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
    private let translucentDepthState: MTLDepthStencilState
    private let camera = Camera()
    private var lastFrameTime: CFTimeInterval?
    private var movementDirection = SIMD2<Float>.zero
    private var lastAimRevision: UInt64 = 0
    private var pendingAimPosition: SIMD2<Float>?

    /// Latest cursor position in scene coordinates, ready to compare with ObjectPlacement.position.
    private(set) var mousePosition: SIMD2<Float>?

    /// Build the default scene and its independent clones once, before the first frame.
    convenience init(view: MTKView, library: MTLLibrary? = nil) throws {
        try self.init(view: view, library: library, sceneObjects: SceneConfiguration.objects)

        let pairs: [(SceneObjectID, SceneObjectID)] = [
            (.circle, .circleClone),
            (.cone, .coneClone),
        ]
        for (sourceID, cloneID) in pairs {
            cloneObject(sourceID, newID: cloneID)
        }
    }

    // A supplied library lets the smoke check exercise this renderer offscreen.
    init(
        view: MTKView,
        library suppliedLibrary: MTLLibrary? = nil,
        sceneObjects: [SceneObjectConfiguration]
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
        let triangleMesh = try TriangleMesh.make(device: device)

        // Share geometry within each shape; every object owns its ID and placement.
        objects = sceneObjects.map { configuration in
            let mesh: MTKMesh
            switch configuration.geometry {
            case .square: mesh = squareMesh
            case .circle: mesh = circleMesh
            case .triangle: mesh = triangleMesh
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
        // All flat meshes use this layout; the pipeline does not belong to one shape.
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
        let colorAttachment = pipeline.colorAttachments[0]!
        colorAttachment.isBlendingEnabled = true
        colorAttachment.sourceRGBBlendFactor = .sourceAlpha
        colorAttachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        colorAttachment.sourceAlphaBlendFactor = .one
        colorAttachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
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
        let translucentDepth = MTLDepthStencilDescriptor()
        translucentDepth.label = "Vision depth test without depth writes"
        translucentDepth.depthCompareFunction = .less
        translucentDepth.isDepthWriteEnabled = false
        guard let translucentState = device.makeDepthStencilState(descriptor: translucentDepth) else {
            throw SetupError.missingDepthState
        }
        translucentDepthState = translucentState
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
            updateInput(from: inputView)
        } else {
            movementDirection = .zero
            mousePosition = nil
            pendingAimPosition = nil
        }
        updateScene(deltaTime: deltaTime)

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

    /// Read native input once per frame. Scene behavior consumes this state below.
    func updateInput(from view: KeyboardMetalView) {
        movementDirection = view.movementDirection
        mousePosition = view.mouseCanvasPosition.map { position in
            position + SIMD2(camera.position.x, camera.position.y)
        }
        if let aimPosition = view.aimCanvasPosition {
            if view.aimRevision != lastAimRevision {
                pendingAimPosition = aimPosition + SIMD2(camera.position.x, camera.position.y)
            }
        } else {
            pendingAimPosition = nil
        }
        lastAimRevision = view.aimRevision
    }

    /// Read an object's current state by name. RenderObject is a value, so this returns a copy.
    func object(withID id: SceneObjectID) -> RenderObject? {
        objects.first { $0.id == id }
    }

    /// Copy an object's current placement and color under a new ID, reusing its GPU mesh.
    @discardableResult
    func cloneObject(_ sourceID: SceneObjectID, newID: SceneObjectID) -> Bool {
        guard let original = object(withID: sourceID),
              object(withID: newID) == nil else { return false }

        objects.append(RenderObject(
            id: newID,
            mesh: original.mesh,
            placement: original.placement,
            color: original.color
        ))
        return true
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
    func updateScene(deltaTime: Float = 0) {
        if simd_length_squared(movementDirection) > 0 {
            // Keep speed consistent diagonally and across frame rates; cap long pauses.
            let step = min(max(deltaTime, 0), 0.1)
            let offset = simd_normalize(movementDirection) * SceneConfiguration.objectMovementSpeed * step
            for id: SceneObjectID in [.cone, .circle] {
                updateObject(id) { object in
                    object.placement.position.x += offset.x
                    object.placement.position.y += offset.y
                }
            }
        }

        // Consume one intentional pointer update. Walking alone keeps the current heading.
        if let aimPosition = pendingAimPosition {
            pendingAimPosition = nil
            updateObject(.cone) { object in
                let position = object.placement.position
                let direction = aimPosition - SIMD2(position.x, position.y)
                let deadZone = SceneConfiguration.lookDeadZoneRadius
                guard simd_length_squared(direction) > deadZone * deadZone else { return }
                // atan2 measures from +X; the mesh's flat edge faces local +Y.
                object.placement.angle = atan2(direction.y, direction.x) - .pi / 2
            }
        }

        guard let portal = object(withID: .bottomBar) else { return }
        // The portal's coordinate frame excludes its visual width and thickness.
        let portalFrame = Transforms.rotation(portal.placement.angle)
            * Transforms.translation(portal.placement.position)
        let inverseFrame = simd_inverse(portalFrame)
        let pairs: [(SceneObjectID, SceneObjectID)] = [
            (.circle, .circleClone), (.cone, .coneClone),
        ]
        for (sourceID, cloneID) in pairs {
            guard let source = object(withID: sourceID) else { continue }
            // World -> portal-local -> world. Always start from the original.
            let relativePosition = SIMD4<Float>(source.placement.position, 1) * inverseFrame
            let worldPosition = relativePosition 

            let direction = SIMD4<Float>(cos(source.placement.angle), sin(source.placement.angle), 0, 0)
            let relativeDirection = direction * inverseFrame
            let worldDirection = relativeDirection * portalFrame

            updateObject(cloneID) { clone in
                clone.placement = ObjectPlacement(
                    position: SIMD3<Float>(worldPosition.x, worldPosition.y, worldPosition.z),
                    scale: source.placement.scale,
                    angle: atan2(worldDirection.y, worldDirection.x)
                )
            }
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

        // Use view points for padding; drawable pixels may be doubled on Retina.
        // Offscreen callers default to one pixel per point unless they supply a viewport.
        let size = viewportSize ?? drawableSize
        let canvasMatrix = Transforms.squareCanvas(
            size: SIMD2(Float(size.width), Float(size.height)),
            padding: Float(SceneConfiguration.canvasPadding)
        )

        // Solid objects establish depth first. Blend translucent fields back to front.
        let opaqueObjects = objects.filter { $0.color.w >= 1 }
        let translucentObjects = objects.filter { $0.color.w < 1 }.sorted {
            $0.placement.position.z > $1.placement.position.z
        }
        for object in opaqueObjects + translucentObjects {
            encoder.setDepthStencilState(object.color.w >= 1 ? depthState : translucentDepthState)
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
