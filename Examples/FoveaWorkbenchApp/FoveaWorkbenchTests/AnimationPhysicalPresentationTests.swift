#if canImport(UIKit)
    import Foundation
    @testable import FoveaWorkbench
    @_spi(BenchmarkDiagnostics) import FoveaUIKit
    import QuartzCore
    import UIKit
    import XCTest

    @MainActor
    final class AnimationPhysicalPresentationTests: XCTestCase {
        func testPhysicalDisplayTargetCoalescingAndLifecycle_W5_DEVICE_PT_001() async throws {
            #if targetEnvironment(simulator)
                throw XCTSkip("physical-device-only animation presentation evidence")
            #else
                let thermalStart = ProcessInfo.processInfo.thermalState.rawValue
                let lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
                let maximumFramesPerSecond = UIScreen.main.maximumFramesPerSecond
                let window = UIWindow(frame: UIScreen.main.bounds)
                let controller = UIViewController()
                window.rootViewController = controller
                window.makeKeyAndVisible()
                defer {
                    window.isHidden = true
                }

                let imageView = FoveaImageView(
                    frame: CGRect(x: 0, y: 0, width: 64, height: 64)
                )
                controller.view.addSubview(imageView)
                try await imageView.startSyntheticAnimationPresentationBenchmark(
                    frameCount: 240,
                    frameDurationNanoseconds: 16_666_667,
                    providerDelayNanoseconds: 40_000_000
                )

                let startedAt = CACurrentMediaTime()
                try await waitUntil("display targets coalesce under slow provider") {
                    guard let snapshot = imageView.animationPresentationDiagnostics else {
                        return false
                    }
                    return snapshot.acceptedTargetCount >= 10
                        && snapshot.consumedTargetCount >= 2
                        && snapshot.supersededPendingTargetCount > 0
                }
                let running = try XCTUnwrap(imageView.animationPresentationDiagnostics)
                XCTAssertEqual(running.rejectedNonmonotonicTargetCount, 0)
                XCTAssertFalse(running.isDisplayLinkPaused)
                XCTAssertEqual(running.effectiveVisibility, true)
                XCTAssertGreaterThan(
                    running.acceptedTargetCount,
                    running.consumedTargetCount
                )

                imageView.isHidden = true
                try await waitUntil("hidden animation pauses its display link") {
                    guard let snapshot = imageView.animationPresentationDiagnostics else {
                        return false
                    }
                    return snapshot.isDisplayLinkPaused
                        && snapshot.effectiveVisibility == false
                }
                let hiddenStart = try XCTUnwrap(imageView.animationPresentationDiagnostics)
                try await Task<Never, Never>.sleep(nanoseconds: 150_000_000)
                let hiddenEnd = try XCTUnwrap(imageView.animationPresentationDiagnostics)
                let hiddenAcceptedDelta =
                    hiddenEnd.acceptedTargetCount - hiddenStart.acceptedTargetCount
                XCTAssertLessThanOrEqual(hiddenAcceptedDelta, 1)

                imageView.isHidden = false
                try await waitUntil("visible animation resumes display targets") {
                    guard let snapshot = imageView.animationPresentationDiagnostics else {
                        return false
                    }
                    return !snapshot.isDisplayLinkPaused
                        && snapshot.effectiveVisibility == true
                        && snapshot.acceptedTargetCount
                            >= hiddenEnd.acceptedTargetCount + 4
                }
                let resumed = try XCTUnwrap(imageView.animationPresentationDiagnostics)
                let resumedAcceptedDelta =
                    resumed.acceptedTargetCount - hiddenEnd.acceptedTargetCount
                XCTAssertEqual(resumed.rejectedNonmonotonicTargetCount, 0)
                XCTAssertGreaterThan(resumedAcceptedDelta, 0)
                XCTAssertGreaterThan(
                    resumed.lifecycleClearedPendingTargetCount,
                    running.lifecycleClearedPendingTargetCount
                )

                let elapsed = CACurrentMediaTime() - startedAt
                let thermalEnd = ProcessInfo.processInfo.thermalState.rawValue
                print(
                    "FOVEA_PHYSICAL_ANIMATION_METRICS "
                        + "accepted=\(resumed.acceptedTargetCount) "
                        + "consumed=\(resumed.consumedTargetCount) "
                        + "superseded=\(resumed.supersededPendingTargetCount) "
                        + "rejected=\(resumed.rejectedNonmonotonicTargetCount) "
                        + "lifecycleCleared=\(resumed.lifecycleClearedPendingTargetCount) "
                        + "hiddenAcceptedDelta=\(hiddenAcceptedDelta) "
                        + "resumedAcceptedDelta=\(resumedAcceptedDelta) "
                        + "maximumFPS=\(maximumFramesPerSecond) "
                        + "lowPowerMode=\(lowPowerMode) "
                        + "thermalStart=\(thermalStart) thermalEnd=\(thermalEnd) "
                        + "elapsedSeconds=\(String(format: "%.6f", elapsed))"
                )
                imageView.cancelImageRequest(clearImage: true)
            #endif
        }

        func testTimelineAlignedCadenceIsExplicitAndDefaultOff_W5_DEVICE_PT_002() async throws {
            #if targetEnvironment(simulator)
                throw XCTSkip("physical-device-only animation cadence configuration evidence")
            #else
                let window = UIWindow(frame: UIScreen.main.bounds)
                let controller = UIViewController()
                window.rootViewController = controller
                window.makeKeyAndVisible()
                defer { window.isHidden = true }

                let imageView = FoveaImageView(
                    frame: CGRect(x: 0, y: 0, width: 64, height: 64)
                )
                controller.view.addSubview(imageView)

                try await imageView.startSyntheticAnimationPresentationBenchmark(
                    frameCount: 20,
                    frameDurationNanoseconds: 100_000_000,
                    providerDelayNanoseconds: 0,
                    cadenceMode: .maximumRefresh
                )
                try await waitUntil("default cadence diagnostics") {
                    imageView.animationPresentationDiagnostics != nil
                }
                let defaultSnapshot = try XCTUnwrap(imageView.animationPresentationDiagnostics)
                XCTAssertNil(defaultSnapshot.requestedPreferredFramesPerSecond)

                try await imageView.startSyntheticAnimationPresentationBenchmark(
                    frameCount: 20,
                    frameDurationNanoseconds: 100_000_000,
                    providerDelayNanoseconds: 0,
                    cadenceMode: .timelineAligned
                )
                try await waitUntil("timeline-aligned cadence request") {
                    imageView.animationPresentationDiagnostics?.requestedPreferredFramesPerSecond
                        == 10
                }
                let alignedSnapshot = try XCTUnwrap(imageView.animationPresentationDiagnostics)
                XCTAssertEqual(alignedSnapshot.requestedPreferredFramesPerSecond, 10)
                XCTAssertGreaterThan(window.screen.maximumFramesPerSecond, 10)
                print(
                    "FOVEA_PHYSICAL_ANIMATION_CADENCE "
                        + "requestedPreferredFPS=10 "
                        + "maximumFPS=\(window.screen.maximumFramesPerSecond) "
                        + "evidenceScope=configuration-only-not-energy-or-timing"
                )
                imageView.cancelImageRequest(clearImage: true)
            #endif
        }

        private func waitUntil(
            _ label: String,
            iterations: Int = 200,
            condition: @escaping @MainActor () -> Bool
        ) async throws {
            for _ in 0..<iterations {
                if condition() { return }
                try await Task<Never, Never>.sleep(nanoseconds: 5_000_000)
            }
            XCTFail("Timed out waiting for \(label)")
        }
    }
#endif
