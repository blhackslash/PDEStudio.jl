const UIType = Union{Symbol,Dict}

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
        "xpadding" => 0.,
        "ypadding" => 0.1,
        "animation_fps" => 30,
        "animation_duration_s" => 10.0,
        "legend_pos" => "detached",
        "xgridvisible" => true,
        "ygridvisible" => true,
        "xticklabelsvisible" => true,
        "yticklabelsvisible" => true,
        "xtick_count" => 0,
        "ytick_count" => 0,
        "xtickformat" => "default",
        "ytickformat" => "default",
        "xscale_offset" => 0.,
        "yscale_offset" => 0.,
        "title" => "default",
        "xlabel" => "default",
        "ylabel" => "default",
        "xlogscale" => false,
        "ylogscale" => false,
        "reference" => (0.,),
        "update_limits" => false,
        "save_formats" => ["png"], # Default to saving only PNG
        "create_savefolder" => false,
        "mark_outliers" => false,
        "remove_outliers" => false,
        "comp_names" => ("default",),
        "outlier_threshold" => 1.5,
        "colors" => [:red, :blue, :green, :orange, :purple, :brown, :cyan, :yellow, :gray, :magenta, :navy],
        "markers" => [:rect, :circle, :utriangle, :dtriangle, :cross, :xcross],
        "lineStyles" => [:solid, (:dash, :dense), (:dash, :normal), (:dashdot, :dense), (:dashdot, :normal), (:dot, :dense), (:dot, :normal), (:dash, :dense), (:dash, :normal), (:dashdot, :dense), (:dashdot, :normal), (:dot, :dense), (:dot, :normal)]
    )

    if style == :default
        return default_style
    elseif style == :publication
        # Start with a copy of the default and modify it
        publication_style = deepcopy(default_style)
        merge!(publication_style, Dict{String, Any}(
            "linewidth" => 2.5,
            "markersize" => 10,
            "title_size" => 14,
            "legend_pos" => "righttop",
            "show_scatter" => true,
            "label_size" => 14,
            "ticklabel_size" => 12,
            "title" => "",
            "legend" => "",
            "font_size" => 14,
            "figsize" => (700, 550),
            "update_limits" => true,
            "save_formats" => ["png", "pdf", "svg"]
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
    else
        @warn "UI style ':$style' not recognized. Returning default style."
        return default_style
    end
end

#======================================================================#
#                      UI STYLES FOR 2D PLOTS
#======================================================================#

"""
    getUIStyle2D(style::Symbol) -> Dict

Returns a dictionary of UI options for pre-defined 2D plotting styles.
It builds upon the 1D styles from `GetUIStyle` and adds/overrides
2D-specific keys.
"""
function getUIStyle2D(style::Symbol)
    # --- 1. Start with the corresponding 1D style as a base ---
    base_style = GetUIStyle(style)

    # --- 2. Define 2D-specific additions and overrides ---
    default_2D_additions = Dict{String, Any}(
        "markersize_2d" => 15,
        "markersize_3d" => Vec3f(0.2, 0.2, 0.2),
        "plot_as_surface" => false,
        "colormap" => :viridis,
        "colormaps" => [:viridis, :plasma, :inferno, :magma, :thermal, :coolwarm, :balance, :grays],
        "axis_limit_padding" => 0.1,
        # Override labels for 2D context
        "zlabel" => "default",
        "colorbar_label" => "default"
    )

    # Merge the 2D additions into the base style
    final_style = merge(base_style, default_2D_additions)

    # --- 3. Apply any 2D-specific modifications for non-default styles ---
    if style == :publication
        merge!(final_style, Dict{String, Any}(
            "markersize_2d" => 10,
            "markersize_3d" => Vec3f(0.1, 0.1, 0.1)
        ))
    end
    
    # --- 4. Remove 1D-only keys that are not applicable to 2D plots ---
    irrelevant_keys = ["show_lines", "dashed_lines", "track_max", "track_min", "linewidth", "markersize", "lineStyles", "reference"]
    for key in irrelevant_keys
        delete!(final_style, key)
    end

    return final_style
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