# Codec boundary audit — 2026-08-08

Status: exact-pin host-boundary audit and local hardening. This document does **not** claim AVIF/JPEG XL support, a production-ready second backend, progressive peak-memory admission, or performance superiority.

## Core question

A pluggable decoder boundary is only real if an independently versioned or third-party codec cannot broaden Fovea's semantics or resource authority by returning values that contradict its own descriptor, probe, request, or resource estimate.

The critical boundary is therefore not merely:

> can Fovea call another decoder?

It is:

> after Fovea admits work based on a codec's declarations, what host-verifiable facts must still be checked before pixels can reach cache/UI, and which costs cannot be safely verified after the decoder has already executed?

## Exact authority inspected

Fovea is evaluated against its exact public ImageCraft dependency pin:

- ImageCraft: `736d0fb75ec612082817ff782d25cb638cb8469e`
- contract source: `.build/checkouts/ImageCraft/Sources/ImageCraftCore/ImageCodecContract.swift`
- core types: `.build/checkouts/ImageCraft/Sources/ImageCraftCore/ImageTypes.swift`
- reference adapter: `.build/checkouts/ImageCraft/Sources/ImageCraftImageIO/ImageIOImageDecoder.swift`

The dirty sibling `../ImageCraft` is not used as Fovea authority. Its newer local work is a future candidate only.

Two external codec projects were checked out only for source comparison:

- libavif v1.4.2: `c5240fc79fe5c2407e10afd35f5505ef6333ea49`
- libjxl v0.12.0: `a7a9c787341cf703dede03c2009fa460cae5e5df`

## What the exact ImageCraft contract already gets right

The current contract is stronger than a format-name switch:

- capability requests separate format, delivery, track, metadata, dynamic range, output representation and cancellation semantics;
- `progressiveFormats` is distinct from `deliveryModes`, so a codec cannot advertise “progressive exists somewhere” and thereby imply every supported format is progressive;
- descriptor identity includes backend identifier, implementation version and contract version;
- `PreparedImageDecoding` gives the host an explicit discard path for unconsumed prepared state;
- `ImageDecodeResourceEstimate` rejects non-positive values and complete-frame admission takes the maximum of the host generic estimate and backend estimate;
- Fovea independently revalidates `ImageProbe` under its own `DecodeLimits` before trusting the probe.

The Python model checker previously omitted `progressiveFormats`, even though the Swift conformance test modeled it correctly. The model now includes that coupling explicitly.

## Defect 1: declarations were checked, returned pixels were not

Before this audit, complete-frame `DecodeStage` validated the probe and capability descriptor, acquired a working-set permit, called the backend, and then accepted the returned `DecodedImage` without an independent Fovea postcondition.

Two malicious-but-type-correct fake codecs demonstrated the gap before the fix:

1. target `10×10`, valid probe, valid descriptor, valid estimate, but backend returned `11×10`; Fovea accepted it;
2. target `10×10`, backend returned `10×10` but with `bytesPerRow=4096`, giving a 40,960-byte resident CGImage after admission for a much smaller working set; Fovea accepted it.

Additional hostile cases cover an output outside `DecodeLimits` and a decoded source-profile fact that disagrees with the validated probe.

### Implemented complete-frame postcondition

`FoveaCodecOutputContract` now runs while the complete-frame working-set permit is still held and requires:

- output dimensions and checked pixel count remain within `DecodeLimits`;
- output dimensions do not exceed the requested target box;
- `DecodedImage.estimatedByteCost` does not exceed the working-set bytes admitted for this decode;
- `DecodedImage.colorDescription.sourceProfile` matches the validated probe source-profile fact.

A violation is a terminal `internalFailure` at the decode stage. It is treated as a codec contract violation, not as evidence that the user's encoded image is corrupt.

This is intentionally a host **postcondition**. It can prevent an invalid returned object from being published, but it cannot undo a codec-private transient allocation peak that already happened during decode.

## Defect 2: progressive previews bypassed the output boundary

The exact pin's `ImageProgressiveDecodeSession.append(_:)` returns an `ImageProgressiveDecodeGeneration` containing pixels, generation number and source byte count. The session contract has no per-session/per-generation resource estimate and the generation carries no probe.

Before this audit, Fovea returned those preview pixels directly from `DecodeStage.appendProgressive`. A fake progressive backend returning `11×10` pixels for a `10×10` request was accepted.

`ProgressiveDecodeStage` now centralizes progressive codec calls on the same blocking executor and validates every returned preview before it leaves the codec boundary:

- `DecodeLimits` dimension/pixel bounds;
- request target bounds;
- the returned image's resident bytes must not exceed Fovea's configured decode working-set hard capacity.

The helper extraction also reduces `DecodeStage` growth: progressive session mechanics no longer live inline in the main decode orchestrator.

### Progressive resource gap remains open

The current check is not pre-decode resource admission. `append(_:)` may allocate codec scratch memory before it returns a generation; a postcondition cannot prevent that already-observed peak. The exact ImageCraft progressive API exposes no conservative peak envelope that Fovea can reserve before calling `append`.

