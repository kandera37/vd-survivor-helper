--!strict
--[[
VD AUTO v3.65 — LIVE-VALIDATED TIMER DELIVERY + ACTIVE-PAIR PINNING

Keeps:
  * automatic skill-check timing
  * F2 toggle
  * F3 stop

Removes/disables:
  * automatic pallet
  * automatic dodge
  * zombie/exit movement
  * flashlight/pistol aim
  * camera and character rotation writes
  * movement/velocity writes
  * per-frame and per-action log spam

The flashlight is left entirely to the game's native LocalScript.
]]

---------------------------------------------------------------------
-- Services
---------------------------------------------------------------------

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
if not player then
	return
end

---------------------------------------------------------------------
-- Replace only an older VD AUTO instance
---------------------------------------------------------------------

local OLD_AUTO_KEY = "__VD_AUTO_INTERACTIONS_V1"
local SKILL_ONLY_KEY = "__VD_SKILL_CHECK_ONLY_V2"

local function stopOldAuto(): ()
	local old = rawget(_G, OLD_AUTO_KEY)
	if type(old) == "table"
		and type((old :: any).Stop) == "function" then
		pcall((old :: any).Stop)
	end
	if rawget(_G, OLD_AUTO_KEY) == old then
		_G[OLD_AUTO_KEY] = nil
	end
end

stopOldAuto()

---------------------------------------------------------------------
-- Singleton
---------------------------------------------------------------------

local previous = rawget(_G, SKILL_ONLY_KEY)
if type(previous) == "table"
	and type((previous :: any).Stop) == "function" then
	pcall((previous :: any).Stop)
end

---------------------------------------------------------------------
-- Configuration
---------------------------------------------------------------------

local CONFIG = {
	skillEnabled = true,

	-- Aim near the middle of the successful zone. v3.43 presses from the
	-- measured angle; the selected Check must also be actually visible through
	-- its full GuiObject/ScreenGui ancestor chain.
	skillTargetOffset = 109.25,
	skillPredictionLead = 0.0005,
	skillPredictionMaximum = 0.0060,
	-- Sample late in RenderStep, then aim at where the marker will be roughly half
	-- a real rendered frame later. The cap below is angular as well as temporal,
	-- so a 2600 deg/s check cannot recreate the old 10-34ms early press.
	-- VIM input is issued after the game's render-side marker update but may not be
	-- consumed by the repair LocalScript until the following engine input step.
	-- The fresh trace reached 700-870 deg/s while the old 1.75-degree lead often
	-- sent the edge less than 2 ms before center. Lead by one bounded high-FPS
	-- frame, never by the old unsafe 6-30 degrees.
	skillPredictionFrameFraction = 0.85,
	skillWindowDegrees = 0.90,
	skillPredictionWindowDegrees = 0.80,
	-- Normal-speed checks are sampled frequently enough to wait for the measured
	-- center. In the supplied failure v3.61 pressed at 107.72 (1.53 degrees early)
	-- solely because prediction guessed 109.29. Keep prediction inside the real
	-- acceptance band instead of trusting a future GUI position.
	skillPredictionArmingDegrees = 0.95,
	skillPredictionMaximumLeadDegrees = 0.85,
	skillFastAngularSpeed = 600.0,
	-- Very fast checks may skip the measured window between rendered samples, so
	-- retain a bounded lead there, but never the old four-degree advance.
	skillFastPredictionArmingDegrees = 2.50,
	skillFastPredictionMaximumLeadDegrees = 2.00,
	skillEmergencyWindowDegrees = 0.90,
	-- A short frame hitch can advance the Line by 10-25 degrees. The old
	-- 10-degree cap silently lost the whole check even when two consecutive
	-- samples unambiguously straddled the center. This rescue fires only after
	-- crossing, so it cannot recreate the old early-press failure.
	-- Crossing is a last-frame fallback, not permission to click well after the
	-- center. cycle=25 clicked at 110.42 (1.17 degrees late) and could not recover.
	-- A rendered frame can jump completely across the narrow 0.90-degree center
	-- window. v3.63 detected that crossing but then required the new frame to
	-- still be within 0.95 degrees, making the rescue effectively useless. Accept
	-- only the measured overshoot of a bounded, continuous crossing. The normal
	-- cap covers ordinary frame spacing; the wider cap is reserved for a marker
	-- whose measured speed is already in the fast tier.
	skillCrossingAcceptanceDegrees = 0.95,
	skillCrossingLateRescueDegrees = 6.0,
	skillFastCrossingLateRescueDegrees = 9.0,
	skillCrossingMaximumStep = 32.0,
	skillCrossingMaximumDt = 0.075,
	skillMinAngularSpeed = 2.0,
	-- A one-frame GUI replacement produced an impossible 5779 deg/s sample and
	-- v3.48 treated it as a valid crossing. Reject discontinuities before they
	-- can arm prediction/crossing, then estimate speed from a short median window.
	-- A speed-only boundary is invalid at high FPS: the supplied trace contains a
	-- real-looking +2611 deg/s sample whose actual 2.07ms step is only 5.4 degrees.
	-- Judge replacement/reset discontinuities primarily by the angular step. This
	-- admits fast continuous markers while rejecting the 38-170 degree GUI jumps.
	skillMaximumPlausibleAngularSpeed = 12000.0,
	skillDiscontinuityMaximumStepDegrees = 32.0,
	-- The trace contained a 51.54 ms render gap. Keep a bounded 75 ms sample when
	-- its angular step itself is still plausible so near-center crossing recovery
	-- remains available; large GUI replacement jumps are still rejected by step.
	skillEstimatorMaximumDt = 0.075,
	-- A long pause/down/respawn is a lifecycle boundary, not an angular sample.
	-- Never feed a multi-second gap into the crossing estimator.
	skillLifecycleGapReset = 0.250,
	-- Three samples adapt to a genuine speed-up without trusting one noisy frame.
	skillAngularMedianWindow = 3,
	skillDiscontinuityLogCooldown = 0.35,
	-- The game can reuse one visible Check while replacing/resetting Line and Goal
	-- for the next real check. Two impossible samples inside one nominal cycle are
	-- therefore a GUI lifecycle boundary, not merely estimator noise.
	skillDiscontinuityCycleResetCount = 2,
	skillDiscontinuityCycleResetMinimumAge = 0.10,
	-- Only consecutive discontinuities from one GUI rebuild may reset a cycle.
	-- Two unrelated noisy samples separated by normal motion must not accumulate.
	skillDiscontinuityCycleResetWindow = 0.20,
	-- A reset of this size is a new GUI lifecycle, not plausible marker travel.
	-- Rearm immediately even when the preceding check was missed, otherwise all
	-- later checks remain trapped in the same unfired cycle (cycle=8 in the log).
	skillHardLifecycleResetStepDegrees = 60.0,

	-- A skill check may spawn already close to the hit window. Waiting 35 ms was
	-- enough to miss one complete check on a stalled/low-FPS frame.
	skillVisibleWarmup = 0.0,
	skillChainWarmup = 0.0,
	skillPressCooldown = 0.050,
	skillCycleGoalJump = 18.0,
	skillCycleDeltaJump = 14.0,
	skillCycleLineFollowTolerance = 10.0,
	skillCycleLineReset = 38.0,
	skillCycleMinGap = 0.028,

	-- The live Line/Goal can flicker invisible or be rebuilt for a few frames.
	-- v3.42 treated the first missing frame as the end of the whole check, then
	-- reacquired after the target had already passed. Keep the current cycle
	-- alive while the Check container itself is still present.
	skillPairLossGrace = 0.280,
	skillGhostSampleGrace = 0.100,
	skillCheckCloseGrace = 0.180,

	-- A removed/template pair can remain visible with both rotations frozen at
	-- zero. Never treat such a GUI as a live check for minutes.
	skillMotionArmAngularSpeed = 12.0,
	skillStaticRejectDelay = 0.75,
	skillCycleMaximumDuration = 8.0,
	skillDormantWakeDelta = 0.35,
	-- A cached 0/0 template can remain visible while a second live Line/Goal pair
	-- is inserted into the same Check. Re-score that small container at a bounded
	-- rate while dormant instead of pinning the first valid pair forever.
	skillDormantReacquireInterval = 0.12,
	-- While a pair has not demonstrated continuous motion, briefly inspect only
	-- the small Check container. A newly inserted live Line must beat a visible
	-- frozen template even when both objects have identical size/ZIndex.
	skillUncertainPairProbeInterval = 0.035,
	skillUncertainPairProbeDuration = 0.45,
	skillPairMotionEpsilonDegrees = 0.04,
	skillPairMotionFreshness = 0.12,
	-- Rotation-change callbacks identify a newly moving alternative Line without
	-- rescanning PlayerGui or continuously walking the active Check every frame.
	skillAlternativeLineProbeInterval = 0.035,
	-- Inactive/template Check candidates are inspected at a bounded rate. The
	-- active pair still uses the event-driven pinning path above, while a
	-- candidate that has no complete pair cannot trigger a GetDescendants walk
	-- on every RenderStep.
	skillCandidateInspectInterval = 0.12,
	-- Do not let a newly inserted/template Line steal an already moving cycle.
	-- A teammate joining the repair can rebuild the small GUI hierarchy; the live
	-- pair stays authoritative while it has moved recently.
	skillActivePairPinFreshness = 0.18,

	-- v3.52 held Space for 80ms and sent three identical non-repeat key-downs.
	-- Those calls were not three input transitions, and a game that samples the
	-- release could evaluate it many degrees after the logged center. Keep the key
	-- across several high-FPS frames, mark reassertions as repeat events, then send
	-- one prompt key-up close to the measured center.
	-- InputBegan is the actionable edge. Bound key-up by angular travel instead
	-- of a fixed 16ms: at 1380 deg/s that old hold released 22 degrees late.
	-- One down edge is sufficient; repeated key-down events can be interpreted as
	-- separate or delayed input by different executor/game combinations.
	-- A 1.5-6 ms down/up pair can fit entirely between two engine input polls.
	-- Keep Space down across at least one Heartbeat and for at least 20 ms. Roblox
	-- key-repeat is far slower, so this is still one logical press.
	spaceHoldMinimum = 0.020,
	spaceHoldMaximum = 0.032,
	spaceHoldMaximumTravelDegrees = 12.0,
	skillInputMinimumHeartbeatFrames = 1,
	skillInputAuditDelay = 0.080,
	skillInputAuditPastCenterDegrees = 10.0,
	-- Render samples cannot observe a narrow target that a very fast marker crosses
	-- entirely between two frames. Once multiple samples establish stable motion,
	-- schedule the single Space edge for the interpolated center time instead of
	-- waiting for the next rendered position. The token is replaced by every newer
	-- sample and cancelled on every GUI lifecycle change.
	skillInterpolatedMinimumAngularSpeed = 420.0,
	skillInterpolatedMinimumSamples = 2,
	skillInterpolatedMinimumDelay = 0.0012,
	skillInterpolatedMaximumDelay = 0.036,
	skillInterpolatedFrameMultiplier = 1.45,
	skillInterpolatedMaximumArmingDegrees = 52.0,
	-- The supplied fast cycle woke 4.65 ms after task.delay's requested deadline,
	-- which is roughly 4.35 degrees at 935 deg/s. Aim a bounded 3.2 ms early;
	-- an on-time callback remains inside the center band, while ordinary scheduler
	-- jitter lands much closer to the measured center instead of beyond it.
	skillInterpolatedInputLead = 0.0032,
	-- task.delay can wake several milliseconds late. Never equate the requested
	-- timer deadline with the marker's live position; validate Line/Goal again in
	-- the callback before delivering Space.
	skillInterpolatedLateTolerance = 0.025,
	skillInterpolatedSampleFreshness = 0.080,
	skillInterpolatedLiveCenterDegrees = 3.50,
	skillInterpolatedLiveLateRescueDegrees = 4.0,
	skillInterpolatedFastLiveLateRescueDegrees = 6.5,
	renderBindingName = "VD_AUTO_SKILL_CHECK_V365_TIMER_DELIVERY_AUDIT",
	renderPriority = Enum.RenderPriority.Last.Value + 20,

	-- Silent means no SKILL_PRESS/SKILL_CHAIN spam.
	debug = false,
	logPresses = true,
	logMisses = true,

}

