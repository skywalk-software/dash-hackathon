// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "EditorInteractionKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "EditorInteractionKit", targets: ["EditorInteractionKit"])],
    targets: [
        .target(name: "EditorInteractionKit"),
        .testTarget(name: "EditorInteractionKitTests", dependencies: ["EditorInteractionKit"])
    ]
)
