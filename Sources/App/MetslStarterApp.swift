import SwiftUI

@main
struct MetslStarterApp: App {
    var body: some Scene {
        WindowGroup("Metsl Starter") {
            MetalView()
                .frame(
                    minWidth: SceneConfiguration.minimumCanvasSide + 2 * SceneConfiguration.canvasPadding,
                    minHeight: SceneConfiguration.minimumCanvasSide + 2 * SceneConfiguration.canvasPadding
                )
        }
        .defaultSize(
            width: SceneConfiguration.initialCanvasSide + 2 * SceneConfiguration.canvasPadding,
            height: SceneConfiguration.initialCanvasSide + 2 * SceneConfiguration.canvasPadding
        )
    }
}
