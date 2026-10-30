#!/usr/bin/env python3
"""Host regression checks of actual Core + source-extracted Telegram census.

No network, accounts, Xcode download, iPhone build or app/demo records. Only native
request/error boundaries use fixtures; all fixture databases are temporary.
"""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--sdk', type=Path)
parser.add_argument('--build-dir', type=Path, default=ROOT / 'build/core-regressions')
args = parser.parse_args()
sdk = args.sdk or Path(subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip())
out = args.build_dir.resolve()
out.mkdir(parents=True, exist_ok=True)
common = ['-swift-version', '6', '-sdk', str(sdk), '-module-cache-path', str(out / 'cache'),
          '-I', str(out), '-Xcc', '-fmodule-map-file=' + str(ROOT / 'Packages/CloudifiedCore/Sources/CSQLite/module.modulemap')]
def run(argv):
    subprocess.run(argv, cwd=ROOT, check=True)
for name, folder, libraries in [('CloudifiedDiagnostics', 'Diagnostics', []),
                              ('CloudifiedCore', 'CloudifiedCore', ['-L', str(out), '-lCloudifiedDiagnostics'])]:
    print('Compile actual ' + name, flush=True)
    run(['swiftc', *common, '-enable-testing', '-emit-library', '-emit-module', '-parse-as-library',
         '-module-name', name, *map(str, sorted((ROOT / 'Packages/CloudifiedCore/Sources' / folder).glob('*.swift'))),
         *libraries, '-emit-module-path', str(out / (name + '.swiftmodule')), '-o', str(out / ('lib' + name + '.dylib'))])

def section(text, start, end):
    a = text.index(start)
    return text[a:text.index(end, a)]
backup = (ROOT / 'App/Application/AppEnvironment+Backup.swift').read_text()
(out / 'ActualBackupRequest.swift').write_text('import Foundation\nimport CloudifiedCore\nextension BackupRequestHarness {\n'
    + section(backup, '    public func requestBackup() {', '    func requestDrain()')
    + section(backup, '    func requireNoRetainedInputs(', '    public func retryItem(') + '}\n')
telegram = (ROOT / 'App/Adapters/Telegram/TelegramProviderAdapter.swift').read_text()
body = section(telegram, '    private struct Census {', '    private var census:')
body += '    private var census: Census?\n'
body += section(telegram, '    private func scanIndex(', '    func inspect(').replace('private func scanIndex', 'func scanIndex')
(out / 'ActualCensus.swift').write_text('''import Foundation
import CloudifiedCore
actor CensusHarness {
 let ledger:Ledger, client:CensusBoundary
 var scanning=false, absenceCurrent=false
 var censusRead:Int?, historyRevision:UInt64=0, epoch:UUID?, streamFailure:SafeFailure?
 let statusContinuation=AsyncStream<Void>.makeStream(bufferingPolicy:.bufferingNewest(1)).continuation
 init(_ ledger:Ledger,_ client:CensusBoundary){self.ledger=ledger;self.client=client}
 func verifyChannel(_ id:Int64) async throws { precondition(id == -100) }
 func incompleteHistory()->SafeFailure {SafeFailure(.reconciliation,domain:.tdlib,cause:.incompleteHistory)}
 func invalidate(){historyRevision &+= 1}
 func complete()->Bool {absenceCurrent}
''' + body + '}\n')
(out / 'ActualResolution.swift').write_text('''import Foundation
import CloudifiedCore
actor ResolutionHarness {
''' + section(telegram, '    private enum Resolution:', '    private struct Pending {').replace('private enum Resolution', 'enum Resolution') + '''
 struct Pending {
  var resolution:Resolution?
  var waiter:CheckedContinuation<Resolution,Never>?
  var deadline:Task<Void,Never>?
  var rejectionCheck:Task<Void,Never>?
 }
 var pending:[Int32:Pending] = [1:Pending()]
 func set(_ value:Resolution){resolve(1,value)}
 func result()->Resolution?{pending[1]?.resolution}
''' + section(telegram, '    private func resolve(', '    func recover(') + '}\n')
support = (ROOT / 'App/Adapters/System/ProviderSupport.swift').read_text()
(out / 'Support.swift').write_text('''import Foundation
import CryptoKit
import CloudifiedCore
enum ProviderSupport {
 static func safe(_ error:any Error,domain:ErrorDomain)->SafeFailure {
  if let wrapped = error as? SafeProviderFailure {return wrapped.failure}
  if let failure = error as? SafeFailure {return failure}
  if error is TDLibError {return TDLibClient.classify(error)}
  if case CoreError.persistence(let code) = error {return SafeFailure(.invariant,domain:.sqlite,code:Int(code),cause:.persistenceFailed)}
  if case CoreError.staleMapping = error {return SafeFailure(.authentication,domain:domain,cause:.accountChanged)}
  return SafeFailure(.reconciliation,domain:domain,cause:.interrupted)
 }
''' + section(support, '    static func canonical<', '    static func fingerprint(')
    + section(support, '    static func fingerprint(', '    static func hex(')
    + section(support, '    static func hex(', '    static func safe(')
    + section(support, '    static func disposition(', '    /// Invalid evidence')
    + section(support, '    static func blocksDestination(', '    static func availableBytes(')
    + section(support, '    static func context(', 'final class ProviderProgressPump:')
    + support[support.index('final class ProviderProgressPump:'):] )
