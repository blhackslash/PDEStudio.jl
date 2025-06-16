
"""
    show1DSolutionFig(sim_config::SimulationConfig)

Creates an interactive Makie plot for `SimData1D` with animation playback
and an option to save the animation as a GIF (which may close the window).
Saves corresponding parameters to a CSV file.
Uses closest data point logic for animation frames.
"""
function show1DSolutionFig(sim_config::SimulationConfig; ui_options::UIType = :default)

    # --- Basic Setup & UI ---
    local_ui_dict = createUIDict(ui_options)
    plot_fig = Figure(size = get(local_ui_dict, "figsize", (900, 600)))


    # --- Parameter & Method Observables/Controls (REVISED INITIALIZATION) ---
    # Observable dictionary for SHARED parameters
    shared_params_obs = Dict{String, Observable}()
    for (key, val) in sim_config.shared_params
        shared_params_obs[key] = Observable(val)
    end
    # NESTED Observable dictionary for METHOD-SPECIFIC parameters
    method_params_collection_obs = Dict{String, Dict{String, Observable}}()
    for (method_name, method_params_dict) in sim_config.methods_dict
        inner_obs_dict = Dict{String, Observable}()
        for (param_key, param_val) in method_params_dict
            inner_obs_dict[param_key] = Observable(param_val)
        end
        method_params_collection_obs[method_name] = inner_obs_dict
    end


    all_method_names = collect(keys(sim_config.methods_dict))

    # Method selection observable (no change)
    methods_obs = Observable(issubset(sim_config.default_methods,all_method_names) ? sim_config.default_methods : all_method_names)
    #methods_obs = Observable(isempty(all_method_names) ? String[] : [default_method])
    method_number = lift(length, methods_obs)


    # --- Call the NEW createControls function ---
    control_fig, update_notifier = createBaseControlsFigure(
        plot_fig,
        shared_params_obs,
        method_params_collection_obs,
        methods_obs,
        all_method_names
    )
    # -----------------------------------------

    sys_dim = local_ui_dict["system_dimension"]
    sel_comp_obs = Observable(1)
    axis_label = lift(update_notifier) do _; "Solution Value u$(sel_comp_obs[])" end

    ax = Axis(plot_fig[1,1], xlabel = "Position (x)", ylabel = axis_label) # Title set dynamically

    compLabel_text = lift(sel_comp_obs) do sel_comp
        sys_dim > 1 ? "Component: $sel_comp / $sys_dim" : "Component: 1 / 1 (Scalar)"
    end    
    Label(control_fig[end+1,:], compLabel_text)
    if sys_dim > 1
        component_slider = Slider(control_fig[end+1,:], range = 1:sys_dim, startvalue = 1)
        on(component_slider.value) do val
            sel_comp_obs[] = round(Int, val)
        end
    end


    # --- NEW Max Tracking Control ---
    # Add Checkbox below the animation/save controls
    track_max_obs = Observable(false) # Get default from dict
    cb_track_max = Toggle(control_fig[end+1, :][1,1], active = false)
    Label(control_fig[end, :][1,2], "Track Maximum") # Span columns

    # Link checkbox state back to observable (no explicit notify needed if lift depends on it)
    on(cb_track_max.active) do track_state
        track_max_obs[] = track_state
    end
    # --- End Max Tracking Control ---

    # --- Time Slider & Label ---
    tLabel_text = Observable("t = 0.0")
    # Add a new row for the time label
    Label(control_fig[end+1, :], text = tLabel_text, tellwidth=false).padding = (0, 0, 5, 0) # Span controls area
    # Add a new row for the time slider
    tSlider = Slider(control_fig[end+1, :], range = 0.0:1.0, startvalue = 0.0) # Span controls area

    # --- Animation and GIF Saving Controls ---
    # Add a new row, using a grid layout within it for alignment
    anim_save_controls_row = control_fig[end+1, :] = GridLayout() # Span controls area

    # Animation State/Controls
    is_animating = Observable(false)
    animation_timer = Ref{Union{Timer, Nothing}}(nothing)
    time_range_data = Ref((0.0, 1.0)) # Stores (t_min, t_max) from actual data
    play_button = Button(anim_save_controls_row[1, 1], label = @lift($is_animating ? "Stop Anim" : "Play Anim")) # Col 1

    # GIF Saving Textbox (Col 2) - with default value
    gif_save_textbox = Textbox(anim_save_controls_row[1, 2], placeholder = "GIF Name (no ext)", width=150)
    gif_save_textbox.stored_string = "untitled_anim" # Set default filename

    # GIF Saving Button (Col 3)
    gif_save_button = Button(anim_save_controls_row[1, 3], label = "Save GIF")

    # Warning Label (Col 4)
    Label(anim_save_controls_row[1, 4], text="(Window may close!)", fontsize=10, color=:darkgray, halign=:left).padding = (10,0,0,0)

    # Adjust column sizes in the controls row for better spacing
    colsize!(anim_save_controls_row, 1, Auto()); colsize!(anim_save_controls_row, 3, Auto()); colsize!(anim_save_controls_row, 4, Auto())



    # --- Data Structures ---
    # Outer Observable holds Vector of Inner Observables (one per method)
    xData = Observable(Vector{Observable{Vector{Vector{Float64}}}}(undef, 0)) # Full x data series
    uData = Observable(Vector{Observable{Vector{Vector{Float64}}}}(undef, 0)) # Full u data series
    tData = Observable(Vector{Observable{Vector{Float64}}}(undef, 0))       # Full t data series
    xs = Observable(Vector{Observable{Vector{Float64}}}(undef, 0))           # Snapshot x data for plotting
    us = Observable(Vector{Observable{Vector{Float64}}}(undef, 0))           # Snapshot u data for plotting
    global_xlims = Observable((0.0, 1.0)) # For fixed plot limits
    global_ylims = Observable((0.0, 1.0)) # For fixed plot limits
    # --- NEW: Observables for max tracking ---
    x_at_max_obs = Observable(Vector{Observable{Float64}}(undef, 0)) # Stores X position of max U per method
    u_at_max_obs = Observable(Vector{Observable{Float64}}(undef, 0)) # Stores max U value per method
    # ------------------------------------
    # --- Lift Block 1: Data Loading / Simulation Execution ---
    lift(update_notifier; ignore_equal_values=true) do _
        active_num = length(methods_obs[])
        println("Lift 1: Running sims / loading data...") # Concise print
        # Resize outer vectors
        resize!(xData[], active_num); resize!(uData[], active_num); resize!(tData[], active_num)
        
        resize!(xs[], active_num); resize!(us[], active_num)
        resize!(x_at_max_obs[], active_num); resize!(u_at_max_obs[], active_num) # Resize new
        # Ensure inner observables exist
        for k in 1:active_num
             if !isassigned(xData[], k) || !isa(xData[][k], Observable); xData[][k] = Observable(Vector{Vector{Float64}}()); end
             if !isassigned(uData[], k) || !isa(uData[][k], Observable); uData[][k] = Observable(Vector{Vector{Float64}}()); end
             if !isassigned(tData[], k) || !isa(tData[][k], Observable); tData[][k] = Observable(Float64[]); end
             if !isassigned(xs[], k) || !isa(xs[][k], Observable); xs[][k] = Observable(Float64[]); end
             if !isassigned(us[], k) || !isa(us[][k], Observable); us[][k] = Observable(Float64[]); end
             if !isassigned(x_at_max_obs[], k) || !isa(x_at_max_obs[][k], Observable); x_at_max_obs[][k] = Observable(NaN); end
             if !isassigned(u_at_max_obs[], k) || !isa(u_at_max_obs[][k], Observable); u_at_max_obs[][k] = Observable(NaN); end
        end

        all_time_points = Set{Float64}()
        g_xmin, g_xmax = Inf, -Inf; g_umin, g_umax = Inf, -Inf
        found_any_data = false
        active_methods_now = methods_obs[]

        for i = 1:active_num
            method = active_methods_now[i]
            # Assemble params for this method run
            # --- Assemble Parameters using Helper ---
            params = assembleParams(
                shared_params_obs,          # Pass the observable dict
                method_params_collection_obs, # Pass the nested observable dict
                method
            )
            # ------------------------------------

            # --- Load or Compute Data ---
            local sim_data::Union{AbstractSimData, Nothing} = nothing
            try
                # Assumes existence of Utils.doesSimDataExist and Utils.loadSimData
                if !Utils.doesSimDataExist(params)
                     println(" Running simulation for method: $method")
                     sim_data = sim_config.sim_function(params)
                     Utils.saveSimData(sim_data;overwrite = true) # Assumes saveSimData exists
                else
                     println(" Loading data for method: $method")
                     sim_data = Utils.loadSimData(params)
                end
            catch e
                 @warn "Simulation/Load failed for method '$method'" exception=(e, catch_backtrace())
                 sim_data = nothing
            end
            # --------------------------

            # --- Store Data & Update Limits ---
            if isnothing(sim_data) || !isa(sim_data, SimData1D)
                 @warn "Invalid SimData1D for '$method'. Assigning empty."
                 xData[][i][] = Vector{Vector{Float64}}(); uData[][i][] = Vector{Vector{Float64}}(); tData[][i][] = Float64[]
                 xs[][i][] = Float64[]; us[][i][] = Float64[]
                 continue # Skip to next method
            end

            xData[][i][] = sim_data.x
            if sys_dim == 1
                @assert isa(sim_data.u, Vector{Vector{Float64}}) "System data input found for scalar plotting. Ensure that system_dimension is set correctly!"
                uData[][i][] = sim_data.u
            else
                uData[][i][] = [us[:,sel_comp_obs[]] for us = sim_data.u]
            end
            tData[][i][] = sim_data.t
            union!(all_time_points, sim_data.t)

            # Update Global Limits Calculation
            for k in eachindex(sim_data.t)
                 if k <= length(sim_data.x) && k <= length(sim_data.u)
                     x_k = sim_data.x[k]; u_k = uData[][i][][k]
                     if !isempty(x_k) && !isempty(u_k)
                         found_any_data = true
                         xmin_k, xmax_k = extrema(x_k); umin_k, umax_k = extrema(u_k)
                         g_xmin = min(g_xmin, xmin_k); g_xmax = max(g_xmax, xmax_k)
                         g_umin = min(g_umin, umin_k); g_umax = max(g_umax, umax_k)
                     end
                 end
            end
            # -----------------------------
        end # End loop over methods

        # --- Finalize and Apply Global Limits ---
        if found_any_data; pad_x=get(local_ui_dict,"x_axis_limit_padding",0.05); pad_y=get(local_ui_dict,"y_axis_limit_padding",0.1); xr=g_xmax-g_xmin; xp=xr≈0 ? 0.1 : (xr*pad_x/2.0); yr=g_umax-g_umin; yp=yr≈0 ? 0.1 : (yr*pad_y/2.0); final_xlims=(g_xmin-xp,g_xmax+xp); final_ylims=(g_umin-yp,g_umax+yp); global_xlims[]=final_xlims; global_ylims[]=final_ylims; try; xlims!(ax,final_xlims); ylims!(ax,final_ylims); catch e; @warn "Failed applying limits" e; end; else; global_xlims[]=(0.0,1.0); global_ylims[]=(0.0,1.0); try; xlims!(ax,0.0,1.0); ylims!(ax,0.0,1.0); catch e; @warn "Failed applying default limits" e; end; end

        # --- Update Time Slider Range / Store Data Range ---
        if !isempty(all_time_points); 
            t_min_data,t_max_data=extrema(all_time_points); 
            time_range_data[]=(t_min_data,t_max_data); 
            sorted_times=sort(collect(all_time_points)); 
            t_len=length(sorted_times); 
            t_range_slider=range(t_min_data,stop=t_max_data,length=max(2,t_len*2+100)); 
            if t_len==1; 
                t_range_slider=range(t_min_data,stop=t_max_data,length=2); 
            end; 
            if tSlider.range[]!=t_range_slider; 
                tSlider.range=t_range_slider; 
            end; 
            current_t_val=clamp(tSlider.value[],t_min_data,t_max_data); 
            set_close_to!(tSlider, current_t_val); 
        else; time_range_data[]=(0.0,1.0); 
            if tSlider.range[]!=(0.0:1.0); 
                tSlider.range=0.0:1.0; 
            end; 
            set_close_to!(tSlider, 0.0); 
        end
        # Set label AFTER slider value might have been clamped/set
        tLabel_text[] = "t = $(round(tSlider.value[], digits=3))"

    # --- Inside Lift Block 1 ---
    # ... (AFTER simulation loop and Time Slider update) ...

    # --- Calculate ALL Initial Snapshots and Max Values FIRST ---
    initial_xs_vectors = Vector{Vector{Float64}}(undef, active_num)
    initial_us_vectors = Vector{Vector{Float64}}(undef, active_num)
    initial_x_max = fill(NaN, active_num)
    initial_u_max = fill(NaN, active_num)
    current_t = tSlider.value[] # Use the final set value

    for i = 1:active_num
        # Default to empty/NaN
        x_init_snap = Float64[]; u_init_snap = Float64[]
        x_max_init = NaN; u_max_init = NaN

        if i <= length(tData[]) && !isempty(tData[][i][]) # Check data loaded
            t_vec = tData[][i][]; x_vecs = xData[][i][]; u_vecs = uData[][i][]
            if length(t_vec) == length(x_vecs) && length(t_vec) == length(u_vecs) # Check consistency
                m = findmin(a->abs(a-current_t), t_vec)[2] # Closest index
                if 1 <= m <= length(x_vecs) # Check index validity
                    x_init_snap = x_vecs[m]; u_init_snap = u_vecs[m]
                    if !isempty(u_init_snap) # Calculate max if valid
                        try; u_max_val,max_idx=findmax(u_init_snap); if isfinite(u_max_val) && 1<=max_idx<=length(x_init_snap); x_max_init=x_init_snap[max_idx]; u_max_init=u_max_val; end; catch; end
                    end
                end
            else; @warn "Inconsistent time steps vs data in Lift 1 for method $i."; end
        end
        initial_xs_vectors[i] = x_init_snap
        initial_us_vectors[i] = u_init_snap
        initial_x_max[i] = x_max_init
        initial_u_max[i] = u_max_init
    end
    # --- End Initial Snapshot/Max Calculation Loop ---

    # --- Update Observables AFTER loop ---
    # Update max values first
    for i = 1:active_num
        if i <= length(x_at_max_obs[]); x_at_max_obs[][i][] = initial_x_max[i]; end
        if i <= length(u_at_max_obs[]); u_at_max_obs[][i][] = initial_u_max[i]; end
    end
    # Then update snapshot values
    for i = 1:active_num
        if i <= length(xs[]); xs[][i][] = initial_xs_vectors[i]; end
        if i <= length(us[]); us[][i][] = initial_us_vectors[i]; end
    end
    # --- End Observable Updates ---

    println("Lift 1: Update complete.")

    end # --- End Lift Block 1 ---


    # --- Lift Block 2 (MODIFIED: Calculate and update max observables) ---
    lift(tSlider.value; ignore_equal_values=false) do t#, xd_obs, ud_obs, td_obs
        # Get inner vectors
        xd = to_value(xData); ud = to_value(uData); td = to_value(tData)
        active_num = method_number[]
        # Consistency check (include new observables)
        if length(xs[])!=active_num || length(us[])!=active_num || length(xd)!=active_num || length(ud)!=active_num || length(td)!=active_num || length(x_at_max_obs[])!=active_num || length(u_at_max_obs[])!=active_num; return; end

        tLabel_text[] = "t = $(round(t, digits=3))"; ax.title = "t=$(round(t, digits=3))"

        for i = 1:active_num # Iterate through active methods
             if i > length(xd) || i > length(ud) || i > length(td); continue; end # Index check
             x_vecs = xd[i][]; u_vecs = ud[i][]; t_vec = td[i][]

             local x_snapshot::Vector{Float64} = Float64[]; local u_snapshot::Vector{Float64} = Float64[]

             # Get snapshot using closest time step logic
             if !isempty(t_vec) && length(t_vec)==length(x_vecs) && length(t_vec)==length(u_vecs)
                 (_, m) = findmin(a -> abs(a - t), t_vec)
                 if 1 <= m <= length(x_vecs); x_snapshot = x_vecs[m]; u_snapshot = u_vecs[m]; end
             end

             # Update snapshot observables
             if i <= length(xs[]) && i <= length(us[]); xs[][i][] = x_snapshot; us[][i][] = u_snapshot; end

             # --- Calculate and Update Max Observables ---
             if !isempty(u_snapshot) && i <= length(x_at_max_obs[]) && i <= length(u_at_max_obs[])
                 try
                     u_max_val, max_idx = findmax(u_snapshot)
                     if isfinite(u_max_val) && 1 <= max_idx <= length(x_snapshot)
                         x_at_max_obs[][i][] = x_snapshot[max_idx]
                         u_at_max_obs[][i][] = u_max_val
                     else; x_at_max_obs[][i][] = NaN; u_at_max_obs[][i][] = NaN; end
                 catch e; @warn "findmax failed: $e"; x_at_max_obs[][i][] = NaN; u_at_max_obs[][i][] = NaN; end
             else # Empty snapshot or invalid index for max obs
                 if i <= length(x_at_max_obs[]) && i <= length(u_at_max_obs[]); x_at_max_obs[][i][] = NaN; u_at_max_obs[][i][] = NaN; end
             end
             # ---------------------------------------------
        end # End loop over methods
    end # --- End Lift Block 2 ---


    # --- Lift Block 3 (Plot Management - ADDED Max Tracking) ---
    # Trigger depends on method changes, snapshot data, AND track_max toggle
    #lift(method_number, tSlider.value, xs, us, track_max_obs, x_at_max_obs, u_at_max_obs; ignore_equal_values=true) do active_num, _, current_xs_obsvec, current_us_obsvec, track_max_enabled, current_x_max_obsvec, current_u_max_obsvec
    lift(update_notifier, tSlider.value) do _...
        empty!(ax) # Clear previous plots
        # Clear legend explicitly targeting cell [1, 2]
        try; existing_legend=filter(c->isa(c, Legend), contents(plot_fig[1, 2])); foreach(delete!, existing_legend); catch e; @warn "Could not clear legend cell: $e"; end

        active_methods = methods_obs[]
        active_num = length(active_methods)
        current_xs_obsvec = xs[]
        current_us_obsvec = us[]
        if active_num == 0; return; end # Nothing to plot

        # Consistency check
        num_to_plot = min(active_num, length(current_xs_obsvec), length(current_us_obsvec))
        if num_to_plot != active_num; @warn "Lift 3: Data series mismatch. Plotting $num_to_plot series."; end
        if num_to_plot <= 0; return; end

        plotted_objects = [] # For legend
        for i = 1:num_to_plot
            plotLabel = active_methods[i]
            # Get styles for this method
            color = local_ui_dict["colors"][mod1(i, length(local_ui_dict["colors"]))]
            marker = local_ui_dict["markers"][mod1(i, length(local_ui_dict["markers"]))]
            linestyle = get(local_ui_dict, "dashed_lines", false) ? local_ui_dict["lineStyles"][mod1(i, length(local_ui_dict["lineStyles"]))] : :solid

            # Access the snapshot observables for plotting
            x_snap_obs = current_xs_obsvec[i]
            u_snap_obs = current_us_obsvec[i]

            # --- Plot main data (Lines/Scatter) ---
            obj_for_legend = nothing
            # Use get for ui_dict keys for safety
            if get(local_ui_dict, "show_lines", true)
                 l = lines!(ax, x_snap_obs[], u_snap_obs[]; color=color, linewidth=get(local_ui_dict,"linewidth", 1.5), label=plotLabel, linestyle=linestyle)
                 obj_for_legend = l
            end
            if get(local_ui_dict, "show_scatter", true)
                 s = scatter!(ax, x_snap_obs[], u_snap_obs[]; color=color, markersize=get(local_ui_dict,"markersize", 8), marker=marker, label=plotLabel)
                 # Only add scatter to legend items if lines weren't plotted or legend is empty
                 if obj_for_legend === nothing; obj_for_legend = s; end
            end
            if obj_for_legend !== nothing; push!(plotted_objects, obj_for_legend); end
            # ------------------------------------

            # --- Plot Max Tracking Line (using observables from arguments) ---
            if track_max_obs[] # Check toggle state passed into lift block
                # Ensure index i is valid for the max observable vectors passed in
                current_x_max_obsvec = x_at_max_obs[]
                current_u_max_obsvec = u_at_max_obs[]
                if i <= length(current_x_max_obsvec) && i <= length(current_u_max_obsvec)
                   # Access the observables holding max info for method i from the arguments
                   x_max_pos_obs = current_x_max_obsvec[i] # This is Observable{Float64}
                   u_max_val_obs = current_u_max_obsvec[i] # This is Observable{Float64}

                   # Define reactive points for the line segment using lift
                   start_point = lift(x_max_pos_obs; ignore_equal_values=true) do x_max
                        Point2f(isfinite(x_max) ? x_max : NaN, 0)
                   end
                   end_point = lift(x_max_pos_obs, u_max_val_obs; ignore_equal_values=true) do x_max, u_max
                        Point2f(isfinite(x_max) && isfinite(u_max) ? x_max : NaN, isfinite(u_max) ? u_max : NaN)
                   end

                   # Plot the line segment reactively if points are finite
                   linesegments!(ax, lift((s, e) -> isfinite(s[1]) && isfinite(e[1]) && isfinite(e[2]) ? [s, e] : Point2f[], start_point, end_point);
                                  color = (color, 0.75), # Use method color, slightly transparent
                                  linestyle = :dash,
                                  linewidth = ui_dict["linewidth"]/2)
               end # End index check
           end # End if track_max_enabled
           # --- End Max Tracking Line ---

        end # End loop over methods

        # Add Legend (as before)
        if !isempty(plotted_objects)
             try
                 # Clear just in case before adding new one
                 for c in contents(plot_fig.layout); if isa(c, Legend) && c.layout_position == (1, 2); delete!(c); end; end
                 Legend(plot_fig[1, 2], plotted_objects, active_methods[1:num_to_plot], "Methods", tellheight=false)
                 colsize!(plot_fig.layout, 2, Auto()) # Adjust column width
             catch e; @error "Error adding Legend" exception=(e, catch_backtrace()); end
        end

    end # --- End Lift Block 3 ---


    # --- Animation Button Logic (Using real-time mapping) ---
    on(play_button.clicks) do _
        new_state = !is_animating[]
        if new_state # --- Request Start Animation ---
            if !isnothing(animation_timer[]); try close(animation_timer[]) catch; end; animation_timer[] = nothing; end
            t_min, t_max = time_range_data[]; if !(t_max > t_min); println("Cannot animate: Invalid time range."); return; end
            is_animating[] = true

            anim_duration_s = get(local_ui_dict, "animation_duration_s", 5.0) # Use value from dict
            anim_fps = get(local_ui_dict, "animation_fps", 30)
            timer_interval = 1.0 / max(1, anim_fps)
            start_real_time = time()
            #anim_time_ref = Ref(t_min) # Start animation from the beginning

            function update_frame(timer_handle)
                # Check if stopped externally
                if !is_animating[]; try close(timer_handle) catch; end; animation_timer[] = nothing; return; end
                # Calculate simulation time based on real time elapsed
                elapsed_real_time = time() - start_real_time
                cycled_elapsed_time = mod(elapsed_real_time, anim_duration_s)
                time_fraction = cycled_elapsed_time / anim_duration_s
                current_sim_time = t_min + time_fraction * (t_max - t_min)
                # Update slider value (triggers Lift 2)
                set_close_to!(tSlider, clamp(current_sim_time, t_min, t_max))
            end

            println("Starting animation (Duration: $(anim_duration_s)s, Target FPS: $anim_fps)...")
            # Start timer immediately, repeat at interval
            animation_timer[] = Timer(update_frame, 0.0, interval=max(0.01, timer_interval))

        else # --- Request Stop Animation ---
            println("Stopping animation...")
            if !isnothing(animation_timer[]); try close(animation_timer[]) catch; end; animation_timer[] = nothing; end
            is_animating[] = false
            # Nudge Lift 2 to ensure final state matches slider using non-animating logic
            set_close_to!(tSlider, tSlider.value[])
        end
    end
    # --- End Animation Button Logic ---

    # --- GIF Saving Button Logic (using saveParametersToCSV) ---
    on(gif_save_button.clicks) do _
        base_filename = string(strip(gif_save_textbox.stored_string[]))
        if isempty(base_filename); @warn "Enter GIF filename."; return; end

        save_dir = joinpath(Utils.get_save_path(), "figures")
        try mkpath(save_dir) catch e; @warn "Could not create dir: $e"; end
        gif_filename = joinpath(save_dir, base_filename * ".gif")

        println("Preparing GIF: $gif_filename and Parameters...")

        # === Call reusable function to save Parameters ===
        anim_info = Dict(
            "Save Type" => "Animation GIF",
            "Timestamp" => string(Dates.now()),
            "Animation Time Range" => string(time_range_data[]),
            "Animation Duration (s)" => string(get(local_ui_dict, "animation_duration_s", 5.0)),
            "Animation FPS" => string(get(local_ui_dict, "animation_fps", 30)),
            "Save Trigger Time (t)" => string(round(tSlider.value[], digits=4))
            # Add other relevant info?
        )
        save_success = saveParametersToCSV( # Call the new function
                            base_filename,
                            save_dir,
                            shared_params_obs,
                            method_params_collection_obs,
                            methods_obs,
                            anim_info
                    )
        if !save_success; @warn "Parameter CSV saving failed for $base_filename. Continuing with GIF..."; end
        # =================================================

        # Stop interactive animation if running
        was_animating = is_animating[]
        if was_animating; if !isnothing(animation_timer[]); try close(animation_timer[]) catch; end; animation_timer[] = nothing; end; is_animating[] = false; sleep(0.1); end

        # Get parameters for saving GIF
        t_min, t_max = time_range_data[]; if !(t_max > t_min); println("Cannot save GIF: Invalid time range."); if was_animating; is_animating[]=true; end; return; end
        duration_s = get(local_ui_dict, "animation_duration_s", 5.0); fps = get(local_ui_dict, "animation_fps", 30); n_frames = round(Int, duration_s * fps); if n_frames <= 0; n_frames = 100; end
        times_for_gif = range(t_min, t_max, length=n_frames)

        # --- Record the animation ---
        try
            println("Recording $n_frames frames at $fps FPS... (Window may close)")
            xlims!(ax, global_xlims[]); ylims!(ax, global_ylims[]) # Use fixed limits

            record(plot_fig, gif_filename, times_for_gif; framerate = fps) do t_now
                set_close_to!(tSlider, t_now) # Update plot state via Lift 2
                yield() # Allow Makie to process events and redraw
            end
            println("Animation saved successfully to $gif_filename")
        catch e; @error "Failed to save GIF animation!" exception=(e, catch_backtrace());
        finally; println("GIF saving process finished."); end
        # --------------------------
    end
    # --- End GIF Saving Logic ---


    # --- Timer Cleanup on Figure Close ---
    on(plot_fig.scene.events.window_open) do is_open
        # Stop timer if figure closes
        if !is_open && !isnothing(animation_timer[]); try close(animation_timer[]) catch; end; animation_timer[] = nothing; is_animating[] = false; end
    end

    # --- Display Figures ---
    try; display(GLMakie.Screen(), control_fig); catch e; @error "Failed displaying control_fig" exception=(e, catch_backtrace()); end
    try; display(GLMakie.Screen(), plot_fig); catch e; @error "Failed displaying plot_fig" exception=(e, catch_backtrace()); end

    return control_fig, plot_fig
end