--!strict
-- VD Unified Loader v1.1
--
-- One entry point for the current standalone VD modules.  The loader only
-- downloads and executes the files below; it does not write movement, camera,
-- physics, remotes, or game state itself.  A second launch stops the previous
-- bundle before creating a new one.

local BASE_URL = "https://raw.githubusercontent.com/kandera37/vd-survivor-helper/refs/heads/main/violence-district/"
local RUNTIME_KEY = "__VD_UNIFIED_LOADER_V1"
local LOADER_VERSION = "1.1"
local BUILD_TAG = "2026-09-25-veil-handoff-repair-lighting-v16"

local MODULES = {
	-- Providers first: Assist publishes the generator/objective cache used by
	-- Anti 3Gen and the Helper; telemetry can bind before a round transition.
	"VD Assist.luau",
	"VD Interaction State Monitor.luau",
	"VD Killer Ability Radar.luau",
	"VD Lighting.luau",
	"Survivor Auto .luau",
	"VD Zombie Aura.luau",
	"VD Anti 3Gen.luau",
	"VD Survivor Helper v5.5.82 AUDIT-CORE-INTEGRATION-FIX.luau",
	"Auto-Parry.luau",
}

local function encodePath(value: string): string
	return (string.gsub(value, "[^%w%._%-%/]", function(character: string): string
		return string.format("%%%02X", string.byte(character))
	end))
end

local function callStop(value: any, reason: string)
	if type(value) ~= "table" or type(value.Stop) ~= "function" then
		return false
	end
	local ok = pcall(value.Stop, reason)
	return ok
end

local function isCurrent(runtime: any): boolean
	return runtime.Running == true
		and rawget(_G, RUNTIME_KEY) == runtime
end

local function stopKnownModules(reason: string)
	-- Stop in reverse dependency order.  Some modules also expose a named
	-- function; the registry keys cover modules without a public Stop alias.
	for _, name in ipairs({
		"StopVDAssistAnti3Unified",
		"StopFixedVDAssist",
		"StopVDAssist",
		"StopVDInteractionStateMonitor",
	}) do
		local callback = rawget(_G, name)
		if type(callback) == "function" then
			pcall(callback, reason)
		end
	end

	for _, key in ipairs({
		"__VD_SURVIVOR_HELPER_RUNTIME",
		"__VD_ASSIST_ANTI3GEN_UNIFIED_V2_2",
		"__VD_ZOMBIE_AURA_VISUAL_V2",
		"__VD_SKILL_CHECK_ONLY_V2",
		"__VD_ASSIST_LIGHTING_STABILIZER_V1_0",
		"__VD_KILLER_ABILITY_RADAR_V1",
		"__VD_INTERACTION_STATE_MONITOR_V1",
		"__VD_ASSIST_V9_6_AIM_INSPECTOR",
		"__VD_STANDALONE_PARRY_DAGGER_V1",
		"__VD_AUTO_INTERACTIONS_V1",
		"__VD_SKILL_CHECK_ONLY_V2",
	}) do
		callStop(rawget(_G, key), reason)
	end
end

local previous = rawget(_G, RUNTIME_KEY)
if type(previous) == "table" and type(previous.Stop) == "function" then
	pcall(previous.Stop, "replaced-by-new-loader")
end

local runtime = {
	Version = LOADER_VERSION,
	Build = BUILD_TAG,
	Running = true,
	BaseUrl = BASE_URL,
	Loaded = {},
	Errors = {},
	Stop = nil,
}
rawset(_G, RUNTIME_KEY, runtime)

runtime.Stop = function(reason: string?): ()
	if not runtime.Running then
		return
	end
	runtime.Running = false
	stopKnownModules(reason or "manual")
	if rawget(_G, RUNTIME_KEY) == runtime then
		rawset(_G, RUNTIME_KEY, nil)
	end
	if rawget(_G, "StopVDUnified") == runtime.Stop then
		rawset(_G, "StopVDUnified", nil)
	end
	print("[VD UNIFIED][STOP] reason=" .. tostring(reason or "manual"))
end

_G.StopVDUnified = runtime.Stop

local loadChunk = loadstring
if type(loadChunk) ~= "function" then
	error("VD Unified Loader requires executor loadstring support")
end

for _, fileName in ipairs(MODULES) do
	if not isCurrent(runtime) then
		break
	end
	local url = BASE_URL .. encodePath(fileName)
		.. "?vd_loader=" .. encodePath(LOADER_VERSION)
		.. "&vd_build=" .. encodePath(BUILD_TAG)
		.. "&vd_module=" .. encodePath(fileName)
	local ok, result, stale = pcall(function()
		local source = game:HttpGet(url)
		if not isCurrent(runtime) then
			return nil, true
		end
		local chunk, compileError = loadChunk(source, "@VD/" .. fileName)
		if type(chunk) ~= "function" then
			error(tostring(compileError or "loadstring returned no chunk"))
		end
		chunk()
		if not isCurrent(runtime) then
			return nil, true
		end
		return true, false
	end)
	if not isCurrent(runtime) or stale then
		break
	end
	if ok then
		table.insert(runtime.Loaded, fileName)
		print("[VD UNIFIED][LOAD] " .. fileName)
	else
		table.insert(runtime.Errors, {file = fileName, error = tostring(result)})
		warn("[VD UNIFIED][ERROR] " .. fileName .. " | " .. tostring(result))
	end
	-- Let each module finish its initial bindings before the next module starts.
	if not isCurrent(runtime) then
		break
	end
	task.wait()
end

if isCurrent(runtime) then
	print(string.format(
		"[VD UNIFIED][READY] v%s build=%s loaded=%d errors=%d | StopVDUnified() to stop",
		LOADER_VERSION,
		BUILD_TAG,
		#runtime.Loaded,
		#runtime.Errors
	))
end
