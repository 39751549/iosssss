import Foundation
import Combine

/// WebSocket 实时连接（URLSessionWebSocketTask，系统原生，无需第三方库）
@MainActor
final class VRConnection: ObservableObject {

    enum Status: Equatable {
        case idle
        case connecting
        case connected
        case failed(String)
    }

    @Published private(set) var status: Status = .idle
    /// 收到服务端下行消息的回调
    var onMessage: ((VRServerMessage) -> Void)?

    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var reconnectAttempt = 0
    private var shouldReconnect = true
    private var pingTimer: Timer?

    // MARK: - 连接

    func connect() {
        guard let url = VRConfig.wsURL else {
            status = .failed("服务器地址无效")
            return
        }
        shouldReconnect = true
        status = .connecting

        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.waitsForConnectivity = true
        // 语音房需要长连接，禁用缓存
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        let s = URLSession(configuration: cfg)
        session = s

        let t = s.webSocketTask(with: url)
        task = t
        t.resume()
        receiveLoop()
        startPing()
    }

    func disconnect() {
        shouldReconnect = false
        stopPing()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        status = .idle
    }

    // MARK: - 发送

    func send(_ message: VRClientMessage) {
        guard let task else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: message.payload) else { return }
        guard let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { [weak self] err in
            if let err {
                Task { @MainActor in self?.handleFailure(err.localizedDescription) }
            }
        }
    }

    // MARK: - 接收循环

    private func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self else { return }
            Task { @MainActor in
                switch result {
                case .success(let msg):
                    self.handleIncoming(msg)
                    self.receiveLoop()          // 继续监听
                case .failure(let err):
                    self.handleFailure(err.localizedDescription)
                }
            }
        }
    }

    private func handleIncoming(_ msg: URLSessionWebSocketTask.Message) {
        let raw: String
        switch msg {
        case .string(let s): raw = s
        case .data(let d):   raw = String(data: d, encoding: .utf8) ?? ""
        @unknown default:    return
        }
        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        // 首帧成功即认为已连接
        if case .connecting = status { status = .connected }
        reconnectAttempt = 0

        let parsed = VRServerMessage.parse(json)
        onMessage?(parsed)
    }

    // MARK: - 心跳（保活，防止中间层断开空闲连接）

    private func startPing() {
        stopPing()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.task?.sendPing { [weak self] err in
                guard let self = self, err != nil else { return }
                Task { @MainActor in
                    self.handleFailure("心跳失败")
                }
            }
        }
    }

    private func stopPing() {
        pingTimer?.invalidate()
        pingTimer = nil
    }

    // MARK: - 断线重连（指数退避）

    private func handleFailure(_ reason: String) {
        guard shouldReconnect else { return }
        stopPing()
        task?.cancel(with: .abnormalClosure, reason: nil)
        task = nil
        status = .failed(reason)

        reconnectAttempt += 1
        // 1s, 2s, 4s, 8s… 最多 15s
        let delay = min(pow(2.0, Double(reconnectAttempt - 1)), 15)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.shouldReconnect else { return }
            self.connect()
        }
    }

    var isConnected: Bool { status == .connected }
}
