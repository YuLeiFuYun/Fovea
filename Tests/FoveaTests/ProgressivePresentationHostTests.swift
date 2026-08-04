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
        private var window: UIWindow?

        override func tearDown() {
            window?.isHidden = true
            window = nil
            ProgressiveFixtureURLProtocol.reset()
            super.tearDown()
        }

        func testChunkedURLSessionPreviewReachesDisplayLinkBeforeFinal_UI_PT_029() async throws {
            let fixture = try BenchmarkFixtureCatalog.load(
                named: "progressive-people-usda-meeting-1920x1280.jpg",
            )
            ProgressiveFixtureURLProtocol.configure(
                data: fixture.data,
                chunkSize: 16 * 1024,
                intervalNanoseconds: 30_000_000,
            )
            let trace = ProgressiveHostTrace()
            let loader = ProgressiveURLSessionLoader(trace: trace)
            let imageView = makeVisibleImageView()
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
            XCTAssertTrue(snapshot.finalEmitted)
            XCTAssertLessThan(previewFrame.elapsedNanoseconds, finalFrame.elapsedNanoseconds)
            XCTAssertEqual(imageIdentifier(imageView.image?.cgImage), finalID)
            XCTAssertEqual(imageView.image?.cgImage?.width, 512)
            XCTAssertEqual(imageView.image?.cgImage?.height, 341)
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
            let trace = ProgressiveHostTrace()
            let barrier = ProgressivePublicationBarrier()
            let firstLoader = ProgressiveURLSessionLoader(
                trace: trace,
                publicationBarrier: barrier,
            )
            let imageView = makeVisibleImageView()
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
        }

        private func makeVisibleImageView() -> FoveaImageView {
            let controller = UIViewController()
            let imageView = FoveaImageView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
            imageView.contentMode = .scaleAspectFit
            controller.view.addSubview(imageView)
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
            window.rootViewController = controller
            window.makeKeyAndVisible()
            self.window = window
            return imageView
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

    private struct ProgressiveDisplayFrame: Sendable {
        let elapsedNanoseconds: UInt64
        let imageID: UInt64
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

    private struct ProgressiveHostTraceSnapshot: Sendable {
        let networkChunkCount: Int
        let previewGeneratedCount: Int
        let previewEmittedCount: Int
        let previewSuppressedCount: Int
        let previewGeneratedImageIDs: [UInt64]
        let previewEmittedImageIDs: [UInt64]
        let finalEmitted: Bool
        let finalEmittedImageID: UInt64?
        let publicationFenceClosed: Bool
    }

    private final class ProgressiveHostTrace: @unchecked Sendable {
        private struct State {
            var networkChunkCount = 0
            var previewGeneratedImageIDs: [UInt64] = []
            var previewEmittedImageIDs: [UInt64] = []
            var previewSuppressedCount = 0
            var finalEmittedImageID: UInt64?
            var publicationFenceClosed = false
        }

        private let originNanoseconds = DispatchTime.now().uptimeNanoseconds
        private let lock = NSLock()
        private var state = State()

        func elapsedNanoseconds() -> UInt64 {
            DispatchTime.now().uptimeNanoseconds &- originNanoseconds
        }

        func recordNetworkChunk() {
            lock.withLock { state.networkChunkCount += 1 }
        }

        func recordPreviewGenerated(_ image: DecodedImage) {
            if let identifier = imageIdentifier(image.cgImage) {
                lock.withLock { state.previewGeneratedImageIDs.append(identifier) }
            }
        }

        func recordPreviewEmitted(_ image: DecodedImage) {
            if let identifier = imageIdentifier(image.cgImage) {
                lock.withLock { state.previewEmittedImageIDs.append(identifier) }
            }
        }

        func recordPreviewSuppressed() {
            lock.withLock { state.previewSuppressedCount += 1 }
        }

        func recordFinalEmitted(_ image: DecodedImage) {
            lock.withLock { state.finalEmittedImageID = imageIdentifier(image.cgImage) }
        }

        func recordPublicationFenceClosed() {
            lock.withLock { state.publicationFenceClosed = true }
        }

        func snapshot() -> ProgressiveHostTraceSnapshot {
            lock.withLock {
                ProgressiveHostTraceSnapshot(
                    networkChunkCount: state.networkChunkCount,
                    previewGeneratedCount: state.previewGeneratedImageIDs.count,
                    previewEmittedCount: state.previewEmittedImageIDs.count,
                    previewSuppressedCount: state.previewSuppressedCount,
                    previewGeneratedImageIDs: state.previewGeneratedImageIDs,
                    previewEmittedImageIDs: state.previewEmittedImageIDs,
                    finalEmitted: state.finalEmittedImageID != nil,
                    finalEmittedImageID: state.finalEmittedImageID,
                    publicationFenceClosed: state.publicationFenceClosed,
                )
            }
        }
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
                guard state.publicationOpen || !state.terminal else { return (nil, nil) }
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
            trace.recordNetworkChunk()
            let shouldDecode = lock.withLock { () -> Bool in
                guard state.publicationOpen, !state.terminal else { return false }
                state.body.append(data)
                return true
            }
            guard shouldDecode else { return }
            do {
                guard let generation = try progressiveSession.append(data) else { return }
                trace.recordPreviewGenerated(generation.image)
                publicationBarrier?.pauseOnce()
                let shouldPublish = lock.withLock { state.publicationOpen && !state.terminal }
                guard shouldPublish else {
                    trace.recordPreviewSuppressed()
                    return
                }
                trace.recordPreviewEmitted(generation.image)
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
