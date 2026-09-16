import MetalKit
import ModelIO

/// Shared vertex format for the flat renderer: one float2 position in buffer 0.
enum Mesh2D {
    static func makeVertexDescriptor() -> MDLVertexDescriptor {
        let descriptor = MDLVertexDescriptor()
        descriptor.attributes[0] = MDLVertexAttribute(
            name: MDLVertexAttributePosition,
            format: .float2,
            offset: 0,
            bufferIndex: 0
        )
        descriptor.layouts[0] = MDLVertexBufferLayout(
            stride: MemoryLayout<SIMD2<Float>>.stride
        )
        return descriptor
    }

    static func make(
        device: MTLDevice,
        positions: [SIMD2<Float>],
        indices: [UInt16],
        geometryType: MDLGeometryType
    ) throws -> MTKMesh {
        let allocator = MTKMeshBufferAllocator(device: device)
        let vertexData = positions.withUnsafeBufferPointer { Data(buffer: $0) }
        let indexData = indices.withUnsafeBufferPointer { Data(buffer: $0) }
        let vertexBuffer = allocator.newBuffer(with: vertexData, type: .vertex)
        let indexBuffer = allocator.newBuffer(with: indexData, type: .index)

        let submesh = MDLSubmesh(
            indexBuffer: indexBuffer,
            indexCount: indices.count,
            indexType: .uInt16,
            geometryType: geometryType,
            material: nil
        )
        let mesh = MDLMesh(
            vertexBuffer: vertexBuffer,
            vertexCount: positions.count,
            descriptor: makeVertexDescriptor(),
            submeshes: [submesh]
        )
        return try MTKMesh(mesh: mesh, device: device)
    }
}
