import FirebaseFirestore
import SwiftUI
import WebRTC

@MainActor
final class InternetCallManager: ObservableObject {
    @Published var destinationUID = ""
    @Published private(set) var incomingCallID: String?
    @Published private(set) var incomingCallerUID: String?
    @Published private(set) var activeCallID: String?
    @Published private(set) var statusText = "Ready for an Internet call"
    @Published private(set) var isMuted = false
    @Published var errorMessage: String?

    private let signaling = CallSignalingService()
    private var localUID: String?
    private var userCallsListener: ListenerRegistration?
    private var callListener: ListenerRegistration?
    private var candidatesListener: ListenerRegistration?
    private var audio: WebRTCAudioService?
    private var remoteDescriptionApplied = false
    private var answerSubmitted = false

    func startListening(uid: String) {
        guard localUID != uid else { return }
        stopListening()
        localUID = uid
        userCallsListener = signaling.observeCallsForUser(uid: uid) { [weak self] documents in
            Task { @MainActor in
                guard let self, self.activeCallID == nil, self.incomingCallID == nil else { return }
                guard let invitation = documents.first(where: {
                    $0.data()["calleeUid"] as? String == uid &&
                    $0.data()["status"] as? String == "ringing"
                }) else { return }
                self.incomingCallID = invitation.documentID
                self.incomingCallerUID = invitation.data()["callerUid"] as? String
                self.statusText = "Incoming Internet call"
            }
        }
    }

    func stopListening() {
        userCallsListener?.remove()
        userCallsListener = nil
        if let callId = activeCallID {
            signaling.endCall(callId: callId) { _ in }
        }
        cleanupActiveCall()
        incomingCallID = nil
        incomingCallerUID = nil
        localUID = nil
    }

    func startCall() {
        guard let uid = localUID else { return }
        let recipient = destinationUID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !recipient.isEmpty, recipient != uid else {
            errorMessage = "Enter a different recipient's Firebase user UID."
            return
        }
        guard activeCallID == nil, incomingCallID == nil else { return }

        statusText = "Creating secure call invitation…"
        signaling.createCall(calleeUID: recipient) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .failure(let error):
                    self.statusText = "Could not start call"
                    self.errorMessage = error.localizedDescription
                case .success(let callId):
                    self.activeCallID = callId
                    self.statusText = "Calling…"
                    self.prepareAudioAndSignaling(callId: callId)
                    self.audio?.createOffer { [weak self] offerResult in
                        guard let self else { return }
                        switch offerResult {
                        case .failure(let error):
                            Task { @MainActor in self.failCall(error) }
                        case .success(let sdp):
                            self.signaling.setDescription(callId: callId, type: "offer", sdp: sdp) { result in
                                if case .failure(let error) = result {
                                    Task { @MainActor in self.failCall(error) }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    func answerIncomingCall() {
        guard let callId = incomingCallID else { return }
        signaling.respondToCall(callId: callId, accepted: true) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .failure(let error):
                    self.errorMessage = error.localizedDescription
                case .success:
                    self.activeCallID = callId
                    self.incomingCallID = nil
                    self.statusText = "Connecting…"
                    self.prepareAudioAndSignaling(callId: callId)
                }
            }
        }
    }

    func rejectIncomingCall() {
        guard let callId = incomingCallID else { return }
        signaling.respondToCall(callId: callId, accepted: false) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                if case .failure(let error) = result {
                    self.errorMessage = error.localizedDescription
                }
                self.incomingCallID = nil
                self.incomingCallerUID = nil
                self.statusText = "Invitation declined"
            }
        }
    }

    func toggleMute() {
        isMuted.toggle()
        audio?.setMuted(isMuted)
    }

    func endCall() {
        guard let callId = activeCallID else { return }
        signaling.endCall(callId: callId) { [weak self] result in
            Task { @MainActor in
                if case .failure(let error) = result {
                    self?.errorMessage = error.localizedDescription
                }
                self?.cleanupActiveCall()
                self?.statusText = "Call ended"
            }
        }
    }

    func clearError() {
        errorMessage = nil
    }

