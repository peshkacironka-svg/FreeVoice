import AVFoundation
import Foundation
import WebRTC

/// Audio-only WebRTC transport. Signaling (SDP and ICE exchange) is supplied
/// by the authenticated Firebase call-signaling layer.
final class WebRTCAudioService: NSObject {
    enum ServiceError: LocalizedError {
        case peerConnectionUnavailable
        case descriptionCreationFailed
        case missingRemoteDescription

        var errorDescription: String? {
            switch self {
            case .peerConnectionUnavailable:
                return "Could not create a WebRTC peer connection."
            case .descriptionCreationFailed:
                return "WebRTC could not create a session description."
            case .missingRemoteDescription:
                return "A remote session description is required before creating an answer."
            }
        }
    }

    var onLocalCandidate: ((RTCIceCandidate) -> Void)?
    var onConnectionStateChanged: ((RTCIceConnectionState) -> Void)?

    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory(
            encoderFactory: RTCDefaultVideoEncoderFactory(),
            decoderFactory: RTCDefaultVideoDecoderFactory()
        )
    }()

    private let peerConnection: RTCPeerConnection
    private let audioTrack: RTCAudioTrack

    init(iceServers: [String] = ["stun:stun.l.google.com:19302"]) throws {
        let configuration = RTCConfiguration()
        // STUN helps discover public network paths. Production deployment must
        // also configure authenticated TURN credentials for reliable NAT traversal.
        configuration.iceServers = [RTCIceServer(urlStrings: iceServers)]
        configuration.sdpSemantics = .unifiedPlan
        configuration.continualGatheringPolicy = .gatherContinually

        let constraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: ["DtlsSrtpKeyAgreement": kRTCMediaConstraintsValueTrue]
        )

        guard let connection = Self.factory.peerConnection(
            with: configuration,
            constraints: constraints,
            delegate: nil
        ) else {
            throw ServiceError.peerConnectionUnavailable
        }

        peerConnection = connection
        let audioSource = Self.factory.audioSource(
            with: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        )
        audioTrack = Self.factory.audioTrack(with: audioSource, trackId: "freevoice-audio")

        super.init()

        peerConnection.delegate = self
        peerConnection.add(audioTrack, streamIds: ["freevoice-audio-stream"])
        configureAudioSession()
    }

    func createOffer(completion: @escaping (Result<String, Error>) -> Void) {
        let constraints = audioConstraints
        peerConnection.offer(for: constraints) { [weak self] description, error in
            guard let self else { return }
            if let error {
                completion(.failure(error))
                return
            }
            guard let description else {
                completion(.failure(ServiceError.descriptionCreationFailed))
                return
            }
            self.peerConnection.setLocalDescription(description) { error in
                if let error {
                    completion(.failure(error))
                } else {
                    completion(.success(description.sdp))
                }
            }
        }
    }

    func acceptOffer(_ sdp: String, completion: @escaping (Result<String, Error>) -> Void) {
        let remote = RTCSessionDescription(type: .offer, sdp: sdp)
        peerConnection.setRemoteDescription(remote) { [weak self] error in
            guard let self else { return }
            if let error {
                completion(.failure(error))
                return
            }
            self.peerConnection.answer(for: self.audioConstraints) { description, error in
                if let error {
                    completion(.failure(error))
                    return
                }
                guard let description else {
                    completion(.failure(ServiceError.descriptionCreationFailed))
                    return
                }
                self.peerConnection.setLocalDescription(description) { error in
                    if let error {
                        completion(.failure(error))
                    } else {
                        completion(.success(description.sdp))
                    }
                }
            }
        }
    }

    func acceptAnswer(_ sdp: String, completion: @escaping (Error?) -> Void) {
        peerConnection.setRemoteDescription(
            RTCSessionDescription(type: .answer, sdp: sdp),
            completionHandler: completion
        )
    }

    func addRemoteCandidate(
        sdp: String,
        sdpMid: String?,
        sdpMLineIndex: Int32,
        completion: @escaping (Error?) -> Void = { _ in }
    ) {
        let candidate = RTCIceCandidate(
            sdp: sdp,
            sdpMLineIndex: sdpMLineIndex,
            sdpMid: sdpMid
        )
        peerConnection.add(candidate, completionHandler: completion)
    }

    func setMuted(_ muted: Bool) {
        audioTrack.isEnabled = !muted
    }

    func close() {
        peerConnection.close()
    }

    private var audioConstraints: RTCMediaConstraints {
        RTCMediaConstraints(
            mandatoryConstraints: [kRTCMediaConstraintsOfferToReceiveAudio: kRTCMediaConstraintsValueTrue],
            optionalConstraints: nil
        )
    }

    private func configureAudioSession() {
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        defer { session.unlockForConfiguration() }
        do {
            try session.setCategory(AVAudioSession.Category.playAndRecord)
            try session.setMode(AVAudioSession.Mode.voiceChat)
            try session.setActive(true)
        } catch {
            NSLog("FreeVoice WebRTC audio session configuration failed: %@", error.localizedDescription)
        }
    }
}

extension WebRTCAudioService: RTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}

    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        onConnectionStateChanged?(newState)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        onLocalCandidate?(candidate)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}
