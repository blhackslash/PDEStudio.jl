# Changelog

## Unreleased: typed manager

### New
- *Simulation → Config → permutation* shows the order of the active methods (`defaults`) as a permutation of their
  automatic order (references first, then alphabetical, as the method menus list them), e.g. `[3, 1, 2]`. Typing a
  new permutation reorders `defaults`, so long method names don't have to be retyped to change the order of
  legends, colours and the *Methods* comparison. It is a view of `defaults` and is not written to CSV files.

### Changed
- The control panel is organised in tabs: **Plot**, **Layout**, **Simulation**, **UI**, **Labels** (the three editor
  categories, which replace the category dropdown) and **Files**. The filename box, the sliders, *Play Anim* /
  *Lock Camera* and the execution buttons are always visible below the tabs, so the window is much shorter (it fits
  a Full HD screen). All widgets are still created once per window: the panels of the other tabs are hidden and
  parked outside the figure (hidden Makie buttons and sliders would otherwise still react to clicks). Switching tabs
  doesn't touch the plots. A window opens on the Plot tab; `PDEStudio.show_tab!` selects one from code.
- The editor has pages instead of the Scope / Parameter dropdowns: each editor tab opens on an overview with one
  button per scope (with the number of entries), and a page lists every entry of the scope as a row (name, value box
  and a button: on/off for Booleans, ↺ to restore the default, *Apply* for presets). Long scopes and overviews get
  ◀ ▶ pages; ◀ Back returns to the overview. Rows and buttons are a fixed set bound to the open page.
  `PDEStudio.show_editor_page!(:simulation, :shared)` opens a page from code.
- Only the sliders with a choice to make are shown (unused parameter sliders and dimensions on a plot axis or not in
  the data are hidden), and the sliders moved to the bottom of the control panel.
- The Layout and Plot tabs are one **Plot** tab (layout options above, plot options below). Plot width, plot height
  and grid columns are number boxes for any value (50–5000 px, 1–12 columns) instead of fixed menus.
- **Methods** tab (in place of the Mode button and the method dropdown): every method with an *active / off* button,
  a *Show: active / disabled / all* filter, *Edit ›* for its parameters (inactive methods too) and an *Order ▲▼*
  view of the active methods in drawing order with ▲ ▼ to move them. The Simulation overview no longer lists the
  methods.
- A status line below the tabs shows the result of the last action (edits and refused values, method changes,
  presets, runs, CSV loads, exports), coloured by outcome. The load button no longer carries the load messages, and
  dropping a CSV no longer switches to the Files tab.
- The plot area keeps its titles and axis labels inside its own box, so they no longer add height to the window
  (about 140 px less).
- The order of `defaults` is kept and used as the display order (legend entries, colours, the *Methods*
  comparison). Reorder the list under *Simulation → Config → defaults* (or in `SimulationConfig`) to override
  the automatic order; activated methods are appended. Without explicit defaults the order is still references
  first, then alphabetical.
- `PlotManager` is a typed struct: the former `state`, `ui_state` and `maps` dictionaries are fields
  (`camera_locked`, `compare_state`, `layout_cache`, `plot_cache`, `slider_cache`, `resolution_base`, `labels`,
  `presets`, `sim_presets`, `param_map`, `reverse_map`, `is_open`, `master_fig`, …). `reset_manager!` rebuilds
  the manager from the field defaults. Code that reached into `manager.state[:Key]` or `manager.maps[:Key]`
  must use the fields.
- `apply_options!` takes the cache dictionary instead of its former `manager.state` key.
- The editor's *Simulation* category lists only the active methods as scopes (activate a method to edit it).
- CSV files (exports and simulation presets) store only the active methods and their parameters; inactive methods
  of the bound configuration are no longer written.

### Breaking
- The editor widgets `:editor_cat`, `:editor_scope`, `:editor_key`, `:editor_text` and `:editor_toggle` are gone
  from `manager.widgets` (and `manager.active_target`), as are the method widgets `:mode_button` and
  `:method_toggle` (and `manager.is_activate_mode`); `:plot_width`, `:plot_height` and `:compare_columns` are
  `NumberBox`es (`.selection` still holds the value, `.box` is the text box). The tabs are `:plot`, `:methods`,
  `:simulation`, `:ui`, `:labels`, `:files` (no `:layout`). Scripts that drove the editor through them should use
  `PDEStudio.show_editor_page!` and the rows (`manager.editor_row_keys`, widgets `:editor_row_<i>_text` /
  `:editor_row_<i>_button`). The CSV format is unchanged.

### Fixed
- A numerically constant field (e.g. the `Float32` initial state of a Riemann problem) made the filled contour
  style fail inside Makie, which could abort `launch_plotter()` when that style was still selected from a previous
  session. The colour range of such fields is now widened (relative `1e-3`), and a failing plot update is reported
  as an error instead of taking the studio down.
- An invalid colour typed into the editor (`hud → color`, `plot_style → colors`, or a wrong `color_map`) is
  rejected with a warning; before, it was stored and failed later inside the render loop, after which nothing could
  be drawn. The HUD also falls back to its default colour if its colour setting is invalid.
- The editor opens on *Presets*; with a configuration bound before `launch_plotter()` it opened on *Config*.
- Presets saved or applied through the API (`save_plot_preset`, `save_sim_preset`, `set_plot_preset!`,
  `set_sim_preset!`) and files copied into the preset folders appear in the *Presets* list right away (the folders
  are rescanned when the parameter menu is opened); before, the list only refreshed when the scope was re-selected,
  e.g. by switching the category and back.
- Values shown by the editor (including preset descriptions) were drawn in the grey placeholder colour, because
  only the displayed text of the box was set; the stored text is now kept in sync.
- A preset description typed under *create_new* is used by *Save Presets* even if Enter was not pressed; editing the
  description of an existing preset is written to its file.
- Restoring a menu option notified its listeners twice.
- Dynamic plot titles use the display labels (`set_label!`) like the menus and legends.
- The default direction of 3-D line grids was a string the grid builder never matched.
- The camera-lock button started in a colour that did not match its unlocked state.

## Unreleased: adaptation to the new PDEStudioCore

### New
- **Simulation presets**: the counterpart of visual presets for the physics. `save_sim_preset`, `set_sim_preset!` (replace or patch mode), `reset_sim_config!`; in the GUI, the preset buttons become *Save Sim Preset* / *Reset Simulation* while the editor shows the *Simulation* category, and presets are applied under *Simulation → Presets*. Stored in `<save path>/Presets/Simulation/`. See `docs/src/presets.md`.
- `save_plot_preset(name; description)` as API for visual presets.
- Editor: scopes *Sweep* (`config.varied`) and *Config* (`defaults`, `reference`, `postprocess`, `sources`); every active method is listed; typing `default` restores the built-in / baseline value; `none` clears a function or a `nothing` parameter.
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
