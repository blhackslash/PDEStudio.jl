const UIType = Union{Symbol,MethodDict}
const LEGEND_SUPPORTED_PLOTS = (:lines, :scattercolors, :scatterlines, :contour, :contourf, :contour3d)
const COLORBAR_SUPPORTED_PLOTS = (:heatmap, :scatter1d, :scatter2d, :scatter2d_surface, :contourf, :scatter3d, :surface, :volume, :contour_cmap, :lines2d, :lines3d)
# --- 1. ROUTING & DIMENSIONALITY ---
const PLOT_DIM_MAP = Dict(
    :lines        => 1,
    :scatter1d    => 1,
    :scatterlines => 1,
    :scattercolors=> 1,
    :lines2d      => 2,
    :heatmap      => 2,
    :contour      => 2,
    :contour_cmap => 2, 
    :contourf     => 2,
    :scatter2d    => 2,
    :scatter2d_surface => 2,
    :surface      => 2,
    :lines3d      => 3,
    :contour3d    => 3,
    :scatter3d    => 3,
    :volume       => 3
)

const EULERIAN_PLOT_STYLE_OPTIONS = Dict{String, Vector{String}}(
    "Lines"   => ["1D", "2D", "3D"],
    "Scatter" => ["1D", "Lines", "Colors"],
    "Contour" => ["Lines", "Colormap", "Filled", "3D"],
    "Heatmap" => ["Flat", "Surface"],
    "Volume"  => ["3D Cloud"]
)

const LAGRANGIAN_PLOT_STYLE_OPTIONS = Dict{String, Vector{String}}(
    "Scatter" => ["1D", "2D","2D (Surface)", "3D", "Lines", "Colors"] # Maps "Lines" to :scatterlines
)

const PLOT_ROUTING_MATRIX = Dict{Tuple{String, String}, Symbol}(
    # Eulerian
    ("Lines", "1D")           => :lines,
    ("Lines", "2D")           => :lines2d,
    ("Scatter", "2D (Surface)") => :scatter2d_surface,
    ("Lines", "3D")           => :lines3d,
    ("Contour", "Lines")      => :contour,
    ("Contour", "Colormap")   => :contour_cmap, 
    ("Contour", "Filled")     => :contourf,
    ("Contour", "3D")         => :contour3d,
    ("Heatmap", "Flat")       => :heatmap,
    ("Heatmap", "Surface")    => :surface,
    ("Volume", "3D Cloud")    => :volume,
    
    # Lagrangian
    ("Scatter", "1D")         => :scatter1d,
    ("Scatter", "2D")         => :scatter2d,
    ("Scatter", "3D")         => :scatter3d,
    ("Scatter", "Lines")      => :scatterlines,
    ("Scatter", "Colors")     => :scattercolors,
)

const STYLE_DEPENDENCIES = Dict{Symbol, Vector{String}}(
    :lines        => ["colors", "line_width", "line_styles", "dashed_lines", "reference"],
    :scatter1d    => ["color_map", "color_range", "markers", "marker_size", "bottom_margin", "rasterize", "method_index"],
    :scattercolors=> ["colors", "markers", "marker_size"],
    :scatterlines => ["colors", "line_width", "line_styles", "dashed_lines", "markers", "marker_size", "reference"],
    
    :lines2d      => ["color_map", "color_range", "line_width", "line_direction", "bottom_margin", "method_index"],
    :lines3d      => ["color_map", "color_range", "line_width", "line_direction", "bottom_margin", "method_index"],
    
    :scatter2d    => ["color_map", "color_range", "markers", "marker_size", "bottom_margin", "rasterize", "method_index"],
    :scatter2d_surface => ["color_map", "color_range", "markers", "marker_size", "rasterize", "method_index"],
    :scatter3d    => ["color_map", "color_range", "markers", "marker_size", "rasterize", "method_index"],
    
    :contour      => ["colors", "levels", "line_width", "labels"],
    :contour_cmap => ["color_map", "color_range", "levels", "line_width", "labels", "bottom_margin", "method_index"],
    :contourf     => ["color_map", "color_range", "levels", "method_index", "rasterize", "bottom_margin"],
    :heatmap      => ["color_map", "color_range", "rasterize", "bottom_margin", "method_index"],
    :surface      => ["color_map", "color_range", "rasterize", "method_index"],
    :volume       => ["color_map", "color_range", "rasterize", "method_index"],
    :contour3d    => ["colors", "levels", "line_width", "method_index"]
)

# --- TIER 1: LAYOUT OPTIONS ---
function get_base_layout_options()
    return Dict{String, Any}(
        "Base_Plot_Selection"       => "Lines",  
        "Plot_Style_Selection"      => "1D",
        "Compare_Target_Selection"  => "None", 
        "Compare_Columns_Selection" => "2",     
        "Compare_Link_Selection"    => "Fully Coupled",
        "Legend_Base_Selection"     => "right",
        "Legend_Add_Selection"      => "detached",
        "Plot_Width_Selection"      => "600",
        "Plot_Height_Selection"     => "400",
        "Anim_Target_Selection"     => "None"
    )
