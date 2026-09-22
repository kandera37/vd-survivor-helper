--!strict
--==============================================================
-- VD ZOMBIE AURA v2.0 — EVENT INDEXED / VISUAL ONLY
--
-- F5  = toggle aura
-- F12 = stop and remove every aura
--
-- This script never writes movement, never scans Workspace per frame and
-- never competes with VD Survivor Helper. New NPCs are indexed from events.
--==============================================================

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local CollectionService = game:GetService("CollectionService")
local Workspace = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer
if not LocalPlayer then
	return
end

-- Stop the old movement-capable standalone once. Do not publish this legacy
-- callback again: old Helper builds called it and accidentally killed the aura.
local legacyStop = rawget(_G, "StopVDZombieDodge")
if type(legacyStop) == "function" then
	pcall(legacyStop)
end
if rawget(_G, "StopVDZombieDodge") == legacyStop then
	_G.StopVDZombieDodge = nil
end

for _, oldKey in ipairs({
	"__VD_ZOMBIE_AURA_DODGE_V1_5",
	"__VD_ZOMBIE_AURA_VISUAL_V2",
}) do
	local old = rawget(_G, oldKey)
	if type(old) == "table" and type(old.Stop) == "function" then
		pcall(old.Stop)
	end
end

local RUNTIME_KEY = "__VD_ZOMBIE_AURA_VISUAL_V2"
local AURA_NAME = "VDZombieAuraV20"

local CONFIG = {
	enabled = true,
	toggleKey = Enum.KeyCode.F5,
	stopKey = Enum.KeyCode.F12,
	fillColor = Color3.fromRGB(200, 70, 255),
	outlineColor = Color3.fromRGB(255, 225, 255),
	fillTransparency = 0.38,
	outlineTransparency = 0.0,
	minimumUprightY = 0.30,
}

type Entry = {
	model: Model,
	humanoid: Humanoid,
	root: BasePart,
	highlight: Highlight,
	connections: {RBXScriptConnection},
	visible: boolean,
}

local runtime = {
	running = true,
	enabled = CONFIG.enabled,
	connections = {} :: {RBXScriptConnection},
	entries = {} :: {[Model]: Entry},
	pending = setmetatable({}, {__mode = "k"}) :: {[Model]: boolean},
	Stop = nil :: ((string?) -> ())?,
}
_G[RUNTIME_KEY] = runtime

local INACTIVE_STATES = {
	[Enum.HumanoidStateType.Dead] = true,
	[Enum.HumanoidStateType.Physics] = true,
	[Enum.HumanoidStateType.Ragdoll] = true,
	[Enum.HumanoidStateType.FallingDown] = true,
	[Enum.HumanoidStateType.PlatformStanding] = true,
	[Enum.HumanoidStateType.Seated] = true,
}

local INACTIVE_ATTRIBUTES = {
	"Dead", "IsDead", "Corpse", "IsCorpse",
	"Downed", "IsDowned", "Knocked", "KnockedDown",
	"Ragdolled", "IsRagdolled", "Disabled", "Inactive",
}

local SIGNAL_ATTRIBUTES = {
	"IsZombie", "Zombie", "IsEnemyNPC", "Hostile",
	"IsNPC", "Enemy", "Minion", "Summoned",
}

local SIGNAL_TAGS = {"Zombie", "EnemyNPC", "HostileNPC", "Minion"}

local function norm(value: any): string
	return string.lower(tostring(value or "")):gsub("[^%w]", "")
end

local function remember(connection: RBXScriptConnection): RBXScriptConnection
	table.insert(runtime.connections, connection)
	return connection
end

local function findRoot(model: Model): BasePart?
	for _, name in ipairs({"HumanoidRootPart", "UpperTorso", "Torso", "RootPart"}) do
		local part = model:FindFirstChild(name)
		if part and part:IsA("BasePart") then
			return part
		end
	end
	return nil
end

local function modelParts(model: Model): (Humanoid?, BasePart?)
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	local root = findRoot(model)
	return humanoid, root
end

local function attributeEnabled(instance: Instance, names: {string}): boolean
	for _, name in ipairs(names) do
		local value = instance:GetAttribute(name)
		if value == true or (typeof(value) == "number" and value > 0) then
			return true
		end
	end
	return false
end

local function ancestorSignal(model: Model): boolean
	local current: Instance? = model
	for _ = 1, 8 do
		if not current or current == Workspace then
			break
		end
		local name = norm(current.Name)
		if string.find(name, "zombie", 1, true)
			or string.find(name, "infected", 1, true)
			or string.find(name, "undead", 1, true)
			or string.find(name, "walker", 1, true)
			or string.find(name, "ghoul", 1, true)
			or string.find(name, "minion", 1, true)
			or string.find(name, "summon", 1, true)
			or name == "npcs"
			or name == "enemies"
			or name == "mobs" then
			return true
		end
		current = current.Parent
	end
	return false
end

local function explicitSignal(model: Model): boolean
	if ancestorSignal(model) or attributeEnabled(model, SIGNAL_ATTRIBUTES) then
		return true
	end
	for _, tag in ipairs(SIGNAL_TAGS) do
		if CollectionService:HasTag(model, tag) then
			return true
		end
	end
	return false
