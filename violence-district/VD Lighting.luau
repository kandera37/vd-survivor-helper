--!strict
--==============================================================
-- VD ASSIST LIGHTING STABILIZER PATCH v1.1 FIXED
--
-- Run AFTER VD Assist v9.9.
--
-- The old version forced a lighting snapshot from one map onto every map.
-- That is unsafe when this script is started during a live round: ClockTime,
-- fog and Atmosphere are global map state, not local UI state. The default
-- mode below is therefore adaptive/observe-only. The current map owns its
-- lighting and post effects; no global properties are rewritten in a match.
--
-- F9: toggle stabilizer
-- F11: force known-good profile now
--==============================================================

local Lighting = game:GetService("Lighting")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local KEY = "__VD_ASSIST_LIGHTING_STABILIZER_V1_0"
-- Stop copies from the pre-audit names as well.  Volt can leave an older
-- runtime alive when a script is hot-reloaded; that runtime was the one that
-- kept writing ClockTime/fog during a live round.  The aliases are harmless
-- when absent and prevent two lighting owners from fighting each other.
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

local CONFIG = {
	enabled = true,
	heartbeatInterval = 1.0,
	changeDebounce = 0.025,
	logCooldown = 0.80,
	-- Brightness and exposure are client-side presentation controls.  They are
	-- safe to maintain during a round; map-owned time, fog and ambient values
	-- stay untouched by the whitelist below.
	applyLightingProfile = true,
	applyAtmosphereProfile = false,

	-- Known-good state captured before the bad map transition.
	lighting = {
		Brightness = 3.0,
		ExposureCompensation = 0.0,
		Ambient = Color3.fromRGB(0, 0, 0),
		OutdoorAmbient = Color3.fromRGB(65, 72, 53),
		ClockTime = 17.0,
		GlobalShadows = false,
		ShadowSoftness = 0.0,
		EnvironmentDiffuseScale = 0.222,
		EnvironmentSpecularScale = 1.0,
		FogStart = 0.0,
		FogEnd = 100000.0,
		FogColor = Color3.fromRGB(192, 192, 192),
	},

	atmosphere = {
		Density = 0.345,
		Haze = 1.88,
		Glare = 0.21,
		Offset = 0.0,
		Color = Color3.fromRGB(255, 192, 146),
		Decay = Color3.fromRGB(213, 233, 248),
	},

	-- The transition created:
	-- Brightness=0.07, Contrast=0.30, TintColor=(216,255,223).
	-- Disable newly-added map correction effects. Existing effects present
	-- when this patch starts are preserved.
	disableNewColorCorrection = false,

	-- Keep the initially-present post effects stable too.
	lockExistingPostEffects = false,
}

type Snapshot = {[string]: any}
type Runtime = {
	running: boolean,
	enabled: boolean,
	connections: {RBXScriptConnection},
	baselineLighting: Snapshot,
	baselineAtmosphere: Snapshot?,
	baselineAtmosphereInstance: Atmosphere?,
	baselineEffects: {[Instance]: Snapshot},
	baselineColorCorrections: {[Instance]: boolean},
	disabledNewColorCorrections: {[Instance]: boolean},
	lastApplyAt: number,
	lastLogAt: number,
	applyQueued: boolean,
	suppressChanges: boolean,
	Stop: (() -> ())?,
}

local runtime: Runtime = {
	running = true,
	enabled = CONFIG.enabled,
	connections = {},
	baselineLighting = {},
	baselineAtmosphere = nil,
	baselineAtmosphereInstance = nil,
	baselineEffects = {},
	baselineColorCorrections = {},
	disabledNewColorCorrections = {},
	lastApplyAt = -math.huge,
	lastLogAt = -math.huge,
	applyQueued = false,
	suppressChanges = false,
	Stop = nil,
}
_G[KEY] = runtime

local LIGHTING_PROPERTIES = {
	"Brightness",
	"ExposureCompensation",
	"Ambient",
	"OutdoorAmbient",
	"ClockTime",
	"GlobalShadows",
	"ShadowSoftness",
	"EnvironmentDiffuseScale",
	"EnvironmentSpecularScale",
	"FogStart",
	"FogEnd",
	"FogColor",
}

