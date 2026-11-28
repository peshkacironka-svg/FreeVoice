import Foundation
import MultipeerConnectivity

/// The app-facing call transport contract.
///
/// This first version intentionally preserves the existing nearby-peer API so
/// the current iPhone experience can be moved behind an abstraction safely.
/// Internet calling will use a separate participant identity and signaling
/// model; it must not pretend that an MCPeerID is an Internet user identity.
@MainActor
protocol CallTransport: AnyObject {
    var onPeersChanged: (([MCPeerID]) -> Void)? { get set }
    var onIncomingCall: ((MCPeerID) -> Void)? { get set }
    var onConnected: ((MCPeerID) -> Void)? { get set }
    var onDisconnected: ((MCPeerID) -> Void)? { get set }
    var onError: ((String) -> Void)? { get set }

    func startDiscovery()
    func requestMicrophonePermission(_ completion: @escaping (Bool) -> Void)
    func invite(_ peer: MCPeerID)
    func acceptIncomingCall()
    func rejectIncomingCall()
    func endCall(with peer: MCPeerID?)
    func setMuted(_ value: Bool)
    func setSpeakerEnabled(_ enabled: Bool)
}
