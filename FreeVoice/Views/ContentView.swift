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
        }
    }

    private var contactPicker: some View {
        VStack(spacing: 20) {
            Image(systemName: "phone.circle.fill")
                .font(.system(size: 72))
                .foregroundStyle(.green)

            Text("Call another iPhone")
                .font(.title2.weight(.semibold))

            TextField("Contact name", text: $contactName)
                .textFieldStyle(.roundedBorder)
                .textContentType(.name)
                .padding(.horizontal)

            Button {
                let name = contactName.trimmingCharacters(in: .whitespacesAndNewlines)
                callManager.startCall(to: name.isEmpty ? "New contact" : name)
            } label: {
                Label("Start call", systemImage: "phone.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .padding(.horizontal)

            Text("Calling is a UI scaffold only. Network signaling and live audio are not implemented yet.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .padding()
    }
}
