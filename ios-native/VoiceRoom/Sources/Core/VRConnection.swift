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
    /// 待触发的重连（可取消：回前台时可立刻取消它，避免和 reconnectNow 各建一条连接）
    private var reconnectTask: Task<Void, Never>?

    // MARK: - 连接

    func connect() {
        guard let url = VRConfig.wsURL else {
            status = .failed("服务器地址无效")
            return
        }
        shouldReconnect = true
        // 关键：先彻底拆掉上一条连接再建新的。
        // 以前这里只是把 task/session 覆盖成新对象、旧的既不 cancel 也不 invalidate，
        // 于是旧 socket 会继续活在服务端；服务端一旦按"同账号"把它顶掉，
        // 旧 socket 的接收循环又会把 room:kicked 交给同一个 AppState ——
        // 表现就是「切后台再回来，提示我在别的地方登录」。
        teardownCurrent()
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
        receiveLoop(for: t)
        startPing(for: t)

        // URLSessionWebSocketTask 没有「已打开」回调。
        // 只靠「收到第一帧」判定连接成功是不可靠的：服务端如果建连后不说话，
        // status 会永远停在 .connecting，上层「连上就自动登录」的逻辑就永远不触发
        // （表现就是每次重开 App 都要手动登录）。
        // 这里再补一个探测：ping 能正常往返即认为链路可用。
        // 注意：必须先 guard let self 把弱引用固化，再进 Task，
        // 否则会把「弱引用盒子」捕获进并发闭包，Swift 直接报错。
        t.sendPing { [weak self] err in
            guard let self = self, err == nil else { return }
            Task { @MainActor in
                guard self.task === t else { return }   // 已被更新的连接替换
                self.markConnected()
            }
        }
    }

    /// 标记链路已就绪（幂等）
    private func markConnected() {
        if case .connected = status { return }
        status = .connected
        reconnectAttempt = 0
    }

    /// 拆掉当前连接（只做清理，不改 shouldReconnect）。重连、重开都先走这里。
    private func teardownCurrent() {
        stopPing()
        reconnectTask?.cancel()
        reconnectTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
    }

    func disconnect() {
        shouldReconnect = false
        teardownCurrent()
        status = .idle
    }

    /// 重新启用重连并确保链路存在。
    /// 用于被顶下线 / 主动登出之后，用户又点了登录这类「显式动作」——
    /// 此时 shouldReconnect 还是 false、task 也是 nil，直接 send 会静默丢弃。
    func resume() {
        shouldReconnect = true
        if task == nil {
            reconnectAttempt = 0
            connect()
        }
    }

    /// 回到前台时立刻重连，不等指数退避。
    /// 切后台期间系统可能已经掐掉连接，而进程被挂起时收不到失败回调，
    /// 回前台后如果什么都不做，界面会一直停在"正在连接"。
    func reconnectNow() {
        guard shouldReconnect else { return }
        if task != nil, case .connected = status { return }
        reconnectAttempt = 0
        connect()
    }

    // MARK: - 发送

    func send(_ message: VRClientMessage) {
        guard let t = task else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: message.payload) else { return }
        guard let text = String(data: data, encoding: .utf8) else { return }
        t.send(.string(text)) { [weak self] err in
            // 先固化弱引用再进 Task：把 weak self 直接带进并发闭包 Swift 会报
            // "reference to captured var 'self' in concurrently-executing code"
            guard let self = self, let err = err else { return }
            let reason = err.localizedDescription
            Task { @MainActor in
                // 失败回调也要确认是自己的连接，旧连接的报错不该触发当前连接的重连
                guard self.task === t else { return }
                self.handleFailure(reason)
            }
        }
    }

    // MARK: - 接收循环

    /// 只监听 t 这条连接的帧。
    ///
    /// 必须把 t 捕获进来做身份校验：旧连接的接收回调可能在它被替换之后才触发，
    /// 若不加判断，旧 socket 上收到的 room:kicked 会被当成本连接的消息交给上层，
    /// 用户就会在自己手机看到"账号在其他地方登录"。
    private func receiveLoop(for t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            guard let self else { return }
            Task { @MainActor in
                guard self.task === t else { return }   // 已过期连接的帧，直接丢弃
                switch result {
                case .success(let msg):
                    self.handleIncoming(msg)
                    self.receiveLoop(for: t)            // 继续监听同一条连接
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

        // 首帧成功同样视为已连接（与 connect() 里的 ping 探测互为兜底）
        markConnected()

        let parsed = VRServerMessage.parse(json)
        onMessage?(parsed)
    }

    // MARK: - 心跳（保活，防止中间层断开空闲连接）

    private func startPing(for t: URLSessionWebSocketTask) {
        stopPing()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { _ in
            t.sendPing { [weak self] err in
                guard let self = self, err != nil else { return }
                Task { @MainActor in
                    guard self.task === t else { return }   // 心跳失败也只看当前连接
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
        session?.invalidateAndCancel()
        session = nil
        status = .failed(reason)

        reconnectAttempt += 1
        // 1s, 2s, 4s, 8s… 最多 15s
        let delay = min(pow(2.0, Double(reconnectAttempt - 1)), 15)
        // 存成 Task 便于取消：回前台时 reconnectNow() 会取消这个待触发的重连，
        // 否则退避重连和前台重连会同时建两条连接。
        reconnectTask?.cancel()
        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self, self.shouldReconnect else { return }
            self.connect()
        }
    }

    var isConnected: Bool { status == .connected }
}
