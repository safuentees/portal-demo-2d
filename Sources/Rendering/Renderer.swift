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
            case .missingShaders: return "The vertex or fragment function is missing."
            case .invalidVertexDescriptor: return "The mesh vertex layout could not be converted to Metal."
            case .missingDepthState: return "Metal could not create the depth state."
            }
        }
    }

    private var objects: [RenderObject] = []
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private var camera = Camera()
    private var lastFrameTime: CFTimeInterval?

    /// Latest cursor position in scene coordinates, ready to compare with ObjectPlacement.position.
    private(set) var mousePosition: SIMD2<Float>?

    // A supplied library lets the smoke check exercise this renderer offscreen.
    init(
        view: MTKView,
        library suppliedLibrary: MTLLibrary? = nil,
        squarePlacements: [ObjectPlacement] = SceneConfiguration.squares,
        circlePlacements: [ObjectPlacement] = [SceneConfiguration.circlePlacement]
    ) throws {
        guard let device = view.device else { throw SetupError.missingDevice }
        guard let queue = device.makeCommandQueue() else { throw SetupError.missingCommandQueue }
        commandQueue = queue

        let squareMesh = try SquareMesh.make(device: device)
        // Share geometry within each shape; every object owns its placement.
        objects = squarePlacements.map { placement in
            RenderObject(mesh: squareMesh, placement: placement, color: SceneConfiguration.objectColor)
        }

        let circleMesh = try CircleMesh.make(device: device)
        objects += circlePlacements.map { placement in
            RenderObject(
                mesh: circleMesh,
                placement: placement,
                color: SceneConfiguration.objectColor
            )
        }

        // Xcode compiles Sources/Shaders/Shaders.metal into default.metallib.
        guard let library = suppliedLibrary ?? device.makeDefaultLibrary() else {
            throw SetupError.missingLibrary
        }
        guard let vertex = library.makeFunction(name: "object_vertex"),
              let fragment = library.makeFunction(name: "object_fragment") else {
            throw SetupError.missingShaders
        }
        // Both meshes are built with this exact layout; the pipeline does not belong to either shape.
        guard let vertexDescriptor = MTKMetalVertexDescriptorFromModelIO(Mesh2D.makeVertexDescriptor()) else {
            throw SetupError.invalidVertexDescriptor
        }
        vertexDescriptor.layouts[0].stepFunction = .perVertex
        vertexDescriptor.layouts[0].stepRate = 1

        let pipeline = MTLRenderPipelineDescriptor()
        pipeline.label = "Solid object pipeline"
        pipeline.vertexFunction = vertex
        pipeline.fragmentFunction = fragment
        pipeline.vertexDescriptor = vertexDescriptor
        pipeline.colorAttachments[0].pixelFormat = view.colorPixelFormat
        pipeline.depthAttachmentPixelFormat = view.depthStencilPixelFormat
        pipeline.rasterSampleCount = view.sampleCount
        pipelineState = try device.makeRenderPipelineState(descriptor: pipeline)

        let depth = MTLDepthStencilDescriptor()
        depth.label = "Object depth test"
        depth.depthCompareFunction = .less
        depth.isDepthWriteEnabled = true
        guard let state = device.makeDepthStencilState(descriptor: depth) else {
            throw SetupError.missingDepthState
        }
        depthState = state
        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // The canvas transform is rebuilt using the view bounds every frame.
    }

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let deltaTime = Float(now - (lastFrameTime ?? now))
        lastFrameTime = now
        if let inputView = view as? KeyboardMetalView {
            updateInput(from: inputView, deltaTime: deltaTime)
        } else {
            mousePosition = nil
        }

        guard view.drawableSize.width > 0, view.drawableSize.height > 0,
              let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        commandBuffer.label = "Scene frame"
        guard encodeFrame(
            commandBuffer: commandBuffer,
            renderPass: pass,
            drawableSize: view.drawableSize,
            viewportSize: view.bounds.size
        ) else { return }
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// Read native input once per frame, including camera movement under a stationary cursor.
    func updateInput(from view: KeyboardMetalView, deltaTime: Float) {
        camera.update(direction: view.movementDirection, deltaTime: deltaTime)
        mousePosition = view.mouseCanvasPosition.map { position in
            position + SIMD2(camera.position.x, camera.position.y)
        }
    }

    /// Encode the scene into a view drawable or an offscreen texture.
    @discardableResult
    func encodeFrame(
        commandBuffer: MTLCommandBuffer,
        renderPass: MTLRenderPassDescriptor,
        drawableSize: CGSize,
        viewportSize: CGSize? = nil
    ) -> Bool {
        guard drawableSize.width > 0, drawableSize.height > 0,
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass) else {
            return false
        }

        encoder.label = "Draw all objects"
        encoder.setRenderPipelineState(pipelineState)
        encoder.setDepthStencilState(depthState)

        // Use view points for padding; drawable pixels may be doubled on Retina.
        // Offscreen callers default to one pixel per point unless they supply a viewport.
        let size = viewportSize ?? drawableSize
        let canvasMatrix = Transforms.squareCanvas(
            size: SIMD2(Float(size.width), Float(size.height)),
            padding: Float(SceneConfiguration.canvasPadding)
        )

        for object in objects {
            // 1. Select this object's geometry.
            let vertexBuffer = object.mesh.vertexBuffers[0]

            encoder.setVertexBuffer(
                vertexBuffer.buffer,
                offset: vertexBuffer.offset,
                index: 0
            )

            // 2. Supply this object's transform and color.
            var uniforms = ShaderUniforms(
                modelMatrix: object.modelMatrix,
                viewMatrix: camera.viewMatrix,
                canvasMatrix: canvasMatrix,
                color: object.color
            )

            encoder.setVertexBytes(
                &uniforms,
                length: MemoryLayout<ShaderUniforms>.stride,
                index: 1
            )
            encoder.setFragmentBytes(
                &uniforms,
                length: MemoryLayout<ShaderUniforms>.stride,
                index: 1
            )

            // 3. Draw every section of this mesh.
            for submesh in object.mesh.submeshes {
                encoder.drawIndexedPrimitives(
                    type: submesh.primitiveType,
                    indexCount: submesh.indexCount,
                    indexType: submesh.indexType,
                    indexBuffer: submesh.indexBuffer.buffer,
                    indexBufferOffset: submesh.indexBuffer.offset
                )
            }
        }

        encoder.endEncoding()
        return true
    }
}
