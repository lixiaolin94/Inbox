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
            path: "Sources/Inbox",
            // The asset catalog is for the Xcode bundle; the bare SPM binary has
            // no bundle to carry it.
            exclude: ["Resources"]
        ),
        .testTarget(
            name: "InboxTests",
            dependencies: ["Inbox"],
            path: "Tests/InboxTests"
        )
    ],
    swiftLanguageModes: [.v5]
)
