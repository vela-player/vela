// vela — ultra-light media player for macOS
// Copyright (C) 2026 vela contributors
// SPDX-License-Identifier: GPL-3.0-or-later

#if compiler(>=6.2)
import Foundation
import FoundationModels

/// EXPERIMENTAL (command line only): in testing on a full film it answered early, simple questions
/// correctly and never spoiled, but refused some action dialogue, missed answerable questions and
/// wrote vague recaps. See ROADMAP.md.
///
/// "Ask the movie" and "Catch me up", answered by Apple's on-device model from what the viewer has
/// already heard. Spoiler safety comes from construction: nothing after the current position is ever
/// put in front of the model.
///
/// The model reads ~4k tokens, a film's dialogue is 15-25k words, so the film is remembered as
/// 5-minute scene summaries (made once, cached) plus the exact recent lines plus lines that match
/// the question.
@available(macOS 26.0, *)
final class MovieMemory: @unchecked Sendable {
    struct Answer: Sendable {
        var revealed: Bool
        var text: String
        var evidence: [Cue]
    }

    /// 2.5 minutes keeps even the busiest scene comfortably inside the model's window.
    static let sceneLength = 150.0

    /// Film dialogue is full of threats, violence and swearing, which the default guardrails refuse
    /// to process. This mode is Apple's setting for transforming content the user already has.
    static let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)

    /// Prompt budget in tokens, leaving room for instructions, schema and the answer in the 4k window.
    static let promptBudget = 2600

    /// Conservative token estimate. Measured on film dialogue: about 1.37 characters per token
    /// (the exact counter, tokenCount(for:), needs macOS 26.4).
    static func tokens(_ s: String) -> Int { Int(Double(s.utf8.count) / 1.2) }

    /// Plain-language versions of the model's errors.
    static func explain(_ error: Error) -> String {
        guard let e = error as? LanguageModelSession.GenerationError else { return "\(error)" }
        switch e {
        case .guardrailViolation, .refusal:
            return "Apple's on-device model declined to process this part of the film (its safety filter flags some film dialogue)."
        case .exceededContextWindowSize:
            return "This part of the film has more dialogue than the on-device model can read at once."
        case .assetsUnavailable:
            return "Apple Intelligence models aren't ready yet. Check System Settings → Apple Intelligence & Siri."
        default:
            return "The on-device model couldn't answer: \(e.localizedDescription)"
        }
    }

    static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    let cues: [Cue]
    private let cacheFile: URL
    private var summaries: [Int: String]
    private let lock = NSLock()

    init(cues: [Cue], cacheFile: URL) {
        self.cues = cues.sorted { $0.start < $1.start }
        self.cacheFile = cacheFile
        let data = try? Data(contentsOf: cacheFile)
        let saved = data.flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        summaries = Dictionary(uniqueKeysWithValues: saved.compactMap { k, v in Int(k).map { ($0, v) } })
    }

    // MARK: - Scene summaries

    /// Summaries of every complete scene before `t`, making any that are missing.
    func scenes(before t: Double, progress: (@Sendable (Int, Int) -> Void)? = nil) async throws -> [(Int, String)] {
        let count = Int(t / Self.sceneLength)
        var out: [(Int, String)] = []
        for i in 0..<count {
            progress?(i, count)
            if let s = lock.withLock({ summaries[i] }) { out.append((i, s)); continue }
            let lines = cues.filter { $0.start >= Double(i) * Self.sceneLength && $0.start < Double(i + 1) * Self.sceneLength }
            let summary: String
            if lines.isEmpty {
                summary = "(no dialogue)"
            } else {
                let session = LanguageModelSession(model: Self.model, instructions: Self.rules)
                var text = lines.map { $0.text.replacingOccurrences(of: "\n", with: " ") }.joined(separator: "\n")
                while Self.tokens(text) > Self.promptBudget, text.count > 400 {
                    text = String(text.suffix(text.count * 4 / 5))
                }
                let r = try await session.respond(
                    to: "Subtitle lines:\n\(text)\n\nSummarize what these lines say in at most two short sentences. Only what the lines literally say; names only if they appear in the lines; say 'someone' when the speaker is unclear.",
                    options: GenerationOptions(sampling: .greedy))
                summary = r.content.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            lock.withLock { summaries[i] = summary }
            save()
            out.append((i, summary))
        }
        return out
    }

    private func save() {
        let dict = lock.withLock { Dictionary(uniqueKeysWithValues: summaries.map { (String($0.key), $0.value) }) }
        if let data = try? JSONEncoder().encode(dict) { try? data.write(to: cacheFile, options: .atomic) }
    }

    // MARK: - Ask

    func ask(_ question: String, at t: Double) async throws -> Answer {
        let notYet = Answer(revealed: false, text: "That hasn't been revealed yet.", evidence: [])
        let heard = cues.filter { $0.start <= t }
        guard !heard.isEmpty else { return notYet }

        let scenes = try await scenes(before: t)
        let recentFrom = max(t - 240, Double(Int(t / Self.sceneLength)) * Self.sceneLength - 60)
        let recent = heard.filter { $0.start >= recentFrom }
        let older = heard.filter { $0.start < recentFrom }
        let matched = Self.matching(question, in: older, limit: 8)
        let (context, shown) = Self.fit(scenes: scenes, lines: (matched + recent).sorted { $0.start < $1.start })

        let session = LanguageModelSession(model: Self.model, instructions: Self.rules)
        let r = try await session.respond(to: "\(context)\n\nQuestion: \(question)", schema: Self.answerSchema,
                                          options: GenerationOptions(sampling: .greedy))
        let revealed = (try? r.content.value(Bool.self, forProperty: "revealed")) ?? false
        let text = ((try? r.content.value(String.self, forProperty: "answer")) ?? "").trimmingCharacters(in: .whitespaces)
        let ids = (try? r.content.value([Int].self, forProperty: "evidence")) ?? []
        // Lines are numbered L1, L2, … in the prompt; keep only numbers that point at a line we showed.
        let evidence = ids.compactMap { shown.indices.contains($0 - 1) ? shown[$0 - 1] : nil }
        let debug = ProcessInfo.processInfo.environment["VELA_ASK_DEBUG"] != nil
        if debug { fputs("    [pass1] revealed=\(revealed) answer=\(text) lines=\(ids)\n", stderr) }
        guard revealed, !text.isEmpty, !evidence.isEmpty else { return notYet }

        // Second opinion: do the quoted lines really say this? Catches confident guesses such as
        // naming a character from an unrelated line.
        // The checker must also copy the exact words that support the claim, and we confirm those words
        // really are in the cited lines. A yes/no alone is too easy to say.
        let check = LanguageModelSession(model: Self.model, instructions: "You check claims strictly against quoted subtitle lines. Use no outside knowledge.")
        let v = try await check.respond(
            to: "Lines:\n\(Self.block(evidence))\n\nQuestion: \(question)\nClaimed answer: \(text)\n\nIs every part of the claimed answer stated in these lines?",
            schema: Self.verdictSchema, options: GenerationOptions(sampling: .greedy))
        let supported = (try? v.content.value(Bool.self, forProperty: "supported")) ?? false
        let quote = (try? v.content.value(String.self, forProperty: "quote")) ?? ""
        let quoteFound = Self.contains(Self.block(evidence), quote)
        if debug { fputs("    [verify] supported=\(supported) quote=\"\(quote)\" found=\(quoteFound)\n", stderr) }
        guard supported, quoteFound else { return notYet }
        return Answer(revealed: true, text: text, evidence: evidence)
    }

    // MARK: - Catch me up

    func recap(at t: Double) async throws -> String {
        let heard = cues.filter { $0.start <= t }
        guard heard.count >= 3 else { return "Not much has been said yet." }
        let scenes = try await scenes(before: t)
        let tail = heard.filter { $0.start >= Double(Int(t / Self.sceneLength)) * Self.sceneLength }
        let (context, _) = Self.fit(scenes: scenes, lines: tail)
        let session = LanguageModelSession(model: Self.model, instructions: Self.rules)
        let r = try await session.respond(
            to: "\(context)\n\nWrite a 'previously' recap for someone returning to this film: at most three short sentences. Only say what the lines and notes above literally say; refer to people only by names that appear in them; if who said something is unclear, say 'someone'. No timestamps.",
            options: GenerationOptions(sampling: .greedy))
        return r.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Prompt pieces

    static let rules = """
    You help someone watching a film. You only know the subtitle lines and scene notes they have heard so far. \
    Treat the film as one you have never seen: do not use outside knowledge about any film, book or comic. \
    Subtitle lines have no speaker names; do not assume who said a line unless the line itself makes it clear. \
    Only state what the material directly supports; do not add names, relationships, motives or events. \
    If the material does not answer a question, the answer has not been revealed yet.
    """

    static let answerSchema: GenerationSchema = try! GenerationSchema(root: DynamicGenerationSchema(name: "Answer", properties: [
        .init(name: "revealed", description: "True only if the given lines directly answer the question.",
              schema: .init(type: Bool.self)),
        .init(name: "answer", description: "One or two sentences answering from the lines; empty if not revealed.",
              schema: .init(type: String.self)),
        .init(name: "evidence", description: "The numbers of the lines that support the answer, e.g. 12 for line L12.",
              schema: .init(arrayOf: .init(type: Int.self), maximumElements: 3)),
    ]), dependencies: [])

    static let verdictSchema: GenerationSchema = try! GenerationSchema(root: DynamicGenerationSchema(name: "Verdict", properties: [
        .init(name: "supported", description: "True only if the lines directly state everything in the claimed answer.", schema: .init(type: Bool.self)),
        .init(name: "quote", description: "The exact words copied from the lines that state the answer; empty if none.", schema: .init(type: String.self)),
    ]), dependencies: [])

    /// Case- and punctuation-insensitive "does `text` contain `quote`" (at least two words).
    static func contains(_ text: String, _ quote: String) -> Bool {
        func norm(_ s: String) -> String {
            s.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " }.reduce(into: "") { $0.append($1) }
                .split(separator: " ").joined(separator: " ")
        }
        let q = norm(quote)
        return q.split(separator: " ").count >= 2 && norm(text).contains(q)
    }

    static func stamp(_ t: Double) -> String {
        let s = Int(t)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    static func block(_ lines: [Cue]) -> String {
        lines.map { "[\(stamp($0.start))] \($0.text.replacingOccurrences(of: "\n", with: " "))" }.joined(separator: "\n")
    }

    /// Scene notes + numbered lines (L1, L2, …), trimmed with the model's own token counter to fit
    /// the prompt budget: oldest scene notes go first, then the oldest lines.
    static func fit(scenes: [(Int, String)], lines: [Cue]) -> (String, [Cue]) {
        var notes = scenes.map { "[\(stamp(Double($0.0) * sceneLength))–\(stamp(Double($0.0 + 1) * sceneLength))] \($0.1)" }
        var kept = lines
        func render() -> String {
            var parts: [String] = []
            if !notes.isEmpty { parts.append("Scene notes so far:\n" + notes.joined(separator: "\n")) }
            let numbered = kept.enumerated().map { "L\($0.offset + 1) [\(stamp($0.element.start))] \($0.element.text.replacingOccurrences(of: "\n", with: " "))" }
            parts.append("Subtitle lines (most recent last):\n" + numbered.joined(separator: "\n"))
            return parts.joined(separator: "\n\n")
        }
        var text = render()
        while tokens(text) > promptBudget {
            if notes.count > 2 { notes.removeFirst(max(1, notes.count / 5)) }
            else if kept.count > 8 { kept.removeFirst(max(1, kept.count / 5)) }
            else if !notes.isEmpty { notes.removeFirst() }
            else { break }
            text = render()
        }
        return (text, kept)
    }

    /// Older lines sharing the question's meaningful words.
    static func matching(_ question: String, in lines: [Cue], limit: Int) -> [Cue] {
        let stop: Set<String> = ["the", "a", "an", "is", "are", "was", "were", "who", "what", "why", "how", "when", "where",
                                 "did", "does", "do", "he", "she", "they", "it", "to", "of", "and", "in", "on", "for", "this", "that",
                                 "with", "his", "her", "their", "about", "just", "say", "said"]
        func words(_ s: String) -> Set<String> {
            Set(s.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "'" }.map(String.init).filter { $0.count > 2 && !stop.contains($0) })
        }
        let q = words(question)
        guard !q.isEmpty else { return [] }
        return lines.map { ($0, words($0.text).intersection(q).count) }.filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }.prefix(limit).map { $0.0 }
    }
}

extension SRT {
    static func parse(_ text: String) -> [Cue] {
        text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n").compactMap { block in
            let l = block.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard let i = l.firstIndex(where: { $0.contains("-->") }), i + 1 < l.count else { return nil }
            let parts = l[i].components(separatedBy: "-->")
            func secs(_ s: String) -> Double? {
                let p = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".").split(separator: ":")
                guard p.count == 3, let h = Double(p[0]), let m = Double(p[1]), let x = Double(p[2]) else { return nil }
                return h * 3600 + m * 60 + x
            }
            guard parts.count == 2, let a = secs(parts[0]), let b = secs(parts[1]) else { return nil }
            return Cue(start: a, end: b, text: l[(i + 1)...].joined(separator: "\n"))
        }
    }
}
#endif
