import MetalKit
import ModelIO

enum SphereMesh {
    static func make(device: MTLDevice) throws -> MTKMesh {
        let allocator = MTKMeshBufferAllocator(device: device)
        let model = MDLMesh(
            sphereWithExtent: SceneConfiguration.sphereExtent,
            segments: SceneConfiguration.sphereSegments,
            inwardNormals: false,
            geometryType: .triangles,
            allocator: allocator
        )

        // Keep all mesh attributes in buffer 0 so buffer 1 is free for uniforms.
        // Normals and UVs are ready for future lighting/texturing experiments.
        let descriptor = MDLVertexDescriptor()
        descriptor.attributes[0] = MDLVertexAttribute(
            name: MDLVertexAttributePosition, format: .float3, offset: 0, bufferIndex: 0
        )
        descriptor.attributes[1] = MDLVertexAttribute(
            name: MDLVertexAttributeNormal, format: .float3, offset: 12, bufferIndex: 0
        )
        descriptor.attributes[2] = MDLVertexAttribute(
            name: MDLVertexAttributeTextureCoordinate, format: .float2, offset: 24, bufferIndex: 0
        )
        descriptor.layouts[0] = MDLVertexBufferLayout(stride: 32)
        model.vertexDescriptor = descriptor
        return try MTKMesh(mesh: model, device: device)
    }
}
