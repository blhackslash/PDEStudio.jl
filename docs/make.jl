using Documenter
using PDEStudio

makedocs(
    sitename = "PDEStudio.jl",
    modules = [PDEStudio],
    checkdocs = :exports,
    # PDEStudioCore names are reexported; their docstrings live in the PDEStudioCore documentation.
    warnonly = [:missing_docs, :cross_references],
    format = Documenter.HTML(
        prettyurls = get(ENV, "CI", "false") == "true",
        assets = String[],
    ),
    pages = [
        "Home" => "index.md",
        "Control Panel" => "overview.md",
        "File Operations" => "file_ops.md",
        "Presets" => "presets.md",
        "Advanced Editors" => "editors.md",
        "Rendering" => "rendering.md",
        "Exploration" => "sliders.md",
        "API Reference" => "api.md",
    ],
)
format = Documenter.HTML(
    prettyurls = get(ENV, "CI", "false") == "true",
    canonical = "https://blhackslash.github.io/PDEStudio.jl/",
    assets = String[],
),

deploydocs(
    repo = "github.com/blhackslash/PDEStudio.jl.git",
    devbranch = "main",
    push_preview = true,
)