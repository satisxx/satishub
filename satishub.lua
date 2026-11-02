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
-- Change KEY_AUTH_VERSION whenever you publish a new SatisHub version.
local KEY_AUTH_VERSION = "SatisHub-V3.7-AnimePurple"
local KEY_SESSION_SECONDS = 24 * 60 * 60

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
    keyValidUntil = 0,
    keyAuthVersion = "",
    earlyNoticeSeen = false,
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

-- ===== Daily Challenge: global reset at 00:00 Europe/Lisbon =====
-- Europe/Lisbon observes GMT in winter and GMT+1 during summer time.
-- Every player uses the same absolute Unix reset timestamp, regardless of device timezone.
local dailyChallenge = {}
do
    local function now() return os.time() end
    local function isLisbonDST(ts)
        local d = os.date("!*t", ts)
        local month, day, hour = d.month, d.day, d.hour
        if month < 3 or month > 10 then return false end
        if month > 3 and month < 10 then return true end
        -- EU clock changes occur at 01:00 UTC on the LAST Sunday of March/October.
        local on31 = os.date("!*t", ts + (31 - day) * 86400)
        local lastSunday = 31 - (on31.wday - 1)
        if month == 3 then
            return day > lastSunday or (day == lastSunday and hour >= 1)
        end
        return day < lastSunday or (day == lastSunday and hour < 1)
    end
    local function nextResetAt(ts)
        -- First estimate next local midnight using the offset at the current instant.
        local offsetNow = isLisbonDST(ts) and 3600 or 0
        local secondsIntoDay = (ts + offsetNow) % 86400
        local estimate = ts + (86400 - secondsIntoDay)
        -- A DST switch near midnight can shift the target by one hour.
        local best
        for delta = -3600, 3600, 3600 do
            local candidate = estimate + delta
            local offsetAtCandidate = isLisbonDST(candidate) and 3600 or 0
            if candidate > ts and (candidate + offsetAtCandidate) % 86400 == 0 then
                if not best or candidate < best then best = candidate end
            end
        end
        return best or estimate
    end
    local function refreshReset()
        local current = now()
        local target = nextResetAt(current)
        local oldTarget = tonumber(state.dailyResetAt) or 0
        local oldLock = tonumber(state.dailyLockUntil) or 0
        -- Preserve completion only if it was locked for a period that has not ended.
        -- Earlier versions could store an incorrect long future deadline.
        if oldLock > current then
            if oldTarget > 0 and oldTarget <= current then
                state.dailyLockUntil = 0
                state.dailyCompletedResetAt = 0
                state.dailyJoinPending = false
            else
                state.dailyLockUntil = target
                state.dailyCompletedResetAt = target
            end
        elseif oldLock ~= 0 then
            state.dailyLockUntil = 0
            state.dailyCompletedResetAt = 0
            state.dailyJoinPending = false
        end
        if oldTarget ~= target then
            state.dailyResetAt = target
            saveSettings()
        end
        return target
    end
    function dailyChallenge.remaining()
        return math.max(0, refreshReset() - now())
    end
    function dailyChallenge.completed()
        refreshReset()
        return (tonumber(state.dailyLockUntil) or 0) > now()
    end
    function dailyChallenge.canJoin()
        return not dailyChallenge.completed()
    end
    function dailyChallenge.markFinished()
        if state.dailyJoinPending then
            dailyChallenge.markCompleted('game_finished')
        end
    end
    function dailyChallenge.markCompleted(reason)
        local target = refreshReset()
        state.dailyResetAt = target
        state.dailyLockUntil = target
        state.dailyCompletedResetAt = target
        state.dailyJoinPending = false
        saveSettings()
        print('[SatisHub] Daily Challenge COMPLETED (' .. tostring(reason) .. ') until next Lisbon midnight UTC timestamp ' .. tostring(target))
    end
    function dailyChallenge.requested()
        state.dailyJoinPending = true
        saveSettings()
    end
    -- Listen for server timer for diagnostics only: the requested reset is
    -- the shared 00:00 Europe/Lisbon instant, not a sliding 24h estimate.
    local serverEvents = endpoints and endpoints:FindFirstChild('server_to_client')
    task.spawn(function()
        if not serverEvents then return end
        local ev = serverEvents:WaitForChild('daily_challenge_remaining_time_changed', 30)
        if ev and ev:IsA('RemoteEvent') then
            ev.OnClientEvent:Connect(function(seconds)
                if not alive() then return end
                local serverRemaining = tonumber(seconds)
                if serverRemaining and math.abs(serverRemaining - dailyChallenge.remaining()) > 180 then
                    warn('[SatisHub] Daily server countdown differs from configured 00:00 Lisbon reset by over 3 minutes: ' .. tostring(serverRemaining))
                end
            end)
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
    refreshReset()
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
local SCRIPT_BUILD = "SatisHub-V3.7-AnimePurple"
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
-- Positions belong to a specific map/server; carrying them between Roblox
-- places causes placement attempts at coordinates from the previous map.
if learned.positionsPlaceId ~= game.PlaceId or learned.positionsJobId ~= game.JobId then
    learned.positions = {}
    learned.positionsPlaceId = game.PlaceId
    learned.positionsJobId = game.JobId
end

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
local ON_COLOR = Color3.fromRGB(145, 38, 245)
local ERROR_COLOR = Color3.fromRGB(240, 70, 70)
local OFF_STROKE = Color3.fromRGB(86, 43, 127)
local DEFAULT_THEME = Color3.fromRGB(15, 5, 29)
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
-- V3.7 defaults to the purple theme irrespective of old saved V3 blue colors.
-- The Settings palette still allows manual recoloring in the current session.

-- Icon image (embedded, shown when the hub is minimized)
local ICON_B64 = "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"

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

-- Embedded Anime Purple / Meliodas banner from the supplied visual reference.
-- No external image URL or Roblox asset upload is needed.
local ANIME_PURPLE_BANNER_B64 = "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"
local function loadAnimePurpleBanner()
    if type(writefile) ~= "function" then return nil end
    local getAsset = getcustomasset or getsynasset
    if type(getAsset) ~= "function" then return nil end
    local ok, asset = pcall(function()
        local name = "satishub_anime_purple_v37.jpg"
        writefile(name, b64decode(ANIME_PURPLE_BANNER_B64))
        return getAsset(name)
    end)
    if ok then return asset end
    return nil
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
for _, n in ipairs({ "SatisHub", "SatisHubBlack", "SatisHubESP", "SatisHubFarmingStats" }) do
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

    -- Close the stats overlay even when the minimize hotkey is unavailable.
    local disableFromStats
    local panel = Instance.new("Frame")
    panel.AnchorPoint = Vector2.new(0.5, 0.5)
    panel.Position = UDim2.fromScale(0.5, 0.5)
    panel.Size = UDim2.fromOffset(340, 295)
    panel.BackgroundColor3 = Color3.fromRGB(18, 5, 33)
    panel.BorderSizePixel = 0
    panel.Parent = statsGui
    Instance.new("UICorner", panel).CornerRadius = UDim.new(0, 14)
    local closeStats = Instance.new("TextButton")
    closeStats.Name = "CloseStats"
    closeStats.AnchorPoint = Vector2.new(1, 0)
    closeStats.Position = UDim2.new(1, -8, 0, 7)
    closeStats.Size = UDim2.fromOffset(28, 28)
    closeStats.Text = "X"
    closeStats.Font = Enum.Font.GothamBold
    closeStats.TextSize = 14
    closeStats.TextColor3 = Color3.fromRGB(255, 255, 255)
    closeStats.BackgroundColor3 = Color3.fromRGB(84, 29, 121)
    closeStats.BorderSizePixel = 0
    closeStats.ZIndex = 12
    closeStats.Parent = panel
    Instance.new("UICorner", closeStats).CornerRadius = UDim.new(0, 7)
    closeStats.MouseButton1Click:Connect(function()
        if disableFromStats then disableFromStats() end
    end)
    local outline = Instance.new("UIStroke", panel)
    outline.Color = Color3.fromRGB(181, 63, 255)
    outline.Thickness = 2
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
    label("SATISHUB  |  FARMING STATS", 1, 19, Color3.fromRGB(220, 152, 255))
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
    local function applyBoost(enabled)
        statsGui.Enabled = enabled
        setLowGraphics(enabled)
        black.Visible = enabled
        local ok, err = pcall(function()
            RunService:Set3dRenderingEnabled(not enabled)
        end)
        if not ok then warn("[SatisHub] FPS Boost: " .. tostring(err)) end
        if enabled then display() end
    end
    disableFromStats = function()
        -- Also update the Settings toggle when available.
        if type(env.SatisHubSetFpsBoostOff) == "function" then
            env.SatisHubSetFpsBoostOff()
        else
            state.fpsBoost = false
            applyBoost(false)
            saveSettings()
        end
    end
    return applyBoost
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

-- ===== First-time notice (only after successful key verification) =====
local function showFirstKeyNotice()
    if state.earlyNoticeSeen then return end
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
	if not alive() then return end
    state.earlyNoticeSeen = true
    saveSettings()
end

local frame = Instance.new("Frame")
frame.Size = UDim2.fromOffset(430, 0)
frame.AutomaticSize = Enum.AutomaticSize.Y
frame.Position = UDim2.new(0, 32, 0.5, -320)
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
        ColorSequenceKeypoint.new(0, Color3.fromRGB(27, 8, 49)),
        ColorSequenceKeypoint.new(1, Color3.fromRGB(10, 3, 20))
    })
    panelGradient.Parent = frame
