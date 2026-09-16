# Base Plot: Contour

The `Contour` base plot family is designed for visualizing topological gradients and scalar fields across 2D grids and 3D volumes. By extracting mathematical isolines or isosurfaces, these plots allow you to clearly identify regions of equal value within dense Eulerian datasets.

## Shared Options
Because all contour styles rely on mathematical discretization, they share the following core property:
*   **Levels (`:levels`):** Dictates the number of discrete isolines or colored bins generated between the field's minimum and maximum values.

---

## Contour Lines (`:contour_colors`)
A classical 2D topological map using discrete un-filled lines. Because the lines are un-filled, this style is highly transparent and allows you to overlay multiple numerical methods on the same axis. It automatically integrates with the Legend system.

**Supported Style Dependencies:**
*   **Colors (`:colors`):** Assigns distinct categorical colors to differentiate each active numerical method.
*   **Line Width (`:line_width`):** Controls the stroke thickness of the generated isolines.
*   **Labels (`:labels`):** A boolean toggle that prints the exact numerical value of the contour directly onto the line.

---

## Contour Colormap (`:contour_cmap`)
A 2D contour line plot mapped to a continuous scalar colormap rather than categorical method colors. This style is used to deeply analyze the gradient of a single method and automatically binds to a Colorbar.

**Supported Style Dependencies:**
*   **Color Map (`:color_map`):** The continuous gradient palette applied across the discrete levels.
*   **Color Range (`:color_range`):** The `[min, max]` bounds mapping the scalar field to the colormap.
*   **Line Width (`:line_width`):** The thickness of the isolines.
*   **Labels (`:labels`):** Toggles numeric text labels on the contour lines.
*   **Method Index (`:method_index`):** Isolates a specific method as the base layer, preventing unreadable overlapping colormaps.
*   **Bottom Margin (`:bottom_margin`):** Adjusts the foundational layout padding.

---

## Contour Filled (`:contour_f`)
A 2D topological map where the regions between isolines are filled with solid colors. This creates a highly readable, banded alternative to a smooth heatmap. Because it is opaque, it requires isolating a single method and supports Colorbars.

**Supported Style Dependencies:**
*   **Color Map (`:color_map`):** The gradient palette used to fill the contour bands.
*   **Color Range (`:color_range`):** The bounds used to scale the color assignments.
*   **Method Index (`:method_index`):** Selects which numerical method is rendered.
*   **Bottom Margin (`:bottom_margin`):** Customizes structural layout padding.

---

## Contour Surface (`:contour_surface`)
A 3D projection of 2D categorical contour lines. It elevates the isolines along the Z-axis based on their scalar value, creating a wireframe-like mountain topology. It supports overlaying multiple methods and integrates with the Legend system.

**Supported Style Dependencies:**
*   **Colors (`:colors`):** Applies categorical coloring to distinguish overlaid methods.
*   **Line Width (`:line_width`):** Adjusts the 3D stroke thickness.
*   **Labels (`:labels`):** Toggles numeric value labels along the elevated lines.

---

## 3D Contour (`:contour_3d`)
A true 3D volumetric contour plot. Instead of drawing lines, it extracts entire 3D isosurfaces (shells) from a dense Eulerian volume. It automatically registers with the Colorbar layout system.

**Supported Style Dependencies:**
*   **Colors (`:colors`):** Dictates the coloring schema for the extracted isosurfaces.
*   **Line Width (`:line_width`):** Adjusts edge and geometric thickness properties.
*   **Method Index (`:method_index`):** Isolates a single numerical method to prevent the 3D viewport from becoming completely occluded.