-- Never force map-owned lighting state.  In particular, ClockTime/Fog and
-- Atmosphere are replicated scene state and changing them caused the live
-- round regression this script was introduced to prevent.
local SAFE_LOCAL_LIGHTING_PROPERTIES = {
	Brightness = true,
	ExposureCompensation = true,
}

local ATMOSPHERE_PROPERTIES = {
	"Density",
	"Haze",
	"Glare",
	"Offset",
	"Color",
	"Decay",
}

local EFFECT_PROPERTIES: {[string]: {string}} = {
	BloomEffect = {
		"Enabled",
		"Intensity",
		"Size",
		"Threshold",
	},
	SunRaysEffect = {
		"Enabled",
		"Intensity",
		"Spread",
	},
	BlurEffect = {
		"Enabled",
		"Size",
	},
	DepthOfFieldEffect = {
		"Enabled",
		"FarIntensity",
		"FocusDistance",
		"InFocusRadius",
		"NearIntensity",
	},
}

local function remember(connection: RBXScriptConnection): RBXScriptConnection
	table.insert(runtime.connections, connection)
	return connection
end

local function safeRead(instance: Instance, property: string): (boolean, any)
	return pcall(function()
		return (instance :: any)[property]
	end)
end

local function safeWrite(instance: Instance, property: string, value: any): boolean
	local ok = pcall(function()
		(instance :: any)[property] = value
	end)
	return ok
end

local function nearlyEqual(a: any, b: any): boolean
	if typeof(a) ~= typeof(b) then
		return false
	end

	if typeof(a) == "number" then
		return math.abs((a :: number) - (b :: number)) <= 0.001
	end

	if typeof(a) == "Color3" then
		local ac = a :: Color3
		local bc = b :: Color3
		return math.abs(ac.R - bc.R) <= 0.002
			and math.abs(ac.G - bc.G) <= 0.002
			and math.abs(ac.B - bc.B) <= 0.002
	end

	return a == b
end

local function snapshot(instance: Instance, properties: {string}): Snapshot
	local result: Snapshot = {}
	for _, property in ipairs(properties) do
		local ok, value = safeRead(instance, property)
		if ok then
			result[property] = value
		end
	end
	return result
end

local function setIfDifferent(
	instance: Instance,
	property: string,
	target: any
): boolean
	local ok, current = safeRead(instance, property)
	if not ok or nearlyEqual(current, target) then
		return false
	end

	return safeWrite(instance, property, target)
end

local function findAtmosphere(): Atmosphere?
	for _, child in ipairs(Lighting:GetChildren()) do
		if child:IsA("Atmosphere") then
			return child
		end
	end
	return nil
end

local function captureExistingEffects()
	runtime.baselineLighting = snapshot(Lighting, LIGHTING_PROPERTIES)
	runtime.baselineAtmosphereInstance = findAtmosphere()
	runtime.baselineAtmosphere =
		runtime.baselineAtmosphereInstance
		and snapshot(
			runtime.baselineAtmosphereInstance,
			ATMOSPHERE_PROPERTIES
		)
		or nil
	table.clear(runtime.baselineEffects)
	table.clear(runtime.baselineColorCorrections)
	table.clear(runtime.disabledNewColorCorrections)

	for _, child in ipairs(Lighting:GetChildren()) do
		if child:IsA("ColorCorrectionEffect") then
			runtime.baselineColorCorrections[child] = true
		else
			local properties = EFFECT_PROPERTIES[child.ClassName]
			if properties then
				runtime.baselineEffects[child] =
					snapshot(child, properties)
			end
		end
	end
end

local function adoptAtmosphereBaseline(atmosphere: Atmosphere)
	if not atmosphere or not atmosphere.Parent then return end
	runtime.baselineAtmosphereInstance = atmosphere
	runtime.baselineAtmosphere = snapshot(atmosphere, ATMOSPHERE_PROPERTIES)
end

