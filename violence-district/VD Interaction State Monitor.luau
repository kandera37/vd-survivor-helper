--!strict
--==============================================================
-- VD INTERACTION STATE MONITOR v1.1
--
-- Read-only local interaction telemetry for VD Survivor Helper modules.
-- It observes native attributes, CollectionService tags, GUI visibility,
-- and event-indexed map points. It never writes movement, character state,
-- attributes, remotes, or camera properties.
--
-- The public snapshot is _G.VDInteractionState.
-- Follows the current LocalPlayer character with generation-safe rebinding.
--==============================================================

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local Workspace = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer
if not LocalPlayer then

	return
end

local RUNTIME_KEY = "__VD_INTERACTION_STATE_MONITOR_V1"
local STOP_NAME = "StopVDInteractionStateMonitor"
local UPDATE_INTERVAL = 0.25 -- at most four snapshots per second
local GUI_SCAN_NODE_LIMIT = 600

local oldRuntime = rawget(_G, RUNTIME_KEY)
if type(oldRuntime) == "table" and typeof(oldRuntime.Stop) == "function" then
	pcall(oldRuntime.Stop)
end

local INTERACTION_ATTRIBUTES = {
	"isRepairing",
	"isHealing",
	"isVaulting",
	"isSliding",
	"isDroppingPallet",
	"isExiting",
	"isUnhooking",
}

local CHARACTER_ATTRIBUTES = {
	"IsHooked",
	"IsCarried",
	"IsStunned",
	"IsDead",
	"MovementLocked",
	"Flowstate",
	"Aiming",
}

local POINT_TAGS = {
	-- Canonical interaction tags used by the native modules.
	"GeneratorPoint",
	"PalletPoint",
	"VaultPoint",
	"ExitPoint",
	"HookPoint",
	-- Live map aliases observed in place.rbxl.  Keep them event-indexed so
	-- late-loaded promptless geometry is visible without a descendant scan.
	"Generator",
	"GeneratorPointInUse",
	"pallet",
	"window",
	"vaultbox",
	"Exit",
	"gatespot",
	"EscapePart",
}

local runtime = {
	running = true,
	Debug = false,
	connections = {} :: {RBXScriptConnection},
	characterConnections = {} :: {RBXScriptConnection},
	sourceConnections = {} :: {RBXScriptConnection},
	guiConnections = {} :: {[Instance]: {RBXScriptConnection}},
	pointSets = {} :: {[string]: {[Instance]: boolean}},
	pointConnections = {} :: {RBXScriptConnection},
	character = nil :: Model?,
	root = nil :: BasePart?,
	checkInterractable = nil :: Instance?,
	playerGui = nil :: PlayerGui?,
	bindingGeneration = 0,
	sourceGeneration = 0,
	lastUpdateAt = -math.huge,
	dirty = true,
	lastSignature = nil :: string?,
	skillCheckCandidates = {} :: {[Instance]: boolean},
	skillCheckScanDone = false,
	snapshot = nil :: {[string]: any}?,
	Stop = nil :: ((string?) -> ())?,
}

for _, tag in ipairs(POINT_TAGS) do
	runtime.pointSets[tag] = {}
end

_G[RUNTIME_KEY] = runtime

local function disconnectList(list)
	for _, connection in ipairs(list) do
		if connection and connection.Connected then
			connection:Disconnect()
		end
	end
	table.clear(list)
end

local function remember(connection)
	table.insert(runtime.connections, connection)
	return connection
end

local function rememberCharacter(connection)
	table.insert(runtime.characterConnections, connection)
	return connection
end

local function safeName(instance)
	if not instance then
		return "nil"
	end
	local ok, value = pcall(function()
		return instance:GetFullName()
	end)
	return ok and value or tostring(instance)
end

local function normalized(value)
	return string.lower(tostring(value or "")):gsub("[^%w]", "")
end

local function boolAttribute(instance, name)
	return instance ~= nil and instance:GetAttribute(name) == true
end

local function valueAttribute(instance, name)
	if not instance then
		return nil
	end
	return instance:GetAttribute(name)
