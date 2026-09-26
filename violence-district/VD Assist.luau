--==============================================================
-- VD ASSIST v10.0 DATA API + ANTI3 OWNER + STAGGERED SCANS
-- Conservative rebuild from the last working v8.2 base.
--
-- No screen rectangles. Exit markers exist only after every real generator is completed.
-- Shows only:
--   * killer / survivor auras;
--   * every unfinished generator with a thin outline;
--   * small progress text when close;
--   * pallets and vault windows;
--   * one stable green generator recommendation;
--   * grey/green exit outlines during the real exit stage.
--
-- M toggles the entire assist without rebuilding or rescanning visuals.
--==============================================================

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local CollectionService = game:GetService("CollectionService")
local Workspace = game:GetService("Workspace")

local localPlayer = Players.LocalPlayer
if not localPlayer then return end

for _, stopName in ipairs({
	"StopVDAssist",
	"StopFixedVDAssist",
	"StopVDAssistCompactOneGen",
}) do
	local stop = _G[stopName]
	if typeof(stop) == "function" then
		pcall(stop)
	end
end

-- Stop any cached copy that used a different runtime key. Without a shared
-- owner, duplicate InputBegan handlers can toggle visuals twice on one press.
local priorSingleton = rawget(_G, "__VD_ASSIST_SINGLETON")
if type(priorSingleton) == "table" and typeof(priorSingleton.Stop) == "function" then
	pcall(priorSingleton.Stop)
end

local KEY = "__VD_ASSIST_V9_6_AIM_INSPECTOR"
local RUN_ID = string.format("v96_%d_%d", math.floor(os.clock() * 1000), math.random(100000, 999999))
local old = _G[KEY]
if type(old) == "table" and typeof(old.Stop) == "function" then
	pcall(old.Stop)
end

local CONFIG = {
	toggleKey = Enum.KeyCode.M,
	windowProbeKey = Enum.KeyCode.P,
	updateInterval = 0.50,
	playerInterval = 0.80,
	npcInterval = 0.85,
	routeInterval = 1.55,
	fullStateDebounce = 0.90,
	numberSourceRetry = 2.25,
	-- DescendantAdded handles normal map loading. A rare safety rescan replaces
	-- the old full Workspace scan every 10 seconds that caused visible hitches.
	rescanInterval = 180.0,
	labelDistance = 42,
	exitLabelDistance = 52,
	-- Keep route objects visible across the playable map. 280 studs was short
	-- enough that pallets/windows disappeared until the survivor was already
	-- beside them, which looked like the indexer had failed.
	routeDistance = 900,
	killerNearDistance = 36,
	targetHold = 8.0,
	targetSwitchMargin = 11.0,
	targetConfirmTime = 1.35,
	etaWarmupSamples = 3,
	etaWarmupTime = 1.40,
	defaultSoloRate = 0.82,
	arrivalBuffer = 2.2,
	teammateApproachDot = 0.48,
	teammateApproachMaxEta = 20.0,
	teammateNearGenDistance = 11.5,
	localAtGenDistance = 8.5,
	killerUnsafeBuffer = 1.5,
	exitTargetHold = 4.0,
	exitSwitchMargin = 5.0,
	exitConfirmDelay = 1.25,
	initialLabelDelay = 0.50,
	exitFallbackOpenSeconds = 20.0,
	repairPointRescanMinimum = 18.0,
	repairPointRescanJitter = 9.0,
	-- Route discovery is incremental. Keep one batch under a small wall-clock
	-- budget so a streamed map cannot monopolize a render/heartbeat step.
	scanBatchBudget = 0.002,
	-- A streamed map can create the generator model before its progress
	-- attributes/tags arrive. Probe the shallow, known generator container at a
	-- low rate so the initial async scan cannot leave the data API empty until
	-- the 180-second safety rescan.
	knownGeneratorProbeInterval = 2.0,
	initialEmptyIndexRetryDelay = 0.65,

	-- VD normally spawns two more physical generators than survivors must finish.
	-- Use objective count, not every remaining model, for late-game and exit logic.
	spareGeneratorCount = 2,
}

local COLORS = {
	killer = Color3.fromRGB(255, 65, 65),
	survivor = Color3.fromRGB(70, 175, 255),
	generator = Color3.fromRGB(190, 210, 235),
	best = Color3.fromRGB(70, 255, 120),
	danger = Color3.fromRGB(255, 145, 70),
	exit = Color3.fromRGB(175, 185, 200),
	pallet = Color3.fromRGB(255, 215, 65),
	window = Color3.fromRGB(105, 225, 255),
	custom = Color3.fromRGB(235, 235, 255),
	zombie = Color3.fromRGB(190, 95, 255),
	text = Color3.fromRGB(245, 248, 255),
}

local runtime = {
	running = true,
	visible = true,
	apiVersion = 2,
	connections = {},
	playerAuras = {},
	npcAuras = {},
	generators = {},
	exits = {},
	routes = {},
	-- Successful route anchors are stable for a model's lifetime. Weak keys
	-- avoid retaining streamed-out map models and prevent repeated descendant
	-- walks when DescendantAdded/tag callbacks mention the same object.
	routeAnchorCache = setmetatable({}, {__mode = "k"}),
	routeAddAt = setmetatable({}, {__mode = "k"}),
	-- Per-round progress samples are cleared whenever the map changes.  Keep
	-- this table owned by the runtime so a first scan cannot call table.clear
	-- on a missing field (older hot-reloaded copies did not initialize it).
	progressHistory = {},
	dataRevision = 0,
	dataUpdatedAt = -math.huge,
	totalGenerators = 0,
	completedGenerators = 0,
	requiredCompletions = 0,
	objectivesRemaining = 0,
	anti3Owner = nil,
	baseGeneratorRecommendation = nil,
	baseGeneratorRecommendationInfo = nil,
	GetAnti3Snapshot = nil,
	Stop = nil,
}
_G[KEY] = runtime
_G.__VD_ASSIST_SINGLETON = runtime

local routeConfig = rawget(_G, "VDAssistRouteConfig")
if type(routeConfig) ~= "table" then routeConfig = {} end
if type(routeConfig.whitelist) ~= "table" then routeConfig.whitelist = {} end
-- Blacklist entries are manual and session-local. Do not carry stale entries
-- from a previous hot-reloaded copy into a new map.
routeConfig.blacklist = {}
_G.VDAssistRouteConfig = routeConfig
runtime.routeConfig = routeConfig

local state = {
	killer = nil,
	lastUpdate = -math.huge,
	lastPlayerUpdate = -math.huge,
	lastNpcUpdate = -math.huge,
	lastRouteUpdate = -math.huge,
	lastScan = -math.huge,
	scanDirty = true,
	bestGenerator = nil,
	bestSince = -math.huge,
	pendingGenerator = nil,
	pendingGeneratorSince = -math.huge,
	roundStartedAt = nil,
	bestExit = nil,
	bestExitSince = -math.huge,
	roundArmed = false,
	sawLiveUnfinished = false,
	exitMode = false,
	exitReadySince = nil,
	lastMap = nil,
	windowProbeBusy = false,
	lastToggleAt = -math.huge,
	lastPicked = nil,
	scanInProgress = false,
	lastRouteCount = -1,
	lastGeneratorCount = -1,
	nextKnownGeneratorProbeAt = -math.huge,
	initialEmptyIndexRetryScheduled = false,
	controlPaused = false,
	exitGuiCacheAt = -math.huge,
	exitGuiVisible = false,
	exitGuiProgress = nil,
	exitGuiSource = nil,
}

local function remember(connection)
	table.insert(runtime.connections, connection)
	return connection
end

local function normalize(value)
	return string.lower(tostring(value or "")):gsub("[^%w]", "")
end

local function horizontal(vector)
	return Vector3.new(vector.X, 0, vector.Z)
end

local function horizontalDistance(a, b)
	return horizontal(a - b).Magnitude
end

local function objectPart(object)
	if not object then return nil end
	if object:IsA("BasePart") then return object end
	if object:IsA("Model") then
		if object.PrimaryPart then return object.PrimaryPart end
		for _, name in ipairs({"RootPart", "GeneratorRoot", "Main", "Base"}) do
			local candidate = object:FindFirstChild(name, true)
			if candidate and candidate:IsA("BasePart") then
				return candidate
			end
		end
		return object:FindFirstChildWhichIsA("BasePart", true)
	end
	return nil
end

local function localRoot()
	local character = localPlayer.Character
	return character and character:FindFirstChild("HumanoidRootPart") or nil
end

local function localControlLocked()
	local character = localPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not character or not humanoid or humanoid.Health <= 0 then return true end
	for _, container in ipairs({character, humanoid, localPlayer}) do
		for _, name in ipairs({
			"Knocked", "Downed", "IsDowned", "Dying", "Incapacitated",
			"Carried", "IsCarried", "BeingCarried", "IsBeingCarried",
			"Hooked", "OnHook", "Hanging", "Captured", "Grabbed",
			"Held", "OnShoulder",
		}) do
			local value = container:GetAttribute(name)
			if value == true or (typeof(value) == "number" and value > 0) then return true end
		end
	end
	return humanoid.PlatformStand == true
end

local function playerRoot(player)
	local character = player and player.Character
	return character and character:FindFirstChild("HumanoidRootPart") or nil
end

local function attributeNumber(instance, names)
	if not instance then return nil end
	for _, name in ipairs(names) do
		local value = instance:GetAttribute(name)
		if typeof(value) == "number" then return value end
	end
	return nil
end

local function attributeTrue(instance, names)
	if not instance then return false end
	for _, name in ipairs(names) do
		if instance:GetAttribute(name) == true then return true end
	end
	return false
end

local function looksLikeKiller(player)
	if not player or player == localPlayer then return false end
	if _G.VDDetectedKiller == player or _G.VDKillerPlayer == player then
		return true
	end
	local teamName = player.Team and string.lower(player.Team.Name) or ""
	if teamName:find("killer", 1, true)
		or teamName:find("maniac", 1, true)
		or teamName:find("slasher", 1, true)
		or teamName:find("monster", 1, true) then
		return true
	end
	for _, container in ipairs({player, player.Character}) do
		if container then
			for name, value in pairs(container:GetAttributes()) do
				local key = normalize(name)
				if (key == "iskiller" or key == "isman" or key == "ismaniac") and value == true then
					return true
				end
				if key == "role" or key == "class" or key == "type" then
					local role = string.lower(tostring(value))
					if role:find("killer", 1, true)
						or role:find("maniac", 1, true)
						or role:find("slasher", 1, true)
						or role:find("monster", 1, true) then
						return true
					end
				end
			end
		end
	end
	return false
end

local function resolveKiller()
	local global = _G.VDDetectedKiller or _G.VDKillerPlayer
	if typeof(global) == "Instance" then
		if global:IsA("Player") and playerRoot(global) then return global end
		if global:IsA("Model") then
			local player = Players:GetPlayerFromCharacter(global)
			if player and playerRoot(player) then return player end
		end
	end
	for _, player in ipairs(Players:GetPlayers()) do
		if looksLikeKiller(player) and playerRoot(player) then
			return player
		end
	end
	return nil
end

local function ensureHighlight(parent, name)
	local existing = parent:FindFirstChild(name)
	if existing and existing:IsA("Highlight") and existing:GetAttribute("VDRunId") == RUN_ID then
		existing.Adornee = parent
		return existing
	end
	if existing then existing:Destroy() end
	local highlight = Instance.new("Highlight")
	highlight.Name = name
	highlight:SetAttribute("VDRunId", RUN_ID)
	highlight.Adornee = parent
	highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	highlight.Enabled = runtime.visible
	highlight.Parent = parent
	return highlight
end

local function applyHighlight(entry, color, fillTransparency, outlineTransparency, enabled)
	local highlight = entry and entry.highlight
	if not highlight then return end
	if entry.visualColor ~= color then
		entry.visualColor = color
		highlight.FillColor = color
		highlight.OutlineColor = color
	end
	if entry.visualFill ~= fillTransparency then
		entry.visualFill = fillTransparency
		highlight.FillTransparency = fillTransparency
	end
	if entry.visualOutline ~= outlineTransparency then
		entry.visualOutline = outlineTransparency
		highlight.OutlineTransparency = outlineTransparency
	end
	if entry.visualEnabled ~= enabled or highlight.Enabled ~= enabled then
		entry.visualEnabled = enabled
		highlight.Enabled = enabled
	end
end

local function setBillboard(entry, enabled, text, color)
	if not entry or not entry.billboard or not entry.label then return end
	if entry.billboardEnabled ~= enabled or entry.billboard.Enabled ~= enabled then
		entry.billboardEnabled = enabled
		entry.billboard.Enabled = enabled
	end
	if text ~= nil and entry.lastText ~= text then
		entry.lastText = text
		entry.label.Text = text
	end
	if color ~= nil and entry.lastTextColor ~= color then
		entry.lastTextColor = color
		entry.label.TextColor3 = color
	end
end

local function cleanupOldVisuals()
	local names = {
		VDAssistPlayerAura=true, VDAssistZombieAura=true, FixedVDPlayerAura=true,
		FixedVDGeneratorAura=true, VDGenAssistHighlight=true, VDGenAssistBillboard=true,
		VDObjectiveOutline=true, VDObjectiveBillboard=true, VDLiteRouteAura=true,
		VDLiteGenAura=true, VDLiteGenBillboard=true, VDRestoredRouteAura=true,
		VDRestoredGenAura=true, VDRestoredGenBillboard=true,
		VDRestoredExitAura=true, VDRestoredExitBillboard=true,
	}
	task.spawn(function()
		local queue, head, processed = {Workspace}, 1, 0
		while runtime.running and _G[KEY] == runtime and head <= #queue do
			local parent = queue[head]; head += 1
			local ok, children = pcall(function() return parent:GetChildren() end)
			if ok then
				for _, object in ipairs(children) do
					table.insert(queue, object)
					if runtime.running and _G[KEY] == runtime then
						local oldAssistVisual = names[object.Name]
							or (object.Name:find("VDAssistWindowSelection_", 1, true) ~= nil)
						if (object:IsA("Highlight") or object:IsA("BillboardGui")
							or object:IsA("SelectionBox") or object:IsA("BoxHandleAdornment"))
							and oldAssistVisual and object:GetAttribute("VDRunId") ~= RUN_ID then
							object:Destroy()
						end
					end
					processed += 1
					if processed % 120 == 0 then RunService.Heartbeat:Wait() end
				end
			end
		end
	end)
	local playerGui = localPlayer:FindFirstChildOfClass("PlayerGui")
	if playerGui then
		for _, name in ipairs({"FixedVDAssistHUD", "VDGenAssistHUD"}) do
			local gui = playerGui:FindFirstChild(name); if gui then gui:Destroy() end
		end
	end
