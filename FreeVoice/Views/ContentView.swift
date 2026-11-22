import SwiftUI
import FirebaseAuth

struct ContentView: View {
    @EnvironmentObject private var callManager: CallManager
    private let profileService = UserProfileService()
    @State private var currentUser: User?
    @State private var isInternetCallActive = false
    @State private var authListener: AuthStateDidChangeListenerHandle?
    @State private var email = ""
    @State private var password = ""
    @State private var isCreatingAccount = false
    @State private var isWorking = false
    @State private var authError: String?
    @State private var contactName = ""

    var body: some View {
        NavigationStack {
            Group {
                if let currentUser {
                    authenticatedContent(user: currentUser)
                } else {
                    authenticationForm
                }
            }
            .navigationTitle("FreeVoice")
            .alert("FreeVoice", isPresented: errorIsPresented) {
                Button("OK", role: .cancel) {
                    callManager.dismissError()
                    authError = nil
                }
            } message: {
                Text(authError ?? callManager.errorMessage ?? "An unexpected error occurred.")
            }
        }
        .onAppear {
            if authListener == nil {
                authListener = Auth.auth().addStateDidChangeListener { _, user in
                    Task { @MainActor in
                        currentUser = user
                        guard let user else { return }
                        do {
                            try await profileService.syncProfile(for: user)
                        } catch {
                            authError = "Could not sync your account profile: \(error.localizedDescription)"
                        }
                    }
                }
            }
        }
        .onDisappear {
            if let authListener {
                Auth.auth().removeStateDidChangeListener(authListener)
                self.authListener = nil
            }
        }
    }

    private var errorIsPresented: Binding<Bool> {
        Binding(
            get: { authError != nil || callManager.errorMessage != nil },
            set: {
                if !$0 {
                    authError = nil
                    callManager.dismissError()
                }
            }
        )
    }

    private var authenticationForm: some View {
        VStack(spacing: 18) {
            Image(systemName: "phone.bubble.left.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)

            Text(isCreatingAccount ? "Create your FreeVoice account" : "Sign in to FreeVoice")
                .font(.title2.weight(.semibold))

            Text("Use your email address and password to securely access your account.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            TextField("Email", text: $email)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)

            SecureField("Password (at least 6 characters)", text: $password)
                .textContentType(isCreatingAccount ? .newPassword : .password)
                .textFieldStyle(.roundedBorder)

            Button {
                authenticate()
            } label: {
                HStack {
                    if isWorking {
                        ProgressView().tint(.white)
                    }
                    Text(isCreatingAccount ? "Create account" : "Sign in")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .disabled(isWorking || email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty)

            Button(isCreatingAccount ? "Already have an account? Sign in" : "New to FreeVoice? Create account") {
                isCreatingAccount.toggle()
                authError = nil
            }
            .font(.footnote)
            .disabled(isWorking)
        }
        .padding(24)
    }

    private func authenticatedContent(user: User) -> some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Signed in")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(user.email ?? "FreeVoice user")
                        .font(.subheadline.weight(.medium))
                }
                Spacer()
                Button("Sign out", systemImage: "rectangle.portrait.and.arrow.right") {
                    do {
                        try Auth.auth().signOut()
                    } catch {
                        authError = error.localizedDescription
                    }
                }
                .font(.footnote)
            }
            .padding(.horizontal)

            InternetCallView(userUID: user.uid, isActive: $isInternetCallActive)

            Divider()
                .padding(.horizontal)

            if let call = callManager.activeCall {
                ActiveCallView(call: call)
            } else {
                contactPicker
            }
        }
        .padding(.top)
    }

    private var contactPicker: some View {
        VStack(spacing: 20) {
            Image(systemName: "phone.circle.fill")
                .font(.system(size: 72))
                .foregroundStyle(.green)

            Text("Call another nearby iPhone")
                .font(.title2.weight(.semibold))

            TextField("Your name (optional)", text: $contactName)
                .textFieldStyle(.roundedBorder)
                .textContentType(.name)
                .padding(.horizontal)

            if callManager.nearbyPeers.isEmpty {
                ProgressView("Looking for nearby iPhones…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Nearby iPhones")
                        .font(.headline)

                    ForEach(callManager.nearbyPeers, id: \.displayName) { peer in
                        Button {
                            callManager.startCall(with: peer)
                        } label: {
                            Label(peer.displayName, systemImage: "phone.fill")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                        .disabled(isInternetCallActive)
                    }
                }
                .padding(.horizontal)
            }

            Text("Your account is connected. Voice calls currently work between nearby iPhones; Internet calling is the next development step.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .padding()
    }

    private func authenticate() {
        isWorking = true
        authError = nil
        let cleanEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)

        let completion: (AuthDataResult?, Error?) -> Void = { _, error in
            isWorking = false
            if let error {
                authError = error.localizedDescription
            }
        }

        if isCreatingAccount {
            Auth.auth().createUser(withEmail: cleanEmail, password: password, completion: completion)
        } else {
            Auth.auth().signIn(withEmail: cleanEmail, password: password, completion: completion)
        }
    }
}
