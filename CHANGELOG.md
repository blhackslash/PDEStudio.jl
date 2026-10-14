# Changelog

## Unreleased: typed manager

### Changed
- `PlotManager` is a typed struct: the former `state`, `ui_state` and `maps` dictionaries are fields
  (`camera_locked`, `compare_state`, `layout_cache`, `plot_cache`, `slider_cache`, `resolution_base`, `labels`,
  `presets`, `sim_presets`, `param_map`, `reverse_map`, `is_open`, `master_fig`, …). `reset_manager!` rebuilds
  the manager from the field defaults. Code that reached into `manager.state[:Key]` or `manager.maps[:Key]`
  must use the fields.
- `apply_options!` takes the cache dictionary instead of its former `manager.state` key.

### Fixed
- Restoring a menu option notified its listeners twice.
- Dynamic plot titles use the display labels (`set_label!`) like the menus and legends.
- The default direction of 3-D line grids was a string the grid builder never matched.
- The camera-lock button started in a colour that did not match its unlocked state.

## Unreleased: adaptation to the new PDEStudioCore

### New
- **Simulation presets**: the counterpart of visual presets for the physics. `save_sim_preset`, `set_sim_preset!` (replace or patch mode), `reset_sim_config!`; in the GUI, the preset buttons become *Save Sim Preset* / *Reset Simulation* while the editor shows the *Simulation* category, and presets are applied under *Simulation → Presets*. Stored in `<save path>/Presets/Simulation/`. See `docs/src/presets.md`.
- `save_plot_preset(name; description)` as API for visual presets.
- Editor: scopes *Sweep* (`config.varied`) and *Config* (`defaults`, `reference`, `postprocess`, `sources`); every method is listed, active or not; typing `default` restores the built-in / baseline value; `none` clears a function or a `nothing` parameter.
- Non-numeric parameter sweeps (scheme names, tuples, …): index sliders that show the swept value, index axes, comparisons.
- Compare over **time** (was unreachable) and over long sweeps, capped at 12 evenly spaced subplots.
- *Load CSV* accepts a bare file name (searched in the usual folders).
- Exports: `jpg`/`jpeg`/`eps` and `webm`/`mkv`; names with dots (`run_dt0.5`) are kept.

### Adapted to PDEStudioCore
- `SimulationConfig` field names (`methods`, `defaults`, `varied`, `reference`, `postprocess`, `sources`); `data.stats[:Solution]`; `get_kept_dims`/`get_kept_indices` (tensor dims in domain order); `generate_reference_simdata(ref, params, domain, res, Val(mode))`; the safe `str2val` (no code evaluation for CSV values).
- CSV files use the backend keys (`animation_FPS`, `sim_func_name`) and never display labels. Text values stay text (also `"1e3"`-like simulation parameters, which are written quoted).

### Breaking (no backwards compatibility)
- Requires the new PDEStudioCore (cleaned `SimulationConfig` fields, `dims` instead of `x_dim`/`y_dim`/`z_dim`).
- CSV layout: the sweep moved from `Config, Parameters` to `Simulation, Sweep`; `Simulation, Config` only accepts `methods`, `defaults`, `reference`, `postprocess`. Files written by earlier versions (display labels as keys, top-level `Layout`/`Plot`/`Camera`/`Exploration` categories, `Config, General`, `active_methods`, `reference_func`, `post_process_func`) are no longer read; re-export them, or rename the keys by hand.
- Removed: label-to-key reverse lookup (`backend_key`, `manager.maps[:Labels_Reverse]`), fuzzy matching of menu values loaded from files, the `:base_method_idx` UI option (use `:method_index`).

### Fixed
- The built-in dummy configuration used the old constructor order (load error).
- Labels/keys that did not survive a CSV round trip (e.g. `animation_FPS`, component labels); only the active methods' parameters were saved; the method list was saved from the UI state instead of the configuration.
- Bundled source files were never written (`hasproperty(config, :source_files)`).
- Undefined `_SIM_ROOT_PATH`; `set_sim_config!(::String)` rejected the `SubString` from the textbox; the comparison method index option (`:method_index`) was read under another name (`:base_method_idx`); the generic `initialize_base_plot!` fallback never matched.
- `allowed_dims` read from a CSV caused a structural rebuild on every load; a staged structural CSV survived later loads.
- More swept parameters than sliders → `KeyError`; a sweep edit was not reflected on the sliders.
- Reference solutions were built from the method's base parameters instead of each task's parameters, crashed without a reference function, and failed for factories defined in freshly included sources (world age).
- `_handle_slider_trigger!` returned `nothing` in a Boolean context; disabled sliders overwrote the remembered slider position with 0.
- Stale Lagrangian positions and sweep coordinates (coordinates were not notified); `scatter_3d` sync used extrema instead of the points.
- Physical axis coordinates came from the first dataset of a sweep instead of the selected one; slider extents ignored all but the first dataset.
- The legend layout used the previous compare target.
- Extrema lines were drawn for 2D data (meaningless lines).
- Single-method styles (heatmaps, surfaces, volumes, …) count `method_index` over the numerical methods first, so they show a numerical method by default instead of the reference.
- `menu.selection` was set directly instead of via `i_selected`; deleting from a `Dict` while iterating it; `nothing` from a reset `Textbox` reached `strip`; `n_frames = Int(duration * fps)` failed for non-integer products; animation formats were removed from the user's export settings in place.
- A running animation timer survived `reset_plotter!` (and the structural rebuild).
- Git info: unbounded `walkdir` from the working directory (now 3 levels, skipping hidden/build folders).
- `set_plot_preset!()` left the UI dictionaries empty until the next plot type switch.
