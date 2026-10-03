import MetalKit

/// GPU geometry paired with the object's editable scene properties.
struct RenderObject {
    let id: SceneObjectID
    let mesh: MTKMesh
    /// Local full width and length; keeps vision feathering and extension aligned with the mesh.
    var coneSize = SIMD2<Float>(repeating: 1)

    var placement = ObjectPlacement()
    var color = SIMD4<Float>(1, 1, 1, 1)
    var extendsVisionToViewport = false

    var modelMatrix: simd_float4x4 {
        placement.modelMatrix
    }
}
