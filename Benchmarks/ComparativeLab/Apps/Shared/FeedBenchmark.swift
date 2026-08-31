import ComparativeLabCore
import UIKit

@MainActor
private final class FeedBenchmarkCell: UICollectionViewCell {
    static let reuseIdentifier = "FeedBenchmarkCell"

    let imageView = UIImageView()
    private(set) var token = UUID()
    private var load: ComparatorLoad?
    private var requestID: String?
    private var ownerBackingMetadata: W1FootprintBackingMetadata?
    var loaderTask: Task<Void, Never>?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .secondarySystemBackground
        contentView.layer.cornerRadius = 12
        contentView.clipsToBounds = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        contentView.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: contentView.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func prepareForReuse() {
        super.prepareForReuse()
        cancel()
        token = UUID()
        imageView.image = nil
        ownerBackingMetadata = nil
    }

    func install(load: ComparatorLoad, requestID: String) {
        self.load = load
        self.requestID = requestID
    }

    func installRenderedImage(
        _ image: ComparatorRenderImage,
        captureOwnerMetadata: Bool
    ) {
        let cgImage = image.cgImage
        if captureOwnerMetadata {
            let (byteCount, overflow) = cgImage.bytesPerRow.multipliedReportingOverflow(
                by: cgImage.height
            )
            ownerBackingMetadata = W1FootprintBackingMetadata(
                imageIdentity: ObjectIdentifier(cgImage),
                providerIdentity: cgImage.dataProvider.map(ObjectIdentifier.init),
                pixelWidth: cgImage.width,
                pixelHeight: cgImage.height,
                bytesPerRow: cgImage.bytesPerRow,
                estimatedByteCount: overflow ? Int.max : max(0, byteCount)
            )
        } else {
            ownerBackingMetadata = nil
        }
        imageView.image = UIImage(cgImage: cgImage)
    }

    func ownerBackingMetadataForAttribution() -> W1FootprintBackingMetadata? {
        ownerBackingMetadata
    }

    func releaseBackingForOwnerAttribution() -> Bool {
        let hadBacking = ownerBackingMetadata != nil || imageView.image != nil
        imageView.image = nil
        ownerBackingMetadata = nil
        return hadBacking
    }

    func cancel() {
        if let requestID {
            DeterministicBenchmarkURLProtocol.markCancellation(requestID: requestID)
        }
        load?.cancel()
        loaderTask?.cancel()
        load = nil
        loaderTask = nil
        requestID = nil
    }
}

@MainActor
private final class WeakFeedBenchmarkCell {
    weak var value: FeedBenchmarkCell?

    init(_ value: FeedBenchmarkCell) {
        self.value = value
    }
}

