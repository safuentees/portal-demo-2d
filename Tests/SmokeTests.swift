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
        let view = MTKView(frame: .zero, device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float
        try checkObjectPlacement(device: device)
        try checkMeshes(device: device)
        let renderer = try Renderer(
            view: view, library: library, squarePlacements: placements, circlePlacements: []
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
            view: view, library: library, squarePlacements: [], circlePlacements: []
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
        try checkCanvasMath()

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
        var object = RenderObject(mesh: mesh, placement: ObjectPlacement(position: [4, -3, 2]))
        object.placement.position = [7, 8, 9]
        object.placement.scale = [1, 0.5, 2]
        let point = SIMD4<Float>(1, -2, 3, 1)
        try expect(point * object.modelMatrix == SIMD4<Float>(8, 7, 15, 1),
                   "Editing an object's position or scale must update its model matrix.")
    }

    static func checkMeshes(device: MTLDevice) throws {
        let square = try SquareMesh.make(device: device)
        let circle = try CircleMesh.make(device: device, segments: 10)
        for mesh in [square, circle] {
            guard let descriptor = MTKMetalVertexDescriptorFromModelIO(mesh.vertexDescriptor) else {
                throw Failure(description: "A 2D mesh has no usable vertex descriptor.")
            }
            try expect(descriptor.attributes[0].format == .float2
                       && descriptor.attributes[0].offset == 0
                       && descriptor.attributes[0].bufferIndex == 0
                       && descriptor.layouts[0].stride == MemoryLayout<SIMD2<Float>>.stride,
                       "Squares and circles must share the packed float2 vertex layout.")
        }
        try expect(square.submeshes.first?.primitiveType == .triangle,
                   "Square geometry must remain triangles.")
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
            view: view, library: library, squarePlacements: squares, circlePlacements: circles
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
        circlePlacements: [ObjectPlacement] = [], viewportSize: CGSize? = nil
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
        func ellipseContains(_ point: CGPoint, in ellipse: CGRect, inset: CGFloat) -> Bool {
            let radiusX = ellipse.width / 2 - inset
            let radiusY = ellipse.height / 2 - inset
            guard radiusX > 0, radiusY > 0 else { return false }
            let x = (point.x - ellipse.midX) / radiusX
            let y = (point.y - ellipse.midY) / radiusY
            return x * x + y * y <= 1
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
                    || ellipses.contains(where: { ellipseContains(pixelCenter, in: $0, inset: 1) }) {
                    try expect(isForeground, "Missing object pixel at \(x),\(y).")
                } else if !bounds.contains(where: { $0.insetBy(dx: -1, dy: -1).contains(pixelCenter) })
                    && !ellipses.contains(where: { ellipseContains(pixelCenter, in: $0, inset: -1) }) {
                    try expect(isBackground, "Object extends beyond its configured bounds at \(x),\(y).")
                }
            }
        }
    }
}
