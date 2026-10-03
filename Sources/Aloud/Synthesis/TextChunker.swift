import Foundation
import NaturalLanguage

/// Kokoro caps input at 510 phoneme tokens per call, which in practice is
/// roughly 1-2 sentences of English. Arbitrary selected text (a paragraph,
/// an article) must be split into smaller pieces before synthesis.
enum TextChunker {
    /// A conservative character-count proxy for the phoneme-token cap —
    /// exact phoneme counting would require running the G2P processor
    /// itself, which isn't exposed by KokoroSwift for a cheap pre-check.
    static let maxCharactersPerChunk = 400

    /// Playback can't start until the first chunk has fully synthesized, so
    /// a first sentence longer than this is split at its first clause break.
    static let firstChunkTarget = 80
    private static let firstClauseRange = 20...160

    /// Short sentences after the first chunk are merged up to this length,
    /// so a run of "Yes. OK. Sure." costs one synthesis call, not three.
    /// Kept well under `maxCharactersPerChunk`: Kokoro throws (and the chunk
    /// is skipped) past its token cap, so packing must never produce a
    /// chunk longer than a single sentence already could be.
    static let packTarget = 250

    static func chunks(for text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var sentences = splitIntoSentences(trimmed)
        sentences.replaceSubrange(0..<1, with: splitFirstClause(sentences[0]))

        var result: [String] = []
        for sentence in sentences {
            if sentence.count <= maxCharactersPerChunk {
                result.append(sentence)
            } else {
                result.append(contentsOf: splitLongSentence(sentence))
            }
        }
        return [result[0]] + pack(Array(result.dropFirst()))
    }

    /// Splits off the first clause (up to and including its punctuation) of
    /// a long first sentence. Leaves the sentence whole when there's no
    /// clause break in range: a cut at an arbitrary space would put an
    /// audible prosody break mid-phrase.
    private static func splitFirstClause(_ sentence: String) -> [String] {
        guard sentence.count > firstChunkTarget else { return [sentence] }
        let breaks = CharacterSet(charactersIn: ",;:—")
        var offset = 0
        for index in sentence.indices {
            offset += 1
            guard offset <= firstClauseRange.upperBound else { break }
            guard offset >= firstClauseRange.lowerBound,
                  sentence[index].unicodeScalars.allSatisfy(breaks.contains) else { continue }
            let tail = sentence[sentence.index(after: index)...].trimmingCharacters(in: .whitespaces)
            guard !tail.isEmpty else { break }
            return [String(sentence[...index]), tail]
        }
        return [sentence]
    }

    private static func pack(_ pieces: [String]) -> [String] {
        var result: [String] = []
        for piece in pieces {
            if let last = result.last, last.count + 1 + piece.count <= packTarget {
                result[result.count - 1] = last + " " + piece
            } else {
                result.append(piece)
            }
        }
        return result
    }

    private static func splitIntoSentences(_ text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var sentences: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty { sentences.append(sentence) }
            return true
        }
        return sentences.isEmpty ? [text] : sentences
    }

    private static func splitLongSentence(_ sentence: String) -> [String] {
        let pieces = sentence
            .components(separatedBy: CharacterSet(charactersIn: ",;—"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var result: [String] = []
        var current = ""
        for piece in pieces {
            let candidate = current.isEmpty ? piece : current + ", " + piece
            if candidate.count > maxCharactersPerChunk, !current.isEmpty {
                result.append(current)
                current = piece
            } else {
                current = candidate
            }
            // A single piece can itself exceed the cap — e.g. a long
            // run-on sentence with no commas/semicolons/dashes anywhere.
            // Without this, `current` would just carry the whole oversized
            // piece straight through, silently violating the cap this
            // function exists to enforce.
            while current.count > maxCharactersPerChunk {
                result.append(contentsOf: splitByWhitespace(current))
                current = ""
            }
        }
        if !current.isEmpty { result.append(current) }
        return result.isEmpty ? [sentence] : result
    }

    /// Last-resort split for a single piece with no punctuation to break
    /// on: chunk at the last space before the cap, or hard-cut mid-word if
    /// there's no space within range at all, so this always terminates.
    private static func splitByWhitespace(_ text: String) -> [String] {
        var remaining = Substring(text.trimmingCharacters(in: .whitespaces))
        var result: [String] = []
        while remaining.count > maxCharactersPerChunk {
            let splitIndex = remaining.index(remaining.startIndex, offsetBy: maxCharactersPerChunk)
            var breakIndex = remaining[..<splitIndex].lastIndex(of: " ") ?? splitIndex
            // Guarantees forward progress even in a degenerate case (e.g.
            // a leading space) that would otherwise leave breakIndex at
            // the very start and loop forever.
            if breakIndex <= remaining.startIndex { breakIndex = splitIndex }

            let piece = remaining[..<breakIndex].trimmingCharacters(in: .whitespaces)
            if !piece.isEmpty { result.append(piece) }
            remaining = Substring(remaining[breakIndex...].trimmingCharacters(in: .whitespaces))
        }
        if !remaining.isEmpty { result.append(String(remaining)) }
        return result
    }
}
