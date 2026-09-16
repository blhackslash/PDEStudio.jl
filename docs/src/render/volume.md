# Base Plot: Volume

The `Volume` base plot is dedicated purely to dense 3D Eulerian grids. It utilizes ray-marching algorithms to render scalar fields as semi-transparent, cloudy volumes in true 3D space, allowing you to see through outer layers into the core of the data tensor.

## 3D Cloud Volume (`:volume_3d`)
The only style in the Volume family, this is the most computationally demanding primitive in the studio. It automatically links to the global Colorbar system to provide a reference for the volumetric density.

**Supported Style Dependencies:**
*   **Color Map (`:color_map`):** The colormap defining the RGB values of the volumetric cloud. (Note: Transparency/Alpha is mapped automatically by Makie's internal volume shader based on field intensity).
*   **Color Range (`:color_range`):** The explicit limits defining the bounds of the colormap.
*   **Method Index (`:method_index`):** Forces the selection of a single active method, as ray-tracing multiple overlapping dense 3D grids is visually and computationally unfeasible.