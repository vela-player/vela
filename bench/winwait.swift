// winwait <owner-name-substring> <launch-epoch-seconds> <timeout-s>
// Prints seconds from launch until the app shows a visible window (>= 300x120 px, normal layer).
// Only apps that were not running before launch should be measured (the script checks this).
import CoreGraphics
import Foundation
let needle = CommandLine.arguments[1].lowercased()
let launch = Double(CommandLine.arguments[2])!
let timeout = Double(CommandLine.arguments[3]) ?? 20
while Date().timeIntervalSince1970 - launch < timeout {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    for w in list where (w["kCGWindowLayer"] as? Int) == 0 {
        let owner = (w["kCGWindowOwnerName"] as? String ?? "").lowercased()
        let b = w["kCGWindowBounds"] as? [String: Any] ?? [:]
        let width = (b["Width"] as? NSNumber)?.doubleValue ?? 0
        let height = (b["Height"] as? NSNumber)?.doubleValue ?? 0
        if owner.contains(needle), width >= 300, height >= 120 {
            print(String(format: "%.3f", Date().timeIntervalSince1970 - launch)); exit(0)
        }
    }
    usleep(5_000)
}
print("timeout"); exit(1)
