--!strict
-- VD ASSIST LIGHTING v1.6
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
		-- The lobby profile already supplies the ambient lift. Keep only a very
		-- small correction so the match is not washed out in bright areas.
		Brightness = 0.03,
		Contrast = 0.0,
		Saturation = 0.0,
		-- ColorShift_Top already carries the lobby warmth; do not stack another
		-- yellow tint on the camera correction.
		TintColor = Color3.fromRGB(255, 255, 255),
	},
}

type Runtime = {
	running: boolean,
	enabled: boolean,
	matchActive: boolean,
	connections: {RBXScriptConnection},
	camera: Camera?,
	cameraPostConnection: RBXScriptConnection?,
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
	postEffects: {[Instance]: boolean},
	profile: {[string]: any},
}

local runtime: Runtime = {
	running = true,
	enabled = CONFIG.enabled,
	matchActive = false,
	connections = {},
	camera = nil,
	cameraPostConnection = nil,
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
	print("[VD ASSIST LIGHT v1.6] " .. message)
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

local function isPostEffect(instance: Instance): boolean
	return instance:IsA("ColorCorrectionEffect")
		or instance:IsA("BlurEffect")
		or instance:IsA("BloomEffect")
		or instance:IsA("DepthOfFieldEffect")
		or instance:IsA("SunRaysEffect")
end

-- This is the game's own intermission profile. The round map script can write
-- a dark map profile again after we start, so the values are reasserted while
-- the match is active and restored from the first observed state on exit.
local LOBBY_PROFILE = {
	-- Values from the game's applyLobbyLighting function. The camera boost is
	-- deliberately small so this keeps the lobby's warm balance without washout.
	Brightness = 3,
	ExposureCompensation = 0,
	Ambient = Color3.fromRGB(0, 0, 0),
	OutdoorAmbient = Color3.fromRGB(65, 72, 53),
	ColorShift_Top = Color3.fromRGB(255, 192, 146),
	ColorShift_Bottom = Color3.fromRGB(0, 0, 0),
	ClockTime = 17,
	-- Keep the exact lobby reflection balance. Zeroing these values makes
	-- enclosed map areas visibly darker and is not what the game's lobby uses.
	EnvironmentDiffuseScale = 0.222,
	EnvironmentSpecularScale = 1,
	GlobalShadows = false,
	ShadowSoftness = 0,
}

local function suppressPostEffect(effect: Instance)
	local snapshot = nativeFog
	if not snapshot or not isPostEffect(effect) or effect == runtime.boost then return end
	if snapshot.postEffects[effect] == nil then
		local ok, enabled = pcall(function() return (effect :: any).Enabled end)
		if not ok then return end
		snapshot.postEffects[effect] = enabled
	end
	pcall(function() (effect :: any).Enabled = false end)
end

local function applyLobbyProfile()
	local snapshot = nativeFog
	if not snapshot then return end
	for property, value in pairs(LOBBY_PROFILE) do
		if snapshot.profile[property] == nil then
			local ok, previous = pcall(function() return (Lighting :: any)[property] end)
			if ok then snapshot.profile[property] = previous end
		end
		pcall(function() (Lighting :: any)[property] = value end)
	end
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
			postEffects = {},
			profile = {},
		}
	end
	local snapshot = nativeFog
	if Lighting.FogStart ~= 0 then snapshot.FogStart = Lighting.FogStart end
	if Lighting.FogEnd ~= CONFIG.fogEnd then snapshot.FogEnd = Lighting.FogEnd end
	pcall(function() Lighting.FogStart = 0 end)
	pcall(function() Lighting.FogEnd = CONFIG.fogEnd end)
	for _, child in ipairs(Lighting:GetChildren()) do
		if isPostEffect(child) then
			suppressPostEffect(child)
		end
		if child:IsA("Atmosphere") then
			rememberAtmosphere(child)
			pcall(function()
				child.Density = 0
				child.Haze = 0
				child.Glare = 0
			end)
		end
	end
	local camera = Workspace.CurrentCamera
	if camera then
		for _, child in ipairs(camera:GetChildren()) do
			suppressPostEffect(child)
		end
	end
	applyLobbyProfile()
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
	for effect, wasEnabled in pairs(snapshot.postEffects) do
		if effect.Parent then
			pcall(function() (effect :: any).Enabled = wasEnabled end)
		end
	end
	for property, value in pairs(snapshot.profile) do
		pcall(function() (Lighting :: any)[property] = value end)
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
		print("[VD ASSIST LIGHT v1.6][STATE] ON | lobby profile active in match")
	else
		removeOwnedBoost()
		restoreFog()
		print("[VD ASSIST LIGHT v1.6][STATE] OFF | native lighting restored")
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
	if runtime.cameraPostConnection then
		pcall(function() runtime.cameraPostConnection:Disconnect() end)
		runtime.cameraPostConnection = nil
	end
	runtime.camera = nil
	if rawget(_G, KEY) == runtime then
		rawset(_G, KEY, nil)
	end
	print("[VD ASSIST LIGHT v1.6][STOP] owned effects removed | native lighting restored")
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

remember(Lighting.ChildAdded:Connect(function(child)
	if runtime.running and runtime.enabled and runtime.matchActive then
		suppressPostEffect(child)
	end
end))

local boundPostCamera: Camera? = nil
local function bindCameraPostEffects(camera: Camera?)
	if boundPostCamera == camera then return end
	if runtime.cameraPostConnection then
		pcall(function() runtime.cameraPostConnection:Disconnect() end)
		runtime.cameraPostConnection = nil
	end
	boundPostCamera = camera
	if not camera then return end
	runtime.cameraPostConnection = camera.ChildAdded:Connect(function(child)
		if runtime.running and runtime.enabled and runtime.matchActive then
			suppressPostEffect(child)
		end
	end)
end
bindCameraPostEffects(Workspace.CurrentCamera)

remember(Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
	if runtime.running then
		bindCameraPostEffects(Workspace.CurrentCamera)
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
			print("[VD ASSIST LIGHT v1.6][MANUAL] lobby profile repaired")
		end
	end
end))

syncWorldState("startup")

local camera = Workspace.CurrentCamera
local cameraName = camera and camera:GetFullName() or "none"
print(string.format(
	"[VD ASSIST LIGHT v1.6][READY] lobby-profile match lighting | enabled=%s match=%s camera=%s brightness=%.2f fogSmokePostEffects=match-only | F9 toggle | F11 repair",
	tostring(runtime.enabled),
	tostring(runtime.matchActive),
	cameraName,
	CONFIG.boost.Brightness
))
