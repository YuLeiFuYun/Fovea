# Derived-raster cache policy study — 2026-08-08

Status: local mechanism study; package-only opt-in path; no release or global-superiority claim.

## Core question

The relevant question is not whether Fovea can add another disk cache. It is whether a target-derived raster can reduce repeated display-ready decode cost while preserving exact representation authority, bounding persistent resource use, and never letting an eviction layer invalidate an alias owned by another layer.

## Exact source comparison

The comparison uses the exact commits locked by `docs/research/comparator-lock.json`:

| Project | Revision | Relevant behavior observed in source |
| --- | --- | --- |
| Nuke 13.0.6 | `63a8fcbd6621340a2410bc3e9575ac97058615f4` | `DataCache.performSweep()` sums allocated file size, sorts by content access date, and removes least-recently-used items until `sizeLimit * trimRatio` (0.7 by default). |
| Kingfisher 8.11.0 | `410984bf301f4fa224fe56277b3f8672cc465c79` | `DiskStorage.removeSizeExceededValues()` enforces `sizeLimit`, sorts by last access date, and trims to half the configured limit. |
| SDWebImage 5.21.7 | `2de3a496eaf6df9a1312862adcfd54acd73c39c0` | `SDDiskCache.removeExpiredData()` combines age cleanup with allocated-size accounting and oldest-first cleanup to half `maxDiskSize`. |
| PINRemoteImage p14.31 | `c0d5cfa1947f2456ddb321a85b347b3d60d83254` | Its cache adapter delegates disk persistence to PINCache with per-entry age limits and TTL semantics; HTTP response max-age/no-store handling remains distinct from the cache object's lifetime controls. |

These designs are useful baselines, but Fovea has a different correctness problem because its derived artifact has two identities: an authorization-sensitive Fovea alias record and a content-addressed Akashic physical blob.

## Defect found in the prior Fovea composition

At Fovea's exact public Akashic pin `2715f23d50b5a17b7328be41608eaf1b1c99b0d6`, `FileBlobStore.publish` publishes the physical blob and then opportunistically calls `trimIfNeeded()`. Fovea previously passed the same derived soft-byte limit directly into this lower store, but only published its derived alias *after* `base.publish` returned.

The causal failure mode was therefore:

1. Fovea stages and publishes a new physical derived blob.
2. Akashic observes its own byte limit and evicts an older physical blob.
3. Fovea has not yet changed its alias manifest, so an older Fovea alias can still point at the evicted blob.
4. A later load can self-heal that alias to a miss, but the two-index system has already violated the stronger invariant that alias reachability and eviction are owned by one authority boundary.

This is more fundamental than choosing LRU versus another eviction algorithm. The eviction owner must first be moved to the layer that can update every alias referencing a physical object.

## Implemented policy

`AkashicDerivedRasterStore` now owns the derived global soft-byte budget above Akashic.

- Akashic receives one maximum-blob of commit headroom instead of the Fovea soft limit itself. This prevents its lower-level post-publish trim from invalidating an existing Fovea alias while a new alias is still crossing publication fences.
- Fovea groups records by `(namespaceFingerprint, containerContentID)`. Shared aliases therefore count the physical bytes once, not once per alias.
- Budget eviction removes every alias for a victim physical reference in one record-manifest publication before removing the physical blob.
- Successful reads set an in-memory reference bit. A budget sweep gives any referenced physical group one second chance, clears the bit, and evicts cold groups first. No Fovea alias manifest write occurs on a cache hit.
- Normal post-blob publication-fence closure and record-publication failures attempt immediate orphan cleanup rather than deliberately deferring cleanup to GC.
- Store open reconciles aliases whose physical blob no longer exists, garbage-collects physical blobs that no alias reaches (including crash leftovers), then applies the Fovea byte budget.
- Corruption, namespace revocation, generation checks, `no-store`, current-response authorization, and original-encoded fallback remain separate gates and are not weakened by eviction.
- A separate durable fixed-window write ledger reserves a logical lower-bound charge before blob staging: candidate container bytes plus the exact projected full Fovea alias-manifest rewrite. The reservation survives reopen, is not refunded after an uncertain failure, and cannot be refreshed by a caller-supplied artifact timestamp or a backward wall-clock jump. Budget exhaustion therefore stops physical staging rather than merely trimming after the write.

The current policy is intentionally **SIEVE-informed, not an implementation of SIEVE**. It adopts the low-write-amplification idea of a reference bit / second chance rather than persistent access-date promotion at every Fovea hit. It does not claim SIEVE's scan hand, trace-level miss-ratio results, lock-free concurrency result, or web-cache behavior.

## Research mechanisms considered

### SIEVE (NSDI 2024)

