if not game:IsLoaded() then
	game.Loaded:Wait()
end

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local TweenService = game:GetService("TweenService")

-- If the script runs more than once (e.g. queued twice), only the newest run keeps its loops alive
local RUN_ID = tostring(os.clock()) .. tostring(math.random(1, 1e9))
local env = (getgenv and getgenv()) or _G
env.SatisHubRunId = RUN_ID
env.SatisHubAutoPlacing = nil
local function alive()
	return env.SatisHubRunId == RUN_ID
end

-- Remotes are looked up when used. Some of them only exist in the lobby or only in a match,
-- so we never wait for them forever (that would freeze the whole script after a teleport).
local endpoints = ReplicatedStorage:WaitForChild("endpoints", 30)
local c2s = endpoints and endpoints:WaitForChild("client_to_server", 30)

local function invoke(name, ...)
	local remote = c2s and c2s:FindFirstChild(name)
	if remote then
		local args = { ... }
		pcall(function()
			remote:InvokeServer(table.unpack(args))
		end)
	end
end

-- Same as invoke, but returns (ok, result) so we can see what the server answered
local function invokeRet(name, ...)
	local remote = c2s and c2s:FindFirstChild(name)
	if not remote then
		return false
	end
	local args = { ... }
	return pcall(function()
		return remote:InvokeServer(table.unpack(args))
	end)
end

-- Packs all return values (including nils) so the __namecall hook can preserve them.
local function pack(...)
	return { n = select("#", ...), ... }
end

local INTERVALO = 1.5
local JOIN_INTERVALO = 5

-- Fixed access key (letters and numbers). Change it here whenever you want.
local KEY = "YJ9IWS8WHFUS6RZZZC73"

local function normalizeKey(s)
	return (s:upper():gsub("%s+", ""))
end

local state = {
	autoStart = false,
	autoSkip = false,
	autoReplay = false,
	autoLeave = false,
	autoCard = false,
	randomCard = false,
	autoJoinEvent = false,
	autoJoinDailyChallenge = false,
    dailyResetAt = 0,
    dailyCompletedResetAt = 0,
    dailyJoinPending = false,
    dailyLockUntil = 0,
	randomPlace = false,
	placeRadius = "15",
	unitIds = "",
	transparent = false,
	autoUpgrade = false,
	autoScanUnits = false,
	antiAfk = false,
	minimizeKey = "RightShift",
	incognitoMode = false,
	autoExecTeleport = true,
	cardOption = "2",
	savedKey = "",
	rgbEnabled = true,
	themeColor = "",
    fpsBoost = false,
    farmingStats = {wins = 0, losses = 0, games = 0, gold = 0, gems = 0, xp = 0, seconds = 0},
}

-- ===== Anti-AFK: only acts when Roblox fires the local idle event =====
-- Avoids continuous input loops and does not interfere with normal play.
do
    local okService, virtualUser = pcall(function()
        return game:GetService("VirtualUser")
    end)
    local localPlayer = Players.LocalPlayer
    if okService and virtualUser and localPlayer then
        localPlayer.Idled:Connect(function()
            if not alive() or not state.antiAfk then return end
            local success, err = pcall(function()
                virtualUser:CaptureController()
                virtualUser:ClickButton2(Vector2.new(0, 0))
            end)
            if not success then
                warn("[SatisHub] Anti-AFK action failed: " .. tostring(err))
            end
        end)
    else
        warn("[SatisHub] Anti-AFK VirtualUser unavailable")
    end
end

-- ===== Settings saved to file (survive teleports) =====
local SAVE_FILE = "satishub_settings.json"

local function saveSettings()
	pcall(function()
		local copy = {}
		for k, v in pairs(state) do
			copy[k] = v
		end
		-- Auto Join Event is now saved like every other option: once you turn it ON,
		-- it stays ON after a teleport / new server.
		writefile(SAVE_FILE, HttpService:JSONEncode(copy))
	end)
end

local function loadSettings()
	pcall(function()
		if isfile(SAVE_FILE) then
			local data = HttpService:JSONDecode(readfile(SAVE_FILE))
			for k, v in pairs(data) do
				if state[k] ~= nil then
					state[k] = v
				end
			end
		end
	end)
	-- The saved value is kept. If it was ON before, it comes back ON.
end

loadSettings()

-- ===== Daily Challenge: reset countdown + completion lock =====
-- Completion is stored independently so a late timer sync cannot erase it.
local dailyChallenge = {}
do
    local PERIOD = 86400
    local function now() return os.time() end
    local function deadline()
        local t = tonumber(state.dailyResetAt) or 0
        if t > 0 and now() >= t then
            t = t + (math.floor((now() - t) / PERIOD) + 1) * PERIOD
            state.dailyResetAt = t
            if (tonumber(state.dailyLockUntil) or 0) <= now() then
                state.dailyLockUntil = 0
                state.dailyCompletedResetAt = 0
                state.dailyJoinPending = false
            end
            saveSettings()
        end
        return t
    end
    function dailyChallenge.remaining()
        local t = deadline()
        return t > 0 and math.max(0, t - now()) or nil
    end
    function dailyChallenge.completed()
        return (tonumber(state.dailyLockUntil) or 0) > now()
    end
    function dailyChallenge.canJoin()
        return not dailyChallenge.completed()
    end
    function dailyChallenge.markFinished()
        if not state.dailyJoinPending then return end
        dailyChallenge.markCompleted('game_finished')
    end
    function dailyChallenge.markCompleted(reason)
        local t = deadline()
        if t <= now() then t = now() + PERIOD end
        state.dailyResetAt = t
        state.dailyLockUntil = t
        state.dailyCompletedResetAt = t
        state.dailyJoinPending = false
        saveSettings()
        print('[SatisHub] Daily Challenge: COMPLETED (' .. tostring(reason) .. '); locked until daily reset.')
    end
    function dailyChallenge.requested()
        state.dailyJoinPending = true
        saveSettings()
    end
    local serverEvents = endpoints and endpoints:FindFirstChild('server_to_client')
    local function onCountdown(seconds)
        if not alive() then return end
        local remaining = tonumber(seconds)
        if not remaining or remaining < 0 or remaining > PERIOD + 300 then return end
        local old = tonumber(state.dailyResetAt) or 0
        local fresh = now() + math.floor(remaining)
        if old > 0 and math.abs(fresh - old) < 90 then return end
        local locked = dailyChallenge.completed()
        local oldLock = tonumber(state.dailyLockUntil) or 0
        state.dailyResetAt = fresh
        if locked then
            -- Correct an estimated deadline without losing the completion lock.
            -- Only unlock after an actual new day has begun.
            if old > 0 and now() >= old and fresh > old + 300 then
                state.dailyLockUntil = 0
                state.dailyCompletedResetAt = 0
            else
                state.dailyLockUntil = fresh
                state.dailyCompletedResetAt = fresh
            end
        elseif oldLock > 0 and oldLock <= now() then
            state.dailyLockUntil = 0
            state.dailyCompletedResetAt = 0
        end
        saveSettings()
        print('[SatisHub] Daily countdown synced: ' .. tostring(math.floor(remaining)) .. 's remaining')
    end
    task.spawn(function()
        if not serverEvents then return end
        local ev = serverEvents:WaitForChild('daily_challenge_remaining_time_changed', 30)
        if ev and ev:IsA('RemoteEvent') then
            ev.OnClientEvent:Connect(onCountdown)
        else
            warn('[SatisHub] Daily countdown signal missing; waiting for a future sync.')
        end
    end)
    task.spawn(function()
        if not serverEvents then return end
        local ev = serverEvents:WaitForChild('game_finished', 30)
        if ev and ev:IsA('RemoteEvent') then
            ev.OnClientEvent:Connect(function()
                if alive() then dailyChallenge.markFinished() end
            end)
        end
    end)
end

-- Started by a queued teleport (auto execute)?
local fromQueue = env.SatisHubFromQueue and true or false
if fromQueue then
	env.SatisHubFromQueue = nil
	-- "Auto Execute On Teleport" is OFF: do not run
	if not state.autoExecTeleport then
		return
	end
end

-- ===== Auto execute on teleport / server change =====
-- Unique marker used to detect whether the saved satishub.lua is this updated version.
local SCRIPT_BUILD = "SatisHub-2026-11-01-no-hide-messages"
-- Option A: put your raw script URL here (GitHub raw, pastebin raw, etc.)
   local SCRIPT_URL = "https://raw.githubusercontent.com/satisxx/satishub/main/satishub.lua"
-- Option B (if URL is empty): save this script in your executor's workspace folder.
-- The main name is "satishub.lua"; the other names are accepted too (some phones add .txt when saving).
local SCRIPT_FILE = "satishub.lua"
local SCRIPT_FILE_NAMES = {
	"satishub.lua",
	"SatisHub.lua",
	"satishub.luau",
	"satishub.txt",
	"satishub.lua.txt",
}

local queueFn = queue_on_teleport
	or (syn and syn.queue_on_teleport)
	or (fluxus and fluxus.queue_on_teleport)

-- Reads the saved copy of this script (returns content, fileName)
local function readOwnFile()
	if not (isfile and readfile) then
		return nil
	end
	local firstOld
	for _, name in ipairs(SCRIPT_FILE_NAMES) do
		local okR, content = pcall(function()
			if isfile(name) then
				return readfile(name)
			end
		end)
		if okR and type(content) == "string" and #content > 0 then
			if content:find(SCRIPT_BUILD, 1, true) then
				return content, name, true
			end
			firstOld = firstOld or { content, name }
		end
	end
	if firstOld then
		return firstOld[1], firstOld[2], false
	end
	return nil
end

if SCRIPT_URL == "" and not readOwnFile() then
	warn("[SatisHub] Auto execute needs SCRIPT_URL filled in or the file '" .. SCRIPT_FILE .. "' saved in your executor's workspace folder.")
end

