using IPlotPDESols.Structs
using IPlotPDESols.Utils

method1 = MethodDict("method1" => ParamDict("a"=>1.))
method12 = MethodDict("method1" => ParamDict("a"=>1.), "method2" => ParamDict("b" => 1))
shared_Dict = ParamDict("c"=>1.)
simulation_fun(x) = x 

test = mergeMethodDicts(shared_Dict, method12)
test1 = SimulationConfig(simulation_fun, method1, "method1")

test2 = SimulationConfig(simulation_fun, shared_Dict, method12, "method1")

typeof(method12)


# SimDAta tests

x = collect(1.:10.)
A = x .* x'
x = [A[i,:] for i in eachindex(A[1,:])]
u = [A[i,:] for i in eachindex(A[1,:])]
t = collect(1.:10.)
param = ParamDict("test" => "done")
stat = ParamDict("norm" => 12)

test = SimData1D(x,u,t,param)

saveSimData(test)

getFileName(param)
test2 = loadSimData(param)
getStats(param)
doesSimDataExist(param)
deleteSimData(Vector{String}(["test"]), Vector(["done"]))