# ==============================================================================
# --- UIStyles.jl ---
# ==============================================================================

const LEGEND_SUPPORTED_PLOTS = (:lines_1d, :scatter_colors, :scatter_lines, :contour_colors, :contour_surface)
const COLORBAR_SUPPORTED_PLOTS = (:heatmap_flat, :scatter_1d, :scatter_2d, :scatter_surface, :contour_f, :contour_3d, :scatter_3d, :heatmap_surface, :volume_3d, :contour_cmap, :lines_2d, :lines_3d)
const REPLOT_OPTIONS = (:use_color_map, :line_direction, :base_method_idx, :padding, :log_scale, :dashed_lines, :levels, :rasterize, :legend_label)
const LAYOUT_OPTIONS = (:base_plot, :plot_style, :compare_target, :compare_columns, :compare_link, :legend_base, :legend_add, :plot_width, :plot_height)
const PLOT_AXIS_OPTIONS = (:x_axis, :y_axis, :z_axis, :u_axis, :component)
const EXPLORATION_OPTIONS = (:anim_target, :component)

# --- SYMBOL / LABEL ROUTING ---
const SYMBOL_TO_LABEL_MAP = Dict{Symbol, String}(
    :hud => "HUD",
    :fps => "FPS",
    :x_axis => "X-Axis",
    :y_axis => "Y-Axis",
    :z_axis => "Z-Axis",
    :u_axis => "U-Axis (Dep)",
    :ui => "UI",
    :none => "Disabled",
    :outliers_extrema => "Outliers & Extrema",
    :dpi => "DPI",
    
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
    :contour_colors => "Contour Lines",
    :contour_cmap => "Contour Colormap",
    :contour_f => "Contour Filled",
    :contour_surface => "Contour Surface",
    :contour_3d => "3D Contour",
    :heatmap_flat => "Flat",
    :heatmap_surface => "Surface",
    :volume_3d => "3D Cloud (Volume)",

    :x => "Position (X)",
    :y => "Position (Y)",
    :z => "Position (Z)",
    :t => "Time (T)",
)

function backend_key(s::AbstractString)
    s_clean = replace(strip(s), r"[\s-]+" => "_")
    return Symbol(lowercase(s_clean))
end

"""
    set_label!(sym::Symbol, label::AbstractString)

Registers a custom UI display name for a backend Symbol. 
Perfect for fixing method acronyms (e.g., `set_label!(:rk4, "RK4")`).
"""
function set_label!(sym::Symbol, label::AbstractString)
    manager.maps[:Labels][sym] = String(label)
end

function frontend_key(s::Symbol)
    # 1. Check User-Defined dynamic labels first
    if haskey(manager.maps, :Labels) && haskey(manager.maps[:Labels], s)
        return manager.maps[:Labels][s]
    end
    # 2. Default Mappings
    if haskey(SYMBOL_TO_LABEL_MAP, s)
        return SYMBOL_TO_LABEL_MAP[s]
    end
    # 3. Algorithmic Fallback
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
    :heatmap_flat       => 2,
    :contour_colors     => 2,
    :contour_cmap       => 2, 
    :contour_f          => 2,
    :scatter_2d         => 2,
    :scatter_surface    => 2,
    :heatmap_surface    => 2,
    :contour_surface    => 2,
    :contour_3d         => 3,
    :lines_3d           => 3,
    :scatter_3d         => 3,
    :volume_3d          => 3,
)

const EULERIAN_PLOT_STYLE_OPTIONS = Dict{Symbol, Vector{Any}}(
    :lines   => Any[menu_opt(:lines_1d), menu_opt(:lines_2d), menu_opt(:lines_3d)],
    :scatter => Any[menu_opt(:scatter_1d), menu_opt(:scatter_lines), menu_opt(:scatter_colors), menu_opt(:scatter_2d), menu_opt(:scatter_3d)],
    :contour => Any[menu_opt(:contour_colors), menu_opt(:contour_cmap), menu_opt(:contour_f), menu_opt(:contour_surface), menu_opt(:contour_3d)],
    :heatmap => Any[menu_opt(:heatmap_flat), menu_opt(:heatmap_surface)],
    :volume  => Any[menu_opt(:volume_3d)]
)

