// Adapted from xob0t/gpmc 94b1b267; MIT. See licenses/gpmc/LICENSE.txt.
import Foundation
import CloudifiedCore

/// Pinned client capability templates. Cursor and account fields are inserted at runtime.
/// These request metadata only; no thumbnail or original-download RPC is used.
enum GoogleLibraryWire {
    private static let state = "CqsCClkKABoAIgAqDAoAEgAaACIAKgA6ADIAOgISAHoAggEAigEAmgEAogEAqgEGKgIaADIAygEA8gECEgD6AQCCAgCKAgIKAJICAKICAKoCALICALoCAMICAMoCACpSEhgSChoCEgAiBBIAIgAiBBICEAEqAhIAMAEaGhIEGgAiABoIEgAaBBABGgAiACoEEgIQAToAIgQSAhIAKhQKEBIEGgAiABoIEgAaBBABGgAYAUIASjASABoECgASACImCiQaHAoaCggqAgoAMgA6ABIAGgwKCCoCCgAyADoAEgAiBAoCEgBaDBIAGgAiBhIECAEQAmIAcgwSABoAIgYSBAgBEAJ6BAoAIgCKAQQKACIAmgEMEgAaACIGEgQIARACqgECCgCyAQC6AQDCAQAShQEKKxIAGgAiACoAMgwKABIAGgAiACoAOgA6AEIAUgBiAGoEEgAaAHoCCgCSAQAiAgoASgBaDAoKCgAiACoAMgBKAHIkCiIKHgoAEggSBgoCCgAaABoQIgYKAgoAGgAqBgoCCgAaABIAigEAkgEGCgASAgoAogEGEgQKABIAsgEAugEAwgEAGsgBEgAaYhIAGgA6AEIAcgIKAIIBAIoBAhIAkgEAmgEAogEAqgEAsgEAugEA2gEGCgASAgoA6gEA8gEA+gEAggIAkgIAqgIAsgIAugIAygIA2gICCgDqAgQKAgoA8gIGCgASABoA+gIAIgwSABoCCgAiACoCCgA6AGIAagByHAoAEgwKABICCgAaACICCgAaCgoAEgIKABoAIgB6AIIBAgoAkgEAmgEUIgISADIEEgAaADoEEgAaAEIASgCiAQCyAQDCAQDKAQDSAQA4AkoqCgYSBAoAEgASBBoCEAEaAhIAIgA6AgoAQgoIAhIGAQIDBQYHSgBaAgoAWAFYAlgGYgwSBAoAEgAaAgoAIgBqAHoEGgIIAZIBO+qopYgFNQozCjEgAiABIAYgCCAKIA8gEiANIBEgEyAOIBQoBjACOAFAAlgDYAFoA3gBgAEBiAEBkAECmgEuCgQKABIAEgwIAQgCCAQIBggFCAcaBAoAEgAqBAoAEgAyAgoAOgQKABIAQgIKAKIBggEIARp+Ckd0eXBlLmdvb2dsZWFwaXMuY29tL3Bob3Rvcy5wcmludGluZy5jbGllbnQuUHJpbnRpbmdQcm9tb3Rpb25TeW5jT3B0aW9ucxIzCjEgAiABIAYgCCAKIA8gEiANIBEgEyAOIBQoBjACOAFAAlgDYAFoA3gBgAEBiAEBkAECqgGUARIIEgIiACIAKgAaCBICCAEiAhIAKgIKADIGCgASAgoAOisIAhIkAQcICQoNDg8RExQWFy0uLzAxOgYYMjY3Oz4/QEE4OTxHQkVEGgEBQiAaDgoKCggSAggBIgISABoAIgIKACoKCggSAggBIgISAEoCCgBSEgoCCgAaACoAMgIKADoASgBSAFoAYgBqAHIAggECCgDKAQoKBgoECgIKABIA0gEA"
    private static let initial = "CpkCClkKABoAIgAqDAoAEgAaACIAKgA6ADIAOgISAHoAggEAigEAmgEAogEAqgEGKgIaADIAygEA8gECEgD6AQCCAgCKAgIKAJICAKICAKoCALICALoCAMICAMoCACpMEhYSCBoCEgAiAhIAIgQSAhABKgISADABGhgSBBoAIgAaBhIAGgIQASIAKgQSAhABOgAiBBICEgAqEgoOEgQaACIAGgYSABoCEAEYAUIASiwSABoECgASACIiCiAaGAoWCgYqAgoAMgASABoKCgYqAgoAMgASACIECgISAFoMEgAaACIGEgQIARACYgByDBIAGgAiBhIECAEQAnoECgAiAIoBBAoAIgCaAQwSABoAIgYSBAgBEAKyAQC6AQASfworEgAaACIAKgAyDAoAEgAaACIAKgA6ADoAQgBSAGIAagQSABoAegIKAJIBACICCgBKAFoMCgoKACIAKgAyAEoAciQKIgoeCgASCBIGCgIKABoAGhAiBgoCCgAaACoGCgIKABoAEgCKAQCSAQYKABICCgCiAQYSBAoAEgC6AQAaogESABpKEgAaADoAQgByAgoAggEAigECEgCSAQCaAQCiAQCqAQCyAQC6AQDaAQYKABICCgDqAQDyAQD6AQCCAgCSAgCqAgCyAgC6AgDKAgAiBhIAGgAiADoAYgBqAHIcCgASDAoAEgIKABoAIgIKABoKCgASAgoAGgAiAHoAggECCgCSAQCaARIiAhIAMgQSABoAOgQSABoAQgCiAQDCAQDKAQA4AkolCgYSBAoAEgASBBoCEAEaAhIAIgA6AgoAQgkIAhIFAQIDBQZKAFgBWAJiDBIECgASABoCCgAiAGoAegQaAggBkgE76qiliAU1CjMKMSACIAEgBiAIIAogDyASIA0gESATIA4gFCgGMAI4AUACWANgAWgDeAGAAQGIAQGQAQKaAS4KBAoAEgASDAgBCAIIBAgGCAUIBxoECgASACoECgASADICCgA6BAoAEgBCAgoAogGCAQgBGn4KR3R5cGUuZ29vZ2xlYXBpcy5jb20vcGhvdG9zLnByaW50aW5nLmNsaWVudC5QcmludGluZ1Byb21vdGlvblN5bmNPcHRpb25zEjMKMSACIAEgBiAIIAogDyASIA0gESATIA4gFCgGMAI4AUACWANgAWgDeAGAAQGIAQGQAQKqAXESBhIAIgAqABoEEgIIASoCCgAyBgoAEgIKADonCAISIAEHCAkKDQ4PERMUFhctLi8wMToGGDI2Nzs+P0BBODk8GgEBQg4aCAoGCgQSAggBIgIKAEoCCgBSEgoCCgAaACoAMgIKADoASgBSAFoAYgBqAMoBCgoGCgQKAgoAEgA="
    private static let delta = "CpkCClkKABoAIgAqDAoAEgAaACIAKgA6ADIAOgISAHoAggEAigEAmgEAogEAqgEGKgIaADIAygEA8gECEgD6AQCCAgCKAgIKAJICAKICAKoCALICALoCAMICAMoCACpMEhYSCBoCEgAiAhIAIgQSAhABKgISADABGhgSBBoAIgAaBhIAGgIQASIAKgQSAhABOgAiBBICEgAqEgoOEgQaACIAGgYSABoCEAEYAUIASiwSABoECgASACIiCiAaGAoWCgYqAgoAMgASABoKCgYqAgoAMgASACIECgISAFoMEgAaACIGEgQIARACYgByDBIAGgAiBhIECAEQAnoECgAiAIoBBAoAIgCaAQwSABoAIgYSBAgBEAKyAQC6AQASfworEgAaACIAKgAyDAoAEgAaACIAKgA6ADoAQgBSAGIAagQSABoAegIKAJIBACICCgBKAFoMCgoKACIAKgAyAEoAciQKIgoeCgASCBIGCgIKABoAGhAiBgoCCgAaACoGCgIKABoAEgCKAQCSAQYKABICCgCiAQYSBAoAEgC6AQAaogESABpKEgAaADoAQgByAgoAggEAigECEgCSAQCaAQCiAQCqAQCyAQC6AQDaAQYKABICCgDqAQDyAQD6AQCCAgCSAgCqAgCyAgC6AgDKAgAiBhIAGgAiADoAYgBqAHIcCgASDAoAEgIKABoAIgIKABoKCgASAgoAGgAiAHoAggECCgCSAQCaARIiAhIAMgQSABoAOgQSABoAQgCiAQDCAQDKAQA4AkolCgYSBAoAEgASBBoCEAEaAhIAIgA6AgoAQgkIAhIFAQIDBQZKAFgBWAJiDBIECgASABoCCgAiAGoAegQaAggBkgE76qiliAU1CjMKMSACIAEgBiAIIAogDyASIA0gESATIA4gFCgGMAI4AUACWANgAWgDeAGAAQGIAQGQAQKaAS4KBAoAEgASDAgBCAIIBAgGCAUIBxoECgASACoECgASADICCgA6BAoAEgBCAgoAogGCAQgBGn4KR3R5cGUuZ29vZ2xlYXBpcy5jb20vcGhvdG9zLnByaW50aW5nLmNsaWVudC5QcmludGluZ1Byb21vdGlvblN5bmNPcHRpb25zEjMKMSACIAEgBiAIIAogDyASIA0gESATIA4gFCgGMAI4AUACWANgAWgDeAGAAQGIAQGQAQKqAXESBhIAIgAqABoEEgIIASoCCgAyBgoAEgIKADonCAISIAEHCAkKDQ4PERMUFhctLi8wMToGGDI2Nzs+P0BBODk8GgEBQg4aCAoGCgQSAggBIgIKAEoCCgBSEgoCCgAaACoAMgIKADoASgBSAFoAYgBqAMoBCgoGCgQKAgoAEgA="
    private static let outer = "EgwKCAoGCgIKABIAEgA="
    static func request(_ cursor: GoogleLibraryCursor, subject: String) throws -> Data {
        guard !subject.isEmpty, subject.utf8.count <= 128, cursor.resume.utf8.count <= 8192,
              cursor.sync.utf8.count <= 8192 else { throw Proto.Failure.malformed }
        let template = cursor.resume.isEmpty ? state : (cursor.initial ? initial : delta)
        guard var body = Data(base64Encoded: template), let tail = Data(base64Encoded: outer) else { throw Proto.Failure.malformed }
        if !cursor.resume.isEmpty { body += Proto.string(4, cursor.resume) }
        if !cursor.initial || cursor.resume.isEmpty { body += Proto.string(6, cursor.sync) }
        let identity = Proto.int(1, cursor.resume.isEmpty ? 1 : 2) + (cursor.resume.isEmpty ? Proto.string(2, subject) : Data())
        body += Proto.bytes(22, identity)
        return Proto.bytes(1, body) + tail
    }

