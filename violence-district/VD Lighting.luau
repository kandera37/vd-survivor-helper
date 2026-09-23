--!strict
-- VD ASSIST LIGHTING v1.3
--
-- Owns one client-only ColorCorrectionEffect under CurrentCamera. The game
-- replaces Lighting children during map transitions, so a post effect parented
-- to Lighting is deleted by the native updateatmosphere script. This module
-- leaves all map-owned Lighting properties (Brightness, ExposureCompensation,
-- Ambient, ClockTime, Fog, Atmosphere, shadows) untouched.
--
-- F9 toggles the owned boost. F11 repairs/rebinds it immediately.

local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

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
local CONFIG = {
	enabled = true,
	heartbeatInterval = 0.50,
	logCooldown = 0.80,
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
	connections: {RBXScriptConnection},
	camera: Camera?,
	boost: ColorCorrectionEffect?,
	lastEnsureAt: number,
	lastLogAt: number,
	Stop: (() -> ())?,
}

local runtime: Runtime = {
	running = true,
	enabled = CONFIG.enabled,
	connections = {},
	camera = nil,
	boost = nil,
	lastEnsureAt = -math.huge,
	lastLogAt = -math.huge,
	Stop = nil,
}
_G[KEY] = runtime

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
	print("[VD ASSIST LIGHT v1.3] " .. message)
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

local function configureBoost(boost: ColorCorrectionEffect)
	for property, value in pairs(CONFIG.boost) do
		pcall(function()
			(boost :: any)[property] = value
		end)
	end
end

local function ensureBoost(reason: string)
	if not runtime.running or not runtime.enabled then
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

local function setEnabled(enabled: boolean)
	if runtime.enabled == enabled then
		return
	end
	runtime.enabled = enabled
	if enabled then
		ensureBoost("toggle-on")
		print("[VD ASSIST LIGHT v1.3][STATE] ON | camera-owned boost")
	else
		removeOwnedBoost()
		print("[VD ASSIST LIGHT v1.3][STATE] OFF | map Lighting untouched")
	end
end

local function stop()
	if not runtime.running then
		return
	end
	runtime.running = false
	runtime.enabled = false
	removeOwnedBoost()
	disconnectList(runtime.connections)
	runtime.camera = nil
	if rawget(_G, KEY) == runtime then
		rawset(_G, KEY, nil)
	end
	print("[VD ASSIST LIGHT v1.3][STOP] owned boost removed | map Lighting untouched")
end

runtime.Stop = stop

remember(Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
	if not runtime.running then
		return
	end
	if runtime.enabled then
		ensureBoost("camera-changed")
	end
end))

remember(RunService.Heartbeat:Connect(function()
	if not runtime.running or not runtime.enabled then
		return
	end
	if os.clock() - runtime.lastEnsureAt >= CONFIG.heartbeatInterval then
		ensureBoost("heartbeat")
	end
end))

remember(UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed or not runtime.running then
		return
	end
	if input.KeyCode == Enum.KeyCode.F9 then
		setEnabled(not runtime.enabled)
	elseif input.KeyCode == Enum.KeyCode.F11 then
		if runtime.enabled then
			ensureBoost("manual-F11")
			print("[VD ASSIST LIGHT v1.3][MANUAL] camera boost repaired")
		end
	end
end))

ensureBoost("startup")

local camera = Workspace.CurrentCamera
local cameraName = camera and camera:GetFullName() or "none"
print(string.format(
	"[VD ASSIST LIGHT v1.3][READY] camera-owned boost | enabled=%s camera=%s brightness=%.2f | map Brightness/Exposure/Ambient/ClockTime/Fog/Atmosphere untouched | F9 toggle | F11 repair",
	tostring(runtime.enabled),
	cameraName,
	CONFIG.boost.Brightness
))
