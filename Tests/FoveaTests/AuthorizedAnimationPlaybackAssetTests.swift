import CoreGraphics
import Foundation
import FoveaCore
import FoveaHTTP
import ImageCraftCore
import XCTest

final class AuthorizedAnimationPlaybackAssetTests: XCTestCase {
    func testAuthorizedAssetCreatesNamespaceBoundPlaybackHandle_W5_PT_114() async throws {
        let body = try makePNG(red: 114)
        let request = try makeRequest(path: "authorized-playback")
        let (pipeline, _, _, _) = try await makePipeline(stubs: [
            .init(
                statusCode: 200,
                headers: ["Content-Type": "image/png", "Cache-Control": "no-store"],
                body: body
            )
        ])
        let authorization = try await pipeline.authorizedEncodedData(for: request)
        let provider = AuthorizedAnimationTestProvider(image: makeAuthorizedAnimationImage())
        let asset = try makeAsset(
            authorization: authorization,
            request: request,
            provider: provider
        )
        let runtime = AnimationPlaybackRuntime(frameMemoryCostLimit: 1024 * 1024)

        let handle = try await makeHandle(
            runtime: runtime,
            asset: asset,
            request: request
        )
        let recorder = AuthorizedAnimationOutputRecorder()
        try await handle.start { output in
            await recorder.record(output)
        }
        try await waitUntil("授权动画发布首帧") {
            await recorder.count == 1
        }

        let registeredBeforeCancel = await runtime.registeredDriverCount()
        let framesBeforeCancel = await runtime.currentFrameCount()
        XCTAssertEqual(registeredBeforeCancel, 1)
        XCTAssertEqual(framesBeforeCancel, 1)

        await runtime.cancelAll(namespace: request.namespace)
        let registeredAfterCancel = await runtime.registeredDriverCount()
        let framesAfterCancel = await runtime.currentFrameCount()
        let providerCancelCount = await provider.cancelCount
        XCTAssertEqual(registeredAfterCancel, 0)
        XCTAssertEqual(framesAfterCancel, 0)
        XCTAssertEqual(providerCancelCount, 1)
    }

    func testPreparedAssetKeepsKnownProviderRetainedCostWithoutWholeTrackProof_W5_PT_195()
        throws
    {
        let provider = AuthorizedAnimationTestProvider(image: makeAuthorizedAnimationImage())
        let prepared = PreparedAnimationPlaybackAsset(
            timeline: try makeTimeline(),
            codecFingerprint: "authorized-animation-test-codec-v1",
            provider: provider,
            wholeTrackDecodedByteCostUpperBound: nil,
            wholeTrackProviderRetainedByteCostUpperBound: 32,
            wholeTrackPredecodePeakByteCostUpperBound: nil
        )
        XCTAssertNil(prepared.wholeTrackDecodedByteCostUpperBound)
        XCTAssertEqual(prepared.wholeTrackProviderRetainedByteCostUpperBound, 32)
        XCTAssertNil(prepared.wholeTrackPredecodePeakByteCostUpperBound)
    }

    func testAuthorizedAssetRejectsDifferentFetchBaseIdentity_W5_PT_115() async throws {
        let body = try makePNG(red: 115)
        let request = try makeRequest(path: "authorized-source-a")
        let otherRequest = try makeRequest(path: "authorized-source-b")
        let (pipeline, _, _, _) = try await makePipeline(stubs: [
            .init(
                statusCode: 200,
                headers: ["Content-Type": "image/png", "Cache-Control": "no-store"],
                body: body
            )
        ])
        let authorization = try await pipeline.authorizedEncodedData(for: request)
        let provider = AuthorizedAnimationTestProvider(image: makeAuthorizedAnimationImage())
        let asset = try makeAsset(
            authorization: authorization,
            request: request,
            provider: provider
        )
        let runtime = AnimationPlaybackRuntime(frameMemoryCostLimit: 1024 * 1024)

        await assertInvalidAuthorizedAsset {
            _ = try await self.makeHandle(
                runtime: runtime,
                asset: asset,
                request: otherRequest
            )
        }
        let cancelCount = await provider.cancelCount
        XCTAssertEqual(cancelCount, 1)
    }

