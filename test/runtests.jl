using PDEStudio
using GLMakie
using WGLMakie
using Test
using StaticArrays
import PDEStudio: manager, EulerianPlotCache, LagrangianPlotCache, PLOT_DIM_MAP, menu_opt, EULERIAN_PLOT_STYLE_OPTIONS, plot_reference_lines!, plot_HUD!

# 1. Register the namespace so PDEStudioCore can dynamically resolve these functions
PDEStudioCore.set_target_module!(@__MODULE__)

# ==============================================================================
# --- EXPERIMENT: 1D Linear Advection (Upwind & Lax-Friedrichs) ---
# ==============================================================================

function advection_solver_1d(params::ParamDict)
    N = params[:N]
    scheme = get(params, :scheme, "upwind")
    cfl = get(params, :cfl, 0.5)
    
    L = 2π
    c = 1.0     
    
    # Strictly periodic grid (dropping the redundant endpoint at x=L)
    dx = L / N  
    dt = cfl * dx / c
    T_end = 2.0
    Nt = ceil(Int, T_end / dt) + 1
    
    x = collect(range(0.0, step=dx, length=N))
    t = collect(range(0.0, step=dt, length=Nt))
    
    # Preallocate the spacetime tensor
    u_num = fill(SVector{1, Float64}(0.0), N, Nt)
    
    # Periodic initial condition: u(x,0) = sin(x) + 2.0
    for i in 1:N
        u_num[i, 1] = SVector{1, Float64}(sin(x[i]) + 2.0)
    end
    
    # Time Marching
    for n in 1:(Nt-1)
        for i in 1:N
            im1 = i == 1 ? N : i - 1 # Wrap around cleanly
            ip1 = i == N ? 1 : i + 1 
            
            if scheme == "upwind"
                val = u_num[i, n][1] - cfl * (u_num[i, n][1] - u_num[im1, n][1])
            elseif scheme == "lax_friedrichs"
                val = 0.5 * (u_num[ip1, n][1] + u_num[im1, n][1]) - 0.5 * cfl * (u_num[ip1, n][1] - u_num[im1, n][1])
            else
                error("Unknown scheme: $scheme")
            end
            
            u_num[i, n+1] = SVector{1, Float64}(val)
        end
    end
    
    return create_sim_data(x, u_num, t, params; time_dim=:t, x_dim=:x)
end

function exact_advection(st::SVector{2, Float64})
    x, t = st[1], st[2]
    c = 1.0
    return SVector{1, Float64}(sin(x - c*t) + 2.0)
end

function exact_advection_factory(params::ParamDict)
    return (x -> exact_advection(x))
end

# ==============================================================================
# --- EXPERIMENT: 1D Lagrangian Particle Tracking ---
# ==============================================================================

function particle_solver_1d(params::ParamDict)
    N = params[:N]
    v = get(params, :v, 1.0)
    
    x0 = collect(range(0.0, 1.0, length=N))
    t = [0.0, 0.5, 1.0]
    Nt = length(t)
    
    x_traj = Vector{Vector{SVector{1, Float64}}}(undef, Nt)
    u_traj = Vector{Vector{SVector{1, Float64}}}(undef, Nt)
    
    for i in 1:Nt
        x_traj[i] = [SVector{1, Float64}(pos + v * t[i]) for pos in x0]
        # Dummy property scalar (e.g., mass or concentration = 1.0)
        u_traj[i] = [SVector{1, Float64}(1.0) for _ in x0] 
    end
    
    # Trigger the Lagrangian constructor
    return create_sim_data(x_traj, u_traj, t, params; time_dim=:t)
end

function exact_particle(st::SVector{2, Float64})
    # st = [x, t]. The exact scalar property is just 1.0.
    return SVector{1, Float64}(1.0)
end

# Define a custom pointwise field statistic for coverage
PDEStudioCore.register_stat!(:pointwise_diff, :all)
function PDEStudioCore.calc_stat(::Val{:pointwise_diff}, fixed_coords, u, ana, domain::DomainInfo)
    # The Lagrangian field evaluator passes 1-element tuples for specific particles
    return u[1] - ana[1]
end


function dummy_tuple_solver(params::ParamDict)
    Nx, Ny = params[:Ns]
    x = collect(range(0.0, 1.0, length=Nx))
    t = [0.0, 0.1]
    u = fill(SVector{1, Float64}(1.0), Nx, length(t))
    return create_sim_data(x, u, t, params; time_dim=:t)
