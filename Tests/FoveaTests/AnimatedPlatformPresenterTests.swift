import CoreGraphics
import Dispatch
import Foundation
import FoveaCore
import FoveaHTTP
import ImageCraftCore
import XCTest

#if canImport(UIKit)
    import FoveaUIKit
    import UIKit

    @MainActor
    final class UIKitAnimationDisplayLinkTests: XCTestCase {
        func testDisplayLinkTimestampConversionRejectsInvalidValues_W5_PT_129() {
            XCTAssertEqual(
                FoveaAnimationDisplayLinkDriver.nanoseconds(
                    fromPresentationTimestamp: 1.5
                ),
                1_500_000_000
            )
            XCTAssertNil(
                FoveaAnimationDisplayLinkDriver.nanoseconds(
                    fromPresentationTimestamp: -.infinity
                )
            )
            XCTAssertNil(
                FoveaAnimationDisplayLinkDriver.nanoseconds(
                    fromPresentationTimestamp: .nan
                )
            )
            XCTAssertNil(
                FoveaAnimationDisplayLinkDriver.nanoseconds(
                    fromPresentationTimestamp: .greatestFiniteMagnitude
                )
            )
            XCTAssertNil(
                FoveaAnimationDisplayLinkDriver.nanoseconds(
                    fromPresentationTimestamp: Double(UInt64.max) / 1_000_000_000
                )
            )
        }
    }
#endif

