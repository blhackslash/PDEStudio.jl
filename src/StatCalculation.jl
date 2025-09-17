module StatCalculation

using ..Structs
using ..Utils

using Dierckx
using QuadGK
using ProgressMeter
using Random


export calculateAllStats!, calculateConvergenceData

"""
    _create_piecewise_spline_function(x_coords, y_values, domain_params, discontinuity_points, k)

Creates a callable, piecewise spline function. The domain is broken into smooth
sub-intervals at the discontinuity points. A separate spline is created for each piece.
"""
function _create_piecewise_spline_function(
    x_coords::AbstractVector{<:Real}, 
    y_values::AbstractVector{<:Real}, 
    breakpoints::AbstractVector{<:Real},
    dierckx_k::Int
)
    if isempty(x_coords)
        return x -> 0.0 # Return a zero function if there's no data
    end

    splines = Dierckx.Spline1D[] # A vector to hold a spline for each smooth segment

    for i in 1:(length(breakpoints)-1)
        # Define the current smooth sub-interval
        xa = breakpoints[i]
        xb = breakpoints[i+1]

        # Find all data points within this sub-interval
        # Add a small epsilon to include points exactly at the boundaries
        epsilon = 1e-9
        indices_in_sub = findall(x -> (xa - epsilon) <= x <= (xb + epsilon), x_coords)

        if length(indices_in_sub) < dierckx_k + 1
            # Not enough points for the requested spline order, fallback to linear
            current_k = 1
            if length(indices_in_sub) < 2
                # Not enough points even for linear, use constant from nearest point
                if isempty(indices_in_sub)
                    # If no points in interval, find nearest point overall to create a constant spline
                    _, nearest_idx = findmin(val -> abs(val - (xa+xb)/2), x_coords)
                    push!(splines, Dierckx.Spline1D([xa, xb], [y_values[nearest_idx], y_values[nearest_idx]]; k=1, bc="nearest"))
                else
                    # Only one point, create a constant spline
                    push!(splines, Dierckx.Spline1D([xa, xb], [y_values[indices_in_sub[1]], y_values[indices_in_sub[1]]]; k=1, bc="nearest"))
                end
                continue
            end
        else
            current_k = dierckx_k
        end
        
        # Get the data for this piece
        x_piece = x_coords[indices_in_sub]
        y_piece = y_values[indices_in_sub]

        # To ensure the spline is well-defined at the boundaries of the sub-interval,
        # we can add the boundary points themselves using constant interpolation.
        # This uses the value of the closest data point as the value at the boundary.
        if abs(x_piece[1] - xa) > epsilon
            insert!(x_piece, 1, xa)
            insert!(y_piece, 1, y_piece[1]) # Constant extrapolation
        end
        if abs(x_piece[end] - xb) > epsilon
            push!(x_piece, xb)
            push!(y_piece, y_piece[end]) # Constant extrapolation
        end

        try
            # Create a spline for this smooth piece of the domain
            spl = Dierckx.Spline1D(x_piece, y_piece; k=current_k, s=0., bc="nearest")
            push!(splines, spl)
        catch e
            @warn "Dierckx spline creation failed for sub-interval [$xa, $xb]: $e. Adding a zero-spline."
            # Add a placeholder spline that evaluates to zero
            push!(splines, Dierckx.Spline1D([xa, xb], [0.0, 0.0]; k=1))
        end
    end

    # Return a function that evaluates the correct spline based on x
    return function piecewise_spline(x::Real)
        # Find which sub-interval x falls into
        # `searchsortedlast` finds the index of the last breakpoint <= x
        idx = searchsortedlast(breakpoints, x)
        
        # Handle edges
        if idx == 0; idx = 1; end
        if idx >= length(breakpoints); idx = length(splines); end
        
        return splines[idx](x)
    end
end

