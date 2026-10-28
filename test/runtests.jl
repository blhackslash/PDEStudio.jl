using PDEStudio
using GLMakie
using WGLMakie
using Test
using StaticArrays
import PDEStudio: manager, EulerianPlotCache, LagrangianPlotCache, PLOT_DIM_MAP, menu_opt, EULERIAN_PLOT_STYLE_OPTIONS, plot_reference_lines!, plot_HUD!
import PDEStudio: preset_dir, sim_preset_dir, MAX_COMPARE_PLOTS

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
    
    return create_sim_data(x, u_num, t, params; time_dim=:t, dims=:x)
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
# --- HELPERS (no window needed) ---
# ==============================================================================
@testset "PDEStudio: Helpers" begin
    @testset "Export formats" begin
        @test PDEStudio._export_formats(["PNG", ".pdf", "mp4", "tiff"]) == ["png", "pdf"]
        @test PDEStudio._export_formats("svg") == ["svg"]       # a single entry typed into the editor
        @test PDEStudio._export_formats((:png, :png)) == ["png"]
    end

    @testset "Editor input parsing" begin
        @test PDEStudio._parse_editor_input("1e3", "old text") == "1e3"      # text stays text
        @test PDEStudio._parse_editor_input("\"quoted\"", "x") == "quoted"
        @test PDEStudio._parse_editor_input("<empty>", "x") == ""
        @test PDEStudio._parse_editor_input("1e3", 1.0) == 1000.0
        @test PDEStudio._parse_editor_input("[:a, :b]", Symbol[]) == [:a, :b]
        @test PDEStudio._parse_editor_input("println(\"hi\")", 1) isa AbstractString  # never evaluated
        @test isnothing(PDEStudio._parse_editor_input("none", nothing))

        # Sweeps: a single value sweeps one value; text sweeps keep unquoted items as text
        @test PDEStudio._parse_sweep_input("[0.1, 0.2]", [0.5]) == [0.1, 0.2]
        @test PDEStudio._parse_sweep_input("0.3", [0.5]) == [0.3]
        @test PDEStudio._parse_sweep_input("[upwind, lax_friedrichs]", ["upwind"]) == ["upwind", "lax_friedrichs"]
        @test PDEStudio._parse_sweep_input("1e3", ["a"]) == ["1e3"]
        @test PDEStudio._parse_sweep_input("0.1:0.1:0.3", [0.5]) ≈ [0.1, 0.2, 0.3]
    end

    @testset "Sweeps & comparisons" begin
        @test PDEStudio._is_numeric_sweep([0.1, 2])
        @test !PDEStudio._is_numeric_sweep(["upwind", "lax_friedrichs"])
        @test PDEStudio._param_index([0.1, 0.2, 0.5], 0.45) == 3
        @test PDEStudio._param_index(["a", "b", "c"], 2.4) == 2
        @test PDEStudio._param_index(["a", "b"], 7) == 2
        @test PDEStudio._compare_picks(5) == 1:5
        picks = PDEStudio._compare_picks(100)
        @test length(picks) == MAX_COMPARE_PLOTS && first(picks) == 1 && last(picks) == 100
        @test PDEStudio._preset_symbol(" My  Preset ") == :my_preset
    end

    @testset "Colour ranges & colour validation" begin
        # A numerically constant field gets a usable (relative 1e-3) colour range instead of one made of noise
        lo, hi = PDEStudio._pad_degenerate_range(1.3999995f0, 1.4000003f0)
        @test hi - lo ≥ 2e-3 * 1.4 && lo < 1.3999995f0 && hi > 1.4000003f0
        @test PDEStudio._pad_degenerate_range(0.0, 0.0) == (-1e-6, 1e-6)
        @test PDEStudio._pad_degenerate_range(0.0, 1.0) == (0.0, 1.0)
        # ... so the Float32 initial state of a Riemann problem (with a masked region) renders as filled contours
        z = 1.4f0 .+ Float32.(1e-7 .* randn(60, 40)); z[40:end, 1:10] .= NaN32
        cr = PDEStudio.get_colorrange(Dict{Symbol, Any}(:color_range => Any[]), z)[]
        fig = Figure(); ax = Axis(fig[1, 1])
        # (contourf! itself fails for noise-spaced levels; rendered through CairoMakie since no backend window is up here)
        @test contourf!(ax, Float32.(1:60), Float32.(1:40), z; levels = range(cr[1], cr[2], length = 20), colorrange = cr) isa Makie.Plot
        @test Makie.colorbuffer(fig; backend = PDEStudio.CairoMakie) isa AbstractMatrix

        @test PDEStudio._valid_color(:red) && PDEStudio._valid_color("#1f77b4") && PDEStudio._valid_color([(:black, 0.8), :blue])
        @test !PDEStudio._valid_color("rde") && !PDEStudio._valid_color([:blue, :rde])
        @test PDEStudio._valid_colormap(:viridis) && !PDEStudio._valid_colormap(:viridiss)
        @test PDEStudio._valid_ui_value(:line_width, "whatever") && !PDEStudio._valid_ui_value(:color, "rde")
        @test PDEStudio._valid_ui_value(:colors, [:cyan, :magenta]) && !PDEStudio._valid_ui_value(:color_map, :viridiss)
    end

    @testset "Simulation CSV: patch semantics & text values" begin
        base = SimulationConfig(
            create_param_dict(:N => 20, :tag => "1e3", :sim_func_name => :advection_solver_1d),
            create_method_dict(:upwind => create_param_dict(:scheme => "upwind"),
                               :lax_friedrichs => create_param_dict(:scheme => "lax_friedrichs")),
            [:upwind]; varied = create_varied_dict(:cfl => [0.2, 0.4]))

        parsed = Dict("Simulation" => Dict("Shared" => Dict{String, Any}("N" => 80)))
        patched = PDEStudio.csv_to_simulation_config(parsed; base = base)
        @test patched.shared[:N] == 80
        @test patched.shared[:sim_func_name] == :advection_solver_1d
        @test patched.defaults == [:upwind]
        @test patched.varied[:cfl] == [0.2, 0.4]
        @test length(patched.methods) == 2
        @test base.shared[:N] == 20                                  # the base is not modified

        replaced = PDEStudio.csv_to_simulation_config(parsed)
        @test replaced.shared == Dict(:N => 80) && isempty(replaced.methods)

        # Text that looks like a number survives a write/read round trip
        rows = PDEStudio._CSVRows()
        PDEStudio._add_simulation_rows!(rows, base)
        path = joinpath(mktempdir(), "sim.csv")
        PDEStudio._write_rows(path, rows)
        reread = PDEStudio.csv_to_simulation_config(PDEStudio.parse_csv_to_dict(path))
        @test reread.shared[:tag] == "1e3"
        @test reread.methods[:upwind][:scheme] == "upwind"
        @test reread.defaults == [:upwind]
        @test reread.varied[:cfl] == [0.2, 0.4]
    end
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

    shared = create_param_dict(:cfl => 0.5, :N => 200, :sim_func_name => :advection_solver_1d)
    methods = create_method_dict(:analytical_solution => create_param_dict(), :upwind => create_param_dict(:scheme => "upwind"),:lax_friedrichs => create_param_dict(:scheme => "lax_friedrichs"))
    # Creating a parameter sweep adds a 3rd dimension (x, t, cfl) for the 3D plot tests
    varied = create_varied_dict(:cfl => [0.2, 0.4, 0.5]) 

    config = SimulationConfig(
        shared, methods, [:upwind, :lax_friedrichs, :analytical_solution];
        varied = varied,
        reference = :exact_advection_factory
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
                
                @test manager.active_plot_type == style_sym
                # Single-method styles draw one (numerical) method, overlay styles all of them
                drawn = [m for (m, c) in manager.caches[1] if haskey(c.primitives, style_sym)]
                @test !isempty(drawn) && !(:analytical_solution in drawn && length(drawn) == 1)
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
        shared = create_param_dict(:cfl => 0.5, :N => 200, :sim_func_name => :advection_solver_1d)
        methods = create_method_dict(
            :upwind => create_param_dict(:scheme => "upwind"),
            :lax_friedrichs => create_param_dict(:scheme => "lax_friedrichs")
        )
        varied = create_varied_dict(:cfl => [0.2, 0.4, 0.5]) 
    
        compare_config = SimulationConfig(
            shared, methods, [:upwind, :lax_friedrichs];
            varied = varied
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

        # A static extension in the filename exports exactly that format
        manager.ui[:export][:save_formats] = ["png"]
        manager.widgets[:export_text].stored_string[] = export_base * "_direct.svg"
        click_button!(:export_button)
        @test isfile(export_base * "_direct.svg")
        @test !isfile(export_base * "_direct.png")

        # An unknown "extension" is part of the name
        manager.widgets[:export_text].stored_string[] = joinpath(export_dir, "run_dt0.5")
        click_button!(:export_button)
        @test isfile(joinpath(export_dir, "run_dt0.5.png"))
        
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

        shared = create_param_dict(:cfl => 0.5, :N => 20, :sim_func_name => :advection_solver_1d)
        methods = create_method_dict(:upwind => create_param_dict(:scheme => "upwind"))
        config = SimulationConfig(shared, methods, [:upwind])
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
        @test manager.active_config.shared[:N] == 20
        @test manager.active_config.defaults == [:upwind]

        # Keys are written as raw backend names (they used to be display labels that did not always map back)
        parsed = PDEStudio.parse_csv_to_dict(sim_csv_path)
        @test haskey(parsed["UI"]["export"], "animation_FPS")
        @test haskey(parsed["Simulation"]["Shared"], "sim_func_name")

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
        preset_path = joinpath(preset_dir(), preset_name * ".csv")
        @test isfile(preset_path)
        
        # Verify the description was parsed and saved to the backend maps
        sym_name = Symbol(preset_name)
        @test haskey(manager.presets, sym_name)
        @test manager.presets[sym_name] == "A rigorous test preset for the UI pipeline"
    end

    # =========================================================================
    # --- VISUAL PRESETS: ROUND TRIP ---
    # =========================================================================
    @testset "Visual Presets: Round Trip" begin
        # Uses the window and the configuration of the previous testset
        manager.ui[:export][:animation_FPS] = 12
        PDEStudio.set_label!(:component_1, "Density")
        @test save_plot_preset("Round Trip"; description = "round trip test")
        @test isfile(joinpath(preset_dir(), "round_trip.csv"))

        manager.ui[:export][:animation_FPS] = 30
        PDEStudio.set_label!(:component_1, "Other")
        sim_before = deepcopy(manager.active_config.shared)
        set_plot_preset!(:round_trip)
        yield()
        @test manager.ui[:export][:animation_FPS] == 12
        @test PDEStudio.frontend_key(:component_1) == "Density"
        @test manager.presets[:round_trip] == "round trip test"
        @test manager.active_config.shared == sim_before        # visual presets never touch the simulation
    end

    # =========================================================================
    # --- SIMULATION PRESETS (API) ---
    # =========================================================================
    @testset "Simulation Presets (API)" begin
        reset_plotter!()
        fig = launch_plotter()
        display(fig)

        shared = create_param_dict(:cfl => 0.5, :N => 20, :sim_func_name => :advection_solver_1d)
        methods = create_method_dict(:upwind => create_param_dict(:scheme => "upwind"),
                                     :lax_friedrichs => create_param_dict(:scheme => "lax_friedrichs"))
        set_sim_config!(SimulationConfig(shared, methods, [:upwind, :lax_friedrichs]))
        click_button!(:run_button)
        ui_before = deepcopy(manager.ui[:plot_style])

        # 1. Save the simulation category only
        @test save_sim_preset("Coarse"; description = "coarse grid")
        coarse_path = joinpath(sim_preset_dir(), "coarse.csv")
        @test isfile(coarse_path)
        parsed = PDEStudio.parse_csv_to_dict(coarse_path)
        @test haskey(parsed, "Simulation") && !haskey(parsed, "UI") && !haskey(parsed, "Scene")
        @test manager.sim_presets[:coarse] == "coarse grid"

        # 1b. Only the active methods are written
        manager.active_config.defaults = [:upwind]
        @test save_sim_preset("only_upwind")
        parsed_u = PDEStudio.parse_csv_to_dict(joinpath(sim_preset_dir(), "only_upwind.csv"))
        @test haskey(parsed_u["Simulation"], "upwind") && !haskey(parsed_u["Simulation"], "lax_friedrichs")
        @test Symbol.(parsed_u["Simulation"]["Config"]["methods"]) == [:upwind]
        manager.active_config.defaults = [:upwind, :lax_friedrichs]

        # 2. Change the simulation, then switch back with the preset (replace mode)
        manager.active_config.shared[:N] = 40
        manager.active_config.defaults = [:upwind]
        cfg = set_sim_preset!(:coarse)
        @test cfg === manager.active_config
        @test cfg.shared[:N] == 20
        @test cfg.defaults == [:upwind, :lax_friedrichs]   # the order given to set_sim_config! survives the round trip
        @test manager.flags[:Simulation][] == true
        @test manager.ui[:plot_style] == ui_before               # simulation presets never touch the look

        # 3. A hand-written preset only patches what it lists
        write(joinpath(sim_preset_dir(), "hires.csv"),
              "Category,Scope,Parameter,Value\nMetadata,Preset,description,Fine grid\nSimulation,Shared,N,80\n")
        cfg = set_sim_preset!("hires")
        @test cfg.shared[:N] == 80
        @test cfg.shared[:cfl] == 0.5
        @test cfg.defaults == [:upwind, :lax_friedrichs]
        @test manager.sim_presets[:hires] == "Fine grid"

        # 4. Reset to the configuration bound with set_sim_config!
        reset_sim_config!()
        @test manager.active_config.shared[:N] == 20
        @test manager.active_config.defaults == [:upwind, :lax_friedrichs]

        # 5. Run the preset
        set_sim_preset!(:hires)
        click_button!(:run_button)
        @test manager.flags[:Simulation][] == false
        @test isnothing(set_sim_preset!(:does_not_exist))
    end

    # =========================================================================
    # --- SIMULATION PRESETS & EDITOR (UI) ---
    # =========================================================================
    @testset "Simulation Presets & Editor (UI)" begin
        reset_plotter!()
        fig = launch_plotter()
        display(fig)

        shared = create_param_dict(:cfl => 0.5, :N => 20, :sim_func_name => :advection_solver_1d)
        methods = create_method_dict(:upwind => create_param_dict(:scheme => "upwind"),
                                     :lax_friedrichs => create_param_dict(:scheme => "lax_friedrichs"))
        set_sim_config!(SimulationConfig(shared, methods, [:upwind]; varied = create_varied_dict(:cfl => [0.2, 0.5])))
        click_button!(:run_button)
        config = manager.active_config
        editor_text(s) = (manager.widgets[:editor_text].stored_string[] = s; yield())

        # 1. The preset buttons follow the editor category
        click_menu!(manager.widgets[:editor_cat], :simulation)
        @test manager.widgets[:save_presets_button].label[] == "Save Sim Preset"
        @test manager.widgets[:clear_presets_button].label[] == "Reset Simulation"
        scopes = [o[2] for o in manager.widgets[:editor_scope].options[]]
        @test all(in(scopes), [:presets, :shared, :sweep, :config, :upwind])
        @test !(:lax_friedrichs in scopes)   # inactive methods are not listed

        # 2. Shared parameters (numbers are parsed, the change flags a re-run)
        click_menu!(manager.widgets[:editor_scope], :shared)
        click_menu!(manager.widgets[:editor_key], :N)
        editor_text("30")
        @test config.shared[:N] == 30
        @test manager.flags[:Simulation][] == true
        editor_text("default")                                # back to the bound configuration
        @test config.shared[:N] == 20

        # 3. Text parameters stay text
        click_menu!(manager.widgets[:editor_scope], :upwind)
        click_menu!(manager.widgets[:editor_key], :scheme)
        editor_text("1e3")
        @test config.methods[:upwind][:scheme] == "1e3"
        editor_text("upwind")
        @test config.methods[:upwind][:scheme] == "upwind"

        # 4. The sweep (a single value becomes a one-value sweep)
        click_menu!(manager.widgets[:editor_scope], :sweep)
        click_menu!(manager.widgets[:editor_key], :cfl)
        editor_text("[0.2, 0.4, 0.5]")
        @test config.varied[:cfl] == [0.2, 0.4, 0.5]
        editor_text("0.3")
        @test config.varied[:cfl] == [0.3]
        editor_text("[0.2, 0.5]")

        # 5. Active methods and functions
        click_menu!(manager.widgets[:editor_scope], :config)
        click_menu!(manager.widgets[:editor_key], :defaults)
        editor_text("[:upwind, :lax_friedrichs]")
        @test sort(config.defaults) == [:lax_friedrichs, :upwind]
        click_menu!(manager.widgets[:editor_key], :reference)
        editor_text(":exact_advection_factory")
        @test config.reference === :exact_advection_factory
        editor_text("none")
        @test isnothing(config.reference)

        # 6. Save a simulation preset from the UI (description typed into the editor)
        click_menu!(manager.widgets[:editor_scope], :presets)
        click_menu!(manager.widgets[:editor_key], :create_new)
        editor_text("Both methods, three CFL numbers")
        manager.widgets[:export_text].stored_string[] = "ui sim preset"
        click_button!(:save_presets_button)
        @test isfile(joinpath(sim_preset_dir(), "ui_sim_preset.csv"))
        @test manager.sim_presets[:ui_sim_preset] == "Both methods, three CFL numbers"
        @test manager.sim_presets[:create_new] == PDEStudio.DEFAULT_PRESET_DESC

        # 7. Reset Simulation restores the bound configuration, Apply loads the preset again
        click_button!(:clear_presets_button)
        @test manager.active_config.defaults == [:upwind]
        click_menu!(manager.widgets[:editor_scope], :presets)
        click_menu!(manager.widgets[:editor_key], :ui_sim_preset)
        @test manager.widgets[:editor_toggle].label[] == "Apply"
        click_button!(:editor_toggle)
        @test sort(manager.active_config.defaults) == [:lax_friedrichs, :upwind]
        click_button!(:run_button)
        @test manager.flags[:Simulation][] == false
        @test sort(manager.methods[]) == [:lax_friedrichs, :upwind]
        @test :lax_friedrichs in [o[2] for o in manager.widgets[:editor_scope].options[]]   # active now

        # 8. Outside the Simulation category the buttons act on visual presets again
        click_menu!(manager.widgets[:editor_cat], :ui)
        @test manager.widgets[:save_presets_button].label[] == "Save Presets"
        @test manager.widgets[:clear_presets_button].label[] == "Clear Presets"
    end

    # =========================================================================
    # --- EDITOR: PRESETS SCOPE & LIVE PRESET LISTS ---
    # =========================================================================
    @testset "Editor: Presets scope & live preset lists" begin
        reset_plotter!()
        shared = create_param_dict(:cfl => 0.5, :N => 20, :sim_func_name => :advection_solver_1d)
        methods = create_method_dict(:upwind => create_param_dict(:scheme => "upwind"))
        set_sim_config!(SimulationConfig(shared, methods, [:upwind]))
        fig = launch_plotter()
        display(fig)
        w = manager.widgets
        key_values() = [o[2] for o in w[:editor_key].options[]]

        # 1. With a configuration bound before launching, the editor opens on Simulation → Presets
        @test w[:editor_cat].selection[] === :simulation
        @test w[:editor_scope].selection[] === :presets
        @test w[:editor_key].selection[] === :create_new

        # 2. A preset saved through the API shows up while the scope stays selected
        save_sim_preset("api_saved"; description = "saved from the REPL")
        @test :api_saved in key_values()
        @test w[:editor_key].selection[] === :create_new

        # 2b. The description is shown as the box's value (stored == displayed, so Makie draws it in the text colour)
        click_menu!(w[:editor_key], :api_saved)
        @test w[:editor_text].displayed_string[] == "saved from the REPL"
        @test w[:editor_text].stored_string[] == w[:editor_text].displayed_string[]
        # ... editing it is written to the preset file
        w[:editor_text].stored_string[] = "edited description"
        @test manager.sim_presets[:api_saved] == "edited description"
        raw_desc = PDEStudio._read_csv(joinpath(sim_preset_dir(), "api_saved.csv"))[2]["Metadata"]["Preset"]["description"]
        @test raw_desc == "edited description"
        # ... and a description typed under create_new counts without pressing Enter
        click_menu!(w[:editor_key], :create_new)
        w[:editor_text].displayed_string[] = "typed, not submitted"
        manager.widgets[:export_text].stored_string[] = "typed_only"
        click_button!(:save_presets_button)
        @test manager.sim_presets[:typed_only] == "typed, not submitted"
        @test w[:editor_key].selection[] === :typed_only

        # 3. A file copied into the preset folder shows up when the key menu is opened
        mkpath(sim_preset_dir())
        write(joinpath(sim_preset_dir(), "copied.csv"),
              "Category,Scope,Parameter,Value\nMetadata,Preset,description,copied by hand\nSimulation,Shared,N,40\n")
        @test !(:copied in key_values())
        w[:editor_key].is_open[] = true
        @test :copied in key_values()
        w[:editor_key].is_open[] = false
        click_menu!(w[:editor_key], :copied)
        @test w[:editor_text].displayed_string[] == "copied by hand"
        @test w[:editor_toggle].label[] == "Apply"

        # 4. The same for visual presets under UI → Presets; the scope survives the category switch
        click_menu!(w[:editor_cat], :ui)
        @test w[:editor_scope].selection[] === :presets
        save_plot_preset("api_look"; description = "look from the REPL")
        @test :api_look in key_values()
        click_menu!(w[:editor_cat], :simulation)
        @test w[:editor_scope].selection[] === :presets
        @test :api_saved in key_values() && !(:api_look in key_values())
    end

    # =========================================================================
    # --- METHOD ORDER FOLLOWS `defaults` ---
    # =========================================================================
    @testset "Method order follows defaults" begin
        reset_plotter!()
        fig = launch_plotter()
        display(fig)
        shared = create_param_dict(:cfl => 0.5, :N => 20, :sim_func_name => :advection_solver_1d)
        methods = create_method_dict(:upwind => create_param_dict(:scheme => "upwind"),
                                     :lax_friedrichs => create_param_dict(:scheme => "lax_friedrichs"),
                                     :analytic => create_param_dict())
        cfg = SimulationConfig(shared, methods, [:upwind, :lax_friedrichs]; reference = :exact_advection_factory)
        set_sim_config!(cfg)
        @test manager.methods[] == [:upwind, :lax_friedrichs]            # not re-sorted
        click_button!(:run_button)
        first_method() = only(keys(manager.caches[1]))

        # 1. The "compare methods" subplots follow the order of `defaults`
        click_menu!(manager.widgets[:base_plot], :lines)
        click_menu!(manager.widgets[:plot_style], :lines_1d)
        click_menu!(manager.widgets[:x_axis], :x)
        click_menu!(manager.widgets[:compare_target], :methods)
        click_button!(:layout_apply)
        @test first_method() == :upwind

        # 2. Reordering the list in the editor is the override; it takes effect with the next run
        click_menu!(manager.widgets[:editor_cat], :simulation)
        click_menu!(manager.widgets[:editor_scope], :config)
        click_menu!(manager.widgets[:editor_key], :defaults)
        manager.widgets[:editor_text].stored_string[] = "[:lax_friedrichs, :upwind]"
        @test manager.active_config.defaults == [:lax_friedrichs, :upwind]
        click_button!(:run_button)
        @test manager.methods[] == [:lax_friedrichs, :upwind]
        click_button!(:layout_apply)
        @test first_method() == :lax_friedrichs

        # 3. Activating a method appends it; a saved preset keeps the order
        manager.is_activate_mode[] = true
        click_menu!(manager.widgets[:method_toggle], :analytic)
        @test manager.active_config.defaults == [:lax_friedrichs, :upwind, :analytic]
        @test save_sim_preset("ordered")
        manager.active_config.defaults = [:upwind]
        @test set_sim_preset!(:ordered).defaults == [:lax_friedrichs, :upwind, :analytic]

        # 4. Without explicit defaults the automatic order (references first) still applies
        set_sim_config!(SimulationConfig(shared, methods; reference = :exact_advection_factory))
        @test manager.methods[] == [:analytic, :lax_friedrichs, :upwind]
    end

    # =========================================================================
    # --- COMPARE OVER TIME & NON-NUMERIC SWEEPS ---
    # =========================================================================
    @testset "Compare over Time & Non-numeric Sweeps" begin
        reset_plotter!()
        fig = launch_plotter()
        display(fig)

        # A swept key must exist in the parameters (here: shared) to be applied by the backend
        shared = create_param_dict(:cfl => 0.5, :N => 40, :scheme => "upwind", :sim_func_name => :advection_solver_1d)
        methods = create_method_dict(:fd => create_param_dict())
        varied = create_varied_dict(:scheme => ["upwind", "lax_friedrichs"])
        set_sim_config!(SimulationConfig(shared, methods, [:fd]; varied = varied))
        click_button!(:run_button)

        click_menu!(manager.widgets[:base_plot], :lines)
        click_menu!(manager.widgets[:plot_style], :lines_1d)
        click_menu!(manager.widgets[:x_axis], :x)
        click_menu!(manager.widgets[:y_axis], :none)
        click_menu!(manager.widgets[:z_axis], :none)
        click_button!(:layout_apply)

        # The text-valued sweep gets an index slider that shows the swept value
        @test manager.reverse_map[:scheme] == :param_1
        @test manager.widgets[:param_1].range[] == [1, 2]
        @test PDEStudio._slider_value_text(:param_1, 2) == "lax_friedrichs"
        set_close_to!(manager.widgets[:param_1], 2)
        yield()
        @test haskey(manager.caches[1][:fd].primitives, :lines_1d)

        # Compare over the text-valued parameter: one subplot per value
        click_menu!(manager.widgets[:compare_target], :scheme)
        click_button!(:layout_apply)
        @test length(manager.caches) == 2

        # Compare over time: at most MAX_COMPARE_PLOTS evenly spaced time steps
        click_menu!(manager.widgets[:compare_target], :time)
        click_button!(:layout_apply)
        @test 2 <= length(manager.caches) <= MAX_COMPARE_PLOTS
        @test first(manager.compare_state) === :time

        click_menu!(manager.widgets[:compare_target], :none)
        click_button!(:layout_apply)
        @test length(manager.caches) == 1
    end

    # =========================================================================
    # --- INBUILT PRESETS (API & UI) ---
    # =========================================================================
    @testset "Inbuilt Presets & Global Reset" begin
        # 0. Clean Slate
        reset_plotter!()
        fig = launch_plotter()
        display(fig)

        shared = create_param_dict(:cfl => 0.5, :N => 20, :sim_func_name => :advection_solver_1d)
        methods = create_method_dict(:upwind => create_param_dict(:scheme => "upwind"))
        config = SimulationConfig(shared, methods, [:upwind])
        set_sim_config!(config)
        
        click_button!(:run_button)

        # 1. Test via Direct API Function Call
        set_plot_preset!(:publication)
        yield()
        @test manager.ui[:labels][:title] == ""
        @test manager.ui[:plot_style][:line_width] == 2.5
        
        set_plot_preset!(:heatmap)
        yield()
        @test manager.layout_cache[:base_plot] == :heatmap
        @test manager.layout_cache[:plot_style] == :heatmap_flat
        
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

        shared = create_param_dict(:cfl => 0.5, :N => 50, :sim_func_name => :advection_solver_1d)
        methods = create_method_dict(:upwind => create_param_dict(:scheme => "upwind"))
        config = SimulationConfig(shared, methods, [:upwind])
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

        # 1b. An invalid HUD colour falls back to the default instead of failing inside the render loop
        manager.ui[:hud][:color] = "rde"
        @test_logs (:warn, r"Invalid HUD color") plot_HUD!(ax)
        hud_plots = [p for p in ax.scene.plots if haskey(p, :label) && p.label[] == "HUD"]
        @test !isempty(hud_plots) && Makie.to_color(hud_plots[1].color[]) == Makie.to_color(:red)
        manager.ui[:hud][:color] = :red
        # ... and the editor refuses to store one
        click_menu!(manager.widgets[:editor_cat], :ui)
        click_menu!(manager.widgets[:editor_scope], :hud)
        click_menu!(manager.widgets[:editor_key], :color)
        @test_logs (:warn, r"not a valid colour") (manager.widgets[:editor_text].stored_string[] = "rde")
        @test manager.ui[:hud][:color] == :red
        manager.widgets[:editor_text].stored_string[] = ":blue"
        @test manager.ui[:hud][:color] == :blue
        manager.widgets[:editor_text].stored_string[] = ":red"

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
        shared = create_param_dict(:cfl => 0.5, :N => 20, :sim_func_name => :advection_solver_1d)
        methods = create_method_dict(:upwind => create_param_dict(:scheme => "upwind"))
        varied = create_varied_dict(:cfl => [0.2, 0.4, 0.5]) 
        
        config = SimulationConfig(
            shared, methods, [:upwind];
            varied = varied
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
        
        @test manager.active_plot_type == :scatter_1d
        @test haskey(manager.caches[1][:upwind].primitives, :scatter_1d)
        # Verify the backend correctly allocated a Lagrangian cache
        @test typeof(manager.caches[1][:upwind]).name.name == :LagrangianPlotCache
    end
    @testset "README Test file" begin
        @test include("../examples/advection_1d.jl") === false
    end
    reset_plotter!()
end
