using PDEStudio
using GLMakie
using WGLMakie
using Test
using StaticArrays
import PDEStudio: manager, EulerianPlotCache, LagrangianPlotCache, PLOT_DIM_MAP, menu_opt, EULERIAN_PLOT_STYLE_OPTIONS, plot_reference_lines!, plot_HUD!
import PDEStudio: preset_dir, sim_preset_dir, MAX_COMPARE_PLOTS, show_tab!, show_editor_page!

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
        if widget isa PDEStudio.StyleChoice      # the plot style (chosen on its page, see the Control tabs tests)
            widget.selection[] = target_sym
            return
        end
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

    # Editor pages (Simulation / UI / Labels tabs): the row of a key on the open page, typing into it, its button,
    # and clicking the page button of a scope on an overview
    editor_row_at(i) = (text = manager.widgets[Symbol("editor_row_", i, "_text")],
                        button = manager.widgets[Symbol("editor_row_", i, "_button")])
    function editor_row(key)
        i = findfirst(isequal(key), manager.editor_row_keys)
        isnothing(i) && error("no row for $(repr(key)) on the editor page (rows: $(manager.editor_row_keys))")
        w = manager.widgets
        return (text = w[Symbol("editor_row_", i, "_text")], button = w[Symbol("editor_row_", i, "_button")])
    end
    type_into!(key, s) = (editor_row(key).text.stored_string[] = s; yield())
    press_row!(key) = (editor_row(key).button.clicks[] += 1; yield())
    # Methods tab: press the active/off button of a method (every method listed)
    function toggle_method!(m)
        manager.method_filter = :all
        show_editor_page!(:methods)
        i = findfirst(isequal(m), manager.editor_row_keys)
        isnothing(i) && error("$(repr(m)) is not listed (methods: $(manager.editor_row_keys))")
        manager.widgets[Symbol("method_row_", i, "_a")].clicks[] += 1
        yield()
    end
    # Whether a widget is drawn inside the window (hidden widgets are parked off-screen)
    shown_now(k) = (b = manager.widgets[k]; b.blockscene.visible[] && all(minimum(b.layoutobservables.computedbbox[]) .>= 0))
    hidden_now(k) = (b = manager.widgets[k]; !b.blockscene.visible[] && !all(minimum(b.layoutobservables.computedbbox[]) .>= 0))

    # Files tab: the preset list of a kind (:simulation, :visual) and the buttons of a preset's row (:a Apply, :b Edit)
    function open_presets!(kind)
        click_button!(:tab_files)
        click_button!(kind === :simulation ? :sim_presets_button : :look_presets_button)
    end
    function press_preset!(name, which)
        i = findfirst(isequal(name), manager.editor_row_keys)
        isnothing(i) && error("no preset $(repr(name)) in the list (presets: $(manager.editor_row_keys))")
        manager.widgets[Symbol("method_row_", i, "_", which)].clicks[] += 1
        yield()
    end
    function open_scope!(scope)
        j = findfirst(isequal(scope), manager.editor_page_scopes)
        isnothing(j) && error("no page button for $(repr(scope)) (overview: $(manager.editor_page_scopes))")
        manager.widgets[Symbol("editor_page_", j)].clicks[] += 1
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
        
        # 5. Speed up tests through the editor (UI → Export page)
        show_editor_page!(:files, PDEStudio.EXPORT_SETTINGS)
        type_into!(:animation_time, "1.0")   # duration 1 s
        type_into!(:animation_FPS, "10")

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
        
        # The description of the new preset (Files tab)
        manager.widgets[:preset_desc_text].stored_string[] = "A rigorous test preset for the UI pipeline"

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

        # 1. The Shared tab is the page of the shared parameters (sweep and fields: Advanced tab)
        click_button!(:tab_shared)
        @test manager.widgets[:editor_title][] == "Shared parameters"
        @test !manager.widgets[:editor_back].blockscene.visible[]   # one page, no overview

        # 2. Shared parameters (numbers are parsed, the change flags a re-run); ↺ restores the bound configuration
        @test manager.editor_row_keys == [:N, :cfl, :sim_func_name]
        @test editor_row(:N).text.displayed_string[] == "20"
        type_into!(:N, "30")
        @test config.shared[:N] == 30
        @test manager.flags[:Simulation][] == true
        @test manager.widgets[:status][] == "Shared → N = 30. Run Simulation to apply."   # the status line reports it
        @test manager.widgets[:status_color][] == PDEStudio.STATUS_COLORS[:ok]
        @test editor_row(:N).button.label[] == "↺"
        press_row!(:N)
        @test config.shared[:N] == 20
        @test editor_row(:N).text.displayed_string[] == "20"
        type_into!(:N, "25")
        type_into!(:N, "default")                              # typing `default` does the same
        @test config.shared[:N] == 20

        # 3. Text parameters stay text (method parameters are edited in the Methods tab)
        show_editor_page!(:methods, :upwind)
        type_into!(:scheme, "1e3")
        @test config.methods[:upwind][:scheme] == "1e3"
        type_into!(:scheme, "upwind")
        @test config.methods[:upwind][:scheme] == "upwind"

        # 4. The sweep and the fields of the configuration are edited in the Advanced tab (raw literals)
        show_editor_page!(:advanced, :config)
        type_into!(:defaults, "Symbol[:upwind, :lax_friedrichs]")
        @test sort(config.defaults) == [:lax_friedrichs, :upwind]
        type_into!(:reference, ":exact_advection_factory")
        @test config.reference === :exact_advection_factory
        type_into!(:reference, "nothing")
        @test isnothing(config.reference)

        # 6. Save a simulation preset in the Files tab (name and description boxes)
        click_button!(:tab_files)
        manager.widgets[:export_text].stored_string[] = "ui sim preset"
        manager.widgets[:preset_desc_text].stored_string[] = "Both methods, three CFL numbers"
        click_button!(:save_sim_preset_button)
        @test isfile(joinpath(sim_preset_dir(), "ui_sim_preset.csv"))
        @test manager.sim_presets[:ui_sim_preset] == "Both methods, three CFL numbers"
        @test occursin("Saved simulation preset 'ui_sim_preset'", manager.widgets[:status][])
        @test isnothing(manager.widgets[:export_text].stored_string[])   # the boxes are cleared
        click_button!(:save_sim_preset_button)                 # without a name: refused, reported
        @test occursin("Enter a preset name", manager.widgets[:status][])

        # 7. Reset restores the bound configuration, Apply (Files → Simulation presets) loads the preset again
        click_button!(:reset_sim_button)
        @test manager.active_config.defaults == [:upwind]
        open_presets!(:simulation)
        @test manager.widgets[:editor_title][] == "Simulation presets"
        press_preset!(:ui_sim_preset, :a)
        @test sort(manager.active_config.defaults) == [:lax_friedrichs, :upwind]
        click_button!(:run_button)
        @test manager.flags[:Simulation][] == false
        @test sort(manager.methods[]) == [:lax_friedrichs, :upwind]
        manager.method_filter = :active
        show_editor_page!(:methods)
        @test manager.editor_row_keys == [:lax_friedrichs, :upwind]   # active now
        manager.method_filter = :all

        # 8. Values that are no literal are refused for non-text parameters (quoted text is accepted)
        show_editor_page!(:shared)
        type_into!(:N, "[1, 2")
        @test manager.active_config.shared[:N] == 20
        @test occursin("not a valid value", manager.widgets[:status][])
        type_into!(:N, "\"twenty\"")
        @test manager.active_config.shared[:N] == "twenty"
        type_into!(:N, "20")
        show_editor_page!(:methods, :upwind)
        type_into!(:scheme, "1e3")                             # text stays text
        @test manager.active_config.methods[:upwind][:scheme] == "1e3"
        type_into!(:scheme, "upwind")
    end

    # =========================================================================
    # --- EDITOR: PRESETS SCOPE & LIVE PRESET LISTS ---
    # =========================================================================
    @testset "Files tab: preset lists & preset files" begin
        reset_plotter!()
        shared = create_param_dict(:cfl => 0.5, :N => 20, :sim_func_name => :advection_solver_1d)
        methods = create_method_dict(:upwind => create_param_dict(:scheme => "upwind"))
        set_sim_config!(SimulationConfig(shared, methods, [:upwind]))
        fig = launch_plotter()
        display(fig)
        w = manager.widgets
        row_label(i) = w[Symbol("editor_row_", i, "_label")][]

        # 1. Presets › lists the saved presets with Apply and Edit; a preset saved through the API shows up
        open_presets!(:simulation)
        @test w[:editor_title][] == "Simulation presets" && shown_now(:editor_back)
        save_sim_preset("api_saved"; description = "saved from the REPL")
        @test :api_saved in manager.editor_row_keys
        i = findfirst(isequal(:api_saved), manager.editor_row_keys)
        @test occursin("saved from the REPL", w[Symbol("method_row_", i, "_label")][])
        @test w[Symbol("method_row_", i, "_a")].label[] == "Apply" && w[Symbol("method_row_", i, "_b")].label[] == "Edit ›"

        # 2. Edit › shows the rows of the file: values as written, ✕ deletes, the add-row adds or replaces
        press_preset!(:api_saved, :b)
        @test w[:editor_title][] == "Preset: api_saved"
        @test row_label(1) == "description" && editor_row_at(1).text.displayed_string[] == "saved from the REPL"
        editor_row_at(1).text.stored_string[] = "edited description"   # the description row
        @test manager.sim_presets[:api_saved] == "edited description"
        raw_desc = PDEStudio._read_csv(joinpath(sim_preset_dir(), "api_saved.csv"))[2]["Metadata"]["Preset"]["description"]
        @test raw_desc == "edited description"
        n_rows = length(manager.preset_file_rows)
        w[:preset_add_scope].stored_string[] = "Shared"           # a simulation preset may give only the scope
        w[:preset_add_key].stored_string[] = "cfl"
        w[:preset_add_value].stored_string[] = "0.25"
        click_button!(:preset_add_button)
        @test ["Simulation", "Shared", "cfl", "0.25"] in manager.preset_file_rows
        @test length(manager.preset_file_rows) == n_rows         # cfl existed: replaced, not added twice
        w[:preset_add_scope].stored_string[] = "Simulation, Shared"
        w[:preset_add_key].stored_string[] = "extra"
        w[:preset_add_value].stored_string[] = "1"
        click_button!(:preset_add_button)
        @test length(manager.preset_file_rows) == n_rows + 1
        idx = findfirst(r -> r[3] == "extra", manager.preset_file_rows)
        row_i = findfirst(isequal(idx), manager.editor_row_keys)
        isnothing(row_i) && (click_button!(:editor_next); row_i = findfirst(isequal(idx), manager.editor_row_keys))
        editor_row_at(row_i).button.clicks[] += 1                # ✕
        @test !any(r -> r[3] == "extra", manager.preset_file_rows)
        @test !any(r -> r[3] == "extra", PDEStudio._preset_rows(:simulation, :api_saved))   # written to the file
        click_button!(:editor_back)                              # back to the list
        @test w[:editor_title][] == "Simulation presets"
        press_preset!(:api_saved, :a)                            # the edited preset is applied
        @test manager.active_config.shared[:cfl] == 0.25
        @test occursin("Applied simulation preset 'api_saved'", w[:status][])

        # 3. A name and description typed into the Files tab count without pressing Enter
        click_button!(:editor_back)
        manager.widgets[:export_text].displayed_string[] = "typed_only"
        manager.widgets[:preset_desc_text].displayed_string[] = "typed, not submitted"
        click_button!(:save_sim_preset_button)
        @test manager.sim_presets[:typed_only] == "typed, not submitted"

        # 4. A file copied into the preset folder shows up when the list is opened
        mkpath(sim_preset_dir())
        write(joinpath(sim_preset_dir(), "copied.csv"),
              "Category,Scope,Parameter,Value\nMetadata,Preset,description,copied by hand\nSimulation,Shared,N,40\n")
        open_presets!(:simulation)
        @test :copied in manager.editor_row_keys

        # 5. Look presets: the built-in ones can be applied but have no file to edit
        click_button!(:editor_back)
        open_presets!(:visual)
        @test w[:editor_title][] == "Look presets" && :darkmode in manager.editor_row_keys
        @test !(:api_saved in manager.editor_row_keys)
        @test_logs (:warn, r"built in") press_preset!(:darkmode, :b)
        @test w[:editor_title][] == "Look presets"
        save_plot_preset("api_look"; description = "look from the REPL")
        @test :api_look in manager.editor_row_keys
        press_preset!(:api_look, :b)
        @test startswith(w[:editor_title][], "Preset: api_look  (1/")   # a look preset has many rows: ◀ ▶ pages
        @test any(r -> r[1] == "UI", manager.preset_file_rows)
    end

    # =========================================================================
    # --- LOADING: JULIA CONFIG FILES, BUNDLED SOURCES, THE FILE DIALOG ---
    # =========================================================================
    @testset "Loading Julia config files & bundled sources" begin
        reset_plotter!()
        fig = launch_plotter()
        display(fig)
        w = manager.widgets
        root = mktempdir()
        status() = replace(w[:status][], '\n' => ' ')        # the status line wraps long messages
        function wait_status(pred; timeout = 10)
            t0 = time()
            while !pred(status()) && time() - t0 < timeout; sleep(0.05); end
            return pred(status())
        end

        # A config folder: the config includes a helper next to it (relative path) and ends with the configuration
        orig = joinpath(root, "orig")
        function write_config(dir; list_helper = false)
            mkpath(dir)
            write(joinpath(dir, "helper.jl"), "helper_N() = 24\n")
            write(joinpath(dir, "config.jl"), """
                include("helper.jl")
                SimulationConfig(create_param_dict(:N => helper_N(), :cfl => 0.5, :sim_func_name => :advection_solver_1d),
                                 create_method_dict(:upwind => create_param_dict(:scheme => "upwind")), [:upwind];
                                 sources = $(list_helper ? "[joinpath(@__DIR__, \"helper.jl\")]" : "String[]"))
                """)
            return joinpath(dir, "config.jl")
        end
        cfg_file = write_config(orig)

        # 1. set_sim_config!(file.jl) runs the file and binds what it returns; the file joins the sources
        @test (@test_logs (:warn, r"runs its code") match_mode=:any set_sim_config!(cfg_file)) == false
        @test manager.active_config.shared[:N] == 24
        @test any(src -> samefile(src, cfg_file), manager.active_config.sources)
        # a function returning the configuration works too; anything else is refused
        fn_file = joinpath(root, "fn_config.jl")
        write(fn_file, "() -> SimulationConfig(create_param_dict(:N => 30, :sim_func_name => :advection_solver_1d), " *
                       "create_method_dict(:upwind => create_param_dict(:scheme => \"upwind\")), [:upwind])\n")
        set_sim_config!(fn_file)
        @test manager.active_config.shared[:N] == 30
        bad_file = joinpath(root, "bad.jl")
        write(bad_file, "1 + 1\n")
        @test_throws ArgumentError set_sim_config!(bad_file)

        # 2. In the Files tab a file that runs code needs a second click (the first one only warns)
        click_button!(:tab_files)
        w[:export_text].stored_string[] = cfg_file
        click_button!(:load_config_button)
        @test occursin("click Load again", status()) && manager.active_config.shared[:N] == 30
        click_button!(:load_config_button)
        @test manager.active_config.shared[:N] == 24 && occursin("Loaded config.jl", status())

        # 3. Exports bundle the sources under their own names; reloading runs them at the original place
        PDEStudio.save_params_to_csv("exp", root, Dict{String, Any}())
        csv = joinpath(root, "exp.csv")
        @test isfile(joinpath(root, "exp_sources", "config.jl"))
        @test PDEStudio._load_runs_code(csv)
        set_sim_config!(fn_file)
        set_sim_config!(csv)
        @test manager.active_config.shared[:N] == 24 && isempty(manager.source_failures)

        # ... without the original folder the bundled config can't find its helper: the load still works, the
        # parameters come from the CSV and the status line says why
        rm(orig; recursive = true)
        set_sim_config!(fn_file)
        @test_logs (:error, r"failed") match_mode=:any set_sim_config!(csv)
        @test !isempty(manager.source_failures) && occursin("helper.jl", manager.source_failures[1])
        @test manager.active_config.shared[:N] == 24
        @test occursin("define the solvers", status())

        # ... with the helper listed in the sources it is bundled too, and the bundle works on its own
        cfg_file = write_config(orig; list_helper = true)
        set_sim_config!(cfg_file)
        PDEStudio.save_params_to_csv("exp2", root, Dict{String, Any}())
        @test isfile(joinpath(root, "exp2_sources", "helper.jl"))
        rm(orig; recursive = true)
        set_sim_config!(fn_file)
        set_sim_config!(joinpath(root, "exp2.csv"))
        @test isempty(manager.source_failures) && manager.active_config.shared[:N] == 24

        # 4. Dropping a CSV without sources loads it right away; other files are refused
        plain_csv = joinpath(root, "plain.csv")
        write(plain_csv, "Category,Scope,Parameter,Value\nSimulation,Shared,N,40\nSimulation,Shared,sim_func_name,:advection_solver_1d\n")
        @test !PDEStudio._load_runs_code(plain_csv)
        events(fig.scene).dropped_files[] = [plain_csv]
        @test manager.active_config.shared[:N] == 40
        events(fig.scene).dropped_files[] = [joinpath(root, "notes.txt")]
        @test occursin("Only CSV and Julia", status())

        # 5. Browse… asks FILE_DIALOG (the system dialog by default) and loads the chosen file
        default_dialog = PDEStudio.FILE_DIALOG[]
        try
            PDEStudio.FILE_DIALOG[] = () -> ""
            click_button!(:browse_button)
            @test wait_status(==("No file chosen."))
            PDEStudio.FILE_DIALOG[] = () -> fn_file             # Julia code: warns first
            click_button!(:browse_button)
            @test wait_status(s -> occursin("click Load again", s))
            @test w[:export_text].displayed_string[] == fn_file
            click_button!(:load_config_button)
            @test manager.active_config.shared[:N] == 30
            PDEStudio.FILE_DIALOG[] = () -> error("no display")
            click_button!(:browse_button)
            @test wait_status(s -> occursin("file dialog failed", s))
        finally
            PDEStudio.FILE_DIALOG[] = default_dialog
        end
        # without zenity/kdialog (as in CI) the system dialog explains what to do instead
        if !Sys.isapple() && !Sys.iswindows() && isnothing(Sys.which("zenity")) && isnothing(Sys.which("kdialog"))
            @test isnothing(PDEStudio._system_file_dialog()) && occursin("No file dialog found", status())
        end
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

        click_menu!(manager.widgets[:plot_style], :lines_1d)
        click_menu!(manager.widgets[:x_axis], :x)
        click_menu!(manager.widgets[:compare_target], :methods)
        click_button!(:layout_apply)
        @test first_method() == :upwind

        # 2. Reordering `defaults` (here in the Advanced tab) is the override; it takes effect with the next run
        show_editor_page!(:advanced, :config)
        type_into!(:defaults, "Symbol[:lax_friedrichs, :upwind]")
        @test manager.active_config.defaults == [:lax_friedrichs, :upwind]
        click_button!(:run_button)
        @test manager.methods[] == [:lax_friedrichs, :upwind]
        click_button!(:layout_apply)
        @test first_method() == :lax_friedrichs

        # 3. Activating a method appends it; a saved preset keeps the order
        toggle_method!(:analytic)
        @test manager.active_config.defaults == [:lax_friedrichs, :upwind, :analytic]
        @test save_sim_preset("ordered")
        manager.active_config.defaults = [:upwind]
        @test set_sim_preset!(:ordered).defaults == [:lax_friedrichs, :upwind, :analytic]

        # 4. Without explicit defaults the automatic order (references first) still applies
        set_sim_config!(SimulationConfig(shared, methods; reference = :exact_advection_factory))
        @test manager.methods[] == [:analytic, :lax_friedrichs, :upwind]
    end

    # =========================================================================
    # --- CONTROL TABS (fixed widgets, hidden panels parked off-screen) ---
    # =========================================================================
    @testset "Control tabs" begin
        reset_plotter!()
        fig = launch_plotter()
        display(fig)
        shared = create_param_dict(:cfl => 0.5, :N => 20, :sim_func_name => :advection_solver_1d)
        methods = create_method_dict(:upwind => create_param_dict(:scheme => "upwind"),
                                     :lax_friedrichs => create_param_dict(:scheme => "lax_friedrichs"))
        cfg = SimulationConfig(shared, methods, [:upwind, :lax_friedrichs])
        set_sim_config!(cfg)
        click_button!(:run_button)
        w = manager.widgets

        # A sample of the widgets each tab shows (the editor tabs open on their overview / the method list)
        tab_widgets = Dict(:plot => (:plot_style, :plot_width, :compare_link, :x_axis, :component),
                           :methods => (:method_filter, :method_row_1_a),
                           :shared => (:editor_row_1_text,), :ui => (:editor_page_1,),
                           :advanced => (:editor_page_1,),
                           :files => (:export_text, :preset_desc_text, :load_config_button, :export_button,
                                      :save_sim_preset_button, :clear_presets_button))
        sample = unique(vcat(collect.(values(tab_widgets))...))
        block(k) = w[k] isa PDEStudio.NumberBox ? w[k].box : w[k] isa PDEStudio.StyleChoice ? w[k].button : w[k]
        onscreen(b) = (bb = b.layoutobservables.computedbbox[]; all(minimum(bb) .>= 0))
        shown(k) = block(k).blockscene.visible[] && onscreen(block(k))
        hidden(k) = !block(k).blockscene.visible[] && !onscreen(block(k))

        @test manager.active_tab[] === :plot                       # a window opens on the Plot tab
        @test PDEStudio.TAB_PANELS[:plot] == (:layout, :plot)      # layout and plot options share a tab

        # 1. Every tab shows exactly its widgets; the always visible controls stay where they are
        always = (:run_button, :layout_apply, :plot_button, :play_anim_button)
        # positions are measured from the top of the tab bar (a rebuilt plot layout may resize the window)
        function from_top(k)
            tab_bb = w[:tab_plot].layoutobservables.computedbbox[]
            bb = block(k).layoutobservables.computedbbox[]
            return round.((maximum(tab_bb)[2] - minimum(bb)[2], minimum(bb)[1] - minimum(tab_bb)[1]); digits = 2)
        end
        always_pos = Dict(k => from_top(k) for k in always)
        for tab in PDEStudio.CONTROL_TABS
            click_button!(Symbol("tab_", tab))
            @test manager.active_tab[] === tab
            tab_bar_bottom = minimum(w[:tab_plot].layoutobservables.computedbbox[])[2]
            for k in sample
                @test k in tab_widgets[tab] ? shown(k) : hidden(k)
                # a panel never reaches into the tab bar (empty grid rows used to squeeze the editor upwards)
                k in tab_widgets[tab] && @test maximum(block(k).layoutobservables.computedbbox[])[2] <= tab_bar_bottom
            end
            @test all(k -> shown(k) && from_top(k) == always_pos[k], always)
        end

        # 2. Clicks reach only the visible widget, never a hidden one at the same place in another tab
        center(b) = (bb = b.layoutobservables.computedbbox[]; Tuple(Float64.(minimum(bb) .+ widths(bb) ./ 2)))
        function mouse_click!(pos)
            e = events(fig)
            e.mouseposition[] = pos
            e.mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.press)
            e.mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.release)
            e.mouseposition[] = (0.0, 0.0)
        end
        show_tab!(:methods)
        filter_pos = center(w[:method_filter])
        filter_before = manager.method_filter
        mouse_click!(filter_pos)
        @test manager.method_filter != filter_before               # the visible button reacts …
        show_tab!(:files)
        sleep(0.5)                                                 # (not a double click)
        clicks_before = w[:method_filter].clicks[]
        mouse_click!(filter_pos)                                   # … the parked one doesn't
        @test w[:method_filter].clicks[] == clicks_before
        manager.method_filter = :all
        show_tab!(:plot)
        mouse_click!(center(w[:x_axis]))
        @test w[:x_axis].is_open[]
        w[:x_axis].is_open[] = false

        # 3. Switching tabs releases open menus and the keyboard focus, and never touches the plot
        ax = first(c for c in fig.content if c isa Axis)
        viewport_updates = Ref(0)
        obs = on(_ -> viewport_updates[] += 1, ax.scene.viewport)
        w[:x_axis].is_open[] = true
        show_editor_page!(:shared)
        @test !w[:x_axis].is_open[]
        Makie.focus!(w[:editor_row_1_text])
        show_tab!(:plot)
        @test !w[:editor_row_1_text].focused[]
        for tab in PDEStudio.CONTROL_TABS; show_tab!(tab); end
        show_editor_page!(:ui, :x_axis_1d)
        show_editor_page!(:ui)
        show_editor_page!(:methods, PDEStudio.ORDER_VIEW)
        @test viewport_updates[] == 0
        off(obs)
        @test_throws ArgumentError show_tab!(:nonsense)
        @test_throws ArgumentError show_editor_page!(:nonsense)

        # 4. Editor pages: one row per key, the unused rows and buttons parked; ◀ ▶ pages for long scopes
        n_rows = PDEStudio.EDITOR_ROWS
        many = create_param_dict(:sim_func_name => :advection_solver_1d, (Symbol("p", lpad(i, 2, '0')) => i for i in 1:n_rows + 2)...)
        set_sim_config!(SimulationConfig(many, methods, [:upwind]))
        show_editor_page!(:advanced)
        @test shown(:editor_page_4) && hidden(:editor_page_5)  # shared, sweep, config, methods
        @test hidden(:editor_back) && hidden(:editor_next) && hidden(:method_filter)
        show_editor_page!(:shared)
        @test w[:editor_title][] == "Shared parameters  (1/2)"
        @test length(manager.editor_row_keys) == n_rows
        @test hidden(:editor_back) && shown(:editor_next)
        @test shown(Symbol("editor_row_", n_rows, "_text")) && hidden(:editor_page_1)
        click_button!(:editor_next)
        @test w[:editor_title][] == "Shared parameters  (2/2)"
        last_key = Symbol("p", lpad(n_rows + 2, 2, '0'))
        @test manager.editor_row_keys == [Symbol("p", lpad(n_rows + 1, 2, '0')), last_key, :sim_func_name]
        @test shown(:editor_row_3_text) && hidden(:editor_row_4_text) && hidden(:editor_row_4_button)
        type_into!(last_key, "140")                            # rows write into the scope of the page
        @test manager.active_config.shared[last_key] == 140
        click_button!(:editor_next)                            # stays on the last page
        @test w[:editor_title][] == "Shared parameters  (2/2)"
        click_button!(:editor_prev)
        @test first(manager.editor_row_keys) === :p01
        # Bool values get an on/off button
        show_editor_page!(:ui, :x_axis_1d)
        @test editor_row(:log_scale).button.label[] == "off"
        press_row!(:log_scale)
        @test manager.ui[:x_axis_1d][:log_scale] == true
        @test editor_row(:log_scale).button.label[] == "on" && editor_row(:log_scale).text.displayed_string[] == "true"
        press_row!(:log_scale)
        @test manager.ui[:x_axis_1d][:log_scale] == false

        # 4b. Plot width, height and grid columns take any whole number in range; other input is refused
        show_tab!(:plot)
        width_box = w[:plot_width].box
        width_box.stored_string[] = "abc"
        @test w[:plot_width].selection[] == manager.layout_cache[:plot_width]
        @test occursin("Plot Width", w[:status][]) && w[:status_color][] == PDEStudio.STATUS_COLORS[:warn]
        @test width_box.displayed_string[] == string(w[:plot_width].selection[])   # the old value is shown again
        width_box.stored_string[] = "20"                       # below the minimum
        @test w[:plot_width].selection[] != 20
        width_box.stored_string[] = "650"
        @test w[:plot_width].selection[] == 650 && manager.flags[:Layout][] == true
        w[:compare_columns].box.stored_string[] = "7"          # more than the old menu offered
        @test w[:compare_columns].selection[] == 7
        click_button!(:layout_apply)
        @test manager.layout_cache[:plot_width] == 650 && manager.layout_cache[:compare_columns] == 7
        PDEStudio.apply_layout_options!(Dict{Symbol, Any}(:plot_width => 480, :compare_columns => 2))   # presets / CSV files
        @test w[:plot_width].selection[] == 480 && w[:plot_width].box.displayed_string[] == "480"
        @test w[:compare_columns].selection[] == 2
        click_button!(:layout_apply)

        # 4c. The plot style is chosen on a page of all styles (grouped by base plot, the current one highlighted)
        set_sim_config!(cfg)
        click_button!(:run_button)
        euler_styles = Set(o[2] for opts in values(EULERIAN_PLOT_STYLE_OPTIONS) for o in opts)
        show_tab!(:plot)
        click_button!(:layout_apply)
        style_btn = w[:plot_style].button
        @test style_btn.label[] == "1D Lines  ›"
        style_btn.clicks[] += 1
        @test manager.active_tab[] === :plot && w[:editor_title][] == "Plot style"
        @test hidden(:x_axis) && shown(:editor_back)           # the page replaces the options
        @test Set(manager.editor_page_scopes) == euler_styles   # (scatter_surface is a Lagrangian style)
        @test [w[Symbol("editor_section_", k)].text[] for k in 1:5] == ["Lines", "Scatter", "Contour", "Heatmap", "Volume"]
        j_active = findfirst(isequal(:lines_1d), manager.editor_page_scopes)
        @test w[Symbol("editor_page_", j_active)].buttoncolor[] != w[:editor_page_2].buttoncolor[]
        click_button!(:editor_back)                            # back without a change
        @test w[:plot_style].selection[] === :lines_1d && shown(:x_axis)
        style_btn.clicks[] += 1
        j = findfirst(isequal(:scatter_lines), manager.editor_page_scopes)
        w[Symbol("editor_page_", j)].clicks[] += 1
        @test w[:plot_style].selection[] === :scatter_lines && shown(:x_axis)
        @test style_btn.label[] == "Scatter Lines  ›" && manager.flags[:Layout][] == true
        click_button!(:layout_apply)
        @test manager.active_plot_type === :scatter_lines

        # 4d. The UI overview is static: general scopes, every axis variant and every plot type
        show_editor_page!(:ui)
        @test [w[Symbol("editor_section_", k)].text[] for k in 1:4] == ["General", "Labels", "Axes", "Plot styles"]
        @test manager.editor_page_scopes[1:12] == [:axis_general, :hud, :outliers_extrema,
                                                   :labels, :components, :variables, :methods,
                                                   :x_axis_1d, :y_axis_1d, :x_axis_nd, :y_axis_nd, :z_axis_3d]
        @test w[:editor_page_4].label[] == "Plot"               # the titles and axis labels of the plot
        @test Set(manager.editor_page_scopes[13:end]) == euler_styles
        @test !(:export in manager.editor_page_scopes)        # the export settings are in the Files tab
        open_scope!(:heatmap_flat)                             # a plot type lists the options it uses
        @test Set(manager.editor_row_keys) == Set(PDEStudio.STYLE_DEPENDENCIES[:heatmap_flat])
        @test w[:editor_title][] == "Heatmap Flat"
        type_into!(:color_map, ":plasma")
        @test manager.ui[:plot_style][:color_map] === :plasma
        # axis variants are kept separately: 1D settings survive a 2D plot and back
        show_editor_page!(:ui, :x_axis_1d)
        type_into!(:padding, "0.3")
        click_menu!(w[:plot_style], :heatmap_flat)
        set_axes_for_dim!(2)
        @test manager.active_plot_type === :heatmap_flat
        @test PDEStudio._axis_ui(:x_axis) === manager.ui[:x_axis_nd]
        click_menu!(w[:plot_style], :lines_1d)
        set_axes_for_dim!(1)
        @test PDEStudio._axis_ui(:x_axis) === manager.ui[:x_axis_1d] && manager.ui[:x_axis_1d][:padding] == 0.3
        # older files and the built-in presets name the active variant `x_axis`
        PDEStudio.set_ui_opt!(:x_axis, :padding, 0.1)
        @test manager.ui[:x_axis_1d][:padding] == 0.1 && !haskey(manager.ui, :x_axis)

        # 4e. The export settings are a page of the Files tab
        click_button!(:tab_files)
        click_button!(:export_settings_button)
        @test w[:editor_title][] == "Export settings" && :animation_FPS in manager.editor_row_keys
        @test hidden(:load_config_button)
        click_button!(:editor_back)
        @test shown(:load_config_button) && manager.active_tab[] === :files

        # 4f. The resolution of the data and the references is a page of the Files tab
        click_button!(:resolution_button)
        @test startswith(w[:editor_title][], "Resolution")
        @test first(manager.editor_row_keys) == (:x, false) && (:t, true) in manager.editor_row_keys
        i = findfirst(isequal((:x, false)), manager.editor_row_keys)
        w[Symbol("editor_row_", i, "_text")].stored_string[] = "300"
        @test PDEStudio.get_resolution(:x) == 300 && manager.flags[:Simulation][] == true
        w[Symbol("editor_row_", i, "_text")].stored_string[] = "abc"
        @test PDEStudio.get_resolution(:x) == 300 && occursin("whole number", w[:status][])
        w[Symbol("editor_row_", i, "_button")].clicks[] += 1   # ↺ restores the default
        @test PDEStudio.get_resolution(:x) == 200
        j = findfirst(isequal((:t, true)), manager.editor_row_keys)
        @test w[Symbol("editor_row_", j, "_text")].displayed_string[] == string(PDEStudio.get_resolution(:t; is_ref = true))
        click_button!(:editor_back)
        @test shown(:load_config_button)
        click_button!(:run_button)

        # 4g. The display names (Labels) and the titles and axis labels of the plot ("Plot") are UI pages
        show_editor_page!(:ui, :methods)
        @test w[:editor_title][] == "Methods" && :upwind in manager.editor_row_keys
        type_into!(:upwind, "Upwind scheme")
        @test manager.labels[:upwind] == "Upwind scheme"
        press_row!(:upwind)                                    # ↺: the built-in name
        @test manager.labels[:upwind] == PDEStudio.frontend_key(:upwind) || manager.labels[:upwind] == "upwind"
        show_editor_page!(:ui, :labels)
        @test w[:editor_title][] == "Plot" && :title in manager.editor_row_keys
        type_into!(:title, "My run")
        @test manager.ui[:labels][:title] == "My run"
        type_into!(:title, "default")

        # 5. Slider rows: only the sliders with a choice to make are shown (no sweep, X on the plot axis here)
        show_tab!(:plot)
        @test shown(:t)
        @test hidden(:param_1) && hidden(:x) && hidden(:y)
        sweep_cfg = SimulationConfig(shared, methods, [:upwind]; varied = create_varied_dict(:cfl => [0.2, 0.5]))
        set_sim_config!(sweep_cfg)
        click_button!(:run_button)
        @test shown(:param_1) && shown(:t)
        @test maximum(w[:param_1].layoutobservables.computedbbox[])[2] > maximum(w[:t].layoutobservables.computedbbox[])[2]
        @test all(k -> from_top(k) == always_pos[k], always)   # the rest stays put

        # 6. Setting a configuration doesn't switch tabs; a rebuilt window opens on the Plot tab and the overviews
        show_tab!(:files)
        set_sim_config!(cfg)
        @test manager.active_tab[] === :files
        show_editor_page!(:ui, :methods)
        fig = launch_plotter()
        display(fig)
        @test manager.active_tab[] === :plot
        @test manager.widgets[:x_axis].blockscene.visible[] && !manager.widgets[:editor_page_1].blockscene.visible[]
        click_button!(:tab_ui)
        @test isnothing(first(manager.editor_view[:ui]))       # the overview again
    end

    # =========================================================================
    # --- METHODS TAB: LIST, FILTER, EDIT, DRAWING ORDER ---
    # =========================================================================
    @testset "Methods tab" begin
        reset_plotter!()
        fig = launch_plotter()
        display(fig)
        shared = create_param_dict(:cfl => 0.5, :N => 20, :sim_func_name => :advection_solver_1d)
        methods = create_method_dict(:upwind => create_param_dict(:scheme => "upwind"),
                                     :lax_friedrichs => create_param_dict(:scheme => "lax_friedrichs"),
                                     :analytic => create_param_dict())
        cfg = SimulationConfig(shared, methods, [:upwind, :lax_friedrichs]; reference = :exact_advection_factory)
        set_sim_config!(cfg)
        click_button!(:run_button)
        w = manager.widgets
        row_button(m, which) = w[Symbol("method_row_", findfirst(isequal(m), manager.editor_row_keys), "_", which)]
        row_label(m) = w[Symbol("method_row_", findfirst(isequal(m), manager.editor_row_keys), "_label")][]

        # 1. The list: every method in the automatic order, with its state
        manager.method_filter = :all
        click_button!(:tab_methods)
        @test manager.editor_row_keys == [:analytic, :lax_friedrichs, :upwind]
        @test w[:editor_title][] == "Methods  (2 of 3 active)"
        @test row_button(:upwind, :a).label[] == "active" && row_button(:analytic, :a).label[] == "off"
        @test row_button(:upwind, :b).label[] == "Edit ›"

        # 2. The filter cycles active → disabled → all
        click_button!(:method_filter)                          # all → active
        @test manager.method_filter === :active && manager.editor_row_keys == [:lax_friedrichs, :upwind]
        @test w[:method_filter].label[] == "Show: active"
        click_button!(:method_filter)
        @test manager.editor_row_keys == [:analytic]
        click_button!(:method_filter)
        @test manager.method_filter === :all

        # 3. Activating appends to the drawing order and flags a run; deactivating removes the method
        row_button(:analytic, :a).clicks[] += 1
        @test manager.active_config.defaults == [:upwind, :lax_friedrichs, :analytic]
        @test manager.flags[:Simulation][] == true
        @test row_button(:analytic, :a).label[] == "active"
        @test w[:status][] == "analytic activated. Run Simulation to apply."
        row_button(:lax_friedrichs, :a).clicks[] += 1
        @test manager.active_config.defaults == [:upwind, :analytic]
        row_button(:lax_friedrichs, :a).clicks[] += 1
        @test manager.active_config.defaults == [:upwind, :analytic, :lax_friedrichs]

        # 4. Edit opens the parameters of a method, also of an inactive one; ◀ Back returns to the list
        row_button(:upwind, :b).clicks[] += 1
        @test w[:editor_title][] == "upwind" && manager.editor_row_keys == [:scheme]
        @test !w[:method_filter].blockscene.visible[]          # the tools belong to the list
        click_button!(:editor_back)
        @test manager.editor_row_keys == [:analytic, :lax_friedrichs, :upwind]

        # 5. The drawing order: active methods in `defaults` order, moved with ▲ ▼
        click_button!(:method_order)
        @test w[:editor_title][] == "Drawing order (top first)"
        @test manager.editor_row_keys == [:upwind, :analytic, :lax_friedrichs]
        @test row_label(:analytic) == "2.  analytic"
        @test w[:method_order].label[] == "◀ Method list"
        row_button(:lax_friedrichs, :a).clicks[] += 1          # ▲
        @test manager.active_config.defaults == [:upwind, :lax_friedrichs, :analytic]
        row_button(:upwind, :a).clicks[] += 1                  # ▲ on the first: nothing happens
        row_button(:analytic, :b).clicks[] += 1                # ▼ on the last: nothing happens
        @test manager.active_config.defaults == [:upwind, :lax_friedrichs, :analytic]
        row_button(:upwind, :b).clicks[] += 1                  # ▼
        @test manager.editor_row_keys == [:lax_friedrichs, :upwind, :analytic]
        @test occursin("position 2", w[:status][])
        # … the order is the drawing order after the next run
        click_button!(:run_button)
        @test manager.methods[] == [:lax_friedrichs, :upwind, :analytic]
        click_button!(:tab_methods)
        @test first(manager.editor_view[:methods]) === PDEStudio.ORDER_VIEW   # the tab keeps its view
        click_button!(:method_order)
        @test isnothing(first(manager.editor_view[:methods]))

        # 6. Long lists get pages; the page of a method that no longer exists falls back to the list
        lots = create_method_dict((Symbol("m", lpad(i, 2, '0')) => create_param_dict(:scheme => "upwind") for i in 1:PDEStudio.EDITOR_ROWS + 1)...)
        set_sim_config!(SimulationConfig(shared, lots, sort!(collect(keys(lots)))))
        show_editor_page!(:methods)
        @test w[:editor_title][] == "Methods  ($(PDEStudio.EDITOR_ROWS + 1) of $(PDEStudio.EDITOR_ROWS + 1) active)  (1/2)"
        @test length(manager.editor_row_keys) == PDEStudio.EDITOR_ROWS
        click_button!(:editor_next)
        @test manager.editor_row_keys == [Symbol("m", lpad(PDEStudio.EDITOR_ROWS + 1, 2, '0'))]
        @test w[:method_row_1_a].blockscene.visible[] && !w[:method_row_2_a].blockscene.visible[]
        show_editor_page!(:methods, Symbol("m", lpad(PDEStudio.EDITOR_ROWS + 1, 2, '0')))
        @test manager.editor_row_keys == [:scheme]
        set_sim_config!(cfg)
        @test isnothing(first(manager.editor_view[:methods]))
        @test :upwind in manager.editor_row_keys

        # 7. Without methods nothing runs, and the status line says why
        manager.method_filter = :active
        show_editor_page!(:methods)
        for m in copy(manager.editor_row_keys)
            row_button(m, :a).clicks[] += 1
        end
        @test isempty(manager.active_config.defaults)
        click_button!(:run_button)
        @test occursin("No methods selected", w[:status][]) && w[:status_color][] == PDEStudio.STATUS_COLORS[:warn]
        manager.method_filter = :all
    end

    # =========================================================================
    # --- ADVANCED TAB: THE SIMULATIONCONFIG ITSELF ---
    # =========================================================================
    @testset "Advanced tab (raw configuration)" begin
        reset_plotter!()
        fig = launch_plotter()
        display(fig)
        shared = create_param_dict(:cfl => 0.5, :N => 20, :sim_func_name => :advection_solver_1d)
        methods = create_method_dict(:upwind => create_param_dict(:scheme => "upwind"),
                                     :lax_friedrichs => create_param_dict(:scheme => "lax_friedrichs"))
        set_sim_config!(SimulationConfig(shared, methods, [:upwind]; varied = create_varied_dict(:cfl => [0.2, 0.5])))
        click_button!(:run_button)
        w = manager.widgets
        config = manager.active_config
        function add_raw!(key, T, value)
            w[:raw_add_key].stored_string[] = key
            w[:raw_add_type].i_selected[] = findfirst(o -> o[2] === T, w[:raw_add_type].options[])
            w[:raw_add_value].stored_string[] = value
            click_button!(:raw_add_button)
        end

        # 1. The overview: the raw scopes and every method (inactive ones too)
        click_button!(:tab_advanced)
        @test manager.editor_page_scopes == [:shared, :sweep, :config, PDEStudio.ADV_METHODS]
        @test w[:editor_page_4].label[] == "Methods (2) ›"
        open_scope!(PDEStudio.ADV_METHODS)                       # every method, on full-width rows
        @test manager.editor_row_keys == [:lax_friedrichs, :upwind]
        @test w[:method_row_2_label][] == "upwind  (active)"
        click_button!(:editor_back)

        # 2. Values are shown and parsed as Julia literals: types are visible, text needs quotes
        open_scope!(:shared)
        @test w[:editor_title][] == "Shared  (raw)"
        @test editor_row(:sim_func_name).text.displayed_string[] == ":advection_solver_1d"
        @test editor_row(:N).button.label[] == "✕"
        type_into!(:N, "30")
        @test config.shared[:N] === 30 && manager.flags[:Simulation][] == true
        type_into!(:N, "abc")                                   # no literal: refused
        @test config.shared[:N] === 30 && occursin("no literal", w[:status][])
        type_into!(:N, "\"abc\"")                             # quoted text is text
        @test config.shared[:N] == "abc"
        type_into!(:N, "20")
        show_editor_page!(:advanced, :lax_friedrichs)           # an inactive method
        @test editor_row(:scheme).text.displayed_string[] == "\"lax_friedrichs\""

        # 3. The sweep takes vectors only (no conversion of single values)
        show_editor_page!(:advanced, :sweep)
        @test editor_row(:cfl).text.displayed_string[] == "Float64[0.2, 0.5]"
        type_into!(:cfl, "0.3")
        @test config.varied[:cfl] == [0.2, 0.5] && occursin("vector", w[:status][])
        type_into!(:cfl, "[0.2, 0.3, 0.5]")
        @test config.varied[:cfl] == [0.2, 0.3, 0.5]

        # 4. The fields of the configuration: raw values, no ✕
        show_editor_page!(:advanced, :config)
        @test manager.editor_row_keys == [:defaults, :reference, :postprocess, :sources]
        @test editor_row(:defaults).text.displayed_string[] == "Symbol[:upwind]"
        @test editor_row(:reference).text.displayed_string[] == "nothing"
        @test hidden_now(:raw_add_key)                          # nothing can be added here
        press_row!(:defaults)
        @test config.defaults == [:upwind]

        # 5. Adding keys with a type; existing keys and impossible values are refused; ✕ deletes
        show_editor_page!(:advanced, :shared)
        add_raw!("p", :Float64, "1")
        @test config.shared[:p] === 1.0
        add_raw!("names", Symbol("Vector{Symbol}"), "[a, b]")
        @test config.shared[:names] == [:a, :b] && eltype(config.shared[:names]) === Symbol
        add_raw!("tag", :String, "upwind")
        @test config.shared[:tag] == "upwind"
        add_raw!("bad", :auto, "abc")
        @test !haskey(config.shared, :bad) && occursin("no literal", w[:status][])
        add_raw!("bad", :Int, "1.5")
        @test !haskey(config.shared, :bad)
        add_raw!("N", :Int, "5")
        @test config.shared[:N] === 20 && occursin("exists already", w[:status][])
        press_row!(:p)
        @test !haskey(config.shared, :p)
        show_editor_page!(:advanced, :sweep)
        add_raw!("N", :auto, "[10, 20]")
        @test config.varied[:N] == [10, 20]
        @test :N in values(manager.param_map)                  # a new swept key gets a slider
        press_row!(:N)
        @test !haskey(config.varied, :N)

        # 6. The method list: Edit ›, ✕ deletes (also from the active methods), a new method is added (inactive)
        show_editor_page!(:advanced, PDEStudio.ADV_METHODS)
        @test shown_now(:method_add_button)
        w[:method_add_name].stored_string[] = "new_scheme"
        click_button!(:method_add_button)
        @test haskey(config.methods, :new_scheme) && !(:new_scheme in config.defaults)
        @test w[:editor_title][] == "new_scheme  (raw)"         # its page is open
        add_raw!("scheme", :String, "upwind")
        @test config.methods[:new_scheme][:scheme] == "upwind"
        click_button!(:editor_back)                            # back to the method list
        @test first(manager.editor_view[:advanced]) === PDEStudio.ADV_METHODS
        i = findfirst(isequal(:upwind), manager.editor_row_keys)
        w[Symbol("method_row_", i, "_b")].clicks[] += 1         # ✕
        @test !haskey(config.methods, :upwind) && isempty(config.defaults)
        @test !(:upwind in manager.editor_row_keys)
        i = findfirst(isequal(:lax_friedrichs), manager.editor_row_keys)
        w[Symbol("method_row_", i, "_a")].clicks[] += 1         # Edit ›
        @test w[:editor_title][] == "lax_friedrichs  (raw)"
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
        @test manager.layout_cache[:plot_style] == :heatmap_flat
        
        set_plot_preset!(:compact3d)
        yield()
        @test manager.ui[:z_axis_3d][:label_offset] == 15.0
        
        set_plot_preset!(:nolabels)
        yield()
        @test manager.ui[:labels][:x_label] == ""
        @test manager.ui[:labels][:y_label] == ""

        # 2. Test via the editor: UI → Presets, the Apply button of a preset's row

        click_menu!(manager.widgets[:plot_style], :lines_1d)
        
        click_menu!(manager.widgets[:x_axis], :x)
        click_menu!(manager.widgets[:y_axis], :none)
        click_menu!(manager.widgets[:z_axis], :none)
        click_button!(:layout_apply)

        open_presets!(:visual)
        press_preset!(:darkmode, :a)
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
        show_editor_page!(:ui, :hud)
        @test_logs (:warn, r"not a valid colour") type_into!(:color, "rde")
        @test manager.ui[:hud][:color] == :red
        type_into!(:color, ":blue")
        @test manager.ui[:hud][:color] == :blue
        type_into!(:color, ":red")

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

        # Lagrangian data offers only the scatter styles of its dimension (1D here)
        @test manager.allowed_styles == [:scatter_1d, :scatter_lines, :scatter_colors]

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
