# ==============================================================================
# --- UIStyles.jl ---
# ==============================================================================

const LEGEND_SUPPORTED_PLOTS = (:lines_1d, :scatter_colors, :scatter_lines, :contour, :contour_f, :contour_surface)
const COLORBAR_SUPPORTED_PLOTS = (:heatmap, :scatter_1d, :scatter_2d, :scatter_surface, :contour_f, :contour_3d, :scatter_3d, :surface, :volume, :contour_cmap, :lines_2d, :lines_3d)
const REPLOT_OPTIONS = (:use_color_map, :line_direction, :base_method_idx, :log_scale, :dashed_lines, :levels, :rasterize)
const LAYOUT_OPTIONS = (:base_plot, :plot_style, :compare_target, :compare_columns, :compare_link, :legend_base, :legend_add, :plot_width, :plot_height, :anim_target)
const PLOT_AXIS_OPTIONS = (:x_axis, :y_axis, :z_axis, :u_axis, :component)

# --- SYMBOL / LABEL ROUTING ---
const SYMBOL_TO_LABEL_MAP = Dict{Symbol, String}(
    :hud => "HUD",
    :fps => "FPS",
    :x_axis => "X-Axis",
    :y_axis => "Y-Axis",
    :z_axis => "Z-Axis",
    :u_axis => "U-Axis (Dep)",
    :ui => "UI",
    :none => "-",
    
    # Plot Styles
    :lines_1d => "1D Lines",
    :lines_2d => "2D Lines",
    :lines_3d => "3D Lines",
    :scatter_1d => "1D Scatter",
    :scatter_2d => "2D Scatter",
    :scatter_3d => "3D Scatter",
    :scatter_lines => "Scatter Lines",
    :scatter_colors => "Scatter Colors",
    :scatter_surface => "2D Scatter (Surface)",
    :contour => "Contour Lines",
    :contour_cmap => "Contour Colormap",
    :contour_f => "Contour Filled",
    :contour_surface => "Contour Surface",
    :contour_3d => "3D Contour",
    :heatmap => "Heatmap",
    :surface => "Surface",
    :volume => "3D Cloud (Volume)"
)

function backend_key(s::AbstractString)
    s_clean = replace(strip(s), r"[\s-]+" => "_")
    return Symbol(lowercase(s_clean))
end

function frontend_key(s::Symbol)
    if haskey(SYMBOL_TO_LABEL_MAP, s)
        return SYMBOL_TO_LABEL_MAP[s]
    end
    words = split(String(s), "_")
    return join(map(titlecase, words), " ")
end

"""
    menu_opt(sym::Symbol)

Helper function that uses `frontend_key` to automatically generate 
a formatted Makie dropdown tuple: `("Nice String", :backend_key)`.
"""
menu_opt(sym::Symbol) = (frontend_key(sym), sym)

is_surface(T::Symbol) = contains(String(T),"surface")

# --- 1. ROUTING & DIMENSIONALITY ---
const PLOT_DIM_MAP = Dict(
    :lines_1d           => 1,
    :scatter_1d         => 1,
    :scatter_lines      => 1,
    :scatter_colors     => 1,
    :lines_2d           => 2,
    :heatmap            => 2,
    :contour            => 2,
    :contour_cmap       => 2, 
    :contour_f          => 2,
    :scatter_2d         => 2,
    :scatter_surface    => 2,
    :surface            => 2,
    :contour_surface    => 2,
    :contour_3d         => 3,
    :lines_3d           => 3,
    :scatter_3d         => 3,
    :volume             => 3,
)

const EULERIAN_PLOT_STYLE_OPTIONS = Dict{Symbol, Vector{Any}}(
    :lines   => Any[menu_opt(:lines_1d), menu_opt(:lines_2d), menu_opt(:lines_3d)],
    :scatter => Any[menu_opt(:scatter_1d), menu_opt(:scatter_lines), menu_opt(:scatter_colors), menu_opt(:scatter_2d), menu_opt(:scatter_3d)],
    :contour => Any[menu_opt(:contour), menu_opt(:contour_cmap), menu_opt(:contour_f), menu_opt(:contour_surface), menu_opt(:contour_3d)],
    :heatmap => Any[menu_opt(:heatmap), menu_opt(:surface)],
    :volume  => Any[menu_opt(:volume)]
)

