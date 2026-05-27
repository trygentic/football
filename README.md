# Google Research Football — `trygentic` fork

This is a fork of [`google-research/football`](https://github.com/google-research/football)
with the minimum changes required to **build and visibly render on
macOS 26 (Tahoe) / Apple Silicon** with Python 3.10 + modern Boost +
CMake 4.

If you got here because your GRF window on macOS is showing pure black:
this fork fixes it. See [`PATCHES.md`](./PATCHES.md) for the technical
detail, or skip to [Install](#install) below to just get it working.

The upstream README is preserved at [`UPSTREAM_README.md`](./UPSTREAM_README.md)
— scenario list, action set documentation, RL semantics, Colab links,
training scripts, and everything else are all unchanged from upstream.

> **License:** Apache 2.0, preserved from upstream. All our commits are
> clearly labeled (`agentloop:`, `try-*:`); upstream copyright headers
> are untouched.

---

## The symptom this fork addresses

On macOS 26 (Tahoe) on Apple Silicon, `python -m gfootball.play_game`
opens a window titled "Google Research Football", but the contents are
pure black. Apple's GL driver emits exactly once:

```
UNSUPPORTED (log once): POSSIBLE ISSUE: unit 1 GLD_TEXTURE_INDEX_2D is
unloadable and bound to sampler type (Float) - using zero texture
because texture unloadable
```

Game logic runs correctly — episodes complete, rewards compute, the
offscreen `write_video=True` render path produces valid AVI files. Only
the live SDL window is broken.

## The fix

Two real GL bugs in series, both in `OpenGLRenderer3D`:

1. **Sampler incompleteness on units 1/2/3.** When a material has no
   normal/specular/illumination map, the engine leaves those units
   bound to default texture `0`. On macOS Core Profile, default
   texture `0` is sampler-incomplete (`GL_TEXTURE_MIN_FILTER` expects
   mipmaps it doesn't have), so the driver substitutes a "zero
   texture" and emits the warning above. Fragments collapse to black.
   **Fix:** create a 1×1 white dummy texture with complete sampler
   state at init, and bind it to those units instead of `0`.

2. **Stuck Cocoa swap chain.** Even with Bug 1 fixed, the window stays
   black. The diagnostic: `glReadPixels` after `SDL_GL_SwapWindow`
   returns correct pixels (that's how the offscreen video works), so
   GL is rendering fine to the back buffer — but Apple's GL→Cocoa
   bridge on Apple Silicon doesn't actually flush the swap to the
   visible `NSView` without an explicit nudge.
   **Fix:** `glFinish()` before `SDL_GL_SwapWindow`, `SDL_PumpEvents()`
   after.

Plus assorted build fixes for modern CMake 4 / Boost 1.85 / conda
Python 3.10 so the package compiles in the first place.

Full technical writeup with root-cause explanations: [`PATCHES.md`](./PATCHES.md).

Neither fix is macOS-specific in spirit — Bug 1 is a real Core-Profile
correctness issue that other GL implementations silently tolerate, and
the `glFinish` / `SDL_PumpEvents` sandwich is longstanding cross-
platform best practice. We'd happily upstream these.

---

## Install

### macOS / Apple Silicon (the case this fork solves)

```bash
# brew prerequisites
brew install cmake sdl2 sdl2_image sdl2_ttf sdl2_gfx boost@1.85

# Use a Python 3.10 env (gfootball's officially-supported max).
# Anything that gives you a clean 3.10 with conda-forge boost-python is fine;
# we use miniforge.
brew install --cask miniforge
conda create --prefix .conda -c conda-forge python=3.10 \
    boost boost-cpp sdl2 sdl2_image sdl2_ttf sdl2_gfx cmake pip psutil wheel setuptools
conda activate ./.conda

# Clone this fork at the agentloop-build branch (the default branch)
git clone --depth 1 https://github.com/trygentic/football.git
cd football
pip install --no-build-isolation .

# gfootball's gym wrappers need the pre-0.26 reset API
pip install 'gym==0.22.0' six
```

Test:

```bash
python -c "import gfootball.env as e; env = e.create_environment(env_name='academy_empty_goal_close'); print(env.observation_space, env.action_space)"
python -m gfootball.play_game --players=bot:left_players=1 --level=academy_3_vs_1_with_keeper --action_set=full --real_time=true --render=true
```

You should see a 3D pitch render with players, scoreboard, and
mini-map. If you see a black window, file an issue here with your
macOS version, chip generation, and the output of `python -m gfootball.play_game ...` from a fresh shell.

### Linux / Windows

Exactly as upstream — these patches don't change anything for non-macOS
platforms (Bug 1 is also a correctness improvement there but
practically invisible). Follow
[`UPSTREAM_README.md`](./UPSTREAM_README.md) for install steps.

---

## Branches

```
master                  ← exact mirror of google-research/football master
agentloop-build         ← default. Includes all patches. What you want to install from.

(educational / negative results)
try-sampler             ← Bug 1 fix alone (window still black)
try-finish-pump         ← Bug 1 + Bug 2 fix (renders correctly)
try-profile             ← FORWARD_COMPATIBLE flag alone (no effect, kept for record)
try-sampler-profile     ← sampler + FORWARD_COMPATIBLE (no improvement)
try-brew-sdl            ← brew SDL2 link instead of conda (no improvement)
```

Tags follow the `<upstream-version>+agentloop.<n>` convention for
stable pinning, e.g. `v2.10.3+agentloop.1`.

## How the patches were found

This fork's patches came out of a multi-day GL debugging session
documented in detail at [agentloop docs / grf-runbook-and-pitch-view.md →
Part D — GL Investigation Log](https://github.com/trygentic/agentloop/blob/main/docs/architecture/neurosymbolic/grf-runbook-and-pitch-view.md).

The short version: the warning was a real bug, but it was masking a
*second* real bug, and only fixing both in series produces a working
window.

## Upstream relationship

We've documented both bugs and the fixes thoroughly here so they can be
cherry-picked into upstream. The two rendering fixes (Bug 1 and Bug 2)
are clean improvements that should apply to any platform; only the
build fixes are macOS-stack-specific.

If `google-research/football` is still accepting PRs at the time you
read this and you got value from this fork, please link this repo
under their issues to raise the signal — the more people who confirm
the bugs, the better the chance of an upstream merge.

If upstream is dormant: this fork is functional and stable; pin to a
tag and ship.

---

## Acknowledgments

- The original [google-research/football](https://github.com/google-research/football)
  team — the game, the scenarios, and the entire RL environment.
- [Bastiaan Konings Schuiling](https://github.com/bksch) for the
  original open-source GameplayFootball engine GRF is built on.
- The [AgentLoop](https://github.com/trygentic/agentloop) project,
  which is where these patches were extracted from and which uses
  this fork as the rendering backend for its RL training stack.
