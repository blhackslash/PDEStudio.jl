module IPlotPDESols

export show1DSolutionFig, show2DSolutionFig, showDynamicDependence, showConvergencePlot, saveSimData,
       calculateHash, getFileName, loadSimData, getStats, doesSimDataExist, deleteSimData, 
       getAllSimData, changeStats, set_save_path!, get_save_path,
       ParamDict, MethodDict, SimulationConfig, SimData1D, SimData2D, createSimData,
       AbstractSimData, ParamDictType, MethodDictType

include("Structs.jl")
using .Structs

include("Utils.jl")
using .Utils

include("MakiePlotting.jl")
using .MakiePlotting

end