"""
    _calculate_stats_at_timestep(u_numerical, u_analytical_ref, x_coords, domain_params; ...)

Internal worker function to compute statistics for a single component at a single time step.
It takes a numerical data vector and a callable function for the analytical/reference solution.
"""
function _calculate_stats_at_timestep(
    u_numerical::AbstractVector{<:Real},
    u_analytical_ref::Function,
    x_coords::AbstractVector{<:Real},
    domain_params::NamedTuple,
    discontinuity_points::Vector{Float64};
    dierckx_k::Int = 3,
    quad_tol::Real = 1e-12,
)::Dict{String, Float64}

    results = Dict{String, Float64}()
    N_particles = length(u_numerical)
    if N_particles == 0; return results; end

    # --- 1. Calculate Pointwise and Analytical Values ---
    u_analytical_at_particles = [u_analytical_ref(x) for x in x_coords]
    errors_at_particles = u_numerical .- u_analytical_at_particles
    
    xmin, xmax = domain_params.xmin, domain_params.xmax
    breakpoints = unique(sort([xmin; discontinuity_points; xmax]))

    # --- 2. Create Splines from Discrete Data ---
    perm = sortperm(x_coords)
    x_sorted = x_coords[perm]
    # Use k=1 (linear) and s=0 (interpolation) as this is most robust for discontinuities
    spl_error = _create_piecewise_spline_function(x_sorted, errors_at_particles[perm], breakpoints, dierckx_k)
    spl_u_num = _create_piecewise_spline_function(x_sorted, u_numerical[perm], breakpoints, dierckx_k)

    # --- 3. Calculate All Requested Statistics ---
    ana_l1_norm, _ = QuadGK.quadgk(x -> abs(u_analytical_ref(x)), breakpoints...; rtol=quad_tol)
    ana_l2_sq_norm, _ = QuadGK.quadgk(x -> u_analytical_ref(x)^2, breakpoints...; rtol=quad_tol)
    ana_l2_norm = sqrt(ana_l2_sq_norm)
    mass_ana, _ = QuadGK.quadgk(u_analytical_ref, breakpoints...; rtol=quad_tol)

    l1_error_val, _ = QuadGK.quadgk(x -> abs(spl_error(x)), breakpoints...; rtol=quad_tol)
    l2_sq_error_val, _ = QuadGK.quadgk(x -> spl_error(x)^2, breakpoints...; rtol=quad_tol)
    results["l1error"] = l1_error_val
    results["l2error"] = sqrt(l2_sq_error_val)
    results["relative_l1error"] = ana_l1_norm > 1e-12 ? results["l1error"] / ana_l1_norm : results["l1error"]
    results["relative_l2error"] = ana_l2_norm > 1e-12 ? results["l2error"] / ana_l2_norm : results["l2error"]

    mass_num, _ = QuadGK.quadgk(spl_u_num, breakpoints...; rtol=quad_tol)
    results["mass"] = mass_num
    results["relative_mass"] = abs(mass_ana) > 1e-12 ? mass_num / abs(mass_ana) : NaN

    
    results["supnorm"] = maximum(abs.(errors_at_particles))
    sup_norm_ana = maximum(abs.(u_analytical_at_particles))
    results["relative_supnorm"] = sup_norm_ana > 1e-12 ? results["supnorm"] / sup_norm_ana : results["supnorm"]

    return results
end

"""
    _calculate_stats_at_timestep_no_ref(...)

Worker for stats that do not require a reference solution.
"""
function _calculate_stats_at_timestep_no_ref(
    u_numerical::AbstractVector{<:Real},
    x_coords::AbstractVector{<:Real},
    domain_params::NamedTuple,
    discontinuity_points::Vector{Float64};
    dierckx_k::Int = 3,
)::Dict{String, Float64}
    
    results = Dict{String, Float64}()
    N_particles = length(u_numerical)
    if N_particles == 0; return results; end

    xmin, xmax = domain_params.xmin, domain_params.xmax
    breakpoints = unique(sort([xmin; discontinuity_points; xmax]))
    perm = sortperm(x_coords)
    spl_u_num = _create_piecewise_spline_function(x_sorted, u_numerical[perm], breakpoints, dierckx_k)

    results["mass"] = Dierckx.integrate(spl_u_num, xmin, xmax)
    
    l1_norm_val, _ = QuadGK.quadgk(x -> abs(spl_u_num(x)), breakpoints...; rtol=quad_tol)
    results["l1norm"] = l1_norm_val
    l2_norm_val, _ = QuadGK.quadgk(x -> abs(spl_u_num(x))^2, breakpoints...; rtol=quad_tol)
    results["l2norm"] = l2_norm_val

    height_num, index_num = findmax(u_numerical)
    pos_num = x_coords[index_num]
    results["wave_height"] = height_num
    results["wave_position"] = pos_num

    return results
