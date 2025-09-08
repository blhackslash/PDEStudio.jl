# """
#     show2DSolutionFig(sim_config::SimulationConfig) # Renamed internally for clarity if needed

# Creates an interactive Makie plot for `SimData2D` with animation playback
# and an option to save the animation as a GIF (which may close the window).
# Saves corresponding parameters to a CSV file.
# Uses closest data point logic for animation frames.

# Features:
# - Reuses Axis3 object for stable interactivity.
# - Auto-scaling XY limits based on current time step (driven by slider/animation).
# - Globally fixed Z limits and Color range based on full dataset.
# - Toggle between 2D scatter plot and 3D surface (meshscatter) plot.
# - Slider to select colormap dynamically.
# - Standard controls for methods, parameters.
# - Animation Play/Stop button and GIF saving.
# """
# function show2DSolutionFig(sim_config::SimulationConfig, ui_options::UIType = :default) # Keep original name

#     # --- Basic Setup & UI ---
#     base_ui_dict = createUIDict2D(ui_options)
#     ui_options_obs = Dict{String, Observable}()
#     for (key, value) in base_ui_dict
#         ui_options_obs[key] = Observable(value)
#     end
#     plot_fig = Figure(size = ui_options_obs["figsize"])

#     shared_params_obs, method_params_collection_obs = create_parameter_observables(sim_config)


#     all_method_names = collect(keys(sim_config.methods_dict))

#     # Method selection observable (no change)
#     methods_obs = Observable(issubset(sim_config.default_methods,all_method_names) ? sim_config.default_methods : all_method_names)
#     method_number = lift(length, methods_obs)

#     # --- Call the NEW createControls function ---
#     control_fig, update_notifier = createBaseControlsFigure(
#         plot_fig,
#         shared_params_obs,
#         method_params_collection_obs,
#         methods_obs,
#         all_method_names,
#         ui_options_obs
#     )
#     # -----------------------------------------
#     controls_layout = control_fig.layout # Get layout grid

#     # Time Slider & Label
#     tLabel_text = Observable("t = 0.0")
#     Label(controls_layout[end+1, 1:4], text = tLabel_text, tellwidth=false).padding = (0, 0, 5, 0) # Span controls area
#     tSlider = Slider(controls_layout[end+1, 1:4], range = 0.0:1.0, startvalue = 0.0) # Span controls area


#     sys_dim = ui_options_obs["system_dimension"][]
#     sel_comp_obs = Observable(1)
#     axis_title = Observable("t = 0.0") 
#     compLabel_text = lift(sel_comp_obs) do sel_comp
#         sys_dim > 1 ? "Component: $sel_comp / $sys_dim" : "Component: 1 / 1 (Scalar)"
#     end   
#     Label(control_fig[end+1,:], compLabel_text)
#     if sys_dim > 1
#         component_slider = Slider(control_fig[end+1,:], range = 1:sys_dim, startvalue = 1)
#         on(component_slider.value) do val
#             sel_comp_obs[] = round(Int, val)
#         end
#     end
#     # This new observable creates the correct default zlabel based on context
#     dynamic_zlabel_default_obs = lift(sel_comp_obs, ui_options_obs["plot_as_surface"]) do comp, is_surface
#         if is_surface
#             # For a 3D surface plot, the z-axis represents the component's value
#             return "Solution Value u$(comp)"
#         else
#             # For a 2D top-down view, the z-axis is not shown, so the label should be empty.
#             return "" 
#         end
#     end
#     default_labels = Dict("xlabel" => "x",
#                           "ylabel" => "Test",
#                           "zlabel" => dynamic_zlabel_default_obs,
#                           "colorbar_label" => (lift(sel_comp_obs) do sel; "Solution Value u$sel" end),
#                           "title" => axis_title)
#     labels_obs = create_axis_label_observables(ui_options_obs, default_labels)
#     ax = Axis3(plot_fig[1, 2], 
#                 xlabel=labels_obs["xlabel"],                
#                 ylabel=labels_obs["ylabel"],
#                 zlabel=labels_obs["zlabel"],
#                 title = labels_obs["title"]) # Title set dynamically

#     # # Plot Type Toggle
#     # plot_toggle_layout = controls_layout[end+1, :] = GridLayout() # Span controls area
#     # plot_as_surface_obs = Observable(get(local_ui_dict, "plot_as_surface", false))
#     # Label(plot_toggle_layout[1, 1], "Plot as Surface (3D)") # Span 2 cols for label
#     # toggle_plot_type = Toggle(plot_toggle_layout[1, 2], active = plot_as_surface_obs[]) # Place toggle in col 3
#     # on(toggle_plot_type.active) do active_state; plot_as_surface_obs[] = active_state; end

