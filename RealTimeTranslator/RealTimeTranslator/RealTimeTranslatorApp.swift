import SwiftUI

@main
struct RealTimeTranslatorApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 560, minHeight: 440)
        }
        .windowResizability(.contentMinSize)
    }
}