end

-- Keep a shallow, read-only copy of attributes on the few live runtime
-- sources we already own.  This exposes dynamic native flags without a
-- workspace scan or any writes back to the instances.
local function sourceAttributes(instance)
	if not instance or not instance.Parent then
		return nil
	end
	local ok, values = pcall(function()
		return instance:GetAttributes()
	end)
	if not ok or type(values) ~= "table" then
		return {
			instance = instance,
			path = safeName(instance),
			values = {},
		}
	end
	return {
		instance = instance,
		path = safeName(instance),
		values = values,
	}
end

local function markDirty()
	if runtime.running then
		runtime.dirty = true
	end
end

local function pointPosition(instance)
	if not instance or not instance.Parent then
		return nil
	end
	if instance:IsA("BasePart") then
		return instance.Position
	end
	if instance:IsA("Attachment") then
		return instance.WorldPosition
	end
	if instance:IsA("Model") then
		local primary = instance.PrimaryPart
		if primary then
			return primary.Position
		end
		local ok, pivot = pcall(function()
			return instance:GetPivot()
		end)
		if ok and pivot then
			return pivot.Position
		end
	end
	return nil
end

local function addPoint(tag, instance)
	if not runtime.running or not runtime.pointSets[tag] then
		return
	end
	if pointPosition(instance) then
		runtime.pointSets[tag][instance] = true
		markDirty()
	end
end

local function removePoint(tag, instance)
	local set = runtime.pointSets[tag]
	if set then
		set[instance] = nil
		markDirty()
	end
end

local function nearestPoint(tag, origin)
	local set = runtime.pointSets[tag]
	if not set or not origin then
		return nil, math.huge
	end
	local nearest = nil
	local nearestDistance = math.huge
	for instance in pairs(set) do
		local position = pointPosition(instance)
		if not position then
			set[instance] = nil
		else
			local distance = (position - origin).Magnitude
			if distance < nearestDistance then
				nearest = instance
				nearestDistance = distance
			end
		end
	end
	return nearest, nearestDistance
end

local function screenGuiAncestor(instance)
	local current = instance
	for _ = 1, 14 do
		if not current then
			return nil
		end
		if current:IsA("ScreenGui") then
			return current
		end
		current = current.Parent
	end
	return nil
end

local function isSkillCheckName(instance)
	local name = normalized(instance.Name)
	local root = screenGuiAncestor(instance)
	local rootName = root and normalized(root.Name) or ""
	if rootName:find("skillcheck", 1, true)
		or rootName:find("skillcheckprompt", 1, true) then
		return name == "check"
			or name == "line"
			or name == "goal"
			or name == "skillcheck"
			or instance == root
	end
	return name:find("skillcheck", 1, true) ~= nil
		or name == "skillcheckpromptgui"
end

local function guiChainVisible(instance)
	local current = instance
	local sawGuiObject = false
	for _ = 1, 18 do
		if not current then
			return false
		end
		if current:IsA("ScreenGui") then
			return current.Enabled and sawGuiObject
		end
		if current:IsA("GuiObject") then
			sawGuiObject = true
			if not current.Visible then
				return false
			end
			local size = current.AbsoluteSize
			if size.X <= 0 or size.Y <= 0 then
				return false
			end
		end
		current = current.Parent
	end
	return false
end

local function removeGuiCandidate(instance)
	runtime.skillCheckCandidates[instance] = nil
	local connections = runtime.guiConnections[instance]
	if connections then
		disconnectList(connections)
		runtime.guiConnections[instance] = nil
	end
end