end

"""
    _calculate_stats_at_timestep(u_numerical, u_analytical_ref, xy_coords, domain_params; ...)

Internal worker function to compute statistics for a single component at a single 2D time step.
It takes numerical data on scattered points and a callable function for the analytical solution.
"""
function _calculate_stats_at_timestep(
    u_numerical::AbstractVector{<:Real},
    u_analytical_ref::Function, # Expected to be u_analytical(x, y)
    xy_coords::AbstractVector{<:Tuple{<:Real, <:Real}},
    domain_params::NamedTuple, # Should contain xmin, xmax, ymin, ymax
    discontinuity_points; # Unused in 2D for now, kept for API consistency
    dierckx_k::Int = 3,
    quad_tol = nothing
)::Dict{String, Float64}

    results = Dict{String, Float64}()
    N_particles = length(u_numerical)
    if N_particles == 0; return results; end

    # --- 1. Unpack Coordinates and Calculate Pointwise Values ---
    x_coords = [p[1] for p in xy_coords]
    y_coords = [p[2] for p in xy_coords]
    
    u_analytical_at_particles = [u_analytical_ref(p) for p in xy_coords]
    errors_at_particles = u_numerical .- u_analytical_at_particles
    
    xmin, xmax = domain_params.xmin, domain_params.xmax
    ymin, ymax = domain_params.ymin, domain_params.ymax

    # --- 2. Create 2D Splines with Smoothing ---
    # THE FIX: Provide a smoothing factor `s`. A good default is the number of data points.
    s_factor = Float64(N_particles)
    
    # --- 2. Create 2D Splines from Scattered Data ---
    # Dierckx.Spline2D is ideal for scattered data interpolation.
    spl_u_num = Spline2D(x_coords, y_coords, u_numerical; ky=dierckx_k, kx=dierckx_k, s = s_factor)
    
    # To integrate non-positive functions (like error), we create splines of their modified values
    spl_error_abs = Spline2D(x_coords, y_coords, abs.(errors_at_particles); kx=dierckx_k, ky=dierckx_k, s=s_factor)
    spl_error_sq = Spline2D(x_coords, y_coords, errors_at_particles.^2; ky=dierckx_k, kx=dierckx_k, s=s_factor)

    # We do the same for the analytical solution to use the same integration method
    spl_ana_abs = Spline2D(x_coords, y_coords, abs.(u_analytical_at_particles); kx=dierckx_k, ky=dierckx_k, s=s_factor)
    spl_ana_sq = Spline2D(x_coords, y_coords, u_analytical_at_particles.^2; kx=dierckx_k, ky=dierckx_k, s=s_factor)
    spl_ana_mass = Spline2D(x_coords, y_coords, u_analytical_at_particles; kx=dierckx_k, ky=dierckx_k, s=s_factor)

    # --- 3. Calculate All Requested Statistics via 2D Integration ---
    ana_l1_norm = Dierckx.integrate(spl_ana_abs, xmin, xmax, ymin, ymax)
    ana_l2_sq_norm = Dierckx.integrate(spl_ana_sq, xmin, xmax, ymin, ymax)
    ana_l2_norm = sqrt(ana_l2_sq_norm)
    mass_ana = Dierckx.integrate(spl_ana_mass, xmin, xmax, ymin, ymax)

    results["l1error"] = Dierckx.integrate(spl_error_abs, xmin, xmax, ymin, ymax)
    l2_sq_error_val = Dierckx.integrate(spl_error_sq, xmin, xmax, ymin, ymax)
    results["l2error"] = sqrt(l2_sq_error_val)
    
    results["relative_l1error"] = ana_l1_norm > 1e-12 ? results["l1error"] / ana_l1_norm : results["l1error"]
    results["relative_l2error"] = ana_l2_norm > 1e-12 ? results["l2error"] / ana_l2_norm : results["l2error"]

    mass_num = Dierckx.integrate(spl_u_num, xmin, xmax, ymin, ymax)
    results["mass"] = mass_num
    results["relative_mass"] = abs(mass_ana) > 1e-12 ? mass_num / mass_ana : NaN

    results["supnorm"] = maximum(abs.(errors_at_particles))
    sup_norm_ana = maximum(abs.(u_analytical_at_particles))
    results["relative_supnorm"] = sup_norm_ana > 1e-12 ? results["supnorm"] / sup_norm_ana : results["supnorm"]

    return results
