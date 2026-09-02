# Target-derived raster persistence contract

Status: package-internal opt-in path implemented; every public/default composition remains disabled.

## Purpose

A target-derived raster is an exact-pixel artifact produced from a verified original representation for one `RenderKey`. It may reduce repeated ordinary-image decode work, but it is not the authoritative HTTP representation and cannot weaken Fovea's cache, authorization, namespace, cancellation, or revocation semantics.

The artifact exists only to accelerate a later load that could otherwise reproduce the same pixels from the original encoded body. The current integration creates artifacts only after a successful reusable-original warm-disk load. Network first display never schedules derived creation.

## Identity

`DerivedRasterArtifactKey` schema 7 binds:

- representation base-key digest;
- selected variant-key digest;
- storage namespace fingerprint and namespace generation;
- `ContentID` digest and byte count;
- exact target width and height;
- content mode, geometry-policy fingerprint, and color policy;
- codec contract version and backend fingerprint;
- transformer fingerprint and render version;
- derived-format identifier, semantic version, and pixel-layout fingerprint.

Equal source bytes alone are insufficient. Different Vary selections, credential contexts, namespace generations, codec semantics, transforms, target geometry, or derived-format versions produce different identities.

The key is not a persistence or reuse authorization token.

## Creation admission

`DerivedRasterAdmissionPolicy` is a conservative prerequisite model. Admission requires all of the following:

1. the request has stable render-cache admission;
2. the current representation is structurally valid, fresh, reusable, and does not require revalidation;
3. representation base identity, namespace fingerprint, namespace generation, `ContentID`, target, geometry, content mode, and color policy match the proposed `RenderKey`;
4. the namespace is currently active;
5. creation runs in background and cannot delay network first display;
6. original reusable-data callback work is measurably more expensive than the matching derived callback boundary: authenticated compressed-container parse + lazy RGB24 `CGImage` construction, plus configured persistent-read overhead; later pixel materialization is measured separately by the comparative display-ready benchmark rather than mixed into only one side of the admission comparison;
7. derived bytes and creation work fit independent per-artifact budgets;
8. exact-`RenderKey` reuse has been observed enough times to repay measured creation work under the conservative per-hit savings model:

```text
ceil(creation work / conservative per-hit savings) + safety margin
```

`DerivedRasterCostEstimating` is package-only. The default estimator uses measured current-process original and derived costs. Runtime admission is driven by observed reuse of the exact artifact identity; there is no caller-supplied or predicted-future-hit admission signal. Controlled experiments may inject a RenderKey-aware calibrated estimator; public callers cannot supply one. A single online sample is not sufficient evidence for default admission.

`DerivedRasterRuntime` additionally bounds concurrent and queued creators. The package-internal Akashic store now owns an alias-aware global soft persistent-byte budget: physical containers shared by multiple aliases are charged once, eviction removes every alias for a victim physical container before removing its bytes, and a successful read supplies one in-memory second chance without rewriting the Fovea alias manifest. It also has a durable fixed-window **logical write admission gate**. Before any blob staging, the store reserves at least the candidate container bytes plus the exact projected full Fovea alias-manifest rewrite bytes; reservations survive reopen, failed later publication remains conservatively charged, and a wall-clock rollback cannot refresh the current window. This bounds a declared logical write floor, not device write amplification: the reservation ledger itself, Akashic metadata, filesystem allocation, fsync/directory metadata, eviction writes, energy, thermal and reclaim-tail still require clean/device calibration before default enablement.

## Reuse fence

Every lookup passes `DerivedRasterReusePolicy` against the current representation record before reading the artifact and again before publishing pixels. Reuse fails closed when:

- the current response is `no-store`;
- revalidation is mandatory;
- freshness has expired;
- the namespace is inactive or its generation changed;
- the selected representation, render identity, or format identity differs.

This check is required even when a stored artifact digest matches. A representation that was reusable when the artifact was created may later become unreachable without trusting the old key.

## Publication and lifecycle ordering

