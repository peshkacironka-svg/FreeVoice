import Foundation
import WebRTC

/// Owns one WebRTC audio peer connection. Signaling is deliberately injected:
/// this type never contacts Supabase or any other backend by itself.
final class WebRTCPeerConnection: NSObject {
    enum ConnectionState {
        case new
        case connecting
        case connected
        case disconnected
        case failed
        case closed
    }

    private let factory: RTCPeerConnectionFactory
    private let peerConnection: RTCPeerConnection
    private let audioTrack: RTCAudioTrack

    var onLocalICECandidate: ((RTCIceCandidate) -> Void)?
    var onConnectionStateChanged: ((ConnectionState) -> Void)?
    var onRemoteAudioTrack: ((RTCAudioTrack) -> Void)?
    var onError: ((Error) -> Void)?

    /// Pass ICE servers supplied by the app's signaling/configuration layer.
    /// Production calls need both STUN discovery and a TURN relay service.
    init(iceServers: [RTCIceServer]) throws {
        factory = WebRTCModule.makePeerConnectionFactory()

        let audioSource = factory.audioSource(
            with: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        )
        audioTrack = factory.audioTrack(with: audioSource, trackId: "freevoice-audio")

        let configuration = RTCConfiguration()
        configuration.iceServers = iceServers
        configuration.sdpSemantics = .unifiedPlan

        let constraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: ["DtlsSrtpKeyAgreement": "true"]
        )

        guard let connection = factory.peerConnection(
            with: configuration,
            constraints: constraints,
            delegate: nil
        ) else {
            throw WebRTCPeerConnectionError.couldNotCreatePeerConnection
        }
        peerConnection = connection
        super.init()

        // WebRTC's delegate is weak; keep this object alive for the lifetime
        // of the peer connection.
        connection.delegate = self

        guard connection.add(audioTrack, streamIds: ["freevoice-audio"]) != nil else {
            throw WebRTCPeerConnectionError.couldNotAddLocalAudioTrack
        }
    }

    func setMicrophoneEnabled(_ enabled: Bool) {
        audioTrack.isEnabled = enabled
    }

    func createOffer(completion: @escaping (Result<RTCSessionDescription, Error>) -> Void) {
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: ["OfferToReceiveAudio": "true"],
            optionalConstraints: nil
        )
        peerConnection.offer(for: constraints) { [weak self] description, error in
            if let error {
                completion(.failure(error))
                self?.onError?(error)
                return
            }
            guard let description else {
                completion(.failure(WebRTCPeerConnectionError.missingSessionDescription))
                return
            }
            self?.peerConnection.setLocalDescription(description) { error in
                if let error {
                    completion(.failure(error))
                    self?.onError?(error)
                } else {
                    completion(.success(description))
                }
            }
        }
    }

    func createAnswer(completion: @escaping (Result<RTCSessionDescription, Error>) -> Void) {
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: ["OfferToReceiveAudio": "true"],
            optionalConstraints: nil
        )
        peerConnection.answer(for: constraints) { [weak self] description, error in
            if let error {
                completion(.failure(error))
                self?.onError?(error)
                return
            }
            guard let description else {
                completion(.failure(WebRTCPeerConnectionError.missingSessionDescription))
                return
            }
            self?.peerConnection.setLocalDescription(description) { error in
                if let error {
                    completion(.failure(error))
                    self?.onError?(error)
                } else {
                    completion(.success(description))
                }
            }
        }
    }

    func setRemoteDescription(
        _ description: RTCSessionDescription,
        completion: @escaping (Error?) -> Void
    ) {
        peerConnection.setRemoteDescription(description, completionHandler: completion)
    }

    func addRemoteICECandidate(
        _ candidate: RTCIceCandidate,
        completion: ((Error?) -> Void)? = nil
    ) {
        peerConnection.add(candidate, completionHandler: completion ?? { _ in })
    }

    func close() {
        peerConnection.close()
        onConnectionStateChanged?(.closed)
    }
}

extension WebRTCPeerConnection: RTCPeerConnectionDelegate {
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}

    func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didChange stateChanged: RTCSignalingState
    ) {}

    func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didAdd stream: RTCMediaStream
    ) {
        if let track = stream.audioTracks.first {
            onRemoteAudioTrack?(track)
        }
    }

    func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didRemove stream: RTCMediaStream
    ) {}

    func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didChange newState: RTCIceConnectionState
    ) {
        switch newState {
        case .checking:
            onConnectionStateChanged?(.connecting)
        case .connected, .completed:
            onConnectionStateChanged?(.connected)
        case .disconnected:
            onConnectionStateChanged?(.disconnected)
        case .failed:
            onConnectionStateChanged?(.failed)
        case .closed:
            onConnectionStateChanged?(.closed)
        default:
            onConnectionStateChanged?(.new)
        }
    }

    func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didChange newState: RTCIceGatheringState
    ) {}

    func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didGenerate candidate: RTCIceCandidate
    ) {
        onLocalICECandidate?(candidate)
    }

    func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didRemove candidates: [RTCIceCandidate]
    ) {}

    func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didOpen dataChannel: RTCDataChannel
    ) {}
}

enum WebRTCPeerConnectionError: LocalizedError {
    case couldNotCreatePeerConnection
    case couldNotAddLocalAudioTrack
    case missingSessionDescription

    var errorDescription: String? {
        switch self {
        case .couldNotCreatePeerConnection:
            return "Could not create the WebRTC peer connection."
        case .couldNotAddLocalAudioTrack:
            return "Could not add the local microphone audio track."
        case .missingSessionDescription:
            return "WebRTC did not create a session description."
        }
    }
}