end

cleanupOldVisuals()

local function updatePlayerAuras()
	state.killer = resolveKiller()
	local alive = {}
	for _, player in ipairs(Players:GetPlayers()) do
		if player ~= localPlayer then
			local character = player.Character
			local humanoid = character and character:FindFirstChildOfClass("Humanoid")
			if character and character.Parent and (not humanoid or humanoid.Health > 0) then
				alive[player] = true
				local entry = runtime.playerAuras[player]
				if not entry or entry.character ~= character or not entry.highlight.Parent then
					if entry and entry.highlight then entry.highlight:Destroy() end
					entry = {
						character = character,
						highlight = ensureHighlight(character, "VDAssistPlayerAura"),
					}
					runtime.playerAuras[player] = entry
				end
				local color = player == state.killer and COLORS.killer or COLORS.survivor
				applyHighlight(
					entry,
					color,
					player == state.killer and 0.58 or 0.78,
					0.04,
					runtime.visible
				)
			end
		end
	end
	for player, entry in pairs(runtime.playerAuras) do
		if not alive[player] then
			if entry.highlight then entry.highlight:Destroy() end
			runtime.playerAuras[player] = nil
		end
	end
end

local function looksLikeZombieModel(model)
	if not model or not model:IsA("Model") or model == localPlayer.Character then return false end
	if Players:GetPlayerFromCharacter(model) then return false end
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	local root = model:FindFirstChild("HumanoidRootPart") or model:FindFirstChild("Torso") or model:FindFirstChild("UpperTorso")
	if not humanoid or humanoid.Health <= 0 or not root then return false end
	local name = normalize(model.Name)
	if name:find("zombie", 1, true) or name:find("infected", 1, true)
		or name:find("undead", 1, true) or name:find("walker", 1, true) then
		return true
	end
	if CollectionService:HasTag(model, "Zombie") or CollectionService:HasTag(model, "EnemyNPC") then
		return true
	end
	for _, attr in ipairs({"IsZombie", "Zombie", "IsEnemyNPC", "Hostile"}) do
		if model:GetAttribute(attr) == true then return true end
	end
	return false
end

local function addZombieCandidate(model)
	local standaloneAura = rawget(_G, "__VD_ZOMBIE_AURA_VISUAL_V2")
	if type(standaloneAura) == "table" and standaloneAura.running == true then
		return
	end
	if not looksLikeZombieModel(model) or runtime.npcAuras[model] then return end
	runtime.npcAuras[model] = {
		model = model,
		highlight = ensureHighlight(model, "VDAssistZombieAura"),
	}
end

local function updateNPCAuras()
	local standaloneAura = rawget(_G, "__VD_ZOMBIE_AURA_VISUAL_V2")
	if type(standaloneAura) == "table" and standaloneAura.running == true then
		for model, entry in pairs(runtime.npcAuras) do
			if entry.highlight then entry.highlight:Destroy() end
			runtime.npcAuras[model] = nil
		end
		return
	end
	for model, entry in pairs(runtime.npcAuras) do
		local humanoid = model.Parent and model:FindFirstChildOfClass("Humanoid") or nil
		if not humanoid or humanoid.Health <= 0 or not looksLikeZombieModel(model) then
			if entry.highlight then entry.highlight:Destroy() end
			runtime.npcAuras[model] = nil
		else
			applyHighlight(entry, COLORS.zombie, 0.72, 0.05, runtime.visible)
		end
	end
end

local PROGRESS_NAMES = {
	"RepairProgress", "GeneratorProgress", "Progress", "Completion", "Percent", "Percentage",
}

local function hasGeneratorSignal(instance)
	if not instance then return false end
	-- Live map generator models carry this tag even before progress attributes
	-- are replicated to a streamed clone.
	if CollectionService:HasTag(instance, "Generator") then return true end
	if attributeNumber(instance, PROGRESS_NAMES) ~= nil then return true end
	return instance:GetAttribute("PlayersRepairingCount") ~= nil
		or instance:GetAttribute("Regressing") ~= nil
		or instance:GetAttribute("Completed") ~= nil
end

local EXIT_PROGRESS_NAMES = {
	"OpenProgress", "OpeningProgress", "GateProgress", "EscapeProgress",
	"RepairProgress", "DoorProgress", "UnlockProgress",
	"OpenPercent", "GateCharge", "OpeningAmount",
}

local function hasExitSignal(instance)
	if not instance then return false end
	if attributeNumber(instance, EXIT_PROGRESS_NAMES) ~= nil then return true end
	for _, child in ipairs(instance:GetDescendants()) do
		if (child:IsA("NumberValue") or child:IsA("IntValue")) then
			local childName = normalize(child.Name)
			for _, expected in ipairs(EXIT_PROGRESS_NAMES) do
				if childName == normalize(expected) then return true end
			end
		end
	end
	return instance:GetAttribute("Opened") ~= nil
		or instance:GetAttribute("IsOpen") ~= nil
		or instance:GetAttribute("GateOpened") ~= nil
end

local EXIT_TAGS = {"Exit", "gatespot", "EscapePart"}

local function hasExitTag(instance)
	if not instance then return false end
	for _, tag in ipairs(EXIT_TAGS) do
		if CollectionService:HasTag(instance, tag) then return true end
	end
	return false
end

local function exitNameMatches(model)
	if not model or not model:IsA("Model") then return false end
	local name = normalize(model.Name)
	if name:find("generator", 1, true) then return false end
	if name == "gates" or name == "exits" or name == "exitgates" then return false end
	return name == "gate"
		or name == "exit"
		or name:find("exitgate", 1, true) ~= nil
		or name:find("exitdoor", 1, true) ~= nil
		or name:find("escapedoor", 1, true) ~= nil
		or name:find("escapegate", 1, true) ~= nil
end

local function modelLooksLikeExit(model)
	if not model or not model:IsA("Model") or model:FindFirstChildOfClass("Humanoid") then
		return false
	end
	if hasExitTag(model) then return true end
	-- A generic numeric attribute named Progress must never turn an arbitrary
	-- model (or a character attachment) into an exit. Require an exit/gate name,
	-- or an explicit ExitLever hierarchy with a real exit signal.
	if exitNameMatches(model) then
		return hasExitSignal(model)
			or model:FindFirstChild("ExitLever", true) ~= nil
			or model:FindFirstChild("Door", true) ~= nil
			or model:FindFirstChild("ExitPart", true) ~= nil
	end
	local lever = model:FindFirstChild("ExitLever")
	return lever ~= nil and hasExitSignal(lever)
end

local function exitRootFrom(instance)
	local current = instance
	local leverFallback = nil
	local taggedFallback = nil
	if hasExitTag(instance) then
		local taggedCurrent = instance:IsA("Model") and instance or instance.Parent
		for _ = 1, 9 do
			if not taggedCurrent or taggedCurrent == Workspace then break end
			if taggedCurrent:IsA("Model") then
				taggedFallback = taggedCurrent
				break
			end
			taggedCurrent = taggedCurrent.Parent
		end
	end
	for _ = 1, 9 do
		if not current or current == Workspace then break end
		if current:IsA("Model") and not current:FindFirstChildOfClass("Humanoid") then
			-- Prefer the first named Gate/Exit ancestor. This keeps the marker on
			-- the map gate instead of binding it to ExitLever.Main beside a player.
			-- Prefer the physical Gate/Exit ancestor. A live `Exit` tag is often
			-- attached to ExitLever.Main, so using the tag as an early root would
			-- put the aura on the lever beside the survivor.
			if exitNameMatches(current) and modelLooksLikeExit(current) then
				return current
			end
			if not leverFallback and modelLooksLikeExit(current) then
				leverFallback = current
			end
		end
		current = current.Parent
	end
	return leverFallback or taggedFallback
end

local function exitAnchorValid(part)
	if not part or not part:IsA("BasePart") or not part.Parent then return false end
	local current = part.Parent
	while current and current ~= Workspace do
		if current:IsA("Model") and current:FindFirstChildOfClass("Humanoid") then
			return false
		end
		current = current.Parent
	end
	return true
end

local function exitPart(model)
	if not model then return nil end
	-- Prefer the physical gate/door body. ExitLever.Main is often close to the
	-- survivor's head while interacting and made the EXIT label look attached
	-- to a player.
	for _, name in ipairs({"ExitPart", "Door", "Gate", "RootPart", "Base"}) do
		local candidate = model:FindFirstChild(name, true)
		if exitAnchorValid(candidate) then return candidate end
	end

	local best, bestVolume = nil, -1
	for _, candidate in ipairs(model:GetDescendants()) do
		if exitAnchorValid(candidate) and candidate.Anchored then
			local n = normalize(candidate.Name)
			local excluded = n:find("lever", 1, true)
				or n:find("trigger", 1, true)
				or n:find("prompt", 1, true)
				or n:find("hitbox", 1, true)
				or n:find("interaction", 1, true)
			if not excluded then
				local volume = candidate.Size.X * candidate.Size.Y * candidate.Size.Z
				if volume > bestVolume then
					best, bestVolume = candidate, volume
				end
			end
		end
	end
	if best then return best end
	if exitAnchorValid(model.PrimaryPart) then return model.PrimaryPart end
	local lever = model:FindFirstChild("ExitLever", true)
	local leverMain = lever and lever:FindFirstChild("Main", true)
	if exitAnchorValid(leverMain) then return leverMain end
	for _, candidate in ipairs(model:GetDescendants()) do
		if exitAnchorValid(candidate) then return candidate end
	end
	return nil
end

local function generatorRootFrom(instance)
	local current = instance
	local fallback = nil
	for _ = 1, 7 do
		if not current or current == Workspace then break end
		if current:IsA("Model") then
			local name = normalize(current.Name)
			local generatorContainer = name == "generators"
				or name == "newgenerators"
				or name:find("generatorcontainer", 1, true) ~= nil
			if hasGeneratorSignal(current) and objectPart(current)
				and not generatorContainer
				and (name:find("generator", 1, true) or name == "gen"
					or CollectionService:HasTag(current, "Generator")
					or current:GetAttribute("IsGenerator") == true
					or current:GetAttribute("Generator") == true) then return current end
			if not generatorContainer
				and (name:find("generator", 1, true) or name == "gen") then
				fallback = fallback or current
			end
		end
		current = current.Parent
	end
	return fallback
end

local VALUE_SENTINEL = "__VALUE__"

local function sourceNumber(source, name)
	if not source or not source.Parent or not name then return nil end
	if name == VALUE_SENTINEL then
		if source:IsA("NumberValue") or source:IsA("IntValue") then
			return source.Value
		end
		return nil
	end
	return source:GetAttribute(name)
end

local function findNumberSource(model, names)
	for _, name in ipairs(names) do
		if typeof(model:GetAttribute(name)) == "number" then return model, name end
	end
	for _, child in ipairs(model:GetDescendants()) do
		for _, name in ipairs(names) do
			if typeof(child:GetAttribute(name)) == "number" then return child, name end
		end
		if child:IsA("NumberValue") or child:IsA("IntValue") then
			local childName = normalize(child.Name)
			for _, name in ipairs(names) do
				if childName == normalize(name) then
					return child, VALUE_SENTINEL
				end
			end
		end
	end
	return nil, nil
end

local function readNumber(entry, sourceKey, nameKey, names)
	local source = entry[sourceKey]
	local name = entry[nameKey]
	local value = sourceNumber(source, name)
	if typeof(value) ~= "number" then
		local retryKey = sourceKey .. "RetryAt"
		local now = os.clock()
		if now >= (entry[retryKey] or -math.huge) then
			source, name = findNumberSource(entry.model, names)
			entry[sourceKey], entry[nameKey] = source, name
			entry[retryKey] = now + CONFIG.numberSourceRetry
			value = sourceNumber(source, name)
		end
	end
	return typeof(value) == "number" and value or nil, name
end

local function progressOf(entry)
	local value = readNumber(entry, "progressSource", "progressName", PROGRESS_NAMES)
	-- Generator progress in VD is 0..100. Never convert a raw value of 1 into 100.
	return math.clamp(value or 0, 0, 100)
end

local function repairersOf(entry)
	local value = readNumber(
		entry,
		"repairersSource",
		"repairersName",
		{
			"PlayersRepairingCount", "RepairingPlayers", "Repairers",
			"PlayersOpeningCount", "OpeningPlayers", "Openers", "PlayersInteractingCount"
		}
	)
	return math.max(0, value or 0)
end


local GENERATOR_CAPACITY_NAMES = {
	"MaxRepairers", "MaximumRepairers", "RepairerCapacity", "RepairCapacity",
	"RepairSlots", "GeneratorSlots", "MaxPlayers", "PlayerCapacity", "Capacity",
}

local function capacityFromObject(object)
	for _, name in ipairs(GENERATOR_CAPACITY_NAMES) do
		local value = object:GetAttribute(name)
		if typeof(value) == "number" and value >= 1 and value <= 8 then
			return math.floor(value + 0.5), object:GetFullName() .. ".Attribute." .. name
		end
	end
	if object:IsA("NumberValue") or object:IsA("IntValue") then
		local objectName = normalize(object.Name)
		for _, name in ipairs(GENERATOR_CAPACITY_NAMES) do
			if objectName == normalize(name) and object.Value >= 1 and object.Value <= 8 then
				return math.floor(object.Value + 0.5), object:GetFullName() .. ".Value"
			end
		end
	end
	return nil, nil
