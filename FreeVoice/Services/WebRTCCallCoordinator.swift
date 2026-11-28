import Foundation
import WebRTC

/// Coordinates call signaling and WebRTC negotiation without depending on a
/// specific backend. A concrete, authenticated CallSignalingClient is injected.
@MainActor
final class WebRTCCallCoordinator {
    struct IncomingInvitation {
        let callID: UUID
        let callerID: String
        let displayName: String?
    }

    private let localUserID: String
    private let signaling: CallSignalingClient
    private let iceServers: [RTCIceServer]

    private(set) var activeCallID: UUID?
    private(set) var remoteUserID: String?
    private(set) var incomingInvitation: IncomingInvitation?
    private(set) var isConnected = false

    var onIncomingInvitation: ((IncomingInvitation) -> Void)?
    var onConnectionStateChanged: ((WebRTCPeerConnection.ConnectionState) -> Void)?
    var onRemoteAudioTrack: ((RTCAudioTrack) -> Void)?
    var onError: ((String) -> Void)?

    private var peerConnection: WebRTCPeerConnection?
    private var hasRemoteDescription = false
    private var pendingRemoteCandidates: [RTCIceCandidate] = []

    init(
        localUserID: String,
        signaling: CallSignalingClient,
        iceServers: [RTCIceServer]
    ) {
        self.localUserID = localUserID
        self.signaling = signaling
        self.iceServers = iceServers

        signaling.onMessage = { [weak self] message in
            Task { @MainActor in
                await self?.handle(message)
            }
        }
        signaling.onError = { [weak self] message in
            self?.onError?(message)
        }
    }

    func connect() async throws {
        try await signaling.connect()
    }

    func startOutgoingCall(to recipientID: String, displayName: String? = nil) async throws {
        guard !recipientID.isEmpty, recipientID != localUserID else {
            throw WebRTCCallCoordinatorError.invalidParticipant
        }
        guard activeCallID == nil else {
            throw WebRTCCallCoordinatorError.callAlreadyActive
        }

        let callID = UUID()
        activeCallID = callID
        remoteUserID = recipientID

        do {
            try await send(type: .invitation, displayName: displayName)
        } catch {
            resetCall()
            throw error
        }
    }

    func acceptIncomingCall() async throws {
        guard let invitation = incomingInvitation, activeCallID == nil else {
            throw WebRTCCallCoordinatorError.noIncomingInvitation
        }
        activeCallID = invitation.callID
        remoteUserID = invitation.callerID
        incomingInvitation = nil

        do {
            try await send(type: .accepted)
        } catch {
            await endCall()
            throw error
        }
    }

    func rejectIncomingCall() async throws {
        guard let invitation = incomingInvitation else {
            throw WebRTCCallCoordinatorError.noIncomingInvitation
        }
        activeCallID = invitation.callID
        remoteUserID = invitation.callerID
        incomingInvitation = nil
        try await send(type: .rejected)
        resetCall()
    }

    func endCall() async {
        if activeCallID != nil, remoteUserID != nil {
            try? await send(type: .ended)
        }
        resetCall()
    }

    func setMicrophoneEnabled(_ enabled: Bool) {
        peerConnection?.setMicrophoneEnabled(enabled)
    }

    private func handle(_ message: CallSignalMessage) async {
        guard message.recipientID == localUserID,
              message.senderID != localUserID,
              !message.senderID.isEmpty else { return }

        if message.type == .invitation {
            guard activeCallID == nil, incomingInvitation == nil else { return }
            incomingInvitation = IncomingInvitation(
                callID: message.callID,
                callerID: message.senderID,
                displayName: message.displayName
            )
            onIncomingInvitation?(incomingInvitation!)
            return
        }

        guard message.callID == activeCallID,
              message.senderID == remoteUserID else { return }

        do {
            switch message.type {
            case .accepted:
                // The caller creates the offer after the callee accepts.
                if peerConnection == nil {
                    try makePeerConnection()
                    try await createAndSendOffer()
                }
            case .rejected, .ended:
                resetCall()
            case .offer:
                try await receiveOffer(message)
            case .answer:
                try await receiveAnswer(message)
            case .iceCandidate:
                try await receiveICECandidate(message)
            case .invitation:
                break
            }
        } catch {
            onError?(error.localizedDescription)
            resetCall()
        }
    }

    private func makePeerConnection() throws {
        guard peerConnection == nil else { return }
        let peer = try WebRTCPeerConnection(iceServers: iceServers)
        peer.onLocalICECandidate = { [weak self] candidate in
            Task { @MainActor in
                await self?.sendICECandidate(candidate)
            }
        }
        peer.onConnectionStateChanged = { [weak self] state in
            Task { @MainActor in
                self?.isConnected = state == .connected
                self?.onConnectionStateChanged?(state)
            }
        }
        peer.onRemoteAudioTrack = { [weak self] track in
            Task { @MainActor in self?.onRemoteAudioTrack?(track) }
        }
        peer.onError = { [weak self] error in
            Task { @MainActor in self?.onError?(error.localizedDescription) }
        }
        peerConnection = peer
    }