session = (ROOT / 'App/Adapters/Telegram/TDLibSession.swift').read_text()
(out / 'ActualProtocolRecovery.swift').write_text('''import Foundation
import CloudifiedCore
actor ProtocolRecoveryHarness {
 enum CloseOutcome: Sendable {case acknowledged, unresolved, differentError}
 var processingFailure:(any Error)? = TDLibError.responseLimitExceeded(.nodes)
 var isTerminated=false
 var clientID:Int32?=1
 let outcome:CloseOutcome
 init(_ outcome:CloseOutcome){self.outcome=outcome}
 func close() async throws {
  switch outcome {
  case .acknowledged: isTerminated=true;clientID=nil;throw processingFailure!
  case .unresolved: throw TDLibError.unresolvedClose("fixture")
  case .differentError: isTerminated=true;clientID=nil;throw ProbeError.rollback
  }
 }
 func acknowledged()->Bool {isTerminated && clientID == nil}
''' + section(session, '    var restartableProtocolFailure: Bool {', '    public private(set) var connectionReady') + '}\n')
client = (ROOT / 'App/Adapters/Telegram/TDLibClient.swift').read_text()
(out / 'ActualLocalReset.swift').write_text('import Foundation\nimport CloudifiedCore\nextension LocalResetHarness {\n'
    + section(client, '    func resetLocalDatabaseAfterKeyLoss()', '    /// Initializes and starts')
        .replace('Self.storageURLs(', 'storageURLsForBoundary(') + '}\n')
