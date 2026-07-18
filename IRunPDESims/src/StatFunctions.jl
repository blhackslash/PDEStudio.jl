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
    :relative_mass => :time,
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
    get_kept_dims(stat::Symbol, dim_keys::Tuple)

Translates generic aliases (:all, :space, :time) into exact dimension symbols 
for the current simulation tensor.
"""
function get_kept_dims(stat::Symbol, dim_keys::Tuple)
    reg_val = get(STAT_REGISTRY, stat, Symbol[])
    
    if reg_val === :all
        return collect(dim_keys)
    elseif reg_val === :space
        return filter(d -> d !== :t, collect(dim_keys))
    elseif reg_val === :time
        return filter(d -> d === :t, collect(dim_keys))
    elseif reg_val isa Vector{Symbol}
        return reg_val
    else
        return Symbol[]
    end
end

function get_kept_indices(stat::Symbol, dim_keys::Tuple)
    # Use the translator!
    kept_dims = get_kept_dims(stat, dim_keys)
    
    indices = Int[]
    for dim in kept_dims
        idx = findfirst(==(dim), dim_keys)
        if !isnothing(idx)
            push!(indices, idx)
        end
    end
    
    return sort(indices)
end

function get_integration_measure(stat::Symbol, domain::DomainInfo{D}) where {D}
    # Use the translator!
    kept_dims = get_kept_dims(stat, domain.dim_keys)
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
    # Find the primary dimension that was integrated out to serve as the physical "axis"
    kept_dims = get_kept_dims(:wave_position, domain.dim_keys)
    int_idx = findfirst(k -> k ∉ kept_dims, domain.dim_keys)
    
    # Fallback to index 1 if no integrated dimension is found
    int_idx = isnothing(int_idx) ? 1 : int_idx 

    M = length(eltype(u))
    return SVector{M, Float64}(ntuple(M) do c
        max_idx = argmax(map(v -> v[c], u))
        
        # Handle both 1D vectors and N-dimensional Cartesian slices safely
        local_idx = max_idx isa CartesianIndex ? max_idx[1] : max_idx
        
        # Calculate physical position: min + (idx - 1) * spacing
        domain.mins[int_idx] + (local_idx - 1) * domain.spacing[int_idx]
    end)
end


# ==============================================================================
# --- ERROR METRICS (Naturally propagates NaNs if analytical data is missing) ---
# ==============================================================================

function calc_stat(::Val{:l1error}, fixed_coords, u, ana, domain::DomainInfo)
    measure = get_integration_measure(:l1error, domain)
    return sum(map((v, a) -> abs.(v - a), u, ana) .* measure)
end

function calc_stat(::Val{:l2error}, fixed_coords, u, ana, domain::DomainInfo)
    measure = get_integration_measure(:l2error, domain)
    return sqrt.(sum(map((v, a) -> abs2.(v - a), u, ana) .* measure))
end

function calc_stat(::Val{:relative_mass}, fixed_coords, u, ana, domain::DomainInfo)
    measure = get_integration_measure(:relative_mass, domain)
    
    sum_u = sum(u .* measure)
    sum_ana = sum(ana .* measure)
    m_ana = abs.(sum_ana) 

    M = length(eltype(u))
    return SVector{M, Float64}(ntuple(M) do c
        m_ana[c] < 1e-9 ? NaN : sum_u[c] / sum_ana[c]
    end)
end

# Keep all dimensions (e.g., for a 1D Space + 1D Time simulation)
register_stat!(:u_squared, :all) 

function calc_stat(::Val{:u_squared}, fixed_coords, u, ana, domain::DomainInfo)
    # Since this is a field, 'u' is effectively an array of 1 element.
    # The measure evaluates to 1.0 automatically!
    # map(v -> v.^2, u) squares the SVector components, and sum() extracts it safely.
    measure = get_integration_measure(:u_squared, domain)
    return sum(map(v -> v.^2, u) .* measure)
end

# (If testing a 2D transient simulation, use [:x, :y, :t])