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
        }
        if !current.isEmpty { result.append(current) }
        return result.isEmpty ? [sentence] : result
    }
}
