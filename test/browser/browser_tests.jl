# The studio in a real browser (WGLMakie + Bonito, headless Chromium driven by test/browser/upload.js): uploads with
# Browse… and drag & drop. Needs node, `npm ci` in test/browser and a Chromium (on the PATH as `chromium`, in
# PDESTUDIO_CHROMIUM, or Playwright's own: `npx playwright-core install chromium`).
# PDESTUDIO_BROWSER_TESTS: `auto` (default) runs them if all of that is there, `true` requires them (CI), `false` skips.
const BROWSER_DIR = @__DIR__

function _browser_test_setup()
    mode = lowercase(get(ENV, "PDESTUDIO_BROWSER_TESTS", "auto"))
    mode == "false" && return nothing, "PDESTUDIO_BROWSER_TESTS=false"
    node = Sys.which("node")
    chromium = get(ENV, "PDESTUDIO_CHROMIUM", something(Sys.which("chromium"), ""))
    playwright_browsers = isdir(get(ENV, "PLAYWRIGHT_BROWSERS_PATH", joinpath(homedir(), ".cache", "ms-playwright")))
    missing = String[]
    isnothing(node) && push!(missing, "node")
    isdir(joinpath(BROWSER_DIR, "node_modules", "playwright-core")) || push!(missing, "playwright-core (npm ci in test/browser)")
    isempty(chromium) && !playwright_browsers && push!(missing, "a Chromium")
    isempty(missing) && return (node = node, chromium = chromium), ""
    reason = "missing " * join(missing, ", ")
    mode == "true" && error("Browser tests required (PDESTUDIO_BROWSER_TESTS=true), but $reason.")
    return nothing, reason
end

@testset "PDEStudio: Browser (WGLMakie)" begin
    setup, reason = _browser_test_setup()
    if isnothing(setup)
        @info "Skipping the browser tests: $reason."
        @test_skip false
    else
        dir = mktempdir()
        set_save_path!(joinpath(dir, "save"))
        set_mode!(:eulerian)
        reset_plotter!()
        WGLMakie.activate!()

        # Files to upload: a plain CSV, and an export whose bundled sources exist only next to it
        files = joinpath(dir, "files")
        mkpath(files)
        write(joinpath(files, "plain.csv"),
              "Category,Scope,Parameter,Value\nSimulation,Shared,N,40\nSimulation,Shared,sim_func_name,:advection_solver_1d\n")
        orig = mktempdir()
        write(joinpath(orig, "helper.jl"), "helper_N() = 24\n")
        write(joinpath(orig, "config.jl"), """
            include("helper.jl")
            SimulationConfig(create_param_dict(:N => helper_N(), :cfl => 0.5, :sim_func_name => :advection_solver_1d),
                             create_method_dict(:upwind => create_param_dict(:scheme => "upwind")), [:upwind];
                             sources = [joinpath(@__DIR__, "helper.jl")])
            """)
        set_sim_config!(joinpath(orig, "config.jl"))
        PDEStudio.save_params_to_csv("exp2", files, Dict{String, Any}())
        rm(orig; recursive = true)
        set_sim_config!(SimulationConfig(create_param_dict(:N => 30, :cfl => 0.5, :sim_func_name => :advection_solver_1d),
                                         create_method_dict(:upwind => create_param_dict(:scheme => "upwind")), [:upwind]))
        fig = launch_plotter()

        # The state the driver checks, written as JSON every 0.2 s
        ext = Base.get_extension(PDEStudio, :PDEStudioWGLMakieExt)
        w = manager.widgets
        json(x::AbstractString) = "\"" * escape_string(x) * "\""
        json(x::Number) = string(x)
        json(x::AbstractVector) = "[" * join(json.(x), ",") * "]"
        bbox(sym) = (r = w[sym].layoutobservables.computedbbox[]; Float64[r.origin..., r.widths...])
        function write_state()
            cfg = manager.active_config
            fields = ["status" => replace(w[:status][], '\n' => ' '),
                      "N" => isnothing(cfg) ? -1 : cfg.shared[:N],
                      "sessions" => length(ext.UPLOADS),
                      "path_box" => PDEStudio._box_text(w[:export_text]),
                      "source_failures" => manager.source_failures,
                      "fig_height" => fig.scene.viewport[].widths[2],
                      "tab_files" => bbox(:tab_files), "browse" => bbox(:browse_button), "load" => bbox(:load_config_button)]
            write(joinpath(dir, "state.tmp"), "{" * join(["\"$k\": " * json(v) for (k, v) in fields], ", ") * "}")
            mv(joinpath(dir, "state.tmp"), joinpath(dir, "state.json"); force = true)
        end

        server = WGLMakie.Bonito.Server(WGLMakie.Bonito.App(() -> fig), "127.0.0.1", 0)   # 0: any free port
        port = server.port
        running = Ref(true)
        poller = @async while running[]
            try
                write_state()
                cmd_file = joinpath(dir, "cmd")
                if isfile(cmd_file)   # Browse… without a click in the browser (the driver's request)
                    rm(cmd_file)
                    @async PDEStudio._browse_for_config()
                end
            catch e
                @error "Writing the browser test state failed" exception = (e, catch_backtrace())
            end
            sleep(0.2)
        end
        try
            env = ["PDESTUDIO_E2E_DIR" => dir, "PDESTUDIO_E2E_URL" => "http://127.0.0.1:$port/"]
            isempty(setup.chromium) || push!(env, "PDESTUDIO_CHROMIUM" => setup.chromium)
            cmd = Cmd(`$(setup.node) $(joinpath(BROWSER_DIR, "upload.js"))`; dir = BROWSER_DIR)
            run(addenv(ignorestatus(cmd), env...))
            results_file = joinpath(dir, "results.json")
            @test isfile(results_file)
            if isfile(results_file)
                text = read(results_file, String)
                steps = [m.captures for m in eachmatch(r"\"step\":\"((?:[^\"\\]|\\.)*)\",\"ok\":(true|false),\"message\":\"((?:[^\"\\]|\\.)*)\"", text)]
                @test length(steps) == 7
                for (step, ok, message) in steps
                    @testset "$step" begin
                        ok == "true" || @info "Browser step failed: $step: $(unescape_string(message))"
                        @test ok == "true"
                    end
                end
            end
        finally
            running[] = false
            wait(poller)
            close(server)
            reset_plotter!()
            GLMakie.activate!()
        end
    end
end