const LAGRANGIAN_PLOT_STYLE_OPTIONS = Dict{Symbol, Vector{Any}}(
    :scatter => Any[menu_opt(:scatter_1d), menu_opt(:scatter_2d), menu_opt(:scatter_surface), menu_opt(:scatter_3d), menu_opt(:scatter_lines), menu_opt(:scatter_colors)] 
)

const STYLE_DEPENDENCIES = Dict{Symbol, Vector{Symbol}}(
    :lines_1d         => [:colors, :line_width, :line_styles, :dashed_lines, :reference],
    :scatter_1d       => [:color_map, :color_range, :markers, :marker_size, :bottom_margin, :method_index],
    :scatter_colors   => [:colors, :markers, :marker_size],
    :scatter_lines    => [:colors, :line_width, :line_styles, :dashed_lines, :markers, :marker_size, :reference],
    
    :lines_2d         => [:color_map, :color_range, :line_width, :line_direction, :bottom_margin, :method_index],
    :lines_3d         => [:color_map, :color_range, :line_width, :line_direction, :bottom_margin, :method_index],
    
    :scatter_2d       => [:color_map, :color_range, :markers, :marker_size, :bottom_margin, :method_index],
    :scatter_surface  => [:color_map, :color_range, :markers, :marker_size, :method_index],
    :scatter_3d       => [:color_map, :color_range, :markers, :marker_size, :method_index],
    
    :contour_colors          => [:colors, :levels, :line_width, :labels],
    :contour_cmap     => [:color_map, :color_range, :levels, :line_width, :labels, :bottom_margin, :method_index],
    :contour_f        => [:color_map, :color_range, :levels, :method_index, :bottom_margin],
    :contour_surface  => [:colors, :levels, :line_width, :labels],
    :heatmap_flat          => [:color_map, :color_range, :bottom_margin, :method_index],
    :heatmap_surface          => [:color_map, :color_range, :method_index],
    :volume_3d           => [:color_map, :color_range, :method_index],
    :contour_3d       => [:colors, :levels, :line_width, :method_index]
)

