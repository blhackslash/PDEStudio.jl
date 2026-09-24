## Deep Dive: File Operations & Execution

The top section of the `PDEStudio` control panel is the command center for data serialization and rendering execution. Because PDE simulations and 3D graphics can be computationally heavy, this region operates on a strict asynchronous lock system to keep the UI responsive.

### 🚦 The Reactive State Machine (Triggers & Locks)

To prevent the Makie rendering engine from crashing or stuttering while the backend calculates heavy mathematical tensors, the studio uses a hierarchical locking system: **Simulation → Layout → Plot**.

The three green execution buttons at the top of the interface (`Run Simulation`, `Apply Layout`, `Update Plot`) serve as your traffic lights:

*   **Green (Synced):** The current visual plot perfectly matches the backend data and your selected UI settings.
*   **Yellow (Pending Action):** You have changed a parameter in the UI, and the system is waiting for you to confirm the change by clicking the yellow button.
*   **Coral / Red (Locked):** A higher-priority action is required first. For example, if you change a core physics parameter, the `Apply Layout` and `Update Plot` buttons will lock out until you click `Run Simulation` to generate the new data.

This design ensures that your laptop won't freeze just because you accidentally scrolled past a heavy UI setting!

### 💾 Exporting (Images & Animations)

The text box labeled *"Filename for Export or Path to Load..."* is the primary gateway for saving your work.

**The Direct Format Trick:**
By default, clicking **Export** will save the figure using the formats defined in the Hierarchical Editor (usually `.png`). However, you can completely bypass these settings by typing the exact extension you want directly into the text box.
*   **Vector Graphics:** Type `my_figure.svg` or `my_figure.pdf` and click Export. The studio will instantly generate a pristine, publication-ready vector file.
*   **Animations:** Select a variable in the **Anim Target** dropdown (e.g., `Time (T)`). Then, type `my_video.mp4` or `my_animation.gif` in the text box and click Export. The studio will automatically lock the camera, hide the UI handles, and render a smooth video sweeping across the target's entire slider range.

> **Note:** All exports are "pristine." The studio silently duplicates your plot in the background before saving, ensuring that UI artifacts (like slider dots or crosshairs) never appear in your final images.

### 🎨 Presets vs. Full Exports

It is important to understand the difference between the **Export** button and the **Save Presets** button.

*   **Export:** Captures the *entire* state of the studio. It saves the image/video, but also generates a comprehensive `.csv` file alongside it containing your complete `PDEStudioCore` physics parameters, exact git-commit hashes, and Julia environment versions for total academic reproducibility.
*   **Save Presets:** Exclusively saves your *visual aesthetics* (colormaps, line widths, legend positions, camera angles) to a lightweight template file. It ignores the mathematical parameters, allowing you to load this visual theme later and apply it to a completely different physical simulation.
