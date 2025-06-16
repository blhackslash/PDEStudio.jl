module MakiePlotting

using ..Structs
using ..Utils
using GLMakie
using CSV, DataFrames
using Dates # For timestamp in optional info


export show1DSolutionFig, show2DSolutionFig, showDynamicDependence, showConvergencePlot

include("UIStyles.jl")
include("PlottingUtils.jl")
include("show1DSolutionFig.jl")
include("show2DSolutionFig.jl")
include("showDynamicDependence.jl")
include("showConvergencePlot.jl")

end