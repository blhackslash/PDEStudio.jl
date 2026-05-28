"""
    createExportOptions!(...)

Populates a layout with a filename textbox and save buttons for Images and GIFs.
"""
function createExportOptions!(
    layout::GridLayout,
    plot_fig::Figure,
    manager::PlotManager,
    anim_target_obs::Observable,
    active_axes_obs::Observable{Vector{Int}}, 
    selector_widgets::Vector{Any},
    active_params::Vector{String}
)
    n_params = length(active_params)
    dim_names = Dict{Int, String}()
    for (i, p) in enumerate(active_params); dim_names[i] = p; end
    dim_names[n_params+1] = "Component"
    dim_names[n_params+2] = "Space"
    dim_names[n_params+3] = "Time"

    saveBox = Textbox(layout[2, 1:4], placeholder = "Filename...", width=nothing)
    
    btn_save_def = Button(layout[1, 1], label="Save Defs", buttoncolor=:lightcoral)
    btn_play     = Button(layout[1, 2], label="Play Anim", buttoncolor=:lightyellow)
    btn_img      = Button(layout[1, 3], label="Save Image", buttoncolor=:lightblue)
    btn_gif      = Button(layout[1, 4], label="Save GIF", buttoncolor=:lightgreen)

    # THE FIX: Alle 4 Buttons auf exakt gleiche Breite zwingen
    for i in 1:4
        colsize!(layout, i, Relative(0.25))
    end

    # Helper: Validation for GIF export
    function check_selection_validity(idx)
        if idx == 0 || isnothing(idx)
            @warn "Export Error: No target selected in Animation Preview."
            return false
        end
        if idx in active_axes_obs[]
            @warn "Animation Error: Cannot animate '$(dim_names[idx])' because it is an active plotting axis."
            return false
        end
        widget = selector_widgets[idx]
        if !(widget isa Slider)
            @warn "Export Error: '$(dim_names[idx])' is a discrete Menu. Only Sliders can be animated."
            return false
        end
        if length(widget.range[]) < 2
            @warn "Export Error: Slider for '$(dim_names[idx])' has no range to animate."
            return false
        end
        return true
    end

    # --- Image Save Logic ---
    on(btn_img.clicks) do _
        
        # --- THE FIX: Hard-Lock the Interactive Zoom State ---
        # Sync the user's interactive mouse zoom (finallimits) back to the hard limits 
        # so CairoMakie doesn't reset the view when switching backends.
        for block in plot_fig.content
            if block isa Axis
                lims = block.finallimits[]
                limits!(block, 
                    lims.origin[1], lims.origin[1] + lims.widths[1], 
                    lims.origin[2], lims.origin[2] + lims.widths[2]
                )
            elseif block isa Axis3
                lims = block.finallimits[]
                limits!(block, 
                    lims.origin[1], lims.origin[1] + lims.widths[1], 
                    lims.origin[2], lims.origin[2] + lims.widths[2],
                    lims.origin[3], lims.origin[3] + lims.widths[3]
                )
            end
        end
        # -----------------------------------------------------

        base_name = string(strip(saveBox.stored_string[]))
        if isempty(base_name)
            @info "No filename provided, using default 'plot_export'"
            base_name = "plot_export"
        end

        save_dir = joinpath(get_save_path(), "figures")
        if manager.ui["Various"]["create_savefolder"][]
            save_dir = joinpath(save_dir, base_name)
        end
        mkpath(save_dir)

        formats = manager.ui["Various"]["save_formats"][]
        for fmt in formats
            ext = lowercase(strip(fmt))
            full_path = joinpath(save_dir, base_name * ".$ext")
            
            if ext in ["pdf", "svg"]
                CairoMakie.activate!()
                save(full_path, plot_fig)
                GLMakie.activate!() 
            else
                save(full_path, plot_fig)
            end
        end

        metadata_general = Dict("Save Type" => "Static Frame", "Timestamp" => string(Dates.now()), "Project Root" => pwd())
        saveParametersToCSV(base_name, save_dir, manager, metadata_general)
        @info "Image saved successfully as $(base_name)!"
        
        saveBox.stored_string.val = "" # Reset silently without triggering observers
        Makie.reset!(saveBox)
    end

    # --- GIF Save Logic ---
    on(btn_gif.clicks) do _
        target_idx = anim_target_obs[]
        !check_selection_validity(target_idx) && return
        
        target_widget = selector_widgets[target_idx]
        
        base_name = string(strip(saveBox.stored_string[]))
        if isempty(base_name)
            @info "No filename provided, using default 'anim_export'"
            base_name = "anim_export"
        end
        
        save_path = joinpath(get_save_path(), "animations")
        mkpath(save_path)
        fname = joinpath(save_path, base_name * ".gif")
        
        duration = manager.ui["Various"]["animation_duration_s"][]
        fps = manager.ui["Various"]["animation_fps"][]
        rng = target_widget.range[]
        n_frames = Int(duration * fps)
        
        @info "Recording '$(dim_names[target_idx])' animation to $fname..."
        try
            record(plot_fig, fname, range(rng[1], rng[end], length=n_frames); framerate=fps) do val
                set_close_to!(target_widget, val)
                yield() 
            end
            metadata_general = Dict("Save Type" => "Animation", "Timestamp" => string(Dates.now()), "Project Root" => pwd())
            saveParametersToCSV(base_name, save_path, manager, metadata_general) 
            @info "GIF Saved Successfully."
            if !isnothing(plot_fig); display(plot_fig) end
        catch e
            @error "GIF Recording Failed" exception=(e, catch_backtrace())
        end
        
        saveBox.stored_string.val = "" # Reset silently without triggering observers
        Makie.reset!(saveBox)
    end
    on(btn_save_def.clicks) do _
        GLOBAL_SCENE_OPTIONS[] = extract_scene_options(manager)
        new_ui = Dict{String, Any}()
        for (scope, subdict) in manager.ui
            new_ui[scope] = Dict{String, Any}()
            for (k, v) in subdict; new_ui[scope][k] = to_value(v); end
        end
        GLOBAL_UI_OVERWRITE[] = new_ui
        GLOBAL_VAR_OVERWRITE[] = copy(manager.controls["base_types"][])
        @info "Current UI and Scene options successfully saved to global defaults!"
    end
    # Anim Play Logic (Die aus createAnimationPreview! übernommen wurde)
    is_animating = Observable(false)
    animation_timer = Ref{Union{Timer, Nothing}}(nothing)
    
    on(is_animating) do animating
        btn_play.label[] = animating ? "Stop Anim" : "Play Anim"
    end

    on(btn_play.clicks) do _
        if is_animating[]
            is_animating[] = false
            !isnothing(animation_timer[]) && close(animation_timer[])
            animation_timer[] = nothing
        else
            target_idx = anim_target_obs[]
            !check_selection_validity(target_idx) && return
            
            target_widget = selector_widgets[target_idx]
            is_animating[] = true
            
            duration = manager.ui["Various"]["animation_duration_s"][]
            fps = manager.ui["Various"]["animation_fps"][]
            rng = target_widget.range[]
            start_time = time()
            
            animation_timer[] = Timer(0.0, interval = 1/fps) do t
                if !is_animating[]
                    close(t); return
                end
                elapsed = mod(time() - start_time, duration)
                progress = elapsed / duration
                val = rng[1] + progress * (rng[end] - rng[1])
                set_close_to!(target_widget, val)
            end
        end
    end
