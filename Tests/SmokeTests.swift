import AppKit
import MetalKit
import simd

/// Runs the actual renderer against GPU textures without opening an app window.
@main
struct SmokeTests {
    // Keep fixtures independent of the editable scene layout. These unit squares
    // become separated rectangles after applying each position and scale.
    static let placements: [ObjectPlacement] = [
        ObjectPlacement(position: [-0.6, 0.55, 0], scale: [0.45, 0.3, 1]),
        ObjectPlacement(position: [0.5, 0.45, 0.2], scale: [0.55, 0.65, 1]),
        ObjectPlacement(position: [-0.4, -0.45, 0.4], scale: [0.75, 0.4, 1]),
        ObjectPlacement(position: [0.65, -0.65, 0.6], scale: [0.2, 0.2, 1]),
    ]

    static func sceneObjects(
        squares: [ObjectPlacement] = [], circles: [ObjectPlacement] = []
    ) -> [SceneObjectConfiguration] {
        squares.enumerated().map { index, placement in
            SceneObjectConfiguration(
                id: .custom("square-\(index)"), geometry: .square,
                placement: placement, color: SceneConfiguration.objectColor
            )
        } + circles.enumerated().map { index, placement in
            SceneObjectConfiguration(
                id: .custom("circle-\(index)"), geometry: .circle,
                placement: placement, color: SceneConfiguration.objectColor
            )
        }
    }

