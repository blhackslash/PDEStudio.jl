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
    :volume    => 3
)

"""
    create_master_ui_observables()

Creates the definitive Master Dictionary containing EVERY possible UI option as Observables.
"""
function create_master_ui_observables()
    master = NestedObsDict()
    make_obs(v) = (v isa Tuple || v isa AbstractVector) ? Observable{Any}(v) : Observable(v)
    obs_dict(d) = Dict{String, Observable}(k => make_obs(v) for (k,v) in d)
    
    # 1. Universal Scopes
    master["Axis-General"] = obs_dict(Dict(
        "plot_size"      => (500, 400),
        "font_size"      => 24, 
        "title_size"     => 26, 
        "label_size"     => 24, 
        "ticklabel_size" => 22,
        "legend_pos"     => :dr,
        "sort_legend"    => true,
    ))
    
    master["Labels"] = obs_dict(Dict(
        "title"          => "default", 
        "xlabel"         => "default", 
        "ylabel"         => "default", 
        "zlabel"         => "default", 
        "colorbar_label" => "default", 
        "legend"         => "Methods"
    ))
    master["HUD"] = obs_dict(Dict(
        "visible"    => false,
        "mode"       => "lines", 
        "close_loop" => false,   
        "points"     => Any[],   
        "color"      => :red,
        "linewidth"  => 3.0,
        "linestyle"  => :dash,
        "markersize" => 15.0
    ))  
    master["Various"] = obs_dict(Dict(
        "save_formats"         => ["png"], 
        "create_savefolder"    => false,      
        "comp_names"           => ("default",), 
        "animation_duration_s" => 10.0, 
        "animation_fps"        => 30, 
        "remove_outliers"      => false, 
        "mark_outliers"        => false, 
        "outlier_threshold"    => 1.5, 
        "track_max"            => false, 
        "track_min"            => false,
    ))
    
    # 2. THE FIX: Added 'label_offset' to the Universal Axis Template!
    axis_dict(pad, default_offset=15.0) = Dict{String, Any}(
        "gridvisible"       => true, 
        "ticklabelsvisible" => true, 
        "tick_count"        => 0, 
        "tickformat"        => "default", 
        "scale_offset"      => 0.0, 
        "logscale"          => false, 
        "padding"           => pad,
        "label_offset"      => default_offset
    )

    master["X-Axis-1D"] = obs_dict(axis_dict(0.05, 15.0))
    master["Y-Axis-1D"] = obs_dict(axis_dict(0.05, 15.0))
    
    master["X-Axis-ND"] = obs_dict(axis_dict(0.0, 15.0))
    master["Y-Axis-ND"] = obs_dict(axis_dict(0.0, 15.0))
    master["Z-Axis-3D"] = obs_dict(axis_dict(0.05, 20.0)) # Z gets slightly more default space
    
    # --- 3. PLOT-SPECIFIC STYLES (Offsets Safely Extracted) ---
    master["Style-Lines"] = obs_dict(Dict(
        "colors"       => [:red, :blue, :green, :orange, :purple],
        "lineStyles"   => [:solid, (:dash, :dense), (:dot, :dense)],
        "markers"      => [:circle, :rect, :utriangle, :dtriangle, :cross],
        "linewidth"    => 5.0,
        "markersize"   => 15.0,
        "show_lines"   => true,
        "show_scatter" => false,
        "dashed_lines" => false,
        "reference"    => [],
    ))
    
    master["Style-Heatmap"] = obs_dict(Dict(
        "colorrange"    => [],
        "colormap"      => :viridis,
        "bottom_margin" => 60,
        "rasterize"     => 2,
    ))
    
    master["Style-Contour"] = obs_dict(Dict(
        "colors"        => [:black, :red, :green, :orange, :purple],
        "levels"        => 15,
        "linewidth"     => 2.0,
        "bottom_margin" => 60,
        "labels"        => true,
    ))
    
    master["Style-Contourf"] = obs_dict(Dict(
        "colorrange"    => [],
        "base_method_idx" => 1,
        "colors"        => [:red, :blue, :green, :orange, :purple],
        "linewidth"     => 2.0,
        "colormap"      => :viridis,
        "levels"        => 15,
        "bottom_margin" => 60,
        "rasterize"     => 2,
    ))

    master["Style-Contour3D"] = obs_dict(Dict(
        "colors"        => [:red, :blue, :green, :orange, :purple],
        "levels"        => 15,
        "linewidth"     => 2.0,
    ))

    master["Style-Surface"] = obs_dict(Dict(
        "colorrange"    => [],
        "colormap"      => :viridis,
        "rasterize"     => 2,
    ))
    
    master["Style-Volume"] = obs_dict(Dict(
        "colorrange"    => [],
        "colormap"      => :viridis,
        "rasterize"     => 2.0,
    ))

    master["Style-Scatter2D"] = obs_dict(Dict(
        "colorrange"    => [],
        "colormap"      => :viridis,
        "colors"        => [:red, :blue], 
        "markers"       => [:circle, :rect], 
        "markersize"    => 15.0, 
        "bottom_margin" => 60, 
        "rasterize"     => 2,
    ))
    
    master["Style-Scatter3D"] = obs_dict(Dict(
        "colorrange"    => [],
        "colormap"      => :viridis,
        "colors"        => [:red, :blue], 
        "markers"       => [:circle, :rect], 
        "markersize"    => 15.0, 
        "rasterize"     => 2,
    ))
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
    ui["HUD"]          = master["HUD"]
    
    style_key = "Style-" * titlecase(string(plot_type)) 
    style_key = replace(style_key, "2d" => "2D", "3d" => "3D", "Contourf" => "Contourf") 
    ui["Plot-Style"] = master[style_key]
    
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

