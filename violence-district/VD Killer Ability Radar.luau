--!strict
-- VD Killer Ability Radar v1.1
-- Read-only telemetry. It never fires remotes and never writes movement, camera,
-- physics, or character properties. The published state is intended for Helper
-- and Assist to consume without another Workspace scan.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local localPlayer = Players.LocalPlayer
if not localPlayer then

	return
end

local KEY = "__VD_KILLER_ABILITY_RADAR_V1"
local previous = rawget(_G, KEY)
if type(previous) == "table" and type(previous.Stop) == "function" then
	pcall(previous.Stop)
end

local now = os.clock
local running = true
local generation = 0
local connections = {}
local remoteBindings = setmetatable({}, { __mode = "k" })
local bindings = setmetatable({}, { __mode = "k" })
local entries = setmetatable({}, { __mode = "k" })
local lastPublish = -math.huge
local revision = 0
local UPDATE_INTERVAL = 0.10
local SIGNAL_DISTANCE = 250

local EXACT_ANIMATIONS = {
	["139366495070441"] = "Stalker",
	["130455657709711"] = "Killer",
	["127938399465832"] = "Abysswalker",
	["72596557610728"] = "Slasher",
	["76630007392356"] = "Masked",
}

local CLASS_NAMES = {
	abysswalker = "Abysswalker",
	veil = "Veil",
	masked = "Masked",
	hidden = "Hidden",
	slasher = "Slasher",
	stalker = "Stalker",
	killer = "Killer",
	cure = "Cure",
}

local ATTRIBUTE_NAMES = {
	"Immobile", "IsStunned", "action", "IsChasing", "Pursuit",
	"Speed", "speed", "speedboost", "Aiming", "isAttacking",
	"isBreaking", "isLunging", "isVaulting", "IsCarried", "IsHooked",
}

local runtime = {
	Version = "1.1-IDENTITY-QUIET",
	Debug = false,
	Running = true,
	Revision = 0,
	Primary = nil,
	Killers = {},
	RecentEvents = {},
	Stop = nil,
}
_G[KEY] = runtime
_G.VDKillerAbilityState = runtime

local function remember(first, second)
	-- Accept both remember(connection, list) and remember(list, connection) so
	-- character-scoped cleanup cannot accidentally register the list itself.
	local list, connection
	if type(first) == "table" then
		list, connection = first, second
	else
		connection, list = first, second
	end
	if connection then
		table.insert(list or connections, connection)
	end
	return connection
end

local function disconnectAll(list)
	for i = #list, 1, -1 do
		local connection = list[i]
		if connection then
			pcall(function()
				connection:Disconnect()
			end)
		end
		list[i] = nil
	end
end

local function normaliseId(value)
	if value == nil then
		return nil
	end
	local text = tostring(value)
	local id = string.match(text, "%d+")
	return id
end

local function classFromText(text)
	local token = string.lower(tostring(text or "")):gsub("[^%w]", "")
	return CLASS_NAMES[token]
end

local function modelClass(model)
	if not model then
		return "Unknown"
	end
	local player = Players:GetPlayerFromCharacter(model)
	for _, source in ipairs(player and { model, player } or { model }) do
		for _, attribute in ipairs({ "KillerClass", "KillerType", "SelectedKiller", "KillerName", "killer" }) do
			local fromAttribute = classFromText(source:GetAttribute(attribute))
			if fromAttribute then return fromAttribute end
		end
	end
	-- Player names are not role or class evidence.
	local fromName = not player and classFromText(model.Name)
	return fromName or "Unknown"
end

local function isFriendly(model)
	local player = Players:GetPlayerFromCharacter(model)
	if not player or not localPlayer then
		return false
	end
	if player == localPlayer then
		return true
	end
	if localPlayer.Team and player.Team and localPlayer.Team == player.Team then
		return true
	end
	return false
end