local function registerGuiCandidate(instance)
	if not runtime.running or not instance or not instance.Parent then
		return
	end
	if not instance:IsA("GuiObject") and not instance:IsA("ScreenGui") then
		return
	end
	if not isSkillCheckName(instance) or runtime.skillCheckCandidates[instance] then
		return
	end
	runtime.skillCheckCandidates[instance] = true
	local connections = {}
	runtime.guiConnections[instance] = connections
	local function dirtyIfCurrent()
		if runtime.running and runtime.skillCheckCandidates[instance] then
			markDirty()
		end
	end
	if instance:IsA("GuiObject") then
		table.insert(connections, instance:GetPropertyChangedSignal("Visible"):Connect(dirtyIfCurrent))
		table.insert(connections, instance:GetPropertyChangedSignal("AbsoluteSize"):Connect(dirtyIfCurrent))
		table.insert(connections, instance:GetPropertyChangedSignal("AbsolutePosition"):Connect(dirtyIfCurrent))
	end
	if instance:IsA("ScreenGui") then
		table.insert(connections, instance:GetPropertyChangedSignal("Enabled"):Connect(dirtyIfCurrent))
	end
	table.insert(connections, instance.AncestryChanged:Connect(function(_, parent)
		if not parent then
			removeGuiCandidate(instance)
		else
			dirtyIfCurrent()
		end
	end))
end

local function scanGuiTree(root)
	if runtime.skillCheckScanDone or not root then
		return
	end
	runtime.skillCheckScanDone = true
	local queue = {root}
	local head = 1
	local processed = 0
	while head <= #queue and processed < GUI_SCAN_NODE_LIMIT do
		local parent = queue[head]
		head += 1
		local ok, children = pcall(function()
			return parent:GetChildren()
		end)
		if ok and type(children) == "table" then
			for _, child in ipairs(children) do
				processed += 1
				registerGuiCandidate(child)
				table.insert(queue, child)
				if processed >= GUI_SCAN_NODE_LIMIT then
					break
				end
			end
		end
	end
end

local function skillCheckVisible()
	local visible = false
	local source = nil
	for instance in pairs(runtime.skillCheckCandidates) do
		if not instance.Parent then
			removeGuiCandidate(instance)
		elseif guiChainVisible(instance) then
			visible = true
			source = instance
			break
		end
	end
	return visible, source
end

local function readLocalInteraction()
	local character = runtime.character
	local check = runtime.checkInterractable
	local root = runtime.root
	local values = {}
	for _, name in ipairs(INTERACTION_ATTRIBUTES) do
		values[name] = boolAttribute(check, name)
	end
	for _, name in ipairs(CHARACTER_ATTRIBUTES) do
		values[name] = valueAttribute(character, name)
	end
	values.doingAction = root ~= nil and CollectionService:HasTag(root, "doing action") or false
	return values
end

local function stateSignature(state)
	local parts = {}
	for _, name in ipairs(INTERACTION_ATTRIBUTES) do
		table.insert(parts, name .. "=" .. tostring(state[name] == true))
	end
	for _, name in ipairs(CHARACTER_ATTRIBUTES) do
		table.insert(parts, name .. "=" .. tostring(state[name]))
	end
	table.insert(parts, "doingAction=" .. tostring(state.doingAction == true))
	table.insert(parts, "skillCheck=" .. tostring(state.skillCheckVisible == true))
	table.insert(parts, "skillSource=" .. tostring(state.skillCheckSourcePath or ""))
	for _, tag in ipairs(POINT_TAGS) do
		local nearest = state.nearest[tag]
		table.insert(parts, tag .. "=" .. tostring(nearest and nearest.path or ""))
	end
	return table.concat(parts, "|")
end

