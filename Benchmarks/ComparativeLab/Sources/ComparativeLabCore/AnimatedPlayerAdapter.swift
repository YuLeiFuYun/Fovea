import Foundation

public enum ComparatorAnimatedFormat: String, Codable, Equatable, Sendable {
    case gif
    case apng
}

/// Distinguishes native encoded playback from player-only decoded-frame harnesses.
/// Startup/resource claims must never be compared across different input paths.
public enum ComparatorAnimatedPlayerInputPath: String, Codable, Equatable, Sendable {
    case encodedNative = "encoded-native"
    case syntheticDecodedFrames = "synthetic-decoded-frames"
}

/// Encoded input and bounded buffering policy shared by W5 player adapters.
///
/// The adapter receives identical encoded bytes. Timeline normalization remains an oracle concern so a player
/// cannot silently rewrite expected durations and still pass comparative scoring.
public struct ComparatorAnimatedPlayerRequest: Sendable {
    public let resourceID: String
    public let encodedData: Data
    public let format: ComparatorAnimatedFormat
    public let referenceFrameDurationsNanoseconds: [UInt64]
    public let referenceLoopCount: UInt
    public let maximumFrameBufferBytes: Int

    public init(
        resourceID: String,
        encodedData: Data,
        format: ComparatorAnimatedFormat,
        referenceFrameDurationsNanoseconds: [UInt64],
        referenceLoopCount: UInt,
        maximumFrameBufferBytes: Int
    ) throws {
        guard !resourceID.isEmpty,
            resourceID.utf8.count <= 256,
            !encodedData.isEmpty,
            encodedData.count <= 64 * 1_024 * 1_024,
            referenceFrameDurationsNanoseconds.count > 1,
            referenceFrameDurationsNanoseconds.count <= 100_000,
            referenceFrameDurationsNanoseconds.allSatisfy({ $0 > 0 }),
            (1...(512 * 1_024 * 1_024)).contains(maximumFrameBufferBytes),
            Self.matches(format: format, data: encodedData)
        else {
            throw ComparativeLabError.invalidMeasurement
        }
        self.resourceID = resourceID
        self.encodedData = encodedData
        self.format = format
        self.referenceFrameDurationsNanoseconds = referenceFrameDurationsNanoseconds
        self.referenceLoopCount = referenceLoopCount
        self.maximumFrameBufferBytes = maximumFrameBufferBytes
    }

    private static func matches(format: ComparatorAnimatedFormat, data: Data) -> Bool {
        switch format {
        case .gif:
            guard data.count >= 6 else { return false }
            let signature = data.prefix(6)
            return signature.elementsEqual(Data("GIF87a".utf8))
                || signature.elementsEqual(Data("GIF89a".utf8))
        case .apng:
            let pngSignature = Data([137, 80, 78, 71, 13, 10, 26, 10])
            guard data.count >= 20, data.prefix(8).elementsEqual(pngSignature) else { return false }
            return data.range(of: Data("acTL".utf8)) != nil
        }
    }
}

/// Raw frame-change callback from the comparator's own player.
///
/// `monotonicNanoseconds` is captured at the player's actual public presentation/frame-change callback. The
/// runner later subtracts the first event timestamp. This keeps adapter scheduling differences observable.
public struct ComparatorAnimatedPlayerFrameEvent: Equatable, Sendable {
    public let sequence: Int
    public let monotonicNanoseconds: UInt64
    public let sourceFrameIndex: Int
    public let mainThreadCallbackNanoseconds: UInt64?

    public init(
        sequence: Int,
        monotonicNanoseconds: UInt64,
        sourceFrameIndex: Int,
        mainThreadCallbackNanoseconds: UInt64? = nil
    ) throws {
        guard sequence >= 0, sourceFrameIndex >= 0 else {
            throw ComparativeLabError.invalidMeasurement
        }
        self.sequence = sequence
        self.monotonicNanoseconds = monotonicNanoseconds
        self.sourceFrameIndex = sourceFrameIndex
        self.mainThreadCallbackNanoseconds = mainThreadCallbackNanoseconds
    }
}

/// A prepared animated player with public-source timing metadata and explicit lifecycle controls.
public struct ComparatorAnimatedPlayerSession: Sendable {
    public let sourceFrameDurationsNanoseconds: [UInt64]
    public let sourceLoopCount: UInt
    public let inputPath: ComparatorAnimatedPlayerInputPath
    public let events: AsyncStream<ComparatorAnimatedPlayerFrameEvent>

