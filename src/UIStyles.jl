# ==============================================================================
# --- UIStyles.jl ---
# ==============================================================================

const LEGEND_SUPPORTED_PLOTS = (:lines, :scattercolors, :scatterlines, :contour, :contourf, :contour_surface)
const COLORBAR_SUPPORTED_PLOTS = (:heatmap, :scatter1d, :scatter2d, :scatter2d_surface, :contourf, :contour3d, :scatter3d, :surface, :volume, :contour_cmap, :lines2d, :lines3d)
const REPLOT_OPTIONS = (:use_color_map, :line_direction, :base_method_idx, :log_scale, :dashed_lines, :levels, :rasterize)

is_surface(T::Symbol) = contains(String(T),"surface")

# --- 1. ROUTING & DIMENSIONALITY ---
const PLOT_DIM_MAP = Dict(
    :lines              => 1,
    :scatter1d          => 1,
    :scatterlines       => 1,
    :scattercolors      => 1,
    :lines2d            => 2,
    :heatmap            => 2,
    :contour            => 2,
    :contour_cmap       => 2, 
    :contourf           => 2,
    :scatter2d          => 2,
    :scatter2d_surface  => 2,
    :surface            => 2,
    :contour_surface    => 2,
    :contour3d          => 3,
    :lines3d            => 3,
    :scatter3d          => 3,
    :volume             => 3,
)

const EULERIAN_PLOT_STYLE_OPTIONS = Dict{Symbol, Vector{Any}}(
    :lines   => Any[("1D", :lines), ("2D", :lines2d), ("3D", :lines3d)],
    :scatter => Any[("1D", :scatter1d), ("Lines", :scatterlines), ("Colors", :scattercolors), ("2D", :scatter2d), ("3D", :scatter3d)],
    :contour => Any[("Lines", :contour), ("Colormap", :contour_cmap), ("Filled", :contourf), ("Surface", :contour_surface), ("3D", :contour3d)],
    :heatmap => Any[("Flat", :heatmap), ("Surface", :surface)],
    :volume  => Any[("3D Cloud", :volume)]
)

const LAGRANGIAN_PLOT_STYLE_OPTIONS = Dict{Symbol, Vector{Any}}(
    :scatter => Any[("1D", :scatter1d), ("2D", :scatter2d), ("2D (Surface)", :scatter2d_surface), ("3D", :scatter3d), ("Lines", :scatterlines), ("Colors", :scattercolors)] 
)

const STYLE_DEPENDENCIES = Dict{Symbol, Vector{Symbol}}(
    :lines        => [:colors, :line_width, :line_styles, :dashed_lines, :reference],
    :scatter1d    => [:color_map, :color_range, :markers, :marker_size, :bottom_margin, :rasterize, :method_index],
    :scattercolors=> [:colors, :markers, :marker_size],
    :scatterlines => [:colors, :line_width, :line_styles, :dashed_lines, :markers, :marker_size, :reference],
    
    :lines2d      => [:color_map, :color_range, :line_width, :line_direction, :bottom_margin, :method_index],
    :lines3d      => [:color_map, :color_range, :line_width, :line_direction, :bottom_margin, :method_index],
    
    :scatter2d    => [:color_map, :color_range, :markers, :marker_size, :bottom_margin, :rasterize, :method_index],
    :scatter2d_surface => [:color_map, :color_range, :markers, :marker_size, :rasterize, :method_index],
    :scatter3d    => [:color_map, :color_range, :markers, :marker_size, :rasterize, :method_index],
    
    :contour      => [:colors, :levels, :line_width, :labels],
    :contour_cmap => [:color_map, :color_range, :levels, :line_width, :labels, :bottom_margin, :method_index],
    :contourf     => [:color_map, :color_range, :levels, :method_index, :rasterize, :bottom_margin],
    :contour_surface => [:colors, :levels, :line_width, :labels],
    :heatmap      => [:color_map, :color_range, :rasterize, :bottom_margin, :method_index],
    :surface      => [:color_map, :color_range, :rasterize, :method_index],
    :volume       => [:color_map, :color_range, :rasterize, :method_index],
    :contour3d    => [:colors, :levels, :line_width, :method_index]
)

# --- TIER 1: LAYOUT OPTIONS ---
function get_base_layout_options()
    return Dict{Symbol, Any}(
        :Base_Plot_Selection       => :lines,
        :Plot_Style_Selection      => :one_d,
        :Compare_Target_Selection  => :None, 
        :Compare_Columns_Selection => 2,     
        :Compare_Link_Selection    => :fully_coupled,
        :Legend_Base_Selection     => :right,
        :Legend_Add_Selection      => :detached,
        :Plot_Width_Selection      => 600,
        :Plot_Height_Selection     => 400,
        :Anim_Target_Selection     => :None
    )
end

