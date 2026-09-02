import Foundation
import FoveaHTTP
import ImageCraftCore

/// 把一个已经由 multipart parser 验证的完整 JPEG part 解码为目标像素。
package protocol MultipartJPEGFrameDecoding: Sendable {
    func decode(_ part: MultipartJPEGPart) async throws -> DecodedImage
}

/// 复用 Fovea 普通静态图 DecodeStage 的 MJPEG 帧解码器。
///
/// part 不进入 OriginalEncoded 或 RenderedMemory；其内容摘要只用于同一目标/codec 下的
/// single-flight 解码身份。namespace generation 在解码前后都验证，撤销期间完成的像素
/// 不得交付给 live 播放会话。
package struct PipelineMultipartJPEGFrameDecoder: MultipartJPEGFrameDecoding {
    private let decodeStage: DecodeStage
    private let namespaceRegistry: NamespaceRegistry
    private let request: ImageRequest
    package let generation: NamespaceGeneration

    package init(
        decodeStage: DecodeStage,
        namespaceRegistry: NamespaceRegistry,
        request: ImageRequest,
        generation: NamespaceGeneration
    ) {
        self.decodeStage = decodeStage
        self.namespaceRegistry = namespaceRegistry
        self.request = request
        self.generation = generation
    }

    package func decode(_ part: MultipartJPEGPart) async throws -> DecodedImage {
        try Task.checkCancellation()
        guard Self.hasCompleteJPEGMarkers(part.data) else {
            throw PipelineFailure.imageCraft(ImageCraftError.formatMismatch, stage: .probe)
        }
        guard await namespaceRegistry.isActive(generation, for: request.namespace) else {
            throw PipelineFailure.namespaceRevoked
        }
        let contentID = ContentID(data: part.data)
        let image = try await decodeStage.image(
            from: part.data,
            contentID: contentID,
            request: request,
            generation: generation,
            keyDigest: contentID.digestHex
        )
        try Task.checkCancellation()
        guard await namespaceRegistry.isActive(generation, for: request.namespace) else {
            throw PipelineFailure.namespaceRevoked
        }
        return image
    }

    private static func hasCompleteJPEGMarkers(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        return data[data.startIndex] == 0xff
            && data[data.index(after: data.startIndex)] == 0xd8
            && data[data.index(data.endIndex, offsetBy: -2)] == 0xff
            && data[data.index(before: data.endIndex)] == 0xd9
    }

}
