# --- Central Plugin Registry ---
const STAT_REGISTRY = Dict{Symbol, Symbol}(
    :mass          => :series,
    :l1norm        => :series,
    :l2norm        => :series,
    :wave_height   => :series,
    :l1error       => :series,
    :l2error       => :series,
    :relative_mass => :series
)

"""
    register_stat!(name::Symbol, category::Symbol)

Allows external plugins to register a new statistic and define its category 
(:series, :profile, or :field) so the pipeline automatically calculates it.
"""
function register_stat!(name::Symbol, category::Symbol)
    if !(category in (:series, :profile, :field))
        @warn "Unknown category '$category'. Valid options are :series, :profile, :field."
    end
    STAT_REGISTRY[name] = category
    @info "Registered new $category statistic: :$name"
end
function delete_stat!(name::Symbol)
    try
        delete!(STAT_REGISTRY,name)
    catch e
        @warn "Could not find key to delete!"
    end
end

# ==============================================================================
# --- DISPATCH ROUTERS & FALLBACKS ---
# ==============================================================================

# 1. Ultimate Fallback (Safely returns an SVector of NaNs matching the component count!)
calc_stat(stat::Val, D::Val, t::Float64, xs, u, args...) = zero(eltype(u)) .* NaN 

# 2. The Router (7 Arguments!)
# If the analytical slice is missing (::Nothing), drop it and call the 6-argument version
calc_stat(stat::Val, D::Val, t::Float64, xs, u, dV, ::Nothing) = calc_stat(stat, D, t, xs, u, dV)


# ==============================================================================
# --- NO-REFERENCE METRICS (6 Arguments) ---
# ==============================================================================

calc_stat(::Val{:mass}, ::Val, t::Float64, xs, u, dV) = sum(u .* dV)

calc_stat(::Val{:l1norm}, ::Val, t::Float64, xs, u, dV) = sum(map(v -> abs.(v), u) .* dV)

calc_stat(::Val{:l2norm}, ::Val, t::Float64, xs, u, dV) = sqrt.(sum(map(v -> abs2.(v), u) .* dV))

calc_stat(::Val{:wave_height}, ::Val, t::Float64, xs, u, dV) = reduce((a, b) -> max.(a, b), u)

function calc_stat(::Val{:wave_position}, ::Val{1}, t::Float64, xs, u, dV)
    M = length(eltype(u))
    return SVector{M, Float64}(ntuple(M) do c
        max_idx = argmax(map(v -> v[c], u))
        xs[max_idx][1] 
    end)
end


# ==============================================================================
# --- ERROR METRICS (7 Arguments - Strictly requires reference) ---
# ==============================================================================

# map((v, a)) evaluates the error element-by-element with ZERO temporary array allocations!
calc_stat(::Val{:l1error}, ::Val, t::Float64, xs, u, dV, ana) = sum(map((v, a) -> abs.(v - a), u, ana) .* dV)

calc_stat(::Val{:l2error}, ::Val, t::Float64, xs, u, dV, ana) = sqrt.(sum(map((v, a) -> abs2.(v - a), u, ana) .* dV))

function calc_stat(::Val{:relative_mass}, ::Val, t::Float64, xs, u, dV, ana)
    sum_u = sum(u .* dV)
    sum_ana = sum(ana .* dV)
    
    m_ana = abs.(sum_ana) 

    M = length(eltype(u))
    return SVector{M, Float64}(ntuple(M) do c
        m_ana[c] < 1e-9 ? NaN : sum_u[c] / sum_ana[c]
    end)
end