The package-internal store publishes one artifact through these ordered fences:

1. check publication permission before staging bytes;
2. check again before publishing the staged blob;
3. check again immediately before publishing the alias record;
4. check after alias publication and roll back both alias and unreferenced blob if permission closed during the final write.

Additional lifecycle rules:

- creation is single-flight per exact derived identity and the coordinator has a finite entry capacity;
- the Fovea alias layer, not the lower Akashic blob layer, owns the derived soft-byte eviction decision; the lower store receives one maximum-blob of commit headroom so its post-publish maintenance cannot invalidate an existing alias during a new publication;
- physical-byte accounting is deduplicated by namespace plus container content identity, and all aliases for one evicted physical container are removed in the same record-manifest update before deleting that container;
- successful derived reads set only an in-memory second-chance bit; a budget sweep consumes that bit before evicting a recently used container, avoiding Fovea alias-manifest writes on ordinary hits;
- a persistent derived hit enters a bounded compressed-container hot tier and never promotes derived output into the decoded rendered cache; repeated derived hits reuse only the authenticated compressed container;
- only the official Akashic path may use the display-lazy fast path, and only when it supplies both `recordValidated` and `containerContentDigestVerified`; custom/package stores default to false, must perform full decoded-pixel SHA validation, and do not seed compressed-hot state;
- trusted record-backed loads validate the current container header/geometry/format against the current record and then return a display-lazy RGB24 `CGImage` with `alphaInfo == .none`; the current container uses independent 1 MiB-decoded LZFSE chunks and a direct random-access `CGDataProvider`, so each `(position, count)` read has no shared decoder cursor; the outer LZFSE frame parser requires every chunk's `bvx$` end marker to land exactly on the chunk boundary and binds the exact decoded byte count without expanding pixels, while the buffer decoder writes exact chunk output on demand; repeated partial reads of one chunk share at most one 1 MiB transient decoded scratch that is discarded when the request reaches the image end or the provider dies;
- the lazy provider must remain exact across repeated and concurrent draw stress before this path can be treated as production-safe; absence of an Apple-documented concurrent-reader guarantee is not replaced by benchmark success;
- memory purge and namespace revocation clear matching compressed-hot state, so warm-disk boundaries and revoked generations cannot reuse RAM-resident derived bytes;
- open-time reconciliation removes aliases whose physical blob is already missing, garbage-collects unreachable crash leftovers, and reapplies the Fovea soft-byte budget;
- every physical publication first computes the hypothetical post-publication alias manifest size and durably reserves `containerByteCount + projectedAliasManifestByteCount` in a separate bounded write-budget record; if the fixed-window budget is exhausted, publication fails before blob staging and emits `derived-raster-global-write-budget`;
- a failed stage, authorization fence, alias publication, or process crash may leave the durable write reservation conservatively consumed for that window; reservations are never refunded from an unproven assumption that no device write occurred;
- the write-budget clock is owned by the persistence layer rather than `DerivedRasterRecord.createdAt`, so a caller-provided artifact timestamp cannot advance the budget window; a backward system-clock movement retains the current reservation window rather than resetting it;
- the coordinator inserts its token entry before detached work can finish, preventing a completion-before-registration leak;
- cancellation and namespace revocation synchronously close publication leases before cancelling work;
- namespace revoke cancels creators before removing every alias in that namespace;
- corrupt, unknown or semantically mismatched containers are removed and fall back to original decode;
- transient store unavailability falls back without deleting the alias;
- normal publication-fence closure or record-publication failure after blob publish attempts immediate cleanup of the now-unreachable blob; garbage collection remains the crash/failure recovery backstop rather than the expected normal path;
- task cancellation propagates to the top-level request and is never normalized into an original-path fallback;
- derived eviction or corruption handling cannot remove or rewrite the authoritative representation record;
- original encoded bytes remain the immediate rollback path.

## Current format

