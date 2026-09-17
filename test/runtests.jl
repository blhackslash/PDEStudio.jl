using Test
using PDEStudio
using GLMakie
using WGLMakie

function dummy_simulation_function(args...); return nothing; end

const DUMMY_CONFIG = SimulationConfig(dummy_simulation_function, :none, nothing, :none, (_ -> false), :none, ParamDict(), MethodDict(), Symbol[], VariedDict(), String[])

@testset "PDEStudio.jl Test Suite" begin

    @testset "GLMakie (Local Desktop) Backend" begin
        GLMakie.activate!()
        
        fig = launch_plotter()
        @test fig isa Figure
        @test !isempty(fig.content) 
        
        # Execute directly. If it crashes, the test suite will register an Error.
        set_sim_config!(DUMMY_CONFIG)
        @test true # Explicitly log a passing test
        
        reset_plotter!()
        @test true
    end

    @testset "WGLMakie (Browser) Backend" begin
        WGLMakie.activate!()
        
        fig = launch_plotter()
        @test fig isa Figure
        
        set_sim_config!(DUMMY_CONFIG)
        @test true
        
        reset_plotter!()
        @test true
    end
    
end