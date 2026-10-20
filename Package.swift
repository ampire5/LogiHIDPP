// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LogiHIDPP",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "LogiHIDPP", targets: ["LogiHIDPP"]),
        .executable(name: "logi-probe", targets: ["logi-probe"]),
    ],
    targets: [
        .target(name: "LogiHIDPP"),
        .executableTarget(name: "logi-probe", dependencies: ["LogiHIDPP"]),
        .testTarget(name: "LogiHIDPPTests", dependencies: ["LogiHIDPP"]),
    ],
    swiftLanguageModes: [.v6]
)