end

local function rejectedName(model: Model): boolean
	local name = norm(model.Name)
	return string.find(name, "dummy", 1, true) ~= nil
		or string.find(name, "training", 1, true) ~= nil
		or string.find(name, "survivor", 1, true) ~= nil
		or string.find(name, "killer", 1, true) ~= nil
		or string.find(name, "maniac", 1, true) ~= nil
		or string.find(name, "lobby", 1, true) ~= nil
end

local function isNpcCandidate(model: Model): boolean
	if not model.Parent
		or model == LocalPlayer.Character
		or Players:GetPlayerFromCharacter(model) ~= nil
		or rejectedName(model) then
		return false
	end
	local humanoid, root = modelParts(model)
	if not humanoid or not root then
		return false
	end
	if explicitSignal(model) then
		return true
	end
	-- The game's zombies can be named only scp/scp5/Model and carry no tag.
	-- A non-player humanoid below the active Map is therefore the safe fallback.
	local map = Workspace:FindFirstChild("Map")
	return map ~= nil and model:IsDescendantOf(map)
end

local function isAliveActive(model: Model, humanoid: Humanoid, root: BasePart): boolean
	if not model.Parent or humanoid.Health <= 0 then
		return false
	end
	if INACTIVE_STATES[humanoid:GetState()]
		or humanoid.PlatformStand
		or attributeEnabled(model, INACTIVE_ATTRIBUTES)
		or attributeEnabled(humanoid, INACTIVE_ATTRIBUTES) then
		return false
	end
	return root.CFrame.UpVector.Y >= CONFIG.minimumUprightY
end

local function ensureHighlight(model: Model): Highlight
	-- Remove highlights created by the old movement-capable aura.
	local legacy = model:FindFirstChild("VDZombieAuraV13")
	if legacy and legacy:IsA("Highlight") then
		legacy:Destroy()
	end
	local highlight = model:FindFirstChild(AURA_NAME)
	if highlight and not highlight:IsA("Highlight") then
		highlight:Destroy()
		highlight = nil
	end
	if not highlight then
		highlight = Instance.new("Highlight")
		highlight.Name = AURA_NAME
		highlight.Parent = model
	end
	local aura = highlight :: Highlight
	aura.Adornee = model
	aura.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	aura.FillColor = CONFIG.fillColor
	aura.OutlineColor = CONFIG.outlineColor
	aura.FillTransparency = CONFIG.fillTransparency
	aura.OutlineTransparency = CONFIG.outlineTransparency
	aura.Enabled = false
	return aura
end

local unbindModel: (Model, string?) -> ()
local bindModel: (Model, boolean?) -> boolean

local function setEntryVisible(entry: Entry, visible: boolean): ()
	local finalVisible = runtime.running and runtime.enabled and visible
	if entry.visible ~= finalVisible or entry.highlight.Enabled ~= finalVisible then
		entry.visible = finalVisible
		entry.highlight.Enabled = finalVisible
	end
end

local function refreshEntry(entry: Entry): ()
	if not runtime.running then
		return
	end
	if not isNpcCandidate(entry.model) then
		unbindModel(entry.model, "candidate-invalid")
		return
	end
	local humanoid, root = modelParts(entry.model)
	if not humanoid or not root or humanoid ~= entry.humanoid or root ~= entry.root then
		unbindModel(entry.model, "rig-changed")
		bindModel(entry.model, true)
		return
	end
	setEntryVisible(entry, isAliveActive(entry.model, humanoid, root))
end

local function disconnectEntry(entry: Entry): ()
	for _, connection in ipairs(entry.connections) do
		if connection.Connected then
			connection:Disconnect()
		end
	end
	table.clear(entry.connections)
end

unbindModel = function(model: Model, _reason: string?): ()
	local entry = runtime.entries[model]
	if not entry then
		return
	end
	disconnectEntry(entry)
	if entry.highlight.Parent then
		entry.highlight:Destroy()
	end
	runtime.entries[model] = nil
end

local function watchAttribute(entry: Entry, instance: Instance, name: string): ()
	table.insert(entry.connections, instance:GetAttributeChangedSignal(name):Connect(function()
		refreshEntry(entry)
	end))
end