end
do
    local st = Instance.new("UIStroke")
    st.Name = "AnimePurpleOuterGlow"
    st.Color = Color3.fromRGB(175, 64, 255)
    st.Thickness = 2.1
    st.Transparency = 0.04
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
	return Color3.fromRGB(39, 16, 65)
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
		o.BackgroundColor3 = Color3.fromRGB(45, 18, 69)
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

-- V3.8: Roblox-native icons. Do not rely on Unicode glyphs: some executors/fonts
-- render them as missing-character squares. Everything below is built from Frames.
local function drawAnimeIcon(parent, kind, x, y, pixelSize, tint)
    local holder = Instance.new("Frame")
    holder.Name = "AnimeVectorIcon"
    holder.BackgroundTransparency = 1
    holder.BorderSizePixel = 0
    holder.Position = UDim2.fromOffset(x, y)
    holder.Size = UDim2.fromOffset(pixelSize, pixelSize)
    holder.Parent = parent
    local u = pixelSize / 24

    local function bar(cx, cy, w, h, rotation, rounded)
        local f = Instance.new("Frame")
        f.AnchorPoint = Vector2.new(0.5, 0.5)
        f.Position = UDim2.fromOffset(cx * u, cy * u)
        f.Size = UDim2.fromOffset(math.max(w * u, 1), math.max(h * u, 1))
        f.Rotation = rotation or 0
        f.BorderSizePixel = 0
        f.BackgroundColor3 = tint
        f.Parent = holder
        if rounded then
            local c = Instance.new("UICorner")
            c.CornerRadius = UDim.new(0, math.max(1, rounded * u))
            c.Parent = f
        end
        return f
    end
    local function outline(cx, cy, w, h, radius, thickness)
        local f = Instance.new("Frame")
        f.AnchorPoint = Vector2.new(0.5, 0.5)
        f.Position = UDim2.fromOffset(cx * u, cy * u)
        f.Size = UDim2.fromOffset(w * u, h * u)
        f.BackgroundTransparency = 1
        f.BorderSizePixel = 0
        f.Parent = holder
        if radius then
            local c = Instance.new("UICorner")
            c.CornerRadius = UDim.new(0, radius * u)
            c.Parent = f
        end
        local stroke = Instance.new("UIStroke")
        stroke.Color = tint
        stroke.Thickness = math.max(1.2, (thickness or 1.8) * u)
        stroke.Parent = f
        return f
    end

    if kind == "main" then
        bar(7, 8, 12, 2.4, -44, 1)
        bar(17, 8, 12, 2.4, 44, 1)
        bar(5.2, 15, 2.4, 10, 0, 1)
        bar(18.8, 15, 2.4, 10, 0, 1)
        bar(12, 19.4, 15, 2.4, 0, 1)
        bar(12, 16, 4, 8, 0, 1)
    elseif kind == "event" or kind == "calendar" then
        outline(12, 13, 18, 17, 3, 1.8)
        bar(12, 9, 17, 2.1, 0, 1)
        bar(8, 4, 2.5, 5.5, 0, 1)
        bar(16, 4, 2.5, 5.5, 0, 1)
        bar(8, 14, 3, 3, 0, 1)
        bar(13, 14, 3, 3, 0, 1)
    elseif kind == "player" then
        local head = bar(12, 7.1, 10, 10, 0, 8)
        bar(12, 19, 18, 8, 0, 6)
    elseif kind == "settings" then
        -- Sliders: recognisable, evenly spaced, no special font required.
        bar(12, 5, 20, 2, 0, 1)
        bar(12, 12, 20, 2, 0, 1)
        bar(12, 19, 20, 2, 0, 1)
        bar(8, 5, 5, 6, 0, 2)
        bar(16, 12, 5, 6, 0, 2)
        bar(10, 19, 5, 6, 0, 2)
    elseif kind == "about" then
        outline(12, 12, 19, 19, 12, 1.9)
        bar(12, 7, 3, 3, 0, 2)
        bar(12, 14, 2.5, 8, 0, 1)
    elseif kind == "play" then
        outline(12, 12, 19, 19, 12, 1.7)
        bar(11, 10, 2.2, 10, -43, 1)
        bar(11, 14, 2.2, 10, 43, 1)
    elseif kind == "skip" then
        for shift = 0, 6 do
            if shift == 0 or shift == 6 then
                bar(7 + shift, 9, 2.2, 9, -43, 1)
                bar(7 + shift, 15, 2.2, 9, 43, 1)
            end
        end
        bar(19.5, 12, 2.2, 13, 0, 1)
    elseif kind == "place" then
        outline(8, 8, 10, 10, 2.5, 1.7)
        outline(16, 16, 10, 10, 2.5, 1.7)
    elseif kind == "upgrade" then
        bar(12, 14, 2.5, 15, 0, 1)
        bar(8.2, 8.2, 2.5, 11, 45, 1)
        bar(15.8, 8.2, 2.5, 11, -45, 1)
    elseif kind == "leave" then
        outline(8, 12, 11, 18, 3, 1.7)
        bar(14, 12, 13, 2.3, 0, 1)
        bar(17, 9, 2.3, 8, -45, 1)
        bar(17, 15, 2.3, 8, 45, 1)
    elseif kind == "brand" then
        -- Four-point anime emblem composed entirely of Roblox frames.
        bar(12, 12, 5, 20, 45, 1)
        bar(12, 12, 5, 20, -45, 1)
        bar(12, 12, 5, 20, 135, 1)
        bar(12, 12, 5, 20, -135, 1)
        bar(12, 12, 5, 5, 45, 1)
    else
        bar(12, 12, 12, 12, 45, 2)
        bar(12, 12, 5, 5, 45, 1)
    end
    return holder
