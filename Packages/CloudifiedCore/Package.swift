// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CloudifiedCore",
    platforms: [.iOS("26.0"), .macOS(.v13)],
    products: [.library(name: "CloudifiedCore", targets: ["CloudifiedCore"])],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "CloudifiedDiagnostics", path: "Sources/Diagnostics"),
        .target(name: "CloudifiedCore", dependencies: ["CSQLite", "CloudifiedDiagnostics"])
    ]
)