#     # Colormap Slider
#     #cmap_layout = controls_layout[end+1, :] = GridLayout() # Span controls area
#     available_cmaps = ui_options_obs["colormaps"][]
#     default_cmap = ui_options_obs["colormap"][]
#     default_cmap_idx = findfirst(isequal(default_cmap), available_cmaps); if isnothing(default_cmap_idx); default_cmap_idx = 1; end
#     selected_colormap_obs = Observable(available_cmaps[default_cmap_idx])
#     cmap_menu = Menu(control_fig[end+1, :], options = available_cmaps, default = default_cmap_idx) # Slider spans 2 cols
#     #cmap_label = Label(cmap_layout[1, 2], lift(cmap -> "$cmap", cmap_menu.selection), width=Auto(), halign=:left) # Label spans 2 cols
#     on(cmap_menu.selection) do cmap; selected_colormap_obs[] = cmap end#available_cmaps[idx]; end

#     # --- Animation and GIF Saving Controls (Copied from 1D version) ---
#     anim_save_controls_row = controls_layout[end+1, 1:4] = GridLayout() # Span controls area
#     # Animation State/Controls
#     is_animating = Observable(false)
#     animation_timer = Ref{Union{Timer, Nothing}}(nothing)
#     time_range_data = Ref((0.0, 1.0)) # Stores (t_min, t_max) from actual data
#     play_button = Button(anim_save_controls_row[1, 1], label = @lift($is_animating ? "Stop Anim" : "Play Anim")) # Col 1
#     # GIF Saving Textbox
#     gif_save_textbox = Textbox(anim_save_controls_row[1, 2], placeholder = "GIF Name (no ext)", width=150) # Col 2
#     gif_save_textbox.stored_string = "untitled_anim_2D" # Set default filename
#     # GIF Saving Button
#     gif_save_button = Button(anim_save_controls_row[1, 3], label = "Save GIF") # Col 3
#     # Warning Label
#     Label(anim_save_controls_row[1, 4], text="(Window may close!)", fontsize=10, color=:darkgray, halign=:left).padding = (10,0,0,0) # Col 4
#     # Adjust column sizes
#     colsize!(anim_save_controls_row, 1, Auto()); colsize!(anim_save_controls_row, 3, Auto()); colsize!(anim_save_controls_row, 4, Auto())
#     # ---------------------------------------------

#     # --- Data Structures ---
#     xData = Observable(Vector{Observable{Vector{Vector{NTuple{2, Float64}}}}}(undef, 0))
#     uData = Observable(Vector{Observable{Vector{Vector{Float64}}}}(undef, 0))
#     tData = Observable(Vector{Observable{Vector{Float64}}}(undef, 0))
#     xs = Observable(Vector{Observable{Vector{NTuple{2, Float64}}}}(undef, 0)) # Snapshot coords
#     us = Observable(Vector{Observable{Vector{Float64}}}(undef, 0))       # Snapshot values
#     global_zlims_and_colorrange = Observable((0.0, 1.0)) # Global U range (min, max)

#     # --- Lift Block 1 (MODIFIED: Store time range) ---
#     lift(update_notifier; ignore_equal_values=true) do _
#         active_num = length(methods_obs[])
#         println("Lift 1 (2D): Updating data & global U range...")
#         # Resize outer vectors
#         resize!(xData[], active_num); resize!(uData[], active_num); resize!(tData[], active_num)
#         resize!(xs[], active_num); resize!(us[], active_num)
#         # Ensure inner observables exist
#         for k in 1:active_num
#             if !isassigned(xData[], k) || !isa(xData[][k], Observable); xData[][k] = Observable(Vector{Vector{NTuple{2,Float64}}}()); end
#             if !isassigned(uData[], k) || !isa(uData[][k], Observable); uData[][k] = Observable(Vector{Vector{Float64}}()); end
#             if !isassigned(tData[], k) || !isa(tData[][k], Observable); tData[][k] = Observable(Float64[]); end
#             if !isassigned(xs[], k) || !isa(xs[][k], Observable); xs[][k] = Observable(NTuple{2, Float64}[]); end
#             if !isassigned(us[], k) || !isa(us[][k], Observable); us[][k] = Observable(Float64[]); end
#         end

#         all_time_points = Set{Float64}()
#         g_umin, g_umax = Inf, -Inf; found_any_u_data = false
#         active_methods_now = methods_obs[]

#         for i = 1:active_num # Loop Methods
#             method = active_methods_now[i]
#             # --- Assemble Parameters using Helper ---
#             params = assembleParams(
#                 shared_params_obs,          # Pass the observable dict
#                 method_params_collection_obs, # Pass the nested observable dict
#                 method
#             )
#             # ------------------------------------

#             # --- Load or Compute Data ---
#             local sim_data::Union{AbstractSimData, Nothing} = nothing
#             try
#                 # Assumes existence of Utils.doesSimDataExist and Utils.loadSimData
#                 if !Utils.doesSimDataExist(params)
#                      println(" Running simulation for method: $method")
#                      sim_data = sim_config.sim_function(params)
#                      Utils.saveSimData(sim_data) # Assumes saveSimData exists
#                 else
#                      println(" Loading data for method: $method")
#                      sim_data = Utils.loadSimData(params)
#                 end
#             catch e
#                  @warn "Simulation/Load failed for method '$method'" exception=(e, catch_backtrace())
#                  sim_data = nothing
#             end
#             # --------------------------

