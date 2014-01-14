Script.Load("lua/compress/deflatelua.lua")
Script.Load("lua/untar.lua")
Script.Load("lua/md5.lua")

local kMaxModDownloadUrlLength = 256
local kMaxModDirNameLength = 128
local kMaxModHashLength = 128
local kMaxModNameLength = 128

local kSetEnabledCustomModsMessage = {
    downloadUrl = string.format("string (%d)", kMaxModDownloadUrlLength),
    totalMods = "integer",
}

Shared.RegisterNetworkMessage("SetEnabledCustomMods", kSetEnabledCustomModsMessage)

local kSetModInfoMessage = {
    dirName = string.format("string (%d)", kMaxModDirNameLength),
    hash = string.format("string (%d)", kMaxModHashLength),
    name = string.format("string (%d)", kMaxModNameLength),
}

Shared.RegisterNetworkMessage("SetModInfo", kSetModInfoMessage)

------------------------------------------------------
-- Functions that need to be implemented by the engine
------------------------------------------------------
function Shared.MountModDir(dirName)
    -- Mount a mod directory from config://mods/
end

function Client.PauseLoading()
    -- Tell the engine to not let loading finish
end

function Client.FinishedLoading()
    -- Tell the engine that Lua is done loading mods
end
------------------------------------------------------

function Shared.GetDirHash(path)
    local matchingPaths = { }    
    Shared.GetMatchingFileNames(path, true, matchingPaths)

    local fileHashes = { }

    for _, subPath in ipairs(matchingPaths) do
        local file = io.open(path .. "/" .. subPath, 'wb')
        table.insert(fileHashes, md5.Calc(file:read()))
        io.close(file)
    end

    table.sort(fileHashes)

    local concatinatedHashes = ""
    for _, fileHash in ipairs(fileHashes) do
        concatinatedHashes = concatinatedHashes .. fileHash
    end

    return md5.Calc(concatinatedHashes)
end

local enabled = false

local downloadUrl

local totalMods = 0
local waitingForMods = 0
local queuedMods = 0
local downloadingMods = 0

local modInfo = { }

ModManager = { }

function ModManager.LoadMod(dirName)
    local matchingPaths = { }
    
    Shared.GetMatchingFileNames("config://mods/" .. dirName, false, matchingPaths)

    if #matchingPaths then
        if Shared.GetDirHash("config://mods/" .. dirName) == modInfo[dirName].hash then                
            Shared.Message("[ModManager] Mounting mod directory: " .. dirName)
            
            Shared.MountModDir(dirName)

            queuedMods = queuedMods - 1

            if waitingForMods + queuedMods == 0 then
                Shared.Message("[ModManager] All mods have been loaded successfully")
                ModManager.OnLoadingComplete()
            end
        else
            Shared.Message("[ModManager] Invalid mod directory: " .. dirName)
            ModManager.DownloadMod(dirName)
        end
    else
        ModManager.DownloadMod(dirName)
    end
end

function ModManager.DownloadMod(dirName)
    downloadingMods = downloadingMods + 1

    local modDownloadUrl = string.format("%s/%s.tar.gz", ModManager.downloadUrl, dirName)

    Shared.Message("[ModManager] Downloading mod: " .. modDownloadUrl)

    Shared.SendHTTPRequest(modDownloadUrl, "GET", function(archiveContents)

        downloadingMods = downloadingMods - 1
        
        local tarFilePath = string.format("config://mods/%s.tar", dirName)
        local tarFile = io.open(tarFilePath, "wb")

        Shared.Message("[ModManager] Decompressing mod: " .. dirName)

        local startedAt = Shared.GetTime()

        deflatelua.gunzip { input = archiveContents, output = tarFile, disable_crc = true }

        io.close(tarFile)

        Shared.Message(string.format("[ModManager] Mod decompression complete: %s (took: %.2f seconds)", dirName, Shared.GetTime() - startedAt))

        Shared.Message("[ModManager] Extracting mod: " .. dirName)

        startedAt = Shared.GetTime()

        if Shared.Untar(tarFilePath, "config://mods/" .. dirName) then
            Shared.Message(string.format("[ModManager] Mod extraction complete: %s (took: %.2f seconds)", dirName, Shared.GetTime() - startedAt))
        else
            Shared.Message("[ModManager] Mod extraction failed: " .. dirName)
        end

        ModManager.LoadMod(dirName)

    end)
