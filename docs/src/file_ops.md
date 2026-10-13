## Deep Dive: File Operations & Execution

The top section of the control panel is the command center for serialization and execution. Because PDE simulations and 3D graphics can be computationally heavy, this region works with a lock system that keeps the UI responsive.

### 🚦 The Reactive State Machine (Triggers & Locks)

To keep the Makie rendering engine from stuttering while the backend computes, the studio uses hierarchical locks: **Simulation → Layout → Plot**.

The three execution buttons (`Run Simulation`, `Apply Layout`, `Update Plot`) are your traffic lights:

*   **Green (Synced):** The plot matches the backend data and your UI settings.
*   **Yellow (Pending Action):** You changed something, and the studio waits for you to confirm it with a click on the yellow button.
*   **Coral / Red (Locked):** A higher-priority action is required first. For example, after changing a physics parameter, `Apply Layout` and `Update Plot` stay locked until you click `Run Simulation`.

Simulations that already exist on disk (same parameters, same hash) are loaded instead of recomputed.

### 📂 Loading a Saved State

Type the path of a CSV into the filename box and click the load button at the top, or simply drop the file onto the window. A bare file name (with or without `.csv`) is enough: the studio searches the working directory, `<save path>/figures`, `<save path>/animations`, the preset folders and `./Experiments` (each including one level of subfolders). The same works from code: `set_sim_config!("my_run.csv")`.

The load button turns **green** when the file was read; press *Run Simulation* to compute and show it.

If the file needs more parameter sliders or other physical dimensions than the open window has, the buttons turn **orange**: the configuration is staged, and the next click on *Run Simulation* rebuilds the whole window with the new limits, applies the file and runs it. (Save your current look as a preset first if you want to keep it.) Without an open window, the limits are applied directly.

### 💾 Exporting (Images & Animations)

The filename box is also the gateway for saving your work. Exports land in `<save path>/figures` (static frames; with the export option `create_savefolder`, in a subfolder per name) and `<save path>/animations`. A path in the name (`study/run_1`, or an absolute path) is honoured.

**The Direct Format Trick:**
By default, **Export** saves the figure in every format listed in the export setting `save_formats` (*UI → Export* in the editor, usually `png`). Typing an extension into the filename bypasses that list:
*   **Static formats** (`png`, `jpg`, `jpeg`, `pdf`, `svg`, `eps`): `my_figure.svg` exports exactly that one file.
*   **Animations** (`mp4`, `webm`, `mkv`, `gif`): select a variable in the **Anim Target** dropdown (e.g. `t`), type `my_video.mp4` and click Export. The studio locks the camera and records the target's whole slider range (duration and frame rate: `animation_time` and `animation_FPS` in *UI → Export*).
*   **Anything else** is part of the name: `run_dt0.5` exports `run_dt0.5.png` (and the other listed formats).

> **Note:** All exports are pristine. The studio renders a fresh copy of the plot for the export, so UI artifacts (slider handles, unapplied states) never appear in your files.

### 🎨 Presets vs. Full Exports

| Button | Saves | Typical use |
| :--- | :--- | :--- |
| **Export** | The figure/animation **and** a CSV with the entire state: physics, sweep, look, git commits, Julia versions, and copies of the configuration's source files. | Reproducing a figure months later. |
| **Save Presets** | The look only: layout, axes, slider positions, camera, labels, exploration options, UI styles. | Applying a house style to any simulation. |
| **Save Sim Preset** (editor on *Simulation*) | The physics only: shared and method parameters, active methods, sweep, reference/post-processing functions. | Switching between setups (coarse/fine grid, test cases) without touching the look. |

Presets are listed in the editor under *UI → Presets* and *Simulation → Presets*; select one and click **Apply**. **Clear Presets** restores the default look, **Reset Simulation** the configuration you bound with `set_sim_config!` (or loaded from a CSV). See [Presets](presets.md) for the file format and the API.
