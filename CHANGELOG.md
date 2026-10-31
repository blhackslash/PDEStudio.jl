# Changelog

## Unreleased: GUI redesign (breaking)

The control panel was rebuilt around tabs and editor pages. Widgets are still created once per window: hidden panels
and unused rows are parked outside the figure (a hidden Makie button or slider would otherwise still react to clicks),
so switching tabs or pages never touches the plots. The window is 500 px of controls plus the plots and fits a Full HD
screen (the plot area keeps its titles and axis labels inside its own box).

### New
- **Tabs:** *Plot*, *Methods*, *Shared*, *UI*, *Files*, *Advanced* (`PDEStudio.show_tab!`). Always visible below
  them: a **status line** with the result of the last action (edits and refused values, method changes, presets,
  runs, loads, exports; green / orange / red), *Play Anim* / *Lock Camera*, the execution buttons and the sliders.
- **Plot tab:** one option per row; *Layout options* (Apply Layout) and *Plot options* (Update Plot). The **plot
  style** is chosen on a page of all supported styles, grouped by Lines, Scatter, Contour, Heatmap and Volume
  (Lagrangian data: the scatter styles of its dimension). Plot width, plot height and grid columns take any whole
  number (50–5000 px, 1–12 columns).
- **Methods tab:** every method with *active / off*, a *Show: active / disabled / all* filter, *Edit ›* for its
  parameters (inactive methods too) and an *Order ▲▼* view of the drawing order (`defaults`) with ▲ ▼.
- **Shared tab:** the shared parameters, one row each.
- **UI tab:** a fixed overview: *General* (fonts, HUD, outliers), *Labels* (*Plot*: title and axis labels; the
  display names of components, variables and methods), *Axes* (every axis variant: X/Y 1D, X/Y 2D/3D, Z 3D) and
  *Plot styles* (one page per plot type with the options it uses). The pages of the active plot are highlighted.
- **Files tab:** Name / path and Description boxes (typed text counts without pressing Enter), Load CSV, Export,
  *Settings ›* (export settings), *Resolution ›* (points per dimension of the data and the references), and all
  presets: Save / Reset / *Presets ›* for simulation and look presets. *Presets ›* lists them with *Apply* and
  *Edit ›*, which edits the rows of the preset file (change, ✕ delete, add; written right away).
- **Advanced tab:** the `SimulationConfig` itself: `shared`, `varied` (the sweep), the fields (`defaults`,
  `reference`, `postprocess`, `sources`) and the list of all methods. Values are typed Julia literals, parsed
  strictly; ✕ deletes a key; keys are added with a type (`auto`, `Int`, `Float64`, `Bool`, `String`, `Symbol`,
  `Tuple`, vectors); methods are added and deleted.
- **Julia configuration files** load like CSV files (`set_sim_config!("config.jl")`, *Files → Load*, drop): the
  last expression is the `SimulationConfig` or a function returning it; the file is added to `sources`. Loading
  code (a `.jl` file or a CSV with bundled sources) needs a second click on *Load* and shows a warning.
- **Files → Browse…** opens the system's file dialog (AppleScript, PowerShell, `zenity` or `kdialog`; not in a
  browser). `PDEStudio.FILE_DIALOG[]` can be replaced.
- **Editor pages:** one row per entry (name, value, a button: on/off for Booleans, ↺ to restore the default), 16
  rows per page with ◀ ▶ for longer lists, ◀ Back to the overview; `PDEStudio.show_editor_page!` opens a page from
  code.

### Changed
- Only the sliders with a choice to make are shown (unused parameter sliders, dimensions on a plot axis or missing
  from the data are hidden); the sliders are at the bottom of the panel.
- Every axis variant keeps its own settings (`manager.ui[:x_axis_1d]`, …), so switching between 1D and 2D/3D plots
  no longer resets them; `manager.ui` always holds every UI scope.
- Editor input that is no literal (`[1, 2`, `abc`) is refused for parameters that aren't text, with a message in the
  status line, instead of silently turning the parameter into text; quoted text (`"abc"`) is accepted.
- Bundled sources are more robust: exports copy them into `<name>_sources/` under their own file names (so bundled
  files include each other), each copy runs as if it were its original while that folder exists (relative includes
  and `@__DIR__` resolve there), and a failing copy no longer aborts the load (the parameters come from the CSV; the
  status line names the error). Older exports (`<name>_source_<i>.jl`) still load. The docs describe how to write
  configuration files that reload reliably (*File Operations*).
- Load results are reported in the status line (the load button only changes colour); dropping a CSV no longer
  switches tabs.

### Breaking
- **Tabs and widgets:** the tabs are `:plot`, `:methods`, `:shared`, `:ui`, `:files`, `:advanced`. Removed from
  `manager.widgets`: `:editor_cat`, `:editor_scope`, `:editor_key`, `:editor_text`, `:editor_toggle`, `:mode_button`,
  `:method_toggle`, `:base_plot` (and `manager.active_target`, `manager.is_activate_mode`). `:plot_width`,
  `:plot_height` and `:compare_columns` are `NumberBox`es and `:plot_style` is a `StyleChoice` (`.selection` holds
  the value as before). The preset buttons are in the Files tab (`:save_sim_preset_button`, `:reset_sim_button`,
  `:save_presets_button`, `:clear_presets_button`, description in `:preset_desc_text`). Scripts that drove the
  editor should use `show_editor_page!` and the rows (`manager.editor_row_keys`, `:editor_row_<i>_text` /
  `:editor_row_<i>_button`).
- **No base plot:** the `base_plot` layout option is gone (`Scene, Layout, base_plot` rows of older files are
  ignored).
- **UI CSV rows of the axes** use the variant scopes (`UI, x_axis_nd, padding, …`). Older files with `x_axis` /
  `y_axis` / `z_axis` still load (as the variant of their plot style), but older versions can't read the axis
  settings of new files. `manager.ui[:x_axis]` no longer exists (`PDEStudio._axis_ui(:x_axis)` is the active one).
- **Removed editor features:** the `permutation` key (use the Methods tab's *Order ▲▼*), the Sweep and Config pages
  with their conveniences (single values as sweeps, unquoted text sweeps; use the Advanced tab), the Presets pages
  of the editor and the `create_new` preset entry (use the Files tab).

## Unreleased: typed manager

### New
- *Simulation → Config → permutation* shows the order of the active methods (`defaults`) as a permutation of their
  automatic order (references first, then alphabetical, as the method menus list them), e.g. `[3, 1, 2]`. Typing a
  new permutation reorders `defaults`, so long method names don't have to be retyped to change the order of
  legends, colours and the *Methods* comparison. It is a view of `defaults` and is not written to CSV files.

### Changed
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
