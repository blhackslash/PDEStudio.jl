# docs/make.jl
using Documenter
using PDEStudio

makedocs(
    sitename = "PDEStudio.jl",
    modules = [PDEStudio],
    checkdocs = :exports, 
    format = Documenter.HTML(
        prettyurls = get(ENV, "CI", "false") == "true",
        canonical = "https://blhackslash.github.io/PDEStudio.jl/",
        assets = String[],
    ),
    pages = [
        "Home" => "index.md",
        "GUI Guide" => [
            "Overview" => "gui/overview.md",
            "File Operations" => "gui/file_ops.md",
            "Advanced Editors" => "gui/editors.md",
            "Rendering Configuration" => "gui/rendering.md",
            "Exploration & Sliders" => "gui/sliders.md",
        ],
        "Render Options" => [
            "Lines" => "render/lines.md",
            "Contour" => "render/contour.md",
            "Scatter" => "render/scatter.md",
            "Heatmap" => "render/heatmap.md",
            "Volume" => "render/volume.md",
        ],
        "API Reference" => "api.md",
    ]
)

deploydocs(
    repo = "github.com/blhackslash/PDEStudio.jl.git",
    devbranch = "main",
    push_preview = true,
)