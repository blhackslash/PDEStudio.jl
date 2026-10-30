# Presets: the Look and the Physics

A study usually has two independent halves: *how it looks* (layout, axes, colors, camera, labels) and *what is computed* (parameters, methods, sweep). PDEStudio keeps them apart with two kinds of presets:

| | Visual Preset | Simulation Preset |
| :--- | :--- | :--- |
| **Holds** | Layout, plot axes, slider positions, camera, labels, exploration options, all UI styles | Shared parameters, the active methods and their parameters, the sweep, the reference and post-processing functions |
| **Ignores** | Everything in the *Simulation* category | Everything visual, and source files |
| **Folder** | `<save path>/Presets/` | `<save path>/Presets/Simulation/` |
| **Save** | *Files → Look → Save* · [`save_plot_preset`](@ref) | *Files → Simulation → Save* · [`save_sim_preset`](@ref) |
| **Apply** | *UI → Presets* + **Apply** · [`set_plot_preset!`](@ref) | *Simulation → Presets* + **Apply** · [`set_sim_preset!`](@ref) |
| **Reset** | *Files → Look → Reset* · `set_plot_preset!()` | *Files → Simulation → Reset* · [`reset_sim_config!`](@ref) |

Both are ordinary studio CSV files, so they can be versioned, shared and written by hand. Full exports (the CSV next to every exported figure) contain both halves; see [File Operations](file_ops.md).

## In the Studio

1.  Open the **Files** tab and type a name into the **Name / path** box (`Coarse Grid` is stored as `coarse_grid.csv`).
2.  *Optional:* type a description into the **Description** box.
3.  Click **Save** in the *Simulation* row (the physics) or the *Look* row (the visual settings). The status line confirms it.
4.  To apply a preset, open the **Presets** page (one row per preset, showing its description) and click the preset's **Apply** button. Applying a simulation preset sets the `Run Simulation` lock; click it to compute.

Preset files you copy into the folders appear the next time you open the *Presets* page.

## From Code

```julia
save_plot_preset("paper"; description = "Two columns, no titles")
save_sim_preset("coarse"; description = "N = 64, explicit methods only")

set_plot_preset!(:paper)      # the look
set_sim_preset!(:coarse)      # the physics (flags a re-run)
force_simulation()

reset_sim_config!()           # back to the configuration bound with set_sim_config!
set_plot_preset!()            # back to the default look
```

Built-in visual presets: `:convergence`, `:publication`, `:heatmap`, `:component`, `:compact3d`, `:nolabels` and `:darkmode`.

## Replace or Patch

A simulation preset is applied in one of two modes:

*   **`replace`** (written into every preset saved by the studio): the preset *is* the simulation. Shared parameters, methods, active methods, sweep and functions all come from the file.
*   **`patch`** (the default for hand-written files): only the entries in the file change; everything else of the bound configuration stays. Ideal for small variations such as "high resolution" or "long time".

The mode is stored in the file (`Metadata, Preset, mode, …`) and can be overridden: `set_sim_preset!(:coarse; mode = :patch)`. In both modes the source files of the bound configuration are kept, since a preset swaps parameters, not code.

*Files → Simulation → Reset* / `reset_sim_config!()` returns to the configuration last bound with [`set_sim_config!`](@ref) or loaded from a project CSV, discarding presets and editor changes applied since.

## Writing Presets by Hand

Every row is `Category, Scope, Parameter, Value`; values use Julia literal syntax and are parsed safely (nothing is evaluated). A minimal patch preset, `Presets/Simulation/hires.csv`:

```csv
Category,Scope,Parameter,Value
Metadata,Preset,description,Four times the resolution
Simulation,Shared,N,400
Simulation,Sweep,cfl,"Float64[0.2, 0.4]"
```

The simulation rows a full (replace) preset contains:

| Category | Scope | Parameter | Value (example) |
| :--- | :--- | :--- | :--- |
| `Simulation` | `Shared` | any shared parameter | `200`, `:advection_solver_1d`, `upwind` |
| `Simulation` | *method name* | any parameter override of that method | `lax_friedrichs` |
| `Simulation` | `Config` | `methods` | `Symbol[:lax_friedrichs, :upwind]` |
| `Simulation` | `Config` | `defaults` (active methods) | `Symbol[:upwind]` |
| `Simulation` | `Config` | `reference`, `postprocess` | `exact_solution`, `none` |
| `Simulation` | `Sweep` | each swept parameter | `"Float64[0.3, 0.5]"` |
| `Metadata` | `Preset` | `description`, `type` (`simulation`), `mode` | `replace` |

Text values are written as plain text (`upwind`); text that would read back as something else, such as `1e3`, is written in quotes. A visual preset uses the categories `Scene` (scopes `Plot`, `Layout`, `Camera`, `Labels`, `Exploration`) and `UI` (one scope per style group, e.g. `UI, export, animation_FPS, 30`). The axes are stored per variant (`x_axis_1d`, `y_axis_1d`, `x_axis_nd`, `y_axis_nd`, `z_axis_3d`); files from earlier versions use `x_axis`, `y_axis` and `z_axis`, which are read as the variant of the file's plot style. Keys are always the backend names, never display labels.

!!! note
    Applying a *visual* preset never changes the simulation, and applying a *simulation* preset never changes the look. Loading a full export CSV (load button, drag & drop or `set_sim_config!("file.csv")`) applies both.