end

local function capacityAttribute(model)
	local capacity, source = capacityFromObject(model)
	if capacity then return capacity, source end
	for _, object in ipairs(model:GetDescendants()) do
		capacity, source = capacityFromObject(object)
		if capacity then return capacity, source end
	end
	return nil, nil
end

local function isRepairPointName(name)
	name = normalize(name)
	return name:match("^generatorpoint%d+$") ~= nil
		or name:match("^repairpoint%d+$") ~= nil
		or name:match("^interactionpoint%d+$") ~= nil
		or name:match("^workpoint%d+$") ~= nil
		or name:match("^genpoint%d+$") ~= nil
		or name:match("^repairslot%d+$") ~= nil
end

local function refreshRepairPoints(entry, now)
	local needsScan = not entry.repairPoints
		or not entry.repairPointNextScanAt
		or now >= entry.repairPointNextScanAt
	if not needsScan then
		for _, point in ipairs(entry.repairPoints) do
			if not point.Parent then
				needsScan = true
				break
			end
		end
	end
	if not needsScan then return entry.repairPoints end

	local anchors = {}
	local modelFallback = {}
	for _, object in ipairs(entry.model:GetDescendants()) do
		if isRepairPointName(object.Name) then
			if object:IsA("BasePart") or object:IsA("Attachment") then
				table.insert(anchors, object)
			elseif object:IsA("Model") then
				table.insert(modelFallback, object)
			end
		end
	end
	entry.repairPoints = #anchors > 0 and anchors or modelFallback
	entry.repairPointScanAt = now
	entry.repairPointNextScanAt = now
		+ CONFIG.repairPointRescanMinimum
		+ math.random() * CONFIG.repairPointRescanJitter
	return entry.repairPoints
end

local function pointOccupied(point)
	-- The live map marks occupied repair stations with the explicit
	-- GeneratorPointInUse tag and/or IsRepairing attribute. Include these
	-- markers when generic Occupied/ObjectValue signals are absent.
	if CollectionService:HasTag(point, "GeneratorPointInUse")
		or point:GetAttribute("IsRepairing") == true then
		return true
	end
	for _, name in ipairs({"Occupied", "IsOccupied", "InUse", "IsInUse", "Taken", "Busy"}) do
		if point:GetAttribute(name) == true then return true end
	end
	for _, name in ipairs({"Occupant", "Player", "User", "Repairer"}) do
		local value = point:GetAttribute(name)
		if typeof(value) == "string" and value ~= "" then return true end
		if typeof(value) == "number" and value ~= 0 then return true end
	end
	for _, child in ipairs(point:GetChildren()) do
		if child:IsA("ObjectValue") then
			local name = normalize(child.Name)
			if (name:find("occup", 1, true) or name:find("player", 1, true)
				or name:find("user", 1, true) or name:find("repair", 1, true))
				and child.Value ~= nil then
				return true
			end
		end
	end
	return false
end

local function generatorSlotState(entry, repairers, now)
	local points = refreshRepairPoints(entry, now)
	if not entry.capacityNextScanAt or now >= entry.capacityNextScanAt then
		entry.explicitSlotCapacity, entry.explicitCapacitySource = capacityAttribute(entry.model)
		entry.capacityScanAt = now
		entry.capacityNextScanAt = now
			+ CONFIG.repairPointRescanMinimum
			+ math.random() * CONFIG.repairPointRescanJitter
	end
	local capacity = entry.explicitSlotCapacity
	local source = entry.explicitCapacitySource
	if not capacity and #points >= 2 then
		capacity = #points
		source = "repair-points"
	end

	local occupiedByPoints = 0
	for _, point in ipairs(points) do
		if pointOccupied(point) then occupiedByPoints += 1 end
	end
	local occupied = math.max(math.floor((tonumber(repairers) or 0) + 0.5), occupiedByPoints)
	local full = capacity ~= nil and capacity > 0 and occupied >= capacity
	return capacity, occupied, full, source
end

local function completedOf(model, progress)
	return attributeTrue(model, {"Completed", "Complete", "Done", "Repaired", "IsCompleted"})
		or progress >= 99.95
end

local function unusableOf(model)
	return attributeTrue(model, {
		"Broken", "IsBroken", "Destroyed", "IsDestroyed", "Disabled", "IsDisabled", "Unavailable",
	})
end

local function exitOpenedOf(model, progress, progressKnown)
	return attributeTrue(model, {"Opened", "IsOpen", "Open", "GateOpened", "Completed", "Done"})
		or (progressKnown == true and progress >= 99.5)
end

local function ensureExitEntry(model)
	local entry = runtime.exits[model]
	local part = exitPart(model)
	if not part then return nil end
	if not entry then
		entry = {
			model = model,
			part = part,
			seenAt = os.clock(),
			lastProgress = nil,
			lastProgressAt = nil,
			repairRate = nil,
			rateSamples = {},
			rateStartedAt = nil,
			lastWorkerCount = nil,
			ratioScale = false,
		}
		runtime.exits[model] = entry
	else
		entry.part = part
	end
	return entry
end

local function ensureExitVisual(entry)
	if entry.highlight and entry.highlight.Parent
		and entry.billboard and entry.billboard.Parent then
		return
	end
	if entry.highlight then entry.highlight:Destroy() end
	if entry.billboard then entry.billboard:Destroy() end
	entry.highlight = ensureHighlight(entry.model, "VDRestoredExitAura")
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "VDRestoredExitBillboard"
	billboard:SetAttribute("VDRunId", RUN_ID)
	billboard.AlwaysOnTop = true
	billboard.Size = UDim2.fromOffset(120, 28)
	billboard.StudsOffset = Vector3.zero
	billboard.StudsOffsetWorldSpace = Vector3.new(0, 4.8, 0)
	billboard.MaxDistance = CONFIG.exitLabelDistance + 5
	billboard.Adornee = entry.part
	billboard.Enabled = runtime.visible
	billboard.Parent = entry.part
	local label = Instance.new("TextLabel")
	label.Name = "Text"
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.BorderSizePixel = 0
	label.Font = Enum.Font.GothamBold
	label.TextSize = 13
	label.TextXAlignment = Enum.TextXAlignment.Center
	label.TextStrokeTransparency = 0.35
	label.TextColor3 = COLORS.text
	label.Text = ""
	label.Parent = billboard
	entry.billboard = billboard
	entry.label = label
	entry.visualColor = nil
	entry.visualFill = nil
	entry.visualOutline = nil
	entry.visualEnabled = nil
	entry.billboardEnabled = nil
	entry.lastText = nil
	entry.lastTextColor = nil
end

local function refreshExitGuiCache()
	local now = os.clock()
	if now - state.exitGuiCacheAt < 0.85 then
		return state.exitGuiVisible, nil, nil
	end
	state.exitGuiCacheAt = now
	state.exitGuiVisible = false
	state.exitGuiProgress = nil
	state.exitGuiSource = nil
	local playerGui = localPlayer:FindFirstChildOfClass("PlayerGui")
	if not playerGui then return false, nil, nil end
	for _, object in ipairs(playerGui:GetDescendants()) do
		if (object:IsA("TextLabel") or object:IsA("TextButton")) and object.Visible then
			local text = normalize(object.Text)
			if text:find("openexit", 1, true)
				or text:find("opengate", 1, true)
				or text:find("exitopen", 1, true)
				or text:find("gateopen", 1, true) then
				state.exitGuiVisible = true
				break
			end
		end
	end
	return state.exitGuiVisible, nil, nil
end

local function visibleExitProgressGui()
	local visible = refreshExitGuiCache()
	return visible
end

local LOCAL_EXIT_PROGRESS_NAMES = {
	"OpenProgress", "OpeningProgress", "ExitProgress", "GateProgress",
	"DoorProgress", "UnlockProgress", "OpenPercent", "ActivationProgress",
}

local function localOwnsRepairInteraction(model)
	local character = localPlayer.Character
	local check = character and character:FindFirstChild("CheckInterractable")
	if not check or check:GetAttribute("isRepairing") ~= true then return false end
	local function pointsTo(value)
		if typeof(value) == "Instance" then
			return value == model or value:IsDescendantOf(model) or model:IsDescendantOf(value)
		end
		if type(value) == "string" and value ~= "" then
			local needle = normalize(value)
			return needle == normalize(model.Name) or needle:find("generator", 1, true) ~= nil
		end
		return false
	end
	for _, container in ipairs({check, character, localPlayer}) do
		for _, name in ipairs({"RepairTarget", "InteractingWith", "InteractionTarget", "GeneratorTarget", "CurrentGenerator"}) do
			if pointsTo(container:GetAttribute(name)) then return true end
			local object = container:FindFirstChild(name, true)
			if object and object:IsA("ObjectValue") and pointsTo(object.Value) then return true end
		end
	end
	return false
end

local function localExitActionProgress(entry)
	if not visibleExitProgressGui() then return nil, nil end
	local root = localRoot()
	if not root or not entry.part or horizontalDistance(root.Position, entry.part.Position) > 15 then
		return nil, nil
	end
	local character = localPlayer.Character
	if not character then return nil, nil end
	for _, name in ipairs(LOCAL_EXIT_PROGRESS_NAMES) do
		local value = character:GetAttribute(name)
		if typeof(value) == "number" and value >= 0 then
			return value, "character." .. name
		end
	end
	for _, object in ipairs(character:GetChildren()) do
		for _, name in ipairs(LOCAL_EXIT_PROGRESS_NAMES) do
			local value = object:GetAttribute(name)
			if typeof(value) == "number" and value >= 0 then
				return value, object.Name .. "." .. name
			end
		end
	end
	return nil, nil
end

local function dynamicExitProgress(entry)
	local now = os.clock()
	if now < (entry.dynamicScanAt or -math.huge) then return nil, nil end
	entry.dynamicScanAt = now + 1.00
	local previous = entry.dynamicNumericSnapshot or {}
	local current = {}
	local bestSource, bestName, bestValue, bestDelta = nil, nil, nil, 0
	local function sample(object, name, value)
		if typeof(value) ~= "number" then return end
		local key = object:GetDebugId() .. ":" .. tostring(name)
		current[key] = value
		local old = previous[key]
		local delta = old and (value - old) or 0
		if delta > bestDelta and value >= 0 and value <= 10000 then
			bestDelta, bestSource, bestName, bestValue = delta, object, name, value
		end
	end
	for name, value in pairs(entry.model:GetAttributes()) do sample(entry.model, name, value) end
	for _, object in ipairs(entry.model:GetDescendants()) do
		for name, value in pairs(object:GetAttributes()) do sample(object, name, value) end
		if object:IsA("NumberValue") or object:IsA("IntValue") then sample(object, VALUE_SENTINEL, object.Value) end
	end
	entry.dynamicNumericSnapshot = current
	if bestSource and bestDelta > 0.0005 then
		entry.progressSource, entry.progressName = bestSource, bestName
		return bestValue, bestSource:GetFullName() .. (bestName == VALUE_SENTINEL and ".Value" or (".Attribute." .. bestName))
	end
	return nil, nil
end

local function exitProgressOf(entry)
	local raw, sourceName = readNumber(entry, "progressSource", "progressName", EXIT_PROGRESS_NAMES)
	local sourceDescription = nil
	if raw ~= nil then
		if sourceName == VALUE_SENTINEL and entry.progressSource then
			sourceDescription = entry.progressSource:GetFullName() .. ".Value"
		elseif entry.progressSource and sourceName then
			sourceDescription = entry.progressSource:GetFullName() .. ".Attribute." .. sourceName
		end
	end

	if raw == nil or tonumber(raw) == 0 then
		local localRaw, localSource = localExitActionProgress(entry)
		if localRaw ~= nil and localRaw > 0 then
			raw, sourceDescription = localRaw, localSource
		end
	end
	local localRootPart = localRoot()
	local localOpening = visibleExitProgressGui()
		and localRootPart ~= nil
		and entry.part ~= nil
		and horizontalDistance(localRootPart.Position, entry.part.Position) <= 16
	if (raw == nil or tonumber(raw) == 0) and localOpening then
		local dynamicRaw, dynamicSource = dynamicExitProgress(entry)
		if dynamicRaw ~= nil and dynamicRaw > 0 then
			raw, sourceDescription = dynamicRaw, dynamicSource
		end
	end

	raw = tonumber(raw) or 0
	entry.progressKnown = sourceDescription ~= nil
	if sourceDescription and entry.loggedProgressSource ~= sourceDescription then
		entry.loggedProgressSource = sourceDescription
		print(string.format("[VD ASSIST v10.0][EXIT_PROGRESS_SOURCE] %s -> %s", entry.model:GetFullName(), sourceDescription))
	end
	-- Ratio interpretation belongs to the source that produced the value. A
	-- gate can replace a 0..1 NumberValue with a 0..100 attribute mid-round;
	-- carrying one boolean across those sources inflated the new value.
	if sourceDescription ~= entry.ratioScaleSource then
		entry.ratioScaleSource = sourceDescription
		entry.ratioScale = false
	end
	if sourceDescription and raw > 0 and raw < 1 then entry.ratioScale = true end
	if entry.ratioScale then raw = raw * 100 end
	if raw == 1 and exitOpenedOf(entry.model, 0, false) then raw = 100 end
	return math.clamp(raw, 0, 100)
end