# --- 2. MASTER UI TEMPLATES ---
"""
    create_master_ui_dict()

Creates the definitive Master Dictionary containing EVERY possible UI option natively.
"""
function create_master_ui_dict()
    master = Dict{Symbol, Dict{Symbol, Any}}()
    
    # 1. Universal Scopes
    master[:Axis_General] = Dict{Symbol, Any}(
        :font_size      => 24, 
        :title_size     => 26, 
        :label_size     => 24, 
        :ticklabel_size => 22,
        :sort_legend    => true,
    )
    
    master[:Labels] = Dict{Symbol, Any}(
        :title          => "default", 
        :x_label        => "default", 
        :y_label        => "default", 
        :z_label        => "default", 
        :colorbar_label => "default", 
        :legend         => "Methods",
        :comp_names     => ("default",)
    )
    
    master[:HUD] = Dict{Symbol, Any}(
        :visible     => false,
        :mode        => "lines", 
        :close_loop  => false,   
        :points      => Any[],   
        :color       => :red,
        :line_width  => 3.0,
        :line_style  => :dash,
        :marker_size => 15.0
    )  
    
    master[:Various] = Dict{Symbol, Any}(
        :save_formats         => ["png"], 
        :create_savefolder    => false,
        :animation_time       => 10.0, 
        :animation_FPS        => 30, 
        :remove_outliers      => false, 
        :mark_outliers        => false, 
        :outlier_threshold    => 1.5, 
        :track_max            => false, 
        :track_min            => false,
    )
    
    # 2. Universal Axis Templates
    axis_dict(pad, default_offset=15.0) = Dict{Symbol, Any}(
        :grid_visibility       => true, 
        :tick_label_visibility => true, 
        :tick_count        => 0, 
        :tick_format       => "default", 
        :scale_offset      => 0.0, 
        :log_scale         => false, 
        :padding           => pad,
        :label_offset      => default_offset,
        :lims              => Any[]
    )

    master[:X_Axis_1D] = axis_dict(0.05, 15.0)
    master[:Y_Axis_1D] = axis_dict(0.05, 15.0)
    
    master[:X_Axis_ND] = axis_dict(0.0, 15.0)
    master[:Y_Axis_ND] = axis_dict(0.0, 15.0)
    master[:Z_Axis_3D] = axis_dict(0.05, 20.0) 
    
    master[:Plot_Style] = Dict{Symbol, Any}(
        :colors          => [(:black,.8), :blue, :green, :orange, :purple, :yellow],
        :color_map       => :viridis,
        :color_range     => Any[],
        :line_width      => 3.0,
        :line_direction  => "Horizontal",
        :line_styles     => [:solid, :dash, :dot, (:dash, :dense), (:dot, :dense)],
        :markers         => [:circle, :rect, :utriangle, :dtriangle, :cross],
        :marker_size     => 15.0,
        :levels          => 15,
        :method_index    => 1,
        :bottom_margin   => 60,
        :rasterize       => 2,
        :show_lines      => true,
        :show_scatter    => false,
        :dashed_lines    => false,
        :labels          => false,
        :reference       => Any[],
    )
    
    return master
end

const MASTER_UI_DICT = create_master_ui_dict()

function switch_ui_plot_type!(plot_type::Symbol)
    
    master = MASTER_UI_DICT
    ui = manager.ui
    empty!(ui)
    
    dim = PLOT_DIM_MAP[plot_type]
    
    # Deepcopy safely instantiates independent values into manager.ui
    ui[:Axis_General] = deepcopy(master[:Axis_General])
    ui[:Labels]       = deepcopy(master[:Labels])
    ui[:Various]      = deepcopy(master[:Various])
    ui[:HUD]          = deepcopy(master[:HUD])
    ui[:Plot_Style]   = deepcopy(master[:Plot_Style])
    
    if dim == 1
        ui[:X_Axis] = deepcopy(master[:X_Axis_1D])
        ui[:Y_Axis] = deepcopy(master[:Y_Axis_1D])
    elseif dim == 2 && !is_surface(plot_type)
        ui[:X_Axis] = deepcopy(master[:X_Axis_ND])
        ui[:Y_Axis] = deepcopy(master[:Y_Axis_ND])
    elseif dim == 3 || is_surface(plot_type)
        ui[:X_Axis] = deepcopy(master[:X_Axis_ND])
        ui[:Y_Axis] = deepcopy(master[:Y_Axis_ND])
        ui[:Z_Axis] = deepcopy(master[:Z_Axis_3D])
    end
    
    if haskey(manager.triggers, :UI)
        manager.triggers[:UI][] += 1
    end
end

