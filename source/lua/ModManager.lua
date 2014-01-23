Script.Load("lua/md5.lua")

local kMaxDownloadChunkSize = 5120 * 1024.0
local kMaxConcurrentChunkDownloads = 2
local kMaxConcurrentDownloads = 8
local kMaxDownloadAttempts = 20

local kMaxConcurrentUploads = 8
local kMaxUploadAttempts = 8

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

local queuedModUploads = { }
local uploadingMods = { }

local modInfo = { }

ModManager = { }

local function DownloadNextQueuedMod()
    local dirName = table.remove(queuedMods, 1)
    ModManager.DownloadMod(dirName)
end

function ModManager.LoadMod(dirName)
    local matchingPaths = { }
    
    Shared.GetMatchingFileNames("config://mods/" .. dirName, false, matchingPaths)

    if #matchingPaths > 0 then
        if Shared.GetDirHash("config://mods/" .. dirName) == modInfo[dirName].hash then
            Shared.Message("[ModManager] Mounting mod directory: " .. dirName)
            
            Shared.MountModDir(dirName)

            if waitingForMods + #queuedMods == 0 then
                Shared.Message("[ModManager] All mods have been loaded successfully")
                ModManager.OnLoadingComplete()
            else
                DownloadNextQueuedMod()
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
    if #downloadingMods < kMaxConcurrentDownloads then
        ModManager.DownloadMod(dirName)
    else
        table.insert(queuedMods, dirName)
    end
end

