import Foundation

/// Cuts a streaming answer into speakable pieces, so VOID can start talking after the
/// first sentence instead of waiting for the whole reply.
struct SentenceChunker {
    private var buffer = ""
    /// The first piece is cut early (at a comma) so VOID starts speaking sooner;
    /// later pieces wait for whole sentences, which sound better.
    private var emittedCount = 0

    mutating func feed(_ text: String) -> [String] {
        buffer += text
        var pieces: [String] = []
        while let end = nextBoundary() {
            let piece = String(buffer[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            buffer = String(buffer[end...])
            if !piece.isEmpty {
                pieces.append(piece)
                emittedCount += 1
            }
        }
        return pieces
    }

    /// Whatever is left when the stream ends.
    mutating func flush() -> String? {
        let rest = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""
        return rest.isEmpty ? nil : rest
    }

    private func nextBoundary() -> String.Index? {
        var count = 0
        var index = buffer.startIndex
        while index < buffer.endIndex {
            let char = buffer[index]
            count += 1
            let next = buffer.index(after: index)
            if char == "\n", count >= 2 {
                return next
            }
            if ".!?…".contains(char), next < buffer.endIndex, buffer[next].isWhitespace, count >= 14 {
                return next
            }
            // Pieces ramp up in size: the first is short so its voice is ready while the
            // opener is still playing, the next a bit longer, then whole sentences.
            let commaAfter = emittedCount == 0 ? 24 : (emittedCount == 1 ? 40 : 70)
            if ",;:—".contains(char), next < buffer.endIndex, buffer[next] == " ", count >= commaAfter {
                return next
            }
            // No comma in sight: cut the first piece at a word boundary rather than wait
            // for a whole long sentence.
            if emittedCount == 0, char == " ", count >= 46 {
                return next
            }
            index = next
        }
        return nil
    }
}
