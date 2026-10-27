import CryptoKit
import Foundation
import Network
import os

/// 局域网接收服务：NWListener 监听所有网卡 + Bonjour 广播 `_aiinput._tcp`，每条 WebSocket 连接交给一个 LocalBridgeSession。
/// 全部跑在主队列上，注入本来就要在主线程做，流量也只是一句话一条。
@MainActor
@Observable
final class LocalBridgeServer {

    enum State: Equatable {
        case stopped
        case starting
        case listening(port: UInt16)
        case failed(String)
    }

    struct Peer: Identifiable, Equatable {
        let id: UUID
        let deviceId: String
        let deviceName: String?
    }

    private(set) var state: State = .stopped
    /// 已通过鉴权的连接
    private(set) var peers: [Peer] = []

    var port: UInt16? {
        if case .listening(let port) = state { return port }
        return nil
    }

    /// 某台设备鉴权成功（deviceId, deviceName）
    @ObservationIgnored var onAuthenticated: ((String, String?) -> Void)?

    @ObservationIgnored private let environment: LocalBridgeSession.Environment
    @ObservationIgnored private let requestedPort: UInt16
    @ObservationIgnored private let advertisesBonjour: Bool
    @ObservationIgnored private let handshakeTimeout: TimeInterval
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var connections: [UUID: (connection: NWConnection, session: LocalBridgeSession)] = [:]

    @ObservationIgnored private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VoiceBridge",
                                                    category: "LocalBridgeServer")

    init(macId: String,
         macName: String,
         port: UInt16 = LocalBridgeWire.defaultPort,
         advertisesBonjour: Bool = true,
         handshakeTimeout: TimeInterval = 10,
         hosts: @escaping () -> [LocalBridgeHost],
         keyForDevice: @escaping (String) -> SymmetricKey?,
         perform: @escaping (LocalBridgeAction) -> InjectionOutcome) {
        // 去重表跨连接共享：断线重发同一 id 也只注入一次
        self.environment = LocalBridgeSession.Environment(
            macId: macId, macName: macName, hosts: hosts, keyForDevice: keyForDevice,
            perform: perform, deduplicator: MessageDeduplicator<LocalBridgeAck>()
        )
        self.requestedPort = port
        self.advertisesBonjour = advertisesBonjour
        self.handshakeTimeout = handshakeTimeout
    }

    // MARK: - 启停

    func start() {
        guard listener == nil else { return }

        let listener: NWListener
        do {
            let port = requestedPort == 0 ? NWEndpoint.Port.any : NWEndpoint.Port(rawValue: requestedPort)!
            listener = try NWListener(using: LocalBridgeWire.parameters(), on: port)
        } catch {
            logger.error("局域网服务创建失败: \(error.localizedDescription, privacy: .public)")
            state = .failed(error.localizedDescription)
            return
        }

        if advertisesBonjour {
            listener.service = NWListener.Service(
                name: environment.macName,
                type: LocalBridgeWire.serviceType,
                txtRecord: NWTXTRecord(["mac": environment.macId, "v": String(LocalBridgeWire.version)])
            )
        }
        listener.stateUpdateHandler = { [weak self, weak listener] newState in
            MainActor.assumeIsolated {
                guard let self, let listener, listener === self.listener else { return }
                self.listenerStateChanged(newState, port: listener.port)
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.accept(connection) }
        }

        self.listener = listener
        state = .starting
        listener.start(queue: .main)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for entry in connections.values { entry.connection.cancel() }
        connections.removeAll()
        peers.removeAll()
        state = .stopped
        logger.info("局域网服务已停止")
    }

    /// 吊销设备时断开它的连接
    func disconnect(deviceId: String) {
        for entry in connections.values where entry.session.deviceId == deviceId {
            entry.connection.cancel()
        }
    }

    private func listenerStateChanged(_ newState: NWListener.State, port: NWEndpoint.Port?) {
        switch newState {
        case .ready:
            let port = port?.rawValue ?? requestedPort
            state = .listening(port: port)
            logger.info("局域网服务监听端口 \(port)")
        case .failed(let error):
            logger.error("局域网服务失败: \(error.localizedDescription, privacy: .public)")
            listener?.cancel()
            listener = nil
            state = .failed(error.localizedDescription)
        case .waiting(let error):
            logger.warning("局域网服务等待中: \(error.localizedDescription, privacy: .public)")
        default:
            break
        }
    }

    // MARK: - 连接

    private func accept(_ connection: NWConnection) {
        let id = UUID()
        let session = LocalBridgeSession(environment: environment)
        connections[id] = (connection, session)
        let remote = "\(connection.endpoint)"
        logger.info("新连接 \(remote, privacy: .public)")

        connection.stateUpdateHandler = { [weak self] newState in
            MainActor.assumeIsolated {
                switch newState {
                case .ready:
                    self?.ready(id)
                case .failed(let error):
                    self?.logger.info("连接失败 \(remote, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    connection.cancel()
                case .cancelled:
                    self?.remove(id)
                default:
                    break
                }
            }
        }
        connection.start(queue: .main)
    }

    private func ready(_ id: UUID) {
        guard let entry = connections[id] else { return }
        apply(entry.session.start(), to: entry.connection)
        receive(id)

        DispatchQueue.main.asyncAfter(deadline: .now() + handshakeTimeout) { [weak self] in
            MainActor.assumeIsolated {
                guard let entry = self?.connections[id], !entry.session.isAuthenticated else { return }
                self?.logger.info("握手超时，断开")
                entry.connection.cancel()
            }
        }
    }

    private func receive(_ id: UUID) {
        guard let connection = connections[id]?.connection else { return }
        connection.receiveMessage { [weak self] data, _, _, error in
            MainActor.assumeIsolated {
                guard let self, let entry = self.connections[id] else { return }
                if let data, !data.isEmpty {
                    self.handle(data, entry: entry, id: id)
                }
                if let error {
                    self.logger.info("连接断开: \(error.localizedDescription, privacy: .public)")
                    connection.cancel()
                    return
                }
                if self.connections[id] != nil { self.receive(id) }
            }
        }
    }

    private func handle(_ data: Data, entry: (connection: NWConnection, session: LocalBridgeSession), id: UUID) {
        let session = entry.session
        let wasAuthenticated = session.isAuthenticated

        let outputs = session.receive(data)

        if !wasAuthenticated, session.isAuthenticated, let deviceId = session.deviceId {
            logger.info("设备鉴权成功 \(deviceId, privacy: .public)")
            peers.append(Peer(id: id, deviceId: deviceId, deviceName: session.deviceName))
            onAuthenticated?(deviceId, session.deviceName)
        }

        apply(outputs, to: entry.connection)
    }

    private func apply(_ outputs: [LocalBridgeSession.Output], to connection: NWConnection) {
        for output in outputs {
            switch output {
            case .send(let data):
                LocalBridgeWire.send(data, on: connection)
            case .close:
                // 等前面的回复（比如 authFail）发出去再断
                connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                                completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }

    private func remove(_ id: UUID) {
        connections[id] = nil
        peers.removeAll { $0.id == id }
    }
}
