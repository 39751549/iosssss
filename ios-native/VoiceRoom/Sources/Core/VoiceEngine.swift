import Foundation
import AVFoundation
import WebRTC

/// 语音引擎：WebRTC 点对点语音 + 说话检测
///
/// 设计说明：
/// - 3 人小房间用 P2P mesh（两两互联），不经过媒体服务器，完全免费
/// - iOS 必须正确配置 AVAudioSession，否则要么没声音、要么录音失败
/// - WebRTC 依赖：Google WebRTC（通过 Swift Package 引入，见 Package.swift）
final class VoiceEngine: NSObject {

    // MARK: 回调（都在主线程触发）
    var onSpeakingChanged: ((Set<String>) -> Void)?
    /// 需要把信令发出去时回调（由 AppState 负责通过 WebSocket 发送）
    var onSignal: ((_ kind: SignalKind, _ to: String, _ payload: [String: Any]) -> Void)?

    enum SignalKind {
        case offer, answer, ice
    }

    // MARK: 内部状态
    private var factory: RTCPeerConnectionFactory?
    private var localStream: RTCMediaStream?
    private var audioTrack: RTCAudioTrack?
    private var peers: [String: RTCPeerConnection] = [:]
    private var proxies: [String: PeerDelegateProxy] = [:]
    private var remoteStreams: [String: RTCMediaStream] = [:]
    private var levelTimers: [String: Timer] = [:]
    private var speakingIds: Set<String> = []

    private static let stunServers = [
        "stun:stun.l.google.com:19302",
        "stun:stun1.l.google.com:19302"
    ]

    private(set) var isMicOn = false
    private var isConfigured = false

    override init() {
        super.init()
        // ⚠️ 这里**绝对不能**碰 AVAudioSession，也先不建 WebRTC 工厂。
        //
        // AppState 是 @StateObject，一启动就 new 出 VoiceEngine。以前 init 里直接
        // setCategory(.playAndRecord) + setActive(true)，于是用户只是**打开 App**
        // （还在登录页/大厅、根本没进房）系统就亮起「正在使用麦克风」的提示，
        // 同时把别的 App 的音频顶掉（.playAndRecord 不带 mixWithOthers 会独占）。
        //
        // 正确做法：音频会话推迟到真正需要出声/收声时再激活 —— 见 enterListenMode /
        // enterTalkMode；离开房间用 leaveAudio() 释放，麦克风提示随之消失。
    }

    // MARK: - 初始化

    private func setupFactory() {
        guard factory == nil else { return }
        // 必须在创建工厂（WebRTC 音频单元诞生）之前把会话档位定成双向语音；
        // 之后整个连接生命周期内都不再改 category。
        prepareSessionForRTC()
        RTCInitializeSSL()
        let encoder = RTCDefaultVideoEncoderFactory()
        let decoder = RTCDefaultVideoDecoderFactory()
        factory = RTCPeerConnectionFactory(encoderFactory: encoder, decoderFactory: decoder)
    }

    // MARK: - 音频会话（按需激活，分「只听」和「说话」两档）

    private(set) var audioMode: AudioMode = .idle

    enum AudioMode { case idle, listen, talk }

