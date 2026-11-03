import Foundation

/// Cuts a streaming answer into speakable pieces, so VOID can start talking after the
/// first sentence instead of waiting for the whole reply.
struct SentenceChunker {
    private var buffer = ""
    /// The first piece is cut early (at a comma) so VOID starts speaking sooner;
    /// later pieces wait for whole sentences, which sound better.
    private var emittedAny = false

    mutating func feed(_ text: String) -> [String] {
        buffer += text
        var pieces: [String] = []
        while let end = nextBoundary() {
            let piece = String(buffer[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            buffer = String(buffer[end...])
            if !piece.isEmpty {
                pieces.append(piece)
                emittedAny = true
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
            // Break at a comma for a long sentence, or early for the very first piece.
            let commaAfter = emittedAny ? 70 : 24
            if ",;:—".contains(char), next < buffer.endIndex, buffer[next] == " ", count >= commaAfter {
                return next
            }
            index = next
        }
        return nil
    }
}
