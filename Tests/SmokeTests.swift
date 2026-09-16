import AppKit
import MetalKit
import simd

/// Runs the actual renderer against GPU textures without opening an app window.
@main
struct SmokeTests {
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
        let renderer = try Renderer(view: view, library: library)

        for (width, height) in [(512, 512), (800, 400), (400, 800)] {
            let first = try render(renderer, device: device, queue: queue, width: width, height: height)
            try checkPixels(first, width: width, height: height)
            let second = try render(renderer, device: device, queue: queue, width: width, height: height)
            try expect(first == second, "The resting sphere changed between frames.")
            print("PASS: \(width)x\(height) — solid color, centered circular silhouette, stable frame")
        }
        print("PASS: projection depth, camera movement, uniform layout, and GPU rendering")
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
        try expect(MemoryLayout<ShaderUniforms>.offset(of: \.color) == 192,
                   "Swift/Metal uniform color offset changed.")
    }

    static func render(
        _ renderer: Renderer, device: MTLDevice, queue: MTLCommandQueue, width: Int, height: Int
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
            commandBuffer: command, renderPass: pass, drawableSize: CGSize(width: width, height: height)
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

    static func checkPixels(_ pixels: [UInt8], width: Int, height: Int) throws {
        let color = SceneConfiguration.sphereColor
        let background = SceneConfiguration.backgroundColor
        let foreground = [color.z, color.y, color.x, color.w].map { Int(($0 * 255).rounded()) }
        let clear = [background.blue, background.green, background.red, background.alpha]
            .map { Int(($0 * 255).rounded()) }
        func matches(_ index: Int, _ expected: [Int]) -> Bool {
            (0..<4).allSatisfy { abs(Int(pixels[index * 4 + $0]) - expected[$0]) <= 1 }
        }
        try expect(matches((height / 2) * width + width / 2, foreground), "The center pixel is not the sphere color.")
        var minX = width, minY = height, maxX = -1, maxY = -1, count = 0
        for y in 0..<height {
            for x in 0..<width {
                let index = y * width + x
                if matches(index, foreground) {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                    count += 1
                } else {
                    try expect(matches(index, clear), "Unexpected shading or corrupted pixel at \(x),\(y).")
                }
            }
        }
        try expect(count > width * height / 100 && count < width * height / 2,
                   "The sphere is missing or fills an unexpected part of the view.")
        try expect(abs((maxX - minX) - (maxY - minY)) <= 3, "Resize stretched the sphere.")
        let boxArea = (maxX - minX + 1) * (maxY - minY + 1)
        let coverage = Float(count) / Float(boxArea)
        try expect((0.72...0.84).contains(coverage), "The silhouette is not approximately circular.")
        try expect(abs(minX + maxX - (width - 1)) <= 2 && abs(minY + maxY - (height - 1)) <= 2,
                   "The sphere is not centered.")
    }
}
