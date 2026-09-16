import MetalKit
import QuartzCore
import simd

final class Renderer: NSObject, MTKViewDelegate {
    private enum SetupError: LocalizedError {
        case missingDevice, missingCommandQueue, missingLibrary
        case missingShaders, invalidVertexDescriptor, missingDepthState
        case duplicateObjectID(SceneObjectID)

        var errorDescription: String? {
            switch self {
            case .missingDevice: return "No Metal device is available."
            case .missingCommandQueue: return "Metal could not create a command queue."
            case .missingLibrary: return "default.metallib is missing. Check Shaders.metal target membership."
            case .missingShaders: return "The vertex or fragment function is missing."
            case .invalidVertexDescriptor: return "The mesh vertex layout could not be converted to Metal."
            case .missingDepthState: return "Metal could not create the depth state."
            case .duplicateObjectID(let id): return "Scene object IDs must be unique. Duplicate: \(id)."
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
        sceneObjects: [SceneObjectConfiguration] = SceneConfiguration.objects
    ) throws {
        var identifiers = Set<SceneObjectID>()
        for object in sceneObjects {
            guard identifiers.insert(object.id).inserted else {
                throw SetupError.duplicateObjectID(object.id)
            }
        }

        guard let device = view.device else { throw SetupError.missingDevice }
        guard let queue = device.makeCommandQueue() else { throw SetupError.missingCommandQueue }
        commandQueue = queue

        let squareMesh = try SquareMesh.make(device: device)
        let circleMesh = try CircleMesh.make(device: device)

        // Share geometry within each shape; every object owns its ID and placement.
        objects = sceneObjects.map { configuration in
            let mesh: MTKMesh
            switch configuration.geometry {
            case .square: mesh = squareMesh
            case .circle: mesh = circleMesh
            }
            return RenderObject(
                id: configuration.id,
                mesh: mesh,
                placement: configuration.placement,
                color: configuration.color
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
        updateScene()

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

    /// Read an object's current state by name. RenderObject is a value, so this returns a copy.
    func object(withID id: SceneObjectID) -> RenderObject? {
        objects.first { $0.id == id }
    }

    /// Edit an object by name and save it back to the scene.
    @discardableResult
    func updateObject(_ id: SceneObjectID, _ update: (inout RenderObject) -> Void) -> Bool {
        guard let index = objects.firstIndex(where: { $0.id == id }) else { return false }
        // Work on a copy so the closure can also read other objects in the scene.
        var object = objects[index]
        update(&object)
        objects[index] = object
        return true
    }

    /// Scene behavior belongs here, after input is read and before the GPU draws it.
    func updateScene() {
        guard let mousePosition else { return }
        updateObject(.circle) { object in
            object.placement.position.x = mousePosition.x
            object.placement.position.y = mousePosition.y
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
