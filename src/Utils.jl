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
Calculates the hash of a given params dictionary
"""
function calculateHash(params::ParamDictType)
    sorted_keys = sort(collect(keys(params)))
    sorted_vals = [params[key] for key = sorted_keys]
    stringToHash = join(map(d -> "$d", sorted_vals))
    return bytes2hex(sha256(stringToHash))
end

"""
Saves the given simulation mesh in the folder given by saveData with the hash as the filename.

CAUTION: Enabling overwrite will overwrite an existing file with the given simulation mesh!
"""
function saveSimData(SimData::AbstractSimData; overwrite::Bool = false)
    hash = calculateHash(SimData.params)
    fileName = saveData * hash *".jld2"
    counter = 0
    while true
        counter += 1
        if !isfile(fileName)
            save(fileName, "SimData", SimData)
            break
        else
            SimDataSaved = load(fileName)["SimData"]
            if !(SimData.params == SimDataSaved.params)
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
Returns the filename of the simulation data corresponding to the given params dictionary
"""
function getFileName(params::ParamDictType)
    hash = calculateHash(params)
    fileName = hash
    file = saveData * fileName *".jld2"
    counter = 0
    while true
        counter += 1
        if isfile(file)
            SimDataSaved = load(file)["SimData"]
            if (params == SimDataSaved.params)
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
Loads the simulation data corresponding to the given params dictionary as a simulation mesh
"""
function loadSimData(params::ParamDictType)
    fileName = saveData * getFileName(params) * ".jld2"
    return load(fileName)["SimData"]
end
function loadSimData(hash::String)
    fileName = saveData * hash *".jld2"
    return load(fileName)["SimData"]
end

"""
Loads only the stats field of the simulation mesh
"""
function getStats(params::ParamDictType)
    SimData = loadSimData(params)
    return SimData.stats
end

"""
Checks if simulation data already exists for the given paramseter dictionary
"""
function doesSimDataExist(params::ParamDictType)
    try getFileName(params)
        return true
    catch e
        return false
    end
end

"""
Deletes all saved simulation meshes with the given keys and values in its paramseter dictionary.
"""
function deleteSimData(keys::Vector{String}, vals::Vector)
    files = readdir(saveData)
    for file = files
        SimData = load(saveData * file)["SimData"]
        deletion = true
        for (i,key) = enumerate(keys)
            deletion = deletion && (SimData.params[key] == vals[i]) && (SimData.params[key] isa typeof(vals[i]))
        end
        if deletion
            println("Saved data is being deleted!")
            rm(saveData * file)
        end
    end
end

"""
Changes the paramseter dictionary of a simulation mesh from the old values to the new ones. Helpful if unused paramseters need to be changed or the type 
is wrong (e.g. Int instead of Float). Note that the values are not changed, hence use with caution.

"""
function changeparams(ks::Vector{String}, oldVals::Vector, newVals::Vector)
    files = readdir(saveData)
    for file = files
        SimData = load(saveData * file)["SimData"]
        for (i,key) = enumerate(ks)
            if (key in keys(SimData.params))
                if SimData.params[key] == oldVals[i]
                    SimData.params[key] = newVals[i]
                    saveSimData(SimData; overwrite = true)
                    println("Changed simulation mesh is saved!")
                end
            end
        end
    end
end

"""
Returns all saved simulation meshes with the given paramseters.
"""
function getAllSavedMeshes(ks::Vector{String}, vals::Vector)
    res = []
    files = readdir(saveData)
    for file = files
        SimData = load(saveData * file)["SimData"]
        hit = true
        for (i,key) = enumerate(ks)
            if (key in keys(SimData.params))
                hit = hit & (SimData.params[key] == vals[i])
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
        if SimData.params["simulation"] == simulation
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