// vela — ultra-light media player for macOS
// Copyright (C) 2026 vela contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import CMpv
import Foundation

let version = "1.0.0"

func usage() -> Never {
    print("""
    vela \(version) — ultra-light media player

    usage: vela [--mpv-option=value ...] [file]
           vela --probe <file>    print media info and exit
           vela --version

    Any --key=value is passed to mpv, e.g. --start=3600 --mute=yes --volume=50
    Defaults can live in ~/.config/vela/config, one key=value per line.
    """)
    exit(0)
}

/// ~/.config/vela/config (or $XDG_CONFIG_HOME/vela/config): one mpv option per line.
///     # comment
///     volume=70
///     --sub-font-size=40      (leading dashes optional)
func loadConfig() -> [(String, String)] {
    let env = ProcessInfo.processInfo.environment
    let base = env["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
    let url = base.appendingPathComponent("vela/config")
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
    return text.split(whereSeparator: \.isNewline).compactMap { raw in
        var line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("#") { return nil }
        while line.hasPrefix("-") { line.removeFirst() }
        guard let eq = line.firstIndex(of: "=") else { return (line, "yes") }
        return (line[..<eq].trimmingCharacters(in: .whitespaces),
                line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces))
    }
}

// Split arguments into vela flags, mpv passthrough options and the file.
// Config file first, so command-line options win.
var mpvOptions: [(String, String)] = loadConfig()
var positional: [String] = []
var mode = "play"
for arg in CommandLine.arguments.dropFirst() {
    switch arg {
    case "-h", "--help": usage()
    case "-v", "--version": mode = "version"
    case "--probe": mode = "probe"
    case _ where arg.hasPrefix("--"):
        let body = arg.dropFirst(2)
        if let eq = body.firstIndex(of: "=") {
            mpvOptions.append((String(body[..<eq]), String(body[body.index(after: eq)...])))
        } else {
            mpvOptions.append((String(body), "yes"))
        }
    default: positional.append(arg)
    }
}

func fileURL(_ path: String) -> URL {
    URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
}

do {
    switch mode {
    case "version":
        let api = mpv_client_api_version()
        print("vela \(version) (libmpv client API \(api >> 16).\(api & 0xffff))")

    case "probe":
        guard let path = positional.first else { usage() }
        let p = try Player(headless: true, options: [("pause", "yes"), ("ao", "null")])
        try p.command(["loadfile", fileURL(path).path])
        guard p.wait(for: [MPV_EVENT_FILE_LOADED, MPV_EVENT_END_FILE]) == MPV_EVENT_FILE_LOADED else {
            fputs("vela: could not open \(path)\n", stderr); exit(1)
        }
        for (label, prop) in [("format", "file-format"), ("duration", "duration"),
                              ("video", "video-codec"), ("width", "width"), ("height", "height")] {
            print(label.padding(toLength: 9, withPad: " ", startingAt: 0), p.string(prop) ?? "-")
        }
        for t in Track.list(from: p.node("track-list")) where t.kind != .video {
            let mark = t.selected ? "*" : " "
            print("\(t.kind.rawValue.padding(toLength: 5, withPad: " ", startingAt: 0)) \(mark) \(t.id)  \(t.label)")
        }

    default:
        if let path = positional.first, !FileManager.default.fileExists(atPath: fileURL(path).path) {
            fputs("vela: no such file: \(path)\n", stderr); exit(1)
        }
        let app = NSApplication.shared
        let delegate = AppDelegate(file: positional.first.map(fileURL), mpvOptions: mpvOptions)
        app.delegate = delegate
        app.setActivationPolicy(.regular)  // dock icon + menu bar even as a bare CLI binary
        // Ctrl-C / kill in the terminal: quit normally so the resume position is saved.
        var signalSources: [DispatchSourceSignal] = []
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { NSApp.terminate(nil) }
            src.resume()
            signalSources.append(src)
        }
        app.run()
    }
} catch {
    fputs("vela: \(error)\n", stderr)
    exit(1)
}
