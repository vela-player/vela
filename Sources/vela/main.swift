// vela — ultra-light media player for macOS
// Copyright (C) 2026 vela contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import CMpv
import Foundation

let version = "0.1.0"
let args = Array(CommandLine.arguments.dropFirst())

func usage() -> Never {
    print("""
    vela \(version) — ultra-light media player
    usage: vela <file>            play (window arrives in Phase 2)
           vela --probe <file>    print media info and exit
           vela --version
    """)
    exit(0)
}

guard let first = args.first else { usage() }

do {
    switch first {
    case "--version", "-v":
        let api = mpv_client_api_version()
        print("vela \(version) (libmpv client API \(api >> 16).\(api & 0xffff))")
    case "--probe":
        guard args.count > 1 else { usage() }
        let p = try Player(headless: true)
        p.set("pause", "yes")
        p.set("ao", "null")
        try p.command(["loadfile", args[1]])
        guard p.wait(for: [MPV_EVENT_FILE_LOADED, MPV_EVENT_END_FILE]) == MPV_EVENT_FILE_LOADED else {
            fputs("vela: could not open \(args[1])\n", stderr); exit(1)
        }
        for (label, prop) in [("format", "file-format"), ("duration", "duration"),
                              ("video", "video-codec"), ("size", "video-params/w"),
                              ("audio", "audio-codec"), ("channels", "audio-params/channel-count"),
                              ("rate", "audio-params/samplerate"), ("hwdec", "hwdec")] {
            print(label.padding(toLength: 9, withPad: " ", startingAt: 0), p.string(prop) ?? "-")
        }
    case "-h", "--help":
        usage()
    default:
        // Phase 1: audio-only headless playback to prove the pipeline end to end.
        let p = try Player(headless: true)
        try p.command(["loadfile", first])
        print("playing \(first) (headless, Ctrl-C to stop)")
        p.wait(for: [MPV_EVENT_END_FILE], timeout: .infinity)
    }
} catch {
    fputs("vela: \(error)\n", stderr)
    exit(1)
}
