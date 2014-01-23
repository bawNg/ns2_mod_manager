Script.Load("lua/md5.lua")

local kMaxConcurrentModDownloads = 8
local kMaxModDownloadAttempts = 20
local kServerUserAgent = string.format("NS2 Server: %s:%d", IPAddressToString(Server.GetIpAddress()), Server.GetPort())

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

function Server.AcceptClientConnections(acceptConnections)
    -- AcceptClientConnections(false) tells the server to not accept client connections until AcceptClientConnections(true) is called
end

function Shared.ModMissingError(errorMessage)
    -- Tell the engine that there was an error loading one or more mods
end

function Shared.SendHTTPRequest(table)
    -- Make a HTTP request with optionally specified headers and an error callback called if the request fails
    -- Default request options if not given: method = "GET", data = { }, header = { }
    -- Callback arguments for onSuccess and onError: (body, responseHeader, code)
    -----------------------------------------------------------------------------
    -- Example usage:
    -----------------------------------------------------------------------------
    -- Shared.SendHTTPRequest {
    --   method = "POST",
    --   url = kUploadFileUrl,
    --   data = { name = "example.txt", content = fileContent },
    --   header = { ["User-Agent"] = string.format("NS2 Server: %s:%d", IPAddressToString(Server.GetIpAddress()), Server.GetPort()) },
    --   onSuccess = function(data, header, code)
    --      Shared.Message("File upload successful!")
    --   end,
    --   onError = function(data, header, code)
    --      Shared.Message("Uploading file failed! Response code: " .. code)
    --   end
    -- }
end

function Shared.CreateZip(dirPath, zipFile, callback)
    -- Create a zip archive containing the specified directory
end

function Shared.ExtractZip(zipFile, destinationPath, callback)
    -- Extract the specified zip archive contents to the destination path
    -- Callback arguments: suceeded
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

local queuedMods = { }
local downloadingMods = { }
local modInfo = { }

ModManager = { }

function ModManager.LoadMod(dirName)
    local matchingPaths = { }
    
    Shared.GetMatchingFileNames("config://mods/" .. dirName, false, matchingPaths)

    if #matchingPaths then
        if Shared.GetDirHash("config://mods/" .. dirName) == modInfo[dirName].hash then                
            Shared.Message("[ModManager] Mounting mod directory: " .. dirName)
            
            Shared.MountModDir(dirName)

            if waitingForMods + #queuedMods == 0 then
                Shared.Message("[ModManager] All mods have been loaded successfully")
                ModManager.OnLoadingComplete()
            else
                ModManager.DownloadNextQueuedMod()
            end
        else
            Shared.Message("[ModManager] Invalid mod directory: " .. dirName)
            ModManager.DownloadMod(dirName)
        end
    else
        ModManager.DownloadMod(dirName)
    end
end

function ModManager.QueueMod(dirName)
    if #downloadingMods < kMaxConcurrentModDownloads then
        ModManager.DownloadMod(dirName)
    else
        table.insert(queuedMods, message.dirName)
    end
end

function ModManager.DownloadNextQueuedMod()
    if #queuedMods == 0 then
        return false
    end

    local dirName = table.remove(queuedMods, 1)
    ModManager.DownloadMod(dirName)

    return true
end

function ModManager.DownloadMod(dirName)
    if modInfo[dirName].attempts >= kMaxModDownloadAttempts then
        Shared.ModMissingError("Failed to download mod: " .. dirName)
        return
    end

    table.insert(downloadingMods, dirName)

    modInfo[dirName].attempts = modInfo[dirName].attempts + 1

    local modDownloadUrl = string.format("%s/%s.zip", ModManager.downloadUrl, dirName)

    Shared.Message(string.format("[ModManager] Downloading mod: %s (attempt: %d)", modDownloadUrl, modInfo[dirName].attempts))

    --TODO: download mods in multiple parts using header support, track progress and retry parts on failure instead of entire mod
    Shared.SendHTTPRequest {
        url = modDownloadUrl,
        header = { ["User-Agent"] = kServerUserAgent },

        onSuccess = function(archiveContents)
            local zipFilePath = string.format("config://mods/%s.zip", dirName)
            local zipFile = io.open(tarFilePath, "wb")

            zipFile:write(archiveContents)

            io.close(zipFile)

            Shared.Message("[ModManager] Extracting mod: " .. dirName)

            local startedAt = Shared.GetTime()

            Shared.ExtractZip(zipFilePath, "config://mods", function(succeeded)

                table.removevalue(downloadingMods, dirName)

                if succeeded then
                    Shared.Message(string.format("[ModManager] Mod extraction complete: %s (took: %.2f seconds)", dirName, Shared.GetTime() - startedAt))

                    ModManager.LoadMod(dirName)
                else
                    Shared.Message(string.format("[ModManager] Mod extraction failed: %s (requeuing mod)", dirName))

                    ModManager.QueueMod(dirName)
                end

            end)
        end,

        onError = function(body, header, code)
            Shared.Message(string.format("[ModManager] Mod download attempt %d failed: %s (response code: %d)", modInfo[dirName].attempts, dirName, code))

            table.removevalue(downloadingMods, dirName)

            ModManager.QueueMod(dirName)
        end
    }
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

        Server.AcceptClientConnections(false)

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

            modInfo[dirName] = { hash = Shared.GetDirHash("config://mods/" .. dirName), name = name, attempts = 0 }

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
        Server.AcceptClientConnections(true)
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

        modInfo[message.dirName] = { hash = message.hash, name = message.name, attempts = 0 }

        waitingForMods = waitingForMods - 1
        
        ModManager.QueueMod(message.dirName)
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