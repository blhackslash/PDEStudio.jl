module IPlotPDESols

export show1DSolutionFig, show2DSolutionFig, showDynamicDependence, showConvergencePlot, saveSimData,show2DConvergencePlot,
       calculateHash, getFileName, loadSimData, getStats, doesSimDataExist, deleteSimData, 
       getAllSimData, changeStats, set_save_path!, get_save_path,
       ParamDict, MethodDict, SimulationConfig, SimData1D, SimData2D, createSimData,
       AbstractSimData, ParamDictType, MethodDictType, calculateConvergenceData, allMethodNames,
       calculateAllStats!, AtomicType, AtomicTuple, create_sim_config_from_csv, plotFromCSV, interactiveCSVLauncher,
       show2DCutFig, registerSimFunction!, getSimFunction, registerAllFunctions

const SIMULATION_FUNCTION_REGISTRY = Dict{Symbol, Function}()

"""
    register_simulation_function!(name::Symbol, func::Function)

Registers a simulation function handle with the plotting package.
This should be called from your main script.
"""
function register_simulation_function!(name::Symbol, func::Function)
    if haskey(SIMULATION_FUNCTION_REGISTRY, name)
        @warn "Redefining simulation function: $name"
    end
    SIMULATION_FUNCTION_REGISTRY[name] = func
    @info "Registered simulation function: :$name"
end

"""
    getSimFunction(name::Symbol) -> Union{Function, Nothing}

Retrieves a registered simulation function handle by its name.
"""
function getSimFunction(name::Symbol)
    func = get(SIMULATION_FUNCTION_REGISTRY, name, nothing)
    if isnothing(func)
        @error "No simulation function found for name ':$name'. 
               Was it registered from your main script?"
    end
    return func
end

"""
    register_functions_from_directory(sim_dir::String)

Scans the specified directory and registers functions
where the function name (as a Symbol) matches the filename.
Assumes functions are loaded into the `Main` module.
"""
function registerAllFunctions(sim_dir::String = (pwd() * "/SimulationFunctions"))
    if !isdir(sim_dir)
        @error "Directory not found: $sim_dir"
        @error "Cannot register functions. Make sure 'SimulationFunctions' exists."
        return
    end

    @info "Scanning $sim_dir for functions to register..."

    # Loop through files in the directory
    for file in readdir(sim_dir)
        # Check if it's a Julia file
        if endswith(file, ".jl")
            # Extract the name without the .jl extension
            # e.g., "my_function.jl" -> "my_function"
            name_str = first(split(file, ".jl"))

            # Convert the string name to a Symbol
            # e.g., "my_function" -> :my_function
            name_sym = Symbol(name_str)

            try
                # Get the function from the Main module scope
                # This assumes the 'include' was done in Main
                # and the function name matches the filename.
                func = getfield(Main, name_sym)

                if func isa Function
                    # Register the function
                    register_simulation_function!(name_sym, func)
                else
                    @warn "Found :$name_sym, but it is not a Function. Skipping."
                end
            catch e
                @error "Could not register :$name_sym."
                if e isa UndefVarError
                    @error "Error: Function :$name_sym is not defined in Main."
                    @error "Ensure $file defines a function named '$name_str'."
                else
                    showerror(stderr, e)
                    println(stderr) # Add a newline
                end
            end
        end
    end
    @info "Finished registering simulation functions."
    @info "Current registry: $(keys(SIMULATION_FUNCTION_REGISTRY))"
end

include("Structs.jl")
using .Structs

include("Utils.jl")
using .Utils

include("StatCalculation.jl")
using .StatCalculation

include("MakiePlotting.jl")
using .MakiePlotting

end