-- Code that runs in the next server: waits for the game, then loads the script.
-- Order: embedded copy -> file read again in the new server -> URL.
local function buildQueuedCode()
    -- Runs in the NEW game, not in the old server.
    -- Never use a saved embedded copy: always prefer the latest GitHub script.
    local parts = {
        "repeat task.wait() until game:IsLoaded()",
        "task.wait(5)",
        "local env = (type(getgenv) == 'function' and getgenv()) or _G",
        "env.SatisHubFromQueue = true",
        [[local function runSource(source, label)
            if type(source) ~= "string" or source == "" then
                return false, label .. ": empty response"
            end
            if type(loadstring) ~= "function" then
                return false, "loadstring unavailable in executor"
            end
            local chunk, compileError = loadstring(source)
            if type(chunk) ~= "function" then
                return false, label .. " compile: " .. tostring(compileError)
            end
            local ok, err = pcall(chunk)
            if not ok then return false, label .. " runtime: " .. tostring(err) end
            return true
        end]],
        "local ok, err = false, 'no script source available'",
    }
    if SCRIPT_URL ~= "" then
        parts[#parts + 1] = ("local fetched, result = pcall(function() return game:HttpGet(%q) end); if fetched then ok, err = runSource(result, 'GitHub') else err = 'download: ' .. tostring(result) end"):format(SCRIPT_URL)
    end
    local quotedNames = {}
    for _, n in ipairs(SCRIPT_FILE_NAMES) do
        quotedNames[#quotedNames + 1] = ("%q"):format(n)
    end
    parts[#parts + 1] = ("if not ok and type(isfile) == 'function' and type(readfile) == 'function' then for _, n in ipairs({%s}) do local exists, has = pcall(isfile, n); if exists and has then local readOk, content = pcall(readfile, n); if readOk then ok, err = runSource(content, n); if ok then break end end end end end"):format(table.concat(quotedNames, ","))
    parts[#parts + 1] = 'if not ok then env.SatisHubFromQueue = nil; warn("[SatisHub] auto execute failed: " .. tostring(err)) end'
    return table.concat(parts, "\n")
end

-- Shown in the About tab and in the startup notice so you can see if auto execute is actually possible
local autoExecStatus
if not queueFn then
	autoExecStatus = "Auto execute: NOT supported by this executor. Put the script in its autoexec folder."
elseif SCRIPT_URL == "" and not readOwnFile() then
	autoExecStatus = "Auto execute: NOT ready. Save the script as '" .. SCRIPT_FILE .. "' in the workspace folder (or fill SCRIPT_URL)."
else
	local src, foundName, isCurrent = readOwnFile()
	if src and not isCurrent then
		autoExecStatus = "Auto execute: saved file is OLD. Replace '" .. SCRIPT_FILE .. "' with this updated script."
	else
		autoExecStatus = "Auto execute: ready" .. (foundName and (" (" .. foundName .. ")") or " (URL)")
	end
end
local execName = "unknown"
pcall(function()
	if identifyexecutor then
		execName = tostring((identifyexecutor()))
	end
end)
autoExecStatus = autoExecStatus .. " [" .. execName .. "]"
print("[SatisHub] " .. autoExecStatus)

-- ===== Unit placement learning =====
-- The unit IDs and positions change per account/map, so the script learns them:
-- every time YOU place a unit manually, the ID and position used by the game are recorded.
-- It also scans the inventory / unit folders, so auto place can work before the first manual unit.
local learned = env.SatisHubLearned
if not learned then
	learned = { ids = {}, confirmed = {}, likely = {}, manual = {}, count = 0, positions = {} }
	env.SatisHubLearned = learned
end
learned.ids = learned.ids or {}
learned.confirmed = learned.confirmed or {}
learned.likely = learned.likely or {}
learned.manual = learned.manual or {}
learned.positions = learned.positions or {}
learned.count = learned.count or 0

-- Scans YOUR player and GUI for unit IDs (format {xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx}):
-- instance names, StringValues and attributes. Finds all your units, not only the one you placed.
local UUID_PATTERN = "^{%x+%-%x+%-%x+%-%x+%-%x+}$"
local lastScan = 0

local function addUnitId(id, confirmed, likely)
	if type(id) ~= "string" or not id:match(UUID_PATTERN) then
		return false
	end
	if confirmed then
		learned.confirmed[id] = true
	end
	if likely then
		learned.likely[id] = true
	end
	if not learned.ids[id] then
		learned.ids[id] = true
		learned.count = learned.count + 1
		return true
	end
	return false
end

-- Finds UUID strings inside tables/strings returned by the game's remotes.
local function collectUuids(value, depth, seen, likely)
	depth = depth or 0
	if depth > 5 then
		return
	end
	local t = type(value)
	if t == "string" then
		addUnitId(value, false, likely)
	elseif t == "table" then
		seen = seen or {}
		if seen[value] then
			return
		end
		seen[value] = true
		for k, v in pairs(value) do
			if type(k) == "string" then
				addUnitId(k, false, likely)
			end
			if type(v) == "string" then
				addUnitId(v, false, likely)
			elseif type(v) == "table" then
				collectUuids(v, depth + 1, seen, likely)
			end
		end
	end
end

local HOOK_VERSION = 2
local DIAGNOSTIC_DISABLE_HOOK = true
local installedHookVersion = tonumber(env.SatisHubHookVersion) or 0
if not DIAGNOSTIC_DISABLE_HOOK and installedHookVersion < HOOK_VERSION and hookmetamethod and getnamecallmethod then
	local okHook = pcall(function()
		local old
		old = hookmetamethod(game, "__namecall", (newcclosure or function(f) return f end)(function(self, ...)
			local method = getnamecallmethod()
			if method == "InvokeServer" and typeof(self) == "Instance" and not (checkcaller and checkcaller()) then
				local args = { ... }
				local remoteName = self.Name
				if remoteName == "spawn_unit" and not env.SatisHubAutoPlacing then
					local id, cf = args[1], args[2]
					if type(id) == "string" then
						addUnitId(id, true, true)
					end
					if typeof(cf) == "CFrame" then
						local list = learned.positions
						list[#list + 1] = cf.Position
						if #list > 30 then
							table.remove(list, 1)
						end
					end
				end
				local results = pack(old(self, ...))
				-- Inventory / shop responses often contain the unit UUIDs. Capturing them
				-- here means auto place works even before you manually place the first unit.
				local n = remoteName:lower()
				if n:find("unit") or n:find("spawn") or n:find("inventory") or n:find("shop") or n:find("roster") or n:find("owned") or n:find("data") or n:find("save") or n:find("load") or n:find("profile") or n:find("team") or n:find("deck") then
					pcall(function()
						local seen = {}
						for i = 1, results.n do
							collectUuids(results[i], 0, seen, true)
						end
					end)
				end
				return table.unpack(results, 1, results.n)
			end
			return old(self, ...)
		end))
	end)
	if okHook then
		env.SatisHubHooked = true
		env.SatisHubHookVersion = HOOK_VERSION
	end
end

-- Scans a whole instance tree for UUIDs (names, StringValues and attributes).
local function scanInstanceTree(root, likely)
	if not root then
		return
	end
	local n = 0
	for _, inst in ipairs(root:GetDescendants()) do
		n = n + 1
		if n % 400 == 0 then
			task.wait()
			if not alive() then
				return
			end
		end
		addUnitId(inst.Name, false, likely)
		if inst:IsA("StringValue") then
			addUnitId(inst.Value, false, likely)
		end
		if inst:IsA("LuaSourceContainer") then
			-- In some games the unit IDs are written in a ModuleScript table.
			-- Source access is blocked in live games, so this is best-effort.
			local okSrc, source = pcall(function()
				return inst.Source
			end)
			if okSrc and type(source) == "string" and #source > 0 then
				for id in source:gmatch("{%x+%-%x+%-%x+%-%x+%-%x+}") do
					addUnitId(id, false, likely)
				end
			end
		end
		for _, v in pairs(inst:GetAttributes()) do
			addUnitId(v, false, likely)
		end
	end
end

local scanning = false
local function scanUnitIds(full)
	if scanning then
		return 0
	end
	scanning = true
	lastScan = os.clock()
	local before = learned.count
	pcall(function()
		scanInstanceTree(Players.LocalPlayer, true)
		if full ~= false then
			scanInstanceTree(ReplicatedStorage, false)
		end
		local unitsFolder = workspace:FindFirstChild("_UNITS")
		if unitsFolder then
			scanInstanceTree(unitsFolder, false)
		end
		-- Scan likely unit / placement folders in the workspace, but not the whole map.
		for _, inst in ipairs(workspace:GetChildren()) do
			local name = inst.Name:lower()
			if name:find("unit") or name:find("place") or name:find("tower") or name:find("base") or name:find("plot") then
				scanInstanceTree(inst, false)
			end
		end
	end)
	scanning = false
	return learned.count - before
end

-- Auto Scan Units: periodic lightweight inventory scans, without hooks or repeated full map scans.
-- The setting survives teleports through the existing saveSettings/loadSettings logic.
local AUTO_SCAN_INTERVAL = 20
local autoScanNextAt = 0
local function requestAutoScan()
    autoScanNextAt = 0
end

task.spawn(function()
    while alive() do
        if state.autoScanUnits and os.clock() >= autoScanNextAt then
            autoScanNextAt = os.clock() + AUTO_SCAN_INTERVAL
            -- scanUnitIds already prevents simultaneous scans.
            local ok, count = pcall(scanUnitIds, false)
            if ok and count > 0 then
                print(("[SatisHub] Auto Scan Units: found %d new ID(s)"):format(count))
            elseif not ok then
                warn("[SatisHub] Auto Scan Units failed: " .. tostring(count))
            end
        end
        task.wait(1)
    end
end)

-- Scan once after loading so the IDs are available even if auto place is turned on later.
task.spawn(function()
	task.wait(1)
	if not alive() then
		return
	end
	scanUnitIds(true)
end)

local clearQueueFn = clear_queue_on_teleport or clearqueueonteleport or (syn and syn.clear_queue_on_teleport)

local function queueSelf()
    if state.autoExecTeleport and type(queueFn) == "function" then
        local ok, err = pcall(queueFn, buildQueuedCode())
        if not ok then warn("[SatisHub] Could not queue teleport script: " .. tostring(err)) end
    end
end

local function setAutoExecTeleport(v)
    if v then
        queueSelf()
    elseif type(clearQueueFn) == "function" then
        pcall(clearQueueFn)
    end
end

-- Register once now. Do not queue repeatedly during the teleport itself.
queueSelf()

-- ===== Look =====
-- Black background (changeable in Settings), grey controls, RGB borders. Green only means "ON".
local ON_COLOR = Color3.fromRGB(0, 170, 100)
local ERROR_COLOR = Color3.fromRGB(240, 70, 70)
local OFF_STROKE = Color3.fromRGB(45, 59, 82)
local DEFAULT_THEME = Color3.fromRGB(11, 14, 23)
local WHITE = Color3.new(1, 1, 1)

-- RGB palette (first and last colors match so the rotation loops smoothly)
local RAINBOW = ColorSequence.new({
	ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 0, 0)),
	ColorSequenceKeypoint.new(0.17, Color3.fromRGB(255, 255, 0)),
	ColorSequenceKeypoint.new(0.33, Color3.fromRGB(0, 255, 0)),
	ColorSequenceKeypoint.new(0.5, Color3.fromRGB(0, 255, 255)),
	ColorSequenceKeypoint.new(0.67, Color3.fromRGB(0, 0, 255)),
	ColorSequenceKeypoint.new(0.83, Color3.fromRGB(255, 0, 255)),
	ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 0, 0)),
})

local currentTheme = DEFAULT_THEME
do
	local hex = tostring(state.themeColor or "")
	if hex ~= "" then
		local okC, c = pcall(Color3.fromHex, hex)
		if okC and c then
			currentTheme = c
		end
	end
end

-- Icon image (embedded, shown when the hub is minimized)
local ICON_B64 = "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAcFBQYFBAcGBgYIBwcICxILCwoKCxYPEA0SGhYbGhkWGRgcICgiHB4mHhgZIzAkJiorLS4tGyIyNTEsNSgsLSz/2wBDAQcICAsJCxULCxUsHRkdLCwsLCwsLCwsLCwsLCwsLCwsLCwsLCwsLCwsLCwsLCwsLCwsLCwsLCwsLCwsLCwsLCz/wAARCABwAHADASIAAhEBAxEB/8QAGwAAAgMBAQEAAAAAAAAAAAAAAgMAAQYEBQf/xAAvEAACAQMDAgUDAwUBAAAAAAABAgADBBEFEiExUQYTIkFhcYHRFCMyQmKhscGR/8QAGAEBAQEBAQAAAAAAAAAAAAAAAAEEAwL/xAAcEQEBAQADAQEBAAAAAAAAAAAAARECAyExQVH/2gAMAwEAAhEDEQA/AM6rRgac6tDDTWz6eDL3RQaWGhdNDSw0Vuk3cQabuk3RW6TdBpu6TdFbpe6DTC0EtAzKLQaItFseJC0WzQlpStDDRCtDBleTg0INEgyw0Gmky90Xuk3Qpm6NoUK1y+yjTLn4iaFN7istKmMsxmqsrJLK3IpqCw/k56mQnrO17S5t8+bRZQOp6iI3T37q8p1lZWG4L1x1xM6WG9gBgAnEuJo90otAzKLSKstAJlFsQC2RKmlBoYaJBhBpUODS90SXCjJIAleY7fwXA7t+IHQGgtWRP5OoPyYkgYzUckfXAif1AHFFAPnH4kCdS8S6hoFalc2PlvRb01FqU8gn256zWaR4wtvE+l4oKKFyqjzqOf8AI7iZS5ope2j0axesrjBVRgAzIW91U8O64tS2q7wj43YxkdCDPHK2XXuezH0fVLn9E6ls98j2nHbVazM6Mu6kDupVV/i6n2+o7TxKuoan4iuGo2dq9xUYgEKMhe2T7D6zVaToNTRdM23ZZi5y2AWZm/tX2H15nXd8cZM9pG6UWi6tJ6VZkd6gIPQ8RaOdx9RZe5nl7NZoBaA9UKdo9TdhBBIHqOSZQG7AyeglGq2MgBR3Y4gnDDBGRKxSTkhRAgcO24sxI9lHSQuuDuX1ewduZDWPRV57Hr/5CVHcfuN9hIALbSMgOR7dcf8ABCNRSDlg2Pdjx9h7x6qqjAAA+Im5rJTXB7c+2BA5NSvWtbUKHIap046fieLpWn6lqepCjp1k1atnJLKCifJJ4E7Xr0tZomyqel6TegjGQw/PtEJ4v13TTUtLdzZ0eVNMIBjnrnHX5nGc/wCu14z8adrXU/CtkFu/Emn6UrNu8m1tg7knqegnLU8S6xStvMTV2vaNXOx6lEIyjv8AM4dN0G4vMajet57Hldx3gfJ7zztVufNumCszY43Mc5x/r6TrJk2uNu3I9ay1K5vRUa6qmvgjBA5P1PadZrceommvYKf9zh0eiVsAdzDcScDid/loDnGT3PM9AwFVfSMCUTBJgkwgcnHGM/MFKTZyzcnt+ZAYYMKNVCjCgCGDF5hZgHmC6h0KkZBGDKzLzCMnUzpt4GpjdURiTke86L7UaF9RWrcKWrnlm42nsAJ166tuoV3yKpBxgZzjvM4jolYPglepHeZu2TWrq5XMOo6jXoNstmqUVJycEgH7To5enl15745kuNQt61Ib1Q44VV6/f8z2NGq061sWRWG30885k6uVvlO3jOPsd1mNlnSXGMKI0mVmCTNTKsmCTITBJgQGGIpTDBhRgywYOZeYQWZeYGZMwPK8Qp5liu04qBvSffp7TOWelXV7di3o0Klaq2SFHHzk9po9V9Va2X2Lz2/DGyz1EMUUiouWb369Jm7OO3WjruSRi7vw5eadte7s2po39RII/wAGaDTralZ0DSo52cHk85IGZqtXoUtTtbncQcqUT65z/wAmYtDmkCRg9D9o6fp2ukmUTKzKJmlwQmDITBzxAsGGDFAw1MBmZeYGZeZUFmCTJmCxhXnamf36B7NPVsGQVqhaqEwMAe5z2nj6if3KfxOmjU21mbuMzPy+11nyNCjJStnoUn83ncx6ETwqR2vUH92Y2yrHyqjk9XijxcVB8zz1+Vefw3dITBzJmaXFCZWeJTGDmB//2Q=="

local function b64decode(data)
	local chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
	local lookup = {}
	for i = 1, #chars do
		lookup[chars:sub(i, i)] = i - 1
	end
	data = data:gsub("[^%w%+/=]", "")
	local out = {}
	local buf, bits = 0, 0
	for i = 1, #data do
		local c = data:sub(i, i)
		if c == "=" then
			break
		end
		buf = buf * 64 + lookup[c]
		bits = bits + 6
		if bits >= 8 then
			bits = bits - 8
			local byte = math.floor(buf / 2 ^ bits)
			out[#out + 1] = string.char(byte % 256)
			buf = buf % 2 ^ bits
		end
	end
	return table.concat(out)
end

local function loadIcon()
	local ok, asset = pcall(function()
		writefile("satishub_icon.jpg", b64decode(ICON_B64))
		local getAsset = getcustomasset or getsynasset
		return getAsset("satishub_icon.jpg")
	end)
	if ok and asset then
		return asset
	end
	return nil
end

-- Stop a mini-game left running by a previous execution of the script.
if env.SatisHubGameCleanup then
	pcall(env.SatisHubGameCleanup)
	env.SatisHubGameCleanup = nil
end
pcall(function()
	game:GetService("ContextActionService"):UnbindAction("SatisHubMiniGame")
end)

-- Remove old instances if the script is executed again
local parent = (gethui and gethui()) or Players.LocalPlayer:WaitForChild("PlayerGui")
for _, n in ipairs({ "SatisHub", "SatisHubBlack", "SatisHubESP" }) do
	local old = parent:FindFirstChild(n)
	if old then
		old:Destroy()
	end
end

-- FPS BOOST overlay (black screen)
local blackGui = Instance.new("ScreenGui")
blackGui.Name = "SatisHubBlack"
blackGui.ResetOnSpawn = false
blackGui.IgnoreGuiInset = true
blackGui.DisplayOrder = 5
blackGui.Parent = parent

local black = Instance.new("Frame")
black.Size = UDim2.fromScale(1, 1)
black.BackgroundColor3 = Color3.new(0, 0, 0)
black.BorderSizePixel = 0
black.Visible = false
black.Parent = blackGui


-- Farming Stats dashboard and reversible low-graphics mode.
-- Kept inside a function so this large script does not exceed Luau's local-register limit.
local function initFarmingDashboard()
    local stats = state.farmingStats
    if type(stats) ~= "table" then stats = {} end
    for _, key in ipairs({"wins", "losses", "games", "gold", "gems", "xp", "seconds"}) do
        stats[key] = tonumber(stats[key]) or 0
    end
    state.farmingStats = stats
    local started = os.clock()
    local lastFlush = started
    local finished = false
    local statsGui = Instance.new("ScreenGui")
    statsGui.Name = "SatisHubFarmingStats"
    statsGui.ResetOnSpawn = false
    statsGui.IgnoreGuiInset = true
    statsGui.DisplayOrder = 7 -- higher than the black screen, lower than SatisHub controls
    statsGui.Enabled = false
    statsGui.Parent = parent

    local panel = Instance.new("Frame")
    panel.AnchorPoint = Vector2.new(0.5, 0.5)
    panel.Position = UDim2.fromScale(0.5, 0.5)
    panel.Size = UDim2.fromOffset(340, 295)
    panel.BackgroundColor3 = Color3.fromRGB(18, 18, 24)
    panel.BorderSizePixel = 0
    panel.Parent = statsGui
    Instance.new("UICorner", panel).CornerRadius = UDim.new(0, 14)
    local outline = Instance.new("UIStroke", panel)
    outline.Color = Color3.fromRGB(75, 75, 90)
    outline.Thickness = 1.5
    local layout = Instance.new("UIListLayout", panel)
    layout.Padding = UDim.new(0, 9)
    layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    local pad = Instance.new("UIPadding", panel)
    pad.PaddingTop = UDim.new(0, 18)
    pad.PaddingLeft = UDim.new(0, 16)
    pad.PaddingRight = UDim.new(0, 16)
    local function label(text, order, size, color)
        local line = Instance.new("TextLabel")
        line.LayoutOrder = order
        line.Size = UDim2.new(1, 0, 0, 25)
        line.BackgroundTransparency = 1
        line.Text = text
        line.TextColor3 = color or Color3.fromRGB(230, 230, 230)
        line.Font = Enum.Font.GothamBold
        line.TextSize = size or 16
        line.TextXAlignment = Enum.TextXAlignment.Center
        line.Parent = panel
        return line
    end
    label("SATISHUB  |  FARMING STATS", 1, 19, Color3.fromRGB(100, 220, 165))
    local uptime = label("Farming time: 00:00:00", 2)
    local games = label("Games: 0   |   Wins: 0   |   Losses: 0", 3)
    local rewards = label("Gold: 0   |   Gems: 0", 4)
    local experience = label("XP: 0", 5)
    label("FPS Boost active - 3D rendering disabled", 6, 11, Color3.fromRGB(165, 165, 180))
    label("Use your minimize key to open SatisHub", 7, 11, Color3.fromRGB(165, 165, 180))

    local function elapsed()
        return math.max(0, math.floor(os.clock() - started))
    end
    local function display()
        local secs = stats.seconds + elapsed()
        uptime.Text = ("Farming time: %02d:%02d:%02d"):format(math.floor(secs/3600), math.floor(secs/60)%60, secs%60)
        games.Text = ("Games: %d   |   Wins: %d   |   Losses: %d"):format(stats.games, stats.wins, stats.losses)
        rewards.Text = ("Gold: %d   |   Gems: %d"):format(stats.gold, stats.gems)
        experience.Text = ("XP: %d"):format(stats.xp)
    end
    local folder = endpoints and endpoints:FindFirstChild("server_to_client")
    local finishedEvent = folder and folder:FindFirstChild("game_finished")
    if finishedEvent and finishedEvent:IsA("RemoteEvent") then
        finishedEvent.OnClientEvent:Connect(function(data)
            if not alive() or finished then return end
            if type(data) ~= "table" then return end
            finished = true
            stats.games = stats.games + 1
            if data.victory == true then stats.wins = stats.wins + 1 else stats.losses = stats.losses + 1 end
            stats.gold = stats.gold + (tonumber(data.gold_reward) or 0)
            stats.gems = stats.gems + (tonumber(data.gem_reward) or 0)
            stats.xp = stats.xp + (tonumber(data.xp_reward) or 0)
            -- Commit elapsed time once, so teleport auto-exec doesn't reset the timer.
            stats.seconds = stats.seconds + elapsed()
            started = os.clock()
            saveSettings()
            display()
        end)
    end
    task.spawn(function()
        while alive() do
            display()
            if os.clock() - lastFlush >= 30 then
                stats.seconds = stats.seconds + elapsed()
                started = os.clock()
                lastFlush = os.clock()
                saveSettings()
            end
            task.wait(1)
        end
    end)

    local lighting = game:GetService("Lighting")
    local oldGraphics = {}
    local applied = false
    local function setLowGraphics(enabled)
        if enabled == applied then return end
        applied = enabled
        if enabled then
            -- Snapshot only values we modify, so OFF restores original graphics.
            local ok, shadows = pcall(function() return lighting.GlobalShadows end)
            if ok then
                oldGraphics.shadows = shadows
                pcall(function() lighting.GlobalShadows = false end)
            end
            oldGraphics.effects = {}
            for _, inst in ipairs(lighting:GetChildren()) do
                if inst:IsA("PostEffect") then
                    local ok2, value = pcall(function() return inst.Enabled end)
                    if ok2 then
                        table.insert(oldGraphics.effects, {instance = inst, enabled = value})
                        pcall(function() inst.Enabled = false end)
                    end
                end
            end
        else
            if oldGraphics.shadows ~= nil then
                pcall(function() lighting.GlobalShadows = oldGraphics.shadows end)
            end
            for _, item in ipairs(oldGraphics.effects or {}) do
                if item.instance and item.instance.Parent then
                    pcall(function() item.instance.Enabled = item.enabled end)
                end
            end
            oldGraphics = {}
        end
    end
    return function(enabled)
        statsGui.Enabled = enabled
        setLowGraphics(enabled)
        black.Visible = enabled
        local ok, err = pcall(function()
            RunService:Set3dRenderingEnabled(not enabled)
        end)
        if not ok then warn("[SatisHub] FPS Boost: " .. tostring(err)) end
        if enabled then display() end
    end
end
local setFpsBoost = initFarmingDashboard()

-- Main GUI container
local gui = Instance.new("ScreenGui")
gui.Name = "SatisHub"
gui.ResetOnSpawn = false
gui.DisplayOrder = 10 -- above the black overlay
gui.Parent = parent

-- ===== Helpers (corners + animated RGB borders) =====
local function corner(inst, r)
	Instance.new("UICorner", inst).CornerRadius = UDim.new(0, r or 6)
end

local rgbGradients = {} -- every RGB border registers here and is rotated by one loop

local function addRgbStroke(inst, thickness)
	local stroke = Instance.new("UIStroke")
	stroke.Color = WHITE
	stroke.Thickness = thickness or 2
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = inst
	local grad = Instance.new("UIGradient")
	grad.Color = RAINBOW
	grad.Parent = stroke
	rgbGradients[#rgbGradients + 1] = grad
	grad.Enabled = state.rgbEnabled
	return stroke, grad
end

task.spawn(function()
	local rot = 0
	while alive() do
		local dt = RunService.RenderStepped:Wait()
		rot = (rot + dt * 90) % 360
		for i = #rgbGradients, 1, -1 do
			local g = rgbGradients[i]
			if g.Parent then
				if state.rgbEnabled then
				g.Rotation = rot
			end
			else
				table.remove(rgbGradients, i)
			end
		end
	end
end)

-- ===== STARTUP NOTICE =====
-- The user has to click "Understood" before the script goes on.
-- (Skipped when the script was started automatically after a teleport: that proves auto execute works.)
if not fromQueue then
	local acknowledged = false

	local nCard = Instance.new("Frame")
	nCard.Size = UDim2.fromOffset(330, 0)
	nCard.AutomaticSize = Enum.AutomaticSize.Y
	nCard.AnchorPoint = Vector2.new(0.5, 0.5)
	nCard.Position = UDim2.fromScale(0.5, 0.5)
	nCard.BackgroundColor3 = currentTheme
	nCard.BorderSizePixel = 0
	nCard.Parent = gui
	corner(nCard, 14)
	addRgbStroke(nCard, 3)

	local nLayout = Instance.new("UIListLayout")
	nLayout.Padding = UDim.new(0, 10)
	nLayout.SortOrder = Enum.SortOrder.LayoutOrder
	nLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	nLayout.Parent = nCard

	local nPad = Instance.new("UIPadding")
	nPad.PaddingTop = UDim.new(0, 16)
	nPad.PaddingBottom = UDim.new(0, 16)
	nPad.PaddingLeft = UDim.new(0, 16)
	nPad.PaddingRight = UDim.new(0, 16)
	nPad.Parent = nCard

	local function nText(text, order, size, color, bold)
		local l = Instance.new("TextLabel")
		l.Size = UDim2.new(1, 0, 0, 0)
		l.AutomaticSize = Enum.AutomaticSize.Y
		l.BackgroundTransparency = 1
		l.Text = text
		l.TextWrapped = true
		l.TextColor3 = color
		l.Font = bold and Enum.Font.GothamBold or Enum.Font.Gotham
		l.TextSize = size
		l.TextXAlignment = Enum.TextXAlignment.Center
		l.LayoutOrder = order
		l.Parent = nCard
		return l
	end

	nText("SatisHub - Early Version", 1, 20, WHITE, true)
	nText(
		"SatisHub is a new script developed and maintained by just one person.",
		2,
		14,
		Color3.fromRGB(230, 230, 230),
		false
	)
	nText(
		"Some features may have bugs, unexpected behavior, or compatibility issues. Thank you for your patience while the script is improved!",
		3,
		12,
		Color3.fromRGB(175, 175, 185),
		false
	)

	local nBtn = Instance.new("TextButton")
	nBtn.Size = UDim2.new(1, 0, 0, 36)
	nBtn.BackgroundColor3 = currentTheme:Lerp(WHITE, 0.14)
	nBtn.Text = "Continue"
	nBtn.TextColor3 = WHITE
	nBtn.Font = Enum.Font.GothamBold
	nBtn.TextSize = 14
	nBtn.BorderSizePixel = 0
	nBtn.AutoButtonColor = false
	nBtn.LayoutOrder = 5
	nBtn.Parent = nCard
	corner(nBtn, 8)
	addRgbStroke(nBtn, 1.5)
	nBtn.MouseButton1Click:Connect(function()
		acknowledged = true
	end)

	repeat
		task.wait(0.1)
	until acknowledged or not alive()

	nCard:Destroy()
	if not alive() then
		return
	end
end

local frame = Instance.new("Frame")
frame.Size = UDim2.fromOffset(320, 0)
frame.AutomaticSize = Enum.AutomaticSize.Y
frame.Position = UDim2.new(0, 20, 0.5, -120)
frame.BackgroundColor3 = currentTheme
frame.BorderSizePixel = 0
frame.ClipsDescendants = true
frame.Visible = false -- shown after the loading screen
frame.Parent = gui
corner(frame, 16)
-- V3.1: static layered dark gradient (zero per-frame cost).
do
    local panelGradient = Instance.new("UIGradient")
    panelGradient.Name = "SatisV31PanelGradient"
    panelGradient.Rotation = 90
    panelGradient.Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0, Color3.fromRGB(17, 27, 47)),
        ColorSequenceKeypoint.new(1, Color3.fromRGB(8, 12, 22))
    })
    panelGradient.Parent = frame