function ModManager.DownloadMod(dirName)
    if modInfo[dirName].attempts >= kMaxDownloadAttempts then
        Shared.ModMissingError("Failed to download mod: " .. dirName)
        return
    end

    table.insert(downloadingMods, dirName)

    modInfo[dirName].attempts = modInfo[dirName].attempts + 1

    local zipPath = string.format("config://mods/%s.zip", dirName)
    local downloadUrl = string.format("%s/%s.zip", ModManager.downloadUrl, dirName)
    local totalBytes, totalParts, downloadingParts = 0
    local queuedParts = { }
    local downloadedParts = { }

    local function WritePartsToDisk()
        local zipFile = io.open(zipPath, "wb")
        local startedAt = Shared.GetTime()

        for i = 1, totalParts do
            zipFile:write(downloadedParts[i])
        end

        io.close(zipFile)

        Shared.Message(string.format("[ModManager] Mod archive written to disk: %s (took: %.2f)", dirName, Shared.GetTime() - startedAt))
    end

    local function ExtractMod(dirName)
        Shared.Message("[ModManager] Extracting mod: " .. dirName)

        local startedAt = Shared.GetTime()

        Shared.ExtractZip(zipPath, "config://mods", function(succeeded)

            if succeeded then
                Shared.Message(string.format("[ModManager] Mod extraction complete: %s (took: %.2f seconds)", dirName, Shared.GetTime() - startedAt))

                ModManager.LoadMod(dirName)
            else
                Shared.Message(string.format("[ModManager] Mod extraction failed: %s (requeuing mod)", dirName))

                ModManager.QueueMod(dirName)
            end

        end)
    end

    local function DownloadModPart(partNumber, attempts)
        attempts = attempts or 1

        if attempts > kMaxDownloadAttempts then
            Shared.ModMissingError("Failed to download mod: " .. dirName)
            return
        end

        downloadingParts = downloadingParts + 1

        Shared.Message(string.format("[ModManager] Downloading mod: %s (part: %d/%d, attempt: %d)", downloadUrl, partNumber, totalParts, attempts))

        local firstByte = partNumber == 1 and 0 or (partNumber - 1) * kMaxDownloadChunkSize + 1
        local range = string.format("bytes=%d-%d", firstByte, firstByte + kMaxDownloadChunkSize)

        Shared.SendHTTPRequest {
            url = downloadUrl,
            header = { ["User-Agent"] = kServerUserAgent, ["Range"] = range },

            onSuccess = function(body)
                downloadingParts = downloadingParts - 1

                if #queuedParts > 0 then
                    local nextPart = table.remove(queuedParts, 1)
                    DownloadModPart(nextPart)
                elseif downloadingParts == 0 then
                    table.removevalue(downloadingMods, dirName)
                    WritePartsToDisk()
                    ExtractMod()
                end
            end,

            onError = function(body, header, code)
                Shared.Message(string.format("[ModManager] Mod part %d/%d download attempt #%d failed: %s (response code: %d)", partNumber, totalParts, attempts, dirName, code))

                downloadingParts = downloadingParts - 1

                DownloadModPart(partNumber, attempts + 1)
            end
        }
    end

    Shared.Message(string.format("[ModManager] Mod download attempt #%d: %s", modInfo[dirName].attempts, downloadUrl))

    Shared.SendHTTPRequest {
        method = "HEAD",
        url = downloadUrl,
        header = { ["User-Agent"] = kServerUserAgent },

        onSuccess = function(body, header, code)
            totalBytes = tonumber(header['Content-Length'])
            totalParts = totalBytes / kMaxDownloadChunkSize

            Shared.Message(string.format("[ModManager] Mod download starting: %s (%d parts, %.2f KB)", dirName, totalParts, totalBytes / 1024.0))

            for i = 1, totalParts do
                if i <= kMaxConcurrentChunkDownloads then
                    DownloadModPart(i)
                else
                    table.insert(queuedParts, i)
                end
            end
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

    local function ArchiveModDir(dirName, isWorkshopMod, callback)
        local dirPath = string.format("%s/%s", isWorkshopMod and "config://mods" or "config://workshop", dirName)
        local zipPath = string.format("config://mods/%s.zip", dirName)
        local startedAt = Shared.GetTime()

        Shared.Message("[ModManager] Creating archive for mod directory: " .. dirName)

        Shared.CreateZip(dirPath, zipPath, function(succeeded)

            if succeeded then
                Shared.Message(string.format("[ModManager] Created archive for mod directory: %s (took: %.2f seconds)", dirName, Shared.GetTime() - startedAt))
            else
                Shared.Message("[ModManager] Failed to create archive for mod directory: " .. dirName)
            end

            callback(succeeded)

        end)
    end

    local function UploadNextQueuedMod()
        local dirName = table.remove(queuedModUploads, 1)
        ModManager.UploadMod(dirName)
    end

    function ModManager.UploadMod(dirName)
        if modInfo[dirName].uploadAttempts >= kMaxUploadAttempts then
            Shared.Message("Failed to upload mod: " .. dirName)
            --TODO: stop mod from being loaded since clients will be unable to download it
            return
        end

        table.insert(uploadingMods, dirName)

        modInfo[dirName].uploadAttempts = modInfo[dirName].uploadAttempts + 1

        local zipPath = string.format("config://mods/%s.zip", dirName)

        Shared.Message(string.format("[ModManager] Uploading mod: %s (attempt: %d)", dirName, modInfo[dirName].uploadAttempts))

        --TODO: send upload metadata to server, get max upload chunk size and upload each chunk to the web server
    end

    function ModManager.QueueModUpload(dirName)
        if #uploadingMods < kMaxConcurrentUploads then
            ModManager.UploadMod(dirName)
        else
            table.insert(queuedModUploads, dirName)
        end
    end

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

            modInfo[dirName] = { hash = Shared.GetDirHash("config://mods/" .. dirName), name = name, attempts = 0, uploadAttempts = 0 }

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

    local GetNumMods = Server.GetNumMods
    function Server.GetNumMods()
        return enabled and totalMods or GetNumMods()
    end

    Server.GetNumActiveMods = Server.GetNumMods

    local GetModId = Server.GetModId
    function Server.GetModId(i)
        return enabled and true or GetModId(i)
    end

    Server.GetActiveModId = Server.GetModId

    local GetModTitle = Server.GetModTitle
    function Server.GetModTitle(i)
        return enabled and modInfo[modDirNames[i]] or GetModTitle(i)
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