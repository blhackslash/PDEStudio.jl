# Base Plot: Heatmap

The `Heatmap` base plot is the standard for visualizing dense 2D Eulerian data. Rather than extracting discrete isolines, it colors every single cell in the mathematical grid based on its scalar value, providing a complete and continuous view of the domain. Because heatmaps are completely opaque, they require isolating a single numerical method via the `:method_index`.

## Heatmap Flat (`:heatmap_flat`)
A traditional 2D orthographic projection of the grid. It is heavily optimized for fast rendering of massive matrices and seamlessly integrates with the Colorbar system.

**Supported Style Dependencies:**
*   **Color Map (`:color_map`):** The continuous color gradient applied to the grid cells.
*   **Color Range (`:color_range`):** The mathematical bounds `[min, max]` locking the colormap scaling.
*   **Method Index (`:method_index`):** Selects which specific active numerical method is rendered onto the grid.
*   **Bottom Margin (`:bottom_margin`):** Customizes the foundational layout padding of the 2D axis.

---

## Heatmap Surface (`:heatmap_surface`)
A 2.5D visualization that renders the dense grid inside a true 3D bounding box. It takes the 2D heatmap and displaces the Z-coordinate of every cell according to its scalar magnitude, creating a continuous, colored mountain-range topology.

**Supported Style Dependencies:**
*   **Color Map (`:color_map`):** The continuous gradient applied to the elevated surface.
*   **Color Range (`:color_range`):** The explicit color scaling boundaries.
*   **Method Index (`:method_index`):** Isolates a single method for 3D projection to prevent overlapping surfaces.