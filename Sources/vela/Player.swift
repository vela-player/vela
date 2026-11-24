// vela — ultra-light media player for macOS
// Copyright (C) 2026 vela contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import CMpv
import Foundation

/// Thin owner of one mpv instance.
final class Player {
    let handle: OpaquePointer

    /// Called on the main thread for every mpv event (GUI mode only).
    var onEvent: ((UnsafePointer<mpv_event>) -> Void)?

    /// - Parameters:
    ///   - headless: no video output (probe / CLI audio).
    ///   - options: extra mpv options (`key=value`) applied last, e.g. from the command line.
    init(headless: Bool = false, options: [(String, String)] = []) throws {
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
        set("input-default-bindings", "no")
        if headless {
            set("vo", "null")
        } else {
            set("vo", "libmpv")      // frames come to us through the render API
            set("keep-open", "yes")  // stay on the last frame at end of file
            set("idle", "yes")       // window may open with no file
        }
        for (k, v) in options { set(k, v) }
        try check(mpv_initialize(handle), "mpv_initialize")
    }

    deinit { mpv_terminate_destroy(handle) }

    // MARK: - Options, properties, commands

    func set(_ name: String, _ value: String) {
        mpv_set_option_string(handle, name, value)
    }

    func setProperty(_ name: String, _ value: String) {
        mpv_set_property_string(handle, name, value)
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

    /// Fire-and-forget command for UI actions (errors are not interesting there).
    func run(_ args: String...) { try? command(args) }

    func string(_ name: String) -> String? {
        guard let p = mpv_get_property_string(handle, name) else { return nil }
        defer { mpv_free(p) }
        return String(cString: p)
    }

    func int(_ name: String) -> Int64? {
        var v: Int64 = 0
        return mpv_get_property(handle, name, MPV_FORMAT_INT64, &v) >= 0 ? v : nil
    }

    /// Ask mpv to send MPV_EVENT_PROPERTY_CHANGE whenever `name` changes.
    func observe(_ name: String, _ format: mpv_format) {
        mpv_observe_property(handle, 0, name, format)
    }

    // MARK: - Events

    /// GUI mode: mpv wakes us, we drain its queue on the main thread.
    func startEventPump() {
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        mpv_set_wakeup_callback(handle, { ctx in
            let player = Unmanaged<Player>.fromOpaque(ctx!).takeUnretainedValue()
            DispatchQueue.main.async { player.drainEvents() }
        }, ctx)
    }

    private func drainEvents() {
        while let ev = mpv_wait_event(handle, 0), ev.pointee.event_id != MPV_EVENT_NONE {
            onEvent?(ev)
            if ev.pointee.event_id == MPV_EVENT_SHUTDOWN { return }
        }
    }

    /// Headless mode: block until mpv emits one of `ids` (or shutdown), returning the id seen.
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
