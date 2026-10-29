// MIT License
// Copyright (c) 2024 xob0t (PhotosBackup)
// Vendored and adapted for Cloudified under the MIT License. See licenses/LICENSE-PhotosBackup.txt.

import Foundation
import CloudifiedCore
import CryptoKit

/// The `google.rpc.Status` Google puts in a protobuf error body: a canonical
/// code in field 1, an English message in field 2.
struct GoogleStatus: Equatable, Sendable {
    enum Code: Int, Equatable, Sendable {
        case invalidArgument = 3
        case deadlineExceeded = 4
        case permissionDenied = 7
        case resourceExhausted = 8
        case failedPrecondition = 9
        case aborted = 10
        case unavailable = 14
        case unauthenticated = 16
    }
    let rawCode: Int
    let message: String?
    let responseKind: DiagnosticResponseKind
    var code: Code? { Code(rawValue: rawCode) }

    init?(_ data: Data) {
        guard !data.isEmpty else { return nil }
        if let number = try? Proto.number(1, in: data), number > 0, let value = Int(exactly: number) {
            rawCode = value; responseKind = .protobuf
            message = (try? Proto.string(at: [2], in: data)) ?? nil
            return
        }
        let first = data.prefix(64).first { ![9, 10, 13, 32].contains($0) }
        guard first == 123, let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = root["error"] as? [String: Any], let name = error["status"] as? String else { return nil }
        let codes = ["INVALID_ARGUMENT":3, "DEADLINE_EXCEEDED":4, "NOT_FOUND":5, "ALREADY_EXISTS":6,
            "PERMISSION_DENIED":7, "RESOURCE_EXHAUSTED":8, "FAILED_PRECONDITION":9, "ABORTED":10,
            "OUT_OF_RANGE":11, "UNIMPLEMENTED":12, "INTERNAL":13, "UNAVAILABLE":14, "DATA_LOSS":15, "UNAUTHENTICATED":16]
        guard let value = codes[name] else { return nil }
        rawCode = value; responseKind = .json; message = error["message"] as? String
    }

    func kind(httpStatus: Int) -> GPMCError.Kind? {
        switch code {
        case .resourceExhausted:
            return httpStatus == 429 ? nil : .storageFull
        case .unauthenticated, .permissionDenied:
            return .credentialRejected
        default:
            return nil
        }
    }
}

/// Current-request evidence only; never reconstructed from an old checkpoint.
final class GoogleCommitDispatch: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    func markSubmitted() { lock.lock(); started = true; lock.unlock() }
    var submitted: Bool { lock.lock(); defer { lock.unlock() }; return started }
}

struct GPMCError: LocalizedError, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case identityUnavailable
        case credentialRejected   // Google refused the credential; the account must be reconnected.
        case tokenBound           // TokenEncrypted=1 — bound token.
        case transport            // Network-level failure.
        case server(Int)          // Non-2xx from Google.
        case malformed            // Malformed body.
        case invalidUploadReceipt // Invalid upload token.
        case storageFull          // Storage exhausted.
        case pairedPhotoMissing   // Live Photo motion arrived before photo.
    }
    let kind: Kind
    let message: String
    let status: GoogleStatus?
    let retryAfter: Date?
    let transportFailure: SafeFailure?
    var httpStatus: Int?
    var responseBytes: Int?
    var responseKind: DiagnosticResponseKind?
    var commitNotSubmitted = false
    var diagnosticStage: DiagnosticStage? = nil
    let googleReason: DiagnosticGoogleError?
    init(kind: Kind = .malformed, message: String, status: GoogleStatus? = nil, retryAfter: Date? = nil, transportFailure: SafeFailure? = nil, googleReason: DiagnosticGoogleError? = nil) {
        self.kind = kind; self.message = message; self.status = status; self.retryAfter = retryAfter
        self.transportFailure = transportFailure
        self.googleReason = googleReason
    }
    var errorDescription: String? { message }

    static func describeTransport(_ error: Error) -> String {
        let nsError = error as NSError
        let described = nsError.localizedDescription
        let useless = described.isEmpty
            || described.localizedCaseInsensitiveContains("unknown error")
        guard useless else { return described }
        if let urlError = error as? URLError {
            return "\(urlError.code) (URLError \(urlError.errorCode))"
        }
        return "\(nsError.domain) \(nsError.code)"
    }

    var isRetryable: Bool {
        switch kind {
        case .transport, .invalidUploadReceipt, .pairedPhotoMissing: return true
        case .server(let code): return code == 408 || code == 429 || code >= 500
        case .identityUnavailable, .credentialRejected, .tokenBound, .malformed, .storageFull: return false
        }
    }
}

