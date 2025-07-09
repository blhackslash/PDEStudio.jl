const UIType = Union{Symbol,Dict}

# In src/ui_styles.jl

"""
    createUIDict(options::Union{Symbol, Dict})

Normalizes UI options input. If a Symbol is provided, it fetches the
corresponding predefined style. If a Dict is provided, it returns a
deep copy to prevent modification of the original.
"""
function createUIDict(options::UIType)
    if isa(options, Symbol)
        # Fetches a new dictionary for the predefined style symbol (e.g., :default, :publication)
        return GetUIStyle(options)
    elseif isa(options, Dict)
        # Return a deep copy to ensure the user's original dictionary is not modified
        return deepcopy(options)
    end
    # Fallback for safety, though should not be reached with Union type hint
    return Dict{String, Any}()
end

"""
    GetUIStyle(style::Symbol)

Returns a dictionary of UI options for pre-defined plotting styles.
Available styles include: `:default`, `:publication`, `:simple`.
"""
function GetUIStyle(style::Symbol)
    # Define the base default style first
    default_style = Dict{String, Any}(
        "dashed_lines" => false,
        "show_scatter" => false,
        "show_lines" => true,
        "track_max" => false,
        "track_min" => false,
        "figsize" => (1280, 800),
        "linewidth" => 5,
        "markersize" => 15,
        "label_size" => 24,
        "title_size" => 26,
        "ticklabel_size" => 22,
        "font_size" => 24,
        "legend" => "Methods",
        "sort_legend" => true,
        "xpadding" => 0,
        "ypadding" => 0.1,
        "animation_fps" => 30,
        "animation_duration_s" => 10.0,
        "legend_pos" => "righttop",
        "xgridvisible" => true,
        "ygridvisible" => true,
        "xticklabelsvisible" => true,
        "yticklabelsvisible" => true,
        "title" => "default",
        "xlabel" => "default",
        "ylabel" => "default",
        "xlogscale" => false,
        "ylogscale" => false,
        "reference" => (1.,),
        "update_limits" => false,
        "save_formats" => ["png"], # Default to saving only PNG
        "colors" => [:red, :blue, :green, :orange, :purple, :brown, :cyan, :yellow, :gray, :magenta, :navy],
        "markers" => [:rect, :circle, :utriangle, :dtriangle, :cross, :xcross],
        "lineStyles" => [:solid, (:dash, :dense), (:dash, :normal), (:dashdot, :dense), (:dashdot, :normal), (:dot, :dense), (:dot, :normal)]
    )

    if style == :default
        return default_style
    elseif style == :publication
        # Start with a copy of the default and modify it
        publication_style = deepcopy(default_style)
        merge!(publication_style, Dict{String, Any}(
            "linewidth" => 2.5,
            "title_size" => 14,
            "legend_pos" => "righttop",
            "label_size" => 14,
            "ticklabel_size" => 12,
            "font_size" => 14,
            "figsize" => (700, 550),
            "save_formats" => ["png", "pdf", "svg"] # For publication, save all formats
            # You could also add other font settings here
        ))
        return publication_style
    elseif style == :simple
        simple_style = deepcopy(default_style)
        merge!(simple_style, Dict{String, Any}(
            "linewidth" => 3,
            "label_size" => 18,
            "ticklabel_size" => 16,
        ))
        return simple_style
    # Add other styles as needed
    else
        @warn "UI style ':$style' not recognized. Returning default style."
        return default_style
    end
end

#======================================================================#
#                      UI STYLES FOR 2D PLOTS
#======================================================================#