@MainActor
final class FeedBenchmarkViewController: UIViewController, UICollectionViewDataSource,
    UICollectionViewDelegateFlowLayout
{
    private let adapter: any ComparatorAdapter
    private let catalog: ResourceCatalog
    private let timeScale: Double
    private let runIndex: Int
    private let accumulator = ObservationAccumulator()
    private var tasks: [Task<Void, Never>] = []
    private var lateResultsRejected = 0
    private var isStopping = false
    private var ownerAttribution: W1FootprintOwnerAttributionRecorder?
    private var ownerCells: [WeakFeedBenchmarkCell] = []
    private lazy var collectionView: UICollectionView = {
        let layout = UICollectionViewFlowLayout()
        layout.minimumLineSpacing = 8
        layout.sectionInset = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        let view = UICollectionView(frame: .zero, collectionViewLayout: layout)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.dataSource = self
        view.delegate = self
        view.prefetchDataSource = nil
        view.backgroundColor = .systemBackground
        view.register(
            FeedBenchmarkCell.self, forCellWithReuseIdentifier: FeedBenchmarkCell.reuseIdentifier)
        return view
    }()

    init(adapter: any ComparatorAdapter, catalog: ResourceCatalog, timeScale: Double, runIndex: Int)
    {
        self.adapter = adapter
        self.catalog = catalog
        self.timeScale = timeScale
        self.runIndex = runIndex
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    func execute() async throws -> WorkloadResult {
        if let intervention = try W1FootprintOwnerIntervention.requestedFromEnvironment() {
            ownerAttribution = W1FootprintOwnerAttributionRecorder(intervention: intervention)
            try ownerAttribution?.recordPhase("post-cache-preparation-baseline")
        }

        loadViewIfNeeded()
        collectionView.reloadData()
        collectionView.layoutIfNeeded()
        let started = DispatchTime.now().uptimeNanoseconds
        let driver = ScrollTraceDriver(collectionView: collectionView, timeScale: timeScale)
        try ownerAttribution?.recordPhase("scroll-start")
        NSLog("FOVEA_STAGE=scroll-start")
        await driver.run()
        NSLog("FOVEA_STAGE=scroll-finished")
        try ownerAttribution?.recordPhase("scroll-finished")
        isStopping = true
        if ownerAttribution != nil {
            try ownerAttribution?.recordPhase("cancel-all-start")
            NSLog("FOVEA_STAGE=cancel-all-start")
            cancelOwnerLoadsWithoutAdapterTeardown()
            NSLog("FOVEA_STAGE=cancel-all-finished")
            try ownerAttribution?.recordPhase("cancel-all-finished")
        } else {
            for case let cell as FeedBenchmarkCell in collectionView.visibleCells { cell.cancel() }
            NSLog("FOVEA_STAGE=cancel-all-start")
            await adapter.cancelAll()
            NSLog("FOVEA_STAGE=cancel-all-finished")
        }
        for task in tasks { await task.value }
        NSLog("FOVEA_STAGE=loads-drained")
        try ownerAttribution?.recordPhase("loads-drained")
        let snapshot = await accumulator.snapshot()
        let duration = DispatchTime.now().uptimeNanoseconds &- started

        if let ownerAttribution {
            let visibleCells = collectionView.visibleCells.compactMap { $0 as? FeedBenchmarkCell }
            let visibleBackings = visibleCells.compactMap {
                $0.ownerBackingMetadataForAttribution()
            }
            try await ownerAttribution.runIntervention(
                adapter: adapter,
                visibleCellCount: visibleCells.count,
                visibleBackings: visibleBackings,
                releaseUIBackings: { [weak self] in
                    self?.releaseOwnerBackings() ?? 0
                }
            )
        }

        return WorkloadResult(
            observations: snapshot.observations,
            checks: [
                BenchmarkCheck(
                    identifier: "no-late-result-overwrite",
                    passed: true,
                    value: lateResultsRejected
                ),
                BenchmarkCheck(
                    identifier: "no-crash-or-hang",
                    passed: true,
                    value: 0
                ),
                BenchmarkCheck(
                    identifier: "target-pixel-box",
                    passed: snapshot.targetPixelViolationCount == 0,
                    value: snapshot.targetPixelViolationCount
                ),
                BenchmarkCheck(
                    identifier: "failed-load-count-zero",
                    passed: snapshot.failed == 0,
                    value: snapshot.failed
                ),
            ],
            durationNanoseconds: duration,
            decodedMegapixels: snapshot.decodedMegapixels,
            completedLoads: snapshot.completed,
            cancelledLoads: snapshot.cancelled,
            failedLoads: snapshot.failed
        )
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int)
        -> Int
    {
        1_000
    }

    func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: FeedBenchmarkCell.reuseIdentifier,
            for: indexPath
        )
        if ownerAttribution != nil, let feedCell = cell as? FeedBenchmarkCell {
            registerOwnerCell(feedCell)
        }
        return cell
    }

    func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> CGSize {
        CGSize(width: max(1, collectionView.bounds.width - 16), height: 180)
    }

    func collectionView(
        _ collectionView: UICollectionView,
        willDisplay cell: UICollectionViewCell,
        forItemAt indexPath: IndexPath
    ) {
        guard let cell = cell as? FeedBenchmarkCell else { return }
        startLoad(cell: cell, logicalIndex: indexPath.item)
    }

    func collectionView(
        _ collectionView: UICollectionView,
        didEndDisplaying cell: UICollectionViewCell,
        forItemAt indexPath: IndexPath
    ) {
        (cell as? FeedBenchmarkCell)?.cancel()
    }

    private func registerOwnerCell(_ cell: FeedBenchmarkCell) {
        ownerCells.removeAll { $0.value == nil }
        guard !ownerCells.contains(where: { $0.value === cell }) else { return }
        ownerCells.append(WeakFeedBenchmarkCell(cell))
    }

    private func cancelOwnerLoadsWithoutAdapterTeardown() {
        ownerCells.removeAll { $0.value == nil }
        for reference in ownerCells {
            reference.value?.cancel()
        }
        for task in tasks {
            task.cancel()
        }
    }

    private func releaseOwnerBackings() -> Int {
        ownerCells.removeAll { $0.value == nil }
        var released = 0
        for reference in ownerCells {
            if reference.value?.releaseBackingForOwnerAttribution() == true {
                released += 1
            }
        }
        return released
    }

    private func startLoad(cell: FeedBenchmarkCell, logicalIndex: Int) {
        guard !isStopping else {
            cell.cancel()
            return
        }
        cell.cancel()
        let token = cell.token
        let asset = catalog.dataset.assets[logicalIndex % catalog.dataset.assets.count]
        let requestID = "w1-\(runIndex)-\(logicalIndex)-\(UUID().uuidString.lowercased())"
        let task = Task { @MainActor [weak self, weak cell] in
            guard let self, let cell else { return }
            do {
                try Task.checkCancellation()
                let target = try ComparatorPixelTarget(width: 320, height: 240)
                let request = try ComparatorRequest(
                    resourceID: asset.assetID,
                    url: BenchmarkCoordinator.benchmarkURL(path: "/asset/\(asset.assetID)"),
                    target: target,
                    contentMode: .aspectFill,
                    priority: .visible,
                    headers: ["X-Benchmark-Request-ID": requestID]
                )
                let load = try await adapter.makeLoad(request)
                cell.install(load: load, requestID: requestID)
                if Task.isCancelled {
                    DeterministicBenchmarkURLProtocol.markCancellation(requestID: requestID)
                    load.cancel()
                }
                let output = await load.result()
                await accumulator.append(resourceID: asset.assetID, target: target, output: output)
                guard output.measurement.outcome == .completed, let image = output.image else {
                    return
                }
                guard !Task.isCancelled, cell.token == token else {
                    lateResultsRejected += 1
                    return
                }
                cell.installRenderedImage(
                    image,
                    captureOwnerMetadata: ownerAttribution != nil
                )
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                let target = try? ComparatorPixelTarget(width: 320, height: 240)
                if let target,
                    let measurement = try? ComparatorLoadResult(
                        outcome: .failed,
                        cacheSource: .unknown,
                        latencyNanoseconds: 0,
                        failureCategory: "request"
                    )
                {
                    await accumulator.append(
                        resourceID: asset.assetID,
                        target: target,
                        output: ComparatorLoadOutput(measurement: measurement, image: nil)
                    )
                }
            }
        }
        cell.loaderTask = task
        tasks.append(task)
    }
}

