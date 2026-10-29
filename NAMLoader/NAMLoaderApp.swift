import SwiftUI

@main
struct NAMLoaderApp: App {
    @StateObject private var audio = AudioManager()
    var body: some Scene {
        WindowGroup { ContentView().environmentObject(audio) }
    }
}