    private let startOperation: @MainActor @Sendable () async throws -> Void
    private let pauseOperation: @MainActor @Sendable () -> Void
    private let stopOperation: @MainActor @Sendable () -> Void

    public init(
        sourceFrameDurationsNanoseconds: [UInt64],
        sourceLoopCount: UInt,
        inputPath: ComparatorAnimatedPlayerInputPath,
        events: AsyncStream<ComparatorAnimatedPlayerFrameEvent>,
        start: @escaping @MainActor @Sendable () async throws -> Void,
        pause: @escaping @MainActor @Sendable () -> Void,
        stop: @escaping @MainActor @Sendable () -> Void
    ) throws {
        guard sourceFrameDurationsNanoseconds.count > 1,
            sourceFrameDurationsNanoseconds.count <= 100_000,
            sourceFrameDurationsNanoseconds.allSatisfy({ $0 > 0 })
        else {
            throw ComparativeLabError.invalidMeasurement
        }
        self.sourceFrameDurationsNanoseconds = sourceFrameDurationsNanoseconds
        self.sourceLoopCount = sourceLoopCount
        self.inputPath = inputPath
        self.events = events
        self.startOperation = start
        self.pauseOperation = pause
        self.stopOperation = stop
    }

    @MainActor
    public func start() async throws {
        try await startOperation()
    }

    @MainActor
    public func pause() {
        pauseOperation()
    }

    @MainActor
    public func stop() {
        stopOperation()
    }
}

public protocol ComparatorAnimatedPlayerAdapter: ComparatorAdapter {
    @MainActor
    func makeAnimatedPlayer(_ request: ComparatorAnimatedPlayerRequest) throws
        -> ComparatorAnimatedPlayerSession
}

extension AnimatedPresentationOracle {
    /// Converts raw comparator callbacks into the normalized trace consumed by the common W5 oracle.
    public static func normalize(
        events: [ComparatorAnimatedPlayerFrameEvent]
    ) throws -> [AnimatedPresentationObservation] {
        guard let first = events.first,
            first.sequence == 0,
            events.count <= 1_000_000
        else {
            throw ComparativeLabError.invalidMeasurement
        }
        var previousTimestamp = first.monotonicNanoseconds
        return try events.enumerated().map { offset, event in
            guard event.sequence == offset,
                offset == 0 || event.monotonicNanoseconds > previousTimestamp
            else {
                throw ComparativeLabError.invalidMeasurement
            }
            defer { previousTimestamp = event.monotonicNanoseconds }
            return try AnimatedPresentationObservation(
                sequence: offset,
                elapsedNanoseconds: event.monotonicNanoseconds - first.monotonicNanoseconds,
                frameIndex: event.sourceFrameIndex,
                mainThreadCallbackNanoseconds: event.mainThreadCallbackNanoseconds
            )
        }
    }
}

/// Canonical conversion for GIF frame delays returned through APIs backed by Float32 ImageIO metadata.
/// GIF stores frame delay in centiseconds, so converting the floating-point seconds directly to nanoseconds
/// can create false 1-3 ns semantic mismatches across otherwise identical decoders.
public enum ComparatorAnimatedDurationNormalization {
    public static func gifCentisecondNanoseconds(seconds: Double) throws -> UInt64 {
        guard seconds.isFinite, seconds > 0 else {
            throw ComparativeLabError.invalidMeasurement
        }
        let centiseconds = (seconds * 100).rounded(.toNearestOrEven)
        guard centiseconds >= 1,
            centiseconds <= Double(UInt64.max / 10_000_000)
        else {
            throw ComparativeLabError.invalidMeasurement
        }
        return UInt64(centiseconds) * 10_000_000
    }

    /// Normalizes APIs which expose encoded image delays through binary floating-point metadata.
    /// One microsecond is far below display scheduling resolution while removing representational
    /// 1-30 ns noise from millisecond-scale APNG delays. This must not be used to hide source-level
    /// clamps or frame-duration rewrites.
    public static func nearestMicrosecondNanoseconds(seconds: Double) throws -> UInt64 {
        guard seconds.isFinite, seconds > 0 else {
            throw ComparativeLabError.invalidMeasurement
        }
        let microseconds = (seconds * 1_000_000).rounded(.toNearestOrEven)
        guard microseconds >= 1,
            microseconds <= Double(UInt64.max / 1_000)
        else {
            throw ComparativeLabError.invalidMeasurement
        }
        return UInt64(microseconds) * 1_000
    }
}
