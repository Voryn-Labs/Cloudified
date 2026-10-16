import Combine

/// Each screen observes only its own state. Upload byte progress must not
/// invalidate Settings, navigation, or a diagnostic page the user is reading.
@MainActor
public final class ScreenStateStore<Value: Equatable>: ObservableObject {
    @Published private var storage: Value
    public init(_ value: Value) { storage = value }
    public var value: Value {
        get { storage }
        set {
            guard newValue != storage else { return }
            storage = newValue
        }
    }
}