Primary source: Yazhuo Zhang et al., *SIEVE is Simpler than LRU: an Efficient Turn-Key Eviction Algorithm for Web Caches*, USENIX NSDI 2024, `https://www.usenix.org/conference/nsdi24/presentation/zhang-yazhuo`.

The paper reports evaluation over 1,559 traces and motivates a simple second-chance-style design whose hits do not require LRU-list mutation. For Fovea, the transferable mechanism is reducing persistent recency-maintenance writes while retaining a weak recency signal. The paper does **not** establish that SIEVE is optimal for image-derived artifacts, so Fovea must measure miss ratio, latency, write bytes, and reclaim tail on its own W2/W11 traces before replacing the current bounded policy with a fuller SIEVE implementation.

### Seer (NSDI 2024)

Primary source: Jason Lei and Vishal Shrivastav, *Seer: Enabling Future-Aware Online Caching in Networked Systems*, USENIX NSDI 2024, `https://www.usenix.org/conference/nsdi24/presentation/lei`.

Seer demonstrates that partial future knowledge can materially improve cache decisions in networked systems. Fovea does not have Seer's packet-level future oracle. The transferable question is narrower: its request scheduler and W11 multi-target plan sometimes expose explicit future target demand. That signal may later improve admission or victim scoring, but using it now without a workload study would be speculative.

### Midas (NSDI 2024)

Primary source: Yifan Qiao et al., *Harvesting Idle Memory for Application-managed Soft State with Midas*, USENIX NSDI 2024, `https://www.usenix.org/conference/nsdi24/presentation/qiao`.

Midas treats reconstructible state as reclaimable soft state under resource pressure. Fovea's derived rasters have the same semantic property: correctness comes from the authoritative original representation, while the raster is only a performance artifact. The transferable principle is therefore strict reconstructibility and immediate fallback, not Midas's OS/kernel mechanism.

## Regression evidence added

`DerivedRasterPersistenceTests` now covers:

- `W11_PT_040`: the global soft budget evicts the oldest cold physical blob and its alias together;
- `W11_PT_041`: aliases sharing one physical container are charged once and are removed together when that physical container is a victim;
- `W11_PT_042`: a recently read physical blob receives one second chance and a colder blob is evicted first;
- `W11_PT_043`: a payload-only write allowance is rejected because the complete projected alias-manifest rewrite is also charged, and rejection happens before a physical blob becomes reachable;
- `W11_PT_044`: the write reservation survives reopen, a backward clock cannot refresh it, and only a forward fixed-window boundary opens a new allowance;
- `W11_PT_045`: the real pipeline exhausts a one-byte write window, publishes no derived alias, and emits the specific `derived-raster-global-write-budget` diagnostic;
- `W11_PT_046`: a publication that fails after durable reservation does not refund the reservation, so retry churn cannot turn uncertain writes into free writes;
- `W11_PT_047`: corrupt or future-schema write-budget metadata fails closed on reopen instead of resetting the window to zero;
- `W11_PT_048`: large caller-supplied artifact timestamps cannot advance the persistence-owned write window;
- strengthened `W11_PT_018` and `W11_PT_021`: ordinary record-publication and publication-fence failures do not intentionally leave an orphan blob.

The strict `DerivedRaster*` suite is rerun as part of this change; full-suite verification remains a separate gate and test counts are recorded only from completed runs.

## Remaining gaps and falsifiers

This work closes the missing **mechanism** for a package-internal global persistent-byte budget, alias-aware eviction, and a durable logical write-window admission gate. It does not close production/default admission or prove physical-device write amplification.

The next falsifiers are:

1. clean-source W2 and W11 end-to-end runs must show display-ready latency benefit after all file I/O, record lookup, and reconciliation costs;
2. the durable logical write window must be calibrated against **total physical write amplification**, including its own reservation record, Fovea alias-manifest publication, Akashic metadata, filesystem allocation/fsync/directory metadata, eviction, and crash-recovery cleanup;
3. the fixed-window boundary permits a bounded boundary burst, so traces must determine whether fixed-window semantics are adequate or a sliding/token-bucket design is required;
4. open-time reconciliation/GC must be measured for large artifact counts; an O(N) scan that materially regresses startup or first use is a policy failure;
5. physical-device memory, energy, thermal, and reclaim-tail measurements remain mandatory;
6. current second-chance behavior must be compared against exact-LRU and a fuller SIEVE-style policy on Fovea request traces before claiming a miss-ratio or throughput advantage.

## Claim boundary

The implementation is stronger than the prior Fovea composition on index/eviction ownership and now has both a bounded derived persistent-byte mechanism and a restart-durable logical write admission gate. It is not evidence that Fovea is globally the best image loader, nor that this eviction policy beats Nuke, Kingfisher, SDWebImage, PINRemoteImage, or SIEVE on every workload. Any such claim requires the preregistered clean comparator matrix and endpoint-specific statistics.