#             if isnothing(sim_data) || !isa(sim_data, SimData2D); @warn "Invalid SimData2D '$method'."; xData[][i][]=[]; uData[][i][]=[]; tData[][i][]=[]; xs[][i][]=[]; us[][i][]=[]; continue; end
#             # Store Data
#             xData[][i][] = sim_data.x; uData[][i][] = sim_data.u; tData[][i][] = sim_data.t; union!(all_time_points, sim_data.t)
#             # Update Global U limits
#             for k in eachindex(sim_data.t); if k <= length(sim_data.u); u_k=sim_data.u[k]; if !isempty(u_k); found_any_u_data=true; umnk,umxk=extrema(u_k); g_umin=min(g_umin,umnk); g_umax=max(g_umax,umxk); end; end; end
#         end # End method loop

#         # Finalize and Store Global Z Limits / Color Range
#         if found_any_u_data; pad_fac=ui_options_obs["axis_limit_padding"][]; zr=g_umax-g_umin; zp=zr*pad_fac/2.0; zp=(zp<=1e-6 && zr<=1e-6) ? 0.1 : zp; final_zlims=(g_umin-zp, g_umax+zp); global_zlims_and_colorrange[]=final_zlims; else; global_zlims_and_colorrange[]=(0.0, 1.0); end
#         println("Lift 1 (2D): Global Z/Color range: $(global_zlims_and_colorrange[])")

#         # --- Store Time Range and Update Time Slider ---
#         local t_min_data, t_max_data
#         if !isempty(all_time_points)
#             t_min_data, t_max_data = extrema(all_time_points)
#             time_range_data[] = (t_min_data, t_max_data) # Store for animation
#             sorted_times = sort(collect(all_time_points)); t_len = length(sorted_times)
#             t_range_slider = range(t_min_data, stop=t_max_data, length=max(2, t_len*2+100))
#             if t_len == 1; t_range_slider = range(t_min_data, stop=t_max_data, length=2); end
#             if tSlider.range[] != t_range_slider; tSlider.range = t_range_slider; end
#             current_t_val = clamp(tSlider.value[], t_min_data, t_max_data)
#         else
#             t_min_data, t_max_data = 0.0, 1.0
#             time_range_data[] = (t_min_data, t_max_data)
#             if tSlider.range[] != (0.0:1.0); tSlider.range = 0.0:1.0; end
#             current_t_val = 0.0
#         end
#         # Set slider value using set_close_to! AFTER calculating initial snapshot below
#         initial_t = current_t_val
#         # ---------------------------------------------

#         # --- Calculate Initial Snapshot ---
#         for i = 1:active_num
#              if i > length(tData[]) || isempty(tData[][i][]); xs[][i][]=[]; us[][i][]=[]; continue; end
#              t_vec = tData[][i][]; x_vecs = xData[][i][]; u_vecs = uData[][i][]
#              m = findmin(a->abs(a-initial_t), t_vec)[2]
#              if 1 <= m <= length(x_vecs) && 1 <= m <= length(u_vecs); xs[][i][] = x_vecs[m]; us[][i][] = u_vecs[m]; else; xs[][i][]=[]; us[][i][]=[]; end
#         end
#         # --- End Initial Snapshot ---

#         # Set slider value now, which might trigger Lift 2 if value changed
#         set_close_to!(tSlider, initial_t)
#         tLabel_text[] = "t = $(round(initial_t, digits=3))"
        

#         println("Lift 1 (2D): Update complete.")
#     end # --- End Lift Block 1 ---


#     # --- Lift Block 2 (Time Slider Updates - Uses Closest Point) ---
#     # UNCHANGED from user's original version - it already does what's needed
#     lift(tSlider.value) do t
#         tLabel_text[] = "t = $(round(t, digits=3))"; axis_title[] = "t=$(round(t, digits=3))"
#         # Consistency check
#         active_num = method_number[]
#         if isempty(xs[]) || isempty(tData[]) || length(xs[]) != active_num; return; end

#         for i = 1:active_num # Use active_num for loop bound
#             # Ensure index validity before access
#             if i > length(tData[]) || i > length(xData[]) || i > length(uData[]) || i > length(xs[]) || i > length(us[]); continue; end
#             current_times = tData[][i][]; if isempty(current_times); xs[][i][] = []; us[][i][] = []; continue; end

#             (_, m) = findmin(a -> abs(a - t), current_times)
#             # Ensure m is valid for *all* data vectors for safety
#             if m > 0 && m <= length(xData[][i][]) && m <= length(uData[][i][])
#                  xs[][i][] = xData[][i][][m]; us[][i][] = uData[][i][][m]
#             else; xs[][i][] = NTuple{2, Float64}[]; us[][i][] = Float64[]; end
#         end

#         # Adjust XY limits automatically for current frame, fix Z limit
#         try; autolimits!(ax); catch e; @warn "autolimits! failed in Lift 2" exc=e; end
#         try; zlims!(ax, global_zlims_and_colorrange[]...); catch e; @warn "Failed applying zlims in Lift 2" exc=e; end
#     end # --- End Lift Block 2 ---