end


"""
    _calculate_stats_at_timestep_no_ref(u_numerical, xy_coords, domain_params; ...)

Worker for 2D stats that do not require a reference solution.
"""
function _calculate_stats_at_timestep_no_ref(
    u_numerical::AbstractVector{<:Real},
    xy_coords::AbstractVector{<:Tuple{<:Real, <:Real}},
    domain_params::NamedTuple,
    discontinuity_points; # Unused
    dierckx_k::Int = 3
)::Dict{String, Float64}
    
    results = Dict{String, Float64}()
    N_particles = length(u_numerical)
    if N_particles == 0; return results; end

    # --- 1. Unpack Coordinates and Get Domain ---
    x_coords = [p[1] for p in xy_coords]
    y_coords = [p[2] for p in xy_coords]
    xmin, xmax = domain_params.xmin, domain_params.xmax
    ymin, ymax = domain_params.ymin, domain_params.ymax

    # --- 2. Create 2D Splines with Smoothing ---
    # THE FIX: Provide a smoothing factor `s`. A good default is the number of data points.
    s_factor = Float64(N_particles)

    # --- 2. Create Splines for Integration ---
    spl_u_num = Spline2D(x_coords, y_coords, u_numerical; kx=dierckx_k, ky=dierckx_k, s=s_factor)
    spl_u_num_abs = Spline2D(x_coords, y_coords, abs.(u_numerical); kx=dierckx_k, ky=dierckx_k, s=s_factor)
    spl_u_num_sq = Spline2D(x_coords, y_coords, u_numerical.^2; kx=dierckx_k, ky=dierckx_k, s=s_factor)

    # --- 3. Calculate Integrals and Pointwise Stats ---
    results["mass"] = Dierckx.integrate(spl_u_num, xmin, xmax, ymin, ymax)
    results["l1norm"] = Dierckx.integrate(spl_u_num_abs, xmin, xmax, ymin, ymax)
    l2_sq_norm_val = Dierckx.integrate(spl_u_num_sq, xmin, xmax, ymin, ymax)
    results["l2norm"] = sqrt(l2_sq_norm_val)

    height_num, index_num = findmax(u_numerical)
    pos_num = xy_coords[index_num]
    results["wave_height"] = height_num
    # For 2D, we can't just return a single position number. We store the x and y coordinates.
    results["wave_pos_x"] = pos_num[1]
    results["wave_pos_y"] = pos_num[2]

    return results
end

# ==============================================================================
# --- SECTION 2: MAIN USER-FACING FUNCTIONS ---
# ==============================================================================

