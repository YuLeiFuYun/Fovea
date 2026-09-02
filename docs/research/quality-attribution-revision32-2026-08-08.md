# Revision 32 quality attribution and candidate authority audit

> Status: local current-candidate evidence. This audit does not certify release readiness or merge readiness.

## Why revision 32 existed

The conservative legacy candidate migration deliberately starts candidate authority at the migration-time Git `HEAD` tree instead of pretending that the original long-running dirty baseline can be reconstructed. That keeps current tracked modifications and reviewable untracked files visible. It also means a whole-worktree maintainability scan contains two causally different populations: paths changed by this workflow's committed transactions and reviewable dirty paths owned by other work.

Revision 32 makes that distinction mechanical. Local function/module quality failures are charged to this change only when the path is present in a `COMMITTED` transaction journal for the active change. Unowned reviewable source drift remains visible in the raw quality analysis and remains a candidate-authority blocker. When unowned source drift exists, aggregate whole-project regressions are retained as raw audit data but are not attributed to this change because their causal contribution cannot be separated from the external drift using retained aggregate summaries.

This is not an exemption for external work. Candidate authority independently requires complete traceability for every baseline-to-current reviewable path before merge readiness.

## Candidate and quality epoch

The retained candidate baseline has provenance `legacy_git_head_conservative`, is bound to Git commit `9137539f6222e7c3fa0ff098d531c3b45917b3c2`, and has snapshot digest `6af24974105795940e9941f362038cfb0fb56231fecb27530fb72b943a834b51`. The quality baseline was subsequently rebound to the same candidate-baseline snapshot and Git tree using Git object bytes rather than dirty working-tree bytes.

Before the final continuity patch, the current candidate projection reported:

- 372 baseline-to-current reviewable changed paths;
- 98 transaction-projected traced paths;
- 332 untraced changed paths;
- 58 stale historical trace paths;
- 924 current reviewable files.

These counts are a pre-continuity snapshot. Applying this audit creates one additional workflow-owned reviewable path, so the final merge report must recompute rather than copy these numbers. The important invariant is unchanged: hundreds of untraced reviewable paths remain, so merge readiness must stay fail-closed even if functional verification and attributed quality are green.

## Attributed maintainability repair

Before revision-32 refactoring, the current quality analyzer reported 216 raw violations with score 553. Transaction attribution reduced the active change's actionable set to eight complexity violations with score 24. The remaining raw violations were on unowned reviewable source paths or aggregate metrics contaminated by such drift.

The two controller-owned refactor tasks repaired only the eight attributed functions:

| Path / function | Before | After |
| --- | ---: | ---: |
| `AnimationPlaybackCoordinator.decodeAndPublish` | 11 | 9 |
| `PipelineFailure.imageCraftFailure` | 16 | 8 |
| `PipelineProgressivePreview.consume` | 13 | 10 |
| `assert_complete_output_contract` | 14 | 4 |
| `assert_progressive_output_contract` | 13 | 4 |
| `DerivedRasterRuntime.reason` | 12 | 10 |
| `AkashicDerivedRasterStore.trimIfNeeded` | 15 | 2 |
| `DerivedRasterRecord.isValidPersistentRecord` | 16 | 8 |

No quality threshold was increased. The refactors reuse or extract existing invariants: publication-generation validation, codec error classification predicates, progressive generation/finalization helpers, data-driven model conditions, derived-raster reason grouping, alias-aware trim helpers, and grouped persistent-record predicates.

After both controller-accepted patches, the same current-candidate analysis reports:

- raw quality: 207 violations, score 526;
- transaction-attributed quality: 0 violations, score 0, passed;
- unattributed raw violations: 207;
- unowned changed source paths: 245;
- aggregate quality regressions: causally indeterminate while that unowned source drift remains.

The raw count is intentionally not normalized to zero. Those paths are outside this workflow task's ownership and remain subject to their own quality/traceability work.

## Functional evidence

The codec/animation refactor was locally falsified against focused behavior before controller submission:

- `AnimationPlaybackCoordinatorTests`: 11/11;
- `AnimationPlaybackRuntimeTests`: 24/24, including the cancellation/reentrancy regressions retained by W5;
- `ImageDecoderTests`: 33/33;
- `ProgressiveImageLoadingTests`: 15/15 after formatting;
- `PipelineFailureTests`: 13/13.

The codec finite model remained unchanged in its enumerated evidence domain: capability 2304, progressive-format coupling 2, generation 262144, resource 49, complete-output 60, progressive-output 30, timing 25, errors 0. Mathematical proof obligations remained 14 targets / 16 obligations / 14 covered / 0 errors.

The derived-raster refactor passed the aggregate `DerivedRaster` SwiftPM selection: 47/47. This includes the existing deterministic eviction, shared-alias, recent-use second-chance, durable write-budget, reopen, corruption and publication-fence cases. In particular, the refactor did not replace the two-stage recently-used eviction policy or the overflow/storage-unavailable semantics.

Each code task was then applied transactionally by the workflow controller and independently verified with the authorized root `swift test` command:

- `task-quality-codec-animation-refactor`: exit 0, 38.492001 seconds, root XCTest 756/756 with zero failures;
- `task-quality-derived-refactor`: exit 0, 40.749932 seconds, root XCTest 756/756 with zero failures.

The revision-31 strict stress evidence remains separate: three consecutive strict root runs previously passed 756/756. Revision 32 does not relabel ordinary controller `swift test` runs as strict runs.

## Current trace, documentation and formal gates

Before this continuity patch:

- project test traceability: 455/455 implemented, 0 missing;
- codec finite model: capability 2304 / progressive-format 2 / generation 262144 / resource 49 / complete-output 60 / progressive-output 30 / timing 25 / errors 0;
- mathematical proof obligations: 14 targets / 16 obligations / 14 covered / 0 errors;
- project memory integrity: sources 12 / discussions 10 / requirements 9 / phases 10 / open obligations 19 before revision-32 continuity updates.

The full `scripts/verify-documentation.py` run is not green in the current environment. It exits 65 while Xcode documentation build dependency scanning cannot resolve `AppKit` for `FoveaAnimationMacLab-product`. Root SwiftPM tests are green, so this audit records the documentation-build failure as a separate environment/toolchain blocker rather than converting it into a product-source failure or hiding it behind static Markdown checks.

The workflow-bundle changes that support conservative legacy candidate/quality epochs and transaction-owned quality attribution pass the targeted regression suites and the non-pytest privacy/repository/version/identity/refinement/mathematical gates. A latest-tree full development-gate claim is intentionally not made: parallel resource-admission work can defer test-internal high-risk lifecycle commands for up to the configured host-pressure admission window on the shared machine.

## Claim boundary

Revision 32 closes only the maintainability debt attributable to this workflow's committed paths. It does not close:

- the hundreds of current untraced reviewable candidate paths;
- structural debt in unowned animation/tooling paths;
- the immutable Release/format environment blockers already recorded elsewhere;
- physical-device, energy, thermal, hosted-CI or publication evidence;
- progressive pre-decode codec peak-resource admission;
- a second production codec or AVIF/JPEG XL format-contract evolution;
- the current Xcode documentation-build `AppKit` dependency-scan failure.

Final verification must bind the exact post-continuity candidate and recompute candidate authority. A green functional/quality verification is necessary but cannot by itself make this dirty multi-owner workspace merge-ready.

## Revision 33: PT175 queued-permit oracle determinism

Revision 32's frozen candidate verification produced a useful counterexample after the transaction-attributed quality gate had already passed. The first authorized root wave, `swift:test`, passed 756/756 with exit 0 in 30.684934 seconds. The second authorized root wave, `swift:full`, failed 1/756 with exit 1 in 31.819995 seconds at `AnimationPlaybackRuntimeTests.testQueuedAutomaticWholeTrackPeakPermitCancelsBeforeProvider_W5_PT_175`, where `AnimationPlaybackRuntime.start` reported `AnimationPlaybackRuntimeError.invalidRegistration`.

This failure was distinct from the earlier production actor-reentrancy cancellation defect. PT175 created the second start task, executed a fixed twenty `Task.yield()` calls, and then cancelled the handle. Under the failing suite schedule, cancellation won before the second start had actually entered the intended weighted-permit queue. The resulting missing registration was therefore a legitimate outcome of the test setup, not evidence that production had recreated work after cancellation. Treating `invalidRegistration` as an accepted result would have weakened PT175 because the test specifically intends to cancel work that is already queued.

Revision 33 changed only `Tests/FoveaTests/AnimationPlaybackRuntimeTests.swift`. The oracle now waits until the runtime mechanically reports one queued automatic whole-track predecode peak permit, asserts the expected 128 used units, and only then performs cancellation. It does not accept `invalidRegistration`, and it does not change production code.

The strengthened test passed:

- isolated PT175: 1/1;
- full `AnimationPlaybackRuntimeTests`: 24/24, including W5_PT_205;
- twenty independent `--skip-build` PT175 repetitions: 20/20;
- three strict root runs: 756/756 each, with XCTest durations 21.738, 22.333 and 22.375 seconds;
- workflow-controller independent root verification: 756/756, exit 0, 27.753754 seconds.

The lesson is narrower than "yield more often": a concurrency regression must establish the suspended or queued state that gives the later cancellation assertion meaning. Fixed scheduler-yield counts are not proof of queue admission.

## Revision 34: live MJPEG lifecycle oracle determinism

The revision-33 continuity-only controller submission then exposed a second test-precondition race in `MultipartJPEGLivePlaybackTests.testInitiallyHiddenIngestsButDecodesOnlyLatestOnVisibility_W5_PT_079`. The root run timed out waiting for the hidden latest frame, observed decoder indices `[0, 2]` instead of `[2]`, and observed the first published drop count as 1 instead of 2. Four assertions in that test failed.

The hidden-state contract itself had held: the hidden decoder/output assertions passed. The weak assumption was again a fixed twenty `Task.yield()` sequence after source parts 0, 1 and 2 were yielded. Those yields did not prove that ingestion had coalesced the pending encoded frame to part 2 before visibility was restored. If visibility became true while part 0 was still pending, the worker could legally decode 0 and later decode 2. This was therefore an oracle setup race rather than a reproduced production defect.