type Runtime = {
	running: boolean,
	connections: {RBXScriptConnection},
	virtualInput: any,
	inputAvailable: boolean,
	warnedNoInput: boolean,
	renderBound: boolean,

	skillVisible: boolean,
	skillVisibleSince: number,
	skillWarmup: number,
	skillFired: boolean,
	skillCycle: number,
	skillCycleStartedAt: number,
	skillCheckObject: GuiObject?,
	lastGoalRotation: number?,
	lastLineRotation: number?,
	lastSkillDelta: number?,
	lastSkillSampleAt: number?,
	lastPredictedDelta: number?,
	lastCurrentError: number?,
	lastPredictedError: number?,
	lastAngularSpeed: number,
	skillAngularSamples: {number},
	skillRejectedSamples: number,
	lastRejectedSampleAt: number,
	lastDiscontinuityLogAt: number,
	skillMotionObserved: boolean,
	skillDormantStatic: boolean,
	dormantLineRotation: number?,
	dormantGoalRotation: number?,
	lastDormantReacquireAt: number,
	lastActivePairProbeAt: number,
	forcePairProbeUntil: number,
	lastMeaningfulMotionAt: number,
	lastInputFailure: string,
	lastSkillPressAt: number,
	skillSampleCount: number,
	activeCheckPath: string,
	activeLineObject: GuiObject?,
	activeGoalObject: GuiObject?,
	lastValidPairAt: number,
	pairMissingSince: number?,
	checkMissingSince: number?,
	pairSwitches: number,
	cachedCheck: GuiObject?,
	cachedLine: GuiObject?,
	cachedGoal: GuiObject?,
	playerGui: PlayerGui?,
	skillCandidates: {[GuiObject]: boolean},
	pairMotionRotation: {[GuiObject]: number},
	pairMotionSampleAt: {[GuiObject]: number},
	pairLastMovedAt: {[GuiObject]: number},
	pairMotionStreak: {[GuiObject]: number},
	lineMotionConnections: {[GuiObject]: RBXScriptConnection},
	pairMotionDirtyLine: GuiObject?,
	lastAlternativeLineProbeAt: number,
	checkInspectAt: {[GuiObject]: number},
	checkInspectedLine: {[GuiObject]: GuiObject?},
	checkInspectedGoal: {[GuiObject]: GuiObject?},
	discoveryConnections: {RBXScriptConnection},
	lifecycleDowned: boolean,

	syntheticSpaceDown: boolean,
	syntheticReleaseToken: number,
	lastSyntheticHoldDuration: number,
	skillInputAuditLogged: boolean,
	skillScheduledToken: number,
	skillScheduledAt: number,

	Stop: (() -> ())?,
}

local runtime: Runtime = {
	running = true,
	connections = {},
	virtualInput = nil,
	inputAvailable = false,
	warnedNoInput = false,
	renderBound = false,

	skillVisible = false,
	skillVisibleSince = 0,
	skillWarmup = 0,
	skillFired = false,
	skillCycle = 0,
	skillCycleStartedAt = -math.huge,
	skillCheckObject = nil,
	lastGoalRotation = nil,
	lastLineRotation = nil,
	lastSkillDelta = nil,
	lastSkillSampleAt = nil,
	lastPredictedDelta = nil,
	lastCurrentError = nil,
	lastPredictedError = nil,
	lastAngularSpeed = 0.0,
	skillAngularSamples = {},
	skillRejectedSamples = 0,
	lastRejectedSampleAt = -math.huge,
	lastDiscontinuityLogAt = -math.huge,
	skillMotionObserved = false,
	skillDormantStatic = false,
	dormantLineRotation = nil,
	dormantGoalRotation = nil,
	lastDormantReacquireAt = -math.huge,
	lastActivePairProbeAt = -math.huge,
	forcePairProbeUntil = -math.huge,
	lastMeaningfulMotionAt = -math.huge,
	lastInputFailure = "none",
	lastSkillPressAt = -math.huge,
	skillSampleCount = 0,
	activeCheckPath = "none",
	activeLineObject = nil,
	activeGoalObject = nil,
	lastValidPairAt = -math.huge,
	pairMissingSince = nil,
	checkMissingSince = nil,
	pairSwitches = 0,
	cachedCheck = nil,
	cachedLine = nil,
	cachedGoal = nil,
	playerGui = nil,
	skillCandidates = {},
	pairMotionRotation = {},
	pairMotionSampleAt = {},
	pairLastMovedAt = {},
	pairMotionStreak = {},
	lineMotionConnections = {},
	pairMotionDirtyLine = nil,
	lastAlternativeLineProbeAt = -math.huge,
	checkInspectAt = {},
	checkInspectedLine = {},
	checkInspectedGoal = {},
	discoveryConnections = {},
	lifecycleDowned = false,

	syntheticSpaceDown = false,
	syntheticReleaseToken = 0,
	lastSyntheticHoldDuration = 0.0,
	skillInputAuditLogged = false,
	skillScheduledToken = 0,
	skillScheduledAt = -math.huge,

	Stop = nil,
}

_G[SKILL_ONLY_KEY] = runtime

---------------------------------------------------------------------
-- Utilities
---------------------------------------------------------------------

local function now(): number
	return os.clock()
end

local function debugLog(message: string): ()
	if CONFIG.debug then
		print("[VD AUTO v3.65] " .. message)
	end
end

local function addConnection(connection: RBXScriptConnection): ()
	table.insert(runtime.connections, connection)
end

local function disconnectAll(): ()
	for _, connection in ipairs(runtime.connections) do
		pcall(function()
			connection:Disconnect()
		end)
	end
	table.clear(runtime.connections)
end

local function normalizeAngle(angle: number): number
	return ((angle % 360) + 360) % 360
end

local function signedAngleDifference(
	fromAngle: number,
	toAngle: number
): number
	return ((toAngle - fromAngle + 180) % 360) - 180
end

local function circularDistance(a: number, b: number): number
	return math.abs(signedAngleDifference(a, b))
end

local function median(values: {number}): number
	local count = #values
	if count == 0 then
		return 0.0
	end
	local sorted = table.clone(values)
	table.sort(sorted)
	local middle = math.floor((count + 1) * 0.5)
	if count % 2 == 1 then
		return sorted[middle]
	end
	return (sorted[middle] + sorted[middle + 1]) * 0.5
end

local function activeStatusValue(
	container: Instance?,
	name: string
): boolean
	if not container then
		return false
	end
	local value = container:GetAttribute(name)
	return value == true
		or (typeof(value) == "number" and value > 0)
end

local function localIsDowned(): boolean
	local character = player.Character
	if not character then
		return true
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return true
	end

	for _, container in ipairs({
		character,
		humanoid,
		player,
	}) do
		for _, attributeName in ipairs({
			"Knocked",
			"Downed",
			"IsDowned",
			"Dying",
			"Incapacitated",
			"Carried",
			"IsCarried",
			"BeingCarried",
			"IsBeingCarried",
			"Hooked",
			"IsHooked",
			"OnHook",
			"Hanging",
			"Captured",
			"Grabbed",
			"Held",
			"OnShoulder",
			"corpsecharge",
		}) do
			if activeStatusValue(container, attributeName) then
				return true
			end
		end
	end

	return humanoid.PlatformStand == true
end

---------------------------------------------------------------------
-- Skill-check discovery (event-driven; never scans PlayerGui per frame)
---------------------------------------------------------------------

