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
                .overlay(alignment: .bottom) {
                    VStack(spacing: 0) {
                        controlsHint
                        Rectangle()
                            .fill(.black.opacity(1))
                            .frame(height: 44) // example height
                    }
                    .overlay(
                        Rectangle()
                            .stroke(Color.red, lineWidth: 2)
                    )
                }
        }
        .defaultSize(
            width: SceneConfiguration.initialCanvasSide + 2 * SceneConfiguration.canvasPadding,
            height: SceneConfiguration.initialCanvasSide + 2 * SceneConfiguration.canvasPadding
        )
    }

    private var controlsHint: some View {
        VStack(spacing: 8) {
            HStack(spacing: 24) {
                Text("WASD").fontWeight(.semibold) + Text("  Move")
                Text("Q / E").fontWeight(.semibold) + Text("  Rotate")
            }
            .font(.system(size: 13))
            .foregroundStyle(.white.opacity(0.9))

            Text("Move without changing your view. Click the canvas to focus.")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.65))
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }
}