(out / 'ActualTelegramRequest.swift').write_text('import Foundation\nimport CloudifiedCore\n'
    + section(client, 'struct TDLibRequestRejection:', 'public actor TDLibClient') + """
actor NativeRequestHarness {
 let session:NativeRequestBoundary
 init(_ error:TDLibError){session=NativeRequestBoundary(error)}
 func emitDiagnostic(_ op:EventOperation,decision:EventDecision,severity:EventSeverity,failure:SafeFailure?) async throws {}
""" + section(client, '    func request(_ request:', '    /// Streams raw updates').replace('Self.classify(', 'TDLibClient.classify(').replace('Self.retryDelay(', 'TDLibClient.retryDelay(') + '}\n')
(out / 'ActualNetworkPolicy.swift').write_text('''import Foundation
actor NetworkPolicyHarness {
 let session:NetworkPolicyBoundary
 var isStarting=false, networkType="networkTypeNone"
 var appliedNetworkType:String?
 var networkPolicyTask:(id:UUID,task:Task<Void,any Error>)?
 init(_ session:NetworkPolicyBoundary){self.session=session}
 func desired()->String {networkType}
''' + section(client, '    func setNetworkPolicy(', '    private func emitDiagnostic(') + '}\n')
(out / 'ActualOwnedRecovery.swift').write_text('''import Foundation
import CloudifiedCore
actor OwnedRecoveryHarness {
 let inputFiles:TelegramInputFiles, client:OwnedRecoveryBoundary
 init(_ inputFiles:TelegramInputFiles,_ client:OwnedRecoveryBoundary){self.inputFiles=inputFiles;self.client=client}
 private struct Pending {var checkpoint:ProviderCheckpoint;var state:State;var inputInventoried=false;var quarantined=false}
 private var pending:[Int32:Pending]=[:]
 func match(_ checkpoint:ProviderCheckpoint,message:TDLibResponse,oldMessageID:Int64?=nil,inventoried:Bool=false) throws -> Int32? {
  pending[1]=Pending(checkpoint:checkpoint,state:State(chatID:-100,sendingID:1,byteCount:3,filename:"original.heic",temporaryID:50,fileID:7),inputInventoried:inventoried)
  return try matchingPending(message,oldMessageID:oldMessageID)
 }
 private var deferrals:[DiagnosticRecoveryLookup]=[]
 func traceOwnedLookup(_ checkpoint:ProviderCheckpoint,pages:Int,candidates:Int,found:Bool,local:Bool) async {}
 func traceLookupDeferral(_ checkpoint:ProviderCheckpoint,lookup:DiagnosticRecoveryLookup,issue:DiagnosticRecoveryIssue) async {deferrals.append(lookup)}
 func deferred()->[DiagnosticRecoveryLookup] {deferrals}
 func incompleteHistory()->SafeFailure {SafeFailure(.reconciliation,domain:.tdlib,cause:.incompleteHistory)}
 func lookup(_ checkpoint:ProviderCheckpoint,fileID:Int32?) async throws -> TDLibResponse? {
  try await findOwnedMessage(checkpoint:checkpoint,state:State(chatID:-100,sendingID:1,byteCount:3,filename:"original.heic",fileID:fileID))
 }
''' + section(telegram, '    private struct State:', '    private enum Resolution:')
 + section(telegram, '    private func matchingPending(', '    private func indexNew(')
 + section(telegram, '    private enum OwnedLookupFailure:', '    private func traceLookupDeferral(')
 + section(telegram, '    private func findOwnedMessage(', '    /// Settings/P6') + '}\n')
(out / 'ActualTelegramSettlement.swift').write_text('''import Foundation
import CloudifiedCore
enum TDLibClient {
''' + section(client, '    static func retryDelay(', '    // MARK: - Error Classification')
 + client[client.index('    static func nativeReason('):] + '''
actor TelegramSettlementHarness {
 let client:OwnedRecoveryBoundary, ledger:Ledger, files:FileLeaseStore,inputFiles:TelegramInputFiles
 private var scope:Scope?=Scope(version:1,userID:1,chatID:-100)
 private var busy=false,nextSendingID:Int32=1,pending:[Int32:Pending]=[:],historyRevision:UInt64=0
 private var mapped:Destination?,epoch:UUID?,scanning=false
 let eventContinuation=AsyncStream<Void>.makeStream(bufferingPolicy:.bufferingNewest(1)).continuation
 let statusContinuation=AsyncStream<Void>.makeStream(bufferingPolicy:.bufferingNewest(1)).continuation
 init(_ client:OwnedRecoveryBoundary,_ ledger:Ledger,_ files:FileLeaseStore){self.client=client;self.ledger=ledger;self.files=files;inputFiles=TelegramInputFiles(stagingRoot:files.root)}
 func startConsumer() async throws {}
 func verify(_ destination:Destination) async throws {mapped=destination}
 func incompleteHistory()->SafeFailure {SafeFailure(.reconciliation,domain:.tdlib,cause:.incompleteHistory)}
 func run(_ destination:Destination) async throws {try await recoverInputs(destination)}
 func install(_ checkpoint:ProviderCheckpoint) async throws {
  let value=State(chatID:-100,sendingID:1,byteCount:3,filename:"original.heic",temporaryID:50,fileID:7)
  try await ledger.saveProviderCheckpoint(ProviderCheckpoint(destinationID:checkpoint.destinationID,tag:checkpoint.tag,
    transferID:checkpoint.transferID,jobID:checkpoint.jobID,phase:.uncertain,inputsTerminal:false,payload:ProviderSupport.canonical(value)))
 }
''' + section(telegram, '    private struct Scope:', '    private let client:')
 + section(telegram, '    @discardableResult private func save(', '    private func handle(')
 + section(telegram, '    private func finish(', '    private func awaitResolution(')
 + section(telegram, '    private func resolve(', '    func recover(')
 + section(telegram, '    private func recoverInputs(', '    /// Settings/P6')
 + section(telegram, '    private func receipt(', '    private func incompleteHistory(') + '}\n')