/// What the server had to say about one item once the upload finished.
enum UploadOutcome: Equatable, Sendable {
    case uploaded(mediaKey: String)
    case alreadyBackedUp(mediaKey: String)
    var mediaKey: String {
        switch self { case .uploaded(let key), .alreadyBackedUp(let key): return key }
    }
}

/// Byte-level progress for one upload.
enum UploadPhase: Equatable, Sendable {
    case hashing(fraction: Double)
    case checkingDuplicate
    case preparing
    case sending(sent: Int64, total: Int64)
    case finalizing
}

enum UploadPreparation: Equatable, Sendable {
    case alreadyBackedUp(mediaKey: String)
    case ready(PreparedUpload)
}

struct PreparedUpload: Codable, Equatable, Sendable {
    let uploadURL: URL
    let hash: Data
    let filename: String
    let modified: Date
    let byteCount: Int64
    var receipt: Data?
}

struct FileUploadResult: Sendable {
    let data: Data
    let response: HTTPURLResponse
}

protocol FileUploadTransport: Sendable {
    var continuesAfterProcessExit: Bool { get }
    func upload(_ request: URLRequest, fromFile file: URL, transferID: UUID,
                progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> FileUploadResult
    func cancel(transferID: UUID) async
    func forget(transferID: UUID) async
}

struct AuthData: Sendable {
    let values: [String: String]
    static let required = ["androidId", "client_sig", "callerSig", "device_country", "Email", "google_play_services_version", "lang", "oauth2_foreground", "sdk_version", "service", "Token"]
    init(_ text: String) throws {
        var parsed: [String: String] = [:]
        for pair in text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            func decode(_ s: Substring) -> String { String(s).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(s) }
            parsed[decode(parts[0])] = decode(parts[1])
        }
        let missing = Self.required.filter { parsed[$0, default: ""].isEmpty }
        guard missing.isEmpty else { throw GPMCError(kind: .credentialRejected, message: "Missing auth fields: " + missing.joined(separator: ", ")) }
        values = parsed
    }
    var body: Data {
        var values = values.filter { Self.required.contains($0.key) }
        values["app"] = "com.google.android.apps.photos"; values["callerPkg"] = "com.google.android.apps.photos"
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return Data(values.keys.sorted().map { key in
            key + "=" + values[key]!.addingPercentEncoding(withAllowedCharacters: allowed)!
        }.joined(separator: "&").utf8)
    }
}

private func drainingAutoreleasePool<T>(_ body: () throws -> T) rethrows -> T {
    #if canImport(ObjectiveC)
    try autoreleasepool(invoking: body)
    #else
    try body()
    #endif
}

final class UploadRequestNetworkPolicy: @unchecked Sendable {
    private let lock = NSLock()
    private var cellularAllowed = true

    func setCellularAllowed(_ allowed: Bool) {
        lock.lock()
        cellularAllowed = allowed
        lock.unlock()
    }

    func apply(to request: inout URLRequest) {
        lock.lock()
        let allowed = cellularAllowed
        lock.unlock()
        request.allowsCellularAccess = allowed
        request.allowsExpensiveNetworkAccess = allowed
        request.allowsConstrainedNetworkAccess = false
    }
}