    /// 把音频会话切到 WebRTC 需要的「双向语音」档。
    ///
    /// ⚠️ 只允许在 **WebRTC 工厂创建之前** 调用（setupFactory 开头会调）。
    /// 只要 factory 已经存在，说明 WebRTC 的 Voice-Processing 音频单元可能正在跑
    /// （房里有人、远端音频在播），这时从外部 setCategory 会直接闪退
    /// （'com.apple.coreaudio.avfaudio' / 音频单元重启失败）——
    /// 这是「房里有人一开麦就闪退」的根因。所以这里对「已是 playAndRecord」做了短路。
    private func prepareSessionForRTC() {
        let session = AVAudioSession.sharedInstance()
        guard session.category != .playAndRecord else {
            audioMode = .talk
            return
        }
        do {
            try session.setCategory(.playAndRecord,
                                    mode: .voiceChat,
                                    options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers])
            try session.setActive(true)
            audioMode = .talk
        } catch {
            print("[Voice] 语音会话配置失败: \(error.localizedDescription)")
        }
    }

    /// 进房但没开麦：只占播放通道，**不碰麦克风**（不会亮麦克风提示，也不会顶掉其他 App 音频）
    ///
    /// 注意：一旦 WebRTC 已经跑起来（factory 存在），会话档位必须是 .playAndRecord 且
    /// **绝不能再切回 .playback** —— 否则又是开麦闪退的同一个坑。闭麦只是降档记录，
    /// 不动 session 的 category。
    func enterListenMode() {
        // 注意守卫写的是 != .listen（而不是 != .talk）：
        // 闭麦时要能从 .talk **降档**回 .listen，写 != .talk 会把降档这条路堵死。
        guard audioMode != .listen else { return }
        let session = AVAudioSession.sharedInstance()
        if factory != nil {
            // WebRTC 已在运行：category 必须保持 .playAndRecord，只确保会话激活
            do {
                try session.setActive(true)
                audioMode = .listen
            } catch {
                print("[Voice] 播放会话激活失败: \(error.localizedDescription)")
            }
            return
        }
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            audioMode = .listen
        } catch {
            print("[Voice] 播放模式音频会话失败: \(error.localizedDescription)")
        }
    }

    /// 开麦：切到双向语音（这一步开始系统会显示正在使用麦克风 —— 属于预期）
    func enterTalkMode() {
        let session = AVAudioSession.sharedInstance()
        // WebRTC 已在跑 / 会话已是双向档：category 一个字都不能改（改 = 闪退），
        // 只补一次激活和扬声器偏好。
        if factory != nil || session.category == .playAndRecord {
            do {
                try session.setActive(true)
            } catch {
                print("[Voice] 语音会话激活失败: \(error.localizedDescription)")
            }
            audioMode = .talk
            applySpeakerPreference()
            return
        }
        do {
            try session.setCategory(.playAndRecord,
                                    mode: .voiceChat,
                                    options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers])
            try session.setActive(true)
            audioMode = .talk
            applySpeakerPreference()
        } catch {
            print("[Voice] 语音模式音频会话失败: \(error.localizedDescription)")
        }
    }

    /// 离开房间 / 退到大厅：释放音频会话，麦克风与扬声器占用一并解除
    func leaveAudio() {
        audioMode = .idle
        do {
            try AVAudioSession.sharedInstance().setActive(false,
                                                          options: [.notifyOthersOnDeactivation])
        } catch {
            print("[Voice] 释放音频会话失败: \(error.localizedDescription)")
        }
    }

    // MARK: - 麦克风权限与采集

    /// 请求麦克风权限并开始采集
    func requestMic(completion: @escaping (Bool) -> Void) {
        if #available(iOS 17.0, *) {
            AVAudioApplication.requestRecordPermission { granted in
                DispatchQueue.main.async {
                    if granted {
                        self.enterTalkMode()
                        self.startLocalAudio()
                    }
                    completion(granted)
                }
            }
        } else {
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                DispatchQueue.main.async {
                    if granted {
                        self.enterTalkMode()
                        self.startLocalAudio()
                    }
                    completion(granted)
                }
            }
        }
    }

    private func startLocalAudio() {
        setupFactory()
        guard localStream == nil, let factory else { return }

        // AEC/NS/AGC 由 WebRTC 音频处理默认开启，无需显式约束键
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: nil
        )
        let source = factory.audioSource(with: constraints)
        let track = factory.audioTrack(with: source, trackId: "audio0")
        audioTrack = track

        let stream = factory.mediaStream(withStreamId: "localStream")
        stream.addAudioTrack(track)
        localStream = stream
        isMicOn = true

        // 已存在的连接补上本地音轨，并触发重协商。
        // ⚠️ 必须传真实的 remoteId：以前传 nil 会被 renegotiate 的 guard 吞掉，
        // 导致「先进房、后开麦」时房里其他人永远收不到我的音轨。
        for (remoteId, pc) in peers {
            pc.add(stream)
            renegotiate(pc, remoteId: remoteId)
        }
    }

    func setMicEnabled(_ enabled: Bool) {
        isMicOn = enabled
        audioTrack?.isEnabled = enabled
        // 闭麦后降到「只听」档：释放录音通道，麦克风提示熄灭
        if enabled {
            enterTalkMode()
        } else if audioMode == .talk {
            enterListenMode()
        }
    }

    /// 记住扬声器开关（.playback 档下音频本来就只走外放，
    /// 只有 .playAndRecord 档才需要用 overrideOutputAudioPort 在听筒/外放之间切）
    private var speakerPreferred = true

    func setSpeakerEnabled(_ enabled: Bool) {
        speakerPreferred = enabled
        applySpeakerPreference()
    }

    private func applySpeakerPreference() {
        guard audioMode == .talk else { return }
        do {
            try AVAudioSession.sharedInstance().overrideOutputAudioPort(speakerPreferred ? .speaker : .none)
        } catch {
            print("[Voice] 切换扬声器失败: \(error.localizedDescription)")
        }
    }

    // MARK: - 建立 P2P 连接

    private func newPeerConnection(to remoteId: String) -> RTCPeerConnection? {
        setupFactory()
        guard let factory else { return nil }
        if let existing = peers[remoteId] { return existing }

        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherContinually
        config.bundlePolicy = .maxBundle
        config.rtcpMuxPolicy = .require
        config.iceServers = Self.stunServers.map { RTCIceServer(urlStrings: [$0]) }

        let constraints = RTCMediaConstraints(mandatoryConstraints: nil,
                                              optionalConstraints: nil)

        guard let pc = factory.peerConnection(with: config, constraints: constraints, delegate: nil) else {
            return nil
        }

        // 音频收发：unifiedPlan 下用 transceiver 显式声明收发方向，
        // 这样即使还没开麦，也能收到对方的音频
        let audioInit = RTCRtpTransceiverInit()
        audioInit.direction = .sendRecv
        pc.addTransceiver(of: .audio, init: audioInit)

        // 若已开麦则加入本地流
        if let stream = localStream {
            pc.add(stream)
        }

        let proxy = PeerDelegateProxy(remoteId: remoteId, engine: self)
        proxies[remoteId] = proxy
        pc.delegate = proxy

        peers[remoteId] = pc
        return pc
    }

    /// 我主动发起 offer（新成员进房时，由老成员发起）
    func createOffer(to remoteId: String) {
        guard let pc = newPeerConnection(to: remoteId) else { return }

        let constraints = RTCMediaConstraints(
            mandatoryConstraints: ["OfferToReceiveAudio": "true"],
            optionalConstraints: nil
        )
        pc.offer(for: constraints) { [weak self] sdp, error in
            guard let self, let sdp, error == nil else { return }
            pc.setLocalDescription(sdp) { err in
                guard err == nil else { return }
                DispatchQueue.main.async {
                    self.onSignal?(.offer, remoteId, ["sdp": sdp.sdp])
                }
            }
        }
    }

    func handleOffer(from remoteId: String, sdp: String) {
        guard let pc = newPeerConnection(to: remoteId) else { return }

        let desc = RTCSessionDescription(type: .offer, sdp: sdp)
        pc.setRemoteDescription(desc) { [weak self] err in
            guard let self, err == nil else { return }
            let constraints = RTCMediaConstraints(
                mandatoryConstraints: ["OfferToReceiveAudio": "true"],
                optionalConstraints: nil
            )
            pc.answer(for: constraints) { answer, error in
                guard let answer, error == nil else { return }
                pc.setLocalDescription(answer) { err2 in
                    guard err2 == nil else { return }
                    DispatchQueue.main.async {
                        self.onSignal?(.answer, remoteId, ["sdp": answer.sdp])
                    }
                }
            }
        }
    }

    func handleAnswer(from remoteId: String, sdp: String) {
        guard let pc = peers[remoteId] else { return }
        let desc = RTCSessionDescription(type: .answer, sdp: sdp)
        pc.setRemoteDescription(desc) { _ in }
    }

    func handleIce(from remoteId: String, candidate: [String: Any]) {
        guard let pc = peers[remoteId] else { return }
        guard let sdp = candidate["candidate"] as? String,
              let sdpMid = candidate["sdpMid"] as? String
        else { return }

        let index: Int32
        if let i = candidate["sdpMLineIndex"] as? Int32 { index = i }
        else if let i = candidate["sdpMLineIndex"] as? Int { index = Int32(i) }
        else { index = 0 }

        let ice = RTCIceCandidate(sdp: sdp, sdpMLineIndex: index, sdpMid: sdpMid)
        pc.add(ice) { _ in }
    }

    /// ICE 收集完成后重协商（开麦时已有连接需要补音轨）
    private func renegotiate(_ pc: RTCPeerConnection, remoteId: String?) {
        guard let remoteId else { return }
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: ["OfferToReceiveAudio": "true"],
            optionalConstraints: nil
        )
        pc.offer(for: constraints) { [weak self] sdp, error in
            guard let self, let sdp, error == nil else { return }
            pc.setLocalDescription(sdp) { err in
                guard err == nil else { return }
                DispatchQueue.main.async {
                    self.onSignal?(.offer, remoteId, ["sdp": sdp.sdp])
                }
            }
        }
    }

    func closePeer(_ remoteId: String) {
        levelTimers[remoteId]?.invalidate()
        levelTimers.removeValue(forKey: remoteId)
        peers[remoteId]?.close()
        peers.removeValue(forKey: remoteId)
        proxies.removeValue(forKey: remoteId)
        remoteStreams.removeValue(forKey: remoteId)

        if speakingIds.remove(remoteId) != nil {
            onSpeakingChanged?(speakingIds)
        }
    }

    /// 进房后与已在房里的人建立连接（由后进房者发起，避免双方同时 offer）
    func connectToExistingPeers(_ ids: [String]) {
        ids.forEach { createOffer(to: $0) }
    }

    func stopAll() {
        levelTimers.forEach { $0.value.invalidate() }
        levelTimers.removeAll()
        peers.forEach { $0.value.close() }
        peers.removeAll()
        proxies.removeAll()
        remoteStreams.removeAll()
        localStream = nil
        audioTrack = nil
        isMicOn = false
        speakingIds.removeAll()
        onSpeakingChanged?([])
        factory = nil
        // 释放音频会话：离开房间后不再占用麦克风/扬声器
        leaveAudio()
    }

    // MARK: - 说话检测

    fileprivate func startAudioLevelWatch(remoteId: String, pc: RTCPeerConnection) {
        levelTimers[remoteId]?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            guard let self else { return }
            pc.statistics { report in
                var level: Double = 0
                for (_, stat) in report.statistics {
                    if stat.type == "inbound-rtp" {
                        if let l = stat.values["audioLevel"] as? Double { level = max(level, l) }
                        else if let l = stat.values["audioLevel"] as? NSNumber { level = max(level, l.doubleValue) }
                    }
                }
                let speaking = level > 0.06
                DispatchQueue.main.async {
                    let before = self.speakingIds.contains(remoteId)
                    if speaking && !before {
                        self.speakingIds.insert(remoteId)
                        self.onSpeakingChanged?(self.speakingIds)
                    } else if !speaking && before {
                        self.speakingIds.remove(remoteId)
                        self.onSpeakingChanged?(self.speakingIds)
                    }
                }
            }
        }
        levelTimers[remoteId] = timer
    }
}

// MARK: - PeerConnection 代理

final class PeerDelegateProxy: NSObject, RTCPeerConnectionDelegate {

    private weak var engine: VoiceEngine?
    private let remoteId: String

    init(remoteId: String, engine: VoiceEngine) {
        self.remoteId = remoteId
        self.engine = engine
    }

    func peerConnection(_ pc: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.engine?.onSignal?(.ice, self.remoteId, [
                "candidate": candidate.sdp,
                "sdpMid": candidate.sdpMid ?? "",
                "sdpMLineIndex": Int(candidate.sdpMLineIndex)
            ])
        }
    }

    func peerConnection(_ pc: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        engine?.startAudioLevelWatch(remoteId: remoteId, pc: pc)
    }

    func peerConnection(_ pc: RTCPeerConnection, didRemove stream: RTCMediaStream) {}

    func peerConnectionShouldNegotiate(_ pc: RTCPeerConnection) {}

    func peerConnection(_ pc: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}

    func peerConnection(_ pc: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

    func peerConnection(_ pc: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}

    func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        if newState == .failed || newState == .closed || newState == .disconnected {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.engine?.closePeer(self.remoteId)
            }
        }
    }

    func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}

    func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {}
}