pipeline = (ROOT / 'App/Adapters/PhotoLibrary/PhotoLibraryPipeline.swift').read_text()
coalescer = pipeline[pipeline.index('final class SourceProgressCoalescer:'):]
coalescer = coalescer[:coalescer.rindex('}')] + ' func closedForBoundary()->Bool {state.withLock{$0.closed}}\n}\n'
(out / 'ActualProgressCoalescer.swift').write_text('import Foundation\nimport os\nimport CloudifiedCore\n' + coalescer)
exporter = (ROOT / 'App/Adapters/PhotoLibrary/PhotoResourceExporter.swift').read_text()
body = exporter[exporter.index('private final class ExportRequest:'):].replace('private final class ExportRequest:', 'final class ExportRequest:')
body = body[:body.rindex('}')] + ' func forceStallForBoundary(){lock.withLock{lastActivity = -1000}; _ = cancelIfStalled()}\n}\n'
(out / 'ActualPhotoExport.swift').write_text('import Foundation\nimport CloudifiedCore\n' + body)
bridge = (ROOT / 'App/Adapters/Telegram/TDLibBridge.swift').read_text()
(out / 'Errors.swift').write_text('import Foundation\n' + section(bridge, 'public enum TDLibResponseLimit:', 'public final class TDLibBridge:'))
google = (ROOT / 'App/Adapters/GooglePhotos/GooglePhotosProviderAdapter.swift').read_text()
(out / 'ActualGoogleQueue.swift').write_text('''import Foundation
import CloudifiedCore
actor GoogleQueueHarness {
 private static let queueLimit = 4
 private static let queueBytes: Int64 = 64 * 1024 * 1024
 let ledger:Ledger, background:QueueInventoryBoundary?
 var busy=false
 init(_ ledger:Ledger,_ background:QueueInventoryBoundary){self.ledger=ledger;self.background=background}
 func allowsAnother(_ destination:Destination) async throws -> Bool {try await queuedBytes(destination) != nil}
''' + section(google, '    private func queuedBytes(', '    func cancelOwnedTransfers(') + '}\n')
continued = (ROOT / 'App/Adapters/System/BackupContinuation.swift').read_text()
(out / 'ActualContinuedProgress.swift').write_text('import Foundation\n' + section(continued, 'struct ContinuedWorkProgress {', '/// User-started continued processing'))
gpmc = (ROOT / 'App/Adapters/GooglePhotos/GPMCClient.swift').read_text()
(out / 'ActualAuthentication.swift').write_text('import Foundation\nactor AuthenticationHarness {\n private var authenticationTask: Task<Void, any Error>?\n private var completion: CheckedContinuation<Void, any Error>?\n private(set) var refreshes = 0\n private(set) var entrances = 0\n private func refreshCredential() async throws {\n  refreshes += 1\n  try await withCheckedThrowingContinuation { completion = $0 }\n }\n func complete(_ failure: Bool = false) {\n  let saved = completion; completion = nil\n  if failure {saved?.resume(throwing: URLError(.timedOut))} else {saved?.resume()}\n }\n' + section(gpmc, '    func authenticate() async throws {', '    private func refreshCredential()').replace('        try Task.checkCancellation()', '        entrances += 1\n        try Task.checkCancellation()', 1) + '}\n')
(out / 'ActualGoogleSettlement.swift').write_text('import Foundation\nimport CloudifiedCore\n'
    + section(gpmc, 'enum UploadPhase:', 'struct FileUploadResult:') + '''
actor GoogleSettlementHarness {
 let ledger:Ledger,files:FileLeaseStore,background:QueueInventoryBoundary?
 let session=GoogleCommitBoundary()
 init(_ ledger:Ledger,_ files:FileLeaseStore,_ background:QueueInventoryBoundary){self.ledger=ledger;self.files=files;self.background=background}
 func commits() async -> Int {await session.commits()}
 func failNextCommit(notSubmitted:Bool=false) async {await session.failNextCommit(notSubmitted:notSubmitted)}
 func settle(_ destination:Destination,finalize:Bool) async throws -> Set<UUID> {try await settleInputs(destination,finalize:finalize)}
 func install(_ transfer:RetainedTransfer) async throws {
  let original=transfer.resource.originals[0]
  let prepared=PreparedUpload(uploadURL:URL(string:"https://photos.googleapis.com/data/upload/uploadmedia/interactive?upload_id=boundary")!,
   hash:try ProviderSupport.hex(original.sha1,count:20),filename:"original.heic",modified:Date(),byteCount:original.byteCount)
  let state=State(prepared:[prepared],mediaKeys:[nil],didUpload:false)
  try await save(transfer.job.id,transfer.job.destination,transfer.resource,transfer.id,.transferring,state)
 }
''' + section(google, '    private struct State:', '    let session:')
    + section(google, '    private func settleInputs(', '    func inspect(')
    + section(google, '    private func reserveCommit(', '    /// Invoked only after')
    + section(google, '    private func decoded(', '    private func presenceFailure(') + '}\n')