end

-- Flat button with a thin border. rgb = true gives it an RGB border (used by toggles when ON).
local function makeButton(parentObj, text, order, rgb)
	local b = Instance.new("TextButton")
	b.Size = UDim2.new(1, -24, 0, 44)
	b.BackgroundColor3 = btnColor()
	b.Text = text
	b.TextColor3 = WHITE
	b.Font = Enum.Font.GothamBold
	b.TextSize = 14
	b.BorderSizePixel = 0
	b.AutoButtonColor = false
	b.LayoutOrder = order or 0
	b.Parent = parentObj
	corner(b, 13)

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
    hoverStroke.Color = Color3.fromRGB(188, 78, 255)
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
-- Anime Purple row-style toggles: keep original state, storage, and callbacks.
local function makeToggle(parentObj, name, order, onChange, initial)
    local on = false
    local b, stroke, grad = makeButton(parentObj, "", order, true)
    b.Text = ""
    b.Size = UDim2.new(1, -28, 0, 48)
    b.BackgroundColor3 = Color3.fromRGB(28, 12, 48)
    stroke.Color = Color3.fromRGB(91, 40, 137)
    stroke.Thickness = 1.1
    grad.Enabled = false

    local iconKind = "diamond"
    if name:find("Skip") then iconKind = "skip"
    elseif name:find("Place") then iconKind = "place"
    elseif name:find("Upgrade") then iconKind = "upgrade"
    elseif name:find("Leave") then iconKind = "leave"
    elseif name:find("Daily") or name:find("Event") then iconKind = "calendar"
    elseif name:find("Start") then iconKind = "play" end
    local symbol = drawAnimeIcon(b, iconKind, 15, 13, 22, Color3.fromRGB(188, 79, 255))

    local nameLabel = Instance.new("TextLabel")
    nameLabel.Name = "OptionName"
    nameLabel.BackgroundTransparency = 1
    nameLabel.Position = UDim2.new(0, 47, 0, 0)
    nameLabel.Size = UDim2.new(1, -132, 1, 0)
    nameLabel.Font = Enum.Font.GothamMedium
    nameLabel.TextSize = 13
    nameLabel.TextColor3 = Color3.fromRGB(239, 231, 252)
    nameLabel.TextXAlignment = Enum.TextXAlignment.Left
    nameLabel.TextTruncate = Enum.TextTruncate.AtEnd
    nameLabel.Text = name
    nameLabel.Parent = b

    local switch = Instance.new("Frame")
    switch.Name = "AnimeSwitch"
    switch.AnchorPoint = Vector2.new(1, 0.5)
    switch.Position = UDim2.new(1, -14, 0.5, 0)
    switch.Size = UDim2.fromOffset(58, 28)
    switch.BorderSizePixel = 0
    switch.BackgroundColor3 = Color3.fromRGB(52, 32, 68)
    switch.Parent = b
    corner(switch, 15)

    local knob = Instance.new("Frame")
    knob.Name = "Knob"
    knob.Size = UDim2.fromOffset(22, 22)
    knob.Position = UDim2.new(0, 3, 0.5, -11)
    knob.BackgroundColor3 = Color3.fromRGB(248, 240, 255)
    knob.BorderSizePixel = 0
    knob.Parent = switch
    corner(knob, 11)
    local knobStroke = Instance.new("UIStroke")
    knobStroke.Color = Color3.fromRGB(207, 161, 254)
    knobStroke.Thickness = 1
    knobStroke.Parent = knob

    local function paint()
        local special = (name == "Auto Join Event")
        local accent = special and Color3.fromRGB(255, 143, 42) or Color3.fromRGB(156, 44, 246)
        local off = Color3.fromRGB(53, 33, 67)
        local target = on and accent or off
        -- Never animate on every theme refresh if there is no actual state change.
        if switch.BackgroundColor3 ~= target then
            TweenService:Create(switch, TweenInfo.new(0.24, Enum.EasingStyle.Quart, Enum.EasingDirection.Out), {BackgroundColor3 = target}):Play()
        end
        local targetPos = on and UDim2.new(1, -25, 0.5, -11) or UDim2.new(0, 3, 0.5, -11)
        if knob.Position ~= targetPos then
            TweenService:Create(knob, TweenInfo.new(0.26, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {Position = targetPos}):Play()
        end
        -- Vector icon is made of Frames; it does not require font glyph support.
        stroke.Color = on and accent or Color3.fromRGB(78, 37, 116)
        grad.Enabled = false -- Preserve the screenshot's single-tone purple look.
    end
    toggleRefreshers[#toggleRefreshers + 1] = paint
    local function set(v)
        on = v and true or false
        paint()
        onChange(on)
        saveSettings()
    end
    b.MouseButton1Click:Connect(function() set(not on) end)
    if initial then set(true) else paint() end
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
header.Size = UDim2.new(1, 0, 0, 92)
header.BackgroundColor3 = Color3.fromRGB(16, 6, 32)
header.BorderSizePixel = 0
header.LayoutOrder = 1
header.Parent = frame

local titulo = Instance.new("TextLabel")
titulo.Size = UDim2.new(1, -128, 0, 39)
titulo.Position = UDim2.new(0, 102, 0, 14)
titulo.BackgroundTransparency = 1
titulo.Text = "SatisHub V3"
titulo.TextColor3 = WHITE
titulo.TextXAlignment = Enum.TextXAlignment.Left
titulo.Font = Enum.Font.GothamBold
titulo.TextSize = 27
titulo.Parent = header
do
    local sub = Instance.new("TextLabel")
    sub.Size = UDim2.new(1,-126,0,18)
    sub.Position = UDim2.new(0,103,0,55)
    sub.Text = "ULTIMATE AUTOMATION HUB"
    sub.TextSize = 12
    sub.Font = Enum.Font.GothamMedium
    sub.TextXAlignment = Enum.TextXAlignment.Left
    sub.BackgroundTransparency = 1
    sub.TextColor3 = Color3.fromRGB(192,143,234)
    sub.Parent = header
end

-- Icon is drawn with Roblox frames, so it cannot render as a missing glyph.
do
    local brand = drawAnimeIcon(header, "brand", 24, 15, 63, Color3.fromRGB(191, 81, 255))
    brand.Name = "AnimePurpleLogo"
end

-- RGB title
local titleGrad = Instance.new("UIGradient")
titleGrad.Color = ColorSequence.new(Color3.fromRGB(250,235,255), Color3.fromRGB(219,170,255))
titleGrad.Parent = titulo
rgbGradients[#rgbGradients + 1] = titleGrad
titleGrad.Enabled = true

local minBtn = Instance.new("TextButton")
minBtn.Size = UDim2.fromOffset(36, 36)
minBtn.Position = UDim2.new(1, -99, 0, 25)
minBtn.BackgroundColor3 = btnColor()
minBtn.Text = "-"
minBtn.TextColor3 = WHITE
minBtn.Font = Enum.Font.GothamBold
minBtn.TextSize = 16
minBtn.BorderSizePixel = 0
minBtn.AutoButtonColor = false
minBtn.Parent = header
corner(minBtn, 11)
plainButtons[#plainButtons + 1] = minBtn
do
	local st = Instance.new("UIStroke")
	st.Color = OFF_STROKE
	st.Thickness = 1.5
	st.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	st.Parent = minBtn
end

-- Visual close control (minimizes instead of stopping farming tasks).
local animeCloseBtn = Instance.new("TextButton")
animeCloseBtn.Size = UDim2.fromOffset(36, 36)
animeCloseBtn.Position = UDim2.new(1, -48, 0, 25)
animeCloseBtn.BackgroundColor3 = Color3.fromRGB(47, 17, 69)
animeCloseBtn.Text = "X"
animeCloseBtn.TextSize = 17
animeCloseBtn.TextColor3 = WHITE
animeCloseBtn.Font = Enum.Font.GothamBold
animeCloseBtn.BorderSizePixel = 0
animeCloseBtn.AutoButtonColor = false
animeCloseBtn.Parent = header
corner(animeCloseBtn, 11)
do
    local outline = Instance.new("UIStroke")
    outline.Color = Color3.fromRGB(140, 59, 197)
    outline.Thickness = 1
    outline.Parent = animeCloseBtn
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
animeCloseBtn.MouseButton1Click:Connect(function()
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
userBar.Size = UDim2.new(1, 0, 0, 52)
userBar.BackgroundColor3 = Color3.fromRGB(24, 8, 43)
userBar.BorderSizePixel = 0
userBar.LayoutOrder = 3
userBar.Parent = frame
userBar.Visible = false

local avatar = Instance.new("ImageLabel")
avatar.Size = UDim2.fromOffset(18, 18)
avatar.Position = UDim2.new(0, 220, 0, 29)
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
userLabel.TextSize = 11
userLabel.Parent = userBar

do
    local ready = Instance.new("TextLabel")
    ready.Name = "AnimePurpleStatus"
    ready.Size = UDim2.new(0, 200, 0, 24)
    ready.Position = UDim2.new(0, 51, 0, 3)
    ready.BackgroundTransparency = 1
    ready.Font = Enum.Font.GothamBold
    ready.TextColor3 = Color3.fromRGB(234, 217, 255)
    ready.TextSize = 14
    ready.TextXAlignment = Enum.TextXAlignment.Left
    ready.Text = "Status: Ready"
    ready.Parent = userBar
    local light = Instance.new("Frame")
    light.Position = UDim2.new(0, 24, 0.5, -7)
    light.Size = UDim2.fromOffset(14, 14)
    light.BackgroundColor3 = Color3.fromRGB(32, 245, 110)
    light.BorderSizePixel = 0
    light.Parent = userBar
    Instance.new("UICorner", light).CornerRadius = UDim.new(1, 0)
    local version = Instance.new("TextLabel")
    version.Size = UDim2.fromOffset(83, 48)
    version.Position = UDim2.new(1, -96, 0, 0)
    version.BackgroundTransparency = 1
    version.Text = "v3.9.2"
    version.Font = Enum.Font.GothamBold
    version.TextColor3 = Color3.fromRGB(208, 156, 255)
    version.TextSize = 15
    version.Parent = userBar
end

-- Executor label: centered in the footer, with a safe fallback.
do
    local executorDisplay = tostring(execName or "unknown")
    if executorDisplay == "" or executorDisplay == "unknown" then
        executorDisplay = "Unknown Executor"
    end
    local executorLabel = Instance.new("TextLabel")
    executorLabel.Name = "ExecutorName"
    executorLabel.AnchorPoint = Vector2.new(0.5, 0.5)
    executorLabel.Position = UDim2.new(0.5, 0, 0.5, 0)
    executorLabel.Size = UDim2.new(0, 205, 0, 32)
    executorLabel.BackgroundTransparency = 1
    executorLabel.Text = "Executor: " .. executorDisplay
    executorLabel.Font = Enum.Font.GothamBold
    executorLabel.TextSize = 12
    executorLabel.TextColor3 = Color3.fromRGB(210, 166, 255)
    executorLabel.TextTruncate = Enum.TextTruncate.AtEnd
    executorLabel.TextXAlignment = Enum.TextXAlignment.Center
    executorLabel.ZIndex = 3
    executorLabel.Parent = userBar
end

-- Incognito hides account details from the SatisHub footer only.
local function refreshIncognito()
    avatar.Visible = not state.incognitoMode
    userLabel.Text = state.incognitoMode and "User: Hidden" or ("User: " .. Players.LocalPlayer.Name)
    userLabel.Position = UDim2.new(0, 51, 0, 27)
    userLabel.Size = UDim2.new(0, 163, 0, 22)
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
caixaKey.Size = UDim2.new(0, 360, 0, 42)
caixaKey.LayoutOrder = 1

local botaoKey = makeButton(keyPage, "Verify", 2)
botaoKey.Size = UDim2.new(0, 360, 0, 44)

-- Copies the official SatisHub Discord invite when the user requests a key.
local getKeyButton = makeButton(keyPage, "Get Key", 3)
getKeyButton.Size = UDim2.new(0, 360, 0, 44)
getKeyButton.MouseButton1Click:Connect(function()
    local url = "https://discord.gg/WvCUTSDSNT"
    local copy = setclipboard or toclipboard
    if type(copy) ~= "function" then
        warn("[SatisHub] Clipboard is not supported by this executor")
        return
    end
    local ok, err = pcall(copy, url)
    if ok then
        getKeyButton.Text = "Link Copied!"
        task.delay(2, function()
            if getKeyButton.Parent then getKeyButton.Text = "Get Key" end
        end)
    else
        warn("[SatisHub] Clipboard error: " .. tostring(err))
    end
end)

local msgKey = makeLabel(keyPage, "", 4)
msgKey.TextColor3 = ERROR_COLOR
msgKey.TextXAlignment = Enum.TextXAlignment.Center
msgKey.Size = UDim2.new(0, 360, 0, 25)

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
	b.Size = UDim2.new(1, -18, 0, 55)
	b.BackgroundColor3 = Color3.fromRGB(27, 12, 49)
	b.Text = ""
    b.TextXAlignment = Enum.TextXAlignment.Left
	b.TextColor3 = WHITE
	b.Font = Enum.Font.GothamBold
	b.TextSize = 16
	b.BorderSizePixel = 0
	b.AutoButtonColor = false
	b.LayoutOrder = order
	b.Parent = tabsRow
	corner(b, 13)
	local stroke, grad = addRgbStroke(b, 1.5)
	local underline = Instance.new("Frame")
    underline.Name = "SatisV31ActiveBar"
    underline.AnchorPoint = Vector2.new(0.5, 1)
    underline.Position = UDim2.new(0.5, 0, 1, -2)
    underline.Size = UDim2.new(0, 0, 0, 2)
    underline.BackgroundColor3 = Color3.fromRGB(203, 97, 255)
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
    local glyph = drawAnimeIcon(b, key, 14, 15, 23, Color3.fromRGB(204, 119, 255))
    glyph.Name = "SidebarGlyph"
    local label = Instance.new("TextLabel")
    label.Name = "SidebarLabel"
    label.Position = UDim2.fromOffset(51, 0)
    label.Size = UDim2.new(1, -61, 1, 0)
    label.BackgroundTransparency = 1
    label.Font = Enum.Font.GothamBold
    label.TextSize = 15
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.TextYAlignment = Enum.TextYAlignment.Center
    label.TextTruncate = Enum.TextTruncate.AtEnd
    label.TextColor3 = Color3.fromRGB(197, 148, 234)
    label.Text = text
    label.Parent = b
    tabInfo[key] = { btn = b, stroke = stroke, grad = grad, underline=underline, glyph=glyph, label=label }
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
            BackgroundColor3 = active and Color3.fromRGB(89, 23, 139) or Color3.fromRGB(26, 9, 47),
            TextColor3 = active and Color3.fromRGB(251, 238, 255) or Color3.fromRGB(197, 148, 234)
        }):Play()
        info.grad.Enabled = active and state.rgbEnabled
        info.label.TextColor3 = active and Color3.fromRGB(251, 238, 255) or Color3.fromRGB(197, 148, 234)
        info.stroke.Color = active and Color3.fromRGB(189, 75, 255) or OFF_STROKE
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
    local dailyStatus = makeLabel(mainPage, 'Daily reset (Lisbon 00:00): calculating...', 3.7)
    dailyStatus.TextWrapped = true
    dailyStatus.Size = UDim2.new(1, -20, 0, 26)
    task.spawn(function()
        while alive() do
            local rem = dailyChallenge.remaining()
            if rem then
                local h = math.floor(rem / 3600)
                local m = math.floor(rem / 60) % 60
                local sec = rem % 60
                dailyStatus.Text = ('Daily reset (Lisbon): %02d:%02d:%02d | %s'):format(
                    h, m, sec, dailyChallenge.completed() and 'COMPLETED' or 'AVAILABLE')
            else
                dailyStatus.Text = dailyChallenge.completed() and 'Daily: COMPLETED | timer awaiting server' or 'Daily reset (Lisbon): calculating...'
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
gameBackBtn.Text = "<"
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
		corner(b, 13)
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
		b.Text = g.name .. "  -  " .. g.desc
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
local fpsToggleButton, fpsToggleSetter = makeToggle(settingsPage, "FPS BOOST", 0, function(v)
    state.fpsBoost = v
    saveSettings()
    setFpsBoost(v)
end, fromQueue and state.fpsBoost == true)
env.SatisHubSetFpsBoostOff = function()
    if alive() then fpsToggleSetter(false) end
end
-- A manual launch must also restore the 3D renderer, which can remain disabled
-- from a prior execution or a teleport when a previous GUI was destroyed.
if not (fromQueue and state.fpsBoost == true) then
    pcall(function() RunService:Set3dRenderingEnabled(true) end)
end

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
makeLabel(settingsPage, "BUILD: V3.7 Anime Purple | Anti-AFK", 8)

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

makeText(aboutPage, "SatisHub V3.7  |  Anime Purple", 1, 17, WHITE, true)
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

-- ===== V3.7 ANIME PURPLE: layout only. All pages and their callbacks are kept. =====
local animeUI = {}
do
    -- The key page stays outside the app shell until authentication succeeds.
    animeUI.shell = Instance.new("Frame")
    animeUI.shell.Name = "AnimePurpleShell"
    animeUI.shell.LayoutOrder = 2
    animeUI.shell.Size = UDim2.new(1, 0, 0, 492)
    animeUI.shell.BackgroundTransparency = 1
    animeUI.shell.Visible = false
    animeUI.shell.Parent = body

    local side = Instance.new("Frame")
    side.Name = "AnimePurpleSidebar"
    side.Size = UDim2.new(0, 184, 1, 0)
    side.Position = UDim2.fromOffset(0, 0)
    side.BackgroundColor3 = Color3.fromRGB(19, 5, 35)
    side.BorderSizePixel = 0
    side.Parent = animeUI.shell
    local sideLine = Instance.new("Frame")
    sideLine.Name = "PurpleDivider"
    sideLine.Position = UDim2.new(1, -1, 0, 13)
    sideLine.Size = UDim2.new(0, 1, 1, -26)
    sideLine.BackgroundColor3 = Color3.fromRGB(87, 29, 128)
    sideLine.BorderSizePixel = 0
    sideLine.Parent = side

    tabsRow.Parent = side
    tabsRow.Position = UDim2.fromOffset(0, 8)
    tabsRow.Size = UDim2.new(1, 0, 0, 385)
    tabsRow.BackgroundTransparency = 1
    tabsLayout.FillDirection = Enum.FillDirection.Vertical
    tabsLayout.Padding = UDim.new(0, 10)
    tabsLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
    tabsLayout.VerticalAlignment = Enum.VerticalAlignment.Top
    tabsPad.PaddingTop = UDim.new(0, 5)
    tabsPad.PaddingLeft = UDim.new(0, 9)
    tabsPad.PaddingRight = UDim.new(0, 9)

    local sideDecoration = Instance.new("TextLabel")
    sideDecoration.Name = "SidebarCaption"
    sideDecoration.Position = UDim2.new(0, 25, 1, -53)
    sideDecoration.Size = UDim2.new(1, -30, 0, 29)
    sideDecoration.BackgroundTransparency = 1
    sideDecoration.Text = "ANIME PURPLE"
    sideDecoration.Font = Enum.Font.GothamBold
    sideDecoration.TextSize = 10
    sideDecoration.TextColor3 = Color3.fromRGB(160, 81, 210)
    sideDecoration.TextXAlignment = Enum.TextXAlignment.Left
    sideDecoration.Parent = side

    local right = Instance.new("Frame")
    right.Name = "AnimePurpleContent"
    right.Position = UDim2.fromOffset(196, 8)
    right.Size = UDim2.new(1, -207, 1, -16)
    right.BackgroundColor3 = Color3.fromRGB(24, 7, 45)
    right.BorderSizePixel = 0
    right.ClipsDescendants = true
    right.Parent = animeUI.shell
    corner(right, 20)
    local rStroke = Instance.new("UIStroke")
    rStroke.Color = Color3.fromRGB(109, 43, 174)
    rStroke.Thickness = 1.3
    rStroke.Parent = right

    local backdrop = Instance.new("Frame")
    backdrop.Size = UDim2.new(1, 0, 0, 170)
    backdrop.BackgroundColor3 = Color3.fromRGB(34, 6, 64)
    backdrop.BorderSizePixel = 0
    backdrop.Parent = right
    local bgGradient = Instance.new("UIGradient")
    bgGradient.Rotation = 0
    bgGradient.Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0, Color3.fromRGB(30, 8, 54)),
        ColorSequenceKeypoint.new(0.55, Color3.fromRGB(72, 18, 113)),
        ColorSequenceKeypoint.new(1, Color3.fromRGB(25, 5, 50))
    })
    bgGradient.Parent = backdrop

    local bannerAsset = loadAnimePurpleBanner()
    if bannerAsset then
        local banner = Instance.new("ImageLabel")
        banner.Name = "MeliodasAnimeBackground"
        banner.Size = UDim2.new(1, 0, 0, 186)
        banner.Position = UDim2.fromOffset(0, 0)
        banner.BackgroundTransparency = 1
        banner.Image = bannerAsset
        banner.ImageTransparency = 0.08
        banner.ScaleType = Enum.ScaleType.Crop
        banner.Parent = right
    end
    -- Soft fade under the character, so controls remain legible.
    local fade = Instance.new("Frame")
    fade.Name = "AnimePurpleBannerFade"
    fade.Position = UDim2.fromOffset(0, 118)
    fade.Size = UDim2.new(1, 0, 0, 89)
    fade.BackgroundColor3 = Color3.fromRGB(24, 7, 45)
    fade.BorderSizePixel = 0
    fade.Parent = right
    local fadeG = Instance.new("UIGradient")
    fadeG.Rotation = 90
    fadeG.Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 1),
        NumberSequenceKeypoint.new(1, 0)
    })
    fadeG.Parent = fade

    animeUI.pageTitle = Instance.new("TextLabel")
    animeUI.pageTitle.Name = "AnimePageTitle"
    animeUI.pageTitle.Size = UDim2.new(1, -66, 0, 43)
    animeUI.pageTitle.Position = UDim2.fromOffset(62, 18)
    animeUI.pageTitle.BackgroundTransparency = 1
    animeUI.pageTitle.Text = "Main"
    animeUI.pageTitle.TextXAlignment = Enum.TextXAlignment.Left
    animeUI.pageTitle.TextColor3 = Color3.fromRGB(250, 238, 255)
    animeUI.pageTitle.Font = Enum.Font.GothamBold
    animeUI.pageTitle.TextSize = 26
    animeUI.pageTitle.TextStrokeColor3 = Color3.fromRGB(17, 4, 29)
    animeUI.pageTitle.TextStrokeTransparency = 0.47
    animeUI.pageTitle.Parent = right
    animeUI.pageIcon = drawAnimeIcon(right, "main", 25, 26, 27, Color3.fromRGB(192, 79, 255))
    animeUI.pageIcon.Name = "AnimePageIcon"

    animeUI.pageDesc = Instance.new("TextLabel")
    animeUI.pageDesc.Name = "AnimePageDesc"
    animeUI.pageDesc.Position = UDim2.fromOffset(27, 57)
    animeUI.pageDesc.Size = UDim2.new(1, -45, 0, 27)
    animeUI.pageDesc.BackgroundTransparency = 1
    animeUI.pageDesc.Text = "Core automation features"
    animeUI.pageDesc.Font = Enum.Font.GothamMedium
    animeUI.pageDesc.TextSize = 13
    animeUI.pageDesc.TextXAlignment = Enum.TextXAlignment.Left
    animeUI.pageDesc.TextColor3 = Color3.fromRGB(217, 162, 254)
    animeUI.pageDesc.Parent = right

    animeUI.scroll = Instance.new("ScrollingFrame")
    animeUI.scroll.Name = "AnimePurplePageScroll"
    animeUI.scroll.Position = UDim2.fromOffset(13, 133)
    animeUI.scroll.Size = UDim2.new(1, -26, 1, -146)
    animeUI.scroll.BackgroundTransparency = 1
    animeUI.scroll.BorderSizePixel = 0
    animeUI.scroll.ScrollBarThickness = 3
    animeUI.scroll.ScrollBarImageColor3 = Color3.fromRGB(184, 76, 255)
    animeUI.scroll.CanvasSize = UDim2.new(0,0,0,0)
    animeUI.scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
    animeUI.scroll.ScrollingDirection = Enum.ScrollingDirection.Y
    animeUI.scroll.Parent = right
    local pagesLayout = Instance.new("UIListLayout")
    pagesLayout.SortOrder = Enum.SortOrder.LayoutOrder
    pagesLayout.Padding = UDim.new(0, 5)
    pagesLayout.Parent = animeUI.scroll
    for _, p in ipairs({mainPage, eventPage, playerPage, settingsPage, aboutPage}) do
        p.Parent = animeUI.scroll
        p.Size = UDim2.new(1, -4, 0, 0)
        p.BackgroundTransparency = 1
    end