Revision 34 audited the same lifecycle test file and removed the corresponding scheduler guesses from PT079, PT080 and PT099. The tests now use the existing `snapshotForTesting()` observables to establish the exact preconditions they assert:

- PT079 waits while hidden until `pendingPartIndex == 2` and `droppedEncodedFrameCount == 2` before restoring visibility;
- PT080 waits until the paused in-flight part is restored to pending with `pendingPartIndex == 0` and `decodedFrameCount == 0` before application reactivation;
- PT099 waits until critical pressure has cleared the pending part and recorded exactly two encoded-frame drops, then verifies recovery begins with no stale pending part before yielding a fresh frame.

No production source changed in revision 34. Local evidence passed the three targeted tests 3/3, the full live-playback selection 19/19, ten independent skip-build live-suite stress repetitions, and one strict root run at 756/756 with zero failures (21.572 seconds XCTest time). The controller then transactionally accepted the test-only patch and independently passed root `swift test` at 756/756, exit 0; the controller command took 29.141015 seconds and XCTest execution took 21.882 seconds.

These revisions strengthen the retained evidence without broadening its claim. Revision 33 and revision 34 are test-oracle repairs only. The revision-32 transaction-attributed quality result remains 0 violations / score 0, while raw unowned quality findings and untraced reviewable candidate paths remain visible and unresolved. Final candidate verification and candidate-authority reporting must recompute against the post-continuity candidate rather than reuse the pre-continuity counts above.

## Revision 35: proof-continuity and cross-repository integration governance

Revision 34 reached a functionally and structurally green frozen candidate before this documentation-only revision: both authorized root verification waves passed 756/756, transaction-attributed quality remained 0 violations / score 0, and independent requirements / implementation / verification reviews were approved. Follow-up current-candidate evidence also closed the previously unregistered local proof gaps without claiming unrelated work: the Workbench verifier passed from a detached dirty-worktree snapshot with byte-reproducible XcodeGen regeneration, Release simulator build, 36 Workbench unit tests, iPhone and iPad UI smoke, and a strict dual-device visual matrix containing 14 screenshots, 14 Accessibility trees and 14 geometry records with no findings or capture errors. A real `FoveaNetworkLab` parser/main reachability matrix exercised help, missing-mode, unknown-argument, conflicting-mode, missing-value, invalid-bound, invalid-URL and invalid-reason-code failures plus the valid offline MJPEG mechanism path; no external live-network result was inferred from that local evidence.

Revision 35 addresses the one remaining requirement-specific proof gap rather than changing product behavior. `docs/roadmaps/fovea-codec-parallel-roadmap.md` now contains an explicit cross-repository integration-branch strategy: short-lived branches remain independent, shared contract / codec dependencies are fixed to immutable commits or contract versions, either-side changes invalidate candidate-bound evidence, promotion is ordered through conformance → shadow → internal canary → format-scoped opt-in → default, reviewed evidence history is not force-rewritten, and rollback returns to an exact prior pin or the ImageIO reference path without deleting original encoded data.

The roadmap task also exposed a controller/host recovery edge without producing a product counterexample. Attempt 1 never launched its authorized root test because local heavy-resource admission deferred execution with exit 126. Attempt 2 launched the root suite and showed ordinary suites passing, then was terminated only by the 600-second task timeout after `StoreGenerationTests.testActiveGenerationRejectsDivergentStoreConfiguration_CACHE_PT_024` started; on the rolled-back tree that test passed in 0.015 seconds and a complete independent root `swift test` passed in about 30.1 seconds. The workflow controller was therefore tightened in the separate workflow-bundle repository to permit exactly one additional manual retry only for an exhausted two-attempt task whose latest failed commands are all pure timeouts; targeted recovery regressions passed 9/9. The bounded attempt 3 then passed the controller root gate at 756/756, exit 0, with 25.542871 seconds controller duration and 22.866 seconds XCTest execution. These are workflow/runtime observations, not a Fovea product defect, and the controller rule still rejects non-timeout failures and any further fourth retry.

The revision-35 transaction boundary is intentionally narrow. The roadmap strategy task writes only the roadmap; this continuity task writes only this retained audit. No production source, Workbench source/project file, codec implementation/test, `FoveaNetworkLab` parser, candidate-baseline contract, or existing `.artifacts/evidence` input is changed by these tasks. Therefore the earlier local Workbench, codec/security/concurrency, mutation, candidate-preservation and command-reachability observations remain useful continuity evidence about unchanged inputs, but they must be rebound to the new verified candidate before satisfying current-revision certificates. The workflow must not silently reuse a stale candidate digest.

The external and multi-owner boundary is unchanged: GitHub `live-network-lab` / `verify` remain independent-environment release stages, physical-device / energy / thermal / publication evidence is not fabricated, the full DocC path retains the Xcode `AppKit` dependency-scan blocker for `FoveaAnimationMacLab-product`, and hundreds of untraced reviewable paths remain outside this workflow's ownership. Final revision-35 verification and candidate authority must recompute those counts and remain fail-closed for every untraced path.
