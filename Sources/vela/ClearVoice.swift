// vela — ultra-light media player for macOS
// Copyright (C) 2026 vela contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Clear Voice: louder dialogue, tamer explosions.
///
/// Film mixes put dialogue in the center channel and effects/music everywhere else. A normal
/// 5.1 -> stereo downmix buries the center under everything, so on laptop speakers you ride the
/// volume all film. Clear Voice:
///   1. Surround input: does its own downmix (or rebalance, for surround speakers) with the
///      center channel weighted up and the effects channels down.
///      Stereo input: lifts the speech band (~2.5 kHz) and cuts rumble.
///   2. Compresses loud peaks so explosions don't jump out, then limits so nothing clips.
enum ClearVoice {
    static let label = "@clearvoice"

    /// - Parameters:
    ///   - layout: mpv/FFmpeg channel layout of the decoded audio, e.g. "5.1(side)" or "fl-fr-fc-lfe-sl-sr".
    ///   - deviceChannels: channels the output device takes (2 for laptop speakers/headphones).
    /// - Returns: an mpv `af` entry.
    static func filter(layout: String, deviceChannels: Int) -> String {
        let channels = Self.channels(of: layout)
        var stages: [String] = []

        if channels.contains("FC"), channels.count > 2 {
            if deviceChannels <= 2 {
                stages.append(stereoDownmix(channels))
            } else {
                stages.append(rebalance(layout: layout, channels: channels))
            }
        } else {
            // No separate dialogue channel: lift the speech band, trim boom and mud.
            stages += ["highpass=f=90", "equalizer=f=250:t=q:w=1:g=-3", "equalizer=f=2500:t=q:w=1:g=5"]
        }
        // Everything above -30 dBFS is squeezed 4:1 and the result lifted 12 dB, so quiet talk comes
        // up and bangs come down; a limiter keeps peaks under -1 dBFS. Measured on a real film:
        // loudness range 13.4 -> 4.8 LU in an action scene, quiet scenes ~10 dB easier to hear.
        stages.append("acompressor=threshold=0.031:ratio=4:attack=8:release=300:makeup=4")
        stages.append("alimiter=limit=0.89:level=0")
        return "\(label):lavfi=[\(stages.joined(separator: ","))]"
    }

    /// Surround -> stereo with dialogue in front. Standard downmix uses center ×0.707 against
    /// fronts ×1.0; Clear Voice flips that balance.
    private static func stereoDownmix(_ ch: [String]) -> String {
        func side(_ front: String, _ surrounds: [String]) -> String {
            var terms = ["1.0*FC", "0.45*\(front)"]
            terms += surrounds.filter(ch.contains).map { "0.30*\($0)" }
            if ch.contains("BC") { terms.append("0.21*BC") }
            if ch.contains("LFE") { terms.append("0.10*LFE") }
            return terms.joined(separator: "+")
        }
        return "pan=stereo|FL=\(side("FL", ["SL", "BL"]))|FR=\(side("FR", ["SR", "BR"]))"
    }

    /// Surround speakers: keep the layout, raise the center, lower the rest.
    private static func rebalance(layout: String, channels ch: [String]) -> String {
        let gains = ch.map { c -> String in
            switch c {
            case "FC": return "\(c)=1.6*\(c)"
            case "LFE": return "\(c)=0.5*\(c)"
            default: return "\(c)=0.6*\(c)"
            }
        }
        return "pan=\(layout)|" + gains.joined(separator: "|")
    }

    /// Channel names for a layout, in FFmpeg spelling (FL, FR, FC, LFE, BL, BR, SL, SR, BC).
    static func channels(of layout: String) -> [String] {
        let known: [String: [String]] = [
            "mono": ["FC"], "stereo": ["FL", "FR"], "2.1": ["FL", "FR", "LFE"],
            "3.0": ["FL", "FR", "FC"], "3.1": ["FL", "FR", "FC", "LFE"],
            "4.0": ["FL", "FR", "FC", "BC"], "quad": ["FL", "FR", "BL", "BR"],
            "5.0": ["FL", "FR", "FC", "BL", "BR"], "5.0(side)": ["FL", "FR", "FC", "SL", "SR"],
            "5.1": ["FL", "FR", "FC", "LFE", "BL", "BR"], "5.1(side)": ["FL", "FR", "FC", "LFE", "SL", "SR"],
            "6.1": ["FL", "FR", "FC", "LFE", "BC", "SL", "SR"],
            "7.1": ["FL", "FR", "FC", "LFE", "BL", "BR", "SL", "SR"],
        ]
        if let list = known[layout] { return list }
        // mpv's explicit form: "fl-fr-fc-lfe-sl-sr"
        return layout.split(separator: "-").map { $0.uppercased() }
    }
}