end
# ==============================================================================
# --- TEST SUITE ---
# ==============================================================================
@testset "PDEStudio: UI Rendering Integration" begin
    # 0. Setup Temporary Environment & 3D Simulation Sweep
    set_stat_preset!("hyperbolic")
    set_save_path!(mktempdir())
    @test isnothing(reset_manager!())
    set_mode!(:eulerian)

    GLMakie.activate!()

    shared = create_param_dict(:cfl => 0.5, :N => 200)
    methods = create_method_dict(:upwind => create_param_dict(:scheme => "upwind"),:lax_friedrichs => create_param_dict(:scheme => "lax_friedrichs"))
    # Creating a parameter sweep adds a 3rd dimension (x, t, cfl) for the 3D plot tests
    varied = create_varied_dict(:cfl => [0.2, 0.4, 0.5]) 

    config = SimulationConfig(
        "advection_solver_1d", shared, methods, [:upwind,:lax_friedrichs];
        varied_params = varied
    )
    
    fig = launch_plotter()
    display(fig)
    set_sim_config!(config)
    force_simulation()
    
# --- HELPER FUNCTIONS ---
    function click_menu!(widget, target_sym)
        options = widget.options[]
        idx = findfirst(opt -> (opt isa Tuple ? opt[2] : opt) == target_sym, options)
        
        if isnothing(idx)
            push!(options, menu_opt(target_sym))
            widget.options[] = options
            idx = length(options)
        end
        widget.i_selected[] = idx
    end

    # New Helper: Simulates a physical user click on a Makie Button
    function click_button!(button_sym)
        manager.widgets[button_sym].clicks[] += 1
        yield()
    end

    function set_axes_for_dim!(dim)
        if dim == 1
            click_menu!(manager.widgets[:x_axis], :x)
            click_menu!(manager.widgets[:y_axis], :none)
            click_menu!(manager.widgets[:z_axis], :none)
        elseif dim == 2
            click_menu!(manager.widgets[:x_axis], :x)
            click_menu!(manager.widgets[:y_axis], :t)
            click_menu!(manager.widgets[:z_axis], :none)
        elseif dim == 3
            click_menu!(manager.widgets[:x_axis], :x)
            click_menu!(manager.widgets[:y_axis], :t)
            click_menu!(manager.widgets[:z_axis], :cfl)
        end
        
        # Click the 'Apply Layout' button instead of manually triggering the layout
        click_button!(:layout_apply)
    end

    # --- DYNAMIC PLOT TESTING LOOP ---
    base_plots = [:lines, :scatter, :contour, :heatmap, :volume]

    for bp in base_plots
        @testset "$(titlecase(string(bp))) Base Plot Styles" begin
            click_menu!(manager.widgets[:base_plot], bp)
            click_button!(:layout_apply)
            
            style_options = EULERIAN_PLOT_STYLE_OPTIONS[bp]
            
            for opt in style_options
                style_sym = opt[2]
                expected_dim = PLOT_DIM_MAP[style_sym]
                
                set_axes_for_dim!(expected_dim)
                
                click_menu!(manager.widgets[:plot_style], style_sym)
                
                # Verify pipeline execution via the physical button click
                click_button!(:layout_apply) 
                
                @test manager.state[:Active_Plot_Type] == style_sym
                @test haskey(manager.caches[1][:upwind].primitives, style_sym)
            end
        end
    end
    
    # =========================================================================
    # --- COMPARE MECHANISM (Surface Plot) ---
    # =========================================================================
    @testset "Compare Mechanism (Surface Plot)" begin
        # 0. Provide a completely clean slate so previous test states don't interfere
        reset_plotter!()
        fig = launch_plotter()
        display(fig)

        # 1. Setup the more complex config with 2 Methods and a Parameter Sweep
        shared = create_param_dict(:cfl => 0.5, :N => 200)
        methods = create_method_dict(
            :upwind => create_param_dict(:scheme => "upwind"),
            :lax_friedrichs => create_param_dict(:scheme => "lax_friedrichs")
        )
        varied = create_varied_dict(:cfl => [0.2, 0.4, 0.5]) 
    
        compare_config = SimulationConfig(
            "advection_solver_1d", shared, methods, [:upwind, :lax_friedrichs];
            varied_params = varied
        )
        
        set_sim_config!(compare_config)
        click_button!(:run_button)

        # 2. Base setup for a 2D Surface Plot
        click_menu!(manager.widgets[:base_plot], :heatmap)
        
        click_menu!(manager.widgets[:plot_style], :heatmap_surface)
        
        click_menu!(manager.widgets[:x_axis], :x)
        click_menu!(manager.widgets[:y_axis], :t)
        click_menu!(manager.widgets[:z_axis], :none)
        
        # 3. Test Compare by Methods
        click_menu!(manager.widgets[:compare_target], :methods)
        click_button!(:layout_apply)
        
        @test haskey(manager.caches, 1) # Subplot 1 (Upwind)
        @test haskey(manager.caches, 2) # Subplot 2 (Lax-Friedrichs)
        
        # 4. Test Compare by CFL (cfl)
        click_menu!(manager.widgets[:compare_target], :cfl)
        click_button!(:layout_apply)
        @test !isempty(manager.caches)
        
        # 5. Test Compare by Components
        click_menu!(manager.widgets[:compare_target], :component)
        click_button!(:layout_apply)
        @test !isempty(manager.caches)
    end

    # =========================================================================
    # --- EXPORT MECHANISMS ---
    # =========================================================================
    @testset "Export Mechanisms (Static & Animated)" begin
        # 0. CLEAN SLATE: Wipe the 3D camera and compare modes from the previous test!
        reset_plotter!()
        fig = launch_plotter()
        
        display(fig)

        # Reinject the global config and unlock the UI
        set_sim_config!(config)
        click_button!(:run_button)

        export_dir = mktempdir()
        export_base = joinpath(export_dir, "test_render")
        
        # 1. Setup a standard 2D plot (Lines) to ensure CairoMakie SVG compatibility
        click_menu!(manager.widgets[:base_plot], :lines)
        click_menu!(manager.widgets[:plot_style], :lines_1d)
        
        click_menu!(manager.widgets[:x_axis], :x)
        click_menu!(manager.widgets[:y_axis], :none)
        click_menu!(manager.widgets[:z_axis], :none)
        click_button!(:layout_apply)

        # 2. Simulate user typing into the Export Textbox
        manager.widgets[:export_text].stored_string[] = export_base
        yield()
        
        # 3. Static Exports (.png, .pdf, .svg)
        manager.ui[:export][:save_formats] = ["png", "pdf", "svg"]
        click_button!(:export_button)
        
        @test isfile(export_base * ".png")
        @test isfile(export_base * ".pdf")
        @test isfile(export_base * ".svg")
        
        # 4. Bind the time dimension to the animation target
        click_menu!(manager.widgets[:anim_target], :t)
        click_button!(:layout_apply)
        
        # 5. Speed up tests & verify Hierarchical Menus!
        click_menu!(manager.widgets[:editor_cat], :ui)
        click_menu!(manager.widgets[:editor_scope], :export)
        
        # Set Duration to 1.0 second
        click_menu!(manager.widgets[:editor_key], :animation_time)
        manager.widgets[:editor_text].stored_string[] = "1.0"
        
        # Set FPS to 10
        click_menu!(manager.widgets[:editor_key], :animation_FPS)
        manager.widgets[:editor_text].stored_string[] = "10"
        yield()

        # 6. Test MP4 Export (by explicitly typing the extension)
        manager.widgets[:export_text].stored_string[] = export_base * ".mp4"
        click_button!(:export_button)
        @test isfile(export_base * ".mp4")
        
        # 7. Test GIF Export
        manager.widgets[:export_text].stored_string[] = export_base * ".gif"
        click_button!(:export_button)
        @test isfile(export_base * ".gif")
    end
    # =========================================================================
    # --- CSV PIPELINE & PRESETS ---
    # =========================================================================
    @testset "CSV Pipeline & Presets" begin
        # 0. Clean Slate
        reset_plotter!()
        fig = launch_plotter()
        display(fig)

        shared = create_param_dict(:cfl => 0.5, :N => 20)
        methods = create_method_dict(:upwind => create_param_dict(:scheme => "upwind"))
        config = SimulationConfig("advection_solver_1d", shared, methods, [:upwind])
        set_sim_config!(config)
        
        click_button!(:run_button)

        export_dir = mktempdir()
        export_base = joinpath(export_dir, "pipeline_test")
        
        # 1. Export a frame to generate a valid, full-state simulation CSV
        manager.widgets[:export_text].stored_string[] = export_base
        manager.ui[:export][:save_formats] = ["png"]
        click_button!(:export_button)
        
        sim_csv_path = export_base * ".csv"
        @test isfile(sim_csv_path)

        # 2. Load the saved CSV via the UI
        manager.widgets[:export_text].stored_string[] = sim_csv_path
        click_button!(:load_config_button)
        
        # 3. Click Run Simulation to execute the staged CSV configuration
        click_button!(:run_button)
        
        # Verify the simulation lock was properly processed and cleared
        @test manager.flags[:Simulation][] == false

        # 4. Save a custom Preset
        preset_name = "my_custom_preset"
        manager.widgets[:export_text].stored_string[] = preset_name
        
        # Navigate the hierarchical editor to add a custom preset description
        click_menu!(manager.widgets[:editor_cat], :ui)
        click_menu!(manager.widgets[:editor_scope], :presets)
        click_menu!(manager.widgets[:editor_key], :create_new)
        
        # Type the description and trigger the sync listener
        manager.widgets[:editor_text].stored_string[] = "A rigorous test preset for the UI pipeline"

        # Click Save Presets
        click_button!(:save_presets_button)
        
        # Verify the preset file was written to the specific Presets directory
        preset_path = joinpath(get_save_path(), "Presets", preset_name * ".csv")
        @test isfile(preset_path)
        
        # Verify the description was parsed and saved to the backend maps
        sym_name = Symbol(preset_name)
        @test haskey(manager.maps[:Presets], sym_name)
        @test manager.maps[:Presets][sym_name] == "A rigorous test preset for the UI pipeline"
    end

    # =========================================================================
    # --- INBUILT PRESETS (API & UI) ---
    # =========================================================================
    @testset "Inbuilt Presets & Global Reset" begin
        # 0. Clean Slate
        reset_plotter!()
        fig = launch_plotter()
        display(fig)

        shared = create_param_dict(:cfl => 0.5, :N => 20)
        methods = create_method_dict(:upwind => create_param_dict(:scheme => "upwind"))
        config = SimulationConfig("advection_solver_1d", shared, methods, [:upwind])
        set_sim_config!(config)
        
        click_button!(:run_button)

        # 1. Test via Direct API Function Call
        set_plot_preset!(:publication)
        yield()
        @test manager.ui[:labels][:title] == ""
        @test manager.ui[:plot_style][:line_width] == 2.5
        
        set_plot_preset!(:heatmap)
        yield()
        @test manager.state[:Layout_Cache][:base_plot] == :heatmap
        @test manager.state[:Layout_Cache][:plot_style] == :heatmap_flat
        
        set_plot_preset!(:compact3d)
        yield()
        @test manager.ui[:z_axis][:label_offset] == 15.0
        
        set_plot_preset!(:nolabels)
        yield()
        @test manager.ui[:labels][:x_label] == ""
        @test manager.ui[:labels][:y_label] == ""

        # 2. Test via the Hierarchical UI Editor
        click_menu!(manager.widgets[:editor_cat], :ui)
        click_menu!(manager.widgets[:editor_scope], :presets)
        
        # Select a dummy preset first to reset the observer state
        click_menu!(manager.widgets[:editor_key], :publication)
        yield()
        
        click_menu!(manager.widgets[:base_plot], :lines)
        click_menu!(manager.widgets[:plot_style], :lines_1d)
        
        click_menu!(manager.widgets[:x_axis], :x)
        click_menu!(manager.widgets[:y_axis], :none)
        click_menu!(manager.widgets[:z_axis], :none)
        click_button!(:layout_apply)
        # Now select :darkmode so the change event guarantees a fresh trigger
        click_menu!(manager.widgets[:editor_key], :darkmode)
        yield()
        
        @test manager.widgets[:editor_toggle].label[] == "Apply"
        
        click_button!(:editor_toggle)
        yield()
        
        @test manager.ui[:plot_style][:colors] == [:cyan, :magenta, :yellow, :white]
        
        # 3. Test the Global Reset Mechanism
        click_button!(:clear_presets_button)
        yield()
        
        # Verify the UI successfully restored the master default templates rather than being bare empty
        @test haskey(manager.ui, :plot_style)
        @test manager.ui[:plot_style][:line_width] == 3.0 # Master default value
    end
    # =========================================================================
    # --- PLOTTING UTILS (HUD, Outliers & Reference Lines) ---
    # =========================================================================
    # =========================================================================
    # --- PLOTTING UTILS (HUD, Outliers & Reference Lines) ---
    # =========================================================================
    @testset "Plotting Utilities: HUD, Outliers & Reference Lines" begin
        # 0. Clean Slate & 1D Scatter Setup
        reset_plotter!()
        fig = launch_plotter()
        display(fig)

        shared = create_param_dict(:cfl => 0.5, :N => 50)
        methods = create_method_dict(:upwind => create_param_dict(:scheme => "upwind"))
        config = SimulationConfig("advection_solver_1d", shared, methods, [:upwind])
        set_sim_config!(config)
        
        click_button!(:run_button)

        # Set up a 1D Scatter plot configuration
        click_menu!(manager.widgets[:base_plot], :scatter)
        click_menu!(manager.widgets[:plot_style], :scatter_1d)
        click_menu!(manager.widgets[:x_axis], :x)
        click_menu!(manager.widgets[:y_axis], :none)
        click_menu!(manager.widgets[:z_axis], :none)
        click_button!(:layout_apply)
        yield()

        # Safely extract the active Makie Axis from the figure
        ax = nothing
        for c in fig.content
            if c isa Axis
                ax = c
                break
            elseif hasproperty(c, :content) && c.content isa Axis
                ax = c.content
                break
            end
        end

        # 1. Test HUD Injection (Direct Local Call)
        manager.ui[:hud][:visible] = true
        manager.ui[:hud][:mode] = "lines"
        manager.ui[:hud][:points] = Any[(0.1, 0.1), (0.9, 0.9)]
        manager.ui[:hud][:close_loop] = false
        
        plot_HUD!(ax)
        yield()

        hud_plots = [p for p in ax.scene.plots if haskey(p, :label) && p.label[] == "HUD"]
        @test !isempty(hud_plots)

        # 2. Test Reference Lines (Direct Local Call)
        ref_lines = plot_reference_lines!(ax, [-1.0, -2.0]; label="Convergence Ref")
        yield()
        
        @test length(ref_lines) == 2
        @test any(p -> haskey(p, :label) && p.label[] == "Convergence Ref", ax.scene.plots)

        # 3. Test Extrema & Outliers Manager via Pipeline
        manager.ui[:outliers_extrema][:track_max] = true
        manager.ui[:outliers_extrema][:track_min] = true
        manager.ui[:outliers_extrema][:mark_outliers] = true
        manager.ui[:outliers_extrema][:remove_outliers] = false 
        
        # A threshold of 0.0 guarantees any point outside the 25th-75th percentile is flagged
        manager.ui[:outliers_extrema][:outlier_threshold] = 0.0

        # Trigger a plot rebuild so the backend pipeline applies the outlier masks
        click_button!(:plot_button)
        yield()

        extrema_max_plots = [p for p in ax.scene.plots if haskey(p, :label) && p.label[] == "Extrema_Max"]
        outlier_plots = [p for p in ax.scene.plots if haskey(p, :label) && p.label[] == "Outlier"]
        
        @test !isempty(extrema_max_plots)
        @test !isempty(outlier_plots)
    end
    # =========================================================================
    # --- LAGRANGIAN RENDER PIPELINE ---
    # =========================================================================
    @testset "Lagrangian Render Pipeline" begin
        # 0. Clean Slate
        reset_plotter!()
        set_mode!(:lagrangian)

        fig = launch_plotter()
        display(fig)

        # 1. Setup Config with 3D data space (x, t, param_1)
        shared = create_param_dict(:cfl => 0.5, :N => 20)
        methods = create_method_dict(:upwind => create_param_dict(:scheme => "upwind"))
        varied = create_varied_dict(:cfl => [0.2, 0.4, 0.5]) 
        
        config = SimulationConfig(
            "advection_solver_1d", shared, methods, [:upwind];
            varied_params = varied
        )
        
        run_all_simulations(config; force_overwrite=true)
        set_sim_config!(config)
        
        click_button!(:run_button)

        # The UI should automatically lock the base plot to scatter for Lagrangian data
        @test manager.widgets[:base_plot].selection[] == :scatter

        # --- Test 1D Lagrangian ---
        click_menu!(manager.widgets[:x_axis], :x)
        click_menu!(manager.widgets[:y_axis], :none)
        click_menu!(manager.widgets[:z_axis], :none)
        click_menu!(manager.widgets[:plot_style], :scatter_1d)
        
        click_button!(:layout_apply)
        yield()
        
        @test manager.state[:Active_Plot_Type] == :scatter_1d
        @test haskey(manager.caches[1][:upwind].primitives, :scatter_1d)
        # Verify the backend correctly allocated a Lagrangian cache
        @test typeof(manager.caches[1][:upwind]).name.name == :LagrangianPlotCache
    end
    reset_plotter!()
end
@testset "README Test file" begin
    @test include("../examples/advection_1d.jl")
end