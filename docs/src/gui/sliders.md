## Deep Dive: Exploration & Playback

The bottom section of the control panel is dedicated to slicing through your high-dimensional datasets. Once your layout is applied and your plot is drawn, these controls allow you to actively explore the tensor without triggering expensive backend recalculations.

### 🎚️ Dimensional Sliders

The UI generates a stack of sliders that act as your coordinates through the mathematical space. They are mapped to both physical dimensions (e.g., `Position (X)`, `Time (T)`) and any custom parameter sweeps defined in your `VariedDict`.

*   **Configuring Slider Limits:** By default, the studio pre-allocates a set number of parameter sliders to avoid constantly rebuilding the UI window. You can change this limit programmatically before launching the plotter by calling `set_max_params!(n)` in your Julia script.
*   **The "Always Ready" Architecture:** To ensure a fluid experience, the UI provisions these sliders even if they aren't currently needed. For example, if you run a purely 1D simulation, the `Position (Y)` and `Position (Z)` sliders will simply appear disabled (locked to `0.0`). If you immediately drag-and-drop a 2D CSV preset into the UI, that Y slider will instantly wake up and adapt to the new spatial bounds. You never have to restart the studio just because your data gained a dimension or an extra sweep parameter.

### 🎥 Animation & The Camera Lock

When navigating through time or sweeping across parameters, the studio provides automated playback via the **Play Anim** button (which smoothly scrubs through whatever variable is selected in the **Anim Target** dropdown). However, animations require strict control over the viewport.

#### The "Lock Camera" Mechanic
By default, Makie operates with an **autoscaling viewport**. Every time the data updates (e.g., when you drag a slider or a new animation frame renders), the axes will automatically tightly bound the new data. While great for exploration, this causes the bounding box to aggressively jitter and jump during animations. 

To fix this, you must use the **Lock Camera** button.

*   **The Snapshot Rule:** Clicking "Lock Camera" takes an exact, mathematical snapshot of your viewport's *current* state (the 2D X/Y limits, or the 3D azimuth, elevation, and bounds). 
*   **Overriding Zoom:** It is crucial to understand that the lock is absolute. If you lock the camera and *then* use your mouse to zoom in closer, the very next time a slider moves or an animation ticks, the plot will instantly snap back out to the originally locked snapshot. 
*   **Updating the Cache:** If you want to change your static view, you must toggle the "Lock Camera" button off, adjust your pan/zoom with your mouse to the new desired angle, and then toggle the lock back on to overwrite the cache snapshot.