end

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
    if animeUI.pageTitle then
        local titleData = ({
            main = {"Main", "Core automation features"},
            event = {"Evento", "Event and card automation"},
            player = {"Player", "Player tools and mini games"},
            settings = {"Settings", "Customize your SatisHub"},
            about = {"About", "Script information and credits"}
        })[name]
        animeUI.pageTitle.Text = titleData[1]
        if animeUI.pageIcon then
            animeUI.pageIcon:Destroy()
            animeUI.pageIcon = drawAnimeIcon(animeUI.pageTitle.Parent, name, 25, 26, 27, Color3.fromRGB(192, 79, 255))
            animeUI.pageIcon.Name = "AnimePageIcon"
        end
        animeUI.pageDesc.Text = titleData[2]
        animeUI.scroll.CanvasPosition = Vector2.new(0, 0)
        local scTitle = animeUI.pageTitle:FindFirstChild("AnimeTitleScale")
        if not scTitle then
            scTitle = Instance.new("UIScale")
            scTitle.Name = "AnimeTitleScale"
            scTitle.Parent = animeUI.pageTitle
        end
        scTitle.Scale = 0.95
        TweenService:Create(scTitle, TweenInfo.new(0.28, Enum.EasingStyle.Quart, Enum.EasingDirection.Out), {Scale = 1}):Play()
    end
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

