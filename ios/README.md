# Vita3K for iOS (Vita3KiOS)

Native iOS 16+ port of Vita3K-Plus. The emulator core (`vita3k/*` modules: CPU/dynarmic, kernel, GXM,
renderer, shader recompiler, audio …) is built **unchanged as static libraries**; `ios/` only adds the
UIKit front-end, a session bridge, the JIT bootstrap and the build/packaging pipeline.

```
ios/
  core/       C++ bridge (session thread, input, IME, install, settings) + JIT probe
  app/        UIKit app: library, game screen (CAMetalLayer), on-screen controls, settings, installer
  moltenvk/   build_moltenvk.sh – trimmed MoltenVK (iOS arm64 only)
  patches/    apply_ios_patches.py – dynarmic/oaknut JIT allocation patch
  entitlements/, scripts/, vcpkg/
```

## Build (GitHub Actions, macOS runner)
`.github/workflows/ios-build.yml` runs on every push and produces
`Vita3K-iOS.tipa` (TrollStore) and `Vita3K-iOS.ipa` (sideloading) as workflow artifacts.
Locally on a Mac: `ios/moltenvk/build_moltenvk.sh out/mvk && ios/scripts/configure_ios.sh out/mvk && ios/scripts/package_ipa.sh build-ios/ios-bin/Vita3KiOS.app dist`.

## JIT
* **TrollStore (`.tipa`)** – signed with `dynamic-codesigning`, `allow-jit`, `get-task-allow`: the app maps
  `MAP_JIT` RWX memory directly, no debugger needed. The code cache is one persistent RWX mapping, so emitting code
  never goes through `mprotect` (patched into oaknut's `CodeBlock`).
* **Sideloaded (`.ipa`)** – enable JIT with SideStore/StikDebug/JitStreamer; the app detects `CS_DEBUGGED` and uses plain RWX.
* The toolbar bolt icon shows the live state (green = ready). If missing, "Enable with TrollStore" opens
  `apple-magnifier://enable-jit?bundle-id=…` and waits for the kernel to grant it.

## MoltenVK
Built from the official v1.2.11 sources for iOS arm64 only (no macOS/tvOS/sim slices, no tools), `-O3`, stripped. Features and the
SPIRV-Cross → MSL path are untouched. Only defaults change: errors-only logging, no performance tracking/watermark/call tracing, and
pipeline compilation on all cores. Vita3K's own layer settings (`FULL_IMAGE_VIEW_SWIZZLE`, `RESUME_LOST_DEVICE`) stay.

## iOS specific performance work
* **UI-heavy games**: texture descriptor sets are now cached per frame by exact (sampler, image view) content, so HUD/text/atlas draws re-bind an existing set instead of allocating and rewriting one per draw.
* **Vertex streams** with strides not multiple of 4 (a Metal requirement) are re-strided directly into the mapped ring buffer instead of a heap copy per draw.
* Emulator threads run at `QOS_CLASS_USER_INTERACTIVE` (performance cores); touch is queued and applied every 4 ms.
* `CAMetalLayer` is `framebufferOnly` with 3 drawables, ProMotion enabled, idle timer disabled, shader pipelines compiled asynchronously by default.

## Files
Documents/Vita3K is visible in the Files app: drop `PSP2UPDAT.PUP`, `.pkg`, `.vpk`/`.zip`, `.rif` there or use **+** in the app.
