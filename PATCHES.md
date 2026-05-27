# Patches in this fork

This fork of [`google-research/football`](https://github.com/google-research/football)
adds the minimum changes needed for **Google Research Football to build
and visibly render on macOS 26 (Tahoe) on Apple Silicon, with Python
3.10 + modern Boost + CMake 4**.

All patches are content-free behavioral fixes — no functional change to
gameplay, RL semantics, or training results. They address real bugs in
the renderer and the build that have accumulated since the upstream
project went into maintenance.

Tested on M-series Mac, macOS 26.x, Python 3.10.20, Boost 1.85
(headers + system) + Boost 1.90 (python bindings via conda-forge),
CMake 4.3.1.

---

## TL;DR

| Branch                              | Patch                                                              | Why it exists                                                                                                                                |
| ----------------------------------- | ------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------- |
| `agentloop: build fixes`            | Loosen `setup.py` gym pin; fix `build_game_engine.sh` CMake flags; force Python framework off in `CMakeLists.txt` | macOS + Python 3.10 + Boost 1.85 + CMake 4 build path                                                                                        |
| `try-sampler`                       | Bind 1×1 dummy texture to units 1/2/3 instead of default texture 0 | Default texture 0 is sampler-incomplete on Core Profile; driver substitutes zero-texture; fragments collapse to black                        |
| `try-finish-pump` (cpp + proc loader) | `glFinish` before `SDL_GL_SwapWindow`; `SDL_PumpEvents` after      | Apple's GL→Cocoa swap chain doesn't flush to the visible NSView without explicit GL sync + event-loop pump on Apple Silicon                  |

Together these turn a black-window install into a fully rendering
native 3D match.

---

## Bug 1 — Sampler incompleteness on texture units 1/2/3

### Symptom

The live window opens but renders pure black. Apple's GL driver emits
exactly once:

```
UNSUPPORTED (log once): POSSIBLE ISSUE: unit 1 GLD_TEXTURE_INDEX_2D is
unloadable and bound to sampler type (Float) - using zero texture
because texture unloadable
```

### Root cause

In `OpenGLRenderer3D::RenderVertexBuffer`, the normal/specular/
illumination textures are only bound to units 1/2/3 if the material
has them:

```cpp
if (has_normal && normalTextureID != currentNormalTextureID) {
  SetTextureUnit(1);
  glBindTexture(GL_TEXTURE_2D, normalTextureID);
}
```

Otherwise unit 1 retains whatever was bound before — either default
texture name `0`, or the end-of-function cleanup binds it back to `0`:

```cpp
SetTextureUnit(1);
glBindTexture(GL_TEXTURE_2D, 0);   // ← leaves unit 1 bound to default texture
```

The shader (`media/shaders/simple.frag`) still samples `map_normal`
unconditionally regardless of `has_normal`. On macOS Core Profile,
default texture `0` is **sampler-incomplete**: its built-in
`GL_TEXTURE_MIN_FILTER` is `GL_NEAREST_MIPMAP_LINEAR`, which requires
mipmaps that texture 0 doesn't have. The driver's response is to
substitute a "zero texture" (transparent) and emit the diagnostic.
Lighting collapses the fragment color through the simple→lighting→
postprocess chain into pure black.

This is not Apple-specific — any Core Profile implementation enforces
sampler completeness — but on Linux the default driver is more
permissive and silently renders with semi-broken textures, while
Apple's hardens to all-zero.

### Fix

Create a 1×1 white texture at context init, complete in all sampler
state, and bind it to units 1/2/3 whenever no material texture is
provided:

```cpp
// In OpenGLRenderer3D::CreateContext, after shader loading:
mapping.glGenTextures(1, &dummyID);
mapping.glBindTexture(GL_TEXTURE_2D, dummyID);
const unsigned char whitePixel[4] = {255, 255, 255, 255};
mapping.glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, 1, 1, 0, GL_RGBA,
                     GL_UNSIGNED_BYTE, whitePixel);
mapping.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
mapping.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
mapping.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
mapping.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
mapping.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_BASE_LEVEL, 0);
mapping.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAX_LEVEL, 0);
dummyTexID = (int)dummyID;
```

Then replace the `has_normal` / `has_specular` / `has_illumination`
guards on the bind calls so we always bind *something* complete:

```cpp
SetTextureUnit(1);
mapping.glBindTexture(GL_TEXTURE_2D,
                      has_normal ? (GLuint)normalTextureID
                                 : (GLuint)dummyTexID);
```

And replace the end-of-function cleanup `glBindTexture(GL_TEXTURE_2D, 0)`
on units 1/2/3 with `dummyTexID` instead.

### Cost

Negligible. One extra 1×1 texture in VRAM. Per-frame: same number of
`glBindTexture` calls as before; just bound to a different texture ID.

---

## Bug 2 — Stuck Cocoa swap chain

### Symptom

Even with Bug 1 fixed and the GL diagnostic warning gone, the live
window still renders pure black on macOS 26 / Apple Silicon. The
offscreen render path (`write_video=True`) works correctly and
produces valid AVI files.

### Root cause

In `OpenGLRenderer3D::SwapBuffers`:

```cpp
void OpenGLRenderer3D::SwapBuffers() {
  last_screen_.resize(context_width * context_height * 3);
  if (window) {
    SDL_GL_SwapWindow(window);
  }
  glReadPixels(0, 0, context_width, context_height, GL_RGB,
               GL_UNSIGNED_BYTE, &last_screen_[0]);
}
```

The diagnostic that cracked this: `glReadPixels` after
`SDL_GL_SwapWindow` returns **correct pixels** (that's how the
offscreen video path captures frames). So GL is rendering correctly
to the back buffer, and `SDL_GL_SwapWindow` is doing its GL-side job
of promoting the back buffer to the front. But the Cocoa-side of the
swap — flushing the front buffer to the visible NSView — silently
doesn't happen.

This is Apple-driver behavior on Apple Silicon: the GL→Cocoa bridge
needs explicit nudges in two places. Without `glFinish`,
`SDL_GL_SwapWindow` can return before GL has actually completed all
pending operations. Without `SDL_PumpEvents`, the Cocoa event loop
doesn't run between swap and the next draw, so the OS never "sees"
that the window needs to be redrawn.

### Fix

```cpp
void OpenGLRenderer3D::SwapBuffers() {
  last_screen_.resize(context_width * context_height * 3);
  if (window) {
    mapping.glFinish();        // force GL to complete before swap
    SDL_GL_SwapWindow(window);
    SDL_PumpEvents();          // kick Cocoa to flush to NSView
  }
  glReadPixels(...);
}
```

Companion change in `sdl_glfuncs.h`: `glFinish` was declared
`SDL_PROC_UNUSED` (never loaded), so the function pointer wasn't
resolved. Change to `SDL_PROC` to enable loading.

### Cost

One GL synchronization point per frame and one event-queue pump. On a
modern Apple Silicon GPU this is on the order of 100µs per frame at
50fps — well below noticeable. The benefit (presentation actually
happening) dwarfs the cost.

### Why this isn't a macOS hack

`glFinish` before swap is a longstanding cross-platform best practice
for low-latency rendering; many production engines do it
unconditionally. `SDL_PumpEvents` is a no-op when called from the
main thread that owns the window, which is exactly the case here.
Neither change risks correctness on any other platform; both are
straight improvements.

---

## Build fixes for macOS / modern toolchain

These are needed just to compile against the system as of late 2025 /
early 2026. None affect gameplay or rendering.

### `setup.py`

- `'gym<=0.21.0'` → `'gym>=0.21.0'` — gym 0.21.0's `extras_require`
  format is rejected by modern `packaging`, so the legacy pin makes
  pip install fail before metadata generation. Externally pin to
  `gym==0.22.0` (the last release with the pre-0.26 `reset()`
  signature gfootball wraps).

### `gfootball/build_game_engine.sh`

Adds CMake flags that the upstream build leaves implicit, but that
modern toolchains require:

- `-DCMAKE_POLICY_VERSION_MINIMUM=3.5` — CMake 4.x dropped support
  for `cmake_minimum_required` below 3.5.
- `-DBoost_NO_BOOST_CMAKE=ON` — modern Boost ships a modular CMake
  config that resolves components differently from upstream's
  expectations; the legacy `FindBoost` module is more compatible.
- `-DBOOST_ROOT="$PYTHON_PREFIX"`, `-DPython_ROOT_DIR="$PYTHON_PREFIX"`,
  `-DCMAKE_PREFIX_PATH="$PYTHON_PREFIX"` — force CMake to use the
  active Python's prefix (typically a conda env) instead of whatever
  system Python it discovers via framework search.
- Explicit `PYTHON_EXE` lookup using `${GFOOTBALL_PYTHON:-...}` so
  the env can be configured from outside; otherwise pip's build
  subprocess inherits a stripped `PATH` that resolves `python3` to
  the wrong interpreter.

### `third_party/gfootball_engine/CMakeLists.txt`

Adds two lines before `find_package(Python COMPONENTS Development REQUIRED)`:

```cmake
set(Python_FIND_FRAMEWORK NEVER)
set(Python_FIND_STRATEGY LOCATION)
```

Passing `-DPython_FIND_FRAMEWORK=NEVER` on the command line isn't
sufficient because CMake's `find_package(Python ...)` overrides
cache values internally. Setting it as a regular variable before
the call binds it.

Without this, CMake finds the system framework Python (currently
3.14 on macOS via Homebrew) instead of the build's active conda
Python 3.10, then tries to link against `libboost_python314.dylib`
(which doesn't exist locally) and fails.

---

## License & upstream relationship

The original [google-research/football](https://github.com/google-research/football)
is Apache 2.0. This fork preserves the upstream license. All commits
are signed-off with the patch author and clearly marked `agentloop:`
or `try-<branch>:` so they can be cherry-picked or stripped cleanly.

We'd happily upstream these patches — Bug 1 and Bug 2 are both real
upstream issues that affect anyone trying to render on macOS Core
Profile, not just our specific stack. The repo appears to be in
deep maintenance mode upstream (no merged PRs in roughly two years
as of writing); we're publishing the fork primarily so other Apple
Silicon users hitting the same wall have a working starting point.

If you found this fork and got things working: please file an issue
or PR upstream linking back here, to help raise the signal that
these fixes are needed.