#     # --- Lift Block 3 (Plot Redraw & Configuration) ---
#     lift(update_notifier, selected_colormap_obs,
#         global_zlims_and_colorrange;
#         ignore_equal_values=true) do _, current_cmap, current_zlims_val
#         active_num = length(methods_obs[])
#         println("Lift 3 (2D): Redrawing plot...")
#         active_methods = methods_obs[] # Define active_methods here

#         empty!(ax); needs_colorbar_update = false
#         # Clear legend/colorbar robustly
#         try; delete!.(filter(c->isa(c,Legend), contents(plot_fig[1,2]))); catch e; @warn "Could not clear legend: $e"; end
#         try; existing_cb=filter(c->isa(c,Colorbar), contents(plot_fig[1,3])); if !isempty(existing_cb); needs_colorbar_update=true; delete!.(existing_cb); end; catch e; @warn "Could not clear colorbar: $e"; end

#         set_axis_styles!(ax, ui_options_obs)

#     # (Fix Z Limits as before)
#     try; zlims!(ax, current_zlims_val...); catch e; @warn "Failed applying zlims in Lift 3" exc=e; end
#     if active_num == 0; return; end # Handle no methods

#     color_range = current_zlims_val

#     # --- Plot data loop ---
#     plotted_objects = []
#     plotted_labels = String[] # <<< Initialize list for labels of plotted items

#     num_to_plot = min(active_num, length(xs[]), length(us[])); if num_to_plot != active_num; @warn "Lift 3 Plot data mismatch"; end; if num_to_plot <= 0; return; end

#     for i = 1:num_to_plot
#     if i > length(active_methods); continue; end # Safety check
#     current_plot_label = active_methods[i] # Get potential label

#     x_snapshot_obs = xs[][i]; u_snapshot_obs = us[][i]
#     # Skip if snapshot data is empty for this method
#     if isempty(x_snapshot_obs[]) || isempty(u_snapshot_obs[]) continue end

#     # (lift points_xyz, points_xy0, color_values - as before)
#     points_xyz=lift((x,u)->[Point3f(x[j][1],x[j][2],u[j]) for j in 1:min(length(x),length(u))],x_snapshot_obs,u_snapshot_obs); points_xy0=lift(x->[Point3f(pt[1],pt[2],0.0f0) for pt in x],x_snapshot_obs); color_values=u_snapshot_obs

#     plt_obj=nothing; marker_size_3d=ui_options_obs["markersize_3d"]; markersize_2d=ui_options_obs["markersize_2d"]
#     # Plot meshscatter! or scatter!
#     if ui_options_obs["plot_as_surface"][]
#         plt_obj = meshscatter!(ax, points_xyz; markersize=ui_options_obs["markersize_3d"], color=color_values, colormap=current_cmap, colorrange=color_range, label=current_plot_label) # Pass label here
#     else
#         plt_obj = scatter!(ax, points_xy0; markersize=ui_options_obs["markersize_2d"], color=color_values, colormap=current_cmap, colorrange=color_range, label=current_plot_label) # Pass label here
#     end

#     # --- Store object AND label if plot was successful ---
#     if plt_obj !== nothing
#         push!(plotted_objects, plt_obj)
#         push!(plotted_labels, current_plot_label) # <<< Store the corresponding label
#     end
#     # ---------------------------------------------------
#     end
#     # --- End plot data loop ---

#     # --- Add Legend/Colorbar (using the filtered lists) ---
#     if !isempty(plotted_objects) # Check if anything was actually plotted
#         try
#             delete!.(filter(c->isa(c, Legend), contents(plot_fig[1, 1]))) # Clear first
#             # Use plotted_labels (guaranteed same length as plotted_objects)
#             Legend(plot_fig[1, 1], plotted_objects, plotted_labels, "Methods", tellheight=false) # <<< Use plotted_labels
#             # Set fixed or relative size for legend column instead of Auto for width control
#             # Or: colsize!(plot_fig.layout, 2, Relative(0.15)) # Use 15% of available width
#         catch e; @error "Error adding Legend" exc=e; end
#     end
#     # (Add/update colorbar logic remains the same)
#     if active_num > 0 || needs_colorbar_update; 
#         try; 
#             delete!.(filter(c->isa(c,Colorbar), contents(plot_fig[1,3]))); 
#             Colorbar(plot_fig[1, 3], limits=color_range, colormap=current_cmap, label=labels_obs["colorbar_label"], width=25, ticklabelsize=ui_options_obs["ticklabel_size"]); 
#             colsize!(plot_fig.layout, 3, Auto()); 
#         catch e; 
#             @error "Error adding Colorbar" exc=e; 
#         end; 
#     end
#     # ---------------------------------------------
#             # --- SET COLUMN SIZES ---
#     colsize!(plot_fig.layout, 1, Auto())        # Column 1 (Legend): Size based on content
#     colsize!(plot_fig.layout, 2, Auto())        # Column 3 (Colorbar): Size based on content
#     colsize!(plot_fig.layout, 3, Auto()) # Column 2 (Plot): Takes remaining space
# end # --- End Lift Block 3 ---