    static func page(_ data: Data) throws -> GoogleLibraryPage {
        guard data.count <= 1_048_576, let root = try Proto.fields(data)[1]?.first else { throw Proto.Failure.malformed }
        let fields = try Proto.fields(root)
        guard (fields[1]?.count ?? 0) <= 1, (fields[6]?.count ?? 0) <= 1,
              (fields[2]?.count ?? 0) <= 1000, (fields[9]?.count ?? 0) <= 1000 else { throw Proto.Failure.malformed }
        let resume = try text(1, in: root, limit: 8192) ?? ""
        let sync = try text(6, in: root, limit: 8192) ?? ""
        var items: [GoogleRemoteItem] = [], deleted: [String] = [], skipped = 0
        for record in fields[2] ?? [] {
            do { items.append(try item(record)) } catch { skipped += 1 }
        }
        for record in fields[9] ?? [] {
            guard let body = try Proto.fields(record)[1]?.first else { skipped += 1; continue }
            let type = try Proto.number(1, in: body)
            if type == 1, let key = try Proto.string(at: [2, 1], in: body), key.utf8.count <= 2048 { deleted.append(key) }
            else if type == 1 { skipped += 1 }
        }
        return GoogleLibraryPage(resume: resume, sync: sync, items: items, deleted: deleted, skipped: skipped)
    }
    private static func text(_ field: Int, in data: Data, limit: Int) throws -> String? {
        guard let bytes = try Proto.fields(data)[field]?.first else { return nil }
        guard bytes.count <= limit, let value = String(data: bytes, encoding: .utf8) else { throw Proto.Failure.malformed }
        return value.isEmpty ? nil : value
    }
    private static func item(_ data: Data) throws -> GoogleRemoteItem {
        let fields = try Proto.fields(data)
        guard let key = try text(1, in: data, limit: 2048), let info = fields[2]?.first,
              let name = try text(4, in: info, limit: 512), let bytes = try Proto.number(10, in: info),
              let stamp = try Proto.number(7, in: info), bytes <= UInt64(Int64.max) else { throw Proto.Failure.malformed }
        let properties = try Proto.fields(info)
        // Trashed/locked items cannot protect a normal-library backup.
        let trash = try properties[16]?.first.flatMap { try Proto.number(3, in: $0) } ?? 0
        let locked = try properties[39]?.first.flatMap { try Proto.number(1, in: $0) } ?? 0
        guard trash == 0, locked != 1 else { throw Proto.Failure.malformed }
        let media = fields[5]?.first ?? Data()
        let kind = try Proto.fields(media)
        let photo = kind[2]?.first ?? Data(), video = kind[3]?.first ?? Data()
        let size = try Proto.fields(photo)[1]?.first.flatMap { try Proto.fields($0)[9]?.first }
        let videoSize = try Proto.fields(video)[4]?.first
        let width = try size.flatMap { try Proto.number(1, in: $0) } ?? videoSize.flatMap { try Proto.number(4, in: $0) } ?? 0
        let height = try size.flatMap { try Proto.number(2, in: $0) } ?? videoSize.flatMap { try Proto.number(5, in: $0) } ?? 0
        guard width <= 1_000_000, height <= 1_000_000 else { throw Proto.Failure.malformed }
        let qualityCode = try properties[35]?.first.flatMap { try Proto.number(3, in: $0) }
        let quality: GoogleRemoteQuality = qualityCode == 2 ? .original : .unknown
        let value = GoogleRemoteItem(key: key, filename: name, bytes: Int64(bytes), timestamp: Double(Int64(bitPattern: stamp)) / 1000,
                                    width: Int(width), height: Int(height), quality: quality)
        guard value.valid else { throw Proto.Failure.malformed }
        return value
    }
}