local function isConfirmedKiller(model)
	if not model or not model:IsA("Model")
		or not model:IsDescendantOf(Workspace) or isFriendly(model) then return false end
	local player = Players:GetPlayerFromCharacter(model)
	local team = player and player.Team
	local teamName = team and string.lower(team.Name) or ""
	if teamName == "killer" or teamName == "killers" then return true end
	-- SelectedKiller is a stored loadout even on survivors/spectators. Require
	-- live role evidence before reading it for class display.
	if teamName == "survivor" or teamName == "survivors" or teamName == "spectator"
		or teamName == "spectators" then return false end
	if CollectionService:HasTag(model, "Killer") then return true end
	for _, source in ipairs(player and { model, player } or { model }) do
		if source:GetAttribute("IsKiller") == true or source:GetAttribute("Killer") == true then return true end
		local role = string.lower(tostring(source:GetAttribute("Role") or ""))
		if role == "killer" then return true end
	end
	return false
end

local function rootPart(model)
	if not model or not model.Parent then
		return nil
	end
	return model:FindFirstChild("HumanoidRootPart")
		or model.PrimaryPart
		or model:FindFirstChild("Torso")
		or model:FindFirstChild("UpperTorso")
end

local function localRoot()
	local character = localPlayer.Character
	return character and rootPart(character)
end

local function distanceTo(model)
	local a = localRoot()
	local b = rootPart(model)
	if not a or not b then
		return math.huge
	end
	return (a.Position - b.Position).Magnitude
end

local function inferModel(...)
	local candidates = table.pack(...)
	local explicitModel = false
	for i = 1, math.min(candidates.n, 8) do
		local value = candidates[i]
		if typeof(value) == "Instance" then
			local model = value:IsA("Player") and value.Character
				or (value:IsA("Model") and value or value:FindFirstAncestorOfClass("Model"))
			if model then
				explicitModel = true
				if isConfirmedKiller(model) then return model end
			end
		end
	end
	if explicitModel then return nil end
	local only = nil
	for model in pairs(entries) do
		if isConfirmedKiller(model) and distanceTo(model) <= SIGNAL_DISTANCE then
			if only then return nil end -- anonymous events cannot choose between owners
			only = model
		end
	end
	return only
end

local function attributeSnapshot(model)
	local result = {}
	for _, name in ipairs(ATTRIBUTE_NAMES) do
		local value = model:GetAttribute(name)
		if value ~= nil then
			result[name] = value
		end
	end
	return result
end

local function classifyAnimation(track)
	if not track then
		return nil, nil
	end
	local animation = track.Animation
	local id = animation and normaliseId(animation.AnimationId)
	local exactClass = id and EXACT_ANIMATIONS[id]
	local name = string.lower(tostring(track.Name or ""))
	local kind = exactClass and "WeaponAttack" or nil
	if track.Looped or (not exactClass and track.Priority
		and track.Priority.Value < Enum.AnimationPriority.Action.Value) then return nil, id, exactClass end
	if string.find(name, "lunge", 1, true) or string.find(name, "dash", 1, true) then
		kind = "Lunge"
	elseif string.find(name, "attack", 1, true) or string.find(name, "hit", 1, true) or string.find(name, "slash", 1, true) then
		kind = "BasicAttack"
	elseif string.find(name, "power", 1, true) or string.find(name, "ability", 1, true) then
		kind = "Power"
	elseif string.find(name, "vault", 1, true) then
		kind = "Vault"
	end
	return kind, id, exactClass
end

local function signature(entry)
	return table.concat({
		tostring(entry.phase), tostring(entry.ability), tostring(entry.attrs.IsStunned),
		tostring(entry.attrs.Immobile), tostring(entry.attrs.action),
	}, "|")
end

local function logTransition(entry, reason)
	local nextSignature = signature(entry)
	if entry.lastSignature == nextSignature then
		return
	end
	entry.lastSignature = nextSignature
	entry.lastReason = reason
	if not runtime.Debug or entry.distance > SIGNAL_DISTANCE then return end
	local stamp = now()
	if stamp - (entry.lastLogAt or -math.huge) < 2.0 then return end
	entry.lastLogAt = stamp
	print(string.format(
		"[VD Killer Ability Radar] %s %s phase=%s ability=%s dist=%.1f source=%s",
		tostring(entry.class), tostring(entry.model.Name), tostring(entry.phase),
		tostring(entry.ability), tonumber(entry.distance) or -1, tostring(reason)
	))
