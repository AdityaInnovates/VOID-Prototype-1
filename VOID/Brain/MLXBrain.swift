import Foundation
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

enum BrainError: LocalizedError {
    case notLoaded(String)

    var errorDescription: String? {
        switch self {
        case .notLoaded(let name): return "The \(name) brain isn't loaded yet."
        }
    }
}

/// One local LLM running on the GPU through MLX.
/// VOID owns two of these: a tiny reflex brain and a bigger deep brain.
///
/// Generation is done by hand (not with ChatSession) so a reply can be *pre-filled*:
/// the deep brain is handed the words the reflex already spoke as the start of its own
/// reply, and simply keeps talking. That's what makes the two brains sound like one voice.
actor MLXBrain {
    struct Turn: Sendable {
        let user: String
        let reply: String
    }

    nonisolated let name: String
    nonisolated let modelID: String

    private let configuration: ModelConfiguration
    private let instructions: String
    private let parameters: GenerateParameters
    /// The deep brain remembers the conversation; the reflex starts fresh every turn.
    private let keepHistory: Bool
    /// Only the last few exchanges are re-read each turn, to keep replies fast.
    private let maxTurns = 4

    private var container: ModelContainer?
    private var loadTask: Task<ModelContainer, Error>?
    private var history: [Turn] = []

    init(
        name: String,
        configuration: ModelConfiguration,
        instructions: String,
        parameters: GenerateParameters,
        keepHistory: Bool
    ) {
        self.name = name
        self.configuration = configuration
        self.modelID = configuration.name
        self.instructions = instructions
        self.parameters = parameters
        self.keepHistory = keepHistory
    }

    var isLoaded: Bool { container != nil }

    /// Downloads the model on first use (cached afterwards) and loads it into memory.
    func load(progress: @escaping @Sendable (Double) -> Void) async throws {
        if container != nil { return }
        if let loadTask {
            _ = try await loadTask.value
            return
        }

        let configuration = self.configuration
        let task = Task<ModelContainer, Error> {
            try await #huggingFaceLoadModelContainer(
                configuration: configuration,
                progressHandler: { p in progress(p.fractionCompleted) }
            )
        }
        loadTask = task
        defer { loadTask = nil }

        container = try await task.value
    }

    /// Frees the model's memory. It reloads automatically the next time it's needed.
    /// The conversation memory is kept.
    func unload() {
        container = nil
        Memory.clearCache()
    }

    // MARK: - Memory of the conversation

    /// Records one exchange exactly as VOID said it (opener and continuation together).
    func remember(user: String, reply: String) {
        guard keepHistory else { return }
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        history.append(Turn(user: user, reply: String(trimmed.prefix(900))))
        if history.count > maxTurns { history.removeFirst(history.count - maxTurns) }
    }

    func resetHistory() {
        history.removeAll()
    }

    func historySnapshot() -> [Turn] { history }

    func restore(_ turns: [Turn]) {
        history = Array(turns.suffix(maxTurns))
    }

    // MARK: - Generation

    /// Streams a reply as text chunks. If `prefix` is given, it is placed at the start of
    /// the reply as if the model had already said it, and the stream contains only what
    /// comes after it. Cancelling the consuming task stops generation.
    nonisolated func stream(_ prompt: String, prefix: String = "") -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.run(prompt, prefix: prefix) { chunk in
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func run(_ prompt: String, prefix: String, yield: @escaping @Sendable (String) -> Void) async throws {
        guard let container else { throw BrainError.notLoaded(name) }

        var built: [[String: any Sendable]] = [["role": "system", "content": instructions]]
        if keepHistory {
            for turn in history {
                built.append(["role": "user", "content": turn.user])
                built.append(["role": "assistant", "content": turn.reply])
            }
        }
        built.append(["role": "user", "content": prompt])

        let messages = built
        let parameters = self.parameters
        let opener = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        // Qwen3.5 can "think" before answering. For a voice assistant that's too slow.
        let extra: [String: any Sendable] = ["enable_thinking": false]

        try await container.perform { (context: ModelContext) in
            var tokens = try context.tokenizer.applyChatTemplate(
                messages: messages, tools: nil, additionalContext: extra
            )
            if !opener.isEmpty {
                tokens += context.tokenizer.encode(text: opener, addSpecialTokens: false)
            }
            let input = LMInput(tokens: MLXArray(tokens))
            let stream = try MLXLMCommon.generate(input: input, parameters: parameters, context: context)
            for await item in stream {
                if Task.isCancelled { break }
                if case .chunk(let text) = item {
                    yield(text)
                }
            }
        }
    }
}
