// swift-tools-version: 6.2
// Мост к ядру на Rust: XCFramework (core/scripts/build-xcframework.sh),
// сгенерированные UniFFI-привязки и @Observable-модель для интерфейса.
import PackageDescription

let package = Package(
    name: "GorionKit",
    platforms: [.macOS(.v26)],
    products: [.library(name: "GorionKit", targets: ["GorionKit"])],
    targets: [
        .binaryTarget(name: "GorionCoreFFI", path: "Frameworks/GorionCoreFFI.xcframework"),
        // Сгенерированный UniFFI код; собирается в режиме Swift 5, потому что
        // генератор не управляет строгой конкурентностью Swift 6.
        .target(
            name: "GorionCoreBindings",
            dependencies: ["GorionCoreFFI"],
            path: "Sources/GorionCoreFFI",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(name: "GorionKit", dependencies: ["GorionCoreBindings"]),
    ]
)