(out / 'ActualReceiptRecovery.swift').write_text('import Foundation\nimport CloudifiedCore\n'
    + """
actor ReceiptRecoveryHarness {
 let ledger:Ledger, session:ReceiptRecoveryBoundary, background:QueueInventoryBoundary?
 private var busy=false
 private var contextLookupFails=false
 func failContextLookup(){contextLookupFails=true}
 func contextJob(_ id:UUID) async throws -> JobRecord {
  if contextLookupFails {throw CoreError.persistence(5)}
  return try await ledger.job(id)
 }
 init(_ ledger:Ledger,_ session:ReceiptRecoveryBoundary,background:QueueInventoryBoundary?=nil) {
  self.ledger=ledger;self.session=session;self.background=background
 }
 func verify(_ destination:Destination) async throws {
  guard try await ledger.selectedDestination(.google)?.id == destination.id else {throw CoreError.staleMapping}
 }
 func libraryEvent(_ stage:DiagnosticStage,_ destination:Destination) async {}
 func checkLibraryCandidate(_ destination:Destination,resource:ResourceRequirement,acceptedOriginals:Set<String>) async throws -> SafeFailure? {nil}
""" + section(google, '    private struct State:', '    let session:')
    + section(google, '    func inspect(', '    func upload(')
    + google[google.index('    private func reserveCommit('):].replace('ledger.job(checkpoint.jobID)', 'contextJob(checkpoint.jobID)'))
gpmc = (ROOT / 'App/Adapters/GooglePhotos/GPMCClient.swift').read_text()
(out / 'ActualHTTPFailure.swift').write_text('import Foundation\nimport CloudifiedCore\n'
    + section(gpmc, 'struct GoogleStatus:', '/// Current-request evidence')
    + """
struct HTTPFailureHarness {
 static func identityError(_ data:Data)->DiagnosticGoogleError? {nil}
 func check(_ data:Data,_ response:HTTPURLResponse) throws { _ = try checked(data,response) }
 func mediaKey(_ data:Data) throws -> String {try Self.commitKey(data)}
""" + section(gpmc, '    private func checked(', '    private func send(')
    + section(gpmc, '    private static func commitKey(', '    func forgetTransfer(') + '}\n')
