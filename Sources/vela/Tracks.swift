// vela — ultra-light media player for macOS
// Copyright (C) 2026 vela contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// One audio, video or subtitle track from mpv's `track-list`.
struct Track {
    enum Kind: String { case video, audio, sub }

    let id: Int64
    let kind: Kind
    let title: String?
    let lang: String?
    let codec: String?
    let profile: String?
    let channels: Int64?
    let selected: Bool
    let isDefault: Bool
    let forced: Bool
    let external: Bool
    let hearingImpaired: Bool

    init?(_ map: [String: Any]) {
        guard let id = map["id"] as? Int64, let kind = Kind(rawValue: map["type"] as? String ?? "") else { return nil }
        self.id = id
        self.kind = kind
        title = (map["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        lang = map["lang"] as? String
        codec = map["codec"] as? String
        profile = map["codec-profile"] as? String
        channels = map["demux-channel-count"] as? Int64
        selected = map["selected"] as? Bool ?? false
        isDefault = map["default"] as? Bool ?? false
        forced = map["forced"] as? Bool ?? false
        external = map["external"] as? Bool ?? false
        hearingImpaired = map["hearing-impaired"] as? Bool ?? false
    }

    static func list(from node: Any?) -> [Track] {
        (node as? [Any] ?? []).compactMap { ($0 as? [String: Any]).flatMap(Track.init) }
    }

    /// e.g. "English — E-AC3 Atmos 5.1" or "English (SDH) — SRT".
    var label: String {
        var name = languageName ?? title ?? "Track \(id)"
        if let title, languageName != nil, !title.localizedCaseInsensitiveContains(name) { name += " · \(title)" }
        var tags: [String] = []
        if hearingImpaired { tags.append("SDH") }
        if forced { tags.append("Forced") }
        if external { tags.append("External") }
        tags.removeAll { name.localizedCaseInsensitiveContains($0) }  // title already says "SDH"
        if !tags.isEmpty { name += " (\(tags.joined(separator: ", ")))" }
        return [name, formatDescription].compactMap { $0 }.joined(separator: " — ")
    }

    private var languageName: String? {
        guard let lang, !lang.isEmpty, lang != "und" else { return nil }
        return Locale.current.localizedString(forLanguageCode: lang)?.capitalized ?? lang
    }

    private var formatDescription: String? {
        let names = ["eac3": "E-AC3", "ac3": "AC3", "truehd": "TrueHD", "dts": "DTS", "aac": "AAC",
                     "flac": "FLAC", "opus": "Opus", "mp3": "MP3", "alac": "ALAC", "vorbis": "Vorbis",
                     "subrip": "SRT", "ass": "ASS", "hdmv_pgs_subtitle": "PGS", "dvd_subtitle": "VobSub",
                     "webvtt": "WebVTT", "mov_text": "Text"]
        var parts: [String] = []
        if let codec {
            if codec.hasPrefix("pcm") { parts.append("PCM") }
            else if codec == "dts", let profile, profile.contains("HD") { parts.append(profile) }  // DTS-HD MA
            else { parts.append(names[codec] ?? codec.uppercased()) }
        }
        if let profile, profile.contains("Atmos") { parts.append("Atmos") }
        if kind == .audio, let ch = channels {
            parts.append([1: "Mono", 2: "Stereo", 6: "5.1", 7: "6.1", 8: "7.1"][ch] ?? "\(ch) ch")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

/// File extensions that are loaded as subtitles when dropped or opened.
let subtitleExtensions: Set<String> = ["srt", "ass", "ssa", "vtt", "sub", "sup", "idx", "smi", "txt"]