local function ensureGeneratorVisual(model)
	local entry = runtime.generators[model]
	local part = objectPart(model)
	if not part then return nil end
	if not entry then
		local highlight = ensureHighlight(model, "VDRestoredGenAura")
		-- Keep the model as the adornee.  The interaction/root part can be a
		-- transparent trigger on VD maps; adorning that part makes the whole
		-- generator appear to vanish even though the entry is alive.
		highlight.Adornee = model
		local billboard = Instance.new("BillboardGui")
		billboard.Name = "VDRestoredGenBillboard"
		billboard:SetAttribute("VDRunId", RUN_ID)
		billboard.AlwaysOnTop = true
		billboard.Size = UDim2.fromOffset(120, 30)
		billboard.StudsOffset = Vector3.zero
		billboard.StudsOffsetWorldSpace = Vector3.new(0, 4.8, 0)
		billboard.MaxDistance = CONFIG.labelDistance + 5
		billboard.Enabled = runtime.visible
		billboard.Parent = part
		billboard.Adornee = part

		local label = Instance.new("TextLabel")
		label.Name = "Text"
		label.Size = UDim2.fromScale(1, 1)
		label.BackgroundTransparency = 1
		label.BorderSizePixel = 0
		label.Font = Enum.Font.GothamBold
		label.TextSize = 13
		label.TextStrokeTransparency = 0.35
		label.TextColor3 = COLORS.text
		label.Text = ""
		label.Parent = billboard

		entry = {
			model = model,
			part = part,
			highlight = highlight,
			billboard = billboard,
			label = label,
			seenAt = os.clock(),
			lastProgress = nil,
			lastProgressAt = nil,
			repairRate = nil,
			rateSamples = {},
			rateStartedAt = nil,
			lastWorkerCount = nil,
			visualColor = nil,
			visualFill = nil,
			visualOutline = nil,
			visualEnabled = nil,
			billboardEnabled = nil,
			lastText = nil,
			lastTextColor = nil,
			repairPoints = {},
			repairPointNextScanAt = os.clock() + math.random() * 1.50,
			capacityNextScanAt = os.clock() + math.random() * 1.75,
		}
		runtime.generators[model] = entry
	else
		entry.part = part
		if entry.highlight and entry.highlight.Parent then
			entry.highlight.Adornee = model
		end
		entry.billboard.Adornee = part
		if entry.billboard.Parent ~= part then entry.billboard.Parent = part end
	end
	return entry
end

