import AVFoundation
import Darwin
import Foundation
import MultipeerConnectivity
import UIKit

/// Nearby-only audio transport. PCM packets use mono Float32 at 16 kHz and are
/// sent unreliably to favor low latency. MultipeerConnectivity encrypts its session.
final class NearbyAudioService: NSObject {
    private static let serviceType = "freevoice"
    private static let sampleRate = 16_000.0
    private static let maximumPacketBytes = 8_192
    private static let maximumQueuedPackets = 8

    var onPeersChanged: (([MCPeerID]) -> Void)?
    var onIncomingCall: ((MCPeerID) -> Void)?
    var onConnected: ((MCPeerID) -> Void)?
    var onDisconnected: ((MCPeerID) -> Void)?
    var onError: ((String) -> Void)?

    private let localPeer = MCPeerID(displayName: UIDevice.current.name)
    private lazy var session = MCSession(peer: localPeer, securityIdentity: nil, encryptionPreference: .required)
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private var pendingInvitation: ((Bool, MCSession?) -> Void)?
    private var discoveredPeers: [MCPeerID] = []

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let audioQueue = DispatchQueue(label: "FreeVoice.audio")
    private let receiveLock = NSLock()
    private let muteLock = NSLock()
    private var queuedIncomingPackets = 0
    private var muted = false
    private var audioStarted = false
    private var inputTapInstalled = false
    private var scheduledPlaybackBuffers = 0
    private var playbackGeneration: UInt64 = 0

    private var pcmFormat: AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32,
                      sampleRate: Self.sampleRate,
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

    func rejectIncomingCall() {
        guard let invitation = pendingInvitation else { return }
        pendingInvitation = nil
        invitation(false, nil)
    }

    func endCall() {
        rejectIncomingCall()
        session.disconnect()
        audioQueue.async { [weak self] in self?.stopAudio() }
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
        dispatchPrecondition(condition: .onQueue(audioQueue))
        guard !audioStarted else { return }

        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth])
            try audioSession.setActive(true)

            let input = engine.inputNode
            try input.setVoiceProcessingEnabled(true)
            let inputFormat = input.outputFormat(forBus: 0)
            guard let converter = AVAudioConverter(from: inputFormat, to: pcmFormat) else {
                throw AudioTransportError.converterUnavailable
            }

            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: pcmFormat)
            input.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat) { [weak self] buffer, _ in
                self?.capture(buffer, using: converter)
            }
            inputTapInstalled = true

            engine.prepare()
            try engine.start()
            player.play()
            playbackGeneration &+= 1
            scheduledPlaybackBuffers = 0
            audioStarted = true
        } catch {
            onError?("Could not start call audio: \(error.localizedDescription)")
            stopAudio()
            session.disconnect()
        }
    }

    private func capture(_ inputBuffer: AVAudioPCMBuffer, using converter: AVAudioConverter) {
        muteLock.lock()
        let shouldMute = muted
        muteLock.unlock()
        guard !shouldMute, !session.connectedPeers.isEmpty else { return }

        let ratio = Self.sampleRate / inputBuffer.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(inputBuffer.frameLength) * ratio) + 64)
        guard capacity > 0,
              let converted = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: capacity) else { return }

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
              converted.frameLength > 0,
              let samples = converted.floatChannelData?[0] else { return }

        let byteCount = Int(converted.frameLength) * MemoryLayout<Float>.size
        guard byteCount > 0, byteCount <= Self.maximumPacketBytes else { return }
        let packet = Data(bytes: samples, count: byteCount)
        do {
            try session.send(packet, toPeers: session.connectedPeers, with: .unreliable)
        } catch {
            DispatchQueue.main.async { [weak self] in
                self?.onError?("Could not send call audio: \(error.localizedDescription)")
            }
        }
    }

    private func enqueuePlayback(_ packet: Data) {
        guard !packet.isEmpty,
              packet.count <= Self.maximumPacketBytes,
              packet.count.isMultiple(of: MemoryLayout<Float>.size) else { return }

        receiveLock.lock()
        guard queuedIncomingPackets < Self.maximumQueuedPackets else {
            receiveLock.unlock()
            return
        }
        queuedIncomingPackets += 1
        receiveLock.unlock()

        audioQueue.async { [weak self] in
            guard let self else { return }
            self.play(packet)
            self.receiveLock.lock()
            self.queuedIncomingPackets = max(0, self.queuedIncomingPackets - 1)
            self.receiveLock.unlock()
        }
    }

    private func play(_ packet: Data) {
        dispatchPrecondition(condition: .onQueue(audioQueue))
        guard audioStarted,
              scheduledPlaybackBuffers < Self.maximumQueuedPackets else { return }

        let frameCount = packet.count / MemoryLayout<Float>.size
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: AVAudioFrameCount(frameCount)),
              let destination = buffer.floatChannelData?[0] else { return }

        let copied = packet.withUnsafeBytes { source -> Bool in
            guard let baseAddress = source.baseAddress else { return false }
            memcpy(destination, baseAddress, packet.count)
            return true
        }
        guard copied else { return }

        buffer.frameLength = AVAudioFrameCount(frameCount)
        scheduledPlaybackBuffers += 1
        let generation = playbackGeneration
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self else { return }
            self.audioQueue.async {
                guard self.playbackGeneration == generation else { return }
                self.scheduledPlaybackBuffers = max(0, self.scheduledPlaybackBuffers - 1)
            }
        }
    }

    private func stopAudio() {
        dispatchPrecondition(condition: .onQueue(audioQueue))
        playbackGeneration &+= 1
        scheduledPlaybackBuffers = 0

        if inputTapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            inputTapInstalled = false
        }
        player.stop()
        engine.stop()
        if engine.attachedNodes.contains(player) {
            engine.disconnectNodeOutput(player)
            engine.detach(player)
        }
        engine.reset()
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
            guard let self, self.pendingInvitation == nil, self.session.connectedPeers.isEmpty else {
                invitationHandler(false, nil)
                return
            }
            self.pendingInvitation = invitationHandler
            self.onIncomingCall?(peerID)
        }
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.onError?("Nearby advertising could not start: \(error.localizedDescription)")
        }
    }
}

extension NearbyAudioService: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if !self.discoveredPeers.contains(peerID) {
                self.discoveredPeers.append(peerID)
            }
            self.onPeersChanged?(self.discoveredPeers)
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
            audioQueue.async { [weak self] in
                guard let self else { return }
                self.startAudio()
                guard self.audioStarted else { return }
                DispatchQueue.main.async { self.onConnected?(peerID) }
            }
        case .notConnected:
            audioQueue.async { [weak self] in self?.stopAudio() }
            DispatchQueue.main.async { [weak self] in self?.onDisconnected?(peerID) }
        case .connecting:
            break
        @unknown default:
            break
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        enqueuePlayback(data)
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
