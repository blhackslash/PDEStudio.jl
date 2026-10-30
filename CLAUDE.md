# PDEStudio.jl

Makie-based interactive frontend for PDE simulations run with PDEStudioCore.jl (which it
reexports): an interactive plotter for Eulerian and Lagrangian data in 1–3 D, a
tabbed control panel with editor pages for the simulation config (and a raw `SimulationConfig` editor), visual and simulation presets, CSV
config files, and static/animated exports. Works with GLMakie (local) or WGLMakie +
Bonito (served from a compute node); CairoMakie is used for exports.

## Commands

```bash
julia --project -e 'using Pkg; Pkg.test()'                 # full suite (needs the X display; the container has Xvfb on :99)
julia --project=test -e 'using Pkg; Pkg.instantiate()'      # once
julia -t 8 --project=test test/runtests.jl                  # same suite, faster to iterate
julia --project=docs docs/make.jl                           # docs (instantiate docs env first)
```

The window is invisible in the container. To check what a change looks like, export a
frame (or `save("x.png", fig)`) and view the PNG with the Read tool; don't claim a visual
fix without having looked at the result.

## Layout

| Path | Contents |
|:-----|:---------|
| `src/PDEStudio.jl` | Module, plot caches, `PlotManager` (the single `manager`), `LOCK_HIERARCHY`, `@with_lock` |
| `src/UILogic.jl`, `src/Controls.jl`, `src/UIStyles.jl` | Window layout, tabs and editor pages (fixed widgets, parked off-screen when hidden), menus, sliders, styles |
| `src/PlottingLogic.jl`, `src/MakiePlotting.jl`, `src/Render.jl`, `src/PlottingUtils.jl` | Building and updating plots, render primitives (lines, heatmap, contour, scatter, volume) |
| `src/DataHandler.jl` | Loading sweep data from PDEStudioCore into `PlotSweepData` |
| `src/ConfigIO.jl` | CSV config read/write, provenance (git commit, package versions), exports |
| `src/Presets.jl` | Visual and simulation presets (stored under `<save path>/Presets/`) |

## Reactive architecture (read before touching UI code)

- State lives in the typed `PlotManager` (`PDEStudio.manager`); `reset_manager!` rebuilds it
  from the field defaults, so new state is a new field with a default, not a dictionary key.
- Updates flow through observables in tiers:
  `:Simulation → :Data → :Layout → :Plot → :Slider → :PlotData → :UI`.
  Tier work is wrapped in `@with_lock :Tier begin … end`. The locks are re-entrancy
  guards for synchronous observable cascades, not thread locks: the body is **silently
  skipped** if the same tier or any higher tier is currently held (except with
  `manager.bypass_locks`, used for headless exports). So code that "does nothing" is
  often running inside a higher tier's cascade; put the work in the right tier instead of
  removing the lock.
- Listeners are stored in `manager.listeners` (one per key) or `main_render_observers`;
  reuse those so they're replaced and cleaned up on rebuilds rather than stacking up.
- Keep the frontend backend-agnostic: no GLMakie- or WGLMakie-only calls in `src/`
  (only `Makie`/`CairoMakie`).

## Conventions

- Requires Julia 1.12.
- **CSV config format is a user-facing file format.** Changing categories or keys
  (`Simulation, Sweep`, `Simulation, Config`, …) breaks users' saved files; only when asked,
  and documented in the CHANGELOG under "Breaking". CSV files store backend keys, never
  display labels.
- Update `CHANGELOG.md` (the "Unreleased" section: New / Changed / Fixed / Breaking) for
  every user-visible change.
- Tests open the real plotter (`launch_plotter()` on GLMakie/WGLMakie, Xvfb display) and
  drive it through the manager, widgets and observables. New UI features need such a test,
  not only a manual check.
- Tests and experiments use a temporary save path (`set_save_path!(mktempdir())`).
- Every export needs a docstring; docs build with `checkdocs = :exports` (warnings only for
  missing docs and cross references, but don't add new ones). UI changes: update the
  matching page in `docs/src/` (the plot styles: `docs/src/render/`).
- Commit subjects: short and imperative, describing the user-visible change.
