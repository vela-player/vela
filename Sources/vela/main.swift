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

    On-device AI (macOS 26+):
           vela --ai-subtitles <file> [--to=hi]           write subtitles (SRT) to stdout
           vela --ask <file|srt> --at=<sec> "question"     EXPERIMENTAL, can be wrong
           vela --recap <file|srt> --at=<sec>              EXPERIMENTAL, can be wrong

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
    case "--ai-subtitles": mode = "aisubs"
    case "--ask": mode = "ask"
    case "--recap": mode = "recap"
    case "--clear-voice-filter": mode = "cvfilter"   // dev: print the Clear Voice filter for <layout> <device channels>
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

    case "aisubs":
        #if !compiler(>=6.2)
        fputs("vela: this build was made without AI subtitles (needs the macOS 26 SDK to compile)\n", stderr); exit(1)
        #else
        // vela --ai-subtitles movie.mkv [--to=hi] [--from=en] [--start=600] [--end=900] > movie.srt
        guard let path = positional.first else { usage() }
        guard #available(macOS 26.0, *) else { fputs("vela: AI subtitles need macOS 26 or newer\n", stderr); exit(1) }
        let opt = Dictionary(mpvOptions.map { ($0.0, $0.1) }, uniquingKeysWith: { $1 })
        let url = fileURL(path)
        let probe = try Player(headless: true, options: [("pause", "yes"), ("ao", "null")])
        try probe.command(["loadfile", url.path])
        guard probe.wait(for: [MPV_EVENT_FILE_LOADED, MPV_EVENT_END_FILE]) == MPV_EVENT_FILE_LOADED else {
            fputs("vela: could not open \(path)\n", stderr); exit(1)
        }
        let audio = Track.list(from: probe.node("track-list")).first { $0.kind == .audio && $0.selected }
        let gen = AISubtitleGenerator()
        var o = AISubtitleGenerator.Options(media: url)
        o.audioTrack = audio?.id
        o.channelLayout = probe.string("current-tracks/audio/demux-channels")
        o.sourceLanguage = opt["from"] ?? audio?.lang
        o.targetLanguage = opt["to"]
        o.start = opt["start"].flatMap(Double.init) ?? 0
        o.end = opt["end"].flatMap(Double.init)
        let t0 = Date()
        gen.onProgress = { cues, at in fputs("\r  \(cues.count) lines · up to \(formatTime(at, showHours: true))   ", stderr) }
        let done = DispatchSemaphore(value: 0)
        Task {
            do {
                let cues = try await gen.run(o)
                print(SRT.text(cues))
                fputs("\n  done: \(cues.count) lines in \(String(format: "%.1f", Date().timeIntervalSince(t0))) s\n", stderr)
            } catch {
                fputs("\nvela: \(error)\n", stderr); exit(1)
            }
            done.signal()
        }
        done.wait()
        #endif

    case "ask", "recap":
        // vela --ask movie.mkv|subs.srt --at=3600 "who is the man in the coat?"
        // vela --recap movie.mkv|subs.srt --at=3600
        guard let path = positional.first else { usage() }
        #if !compiler(>=6.2)
        fputs("vela: this build was made without on-device AI (needs the macOS 26 SDK)\n", stderr); exit(1)
        #else
        guard #available(macOS 26.0, *) else { fputs("vela: needs macOS 26 or newer\n", stderr); exit(1) }
        guard MovieMemory.isAvailable else { fputs("vela: turn on Apple Intelligence in System Settings first\n", stderr); exit(1) }
        let opt = Dictionary(mpvOptions.map { ($0.0, $0.1) }, uniquingKeysWith: { $1 })
        let at = opt["at"].flatMap(Double.init) ?? .infinity
        let url = fileURL(path)
        let done = DispatchSemaphore(value: 0)
        Task {
            do {
                var cues: [Cue]
                if url.pathExtension.lowercased() == "srt" {
                    cues = SRT.parse(try String(contentsOf: url, encoding: .utf8))
                } else {
                    fputs("  listening to the dialogue…\n", stderr)
                    cues = try await AISubtitleGenerator().run(AISubtitleGenerator.Options(media: url))
                }
                let memory = MovieMemory(cues: cues, cacheFile: FileManager.default.temporaryDirectory
                    .appendingPathComponent("vela-memory-\(Int(MovieMemory.sceneLength))s-\(url.path.utf8.reduce(UInt64(5381)) { ($0 &* 33) ^ UInt64($1) }).json"))
                let t0 = Date()
                if mode == "recap" {
                    print(try await memory.recap(at: at))
                } else {
                    let q = positional.dropFirst().joined(separator: " ")
                    let a = try await memory.ask(q, at: at)
                    print(a.text)
                    for e in a.evidence { print("   [\(MovieMemory.stamp(e.start))] \(e.text.replacingOccurrences(of: "\n", with: " "))") }
                }
                fputs(String(format: "  (%.1f s)\n", Date().timeIntervalSince(t0)), stderr)
            } catch {
                fputs("vela: \(MovieMemory.explain(error))\n", stderr); exit(1)
            }
            done.signal()
        }
        done.wait()
        #endif

    case "cvfilter":
        print(ClearVoice.filter(layout: positional.first ?? "5.1(side)", deviceChannels: Int(positional.dropFirst().first ?? "2") ?? 2))

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
