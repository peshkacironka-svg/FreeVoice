import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var callManager: CallManager
    @State private var contactName = ""

    var body: some View {
        NavigationStack {
            Group {
                if let call = callManager.activeCall {
                    ActiveCallView(call: call)
                } else {
                    contactPicker
                }
            }
            .navigationTitle("FreeVoice")
            .alert("FreeVoice", isPresented: errorIsPresented) {
                Button("OK", role: .cancel) {
                    callManager.dismissError()
                }
            } message: {
                Text(callManager.errorMessage ?? "An unexpected error occurred.")
            }
        }
    }

    private var errorIsPresented: Binding<Bool> {
        Binding(
            get: { callManager.errorMessage != nil },
            set: { if !$0 { callManager.dismissError() } }
        )
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
                    }
                }
                .padding(.horizontal)
            }

            Text("FreeVoice calls work between nearby iPhones. Both people need this app open and local-network access enabled.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .padding()
    }
}