end

local function publish(force)
	local stamp = now()
	if not force and stamp - lastPublish < 0.10 then
		return
	end
	lastPublish = stamp
	revision += 1
	runtime.Revision = revision
	local rows = {}
	local primary, bestDistance = nil, math.huge
	for model, entry in pairs(entries) do
		if isConfirmedKiller(model) then
			entry.distance = distanceTo(model)
			entry.attrs = attributeSnapshot(model)
			local row = {
				Model = model,
				Name = model.Name,
				Class = entry.class,
				Distance = entry.distance,
				Phase = entry.phase,
				Ability = entry.ability,
				AnimationId = entry.animationId,
				Source = entry.source,
				LastSignalAt = entry.lastSignalAt,
				Attributes = entry.attrs,
			}
			table.insert(rows, row)
			if entry.distance < bestDistance then
				primary, bestDistance = row, entry.distance
			end
		end
	end
	runtime.Killers = rows
	runtime.Primary = primary
	runtime.RecentEvents = runtime.RecentEvents
end

local function updateEntry(entry, ability, source, modelHint, reason)
	if not running or not entry then
		return
	end
	if modelHint and modelHint ~= entry.model then
		local hinted = entries[modelHint]
		if hinted then
			entry = hinted
		end
	end
	if not ability or not isConfirmedKiller(entry.model)
		or distanceTo(entry.model) > SIGNAL_DISTANCE then return end
	entry.ability = ability or entry.ability or "Unknown"
	entry.source = source or entry.source or "unknown"
	entry.lastSignalAt = now()
	entry.activeUntil = entry.lastSignalAt + 1.75
	-- refreshPhase owns precedence; an animation must not temporarily overwrite
	-- stunned/immobile/chase on every event and produce two opposing log lines.
	table.insert(runtime.RecentEvents, 1, {
		At = entry.lastSignalAt,
		Model = entry.model,
		Class = entry.class,
		Ability = entry.ability,
		Source = entry.source,
	})
	while #runtime.RecentEvents > 32 do
		table.remove(runtime.RecentEvents)
	end
	publish(false)
end

local function onAnimation(entry, track)
	local kind, id, exactClass = classifyAnimation(track)
	-- These IDs come from the native killer weapon animation assets.  They are
	-- stronger evidence than a replicated model name, which can be a skin or a
	-- stale nickname, so always let an exact killer track correct the class.
	if exactClass then
		entry.class = exactClass
	end
	if not kind then return end
	entry.animationId = id
	updateEntry(entry, kind, "AnimationPlayed", nil, "animation")
end

local function bindAnimator(entry, animator, token)
	if not animator or not animator:IsA("Animator") then
		return
	end
	if entry.animators[animator] then return end
	entry.animators[animator] = true
	remember(entry.connections, animator.AnimationPlayed:Connect(function(track)
		if running and entry.generation == token and entry.model.Parent then
			onAnimation(entry, track)
		end
	end))
end

local function refreshPhase(entry)
	if not entry.model.Parent then
		return
	end
	entry.distance = distanceTo(entry.model)
	entry.attrs = attributeSnapshot(entry.model)
	local resolvedClass = modelClass(entry.model)
	entry.class = resolvedClass ~= "Unknown" and resolvedClass or entry.class
	local current = now()
	if entry.attrs.IsStunned == true then
		entry.phase = "stunned"
	elseif entry.attrs.Immobile == true then
		entry.phase = "immobile"
	elseif entry.attrs.IsChasing == true or entry.attrs.Pursuit == true then
		entry.phase = "chase"
	elseif current < (entry.activeUntil or 0) then
		entry.phase = "ability"
	elseif entry.distance <= 18 then
		entry.phase = "near"
	elseif entry.distance <= 42 then
		entry.phase = "approach"
	else
		entry.phase = "distant"
	end
	logTransition(entry, "attribute")
end

