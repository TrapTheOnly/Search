// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Search",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Search", targets: ["SearchApp"])
    ],
    targets: [
        // The window and its types live here. The product is still named
        // Search: a thin executable calls through.
        .target(
            name: "Search",
            path: "Sources/Search",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "SearchApp",
            dependencies: ["Search"],
            path: "Sources/SearchApp",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