    func testAuthorizedAssetRejectsDifferentRequestExecutionIdentity_W5_PT_116() async throws {
        let body = try makePNG(red: 116)
        let url = try XCTUnwrap(URL(string: "https://example.test/encoded/execution-identity"))
        let namespace = SecurityNamespaceID.publicNamespace(appID: "authorized-animation-tests")
        let first = try ImageRequest(
            url: url,
            target: TargetPixels(width: 20, height: 20),
            namespace: namespace,
            headers: ["X-Animation-Mode": "first"]
        )
        let second = try ImageRequest(
            url: url,
            target: TargetPixels(width: 20, height: 20),
            namespace: namespace,
            headers: ["X-Animation-Mode": "second"]
        )
        XCTAssertEqual(first.fetchBaseDigest, second.fetchBaseDigest)
        XCTAssertNotEqual(first.fetchExecutionKey.digestHex, second.fetchExecutionKey.digestHex)
        let (pipeline, _, _, _) = try await makePipeline(stubs: [
            .init(
                statusCode: 200,
                headers: ["Content-Type": "image/png", "Cache-Control": "no-store"],
                body: body
            )
        ])
        let authorization = try await pipeline.authorizedEncodedData(for: first)
        let provider = AuthorizedAnimationTestProvider(image: makeAuthorizedAnimationImage())
        let asset = try makeAsset(
            authorization: authorization,
            request: first,
            provider: provider
        )
        let runtime = AnimationPlaybackRuntime(frameMemoryCostLimit: 1024 * 1024)

        await assertInvalidAuthorizedAsset {
            _ = try await self.makeHandle(
                runtime: runtime,
                asset: asset,
                request: second
            )
        }
        let cancelCount = await provider.cancelCount
        XCTAssertEqual(cancelCount, 1)
    }

    func testAuthorizedAssetRejectsDifferentRenderRequestIdentity_W5_PT_124() async throws {
        let body = try makePNG(red: 124)
        let url = try XCTUnwrap(URL(string: "https://example.test/encoded/render-identity"))
        let namespace = SecurityNamespaceID.publicNamespace(appID: "authorized-animation-tests")
        let first = try ImageRequest(
            url: url,
            target: TargetPixels(width: 20, height: 20),
            namespace: namespace
        )
        let second = try ImageRequest(
            url: url,
            target: TargetPixels(width: 40, height: 40),
            namespace: namespace
        )
        XCTAssertEqual(first.fetchBaseDigest, second.fetchBaseDigest)
        XCTAssertEqual(first.fetchExecutionKey.digestHex, second.fetchExecutionKey.digestHex)
        XCTAssertNotEqual(first.renderAliasIdentity, second.renderAliasIdentity)
        let (pipeline, _, _, _) = try await makePipeline(stubs: [
            .init(
                statusCode: 200,
                headers: ["Content-Type": "image/png", "Cache-Control": "no-store"],
                body: body
            )
        ])
        let authorization = try await pipeline.authorizedEncodedData(for: first)
        let provider = AuthorizedAnimationTestProvider(image: makeAuthorizedAnimationImage())
        let asset = try makeAsset(
            authorization: authorization,
            request: first,
            provider: provider
        )
        let runtime = AnimationPlaybackRuntime(frameMemoryCostLimit: 1024 * 1024)

        await assertInvalidAuthorizedAsset {
            _ = try await self.makeHandle(
                runtime: runtime,
                asset: asset,
                request: second
            )
        }
        let cancelCount = await provider.cancelCount
        XCTAssertEqual(cancelCount, 1)
    }