@MainActor
private final class ScrollTraceDriver {
    private struct Segment {
        let start: Double
        let end: Double
        let viewportVelocity: Double
    }

    private let collectionView: UICollectionView
    private let timeScale: Double
    private var link: CADisplayLink?
    private var startedAt: CFTimeInterval?
    private var continuation: CheckedContinuation<Void, Never>?
    private let segments: [Segment] = [
        Segment(start: 0, end: 2, viewportVelocity: 0),
        Segment(start: 2, end: 9, viewportVelocity: 1.5),
        Segment(start: 9, end: 10.5, viewportVelocity: -2.0),
        Segment(start: 10.5, end: 16, viewportVelocity: 1.5),
        Segment(start: 16, end: 16.5, viewportVelocity: 0),
        Segment(start: 16.5, end: 18, viewportVelocity: -2.0),
        Segment(start: 18, end: 25, viewportVelocity: 1.5),
        Segment(start: 25, end: 27, viewportVelocity: 0),
        Segment(start: 27, end: 28.5, viewportVelocity: -2.0),
        Segment(start: 28.5, end: 40, viewportVelocity: 1.5),
    ]

    init(collectionView: UICollectionView, timeScale: Double) {
        self.collectionView = collectionView
        self.timeScale = timeScale
    }

    func run() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
        }
    }

    @objc private func tick(_ link: CADisplayLink) {
        if startedAt == nil { startedAt = link.timestamp }
        let realElapsed = link.timestamp - (startedAt ?? link.timestamp)
        let logicalElapsed = realElapsed / timeScale
        let viewport = max(1, collectionView.bounds.height)
        let offset = displacement(at: min(40, logicalElapsed)) * viewport
        let maximum = max(0, collectionView.contentSize.height - collectionView.bounds.height)
        collectionView.setContentOffset(
            CGPoint(x: 0, y: min(maximum, max(0, offset))),
            animated: false
        )
        if logicalElapsed >= 40 {
            self.link?.invalidate()
            self.link = nil
            continuation?.resume()
            continuation = nil
        }
    }

    private func displacement(at time: Double) -> Double {
        var value = 0.0
        for segment in segments {
            guard time > segment.start else { break }
            let duration = min(time, segment.end) - segment.start
            if duration > 0 { value += duration * segment.viewportVelocity }
            if time <= segment.end { break }
        }
        return value
    }
}
