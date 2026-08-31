# Fovea automation contract

## Nonintrusive macOS experiment windows

Automated benchmarks, probes, capture scripts, and temporary experiments must not place visible test UI on the user's desktop.

- Any AppKit `NSWindow` created only to preserve real-screen, WindowServer, or view-bound display-link semantics must be nonintrusive before it is ordered: no shadow, ignore mouse events, and use `alphaValue = 0.0` (or the repository's equivalent nonintrusive mode).
- ScreenCaptureKit probes that require opaque desktop-independent window capture are the only exception to `alphaValue = 0.0`: keep them opaque but set `window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 3)` before ordering, which places the probe below the wallpaper layer. Do not center an opaque probe at a normal window level.
- Do not use `--window-presentation visible` to obtain visible benchmark UI. The MacLab accepts that legacy argument only for compatibility and still executes nonintrusively.
- This invariant applies equally to ad-hoc sources and binaries under `.codex_tmp`; temporary Core Animation or AppKit probes are not exempt.
- Do not run stale experimental binaries that predate nonintrusive-window support. Rebuild the variant from current patched source instead.
- A deliberately visible test window requires an explicit user request in the current task. Never enable one merely for measurement convenience.
