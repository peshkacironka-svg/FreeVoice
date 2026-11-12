import AVFoundation
import Foundation
import MultipeerConnectivity
import UIKit

/// Nearby-only audio transport. Each short PCM frame is sent unreliably to minimize
/// latency; MultipeerConnectivity encrypts the peer session by default.
final class NearbyAudioService: NSObject {
    private static let serviceType = "freevoice"
    private static let audioSampleRate = 16_000.0

    var onPeersChanged: (([MCPeerID]) -> Void)?
    var onIncomingCall: ((MCPeerID) -> Void)?
    var onConnected: ((MCPeerID) -> Void)?
    var onDisconnected: (() -> Void)?
    var onError: ((String) -> Void)?

    private let localPeer = MCPeerID(displayName: UIDevice.current.name)
    private lazy var session = MCSession(peer: localPeer, securityIdentity: nil, encryptionPreference: .required)
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
private var discoveredPeers: [MCPeerID] = []
private var pendingInvitation: ((Bool, MCSession?) -> Void)?

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let playbackQueue = DispatchQueue(label: "FreeVoice.audio.playback")
    private let muteLock = NSLock()
    private var muted = false
private var audioStarted = false
private var inputTapInstalled = false
private var networkFormat: AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32,
                      sampleRate: Self.audioSampleRate,
                      channels: 1,
                      interleaved: false)!
    }

    func startDiscovery() {
        session.delegate = self
        let advertiser = MCNearbyServiceAdvertiser(peer: localPeer, discoveryInfo: nil, serviceType: Self.serviceType)
        let browser = MCNearbyServiceBrowser(peer: localPeer, serviceType: Self.serviceType)
        advertiser.delegate = self
        browser.delegate = self
        self.advertiser = advertiser
        self.browser = browser
        advertiser.startAdvertisingPeer()
        browser.startBrowsingForPeers()
    }

    func requestMicrophonePermission(_ completion: @escaping (Bool) -> Void) {
        AVAudioSession.sharedInstance().requestRecordPermission(completion)
    }

    func invite(_ peer: MCPeerID) {
        browser?.invitePeer(peer, to: session, withContext: nil, timeout: 30)
    }

    func acceptIncomingCall() {
        guard let invitation = pendingInvitation else { return }
        pendingInvitation = nil
        invitation(true, session)
    }

    func endCall() {
        pendingInvitation?(false, nil)
        pendingInvitation = nil
        stopAudio()
        session.disconnect()
    }

    func setMuted(_ value: Bool) {
        muteLock.lock()
        muted = value
        muteLock.unlock()
    }

    func setSpeakerEnabled(_ enabled: Bool) {
        do {
            try AVAudioSession.sharedInstance().overrideOutputAudioPort(enabled ? .speaker : .none)
        } catch {
            onError?("Could not change the audio output route: \(error.localizedDescription)")
        }
    }

    private func startAudio() {
        guard !audioStarted else { return }
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth])
            try audioSession.setActive(true)

            let input = engine.inputNode
            try? input.setVoiceProcessingEnabled(true)
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: networkFormat)

            let inputFormat = input.outputFormat(forBus: 0)
            guard let converter = AVAudioConverter(from: inputFormat, to: networkFormat) else {
                throw AudioTransportError.converterUnavailable
            }

            input.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat) { [weak self] buffer, _ in
    guard let self else { return }
    self.capture(buffer, using: converter)
}
inputTapInstalled = true

engine.prepare()
            try engine.start()
            player.play()
            audioStarted = true
        } catch {
            onError?("Could not start call audio: \(error.localizedDescription)")
            stopAudio()
        }
    }

    private func capture(_ inputBuffer: AVAudioPCMBuffer, using converter: AVAudioConverter) {
        muteLock.lock()
        let shouldMute = muted
        muteLock.unlock()
        guard !shouldMute, !session.connectedPeers.isEmpty else { return }

        let ratio = Self.audioSampleRate / inputBuffer.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(inputBuffer.frameLength) * ratio) + 32)
        guard let converted = AVAudioPCMBuffer(pcmFormat: networkFormat, frameCapacity: capacity) else { return }

        var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: converted, error: &conversionError) { _, inputStatus in
            guard !suppliedInput else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return inputBuffer
        }
        guard status != .error, conversionError == nil,
              let samples = converted.floatChannelData?[0] else { return }

        let byteCount = Int(converted.frameLength) * MemoryLayout<Float>.size
        guard byteCount > 0 else { return }
        let frame = Data(bytes: samples, count: byteCount)
        do {
            try session.send(frame, toPeers: session.connectedPeers, with: .unreliable)
        } catch {
            DispatchQueue.main.async { [weak self] in
                self?.onError?("Could not send call audio: \(error.localizedDescription)")
            }
        }
    }

    private func play(_ frame: Data) {
        let sampleSize = MemoryLayout<Float>.size
        guard !frame.isEmpty, frame.count <= 8_192, frame.count.isMultiple(of: sampleSize) else { return }
        let frameCount = AVAudioFrameCount(frame.count / sampleSize)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: networkFormat, frameCapacity: frameCount),
              let destination = buffer.floatChannelData?[0] else { return }
        frame.withUnsafeBytes { bytes in
            guard let source = bytes.baseAddress else { return }
            destination.update(from: source.assumingMemoryBound(to: Float.self), count: Int(frameCount))
        }
        buffer.frameLength = frameCount
        player.scheduleBuffer(buffer)
    }

    private func stopAudio() {
        guard audioStarted || engine.isRunning || inputTapInstalled || engine.attachedNodes.contains(player) else {
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    return
}
    engine.inputNode.removeTap(onBus: 0)
    inputTapInstalled = false
}
        player.stop()
        engine.stop()
        engine.reset()
        if engine.attachedNodes.contains(player) {
            engine.disconnectNodeOutput(player)
            engine.detach(player)
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        audioStarted = false
    }
}

extension NearbyAudioService: MCNearbyServiceAdvertiserDelegate {
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser,
                    didReceiveInvitationFromPeer peerID: MCPeerID,
                    withContext context: Data?,
                    invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.pendingInvitation == nil else {
                invitationHandler(false, nil)
                return
            }
            self.pendingInvitation = invitationHandler
            self.onIncomingCall?(peerID)
        }
    }
}

extension NearbyAudioService: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
           var peers = self.discoveredPeers
            if !peers.contains(peerID) { peers.append(peerID) }
self.discoveredPeers = peers
self.onPeersChanged?(peers)
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
    DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.discoveredPeers.removeAll { $0 == peerID }
        self.onPeersChanged?(self.discoveredPeers)
    }
}

    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.onError?("Nearby discovery could not start: \(error.localizedDescription)")
        }
    }
}

extension NearbyAudioService: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        switch state {
        case .connected:
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.startAudio()
                self.onConnected?(peerID)
            }
        case .notConnected:
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.stopAudio()
                self.onDisconnected?()
            }
        case .connecting:
            break
        @unknown default:
            break
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        playbackQueue.async { [weak self] in self?.play(data) }
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

private enum AudioTransportError: LocalizedError {
    case converterUnavailable

    var errorDescription: String? {
        "The device audio format could not be prepared for the call."
    }
}
