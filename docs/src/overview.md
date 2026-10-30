# PDEStudio Control Panel Overview

![GUI](./gui.png)

The `PDEStudio` interface is a single window: the control panel on the left, the plots on the right. The top of the
control panel is a row of tabs; below the selected tab, the controls you need all the time are always visible.

## The Tabs

| Tab | Contents |
| :--- | :--- |
| **Plot** | Two sections. *Layout options*: the **plot style** (the button opens a page of every supported style, grouped by Lines, Scatter, Contour, Heatmap and Volume; click one to choose it), plot width and height and the number of grid columns (any number), legend placement and multi-plot comparisons; *changes here require a click on **Apply Layout** to rebuild the plot grid*, which is the expensive step (especially in a browser with WGLMakie). *Plot options*: the independent axes (X, Y, Z), the dependent field (U-Axis), its component and the animation target; changes update the data without rebuilding the plot grid (**Update Plot**). Details: [Rendering](rendering.md). |
| **Methods** | Every method of the configuration with an **active / off** button (filter: **Show: active / disabled / all**) and **Edit ›** for its parameters (also of inactive methods); **Order ▲▼** shows the active methods in drawing order (legends, colours, the *Methods* comparison) with ▲ ▼ to move them. Details: [Advanced Editors](editors.md). |
| **Simulation** | The editor for the simulation configuration: shared parameters, the sweep, `defaults`/`permutation`/functions (*Config*) and the simulation presets (applied here with **Apply**). Details: [Advanced Editors](editors.md). |
| **UI** | The editor for the look, with a fixed overview: *General* (presets, fonts, labels, HUD, outliers), *Axes* (every axis variant: 1D, 2D/3D, Z) and *Plot styles* (one page per plot type). The pages of the active plot are highlighted. |
| **Labels** | The editor for display names of components, variables and methods. |
| **Files** | The **Name / path** box (exports, presets, CSV files) and the **Description** of a preset you save; **Load CSV** (or drop the file anywhere on the window), **Export** and **Export settings ›** (formats, resolution, animation length, …); **Save / Reset** of simulation presets (the physics) and look presets (the visual settings). Details: [File Operations](file_ops.md), [Presets](presets.md). |

*Simulation*, *UI* and *Labels* are the three categories of the editor: the tab selects the category and opens on
an overview with one button per page (scope); a page lists the entries of the scope as rows. The *Methods* tab uses
the same editor for the method parameters.

## Always Visible

*   **Status line** (below the tab content): the result of the last action, coloured by outcome: green for done,
    orange for warnings (e.g. a value that was refused, and why), red for errors. Edits, method changes, presets,
    simulation runs, CSV loads and exports report here; everything is also written to the Julia log.
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
