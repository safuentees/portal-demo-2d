import MetalKit
import QuartzCore
import simd

final class Renderer: NSObject, MTKViewDelegate {
    private enum SetupError: LocalizedError {
        case missingDevice, missingCommandQueue, missingLibrary
        case missingShaders, invalidVertexDescriptor, missingDepthState

        var errorDescription: String? {
            switch self {
            case .missingDevice: return "No Metal device is available."
            case .missingCommandQueue: return "Metal could not create a command queue."
            case .missingLibrary: return "default.metallib is missing. Check Shaders.metal target membership."
            case .missingShaders: return "The sphere vertex or fragment function is missing."
            case .invalidVertexDescriptor: return "The sphere vertex layout could not be converted to Metal."
            case .missingDepthState: return "Metal could not create the depth state."
            }
        }
    }

    private let commandQueue: MTLCommandQueue
    private let mesh: MTKMesh
    private let pipelineState: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private var camera = Camera()
    private var lastFrameTime: CFTimeInterval?

    // A supplied library lets the smoke check exercise this renderer offscreen.
    init(view: MTKView, library suppliedLibrary: MTLLibrary? = nil) throws {
        guard let device = view.device else { throw SetupError.missingDevice }
        guard let queue = device.makeCommandQueue() else { throw SetupError.missingCommandQueue }
        commandQueue = queue
        mesh = try SphereMesh.make(device: device)

        // Xcode compiles Sources/Shaders/Shaders.metal into default.metallib.
        guard let library = suppliedLibrary ?? device.makeDefaultLibrary() else {
            throw SetupError.missingLibrary
        }
        guard let vertex = library.makeFunction(name: "sphere_vertex"),
              let fragment = library.makeFunction(name: "sphere_fragment") else {
            throw SetupError.missingShaders
        }
        guard let vertexDescriptor = MTKMetalVertexDescriptorFromModelIO(mesh.vertexDescriptor) else {
            throw SetupError.invalidVertexDescriptor
        }
        vertexDescriptor.layouts[0].stepFunction = .perVertex
        vertexDescriptor.layouts[0].stepRate = 1

        let pipeline = MTLRenderPipelineDescriptor()
        pipeline.label = "Solid sphere pipeline"
        pipeline.vertexFunction = vertex
        pipeline.fragmentFunction = fragment
        pipeline.vertexDescriptor = vertexDescriptor
        pipeline.colorAttachments[0].pixelFormat = view.colorPixelFormat
        pipeline.depthAttachmentPixelFormat = view.depthStencilPixelFormat
        pipeline.rasterSampleCount = view.sampleCount
        pipelineState = try device.makeRenderPipelineState(descriptor: pipeline)

        let depth = MTLDepthStencilDescriptor()
        depth.label = "Sphere depth test"
        depth.depthCompareFunction = .less
        depth.isDepthWriteEnabled = true
        guard let state = device.makeDepthStencilState(descriptor: depth) else {
            throw SetupError.missingDepthState
        }
        depthState = state
        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // The projection is rebuilt using drawableSize every frame.
    }

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let deltaTime = Float(now - (lastFrameTime ?? now))
        lastFrameTime = now
        if let keyboardView = view as? KeyboardMetalView {
            camera.update(direction: keyboardView.movementDirection, deltaTime: deltaTime)
        }

        guard view.drawableSize.width > 0, view.drawableSize.height > 0,
              let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        commandBuffer.label = "Sphere frame"
        guard encodeFrame(
            commandBuffer: commandBuffer,
            renderPass: pass,
            drawableSize: view.drawableSize
        ) else { return }
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// Encode the scene into a view drawable or an offscreen texture.
    @discardableResult
    func encodeFrame(
        commandBuffer: MTLCommandBuffer,
        renderPass: MTLRenderPassDescriptor,
        drawableSize: CGSize
    ) -> Bool {
        guard drawableSize.width > 0, drawableSize.height > 0,
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass) else {
            return false
        }

        var uniforms = ShaderUniforms(
            modelMatrix: Transforms.translation(SceneConfiguration.spherePosition),
            viewMatrix: camera.viewMatrix,
            projectionMatrix: Transforms.perspective(
                aspect: Float(drawableSize.width / drawableSize.height),
                fieldOfView: SceneConfiguration.fieldOfViewRadians,
                near: SceneConfiguration.nearPlane,
                far: SceneConfiguration.farPlane
            ),
            color: SceneConfiguration.sphereColor
        )

        encoder.label = "Draw solid sphere"
        encoder.setRenderPipelineState(pipelineState)
        encoder.setDepthStencilState(depthState)
        for (index, buffer) in mesh.vertexBuffers.enumerated() {
            encoder.setVertexBuffer(buffer.buffer, offset: buffer.offset, index: index)
        }
        // Small per-frame values are copied by Metal; no shared-buffer sync needed.
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<ShaderUniforms>.stride, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ShaderUniforms>.stride, index: 1)

        for submesh in mesh.submeshes {
            encoder.drawIndexedPrimitives(
                type: submesh.primitiveType,
                indexCount: submesh.indexCount,
                indexType: submesh.indexType,
                indexBuffer: submesh.indexBuffer.buffer,
                indexBufferOffset: submesh.indexBuffer.offset
            )
        }
        encoder.endEncoding()
        return true
    }
}