googleSession = (ROOT / 'App/Adapters/GooglePhotos/GooglePhotosClientSession.swift').read_text()
(out / 'ActualGoogleTrace.swift').write_text('import Foundation\nimport CloudifiedCore\n'
    + """
actor GoogleTraceHarness {
 private let diagnosticSink:(@Sendable(EventOperation,EventContext,EventDecision,EventSeverity,SafeFailure?,TimeInterval?,Int64?,Int64?)async throws->Void)?
 init(_ ledger:Ledger) {
  diagnosticSink={op,context,decision,severity,failure,duration,bytes,expected in
   try await ledger.appendEvent(op,context:context,decision:decision,severity:severity,failure:failure,duration:duration,bytes:bytes,expectedBytes:expected)
  }
 }
 static func classify(_ error:GPMCError)->SafeFailure {SafeFailure(.transfer,domain:.google,code:error.httpStatus,cause:.providerRejected)}
 func success(_ owner:EventContext) async throws {let _:Int = try await traced(.googleCommit,owner:owner){1}}
 func probe(_ owner:EventContext,error:GPMCError) async {
  do {let _:Int = try await traced(.googleCommit,owner:owner){throw error}} catch {}
 }
""" + section(googleSession,'    private func traced<','    func authenticate(') + '}\n')
(out / 'ActualTelegramAdmission.swift').write_text('import Foundation\nimport CloudifiedCore\n'
    + """
actor TelegramAdmissionHarness {
 var streamFailure:SafeFailure?
 var pending:[Int:Bool]=[:]
 func fail(_ error:SafeFailure){streamFailure=error}
 func fill(){pending=Dictionary(uniqueKeysWithValues:(0..<8).map{($0,true)})}
""" + section(telegram,'    var canAcceptWork:', '    /// Includes potential native readers') + '}\n')
accounts = (ROOT / 'App/Application/AppEnvironment+Accounts.swift').read_text()
(out / 'ActualProviderEnable.swift').write_text('import Foundation\nimport CloudifiedCore\nextension ProviderEnableHarness {\n'
    + section(accounts, '    func setEnabled(', '    public func setWiFiOnly(') + '}\n')
background = (ROOT / 'App/Adapters/GooglePhotos/BackgroundFileUploadTransport.swift').read_text()
body = background[:background.index('final class CloudifiedAppDelegate:')].replace('import UIKit\n', '')
body = body.replace('config.waitsForConnectivity = true;', 'config.protocolClasses = [OfflineUploadProtocol.self]; config.waitsForConnectivity = true;')
(out / 'ActualBackgroundTransport.swift').write_text(body + """
extension BackgroundFileUploadTransport {
 func forceFailure(_ id:UUID) {lock.withLock {persistenceFailures[id]=SafeFailure(.invariant,domain:.core,cause:.invalidContract)}}
 func cachedInventory(_ id:UUID,new:Bool) throws -> Inventory {
  try lock.withLock {
   if new && tasks[id] == nil {let task=session.dataTask(with:URL(string:"https://photos.googleapis.com/fixture")!);task.taskDescription=id.uuidString;tasks[id]=task}
   return try inventoryLocked(id,current:[],newlySubmitted:new)
  }
 }
 func attachBoundaryWaiter(_ id:UUID) async throws -> FileUploadResult {
  try await withCheckedThrowingContinuation { continuation in
   lock.withLock {waiters[id]=Waiter(continuation:continuation,progress:{_,_ in})}
  }
 }
 func hasBoundaryWaiter(_ id:UUID)->Bool {lock.withLock {waiters[id] != nil}}
 func completeFailure(_ id:UUID) {
  let task=lock.withLock {tasks[id]!}
  urlSession(session,task:task,didCompleteWithError:URLError(.cancelled))
 }
}
""")
exports = (ROOT / 'App/Adapters/System/DiagnosticExportStore.swift').read_text()
a = exports.index('    init(layout:'); b = exports.index('    func export(', a)
(out / 'ActualDiagnosticExports.swift').write_text(exports[:a] + """
    init(boundaryRoot:URL) throws {root=boundaryRoot;try StorageLayout.prepareDirectory(root,fileManager:.default)}
""" + exports[b:])
(out / 'ActualCommitTimestamp.swift').write_text('import Foundation\nimport CloudifiedCore\nenum CommitTimestampHarness {\n'
    + section(gpmc, '    static func commitTimestamp(', '    static func commitProfile(') + '}\n')
