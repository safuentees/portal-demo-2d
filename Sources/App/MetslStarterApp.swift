import SwiftUI

@main
struct MetslStarterApp: App {
    var body: some Scene {
        WindowGroup("Metsl Starter") {
            MetalView()
                .frame(minWidth: 400, minHeight: 400)
        }
        .defaultSize(width: 700, height: 700)
    }
}
