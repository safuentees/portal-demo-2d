import simd

/// A portal's rigid coordinate system and opening, independent of its bar thickness.
struct PortalFrame {
    let localToWorld: simd_float4x4
    let worldToLocal: simd_float4x4
    let halfWidth: Float

    init(placement: ObjectPlacement) {
        localToWorld = Transforms.frame(position: placement.position, angle: placement.angle)
        worldToLocal = simd_inverse(localToWorld)
        // The square mesh spans -0.5...0.5 along its local x axis.
        halfWidth = abs(placement.scale.x) / 2
    }
}

/// The current entrance-to-exit mapping used to display the player copies.
struct PortalPair {
    let entrance: PortalFrame
    let exit: PortalFrame

    var transferMatrix: simd_float4x4 {
        // Row vectors: world -> entrance-local -> exit-world.
        // Keep the current frame-alignment convention; no extra half-turn.
        entrance.worldToLocal * exit.localToWorld
    }

    func mappedPlacement(_ placement: ObjectPlacement) -> ObjectPlacement {
        Transforms.mappedPlacement(placement, through: transferMatrix)
    }
}
