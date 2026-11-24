// vela — ultra-light media player for macOS
// Copyright (C) 2026 vela contributors
// SPDX-License-Identifier: GPL-3.0-or-later

#if compiler(>=6.2)
import AppKit
import CryptoKit
import SwiftUI
import Translation

/// The player side of AI subtitles: Subtitles-menu items, a background job that starts where you
/// are watching and fills in progressively, and a per-file cache so a film is only processed once.
@available(macOS 26.0, *)
@MainActor
final class AISubtitleController: NSObject {
    private let player: Player
    private weak var window: NSWindow?
    /// Ask the window controller to rebuild its menus (status text changed).
    var onChange: () -> Void = {}

    private var task: Task<Void, Never>?
    private var generator: AISubtitleGenerator?
    private var status: String?
    private var liveTrack: Int64?          // mpv sid of the track being filled in
    private var lastReload = Date.distantPast

    init(player: Player, window: NSWindow) {
        self.player = player
        self.window = window
    }

    // MARK: - Menu

    func addMenuItems(to menu: NSMenu) {
        menu.addItem(.separator())
        if let status {
            menu.addItem(withTitle: status, action: nil, keyEquivalent: "").isEnabled = false
            let stop = menu.addItem(withTitle: "Stop Generating", action: #selector(stopClicked), keyEquivalent: "")
            stop.target = self
            return
        }
        let source = sourceLanguageName
        let gen = menu.addItem(withTitle: "Generate Subtitles (\(source), on this Mac)", action: #selector(generateClicked(_:)),
                               keyEquivalent: "")
        gen.target = self
        gen.toolTip = "Listens to the dialogue and writes subtitles with Apple's on-device speech recognition. Nothing is uploaded."

        let translate = NSMenuItem(title: "Generate Translated Subtitles", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for code in Self.targetLanguages where code != sourceCode {
            let item = sub.addItem(withTitle: Self.name(code), action: #selector(generateClicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = code
        }
        translate.submenu = sub
        menu.addItem(translate)
    }

    @objc private func generateClicked(_ item: NSMenuItem) { start(target: item.representedObject as? String) }
    @objc private func stopClicked() { stop(); player.run("show-text", "Stopped generating subtitles", "2000") }

    // MARK: - Lifecycle

    /// New file: forget the old job, and offer any subtitles generated for this file before.
    func fileOpened(_ url: URL) {
        liveTrack = nil
        for file in cachedFiles(for: url) {
            player.run("sub-add", file.url.path, "auto", file.title)
        }
    }

    func stop() {
        generator?.cancel()
        task?.cancel()
        task = nil
        generator = nil
        setStatus(nil)
    }

    // MARK: - Job

    func start(target: String?) {
        guard task == nil, let url = window?.representedURL else { return }
        let duration = player.double("duration") ?? 0
        let here = max(0, (player.double("time-pos") ?? 0) - 2)
        let audio = Track.list(from: player.node("track-list")).first { $0.kind == .audio && $0.selected }
        let layout = player.string("current-tracks/audio/demux-channels")
        let source = sourceCode
        let title = target.map { "AI · \(Self.name($0)) (from \(Self.name(source)))" } ?? "AI · \(Self.name(source))"
        let tag = target ?? "orig"
        let partial = cacheURL(for: url, tag: tag, partial: true)
        let final = cacheURL(for: url, tag: tag, partial: false)

        setStatus(target == nil ? "Generating subtitles…" : "Preparing \(Self.name(target!))…")
        task = Task { [weak self] in
            guard let self else { return }
            if let target, !(await self.ensureTranslation(from: source, to: target)) { self.stop(); return }
            self.player.run("show-text", "Writing subtitles on your Mac. They'll appear as they're ready.", "3000")

            // Start where the viewer is, then go back and fill in the beginning.
            let passes: [(Double, Double?)] = here > 10 ? [(here, nil), (0, here)] : [(0, nil)]
            var all: [Cue] = []
            var covered = 0.0
            for (start, end) in passes {
                let gen = AISubtitleGenerator()
                self.generator = gen
                var o = AISubtitleGenerator.Options(media: url)
                o.audioTrack = audio?.id
                o.channelLayout = layout
                o.sourceLanguage = source
                o.targetLanguage = target
                o.start = start
                o.end = end
                let before = all, done = covered
                gen.onProgress = { cues, at in
                    Task { @MainActor [weak self] in
                        self?.progress(before + cues, covered: done + max(0, at - start), duration: duration,
                                       file: partial, title: title)
                    }
                }
                do {
                    all = before + (try await gen.run(o))
                } catch {
                    if !Task.isCancelled { self.fail(error) }
                    return
                }
                if Task.isCancelled { return }
                covered += (end ?? duration) - start
            }
            self.finish(AISubtitleGenerator.tidy(all), partial: partial, final: final, title: title)
        }
    }

    private func progress(_ cues: [Cue], covered: Double, duration: Double, file: URL, title: String) {
        guard task != nil else { return }
        let pct = duration > 0 ? min(99, Int(covered / duration * 100)) : 0
        setStatus("Generating subtitles… \(pct)%")
        // Rewriting and reloading the file every few seconds is plenty; mpv re-reads it cheaply.
        guard Date().timeIntervalSince(lastReload) > 3 || liveTrack == nil, !cues.isEmpty else { return }
        lastReload = Date()
        try? SRT.text(AISubtitleGenerator.tidy(cues)).write(to: file, atomically: true, encoding: .utf8)
        if let id = liveTrack {
            player.run("sub-reload", String(id))
        } else {
            player.run("sub-add", file.path, "select", title)
            liveTrack = player.int("sid")
        }
    }

    private func finish(_ cues: [Cue], partial: URL, final: URL, title: String) {
        try? FileManager.default.removeItem(at: final)
        try? SRT.text(cues).write(to: final, atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(at: partial)
        if let id = liveTrack { player.run("sub-remove", String(id)) }
        player.run("sub-add", final.path, "select", title)
        liveTrack = nil
        task = nil
        generator = nil
        setStatus(nil)
        player.run("show-text", "Subtitles ready: \(cues.count) lines", "3000")
    }

    private func fail(_ error: Error) {
        task = nil
        generator = nil
        setStatus(nil)
        let alert = NSAlert()
        alert.messageText = "Couldn't generate subtitles"
        alert.informativeText = "\(error)"
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    private func setStatus(_ s: String?) {
        status = s
        onChange()
    }

    // MARK: - Translation languages

    /// Translation languages are downloaded by macOS. If needed, show Apple's own download prompt
    /// (through a tiny invisible SwiftUI view, which is the only way to get it).
    private func ensureTranslation(from source: String, to target: String) async -> Bool {
        let s = Locale.Language(identifier: source), t = Locale.Language(identifier: target)
        switch await LanguageAvailability().status(from: s, to: t) {
        case .installed:
            return true
        case .unsupported:
            alert("\(Self.name(source)) → \(Self.name(target)) translation isn't available on this Mac.")
            return false
        case .supported:
            setStatus("Downloading \(Self.name(target))…")
            guard let window, let content = window.contentView else { return false }
            let ok = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                var host: NSView?
                let view = TranslationDownloadView(source: s, target: t) { ok in
                    host?.removeFromSuperview()
                    cont.resume(returning: ok)
                }
                let h = NSHostingView(rootView: view)
                h.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
                content.addSubview(h)
                host = h
            }
            if !ok { alert("The \(Self.name(target)) translation language wasn't downloaded.") }
            return ok
        @unknown default:
            return false
        }
    }

    private func alert(_ text: String) {
        let a = NSAlert()
        a.messageText = text
        if let window { a.beginSheetModal(for: window) } else { a.runModal() }
    }

    // MARK: - Cache

    private struct CachedFile { let url: URL; let title: String }

    private static var cacheDir: URL {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("vela/transcripts", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// Same file (path, size, modification date) -> same key.
    private func key(for url: URL) -> String {
        let a = try? FileManager.default.attributesOfItem(atPath: url.path)
        let id = "\(url.path)|\((a?[.size] as? NSNumber)?.int64Value ?? 0)|\((a?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
        return SHA256.hash(data: Data(id.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
    }

    private func cacheURL(for url: URL, tag: String, partial: Bool) -> URL {
        Self.cacheDir.appendingPathComponent("\(key(for: url)).\(tag)\(partial ? ".partial" : "").srt")
    }

    private func cachedFiles(for url: URL) -> [CachedFile] {
        let k = key(for: url)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: Self.cacheDir.path)) ?? []
        return names.filter { $0.hasPrefix(k + ".") && $0.hasSuffix(".srt") && !$0.contains(".partial") }.sorted().map { name in
            let tag = name.dropFirst(k.count + 1).dropLast(4)
            let title = tag == "orig" ? "AI · \(Self.name(sourceCode))" : "AI · \(Self.name(String(tag)))"
            return CachedFile(url: Self.cacheDir.appendingPathComponent(name), title: title)
        }
    }

    // MARK: - Languages

    /// The spoken language: the audio track's tag, else the Mac's language.
    private var sourceCode: String {
        let lang = player.string("current-tracks/audio/lang")
        return AISubtitleGenerator.locale(for: lang).language.languageCode?.identifier ?? "en"
    }

    private var sourceLanguageName: String { Self.name(sourceCode) }

    /// The Mac's languages first, then widely used ones.
    static var targetLanguages: [String] {
        var out: [String] = []
        let mine = Locale.preferredLanguages.compactMap { Locale(identifier: $0).language.languageCode?.identifier }
        for c in mine + ["en", "hi", "es", "fr", "de", "it", "pt", "zh", "ja", "ko", "ar", "ru", "tr", "nl", "pl"]
            where !out.contains(c) { out.append(c) }
        return out
    }

    static func name(_ code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code)?.capitalized ?? code
    }
}

/// Invisible view whose only job is to obtain a TranslationSession from SwiftUI and ask macOS to
/// download the language pair (macOS shows its own confirmation).
@available(macOS 26.0, *)
private struct TranslationDownloadView: View {
    let source: Locale.Language
    let target: Locale.Language
    let done: (Bool) -> Void
    @State private var config: TranslationSession.Configuration?

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .translationTask(config) { session in
                do {
                    try await session.prepareTranslation()
                    done(true)
                } catch {
                    done(false)
                }
            }
            .onAppear { config = .init(source: source, target: target) }
    }
}
#endif