local function median(values)
	if #values == 0 then return nil end
	local copy = table.clone(values)
	table.sort(copy)
	local middle = math.floor((#copy + 1) / 2)
	if #copy % 2 == 1 then return copy[middle] end
	return (copy[middle] + copy[middle + 1]) * 0.5
end

local function resetRate(entry, progress, now, workerCount)
	entry.lastProgress = progress
	entry.lastProgressAt = now
	entry.repairRate = nil
	entry.rateSamples = {}
	entry.rateStartedAt = now
	entry.lastWorkerCount = workerCount
end

local function updateRepairRate(entry, progress, now, workerCount)
	workerCount = math.max(0, tonumber(workerCount) or 0)
	if entry.lastProgress == nil or entry.lastProgressAt == nil then
		resetRate(entry, progress, now, workerCount)
		return
	end
	if entry.lastWorkerCount ~= workerCount then
		-- The speed changes when another survivor joins/leaves. Old samples would
		-- produce the fake 20/30 second jumps seen at the beginning of repair.
		resetRate(entry, progress, now, workerCount)
		return
	end
	local delta = progress - entry.lastProgress
	local dt = now - entry.lastProgressAt
	if delta < -0.04 then
		resetRate(entry, progress, now, workerCount)
		return
	end
	if delta > 0.025 and dt >= 0.22 then
		local rate = delta / dt
		if rate > 0.025 and rate < 18 then
			entry.rateStartedAt = entry.rateStartedAt or now
			table.insert(entry.rateSamples, rate)
			while #entry.rateSamples > 7 do table.remove(entry.rateSamples, 1) end
			if #entry.rateSamples >= CONFIG.etaWarmupSamples
				and now - entry.rateStartedAt >= CONFIG.etaWarmupTime then
				local robust = median(entry.rateSamples)
				if robust then
					entry.repairRate = entry.repairRate
						and (entry.repairRate * 0.68 + robust * 0.32)
						or robust
				end
			end
		end
		entry.lastProgress = progress
		entry.lastProgressAt = now
	elseif dt > 4.0 then
		-- Do not divide one tiny future change by a long idle period.
		entry.lastProgress = progress
		entry.lastProgressAt = now
		entry.rateSamples = {}
		entry.rateStartedAt = now
		entry.repairRate = nil
	end
end

local function effectiveTravelSpeed(root, humanoid)
	local walkSpeed = humanoid and humanoid.WalkSpeed or 16
	local currentSpeed = root and horizontal(root.AssemblyLinearVelocity).Magnitude or 0
	-- Standing still must not mean an infinite route ETA, but sprint/debuff state
	-- should still affect the estimate.
	if currentSpeed > 2 then
		return math.clamp(currentSpeed * 0.68 + walkSpeed * 0.32, 7, 32)
	end
	return math.clamp(walkSpeed, 7, 32)
end

local function localWalkSpeed()
	local character = localPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	return effectiveTravelSpeed(root, humanoid)
end

local function gamePhase(unfinished, elapsed)
	-- Three unfinished generators is already the clutch phase: grouping for a
	-- fast finish can be better than spreading.
	if unfinished <= 3 then return "late" end
	if unfinished >= 6 and elapsed < 190 then return "early" end
	return "mid"
end

local function workerMultiplier(workers)
	workers = math.max(0, math.floor((tonumber(workers) or 0) + 0.5))
	if workers <= 0 then return 0 end
	if workers == 1 then return 1.00 end
	if workers == 2 then return 1.72 end
	if workers == 3 then return 2.18 end
	return 2.48
end

-- Measured progress already includes the real effect of repair perks, debuffs,
-- item bonuses and the current crew composition. Dividing by the observed crew
-- multiplier gives a practical per-survivor baseline without hard-coding every perk.
local function estimateSoloRate(row)
	local measured = row.entry.repairRate
	if measured and row.repairers > 0 then
		return math.clamp(measured / math.max(0.1, workerMultiplier(row.repairers)), 0.42, 1.75)
	end
	return CONFIG.defaultSoloRate
end

local function characterUnavailable(character)
	if not character then return true end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.Health <= 0 then return true end
	for _, name in ipairs({"Knocked", "Downed", "Dying", "Dead", "Eliminated"}) do
		if character:GetAttribute(name) == true then return true end
	end
	return false
end

local function survivorSnapshot(killer)
	local list = {}
	for _, player in ipairs(Players:GetPlayers()) do
		if player ~= localPlayer and player ~= killer then
			local character = player.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			local humanoid = character and character:FindFirstChildOfClass("Humanoid")
			if root and humanoid and not characterUnavailable(character) then
				table.insert(list, {
					player = player,
					root = root,
					speed = effectiveTravelSpeed(root, humanoid),
				})
			end
		end
	end
	return list
end

local function teammateArrivals(point, survivors)
	local arrivals = {}
	for _, survivor in ipairs(survivors) do
		local offset = horizontal(point - survivor.root.Position)
		local distance = offset.Magnitude
		if distance > CONFIG.teammateNearGenDistance and distance > 0.01 then
			local velocity = horizontal(survivor.root.AssemblyLinearVelocity)
			local speed = velocity.Magnitude
			if speed > 2.0 then
				local toward = velocity.Unit:Dot(offset.Unit)
				if toward >= CONFIG.teammateApproachDot then
					local closing = math.max(0.1, speed * toward)
					local eta = distance / closing
					if eta <= CONFIG.teammateApproachMaxEta then
						table.insert(arrivals, eta)
					end
				end
			end
		end
	end
	table.sort(arrivals)
	while #arrivals > 3 do table.remove(arrivals) end
	return arrivals
end

local function simulateFinish(remaining, initialWorkers, soloRate, arrivals)
	remaining = math.max(0, remaining)
	local workers = math.max(0, initialWorkers)
	local currentTime = 0
	for _, arrival in ipairs(arrivals) do
		arrival = math.max(currentTime, arrival)
		local rate = soloRate * workerMultiplier(workers)
		if rate > 0 then
			local untilFinish = remaining / rate
			if currentTime + untilFinish <= arrival then
				return currentTime + untilFinish
			end
			remaining = math.max(0, remaining - rate * (arrival - currentTime))
		end
		currentTime = arrival
		workers = workers + 1
	end
	local rate = soloRate * workerMultiplier(workers)
	if rate <= 0 then return math.huge end
	return currentTime + remaining / rate
end

local function killerApproach(killerRoot, point)
	if not killerRoot then return math.huge, false, 0 end
	local offset = horizontal(point - killerRoot.Position)
	local distance = offset.Magnitude
	if distance < 0.01 then return 0, true, 0 end
	local velocity = horizontal(killerRoot.AssemblyLinearVelocity)
	local speed = velocity.Magnitude
	if speed < 2.0 then return math.huge, false, speed end
	local toward = velocity.Unit:Dot(offset.Unit)
	if toward < 0.42 then return math.huge, false, speed end
	local closingSpeed = math.max(0.1, speed * toward)
	return distance / closingSpeed, true, speed
end

local function clusterSpreadAfter(rows, excludedModel)
	local positions = {}
	for _, other in ipairs(rows) do
		if other.entry.model ~= excludedModel then
			table.insert(positions, other.entry.part.Position)
		end
	end
	if #positions < 3 or #positions > 4 then return 0 end
	local total, count = 0, 0
	for i = 1, #positions do
		for j = i + 1, #positions do
			total = total + horizontalDistance(positions[i], positions[j])
			count = count + 1
		end
	end
	return count > 0 and total / count or 0
end

local function generatorScore(row, phase, rows, elapsed, objectivesRemaining)
	local remaining = math.max(0, 100 - row.progress)
	local soloRate = estimateSoloRate(row)
	local localAtGen = row.distance <= CONFIG.localAtGenDistance and row.repairers > 0
	local currentWithoutLocal = math.max(0, row.repairers - (localAtGen and 1 or 0))

	local teammateEvents = table.clone(row.teammateArrivals)
	local withoutYou = simulateFinish(remaining, currentWithoutLocal, soloRate, teammateEvents)

	local withYouEvents = table.clone(teammateEvents)
	local initialWithYou = row.repairers
	if not localAtGen then
		table.insert(withYouEvents, row.travelTime)
		table.sort(withYouEvents)
	else
		initialWithYou = math.max(1, row.repairers)
	end
	local withYou = simulateFinish(remaining, initialWithYou, soloRate, withYouEvents)

	local alliesFinishFirst = withoutYou < math.huge
		and withoutYou <= row.travelTime + CONFIG.arrivalBuffer
	local timeSaved = withoutYou < math.huge
		and math.max(0, withoutYou - withYou)
		or math.min(28, math.max(0, 34 - withYou))
	local urgency = math.clamp((elapsed - 210) / 180, 0, 1)

	-- Core value: fastest safe completion plus the amount of time your presence
	-- actually saves. This prevents recommending a gen allies will finish before
	-- you arrive.
	local score = 180
		- withYou * 1.45
		- row.travelTime * 0.28
		+ math.min(timeSaved, 30) * 1.55

	if localAtGen then score = score + 18 end

	-- Crew policy changes through the match.
	if phase == "early" then
		if row.repairers == 0 then score = score + 18
		elseif row.repairers == 1 then score = score + 4
		elseif row.repairers == 2 then score = score - 24
		else score = score - 38 end
	elseif phase == "mid" then
		if row.repairers == 0 then score = score + 7
		elseif row.repairers == 1 then score = score + 18
		elseif row.repairers == 2 then score = score - 7
		else score = score - 22 end
	else
		-- With three or fewer gens left, a two-person finish is often the correct
		-- play. Three-person stacking is only mildly penalised when it ends fast.
		if row.repairers == 0 then score = score + 1
		elseif row.repairers == 1 then score = score + 31
		elseif row.repairers == 2 then score = score + 12 + urgency * 7
		else score = score - 8 + urgency * 5 end
	end

	if alliesFinishFirst then score = score - 165 end
	if row.killerDistance <= CONFIG.killerNearDistance then score = score - 145 end
	if row.killerMovingToward then
		local safety = row.killerEta - withYou
		if safety < -CONFIG.killerUnsafeBuffer then score = score - 185
		elseif safety < 2.5 then score = score - 105
		elseif safety < 6 then score = score - 52
		elseif safety < 11 then score = score - 18 end
	end

	if phase == "late" then
		-- Reward completing the gen that leaves the remaining objectives spread
		-- farther apart, instead of gifting the killer an easy final cluster.
		score = score + math.clamp(clusterSpreadAfter(rows, row.entry.model) * 0.22, 0, 26)
	end

	-- On the last required objective, raw completion time dominates strategy.
	-- This prevents the old nonsense where a nearly empty gen beat one already
	-- halfway repaired because of distance or anti-3-gen bonuses.
	if objectivesRemaining <= 1 then
		score = score + row.progress * 1.15 - withYou * 1.65
		if row.progress >= 70 then score = score + 42
		elseif row.progress >= 45 then score = score + 28
		elseif row.progress < 12 then score = score - 24 end
		if row.repairers >= 1 then score = score + 24 end
	end

	row.etaWithYou = withYou
	row.etaWithoutYou = withoutYou
	row.alliesFinishFirst = alliesFinishFirst
	row.timeSaved = timeSaved
	row.localAtGen = localAtGen
	row.crewPlan = localAtGen and "stay"
		or (row.repairers == 0 and "solo"
		or row.repairers == 1 and "duo"
		or "stack")
	return score
end

local function addGeneratorCandidate(instance)
	local root = generatorRootFrom(instance)
	if root and not runtime.generators[root] then
		ensureGeneratorVisual(root)
	end
end

local function indexKnownGeneratorContainers()
	-- The supplied map uses Workspace.Map.Generators.Generator. Keep this
	-- fallback deliberately shallow: it catches late replication without
	-- reintroducing a per-frame Workspace:GetDescendants() scan.
	local map = Workspace:FindFirstChild("Map")
	if not map then return 0 end
	local indexed = 0
	local containers = {}
	for _, name in ipairs({"Generators", "NewGenerators", "GeneratorContainer"}) do
		local container = map:FindFirstChild(name)
		if container then table.insert(containers, container) end
	end
	local function probe(parent)
		local ok, children = pcall(function() return parent:GetChildren() end)
		if not ok or type(children) ~= "table" then return end
		for _, child in ipairs(children) do
			local childName = normalize(child.Name)
			if child:IsA("Model") or child:IsA("BasePart") then
				if hasGeneratorSignal(child)
					or childName:find("generator", 1, true)
					or childName == "gen" then
					local childRoot = generatorRootFrom(child)
					local before = childRoot and runtime.generators[childRoot] or nil
					addGeneratorCandidate(child)
					if childRoot and not before then indexed += 1 end
				end
				-- Some streamed variants insert one folder/model between the
				-- container and the physical generator. One extra level is enough.
				if child:IsA("Model") or child:IsA("Folder") then
					local nestedOk, nested = pcall(function() return child:GetChildren() end)
					if nestedOk and type(nested) == "table" then
						for _, grandchild in ipairs(nested) do
							local grandName = normalize(grandchild.Name)
							if grandchild:IsA("Model") or grandchild:IsA("BasePart") then
								if hasGeneratorSignal(grandchild)
									or grandName:find("generator", 1, true)
									or grandName == "gen" then
									local nestedRoot = generatorRootFrom(grandchild)
									local beforeNested = nestedRoot and runtime.generators[nestedRoot] or nil
									addGeneratorCandidate(grandchild)
									if nestedRoot and not beforeNested then indexed += 1 end
								end
							end
						end
					end
				end
			end
		end
	end
	for _, container in ipairs(containers) do probe(container) end
	return indexed
end

local function addExitCandidate(instance)
	local root = exitRootFrom(instance)
	if root and not runtime.exits[root] then
		ensureExitEntry(root)
	end
end

local function findAncestorModelWithName(instance, word)
	local current = instance
	while current and current ~= Workspace do
		if current:IsA("Model") and normalize(current.Name):find(word, 1, true) then
			return current
		end
		current = current.Parent
	end
	return nil
end

local function firstAncestorModel(instance)
	local current = instance.Parent
	while current and current ~= Workspace do
		if current:IsA("Model") then return current end
		current = current.Parent
	end
	return nil
end

local function interactionPart(model)
	if not model then return nil end
	for _, child in ipairs(model:GetDescendants()) do
		if child:IsA("ProximityPrompt") and child.Parent and child.Parent:IsA("BasePart") then
			return child.Parent
		end
	end
	for _, child in ipairs(model:GetDescendants()) do
		if child:IsA("BasePart") then
			local name = normalize(child.Name)
			if name:find("interact", 1, true)
				or name:find("trigger", 1, true)
				or name:find("prompt", 1, true)
				or name:find("root", 1, true) then
				return child
			end
		end
	end
	return objectPart(model)
end

local function palletBroken(model)
	return attributeTrue(model, {"Broken", "IsBroken", "Destroyed", "Used", "IsUsed"})
end

local function namedBasePart(root, wantedName)
	if not root then return nil end
	local direct = root:FindFirstChild(wantedName)
	if direct and direct:IsA("BasePart") then return direct end
	-- Named anchors in the supplied map are direct children. Keep a bounded
	-- fallback for streamed variants, but call it only after strict model
	-- evidence has identified a real route model (never during classification).
	for _, object in ipairs(root:GetDescendants()) do
		if object:IsA("BasePart") and normalize(object.Name) == normalize(wantedName) then
			return object
		end
	end
	return nil
end

local function palletAnchor(model)
	if not model or not model:IsA("Model") then return nil end
	local cached = runtime.routeAnchorCache[model]
	if cached and cached.kind == "Pallet" and cached.part and cached.part.Parent then
		return cached.part
	end
	for _, name in ipairs({"Primary1", "Primary2", "PrimaryPartPallet"}) do
		local part = namedBasePart(model, name)
		if part then
			runtime.routeAnchorCache[model] = {kind = "Pallet", part = part}
			return part
		end
	end
	if model.PrimaryPart and model.PrimaryPart:IsA("BasePart") then
		runtime.routeAnchorCache[model] = {kind = "Pallet", part = model.PrimaryPart}
		return model.PrimaryPart
	end
	local best, bestVolume = nil, -1
	for _, object in ipairs(model:GetDescendants()) do
		if object:IsA("BasePart") then
			local n = normalize(object.Name)
			if n ~= "humanoidrootpart" and not n:find("trigger", 1, true) and not n:find("hitbox", 1, true) then
				local volume = object.Size.X * object.Size.Y * object.Size.Z
				if volume > bestVolume then
					best, bestVolume = object, volume
				end
			end
		end
	end
	if best then runtime.routeAnchorCache[model] = {kind = "Pallet", part = best} end
	return best
end

local function windowAnchor(model)
	if not model then return nil end
	local cached = runtime.routeAnchorCache[model]
	if cached and cached.kind == "Window" and cached.part and cached.part.Parent then
		return cached.part
	end
	for _, wanted in ipairs({"VaultTrigger", "VaultPoint", "WindowTrigger", "WindowPoint", "Trigger", "Interaction"}) do
		local trigger = model:FindFirstChild(wanted)
		if trigger and trigger:IsA("BasePart") then return trigger end
	end
	-- A number of maps expose only a visible frame/board and keep the vault
	-- trigger unnamed.  Do not drop those windows just because the conventional
	-- trigger name is absent.  Prefer a visible physical part and leave the
	-- model itself as the highlight adornee so transparent hitboxes cannot hide
	-- the aura.
	for _, object in ipairs(model:GetDescendants()) do
		if object:IsA("BasePart") and object.Transparency < 0.98 then
			local name = normalize(object.Name)
			if not name:find("trigger", 1, true)
				and not name:find("hitbox", 1, true)
				and not name:find("prompt", 1, true) then
				runtime.routeAnchorCache[model] = {kind = "Window", part = object}
				return object
			end
		end
	end
	local fallback = objectPart(model)
	if fallback then runtime.routeAnchorCache[model] = {kind = "Window", part = fallback} end
	return fallback
end

local function fullPath(instance)
	if not instance then return "nil" end
	local ok, value = pcall(function() return instance:GetFullName() end)
	return ok and value or tostring(instance)
end

local function resolveWorkspacePath(path)
	if type(path) ~= "string" or path == "" then return nil end
	local parts = {}
	for token in string.gmatch(path, "[^%.]+") do table.insert(parts, token) end
	if #parts == 0 then return nil end
	local current = Workspace
	local index = 1
	if parts[1] == "Workspace" or parts[1] == "workspace" then index = 2 end
	for i = index, #parts do
		current = current and current:FindFirstChild(parts[i]) or nil
		if not current then return nil end
	end
	return current
end

local function routePathBlocked(root)
	local path = fullPath(root)
	if routeConfig.whitelist[path] ~= nil then return false end
	if routeConfig.blacklist[path] == true then return true end
	local current = root and root.Parent
	while current and current ~= Workspace do
		if routeConfig.blacklist[fullPath(current)] == true then return true end
		current = current.Parent
	end
	return false
end

local function removeRoute(root)
	local entry = root and runtime.routes[root]
	if not entry then return end
	if entry.highlight then entry.highlight:Destroy() end
	runtime.routes[root] = nil
end

local function windowHasVisibleGeometry(root)
	if not root or not root:IsA("Model") then return false end
	for _, object in ipairs(root:GetDescendants()) do
		if object:IsA("BasePart") and object.Transparency < 0.98 then
			local name = normalize(object.Name)
			if name ~= "vaulttrigger" and name ~= "vaultpoint"
				and not name:find("trigger", 1, true)
				and not name:find("hitbox", 1, true)
				and not name:find("invis", 1, true)
				and not name:find("prompt", 1, true) then
				return true
			end
		end
	end
	return false
end

local function routeHighlightHost(root, kind, part)
	-- Pallets are multi-part models, so adorn the model to cover both boards.
	-- Windows normally have visible Part/Bottom geometry and an invisible
	-- VaultTrigger; use the model when that geometry exists and a marker only
	-- while a streamed variant exposes no visible geometry yet.
	if kind == "Window" and not windowHasVisibleGeometry(root) then return part end
	return root
end

-- Workspace also contains lobby and pooled map clones. Route discovery must
-- stay inside the active Map or those copies become false route auras.
local function isActiveMapRoute(root)
	if not root or not root:IsDescendantOf(Workspace) then return false end
	local map = Workspace:FindFirstChild("Map")
	return map ~= nil and root:IsDescendantOf(map)
end

local function ensureWindowSelection(part)
	local name = "VDAssistWindowSelection_" .. RUN_ID
	local existing = part:FindFirstChild(name)
	if existing and existing:IsA("SelectionBox")
		and existing:GetAttribute("VDRunId") == RUN_ID then
		existing.Adornee = part
		existing.Visible = runtime.visible
		return existing
	end
	local selection = Instance.new("SelectionBox")
	selection.Name = name
	selection:SetAttribute("VDRunId", RUN_ID)
	selection.Adornee = part
	selection.Color3 = COLORS.window
	selection.SurfaceColor3 = COLORS.window
	selection.SurfaceTransparency = 1
	selection.LineThickness = 0.08
	selection.Visible = runtime.visible
	selection.Parent = part
	return selection
end

local function ensureRouteVisual(root, kind, part)
	if kind == "Window" and routeHighlightHost(root, kind, part) == part
		and part and part:IsA("BasePart") then
		return ensureWindowSelection(part)
	end
	return ensureHighlight(root, "VDRestoredRouteAura")
end

local function applyRouteVisual(entry, color, fillTransparency, outlineTransparency, enabled)
	local visual = entry and entry.highlight
	if visual and visual:IsA("SelectionBox") then
		if entry.visualColor ~= color then
			entry.visualColor = color
			visual.Color3 = color
			visual.SurfaceColor3 = color
		end
		if visual.Visible ~= enabled then visual.Visible = enabled end
		return
	end
	applyHighlight(entry, color, fillTransparency, outlineTransparency, enabled)
end

local function disableRouteVisual(entry)
	local visual = entry and entry.highlight
	if not visual then return end
	if visual:IsA("SelectionBox") then
		visual.Visible = false
	else
		visual.Enabled = false
	end
end

local function addRoute(root, kind, partOverride)
	if not root or not isActiveMapRoute(root) then return end
	local now = os.clock()
	local lastAdd = runtime.routeAddAt[root]
	if lastAdd and now - lastAdd < 0.12 and runtime.routes[root] then return end
	runtime.routeAddAt[root] = now
	local path = fullPath(root)
	local manualKind = routeConfig.whitelist[path]
	if manualKind ~= nil then kind = tostring(manualKind) end
	if routePathBlocked(root) then
		removeRoute(root)
		return
	end
	local part = partOverride
	if not part or not part:IsA("BasePart") then
		part = kind == "Pallet" and palletAnchor(root)
			or (kind == "Window" and windowAnchor(root))
			or interactionPart(root)
	end
	if not part or not part:IsA("BasePart") then return end
	local host = routeHighlightHost(root, kind, part)
	local existing = runtime.routes[root]
	if existing then
		existing.part = part
		existing.kind = kind
		if existing.highlightHost ~= host then
			if existing.highlight then existing.highlight:Destroy() end
			existing.highlight = ensureRouteVisual(root, kind, part)
			existing.highlightHost = host
			existing.visualEnabled = nil
			existing.visualColor = nil
		end
		return
	end
	local highlight = ensureRouteVisual(root, kind, part)
	runtime.routes[root] = {
		root = root,
		part = part,
		kind = kind,
		highlight = highlight,
		highlightHost = host,
	}
end

local function directWindowEvidence(model)
	if not model or not model:IsA("Model") then return false end
	local modelName = normalize(model.Name)
	local ownTag = CollectionService:HasTag(model, "window")
		or CollectionService:HasTag(model, "Window")
	if modelName ~= "window" and not ownTag then return false end
	for _, child in ipairs(model:GetChildren()) do
		local childName = normalize(child.Name)
		if CollectionService:HasTag(child, "VaultPoint")
			or CollectionService:HasTag(child, "window")
			or childName == "vaulttrigger"
			or childName == "vaultpoint"
			or childName == "bottom" then
			return true
		end
	end
	return false
end

local function addWindowCandidate(instance)
	if not instance then return end
	local name = normalize(instance.Name)
	local tagged = CollectionService:HasTag(instance, "VaultPoint")
		or CollectionService:HasTag(instance, "window")
	local root = nil
	if instance:IsA("Model") and directWindowEvidence(instance) then
		root = instance
	elseif instance.Parent and instance.Parent:IsA("Model")
		and directWindowEvidence(instance.Parent) then
		root = instance.Parent
	end
	-- A tagged marker belongs only to its immediate owning Window model. Never
	-- promote a generic tagged descendant to Maze/Map or another container.
	if not root and tagged then
		-- A tagged VaultPoint/window part belongs to its immediate model in the
		-- supplied map. Never promote it to Map/Maze merely because an ancestor
		-- happens to contain a window somewhere below it.
		local owner = instance.Parent
		if owner and owner:IsA("Model") then
			local ownerName = normalize(owner.Name)
			if (ownerName == "window" or ownerName:find("vault", 1, true))
				and directWindowEvidence(owner) then
				root = owner
			end
		end
	end
	if not root or not directWindowEvidence(root) then return end
	-- Maps differ on whether the vault marker is named VaultTrigger, Trigger,
	-- WindowPoint, or only carries the VaultPoint tag.  Once an instance sits in
	-- a clearly named window/vault model, accept the model's concrete anchor as
	-- the fallback as well.
	if name ~= "vaulttrigger" and name ~= "vaultpoint"
		and name ~= "windowtrigger" and name ~= "windowpoint"
		and name ~= "trigger" and name ~= "interaction"
		and not tagged and instance ~= root then
		return
	end
	local part = nil
	if instance:IsA("BasePart") then
		part = instance
	else
		part = windowAnchor(root)
	end
	part = part or windowAnchor(root)
	if not part or not part:IsA("BasePart") then return end
	addRoute(root, "Window", part)
end

local function isRealPalletModel(model)
	if not model or not model:IsA("Model") then return false end
	local name = normalize(model.Name)
	local modelTagged = CollectionService:HasTag(model, "Pallet")
		or CollectionService:HasTag(model, "pallet")
	local namedModel = name == "palletwrong" or name == "pallet"
	if not modelTagged and not namedModel then return false end
	-- Evidence must be owned by this model. In particular, do not use a tagged
	-- descendant anywhere in Map/Maze to promote the container to a pallet.
	local directPoint = false
	local directAnchor = false
	for _, child in ipairs(model:GetChildren()) do
		if CollectionService:HasTag(child, "PalletPoint")
			or normalize(child.Name) == "palletpoint" then
			directPoint = true
		end
		if child:IsA("BasePart") then
			local childName = normalize(child.Name)
			if childName == "primary1" or childName == "primary2"
				or childName == "primarypartpallet" or childName == "palletpoint" then
				directAnchor = true
			end
		end
	end
	if not directPoint and not directAnchor and not model.PrimaryPart then
		return false
	end
	return palletAnchor(model) ~= nil
end

local function addPalletCandidate(instance)
	local current = instance
	for _ = 1, 7 do
		if not current or current == Workspace then break end
		if current:IsA("Model") and isRealPalletModel(current) then
			addRoute(current, "Pallet", palletAnchor(current))
			return
		end
		current = current.Parent
	end
end

local function scanWorkspace()
	if state.scanInProgress then return end
	state.scanInProgress = true
	state.scanDirty = false
	local map = Workspace:FindFirstChild("Map")
	if state.lastMap ~= map then
		-- A pooled map can remain parented after the new round appears. Drop all
		-- entries that belong to that old map immediately; waiting for the next
		-- update let stale recommendations leak across rounds.
		local function inCurrentMap(model)
			return not map or model:IsDescendantOf(map)
		end
		for model, entry in pairs(runtime.generators) do
			if not inCurrentMap(model) then
				if entry.highlight then entry.highlight:Destroy() end
				if entry.billboard then entry.billboard:Destroy() end
				runtime.generators[model] = nil
			end
		end
		for model, entry in pairs(runtime.exits) do
			if not inCurrentMap(model) then
				if entry.highlight then entry.highlight:Destroy() end
				if entry.billboard then entry.billboard:Destroy() end
				runtime.exits[model] = nil
			end
		end
		for root in pairs(runtime.routes) do
			if not inCurrentMap(root) then removeRoute(root) end
		end
		-- Replace the history object instead of clearing it in place. A hot
		-- reloaded copy can leave the old field nil while scanWorkspace is
		-- already queued; assignment is safe in both cases.
		runtime.progressHistory = {}
		state.lastMap = map
		state.roundArmed = false
		state.sawLiveUnfinished = false
		state.exitMode = false
		state.exitReadySince = nil
		state.bestExit = nil
		state.bestGenerator = nil
		state.pendingGenerator = nil
		state.roundStartedAt = nil
	end
	local searchRoot = map or Workspace

	-- Breadth-first, yielded scan. The old one-shot GetDescendants loop could
	-- stall one frame on large maps, especially when a pallet prompt appeared
	-- at the same moment. Normal new objects are still handled by DescendantAdded.
	task.spawn(function()
		local scanOk, scanError = xpcall(function()
		local queue = {searchRoot}
		local head = 1
		local processed = 0
		local batchStartedAt = os.clock()
		while runtime.running and _G[KEY] == runtime and head <= #queue do
			local parent = queue[head]
			head += 1
			local ok, children = pcall(function() return parent:GetChildren() end)
			if ok and type(children) == "table" then
				for _, object in ipairs(children) do
					table.insert(queue, object)
					if not runtime.running or _G[KEY] ~= runtime then return end
					if object:IsA("Model") or object:IsA("BasePart") then
						if hasGeneratorSignal(object)
							or normalize(object.Name):find("generator", 1, true) then
							addGeneratorCandidate(object)
						end
						addExitCandidate(object)
						if object:IsA("Model") then addZombieCandidate(object) end
						addPalletCandidate(object)
						addWindowCandidate(object)
					elseif object:IsA("ProximityPrompt") then
						addExitCandidate(object)
						addWindowCandidate(object)
					end
					processed += 1
					-- Keep each scan slice below the configured wall-clock budget.
					-- DescendantAdded remains responsible for newly streamed objects;
					-- this yield only protects the initial/periodic index pass.
					if processed % 90 == 0
						or os.clock() - batchStartedAt >= CONFIG.scanBatchBudget then
						RunService.Heartbeat:Wait()
						batchStartedAt = os.clock()
					end
				end
			end
		end
		if not runtime.running or _G[KEY] ~= runtime then return end
		for path, kind in pairs(routeConfig.whitelist) do
			local object = resolveWorkspacePath(path)
			if object then addRoute(object, tostring(kind), objectPart(object)) end
		end
		state.lastScan = os.clock()
		local routeCount, generatorCount = 0, 0
		for _ in pairs(runtime.routes) do routeCount += 1 end
		for _ in pairs(runtime.generators) do generatorCount += 1 end
		if routeCount ~= state.lastRouteCount or generatorCount ~= state.lastGeneratorCount then
			state.lastRouteCount = routeCount
			state.lastGeneratorCount = generatorCount
			print(string.format(
				"[VD ASSIST v10.0][INDEX] generators=%d routes=%d",
				generatorCount, routeCount
			))
		end
		-- Initial scans can legitimately finish before streamed generator models
		-- exist. Retry once after the map settles instead of waiting for the long
		-- safety rescan or forcing a full hierarchy walk every frame.
		if generatorCount == 0
			and Workspace:FindFirstChild("Map") ~= nil
			and not state.initialEmptyIndexRetryScheduled then
			state.initialEmptyIndexRetryScheduled = true
			task.delay(CONFIG.initialEmptyIndexRetryDelay, function()
				if not runtime.running or _G[KEY] ~= runtime then return end
				state.initialEmptyIndexRetryScheduled = false
				local found = indexKnownGeneratorContainers()
				if found == 0 and next(runtime.generators) == nil then
					state.scanDirty = true
				end
			end)
		end
		end, debug.traceback)
		state.scanInProgress = false
		if not scanOk and runtime.running and _G[KEY] == runtime then
			state.scanDirty = true
			warn("[VD ASSIST v10.0][SCAN_ERROR] " .. tostring(scanError))
		end
	end)
end

local function updateGenerators(now)
	local root = localRoot()
	local killerRoot = playerRoot(state.killer)
	local rows = {}
	local totalGenerators = 0
	local unfinished = 0
	local sawActivity = false
	local completedCount = 0
	local walkSpeed = localWalkSpeed()
	local survivors = survivorSnapshot(state.killer)

	for model, entry in pairs(runtime.generators) do
		if not model.Parent or not entry.part.Parent then
			if entry.highlight then entry.highlight:Destroy() end
			if entry.billboard then entry.billboard:Destroy() end
			runtime.generators[model] = nil
		else
			totalGenerators = totalGenerators + 1
			local progress = progressOf(entry)
			local progressKnown = entry.progressSource ~= nil
				and entry.progressSource.Parent ~= nil
			local repairers = repairersOf(entry)
			local progressPaused = attributeTrue(model, {"ProgressPaused"})
			local kickCount = attributeNumber(model, {"kickcount", "KickCount"}) or 0
			local complete = completedOf(model, progress)
			local unusable = unusableOf(model)
			local slotCapacity, occupiedSlots, rawSlotsFull, capacitySource = generatorSlotState(entry, repairers, now)
			local localDistance = root and horizontalDistance(root.Position, entry.part.Position) or math.huge
			local localAlreadyRepairing = localOwnsRepairInteraction(model)
			entry.currentProgress = progress
			entry.currentProgressKnown = progressKnown
			entry.currentRepairers = repairers
			entry.currentProgressPaused = progressPaused
			entry.currentKickCount = kickCount
			entry.currentComplete = complete
			entry.currentUnusable = unusable
			entry.currentSlotCapacity = slotCapacity
			entry.currentOccupiedSlots = occupiedSlots
			entry.currentSlotsFull = rawSlotsFull
			entry.currentLocalAtGen = localAlreadyRepairing
			entry.currentUpdatedAt = now
			if rawSlotsFull then
				if entry.rawSlotsFull ~= true then
					entry.rawSlotsFull = true
					entry.rawSlotsFullSince = now
				end
				if entry.stableSlotsFull == nil then entry.stableSlotsFull = false end
				if entry.stableSlotsFull ~= true
					and now - (entry.rawSlotsFullSince or now) >= CONFIG.fullStateDebounce then
					entry.stableSlotsFull = true
				end
			else
				-- Opening a repair slot is safe to show immediately. Debouncing this
				-- transition caused impossible logs such as occupied=0/2 hidden.
				entry.rawSlotsFull = false
				entry.rawSlotsFullSince = now
				entry.stableSlotsFull = false
			end
			local slotsFull = entry.stableSlotsFull
			if progress > 0.1 or repairers > 0 or complete then sawActivity = true end
			if complete then completedCount = completedCount + 1 end
			if complete or unusable then
				entry.wasSlotsFull = false
				applyHighlight(entry, COLORS.generator, 0.98, 0.42, false)
				setBillboard(entry, false, nil, nil)
			else
				unfinished = unfinished + 1
				updateRepairRate(entry, progress, now, repairers)
				local hideBecauseFull = slotsFull and not localAlreadyRepairing
				if hideBecauseFull then
					if entry.wasSlotsFull ~= true then
						print(string.format(
							"[VD ASSIST v10.0][GEN_FULL] %s occupied=%d/%d source=%s hidden",
							model:GetFullName(), occupiedSlots, slotCapacity, tostring(capacitySource)
						))
					end
					entry.wasSlotsFull = true
					-- A full repair slot makes a generator ineligible for the next
					-- target, but it remains a real unfinished generator. Keep a
					-- readable outline: 0.995/0.55 was effectively invisible on
					-- dark maps and made every occupied generator look deleted.
					applyHighlight(entry, COLORS.generator, 0.90, 0.20, runtime.visible)
					setBillboard(entry, false, nil, nil)
				else
					if entry.wasSlotsFull == true then
						if slotsFull and localAlreadyRepairing then
							print(string.format(
								"[VD ASSIST v10.0][GEN_FULL_LOCAL] %s occupied=%d/%s; keeping your active label",
								model:GetFullName(), occupiedSlots, slotCapacity and tostring(slotCapacity) or "?"
							))
						else
							print(string.format(
								"[VD ASSIST v10.0][GEN_SLOT_OPEN] %s occupied=%d/%s visible",
								model:GetFullName(), occupiedSlots, slotCapacity and tostring(slotCapacity) or "?"
							))
						end
					end
					entry.wasSlotsFull = false
					local distance = localDistance
					local killerDistance = killerRoot and horizontalDistance(killerRoot.Position, entry.part.Position) or math.huge
					local killerEta, killerMovingToward, killerSpeed = killerApproach(killerRoot, entry.part.Position)
					local killerPotentialEta = killerRoot and killerDistance / math.max(14, killerSpeed) or math.huge
					table.insert(rows, {
						entry = entry,
						progress = progress,
						distance = distance,
						localAtGen = localAlreadyRepairing,
						travelTime = distance / math.max(8, walkSpeed * 0.88),
						killerDistance = killerDistance,
						killerEta = killerEta,
						killerMovingToward = killerMovingToward,
						killerSpeed = killerSpeed,
						killerPotentialEta = killerPotentialEta,
						repairers = repairers,
						progressPaused = progressPaused,
						kickCount = kickCount,
						slotCapacity = slotCapacity,
						occupiedSlots = occupiedSlots,
						teammateArrivals = teammateArrivals(entry.part.Position, survivors),
					})
				end
			end
		end
	end

	local requiredCompletions = math.max(1, totalGenerators - CONFIG.spareGeneratorCount)
	local objectivesRemaining = math.max(0, requiredCompletions - completedCount)
	runtime.dataRevision += 1
	runtime.dataUpdatedAt = now
	runtime.totalGenerators = totalGenerators
	runtime.completedGenerators = completedCount
	runtime.requiredCompletions = requiredCompletions
	runtime.objectivesRemaining = objectivesRemaining

	-- Arm the round only after this script has actually observed a live stage with
	-- unfinished generators. This prevents stale completed map models in the lobby
	-- from creating fake exit markers.
	if totalGenerators >= 3 and unfinished > 0 and (sawActivity or state.killer ~= nil) then
		state.sawLiveUnfinished = true
		state.roundArmed = true
		state.roundStartedAt = state.roundStartedAt or now
	end
	local exitCandidate = state.roundArmed
		and state.sawLiveUnfinished
		and totalGenerators >= 3
		and objectivesRemaining == 0
	if exitCandidate then
		state.exitReadySince = state.exitReadySince or now
		if now - state.exitReadySince >= CONFIG.exitConfirmDelay then state.exitMode = true end
	else
		state.exitReadySince = nil
		state.exitMode = false
	end

	if state.exitMode then
		state.bestGenerator = nil
		state.pendingGenerator = nil
		runtime.baseGeneratorRecommendation = nil
		runtime.baseGeneratorRecommendationInfo = nil
		for _, row in ipairs(rows) do
			applyHighlight(row.entry, COLORS.generator, 0.98, 0.42, false)
			setBillboard(row.entry, false, nil, nil)
		end
		_G.VDGenRecommendation = nil
		_G.VDGenRecommendationInfo = nil
		return
	end

	local elapsed = state.roundStartedAt and now - state.roundStartedAt or 0
	local phase = gamePhase(objectivesRemaining, elapsed)
	local anti3Owner = runtime.anti3Owner
	local anti3Active = type(anti3Owner) == "table"
		and anti3Owner.running == true
	for _, row in ipairs(rows) do
		row.score = generatorScore(row, phase, rows, elapsed, objectivesRemaining)
	end
	table.sort(rows, function(a, b) return a.score > b.score end)
	local candidate = rows[1]
	local current = nil
	for _, row in ipairs(rows) do
		if row.entry.model == state.bestGenerator then current = row break end
	end
	if not current then
		state.bestGenerator = candidate and candidate.entry.model or nil
		state.bestSince = now
		state.pendingGenerator = nil
		if candidate then
			print(string.format(
				"[VD ASSIST v10.0][GEN_TARGET] phase=%s objectives=%d progress=%.0f repairers=%d eta=%.1fs saved=%.1fs killerEta=%s",
				phase, objectivesRemaining, candidate.progress, candidate.repairers,
				candidate.etaWithYou or -1, candidate.timeSaved or 0,
				candidate.killerEta < math.huge and string.format("%.1f", candidate.killerEta) or "inf"
			))
		end
	elseif candidate and candidate.entry.model ~= current.entry.model
		and candidate.score >= current.score + CONFIG.targetSwitchMargin then
		if state.pendingGenerator ~= candidate.entry.model then
			state.pendingGenerator = candidate.entry.model
			state.pendingGeneratorSince = now
		elseif now - state.pendingGeneratorSince >= CONFIG.targetConfirmTime
			and now - state.bestSince >= CONFIG.targetHold then
			state.bestGenerator = candidate.entry.model
			state.bestSince = now
			state.pendingGenerator = nil
			print(string.format(
				"[VD ASSIST v10.0][GEN_TARGET] phase=%s objectives=%d progress=%.0f repairers=%d eta=%.1fs saved=%.1fs killerEta=%s",
				phase, objectivesRemaining, candidate.progress, candidate.repairers,
				candidate.etaWithYou or -1, candidate.timeSaved or 0,
				candidate.killerEta < math.huge and string.format("%.1f", candidate.killerEta) or "inf"
			))
		end
	else
		state.pendingGenerator = nil
	end

	local chosen = nil
	for _, row in ipairs(rows) do
		local best = row.entry.model == state.bestGenerator
		if best then chosen = row end
		local danger = row.killerDistance <= CONFIG.killerNearDistance
			or (row.killerMovingToward and row.killerEta < 7)
		local color = danger and COLORS.danger or (best and COLORS.best or COLORS.generator)
		if anti3Active then
			-- Anti3 owns the live target/danger colors. Keep a visible base style
			-- as a fallback, though, so a delayed Anti3 tick (or a stale owner
			-- during script startup) cannot leave every generator visually blank.
			-- Once Anti3 has written a color into visualColor, Assist only updates
			-- the Enabled gate and does not overwrite that choice.
			if row.entry.highlight then
				row.entry.highlight.Enabled = runtime.visible
				if row.entry.visualColor == nil then
					applyHighlight(
						row.entry,
						COLORS.generator,
						0.90,
						0.12,
						runtime.visible
					)
				end
			end
		else
			applyHighlight(
				row.entry,
				color,
				best and 0.88 or 0.90,
				best and 0.06 or 0.12,
				runtime.visible
			)
		end

		local close = (row.distance <= CONFIG.labelDistance or row.localAtGen)
			and now - row.entry.seenAt >= CONFIG.initialLabelDelay
		if close then
			local text = string.format("%d%%", math.floor(row.progress + 0.5))
			local eta = row.localAtGen and row.etaWithYou or row.etaWithoutYou
			if (not eta or eta == math.huge) and row.repairers > 0 then
				eta = (100 - row.progress) / math.max(0.1, CONFIG.defaultSoloRate * workerMultiplier(row.repairers))
			end
			if eta and eta > 0 and eta < 240 then
				text = text .. string.format(" • ~%dс", math.max(1, math.floor(eta + 0.5)))
			end
			local shownKillerEta = row.killerMovingToward and row.killerEta or row.killerPotentialEta
			if shownKillerEta and shownKillerEta < 90 then
				text = text .. string.format(
					row.killerMovingToward and " • МАН ~%dс" or " • МАН ≤%dс",
					math.max(1, math.floor(shownKillerEta + 0.5))
				)
			end
			setBillboard(row.entry, runtime.visible, text, color)
		else
			setBillboard(row.entry, false, nil, nil)
		end
	end

	runtime.baseGeneratorRecommendation = state.bestGenerator
	runtime.baseGeneratorRecommendationInfo = chosen and {
		phase = phase,
		score = chosen.score,
		progress = chosen.progress,
		repairers = chosen.repairers,
		progressPaused = chosen.progressPaused,
		kickCount = chosen.kickCount,
		slotCapacity = chosen.slotCapacity,
		occupiedSlots = chosen.occupiedSlots,
		travelTime = chosen.travelTime,
		etaWithYou = chosen.etaWithYou,
		etaWithoutYou = chosen.etaWithoutYou,
		alliesFinishFirst = chosen.alliesFinishFirst,
		timeSaved = chosen.timeSaved,
		crewPlan = chosen.crewPlan,
		incomingSurvivors = #chosen.teammateArrivals,
		localSpeed = walkSpeed,
		killerEta = chosen.killerEta,
		completed = completedCount,
		unfinishedModels = unfinished,
		requiredCompletions = requiredCompletions,
		objectivesRemaining = objectivesRemaining,
	} or nil
	if not anti3Active then
		_G.VDGenRecommendation = runtime.baseGeneratorRecommendation
		_G.VDGenRecommendationInfo = runtime.baseGeneratorRecommendationInfo
	end
end

function runtime.GetAnti3Snapshot()
	local rows = {}
	for model, entry in pairs(runtime.generators) do
		if model.Parent and entry.part and entry.part.Parent
			and entry.currentUpdatedAt == runtime.dataUpdatedAt then
			table.insert(rows, {
				model = model,
				entry = entry,
				part = entry.part,
				progress = entry.currentProgress or 0,
				progressKnown = entry.currentProgressKnown == true,
				repairers = entry.currentRepairers or 0,
				progressPaused = entry.currentProgressPaused == true,
				kickCount = entry.currentKickCount or 0,
				complete = entry.currentComplete == true,
				unusable = entry.currentUnusable == true,
				slotsFull = entry.currentSlotsFull == true,
				localAtGen = entry.currentLocalAtGen == true,
			})
		end
	end
	return {
		apiVersion = runtime.apiVersion,
		revision = runtime.dataRevision,
		updatedAt = runtime.dataUpdatedAt,
		visible = runtime.visible,
		roundArmed = state.roundArmed,
		exitMode = state.exitMode,
		rows = rows,
		totalGenerators = runtime.totalGenerators,
		completedGenerators = runtime.completedGenerators,
		requiredCompletions = runtime.requiredCompletions,
		objectivesRemaining = runtime.objectivesRemaining,
		localRoot = localRoot(),
		killerPlayer = state.killer,
		killerRoot = playerRoot(state.killer),
		baseRecommendation = runtime.baseGeneratorRecommendation,
		baseRecommendationInfo = runtime.baseGeneratorRecommendationInfo,
	}
end

local function exitScore(row)
	local remaining = math.max(0, 100 - row.progress)
	local workers = math.max(1, row.repairers)
	local rate = row.entry.repairRate or (CONFIG.defaultSoloRate * workerMultiplier(workers))
	local openEta = row.opened and 0 or remaining / math.max(0.1, rate)
	local travelTime = row.distance / math.max(8, localWalkSpeed() * 0.88)
	local totalEta = travelTime + openEta
	local score = 120 - totalEta * 1.3
	if row.opened then score = score + 100 end
	if row.killerDistance <= CONFIG.killerNearDistance then score = score - 140 end
	if row.killerMovingToward then
		local margin = row.killerEta - totalEta
		if margin < 0 then score = score - 130
		elseif margin < 5 then score = score - 70
		elseif margin < 10 then score = score - 25 end
	end
	row.openEta = openEta
	row.totalEta = totalEta
	return score
end

local function localOpeningExit(entry)
	local root=localRoot()
	if not root or not entry or not entry.part or horizontalDistance(root.Position,entry.part.Position)>16 then return false end
	return visibleExitProgressGui()
end

local function applyExitEstimate(entry, progress, repairers, now, opened)
	if opened then
		entry.estimatedProgress = 100
		entry.estimateLastAt = now
		entry.progressEstimated = false
		return 100
	end
	if entry.progressKnown then
		entry.estimatedProgress = progress
		entry.estimateLastAt = now
		entry.progressEstimated = false
		return progress
	end
	local last = entry.estimateLastAt or now
	local dt = math.clamp(now - last, 0, 1.0)
	entry.estimateLastAt = now
	entry.estimatedProgress = math.max(entry.estimatedProgress or 0, progress or 0)
	local activeWorkers = math.max(0, tonumber(repairers) or 0)
	if activeWorkers <= 0 and localOpeningExit(entry) then activeWorkers = 1 end
	if activeWorkers > 0 then
		local rate = 100 / CONFIG.exitFallbackOpenSeconds
		entry.estimatedProgress = math.clamp(
			entry.estimatedProgress + dt * rate * workerMultiplier(activeWorkers),
			0,
			99
		)
	end
	entry.progressEstimated = true
	return entry.estimatedProgress
end

local function updateExits(now)
	local root = localRoot()
	local killerRoot = playerRoot(state.killer)
	local rows = {}

	for model, entry in pairs(runtime.exits) do
		if model.Parent and not exitAnchorValid(entry.part) then
			entry.part = exitPart(model)
			if entry.billboard then entry.billboard:Destroy(); entry.billboard = nil end
		end
		if not model.Parent or not entry.part or not entry.part.Parent then
			if entry.highlight then entry.highlight:Destroy() end
			if entry.billboard then entry.billboard:Destroy() end
			runtime.exits[model] = nil
		elseif state.exitMode then
			ensureExitVisual(entry)
			local rawProgress = exitProgressOf(entry)
			local repairers = repairersOf(entry)
			local opened = exitOpenedOf(model, rawProgress, entry.progressKnown)
			local progress = applyExitEstimate(entry, rawProgress, repairers, now, opened)
			updateRepairRate(entry, progress, now, repairers)
			local distance = root and horizontalDistance(root.Position, entry.part.Position) or math.huge
			local killerDistance = killerRoot and horizontalDistance(killerRoot.Position, entry.part.Position) or math.huge
			local killerEta, killerMovingToward, killerSpeed = killerApproach(killerRoot, entry.part.Position)
			local killerPotentialEta = killerRoot and killerDistance / math.max(14, killerSpeed) or math.huge
			local row = {
				entry = entry,
				progress = progress,
				repairers = repairers,
				distance = distance,
				killerDistance = killerDistance,
				killerEta = killerEta,
				killerMovingToward = killerMovingToward,
				killerSpeed = killerSpeed,
				killerPotentialEta = killerPotentialEta,
				opened = opened,
			}
			row.score = exitScore(row)
			table.insert(rows, row)
		else
			if entry.highlight then applyHighlight(entry, COLORS.exit, 0.98, 0.42, false) end
			if entry.billboard then setBillboard(entry, false, nil, nil) end
		end
	end

	if not state.exitMode then
		state.bestExit = nil
		_G.VDExitRecommendation = nil
		_G.VDExitRecommendationInfo = nil
		return
	end

	table.sort(rows, function(a, b) return a.score > b.score end)
	local candidate = rows[1]
	local current = nil
	for _, row in ipairs(rows) do
		if row.entry.model == state.bestExit then current = row break end
	end
	if not current then
		state.bestExit = candidate and candidate.entry.model or nil
		state.bestExitSince = now
	elseif candidate and candidate.entry.model ~= current.entry.model then
		if now - state.bestExitSince >= CONFIG.exitTargetHold
			and candidate.score >= current.score + CONFIG.exitSwitchMargin then
			state.bestExit = candidate.entry.model
			state.bestExitSince = now
		end
	end

	local chosen = nil
	for _, row in ipairs(rows) do
		local best = row.entry.model == state.bestExit
		if best then chosen = row end
		local danger = row.killerDistance <= CONFIG.killerNearDistance
			or (row.killerMovingToward and row.killerEta < 8)
		local color = danger and COLORS.danger or (best and COLORS.best or COLORS.exit)
		applyHighlight(
			row.entry,
			color,
			best and 0.93 or 0.98,
			best and 0.10 or 0.36,
			runtime.visible
		)
		local close = row.distance <= CONFIG.exitLabelDistance
		if close then
			local text
			if row.opened then
				text = "ВЫХОД ОТКРЫТ"
			else
				text = string.format(
					row.entry.progressEstimated and "ВЫХОД • ~%d%%" or "ВЫХОД • %d%%",
					math.floor(row.progress + 0.5)
				)
				if row.openEta > 0 and row.openEta < 240 then
					text = text .. string.format(" • ~%dс", math.max(1, math.floor(row.openEta + 0.5)))
				end
				local shownKillerEta = row.killerMovingToward and row.killerEta or row.killerPotentialEta
				if shownKillerEta and shownKillerEta < 90 then
					if row.killerMovingToward and row.openEta + 1.2 < shownKillerEta then
						text = text .. " • УСПЕВАЕШЬ"
					else
						text = text .. string.format(
							row.killerMovingToward and " • МАН ~%dс" or " • МАН ≤%dс",
							math.max(1, math.floor(shownKillerEta + 0.5))
						)
					end
				end
			end
			setBillboard(row.entry, runtime.visible, text, color)
		else
			setBillboard(row.entry, false, nil, nil)
		end
	end
	_G.VDExitRecommendation = state.bestExit
	_G.VDExitRecommendationInfo = chosen and {
		progress = chosen.progress,
		openEta = chosen.openEta,
		totalEta = chosen.totalEta,
		killerEta = chosen.killerEta,
		killerMovingToward = chosen.killerMovingToward,
	} or nil
end

local function updateRoutes()
	local root = localRoot()
	for model, entry in pairs(runtime.routes) do
		if not model.Parent then
			if entry.highlight then entry.highlight:Destroy() end
			runtime.routes[model] = nil
		else
			if not entry.part or not entry.part:IsA("BasePart") or not entry.part.Parent then
				entry.part = entry.kind == "Pallet" and palletAnchor(model) or windowAnchor(model)
			end
			if not entry.part or not entry.part:IsA("BasePart") or not entry.part.Parent then
				disableRouteVisual(entry)
				entry.visualEnabled = false
			else
				local desiredHost = routeHighlightHost(model, entry.kind, entry.part)
				if not entry.highlight or not entry.highlight.Parent or entry.highlightHost ~= desiredHost then
					if entry.highlight then entry.highlight:Destroy() end
					entry.highlight = ensureRouteVisual(model, entry.kind, entry.part)
					entry.highlightHost = desiredHost
					entry.visualColor = nil
					entry.visualFill = nil
					entry.visualOutline = nil
					entry.visualEnabled = nil
				end
				local distance = root and horizontalDistance(root.Position, entry.part.Position) or math.huge
				-- Highlight objects are already AlwaysOnTop.  A line-of-sight check here
				-- made valid pallets/windows disappear behind walls, which is exactly
				-- when the route aura is most useful. Manual blacklist entries are still
				-- rejected when the route is indexed in addRoute().
				local visible = runtime.visible and distance <= CONFIG.routeDistance
				if entry.kind == "Pallet" and palletBroken(model) then visible = false end
				local color = entry.kind == "Pallet" and COLORS.pallet
					or (entry.kind == "Window" and COLORS.window or COLORS.custom)
				-- Route auras must be readable at map distance. 0.91 left only a
				-- faint five-percent fill on the pallet meshes, which looked like a
				-- partial highlight even though the model was correctly adorned.
				local fill = entry.kind == "Pallet" and 0.68 or 0.78
				local outline = entry.kind == "Pallet" and 0.04 or 0.06
				applyRouteVisual(entry, color, fill, outline, visible)
			end
		end
	end

end

remember(Workspace.DescendantAdded:Connect(function(object)
	if not runtime.running then return end
	if object:IsA("Model") or object:IsA("BasePart") then
		local namedGeneratorAncestor = findAncestorModelWithName(object, "generator")
		if hasGeneratorSignal(object)
			or normalize(object.Name):find("generator", 1, true)
			or namedGeneratorAncestor then
			addGeneratorCandidate(namedGeneratorAncestor or object)
			-- Attributes/tags often replicate one frame after the model. A
			-- delayed bounded retry promotes that already-known ancestor without
			-- scheduling a full Workspace scan for every BasePart.
			if namedGeneratorAncestor then
				task.delay(0.35, function()
					if runtime.running and _G[KEY] == runtime
						and namedGeneratorAncestor.Parent then
						addGeneratorCandidate(namedGeneratorAncestor)
					end
				end)
			end
		end
		addExitCandidate(object)
		if object:IsA("Model") then addZombieCandidate(object) end
		addPalletCandidate(object)
		addWindowCandidate(object)
	elseif object:IsA("ProximityPrompt") then
		addExitCandidate(object)
		addWindowCandidate(object)
	end
end))

-- Tags can replicate after the instance itself. Listen for those late signals
-- so streamed generators/routes/exits do not wait for the long safety rescan.
for _, tag in ipairs({
	"Generator", "GeneratorPoint", "GeneratorPointInUse",
	"pallet", "Pallet", "PalletPoint", "window", "VaultPoint",
	"Exit", "gatespot", "EscapePart",
}) do
	remember(CollectionService:GetInstanceAddedSignal(tag):Connect(function(instance)
		if not runtime.running then return end
		-- Occupancy tags are state changes on an already indexed generator
		-- point, not structural map additions. Dirtying the whole workspace here
		-- caused one full scan per repair interaction.
		if tag ~= "GeneratorPointInUse" then state.scanDirty = true end
		addGeneratorCandidate(instance)
		if tag ~= "GeneratorPointInUse" then
			addExitCandidate(instance)
			addPalletCandidate(instance)
			addWindowCandidate(instance)
		end
	end))
	remember(CollectionService:GetInstanceRemovedSignal(tag):Connect(function()
		if runtime.running and tag ~= "GeneratorPointInUse" then state.scanDirty = true end
	end))
end

remember(Workspace.DescendantRemoving:Connect(function(object)
	if runtime.generators[object] or runtime.exits[object] or runtime.routes[object] then
		state.scanDirty = true
	end
end))

remember(Players.PlayerRemoving:Connect(function(player)
	local entry = runtime.playerAuras[player]
	if entry and entry.highlight then entry.highlight:Destroy() end
	runtime.playerAuras[player] = nil
end))

local function hideAllVisualsImmediate()
	for _, entry in pairs(runtime.playerAuras) do
		if entry.highlight then entry.highlight.Enabled = false end
		entry.visualEnabled = false
	end
	for _, entry in pairs(runtime.npcAuras) do
		if entry.highlight then entry.highlight.Enabled = false end
		entry.visualEnabled = false
	end
	for _, bucket in ipairs({runtime.generators, runtime.exits, runtime.routes}) do
		for _, entry in pairs(bucket) do
			if bucket == runtime.routes then
				disableRouteVisual(entry)
			elseif entry.highlight then
				entry.highlight.Enabled = false
			end
			if entry.billboard then entry.billboard.Enabled = false end
			entry.visualEnabled = false
			entry.billboardEnabled = false
		end
	end
end

local function aimedInstance()
	local mouse = localPlayer:GetMouse()
	local target = mouse and mouse.Target or nil
	if target and target:IsDescendantOf(Workspace) then return target end
	local camera = Workspace.CurrentCamera
	if not camera then return nil end
	local viewport = camera.ViewportSize
	local ray = camera:ViewportPointToRay(viewport.X * 0.5, viewport.Y * 0.5)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = localPlayer.Character and {localPlayer.Character} or {}
	params.IgnoreWater = true
	local result = Workspace:Raycast(ray.Origin, ray.Direction * 1000, params)
	return result and result.Instance or nil
end

local function inspectRouteRoot(hit)
	local current = hit
	for _ = 1, 12 do
		if not current or current == Workspace then break end
		local entry = runtime.routes[current]
		if entry then return current, entry.kind, entry.part end
		if current:IsA("Model") then
			if isRealPalletModel(current) then return current, "Pallet", palletAnchor(current) end
			if normalize(current.Name) == "window" and windowAnchor(current) then
				return current, "Window", windowAnchor(current)
			end
		end
		current = current.Parent
	end
	local path = string.lower(fullPath(hit))
	local guessed = path:find("pallet", 1, true) and "Pallet"
		or ((path:find("window", 1, true) or path:find("vault", 1, true)) and "Window")
		or "Custom"
	return hit, guessed, hit:IsA("BasePart") and hit or objectPart(hit)
end

local function printAimInspector(toggleMode)
	if state.windowProbeBusy then return end
	state.windowProbeBusy = true
	local hit = aimedInstance()
	if not hit then
		print("[VD ASSIST v10.0][PICK] nothing under crosshair/cursor")
		state.windowProbeBusy = false
		return
	end
	local root, kind, part = inspectRouteRoot(hit)
	local path = fullPath(root)
	state.lastPicked = {hit=hit, root=root, part=part, kind=kind, path=path}
	_G.VDAssistLastPick = state.lastPicked

	if toggleMode == "blacklist" then
		if routeConfig.blacklist[path] then
			routeConfig.blacklist[path] = nil
			print(string.format("[VD ASSIST v10.0][PICK_CONFIG] BLACKLIST REMOVE %s", path))
			addRoute(root, kind, part)
		else
			routeConfig.blacklist[path] = true
			routeConfig.whitelist[path] = nil
			removeRoute(root)
			print(string.format("[VD ASSIST v10.0][PICK_CONFIG] BLACKLIST ADD %s", path))
		end
	elseif toggleMode == "whitelist" then
		if routeConfig.whitelist[path] then
			routeConfig.whitelist[path] = nil
			print(string.format("[VD ASSIST v10.0][PICK_CONFIG] WHITELIST REMOVE %s", path))
			if kind == "Custom" then removeRoute(root) end
		else
			routeConfig.whitelist[path] = kind
			routeConfig.blacklist[path] = nil
			addRoute(root, kind, part)
			print(string.format("[VD ASSIST v10.0][PICK_CONFIG] WHITELIST ADD %s kind=%s", path, kind))
		end
	else
		print(string.format("[VD ASSIST v10.0][PICK] hit=%s class=%s", fullPath(hit), hit.ClassName))
		print(string.format("[VD ASSIST v10.0][PICK] root=%s kind=%s part=%s", path, kind, fullPath(part)))
		print(string.format("[VD ASSIST v10.0][PICK_CONFIG] blacklist[%q] = true", path))
		print(string.format("[VD ASSIST v10.0][PICK_CONFIG] whitelist[%q] = %q", path, kind))
		print("[VD ASSIST v10.0][PICK_KEYS] P inspect | Shift+P blacklist toggle | Ctrl+P whitelist toggle")
	end
	state.lastRouteUpdate = -math.huge
	state.windowProbeBusy = false
end

remember(UserInputService.InputBegan:Connect(function(input, processed)
	if processed then return end
	if input.KeyCode == CONFIG.windowProbeKey then
		local shift = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
		local control = UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) or UserInputService:IsKeyDown(Enum.KeyCode.RightControl)
		printAimInspector(shift and "blacklist" or (control and "whitelist" or nil))
		return
	end
	if input.KeyCode == CONFIG.toggleKey then
		local toggleAt = os.clock()
		-- During hot reload an older InputBegan connection may coexist for a
		-- fraction of a second. Share the edge timestamp so one physical M press
		-- cannot toggle two runtimes and end in the same OFF state.
		local sharedToggleAt = rawget(_G, "__VD_ASSIST_TOGGLE_STAMP")
		if type(sharedToggleAt) == "number" and toggleAt - sharedToggleAt < 0.20 then
			return
		end
		rawset(_G, "__VD_ASSIST_TOGGLE_STAMP", toggleAt)
		if toggleAt - (state.lastToggleAt or -math.huge) < 0.35 then
			return
		end
		state.lastToggleAt = toggleAt
		runtime.visible = not runtime.visible
		if runtime.visible then
			-- Do not scan/recreate anything here. Existing entries are refreshed
			-- incrementally on the next normal update tick.
			state.lastPlayerUpdate = -math.huge
			state.lastNpcUpdate = -math.huge
			state.lastUpdate = -math.huge
			state.lastRouteUpdate = -math.huge
		else
			hideAllVisualsImmediate()
		end
		print("[VD ASSIST v10.0][STATE] " .. (runtime.visible and "ON" or "OFF") .. " | M toggle, P inspect")
	end
end))

remember(RunService.Heartbeat:Connect(function()
	if not runtime.running then return end
	local locked=localControlLocked()
	if locked then
		if not state.controlPaused then
			state.controlPaused = true
			print("[VD ASSIST v10.0][PAUSE] downed/carried/hooked; heavy updates suspended, existing aura kept")
		end
		return
	elseif state.controlPaused then
		state.controlPaused=false; state.lastPlayerUpdate=-math.huge; state.lastNpcUpdate=-math.huge; state.lastUpdate=-math.huge; state.lastRouteUpdate=-math.huge
		print("[VD ASSIST v10.0][RESUME] local control restored")
	end
	local now = os.clock()
	-- Killer identity and generator data are gameplay data, not visuals. v9.9
	-- stopped all of them when M hid auras, which silently disabled Anti3 danger
	-- scoring and froze progress. Resolve the killer continuously; only aura work
	-- remains gated by the visual toggle.
	if runtime.visible and now - state.lastPlayerUpdate >= CONFIG.playerInterval then
		state.lastPlayerUpdate = now
		updatePlayerAuras()
	end
	if runtime.visible and now - state.lastNpcUpdate >= CONFIG.npcInterval then
		state.lastNpcUpdate = now
		updateNPCAuras()
	end
	local currentMap = Workspace:FindFirstChild("Map")
	if now >= (state.nextKnownGeneratorProbeAt or -math.huge) then
		state.nextKnownGeneratorProbeAt = now + CONFIG.knownGeneratorProbeInterval
		indexKnownGeneratorContainers()
	end
	if state.scanDirty or currentMap ~= state.lastMap
		or now - state.lastScan >= CONFIG.rescanInterval then
		scanWorkspace()
	end
	if now - state.lastUpdate >= CONFIG.updateInterval then
		state.lastUpdate = now
		state.killer = resolveKiller()
		updateGenerators(now)
		updateExits(now)
	end
	if runtime.visible and now - state.lastRouteUpdate >= CONFIG.routeInterval then
		state.lastRouteUpdate = now
		updateRoutes()
	end
end))

function runtime.Stop()
	if not runtime.running then return end
	runtime.running = false
	for _, connection in ipairs(runtime.connections) do
		if connection.Connected then connection:Disconnect() end
	end
	for _, entry in pairs(runtime.playerAuras) do
		if entry.highlight then entry.highlight:Destroy() end
	end
	for _, entry in pairs(runtime.npcAuras) do
		if entry.highlight then entry.highlight:Destroy() end
	end
	for _, entry in pairs(runtime.generators) do
		if entry.highlight then entry.highlight:Destroy() end
		if entry.billboard then entry.billboard:Destroy() end
	end
	for _, entry in pairs(runtime.exits) do
		if entry.highlight then entry.highlight:Destroy() end
		if entry.billboard then entry.billboard:Destroy() end
	end
	for _, entry in pairs(runtime.routes) do
		if entry.highlight then entry.highlight:Destroy() end
	end
	if _G[KEY] == runtime then _G[KEY] = nil end
	if rawget(_G, "__VD_ASSIST_SINGLETON") == runtime then
		_G.__VD_ASSIST_SINGLETON = nil
	end
	_G.VDGenRecommendation = nil
	_G.VDGenRecommendationInfo = nil
	_G.VDExitRecommendation = nil
	_G.VDExitRecommendationInfo = nil
	print("[VD ASSIST RESTORED] stopped")
end

_G.StopVDAssist = runtime.Stop
_G.StopFixedVDAssist = runtime.Stop

scanWorkspace()
indexKnownGeneratorContainers()
updatePlayerAuras()
updateNPCAuras()
local initialNow = os.clock()
updateGenerators(initialNow)
updateExits(initialNow)
updateRoutes()
print("[VD ASSIST v10.0] data API v2 active | generator/killer data continues with M=OFF | Anti3 owner supported | staggered repair-point scans | standalone Zombie Aura owns NPC visuals | M toggle, P inspect")