end
addRgbStroke(frame, 2)
do
    local st = Instance.new("UIStroke")
    st.Color = Color3.fromRGB(45, 62, 91)
    st.Thickness = 1
    st.Parent = frame
end

local frameLayout = Instance.new("UIListLayout")
frameLayout.SortOrder = Enum.SortOrder.LayoutOrder
frameLayout.Parent = frame

-- Theme handling
local fields = {} -- text boxes that follow the theme (slightly lighter, can be transparent)
local plainButtons = {} -- buttons that follow the theme (always solid)
local toggleRefreshers = {} -- repaint functions of the toggles
local header
local userBar
local gameWindow
local gameHeader
local refreshTabs

local function btnColor()
	return currentTheme:Lerp(Color3.fromRGB(74, 96, 139), 0.27)
end

local function applyTheme(c)
	currentTheme = c
	frame.BackgroundColor3 = c
	if header then
		header.BackgroundColor3 = c:Lerp(Color3.new(0, 0, 0), 0.3)
	end
	if userBar then
		userBar.BackgroundColor3 = c:Lerp(Color3.new(0, 0, 0), 0.3)
	end
	if gameWindow then
		gameWindow.BackgroundColor3 = c
	end
	if gameHeader then
		gameHeader.BackgroundColor3 = c:Lerp(Color3.new(0, 0, 0), 0.3)
	end
	for _, o in ipairs(fields) do
		o.BackgroundColor3 = c:Lerp(WHITE, 0.12)
	end
	for _, b in ipairs(plainButtons) do
		b.BackgroundColor3 = btnColor()
	end
	for _, fn in ipairs(toggleRefreshers) do
		fn()
	end
	if refreshTabs then
		refreshTabs()
	end
end

-- Transparent background option (buttons stay solid so they remain easy to read)
local function refreshTransparency()
	local t = state.transparent
	frame.BackgroundTransparency = t and 0.6 or 0
	if header then
		header.BackgroundTransparency = t and 0.5 or 0
	end
	if userBar then
		userBar.BackgroundTransparency = t and 0.5 or 0
	end
	for _, o in ipairs(fields) do
		o.BackgroundTransparency = t and 0.4 or 0
	end
end

local function makePage(parentObj, order)
	local p = Instance.new("Frame")
	p.Size = UDim2.new(1, 0, 0, 0)
	p.AutomaticSize = Enum.AutomaticSize.Y
	p.BackgroundTransparency = 1
	p.LayoutOrder = order or 0
	p.Parent = parentObj
	local l = Instance.new("UIListLayout")
	l.Padding = UDim.new(0, 6)
	l.SortOrder = Enum.SortOrder.LayoutOrder
	l.HorizontalAlignment = Enum.HorizontalAlignment.Center
	l.Parent = p
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 8)
	pad.PaddingBottom = UDim.new(0, 10)
	pad.Parent = p
	return p
end

-- Flat button with a thin border. rgb = true gives it an RGB border (used by toggles when ON).
local function makeButton(parentObj, text, order, rgb)
	local b = Instance.new("TextButton")
	b.Size = UDim2.new(1, -24, 0, 36)
	b.BackgroundColor3 = btnColor()
	b.Text = text
	b.TextColor3 = WHITE
	b.Font = Enum.Font.GothamBold
	b.TextSize = 12
	b.BorderSizePixel = 0
	b.AutoButtonColor = false
	b.LayoutOrder = order or 0
	b.Parent = parentObj
	corner(b, 10)

	local stroke, grad
	if rgb then
		stroke, grad = addRgbStroke(b, 1.5)
		grad.Enabled = false
		stroke.Color = OFF_STROKE
	else
		stroke = Instance.new("UIStroke")
		stroke.Color = OFF_STROKE
		stroke.Thickness = 1.5
		stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		stroke.Parent = b
		plainButtons[#plainButtons + 1] = b
	end

    -- V3.1: smooth spring-like hover and press feedback; no permanent loops.
    local sc = Instance.new("UIScale")
    sc.Name = "SatisV31ButtonScale"
    sc.Parent = b
    local activeTween
    local hovering = false
    local pressing = false
    local function animateButton()
        if activeTween then activeTween:Cancel() end
        local target = pressing and 0.955 or (hovering and 1.018 or 1)
        activeTween = TweenService:Create(sc,
            TweenInfo.new(0.19, Enum.EasingStyle.Quart, Enum.EasingDirection.Out),
            {Scale = target})
        activeTween:Play()
    end
    b.MouseEnter:Connect(function() hovering = true; animateButton() end)
    b.MouseLeave:Connect(function() hovering = false; pressing = false; animateButton() end)
    b.MouseButton1Down:Connect(function() pressing = true; animateButton() end)
    b.MouseButton1Up:Connect(function() pressing = false; animateButton() end)
    -- Narrow highlight on hover, without changing functional ON/OFF colors.
    local hoverStroke = Instance.new("UIStroke")
    hoverStroke.Name = "SatisV31HoverStroke"
    hoverStroke.Color = Color3.fromRGB(113, 175, 255)
    hoverStroke.Thickness = 1
    hoverStroke.Transparency = 1
    hoverStroke.Parent = b
    b.MouseEnter:Connect(function()
        TweenService:Create(hoverStroke, TweenInfo.new(0.22), {Transparency = 0.42}):Play()
    end)
    b.MouseLeave:Connect(function()
        TweenService:Create(hoverStroke, TweenInfo.new(0.22), {Transparency = 1}):Play()
    end)
	return b, stroke, grad
end

-- Returns the button and a setter (set(true/false)) so toggles can control each other.
-- "initial" restores the saved value; every change is saved to file.
local function makeToggle(parentObj, name, order, onChange, initial)
	local on = false
	local b, stroke, grad = makeButton(parentObj, name .. ": OFF", order, true)

	local function paint()
		b.Text = name .. (on and ": ON" or ": OFF")
		if name == "Auto Join Event" then
			b.BackgroundColor3 = on and Color3.fromRGB(255, 140, 25) or Color3.fromRGB(135, 72, 16)
		else
			b.BackgroundColor3 = on and ON_COLOR or btnColor()
		end
		stroke.Color = on and WHITE or OFF_STROKE
		grad.Enabled = on and state.rgbEnabled
	end
	toggleRefreshers[#toggleRefreshers + 1] = paint

	local function set(v)
		on = v
		paint()
		onChange(on)
		saveSettings()
	end
	b.MouseButton1Click:Connect(function()
		set(not on)
	end)
	if initial then
		set(true)
	end
	return b, set
end

local function makeLabel(parentObj, text, order)
	local l = Instance.new("TextLabel")
	l.Size = UDim2.new(1, -20, 0, 18)
	l.BackgroundTransparency = 1
	l.Text = text
	l.TextColor3 = Color3.fromRGB(200, 200, 200)
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.Font = Enum.Font.Gotham
	l.TextSize = 12
	l.LayoutOrder = order or 0
	l.Parent = parentObj
	return l
end

local function makeTextBox(parentObj, placeholder, text)
	local t = Instance.new("TextBox")
	t.BackgroundColor3 = currentTheme:Lerp(WHITE, 0.12)
	t.PlaceholderText = placeholder or ""
	t.Text = text or ""
	t.TextColor3 = WHITE
	t.PlaceholderColor3 = Color3.fromRGB(150, 150, 150)
	t.Font = Enum.Font.GothamBold
	t.TextSize = 13
	t.BorderSizePixel = 0
	t.ClearTextOnFocus = false
	t.Parent = parentObj
	corner(t, 8)
	local st = Instance.new("UIStroke")
	st.Color = OFF_STROKE
	st.Thickness = 1.5
	st.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	st.Parent = t
	table.insert(fields, t)
	return t
end

-- Dragging (works for mouse and touch). onTap runs if the user clicked without moving.
local function makeDraggable(handle, target, onTap)
	local dragging, moved, startMouse, startPos
	handle.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			moved = false
			startMouse = input.Position
			startPos = target.Position
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			local d = input.Position - startMouse
			if d.Magnitude > 5 then
				moved = true
			end
			target.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch) then
			dragging = false
			if not moved and onTap then
				onTap()
			end
		end
	end)
end

-- Header (title + minimize)
header = Instance.new("Frame")
header.Size = UDim2.new(1, 0, 0, 54)
header.BackgroundColor3 = currentTheme:Lerp(Color3.new(0, 0, 0), 0.3)
header.BorderSizePixel = 0
header.LayoutOrder = 1
header.Parent = frame

local titulo = Instance.new("TextLabel")
titulo.Size = UDim2.new(1, -48, 0, 27)
titulo.Position = UDim2.new(0, 12, 0, 5)
titulo.BackgroundTransparency = 1
titulo.Text = "⚡ SatisHub V3.2"
titulo.TextColor3 = WHITE
titulo.TextXAlignment = Enum.TextXAlignment.Left
titulo.Font = Enum.Font.GothamBold
titulo.TextSize = 19
titulo.Parent = header
do
    local sub = Instance.new("TextLabel")
    sub.Size = UDim2.new(1,-48,0,15)
    sub.Position = UDim2.new(0,14,0,31)
    sub.Text = "ULTIMATE AUTOMATION HUB"
    sub.TextSize = 9
    sub.Font = Enum.Font.GothamMedium
    sub.TextXAlignment = Enum.TextXAlignment.Left
    sub.BackgroundTransparency = 1
    sub.TextColor3 = Color3.fromRGB(132,153,188)
    sub.Parent = header
end

