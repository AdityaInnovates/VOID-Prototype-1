import Foundation
import Network

/// The link between VOID and the VOID Music Chrome extension.
///
/// A tiny WebSocket server that listens on 127.0.0.1 only, so nothing outside this Mac
/// can reach it. The extension connects, proves it's yours with the pairing code from the
/// menu, then answers VOID's commands and reports what's playing.
@MainActor
final class MusicBridge {
    static let port: UInt16 = 47321

    enum BridgeError: LocalizedError {
        case notConnected
        case timeout
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .notConnected: return "Chrome isn't connected."
            case .timeout: return "Chrome didn't answer in time."
            case .failed(let message): return message
            }
        }
    }

    /// A reply from the extension. Wrapped so it can cross the continuation.
    struct Reply: @unchecked Sendable {
        let data: [String: Any]
    }

    var onConnectionChange: (@MainActor (Bool) -> Void)?
    var onEvent: (@MainActor (String, [String: Any]) -> Void)?

    /// The pairing code the extension must send. Made once, kept in UserDefaults.
    let token: String
    var isConnected: Bool { client != nil }

    private var listener: NWListener?
    private var client: NWConnection?
    private var pending: [String: CheckedContinuation<Reply, Error>] = [:]
    private var nextId = 0

    init() {
        if let saved = UserDefaults.standard.string(forKey: "musicPairingCode"), saved.count >= 6 {
            token = saved
        } else {
            let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
            let code = String((0..<8).map { _ in alphabet.randomElement()! })
            UserDefaults.standard.set(code, forKey: "musicPairingCode")
            token = code
        }
    }

    func start() {
        guard listener == nil else { return }
        let parameters = NWParameters.tcp
        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Self.port)!)
        parameters.allowLocalEndpointReuse = true
        do {
            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated { self?.accept(connection) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                if case .failed = state {
                    MainActor.assumeIsolated { self?.restartSoon() }
                }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            restartSoon()
        }
    }

    private func restartSoon() {
        listener?.cancel()
        listener = nil
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            self?.start()
        }
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            switch state {
            case .failed, .cancelled:
                MainActor.assumeIsolated {
                    if let connection { self?.dropped(connection) }
                }
            default:
                break
            }
        }
        connection.start(queue: .main)
        receive(on: connection)
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, context, _, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                if error != nil {
                    connection.cancel()
                    return
                }
                if let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                    as? NWProtocolWebSocket.Metadata, metadata.opcode == .close {
                    connection.cancel()
                    return
                }
                if let data, !data.isEmpty,
                   let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    self.handle(object, from: connection)
                }
                self.receive(on: connection)
            }
        }
    }

    private func handle(_ message: [String: Any], from connection: NWConnection) {
        let type = message["type"] as? String ?? ""
        if type == "hello" {
            let code = (message["token"] as? String ?? "").uppercased()
            guard code == token else {
                send(["type": "rejected"], to: connection)
                connection.cancel()
                return
            }
            if let old = client, old !== connection { old.cancel() }
            client = connection
            send(["type": "welcome"], to: connection)
            onConnectionChange?(true)
            return
        }
        guard connection === client else { return }
        if let replyTo = message["re"] as? String {
            guard let waiter = pending.removeValue(forKey: replyTo) else { return }
            if message["ok"] as? Bool == true {
                waiter.resume(returning: Reply(data: message["data"] as? [String: Any] ?? [:]))
            } else {
                let reason = message["error"] as? String ?? "Chrome couldn't do that."
                waiter.resume(throwing: BridgeError.failed(reason))
            }
            return
        }
        if type == "ping" {
            send(["type": "pong"], to: connection)
            return
        }
        onEvent?(type, message)
    }

    private func dropped(_ connection: NWConnection) {
        guard connection === client else { return }
        client = nil
        let waiters = pending
        pending.removeAll()
        for (_, waiter) in waiters { waiter.resume(throwing: BridgeError.notConnected) }
        onConnectionChange?(false)
    }

    // MARK: - Sending

    /// Sends a command to the extension and waits for its answer.
    func request(_ type: String, _ payload: [String: Any] = [:], timeout: Double = 20) async throws -> [String: Any] {
        guard let client else { throw BridgeError.notConnected }
        nextId += 1
        let id = "v\(nextId)"
        var message = payload
        message["type"] = type
        message["id"] = id
        let timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled, let self else { return }
            self.pending.removeValue(forKey: id)?.resume(throwing: BridgeError.timeout)
        }
        defer { timer.cancel() }
        let reply = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Reply, Error>) in
            pending[id] = continuation
            send(message, to: client)
        }
        return reply.data
    }

    /// Tells the extension something without waiting for an answer.
    func notify(_ type: String) {
        guard let client else { return }
        send(["type": type], to: client)
    }

    private func send(_ message: [String: Any], to connection: NWConnection) {
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "void", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
    }
}
