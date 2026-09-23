// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RunOnSleep",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "RunOnSleep", targets: ["RunOnSleep"]),
        .executable(name: "RunOnSleepHelper", targets: ["RunOnSleepHelper"])
    ],
    targets: [
        .target(name: "RunOnSleepCore"),
        .executableTarget(name: "RunOnSleep", dependencies: ["RunOnSleepCore"]),
        .executableTarget(name: "RunOnSleepHelper", dependencies: ["RunOnSleepCore"]),
        .testTarget(name: "RunOnSleepCoreTests", dependencies: ["RunOnSleepCore"])
    ],
    swiftLanguageModes: [.v5]
)
