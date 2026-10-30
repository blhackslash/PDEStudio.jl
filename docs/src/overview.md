# PDEStudio Control Panel Overview

![GUI](./gui.png)

The `PDEStudio` interface is a single window: the control panel on the left, the plots on the right. The top of the
control panel is a row of tabs; below the selected tab, the controls you need all the time are always visible.

## The Tabs

| Tab | Contents |
| :--- | :--- |
| **Plot** | Two sections. *Layout options*: base plot and style (1D lines, 3D surfaces, …), plot width and height and the number of grid columns (any number), legend placement and multi-plot comparisons; *changes here require a click on **Apply Layout** to rebuild the plot grid*, which is the expensive step (especially in a browser with WGLMakie). *Plot options*: the independent axes (X, Y, Z), the dependent field (U-Axis), its component and the animation target; changes update the data without rebuilding the plot grid (**Update Plot**). Details: [Rendering](rendering.md). |
| **Methods** | Every method of the configuration with an **active / off** button (filter: **Show: active / disabled / all**) and **Edit ›** for its parameters (also of inactive methods); **Order ▲▼** shows the active methods in drawing order (legends, colours, the *Methods* comparison) with ▲ ▼ to move them. Details: [Advanced Editors](editors.md). |
| **Simulation** | The editor for the simulation configuration: shared parameters, the sweep, `defaults`/`permutation`/functions (*Config*) and simulation presets. The preset buttons read **Save Sim Preset / Reset Simulation**. Details: [Advanced Editors](editors.md). |
| **UI** | The editor for the look: every UI style, the export settings and the visual presets (**Save Presets / Clear Presets**). |
| **Labels** | The editor for display names of components, variables and methods. |
| **Files** | Loading a CSV (button, or drop the file anywhere on the window) and **Export**. Details: [File Operations](file_ops.md). |

*Simulation*, *UI* and *Labels* are the three categories of the editor: the tab selects the category and opens on
an overview with one button per page (scope); a page lists the entries of the scope as rows. The *Methods* tab uses
the same editor for the method parameters.

## Always Visible

*   **Status line** (below the tab content): the result of the last action, coloured by outcome: green for done,
    orange for warnings (e.g. a value that was refused, and why), red for errors. Edits, method changes, presets,
    simulation runs, CSV loads and exports report here; everything is also written to the Julia log.
*   **Filename box:** shared by all file operations. Type a file name and click **Export** to save the figure or an
    animation, or type a name and click **Save Presets** / **Save Sim Preset**; type a path *or just a file name*
    of a saved CSV and click the load button (or drop the CSV onto the window) to recreate a saved state (see
    [Presets](presets.md)).
*   **Sliders** (at the bottom): one slider per swept parameter and per physical dimension, scaled to the values of
    the active datasets. Only sliders with a choice to make are shown: unused parameter sliders, dimensions on a plot
    axis and dimensions the data doesn't have are hidden. Text-valued sweeps (e.g. scheme names) get index sliders that display the swept value. Details:
    [Exploration](sliders.md).
*   **Camera & Animation:** a one-click animation player that sweeps the chosen `Anim Target`. **Lock Camera**
    freezes the view (2D limits, or 3D azimuth, elevation and bounds) for perfectly stable video exports.
*   **Reactive Triggers:** the execution buttons (`Run Simulation`, `Apply Layout`, `Update Plot`) are tied to a
    background state machine. When a change requires a backend recalculation, a structural layout change or a
    redraw, the corresponding button turns yellow to show that the plot is out of sync.

A window opens on the **Plot** tab. The tab can also be selected from code with `PDEStudio.show_tab!(:methods)`
(`:plot`, `:methods`, `:simulation`, `:ui`, `:labels`, `:files`).
