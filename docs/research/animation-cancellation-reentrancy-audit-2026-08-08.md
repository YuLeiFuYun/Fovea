# Animation cancellation / actor-reentrancy audit — 2026-08-08

Status: local production liveness defect reproduced, causally isolated, repaired, and stress-regressed. This is not physical-device timing/energy evidence and does not close the remaining animation structural debt.

## Core question

The relevant concurrency question is not whether `AnimationPlaybackCoordinator` is an actor. Actor isolation prevents simultaneous actor-isolated execution, but Swift actors are reentrant across suspension points. The actual requirement is stronger:

> once cancellation or publication-generation invalidation wins, can an older suspended `produce` invocation resume and create new provider/decode/permit work from state it captured before the `await`?

Before this repair, the answer was yes.

## Language-level premise

Swift Evolution SE-0306 states that actor-isolated functions are reentrant: when one suspends, other actor work may execute before it resumes, and actor-isolated state can therefore change across an `await`. The same proposal says every suspension point must be inspected when code after it depends on invariants established before suspension. Primary source:

- https://github.com/swiftlang/swift-evolution/blob/main/proposals/0306-actors.md#actor-reentrancy

SE-0392 also explicitly notes that `SerialExecutor` does not provide non-reentrant actor semantics. Customizing the executor would therefore not make a pre-`await` cancellation/generation observation linearizable by itself:

- https://github.com/swiftlang/swift-evolution/blob/main/proposals/0392-custom-actor-executors.md

The Fovea repair consequently preserves reentrant actors and validates the publication invariant after suspension rather than trying to replace Swift's execution model.

## Reproduction

The original retained regression `W5-PT-175` constructs two automatic whole-track starts under a weighted predecode-peak pool of 192 bytes-equivalent units. The first start holds 128 units inside a suspending provider; the second also needs 128 and therefore queues. Cancellation of the second handle must remove that queued work before its provider is called.

During full root-suite execution, the same candidate hung twice at:

`AnimationPlaybackRuntimeTests.testQueuedAutomaticWholeTrackPeakPermitCancelsBeforeProvider_W5_PT_175`

The XCTest process was at 0% CPU in a waiter for more than two minutes, while isolated execution of PT175 could pass in roughly 7–12 ms. This isolated/full-suite split pointed to a scheduling-sensitive actor-reentrancy race rather than a deterministic weighted-permit implementation failure.

## Causal failure mode

`AnimationPlaybackCoordinator.produce()` captured `publicationGeneration`, then suspended while asking the session for work, a cached frame, and automatic whole-track admission state.

The failing interleaving was:

1. `produce()` captures generation `g`.
2. `produce()` suspends on a cross-actor session call before assigning `automaticWholeTrackPredecodeTask`.
3. `cancel()` re-enters the coordinator, sets `isCancelled`, advances the publication generation to `g+1`, and attempts to cancel the current predecode task.
4. No predecode task exists yet, so there is nothing to cancel.
5. The stale `produce()` resumes with facts obtained from generation `g`.
6. The old implementation did not revalidate `isCancelled` / `publicationGeneration` after those suspension points and created a new weighted predecode task after cancellation had already won.
7. That newly created task waited behind the first request's 128/192 peak reservation. PT175 awaited the second start before releasing the first provider, producing a liveness cycle.

This is an actor-level time-of-check/time-of-use defect. The actor never executed two isolated fragments concurrently; the invariant was invalidated by legal interleaving across `await`.

## Fast falsifier

`W5-PT-205` is a schedule-search regression designed not to hang even when the bug exists.

For delays `0..<64` it:

- lets the first provider hold 128 of 192 peak units;
- starts a second request needing 128 units;
- varies the number of `Task.yield()` calls before cancelling the second handle;
- immediately releases the first provider after cancellation, so any stale queued work can proceed and fail an assertion instead of deadlocking the test;
- requires the second provider call count to remain zero;
- requires exactly one provider cancellation;
- requires peak used units and queued requests to both return to zero.

Before the production fix, this test failed in under one second at `delay=17`: the second provider was called once after the handle had been cancelled. That converts the intermittent full-suite hang into a fast deterministic counterexample search.

## Repair

`AnimationPlaybackCoordinator` now executes a synchronous `requireCurrentPublication(generation)` check after the cross-actor cached-frame lookup and again after the cross-actor automatic-admission query, before it may create automatic predecode work.

The check requires both:

- the coordinator is not cancelled; and
- the captured generation still equals the current `publicationGeneration`.

There is no suspension between the second revalidation and creation/assignment of the automatic predecode task. Therefore cancellation has two safe linearization regions:

- if cancellation wins before the revalidation, stale `produce` fails before creating new work;
- if cancellation wins after the revalidation/task assignment, the existing `advancePublicationGeneration()` path can see and cancel that assigned task.

The repair does not replace the weighted permit pool, bypass provider cancellation, weaken frame-memory accounting, or make the actor non-reentrant.

## Evidence

- `W5-PT-175`: queued automatic whole-track peak permit cancels before provider.
- `W5-PT-205`: 64-delay schedule search for cancellation/publication invalidation racing predecode creation.
- `AnimationPlaybackRuntimeTests`: 24/24 after the fix.
- three consecutive strict root runs: each 756/756, zero failures, approximately 20.2–21.8 seconds per run; retained log: `.project-local/animation-cancel-root-stress-20260808.log`.
- workflow controller independently ran the task's authorized root `swift test` and accepted `task-animation-cancel-reentrancy-liveness`.

The new test also verifies provider cancellation count and weighted-peak used/queued counts, so a "returns eventually but leaks permit/provider work" implementation still fails.

## General rule retained for Fovea

For actor-isolated asynchronous methods, a generation/cancellation/authorization observation made before an `await` is not authority for creating or publishing work after that `await`. If post-suspension code depends on that invariant, it must either:

1. revalidate the invariant after the suspension and before the side effect; or
2. move the invariant-sensitive state transition into one synchronous actor critical section.

This applies beyond animation to namespace revocation, request authorization, publication generations, cache aliases, and other "cancel/revoke then no new work" contracts.

## Remaining animation blockers

This repair closes the reproduced cancellation TOCTOU; it does not make the animation area release-ready by itself. Remaining local structural gates include the oversized `FoveaAnimatedImageViewPresenter`, `AnimationPlaybackRuntime`, and `AnimationPlaybackDriver`, plus the broader FoveaCore module file-count/source-share debt and existing reviewed `AnimationFrameMemory` unchecked-Sendable boundary. Physical-device timing, energy and thermal evidence also remain separate.
