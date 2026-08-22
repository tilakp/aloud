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

    static func chunks(for text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var result: [String] = []
        for sentence in splitIntoSentences(trimmed) {
            if sentence.count <= maxCharactersPerChunk {
                result.append(sentence)
            } else {
                result.append(contentsOf: splitLongSentence(sentence))
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