with (out / 'ActualCommitTimestamp.swift').open('a') as marker:
    marker.write(section(gpmc, 'final class GoogleCommitDispatch:', 'struct GPMCError:'))
(out / 'ActualCommitSubmission.swift').write_text('import Foundation\nimport CloudifiedCore\n'
    + section(gpmc, 'enum UploadOutcome:', 'enum UploadPhase:').replace('UploadOutcome', 'CommitProbeOutcome')
    + """
actor CommitSubmissionHarness {
 let started:Bool
 init(started:Bool){self.started=started}
 private func commitReceipt(_ prepared:PreparedUpload,useQuota:Bool,saver:Bool,pairedStillHash:Data?,
   phase:@escaping @Sendable (UploadPhase)->Void,submission:GoogleCommitDispatch) async throws -> CommitProbeOutcome {
  if started {submission.markSubmitted()}
  throw CancellationError()
 }
""" + section(gpmc, '    func commit(_ prepared:', '    private func commitReceipt(').replace('UploadOutcome', 'CommitProbeOutcome') + '}\n')
presentation = (ROOT / 'App/Application/AppEnvironment+Presentation.swift').read_text()
(out / 'ActualFailureExplanation.swift').write_text((ROOT / 'App/Adapters/System/FailureExplanation.swift').read_text()
    + '\n' + presentation[presentation.index('extension Provider { var displayName:'):])