#     # --- Animation Button Logic (Copied from 1D version) ---
#     on(play_button.clicks) do _
#         new_state = !is_animating[]
#         if new_state # Start Anim
#             if !isnothing(animation_timer[]); try close(animation_timer[]) catch; end; animation_timer[]=nothing; end
#             t_min, t_max = time_range_data[]; if !(t_max > t_min); println("Cannot animate: Invalid time range."); return; end
#             is_animating[] = true
#             anim_duration_s = ui_options_obs["animation_duration_s"][] # Use 2D dict value
#             anim_fps = ui_options_obs["animation_fps"][]
#             timer_interval = 1.0 / max(1, anim_fps)
#             start_real_time = time()
#             function update_frame(th); if !is_animating[]; try close(th) catch; end; animation_timer[]=nothing; return; end; ert=time()-start_real_time; cet=mod(ert,anim_duration_s); tf=cet/anim_duration_s; cst=t_min+tf*(t_max-t_min); set_close_to!(tSlider, clamp(cst,t_min,t_max)); end
#             println("Starting animation...")
#             animation_timer[] = Timer(update_frame, 0.0, interval=max(0.01, timer_interval))
#         else # Stop Anim
#             println("Stopping animation..."); if !isnothing(animation_timer[]); try close(animation_timer[]) catch; end; animation_timer[]=nothing; end
#             is_animating[] = false; set_close_to!(tSlider, tSlider.value[]) # Nudge Lift 2
#         end
#     end # --- End Animation Button Logic ---


#     # --- GIF Saving Button Logic (Using saveParametersToCSV) ---
#     on(gif_save_button.clicks) do _
#         base_filename = string(strip(gif_save_textbox.stored_string[]))
#         if isempty(base_filename)
#             @warn "Enter GIF filename."
#             return
#         end

#         # Construct paths
#         save_dir = joinpath(Utils.get_save_path(), "figures") # Use Utils module path
#         try mkpath(save_dir) catch e; @warn "Could not create directory $save_dir: $e"; end
#         gif_filename = joinpath(save_dir, base_filename * ".gif")
#         # CSV filename is handled inside the helper function now

#         println("Preparing 2D GIF: $gif_filename and Parameters...")

#         # === Call reusable function to save Parameters ===
#         # Create context dictionary with 2D-specific info
#         optional_save_info = Dict{String, Any}(
#             "Save Type"                => "Animation GIF (2D)",
#             "Timestamp"                => string(Dates.now()),
#             "Plot Type Request"        => ui_options_obs["plot_as_surface"][] ? "Surface (3D)" : "Scatter (2D)", # State of the toggle
#             "Colormap Selection"       => string(selected_colormap_obs[]), # State of colormap
#             # Methods list will be saved by the helper function based on methods_obs
#             "Animation Time Range"     => string(time_range_data[]),
#             "Animation Duration (s)" => string(ui_options_obs["animation_duration_s"][]), # Use 2D default if different
#             "Animation FPS"            => string(ui_options_obs["animation_fps", 30][]),
#             "Save Trigger Time (t)"    => string(round(tSlider.value[], digits=4))
#             # Add any other relevant context here
#         )

#         # Call the reusable function
#         # !!! Assumes shared_params_obs and method_params_collection_obs are defined
#         # in the scope of show2DSolutionFig according to the new structure !!!
#         save_success = saveParametersToCSV(
#                         base_filename,
#                         save_dir,
#                         shared_params_obs,            # Pass shared observables
#                         method_params_collection_obs, # Pass method-specific observables collection
#                         methods_obs,                  # Pass active methods observable
#                         optional_save_info
#                     )

#         if !save_success
#             @warn "Parameter CSV saving failed for $base_filename. Stopping GIF save."
#             # Decide if you want to stop GIF recording if CSV fails
#             return # Stop GIF recording if CSV fails
#         end
#         # ==============================================

#         # --- Proceed with GIF Recording ---
#         # Stop interactive animation if running
#         was_animating = is_animating[]
#         if was_animating
#             if !isnothing(animation_timer[]); try close(animation_timer[]) catch; end; animation_timer[] = nothing; end
#             is_animating[] = false
#             sleep(0.1) # Brief pause
#         end

#         # Get parameters for saving GIF
#         t_min, t_max = time_range_data[]
#         if !(t_max > t_min)
#             println("Cannot save GIF: Invalid time range ($t_min, $t_max).")
#             if was_animating; is_animating[]=true; end # Optionally restart animation?
#             return
#         end
#         duration_s = ui_options_obs["animation_duration_s"][] # Use 2D dict default
#         fps = ui_options_obs["animation_fps"][]
#         n_frames = round(Int, duration_s * fps); if n_frames <= 0; n_frames = 100; end
#         times_for_gif = range(t_min, t_max, length=n_frames)

