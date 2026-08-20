// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Inbox",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "Inbox",
            path: "Sources/Inbox"
        ),
        .testTarget(
            name: "InboxTests",
            dependencies: ["Inbox"],
            path: "Tests/InboxTests"
        )
    ],
    swiftLanguageModes: [.v5]
)
