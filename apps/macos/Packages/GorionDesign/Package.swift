// swift-tools-version: 6.2
// Дизайн-система Gorion для macOS: токены (из design/tokens.json),
// физическое движение и базовые компоненты. См. DESIGN.md.
import PackageDescription

let package = Package(
    name: "GorionDesign",
    platforms: [.macOS(.v26)],
    products: [.library(name: "GorionDesign", targets: ["GorionDesign"])],
    targets: [
        .target(name: "GorionDesign"),
        .testTarget(name: "GorionDesignTests", dependencies: ["GorionDesign"]),
    ]
)
