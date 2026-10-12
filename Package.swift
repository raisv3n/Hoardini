// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Hoardini",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "HoardiniCore", targets: ["HoardiniCore"]),
        .executable(name: "hoardini", targets: ["hoardini"]),
        .executable(name: "hoardini-host", targets: ["hoardini-host"]),
        .executable(name: "HoardiniApp", targets: ["HoardiniApp"]),
    ],
    targets: [
        .target(name: "HoardiniCore"),
        .executableTarget(name: "hoardini", dependencies: ["HoardiniCore"]),
        .executableTarget(name: "hoardini-host", dependencies: ["HoardiniCore"]),
        .executableTarget(name: "HoardiniApp", dependencies: ["HoardiniCore"]),
        .testTarget(name: "HoardiniCoreTests", dependencies: ["HoardiniCore"]),
    ]
)