end
"""
    apply_scene_options!(manager::PlotManager, scene_options::Dict)

Safely snaps UI widgets to the requested states natively through the MVC Dictionary structure.
"""
function apply_scene_options!(manager::PlotManager, scene_options::Dict)
    isempty(scene_options) && return

    # 1. Apply Structural & Axis Menus
    menu_keys = ["Plot_Type", "Compare_Target", "Compare_Columns", "Compare_Link", "Legend_Base", "Legend_Add", "Plot_Width", "Plot_Height", "Anim_Target", "c", "X-Axis", "Y-Axis", "Z-Axis", "U-Axis"]
    
    for k in menu_keys
        sel_key = "$(k)_Selection"
        if haskey(scene_options, sel_key) && haskey(manager.controls["Widget"], k)
            val = scene_options[sel_key]
            widget = manager.controls["Widget"][k][]
            opts = manager.controls["Options"][k][]
            isempty(opts) && continue
            
            valid_vals = (!isempty(opts) && opts[1] isa Tuple) ? [o[2] for o in opts] : opts
            idx = findfirst(v -> string(v) == string(val), valid_vals)
            if !isnothing(idx)
                widget.i_selected[] = idx
            end
        end
    end

    # 2. Apply Sliders (Safely clamped to the newly calculated ranges!)
    for (key, desired_val) in scene_options
        if endswith(key, "_Value")
            base_name = replace(key, "_Value" => "")
            if haskey(manager.controls["Widget"], base_name)
                widget = manager.controls["Widget"][base_name][]
                if widget isa Makie.Slider
                    rng = manager.controls["Range"][base_name][]
                    isempty(rng) && continue
                    
                    val = Float64(rng[1])
                    if desired_val isa Real
                        val = clamp(Float64(desired_val), Float64(rng[1]), Float64(rng[end]))
                    end
                    set_close_to!(widget, val)
                end
            end
        end
    end
    @info "Dynamic Scene Options Successfully Applied."
end

function get_base_scene_options()
    return Dict{String, Any}(
        "X-Axis_Selection"          => "x",      
        "U-Axis_Selection"          => "u",      
        "Plot_Type_Selection"       => "Lines",  
        "c_Selection"               => 1,        
        "t_Value"                   => 0.0,      
        "x_Value"                   => 0.0,
        "Compare_Target_Selection"  => "None", 
        "Compare_Columns_Selection" => "2",     
        "Compare_Link_Selection"    => "Fully Coupled",
        "Legend_Base_Selection"     => "right",
        "Legend_Add_Selection"      => "detached",
        "Plot_Width_Selection"      => "600",
        "Plot_Height_Selection"     => "400",
    )
