import Combine
import Foundation

@MainActor
final class CallManager: ObservableObject {
    @Published private(set) var activeCall: CallSession?
    @Published private(set) var recentCalls: [CallSession] = []

    // Signaling and real-time audio transport will be added in a later milestone.
    func startCall(to contactName: String) {
        activeCall = CallSession(contactName: contactName, status: .outgoing)
    }

    func acceptCall() {
        guard var call = activeCall, call.status == .incoming else { return }
        call.status = .connected
        activeCall = call
    }

    func toggleMute() {
        guard var call = activeCall else { return }
        call.isMuted.toggle()
        activeCall = call
    }

    func toggleSpeaker() {
        guard var call = activeCall else { return }
        call.isSpeakerEnabled.toggle()
        activeCall = call
    }

    func endCall() {
        guard let call = activeCall else { return }
        recentCalls.insert(call, at: 0)
        activeCall = nil
    }
}
