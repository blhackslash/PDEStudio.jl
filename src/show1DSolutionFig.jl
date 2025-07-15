
"""
    show1DSolutionFig(sim_config::SimulationConfig)

Creates an interactive Makie plot for `SimData1D` with animation playback
and an option to save the animation as a GIF (which may close the window).
Saves corresponding parameters to a CSV file.
Uses closest data point logic for animation frames.
"""
function show1DSolutionFig(sim_config::SimulationConfig; ui_options::UIType = :default)

    # --- Basic Setup & UI ---
    base_ui_dict = createUIDict(ui_options)
    ui_options_obs = create_ui_observables(base_ui_dict)
    plot_fig = Figure(size = ui_options_obs["figsize"])


    # --- Parameter & Method Observables/Controls (REVISED INITIALIZATION) ---
    # Observable dictionary for SHARED parameters
    shared_params_obs, method_params_collection_obs = create_parameter_observables(sim_config)
    all_method_names = collect(keys(sim_config.methods_dict))

    # Method selection observable (no change)
    methods_obs = Observable(issubset(sim_config.default_methods,all_method_names) ? sim_config.default_methods : all_method_names)
    #methods_obs = Observable(isempty(all_method_names) ? String[] : [default_method])
    method_number = lift(length, methods_obs)


    # --- Call the NEW createControls function ---
    control_fig, update_notifier, ui_update, y_options, selector = createBaseControlsFigure(
        plot_fig,
        shared_params_obs,
        method_params_collection_obs,
        methods_obs,
        all_method_names,
        ui_options_obs
    )
    # -----------------------------------------

    # --- Time Slider & Label ---
    tLabel_text = Observable("t = 0.0")
    # Add a new row for the time label
    # --- Time Slider, Log Toggles, etc. ---
    tSlider = Slider(control_fig[end+2,:], range = 0:0)

    tLabel_text = lift(tSlider.value, tSlider.range) do val, range; 
        if range == [0]
            "t = N/A"
        else
            "t = $(round(val; digits = 3))"
        end 
    end
    Label(control_fig[end-1,:], tLabel_text)
    axis_label = lift(selector) do sel; "Solution Value ($sel)" end
    axis_title = @lift("t = " * string(round($(tSlider.value),digits = 3)))
    
    default_labels = Dict("xlabel" => "Position (x)",
                      "ylabel" => axis_label,                        
                      "title" => axis_title)
    label_obs = create_axis_label_observables(ui_options_obs, default_labels)

    ax = Axis(plot_fig[1,1], xlabel = label_obs["xlabel"], ylabel = label_obs["ylabel"], title = label_obs["title"])

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
    datatype = Vector{Vector{Float64}}
    # Outer Observable holds Vector of Inner Observables (one per method)
    xData = Observable(Vector{Tuple{datatype, Vector{Float64}}}(undef, 0)) # Full x data series
    uData = Observable(Vector{Tuple{Dict{String, Any}, Vector{Float64}}}(undef, 0)) # Full u data series
    uData_extr = Observable(Vector{Tuple{datatype, Vector{Float64}}}(undef, 0)) # Full u data series

    # ------------------------------------
    # --- Lift Block 1: Data Loading / Simulation Execution ---
    lift(update_notifier; ignore_equal_values=true) do _
        active_num = length(methods_obs[])
        println("Lift 1: Running sims / loading data...") # Concise print

        xData_tmp = Vector{Tuple{datatype, Vector{Float64}}}(undef, active_num)
        uData_tmp = Vector{Tuple{Dict{String, Any}, Vector{Float64}}}(undef, active_num)
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


            xData_tmp[i] = (sim_data.x, sim_data.t)
            
            if isa(sim_data.u[1], AbstractVector)
                key = "u"
                y_options[] = [key]
                uData_tmp[i] = (Dict(key => sim_data.u), sim_data.t)
            elseif isa(sim_data.u[1], AbstractMatrix)
                y_options[] = ["u_$j" for j = 1:length(sim_data.u[1][1,:])]
                uData_tmp[i] = (Dict("u_$j" => [sim_data.u[k][:,j] for k = eachindex(sim_data.u)] for j = 1:length(sim_data.u[1][1,:])), sim_data.t)
            end

            
            # -----------------------------
        end # End loop over methods
        
        xData[] = xData_tmp
        uData[] = uData_tmp
        update_time_slider!(tSlider,xData[])
    println("Lift 1: Update complete.")

    end # --- End Lift Block 1 ---
    lift(selector, uData) do sel, u
        if isempty(u); return; end
        uData_extr[] = extractStats(u, sel);
        set_axis_limits!(ax, xData[], uData_extr[], ui_options_obs)
        return nothing

    end
    #lift(method_number, tSlider.value, xs, us, track_max_obs, x_at_max_obs, u_at_max_obs; ignore_equal_values=true) do active_num, _, current_xs_obsvec, current_us_obsvec, track_max_enabled, current_x_max_obsvec, current_u_max_obsvec
    lift(uData_extr, tSlider.value, ui_update) do u_data, t, _

        x_snapshot, y_snapshot = calculate_snapshot(xData[], u_data, t)
        create_base_plot_1D!(plot_fig, ax, 
                             methods_obs[],
                             x_snapshot,
                             y_snapshot,
                             ui_options_obs; 
                             plot_observable = false)        
     
    end # --- End Lift Block 3 ---


    # --- Animation Button Logic (Using real-time mapping) ---
    on(play_button.clicks) do _
        new_state = !is_animating[]
        if new_state # --- Request Start Animation ---
            if !isnothing(animation_timer[]); try close(animation_timer[]) catch; end; animation_timer[] = nothing; end
            t_min, t_max = (tSlider.range[][1], tSlider.range[][end]); 
            if !(t_max > t_min); println("Cannot animate: Invalid time range."); return; end
            is_animating[] = true

            anim_duration_s = ui_options_obs["animation_duration_s"][] # Use value from dict
            anim_fps = ui_options_obs["animation_fps"][]
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
            "Animation Duration (s)" => string(ui_options_obs["animation_duration_s"]),
            "Animation FPS" => string(ui_options_obs["animation_fps"][]),
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
        duration_s = ui_options_obs["animation_duration_s"][]; fps = ui_options_obs["animation_fps"]; n_frames = round(Int, duration_s * fps); if n_frames <= 0; n_frames = 100; end
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