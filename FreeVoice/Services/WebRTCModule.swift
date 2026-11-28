import Foundation
import WebRTC

/// Creates the native WebRTC factory used by the future Internet-call transport.
///
/// This deliberately does not start a call or connect to a server. Signaling,
/// authenticated user identity, and STUN/TURN configuration must be supplied
/// before this factory is used for a real Internet call.
enum WebRTCModule {
    static func makePeerConnectionFactory() -> RTCPeerConnectionFactory {
        _ = RTCInitializeSSL()
        return RTCPeerConnectionFactory()
    }
}
