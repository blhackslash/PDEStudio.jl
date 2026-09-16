# docs/make.jl
using Documenter
using PDEStudio

makedocs(
    sitename = "PDEStudio.jl",
    modules = [PDEStudio],
    remotes = nothing,
    checkdocs = :exports, # Tell Documenter to ignore unlisted private functions
    format = Documenter.HTML(
        # Set this if you link between pages without '.html'
        prettyurls = true,
        # Informs Documenter that the site lives under /PDECore/
        canonical = "https://docs.blackslash.win/PDEStudio/"
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