    static let namedScene: [SceneObjectConfiguration] = [
        SceneObjectConfiguration(
            id: .custom("other-circle"), geometry: .circle,
            placement: ObjectPlacement(position: [0.7, 0.65, 0.2], scale: [0.08, 0.08, 1])
        ),
        SceneObjectConfiguration(
            id: .topBar, geometry: .square,
            placement: ObjectPlacement(position: [-0.65, 0.7, 0], scale: [0.25, 0.1, 1])
        ),
        SceneObjectConfiguration(
            id: .circle, geometry: .circle,
            placement: ObjectPlacement(position: [-0.5, 0.5, 0.4], scale: [0.16, 0.12, 1])
        ),
        SceneObjectConfiguration(
            id: .cone, geometry: .triangle,
            placement: ObjectPlacement(position: [0.25, -0.25, 0.3], scale: [0.3, 0.4, 1], angle: 0.37)
        ),
        SceneObjectConfiguration(
            id: .bottomBar, geometry: .square,
            placement: ObjectPlacement(position: [-0.65, -0.7, 0], scale: [0.2, 0.1, 1])
        ),
    ].map { configuration in
        var configuration = configuration
        configuration.color = SceneConfiguration.objectColor
        return configuration
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(description: message) }
    }

    @MainActor
    static func main() throws {
        try checkMath()
        guard CommandLine.arguments.count == 2 else {
            throw Failure(description: "Pass the built default.metallib path.")
        }
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            throw Failure(description: "A Metal GPU is required for the render checks.")
        }
        let library = try device.makeLibrary(URL: URL(fileURLWithPath: CommandLine.arguments[1]))
        try checkMouseInput(device: device, library: library, queue: queue)
        let view = MTKView(frame: .zero, device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float
        try checkObjectPlacement(device: device)
        try checkMeshes(device: device)
        try checkNamedObjects(view: view, library: library)
        let renderer = try Renderer(
            view: view, library: library, sceneObjects: sceneObjects(squares: placements)
        )

        let viewports: [(Int, Int, CGSize?)] = [
            (512, 512, nil), (800, 400, nil), (400, 800, nil),
            (1024, 800, CGSize(width: 512, height: 400)),
            (800, 1024, CGSize(width: 400, height: 512)),
        ]
        for (width, height, viewportSize) in viewports {
            let first = try render(
                renderer, device: device, queue: queue,
                width: width, height: height, viewportSize: viewportSize
            )
            try checkPixels(
                first, width: width, height: height,
                placements: placements, viewportSize: viewportSize
            )
            let second = try render(
                renderer, device: device, queue: queue,
                width: width, height: height, viewportSize: viewportSize
            )
            try expect(first == second, "The resting scene changed between frames.")
            let backingScale = viewportSize == nil ? "1x" : "2x Retina"
            print("PASS: \(width)x\(height) \(backingScale) — centered square canvas, padding, independent sizes, stable frame")
        }
        let emptyRenderer = try Renderer(
            view: view, library: library, sceneObjects: []
        )
        let empty = try render(emptyRenderer, device: device, queue: queue, width: 512, height: 512)
        try checkPixels(empty, width: 512, height: 512, placements: [])
        let tiny = try render(renderer, device: device, queue: queue, width: 128, height: 128)
        try checkPixels(tiny, width: 128, height: 128, placements: [])
        try checkMixedScene(view: view, library: library, device: device, queue: queue)
        print("PASS: empty scene, excessive padding, transform order, placement edits, camera movement, uniform layout")
    }

    static func checkMath() throws {
        let projection = Transforms.perspective(aspect: 1, fieldOfView: .pi / 2, near: 0.1, far: 100)
        for (z, expectedDepth): (Float, Float) in [(0.1, 0), (100, 1)] {
            let clip = SIMD4<Float>(0, 0, z, 1) * projection
            try expect(abs(clip.z / clip.w - expectedDepth) < 0.0001,
                       "Projection must map near/far to Metal depth 0/1.")
        }
        let translated = SIMD4<Float>(0, 0, 0, 1) * Transforms.translation([1, 2, 3])
        try expect(translated == SIMD4<Float>(1, 2, 3, 1), "Row-vector translation is incorrect.")
        let point = SIMD4<Float>(1, -2, 3, 1)
        try expect(point * ObjectPlacement().modelMatrix == point,
                   "A default placement must preserve the original mesh.")
        let placement = ObjectPlacement(position: [4, -3, 2], scale: [2, 3, 4])
        try expect(point * placement.modelMatrix == SIMD4<Float>(6, -9, 14, 1),
                   "Placement must scale each axis before translating; scale must not move the origin.")
        let quarterTurn = Transforms.rotation(.pi / 2)
        let rotated = SIMD4<Float>(1, 0, 2, 1) * quarterTurn
        try expect(simd_distance(rotated, SIMD4<Float>(0, 1, 2, 1)) < 0.0001,
                   "Positive rotation must turn +X toward +Y counterclockwise, preserving depth and W.")
        let rightward = SIMD4<Float>(0, 1, 0, 1) * Transforms.rotation(-.pi / 2)
        try expect(simd_distance(rightward, SIMD4<Float>(1, 0, 0, 1)) < 0.0001,
                   "A negative quarter-turn must aim the triangle's +Y tip toward +X.")
        let rotatedPlacement = ObjectPlacement(position: [4, -3, 2], scale: [2, 3, 4], angle: .pi / 2)
        try expect(simd_distance(SIMD4<Float>(1, 2, 3, 1) * rotatedPlacement.modelMatrix,
                                SIMD4<Float>(-2, -1, 14, 1)) < 0.0001,
                   "Placement must scale, then rotate, then translate in row-vector order.")
        try expect(simd_distance(SIMD4<Float>(0, 0, 0, 1) * rotatedPlacement.modelMatrix,
                                SIMD4<Float>(4, -3, 2, 1)) < 0.0001,
                   "Rotation must keep the object's origin fixed at its configured position.")
        let homogeneous = SIMD4<Float>(3, -2, 5, 7) * Transforms.rotation(0.71)
        try expect(homogeneous.z == 5 && homogeneous.w == 7,
                   "Planar rotation must preserve depth and homogeneous W.")
        try checkCanvasMath()
        try checkCanvasPosition()

        var straight = Camera()
        var diagonal = Camera()
        straight.update(direction: [0, 0, 1], deltaTime: 0.05)
        diagonal.update(direction: [1, 0, 1], deltaTime: 0.05)
        try expect(abs(simd_length(straight.position) - simd_length(diagonal.position)) < 0.0001,
                   "Diagonal movement must not be faster.")
        let eye = SIMD4<Float>(straight.position.x, straight.position.y, straight.position.z, 1)
        try expect(simd_length((eye * straight.viewMatrix) - SIMD4<Float>(0, 0, 0, 1)) < 0.0001,
                   "The view transform must invert the camera position.")
        var paused = Camera()
        paused.update(direction: [0, 0, 1], deltaTime: 100)
        try expect(abs(paused.position.z - SceneConfiguration.cameraSpeed * 0.1) < 0.0001,
                   "A debugger pause must not cause a camera jump.")
        try expect(MemoryLayout<ShaderUniforms>.stride == 208, "Swift/Metal uniform stride changed.")
        try expect(MemoryLayout<ShaderUniforms>.offset(of: \.canvasMatrix) == 128,
                   "Swift/Metal uniform canvas matrix offset changed.")
        try expect(MemoryLayout<ShaderUniforms>.offset(of: \.color) == 192,
                   "Swift/Metal uniform color offset changed.")
    }

    static func checkCanvasMath() throws {
        for size: SIMD2<Float> in [[900, 900], [1200, 900], [900, 1200]] {
            let canvas = Transforms.squareCanvas(size: size, padding: 100)
            let corner = SIMD4<Float>(1, 1, 0.4, 1) * canvas
            let halfWidth = corner.x * size.x / 2
            let halfHeight = corner.y * size.y / 2
            try expect(abs(halfWidth - 350) < 0.0001 && abs(halfHeight - 350) < 0.0001,
                       "A 900-point short side must contain a centered 700-point square with 100-point padding.")
            for depth: Float in [0, 0.2, 0.9] {
                let shifted = SIMD4<Float>(1, 1, depth, 1) * canvas
                try expect(shifted.x == corner.x && shifted.y == corner.y
                           && shifted.z == depth && shifted.w == 1,
                           "Canvas layout must preserve depth and never apply perspective scaling.")
            }
        }
        let collapsed = Transforms.squareCanvas(size: [128, 128], padding: 100)
        try expect(SIMD4<Float>(1, -1, 0.5, 1) * collapsed == SIMD4<Float>(0, 0, 0.5, 1),
                   "Excessive padding must collapse the canvas without inverting it.")
        for size: SIMD2<Float> in [[0, 400], [400, 0], [0, 0]] {
            let zero = Transforms.squareCanvas(size: size, padding: 100)
            try expect(SIMD4<Float>(1, -1, 0.5, 1) * zero == SIMD4<Float>(0, 0, 0.5, 1),
                       "Zero-size viewports must produce finite, collapsed canvas coordinates.")
        }
        let unpadded = Transforms.squareCanvas(size: [400, 400], padding: -100)
        try expect(SIMD4<Float>(1, -1, 0.5, 1) * unpadded == SIMD4<Float>(1, -1, 0.5, 1),
                   "Negative padding must behave like zero padding.")
    }

    static func checkObjectPlacement(device: MTLDevice) throws {
        let mesh = try SquareMesh.make(device: device)
        var object = RenderObject(
            id: .custom("placement"), mesh: mesh, placement: ObjectPlacement(position: [4, -3, 2])
        )
        object.placement.position = [7, 8, 9]
        object.placement.scale = [1, 0.5, 2]
        let point = SIMD4<Float>(1, -2, 3, 1)
        try expect(point * object.modelMatrix == SIMD4<Float>(8, 7, 15, 1),
                   "Editing an object's position or scale must update its model matrix.")
    }

    static func checkCanvasPosition() throws {
        let cases: [(SIMD2<Float>, SIMD2<Float>, SIMD2<Float>)] = [
            ([900, 900], [450, 450], [0, 0]),
            ([900, 900], [100, 100], [-1, -1]),
            ([900, 900], [800, 800], [1, 1]),
            ([900, 900], [800, 100], [1, -1]),
            ([900, 900], [50, 450], [-8.0 / 7.0, 0]),
            ([1200, 900], [250, 100], [-1, -1]),
            ([1200, 900], [950, 800], [1, 1]),
            ([900, 1200], [100, 250], [-1, -1]),
            ([900, 1200], [800, 950], [1, 1]),
        ]
        for (size, point, expected) in cases {
            guard let actual = Transforms.canvasPosition(from: point, size: size, padding: 100) else {
                throw Failure(description: "A valid view point must map into canvas coordinates.")
            }
            try expect(simd_distance(actual, expected) < 0.0001,
                       "Mouse coordinates must account for centered padding and positive Y up, without clamping.")
        }
        for size: SIMD2<Float> in [[900, 900], [1200, 900], [900, 1200]] {
            for point: SIMD2<Float> in [[-1, -1], [0.37, -0.62], [1.2, -1.3]] {
                let clip = SIMD4<Float>(point.x, point.y, 0, 1)
                    * Transforms.squareCanvas(size: size, padding: 100)
                let viewPoint = (SIMD2(clip.x, clip.y) + 1) * size / 2
                guard let restored = Transforms.canvasPosition(from: viewPoint, size: size, padding: 100) else {
                    throw Failure(description: "Canvas projection must have a valid mouse-coordinate inverse.")
                }
                try expect(simd_distance(restored, point) < 0.0001,
                           "Rendered positions and mouse positions must round-trip across viewport shapes.")
            }
        }
        let logical = Transforms.canvasPosition(from: [550, 250], size: [900, 600], padding: 100)
        let backing = Transforms.canvasPosition(from: [1100, 500], size: [1800, 1200], padding: 200)
        try expect(logical == SIMD2<Float>(0.5, -0.25) && backing == logical,
                   "Equivalent point and Retina pixel geometry must produce the same canvas position.")
        for size: SIMD2<Float> in [[0, 400], [400, 0], [-1, 400], [128, 128], [200, 500]] {
            try expect(Transforms.canvasPosition(from: .zero, size: size, padding: 100) == nil,
                       "Invalid or collapsed canvases must not produce mouse coordinates.")
        }
        try expect(Transforms.canvasPosition(from: [0, 400], size: [400, 400], padding: -100)
                   == SIMD2<Float>(-1, 1), "Negative input padding must behave like zero padding.")
    }

    @MainActor
    static func checkMouseInput(device: MTLDevice, library: MTLLibrary, queue: MTLCommandQueue) throws {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 900),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = KeyboardMetalView(frame: NSRect(x: 40, y: 30, width: 900, height: 600), device: device)
        view.isPaused = true
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float
        window.contentView?.addSubview(view)
        view.setBoundsOrigin(CGPoint(x: 15, y: 25))
        view.autoResizeDrawable = false
        view.drawableSize = CGSize(width: 1800, height: 1200)

        view.updateTrackingAreas()
        view.updateTrackingAreas()
        let areas = view.trackingAreas.filter { ($0.owner as? KeyboardMetalView) === view }
        try expect(areas.count == 1, "Updating mouse tracking must replace the previous tracking area.")
        let required: NSTrackingArea.Options = [
            .mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow,
            .inVisibleRect, .enabledDuringMouseDrag
        ]
        try expect(areas[0].options.isSuperset(of: required),
                   "Mouse tracking must register movement, entry/exit, and dragging for the visible key-window view.")

        func event(_ type: NSEvent.EventType, at point: CGPoint) throws -> NSEvent {
            let location = view.convert(point, to: nil)
            let result: NSEvent?
            if type == .mouseEntered || type == .mouseExited {
                result = NSEvent.enterExitEvent(
                    with: type, location: location, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil,
                    eventNumber: 0, trackingNumber: 0, userData: nil
                )
            } else {
                result = NSEvent.mouseEvent(
                    with: type, location: location, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: 0
                )
            }
            guard let result = result else { throw Failure(description: "Could not construct a mouse event.") }
            return result
        }

        let point = CGPoint(x: view.bounds.midX + 100, y: view.bounds.midY - 50)
        let moved = try event(.mouseMoved, at: point)
        view.mouseMoved(with: moved)
        try expect(view.mousePosition == point, "Mouse events must convert window locations into native view points.")
        try expect(view.mouseCanvasPosition == SIMD2<Float>(0.5, -0.25),
                   "Mouse mapping must account for bounds origin and use logical points, not Retina drawable pixels.")
        let renderer = try Renderer(view: view, library: library, sceneObjects: namedScene)
        renderer.updateScene()
        try expect(renderer.object(withID: .cone)?.placement.angle == 0.37,
                   "A scene without mouse input must retain its configured cone angle.")
        view.drawableSize = .zero
        renderer.draw(in: view)
        view.drawableSize = CGSize(width: 1800, height: 1200)
        try expect(renderer.mousePosition == SIMD2<Float>(0.5, -0.25)
                   && abs((renderer.object(withID: .cone)?.placement.angle ?? 0) + .pi / 2) < 0.0001,
                   "The draw loop must read input and update the scene before checking drawable availability.")
        renderer.updateInput(from: view, deltaTime: 0)
        try expect(renderer.mousePosition == view.mouseCanvasPosition,
                   "The renderer must consume the input view's canvas position at rest.")
        for _ in 0..<3 { renderer.updateScene() }
        try expect(abs((renderer.object(withID: .cone)?.placement.angle ?? 0) + .pi / 2) < 0.0001,
                   "The cone must aim from its translated origin without accumulating rotation each frame.")
        for configuration in namedScene {
            try expect(renderer.object(withID: configuration.id)?.placement.position == configuration.placement.position
                       && renderer.object(withID: configuration.id)?.placement.scale == configuration.placement.scale
                       && renderer.object(withID: configuration.id)?.color == configuration.color,
                       "Aiming must preserve every object's position, depth, scale, and color.")
            if configuration.id != .cone {
                try expect(renderer.object(withID: configuration.id)?.placement.angle == configuration.placement.angle,
                           "Aiming the cone must not rotate circles or bars.")
            }
        }
        var expectedSquares: [ObjectPlacement] = []
        var expectedCircles: [ObjectPlacement] = []
        var expectedTriangles: [ObjectPlacement] = []
        for configuration in namedScene {
            var placement = configuration.placement
            if configuration.id == .cone { placement.angle = -.pi / 2 }
            switch configuration.geometry {
            case .square: expectedSquares.append(placement)
            case .circle: expectedCircles.append(placement)
            case .triangle: expectedTriangles.append(placement)
            }
        }
        let rotatedPixels = try render(renderer, device: device, queue: queue, width: 900, height: 600)
        try checkPixels(
            rotatedPixels, width: 900, height: 600,
            placements: expectedSquares, circlePlacements: expectedCircles, trianglePlacements: expectedTriangles
        )

        let center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        for type in [NSEvent.EventType.leftMouseDragged, .rightMouseDragged, .otherMouseDragged] {
            view.mouseMoved(with: moved)
            let drag = try event(type, at: center)
            switch type {
            case .leftMouseDragged: view.mouseDragged(with: drag)
            case .rightMouseDragged: view.rightMouseDragged(with: drag)
            default: view.otherMouseDragged(with: drag)
            }
            try expect(view.mousePosition == center && view.mouseCanvasPosition == SIMD2<Float>.zero,
                       "Every mouse drag callback must update the stored position.")
            renderer.updateInput(from: view, deltaTime: 0)
            renderer.updateScene()
            try expect(abs((renderer.object(withID: .cone)?.placement.angle ?? 0) - .pi / 4) < 0.0001,
                       "Dragging toward the canvas center must aim from the cone's translated origin.")
        }
        expectedTriangles[0].angle = .pi / 4
        let diagonalPixels = try render(renderer, device: device, queue: queue, width: 900, height: 600)
        try checkPixels(
            diagonalPixels, width: 900, height: 600,
            placements: expectedSquares, circlePlacements: expectedCircles, trianglePlacements: expectedTriangles
        )
        let pivot = CGPoint(x: view.bounds.midX + 50, y: view.bounds.midY - 50)
        view.mouseMoved(with: try event(.mouseMoved, at: pivot))
        renderer.updateInput(from: view, deltaTime: 0)
        renderer.updateScene()
        try expect(abs((renderer.object(withID: .cone)?.placement.angle ?? 0) - .pi / 4) < 0.0001,
                   "A pointer exactly at the cone origin must preserve the previous angle.")
        view.mouseDown(with: try event(.leftMouseDown, at: point))
        try expect(view.mousePosition == point, "A mouse click must update position before the next move.")
        let padding = CGPoint(x: view.bounds.minX + 50, y: view.bounds.midY)
        view.mouseMoved(with: try event(.mouseMoved, at: padding))
        try expect(view.mouseCanvasPosition == SIMD2<Float>(-2, 0),
                   "Mouse positions in window padding must remain available outside -1...1.")
        renderer.updateInput(from: view, deltaTime: 0)
        renderer.updateScene()
        let lastAngle = renderer.object(withID: .cone)?.placement.angle
        let paddingAngle = atan2(Float(0.25), Float(-2.25)) - .pi / 2
        try expect(abs((lastAngle ?? 0) - paddingAngle) < 0.0001, "Cone aiming must not clamp input in padding.")
        view.mouseExited(with: try event(.mouseExited, at: padding))
        renderer.updateInput(from: view, deltaTime: 0)
        renderer.updateScene()
        try expect(view.mousePosition == nil && view.mouseCanvasPosition == nil && renderer.mousePosition == nil,
                   "Leaving the view must clear input and renderer mouse positions.")
        try expect(renderer.object(withID: .cone)?.placement.angle == lastAngle,
                   "When mouse input becomes unavailable, the cone must hold its last angle.")
        view.mouseEntered(with: try event(.mouseEntered, at: point))
        try expect(view.mousePosition == point, "Reentering the view must restore the current mouse location.")
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        try expect(view.mousePosition == nil, "Window resignation must clear stale mouse input.")
        view.mouseMoved(with: moved)
        let outside = CGPoint(x: view.bounds.maxX + 1, y: view.bounds.midY)
        view.mouseDragged(with: try event(.leftMouseDragged, at: outside))
        try expect(view.mousePosition == nil, "Dragging outside the view must clear mouse input.")
        view.setFrameSize(CGSize(width: 128, height: 128))
        view.mouseMoved(with: try event(.mouseMoved, at: CGPoint(x: view.bounds.midX, y: view.bounds.midY)))
        try expect(view.mouseCanvasPosition == nil, "Collapsed canvases must not expose mouse canvas coordinates.")
        view.removeFromSuperview()
        try expect(view.mousePosition == nil && view.mouseCanvasPosition == nil,
                   "Detaching the view must clear mouse input.")
        view.mouseMoved(with: moved)
        try expect(view.mousePosition == nil, "Detached views must ignore mouse callbacks.")
        print("PASS: native mouse input, cone aiming, fixed origin and scene properties, GPU rotation, input cleanup")
    }

    @MainActor
    static func checkNamedObjects(view: MTKView, library: MTLLibrary) throws {
        for configurations in [namedScene, Array(namedScene.reversed())] {
            let renderer = try Renderer(view: view, library: library, sceneObjects: configurations)
            try expect(renderer.object(withID: .circle)?.id == .circle,
                       "Named lookup must remain stable when the scene array is reordered.")
            let changed = renderer.updateObject(.topBar) { object in
                object.placement.position = [0.3, 0.4, 0.2]
                object.placement.scale = [0.6, 0.2, 1]
                object.placement.angle = .pi / 3
                object.color = [1, 0.5, 0.25, 1]
            }
            try expect(changed
                       && renderer.object(withID: .topBar)?.placement.position == SIMD3<Float>(0.3, 0.4, 0.2)
                       && renderer.object(withID: .topBar)?.placement.scale == SIMD3<Float>(0.6, 0.2, 1)
                       && renderer.object(withID: .topBar)?.placement.angle == Float.pi / 3
                       && renderer.object(withID: .topBar)?.color == SIMD4<Float>(1, 0.5, 0.25, 1),
                       "Targeted mutation must update the named object's position, scale, angle, and color.")
            for configuration in configurations where configuration.id != .topBar {
                try expect(renderer.object(withID: configuration.id)?.placement.position == configuration.placement.position
                           && renderer.object(withID: configuration.id)?.placement.angle == configuration.placement.angle
                           && renderer.object(withID: configuration.id)?.color == configuration.color,
                           "Targeted mutation must leave every other named object unchanged.")
            }
            let copied = renderer.updateObject(.topBar) { object in
                if let bottomBar = renderer.object(withID: .bottomBar) {
                    object.placement.position.x = bottomBar.placement.position.x
                }
            }
            try expect(copied
                       && renderer.object(withID: .topBar)?.placement.position == SIMD3<Float>(-0.65, 0.4, 0.2),
                       "An update closure must be able to read another object without overlapping storage access.")
            var invokedMissingUpdate = false
            let missing = renderer.updateObject(.custom("missing")) { _ in invokedMissingUpdate = true }
            try expect(!missing && !invokedMissingUpdate && renderer.object(withID: .custom("missing")) == nil,
                       "Missing IDs must return nil/false without invoking a mutation.")
        }
        var duplicateRejected = false
        do {
            _ = try Renderer(view: view, library: library, sceneObjects: [namedScene[0], namedScene[0]])
        } catch { duplicateRejected = true }
        try expect(duplicateRejected, "Duplicate scene IDs must be rejected instead of selecting an arbitrary object.")
        print("PASS: reordered scene IDs, targeted mutations, missing IDs, duplicate rejection")
    }

    static func checkMeshes(device: MTLDevice) throws {
        let square = try SquareMesh.make(device: device)
        let circle = try CircleMesh.make(device: device, segments: 10)
        let triangle = try TriangleMesh.make(device: device)
        for mesh in [square, circle, triangle] {
            guard let descriptor = MTKMetalVertexDescriptorFromModelIO(mesh.vertexDescriptor) else {
                throw Failure(description: "A 2D mesh has no usable vertex descriptor.")
            }
            try expect(descriptor.attributes[0].format == .float2
                       && descriptor.attributes[0].offset == 0
                       && descriptor.attributes[0].bufferIndex == 0
                       && descriptor.layouts[0].stride == MemoryLayout<SIMD2<Float>>.stride,
                       "Squares, circles, and triangles must share the packed float2 vertex layout.")
        }
        try expect(square.submeshes.first?.primitiveType == .triangle,
                   "Square geometry must remain triangles.")
        try expect(triangle.vertexCount == 3 && triangle.submeshes.count == 1
                   && triangle.submeshes.first?.primitiveType == .triangle
                   && triangle.submeshes.first?.indexCount == 3,
                   "Cone geometry must draw one triangle from three vertices.")
        guard circle.vertexCount == 11, circle.submeshes.count == 1,
              let vertices = circle.vertexBuffers.first, let triangles = circle.submeshes.first else {
            throw Failure(description: "A ten-segment circle must have one center, ten rim vertices, and one submesh.")
        }
        try expect(triangles.primitiveType == .triangle
                   && triangles.indexType == .uint16 && triangles.indexCount == 30,
                   "A solid circle must draw a full triangle fan.")
        let positions = vertices.buffer.contents().advanced(by: vertices.offset)
            .assumingMemoryBound(to: SIMD2<Float>.self)
        let indices = triangles.indexBuffer.buffer.contents().advanced(by: triangles.indexBuffer.offset)
            .assumingMemoryBound(to: UInt16.self)
        try expect(positions[0] == .zero, "The circle's first vertex must be its center.")
        for index in 0..<10 {
            let current = index + 1
            let next = (index + 1) % 10 + 1
            try expect(abs(simd_length(positions[current]) - 1) < 0.0001,
                       "Circle vertices must lie on the unit-radius perimeter.")
            try expect(indices[index * 3] == 0
                       && indices[index * 3 + 1] == UInt16(current)
                       && indices[index * 3 + 2] == UInt16(next),
                       "Each circle triangle must join the center to adjacent rim vertices, closing the seam.")
            let cross = positions[current].x * positions[next].y - positions[current].y * positions[next].x
            try expect(cross > 0, "Circle triangles must have consistent counterclockwise winding.")
            for previous in 1..<current {
                try expect(simd_distance(positions[current], positions[previous]) > 0.0001,
                           "Circle vertices must be unique, including the closing seam.")
            }
        }
        for count in [3, 65_535] {
            let boundary = try CircleMesh.make(device: device, segments: count)
            try expect(boundary.vertexCount == count + 1 && boundary.submeshes.first?.indexCount == count * 3,
                       "The valid UInt16 segment-count boundary \(count) must be supported.")
        }
        for count in [-1, 0, 1, 2, 65_536, Int.max] {
            var rejected = false
            do { _ = try CircleMesh.make(device: device, segments: count) }
            catch CircleMesh.SetupError.invalidSegmentCount { rejected = true }
            try expect(rejected, "Invalid circle segment count \(count) must throw before indexing.")
        }
        print("PASS: shared 2D layout, solid circle fan, unique rim, winding/seam, index-count bounds")
    }

    @MainActor
    static func checkMixedScene(
        view: MTKView, library: MTLLibrary, device: MTLDevice, queue: MTLCommandQueue
    ) throws {
        let squares = [
            ObjectPlacement(position: [-0.65, 0.65, 0], scale: [0.3, 0.2, 1]),
            ObjectPlacement(position: [0.7, -0.65, 0], scale: [0.2, 0.35, 1]),
        ]
        let circles = [ObjectPlacement(position: [0.1, -0.05, 0.5], scale: [0.5, 0.4, 1])]
        let renderer = try Renderer(
            view: view, library: library, sceneObjects: sceneObjects(squares: squares, circles: circles)
        )
        let viewports: [(Int, Int, CGSize?)] = [
            (512, 512, nil), (800, 400, nil),
            (800, 1024, CGSize(width: 400, height: 512)),
        ]
        for (width, height, viewportSize) in viewports {
            let pixels = try render(
                renderer, device: device, queue: queue,
                width: width, height: height, viewportSize: viewportSize
            )
            try checkPixels(
                pixels, width: width, height: height, placements: squares,
                circlePlacements: circles, viewportSize: viewportSize
            )
        }
        print("PASS: mixed bars and solid circle, filled center, clean outer boundary including Retina")
    }

    static func render(
        _ renderer: Renderer, device: MTLDevice, queue: MTLCommandQueue,
        width: Int, height: Int, viewportSize: CGSize? = nil
    ) throws -> [UInt8] {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
        )
        descriptor.usage = [.renderTarget]
        descriptor.storageMode = .private
        guard let color = device.makeTexture(descriptor: descriptor) else {
            throw Failure(description: "Could not allocate the color target.")
        }
        descriptor.pixelFormat = .depth32Float
        guard let depth = device.makeTexture(descriptor: descriptor) else {
            throw Failure(description: "Could not allocate the depth target.")
        }
        let bytesPerRow = ((width * 4 + 255) / 256) * 256
        guard let readback = device.makeBuffer(length: bytesPerRow * height, options: .storageModeShared),
              let command = queue.makeCommandBuffer() else {
            throw Failure(description: "Could not allocate the readback buffer or command buffer.")
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = color
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = SceneConfiguration.backgroundColor
        pass.depthAttachment.texture = depth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .dontCare
        pass.depthAttachment.clearDepth = 1
        try expect(renderer.encodeFrame(
            commandBuffer: command, renderPass: pass,
            drawableSize: CGSize(width: width, height: height), viewportSize: viewportSize
        ), "The renderer did not encode a frame.")
        guard let blit = command.makeBlitCommandEncoder() else {
            throw Failure(description: "Could not create the readback encoder.")
        }
        blit.copy(
            from: color, sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: width, height: height, depth: 1),
            to: readback, destinationOffset: 0, destinationBytesPerRow: bytesPerRow,
            destinationBytesPerImage: bytesPerRow * height
        )
        blit.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        if let error = command.error { throw error }
        try expect(command.status == .completed, "GPU work did not complete.")

        let bytes = readback.contents().assumingMemoryBound(to: UInt8.self)
        var pixels = [UInt8]()
        pixels.reserveCapacity(width * height * 4)
        for y in 0..<height {
            pixels.append(contentsOf: UnsafeBufferPointer(start: bytes + y * bytesPerRow, count: width * 4))
        }
        return pixels
    }

    static func checkPixels(
        _ pixels: [UInt8], width: Int, height: Int, placements: [ObjectPlacement],
        circlePlacements: [ObjectPlacement] = [], trianglePlacements: [ObjectPlacement] = [],
        viewportSize: CGSize? = nil
    ) throws {
        let color = SceneConfiguration.objectColor
        let background = SceneConfiguration.backgroundColor
        let foreground = [color.z, color.y, color.x, color.w].map { Int(($0 * 255).rounded()) }
        let clear = [background.blue, background.green, background.red, background.alpha]
            .map { Int(($0 * 255).rounded()) }
        func matches(_ index: Int, _ expected: [Int]) -> Bool {
            (0..<4).allSatisfy { abs(Int(pixels[index * 4 + $0]) - expected[$0]) <= 1 }
        }
        // Derive canvas bounds in points, then convert them to backing pixels.
        // This is independent of the matrix implementation and preserves squares
        // in both rectangular windows and Retina drawables.
        let viewport = viewportSize ?? CGSize(width: width, height: height)
        let side = max(min(viewport.width, viewport.height) - 2 * max(SceneConfiguration.canvasPadding, 0), 0)
        let pixelsPerPointX = CGFloat(width) / viewport.width
        let pixelsPerPointY = CGFloat(height) / viewport.height
        let bounds = placements.map { placement in
            let left = placement.position.x - placement.scale.x / 2
            let top = placement.position.y + placement.scale.y / 2
            return CGRect(
                x: (viewport.width / 2 + CGFloat(left) * side / 2) * pixelsPerPointX,
                y: (viewport.height / 2 - CGFloat(top) * side / 2) * pixelsPerPointY,
                width: CGFloat(placement.scale.x) * side / 2 * pixelsPerPointX,
                height: CGFloat(placement.scale.y) * side / 2 * pixelsPerPointY
            )
        }
        let ellipses = circlePlacements.map { placement in
            let left = CGFloat(placement.position.x - placement.scale.x)
            let top = CGFloat(placement.position.y + placement.scale.y)
            return CGRect(
                x: (viewport.width / 2 + left * side / 2) * pixelsPerPointX,
                y: (viewport.height / 2 - top * side / 2) * pixelsPerPointY,
                width: CGFloat(placement.scale.x) * side * pixelsPerPointX,
                height: CGFloat(placement.scale.y) * side * pixelsPerPointY
            )
        }
        // Derive triangle corners directly from 2D scale/rotation equations,
        // independently of the model matrix used by the renderer.
        let triangles = trianglePlacements.map { placement in
            [SIMD2<Float>(0, 1), SIMD2<Float>(0.5, 0), SIMD2<Float>(-0.5, 0)].map { vertex in
                let x = vertex.x * placement.scale.x
                let y = vertex.y * placement.scale.y
                let c = cos(placement.angle), s = sin(placement.angle)
                let worldX = x * c - y * s + placement.position.x
                let worldY = x * s + y * c + placement.position.y
                return CGPoint(
                    x: (viewport.width / 2 + CGFloat(worldX) * side / 2) * pixelsPerPointX,
                    y: (viewport.height / 2 - CGFloat(worldY) * side / 2) * pixelsPerPointY
                )
            }
        }
        func ellipseContains(_ point: CGPoint, in ellipse: CGRect, inset: CGFloat) -> Bool {
            let radiusX = ellipse.width / 2 - inset
            let radiusY = ellipse.height / 2 - inset
            guard radiusX > 0, radiusY > 0 else { return false }
            let x = (point.x - ellipse.midX) / radiusX
            let y = (point.y - ellipse.midY) / radiusY
            return x * x + y * y <= 1
        }
        func triangleContains(_ point: CGPoint, in triangle: [CGPoint], inset: CGFloat) -> Bool {
            let a = triangle[0], b = triangle[1], c = triangle[2]
            let area = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
            let orientation: CGFloat = area >= 0 ? 1 : -1
            for index in 0..<3 {
                let start = triangle[index], end = triangle[(index + 1) % 3]
                let dx = end.x - start.x, dy = end.y - start.y
                let length = (dx * dx + dy * dy).squareRoot()
                guard length > 0 else { return false }
                let distance = orientation * (dx * (point.y - start.y) - dy * (point.x - start.x)) / length
                if distance < inset { return false }
            }
            return true
        }
        for y in 0..<height {
            for x in 0..<width {
                let index = y * width + x
                let isForeground = matches(index, foreground)
                let isBackground = matches(index, clear)
                try expect(isForeground || isBackground,
                           "Unexpected shading or corrupted pixel at \(x),\(y).")
                let pixelCenter = CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)
                // Allow one pixel for rasterization and the circle's polygonal
                // boundary; check all other pixels, including the filled center.
                if bounds.contains(where: { $0.insetBy(dx: 1, dy: 1).contains(pixelCenter) })
                    || ellipses.contains(where: { ellipseContains(pixelCenter, in: $0, inset: 1) })
                    || triangles.contains(where: { triangleContains(pixelCenter, in: $0, inset: 1) }) {
                    try expect(isForeground, "Missing object pixel at \(x),\(y).")
                } else if !bounds.contains(where: { $0.insetBy(dx: -1, dy: -1).contains(pixelCenter) })
                    && !ellipses.contains(where: { ellipseContains(pixelCenter, in: $0, inset: -1) })
                    && !triangles.contains(where: { triangleContains(pixelCenter, in: $0, inset: -1) }) {
                    try expect(isBackground, "Object extends beyond its configured bounds at \(x),\(y).")
                }
            }
        }
    }
}
