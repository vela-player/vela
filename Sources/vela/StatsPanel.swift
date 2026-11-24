// vela — ultra-light media player for macOS
// Copyright (C) 2026 vela contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import CoreAudio

/// The `I` panel: what is playing and how well, in plain words.
final class StatsPanel: NSVisualEffectView {
    private let stack = NSStackView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(lessThanOrEqualToConstant: 460),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }  // never blocks the video

    /// Sections of (label, value) rows; rows with an empty value are skipped.
    func show(_ sections: [(String, [(String, String?)])]) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (title, rows) in sections {
            let rows = rows.compactMap { label, value in value.flatMap { $0.isEmpty ? nil : (label, $0) } }
            guard !rows.isEmpty else { continue }

            let header = NSTextField(labelWithString: title.uppercased())
            header.font = .systemFont(ofSize: 10, weight: .bold)
            header.textColor = .secondaryLabelColor

            let grid = NSGridView(views: rows.map { label, value in
                let l = NSTextField(labelWithString: label)
                l.font = .systemFont(ofSize: 12)
                l.textColor = .secondaryLabelColor
                let v = NSTextField(labelWithString: value)
                v.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
                v.textColor = .white
                v.lineBreakMode = .byTruncatingMiddle
                v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                return [l, v]
            })
            grid.columnSpacing = 14
            grid.rowSpacing = 4
            grid.column(at: 0).width = 92

            let section = NSStackView(views: [header, grid])
            section.orientation = .vertical
            section.alignment = .leading
            section.spacing = 6
            stack.addArrangedSubview(section)
        }
    }
}

// MARK: - Collecting the values

extension Player {
    /// Everything the stats panel shows, already turned into readable text.
    func statsSections(window: NSWindow) -> [(String, [(String, String?)])] {
        let tracks = node("track-list") as? [[String: Any]] ?? []
        let video = tracks.first { $0["type"] as? String == "video" && $0["selected"] as? Bool == true }
        let audio = tracks.first { $0["type"] as? String == "audio" && $0["selected"] as? Bool == true }
        let sub = tracks.first { $0["type"] as? String == "sub" && $0["selected"] as? Bool == true }

        // File
        var chapter: String?
        if let c = int("chapter"), let n = int("chapters"), n > 0, c >= 0 {
            let title = string("chapter-list/\(c)/title")
            chapter = "\(c + 1) of \(n)" + (title.map { $0.hasPrefix("Chapter") ? "" : " · \($0)" } ?? "")
        }
        let file: [(String, String?)] = [
            ("Name", string("filename")),
            ("Size", int("file-size").map(Self.bytes)),
            ("Container", string("file-format")?.uppercased()),
            ("Chapter", chapter),
        ]

        // Video
        var videoRows: [(String, String?)] = []
        if video != nil, video?["albumart"] as? Bool != true {
            let w = int("video-params/w") ?? int("width"), h = int("video-params/h") ?? int("height")
            let pixfmt = string("video-params/pixelformat") ?? ""
            let hwfmt = string("video-params/hw-pixelformat") ?? ""
            let tenBit = [pixfmt, hwfmt].contains { $0.contains("10") || $0.contains("p010") || $0.contains("12") }
            let codec = Self.codecName(string("video-format"))
            let profile = (video?["codec-profile"] as? String).map { " \($0)" } ?? ""
            let hdr: String? = {
                switch string("video-params/gamma") {
                case "pq": return "HDR10 (PQ)"
                case "hlg": return "HLG"
                default: return "SDR"
                }
            }()
            let hw = string("hwdec-current").map { $0 == "no" || $0.isEmpty ? "Software" : "Hardware (VideoToolbox)" }
            videoRows = [
                ("Codec", codec.map { $0 + profile }),
                ("Resolution", w.flatMap { w in h.map { "\(w) × \($0)" + Self.aspect(Double(w), Double($0)) } }),
                ("Color", "\(tenBit ? "10-bit" : "8-bit") · \(hdr ?? "SDR") · \(string("video-params/primaries")?.uppercased() ?? "")"),
                ("Frame rate", double("container-fps").map { String(format: "%.3f fps", $0) }),
                ("Bitrate", double("video-bitrate").map(Self.bitrate)),
                ("Decoding", hw),
            ]
        }

        // Audio
        var audioRows: [(String, String?)] = []
        if audio != nil {
            let codec = Self.codecName(string("audio-codec-name"))
            let profile = audio?["codec-profile"] as? String
            let inCh = int("audio-params/channel-count"), outCh = int("audio-out-params/channel-count")
            var channels = inCh.map(Self.channels)
            if let i = inCh, let o = outCh, i != o { channels = "\(Self.channels(i)) → \(Self.channels(o)) for this device" }
            let atmos = (profile ?? "").contains("Atmos") ? " · Atmos" : ""
            audioRows = [
                ("Track", (audio?["lang"] as? String).flatMap { Locale.current.localizedString(forLanguageCode: $0)?.capitalized }
                    ?? audio?["title"] as? String),
                ("Codec", codec.map { $0 + atmos }),
                ("Channels", channels),
                ("Sample rate", int("audio-params/samplerate").map { String(format: "%.1f kHz", Double($0) / 1000) }),
                ("Bitrate", double("audio-bitrate").map(Self.bitrate)),
                ("Output", Self.defaultOutputDeviceName()),
            ]
        }

        // Playback
        let cacheBytes = ((node("demuxer-cache-state") as? [String: Any])?["fw-bytes"] as? Int64)
        let cacheSecs = double("demuxer-cache-duration")
        let drops = (int("frame-drop-count") ?? 0) + (int("decoder-frame-drop-count") ?? 0)
        let refresh = (window.screen ?? NSScreen.main)?.maximumFramesPerSecond
        let playback: [(String, String?)] = [
            ("Dropped", video == nil ? nil : drops == 0 ? "None" : "\(drops) frames"),
            ("A/V sync", double("avsync").map { String(format: "%+.1f ms", $0 * 1000) }),
            ("Buffered", cacheSecs.map { s in String(format: "%.0f s ahead", s) + (cacheBytes.map { " · " + Self.bytes($0) } ?? "") }),
            ("Display", refresh.map { "\($0) Hz · 16-bit float" }),
            ("Subtitles", sub.map { ($0["lang"] as? String).flatMap { Locale.current.localizedString(forLanguageCode: $0)?.capitalized }
                ?? ($0["title"] as? String) ?? "On" } ?? "Off"),
        ]

        return [("File", file), ("Video", videoRows), ("Audio", audioRows), ("Playback", playback)]
    }

