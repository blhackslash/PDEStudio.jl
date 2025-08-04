module MakiePlotting

using ..Structs
using ..Utils
using ..StatCalculation
using GLMakie
using CSV, DataFrames
using Dates # For timestamp in optional info
using ProgressMeter


export show1DSolutionFig, show2DSolutionFig, showDynamicDependence, showConvergencePlot, GetUIStyle

include("UIStyles.jl")
include("PlottingUtils.jl")
include("show1DSolutionFig.jl")
include("show2DSolutionFig.jl")
include("showDynamicDependence.jl")
include("showConvergencePlot.jl")

end