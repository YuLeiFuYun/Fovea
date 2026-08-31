import AppKit
import CoreGraphics
import CryptoKit
import Foundation

@MainActor
package func measure(
    count: Int,
    operation: @MainActor () async throws -> Void
) async throws -> [UInt64] {
    var samples: [UInt64] = []
    samples.reserveCapacity(count)
    for _ in 0..<count {
        let start = DispatchTime.now().uptimeNanoseconds
        try await operation()
        samples.append(DispatchTime.now().uptimeNanoseconds &- start)
    }
    return samples
}

package func timing(_ samples: [UInt64]) -> TimingReport {
    let sorted = samples.sorted()
    let median = sorted[sorted.count / 2]
    let p95 = sorted[min(sorted.count - 1, Int(ceil(Double(sorted.count) * 0.95)) - 1)]
    return TimingReport(
        medianNanoseconds: median,
        p95Nanoseconds: p95,
        samplesNanoseconds: samples
    )
}

package func platformCGImage(_ image: NSImage) throws -> CGImage {
    if let underlying = image.cgImage { return underlying }
    var rect = CGRect(origin: .zero, size: image.size)
    guard let rendered = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
        throw LabError.frameUnavailable
    }
    return rendered
}

package func normalizedRGBA(_ image: CGImage) throws -> Data {
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
        throw LabError.pixelMaterializationFailed
    }
    let rowBytes = image.width.multipliedReportingOverflow(by: 4)
    let total = rowBytes.partialValue.multipliedReportingOverflow(by: image.height)
    guard !rowBytes.overflow, !total.overflow else {
        throw LabError.pixelMaterializationFailed
    }
    var pixels = Data(count: total.partialValue)
    let rendered = pixels.withUnsafeMutableBytes { raw -> Bool in
        guard let address = raw.baseAddress,
            let context = CGContext(
                data: address,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: rowBytes.partialValue,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue
            )
        else { return false }
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return true
    }
    guard rendered else { throw LabError.pixelMaterializationFailed }
    return pixels
}


package func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