    private func createAndSendOffer() async throws {
        try makePeerConnection()
        let offer = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<RTCSessionDescription, Error>) in
            peerConnection?.createOffer { result in continuation.resume(with: result) }
        }
        try await send(type: .offer, sdp: offer.sdp, sdpType: "offer")
    }

    private func receiveOffer(_ message: CallSignalMessage) async throws {
        guard let sdp = message.sdp, message.sdpType == "offer" else {
            throw WebRTCCallCoordinatorError.invalidSessionDescription
        }
        try makePeerConnection()
        let offer = RTCSessionDescription(type: .offer, sdp: sdp)
        try await setRemoteDescription(offer)
        try await flushPendingCandidates()

        let answer = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<RTCSessionDescription, Error>) in
            peerConnection?.createAnswer { result in continuation.resume(with: result) }
        }
        try await send(type: .answer, sdp: answer.sdp, sdpType: "answer")
    }

    private func receiveAnswer(_ message: CallSignalMessage) async throws {
        guard let sdp = message.sdp, message.sdpType == "answer" else {
            throw WebRTCCallCoordinatorError.invalidSessionDescription
        }
        try await setRemoteDescription(RTCSessionDescription(type: .answer, sdp: sdp))
        try await flushPendingCandidates()
    }

    private func setRemoteDescription(_ description: RTCSessionDescription) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            peerConnection?.setRemoteDescription(description) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: ()) }
            }
        }
        hasRemoteDescription = true
    }

    private func receiveICECandidate(_ message: CallSignalMessage) async throws {
        guard let candidateText = message.candidate,
              let lineIndex = message.sdpMLineIndex else {
            throw WebRTCCallCoordinatorError.invalidICECandidate
        }
        let candidate = RTCIceCandidate(
            sdp: candidateText,
            sdpMLineIndex: lineIndex,
            sdpMid: message.sdpMid
        )
        guard hasRemoteDescription else {
            pendingRemoteCandidates.append(candidate)
            return
        }
        try await addRemoteCandidate(candidate)
    }

    private func flushPendingCandidates() async throws {
        let candidates = pendingRemoteCandidates
        pendingRemoteCandidates.removeAll()
        for candidate in candidates {
            try await addRemoteCandidate(candidate)
        }
    }

    private func addRemoteCandidate(_ candidate: RTCIceCandidate) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            peerConnection?.addRemoteICECandidate(candidate) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: ()) }
            }
        }
    }

    private func sendICECandidate(_ candidate: RTCIceCandidate) async {
        do {
            try await send(
                type: .iceCandidate,
                candidate: candidate.sdp,
                sdpMid: candidate.sdpMid,
                sdpMLineIndex: candidate.sdpMLineIndex
            )
        } catch {
            onError?(error.localizedDescription)
        }
    }

    private func send(
        type: CallSignalType,
        displayName: String? = nil,
        sdp: String? = nil,
        sdpType: String? = nil,
        candidate: String? = nil,
        sdpMid: String? = nil,
        sdpMLineIndex: Int32? = nil
    ) async throws {
        guard let callID = activeCallID, let recipientID = remoteUserID else {
            throw WebRTCCallCoordinatorError.noActiveCall
        }
        let message = CallSignalMessage(
            callID: callID,
            senderID: localUserID,
            recipientID: recipientID,
            type: type,
            displayName: displayName,
            sdp: sdp,
            sdpType: sdpType,
            candidate: candidate,
            sdpMid: sdpMid,
            sdpMLineIndex: sdpMLineIndex
        )
        try await signaling.send(message)
    }

    private func resetCall() {
        peerConnection?.close()
        peerConnection = nil
        activeCallID = nil
        remoteUserID = nil
        incomingInvitation = nil
        hasRemoteDescription = false
        pendingRemoteCandidates.removeAll()
        isConnected = false
    }
}

enum WebRTCCallCoordinatorError: LocalizedError {
    case invalidParticipant
    case callAlreadyActive
    case noIncomingInvitation
    case noActiveCall
    case invalidSessionDescription
    case invalidICECandidate

    var errorDescription: String? {
        switch self {
        case .invalidParticipant: return "The selected call participant is invalid."
        case .callAlreadyActive: return "A call is already active."
        case .noIncomingInvitation: return "There is no incoming call to answer."
        case .noActiveCall: return "There is no active call."
        case .invalidSessionDescription: return "The received WebRTC session description is invalid."
        case .invalidICECandidate: return "The received ICE candidate is invalid."
        }
    }
}