(out / 'ActualGoogleLibraryMatching.swift').write_text((ROOT / 'App/Adapters/GooglePhotos/GoogleLibraryMatching.swift').read_text().replace('extension GooglePhotosProviderAdapter', 'extension GoogleMatchingHarness'))
policy = (ROOT / 'App/Presentation/Settings/SettingsViewState.swift').read_text()
(out / 'ActualPlanPolicy.swift').write_text('import Foundation\n' + section(policy, 'public enum LivePhotoFallbackOption:', '/// Current step'))
(out / 'ActualUpdateRouting.swift').write_text('import Foundation\n' + """
actor UpdateRoutingHarness {
 let interest=TelegramUpdateInterest()
 var updateContinuations:[UUID:AsyncThrowingStream<TDLibResponse,any Error>.Continuation]=[:]
 var updateFilters:[UUID:Set<String>]=[:]
 var updatePredicates:[UUID:@Sendable(TDLibResponse)->Bool]=[:]
 var processingFailure:(any Error)?
 func subscribe(filtering:Bool=true) -> AsyncThrowingStream<TDLibResponse,any Error> {
  let pair=AsyncThrowingStream<TDLibResponse,any Error>.makeStream(bufferingPolicy:.bufferingOldest(16))
  let id=UUID();updateContinuations[id]=pair.continuation
  let filter=interest;if filtering {updatePredicates[id]={filter.accepts($0)}}
  return pair.stream
 }
 func configure(_ chat:Int64,_ ids:[Int32?],_ chats:Set<Int64>=[]){interest.setChatID(chat);interest.setPendingFiles(ids,chatIDs:chats)}
 func send(_ update:TDLibResponse){publish(update)}
 func failed()->Bool{processingFailure != nil}
 func unregisterUpdateContinuation(id:UUID){updateContinuations.removeValue(forKey:id);updatePredicates.removeValue(forKey:id)}
 func interruptInput(_ error:any Error){processingFailure=error;for c in updateContinuations.values{c.finish(throwing:error)}}
""" + section(session, '    private func publish(', '    /// Retain only') + '}\n')
files = [out / 'ActualUpdateRouting.swift', ROOT / 'scripts/regressions/TelegramUpdateRouting.swift', out / 'ActualPlanPolicy.swift', ROOT / 'App/Adapters/PhotoLibrary/UploadPlanProducer.swift', ROOT / 'App/Adapters/PhotoLibrary/ArchiveManifestBuilder.swift', ROOT / 'scripts/regressions/ManifestBoundary.swift', ROOT / 'scripts/regressions/AlbumExclusions.swift', out / 'ActualAuthentication.swift', ROOT / 'scripts/regressions/GoogleAuthenticationBoundary.swift', ROOT / 'App/Adapters/GooglePhotos/GoogleLibraryWire.swift', out / 'ActualGoogleLibraryMatching.swift', ROOT / 'scripts/regressions/GoogleRemoteIndex.swift', out / 'ActualReceiptRecovery.swift', out / 'ActualHTTPFailure.swift', out / 'ActualGoogleTrace.swift', out / 'ActualTelegramAdmission.swift', out / 'ActualBackgroundTransport.swift', out / 'ActualDiagnosticExports.swift', out / 'ActualCommitTimestamp.swift', out / 'ActualCommitSubmission.swift', ROOT / 'App/Adapters/System/StorageLayout.swift', ROOT / 'App/Adapters/GooglePhotos/Protobuf.swift', ROOT / 'scripts/regressions/AuditSecondPass.swift', out / 'ActualTelegramRequest.swift', out / 'ActualFailureExplanation.swift', ROOT / 'scripts/regressions/ProviderEnableBoundary.swift', out / 'ActualProviderEnable.swift', out / 'ActualGoogleSettlement.swift', ROOT / 'scripts/regressions/GoogleSubmissionBoundary.swift', out / 'ActualGoogleQueue.swift', out / 'ActualContinuedProgress.swift', ROOT / 'scripts/regressions/AuditRequestBoundary.swift', out / 'ActualBackupRequest.swift', out / 'ActualLocalReset.swift', ROOT / 'App/Adapters/System/DiagnosticReportUploader.swift', ROOT / 'App/Adapters/System/AppRuntime.swift', out / 'ActualTelegramSettlement.swift', ROOT / 'scripts/regressions/AuditBoundaries.swift', ROOT / 'App/Adapters/GooglePhotos/ForegroundFileUploadTransport.swift', ROOT / 'App/Adapters/PhotoLibrary/StreamingHasher.swift', ROOT / 'App/Adapters/PhotoLibrary/SourceRecipe.swift', ROOT / 'App/Adapters/PhotoLibrary/LosslessVideoPartSplitter.swift', out / 'ActualProgressCoalescer.swift', out / 'ActualPhotoExport.swift', ROOT / 'scripts/regressions/TelegramRecoveryBoundary.swift', ROOT / 'App/Adapters/Telegram/TelegramInputFiles.swift', ROOT / 'App/Presentation/Dashboard/DashboardViewState.swift', out / 'ActualNetworkPolicy.swift', out / 'ActualOwnedRecovery.swift', ROOT / 'scripts/regressions/CoreRegression.swift', ROOT / 'scripts/regressions/PresentationRecovery.swift', ROOT / 'App/Presentation/ScreenStateStore.swift', ROOT / 'App/Presentation/NotUploaded/NotUploadedViewState.swift', ROOT / 'scripts/regressions/CredentialKeyBoundary.swift', ROOT / 'App/Adapters/Security/KeychainCredentialStore.swift', ROOT / 'scripts/regressions/NativeProtocolBoundary.swift', ROOT / 'scripts/regressions/TelegramCensusBoundary.swift', ROOT / 'scripts/regressions/LaneIsolation.swift',
         ROOT / 'App/Adapters/Telegram/TDLibJSON.swift', ROOT / 'App/Adapters/Telegram/TelegramDocumentReference.swift',
         out / 'ActualCensus.swift', out / 'ActualResolution.swift', out / 'ActualProtocolRecovery.swift', out / 'Support.swift', out / 'Errors.swift']
run(['swiftc', *common, '-parse-as-library', *map(str, files), '-L', str(out),
     '-lCloudifiedCore', '-lCloudifiedDiagnostics', '-o', str(out / 'regressions')])
subprocess.run([str(out / 'regressions')], env=dict(os.environ, DYLD_LIBRARY_PATH=str(out), NSUnbufferedIO="YES"), check=True, timeout=60)
