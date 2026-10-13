# PDEStudio.jl

**PDEStudio.jl** is an interactive, Makie-driven graphical frontend for the real-time visualization and exploration of Partial Differential Equation (PDE) simulations.

It is built directly on top of its numerical backend **PDEStudioCore.jl** (reexported, so `using PDEStudio` is enough) and turns its simulation data into responsive 1D, 2D and 3D visualizations. It features a hierarchical editor, CSV-based presets for both the look and the physics of a study, and a rendering engine that handles Eulerian grids and Lagrangian particle systems.

PDE simulations often have to run on servers. There are two ways to work with remote machines:

> **Headless Mode:** The backend `PDEStudioCore` runs and stores simulations on its own, so it can create `PDEStudio`-compatible data on the server, which you then copy for local exploration with `GLMakie`. This gives the best performance, but can mean large data transfers.

> **Web Mode:** `PDEStudio` is Makie-backend agnostic, so you can use `WGLMakie` (powered by `Bonito`) to serve the studio from the server to a web browser. This greatly reduces data transfer, at the cost of performance and latency.

---

## 🎨 Interactive Architecture

The studio is built around a central, reactive state manager that links the live simulation data to the Makie render loop.

*   **Eulerian & Lagrangian Support:** Rendering primitives adapt to the data: grid-based heatmaps, surfaces and volumes, or point-based scatter plots. Data stored in the other representation is converted on the fly.
*   **Hierarchical Editor:** Shared parameters, method parameters, the parameter sweep, the active methods, UI styles, export settings and display names, all in one Category → Scope → Parameter editor (see [Advanced Editors](editors.md)).
*   **Dynamic Layouts:** Multi-plot comparisons (methods, components, time steps or any swept parameter), linked or decoupled axes and detached legends.
*   **Any Sweep:** Swept parameters can be numbers or anything else (scheme names, tuples, …); non-numeric sweeps get index sliders that display the swept value.

---

## 💾 Serialization & Presets

**PDEStudio.jl** stores its state in plain CSV files (`Category, Scope, Parameter, Value`, RFC 4180).

| File | What it holds | Created with |
| :--- | :--- | :--- |
| **Export CSV** | Everything: physics, look, sweep, git commits, Julia versions, bundled sources | *Export* (next to every figure/animation) |
| **Visual Preset** | The look only (layout, axes, camera, labels, UI styles) | *Save Presets*, [`save_plot_preset`](@ref) |
| **Simulation Preset** | The physics only (shared/method parameters, active methods, sweep, functions) | *Save Sim Preset*, [`save_sim_preset`](@ref) |

Visual presets apply to any simulation; simulation presets swap the physics while the look stays as it is. See [Presets](presets.md).

*   **Readable & Editable:** Keys are written as their raw backend names (`animation_FPS`, `sim_func_name`), values in Julia literal syntax (`Float64[0.2, 0.5]`, `:upwind`). Display labels never appear in files, so renaming a label does not affect saved states.
*   **Type-Preserving Parsing:** Values are read back with the safe literal parser `str2val` into the type they were saved as (vectors, tuples, symbols, dictionaries, …). Text stays text.
*   **Drag-and-Drop:** Drop a CSV onto the studio window (or type its path or file name into the filename box and click the load button) to recreate a saved state.

> **Security Note:** CSV values are parsed safely; no code in a value is ever evaluated. However, an export CSV can *bundle source files* (the `sources` of a `SimulationConfig`, copied next to the export), and loading such a CSV **executes those files** to restore the solvers. Only load exports you trust. Presets never contain source files.

---

## 🎬 Exporting & Animations

The export pipeline renders a pristine copy of the plot, independent of the interactive window.

*   **Static Frames:** High-DPI `.png`/`.jpg`, and vector `.pdf`, `.svg` and `.eps` via CairoMakie, with optional rasterization of heavy 3D plots.
*   **Animations:** `.mp4`, `.webm`, `.mkv` or `.gif`, sweeping any slider (time, a physical dimension or a swept parameter) with a locked camera, a custom frame rate and duration.

See [File Operations](file_ops.md) for the details.

---

## 🛠️ Main API Functions

