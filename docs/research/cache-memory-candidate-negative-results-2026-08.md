# Cache memory candidate negative results — 2026-08

## Scope

These are local paired CacheLab calibration or formal results obtained while trying to make the
Akashic/Fovea memory cache materially dominate locked LRUCache and PINMemoryCache. A candidate is
rejected when it improves one endpoint by sacrificing another, fails the independent reference
model, changes the global cost contract, or does not put the 95% interval above the preregistered
20% dominance margin.

The rejected-candidate numbers below are diagnostic evidence from the original research worktree.
They are not marketing claims. The retained Akashic implementation is now published at the exact
Fovea pin; the production switch still requires the current clean verification and a new quiet-host
formal run before a release certificate.

## Rejected candidates

| Candidate | Useful observation | Rejection reason |
|---|---|---|
| One global `os_unfair_lock` | Raised point throughput | p99 worsened by about 19%; one unfair lock permits sustained barging under the mixed workload. |
| One global `pthread_mutex` | Concurrent throughput point estimate reached about 1.34× | 95% lower bound was about 1.08× and p99 evidence remained insufficient. |
| Read/write lock | Concurrent p99 improved to about 1.81× | Throughput fell to about 0.40× because the workload contains enough mutations to make RW state transitions dominant. |
| Contiguous optional-value slots | Removed per-entry object allocation in theory | Throughput fell to roughly 0.50–0.58× because Swift optional-structure mutation and value/ARC traffic dominated. |
| Sharded reads plus one global mutation sequence | Concurrent throughput point estimate reached about 1.24× | p99 fell to about 0.91× because readers could overtake a waiting global mutation. A pending-writer gate made all primary memory metrics worse. |
| O(1) cold-candidate chain for exact SIEVE | Intended to skip visited nodes | Failed the 32-seed independent SIEVE differential. Skipping a visited node must also clear its visit bit, so direct cold-node jumps changed the next victim. |
| Immediate-promotion segmented FIFO | Hot-scan throughput and p99 improved by about 30% | Formal mixed-concurrency throughput fell to about 0.86× and p99 to about 0.75× because hits moved nodes between segments. |
| S3-FIFO prototype with ghost history | Deferred most movement to eviction | Hot-scan throughput fell to about 0.64× and concurrent throughput to about 0.86×; ghost maintenance and main-queue rotation were too expensive for this Swift implementation. |
| Deferred-promotion two-segment FIFO | Removed ghost history and hit-time movement | Returned near baseline only: hot throughput about 1.17×, concurrent throughput about 1.07×, concurrent p99 about 0.91×. It did not cross the 20% dominance bound. |
| Fixed-budget independent shards | Concurrent throughput/p99 exceeded 2× | A value that fit the global budget could be rejected merely because it exceeded one shard budget. This leaks the implementation topology into the public capacity contract and is unacceptable without a global-budget slow path. |
| Reverse collision backlink + stored bucket index | Made victim unlink O(1) and passed all eight correctness tests | Enlarged every node and added pointer writes; clean 20-block hot throughput fell from about 1.25× to about 1.21×, so the compact singly linked chain was restored. |
| V2 timed corpus construction | Produced apparently stable total-throughput numbers | Hot throughput included payload generation and string interpolation while p99 excluded them; concurrent metrics also paid key/value construction. This diluted cache differences and made throughput/p99 measure different boundaries. V2 was archived and V3 precomputes corpus. |
| Thirty-two shards at cost limit 128 | Shortened local scan chains | Static per-shard budgets retained only 21/32 hot entries in every diagnostic run. The topology leaked into hit semantics, so 32 shards were rejected. |

## Retained direction

The retained candidate is a configurable independent sharded SIEVE; the V4 Fovea measurement configuration uses eight shards with:

- one short unfair lock per shard;
- a single precomputed key hash used for shard and bucket selection;
- explicit collision chains;
- victim-node recycling on steady-state scans;
- an all-shard slow path only when a value needs more than its current shard budget;
- all-shard locking for atomic global limit changes, filtered purge and aggregate snapshots.

The candidate passes the Akashic 55-test suite, public-API additive diff, six-case Apple platform matrix, full local release-readiness mechanics, and a Git-free Fovea 478-test integration. V2 passed 12/13 comparisons and was rejected; V3 had a declared-versus-executed round mismatch and three final failures. V4 executes twenty fresh-cache rounds, selects eight shards after explicit 16/32-shard retention counterexamples, and its twenty clean process blocks pass all 13 applicable dominance comparisons. Akashic revision `2715f23d50b5a17b7328be41608eaf1b1c99b0d6` is public and already pinned by Fovea, so the default rendered cache now uses the measured eight-shard implementation. A current clean Fovea verification and quiet-host trusted-CI repetition remain mandatory before a release certificate.
