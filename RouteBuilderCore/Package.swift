// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "RouteBuilderCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "RouteBuilderCore", targets: ["RouteBuilderCore"])
    ],
    targets: [
        // Pure logic and providers: no UIKit, no MapLibre, no SwiftUI.
        // Keeping it a separate package means the route math is testable on
        // macOS without booting a simulator.
        .target(name: "RouteBuilderCore"),
        .testTarget(name: "RouteBuilderCoreTests", dependencies: ["RouteBuilderCore"]),
    ]
)