local function publishState(force)
	if not runtime.running then
		return
	end
	local values = readLocalInteraction()
	local origin = runtime.root and runtime.root.Position or nil
	local nearest = {}
	for _, tag in ipairs(POINT_TAGS) do
		local instance, distance = nearestPoint(tag, origin)
		nearest[tag] = {
			instance = instance,
			path = instance and safeName(instance) or nil,
			distance = distance < math.huge and distance or nil,
			attributes = sourceAttributes(instance),
		}
	end
	local skillVisible, skillSource = skillCheckVisible()
	local snapshot = {
		running = true,
		generation = runtime.bindingGeneration,
		updatedAt = os.clock(),
		character = runtime.character,
		root = runtime.root,
		checkInterractable = runtime.checkInterractable,
		-- These are snapshots, never live tables returned by Roblox. Consumers
		-- can inspect native runtime flags such as Immobile, action, Pursuit,
		-- IsBeingHealed, Crouching, or Sprinting without mutating the sources.
		sources = {
			character = sourceAttributes(runtime.character),
			root = sourceAttributes(runtime.root),
			checkInterractable = sourceAttributes(runtime.checkInterractable),
		},
		isRepairing = values.isRepairing == true,
		isHealing = values.isHealing == true,
		isVaulting = values.isVaulting == true,
		isSliding = values.isSliding == true,
		isDroppingPallet = values.isDroppingPallet == true,
		isExiting = values.isExiting == true,
		isUnhooking = values.isUnhooking == true,
		IsHooked = values.IsHooked,
		IsCarried = values.IsCarried,
		IsStunned = values.IsStunned,
		IsDead = values.IsDead,
		MovementLocked = values.MovementLocked,
		Flowstate = values.Flowstate,
		Aiming = values.Aiming,
		doingAction = values.doingAction == true,
		skillCheckVisible = skillVisible,
		skillCheckSource = skillSource,
		skillCheckSourcePath = skillSource and safeName(skillSource) or nil,
		nearest = nearest,
	}
	local signature = stateSignature(snapshot)
	local changed = force or signature ~= runtime.lastSignature
	runtime.lastSignature = signature
	runtime.snapshot = snapshot
	runtime.dirty = false
	_G.VDInteractionState = snapshot
	if changed and runtime.Debug then
		print(string.format(
			"[VD INTERACTION][STATE] repair=%s heal=%s vault=%s pallet=%s exit=%s hook=%s carried=%s stunned=%s skill=%s action=%s",
			tostring(snapshot.isRepairing),
			tostring(snapshot.isHealing),
			tostring(snapshot.isVaulting),
			tostring(snapshot.isDroppingPallet),
			tostring(snapshot.isExiting),
			tostring(snapshot.IsHooked),
			tostring(snapshot.IsCarried),
			tostring(snapshot.IsStunned),
			tostring(snapshot.skillCheckVisible),
			tostring(snapshot.doingAction)
		))
	end
end

local function refreshSources(character, token)
	if not runtime.running or token ~= runtime.bindingGeneration or character ~= runtime.character then
		return
	end
	disconnectList(runtime.sourceConnections)
	runtime.sourceGeneration += 1
	local sourceToken = runtime.sourceGeneration
	runtime.root = character:FindFirstChild("HumanoidRootPart")
	runtime.checkInterractable = character:FindFirstChild("CheckInterractable", true)
	local function watch(instance, name)
		if not instance then
			return
		end
		local signal = instance:GetAttributeChangedSignal(name)
		table.insert(runtime.sourceConnections, signal:Connect(function()
			if runtime.running and token == runtime.bindingGeneration and sourceToken == runtime.sourceGeneration then
				markDirty()
			end
		end))
	end
	for _, name in ipairs(INTERACTION_ATTRIBUTES) do
		watch(runtime.checkInterractable, name)
	end
	for _, name in ipairs(CHARACTER_ATTRIBUTES) do
		watch(character, name)
	end
	markDirty()
end

local function bindCharacter(character)
	runtime.bindingGeneration += 1
	local token = runtime.bindingGeneration
	disconnectList(runtime.characterConnections)
	disconnectList(runtime.sourceConnections)
	runtime.character = character
	runtime.root = nil
	runtime.checkInterractable = nil
	runtime.lastSignature = nil
	if not character then
		markDirty()
		return
	end
	local function tryRefresh()
		if runtime.running and token == runtime.bindingGeneration then
			refreshSources(character, token)
		end
	end
	rememberCharacter(character.DescendantAdded:Connect(function(instance)
		if token ~= runtime.bindingGeneration then return end
		if instance.Name == "HumanoidRootPart" or instance.Name == "CheckInterractable" then
			task.defer(tryRefresh)
		end
	end))
	rememberCharacter(character.DescendantRemoving:Connect(function(instance)
		if token ~= runtime.bindingGeneration then return end
		if instance == runtime.root or instance == runtime.checkInterractable then
			task.defer(tryRefresh)
		end
	end))
	tryRefresh()
	task.spawn(function()
		for _ = 1, 20 do
			if not runtime.running or token ~= runtime.bindingGeneration then return end
			if runtime.root and runtime.checkInterractable then return end
			task.wait(0.05)
			tryRefresh()
		end
	end)
