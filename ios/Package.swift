// swift-tools-version: 5.9
import PackageDescription

let package = Package(name: "YokaiSync", platforms: [.macOS(.v13)],
    targets: [.target(name: "SyncCore", path: "Yokai/SyncCore"),
              .testTarget(name: "SyncCoreTests", dependencies: ["SyncCore"], path: "Tests")])