local function bindModel(model)
	if not running or not isConfirmedKiller(model) then
		return
	end
	if entries[model] then
		return
	end
	generation += 1
	local token = generation
	local entry = {
		model = model,
		class = modelClass(model),
		distance = distanceTo(model),
		phase = "distant",
		ability = "None",
		source = "scan",
		animationId = nil,
		lastSignalAt = 0,
		activeUntil = 0,
		attrs = attributeSnapshot(model),
		generation = token,
		connections = {},
		animators = setmetatable({}, { __mode = "k" }),
		lastSignature = nil,
		lastReason = nil,
	}
	entries[model] = entry
	bindings[model] = entry

	local humanoid = model:FindFirstChildOfClass("Humanoid")
	local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
	bindAnimator(entry, animator, token)
	remember(entry.connections, model.DescendantAdded:Connect(function(child)
		if not running or entry.generation ~= token or not model.Parent then
			return
		end
		if child:IsA("Animator") then
			bindAnimator(entry, child, token)
		end
	end))
	for _, name in ipairs(ATTRIBUTE_NAMES) do
		remember(entry.connections, model:GetAttributeChangedSignal(name):Connect(function()
			if running and entry.generation == token then
				entry.attrs = attributeSnapshot(model)
				refreshPhase(entry)
				publish(true)
			end
		end))
	end
	remember(entry.connections, model.AncestryChanged:Connect(function(_, parent)
		if parent then
			return
		end
		if entries[model] == entry then
			entries[model] = nil
		end
		disconnectAll(entry.connections)
		publish(true)
	end))
	refreshPhase(entry)
	publish(true)
end

local function scanKillerModels()
	if not running then
		return
	end
	local seen = setmetatable({}, { __mode = "k" })
	for _, tagged in ipairs(CollectionService:GetTagged("Killer")) do
		if tagged:IsA("Model") then
			seen[tagged] = true
			bindModel(tagged)
		end
	end
	-- Player characters are a bounded fallback when the server omits the Killer
	-- tag or applies it after the character has already spawned.
	for _, player in ipairs(Players:GetPlayers()) do
		local character = player.Character
		if character and isConfirmedKiller(character) then
			seen[character] = true
			bindModel(character)
		end
	end
	-- Fallback for rounds where the server has not replicated the Killer tag yet.
	for _, child in ipairs(Workspace:GetChildren()) do
		if isConfirmedKiller(child) then
			seen[child] = true
			bindModel(child)
		end
	end
	for model, entry in pairs(entries) do
		if not model.Parent then
			entries[model] = nil
			disconnectAll(entry.connections)
		elseif not seen[model] or not isConfirmedKiller(model) then
			entries[model] = nil
			disconnectAll(entry.connections)
		end
	end
	publish(true)
end

local function connectRemote(path, ability, classHint)
	local object = ReplicatedStorage
	for _, name in ipairs(path) do
		object = object and object:FindFirstChild(name)
	end
	if not object or not object:IsA("RemoteEvent") then
		return
	end
	if remoteBindings[object] then
		return
	end
	local connection = object.OnClientEvent:Connect(function(a1, a2, a3, a4, a5, a6)
		if not running then
			return
		end
		local model = inferModel(a1, a2, a3, a4, a5, a6)
		if model and not entries[model] then
			bindModel(model)
		end
		local entry = model and entries[model]
		if entry and classHint and entry.class == "Unknown" then
			entry.class = classHint
		end
		if entry then
			updateEntry(entry, ability, table.concat(path, "/"), model, "remote")
		end
	end)
	remoteBindings[object] = true
	remember(connection)
end

