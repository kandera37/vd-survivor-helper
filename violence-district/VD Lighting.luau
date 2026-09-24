--!strict
-- VD ASSIST LIGHTING v1.5
--
-- Applies the client visibility boost only while the local player has a live
-- Survivor/Killer team. Lobby lighting is left alone. During a match, fog,
-- atmosphere haze, and named smoke/mist emitters are temporarily hidden.
--
-- F9 toggles the owned boost. F11 repairs/rebinds it immediately.

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local Lighting = game:GetService("Lighting")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local LocalPlayer = Players.LocalPlayer
if not LocalPlayer then return end

local KEY = "__VD_ASSIST_LIGHTING_STABILIZER_V1_0"
for _, legacyKey in ipairs({
	KEY,
	"__VD_ASSIST_LIGHTING_STABILIZER",
	"__VD_LIGHTING_STABILIZER",
	"__VD_ASSIST_LIGHTING",
}) do
	local old = rawget(_G, legacyKey)
	if type(old) == "table" and typeof(old.Stop) == "function" then
		pcall(old.Stop)
	end
end

local BOOST_NAME = "VDLightingClientVisibilityBoost"
local MATCH_TEAMS = {
	survivors = true,
	killer = true,
}
local CONFIG = {
	enabled = true,
	heartbeatInterval = 0.50,
	logCooldown = 0.80,
	fogEnd = 100000,
	boost = {
		Enabled = true,
		Brightness = 0.22,
		Contrast = 0.0,
		Saturation = 0.0,
		TintColor = Color3.fromRGB(255, 255, 255),
	},
}

type Runtime = {
	running: boolean,
	enabled: boolean,
	matchActive: boolean,
	connections: {RBXScriptConnection},
	camera: Camera?,
	boost: ColorCorrectionEffect?,
	lastEnsureAt: number,
	lastLogAt: number,
	Stop: (() -> ())?,
}

type AtmosphereState = {
	Density: number,
	Haze: number,
	Glare: number,
}

type NativeFogState = {
	FogStart: number,
	FogEnd: number,
	atmospheres: {[Atmosphere]: AtmosphereState},
	emitters: {[Instance]: boolean},
}

local runtime: Runtime = {
	running = true,
	enabled = CONFIG.enabled,
	matchActive = false,
	connections = {},
	camera = nil,
	boost = nil,
	lastEnsureAt = -math.huge,
	lastLogAt = -math.huge,
	Stop = nil,
}
_G[KEY] = runtime
local nativeFog: NativeFogState? = nil

local function remember(connection: RBXScriptConnection): RBXScriptConnection
	table.insert(runtime.connections, connection)
	return connection
end

local function disconnectList(list: {RBXScriptConnection})
	for _, connection in ipairs(list) do
		pcall(function()
			connection:Disconnect()
		end)
	end
	table.clear(list)
end

local function log(message: string)
	local now = os.clock()
	if now - runtime.lastLogAt < CONFIG.logCooldown then
		return
	end
	runtime.lastLogAt = now
	print("[VD ASSIST LIGHT v1.5] " .. message)
end

local function removeOwnedBoost()
	local boost = runtime.boost
	runtime.boost = nil
	if boost then
		pcall(function()
			boost:Destroy()
		end)
	end
end

local function isMatchActive(): boolean
	local team = LocalPlayer.Team
	local teamName = team and string.lower(team.Name) or ""
	return MATCH_TEAMS[teamName] == true
		and LocalPlayer:GetAttribute("killerend") ~= true
end

local function rememberAtmosphere(atmosphere: Atmosphere)
	local snapshot = nativeFog
	if not snapshot then return end
	local values = snapshot.atmospheres[atmosphere]
	if not values then
		values = {
			Density = atmosphere.Density,
			Haze = atmosphere.Haze,
			Glare = atmosphere.Glare,
		}
		snapshot.atmospheres[atmosphere] = values
		return
	end
	if atmosphere.Density ~= 0 then values.Density = atmosphere.Density end
	if atmosphere.Haze ~= 0 then values.Haze = atmosphere.Haze end
	if atmosphere.Glare ~= 0 then values.Glare = atmosphere.Glare end
end

local function isSmokeEffect(instance: Instance): boolean
	local isSmokeClass = instance:IsA("Smoke")
	if not isSmokeClass and not instance:IsA("ParticleEmitter") then
		return false
	end
	if isSmokeClass then return true end
	local name = string.lower(instance.Name)
	return string.find(name, "smoke", 1, true) ~= nil
		or string.find(name, "mist", 1, true) ~= nil
		or string.find(name, "fog", 1, true) ~= nil
end

local function suppressSmokeEffect(emitter: Instance)
	local snapshot = nativeFog
	if not snapshot or not isSmokeEffect(emitter) then return end
	if snapshot.emitters[emitter] == nil then
		local ok, enabled = pcall(function() return (emitter :: any).Enabled end)
		if not ok then return end
		snapshot.emitters[emitter] = enabled
	end
	pcall(function()
		(emitter :: any).Enabled = false
		if emitter:IsA("ParticleEmitter") then
			emitter:Clear()
		end
	end)
end