"""
    calculateAllStats!(sim_data, ref_func, discontinuity_points_func; ...)

Main user-facing function for problems WITH a reference solution (analytical or numerical).
Handles both scalar and system `sim_data` automatically.
"""
function calculateAllStats!(
    sim_data::AbstractSimData,
    ref_func::Function; # Should be a function ref(x, t)
    discontinuity_points_func::Function = _ -> Float64[], # Should be a function disc_pts(t)
    dierckx_k::Int = 1, 
    quad_tol::Real = 1e-12,
    stats_to_calculate::Union{String,Vector{String}} = "all",
    custom_function::Union{Nothing,Function} = nothing,
    custom_params::Union{Nothing,Function} = nothing
)
    all_possible_stats = [ "l1error", "l2error", "supnorm", "relative_l1error", "relative_l2error", "relative_supnorm", "l1norm", "mass", "relative_mass" ]
    stats_list = stats_to_calculate == "all" ? all_possible_stats : stats_to_calculate

    if isempty(sim_data.u); @warn "SimData has no solution steps to process."; return; end
    if !hasproperty(sim_data, :stats); sim_data.stats = Dict{String, Any}(); end

    num_timesteps = length(sim_data.t)
    # Determine if this is a system by checking the type of the solution data
    is_system = sim_data.u[1] isa AbstractMatrix
    num_components = is_system ? size(sim_data.u[1], 2) : 1

    # Initialize stats storage
    for key in stats_list
        sim_data.stats[key] = is_system ? Matrix{Float64}(undef, num_timesteps, num_components) : Vector{Float64}(undef, num_timesteps)
    end

    domain_params = (xmin=sim_data.params["xmin"], xmax=sim_data.params["xmax"], ymin= get(sim_data.params,"ymin",nothing), ymax = get(sim_data.params,"ymax",nothing))
    @debug "Calculating statistics for $(sim_data.params)..."
    p = Progress(num_timesteps, "Calculating Stats...")
    counter = Threads.Atomic{Int}(0)
    Threads.@threads for m in 1:num_timesteps
        t = sim_data.t[m]
        x_coords = sim_data.x[m]
        discontinuity_points = discontinuity_points_func(t)

        if is_system
            for i_comp in 1:num_components
                analytical_func_component = x -> ref_func(x, t)[i_comp]
                u_numerical_component = @view sim_data.u[m][:, i_comp]
                stats_tmp = _calculate_stats_at_timestep(u_numerical_component, analytical_func_component, x_coords, domain_params, discontinuity_points; dierckx_k=dierckx_k, quad_tol=quad_tol)
                for key in stats_list; sim_data.stats[key][m,i_comp] = get(stats_tmp, key, NaN); end
            end
        else # Scalar case
            analytical_func_scalar = x -> ref_func(x, t)
            stats_tmp = _calculate_stats_at_timestep(sim_data.u[m], analytical_func_scalar, x_coords, domain_params, discontinuity_points; dierckx_k=dierckx_k, quad_tol=quad_tol)
            for key in stats_list; sim_data.stats[key][m] = get(stats_tmp, key, NaN); end
        end
        Threads.atomic_add!(counter, 1)
        ProgressMeter.update!(p, counter[])
    end  
    # Placeholder for derived stats, which would only apply to systems
    if is_system
        @debug "No mixed stats implemented yet!"
        # _calculate_derived_system_stats!(sim_data, ref_func, ... )
    end
    if !isnothing(custom_function)
        try
            isnothing(custom_params) ? custom_function(sim_data, ref_func) : custom_function(sim_data, ref_func, custom_params...)
        catch e
            @warn "Error while running the custom stats-Function! Check the input structure." exception=(e, catch_backtrace())
        end
    end
    saveSimData(sim_data; overwrite = true)
end

"""
    calculateAllStats!(sim_data::AbstractSimData; ...)

Main user-facing function for problems WITHOUT a reference solution.
"""
function calculateAllStats!(
    sim_data::AbstractSimData;
    dierckx_k::Int = 1,
    stats_to_calculate::Union{String,Vector{String}} = "all",
    custom_function::Union{Nothing,Function} = nothing,
    custom_params::Union{Nothing,Function} = nothing,
    discontinuity_points = Float64[]
)
    no_ref_stats = ["mass", "wave_height", "wave_position"]
    stats_list = stats_to_calculate == "all" ? no_ref_stats : intersect(stats_to_calculate, no_ref_stats)
    
    if isempty(sim_data.u); @warn "SimData has no solution steps to process."; return; end
    if !hasproperty(sim_data, :stats); sim_data.stats = Dict{String, Any}(); end
    for key in stats_list; sim_data.stats[key] = []; end

    xmin = get(sim_data.params, "xmin", sim_data.x[1][1])
    xmax = get(sim_data.params, "xmax", sim_data.x[1][end])
    domain_params = (xmin=xmin, xmax=xmax)

    @debug "Calculating statistics (no reference) for $(sim_data.params)"
    for m in 1:length(sim_data.t)
        stats_tmp = _calculate_stats_at_timestep_no_ref(sim_data.u[m], sim_data.x[m], domain_params, discontinuity_points; dierckx_k=dierckx_k)
        for key in stats_list; push!(sim_data.stats[key], get(stats_tmp, key, NaN)); end
    end
    if !isnothing(custom_function)
        try
            isnothing(custom_params) ? custom_function(sim_data) : custom_function(sim_data, custom_params...)
        catch e
            @warn "Error while running the custom stats-Function! Check the input structure." exception=(e, catch_backtrace())
        end
    end
    saveSimData(sim_data; overwrite = true)
