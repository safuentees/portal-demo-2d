import MetalKit

/// GPU geometry paired with the object's editable scene properties.
struct RenderObject {
    let mesh: MTKMesh

    var placement = ObjectPlacement()
    var color = SIMD4<Float>(1, 1, 1, 1)

    var modelMatrix: simd_float4x4 {
        placement.modelMatrix
    }
}
