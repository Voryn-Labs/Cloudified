// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CTDLib",
    platforms: [.iOS("26.0"), .macOS(.v13)],
    products: [.library(name: "CTDLib", targets: ["CTDLib"])],
    targets: [
        .target(
            name: "CTDLib",
            path: "Sources/CTDLib",
            publicHeadersPath: "include"
        )
    ]
)