-- RGB title
local titleGrad = Instance.new("UIGradient")
titleGrad.Color = RAINBOW
titleGrad.Parent = titulo
rgbGradients[#rgbGradients + 1] = titleGrad
titleGrad.Enabled = state.rgbEnabled

local minBtn = Instance.new("TextButton")
minBtn.Size = UDim2.fromOffset(24, 24)
minBtn.Position = UDim2.new(1, -34, 0, 15)
minBtn.BackgroundColor3 = btnColor()
minBtn.Text = "–"
minBtn.TextColor3 = WHITE
minBtn.Font = Enum.Font.GothamBold
minBtn.TextSize = 16
minBtn.BorderSizePixel = 0
minBtn.AutoButtonColor = false
minBtn.Parent = header
corner(minBtn, 6)
plainButtons[#plainButtons + 1] = minBtn
do
	local st = Instance.new("UIStroke")
	st.Color = OFF_STROKE
	st.Thickness = 1.5
	st.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	st.Parent = minBtn
end

makeDraggable(header, frame)

-- Minimized icon (shows the photo)
local miniIcon = Instance.new("ImageButton")
miniIcon.Size = UDim2.fromOffset(56, 56)
miniIcon.BackgroundColor3 = Color3.fromRGB(10, 10, 10)
miniIcon.BorderSizePixel = 0
miniIcon.AutoButtonColor = false
miniIcon.ScaleType = Enum.ScaleType.Crop
miniIcon.Visible = false
miniIcon.Parent = gui
corner(miniIcon, 14)
addRgbStroke(miniIcon, 3)

local miniFallback = Instance.new("TextLabel")
miniFallback.Size = UDim2.fromScale(1, 1)
miniFallback.BackgroundTransparency = 1
miniFallback.Text = "S"
miniFallback.TextColor3 = WHITE
miniFallback.Font = Enum.Font.GothamBold
miniFallback.TextSize = 26
miniFallback.Parent = miniIcon

local iconAsset = loadIcon()
if iconAsset then
	miniIcon.Image = iconAsset
	miniFallback.Visible = false
end

-- V3.1: animated open/close. Guard against repeated hotkey presses.
local menuScale = Instance.new("UIScale")
menuScale.Name = "SatisV31MenuScale"
menuScale.Parent = frame
local miniScale = Instance.new("UIScale")
miniScale.Name = "SatisV31MiniScale"
miniScale.Parent = miniIcon
local menuTransition = 0
local function setMinimized(min)
    menuTransition = menuTransition + 1
    local token = menuTransition
    if min then
        miniIcon.Position = frame.Position
        miniIcon.Visible = true
        miniScale.Scale = 0.65
        TweenService:Create(miniScale, TweenInfo.new(0.28, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {Scale = 1}):Play()
        if frame.Visible then
            local tw = TweenService:Create(menuScale, TweenInfo.new(0.17, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {Scale = 0.91})
            tw:Play()
            task.delay(0.18, function()
                if token == menuTransition and alive() then frame.Visible = false end
            end)
        else
            frame.Visible = false
        end
    else
        frame.Position = miniIcon.Position
        frame.Visible = true
        miniIcon.Visible = false
        menuScale.Scale = 0.87
        TweenService:Create(menuScale, TweenInfo.new(0.32, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {Scale = 1}):Play()
    end
end

minBtn.MouseButton1Click:Connect(function()
	setMinimized(true)
end)

makeDraggable(miniIcon, miniIcon, function()
	setMinimized(false)
end)

-- Body (everything below the header)
local body = Instance.new("Frame")
body.Size = UDim2.new(1, 0, 0, 0)
body.AutomaticSize = Enum.AutomaticSize.Y
body.BackgroundTransparency = 1
body.LayoutOrder = 2
body.Parent = frame

local bodyLayout = Instance.new("UIListLayout")
bodyLayout.SortOrder = Enum.SortOrder.LayoutOrder
bodyLayout.Parent = body

-- Footer: user who is running the script (name + avatar)
userBar = Instance.new("Frame")
userBar.Size = UDim2.new(1, 0, 0, 36)
userBar.BackgroundColor3 = currentTheme:Lerp(Color3.new(0, 0, 0), 0.3)
userBar.BorderSizePixel = 0
userBar.LayoutOrder = 3
userBar.Parent = frame

local avatar = Instance.new("ImageLabel")
avatar.Size = UDim2.fromOffset(26, 26)
avatar.Position = UDim2.new(0, 8, 0.5, -13)
avatar.BackgroundColor3 = Color3.fromRGB(40, 40, 50)
avatar.BorderSizePixel = 0
avatar.Parent = userBar
corner(avatar, 13)
addRgbStroke(avatar, 2)

local userLabel = Instance.new("TextLabel")
userLabel.Size = UDim2.new(1, -50, 1, 0)
userLabel.Position = UDim2.new(0, 42, 0, 0)
userLabel.BackgroundTransparency = 1
userLabel.Text = "User: " .. Players.LocalPlayer.Name
userLabel.TextColor3 = Color3.fromRGB(220, 220, 220)
userLabel.TextXAlignment = Enum.TextXAlignment.Left
userLabel.TextTruncate = Enum.TextTruncate.AtEnd
userLabel.Font = Enum.Font.GothamBold
userLabel.TextSize = 12
userLabel.Parent = userBar

-- Incognito hides account details from the SatisHub footer only.
local function refreshIncognito()
    avatar.Visible = not state.incognitoMode
    userLabel.Text = state.incognitoMode and "User: Hidden" or ("User: " .. Players.LocalPlayer.Name)
    userLabel.Position = state.incognitoMode and UDim2.new(0, 10, 0, 0) or UDim2.new(0, 42, 0, 0)
    userLabel.Size = state.incognitoMode and UDim2.new(1, -20, 1, 0) or UDim2.new(1, -50, 1, 0)
end
refreshIncognito()

task.spawn(function()
	local ok, img = pcall(function()
		return (Players:GetUserThumbnailAsync(
			Players.LocalPlayer.UserId,
			Enum.ThumbnailType.HeadShot,
			Enum.ThumbnailSize.Size100x100
		))
	end)
	if ok and img then
		avatar.Image = img
	end
end)

-- KEY page
local keyPage = makePage(body, 1)

local caixaKey = makeTextBox(keyPage, "Enter key", "")
caixaKey.Size = UDim2.new(1, -20, 0, 30)
caixaKey.LayoutOrder = 1

local botaoKey = makeButton(keyPage, "Verify", 2)

local msgKey = makeLabel(keyPage, "", 3)
msgKey.TextColor3 = ERROR_COLOR
msgKey.TextXAlignment = Enum.TextXAlignment.Center

-- Tabs row
local tabsRow = Instance.new("Frame")
tabsRow.Size = UDim2.new(1, 0, 0, 44)
tabsRow.BackgroundTransparency = 1
tabsRow.LayoutOrder = 2
tabsRow.Visible = false
tabsRow.Parent = body

local tabsPad = Instance.new("UIPadding")
tabsPad.PaddingLeft = UDim.new(0, 10)
tabsPad.PaddingRight = UDim.new(0, 10)
tabsPad.PaddingTop = UDim.new(0, 6)
tabsPad.Parent = tabsRow

local tabsLayout = Instance.new("UIListLayout")
tabsLayout.FillDirection = Enum.FillDirection.Horizontal
tabsLayout.Padding = UDim.new(0, 6)
tabsLayout.SortOrder = Enum.SortOrder.LayoutOrder
tabsLayout.Parent = tabsRow

local tabInfo = {} -- [key] = { btn, stroke, grad }
local activeTab = "main"

local function makeTab(text, order, key)
	local b = Instance.new("TextButton")
	b.Size = UDim2.new(0.20, -5, 1, -8)
	b.BackgroundColor3 = currentTheme:Lerp(WHITE, 0.08)
	b.Text = text
	b.TextColor3 = WHITE
	b.Font = Enum.Font.GothamBold
	b.TextSize = 10
	b.BorderSizePixel = 0
	b.AutoButtonColor = false
	b.LayoutOrder = order
	b.Parent = tabsRow
	corner(b, 8)
	local stroke, grad = addRgbStroke(b, 1.5)
	local underline = Instance.new("Frame")
    underline.Name = "SatisV31ActiveBar"
    underline.AnchorPoint = Vector2.new(0.5, 1)
    underline.Position = UDim2.new(0.5, 0, 1, -2)
    underline.Size = UDim2.new(0, 0, 0, 2)
    underline.BackgroundColor3 = Color3.fromRGB(100, 177, 255)
    underline.BorderSizePixel = 0
    underline.Parent = b
    corner(underline, 2)
    local tabScale = Instance.new("UIScale")
    tabScale.Parent = b
    b.MouseEnter:Connect(function()
        TweenService:Create(tabScale, TweenInfo.new(0.18, Enum.EasingStyle.Quart), {Scale=1.045}):Play()
    end)
    b.MouseLeave:Connect(function()
        TweenService:Create(tabScale, TweenInfo.new(0.18, Enum.EasingStyle.Quart), {Scale=1}):Play()
    end)
    tabInfo[key] = { btn = b, stroke = stroke, grad = grad, underline=underline }
	return b
end

local tabMain = makeTab("Main", 1, "main")
local tabEvent = makeTab("Evento", 2, "event")
local tabPlayer = makeTab("Player", 3, "player")
local tabSettings = makeTab("Settings", 4, "settings")
local tabAbout = makeTab("About", 5, "about")

refreshTabs = function()
	for key, info in pairs(tabInfo) do
		local active = (key == activeTab)
		TweenService:Create(info.btn, TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
            BackgroundColor3 = active and Color3.fromRGB(33, 55, 92) or Color3.fromRGB(22, 28, 42),
            TextColor3 = active and Color3.fromRGB(147, 194, 255) or Color3.fromRGB(155, 166, 186)
        }):Play()
        info.grad.Enabled = active and state.rgbEnabled
        info.stroke.Color = active and Color3.fromRGB(105, 159, 239) or OFF_STROKE
        TweenService:Create(info.underline, TweenInfo.new(0.26, Enum.EasingStyle.Quart, Enum.EasingDirection.Out), {
            Size = active and UDim2.new(0.66, 0, 0, 2) or UDim2.new(0, 0, 0, 2)
        }):Play()
	end
end

-- MAIN page
local mainPage = makePage(body, 3)
mainPage.Visible = false

-- Event page contains event joining and both card options.
local eventPage = makePage(body, 3)
eventPage.Visible = false

local setAutoCard, setRandomCard
local _

makeToggle(mainPage, "Auto Start", 1, function(v)
	state.autoStart = v
end, state.autoStart)

makeToggle(mainPage, "Auto Skip Wave", 2, function(v)
	state.autoSkip = v
end, state.autoSkip)

makeToggle(mainPage, "Auto Replay", 3, function(v)
	state.autoReplay = v
end, state.autoReplay)

-- Auto Leave sends the lobby vote after the actual end-of-match event.
makeToggle(mainPage, "Auto Leave (Lobby)", 3.5, function(v)
    state.autoLeave = v
end, state.autoLeave)

-- Daily Challenge matchmaking. Keep this on Main, separate from Event matchmaking.
-- When both toggles are ON, Daily Challenge takes priority to prevent overlapping teleports.
do
    makeToggle(mainPage, "Auto Join Daily Challenge", 3.6, function(v)
        state.autoJoinDailyChallenge = v
        -- If both modes are enabled, Daily Challenge takes priority.
    end, state.autoJoinDailyChallenge)
    -- Manual completion lock also covers runs finished before SatisHub was launched.
    local dailyLockButton = makeButton(mainPage, "Mark Daily Completed", 3.65)
    dailyLockButton.MouseButton1Click:Connect(function()
        dailyChallenge.markCompleted('manual')
        dailyLockButton.Text = "Daily Completed - Locked"
    end)
    local dailyStatus = makeLabel(mainPage, 'Daily reset: syncing with server...', 3.7)
    dailyStatus.TextWrapped = true
    dailyStatus.Size = UDim2.new(1, -20, 0, 26)
    task.spawn(function()
        while alive() do
            local rem = dailyChallenge.remaining()
            if rem then
                local h = math.floor(rem / 3600)
                local m = math.floor(rem / 60) % 60
                local sec = rem % 60
                dailyStatus.Text = ('Daily reset: %02d:%02d:%02d | %s'):format(
                    h, m, sec, dailyChallenge.completed() and 'COMPLETED' or 'AVAILABLE')
            else
                dailyStatus.Text = dailyChallenge.completed() and 'Daily: COMPLETED | timer awaiting server' or 'Daily reset: waiting for server countdown...'
            end
            dailyLockButton.Text = dailyChallenge.completed() and 'Daily Completed - Locked' or 'Mark Daily Completed'
            task.wait(1)
        end
    end)
end

-- Auto Select Card and Random Card are mutually exclusive:
-- turning one on turns the other one off.

_, setAutoCard = makeToggle(eventPage, "Auto Select Card", 4, function(v)
	state.autoCard = v
	if v and state.randomCard and setRandomCard then
		setRandomCard(false)
	end
end, state.autoCard)

_, setRandomCard = makeToggle(eventPage, "Random Card (1-3)", 5, function(v)
	state.randomCard = v
	if v and state.autoCard and setAutoCard then
		setAutoCard(false)
	end
end, state.randomCard)

local optRow = Instance.new("Frame")
optRow.Size = UDim2.new(1, -20, 0, 26)
optRow.BackgroundTransparency = 1
optRow.LayoutOrder = 6
optRow.Parent = eventPage

local optLabel = makeLabel(optRow, "Card option:", 0)
optLabel.Size = UDim2.new(0.6, 0, 1, 0)

local caixaOpcao = makeTextBox(optRow, "2", state.cardOption)
caixaOpcao.Size = UDim2.new(0, 60, 1, 0)
caixaOpcao.Position = UDim2.new(1, -60, 0, 0)

caixaOpcao.FocusLost:Connect(function()
	local t = caixaOpcao.Text:gsub("%s+", "")
	if t == "" then
		t = "2"
	end
	state.cardOption = t
	caixaOpcao.Text = t
	saveSettings()
end)

makeToggle(eventPage, "Auto Join Event", 1, function(v)
    state.autoJoinEvent = v
    -- Daily Challenge has priority if both matchmaking toggles are enabled.
end, state.autoJoinEvent)

makeToggle(mainPage, "Random Place Units", 9, function(v)
	state.randomPlace = v
end, state.randomPlace)

local radiusRow = Instance.new("Frame")
radiusRow.Size = UDim2.new(1, -20, 0, 26)
radiusRow.BackgroundTransparency = 1
radiusRow.LayoutOrder = 10
radiusRow.Parent = mainPage

local radiusLabel = makeLabel(radiusRow, "Place radius (studs):", 0)
radiusLabel.Size = UDim2.new(0.6, 0, 1, 0)

local caixaRadius = makeTextBox(radiusRow, "15", state.placeRadius)
caixaRadius.Size = UDim2.new(0, 60, 1, 0)
caixaRadius.Position = UDim2.new(1, -60, 0, 0)

caixaRadius.FocusLost:Connect(function()
	local n = tonumber(caixaRadius.Text)
	if not n or n < 0 then
		n = 15
	end
	state.placeRadius = tostring(n)
	caixaRadius.Text = state.placeRadius
	saveSettings()
end)

local placeStatus = makeLabel(mainPage, "Auto Place: scanning unit IDs...", 12)
placeStatus.TextSize = 11
placeStatus.TextWrapped = true
placeStatus.Size = UDim2.new(1, -20, 0, 34)

makeToggle(mainPage, "Auto Upgrade Units", 14, function(v)
	state.autoUpgrade = v
end, state.autoUpgrade)

-- PLAYER page (ESP + Noclip + mini games)
local setEsp, setNoclip

do
	local LocalPlayer = Players.LocalPlayer
	local ESP_COLOR = Color3.fromRGB(255, 70, 70)

	local espFolder = Instance.new("Folder")
	espFolder.Name = "SatisHubESP"
	espFolder.Parent = parent

	local espEnabled = false
	local espObjects = {} -- [player] = { highlight, billboard, label }

	local function removeEsp(plr)
		local o = espObjects[plr]
		if o then
			pcall(function()
				o.highlight:Destroy()
				o.billboard:Destroy()
			end)
			espObjects[plr] = nil
		end
	end

	local function applyEsp(plr)
		if not espEnabled or plr == LocalPlayer then
			return
		end
		local char = plr.Character
		if not char then
			return
		end
		local root = char:FindFirstChild("HumanoidRootPart") or char:WaitForChild("HumanoidRootPart", 5)
		if not root or not espEnabled then
			return
		end
		removeEsp(plr)

		local hl = Instance.new("Highlight")
		hl.Name = "SatisESP"
		hl.Adornee = char
		hl.FillColor = ESP_COLOR
		hl.FillTransparency = 0.6
		hl.OutlineColor = Color3.new(1, 1, 1)
		hl.OutlineTransparency = 0
		hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
		hl.Parent = espFolder

		local bb = Instance.new("BillboardGui")
		bb.Name = "SatisESPLabel"
		bb.Adornee = root
		bb.AlwaysOnTop = true
		bb.Size = UDim2.fromOffset(140, 20)
		bb.StudsOffset = Vector3.new(0, 3.5, 0)
		bb.Parent = espFolder

		local lbl = Instance.new("TextLabel")
		lbl.Size = UDim2.fromScale(1, 1)
		lbl.BackgroundTransparency = 1
		lbl.Text = plr.Name
		lbl.TextColor3 = Color3.new(1, 1, 1)
		lbl.TextStrokeTransparency = 0.3
		lbl.Font = Enum.Font.GothamBold
		lbl.TextSize = 13
		lbl.Parent = bb

		espObjects[plr] = { highlight = hl, billboard = bb, label = lbl }
	end

	local function trackPlayer(plr)
		if plr == LocalPlayer then
			return
		end
		plr.CharacterAdded:Connect(function()
			task.spawn(applyEsp, plr)
		end)
	end

	for _, plr in ipairs(Players:GetPlayers()) do
		trackPlayer(plr)
	end
	Players.PlayerAdded:Connect(trackPlayer)
	Players.PlayerRemoving:Connect(removeEsp)

	setEsp = function(v)
		espEnabled = v
		if v then
			for _, plr in ipairs(Players:GetPlayers()) do
				task.spawn(applyEsp, plr)
			end
		else
			for plr in pairs(espObjects) do
				removeEsp(plr)
			end
		end
	end

	-- Keeps the distance shown on each name up to date
	task.spawn(function()
		while alive() do
			task.wait(0.25)
			if espEnabled then
				local myChar = LocalPlayer.Character
				local myRoot = myChar and myChar:FindFirstChild("HumanoidRootPart")
				for plr, o in pairs(espObjects) do
					local char = plr.Character
					local root = char and char:FindFirstChild("HumanoidRootPart")
					if myRoot and root then
						o.label.Text = plr.Name .. " [" .. math.floor((root.Position - myRoot.Position).Magnitude) .. "m]"
					end
				end
			end
		end
	end)

	-- Noclip: turns collisions off on your character while enabled
	local noclipConn = nil
	local noclipParts = {}

	setNoclip = function(v)
		if v then
			if noclipConn then
				return
			end
			noclipConn = RunService.Stepped:Connect(function()
				local char = LocalPlayer.Character
				if not char then
					return
				end
				for _, part in ipairs(char:GetDescendants()) do
					if part:IsA("BasePart") and part.CanCollide then
						noclipParts[part] = true
						part.CanCollide = false
					end
				end
			end)
		else
			if noclipConn then
				noclipConn:Disconnect()
				noclipConn = nil
			end
			for part in pairs(noclipParts) do
				if part.Parent then
					part.CanCollide = true
				end
			end
			noclipParts = {}
		end
	end
end

local playerPage = makePage(body, 5)
playerPage.Visible = false

makeToggle(playerPage, "ESP", 1, function(v)
	setEsp(v)
end)

makeToggle(playerPage, "Noclip", 2, function(v)
	setNoclip(v)
end)

-- ===== MINI GAMES (Player tab) =====
-- Small Lua games that run inside the hub GUI. They do not touch the game itself.
local gameTitle, gameContent, gameBackBtn, gameCloseBtn
local stopCurrentGame
local gameSession = 0

gameWindow = Instance.new("Frame")
gameWindow.Name = "SatisHubGames"
gameWindow.Size = UDim2.fromOffset(360, 430)
gameWindow.Position = UDim2.new(0.5, -180, 0.5, -215)
gameWindow.BackgroundColor3 = currentTheme
gameWindow.BorderSizePixel = 0
gameWindow.Visible = false
gameWindow.ZIndex = 30
gameWindow.Parent = gui
corner(gameWindow, 14)
addRgbStroke(gameWindow, 3)

gameHeader = Instance.new("Frame")
gameHeader.Size = UDim2.new(1, 0, 0, 36)
gameHeader.BackgroundColor3 = currentTheme:Lerp(Color3.new(0, 0, 0), 0.3)
gameHeader.BorderSizePixel = 0
gameHeader.ZIndex = 31
gameHeader.Parent = gameWindow

gameTitle = Instance.new("TextLabel")
gameTitle.Size = UDim2.new(1, -100, 1, 0)
gameTitle.Position = UDim2.fromOffset(12, 0)
gameTitle.BackgroundTransparency = 1
gameTitle.Text = "Mini Games"
gameTitle.TextColor3 = WHITE
gameTitle.TextXAlignment = Enum.TextXAlignment.Left
gameTitle.Font = Enum.Font.GothamBold
gameTitle.TextSize = 16
gameTitle.ZIndex = 32
gameTitle.Parent = gameHeader

gameBackBtn = Instance.new("TextButton")
gameBackBtn.Size = UDim2.fromOffset(28, 26)
gameBackBtn.Position = UDim2.new(1, -68, 0, 5)
gameBackBtn.BackgroundColor3 = btnColor()
gameBackBtn.Text = "←"
gameBackBtn.TextColor3 = WHITE
gameBackBtn.Font = Enum.Font.GothamBold
gameBackBtn.TextSize = 16
gameBackBtn.BorderSizePixel = 0
gameBackBtn.AutoButtonColor = false
gameBackBtn.Visible = false
gameBackBtn.ZIndex = 32
gameBackBtn.Parent = gameHeader
corner(gameBackBtn, 6)
plainButtons[#plainButtons + 1] = gameBackBtn

gameCloseBtn = Instance.new("TextButton")
gameCloseBtn.Size = UDim2.fromOffset(28, 26)
gameCloseBtn.Position = UDim2.new(1, -34, 0, 5)
gameCloseBtn.BackgroundColor3 = btnColor()
gameCloseBtn.Text = "X"
gameCloseBtn.TextColor3 = WHITE
gameCloseBtn.Font = Enum.Font.GothamBold
gameCloseBtn.TextSize = 14
gameCloseBtn.BorderSizePixel = 0
gameCloseBtn.AutoButtonColor = false
gameCloseBtn.ZIndex = 32
gameCloseBtn.Parent = gameHeader
corner(gameCloseBtn, 6)
plainButtons[#plainButtons + 1] = gameCloseBtn

for _, b in ipairs({ gameBackBtn, gameCloseBtn }) do
	local st = Instance.new("UIStroke")
	st.Color = OFF_STROKE
	st.Thickness = 1.5
	st.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	st.Parent = b
end

gameContent = Instance.new("Frame")
gameContent.Name = "Content"
gameContent.Position = UDim2.fromOffset(0, 36)
gameContent.Size = UDim2.new(1, 0, 1, -36)
gameContent.BackgroundTransparency = 1
gameContent.ClipsDescendants = true
gameContent.ZIndex = 31
gameContent.Parent = gameWindow

makeDraggable(gameHeader, gameWindow)

local function clearGameContent()
	if stopCurrentGame then
		local fn = stopCurrentGame
		stopCurrentGame = nil
		if env.SatisHubGameCleanup == fn then
			env.SatisHubGameCleanup = nil
		end
		pcall(fn)
	end
	for _, child in ipairs(gameContent:GetChildren()) do
		child:Destroy()
	end
end

local function setGameCleanup(fn)
	stopCurrentGame = fn
	env.SatisHubGameCleanup = fn
end

local function gameLabel(parentObj, text, size, position, textSize, color, bold)
	local l = Instance.new("TextLabel")
	l.Size = size
	l.Position = position
	l.BackgroundTransparency = 1
	l.Text = text
	l.TextColor3 = color or WHITE
	l.Font = bold and Enum.Font.GothamBold or Enum.Font.Gotham
	l.TextSize = textSize or 13
	l.TextWrapped = true
	l.ZIndex = 32
	l.Parent = parentObj
	return l
end

local function gameButton(parentObj, text, size, position, color)
	local b = Instance.new("TextButton")
	b.Size = size
	b.Position = position
	b.BackgroundColor3 = color or Color3.fromRGB(45, 48, 60)
	b.Text = text
	b.TextColor3 = WHITE
	b.Font = Enum.Font.GothamBold
	b.TextSize = 13
	b.BorderSizePixel = 0
	b.AutoButtonColor = false
	b.ZIndex = 32
	b.Parent = parentObj
	corner(b, 8)
	local st = Instance.new("UIStroke")
	st.Color = OFF_STROKE
	st.Thickness = 1.5
	st.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	st.Parent = b
	return b
end

local function showGameOver(parentObj, titleText, subtitleText, onRestart)
	local overlay = Instance.new("Frame")
	overlay.Size = UDim2.fromScale(1, 1)
	overlay.BackgroundColor3 = Color3.new(0, 0, 0)
	overlay.BackgroundTransparency = 0.35
	overlay.BorderSizePixel = 0
	overlay.ZIndex = 40
	overlay.Parent = parentObj
	corner(overlay, 8)

	local t = gameLabel(overlay, titleText, UDim2.new(1, -20, 0, 30), UDim2.new(0, 10, 0.5, -55), 22, WHITE, true)
	t.ZIndex = 41
	t.TextXAlignment = Enum.TextXAlignment.Center

	local s = gameLabel(overlay, subtitleText, UDim2.new(1, -20, 0, 24), UDim2.new(0, 10, 0.5, -20), 14, Color3.fromRGB(220, 220, 220), false)
	s.ZIndex = 41
	s.TextXAlignment = Enum.TextXAlignment.Center

	local b = gameButton(overlay, "Play Again", UDim2.fromOffset(130, 34), UDim2.new(0.5, -65, 0.5, 15))
	b.ZIndex = 41
	b.MouseButton1Click:Connect(onRestart)
	return overlay
end

local gameActionName = "SatisHubMiniGame"

local function bindGameKeys(keys)
	local cas = game:GetService("ContextActionService")
	pcall(function()
		cas:BindActionAtPriority(gameActionName, function()
			return Enum.ContextActionResult.Sink
		end, false, 3000, table.unpack(keys))
	end)
end

local function unbindGameKeys()
	local cas = game:GetService("ContextActionService")
	pcall(function()
		cas:UnbindAction(gameActionName)
	end)
end

local function keyDown(...)
	for _, key in ipairs({ ... }) do
		if UserInputService:IsKeyDown(key) then
			return true
		end
	end
	return false
end

-- ===== Snake =====
local function startSnake()
	clearGameContent()
	gameTitle.Text = "Snake"
	gameBackBtn.Visible = true
	local session = gameSession + 1
	gameSession = session

	local running = true
	local gridSize = 15
	local cellSize = 20

	local scoreLabel = gameLabel(gameContent, "Score: 0", UDim2.new(1, -20, 0, 24), UDim2.new(0, 10, 0, 8), 14, WHITE, true)
	scoreLabel.TextXAlignment = Enum.TextXAlignment.Center

	local grid = Instance.new("Frame")
	grid.Size = UDim2.fromOffset(gridSize * cellSize, gridSize * cellSize)
	grid.Position = UDim2.new(0.5, -(gridSize * cellSize) / 2, 0, 40)
	grid.BackgroundColor3 = Color3.fromRGB(16, 18, 24)
	grid.BorderSizePixel = 0
	grid.ClipsDescendants = true
	grid.ZIndex = 32
	grid.Parent = gameContent
	corner(grid, 8)

	local cells = {}
	for y = 1, gridSize do
		cells[y] = {}
		for x = 1, gridSize do
			local c = Instance.new("Frame")
			c.Size = UDim2.fromOffset(cellSize - 1, cellSize - 1)
			c.Position = UDim2.fromOffset((x - 1) * cellSize, (y - 1) * cellSize)
			c.BackgroundColor3 = Color3.fromRGB(24, 27, 36)
			c.BorderSizePixel = 0
			c.ZIndex = 33
			c.Parent = grid
			cells[y][x] = c
		end
	end

	local snake = { { x = 8, y = 8 }, { x = 7, y = 8 }, { x = 6, y = 8 } }
	local dir = { x = 1, y = 0 }
	local nextDir = { x = 1, y = 0 }
	local food = { x = 12, y = 8 }
	local score = 0

	local function render()
		for y = 1, gridSize do
			for x = 1, gridSize do
				cells[y][x].BackgroundColor3 = Color3.fromRGB(24, 27, 36)
			end
		end
		cells[food.y][food.x].BackgroundColor3 = Color3.fromRGB(255, 90, 90)
		for i, p in ipairs(snake) do
			if p.x >= 1 and p.x <= gridSize and p.y >= 1 and p.y <= gridSize then
				cells[p.y][p.x].BackgroundColor3 = (i == 1) and Color3.fromRGB(90, 255, 140) or Color3.fromRGB(40, 200, 100)
			end
		end
	end

	local function placeFood()
		local free = {}
		local occupied = {}
		for _, p in ipairs(snake) do
			occupied[p.y * 100 + p.x] = true
		end
		for y = 1, gridSize do
			for x = 1, gridSize do
				if not occupied[y * 100 + x] then
					free[#free + 1] = { x = x, y = y }
				end
			end
		end
		if #free > 0 then
			food = free[math.random(1, #free)]
		end
	end

	local function gameOver()
		running = false
		showGameOver(grid, "Game Over", "Score: " .. score, function()
			if gameSession == session then
				startSnake()
			end
		end)
	end

	local function step()
		if not running then
			return
		end
		dir = nextDir
		local head = { x = snake[1].x + dir.x, y = snake[1].y + dir.y }
		if head.x < 1 or head.x > gridSize or head.y < 1 or head.y > gridSize then
			gameOver()
			return
		end
		local eating = (head.x == food.x and head.y == food.y)
		local limit = eating and #snake or (#snake - 1)
		for i = 1, limit do
			if snake[i].x == head.x and snake[i].y == head.y then
				gameOver()
				return
			end
		end
		table.insert(snake, 1, head)
		if eating then
			score = score + 1
			scoreLabel.Text = "Score: " .. score
			placeFood()
		else
			table.remove(snake)
		end
		render()
	end

	render()

	local inputConn = UserInputService.InputBegan:Connect(function(input)
		local focused = UserInputService:GetFocusedTextBox()
		if focused and focused.Parent and focused.Parent.Visible then
			return
		end
		local key = input.KeyCode
		local newDir
		if key == Enum.KeyCode.W or key == Enum.KeyCode.Up then
			newDir = { x = 0, y = -1 }
		elseif key == Enum.KeyCode.S or key == Enum.KeyCode.Down then
			newDir = { x = 0, y = 1 }
		elseif key == Enum.KeyCode.A or key == Enum.KeyCode.Left then
			newDir = { x = -1, y = 0 }
		elseif key == Enum.KeyCode.D or key == Enum.KeyCode.Right then
			newDir = { x = 1, y = 0 }
		end
		if newDir and not (newDir.x == -dir.x and newDir.y == -dir.y) then
			nextDir = newDir
		end
	end)

	-- On-screen arrows (mobile)
	local pad = Instance.new("Frame")
	pad.Size = UDim2.fromOffset(180, 32)
	pad.Position = UDim2.new(0.5, -90, 1, -42)
	pad.BackgroundTransparency = 1
	pad.ZIndex = 32
	pad.Parent = gameContent
	local padLayout = Instance.new("UIListLayout")
	padLayout.FillDirection = Enum.FillDirection.Horizontal
	padLayout.Padding = UDim.new(0, 6)
	padLayout.SortOrder = Enum.SortOrder.LayoutOrder
	padLayout.Parent = pad
	local arrows = {
		{ "←", -1, 0 },
		{ "↑", 0, -1 },
		{ "↓", 0, 1 },
		{ "→", 1, 0 },
	}
	for i, a in ipairs(arrows) do
		local b = gameButton(pad, a[1], UDim2.fromOffset(40, 32), UDim2.fromOffset(0, 0))
		b.TextSize = 18
		b.LayoutOrder = i
		b.MouseButton1Click:Connect(function()
			local newDir = { x = a[2], y = a[3] }
			if not (newDir.x == -dir.x and newDir.y == -dir.y) then
				nextDir = newDir
			end
		end)
	end

	bindGameKeys({ Enum.KeyCode.W, Enum.KeyCode.A, Enum.KeyCode.S, Enum.KeyCode.D, Enum.KeyCode.Up, Enum.KeyCode.Down, Enum.KeyCode.Left, Enum.KeyCode.Right })

	task.spawn(function()
		while running and gameSession == session do
			task.wait(0.16)
			step()
		end
	end)

	setGameCleanup(function()
		running = false
		inputConn:Disconnect()
		unbindGameKeys()
	end)
end

-- ===== Pong =====
local function startPong()
	clearGameContent()
	gameTitle.Text = "Pong"
	gameBackBtn.Visible = true
	local session = gameSession + 1
	gameSession = session

	local running = true
	local W, H = 320, 220

	local scoreLabel = gameLabel(gameContent, "You 0  x  0 CPU", UDim2.new(1, -20, 0, 24), UDim2.new(0, 10, 0, 8), 14, WHITE, true)
	scoreLabel.TextXAlignment = Enum.TextXAlignment.Center

	local canvas = Instance.new("Frame")
	canvas.Size = UDim2.fromOffset(W, H)
	canvas.Position = UDim2.new(0.5, -W / 2, 0, 42)
	canvas.BackgroundColor3 = Color3.fromRGB(16, 18, 24)
	canvas.BorderSizePixel = 0
	canvas.ClipsDescendants = true
	canvas.ZIndex = 32
	canvas.Parent = gameContent
	corner(canvas, 8)

	local paddleW, paddleH = 8, 48
	local playerPaddle = Instance.new("Frame")
	playerPaddle.Size = UDim2.fromOffset(paddleW, paddleH)
	playerPaddle.BackgroundColor3 = Color3.fromRGB(90, 255, 140)
	playerPaddle.BorderSizePixel = 0
	playerPaddle.ZIndex = 33
	playerPaddle.Parent = canvas
	corner(playerPaddle, 3)

	local aiPaddle = Instance.new("Frame")
	aiPaddle.Size = UDim2.fromOffset(paddleW, paddleH)
	aiPaddle.BackgroundColor3 = Color3.fromRGB(255, 120, 120)
	aiPaddle.BorderSizePixel = 0
	aiPaddle.ZIndex = 33
	aiPaddle.Parent = canvas
	corner(aiPaddle, 3)

	local ball = Instance.new("Frame")
	ball.Size = UDim2.fromOffset(10, 10)
	ball.BackgroundColor3 = WHITE
	ball.BorderSizePixel = 0
	ball.ZIndex = 33
	ball.Parent = canvas
	corner(ball, 5)

	local playerY = H / 2 - paddleH / 2
	local aiY = playerY
	local targetPlayerY = playerY
	local ballPos = Vector2.new(W / 2 - 5, H / 2 - 5)
	local ballVel = Vector2.new(150, 100)
	local playerScore, aiScore = 0, 0

	local function resetBall(direction)
		ballPos = Vector2.new(W / 2 - 5, H / 2 - 5)
		ballVel = Vector2.new(160 * direction, math.random(-80, 80))
		if math.abs(ballVel.Y) < 40 then
			ballVel = Vector2.new(ballVel.X, 60)
		end
	end

	local function updateScore()
		scoreLabel.Text = ("You %d  x  %d CPU"):format(playerScore, aiScore)
	end

	local function finish()
		running = false
		local won = playerScore > aiScore
		showGameOver(canvas, won and "You win!" or "CPU wins", ("%d x %d"):format(playerScore, aiScore), function()
			if gameSession == session then
				startPong()
			end
		end)
	end

	local inputConn = UserInputService.InputChanged:Connect(function(input)
		if input.UserInputType ~= Enum.UserInputType.MouseMovement and input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end
		local abs = canvas.AbsolutePosition
		local relY = input.Position.Y - abs.Y
		targetPlayerY = math.clamp(relY - paddleH / 2, 0, H - paddleH)
	end)

	bindGameKeys({ Enum.KeyCode.W, Enum.KeyCode.S, Enum.KeyCode.Up, Enum.KeyCode.Down })

	task.spawn(function()
		while running and gameSession == session do
			local dt = RunService.RenderStepped:Wait()
			if not running then
				break
			end
			local speed = 260
			if keyDown(Enum.KeyCode.W, Enum.KeyCode.Up) then
				targetPlayerY = math.clamp(targetPlayerY - speed * dt, 0, H - paddleH)
			elseif keyDown(Enum.KeyCode.S, Enum.KeyCode.Down) then
				targetPlayerY = math.clamp(targetPlayerY + speed * dt, 0, H - paddleH)
			end
			playerY = playerY + (targetPlayerY - playerY) * math.min(1, dt * 20)

			local aiTarget = ballPos.Y - paddleH / 2
			local aiSpeed = 150
			if aiTarget > aiY then
				aiY = math.min(aiY + aiSpeed * dt, aiTarget)
			else
				aiY = math.max(aiY - aiSpeed * dt, aiTarget)
			end
			aiY = math.clamp(aiY, 0, H - paddleH)

			ballPos = ballPos + ballVel * dt
			if ballPos.Y <= 0 then
				ballPos = Vector2.new(ballPos.X, 0)
				ballVel = Vector2.new(ballVel.X, math.abs(ballVel.Y))
			end
			if ballPos.Y >= H - 10 then
				ballPos = Vector2.new(ballPos.X, H - 10)
				ballVel = Vector2.new(ballVel.X, -math.abs(ballVel.Y))
			end

			if ballVel.X < 0 and ballPos.X <= 10 + paddleW and ballPos.X >= 0 then
				if ballPos.Y + 10 >= playerY and ballPos.Y <= playerY + paddleH then
					ballPos = Vector2.new(10 + paddleW, ballPos.Y)
					local rel = ((ballPos.Y + 5) - (playerY + paddleH / 2)) / (paddleH / 2)
					ballVel = Vector2.new(math.abs(ballVel.X) * 1.05, rel * 220)
					if math.abs(ballVel.X) > 420 then
						ballVel = Vector2.new(420, ballVel.Y)
					end
				end
			end

			if ballVel.X > 0 and ballPos.X + 10 >= W - 10 - paddleW and ballPos.X <= W - 10 then
				if ballPos.Y + 10 >= aiY and ballPos.Y <= aiY + paddleH then
					ballPos = Vector2.new(W - 10 - paddleW - 10, ballPos.Y)
					local rel = ((ballPos.Y + 5) - (aiY + paddleH / 2)) / (paddleH / 2)
					ballVel = Vector2.new(-math.abs(ballVel.X) * 1.05, rel * 220)
					if math.abs(ballVel.X) > 420 then
						ballVel = Vector2.new(-420, ballVel.Y)
					end
				end
			end

			if ballPos.X < -10 then
				aiScore = aiScore + 1
				updateScore()
				if aiScore >= 5 then
					finish()
					break
				end
				resetBall(1)
			elseif ballPos.X > W + 10 then
				playerScore = playerScore + 1
				updateScore()
				if playerScore >= 5 then
					finish()
					break
				end
				resetBall(-1)
			end

			playerPaddle.Position = UDim2.fromOffset(10, playerY)
			aiPaddle.Position = UDim2.fromOffset(W - 10 - paddleW, aiY)
			ball.Position = UDim2.fromOffset(ballPos.X, ballPos.Y)
		end
	end)

	setGameCleanup(function()
		running = false
		inputConn:Disconnect()
		unbindGameKeys()
	end)
end

-- ===== Memory =====
local function startMemory()
	clearGameContent()
	gameTitle.Text = "Memory"
	gameBackBtn.Visible = true
	local session = gameSession + 1
	gameSession = session

	local running = true
	local accepting = false
	local sequence = {}
	local inputIndex = 1
	local level = 0

	local status = gameLabel(gameContent, "Watch the sequence...", UDim2.new(1, -20, 0, 24), UDim2.new(0, 10, 0, 8), 14, WHITE, true)
	status.TextXAlignment = Enum.TextXAlignment.Center

	local grid = Instance.new("Frame")
	grid.Size = UDim2.fromOffset(260, 220)
	grid.Position = UDim2.new(0.5, -130, 0, 48)
	grid.BackgroundTransparency = 1
	grid.ZIndex = 32
	grid.Parent = gameContent

	local colors = {
		Color3.fromRGB(230, 70, 70),
		Color3.fromRGB(70, 200, 120),
		Color3.fromRGB(70, 130, 230),
		Color3.fromRGB(230, 200, 70),
	}
	local positions = {
		UDim2.fromOffset(0, 0),
		UDim2.fromOffset(135, 0),
		UDim2.fromOffset(0, 115),
		UDim2.fromOffset(135, 115),
	}
	local buttons = {}

	local function flash(i, duration)
		local original = colors[i]
		buttons[i].BackgroundColor3 = original:Lerp(WHITE, 0.55)
		task.delay(duration, function()
			if buttons[i] and buttons[i].Parent then
				buttons[i].BackgroundColor3 = original
			end
		end)
	end

	local showSequence
	showSequence = function()
		accepting = false
		inputIndex = 1
		status.Text = "Watch..."
		task.spawn(function()
			task.wait(0.5)
			for _, idx in ipairs(sequence) do
				if not running or gameSession ~= session then
					return
				end
				flash(idx, 0.35)
				task.wait(0.55)
			end
			if running and gameSession == session then
				status.Text = "Your turn!"
				accepting = true
			end
		end)
	end

	for i = 1, 4 do
		local b = Instance.new("TextButton")
		b.Size = UDim2.fromOffset(125, 105)
		b.Position = positions[i]
		b.BackgroundColor3 = colors[i]
		b.Text = ""
		b.BorderSizePixel = 0
		b.AutoButtonColor = false
		b.ZIndex = 33
		b.Parent = grid
		corner(b, 10)
		local st = Instance.new("UIStroke")
		st.Color = Color3.fromRGB(20, 20, 26)
		st.Thickness = 2
		st.Parent = b
		buttons[i] = b
		b.MouseButton1Click:Connect(function()
			if not running or not accepting then
				return
			end
			if i == sequence[inputIndex] then
				flash(i, 0.18)
				inputIndex = inputIndex + 1
				if inputIndex > #sequence then
					accepting = false
					level = level + 1
					status.Text = "Level " .. level .. "! Next..."
					task.delay(0.7, function()
						if running and gameSession == session then
							sequence[#sequence + 1] = math.random(1, 4)
							showSequence()
						end
					end)
				end
			else
				running = false
				accepting = false
				status.Text = "Wrong! Score: " .. level
				showGameOver(grid, "Game Over", "Level reached: " .. level, function()
					if gameSession == session then
						startMemory()
					end
				end)
			end
		end)
	end

	sequence = { math.random(1, 4) }
	showSequence()

	setGameCleanup(function()
		running = false
		accepting = false
	end)
end

-- ===== Tic-Tac-Toe =====
local function startTicTacToe()
	clearGameContent()
	gameTitle.Text = "Tic-Tac-Toe"
	gameBackBtn.Visible = true
	local session = gameSession + 1
	gameSession = session

	local running = true
	local status = gameLabel(gameContent, "You are X. Your turn!", UDim2.new(1, -20, 0, 24), UDim2.new(0, 10, 0, 8), 14, WHITE, true)
	status.TextXAlignment = Enum.TextXAlignment.Center

	local grid = Instance.new("Frame")
	grid.Size = UDim2.fromOffset(270, 270)
	grid.Position = UDim2.new(0.5, -135, 0, 42)
	grid.BackgroundTransparency = 1
	grid.ZIndex = 32
	grid.Parent = gameContent

	local board = {}
	local cells = {}
	local gameOver = false
	local playerTurn = true

	local function checkWinner(b)
		local lines = {
			{ 1, 2, 3 }, { 4, 5, 6 }, { 7, 8, 9 },
			{ 1, 4, 7 }, { 2, 5, 8 }, { 3, 6, 9 },
			{ 1, 5, 9 }, { 3, 5, 7 },
		}
		for _, l in ipairs(lines) do
			if b[l[1]] and b[l[1]] == b[l[2]] and b[l[2]] == b[l[3]] then
				return b[l[1]]
			end
		end
		for i = 1, 9 do
			if not b[i] then
				return nil
			end
		end
		return "draw"
	end

	local function finish(result)
		gameOver = true
		running = false
		local title
		if result == "X" then
			title = "You win!"
		elseif result == "O" then
			title = "CPU wins"
		else
			title = "Draw"
		end
		showGameOver(grid, title, "Tic-Tac-Toe", function()
			if gameSession == session then
				startTicTacToe()
			end
		end)
	end

	local function aiMove()
		if gameOver or not running then
			return
		end
		local function findMove(mark)
			for i = 1, 9 do
				if not board[i] then
					board[i] = mark
					local w = checkWinner(board)
					board[i] = nil
					if w == mark then
						return i
					end
				end
			end
			return nil
		end
		local move = findMove("O") or findMove("X")
		if not move then
			if not board[5] then
				move = 5
			else
				local corners = { 1, 3, 7, 9 }
				local freeCorners = {}
				for _, i in ipairs(corners) do
					if not board[i] then
						freeCorners[#freeCorners + 1] = i
					end
				end
				if #freeCorners > 0 then
					move = freeCorners[math.random(1, #freeCorners)]
				else
					local free = {}
					for i = 1, 9 do
						if not board[i] then
							free[#free + 1] = i
						end
					end
					move = free[math.random(1, #free)]
				end
			end
		end
		if move then
			board[move] = "O"
			cells[move].Text = "O"
			cells[move].TextColor3 = Color3.fromRGB(255, 120, 120)
		end
		local w = checkWinner(board)
		if w then
			finish(w)
		else
			playerTurn = true
			status.Text = "Your turn!"
		end
	end

	local function playerMove(i)
		if gameOver or not running or not playerTurn or board[i] then
			return
		end
		board[i] = "X"
		cells[i].Text = "X"
		cells[i].TextColor3 = Color3.fromRGB(120, 220, 255)
		local w = checkWinner(board)
		if w then
			finish(w)
			return
		end
		playerTurn = false
		status.Text = "CPU thinking..."
		task.delay(0.35, function()
			if running and gameSession == session then
				aiMove()
			end
		end)
	end

	for i = 1, 9 do
		local row = math.floor((i - 1) / 3)
		local col = (i - 1) % 3
		local b = Instance.new("TextButton")
		b.Size = UDim2.fromOffset(86, 86)
		b.Position = UDim2.fromOffset(col * 92, row * 92)
		b.BackgroundColor3 = Color3.fromRGB(32, 35, 46)
		b.Text = ""
		b.TextColor3 = WHITE
		b.Font = Enum.Font.GothamBold
		b.TextSize = 38
		b.BorderSizePixel = 0
		b.AutoButtonColor = false
		b.ZIndex = 33
		b.Parent = grid
		corner(b, 8)
		local st = Instance.new("UIStroke")
		st.Color = Color3.fromRGB(70, 75, 90)
		st.Thickness = 1.5
		st.Parent = b
		cells[i] = b
		b.MouseButton1Click:Connect(function()
			playerMove(i)
		end)
	end

	setGameCleanup(function()
		running = false
	end)
end

-- ===== Game menu =====
local function openGameMenu()
	clearGameContent()
	gameTitle.Text = "Mini Games"
	gameBackBtn.Visible = false
	gameWindow.Visible = true

	local list = Instance.new("Frame")
	list.Size = UDim2.new(1, -24, 1, -24)
	list.Position = UDim2.fromOffset(12, 12)
	list.BackgroundTransparency = 1
	list.ZIndex = 32
	list.Parent = gameContent

	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 8)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = list

	local title = Instance.new("TextLabel")
	title.Size = UDim2.new(1, 0, 0, 24)
	title.BackgroundTransparency = 1
	title.Text = "Choose a game:"
	title.TextColor3 = Color3.fromRGB(200, 205, 220)
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Font = Enum.Font.GothamBold
	title.TextSize = 13
	title.LayoutOrder = 0
	title.ZIndex = 32
	title.Parent = list

	local games = {
		{ name = "Snake", desc = "Eat apples and don't hit the walls", start = startSnake },
		{ name = "Pong", desc = "First to 5 points wins", start = startPong },
		{ name = "Memory", desc = "Repeat the color sequence", start = startMemory },
		{ name = "Tic-Tac-Toe", desc = "You are X, beat the CPU", start = startTicTacToe },
	}

	for i, g in ipairs(games) do
		local b = Instance.new("TextButton")
		b.Size = UDim2.new(1, 0, 0, 42)
		b.BackgroundColor3 = btnColor()
		b.Text = g.name .. "  —  " .. g.desc
		b.TextColor3 = WHITE
		b.Font = Enum.Font.GothamBold
		b.TextSize = 12
		b.TextWrapped = true
		b.BorderSizePixel = 0
		b.AutoButtonColor = false
		b.LayoutOrder = i
		b.ZIndex = 33
		b.Parent = list
		corner(b, 8)
		local st = Instance.new("UIStroke")
		st.Color = OFF_STROKE
		st.Thickness = 1.5
		st.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		st.Parent = b
		b.MouseButton1Click:Connect(function()
			g.start()
		end)
	end
end

gameBackBtn.MouseButton1Click:Connect(function()
	openGameMenu()
end)

gameCloseBtn.MouseButton1Click:Connect(function()
	clearGameContent()
	gameWindow.Visible = false
end)

local playGameBtn = makeButton(playerPage, "Play Game", 3)
playGameBtn.Name = "PlayGame"
playGameBtn.MouseButton1Click:Connect(function()
	openGameMenu()
end)

-- Switch RGB animations and borders globally without changing toggle ON/OFF states.
local function refreshRgb()
    for _, grad in ipairs(rgbGradients) do
        if grad and grad.Parent then
            -- Toggle gradients are restored below according to their actual state.
            grad.Enabled = state.rgbEnabled
        end
    end
    for _, paint in ipairs(toggleRefreshers) do
        paint()
    end
end

-- SETTINGS page
local settingsPage = makePage(body, 4)
settingsPage.Visible = false

-- Keep FPS Boost enabled across queued teleports; a fresh/manual execution starts with it OFF.
if not fromQueue then
    state.fpsBoost = false
    saveSettings()
end
makeToggle(settingsPage, "FPS BOOST", 0, function(v)
    state.fpsBoost = v
    saveSettings()
    setFpsBoost(v)
end, fromQueue and state.fpsBoost == true)


makeLabel(settingsPage, "GUI color (background)", 1)

local swatchRow = Instance.new("Frame")
swatchRow.Size = UDim2.new(1, -20, 0, 26)
swatchRow.BackgroundTransparency = 1
swatchRow.LayoutOrder = 2
swatchRow.Parent = settingsPage

local swatchLayout = Instance.new("UIListLayout")
swatchLayout.FillDirection = Enum.FillDirection.Horizontal
swatchLayout.Padding = UDim.new(0, 6)
swatchLayout.Parent = swatchRow

local presets = {
	Color3.fromRGB(8, 8, 8), -- black (default)
	Color3.fromRGB(28, 28, 34), -- graphite
	Color3.fromRGB(10, 40, 100), -- ocean
	Color3.fromRGB(45, 20, 95), -- violet
	Color3.fromRGB(100, 20, 40), -- crimson
	Color3.fromRGB(10, 80, 65), -- emerald
}

for _, c in ipairs(presets) do
	local s = Instance.new("TextButton")
	s.Size = UDim2.fromOffset(26, 26)
	s.BackgroundColor3 = c
	s.Text = ""
	s.BorderSizePixel = 0
	s.Parent = swatchRow
	corner(s, 6)
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(120, 120, 130)
	stroke.Thickness = 1
	stroke.Parent = s
	s.MouseButton1Click:Connect(function()
		applyTheme(c)
		state.themeColor = c:ToHex()
		saveSettings()
	end)
end

makeLabel(settingsPage, "Custom hex (e.g. #1e1e2e)", 3)

local caixaHex = makeTextBox(settingsPage, "#RRGGBB", "")
caixaHex.Size = UDim2.new(1, -20, 0, 28)
caixaHex.LayoutOrder = 4

caixaHex.FocusLost:Connect(function()
	local txt = caixaHex.Text:gsub("%s+", "")
	if txt == "" then
		return
	end
	local ok, c = pcall(Color3.fromHex, txt)
	if ok and c then
		applyTheme(c)
		state.themeColor = c:ToHex()
		saveSettings()
	else
		caixaHex.Text = ""
		caixaHex.PlaceholderText = "Invalid hex"
	end
end)

makeToggle(settingsPage, "Transparent Background", 5, function(v)
	state.transparent = v
	refreshTransparency()
end, state.transparent)

local autoExecReady = false
makeToggle(settingsPage, "Auto Execute On Teleport", 6, function(v)
	state.autoExecTeleport = v
	if autoExecReady then
		setAutoExecTeleport(v)
	end
end, state.autoExecTeleport)
autoExecReady = true

-- Display the new settings first so they are easy to find.
makeLabel(settingsPage, "BUILD: EVENT-TAB-V2 | Anti-AFK + Mini Start", 8)

makeToggle(settingsPage, "Anti-AFK", 8.5, function(v)
    state.antiAfk = v
end, state.antiAfk)

makeToggle(settingsPage, "Auto Scan Units (20s)", 9, function(v)
    state.autoScanUnits = v
    if v then requestAutoScan() end
end, state.autoScanUnits)

makeToggle(settingsPage, "Incognito Mode", 10, function(v)
    state.incognitoMode = v
    refreshIncognito()
end, state.incognitoMode)

makeToggle(settingsPage, "RGB Effects", 11, function(v)
    state.rgbEnabled = v
    refreshRgb()
end, state.rgbEnabled)

-- ===== Configurable minimize / restore keybind =====
-- Runs in its own scope to avoid adding locals to the main chunk.
do
    local function keyName()
        local stored = tostring(state.minimizeKey or "RightShift")
        return Enum.KeyCode[stored] and stored or "RightShift"
    end

    local capture = false
    local keyButton = makeButton(settingsPage, "Minimize Key: " .. keyName(), 12)

    keyButton.MouseButton1Click:Connect(function()
        capture = true
        keyButton.Text = "Press a key (Esc to cancel)"
    end)

    UserInputService.InputBegan:Connect(function(input, processed)
        if not alive() or input.UserInputType ~= Enum.UserInputType.Keyboard then
            return
        end
        if capture then
            capture = false
            if input.KeyCode ~= Enum.KeyCode.Escape and input.KeyCode ~= Enum.KeyCode.Unknown then
                state.minimizeKey = input.KeyCode.Name
                saveSettings()
            end
            keyButton.Text = "Minimize Key: " .. keyName()
            return
        end
        -- Don't toggle while typing a key or using another game's menu.
        if processed or UserInputService:GetFocusedTextBox() then
            return
        end
        if input.KeyCode.Name == keyName() and gui.Enabled and not keyPage.Visible then
            setMinimized(not miniIcon.Visible)
        end
    end)
end

-- ABOUT page
local aboutPage = makePage(body, 6)
aboutPage.Visible = false

local function makeText(parentObj, text, order, size, color, bold)
	local l = Instance.new("TextLabel")
	l.Size = UDim2.new(1, -20, 0, 0)
	l.AutomaticSize = Enum.AutomaticSize.Y
	l.BackgroundTransparency = 1
	l.Text = text
	l.TextWrapped = true
	l.TextColor3 = color or Color3.fromRGB(220, 220, 220)
	l.Font = bold and Enum.Font.GothamBold or Enum.Font.Gotham
	l.TextSize = size or 12
	l.TextXAlignment = Enum.TextXAlignment.Center
	l.LayoutOrder = order
	l.Parent = parentObj
	return l
end

makeText(aboutPage, "SatisHub V3", 1, 17, WHITE, true)
makeText(aboutPage, "Discord: satis1x", 2, 14, Color3.fromRGB(210, 210, 220), true)

local copyBtn = makeButton(aboutPage, "Copy Discord", 3)
copyBtn.MouseButton1Click:Connect(function()
	local clip = setclipboard or toclipboard or (syn and syn.write_clipboard)
	local ok = clip and pcall(clip, "satis1x")
	copyBtn.Text = ok and "Copied!" or "Not supported"
	task.delay(1.5, function()
		copyBtn.Text = "Copy Discord"
	end)
end)

makeText(aboutPage, "If someone charged you for this script, you got scammed.", 4, 13, ERROR_COLOR, true)
makeText(aboutPage, autoExecStatus, 5, 11, Color3.fromRGB(170, 175, 190), false)

-- Tab switching
local function showTab(name)
    -- V3: short scale/fade-feel transition without delaying functionality.
    -- A per-page UIScale avoids modifying the size of the automatic layout.
    if activeTab == name and ((name == "main" and mainPage.Visible) or
        (name == "event" and eventPage.Visible) or
        (name == "player" and playerPage.Visible) or
        (name == "settings" and settingsPage.Visible) or
        (name == "about" and aboutPage.Visible)) then
        return
    end
    activeTab = name
    mainPage.Visible = (name == "main")
    eventPage.Visible = (name == "event")
    playerPage.Visible = (name == "player")
    settingsPage.Visible = (name == "settings")
    aboutPage.Visible = (name == "about")
    refreshTabs()
    local page = (name == "main" and mainPage) or
        (name == "event" and eventPage) or
        (name == "player" and playerPage) or
        (name == "settings" and settingsPage) or aboutPage
    local scale = page:FindFirstChild("SatisV3TabScale")
    if not scale then
        scale = Instance.new("UIScale")
        scale.Name = "SatisV3TabScale"
        scale.Parent = page
    end
    scale.Scale = 0.925
    local previous = page:FindFirstChild("SatisV31PageTween")
    -- A short easing-out entrance keeps UI responsive during rapid switches.
    TweenService:Create(scale, TweenInfo.new(0.29, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {Scale = 1}):Play()
end

tabMain.MouseButton1Click:Connect(function()
	showTab("main")
end)
tabEvent.MouseButton1Click:Connect(function()
	showTab("event")
end)
tabPlayer.MouseButton1Click:Connect(function()
	showTab("player")
end)
tabSettings.MouseButton1Click:Connect(function()
	showTab("settings")
end)
tabAbout.MouseButton1Click:Connect(function()
	showTab("about")
end)

-- Key verification: acknowledge a successful key before minimizing.
local keyVerified = false
local function verificar()
    if keyVerified then return end
    if normalizeKey(caixaKey.Text) == KEY then
        keyVerified = true
        msgKey.Text = "Success!"
        msgKey.TextColor3 = Color3.fromRGB(80, 230, 130)
        botaoKey.Text = "Success!"
        caixaKey.TextEditable = false
        state.savedKey = KEY
        saveSettings()

        -- Keep the key page visible so the confirmation can be read.
        task.spawn(function()
            task.wait(2)
            if not alive() or not gui.Parent then return end
            keyPage.Visible = false
            tabsRow.Visible = true
            showTab("main")
            setMinimized(true)
        end)
    else
        msgKey.TextColor3 = ERROR_COLOR
        msgKey.Text = "Invalid key"
    end
end

botaoKey.MouseButton1Click:Connect(verificar)
caixaKey.FocusLost:Connect(function(enter)
	if enter then
		verificar()
	end
end)

-- Skip key only on a queued teleport when it was previously verified
if fromQueue and state.savedKey == KEY then
	keyPage.Visible = false
	tabsRow.Visible = true
	showTab("main")
end

applyTheme(currentTheme)
refreshRgb()
refreshTransparency()
refreshTabs()

-- ===== Anti-spam: votes and card selection =====
-- These remotes were previously called every 1.5 seconds even if the game had
-- already accepted the vote. Use a single start vote per activation and strict
-- cooldowns for wave/card actions. Never issue these while leaving the match.
local matchEnding = false
local startVoted = false
local cardNextAt = 0
local skipNextAt = 0
local replayVoted = false
local CARD_COOLDOWN = 30
local SKIP_COOLDOWN = 15

-- Auto Start: once per activation. Switching OFF arms it for the next activation.
task.spawn(function()
    while alive() do
        if not state.autoStart then
            startVoted = false
        elseif not matchEnding and not startVoted then
            startVoted = true
            invoke("vote_start")
            print("[SatisHub] Auto Start: sent once (anti-spam)")
        end
        task.wait(1)
    end
end)

-- Card selection: at most one request per 30 seconds. Never spam the server.
task.spawn(function()
    while alive() do
        local opt
        if state.randomCard then
            opt = tostring(math.random(1, 3))
        elseif state.autoCard then
            opt = tostring(state.cardOption)
        end
        if not opt then
            cardNextAt = 0
        elseif not matchEnding and os.clock() >= cardNextAt then
            cardNextAt = os.clock() + CARD_COOLDOWN
            invoke("select_roguelike_option", opt)
        end
        task.wait(1)
    end
end)

-- Skip Wave: maximum one request every 15 seconds.
task.spawn(function()
    while alive() do
        if not state.autoSkip then
            skipNextAt = 0
        elseif not matchEnding and os.clock() >= skipNextAt then
            skipNextAt = os.clock() + SKIP_COOLDOWN
            invoke("vote_wave_skip")
        end
        task.wait(1)
    end
end)

-- Replay vote only when game_finished fires (if Auto Leave is disabled).
-- This avoids casting a replay vote repeatedly during an active match.
do
    local s2cFolder = endpoints and endpoints:FindFirstChild("server_to_client")
    local finishedRemote = s2cFolder and s2cFolder:FindFirstChild("game_finished")
    if finishedRemote and finishedRemote:IsA("RemoteEvent") then
        finishedRemote.OnClientEvent:Connect(function()
            if alive() and state.autoReplay and not state.autoLeave and not replayVoted then
                replayVoted = true
                task.delay(2, function()
                    if alive() and state.autoReplay and not state.autoLeave then
                        invoke("set_game_finished_vote", "replay")
                    end
                end)
            end
        end)
    end
end

-- ===== Auto Leave: victory/defeat or visible end screen =====
-- O evento pode chegar antes de o UI aparecer. Nunca repetir o remote automaticamente.
local function startAutoLeave()
    local requested, pending = false, false
    local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui", 15)

    local function requestLobby(origin)
        if requested or pending or not alive() or not state.autoLeave then return end
        pending = true
        matchEnding = true -- bloqueia votes, cartas, upgrades e placements
        print("[SatisHub] Auto Leave: fim detectado por " .. origin .. "; a aguardar 3s")
        task.delay(3, function()
            if not alive() or not state.autoLeave then
                pending = false
                matchEnding = false
                return
            end
            requested = true -- reservado ANTES do InvokeServer (que pode bloquear)
            pending = false
            local remote = c2s and c2s:FindFirstChild("teleport_back_to_lobby")
            if not remote or not remote:IsA("RemoteFunction") then
                warn("[SatisHub] Auto Leave: remote teleport_back_to_lobby nao encontrado")
                return
            end
            print("[SatisHub] Auto Leave: enviando UM pedido ao servidor")
            -- InvokeServer pode ficar em espera: nao bloqueia a rotina de detecao.
            task.spawn(function()
                local ok, reply = pcall(function() return remote:InvokeServer() end)
                if not alive() then return end
                if not ok then
                    warn("[SatisHub] Auto Leave: erro do servidor: " .. tostring(reply))
                elseif reply == false then
                    warn("[SatisHub] Auto Leave: servidor respondeu false; usa Return to Lobby manualmente")
                else
                    print("[SatisHub] Auto Leave: servidor respondeu " .. tostring(reply) .. "; a aguardar teleport")
                end
            end)
            task.delay(12, function()
                if alive() then
                    warn("[SatisHub] Auto Leave: se continuares na partida, o servidor nao concluiu o teleport; usa o botao manual. Nao vou repetir o pedido.")
                end
            end)
        end)
    end

    local folder = endpoints and endpoints:FindFirstChild("server_to_client")
    local event = folder and folder:FindFirstChild("game_finished")
    if event and event:IsA("RemoteEvent") then
        event.OnClientEvent:Connect(function()
            if state.autoLeave then requestLobby("game_finished") end
        end)
    else
        warn("[SatisHub] Auto Leave: game_finished nao encontrado; fallback do ecrã ativo")
    end

    local function visible(obj)
        local node = obj
        while node and node ~= playerGui do
            if node:IsA("GuiObject") and not node.Visible then return false end
            if node:IsA("ScreenGui") and not node.Enabled then return false end
            node = node.Parent
        end
        return node == playerGui
    end

    local function endScreenShown()
        if not playerGui then return false end
        local lobby, replay = false, false
        for _, obj in ipairs(playerGui:GetDescendants()) do
            if obj:IsA("TextButton") and visible(obj) then
                local t = tostring(obj.Text):lower():gsub("%s+", " ")
                if t:find("return to lobby", 1, true) then lobby = true end
                if t == "replay" then replay = true end
                if lobby and replay then return true end
            end
        end
        return false
    end
    task.spawn(function()
        local seen = 0
        while alive() do
            if state.autoLeave and not requested and not pending then
                seen = endScreenShown() and (seen + 1) or 0
                if seen >= 2 then requestLobby("end-screen UI") end
            else
                seen = 0
            end
            task.wait(1.5)
        end
    end)
end
startAutoLeave()

-- Unit automation lives in a separate function to keep the main Luau chunk below the 200-local-register limit.
local function startUnitAutomation()
-- ===== Unit helpers (placement / upgrade) =====
local function getUnitsFolder()
	return workspace:FindFirstChild("_UNITS")
end

-- true = mine, false = someone else's, nil = cannot tell
local function unitOwnedByMe(unit)
	local me = Players.LocalPlayer
	local stats = unit:FindFirstChild("_stats")
	local owner = stats and stats:FindFirstChild("player")
	if owner then
		if owner:IsA("ObjectValue") then
			return owner.Value == me
		elseif owner:IsA("StringValue") then
			return owner.Value == me.Name or owner.Value == tostring(me.UserId)
		end
	end
	for _, key in ipairs({ "Owner", "owner", "Player", "player", "OwnerId", "UserId" }) do
		local v = unit:GetAttribute(key)
		if v ~= nil then
			return v == me or v == me.Name or v == me.UserId or tostring(v) == tostring(me.UserId)
		end
	end
	return nil
end

local function myUnits()
	local list = {}
	local folder = getUnitsFolder()
	if folder then
		for _, u in ipairs(folder:GetChildren()) do
			if unitOwnedByMe(u) ~= false then
				list[#list + 1] = u
			end
		end
	end
	return list
end

-- Auto Upgrade V3.2: rotate units and give each unit its own cooldown.
-- One request at a time; one rejection no longer pauses every other unit.
local UPGRADE_INTERVALO = 3.0
local UPGRADE_REJECT_COOLDOWN = 18
local upgradeIndex = 0
local upgradeNextAt = 0
local upgradeWasOn = false
local upgradeRetryAt = {}

task.spawn(function()
    while alive() do
        if state.autoUpgrade and not matchEnding then
            if not upgradeWasOn then
                upgradeNextAt = 0
                upgradeIndex = 0
                upgradeRetryAt = {}
            end
            if os.clock() >= upgradeNextAt then
                local units = myUnits()
                local chosen
                -- Skip units on cooldown, instead of blocking the whole loop.
                for _ = 1, #units do
                    upgradeIndex = (upgradeIndex % #units) + 1
                    local candidate = units[upgradeIndex]
                    if candidate and candidate.Parent and (upgradeRetryAt[candidate] or 0) <= os.clock() then
                        chosen = candidate
                        break
                    end
                end
                if chosen then
                    local ok, result = invokeRet("upgrade_unit_ingame", chosen)
                    if not ok or result == false then
                        upgradeRetryAt[chosen] = os.clock() + UPGRADE_REJECT_COOLDOWN
                        upgradeNextAt = os.clock() + 4
                    else
                        -- A nil response does not prove success: leave a moderate delay.
                        upgradeNextAt = os.clock() + UPGRADE_INTERVALO
                    end
                else
                    upgradeNextAt = os.clock() + 3
                end
            end
        else
            upgradeNextAt = 0
        end
        upgradeWasOn = state.autoUpgrade
        task.wait(0.4)
    end
end)

-- ===== Smart random placement =====
-- Learns what kind of floor the spots you used are on, then picks random spots only on that floor,
-- away from other units and from spots that failed. When a spot fails it moves on to another one.
local PLACE_INTERVALO = 0.7
local MIN_SPACING = 3.5 -- minimum distance (studs) from other units
local BAD_SPOT_RADIUS = 3 -- area blocked around a spot where placing failed
local BAD_SPOT_TTL = 120 -- seconds a failed spot stays blocked
local ATTEMPTS_PER_CYCLE = 2 -- different spots tried per cycle when one fails
local NO_MONEY_AFTER = 5 -- this many failures in a row = probably no money / unit limit

local badSpots = {} -- confirmed bad spots { pos, t }
local pendingBad = {} -- failures not confirmed yet (could just be no money)
local goodSpots = {} -- positions where a unit was placed successfully
local idFails = {} -- consecutive failures per unit ID
local failStreak = 0
local placedCount = 0
local placeLastError = ""
local lastPlaceNotice = 0
local function placeNotice(message)
    placeLastError = tostring(message)
    if os.clock() - lastPlaceNotice > 4 then
        warn("[SatisHub Auto Place] " .. placeLastError)
        lastPlaceNotice = os.clock()
    end
end

local function flatDist(a, b)
	return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude
end

-- Returns a point at the bottom of a unit model (the ground under it).
-- Using the bounding box instead of the pivot also works for tall units.
local function unitGroundPosition(unit)
	local ok, cf, size = pcall(function()
		return unit:GetBoundingBox()
	end)
	if ok and cf and size then
		return Vector3.new(cf.Position.X, cf.Position.Y - size.Y / 2, cf.Position.Z)
	end
	local ok2, pivot = pcall(function()
		return unit:GetPivot()
	end)
	if ok2 and pivot then
		return pivot.Position
	end
	return nil
end

-- The unit's origin / pivot, which is what spawn_unit expects as CFrame.Position.
local function unitPivotPosition(unit)
	local ok, pivot = pcall(function()
		return unit:GetPivot()
	end)
	if ok and pivot then
		return pivot.Position
	end
	return unitGroundPosition(unit)
end

local function farFrom(list, pos, dist)
	for _, p in ipairs(list) do
		if flatDist(p, pos) < dist then
			return false
		end
	end
	return true
end

local function isBad(pos)
	local now = os.clock()
	for i = #badSpots, 1, -1 do
		local b = badSpots[i]
		if now - b.t > BAD_SPOT_TTL then
			table.remove(badSpots, i)
		elseif flatDist(b.pos, pos) < BAD_SPOT_RADIUS then
			return true
		end
	end
	for _, b in ipairs(pendingBad) do
		if flatDist(b.pos, pos) < BAD_SPOT_RADIUS then
			return true
		end
	end
	return false
end

-- If the script has not learned a valid placement area yet, look for likely
-- placement pads / plots / bases in the map and use them as search centers.
local autoCenterCache = { time = 0, list = {} }

local function findAutoCenters()
	local now = os.clock()
	if now - autoCenterCache.time < 8 then
		return autoCenterCache.list
	end
	autoCenterCache.time = now
	local list = {}
	local keywords = { "place", "placement", "pad", "plot", "base", "tower", "unit", "zone", "platform", "spawn" }
	local function relevant(name)
		local n = name:lower()
		for _, k in ipairs(keywords) do
			if n:find(k, 1, true) then
				return true
			end
		end
		return false
	end
	local function add(pos)
		for _, p in ipairs(list) do
			if flatDist(p, pos) < 4 then
				return
			end
		end
		list[#list + 1] = pos
	end
	local function addInstance(inst)
		if inst:IsA("BasePart") and relevant(inst.Name) then
			-- Use the top surface of pads / baseplates, not their center.
			add(inst.Position + Vector3.new(0, inst.Size.Y / 2, 0))
		elseif inst:IsA("Model") and relevant(inst.Name) then
			local ok, cf, size = pcall(function()
				return inst:GetBoundingBox()
			end)
			if ok and cf and size then
				add(Vector3.new(cf.Position.X, cf.Position.Y - size.Y / 2, cf.Position.Z))
			end
		end
	end
	-- Check the top level first, so a baseplate / plot is found even in a big map.
	for _, inst in ipairs(workspace:GetChildren()) do
		addInstance(inst)
	end
	local stack = { workspace }
	local visited = 0
	while #stack > 0 and visited < 3000 do
		local inst = table.remove(stack)
		visited = visited + 1
		addInstance(inst)
		for _, child in ipairs(inst:GetChildren()) do
			if not child:IsA("Terrain") and not child:IsA("Player") then
				stack[#stack + 1] = child
			end
		end
	end
	autoCenterCache.list = list
	return list
end

-- Finds the local player's own units / plot / base, so auto place does not
-- try to use another player's plot when the game has per-player plots.
local playerCenterCache = { time = 0, list = {} }

local function findPlayerCenters()
	local list = {}
	local function add(pos)
		for _, p in ipairs(list) do
			if flatDist(p, pos) < 4 then
				return
			end
		end
		list[#list + 1] = pos
	end
	local me = Players.LocalPlayer
	local folder = getUnitsFolder()
	if folder then
		for _, u in ipairs(folder:GetChildren()) do
			if unitOwnedByMe(u) == true then
				local p = unitPivotPosition(u)
				if p then
					add(p)
				end
			end
		end
	end
	local char = me.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if root then
		add(root.Position)
	end

	local now = os.clock()
	if now - playerCenterCache.time < 8 then
		for _, p in ipairs(playerCenterCache.list) do
			add(p)
		end
		return list
	end
	playerCenterCache.time = now

	local found = {}
	local function addFound(pos)
		for _, p in ipairs(found) do
			if flatDist(p, pos) < 4 then
				return
			end
		end
		found[#found + 1] = pos
	end
	local charSet = {}
	for _, plr in ipairs(Players:GetPlayers()) do
		if plr.Character then
			charSet[plr.Character] = true
		end
	end
	local myName = me.Name:lower()
	local myId = tostring(me.UserId)
	local function nameHasToken(name, token)
		if token == "" then
			return false
		end
		local start = 1
		while true do
			local s, e = name:find(token, start, true)
			if not s then
				return false
			end
			local before = s > 1 and name:sub(s - 1, s - 1) or ""
			local after = e < #name and name:sub(e + 1, e + 1) or ""
			if (before == "" or not before:match("[%w]")) and (after == "" or not after:match("[%w]")) then
				return true
			end
			start = e + 1
		end
	end
	local queue = {}
	for _, child in ipairs(workspace:GetChildren()) do
		queue[#queue + 1] = child
	end
	local index = 1
	local visited = 0
	while index <= #queue and visited < 1500 do
		local inst = queue[index]
		index = index + 1
		visited = visited + 1
		if inst ~= char and inst ~= folder and not charSet[inst] and not inst:IsA("Player") and not inst:IsA("Terrain") then
			local owned = false
			local name = inst.Name:lower()
			local relevantName = name:find("plot", 1, true) or name:find("base", 1, true) or name:find("unit", 1, true) or name:find("tower", 1, true) or name:find("place", 1, true) or name:find("spawn", 1, true) or name:find("zone", 1, true)
			if name == myName or nameHasToken(name, myId) or (relevantName and nameHasToken(name, myName)) then
				owned = true
			end
			if not owned then
				for _, key in ipairs({ "Owner", "owner", "Player", "player", "OwnerId", "UserId" }) do
					local v = inst:GetAttribute(key)
					if v ~= nil and (v == me or v == me.Name or v == me.UserId or tostring(v) == myId) then
						owned = true
						break
					end
				end
			end
			if not owned then
				for _, child in ipairs(inst:GetChildren()) do
					if child:IsA("ObjectValue") and child.Value == me then
						owned = true
						break
					end
				end
			end
			if owned then
				if inst:IsA("BasePart") then
					addFound(inst.Position + Vector3.new(0, inst.Size.Y / 2, 0))
				elseif inst:IsA("Model") then
					local ok, cf, size = pcall(function()
						return inst:GetBoundingBox()
					end)
					if ok and cf and size then
						addFound(Vector3.new(cf.Position.X, cf.Position.Y - size.Y / 2, cf.Position.Z))
					end
				else
					-- A folder named after the player: keep looking inside it.
					for _, child in ipairs(inst:GetChildren()) do
						if not child:IsA("Player") and not child:IsA("Terrain") then
							queue[#queue + 1] = child
						end
					end
				end
			else
				for _, child in ipairs(inst:GetChildren()) do
					if not child:IsA("Player") and not child:IsA("Terrain") then
						queue[#queue + 1] = child
					end
				end
			end
		end
	end
	playerCenterCache.list = found
	for _, p in ipairs(found) do
		add(p)
	end
	return list
end

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude

local function prepareRay()
	local ignore = {}
	local folder = getUnitsFolder()
	if folder then
		ignore[#ignore + 1] = folder
	end
	for _, plr in ipairs(Players:GetPlayers()) do
		if plr.Character then
			ignore[#ignore + 1] = plr.Character
		end
	end
	rayParams.FilterDescendantsInstances = ignore
end

local function rayDown(pos, up, len)
	return workspace:Raycast(pos + Vector3.new(0, up, 0), Vector3.new(0, -len, 0), rayParams)
end

-- Learns what kind of floor the valid spots (the ones you used + the ones that worked) are on
local function buildGroundFilter()
	local f = { parts = {}, parents = {}, names = {}, mats = {} }
	local any = false
	local function learnFrom(p)
		local hit = rayDown(p, 35, 100)
		if hit and hit.Instance then
			any = true
			local inst = hit.Instance
			if inst:IsA("Terrain") then
				f.mats[hit.Material] = true
			else
				f.parts[inst] = true
				f.names[inst.Name] = true
				if inst.Parent and inst.Parent ~= workspace then
					f.parents[inst.Parent] = true
				end
			end
		end
	end
	for _, p in ipairs(learned.positions) do
		learnFrom(p)
	end
	for _, p in ipairs(goodSpots) do
		learnFrom(p)
	end
	-- Before the script has a learned spot, learn from the player's own area
	-- and from units already on the map (they are standing on valid ground).
	if #learned.positions == 0 and #goodSpots == 0 then
		local okPC, pcList = pcall(findPlayerCenters)
		if okPC and type(pcList) == "table" then
			for _, p in ipairs(pcList) do
				learnFrom(p)
			end
		end
		local folder = getUnitsFolder()
		if folder then
			local n = 0
			for _, u in ipairs(folder:GetChildren()) do
				n = n + 1
				if n > 30 then
					break
				end
				local p = unitGroundPosition(u)
				if p then
					learnFrom(p)
				end
			end
		end
	end
	return any and f or nil
end

local function groundOk(hit, filter)
	if not hit or not hit.Instance then
		return false
	end
	if hit.Normal.Y < 0.85 then -- too steep
		return false
	end
	if not filter then
		return true
	end
	local inst = hit.Instance
	if inst:IsA("Terrain") then
		return filter.mats[hit.Material] == true
	end
	return filter.parts[inst] == true or (filter.parents[inst.Parent] == true and filter.names[inst.Name] == true)
end

local function pickSpot()
	local playerCenters = {}
	local otherCenters = {}
	local function addTo(list, p)
		for _, c in ipairs(list) do
			if flatDist(c, p) < 2 then
				return
			end
		end
		list[#list + 1] = p
	end
	for _, p in ipairs(learned.positions) do
		addTo(playerCenters, p)
	end
	for _, p in ipairs(goodSpots) do
		addTo(playerCenters, p)
	end
	-- Learned spots are always preferred. Before the script learns one, use the
	-- local player's own units / plot / character position first.
	if #learned.positions == 0 and #goodSpots == 0 then
		local okPC, pcList = pcall(findPlayerCenters)
		if okPC and type(pcList) == "table" then
			for _, p in ipairs(pcList) do
				addTo(playerCenters, p)
			end
		end
	end
    local folder = getUnitsFolder()
    if #learned.positions == 0 and #goodSpots == 0 and folder then
        for _, u in ipairs(folder:GetChildren()) do
            if unitOwnedByMe(u) == true then
                local up = unitGroundPosition(u)
                if up then addTo(playerCenters, up) end
            end
        end
    end
	-- When the local character stands on a high ledge, nearby placed friendly
    -- units are much more reliable anchors than the character's root.
    -- Other players' units / generic pads are only a fallback.
	local useFallback = #playerCenters == 0 or (#learned.positions == 0 and #goodSpots == 0 and failStreak >= 4)
	if useFallback then
		if folder then
			local n = 0
			for _, u in ipairs(folder:GetChildren()) do
				n = n + 1
				if n > 30 then
					break
				end
				local p = unitPivotPosition(u)
				if p then
					addTo(otherCenters, p)
				end
			end
		end
		local okAC, acList = pcall(findAutoCenters)
		if okAC and type(acList) == "table" then
			for _, p in ipairs(acList) do
				addTo(otherCenters, p)
			end
		end
	end
	local centers = playerCenters
	if useFallback then
		centers = {}
		for _, p in ipairs(playerCenters) do
			addTo(centers, p)
		end
        -- Do not place on other players' plots merely because our own positions failed.
	end
	if #centers == 0 then
		return nil
	end

	prepareRay()
	local filter = buildGroundFilter()
	-- every failure in a row widens the search a bit, so it stops hitting the same area
	local radius = math.min(48, (tonumber(state.placeRadius) or 15) * (1 + math.min(failStreak, 5) * 0.18))
	local char = Players.LocalPlayer.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	local rootPos = root and root.Position

	local occupied = {}
	if folder then
		for _, u in ipairs(folder:GetChildren()) do
			local p = unitGroundPosition(u)
			if p then
				occupied[#occupied + 1] = p
			end
		end
	end

	for attempt = 1, 60 do
        -- Different maps use different floor names/materials. Prefer learned
        -- ground briefly, then explore flat surfaces near existing units.
        local useFilter = (attempt <= 20) and filter or nil
		local center = centers[math.random(1, #centers)]
		local angle = math.random() * math.pi * 2
		local dist = math.sqrt(math.random()) * radius
		local flat = Vector3.new(center.X + math.cos(angle) * dist, center.Y, center.Z + math.sin(angle) * dist)

		local hit = rayDown(flat, 140, 430)
		if hit and groundOk(hit, useFilter) then
			-- keep the same height convention the game used for the spot we learned from
			local cHit = rayDown(center, 140, 430)
			local centerGroundY = cHit and cHit.Position.Y or center.Y
			local offset = cHit and (center.Y - cHit.Position.Y) or 0
			-- The character root is not a unit origin; place at ground level there.
			if rootPos and flatDist(center, rootPos) < 0.01 and math.abs(center.Y - rootPos.Y) < 0.01 then
				offset = 0
			end
			if math.abs(hit.Position.Y - centerGroundY) <= 28 then
				local pos = Vector3.new(flat.X, hit.Position.Y + offset, flat.Z)
				if farFrom(occupied, pos, MIN_SPACING) and not isBad(pos) then
					return pos
				end
			end
		end
	end
	return nil
end

-- Cycle through the available IDs rather than randomly picking the same one.
-- A rejected ID is cooled down briefly, while other IDs still get a turn.
local nextUnitIndex = 0
local idRetryAfter = {}
-- Unit limits vary by character. Learn the limit from the game's own notification.
-- Once an ID reaches its limit, skip it for this match instead of retrying forever.
local unitCaps = {}
local unitAtCap = {}
local activePlaceId = nil
local activePlaceAt = 0
local activePlacePosition = nil
local playerGuiForCaps = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
local function observePlaceNotice(text)
    if type(text) ~= "string" then return end
    local max = tonumber(text:lower():match("cannot place more than%s+(%d+)%s+of this unit"))
    if text:lower():find("cannot place unit here", 1, true)
        and activePlacePosition and os.clock() - activePlaceAt < 4 then
        badSpots[#badSpots + 1] = {pos = activePlacePosition, t = os.clock()}
        if #badSpots > 250 then table.remove(badSpots, 1) end
        placeNotice("Invalid ground; trying another position")
    end
    if max and activePlaceId and os.clock() - activePlaceAt < 4 then
        unitCaps[activePlaceId] = max
        unitAtCap[activePlaceId] = true
        idRetryAfter[activePlaceId] = math.huge
        placeNotice(("Unit limit reached (%d). Skipping this unit for the match."):format(max))
    end
end
-- Event-based notification reader: does not disable any game connections.
-- Covers new labels and text updates on labels reused by the game's UI.
local seenNoticeLabels = setmetatable({}, {__mode = "k"})
local function observeNoticeLabel(obj)
    if not (obj:IsA("TextLabel") or obj:IsA("TextButton")) or seenNoticeLabels[obj] then return end
    seenNoticeLabels[obj] = true
    observePlaceNotice(obj.Text)
    obj:GetPropertyChangedSignal("Text"):Connect(function()
        if alive() then observePlaceNotice(obj.Text) end
    end)
end
if playerGuiForCaps then
    for _, obj in ipairs(playerGuiForCaps:GetDescendants()) do
        observeNoticeLabel(obj)
    end
    playerGuiForCaps.DescendantAdded:Connect(function(obj)
        if alive() then observeNoticeLabel(obj) end
    end)
end
local function pickId(ids)
    if #ids == 0 then return nil end
    for _ = 1, #ids do
        nextUnitIndex = (nextUnitIndex % #ids) + 1
        local id = ids[nextUnitIndex]
        if not unitAtCap[id] and (idRetryAfter[id] or 0) <= os.clock() then
            return id
        end
    end
    return nil
end

-- Places one unit and checks if it really appeared (your unit count goes up)
-- Returns success, reason. Do not treat a nil server response as confirmed placement.
local function tryPlace(id, pos)
    if unitAtCap[id] then return false, "Unit placement limit reached" end
    local before = #myUnits()
    activePlaceId = id
    activePlaceAt = os.clock()
    activePlacePosition = pos
    env.SatisHubAutoPlacing = true
    local ok, res = invokeRet("spawn_unit", id, CFrame.new(pos))
    env.SatisHubAutoPlacing = nil
    -- Let client notifications arrive without spamming additional requests.
    task.wait(0.12)
    if unitAtCap[id] then return false, "Unit placement limit reached" end
    if not ok then
        return false, "Remote failed or unavailable: " .. tostring(res)
    end
    if res == false then
        return false, "Server rejected placement"
    end
    if getUnitsFolder() then
        for _ = 1, 9 do
            if not (alive() and state.randomPlace) then
                return false, "Placement cancelled"
            end
            task.wait(0.13)
            if unitAtCap[id] then return false, "Unit placement limit reached" end
            if #myUnits() > before then
                addUnitId(id, true, true)
                return true
            end
        end
        return false, "No new unit detected (server reply: " .. tostring(res) .. ")"
    end
    -- Without the units folder there is no trustworthy way to verify success.
    return false, "_UNITS folder not found; cannot confirm placement"
end

local function collectUnitIds()
    local list, seen = {}, {}
    local function add(id)
        if type(id) ~= "string" or not id:match(UUID_PATTERN) or seen[id] then return end
        seen[id] = true
        list[#list + 1] = id
    end
    -- Explicit unit IDs take priority; do not mix unrelated IDs from the world.
    for token in tostring(state.unitIds or ""):gmatch("[^,;%s]+") do
        local id = token
        if id:sub(1, 1) ~= "{" then id = "{" .. id .. "}" end
        if id:match(UUID_PATTERN) then
            add(id)
            learned.manual[id] = true
            learned.likely[id] = true
        end
    end
    if #list > 0 then return list end
    -- If no manual ID was set, only use IDs gathered from the player's own UI / inventory.
    for id in pairs(learned.likely) do add(id) end
    for id in pairs(learned.confirmed) do add(id) end
    table.sort(list)
    return list
end

task.spawn(function()
	local wasOn = false
	while alive() do
		local ids = collectUnitIds()
		if state.randomPlace and not matchEnding and os.clock() - lastScan > 15 then
			-- Scan while we still have no confirmed unit ID, or while we have no IDs at all.
			-- This catches the inventory once it loads / after the shop is opened.
			if #ids == 0 or next(learned.confirmed) == nil then
				task.spawn(scanUnitIds, false)
			end
		end
		if #ids == 0 then
			placeStatus.Text = "No unit IDs found automatically"
		else
			placeStatus.Text = ("IDs: %d | Spots: %d | Placed: %d | %s"):format(#ids, #learned.positions + #goodSpots, placedCount, placeLastError:sub(1, 35))
		end

		-- fresh start every time the option is turned on
		if state.randomPlace and not wasOn then
			badSpots = {}
			pendingBad = {}
			idFails = {}
            idRetryAfter = {}
            -- Keep learned unit limits when toggling Auto Place in the same match.
            nextUnitIndex = 0
			failStreak = 0
		end

		wasOn = state.randomPlace

		if state.randomPlace and not matchEnding and #ids > 0 then
			for _ = 1, ATTEMPTS_PER_CYCLE do
				if not (alive() and state.randomPlace) then
					break
				end
				local pos = pickSpot()
				if not pos then
                    placeNotice("No valid placement ground found. Place one unit manually or adjust radius.")
					failStreak = failStreak + 1
					break
				end
				local id = pickId(ids)
                if not id then
                    placeNotice("All unit IDs temporarily on cooldown (money, cap, or invalid IDs)")
                    break
                end
                local placed, reason = tryPlace(id, pos)
				if placed then
					failStreak = 0
                    placeLastError = "OK"
					idFails[id] = 0
                    idRetryAfter[id] = nil
					placedCount = placedCount + 1
					goodSpots[#goodSpots + 1] = pos
					if #goodSpots > 30 then
						table.remove(goodSpots, 1)
					end
					-- it worked, so the spots that failed just before really were bad
					for _, b in ipairs(pendingBad) do
						badSpots[#badSpots + 1] = b
					end
					pendingBad = {}
					if #badSpots > 300 then
						table.remove(badSpots, 1)
					end
					break
				else
                    placeNotice(reason or "Placement not confirmed")
                    if reason and (reason:find("Remote failed", 1, true) or reason:find("_UNITS folder", 1, true)) then
                        break
                    end
					-- this spot did not work: move on to another one right away
					failStreak = failStreak + 1
					idFails[id] = (idFails[id] or 0) + 1
                    -- Avoid retrying one failing unit endlessly. Do not permanently ban it.
                    if not unitAtCap[id] then
                        idRetryAfter[id] = os.clock() + math.min(12, 2 * idFails[id])
                    end
					pendingBad[#pendingBad + 1] = { pos = pos, t = os.clock() }
					if failStreak >= NO_MONEY_AFTER then
						-- many fails in a row: probably no money / unit limit, not the spots
						pendingBad = {}
                        placeNotice("Multiple failed placements: check money, unit cap, and available ground")
						break
					end
				end
			end
		end
		-- when it keeps failing (probably no money) slow down
		task.wait(PLACE_INTERVALO * ((failStreak >= NO_MONEY_AFTER) and 5 or 1))
	end
end)

end
task.spawn(startUnitAutomation)

-- Auto join event: only one matchmaking request per activation.
-- Repeated requests every five seconds can overlap with a server teleport.
task.spawn(function()
    local autoJoinRequested = false
    local autoJoinBusy = false
	while alive() do
		if not state.autoJoinEvent or (state.autoJoinDailyChallenge and dailyChallenge.canJoin()) then
			autoJoinRequested = false
		elseif not matchEnding and not autoJoinRequested and not autoJoinBusy then
			autoJoinRequested = true
			autoJoinBusy = true
			local ok, result = invokeRet("request_matchmaking", "summer2_event")
			autoJoinBusy = false
			if not ok then
				warn("[SatisHub] Auto Join: pedido falhou ou remote indisponivel: " .. tostring(result))
			else
				print("[SatisHub] Auto Join: pedido enviado; a aguardar pelo jogo.")
			end
		end
		task.wait(1)
	end
end)

-- Daily Challenge: send exactly one matchmaking request for each activation.
-- Do not issue requests while the match is ending; Daily Challenge has priority over Event.
local function runDailyChallengeJoin()
    local requested = false
    while alive() do
        if not state.autoJoinDailyChallenge then
            requested = false
        elseif not dailyChallenge.canJoin() then
            requested = false -- Completed: block requests, then permit a fresh attempt after reset.
        elseif not requested and not matchEnding then
            requested = true
            local ok, result = invokeRet("request_matchmaking", "__DAILY_CHALLENGE")
            if not ok or result == false then
                warn("[SatisHub] Daily Challenge: matchmaking failed: " .. tostring(result))
            else
                dailyChallenge.requested()
                print("[SatisHub] Daily Challenge: matchmaking requested; waiting for server.")
            end
        end
        task.wait(1)
    end
end
task.spawn(runDailyChallengeJoin)

-- LOADING screen (shown after the notice / when the script is executed)
task.spawn(function()
	local card = Instance.new("Frame")
	card.Size = UDim2.fromOffset(300, 0)
	card.AutomaticSize = Enum.AutomaticSize.Y
	card.AnchorPoint = Vector2.new(0.5, 0.5)
	card.Position = UDim2.fromScale(0.5, 0.5)
	card.BackgroundColor3 = currentTheme
	card.BorderSizePixel = 0
	card.Parent = gui
	corner(card, 14)
	addRgbStroke(card, 3)

	local cardLayout = Instance.new("UIListLayout")
	cardLayout.Padding = UDim.new(0, 8)
	cardLayout.SortOrder = Enum.SortOrder.LayoutOrder
	cardLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	cardLayout.Parent = card

	local cardPad = Instance.new("UIPadding")
	cardPad.PaddingTop = UDim.new(0, 18)
	cardPad.PaddingBottom = UDim.new(0, 18)
	cardPad.Parent = card

	if iconAsset then
		local logo = Instance.new("ImageLabel")
		logo.Size = UDim2.fromOffset(64, 64)
		logo.BackgroundTransparency = 1
		logo.Image = iconAsset
		logo.ScaleType = Enum.ScaleType.Crop
		logo.LayoutOrder = 1
		logo.Parent = card
		corner(logo, 14)
	end

	local function line(text, order, size, color, font)
		local l = Instance.new("TextLabel")
		l.Size = UDim2.new(1, -30, 0, size + 6)
		l.BackgroundTransparency = 1
		l.Text = text
		l.TextColor3 = color
		l.Font = font
		l.TextSize = size
		l.LayoutOrder = order
		l.Parent = card
		return l
	end

	line("SatisHub", 2, 20, WHITE, Enum.Font.GothamBold)
	line("Thank you for using my script!", 3, 13, Color3.fromRGB(200, 205, 220), Enum.Font.Gotham)

	local track = Instance.new("Frame")
	track.Size = UDim2.new(1, -50, 0, 8)
	track.BackgroundColor3 = Color3.fromRGB(45, 45, 58)
	track.BorderSizePixel = 0
	track.LayoutOrder = 4
	track.Parent = card
	corner(track, 4)

	local fill = Instance.new("Frame")
	fill.Size = UDim2.fromScale(0, 1)
	fill.BackgroundColor3 = WHITE
	fill.BorderSizePixel = 0
	fill.Parent = track

	local fillGrad = Instance.new("UIGradient")
	fillGrad.Color = RAINBOW
	fillGrad.Parent = fill
	corner(fill, 4)

	local status = line("Loading...", 5, 11, Color3.fromRGB(150, 155, 170), Enum.Font.Gotham)

	local steps = {
		{ 0.35, "Loading modules..." },
		{ 0.7, "Preparing menu..." },
		{ 1, "Ready!" },
	}
	for _, st in ipairs(steps) do
		status.Text = st[2]
		TweenService:Create(
			fill,
			TweenInfo.new(0.8, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Size = UDim2.fromScale(st[1], 1) }
		):Play()
		task.wait(0.9)
	end

	card:Destroy()
	-- Start minimized after loading, except when the user must enter the key.
    if keyPage.Visible then
        frame.Visible = true
        miniIcon.Visible = false
    else
        setMinimized(true)
    end
end)