function set_plot_presets!(presets::Union{Symbol, Vector{Symbol}})
    
    preset_list = presets isa Symbol ? [presets] : presets
    ui_over = Dict{Symbol, Any}()
    
    scene_opt = Dict{Symbol, Any}()
    layout_opt = get_base_layout_options()

    function set_ui!(scope, key, val)
        if !haskey(ui_over, scope); ui_over[scope] = Dict{Symbol, Any}(); end
        ui_over[scope][key] = val
    end

    for preset in preset_list
        if preset == :convergence
            scene_opt[:X_Axis_Selection]      = :Ns__1
            scene_opt[:U_Axis_Selection]      = :relative_l2error
            layout_opt[:Base_Plot_Selection]  = :lines
            layout_opt[:Plot_Style_Selection] = :lines 
            scene_opt[:t_Value]               = 10.0^10
            
            set_ui!(:X_Axis, :log_scale, true)
            set_ui!(:Y_Axis, :log_scale, true)
            set_ui!(:X_Axis, :padding, 0.0)
            
            set_ui!(:Labels, :x_label, "Number of Cells (N)")
            set_ui!(:Labels, :y_label, "Relative L2 Error")

        elseif preset == :publication
            set_ui!(:Labels, :title, "")
            set_ui!(:Labels, :legend, "")

            set_ui!(:Axis_General, :font_size, 18)
            set_ui!(:Axis_General, :label_size, 18)
            set_ui!(:Axis_General, :title_size, 22)
            set_ui!(:Axis_General, :ticklabel_size, 16)
            set_ui!(:X_Axis, :padding, 0.0)

            set_ui!(:Plot_Style, :line_width, 3.6)
            set_ui!(:Plot_Style, :dashed_lines, false)
            set_ui!(:Plot_Style, :line_styles, [:solid,:dash, :dot, (:dash, :dense), (:dot, :dense)])
            set_ui!(:Various, :save_formats, ["pdf", "svg"])
            
            set_ui!(:X_Axis, :label_offset, 5.)
            set_ui!(:Y_Axis, :label_offset, 5.)
            set_ui!(:Z_Axis, :label_offset, 5.)

            layout_opt[:Legend_Base_Selection] = :top
            layout_opt[:Legend_Add_Selection]  = :detached
            layout_opt[:Plot_Width_Selection]  = 500
            layout_opt[:Plot_Height_Selection] = 400
            
        elseif preset == :heatmap
            layout_opt[:Base_Plot_Selection]  = :heatmap
            layout_opt[:Plot_Style_Selection] = :heatmap 
            set_ui!(:X_Axis, :label_offset, 10.0)
            set_ui!(:Y_Axis, :label_offset, 10.0)
            set_ui!(:Plot_Style, :bottom_margin, 20)
        elseif preset == :component
            layout_opt[:Compare_Target_Selection]  = :Component
            layout_opt[:Compare_Columns_Selection] = 1
            layout_opt[:Compare_Link_Selection]    = :decoupled
            set_ui!(:Labels, :title, "default")
            set_ui!(:Labels, :y_label, "")
            
        elseif preset == :compact3d
            set_ui!(:X_Axis, :label_offset, 5.0)
            set_ui!(:Y_Axis, :label_offset, 5.0)
            set_ui!(:Z_Axis, :label_offset, 15.0)
            set_ui!(:Axis_General, :legend_pos, :td)

        elseif preset == :nolabels
            for key in keys(MASTER_UI_DICT[:Labels])
                set_ui!(:Labels, key, "")
            end
        elseif preset == :darkmode
            set_ui!(:Plot_Style, :colors, [:cyan, :magenta, :yellow, :white])
        else
            @warn "Unknown plot preset ignored: $preset"
        end
    end

    manager.staged[:UI]     = ui_over
    manager.staged[:Scene]  = scene_opt
    manager.staged[:Layout] = layout_opt
    @info "Successfully applied plot presets: $(join(preset_list, " + "))"
end

function set_plot_presets!()
    
    manager.staged[:UI]     = Dict{Symbol, Any}()
    manager.staged[:Scene]  = Dict{Symbol, Any}()
    manager.staged[:Layout] = Dict{Symbol, Any}()
    manager.staged[:Camera] = Dict{Symbol, Any}()
    @info "Plot presets cleared. Reverted to default settings."
    return
end

# ==============================================================================
# --- MODULAR UI MODIFIERS ---
# ==============================================================================
function apply_ui_style!(prim_key::Union{Symbol, AbstractString}, prim::Any, ui_app::Dict, color::Any)
    k = Symbol(prim_key)
    deps = get(STYLE_DEPENDENCIES, k, Symbol[])
    
    # 1. Color Management
    if :colors in deps
        prim.color[] = color
    elseif :color_map in deps
        prim.colormap[] = ui_app[:color_map]
    end
    
    # 2. Geometry Attributes
    if :line_width in deps
        prim.linewidth[] = ui_app[:line_width]
    end
    
    if :marker_size in deps
        prim.markersize[] = ui_app[:marker_size]
    end
end