// vela — ultra-light media player for macOS
// Copyright (C) 2026 vela contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import AVFAudio
import CMpv
import CoreMedia
import Foundation
import Speech
import Translation

// The speech APIs ship with the macOS 26 SDK (Swift 6.2). Older toolchains build vela without them.
#if compiler(>=6.2)

/// One subtitle line, in seconds from the start of the media.
struct Cue: Sendable {
    var start: Double
    var end: Double
    var text: String
}

enum SRT {
    static func text(_ cues: [Cue]) -> String {
        cues.enumerated().map { i, c in "\(i + 1)\n\(time(c.start)) --> \(time(c.end))\n\(c.text)\n" }
            .joined(separator: "\n")
    }

    static func time(_ t: Double) -> String {
        let ms = Int((max(t, 0) * 1000).rounded())
        return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
    }
}

enum AISubtitleError: Error, CustomStringConvertible {
    case speechUnsupported(String)
    case translationUnavailable(String, String)
    case audio(String)

    var description: String {
        switch self {
        case .speechUnsupported(let l): return "On-device speech recognition doesn't support \(l) on this Mac."
        case .translationUnavailable(let s, let t):
            return "Translation from \(s) to \(t) isn't installed. Add it in System Settings → General → Language & Region → Translation Languages."
        case .audio(let m): return "Couldn't read the audio: \(m)"
        }
    }
}

/// Generates subtitles on-device: dialogue audio -> Apple speech recognition -> (optional) Apple translation.
/// Everything stays on the Mac; nothing is uploaded. Requires macOS 26 (SpeechAnalyzer).
/// Pulls 0.5 s PCM buffers from the pipe mpv writes to, one at a time, on a background queue.
final class PCMSource: @unchecked Sendable {
    private let format: AVAudioFormat
    private let queue = DispatchQueue(label: "vela.ai.pcm")
    private var handle: FileHandle?
    private let fifo: URL
    private let isCancelled: () -> Bool
    private var finished = false

    init(fifo: URL, format: AVAudioFormat, isCancelled: @escaping () -> Bool) {
        self.fifo = fifo
        self.format = format
        self.isCancelled = isCancelled
    }

    func next() async -> AVAudioPCMBuffer? {
        await withCheckedContinuation { cont in queue.async { cont.resume(returning: self.read()) } }
    }

    private func read() -> AVAudioPCMBuffer? {
        if finished || isCancelled() { return nil }
        if handle == nil { handle = FileHandle(forReadingAtPath: fifo.path) }  // blocks until mpv opens the pipe
        guard let handle else { finished = true; return nil }
        let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
        let want = Int(format.sampleRate / 2) * bytesPerFrame
        var data = Data()
        while data.count < want, let chunk = try? handle.read(upToCount: want - data.count), !chunk.isEmpty {
            data.append(chunk)
        }
        let frames = data.count / bytesPerFrame
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else {
            finished = true
            try? handle.close()
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        data.withUnsafeBytes { raw in
            buffer.audioBufferList.pointee.mBuffers.mData!.copyMemory(from: raw.baseAddress!, byteCount: frames * bytesPerFrame)
        }
        return buffer
    }
}

@available(macOS 26.0, *)
final class AISubtitleGenerator: @unchecked Sendable {
    struct Options: Sendable {
        var media: URL
        var audioTrack: Int64?        // mpv aid; nil = default
        var channelLayout: String?    // e.g. "5.1(side)" — lets us use just the center (dialogue) channel
        var sourceLanguage: String?   // track language (e.g. "eng"); nil = Mac's language
        var targetLanguage: String?   // translate into this (e.g. "hi"); nil = keep original
        var start: Double = 0
        var end: Double?
    }

    /// Called (on an arbitrary thread) with all cues so far and how far into the media we are (seconds).
    var onProgress: (@Sendable ([Cue], Double) -> Void)?
    private var cancelled = false
    private var extractor: Player?

    func cancel() {
        cancelled = true
        if let e = extractor { e.run("quit") }
    }

