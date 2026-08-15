import SwiftUI

@main
struct RealTimeTranslatorApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 560, minHeight: 440)
                .preferredColorScheme(.dark)
                .tint(Color(red: 1.0, green: 0.23, blue: 0.58)) // 霓虹品红
        }
        .windowResizability(.contentMinSize)
    }
}
