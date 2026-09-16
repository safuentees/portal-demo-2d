import simd

struct Camera {
    private(set) var position = SIMD3<Float>.zero

    var viewMatrix: simd_float4x4 {
        Transforms.translation(-position)
    }

    mutating func update(direction: SIMD3<Float>, deltaTime: Float) {
        guard simd_length_squared(direction) > 0 else { return }
        // Clamp debugger pauses, and prevent diagonal movement from being faster.
        let step = min(max(deltaTime, 0), 0.1)
        position += simd_normalize(direction) * SceneConfiguration.cameraSpeed * step
    }
}
