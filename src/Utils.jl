module Utils

using ..Structs  

using SHA
using CSV, DataFrames
using JLD2, FileIO

export saveSimData,calculateHash, getFileName, loadSimData, getStats, doesSimDataExist, deleteSimData, 
       getAllSavedMeshes, changeStats


# Save Directories
saveData = dirname(@__DIR__) * "/data/"
saveFigs = dirname(@__DIR__) * "/figures/"

"""
Calculates the hash of a given param dictionary
"""
function calculateHash(param::ParamDictType)
    sorted_keys = sort(collect(keys(param)))
    sorted_vals = [param[key] for key = sorted_keys]
    stringToHash = join(map(d -> "$d", sorted_vals))
    return bytes2hex(sha256(stringToHash))
end

"""
Saves the given simulation mesh in the folder given by saveData with the hash as the filename.

CAUTION: Enabling overwrite will overwrite an existing file with the given simulation mesh!
"""
function saveSimData(SimData::AbstractSimData; overwrite::Bool = false)
    hash = calculateHash(SimData.param)
    fileName = saveData * hash *".jld2"
    counter = 0
    while true
        counter += 1
        if !isfile(fileName)
            save(fileName, "SimData", SimData)
            break
        else
            SimDataSaved = load(fileName)["SimData"]
            if !(SimData.param == SimDataSaved.param)
                print("Filename already exists! Changing hash...")
                fileName = saveData * hash * "_$counter.jld2"
            else
                if overwrite
                    println("Simulation mesh has been overwritten!")
                    save(fileName, "SimData", SimData)
                else
                    println("File already exists!")
                end
                break
            end 
        end
    end
end

"""
Returns the filename of the simulation data corresponding to the given param dictionary
"""
function getFileName(param::ParamDictType)
    hash = calculateHash(param)
    fileName = hash
    file = saveData * fileName *".jld2"
    counter = 0
    while true
        counter += 1
        if isfile(file)
            SimDataSaved = load(file)["SimData"]
            if (param == SimDataSaved.param)
                return fileName
            else
                fileName = hash * "_$counter"
                file = saveData * fileName * ".jld2"
            end
        else
            error("Requested File does not exist! Make sure you ran the simulation!")
        end
    end
end

"""
Loads the simulation data corresponding to the given param dictionary as a simulation mesh
"""
function loadSimData(param::ParamDictType)
    fileName = saveData * getFileName(param) * ".jld2"
    return load(fileName)["SimData"]
end
function loadSimData(hash::String)
    fileName = saveData * hash *".jld2"
    return load(fileName)["SimData"]
end

"""
Loads only the stats field of the simulation mesh
"""
function getStats(param::ParamDictType)
    SimData = loadSimData(param)
    return SimData.stats
end

"""
Checks if simulation data already exists for the given parameter dictionary
"""
function doesSimDataExist(param::ParamDictType)
    try getFileName(param)
        return true
    catch e
        return false
    end
end

"""
Deletes all saved simulation meshes with the given keys and values in its parameter dictionary.
"""
function deleteSimData(keys::Vector{String}, vals::Vector)
    files = readdir(saveData)
    for file = files
        SimData = load(saveData * file)["SimData"]
        deletion = true
        for (i,key) = enumerate(keys)
            deletion = deletion && (SimData.param[key] == vals[i]) && (SimData.param[key] isa typeof(vals[i]))
        end
        if deletion
            println("Saved data is being deleted!")
            rm(saveData * file)
        end
    end
end

"""
Changes the parameter dictionary of a simulation mesh from the old values to the new ones. Helpful if unused parameters need to be changed or the type 
is wrong (e.g. Int instead of Float). Note that the values are not changed, hence use with caution.

"""
function changeparam(ks::Vector{String}, oldVals::Vector, newVals::Vector)
    files = readdir(saveData)
    for file = files
        SimData = load(saveData * file)["SimData"]
        for (i,key) = enumerate(ks)
            if (key in keys(SimData.param))
                if SimData.param[key] == oldVals[i]
                    SimData.param[key] = newVals[i]
                    saveSimData(SimData; overwrite = true)
                    println("Changed simulation mesh is saved!")
                end
            end
        end
    end
end

"""
Returns all saved simulation meshes with the given parameters.
"""
function getAllSavedMeshes(ks::Vector{String}, vals::Vector)
    res = []
    files = readdir(saveData)
    for file = files
        SimData = load(saveData * file)["SimData"]
        hit = true
        for (i,key) = enumerate(ks)
            if (key in keys(SimData.param))
                hit = hit & (SimData.param[key] == vals[i])
            else
                hit = false
            end
        end
        if hit
            push!(res, SimData)
        end
    end
    return res
end

"""
Changes the given stat of all simulation meshes using the given function f. The function has to be of the
form f(u,x) or f(u,x,t) for the static and dynamic case respectively. It can also be used to add a new stat
to the simulation meshes.
"""
function changeStats(statsName::String, f::Function, simulation::String)
    files = readdir(saveData)
    for file = files
        SimData = load(saveData * file)["SimData"]
        if SimData.param["simulation"] == simulation
            if simulation == "PDE"
                SimData.stats[statsName] = f(SimData.u, SimData.x, SimData.t)
            else
                SimData.stats[statsName] = f(SimData.u, SimData.x)
            end
            saveSimData(SimData; overwrite = true)
        end
    end    
end

end