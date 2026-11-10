import SwiftUI

struct ActiveCallView: View {
    @EnvironmentObject private var callManager: CallManager
    let call: CallSession

    var body: some View {
        VStack(spacing: 28) {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 96))
                .foregroundStyle(.green)

            VStack(spacing: 8) {
                Text(call.contactName)
                    .font(.title2.weight(.semibold))
                Text(call.status.rawValue.capitalized)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 36) {
                controlButton(
                    title: call.isMuted ? "Unmute" : "Mute",
                    symbol: call.isMuted ? "mic.slash.fill" : "mic.fill",
                    action: callManager.toggleMute
                )
                controlButton(
                    title: "Speaker",
                    symbol: call.isSpeakerEnabled ? "speaker.wave.2.fill" : "speaker.fill",
                    action: callManager.toggleSpeaker
                )
            }

            HStack(spacing: 16) {
                if call.status == .incoming {
                    Button("Accept", systemImage: "phone.fill") {
                        callManager.acceptCall()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                }

                Button("End call", systemImage: "phone.down.fill") {
                    callManager.endCall()
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
        }
        .padding()
    }

    private func controlButton(title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.title2)
                    .frame(width: 64, height: 64)
                    .background(.secondary.opacity(0.15), in: Circle())
                Text(title)
                    .font(.caption)
            }
            .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
    }
}
