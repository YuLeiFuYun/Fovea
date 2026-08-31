# W5 Animated Codec Lab

This isolated Swift package compares equivalent codec surfaces without changing the Fovea production package graph.

Eligible formats are GIF and APNG. Every process prepares one retained provider, reports exact timeline metadata, materializes the selected frame and every sequential frame into the same sRGB premultiplied RGBA layout, and stores raw timing samples plus an RGBA sidecar.

The capture runner rotates comparator order across six independent process blocks and alternates format order. ImageCraft and PINRemoteImage enter the exact-pixel pair only when their selected-frame digests match. SDWebImage is reported separately when its pixels differ; visually small channel differences do not satisfy the preregistered exact-pixel gate.

## Source identity

The executable does not invent or hard-code comparator identity. The canonical capture runner injects, for every report:

- comparator name and version;
- Git HEAD commit;
- the complete unignored working-tree Git tree produced through a temporary index and `git add -A`;
- dirty state derived from the difference between the HEAD tree and working tree.

The runner records source and input identities before and after the complete capture and fails if either changes. Fixed SDWebImage and PINRemoteImage checkouts must be clean and at the preregistered commits. The local ImageCraft animation candidate may be dirty, but its exact working-tree tree is retained and never described as a published revision.

The schema-2 validator checks every report against the capture manifest, confines reports and RGBA sidecars to the capture directory, rejects missing or unexpected block artifacts, and writes an aggregate containing SHA-256 and byte-count identities for all 72 retained block artifacts. `Tools/Performance/test_w5_animated_codec_identity.py` exercises modified, deleted, untracked and executable-bit source changes plus report-identity, RGBA and source-after tampering.

Schema-1 captures that identify ImageCraft only as `local-uncommitted-source-tree` are legacy directional records. They cannot be upgraded in place or used as source-bound evidence.

This lab is codec-only. It does not measure playback clocks, deadline misses, visibility, frame-cache bytes, background work, memory pressure, energy, or network loading, and therefore cannot establish an overall animated-image product winner.

```sh
python3 Tools/Performance/capture_w5_animated_codec.py \
  --gif /path/to/input.gif \
  --apng /path/to/input.apng \
  --output .artifacts/performance/w5-animated-codec-identity-v2
```
