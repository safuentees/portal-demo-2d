import AppKit
import MetalKit

// Native input belongs to the view; the renderer reads its state each frame.
final class KeyboardMetalView: MTKView {
    // Remember the physical key code so key-up still works if modifiers change.
    private var pressedKeys: [UInt16: String] = [:]
    private var mouseTrackingArea: NSTrackingArea?

    /// Cursor location in this view's coordinates (macOS points), or nil when unavailable.
    private(set) var mousePosition: CGPoint? {
        didSet {
            if mousePosition == nil { aimCanvasPosition = nil }
        }
    }

    /// Changes only when the user moves/drags the pointer or explicitly clicks to aim.
    private(set) var aimRevision: UInt64 = 0
    /// The latest intentional target, invalidated when focus, tracking, or coordinates change.
    private(set) var aimCanvasPosition: SIMD2<Float>?

    /// Cursor relative to the centered square canvas: (0, 0) at center, +y upward.
    var mouseCanvasPosition: SIMD2<Float>? {
        guard let mousePosition else { return nil }
        let point = SIMD2<Float>(
            Float(mousePosition.x - bounds.minX),
            Float(isFlipped ? bounds.maxY - mousePosition.y : mousePosition.y - bounds.minY)
        )
        return Transforms.canvasPosition(
            from: point,
            size: SIMD2(Float(bounds.width), Float(bounds.height)),
            padding: Float(SceneConfiguration.canvasPadding)
        )
    }

    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .crosshair)
    }

    /// Held WASD keys in the scene's XY plane: W is up, D is right.
    var movementDirection: SIMD2<Float> {
        guard window?.isKeyWindow == true,
              window?.firstResponder === self else { return .zero }

        let keys = Set(pressedKeys.values)
        var direction = SIMD2<Float>.zero
        if keys.contains("a") { direction.x -= 1 }
        if keys.contains("d") { direction.x += 1 }
        if keys.contains("w") { direction.y += 1 }
        if keys.contains("s") { direction.y -= 1 }
        return direction
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        pressedKeys.removeAll()
        mousePosition = nil
        NotificationCenter.default.removeObserver(
            self, name: NSWindow.didResignKeyNotification, object: nil
        )
        NotificationCenter.default.removeObserver(
            self, name: NSWindow.didBecomeKeyNotification, object: nil
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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeKey(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: window
        )
        refreshMousePosition()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let mouseTrackingArea {
            removeTrackingArea(mouseTrackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow,
                      .inVisibleRect, .enabledDuringMouseDrag],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        mouseTrackingArea = area
        // Resizing can move the canvas under a stationary cursor.
        refreshMousePosition()
    }

    override func mouseEntered(with event: NSEvent) {
        aimCanvasPosition = nil
        updateMousePosition(inWindow: event.locationInWindow)
    }

    override func mouseMoved(with event: NSEvent) {
        recordAimInput(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        mousePosition = nil
    }

    override func mouseDragged(with event: NSEvent) {
        recordAimInput(with: event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        recordAimInput(with: event)
    }

    override func otherMouseDragged(with event: NSEvent) {
        recordAimInput(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        recordAimInput(with: event, force: true)
    }

    override func keyDown(with event: NSEvent) {
        // Leave shortcuts such as Command-W to AppKit.
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              let key = event.charactersIgnoringModifiers?.lowercased(),
              ["w", "a", "s", "d"].contains(key) else {
            super.keyDown(with: event)
            return
        }
        // Key repeat only keeps this key held; movement happens once per frame.
        pressedKeys[event.keyCode] = key
    }

    override func keyUp(with event: NSEvent) {
        if pressedKeys.removeValue(forKey: event.keyCode) == nil {
            super.keyUp(with: event)
        }
    }

    override func resignFirstResponder() -> Bool {
        pressedKeys.removeAll()
        aimCanvasPosition = nil
        return super.resignFirstResponder()
    }

    @objc private func windowDidResignKey(_ notification: Notification) {
        // Avoid stuck movement if a key is released while another app is active.
        pressedKeys.removeAll()
        mousePosition = nil
    }

    @objc private func windowDidBecomeKey(_ notification: Notification) {
        refreshMousePosition()
    }

    private func refreshMousePosition() {
        aimCanvasPosition = nil
        guard let window, window.isKeyWindow else {
            mousePosition = nil
            return
        }
        updateMousePosition(inWindow: window.mouseLocationOutsideOfEventStream)
    }

    private func recordAimInput(with event: NSEvent, force: Bool = false) {
        let previousPosition = mousePosition
        updateMousePosition(inWindow: event.locationInWindow)
        if mousePosition != nil && (force || mousePosition != previousPosition) {
            aimCanvasPosition = mouseCanvasPosition
            aimRevision &+= 1
        }
    }

    private func updateMousePosition(inWindow location: CGPoint) {
        guard window != nil else {
            mousePosition = nil
            return
        }
        let point = convert(location, from: nil)
        mousePosition = bounds.contains(point) && visibleRect.contains(point) ? point : nil
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