    func run(_ o: Options) async throws -> [Cue] {
        // 1. Speech model for the audio's language (downloaded once by macOS if missing).
        let wanted = Self.locale(for: o.sourceLanguage)
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: wanted) else {
            throw AISubtitleError.speechUnsupported(wanted.localizedString(forIdentifier: wanted.identifier) ?? wanted.identifier)
        }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [],
                                            attributeOptions: [.audioTimeRange])
        if let install = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await install.downloadAndInstall()
        }

        // 2. Translation session, if asked and different from the spoken language.
        var translator: TranslationSession?
        if let target = o.targetLanguage.map(Locale.Language.init(identifier:)),
           target.languageCode != locale.language.languageCode {
            let status = await LanguageAvailability().status(from: locale.language, to: target)
            guard status == .installed else {
                throw AISubtitleError.translationUnavailable(Self.name(locale.language), Self.name(target))
            }
            translator = TranslationSession(installedSource: locale.language, target: target)
        }

        // 3. Stream the dialogue audio out of a headless mpv at the analyzer's preferred format.
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
            ?? AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
        let fifo = FileManager.default.temporaryDirectory.appendingPathComponent("vela-ai-\(UUID().uuidString).pcm")
        guard mkfifo(fifo.path, 0o600) == 0 else { throw AISubtitleError.audio("mkfifo failed") }
        defer { unlink(fifo.path) }
        try startExtractor(o, fifo: fifo, format: format)
        // The analyzer pulls audio when it's ready for more, so nothing is dropped while the model
        // loads and memory stays flat; mpv simply waits on the pipe in between.
        let source = PCMSource(fifo: fifo, format: format, isCancelled: { [weak self] in self?.cancelled ?? true })
        let stream = AsyncStream<AnalyzerInput>(unfolding: { await source.next().map { AnalyzerInput(buffer: $0) } })

        // 4. Transcribe, cut into cues, translate in batches, report as we go.
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        var cues: [Cue] = []
        let collect = Task { () -> [Cue] in
            var pending: [Cue] = []
            for try await result in transcriber.results {
                var fresh = Self.cues(from: result, offset: o.start)
                if let translator, !fresh.isEmpty {
                    pending += fresh
                    guard pending.count >= 8 else { continue }   // translate a few lines at a time
                    fresh = try await Self.translate(pending, with: translator)
                    pending = []
                }
                cues += fresh
                self.onProgress?(cues, fresh.last?.end ?? o.start)
            }
            if let translator, !pending.isEmpty { cues += try await Self.translate(pending, with: translator) }
            return cues
        }
        if let last = try await analyzer.analyzeSequence(stream) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        cues = Self.tidy(try await collect.value)
        onProgress?(cues, cues.last?.end ?? o.start)
        return cues
    }

    // MARK: - Audio

    private func startExtractor(_ o: Options, fifo: URL, format: AVAudioFormat) throws {
        var opts: [(String, String)] = [
            ("vid", "no"), ("sid", "no"), ("ao", "pcm"), ("ao-pcm-file", fifo.path), ("ao-pcm-waveheader", "no"),
            ("untimed", "yes"), ("audio-samplerate", String(Int(format.sampleRate))), ("audio-channels", "mono"),
            ("audio-format", format.commonFormat == .pcmFormatFloat32 ? "floatp" : "s16"),
            ("start", String(o.start)), ("volume", "100"), ("mute", "no"), ("audio-display", "no"),
        ]
        if let end = o.end { opts.append(("end", String(end))) }
        if let aid = o.audioTrack { opts.append(("aid", String(aid))) }
        // Film dialogue lives in the center channel: listening only to it removes most music and effects.
        if let layout = o.channelLayout, ClearVoice.channels(of: layout).contains("FC"),
           ClearVoice.channels(of: layout).count > 2 {
            opts.append(("af", "lavfi=[pan=mono|c0=FC]"))
        }
        let p = try Player(headless: true, options: opts)
        extractor = p
        try p.command(["loadfile", o.media.path])
        Thread {
            p.wait(for: [MPV_EVENT_END_FILE], timeout: .infinity)
        }.start()
    }

    // MARK: - Cues

    /// Turns one recognition result into readable subtitle cues: break on pauses, sentence ends,
    /// ~84 characters (two lines of 42) or ~6 seconds.
    static func cues(from result: SpeechTranscriber.Result, offset: Double) -> [Cue] {
        var cues: [Cue] = []
        var text = "", start: Double?, end = 0.0
        func flush() {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty, let s = start { cues.append(Cue(start: s, end: max(end, s + 1.0), text: wrap(t))) }
            text = ""; start = nil
        }
        for run in result.text.runs {
            let piece = String(result.text[run.range].characters)
            guard let range = run.audioTimeRange else { text += piece; continue }
            let s = offset + range.start.seconds, e = offset + range.end.seconds
            if let st = start, s - end > 0.7 || e - st > 6 || text.count + piece.count > 84 { flush() }
            if start == nil { start = s }
            text += piece
            end = e
            if let last = piece.trimmingCharacters(in: .whitespaces).last, ".?!。？！".contains(last), text.count > 25 { flush() }
        }
        flush()
        return cues
    }

    /// Sort and stop each line before the next one starts (short lines are padded to 1 s,
    /// which can otherwise overlap the following line).
    static func tidy(_ cues: [Cue]) -> [Cue] {
        var c = cues.sorted { $0.start < $1.start }
        for i in c.indices.dropLast() where c[i].end > c[i + 1].start - 0.04 {
            c[i].end = max(c[i].start + 0.3, c[i + 1].start - 0.04)
        }
        return c
    }

    /// Two balanced lines when a cue is long.
    static func wrap(_ t: String) -> String {
        guard t.count > 42 else { return t }
        let mid = t.index(t.startIndex, offsetBy: t.count / 2)
        let space = t[mid...].firstIndex(of: " ") ?? t[..<mid].lastIndex(of: " ")
        guard let space else { return t }
        return t[..<space].trimmingCharacters(in: .whitespaces) + "\n" + t[t.index(after: space)...].trimmingCharacters(in: .whitespaces)
    }

    static func translate(_ cues: [Cue], with session: TranslationSession) async throws -> [Cue] {
        let requests = cues.map { TranslationSession.Request(sourceText: $0.text.replacingOccurrences(of: "\n", with: " ")) }
        let responses = try await session.translations(from: requests)
        return zip(cues, responses).map { Cue(start: $0.start, end: $0.end, text: wrap($1.targetText)) }
    }

    // MARK: - Languages

    /// "eng" / "en" / nil -> a Locale for speech recognition.
    static func locale(for lang: String?) -> Locale {
        guard let lang, !lang.isEmpty, lang != "und" else { return Locale.current }
        let code = Locale.Language(identifier: lang).languageCode?.identifier(.alpha2) ?? lang
        return Locale(identifier: code)
    }

    static func name(_ l: Locale.Language) -> String {
        Locale.current.localizedString(forLanguageCode: l.languageCode?.identifier ?? "") ?? l.minimalIdentifier
    }
}

#endif
