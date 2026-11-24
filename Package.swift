// swift-tools-version:5.9
import PackageDescription

let brew = "/opt/homebrew"

let package = Package(
    name: "vela",
    platforms: [.macOS(.v13)],
    targets: [
        .systemLibrary(name: "CMpv", path: "Sources/CMpv"),
        .executableTarget(
            name: "vela",
            dependencies: ["CMpv"],
            cSettings: [.unsafeFlags(["-I\(brew)/include"])],
            swiftSettings: [.unsafeFlags(["-Xcc", "-I\(brew)/include"])],
            linkerSettings: [.unsafeFlags(["-L\(brew)/lib", "-Xlinker", "-rpath", "-Xlinker", "\(brew)/lib"])]
        ),
    ]
)
