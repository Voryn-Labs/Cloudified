import SwiftUI

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, night
    var id: String { rawValue }
    var title: String {
        switch self { case .system: "System"; case .light: "Light"; case .night: "Night" }
    }
    var colorScheme: ColorScheme? {
        switch self { case .system: nil; case .light: .light; case .night: .dark }
    }
}