end

if Server then

    local mapCycle = MapCycle_GetMapCycle()

    downloadUrl = mapCycle.mod_download_url

    if downloadUrl then
        Shared.Message("[ModManager] Custom mod download url: " .. downloadUrl)

        enabled = true
    end

    local function OnMapPreLoad()
        if not enabled then return end

        local mapName = Shared.GetCurrentMap()
        local mods = { }

        if type(mapCycle.mods) == "table" then
            table.copy(mapCycle.mods, mods, true)
        end

        for _, map in ipairs(mapCycle.maps) do
            if type(map) == "table" and map.map == mapName then
                if type(map.mods) == "table" then
                    table.copy(map.mods, mods, true)
                end
                break
            end
        end

        for _, modName in ipairs(mods) do
            local modDirs = { }                
            Shared.GetMatchingFileNames("config://mods/" .. modName .. "_*", false, modDirs)
            table.sort(modDirs)

            local dirName = string.sub(modDirs[#modDirs-1], 6, -2)
            local name = dirName

            local func = loadfile(path)
            if func then
                local data = { }
                local succeeded = pcall(setfenv(func, data))
                if succeeded and data.name then
                    name = data.name
                end
            end

            modInfo[dirName] = { hash = Shared.GetDirHash("config://mods/" .. dirName), name = name }

            ModManager.LoadMod(dirName)
        end
    end

    Event.Hook("MapPreLoad", OnMapPreLoad)

    local connectedUserIds = { }

    local function OnClientConnect(client)
        connectedUserIds[client:GetUserId()] = client

        if not enabled then return end

        local message = { downloadUrl = downloadUrl, totalMods = totalMods }
        Server.SendNetworkMessage("SetEnabledCustomMods", message, true)

        for dirName, info in pairs(modInfo) do
            local message = { dirName = dirName, hash = info.hash, name = info.name }
            Server.SendNetworkMessage("SetModInfo", message, true)
        end
    end

    Event.Hook("ClientConnect", OnClientConnect)

    local function OnClientDisconnect(client)
        connectedUserIds[client:GetUserId()] = nil
    end
    
    Event.Hook("ClientDisconnect", OnClientDisconnect)

    function ModManager.OnLoadingComplete()
        for user_id, client in pairs(connectedUserIds) do
            OnClientConnect(client)
        end
    end

elseif Client then

    local modDirNames = { }

    local function OnSetEnabledCustomMods(message)
        enabled = true
        downloadUrl = message.downloadUrl
        totalMods = message.totalMods        
        waitingForMods = message.totalMods

        Shared.Message("[ModManager] " .. waitingForMods .. " mods are enabled on this server")
    end

    Client.HookNetworkMessage("SetEnabledCustomMods", OnSetEnabledCustomMods)

    local function OnSetModInfo(message)
        Shared.Message("[ModManager] Loading " .. message.name .. "...")

        table.insert(modDirNames, message.dirName)

        modInfo[message.dirName] = { hash = message.hash, name = message.name }

        waitingForMods = waitingForMods - 1
        queuedMods = queuedMods + 1
    end

    Client.HookNetworkMessage("SetModInfo", OnSetModInfo)

    function ModManager.OnLoadingComplete()
        Client.FinishedLoading()
    end

    local GetNumMods = Client.GetNumMods
    function Client.GetNumMods()
        return enabled and totalMods or GetNumMods()
    end

    local GetIsModMounted = Client.GetIsModMounted
    function Client.GetIsModMounted(i)
        return enabled and true or GetIsModMounted(i)
    end

    local GetModTitle = Client.GetModTitle
    function Client.GetModTitle(i)
        return enabled and modInfo[modDirNames[i]] or GetModTitle(i)
    end

    local GetModState = Client.GetModState
    function Client.GetModState()
        return enabled and "available" or GetModState()
    end

end