Therefore production-quality progressive resource closure requires an ImageCraftCore contract evolution, for example a versioned session/generation resource envelope whose semantics are explicit enough for the host to acquire permits before decode work begins. The exact shape should be driven by a second real backend rather than invented speculatively.

## Format extensibility is also not yet open-ended

At the exact Fovea pin, `EncodedImageFormat` contains only PNG, JPEG and GIF. Consequently AVIF or JPEG XL cannot be added solely by registering another implementation of `ImageCodec`; the shared core contract must first gain a versioned representation for the new encoded format and Fovea must explicitly accept that contract version.

This is preferable to pretending the current enum is already a universal codec ABI. A future format extension must preserve cache identity, capability negotiation, failure classification, limits and rollback semantics.

## Source comparison: libavif v1.4.2

The exact libavif source exposes several mechanisms relevant to a future backend:

- `avifDecoder.imageSizeLimit`, `imageDimensionLimit` and `imageCountLimit` are decoder-owned hard guards against oversized/malicious declarations;
- `avifIO` uses offset/range reads, supports unavailable streamed ranges with `AVIF_RESULT_WAITING_ON_IO`, and carries a `sizeHint` explicitly used for allocation sanity checks;
- buffer lifetime is part of the I/O contract (`persistent` versus data valid only until the next read).

Transferable lesson: streaming and hard size limits are part of the decoder contract, not optional application metadata. A Fovea adapter must map these mechanisms into host limits without weakening either layer.

## Source comparison: libjxl v0.12.0

The exact libjxl decoder API similarly makes ownership and incremental state explicit:

- caller-owned input is provided with `JxlDecoderSetInput`, remains live until `JxlDecoderReleaseInput`, and unprocessed bytes must be re-presented on the next chunk;
- `JXL_DEC_FRAME_PROGRESSION` marks codec-defined progressive points and is explicitly not guaranteed for every image;
- decoder creation accepts a `JxlMemoryManager`, allowing all dynamic allocations for that decoder instance to be routed through caller-provided allocation functions;
- image output can be a caller-sized buffer or callbacks that receive horizontal pixel stripes; callback pixels are borrowed and valid only during the callback, and the multithreaded callback API exposes an explicit concurrency bound.

Transferable lesson: a future JPEG XL adapter should not immediately materialize a universal full-frame CGImage if a bounded stripe/callback path can preserve Fovea's output and memory contract. But adopting such a path would require an explicit output-representation/resource contract extension; it is not present in the current Fovea pin.

## Resource-composition interpretation

`docs/research/decode-resource-composition-model.json` contains counterexamples where `max(generic, backend)` under-reports a true peak if the two numbers cover disjoint live allocations. That does **not** contradict the current ImageCraft API only because `ImageCodec.resourceEstimate` is specified as a conservative peak for the whole probe/request execution, not as “codec-private scratch”.

The distinction is a contract precondition:

- if backend estimate = conservative **total peak**, `max(hostLowerBound, backendTotalPeak)` is a conservative admission value;
- if a future backend estimate = only codec-private scratch, the same algebra is unsound when host and codec allocations overlap.

The new post-decode resident check catches a returned output larger than the admitted total, but cannot observe transient scratch that was allocated and released before return. Default-backend qualification therefore still requires independent peak RSS / allocator / VM evidence and a safety margin.

## Executable evidence

The finite model checker now covers:

- 2,304 capability requests with explicit progressive-format coupling;
- two direct progressive-format coupling cases;
- 262,144 generation-order triples;
- 49 complete-frame resource-join cases;
- 60 complete-frame output-contract combinations;
- 30 progressive output-contract combinations;
- 25 checked timing-domain combinations.

Swift hostile-backend tests additionally exercise real `CGImage.bytesPerRow`, `DecodedImage.estimatedByteCost`, `DecodeStage`, cancellation boundaries and progressive session plumbing. The current required IDs are:

- `CODEC-PT-012`: complete-frame output must not exceed the requested target box;
- `CODEC-PT-013`: complete-frame output must remain inside host `DecodeLimits`;
- `CODEC-PT-014`: actual complete-frame resident output bytes must not exceed admitted working-set bytes;
- `CODEC-PT-015`: decoded source-profile fact must match the validated probe;
- `CODEC-PT-016`: progressive preview output must not exceed the requested target box;
- `CODEC-PT-017`: progressive preview resident output must not exceed the configured host hard working-set capacity.

The full `ImageDecoderTests` and `ProgressiveImageLoadingTests` suites must remain green before this patch can be considered locally valid.

## Remaining blockers / falsifiers

This audit does not close the following:

1. AVIF/JPEG XL format identity and capability representation in `ImageCraftCore`;
2. a second backend running the same cross-repository conformance kit;
3. progressive pre-decode peak-resource admission;
4. proof that a backend's claimed complete-frame peak estimate covers transient private allocations;
5. interruptible cancellation for backends that advertise it;
6. allocator/VM/peak-RSS and device energy/thermal evidence;
7. fuzz/sanitizer coverage for any non-ImageIO parser/decoder;
8. performance or quality superiority over ImageIO, libavif, libjxl or other codecs.

Any “world best” or “beats every codec” claim remains invalid until a preregistered, format/device/corpus-specific comparison closes the applicable gates above.