#if canImport(AppKit)
    import AppKit
    import FoveaAppKit

    @MainActor
    final class AppKitAnimatedPresenterTests: XCTestCase {
        func testDisplayLinkTimestampConversionRejectsInvalidValues_W5_PT_142() {
            guard #available(macOS 14.0, *) else { return }
            XCTAssertEqual(
                FoveaAnimationDisplayLinkDriver.nanoseconds(
                    fromPresentationTimestamp: 1.5
                ),
                1_500_000_000
            )
            XCTAssertNil(
                FoveaAnimationDisplayLinkDriver.nanoseconds(
                    fromPresentationTimestamp: -.infinity
                )
            )
            XCTAssertNil(
                FoveaAnimationDisplayLinkDriver.nanoseconds(
                    fromPresentationTimestamp: .nan
                )
            )
            XCTAssertNil(
                FoveaAnimationDisplayLinkDriver.nanoseconds(
                    fromPresentationTimestamp: .greatestFiniteMagnitude
                )
            )
            XCTAssertNil(
                FoveaAnimationDisplayLinkDriver.nanoseconds(
                    fromPresentationTimestamp: Double(UInt64.max) / 1_000_000_000
                )
            )
        }

        func testModernAppKitAnimationUsesViewDisplayLinkExternalTicks_W5_PT_143()
            async throws
        {
            guard #available(macOS 14.0, *) else { return }
            let runtime = AnimationPlaybackRuntime(frameMemoryCostLimit: 16 * 1024)
            let provider = PresenterAnimationProvider(image: presenterImage(width: 12))
            let handle = try await presenterLoopingHandle(
                runtime: runtime,
                provider: provider,
                label: "appkit-display-link"
            )
            let view = FoveaAppKit.FoveaImageView()
            let window = presenterWindow(containing: view)
            view.setAnimation(
                handle: handle,
                runtime: runtime,
                accessibility: .decorative
            )

            try await waitUntilOnMainActor("AppKit animation selects external display ticks") {
                await handle.driver.schedulingModeForTesting() == .externalPresentationTicks
            }
            let deadlineLoopRunning = await handle.driver.isRunningForTesting()
            XCTAssertFalse(deadlineLoopRunning)
            try await waitUntilOnMainActor("AppKit display link activates") {
                view.animationDisplayLinkPausedForTesting == false
            }
            let activeDiagnostics = try XCTUnwrap(view.animationPresentationDiagnostics)
            XCTAssertFalse(activeDiagnostics.isDisplayLinkPaused)
            XCTAssertEqual(activeDiagnostics.effectiveVisibility, true)
            XCTAssertLessThanOrEqual(
                activeDiagnostics.consumedTargetCount,
                activeDiagnostics.acceptedTargetCount
            )
            XCTAssertLessThanOrEqual(
                activeDiagnostics.supersededPendingTargetCount,
                activeDiagnostics.acceptedTargetCount
            )

            view.isHidden = true
            XCTAssertEqual(view.animationDisplayLinkPausedForTesting, true)
            let hiddenDiagnostics = try XCTUnwrap(view.animationPresentationDiagnostics)
            XCTAssertTrue(hiddenDiagnostics.isDisplayLinkPaused)
            XCTAssertEqual(hiddenDiagnostics.effectiveVisibility, false)
            view.isHidden = false
            try await waitUntilOnMainActor("AppKit display link resumes") {
                view.animationDisplayLinkPausedForTesting == false
            }

            view.cancelAnimation(clearImage: true)
            try await waitUntilOnMainActor("AppKit display-link handle unregisters") {
                await runtime.registeredDriverCount() == 0
            }
            _ = window
        }
        func
            testAppKitPredecodeCompositorActivatesForResidentTrackAndFallsBackAfterVisibilityPause_W5_PT_153()
            async throws
        {
            guard #available(macOS 14.0, *) else { return }
            let runtime = AnimationPlaybackRuntime(frameMemoryCostLimit: 64 * 1024)
            let provider = PresenterAnimationProvider(image: presenterImage(width: 12))
            let handle = try await presenterPredecodeAllLoopingHandle(
                runtime: runtime,
                provider: provider,
                label: "appkit-compositor-visibility"
            )
            let view = NSImageView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
            let window = presenterWindow(containing: view)
            let presenter = FoveaAnimatedImageViewPresenter(imageView: view)
            presenter.present(handle: handle, runtime: runtime, initiallyVisible: true)

            try await waitUntilOnMainActor("AppKit compositor predecode path activates") {
                presenter.compositorPresentationActiveForTesting
            }
            XCTAssertEqual(presenter.compositorRetainedFrameCountForTesting, 2)
            XCTAssertTrue(presenter.compositorLayerAttachedForTesting)
            let pinnedWhileVisible = await runtime.currentPinnedFrameMemoryCostForTesting()
            XCTAssertGreaterThan(pinnedWhileVisible, 0)
            XCTAssertNotNil(presenter.compositorAnimationBeginTimeForTesting)
            XCTAssertNotNil(presenter.compositorLayerCurrentTimeForTesting)
            XCTAssertNotNil(view.image)
            let providerCalls = await provider.callCount()
            let residentFrameCount = await runtime.currentFrameCount()
            XCTAssertEqual(providerCalls, 1)
            XCTAssertEqual(residentFrameCount, 2)
            XCTAssertEqual(presenter.presentationDriverPausedForTesting, true)
            let diagnostics = try XCTUnwrap(presenter.presentationDiagnostics)
            XCTAssertEqual(diagnostics.acceptedTargetCount, 0)
            XCTAssertEqual(diagnostics.consumedTargetCount, 0)

            presenter.setVisible(false)
            try await waitUntilOnMainActor("visibility pause tears down compositor snapshot") {
                !presenter.compositorPresentationActiveForTesting
                    && presenter.compositorRetainedFrameCountForTesting == 0
            }
            XCTAssertNotNil(view.image)
            XCTAssertEqual(presenter.presentationDriverPausedForTesting, true)
            let pinnedAfterVisibilityPause = await runtime.currentPinnedFrameMemoryCostForTesting()
            XCTAssertEqual(pinnedAfterVisibilityPause, 0)

            presenter.setVisible(true)
            try await waitUntilOnMainActor("visibility resume reactivates compositor") {
                presenter.compositorPresentationActiveForTesting
                    && presenter.compositorRetainedFrameCountForTesting == 2
                    && presenter.presentationDriverPausedForTesting == true
            }
            let pinnedAfterVisibilityResume =
                await runtime.currentPinnedFrameMemoryCostForTesting()
            XCTAssertGreaterThan(pinnedAfterVisibilityResume, 0)
            let providerCallsAfterResume = await provider.callCount()
            XCTAssertEqual(providerCallsAfterResume, 1)

            presenter.cancel(clearImage: true)
            try await waitUntilOnMainActor("compositor visibility handle unregisters") {
                await runtime.registeredDriverCount() == 0
            }
            XCTAssertFalse(presenter.compositorPresentationActiveForTesting)
            XCTAssertEqual(presenter.compositorRetainedFrameCountForTesting, 0)
            XCTAssertNil(view.image)
            _ = window
        }

        func testAppKitPredecodeCompositorDefersUntilFirstVisibility_W5_PT_183() async throws {
            guard #available(macOS 14.0, *) else { return }
            let runtime = AnimationPlaybackRuntime(frameMemoryCostLimit: 64 * 1024)
            let provider = PresenterAnimationProvider(image: presenterImage(width: 12))
            let handle = try await presenterPredecodeAllLoopingHandle(
                runtime: runtime,
                provider: provider,
                label: "appkit-compositor-initially-hidden"
            )
            let view = NSImageView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
            let presenter = FoveaAnimatedImageViewPresenter(imageView: view)
            presenter.present(handle: handle, runtime: runtime, initiallyVisible: false)

            for _ in 0..<20 { await Task.yield() }
            let hiddenProviderCalls = await provider.callCount()
            XCTAssertEqual(hiddenProviderCalls, 0)
            XCTAssertFalse(presenter.compositorPresentationActiveForTesting)
            XCTAssertNil(view.image)

            let window = presenterWindow(containing: view)
            presenter.setVisible(true)
            try await waitUntilOnMainActor(
                "initially hidden predecode enters compositor on visibility"
            ) {
                presenter.compositorPresentationActiveForTesting
            }
            XCTAssertEqual(presenter.compositorRetainedFrameCountForTesting, 2)
            XCTAssertTrue(presenter.compositorLayerAttachedForTesting)
            XCTAssertEqual(presenter.presentationDriverPausedForTesting, true)
            let providerCalls = await provider.callCount()
            XCTAssertEqual(providerCalls, 1)
            let diagnostics = try XCTUnwrap(presenter.presentationDiagnostics)
            XCTAssertEqual(diagnostics.acceptedTargetCount, 0)
            XCTAssertEqual(diagnostics.consumedTargetCount, 0)

            presenter.cancel(clearImage: true)
            try await waitUntilOnMainActor("initially hidden compositor handle unregisters") {
                await runtime.registeredDriverCount() == 0
            }
            _ = window
        }

        func testAppKitPredecodeCompositorReoffloadsAcrossApplicationAndExplicitPause_W5_PT_186()
            async throws
        {
            guard #available(macOS 14.0, *) else { return }
            let runtime = AnimationPlaybackRuntime(frameMemoryCostLimit: 64 * 1024)
            let provider = PresenterAnimationProvider(image: presenterImage(width: 12))
            let handle = try await presenterPredecodeAllLoopingHandle(
                runtime: runtime,
                provider: provider,
                label: "appkit-compositor-lifecycle-reoffload"
            )
            let view = NSImageView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
            let window = presenterWindow(containing: view)
            let presenter = FoveaAnimatedImageViewPresenter(imageView: view)
            presenter.present(handle: handle, runtime: runtime, initiallyVisible: true)

            try await waitUntilOnMainActor("lifecycle compositor initially activates") {
                presenter.compositorPresentationActiveForTesting
            }
            let initialProviderCalls = await provider.callCount()
            XCTAssertEqual(initialProviderCalls, 1)

            _ = await runtime.setApplicationActive(false)
            try await waitUntilOnMainActor("application inactive releases compositor") {
                !presenter.compositorPresentationActiveForTesting
                    && presenter.compositorRetainedFrameCountForTesting == 0
                    && presenter.presentationDriverPausedForTesting == true
            }
            let pinnedWhileInactive = await runtime.currentPinnedFrameMemoryCostForTesting()
            XCTAssertEqual(pinnedWhileInactive, 0)

            _ = await runtime.setApplicationActive(true)
            try await waitUntilOnMainActor("application active reoffloads compositor") {
                presenter.compositorPresentationActiveForTesting
                    && presenter.compositorRetainedFrameCountForTesting == 2
                    && presenter.presentationDriverPausedForTesting == true
            }
            let callsAfterApplicationResume = await provider.callCount()
            XCTAssertEqual(callsAfterApplicationResume, initialProviderCalls)

            try await handle.driver.setExplicitlyPaused(true)
            try await waitUntilOnMainActor("explicit pause releases compositor") {
                !presenter.compositorPresentationActiveForTesting
                    && presenter.compositorRetainedFrameCountForTesting == 0
                    && presenter.presentationDriverPausedForTesting == true
            }
            let pinnedWhileExplicitlyPaused =
                await runtime.currentPinnedFrameMemoryCostForTesting()
            XCTAssertEqual(pinnedWhileExplicitlyPaused, 0)

            try await handle.driver.setExplicitlyPaused(false)
            try await waitUntilOnMainActor("explicit resume reoffloads compositor") {
                presenter.compositorPresentationActiveForTesting
                    && presenter.compositorRetainedFrameCountForTesting == 2
                    && presenter.presentationDriverPausedForTesting == true
            }
            let callsAfterExplicitResume = await provider.callCount()
            XCTAssertEqual(callsAfterExplicitResume, initialProviderCalls)
            let pinnedAfterExplicitResume = await runtime.currentPinnedFrameMemoryCostForTesting()
            XCTAssertGreaterThan(pinnedAfterExplicitResume, 0)

            presenter.cancel(clearImage: true)
            try await waitUntilOnMainActor("lifecycle-reoffload handle unregisters") {
                await runtime.registeredDriverCount() == 0
            }
            _ = window
        }

        func testAppKitPredecodeCompositorSeekReanchorsWithoutDecode_W5_PT_187() async throws {
            guard #available(macOS 14.0, *) else { return }
            let runtime = AnimationPlaybackRuntime(frameMemoryCostLimit: 64 * 1024)
            let provider = PresenterAnimationProvider(image: presenterImage(width: 12))
            let handle = try await presenterPredecodeAllLoopingHandle(
                runtime: runtime,
                provider: provider,
                label: "appkit-compositor-seek-reoffload"
            )
            let view = NSImageView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
            let window = presenterWindow(containing: view)
            let presenter = FoveaAnimatedImageViewPresenter(imageView: view)
            presenter.present(handle: handle, runtime: runtime, initiallyVisible: true)

            try await waitUntilOnMainActor("seek compositor initially activates") {
                presenter.compositorPresentationActiveForTesting
            }
            let callsBeforeSeek = await provider.callCount()
            XCTAssertEqual(callsBeforeSeek, 1)
            let beginTimeBeforeSeek = try XCTUnwrap(
                presenter.compositorAnimationBeginTimeForTesting
            )

            try await handle.driver.seek(toFrame: 1)
            try await waitUntilOnMainActor("seek reanchors resident compositor") {
                presenter.compositorPresentationActiveForTesting
                    && presenter.compositorRetainedFrameCountForTesting == 2
                    && presenter.presentationDriverPausedForTesting == true
            }
            let callsAfterSeek = await provider.callCount()
            XCTAssertEqual(callsAfterSeek, callsBeforeSeek)
            let beginTimeAfterSeek = try XCTUnwrap(
                presenter.compositorAnimationBeginTimeForTesting
            )
            XCTAssertNotEqual(beginTimeAfterSeek, beginTimeBeforeSeek)
            let pinnedAfterSeek = await runtime.currentPinnedFrameMemoryCostForTesting()
            XCTAssertGreaterThan(pinnedAfterSeek, 0)

            presenter.cancel(clearImage: true)
            try await waitUntilOnMainActor("seek-reoffload handle unregisters") {
                await runtime.registeredDriverCount() == 0
            }
            _ = window
        }

        func testAppKitFinitePredecodeCompositorActivatesByDefault_W5_PT_196()
            async throws
        {
            guard #available(macOS 14.0, *) else { return }
            let runtime = AnimationPlaybackRuntime(frameMemoryCostLimit: 64 * 1024)
            let provider = PresenterAnimationProvider(image: presenterImage(width: 12))
            let handle = try await presenterFinitePredecodeAllHandle(
                runtime: runtime,
                provider: provider,
                label: "appkit-finite-compositor-default-off"
            )
            let view = NSImageView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
            let window = presenterWindow(containing: view)
            let presenter = FoveaAnimatedImageViewPresenter(imageView: view)
            presenter.present(handle: handle, runtime: runtime, initiallyVisible: true)

            try await waitUntilOnMainActor("finite predecode compositor activates by default") {
                presenter.compositorPresentationActiveForTesting
                    && presenter.compositorRetainedFrameCountForTesting == 2
                    && presenter.presentationDriverPausedForTesting == true
            }
            XCTAssertNotNil(presenter.compositorFiniteCompletionDeadlineNanosecondsForTesting)
            XCTAssertEqual(presenter.compositorAnimationRepeatCountForTesting, 2)
            let providerCalls = await provider.callCount()
            XCTAssertEqual(providerCalls, 1)
            let pinned = await runtime.currentPinnedFrameMemoryCostForTesting()
            XCTAssertGreaterThan(pinned, 0)

            presenter.cancel(clearImage: true)
            try await waitUntilOnMainActor("finite default-off handle unregisters") {
                await runtime.registeredDriverCount() == 0
            }
            _ = window
        }

        func testAppKitFinitePredecodeCompositorCandidateCompletesWithOneCoreTick_W5_PT_197()
            async throws
        {
            guard #available(macOS 14.0, *) else { return }
            let runtime = AnimationPlaybackRuntime(frameMemoryCostLimit: 64 * 1024)
            let provider = PresenterAnimationProvider(image: presenterImage(width: 12))
            let handle = try await presenterFinitePredecodeAllHandle(
                runtime: runtime,
                provider: provider,
                label: "appkit-finite-compositor-candidate"
            )
            let view = NSImageView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
            let window = presenterWindow(containing: view)
            let presenter = FoveaAnimatedImageViewPresenter(imageView: view)
            presenter.present(handle: handle, runtime: runtime, initiallyVisible: true)

            try await waitUntilOnMainActor("finite compositor candidate activates") {
                presenter.compositorPresentationActiveForTesting
                    && presenter.compositorRetainedFrameCountForTesting == 2
                    && presenter.presentationDriverPausedForTesting == true
            }
            XCTAssertEqual(presenter.compositorAnimationRepeatCountForTesting, 2)
            let deadline = try XCTUnwrap(
                presenter.compositorFiniteCompletionDeadlineNanosecondsForTesting
            )
            let beginTime = try XCTUnwrap(presenter.compositorAnimationBeginTimeForTesting)
            XCTAssertGreaterThan(Double(deadline) / 1_000_000_000, beginTime)
            let providerCallsBeforeCompletion = await provider.callCount()
            XCTAssertEqual(providerCallsBeforeCompletion, 1)
            let pinnedBeforeCompletion = await runtime.currentPinnedFrameMemoryCostForTesting()
            XCTAssertGreaterThan(pinnedBeforeCompletion, 0)

            let completion = await presenter.completeFiniteCompositorForTesting()
            XCTAssertEqual(completion, .finished)
            try await waitUntilOnMainActor("finite compositor terminal tick tears down layer") {
                !presenter.compositorPresentationActiveForTesting
                    && presenter.compositorRetainedFrameCountForTesting == 0
            }
            XCTAssertNil(presenter.compositorFiniteCompletionDeadlineNanosecondsForTesting)
            XCTAssertEqual(presenter.presentationDriverPausedForTesting, true)
            let pinnedAfterCompletion = await runtime.currentPinnedFrameMemoryCostForTesting()
            XCTAssertEqual(pinnedAfterCompletion, 0)
            let providerCallsAfterCompletion = await provider.callCount()
            XCTAssertEqual(providerCallsAfterCompletion, providerCallsBeforeCompletion)
            let dispositionAfterFinish = await handle.driver.tick(
                atPresentationNanoseconds: deadline &+ 1
            )
            XCTAssertEqual(dispositionAfterFinish, .finished)

            presenter.cancel(clearImage: true)
            try await waitUntilOnMainActor("finite compositor handle unregisters") {
                await runtime.registeredDriverCount() == 0
            }
            _ = window
        }

        func
            testAppKitFinitePredecodeCompositorCandidateWakesDisplayLinkAtNaturalDeadline_W5_PT_198()
            async throws
        {
            guard #available(macOS 14.0, *) else { return }
            let runtime = AnimationPlaybackRuntime(frameMemoryCostLimit: 64 * 1024)
            let provider = PresenterAnimationProvider(image: presenterImage(width: 12))
            let handle = try await presenterFinitePredecodeAllHandle(
                runtime: runtime,
                provider: provider,
                label: "appkit-finite-compositor-natural-completion",
                frameDurationsNanoseconds: [150_000_000, 150_000_000],
                additionalRepeatCount: 0
            )
            let view = NSImageView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
            let window = presenterWindow(containing: view)
            let presenter = FoveaAnimatedImageViewPresenter(imageView: view)
            presenter.present(handle: handle, runtime: runtime, initiallyVisible: true)

            try await waitUntilOnMainActor("natural finite compositor activates") {
                presenter.compositorPresentationActiveForTesting
                    && presenter.compositorFiniteCompletionDeadlineNanosecondsForTesting != nil
            }
            XCTAssertEqual(presenter.compositorAnimationRepeatCountForTesting, 1)
            let callsBeforeCompletion = await provider.callCount()
            XCTAssertEqual(callsBeforeCompletion, 1)

            try await waitUntilOnMainActor(
                "natural finite deadline releases compositor and wakes display link"
            ) {
                !presenter.compositorPresentationActiveForTesting
                    && presenter.compositorFiniteCompletionDeadlineNanosecondsForTesting == nil
                    && presenter.presentationDriverPausedForTesting == false
            }
            let pinnedAfterDeadline = await runtime.currentPinnedFrameMemoryCostForTesting()
            XCTAssertEqual(pinnedAfterDeadline, 0)
            XCTAssertNotNil(view.image)
            let diagnosticsAfterWake = try XCTUnwrap(presenter.presentationDiagnostics)
            XCTAssertEqual(diagnosticsAfterWake.acceptedTargetCount, 0)

            let dispositionAfterNaturalCompletion = await handle.driver.tick(
                atPresentationNanoseconds: DispatchTime.now().uptimeNanoseconds
            )
            XCTAssertEqual(dispositionAfterNaturalCompletion, .finished)
            let callsAfterCompletion = await provider.callCount()
            XCTAssertEqual(callsAfterCompletion, callsBeforeCompletion)
            let pinnedAfterCompletion = await runtime.currentPinnedFrameMemoryCostForTesting()
            XCTAssertEqual(pinnedAfterCompletion, 0)

            presenter.cancel(clearImage: true)
            try await waitUntilOnMainActor("natural finite compositor handle unregisters") {
                await runtime.registeredDriverCount() == 0
            }
            _ = window
        }

        func testAppKitFinitePredecodeCompositorCandidateReanchorsCompletionAfterPause_W5_PT_199()
            async throws
        {
            guard #available(macOS 14.0, *) else { return }
            let runtime = AnimationPlaybackRuntime(frameMemoryCostLimit: 64 * 1024)
            let provider = PresenterAnimationProvider(image: presenterImage(width: 12))
            let handle = try await presenterFinitePredecodeAllHandle(
                runtime: runtime,
                provider: provider,
                label: "appkit-finite-compositor-pause-reanchor"
            )
            let view = NSImageView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
            let window = presenterWindow(containing: view)
            let presenter = FoveaAnimatedImageViewPresenter(imageView: view)
            presenter.present(handle: handle, runtime: runtime, initiallyVisible: true)

            try await waitUntilOnMainActor("finite pause candidate initially activates") {
                presenter.compositorPresentationActiveForTesting
            }
            let deadlineBeforePause = try XCTUnwrap(
                presenter.compositorFiniteCompletionDeadlineNanosecondsForTesting
            )
            let callsBeforePause = await provider.callCount()
            XCTAssertEqual(callsBeforePause, 1)

            try await handle.driver.setExplicitlyPaused(true)
            try await waitUntilOnMainActor("finite pause cancels compositor completion") {
                !presenter.compositorPresentationActiveForTesting
                    && presenter.compositorFiniteCompletionDeadlineNanosecondsForTesting == nil
            }
            try await Task<Never, Never>.sleep(nanoseconds: 20_000_000)
            try await handle.driver.setExplicitlyPaused(false)
            try await waitUntilOnMainActor("finite resume reoffloads with new completion") {
                presenter.compositorPresentationActiveForTesting
                    && presenter.compositorFiniteCompletionDeadlineNanosecondsForTesting != nil
            }
            let deadlineAfterResume = try XCTUnwrap(
                presenter.compositorFiniteCompletionDeadlineNanosecondsForTesting
            )
            XCTAssertGreaterThan(deadlineAfterResume, deadlineBeforePause)
            let callsAfterResume = await provider.callCount()
            XCTAssertEqual(callsAfterResume, callsBeforePause)

            presenter.cancel(clearImage: true)
            try await waitUntilOnMainActor("finite pause-reanchor handle unregisters") {
                await runtime.registeredDriverCount() == 0
            }
            _ = window
        }

        func testAppKitFiniteCompositorSeekReanchorsDeadlineWithoutDecode_W5_PT_201()
            async throws
        {
            guard #available(macOS 14.0, *) else { return }
            let runtime = AnimationPlaybackRuntime(frameMemoryCostLimit: 64 * 1024)
            let provider = PresenterAnimationProvider(image: presenterImage(width: 12))
            let handle = try await presenterFinitePredecodeAllHandle(
                runtime: runtime,
                provider: provider,
                label: "appkit-finite-seek-reanchor"
            )
            let view = NSImageView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
            let window = presenterWindow(containing: view)
            let presenter = FoveaAnimatedImageViewPresenter(imageView: view)
            presenter.present(handle: handle, runtime: runtime, initiallyVisible: true)

            try await waitUntilOnMainActor("finite seek compositor activates") {
                presenter.compositorPresentationActiveForTesting
            }
            let deadlineBeforeSeek = try XCTUnwrap(
                presenter.compositorFiniteCompletionDeadlineNanosecondsForTesting
            )
            let callsBeforeSeek = await provider.callCount()
            XCTAssertEqual(callsBeforeSeek, 1)

            try await handle.driver.seek(toFrame: 1)
            try await waitUntilOnMainActor("finite seek reoffloads resident compositor") {
                presenter.compositorPresentationActiveForTesting
                    && presenter.compositorFiniteCompletionDeadlineNanosecondsForTesting != nil
                    && presenter.presentationDriverPausedForTesting == true
            }
            let deadlineAfterSeek = try XCTUnwrap(
                presenter.compositorFiniteCompletionDeadlineNanosecondsForTesting
            )
            XCTAssertLessThan(deadlineAfterSeek, deadlineBeforeSeek)
            XCTAssertEqual(presenter.compositorAnimationRepeatCountForTesting, 2)
            let callsAfterSeek = await provider.callCount()
            XCTAssertEqual(callsAfterSeek, callsBeforeSeek)
            let pinnedAfterSeek = await runtime.currentPinnedFrameMemoryCostForTesting()
            XCTAssertGreaterThan(pinnedAfterSeek, 0)

            presenter.cancel(clearImage: true)
            try await waitUntilOnMainActor("finite seek handle unregisters") {
                await runtime.registeredDriverCount() == 0
            }
            _ = window
        }

        func testAppKitFiniteCompositorRestartReanchorsFullDurationWithoutDecode_W5_PT_202()
            async throws
        {
            guard #available(macOS 14.0, *) else { return }
            let runtime = AnimationPlaybackRuntime(frameMemoryCostLimit: 64 * 1024)
            let provider = PresenterAnimationProvider(image: presenterImage(width: 12))
            let handle = try await presenterFinitePredecodeAllHandle(
                runtime: runtime,
                provider: provider,
                label: "appkit-finite-restart-reanchor"
            )
            let view = NSImageView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
            let window = presenterWindow(containing: view)
            let presenter = FoveaAnimatedImageViewPresenter(imageView: view)
            presenter.present(handle: handle, runtime: runtime, initiallyVisible: true)

            try await waitUntilOnMainActor("finite restart compositor activates") {
                presenter.compositorPresentationActiveForTesting
            }
            let deadlineBeforeRestart = try XCTUnwrap(
                presenter.compositorFiniteCompletionDeadlineNanosecondsForTesting
            )
            let callsBeforeRestart = await provider.callCount()
            try await Task<Never, Never>.sleep(nanoseconds: 20_000_000)
            try await handle.driver.restart()
            try await waitUntilOnMainActor("finite restart reoffloads compositor") {
                presenter.compositorPresentationActiveForTesting
                    && presenter.compositorFiniteCompletionDeadlineNanosecondsForTesting != nil
                    && presenter.presentationDriverPausedForTesting == true
            }
            let deadlineAfterRestart = try XCTUnwrap(
                presenter.compositorFiniteCompletionDeadlineNanosecondsForTesting
            )
            XCTAssertGreaterThan(deadlineAfterRestart, deadlineBeforeRestart)
            let callsAfterRestart = await provider.callCount()
            XCTAssertEqual(callsAfterRestart, callsBeforeRestart)

            presenter.cancel(clearImage: true)
            try await waitUntilOnMainActor("finite restart handle unregisters") {
                await runtime.registeredDriverCount() == 0
            }
            _ = window
        }

        func testAppKitFiniteCompositorWarningPressureReoffloadsWithoutDecode_W5_PT_203()
            async throws
        {
            guard #available(macOS 14.0, *) else { return }
            let runtime = AnimationPlaybackRuntime(frameMemoryCostLimit: 64 * 1024)
            let provider = PresenterAnimationProvider(image: presenterImage(width: 12))
            let handle = try await presenterFinitePredecodeAllHandle(
                runtime: runtime,
                provider: provider,
                label: "appkit-finite-warning-reoffload"
            )
            let view = NSImageView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
            let window = presenterWindow(containing: view)
            let presenter = FoveaAnimatedImageViewPresenter(imageView: view)
            presenter.present(handle: handle, runtime: runtime, initiallyVisible: true)

            try await waitUntilOnMainActor("finite warning compositor activates") {
                presenter.compositorPresentationActiveForTesting
            }
            let callsBeforeWarning = await provider.callCount()
            _ = await runtime.applyMemoryPressure(.warning)
            try await waitUntilOnMainActor("finite warning releases compositor pin") {
                !presenter.compositorPresentationActiveForTesting
                    && presenter.compositorRetainedFrameCountForTesting == 0
                    && presenter.presentationDriverPausedForTesting == false
            }
            let pinnedAtWarning = await runtime.currentPinnedFrameMemoryCostForTesting()
            XCTAssertEqual(pinnedAtWarning, 0)

            _ = await runtime.applyMemoryPressure(.normal)
            try await waitUntilOnMainActor("finite normal pressure reoffloads compositor") {
                presenter.compositorPresentationActiveForTesting
                    && presenter.compositorRetainedFrameCountForTesting == 2
                    && presenter.presentationDriverPausedForTesting == true
            }
            let callsAfterNormal = await provider.callCount()
            XCTAssertEqual(callsAfterNormal, callsBeforeWarning)
            let pinnedAfterNormal = await runtime.currentPinnedFrameMemoryCostForTesting()
            XCTAssertGreaterThan(pinnedAfterNormal, 0)

            presenter.cancel(clearImage: true)
            try await waitUntilOnMainActor("finite warning handle unregisters") {
                await runtime.registeredDriverCount() == 0
            }
            _ = window
        }

        func testAppKitFiniteCompositorRejectsUnexactFloatPlayCountAndStreams_W5_PT_204()
            async throws
        {
            guard #available(macOS 14.0, *) else { return }
            let runtime = AnimationPlaybackRuntime(frameMemoryCostLimit: 64 * 1024)
            let provider = PresenterAnimationProvider(image: presenterImage(width: 12))
            let handle = try await presenterFinitePredecodeAllHandle(
                runtime: runtime,
                provider: provider,
                label: "appkit-finite-repeat-overflow",
                additionalRepeatCount: 16_777_216
            )
            let view = NSImageView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
            let window = presenterWindow(containing: view)
            let presenter = FoveaAnimatedImageViewPresenter(imageView: view)
            presenter.present(handle: handle, runtime: runtime, initiallyVisible: true)

            try await waitUntilOnMainActor("unexact finite play count falls back to streaming") {
                view.image != nil
                    && !presenter.compositorPresentationActiveForTesting
                    && presenter.presentationDriverPausedForTesting == false
            }
            XCTAssertNil(presenter.compositorFiniteCompletionDeadlineNanosecondsForTesting)
            let pinned = await runtime.currentPinnedFrameMemoryCostForTesting()
            XCTAssertEqual(pinned, 0)
            let providerCalls = await provider.callCount()
            XCTAssertEqual(providerCalls, 1)

            presenter.cancel(clearImage: true)
            try await waitUntilOnMainActor("unexact finite play count handle unregisters") {
                await runtime.registeredDriverCount() == 0
            }
            _ = window
        }

        func testAppKitAutomaticCompositorRefillsAfterCriticalPressure_W5_PT_185() async throws {
            guard #available(macOS 14.0, *) else { return }
            let runtime = AnimationPlaybackRuntime(frameMemoryCostLimit: 64 * 1024)
            let provider = PresenterAnimationProvider(image: presenterImage(width: 12))
            let handle = try await presenterAutomaticPredecodeAllLoopingHandle(
                runtime: runtime,
                provider: provider,
                label: "appkit-compositor-critical-refill"
            )
            let view = NSImageView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
            let window = presenterWindow(containing: view)
            let presenter = FoveaAnimatedImageViewPresenter(imageView: view)
            presenter.present(handle: handle, runtime: runtime, initiallyVisible: true)

            try await waitUntilOnMainActor("automatic compositor activates before critical refill")
            {
                presenter.compositorPresentationActiveForTesting
            }
            let callsBeforeCritical = await provider.callCount()
            XCTAssertEqual(callsBeforeCritical, 1)
            let rangesBeforeCritical = await provider.requestedRanges()
            XCTAssertEqual(rangesBeforeCritical, [0..<2])

            _ = await runtime.applyMemoryPressure(.critical)
            try await waitUntilOnMainActor("critical purge removes automatic compositor") {
                !presenter.compositorPresentationActiveForTesting
                    && presenter.compositorRetainedFrameCountForTesting == 0
            }
            let residentAfterCritical = await runtime.currentFrameCount()
            XCTAssertEqual(residentAfterCritical, 0)

            _ = await runtime.applyMemoryPressure(.normal)
            try await waitUntilOnMainActor("normal pressure re-enables streaming until refill tick")
            {
                presenter.presentationDriverPausedForTesting == false
            }
            XCTAssertFalse(presenter.compositorPresentationActiveForTesting)
            let residentBeforeRefillTick = await runtime.currentFrameCount()
            XCTAssertEqual(residentBeforeRefillTick, 0)

            let refillDisposition = await handle.driver.tick(
                atPresentationNanoseconds: DispatchTime.now().uptimeNanoseconds
            )
            XCTAssertEqual(refillDisposition, .advanced)
            try await waitUntilOnMainActor(
                "automatic handoff reactivates compositor after refill tick"
            ) {
                presenter.compositorPresentationActiveForTesting
                    && presenter.compositorRetainedFrameCountForTesting == 2
                    && presenter.presentationDriverPausedForTesting == true
            }
            let rangesAfterRefill = await provider.requestedRanges()
            let refillRanges = Array(rangesAfterRefill.dropFirst(rangesBeforeCritical.count))
            XCTAssertEqual(refillRanges.flatMap(Array.init).sorted(), [0, 1])
            XCTAssertLessThanOrEqual(refillRanges.count, 2)
            let residentAfterRefill = await runtime.currentFrameCount()
            XCTAssertEqual(residentAfterRefill, 2)
            let pinnedAfterRefill = await runtime.currentPinnedFrameMemoryCostForTesting()
            XCTAssertGreaterThan(pinnedAfterRefill, 0)

            presenter.cancel(clearImage: true)
            try await waitUntilOnMainActor("critical-refill compositor handle unregisters") {
                await runtime.registeredDriverCount() == 0
            }
            _ = window
        }

        func testAppKitPredecodeCompositorCriticalPressureReleasesWholeTrackSnapshot_W5_PT_154()
            async throws
        {
            guard #available(macOS 14.0, *) else { return }
            let runtime = AnimationPlaybackRuntime(frameMemoryCostLimit: 64 * 1024)
            let provider = PresenterAnimationProvider(image: presenterImage(width: 12))
            let handle = try await presenterPredecodeAllLoopingHandle(
                runtime: runtime,
                provider: provider,
                label: "appkit-compositor-pressure"
            )
            let view = NSImageView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
            let window = presenterWindow(containing: view)
            let presenter = FoveaAnimatedImageViewPresenter(imageView: view)
            presenter.present(handle: handle, runtime: runtime, initiallyVisible: true)

            try await waitUntilOnMainActor("AppKit compositor activates before pressure") {
                presenter.compositorPresentationActiveForTesting
            }
            XCTAssertEqual(presenter.compositorRetainedFrameCountForTesting, 2)
            XCTAssertTrue(presenter.compositorLayerAttachedForTesting)
            XCTAssertNotNil(view.image)
            let pinnedBeforeCritical = await runtime.currentPinnedFrameMemoryCostForTesting()
            XCTAssertGreaterThan(pinnedBeforeCritical, 0)
            let residentBeforePressure = await runtime.currentFrameCount()
            XCTAssertEqual(residentBeforePressure, 2)

            let report = await runtime.applyMemoryPressure(.critical)
            XCTAssertGreaterThanOrEqual(report.removedFrames.itemCount, 2)
            try await waitUntilOnMainActor("critical pressure tears down compositor snapshot") {
                !presenter.compositorPresentationActiveForTesting
                    && presenter.compositorRetainedFrameCountForTesting == 0
            }
            let residentAfterPressure = await runtime.currentFrameCount()
            let residentCostAfterPressure = await runtime.currentFrameMemoryCost()
            XCTAssertEqual(residentAfterPressure, 0)
            XCTAssertEqual(residentCostAfterPressure, 0)
            let pinnedAfterCritical = await runtime.currentPinnedFrameMemoryCostForTesting()
            XCTAssertEqual(pinnedAfterCritical, 0)
            XCTAssertEqual(presenter.presentationDriverPausedForTesting, true)
            XCTAssertNotNil(view.image)

            presenter.cancel(clearImage: true)
            try await waitUntilOnMainActor("compositor pressure handle unregisters") {
                await runtime.registeredDriverCount() == 0
            }
            XCTAssertFalse(presenter.compositorPresentationActiveForTesting)
            XCTAssertEqual(presenter.compositorRetainedFrameCountForTesting, 0)
            XCTAssertNil(view.image)
            _ = window
        }

        func testAppKitPredecodeCompositorWarningPressureInvalidatesAndResumesStreaming_W5_PT_157()
            async throws
        {
            guard #available(macOS 14.0, *) else { return }
            let runtime = AnimationPlaybackRuntime(frameMemoryCostLimit: 64 * 1024)
            let provider = PresenterAnimationProvider(image: presenterImage(width: 12))
            let handle = try await presenterPredecodeAllLoopingHandle(
                runtime: runtime,
                provider: provider,
                label: "appkit-compositor-warning"
            )
            let view = NSImageView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
            let window = presenterWindow(containing: view)
            let presenter = FoveaAnimatedImageViewPresenter(imageView: view)
            presenter.present(handle: handle, runtime: runtime, initiallyVisible: true)

            try await waitUntilOnMainActor("AppKit compositor activates before warning pressure") {
                presenter.compositorPresentationActiveForTesting
            }
            let pinnedBeforeWarning = await runtime.currentPinnedFrameMemoryCostForTesting()
            XCTAssertGreaterThan(pinnedBeforeWarning, 0)
            _ = await runtime.applyMemoryPressure(.warning)
            try await waitUntilOnMainActor("warning pressure invalidates compositor presentation") {
                !presenter.compositorPresentationActiveForTesting
                    && presenter.compositorRetainedFrameCountForTesting == 0
                    && presenter.presentationDriverPausedForTesting == false
            }
            let residentAtWarning = await runtime.currentFrameCount()
            XCTAssertEqual(residentAtWarning, 2)
            let pinnedAfterWarning = await runtime.currentPinnedFrameMemoryCostForTesting()
            XCTAssertEqual(pinnedAfterWarning, 0)
            let warningSnapshot = await handle.driver.fullyResidentFramesSnapshotForCompositor()
            XCTAssertNil(warningSnapshot)
            XCTAssertNotNil(view.image)

            _ = await runtime.applyMemoryPressure(.normal)
            try await waitUntilOnMainActor("normal pressure reactivates resident compositor") {
                presenter.compositorPresentationActiveForTesting
                    && presenter.compositorRetainedFrameCountForTesting == 2
                    && presenter.presentationDriverPausedForTesting == true
            }
            let pinnedAfterNormal = await runtime.currentPinnedFrameMemoryCostForTesting()
            XCTAssertGreaterThan(pinnedAfterNormal, 0)
            let providerCallsAfterNormal = await provider.callCount()
            XCTAssertEqual(providerCallsAfterNormal, 1)

            presenter.cancel(clearImage: true)
            try await waitUntilOnMainActor("compositor warning handle unregisters") {
                await runtime.registeredDriverCount() == 0
            }
            _ = window
        }

        func
            testAppKitPredecodeCompositorRestartInvalidatesOldTimelineAndResumesStreaming_W5_PT_158()
            async throws
        {
            guard #available(macOS 14.0, *) else { return }
            let runtime = AnimationPlaybackRuntime(frameMemoryCostLimit: 64 * 1024)
            let provider = PresenterAnimationProvider(image: presenterImage(width: 12))
            let handle = try await presenterPredecodeAllLoopingHandle(
                runtime: runtime,
                provider: provider,
                label: "appkit-compositor-restart"
            )
            let view = NSImageView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
            let window = presenterWindow(containing: view)
            let presenter = FoveaAnimatedImageViewPresenter(imageView: view)
            presenter.present(handle: handle, runtime: runtime, initiallyVisible: true)

            try await waitUntilOnMainActor("AppKit compositor activates before restart") {
                presenter.compositorPresentationActiveForTesting
            }
            let beginTimeBeforeRestart = try XCTUnwrap(
                presenter.compositorAnimationBeginTimeForTesting
            )
            try await handle.driver.restart()
            try await waitUntilOnMainActor("restart reanchors resident compositor timeline") {
                presenter.compositorPresentationActiveForTesting
                    && presenter.compositorRetainedFrameCountForTesting == 2
                    && presenter.presentationDriverPausedForTesting == true
            }
            let beginTimeAfterRestart = try XCTUnwrap(
                presenter.compositorAnimationBeginTimeForTesting
            )
            XCTAssertGreaterThan(beginTimeAfterRestart, beginTimeBeforeRestart)
            XCTAssertNotNil(view.image)
            let providerCallsAfterRestart = await provider.callCount()
            XCTAssertEqual(providerCallsAfterRestart, 1)

            presenter.cancel(clearImage: true)
            try await waitUntilOnMainActor("compositor restart handle unregisters") {
                await runtime.registeredDriverCount() == 0
            }
            _ = window
        }

        func testAppKitBoundedFrameCacheDoesNotActivateCompositor_W5_PT_155() async throws {
            guard #available(macOS 14.0, *) else { return }
            let runtime = AnimationPlaybackRuntime(frameMemoryCostLimit: 64 * 1024)
            let provider = PresenterAnimationProvider(image: presenterImage(width: 12))
            let handle = try await presenterLoopingHandle(
                runtime: runtime,
                provider: provider,
                label: "appkit-compositor-bounded-cache"
            )
            let view = FoveaImageView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
            let window = presenterWindow(containing: view)
            view.setAnimation(
                handle: handle,
                runtime: runtime,
                accessibility: .decorative,
                schedulingControl: .platformDefault
            )

            try await waitUntilOnMainActor("bounded-cache animation keeps display link active") {
                view.image != nil && view.animationDisplayLinkPausedForTesting == false
            }
            let providerCalls = await provider.callCount()
            XCTAssertNotEqual(providerCalls, 0)
            XCTAssertEqual(view.animationCompositorPresentationActiveForTesting, false)

            view.cancelAnimation(clearImage: true)
            try await waitUntilOnMainActor("bounded-cache handle unregisters") {
                await runtime.registeredDriverCount() == 0
            }
            _ = window
        }

        func testAppKitPredecodeCompositorTracksLayoutChangesWithoutLeavingFastPath_W5_PT_159()
            async throws
        {
            guard #available(macOS 14.0, *) else { return }
            let runtime = AnimationPlaybackRuntime(frameMemoryCostLimit: 64 * 1024)
            let provider = PresenterAnimationProvider(image: presenterImage(width: 12))
            let handle = try await presenterPredecodeAllLoopingHandle(
                runtime: runtime,
                provider: provider,
                label: "appkit-compositor-layout"
            )
            let view = FoveaImageView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
            let window = presenterWindow(containing: view)
            view.setAnimation(
                handle: handle,
                runtime: runtime,
                accessibility: .decorative,
                schedulingControl: .platformDefault
            )

            try await waitUntilOnMainActor("AppKit compositor activates before layout change") {
                view.animationCompositorPresentationActiveForTesting == true
            }
            let before = try XCTUnwrap(view.animationCompositorLayerFrameForTesting)
            XCTAssertEqual(before.midX, view.bounds.midX, accuracy: 0.001)
            XCTAssertEqual(before.midY, view.bounds.midY, accuracy: 0.001)

            view.frame.size = NSSize(width: 128, height: 128)
            view.layout()
            let after = try XCTUnwrap(view.animationCompositorLayerFrameForTesting)
            XCTAssertEqual(after.midX, view.bounds.midX, accuracy: 0.001)
            XCTAssertEqual(after.midY, view.bounds.midY, accuracy: 0.001)
            XCTAssertEqual(after.size, before.size)
            XCTAssertEqual(view.animationCompositorPresentationActiveForTesting, true)
            XCTAssertEqual(view.animationDisplayLinkPausedForTesting, true)

            view.cancelAnimation(clearImage: true)
            try await waitUntilOnMainActor("compositor layout handle unregisters") {
                await runtime.registeredDriverCount() == 0
            }
            _ = window
        }

        func testAppKitPredecodeCompositorFallsBackWhenImageGeometryPolicyChanges_W5_PT_160()
            async throws
        {
            guard #available(macOS 14.0, *) else { return }
            let runtime = AnimationPlaybackRuntime(frameMemoryCostLimit: 64 * 1024)
            let provider = PresenterAnimationProvider(image: presenterImage(width: 12))
            let handle = try await presenterPredecodeAllLoopingHandle(
                runtime: runtime,
                provider: provider,
                label: "appkit-compositor-geometry-policy"
            )
            let view = FoveaImageView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
            let window = presenterWindow(containing: view)
            view.setAnimation(
                handle: handle,
                runtime: runtime,
                accessibility: .decorative,
                schedulingControl: .platformDefault
            )

            try await waitUntilOnMainActor(
                "AppKit compositor activates before geometry policy change"
            ) {
                view.animationCompositorPresentationActiveForTesting == true
            }
            XCTAssertNotNil(view.image)
            let providerCallsBeforeFallback = await provider.callCount()
            view.imageScaling = .scaleAxesIndependently
            try await waitUntilOnMainActor("unsupported image scaling falls back to streaming") {
                view.animationCompositorPresentationActiveForTesting == false
                    && view.animationDisplayLinkPausedForTesting == false
            }
            XCTAssertNotNil(view.image)
            let pinnedDuringUnsupportedGeometry =
                await runtime.currentPinnedFrameMemoryCostForTesting()
            XCTAssertEqual(pinnedDuringUnsupportedGeometry, 0)

            view.imageScaling = .scaleProportionallyDown
            try await waitUntilOnMainActor("supported image scaling reactivates compositor") {
                view.animationCompositorPresentationActiveForTesting == true
                    && view.animationDisplayLinkPausedForTesting == true
            }
            let providerCallsAfterRestore = await provider.callCount()
            XCTAssertEqual(providerCallsAfterRestore, providerCallsBeforeFallback)
            let pinnedAfterGeometryRestore = await runtime.currentPinnedFrameMemoryCostForTesting()
            XCTAssertGreaterThan(pinnedAfterGeometryRestore, 0)

            view.cancelAnimation(clearImage: true)
            try await waitUntilOnMainActor("compositor geometry-policy handle unregisters") {
                await runtime.registeredDriverCount() == 0
            }
            _ = window
        }

        func testAppKitPredecodeCompositorFallsBackWhenImageFrameStyleChanges_W5_PT_161()
            async throws
        {
            guard #available(macOS 14.0, *) else { return }
            let runtime = AnimationPlaybackRuntime(frameMemoryCostLimit: 64 * 1024)
            let provider = PresenterAnimationProvider(image: presenterImage(width: 12))
            let handle = try await presenterPredecodeAllLoopingHandle(
                runtime: runtime,
                provider: provider,
                label: "appkit-compositor-frame-style"
            )
            let view = FoveaImageView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
            let window = presenterWindow(containing: view)
            view.setAnimation(
                handle: handle,
                runtime: runtime,
                accessibility: .decorative,
                schedulingControl: .platformDefault
            )

            try await waitUntilOnMainActor("AppKit compositor activates before frame-style change")
            {
                view.animationCompositorPresentationActiveForTesting == true
            }
            XCTAssertNotNil(view.image)
            let providerCallsBeforeFallback = await provider.callCount()
            view.imageFrameStyle = .photo
            try await waitUntilOnMainActor("unsupported frame style falls back to streaming") {
                view.animationCompositorPresentationActiveForTesting == false
                    && view.animationDisplayLinkPausedForTesting == false
            }
            XCTAssertNotNil(view.image)
            let pinnedDuringUnsupportedFrameStyle =
                await runtime.currentPinnedFrameMemoryCostForTesting()
            XCTAssertEqual(pinnedDuringUnsupportedFrameStyle, 0)

            view.imageFrameStyle = .none
            try await waitUntilOnMainActor("supported frame style reactivates compositor") {
                view.animationCompositorPresentationActiveForTesting == true
                    && view.animationDisplayLinkPausedForTesting == true
            }
            let providerCallsAfterRestore = await provider.callCount()
            XCTAssertEqual(providerCallsAfterRestore, providerCallsBeforeFallback)
            let pinnedAfterFrameStyleRestore =
                await runtime.currentPinnedFrameMemoryCostForTesting()
            XCTAssertGreaterThan(pinnedAfterFrameStyleRestore, 0)

            view.cancelAnimation(clearImage: true)
            try await waitUntilOnMainActor("compositor frame-style handle unregisters") {
                await runtime.registeredDriverCount() == 0
            }
            _ = window
        }

        func testBenchmarkControlForcesAutomaticDeadlineLoop_W5_PT_145() async throws {
            let runtime = AnimationPlaybackRuntime(frameMemoryCostLimit: 16 * 1024)
            let provider = PresenterAnimationProvider(image: presenterImage(width: 12))
            let handle = try await presenterLoopingHandle(
                runtime: runtime,
                provider: provider,
                label: "appkit-deadline-control"
            )
            let view = FoveaAppKit.FoveaImageView()
            let window = presenterWindow(containing: view)
            view.setAnimation(
                handle: handle,
                runtime: runtime,
                accessibility: .decorative,
                schedulingControl: .automaticDeadlineLoop
            )

            try await waitUntilOnMainActor("AppKit benchmark selects deadline loop") {
                await handle.driver.schedulingModeForTesting() == .automaticDeadlineLoop
            }
            try await waitUntilOnMainActor("AppKit deadline loop runs") {
                await handle.driver.isRunningForTesting()
            }
            XCTAssertNil(view.animationPresentationDiagnostics)

            view.cancelAnimation(clearImage: true)
            try await waitUntilOnMainActor("AppKit deadline control unregisters") {
                await runtime.registeredDriverCount() == 0
            }
            _ = window
        }

        func testBenchmarkRefreshObserverDoesNotDriveDeadlineControl_W5_PT_147() async throws {
            guard #available(macOS 14.0, *) else { return }
            let runtime = AnimationPlaybackRuntime(frameMemoryCostLimit: 16 * 1024)
            let provider = PresenterAnimationProvider(image: presenterImage(width: 12))
            let handle = try await presenterLoopingHandle(
                runtime: runtime,
                provider: provider,
                label: "appkit-refresh-observer"
            )
            let view = FoveaAppKit.FoveaImageView()
            view.animationBenchmarkRefreshSampleHandler = { _, _ in }
            let window = presenterWindow(containing: view)
            view.setAnimation(
                handle: handle,
                runtime: runtime,
                accessibility: .decorative,
                schedulingControl: .automaticDeadlineLoop
            )

            try await waitUntilOnMainActor("deadline control remains automatic") {
                await handle.driver.schedulingModeForTesting() == .automaticDeadlineLoop
            }
            try await waitUntilOnMainActor("refresh observer activates") {
                view.animationDisplayLinkPausedForTesting == false
            }
            let diagnostics = try XCTUnwrap(view.animationPresentationDiagnostics)
            XCTAssertEqual(diagnostics.acceptedTargetCount, 0)
            XCTAssertEqual(diagnostics.consumedTargetCount, 0)
            XCTAssertEqual(diagnostics.supersededPendingTargetCount, 0)
            XCTAssertEqual(diagnostics.rejectedNonmonotonicTargetCount, 0)
            XCTAssertFalse(diagnostics.isDisplayLinkPaused)
            XCTAssertEqual(diagnostics.effectiveVisibility, true)

            view.cancelAnimation(clearImage: true)
            try await waitUntilOnMainActor("refresh observer control unregisters") {
                await runtime.registeredDriverCount() == 0
            }
            _ = window
        }

        func testBenchmarkPresentationHookReportsSourceFrame_W5_PT_146() async throws {
            let runtime = AnimationPlaybackRuntime(frameMemoryCostLimit: 16 * 1024)
            let provider = PresenterAnimationProvider(image: presenterImage(width: 12))
            let handle = try await presenterHandle(
                runtime: runtime,
                provider: provider,
                label: "appkit-benchmark-hook"
            )
            let view = FoveaAppKit.FoveaImageView()
            let recorder = PresenterBenchmarkRecorder()
            view.animationBenchmarkPresentationHandler = { frameIndex, timestamp in
                recorder.record(frameIndex: frameIndex, timestamp: timestamp)
            }
            let window = presenterWindow(containing: view)
            view.setAnimation(
                handle: handle,
                runtime: runtime,
                accessibility: .decorative,
                schedulingControl: .automaticDeadlineLoop
            )

            try await waitUntilOnMainActor("AppKit benchmark hook receives first frame") {
                recorder.events.count == 1
            }
            XCTAssertEqual(recorder.events.map(\.frameIndex), [0])
            XCTAssertGreaterThan(recorder.events[0].timestamp, 0)

            view.cancelAnimation(clearImage: true)
            try await waitUntilOnMainActor("AppKit benchmark hook unregisters") {
                await runtime.registeredDriverCount() == 0
            }
            _ = window
        }

        func testAnimationDoesNoFrameWorkOutsideWindowThenDisplaysOnAttach_W5_PT_068()
            async throws
        {
            let runtime = AnimationPlaybackRuntime(frameMemoryCostLimit: 16 * 1024)
            let provider = PresenterAnimationProvider(image: presenterImage(width: 12))
            let handle = try await presenterHandle(
                runtime: runtime,
                provider: provider,
                label: "offscreen"
            )
            let view = FoveaAppKit.FoveaImageView()
            view.setAnimation(
                handle: handle,
                runtime: runtime,
                accessibility: .decorative
            )
            for _ in 0..<20 { await Task.yield() }
            let offscreenCalls = await provider.callCount()
            XCTAssertEqual(offscreenCalls, 0)
            XCTAssertNil(view.image)

            let window = presenterWindow(containing: view)
            XCTAssertNotNil(view.window)
            try await waitUntilOnMainActor("动画视图进入窗口后显示首帧") {
                presenterPixelWidth(view.image) == 12
            }
            let onscreenCalls = await provider.callCount()
            XCTAssertEqual(onscreenCalls, 1)
            _ = window
            view.cancelAnimation(clearImage: true)
            try await waitUntilOnMainActor("动画视图取消后注销 handle") {
                await runtime.registeredDriverCount() == 0
            }
            XCTAssertNil(view.image)
        }

        func testAnimationVisibilityTracksHiddenAlphaAndAncestor_W5_PT_126()
            async throws
        {
            let runtime = AnimationPlaybackRuntime(frameMemoryCostLimit: 16 * 1024)
            let provider = PresenterAnimationProvider(image: presenterImage(width: 12))
            let handle = try await presenterHandle(
                runtime: runtime,
                provider: provider,
                label: "effective-visibility"
            )
            let view = FoveaAppKit.FoveaImageView(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
            view.setAnimation(
                handle: handle,
                runtime: runtime,
                accessibility: .decorative
            )
            XCTAssertEqual(view.animationVisibilityForTesting, false)

            let window = presenterWindow(containing: view)
            try await waitUntilOnMainActor("attached animation becomes visible") {
                view.animationVisibilityForTesting == true
            }

            view.isHidden = true
            XCTAssertEqual(view.animationVisibilityForTesting, false)
            view.isHidden = false
            XCTAssertEqual(view.animationVisibilityForTesting, true)

            view.alphaValue = 0
            XCTAssertEqual(view.animationVisibilityForTesting, false)
            view.alphaValue = 1
            XCTAssertEqual(view.animationVisibilityForTesting, true)

            window.contentView?.isHidden = true
            view.layoutSubtreeIfNeeded()
            XCTAssertEqual(view.animationVisibilityForTesting, false)
            window.contentView?.isHidden = false
            view.layoutSubtreeIfNeeded()
            XCTAssertEqual(view.animationVisibilityForTesting, true)

            view.cancelAnimation(clearImage: true)
            _ = window
        }

        func testAnimationReplacementRejectsLateOldProviderFrame_W5_PT_069() async throws {
            let runtime = AnimationPlaybackRuntime(frameMemoryCostLimit: 32 * 1024)
            let firstProvider = GatedPresenterAnimationProvider(
                image: presenterImage(width: 12)
            )
            let secondProvider = PresenterAnimationProvider(
                image: presenterImage(width: 24)
            )
            let view = FoveaAppKit.FoveaImageView()
            let window = presenterWindow(containing: view)
            let first = try await presenterHandle(
                runtime: runtime,
                provider: firstProvider,
                label: "old"
            )
            view.setAnimation(
                handle: first,
                runtime: runtime,
                accessibility: .decorative
            )
            await firstProvider.waitUntilStarted()

            let second = try await presenterHandle(
                runtime: runtime,
                provider: secondProvider,
                label: "new"
            )
            view.setAnimation(
                handle: second,
                runtime: runtime,
                accessibility: .decorative
            )
            try await waitUntilOnMainActor("替代动画显示新帧") {
                presenterPixelWidth(view.image) == 24
            }
            await firstProvider.release()
            try await testSleep(.milliseconds(20))
            XCTAssertEqual(presenterPixelWidth(view.image), 24)
            let firstCancelCount = await firstProvider.cancelCount()
            XCTAssertEqual(firstCancelCount, 1)
            _ = window
            view.cancelAnimation(clearImage: true)
        }

        func testStaticImageRequestCancelsAnimationAndPreventsLateOverwrite_W5_PT_070()
            async throws
        {
            let runtime = AnimationPlaybackRuntime(frameMemoryCostLimit: 32 * 1024)
            let animationProvider = GatedPresenterAnimationProvider(
                image: presenterImage(width: 12)
            )
            let view = FoveaAppKit.FoveaImageView()
            let window = presenterWindow(containing: view)
            let handle = try await presenterHandle(
                runtime: runtime,
                provider: animationProvider,
                label: "static-replacement"
            )
            view.setAnimation(
                handle: handle,
                runtime: runtime,
                accessibility: .decorative
            )
            await animationProvider.waitUntilStarted()

            let staticImage = presenterImage(width: 30)
            view.setImage(
                request: try presenterRequest(width: 30),
                loader: PresenterStaticLoader(image: staticImage),
                accessibility: .decorative,
                placeholderDelayNanoseconds: 0
            )
            try await waitUntilOnMainActor("静态图替换动画") {
                presenterPixelWidth(view.image) == 30
            }
            await animationProvider.release()
            try await testSleep(.milliseconds(20))
            XCTAssertEqual(presenterPixelWidth(view.image), 30)
            let cancelCount = await animationProvider.cancelCount()
            XCTAssertEqual(cancelCount, 1)
            _ = window
        }

        func testRemovingAnimatedViewPausesWithoutCancellingHandle_W5_PT_072() async throws {
            let runtime = AnimationPlaybackRuntime(frameMemoryCostLimit: 16 * 1024)
            let provider = PresenterAnimationProvider(image: presenterImage(width: 20))
            let view = FoveaAppKit.FoveaImageView()
            let window = presenterWindow(containing: view)
            let handle = try await presenterHandle(
                runtime: runtime,
                provider: provider,
                label: "window-pause"
            )
            view.setAnimation(
                handle: handle,
                runtime: runtime,
                accessibility: .decorative
            )
            try await waitUntilOnMainActor("窗口内动画显示") {
                presenterPixelWidth(view.image) == 20
            }

            view.removeFromSuperview()
            try await waitUntilOnMainActor("动画视图离开窗口") { view.window == nil }
            for _ in 0..<20 { await Task.yield() }
            let registeredWhileHidden = await runtime.registeredDriverCount()
            let cancelCountWhileHidden = await provider.cancelCount()
            XCTAssertEqual(registeredWhileHidden, 1)
            XCTAssertEqual(cancelCountWhileHidden, 0)
            XCTAssertEqual(presenterPixelWidth(view.image), 20)

            window.contentView?.addSubview(view)
            try await waitUntilOnMainActor("动画视图重新进入窗口") { view.window != nil }
            let callCountAfterReattach = await provider.callCount()
            XCTAssertEqual(callCountAfterReattach, 1)
            view.prepareForReuse()
        }

        func testLiveMJPEGOutsideWindowDecodesLatestOnlyAfterAttach_W5_PT_084() async throws {
            let source = PresenterLiveSource()
            let decoder = PresenterLiveDecoder()
            let session = MultipartJPEGLivePlaybackSession(
                stream: source.stream,
                decoder: decoder,
                policy: MultipartJPEGLivePlaybackPolicy(
                    minimumFrameIntervalNanoseconds: 1
                ),
                clock: PresenterConstantClock()
            )
            let view = FoveaAppKit.FoveaImageView()
            view.setLiveMultipartJPEG(
                session: session,
                accessibility: .decorative
            )
            source.yield(MultipartJPEGPart(index: 0, data: Data([0xff, 0xd8, 0xff, 0xd9])))
            source.yield(MultipartJPEGPart(index: 1, data: Data([0xff, 0xd8, 0xff, 0xd9])))
            for _ in 0..<20 { await Task.yield() }
            let hiddenIndices = await decoder.indices()
            XCTAssertEqual(hiddenIndices, [])
            XCTAssertNil(view.image)

            let window = presenterWindow(containing: view)
            try await waitUntilOnMainActor("live MJPEG attach displays latest") {
                presenterPixelWidth(view.image) == 3
            }
            let visibleIndices = await decoder.indices()
            XCTAssertEqual(visibleIndices, [1])
            _ = window
            view.cancelAnimation(clearImage: true)
        }

        func testStaticRequestCancelsLiveMJPEGAndRejectsLateFrame_W5_PT_085() async throws {
            let source = PresenterLiveSource()
            let decoder = GatedPresenterLiveDecoder()
            let session = MultipartJPEGLivePlaybackSession(
                stream: source.stream,
                decoder: decoder,
                policy: MultipartJPEGLivePlaybackPolicy(
                    minimumFrameIntervalNanoseconds: 1
                ),
                clock: PresenterConstantClock()
            )
            let view = FoveaAppKit.FoveaImageView()
            let window = presenterWindow(containing: view)
            view.setLiveMultipartJPEG(
                session: session,
                accessibility: .decorative
            )
            source.yield(MultipartJPEGPart(index: 0, data: Data([0xff, 0xd8, 0xff, 0xd9])))
            await decoder.waitUntilStarted()

            view.setImage(
                request: try presenterRequest(width: 30),
                loader: PresenterStaticLoader(image: presenterImage(width: 30)),
                accessibility: .decorative,
                placeholderDelayNanoseconds: 0
            )
            try await waitUntilOnMainActor("static replaces live MJPEG") {
                presenterPixelWidth(view.image) == 30
            }
            await decoder.release()
            try await testSleep(.milliseconds(20))
            XCTAssertEqual(presenterPixelWidth(view.image), 30)
            let snapshot = await session.snapshotForTesting()
            XCTAssertTrue(snapshot.isCancelled)
            _ = window
        }

        func testRegisteredLiveHandleUsesRuntimeLifecycleInImageView_W5_PT_093() async throws {
            let runtime = AnimationPlaybackRuntime(frameMemoryCostLimit: 16 * 1024)
            let source = PresenterLiveSource()
            let decoder = PresenterLiveDecoder()
            let session = MultipartJPEGLivePlaybackSession(
                stream: source.stream,
                decoder: decoder,
                policy: MultipartJPEGLivePlaybackPolicy(
                    minimumFrameIntervalNanoseconds: 1
                ),
                clock: PresenterConstantClock()
            )
            let handle = try await runtime.registerLiveSession(session)
            let view = FoveaAppKit.FoveaImageView()
            view.setLiveMultipartJPEG(
                handle: handle,
                accessibility: .decorative
            )
            source.yield(MultipartJPEGPart(index: 0, data: Data([0xff, 0xd8, 0xff, 0xd9])))
            source.yield(MultipartJPEGPart(index: 1, data: Data([0xff, 0xd8, 0xff, 0xd9])))
            for _ in 0..<20 { await Task.yield() }
            let hiddenIndices = await decoder.indices()
            XCTAssertEqual(hiddenIndices, [])
            let registeredHidden = await runtime.registeredLiveSessionCount()
            XCTAssertEqual(registeredHidden, 1)

            let window = presenterWindow(containing: view)
            try await waitUntilOnMainActor("registered live handle displays latest") {
                presenterPixelWidth(view.image) == 3
            }
            let visibleIndices = await decoder.indices()
            XCTAssertEqual(visibleIndices, [1])

            view.cancelAnimation(clearImage: true)
            try await waitUntilOnMainActor("registered live handle unregisters") {
                await runtime.registeredLiveSessionCount() == 0
            }
            XCTAssertNil(view.image)
            _ = window
        }

        func testPrepareForReuseCancelsAnimationAndClearsPixels_W5_PT_071() async throws {
            let runtime = AnimationPlaybackRuntime(frameMemoryCostLimit: 16 * 1024)
            let provider = PresenterAnimationProvider(image: presenterImage(width: 18))
            let view = FoveaAppKit.FoveaImageView()
            let window = presenterWindow(containing: view)
            let handle = try await presenterHandle(
                runtime: runtime,
                provider: provider,
                label: "reuse"
            )
            view.setAnimation(
                handle: handle,
                runtime: runtime,
                accessibility: .label("动态图")
            )
            try await waitUntilOnMainActor("复用前动画显示") {
                presenterPixelWidth(view.image) == 18
            }

            view.prepareForReuse()
            XCTAssertNil(view.image)
            try await waitUntilOnMainActor("复用取消动画 handle") {
                await runtime.registeredDriverCount() == 0
            }
            XCTAssertNil(view.accessibilityLabel())
            _ = window
        }
    }
#endif

private struct PresenterLiveSource: Sendable {
    let stream: AsyncThrowingStream<MultipartJPEGPart, any Error>
    private let continuation: AsyncThrowingStream<MultipartJPEGPart, any Error>.Continuation

    init() {
        let pair = AsyncThrowingStream<MultipartJPEGPart, any Error>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
    }

    func yield(_ part: MultipartJPEGPart) { continuation.yield(part) }
}

private actor PresenterLiveDecoder: MultipartJPEGFrameDecoding {
    private var decoded: [Int] = []
    func decode(_ part: MultipartJPEGPart) -> DecodedImage {
        decoded.append(part.index)
        return presenterImage(width: part.index + 2)
    }
    func indices() -> [Int] { decoded }
}

private actor GatedPresenterLiveDecoder: MultipartJPEGFrameDecoding {
    private var startedWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    private var hasStarted = false
    private var isReleased = false

    func decode(_ part: MultipartJPEGPart) async -> DecodedImage {
        hasStarted = true
        startedWaiter?.resume()
        startedWaiter = nil
        if !isReleased {
            await withCheckedContinuation { releaseWaiter = $0 }
        }
        return presenterImage(width: part.index + 12)
    }

    func waitUntilStarted() async {
        if hasStarted { return }
        await withCheckedContinuation { startedWaiter = $0 }
    }

    func release() {
        isReleased = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private struct PresenterStaticLoader: ImageLoading {
    let image: DecodedImage
    func image(for _: ImageRequest) async throws -> DecodedImage { image }
}

private actor PresenterAnimationProvider: AnimationFrameProvider {
    private let image: DecodedImage
    private var calls = 0
    private var cancellations = 0
    private var ranges: [Range<Int>] = []

    init(image: DecodedImage) { self.image = image }

    func frames(in range: Range<Int>) -> [AnimationProviderFrame] {
        calls += 1
        ranges.append(range)
        return range.map { AnimationProviderFrame(index: $0, image: image) }
    }

    func cancel() { cancellations += 1 }
    func callCount() -> Int { calls }
    func cancelCount() -> Int { cancellations }
    func requestedRanges() -> [Range<Int>] { ranges }
}

private actor GatedPresenterAnimationProvider: AnimationFrameProvider {
    private let image: DecodedImage
    private var started = false
    private var released = false
    private var cancellations = 0
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    init(image: DecodedImage) { self.image = image }

    func frames(in range: Range<Int>) async -> [AnimationProviderFrame] {
        started = true
        for waiter in startedWaiters { waiter.resume() }
        startedWaiters.removeAll(keepingCapacity: false)
        if !released {
            await withCheckedContinuation { releaseWaiters.append($0) }
        }
        return range.map { AnimationProviderFrame(index: $0, image: image) }
    }

    func cancel() { cancellations += 1 }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startedWaiters.append($0) }
    }

    func release() {
        released = true
        for waiter in releaseWaiters { waiter.resume() }
        releaseWaiters.removeAll(keepingCapacity: false)
    }

    func cancelCount() -> Int { cancellations }
}

private func presenterHandle<Provider: AnimationFrameProvider>(
    runtime: AnimationPlaybackRuntime,
    provider: Provider,
    label: String
) async throws -> AnimationPlaybackHandle {
    let decodeKey = try XCTUnwrap(
        AnimationDecodeKey(
            contentID: ContentID(data: Data("presenter-\(label)".utf8)),
            target: TargetPixels(width: 64, height: 64),
            contentMode: .fit,
            colorPolicy: .convertToSRGB,
            codecFingerprint: "presenter-provider-v1",
            animationPolicyVersion: 1,
            timingPolicyVersion: 1,
            frameStrategy: .boundedFrameCache
        )
    )
    let timeline = try AnimationPlaybackTimeline(
        frameDurationsNanoseconds: [10],
        additionalRepeatCount: nil,
        zeroDurationReplacementNanoseconds: 1,
        timingPolicyVersion: 1
    )
    return try await runtime.makeHandle(
        namespace: SecurityNamespaceID("presenter-account"),
        generation: NamespaceGeneration(1),
        decodeKey: decodeKey,
        timeline: timeline,
        playbackPolicy: AnimationPlaybackPolicy(requestedMode: .firstFrame),
        reduceMotionEnabled: false,
        provider: provider,
        windowPolicy: AnimationFrameWindowPolicy(
            normalFrameCount: 1,
            warningFrameCount: 1
        ),
        clock: PresenterConstantClock()
    )
}

private func presenterLoopingHandle<Provider: AnimationFrameProvider>(
    runtime: AnimationPlaybackRuntime,
    provider: Provider,
    label: String
) async throws -> AnimationPlaybackHandle {
    let decodeKey = try XCTUnwrap(
        AnimationDecodeKey(
            contentID: ContentID(data: Data("presenter-loop-\(label)".utf8)),
            target: TargetPixels(width: 64, height: 64),
            contentMode: .fit,
            colorPolicy: .convertToSRGB,
            codecFingerprint: "presenter-loop-provider-v1",
            animationPolicyVersion: 1,
            timingPolicyVersion: 1,
            frameStrategy: .boundedFrameCache
        )
    )
    let timeline = try AnimationPlaybackTimeline(
        frameDurationsNanoseconds: [100_000_000, 100_000_000],
        additionalRepeatCount: nil,
        zeroDurationReplacementNanoseconds: 1,
        timingPolicyVersion: 1
    )
    return try await runtime.makeHandle(
        namespace: SecurityNamespaceID("presenter-account"),
        generation: NamespaceGeneration(1),
        decodeKey: decodeKey,
        timeline: timeline,
        playbackPolicy: AnimationPlaybackPolicy(requestedMode: .normal),
        reduceMotionEnabled: false,
        provider: provider,
        windowPolicy: AnimationFrameWindowPolicy(
            normalFrameCount: 2,
            warningFrameCount: 1
        )
    )
}

private func presenterPredecodeAllLoopingHandle<Provider: AnimationFrameProvider>(
    runtime: AnimationPlaybackRuntime,
    provider: Provider,
    label: String
) async throws -> AnimationPlaybackHandle {
    let decodeKey = try XCTUnwrap(
        AnimationDecodeKey(
            contentID: ContentID(data: Data("presenter-predecode-\(label)".utf8)),
            target: TargetPixels(width: 64, height: 64),
            contentMode: .fit,
            colorPolicy: .convertToSRGB,
            codecFingerprint: "presenter-predecode-provider-v1",
            animationPolicyVersion: 1,
            timingPolicyVersion: 1,
            frameStrategy: .predecodeAll
        )
    )
    let timeline = try AnimationPlaybackTimeline(
        frameDurationsNanoseconds: [100_000_000, 100_000_000],
        additionalRepeatCount: nil,
        zeroDurationReplacementNanoseconds: 1,
        timingPolicyVersion: 1
    )
    return try await runtime.makeHandle(
        namespace: SecurityNamespaceID("presenter-account"),
        generation: NamespaceGeneration(1),
        decodeKey: decodeKey,
        timeline: timeline,
        playbackPolicy: AnimationPlaybackPolicy(requestedMode: .normal),
        reduceMotionEnabled: false,
        provider: provider,
        windowPolicy: AnimationFrameWindowPolicy(
            normalFrameCount: 2,
            warningFrameCount: 1
        ),
        maximumPredecodeAllFrameCount: 2
    )
}

private func presenterFinitePredecodeAllHandle<Provider: AnimationFrameProvider>(
    runtime: AnimationPlaybackRuntime,
    provider: Provider,
    label: String,
    frameDurationsNanoseconds: [UInt64] = [1_000_000_000, 1_000_000_000],
    additionalRepeatCount: UInt32 = 1
) async throws -> AnimationPlaybackHandle {
    let decodeKey = try XCTUnwrap(
        AnimationDecodeKey(
            contentID: ContentID(data: Data("presenter-finite-predecode-\(label)".utf8)),
            target: TargetPixels(width: 64, height: 64),
            contentMode: .fit,
            colorPolicy: .convertToSRGB,
            codecFingerprint: "presenter-finite-predecode-provider-v1",
            animationPolicyVersion: 1,
            timingPolicyVersion: 1,
            frameStrategy: .predecodeAll
        )
    )
    let timeline = try AnimationPlaybackTimeline(
        frameDurationsNanoseconds: frameDurationsNanoseconds,
        additionalRepeatCount: additionalRepeatCount,
        zeroDurationReplacementNanoseconds: 1,
        timingPolicyVersion: 1
    )
    return try await runtime.makeHandle(
        namespace: SecurityNamespaceID("presenter-account"),
        generation: NamespaceGeneration(1),
        decodeKey: decodeKey,
        timeline: timeline,
        playbackPolicy: AnimationPlaybackPolicy(requestedMode: .normal),
        reduceMotionEnabled: false,
        provider: provider,
        windowPolicy: AnimationFrameWindowPolicy(
            normalFrameCount: 2,
            warningFrameCount: 1
        ),
        maximumPredecodeAllFrameCount: 2
    )
}

private func presenterAutomaticPredecodeAllLoopingHandle<Provider: AnimationFrameProvider>(
    runtime: AnimationPlaybackRuntime,
    provider: Provider,
    label: String
) async throws -> AnimationPlaybackHandle {
    let decodeKey = try XCTUnwrap(
        AnimationDecodeKey(
            contentID: ContentID(data: Data("presenter-auto-predecode-\(label)".utf8)),
            target: TargetPixels(width: 64, height: 64),
            contentMode: .fit,
            colorPolicy: .convertToSRGB,
            codecFingerprint: "presenter-auto-predecode-provider-v1",
            animationPolicyVersion: 1,
            timingPolicyVersion: 1,
            frameStrategy: .predecodeAll
        )
    )
    let timeline = try AnimationPlaybackTimeline(
        frameDurationsNanoseconds: [100_000_000, 100_000_000],
        additionalRepeatCount: nil,
        zeroDurationReplacementNanoseconds: 1,
        timingPolicyVersion: 1
    )
    return try await runtime.makeHandle(
        namespace: SecurityNamespaceID("presenter-account"),
        generation: NamespaceGeneration(1),
        decodeKey: decodeKey,
        timeline: timeline,
        playbackPolicy: AnimationPlaybackPolicy(requestedMode: .normal),
        reduceMotionEnabled: false,
        provider: provider,
        windowPolicy: AnimationFrameWindowPolicy(
            normalFrameCount: 2,
            warningFrameCount: 1
        ),
        maximumPredecodeAllFrameCount: 2,
        automaticWholeTrackDecodedByteCostUpperBound: 2_048,
        providerRetainedByteCost: 0,
        automaticWholeTrackPredecodePeakByteCost: 4_096
    )
}

private struct PresenterConstantClock: AnimationPlaybackClock {
    func nowNanoseconds() async -> UInt64 { 0 }
    func sleep(untilNanoseconds _: UInt64) async throws { throw CancellationError() }
}

private func presenterRequest(width: Int) throws -> ImageRequest {
    try ImageRequest.publicImage(
        url: XCTUnwrap(URL(string: "https://example.test/presenter-static-\(width).png")),
        target: TargetPixels(width: width, height: width),
        appID: "animated-presenter-tests"
    )
}

private func presenterImage(width: Int) -> DecodedImage {
    let height = width
    let bytesPerRow = width * 4
    let data = Data(repeating: UInt8(width & 0xff), count: bytesPerRow * height)
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

#if canImport(AppKit)
    @MainActor
    private final class PresenterBenchmarkRecorder {
        struct Event {
            let frameIndex: Int
            let timestamp: UInt64
        }

        private(set) var events: [Event] = []

        func record(frameIndex: Int, timestamp: UInt64) {
            events.append(Event(frameIndex: frameIndex, timestamp: timestamp))
        }
    }

    @MainActor
    private func presenterWindow(containing view: NSView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = NSView(frame: window.contentView?.bounds ?? .zero)
        if view.frame.isEmpty { view.frame = window.contentView?.bounds ?? .zero }
        window.contentView?.addSubview(view)
        return window
    }

    private func presenterPixelWidth(_ image: NSImage?) -> Int? {
        image?.representations.compactMap { representation in
            representation.pixelsWide > 0 ? representation.pixelsWide : nil
        }.max()
    }
#endif
