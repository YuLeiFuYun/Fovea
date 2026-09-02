import Darwin
import Foundation
import QuartzCore
import UIKit

final class PhysicalFootprintSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var baseline: UInt64?
    private var peak: UInt64?

    func start() {
        let initial = Self.current()
        lock.lock()
        baseline = initial
        peak = initial
        lock.unlock()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now(), repeating: .milliseconds(50))
        timer.setEventHandler { [weak self] in self?.sample() }
        self.timer = timer
        timer.resume()
    }

    func stop() -> (baseline: UInt64?, peak: UInt64?, delta: Int64?) {
        timer?.cancel()
        timer = nil
        sample()
        lock.lock()
        let baseline = baseline
        let peak = peak
        lock.unlock()
        let delta: Int64?
        if let baseline, let peak {
            delta =
                peak >= baseline
                ? Int64(min(UInt64(Int64.max), peak - baseline))
                : -Int64(min(UInt64(Int64.max), baseline - peak))
        } else {
            delta = nil
        }
        return (baseline, peak, delta)
    }

    private func sample() {
        guard let value = Self.current() else { return }
        lock.lock()
        peak = max(peak ?? value, value)
        lock.unlock()
    }

    static func current() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return info.phys_footprint
    }
}

final class ThreadCountSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var baseline: Int?
    private var peak: Int?

    func start() {
        let initial = Self.current()
        lock.lock()
        baseline = initial
        peak = initial
        lock.unlock()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now(), repeating: .milliseconds(10))
        timer.setEventHandler { [weak self] in self?.sample() }
        self.timer = timer
        timer.resume()
    }

    func stop() -> (baseline: Int?, peak: Int?) {
        timer?.cancel()
        timer = nil
        sample()
        lock.lock()
        defer { lock.unlock() }
        return (baseline, peak)
    }

    private func sample() {
        guard let value = Self.current() else { return }
        lock.lock()
        peak = max(peak ?? value, value)
        lock.unlock()
    }

    private static func current() -> Int? {
        var threads: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        let result = task_threads(mach_task_self_, &threads, &count)
        guard result == KERN_SUCCESS else { return nil }
        if let threads {
            let byteCount = vm_size_t(Int(count) * MemoryLayout<thread_t>.stride)
            vm_deallocate(
                mach_task_self_,
                vm_address_t(UInt(bitPattern: threads)),
                byteCount
            )
        }
        return Int(count)
    }
}

@MainActor
final class FrameHitchSampler {
    private var displayLink: CADisplayLink?
    private var previousTimestamp: CFTimeInterval?
    private(set) var hitchCount = 0
    private(set) var hitchExcessNanoseconds: UInt64 = 0
    private(set) var maximumFrameIntervalNanoseconds: UInt64 = 0

    func start() {
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        defer { previousTimestamp = link.timestamp }
        guard let previousTimestamp else { return }
        let interval = max(0, link.timestamp - previousTimestamp)
        let intervalNanoseconds = UInt64(interval * 1_000_000_000)
        maximumFrameIntervalNanoseconds = max(maximumFrameIntervalNanoseconds, intervalNanoseconds)
        let nominal = max(1.0 / 120.0, link.targetTimestamp - link.timestamp)
        let threshold = nominal * 1.5
        if interval > threshold {
            hitchCount += 1
            hitchExcessNanoseconds += UInt64((interval - nominal) * 1_000_000_000)
        }
    }
}

@MainActor
final class DisplayFrameBarrier {
    private var remainingFrames: Int
    private var displayLink: CADisplayLink?
    private var continuation: CheckedContinuation<Void, Never>?

    init(frameCount: Int) {
        remainingFrames = max(0, frameCount)
    }

    func wait() async {
        guard remainingFrames > 0 else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
    }

    @objc private func tick(_ link: CADisplayLink) {
        remainingFrames -= 1
        guard remainingFrames == 0 else { return }
        link.invalidate()
        displayLink = nil
        let continuation = continuation
        self.continuation = nil
        continuation?.resume()
    }
}

/// Refresh-synchronized, non-retaining observation of the image currently bound to one benchmark
/// `UIImageView`. The recorder stores only opaque backing/binding identities and timestamps; it
/// never retains `UIImage`, `CGImage`, or the view.
///
/// A binding token is distinct from backing identity so a later semantic frame that intentionally
/// reuses the same `CGImage` can still be observed independently. All mutation happens on the main
/// actor, matching `CADisplayLink` and benchmark UI assignment.
@MainActor
final class ImageViewPresentationRecorder {
    struct Observation: Sendable {
        let bindingToken: UInt64
        let backingIdentity: UInt64
        let uptimeNanoseconds: UInt64
        let displayLinkTimestamp: CFTimeInterval
        let displayLinkTargetTimestamp: CFTimeInterval
    }

    private struct Binding {
        let token: UInt64
        let backingIdentity: UInt64
    }

    private weak var imageView: UIImageView?
    private let maximumObservations: Int
    private var displayLink: CADisplayLink?
    private var currentBinding: Binding?
    private var observationsByToken: [UInt64: Observation] = [:]

    init(imageView: UIImageView, maximumObservations: Int = 64) {
        self.imageView = imageView
        self.maximumObservations = max(1, maximumObservations)
        observationsByToken.reserveCapacity(self.maximumObservations)
    }

    func start() {
        guard displayLink == nil else { return }
        currentBinding = nil
        observationsByToken.removeAll(keepingCapacity: true)
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        currentBinding = nil
    }

    func didBind(image: CGImage, bindingToken: UInt64) {
        currentBinding = Binding(
            token: bindingToken,
            backingIdentity: Self.backingIdentity(image)
        )
    }

    func observation(for bindingToken: UInt64) -> Observation? {
        observationsByToken[bindingToken]
    }

    static func backingIdentity(_ image: CGImage) -> UInt64 {
        UInt64(UInt(bitPattern: Unmanaged.passUnretained(image).toOpaque()))
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard observationsByToken.count < maximumObservations,
            let binding = currentBinding,
            observationsByToken[binding.token] == nil,
            let image = imageView?.image?.cgImage,
            Self.backingIdentity(image) == binding.backingIdentity
        else { return }
        observationsByToken[binding.token] = Observation(
            bindingToken: binding.token,
            backingIdentity: binding.backingIdentity,
            uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds,
            displayLinkTimestamp: link.timestamp,
            displayLinkTargetTimestamp: link.targetTimestamp
        )
    }
}
