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

    init() {
        nearbyAudio.onPeersChanged = { [weak self] peers in
            self?.nearbyPeers = peers
        }
        nearbyAudio.onIncomingCall = { [weak self] peer in
            guard let self, self.activeCall == nil else { return }
            self.activeCall = CallSession(contactName: peer.displayName, status: .incoming)
        }
        nearbyAudio.onConnected = { [weak self] peer in
            guard let self else { return }
            self.activeCall = CallSession(contactName: peer.displayName, status: .connected)
        }
        nearbyAudio.onDisconnected = { [weak self] in
            guard let self, let call = self.activeCall else { return }
            self.recentCalls.insert(
                CallSession(contactName: call.contactName, status: .idle,
                            isMuted: call.isMuted, isSpeakerEnabled: call.isSpeakerEnabled),
                at: 0
            )
            self.activeCall = nil
        }
        nearbyAudio.onError = { [weak self] message in
            self?.errorMessage = message
        }
        nearbyAudio.startDiscovery()
    }

    func startCall(with peer: MCPeerID) {
        guard activeCall == nil else { return }
        activeCall = CallSession(contactName: peer.displayName, status: .outgoing)
        nearbyAudio.requestMicrophonePermission { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.activeCall = nil
                self.errorMessage = "Microphone access is required to make a voice call. Enable it for FreeVoice in Settings."
                return
            }
            self.nearbyAudio.invite(peer)
        }
    }

    func acceptCall() {
        guard activeCall?.status == .incoming else { return }
        nearbyAudio.requestMicrophonePermission { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.errorMessage = "Microphone access is required to answer. Enable it for FreeVoice in Settings."
                return
            }
            self.nearbyAudio.acceptIncomingCall()
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
        nearbyAudio.endCall()
        recentCalls.insert(
            CallSession(contactName: call.contactName, status: .idle,
                        isMuted: call.isMuted, isSpeakerEnabled: call.isSpeakerEnabled),
            at: 0
        )
        activeCall = nil
    }

    func dismissError() {
        errorMessage = nil
    }
}
