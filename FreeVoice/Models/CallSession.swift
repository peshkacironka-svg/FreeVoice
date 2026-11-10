import Foundation

struct CallSession: Identifiable, Equatable {
    let id: UUID
    let contactName: String
    var status: CallStatus
    var isMuted: Bool
    var isSpeakerEnabled: Bool

    init(
        id: UUID = UUID(),
        contactName: String,
        status: CallStatus,
        isMuted: Bool = false,
        isSpeakerEnabled: Bool = false
    ) {
        self.id = id
        self.contactName = contactName
        self.status = status
        self.isMuted = isMuted
        self.isSpeakerEnabled = isSpeakerEnabled
    }
}

enum CallStatus: String {
    case idle
    case outgoing
    case incoming
    case connected
}