end

# --- 2. OBSERVABLE TEMPLATES ---
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
        "font_size"      => 24, 
        "title_size"     => 26, 
        "label_size"     => 24, 
        "ticklabel_size" => 22,
        "sort_legend"    => true,
    ))
    
    master["Labels"] = obs_dict(Dict(
        "title"          => "default", 
        "x_label"        => "default", 
        "y_label"        => "default", 
        "z_label"        => "default", 
        "colorbar_label" => "default", 
        "legend"         => "Methods",
        "comp_names"     => ("default",)
    ))
    
    master["HUD"] = obs_dict(Dict(
        "visible"     => false,
        "mode"        => "lines", 
        "close_loop"  => false,   
        "points"      => Any[],   
        "color"       => :red,
        "line_width"  => 3.0,
        "line_style"  => :dash,
        "marker_size" => 15.0
    ))  
    
    master["Various"] = obs_dict(Dict(
        "save_formats"         => ["png"], 
        "create_savefolder"    => false,
        "animation_time"       => 10.0, 
        "animation_FPS"        => 30, 
        "remove_outliers"      => false, 
        "mark_outliers"        => false, 
        "outlier_threshold"    => 1.5, 
        "track_max"            => false, 
        "track_min"            => false,
    ))
    
    # 2. Universal Axis Templates
    axis_dict(pad, default_offset=15.0) = Dict{String, Any}(
        "grid_visibility"       => true, 
        "tick_label_visibility" => true, 
        "tick_count"        => 0, 
        "tick_format"       => "default", 
        "scale_offset"      => 0.0, 
        "log_scale"         => false, 
        "padding"           => pad,
        "label_offset"      => default_offset,
        "lims"              => Any[]
    )

    master["X-Axis-1D"] = obs_dict(axis_dict(0.05, 15.0))
    master["Y-Axis-1D"] = obs_dict(axis_dict(0.05, 15.0))
    
    master["X-Axis-ND"] = obs_dict(axis_dict(0.0, 15.0))
    master["Y-Axis-ND"] = obs_dict(axis_dict(0.0, 15.0))
    master["Z-Axis-3D"] = obs_dict(axis_dict(0.05, 20.0)) 
    
    # 3. THE FIX: The Single, Flat Plot-Style Dictionary!
    master["Plot-Style"] = obs_dict(Dict(
        "colors"          => [(:black,.8), :blue, :green, :orange, :purple, :yellow],
        "color_map"       => :viridis,
        "color_range"     => Any[],
        "line_width"      => 3.0,
        "line_direction"  => "Horizontal",
        "line_styles"     => [:solid, :dash, :dot, (:dash, :dense), (:dot, :dense)],
        "markers"         => [:circle, :rect, :utriangle, :dtriangle, :cross],
        "marker_size"     => 15.0,
        "levels"          => 15,
        "method_index"    => 1,
        "bottom_margin"   => 60,
        "rasterize"       => 2,
        "show_lines"      => true,
        "show_scatter"    => false,
        "dashed_lines"    => false,
        "labels"          => false,
        "reference"       => Any[],
    ))
    
    return master
end

const MASTER_UI_DICT = create_master_ui_observables()

function switch_ui_plot_type!(manager::PlotManager, plot_type::Symbol)
    master = manager.state["Master_UI_Ref"][]
    ui = manager.ui
    empty!(ui)
    
    dim = PLOT_DIM_MAP[plot_type]
    
    ui["Axis-General"] = master["Axis-General"]
    ui["Labels"]       = master["Labels"]
    ui["Various"]      = master["Various"]
    ui["HUD"]          = master["HUD"]
    
    # THE FIX: Always use the shared, flat Plot-Style!
    ui["Plot-Style"]   = master["Plot-Style"]
    
    if dim == 1
        ui["X-Axis"] = master["X-Axis-1D"]
        ui["Y-Axis"] = master["Y-Axis-1D"]
    elseif dim == 2 && !(plot_type==:surface || plot_type==:scatter2d_surface)
        ui["X-Axis"] = master["X-Axis-ND"]
        ui["Y-Axis"] = master["Y-Axis-ND"]
    elseif dim == 3 || plot_type==:surface || plot_type==:scatter2d_surface
        ui["X-Axis"] = master["X-Axis-ND"]
        ui["Y-Axis"] = master["Y-Axis-ND"]
        ui["Z-Axis"] = master["Z-Axis-3D"]
    end
    
    if haskey(manager.triggers, "UI_Update")
        notify(manager.triggers["UI_Update"])
    end
end