end

function createReferenceFunction(ref_sim_data::AbstractSimData; discontinuity_points_func::Function = t -> Float64[])
    is_ref_system = ref_sim_data.u[1] isa AbstractMatrix
    num_ref_components = is_ref_system ? size(ref_sim_data.u[1], 2) : 1
    ref_func_splines = []
    for (m,t) in enumerate(ref_sim_data.t)
        breakpoints = [ref_sim_data.x[m][1]; discontinuity_points_func(t); ref_sim_data.x[m][end]]
        if is_ref_system
            comp_splines = [_create_piecewise_spline_function(ref_sim_data.x[m], ref_sim_data.u[m][:, i], breakpoints, 1) for i in 1:num_ref_components]
            push!(ref_func_splines, comp_splines)
        else
            push!(ref_func_splines, _create_piecewise_spline_function(ref_sim_data.x[m], ref_sim_data.u[m], breakpoints, 1))
        end
    end

    function ref_func(x, t)
        _, t_idx = findmin(abs.(ref_sim_data.t .- t))
        if is_ref_system
            return Tuple([ref_func_splines[t_idx][comp](x) for comp = 1:length(ref_func_splines[t_idx])])
        else
            return ref_func_splines[t_idx](x)
        end
    end
    return ref_func
end

"""
    calculateAllStats!(sim_data, ref_params::ParamDictType; ...)

Convenience function that loads a reference solution from disk.
"""
function calculateAllStats!(sim_data::AbstractSimData, ref_params::ParamDictType; kwargs...)
    @info "Loading reference solution for stats calculation..."
    ref_sim_data = try loadSimData(ref_params) catch e; @warn "Failed to load reference SimData" exception=e; nothing end
    if isnothing(ref_sim_data)
        @warn "Could not load reference SimData for params: $ref_params. Skipping stats calculation."
        return
    end
    calculateAllStats!(sim_data, ref_sim_data; kwargs...)
end

"""
    calculateAllStats!(sim_config::SimulationConfig; ref_func_cont=nothing, kwargs...)

High-level convenience function that takes a SimulationConfig and orchestrates stats calculation.
"""
function calculateAllStats!(sim_config::SimulationConfig; ref_func_cont::Union{Function, Nothing}=nothing, discontinuity_points_func::Union{Function, Nothing} = t -> Float64[], kwargs...)
    all_methods = collect(keys(sim_config.methods_dict))
    ref_method_idx = findfirst(s -> contains(lowercase(s), "reference"), all_methods)
    
    local reference
    if !isnothing(ref_func_cont)
        @info "continuous Analytic/Reference Solution given"
        reference = ref_func_cont
    elseif !isnothing(ref_method_idx)
        ref_method_name = all_methods[ref_method_idx]
        @info "Using numerical reference solution '$ref_method_name'."
        ref_params = assembleParams(sim_config.shared_params, sim_config.methods_dict, ref_method_name)
        reference = createReferenceFunction(loadSimData(ref_params); discontinuity_points_func = discontinuity_points_func)
    else
        reference = nothing
        @warn "Neither an analytic solution nor a numerical reference method found in SimulationConfig. Skipping calculation!"
        @info "Turn off stat calculation if you handle the calculation yourself."
    end

    # Loop through all other methods and calculate their stats against the reference
    for method_label in sim_config.default_methods
        #if method_label == all_methods[ref_method_idx]; continue; end
        
        params = assembleParams(sim_config.shared_params, sim_config.methods_dict, method_label)
        sim_data = loadSimData(params)
        if isnothing(sim_data); @warn "Could not load SimData for '$method_label' to calculate stats."; continue; end
        
        # Call the version that takes the reference parameters
        if !isnothing(reference)
            calculateAllStats!(sim_data, reference; kwargs...)
        end
    end
end

