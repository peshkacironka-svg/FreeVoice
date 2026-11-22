import FirebaseFirestore
import FirebaseFunctions
import Foundation

/// Authenticated Firebase call signaling. Audio packets never pass through
/// Firestore; this service only exchanges call state, SDP, and ICE candidates.
final class CallSignalingService {
    private let database = Firestore.firestore()
    private let functions = Functions.functions()

    func createCall(
        calleeUID: String,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        functions.httpsCallable("createCall").call(["calleeUid": calleeUID]) { result, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let data = result?.data as? [String: Any],
                  let callId = data["callId"] as? String else {
                completion(.failure(SignalingError.invalidServerResponse))
                return
            }
            completion(.success(callId))
        }
    }

    func respondToCall(
        callId: String,
        accepted: Bool,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let response = accepted ? "accepted" : "rejected"
        functions.httpsCallable("respondToCall").call([
            "callId": callId,
            "response": response
        ]) { _, error in
            if let error {
                completion(.failure(error))
            } else {
                completion(.success(()))
            }
        }
    }

    func endCall(
        callId: String,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        functions.httpsCallable("endCall").call(["callId": callId]) { _, error in
            if let error {
                completion(.failure(error))
            } else {
                completion(.success(()))
            }
        }
    }

    func setDescription(
        callId: String,
        type: String,
        sdp: String,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        functions.httpsCallable("setCallDescription").call([
            "callId": callId,
            "type": type,
            "sdp": sdp
        ]) { _, error in
            if let error {
                completion(.failure(error))
            } else {
                completion(.success(()))
            }
        }
    }

    func addCandidate(
        callId: String,
        sdp: String,
        sdpMid: String?,
        sdpMLineIndex: Int32,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        functions.httpsCallable("addCallIceCandidate").call([
            "callId": callId,
            "sdp": sdp,
            "sdpMid": sdpMid as Any? ?? NSNull(),
            "sdpMLineIndex": Int(sdpMLineIndex)
        ]) { _, error in
            if let error {
                completion(.failure(error))
            } else {
                completion(.success(()))
            }
        }
    }

    func observeCall(
        callId: String,
        onChange: @escaping ([String: Any]?) -> Void
    ) -> ListenerRegistration {
        database.collection("calls").document(callId).addSnapshotListener { snapshot, error in
            guard error == nil, let snapshot, snapshot.exists else {
                onChange(nil)
                return
            }
            onChange(snapshot.data())
        }
    }

    func observeRemoteCandidates(
        callId: String,
        localUID: String,
        onCandidate: @escaping ([String: Any]) -> Void
    ) -> ListenerRegistration {
        database.collection("calls")
            .document(callId)
            .collection("iceCandidates")
            .whereField("fromUid", isNotEqualTo: localUID)
            .addSnapshotListener { snapshot, error in
                guard error == nil, let snapshot else { return }
                for change in snapshot.documentChanges where change.type == .added {
                    onCandidate(change.document.data())
                }
            }
    }
}

private enum SignalingError: LocalizedError {
    case invalidServerResponse

    var errorDescription: String? {
        "The call server returned an invalid response."
    }
}