actor GPMCClient {
    private let auth: AuthData
    private let httpTransport: ForegroundFileUploadTransport
    private let networkPolicy: UploadRequestNetworkPolicy
    private let fileUploadTransport: any FileUploadTransport
    private var token = ""
    private var expiry = Date.distantPast
    private var identityProof: (token: String, subject: String, until: Date)?
    private var establishedSubject: String?
    private let userAgent = "com.google.android.apps.photos/49029607 (Linux; U; Android 9; en_US; Pixel XL; Build/PQ2A.190205.001; Cronet/127.0.6510.5) (gzip)"

    init(authData: String,
         freshExchange: GoogleTokenExchange.Result? = nil,
         session: URLSession? = nil,
         networkPolicy: UploadRequestNetworkPolicy = UploadRequestNetworkPolicy(),
         fileUploadTransport: (any FileUploadTransport)? = nil) throws {
        auth = try AuthData(authData)
        if let freshExchange, freshExchange.authData == authData, !freshExchange.encrypted,
           !freshExchange.photosAccessToken.isEmpty {
            token = freshExchange.photosAccessToken
            expiry = freshExchange.photosTokenExpiry ?? Date().addingTimeInterval(300)
        }
        self.networkPolicy = networkPolicy
        let configuration = (session?.configuration ?? URLSessionConfiguration.ephemeral).copy() as! URLSessionConfiguration
        configuration.waitsForConnectivity = true
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 120; configuration.timeoutIntervalForResource = 3600
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData; configuration.urlCache = nil
        httpTransport = ForegroundFileUploadTransport(configuration: configuration, reuseDataSession: true)
        self.fileUploadTransport = fileUploadTransport ?? ForegroundFileUploadTransport(configuration: configuration)
    }

    var accountEmail: String { auth.values["Email"] ?? "" }

    private func checked(_ data: Data, _ response: URLResponse, operation: String = "request") throws -> (Data, HTTPURLResponse) {
        do { return try checkedResponse(data, response, operation: operation) }
        catch var error as GPMCError {
            error.httpStatus = (response as? HTTPURLResponse)?.statusCode
            error.responseBytes = data.count
            let contentType = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
            if data.isEmpty { error.responseKind = .empty }
            else if let status = error.status { error.responseKind = status.responseKind }
            else { error.responseKind = contentType.contains("json") ? .json : contentType.contains("html") ? .html : .other }
            throw error
        }
    }
    private func checkedResponse(_ data: Data, _ response: URLResponse, operation: String = "request") throws -> (Data, HTTPURLResponse) {
        guard let http = response as? HTTPURLResponse else { throw GPMCError(message: "Invalid server response.") }
        let identityReason = ["account verification", "token verification"].contains(operation) ? Self.identityError(data) : nil
        if http.statusCode == 401 || http.statusCode == 403 {
            throw GPMCError(kind: .credentialRejected, message: "Google rejected the stored credential. Connect the account again.",
                transportFailure: SafeFailure(.authentication, domain: .google, code: http.statusCode, cause: .loginRequired),
                googleReason: identityReason)
        }
        guard (200..<300).contains(http.statusCode) else {
            let status = GoogleStatus(data)
            var retryAfter: Date?
            if let text = http.value(forHTTPHeaderField: "Retry-After") {
                if let seconds = Double(text), seconds.isFinite, seconds >= 0, seconds <= 31_536_000 { retryAfter = Date().addingTimeInterval(seconds) }
                else {
                    let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
                    formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
                    retryAfter = formatter.date(from: text)
                }
            }
            if http.statusCode == 429 && retryAfter == nil { retryAfter = Date().addingTimeInterval(60) }
            switch status?.kind(httpStatus: http.statusCode) {
            case .storageFull:
                throw GPMCError(kind: .storageFull,
                                message: "The Google account is out of storage. Free up space in Google Photos, then resume."
                                    , status: status, retryAfter: retryAfter)
            case .credentialRejected:
                throw GPMCError(kind: .credentialRejected,
                                message: "Google rejected the stored credential during \(operation). Connect the account again."
                                    , status: status, retryAfter: retryAfter)
            default:
                throw GPMCError(kind: .server(http.statusCode),
                                message: "Google returned HTTP \(http.statusCode) during \(operation)."
                                    , status: status, retryAfter: retryAfter, googleReason: identityReason)
            }
        }
        return (data, http)
    }

    private func send(_ originalRequest: URLRequest, submission: GoogleCommitDispatch? = nil, responseLimit: Int = 1_048_576) async throws -> (Data, URLResponse) {
        try Task.checkCancellation()
        var request = originalRequest
        networkPolicy.apply(to: &request)
        do {
            return try await httpTransport.requestData(request, responseLimit: responseLimit, onStart: { submission?.markSubmitted() })
        } catch let error as GPMCError {
            throw error
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw GPMCError(kind: .transport, message: "Google network request failed.", transportFailure: ProviderSupport.safe(error, domain: .urlSession))
        }
    }

    func authenticate() async throws {
        do {
        var request = URLRequest(url: URL(string: "https://android.googleapis.com/auth")!); request.httpMethod = "POST"
        request.httpBody = auth.body; request.timeoutInterval = 60
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("com.google.android.apps.photos", forHTTPHeaderField: "app")
        request.setValue(auth.values["androidId"], forHTTPHeaderField: "device")
        request.setValue("GoogleAuth/1.4 (Pixel XL PQ2A.190205.001); gzip", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await send(request)
        var fields: [String: String] = [:]
        for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1)
            if parts.count == 2 { fields[String(parts[0])] = String(parts[1]) }
        }
        if fields["TokenEncrypted"] == "1" {
            throw GPMCError(kind: .tokenBound, message: "Google returned an encrypted (bound) token. This build does not implement token binding; import an unbound credential.")
        }
        if let code = fields["Error"], !code.isEmpty {
            throw GPMCError(kind: .credentialRejected, message: "Google rejected the stored credential. Connect the account again.", googleReason: DiagnosticGoogleError(rawValue: code) ?? .other)
        }
        _ = try checked(data, response, operation: "authentication")
        guard let value = fields["Auth"], !value.isEmpty else {
            throw GPMCError(kind: .credentialRejected, message: "Google did not issue a token. Connect the account again.")
        }
        identityProof = nil
        token = value; expiry = Date(timeIntervalSince1970: Double(fields["Expiry"] ?? "") ?? Date().addingTimeInterval(300).timeIntervalSince1970)
        } catch var error as GPMCError {
            error.diagnosticStage = .googleAuthenticate
            throw error
        }
    }

    /// Same access token as the Photos RPCs. Email in imported authData is not
    /// identity proof. Both identity paths verify this exact token or fail closed.
    func verifiedSubject(onDiagnostic: GoogleTokenExchange.DiagnosticCallback? = nil) async throws -> String {
        if expiry <= Date().addingTimeInterval(30) { try await authenticate() }
        let verifiedToken = token
        if let proof = identityProof, proof.token == verifiedToken, proof.until > Date() {
            return proof.subject
        }
        let data: Data
        var proofExpiry = expiry
        var proofStage: DiagnosticStage = .googleIdentity
        let correlation = UUID(), started = ProcessInfo.processInfo.systemUptime
        func trace(_ stage: DiagnosticStage, _ status: DiagnosticStatus, rejection: GPMCError? = nil) async {
            let failure = rejection.map { GooglePhotosClientSession.classify($0) }
            await onDiagnostic?(DiagnosticDetail(stage: stage, status: status, correlationID: correlation,
                httpStatus: rejection?.transportFailure?.code ?? {
                    if let rejection, case .server(let code) = rejection.kind { return code }; return nil
                }(), googleError: rejection?.googleReason), failure,
                ProcessInfo.processInfo.systemUptime - started)
        }
        await trace(.googleIdentity, .started)
        do {
            data = try await request(URL(string: "https://openidconnect.googleapis.com/v1/userinfo")!,
                method: "GET", headers: ["Accept": "application/json", "Authorization": "Bearer \(verifiedToken)"],
                operation: "account verification", allowReauth: false, photosProtocolHeaders: false).0
        } catch var error as GPMCError {
            error.diagnosticStage = error.diagnosticStage ?? .googleIdentity
            await trace(error.diagnosticStage ?? .googleIdentity, .failed, rejection: error)
            guard error.diagnosticStage != .googleAuthenticate,
                  error.kind == .credentialRejected || error.kind == .server(400) else { throw error }
            // Match Google's own OAuth2Client.getTokenInfo: POST with Bearer header.
            // No token URL, separate identity credential or email-only mapping.
            proofStage = .googleTokenInfo
            await trace(.googleTokenInfo, .started)
            var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/tokeninfo")!)
            request.httpMethod = "POST"; request.timeoutInterval = 45
            request.setValue("Bearer \(verifiedToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/x-www-form-urlencoded;charset=UTF-8", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            do {
                let result = try await send(request)
                data = try checked(result.0, result.1, operation: "token verification").0
                guard data.count <= 16_384,
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let seconds = Self.tokenInfoLifetime(object["expires_in"]), seconds > 0 else {
                    throw GPMCError(kind: .identityUnavailable, message: "Google did not provide a valid token lifetime.")
                }
                proofExpiry = min(proofExpiry, Date().addingTimeInterval(seconds))
            } catch var rejection as GPMCError {
                rejection.diagnosticStage = .googleTokenInfo
                await trace(.googleTokenInfo, .failed, rejection: rejection)
                throw rejection
            }
        }
        guard token == verifiedToken, expiry > Date(), proofExpiry > Date(),
              data.count <= 16_384,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let subject = object["sub"] as? String, !subject.isEmpty, subject.utf8.count <= 255,
              subject.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 || $0 == 46 }) else {
            var rejection = GPMCError(kind: .identityUnavailable, message: "Immutable Google account verification is unavailable.")
            rejection.diagnosticStage = proofStage
            await trace(proofStage, .failed, rejection: rejection)
            throw rejection
        }
        guard establishedSubject == nil || establishedSubject == subject else {
            throw GPMCError(kind: .identityUnavailable, message: "Google account identity changed.",
                transportFailure: SafeFailure(.authentication, domain: .google, cause: .accountChanged))
        }
        establishedSubject = subject
        expiry = min(expiry, proofExpiry)
        identityProof = (verifiedToken, subject, proofExpiry)
        await trace(proofStage, .succeeded)
        guard token == verifiedToken, expiry > Date() else {
            throw GPMCError(kind: .identityUnavailable, message: "Google credential changed during verification.")
        }
        return subject
    }

    private static func tokenInfoLifetime(_ value: Any?) -> TimeInterval? {
        let seconds: Double?
        if let text = value as? String { seconds = Double(text) }
        else if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { seconds = number.doubleValue }
        else { seconds = nil }
        guard let seconds, seconds.isFinite, seconds > 0, seconds <= 31_536_000 else { return nil }
        return seconds
    }

    func validateReadAccess() async throws {
        if expiry <= Date().addingTimeInterval(30) { try await authenticate() }
        let dummyHash = Data(repeating: 0, count: 20)
        let check = Proto.bytes(1, Proto.bytes(1, Proto.bytes(1, dummyHash)) + Proto.bytes(2, Data()))
        _ = try await rpc(Self.hashCheckMethod, body: check)
    }

    private static func identityError(_ data: Data) -> DiagnosticGoogleError? {
        guard data.count <= 16_384, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .other }
        if let name = object["error"] as? String { return DiagnosticGoogleError(rawValue: name) ?? .other }
        if let error = object["error"] as? [String: Any] {
            // Exact known prose only; arbitrary server text is never retained.
            switch error["message"] as? String {
            case "Unsupported token type": return .unsupportedTokenType
            case "Invalid Credentials": return .invalidToken
            case "Invalid Value": return .invalidRequest
            default: break
            }
            if let status = error["status"] as? String { return DiagnosticGoogleError(rawValue: status) ?? .other }
        }
        return .other
    }

    private func request(_ url: URL, method: String = "POST", body: Data? = nil, headers: [String: String] = [:], operation: String = "request", allowReauth: Bool = true, photosProtocolHeaders: Bool = true, timeout: TimeInterval = 120, submission: GoogleCommitDispatch? = nil, responseLimit: Int = 1_048_576) async throws -> (Data, HTTPURLResponse) {
        if expiry <= Date().addingTimeInterval(30) { try await authenticate() }
        // Renewed Photos credentials must be identity-verified before any RPC.
        // JSON identity calls opt out, so this cannot recurse into itself.
        if photosProtocolHeaders { _ = try await verifiedSubject() }
        var request = URLRequest(url: url); request.httpMethod = method; request.timeoutInterval = timeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if photosProtocolHeaders {
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("en_US", forHTTPHeaderField: "Accept-Language")
            request.setValue("application/x-protobuf", forHTTPHeaderField: "Content-Type")
        } else {
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unavailable"
            request.setValue("Cloudified/\(version)", forHTTPHeaderField: "User-Agent")
        }
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.httpBody = body
        let result = try await send(request, submission: submission, responseLimit: responseLimit)
        if allowReauth, let http = result.1 as? HTTPURLResponse, http.statusCode == 401 || http.statusCode == 403 {
            expiry = .distantPast
            return try await self.request(url, method: method, body: body, headers: headers, operation: operation,
                                          allowReauth: false, photosProtocolHeaders: photosProtocolHeaders, timeout: timeout, submission: submission, responseLimit: responseLimit)
        }
        return try checked(result.0, result.1, operation: operation)
    }

    private static let hashCheckMethod = "5084965799730810217"
    private static let commitMethod = "16538846908252377752"
    private static let extHeaders = [
        "x-goog-ext-173412678-bin": "CgcIAhClARgC",
        "x-goog-ext-174067345-bin": "CgIIAg==",
    ]

    private func rpc(_ method: String, body: Data, ext: Bool = false, submission: GoogleCommitDispatch? = nil) async throws -> Data {
        try await request(URL(string: "https://photosdata-pa.googleapis.com/6439526531001121323/" + method)!,
                          body: body, headers: ext ? Self.extHeaders : [:],
                          operation: method == Self.commitMethod ? "finalization" : "duplicate check", submission: submission).0
    }

    func prepareVerifiedUpload(file: URL, filename: String, modified: Date?, hash: Data, byteCount: Int64,
                               stillHash: Data?, phase: @escaping @Sendable (UploadPhase) -> Void) async throws -> UploadPreparation {
        guard hash.count == 20, byteCount > 0 else { throw GPMCError(kind: .malformed, message: "Invalid verified original.") }
        phase(.checkingDuplicate)
        if let key = try await remoteMediaKey(sha1: hash, asLivePhotoMotion: stillHash != nil) { return .alreadyBackedUp(mediaKey: key) }
        if let stillHash, try await remoteMediaKey(sha1: stillHash) == nil {
            throw GPMCError(kind: .pairedPhotoMissing, message: "Paired still is not present.")
        }
        return .ready(try await startUploadSession(file: file, filename: filename, modified: modified, hash: hash,
                                                   size: UInt64(byteCount), phase: phase))
    }

    func prepareUpload(file: URL, filename: String, modified: Date? = nil,
                       phase: @escaping @Sendable (UploadPhase) -> Void) async throws -> UploadPreparation {
        let (hash, size) = try hashFile(file, phase: phase)
        phase(.checkingDuplicate)
        if let key = try await remoteMediaKey(sha1: hash) {
            return .alreadyBackedUp(mediaKey: key)
        }
        return .ready(try await startUploadSession(file: file, filename: filename, modified: modified,
                                                   hash: hash, size: size, phase: phase))
    }

    func prepareMotionUpload(file: URL, filename: String, modified: Date? = nil, stillHash: Data,
                             phase: @escaping @Sendable (UploadPhase) -> Void) async throws -> UploadPreparation {
        let (hash, size) = try hashFile(file, phase: phase)
        phase(.checkingDuplicate)
        if let key = try await remoteMediaKey(sha1: hash, asLivePhotoMotion: true) {
            return .alreadyBackedUp(mediaKey: key)
        }
        guard try await remoteMediaKey(sha1: stillHash) != nil else {
            throw GPMCError(kind: .pairedPhotoMissing,
                            message: "The photo for this Live Photo motion is not in Google Photos yet, so the motion waits for it.")
        }
        return .ready(try await startUploadSession(file: file, filename: filename, modified: modified,
                                                   hash: hash, size: size, phase: phase))
    }

    private func hashFile(_ file: URL, phase: @escaping @Sendable (UploadPhase) -> Void) throws -> (hash: Data, size: UInt64) {
        let declared = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        guard declared > 0 else { throw GPMCError(message: "That item is empty; there is nothing to upload.") }
        phase(.hashing(fraction: 0))
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        var hasher = Insecure.SHA1(); var size: UInt64 = 0; var reachedEnd = false
        while !reachedEnd {
            try drainingAutoreleasePool {
                guard let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty else {
                    reachedEnd = true
                    return
                }
                try Task.checkCancellation()
                hasher.update(data: chunk)
                size += UInt64(chunk.count)
                phase(.hashing(fraction: min(1, Double(size) / Double(declared))))
            }
        }
        return (Data(hasher.finalize()), size)
    }

    func libraryPage(cursor: GoogleLibraryCursor, subject: String) async throws -> GoogleLibraryPage {
        let body: Data
        do { body = try GoogleLibraryWire.request(cursor, subject: subject) }
        catch { throw GPMCError(message: "Library request is invalid.", googleReason: .libraryRequestInvalid) }
        let response = try await request(URL(string: "https://photosdata-pa.googleapis.com/6439526531001121323/18047484249733410717")!,
            body: body, headers: Self.extHeaders, operation: "library metadata", timeout: 12, responseLimit: 4_194_304)
        do { return try GoogleLibraryWire.page(response.0) }
        catch let failure as GoogleLibraryWire.Failure {
            throw GPMCError(message: "Library response could not be decoded.", googleReason: failure.reason)
        } catch { throw GPMCError(message: "Library response is malformed.", googleReason: .libraryEnvelopeInvalid) }
    }

    func remoteMediaKey(sha1 hash: Data, asLivePhotoMotion: Bool = false) async throws -> String? {
        let query = Proto.bytes(1, hash) + (asLivePhotoMotion ? Proto.int(5, 2) : Data())
        let check = Proto.bytes(1, Proto.bytes(1, query) + Proto.bytes(2, Data()))
        let existing = try await rpc(Self.hashCheckMethod, body: check)
        return try Proto.string(at: [1, 2, 2, 1], in: existing)
    }

    func startUploadSession(file: URL, filename: String, modified: Date?, hash: Data, size: UInt64,
                            phase: @escaping @Sendable (UploadPhase) -> Void) async throws -> PreparedUpload {
        phase(.preparing)
        let endpoint = URL(string: "https://photos.googleapis.com/data/upload/uploadmedia/interactive")!
        let body = Proto.int(1, 2) + Proto.int(2, 2) + Proto.int(3, 1) + Proto.int(4, 3) + Proto.int(7, size)
        let (_, response) = try await request(endpoint, body: body, headers: ["X-Goog-Hash": "sha1=" + hash.base64EncodedString(), "X-Upload-Content-Length": String(size)], operation: "upload initialization")
        guard let uploadID = response.value(forHTTPHeaderField: "X-GUploader-UploadID"), !uploadID.isEmpty, uploadID.utf8.count <= 8192 else { throw GPMCError(message: "Google did not return an upload ID.") }
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "upload_id", value: uploadID)]
        let date = modified ?? (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
        return PreparedUpload(uploadURL: components.url!, hash: hash, filename: filename,
                              modified: date, byteCount: Int64(size), receipt: nil)
    }

    func transfer(_ prepared: PreparedUpload, file: URL, transferID: UUID, foreground: Bool = false,
                  phase: @escaping @Sendable (UploadPhase) -> Void) async throws -> PreparedUpload {
        if let receipt = prepared.receipt {
            try Self.validateReceipt(receipt)
            return prepared
        }
        let request = try await transferRequest(prepared)
        let total = prepared.byteCount
        phase(.sending(sent: 0, total: total))
        let transport: any FileUploadTransport = foreground ? ForegroundFileUploadTransport() : fileUploadTransport
        let result = try await transport.upload(request, fromFile: file, transferID: transferID) { sent, expected in
            phase(.sending(sent: sent, total: expected > 0 ? expected : total))
        }
        return try receivedTransfer(prepared, result: result)
    }
    func submit(_ prepared: PreparedUpload, file: URL, transferID: UUID) async throws {
        guard let transport = fileUploadTransport as? BackgroundFileUploadTransport,
              transport.continuesAfterProcessExit, prepared.receipt == nil else { throw CoreError.invalidTransition }
        let request = try await transferRequest(prepared)
        try Task.checkCancellation()
        try transport.submit(request, fromFile: file, transferID: transferID)
    }
    private func transferRequest(_ prepared: PreparedUpload) async throws -> URLRequest {
        if expiry <= Date().addingTimeInterval(30) { try await authenticate() }
        _ = try await verifiedSubject()
        var request = URLRequest(url: prepared.uploadURL)
        request.httpMethod = "PUT"
        request.timeoutInterval = 7 * 24 * 60 * 60
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("en_US", forHTTPHeaderField: "Accept-Language")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        networkPolicy.apply(to: &request)
        return request
    }
    func receivedTransfer(_ prepared: PreparedUpload, result: FileUploadResult) throws -> PreparedUpload {
        let (receipt, _) = try checked(result.data, result.response, operation: "file transfer")
        try Self.validateReceipt(receipt)
        var completed = prepared
        completed.receipt = receipt
        return completed
    }

    static func validateReceipt(_ receipt: Data) throws {
        guard receipt.count <= 65_536, let fields = try? Proto.fields(receipt),
              let token = fields[2]?.first, !token.isEmpty else {
            throw GPMCError(kind: .invalidUploadReceipt,
                            message: "Google did not return a usable upload receipt. The file must be transferred again.")
        }
    }

    static func rejectsReceipt(_ error: GPMCError) -> Bool {
        guard case .server = error.kind else { return false }
        if let code = error.status?.code { return code == .invalidArgument }
        return error.message.localizedCaseInsensitiveContains("valid blueprint")
    }

    static func commitTimestamp(_ date: Date) throws -> Data {
        let value = date.timeIntervalSince1970
        guard value.isFinite, value >= -62_135_596_800, value < 253_402_300_800 else {
            throw CoreError.invalidContract
        }
        let seconds = floor(value)
        let nanos = UInt64(min(999_999_999, max(0, (value - seconds) * 1_000_000_000)))
        return Proto.int(1, UInt64(bitPattern: Int64(seconds))) + Proto.int(2, nanos)
    }
    static func commitProfile(useQuota: Bool, saver: Bool) -> (model: String, quality: UInt64) {
        (useQuota ? "Pixel 8" : (saver ? "Pixel 2" : "Pixel XL"), saver ? 1 : 3)
    }

    func commit(_ prepared: PreparedUpload, useQuota: Bool, saver: Bool, pairedStillHash: Data? = nil,
                phase: @escaping @Sendable (UploadPhase) -> Void) async throws -> UploadOutcome {
        let submission = GoogleCommitDispatch()
        do {
            return try await commitReceipt(prepared, useQuota: useQuota, saver: saver,
                pairedStillHash: pairedStillHash, phase: phase, submission: submission)
        } catch {
            guard !submission.submitted else { throw error }
            var failure = (error as? GPMCError) ?? GPMCError(kind: .transport,
                message: "Finalization did not start.", transportFailure: ProviderSupport.safe(error, domain: .google))
            failure.commitNotSubmitted = true
            failure.diagnosticStage = .googleCommitNotSubmitted
            throw failure
        }
    }
    private func commitReceipt(_ prepared: PreparedUpload, useQuota: Bool, saver: Bool, pairedStillHash: Data?,
                phase: @escaping @Sendable (UploadPhase) -> Void, submission: GoogleCommitDispatch) async throws -> UploadOutcome {
        guard let receipt = prepared.receipt else {
            throw GPMCError(message: "The upload has not finished transferring yet.")
        }
        try Self.validateReceipt(receipt)
        phase(.finalizing)
        let timestamp = try Self.commitTimestamp(prepared.modified)
        let profile = Self.commitProfile(useQuota: useQuota, saver: saver)
        var metadata = Proto.bytes(1, receipt) + Proto.string(2, prepared.filename) + Proto.bytes(3, prepared.hash) + Proto.bytes(4, timestamp) + Proto.int(7, profile.quality) + Proto.int(10, 1)
        if let pairedStillHash {
            metadata += Proto.bytes(9, Proto.int(2, 1) + Proto.bytes(3, pairedStillHash))
        }
        let device = Proto.string(3, profile.model) + Proto.string(4, "Google") + Proto.int(5, 28)
        let committed: Data
        do {
            committed = try await rpc(Self.commitMethod, body: Proto.bytes(1, metadata) + Proto.bytes(2, device) + Proto.bytes(3, Data([1, 3])), ext: true, submission: submission)
        } catch let error as GPMCError where Self.rejectsReceipt(error) {
            var rejection = GPMCError(kind: .invalidUploadReceipt, message: error.message, status: error.status, googleReason: .uploadReceiptRejected)
            rejection.httpStatus = error.httpStatus; rejection.responseBytes = error.responseBytes; rejection.responseKind = error.responseKind
            throw rejection
        }
        return .uploaded(mediaKey: try Self.commitKey(committed))
    }
    private static func commitKey(_ data: Data) throws -> String {
        let key: String?
        do { key = try Proto.string(at: [1, 3, 1], in: data) }
        catch {
            var failure = GPMCError(message: "Google returned an invalid finalization response.", googleReason: .commitResponseInvalid)
            failure.httpStatus = 200; failure.responseBytes = data.count; failure.responseKind = data.isEmpty ? .empty : .protobuf
            throw failure
        }
        guard let key, !key.isEmpty, key.utf8.count <= 2048 else {
            var failure = GPMCError(message: "Google did not confirm a valid media key.", googleReason: (key?.isEmpty ?? true) ? .commitKeyMissing : .commitResponseInvalid)
            failure.httpStatus = 200; failure.responseBytes = data.count; failure.responseKind = data.isEmpty ? .empty : .protobuf
            throw failure
        }
        return key
    }

    func forgetTransfer(_ transferID: UUID) async {
        await fileUploadTransport.forget(transferID: transferID)
    }

    func cancelTransfer(_ transferID: UUID) async {
        await fileUploadTransport.cancel(transferID: transferID)
    }

    var usesBackgroundFileTransfers: Bool { fileUploadTransport.continuesAfterProcessExit }
}