function set_plot_presets!(presets::Union{Symbol, Vector{Symbol}})
    preset_list = presets isa Symbol ? [presets] : presets
    ui_over = Dict{String, Any}()
    scene_opt = Dict{String, Any}()
    master_tmp = create_master_ui_observables()

    function set_ui!(scope, key, val)
        if !haskey(ui_over, scope); ui_over[scope] = Dict{String, Any}(); end
        ui_over[scope][key] = val
    end

    for preset in preset_list
        if preset == :convergence
            scene_opt["X-Axis_Selection"]    = "Ns__1"
            scene_opt["U-Axis_Selection"]    = "relative_l2error"
            scene_opt["Plot-Type_Selection"] = "Lines"
            scene_opt["t_Value"]             = 10.0^10
            
            set_ui!("X-Axis", "logscale", true)
            set_ui!("Y-Axis", "logscale", true)
            set_ui!("X-Axis", "padding", 0.0)
            
            set_ui!("Labels", "xlabel", "Number of Cells (N)")
            set_ui!("Labels", "ylabel", "Relative L2 Error")

        elseif preset == :publication
            set_ui!("Labels", "title", "")
            set_ui!("Labels", "legend", "")

            set_ui!("Axis-General", "plot_size",(400, 400))
            set_ui!("Axis-General", "font_size", 18)
            set_ui!("Axis-General", "label_size", 18)
            set_ui!("Axis-General", "ticklabel_size", 16)
            set_ui!("Axis-General", "legend_pos", :rt)
            set_ui!("X-Axis", "padding", 0.0)

            set_ui!("Plot-Style", "linewidth", 4.0)
            set_ui!("Plot-Style", "dashed_lines", true)
            set_ui!("Plot-Style", "lineStyles", [:dash, :dot, (:dash, :dense), (:dot, :dense)])
            set_ui!("Various", "save_formats", ["pdf", "svg"])
            
            # THE FIX: Presets now cleanly route the offsets directly into the Axis scopes!
            set_ui!("X-Axis", "label_offset", 5.)
            set_ui!("Y-Axis", "label_offset", 5.)
            set_ui!("Z-Axis", "label_offset", 5.)
            
        elseif preset == :heatmap
            scene_opt["Plot-Type_Selection"] = "Heatmap"
            set_ui!("X-Axis", "label_offset", 10.0)
            set_ui!("Y-Axis", "label_offset", 10.0)
            set_ui!("Plot-Style", "bottom_margin", 20)
            set_ui!("Axis-General", "legend_pos", :td)
            
        elseif preset == :compact3d
            set_ui!("X-Axis", "label_offset", 5.0)
            set_ui!("Y-Axis", "label_offset", 5.0)
            set_ui!("Z-Axis", "label_offset", 15.0)
            set_ui!("Axis-General", "legend_pos", :rt)

        elseif preset == :nolabels
            for key = keys(master_tmp["Labels"])
                set_ui!("Labels",key,"")
            end
        elseif preset == :darkmode
            set_ui!("Plot-Style", "colors", [:cyan, :magenta, :yellow, :white])
        else
            @warn "Unknown plot preset ignored: $preset"
        end
    end

    GLOBAL_UI_OVERWRITE[] = ui_over
    GLOBAL_SCENE_OPTIONS[] = scene_opt
    GLOBAL_VAR_OVERWRITE[] = Any[:menu, :slider, :slider, :slider, :slider]
    @info "Successfully applied plot presets: $(join(preset_list, " + "))"
end

function set_plot_presets!()
    GLOBAL_UI_OVERWRITE[] = Dict{String, Any}()
    GLOBAL_SCENE_OPTIONS[] = Dict{String, Any}()
    GLOBAL_VAR_OVERWRITE[] = Any[:menu, :slider, :slider, :slider, :slider]
    @info "Plot presets cleared. Reverted to default settings."
    return
end