#         # --- Record the animation ---
#         try
#             println("Recording $n_frames frames at $fps FPS... (Window may close)")
#             # Note: Lift 2 controls XY autolimits and fixed Z limits per frame
#             record(plot_fig, gif_filename, times_for_gif; framerate = fps) do t_now
#                 set_close_to!(tSlider, t_now) # Trigger Lift 2 update
#                 yield() # Allow Makie to process events and redraw
#             end
#             println("Animation saved successfully to $gif_filename")
#         catch e
#             @error "Failed to save GIF animation!" exception=(e, catch_backtrace())
#         finally
#             println("GIF saving process finished.")
#             # Leave animation stopped for simplicity
#         end
#         # -----------------------------
#     end
#     # --- End GIF Saving Logic ---


#     # --- Timer Cleanup on Figure Close ---
#     on(plot_fig.scene.events.window_open) do is_open
#         if !is_open && !isnothing(animation_timer[]); try close(animation_timer[]) catch; end; animation_timer[] = nothing; is_animating[] = false; end
#     end


#     # --- Display Figures ---
#     try; display(GLMakie.Screen(), control_fig); catch e; @error "Failed displaying control_fig" exception=(e, catch_backtrace()); end
#     try; display(GLMakie.Screen(), plot_fig); catch e; @error "Failed displaying plot_fig" exception=(e, catch_backtrace()); end

#     return control_fig, plot_fig
# end # --- End show2DSolutionFig Function ---

# """
#     show2DSolutionFig(sim_config::SimulationConfig; ...)

# Creates a fully interactive Makie plot for 2D simulation data. This version
# is rewritten to use the modern, modular, two-lift architecture for optimal
# performance and code clarity.
# """
# function show2DSolutionFig(sim_config::SimulationConfig; 
#     calc_stats = false, 
#     reference_function::Union{Function,Nothing} = nothing, 
#     scene_options::Dict = Dict{String,Any}(), 
#     ui_options::Symbol = :default
# )
#     # --- 1. Basic Setup & UI ---
#     base_ui_dict = GetUIStyle(ui_options) # Assumes a GetUIStyle for 2D exists or is general
#     ui_options_obs = create_ui_observables(base_ui_dict)
#     plot_fig = Figure(size = ui_options_obs["figsize"][])
#     ax = Axis3(plot_fig[1, 1]) # Use Axis3 for 2D data (surface/heatmap)
    
#     scene_default = Dict{String,Any}("t"=>0., "component" => 1)
#     scene_dict = merge(scene_options, scene_default)
#     scene_obs = createObsDict(scene_dict)
    
#     # --- 2. Parameter & Method Observables ---
#     shared_params_obs, method_params_collection_obs = create_parameter_observables(sim_config)
#     all_method_names = collect(keys(sim_config.methods_dict))
#     methods_obs = Observable(issubset(sim_config.default_methods, all_method_names) ? sim_config.default_methods : all_method_names)


#     #set_scene_options!(scene_obs, scene_options)

#     # --- 4. Create Control Figure and Animation Controls ---
#     control_fig, update_notifier, ui_update, components, comp_sel = createBaseControlsFigure(
#         plot_fig, shared_params_obs, method_params_collection_obs, methods_obs, all_method_names, ui_options_obs, scene_obs
#     )

#     tSlider = GLMakie.Slider(control_fig[end+1, 1:end], range=0:0.01:1, startvalue=scene_dict["t"])
#     comp_sel[] = scene_dict["component"]
#     # --- 3. Scene-Specific Observables for 2D Plot ---
#     connectObsDict!(scene_obs, ["t","component"],[tSlider.value,comp_sel])
    
#     ani_layout = control_fig[end+1, 1:end] = GridLayout()
#     createAnimationControls!(
#         ani_layout, plot_fig, tSlider,
#         shared_params_obs, method_params_collection_obs, methods_obs,
#         ui_options_obs, scene_obs
#     )

#     # --- 5. Data Storage Observables ---
#     xData = Observable(Vector{Any}())
#     yData = Observable(Vector{Any}())
#     uData = Observable(Vector{Any}())
#     tData = Observable(Vector{Any}())

#     # --- 6. LIFT 1: Data Loading & Simulation ---
#     # Triggered by parameter changes. This is the slow, expensive part.
#     lift(update_notifier) do _
#         println("Lift 1: Running sims / loading data...")
#         active_methods = methods_obs[]
        
#         tasks = assemble_simulation_tasks(shared_params_obs, method_params_collection_obs, active_methods)
#         ensure_sim_data_exists!(tasks, sim_config)
#         if calc_stats; calculateAllStats!(tasks, sim_config, reference_function); end
        
#         # Pre-allocate data vectors
#         num_methods = length(active_methods)
#         xData_new = Vector{Any}(undef, num_methods)
#         yData_new = Vector{Any}(undef, num_methods)
#         uData_new = Vector{Any}(undef, num_methods)
#         tData_new = Vector{Any}(undef, num_methods)
        
#         t_min_global, t_max_global = Inf, -Inf

#         for (i, method) in enumerate(active_methods)
#             params = tasks[i]
#             sim_data = loadSimData(params)
            
