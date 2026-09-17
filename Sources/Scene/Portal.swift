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

    /// Fraction of a movement segment that crosses this opening, from either side.
    func crossingFraction(from before: SIMD3<Float>, to after: SIMD3<Float>) -> Float? {
        guard halfWidth > 0 else { return nil }
        let start = SIMD4<Float>(before, 1) * worldToLocal
        let end = SIMD4<Float>(after, 1) * worldToLocal

        // These sign checks exclude parallel motion and starting on the plane,
        // while accepting movement that ends exactly on it. The divisor cannot be zero.
        let crossedPlane = (start.y > 0 && end.y <= 0) || (start.y < 0 && end.y >= 0)
        guard crossedPlane else { return nil }

        let fraction = start.y / (start.y - end.y)
        let crossingX = start.x + fraction * (end.x - start.x)
        return abs(crossingX) <= halfWidth ? fraction : nil
    }
}

/// One directed mapping, shared by player traversal and the displayed copies.
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

    /// Select the first opening crossed and orient the pair in that travel direction.
    func firstCrossing(from before: SIMD3<Float>, to after: SIMD3<Float>) -> PortalPair? {
        guard entrance.halfWidth > 0, exit.halfWidth > 0 else { return nil }
        let forward = entrance.crossingFraction(from: before, to: after)
        let backward = exit.crossingFraction(from: before, to: after)

        switch (forward, backward) {
        case let (forward?, backward?):
            return forward <= backward ? self : PortalPair(entrance: exit, exit: entrance)
        case (_?, nil):
            return self
        case (nil, _?):
            return PortalPair(entrance: exit, exit: entrance)
        case (nil, nil):
            return nil
        }
    }

    /// Move an exact-plane arrival just beyond the exit to avoid roundoff recrossings.
    /// Apply this same offset to the player's body and vision; ordinary overshoot is preserved.
    func exitClearanceOffset(from before: SIMD3<Float>, to after: SIMD3<Float>) -> SIMD3<Float> {
        let minimumDistance: Float = 0.00001
        let mappedEnd = SIMD4<Float>(after, 1) * transferMatrix * exit.worldToLocal
        let mappedMotion = SIMD4<Float>(after - before, 0) * transferMatrix * exit.worldToLocal
        guard abs(mappedEnd.y) < minimumDistance, mappedMotion.y != 0 else { return .zero }

        let targetY = mappedMotion.y > 0 ? minimumDistance : -minimumDistance
        let localOffset = SIMD4<Float>(0, targetY - mappedEnd.y, 0, 0)
        let worldOffset = localOffset * exit.localToWorld
        return SIMD3(worldOffset.x, worldOffset.y, worldOffset.z)
    }
}
