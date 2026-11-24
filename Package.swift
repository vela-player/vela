// swift-tools-version:5.9
// vela — ultra-light media player for macOS
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import PackageDescription

/// Where libmpv lives: $MPV_PREFIX, then $HOMEBREW_PREFIX (set during `brew install`),
/// then the default Homebrew location for Apple Silicon or Intel.
let mpvPrefix: String = {
    let env = ProcessInfo.processInfo.environment
    if let p = env["MPV_PREFIX"] ?? env["HOMEBREW_PREFIX"] { return p }
    for p in ["/opt/homebrew", "/usr/local"] where FileManager.default.fileExists(atPath: "\(p)/include/mpv/client.h") {
        return p
    }
    return "/opt/homebrew"
}()

let package = Package(
    name: "vela",
    platforms: [.macOS(.v13)],
    targets: [
        .systemLibrary(name: "CMpv", path: "Sources/CMpv"),
        .executableTarget(
            name: "vela",
            dependencies: ["CMpv"],
            cSettings: [.unsafeFlags(["-I\(mpvPrefix)/include"])],
            swiftSettings: [.unsafeFlags(["-Xcc", "-I\(mpvPrefix)/include", "-Xcc", "-DGL_SILENCE_DEPRECATION"])],
            linkerSettings: [.unsafeFlags(["-L\(mpvPrefix)/lib", "-Xlinker", "-rpath", "-Xlinker", "\(mpvPrefix)/lib"])]
        ),
    ]
)
