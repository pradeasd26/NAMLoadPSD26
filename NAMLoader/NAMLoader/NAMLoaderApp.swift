import SwiftUI

@main
struct NAMLoaderApp: App {
    @StateObject private var audio = AudioManager()
    @StateObject private var midi = MIDIManager()
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(audio)
                .environmentObject(midi)
                .onAppear { midi.start(audio: audio) }
        }
    }
}