end

local function bindPlayerGui(playerGui)
	if runtime.playerGui == playerGui then
		return
	end
	runtime.playerGui = playerGui
	runtime.skillCheckScanDone = false
	if not playerGui then
		return
	end
	remember(playerGui.DescendantAdded:Connect(function(instance)
		registerGuiCandidate(instance)
		markDirty()
	end))
	remember(playerGui.DescendantRemoving:Connect(function(instance)
		removeGuiCandidate(instance)
		markDirty()
	end))
	-- The native place ships these two roots. Register them directly before the
	-- bounded generic scan so a large PlayerGui cannot hide an already-created
	-- skill-check behind the scan budget.
	for _, name in ipairs({"SkillCheckPromptGui", "SkillCheckPromptGui-con"}) do
		local known = playerGui:FindFirstChild(name, true)
		if known then
			registerGuiCandidate(known)
			for _, child in ipairs(known:GetChildren()) do
				registerGuiCandidate(child)
			end
		end
	end
	scanGuiTree(playerGui)
end

for _, tag in ipairs(POINT_TAGS) do
	for _, instance in ipairs(CollectionService:GetTagged(tag)) do
		addPoint(tag, instance)
	end
	remember(CollectionService:GetInstanceAddedSignal(tag):Connect(function(instance)
		addPoint(tag, instance)
	end))
	remember(CollectionService:GetInstanceRemovedSignal(tag):Connect(function(instance)
		removePoint(tag, instance)
	end))
end

remember(CollectionService:GetInstanceAddedSignal("doing action"):Connect(function(instance)
	if instance == runtime.root then markDirty() end
end))
remember(CollectionService:GetInstanceRemovedSignal("doing action"):Connect(function(instance)
	if instance == runtime.root then markDirty() end
end))

remember(LocalPlayer.CharacterAdded:Connect(function(character)
	bindCharacter(character)
end))
remember(LocalPlayer.CharacterRemoving:Connect(function(character)
	if character == runtime.character then
		bindCharacter(nil)
	end
end))
remember(LocalPlayer.ChildAdded:Connect(function(child)
	if child:IsA("PlayerGui") then
		bindPlayerGui(child)
	end
end))

bindCharacter(LocalPlayer.Character)
bindPlayerGui(LocalPlayer:FindFirstChildOfClass("PlayerGui"))

runtime.Stop = function(reason)
	if not runtime.running then
		return
	end
	runtime.running = false
	runtime.bindingGeneration += 1
	runtime.sourceGeneration += 1
	disconnectList(runtime.connections)
	disconnectList(runtime.characterConnections)
	disconnectList(runtime.sourceConnections)
	for instance, connections in pairs(runtime.guiConnections) do
		disconnectList(connections)
		runtime.guiConnections[instance] = nil
	end
	for _, set in pairs(runtime.pointSets) do
		table.clear(set)
	end
	if rawget(_G, RUNTIME_KEY) == runtime then
		rawset(_G, RUNTIME_KEY, nil)
	end
	if rawget(_G, STOP_NAME) == runtime.Stop then
		rawset(_G, STOP_NAME, nil)
	end
	if rawget(_G, "VDInteractionState") == runtime.snapshot then
		rawset(_G, "VDInteractionState", nil)
	end
	print("[VD INTERACTION][STOP] reason=" .. tostring(reason or "manual"))
end

_G[STOP_NAME] = runtime.Stop

remember(RunService.Heartbeat:Connect(function()
	if not runtime.running then
		return
	end
	local current = os.clock()
	if current - runtime.lastUpdateAt < UPDATE_INTERVAL then
		return
	end
	runtime.lastUpdateAt = current
	publishState(false)
end))

publishState(true)
