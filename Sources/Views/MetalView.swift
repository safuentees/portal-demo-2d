import MetalKit
import SwiftUI

/// The SwiftUI-to-Metal boundary. Scene and rendering code live separately.
struct MetalView: NSViewRepresentable {
    final class Coordinator {
        // MTKView.delegate is weak; retain the renderer for the view's lifetime.
        var renderer: Renderer?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> KeyboardMetalView {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metsl Starter requires a Mac that supports Metal.")
        }

        let view = KeyboardMetalView(frame: .zero, device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float
        let samples = SceneConfiguration.antialiasingSampleCount
        view.sampleCount = device.supportsTextureSampleCount(samples) ? samples : 1
        view.clearColor = SceneConfiguration.backgroundColor
        view.clearDepth = 1
        view.preferredFramesPerSecond = 60
        // A continuous draw loop lets held WASD keys move smoothly.
        view.isPaused = false
        view.enableSetNeedsDisplay = false

        do {
            context.coordinator.renderer = try Renderer(view: view)
        } catch {
            fatalError("Could not initialize Metal: \(error.localizedDescription)")
        }
        view.delegate = context.coordinator.renderer
        return view
    }

    func updateNSView(_ nsView: KeyboardMetalView, context: Context) {}

    static func dismantleNSView(_ nsView: KeyboardMetalView, coordinator: Coordinator) {
        nsView.isPaused = true
        nsView.delegate = nil
        coordinator.renderer = nil
    }
}

#Preview("Square canvas") {
    MetalView()
        .frame(width: 500, height: 500)
}