-- Key session: valid for 24 hours OR until a new script version is published.
-- Existing users must verify once to create the new session record.
local function hasValidKeySession()
    return state.savedKey == KEY
        and state.keyAuthVersion == KEY_AUTH_VERSION
        and tonumber(state.keyValidUntil) ~= nil
        and os.time() < tonumber(state.keyValidUntil)
end

local keyVerified = false
local function unlockMenu()
    keyPage.Visible = false
    animeUI.shell.Visible = true
    userBar.Visible = true
    frame.Size = UDim2.fromOffset(770, 0)
    tabsRow.Visible = true
    showTab("main")
    setMinimized(true)
end

local function verificar()
    if keyVerified then return end
    if normalizeKey(caixaKey.Text) == KEY then
        keyVerified = true
        msgKey.Text = "Success!"
        msgKey.TextColor3 = Color3.fromRGB(80, 230, 130)
        botaoKey.Text = "Success!"
        caixaKey.TextEditable = false
        state.savedKey = KEY
        state.keyAuthVersion = KEY_AUTH_VERSION
        state.keyValidUntil = os.time() + KEY_SESSION_SECONDS
        saveSettings()

        task.spawn(function()
            task.wait(2)
            if not alive() or not gui.Parent then return end
            -- Early Version notice is shown ONLY after the first correct key.
            -- It never appears again once Continue has been clicked.
            showFirstKeyNotice()
            if not alive() or not gui.Parent then return end
            unlockMenu()
        end)
    else
        msgKey.TextColor3 = ERROR_COLOR
        msgKey.Text = "Invalid key"
    end
