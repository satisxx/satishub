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
	autoCard = false,
	randomCard = false,
	autoJoinEvent = false,
	randomPlace = false,
	placeRadius = "15",
	unitIds = "",
	transparent = false,
	autoUpgrade = false,
	autoExecTeleport = true,
	cardOption = "2",
	savedKey = "",
	themeColor = "",
}

-- ===== Settings saved to file (survive teleports) =====
local SAVE_FILE = "satishub_settings.json"

local function saveSettings()
	pcall(function()
		local copy = {}
		for k, v in pairs(state) do
			copy[k] = v
		end
		copy.autoJoinEvent = false -- never saved: Auto Join Event always starts OFF
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
	state.autoJoinEvent = false -- always OFF on execute, even if an old save file had it ON
end

loadSettings()

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
	for _, name in ipairs(SCRIPT_FILE_NAMES) do
		local okR, content = pcall(function()
			if isfile(name) then
				return readfile(name)
			end
		end)
		if okR and type(content) == "string" and #content > 0 then
			return content, name
		end
	end
	return nil
end

if SCRIPT_URL == "" and not readOwnFile() then
	warn("[SatisHub] Auto execute needs SCRIPT_URL filled in or the file '" .. SCRIPT_FILE .. "' saved in your executor's workspace folder.")
end

-- Code that runs in the next server: waits for the game, then loads the script.
-- Order: embedded copy -> file read again in the new server -> URL.
local function buildQueuedCode()
	local quotedNames = {}
	for _, n in ipairs(SCRIPT_FILE_NAMES) do
		quotedNames[#quotedNames + 1] = ("%q"):format(n)
	end
	local parts = {
		"repeat task.wait() until game:IsLoaded()",
		"task.wait(2)",
		"pcall(function() getgenv().SatisHubFromQueue = true end)",
		"local ok, err = false, \"no script source found (save the script as satishub.lua in the workspace folder and execute it once)\"",
	}
	-- The script source is embedded directly, so the next server doesn't need to read any file
	local src = readOwnFile()
	if src then
		parts[#parts + 1] = ("ok, err = pcall(function() loadstring(%s)() end)"):format(("%q"):format(src))
	end
	-- Fallback: read the saved file inside the new server
	parts[#parts + 1] = ("if not ok then for _, n in ipairs({%s}) do local has = false pcall(function() has = isfile(n) end) if has then ok, err = pcall(function() loadstring(readfile(n))() end) if ok then break end end end end"):format(table.concat(quotedNames, ","))
	if SCRIPT_URL ~= "" then
		parts[#parts + 1] = ('if not ok then ok, err = pcall(function() loadstring(game:HttpGet("%s"))() end) end'):format(SCRIPT_URL)
	end
	parts[#parts + 1] = 'if not ok then warn("[SatisHub] auto execute failed: " .. tostring(err)) end'
	return table.concat(parts, "\n")
end

-- Shown in the About tab and in the startup notice so you can see if auto execute is actually possible
local autoExecStatus
if not queueFn then
	autoExecStatus = "Auto execute: NOT supported by this executor. Put the script in its autoexec folder."
elseif SCRIPT_URL == "" and not readOwnFile() then
	autoExecStatus = "Auto execute: NOT ready. Save the script as '" .. SCRIPT_FILE .. "' in the workspace folder (or fill SCRIPT_URL)."
else
	local _, foundName = readOwnFile()
	autoExecStatus = "Auto execute: ready" .. (foundName and (" (" .. foundName .. ")") or " (URL)")
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
local learned = env.SatisHubLearned
if not learned then
	learned = { ids = {}, count = 0, positions = {} }
	env.SatisHubLearned = learned
end

if not env.SatisHubHooked and hookmetamethod and getnamecallmethod then
	local okHook = pcall(function()
		local old
		old = hookmetamethod(game, "__namecall", (newcclosure or function(f) return f end)(function(self, ...)
			local method = getnamecallmethod()
			if method == "InvokeServer" and typeof(self) == "Instance" and self.Name == "spawn_unit" and not (checkcaller and checkcaller()) then
				local args = { ... }
				local id, cf = args[1], args[2]
				if type(id) == "string" and not learned.ids[id] then
					learned.ids[id] = true
					learned.count = learned.count + 1
				end
				if typeof(cf) == "CFrame" then
					local list = learned.positions
					list[#list + 1] = cf.Position
					if #list > 30 then
						table.remove(list, 1)
					end
				end
			end
			return old(self, ...)
		end))
	end)
	if okHook then
		env.SatisHubHooked = true
	end
end

-- Scans YOUR player and GUI for unit IDs (format {xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx}):
-- instance names, StringValues and attributes. Finds all your units, not only the one you placed.
local UUID_PATTERN = "^{%x+%-%x+%-%x+%-%x+%-%x+}$"
local lastScan = 0

local function addUnitId(id)
	if type(id) == "string" and id:match(UUID_PATTERN) and not learned.ids[id] then
		learned.ids[id] = true
		learned.count = learned.count + 1
		return true
	end
	return false
end

local function scanUnitIds()
	lastScan = os.clock()
	local before = learned.count
	local n = 0
	for _, inst in ipairs(Players.LocalPlayer:GetDescendants()) do
		n = n + 1
		if n % 400 == 0 then
			task.wait()
		end
		addUnitId(inst.Name)
		if inst:IsA("StringValue") then
			addUnitId(inst.Value)
		end
		for _, v in pairs(inst:GetAttributes()) do
			addUnitId(v)
		end
	end
	return learned.count - before
end

local clearQueueFn = clear_queue_on_teleport or clearqueueonteleport or (syn and syn.clear_queue_on_teleport)

local function queueSelf()
	if state.autoExecTeleport and queueFn then
		pcall(queueFn, buildQueuedCode())
	end
end

-- Called by the "Auto Execute On Teleport" toggle (Settings tab)
local function setAutoExecTeleport(v)
	if v then
		queueSelf()
	elseif clearQueueFn then
		pcall(clearQueueFn)
	end
end

-- Queue now AND again right when a teleport starts (the matchmaking teleport),
-- so it works even if the first queue was lost.
queueSelf()
pcall(function()
	Players.LocalPlayer.OnTeleport:Connect(queueSelf)
end)

-- ===== Look =====
-- Black background (changeable in Settings), grey controls, RGB borders. Green only means "ON".
local ON_COLOR = Color3.fromRGB(0, 170, 100)
local ERROR_COLOR = Color3.fromRGB(240, 70, 70)
local OFF_STROKE = Color3.fromRGB(75, 75, 85)
local DEFAULT_THEME = Color3.fromRGB(8, 8, 8)
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
				g.Rotation = rot
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

	nText("Important", 1, 20, WHITE, true)
	nText(
		'To make "Auto Execute On Teleport" work, save this script as "' .. SCRIPT_FILE .. '" in your executor\'s workspace folder.',
		2,
		14,
		Color3.fromRGB(230, 230, 230),
		false
	)
	nText("Without it, the script will not run again after you change server.", 3, 12, Color3.fromRGB(160, 160, 170), false)
	nText(autoExecStatus, 4, 11, Color3.fromRGB(160, 160, 170), false)

	local nBtn = Instance.new("TextButton")
	nBtn.Size = UDim2.new(1, 0, 0, 36)
	nBtn.BackgroundColor3 = currentTheme:Lerp(WHITE, 0.14)
	nBtn.Text = "Understood"
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
frame.Size = UDim2.fromOffset(280, 0)
frame.AutomaticSize = Enum.AutomaticSize.Y
frame.Position = UDim2.new(0, 20, 0.5, -120)
frame.BackgroundColor3 = currentTheme
frame.BorderSizePixel = 0
frame.ClipsDescendants = true
frame.Visible = false -- shown after the loading screen
frame.Parent = gui
corner(frame, 14)
addRgbStroke(frame, 3)

local frameLayout = Instance.new("UIListLayout")
frameLayout.SortOrder = Enum.SortOrder.LayoutOrder
frameLayout.Parent = frame

-- Theme handling
local fields = {} -- text boxes that follow the theme (slightly lighter, can be transparent)
local plainButtons = {} -- buttons that follow the theme (always solid)
local toggleRefreshers = {} -- repaint functions of the toggles
local header
local userBar
local refreshTabs

local function btnColor()
	return currentTheme:Lerp(WHITE, 0.14)
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
	b.Size = UDim2.new(1, -20, 0, 32)
	b.BackgroundColor3 = btnColor()
	b.Text = text
	b.TextColor3 = WHITE
	b.Font = Enum.Font.GothamBold
	b.TextSize = 13
	b.BorderSizePixel = 0
	b.AutoButtonColor = false
	b.LayoutOrder = order or 0
	b.Parent = parentObj
	corner(b, 8)

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

	-- pressed look
	local sc = Instance.new("UIScale")
	sc.Parent = b
	b.MouseButton1Down:Connect(function()
		sc.Scale = 0.96
	end)
	b.MouseButton1Up:Connect(function()
		sc.Scale = 1
	end)
	b.MouseLeave:Connect(function()
		sc.Scale = 1
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
		b.BackgroundColor3 = on and ON_COLOR or btnColor()
		stroke.Color = on and WHITE or OFF_STROKE
		grad.Enabled = on
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
header.Size = UDim2.new(1, 0, 0, 34)
header.BackgroundColor3 = currentTheme:Lerp(Color3.new(0, 0, 0), 0.3)
header.BorderSizePixel = 0
header.LayoutOrder = 1
header.Parent = frame

local titulo = Instance.new("TextLabel")
titulo.Size = UDim2.new(1, -40, 1, 0)
titulo.Position = UDim2.new(0, 10, 0, 0)
titulo.BackgroundTransparency = 1
titulo.Text = "SatisHub"
titulo.TextColor3 = WHITE
titulo.TextXAlignment = Enum.TextXAlignment.Left
titulo.Font = Enum.Font.GothamBold
titulo.TextSize = 19
titulo.Parent = header

-- RGB title
local titleGrad = Instance.new("UIGradient")
titleGrad.Color = RAINBOW
titleGrad.Parent = titulo
rgbGradients[#rgbGradients + 1] = titleGrad

local minBtn = Instance.new("TextButton")
minBtn.Size = UDim2.fromOffset(24, 24)
minBtn.Position = UDim2.new(1, -32, 0, 5)
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

local function setMinimized(min)
	if min then
		miniIcon.Position = frame.Position
		frame.Visible = false
		miniIcon.Visible = true
	else
		frame.Position = miniIcon.Position
		miniIcon.Visible = false
		frame.Visible = true
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
tabsRow.Size = UDim2.new(1, 0, 0, 34)
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
	b.Size = UDim2.new(0.25, -5, 1, -6)
	b.BackgroundColor3 = currentTheme:Lerp(WHITE, 0.08)
	b.Text = text
	b.TextColor3 = WHITE
	b.Font = Enum.Font.GothamBold
	b.TextSize = 11
	b.BorderSizePixel = 0
	b.AutoButtonColor = false
	b.LayoutOrder = order
	b.Parent = tabsRow
	corner(b, 8)
	local stroke, grad = addRgbStroke(b, 1.5)
	tabInfo[key] = { btn = b, stroke = stroke, grad = grad }
	return b
end

local tabMain = makeTab("Main", 1, "main")
local tabPlayer = makeTab("Player", 2, "player")
local tabSettings = makeTab("Settings", 3, "settings")
local tabAbout = makeTab("About", 4, "about")

refreshTabs = function()
	for key, info in pairs(tabInfo) do
		local active = (key == activeTab)
		info.btn.BackgroundColor3 = currentTheme:Lerp(WHITE, active and 0.22 or 0.08)
		info.btn.TextColor3 = active and WHITE or Color3.fromRGB(170, 170, 175)
		info.grad.Enabled = active
		info.stroke.Color = active and WHITE or OFF_STROKE
	end
end

-- MAIN page
local mainPage = makePage(body, 3)
mainPage.Visible = false

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

-- Auto Select Card and Random Card are mutually exclusive:
-- turning one on turns the other one off.

_, setAutoCard = makeToggle(mainPage, "Auto Select Card", 4, function(v)
	state.autoCard = v
	if v and state.randomCard and setRandomCard then
		setRandomCard(false)
	end
end, state.autoCard)

_, setRandomCard = makeToggle(mainPage, "Random Card (1-3)", 5, function(v)
	state.randomCard = v
	if v and state.autoCard and setAutoCard then
		setAutoCard(false)
	end
end, state.randomCard)

local optRow = Instance.new("Frame")
optRow.Size = UDim2.new(1, -20, 0, 26)
optRow.BackgroundTransparency = 1
optRow.LayoutOrder = 6
optRow.Parent = mainPage

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

makeToggle(mainPage, "FPS BOOST", 7, function(v)
	black.Visible = v
	pcall(function()
		RunService:Set3dRenderingEnabled(not v)
	end)
end)

makeToggle(mainPage, "Auto Join Event", 8, function(v)
	state.autoJoinEvent = v
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

local caixaUnits = makeTextBox(mainPage, "Unit IDs (optional, comma separated)", state.unitIds)
caixaUnits.Size = UDim2.new(1, -20, 0, 28)
caixaUnits.LayoutOrder = 11
caixaUnits.TextSize = 11

caixaUnits.FocusLost:Connect(function()
	state.unitIds = caixaUnits.Text
	saveSettings()
end)

local placeStatus = makeLabel(mainPage, "Place one unit manually so the script learns it", 12)
placeStatus.TextSize = 11

local scanBtn = makeButton(mainPage, "Scan Units", 13)
scanBtn.MouseButton1Click:Connect(function()
	scanBtn.Text = "Scanning..."
	task.spawn(function()
		local found = scanUnitIds()
		scanBtn.Text = ("Found %d new unit ID(s)"):format(found)
		task.wait(1.5)
		scanBtn.Text = "Scan Units"
	end)
end)

makeToggle(mainPage, "Auto Upgrade Units", 14, function(v)
	state.autoUpgrade = v
end, state.autoUpgrade)

-- PLAYER page (ESP + Noclip)
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

-- SETTINGS page
local settingsPage = makePage(body, 4)
settingsPage.Visible = false

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

makeText(aboutPage, "SatisHub", 1, 17, WHITE, true)
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
	activeTab = name
	mainPage.Visible = (name == "main")
	playerPage.Visible = (name == "player")
	settingsPage.Visible = (name == "settings")
	aboutPage.Visible = (name == "about")
	refreshTabs()
end

tabMain.MouseButton1Click:Connect(function()
	showTab("main")
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

-- Key verification
-- Checks the key typed after the script is executed.
local function verificar()
	if normalizeKey(caixaKey.Text) == KEY then
		msgKey.Text = ""
		keyPage.Visible = false
		tabsRow.Visible = true
		showTab("main")
		state.savedKey = KEY
		saveSettings()
	else
		msgKey.Text = "Invalid key"
	end
end

botaoKey.MouseButton1Click:Connect(verificar)
caixaKey.FocusLost:Connect(function(enter)
	if enter then
		verificar()
	end
end)

-- Already verified before (e.g. after a teleport): skip the key screen
if state.savedKey == KEY then
	keyPage.Visible = false
	tabsRow.Visible = true
	showTab("main")
end

applyTheme(currentTheme)
refreshTransparency()
refreshTabs()

-- Loops
task.spawn(function()
	while alive() do
		if state.autoStart then
			invoke("vote_start")
		end
		task.wait(INTERVALO)
	end
end)

-- Cards: random mode works on its own, fixed mode uses the "Card option" box
task.spawn(function()
	while alive() do
		local opt
		if state.randomCard then
			opt = tostring(math.random(1, 3))
		elseif state.autoCard then
			opt = state.cardOption
		end
		if opt then
			invoke("select_roguelike_option", opt)
		end
		task.wait(INTERVALO)
	end
end)

task.spawn(function()
	while alive() do
		if state.autoSkip then
			invoke("vote_wave_skip")
		end
		task.wait(INTERVALO)
	end
end)

-- Replay vote when the game finishes
task.spawn(function()
	while alive() do
		if state.autoReplay then
			invoke("set_game_finished_vote", "replay")
		end
		task.wait(INTERVALO)
	end
end)

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
			return owner.Value == me.Name
		end
	end
	for _, key in ipairs({ "Owner", "owner", "Player", "player", "OwnerId", "UserId" }) do
		local v = unit:GetAttribute(key)
		if v ~= nil then
			return v == me.Name or v == me.UserId
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

-- Auto upgrade: upgrades every unit of yours that is on the map
local UPGRADE_INTERVALO = 1
task.spawn(function()
	while alive() do
		if state.autoUpgrade then
			for _, unit in ipairs(myUnits()) do
				if not (alive() and state.autoUpgrade) then
					break
				end
				invoke("upgrade_unit_ingame", unit)
				task.wait(0.1)
			end
		end
		task.wait(UPGRADE_INTERVALO)
	end
end)

-- ===== Smart random placement =====
-- Learns what kind of floor the spots you used are on, then picks random spots only on that floor,
-- away from other units and from spots that failed. When a spot fails it moves on to another one.
local PLACE_INTERVALO = 0.8
local MIN_SPACING = 3.5 -- minimum distance (studs) from other units
local BAD_SPOT_RADIUS = 3 -- area blocked around a spot where placing failed
local BAD_SPOT_TTL = 120 -- seconds a failed spot stays blocked
local ATTEMPTS_PER_CYCLE = 4 -- different spots tried per cycle when one fails
local NO_MONEY_AFTER = 8 -- this many failures in a row = probably no money / unit limit

local badSpots = {} -- confirmed bad spots { pos, t }
local pendingBad = {} -- failures not confirmed yet (could just be no money)
local goodSpots = {} -- positions where a unit was placed successfully
local idFails = {} -- consecutive failures per unit ID
local failStreak = 0
local placedCount = 0

local function flatDist(a, b)
	return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude
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
		local hit = rayDown(p, 4, 12)
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
	local centers = {}
	for _, p in ipairs(learned.positions) do
		centers[#centers + 1] = p
	end
	for _, p in ipairs(goodSpots) do
		centers[#centers + 1] = p
	end
	if #centers == 0 then
		local char = Players.LocalPlayer.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		if root then
			centers[1] = root.Position
		end
	end
	if #centers == 0 then
		return nil
	end

	prepareRay()
	local filter = buildGroundFilter()
	-- every failure in a row widens the search a bit, so it stops hitting the same area
	local radius = (tonumber(state.placeRadius) or 15) * (1 + math.min(failStreak, 12) * 0.25)

	local occupied = {}
	local folder = getUnitsFolder()
	if folder then
		for _, u in ipairs(folder:GetChildren()) do
			local ok, cf = pcall(function()
				return u:GetPivot()
			end)
			if ok and cf then
				occupied[#occupied + 1] = cf.Position
			end
		end
	end

	for attempt = 1, 45 do
		-- first 30 tries: only floor like the one you placed on; last 15: any flat floor
		local useFilter = (attempt <= 30) and filter or nil
		local center = centers[math.random(1, #centers)]
		local angle = math.random() * math.pi * 2
		local dist = math.sqrt(math.random()) * radius
		local flat = Vector3.new(center.X + math.cos(angle) * dist, center.Y, center.Z + math.sin(angle) * dist)

		local hit = rayDown(flat, 25, 80)
		if hit and math.abs(hit.Position.Y - center.Y) <= 8 and groundOk(hit, useFilter) then
			-- keep the same height convention the game used for the spot we learned from
			local cHit = rayDown(center, 4, 12)
			local offset = cHit and (center.Y - cHit.Position.Y) or 0
			local pos = Vector3.new(flat.X, hit.Position.Y + offset, flat.Z)
			if farFrom(occupied, pos, MIN_SPACING) and not isBad(pos) then
				return pos
			end
		end
	end
	return nil
end

local function pickId(ids)
	local usable = {}
	for _, id in ipairs(ids) do
		if (idFails[id] or 0) < 6 then
			usable[#usable + 1] = id
		end
	end
	if #usable == 0 then
		idFails = {}
		usable = ids
	end
	return usable[math.random(1, #usable)]
end

-- Places one unit and checks if it really appeared (your unit count goes up)
local function tryPlace(id, pos)
	local before = #myUnits()
	local ok, res = invokeRet("spawn_unit", id, CFrame.new(pos))
	if not ok or res == false then
		return false
	end
	if getUnitsFolder() then
		for _ = 1, 6 do
			task.wait(0.12)
			if #myUnits() > before then
				return true
			end
		end
		return false
	end
	return true
end

local function collectUnitIds()
	local list = {}
	for id in pairs(learned.ids) do
		list[#list + 1] = id
	end
	for token in tostring(state.unitIds):gmatch("[^,;%s]+") do
		local id = token
		if id:sub(1, 1) ~= "{" then
			id = "{" .. id .. "}"
		end
		list[#list + 1] = id
	end
	return list
end

task.spawn(function()
	local wasOn = false
	while alive() do
		local ids = collectUnitIds()
		if #ids == 0 and state.randomPlace and os.clock() - lastScan > 5 then
			task.spawn(scanUnitIds)
		end
		placeStatus.Text = ("Units: %d | Spots: %d | Placed: %d"):format(learned.count, #learned.positions, placedCount)

		-- fresh start every time the option is turned on
		if state.randomPlace and not wasOn then
			badSpots = {}
			pendingBad = {}
			idFails = {}
			failStreak = 0
		end
		wasOn = state.randomPlace

		if state.randomPlace and #ids > 0 then
			for _ = 1, ATTEMPTS_PER_CYCLE do
				if not (alive() and state.randomPlace) then
					break
				end
				local pos = pickSpot()
				if not pos then
					failStreak = failStreak + 1
					break
				end
				local id = pickId(ids)
				if tryPlace(id, pos) then
					failStreak = 0
					idFails[id] = 0
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
					-- this spot did not work: move on to another one right away
					failStreak = failStreak + 1
					idFails[id] = (idFails[id] or 0) + 1
					pendingBad[#pendingBad + 1] = { pos = pos, t = os.clock() }
					if failStreak >= NO_MONEY_AFTER then
						-- many fails in a row: probably no money / unit limit, not the spots
						pendingBad = {}
						idFails = {}
						break
					end
				end
			end
		end
		-- when it keeps failing (probably no money) slow down
		task.wait(PLACE_INTERVALO * ((failStreak >= NO_MONEY_AFTER) and 3 or 1))
	end
end)

-- Auto join event (matchmaking)
task.spawn(function()
	while alive() do
		if state.autoJoinEvent then
			invoke("request_matchmaking", "summer2_event")
		end
		task.wait(JOIN_INTERVALO)
	end
end)

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
	frame.Visible = true
end)
