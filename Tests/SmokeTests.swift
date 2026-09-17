import AppKit
import MetalKit
import simd

/// Runs the actual renderer against GPU textures without opening an app window.
@main
struct SmokeTests {
    /// Exercise key-window guards without showing or activating a real window.
    @MainActor
    final class InputTestWindow: NSWindow {
        var reportsKeyWindow = false
        override var isKeyWindow: Bool { reportsKeyWindow }
    }

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
            // Keep input/movement fixtures clear of this aperture; masking has dedicated GPU checks.
            placement: ObjectPlacement(position: [-0.65, 0.9, 0], scale: [0.25, 0.1, 1])
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
        try checkMouseInput(device: device, library: library)
        try checkObjectMovement(device: device, library: library, queue: queue)
        let view = MTKView(frame: .zero, device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float
        try checkObjectPlacement(device: device)
        try checkMeshes(device: device)
        try checkNamedObjects(view: view, library: library)
        try checkCloning(view: view, library: library, device: device, queue: queue)
        try checkResolutionUniform(view: view, device: device, queue: queue)
        try checkPortalIntersection(device: device, queue: queue)
        try checkPortalMasks(view: view, library: library, device: device, queue: queue)
        try checkViewportVision(view: view, library: library, device: device, queue: queue)
        try checkVisionFeathering(view: view, library: library, device: device, queue: queue)
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
        for _ in 0..<3 { emptyRenderer.updateScene() }
        try expect(emptyRenderer.object(withID: .circleClone) == nil && emptyRenderer.object(withID: .coneClone) == nil,
                   "An explicitly injected empty scene must never create default clones.")
        let empty = try render(emptyRenderer, device: device, queue: queue, width: 512, height: 512)
        try checkPixels(empty, width: 512, height: 512, placements: [])
        let tiny = try render(renderer, device: device, queue: queue, width: 128, height: 128)
        try checkPixels(tiny, width: 128, height: 128, placements: [])
        try checkMixedScene(view: view, library: library, device: device, queue: queue)
        try checkAlphaCompositing(view: view, library: library, device: device, queue: queue)
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
                   "A negative quarter-turn must aim the triangle's +Y flat-edge direction toward +X.")
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
        let frame = Transforms.frame(position: [5, 3, 0.2], angle: .pi / 2)
        let localPoint = SIMD4<Float>(2, 1, 0.3, 1)
        let worldPoint = SIMD4<Float>(4, 5, 0.5, 1)
        try expect(simd_distance(localPoint * frame, worldPoint) < 0.0001,
                   "A frame must rotate local coordinates before placing them in world space.")
        try expect(simd_distance(worldPoint * simd_inverse(frame), localPoint) < 0.0001,
                   "An inverse frame must recover the point's local coordinates.")
        try expect(simd_distance(SIMD4<Float>(1, 0, 0, 0) * frame, SIMD4<Float>(0, 1, 0, 0)) < 0.0001,
                   "A frame must rotate directions without translating or scaling them.")
        try checkCanvasMath()
        try checkCanvasPosition()
        try checkVisionScale()
        try checkPortalFrames()
        try checkPortalCrossings()

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
        try expect(MemoryLayout<ShaderUniforms>.size == 388
                   && MemoryLayout<ShaderUniforms>.stride == 400
                   && MemoryLayout<ShaderUniforms>.alignment == 16,
                   "Swift/Metal uniforms must include vision feathering with a 400-byte aligned stride.")
        try expect(MemoryLayout<ShaderUniforms>.offset(of: \.canvasMatrix) == 128,
                   "Swift/Metal uniform canvas matrix offset changed.")
        try expect(MemoryLayout<ShaderUniforms>.offset(of: \.color) == 192,
                   "Swift/Metal uniform color offset changed.")
        try expect(MemoryLayout<ShaderUniforms>.offset(of: \.worldToEntrance) == 208
                   && MemoryLayout<ShaderUniforms>.offset(of: \.eyeInEntrance) == 272
                   && MemoryLayout<ShaderUniforms>.offset(of: \.worldToExit) == 288
                   && MemoryLayout<ShaderUniforms>.offset(of: \.eyeInExit) == 352
                   && MemoryLayout<ShaderUniforms>.offset(of: \.resolution) == 368
                   && MemoryLayout<ShaderUniforms>.offset(of: \.portalHalfWidths) == 376
                   && MemoryLayout<ShaderUniforms>.offset(of: \.visionFeatherPixels) == 384,
                   "Swift/Metal portal frames, resolution, widths, and feathering offsets must match.")
    }

    static func checkPortalFrames() throws {
        let entrance = PortalFrame(placement: ObjectPlacement(
            position: [2, -3, 0.2], scale: [-0.8, 6, 4], angle: .pi / 2
        ))
        let exit = PortalFrame(placement: ObjectPlacement(
            position: [-4, 5, 0.4], scale: [1.2, 0.03, 1], angle: -.pi / 2
        ))
        let local = SIMD4<Float>(1, 2, 0.1, 1)
        let world = SIMD4<Float>(0, -2, 0.3, 1)
        try expect(simd_distance(local * entrance.localToWorld, world) < 0.0001
                   && simd_distance(world * entrance.worldToLocal, local) < 0.0001,
                   "Portal frames must rotate/translate without incorporating bar scale or thickness.")
        try expect(entrance.halfWidth == 0.4 && exit.halfWidth == 0.6,
                   "Portal opening widths must match the square mesh's absolute horizontal half-extent.")
        let closed = PortalFrame(placement: ObjectPlacement(scale: [0, 1, 1]))
        try expect(closed.halfWidth == 0, "Zero-width bars must represent closed openings.")
        let pair = PortalPair(entrance: entrance, exit: exit)
        let original = ObjectPlacement(position: [0, -2, 0.3], scale: [0.2, 0.5, 1.3], angle: 0.37)
        let mapped = pair.mappedPlacement(original)
        try expect(simd_distance(world * pair.transferMatrix, SIMD4<Float>(-2, 4, 0.5, 1)) < 0.0001
                   && simd_distance(mapped.position, SIMD3<Float>(-2, 4, 0.5)) < 0.0001,
                   "Portal pairs must map world to entrance-local to exit-world in row-vector order.")
        try expect(mapped.scale == original.scale && abs(mapped.angle - (original.angle - .pi)) < 0.0001,
                   "Portal mapping must preserve scale and the current frame-alignment convention without an extra half-turn.")
        let restored = PortalPair(entrance: exit, exit: entrance).mappedPlacement(mapped)
        try expect(simd_distance(restored.position, original.position) < 0.0001
                   && abs(restored.angle - original.angle) < 0.0001 && restored.scale == original.scale,
                   "Reversing a portal pair must restore the original placement.")
    }

    static func checkPortalCrossings() throws {
        let frame = PortalFrame(placement: ObjectPlacement(scale: [0.8, 0.03, 1]))
        let segments: [(SIMD3<Float>, SIMD3<Float>, Float?)] = [
            ([0, -0.4, 0.2], [0, 0.6, 0.7], 0.4),
            ([0, 0.6, 0.7], [0, -0.4, 0.2], 0.6),
            ([0, -0.00000001, 0], [0, 0.00000001, 0], 0.5), // Tiny sign changes still cross.
            ([0.4, -1, 0], [0.4, 1, 0], 0.5), // The opening includes its horizontal edges.
            ([0, -1, 0], [0, 0, 0], 1),       // Arriving exactly on the plane counts.
            ([0, 0, 0], [0, 1, 0], nil),      // Starting on the plane is not a new crossing.
            ([-0.1, 0.2, 0], [0.1, 0.2, 0], nil),
            ([0.41, -1, 0], [0.41, 1, 0], nil),
            ([0, -1, 0], [0, -0.2, 0], nil),
        ]
        for (from, to, expected) in segments {
            let actual = frame.crossingFraction(from: from, to: to)
            if let expected {
                try expect(actual.map { abs($0 - expected) < 0.0001 } == true,
                           "Portal movement must report the actual segment crossing fraction.")
            } else {
                try expect(actual == nil, "Parallel, same-side, outside, or starting-plane segments must not cross.")
            }
        }
        let rotated = PortalFrame(placement: ObjectPlacement(position: [0.2, -0.3, 0.8],
                                                              scale: [0.8, 0.03, 1], angle: 0.73))
        let normal = SIMD3<Float>(-sin(0.73), cos(0.73), 0)
        let center = SIMD3<Float>(0.2, -0.3, 0.2)
        try expect(rotated.crossingFraction(from: center - normal * 0.1, to: center + normal * 0.3)
            .map { abs($0 - 0.25) < 0.0001 } == true, "Crossing tests must use the portal's rotated plane.")

        let upper = PortalFrame(placement: ObjectPlacement(position: [0, 0.1, 0], scale: [1.2, 1, 1]))
        let closePair = PortalPair(entrance: upper, exit: frame)
        let forward = closePair.firstCrossing(from: [0, -0.1, 0], to: [0, 0.2, 0])
        let reverse = closePair.firstCrossing(from: [0, 0.2, 0], to: [0, -0.1, 0])
        try expect(forward?.entrance.halfWidth == frame.halfWidth
                   && reverse?.entrance.halfWidth == upper.halfWidth,
                   "When a step crosses both portals, select the earliest crossing in either direction.")
        let closed = PortalFrame(placement: ObjectPlacement(scale: [0, 1, 1]))
        try expect(closed.crossingFraction(from: [0, -1, 0], to: [0, 1, 0]) == nil
                   && PortalPair(entrance: closed, exit: upper).firstCrossing(from: [0, -1, 0], to: [0, 1, 0]) == nil
                   && PortalPair(entrance: upper, exit: closed).firstCrossing(from: [0, -1, 0], to: [0, 1, 0]) == nil,
                   "A crossing requires both an open entrance and an open exit.")

        let pair = PortalPair(entrance: frame, exit: rotated)
        for sign: Float in [-1, 1] {
            let from = SIMD3<Float>(0, -sign * 0.1, 0.4), to = SIMD3<Float>(0, 0, 0.4)
            let clearance = pair.exitClearanceOffset(from: from, to: to)
            let mappedEnd = SIMD4<Float>(to, 1) * pair.transferMatrix
            let clearedEnd = (mappedEnd + SIMD4<Float>(clearance, 0)) * rotated.worldToLocal
            try expect(clearance.z == 0 && simd_length(clearance) <= 0.00003
                       && clearedEnd.y * sign > 0 && abs(simd_dot(clearance, SIMD3<Float>(cos(0.73), sin(0.73), 0))) < 0.000001,
                       "Exact-plane arrivals need only a tiny XY clearance along the outgoing portal normal.")
        }
        try expect(pair.exitClearanceOffset(from: [0, -0.1, 0.4], to: [0, 0.1, 0.4]) == .zero,
                   "Movement already beyond the exit plane must keep its full mapped endpoint without a nudge.")
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

    static func checkVisionScale() throws {
        let base = SIMD3<Float>(0.62, 0.5, 2)
        let size = SIMD2<Float>(900, 600)
        let halfExtent = size / 400 // A 600-point short side minus 100 points on each side.
        for eye: SIMD2<Float> in [[0, 0], [5, -2], [-3, 4]] {
            for angle: Float in [0, 0.83, .pi / 2, -.pi / 2] {
                let scale = Transforms.visionScaleToCoverViewport(
                    scale: base, eyePosition: eye, angle: angle, viewportSize: size, padding: 100
                )
                try expect(scale.y >= base.y && scale.z == base.z
                           && abs(scale.x / scale.y - base.x / base.y) < 0.0001,
                           "Vision extension must preserve its opening angle and depth without shrinking its base scale.")
                let forward = SIMD2<Float>(-sin(angle), cos(angle))
                for x in [-halfExtent.x, halfExtent.x] {
                    for y in [-halfExtent.y, halfExtent.y] {
                        try expect(scale.y > simd_dot(SIMD2(x, y) - eye, forward),
                                   "The vision far edge must lie beyond every viewport corner, including padding.")
                    }
                }
            }
        }
        for size: SIMD2<Float> in [[0, 400], [400, 0], [128, 128]] {
            try expect(Transforms.visionScaleToCoverViewport(
                scale: base, eyePosition: .zero, angle: 0, viewportSize: size, padding: 100
            ) == base, "Collapsed viewports must leave the stored vision shape finite and unchanged.")
        }
        try expect(abs(SceneConfiguration.visionScale.x / (2 * SceneConfiguration.visionScale.y)
                       - tan(SceneConfiguration.visionFieldOfView / 2)) < 0.0001,
                   "The configured triangle shape must match the configured field of view.")
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
    static func checkMouseInput(device: MTLDevice, library: MTLLibrary) throws {
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
        view.mouseMoved(with: moved)
        try expect(view.mousePosition == point, "Mouse events must convert window locations into native view points.")
        try expect(view.mouseCanvasPosition == SIMD2<Float>(0.5, -0.25),
                   "Mouse mapping must account for bounds origin and use logical points, not Retina drawable pixels.")
        let renderer = try Renderer(view: view, library: library, sceneObjects: namedScene)
        func expectPointerOnlyTracksPosition() throws {
            renderer.updateInput(from: view)
            renderer.updateScene(deltaTime: 0.05)
            for configuration in namedScene {
                guard let object = renderer.object(withID: configuration.id) else {
                    throw Failure(description: "A mouse-tracking fixture disappeared.")
                }
                try expect(object.placement.position == configuration.placement.position
                           && object.placement.scale == configuration.placement.scale
                           && object.placement.angle == configuration.placement.angle && object.color == configuration.color,
                           "Mouse movement, dragging, clicks, and focus changes must never aim or move scene objects.")
            }
        }
        view.drawableSize = .zero
        renderer.draw(in: view)
        view.drawableSize = CGSize(width: 1800, height: 1200)
        try expect(renderer.mousePosition == SIMD2<Float>(0.5, -0.25),
                   "The draw loop must read mouse coordinates before checking drawable availability.")
        try expectPointerOnlyTracksPosition()
        try expect(renderer.mousePosition == view.mouseCanvasPosition,
                   "The renderer must still expose the pointer's canvas position.")

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
            try expectPointerOnlyTracksPosition()
        }
        for _ in 0..<2 {
            view.mouseDown(with: try event(.leftMouseDown, at: point))
            try expect(view.mousePosition == point, "A mouse click must update position before the next move.")
            try expectPointerOnlyTracksPosition()
        }
        let padding = CGPoint(x: view.bounds.minX + 50, y: view.bounds.midY)
        view.mouseMoved(with: try event(.mouseMoved, at: padding))
        try expect(view.mouseCanvasPosition == SIMD2<Float>(-2, 0),
                   "Mouse positions in window padding must remain available outside -1...1.")
        try expectPointerOnlyTracksPosition()
        view.mouseExited(with: try event(.mouseExited, at: padding))
        try expectPointerOnlyTracksPosition()
        try expect(view.mousePosition == nil && view.mouseCanvasPosition == nil && renderer.mousePosition == nil,
                   "Leaving the view must clear input and renderer mouse positions.")
        view.mouseEntered(with: try event(.mouseEntered, at: point))
        try expect(view.mousePosition == point, "Reentering the view must restore the current mouse location.")
        try expectPointerOnlyTracksPosition()
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        try expect(view.mousePosition == nil, "Window resignation must clear stale mouse input.")
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        view.updateTrackingAreas()
        try expectPointerOnlyTracksPosition()
        view.mouseMoved(with: moved)
        let outside = CGPoint(x: view.bounds.maxX + 1, y: view.bounds.midY)
        view.mouseDragged(with: try event(.leftMouseDragged, at: outside))
        try expect(view.mousePosition == nil, "Dragging outside the view must clear mouse input.")
        view.setFrameSize(CGSize(width: 128, height: 128))
        view.mouseMoved(with: try event(.mouseMoved, at: CGPoint(x: view.bounds.midX, y: view.bounds.midY)))
        try expect(view.mouseCanvasPosition == nil, "Collapsed canvases must not expose mouse canvas coordinates.")
        try expectPointerOnlyTracksPosition()
        view.setFrameSize(CGSize(width: 900, height: 600))
        view.mouseEntered(with: try event(.mouseEntered, at: point))
        try expect(view.mousePosition == point, "Restoring the canvas must restore usable pointer tracking.")
        _ = window.makeFirstResponder(nil)
        _ = window.makeFirstResponder(view)
        try expectPointerOnlyTracksPosition()
        view.removeFromSuperview()
        try expect(view.mousePosition == nil && view.mouseCanvasPosition == nil,
                   "Detaching the view must clear mouse input.")
        view.mouseMoved(with: moved)
        try expect(view.mousePosition == nil, "Detached views must ignore mouse callbacks.")
        print("PASS: native mouse coordinates, dragging/clicks, Retina, input cleanup, no mouse aiming")
    }

    @MainActor
    static func checkObjectMovement(device: MTLDevice, library: MTLLibrary, queue: MTLCommandQueue) throws {
        _ = NSApplication.shared
        let window = InputTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.reportsKeyWindow = false; window.close() }
        let view = KeyboardMetalView(frame: NSRect(x: 0, y: 0, width: 900, height: 600), device: device)
        view.isPaused = true
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float
        window.contentView = view
        window.reportsKeyWindow = true
        try expect(window.makeFirstResponder(view), "The hidden input fixture must accept keyboard focus.")

        func keyEvent(
            _ key: String, code: UInt16, type: NSEvent.EventType = .keyDown,
            repeated: Bool = false, modifiers: NSEvent.ModifierFlags = []
        ) throws -> NSEvent {
            guard let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: window.windowNumber, context: nil,
                characters: key, charactersIgnoringModifiers: key, isARepeat: repeated, keyCode: code
            ) else { throw Failure(description: "Could not construct a keyboard event.") }
            return event
        }
        func renderer() throws -> Renderer {
            try Renderer(view: view, library: library, sceneObjects: namedScene)
        }
        func mouseEvent(_ type: NSEvent.EventType, at position: SIMD2<Float>) throws -> NSEvent {
            let side = min(view.bounds.width, view.bounds.height) - 2 * SceneConfiguration.canvasPadding
            let point = CGPoint(
                x: view.bounds.midX + CGFloat(position.x) * side / 2,
                y: view.bounds.midY + CGFloat(position.y) * side / 2
            )
            guard let event = NSEvent.mouseEvent(
                with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0
            ) else { throw Failure(description: "Could not construct a pointer-tracking mouse event.") }
            return event
        }
        func expectMovement(_ renderer: Renderer, displacement: SIMD2<Float>) throws {
            for configuration in namedScene {
                guard let object = renderer.object(withID: configuration.id) else {
                    throw Failure(description: "A movement fixture disappeared.")
                }
                let moves = configuration.id == .cone || configuration.id == .circle
                let offset = moves ? SIMD3<Float>(displacement.x, displacement.y, 0) : .zero
                try expect(simd_distance(object.placement.position, configuration.placement.position + offset) < 0.0001,
                           "Only the named cone and circle must receive the same XY displacement; depth must stay fixed.")
                try expect(object.placement.scale == configuration.placement.scale && object.color == configuration.color,
                           "Keyboard movement must preserve object scale and color.")
                if configuration.id != .cone {
                    try expect(object.placement.angle == configuration.placement.angle,
                               "Keyboard movement must not rotate circles or bars.")
                }
            }
        }

        let bindings: [(String, UInt16, SIMD2<Float>)] = [
            ("w", 13, [0, 1]), ("a", 0, [-1, 0]), ("s", 1, [0, -1]), ("d", 2, [1, 0]),
        ]
        for (key, code, direction) in bindings {
            view.keyDown(with: try keyEvent(key, code: code))
            try expect(view.movementDirection == direction, "WASD must map to the expected XY direction.")
            view.keyDown(with: try keyEvent(key, code: code, repeated: true))
            try expect(view.movementDirection == direction, "Key repeats must not accumulate movement strength.")
            view.keyUp(with: try keyEvent(key.uppercased(), code: code, type: .keyUp, modifiers: [.shift]))
            try expect(view.movementDirection == SIMD2<Float>.zero,
                       "Key release must stop movement even when modifiers change.")
        }
        for (key, code, direction): (String, UInt16, Float) in [("q", 12, 1), ("e", 14, -1)] {
            view.keyDown(with: try keyEvent(key, code: code))
            try expect(view.rotationDirection == direction && view.movementDirection == .zero,
                       "Q must rotate counterclockwise and E clockwise without creating movement.")
            view.keyDown(with: try keyEvent(key, code: code, repeated: true))
            try expect(view.rotationDirection == direction, "Key repeats must not accumulate rotation strength.")
            view.keyUp(with: try keyEvent(key.uppercased(), code: code, type: .keyUp, modifiers: [.shift]))
            try expect(view.rotationDirection == 0, "Physical key release must stop rotation even if modifiers change.")
        }
        view.keyDown(with: try keyEvent("q", code: 12))
        view.keyDown(with: try keyEvent("e", code: 14))
        try expect(view.rotationDirection == 0, "Holding Q and E together must cancel rotation.")
        view.keyUp(with: try keyEvent("e", code: 14, type: .keyUp))
        try expect(view.rotationDirection == 1, "Releasing E while Q remains held must resume counterclockwise rotation.")
        for (key, code, _) in bindings { view.keyDown(with: try keyEvent(key, code: code)) }
        try expect(view.movementDirection == SIMD2<Float>.zero, "Opposite held keys must cancel on both axes.")
        view.keyUp(with: try keyEvent("a", code: 0, type: .keyUp))
        view.keyUp(with: try keyEvent("s", code: 1, type: .keyUp))
        try expect(view.movementDirection == SIMD2<Float>(1, 1), "Held W and D must combine into a diagonal.")
        _ = window.makeFirstResponder(nil)
        try expect(view.movementDirection == .zero && view.rotationDirection == 0,
                   "Losing first-responder focus must stop movement and rotation.")
        _ = window.makeFirstResponder(view)
        try expect(view.movementDirection == .zero && view.rotationDirection == 0,
                   "Restoring focus must not revive held keys.")
        view.keyDown(with: try keyEvent("w", code: 13))
        view.keyDown(with: try keyEvent("e", code: 14))
        window.reportsKeyWindow = false
        try expect(view.movementDirection == .zero && view.rotationDirection == 0,
                   "A non-key window must not report movement or rotation.")
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        window.reportsKeyWindow = true
        try expect(view.movementDirection == .zero && view.rotationDirection == 0,
                   "Window resignation must clear all held keys.")

        let speed = SceneConfiguration.objectMovementSpeed
        view.keyDown(with: try keyEvent("d", code: 2))
        let straight = try renderer()
        straight.updateInput(from: view)
        straight.updateScene(deltaTime: 0.04)
        try expectMovement(straight, displacement: [speed * 0.04, 0])
        try expect(straight.mousePosition == nil && straight.object(withID: .cone)?.placement.angle == 0.37,
                   "Keyboard movement must work without mouse input and retain the last cone angle.")
        let splitFrames = try renderer()
        splitFrames.updateInput(from: view)
        splitFrames.updateScene(deltaTime: 0.02)
        splitFrames.updateScene(deltaTime: 0.02)
        try expectMovement(splitFrames, displacement: [speed * 0.04, 0])
        let clamped = try renderer()
        clamped.updateInput(from: view)
        clamped.updateScene(deltaTime: -1)
        try expectMovement(clamped, displacement: .zero)
        clamped.updateScene(deltaTime: 100)
        clamped.updateScene(deltaTime: 0)
        try expectMovement(clamped, displacement: [speed * 0.1, 0])
        view.keyDown(with: try keyEvent("w", code: 13))
        let diagonal = try renderer()
        diagonal.updateInput(from: view)
        diagonal.updateScene(deltaTime: 0.04)
        let diagonalStep = SIMD2<Float>(repeating: speed * 0.04 / sqrt(2))
        try expectMovement(diagonal, displacement: diagonalStep)
        view.keyUp(with: try keyEvent("w", code: 13, type: .keyUp))
        view.keyUp(with: try keyEvent("d", code: 2, type: .keyUp))
        diagonal.updateInput(from: view)
        diagonal.updateScene(deltaTime: 0.1)
        try expectMovement(diagonal, displacement: diagonalStep)

        let rotationSpeed = SceneConfiguration.objectRotationSpeed
        let initialAngle: Float = 0.37
        func expectAngle(_ renderer: Renderer, _ expected: Float) throws {
            guard let cone = renderer.object(withID: .cone) else {
                throw Failure(description: "The rotating cone fixture is missing.")
            }
            try expect(abs(cone.placement.angle - expected) < 0.0001,
                       "Held Q/E rotation must advance by direction times speed times clamped frame time.")
            let tip = SIMD4<Float>(0, 0, 0, 1) * cone.modelMatrix
            try expect(simd_distance(tip, SIMD4<Float>(cone.placement.position, 1)) < 0.0001,
                       "Keyboard rotation must keep the triangle's tip fixed at its own position.")
        }
        view.keyDown(with: try keyEvent("q", code: 12))
        let rotating = try renderer()
        try expect(rotating.cloneObject(.cone, newID: .coneClone), "The rotation fixture must create its cone clone.")
        let drawableSize = view.drawableSize
        view.autoResizeDrawable = false
        view.drawableSize = .zero
        rotating.draw(in: view)
        view.drawableSize = drawableSize
        rotating.updateScene(deltaTime: 0.04)
        try expectAngle(rotating, initialAngle + rotationSpeed * 0.04)
        try expectMovement(rotating, displacement: .zero)
        try expect(rotating.mousePosition == nil, "Rotation alone must work without mouse input.")
        try expect(abs((rotating.object(withID: .coneClone)?.placement.angle ?? 0)
                       - (initialAngle + rotationSpeed * 0.04)) < 0.0001,
                   "The existing portal mapping must carry Q/E rotation to the cone clone.")
        let splitRotation = try renderer()
        splitRotation.updateInput(from: view)
        splitRotation.updateScene(deltaTime: 0.02)
        splitRotation.updateScene(deltaTime: 0.02)
        try expectAngle(splitRotation, initialAngle + rotationSpeed * 0.04)
        let pausedRotation = try renderer()
        pausedRotation.updateInput(from: view)
        pausedRotation.updateScene(deltaTime: -1)
        try expectAngle(pausedRotation, initialAngle)
        pausedRotation.updateScene(deltaTime: 100)
        pausedRotation.updateScene(deltaTime: 0)
        try expectAngle(pausedRotation, initialAngle + rotationSpeed * 0.1)
        view.keyUp(with: try keyEvent("q", code: 12, type: .keyUp))
        rotating.updateInput(from: view)
        rotating.updateScene(deltaTime: 0.1)
        try expectAngle(rotating, initialAngle + rotationSpeed * 0.04)
        view.keyDown(with: try keyEvent("e", code: 14))
        rotating.updateInput(from: view)
        rotating.updateScene(deltaTime: 0.02)
        try expectAngle(rotating, initialAngle + rotationSpeed * 0.02)
        view.keyUp(with: try keyEvent("e", code: 14, type: .keyUp))

        view.mouseMoved(with: try mouseEvent(.mouseMoved, at: [0.5, -0.25]))
        let combined = try renderer()
        combined.updateInput(from: view)
        combined.updateScene(deltaTime: 0.05)
        try expectAngle(combined, initialAngle)
        view.keyDown(with: try keyEvent("w", code: 13))
        view.keyDown(with: try keyEvent("q", code: 12))
        combined.updateInput(from: view)
        combined.updateScene(deltaTime: 0.1)
        try expectMovement(combined, displacement: [0, speed * 0.1])
        try expectAngle(combined, initialAngle + rotationSpeed * 0.1)
        view.mouseDown(with: try mouseEvent(.leftMouseDown, at: [-0.5, 0.5]))
        combined.updateInput(from: view)
        combined.updateScene(deltaTime: 0.02)
        let step = speed * 0.12
        let expectedAngle = initialAngle + rotationSpeed * 0.12
        try expectMovement(combined, displacement: [0, step])
        try expectAngle(combined, expectedAngle)
        try expect(combined.mousePosition == SIMD2<Float>(-0.5, 0.5),
                   "WASD and Q/E must leave camera and tracked mouse coordinates fixed.")
        var squares: [ObjectPlacement] = [], circles: [ObjectPlacement] = [], triangles: [ObjectPlacement] = []
        for configuration in namedScene {
            var placement = configuration.placement
            if configuration.id == .cone || configuration.id == .circle { placement.position.y += step }
            if configuration.id == .cone { placement.angle = expectedAngle }
            switch configuration.geometry {
            case .square: squares.append(placement)
            case .circle: circles.append(placement)
            case .triangle: triangles.append(placement)
            }
        }
        let pixels = try render(combined, device: device, queue: queue, width: 900, height: 600)
        try checkPixels(pixels, width: 900, height: 600, placements: squares,
                        circlePlacements: circles, trianglePlacements: triangles, featheredTriangleIndices: [0])
        let plainView = MTKView(frame: .zero, device: device)
        plainView.drawableSize = .zero
        combined.draw(in: plainView)
        combined.updateScene(deltaTime: 0.1)
        try expectMovement(combined, displacement: [0, step])
        try expectAngle(combined, expectedAngle)
        try expect(combined.mousePosition == nil, "A non-input view must clear pointer, movement, and rotation input.")
        view.keyUp(with: try keyEvent("w", code: 13, type: .keyUp))
        view.keyUp(with: try keyEvent("q", code: 12, type: .keyUp))
        try checkPortalMovement(view: view, library: library)
        view.keyDown(with: try keyEvent("w", code: 13))
        view.keyDown(with: try keyEvent("q", code: 12))
        window.contentView = NSView(frame: view.frame)
        try expect(view.movementDirection == .zero && view.rotationDirection == 0,
                   "Detaching the view must clear held movement and rotation keys.")
        window.contentView = view
        try expect(window.makeFirstResponder(view), "The reattached input fixture must accept keyboard focus.")
        try expect(view.movementDirection == .zero && view.rotationDirection == 0,
                   "Reattaching the view must not restore previously held keys.")
        print("PASS: held WASD and Q/E, independent movement/rotation, frame timing, fixed pivot, clone rotation, GPU rotation")
    }

    @MainActor
    static func checkPortalMovement(view: KeyboardMetalView, library: MTLLibrary) throws {
        guard let window = view.window else { throw Failure(description: "Portal movement needs an attached input view.") }
        let step = SceneConfiguration.objectMovementSpeed * 0.1
        let offset = SIMD3<Float>(0, step, 0)
        let entrance = ObjectPlacement(position: [0.2, -0.2, 0.7], scale: [0.8, 0.03, 1], angle: 0.3)
        let exit = ObjectPlacement(position: [-0.5, 0.6, 0.1], scale: [0.6, 0.05, 1], angle: -0.8)
        func scene(circle: ObjectPlacement?, cone: ObjectPlacement,
                   entrance: ObjectPlacement?, exit: ObjectPlacement?) -> [SceneObjectConfiguration] {
            var objects = [SceneObjectConfiguration(id: .cone, geometry: .triangle, placement: cone)]
            if let circle { objects.append(SceneObjectConfiguration(id: .circle, geometry: .circle, placement: circle)) }
            if let entrance { objects.append(SceneObjectConfiguration(id: .bottomBar, geometry: .square, placement: entrance)) }
            if let exit { objects.append(SceneObjectConfiguration(id: .topBar, geometry: .square, placement: exit)) }
            return objects
        }
        func setKey(_ key: String, down: Bool) throws {
            let codes: [String: UInt16] = ["w": 13, "s": 1, "d": 2, "q": 12]
            guard let code = codes[key], let event = NSEvent.keyEvent(
                with: down ? .keyDown : .keyUp, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: key,
                charactersIgnoringModifiers: key, isARepeat: false, keyCode: code
            ) else { throw Failure(description: "Could not construct the portal movement key event.") }
            if down { view.keyDown(with: event) } else { view.keyUp(with: event) }
        }
        func move(_ objects: [SceneObjectConfiguration], key: String = "w", keepHeld: Bool = false) throws -> Renderer {
            let renderer = try Renderer(view: view, library: library, sceneObjects: objects)
            try setKey(key, down: true)
            renderer.updateInput(from: view)
            renderer.updateScene(deltaTime: 0.1)
            if !keepHeld { try setKey(key, down: false) }
            return renderer
        }
        // Independent 2D frame equations: map the proposed endpoint, then preserve render depth.
        func expected(_ original: ObjectPlacement, from: ObjectPlacement, to: ObjectPlacement) -> ObjectPlacement {
            let delta = original.position + offset - from.position
            let localX = delta.x * cos(from.angle) + delta.y * sin(from.angle)
            let localY = -delta.x * sin(from.angle) + delta.y * cos(from.angle)
            var result = original
            result.position = [to.position.x + localX * cos(to.angle) - localY * sin(to.angle),
                               to.position.y + localX * sin(to.angle) + localY * cos(to.angle), original.position.z]
            let angle = original.angle - from.angle + to.angle
            result.angle = atan2(sin(angle), cos(angle))
            return result
        }
        for (reversed, includesCircle) in [(false, true), (true, true), (false, false)] {
            let from = reversed ? exit : entrance, to = reversed ? entrance : exit
            let circle = ObjectPlacement(position: [from.position.x, from.position.y - step / 2, 0.2],
                                         scale: [0.04, 0.06, 1.7], angle: 0.31)
            var cone = ObjectPlacement(position: circle.position, scale: [0.5, 0.4, 2.3], angle: -0.4)
            // The cone is already across the plane: the body must choose the transfer for both.
            if includesCircle { cone.position += [0.06, step * 1.5, 0] }
            cone.position.z = 0.6
            let configurations = scene(circle: includesCircle ? circle : nil, cone: cone, entrance: entrance, exit: exit)
            let renderer = try move(configurations)
            for configuration in configurations {
                guard let actual = renderer.object(withID: configuration.id) else {
                    throw Failure(description: "A portal movement fixture disappeared.")
                }
                let player = configuration.id == .circle || configuration.id == .cone
                let placement = player ? expected(configuration.placement, from: from, to: to) : configuration.placement
                try expect(simd_distance(actual.placement.position, placement.position) < 0.00001
                           && abs(actual.placement.angle - placement.angle) < 0.00001
                           && actual.placement.scale == placement.scale && actual.color == configuration.color,
                           "Portal crossing must map both proposed positions and headings coherently, preserving depth, scale, and other objects.")
            }
        }

        let axisEntrance = ObjectPlacement(position: [0, 0, 0.7], scale: [0.8, 0.03, 1])
        let axisExit = ObjectPlacement(position: [0.5, 0.5, 0.1], scale: [0.8, 0.03, 1], angle: 0.7)
        let arrival = ObjectPlacement(position: [0, -step, 0.2], scale: [0.04, 0.06, 1.7], angle: 0.31)
        let cone = ObjectPlacement(position: [0.06, step / 2, 0.6], scale: [0.5, 0.4, 2.3], angle: -0.4)
        let arrived = try move(scene(circle: arrival, cone: cone, entrance: axisEntrance, exit: axisExit))
        let expectedBody = expected(arrival, from: axisEntrance, to: axisExit)
        let expectedCone = expected(cone, from: axisEntrance, to: axisExit)
        guard let bodyAfter = arrived.object(withID: .circle), let coneAfter = arrived.object(withID: .cone) else {
            throw Failure(description: "Exact-endpoint movement lost a player object.")
        }
        let clearance = bodyAfter.placement.position - expectedBody.position
        let outgoing = SIMD3<Float>(-sin(axisExit.angle), cos(axisExit.angle), 0)
        try expect(clearance.z == 0 && simd_dot(clearance, outgoing) > 0 && simd_length(clearance) <= 0.00003
                   && simd_distance(coneAfter.placement.position - expectedCone.position, clearance) < 0.000001,
                   "An exact-plane arrival must apply the same tiny outgoing clearance to body and cone.")
        arrived.updateInput(from: view) // Key-up: an idle frame must not transfer back from the exit plane.
        arrived.updateScene(deltaTime: 0.1)
        try expect(arrived.object(withID: .circle)?.placement.position == bodyAfter.placement.position
                   && arrived.object(withID: .cone)?.placement.position == coneAfter.placement.position,
                   "Stopping after an exact endpoint must retain the transferred placement.")

        var closed = axisEntrance
        closed.scale.x = 0
        let unavailable: [(ObjectPlacement?, ObjectPlacement?)] = [
            (nil, nil), (axisEntrance, nil), (nil, axisExit), (closed, axisExit), (axisEntrance, closed),
        ]
        for (entrance, exit) in unavailable {
            let renderer = try move(scene(circle: arrival, cone: cone, entrance: entrance, exit: exit))
            for (id, before): (SceneObjectID, ObjectPlacement) in [(.circle, arrival), (.cone, cone)] {
                try expect(renderer.object(withID: id)?.placement.position == before.position + offset
                           && renderer.object(withID: id)?.placement.angle == before.angle,
                           "Missing or closed portal pairs must allow ordinary movement without a transfer or crash.")
            }
        }
        for (position, key, delta): (SIMD3<Float>, String, SIMD3<Float>) in [
            ([0, -0.1, 0.2], "d", [step, 0, 0]), ([0.6, -step / 2, 0.2], "w", offset),
        ] {
            let placement = ObjectPlacement(position: position, scale: [0.04, 0.06, 1], angle: 0.31)
            let renderer = try move(scene(circle: placement, cone: placement, entrance: axisEntrance, exit: axisExit), key: key)
            try expect(renderer.object(withID: .circle)?.placement.position == position + delta
                       && renderer.object(withID: .cone)?.placement.position == position + delta,
                       "Parallel movement and segments outside the finite opening must not teleport.")
        }
        let controlCases: [(Bool, Float, Float)] = [
            (false, 1, .pi), (false, -1, .pi), (true, 1, .pi), (true, -1, .pi), (false, 1, 0.83),
        ]
        for (reversed, sign, exitAngle) in controlCases {
            let entrance = ObjectPlacement(scale: [1.4, 0.03, 1])
            let exit = ObjectPlacement(position: [0.6, 0.6, 0], scale: [1.4, 0.03, 1], angle: exitAngle)
            let from = reversed ? exit : entrance, to = reversed ? entrance : exit
            let angle = to.angle - from.angle
            let forward = SIMD3<Float>(-sin(angle) * sign, cos(angle) * sign, 0)
            let right = SIMD3<Float>(cos(angle), sin(angle), 0)
            let position = SIMD3<Float>(from.position.x, from.position.y - sign * step / 2, 0.2)
            let circle = ObjectPlacement(position: position, scale: [0.04, 0.06, 1], angle: 0.31)
            var cone = circle
            cone.position.z = 0.6
            cone.angle = -0.4
            let key = sign > 0 ? "w" : "s", opposite = sign > 0 ? "s" : "w"
            let renderer = try move(scene(circle: circle, cone: cone, entrance: entrance, exit: exit),
                                    key: key, keepHeld: true)
            func expectPosition(_ xy: SIMD3<Float>) throws {
                for (id, z): (SceneObjectID, Float) in [(.circle, 0.2), (.cone, 0.6)] {
                    guard let object = renderer.object(withID: id) else {
                        throw Failure(description: "A portal-relative control fixture disappeared.")
                    }
                    try expect(simd_distance(object.placement.position, SIMD3<Float>(xy.x, xy.y, z)) < 0.00001,
                               "Portal-relative controls must move body and cone together along the mapped key axes.")
                }
            }
            for frame in 1...4 {
                if frame > 1 { renderer.updateInput(from: view); renderer.updateScene(deltaTime: 0.1) }
                try expectPosition(to.position + forward * step * (Float(frame) - 0.5))
            }
            try setKey(key, down: false)
            renderer.updateInput(from: view)
            renderer.updateScene(deltaTime: 0.1)
            var expectedPosition = to.position + forward * step * 3.5
            try expectPosition(expectedPosition)
            try setKey("d", down: true)
            renderer.updateInput(from: view)
            renderer.updateScene(deltaTime: 0.05)
            expectedPosition += right * step * 0.5
            try expectPosition(expectedPosition)
            if !reversed && sign == 1 && exitAngle == .pi {
                _ = window.makeFirstResponder(nil)
                renderer.updateInput(from: view)
                renderer.updateScene(deltaTime: 0.1)
                try expectPosition(expectedPosition)
                _ = window.makeFirstResponder(view)
                renderer.updateInput(from: view)
                renderer.updateScene(deltaTime: 0.1)
                try expectPosition(expectedPosition)
                try setKey("d", down: true)
            }
            // Q rotates the cone independently; it must not rotate the persistent movement axes.
            try setKey("q", down: true)
            renderer.updateInput(from: view)
            renderer.updateScene(deltaTime: 0.02)
            expectedPosition += right * step * 0.2
            try expectPosition(expectedPosition)
            let expectedAngle = cone.angle + angle + SceneConfiguration.objectRotationSpeed * 0.02
            guard let actualAngle = renderer.object(withID: .cone)?.placement.angle else {
                throw Failure(description: "The portal-relative cone disappeared.")
            }
            try expect(simd_distance(SIMD2<Float>(cos(actualAngle), sin(actualAngle)),
                                     SIMD2<Float>(cos(expectedAngle), sin(expectedAngle))) < 0.00001,
                       "Q/E rotation must remain independent of portal-relative movement controls.")
            try setKey("q", down: false)
            try setKey(key, down: true)
            renderer.updateInput(from: view)
            renderer.updateScene(deltaTime: 0.02)
            let diagonalPart: Float = 0.2 / sqrt(2)
            expectedPosition += (forward + right) * step * diagonalPart
            try expectPosition(expectedPosition)
            try setKey(key, down: false)
            try setKey("d", down: false)
            try setKey(opposite, down: true)
            renderer.updateInput(from: view)
            for _ in 0..<4 { renderer.updateScene(deltaTime: 0.1) }
            expectedPosition = from.position + SIMD3<Float>(step * (0.7 + diagonalPart), sign * step * (-0.5 + diagonalPart), 0)
            try expectPosition(expectedPosition)
            renderer.updateScene(deltaTime: 0.1)
            expectedPosition.y -= sign * step
            try expectPosition(expectedPosition)
            try setKey(opposite, down: false)
            try setKey("d", down: true)
            renderer.updateInput(from: view)
            renderer.updateScene(deltaTime: 0.1)
            expectedPosition.x += step
            try expectPosition(expectedPosition)
            try setKey("d", down: false)
        }
        print("PASS: rotated and reverse portal movement, shared body/cone transfer, proposed endpoint, depth, clearance, missing portals")
        print("PASS: sustained portal-relative controls, both directions/sides, arbitrary angles, focus, diagonal speed, return travel, independent Q/E")
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

    @MainActor
    static func checkCloning(
        view: MTKView, library: MTLLibrary, device: MTLDevice, queue: MTLCommandQueue
    ) throws {
        let circlePlacement = ObjectPlacement(position: [-0.45, -0.35, 0.2], scale: [0.13, 0.09, 1])
        let conePlacement = ObjectPlacement(position: [-0.45, 0.15, 0.3], scale: [0.25, 0.35, 1], angle: 0.31)
        let configurations = [
            SceneObjectConfiguration(id: .circle, geometry: .circle, placement: circlePlacement,
                                     color: SceneConfiguration.objectColor),
            SceneObjectConfiguration(id: .cone, geometry: .triangle, placement: conePlacement,
                                     color: SceneConfiguration.objectColor),
        ]
        let renderer = try Renderer(view: view, library: library, sceneObjects: configurations)
        // Generic copies use custom IDs; the named cone clone intentionally has portal clipping.
        let pairs: [(SceneObjectID, SceneObjectID)] = [
            (.circle, .custom("circle-copy")), (.cone, .custom("cone-copy")),
        ]
        var copiedPlacements: [ObjectPlacement] = []
        for (sourceID, cloneID) in pairs {
            try expect(renderer.object(withID: cloneID) == nil, "Injected scenes must remain clone-free until requested.")
            try expect(renderer.cloneObject(sourceID, newID: cloneID), "Cloning an existing object into a new ID must succeed.")
            guard let source = renderer.object(withID: sourceID), let clone = renderer.object(withID: cloneID) else {
                throw Failure(description: "The source or its clone is missing.")
            }
            try expect(clone.id == cloneID && clone.mesh === source.mesh
                       && clone.placement.position == source.placement.position
                       && clone.placement.scale == source.placement.scale
                       && clone.placement.angle == source.placement.angle && clone.color == source.color
                       && clone.extendsVisionToViewport == source.extendsVisionToViewport,
                       "A clone must share the exact GPU mesh and copy every editable scene property.")
            var displaced = source.placement
            displaced.position.x += 0.9
            displaced.scale *= 0.8
            let cloneColor = SIMD4<Float>(0.3, 0.6, 0.9, 0.5)
            renderer.updateObject(cloneID) { object in
                object.placement = displaced
                object.placement.angle += 0.2
                object.color = cloneColor
            }
            try expect(renderer.object(withID: sourceID)?.placement.position == source.placement.position
                       && renderer.object(withID: sourceID)?.placement.scale == source.placement.scale
                       && renderer.object(withID: sourceID)?.placement.angle == source.placement.angle
                       && renderer.object(withID: sourceID)?.color == source.color,
                       "Editing a clone's placement and color must leave its source unchanged.")
            renderer.updateObject(sourceID) { $0.color = [0.9, 0.1, 0.2, 1] }
            try expect(renderer.object(withID: cloneID)?.color == cloneColor,
                       "Editing the source must not change the clone's copied color.")
            renderer.updateObject(sourceID) { $0.color = source.color }
            renderer.updateObject(cloneID) { object in
                object.placement.angle = displaced.angle
                object.color = source.color
            }
            try expect(!renderer.cloneObject(sourceID, newID: cloneID)
                       && !renderer.cloneObject(sourceID, newID: sourceID),
                       "Existing target IDs and cloning onto the source ID must be rejected.")
            try expect(renderer.object(withID: cloneID)?.placement.position == displaced.position
                       && renderer.object(withID: cloneID)?.placement.scale == displaced.scale,
                       "A rejected clone request must not overwrite the existing target.")
            copiedPlacements.append(displaced)
        }
        try expect(!renderer.cloneObject(.custom("missing"), newID: .custom("failed-clone"))
                   && renderer.object(withID: .custom("failed-clone")) == nil,
                   "A missing source must fail without creating an object.")
        let pixels = try render(renderer, device: device, queue: queue, width: 512, height: 512)
        try checkPixels(pixels, width: 512, height: 512, placements: [],
                        circlePlacements: [circlePlacement, copiedPlacements[0]],
                        trianglePlacements: [conePlacement, copiedPlacements[1]], featheredTriangleIndices: [0])

        let startup = try Renderer(view: view, library: library)
        let defaultPairs: [(SceneObjectID, SceneObjectID)] = [(.circle, .circleClone), (.cone, .coneClone)]
        for (sourceID, cloneID) in defaultPairs {
            guard let source = startup.object(withID: sourceID), let clone = startup.object(withID: cloneID) else {
                throw Failure(description: "The default renderer must create the circle and cone clones once.")
            }
            try expect(clone.mesh === source.mesh
                       && clone.placement.position == source.placement.position
                       && clone.placement.scale == source.placement.scale
                       && clone.placement.angle == source.placement.angle
                       && clone.extendsVisionToViewport == source.extendsVisionToViewport
                       && clone.color == (cloneID == .coneClone ? SceneConfiguration.portalVisionColor : SceneConfiguration.cloneColor),
                       "Default clones must copy source placement and retain their distinct teal appearance.")
            startup.updateObject(sourceID) {
                $0.placement.position += SIMD3<Float>(0.13, -0.17, 0)
                $0.placement.angle = 1.1
            }
            startup.updateObject(cloneID) {
                $0.placement.position = [99, 99, 4]
                $0.placement.angle = -2
            }
        }
        let referencePortal = ObjectPlacement(position: [0.3, -0.2, 0], scale: [0.4, 0.035, 1], angle: 0.73)
        startup.updateObject(.bottomBar) { $0.placement = referencePortal }
        guard let destinationPortal = startup.object(withID: .topBar)?.placement else {
            throw Failure(description: "The default scene must contain its destination portal.")
        }
        func expectedMappedPosition(_ position: SIMD3<Float>) -> SIMD3<Float> {
            let offset = position - referencePortal.position
            let c = cos(referencePortal.angle), s = sin(referencePortal.angle)
            let local = SIMD3<Float>(offset.x * c + offset.y * s, -offset.x * s + offset.y * c, offset.z)
            let destinationCos = cos(destinationPortal.angle), destinationSin = sin(destinationPortal.angle)
            return destinationPortal.position + SIMD3<Float>(
                local.x * destinationCos - local.y * destinationSin,
                local.x * destinationSin + local.y * destinationCos,
                local.z
            )
        }
        startup.updateScene()
        let before = try render(startup, device: device, queue: queue, width: 512, height: 512)
        for _ in 0..<120 {
            startup.updateScene(deltaTime: 0.1)
        }
        for (sourceID, cloneID) in defaultPairs {
            guard let source = startup.object(withID: sourceID), let clone = startup.object(withID: cloneID) else {
                throw Failure(description: "A portal-relative source or clone is missing.")
            }
            var expectedPlacement = source.placement
            expectedPlacement.position = expectedMappedPosition(source.placement.position)
            expectedPlacement.angle = source.placement.angle - referencePortal.angle + destinationPortal.angle
            for column in 0..<4 {
                try expect(simd_distance(expectedPlacement.modelMatrix[column], clone.modelMatrix[column]) < 0.00001,
                           "Clones must map through the bottom portal into the top portal, preserving source scale without drift.")
            }
            startup.updateObject(sourceID) { $0.placement.position.x += 0.1 }
            startup.updateScene()
            let currentSource = startup.object(withID: sourceID)!
            let currentClone = startup.object(withID: cloneID)!
            try expect(simd_distance(expectedMappedPosition(currentSource.placement.position),
                                     currentClone.placement.position) < 0.00001,
                       "Clones must read their original's current position even without a mouse event.")
            startup.updateObject(sourceID) { $0.placement.position = source.placement.position }
            startup.updateScene()
        }
        let after = try render(startup, device: device, queue: queue, width: 512, height: 512)
        try expect(before == after, "Repeated portal-relative updates must produce stable pixels without flickering.")
        print("PASS: shared-mesh clones, independent copies, rejected IDs, GPU duplicates, stable portal mapping")
    }

    @MainActor
    static func checkResolutionUniform(view: MTKView, device: MTLDevice, queue: MTLCommandQueue) throws {
        // Reuse the real vertex shader and Metal uniform layout; only the fragment
        // result changes so GPU readback can observe the supplied resolution.
        let shaderURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Shaders/Shaders.metal")
        let source = try String(contentsOf: shaderURL, encoding: .utf8)
        let probeSource = source
            .replacingOccurrences(of: "fragment float4 object_fragment(", with: "fragment float4 original_object_fragment(")
            .replacingOccurrences(of: "fragment float4 portal_clone_fragment(", with: "fragment float4 original_portal_clone_fragment(")
            + """

            fragment float4 object_fragment(constant ShaderUniforms &u [[buffer(1)]]) {
                return float4(u.resolution / 2048.0, 0.0, 1.0);
            }
            fragment float4 portal_clone_fragment(VertexOut input [[stage_in]], constant ShaderUniforms &u [[buffer(1)]]) {
                return float4(u.resolution / 2048.0, 1.0, 1.0);
            }
            """
        let library = try device.makeLibrary(source: probeSource, options: nil)
        let objects = [
            SceneObjectConfiguration(id: .custom("resolution-object"), geometry: .square,
                                     placement: ObjectPlacement(position: [-0.45, 0, 0], scale: [0.5, 0.5, 1])),
            SceneObjectConfiguration(id: .coneClone, geometry: .square,
                                     placement: ObjectPlacement(position: [0.45, 0, 0], scale: [0.5, 0.5, 1])),
        ]
        let renderer = try Renderer(view: view, library: library, sceneObjects: objects)
        let viewports: [(Int, Int, CGSize?)] = [
            (512, 384, nil), (800, 400, nil), (400, 800, nil),
            (1024, 768, CGSize(width: 512, height: 384)),
        ]
        for (width, height, viewportSize) in viewports {
            let pixels = try render(renderer, device: device, queue: queue,
                                    width: width, height: height, viewportSize: viewportSize)
            let viewport = viewportSize ?? CGSize(width: width, height: height)
            let side = min(viewport.width, viewport.height) - 2 * SceneConfiguration.canvasPadding
            for (index, xPosition): (Int, CGFloat) in [(0, -0.45), (1, 0.45)] {
                let x = Int((viewport.width / 2 + xPosition * side / 2) * CGFloat(width) / viewport.width)
                let pixel = (height / 2 * width + x) * 4
                let expected = [index * 255, Int((Float(height) / 2048 * 255).rounded()),
                                Int((Float(width) / 2048 * 255).rounded()), 255]
                try expect((0..<4).allSatisfy { abs(Int(pixels[pixel + $0]) - expected[$0]) <= 1 },
                           "Both fragment pipelines must receive current drawable pixels, including resize and Retina.")
            }
        }
        print("PASS: drawable resolution in object/portal fragment uniforms, resize, non-square views, Retina")
    }

    static func checkPortalIntersection(device: MTLDevice, queue: MTLCommandQueue) throws {
        let shaderURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Shaders/Shaders.metal")
        let source = try String(contentsOf: shaderURL, encoding: .utf8) + """

            kernel void check_portal_intersections(
                constant float4 *segments [[buffer(0)]], device uint *results [[buffer(1)]],
                uint index [[thread_position_in_grid]]
            ) {
                results[index * 2] = intersectsPortal(segments[index].xy, segments[index].zw, 0.2) ? 1 : 0;
                results[index * 2 + 1] = intersectsPortal(segments[index].xy, segments[index].zw, 0.0) ? 1 : 0;
            }
            """
        let library = try device.makeLibrary(source: source, options: nil)
        guard let function = library.makeFunction(name: "check_portal_intersections") else {
            throw Failure(description: "Could not create the portal intersection probe.")
        }
        let cases: [(SIMD4<Float>, UInt32)] = [
            ([0, -1, 0, 1], 1),       // Through the center.
            ([0, 1, 0, -1], 1),       // Either direction crosses the same opening.
            ([0.2, -1, 0.2, 1], 1),   // The aperture includes both horizontal endpoints.
            ([-0.2, -1, -0.2, 1], 1),
            ([0.21, -1, 0.21, 1], 0), // Crossing outside the opening.
            ([0, 1, 0, 2], 0),        // The infinite line crosses, but the segment does not.
            ([0, -2, 0, -1], 0),
            ([-1, 1, 1, 1], 0),       // Parallel to the portal plane.
            ([-1, 0, 1, 0], 0),       // Collinear is also parallel.
            ([0, -0.0000001, 0, 0.0000001], 0), // Near-parallel guard.
            ([0, 0, 0, 1], 0),        // Strict segment endpoints: t = 0 and t = 1.
            ([0, -1, 0, 0], 0),
        ]
        let segments = cases.map { $0.0 }
        let pipeline = try device.makeComputePipelineState(function: function)
        guard let results = device.makeBuffer(length: cases.count * 2 * MemoryLayout<UInt32>.stride,
                                              options: .storageModeShared),
              let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else {
            throw Failure(description: "Could not allocate the portal intersection probe.")
        }
        encoder.setComputePipelineState(pipeline)
        segments.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: $0.count, index: 0) }
        encoder.setBuffer(results, offset: 0, index: 1)
        encoder.dispatchThreads(MTLSize(width: cases.count, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: cases.count, height: 1, depth: 1))
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        if let error = command.error { throw error }
        try expect(command.status == .completed, "The portal intersection probe did not complete.")
        let actual = results.contents().assumingMemoryBound(to: UInt32.self)
        for (index, fixture) in cases.enumerated() {
            try expect(actual[index * 2] == fixture.1, "Portal intersection case \(index) returned the wrong Boolean.")
            try expect(actual[index * 2 + 1] == 0, "A closed or absent aperture must never intersect a sightline.")
        }
        print("PASS: shared GPU portal predicate — hits, misses, aperture edges, parallel rays, strict endpoints")
    }

    @MainActor
    static func checkPortalMasks(
        view: MTKView, library: MTLLibrary, device: MTLDevice, queue: MTLCommandQueue
    ) throws {
        let shapes: [(SceneObjectID, SceneObjectID, SceneObjectConfiguration.Geometry, SIMD3<Float>)] = [
            (.circle, .circleClone, .circle, [0.8, 0.8, 1]),
            (.cone, .coneClone, .triangle, [1.6, 1.2, 1]),
        ]
        // Full bar widths: missing, each portal alone, both, independently narrowed, closed, mirrored.
        let widths: [(Float?, Float?)] = [
            (nil, nil), (0.24, nil), (nil, 0.24), (0.24, 0.24), (0.04, 0.24), (0, 0), (-0.24, 0.04),
        ]
        let color = SIMD4<Float>(0.3, 0.7, 0.9, 1)
        let foreground = [color.z, color.y, color.x, color.w].map { Int(($0 * 255).rounded()) }
        let background = SceneConfiguration.backgroundColor
        let clear = [background.blue, background.green, background.red, background.alpha]
            .map { Int(($0 * 255).rounded()) }
        let eye = SIMD2<Float>(0, -0.35)
        let size = 512
        let halfCanvas = Float(CGFloat(size) - 2 * SceneConfiguration.canvasPadding) / 2
        for (originalID, cloneID, geometry, scale) in shapes {
            for (caseIndex, widthPair) in widths.enumerated() {
                let portals: [(SceneObjectID, Float, Float?)] = [
                    (.bottomBar, -0.18, widthPair.0), (.topBar, 0.18, widthPair.1),
                ]
                let frames = portals.compactMap { id, x, width -> SceneObjectConfiguration? in
                    guard let width else { return nil }
                    return SceneObjectConfiguration(
                        id: id, geometry: .square,
                        placement: ObjectPlacement(position: [x, 0, 0], scale: [width, 0.04, 1]), color: .zero
                    )
                }
                for isClone in [false, true] {
                    let object = SceneObjectConfiguration(
                        id: isClone ? cloneID : originalID, geometry: geometry,
                        placement: ObjectPlacement(position: [eye.x, eye.y, 0.5], scale: scale), color: color
                    )
                    let renderer = try Renderer(view: view, library: library, sceneObjects: frames + [object])
                    let pixels = try render(renderer, device: device, queue: queue, width: size, height: size)
                    // All four samples are well inside both shapes; the last lies before either portal plane.
                    for sample: SIMD2<Float> in [[-0.25, 0.25], [0.25, 0.25], [0, 0.25], [0, -0.2]] {
                        let x = Int(Float(size) / 2 + sample.x * halfCanvas)
                        let y = Int(Float(size) / 2 - sample.y * halfCanvas)
                        let world = SIMD2<Float>((Float(x) + 0.5 - Float(size) / 2) / halfCanvas,
                                                 (Float(size) / 2 - Float(y) - 0.5) / halfCanvas)
                        let t = -eye.y / (world.y - eye.y)
                        let crossingX = eye.x + t * (world.x - eye.x)
                        let hitsEither = portals.contains { _, center, width in
                            guard let width, abs(width) > 0 else { return false }
                            return t > 0 && t < 1 && abs(crossingX - center) <= abs(width) / 2
                        }
                        let visible = isClone ? hitsEither : !hitsEither
                        let expected = visible ? foreground : clear
                        let pixel = (y * size + x) * 4
                        try expect((0..<4).allSatisfy { abs(Int(pixels[pixel + $0]) - expected[$0]) <= 1 },
                                   "Portal mask mismatch for \(object.id), widths case \(caseIndex), sample \(sample).")
                    }
                }
            }
        }
        print("PASS: original/clone circle and cone masks, either portal, missing portals, independent widths, closed openings")
    }

    @MainActor
    static func checkViewportVision(
        view: MTKView, library: MTLLibrary, device: MTLDevice, queue: MTLCommandQueue
    ) throws {
        // The reference is an infinite wedge, independent of the triangle extension helper.
        // Portal cases express their eye in the portal's local frame.
        let cases: [(Int, Int, CGSize?, SIMD2<Float>, Float, Bool)] = [
            (512, 512, nil, [0, 0], 0, false),
            (800, 400, nil, [-0.6, 0.2], -.pi / 2, false),
            (400, 800, nil, [0.4, -0.5], 0.6, false),
            (1024, 768, CGSize(width: 512, height: 384), [0.2, -0.1], -0.8, false),
            (800, 400, nil, [5, 0], .pi / 2, false),
            (400, 800, nil, [0, -5], 0, false),
            (512, 512, nil, [0, -0.6], 0, true),
            (800, 600, CGSize(width: 400, height: 300), [0, -0.6], 0.45, true),
        ]
        let color = SIMD4<Float>(0.2, 0.5, 0.9, 1)
        let foreground = [color.z, color.y, color.x, color.w].map { Int(($0 * 255).rounded()) }
        let background = SceneConfiguration.backgroundColor
        let clear = [background.blue, background.green, background.red, background.alpha]
            .map { Int(($0 * 255).rounded()) }
        for (width, height, viewportSize, fixtureEye, angle, clipped) in cases {
            let forward = SIMD2<Float>(-sin(angle), cos(angle))
            let right = SIMD2<Float>(cos(angle), sin(angle))
            let portalOrigin = SIMD2<Float>(-0.15, 0.1)
            let eye = clipped ? portalOrigin + right * fixtureEye.x + forward * fixtureEye.y : fixtureEye
            let id: SceneObjectID = clipped ? .coneClone : .custom("unmasked-vision")
            let placement = ObjectPlacement(position: [eye.x, eye.y, 0.5], scale: [1.24, 1, 1], angle: angle)
            var objects = [SceneObjectConfiguration(
                id: id, geometry: .triangle, placement: placement, color: color,
                extendsVisionToViewport: true
            )]
            if clipped {
                // Supply a portal frame without adding visible geometry to the reference image.
                objects.append(SceneObjectConfiguration(
                    id: .topBar, geometry: .square,
                    placement: ObjectPlacement(position: [portalOrigin.x, portalOrigin.y, 0],
                                               scale: [0.4, 0.035, 1], angle: angle), color: .zero
                ))
            }
            let renderer = try Renderer(view: view, library: library, sceneObjects: objects)
            let pixels = try render(renderer, device: device, queue: queue,
                                    width: width, height: height, viewportSize: viewportSize)
            let viewport = viewportSize ?? CGSize(width: width, height: height)
            let size = SIMD2<Float>(Float(viewport.width), Float(viewport.height))
            let side = min(size.x, size.y) - 2 * Float(SceneConfiguration.canvasPadding)
            let unitsPerPixel = 2 / side * max(size.x / Float(width), size.y / Float(height))
            let featherPixels = SceneConfiguration.visionEdgeSoftness * Float(width) / size.x
            let tolerance = (clipped ? max(1.5, featherPixels * sqrt(2) + 1) : 1.5) * unitsPerPixel
            let tanHalfAngle: Float = 0.62
            var edgeCoverage = 0
            var portalRejections = 0
            // Sample the interior and every viewport edge, including the last row/column.
            for y in Array(stride(from: 0, to: height, by: 11)) + [height - 1] {
                for x in Array(stride(from: 0, to: width, by: 11)) + [width - 1] {
                    let world = SIMD2<Float>(
                        (Float(x) + 0.5) * size.x / Float(width) - size.x / 2,
                        size.y / 2 - (Float(y) + 0.5) * size.y / Float(height)
                    ) * (2 / side)
                    let delta = world - eye
                    let along = simd_dot(delta, forward)
                    let lateral = simd_dot(delta, right)
                    let margin = min(along, (tanHalfAngle * along - abs(lateral))
                                     / sqrt(1 + tanHalfAngle * tanHalfAngle))
                    if abs(margin) < tolerance { continue }
                    var visible = margin > 0
                    if clipped && visible {
                        let local = world - portalOrigin
                        let point = SIMD2(simd_dot(local, right), simd_dot(local, forward))
                        let dy = point.y - fixtureEye.y
                        if abs(dy) < 0.000001 { continue }
                        let t = -fixtureEye.y / dy
                        let crossingX = fixtureEye.x + t * (point.x - fixtureEye.x)
                        if abs(point.y) < tolerance || abs(abs(crossingX) - 0.2) < tolerance { continue }
                        visible = t > 0 && t < 1 && abs(crossingX) <= 0.2
                        if !visible { portalRejections += 1 }
                    }
                    let expected = visible ? foreground : clear
                    let index = (y * width + x) * 4
                    try expect((0..<4).allSatisfy { abs(Int(pixels[index + $0]) - expected[$0]) <= 1 },
                               "Viewport vision mismatch at \(width)x\(height), angle \(angle), portal \(clipped), pixel (\(x), \(y)).")
                    if visible && (x == 0 || y == 0 || x == width - 1 || y == height - 1) { edgeCoverage += 1 }
                }
            }
            try expect(edgeCoverage > 0, "Vision must reach the actual viewport edge beyond the padded canvas.")
            try expect(!clipped || portalRejections > 0, "The extended clone must still discard rays outside its portal aperture.")
            try expect(renderer.object(withID: id)?.placement.scale == placement.scale,
                       "Viewport extension must only affect the draw; stored placement scale must not accumulate.")
        }
        print("PASS: viewport-reaching vision, preserved field of view, rotated/offscreen eyes, Retina, portal aperture")
    }

    @MainActor
    static func checkVisionFeathering(
        view: MTKView, library: MTLLibrary, device: MTLDevice, queue: MTLCommandQueue
    ) throws {
        let clearRed = Float(SceneConfiguration.backgroundColor.red * 255)
        func opacity(_ pixels: [UInt8], width: Int, x: Int, y: Int) -> Float {
            (Float(pixels[(y * width + x) * 4 + 2]) - clearRed) / (255 - clearRed)
        }
        let cone = SceneObjectConfiguration(
            id: .cone, geometry: .triangle,
            placement: ObjectPlacement(position: [0, -0.5, 0.5]), color: [1, 1, 1, 1]
        )
        let renderer = try Renderer(view: view, library: library, sceneObjects: [cone])
        let viewports: [(Int, Int, CGSize)] = [
            (512, 512, CGSize(width: 512, height: 512)),
            (1024, 1024, CGSize(width: 512, height: 512)),
            (900, 600, CGSize(width: 900, height: 600)),
            (1800, 1200, CGSize(width: 900, height: 600)),
        ]
        var partialEdge: (Int, Int)?
        for (width, height, viewport) in viewports {
            let pixels = try render(renderer, device: device, queue: queue, width: width, height: height, viewportSize: viewport)
            let backingScale = Float(width) / Float(viewport.width)
            let halfCanvas = Float(min(viewport.width, viewport.height) - 2 * SceneConfiguration.canvasPadding) / 2 * backingScale
            let y = height / 2
            let localY = (Float(height) / 2 - Float(y) - 0.5) / halfCanvas + 0.5
            let edge = Float(width) / 2 + 0.5 * localY * halfCanvas
            // At this horizontal scanline the side's pixel derivatives are 1 and 1/2.
            let fadeWidth = SceneConfiguration.visionEdgeSoftness * backingScale * 1.5
            var partialCount = 0
            for x in Int(floor(edge - fadeWidth)) - 2...Int(ceil(edge)) + 2 {
                let t = min(max((edge - Float(x) - 0.5) / fadeWidth, 0), 1)
                let expected = t * t * (3 - 2 * t)
                let actual = opacity(pixels, width: width, x: x, y: y)
                try expect(abs(actual - expected) < 0.015,
                           "Cone feathering must retain its point width after Retina scaling and viewport resize.")
                if actual > 0.05 && actual < 0.95 { partialCount += 1 }
                if width == 512 && actual > 0.2 && actual < 0.8 { partialEdge = (x, y) }
            }
            try expect(partialCount > 0 && opacity(pixels, width: width, x: width / 2, y: y) > 0.99
                       && opacity(pixels, width: width, x: Int(edge) + 8, y: y) < 0.01,
                       "Cone boundaries must fade while distant interior and exterior pixels remain unchanged.")
        }

        // Compare the two masks away from geometric cone edges, including rotated portals and Retina.
        for (index, viewportCase) in viewports.enumerated() {
            let (width, height, viewport) = viewportCase
            let angle: Float = index < 2 ? 0 : 0.43
            let right = SIMD2<Float>(cos(angle), sin(angle)), forward = SIMD2<Float>(-sin(angle), cos(angle))
            let origin = SIMD2<Float>(-0.1, 0.1), eye = origin - forward * 0.6
            let portal = SceneObjectConfiguration(
                id: .topBar, geometry: .square,
                placement: ObjectPlacement(position: [origin.x, origin.y, 0], scale: [0.4, 0.03, 1], angle: angle), color: .zero
            )
            var masks: [[UInt8]] = []
            for id: SceneObjectID in [.cone, .coneClone] {
                let vision = SceneObjectConfiguration(
                    id: id, geometry: .triangle,
                    placement: ObjectPlacement(position: [eye.x, eye.y, 0.5], scale: [2, 2, 1], angle: angle), color: [1, 1, 1, 1]
                )
                let maskRenderer = try Renderer(view: view, library: library, sceneObjects: [portal, vision])
                masks.append(try render(maskRenderer, device: device, queue: queue, width: width, height: height, viewportSize: viewport))
            }
            let backingScale = Float(width) / Float(viewport.width)
            let halfCanvas = Float(min(viewport.width, viewport.height) - 2 * SceneConfiguration.canvasPadding) / 2 * backingScale
            func pixel(_ local: SIMD2<Float>) -> (Int, Int) {
                let world = origin + right * local.x + forward * local.y
                return (Int(Float(width) / 2 + world.x * halfCanvas), Int(Float(height) / 2 - world.y * halfCanvas))
            }
            let (edgeX, edgeY) = pixel([0.2 * 1.1 / 0.6, 0.5])
            let radius = Int(ceil(SceneConfiguration.visionEdgeSoftness * backingScale * 3)) + 2
            var partialCount = 0
            for y in edgeY - radius...edgeY + radius {
                for x in edgeX - radius...edgeX + radius {
                    let original = opacity(masks[0], width: width, x: x, y: y)
                    let clone = opacity(masks[1], width: width, x: x, y: y)
                    try expect(abs(original + clone - 1) < 0.015,
                               "Original and cloned vision must have complementary soft portal coverage.")
                    if clone > 0.05 && clone < 0.95 { partialCount += 1 }
                }
            }
            for (local, cloneCoverage): (SIMD2<Float>, Float) in [([0, 0.5], 1), ([0.5, 0.5], 0)] {
                let (x, y) = pixel(local)
                try expect(abs(opacity(masks[1], width: width, x: x, y: y) - cloneCoverage) < 0.01,
                           "Portal feathering must preserve coverage far from the aperture boundary.")
            }
            try expect(partialCount > 0, "Portal boundaries must contain intermediate coverage.")
        }

        guard let (edgeX, edgeY) = partialEdge else { throw Failure(description: "No partial cone-edge pixel was found.") }
        let backdrop = SceneObjectConfiguration(
            id: .custom("feather-backdrop"), geometry: .square,
            placement: ObjectPlacement(position: [0, 0, 0.8], scale: [2, 2, 1]), color: [0, 1, 0, 1]
        )
        var previous: [UInt8]?
        for objects in [[cone, backdrop], [backdrop, cone]] {
            let depthRenderer = try Renderer(view: view, library: library, sceneObjects: objects)
            let pixels = try render(depthRenderer, device: device, queue: queue, width: 512, height: 512)
            let index = (edgeY * 512 + edgeX) * 4
            try expect(pixels[index + 1] == 255 && pixels[index + 2] > 10 && pixels[index + 2] < 245,
                       "An alpha-1 vision edge must blend over the opaque backdrop without writing invisible depth.")
            if let previous { try expect(pixels == previous, "Soft vision depth must be independent of scene order.") }
            previous = pixels
        }

        if device.supportsTextureSampleCount(4) {
            let multisampleView = MTKView(frame: .zero, device: device)
            multisampleView.colorPixelFormat = view.colorPixelFormat
            multisampleView.depthStencilPixelFormat = view.depthStencilPixelFormat
            multisampleView.sampleCount = 4
            let hardTriangle = SceneObjectConfiguration(
                id: .custom("msaa-triangle"), geometry: .triangle,
                placement: ObjectPlacement(position: [0, -0.5, 0.3], scale: [0.9, 1.1, 1], angle: 0.37), color: [1, 1, 1, 1]
            )
            for (targetView, samples) in [(view, 1), (multisampleView, 4)] {
                let msaaRenderer = try Renderer(view: targetView, library: library, sceneObjects: [hardTriangle])
                let pixels = try render(msaaRenderer, device: device, queue: queue, width: 512, height: 512, sampleCount: samples)
                let partialCount = stride(from: 2, to: pixels.count, by: 4).filter {
                    Float(pixels[$0]) > clearRed + 1 && pixels[$0] < 254
                }.count
                try expect(samples == 1 ? partialCount == 0 : partialCount > 20,
                           "4x MSAA resolve must add geometric edge coverage without changing the hard 1x shader.")
            }
        }
        print("PASS: soft cone/portal edges, complementary masks, Retina point widths, opaque backdrop visibility, 4x MSAA when supported")
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
        guard let triangleBuffer = triangle.vertexBuffers.first, let triangleFaces = triangle.submeshes.first else {
            throw Failure(description: "The triangle must provide vertex and index buffers.")
        }
        let triangleVertices = triangleBuffer.buffer.contents().advanced(by: triangleBuffer.offset)
            .assumingMemoryBound(to: SIMD2<Float>.self)
        let triangleIndices = triangleFaces.indexBuffer.buffer.contents().advanced(by: triangleFaces.indexBuffer.offset)
            .assumingMemoryBound(to: UInt16.self)
        try expect(triangleVertices[0] == SIMD2<Float>(0, 0)
                   && triangleVertices[1] == SIMD2<Float>(-0.5, 1)
                   && triangleVertices[2] == SIMD2<Float>(0.5, 1),
                   "The baked half-turn must place the tip below the flat edge without moving the triangle's footprint.")
        let lower = simd_min(triangleVertices[0], simd_min(triangleVertices[1], triangleVertices[2]))
        let upper = simd_max(triangleVertices[0], simd_max(triangleVertices[1], triangleVertices[2]))
        try expect(lower == SIMD2<Float>(-0.5, 0) && upper == SIMD2<Float>(0.5, 1)
                   && (lower + upper) / 2 == SIMD2<Float>(0, 0.5),
                   "The flipped mesh must preserve its original bounds and bounds center.")
        let edgeA = triangleVertices[1] - triangleVertices[0]
        let edgeB = triangleVertices[2] - triangleVertices[0]
        try expect(triangleIndices[0] == 0 && triangleIndices[1] == 1 && triangleIndices[2] == 2
                   && edgeA.x * edgeB.y - edgeA.y * edgeB.x < 0,
                   "The baked flip must retain the original indices and clockwise winding.")
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

    @MainActor
    static func checkAlphaCompositing(
        view: MTKView, library: MTLLibrary, device: MTLDevice, queue: MTLCommandQueue
    ) throws {
        let visionColor = SIMD4<Float>(0.8, 0.4, 0.2, 0.25)
        let playerColor = SIMD4<Float>(0.2, 0.7, 1, 1)
        let portalColor = SIMD4<Float>(0.9, 0.7, 0.1, 1)
        let backdropColor = SIMD4<Float>(0.7, 0.2, 0.8, 1)
        let farColor = SIMD4<Float>(0.2, 1, 0.3, 0.4)
        let objects = [
            SceneObjectConfiguration(
                id: .custom("vision"), geometry: .triangle,
                placement: ObjectPlacement(position: [0, -0.6, 0.5], scale: [1.2, 1.2, 1]), color: visionColor
            ),
            SceneObjectConfiguration(
                id: .custom("player"), geometry: .circle,
                placement: ObjectPlacement(position: [-0.15, 0, 0], scale: [0.07, 0.07, 1]), color: playerColor
            ),
            SceneObjectConfiguration(
                id: .custom("portal"), geometry: .square,
                placement: ObjectPlacement(position: [0.22, 0.3, 0.1], scale: [0.15, 0.15, 1]), color: portalColor
            ),
            SceneObjectConfiguration(
                id: .custom("opaque-backdrop"), geometry: .square,
                placement: ObjectPlacement(position: [-0.2, 0.4, 0.9], scale: [0.15, 0.15, 1]), color: backdropColor
            ),
            SceneObjectConfiguration(
                id: .custom("far-tint"), geometry: .square,
                placement: ObjectPlacement(position: [0, 0.1, 0.7], scale: [0.25, 0.25, 1]), color: farColor
            ),
        ]
        let clear = SceneConfiguration.backgroundColor
        let background = SIMD4<Float>(Float(clear.red), Float(clear.green), Float(clear.blue), Float(clear.alpha))
        func over(_ foreground: SIMD4<Float>, _ background: SIMD4<Float>) -> SIMD4<Float> {
            var result = foreground * foreground.w + background * (1 - foreground.w)
            result.w = foreground.w + background.w * (1 - foreground.w)
            return result
        }
        let samples: [(SIMD2<Float>, SIMD4<Float>, String)] = [
            ([0.8, -0.8], background, "untouched background"),
            ([0, 0.45], over(visionColor, background), "vision over background"),
            ([-0.15, 0], playerColor, "opaque foreground player"),
            ([0.22, 0.3], portalColor, "opaque foreground portal"),
            ([-0.2, 0.4], over(visionColor, backdropColor), "vision over opaque backdrop"),
            ([0, 0.1], over(visionColor, over(farColor, background)), "transparent layers back to front"),
        ]
        let orders = [objects, Array(objects.reversed()), Array(objects.dropFirst()) + [objects[0]]]
        var previous: [UInt8]?
        let size = 512
        let halfCanvas = (CGFloat(size) - 2 * SceneConfiguration.canvasPadding) / 2
        for order in orders {
            let renderer = try Renderer(view: view, library: library, sceneObjects: order)
            let pixels = try render(renderer, device: device, queue: queue, width: size, height: size)
            for (position, color, description) in samples {
                let x = Int(CGFloat(size) / 2 + CGFloat(position.x) * halfCanvas)
                let y = Int(CGFloat(size) / 2 - CGFloat(position.y) * halfCanvas)
                let expected = [color.z, color.y, color.x, color.w].map { Int(($0 * 255).rounded()) }
                try expect((0..<4).allSatisfy { abs(Int(pixels[(y * size + x) * 4 + $0]) - expected[$0]) <= 2 },
                           "Incorrect straight-alpha composite for \(description).")
            }
            if let previous {
                try expect(pixels == previous, "Scene order must not change depth-correct alpha compositing.")
            }
            previous = pixels
        }
        print("PASS: straight-alpha vision, readable opaque player/portal, transparent depth order, reordered scenes")
    }

    static func render(
        _ renderer: Renderer, device: MTLDevice, queue: MTLCommandQueue,
        width: Int, height: Int, viewportSize: CGSize? = nil, sampleCount: Int = 1
    ) throws -> [UInt8] {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
        )
        descriptor.usage = [.renderTarget]
        descriptor.storageMode = .private
        guard let color = device.makeTexture(descriptor: descriptor) else {
            throw Failure(description: "Could not allocate the color target.")
        }
        var multisampleColor: MTLTexture?
        if sampleCount > 1 {
            descriptor.textureType = .type2DMultisample
            descriptor.sampleCount = sampleCount
            guard let texture = device.makeTexture(descriptor: descriptor) else {
                throw Failure(description: "Could not allocate the multisample color target.")
            }
            multisampleColor = texture
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
        pass.colorAttachments[0].texture = multisampleColor ?? color
        pass.colorAttachments[0].resolveTexture = multisampleColor == nil ? nil : color
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = multisampleColor == nil ? .store : .multisampleResolve
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
        featheredTriangleIndices: Set<Int> = [],
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
            [SIMD2<Float>(0, 0), SIMD2<Float>(-0.5, 1), SIMD2<Float>(0.5, 1)].map { vertex in
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
        let fadeInset = CGFloat(SceneConfiguration.visionEdgeSoftness) * pixelsPerPointX * sqrt(2) + 1
        for y in 0..<height {
            for x in 0..<width {
                let index = y * width + x
                let isForeground = matches(index, foreground)
                let isBackground = matches(index, clear)
                let pixelCenter = CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)
                // Only named vision triangles gain feathering. fwidth's L1 derivative
                // spans at most sqrt(2) times the perpendicular edge distance.
                let inFadeBand = featheredTriangleIndices.contains { index in
                    triangleContains(pixelCenter, in: triangles[index], inset: -1)
                        && !triangleContains(pixelCenter, in: triangles[index], inset: fadeInset)
                }
                if inFadeBand {
                    let opacity = Float(Int(pixels[index * 4 + 2]) - clear[2]) / Float(foreground[2] - clear[2])
                    try expect(opacity >= -0.01 && opacity <= 1.01 && (0..<4).allSatisfy { channel in
                        let expected = Float(clear[channel]) + Float(foreground[channel] - clear[channel]) * opacity
                        return abs(Float(pixels[index * 4 + channel]) - expected) <= 2
                    }, "Vision edges must contain only the expected alpha blend at \(x),\(y).")
                    continue
                }
                try expect(isForeground || isBackground,
                           "Unexpected shading or corrupted pixel at \(x),\(y).")
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