    // MARK: formatting

    private static func codecName(_ c: String?) -> String? {
        guard let c else { return nil }
        let names = ["hevc": "HEVC (H.265)", "h264": "H.264", "av1": "AV1", "vp9": "VP9", "vp8": "VP8",
                     "mpeg2video": "MPEG-2", "mpeg4": "MPEG-4", "vc1": "VC-1", "prores": "ProRes",
                     "eac3": "Dolby Digital Plus (E-AC3)", "ac3": "Dolby Digital (AC3)", "truehd": "Dolby TrueHD",
                     "dts": "DTS", "aac": "AAC", "flac": "FLAC", "alac": "Apple Lossless", "opus": "Opus",
                     "mp3": "MP3", "vorbis": "Vorbis"]
        if c.hasPrefix("pcm") { return "PCM" }
        return names[c] ?? c.uppercased()
    }

    private static func channels(_ n: Int64) -> String {
        [1: "Mono", 2: "Stereo", 6: "5.1", 7: "6.1", 8: "7.1"][n] ?? "\(n) ch"
    }

    private static func bytes(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .binary)
    }

    private static func bitrate(_ bps: Double) -> String {
        bps >= 1_000_000 ? String(format: "%.1f Mbps", bps / 1_000_000) : String(format: "%.0f kbps", bps / 1000)
    }

    private static func aspect(_ w: Double, _ h: Double) -> String {
        let r = w / h
        let known: [(Double, String)] = [(2.39, "2.39:1"), (2.35, "2.35:1"), (2.0, "2:1"), (1.85, "1.85:1"),
                                         (16.0 / 9, "16:9"), (4.0 / 3, "4:3"), (1, "1:1")]
        return known.first { abs($0.0 - r) < 0.02 }.map { "  (\($0.1))" } ?? String(format: "  (%.2f:1)", r)
    }

    /// Name of the Mac's current output device, e.g. "MacBook Pro Speakers" or "AirPods Pro".
    static func defaultOutputDeviceName() -> String? {
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device) == noErr
        else { return nil }
        var name: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        addr.mSelector = kAudioObjectPropertyName
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &name) == noErr, let name else { return nil }
        return name.takeRetainedValue() as String
    }
}
