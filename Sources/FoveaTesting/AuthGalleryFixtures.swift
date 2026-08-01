import CoreGraphics
import CryptoKit
import Foundation
import FoveaHTTP
import ImageIO
import UniformTypeIdentifiers

/// 为鉴权隔离验收生成确定性像素与受控源站；不依赖公网或图片压缩器的偶然输出。
enum AuthGalleryFixtures {
    static func makeSolidPNG(red: UInt8) throws -> Data {
        let width = 100
        let height = 50
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            pixels[index] = red
            pixels[index + 1] = 32
            pixels[index + 2] = 64
            pixels[index + 3] = 255
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
            let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )
        else {
            throw AuthGalleryHarnessError.imageGenerationFailed
        }
        let data = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                data,
                UTType.png.identifier as CFString,
                1,
                nil
            )
        else {
            throw AuthGalleryHarnessError.imageGenerationFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw AuthGalleryHarnessError.imageGenerationFailed
        }
        return data as Data
    }

    static func centerRed(_ image: CGImage) throws -> UInt8 {
        var pixel = [UInt8](repeating: 0, count: 4)
        let rendered = pixel.withUnsafeMutableBytes { bytes -> Bool in
            guard let baseAddress = bytes.baseAddress,
                let context = CGContext(
                    data: baseAddress,
                    width: 1,
                    height: 1,
                    bitsPerComponent: 8,
                    bytesPerRow: 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )
            else {
                return false
            }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard rendered else { throw AuthGalleryHarnessError.pixelReadFailed }
        return pixel[0]
    }
}

private enum AuthGalleryHarnessError: Error {
    case imageGenerationFailed
    case pixelReadFailed
}

actor AuthenticatedOrigin: HTTPTransporting {
    nonisolated let reusePolicy = TransportReusePolicy.reusable(
        contextIdentifier: "fovea-testing-authenticated-origin-v1"
    )

    struct Response: Sendable {
        let body: Data
        let headers: [String: String]
        let delayNanoseconds: UInt64

        init(body: Data, headers: [String: String], delayNanoseconds: UInt64 = 0) {
            self.body = body
            self.headers = headers
            self.delayNanoseconds = delayNanoseconds
        }
    }

    struct Metrics: Sendable {
        let requestCount: Int
        let requestsByCredential: [String: Int]
    }

    private let responses: [String: Response]
    private var counts: [String: Int] = [:]

    init(responses: [String: Response]) {
        self.responses = responses
    }

    func execute(_ request: TransportRequest) async throws -> TransportResponse {
        guard let credential = request.request.value(forHTTPHeaderField: "Authorization"),
            let response = responses[credential]
        else {
            throw URLError(.userAuthenticationRequired)
        }
        counts[credential, default: 0] += 1
        if response.delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: response.delayNanoseconds)
        }
        try Task.checkCancellation()
        return TransportResponse(
            head: try TransportResponseHead(
                statusCode: 200,
                headers: response.headers,
                url: request.request.url
            ),
            body: response.body,
            metrics: TransportMetrics(receivedBytes: response.body.count, spilledToDisk: false)
        )
    }

    func metrics() -> Metrics {
        Metrics(requestCount: counts.values.reduce(0, +), requestsByCredential: counts)
    }
}

extension Optional {
    func flatMapAsync<T>(_ transform: (Wrapped) async -> T?) async -> T? {
        guard let self else { return nil }
        return await transform(self)
    }
}
