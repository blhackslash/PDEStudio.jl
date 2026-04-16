const UIType = Union{Symbol,MethodDict}

# --- Source of Truth for Dimensionality ---
const PLOT_DIM_MAP = Dict(
    :lines     => 1,
    :heatmap   => 2,
    :contour   => 2,
    :contourf  => 2,
    :scatter2d => 2,
    :surface   => 2,
    :contour3d => 3,
    :scatter3d => 3,
    :volume    => 3  # <-- ADDED VOLUME
)

"""
    create_master_ui_observables(style::Symbol)

Creates the definitive Master Dictionary containing EVERY possible UI option as Observables.
"""
function create_master_ui_observables(style::Symbol=:default)
    master = NestedObsDict()
    obs_dict(d) = Dict{String, Observable}(k => Observable(v) for (k,v) in d)
    
    # 1. Universal Scopes
    master["Axis-General"] = obs_dict(Dict(
        "figsize"        => (1280, 800), 
        "font_size"      => 24, 
        "title_size"     => 26, 
        "label_size"     => 24, 
        "ticklabel_size" => 22
    ))
    
    master["Labels"] = obs_dict(Dict(
        "title"          => "default", 
        "xlabel"         => "default", 
        "ylabel"         => "default", 
        "zlabel"         => "default", 
        "colorbar_label" => "default", 
        "legend"         => "Methods"
    ))
    
    master["Various"] = obs_dict(Dict(
        "save_formats"         => ["png"], 
        "create_savefolder"    => false,      # <-- ADDED (Prevents export crash)
        "comp_names"           => ("default",), # <-- ADDED
        "animation_duration_s" => 10.0, 
        "animation_fps"        => 30, 
        "reference"            => (0.0,), 
        "remove_outliers"      => false, 
        "mark_outliers"        => false, 
        "outlier_threshold"    => 1.5, 
        "track_max"            => false, 
        "track_min"            => false
    ))
    
    # 2. Axes (Hierarchic Generator)
    axis_dict(pad) = Dict{String, Any}(
        "gridvisible"       => true, 
        "ticklabelsvisible" => true, 
        "tick_count"        => 0, 
        "tickformat"        => "default", 
        "scale_offset"      => 0.0, 
        "logscale"          => false, 
        "padding"           => pad
    )

    master["X-Axis-1D"] = obs_dict(axis_dict(0.05))
    master["Y-Axis-1D"] = obs_dict(axis_dict(0.05))
    
    master["X-Axis-ND"] = obs_dict(axis_dict(0.0))
    master["Y-Axis-ND"] = obs_dict(axis_dict(0.0))
    master["Z-Axis-3D"] = obs_dict(axis_dict(0.05))
    
    # --- 3. PLOT-SPECIFIC STYLES ---
    master["Style-Lines"] = obs_dict(Dict(
        "colors"       => [:red, :blue, :green, :orange, :purple],
        "lineStyles"   => [:solid, (:dash, :dense), (:dot, :dense)],
        "markers"      => [:circle, :rect, :utriangle, :dtriangle, :cross], # <-- ADDED
        "linewidth"    => 5.0,
        "markersize"   => 15.0,  # <-- ADDED
        "show_lines"   => true,  # <-- ADDED
        "show_scatter" => false, # <-- ADDED
        "dashed_lines" => false, # <-- ADDED
        "legend_pos"   => "detached",
        "sort_legend"  => true,
    ))
    
    master["Style-Heatmap"] = obs_dict(Dict(
        "colormap"      => :viridis,
        "bottom_margin" => 60,
        "xlabel_offset" => 40.0,
        "ylabel_offset" => 40.0,
    ))
    
    master["Style-Contour"] = obs_dict(Dict(
        "colors"        => [:red, :blue, :green, :orange, :purple],
        "levels"        => 15,
        "linewidth"     => 2.0,
        "bottom_margin" => 60,
        "xlabel_offset" => 40.0,
        "ylabel_offset" => 40.0,
        "legend_pos"    => "detached", # <-- ADDED (Needed for contours)
        "sort_legend"   => true,       # <-- ADDED
    ))
    
    master["Style-Contourf"] = obs_dict(Dict(
        "colormap"      => :viridis,
        "levels"        => 15,
        "bottom_margin" => 60,
        "xlabel_offset" => 40.0,
        "ylabel_offset" => 40.0,
        "legend_pos"    => "detached", # <-- ADDED 
        "sort_legend"   => true,       # <-- ADDED
    ))

    master["Style-Contour3D"] = obs_dict(Dict(
        "colors"        => [:red, :blue, :green, :orange, :purple],
        "levels"        => 15,
        "linewidth"     => 2.0,
        "xlabel_offset" => 40.0,
        "ylabel_offset" => 40.0,
        "zlabel_offset" => 50.0,
        "legend_pos"    => "detached", # <-- ADDED 
        "sort_legend"   => true,       # <-- ADDED
    ))

    master["Style-Surface"] = obs_dict(Dict(
        "colormap"      => :viridis,
        "xlabel_offset" => 40.0,
        "ylabel_offset" => 40.0,
        "zlabel_offset" => 50.0,
    ))
    
    # --- ADDED TRUE 3D VOLUME ---
    master["Style-Volume"] = obs_dict(Dict(
        "colormap"      => :viridis,
        "xlabel_offset" => 40.0,
        "ylabel_offset" => 40.0,
        "zlabel_offset" => 50.0,
    ))

    master["Style-Scatter2D"] = obs_dict(Dict(
        "colormap"      => :viridis,
        "colors"        => [:red, :blue], 
        "markers"       => [:circle, :rect], 
        "markersize"    => 15.0, 
        "legend_pos"    => "detached", 
        "bottom_margin" => 60, 
        "xlabel_offset" => 40.0, 
        "ylabel_offset" => 40.0
    ))
    
    master["Style-Scatter3D"] = obs_dict(Dict(
        "colormap"      => :viridis,
        "colors"        => [:red, :blue], 
        "markers"       => [:circle, :rect], 
        "markersize"    => 15.0, 
        "legend_pos"    => "detached", 
        "xlabel_offset" => 40.0, 
        "ylabel_offset" => 40.0, 
        "zlabel_offset" => 50.0
    ))

    if style == :publication
        master["Axis-General"]["figsize"][] = (800, 600)
        master["Style-Lines"]["lineStyles"][] = [(:dash, :dense), (:dot, :dense), :solid]
        master["Style-Lines"]["linewidth"][] = 4.0
        master["Style-Lines"]["dashed_lines"][] = true
    end

    return master