local function effectivelyVisible(gui: GuiObject?): boolean
	local playerGui = runtime.playerGui
	if not gui or not playerGui or not gui:IsDescendantOf(playerGui) then
		return false
	end
	if not gui.Visible
		or gui.AbsoluteSize.X <= 1
		or gui.AbsoluteSize.Y <= 1 then
		return false
	end

	local camera = workspace.CurrentCamera
	if camera then
		local position = gui.AbsolutePosition
		local size = gui.AbsoluteSize
		local viewport = camera.ViewportSize
		if position.X + size.X <= 0
			or position.Y + size.Y <= 0
			or position.X >= viewport.X
			or position.Y >= viewport.Y then
			return false
		end
	end

	local current: Instance? = gui
	while current and current ~= playerGui do
		if current:IsA("GuiObject") then
			local guiObject = current :: GuiObject
			if not guiObject.Visible then
				return false
			end
			if guiObject:IsA("CanvasGroup") then
				local canvasGroup = guiObject :: CanvasGroup
				if canvasGroup.GroupTransparency >= 0.995 then
					return false
				end
			end
			-- A visible child outside a clipping Frame/ScrollingFrame is not
			-- rendered. Check the actual screen-space rectangles so a stale
			-- template cannot pass visibility merely because Visible=true.
			if guiObject.ClipsDescendants and guiObject ~= gui then
				local childPosition = gui.AbsolutePosition
				local childSize = gui.AbsoluteSize
				local parentPosition = guiObject.AbsolutePosition
				local parentSize = guiObject.AbsoluteSize
				local childRight = childPosition.X + childSize.X
				local childBottom = childPosition.Y + childSize.Y
				local parentRight = parentPosition.X + parentSize.X
				local parentBottom = parentPosition.Y + parentSize.Y
				if childRight <= parentPosition.X
					or childPosition.X >= parentRight
					or childBottom <= parentPosition.Y
					or childPosition.Y >= parentBottom then
					return false
				end
			end
		end
		if current:IsA("LayerCollector") and not current.Enabled then
			return false
		end
		current = current.Parent
	end
	return current == playerGui
end

local function validSkillTriple(
	check: Instance?,
	line: Instance?,
	goal: Instance?
): boolean
	return check ~= nil
		and line ~= nil
		and goal ~= nil
		and check:IsA("GuiObject")
		and line:IsA("GuiObject")
		and goal:IsA("GuiObject")
		and effectivelyVisible(check)
		and effectivelyVisible(line)
		and effectivelyVisible(goal)
end

local function structurallyValidSkillTriple(
	check: Instance?,
	line: Instance?,
	goal: Instance?
): boolean
	local playerGui = runtime.playerGui
	return playerGui ~= nil
		and check ~= nil
		and line ~= nil
		and goal ~= nil
		and check:IsA("GuiObject")
		and line:IsA("GuiObject")
		and goal:IsA("GuiObject")
		and check:IsDescendantOf(playerGui)
		and line:IsDescendantOf(check)
		and goal:IsDescendantOf(check)
end

local function normalizedGuiName(instance: Instance): string
	return string.gsub(string.lower(instance.Name), "[^%w]", "")
end

