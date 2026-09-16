# Base Plot: Lines

The `Lines` base plot is the fundamental rendering class for continuous, connected data. It is highly optimized for Eulerian meshes and is the default starting point for 1D visualizations. Instead of plotting discrete dots, it traces the continuous mathematical shape of your data over the physical domain.

## Shared Options
Regardless of the dimensionality of the line plot, the following styling option is universally supported:
*   **Line Width (`:line_width`):** Controls the thickness of the rendered strokes globally.

---

## 1D Lines (`:lines_1d`)
The standard, classical two-axis line plot. It maps a single independent variable (X) to a dependent mathematical field (U). Because multiple numerical methods can easily be overlaid in 1D without visual obstruction, this style supports categorical coloring and automatic legend generation.

**Supported Style Dependencies:**
*   **Colors (`:colors`):** Assigns distinct categorical colors to each active numerical method.
*   **Line Styles (`:line_styles`):** Differentiates methods using stroke patterns (e.g., `:solid`, `:dash`, `:dot`).
*   **Dashed Lines (`:dashed_lines`):** A boolean toggle to enable or disable the application of `line_styles`.
*   **Reference Lines (`:reference`):** Allows the injection of analytical slopes (e.g., convergence rates) directly onto the axis bounds.

---

## 2D Lines (`:lines_2d`)
A highly specialized plot style that renders a 2D mesh as a series of dense, parallel 1D line slices. Instead of using categorical colors for different methods, it applies a continuous scalar colormap based on the value of the dependent field. It automatically supports Colorbar integration.

**Supported Style Dependencies:**
*   **Color Map (`:color_map`):** The continuous gradient used to color the line segments (e.g., `:viridis`, `:inferno`).
*   **Color Range (`:color_range`):** The mathematical limits `[min, max]` mapping the field values to the colormap.
*   **Line Direction (`:line_direction`):** Determines the slicing axis, allowing you to sweep the parallel lines either horizontally or vertically across the grid.
*   **Method Index (`:method_index`):** Selects which specific numerical method acts as the base layer, since multiple dense 2D line grids cannot easily be overlaid.
*   **Bottom Margin (`:bottom_margin`):** Adjusts padding at the base of the plot.

---

## 3D Lines (`:lines_3d`)
The three-dimensional extension of the parallel slicing technique. It projects the continuous grid lines into an `Axis3` bounding box, colored dynamically by the dependent scalar field. Like its 2D counterpart, it supports global Colorbar integration.

**Supported Style Dependencies:**
*   **Color Map (`:color_map`):** The continuous gradient applied to the 3D strokes.
*   **Color Range (`:color_range`):** The strict bounds `[min, max]` for the color scaling.
*   **Line Direction (`:line_direction`):** Controls the primary orientation of the 3D slicing projection.
*   **Method Index (`:method_index`):** Isolates a single method to project into the 3D volume.
*   **Bottom Margin (`:bottom_margin`):** Customizes structural padding.