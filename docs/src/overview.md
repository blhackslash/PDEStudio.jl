# PDEStudio Control Panel Overview

![GUI](./gui.png)

The `PDEStudio` interface is a single window: the control panel on the left, the plots on the right. The top of the
control panel is a row of tabs; below the selected tab, the controls you need all the time are always visible.

## The Tabs

| Tab | Contents |
| :--- | :--- |
| **Plot** | The independent axes (X, Y, Z), the dependent field (U-Axis), its component and the animation target. Changes update the data without rebuilding the plot grid (**Update Plot**). Details: [Rendering](rendering.md). |
| **Layout** | Structural choices: base plot and style (1D lines, 3D surfaces, …), plot size, legend placement and multi-plot comparisons. *Changes here require a click on **Apply Layout** to rebuild the plot grid*, which is the expensive step (especially in a browser with WGLMakie). Details: [Rendering](rendering.md). |
| **Simulation** | The editor for the simulation configuration: shared and method parameters, the sweep, the active methods and their order, simulation presets; plus the method toggle that activates or deactivates methods. The preset buttons read **Save Sim Preset / Reset Simulation**. Details: [Advanced Editors](editors.md). |
| **UI** | The editor for the look: every UI style, the export settings and the visual presets (**Save Presets / Clear Presets**). |
| **Labels** | The editor for display names of components, variables and methods. |
| **Files** | Loading a CSV (button, or drop the file anywhere on the window) and **Export**. Details: [File Operations](file_ops.md). |

*Simulation*, *UI* and *Labels* are the three categories of the editor: the tab selects the category and opens on
an overview with one button per page (scope); a page lists the entries of the scope as rows.

## Always Visible

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

A window opens on the **Plot** tab. The tab can also be selected from code with `PDEStudio.show_tab!(:layout)`
(`:plot`, `:layout`, `:simulation`, `:ui`, `:labels`, `:files`).
