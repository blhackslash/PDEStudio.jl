## Deep Dive: File Operations & Execution

The **Files** tab (name / path and description boxes, loading, export, presets) and the execution buttons below the tabs handle serialization and execution. Because PDE simulations and 3D graphics can be computationally heavy, this region works with a lock system that keeps the UI responsive.

### 🚦 The Reactive State Machine (Triggers & Locks)

To keep the Makie rendering engine from stuttering while the backend computes, the studio uses hierarchical locks: **Simulation → Layout → Plot**.

The three execution buttons (`Run Simulation`, `Apply Layout`, `Update Plot`) are your traffic lights:

*   **Green (Synced):** The plot matches the backend data and your UI settings.
*   **Yellow (Pending Action):** You changed something, and the studio waits for you to confirm it with a click on the yellow button.
*   **Coral / Red (Locked):** A higher-priority action is required first. For example, after changing a physics parameter, `Apply Layout` and `Update Plot` stay locked until you click `Run Simulation`.

Simulations that already exist on disk (same parameters, same hash) are loaded instead of recomputed.

### 📂 Loading a Saved State

In the **Files** tab, choose the file with **Browse…** (the system's file dialog), type its path into the **Name / path** box and click **Load**, or drop it anywhere onto the window; the status line reports the result. A bare file name is enough: the studio searches the working directory, `<save path>/figures`, `<save path>/animations`, the preset folders and `./Experiments` (each including one level of subfolders; a name without extension means a CSV). The same works from code: `set_sim_config!("my_run.csv")`, `set_sim_config!("configs/euler2d.jl")`.

Two kinds of files can be loaded:

*   **CSV files** (exports and presets): values only, parsed safely. This is the preferred way: a CSV without bundled source files never runs code.
*   **Julia files** (`.jl`) whose last expression is the `SimulationConfig`, or a function without arguments that returns it. The file runs in the target module (`set_target_module!`) and is added to the configuration's `sources`, so exports bundle it.

> **⚠️ Code execution:** loading a Julia file, or a CSV that bundles source files (see below), **runs that code with your rights**. Only load files you trust. In the studio, such a file needs a second click on **Load**: the first one only shows the warning in the status line.

The load button turns **green** when the file was read; press *Run Simulation* to compute and show it.

**File dialog:** *Browse…* uses the tools the operating system brings: AppleScript on macOS, PowerShell on Windows, `zenity` or `kdialog` on Linux (install one of them if the status line says that no dialog was found). In a browser (WGLMakie) there is no dialog, because it would open on the machine running Julia; type the path or drop the file instead. `PDEStudio.FILE_DIALOG[]` can be replaced by any function returning a path.

If the file needs more parameter sliders or other physical dimensions than the open window has, the buttons turn **orange**: the configuration is staged, and the next click on *Run Simulation* rebuilds the whole window with the new limits, applies the file and runs it. (Save your current look as a preset first if you want to keep it.) Without an open window, the limits are applied directly.

### 🧩 Config Files and Bundled Sources

A configuration that comes from a Julia file (listed in its `sources`, which loading a `.jl` file does by itself) is
**bundled with every export**: the files of `sources` are copied into `<name>_sources/` next to the exported CSV,
under their own file names. Loading that CSV runs the copies again to restore the solvers:

*   each copy runs **as if it were the original file** while the original's folder exists, so `@__DIR__` and relative
    `include`s find the files next to the original (later edits of those files are used, the configuration itself
    is the snapshot of the export);
*   without the original folder the copies run from `<name>_sources/`, so a file that includes another one finds it
    there if that one is listed in `sources` too;
*   if a copy fails, the load does not stop: the **parameters come from the CSV**, the status line names the file and
    the error, and the solver functions have to be defined before *Run Simulation* (e.g. by loading their package).

Configuration files that reload reliably, from the studio and from any bundled copy:

1.  **End with the configuration:** the last expression is the `SimulationConfig`, or a function without arguments
    that returns it (`() -> SimulationConfig(...)`); nothing interactive (no `launch_plotter()`, no `display`).
2.  **No absolute paths:** include helper files relative to the file (`include("solvers.jl")` or
    `include(joinpath(@__DIR__, "solvers.jl"))`) and list them in `sources` too
    (`sources = [joinpath(@__DIR__, "solvers.jl")]`), so they are bundled with it.
3.  **Solvers in a package** are the most robust: `using MySolvers` at the top, and the bundled file only holds the
    configuration. Packages must be installed in the environment that loads the file.
4.  **Data files** (meshes, initial conditions) are read relative to `@__DIR__` and are not bundled; keep them with the
    configuration or in a package.

```julia
# configs/advection.jl
using PDEStudio
include("solvers.jl")                    # defines advection_1d (relative to this file)

SimulationConfig(create_param_dict(:N => 100, :cfl => 0.5, :sim_func_name => :advection_1d),
                 create_method_dict(:upwind => create_param_dict(:scheme => "upwind")), [:upwind];
                 varied = create_varied_dict(:cfl => [0.3, 0.5]),
                 sources = [joinpath(@__DIR__, "solvers.jl")])   # bundled with exports, too
```

### 💾 Exporting (Images & Animations)

The **Name / path** box is also the gateway for saving your work. Exports land in `<save path>/figures` (static frames; with the export option `create_savefolder`, in a subfolder per name) and `<save path>/animations`. A path in the name (`study/run_1`, or an absolute path) is honoured.

**The Direct Format Trick:**
By default, **Export** saves the figure in every format listed in the export setting `save_formats` (*Files → Settings ›*, usually `png`). Typing an extension into the filename bypasses that list:
*   **Static formats** (`png`, `jpg`, `jpeg`, `pdf`, `svg`, `eps`): `my_figure.svg` exports exactly that one file.
*   **Animations** (`mp4`, `webm`, `mkv`, `gif`): select a variable in the **Anim Target** dropdown (e.g. `t`), type `my_video.mp4` and click Export. The studio locks the camera and records the target's whole slider range (duration and frame rate: `animation_time` and `animation_FPS` in *Files → Settings ›*).
*   **Anything else** is part of the name: `run_dt0.5` exports `run_dt0.5.png` (and the other listed formats).

> **Note:** All exports are pristine. The studio renders a fresh copy of the plot for the export, so UI artifacts (slider handles, unapplied states) never appear in your files.

### 🎨 Presets vs. Full Exports

| Button | Saves | Typical use |
| :--- | :--- | :--- |
| **Export** | The figure/animation **and** a CSV with the entire state: physics, sweep, look, git commits, Julia versions, and copies of the configuration's source files. | Reproducing a figure months later. |
| **Look → Save** | The look only: layout, axes, slider positions, camera, labels, exploration options, UI styles. | Applying a house style to any simulation. |
| **Simulation → Save** | The physics only: shared and method parameters, active methods, sweep, reference/post-processing functions. | Switching between setups (coarse/fine grid, test cases) without touching the look. |

Presets are listed under **Presets ›** in the Files tab, with **Apply** and **Edit ›** (the rows of the preset file). **Look → Reset** restores the default look, **Simulation → Reset** the configuration you bound with `set_sim_config!` (or loaded from a CSV). See [Presets](presets.md) for the file format and the API.