    private func prepareAudioAndSignaling(callId: String) {
        guard let uid = localUID else { return }
        do {
            let connection = try WebRTCAudioService()
            audio = connection
            remoteDescriptionApplied = false
            answerSubmitted = false

            connection.onLocalCandidate = { [weak self] candidate in
                guard let self else { return }
                self.signaling.addCandidate(
                    callId: callId,
                    sdp: candidate.sdp,
                    sdpMid: candidate.sdpMid,
                    sdpMLineIndex: candidate.sdpMLineIndex
                ) { result in
                    if case .failure(let error) = result {
                        Task { @MainActor in self.errorMessage = error.localizedDescription }
                    }
                }
            }
            connection.onConnectionStateChanged = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .connected, .completed:
                        self?.statusText = "Connected"
                    case .failed:
                        self?.statusText = "Connection failed — check TURN configuration"
                    case .disconnected:
                        self?.statusText = "Connection interrupted"
                    case .closed:
                        self?.statusText = "Call closed"
                    default:
                        self?.statusText = "Connecting…"
                    }
                }
            }

            callListener = signaling.observeCall(callId: callId) { [weak self] data in
                Task { @MainActor in self?.handleCallUpdate(data, callId: callId) }
            }
            candidatesListener = signaling.observeRemoteCandidates(
                callId: callId,
                localUID: uid
            ) { [weak self] candidate in
                guard let sdp = candidate["sdp"] as? String,
                      let line = candidate["sdpMLineIndex"] as? Int else { return }
                let mid = candidate["sdpMid"] as? String
                Task { @MainActor in
                    self?.audio?.addRemoteCandidate(
                        sdp: sdp,
                        sdpMid: mid,
                        sdpMLineIndex: Int32(line)
                    )
                }
            }
        } catch {
            failCall(error)
        }
    }

    private func handleCallUpdate(_ data: [String: Any]?, callId: String) {
        guard let data else { return }
        let status = data["status"] as? String ?? ""
        if ["ended", "rejected", "expired"].contains(status) {
            cleanupActiveCall()
            statusText = status == "expired" ? "Call invitation expired" : "Call ended"
            return
        }

        guard let uid = localUID else { return }
        if data["callerUid"] as? String == uid,
           let answer = data["answerSdp"] as? String,
           !remoteDescriptionApplied {
            audio?.acceptAnswer(answer) { [weak self] error in
                Task { @MainActor in
                    if let error {
                        self?.failCall(error)
                    } else {
                        self?.remoteDescriptionApplied = true
                    }
                }
            }
        } else if data["calleeUid"] as? String == uid,
                  let offer = data["offerSdp"] as? String,
                  status == "accepted",
                  !answerSubmitted {
            answerSubmitted = true
            audio?.acceptOffer(offer) { [weak self] result in
                guard let self else { return }
                switch result {
                case .failure(let error):
                    Task { @MainActor in self.failCall(error) }
                case .success(let answer):
                    self.signaling.setDescription(
                        callId: callId,
                        type: "answer",
                        sdp: answer
                    ) { result in
                        if case .failure(let error) = result {
                            Task { @MainActor in self.failCall(error) }
                        }
                    }
                }
            }
        }
    }

    private func failCall(_ error: Error) {
        errorMessage = error.localizedDescription
        if let callId = activeCallID {
            signaling.endCall(callId: callId) { _ in }
        }
        cleanupActiveCall()
        statusText = "Call failed"
    }

    private func cleanupActiveCall() {
        callListener?.remove()
        callListener = nil
        candidatesListener?.remove()
        candidatesListener = nil
        audio?.close()
        audio = nil
        activeCallID = nil
        remoteDescriptionApplied = false
        answerSubmitted = false
        isMuted = false
    }
}

struct InternetCallView: View {
    let userUID: String
    @StateObject private var manager = InternetCallManager()

    var body: some View {
        VStack(spacing: 12) {
            Text("Internet voice calls")
                .font(.headline)

            Text("Your FreeVoice UID: \\(userUID)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            if let incomingCallID = manager.incomingCallID {
                VStack(spacing: 8) {
                    Text("Incoming call")
                        .font(.subheadline.weight(.semibold))
                    Text("From: \(manager.incomingCallerUID ?? "FreeVoice user")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Accept", systemImage: "phone.fill") {
                            manager.answerIncomingCall()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                        Button("Decline", systemImage: "phone.down.fill") {
                            manager.rejectIncomingCall()
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityIdentifier("incomingInternetCall")
            } else if manager.activeCallID != nil {
                VStack(spacing: 10) {
                    Text(manager.statusText)
                        .font(.subheadline.weight(.medium))
                    HStack {
                        Button(manager.isMuted ? "Unmute" : "Mute", systemImage: manager.isMuted ? "mic.slash.fill" : "mic.fill") {
                            manager.toggleMute()
                        }
                        .buttonStyle(.bordered)
                        Button("End call", systemImage: "phone.down.fill", role: .destructive) {
                            manager.endCall()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            } else {
                TextField("Recipient Firebase UID", text: $manager.destinationUID)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("recipientUIDField")
                Button("Start Internet call", systemImage: "phone.fill") {
                    manager.startCall()
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(manager.destinationUID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Text(manager.statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .onAppear { manager.startListening(uid: userUID) }
        .onDisappear { manager.stopListening() }
        .alert("Internet call", isPresented: Binding(
            get: { manager.errorMessage != nil },
            set: { if !$0 { manager.clearError() } }
        )) {
            Button("OK", role: .cancel) { manager.clearError() }
        } message: {
            Text(manager.errorMessage ?? "An unexpected error occurred.")
        }
    }
}
