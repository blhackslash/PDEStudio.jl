const UIType = Union{Symbol,Dict}

# --- NEW: Source of Truth for Dimensionality ---
const PLOT_DIM_MAP = Dict(
    :lines     => 1,
    :heatmap   => 2,
    :contour   => 2,
    :scatter2d => 2,
    :surface   => 3,
    :scatter3d => 3
)

function create_master_ui_observables(style::Symbol=:default)
    master = NestedObsDict()
    obs_dict(d) = Dict{String, Observable}(k => Observable(v) for (k,v) in d)
    
    # 1. Universal Scopes (Axis-General, Labels, Various)
    master["Axis-General"] = obs_dict(Dict("figsize" => (1280, 800), "font_size" => 24, "title_size" => 26, "label_size" => 24, "ticklabel_size" => 22))
    master["Labels"]       = obs_dict(Dict("title" => "default", "xlabel" => "default", "ylabel" => "default", "zlabel" => "default", "colorbar_label" => "default", "legend" => "Methods"))
    master["Various"]      = obs_dict(Dict("save_formats" => ["png"], "animation_duration_s" => 10.0, "animation_fps" => 30, "reference" => (0.0,), "remove_outliers" => false, "mark_outliers" => false, "outlier_threshold" => 1.5, "track_max" => false, "track_min" => false))
    
    # 2. Axes (1D vs ND padding logic remains)
    master["X-Axis-1D"] = obs_dict(Dict("xgridvisible" => true, "xticklabelsvisible" => true, "xtick_count" => 0, "xtickformat" => "default", "xscale_offset" => 0.0, "xlogscale" => false, "xpadding" => 0.05))
    master["Y-Axis-1D"] = obs_dict(Dict("ygridvisible" => true, "yticklabelsvisible" => true, "ytick_count" => 0, "ytickformat" => "default", "yscale_offset" => 0.0, "ylogscale" => false, "ypadding" => 0.05))
    
    master["X-Axis-ND"] = obs_dict(Dict("xgridvisible" => true, "xticklabelsvisible" => true, "xtick_count" => 0, "xtickformat" => "default", "xscale_offset" => 0.0, "xlogscale" => false, "xpadding" => 0.0))
    master["Y-Axis-ND"] = obs_dict(Dict("ygridvisible" => true, "yticklabelsvisible" => true, "ytick_count" => 0, "ytickformat" => "default", "yscale_offset" => 0.0, "ylogscale" => false, "ypadding" => 0.0))
    master["Z-Axis-3D"] = obs_dict(Dict("zgridvisible" => true, "zticklabelsvisible" => true, "ztick_count" => 0, "ztickformat" => "default", "zscale_offset" => 0.0, "zlogscale" => false, "zpadding" => 0.05))
    
    # --- 3. PLOT-SPECIFIC STYLES ---
    master["Style-Lines"] = obs_dict(Dict(
        "colors"       => [:red, :blue, :green, :orange, :purple],
        "lineStyles"   => [:solid, (:dash, :dense), (:dot, :dense)],
        "linewidth"    => 5.0,
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
        "colormap"      => :viridis,
        "levels"        => 15,
        "linewidth"     => 2.0,
        "bottom_margin" => 60,
        "xlabel_offset" => 40.0,
        "ylabel_offset" => 40.0,
    ))

    master["Style-Surface"] = obs_dict(Dict(
        "colormap"      => :viridis,
        "xlabel_offset" => 40.0,
        "ylabel_offset" => 40.0,
        "zlabel_offset" => 50.0,
    ))
    
    # Shared scatter settings for both 2D and 3D
    master["Style-Scatter2D"] = obs_dict(Dict("colors" => [:red, :blue], "markers" => [:circle, :rect], "markersize" => 15.0, "legend_pos" => "detached", "bottom_margin" => 60, "xlabel_offset" => 40.0, "ylabel_offset" => 40.0))
    master["Style-Scatter3D"] = obs_dict(Dict("colors" => [:red, :blue], "markers" => [:circle, :rect], "markersize" => 15.0, "legend_pos" => "detached", "xlabel_offset" => 40.0, "ylabel_offset" => 40.0, "zlabel_offset" => 50.0))

    return master
end

function switch_ui_plot_type!(manager::PlotManager, plot_type::Symbol)
    master = manager.controls["Master_UI_Ref"][]
    ui = manager.ui
    empty!(ui)
    
    dim = PLOT_DIM_MAP[plot_type]
    
    ui["Axis-General"] = master["Axis-General"]
    ui["Labels"]       = master["Labels"]
    ui["Various"]      = master["Various"]
    
    # Map the specific style block!
    # e.g., :scatter2d maps to "Style-Scatter2D"
    style_key = "Style-" * titlecase(string(plot_type)) 
    
    # Handle the capitalization differences for 2D/3D suffixes
    style_key = replace(style_key, "2d" => "2D", "3d" => "3D") 
    ui["Plot-Style"] = master[style_key]
    
    if dim == 1
        ui["X-Axis"] = master["X-Axis-1D"]
        ui["Y-Axis"] = master["Y-Axis-1D"]
    elseif dim == 2
        ui["X-Axis"] = master["X-Axis-ND"]
        ui["Y-Axis"] = master["Y-Axis-ND"]
    elseif dim == 3
        ui["X-Axis"] = master["X-Axis-ND"]
        ui["Y-Axis"] = master["Y-Axis-ND"]
        ui["Z-Axis"] = master["Z-Axis-3D"]
    end
    
    if haskey(manager.controls, "UI_Update"); notify(manager.controls["UI_Update"]); end
end