#             if !isnothing(sim_data)
#                 xData_new[i] = sim_data.x
#                 yData_new[i] = sim_data.y
#                 uData_new[i] = sim_data.u
#                 tData_new[i] = sim_data.t
                
#                 if !isempty(sim_data.t)
#                     t_min_global = min(t_min_global, sim_data.t[1])
#                     t_max_global = max(t_max_global, sim_data.t[end])
#                 end
#             else
#                 # Assign empty defaults if data loading fails
#                 xData_new[i], yData_new[i], uData_new[i], tData_new[i] = [], [], [], []
#             end
#         end
        
#         # Update observables to trigger the plotting lift
#         xData[] = xData_new
#         yData[] = yData_new
#         uData[] = uData_new
#         tData[] = tData_new
        
#         # Update the time slider's range and value
#         if isinf(t_min_global); t_min_global=0.0; t_max_global=1.0; end
#         tSlider.range = range(t_min_global, t_max_global, length=200)
#         tSlider.value = clamp(to_value(scene_obs["t"]), t_min_global, t_max_global)

#         println("Lift 1: Update complete.")
#     end

#     # --- 7. LIFT 2: Plotting ---
#     # Triggered by data changes, time slider, or UI tweaks. This is the fast part.
#     lift(uData, scene_obs["t"], ui_update) do u_data, t, _
#         #save_scene_info!(scene_obs, scene_info)
        
#         # Get the interpolated data snapshot for the current time `t`
#         x_snapshot, y_snapshot, u_snapshot = calculate_snapshot_2D(xData[], yData[], u_data, tData[], t)
        
#         # Call the dedicated 2D base plotting function
#         create_base_plot_2D!(
#             plot_fig, ax,
#             methods_obs[],
#             x_snapshot, y_snapshot, u_snapshot,
#             ui_options_obs
#         )
#     end

#     # --- 8. Display Figures ---
#     try; display(GLMakie.Screen(), control_fig); catch e; @error "Failed displaying control_fig" exception=(e, catch_backtrace()); end
#     try; display(GLMakie.Screen(), plot_fig); catch e; @error "Failed displaying plot_fig" exception=(e, catch_backtrace()); end
    
#     return control_fig, plot_fig
# end