    func testAuthorizedAssetRejectsInvalidCodecFingerprint_W5_PT_117() async throws {
        let body = try makePNG(red: 117)
        let request = try makeRequest(path: "authorized-invalid-codec")
        let (pipeline, _, _, _) = try await makePipeline(stubs: [
            .init(
                statusCode: 200,
                headers: ["Content-Type": "image/png", "Cache-Control": "no-store"],
                body: body
            )
        ])
        let authorization = try await pipeline.authorizedEncodedData(for: request)
        let provider = AuthorizedAnimationTestProvider(image: makeAuthorizedAnimationImage())
        let asset = AuthorizedAnimationPlaybackAsset(
            authorization: authorization,
            request: request,
            timeline: try makeTimeline(),
            codecFingerprint: "",
            provider: provider
        )
        let runtime = AnimationPlaybackRuntime(frameMemoryCostLimit: 1024 * 1024)

        await assertInvalidAuthorizedAsset {
            _ = try await self.makeHandle(
                runtime: runtime,
                asset: asset,
                request: request
            )
        }
        let cancelCount = await provider.cancelCount
        XCTAssertEqual(cancelCount, 1)
    }

    private func makeRequest(path: String) throws -> ImageRequest {
        try ImageRequest.publicImage(
            url: XCTUnwrap(URL(string: "https://example.test/encoded/\(path)")),
            target: TargetPixels(width: 20, height: 20),
            appID: "authorized-animation-tests"
        )
    }

    private func makeAsset(
        authorization: AuthorizedEncodedData,
        request: ImageRequest,
        provider: any AnimationFrameProvider
    ) throws -> AuthorizedAnimationPlaybackAsset {
        AuthorizedAnimationPlaybackAsset(
            authorization: authorization,
            request: request,
            timeline: try makeTimeline(),
            codecFingerprint: "authorized-animation-test-codec-v1",
            provider: provider
        )
    }

    private func makeTimeline() throws -> AnimationPlaybackTimeline {
        try AnimationPlaybackTimeline(
            frameDurationsNanoseconds: [10],
            additionalRepeatCount: nil,
            zeroDurationReplacementNanoseconds: 1,
            timingPolicyVersion: 1
        )
    }

    private func makeHandle(
        runtime: AnimationPlaybackRuntime,
        asset: AuthorizedAnimationPlaybackAsset,
        request: ImageRequest
    ) async throws -> AnimationPlaybackHandle {
        try await runtime.makeHandle(
            authorizedAsset: asset,
            request: request,
            animationPolicyVersion: 1,
            frameStrategy: .boundedFrameCache,
            playbackPolicy: AnimationPlaybackPolicy(requestedMode: .firstFrame),
            reduceMotionEnabled: false,
            windowPolicy: AnimationFrameWindowPolicy(
                normalFrameCount: 1,
                warningFrameCount: 1
            ),
            clock: AuthorizedAnimationConstantClock()
        )
    }

    private func assertInvalidAuthorizedAsset(
        _ operation: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("错配授权动画资产必须被拒绝", file: file, line: line)
        } catch let error as AnimationPlaybackRuntimeError {
            XCTAssertEqual(error, .invalidAuthorizedAsset, file: file, line: line)
        } catch {
            XCTFail("非预期错误：\(error)", file: file, line: line)
        }
    }
}

private struct AuthorizedAnimationConstantClock: AnimationPlaybackClock {
    func nowNanoseconds() async -> UInt64 { 0 }
    func sleep(untilNanoseconds _: UInt64) async throws { throw CancellationError() }
}

private actor AuthorizedAnimationTestProvider: AnimationFrameProvider {
    private let image: DecodedImage
    private var cancellations = 0

    init(image: DecodedImage) {
        self.image = image
    }

    func frames(in range: Range<Int>) -> [AnimationProviderFrame] {
        range.map { AnimationProviderFrame(index: $0, image: image) }
    }

    func cancel() {
        cancellations += 1
    }

    var cancelCount: Int { cancellations }
}

private actor AuthorizedAnimationOutputRecorder {
    private var outputs: [AnimationPlaybackOutput] = []

    func record(_ output: AnimationPlaybackOutput) {
        outputs.append(output)
    }

    var count: Int { outputs.count }
}

private func makeAuthorizedAnimationImage() -> DecodedImage {
    let width = 4
    let height = 4
    let bytesPerRow = width * 4
    let data = Data(repeating: 0x4a, count: bytesPerRow * height)
    let provider = CGDataProvider(data: data as CFData)!
    let image = CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: bytesPerRow,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    )!
    return DecodedImage(cgImage: image)
}