const LAGRANGIAN_PLOT_STYLE_OPTIONS = Dict{Symbol, Vector{Any}}(
    :scatter => Any[menu_opt(:scatter_1d), menu_opt(:scatter_2d), menu_opt(:scatter_surface), menu_opt(:scatter_3d), menu_opt(:scatter_lines), menu_opt(:scatter_colors)] 
)

const STYLE_DEPENDENCIES = Dict{Symbol, Vector{Symbol}}(
    :lines_1d         => [:colors, :line_width, :line_styles, :dashed_lines, :reference],
    :scatter_1d       => [:color_map, :color_range, :markers, :marker_size, :bottom_margin, :rasterize, :method_index],
    :scatter_colors   => [:colors, :markers, :marker_size],
    :scatter_lines    => [:colors, :line_width, :line_styles, :dashed_lines, :markers, :marker_size, :reference],
    
    :lines_2d         => [:color_map, :color_range, :line_width, :line_direction, :bottom_margin, :method_index],
    :lines_3d         => [:color_map, :color_range, :line_width, :line_direction, :bottom_margin, :method_index],
    
    :scatter_2d       => [:color_map, :color_range, :markers, :marker_size, :bottom_margin, :rasterize, :method_index],
    :scatter_surface  => [:color_map, :color_range, :markers, :marker_size, :rasterize, :method_index],
    :scatter_3d       => [:color_map, :color_range, :markers, :marker_size, :rasterize, :method_index],
    
    :contour          => [:colors, :levels, :line_width, :labels],
    :contour_cmap     => [:color_map, :color_range, :levels, :line_width, :labels, :bottom_margin, :method_index],
    :contour_f        => [:color_map, :color_range, :levels, :method_index, :rasterize, :bottom_margin],
    :contour_surface  => [:colors, :levels, :line_width, :labels],
    :heatmap          => [:color_map, :color_range, :rasterize, :bottom_margin, :method_index],
    :surface          => [:color_map, :color_range, :rasterize, :method_index],
    :volume           => [:color_map, :color_range, :rasterize, :method_index],
    :contour_3d       => [:colors, :levels, :line_width, :method_index]
)


