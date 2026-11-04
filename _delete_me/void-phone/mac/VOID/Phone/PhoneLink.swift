import CryptoKit
import Foundation
import Network

/// The link between VOID on this Mac and the VOID app on your phone.
///
/// A WebSocket server on 127.0.0.1 only. Nothing on the network can reach it directly:
/// cloudflared carries traffic from wss://void.adityainnovates.me to this port.
/// Because that address is public, every connection must prove it's your phone:
/// - pairing: a 6-digit PIN that exists only for 5 minutes after you click
///   "Pair a phone…" in the menu, with 5 tries, swapped for a long random device key
/// - after that: the device key on every connection. Only its SHA-256 is kept here.
///
/// Both sides can call the other's tools: {"type":"call","id","tool","args"} is answered
/// with {"type":"result","re","ok","data"|"error"}. Either side can push
/// {"type":"event","name","data"}.
@MainActor
final class PhoneLink {
    static let port: UInt16 = 47322

    enum LinkError: LocalizedError {
        case notConnected
        case timeout
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .notConnected: return "Your phone isn't connected."
            case .timeout: return "Your phone didn't answer in time."
            case .failed(let message): return message
            }
        }
    }

    struct Reply: @unchecked Sendable {
        let data: [String: Any]
    }

    struct Device: Codable {
        var name: String
        var keyHash: String
        var added: Date
    }

    /// Answers a tool call from the phone. Throw to send an error back.
    var onCall: (@MainActor (String, [String: Any]) async throws -> [String: Any])?
    var onEvent: (@MainActor (String, [String: Any]) -> Void)?
    var onConnectionChange: (@MainActor (Bool, String?) -> Void)?

    private(set) var deviceName: String?
    var isConnected: Bool { client != nil }

    /// The PIN shown in the menu while pairing is open.
    private(set) var pairingPin: String?
    private var pinExpires = Date.distantPast
    private var pinTries = 0
    var onPairingChange: (@MainActor (String?) -> Void)?

    private var listener: NWListener?
    private var client: NWConnection?
    /// Connections that haven't proved themselves yet, closed after 10 seconds.
    private var unproven: [ObjectIdentifier: NWConnection] = [:]
    private var pending: [String: CheckedContinuation<Reply, Error>] = [:]
    private var nextId = 0
    private var failedHellos: [Date] = []

    private var devices: [Device] {
        get {
            guard let data = UserDefaults.standard.data(forKey: "phoneDevices") else { return [] }
            return (try? JSONDecoder().decode([Device].self, from: data)) ?? []
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: "phoneDevices")
            }
        }
    }

    var pairedNames: [String] { devices.map(\.name) }

    // MARK: - Server

    func start() {
        guard listener == nil else { return }
        let parameters = NWParameters.tcp
        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true
        websocket.maximumMessageSize = 24 * 1024 * 1024
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

    // MARK: - Pairing

    /// Opens pairing for 5 minutes and returns the PIN to type on the phone.
    func openPairing() -> String {
        let pin = String(format: "%06d", Int.random(in: 0...999_999))
        pairingPin = pin
        pinExpires = Date().addingTimeInterval(300)
        pinTries = 0
        onPairingChange?(pin)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(301))
            guard let self, self.pairingPin == pin else { return }
            self.closePairing()
        }
        return pin
    }

    func closePairing() {
        pairingPin = nil
        onPairingChange?(nil)
    }

    /// Forgets every paired phone and drops the connection.
    func forgetDevices() {
        devices = []
        client?.cancel()
    }

    private static func hash(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func newKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Compares without stopping at the first different character.
    private static func same(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var difference: UInt8 = 0
        for i in 0..<x.count { difference |= x[i] ^ y[i] }
        return difference == 0
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        unproven[id] = connection
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
        Task { [weak self, weak connection] in
            try? await Task.sleep(for: .seconds(10))
            guard let self, let connection, self.unproven[ObjectIdentifier(connection)] != nil else { return }
            connection.cancel()
        }
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
        let id = ObjectIdentifier(connection)

        if type == "pair" {
            let pin = message["pin"] as? String ?? ""
            let name = String((message["device"] as? String ?? "Phone").prefix(60))
            guard let open = pairingPin, Date() < pinExpires else {
                return reject(connection, "Pairing isn't open. In VOID's menu, click “Pair a phone…”.")
            }
            pinTries += 1
            guard Self.same(pin, open) else {
                if pinTries >= 5 { closePairing() }
                return reject(connection, pinTries >= 5 ? "Too many wrong PINs. Open pairing again." : "Wrong PIN.")
            }
            closePairing()
            let key = Self.newKey()
            var list = devices.filter { $0.name != name }
            list.append(Device(name: name, keyHash: Self.hash(key), added: Date()))
            devices = list
            send(["type": "paired", "key": key, "mac": Host.current().localizedName ?? "Mac"], to: connection)
            admit(connection, name: name)
            return
        }

        if type == "hello" {
            let now = Date()
            failedHellos = failedHellos.filter { now.timeIntervalSince($0) < 60 }
            guard failedHellos.count < 10 else { return reject(connection, "Too many tries. Wait a minute.") }
            let key = message["key"] as? String ?? ""
            let keyHash = Self.hash(key)
            guard let device = devices.first(where: { Self.same($0.keyHash, keyHash) }) else {
                failedHellos.append(now)
                return reject(connection, "This phone isn't paired anymore. Pair it again from VOID's menu.", forget: true)
            }
            send(["type": "welcome", "mac": Host.current().localizedName ?? "Mac"], to: connection)
            admit(connection, name: device.name)
            return
        }

        guard connection === client, unproven[id] == nil else { return }

        if type == "ping" {
            send(["type": "pong"], to: connection)
            return
        }
        if type == "result", let replyTo = message["re"] as? String {
            guard let waiter = pending.removeValue(forKey: replyTo) else { return }
            if message["ok"] as? Bool == true {
                waiter.resume(returning: Reply(data: message["data"] as? [String: Any] ?? [:]))
            } else {
                waiter.resume(throwing: LinkError.failed(message["error"] as? String ?? "Your phone couldn't do that."))
            }
            return
        }
        if type == "call", let callId = message["id"] as? String, let tool = message["tool"] as? String {
            let args = message["args"] as? [String: Any] ?? [:]
            Task { [weak self] in
                guard let self else { return }
                do {
                    let data = try await self.onCall?(tool, args) ?? [:]
                    self.send(["type": "result", "re": callId, "ok": true, "data": data], to: connection)
                } catch {
                    self.send(["type": "result", "re": callId, "ok": false, "error": error.localizedDescription], to: connection)
                }
            }
            return
        }
        if type == "event", let name = message["name"] as? String {
            onEvent?(name, message["data"] as? [String: Any] ?? [:])
        }
    }

    private func reject(_ connection: NWConnection, _ reason: String, forget: Bool = false) {
        send(["type": "rejected", "reason": reason, "forget": forget], to: connection)
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            connection.cancel()
        }
    }

    private func admit(_ connection: NWConnection, name: String) {
        unproven.removeValue(forKey: ObjectIdentifier(connection))
        if let old = client, old !== connection { old.cancel() }
        client = connection
        deviceName = name
        onConnectionChange?(true, name)
    }

    private func dropped(_ connection: NWConnection) {
        unproven.removeValue(forKey: ObjectIdentifier(connection))
        guard connection === client else { return }
        client = nil
        let waiters = pending
        pending.removeAll()
        for (_, waiter) in waiters { waiter.resume(throwing: LinkError.notConnected) }
        onConnectionChange?(false, deviceName)
    }

    // MARK: - Calling the phone

    /// Runs one of the phone's tools and waits for its answer.
    func call(_ tool: String, _ args: [String: Any] = [:], timeout: Double = 20) async throws -> [String: Any] {
        guard let client else { throw LinkError.notConnected }
        nextId += 1
        let id = "m\(nextId)"
        let timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled, let self else { return }
            self.pending.removeValue(forKey: id)?.resume(throwing: LinkError.timeout)
        }
        defer { timer.cancel() }
        let reply = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Reply, Error>) in
            pending[id] = continuation
            send(["type": "call", "id": id, "tool": tool, "args": args], to: client)
        }
        return reply.data
    }

    func notify(_ name: String, _ data: [String: Any] = [:]) {
        guard let client else { return }
        send(["type": "event", "name": name, "data": data], to: client)
    }

    private func send(_ message: [String: Any], to connection: NWConnection) {
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "void-phone", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
    }
}
