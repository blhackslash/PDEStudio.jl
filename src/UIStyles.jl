const UIType = Union{Symbol,Dict}

"""
    GetUIStyle(style::Symbol)

Returns a nested dictionary of UI options: Dict{String, Dict{String, Any}}.
Scopes: "Axis", "Legend", "Appearance", "Various".
"""
function GetUIStyle(style::Symbol)
    # 1. Define the Nested Default Style
    default_style = Dict{String, Dict{String, Any}}(
        "Axis" => Dict{String, Any}(
            "title"              => "default",
            "xlabel"             => "default",
            "ylabel"             => "default",
            "label_size"         => 24,
            "title_size"         => 26,
            "ticklabel_size"     => 22,
            "font_size"          => 24,
            "figsize"            => (1280, 800),
            "xgridvisible"       => true,
            "ygridvisible"       => true,
            "xticklabelsvisible" => true,
            "yticklabelsvisible" => true,
            "xtick_count"        => 0,
            "ytick_count"        => 0,
            "xtickformat"        => "default",
            "ytickformat"        => "default",
            "xscale_offset"      => 0.,
            "yscale_offset"      => 0.,
            "xlogscale"          => false,
            "ylogscale"          => false,
            "xpadding"           => 0.,
            "ypadding"           => 0.1,
            "update_limits"      => false
        ),
        "Legend" => Dict{String, Any}(
            "legend"             => "Methods",
            "sort_legend"        => true,
            "legend_pos"         => "detached"
        ),
        "Appearance" => Dict{String, Any}(
            "linewidth"          => 5,
            "markersize"         => 15,
            "dashed_lines"       => false,
            "show_scatter"       => false,
            "show_lines"         => true,
            "colors"             => [:red, :blue, :green, :orange, :purple, :brown, :cyan, :yellow, :gray, :magenta, :navy],
            "markers"            => [:rect, :circle, :utriangle, :dtriangle, :cross, :xcross],
            "lineStyles"         => [:solid, (:dash, :dense), (:dash, :normal), (:dashdot, :dense), (:dashdot, :normal), (:dot, :dense), (:dot, :normal)]
        ),
        "Various" => Dict{String, Any}(
            "animation_fps"        => 30,
            "animation_duration_s" => 10.0,
            "track_max"            => false,
            "track_min"            => false,
            "reference"            => (0.,),
            "save_formats"         => ["png"],
            "create_savefolder"    => false,
            "mark_outliers"        => false,
            "remove_outliers"      => false,
            "comp_names"           => ("default",),
            "outlier_threshold"    => 1.5
        )
    )

    if style == :default
        return default_style

    elseif style == :publication
        pub = deepcopy(default_style)
        # Apply overrides to specific scopes
        merge!(pub["Axis"], Dict(
            "title_size"      => 14,
            "label_size"      => 14,
            "ticklabel_size"  => 12,
            "font_size"       => 14,
            "figsize"         => (700, 550),
            "update_limits"   => true,
            "title"           => ""
        ))
        merge!(pub["Legend"], Dict(
            "legend_pos"      => "righttop",
            "legend"          => ""
        ))
        merge!(pub["Appearance"], Dict(
            "linewidth"       => 3.0,
            "markersize"      => 10,
            "show_scatter"    => true
        ))
        merge!(pub["Various"], Dict(
            "save_formats"    => ["png", "pdf", "svg"]
        ))
        return pub

    elseif style == :simple
        sim = deepcopy(default_style)
        merge!(sim["Axis"], Dict(
            "label_size"     => 18,
            "ticklabel_size" => 16
        ))
        merge!(sim["Appearance"], Dict(
            "linewidth"      => 3
        ))
        return sim

    else
        @warn "UI style ':$style' not recognized. Returning default."
        return default_style
    end
end
"""
    createUIDict(options::Union{Symbol, Dict})

Returns a nested Dict{String, Dict{String, Any}}.
If a flat Dict is provided, it automatically sorts keys into the correct scopes.
"""
function createUIDict(options::UIType)
    if isa(options, Symbol)
        return GetUIStyle(options)
    elseif isa(options, Dict)
        # If it's already nested, just return it
        if any(v -> isa(v, Dict), values(options))
            return deepcopy(options)
        end
        
        # Otherwise, merge a flat dict into the default nested structure
        base = GetUIStyle(:default)
        for (key, val) in options
            found = false
            for scope in keys(base)
                if haskey(base[scope], key)
                    base[scope][key] = val
                    found = true
                    break
                end
            end
            !found && @warn "UI Key '$key' not found in any scope. Adding to 'Various'."
            if !found; base["Various"][key] = val; end
        end
        return base
    end
    return GetUIStyle(:default)
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
        "plot_type" => :contourf,
        "plot_options" => [:scatter2d,:scatter3d,:surface,:contour,:contourf],
        "colormap" => :viridis,
        "colormaps" => [:viridis, :plasma, :inferno, :magma, :thermal, :coolwarm, :balance, :grays],
        "xpadding" => 0.,
        "ypadding" => 0.,
        "zpadding" => 0.4,
        # Override labels for 2D context
        "zlabel" => "default",
        "colorbar_label" => "default",
        "contour_levels" => 10,
    # --- 2D View Offsets (Top-Down) ---
        # These need to be higher to prevent overlap with ticks in orthographic projection
        "xlabel_offset_2d" => 40.0,
        "ylabel_offset_2d" => 80.0,
        "bottom_margin_2d"   => 60,

        # --- 3D View Offsets (Perspective) ---
        # Standard Makie defaults usually work well here
        "xlabel_offset_3d" => 40.0,
        "ylabel_offset_3d" => 40.0,
        "zlabel_offset_3d" => 50.0,
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
    irrelevant_keys = ["show_lines", "dashed_lines", "track_max", "track_min", "markersize", "lineStyles", "reference","xlogscale","ylogscale"]
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