function set_plot_presets!(presets::Union{Symbol, Vector{Symbol}})
    preset_list = presets isa Symbol ? [presets] : presets
    ui_over = Dict{String, Any}()
    
    scene_opt = Dict{String, Any}()
    layout_opt = get_base_layout_options() # THE FIX: Bring Layout options back!

    function set_ui!(scope, key, val)
        if !haskey(ui_over, scope); ui_over[scope] = Dict{String, Any}(); end
        ui_over[scope][key] = val
    end

    for preset in preset_list
        if preset == :convergence
            scene_opt["X-Axis_Selection"]      = "Ns__1"
            scene_opt["U-Axis_Selection"]      = "relative_l2error"
            layout_opt["Base_Plot_Selection"]  = "Lines"
            layout_opt["Plot_Style_Selection"] = "1D"
            scene_opt["t_Value"]              = 10.0^10
            
            set_ui!("X-Axis", "log_scale", true)
            set_ui!("Y-Axis", "log_scale", true)
            set_ui!("X-Axis", "padding", 0.0)
            
            set_ui!("Labels", "x_label", "Number of Cells (N)")
            set_ui!("Labels", "y_label", "Relative L2 Error")

        elseif preset == :publication
            set_ui!("Labels", "title", "")
            set_ui!("Labels", "legend", "")

            set_ui!("Axis-General", "font_size", 18)
            set_ui!("Axis-General", "label_size", 18)
            set_ui!("Axis-General", "title_size", 22)
            set_ui!("Axis-General", "ticklabel_size", 16)
            set_ui!("X-Axis", "padding", 0.0)

            set_ui!("Plot-Style", "line_width", 3.6)
            set_ui!("Plot-Style", "dashed_lines", false)
            set_ui!("Plot-Style", "line_styles", [:solid,:dash, :dot, (:dash, :dense), (:dot, :dense)])
            set_ui!("Various", "save_formats", ["pdf", "svg"])
            
            set_ui!("X-Axis", "label_offset", 5.)
            set_ui!("Y-Axis", "label_offset", 5.)
            set_ui!("Z-Axis", "label_offset", 5.)

            layout_opt["Legend_Base_Selection"] = "top"      # THE FIX: Move to Layout
            layout_opt["Legend_Add_Selection"]  = "detached" # THE FIX: Move to Layout
            layout_opt["Plot_Width_Selection"]  = 500        # THE FIX: Move to Layout
            layout_opt["Plot_Height_Selection"] = 400        # THE FIX: Move to Layout
            
        elseif preset == :heatmap
            layout_opt["Base_Plot_Selection"]  = "Heatmap"
            layout_opt["Plot_Style_Selection"] = "Flat"
            set_ui!("X-Axis", "label_offset", 10.0)
            set_ui!("Y-Axis", "label_offset", 10.0)
            set_ui!("Plot-Style", "bottom_margin", 20)
        elseif preset == :component
            layout_opt["Compare_Target_Selection"]  = "Component"
            layout_opt["Compare_Columns_Selection"] = "1"
            layout_opt["Compare_Link_Selection"]    = "Decoupled"
            set_ui!("Labels", "title", "default")
            set_ui!("Labels", "y_label", "")
            
        elseif preset == :compact3d
            set_ui!("X-Axis", "label_offset", 5.0)
            set_ui!("Y-Axis", "label_offset", 5.0)
            set_ui!("Z-Axis", "label_offset", 15.0)
            set_ui!("Axis-General", "legend_pos", :td)

        elseif preset == :nolabels
            # THE FIX: Safely pull the keys from the global master!
            for key in keys(MASTER_UI_DICT["Labels"])
                set_ui!("Labels", key, "")
            end
        elseif preset == :darkmode
            set_ui!("Plot-Style", "colors", [:cyan, :magenta, :yellow, :white])
        else
            @warn "Unknown plot preset ignored: $preset"
        end
    end

    GLOBAL_UI_OVERWRITE[] = ui_over
    GLOBAL_SCENE_OPTIONS[] = scene_opt
    GLOBAL_LAYOUT_OPTIONS[] = layout_opt # THE FIX: Register layout to Global State
    GLOBAL_VAR_OVERWRITE[] = Any[:menu, :slider, :slider, :slider, :slider]
    @info "Successfully applied plot presets: $(join(preset_list, " + "))"
end

function set_plot_presets!()
    GLOBAL_UI_OVERWRITE[] = Dict{String, Any}()
    GLOBAL_SCENE_OPTIONS[] = Dict{String, Any}()
    GLOBAL_LAYOUT_OPTIONS[] = Dict{String, Any}()
    GLOBAL_CAMERA_OPTIONS[] = Dict{String, Any}()
    GLOBAL_VAR_OVERWRITE[] = Any[:menu, :slider, :slider, :slider, :slider]
    @info "Plot presets cleared. Reverted to default settings."
    return
end

# ==============================================================================
# --- MODULAR UI MODIFIERS ---
# ==============================================================================
function apply_ui_style!(prim_key::Union{Symbol, AbstractString}, prim::Any, ui_app::Dict, color::Any)
    k = Symbol(prim_key)
    deps = get(STYLE_DEPENDENCIES, k, String[])
    
    # 1. Color Management
    if "colors" in deps
        prim.color[] = color
    elseif "color_map" in deps
        prim.colormap[] = ui_app["color_map"][]
    end
    
    # 2. Geometry Attributes
    if "line_width" in deps
        prim.linewidth[] = ui_app["line_width"][]
    end
    
    if "marker_size" in deps
        prim.markersize[] = ui_app["marker_size"][]
    end
end