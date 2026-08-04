# W7 control-plane profiling and rejected candidates — 2026-08

This record separates causal diagnostics from claim-bearing W7 evidence. All numbers below are local
iOS Simulator calibration or exploratory A/B results. They do not establish a release performance
claim, and none may override the preregistered V10 hard checks or formal repeated-device requirement.

## Causal localization

Phase timing and origin service-slot accounting localized the dominant Fovea gap to the 448-request
balanced-priority subtrace rather than decode correctness or the eight 1.5-second blocker requests.
In the diagnostic run that motivated the work, Fovea's balanced phase was about 547 ms slower than
Kingfisher. Fovea accumulated about 4.40 seconds-slot more origin idle capacity, equivalent to about
550 ms of wall time at eight slots. The close match supports a permit-to-origin handoff bubble as the
mechanism; it does not by itself identify a safe optimization.

The optional `--phase-diagnostics` mode now records phase durations, origin idle-slot time and origin
start gaps. Those fields are explicitly non-claim-bearing.

## Rejected: active-fetch over-admission

Raising Fovea's active fetch budget from eight to sixteen almost eliminated balanced-phase origin idle
time and reduced p99, but it violated the common W7 client budget. Raising it only to nine shortened
the balanced subtrace by roughly 464 ms yet made the shared cancellation subtrace roughly 2.49 s
slower. Neither result is admissible: improving a benchmark by changing the semantic budget is not an
optimization.

## Rejected: suspended URLSession preparation wave

A prototype prepared URLSession tasks, event routes and bounded body accumulators while keeping at
most eight tasks active on the network. It preserved origin peak concurrency eight, cancellation
counts and response correctness. Across three gated repeats, median throughput was 75.628 requests/s
and median p99 was 8.907 s, only about 1.2% and 1.3% better than the preceding clean calibration.
Median physical-footprint growth was about 27.1 MiB versus roughly 14.2 MiB in the preceding clean
run. Nearly doubling measured footprint for an approximately one-percent latency/throughput change
is an unacceptable trade.

A synchronous permit-grant start hook was also rejected: its first A/B reduced neither total duration
nor origin idle time and lowered throughput by about 0.7%.

## Rejected: NullDiagnosticsSink type fast path

A proposed fast path skipped the asynchronous `recordStarted` call when the configured sink was the
built-in `NullDiagnosticsSink`. A same-source paired experiment alternated the real null sink with a
type-distinct no-op sink. Throughput ratios were approximately 1.0070, 1.0132 and 0.9899; one of three
pairs reversed direction and the mean improvement was only about 0.33%. The p99 direction also
reversed in one pair. The change was removed as indistinguishable from host noise.

## Methodological counterexample: V9 origin readiness

The suspended-preparation prototype exposed a flaw in V9 even though the prototype itself was
rejected. V9 observed all 512 logical loads as prepared but could release the shared-response gate
before any request reached it. One run therefore had:

- 512 prepared logical loads;
- 744 completed and 256 cancelled subscribers;
- zero failed loads and origin peak concurrency eight;
- only 12 shared origin starts;
- zero origin preparation-gate waiters.

The application outcomes were correct, but the benchmark's cancellation timing was no longer bound
to a fully occupied origin service curve. V10 consequently requires exactly eight shared requests—
one per origin service slot—to be waiting on the closed response gate before release. The wait is
bounded and fails closed. This is a methodology correction, not a Fovea-specific advantage.