end

"""
    switch_ui_plot_type!(manager::PlotManager, plot_type::Symbol)

Clears the active UI dictionary and repopulates it with DIRECT REFERENCES 
to the Master UI dictionary scopes based on the requested View Type.
"""
function switch_ui_plot_type!(manager::PlotManager, plot_type::Symbol)
    master = manager.controls["Master_UI_Ref"][]
    ui = manager.ui
    empty!(ui)
    
    dim = PLOT_DIM_MAP[plot_type]
    
    # 1. Universal Scopes
    ui["Axis-General"] = master["Axis-General"]
    ui["Labels"]       = master["Labels"]
    ui["Various"]      = master["Various"]
    
    # 2. Map the specific style block dynamically
    style_key = "Style-" * titlecase(string(plot_type)) 
    style_key = replace(style_key, "2d" => "2D", "3d" => "3D", "Contourf" => "Contourf") 
    ui["Plot-Style"] = master[style_key]
    
    # 3. Map Axis Dimensionalities
    if dim == 1
        ui["X-Axis"] = master["X-Axis-1D"]
        ui["Y-Axis"] = master["Y-Axis-1D"]
    elseif dim == 2 && !(plot_type==:surface)
        ui["X-Axis"] = master["X-Axis-ND"]
        ui["Y-Axis"] = master["Y-Axis-ND"]
    elseif dim == 3 || plot_type==:surface
        ui["X-Axis"] = master["X-Axis-ND"]
        ui["Y-Axis"] = master["Y-Axis-ND"]
        ui["Z-Axis"] = master["Z-Axis-3D"]
    end
    
    if haskey(manager.controls, "UI_Update")
        notify(manager.controls["UI_Update"])
    end
end