# In UIStyles.jl
const PRESET_DESCRIPTIONS = Dict{Symbol, String}(
    :convergence => "Optimized for 1D error convergence plots.",
    :publication => "Clean, high-contrast style for papers.",
    :heatmap     => "Optimized layout and margins for 2D heatmaps.",
    :component   => "Splits components into separate linked plots.",
    :compact3d   => "Adjusts 3D axis labels for tighter packing.",
    :nolabels    => "Removes all axis and title labels.",
    :darkmode    => "High-contrast colors for dark themes."
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
        :legend_label   => "Methods",
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
    
    master[:export] = Dict{Symbol, Any}(
        :save_formats         => ["png"], 
        :create_savefolder    => false,
        :animation_time       => 10.0, 
        :animation_FPS        => 30,
        :rasterize            => 3,
        :dpi                  => 300,
        :mp4_compression      => 15, # THE FIX: Added high-quality MP4 compression (0 is lossless, 51 is worst)
    )
    master[:outliers_extrema] = Dict{Symbol, Any}(
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

    master[:x_axis_1d] = axis_dict(0.0, 15.0)
    master[:y_axis_1d] = axis_dict(0.05, 15.0)
    
    master[:x_axis_nd] = axis_dict(0.0, 40.0)
    master[:y_axis_nd] = axis_dict(0.0, 40.0)
    master[:z_axis_3d] = axis_dict(0.05, 50.0)
    
    master[:plot_style] = Dict{Symbol, Any}(
        :colors          => [(:black,.8), :blue, :green, :orange, :purple, :yellow],
        :color_map       => :viridis,
        :color_range     => Any[],
        :line_width      => 3.0,
        :line_direction  => :horizontal,
        :line_styles     => [:solid, :dash, :dot, (:dash, :dense), (:dot, :dense)],
        :markers         => [:circle, :rect, :utriangle, :dtriangle, :cross],
        :marker_size     => 15.0,
        :levels          => 15,
        :method_index    => 1,
        :bottom_margin   => 60,
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

    # THE FIX: Track the active state and calculate dimensionality shifts!
    old_plot_type = get(manager.state, :Active_Plot_Type, :none)
    if old_plot_type == plot_type && !isempty(ui)
        return 
    end
    manager.state[:Active_Plot_Type] = plot_type
    
    old_dim = haskey(PLOT_DIM_MAP, old_plot_type) ? PLOT_DIM_MAP[old_plot_type] : 0
    new_dim = PLOT_DIM_MAP[plot_type]
    dim_changed = old_dim != new_dim
    
    # Cache user's current settings before overwriting with defaults
    cached_ui = deepcopy(ui)
    empty!(ui)
    
    ui[:axis_general]       = deepcopy(master[:axis_general])
    ui[:labels]             = deepcopy(master[:labels])
    ui[:export]            = deepcopy(master[:export])
    ui[:outliers_extrema]   = deepcopy(master[:outliers_extrema])
    ui[:hud]                = deepcopy(master[:hud])
    ui[:plot_style]         = deepcopy(master[:plot_style])
    
    if new_dim == 1
        ui[:x_axis] = deepcopy(master[:x_axis_1d])
        ui[:y_axis] = deepcopy(master[:y_axis_1d])
    elseif new_dim == 2 && !is_surface(plot_type)
        ui[:x_axis] = deepcopy(master[:x_axis_nd])
        ui[:y_axis] = deepcopy(master[:y_axis_nd])
    elseif new_dim == 3 || is_surface(plot_type)
        ui[:x_axis] = deepcopy(master[:x_axis_nd])
        ui[:y_axis] = deepcopy(master[:y_axis_nd])
        ui[:z_axis] = deepcopy(master[:z_axis_3d])
    end

    # Core master templates that should never act as active overrides
    internal_templates = (:x_axis_1d, :y_axis_1d, :x_axis_nd, :y_axis_nd, :z_axis_3d)

    for (scope, dict) in cached_ui
        scope in internal_templates && continue 
        
        # THE FIX: Only wipe the axis customizations if the dimensionality fundamentally changed!
        if dim_changed && scope in (:x_axis, :y_axis, :z_axis)
            continue
        end
        
        if haskey(ui, scope)
            for (k, v) in dict
                ui[scope][k] = v
            end
        else
            ui[scope] = deepcopy(dict)
        end
    end
end

function set_plot_presets!()
    # 1. Clear the UI dictionary completely (switch_ui_plot_type! will build the specific defaults)
    empty!(manager.ui)
    
    # 2. Reset Layout and Sliders safely
    apply_layout_options!(get_base_layout_options())
    empty!(manager.state[:Slider_Cache])
    
    # 3. Reset Camera
    manager.state[:Camera_Cache] = Dict{Symbol, Any}()
    
    # 4. Reset Exploration Options
    if haskey(manager.state, :Exploration_Cache)
        manager.state[:Exploration_Cache] = Dict{Symbol, Any}(:anim_target => :none, :component => 1)
    end

    manager.triggers[:Layout][] += 1
    @info "UI and Layout have been directly reset to defaults."
    return
end

function set_ui_opt!(scope::Symbol, key::Symbol, val::Any)
    # Directly mutates the active UI dictionary
    if !haskey(manager.ui, scope)
        manager.ui[scope] = Dict{Symbol, Any}()
    end
    manager.ui[scope][key] = val
end

"""
    apply_plot_preset!(::Val{:preset_name})

Dispatched function to define a plot preset.
"""
function apply_plot_preset!(::Val{T}) where T
    @warn "Unknown plot preset ignored: $T"
end
# ==============================================================================
# --- BUILT-IN PRESETS ---
# ==============================================================================

function apply_plot_preset!(::Val{:publication})
    set_ui_opt!(:labels, :title, "")
    set_ui_opt!(:labels, :legend_label, "")

    set_ui_opt!(:axis_general, :font_size, 18)
    set_ui_opt!(:axis_general, :label_size, 18)
    set_ui_opt!(:axis_general, :title_size, 22)
    set_ui_opt!(:axis_general, :ticklabel_size, 16)
    
    set_ui_opt!(:x_axis, :padding, 0.0)
    set_ui_opt!(:x_axis, :label_offset, 5.0)
    set_ui_opt!(:y_axis, :label_offset, 5.0)
    set_ui_opt!(:z_axis, :label_offset, 5.0)

    set_ui_opt!(:plot_style, :line_width, 2.5)
    set_ui_opt!(:plot_style, :dashed_lines, false)
    set_ui_opt!(:plot_style, :line_styles, [:solid, (:dash, :dense), (:dot, :dense), :dash, :dot])
    set_ui_opt!(:export, :save_formats, ["pdf", "svg", "png"])

    apply_layout_options!(Dict(
        :legend_base => :top,
        :legend_add  => :detached,
        :plot_width  => 500,
        :plot_height => 400
    ))
end

function apply_plot_preset!(::Val{:heatmap})
    apply_layout_options!(Dict(
        :base_plot      => :heatmap,
        :plot_style     => :heatmap_flat,
        :compare_target => :methods,
        :compare_link   => :fully_coupled
    ))
    
    set_ui_opt!(:x_axis, :label_offset, 10.0)
    set_ui_opt!(:y_axis, :label_offset, 10.0)
    set_ui_opt!(:x_axis, :padding, 0.0)
    set_ui_opt!(:y_axis, :padding, 0.0)
    set_ui_opt!(:plot_style, :bottom_margin, 20)
end

function apply_plot_preset!(::Val{:component})
    apply_layout_options!(Dict(
        :compare_target  => :component,
        :compare_columns => 1,
        :compare_link    => :decoupled
    ))
    
    set_ui_opt!(:labels, :title, "default")
    set_ui_opt!(:labels, :y_label, "")
end

function apply_plot_preset!(::Val{:compact3d})
    set_ui_opt!(:x_axis, :label_offset, 5.0)
    set_ui_opt!(:y_axis, :label_offset, 5.0)
    set_ui_opt!(:z_axis, :label_offset, 15.0)
    set_ui_opt!(:axis_general, :legend_pos, :td)
end

function apply_plot_preset!(::Val{:nolabels})
    for key in keys(MASTER_UI_DICT[:labels])
        set_ui_opt!(:labels, key, "")
    end
end

function apply_plot_preset!(::Val{:darkmode})
    set_ui_opt!(:plot_style, :colors, [:cyan, :magenta, :yellow, :white])
end

# ==============================================================================
# --- THE ORCHESTRATOR ---
# ==============================================================================

function set_plot_presets!(name::Symbol)
    # 1. Check for Hardcoded functions
    if haskey(PRESET_DESCRIPTIONS, name)
        
        apply_plot_preset!(Val(name))
        manager.triggers[:Layout][] += 1
        @info "Applied hardcoded preset: $name"
    else
        # 2. Check Disk CSVs
        preset_path = joinpath(get_save_path(), "Presets", "$(name).csv")
        if isfile(preset_path)
            load_and_apply_csv!(preset_path)
            
            parsed = parse_csv_to_dict(preset_path)
            if haskey(parsed, "Metadata") && haskey(parsed["Metadata"], "Preset")
                manager.maps[:Presets][name] = get(parsed["Metadata"]["Preset"], "description", "Custom disk preset")
            end
            
            manager.triggers[:Layout][] += 1
            @info "Applied custom disk preset: $name"
        else
            @warn "Preset '$name' not found in Disk or Hardcoded styles."
        end
    end
end

# ==============================================================================
# --- MODULAR UI MODIFIERS ---
# ==============================================================================
function apply_ui_style!(prim_key::Union{Symbol, AbstractString}, prim::Any, ui_app::Dict, color::Any, cr_obs::Observable = Observable((0.0, 1.0)))
    k = Symbol(prim_key)
    deps = get(STYLE_DEPENDENCIES, k, Symbol[])
    
    try
        if :colors in deps && haskey(prim.attributes, :color)
            prim.color[] = Makie.to_color(color)
        elseif :color_map in deps && haskey(prim.attributes, :colormap)
            prim.colormap[] = Makie.to_colormap(ui_app[:color_map])
        end
        
        # THE FIX: Apply the extracted color limits dynamically
        if :color_range in deps && haskey(prim.attributes, :colorrange)
            prim.colorrange[] = cr_obs[]
        end
        
        # THE FIX: Force contour lines to map exactly onto the active color limits
        if :levels in deps && haskey(prim.attributes, :levels)
            lvls = ui_app[:levels]
            prim.levels[] = range(cr_obs[][1], cr_obs[][2], length=max(2, lvls))
        end
        
        if :line_width in deps && haskey(prim.attributes, :linewidth)
            prim.linewidth[] = Float64(ui_app[:line_width])
        end
        
        if :marker_size in deps && haskey(prim.attributes, :markersize)
            prim.markersize[] = Float32(ui_app[:marker_size])
        end
    catch e
        @warn "Failed to apply UI style dynamically to $k" exception=(e, catch_backtrace())
    end
end