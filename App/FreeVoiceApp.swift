import SwiftUI

@main
struct FreeVoiceApp: App {
    @StateObject private var callManager = VoiceCallManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(callManager)
        }
    }
}
