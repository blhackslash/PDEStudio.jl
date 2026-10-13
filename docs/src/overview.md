# PDEStudio Control Panel Overview

![GUI](./gui.png)

The `PDEStudio` interface is driven by a single, reactive control panel. Rather than hiding settings in nested pop-up windows, it is one vertically scrolling dashboard, divided into four regions.

## 1. File Operations & Execution

The top region handles serialization and execution (details: [File Operations](file_ops.md)).
*   **Load, Export & Presets:** The filename box is shared by all file operations. Type a file name and click **Export** to save the figure or an animation; type a path *or just a file name* of a saved CSV and click the load button (or drop the CSV onto the window) to recreate a saved state. **Save Presets / Clear Presets** save and reset the look; while the editor shows the *Simulation* category, the same buttons read **Save Sim Preset / Reset Simulation** and act on the physics instead (see [Presets](presets.md)).
*   **Reactive Triggers:** The execution buttons (`Run Simulation`, `Apply Layout`, `Update Plot`) are tied to a background state machine. When a change requires a backend recalculation or a structural layout change, the corresponding button turns yellow to show that the plot is out of sync.

## 2. Advanced Editors

Granular control over the simulation and the look (details: [Advanced Editors](editors.md)).
*   **Parameter & UI Editor:** A three-tier dropdown system (Category → Scope → Parameter) with direct access to the shared and method parameters, the sweep, the active methods, every UI style, the presets and the display names, without writing code.
*   **Method Controls:** Activate or deactivate numerical methods or analytical references of your `SimulationConfig` on the fly.

## 3. Rendering Configuration

The red-titled sections dictate how the data is projected onto the screen (details: [Rendering](rendering.md)).
*   **Layout Options:** Structural changes such as switching from 1D lines to 3D surfaces, legend placement or multi-plot comparisons. *Changes here require a click on "Apply Layout" to rebuild the plot grid.*
*   **Plot Options:** The independent axes (X, Y, Z), the dependent field (U-Axis) and its component. Changes here update the data without rebuilding the plot window.

## 4. Exploration & Playback

Interacting with the data (details: [Exploration](sliders.md)).
*   **Sliders:** One slider per swept parameter and per physical dimension, scaled to the values of the active datasets. Text-valued sweeps (e.g. scheme names) get index sliders that display the swept value.
*   **Camera & Animation:** A one-click animation player that sweeps the chosen `Anim Target`. **Lock Camera** freezes the view (2D limits, or 3D azimuth, elevation and bounds) for perfectly stable video exports.