local function connectRemotes()
	local specs = {
		{ { "Remotes", "AttackEvent" }, "Attack", nil },
		{ { "Remotes", "Attacks", "BasicAttack" }, "BasicAttack", nil },
		{ { "Remotes", "Attacks", "Lunge" }, "Lunge", nil },
		{ { "Remotes", "Attacks", "LungeDetect" }, "LungeDetect", nil },
		{ { "Remotes", "Attacks", "AfterAttack" }, "AfterAttack", nil },
		{ { "Remotes", "Attacks", "hit" }, "Hit", nil },
		{ { "Remotes", "Attacks", "TrailEvent" }, "Trail", nil },
		{ { "Remotes", "Killers", "Abysswalker", "visualize" }, "AbyssWave", "Abysswalker" },
		{ { "Remotes", "Killers", "Abysswalker", "corrupt" }, "AbyssCorrupt", "Abysswalker" },
		{ { "Remotes", "Killers", "Veil", "visualize" }, "VeilSpear", "Veil" },
		{ { "Remotes", "Killers", "Veil", "Spearthrow" }, "VeilSpearThrow", "Veil" },
		{ { "Remotes", "Killers", "Veil", "vfx" }, "VeilVFX", "Veil" },
		{ { "Remotes", "Killers", "Veil", "Echo", "EchoVoid_Trigger" }, "VeilEcho", "Veil" },
		{ { "Remotes", "Killers", "Masked", "Activatepower" }, "MaskedPower", "Masked" },
		{ { "Remotes", "Killers", "Masked", "Deactivatepower" }, "MaskedPowerEnd", "Masked" },
		{ { "Remotes", "Killers", "Masked", "alexattack" }, "MaskedDash", "Masked" },
		{ { "Remotes", "Killers", "Masked", "StopDash" }, "MaskedDashEnd", "Masked" },
		{ { "Remotes", "Killers", "Hidden", "M2" }, "HiddenM2", "Hidden" },
		{ { "Remotes", "Killers", "Hidden", "Leap" }, "HiddenLeap", "Hidden" },
		{ { "Remotes", "Killers", "Hidden", "m2HitVM" }, "HiddenM2Hit", "Hidden" },
		{ { "Remotes", "Killers", "Cure", "PrepareFlask" }, "CurePrepareFlask", "Cure" },
		{ { "Remotes", "Killers", "Cure", "VisualizeFlask" }, "CureFlask", "Cure" },
		{ { "Remotes", "Killers", "Cure", "ThrowFlask" }, "CureThrowFlask", "Cure" },
		{ { "Remotes", "Killers", "Cure", "CancelFlask" }, "CureCancelFlask", "Cure" },
		{ { "Remotes", "Killers", "SlowAttack" }, "SlowAttack", nil },
		{ { "Remotes", "Killers", "Damageviz" }, "Damage", nil },
	}
	for _, spec in ipairs(specs) do
		connectRemote(spec[1], spec[2], spec[3])
	end
end

remember(connections, CollectionService:GetInstanceAddedSignal("Killer"):Connect(function(instance)
	if instance:IsA("Model") then
		bindModel(instance)
	end
end))
remember(connections, localPlayer.CharacterAdded:Connect(function()
	task.defer(publish, true)
end))
connectRemotes()

local scanAccumulator = 0
local updateAccumulator = 0
remember(connections, RunService.Heartbeat:Connect(function(delta)
	if not running then
		return
	end
	scanAccumulator += delta
	updateAccumulator += delta
	if scanAccumulator >= 1.0 then
		scanAccumulator = 0
		scanKillerModels()
		-- Remotes may be replicated after the first frame.  This is a small,
		-- idempotent path lookup; remoteBindings prevents duplicate callbacks.
		connectRemotes()
	end
	if updateAccumulator < UPDATE_INTERVAL then return end
	updateAccumulator = 0
	for _, entry in pairs(entries) do
		if entry.model.Parent then
			refreshPhase(entry)
		end
	end
	publish(false)
end))

local function stop()
	if not running then
		return
	end
	running = false
	runtime.Running = false
	disconnectAll(connections)
	for model, entry in pairs(entries) do
		disconnectAll(entry.connections)
		entries[model] = nil
	end
	runtime.Killers = {}
	runtime.Primary = nil
	runtime.RecentEvents = {}
	if rawget(_G, KEY) == runtime then
		_G[KEY] = nil
	end
	if rawget(_G, "VDKillerAbilityState") == runtime then
		_G.VDKillerAbilityState = nil
	end
end
runtime.Stop = stop

scanKillerModels()
print("[VD Killer Ability Radar v1.1][READY] confirmed killers only | update=10Hz | transition logs OFF")
