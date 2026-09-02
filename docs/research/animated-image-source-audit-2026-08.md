# Animated image source audit — 2026-08

This audit expands the comparison set without expanding the product surface. Exact shallow source revisions are recorded in `animated-image-library-registry-2026-08.json`; none is added as a Fovea runtime dependency.

## High-value mechanisms

- **Display deadline alignment:** FLAnimatedImage and AnimatedImage consume display-link target timestamps; Apple exposes the next-display timestamp and actual refresh interval. Fovea already uses absolute playback deadlines, but a platform clock adapter should be tested against physical display callbacks before adoption.
- **Bounded adaptive frame memory:** Gifu caches a finite upcoming window. FLAnimatedImage and YYImage derive cache behavior from memory cost and reduce it on pressure/background. Fovea already has actual-byte SIEVE memory, bounded wrap-aware windows, and explicit pressure levels; the remaining useful experiment is adaptive window recovery, not a second cache implementation.
- **Partial-frame composition:** APNGKit and YYImage maintain disposal/blend-aware composition state. ImageCraft already validates rect/disposal/blend metadata; a checkpoint/subrect experiment is justified only after the real Fovea adapter exists and exact-pixel oracles pass.
- **Streaming first pass:** APNGKit distinguishes loaded-partial and full duration. This is deferred until large APNG fixtures show material startup benefit without weakening chunk-order, CRC, limit, or cancellation guarantees.
- **Lifecycle falsifiers:** Gifu, FLAnimatedImage, SwiftyGif, SDWebImage, PINRemoteImage, and Kingfisher provide different pause, visibility, waiting, cache, and loop behaviors. They enter role-specific player comparisons rather than a single aggregate ranking.

## Scope control

The current product objective remains bounded raster playback for GIF, APNG, pre-split complete JPEG sequences, and the already implemented live MJPEG path. Animated WebP/AVIF/HEIF, encoding, sprite-sheet authoring, video, and vector animation are deferred or rejected from the current scope. A source project may be technically impressive without its entire feature set being appropriate for Fovea.

## Evidence order

1. Source semantics and exact revision registry.
2. Correctness adapters and hostile/edge fixtures.
3. Mechanism measurements under equivalent cache and timeline policies.
4. Clean fixed revisions and physical-device player measurements.
5. Product adoption only after benefit exceeds complexity and lifecycle cost.


## Research signals and boundaries

- Apple display-link contracts expose the next display target timestamp and a preferred frame-rate range, while the system may adjust actual rates for hardware capability, Low Power Mode, thermal state and accessibility. This supports a physical-device target-deadline clock experiment; it does not justify a fixed refresh assumption.
- The HotPower 2014 dynamic resolution/frame-rate study and later adaptive-rate video work show that reducing update rate can save mobile energy in graphics/video workloads. Those results are not transferable performance evidence for raster image playback; Fovea therefore requires its own timing, quality and energy gate.
- USENIX LPD shows that avoiding unchanged-region copies can reduce display-side energy on a different Linux/X stack. Together with APNGKit and YYImage source behavior, this motivates—but does not preapprove—a subrect/checkpoint compositor experiment after the real ImageCraft adapter exists.
- Human-subject work on variable frame timing reports that small frame-time variations can affect perceived smoothness. Player comparison therefore records timing-error distribution and missed deadlines rather than average FPS alone.
- Hardware proposals such as BurstLink and dynamic sampling exploit display-transfer or temporal-coherence mechanisms unavailable to a portable Swift library. They remain architectural signals, not implementation candidates.