"""
    get_ui_style_2D(style::Symbol) -> Dict

Returns a dictionary of UI options for pre-defined 2D plotting styles.
Available styles include: `:default`, `:publication`.
"""
function getUIStyle2D(style::Symbol)
    # --- Base Default Style for 2D Plots ---
    default_style_2D = Dict{String, Any}(
        "system_dimension" => 1,
        "figsize" => (1280, 800),
        "markersize_2d" => 15,
        "markersize_3d" => Vec3f(0.2, 0.2, 0.2),
        "label_size" => 24,
        "ticklabel_size" => 22,
        "font_size" => 24,
        "legend" => "Legend",
        "xpadding" => 0,
        "ypadding" => 0.1,
        "animation_fps" => 30,
        "animation_duration_s" => 10.0,
        "legend_pos" => "detached",
        "xgridvisible" => true,
        "ygridvisible" => true,
        "xticklabelsvisible" => true,
        "yticklabelsvisible" => true,
        "title" => "default",
        "xlabel" => "default",
        "ylabel" => "default",
        "zlabel" => "default",
        "colorbar_label" => "default",
        "xlogscale" => false,
        "ylogscale" => false,
        "colors" => [:red, :blue, :green, :orange, :purple, :brown, :cyan, :yellow, :gray, :magenta, :navy],
        "markers" => [:circle, :rect, :utriangle, :dtriangle, :cross, :xcross],
        "plot_as_surface" => false,
        "colormap" => :viridis,
        "colormaps" => [:viridis, :plasma, :inferno, :magma, :thermal, :coolwarm, :balance, :grays],
        "axis_limit_padding" => 0.1
    )

    if style == :default
        return default_style_2D
    elseif style == :publication
        publication_style_2D = deepcopy(default_style_2D)
        merge!(publication_style_2D, Dict{String, Any}(
            "figsize" => (700, 550), # A more paper-friendly size
            "label_size" => 16,
            "ticklabel_size" => 14,
            "font_size" => 16,
            "markersize_2d" => 10,
            "markersize_3d" => Vec3f(0.1, 0.1, 0.1),
        ))
        return publication_style_2D
    # You can add other 2D-specific styles here, e.g., :heatmap_default
    else
        @warn "2D UI style ':$style' not recognized. Returning default 2D style."
        return default_style_2D
    end
end

"""
    createUIDict2D(options::UIType) -> Dict

Normalizes UI options for 2D plots. If a Symbol is provided, it fetches the
corresponding predefined 2D style. If a Dict is provided, it returns a deep copy.
"""
function createUIDict2D(options::UIType)
    if isa(options, Symbol)
        return getUIStyle2D(options)
    elseif isa(options, Dict)
        return deepcopy(options)
    end
    return Dict{String, Any}() # Fallback
end

ui_dict = Dict(
    "system_dimension" => 1,
    "dashed_lines" => false,
    "show_scatter" => false,
    "show_lines" => true,
    "hPos" => :right,
    "vPos" => :top,
    "figsize" => (1280,800),
    "linewidth" => 6,
    "markersize" => 20,
    "label_size" => 24,
    "ticklabel_size" => 22,
    "font_size" => 24,
    "legend" => "Legend",
    "xpadding" => 0,
    "ypadding" => 0.1,
    "animation_fps" => 30,
    "animation_duration_s" => 10.,
    "colors" => [:red, :blue, :green, :orange, :purple, :brown, :cyan, :yellow, :gray, :magenta, :navy],
    "markers" => [:rect, :circle, :utriangle, :dtriangle, :cross, :xcross],
    "lineStyles" => [:solid, (:dash, :dense), (:dash, :normal), (:dashdot, :dense), (:dashdot, :normal), (:dot, :dense), (:dot, :normal)]
)

# --- ui_dict definition ---
# Add the new option for 2D plotting type
ui_dict2D = Dict(
    # ... (previous keys) ...
    "hPos" => :right,
    "vPos" => :top,
    "figsize" => (1280, 800),
    "markersize_2d" => 15,    # Marker size for 2D scatter plot
    "markersize_3d" => Vec3f(0.2, 0.2, 0.2), # Marker size for 3D meshscatter (can be Vec3f or Float)
    "label_size" => 24,
    "ticklabel_size" => 22,
    "font_size" => 24,
    "legend" => "Legend",
    "colors" => [:red, :blue, :green, :orange, :purple, :brown, :cyan, :yellow, :gray, :magenta, :navy],
    "markers" => [:circle, :rect, :utriangle, :dtriangle, :cross, :xcross], # Markers for legend mostly
    "lineStyles" => [:solid, (:dash, :dense), (:dash, :normal), (:dashdot, :dense), (:dashdot, :normal), (:dot, :dense), (:dot, :normal)], # Less relevant
    "plot_as_surface" => false, # << NEW: false for scatter/heatmap, true for surface
    "colormap" => :viridis,     # Default colormap
    "colormaps" => [:viridis, :plasma, :inferno, :magma, :thermal, :coolwarm, :balance, :grays], # Available colormaps
    "axis_limit_padding" => 0.1
)