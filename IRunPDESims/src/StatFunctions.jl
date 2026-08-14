# ==============================================================================
# --- Central Plugin Registry (Dimension-Based) ---
# ==============================================================================

const STAT_REGISTRY = Dict{Symbol, Union{Symbol, Vector{Symbol}}}(
    :mass          => :time,
    :l1norm        => :time,
    :l2norm        => :time,
    :wave_height   => :time,
    :l1error       => :time,
    :l2error       => :time,
    :relative_l2error => :time,
    :relative_l1error => :time,
    :relative_mass => :time,
    :spacetime_relative_mass => Symbol[],
    :mass_error    => :time,
    :mass_signed_error => :time,
    :wave_position => :time,
    # Examples of your new D-agnostic aliases:
    # :u_squared   => :all,      (Field: keeps everything)
    # :mass_profile => :space,   (Profile: keeps space, integrates time)
)

function register_stat!(name::Symbol, kept_dims::Union{Symbol, Vector{Symbol}})
    STAT_REGISTRY[name] = kept_dims
    @info "Registered statistic :$name keeping dimensions: $kept_dims"
end

# --- THE NEW TRANSLATOR HELPER ---
"""
    get_kept_dims(stat::Symbol, domain::DomainInfo)

Translates generic aliases (:all, :space, :time) into exact dimension symbols 
using the domain's local registry and specific time_dim.
"""
function get_kept_dims(stat::Symbol, domain::DomainInfo)
    reg_val = get(domain.stat_registry, stat, Symbol[])
    
    if reg_val === :all
        return collect(domain.dim_keys)
    elseif reg_val === :space
        return filter(d -> d !== domain.time_dim, collect(domain.dim_keys))
    elseif reg_val === :time
        return isnothing(domain.time_dim) ? Symbol[] : [domain.time_dim]
    elseif reg_val isa Vector{Symbol}
        return reg_val
    else
        return Symbol[]
    end
end

function get_kept_indices(stat::Symbol, domain::DomainInfo)
    kept_dims = get_kept_dims(stat, domain)
    
    indices = Int[]
    for dim in kept_dims
        idx = findfirst(==(dim), domain.dim_keys)
        if !isnothing(idx)
            push!(indices, idx)
        end
    end
    
    return sort(indices)
end

function get_integration_measure(stat::Symbol, domain::DomainInfo{D}) where {D}
    kept_dims = get_kept_dims(stat, domain)
    measure = 1.0
    for d in 1:D
        if !(domain.dim_keys[d] in kept_dims)
            measure *= domain.spacing[d]
        end
    end
    return measure
end

function delete_stat!(name::Symbol)
    try
        delete!(STAT_REGISTRY, name)
        @info "Deleted statistic :$name"
    catch
        @warn "Could not find statistic :$name to delete!"
    end
end

"""
    add_stat!(sim_data::AbstractSimData, name::Union{String, Symbol}, value, kept_dims::Union{Symbol, Vector{Symbol}})

Appends a fully custom statistic to a simulation dataset. 
Registers the dimensions it keeps so the Plotter UI knows exactly how to slice and display it.
"""
function add_stat!(sim_data::AbstractSimData{D, DS, M, T}, name::Symbol, value, kept_dims::Union{Symbol, Vector{Symbol}}) where {D, DS, M, T}
    value_vec = value isa Real ? SVector{M, T}([T(value) for _ in 1:M]) : value
    sim_data.stats[name] = value_vec
    sim_data.domain.stat_registry[name] = kept_dims
    @info "Added custom stat '$name' keeping dimensions: $kept_dims"
end

# ==============================================================================
# --- DISPATCH ROUTERS & FALLBACKS ---
# ==============================================================================

# Ultimate Fallback (Safely returns an SVector of NaNs matching the component count)
calc_stat(stat, fixed_coords, u, ana, domain) = zero(eltype(u)) .* NaN 


# ==============================================================================
# --- STANDARD METRICS ---
# ==============================================================================

function calc_stat(::Val{:mass}, fixed_coords, u, ana, domain::DomainInfo)
    measure = get_integration_measure(:mass, domain)
    return sum(u .* measure)
end

function calc_stat(::Val{:l1norm}, fixed_coords, u, ana, domain::DomainInfo)
    measure = get_integration_measure(:l1norm, domain)
    return sum(map(v -> abs.(v), u) .* measure)
end

function calc_stat(::Val{:l2norm}, fixed_coords, u, ana, domain::DomainInfo)
    measure = get_integration_measure(:l2norm, domain)
    return sqrt.(sum(map(v -> abs2.(v), u) .* measure))