end

botaoKey.MouseButton1Click:Connect(verificar)
caixaKey.FocusLost:Connect(function(enter)
    if enter then verificar() end
end)

-- Manual launches and queued teleports both reuse the same verified session.
if hasValidKeySession() then
    keyVerified = true
    unlockMenu()
else
    -- Leave the key on screen when the 24h period expires or the build changes.
    state.savedKey = ""
    state.keyAuthVersion = ""
    state.keyValidUntil = 0
    saveSettings()
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

-- ===== Auto Leave V3.9.2: bounded recovery for stuck result screens =====
-- A finished match can leave InvokeServer pending (especially after repeated runs).
-- Keep attempts bounded, and never call during an active match.
local function startAutoLeave()
    local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui", 15)
    local teleporting = false
    local finishing = false
    local startedAt = 0
    local attempts = 0
    local firstPendingAt = nil
    local lastAttemptAt = 0
    local MAX_ATTEMPTS = 3
    local RETRY_GAP = 20

    pcall(function()
        Players.LocalPlayer.OnTeleport:Connect(function(phase)
            if phase == Enum.TeleportState.Started or phase == Enum.TeleportState.InProgress then
                teleporting = true
                print("[SatisHub] Auto Leave: teleport started")
            end
        end)
    end)

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
            -- Some result GUIs use TextLabels inside image buttons.
            if (obj:IsA("TextButton") or obj:IsA("TextLabel")) and visible(obj) then
                local t = tostring(obj.Text):lower():gsub("%s+", " ")
                if t:find("return to lobby", 1, true) then lobby = true end
                if t == "replay" then replay = true end
                if lobby and replay then return true end
            end
        end
        return false
    end

    local function beginEnding(reason)
        if finishing or teleporting or not alive() or not state.autoLeave then return end
        finishing = true
        matchEnding = true
        startedAt = os.clock()
        print("[SatisHub] Auto Leave: results detected (" .. tostring(reason) .. ")")
    end

    local folder = endpoints and endpoints:FindFirstChild("server_to_client")
    local event = folder and folder:FindFirstChild("game_finished")
    if event and event:IsA("RemoteEvent") then
        event.OnClientEvent:Connect(function()
            if alive() and state.autoLeave then beginEnding("game_finished") end
        end)
    else
        warn("[SatisHub] Auto Leave: waiting for results GUI (game_finished missing)")
    end

    local function attemptLeave()
        attempts = attempts + 1
        lastAttemptAt = os.clock()
        local thisAttempt = attempts
        local remoteFolder = ReplicatedStorage:FindFirstChild("endpoints")
        remoteFolder = remoteFolder and remoteFolder:FindFirstChild("client_to_server")
        local remote = remoteFolder and remoteFolder:FindFirstChild("teleport_back_to_lobby")
        if not remote or not remote:IsA("RemoteFunction") then
            warn("[SatisHub] Auto Leave: request " .. thisAttempt .. ": remote not available")
            return
        end
        if not firstPendingAt then firstPendingAt = os.clock() end
        print(("[SatisHub] Auto Leave: sending request %d/%d"):format(thisAttempt, MAX_ATTEMPTS))
        task.spawn(function()
            local ok, reply = pcall(function() return remote:InvokeServer() end)
            if not alive() then return end
            if ok then
                print(("[SatisHub] Auto Leave: reply to request %d: %s"):format(thisAttempt, tostring(reply)))
            else
                warn(("[SatisHub] Auto Leave: request %d failed: %s"):format(thisAttempt, tostring(reply)))
            end
        end)
    end

    task.spawn(function()
        local seen = 0
        while alive() do
            if teleporting or not state.autoLeave then
                seen = 0
            else
                local hasResults = endScreenShown()
                seen = hasResults and (seen + 1) or 0
                if not finishing and seen >= 2 then beginEnding("results GUI") end
                if finishing and (os.clock() - startedAt) >= 3 then
                    if attempts == 0 and hasResults then
                        attemptLeave()
                    elseif attempts > 0 and attempts < MAX_ATTEMPTS and hasResults
                        and os.clock() - lastAttemptAt >= RETRY_GAP then
                        warn("[SatisHub] Auto Leave: result screen still visible; limited retry")
                        attemptLeave()
                    elseif attempts == MAX_ATTEMPTS and hasResults
                        and os.clock() - lastAttemptAt >= RETRY_GAP then
                        warn("[SatisHub] Auto Leave: server has not teleported. Try Return to Lobby manually; further requests disabled.")
                        -- Avoid repeating this warning indefinitely.
                        lastAttemptAt = os.clock() + 999999
                    end
                end
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
    -- Search from actual successful placements first, then owned units, then
    -- map/other-unit anchors. A tiny UI radius cannot trap placement forever.
    local centers = {}
    local function addCenter(p)
        if typeof(p) ~= "Vector3" then return end
        for _, previous in ipairs(centers) do
            if flatDist(previous, p) < 2.5 then return end
        end
        if #centers < 65 then centers[#centers + 1] = p end
    end
    for _, p in ipairs(goodSpots) do addCenter(p) end
    for _, p in ipairs(learned.positions) do addCenter(p) end

    local folder = getUnitsFolder()
    if folder then
        for _, unit in ipairs(folder:GetChildren()) do
            if unitOwnedByMe(unit) == true then
                addCenter(unitGroundPosition(unit) or unitPivotPosition(unit))
            end
        end
    end
    local okPC, pcList = pcall(findPlayerCenters)
    if okPC and type(pcList) == "table" then
        for _, p in ipairs(pcList) do addCenter(p) end
    end

    -- Other units provide known navigable surfaces. They're fallback anchors,
    -- not evidence that the local player is allowed to place on that plot.
    if #centers < 3 or failStreak >= 2 then
        if folder then
            local n = 0
            for _, unit in ipairs(folder:GetChildren()) do
                n = n + 1
                if n > 45 then break end
                addCenter(unitGroundPosition(unit) or unitPivotPosition(unit))
            end
        end
        local okAuto, autoList = pcall(findAutoCenters)
        if okAuto and type(autoList) == "table" then
            for _, p in ipairs(autoList) do addCenter(p) end
        end
    end
    local char = Players.LocalPlayer.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if root then addCenter(root.Position) end
    if #centers == 0 then return nil end

    prepareRay()
    local occupied = {}
    if folder then
        for _, unit in ipairs(folder:GetChildren()) do
            local p = unitGroundPosition(unit)
            if p then occupied[#occupied + 1] = p end
        end
    end
    local radiusSetting = math.clamp(tonumber(state.placeRadius) or 15, 1, 65)
    local radius = math.min(75, math.max(15, radiusSetting) + math.min(failStreak, 7) * 6)
    -- First sample useful nearby spots; progressively cover a larger region.
    for attempt = 1, 64 do
        local center = centers[math.random(1, #centers)]
        local angle = (attempt * 2.39996323) + math.random() * 0.25
        local ring = math.sqrt((attempt % 23 + 1) / 23)
        local dist = math.max(3.5, ring * radius)
        local flat = Vector3.new(center.X + math.cos(angle) * dist, center.Y, center.Z + math.sin(angle) * dist)
        local hit = rayDown(flat, 170, 480)
        if hit and hit.Instance and hit.Normal.Y >= 0.72 then
            local pos = hit.Position
            -- Learned placement positions preserve the CFrame height convention.
            local offset = 0
            if #goodSpots > 0 then
                local nearest = goodSpots[1]
                local nearestDist = flatDist(nearest, pos)
                for _, known in ipairs(goodSpots) do
                    local d = flatDist(known, pos)
                    if d < nearestDist then nearest, nearestDist = known, d end
                end
                if nearestDist < 18 then
                    local knownHit = rayDown(nearest, 170, 480)
                    if knownHit then offset = math.clamp(nearest.Y - knownHit.Position.Y, -4, 8) end
                end
            end
            pos = Vector3.new(pos.X, pos.Y + offset, pos.Z)
            if farFrom(occupied, pos, MIN_SPACING) and not isBad(pos) then
                return pos
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
                    placeNotice("No free ground found nearby; expanding search. If this persists, place one manually.")
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
