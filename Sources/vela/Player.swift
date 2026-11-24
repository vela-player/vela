// vela — ultra-light media player for macOS
// Copyright (C) 2026 vela contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import CMpv
import Foundation

/// Thin owner of one mpv instance. Phase 1: headless; rendering arrives in Phase 2.
final class Player {
    let handle: OpaquePointer

    init(headless: Bool = false) throws {
        guard let h = mpv_create() else { throw VelaError.mpv("mpv_create failed") }
        handle = h
        // Tuned defaults for huge, high-bitrate files (see SPEC.md).
        set("hwdec", "videotoolbox")
        set("video-sync", "audio")
        set("cache", "yes")
        set("demuxer-max-bytes", "256MiB")
        set("demuxer-max-back-bytes", "64MiB")
        set("audio-channels", "auto")
        set("terminal", "no")
        if headless { set("vo", "null") }
        try check(mpv_initialize(handle), "mpv_initialize")
    }

    deinit { mpv_terminate_destroy(handle) }

    func set(_ name: String, _ value: String) {
        mpv_set_option_string(handle, name, value)
    }

    func command(_ args: [String]) throws {
        var cargs = args.map { strdup($0) } + [nil]
        defer { cargs.forEach { free($0) } }
        let rc = cargs.withUnsafeMutableBufferPointer { buf in
            buf.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: buf.count) {
                mpv_command(handle, $0)
            }
        }
        try check(rc, args.joined(separator: " "))
    }

    func string(_ name: String) -> String? {
        guard let p = mpv_get_property_string(handle, name) else { return nil }
        defer { mpv_free(p) }
        return String(cString: p)
    }

    /// Blocks until mpv emits `id` (or shutdown/error), returning the event id seen.
    @discardableResult
    func wait(for ids: Set<mpv_event_id>, timeout: Double = 10) -> mpv_event_id {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard let ev = mpv_wait_event(handle, 0.5)?.pointee else { continue }
            if ids.contains(ev.event_id) || ev.event_id == MPV_EVENT_SHUTDOWN { return ev.event_id }
        }
        return MPV_EVENT_NONE
    }

    private func check(_ rc: Int32, _ what: String) throws {
        if rc < 0 { throw VelaError.mpv("\(what): \(String(cString: mpv_error_string(rc)))") }
    }
}

enum VelaError: Error, CustomStringConvertible {
    case mpv(String)
    var description: String { switch self { case .mpv(let m): return "mpv error: \(m)" } }
}
