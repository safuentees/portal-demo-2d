import AppKit
import MetalKit

// Keyboard input belongs to the view; the renderer reads the held keys each frame.
final class KeyboardMetalView: MTKView {
    // Remember the physical key code so key-up still works if modifiers change.
    private var pressedKeys: [UInt16: String] = [:]

    override var acceptsFirstResponder: Bool { true }

    var movementDirection: SIMD3<Float> {
        guard window?.isKeyWindow == true,
              window?.firstResponder === self else { return .zero }

        let keys = Set(pressedKeys.values)
        var direction = SIMD3<Float>.zero
        if keys.contains("a") { direction.x -= 1 }
        if keys.contains("d") { direction.x += 1 }
        // This scene's camera looks along +Z.
        if keys.contains("w") { direction.z += 1 }
        if keys.contains("s") { direction.z -= 1 }
        return direction
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        pressedKeys.removeAll()
        NotificationCenter.default.removeObserver(
            self, name: NSWindow.didResignKeyNotification, object: nil
        )
        guard let window = window else { return }
        window.initialFirstResponder = self
        window.makeFirstResponder(self)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidResignKey(_:)),
            name: NSWindow.didResignKeyNotification,
            object: window
        )
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        // Leave shortcuts such as Command-W to AppKit.
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              let key = event.charactersIgnoringModifiers?.lowercased(),
              ["w", "a", "s", "d"].contains(key) else {
            super.keyDown(with: event)
            return
        }
        // Key repeat does not move the camera; it only keeps this key held.
        pressedKeys[event.keyCode] = key
    }

    override func keyUp(with event: NSEvent) {
        if pressedKeys.removeValue(forKey: event.keyCode) == nil {
            super.keyUp(with: event)
        }
    }

    override func resignFirstResponder() -> Bool {
        pressedKeys.removeAll()
        return super.resignFirstResponder()
    }

    @objc private func windowDidResignKey(_ notification: Notification) {
        // Avoid stuck movement if a key is released while another app is active.
        pressedKeys.removeAll()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