local function guiRoleMatches(instance: Instance, role: string): boolean
	local name = normalizedGuiName(instance)
	return name == role or string.sub(name, 1, #role) == role
end

local function belongsToSkillPrompt(instance: Instance?): boolean
	local current = instance
	while current and current ~= runtime.playerGui do
		local name = normalizedGuiName(current)
		if string.find(name, "skillcheck", 1, true)
			or string.find(name, "skillprompt", 1, true) then
			return true
		end
		current = current.Parent
	end
	return false
end

local function findCheckAncestor(instance: Instance?): GuiObject?
	local current = instance
	while current and current ~= runtime.playerGui do
		if current:IsA("GuiObject")
			and guiRoleMatches(current, "check")
			and belongsToSkillPrompt(current) then
			return current
		end
		current = current.Parent
	end
	return nil
end

local function addDiscoveryConnection(connection: RBXScriptConnection): ()
	table.insert(runtime.discoveryConnections, connection)
end

local function disconnectSkillDiscovery(): ()
	for _, connection in ipairs(runtime.discoveryConnections) do
		pcall(function()
			connection:Disconnect()
		end)
	end
	table.clear(runtime.discoveryConnections)
	for line, connection in pairs(runtime.lineMotionConnections) do
		pcall(function()
			connection:Disconnect()
		end)
		runtime.pairMotionRotation[line] = nil
		runtime.pairMotionSampleAt[line] = nil
		runtime.pairLastMovedAt[line] = nil
		runtime.pairMotionStreak[line] = nil
	end
	table.clear(runtime.lineMotionConnections)
	table.clear(runtime.skillCandidates)
	table.clear(runtime.checkInspectAt)
	table.clear(runtime.checkInspectedLine)
	table.clear(runtime.checkInspectedGoal)
	runtime.pairMotionDirtyLine = nil
	runtime.cachedCheck = nil
	runtime.cachedLine = nil
	runtime.cachedGoal = nil
	runtime.playerGui = nil
end

local function observeLineMotion(instance: Instance): ()
	if not instance:IsA("GuiObject")
		or not guiRoleMatches(instance, "line")
		or not findCheckAncestor(instance)
		or runtime.lineMotionConnections[instance] then
		return
	end
	local line = instance :: GuiObject
	runtime.pairMotionRotation[line] = normalizeAngle(line.Rotation)
	runtime.pairMotionSampleAt[line] = now()
	local connection = line:GetPropertyChangedSignal("Rotation"):Connect(function()
		if not runtime.running or not line.Parent then
			return
		end
		-- A queued callback from a replaced PlayerGui may run after its
		-- connection was disconnected. Do no work for that retired hierarchy.
		if not findCheckAncestor(line) then
			return
		end
		local sampleAt = now()
		local rotation = normalizeAngle(line.Rotation)
		local previousRotation = runtime.pairMotionRotation[line]
		local previousAt = runtime.pairMotionSampleAt[line]
		local plausibleMotion = false
		if previousRotation ~= nil and previousAt ~= nil then
			local dt = sampleAt - previousAt
			local step = circularDistance(previousRotation, rotation)
			plausibleMotion = dt > 0.0001
				and dt <= CONFIG.skillEstimatorMaximumDt
				and step >= CONFIG.skillPairMotionEpsilonDegrees
				and step <= CONFIG.skillDiscontinuityMaximumStepDegrees
		end
		if plausibleMotion then
			runtime.pairLastMovedAt[line] = sampleAt
			runtime.pairMotionStreak[line] = math.min(
				(runtime.pairMotionStreak[line] or 0) + 1,
				5
			)
			-- Do not switch on a single lifecycle teleport. Two consecutive bounded
			-- Rotation changes identify the actual moving marker even when it starts
			-- after the old 450 ms probing window has expired.
			if (runtime.pairMotionStreak[line] or 0) >= 2
				and line ~= runtime.cachedLine then
				runtime.pairMotionDirtyLine = line
				runtime.lastActivePairProbeAt = -math.huge
				local check = findCheckAncestor(line)
				if check and runtime.checkInspectedLine[check] ~= line then
					runtime.checkInspectAt[check] = -math.huge
				end
			end
		else
			runtime.pairMotionStreak[line] = 0
		end
		runtime.pairMotionRotation[line] = rotation
		runtime.pairMotionSampleAt[line] = sampleAt
	end)
	runtime.lineMotionConnections[line] = connection
end

local function registerSkillCandidate(instance: Instance): ()
	observeLineMotion(instance)
	local check = findCheckAncestor(instance)
	if check then
		runtime.skillCandidates[check] = true
		runtime.checkInspectAt[check] = -math.huge
	end
end

local function initializeSkillDiscovery(preferredGui: PlayerGui?): ()
	-- Rebinding is required when the game replaces PlayerGui after a respawn or
	-- when the first GUI appears after this script starts. Drop old callbacks and
	-- line observers before attaching to the new hierarchy.
	local playerGui = preferredGui or player:FindFirstChildOfClass("PlayerGui")
	if playerGui == runtime.playerGui then return end
	disconnectSkillDiscovery()
	if not playerGui then
		return
	end

	runtime.playerGui = playerGui

	-- One initial scan only. New UI objects are indexed through DescendantAdded;
	-- GetDescendants is never called from RenderStep.
	for _, object in ipairs(playerGui:GetDescendants()) do
		observeLineMotion(object)
		if object:IsA("GuiObject")
			and guiRoleMatches(object, "check")
			and belongsToSkillPrompt(object) then
			runtime.skillCandidates[object] = true
			runtime.checkInspectAt[object] = -math.huge
		end
	end

	addDiscoveryConnection(playerGui.DescendantAdded:Connect(function(instance)
		if not runtime.running or runtime.playerGui ~= playerGui then return end
		registerSkillCandidate(instance)
	end))

	addDiscoveryConnection(playerGui.DescendantRemoving:Connect(function(instance)
		if not runtime.running or runtime.playerGui ~= playerGui then return end
		if instance:IsA("GuiObject") then
			local line = instance :: GuiObject
			local lineConnection = runtime.lineMotionConnections[line]
			if lineConnection then
				lineConnection:Disconnect()
				runtime.lineMotionConnections[line] = nil
			end
			runtime.pairMotionRotation[line] = nil
			runtime.pairMotionSampleAt[line] = nil
			runtime.pairLastMovedAt[line] = nil
			runtime.pairMotionStreak[line] = nil
			if runtime.pairMotionDirtyLine == line then
				runtime.pairMotionDirtyLine = nil
			end
		end
		if instance == runtime.cachedCheck
			or instance == runtime.cachedLine
			or instance == runtime.cachedGoal then
			runtime.cachedCheck = nil
			runtime.cachedLine = nil
			runtime.cachedGoal = nil
		end
		if instance:IsA("GuiObject") and runtime.skillCandidates[instance] then
			runtime.skillCandidates[instance] = nil
			runtime.checkInspectAt[instance] = nil
			runtime.checkInspectedLine[instance] = nil
			runtime.checkInspectedGoal[instance] = nil
		end
	end))
end

local function cacheTriple(
	check: GuiObject,
	line: GuiObject,
	goal: GuiObject
): (GuiObject, GuiObject, GuiObject)
	runtime.cachedCheck = check
	runtime.cachedLine = line
	runtime.cachedGoal = goal
	runtime.skillCandidates[check] = true
	return check, line, goal
end

local function sharedAncestorDepth(
	check: GuiObject,
	first: GuiObject,
	second: GuiObject
): number
	local firstAncestors: {[Instance]: number} = {}
	local current: Instance? = first
	local depth = 0
	while current and current ~= check.Parent do
		firstAncestors[current] = depth
		if current == check then break end
		current = current.Parent
		depth += 1
	end

	current = second
	depth = 0
	while current and current ~= check.Parent do
		local firstDepth = firstAncestors[current]
		if firstDepth ~= nil then
			return 100 - firstDepth - depth
		end
		if current == check then break end
		current = current.Parent
		depth += 1
	end
	return 0
end

local function samplePairMotion(line: GuiObject, sampleAt: number): ()
	local rotation = normalizeAngle(line.Rotation)
	local previousRotation = runtime.pairMotionRotation[line]
	local previousAt = runtime.pairMotionSampleAt[line]
	local moving = false
	if previousRotation ~= nil and previousAt ~= nil then
		local dt = sampleAt - previousAt
		moving = dt > 0.0001
			and dt <= 0.25
			and circularDistance(previousRotation, rotation)
				>= CONFIG.skillPairMotionEpsilonDegrees
	end

	if moving then
		runtime.pairLastMovedAt[line] = sampleAt
		runtime.pairMotionStreak[line] = math.min(
			(runtime.pairMotionStreak[line] or 0) + 1,
			5
		)
	else
		runtime.pairMotionStreak[line] = 0
	end
	runtime.pairMotionRotation[line] = rotation
	runtime.pairMotionSampleAt[line] = sampleAt
end

local function activePairScore(
	check: GuiObject,
	line: GuiObject,
	goal: GuiObject,
	sampleAt: number
): number
	-- One Check can contain a visible live pair and visible-but-stale template
	-- children. FindFirstChild picked the first one and produced long cycles with
	-- omega=0 far from the target. Prefer a Line/Goal pair that shares the
	-- closest container, occupies real screen area and is rendered on top.
	local sameParentBonus = line.Parent == goal.Parent and 1000000 or 0
	local ancestryBonus = sharedAncestorDepth(check, line, goal) * 1000
	local area = line.AbsoluteSize.X * line.AbsoluteSize.Y
		+ goal.AbsoluteSize.X * goal.AbsoluteSize.Y
	local zBonus = (line.ZIndex + goal.ZIndex) * 10
	local cachedBonus = line == runtime.cachedLine and goal == runtime.cachedGoal
		and 25 or 0
	local movedAt = runtime.pairLastMovedAt[line] or -math.huge
	local motionFresh = sampleAt - movedAt <= CONFIG.skillPairMotionFreshness
	local motionBonus = motionFresh
		and (3000000 + (runtime.pairMotionStreak[line] or 0) * 100000)
		or 0
	local lineRotation = normalizeAngle(line.Rotation)
	local goalRotation = normalizeAngle(goal.Rotation)
	local frozenZeroTemplatePenalty = lineRotation <= 0.01
		and goalRotation <= 0.01
		and -2000000
		or 0
	return sameParentBonus + ancestryBonus + area + zBonus + cachedBonus
		+ frozenZeroTemplatePenalty + motionBonus
end

local function inspectCheck(check: GuiObject?): (
	GuiObject?,
	GuiObject?,
	GuiObject?
)
	local playerGui = runtime.playerGui
	if not check or not playerGui or not check:IsDescendantOf(playerGui) then
		if check then
			runtime.skillCandidates[check] = nil
			runtime.checkInspectAt[check] = nil
			runtime.checkInspectedLine[check] = nil
			runtime.checkInspectedGoal[check] = nil
		end
		return nil, nil, nil
	end
	if not effectivelyVisible(check) then
		runtime.checkInspectAt[check] = nil
		return nil, nil, nil
	end

	local sampleAt = now()
	local inspectInterval = check == runtime.cachedCheck
		and CONFIG.skillUncertainPairProbeInterval
		or CONFIG.skillCandidateInspectInterval
	if sampleAt - (runtime.checkInspectAt[check] or -math.huge) < inspectInterval then
		local inspectedLine = runtime.checkInspectedLine[check]
		local inspectedGoal = runtime.checkInspectedGoal[check]
		if inspectedLine and inspectedGoal
			and validSkillTriple(check, inspectedLine, inspectedGoal) then
			return check, inspectedLine, inspectedGoal
		end
		return nil, nil, nil
	end
	runtime.checkInspectAt[check] = sampleAt

	local lines: {GuiObject} = {}
	local goals: {GuiObject} = {}
	for _, descendant in ipairs(check:GetDescendants()) do
		if descendant:IsA("GuiObject") and effectivelyVisible(descendant) then
			if guiRoleMatches(descendant, "line") then
				lines[#lines + 1] = descendant
			elseif guiRoleMatches(descendant, "goal") then
				goals[#goals + 1] = descendant
			end
		end
	end
	for _, line in ipairs(lines) do
		samplePairMotion(line, sampleAt)
	end

	local bestLine: GuiObject? = nil
	local bestGoal: GuiObject? = nil
	local bestScore = -math.huge
	for _, line in ipairs(lines) do
		for _, goal in ipairs(goals) do
			if validSkillTriple(check, line, goal) then
				local score = activePairScore(check, line, goal, sampleAt)
				if score > bestScore then
					bestScore = score
					bestLine = line
					bestGoal = goal
				end
			end
		end
	end

	runtime.checkInspectedLine[check] = bestLine
	runtime.checkInspectedGoal[check] = bestGoal
	if bestLine and bestGoal then
		return check, bestLine, bestGoal
	end
	return nil, nil, nil
end

local function visibleCandidateScore(
	check: GuiObject,
	line: GuiObject,
	goal: GuiObject
): number
	-- Motion must dominate size and ZIndex: a large stale template can remain
	-- rendered beside a smaller live skill check. Bound appearance bonuses so
	-- they can never outweigh fresh motion evidence.
	local area = check.AbsoluteSize.X * check.AbsoluteSize.Y
	local lineArea = line.AbsoluteSize.X * line.AbsoluteSize.Y
	local goalArea = goal.AbsoluteSize.X * goal.AbsoluteSize.Y
	local cachedBonus = check == runtime.cachedCheck and 1000 or 0
	local zBonus = math.clamp((check.ZIndex + line.ZIndex + goal.ZIndex) * 0.01, 0, 100)
	local motionFresh = now() - (runtime.pairLastMovedAt[line] or -math.huge)
		<= CONFIG.skillPairMotionFreshness
	local motionBonus = motionFresh and 10000000 or 0
	local frozenZeroPenalty = normalizeAngle(line.Rotation) <= 0.01
		and normalizeAngle(goal.Rotation) <= 0.01 and -2000000 or 0
	return math.min(area + lineArea + goalArea, 100000)
		+ cachedBonus + zBonus + motionBonus + frozenZeroPenalty
end

local function findVisibleSkillCheck(): (
	GuiObject?,
	GuiObject?,
	GuiObject?
)
	local playerGui = runtime.playerGui
	if not playerGui then return nil, nil, nil end
	local eventMovingLine = runtime.pairMotionDirtyLine

	-- Pin the currently active pair while it is still genuinely rendered. The
	-- old code cleared cachedLine/cachedGoal every RenderStep, so a one-frame UI
	-- rebuild could close the cycle and reacquire it only after the target.
	if validSkillTriple(
		runtime.cachedCheck,
		runtime.cachedLine,
		runtime.cachedGoal
	) then
		local sampleAt = now()
		if runtime.skillVisible
			and not runtime.skillFired
			and runtime.skillMotionObserved
			and sampleAt - runtime.lastMeaningfulMotionAt
				<= CONFIG.skillActivePairPinFreshness then
			return runtime.cachedCheck, runtime.cachedLine, runtime.cachedGoal
		end
		local shouldProbeDormantAlternates = runtime.skillDormantStatic
			and sampleAt - runtime.lastDormantReacquireAt
				>= CONFIG.skillDormantReacquireInterval
		local uncertainPair = runtime.skillVisible
			and not runtime.skillFired
			and (
				not runtime.skillMotionObserved
				or sampleAt <= runtime.forcePairProbeUntil
			)
		local shouldProbeUncertainAlternates = uncertainPair
			and sampleAt - runtime.lastActivePairProbeAt
				>= CONFIG.skillUncertainPairProbeInterval
		local dirtyAlternative = eventMovingLine
		local shouldProbeMovingAlternative = dirtyAlternative ~= nil
			and dirtyAlternative ~= runtime.cachedLine
			and sampleAt - runtime.lastAlternativeLineProbeAt
				>= CONFIG.skillAlternativeLineProbeInterval
		if not shouldProbeDormantAlternates
			and not shouldProbeUncertainAlternates
			and not shouldProbeMovingAlternative then
			return runtime.cachedCheck, runtime.cachedLine, runtime.cachedGoal
		end
		if shouldProbeDormantAlternates then
			runtime.lastDormantReacquireAt = sampleAt
		end
		if shouldProbeUncertainAlternates then
			runtime.lastActivePairProbeAt = sampleAt
		end
		if shouldProbeMovingAlternative then
			runtime.lastAlternativeLineProbeAt = sampleAt
			runtime.pairMotionDirtyLine = nil
		end
	end

	-- Rebuild the current small Check first, then compare the indexed candidates.
	-- Returning it immediately would hide a moving Check behind a cached template.
	if runtime.cachedCheck and effectivelyVisible(runtime.cachedCheck) then
		local oldLine = runtime.cachedLine
		local oldGoal = runtime.cachedGoal
		local check, line, goal = inspectCheck(runtime.cachedCheck)
		if check and line and goal then
			if (line ~= oldLine or goal ~= oldGoal)
				and runtime.skillVisible
				and not runtime.skillFired then
				warn(string.format(
					"[VD AUTO v3.65][SKILL_LIVE_PAIR_RECOVERED] cycle=%d oldLine=%s oldGoal=%s newLine=%s newGoal=%s action=switch-to-event-confirmed-moving-pair",
					runtime.skillCycle,
					oldLine and oldLine:GetFullName() or "none",
					oldGoal and oldGoal:GetFullName() or "none",
					line:GetFullName(),
					goal:GetFullName()
				))
			end
		end
	end

	local bestCheck: GuiObject? = nil
	local bestLine: GuiObject? = nil
	local bestGoal: GuiObject? = nil
	local bestScore = -math.huge

	for check in pairs(runtime.skillCandidates) do
		local foundCheck, line, goal = inspectCheck(check)
		if foundCheck and line and goal then
			local score = visibleCandidateScore(foundCheck, line, goal)
			if score > bestScore then
				bestScore = score
				bestCheck = foundCheck
				bestLine = line
				bestGoal = goal
			end
		end
	end

	if bestCheck and bestLine and bestGoal then
		if runtime.skillDormantStatic
			and (bestLine ~= runtime.cachedLine
				or bestGoal ~= runtime.cachedGoal) then
			warn(string.format(
				"[VD AUTO v3.65][SKILL_DORMANT_PAIR_REACQUIRED] cycle=%d oldLine=%s oldGoal=%s newLine=%s newGoal=%s action=resume-live-pair",
				runtime.skillCycle,
				runtime.cachedLine and runtime.cachedLine:GetFullName() or "none",
				runtime.cachedGoal and runtime.cachedGoal:GetFullName() or "none",
				bestLine:GetFullName(),
				bestGoal:GetFullName()
			))
		end
		return cacheTriple(bestCheck, bestLine, bestGoal)
	end
	return nil, nil, nil
end

---------------------------------------------------------------------
-- Normal Space input
---------------------------------------------------------------------

local function initializeVirtualInput(): ()
	local ok, service = pcall(function()
		return game:GetService("VirtualInputManager")
	end)

	if ok and service then
		runtime.virtualInput = service
		runtime.inputAvailable = true
	end
end

local function releaseSyntheticSpace(): ()
	if not runtime.syntheticSpaceDown
		or not runtime.virtualInput then
		return
	end

	pcall(function()
		runtime.virtualInput:SendKeyEvent(
			false,
			Enum.KeyCode.Space,
			false,
			game
		)
	end)
	runtime.syntheticSpaceDown = false
end

local function sendSpace(angularSpeed: number?): boolean
	if not runtime.running then
		runtime.lastInputFailure = "stopped"
		return false
	end
	if UserInputService:GetFocusedTextBox() then
		runtime.lastInputFailure = "textbox-focused"
		return false
	end
	if UserInputService:IsKeyDown(Enum.KeyCode.Space) then
		runtime.lastInputFailure = "physical-space-held"
		return false
	end

	-- Optional adapter used by some Studio harnesses.
	local externalAdapter = rawget(_G, "VDAutoPressSpace")
	if type(externalAdapter) == "function" then
		local ok = pcall(externalAdapter, "skill_check")
		if ok then
			runtime.lastSyntheticHoldDuration = 0.0
			runtime.lastInputFailure = "none"
			return true
		end
	end

	if not runtime.inputAvailable or not runtime.virtualInput then
		if not runtime.warnedNoInput then
			runtime.warnedNoInput = true
			warn(
					"[VD AUTO v3.65] VirtualInputManager unavailable; "
				.. "use a LocalScript in Studio play-test or provide "
				.. "_G.VDAutoPressSpace."
			)
		end
		runtime.lastInputFailure = "virtual-input-unavailable"
		return false
	end

	if runtime.syntheticSpaceDown then
		releaseSyntheticSpace()
	end

	local ok = pcall(function()
		runtime.virtualInput:SendKeyEvent(
			true,
			Enum.KeyCode.Space,
			false,
			game
		)
		runtime.syntheticSpaceDown = true
	end)
	if not ok then
		runtime.lastInputFailure = "send-key-down-failed"
		return false
	end
	runtime.lastInputFailure = "none"
	local speed = math.abs(angularSpeed or 0.0)
	local holdDuration = if speed >= CONFIG.skillMinAngularSpeed
		then math.clamp(
			CONFIG.spaceHoldMaximumTravelDegrees / speed,
			CONFIG.spaceHoldMinimum,
			CONFIG.spaceHoldMaximum
		)
		else CONFIG.spaceHoldMaximum
	runtime.lastSyntheticHoldDuration = holdDuration

	runtime.syntheticReleaseToken += 1
	local token = runtime.syntheticReleaseToken
	task.spawn(function()
		local startedAt = now()
		local heartbeatFrames = 0
		repeat
			RunService.Heartbeat:Wait()
			heartbeatFrames += 1
		until not runtime.running
			or token ~= runtime.syntheticReleaseToken
			or (
				heartbeatFrames >= CONFIG.skillInputMinimumHeartbeatFrames
				and now() - startedAt >= holdDuration
			)
		-- A stopped/replaced instance releases synchronously in stop(); a newer
		-- generation owns its own key pulse and must not be released by this task.
		if runtime.running
			and token == runtime.syntheticReleaseToken then
			releaseSyntheticSpace()
		end
	end)

	return true
end

---------------------------------------------------------------------
-- Skill-check state machine
---------------------------------------------------------------------

local function beginSkillCycle(
	check: GuiObject,
	line: GuiObject,
	goal: GuiObject,
	sampleAt: number,
	warmup: number
): ()
	runtime.skillVisible = true
	runtime.skillVisibleSince = sampleAt
	runtime.skillWarmup = warmup
	runtime.skillFired = false
	runtime.skillInputAuditLogged = false
	runtime.skillScheduledToken += 1
	runtime.skillScheduledAt = -math.huge
	runtime.skillCycle += 1
	runtime.skillCycleStartedAt = sampleAt
	runtime.skillCheckObject = check
	runtime.activeLineObject = line
	runtime.activeGoalObject = goal
	runtime.lastValidPairAt = sampleAt
	runtime.pairMissingSince = nil
	runtime.checkMissingSince = nil
	runtime.pairSwitches = 0
	runtime.lastGoalRotation = normalizeAngle(goal.Rotation)
	runtime.lastLineRotation = normalizeAngle(line.Rotation)
	runtime.lastSkillDelta = nil
	runtime.lastSkillSampleAt = nil
	runtime.lastPredictedDelta = nil
	runtime.lastCurrentError = nil
	runtime.lastPredictedError = nil
	runtime.lastAngularSpeed = 0.0
	table.clear(runtime.skillAngularSamples)
	runtime.skillRejectedSamples = 0
	runtime.lastRejectedSampleAt = -math.huge
	runtime.skillMotionObserved = false
	runtime.skillDormantStatic = false
	runtime.dormantLineRotation = nil
	runtime.dormantGoalRotation = nil
	runtime.lastActivePairProbeAt = -math.huge
	runtime.forcePairProbeUntil = sampleAt
		+ CONFIG.skillUncertainPairProbeDuration
	runtime.lastMeaningfulMotionAt = -math.huge
	runtime.skillSampleCount = 0
	runtime.activeCheckPath = check:GetFullName()
end

local function resetSkillState(): ()
	runtime.skillVisible = false
	runtime.skillFired = false
	runtime.skillInputAuditLogged = false
	runtime.skillScheduledToken += 1
	runtime.skillScheduledAt = -math.huge
	runtime.skillCheckObject = nil
	runtime.activeLineObject = nil
	runtime.activeGoalObject = nil
	runtime.lastValidPairAt = -math.huge
	runtime.pairMissingSince = nil
	runtime.checkMissingSince = nil
	runtime.pairSwitches = 0
	runtime.lastGoalRotation = nil
	runtime.lastLineRotation = nil
	runtime.lastSkillDelta = nil
	runtime.lastSkillSampleAt = nil
	runtime.lastPredictedDelta = nil
	runtime.lastCurrentError = nil
	runtime.lastPredictedError = nil
	runtime.lastAngularSpeed = 0.0
	table.clear(runtime.skillAngularSamples)
	runtime.skillRejectedSamples = 0
	runtime.lastRejectedSampleAt = -math.huge
	runtime.skillMotionObserved = false
	runtime.skillDormantStatic = false
	runtime.dormantLineRotation = nil
	runtime.dormantGoalRotation = nil
	runtime.lastActivePairProbeAt = -math.huge
	runtime.forcePairProbeUntil = -math.huge
	runtime.lastMeaningfulMotionAt = -math.huge
	runtime.skillSampleCount = 0
	runtime.activeCheckPath = "none"
end

local function updateSkillCheck(): ()
	-- F2 OFF is a true zero-work mode: no GUI lookup and no per-frame state work.
	if not CONFIG.skillEnabled then
		if runtime.skillVisible then resetSkillState() end
		return
	end
	local downed = localIsDowned()
	if downed then
		if not runtime.lifecycleDowned then
			runtime.lifecycleDowned = true
			releaseSyntheticSpace()
			resetSkillState()
			warn("[VD AUTO v3.65][SKILL_LIFECYCLE_RESET] reason=downed action=discard-old-cycle")
		end
		return
	elseif runtime.lifecycleDowned then
		runtime.lifecycleDowned = false
		resetSkillState()
		warn("[VD AUTO v3.65][SKILL_LIFECYCLE_RESET] reason=control-restored action=fresh-cycle")
	end

	local check, line, goal = findVisibleSkillCheck()
	local sampleAt = now()
	local structuralGhost = false

	if not check or not line or not goal then
		-- Preserve a short lifecycle grace across GUI reconstruction, but never
		-- deliver a new synthetic input using a hidden/stale GUI sample. A key
		-- pulse already delivered keeps its normal minimum hold duration.
		runtime.skillScheduledToken += 1
		if runtime.skillVisible then
			local activeCheck = runtime.skillCheckObject
			local checkStillVisible = activeCheck ~= nil
				and effectivelyVisible(activeCheck)

			if checkStillVisible then
				runtime.checkMissingSince = nil
				if runtime.pairMissingSince == nil then
					runtime.pairMissingSince = sampleAt
				end

				local activeLine = runtime.activeLineObject
				local activeGoal = runtime.activeGoalObject
				if structurallyValidSkillTriple(activeCheck, activeLine, activeGoal)
					and sampleAt - runtime.lastValidPairAt
						<= CONFIG.skillGhostSampleGrace then
					check = activeCheck :: GuiObject
					line = activeLine :: GuiObject
					goal = activeGoal :: GuiObject
					structuralGhost = true
				elseif sampleAt - (runtime.pairMissingSince or sampleAt)
					<= CONFIG.skillPairLossGrace then
					return
				else
					resetSkillState()
					return
				end
			else
				if runtime.checkMissingSince == nil then
					runtime.checkMissingSince = sampleAt
				end
				local activeLine = runtime.activeLineObject
				local activeGoal = runtime.activeGoalObject
				if structurallyValidSkillTriple(activeCheck, activeLine, activeGoal)
					and sampleAt - runtime.lastValidPairAt
						<= (CONFIG.skillPairLossGrace + CONFIG.skillCheckCloseGrace) then
					check = activeCheck :: GuiObject
					line = activeLine :: GuiObject
					goal = activeGoal :: GuiObject
					structuralGhost = true
				else
					if runtime.checkMissingSince == nil then
						runtime.checkMissingSince = sampleAt
					end
					if sampleAt - (runtime.checkMissingSince or sampleAt)
						<= CONFIG.skillCheckCloseGrace then
						return
					end

					if CONFIG.logMisses
						and not runtime.skillFired
						and (
							runtime.skillMotionObserved
							or runtime.skillRejectedSamples > 0
						) then
						warn(string.format(
							"[VD AUTO v3.65][SKILL_CLOSED_WITHOUT_PRESS] cycle=%d samples=%d check=%s line=%s goal=%s pairSwitches=%d currentError=%s predictedError=%s omega=%+.1f inputFailure=%s dormant=%s rejected=%d",
							runtime.skillCycle,
							runtime.skillSampleCount,
							runtime.activeCheckPath,
							runtime.activeLineObject and runtime.activeLineObject:GetFullName() or "none",
							runtime.activeGoalObject and runtime.activeGoalObject:GetFullName() or "none",
							runtime.pairSwitches,
							runtime.lastCurrentError and string.format("%.2f", runtime.lastCurrentError) or "n/a",
							runtime.lastPredictedError and string.format("%.2f", runtime.lastPredictedError) or "n/a",
							runtime.lastAngularSpeed,
							runtime.lastInputFailure,
							tostring(runtime.skillDormantStatic),
							runtime.skillRejectedSamples
						))
					end
					resetSkillState()
					return
				end
			end
		else
			return
		end
	end

	-- A structural ghost only preserves cycle identity. It must not renew its
	-- own grace timestamp or reach the normal/timed Space delivery paths.
	if not validSkillTriple(check, line, goal) then
		return
	end
	if structuralGhost then
		-- Preserve the current cycle while Roblox rebuilds the GUI, but do not
		-- refresh its validity timestamp or run angle/Space logic from a hidden
		-- pair. A genuinely rendered pair must be observed before input resumes.
		return
	end

	-- Only a genuinely rendered pair clears the loss timers.
	runtime.lastValidPairAt = sampleAt
	runtime.pairMissingSince = nil
	runtime.checkMissingSince = nil

	local currentGoal = normalizeAngle(goal.Rotation)
	local currentLine = normalizeAngle(line.Rotation)
	local pairChanged = runtime.skillVisible
		and (runtime.activeLineObject ~= line
			or runtime.activeGoalObject ~= goal)

	if pairChanged and not runtime.skillFired then
		runtime.pairSwitches += 1
		runtime.activeLineObject = line
		runtime.activeGoalObject = goal
		runtime.lastGoalRotation = currentGoal
		runtime.lastLineRotation = currentLine
		runtime.lastSkillDelta = nil
		runtime.lastSkillSampleAt = nil
		runtime.lastCurrentError = nil
		runtime.lastPredictedError = nil
		runtime.lastAngularSpeed = 0.0
		table.clear(runtime.skillAngularSamples)
		runtime.skillMotionObserved = false
		runtime.skillDormantStatic = false
		runtime.dormantLineRotation = nil
		runtime.dormantGoalRotation = nil
		runtime.lastMeaningfulMotionAt = -math.huge
		runtime.forcePairProbeUntil = sampleAt
			+ CONFIG.skillUncertainPairProbeDuration
	end

	if not runtime.skillVisible then
		beginSkillCycle(
			check,
			line,
			goal,
			sampleAt,
			CONFIG.skillVisibleWarmup
		)
	else
		local checkChanged =
			runtime.skillCheckObject ~= check
		local goalJump =
			runtime.lastGoalRotation
				and circularDistance(
					runtime.lastGoalRotation,
					currentGoal
				)
				or 0
		local lineJump =
			runtime.lastLineRotation
				and math.abs(
					signedAngleDifference(
						runtime.lastLineRotation,
						currentLine
					)
				)
				or 0
		local previousRelative =
			runtime.lastGoalRotation
				and runtime.lastLineRotation
				and normalizeAngle(
					runtime.lastLineRotation
						- runtime.lastGoalRotation
				)
				or nil
		local currentRelative =
			normalizeAngle(currentLine - currentGoal)
		local relativeJump =
			previousRelative
				and circularDistance(
					previousRelative,
					currentRelative
				)
				or 0
		local isolatedGoalJump =
			runtime.skillFired
				and goalJump >= CONFIG.skillCycleGoalJump
				and lineJump
					<= CONFIG.skillCycleLineFollowTolerance
				and relativeJump
					>= CONFIG.skillCycleDeltaJump
		local enoughGap =
			sampleAt - runtime.skillCycleStartedAt
				>= CONFIG.skillCycleMinGap

		local newCycle =
			enoughGap
				and (
					checkChanged
					or (pairChanged and runtime.skillFired)
					or isolatedGoalJump
					or (
						runtime.skillFired
						and lineJump
							>= CONFIG.skillCycleLineReset
					)
				)

		if newCycle then
			-- A replacement Check can appear in the same render frame in which the
			-- previous one disappears. v3.46 immediately began the new cycle and
			-- silently erased the missed one, which is exactly how cycle 33 vanished
			-- from the supplied log. Audit it before replacing any state.
			if CONFIG.logMisses
				and not runtime.skillFired
				and (
					runtime.skillMotionObserved
					or runtime.skillRejectedSamples > 0
				) then
				warn(string.format(
					"[VD AUTO v3.65][SKILL_REPLACED_WITHOUT_PRESS] cycle=%d samples=%d check=%s line=%s goal=%s currentError=%s predictedError=%s omega=%+.1f replacementCheck=%s reason=%s",
					runtime.skillCycle,
					runtime.skillSampleCount,
					runtime.activeCheckPath,
					runtime.activeLineObject and runtime.activeLineObject:GetFullName() or "none",
					runtime.activeGoalObject and runtime.activeGoalObject:GetFullName() or "none",
					runtime.lastCurrentError and string.format("%.2f", runtime.lastCurrentError) or "n/a",
					runtime.lastPredictedError and string.format("%.2f", runtime.lastPredictedError) or "n/a",
					runtime.lastAngularSpeed,
					check:GetFullName(),
					checkChanged and "check-changed" or (pairChanged and "pair-changed" or "rotation-reset")
				))
			end
			beginSkillCycle(
				check :: GuiObject,
				line :: GuiObject,
				goal :: GuiObject,
				sampleAt,
				CONFIG.skillChainWarmup
			)
		else
			runtime.activeLineObject = line
			runtime.activeGoalObject = goal
		end
	end

	runtime.lastGoalRotation = currentGoal
	runtime.lastLineRotation = currentLine

	if runtime.skillFired
		and not runtime.skillInputAuditLogged
		and sampleAt - runtime.lastSkillPressAt >= CONFIG.skillInputAuditDelay then
		local liveLine = line :: GuiObject
		local liveGoal = goal :: GuiObject
		local liveDelta = normalizeAngle(liveLine.Rotation - liveGoal.Rotation)
		local liveError = circularDistance(liveDelta, CONFIG.skillTargetOffset)
		if liveError >= CONFIG.skillInputAuditPastCenterDegrees then
			runtime.skillInputAuditLogged = true
			warn(string.format(
				"[VD AUTO v3.65][SKILL_INPUT_UNCONFIRMED] cycle=%d sentAtCenter=true guiStillLive=true current=%.2f target=%.2f error=%.2f ageMs=%.1f action=report-game-did-not-close-no-dangerous-late-retry",
				runtime.skillCycle,
				liveDelta,
				CONFIG.skillTargetOffset,
				liveError,
				(sampleAt - runtime.lastSkillPressAt) * 1000
			))
		end
	end

	if not CONFIG.skillEnabled
		or runtime.skillFired
		or localIsDowned()
		or sampleAt - runtime.skillVisibleSince
			< runtime.skillWarmup then
		return
	end

	local delta =
		normalizeAngle(line.Rotation - goal.Rotation)
	local previousDelta = runtime.lastSkillDelta
	local previousSampleAt = runtime.lastSkillSampleAt
	local currentError = circularDistance(delta, CONFIG.skillTargetOffset)
	runtime.skillSampleCount += 1
	local angularSpeed = 0.0
	local sampleDt = 0.0
	local sampleDiscontinuity = false

	if previousDelta ~= nil
		and previousSampleAt ~= nil then
		local dt = sampleAt - previousSampleAt
		sampleDt = dt
		if dt > CONFIG.skillLifecycleGapReset then
			warn(string.format(
				"[VD AUTO v3.65][SKILL_LIFECYCLE_RESET] reason=sample-gap gapMs=%.2f oldCycle=%d action=fresh-cycle",
				dt * 1000,
				runtime.skillCycle
			))
			beginSkillCycle(
				check :: GuiObject,
				line :: GuiObject,
				goal :: GuiObject,
				sampleAt,
				0.0
			)
			return
		end
		if dt > 0.0001 then
			local rawStep = signedAngleDifference(previousDelta, delta)
			local rawAngularSpeed = rawStep / dt
			local absoluteStep = math.abs(rawStep)
			if dt > CONFIG.skillEstimatorMaximumDt
				or absoluteStep
					> CONFIG.skillDiscontinuityMaximumStepDegrees
				or math.abs(rawAngularSpeed)
					> CONFIG.skillMaximumPlausibleAngularSpeed then
				sampleDiscontinuity = true
				previousDelta = nil
				previousSampleAt = nil
				sampleDt = 0.0
				table.clear(runtime.skillAngularSamples)
				-- A discontinuity can mean that the visible Check kept an old Line
				-- while inserting a second, live Line. Probe the small container for
				-- continuous motion on the following frames instead of pinning cache.
				runtime.forcePairProbeUntil = math.max(
					runtime.forcePairProbeUntil,
					sampleAt + CONFIG.skillUncertainPairProbeDuration
				)
				runtime.lastActivePairProbeAt = -math.huge

				local hardLifecycleReset = absoluteStep
					>= CONFIG.skillHardLifecycleResetStepDegrees
					and not runtime.skillFired
					and sampleAt - runtime.skillCycleStartedAt
						>= CONFIG.skillDiscontinuityCycleResetMinimumAge
				if hardLifecycleReset then
					warn(string.format(
						"[VD AUTO v3.65][SKILL_HARD_RESET_REARMED] oldCycle=%d step=%+.2f current=%.2f samples=%d action=new-cycle-and-event-live-pair-probe",
						runtime.skillCycle,
						rawStep,
						delta,
						runtime.skillSampleCount
					))
					beginSkillCycle(
						check :: GuiObject,
						line :: GuiObject,
						goal :: GuiObject,
						sampleAt,
						0.0
					)
					return
				end
				if sampleAt - runtime.lastRejectedSampleAt
						> CONFIG.skillDiscontinuityCycleResetWindow then
					runtime.skillRejectedSamples = 0
				end
				runtime.skillRejectedSamples += 1
				runtime.lastRejectedSampleAt = sampleAt
				runtime.lastInputFailure = "sample-discontinuity-rejected"
				if CONFIG.logMisses
					and sampleAt - runtime.lastDiscontinuityLogAt
						>= CONFIG.skillDiscontinuityLogCooldown then
					runtime.lastDiscontinuityLogAt = sampleAt
					warn(string.format(
						"[VD AUTO v3.65][SKILL_SAMPLE_REJECTED] cycle=%d rawOmega=%+.1f step=%+.2f dtMs=%.2f current=%.2f target=%.2f error=%.2f rejected=%d action=probe-live-pair-reset-estimator",
						runtime.skillCycle,
						rawAngularSpeed,
						rawStep,
						dt * 1000,
						delta,
						CONFIG.skillTargetOffset,
						currentError,
						runtime.skillRejectedSamples
					))
				end
				if runtime.skillRejectedSamples
						>= CONFIG.skillDiscontinuityCycleResetCount
					and sampleAt - runtime.skillCycleStartedAt
						>= CONFIG.skillDiscontinuityCycleResetMinimumAge then
					warn(string.format(
						"[VD AUTO v3.65][SKILL_GUI_REBUILD_RESET] oldCycle=%d rejected=%d current=%.2f action=new-cycle-same-check",
						runtime.skillCycle,
						runtime.skillRejectedSamples,
						delta
					))
					beginSkillCycle(
						check :: GuiObject,
						line :: GuiObject,
						goal :: GuiObject,
						sampleAt,
						0.0
					)
					return
				end
			else
				local samples = runtime.skillAngularSamples
				samples[#samples + 1] = rawAngularSpeed
				while #samples > CONFIG.skillAngularMedianWindow do
					table.remove(samples, 1)
				end
				angularSpeed = median(samples)
				if runtime.lastInputFailure
					== "sample-discontinuity-rejected" then
					runtime.lastInputFailure = "none"
				end
			end
		end
	end

	local deltaStep = not sampleDiscontinuity and previousDelta ~= nil
		and math.abs(signedAngleDifference(previousDelta, delta))
		or 0.0
	local meaningfulMotion = math.abs(angularSpeed) >= CONFIG.skillMotionArmAngularSpeed
		or deltaStep >= CONFIG.skillDormantWakeDelta
	if meaningfulMotion then
		runtime.skillMotionObserved = true
		runtime.lastMeaningfulMotionAt = sampleAt
	end

	local cycleAge = sampleAt - runtime.skillCycleStartedAt
	if runtime.skillDormantStatic then
		local dormantLineDelta = runtime.dormantLineRotation ~= nil
			and circularDistance(runtime.dormantLineRotation, currentLine)
			or 0.0
		local dormantGoalDelta = runtime.dormantGoalRotation ~= nil
			and circularDistance(runtime.dormantGoalRotation, currentGoal)
			or 0.0
		if not meaningfulMotion
			and dormantLineDelta < CONFIG.skillDormantWakeDelta
			and dormantGoalDelta < CONFIG.skillDormantWakeDelta then
			runtime.lastSkillDelta = delta
			runtime.lastSkillSampleAt = sampleAt
			return
		end
		-- The same GuiObjects woke up into a real check. Rearm without requiring
		-- them to be destroyed/recreated and without incrementing a fake cycle.
		runtime.skillDormantStatic = false
		runtime.skillMotionObserved = true
		runtime.skillCycleStartedAt = sampleAt
		runtime.skillVisibleSince = sampleAt
		runtime.skillSampleCount = 0
		runtime.lastSkillDelta = nil
		runtime.lastSkillSampleAt = nil
		previousDelta = nil
		previousSampleAt = nil
		angularSpeed = 0.0
		sampleDt = 0.0
		table.clear(runtime.skillAngularSamples)
		runtime.lastInputFailure = "none"
	elseif not runtime.skillMotionObserved
		and cycleAge >= CONFIG.skillStaticRejectDelay then
		-- Do not mark the cycle as fired. Some real checks hold a static template
		-- before the Line begins moving; v3.45 silently discarded those forever.
		runtime.skillDormantStatic = true
		runtime.dormantLineRotation = currentLine
		runtime.dormantGoalRotation = currentGoal
		runtime.lastInputFailure = "waiting-for-real-line-motion"
		runtime.lastSkillDelta = delta
		runtime.lastSkillSampleAt = sampleAt
		return
	end

	-- A moving check is never discarded solely because it lasted longer than a
	-- guessed timeout. Only dormant/static templates are quarantined.
	if cycleAge >= CONFIG.skillCycleMaximumDuration
		and not runtime.skillMotionObserved then
		runtime.skillDormantStatic = true
	end

	runtime.lastSkillDelta = delta
	runtime.lastSkillSampleAt = sampleAt

	if math.abs(angularSpeed) < CONFIG.skillMinAngularSpeed then
		runtime.lastCurrentError = currentError
		runtime.lastPredictedError = currentError
		runtime.lastAngularSpeed = angularSpeed
		-- Do not fire four degrees before the center merely because this is the
		-- first visible frame. Only accept a genuinely centered first sample.
		if currentError <= CONFIG.skillEmergencyWindowDegrees
			and sampleAt - runtime.lastSkillPressAt >= CONFIG.skillPressCooldown then
			runtime.skillScheduledToken += 1
			runtime.skillFired = true
			runtime.lastSkillPressAt = sampleAt
			if not sendSpace(0.0) then
				runtime.skillFired = false
				warn(string.format(
					"[VD AUTO v3.65][SKILL_PRESS_FAILED] cycle=%d reason=%s firstFrame=true current=%.2f target=%.2f error=%.2f",
					runtime.skillCycle, runtime.lastInputFailure, delta,
					CONFIG.skillTargetOffset, currentError
				))
			elseif CONFIG.logPresses then
				print(string.format(
					"[VD AUTO v3.65][SKILL_PRESS] cycle=%d reason=center-first-frame current=%.2f target=%.2f error=%.2f delivery=heartbeat-latched holdMs>=%.2f minHeartbeatFrames=%d",
					runtime.skillCycle, delta, CONFIG.skillTargetOffset, currentError,
					runtime.lastSyntheticHoldDuration * 1000,
					CONFIG.skillInputMinimumHeartbeatFrames
				))
			end
		end
		return
	end

	local adaptiveLead = math.min(
		CONFIG.skillPredictionMaximum,
		math.max(
			CONFIG.skillPredictionLead,
			sampleDt * CONFIG.skillPredictionFrameFraction
		)
	)
	local absoluteAngularSpeed = math.abs(angularSpeed)
	local maximumLeadDegrees = absoluteAngularSpeed
		>= CONFIG.skillFastAngularSpeed
		and CONFIG.skillFastPredictionMaximumLeadDegrees
		or CONFIG.skillPredictionMaximumLeadDegrees
	if absoluteAngularSpeed > CONFIG.skillMinAngularSpeed then
		adaptiveLead = math.min(
			adaptiveLead,
			maximumLeadDegrees / absoluteAngularSpeed
		)
	end
	local predictedDelta = normalizeAngle(delta + angularSpeed * adaptiveLead)
	local predictedError = circularDistance(predictedDelta, CONFIG.skillTargetOffset)
	local signedToTarget = signedAngleDifference(delta, CONFIG.skillTargetOffset)
	local timeToTarget = nil
	if math.abs(angularSpeed) >= CONFIG.skillMinAngularSpeed
		and signedToTarget * angularSpeed >= 0 then
		timeToTarget = signedToTarget / angularSpeed
	end

	-- A high-speed marker can cross the entire success band between rendered
	-- samples. Do not guess a wider early angle and do not wait to click late on
	-- the next frame: interpolate the center time from stable measured motion and
	-- schedule exactly one cancellable input edge inside that frame interval.
	if timeToTarget ~= nil
		and absoluteAngularSpeed >= CONFIG.skillInterpolatedMinimumAngularSpeed
		and #runtime.skillAngularSamples >= CONFIG.skillInterpolatedMinimumSamples
		and currentError <= CONFIG.skillInterpolatedMaximumArmingDegrees
		and timeToTarget >= CONFIG.skillInterpolatedMinimumDelay
		and timeToTarget <= math.min(
			CONFIG.skillInterpolatedMaximumDelay,
			math.max(
				0.012,
				sampleDt * CONFIG.skillInterpolatedFrameMultiplier
			)
		) then
		runtime.skillScheduledToken += 1
		local scheduledToken = runtime.skillScheduledToken
		local scheduledCycle = runtime.skillCycle
		local scheduledSpeed = angularSpeed
		local fireDelay = math.max(
			0.0,
			timeToTarget - CONFIG.skillInterpolatedInputLead
		)
		runtime.skillScheduledAt = sampleAt + fireDelay
		task.delay(fireDelay, function()
			local firedAt = now()
			if not runtime.running
				or not CONFIG.skillEnabled
				or runtime.skillFired
				or not runtime.skillVisible
				or runtime.skillCycle ~= scheduledCycle
				or runtime.skillScheduledToken ~= scheduledToken
				or firedAt - runtime.skillScheduledAt
					> CONFIG.skillInterpolatedLateTolerance
				or firedAt - (runtime.lastSkillSampleAt or -math.huge)
					> CONFIG.skillInterpolatedSampleFreshness
				or runtime.lastAngularSpeed * scheduledSpeed <= 0
				or not runtime.activeLineObject
				or not runtime.activeLineObject.Parent
				or not runtime.activeGoalObject
				or not runtime.activeGoalObject.Parent then
				return
			end
			local liveLine = runtime.activeLineObject :: GuiObject
			local liveGoal = runtime.activeGoalObject :: GuiObject
			local liveDelta = normalizeAngle(liveLine.Rotation - liveGoal.Rotation)
			local liveError = circularDistance(
				liveDelta,
				CONFIG.skillTargetOffset
			)
			local previousLiveDelta = runtime.lastSkillDelta
			local liveCrossed = false
			if previousLiveDelta ~= nil then
				local liveStep = signedAngleDifference(previousLiveDelta, liveDelta)
				local targetStep = signedAngleDifference(
					previousLiveDelta,
					CONFIG.skillTargetOffset
				)
				if liveStep > 0 then
					liveCrossed = targetStep >= 0 and targetStep <= liveStep
				elseif liveStep < 0 then
					liveCrossed = targetStep <= 0 and targetStep >= liveStep
				end
				liveCrossed = liveCrossed
					and liveStep * scheduledSpeed > 0
					and math.abs(liveStep)
						<= CONFIG.skillCrossingMaximumStep
			end
			local liveRescueLimit = math.abs(scheduledSpeed)
				>= CONFIG.skillFastAngularSpeed
				and CONFIG.skillInterpolatedFastLiveLateRescueDegrees
				or CONFIG.skillInterpolatedLiveLateRescueDegrees
			local liveAccept = liveError
				<= CONFIG.skillInterpolatedLiveCenterDegrees
				or (liveCrossed and liveError <= liveRescueLimit)
			if not liveAccept then
				runtime.skillScheduledToken += 1
				warn(string.format(
					"[VD AUTO v3.65][SKILL_TIMER_POSITION_REJECTED] cycle=%d scheduledDelayMs=%.2f latenessMs=%+.2f live=%.2f target=%.2f liveError=%.2f crossed=%s action=do-not-log-false-success-allow-render-crossing-rescue",
					scheduledCycle,
					fireDelay * 1000,
					(firedAt - runtime.skillScheduledAt) * 1000,
					liveDelta,
					CONFIG.skillTargetOffset,
					liveError,
					tostring(liveCrossed)
				))
				return
			end
			runtime.skillFired = true
			runtime.lastSkillPressAt = firedAt
			runtime.skillScheduledToken += 1
			if not sendSpace(scheduledSpeed) then
				runtime.skillFired = false
				warn(string.format(
					"[VD AUTO v3.65][SKILL_PRESS_FAILED] cycle=%d reason=interpolated-center input=%s scheduledDelayMs=%.2f",
					scheduledCycle,
					runtime.lastInputFailure,
					fireDelay * 1000
				))
			elseif CONFIG.logPresses then
				print(string.format(
					"[VD AUTO v3.65][SKILL_PRESS] cycle=%d reason=interpolated-live-validated omega=%+.1f scheduledDelayMs=%.2f latenessMs=%+.2f liveError=%.2f liveCrossed=%s delivery=heartbeat-latched",
					scheduledCycle,
					scheduledSpeed,
					fireDelay * 1000,
					(firedAt - runtime.skillScheduledAt) * 1000,
					liveError,
					tostring(liveCrossed)
				))
			end
		end)
	end

	local crossedTarget = false
	local crossingOvershoot = math.huge
	if previousDelta ~= nil then
		local step = signedAngleDifference(previousDelta, delta)
		local targetStep = signedAngleDifference(previousDelta, CONFIG.skillTargetOffset)
		if math.abs(step) <= CONFIG.skillCrossingMaximumStep
			and sampleDt <= CONFIG.skillCrossingMaximumDt then
			if step > 0 then
				crossedTarget = targetStep >= 0 and targetStep <= step
			elseif step < 0 then
				crossedTarget = targetStep <= 0 and targetStep >= step
			end
		end
		if crossedTarget then
			crossingOvershoot = currentError
		end
		-- Crossing is accepted only when two consecutive plausible samples
		-- straddle the measured target and the new sample has not travelled far
		-- beyond it. This catches a skipped center without reviving the old
		-- unbounded crossed=true behaviour.
		local crossingLimit = absoluteAngularSpeed
			>= CONFIG.skillFastAngularSpeed
			and CONFIG.skillFastCrossingLateRescueDegrees
			or CONFIG.skillCrossingLateRescueDegrees
		crossedTarget = crossedTarget
			and crossingOvershoot <= crossingLimit
	end

	runtime.lastPredictedDelta = predictedDelta
	runtime.lastCurrentError = currentError
	runtime.lastPredictedError = predictedError
	runtime.lastAngularSpeed = angularSpeed

	local predictionArmingDegrees = absoluteAngularSpeed
		>= CONFIG.skillFastAngularSpeed
		and CONFIG.skillFastPredictionArmingDegrees
		or CONFIG.skillPredictionArmingDegrees
	local predictionArmed =
		timeToTarget ~= nil
		and timeToTarget >= 0
		and timeToTarget <= adaptiveLead
		and currentError <= predictionArmingDegrees
		and predictedError <= CONFIG.skillPredictionWindowDegrees

	local reason = nil
	if currentError <= CONFIG.skillWindowDegrees then
		reason = "center"
	elseif predictionArmed then
		reason = "short-prediction"
	elseif crossedTarget then
		reason = if crossingOvershoot
			<= CONFIG.skillCrossingAcceptanceDegrees
			then "near-center-crossing"
			else "bounded-late-crossing"
	end

	if reason
		and sampleAt - runtime.lastSkillPressAt
			>= CONFIG.skillPressCooldown then
		runtime.skillScheduledToken += 1
		runtime.skillFired = true
		runtime.lastSkillPressAt = sampleAt

		if not sendSpace(angularSpeed) then
			runtime.skillFired = false
			warn(string.format(
				"[VD AUTO v3.65][SKILL_PRESS_FAILED] cycle=%d reason=%s input=%s current=%.2f target=%.2f currentError=%.2f predicted=%.2f predictedError=%.2f",
				runtime.skillCycle,
				reason,
				runtime.lastInputFailure,
				delta,
				CONFIG.skillTargetOffset,
				currentError,
				predictedDelta,
				predictedError
			))
		elseif CONFIG.logPresses then
			print(string.format(
				"[VD AUTO v3.65][SKILL_PRESS] cycle=%d reason=%s current=%.2f target=%.2f predicted=%.2f currentError=%.2f predictedError=%.2f omega=%+.1f leadMs=%.2f tTargetMs=%s crossed=%s delivery=heartbeat-latched holdMs>=%.2f minHeartbeatFrames=%d",
				runtime.skillCycle,
				reason,
				delta,
				CONFIG.skillTargetOffset,
				predictedDelta,
				currentError,
				predictedError,
				angularSpeed,
				adaptiveLead * 1000,
				timeToTarget and string.format("%.2f", timeToTarget * 1000) or "n/a",
				tostring(crossedTarget),
				runtime.lastSyntheticHoldDuration * 1000,
				CONFIG.skillInputMinimumHeartbeatFrames
			))
		end
	end
end

---------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------

local function stop(): ()
	if not runtime.running then
		return
	end

	runtime.running = false
	releaseSyntheticSpace()
	if runtime.renderBound then
		pcall(function() RunService:UnbindFromRenderStep(CONFIG.renderBindingName) end)
		runtime.renderBound = false
	end
	disconnectSkillDiscovery()
	disconnectAll()

	if rawget(_G, SKILL_ONLY_KEY) == runtime then
		_G[SKILL_ONLY_KEY] = nil
	end

	print("[VD AUTO v3.65] stopped")
end

runtime.Stop = stop

initializeVirtualInput()

-- PlayerGui is occasionally destroyed/recreated around respawn and can also be
-- inserted after this script starts. Keep the watcher outside discovery so a
-- missing initial GUI can recover without polling or another GetDescendants
-- scan every frame.
addConnection(player.ChildAdded:Connect(function(instance)
	if runtime.running and instance:IsA("PlayerGui") then
		initializeSkillDiscovery(instance :: PlayerGui)
		resetSkillState()
	end
end))

addConnection(player.ChildRemoved:Connect(function(instance)
	if runtime.running and instance == runtime.playerGui then
		disconnectSkillDiscovery()
		releaseSyntheticSpace()
		resetSkillState()
	end
end))

initializeSkillDiscovery()

addConnection(
	player.CharacterAdded:Connect(function()
		releaseSyntheticSpace()
		resetSkillState()
		runtime.lifecycleDowned = false
		initializeSkillDiscovery()
		warn("[VD AUTO v3.65][SKILL_LIFECYCLE_RESET] reason=character-added action=fresh-cycle")
	end)
)

addConnection(
	UserInputService.InputBegan:Connect(function(input, processed)
		if processed then
			return
		end

		if input.KeyCode == Enum.KeyCode.F2 then
			CONFIG.skillEnabled = not CONFIG.skillEnabled
			print(
				"[VD AUTO v3.65] auto skill = "
					.. (
						CONFIG.skillEnabled
							and "ON"
							or "OFF"
					)
			)
		elseif input.KeyCode == Enum.KeyCode.F3 then
			stop()
		end
	end)
)

local bindOk = pcall(function()
	RunService:BindToRenderStep(
		CONFIG.renderBindingName,
		CONFIG.renderPriority,
		function()
			if runtime.running then updateSkillCheck() end
		end
	)
end)
if bindOk then
	runtime.renderBound = true
else
	-- Executor/game compatibility fallback. The late binding above is preferred
	-- because the game's UI commonly updates after ordinary RenderStepped
	-- connections, which was enough to miss an entire low-FPS skill window.
	addConnection(RunService.RenderStepped:Connect(function()
		if runtime.running then updateSkillCheck() end
	end))
end

print(
	"[VD AUTO v3.65] active | live-validated interpolated timer for fast checks | measured normal-speed center | active moving Line pinned through repair-GUI rebuild | heartbeat-latched Space input | one cancellable Space edge | timer position audit | zero PlayerGui per-frame GetDescendants | "
	.. "center target=109.25 | no silent replaced cycle | F2 toggle | F3 stop"
)
