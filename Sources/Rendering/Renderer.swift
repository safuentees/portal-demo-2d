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

    private static let portalClonePairs: [(source: SceneObjectID, clone: SceneObjectID)] = [
        (.circle, .circleClone),
        (.cone, .coneClone),
    ]

    private var objects: [RenderObject] = []
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private let portalPipelineState: MTLRenderPipelineState
    private let portalClonePipelineState: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private let translucentDepthState: MTLDepthStencilState
    private let camera = Camera()
    private var lastFrameTime: CFTimeInterval?
    private var movementDirection = SIMD2<Float>.zero
    private var rotationDirection: Float = 0

    /// WASD axes follow portal crossings and persist between key presses, independent of Q/E.
    private var movementControlAngle: Float = 0

    /// Latest cursor position in scene coordinates, ready to compare with ObjectPlacement.position.
    private(set) var mousePosition: SIMD2<Float>?

    /// Build the default scene and its independent clones once, before the first frame.
    convenience init(view: MTKView, library: MTLLibrary? = nil) throws {
        try self.init(view: view, library: library, sceneObjects: SceneConfiguration.objects)

        for (sourceID, cloneID) in Self.portalClonePairs {
            cloneObject(sourceID, newID: cloneID)
            updateObject(cloneID) { clone in
                clone.color = cloneID == .coneClone
                    ? SceneConfiguration.portalVisionColor
                    : SceneConfiguration.cloneColor
            }
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
                color: configuration.color,
                extendsVisionToViewport: configuration.extendsVisionToViewport
            )
        }

        // Xcode compiles Sources/Shaders/Shaders.metal into default.metallib.
        guard let library = suppliedLibrary ?? device.makeDefaultLibrary() else {
            throw SetupError.missingLibrary
        }
        guard let vertex = library.makeFunction(name: "object_vertex"),
              let fragment = library.makeFunction(name: "object_fragment"),
              let portalFragment = library.makeFunction(name: "portal_fragment"),
              let portalCloneFragment = library.makeFunction(name: "portal_clone_fragment") else {
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

        pipeline.label = "Portal clone pipeline"
        pipeline.fragmentFunction = portalCloneFragment
        portalClonePipelineState = try device.makeRenderPipelineState(descriptor: pipeline)

        pipeline.label = "Portal original pipeline"
        pipeline.fragmentFunction = portalFragment
        portalPipelineState = try device.makeRenderPipelineState(descriptor: pipeline)

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
            rotationDirection = 0
            mousePosition = nil
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
        rotationDirection = view.rotationDirection
        mousePosition = view.mouseCanvasPosition.map { position in
            position + SIMD2(camera.position.x, camera.position.y)
        }
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
            color: original.color,
            extendsVisionToViewport: original.extendsVisionToViewport
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

    /// Scene behavior runs after input is read and before the GPU draws it.
    func updateScene(deltaTime: Float = 0) {
        movePlayer(deltaTime: deltaTime)
        rotatePlayer(deltaTime: deltaTime)
        updatePortalClones()
    }

    private func movePlayer(deltaTime: Float) {
        guard simd_length_squared(movementDirection) > 0 else { return }
        // Keep speed consistent diagonally and across frame rates; cap long pauses.
        let step = min(max(deltaTime, 0), 0.1)
        guard step > 0 else { return }
        let offset = simd_normalize(movementDirection) * SceneConfiguration.objectMovementSpeed * step
        let worldOffset = SIMD4<Float>(offset.x, offset.y, 0, 0) * Transforms.rotation(movementControlAngle)
        let displacement = SIMD3<Float>(worldOffset.x, worldOffset.y, 0)

        // The body's center decides the crossing once for both body and vision.
        guard let player = object(withID: .circle) ?? object(withID: .cone) else { return }
        let before = player.placement.position
        let after = before + displacement
        let crossedPair = currentPortalPair()?.firstCrossing(from: before, to: after)
        let exitOffset = crossedPair?.exitClearanceOffset(from: before, to: after) ?? .zero

        for id: SceneObjectID in [.circle, .cone] {
            updateObject(id) { object in
                var placement = object.placement
                placement.position += displacement
                if let crossedPair {
                    // Map the proposed placement, including its heading and movement past the opening.
                    placement = crossedPair.mappedPlacement(placement)
                    placement.position += exitOffset
                    // In this flat scene z controls drawing order, not physical travel.
                    placement.position.z = object.placement.position.z
                }
                object.placement = placement
            }
        }

        if let crossedPair {
            // Rotate the controls once per crossing so held keys continue along the exit motion.
            // This frame's displacement was already mapped with the player's placement above.
            movementControlAngle = Transforms.mappedAngle(movementControlAngle, through: crossedPair.transferMatrix)
        }
    }

    private func rotatePlayer(deltaTime: Float) {
        guard rotationDirection != 0 else { return }
        let step = min(max(deltaTime, 0), 0.1)
        let angle = rotationDirection * SceneConfiguration.objectRotationSpeed * step
        updateObject(.cone) { object in
            object.placement.angle += angle
        }
    }

    private func portalFrame(for id: SceneObjectID) -> PortalFrame? {
        object(withID: id).map { PortalFrame(placement: $0.placement) }
    }

    private func currentPortalPair() -> PortalPair? {
        guard let entrance = portalFrame(for: .bottomBar),
              let exit = portalFrame(for: .topBar) else { return nil }
        return PortalPair(entrance: entrance, exit: exit)
    }

    private func updatePortalClones() {
        guard let pair = currentPortalPair() else { return }
        for (sourceID, cloneID) in Self.portalClonePairs {
            guard let source = object(withID: sourceID) else { continue }
            // Always map the original so repeated updates cannot accumulate drift.
            updateObject(cloneID) { clone in
                clone.placement = pair.mappedPlacement(source.placement)
            }
        }
    }

    private func pipeline(for id: SceneObjectID) -> MTLRenderPipelineState {
        switch id {
        case .circle, .cone:
            return portalPipelineState
        case .circleClone, .coneClone:
            return portalClonePipelineState
        default:
            return pipelineState
        }
    }

    private func hasSoftVisionEdges(_ object: RenderObject) -> Bool {
        SceneConfiguration.visionEdgeSoftness > 0 && (object.id == .cone || object.id == .coneClone)
    }

    private func isTranslucent(_ object: RenderObject) -> Bool {
        // Feathered edges have partial alpha even when the object's base color is opaque.
        object.color.w < 1 || hasSoftVisionEdges(object)
    }

    /// Viewport extension changes only the draw, not the object's stored placement.
    private func drawPlacement(for object: RenderObject, viewportSize: SIMD2<Float>) -> ObjectPlacement {
        var placement = object.placement
        if object.extendsVisionToViewport {
            placement.scale = Transforms.visionScaleToCoverViewport(
                scale: placement.scale,
                eyePosition: SIMD2(placement.position.x - camera.position.x,
                                   placement.position.y - camera.position.y),
                angle: placement.angle,
                viewportSize: viewportSize,
                padding: Float(SceneConfiguration.canvasPadding)
            )
        }
        return placement
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

        // Use view points for padding; drawable pixels may be doubled on Retina.
        // Offscreen callers default to one pixel per point unless they supply a viewport.
        let size = viewportSize ?? drawableSize
        let canvasMatrix = Transforms.squareCanvas(
            size: SIMD2(Float(size.width), Float(size.height)),
            padding: Float(SceneConfiguration.canvasPadding)
        )

        // Resolve each rigid frame once per frame, outside the object loop.
        let entrance = portalFrame(for: .bottomBar)
        let exit = portalFrame(for: .topBar)
        let worldToEntrance = entrance?.worldToLocal ?? matrix_identity_float4x4
        let worldToExit = exit?.worldToLocal ?? matrix_identity_float4x4
        let portalHalfWidths = SIMD2<Float>(entrance?.halfWidth ?? 0, exit?.halfWidth ?? 0)
        let viewportDimensions = SIMD2<Float>(Float(size.width), Float(size.height))
        let resolution = SIMD2<Float>(Float(drawableSize.width), Float(drawableSize.height))
        // Derivatives in the shader measure drawable pixels; settings use view points.
        let featherPixels = max(SceneConfiguration.visionEdgeSoftness, 0)
            * resolution.x / max(viewportDimensions.x, 1)

        // Solid objects establish depth first. Blend translucent fields back to front.
        let opaqueObjects = objects.filter { !isTranslucent($0) }
        let translucentObjects = objects.filter { isTranslucent($0) }.sorted {
            $0.placement.position.z > $1.placement.position.z
        }
        for object in opaqueObjects + translucentObjects {
            encoder.setRenderPipelineState(pipeline(for: object.id))
            encoder.setDepthStencilState(isTranslucent(object) ? translucentDepthState : depthState)
            // 1. Select this object's geometry.
            let vertexBuffer = object.mesh.vertexBuffers[0]

            encoder.setVertexBuffer(
                vertexBuffer.buffer,
                offset: vertexBuffer.offset,
                index: 0
            )

            // 2. Supply this object's transform, color, and portal-local eye positions.
            let placement = drawPlacement(for: object, viewportSize: viewportDimensions)
            let eye = SIMD4<Float>(object.placement.position, 1)
            var uniforms = ShaderUniforms(
                modelMatrix: placement.modelMatrix,
                viewMatrix: camera.viewMatrix,
                canvasMatrix: canvasMatrix,
                color: object.color,
                worldToEntrance: worldToEntrance,
                eyeInEntrance: eye * worldToEntrance,
                worldToExit: worldToExit,
                eyeInExit: eye * worldToExit,
                resolution: resolution,
                portalHalfWidths: portalHalfWidths,
                visionFeatherPixels: hasSoftVisionEdges(object) ? featherPixels : 0
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