# --- 2. MASTER UI TEMPLATES ---
"""
    create_master_ui_dict()

Creates the definitive Master Dictionary containing EVERY possible UI option natively.
"""
function create_master_ui_dict()
    master = Dict{Symbol, Dict{Symbol, Any}}()
    
    # 1. Universal Scopes (LOWERCASE)
    master[:axis_general] = Dict{Symbol, Any}(
        :font_size      => 24, 
        :title_size     => 26, 
        :label_size     => 24, 
        :ticklabel_size => 22,
        :sort_legend    => true,
    )
    
    master[:labels] = Dict{Symbol, Any}(
        :title          => "default", 
        :x_label        => "default", 
        :y_label        => "default", 
        :z_label        => "default", 
        :colorbar_label => "default", 
        :legend         => "Methods",
        :comp_names     => ("default",)
    )
    
    master[:hud] = Dict{Symbol, Any}(
        :visible     => false,
        :mode        => "lines", 
        :close_loop  => false,   
        :points      => Any[],   
        :color       => :red,
        :line_width  => 3.0,
        :line_style  => :dash,
        :marker_size => 15.0
    )  
    
    master[:various] = Dict{Symbol, Any}(
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

    master[:x_axis_1d] = axis_dict(0.05, 15.0)
    master[:y_axis_1d] = axis_dict(0.05, 15.0)
    
    master[:x_axis_nd] = axis_dict(0.0, 15.0)
    master[:y_axis_nd] = axis_dict(0.0, 15.0)
    master[:z_axis_3d] = axis_dict(0.05, 20.0)
    
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
    
    do_reset = get(manager.staged[:UI], :reset, false)
    cached_ui = deepcopy(ui)
    empty!(ui)
    
    dim = PLOT_DIM_MAP[plot_type]
    
    ui[:axis_general] = deepcopy(master[:axis_general])
    ui[:labels]       = deepcopy(master[:labels])
    ui[:various]      = deepcopy(master[:various])
    ui[:hud]          = deepcopy(master[:hud])
    ui[:plot_style]   = deepcopy(master[:plot_style])
    
    if dim == 1
        ui[:x_axis] = deepcopy(master[:x_axis_1d])
        ui[:y_axis] = deepcopy(master[:y_axis_1d])
    elseif dim == 2 && !is_surface(plot_type)
        ui[:x_axis] = deepcopy(master[:x_axis_nd])
        ui[:y_axis] = deepcopy(master[:y_axis_nd])
    elseif dim == 3 || is_surface(plot_type)
        ui[:x_axis] = deepcopy(master[:x_axis_nd])
        ui[:y_axis] = deepcopy(master[:y_axis_nd])
        ui[:z_axis] = deepcopy(master[:z_axis_3d])
    end

    if !do_reset
        for (scope, dict) in cached_ui
            if haskey(ui, scope)
                for (k, v) in dict
                    ui[scope][k] = v
                end
            else
                ui[scope] = deepcopy(dict)
            end
        end
    end
end

function set_plot_presets!()
    manager.staged[:UI]     = Dict{Symbol, Any}(:reset => true)
    manager.staged[:Plot]   = Dict{Symbol, Any}()
    manager.staged[:Layout] = Dict{Symbol, Any}(:reset => true)
    manager.staged[:Camera] = Dict{Symbol, Any}()

    empty!(manager.staged[:Slider])

    manager.flags[:Layout][] = true
    @info "Staged presets have been cleared. Run Layout update to apply the default values."
    return
end

# ==============================================================================
# --- PLOT PRESET EXTENSION INTERFACE ---
# ==============================================================================

"""
    set_ui_opt!(ui_dict, scope, key, val)

Helper function to safely stage UI options in custom presets.
"""
function set_ui_opt!(ui_dict::Dict, scope::Symbol, key::Symbol, val::Any)
    if !haskey(ui_dict, scope)
        ui_dict[scope] = Dict{Symbol, Any}()
    end
    ui_dict[scope][key] = val
end

"""
    apply_plot_preset!(::Val{:preset_name}, ui, plot, layout)

Dispatched function to define a plot preset. Modify the provided `ui`, `plot`, 
and `layout` dictionaries to stage your desired settings.
"""
function apply_plot_preset!(::Val{T}, ui::Dict, plot::Dict, layout::Dict) where T
    @warn "Unknown plot preset ignored: $T"
end

# ==============================================================================
# --- BUILT-IN PRESETS ---
# ==============================================================================

function apply_plot_preset!(::Val{:convergence}, ui::Dict, plot::Dict, layout::Dict)
    plot[:x_axis]       = :Ns__1
    plot[:u_axis]       = :relative_l2error
    plot[:t]            = 10.0^10              # Replaces :t_Value
    layout[:base_plot]  = :lines_1d
    layout[:plot_style] = :lines_1d 
    
    set_ui_opt!(ui, :x_axis, :log_scale, true)
    set_ui_opt!(ui, :y_axis, :log_scale, true)
    set_ui_opt!(ui, :x_axis, :padding, 0.0)
    
    set_ui_opt!(ui, :labels, :x_label, "Number of Cells (N)")
    set_ui_opt!(ui, :labels, :y_label, "Relative L2 Error")
end

function apply_plot_preset!(::Val{:publication}, ui::Dict, plot::Dict, layout::Dict)
    set_ui_opt!(ui, :labels, :title, "")
    set_ui_opt!(ui, :labels, :legend, "")

    set_ui_opt!(ui, :axis_general, :font_size, 18)
    set_ui_opt!(ui, :axis_general, :label_size, 18)
    set_ui_opt!(ui, :axis_general, :title_size, 22)
    set_ui_opt!(ui, :axis_general, :ticklabel_size, 16)
    
    set_ui_opt!(ui, :x_axis, :padding, 0.0)
    set_ui_opt!(ui, :x_axis, :label_offset, 5.0)
    set_ui_opt!(ui, :y_axis, :label_offset, 5.0)
    set_ui_opt!(ui, :z_axis, :label_offset, 5.0)

    set_ui_opt!(ui, :plot_style, :line_width, 3.6)
    set_ui_opt!(ui, :plot_style, :dashed_lines, false)
    set_ui_opt!(ui, :plot_style, :line_styles, [:solid, (:dash, :dense), (:dot, :dense), :dash, :dot])
    set_ui_opt!(ui, :various, :save_formats, ["pdf", "svg"])

    layout[:legend_base] = :top
    layout[:legend_add]  = :detached
    layout[:plot_width]  = 500
    layout[:plot_height] = 400
end

function apply_plot_preset!(::Val{:heatmap}, ui::Dict, plot::Dict, layout::Dict)
    layout[:base_plot]  = :heatmap
    layout[:plot_style] = :heatmap 
    set_ui_opt!(ui, :x_axis, :label_offset, 10.0)
    set_ui_opt!(ui, :y_axis, :label_offset, 10.0)
    set_ui_opt!(ui, :plot_style, :bottom_margin, 20)
end

function apply_plot_preset!(::Val{:component}, ui::Dict, plot::Dict, layout::Dict)
    layout[:compare_target]  = :Component
    layout[:compare_Columns] = 1
    layout[:compare_link]    = :decoupled
    set_ui_opt!(ui, :labels, :title, "default")
    set_ui_opt!(ui, :labels, :y_label, "")
end

function apply_plot_preset!(::Val{:compact3d}, ui::Dict, plot::Dict, layout::Dict)
    set_ui_opt!(ui, :x_axis, :label_offset, 5.0)
    set_ui_opt!(ui, :y_axis, :label_offset, 5.0)
    set_ui_opt!(ui, :z_axis, :label_offset, 15.0)
    set_ui_opt!(ui, :axis_general, :legend_pos, :td)
end

function apply_plot_preset!(::Val{:nolabels}, ui::Dict, plot::Dict, layout::Dict)
    for key in keys(MASTER_UI_DICT[:labels])
        set_ui_opt!(ui, :Labels, key, "")
    end
end

function apply_plot_preset!(::Val{:darkmode}, ui::Dict, plot::Dict, layout::Dict)
    set_ui_opt!(ui, :plot_style, :colors, [:cyan, :magenta, :yellow, :white])
end

# ==============================================================================
# --- THE ORCHESTRATOR ---
# ==============================================================================

function set_plot_presets!(presets::Union{Symbol, Vector{Symbol}})
    preset_list = presets isa Symbol ? [presets] : presets
    
    ui_over    = Dict{Symbol, Any}()
    plot_opt   = Dict{Symbol, Any}()
    layout_opt = get_base_layout_options()

    for preset in preset_list
        apply_plot_preset!(Val(preset), ui_over, plot_opt, layout_opt)
    end

    merge!(manager.staged[:UI], ui_over)
    merge!(manager.staged[:Plot], plot_opt)
    merge!(manager.staged[:Layout], layout_opt)
    
    if !isempty(layout_opt); manager.flags[:Layout][] = true
    elseif !isempty(plot_opt); manager.flags[:Plot][] = true end 
    
    @info "Successfully staged plot presets: $(join(preset_list, " + "))"
end

# ==============================================================================
# --- MODULAR UI MODIFIERS ---
# ==============================================================================
function apply_ui_style!(prim_key::Union{Symbol, AbstractString}, prim::Any, ui_app::Dict, color::Any)
    k = Symbol(prim_key)
    deps = get(STYLE_DEPENDENCIES, k, Symbol[])
    
    if :colors in deps
        prim.color[] = color
    elseif :color_map in deps
        prim.colormap[] = ui_app[:color_map]
    end
    
    if :line_width in deps
        prim.linewidth[] = ui_app[:line_width]
    end
    
    if :marker_size in deps
        prim.markersize[] = ui_app[:marker_size]
    end
end