"""
    calculateConvergenceStats!(sim_config, key_varied, param_values; kwargs...)

Convenience function for convergence studies.
"""
function calculateAllStats!(sim_config::SimulationConfig, key_varied::String, param_values; force_int_param = false, kwargs...)
    for p_val in param_values
        @info "Running stats for $key_varied = $p_val"
        temp_shared_params = deepcopy(sim_config.shared_params)
        temp_shared_params[key_varied] = force_int_param ? trunc(Int64, p_val) : p_val
        temp_config = SimulationConfig(sim_config.sim_function, temp_shared_params, sim_config.methods_dict, sim_config.default_methods)
        
        calculateAllStats!(temp_config; kwargs...)
    end
end

"""
    calculateConvergenceData(sim_config::SimulationConfig,
                             key_varied::String,
                             param_values_for_key::Union{AbstractVector, AbstractRange};
                             force_int_param::Bool = false)

Runs simulations for each method in `sim_config` across each value in
`param_values_for_key` (for the `key_varied`) IN PARALLEL.
Returns a dictionary of results.
"""
function calculateConvergenceData(
    sim_config::SimulationConfig,
    key_varied::String,
    param_values_for_key::Union{AbstractVector, AbstractRange};
    force_int_param::Bool = false,
    calculate_all::Bool = false,
    force_overwrite::Bool = false,
    calc_stats = true
)
    # --- Task Preparation (as before) ---
    all_method_labels = calculate_all ? collect(keys(sim_config.methods_dict)) : sim_config.default_methods
    num_tasks = length(all_method_labels) * length(param_values_for_key)
    if num_tasks == 0; @info "No simulations to run."; return; end

    tasks_params_list = Vector{ParamDictType}(undef, num_tasks)
    task_identifiers = Vector{Tuple{String, Int}}(undef, num_tasks)
    
    task_idx = 0
    for method_label in all_method_labels
        current_method_base_params = assembleParams(sim_config.shared_params, sim_config.methods_dict, method_label)
        for (j, p_val) in enumerate(param_values_for_key)
            task_idx += 1
            params_for_this_run = copy(current_method_base_params)
            params_for_this_run[key_varied] = force_int_param ? trunc(Int64, p_val) : p_val
            tasks_params_list[task_idx] = params_for_this_run
            task_identifiers[task_idx] = (method_label, j)
        end
    end

    @info "Starting parallel calculation of $(num_tasks) convergence simulations..."

    # --- NEW: Progress Bar Setup ---
    # 1. Create a Progress meter object.
    p = Progress(num_tasks, "Calculating..."; 
        barglyphs=BarGlyphs('|','█', ['▁' ,'▂' ,'▃' ,'▄' ,'▅' ,'▆', '▇'],' ','|',),
        showspeed=true)
    # 2. Create a thread-safe counter.
    counter = Threads.Atomic{Int}(0)
    # -----------------------------

    loop_indices = randperm(num_tasks)
    # --- Parallel Execution ---
    Threads.@threads for i in loop_indices
        try
            params_for_this_run = tasks_params_list[i]
            method_label_this_run, p_val_idx = task_identifiers[i]
            p_val_actual = param_values_for_key[p_val_idx]

            # Optional: You may want to remove or comment out the println statements
            # below, as they can interfere with the visual appearance of the progress bar.
            # @info "Thread $(Threads.threadid()): Starting Sim - Label: '$method_label_this_run', $key_varied = $p_val_actual")

            if !doesSimDataExist(params_for_this_run) || force_overwrite
                sim_data = Base.invokelatest(sim_config.sim_function, params_for_this_run)
                if !isnothing(sim_data)
                    saveSimData(sim_data; overwrite = force_overwrite)
                else
                    @warn "Simulation returned `nothing` for $method_label_this_run, $key_varied = $p_val_actual"
                end
            else
                # @info "Skipped calculation because existing data was found."
            end
        catch e
            @error "Error in thread $(Threads.threadid())" exception=(e, catch_backtrace())
        end

        # --- NEW: Update Progress ---
        # 3. Atomically increment the counter and update the progress bar.
        Threads.atomic_add!(counter, 1)
        ProgressMeter.update!(p, counter[])
        # ----------------------------
    end
    @info "\nConvergence data calculation complete."
    @info "\nStat calculation started."
    if calc_stats
        calculateAllStats!(sim_config,key_varied, param_values_for_key, force_int_param = force_int_param)
    end
    @info "\nStat calculation complete."
end

end