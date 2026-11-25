import FirebaseAuth
import FirebaseFirestore

@MainActor
final class UserProfileService {
    private let database = Firestore.firestore()

    func syncProfile(for user: User) async throws {
        let reference = database.collection("users").document(user.uid)
        let snapshot = try await reference.getDocument()
        let email = user.email ?? ""

        var profile: [String: Any] = [
            "uid": user.uid,
            "email": email,
            "updatedAt": FieldValue.serverTimestamp()
        ]

        if !snapshot.exists {
            profile["createdAt"] = FieldValue.serverTimestamp()
        }

        try await reference.setData(profile, merge: true)
    }
}