end

function calc_stat(::Val{:wave_height}, fixed_coords, u, ana, domain::DomainInfo)
    return reduce((a, b) -> max.(a, b), u)
end

function calc_stat(::Val{:wave_position}, fixed_coords, u, ana, domain::DomainInfo)
    kept_dims = get_kept_dims(:wave_position, domain)
    int_idx = findfirst(k -> k ∉ kept_dims, domain.dim_keys)
    int_idx = isnothing(int_idx) ? 1 : int_idx 

    M = length(eltype(u))
    T = eltype(eltype(u)) # Dynamically get T
    return SVector{M, T}(ntuple(M) do c
        max_idx = argmax(map(v -> v[c], u))
        local_idx = max_idx isa CartesianIndex ? max_idx[1] : max_idx
        T(domain.mins[int_idx] + (local_idx - 1) * domain.spacing[int_idx])
    end)
end


# ==============================================================================
# --- ERROR METRICS (Naturally propagates NaNs if analytical data is missing) ---
# ==============================================================================
function calc_stat(::Val{:l1error}, fixed_coords, u, ana, domain::DomainInfo)
    measure = get_integration_measure(:l1error, domain)
    return sum(map((v, a) -> abs.(v - a), u, ana) .* measure)
end

function calc_stat(::Val{:relative_l1error}, fixed_coords, u, ana, domain::DomainInfo)
    measure = get_integration_measure(:relative_l1error, domain)
    error_norm = sum(map((v, a) -> abs.(v - a), u, ana) .* measure)
    ana_norm = sum(map(a -> abs.(a), ana) .* measure)
    return error_norm ./ ana_norm
end

function calc_stat(::Val{:l2error}, fixed_coords, u, ana, domain::DomainInfo)
    measure = get_integration_measure(:l2error, domain)
    return sqrt.(sum(map((v, a) -> abs2.(v - a), u, ana) .* measure))
end

function calc_stat(::Val{:relative_l2error}, fixed_coords, u, ana, domain::DomainInfo)
    measure = get_integration_measure(:relative_l2error, domain)
    error_norm = sqrt.(sum(map((v, a) -> abs2.(v - a), u, ana) .* measure))
    ana_norm = sqrt.(sum(map(a -> abs2.(a), ana) .* measure))
    return error_norm ./ ana_norm
end

function calc_stat(::Val{:relative_mass}, fixed_coords, u, ana, domain::DomainInfo)
    measure = get_integration_measure(:relative_mass, domain)
    sum_u = sum(u .* measure)
    sum_ana = sum(ana .* measure)
    m_ana = abs.(sum_ana) 

    M = length(eltype(u))
    T = eltype(eltype(u)) # Dynamically get T
    return SVector{M, T}(ntuple(M) do c
        m_ana[c] < 1e-9 ? T(NaN) : T(sum_u[c] / sum_ana[c])
    end)
end

function calc_stat(::Val{:mass_error}, fixed_coords, u, ana, domain::DomainInfo)
    measure = get_integration_measure(:mass_error, domain)
    sum_u = sum(u .* measure)
    sum_ana = sum(ana .* measure)
    m_err = abs.(sum_u - sum_ana)
    M = length(eltype(u))
    T = eltype(eltype(u)) # Dynamically get T
    return SVector{M, T}(ntuple(M) do c
        m_err[c] < 1e-9 ? T(1e-9) : T(m_err[c])
    end)
end
function calc_stat(::Val{:mass_signed_error}, fixed_coords, u, ana, domain::DomainInfo)
    measure = get_integration_measure(:mass_signed_error, domain)
    sum_u = sum(u .* measure)
    sum_ana = sum(ana .* measure)
    return sum_u - sum_ana
end

# 2. Add the calc_stat overload
function calc_stat(::Val{:spacetime_relative_mass}, fixed_coords, u, ana, domain::DomainInfo)
    # Gets the combined integration measure for dx * dy * dz * dt
    measure = get_integration_measure(:spacetime_relative_mass, domain)
    
    sum_u = sum(u .* measure)
    sum_ana = sum(ana .* measure)
    m_ana = abs.(sum_ana) 

    M = length(eltype(u))
    T = eltype(eltype(u)) 
    
    return SVector{M, T}(ntuple(M) do c
        m_ana[c] < 1e-9 ? T(NaN) : T(sum_u[c] / sum_ana[c])
    end)
end