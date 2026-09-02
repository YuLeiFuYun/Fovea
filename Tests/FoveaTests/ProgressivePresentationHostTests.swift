#if canImport(UIKit)
    import Foundation
    import FoveaCore
    import FoveaTesting
    import FoveaUIKit
    import ImageCraftCore
    import ImageCraftImageIO
    import UIKit
    import XCTest

    @MainActor
    final class ProgressivePresentationHostTests: XCTestCase {

        func testChunkedURLSessionPreviewReachesDisplayLinkBeforeFinal_UI_PT_029() async throws {
            let fixture = try BenchmarkFixtureCatalog.load(
                named: "progressive-people-usda-meeting-1920x1280.jpg",
            )
            ProgressiveFixtureURLProtocol.configure(
                data: fixture.data,
                chunkSize: 16 * 1024,
                intervalNanoseconds: 30_000_000,
            )
            defer { ProgressiveFixtureURLProtocol.reset() }
            let trace = ProgressiveHostTrace()
            let loader = ProgressiveURLSessionLoader(trace: trace)
            let host = makeVisibleImageView()
            defer { host.close() }
            let imageView = host.imageView
            let displayLink = ProgressiveDisplayLinkRecorder(imageView: imageView, trace: trace)
            displayLink.start()
            defer { displayLink.stop() }

            try imageView.setImage(
                request: hostRequest(path: "progressive-complete.jpg", width: 512),
                loader: loader,
                accessibility: .decorative,
                placeholderDelayNanoseconds: 0,
            )

            try await waitUntilOnMainActor(
                "display link observes final progressive image",
                timeout: .seconds(8),
                pollInterval: .milliseconds(5),
                condition: {
                    let snapshot = trace.snapshot()
                    guard let finalID = snapshot.finalEmittedImageID else { return false }
                    return displayLink.snapshot().contains { $0.imageID == finalID }
                },
            )

            let snapshot = trace.snapshot()
            let frames = displayLink.snapshot()
            let finalID = try XCTUnwrap(snapshot.finalEmittedImageID)
            let finalFrame = try XCTUnwrap(frames.first { $0.imageID == finalID })
            let previewIDs = Set(snapshot.previewEmittedImageIDs)
            let previewFrame = try XCTUnwrap(
                frames.first { previewIDs.contains($0.imageID) },
            )

            XCTAssertGreaterThanOrEqual(snapshot.networkChunkCount, 20)
            XCTAssertGreaterThanOrEqual(snapshot.previewGeneratedCount, 2)
            XCTAssertEqual(snapshot.previewGeneratedCount, snapshot.previewEmittedCount)
            XCTAssertEqual(snapshot.previewSuppressedCount, 0)
            XCTAssertNotNil(snapshot.finalEmitted)
            XCTAssertLessThan(previewFrame.elapsedNanoseconds, finalFrame.elapsedNanoseconds)
            XCTAssertEqual(imageIdentifier(imageView.image?.cgImage), finalID)
            XCTAssertEqual(imageView.image?.cgImage?.width, 512)
            XCTAssertEqual(imageView.image?.cgImage?.height, 341)
            try emitProgressiveHostEvidence(
                scenario: "complete",
                source: fixture.metadata,
                chunkSizeBytes: 16 * 1024,
                intervalNanoseconds: 30_000_000,
                targetWidth: 512,
                targetHeight: 341,
                trace: snapshot,
                frames: frames,
                replacementStartedElapsedNanoseconds: nil,
            )
        }

        func testIdentityReplacementClosesPublicationFenceBeforeOldPreview_UI_PT_030()
            async throws
        {
            let fixture = try BenchmarkFixtureCatalog.load(
                named: "progressive-people-usda-meeting-1920x1280.jpg",
            )
            ProgressiveFixtureURLProtocol.configure(
                data: fixture.data,
                chunkSize: 32 * 1024,
                intervalNanoseconds: 20_000_000,
            )
            defer { ProgressiveFixtureURLProtocol.reset() }
            let trace = ProgressiveHostTrace()
            let barrier = ProgressivePublicationBarrier()
            let firstLoader = ProgressiveURLSessionLoader(
                trace: trace,
                publicationBarrier: barrier,
            )
            let host = makeVisibleImageView()
            defer { host.close() }
            let imageView = host.imageView
            let displayLink = ProgressiveDisplayLinkRecorder(imageView: imageView, trace: trace)
            displayLink.start()
            defer { displayLink.stop() }

            try imageView.setImage(
                request: hostRequest(path: "progressive-old.jpg", width: 512),
                loader: firstLoader,
                accessibility: .decorative,
                placeholderDelayNanoseconds: 0,
            )
            try await waitUntilOnMainActor(
                "old generation reaches pre-publication barrier",
                timeout: .seconds(5),
                pollInterval: .milliseconds(1),
                condition: {
                    barrier.hasEntered
                },
            )

            let replacement = try ImageIOImageDecoder().decode(
                data: makePNG(width: 64, height: 64),
                target: TargetPixels(width: 64, height: 64),
            )
            try imageView.setImage(
                request: hostRequest(path: "replacement.png", width: 64),
                loader: ImmediateHostImageLoader(image: replacement),
                accessibility: .decorative,
                placeholderDelayNanoseconds: 0,
            )
            try await waitUntilOnMainActor(
                "old stream closes publication fence",
                timeout: .seconds(3),
                pollInterval: .milliseconds(1),
                condition: {
                    trace.snapshot().publicationFenceClosed
                },
            )
            let replacementStarted = trace.elapsedNanoseconds()
            barrier.release()

            try await waitUntilOnMainActor(
                "replacement image becomes visible",
                timeout: .seconds(3),
                pollInterval: .milliseconds(2),
                condition: {
                    imageView.image?.cgImage?.width == 64
                },
            )
            try await waitUntilOnMainActor(
                "old generated preview is suppressed",
                timeout: .seconds(3),
                pollInterval: .milliseconds(2),
                condition: {
                    trace.snapshot().previewSuppressedCount == 1
                },
            )
            try await Task.sleep(nanoseconds: 80_000_000)

            let snapshot = trace.snapshot()
            let oldIDs = Set(snapshot.previewGeneratedImageIDs)
            let framesAfterReplacement = displayLink.snapshot().filter {
                $0.elapsedNanoseconds >= replacementStarted
            }
            XCTAssertEqual(snapshot.previewGeneratedCount, 1)
            XCTAssertEqual(snapshot.previewEmittedCount, 0)
            XCTAssertEqual(snapshot.previewSuppressedCount, 1)
            XCTAssertTrue(snapshot.publicationFenceClosed)
            XCTAssertTrue(
                framesAfterReplacement.allSatisfy { !oldIDs.contains($0.imageID) },
                "旧身份 generation 不得在 publication fence 关闭后进入 UIImageView",
            )
            XCTAssertEqual(imageView.image?.cgImage?.width, 64)
            try emitProgressiveHostEvidence(
                scenario: "identity-replacement",
                source: fixture.metadata,
                chunkSizeBytes: 32 * 1024,
                intervalNanoseconds: 20_000_000,
                targetWidth: 512,
                targetHeight: 341,
                trace: snapshot,
                frames: displayLink.snapshot(),
                replacementStartedElapsedNanoseconds: replacementStarted,
            )
        }

        private func makeVisibleImageView() -> ProgressiveVisibleImageHost {
            ProgressiveVisibleImageHost()
        }
    }

    @MainActor
    private final class ProgressiveVisibleImageHost {
        let imageView: FoveaImageView
        private let window: UIWindow

        init() {
            let controller = UIViewController()
            let imageView = FoveaImageView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
            imageView.contentMode = .scaleAspectFit
            controller.view.addSubview(imageView)
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
            window.rootViewController = controller
            window.makeKeyAndVisible()
            self.imageView = imageView
            self.window = window
        }

        func close() {
            imageView.cancelImageRequest(clearImage: true)
            window.isHidden = true
            window.rootViewController = nil
        }
    }

    private struct ImmediateHostImageLoader: ImageLoading {
        let image: DecodedImage

        func image(for _: ImageRequest) async throws -> DecodedImage {
            image
        }
    }

    private func hostRequest(path: String, width: Int) throws -> ImageRequest {
        try ImageRequest.publicImage(
            url: XCTUnwrap(URL(string: "https://fovea-progressive.test/\(path)")),
            target: TargetPixels(width: width, height: width),
            appID: "progressive-presentation-host-tests",
        )
    }

    private func imageIdentifier(_ image: CGImage?) -> UInt64? {
        image.map {
            UInt64(UInt(bitPattern: Unmanaged.passUnretained($0).toOpaque()))
        }
    }

    private let progressiveHostEvidencePrefix = "FOVEA_PROGRESSIVE_HOST_EVIDENCE_BASE64:"

    private struct ProgressiveDisplayFrame: Sendable {
        let elapsedNanoseconds: UInt64
        let imageID: UInt64
    }

    private struct ProgressiveNetworkTraceEvent: Sendable {
        let index: Int
        let cumulativeByteCount: Int
        let elapsedNanoseconds: UInt64
    }

    private struct ProgressivePreviewTraceEvent: Sendable {
        let generation: UInt32
        let sourceByteCount: Int
        let elapsedNanoseconds: UInt64
        let imageID: UInt64
        let retainedImage: CGImage
    }

    private struct ProgressiveFinalTraceEvent: Sendable {
        let elapsedNanoseconds: UInt64
        let imageID: UInt64
        let retainedImage: CGImage
    }

    private struct ProgressiveHostTraceSnapshot: Sendable {
        let networkChunks: [ProgressiveNetworkTraceEvent]
        let generatedPreviews: [ProgressivePreviewTraceEvent]
        let emittedPreviews: [ProgressivePreviewTraceEvent]
        let suppressedPreviews: [ProgressivePreviewTraceEvent]
        let finalEmitted: ProgressiveFinalTraceEvent?
        let publicationFenceClosedElapsedNanoseconds: UInt64?

        var networkChunkCount: Int { networkChunks.count }
        var previewGeneratedCount: Int { generatedPreviews.count }
        var previewEmittedCount: Int { emittedPreviews.count }
        var previewSuppressedCount: Int { suppressedPreviews.count }
        var previewGeneratedImageIDs: [UInt64] { generatedPreviews.map(\.imageID) }
        var previewEmittedImageIDs: [UInt64] { emittedPreviews.map(\.imageID) }
        var finalEmittedImageID: UInt64? { finalEmitted?.imageID }
        var publicationFenceClosed: Bool {
            publicationFenceClosedElapsedNanoseconds != nil
        }
    }

    private struct ProgressiveHostEvidence: Codable {
        struct Source: Codable {
            let resourceID: String
            let pixelWidth: Int
            let pixelHeight: Int
            let byteCount: Int
            let sha256: String
        }

        struct NetworkChunk: Codable {
            let index: Int
            let cumulativeByteCount: Int
            let elapsedNanoseconds: UInt64
        }

        struct Preview: Codable {
            let generation: UInt32
            let sourceByteCount: Int
            let elapsedNanoseconds: UInt64
        }

        struct DisplayObservation: Codable {
            let elapsedNanoseconds: UInt64
            let kind: String
            let generation: UInt32?
        }

        let schemaVersion: Int
        let scenario: String
        let source: Source
        let chunkSizeBytes: Int
        let intervalNanoseconds: UInt64
        let targetWidth: Int
        let targetHeight: Int
        let networkChunks: [NetworkChunk]
        let generatedPreviews: [Preview]
        let emittedPreviews: [Preview]
        let suppressedPreviews: [Preview]
        let finalEmittedElapsedNanoseconds: UInt64?
        let publicationFenceClosedElapsedNanoseconds: UInt64?
        let displayObservations: [DisplayObservation]
        let previewDisplayedBeforeFinal: Bool?
        let publicationFenceBeforeSuppression: Bool?
        let oldPreviewObservedAfterReplacement: Bool?
    }

    @MainActor
    private final class ProgressiveDisplayLinkRecorder: NSObject {
        private weak var imageView: UIImageView?
        private let trace: ProgressiveHostTrace
        private var displayLink: CADisplayLink?
        private var frames: [ProgressiveDisplayFrame] = []
        private var lastImageID: UInt64?

        init(imageView: UIImageView, trace: ProgressiveHostTrace) {
            self.imageView = imageView
            self.trace = trace
        }

        func start() {
            guard displayLink == nil else { return }
            let link = CADisplayLink(target: self, selector: #selector(tick))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        func stop() {
            displayLink?.invalidate()
            displayLink = nil
        }

        func snapshot() -> [ProgressiveDisplayFrame] {
            frames
        }

        @objc private func tick() {
            guard let identifier = imageIdentifier(imageView?.image?.cgImage),
                identifier != lastImageID
            else { return }
            lastImageID = identifier
            frames.append(
                ProgressiveDisplayFrame(
                    elapsedNanoseconds: trace.elapsedNanoseconds(),
                    imageID: identifier,
                ),
            )
        }
    }

    private final class ProgressivePublicationBarrier: @unchecked Sendable {
        private let lock = NSLock()
        private let releaseSemaphore = DispatchSemaphore(value: 0)
        private var entered = false
        private var consumed = false

        var hasEntered: Bool {
            lock.withLock { entered }
        }

        func pauseOnce() {
            let shouldPause = lock.withLock { () -> Bool in
                guard !consumed else { return false }
                consumed = true
                entered = true
                return true
            }
            if shouldPause {
                releaseSemaphore.wait()
            }
        }

        func release() {
            releaseSemaphore.signal()
        }
    }

    private final class ProgressiveHostTrace: @unchecked Sendable {
        private struct State {
            var networkChunks: [ProgressiveNetworkTraceEvent] = []
            var cumulativeNetworkByteCount = 0
            var generatedPreviews: [ProgressivePreviewTraceEvent] = []
            var emittedPreviews: [ProgressivePreviewTraceEvent] = []
            var suppressedPreviews: [ProgressivePreviewTraceEvent] = []
            var finalEmitted: ProgressiveFinalTraceEvent?
            var publicationFenceClosedElapsedNanoseconds: UInt64?
        }

        private let originNanoseconds = DispatchTime.now().uptimeNanoseconds
        private let lock = NSLock()
        private var state = State()

        func elapsedNanoseconds() -> UInt64 {
            DispatchTime.now().uptimeNanoseconds &- originNanoseconds
        }

        func recordNetworkChunk(byteCount: Int) {
            let elapsed = elapsedNanoseconds()
            lock.withLock {
                state.cumulativeNetworkByteCount += byteCount
                state.networkChunks.append(
                    ProgressiveNetworkTraceEvent(
                        index: state.networkChunks.count,
                        cumulativeByteCount: state.cumulativeNetworkByteCount,
                        elapsedNanoseconds: elapsed,
                    ),
                )
            }
        }

        func recordPreviewGenerated(
            _ image: DecodedImage,
            generation: UInt32,
            sourceByteCount: Int,
        ) {
            recordPreview(
                image,
                generation: generation,
                sourceByteCount: sourceByteCount,
                destination: \.generatedPreviews,
            )
        }

        func recordPreviewEmitted(
            _ image: DecodedImage,
            generation: UInt32,
            sourceByteCount: Int,
        ) {
            recordPreview(
                image,
                generation: generation,
                sourceByteCount: sourceByteCount,
                destination: \.emittedPreviews,
            )
        }

        func recordPreviewSuppressed(
            _ image: DecodedImage,
            generation: UInt32,
            sourceByteCount: Int,
        ) {
            recordPreview(
                image,
                generation: generation,
                sourceByteCount: sourceByteCount,
                destination: \.suppressedPreviews,
            )
        }

        func recordFinalEmitted(_ image: DecodedImage) {
            guard let identifier = imageIdentifier(image.cgImage) else { return }
            let event = ProgressiveFinalTraceEvent(
                elapsedNanoseconds: elapsedNanoseconds(),
                imageID: identifier,
                retainedImage: image.cgImage,
            )
            lock.withLock { state.finalEmitted = event }
        }

        func recordPublicationFenceClosed() {
            let elapsed = elapsedNanoseconds()
            lock.withLock {
                if state.publicationFenceClosedElapsedNanoseconds == nil {
                    state.publicationFenceClosedElapsedNanoseconds = elapsed
                }
            }
        }

        func snapshot() -> ProgressiveHostTraceSnapshot {
            lock.withLock {
                ProgressiveHostTraceSnapshot(
                    networkChunks: state.networkChunks,
                    generatedPreviews: state.generatedPreviews,
                    emittedPreviews: state.emittedPreviews,
                    suppressedPreviews: state.suppressedPreviews,
                    finalEmitted: state.finalEmitted,
                    publicationFenceClosedElapsedNanoseconds:
                        state.publicationFenceClosedElapsedNanoseconds,
                )
            }
        }

        private func recordPreview(
            _ image: DecodedImage,
            generation: UInt32,
            sourceByteCount: Int,
            destination: WritableKeyPath<State, [ProgressivePreviewTraceEvent]>,
        ) {
            guard let identifier = imageIdentifier(image.cgImage) else { return }
            let event = ProgressivePreviewTraceEvent(
                generation: generation,
                sourceByteCount: sourceByteCount,
                elapsedNanoseconds: elapsedNanoseconds(),
                imageID: identifier,
                retainedImage: image.cgImage,
            )
            lock.withLock { state[keyPath: destination].append(event) }
        }
    }

    private func emitProgressiveHostEvidence(
        scenario: String,
        source: BenchmarkSourceDescriptor,
        chunkSizeBytes: Int,
        intervalNanoseconds: UInt64,
        targetWidth: Int,
        targetHeight: Int,
        trace: ProgressiveHostTraceSnapshot,
        frames: [ProgressiveDisplayFrame],
        replacementStartedElapsedNanoseconds: UInt64?,
    ) throws {
        let previewsByImageID = Dictionary(
            uniqueKeysWithValues: trace.emittedPreviews.map { ($0.imageID, $0.generation) },
        )
        let observations = frames.map { frame -> ProgressiveHostEvidence.DisplayObservation in
            if let generation = previewsByImageID[frame.imageID] {
                return .init(
                    elapsedNanoseconds: frame.elapsedNanoseconds,
                    kind: "preview",
                    generation: generation,
                )
            }
            if frame.imageID == trace.finalEmitted?.imageID {
                return .init(
                    elapsedNanoseconds: frame.elapsedNanoseconds,
                    kind: "final",
                    generation: nil,
                )
            }
            return .init(
                elapsedNanoseconds: frame.elapsedNanoseconds,
                kind: "other",
                generation: nil,
            )
        }
        let firstPreviewDisplay = observations.first { $0.kind == "preview" }
        let finalDisplay = observations.first { $0.kind == "final" }
        let oldIDs = Set(trace.generatedPreviews.map(\.imageID))
        let oldObservedAfterReplacement = replacementStartedElapsedNanoseconds.map { started in
            frames.contains { frame in
                frame.elapsedNanoseconds >= started && oldIDs.contains(frame.imageID)
            }
        }
        let fenceBeforeSuppression: Bool? = {
            guard let fence = trace.publicationFenceClosedElapsedNanoseconds,
                let suppression = trace.suppressedPreviews.first?.elapsedNanoseconds
            else { return nil }
            return fence <= suppression
        }()
        let evidence = ProgressiveHostEvidence(
            schemaVersion: 1,
            scenario: scenario,
            source: .init(
                resourceID: source.resourceID,
                pixelWidth: source.pixelWidth,
                pixelHeight: source.pixelHeight,
                byteCount: source.byteCount,
                sha256: source.sha256,
            ),
            chunkSizeBytes: chunkSizeBytes,
            intervalNanoseconds: intervalNanoseconds,
            targetWidth: targetWidth,
            targetHeight: targetHeight,
            networkChunks: trace.networkChunks.map {
                .init(
                    index: $0.index,
                    cumulativeByteCount: $0.cumulativeByteCount,
                    elapsedNanoseconds: $0.elapsedNanoseconds,
                )
            },
            generatedPreviews: trace.generatedPreviews.map(stablePreview),
            emittedPreviews: trace.emittedPreviews.map(stablePreview),
            suppressedPreviews: trace.suppressedPreviews.map(stablePreview),
            finalEmittedElapsedNanoseconds: trace.finalEmitted?.elapsedNanoseconds,
            publicationFenceClosedElapsedNanoseconds:
                trace.publicationFenceClosedElapsedNanoseconds,
            displayObservations: observations,
            previewDisplayedBeforeFinal: {
                guard let preview = firstPreviewDisplay, let final = finalDisplay else {
                    return nil
                }
                return preview.elapsedNanoseconds < final.elapsedNanoseconds
            }(),
            publicationFenceBeforeSuppression: fenceBeforeSuppression,
            oldPreviewObservedAfterReplacement: oldObservedAfterReplacement,
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let encoded = try encoder.encode(evidence)
        print(progressiveHostEvidencePrefix + encoded.base64EncodedString())
    }

    private func stablePreview(
        _ event: ProgressivePreviewTraceEvent,
    ) -> ProgressiveHostEvidence.Preview {
        .init(
            generation: event.generation,
            sourceByteCount: event.sourceByteCount,
            elapsedNanoseconds: event.elapsedNanoseconds,
        )
    }

    private final class ProgressiveURLSessionLoader: ProgressiveImageLoading, @unchecked Sendable {
        private let trace: ProgressiveHostTrace
        private let publicationBarrier: ProgressivePublicationBarrier?

        init(
            trace: ProgressiveHostTrace,
            publicationBarrier: ProgressivePublicationBarrier? = nil,
        ) {
            self.trace = trace
            self.publicationBarrier = publicationBarrier
        }

        func events(
            for request: ImageRequest,
        ) -> AsyncThrowingStream<ImageLoadingEvent, any Error> {
            AsyncThrowingStream { continuation in
                do {
                    let transfer = try ProgressiveURLSessionTransfer(
                        request: request,
                        continuation: continuation,
                        trace: trace,
                        publicationBarrier: publicationBarrier,
                    )
                    continuation.onTermination = { @Sendable _ in transfer.cancel() }
                    transfer.start()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private final class ProgressiveURLSessionTransfer: NSObject, URLSessionDataDelegate,
        URLSessionTaskDelegate, @unchecked Sendable
    {
        private struct State {
            var body = Data()
            var publicationOpen = true
            var terminal = false
            weak var task: URLSessionDataTask?
        }

        private let request: ImageRequest
        private let continuation: AsyncThrowingStream<ImageLoadingEvent, any Error>.Continuation
        private let trace: ProgressiveHostTrace
        private let publicationBarrier: ProgressivePublicationBarrier?
        private let decoder = ImageIOImageDecoder()
        private let progressiveSession: any ImageProgressiveDecodeSession
        private let decodeRequest: ImageDecodeRequest
        private let limits: DecodeLimits
        private let lock = NSLock()
        private var state = State()
        private var urlSession: URLSession?

        init(
            request: ImageRequest,
            continuation: AsyncThrowingStream<ImageLoadingEvent, any Error>.Continuation,
            trace: ProgressiveHostTrace,
            publicationBarrier: ProgressivePublicationBarrier?,
        ) throws {
            self.request = request
            self.continuation = continuation
            self.trace = trace
            self.publicationBarrier = publicationBarrier
            decodeRequest = ImageDecodeRequest(
                target: request.target,
                contentMode: request.contentMode,
                colorPolicy: request.colorPolicy,
            )
            limits = DecodeLimits(
                maximumEncodedBytes: 2 * 1024 * 1024,
                maximumDimension: 8192,
                maximumPixelCount: 40_000_000,
                maximumFrameCount: 1,
                maximumMetadataBytes: 2 * 1024 * 1024,
                maximumAuxiliaryAttachments: 0,
                allowedFormats: [.jpeg],
            )
            progressiveSession = try decoder.makeProgressiveSession(
                format: .jpeg,
                request: decodeRequest,
                limits: limits,
            )
            super.init()
        }

        func start() {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ProgressiveFixtureURLProtocol.self]
            configuration.urlCache = nil
            let queue = OperationQueue()
            queue.name = "dev.fovea.progressive-host-url-session"
            queue.maxConcurrentOperationCount = 1
            let session = URLSession(
                configuration: configuration, delegate: self, delegateQueue: queue)
            let task = session.dataTask(with: request.url)
            lock.withLock {
                urlSession = session
                state.task = task
            }
            task.resume()
        }

        func cancel() {
            let taskAndSession = lock.withLock { () -> (URLSessionDataTask?, URLSession?) in
                guard state.publicationOpen, !state.terminal else { return (nil, nil) }
                state.publicationOpen = false
                trace.recordPublicationFenceClosed()
                return (state.task, urlSession)
            }
            taskAndSession.0?.cancel()
            progressiveSession.cancel()
            finish(throwing: CancellationError())
            taskAndSession.1?.invalidateAndCancel()
        }

        func urlSession(
            _: URLSession,
            dataTask _: URLSessionDataTask,
            didReceive response: URLResponse,
            completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void,
        ) {
            guard let http = response as? HTTPURLResponse,
                http.statusCode == 200,
                http.mimeType?.lowercased() == "image/jpeg"
            else {
                completionHandler(.cancel)
                finish(throwing: URLError(.badServerResponse))
                return
            }
            completionHandler(.allow)
        }

        func urlSession(
            _: URLSession,
            dataTask _: URLSessionDataTask,
            didReceive data: Data,
        ) {
            trace.recordNetworkChunk(byteCount: data.count)
            let shouldDecode = lock.withLock { () -> Bool in
                guard state.publicationOpen, !state.terminal else { return false }
                state.body.append(data)
                return true
            }
            guard shouldDecode else { return }
            do {
                guard let generation = try progressiveSession.append(data) else { return }
                trace.recordPreviewGenerated(
                    generation.image,
                    generation: generation.generation,
                    sourceByteCount: generation.sourceByteCount,
                )
                publicationBarrier?.pauseOnce()
                let shouldPublish = lock.withLock { state.publicationOpen && !state.terminal }
                guard shouldPublish else {
                    trace.recordPreviewSuppressed(
                        generation.image,
                        generation: generation.generation,
                        sourceByteCount: generation.sourceByteCount,
                    )
                    return
                }
                trace.recordPreviewEmitted(
                    generation.image,
                    generation: generation.generation,
                    sourceByteCount: generation.sourceByteCount,
                )
                let quality = UInt16(min(UInt32(UInt16.max - 1), generation.generation))
                if case .terminated = continuation.yield(
                    .preview(generation.image, quality: quality),
                ) {
                    cancel()
                }
            } catch let error as ImageCraftError where error == .progressiveSessionCancelled {
                finish(throwing: CancellationError())
            } catch {
                finish(throwing: error)
            }
        }

        func urlSession(
            _: URLSession,
            task _: URLSessionTask,
            didCompleteWithError error: (any Error)?,
        ) {
            if let error {
                if (error as? URLError)?.code == .cancelled {
                    finish(throwing: CancellationError())
                } else {
                    finish(throwing: error)
                }
                return
            }
            do {
                let body = lock.withLock { state.body }
                try progressiveSession.finish()
                let final = try decoder.decode(
                    data: body,
                    request: decodeRequest,
                    limits: limits,
                )
                let shouldPublish = lock.withLock { state.publicationOpen && !state.terminal }
                guard shouldPublish else {
                    finish(throwing: CancellationError())
                    return
                }
                trace.recordFinalEmitted(final)
                _ = continuation.yield(.final(final))
                finish(throwing: nil)
            } catch {
                finish(throwing: error)
            }
        }

        private func finish(throwing error: (any Error)?) {
            let shouldFinish = lock.withLock { () -> Bool in
                guard !state.terminal else { return false }
                state.terminal = true
                return true
            }
            guard shouldFinish else { return }
            if let error {
                continuation.finish(throwing: error)
            } else {
                continuation.finish()
            }
            urlSession?.finishTasksAndInvalidate()
        }
    }

    private final class ProgressiveFixtureURLProtocol: URLProtocol {
        private struct Configuration: Sendable {
            let data: Data
            let chunkSize: Int
            let intervalNanoseconds: UInt64
        }

        private static let configurationLock = NSLock()
        private nonisolated(unsafe) static var configured: Configuration?

        private let stateLock = NSLock()
        private var stopped = false
        private var operation: Task<Void, Never>?

        static func configure(data: Data, chunkSize: Int, intervalNanoseconds: UInt64) {
            configurationLock.withLock {
                configured = Configuration(
                    data: data,
                    chunkSize: chunkSize,
                    intervalNanoseconds: intervalNanoseconds,
                )
            }
        }

        static func reset() {
            configurationLock.withLock { configured = nil }
        }

        override class func canInit(with request: URLRequest) -> Bool {
            request.url?.host == "fovea-progressive.test"
        }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest {
            request
        }

        override func startLoading() {
            guard let configuration = Self.configurationLock.withLock({ Self.configured }) else {
                client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
                return
            }
            let reference = UncheckedReference(value: self)
            let task = Task { @concurrent in
                await reference.value.serve(configuration)
            }
            stateLock.withLock { operation = task }
        }

        override func stopLoading() {
            let task = stateLock.withLock { () -> Task<Void, Never>? in
                stopped = true
                let task = operation
                operation = nil
                return task
            }
            task?.cancel()
        }

        private func serve(_ configuration: Configuration) async {
            guard let url = request.url,
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: [
                        "Content-Type": "image/jpeg",
                        "Content-Length": String(configuration.data.count),
                        "Cache-Control": "no-store",
                    ],
                )
            else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            guard !isStopped else { return }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            var offset = 0
            while offset < configuration.data.count {
                if Task.isCancelled || isStopped {
                    return
                }
                let end = min(configuration.data.count, offset + configuration.chunkSize)
                client?.urlProtocol(
                    self,
                    didLoad: configuration.data.subdata(in: offset..<end),
                )
                offset = end
                if offset < configuration.data.count {
                    do {
                        try await Task.sleep(nanoseconds: configuration.intervalNanoseconds)
                    } catch {
                        return
                    }
                }
            }
            guard !isStopped else { return }
            client?.urlProtocolDidFinishLoading(self)
        }

        private var isStopped: Bool {
            stateLock.withLock { stopped }
        }
    }

    private struct UncheckedReference<Value>: @unchecked Sendable {
        let value: Value
    }
#endif
