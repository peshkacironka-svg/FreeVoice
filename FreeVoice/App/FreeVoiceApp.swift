import SwiftUI

@main
struct FreeVoiceApp: App {
    @StateObject private var callManager = CallManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(callManager)
        }
    }
}
