# Base Plot: Scatter

The `Scatter` base plot is the most versatile rendering class in the studio, acting as the primary bridge between Eulerian meshes and Lagrangian particle clouds. Instead of drawing continuous shapes, it plots discrete data points at explicit mathematical coordinates. 

## Shared Marker Options
Because every scatter plot relies on discrete geometry, they uniformly support the following structural modifiers:
*   **Markers (`:markers`):** Defines the geometric shape of the points (e.g., circles, crosses, triangles).
*   **Marker Size (`:marker_size`):** Controls the pixel scaling of the plotted geometries.

## 1D Scatter Styles
These styles are optimized for single-axis data projections, often used to compare discrete nodal outputs against analytical curves.

| Style | Description | Additional Dependencies |
| :--- | :--- | :--- |
| **1D Scatter** (`:scatter_1d`) | Discrete points bound to a continuous scalar colormap, displaying a single method. | `:color_map`, `:color_range`, `:bottom_margin`, `:method_index`. |
| **Scatter Colors** (`:scatter_colors`) | Categorically colored points that support overlaying multiple numerical methods simultaneously. | `:colors`. |
| **Scatter Lines** (`:scatter_lines`) | Discrete markers connected by continuous strokes, merging point tracking with line aesthetics. | `:colors`, `:line_width`, `:line_styles`, `:dashed_lines`, `:reference`. |

## Multi-Dimensional Scatter Styles
These styles handle complex 2D domains and 3D volumetric point clouds, relying exclusively on colormaps since multi-method spatial overlaps are visually unreadable.

| Style | Description | Additional Dependencies |
| :--- | :--- | :--- |
| **2D Scatter** (`:scatter_2d`) | 2D particle grids or moving tracking points, tied directly to the Colorbar system. | `:color_map`, `:color_range`, `:bottom_margin`, `:method_index`. |
| **2D Scatter Surface** (`:scatter_surface`) | Projects 2D points into an `Axis3` bounding box, elevating them along the Z-axis based on their scalar magnitude. | `:color_map`, `:color_range`, `:method_index`. |
| **3D Scatter** (`:scatter_3d`) | True volumetric point clouds floating in 3D space, perfect for Lagrangian simulations. | `:color_map`, `:color_range`, `:method_index`. |