bindModel = function(model: Model, announce: boolean?): boolean
	local existing = runtime.entries[model]
	if existing then
		refreshEntry(existing)
		return true
	end
	if not runtime.running or not isNpcCandidate(model) then
		return false
	end
	local humanoid, root = modelParts(model)
	if not humanoid or not root then
		return false
	end
	local entry: Entry = {
		model = model,
		humanoid = humanoid,
		root = root,
		highlight = ensureHighlight(model),
		connections = {},
		visible = false,
	}
	runtime.entries[model] = entry

	table.insert(entry.connections, model.AncestryChanged:Connect(function()
		refreshEntry(entry)
	end))
	table.insert(entry.connections, model.ChildAdded:Connect(function()
		refreshEntry(entry)
	end))
	table.insert(entry.connections, model.ChildRemoved:Connect(function()
		task.defer(function()
			if runtime.entries[model] == entry then
				refreshEntry(entry)
			end
		end)
	end))
	table.insert(entry.connections, humanoid.HealthChanged:Connect(function()
		refreshEntry(entry)
	end))
	table.insert(entry.connections, humanoid.StateChanged:Connect(function()
		refreshEntry(entry)
	end))
	table.insert(entry.connections, humanoid:GetPropertyChangedSignal("PlatformStand"):Connect(function()
		refreshEntry(entry)
	end))
	table.insert(entry.connections, root:GetPropertyChangedSignal("Anchored"):Connect(function()
		refreshEntry(entry)
	end))
	-- Upright filtering depends on the root pose. Re-evaluate when a replicated
	-- rig rotates or is knocked over; Highlight itself follows the model.
	table.insert(entry.connections, root:GetPropertyChangedSignal("CFrame"):Connect(function()
		if runtime.entries[model] == entry then refreshEntry(entry) end
	end))
	for _, name in ipairs(INACTIVE_ATTRIBUTES) do
		watchAttribute(entry, model, name)
		watchAttribute(entry, humanoid, name)
	end
	for _, name in ipairs(SIGNAL_ATTRIBUTES) do
		watchAttribute(entry, model, name)
	end
	refreshEntry(entry)
	if announce then
		print(string.format("[VD ZOMBIE AURA v2.0][INDEXED] npc=%s visible=%s", model:GetFullName(), tostring(entry.visible)))
	end
	return true
end

local function queueModel(model: Model): ()
	if not runtime.running or runtime.pending[model] then
		return
	end
	runtime.pending[model] = true
	-- First attempt immediately, second after the replicated rig has received its
	-- Humanoid/root. DescendantAdded events during the window are naturally folded.
	task.defer(function()
		if runtime.running and runtime.pending[model] then
			bindModel(model, false)
		end
	end)
	task.delay(0.25, function()
		if not runtime.running or not runtime.pending[model] then
			return
		end
		runtime.pending[model] = nil
		bindModel(model, true)
	end)
end

local function queueInstanceAncestors(instance: Instance): ()
	local current: Instance? = if instance:IsA("Model") then instance else instance.Parent
	for _ = 1, 6 do
		if not current or current == Workspace then
			break
		end
		if current:IsA("Model") then
			queueModel(current)
		end
		current = current.Parent
	end
end

remember(Workspace.DescendantAdded:Connect(queueInstanceAncestors))
remember(Workspace.DescendantRemoving:Connect(function(instance)
	if instance:IsA("Model") and runtime.entries[instance] then
		unbindModel(instance, "removed")
	end
end))

for _, tag in ipairs(SIGNAL_TAGS) do
	remember(CollectionService:GetInstanceAddedSignal(tag):Connect(function(instance)
		queueInstanceAncestors(instance)
	end))
	remember(CollectionService:GetInstanceRemovedSignal(tag):Connect(function(instance)
		if instance:IsA("Model") and runtime.entries[instance] then
			refreshEntry(runtime.entries[instance])
		end
	end))
end

remember(UserInputService.InputBegan:Connect(function(input, processed)
	if processed or not runtime.running then
		return
	end
	if input.KeyCode == CONFIG.toggleKey then
		runtime.enabled = not runtime.enabled
		for _, entry in pairs(runtime.entries) do
			refreshEntry(entry)
		end
		print("[VD ZOMBIE AURA v2.0][STATE] " .. (runtime.enabled and "ON" or "OFF"))
	elseif input.KeyCode == CONFIG.stopKey and runtime.Stop then
		runtime.Stop("F12")
	end
end))

runtime.Stop = function(reason: string?): ()
	if not runtime.running then
		return
	end
	runtime.running = false
	for _, connection in ipairs(runtime.connections) do
		if connection.Connected then
			connection:Disconnect()
		end
	end
	table.clear(runtime.connections)
	local models = {}
	for model in pairs(runtime.entries) do
		table.insert(models, model)
	end
	for _, model in ipairs(models) do
		unbindModel(model, reason)
	end
	if _G[RUNTIME_KEY] == runtime then
		_G[RUNTIME_KEY] = nil
	end
	print("[VD ZOMBIE AURA v2.0][STOP] reason=" .. tostring(reason or "manual"))
end

-- One initial bounded scan. There is no periodic or per-frame GetDescendants.
-- Tagged/named NPCs can be spawned in Workspace folders outside Map. The
-- initial pass therefore covers Workspace; subsequent additions stay event-driven.
local initialRoot = Workspace
local inspected = 0
local bound = 0
for _, instance in ipairs(initialRoot:GetDescendants()) do
	if instance:IsA("Model") then
		inspected += 1
		if bindModel(instance, false) then
			bound += 1
		end
	end
end

print(string.format(
	"[VD ZOMBIE AURA v2.0][READY] mode=VISUAL_ONLY_EVENT_INDEXED inspected=%d bound=%d enabled=%s F5=toggle F12=stop",
	inspected,
	bound,
	tostring(runtime.enabled)
))