local function applyFogRemoval()
	local needsWorkspaceScan = nativeFog == nil
	if not nativeFog then
		nativeFog = {
			FogStart = Lighting.FogStart,
			FogEnd = Lighting.FogEnd,
			atmospheres = {},
			emitters = {},
		}
	end
	local snapshot = nativeFog
	if Lighting.FogStart ~= 0 then snapshot.FogStart = Lighting.FogStart end
	if Lighting.FogEnd ~= CONFIG.fogEnd then snapshot.FogEnd = Lighting.FogEnd end
	pcall(function() Lighting.FogStart = 0 end)
	pcall(function() Lighting.FogEnd = CONFIG.fogEnd end)
	for _, child in ipairs(Lighting:GetChildren()) do
		if child:IsA("Atmosphere") then
			rememberAtmosphere(child)
			pcall(function()
				child.Density = 0
				child.Haze = 0
				child.Glare = 0
			end)
		end
	end
	if needsWorkspaceScan then
		for _, descendant in ipairs(Workspace:GetDescendants()) do
			if isSmokeEffect(descendant) then
				suppressSmokeEffect(descendant)
			end
		end
	else
		for emitter in pairs(snapshot.emitters) do
			if emitter.Parent then
				pcall(function() (emitter :: any).Enabled = false end)
			end
		end
	end
end

local function restoreFog()
	local snapshot = nativeFog
	if not snapshot then return end
	nativeFog = nil
	pcall(function() Lighting.FogStart = snapshot.FogStart end)
	pcall(function() Lighting.FogEnd = snapshot.FogEnd end)
	for atmosphere, values in pairs(snapshot.atmospheres) do
		if atmosphere.Parent then
			pcall(function()
				atmosphere.Density = values.Density
				atmosphere.Haze = values.Haze
				atmosphere.Glare = values.Glare
			end)
		end
	end
	for emitter, wasEnabled in pairs(snapshot.emitters) do
		if emitter.Parent then
			pcall(function() (emitter :: any).Enabled = wasEnabled end)
		end
	end
end

local function configureBoost(boost: ColorCorrectionEffect)
	for property, value in pairs(CONFIG.boost) do
		pcall(function()
			(boost :: any)[property] = value
		end)
	end
end

local function ensureBoost(reason: string)
	if not runtime.running or not runtime.enabled or not runtime.matchActive then
		removeOwnedBoost()
		return
	end
	local camera = Workspace.CurrentCamera
	if runtime.camera ~= camera then
		removeOwnedBoost()
		runtime.camera = camera
	end
	runtime.lastEnsureAt = os.clock()
	if not camera then
		return
	end

	local boost = runtime.boost
	if not boost or boost.Parent ~= camera then
		removeOwnedBoost()
		boost = Instance.new("ColorCorrectionEffect")
		boost.Name = BOOST_NAME
		configureBoost(boost)
		boost.Parent = camera
		runtime.boost = boost
		log("boost bound camera=" .. camera:GetFullName() .. " reason=" .. reason)
	end
	configureBoost(boost)
	runtime.lastEnsureAt = os.clock()
end

local function syncWorldState(reason: string)
	if not runtime.running then return end
	runtime.lastEnsureAt = os.clock()
	local wasActive = runtime.matchActive
	runtime.matchActive = isMatchActive()
	if not runtime.matchActive then
		removeOwnedBoost()
		runtime.camera = nil
		restoreFog()
		if wasActive then log("MATCH OFF | lobby lighting restored") end
		return
	end
	if runtime.enabled then
		applyFogRemoval()
		ensureBoost(reason)
	else
		removeOwnedBoost()
		restoreFog()
	end
	if not wasActive then log("MATCH ON | boost and fog removal active") end
end

local function setEnabled(enabled: boolean)
	if runtime.enabled == enabled then
		return
	end
	runtime.enabled = enabled
	if enabled then
		syncWorldState("toggle-on")
		print("[VD ASSIST LIGHT v1.5][STATE] ON | active match only")
	else
		removeOwnedBoost()
		restoreFog()
		print("[VD ASSIST LIGHT v1.5][STATE] OFF | native fog restored")
	end
end

local function stop()
	if not runtime.running then
		return
	end
	runtime.running = false
	runtime.enabled = false
	removeOwnedBoost()
	restoreFog()
	disconnectList(runtime.connections)
	runtime.camera = nil
	if rawget(_G, KEY) == runtime then
		rawset(_G, KEY, nil)
	end
	print("[VD ASSIST LIGHT v1.5][STOP] owned boost removed | native fog restored")
end

runtime.Stop = stop

remember(Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
	if not runtime.running then
		return
	end
	syncWorldState("camera-changed")
end))

remember(Workspace.DescendantAdded:Connect(function(descendant)
	if runtime.running and runtime.enabled and runtime.matchActive then
		suppressSmokeEffect(descendant)
	end
end))

remember(LocalPlayer:GetPropertyChangedSignal("Team"):Connect(function()
	syncWorldState("team-changed")
end))
remember(LocalPlayer:GetAttributeChangedSignal("killerend"):Connect(function()
	syncWorldState("round-ended")
end))

remember(RunService.Heartbeat:Connect(function()
	if runtime.running and os.clock() - runtime.lastEnsureAt >= CONFIG.heartbeatInterval then
		syncWorldState("heartbeat")
	end
end))

remember(UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed or not runtime.running then
		return
	end
	if input.KeyCode == Enum.KeyCode.F9 then
		setEnabled(not runtime.enabled)
	elseif input.KeyCode == Enum.KeyCode.F11 then
		if runtime.enabled and runtime.matchActive then
			syncWorldState("manual-F11")
			print("[VD ASSIST LIGHT v1.5][MANUAL] match boost repaired")
		end
	end
end))

syncWorldState("startup")

local camera = Workspace.CurrentCamera
local cameraName = camera and camera:GetFullName() or "none"
print(string.format(
	"[VD ASSIST LIGHT v1.5][READY] match-only camera boost | enabled=%s match=%s camera=%s brightness=%.2f fogAndSmokeRemoval=match-only | F9 toggle | F11 repair",
	tostring(runtime.enabled),
	tostring(runtime.matchActive),
	cameraName,
	CONFIG.boost.Brightness
))
