import Foundation

/// Signaling events exchanged between two authenticated FreeVoice users.
/// The signaling provider is intentionally unspecified (no backend SDK here).
enum CallSignalType: String, Codable, Sendable {
    case invitation
    case accepted
    case rejected
    case offer
    case answer
    case iceCandidate
    case ended
}

/// Stable app-level identities are used here, never MCPeerID or device names.
struct CallSignalMessage: Codable, Identifiable, Sendable {
    let id: UUID
    let callID: UUID
    let senderID: String
    let recipientID: String
    let type: CallSignalType
    let sentAt: Date

    // Invitation metadata
    let displayName: String?

    // SDP offer/answer payload
    let sdp: String?
    let sdpType: String?

    // ICE candidate payload
    let candidate: String?
    let sdpMid: String?
    let sdpMLineIndex: Int32?

    init(
        id: UUID = UUID(),
        callID: UUID,
        senderID: String,
        recipientID: String,
        type: CallSignalType,
        sentAt: Date = Date(),
        displayName: String? = nil,
        sdp: String? = nil,
        sdpType: String? = nil,
        candidate: String? = nil,
        sdpMid: String? = nil,
        sdpMLineIndex: Int32? = nil
    ) {
        self.id = id
        self.callID = callID
        self.senderID = senderID
        self.recipientID = recipientID
        self.type = type
        self.sentAt = sentAt
        self.displayName = displayName
        self.sdp = sdp
        self.sdpType = sdpType
        self.candidate = candidate
        self.sdpMid = sdpMid
        self.sdpMLineIndex = sdpMLineIndex
    }
}

enum CallSignalingState: Sendable {
    case disconnected
    case connecting
    case connected
    case failed
}

/// Backend-neutral contract for call invitations and WebRTC negotiation.
/// A future implementation must authenticate users and authorize every
/// sender/recipient/callID relationship on the server.
@MainActor
protocol CallSignalingClient: AnyObject {
    var onMessage: ((CallSignalMessage) -> Void)? { get set }
    var onStateChanged: ((CallSignalingState) -> Void)? { get set }
    var onError: ((String) -> Void)? { get set }

    func connect() async throws
    func send(_ message: CallSignalMessage) async throws
    func disconnect()
}
