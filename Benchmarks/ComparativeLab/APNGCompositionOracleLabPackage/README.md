# W5 APNG Composition Oracle Lab

This isolated macOS package adjudicates APNG full-canvas composition semantics and distinguishes parsed subrect metadata from actual decoded-frame materialization without changing the Fovea production package graph.

It compares three frame paths on full-canvas disposal fixtures and true subrect fixtures:

- the unpublished local ImageCraft animation candidate;
- APNGKit with `.preRenderAllFrames` and its decoded-image cache;
- Apple ImageIO through `CGImageSourceCreateImageAtIndex`.

The lab retains one RGBA sidecar per comparator and frame, normalizes every image into sRGB premultiplied RGBA, and reports pairwise exact digests plus independently recomputed pixel differences. It also compares ImageCraft and APNGKit timeline and loop semantics within a one-microsecond tolerance.

For ImageCraft, every frame report additionally records:

- the APNG metadata rect, disposal method, and blend operation;
- metadata-subrect RGBA bytes;
- actual decoded RGBA bytes and dimensions;
- whether the returned frame is full canvas.

The capture runner binds exact source identities for `AnimatedImageTypes`, `AnimatedContainerInspector`, `APNGAnimationInspector`, `ImageIOAnimatedImageDecoder`, `ImageIOAnimationFrameProvider`, and `ImageIOAnimationFrameRenderer`. Its source audit verifies that the inspector publishes rect/disposal/blend metadata, the decoder rejects unaligned multi-frame separate-default ImageIO indexing, and supported requested indices still map directly to full-canvas ImageIO materialization with no explicit checkpoint state in the bound provider/renderer files.

The canonical capture also binds:

- Fovea, ImageCraft, APNGKit, and Delegate HEAD plus complete unignored working-tree Git trees;
- input bytes before and after capture;
- macOS product/build identity;
- Xcode and Swift versions;
- ImageIO bundle metadata and Info.plist SHA-256.

Apple ImageIO is an additional system-framework comparator, not an authority by declaration. Its executable is supplied through the dyld shared cache, so the evidence binds the OS build and framework metadata instead of claiming a standalone binary hash.

APNGKit's `.preRenderAllFrames` policy is useful for correctness comparison but is not equivalent to ImageCraft's on-demand window, memory, or performance policy. Likewise, APNG frame rect metadata must not be described as subrect decoded storage or a checkpoint implementation: the current ImageCraft layer returns complete full-canvas frames and delegates supported composition to Apple ImageIO. A static default image before the first `fcTL` defines a different index domain; the current candidate accepts the aligned one-animation-frame special case and fails closed for the multi-frame case until an owned animation-index decoder exists.

This lab does not produce a speed, peak-memory, cache-occupancy, replay-depth, player, energy, thermal, network, or physical-device claim.

An isolated owned executable specification now exercises the next architecture step without entering production. `Tools/Performance/w5_apng_reference.py` parses retained APNG bytes into true raw subrect RGBA and composes a straight-alpha canvas using exact source-over numerators with floor division; only the emitted frame is premultiplied with nearest rounding. Its source-bound capture reproduces all 21 retained ImageCraft and Apple ImageIO frames byte-for-byte. It remains Python research code rather than a production Swift decoder. The separate checkpoint model rejects retained full-canvas checkpoints as the general default at the 32 MiB/eight-frame reference point. See `docs/research/w5-apng-owned-reference-2026-08.json` and `docs/research/w5-apng-checkpoint-model-2026-08.json`.

```sh
python3 Tools/Performance/capture_w5_apng_composition_oracle.py \
  --output .artifacts/performance/w5-apng-composition-oracle-v5

python3 Tools/Performance/capture_w5_apng_reference.py \
  --oracle-evidence .artifacts/performance/w5-apng-composition-oracle-v5 \
  --output .artifacts/performance/w5-apng-owned-reference-v1
```

The synthetic tamper contract is:

```sh
python3 Tools/Performance/test_w5_apng_composition_oracle.py
python3 Tools/Performance/test_w5_apng_reference.py
python3 Tools/Performance/test_w5_apng_reference_capture.py
python3 Tools/Performance/test_w5_apng_checkpoint_model.py
python3 Tools/Performance/test_w5_apng_checkpoint_capture.py
```
