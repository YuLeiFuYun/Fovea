# PINRemoteImage comparative adapter findings — 2026-07

> **Scope:** deterministic W1/W2/W3 calibration of locked PINRemoteImage `c0d5cfa1947f2456ddb321a85b347b3d60d83254` (`releases/p14.31`). These findings constrain the adapter and comparison claims; they do not modify upstream source.

## Processed variants can bypass `no-store`

PINRemoteImage only interprets HTTP cache lifetime when a TTL-capable PINCache is used. More importantly, its processor path creates a derived image and materializes that processed variant without carrying the response-derived `maxAge` into the processed-cache write. A `Cache-Control: no-store` response can therefore be absent from the original TTL cache yet remain reusable through the processed-image cache.

The comparative adapter avoids claiming this behavior as HTTP-compliant caching. Authenticated requests use the original download path and perform only output-size normalization after PINRemoteImage returns. W3 keeps `no-store-reusable-write-zero` as a hard check.

## Eager orientation normalization can introduce an extra pixel

The locked upstream decoder reads EXIF orientation, computes a floating-point rotated rectangle, and creates a `UIGraphicsImageRenderer` from that size. For the orientation-6 probe, the intended 120×80 normalized image became 120×81 because the 90-degree transform produced a small floating-point residual that the renderer rounded upward. The extra row also changed reference samples.

The adapter uses the public skip-decode option so that PINRemoteImage retains the original `CGImage` plus `UIImageOrientation`; one target-size render then applies orientation and scaling together. This avoids double rasterization and restores the W2 orientation, color and target-pixel invariants.

## Cross-origin redirects retain authorization

The locked manager accepts a session configuration but does not expose a redirect-delegate hook through its public construction surface. Under the deterministic W3 redirect, the redirected request retained `Authorization` when the destination origin changed. The adapter does not install an out-of-contract proxy or private hook to conceal this result.

The finding remains a visible W3 capability gap: PINRemoteImage is not performance-ranked as semantically equivalent to implementations that guarantee cross-origin credential stripping.

## Cancellation integration note

PINRemoteImage does not guarantee that cancellation invokes the completion block. A Swift continuation that is resumed only from completion can therefore leak. The adapter owns an exactly-once result relay and an active-load registry so explicit cancellation, namespace revoke and global cancellation all finish the Swift result while ignoring any late callback. This is adapter lifecycle correctness, not a claim that upstream exposes subscriber-scoped cancellation semantics identical to Fovea.