end

function extract_scene_options(manager::PlotManager)
    opts = Dict{String, Any}()
    
    # Matches the exact MVC keys defined in Controls.jl
    for k in ["X-Axis", "Y-Axis", "Z-Axis", "U-Axis", "Plot_Type", "c", "Compare_Target", 
              "Compare_Columns", "Compare_Link", "Legend_Base", "Legend_Add", "Plot_Width", "Plot_Height", "Anim_Target"]
        if haskey(manager.controls["Selection"], k)
            opts["$(k)_Selection"] = to_value(manager.controls["Selection"][k])
        end
    end
    
    for k in manager.plot_vars
        if haskey(manager.controls["Value"], k)
            opts["$(k)_Value"] = to_value(manager.controls["Value"][k])
        end
    end
    
    return opts
end
"""
    csv_to_simulation_config(parsed_csv::Dict, sim_func::Function)

Converts a parsed nested CSV dictionary into a properly formatted `SimulationConfig`.
"""
function csv_to_simulation_config(parsed_csv::Dict, sim_func::Function)
    # 1. Extract Shared Parameters
    shared_params = Dict{String, Any}()
    if haskey(parsed_csv, "Simulation") && haskey(parsed_csv["Simulation"], "shared")
        shared_params = parsed_csv["Simulation"]["shared"]
    end

    # 2. Extract Methods (No longer hijacks "analytical" methods!)
    methods_dict = Dict{String, Dict{String, Any}}()
    if haskey(parsed_csv, "Simulation")
        for (scope, params) in parsed_csv["Simulation"]
            if scope != "shared"
                methods_dict[scope] = params
            end
        end
    end

    # 3. Extract Varied Parameters from the Config Category
    varied_params = Dict{String, Vector}()
    if haskey(parsed_csv, "Config") && haskey(parsed_csv["Config"], "Parameters")
        for (k, v) in parsed_csv["Config"]["Parameters"]
            varied_params[k] = v
        end
    else
        @warn "No 'Config -> Parameters' found in CSV. Simulation will have no varied parameters."
    end

    # 4. Default Methods
    default_methods = collect(keys(methods_dict))

    # 5. Extract Reference Name explicitly from Config
    ref_name = nothing
    if haskey(parsed_csv, "Config") && haskey(parsed_csv["Config"], "General")
        csv_ref = get(parsed_csv["Config"]["General"], "reference_func", "none")
        if csv_ref != "none" && !isempty(csv_ref)
            ref_name = csv_ref
        end
    end

    # 6. Resolve the Analytical Solution Factory
    ref_func = nothing
    if !isnothing(ref_name)
        # Convert the UI string back to a safe function name
        safe_ref_name = lowercase(replace(strip(ref_name), r"[\s-]+" => "_"))
        
        ref_factory = try
            resolve_reference_function(safe_ref_name)
        catch
            nothing
        end
        
        # Instantiate the exact mathematical closure using the loaded shared parameters
        if !isnothing(ref_factory)
            ref_func = Base.invokelatest(ref_factory, shared_params)
        else
            @warn "Failed to resolve reference function: $safe_ref_name"
        end
    end

    # 7. Construct and return the SimulationConfig
    return SimulationConfig(
        sim_func,
        ref_func,
        ref_name,
        shared_params,
        methods_dict,
        default_methods,
        varied_params
    )
end
function smart_parse_csv_value(val_str::String)
    val_str = strip(val_str)
    
    # 1. Handle Keywords
    if val_str == "true"; return true; end
    if val_str == "false"; return false; end
    if val_str == "<empty>"; return ""; end
    
    # 2. Handle Numbers
    v_int = tryparse(Int, val_str)
    if !isnothing(v_int); return v_int; end
    v_float = tryparse(Float64, val_str)
    if !isnothing(v_float); return v_float; end
    
    # 3. Handle Julia Expressions (Symbols, Arrays, Tuples)
    # Since we stripped prefixes, everything starts with ':', '[', or '('
    if startswith(val_str, ":") || startswith(val_str, "[") || startswith(val_str, "(")
        try
            return eval(Meta.parse(val_str))
        catch e
            @warn "Failed to parse expression: $val_str"
        end
    end
    
    # 4. Fallback to clean string
    return replace(val_str, r"^\"|\"$" => "")
end

function parse_csv_to_dict(filepath::String)
    parsed = Dict{String, Dict{String, Dict{String, Any}}}()
    
    for row in CSV.Rows(filepath)
        cat, scope, param, val_str = String(row.Category), String(row.Scope), String(row.Parameter), String(row.Value)
        val = smart_parse_csv_value(val_str)
        
        if !haskey(parsed, cat); parsed[cat] = Dict{String, Dict{String, Any}}(); end
        if !haskey(parsed[cat], scope); parsed[cat][scope] = Dict{String, Any}(); end
        
        parsed[cat][scope][param] = val
    end
    
    return parsed
end