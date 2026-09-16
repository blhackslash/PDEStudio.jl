## Deep Dive: Rendering Configuration

The red-titled sections—**Layout Options** and **Plot Options**—are the visual engine room of PDEStudio. These panels define exactly how your high-dimensional simulation tensors are sliced, projected, and compared on the screen. 

### 🏗️ Layout Options (Structural Geometry)

The Layout Options section dictates the physical structure of the Makie grid. Because changes here require destroying and rebuilding plot axes and legends, modifying these settings will turn the **Apply Layout** button yellow, signaling that a structural rebuild is required.

#### 1. Base Plot & Plot Style
*   **Base Plot:** Defines the core geometry (e.g., `Lines`, `Heatmap`, `Scatter`, `Volume`). This dropdown automatically adapts based on whether your backend is in Eulerian (mesh) or Lagrangian (particle) mode.
*   **Plot Style:** Offers specific modifiers for your base plot (e.g., switching a heatmap from `Flat` to `Surface`, or changing 1D lines to `Scatter Lines`).

#### 2. The Comparison Engine
Instead of constantly tweaking sliders to compare states, you can unroll your dimensions across a multi-column grid.
*   **Compare Target:** You can compare *almost anything* side-by-side. You can unroll different **Methods** (e.g., comparing an Upwind solver vs. a WENO solver), split vector **Components** into separate plots, or compare across any mathematical variable (like `Time (T)`) or custom **Varied Parameter** (e.g., sweeping across different grid resolutions `N`).
*   **Compare Link (Coupling):** When comparing multiple plots, this dropdown dictates how they share visual limits:
    *   *Fully Coupled:* All subplots share the exact same X/Y/Z axis limits and a single global Colorbar. Perfect for 1-to-1 visual comparisons.
    *   *Axes Only:* Limits are locked together, but each plot gets its own local color range.
    *   *Colorbar Only:* Axes can zoom independently, but the color mapping is universally locked.
    *   *Decoupled:* Every plot scales completely independently.

### 📐 Plot Options (Data Projection)

While Layout dictates *how* things are drawn, Plot Options dictate *what* is drawn. Changes made here are instantly resolved via the **Update Plot** button without needing to rebuild the layout.

#### 1. The X $\rightarrow$ Y $\rightarrow$ Z Hierarchy
The independent axes cascade strictly from left to right. This prevents mathematically impossible plots (like plotting X versus X).
*   When you select an **X-Axis**, that variable is removed from the available options for Y and Z.
*   Selecting a **Y-Axis** further restricts the available options for Z.
*   *Auto-Correction:* If you change your Plot Style from a 3D volume down to a 1D line plot, the studio will automatically detect the incompatibility, disable the Y and Z axis selectors, and reset the plot to prevent the engine from crashing.

#### 2. The Dependent Field (U-Axis)
The **U-Axis** selector is highly intelligent and reacts to your choices in the X/Y/Z dropdowns. It analyzes the backend statistical registry and automatically hides metrics that do not mathematically fit your chosen axes.
*   **Dimensional Filtering:** If you set your axes to `Position (X)` and `Position (Y)`, the U-Axis will only allow you to plot 2D spatial fields or profiles. It will automatically hide purely temporal statistics (like a time-series of Total Energy) because they lack the required spatial dimensions.
*   **The `Solution` Guarantee:** The raw, un-integrated physical state vector of your simulation is labeled `Solution`. Because it natively spans the entire mathematical domain (all space and time), it will *always* be available in the U-Axis dropdown, regardless of your axis configuration.

#### 3. Vector Components
If the variable selected in the U-Axis is a multi-dimensional state vector (e.g., a fluid momentum vector $[\ \rho u, \ \rho v]$), the **Component** dropdown will automatically activate, allowing you to quickly scrub through the individual scalar layers of that vector.