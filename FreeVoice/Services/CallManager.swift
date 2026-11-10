import Combine
import Foundation
import MultipeerConnectivity

@MainActor
final class CallManager: ObservableObject {
    @Published private(set) var activeCall: CallSession?
    @Published private(set) var recentCalls: [CallSession] = []
    @Published private(set) var nearbyPeers: [MCPeerID] = []
    @Published var errorMessage: String?

    private let nearbyAudio = NearbyAudioService()
    private var activePeer: MCPeerID?

    init() {
        nearbyAudio.onPeersChanged = { [weak self] peers in
            Task { @MainActor in self?.nearbyPeers = peers }
        }
        nearbyAudio.onIncomingCall = { [weak self] peer in
            Task { @MainActor in
                guard let self else { return }
                guard self.activeCall == nil else {
                    self.nearbyAudio.rejectIncomingCall()
                    return
                }
                self.activePeer = peer
                self.activeCall = CallSession(contactName: peer.displayName, status: .incoming)
            }
        }
        nearbyAudio.onConnected = { [weak self] peer in
            Task { @MainActor in
                guard let self, self.activePeer == peer, var call = self.activeCall else { return }
                call.status = .connected
                self.activeCall = call
            }
        }
        nearbyAudio.onDisconnected = { [weak self] peer in
            Task { @MainActor in
                guard let self, self.activePeer == peer, let call = self.activeCall else { return }
                if call.status == .connected {
                    self.recordCompletedCall(call)
                } else if call.status == .outgoing {
                    self.errorMessage = "The nearby call did not connect. The other iPhone may have declined or disconnected."
                }
                self.activeCall = nil
                self.activePeer = nil
            }
        }
        nearbyAudio.onError = { [weak self] message in
            Task { @MainActor in self?.errorMessage = message }
        }
        nearbyAudio.startDiscovery()
    }

    func startCall(with peer: MCPeerID) {
        guard activeCall == nil else { return }
        let call = CallSession(contactName: peer.displayName, status: .outgoing)
        activeCall = call
        activePeer = peer

        nearbyAudio.requestMicrophonePermission { [weak self] granted in
            Task { @MainActor in
                guard let self,
                      self.activeCall?.id == call.id,
                      self.activeCall?.status == .outgoing else { return }
                guard granted else {
                    self.nearbyAudio.endCall()
                    self.activeCall = nil
                    self.activePeer = nil
                    self.errorMessage = "Microphone access is required to make a voice call. Enable it for FreeVoice in Settings."
                    return
                }
                self.nearbyAudio.invite(peer)
            }
        }
    }

    func acceptCall() {
        guard let call = activeCall, call.status == .incoming else { return }
        nearbyAudio.requestMicrophonePermission { [weak self] granted in
            Task { @MainActor in
                guard let self,
                      self.activeCall?.id == call.id,
                      self.activeCall?.status == .incoming else { return }
                guard granted else {
                    self.nearbyAudio.rejectIncomingCall()
                    self.activeCall = nil
                    self.activePeer = nil
                    self.errorMessage = "Microphone access is required to answer. Enable it for FreeVoice in Settings."
                    return
                }
                self.nearbyAudio.acceptIncomingCall()
            }
        }
    }

    func toggleMute() {
        guard var call = activeCall else { return }
        call.isMuted.toggle()
        nearbyAudio.setMuted(call.isMuted)
        activeCall = call
    }

    func toggleSpeaker() {
        guard var call = activeCall else { return }
        call.isSpeakerEnabled.toggle()
        nearbyAudio.setSpeakerEnabled(call.isSpeakerEnabled)
        activeCall = call
    }

    func endCall() {
        guard let call = activeCall else { return }
        if call.status == .connected {
            recordCompletedCall(call)
        }
        if call.status == .incoming {
            nearbyAudio.rejectIncomingCall()
        } else {
            nearbyAudio.endCall()
        }
        activeCall = nil
        activePeer = nil
    }

    func dismissError() {
        errorMessage = nil
    }

    private func recordCompletedCall(_ call: CallSession) {
        recentCalls.insert(
            CallSession(
                contactName: call.contactName,
                status: .idle,
                isMuted: call.isMuted,
                isSpeakerEnabled: call.isSpeakerEnabled
            ),
            at: 0
        )
    }
}