| Function | Purpose |
| :--- | :--- |
| [`launch_plotter`](@ref)`()` | Builds the studio window and its reactive listeners; returns the `Figure`. |
| [`set_sim_config!`](@ref)`(config)` | Binds a `SimulationConfig` (or a CSV: `set_sim_config!("name.csv")`). Also the baseline for *Reset Simulation*. |
| [`force_simulation`](@ref)`()` | Runs the bound configuration (same as clicking *Run Simulation*). |
| [`set_plot_preset!`](@ref)`(name)` | Applies a built-in or saved visual preset; `set_plot_preset!()` restores the default look. |
| [`save_plot_preset`](@ref)`(name)` | Saves the current look as a visual preset. |
| [`save_sim_preset`](@ref)`(name)` | Saves the bound simulation as a simulation preset. |
| [`set_sim_preset!`](@ref)`(name)` | Applies a simulation preset (replace or patch). |
| [`reset_sim_config!`](@ref)`()` | Restores the configuration last bound with `set_sim_config!`. |
| [`set_mode!`](@ref)`(:eulerian / :lagrangian)` | Switches between grid and particle rendering. |
| [`set_allowed_dims!`](@ref)`(dims)`, [`set_max_params!`](@ref)`(n)` | Structural limits: the physical dimensions and the number of parameter sliders. |
| [`set_resolution!`](@ref)`(dim, n)` | Display resolution of a dimension (data is resampled for display). |
| [`reset_plotter!`](@ref)`()`, [`reset_manager!`](@ref)`()` | Closes the window / resets the whole studio without restarting Julia. |

---

## 🚀 Basic Workflow

```julia
using PDEStudio   # reexports PDEStudioCore
using GLMakie     # or WGLMakie for browser rendering

# 1. The physics (see the PDEStudioCore documentation)
shared  = create_param_dict(:N => 100, :cfl => 0.5, :sim_func_name => :my_solver)
methods = create_method_dict(:upwind => create_param_dict(:scheme => "upwind"),
                             :lax_friedrichs => create_param_dict(:scheme => "lax_friedrichs"))
config  = SimulationConfig(shared, methods, [:upwind, :lax_friedrichs];  # active methods (`defaults`)
                           varied = create_varied_dict(:cfl => [0.3, 0.5, 0.8]),
                           reference = :my_exact_solution)

# 2. Launch and display the studio
fig = launch_plotter()
display(fig)

# 3. Bind the physics and run it (or click "Run Simulation")
set_sim_config!(config)
force_simulation()
```

A complete, runnable script is `examples/advection_1d.jl`.

---

## ⚙️ Advanced Workflow (Custom Macros & Web Servers)

For extensive experiment libraries or remote servers, PDEStudio can be wrapped in custom macros for rapid deployment.

Below is a pattern that configures a `Bonito` web server for `WGLMakie`, resolves configuration paths, backs up executed configurations for reproducibility, and binds the physics to the studio in a single macro call.

```julia
using PDEStudio
using WGLMakie
using Bonito

# 1. Configure the Web Server for Remote Viewing
Bonito.configure_server!(
    listen_url = "0.0.0.0",
    listen_port = 9384
)
WGLMakie.activate!()

# 2. Build a one-click macro to load, archive, and plot your experiments
macro plot(name)
    return quote
        # Launch studio
        fig = Base.invokelatest(() -> launch_plotter())
        
        # Resolve path and archive the config 
        path = joinpath(@__DIR__, "Configs", $(esc(name)) * ".jl")
        cp(path, joinpath(@__DIR__, "Archive", $(esc(name)) * "_backup.jl"), force=true)
        
        # Load physics and trigger rendering
        config = include(path) 
        set_sim_config!(config)
        force_simulation()
        
        fig
    end
end

# Usage: 
# julia> @plot "Euler2D_Shock"
```

If the configuration file is listed in the config's `sources` (`SimulationConfig(...; sources = [path])`), every export copies it next to the exported CSV (`<name>_source_1.jl`, …). Loading that CSV later runs the copy (its last expression should be the `SimulationConfig`) and so recreates the experiment, solvers included. Afterwards the configuration keeps pointing at the original file while it exists (later runs pick up your edits) and falls back to the bundled copy otherwise.
