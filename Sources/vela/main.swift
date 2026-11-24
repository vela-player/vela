// vela — ultra-light media player for macOS
// Copyright (C) 2026 vela contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import CMpv
import Foundation

let version = "0.2.0"

func usage() -> Never {
    print("""
    vela \(version) — ultra-light media player

    usage: vela [--mpv-option=value ...] [file]
           vela --probe <file>    print media info and exit
           vela --version

    Any --key=value is passed to mpv, e.g. --start=3600 --mute=yes --volume=50
    """)
    exit(0)
}

// Split arguments into vela flags, mpv passthrough options and the file.
var mpvOptions: [(String, String)] = []
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
                              ("video", "video-codec"), ("width", "width"), ("height", "height"),
                              ("audio", "audio-codec"), ("channels", "track-list/1/demux-channel-count"),
                              ("rate", "track-list/1/demux-samplerate"), ("tracks", "track-list/count")] {
            print(label.padding(toLength: 9, withPad: " ", startingAt: 0), p.string(prop) ?? "-")
        }

    default:
        if let path = positional.first, !FileManager.default.fileExists(atPath: fileURL(path).path) {
            fputs("vela: no such file: \(path)\n", stderr); exit(1)
        }
        let app = NSApplication.shared
        let delegate = AppDelegate(file: positional.first.map(fileURL), mpvOptions: mpvOptions)
        app.delegate = delegate
        app.setActivationPolicy(.regular)  // dock icon + menu bar even as a bare CLI binary
        app.run()
    }
} catch {
    fputs("vela: \(error)\n", stderr)
    exit(1)
}
