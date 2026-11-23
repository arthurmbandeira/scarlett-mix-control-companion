// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ScarlettDeviceProbe",
    platforms: [.macOS(.v12)],
    products: [
        .executable(name: "ScarlettDeviceProbe", targets: ["ScarlettDeviceProbe"])
    ],
    targets: [
        .executableTarget(name: "ScarlettDeviceProbe"),
        .testTarget(name: "ScarlettDeviceProbeTests", dependencies: ["ScarlettDeviceProbe"])
    ]
)