Schema 7 stores one format only: tightly packed opaque 8-bit sRGB RGB24 pixels (`CGImageAlphaInfo.none`) split into fixed 1 MiB decoded chunks and independently compressed with LZFSE. Alpha is structurally absent from the persisted byte stream, so cache reuse preserves the direct decode's `.none` alpha semantics without a decoded alpha proof pass. Creation draws the already-opaque source into a deterministic 32-bit sRGB staging surface and packs only RGB bytes before encoding; the pack is background creation work, not part of the reusable read boundary. The 120-byte fixed header binds dimensions, exact decoded length, current chunk size/count, total compressed length, pixel digest and the digest of the complete chunk-table-plus-payload region; each table entry binds one compressed chunk length, and Akashic separately binds the complete container through its content identity. Parsing walks only the LZFSE outer block headers, requires a bounded block count, sums each block's declared decoded bytes to the exact chunk length, and requires the `bvx$` end marker to be the final four bytes of the chunk. Pixel expansion remains lazy and uses the buffer decoder only after that canonical frame boundary has been proven.

There is no legacy reader, RGB24 layout, row-filtered payload, or compatibility identity. Older schemas/formats are rejected and quarantined through the normal derived-cache fallback path. This is package-only state, not a public file-format compatibility promise.

## Current opt-in integration

A package-level test or experimental composition must provide both:

- a `DerivedRasterStoring` implementation;
- a `DerivedRasterRuntimeConfiguration`.

If either is absent, no runtime is constructed and the existing pipeline is unchanged. Public `FoveaPipeline` and `FoveaSystemPipeline` construction do not expose or enable these inputs.

The implemented cache order for a selected fresh representation is:

```text
rendered memory
→ authorized compressed-hot / persistent derived raster
→ authoritative original encoded body
→ conditional/network fetch
```

After original encoded reuse succeeds, the final transformed opaque image may be scheduled for background derivation. Alpha-bearing source surfaces are rejected because the current RGB24 format deliberately models opaque display-ready pixels only; a derived hit therefore preserves `.none` alpha semantics while storing no alpha bytes.

## Evidence and claim boundary

Current mechanism and integration evidence:

- `docs/research/ordinary-image-derived-raster-study-2026-08.json`;
- `Benchmarks/ComparativeLab/ordinary-image-derived-cache-plan.json`;
- `Tests/FoveaTests/DerivedRasterAdmissionPolicyTests.swift`;
- `Tests/FoveaTests/DerivedRasterContainerTests.swift`;
- `Tests/FoveaTests/DerivedRasterCreationCoordinatorTests.swift`;
- `Tests/FoveaTests/DerivedRasterPersistenceTests.swift`;
- `Tests/FoveaTests/DerivedRasterPipelineIntegrationTests.swift`;
- `Tests/FoveaTests/DerivedRasterRuntimeTests.swift`.

The retained tests establish identity, admission arithmetic, bounded creation, exact container round-trip, reopen, publication rollback, namespace cleanup, `no-store` exclusion, corruption fallback, transient-error preservation, cancellation propagation, alias-aware physical-byte accounting, shared-container eviction, a bounded in-memory second-chance eviction signal, durable logical write reservations across reopen/clock rollback, conservative reservation retention after failed publication, fail-closed handling of corrupt/future budget metadata, rejection of caller-timestamp window spoofing, pre-staging rejection when payload-plus-alias-manifest cost exceeds the window, and a pipeline-level write-budget diagnostic. They do not establish:

- clean-source W2 or W11 latency improvement after integration;
- a production default admission policy;
- a production/default persistent-byte limit or admission policy calibrated by clean workloads;
- a production-calibrated logical write-window value or a sliding-window/token-bucket burst guarantee;
- total physical write amplification, because the current logical charge intentionally excludes the budget-control file itself, Akashic metadata, filesystem allocation/fsync/directory metadata, and eviction/recovery writes;
- physical-device memory, energy, thermal or reclaim-tail behavior;
- superiority of the current second-chance policy over LRU/SIEVE alternatives on Fovea traces;
- release eligibility or superiority over another loader.