"""
    show2DSolutionFig(sim_config::SimulationConfig)

Creates an interactive Makie plot for `SimData2D` with animation playback.
This version uses a modular, reactive architecture analogous to the 1D plotting functions.
"""
function show2DSolutionFig(sim_config::SimulationConfig; calc_stats = false, reference_function::Union{Function,Nothing} = nothing, scene_options::Dict = Dict{String,Any}(), ui_options::UIType = :default)

    # --- Basic Setup & UI ---
    base_ui_dict = createUIDict2D(ui_options)
    ui_options_obs = create_ui_observables(base_ui_dict)
    plot_fig = Figure(size = ui_options_obs["figsize"][])

    scene_default = Dict{String,Any}("t"=> 0., "component" => 1)
    scene_dict = merge(scene_options, scene_default)
    scene_obs = createObsDict(scene_dict)

    # --- Parameter & Method Observables ---
    shared_params_obs, method_params_collection_obs = create_parameter_observables(sim_config)
    all_method_names = collect(keys(sim_config.methods_dict))
    methods_obs = Observable(issubset(sim_config.default_methods, all_method_names) ? sim_config.default_methods : all_method_names)

    # --- Base Controls Figure ---
    control_fig, update_notifier, ui_update, components, comp_sel = createBaseControlsFigure(
        plot_fig, shared_params_obs, method_params_collection_obs, methods_obs,
        all_method_names, ui_options_obs, scene_obs
    )

    # --- 2D-Specific Controls ---
    Label(control_fig[end+1,:], "Plot Type: (Scatter / Surface)")
    plot_type_toggle = Toggle(control_fig[end+1,:], active = ui_options_obs["plot_as_surface"][])
    on(plot_type_toggle.active) do active_state
        ui_options_obs["plot_as_surface"][] = active_state
    end
    
    Label(control_fig[end+1,:], "Colormap:")
    cmap_menu = Menu(control_fig[end+1,:], options = ui_options_obs["colormaps"][])
    cmap_menu.selection[] = ui_options_obs["colormap"][]
    on(cmap_menu.selection) do cmap
        ui_options_obs["colormap"][] = cmap
    end

    #--- Time Slider & Animation Controls ---
    tSlider = GLMakie.Slider(control_fig[end+1, 1:end], range=0:0.01:1, startvalue=scene_dict["t"])
    comp_sel[] = scene_dict["component"]
    # --- 3. Scene-Specific Observables for 2D Plot ---
    connectObsDict!(scene_obs, ["t","component"],[tSlider.value,comp_sel])

    Label(control_fig[end-1,:], lift(t -> "t = $(round(t; digits=3))", tSlider.value))
    ani_layout = control_fig[end+1,:] = GridLayout()
    createAnimationControls!(ani_layout, plot_fig, tSlider, shared_params_obs, method_params_collection_obs, methods_obs, ui_options_obs, scene_obs)

    # --- Axis and Labels ---
    dynamic_zlabel = lift(comp_sel, ui_options_obs["plot_as_surface"]) do c, is_surf
        is_surf && c <= length(components[]) ? "$(components[][c])" : ""
    end
    dynamic_clabel = lift(comp_sel) do c; c <= length(components[]) ? "$(components[][c])" : "" end
    dynamic_title = lift(tSlider.value) do t; "t = $(round(t, digits=3))" end

    default_labels = Dict("xlabel" => "Position (x)", "ylabel" => "Position (y)", "zlabel" => dynamic_zlabel, "colorbar_label" => dynamic_clabel, "title" => dynamic_title)
    label_obs = create_axis_label_observables(ui_options_obs, default_labels)
    ax = Axis3(plot_fig[1,1], xlabel=label_obs["xlabel"], ylabel=label_obs["ylabel"], zlabel=label_obs["zlabel"], title=label_obs["title"])
    
    # Scene observables for saving/reloading state
    scene_obs = Dict{String,Observable}(
        "component" => comp_sel,
        "t" => tSlider.value
    )
    #set_scene_options!(scene_obs, scene_options)

    # --- Data Structures ---
    xData = Observable(Vector{Tuple{Vector{Vector{NTuple{2,Float64}}}, Vector{Float64}}}(undef, 0))
    uData = Observable(Vector{Tuple{Dict{String, Any}, Vector{Float64}}}(undef, 0))
    uData_extr = Observable(Vector{Tuple{Vector{VecOrMat}, Vector{Float64}}}(undef, 0))
    color_range = Observable((0.0, 1.0)) # Global range for color and Z-axis

    # --- LIFT BLOCK 1: Data Loading / Simulation ---
    lift(update_notifier; ignore_equal_values=true) do _
        println("Lift 1 (2D): Running sims / loading data...")
        active_methods_now = methods_obs[]
        tasks = assemble_simulation_tasks(shared_params_obs, method_params_collection_obs, active_methods_now)
        ensure_sim_data_exists!(tasks, sim_config)

        if calc_stats; calculateAllStats!(sim_config; ref_func_cont = reference_function); end

        xData_tmp = Vector{Tuple{Vector{Vector{NTuple{2,Float64}}}, Vector{Float64}}}(undef, length(tasks))
        uData_tmp = Vector{Tuple{Dict{String, Any}, Vector{Float64}}}(undef, length(tasks))
        
        g_umin, g_umax = Inf, -Inf
        first_run = true

        for (i, params) in enumerate(tasks)
            sim_data = Utils.loadSimData(params)
            if isnothing(sim_data) || !isa(sim_data, SimData2D); continue; end
            
            xData_tmp[i] = (sim_data.x, sim_data.t)
            uData_tmp[i] = (Dict("u" => sim_data.u), sim_data.t)
            
            # Update global U limits for color range
            for u_vec in sim_data.u; if !isempty(u_vec); umin_t, umax_t = extrema(u_vec); g_umin=min(g_umin, umin_t); g_umax=max(g_umax, umax_t); end; end

            # Update components menu
            if first_run && !isempty(sim_data.u) && !isempty(sim_data.u[1])
                num_comps = sim_data.u[1] isa AbstractMatrix ? size(sim_data.u[1], 2) : 1
                components[] = Tuple(["Component $k" for k = 1:num_comps])
                first_run = false
            end
        end
        
        xData[] = xData_tmp
        uData[] = uData_tmp
        update_time_slider!(tSlider, xData[])
        
        # # Finalize and store global Z limits / color range
        # pad_range = g_umax - g_umin
        # pad = ui_options_obs["axis_limit_padding"][] * (isinf(pad_range) || isnan(pad_range) ? 0.0 : pad_range) / 2.0
        # pad = (pad <= 1e-6 && pad_range <= 1e-6) ? 0.1 : pad
        # global_zlims[] = (g_umin - pad, g_umax + pad)

        println("Lift 1 (2D): Update complete.")
    end

    # --- LIFT BLOCK 2: Component Extraction ---
    lift(comp_sel, uData) do sel, u
        if isempty(u); return; end
        uData_extr[] = extractData(u, "u", sel)
        set_axis_limits!(ax, xData[], uData_extr[], ui_options_obs, color_range)
        return 
    end

    # --- LIFT BLOCK 3: Plotting ---
    lift(tSlider.value, uData_extr, ui_update) do t, u_data, _
        #save_scene_info!(scene_obs, scene_info)
        x_snapshot, u_snapshot = calculate_snapshot(xData[], u_data, t)
        
        create_base_plot_2D!(
            plot_fig, ax, methods_obs[],
            x_snapshot, u_snapshot,
            ui_options_obs,
            color_range,
            label_obs
        )
    end

    # --- Display Figures ---
    try; display(GLMakie.Screen(), control_fig); catch e; @error "Failed displaying control_fig" exception=(e, catch_backtrace()); end
    try; display(GLMakie.Screen(), plot_fig); catch e; @error "Failed displaying plot_fig" exception=(e, catch_backtrace()); end

    return nothing
end