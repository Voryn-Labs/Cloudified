import Foundation
import Network

struct NetworkPolicySnapshot: Sendable, Equatable {
    let available: Bool
    let wifi: Bool
    let constrained: Bool
    let expensive: Bool
}
/// One passive monitor. Connectivity is a policy input, never an internet/auth proof.
final class NetworkPolicyMonitor: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let continuation: AsyncStream<NetworkPolicySnapshot>.Continuation
    let events: AsyncStream<NetworkPolicySnapshot>
    init() {
        let stream = AsyncStream<NetworkPolicySnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        events = stream.stream; continuation = stream.continuation
        let sink = continuation
        monitor.pathUpdateHandler = { path in
            sink.yield(NetworkPolicySnapshot(available: path.status == .satisfied,
                wifi: path.usesInterfaceType(.wifi), constrained: path.isConstrained, expensive: path.isExpensive))
        }
        monitor.start(queue: DispatchQueue(label: "Cloudified.network-policy", qos: .utility))
    }
    func stop() { monitor.cancel(); continuation.finish() }
    deinit { monitor.cancel(); continuation.finish() }
}
