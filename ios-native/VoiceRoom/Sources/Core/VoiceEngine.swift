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
        setupFactory()
        configureAudioSession()
    }

    // MARK: - 初始化

    private func setupFactory() {
        guard factory == nil else { return }
        RTCInitializeSSL()
        let encoder = RTCDefaultVideoEncoderFactory()
        let decoder = RTCDefaultVideoDecoderFactory()
        factory = RTCPeerConnectionFactory(encoderFactory: encoder, decoderFactory: decoder)
    }

    /// 配置音频会话：允许录音 + 播放，支持蓝牙与外放
    /// iOS 上这是必须的一步，否则麦克风采集不到数据
    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord,
                                    mode: .voiceChat,
                                    options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true, options: [])
        } catch {
            print("[Voice] AVAudioSession 配置失败: \(error.localizedDescription)")
        }
    }

    // MARK: - 麦克风权限与采集

    /// 请求麦克风权限并开始采集
    func requestMic(completion: @escaping (Bool) -> Void) {
        if #available(iOS 17.0, *) {
            AVAudioApplication.requestRecordPermission { granted in
                DispatchQueue.main.async {
                    if granted {
                        self.configureAudioSession()
                        self.startLocalAudio()
                    }
                    completion(granted)
                }
            }
        } else {
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                DispatchQueue.main.async {
                    if granted {
                        self.configureAudioSession()
                        self.startLocalAudio()
                    }
                    completion(granted)
                }
            }
        }
    }

    private func startLocalAudio() {
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

        // 已存在的连接补上本地音轨，并触发重协商
        for (_, pc) in peers {
            pc.add(stream)
            renegotiate(pc, remoteId: nil)
        }
    }

    func setMicEnabled(_ enabled: Bool) {
        isMicOn = enabled
        audioTrack?.isEnabled = enabled
    }

    func setSpeakerEnabled(_ enabled: Bool) {
        do {
            try AVAudioSession.sharedInstance().overrideOutputAudioPort(enabled ? .speaker : .none)
        } catch {
            print("[Voice] 切换扬声器失败: \(error.localizedDescription)")
        }
    }

    // MARK: - 建立 P2P 连接

    private func newPeerConnection(to remoteId: String) -> RTCPeerConnection? {
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