local function logCorrection(changed: {string})
	if #changed == 0 then
		return
	end

	local now = os.clock()
	if now - runtime.lastLogAt < CONFIG.logCooldown then
		return
	end
	runtime.lastLogAt = now

	local preview = {}
	for index = 1, math.min(#changed, 8) do
		table.insert(preview, changed[index])
	end

	print(string.format(
		"[VD ASSIST LIGHT v1.1][STABILIZED] changed=%d fields=%s",
		#changed,
		table.concat(preview, ",")
	))
end

local function applyKnownGood(reason: string?)
	if not runtime.running or not runtime.enabled then
		return
	end

	runtime.applyQueued = false
	runtime.suppressChanges = true
	local changed = {}

	if CONFIG.applyLightingProfile then
		for property, target in pairs(CONFIG.lighting) do
			if SAFE_LOCAL_LIGHTING_PROPERTIES[property]
				and setIfDifferent(Lighting, property, target) then
				table.insert(changed, "Lighting." .. property)
			end
		end
	end

	if CONFIG.applyAtmosphereProfile then
		local atmosphere = findAtmosphere()
		if atmosphere then
			for property, target in pairs(CONFIG.atmosphere) do
				if setIfDifferent(atmosphere, property, target) then
					table.insert(changed, "Atmosphere." .. property)
				end
			end
		end
	end

	if CONFIG.disableNewColorCorrection then
		for _, child in ipairs(Lighting:GetChildren()) do
			if child:IsA("ColorCorrectionEffect")
				and not runtime.baselineColorCorrections[child]
				and child.Enabled then
				if runtime.disabledNewColorCorrections[child] == nil then
					runtime.disabledNewColorCorrections[child] = child.Enabled
				end
				child.Enabled = false
				table.insert(
					changed,
					"ColorCorrection." .. child.Name .. ".Enabled"
				)
			end
		end
	end

	if CONFIG.lockExistingPostEffects then
		for effect, values in pairs(runtime.baselineEffects) do
			if effect.Parent then
				for property, target in pairs(values) do
					if setIfDifferent(effect, property, target) then
						table.insert(
							changed,
							effect.ClassName .. "." .. property
						)
					end
				end
			end
		end
	end

	runtime.lastApplyAt = os.clock()
	runtime.suppressChanges = false

	if #changed > 0 then
		logCorrection(changed)
	end
end

local function restoreBaseline(reason: string?)
	runtime.applyQueued = false
	runtime.suppressChanges = true

	if CONFIG.applyLightingProfile then
		for property, target in pairs(runtime.baselineLighting) do
			if SAFE_LOCAL_LIGHTING_PROPERTIES[property] then
				safeWrite(Lighting, property, target)
			end
		end
	end

	if CONFIG.applyAtmosphereProfile then
		local atmosphere = runtime.baselineAtmosphereInstance
		if atmosphere and atmosphere.Parent and runtime.baselineAtmosphere then
			for property, target in pairs(runtime.baselineAtmosphere) do
				safeWrite(atmosphere, property, target)
			end
		end
	end

	if CONFIG.lockExistingPostEffects then
		for effect, values in pairs(runtime.baselineEffects) do
			if effect.Parent then
				for property, target in pairs(values) do
					safeWrite(effect, property, target)
				end
			end
		end
	end

	for effect, wasEnabled in pairs(runtime.disabledNewColorCorrections) do
		if effect.Parent and effect:IsA("ColorCorrectionEffect") then
			safeWrite(effect, "Enabled", wasEnabled)
		end
	end
	table.clear(runtime.disabledNewColorCorrections)

	runtime.suppressChanges = false
	print(string.format(
		"[VD ASSIST LIGHT v1.1][RESTORED] reason=%s",
		tostring(reason or "disabled")
	))
end

local function queueApply(reason: string)
	if not runtime.running
		or not runtime.enabled
		or runtime.suppressChanges
		or runtime.applyQueued then
		return
	end

	runtime.applyQueued = true
	task.delay(CONFIG.changeDebounce, function()
		if runtime.running and runtime.enabled then
			applyKnownGood(reason)
		else
			runtime.applyQueued = false
		end
	end)
end

local function watchProperty(instance: Instance, property: string)
	local ok, signal = pcall(function()
		return instance:GetPropertyChangedSignal(property)
	end)
	if ok and signal then
		remember(signal:Connect(function()
			queueApply(instance.Name .. "." .. property)
		end))
	end
end

local function watchLighting()
	if CONFIG.applyLightingProfile then
		for _, property in ipairs(LIGHTING_PROPERTIES) do
			if SAFE_LOCAL_LIGHTING_PROPERTIES[property] then
				watchProperty(Lighting, property)
			end
		end
	end

	local atmosphere = findAtmosphere()
	if atmosphere and CONFIG.applyAtmosphereProfile then
		for property in pairs(CONFIG.atmosphere) do
			watchProperty(atmosphere, property)
		end
	end

	if CONFIG.lockExistingPostEffects then
		for effect, values in pairs(runtime.baselineEffects) do
			for property in pairs(values) do
				watchProperty(effect, property)
			end
		end
	end

	remember(Lighting.ChildAdded:Connect(function(child)
		if child:IsA("ColorCorrectionEffect") and CONFIG.disableNewColorCorrection then
			task.defer(function()
				queueApply("new ColorCorrection: " .. child.Name)
			end)
		elseif child:IsA("Atmosphere") then
			-- Map transitions may replace the original Atmosphere instance. Keep
			-- the replacement as the restore target instead of writing to a dead
			-- object when the script is disabled.
			if not runtime.baselineAtmosphereInstance
				or not runtime.baselineAtmosphereInstance.Parent then
				adoptAtmosphereBaseline(child)
			end
			if CONFIG.applyAtmosphereProfile then
				for property in pairs(CONFIG.atmosphere) do
					watchProperty(child, property)
				end
			end
			if CONFIG.applyAtmosphereProfile then
				task.defer(function()
					queueApply("new Atmosphere")
				end)
			end
		end
	end))
	remember(Lighting.ChildRemoved:Connect(function(child)
		if child:IsA("Atmosphere")
			and child == runtime.baselineAtmosphereInstance then
			task.defer(function()
				local replacement = findAtmosphere()
				if replacement then adoptAtmosphereBaseline(replacement) end
				if CONFIG.applyAtmosphereProfile and runtime.running and runtime.enabled then
					queueApply("Atmosphere replacement")
				end
			end)
		end
	end))
end

local function setEnabled(enabled: boolean)
	if runtime.enabled == enabled then
		return
	end
	runtime.enabled = enabled
	if enabled then
		-- A toggle on may happen after a map/round transition. Refresh the
		-- observation baseline so Stop never restores an old map's values.
		captureExistingEffects()
		applyKnownGood("toggle on")
		print("[VD ASSIST LIGHT v1.1][STATE] ON | adaptive monitor | F11 recapture")
	else
		restoreBaseline("toggle off")
		print("[VD ASSIST LIGHT v1.1][STATE] OFF | map lighting left unchanged")
	end
end

runtime.Stop = function()
	if not runtime.running then
		return
	end

	if runtime.enabled then
		restoreBaseline("stop")
	end
	runtime.enabled = false
	runtime.running = false
	for _, connection in ipairs(runtime.connections) do
		pcall(function()
			connection:Disconnect()
		end)
	end
	table.clear(runtime.connections)

	if rawget(_G, KEY) == runtime then
		_G[KEY] = nil
	end
end

captureExistingEffects()
watchLighting()
applyKnownGood("startup")

remember(RunService.Heartbeat:Connect(function()
	if not runtime.running or not runtime.enabled then
		return
	end

	local now = os.clock()
	if now - runtime.lastApplyAt >= CONFIG.heartbeatInterval then
		applyKnownGood("heartbeat")
	end
end))

remember(UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then
		return
	end

	if input.KeyCode == Enum.KeyCode.F9 then
		setEnabled(not runtime.enabled)
	elseif input.KeyCode == Enum.KeyCode.F11 then
		captureExistingEffects()
		runtime.enabled = true
		applyKnownGood("manual F11 recapture")
		print("[VD ASSIST LIGHT v1.1][MANUAL] adaptive baseline recaptured")
	end
end))

do
	local okBrightness, brightness = safeRead(Lighting, "Brightness")
	local okExposure, exposure = safeRead(Lighting, "ExposureCompensation")
	print(string.format(
		"[VD ASSIST LIGHT v1.2][READY] local brightness/exposure stabilizer | enabled=%s brightness=%s exposure=%s | map ClockTime/Fog/Ambient untouched | F9 toggle | F11 recapture",
		tostring(runtime.enabled),
		okBrightness and string.format("%.2f", brightness) or "?",
		okExposure and string.format("%.2f", exposure) or "?"
	))
end
