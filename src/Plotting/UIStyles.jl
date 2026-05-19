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
function create_master_ui_observables()
    master = NestedObsDict()
    make_obs(v) = (v isa Tuple || v isa AbstractVector) ? Observable{Any}(v) : Observable(v)
    obs_dict(d) = Dict{String, Observable}(k => make_obs(v) for (k,v) in d)
    
    # 1. Universal Scopes
    master["Axis-General"] = obs_dict(Dict(
        "figsize"        => (1280, 800), 
        "font_size"      => 24, 
        "title_size"     => 26, 
        "label_size"     => 24, 
        "ticklabel_size" => 22,
        "legend_pos"   => :td,
        "sort_legend"  => true,
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
        "mode"       => "lines", # Options: "lines", "scatter", "scatterlines", "polygon"
        "close_loop" => false,   # Automatically connects the last point to the first
        "points"     => Any[],   # e.g., [(0.1, 0.1), (0.5, 0.9), (0.9, 0.1)]
        "color"      => :red,
        "linewidth"  => 3.0,
        "linestyle"  => :dash,
        "markersize" => 15.0
    ))  
    master["Various"] = obs_dict(Dict(
        "save_formats"         => ["png"], 
        "create_savefolder"    => false,      # <-- ADDED (Prevents export crash)
        "comp_names"           => ("default",), # <-- ADDED
        "animation_duration_s" => 10.0, 
        "animation_fps"        => 30, 
        "remove_outliers"      => false, 
        "mark_outliers"        => false, 
        "outlier_threshold"    => 1.5, 
        "track_max"            => false, 
        "track_min"            => false,
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
# --- 3. PLOT-SPECIFIC STYLES ---
    master["Style-Lines"] = obs_dict(Dict(
        "colors"       => [:red, :blue, :green, :orange, :purple],
        "lineStyles"   => [:solid, (:dash, :dense), (:dot, :dense)],
        "markers"      => [:circle, :rect, :utriangle, :dtriangle, :cross],
        "linewidth"    => 5.0,
        "markersize"   => 15.0,
        "xlabel_offset" => 15.0, # <-- SHRUNK
        "ylabel_offset" => 15.0, # <-- SHRUNK
        "show_lines"   => true,
        "show_scatter" => false,
        "dashed_lines" => false,
        "reference"    => [],
    ))
    
    master["Style-Heatmap"] = obs_dict(Dict(
        "colorrange"    => [],
        "colormap"      => :viridis,
        "bottom_margin" => 60,
        "xlabel_offset" => 15.0, # <-- SHRUNK
        "ylabel_offset" => 15.0, # <-- SHRUNK
    ))
    
    master["Style-Contour"] = obs_dict(Dict(
        "colors"        => [:red, :blue, :green, :orange, :purple],
        "levels"        => 15,
        "linewidth"     => 2.0,
        "bottom_margin" => 60,
        "xlabel_offset" => 15.0, # <-- SHRUNK
        "ylabel_offset" => 15.0, # <-- SHRUNK
    ))
    
    master["Style-Contourf"] = obs_dict(Dict(
        "colorrange"    => [],
        "base_method_idx" => 1,
        "colors"        => [:red, :blue, :green, :orange, :purple],
        "linewidth"     => 2.0,
        "colormap"      => :viridis,
        "levels"        => 15,
        "bottom_margin" => 60,
        "xlabel_offset" => 15.0, # <-- SHRUNK
        "ylabel_offset" => 15.0, # <-- SHRUNK
    ))

    master["Style-Contour3D"] = obs_dict(Dict(
        "colors"        => [:red, :blue, :green, :orange, :purple],
        "levels"        => 15,
        "linewidth"     => 2.0,
        "xlabel_offset" => 15.0, # <-- SHRUNK
        "ylabel_offset" => 15.0, # <-- SHRUNK
        "zlabel_offset" => 20.0, # <-- SHRUNK
    ))

    master["Style-Surface"] = obs_dict(Dict(
        "colorrange"    => [],
        "colormap"      => :viridis,
        "xlabel_offset" => 15.0, # <-- SHRUNK
        "ylabel_offset" => 15.0, # <-- SHRUNK
        "zlabel_offset" => 20.0, # <-- SHRUNK
    ))
    
    master["Style-Volume"] = obs_dict(Dict(
        "colorrange"    => [],
        "colormap"      => :viridis,
        "xlabel_offset" => 15.0, # <-- SHRUNK
        "ylabel_offset" => 15.0, # <-- SHRUNK
        "zlabel_offset" => 20.0, # <-- SHRUNK
    ))

    master["Style-Scatter2D"] = obs_dict(Dict(
        "colorrange"    => [],
        "colormap"      => :viridis,
        "colors"        => [:red, :blue], 
        "markers"       => [:circle, :rect], 
        "markersize"    => 15.0, 
        "bottom_margin" => 60, 
        "xlabel_offset" => 15.0, # <-- SHRUNK
        "ylabel_offset" => 15.0  # <-- SHRUNK
    ))
    
    master["Style-Scatter3D"] = obs_dict(Dict(
        "colorrange"    => [],
        "colormap"      => :viridis,
        "colors"        => [:red, :blue], 
        "markers"       => [:circle, :rect], 
        "markersize"    => 15.0, 
        "xlabel_offset" => 15.0, # <-- SHRUNK
        "ylabel_offset" => 15.0, # <-- SHRUNK
        "zlabel_offset" => 20.0  # <-- SHRUNK
    ))
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
    ui["HUD"]          = master["HUD"]
    
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

"""
    set_plot_presets!(presets::Union{Symbol, Vector{Symbol}, Nothing})

Configures the Global UI and Scene Options based on predefined templates.
Pass `nothing` to clear all overrides. Pass an array of symbols to stack multiple presets 
(e.g., `[:convergence, :publication]`). Presets applied later in the array overwrite earlier ones.
"""
function set_plot_presets!(presets::Union{Symbol, Vector{Symbol}})
    # 2. Convert single symbol to vector for unified processing
    preset_list = presets isa Symbol ? [presets] : presets

    # 3. Initialize fresh dictionaries
    ui_over = Dict{String, Any}()
    scene_opt = Dict{String, Any}()

    # Helper to safely dig into nested UI overrides
    function set_ui!(scope, key, val)
        if !haskey(ui_over, scope); ui_over[scope] = Dict{String, Any}(); end
        ui_over[scope][key] = val
    end

    # 4. Apply Presets in order
    for preset in preset_list
        if preset == :convergence
            # Set the exact axes for a convergence plot
            scene_opt["X-Axis_Selection"]    = "Ns__1"
            scene_opt["U-Axis_Selection"]    = "relative_l2error"
            scene_opt["Plot-Type_Selection"] = "Lines"
            scene_opt["t_Value"]      = 10. ^10
            
            # Force log scales for 1D plotting[cite: 13]
            set_ui!("X-Axis", "logscale", true)
            set_ui!("Y-Axis", "logscale", true)
            set_ui!("X-Axis", "padding", 0.)
            
            # Optional QoL: Set default labels
            set_ui!("Labels", "xlabel", "Number of Cells (N)")
            set_ui!("Labels", "ylabel", "Relative L2 Error")

        elseif preset == :publication
            set_ui!("Labels", "title", "")
            set_ui!("Labels", "legend", "")

            # Apply compact, high-visibility styling suitable for papers
            set_ui!("Axis-General", "figsize", (800, 600))
            set_ui!("Axis-General", "font_size", 18)
            set_ui!("Axis-General", "label_size", 18)
            set_ui!("Axis-General", "ticklabel_size", 16)
            set_ui!("Axis-General", "legend_pos", :rt)
            set_ui!("X-Axis", "padding", 0.0)

            set_ui!("Plot-Style", "linewidth", 4.0)
            set_ui!("Plot-Style", "dashed_lines", true)
            set_ui!("Plot-Style", "lineStyles", [:dash, :dot, (:dash, :dense), (:dot, :dense)])
            set_ui!("Various", "save_formats", ["pdf", "svg"])
            
            # THE FIX: Universally suck in all axis margins for publication!
            set_ui!("Plot-Style", "xlabel_offset", 15.0)
            set_ui!("Plot-Style", "ylabel_offset", 15.0)
            set_ui!("Plot-Style", "zlabel_offset", 20.0)
            
        elseif preset == :heatmap
            scene_opt["Plot-Type_Selection"] = "Heatmap"
            set_ui!("Plot-Style", "xlabel_offset", 10.0)
            set_ui!("Plot-Style", "ylabel_offset", 10.0)
            set_ui!("Plot-Style", "bottom_margin", 20)
            set_ui!("Axis-General", "legend_pos", :td)
            
        elseif preset == :compact3d
            set_ui!("Plot-Style", "xlabel_offset", 5.0)
            set_ui!("Plot-Style", "ylabel_offset", 5.0)
            set_ui!("Plot-Style", "zlabel_offset", 15.0)
            set_ui!("Axis-General", "legend_pos", :rt)
            
        elseif preset == :darkmode
            # Example of how easily you can extend this!
            set_ui!("Plot-Style", "colors", [:cyan, :magenta, :yellow, :white])
            
        else
            @warn "Unknown plot preset ignored: $preset"
        end
    end

    # 5. Push to Globals
    GLOBAL_UI_OVERWRITE[] = ui_over
    GLOBAL_SCENE_OPTIONS[] = scene_opt
    GLOBAL_VAR_OVERWRITE[] = Any[:menu, :slider, :slider, :slider, :slider] # Default widget types
    
    @info "Successfully applied plot presets: $(join(preset_list, " + "))"
end
function set_plot_presets!()
    GLOBAL_UI_OVERWRITE[] = Dict{String, Any}()
    GLOBAL_SCENE_OPTIONS[] = Dict{String, Any}()
    GLOBAL_VAR_OVERWRITE[] = Any[:menu, :slider, :slider, :slider, :slider]
    @info "Plot presets cleared. Reverted to default settings."
    return
end
