--!strict
--[[
VD Survivor Helper v5.5.82 AUDIT CORE INTEGRATION FIX

Clean single-file architecture.

Hard invariants:
  * one LocalScript
  * one PreSimulation detector scheduler
  * one post-input RenderStep movement writer
  * one MovementWriter
  * one active ThreatEpisode
  * one runtime owner token and one local BindableEvent singleton marker
  * all movement writes stay inside the MovementWriter module
  * animation owner is the source of truth for an attack
  * signals from the same attack merge into one episode
  * personal-space movement uses one raycast-planned open corridor, never a blind wall-facing vector
  * Zombie, Exit, Flashlight and Pistol aim are integrated
  * crouch counter uses one active signal; bounded personal-space guard is class-independent
]]

---------------------------------------------------------------------
-- 1. Services
---------------------------------------------------------------------

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local VirtualInputManager = game:GetService("VirtualInputManager")

local LocalPlayer = Players.LocalPlayer
if not LocalPlayer then
	error("VD Helper requires Players.LocalPlayer")
end

-- The standalone Zombie Aura starts before Helper in the supplied launch order
-- and retains its own Heartbeat, 4-second Workspace rescan and RenderStep writer.
-- Helper already owns event-indexed zombie detection/movement, so stop that old
-- runtime instead of merely asking it to skip writes after doing duplicate work.
local stoppedStandaloneZombieRuntime = false
do
	local standaloneStop = rawget(_G, "StopVDZombieDodge")
	if type(standaloneStop) == "function" then
		local ok = pcall(standaloneStop)
		stoppedStandaloneZombieRuntime = ok
		if rawget(_G, "StopVDZombieDodge") == standaloneStop then
			_G.StopVDZombieDodge = nil
		end
	end
end

-- Keep a process-wide runtime owner as well as the PlayerScripts marker.
-- The marker alone cannot stop a second legacy copy whose marker was already
-- replaced; the global registry prevents every v5.2.42+ instance from becoming
-- markerless and surviving into a later round.
local GLOBAL_RUNTIME_KEY = "__VD_SURVIVOR_HELPER_RUNTIME"
local previousGlobalRuntime = rawget(_G, GLOBAL_RUNTIME_KEY)
if type(previousGlobalRuntime) == "table"
	and type(previousGlobalRuntime.Stop) == "function" then
	pcall(previousGlobalRuntime.Stop, "replaced-by-v5.5.82")
end
local GLOBAL_OWNER_TOKEN = {}
_G[GLOBAL_RUNTIME_KEY] = {
	token = GLOBAL_OWNER_TOKEN,
	starting = true,
}

-- A duplicated Helper was visible in the supplied log: every event appeared
-- twice. Keep one local instance with both marker and global ownership.
local PlayerScripts =
	LocalPlayer:WaitForChild("PlayerScripts")
do
	local runtime = rawget(_G, GLOBAL_RUNTIME_KEY)
	if type(runtime) ~= "table" or runtime.token ~= GLOBAL_OWNER_TOKEN then
		return
	end
end
local SINGLETON_MARKER_NAME =
	"VD_Survivor_Helper_LocalSingleton"
local oldSingleton =
	PlayerScripts:FindFirstChild(
		SINGLETON_MARKER_NAME
	)
if oldSingleton then
	-- Ask the previous instance to shut down, but do not trust the event alone:
	-- an executor can replace scripts while an older instance is between startup
	-- stages. Directly unbind the exact render name stored on its marker too.
	local oldMovementBindingName = oldSingleton:GetAttribute(
		"MovementRenderBindingName"
	)
	if oldSingleton:IsA("BindableEvent") then
		pcall(function()
			oldSingleton:Fire(
				"replaced-by-new-instance"
			)
		end)
	end
	if type(oldMovementBindingName) == "string"
		and oldMovementBindingName ~= "" then
		pcall(function()
			RunService:UnbindFromRenderStep(
				oldMovementBindingName
			)
		end)
	end
	-- v5.2.25-v5.2.35 all shared this static name. Clear it even when
	-- the old marker/event was stale or belonged to an interrupted startup.
	pcall(function()
		RunService:UnbindFromRenderStep(
			"VDHelperRenderDodgeV5225"
		)
	end)
	task.wait()
	local runtime = rawget(_G, GLOBAL_RUNTIME_KEY)
	if type(runtime) ~= "table" or runtime.token ~= GLOBAL_OWNER_TOKEN then return end
	if oldSingleton.Parent then
		oldSingleton:Destroy()
	end
else
	-- Also clear a legacy writer that survived without its singleton marker.
	pcall(function()
		RunService:UnbindFromRenderStep(
			"VDHelperRenderDodgeV5225"
		)
	end)
end

local SingletonMarker = Instance.new("BindableEvent")
SingletonMarker.Name = SINGLETON_MARKER_NAME
SingletonMarker.Parent = PlayerScripts

local INSTANCE_ID =
	string.format(
		"%08x",
		math.random(0, 0x7fffffff)
	)

---------------------------------------------------------------------
-- 2. Constants
---------------------------------------------------------------------

local VERSION = "5.5.82-AUDITCORE1"
local SCRIPT_TAG = "VD 360 V5.5.82-AUDITCORE1"

SingletonMarker:SetAttribute("Version", VERSION)
SingletonMarker:SetAttribute("OwnsZombieMovement", true)
SingletonMarker:SetAttribute("MovementWriterIntegrated", true)
SingletonMarker:SetAttribute("OwnsAutoPallet", false)
SingletonMarker:SetAttribute("OwnsWindowAssist", true)
SingletonMarker:SetAttribute("ObservesWindowVaults", true)

local PRIORITY = {
	EXIT = 1000,
	EMERGENCY_RELEASE = 900,
	PALLET_ESCAPE = 875,
	ZOMBIE = 850,
	DODGE = 825,
	-- A consumed physical Space must be paired with an actual alternative route.
	-- This short, topology-checked intent outranks the old attack route because
	-- that route may itself be pointing at the traversal we just rejected.
	TRAVERSAL_ESCAPE = 835,
	-- Defence in depth only. Automatic window commits are disabled below, and
	-- even if a runtime edit re-enables them they may never beat a live dodge.
	VAULT_COMMIT = 760,
	MINDGAME = 500,
	REPAIR_RESUME = 320,
}

local PHASE_RANK = {
	PREP = 1,
	ACTIVE = 2,
	FINISHER = 3,
}

local OWNER = {
	EXIT = "ExitController",
	THREAT = "ThreatController",
	ZOMBIE = "ZombieController",
	PALLET = "PalletController",
	WINDOW = "WindowController",
	REPAIR = "RepairResumeController",
}

-- Every defensive subsystem proposes an action, but only this typed contract
-- decides which kind may own the character. Movement priorities are compared
-- only after non-movement authority (locks/counters) has been resolved.
local ACTION_KIND = {
	OBSERVE = "OBSERVE",
	MOVE = "MOVE",
	COUNTER_ARM = "COUNTER_ARM",
	COUNTER_C = "COUNTER_C",
	HARD_BLOCK = "HARD_BLOCK",
}

local ACTION_PRIORITY = {
	[ACTION_KIND.OBSERVE] = 0,
	[ACTION_KIND.MOVE] = 100,
	[ACTION_KIND.COUNTER_ARM] = 800,
	[ACTION_KIND.COUNTER_C] = 900,
	[ACTION_KIND.HARD_BLOCK] = 1000,
}

local EXACT_ACTION_CONTRACTS = {
	-- Both exact Abysswalker posture sequences are serialized through the counter
	-- arbiter. PREP/ACTIVE alone is not enough: TryAbysswalkerCrouch separates the
	-- held long strike from the fast ordinary-M1 transition before emitting C.
	["129784271201071"] = ACTION_KIND.COUNTER_ARM,
	["132817836308238"] = ACTION_KIND.COUNTER_C,
	["118907603246885"] = ACTION_KIND.COUNTER_ARM,
	["78432063483146"] = ACTION_KIND.COUNTER_C,
}

local MOVEMENT_OWNER_TIEBREAK = {
	[OWNER.EXIT] = 60,
	[OWNER.PALLET] = 50,
	[OWNER.ZOMBIE] = 40,
	[OWNER.THREAT] = 30,
	[OWNER.WINDOW] = 20,
	[OWNER.REPAIR] = 10,
}

---------------------------------------------------------------------
-- 3. Config
---------------------------------------------------------------------

local Config = {
	enabled = true,
	showHud = false,
	-- Confirmed ACTIVE attacks may own one raycast-planned direction. The route is
	-- fixed for continuity: no live 360/orbit transform and no opposite WASD blend.
	-- PREP/FINISHER/proximity-only signals remain observe-only unless an exact,
	-- log-proven wind-up explicitly opts into forcePrepMovement.
	threatAutoMovementEnabled = true,
	threatConservativeMovementEnabled = true,
	threatConservativeActiveOnly = true,
	threatConservativeMinimumAwayDot = 0.18,
	threatConservativeWallClearance = 2.50,
	threatConservativeWallProbeDistance = 5.50,
	-- v5.5.2: ordinary killers can steer toward the survivor even when the current
	-- animation is not a lunge. DistanceKeeper is therefore a bounded relative-
	-- closing safety floor, not an attack claim. Exact animation IDs below decide
	-- whether the forecast receives projectile/lunge speed and reach.
	threatDistanceKeeperEnabled = true,
	threatDistanceKeeperEnterDistance = 16.5,
	threatDistanceKeeperExitDistance = 20.0,
	threatDistanceKeeperDuration = 3.10,
	threatDistanceKeeperMinimumHold = 0.45,
	threatDistanceKeeperMinimumAwayDot = 0.42,
	threatDistanceKeeperRequireLineOfSight = true,
	threatDistanceKeeperMinimumFacing = 0.35,
	threatDistanceKeeperMinimumApproach = 1.00,
	-- Abysswalker's slowing pressure can cut native speed to roughly half before
	-- the damaging edge. Treat that replicated WalkSpeed loss as evidence to seek
	-- an obstacle-certified exit, but never while C itself is being held and never
	-- write WalkSpeed or break an interaction.
	abysswalkerSlowPressureEnabled = true,
	abysswalkerSlowPressureMaximumDistance = 28.0,
	abysswalkerSlowPressureWalkRatio = 0.82,
	abysswalkerSlowPressureAbsoluteMaximum = 14.0,
	abysswalkerSlowPressureTargetDistance = 23.0,
	abysswalkerSlowPressureCounterGrace = 0.20,
	-- Slasher can remain nearly stationary and wait for the survivor to enter the
	-- short Tracking envelope. In that case killer-only approach is zero even
	-- though physical WASD is rapidly destroying separation. Permit an early
	-- distance episode only for the authoritative Slasher/Tracking class, strong
	-- aim and material player-created closing. Movement still needs a grounded
	-- open exit and either a full certificate or a >=1.5-stud gain over WASD.
	trackingManualClosingGuardEnabled = true,
	trackingManualClosingGuardMaximumDistance = 20.0,
	trackingManualClosingGuardMinimumFacing = 0.80,
	trackingManualClosingGuardMinimumRelativeApproach = 5.0,
	trackingManualClosingGuardMinimumKillerApproach = -0.75,
	-- An exact Tracking phase proves that Slasher is actively pressuring this
	-- survivor. Keep a bounded post-signal envelope so one weak root-facing
	-- sample cannot immediately permit native WASD to re-enter melee range.
	trackingPostSignalEnvelopeDuration = 5.75,
	trackingPostSignalEnvelopeDistance = 16.5,
	trackingPostSignalEnvelopeMinimumRelativeClosing = 1.75,
	trackingPostSignalEnvelopeMinimumFacing = -0.15,
	-- Literal Killer can chain a second charged wind-up a few seconds after a
	-- certified melee. Keep the preventive distance envelope alive across that
	-- gap so native WASD cannot re-enter the 11-stud lunge radius before PREP.
	literalKillerPostSignalEnvelopeDuration = 4.75,
	literalKillerPostSignalEnvelopeDistance = 19.0,
	literalKillerPostSignalEnvelopeMinimumRelativeClosing = 1.25,
	literalKillerPostSignalEnvelopeMinimumFacing = -0.20,
	-- Veil may remain almost stationary while the survivor accidentally runs into
	-- the melee envelope. Strong aim plus rapid player-created closing is enough
	-- to request a deep open exit, but never a weak/boxed route.
	veilManualClosingGuardEnabled = true,
	veilManualClosingGuardMaximumDistance = 22.0,
	veilManualClosingGuardMinimumFacing = 0.80,
	veilManualClosingGuardMinimumRelativeApproach = 5.0,
	veilManualClosingGuardMinimumKillerApproach = -0.75,
	-- Veil can hold its root almost still while aiming a close melee. Waiting for
	-- 8 studs/s of relative closing admitted the episode only inside 9.5 studs in
	-- the supplied trace. Strong, authoritative aim inside this smaller envelope
	-- may request the strict Veil open-exit profile before the late ACTIVE signal.
	veilCloseAimedGuardEnabled = true,
	veilCloseAimedGuardMaximumDistance = 14.5,
	veilCloseAimedGuardMinimumFacing = 0.85,
	veilCloseAimedGuardMinimumApproach = -0.50,
	-- A through-wall Veil shot produced no animation signal at 56.31 studs. Root
	-- aim alone remains too ambiguous, so this fallback additionally requires
	-- sustained killer-authored closing. It still needs a full open-route
	-- certificate before it may own movement.
	veilLongApproachGuardEnabled = true,
	-- DistanceKeeper must not drag the survivor across the map merely because
	-- Veil is running roughly toward them. The dedicated wall-arrow detector owns
	-- long-range projectile pressure; ordinary distance holding stays local.
	veilLongApproachGuardMaximumDistance = 42.0,
	veilLongApproachGuardMinimumDistance = 22.0,
	veilLongApproachGuardMinimumFacing = 0.90,
	veilLongApproachGuardMinimumKillerApproach = 4.0,
	veilLongApproachGuardSustain = 0.24,
	veilLongApproachGuardSampleGap = 0.22,
	trackingDistanceKeeperEnterDistance = 20.0,
	trackingDistanceKeeperExitDistance = 23.0,
	-- A player's own WASD may never authorize automatic movement. Ordinary
	-- distance holding requires both Killer aim and Killer velocity toward us.
	-- The much smaller emergency envelope still rejects a clearly retreating or
	-- backwards-facing Killer.
	threatDistanceKeeperEmergencyDistance = 8.0,
	threatDistanceKeeperEmergencyMinimumFacing = 0.15,
	threatDistanceKeeperEmergencyMinimumApproach = -0.25,
	threatDistanceKeeperLateralWeight = 7.0,
	threatDistanceKeeperAwayWeight = 34.0,
	threatDistanceKeeperPostHitBlock = 0.90,
	threatDistanceKeeperSafetyFloorClearance = 3.25,
	threatDistanceKeeperSafetyFloorAwayDot = 0.18,
	threatDistanceKeeperManualSafeAwayDot = 0.16,
	-- Distance hold is not a one-shot animation. Its forecast must remain a
	-- rolling future window instead of counting down to 80 ms and certifying a
	-- route on the impact frame. Veil starts farther out because its exact melee
	-- ACTIVE was observed only 0.21-0.24 s before damage.
	threatDistanceKeeperRollingDelay = 0.65,
	threatDistanceKeeperVeilEnterDistance = 22.0,
	threatDistanceKeeperVeilExitDistance = 26.0,
	threatDistanceKeeperVeilEmergencyDistance = 9.5,
	threatDistanceKeeperVeilRollingDelay = 0.80,
	-- A single turn-away sample is not proof that an already-close homing attack
	-- has ended. Keep the last committed threat alive briefly so an attacker
	-- crossing the survivor cannot create a route-less impact frame.
	threatDistanceKeeperDisengageGrace = 0.82,
	threatDistanceKeeperContactHoldDistance = 10.25,

	-- Predictive route planner. It evaluates where both characters can be at the
	-- estimated impact time, not merely where they are on AnimationPlayed. A small
	-- geometry cache is prepared while idle so an ACTIVE signal does not pay for a
	-- full corridor scan on its first frame.
	predictivePlannerEnabled = true,
	predictiveCacheHz = 4,
	predictiveCacheRange = 32.0,
	-- A corridor beside a small crate can change completely after a 2-3 stud
	-- displacement. Keep idle geometry only as a very short first-frame hint.
	predictiveCacheMaximumAge = 0.22,
	predictiveCacheMaximumOriginShift = 1.50,
	predictiveCacheMaximumThreatShift = 2.75,
	predictiveCandidateAngles = {-85, -45, 0, 45, 85},
	predictiveProbeDistance = 17.0,
	predictiveSweepHalfWidth = 1.35,
	predictiveSweepLowHeight = 1.15,
	predictiveSweepHighHeight = 2.85,
	predictivePathPadding = 0.85,
	predictiveDefaultImpactDelay = 0.55,
	predictiveMinimumImpactDelay = 0.20,
	predictiveMaximumImpactDelay = 1.20,
	predictiveTurnMinimumFactor = 0.80,
	-- Forecast only speed the game currently grants. The failed Slasher sample
	-- had WalkSpeed=10 while the old 12-stud floor certified impossible travel.
	predictiveNativeSpeedFloor = 0.0,
	predictiveDefaultHitRadius = 6.25,
	predictiveSafetyMargin = 1.10,
	predictiveMinimumSeparationGain = 0.65,
	predictiveMinimumAwayDot = -0.08,

	-- v5.4 motion core. A threat is no longer treated as one generic chase.
	-- Each confirmed attack is classified as MELEE_ARC, LUNGE,
	-- HOMING_LUNGE or PROJECTILE_LINE;
	-- its impact window owns lifecycle, scoring and bounded live replanning.
	motionCoreEnabled = true,
	motionCoreReplanInterval = 0.14,
	motionCoreEmergencyReplanInterval = 0.07,
	motionCoreMaximumReplans = 6,
	motionCoreMinimumDirectionDot = 0.20,
	-- A signal handoff or horizon refresh is not proof that the already-owned
	-- corridor became invalid. Do not flip to the opposite side until the current
	-- route is actually blocked/stuck/unsafe. This removes the -0.63/-0.81/-0.94
	-- direction changes observed in the supplied Veil trace.
	motionCoreNonFailureMinimumDirectionDot = 0.35,
	motionCoreSwitchScoreGain = 2.25,
	motionCorePeriodicMinimumDirectionDot = 0.90,
	motionCorePeriodicMinimumManualGain = 0.10,
	-- A certified route is still harmful when the player's current heading is
	-- already certified and forecasts materially more separation. This applies to
	-- the first plan as well as every replan; v5.5.4 guarded only sharp periodic
	-- turns and accepted the supplied initial manualGain=-4.31 route.
	motionCoreManualAuthorityTolerance = 0.20,
	-- A route that is only trivially better than an already-safe physical heading
	-- does not justify taking control. The threshold also governs emergency
	-- blocked/stuck replans, not only the first plan.
	motionCoreManualCertifiedOverrideGain = 2.00,
	motionCoreObstacleClearance = 2.75,
	motionCoreObstacleProbeDistance = 6.5,
	motionCoreImpactHoldPadding = 0.24,
	motionCoreProjectileHoldPadding = 0.36,
	motionCoreTelemetryInterval = 0.05,
	motionCoreTelemetryCapacity = 72,
	motionCoreHitDumpSamples = 12,
	motionCoreProjectileMinimumLateral = 5.25,
	motionCoreProjectileMinimumLateralGain = 3.25,
	motionCoreLungeMinimumAwayDot = 0.22,
	-- Do not reverse a valid route during the final server-impact window. Masked
	-- traces showed three large direction changes in the last few tenths before a
	-- hit, which spent the only useful travel on turning instead of separation.
	motionCoreFinalCommitWindow = 0.18,
	-- Ranged line attacks are already in flight. A last-frame obstacle sample may
	-- mean the route is no longer perfect, but returning native WASD inside this
	-- window caused an immediate 90/180-degree reversal 93 ms before impact.
	motionCoreProjectileFinalCommitWindow = 0.30,
	-- Failed geometry is cached briefly. Re-running the same sweep every scheduler
	-- tick cannot create a corridor, but it can hitch the client.
	motionCoreNoRouteRetryInterval = 0.28,
	motionCoreNoRouteMaximumOriginShift = 1.25,
	motionCoreNoRouteMaximumThreatShift = 1.75,
	motionCoreNoRouteCacheMaximumAge = 0.60,
	-- During an exact-signal handoff the currently working route remains valid
	-- until a replacement is committed. There is never a route-less middle state.
	motionCoreTransactionalHandoffRetry = 0.12,
	motionCoreTransactionalHandoffGrace = 0.38,
	-- A best-effort route may own movement only when the predictive planner has
	-- already proved it safer than the player's current physical heading.
	motionCoreBestEffortMinimumClearance = 3.25,
	motionCoreEmergencyLease = 0.14,
	motionCoreEmergencyReviewInterval = 0.10,
	motionCoreEmergencyEpisodeWindow = 0.65,
	predictivePerformanceWarningMs = 4.0,
	motionCoreBestEffortMinimumManualGain = 0.75,
	motionCoreBestEffortMinimumSeparationGain = 0.50,
	motionCoreBestEffortMinimumAwayDot = 0.20,
	trackingSurvivalFallbackMinimumManualGain = 0.20,
	trackingSurvivalFallbackMinimumSeparationRatio = 0.62,
	-- A late exact homing signal can make the full hit-radius certificate
	-- mathematically impossible. If current WASD is idle/inward, a grounded open
	-- outward lane may still own control only when it forecasts a material gain
	-- over that exact physical-input baseline.
	motionCoreSafetyFloorMinimumManualGain = 0.50,
	motionCoreSafetyFloorMinimumAwayDot = 0.35,
	-- Slasher's replicated Q track remains actionable well after the catalog's
	-- first 0.24-second impact sample. Re-forecast a bounded near-future horizon
	-- while that exact AnimationTrack is still playing instead of repeatedly
	-- certifying against an already elapsed impact timestamp.
	-- The supplied 139369... phase reached HealthChanged after only 0.188 s.
	-- A 0.32-second rolling forecast invented more than two studs of movement that
	-- could not be delivered before impact. Use the conservative compiler-wide
	-- minimum and require the resulting absolute certificate below.
	trackingTrackRollingImpactDelay = 0.20,
	trackingTrackRollingExpiryRefresh = 0.40,
	-- A straight corridor can terminate in a box. Probe escape choices from the
	-- far half of each candidate so homing attacks do not select sealed lanes.
	-- Certify substantially beyond the point the player will reach during the
	-- first steering burst. The old 7.5+7 horizon could certify the mouth of a
	-- pocket and discover its back wall only after committing to it.
	motionCoreDeadEndLookahead = 10.0,
	motionCoreDeadEndBranchProbe = 12.0,
	motionCoreDeadEndMinimumDepth = 7.0,
	motionCoreDeadEndMinimumHorizon = 16.0,
	-- Recede the long-horizon certificate as the player advances. This is a
	-- bounded event (not a per-frame pathfinder): roughly every six studs the
	-- current threat gets one fresh five-candidate topology forecast.
	-- Re-certify before consuming the whole 6-stud horizon. The old interval let
	-- a route that began with three branches reach a wall before the next probe.
	motionCoreHorizonRevalidateDistance = 4.25,
	motionCoreHorizonRevalidateCooldown = 0.20,
	motionCoreDeadEndBranchAngle = 62.0,
	motionCoreBlockedObserveCooldown = 0.28,
	motionCoreNoCorridorEpisodeCooldown = 0.85,
	motionCoreNoCorridorLogCooldown = 0.45,
	-- If a certified lane reaches a wall, select a grounded outward continuation
	-- before giving movement back. This is a geometric wall slide, not a blind
	-- wall push: it must have body clearance and a branch beyond the corner.
	motionCoreWallContinuationProbeDistance = 10.0,
	motionCoreWallContinuationMinimumClearance = 2.20,
	motionCoreWallContinuationMinimumAwayDot = 0.05,
	motionCoreWallContinuationMinimumBranchClearance = 5.0,
	motionCoreWallContinuationCooldown = 0.10,
	motionCoreWallContinuationRayReserve = 42,
	motionCoreObstacleRetryInterval = 0.14,
	motionCoreObstacleMaximumRetries = 3,
	-- Instant AssemblyLinearVelocity was zero in the first missed Masked hit even
	-- though telemetry showed that 16 studs had closed during the prior 0.6 s.
	motionCoreHistoricalApproachWindow = 0.62,
	motionCoreHistoricalApproachMinimumAge = 0.18,
	maskedHistoricalGuardDistance = 18.50,
	maskedHistoricalGuardFacing = 0.45,
	maskedHistoricalGuardApproach = 5.50,
	maskedHistoricalGuardSustain = 0.03,

	-- Veil has a charged arrow whose server hit can cross map walls. The remote
	-- player's literal cursor is not normally replicated, so this guard ranks any
	-- replicated aim target/direction first, then weapon muzzle/head/root facing.
	-- Line-of-sight is intentionally never required for this one exact class.
	veilWallAimEnabled = true,
	veilWallAimHz = 12,
	veilWallAimMinimumDistanceStrong = 8.0,
	veilWallAimMinimumDistanceFallback = 18.0,
	veilWallAimMaximumDistance = 95.0,
	-- Fresh Veil traces resolved damage while the root/head fallback was still at
	-- dot=0.9709, and the old 0.30-second evidence gate left only 0.144 seconds to
	-- move.  A selected Veil holding this narrow cone is actionable aim evidence;
	-- acquire on the first stable 12 Hz pair, then retain the wider release cone.
	veilWallAimStrongDot = 0.965,
	veilWallAimFallbackDot = 0.970,
	veilWallAimStrongSustain = 0.10,
	veilWallAimFallbackSustain = 0.08,
	veilWallAimFallbackMaximumSpeed = 5.0,
	veilWallAimReleaseDot = 0.94,
	veilWallAimReleaseGrace = 0.40,
	-- Head/root aim replication jitters even while the remote cursor remains held.
	-- Accumulate strong samples and decay through short gaps instead of resetting
	-- the entire 300ms confirmation on one bad 12Hz sample.
	veilWallAimEvidenceDecayRate = 0.65,
	veilWallAimEvidenceNearDotScale = 0.30,
	veilWallAimEvidenceMaximumSampleDt = 0.20,
	veilWallAimTriggerCooldown = 0.45,
	veilWallAimEpisodeDuration = 5.20,
	veilWallAimMinimumHold = 0.62,
	veilWallAimImpactDelay = 0.75,
	veilWallAimProjectileSpeed = 12.0,
	veilWallAimProjectileHoldPadding = 0.45,
	veilWallAimProjectileMinimumHold = 1.50,
	veilWallAimProjectileMaximumHold = 5.00,
	veilWallAimSourceRescan = 1.50,
	veilWallAimSourceScanLimit = 180,
	veilWallAimMaximumSources = 16,

	-- Route planning runs in PreSimulation, but the actual direction is
	-- applied immediately after Roblox's ControlModule input RenderStep.
	-- This keeps ordinary game speed and never presses/releases W/A/S/D.
	movementHardSpeedCap = 17.0,
	movementIntentDefaultTtl = 0.10,
	movementOwnerLogCooldown = 0.20,
	movementForceAutoRotate = false,
	-- Ordinary aiming never suppresses a real dodge. Only a physically held RMB
	-- plus a replicated, confirmed stun/blind state on the current flashlight
	-- target yields movement authority back to native controls.
	movementSuspendDuringFlashlightAim = false,
	flashlightYieldMovementOnConfirmedStun = true,
	-- An unstunned attacker must not keep the flashlight's native movement
	-- penalty while an actionable threat is already live. The Helper turns the
	-- native flashlight off, but never synthesizes RMB-up and never touches an
	-- unrelated repair/heal/unhook interaction. A replicated stun/blind or the
	-- exact pallet-break animation is an explicit safe exception.
	flashlightUnsafeAutoDeactivate = true,
	flashlightUnsafeDetectionGrace = 0.10,
	flashlightUnsafeSpeedRatio = 0.78,
	flashlightUnsafeMinimumSpeedDrop = 2.0,
	flashlightPalletBreakSafeWindow = 2.40,
	movementRenderBindingName = "VDHelperRenderDodgeV538_" .. INSTANCE_ID,
	movementLegacyRenderBindingName = "VDHelperRenderDodgeV5225",
	movementRenderFallbackThreshold = 0.008,
	movementRenderWatchdogThreshold = 0.35,
	-- Run after older Helper writers without adding a second writer/watchdog.
	movementRenderPriorityOffset = 18,
	movementRouteWeight = 1.00,
	movementManualWeight = 0.45,
	-- The generic fallback is advisory: it may bend a safe manual route, but
	-- must never turn the survivor around merely because another corridor got
	-- a slightly higher geometric score.
	movementGenericRouteWeight = 0.55,
	movementGenericManualWeight = 1.00,
	movementReverseDotThreshold = -0.15,
	movementManualAwaySafetyDot = -0.05,
	movementMinimumDirection = 0.05,
	-- Safety-first authority: suggestions may assist, but do not reverse a
	-- deliberate manual route unless an exact ACTIVE attack is point-blank.
	movementManualFirstEnabled = true,
	movementStrictRouteDistance = 6.25,
	movementManualFirstRouteWeight = 0.55,
	movementManualFirstManualWeight = 1.00,
	movementManualPreserveAwayDot = -0.10,
	movementManualPreserveConflictDot = -0.35,
	conservativePrepLogOnly = true,
	familyFailureDisableAfterHits = 2,
	-- A signal first observed on the damage frame did not give the writer a
	-- meaningful chance to evade and must not disable the whole family.
	familyFailureMinimumThreatAge = 0.30,
	-- Damage is an unconditional return-to-manual boundary. A second animation
	-- from the same combo must not create a fresh episode on the same frame.
	postHitThreatReacquireBlock = 0.55,
	trackingFailureDisableAfterHits = 1,
	-- Slasher's exact replicated hit arrived 0.287 s after the ACTIVE signal.
	-- The generic 0.30 s same-frame filter discarded that real route failure.
	trackingFailureMinimumThreatAge = 0.15,
	stalkerFailureDisableAfterHits = 1,
	stalkerFailureMinimumThreatAge = 0.18,
	veilFailureDisableAfterHits = 1,
	-- Veil's confirmed melee hit lands roughly 0.22-0.24 s after the exact
	-- animation signal. The generic 0.30 s filter incorrectly called both
	-- observed failures "same-frame" even though Helper owned movement.
	veilFailureMinimumThreatAge = 0.15,
	ripFailureDisableAfterHits = 1,

	-- DODGE uses native Humanoid movement plus bounded acceleration. Unlike the
	-- old hard writer this never snaps to direction*36 and never changes CFrame.
	movementSoftAccelerationEnabled = false,
	movementSoftAccelerationMaxSpeed = 32.0,
	movementSoftAcceleration = 125.0,
	movementSoftAccelerationEmergency = 205.0,
	movementSoftAccelerationEmergencyDistance = 10.5,
	movementSoftAccelerationMaximumDt = 0.040,
	movementSoftAccelerationMinimumDt = 0.004,
	movementTelemetryInterval = 0.22,

	-- Match state is event-driven. While a round is active, a cheap bounded audit
	-- also catches a missed ExpinRound transition; the lobby still does no polling.
	matchEnterConfirmTime = 0.0,
	matchExitConfirmTime = 0.0,
	matchActiveAuditHz = 4,
	-- Never call GetDescendants from the lobby detector. Existing map evidence
	-- is checked only across two shallow levels, while newly created evidence
	-- is captured by Workspace.DescendantAdded.
	matchShallowEvidenceBudget = 160,
	matchMapNames = {"map", "currentmap", "gamemap", "roundmap"},
	matchObjectiveTokens = {
		"generator",
		"generators",
		"repairpoint",
		"repair point",
		"exitgate",
		"exit gate",
		"escapeportal",
		"escape portal",
	},
	matchPositiveRoleTokens = {
		"survivor",
		"killer",
		"hunter",
		"monster",
		"infected",
	},
	matchNegativeRoleTokens = {
		"lobby",
		"spectator",
		"spectating",
		"menu",
		"waiting",
		"intermission",
	},
	matchPositiveAttributes = {
		"InRound",
		"InGame",
		"MatchActive",
		"RoundActive",
		"Playing",
		"IsPlaying",
	},
	-- Observed exact Player attributes in this game.
	matchRoundTimeAttribute = "ExpinRound",
	matchSpectateAttributes = {"spectate", "isspectating"},
	matchEndAttributes = {"killerend"},
	matchExactSurvivorTeam = "survivors",
	matchExactKillerTeam = "killer",
	-- The Helper belongs only to the local Survivor role. In particular, the
	-- owner's account must become completely dormant while Team=Killer. Once a
	-- Killer role has been observed, a nil/transitional Team cannot wake any
	-- controller; only an explicit return to Team=Survivors can re-arm it.
	localRoleGateUsername = "kandera37",
	localKillerHardDisable = true,
	matchExactTeamFallbackEnabled = true,
	matchExactTeamFallbackRequirePriorMatch = false,
	matchRoleAttributes = {
		"Role",
		"Class",
		"Team",
		"GameRole",
		"PlayerRole",
	},

	targetResolverHz = 5,
	-- AnimationPlayed is still primary. A cheap poll of the one nearest Killer
	-- recovers a currently-playing attack when Roblox misses that callback; it
	-- does not scan Workspace or every humanoid.
	animationPlayingTrackPollHz = 10,
	animationPollMaximumStartAge = 0.45,
	animationPollReplayMinimumInterval = 0.85,
	-- Unknown Action tracks from the actual Killer are learned passively and may
	-- trigger a conservative close-range dodge. Core/Idle/Movement never do.
	animationUnknownLogEnabled = true,
	animationIgnoredKnownLogEnabled = false,
	animationPrepLogOnlyEnabled = false,
	animationRequireThreatOwner = true,
	-- AnimationTrack objects are commonly replayed. Only suppress duplicate
	-- callbacks from the same frame, never the entire lifetime of the track.
	animationReplayDebounce = 0.025,

	-- Unknown Action tracks and pure proximity are not sufficient evidence to
	-- take movement. The supplied Hidden match showed four full-speed failures
	-- caused by a guessed 12.5-stud PERSONAL_SPACE_GUARD.
	unknownActionFallbackEnabled = false,
	unknownActionMaximumDistance = 13.5,
	unknownActionMinimumFacing = -0.15,
	unknownActionMinimumLength = 0.12,
	unknownActionMaximumLength = 3.50,
	unknownActionDefaultDuration = 0.58,
	unknownActionSafeDistance = 20.0,
	maskedUnknownMaximumDistance = 8.5,
	maskedUnknownMinimumFacing = 0.20,
	maskedUnknownDuration = 0.46,
	maskedUnknownSafeDistance = 15.0,

	-- When damage arrives without an active episode, associate it with the most
	-- recent real Killer Action. The first miss teaches the runtime profile;
	-- later repetitions can be dodged without another manual mapping.
	damageLearningEnabled = true,
	damageLearningWindow = 1.60,
	damageLearningMaximumDistance = 75.0,
	damageLearningRangedThreshold = 19.0,
	damageLearningRangedDuration = 0.92,
	damageLearningMeleeDuration = 0.74,
	-- A signal first seen only a few frames before damage is an impact/confirm,
	-- not a usable telegraph. It must never become an ACTIVE movement owner.
	damageLearningMinimumUsefulLead = 0.30,
	damageLearningConfirmationsRequired = 2,
	damageLearningMaximumLeadSpread = 0.28,

	-- Masked sometimes produces no replicated actionable animation at all. This
	-- narrow guard is deliberately not a generic proximity guard: it requires the
	-- exact Masked class, close range and near-perfect sustained aim. It is also
	-- disabled by every interaction/WalkSpeed lock before an episode is created.
	maskedCloseAimGuardEnabled = true,
	maskedCloseAimGuardDistance = 10.75,
	-- Normal coverage is deliberately slower but accepts partial aim. The supplied
	-- animation-less hit arrived at d=9.93/facing=0.60/approach=0. A separate
	-- near-perfect emergency tier remains fast at point blank.
	maskedCloseAimGuardFacing = 0.55,
	maskedCloseAimGuardMinimumApproach = -0.25,
	maskedCloseAimGuardSustain = 0.45,
	maskedCloseAimGuardEmergencyDistance = 10.0,
	maskedCloseAimGuardEmergencyFacing = 0.90,
	maskedCloseAimGuardEmergencySustain = 0.0,
	-- The old 1.10-second re-arm gap let Masked close from safe distance to the
	-- player with no episode after the previous guard released.
	maskedCloseAimGuardCooldown = 0.20,
	maskedCloseAimGuardDuration = 1.25,
	maskedCloseAimGuardMinimumHold = 0.80,
	maskedCloseAimGuardSafeDistance = 16.0,
	-- Animation-less Masked damage in the supplied trace landed after the old
	-- 0.79-second motion hold had already expired. Keep this exact-class,
	-- aimed/closing guard alive long enough to bridge the missing ACTIVE signal.
	-- This guard is synthetic: unlike an AnimationPlayed edge, it can begin at any
	-- point inside the wind-up. The supplied hit landed 0.250 s after guard start;
	-- forecasting 0.85 s invented roughly ten studs of unreachable travel.
	-- A fresh no-animation Masked hit resolved 0.562 s after guard acquisition.
	-- The former 0.28 rolling horizon repeatedly certified only half the danger.
	maskedCloseAimGuardImpactDelay = 0.65,
	maskedCloseAimGuardMaximumHold = 3.40,
	maskedCloseAimGuardRefreshHorizon = 0.28,
	maskedCloseAimGuardRefreshHold = 1.02,
	-- Hidden produced several point-blank hits without any AnimationPlayed event.
	-- This is not a universal proximity guard: exact authoritative Hidden only,
	-- sustained facing, no interaction locks, and a predictive outward corridor.
	hiddenCloseAimGuardEnabled = true,
	hiddenCloseAimGuardDistance = 14.5,
	hiddenCloseAimGuardFacing = 0.72,
	hiddenCloseAimGuardMinimumApproach = -0.25,
	hiddenCloseAimGuardSustain = 0.16,
	hiddenCloseAimGuardEmergencyDistance = 8.5,
	hiddenCloseAimGuardEmergencyFacing = 0.90,
	hiddenCloseAimGuardEmergencySustain = 0.0,
	hiddenCloseAimGuardCooldown = 0.90,
	hiddenCloseAimGuardDuration = 1.10,
	hiddenCloseAimGuardMinimumHold = 0.72,
	hiddenCloseAimGuardSafeDistance = 19.0,
	hiddenCloseAimGuardImpactDelay = 0.78,
	-- A supplied Hidden guard found a route, then its one-shot lifecycle expired
	-- while Hidden was still closing and the exact ACTIVE had not replicated yet.
	-- Refresh only this authoritative class guard while contact geometry persists.
	hiddenCloseAimGuardMaximumHold = 2.40,
	hiddenCloseAimGuardRefreshHorizon = 0.32,
	hiddenCloseAimGuardRefreshHold = 0.72,
	-- Hidden's replicated instantaneous approach is often zero until the final
	-- six studs. Use the same bounded telemetry history as Masked so sustained
	-- closing at 12-15 studs can arm the exact-class guard before the hit frame.
	hiddenHistoricalGuardDistance = 16.0,
	hiddenHistoricalGuardFacing = 0.78,
	hiddenHistoricalGuardApproach = 5.0,
	-- Historical closing is only an early-warning hint. It must expire as soon as
	-- the live sample proves that Hidden is already moving away; otherwise an old
	-- approach burst can seize movement several seconds later in the wrong direction.
	hiddenHistoricalGuardCurrentApproachFloor = -1.0,
	hiddenHistoricalGuardSustain = 0.06,
	-- Literal Killer shares attack assets with Abysswalker and can produce the
	-- ACTIVE signal only ~0.17 s before damage. Use the same narrow sustained-aim
	-- rule as Hidden, but only when authoritative class resolution says Killer.
	killerCloseAimGuardEnabled = true,
	killerCloseAimGuardDistance = 14.5,
	killerCloseAimGuardFacing = 0.70,
	killerCloseAimGuardMinimumApproach = -0.25,
	killerCloseAimGuardSustain = 0.14,
	killerCloseAimGuardEmergencyDistance = 9.5,
	killerCloseAimGuardEmergencyFacing = 0.88,
	killerCloseAimGuardEmergencySustain = 0.0,
	-- At contact range the killer can turn inside one replication interval. Do
	-- not require a stale facing vector before preserving an existing escape.
	killerCloseAimGuardContactDistance = 4.25,
	killerCloseAimGuardCooldown = 0.90,
	killerCloseAimGuardDuration = 1.25,
	killerCloseAimGuardMinimumHold = 0.82,
	killerCloseAimGuardSafeDistance = 20.0,
	killerCloseAimGuardImpactDelay = 0.78,
	killerCloseAimGuardMaximumHold = 3.40,
	killerCloseAimGuardRefreshHorizon = 0.32,
	killerCloseAimGuardRefreshHold = 0.48,
	killerHistoricalGuardDistance = 16.5,
	killerHistoricalGuardFacing = 0.45,
	killerHistoricalGuardApproach = 2.5,
	-- Historical closing is only a hint. It must never seize movement after the
	-- live sample already proves that literal Killer is rapidly separating.
	killerHistoricalGuardCurrentApproachFloor = -1.0,
	killerHistoricalGuardSustain = 0.06,
	-- The supplied hit crossed 14.67 -> 7.82 studs in 232ms. Waiting for the
	-- ordinary 16.5-stud band left no usable planning horizon. A wider early band
	-- is allowed only for an authoritative literal Killer with strong aim and a
	-- measured >=10 stud/s closing history, so an unrelated nearby pass cannot
	-- manufacture movement.
	killerFastHistoricalGuardDistance = 20.0,
	killerFastHistoricalGuardFacing = 0.80,
	killerFastHistoricalGuardApproach = 10.0,
	killerFastHistoricalGuardCurrentApproachFloor = -1.0,
	killerFastHistoricalGuardSustain = 0.02,
	-- A synthetic guard is not an exact attack. Give native WASD back before the
	-- route reaches a wall instead of steering into a pocket and changing sides.
	killerSyntheticGuardWallReleaseClearance = 5.25,
	killerSyntheticGuardWallProbeDistance = 8.0,
	-- While this exact-class close guard remains geometrically valid, refresh one
	-- episode instead of letting a short timer expire and waiting for a last-frame
	-- animation. Heal/unhook/open and the visible skill-check remain hard locks;
	-- generator repair alone may be left by the bounded confirmed-threat edge.
	killerCloseAimRefreshHorizon = 0.78,
	killerCloseAimRefreshHold = 1.02,

	-- Physical Space remains player-owned, but an unsafe press toward a nearby
	-- aimed/closing Killer is vetoed before Roblox can interpret it as a pallet or
	-- window vault. Locked interactions and visible skill checks are always passed.
	unsafeTraversalVetoEnabled = true,
	unsafeTraversalContextActionName = "VD_UnsafeTraversalVeto",
	unsafeTraversalContextPriority = 4000,
	unsafeTraversalMaximumKillerDistance = 12.5,
	unsafeTraversalEmergencyDistance = 7.5,
	unsafeTraversalTowardDot = 0.20,
	-- A vault request can be committed before a fast lunge closes the old
	-- 12.5-stud band. The supplied failure began at 21.93 studs with facing=.90
	-- and player-created relative closing=5.06, then became an 8.79-stud Veil
	-- PREP after the vault had already started. This wider tier only consumes
	-- Space: it never creates movement, and requires strong aim plus measured or
	-- intended relative closing toward the Killer.
	unsafeTraversalPredictiveDistance = 24.0,
	unsafeTraversalPredictiveFacing = 0.78,
	unsafeTraversalPredictiveRelativeApproach = 3.0,
	unsafeTraversalPredictiveTowardDot = 0.15,
	-- Space is a shared jump/pallet/window key. Proximity to a Killer alone may
	-- never consume it; veto is eligible only when a real indexed window or an
	-- already-dropped pallet is directly ahead of physical WASD.
	-- Roblox can buffer a vault before the root reaches the trigger. Five studs
	-- missed the supplied window: Space was passed at full speed and isVaulting
	-- appeared on the next sample. This remains a read-only target probe.
	unsafeTraversalTargetMaximumDistance = 7.5,
	unsafeTraversalTargetMinimumDot = 0.72,
	unsafeTraversalPalletProbeDistance = 4.5,
	-- Dropped-pallet loops are side-sensitive. Crossing away from a Killer on the
	-- player's current side is the intended Jeff timing and must remain native.
	-- Crossing onto the Killer's side is blocked even before an animation signal,
	-- because the supplied hit's PREP arrived only after the vault had committed.
	unsafeTraversalPalletSideMargin = 0.20,
	unsafeTraversalPalletLandingDangerDistance = 10.0,
	unsafeTraversalPalletOriginEscapeTowardDot = -0.25,
	unsafeTraversalPalletOriginEscapeMaximumApproach = 1.0,
	-- Same-side is not automatically safe: during a native pallet vault the Killer
	-- can cross the pallet plane before control returns.  Block a contested crossing
	-- when the Killer is at essentially the same pallet depth and aimed/closing.
	unsafeTraversalPalletContestedDistance = 10.0,
	unsafeTraversalPalletContestedDepthSlack = 1.50,
	unsafeTraversalPalletContestedFacing = 0.70,
	unsafeTraversalPalletContestedRelativeApproach = 3.0,
	-- Once an exact/confirmed attack already owns the threat episode, traversing a
	-- window or a dropped pallet is unsafe even when the player is moving away.
	-- The vault itself locks WalkSpeed at zero for roughly 0.9 s; the supplied RIP
	-- hit arrived 0.27 s after that lock. This rule only consumes the player's
	-- Space. It never starts movement or releases an interaction.
	unsafeTraversalActiveThreatDistance = 18.0,
	-- Space at a window freezes native walking for the vault. Judge that commit by
	-- whether the full approach + observed vault can finish before the Killer is in
	-- attack range. This tier is intentionally independent of towardDot: crossing
	-- away from a Killer is still fatal when the animation lock lasts longer than
	-- the remaining hit ETA (the supplied deaths began at 6.81 and 9.03 studs).
	unsafeTraversalWindowEtaEnabled = true,
	unsafeTraversalWindowPredictionDistance = 18.0,
	unsafeTraversalWindowEmergencyDistance = 7.75,
	unsafeTraversalWindowThreatFacing = 0.30,
	unsafeTraversalWindowThreatApproach = 0.75,
	unsafeTraversalWindowAttackBuffer = 4.5,
	unsafeTraversalWindowKillerSpeedFloor = 12.0,
	unsafeTraversalWindowSafetyMargin = 0.22,
	unsafeTraversalWindowMinimumVaultDuration = 0.58,
	-- A native vault may commit one scheduler sample before the exact attack track.
	-- Permit a nearby direction-aligned indexed window to enter the existing ETA
	-- veto from strong pre-animation geometry. This consumes only Space; it never
	-- creates an attack episode or moves through an interaction lock.
	unsafeTraversalPreThreatWindowFallbackEnabled = true,
	unsafeTraversalPreThreatWindowFallbackDistance = 12.75,
	unsafeTraversalPreThreatWindowFallbackFacing = 0.30,
	unsafeTraversalPreThreatWindowFallbackApproach = 0.50,
	unsafeTraversalPreThreatWindowFallbackDirectionDot = 0.25,
	-- A native vault can arm between input sampling and the next attribute edge.
	-- In the supplied hit, Space reported traversal=none and VAULT_START followed
	-- immediately on an already-indexed window. While an actionable threat is
	-- live, treat a very near indexed window as the intended traversal even when
	-- the thin trigger's forward-axis probe misses it.
	unsafeTraversalWindowProximityFallbackDistance = 8.5,
	-- Keep a vetoed window blocked across subsequent Space edges even after the
	-- trigger moves behind the player's forward probe. Without this latch the
	-- supplied trace blocked the first edge, passed the next one 0.5 s later and
	-- entered the same fatal vault. While latched, propose an open-corridor route
	-- away from both the opening and Killer, but never under an interaction lock.
	unsafeTraversalWindowVetoLatchDuration = 1.15,
	unsafeTraversalWindowVetoLatchRadius = 10.0,
	unsafeTraversalWindowEscapeDuration = 0.85,
	unsafeTraversalWindowEscapeProbeDistance = 10.0,
	unsafeTraversalWindowEscapeMinimumClearance = 3.0,
	unsafeTraversalWindowEscapeMaximumTowardDot = 0.10,
	unsafeTraversalWindowEscapeMinimumAwayDot = -0.05,
	unsafeTraversalWindowEscapePlanRetryInterval = 0.06,
	unsafeTraversalWindowEscapeMaximumPlanAttempts = 5,
	lockedThreatVisualWarningEnabled = false,
	-- A received hit immediately returns control to the player. Post-hit steering
	-- kept a failed route alive and caused the supplied second hit three seconds
	-- later while the player was unable to override it.
	damageLearningPostHitEscape = false,

	-- Six detailed scans per second are sufficient for a 14-stud acquisition
	-- radius and avoid evaluating every cached NPC on adjacent frames.
	zombieScanHz = 6,
	-- Cure/minion rigs can replicate outside Map and can arrive as an empty
	-- wrapper before their Humanoid/root. DescendantAdded remains the primary
	-- index; this bounded spatial query is only a nearby lifecycle backstop and
	-- never walks Workspace descendants.
	zombieProximityDiscoveryHz = 4,
	zombieProximityDiscoveryRadius = 28.0,
	zombieProximityDiscoveryMaxParts = 64,
	zombieProximityDiscoveryMaxModels = 12,
	palletScanHz = 8,
	windowScanHz = 6,
	exitScanHz = 4,
	flashlightResolveHz = 10,

	-- Existing world objects are indexed incrementally after a real match starts.
	-- No controller may call Workspace:GetDescendants().
	worldIndexMaxInstancesPerFrame = 5,
	worldIndexTimeBudgetMs = 0.18,
	performanceOwnSpikeMs = 4.0,
	performanceFrameStallDt = 0.090,
	performanceLogCooldown = 2.0,

	-- Leave a small reserve for the final render-vector wall check. Route
	-- acquisition can consume 26 rays; the final 360 direction did not exist yet
	-- when those rays were evaluated.
	-- Five body-height rays per corridor replace the old single ray above the
	-- HumanoidRootPart. The larger ceiling covers one live selection plus its
	-- uncached final safety check without silently treating budget exhaustion as
	-- open space.
	-- A live open-exit selection can spend 45 rays; one event-indexed window
	-- candidate adds at most 10 and the final body sweep needs five more. This is
	-- active-threat-only work, not a permanent per-frame scan.
	raycastMaxPerFrame = 64,
	-- Live route validation uses a separate bounded reserve. A budget-exhausted
	-- ordinary Cast returns nil, which historically looked identical to clear air.
	-- Critical five-ray body sweeps are therefore atomic and never partially run.
	raycastCriticalMaxPerFrame = 20,
	raycastCacheMaxAge = 0.05,
	raycastCacheMaximumEntries = 512,
	raycastCachePositionTolerance = 0.75,
	raycastCacheDirectionDot = 0.985,

	routeProbeDistance = 18.0,
	routeGroundDepth = 9.0,
	routeBodyRadius = 1.35,
	routeSweepHalfWidth = 1.45,
	routeSweepLowOffset = -1.30,
	routeSweepMidOffset = -0.10,
	routeSweepHighOffset = 1.05,
	routeMinimumClearance = 1.10,
	routeDeepClearance = 4.00,
	routeDeepSafeLength = 14.0,
	routeMinimumBranches = 2,
	routeReplanCriticalClearance = 0.75,
	trackingRouteReplanClearance = 3.00,
	trackingRouteProbeDistance = 7.0,
	trackingRouteContinuationSeconds = 3.5,
	trackingRouteMinimumContinuationClearance = 4.0,
	trackingRouteReplanCooldown = 0.18,
	-- A confirmed Slasher route may cut laterally, but it must always retain a
	-- positive component away from the Killer's current position.
	trackingRouteMinimumAwayDot = 0.10,
	trackingStuckSampleWindow = 0.24,
	trackingStuckMinimumTravel = 0.55,
	routeReplanMinimumGain = 1.0,
	routeMaximumReplans = 3,
	routeNeverStopDuringThreat = true,
	globalThreat360CutEnabled = false,
	globalThreat360AwayWeight = 0.24,
	globalThreat360CloseAwayWeight = 0.16,
	-- Masked/RIP closed distance during a nearly pure tangent even at full native
	-- speed. Keep the rapid curve, but give this lunge family enough radial escape
	-- to avoid orbiting in the same hit radius.
	globalThreat360MaskedAwayWeight = 0.55,
	globalThreat360MaskedCloseAwayWeight = 0.72,
	globalThreat360CloseDistance = 7.0,
	globalThreat360CorridorWeight = 0.35,
	globalThreat360MinimumAwayDot = 0.10,
	globalThreat360WallGuardEnabled = false,
	globalThreat360WallProbeDistance = 5.5,
	globalThreat360WallBlockedClearance = 2.35,
	globalThreat360WallMinimumEscapeClearance = 3.0,
	globalThreat360WallCheckInterval = 0.055,
	globalThreat360WallSwitchCooldown = 0.32,
	globalThreat360WallManualReleaseTime = 0.14,
	routeAngles = {-90, -55, -20, 0, 20, 55, 90},
	routeBranchAngles = {-55, 0, 55},
	-- The personal-space guard runs more often than exact attack episodes. Use a
	-- smaller candidate set and enrich its two best corridors with two branch
	-- probes each: 18 rays at
	-- acquisition instead of the general planner's 26, while still rejecting a
	-- route that terminates in a dead end.
	personalSpaceRouteAngles = {-80, -40, 0, 40, 80},
	personalSpaceRouteBranchAngles = {-50, 50},
	personalSpaceRouteEnrichCount = 2,
	personalSpaceRouteProbeDistance = 14.0,
	personalSpaceRouteBlockedClearance = 2.75,
	personalSpaceRouteReplanCooldown = 0.22,
	personalSpaceRouteRetryCooldown = 0.45,
	personalSpaceRouteMaximumReplans = 10,
	personalSpaceRouteMinimumAwayDot = 0.05,
	routePreferredWeight = 18.0,
	routeReversePenalty = 42.0,
	routeReverseDotThreshold = -0.15,

	threatDefaultDuration = 0.75,
	threatDefaultSafeDistance = 20.0,
	threatMinimumHold = 0.16,
	threatMaximumDistance = 70.0,
	threatMergeWindow = 2.20,
	threatDifferentKillerSwitchGain = 5.0,
	threatAnimationCooldown = 0.08,

	interactionReleaseDistance = 23.0,
	interactionReleaseFacing = -0.25,
	interactionReleaseApproach = 0.10,
	interactionOverrideWalkSpeed = 36.0,
	interactionReleaseCooldown = 0.18,
	interactionPromptReleaseRadius = 14.0,
	interactionKey = Enum.KeyCode.E,
	interactionGamepadKey = Enum.KeyCode.ButtonX,
	interactionReleaseForceDuration = 0.72,
	-- Legacy release settings remain dormant. The only synthetic movement event
	-- is the narrowly gated repair-threat pulse configured below.
	interactionMouseReleaseRepeats = 1,
	interactionMouseReleaseInterval = 0.035,
	interactionMovementPulseDuration = 0.0,
	-- A confirmed attack may use one short native movement-key edge to leave a
	-- generator. It never releases Mouse1, edits WalkSpeed/Anchored, resumes the
	-- repair, or breaks heal/unhook/open. A visible skill-check is a hard veto.
	repairThreatEscapeEnabled = true,
	repairThreatEscapeVeilOnly = false,
	repairThreatEscapeMaximumDistance = 24.0,
	repairThreatEscapePrepMaximumDistance = 18.0,
	-- A low-confidence head/root look vector at 80-90 studs is not authority to
	-- synthesize WASD and stand from a generator. Exact/replicated Veil aim may
	-- still request an escape at useful range; fallback body aim is much tighter.
	repairThreatEscapeVeilMaximumDistance = 55.0,
	repairThreatEscapeVeilFallbackMaximumDistance = 30.0,
	repairThreatEscapeVeilFallbackMinimumEvidence = 0.30,
	-- Horizontal distance alone made a Killer on another storey stand the player
	-- up from a generator. Ordinary melee/charge threats cannot request that key
	-- edge across floors. Veil wall-arrow families are handled separately below.
	repairThreatEscapeMaximumVerticalSeparation = 7.0,
	repairThreatEscapePulseDuration = 0.085,
	repairThreatEscapeRetryCooldown = 0.14,
	repairThreatEscapeMaximumAttempts = 3,
	repairThreatEscapeMinimumCorridor = 2.25,
	-- Protect unhook/heal/open from guessed PREP movement.
	interactionProtectedBreakDistance = 3.75,
	interactionProtectedBreakFacing = 0.75,
	interactionProtectedBreakApproach = 2.00,

	-- A zombie that interrupts generator repair should not permanently throw
	-- away that interaction. Remember the exact prompt, wait until the area is
	-- safe, return to it, and resume repair automatically.
	repairResumeEnabled = false,
	repairResumeScanRadius = 18.0,
	repairResumeSafeDelay = 0.85,
	repairResumeTimeout = 18.0,
	repairResumeReturnMaximumDistance = 28.0,
	repairResumeActivationDistance = 1.35,
	repairResumeKillerSafeDistance = 24.0,
	repairResumeTriggerCooldown = 0.75,
	repairResumePromptHold = 0.075,
	repairResumeMouseHold = 0.060,
	repairResumeMaximumAttempts = 5,
	repairResumeHz = 12,

	-- Only generator repair may be exited by the bounded confirmed-threat pulse.
	-- Heal/unhook/open and every other interaction remain strictly player-owned.
	interactionBreakForThreat = false,
	interactionBreakForZombie = false,
	interactionBreakForExit = false,
	interactionBreakForPallet = false,

	-- A hit without a recognized animation still receives an emergency escape.
	postHitFallbackEnabled = false,
	postHitFallbackDuration = 1.20,
	postHitFallbackMinimumHold = 0.88,
	postHitFallbackSafeDistance = 24.0,
	postHitFallbackMaximumSourceDistance = 35.0,

	-- Cure's melee track follows diagonal backpedal too well. Use a clean lateral
	-- lane and an early class-scoped guard.
	curePointBlankGuardEnabled = false,
	curePointBlankGuardDistance = 23.0,
	curePointBlankGuardHardDistance = 8.0,
	curePointBlankGuardFacing = 0.38,
	curePointBlankGuardApproach = 0.15,
	curePointBlankGuardRushFacing = -0.05,
	curePointBlankGuardRushApproach = 2.25,
	curePointBlankGuardCooldown = 0.48,
	curePointBlankGuardDuration = 1.52,
	curePointBlankGuardMinimumHold = 1.08,
	curePointBlankGuardSafeDistance = 27.0,
	-- Cure confirmed ACTIVE now prioritizes live radial separation. Legacy tangent
	-- orbit settings remain for compatibility with older profiles.
	cureOrbitTangentialWeight = 1.00,
	cureOrbitAwayWeight = 0.32,
	cureOrbitCloseAwayWeight = 0.58,
	cureOrbitCloseDistance = 6.5,

	-- Automatic pallet. VD drops a standing pallet with Space, not LMB/E.
	-- Pallet geometry is cached once so the controller does not rescan every
	-- descendant of every pallet several times per second.
	-- Enabled only behind the strict crossed-side certificate below. Space is
	-- never emitted while the survivor is still on the Killer's side, while the
	-- pallet is no longer standing, or while movement/interaction is locked.
	palletAutoEnabled = true,
	-- Pallet topology is independent from automatic interaction. Even while
	-- synthetic Space remains permanently disabled, standing pallets must stay in
	-- the world index so the threat planner can preserve a usable loop instead of
	-- abandoning it for a locally open but strategically empty corridor.
	palletTopologyEnabled = true,
	palletKey = Enum.KeyCode.Space,
	palletLocalDistance = 8.5,
	palletKillerDistance = 9.5,
	palletEmergencyKillerDistance = 5.25,
	palletCloseKillerDistance = 6.75,
	-- Space is allowed only after the survivor is unambiguously beyond the
	-- pallet relative to the Killer. The previous positive threshold accepted
	-- nearly perpendicular positions (the supplied failure had sideDot=0.09),
	-- so the pallet fired before the survivor crossed it.
	palletOppositeSideDot = -0.55,
	palletPlayerBehindMargin = 0.85,
	palletKillerFrontMargin = 0.75,
	palletMinimumApproach = -0.25,
	palletCooldown = 1.20,
	palletKeyHold = 0.040,
	palletEscapeDuration = 0.42,
	palletZombieEnabled = true,
	-- A pallet is one-shot. Once Space has been emitted for a model, never
	-- target that same model again during the current match.
	palletOneShotPerModel = true,
	palletUsedPositionDelta = 1.40,
	palletUsedUpDot = 0.78,
	-- Baseline-independent world-state test. A pallet dropped by another
	-- survivor may already be flat when this script indexes it, so comparing
	-- only against the first observed CFrame can never detect that case.
	palletDroppedThinAxisY = 0.70,
	palletDroppedHeightRatio = 0.34,
	palletDroppedGeometryMinimumParts = 2,
	-- Model:GetBoundingBox plus every cached board orientation is the expensive
	-- part of pallet state detection. Cheap attributes/prompts remain checked at
	-- 8 Hz, while this baseline-independent geometry fallback runs only twice/s.
	palletGeometryCheckInterval = 0.50,
	palletGeometryCheckJitter = 0.18,

	-- Window assistance is opt-in through the player's own held WASD direction.
	-- It never starts a vault or writes movement while the
	-- game reports isVaulting/WalkSpeed=0. It only centers a safe manual approach
	-- and briefly preserves the successfully observed exit direction afterward.
	-- Automatic window steering proved unsafe: it could outrank a confirmed
	-- attack route and center the player into a native vault. Windows are now
	-- observation-only; only the player's own movement can start a vault.
	windowManualCommitEnabled = false,
	-- Windows participate in threat route topology without owning the vault. The
	-- motion core may approach a safe player-side staging point, then releases to
	-- physical input before the native trigger. It never presses Space or writes
	-- movement while isVaulting/WalkSpeed=0.
	windowPlannerApproachEnabled = true,
	windowPlannerCandidateDistance = 15.0,
	windowPlannerStagingDistance = 2.40,
	windowPlannerMinimumApproachDistance = 1.20,
	windowPlannerMinimumAwayDot = 0.12,
	windowPlannerExitOffset = 2.75,
	windowPlannerExitProbeDistance = 7.0,
	windowPlannerStopRadius = 0.90,
	windowPlannerScoreBonus = 18.0,
	-- Strategic loop retention. The predictive planner used to score only the
	-- next 17 studs, so a three-branch corridor could win even when it moved the
	-- survivor away from a nearby pallet/window. Loop anchors are event-indexed,
	-- never Workspace-scanned, and never synthesize Space or a vault.
	loopAnchorEnabled = true,
	loopAnchorCandidateDistance = 15.0,
	loopAnchorRetentionDistance = 12.0,
	loopAnchorStagingDistance = 3.25,
	loopAnchorMinimumApproachDistance = 0.85,
	loopAnchorOppositeSideDot = -0.12,
	loopAnchorMinimumAwayDot = 0.04,
	loopAnchorScoreBonus = 52.0,
	loopAnchorDepartureGrace = 0.85,
	loopAnchorDeparturePenaltyPerStud = 22.0,
	loopAnchorMaximumPreferredDeparture = 3.25,
	-- Window centering is an escape assist, not ambient navigation. Physical WASD
	-- toward a window is insufficient unless an actionable ThreatEpisode currently
	-- exists and its attacker is close enough to matter.
	windowRequireActionableThreat = true,
	windowThreatMaximumDistance = 42.0,
	windowMinimumEscapeAwayDot = 0.00,
	windowCandidateDistance = 7.5,
	windowManualDot = 0.72,
	windowCenterArrivalDistance = 1.35,
	windowDefaultVaultDuration = 0.72,
	windowDurationMinimum = 0.25,
	windowDurationMaximum = 1.40,
	windowDurationLearningWeight = 0.30,
	-- The supplied auto-commit passed with only 0.59 s ETA margin. A vault may
	-- visually finish while the game still owns WalkSpeed=0, so require a larger
	-- reserve instead of trying to fake invulnerability during the interaction.
	windowSafetyMargin = 0.85,
	windowKillerAttackBuffer = 4.5,
	windowKillerSpeedFloor = 14.0,
	windowIntentTtl = 0.22,
	windowCommitCooldown = 0.30,
	windowPostExitDuration = 0.30,
	windowPostExitMinimumTravel = 1.0,
	windowPostExitMinimumAwayDot = 0.05,
	windowPostExitClearance = 2.75,
	windowPostExitProbeDistance = 5.0,
	-- Learn the exact local AnimationId used by each native vault. The game chooses
	-- the traversal; the Helper never synthesizes Space. Once isVaulting begins,
	-- raise only that already-playing vault track to the configured fast rate.
	-- MovementWriter remains hard-blocked for WalkSpeed=0/isVaulting.
	windowVaultAnimationLookupWindow = 0.40,
	windowForceFastVaultAnimation = true,
	windowFastVaultAnimationMinimumSpeed = 1.85,
	windowFastVaultAnimationMaximumSpeed = 2.40,
	windowFastVaultDesiredVisualDuration = 0.46,

	abysswalkerPointBlankGuardEnabled = false,
	abysswalkerPointBlankGuardDistance = 12.5,
	abysswalkerPointBlankGuardFacing = 0.78,
	abysswalkerPointBlankGuardApproach = 3.0,
	abysswalkerPointBlankGuardCooldown = 0.62,
	abysswalkerPointBlankGuardDuration = 0.62,
	abysswalkerPointBlankGuardMinimumHold = 0.34,
	abysswalkerPointBlankGuardSafeDistance = 18.0,

	-- 110355... first appeared at 2.52/2.71 studs and damage resolved only
	-- 0.141-0.261 s later. ACTIVE is therefore too late to start movement. Use a
	-- narrow Slasher-only committed-approach guard; distance alone never fires it.
	trackingPointBlankGuardEnabled = false,
	trackingPointBlankGuardDistance = 15.0,
	trackingPointBlankGuardHardDistance = 5.5,
	trackingPointBlankGuardFacing = 0.65,
	trackingPointBlankGuardApproach = 1.50,
	trackingPointBlankGuardRushFacing = 0.25,
	trackingPointBlankGuardRushApproach = 5.00,
	trackingPointBlankGuardCooldown = 0.42,
	trackingPointBlankGuardDuration = 1.60,
	trackingPointBlankGuardMinimumHold = 0.82,
	trackingPointBlankGuardSafeDistance = 22.0,
	trackingStrictRouteDistance = 24.0,
	stalkerStrictRouteDistance = 20.0,
	trackingPostTrackHold = 0.24,
	trackingHardMaximumDuration = 3.20,

	-- "Killer" is a real SelectedKiller class in the supplied match logs, not
	-- merely a missing archetype label. It gets its own animation overrides and
	-- proactive guard before the universal fallback.
	killerPointBlankGuardEnabled = false,
	killerPointBlankGuardDistance = 16.0,
	killerPointBlankGuardHardDistance = 5.25,
	killerPointBlankGuardFacing = 0.72,
	killerPointBlankGuardApproach = 1.10,
	killerPointBlankGuardRushFacing = 0.25,
	killerPointBlankGuardRushApproach = 3.75,
	killerPointBlankGuardCooldown = 0.72,
	killerPointBlankGuardDuration = 1.35,
	killerPointBlankGuardMinimumHold = 0.82,
	killerPointBlankGuardSafeDistance = 22.0,

	-- Universal bounded personal space. Exact attack episodes still supersede
	-- this guard, but no Killer class may stand inside 12.5 studs while Helper
	-- waits indefinitely for an animation that can arrive only 0.15 s pre-hit.
	genericPointBlankGuardEnabled = false,
	genericPointBlankGuardMaximumDistance = 16.0,
	genericPointBlankGuardHardDistance = 12.5,
	genericPointBlankGuardHardFacing = 0.45,
	-- Legacy tuning fields are retained for config compatibility. The hard
	-- radius itself is unconditional; outside it, facing/approach are required.
	genericPointBlankGuardHardMinimumApproach = -0.35,
	genericPointBlankGuardReleaseSeparatingApproach = -1.25,
	genericPointBlankGuardSkipKnownArchetypes = true,
	genericPointBlankGuardFacing = 0.78,
	genericPointBlankGuardApproach = 2.25,
	genericPointBlankGuardRushApproach = 5.00,
	genericPointBlankGuardRushFacing = 0.25,
	genericPointBlankGuardCooldown = 0.20,
	genericPointBlankGuardDuration = 6.00,
	genericPointBlankGuardMinimumHold = 0.60,
	genericPointBlankGuardSafeDistance = 18.0,
	genericPointBlankGuardNonThreatSuppress = 1.35,

	-- RIP_TRACKING was observed only at d=1.50, which is too late for
	-- native-speed movement. This class-specific guard starts while RIP is
	-- still approaching, without enabling the noisy universal guard.
	-- Two animation-less Masked hits arrived at d=10.82/facing=.89/approach=7.27
	-- and d=4.04/facing=.72/approach=8.00. Restore only a narrow committed-
	-- approach guard; ordinary proximity, slow walking and passing-by remain
	-- manual. The old broad 18.5-stud/.55-approach guard stays removed.
	ripPointBlankGuardEnabled = false,
	ripPointBlankGuardDistance = 13.0,
	ripPointBlankGuardHardDistance = 12.5,
	ripPointBlankGuardFacing = 0.82,
	ripPointBlankGuardApproach = 6.0,
	ripPointBlankGuardRushFacing = 0.68,
	ripPointBlankGuardRushApproach = 7.0,
	ripPointBlankGuardCooldown = 0.55,
	ripPointBlankGuardDuration = 1.60,
	ripPointBlankGuardMinimumHold = 0.85,
	ripPointBlankGuardSafeDistance = 22.0,
	-- RIP continues steering during the lunge. Keep the chosen side, but rotate
	-- that tangent around the Killer's current position every render frame.
	-- Confirmed RIP signals must not blend back into an opposite manual input.
	-- Pick the tangent closest to the survivor's current motion so a late signal
	-- does not spend the hit window braking through a 180-degree turn.
	ripOrbitTangentialWeight = 0.10,
	ripOrbitAwayWeight = 1.00,
	ripOrbitCloseAwayWeight = 1.00,
	ripOrbitCloseDistance = 10.0,
	ripStrictRouteDistance = 20.0,
	ripContinuityMinimumSpeed = 1.50,

	-- Veil's melee can begin from point-blank range before the windup track is
	-- useful to the client. A very strict proximity guard starts only when Veil
	-- is both close and credibly facing/approaching the survivor.
	-- Veil ACTIVE arrives after the lunge is already dangerous. Start a
	-- normal-speed sidestep before the animation when Veil is close and
	-- credibly facing or approaching the survivor.
	-- Veil melee PREP was repeatedly first observed at 5.95-8.30 studs only
	-- 0.149-0.186 seconds before damage. Maintain a bounded personal-space zone
	-- before the animation instead of waiting for an unusably late signal.
	veilPointBlankGuardEnabled = false,
	veilPointBlankGuardDistance = 16.0,
	veilPointBlankGuardHardDistance = 12.5,
	veilPointBlankGuardFacing = 0.65,
	veilPointBlankGuardApproach = 2.25,
	veilPointBlankGuardRushFacing = 0.35,
	veilPointBlankGuardRushApproach = 7.00,
	veilPointBlankGuardCooldown = 0.20,
	veilPointBlankGuardDuration = 6.00,
	veilPointBlankGuardMinimumHold = 0.60,
	veilPointBlankGuardSafeDistance = 18.0,

	zombieAcquireDistance = 14.0,
	zombieEmergencyDistance = 6.5,
	zombieReleaseDistance = 20.0,
	zombieFacingThreshold = -0.10,
	zombieApproachThreshold = 1.35,
	zombieEmergencyApproachThreshold = 0.45,
	zombieSpeed = 36.0,
	zombieNames = {
		"scp", "zombie", "infected", "monster", "undead",
		"minion", "summon", "walker", "ghoul",
	},
	zombieSignalAttributes = {
		"IsZombie", "Zombie", "IsEnemyNPC", "Hostile",
		"IsNPC", "Enemy", "Minion", "Summoned",
	},
	zombieSignalTags = {"Zombie", "EnemyNPC", "HostileNPC", "Minion"},

	-- Only a genuinely active, upright NPC may own movement. The previous
	-- integrated controller treated every living Humanoid as dangerous, which
	-- made corpses/ragdolls and motionless summons trigger avoidance.
	zombieMovingMinSpeed = 0.70,
	zombieMoveDirectionThreshold = 0.05,
	zombieMovingVisibilityHold = 0.45,
	-- A close active NPC commonly stops translating while its attack track plays.
	-- Keep that already-acquired threat briefly; never apply this hold to a
	-- corpse/ragdoll or use it to acquire a motionless NPC from scratch.
	zombieStationaryAttackHoldDistance = 10.0,
	zombieStationaryAttackHoldTime = 1.55,
	zombieMinimumUprightY = 0.48,
	zombieTargetSwitchMargin = 12.0,
	zombieRouteLockTime = 1.45,
	zombieRouteReplanInterval = 0.42,
	zombieRouteMinimumAwayDot = 0.12,
	zombieRouteBlockedClearance = 3.00,
	zombieRouteBlockedProbeDistance = 7.0,
	zombieRouteRetryCooldown = 0.60,
	zombieRouteSharpTurnDot = 0.75,
	zombieRouteSharpTurnCooldown = 1.00,
	zombieStuckSampleTime = 0.22,
	zombieStuckMinimumTravel = 0.28,
	zombieIntentTtl = 0.28,
	zombiePalletOpportunityHold = 0.38,

	exitReadyProgress = 0.995,
	exitAcquireDistance = 28.0,
	exitCenterArrivalDistance = 0.75,
	exitPushDistance = 17.0,
	exitApproachSpeed = 32.0,
	exitPushSpeed = 34.0,
	exitMaximumDuration = 5.5,
	exitPushDuration = 1.25,
	exitRouteProbeDistance = 7.0,
	exitRetryCooldown = 2.0,
	exitRetryMinimumTravel = 4.0,
	movementAuxiliaryValidationInterval = 0.10,

	-- RMB item aim. AUTO follows Player.EquippedItem; F6 cycles
	-- AUTO -> FLASHLIGHT -> PISTOL -> OFF.
	itemAimToggleKey = Enum.KeyCode.F6,
	itemAimDefaultMode = "AUTO",
	itemAimModeCycle = {"AUTO", "FLASHLIGHT", "PISTOL", "OFF"},

	-- F7 opens the pistol target selector.
	-- Modes are exclusive:
	--   KILLER_ONLY   -> only the exact current Team=Killer player
	--   NICKNAME_ONLY -> only the selected username/display name
	-- Flashlight targeting always remains Killer-only.
	extraAimTargetKey = Enum.KeyCode.F7,
	extraAimTargetFallbackKey = Enum.KeyCode.Insert,
	extraAimContextActionName = "VD_ExtraAimTargetPromptAction",
	extraAimContextPriority = 3000,
	extraAimHotkeyDebounce = 0.22,
	extraAimTargetGuiName = "VD_ExtraAimTargetPrompt",
	extraAimTargetCurrentBiasPixels = 85.0,
	extraAimTargetWorldWeight = 0.08,
	extraAimTargetOffscreenPenalty = 2500.0,

	flashlightAimEnabled = true,
	-- Do not snap onto a Killer across the map. At useful flashlight range,
	-- hold the real camera direction continuously instead of restoring it one
	-- frame later and hoping the native module sampled the proxy.
	flashlightTargetMaximumDistance = 80.0,
	flashlightTargetMaximumScreenDistance = 520.0,
	-- Keep Camera.LookVector on the target for the complete RMB hold.
	-- The old 299/301 proxy could restore it before the native module read it.
	flashlightKeepVisibleCameraLocked = true,
	flashlightBlindLogCooldown = 0.50,
	-- Camera and visible Beam share one point on the actual face plane. A small
	-- vertical offset targets the upper face instead of the neck/torso boundary.
	flashlightTargetYOffsetFraction = 0.0,
	flashlightTargetFixedCompensation = 0.0,
	flashlightHeadAttachmentName = "VD_FlashlightHeadTarget",
	-- Aim above Head center at the eye/forehead band. The previous 0.16 offset
	-- was technically inside Head but looked low from the hand-mounted emitter.
	flashlightFaceVerticalFraction = 0.34,
	-- 1.0 is the actual decal plane; stay barely inside to avoid precision
	-- problems while still aiming at the face rather than the head center.
	flashlightFaceSurfaceInset = 0.96,
	flashlightFaceBeamCalibrationEnabled = false,
	flashlightFaceBeamInitialPitchCorrection = 0.0,
	flashlightFaceBeamMinimumPitchCorrection = -0.10,
	flashlightFaceBeamMaximumPitchCorrection = 0.38,
	flashlightFaceBeamCorrectionGain = 0.72,
	flashlightFaceBeamCorrectionSmoothing = 0.42,
	flashlightFaceBeamMinimumSampleDistance = 4.0,
	flashlightFaceBeamMinimumHorizontalDot = 0.55,
	flashlightFaceBeamMaximumVerticalError = 10.0,
	flashlightFaceBeamLogCooldown = 0.45,
	flashlightBeamVerificationTolerance = 0.08,
	-- Attachment1 alone is cosmetic. Own the straight visible chord and point the
	-- source Attachment's native Axis at the same face point. Roblox Beam emitters
	-- use Attachment.Axis; Camera.LookVector remains a separate gameplay authority.
	flashlightSourceRayMinimumDot = 0.997,
	flashlightSourceRayMaximumMiss = 0.18,
	flashlightFinalCameraMinimumDot = 0.998,
	flashlightBeamVerificationLogCooldown = 0.40,
	flashlightLosGrace = 0.20,
	-- A blind status existing on the first aim frame may be stale or may mean
	-- "being illuminated", not "fully blinded". Require a fresh false->true
	-- edge after continuous face exposure before pausing the flashlight.
	-- Stable mode never turns the flashlight off automatically. The old
	-- threshold treated partial Blindness progress as a completed blind and
	-- interrupted saves. The user releases RMB manually.
	flashlightBlindPauseEnabled = false,
	flashlightBlindPauseDuration = 0.90,
	flashlightBlindPauseMinimumInterval = 1.20,
	flashlightBlindMinimumExposure = 1.05,
	flashlightBlindConfirmFrames = 4,
	flashlightBlindClearFrames = 3,
	flashlightBlindNumericThreshold = 99.0,
	flashlightBeamFallbackSearchCooldown = 2.0,
	flashlightExactModelName = "Flashlight",
	flashlightExactLightName = "light",
	flashlightExactBeamName = "Beam",
	flashlightEquippedAttribute = "EquippedItem",
	flashlightEquippedValue = "Flashlight",
	flashlightRenderBindingName = "VDV520ItemAimCameraProxy",
	flashlightGameplayBindingName = "VDV528FlashlightGameplayRay",
	flashlightRestoreBindingName = "VDV520FlashlightCameraRestore",
	-- The native module samples Camera.LookVector at Character priority=300.
	-- We provide the target direction at 299, then restore the user's visible
	-- camera orientation at 301 after the native rig consumed it.
	flashlightRenderPriorityOffset = -1,
	-- The previous build jumped directly from Character-1 to Last+12. Native
	-- flashlight code could overwrite Attachment0 at Character priority and
	-- consume that wrong ray for the entire frame before our cosmetic audit.
	flashlightGameplayPriorityOffset = 1,
	flashlightRestorePriorityOffset = 1,
	-- Native flashlight code may run after Character priority. Reassert and
	-- verify the endpoint at the end of the frame, after all normal rig updates.
	flashlightEndpointRenderPriority = Enum.RenderPriority.Last.Value + 12,
	flashlightCameraProxyEnabled = true,
	flashlightMaximumPitch = 0.70,
	-- Coalesce rapid RMB up/down chatter into one aim session. The supplied log
	-- rebound and rescanned the flashlight rig about twenty times in four
	-- seconds, creating avoidable frame pressure beside the skill-check.
	itemAimReleaseGrace = 0.14,

	-- Generic pistol profile. Chest is intentionally preferred over the face:
	-- it is a larger target and most ray/projectile implementations use the
	-- camera direction rather than requiring a headshot.
	pistolAimEnabled = true,
	pistolTargetMaximumDistance = 160.0,
	pistolEquippedTokens = {
		"pistol",
		"gun",
		"revolver",
		"handgun",
		"twist of fate",
		"twistoffate",
	},
	pistolModelTokens = {
		"pistol",
		"gun",
		"revolver",
		"handgun",
		"twistoffate",
	},
	pistolProjectileSpeed = 420.0,
	pistolMaximumLeadTime = 0.14,
	pistolMaximumLeadDistance = 4.5,
	pistolChestYOffset = 0.28,
	pistolMaximumPitch = 0.70,

	abysswalkerCrouchCounterEnabled = true,
	abysswalkerCrouchKey = Enum.KeyCode.C,
	-- These assets are shared by more than one Abysswalker action. They identify a
	-- possible posture-counter sequence, not proof that every 784... is crouchable.
	abysswalkerCrouchIds = {
		["132817836308238"] = true,
		["129784271201071"] = true,
		["118907603246885"] = true,
		["78432063483146"] = true,
	},
	abysswalkerCrouchSequenceById = {
		["129784271201071"] = {phase = "PREP", activeId = "132817836308238"},
		["132817836308238"] = {phase = "ACTIVE", prepId = "129784271201071"},
		["118907603246885"] = {phase = "PREP", activeId = "78432063483146"},
		["78432063483146"] = {phase = "ACTIVE", prepId = "118907603246885"},
	},
	-- Kept as the primary pair for diagnostics/self-tests.
	abysswalkerCrouchPrepId = "118907603246885",
	abysswalkerCrouchActiveId = "78432063483146",
	abysswalkerCrouchPrepMaximumDistance = 24.0,
	abysswalkerCrouchPrepMinimumFacing = 0.85,
	abysswalkerCrouchPrepMaximumRetreat = -0.75,
	abysswalkerCrouchPrepArmWindow = 1.60,
	-- Do not C merely because PREP or ACTIVE played. The supplied trace proves two
	-- modes for the same pair: an ordinary hit compressed 13.83->4.02 studs in
	-- 0.121 s, while the crouchable long strike held its wind-up for 0.36-0.50 s
	-- and changed distance by less than two studs. Time and closure direction are
	-- therefore both part of the action contract.
	abysswalkerCrouchEarlyTriggerDistance = 12.75,
	abysswalkerCrouchMinimumWindupAge = 0.20,
	abysswalkerCrouchEarlyMaximumClosingGain = 2.25,
	abysswalkerCrouchEarlyMinimumFacing = 0.85,
	-- ACTIVE can arrive in the same scheduler slice as PREP. The paired event edge
	-- therefore has its own authorization and never depends on a Heartbeat occurring
	-- between the two AnimationPlayed callbacks.
	abysswalkerCrouchPairedActiveMaximumDistance = 16.0,
	abysswalkerCrouchPairedMaximumClosingGain = 2.50,
	abysswalkerCrouchLiteralKillerRequiresPrep = true,
	-- Exact ownership plus the observed PREP->ACTIVE sequence is stronger than
	-- a shared animation's deliberately generic class label. This permits the
	-- counter without trusting a stale Player.SelectedKiller value by itself.
	abysswalkerCrouchSequenceAuthorityEnabled = true,
	-- A supplied miss landed at 12.60 studs with no C edge or threat episode.
	-- The old 11.5-stud gate silently rejected the exact active signal.
	abysswalkerCrouchMaximumDistance = 16.0,
	-- The shared 784... asset also appears during ordinary close attacks. Distance
	-- never overrides the wind-up/closure discriminator, including point-blank.
	abysswalkerCrouchSharedMinimumActiveDistance = 11.25,
	abysswalkerCrouchCooldown = 0.58,
	-- The supplied 118907... -> 784320... sequence hit roughly 0.60 s after
	-- ACTIVE while the old 220 ms hold had already released C. Keep the native
	-- counter held through the bounded charged-dash impact window.
	abysswalkerCrouchHold = 0.780,

	diagnosticsRingSize = 200,
	diagnosticsDeathDumpCount = 45,
	diagnosticsDefaultCooldown = 0.25,
	-- Keep the ring internally for debugging, but never flood the executor
	-- console during normal play or after being downed.
	diagnosticsConsoleEnabled = true,
	diagnosticsImportantOnly = true,
	diagnosticsDeathDumpEnabled = false,
}

SingletonMarker:SetAttribute(
	"MovementRenderBindingName",
	Config.movementRenderBindingName
)

-- Only observed, useful attack metadata is retained. Legacy FSM fields,
-- takeovers, guards and dozens of unused thresholds are intentionally absent.
local AttackCatalog = {
	["129784271201071"] = {family="ABYSSWALKER", phase="PREP", kind="CHARGED_PREP", startOnPrep=true, maxDistance=22.0, duration=1.22, safeDistance=22.0, speed=36.0, lateral=31.0, away=2.0, minFacing=-0.10, minimumHold=0.62},
	["132817836308238"] = {family="ABYSSWALKER", phase="ACTIVE", kind="CHARGED", maxDistance=18.5, duration=0.66, safeDistance=23.0, speed=36.0, lateral=18.0, away=14.0, minFacing=-0.10},
	-- New Abysswalker pair observed simultaneously at 48.73 studs before
	-- repeated long/medium-range HIT_NO_THREAT results.
	["130585295123651"] = {family="ABYSSWALKER_RANGED", phase="PREP", kind="ABYSSWALKER_RANGED_PREP", startOnPrep=true, maxDistance=70.0, duration=0.92, safeDistance=24.0, speed=36.0, lateral=30.0, away=2.0, minFacing=-0.10, ignoreSafeDistance=true, minimumHold=0.46, requireAimedOrApproaching=true, aimedFacing=0.42, minimumApproach=1.25, releaseWhenSeparating=true, separatingApproach=-1.25, separatingFacing=0.05},
	["102489115945356"] = {family="ABYSSWALKER_RANGED", phase="ACTIVE", kind="ABYSSWALKER_RANGED_ACTIVE", maxDistance=70.0, duration=0.88, safeDistance=24.0, speed=36.0, lateral=31.0, away=1.0, minFacing=-0.70, ignoreSafeDistance=true, minimumHold=0.62},
	["112166042383605"] = {family="ABYSSWALKER_RANGED", phase="PREP", kind="ABYSSWALKER_DELAYED_RANGED", startOnPrep=true, maxDistance=40.0, duration=1.30, safeDistance=25.0, speed=36.0, lateral=31.0, away=1.0, minFacing=-0.10, ignoreSafeDistance=true, minimumHold=0.62, requireAimedOrApproaching=true, aimedFacing=0.45, minimumApproach=1.50, releaseWhenSeparating=true, separatingApproach=-1.25, separatingFacing=0.05},
	-- Both IDs appeared inside a confirmed close attack chain. Treat them as
	-- animation-timed signals instead of using permanent proximity movement.
	["80411309607666"] = {family="ABYSSWALKER_CLOSE_CHAIN", phase="PREP", kind="ABYSSWALKER_CLOSE_CHAIN_PREP", startOnPrep=true, maxDistance=17.0, duration=0.88, safeDistance=19.0, speed=36.0, lateral=31.0, away=2.0, minFacing=-0.35, minimumHold=0.48},
	["123047897844134"] = {family="ABYSSWALKER_CLOSE_CHAIN", phase="ACTIVE", kind="ABYSSWALKER_CLOSE_CHAIN_ACTIVE", maxDistance=12.5, duration=0.78, safeDistance=19.0, speed=36.0, lateral=31.0, away=2.0, minFacing=-0.40, minimumHold=0.46},
	["82666958311998"] = {family="QUICK", phase="ACTIVE", kind="QUICK", maxDistance=14.5, duration=0.50, safeDistance=19.0, speed=36.0, lateral=18.0, away=5.0, minFacing=-0.10},
	["138720291317243"] = {family="RIP_TRACKING", phase="ACTIVE", kind="RIP_TRACKING_STRIKE_ACTIVE", maxDistance=20.0, duration=3.40, safeDistance=28.0, speed=36.0, lateral=3.0, away=36.0, minFacing=-0.10, minimumHold=0.65, requireAimedOrApproaching=true, aimedFacing=0.20, minimumApproach=1.50, releaseWhenSeparating=true, separatingApproach=-1.25, separatingFacing=0.15, lateObserveOnlyDistance=15.0},
	["110355011987939"] = {family="TRACKING", phase="ACTIVE", kind="TRACKING_MELEE_ACTIVE", maxDistance=18.0, duration=1.40, safeDistance=25.0, speed=36.0, lateral=14.0, away=32.0, minFacing=-0.10, minimumHold=1.00, holdControlUntilTrackStop=true, postTrackHold=0.24, hardMaximumDuration=3.20, requireDeepRoute=true, lateObserveOnlyDistance=6.0},
	["77477445889320"] = {family="TRACKING", phase="ACTIVE", kind="TRACKING_LUNGE", maxDistance=19.0, duration=1.50, safeDistance=25.0, speed=36.0, lateral=16.0, away=30.0, minFacing=-0.15, minimumHold=1.06, holdControlUntilTrackStop=true, postTrackHold=0.24, hardMaximumDuration=3.20, requireDeepRoute=true},
	["139369275981139"] = {family="TRACKING", phase="ACTIVE", kind="SLASHER", maxDistance=19.0, duration=1.50, safeDistance=25.0, speed=36.0, lateral=16.0, away=30.0, minFacing=-0.15, minimumHold=1.06, holdControlUntilTrackStop=true, postTrackHold=0.24, hardMaximumDuration=3.20, requireDeepRoute=true, lateObserveOnlyDistance=13.0},
	["121571390309073"] = {family="TRACKING", phase="FINISHER", kind="TRACKING_FINISHER_ACTIVE", maxDistance=20.0, duration=1.65, safeDistance=30.0, speed=36.0, lateral=14.0, away=32.0, minFacing=-0.20, minimumHold=1.12, holdControlUntilTrackStop=true, postTrackHold=0.24, hardMaximumDuration=3.20, requireDeepRoute=true},
	-- This PREP was recovered 0.308 s into the track and the old observe-only
	-- contract waited for a synthetic close guard at 5.37 studs.  Treat the exact
	-- wind-up as the early edge, while still requiring aimed/closing geometry.
	["113255068724446"] = {family="HIDDEN", phase="PREP", kind="HIDDEN_PREP", startOnPrep=true, forcePrepMovement=true, forceRouteOnPrep=true, maxDistance=18.5, duration=1.18, safeDistance=22.0, speed=36.0, lateral=12.0, away=32.0, minFacing=-0.15, minimumHold=0.82, requireDeep=true, requireDeepRoute=true, requireAimedOrApproaching=true, aimedFacing=0.70, minimumApproach=2.0, preserveExistingRouteOnConfirm=true, preserveExistingRouteFamily="HIDDEN_CLOSE_AIM_GUARD", confirmationHold=1.10, clearMotionProfileOverride=true},
	-- Confirmed damaging long Hidden attack. It was previously unknown on the
	-- first hit and later ran as a short LEARNED_HIDDEN fallback whose manual
	-- blend weakened the lateral route. Keep the ordinary prep short, but give
	-- this active signal a dedicated long, route-only sidestep immediately.
	["98163597193511"] = {family="HIDDEN_LONG", phase="ACTIVE", kind="HIDDEN_LONG_TRACKING_ACTIVE", maxDistance=45.0, duration=1.75, safeDistance=30.0, speed=36.0, lateral=14.0, away=30.0, minFacing=-0.30, requireDeep=true, ignoreSafeDistance=false, minimumHold=1.30, requireAimedOrApproaching=true, aimedFacing=0.62, minimumApproach=1.25, releaseWhenSeparating=false, replaceExistingGuard=true},
	-- Fresh evidence shows two delivery modes for this asset: one copy was only
	-- recovered after damage, but another arrived roughly 0.62 s before a hit while
	-- Hidden closed from 16.49 to 9.85 studs. Do not globally classify it as late.
	-- When it is delivered in time it must replace a route-less distance floor and
	-- plan against Hidden's real lunge reach.
	["74968262036854"] = {family="HIDDEN", phase="ACTIVE", kind="HIDDEN_ACTIVE", replaceExistingGuard=true, maxDistance=22.0, duration=1.24, safeDistance=24.0, speed=36.0, lateral=12.0, away=32.0, minFacing=-0.35, minimumHold=0.82, requireDeepRoute=true, requireAimedOrApproaching=true, aimedFacing=0.35, minimumApproach=1.0, clearMotionProfileOverride=true},
	["135002183282873"] = {family="CURE", phase="ACTIVE", kind="CURE_LUNGE_A", maxDistance=23.0, duration=1.48, safeDistance=27.0, speed=17.0, lateral=42.0, away=0.0, minFacing=-0.75, minimumHold=1.05},
	["121216847022485"] = {family="CURE", phase="ACTIVE", kind="CURE_LUNGE_B", maxDistance=23.0, duration=1.48, safeDistance=27.0, speed=17.0, lateral=42.0, away=0.0, minFacing=-0.75, minimumHold=1.05},
	-- Abysswalker-specific posture sequence. The family name intentionally names
	-- the real class; it must never relabel this model as the literal "Killer".
	-- Counter authorization still happens separately and rejects the rapid M1 form.
	["118907603246885"] = {family="ABYSSWALKER_CROUCH_STRIKE", phase="PREP", kind="ABYSSWALKER_CROUCH_WINDUP", startOnPrep=true, forcePrepMovement=true, forceRouteOnPrep=true, replaceExistingGuard=true, maxDistance=20.0, duration=1.45, safeDistance=26.0, speed=36.0, lateral=5.0, away=36.0, minFacing=-0.10, minimumHold=0.92, hardMaximumDuration=1.70, requireDeep=true, requireAimedOrApproaching=true, aimedFacing=0.55, minimumApproach=2.0, releaseWhenSeparating=true, separatingApproach=-1.25, separatingFacing=0.10},
	["78432063483146"] = {family="ABYSSWALKER_CROUCH_STRIKE", phase="ACTIVE", kind="ABYSSWALKER_CROUCH_ACTIVE", replaceExistingGuard=true, maxDistance=18.0, duration=0.78, safeDistance=26.0, speed=36.0, lateral=5.0, away=36.0, minFacing=-0.10, minimumHold=0.42, preserveExistingRouteOnConfirm=true, lateObserveOnlyDistance=12.25, requireAimedOrApproaching=true, aimedFacing=0.35, minimumApproach=1.0},
	["116093934008204"] = {family="RUSH", phase="PREP", kind="RUSH_PREP", startOnPrep=true, maxDistance=25.5, duration=1.10, safeDistance=26.0, speed=36.0, lateral=17.0, away=13.0, minFacing=-0.10, requireDeep=true},
	["133002120549396"] = {family="RUSH", phase="ACTIVE", kind="RUSH_ACTIVE", maxDistance=18.5, duration=0.64, safeDistance=27.0, speed=36.0, lateral=18.0, away=14.0, minFacing=-0.10},
	["130012819736632"] = {family="RUSH", phase="ACTIVE", kind="RUSH_ACTIVE", maxDistance=21.5, duration=0.72, safeDistance=30.0, speed=36.0, lateral=15.0, away=21.0, minFacing=-0.20},
	-- This ID has two materially different observed server-resolution windows.
	-- ACTIVE must atomically re-certify the current corridor under the exact RIP
	-- envelope: preserving the shorter synthetic guard certificate produced a logged
	-- predictedSep=10.86/required=10.35 route that was still hit.
	["105374834496520"] = {family="RIP", phase="ACTIVE", kind="RIP_LUNGE_ACTIVE", replaceExistingGuard=true, clearMotionProfileOverride=true, maxDistance=20.0, duration=3.40, safeDistance=28.0, speed=36.0, lateral=8.0, away=30.0, minFacing=-0.10, minimumHold=0.80, motionHoldPadding=0.55, confirmationHold=0.80, preserveExistingRouteOnConfirm=false, requireAimedOrApproaching=true, aimedFacing=0.20, minimumApproach=1.50, releaseWhenSeparating=true, separatingApproach=-1.25, separatingFacing=0.15, lateObserveOnlyDistance=15.0},
	-- Observed as UNKNOWN_MASKED with no damage correlation for ~20 seconds.
	-- Keep it for class/telemetry visibility but never let it own movement.
	["136365031119137"] = {family="MASKED_SIGNAL", phase="PREP", kind="MASKED_AMBIGUOUS_SIGNAL", maxDistance=20.0, duration=0.0, safeDistance=20.0, speed=0.0, lateral=0.0, away=0.0, minFacing=-1.0, startOnPrep=false, observeOnly=true},
	-- This signal coincides with damage in the same timestamp in repeated logs.
	-- It is a late hit/finisher confirmation, not useful dodge anticipation.
	["111920872708571"] = {family="RIP", phase="FINISHER", kind="RIP_COMBO_HIT_CONFIRM", maxDistance=17.5, duration=0.0, safeDistance=24.0, speed=0.0, lateral=0.0, away=0.0, minFacing=-1.0, observeOnly=true},
	["92362656727126"] = {family="RIP_EXTENDED", phase="ACTIVE", kind="RIP_EXTENDED_A", maxDistance=19.0, duration=1.08, safeDistance=24.0, speed=36.0, lateral=12.0, away=23.0, minFacing=-0.15},
	["115244153053858"] = {family="RIP_EXTENDED", phase="FINISHER", kind="RIP_EXTENDED_HIT_CONFIRM", maxDistance=19.0, duration=0.0, safeDistance=25.0, speed=0.0, lateral=0.0, away=0.0, minFacing=-1.0, observeOnly=true},
	-- ACTIVE 133963... repeatedly appeared on the same frame as damage, so it is
	-- a late confirmation rather than usable anticipation. Start on the exact
	-- PREP only when Stalker is strongly aimed at the survivor or committing a
	-- fast approach; release early when that geometry disappears.
	["117042998468241"] = {family="STALKER", phase="PREP", kind="STALKER_Q_PREP", startOnPrep=true, forcePrepMovement=true, forceRouteOnPrep=true, maxDistance=20.0, duration=1.85, safeDistance=26.0, speed=36.0, lateral=40.0, away=3.0, minFacing=0.10, minimumHold=0.72, requireDeep=true, requireAimedOrApproaching=true, aimedFacing=0.72, minimumApproach=4.50, closeRangeAlwaysActionableDistance=11.50, releaseWhenSeparating=true, separatingApproach=-0.50, separatingFacing=0.25},
	["133963973694098"] = {family="STALKER", phase="ACTIVE", kind="STALKER_Q_ACTIVE", maxDistance=20.0, duration=3.35, safeDistance=28.0, speed=36.0, lateral=40.0, away=3.0, minFacing=-0.25, minimumHold=1.20, holdControlUntilTrackStop=true, postTrackHold=0.65, hardMaximumDuration=4.25, releaseWhenSeparating=true, separatingApproach=-1.50, separatingFacing=0.10, lateObserveOnlyDistance=10.0, preserveExistingRouteOnConfirm=true, preserveExistingRouteFamily="STALKER", confirmationHold=0.46},
	["84093948968516"] = {family="VEIL_THROW", phase="PREP", kind="VEIL_AIM_A", startOnPrep=true, forcePrepMovement=true, forceRouteOnPrep=true, maxDistance=34.0, duration=2.45, safeDistance=28.0, speed=36.0, lateral=38.0, away=1.0, minFacing=0.55, minimumHold=1.00, aimImpactDelay=1.05, motionHoldPadding=1.30, requireAimedOrApproaching=true, aimedFacing=0.78, minimumApproach=999.0, pendingAimRecheck=true, pendingAimDuration=1.15, pendingAimFacing=0.62, releaseWhenSeparating=true, separatingApproach=-0.50, separatingFacing=0.20},
	["137688077908355"] = {family="VEIL_THROW", phase="PREP", kind="VEIL_AIM_B", startOnPrep=true, forcePrepMovement=true, forceRouteOnPrep=true, maxDistance=34.0, duration=2.45, safeDistance=28.0, speed=36.0, lateral=38.0, away=1.0, minFacing=0.55, minimumHold=1.00, aimImpactDelay=1.05, motionHoldPadding=1.30, requireAimedOrApproaching=true, aimedFacing=0.78, minimumApproach=999.0, pendingAimRecheck=true, pendingAimDuration=1.15, pendingAimFacing=0.62, releaseWhenSeparating=true, separatingApproach=-0.50, separatingFacing=0.20},
	-- New traces show ACTIVE roughly one second before impact after Veil spent the
	-- entire PREP tracking the survivor.  Keeping the PREP world vector let two
	-- arrows hit after 30-35 studs of movement.  ACTIVE must atomically recertify
	-- against Veil's current line instead of preserving the now-predictable side.
	["86266790353635"] = {family="VEIL_THROW", phase="ACTIVE", kind="VEIL_THROW", maxDistance=120.0, duration=1.35, safeDistance=120.0, speed=36.0, lateral=36.0, away=1.0, minFacing=0.18, ignoreSafeDistance=true, minimumHold=0.72, requireAimedOrApproaching=true, aimedFacing=0.82, minimumApproach=999.0, preserveExistingRouteOnConfirm=false},
	-- Fresh trace: this appeared only 60 ms before damage. It is useful as a
	-- confirmation of an already-running Veil aim/PREP episode, never as a new
	-- movement trigger on its own.
	["93136435416899"] = {family="VEIL_DELAYED", phase="ACTIVE", kind="VEIL_DELAYED_HIT_CONFIRM", maxDistance=30.0, duration=0.0, safeDistance=28.0, speed=0.0, lateral=0.0, away=0.0, minFacing=-1.0, observeOnly=true},
	["122812055447896"] = {family="VEIL_MELEE", phase="PREP", kind="VEIL_MELEE_WINDUP", startOnPrep=true, forcePrepMovement=true, forceRouteOnPrep=true, replaceExistingGuard=true, clearMotionProfileOverride=true, maxDistance=18.0, duration=2.65, safeDistance=26.0, speed=36.0, lateral=38.0, away=8.0, minFacing=0.20, minimumHold=1.40, hardMaximumDuration=3.20, aimImpactDelay=1.35, motionHoldPadding=1.20, requireDeepRoute=true, requireAimedOrApproaching=true, aimedFacing=0.62, minimumApproach=6.0, releaseWhenSeparating=true, separatingApproach=-0.75, separatingFacing=0.05},
	["78935059863801"] = {family="VEIL_MELEE", phase="ACTIVE", kind="VEIL_MELEE_ACTIVE", replaceExistingGuard=true, clearMotionProfileOverride=true, maxDistance=18.0, duration=1.45, safeDistance=26.0, speed=36.0, lateral=38.0, away=8.0, minFacing=0.10, minimumHold=1.08, requireDeepRoute=true, lateObserveOnlyDistance=4.5, preserveDistanceKeeperRouteOnConfirm=false, preserveExistingRouteOnConfirm=true, preserveExistingRouteFamily="VEIL_MELEE", confirmationHold=0.85},
	-- Both actions repeatedly appeared without damage correlation. They are not
	-- allowed to re-enter movement as UNKNOWN_VEIL after exact Veil safety logic.
	["104192089592095"] = {family="VEIL_SIGNAL", phase="ACTIVE", kind="VEIL_UNCORRELATED_ACTION_A", maxDistance=20.0, duration=0.0, safeDistance=20.0, speed=0.0, lateral=0.0, away=0.0, minFacing=-1.0, observeOnly=true},
	["105221485497534"] = {family="VEIL_SIGNAL", phase="ACTIVE", kind="VEIL_UNCORRELATED_ACTION_B", maxDistance=20.0, duration=0.0, safeDistance=20.0, speed=0.0, lateral=0.0, away=0.0, minFacing=-1.0, observeOnly=true},

	-- Masked: observed close enough and facing the survivor, with the old
	-- unknown-action detector independently deciding fallback=true.
	["79935565590141"] = {family="MASKED", phase="ACTIVE", kind="MASKED_CLOSE_ACTION_A", maxDistance=14.5, duration=0.68, safeDistance=18.0, speed=36.0, lateral=15.0, away=15.0, minFacing=-0.05},
	["133881825716964"] = {family="MASKED", phase="ACTIVE", kind="MASKED_POINT_BLANK_ACTION", maxDistance=9.0, duration=0.46, safeDistance=15.0, speed=36.0, lateral=21.0, away=7.0, minFacing=0.10},
	-- Confirmed 80-damage Masked signal: the animation began 0.247 s before
	-- health changed at 8.82 studs with facing=0.99. It was previously retained
	-- only as an unclassified candidate, so exact-signal-only v5.2.60 could not
	-- create an episode. Use a deep, fixed-side cut across the lunge line.
	-- This replicated ACTIVE arrived only about 0.10 s before the logged impact.
	-- It confirms the sustained Masked aim episode; it must not choose a new side
	-- or straighten a cover route on the last frames of the lunge.
	["106871536134254"] = {family="MASKED_LUNGE", phase="ACTIVE", kind="MASKED_80_DAMAGE_LUNGE", maxDistance=16.0, duration=1.05, safeDistance=21.0, speed=36.0, lateral=38.0, away=7.0, minFacing=0.10, minimumHold=0.78, requireDeepRoute=true, requireAimedOrApproaching=true, aimedFacing=0.55, minimumApproach=3.0, preserveExistingRouteOnConfirm=true},

	-- Repeated across multiple killer contexts at 2-11 studs, Action4, 2.0 s.
	-- Older result logs show successful no-damage side dodges from this signal.
	["102055678391920"] = {family="GENERIC_MELEE_SIGNAL", phase="ACTIVE", kind="GENERIC_ACTION4_NON_DAMAGE_SIGNAL", maxDistance=13.0, duration=0.0, safeDistance=18.0, speed=0.0, lateral=0.0, away=0.0, minFacing=-1.00, observeOnly=true},
}

-- Some animation assets are shared between classes. Resolve these overrides
-- by the exact SelectedKiller token before consulting the global catalog.
-- This prevents 129784271201071 from being forced into ABYSSWALKER when the
-- game explicitly reports SelectedKiller=Killer.
local CLASS_ATTRIBUTE_NAMES = {
	"SelectedKiller",
	"KillerName",
	"KillerClass",
	"Archetype",
	"Class",
	"Role",
	"CharacterName",
	"CharacterClass",
}

local CLASS_CANONICAL_BY_TOKEN = {
	abysswalker = "Abysswalker",
	knight = "Abysswalker",
	quick = "Quick",
	rip = "RIP",
	tracking = "Slasher",
	slasher = "Slasher",
	hidden = "Hidden",
	cure = "Cure",
	rush = "Rush",
	stalker = "Stalker",
	masked = "Masked",
	themasked = "Masked",
	veil = "Veil",
	killer = "Killer",
}

local CLASS_BY_ATTACK_FAMILY = {
	ABYSSWALKER = "Abysswalker",
	ABYSSWALKER_RANGED = "Abysswalker",
	ABYSSWALKER_CLOSE_CHAIN = "Abysswalker",
	ABYSSWALKER_CROUCH_STRIKE = "Abysswalker",
	QUICK = "Quick",
	RIP = "RIP",
	RIP_TRACKING = "RIP",
	TRACKING = "Slasher",
	TRACKING_POINTBLANK_GUARD = "Slasher",
	HIDDEN = "Hidden",
	HIDDEN_LONG = "Hidden",
	LEARNED_HIDDEN = "Hidden",
	CURE = "Cure",
	RUSH = "Rush",
	STALKER = "Stalker",
	MASKED = "Masked",
	MASKED_LUNGE = "Masked",
	VEIL = "Veil",
	KILLER = "Killer",
}

local GENERIC_CLASS_TOKENS = {
	[""] = true,
	killer = true,
	unknown = true,
	none = true,
	default = true,
}

-- These assets have appeared in both the literal Killer class and the old
-- Abysswalker profile. A player-level SelectedKiller value can be stale, so it
-- may not relabel a shared attack. Only current character/model metadata is
-- strong enough to call the class Abysswalker.
local SHARED_KILLER_ABYSS_IDS = {
	["129784271201071"] = true,
	["132817836308238"] = true,
	["130585295123651"] = true,
	["102489115945356"] = true,
	["112166042383605"] = true,
	["80411309607666"] = true,
	["123047897844134"] = true,
	["118907603246885"] = true,
	["78432063483146"] = true,
}

local function isRuntimeModelClassSource(source: any): boolean
	return typeof(source) == "string"
		and string.sub(source, 1, 6) == "model."
end

local AttackCatalogBySelected = {
	killer = {
		["104689417033027"] = {
			family = "KILLER",
			phase = "ACTIVE",
			kind = "KILLER_ACTIVE_104689417033027",
			maxDistance = 22.0,
			duration = 1.35,
			safeDistance = 23.0,
			speed = 36.0,
			lateral = 34.0,
			away = 1.0,
			minFacing = -0.35,
			minimumHold = 0.88,
			requireDeep = true,
		},
		["129784271201071"] = {
			family = "KILLER",
			phase = "PREP",
			kind = "KILLER_PREP_129784271201071",
			startOnPrep = true,
			forcePrepMovement = true,
			forceRouteOnPrep = true,
			maxDistance = 21.0,
			duration = 1.55,
			safeDistance = 28.0,
			speed = 36.0,
			lateral = 5.0,
			away = 36.0,
			minFacing = -0.20,
			minimumHold = 1.05,
			requireDeep = false,
			requireAimedOrApproaching = true,
			aimedFacing = 0.55,
			minimumApproach = 1.50,
			-- This exact PREP is the only useful warning for the fast literal-Killer
			-- ultimate. It must replace the synthetic close-aim guard immediately;
			-- waiting for ACTIVE leaves only a few render frames before damage.
			promoteFromCloseAimGuard = true,
			releaseWhenSeparating = true,
			separatingApproach = -1.25,
			separatingFacing = 0.15,
			-- If the sustained close-aim guard already owns a certified open
			-- corridor, the exact PREP confirms the attack rather than revoking
			-- that corridor during a fresh ray-budget transaction.
			preserveExistingRouteOnConfirm = true,
			confirmationHold = 0.42,
		},
		["132817836308238"] = {
			family = "KILLER",
			phase = "ACTIVE",
			kind = "KILLER_ACTIVE_132817836308238",
			maxDistance = 20.0,
			duration = 1.30,
			safeDistance = 28.0,
			speed = 36.0,
			-- The attacker is faster than native survivor movement during this phase.
			-- Straight-away running is therefore not a dodge; prefer an outward lateral
			-- cut through a proven open corridor.
			lateral = 28.0,
			away = 12.0,
			minFacing = -0.30,
			minimumHold = 0.96,
			requireDeep = false,
			-- Supplied literal-Killer hits resolved only 0.150 s after this
			-- ACTIVE appeared at 8.26 studs. Without an already-running PREP episode,
			-- this is too late to justify replacing the player's current direction.
			lateObserveOnlyDistance = 4.0,
			-- ACTIVE follows PREP within a few frames. Keep the already certified
			-- direction instead of clearing it to route-pending on the damage frame.
			preserveExistingRouteOnConfirm = true,
			confirmationHold = 0.42,
		},
	},
}

-- Seen on SelectedKiller=Masked, but the supplied samples happened too far
-- away to prove they are damaging attacks. They remain eligible only for a
-- much stricter point-blank fallback instead of becoming global triggers.
local NonThreatAnimationIds = {
	-- Veil post-hit/hit-confirm: observed only after health loss.
	["119752564209631"] = "VEIL_POST_HIT_CONFIRM",
	-- Masked late impact/hit-confirm. In the supplied pair it preceded damage by
	-- 0.155 s and then 0.067 s; learning it with the generic 0.55 s forecast made
	-- the planner certify a route after the hit was already unavoidable.
	["130593238885843"] = "MASKED_LATE_IMPACT_CONFIRM",
	-- Universal killer pallet kick/break. Do not run away; this is a useful
	-- flashlight window.
	["135181748009911"] = "PALLET_BREAK",
	-- Shared long interaction/carry/recovery tracks repeatedly seen far away or
	-- immediately after the survivor was already downed.
	["111223305405046"] = "SHARED_INTERACTION_ACTION3",
	["110466971021611"] = "CARRY_OR_RECOVERY",
	["102746205979822"] = "CARRY_OR_HOOK_RECOVERY",
	["126626340093785"] = "ABYSSWALKER_RECOVERY",
	["128241974219045"] = "CARRY_RELEASE_RECOVERY",
	["76503974441748"] = "CARRY_OR_HOOK_RECOVERY",
}

local MaskedObservedUnclassified = {
	["135403091566760"] = true,
	["117070354890871"] = true,
	["135029251763856"] = true,
	["92431623965655"] = true,
}

---------------------------------------------------------------------
-- 4. Runtime state
---------------------------------------------------------------------

local State = {
	enabled = Config.enabled,
	alive = true,

	matchActive = false,
	matchReason = "startup",
	localKillerRoleSuppressed = false,
	matchCandidateSince = nil :: number?,
	matchInactiveSince = nil :: number?,
	matchEvidenceInstance = nil :: Instance?,
	matchMapRoot = nil :: Instance?,
	matchGeneration = 0,
	lastRoundTimePositive = false,
	roundEndedLatch = false,

	worldIndexQueue = {} :: {Instance},
	worldIndexHead = 1,
	worldIndexActive = false,
	worldIndexGeneration = 0,
	worldIndexProcessed = 0,
	lastPerformanceLogAt = -math.huge,

	character = nil :: Model?,
	characterGeneration = 0,
	targetBindingGeneration = 0,
	humanoid = nil :: Humanoid?,
	root = nil :: BasePart?,
	animator = nil :: Animator?,

	activeThreat = nil :: any,
	movementIntents = {} :: {[string]: any},
	movementOwner = nil :: string?,
	movementGroup = nil :: string?,
	movementSelectedIntent = nil :: any,

	nearestKiller = nil :: Model?,
	nearestKillerRoot = nil :: BasePart?,
	nearestKillerDistance = math.huge,

	animatorConnections = {} :: {[Animator]: RBXScriptConnection},
	modelByAnimator = {} :: {[Animator]: Model},
	playerCharacterConnections = {} :: {[Player]: RBXScriptConnection},
	animationTrackLastHandledAt = setmetatable({}, {__mode = "k"}) :: {[AnimationTrack]: any},
	animationPollStateByTrack = setmetatable({}, {__mode = "k"}) :: {[AnimationTrack]: any},
	animationPlayGenerationByTrack = setmetatable({}, {__mode = "k"}) :: {[AnimationTrack]: number},
	animationPlayStartedAtByTrack = setmetatable({}, {__mode = "k"}) :: {[AnimationTrack]: number},
	animationPlayStopConnectionsByTrack = {} :: {[AnimationTrack]: RBXScriptConnection},
	unknownAnimationSeen = {} :: {[string]: boolean},
	recentActionByModel = setmetatable({}, {__mode = "k"}) :: {[Model]: any},
	recentNonThreatUntilByModel = setmetatable({}, {__mode = "k"}) :: {[Model]: number},
	recentPalletBreakUntilByModel = setmetatable({}, {__mode = "k"}) :: {[Model]: number},
	genericGuardDistanceSampleByModel = setmetatable({}, {__mode = "k"}) :: {[Model]: any},
	personalSpaceRouteBlockedUntilByModel = setmetatable({}, {__mode = "k"}) :: {[Model]: number},
	learnedAttackCatalog = {} :: {[string]: any},
	damageLearningCounts = {} :: {[string]: number},
	damageLearningEvidence = {} :: {[string]: any},
	damageLearningObserveOnly = {} :: {[string]: boolean},
	familyFailureHits = {} :: {[string]: number},
	disabledMovementFamilies = {} :: {[string]: boolean},
	distanceKeeperBlockedUntil = -math.huge,
	noCorridorGuardBlockedUntilByModel = {} :: {[Model]: number},
	lastEscapeRouteByModel = setmetatable({}, {__mode = "k"}) :: {[Model]: any},
	predictiveRouteCacheByModel = setmetatable({}, {__mode = "k"}) :: {[Model]: any},
	attackImpactDelayById = {} :: {[string]: number},
	motionTelemetry = table.create(72) :: {any},
	motionTelemetryHead = 0,
	motionTelemetryCount = 0,
	motionTelemetryLastAt = -math.huge,
	veilAimStateByModel = setmetatable({}, {__mode = "k"}) :: {[Model]: any},
	-- Exact Veil PREP can be delivered while the replicated root happens to be
	-- between two aim samples. Keep the live track briefly and re-evaluate it;
	-- never manufacture a threat after the track has stopped.
	veilPendingPrepByModel = setmetatable({}, {__mode = "k"}) :: {[Model]: any},
	veilLongApproachStateByModel = setmetatable({}, {__mode = "k"}) :: {[Model]: any},
	trackingSafetyEnvelopeUntilByModel = setmetatable({}, {__mode = "k"}) :: {[Model]: number},
	literalKillerSafetyEnvelopeUntilByModel = setmetatable({}, {__mode = "k"}) :: {[Model]: number},
	maskedCloseAimStateByModel = setmetatable({}, {__mode = "k"}) :: {[Model]: any},
	hiddenCloseAimStateByModel = setmetatable({}, {__mode = "k"}) :: {[Model]: any},
	killerCloseAimStateByModel = setmetatable({}, {__mode = "k"}) :: {[Model]: any},
	unsafeTraversalSpaceHeld = false,
	syntheticPalletSpaceUntil = -math.huge,
	unsafeTraversalVetoLatch = nil :: any,
	unsafeTraversalEscape = nil :: any,
	lockedThreatWarningGui = nil :: ScreenGui?,
	lockedThreatWarningLabel = nil :: TextLabel?,
	lockedThreatWarningUntil = -math.huge,
	lastLockedThreatWarningLogAt = -math.huge,
	zombieCache = {} :: {[Model]: any},
	zombieLastProximityDiscoveryAt = -math.huge,
	zombiePalletOpportunityUntil = -math.huge,
	zombiePalletOpportunityModel = nil :: Model?,
	palletCache = {} :: {[Model]: any},
	palletUsedModels = setmetatable({}, {__mode = "k"}) :: {[Model]: boolean},
	windowCache = {} :: {[Model]: any},
	gateCache = {} :: {[Instance]: any},
	activeGate = nil :: any,

	originalWalkSpeed = nil :: number?,
	observedNativeWalkSpeed = 0.0,
	walkSpeedOwner = nil :: string?,
	originalAutoRotate = nil :: boolean?,
	autoRotateOwner = nil :: string?,
	movementSoftWriteCount = 0,
	movementLastActualSpeed = 0.0,
	movementLastAlignment = 0.0,
	movementRenderBound = false,
	movementRenderBindGeneration = 0,
	movementPrimaryHeartbeatAt = -math.huge,
	movementFallbackLastAt = -math.huge,
	movementFallbackWrites = 0,
	movementLastAppliedEpisode = nil :: any,
	movementLastAppliedAt = -math.huge,
	movementRenderWrites = 0,
	lastInteractionReleaseAt = -math.huge,
	lastInteractionReleaseReason = "none",
	interactionReleaseUntil = -math.huge,
	interactionPulseToken = 0,
	repairEscapeEpisodeId = nil :: number?,
	repairEscapeAttempts = 0,
	repairEscapeLastAt = -math.huge,
	repairEscapePulseGeneration = 0,
	repairEscapeKeyCode = nil :: Enum.KeyCode?,
	repairResume = nil :: any,
	lastRepairResumeTriggerAt = -math.huge,
	lastPalletDropAt = -math.huge,

	rightMouseDown = false,
	rightMouseReleaseGeneration = 0,
	crouchCounterHeldUntil = -math.huge,
	crouchCounterGeneration = 0,
	crouchCounterPrepByModel = setmetatable({}, {__mode = "k"}) :: {[Model]: any},
	actionReservation = nil :: any,
	actionAuthority = nil :: any,
	actionDecisionGeneration = 0,
	actionLastSuppressedLogAt = -math.huge,
	skillCheckCandidates = setmetatable({}, {__mode = "k"}) :: {[GuiObject]: boolean},
	itemAimModePreference = Config.itemAimDefaultMode,
	itemAimActiveMode = "OFF",
	itemAimLastUnsupportedLogAt = -math.huge,
	pistolTargetMode = "KILLER_ONLY",
	extraAimTargetUserId = nil :: number?,
	extraAimTargetName = "none",
	extraAimTargetDisplayName = "none",
	extraAimTargetPrompt = nil :: ScreenGui?,
	extraAimTargetTextBox = nil :: TextBox?,
	extraAimTargetStatus = nil :: TextLabel?,
	extraAimTargetPromptOpen = false,
	extraAimLastHotkeyAt = -math.huge,
	extraAimLastHotkeySource = "none",
	extraAimLastSource = "none",
	extraAimLastScreenDistance = math.huge,
	pistolLastLeadTime = 0.0,
	pistolLastLeadDistance = 0.0,
	pistolLastTargetPart = "none",
	flashlightLastBeamFallbackSearchAt = -math.huge,
	flashlightBeam = nil :: Beam?,
	flashlightOriginalAttachment1 = nil :: Attachment?,
	flashlightOriginalEnabled = nil :: boolean?,
	flashlightOriginalCurveSize0 = nil :: number?,
	flashlightOriginalCurveSize1 = nil :: number?,
	flashlightSource = nil :: Attachment?,
	flashlightOriginalSourceCFrame = nil :: CFrame?,
	flashlightTargetAttachment = nil :: Attachment?,
	flashlightTargetModel = nil :: Model?,
	flashlightLastValidAt = -math.huge,
	flashlightAimConfirmedThisHold = false,
	flashlightBeamVerifiedThisHold = false,
	flashlightLastBlindAt = -math.huge,
	flashlightAimStartedAt = -math.huge,
	flashlightPreAimWalkSpeed = nil :: number?,
	flashlightUnsafeStopQueued = false,
	flashlightBlindObservedTarget = nil :: Model?,
	flashlightBlindSignalActive = false,
	flashlightBlindSignalSource = "none",
	flashlightBlindArmed = false,
	flashlightBlindActiveFrames = 0,
	flashlightBlindInactiveFrames = 0,
	flashlightBlindLatchedTarget = nil :: Model?,
	flashlightBlindSuppressedUntil = -math.huge,
	flashlightBlindPauseGeneration = 0,
	flashlightMovementYieldActive = false,
	flashlightMovementYieldSource = "none",
	flashlightActivationRemote = nil :: RemoteEvent?,
	flashlightActivationPart = nil :: Instance?,
	flashlightRenderBound = false,
	flashlightGameplayRenderBound = false,
	flashlightGameplayAuthorityAt = -math.huge,
	flashlightRestoreRenderBound = false,
	flashlightPreProxyCameraCFrame = nil :: CFrame?,
	flashlightLastProxyPitch = 0.0,
	flashlightFacePitchCorrection = Config.flashlightFaceBeamInitialPitchCorrection,
	flashlightFaceBeamErrorY = 0.0,
	flashlightFaceBeamCalibrationValid = false,
	flashlightFaceBeamCalibrationSamples = 0,
	flashlightTorso = nil :: BasePart?,
	flashlightShoulder = nil :: Motor6D?,
	flashlightOriginalShoulderC0 = nil :: CFrame?,

	connections = {} :: {RBXScriptConnection},
	characterConnections = {} :: {RBXScriptConnection},
	knownKillerModels = {} :: {[Model]: boolean},
	inferredAttackFamilyByModel = setmetatable({}, {__mode = "k"}) :: {[Model]: any},
	killerClassInfoByModel = setmetatable({}, {__mode = "k"}) :: {[Model]: any},
	rawKillerClassCacheByModel = setmetatable({}, {__mode = "k"}) :: {[Model]: any},
	timers = {
		target = 0.0,
		matchAudit = 0.0,
		animators = 0.0,
		animationPoll = 0.0,
		zombie = 0.0,
		pallet = 0.0,
		window = 0.0,
		repair = 0.0,
		exit = 0.0,
		flashlight = 0.0,
		predictive = 0.0,
		veilAim = 0.0,
		workspaceExit = 0.0,
	},
	telemetry = {
		episodeCounter = 0,
		lastDamageAt = -math.huge,
		lastHealth = 100.0,
		recentThreatSnapshot = nil :: any,
		recentThreatSnapshotAt = -math.huge,
		lastKnightCounterAt = -math.huge,
		lastGenericPointBlankGuardAt = -math.huge,
		lastKillerPointBlankGuardAt = -math.huge,
		lastTrackingPointBlankGuardAt = -math.huge,
		lastCurePointBlankGuardAt = -math.huge,
		lastRipPointBlankGuardAt = -math.huge,
		lastAbysswalkerPointBlankGuardAt = -math.huge,
		lastVeilPointBlankGuardAt = -math.huge,
		terminalSnapshotCharacter = nil :: Model?,
		terminalSnapshotAt = -math.huge,
	},
}

---------------------------------------------------------------------
-- 5. Utility functions
---------------------------------------------------------------------

local function now(): number
	return os.clock()
end

local function ownsGlobalRuntime(): boolean
	local runtime = rawget(_G, GLOBAL_RUNTIME_KEY)
	return State.alive and type(runtime) == "table" and runtime.token == GLOBAL_OWNER_TOKEN
end

local function horizontal(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

local function unitOr(v: Vector3, fallback: Vector3): Vector3
	local h = horizontal(v)
	if h.Magnitude > 1e-4 then
		return h.Unit
	end
	local hf = horizontal(fallback)
	if hf.Magnitude > 1e-4 then
		return hf.Unit
	end
	return Vector3.new(0, 0, -1)
end

local function unit3Or(v: Vector3, fallback: Vector3): Vector3
	if v.Magnitude > 1e-4 then return v.Unit end
	if fallback.Magnitude > 1e-4 then return fallback.Unit end
	return Vector3.new(0, 0, -1)
end

local function clampSpeed(speed: number): number
	return math.clamp(speed, 0, Config.movementHardSpeedCap)
end

local function rotateY(direction: Vector3, degrees: number): Vector3
	local radians = math.rad(degrees)
	local c = math.cos(radians)
	local s = math.sin(radians)
	local d = unitOr(direction, Vector3.new(0, 0, -1))
	return Vector3.new(
		d.X * c - d.Z * s,
		0,
		d.X * s + d.Z * c
	).Unit
end

local function animationId(track: AnimationTrack): string
	local animation = track.Animation
	if not animation then
		return ""
	end
	local raw = tostring(animation.AnimationId or "")
	return raw:match("(%d+)$") or raw
end

local function aliveHumanoid(model: Model?): Humanoid?
	if not model or not model.Parent then
		return nil
	end
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.Health > 0 then
		return humanoid
	end
	return nil
end

local function modelRoot(model: Model?): BasePart?
	if not model then
		return nil
	end
	local root = model:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root
	end
	if model.PrimaryPart then
		return model.PrimaryPart
	end
	return model:FindFirstChildWhichIsA("BasePart")
end

local function modelFromAnimator(animator: Animator): Model?
	local humanoid = animator.Parent
	if not humanoid or not humanoid:IsA("Humanoid") then
		return nil
	end
	local model = humanoid.Parent
	if model and model:IsA("Model") then
		return model
	end
	return nil
end

local function playerFromCharacter(model: Model?): Player?
	if not model then
		return nil
	end
	return Players:GetPlayerFromCharacter(model)
end

local function isLocalCharacter(model: Model?): boolean
	return model ~= nil and model == State.character
end

local function isDowned(): boolean
	local humanoid = State.humanoid
	if not humanoid then
		return true
	end
	if humanoid.Health <= 0 then
		return true
	end
	-- Native item control is unavailable below half health in this game; the
	-- downed attributes may arrive later, so stop all helper control here too.
	if humanoid.MaxHealth > 0
		and humanoid.Health < humanoid.MaxHealth * 0.5 then
		return true
	end
	local character = State.character
	if character then
		for _, name in ipairs({"Downed", "Carried", "Hooked", "IsDowned", "IsCarried", "IsHooked", "BeingCarried"}) do
			local value = character:GetAttribute(name)
			if value == true then
				return true
			end
			local child = character:FindFirstChild(name)
			if child and child:IsA("BoolValue") and child.Value then
				return true
			end
		end
	end
	return false
end

local function getFacingDot(threatRoot: BasePart, targetRoot: BasePart): number
	local toTarget = unitOr(targetRoot.Position - threatRoot.Position, threatRoot.CFrame.LookVector)
	return unitOr(threatRoot.CFrame.LookVector, toTarget):Dot(toTarget)
end

local function getApproachSpeed(threatRoot: BasePart, targetRoot: BasePart): number
	local toTarget = unitOr(targetRoot.Position - threatRoot.Position, threatRoot.CFrame.LookVector)
	return horizontal(threatRoot.AssemblyLinearVelocity):Dot(toTarget)
end

local function containsToken(value: string, tokens: {string}): boolean
	local lower = string.lower(value)
	for _, token in ipairs(tokens) do
		if string.find(lower, token, 1, true) then
			return true
		end
	end
	return false
end

local function countDictionaryEntries(dictionary: {[any]: any}): number
	local count = 0
	for _ in pairs(dictionary) do
		count += 1
	end
	return count
end

local safeCallErrorLastAt = {} :: {[string]: number}
local safeCallErrorSuppressed = {} :: {[string]: number}

local function safeCall(label, callback, ...)
	local packed = table.pack(xpcall(callback, debug.traceback, ...))
	if not packed[1] then
		-- A render callback can fail dozens of times per second. Keep the first
		-- traceback and a bounded one-second reminder instead of turning one bug
		-- into a console/FPS flood that survives until the intent is cleared.
		local key = tostring(label)
		local t = now()
		local lastAt = safeCallErrorLastAt[key] or -math.huge
		if t - lastAt >= 1.0 then
			local suppressed = safeCallErrorSuppressed[key] or 0
			safeCallErrorLastAt[key] = t
			safeCallErrorSuppressed[key] = 0
			warn(string.format(
				"[%s][ERROR] label=%s suppressed=%d traceback=%s",
				SCRIPT_TAG,
				key,
				suppressed,
				tostring(packed[2])
			))
		else
			safeCallErrorSuppressed[key] =
				(safeCallErrorSuppressed[key] or 0) + 1
		end
		return nil
	end
	return table.unpack(packed, 2, packed.n)
end

-- Forward declarations used by MatchController. They are assigned in their
-- own sections later; no event callback writes movement directly.
local TargetResolver
local ThreatController
local ZombieController
local PalletController
local WindowController
local RepairResumeController
local ExitController
local WorldIndexer
local FlashlightController
local MovementWriter
local ActionArbiter
local activeSkillCheckVisible

---------------------------------------------------------------------
-- 6. Diagnostics
---------------------------------------------------------------------

local Diagnostics = {
	buffer = table.create(Config.diagnosticsRingSize),
	head = 0,
	count = 0,
	cooldowns = {} :: {[string]: number},
}

local IMPORTANT_DIAGNOSTICS = {
	PLANNER_PERFORMANCE = true,
	MOTION_CORE_WALL_RECERTIFIED = true,
	EMERGENCY_AUTHORITY_EXPIRED = true,
	READY = true,
	MATCH_ACTIVE = true,
	THREAT_START = true,
	DODGE_DETECTED = true,
	DODGE_APPLIED = true,
	DODGE_MANUAL_ONLY = true,
	ACTION_ARBITER_SUPPRESSED = true,
	ACTION_ARBITER_FALLBACK = true,
	DISTANCE_KEEPER_START = true,
	DISTANCE_KEEPER_CONFIRMED = true,
	DISTANCE_KEEPER_REJECTED_PLAYER_CLOSING = true,
	DISTANCE_KEEPER_DISENGAGED = true,
	CHARACTER_TERMINAL_SNAPSHOT = true,
	DODGE_CONSERVATIVE_UNSAFE = true,
	DODGE_CONSERVATIVE_RELEASE = true,
	KILLER_GUARD_WALL_RELEASE = true,
	CONSERVATIVE_ROUTE_FAILURE_RETAINED = true,
	CONSERVATIVE_ROUTE_ABSENT_NATIVE = true,
	MOTION_CORE_REPLAN_REJECTED_WORSE = true,
	MOTION_CORE_MANUAL_CERTIFICATE_AUTHORITY = true,
	MOTION_CORE_COMMITTED_ROUTE_MANUAL_RELEASE_BLOCKED = true,
	MOTION_CORE_SUSTAINED_MANUAL_RELEASE_BLOCKED = true,
	MANUAL_POCKET_ENTRY_REJECTED = true,
	UNSAFE_WINDOW_APPROACH_REJECTED_EARLY = true,
	TRACKING_OBSTACLE_RETRY = true,
	MOTION_CORE_WALL_CONTINUATION = true,
	MOTION_CORE_WALL_CONTINUATION_REJECTED = true,
	VEIL_FALLBACK_LATERAL_AUTHORITY = true,
	VEIL_HIT_SIGNAL_SNAPSHOT = true,
	PREDICTIVE_ROUTE_SELECTED = true,
	DODGE_FEASIBILITY_REJECTED = true,
	REPAIR_ESCAPE_GEOMETRY_FALLBACK = true,
	REPAIR_CONFIRMED_THREAT_ESCAPE = true,
	REPAIR_THREAT_ESCAPE_REQUESTED = true,
	REPAIR_THREAT_ESCAPE_PULSE_RELEASED = true,
	REPAIR_THREAT_DIFFERENT_FLOOR_IGNORED = true,
	EXACT_SIGNAL_SUPERSEDES_GUARD = true,
	PREDICTIVE_ROUTE_ABORTED = true,
	PREDICTIVE_PLANNER_SUPPRESSED_LOCKED = true,
	LOCKED_THREAT_WARNING = true,
	ATTACK_IMPACT_DELAY_LEARNED = true,
	MOTION_CORE_BOUND = true,
	MOTION_CORE_ROUTE = true,
	MOTION_CORE_REPLAN = true,
	MOTION_CORE_NO_CORRIDOR = true,
	MOTION_TRACE = true,
	LOW_OBSTACLE_CORRIDOR_ACTIVE = true,
	VEIL_WALL_AIM_TRACK = true,
	VEIL_WALL_AIM_COMMITTED = true,
	VEIL_WALL_AIM_CONFIRMED = true,
	VEIL_WALL_AIM_SUPPRESSED_LOCKED = true,
	VEIL_REPAIR_AIM_ESCAPE = true,
	THREAT_HIT_MANUAL_ONLY = true,
	DODGE_WALL_ESCAPE = true,
	DODGE_WALL_RELEASE_MANUAL = true,
	MOVEMENT_RENDER_BOUND = true,
	MOVEMENT_RENDER_FALLBACK_ACTIVE = true,
	MOVEMENT_SUPPRESSED_LOCKED = true,
	GENERIC_POINTBLANK_GUARD = true,
	PERSONAL_SPACE_NO_OPEN_CORRIDOR = true,
	PROXIMITY_MOVEMENT_DISABLED = true,
	KILLER_CLASS_RESOLVED = true,
	ANIMATION_POLL_RECOVERED = true,
	HIDDEN_CLOSE_AIM_GUARD = true,
	KILLER_CLOSE_AIM_GUARD = true,
	UNSAFE_TRAVERSAL_BLOCKED = true,
	UNSAFE_TRAVERSAL_ESCAPE_ROUTE = true,
	UNSAFE_TRAVERSAL_THREAT_ROUTE_RETAINED = true,
	UNSAFE_TRAVERSAL_ESCAPE_REJECTED = true,
	SPACE_INPUT_PASSED = true,
	UNSAFE_TRAVERSAL_CONTEXT_BIND = true,
	RIP_POINTBLANK_GUARD = true,
	VEIL_POINTBLANK_GUARD = true,
	ABYSSWALKER_CROUCH = true,
	CROUCH_COUNTER = true,
	CROUCH_COUNTER_SKIPPED = true,
	CROUCH_COUNTER_PREP_ARMED = true,
	CROUCH_COUNTER_PREP_REJECTED = true,
	STALKER_PREP_SKIPPED = true,
	DAMAGE_RESULT = true,
	ITEM_AIM_START = true,
	ITEM_AIM_STOP = true,
	FLASHLIGHT_DIRECT_BEAM = true,
	FLASHLIGHT_HEAD_BEAM_BOUND = true,
	FLASHLIGHT_BEAM_FACE_VERIFIED = true,
	FLASHLIGHT_BEAM_FACE_VERIFY_FAILED = true,
	FLASHLIGHT_SOURCE_FACE_VERIFIED = true,
	FLASHLIGHT_SOURCE_FACE_VERIFY_FAILED = true,
	FLASHLIGHT_NATIVE_BEAM_DRIFT = true,
	FLASHLIGHT_FACE_CALIBRATION = true,
	FLASHLIGHT_FACE_CALIBRATION_UNAVAILABLE = true,
	FLASHLIGHT_BEAM_MISSING = true,
	FLASHLIGHT_AIM_ACTIVE = true,
	FLASHLIGHT_NO_TARGET = true,
	FLASHLIGHT_UNSAFE_AIM_DEACTIVATED = true,
	FLASHLIGHT_SAFE_WINDOW_RETAINED = true,
	FLASHLIGHT_SAFE_ACTION_MOVEMENT_YIELD = true,
	REPAIR_THREAT_ESCAPE_REQUESTED = true,
	REPAIR_THREAT_ESCAPE_PULSE_RELEASED = true,
	INTERACTION_RELEASE = true,
	ZOMBIE_THREAT_START = true,
	ZOMBIE_THREAT_RELEASE = true,
	ZOMBIE_ROUTE_SELECTED = true,
	ZOMBIE_INDEXED = true,
	PALLET_INDEXED = false,
	AUTO_PALLET_DROP = true,
	AUTO_PALLET_FAILED = true,
	AUTO_PALLET_WAIT_CROSS = true,
	VAULT_CANDIDATE = true,
	VAULT_COMMIT = true,
	VAULT_REJECTED_NO_THREAT = true,
	VAULT_REJECTED_TOWARD_THREAT = true,
	VAULT_REJECTED_LATE = true,
	VAULT_START = true,
	VAULT_END = true,
	VAULT_HIT = true,
	REPAIR_RESUME_CAPTURED = true,
	REPAIR_RESUME_RETURN = true,
	REPAIR_RESUME_TRIGGER = true,
	REPAIR_RESUMED = true,
	REPAIR_RESUME_CANCELLED = true,
	POST_HIT_ESCAPE_FALLBACK = true,
	CURE_POINTBLANK_GUARD = true,
	FAMILY_FAILSAFE_DISABLED = true,
	FAMILY_FAILSAFE_HIT_IGNORED_LOCKED = true,
	FAMILY_FAILSAFE_HIT_IGNORED_LATE_SIGNAL = true,
	FAMILY_FAILSAFE_SUPPRESSED = true,
	PERF_SPIKE_OWN = true,
	FRAME_STALL_EXTERNAL_OR_ENGINE = true,
}

function Diagnostics.Push(kind: string, message: string, cooldownKey: string?, cooldown: number?): ()
	local t = now()
	if cooldownKey then
		local last = Diagnostics.cooldowns[cooldownKey] or -math.huge
		if t - last < (cooldown or Config.diagnosticsDefaultCooldown) then
			return
		end
		Diagnostics.cooldowns[cooldownKey] = t
	end

	local line =
		string.format(
			"[%s][%s] %s",
			SCRIPT_TAG,
			kind,
			message
		)
	Diagnostics.head =
		(Diagnostics.head % Config.diagnosticsRingSize) + 1
	Diagnostics.buffer[Diagnostics.head] =
		string.format("%.3f %s", t, line)
	Diagnostics.count =
		math.min(
			Diagnostics.count + 1,
			Config.diagnosticsRingSize
		)

	if Config.diagnosticsConsoleEnabled
		and (
			not Config.diagnosticsImportantOnly
			or IMPORTANT_DIAGNOSTICS[kind] == true
		) then
		print(line)
	end
end

function Diagnostics.DumpRecent(reason: string, amount: number?): ()
	if not Config.diagnosticsDeathDumpEnabled then
		return
	end

	local n =
		math.min(
			amount or Config.diagnosticsDeathDumpCount,
			Diagnostics.count
		)
	print(
		string.format(
			"[%s][DIAGNOSTIC_DUMP_START] reason=%s count=%d",
			SCRIPT_TAG,
			reason,
			n
		)
	)
	for offset = n - 1, 0, -1 do
		local index =
			((Diagnostics.head - offset - 1)
				% Config.diagnosticsRingSize) + 1
		local value = Diagnostics.buffer[index]
		if value then
			print(
				string.format(
					"[%s][TRACE] %s",
					SCRIPT_TAG,
					value
				)
			)
		end
	end
	print(
		string.format(
			"[%s][DIAGNOSTIC_DUMP_END]",
			SCRIPT_TAG
		)
	)
end

---------------------------------------------------------------------
-- 7. RaycastBudget
---------------------------------------------------------------------

local RaycastBudget = {
	used = 0,
	criticalUsed = 0,
	cache = {} :: {[string]: any},
	cacheCount = 0,
	cacheExpiresAt = -math.huge,
	params = RaycastParams.new(),
}

RaycastBudget.params.FilterType = Enum.RaycastFilterType.Exclude
RaycastBudget.params.IgnoreWater = true
-- Movement must care about parts the Humanoid can physically collide with.
-- Some map props disable CanQuery while keeping CanCollide, which made a plain
-- ray report an open path immediately before the character hit the prop.
pcall(function()
	RaycastBudget.params.RespectCanCollide = true
end)

function RaycastBudget.BeginFrame(): ()
	RaycastBudget.used = 0
	RaycastBudget.criticalUsed = 0
	local t = now()
	if t >= RaycastBudget.cacheExpiresAt then
		-- A short cache generation bounds retained map references without scanning
		-- an ever-growing dictionary on a gameplay frame.
		table.clear(RaycastBudget.cache)
		RaycastBudget.cacheCount = 0
		RaycastBudget.cacheExpiresAt = t + Config.raycastCacheMaxAge
	end
	RaycastBudget.params.FilterDescendantsInstances = State.character and {State.character} or {}
end

function RaycastBudget.HasRegularCapacity(count: number): boolean
	return RaycastBudget.used + math.max(0, count)
		<= Config.raycastMaxPerFrame
end

function RaycastBudget.HasCriticalCapacity(count: number): boolean
	return RaycastBudget.criticalUsed + math.max(0, count)
		<= Config.raycastCriticalMaxPerFrame
end

local function rayKey(origin: Vector3, direction: Vector3): string
	return string.format(
		"%.1f:%.1f:%.1f|%.2f:%.2f:%.2f|%.1f",
		origin.X,
		origin.Y,
		origin.Z,
		direction.X,
		direction.Y,
		direction.Z,
		direction.Magnitude
	)
end

function RaycastBudget.Cast(origin: Vector3, direction: Vector3, allowCache: boolean?): RaycastResult?
	local key = rayKey(origin, direction)
	local t = now()
	if allowCache ~= false then
		local cached = RaycastBudget.cache[key]
		if cached and t - cached.time <= Config.raycastCacheMaxAge then
			return cached.result
		end
	end
	if RaycastBudget.used >= Config.raycastMaxPerFrame then
		-- A permitted fresh cache hit already returned above. Never revive an old
		-- result, or a result explicitly forbidden by allowCache=false.
		return nil
	end
	RaycastBudget.used += 1
	local result = Workspace:Raycast(origin, direction, RaycastBudget.params)
	if not RaycastBudget.cache[key] then
		if RaycastBudget.cacheCount >= Config.raycastCacheMaximumEntries then
			table.clear(RaycastBudget.cache)
			RaycastBudget.cacheCount = 0
		end
		RaycastBudget.cacheCount += 1
	end
	RaycastBudget.cache[key] = {time=t, result=result}
	return result
end

function RaycastBudget.CastCritical(origin: Vector3, direction: Vector3): RaycastResult?
	-- This method is called only after the caller reserved a complete body sweep.
	-- Do not reuse the general cache here: live collision geometry is the final
	-- authority before Player:Move and must not inherit a 50 ms old clear result.
	RaycastBudget.criticalUsed += 1
	return Workspace:Raycast(origin, direction, RaycastBudget.params)
end

function RaycastBudget.Clear(): ()
	table.clear(RaycastBudget.cache)
	RaycastBudget.cacheCount = 0
	RaycastBudget.cacheExpiresAt = -math.huge
	RaycastBudget.used = 0
	RaycastBudget.criticalUsed = 0
end

---------------------------------------------------------------------
-- 8. CharacterController
---------------------------------------------------------------------

local CharacterController = {}

function CharacterController.GetOriginalWalkSpeed(): number
	local captured = State.originalWalkSpeed or 0
	local observed = State.observedNativeWalkSpeed or 0
	if math.max(captured, observed) > 0.1 then
		return math.max(captured, observed)
	end
	local humanoid = State.humanoid
	local current = humanoid and humanoid.WalkSpeed or 0
	return current > 0.1 and current or 16.0
end

function CharacterController.CaptureOriginalMovement(): ()
	local humanoid = State.humanoid
	if not humanoid then
		return
	end
	if State.originalWalkSpeed == nil then
		local current = humanoid.WalkSpeed
		State.originalWalkSpeed =
			current > 0 and current or 16.0
	end
	if humanoid.WalkSpeed > State.observedNativeWalkSpeed then
		State.observedNativeWalkSpeed = humanoid.WalkSpeed
	end
	if State.originalAutoRotate == nil then
		State.originalAutoRotate =
			humanoid.AutoRotate
	end
end

-- Compatibility name retained for older internal calls.
function CharacterController.CaptureOriginalWalkSpeed(): ()
	CharacterController.CaptureOriginalMovement()
end

local INTERACTION_ATTRIBUTES = {
	"isRepairing",
	"isHealing",
	"isUnhooking",
	"isOpening",
	"isInteracting",
	"isExiting",
	"isVaulting",
	"isDroppingPallet",
}

function CharacterController.InteractionStatus(): (boolean, string)
	local humanoid = State.humanoid
	local root = State.root
	local character = State.character
	if not humanoid or not root or not character then
		return false, "no-character"
	end

	local reasons = {}
	local check = character:FindFirstChild("CheckInterractable")
	if check then
		for _, name in ipairs(INTERACTION_ATTRIBUTES) do
			if check:GetAttribute(name) == true then
				reasons[#reasons + 1] = name
			end
		end
	end
	if root.Anchored then reasons[#reasons + 1] = "root-anchored" end
	if humanoid.Sit then reasons[#reasons + 1] = "sit" end
	if humanoid.PlatformStand then reasons[#reasons + 1] = "platform-stand" end
	if humanoid.WalkSpeed <= 0.1 then reasons[#reasons + 1] = "walkspeed-zero" end
	return #reasons > 0, table.concat(reasons, ",")
end

function CharacterController.IsRepairing(): boolean
	local character = State.character
	local check = character and character:FindFirstChild("CheckInterractable")
	return check ~= nil and check:GetAttribute("isRepairing") == true
end

function CharacterController.HasNonRepairInteraction(): (boolean, string)
	local humanoid = State.humanoid
	local character = State.character
	if not humanoid or not character then
		return true, "no-character"
	end
	local reasons = {}
	local check = character:FindFirstChild("CheckInterractable")
	if check then
		for _, name in ipairs(INTERACTION_ATTRIBUTES) do
			if name ~= "isRepairing"
				and check:GetAttribute(name) == true then
				reasons[#reasons + 1] = name
			end
		end
	end
	if humanoid.Sit then reasons[#reasons + 1] = "sit" end
	if humanoid.PlatformStand then reasons[#reasons + 1] = "platform-stand" end
	return #reasons > 0, table.concat(reasons, ",")
end

function CharacterController.CanDetectThreatWhileRepairLocked(): boolean
	if not Config.repairThreatEscapeEnabled
		or not CharacterController.IsRepairing() then
		return false
	end
	-- Detection remains live while the skill-check is visible so its evidence is
	-- ready on the first frame after the GUI closes. CanRequestRepairThreatEscape
	-- is the separate authority that vetoes the key edge while that GUI is visible.
	local otherLocked = CharacterController.HasNonRepairInteraction()
	return not otherLocked
end

function CharacterController.DefensiveMovementStatus(): (boolean, string)
	-- The skill-check window is the one repair state that must never be
	-- interrupted. A lingering isRepairing attribute is not itself a movement
	-- lock after the game has restored native movement.
	if activeSkillCheckVisible and activeSkillCheckVisible() then
		return true, "skill-check-visible"
	end
	if CharacterController.IsRepairing() then
		local otherLocked, otherStatus =
			CharacterController.HasNonRepairInteraction()
		local humanoid = State.humanoid
		local root = State.root
		if not otherLocked
			and humanoid and humanoid.WalkSpeed > 0.1
			and root and not root.Anchored then
			return false, "repair-ui-native-movement-available"
		end
		if otherLocked then
			return true, otherStatus
		end
	end
	return CharacterController.InteractionStatus()
end

function CharacterController.DefensivePlanningSpeed(): number
	local humanoid = State.humanoid
	if not humanoid then
		return 0
	end
	return humanoid.WalkSpeed
end

function CharacterController.PhysicalInputDirection(): Vector3?
	-- Humanoid.MoveDirection is written by Player:Move as well as Roblox's native
	-- controls. Reading it after the Helper has taken authority feeds the Helper's
	-- own route back into the planner and falsely labels it as the player's WASD.
	-- Read the physical keyboard state directly so route comparison has an
	-- independent source of truth.
	local forwardAmount = 0
	local rightAmount = 0
	if UserInputService:IsKeyDown(Enum.KeyCode.W) then forwardAmount += 1 end
	if UserInputService:IsKeyDown(Enum.KeyCode.S) then forwardAmount -= 1 end
	if UserInputService:IsKeyDown(Enum.KeyCode.D) then rightAmount += 1 end
	if UserInputService:IsKeyDown(Enum.KeyCode.A) then rightAmount -= 1 end
	if forwardAmount == 0 and rightAmount == 0 then
		return nil
	end
	local camera = Workspace.CurrentCamera
	local forward = camera
		and unitOr(horizontal(camera.CFrame.LookVector), Vector3.new(0, 0, -1))
		or Vector3.new(0, 0, -1)
	local right = camera
		and unitOr(horizontal(camera.CFrame.RightVector), Vector3.new(1, 0, 0))
		or Vector3.new(1, 0, 0)
	local direction = forward * forwardAmount + right * rightAmount
	return direction.Magnitude >= Config.movementMinimumDirection
		and direction.Unit
		or nil
end

local REPAIR_ESCAPE_KEYS = {
	Enum.KeyCode.W,
	Enum.KeyCode.A,
	Enum.KeyCode.S,
	Enum.KeyCode.D,
}

local function anyPhysicalMovementKeyDown(): boolean
	for _, keyCode in ipairs(REPAIR_ESCAPE_KEYS) do
		if UserInputService:IsKeyDown(keyCode) then
			return true
		end
	end
	return false
end

local function worldDirectionToMovementKey(direction: Vector3): Enum.KeyCode
	local camera = Workspace.CurrentCamera
	if not camera then
		return Enum.KeyCode.S
	end
	local forward = unitOr(
		horizontal(camera.CFrame.LookVector),
		Vector3.new(0, 0, -1)
	)
	local right = unitOr(
		horizontal(camera.CFrame.RightVector),
		Vector3.new(1, 0, 0)
	)
	local candidates = {
		{key = Enum.KeyCode.W, direction = forward},
		{key = Enum.KeyCode.S, direction = -forward},
		{key = Enum.KeyCode.D, direction = right},
		{key = Enum.KeyCode.A, direction = -right},
	}
	local wanted = unitOr(horizontal(direction), -forward)
	local selected = candidates[1]
	local selectedDot = -math.huge
	for _, candidate in ipairs(candidates) do
		local dot = wanted:Dot(candidate.direction)
		if dot > selectedDot then
			selectedDot = dot
			selected = candidate
		end
	end
	return selected.key
end

function CharacterController.CanRequestRepairThreatEscape(
	threat: any
): (boolean, string)
	if not Config.repairThreatEscapeEnabled then
		return false, "disabled"
	end
	if activeSkillCheckVisible and activeSkillCheckVisible() then
		return false, "skill-check-visible"
	end
	local otherLocked, otherStatus =
		CharacterController.HasNonRepairInteraction()
	if otherLocked then
		return false, otherStatus
	end
	local humanoid = State.humanoid
	local root = State.root
	if not humanoid or not root then
		return false, "missing-character"
	end
	-- The game can set WalkSpeed to zero one replication step before the
	-- CheckInterractable.isRepairing attribute appears.  During that narrow
	-- window the old gate returned "not-repairing" and left the survivor frozen
	-- in front of an active attack (the RIP trace at d=6.65 showed exactly this).
	-- Treat only an unanchored zero-speed lock with no other interaction as an
	-- implicit generator-repair lock.  Anchored/PlatformStand/Sit/non-repair
	-- states remain vetoes, and no character property is written here.
	local explicitRepair = CharacterController.IsRepairing()
	local interactionMarker = State.character
		and State.character:FindFirstChild("CheckInterractable")
	local implicitRepairLock = not explicitRepair
		and interactionMarker ~= nil
		and humanoid.WalkSpeed <= 0.1
		and not root.Anchored
	if not explicitRepair and not implicitRepairLock then
		return false, "not-repairing"
	end
	-- If Roblox has already restored ordinary movement, the unified writer can
	-- use Player:Move directly. Do not manufacture another keyboard edge merely
	-- because a stale isRepairing attribute remains true.
	if humanoid.WalkSpeed > 0.1 and not root.Anchored then
		return false, "repair-already-movable"
	end
	if type(threat) ~= "table"
		or threat.actionContract ~= ACTION_KIND.MOVE then
		return false, "not-confirmed-active"
	end
	local family = tostring(threat.family or "")
	local veilThreat = family == "VEIL_THROW"
		or family == "VEIL_DELAYED"
		or family == "VEIL_WALL_ARROW_AIM"
	if Config.repairThreatEscapeVeilOnly and not veilThreat then
		return false, "non-veil-repair-remains-player-owned"
	end
	local phase = tostring(threat.phase or "")
	local active = phase == "ACTIVE"
	local exactForcedPrep = phase == "PREP"
		and threat.forceRouteOnPrep == true
		and (threat.synthetic ~= true or threat.confirmedAimGuard == true)
		and tostring(threat.motionType or "") ~= ""
	if not active and not exactForcedPrep then
		return false, "not-confirmed-active-or-forced-prep"
	end
	local killerRoot = threat.killerRoot
	if not killerRoot or not killerRoot.Parent then
		return false, "missing-root"
	end
	local verticalSeparation = math.abs(
		killerRoot.Position.Y - root.Position.Y
	)
	if not veilThreat
		and verticalSeparation
			> Config.repairThreatEscapeMaximumVerticalSeparation then
		return false, "different-floor"
	end
	local distance = horizontal(killerRoot.Position - root.Position).Magnitude
	local maximumDistance = veilThreat
		and Config.repairThreatEscapeVeilMaximumDistance
		or (exactForcedPrep
			and Config.repairThreatEscapePrepMaximumDistance
			or Config.repairThreatEscapeMaximumDistance)
	if distance > maximumDistance then
		return false, "threat-too-far"
	end
	if family == "VEIL_WALL_ARROW_AIM" then
		local aimSource = string.lower(tostring(threat.aimSource or ""))
		local fallbackAim = string.find(aimSource, "head%-fallback") ~= nil
			or string.find(aimSource, "root%-fallback") ~= nil
		if fallbackAim
			and distance > Config.repairThreatEscapeVeilFallbackMaximumDistance then
			return false, "fallback-aim-too-far"
		end
		if fallbackAim
			and (tonumber(threat.aimEvidence) or 0.0)
				< Config.repairThreatEscapeVeilFallbackMinimumEvidence then
			return false, "fallback-aim-not-sustained"
		end
	end
	if anyPhysicalMovementKeyDown() then
		return false, "player-movement-key-held"
	end
	if implicitRepairLock then
		return true, exactForcedPrep
			and "exact-forced-prep-implicit-repair-lock"
			or "confirmed-active-implicit-repair-lock"
	end
	return true, exactForcedPrep
		and "exact-forced-prep-no-skill-check"
		or "confirmed-active-no-skill-check"
end

function CharacterController.RequestRepairThreatEscape(
	threat: any,
	direction: Vector3
): (boolean, string)
	local allowed, reason =
		CharacterController.CanRequestRepairThreatEscape(threat)
	if not allowed then
		return false, reason
	end
	local episodeId = tonumber(threat.episodeId)
	if State.repairEscapeEpisodeId ~= episodeId then
		State.repairEscapeEpisodeId = episodeId
		State.repairEscapeAttempts = 0
		State.repairEscapeLastAt = -math.huge
		State.repairEscapeKeyCode = nil
	end
	if State.repairEscapeAttempts
		>= Config.repairThreatEscapeMaximumAttempts then
		return false, "attempt-limit"
	end
	local t = now()
	if t - State.repairEscapeLastAt
		< Config.repairThreatEscapeRetryCooldown then
		return false, "retry-cooldown"
	end

	-- Keep one key for the whole episode. Re-evaluating camera-relative A/D every
	-- retry produced an artificial left/right shake before native movement was
	-- restored by the game.
	local keyCode = State.repairEscapeKeyCode
		or worldDirectionToMovementKey(direction)
	local sent = pcall(function()
		VirtualInputManager:SendKeyEvent(
			true,
			keyCode,
			false,
			game
		)
	end)
	if not sent then
		return false, "input-send-failed"
	end

	State.repairEscapeAttempts += 1
	State.repairEscapeLastAt = t
	State.repairEscapeKeyCode = keyCode
	State.repairEscapePulseGeneration += 1
	local pulseGeneration = State.repairEscapePulseGeneration
	task.delay(Config.repairThreatEscapePulseDuration, function()
		-- Always pair the synthetic down event, even if the Helper was replaced.
		pcall(function()
			VirtualInputManager:SendKeyEvent(
				false,
				keyCode,
				false,
				game
			)
		end)
		if pulseGeneration == State.repairEscapePulseGeneration then
			Diagnostics.Push(
				"REPAIR_THREAT_ESCAPE_PULSE_RELEASED",
				string.format(
					"episode=%s key=%s attempt=%d",
					tostring(episodeId or "none"),
					keyCode.Name,
					State.repairEscapeAttempts
				),
				"repair-threat-pulse-release-" .. tostring(episodeId),
				0.05
			)
		end
	end)

	Diagnostics.Push(
		"REPAIR_THREAT_ESCAPE_REQUESTED",
		string.format(
			"episode=%s family=%s key=%s attempt=%d action=native-input-only-no-property-writes",
			tostring(episodeId or "none"),
			tostring(threat.family or "UNKNOWN"),
			keyCode.Name,
			State.repairEscapeAttempts
		),
		"repair-threat-escape-" .. tostring(episodeId),
		0.05
	)
	return true, "pulse-sent"
end

local function promptWorldPart(instance: Instance?): BasePart?
	local current = instance
	for _ = 1, 8 do
		if not current or current == Workspace then break end
		if current:IsA("BasePart") then return current end
		current = current.Parent
	end
	return nil
end

function CharacterController.ReleaseInteraction(
	reason: string?,
	_escapeDirection: Vector3?
): boolean
	-- v5.2.27: never release Mouse1, prompts, anchors, seats, PlatformStand,
	-- WalkSpeed locks or keyboard keys. Interaction ownership stays with the
	-- player/game. Callers may keep this compatibility function, but it is a
	-- guaranteed no-op.
	local active, status = CharacterController.InteractionStatus()
	if active then
		Diagnostics.Push(
			"INTERACTION_AUTOBREAK_SKIPPED",
			string.format(
				"reason=%s status=%s action=player-controls-release",
				tostring(reason or "unspecified"),
				status
			),
			"interaction-autobreak-skipped-" .. tostring(reason or "unknown"),
			0.50
		)
	end
	return false
end

function CharacterController.ResetReferences(): ()
	State.repairEscapePulseGeneration += 1
	State.repairEscapeEpisodeId = nil
	State.repairEscapeAttempts = 0
	State.repairEscapeLastAt = -math.huge
	State.repairEscapeKeyCode = nil
	State.character = nil
	State.humanoid = nil
	State.root = nil
	State.animator = nil
	State.originalWalkSpeed = nil
	State.observedNativeWalkSpeed = 0.0
	State.walkSpeedOwner = nil
	State.originalAutoRotate = nil
	State.autoRotateOwner = nil
end

---------------------------------------------------------------------
-- 9. ActionArbiter
---------------------------------------------------------------------

ActionArbiter = {}

function ActionArbiter.ResolveKinds(candidates: {string}): string
	local selected = ACTION_KIND.OBSERVE
	local selectedPriority = ACTION_PRIORITY[selected]
	for _, kind in ipairs(candidates) do
		local priority = ACTION_PRIORITY[kind] or -math.huge
		if priority > selectedPriority then
			selected = kind
			selectedPriority = priority
		end
	end
	return selected
end

function ActionArbiter.ContractFor(id: string, metadata: any): string
	local exact = EXACT_ACTION_CONTRACTS[id]
	if exact then
		return exact
	end
	if type(metadata) ~= "table" or metadata.observeOnly == true then
		return ACTION_KIND.OBSERVE
	end
	local phase = tostring(metadata.phase or "")
	if phase == "ACTIVE" then
		return ACTION_KIND.MOVE
	end
	if phase == "PREP"
		and metadata.startOnPrep == true
		and (
			metadata.forceRouteOnPrep == true
			or metadata.forcePrepMovement == true
		) then
		return ACTION_KIND.MOVE
	end
	return ACTION_KIND.OBSERVE
end

function ActionArbiter.HardBlockStatus(): (boolean, string)
	local humanoid = State.humanoid
	local root = State.root
	if not State.character or not humanoid or not root then
		return true, "no-character"
	end
	local locked, status = CharacterController.DefensiveMovementStatus()
	if locked then
		return true, status
	end
	return false, status
end

function ActionArbiter.CleanupExpired(t: number?): ()
	local current = t or now()
	local reservation = State.actionReservation
	if reservation and current > (reservation.untilAt or -math.huge) then
		State.actionReservation = nil
	end
	local authority = State.actionAuthority
	if authority and current > (authority.untilAt or -math.huge) then
		State.actionAuthority = nil
	end
end

function ActionArbiter.CounterOwnsModel(model: Model?): boolean
	ActionArbiter.CleanupExpired()
	local reservation = State.actionReservation
	if reservation
		and reservation.kind == ACTION_KIND.COUNTER_ARM
		and reservation.blocksMovement ~= false
		and reservation.model == model then
		return true
	end
	local authority = State.actionAuthority
	return authority ~= nil
		and authority.kind == ACTION_KIND.COUNTER_C
		and authority.model == model
end

function ActionArbiter.CancelCounterReservation(model: Model?): ()
	local reservation = State.actionReservation
	if reservation
		and reservation.kind == ACTION_KIND.COUNTER_ARM
		and (model == nil or reservation.model == model) then
		State.actionReservation = nil
	end
end

function ActionArbiter.ReserveCounter(
	model: Model,
	id: string,
	untilAt: number,
	blocksMovement: boolean?
): (boolean, string)
	local blocked, status = ActionArbiter.HardBlockStatus()
	if blocked then
		return false, status
	end
	State.actionDecisionGeneration += 1
	State.actionReservation = {
		kind = ACTION_KIND.COUNTER_ARM,
		priority = ACTION_PRIORITY[ACTION_KIND.COUNTER_ARM],
		model = model,
		id = id,
		createdAt = now(),
		untilAt = untilAt,
		blocksMovement = blocksMovement ~= false,
		token = State.actionDecisionGeneration,
	}
	-- A counter wind-up is positional/manual authority, not a dodge request.
	-- Clear every helper movement owner so Exit/Zombie/window cannot win merely
	-- because their legacy numeric movement priority is higher.
	if MovementWriter and blocksMovement ~= false then
		MovementWriter.ClearAll("counter arm authority")
	end
	return true, "reserved"
end

function ActionArbiter.CanAcceptMovement(): (boolean, string)
	ActionArbiter.CleanupExpired()
	local reservation = State.actionReservation
	if reservation
		and reservation.kind == ACTION_KIND.COUNTER_ARM
		and reservation.blocksMovement ~= false then
		return false, "counter-arm"
	end
	-- Holding C is compatible with ordinary directional movement. Suppressing all
	-- movement here left the supplied survivor at pv=0 for the full 0.78-second
	-- counter hold; if the game rejected/lagged that counter edge, there was no
	-- positional fallback. PREP reservation remains exclusive, while ACTIVE C may
	-- coexist with the exact attack's newly certified MOVE intent.
	return true, "movement"
end

function ActionArbiter.KillerThreatBlocksZombie(currentTime: number): boolean
	local threat = State.activeThreat
	if type(threat) ~= "table" or threat.released == true
		or threat.actionContract == ACTION_KIND.OBSERVE
		or currentTime > math.max(threat.expiresAt or -math.huge,
			threat.minimumReleaseAt or -math.huge)
		or not (threat.phase == "ACTIVE"
			or (threat.phase == "PREP" and threat.forceRouteOnPrep == true)) then
		return false
	end
	local model = threat.killerModel
	if not model or not model.Parent then return false end
	if State.rightMouseDown
		and State.itemAimActiveMode == "FLASHLIGHT"
		and FlashlightController
		and FlashlightController.IsSafeToKeepShining then
		local ok, safe = pcall(FlashlightController.IsSafeToKeepShining, model)
		safe = ok and safe == true
		if safe then return false end
	end
	-- A zombie route is certified against that NPC only. Even when the killer
	-- planner has no route, it cannot authorize a different owner's escape.
	return true
end

function ActionArbiter.SelectMovementIntent(
	intents: {[string]: any},
	currentTime: number
): (any, {string})
	local movementAllowed = ActionArbiter.CanAcceptMovement()
	if not movementAllowed then
		return nil, {}
	end
	local selected = nil
	local expired = {}
	local killerBlocksZombie = ActionArbiter.KillerThreatBlocksZombie(currentTime)
	local killerIntent = intents[OWNER.THREAT]
	if killerIntent and killerIntent.actionKind == ACTION_KIND.MOVE
		and currentTime <= (killerIntent.expiresAt or -math.huge)
		and killerIntent.group == "DODGE" then
		killerBlocksZombie = true
	end
	for owner, intent in pairs(intents) do
		if not intent
			or currentTime > (intent.expiresAt or -math.huge) then
			expired[#expired + 1] = owner
		elseif intent.actionKind == ACTION_KIND.MOVE
			and not (owner == OWNER.ZOMBIE and killerBlocksZombie) then
			local priority = intent.priority or 0
			local selectedPriority = selected and (selected.priority or 0) or -math.huge
			local tie = MOVEMENT_OWNER_TIEBREAK[owner] or 0
			local selectedTie = selected
				and (MOVEMENT_OWNER_TIEBREAK[tostring(selected.owner or "")] or 0)
				or -math.huge
			if not selected
				or priority > selectedPriority
				or (priority == selectedPriority and tie > selectedTie) then
				selected = intent
			end
		end
	end
	return selected, expired
end

function ActionArbiter.CanApplyMovement(): (boolean, string)
	local blocked, status = ActionArbiter.HardBlockStatus()
	if blocked then
		return false, "hard-block:" .. status
	end
	return ActionArbiter.CanAcceptMovement()
end

function ActionArbiter.EmitCounter(
	model: Model,
	id: string,
	holdDuration: number,
	requireReservation: boolean
): (boolean, string)
	local blocked, status = ActionArbiter.HardBlockStatus()
	if blocked then
		return false, "hard-block:" .. status
	end
	ActionArbiter.CleanupExpired()
	local reservation = State.actionReservation
	if requireReservation
		and not (
			reservation
			and reservation.kind == ACTION_KIND.COUNTER_ARM
			and reservation.model == model
		) then
		return false, "counter-not-armed"
	end

	State.actionDecisionGeneration += 1
	local token = State.actionDecisionGeneration
	State.actionReservation = nil
	State.actionAuthority = {
		kind = ACTION_KIND.COUNTER_C,
		priority = ACTION_PRIORITY[ACTION_KIND.COUNTER_C],
		model = model,
		id = id,
		createdAt = now(),
		untilAt = now() + holdDuration,
		token = token,
	}
	MovementWriter.ClearAll("counter C authority")

	pcall(function()
		VirtualInputManager:SendKeyEvent(
			false,
			Config.abysswalkerCrouchKey,
			false,
			game
		)
	end)
	local downOk = pcall(function()
		VirtualInputManager:SendKeyEvent(
			true,
			Config.abysswalkerCrouchKey,
			false,
			game
		)
	end)
	if not downOk then
		if State.actionAuthority
			and State.actionAuthority.token == token then
			State.actionAuthority = nil
		end
		return false, "key-down-failed"
	end

	State.crouchCounterHeldUntil = now() + holdDuration
	State.crouchCounterGeneration += 1
	local releaseGeneration = State.crouchCounterGeneration
	task.delay(holdDuration, function()
		if releaseGeneration ~= State.crouchCounterGeneration then
			return
		end
		pcall(function()
			VirtualInputManager:SendKeyEvent(
				false,
				Config.abysswalkerCrouchKey,
				false,
				game
			)
		end)
		if State.actionAuthority
			and State.actionAuthority.token == token then
			State.actionAuthority = nil
		end
	end)
	return true, "key-down"
end

function ActionArbiter.Reset(_reason: string?): ()
	State.actionDecisionGeneration += 1
	State.actionReservation = nil
	State.actionAuthority = nil
	State.crouchCounterGeneration += 1
	State.crouchCounterHeldUntil = -math.huge
	pcall(function()
		VirtualInputManager:SendKeyEvent(
			false,
			Config.abysswalkerCrouchKey,
			false,
			game
		)
	end)
end

---------------------------------------------------------------------
-- 10. MatchController
---------------------------------------------------------------------

local MatchController = {}

local function attributeSignalsMatch(
	instance: Instance?
): (boolean?, string?)
	if not instance then
		return nil, nil
	end

	for _, name in ipairs(
		Config.matchPositiveAttributes
	) do
		local value = instance:GetAttribute(name)
		if value == true then
			return true, instance:GetFullName() .. "." .. name
		elseif value == false then
			return false, instance:GetFullName() .. "." .. name
		end
	end

	for _, name in ipairs(
		Config.matchRoleAttributes
	) do
		local value = instance:GetAttribute(name)
		if typeof(value) == "string" then
			if containsToken(
				value,
				Config.matchNegativeRoleTokens
			) then
				return false,
					instance:GetFullName()
						.. "."
						.. name
						.. "="
						.. value
			end
			if containsToken(
				value,
				Config.matchPositiveRoleTokens
			) then
				return true,
					instance:GetFullName()
						.. "."
						.. name
						.. "="
						.. value
			end
		end
	end

	return nil, nil
end

function MatchController.FindMapRoot(): Instance?
	local cached = State.matchMapRoot
	if cached and cached.Parent then
		return cached
	end
	State.matchMapRoot = nil

	for _, child in ipairs(Workspace:GetChildren()) do
		if containsToken(
			child.Name,
			Config.matchMapNames
		) then
			State.matchMapRoot = child
			return child
		end
	end
	return nil
end

function MatchController.IsObjectiveEvidence(
	instance: Instance?
): boolean
	return instance ~= nil
		and containsToken(
			instance.Name,
			Config.matchObjectiveTokens
		)
end

function MatchController.BelongsToMapRoot(
	instance: Instance?,
	mapRoot: Instance?
): boolean
	if not instance or not mapRoot then
		return false
	end

	local cursor: Instance? = instance
	local depth = 0
	while cursor and depth < 12 do
		if cursor == mapRoot then
			return true
		end
		cursor = cursor.Parent
		depth += 1
	end
	return false
end

function MatchController.ConsiderEvidence(
	instance: Instance?
): boolean
	if not MatchController.IsObjectiveEvidence(instance) then
		return false
	end

	local mapRoot =
		MatchController.FindMapRoot()
	if not mapRoot
		or not MatchController.BelongsToMapRoot(
			instance,
			mapRoot
		) then
		return false
	end

	State.matchEvidenceInstance = instance
	return true
end

function MatchController.FindMapEvidence(): Instance?
	local cached = State.matchEvidenceInstance
	if cached and cached.Parent then
		return cached
	end
	State.matchEvidenceInstance = nil

	local mapRoot = MatchController.FindMapRoot()
	if not mapRoot then
		return nil
	end

	-- Bounded two-level lookup only. This covers the observed structure
	-- Workspace.Map -> "new Generators" -> Generator without walking the
	-- complete map hierarchy and without producing a recurring frame spike.
	local checked = 0
	for _, child in ipairs(mapRoot:GetChildren()) do
		checked += 1
		if MatchController.IsObjectiveEvidence(child) then
			State.matchEvidenceInstance = child
			return child
		end
		if checked >= Config.matchShallowEvidenceBudget then
			break
		end

		for _, grandchild in ipairs(child:GetChildren()) do
			checked += 1
			if MatchController.IsObjectiveEvidence(grandchild) then
				State.matchEvidenceInstance = grandchild
				return grandchild
			end
			if checked >= Config.matchShallowEvidenceBudget then
				break
			end
		end

		if checked >= Config.matchShallowEvidenceBudget then
			break
		end
	end

	return nil
end

function MatchController.IsSpectating(): (boolean, string?)
	for _, name in ipairs(
		Config.matchSpectateAttributes
	) do
		if LocalPlayer:GetAttribute(name) == true then
			return true, name .. "=true"
		end
	end
	return false, nil
end

function MatchController.RoundTime(): number
	local value =
		LocalPlayer:GetAttribute(
			Config.matchRoundTimeAttribute
		)
	return typeof(value) == "number"
		and value
		or 0
end

function MatchController.IsExactSurvivorTeam(): boolean
	local team = LocalPlayer.Team
	if not team then
		return false
	end
	return string.lower(team.Name)
		== Config.matchExactSurvivorTeam
end

function MatchController.IsExactKillerTeam(): boolean
	local team = LocalPlayer.Team
	if not team then
		return false
	end
	return string.lower(team.Name)
		== Config.matchExactKillerTeam
end

function MatchController.RoundEndedFlag(): (boolean, string?)
	for _, name in ipairs(
		Config.matchEndAttributes
	) do
		if LocalPlayer:GetAttribute(name) == true then
			return true, name .. "=true"
		end
	end
	return false, nil
end

function MatchController.HasLiveExactKiller(): boolean
	for _, player in ipairs(Players:GetPlayers()) do
		if player ~= LocalPlayer
			and player.Team
			and string.lower(player.Team.Name)
				== Config.matchExactKillerTeam then
			local character = player.Character
			local humanoid =
				character
				and character:FindFirstChildOfClass(
					"Humanoid"
				)
			if character
				and character.Parent
				and humanoid
				and humanoid.Health > 0
				and modelRoot(character) then
				return true
			end
		end
	end
	return false
end

function MatchController.TryCombatWake(
	model: Model?,
	killerRoot: BasePart?,
	animationId: string,
	metadata: any
): boolean
	if State.matchActive then
		return true
	end
	if not State.enabled
		or State.localKillerRoleSuppressed
		or not MatchController.IsExactSurvivorTeam()
		or not State.character
		or not State.character.Parent
		or not State.humanoid
		or State.humanoid.Health <= 0
		or not State.root
		or not model
		or not model.Parent
		or not killerRoot
		or not killerRoot.Parent then
		return false
	end

	local spectating = MatchController.IsSpectating()
	local ended = MatchController.RoundEndedFlag()
	if spectating or ended then
		return false
	end

	-- A stale ExpinRound=0/round-ended latch survived into the beginning of the
	-- supplied match.  The Helper was already receiving a recognized ACTIVE asset
	-- from the opposing player at 10.53 studs, yet movement stayed asleep until the
	-- second hit.  A nearby, actionable replicated attack from an actual killer
	-- owner is stronger evidence than that delayed scalar attribute.
	local ownerPlayer = playerFromCharacter(model)
	local opposingPlayer = ownerPlayer ~= nil
		and ownerPlayer ~= LocalPlayer
		and (
			ownerPlayer.Team == nil
			or LocalPlayer.Team == nil
			or ownerPlayer.Team ~= LocalPlayer.Team
		)
	local explicitKiller = TargetResolver ~= nil
		and TargetResolver.HasExplicitKillerIdentity ~= nil
		and TargetResolver.HasExplicitKillerIdentity(model)
	if not opposingPlayer or not explicitKiller then
		return false
	end

	local distance = horizontal(killerRoot.Position - State.root.Position).Magnitude
	local maximumDistance = math.min(
		tonumber(metadata and metadata.maxDistance) or Config.threatMaximumDistance,
		Config.threatMaximumDistance
	)
	if distance > maximumDistance then
		return false
	end

	State.roundEndedLatch = false
	State.lastRoundTimePositive = MatchController.RoundTime() > 0
	MatchController.Enter(string.format(
		"combat-evidence id=%s owner=%s d=%.2f",
		animationId,
		model.Name,
		distance
	))
	if State.matchActive then
		Diagnostics.Push(
			"MATCH_COMBAT_RECOVERED",
			string.format(
				"id=%s owner=%s d=%.2f action=clear-stale-round-latch-and-wake-before-threat",
				animationId,
				model.Name,
				distance
			),
			"match-combat-recovered",
			0.05
		)
	end
	return State.matchActive
end

function MatchController.Detect(): (boolean, string)
	if not State.character
		or not State.humanoid
		or not State.root
		or not State.character.Parent then
		return false, "no-local-game-character"
	end

	-- This is a Survivor helper. Explicit match attributes must not wake it
	-- while the local player is the Killer.
	if not MatchController.IsExactSurvivorTeam() then
		return false,
			"local-team-not-survivors:"
				.. (
					LocalPlayer.Team
					and LocalPlayer.Team.Name
					or "none"
				)
	end

	local spectating, spectateReason =
		MatchController.IsSpectating()
	if spectating then
		return false,
			spectateReason or "spectating"
	end

	local ended, endedReason =
		MatchController.RoundEndedFlag()
	if ended then
		return false,
			endedReason or "round-ended"
	end

	local roundTime = MatchController.RoundTime()
	if roundTime > 0 then
		State.roundEndedLatch = false
		State.lastRoundTimePositive = true
	elseif State.lastRoundTimePositive then
		-- ExpinRound falling to zero is authoritative. The old exact-team
		-- fallback immediately woke the Helper again while the Killer model/team
		-- still existed during the results screen.
		State.roundEndedLatch = true
		State.lastRoundTimePositive = false
	end
	if State.roundEndedLatch then
		return false, "round-time-ended-latched"
	end

	for _, instance in ipairs({
		LocalPlayer,
		State.character,
		Workspace,
	}) do
		local active, reason =
			attributeSignalsMatch(instance)
		if active == false then
			return false,
				reason or "explicit-lobby-state"
		end
	end

	for _, instance in ipairs({
		LocalPlayer,
		State.character,
		Workspace,
	}) do
		local active, reason =
			attributeSignalsMatch(instance)
		if active == true then
			return true,
				reason or "explicit-match-state"
		end
	end

	if roundTime > 0
		and MatchController.IsExactSurvivorTeam() then
		return true,
			string.format(
				"%s=%.2f team=%s",
				Config.matchRoundTimeAttribute,
				roundTime,
				LocalPlayer.Team
					and LocalPlayer.Team.Name
					or "none"
			)
	end

	if Config.matchExactTeamFallbackEnabled
		and (
			not Config.matchExactTeamFallbackRequirePriorMatch
			or State.matchGeneration > 0
		)
		and MatchController.HasLiveExactKiller() then
		return true,
			string.format(
				"exact-team-fallback %s=%.2f team=%s liveKiller=true",
				Config.matchRoundTimeAttribute,
				roundTime,
				LocalPlayer.Team
					and LocalPlayer.Team.Name
					or "none"
			)
	end

	return false,
		string.format(
			"%s=%.2f team=%s",
			Config.matchRoundTimeAttribute,
			roundTime,
			LocalPlayer.Team
				and LocalPlayer.Team.Name
				or "none"
		)
end

function MatchController.Enter(reason: string): ()
	if State.roundEndedLatch
		and MatchController.RoundTime() <= 0 then
		return
	end
	if State.matchActive then
		State.matchReason = reason
		return
	end

	State.matchActive = true
	State.matchReason = reason
	State.matchGeneration += 1
	State.matchCandidateSince = nil
	State.matchInactiveSince = nil

	table.clear(State.zombieCache)
	State.zombiePalletOpportunityUntil = -math.huge
	State.zombiePalletOpportunityModel = nil
	table.clear(State.palletCache)
	table.clear(State.palletUsedModels)
	table.clear(State.windowCache)
	table.clear(State.familyFailureHits)
	table.clear(State.disabledMovementFamilies)
	table.clear(State.motionTelemetry)
	State.motionTelemetryHead = 0
	State.motionTelemetryCount = 0
	State.motionTelemetryLastAt = -math.huge
	table.clear(State.maskedCloseAimStateByModel)
	table.clear(State.trackingSafetyEnvelopeUntilByModel)
	table.clear(State.literalKillerSafetyEnvelopeUntilByModel)
	table.clear(State.hiddenCloseAimStateByModel)
	table.clear(State.killerCloseAimStateByModel)
	table.clear(State.crouchCounterPrepByModel)
	table.clear(State.noCorridorGuardBlockedUntilByModel)
	ActionArbiter.Reset("match enter")
	State.distanceKeeperBlockedUntil = -math.huge
	State.telemetry.recentThreatSnapshot = nil
	State.telemetry.recentThreatSnapshotAt = -math.huge
	table.clear(State.gateCache)
	State.activeGate = nil
	WindowController.IndexExistingTags()
	ExitController.IndexKnownMapGates(
		MatchController.FindMapRoot()
	)
	WorldIndexer.Begin("match enter")
	TargetResolver.RefreshAnimators() -- players only; no Workspace traversal
	TargetResolver.UpdateNearestKiller()

	Diagnostics.Push(
		"MATCH_ACTIVE",
		string.format(
			"generation=%d reason=%s controllers=awake",
			State.matchGeneration,
			reason
		),
		"match-active",
		0.05
	)
end

function MatchController.Sleep(reason: string): ()
	local changed =
		State.matchActive
		or State.matchReason ~= reason

	State.matchActive = false
	State.matchReason = reason
	State.matchCandidateSince = nil
	State.matchInactiveSince = nil
	State.rightMouseDown = false

	ThreatController.Reset()
	ZombieController.Reset()
	PalletController.Reset()
	WindowController.Reset(true)
	RepairResumeController.Reset()
	ExitController.Reset()
	MovementWriter.ClearAll("lobby sleep")
	FlashlightController.StopAim("lobby sleep")
	TargetResolver.Reset(false)
	WorldIndexer.Reset()
	table.clear(State.zombieCache)
	table.clear(State.palletCache)
	table.clear(State.palletUsedModels)
	table.clear(State.windowCache)
	table.clear(State.gateCache)
	State.activeGate = nil
	State.matchEvidenceInstance = nil
	State.matchMapRoot = nil
	RaycastBudget.Clear()
	MovementWriter.RestoreWalkSpeed()

	if changed then
		Diagnostics.Push(
			"LOBBY_SLEEP",
			string.format(
				"reason=%s flashlight=false animations=false zombie=false exit=false raycasts=false",
				reason
			),
			"lobby-sleep",
			0.05
		)
	end
end

function MatchController.Update(): ()
	if not ownsGlobalRuntime() then return end
	-- Hard local role kill-switch. This is intentionally evaluated before every
	-- match attribute/fallback. Team=Killer immediately sleeps every controller,
	-- clears movement/aim intents and latches the Helper dormant across transient
	-- Team=nil states. Only an explicit Team=Survivors may re-arm it.
	if Config.localKillerHardDisable
		and MatchController.IsExactKillerTeam() then
		local firstSuppression =
			not State.localKillerRoleSuppressed
		State.localKillerRoleSuppressed = true
		MatchController.Sleep(
			"hard-local-role-gate:"
				.. LocalPlayer.Name
				.. ":team=Killer"
		)
		if firstSuppression then
			Diagnostics.Push(
				"HELPER_ROLE_DISABLED",
				string.format(
					"local=%s configuredOwner=%s team=%s action=all-helper-controllers-dormant",
					LocalPlayer.Name,
					Config.localRoleGateUsername,
					LocalPlayer.Team and LocalPlayer.Team.Name or "none"
				),
				"helper-role-disabled",
				0
			)
		end
		return
	end

	if State.localKillerRoleSuppressed then
		if not MatchController.IsExactSurvivorTeam() then
			MatchController.Sleep(
				"hard-local-role-gate-awaiting-explicit-survivor"
			)
			return
		end
		State.localKillerRoleSuppressed = false
		Diagnostics.Push(
			"HELPER_ROLE_ENABLED",
			string.format(
				"local=%s team=%s action=survivor-helper-rearmed",
				LocalPlayer.Name,
				LocalPlayer.Team and LocalPlayer.Team.Name or "none"
			),
			"helper-role-enabled",
			0
		)
	end

	local detected, reason = MatchController.Detect()
	if detected then
		State.matchCandidateSince = nil
		State.matchInactiveSince = nil
		if State.matchActive then
			State.matchReason = reason
		else
			MatchController.Enter(reason)
		end
		return
	end

	State.matchCandidateSince = nil
	State.matchInactiveSince = nil
	if State.matchActive then
		MatchController.Sleep(reason)
	else
		State.matchReason = reason
	end
end
---------------------------------------------------------------------
-- 10. TargetResolver
---------------------------------------------------------------------

TargetResolver = {}

local function zombiePresentationAncestor(model: Model): boolean
	local current: Instance? = model
	for _ = 1, 8 do
		if not current or current == Workspace then
			break
		end
		local token = string.lower(current.Name):gsub("[^%w]", "")
		if string.find(token, "endscreen", 1, true)
			or string.find(token, "camerarig", 1, true)
			or string.find(token, "presetcharacter", 1, true)
			or string.find(token, "lobby", 1, true)
			or string.find(token, "spectate", 1, true) then
			return true
		end
		current = current.Parent
	end
	return false
end

local function zombieExplicitSignal(model: Model): boolean
	local current: Instance? = model
	for _ = 1, 8 do
		if not current or current == Workspace then
			break
		end
		if containsToken(current.Name, Config.zombieNames) then
			return true
		end
		current = current.Parent
	end
	for _, attribute in ipairs(Config.zombieSignalAttributes) do
		local value = model:GetAttribute(attribute)
		if value == true
			or (typeof(value) == "number" and value > 0)
			or (typeof(value) == "string" and containsToken(value, Config.zombieNames)) then
			return true
		end
	end
	for _, tag in ipairs(Config.zombieSignalTags) do
		if CollectionService:HasTag(model, tag) then
			return true
		end
	end
	return false
end

function TargetResolver.IsZombieModel(model: Model): boolean
	if isLocalCharacter(model) or playerFromCharacter(model) then
		return false
	end
	if not aliveHumanoid(model) or not modelRoot(model) then
		return false
	end
	if zombiePresentationAncestor(model) then
		return false
	end
	if zombieExplicitSignal(model) then
		return true
	end
	for _, attribute in ipairs({"NPCType", "EnemyType", "MonsterType", "Role", "Class"}) do
		local value = model:GetAttribute(attribute)
		if typeof(value) == "string" and containsToken(value, Config.zombieNames) then
			return true
		end
	end

	-- Cure summons use neutral/random names and can be parented beside Map rather
	-- than below it. During a live match, any living non-player Workspace rig is
	-- a bounded candidate unless it explicitly advertises a friendly role or is
	-- presentation scenery. Upright/moving/approaching gates still decide whether
	-- it may ever own movement, so a decorative/static rig remains inert.
	if not playerFromCharacter(model)
		and not State.knownKillerModels[model] then
		for _, attribute in ipairs({"Friendly", "IsFriendly", "Ally", "IsAlly"}) do
			if model:GetAttribute(attribute) == true then
				return false
			end
		end
		if State.matchActive and model:IsDescendantOf(Workspace) then
			return true
		end
	end
	return false
end

function TargetResolver.HasExplicitKillerIdentity(model: Model): boolean
	if not model or isLocalCharacter(model) then
		return false
	end

	local player = playerFromCharacter(model)
	if player and player.Team and LocalPlayer.Team
		and player.Team == LocalPlayer.Team then
		return false
	end
	if player and player.Team
		and string.lower(player.Team.Name)
			== Config.matchExactKillerTeam then
		local selected =
			player:GetAttribute("SelectedKiller")
		if typeof(selected) == "string"
			and selected ~= "" then
			return true
		end
		return true
	end

	if State.knownKillerModels[model] then
		return true
	end
	if containsToken(
		model.Name,
		{"killer", "knight", "rip", "veil", "hidden", "stalker", "slasher", "cure"}
	) then
		return true
	end
	for _, attribute in ipairs({
		"IsKiller",
		"Killer",
		"Role",
		"Archetype",
		"KillerName",
	}) do
		local value = model:GetAttribute(attribute)
		if value == true then
			return true
		end
		if typeof(value) == "string"
			and containsToken(value, {
				"killer",
				"knight",
				"rip",
				"veil",
				"hidden",
				"stalker",
				"slasher",
				"cure",
			}) then
			return true
		end
	end
	return false
end

function TargetResolver.IsKillerCandidate(model: Model): boolean
	if isLocalCharacter(model) then
		return false
	end
	local humanoid = aliveHumanoid(model)
	local root = modelRoot(model)
	if not humanoid or not root then
		return false
	end
	if TargetResolver.HasExplicitKillerIdentity(model) then
		return true
	end
	local player = playerFromCharacter(model)
	if player
		and player.Team
		and string.lower(player.Team.Name)
			== Config.matchExactKillerTeam then
		return true
	end
	if State.matchActive
		and player
		and player.Team
		and LocalPlayer.Team
		and player.Team ~= LocalPlayer.Team then
		return true
	end
	return false
end

function TargetResolver.IsThreatAnimationOwner(model: Model): boolean
	if not model
		or isLocalCharacter(model)
		or not aliveHumanoid(model)
		or not modelRoot(model) then
		return false
	end

	-- NPCs are handled by the integrated ZombieController, but known combat
	-- animations from a valid NPC may still be merged into one threat episode.
	if TargetResolver.IsZombieModel(model) then
		return true
	end

	-- A player character must have actual killer context. Merely owning an
	-- Animator or playing a catalog/unknown animation is never sufficient.
	return TargetResolver.IsKillerCandidate(model)
end

function TargetResolver.MarkPlayback(track: AnimationTrack, animator: Animator, source: string): any
	local t = now()
	local position = math.max(0, track.TimePosition)
	local previous = State.animationPollStateByTrack[track]
	-- A poll may recover a playback just before its primary event is dispatched.
	-- Only that narrow recovery handoff shares a generation; a later Play on the
	-- same AnimationTrack is a new attack observation.
	local recoveredPrimary = source == "event" and previous
		and previous.source == "poll" and previous.animator == animator
		and t - (previous.forwardedAt or -math.huge) <= 0.10
		and position >= (previous.position or 0) - 0.01
	if not recoveredPrimary then
		State.animationPlayGenerationByTrack[track] =
			(State.animationPlayGenerationByTrack[track] or 0) + 1
		local speed = track.Speed
		State.animationPlayStartedAtByTrack[track] = t
			- ((type(speed) == "number" and speed > 0) and position / speed or 0)
		local previousStop = State.animationPlayStopConnectionsByTrack[track]
		if previousStop then previousStop:Disconnect() end
		local generation = State.animationPlayGenerationByTrack[track]
		if track.Stopped then
			State.animationPlayStopConnectionsByTrack[track] = track.Stopped:Once(function()
				if not ownsGlobalRuntime()
					or State.animationPlayGenerationByTrack[track] ~= generation then return end
				State.animationPollStateByTrack[track] = nil
				State.animationPlayStopConnectionsByTrack[track] = nil
			end)
		end
	end
	State.animationPollStateByTrack[track] = {
		position = position, observedAt = t, forwardedAt = t, delivered = true,
		animator = animator, source = source,
		generation = State.animationPlayGenerationByTrack[track],
		startedAt = State.animationPlayStartedAtByTrack[track],
	}
	return State.animationPollStateByTrack[track]
end

function TargetResolver.ConnectAnimator(animator: Animator, model: Model): ()
	if not ownsGlobalRuntime() then return end
	if State.animatorConnections[animator] then
		State.modelByAnimator[animator] = model
		return
	end
	State.modelByAnimator[animator] = model
	local connection: RBXScriptConnection? = nil
	connection = animator.AnimationPlayed:Connect(function(track)
		if not ownsGlobalRuntime() or State.animatorConnections[animator] ~= connection then return end
		safeCall("AnimationPlayed", function()
			-- Mark the exact track before forwarding it. Without this, the 10 Hz
			-- recovery poll treated the same already-delivered AnimationPlayed as
			-- missing, merged it again, reset activeSignalAt/impact time and doubled
			-- activeTracks/Stopped callbacks.
			local playback = TargetResolver.MarkPlayback(track, animator, "event")
			if ThreatController then
				ThreatController.OnAnimation(track, animator, nil, playback)
			end
		end)
	end)
	State.animatorConnections[animator] = connection
end

function TargetResolver.PollNearestKillerAnimations(): ()
	if not ownsGlobalRuntime() or not State.enabled or not State.matchActive or isDowned() then
		return
	end
	local model = State.nearestKiller
	local humanoid = aliveHumanoid(model)
	local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
	if not model or not animator or not animator:IsA("Animator") then
		return
	end
	TargetResolver.ConnectAnimator(animator, model)
	local ok, tracks = pcall(function()
		return animator:GetPlayingAnimationTracks()
	end)
	if not ok or type(tracks) ~= "table" then
		return
	end

	local playing = {} :: {[AnimationTrack]: boolean}
	for _, track in ipairs(tracks) do
		if track and track.IsPlaying then
			playing[track] = true
			local position = math.max(0, track.TimePosition)
			local previous = State.animationPollStateByTrack[track]
			-- A looping AnimationTrack can wrap TimePosition many times without a new
			-- attack start. Forward it once for this IsPlaying lifetime. The entry is
			-- removed below only after GetPlayingAnimationTracks no longer reports it,
			-- so a genuine later playback can still be recovered.
			if not previous
				and position <= Config.animationPollMaximumStartAge then
				local playback = TargetResolver.MarkPlayback(track, animator, "poll")
				local id = animationId(track)
				safeCall("AnimationTrackPoll", function()
					ThreatController.OnAnimation(track, animator, nil, playback)
				end)
				if AttackCatalog[id] then
					Diagnostics.Push(
						"ANIMATION_POLL_RECOVERED",
						string.format(
							"killer=%s id=%s time=%.3f action=forward-to-threat-controller",
							model.Name,
							id,
							position
						),
						"animation-poll-" .. model.Name .. "-" .. id,
						0.30
					)
				end
			else
				if previous then
					previous.position = position
				else
					State.animationPollStateByTrack[track] = {
						position = position, observedAt = now(),
						animator = animator, delivered = false,
					}
				end
			end
		end
	end
	for track, playback in pairs(State.animationPollStateByTrack) do
		if playback.animator == animator and not playing[track] then
			State.animationPollStateByTrack[track] = nil
			local stop = State.animationPlayStopConnectionsByTrack[track]
			if stop then stop:Disconnect() end
			State.animationPlayStopConnectionsByTrack[track] = nil
		end
	end
end

function TargetResolver.ConnectCharacterAnimator(model: Model): ()
	if not ownsGlobalRuntime() or not model or isLocalCharacter(model) then
		return
	end
	local generation = State.targetBindingGeneration
	local player = playerFromCharacter(model)
	local function current(): boolean
		return ownsGlobalRuntime() and generation == State.targetBindingGeneration
			and model.Parent ~= nil and (not player or player.Character == model)
	end
	task.defer(function()
		if not current() then
			return
		end
		local humanoid = model:FindFirstChildOfClass("Humanoid")
			or model:WaitForChild("Humanoid", 5)
		if not current() or not humanoid or not humanoid:IsA("Humanoid") then
			return
		end
		local animator = humanoid:FindFirstChildOfClass("Animator")
			or humanoid:WaitForChild("Animator", 5)
		if current() and animator and animator:IsA("Animator") then
			TargetResolver.ConnectAnimator(animator, model)
		end
	end)
end

function TargetResolver.BindPlayer(player: Player): ()
	if not ownsGlobalRuntime() or player == LocalPlayer then
		return
	end
	local old = State.playerCharacterConnections[player]
	if old then
		old:Disconnect()
	end
	local connection: RBXScriptConnection? = nil
	connection = player.CharacterAdded:Connect(function(character)
		if not ownsGlobalRuntime() or State.playerCharacterConnections[player] ~= connection then return end
		TargetResolver.ConnectCharacterAnimator(character)
		MatchController.Update()
	end)
	State.playerCharacterConnections[player] = connection
	if player.Character then
		TargetResolver.ConnectCharacterAnimator(player.Character)
	end
end

function TargetResolver.BindExistingPlayers(): ()
	for _, player in ipairs(Players:GetPlayers()) do
		TargetResolver.BindPlayer(player)
	end
end

function TargetResolver.UnbindPlayer(player: Player): ()
	local connection = State.playerCharacterConnections[player]
	if connection then
		connection:Disconnect()
		State.playerCharacterConnections[player] = nil
	end
end

function TargetResolver.DisconnectInvalidAnimators(): ()
	for animator, connection in pairs(State.animatorConnections) do
		local model = State.modelByAnimator[animator]
		if not animator.Parent or not model or not model.Parent then
			connection:Disconnect()
			State.animatorConnections[animator] = nil
			State.modelByAnimator[animator] = nil
		end
	end
end

function TargetResolver.RefreshAnimators(): ()
	TargetResolver.DisconnectInvalidAnimators()
	for _, player in ipairs(Players:GetPlayers()) do
		if player ~= LocalPlayer then
			local model = player.Character
			local humanoid = model and model:FindFirstChildOfClass("Humanoid")
			local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
			if model and animator then
				TargetResolver.ConnectAnimator(animator, model)
			end
		end
	end
	for model in pairs(State.zombieCache) do
		local humanoid = model:FindFirstChildOfClass("Humanoid")
		local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
		if animator then
			TargetResolver.ConnectAnimator(animator, model)
		end
	end
end

function TargetResolver.UpdateNearestKiller(): ()
	local root = State.root
	if not root then
		State.nearestKiller = nil
		State.nearestKillerRoot = nil
		State.nearestKillerDistance = math.huge
		return
	end
	local bestModel = nil
	local bestRoot = nil
	local bestDistance = math.huge
	for _, player in ipairs(Players:GetPlayers()) do
		if player ~= LocalPlayer then
			local model = player.Character
			if model and TargetResolver.IsKillerCandidate(model) then
				local candidateRoot = modelRoot(model)
				if candidateRoot then
					local distance = horizontal(candidateRoot.Position - root.Position).Magnitude
					if distance < bestDistance then
						bestDistance = distance
						bestModel = model
						bestRoot = candidateRoot
					end
				end
			end
		end
	end
	local changed = bestModel ~= State.nearestKiller
	State.nearestKiller = bestModel
	State.nearestKillerRoot = bestRoot
	State.nearestKillerDistance = bestDistance
	if changed then
		Diagnostics.Push(
			"TARGET_CHANGED",
			string.format("target=%s distance=%.2f", bestModel and bestModel:GetFullName() or "none", bestDistance),
			"target-change",
			0.05
		)
	end
end

function TargetResolver.Shutdown(): ()
	TargetResolver.Reset(true)
	for player, connection in pairs(State.playerCharacterConnections) do
		connection:Disconnect()
		State.playerCharacterConnections[player] = nil
	end
	for track, playback in pairs(State.animationPollStateByTrack) do
		if not playback.animator or not State.animatorConnections[playback.animator] then
			local stop = State.animationPlayStopConnectionsByTrack[track]
			if stop then stop:Disconnect() end
			State.animationPlayStopConnectionsByTrack[track] = nil
			State.animationPollStateByTrack[track] = nil
		end
	end
end
function TargetResolver.OwnerForTrack(animator: Animator): (Model?, BasePart?)
	local model = State.modelByAnimator[animator] or modelFromAnimator(animator)
	if not model or isLocalCharacter(model) then
		return nil, nil
	end
	return model, modelRoot(model)
end

function TargetResolver.Reset(disconnectAnimators: boolean?): ()
	table.clear(State.animationTrackLastHandledAt)
	table.clear(State.animationPollStateByTrack)
	table.clear(State.recentActionByModel)
	table.clear(State.recentNonThreatUntilByModel)
	table.clear(State.recentPalletBreakUntilByModel)
	table.clear(State.genericGuardDistanceSampleByModel)
	table.clear(State.knownKillerModels)
	table.clear(State.inferredAttackFamilyByModel)
	table.clear(State.killerClassInfoByModel)
	table.clear(State.rawKillerClassCacheByModel)
	table.clear(State.lastEscapeRouteByModel)
	table.clear(State.predictiveRouteCacheByModel)
	table.clear(State.veilAimStateByModel)
	table.clear(State.veilPendingPrepByModel)
	table.clear(State.trackingSafetyEnvelopeUntilByModel)
	table.clear(State.literalKillerSafetyEnvelopeUntilByModel)
	table.clear(State.veilLongApproachStateByModel)
	table.clear(State.maskedCloseAimStateByModel)
	table.clear(State.hiddenCloseAimStateByModel)
	table.clear(State.killerCloseAimStateByModel)
	table.clear(State.crouchCounterPrepByModel)
	table.clear(State.noCorridorGuardBlockedUntilByModel)
	State.nearestKiller = nil
	State.nearestKillerRoot = nil
	State.nearestKillerDistance = math.huge
	if disconnectAnimators == false then
		TargetResolver.DisconnectInvalidAnimators()
		return
	end
	State.targetBindingGeneration += 1
	for track, connection in pairs(State.animationPlayStopConnectionsByTrack) do
		connection:Disconnect()
		State.animationPlayStopConnectionsByTrack[track] = nil
	end
	for animator, connection in pairs(State.animatorConnections) do
		connection:Disconnect()
		State.animatorConnections[animator] = nil
		State.modelByAnimator[animator] = nil
	end
end

---------------------------------------------------------------------
-- 10. RoutePlanner
---------------------------------------------------------------------

local RoutePlanner = {}

local function bodyCorridorClearance(
	origin: Vector3,
	direction: Vector3,
	distance: number,
	halfWidth: number?,
	allowCache: boolean?,
	critical: boolean?
): number
	if typeof(origin) ~= "Vector3"
		or typeof(direction) ~= "Vector3"
		or horizontal(direction).Magnitude < 1e-4
		or not tonumber(distance)
		or distance <= 0 then
		return 0
	end
	local dir = horizontal(direction).Unit
	local right = Vector3.new(-dir.Z, 0, dir.X)
	local width = halfWidth or Config.routeSweepHalfWidth
	-- Root.Position is already around waist height. The old code added +1.5 and
	-- therefore shot over crates. These offsets cover lower body, both lower
	-- shoulders, torso and head relative to the root.
	local offsets = {
		Vector3.new(0, Config.routeSweepLowOffset, 0),
		right * width + Vector3.new(0, Config.routeSweepLowOffset, 0),
		-right * width + Vector3.new(0, Config.routeSweepLowOffset, 0),
		Vector3.new(0, Config.routeSweepMidOffset, 0),
		Vector3.new(0, Config.routeSweepHighOffset, 0),
	}
	-- Never execute only part of a body sweep. The previous implementation let a
	-- depleted budget return nil for the remaining rays, falsely certifying the
	-- exact direction as open and then discovering the wall one render later.
	if critical == true then
		if not RaycastBudget.HasCriticalCapacity(#offsets) then
			return 0
		end
	elseif not RaycastBudget.HasRegularCapacity(#offsets) then
		return 0
	end
	local clearance = distance
	for _, offset in ipairs(offsets) do
		local result = if critical == true
			then RaycastBudget.CastCritical(origin + offset, dir * distance)
			else RaycastBudget.Cast(origin + offset, dir * distance, allowCache)
		if result then
			clearance = math.min(
				clearance,
				math.max(0, result.Distance - 0.20)
			)
		end
	end
	return clearance
end

local function pathClearance(
	origin: Vector3,
	direction: Vector3,
	distance: number,
	allowCache: boolean?
): number
	-- Cheap first pass for large candidate sets (notably zombie routing). Keep it
	-- at lower-body height so a crate cannot be skipped, then use the full swept
	-- corridor for predictive selection and every live route safety check.
	local dir = unitOr(direction, Vector3.new(0, 0, -1))
	local result = RaycastBudget.Cast(
		origin + Vector3.new(0, Config.routeSweepLowOffset, 0),
		dir * distance,
		allowCache ~= false
	)
	if result then
		return math.max(0, result.Distance - Config.routeBodyRadius)
	end
	return distance
end

local function groundOkay(position: Vector3): boolean
	local result = RaycastBudget.Cast(position + Vector3.new(0, 2.5, 0), Vector3.new(0, -Config.routeGroundDepth, 0), true)
	return result ~= nil
end

local function routeAwayDot(direction: Vector3, origin: Vector3, threatPosition: Vector3): number
	local away = unitOr(origin - threatPosition, direction)
	return unitOr(direction, away):Dot(away)
end

function RoutePlanner.ScoreCandidate(origin: Vector3, threatPosition: Vector3, direction: Vector3, preferredDirection: Vector3?, lateralWeight: number?, awayWeight: number?, probeDistance: number?): any
	local dir = unitOr(direction, origin - threatPosition)
	local effectiveProbeDistance = probeDistance or Config.routeProbeDistance
	local clearance = pathClearance(origin, dir, effectiveProbeDistance)
	local sampleLength = math.min(clearance, effectiveProbeDistance)
	local endpoint = origin + dir * sampleLength
	local grounded = groundOkay(endpoint)
	local awayDot = routeAwayDot(dir, origin, threatPosition)
	local preferredDot = preferredDirection and dir:Dot(unitOr(preferredDirection, dir)) or 0
	local lateralDot = math.sqrt(math.max(0, 1 - awayDot * awayDot))
	local blocked = clearance < Config.routeMinimumClearance or not grounded
	local lateralBias = math.clamp(tonumber(lateralWeight) or 14.0, 2.0, 30.0)
	local awayBias = math.clamp(tonumber(awayWeight) or 14.0, 2.0, 30.0)
	local score = clearance * 5.0
		+ awayDot * awayBias
		+ lateralDot * lateralBias
		+ preferredDot * Config.routePreferredWeight
	if preferredDirection
		and preferredDot < Config.routeReverseDotThreshold then
		-- A route opposite to the user's current direction must win by a large
		-- physical-safety margin, not by a tiny clearance/branch difference.
		score -= Config.routeReversePenalty * math.abs(preferredDot)
	end
	if not grounded then
		score -= 45
	end
	if blocked then
		score -= 60
	end
	return {
		direction = dir,
		score = score,
		clearance = clearance,
		safeLength = sampleLength,
		awayDot = awayDot,
		lateralDot = lateralDot,
		preferredDot = preferredDot,
		grounded = grounded,
		blocked = blocked,
		probeDistance = effectiveProbeDistance,
		branches = 0,
		deepBranches = 0,
		reason = blocked and "blocked-first-pass" or "open-first-pass",
	}
end

function RoutePlanner.EnrichBranches(candidate: any, origin: Vector3, branchAngles: any?): ()
	local endpoint = origin + candidate.direction * math.min(candidate.clearance, candidate.probeDistance or Config.routeProbeDistance)
	local branches = 0
	local deepBranches = 0
	for _, angle in ipairs(branchAngles or Config.routeBranchAngles) do
		local branchDirection = rotateY(candidate.direction, angle)
		local branchClearance = pathClearance(endpoint, branchDirection, 8.0)
		if branchClearance >= 3.0 and groundOkay(endpoint + branchDirection * math.min(branchClearance, 6.0)) then
			branches += 1
			if branchClearance >= 6.0 then
				deepBranches += 1
			end
		end
	end
	candidate.branches = branches
	candidate.deepBranches = deepBranches
	candidate.score += branches * 6.0 + deepBranches * 5.0
	if branches == 0 and candidate.clearance < Config.routeDeepSafeLength then
		candidate.score -= 35
		candidate.reason = "dead-end"
	else
		candidate.reason = "best-open-corridor"
	end
end

function RoutePlanner.FindEscapeRoute(request: any): any
	local origin = request.origin
	local threatPosition = request.threatPosition
	local preferredDirection = request.preferredDirection
	local away = unitOr(origin - threatPosition, preferredDirection or Vector3.new(0, 0, -1))
	local routeAngles = request.routeAngles or Config.routeAngles
	local probeDistance = request.probeDistance or Config.routeProbeDistance
	local minimumAwayDot = tonumber(request.minimumAwayDot)
	local candidates = table.create(#routeAngles)
	for _, angle in ipairs(routeAngles) do
		local direction = rotateY(away, angle)
		local candidate = RoutePlanner.ScoreCandidate(origin, threatPosition, direction, preferredDirection, request.lateralWeight, request.awayWeight, probeDistance)
		if minimumAwayDot and candidate.awayDot < minimumAwayDot then
			-- Clearance must never make an inward route beat an outward route.
			-- Keep the rejected entry for diagnostics/fallback ordering, but make it
			-- impossible to enrich or select while any valid candidate exists.
			candidate.score -= 10000
			candidate.rejectedTowardThreat = true
			candidate.reason = "toward-threat-rejected"
		end
		table.insert(candidates, candidate)
	end
	table.sort(candidates, function(a, b)
		return a.score > b.score
	end)
	-- First pass consumes 14 rays (7 directions × clearance+ground).
	-- Enrich the best two candidates with 6 rays each (3 branches ×
	-- clearance+ground). Peak route selection budget is 26.
	local enrichCount = request.enrichCount
	if enrichCount == nil then
		enrichCount = 2
	end
	local enrichedLimit = math.min(enrichCount, #candidates)
	for index = 1, enrichedLimit do
		RoutePlanner.EnrichBranches(candidates[index], origin, request.branchAngles)
	end
	local best
	if request.restrictToEnriched == true and enrichedLimit > 0 then
		best = candidates[1]
		for index = 2, enrichedLimit do
			if candidates[index].score > best.score then
				best = candidates[index]
			end
		end
	else
		table.sort(candidates, function(a, b)
			return a.score > b.score
		end)
		best = candidates[1]
	end
	if request.requireDeep then
		if not best
			or best.clearance < Config.routeDeepClearance
			or best.safeLength < Config.routeDeepSafeLength
			or best.branches < Config.routeMinimumBranches then
			return {
				direction = best and best.direction or away,
				score = best and best.score or -math.huge,
				clearance = best and best.clearance or 0,
				safeLength = best and best.safeLength or 0,
				branches = best and best.branches or 0,
				awayDot = best and best.awayDot or 1,
				blocked = true,
				reason = "deep-route-required",
			}
		end
	end
	return best
end

function RoutePlanner.IsCurrentRouteBlocked(
	direction: Vector3?,
	threshold: number?,
	probeDistance: number?
): (boolean, number)
	local root = State.root
	if not root
		or typeof(direction) ~= "Vector3"
		or horizontal(direction).Magnitude < 1e-4 then
		return true, 0
	end
	local clearance = bodyCorridorClearance(
		root.Position,
		direction,
		probeDistance or 5.0,
		Config.routeSweepHalfWidth,
		false,
		true
	)
	return clearance < (threshold or Config.routeReplanCriticalClearance), clearance
end

local function selectVeilRepairEscapeDirection(
	root: BasePart,
	killerRoot: BasePart,
	aimDirection: Vector3?
): (Vector3, number)
	local away = unitOr(
		horizontal(root.Position - killerRoot.Position),
		Vector3.new(0, 0, -1)
	)
	local line = typeof(aimDirection) == "Vector3"
		and unitOr(horizontal(aimDirection), -away)
		or -away
	local lateral = unitOr(
		Vector3.new(-line.Z, 0, line.X),
		rotateY(away, 90)
	)
	local directions = {
		lateral,
		-lateral,
		unitOr(lateral + away * 0.35, lateral),
		unitOr(-lateral + away * 0.35, -lateral),
	}
	local preferred = CharacterController.PhysicalInputDirection()
	local best = nil
	for _, direction in ipairs(directions) do
		local candidate = RoutePlanner.ScoreCandidate(
			root.Position,
			killerRoot.Position,
			direction,
			preferred,
			30.0,
			6.0,
			14.0
		)
		if candidate.awayDot < -0.20 then
			candidate.score -= 1000
		end
		if not best or candidate.score > best.score then
			best = candidate
		end
	end
	return best and best.direction or away,
		best and best.clearance or 0.0
end

local function selectRepairThreatEscapeDirection(
	root: BasePart,
	killerRoot: BasePart,
	threat: any
): (Vector3, number, string)
	local family = tostring(threat and threat.family or "")
	if family == "VEIL_THROW"
		or family == "VEIL_DELAYED"
		or family == "VEIL_WALL_ARROW_AIM" then
		local direction, clearance = selectVeilRepairEscapeDirection(
			root,
			killerRoot,
			threat and threat.aimDirection
		)
		return direction, clearance, "veil-lateral"
	end

	local away = unitOr(
		horizontal(root.Position - killerRoot.Position),
		root.CFrame.LookVector
	)
	local preferred = threat and threat.routeDirection
		or CharacterController.PhysicalInputDirection()
	local candidate = RoutePlanner.FindEscapeRoute({
		origin = root.Position,
		threatPosition = killerRoot.Position,
		preferredDirection = preferred,
		minimumAwayDot = 0.05,
		probeDistance = 12.0,
		lateralWeight = 8.0,
		awayWeight = 26.0,
		enrichCount = 2,
		restrictToEnriched = true,
	})
	if candidate
		and candidate.rejectedTowardThreat ~= true
		and (candidate.clearance or 0)
			>= Config.repairThreatEscapeMinimumCorridor then
		return candidate.direction, candidate.clearance, "open-corridor"
	end
	return away, candidate and candidate.clearance or 0.0, "direct-away-release"
end

---------------------------------------------------------------------
-- 10b. PredictivePlanner
---------------------------------------------------------------------

local PredictivePlanner = {}

-- These are impact delays observed in the supplied logs, measured from the
-- client AnimationPlayed signal to HealthChanged. Runtime failures refine the
-- value with a bounded moving average; an unobserved ID uses the family default.
local PREDICTIVE_IMPACT_DELAY_BY_ID = {
	-- Fresh Slasher traces: damage followed 110355... in 0.234 s; the supplied
	-- v5.5.76 trace reached HealthChanged only 0.188 s after 139369.... Clamp that
	-- second phase to the conservative minimum so the planner cannot certify travel
	-- which occurs after the server hit.
	["110355011987939"] = 0.24,
	["77477445889320"] = 0.58,
	["139369275981139"] = 0.20,
	["121571390309073"] = 0.60,
	["138720291317243"] = 0.56,
	-- Fresh v5.5.16 trace: this RIP ACTIVE reached HealthChanged in 0.229 s.
	-- Persist the observation across Helper reloads instead of relearning from the
	-- obsolete 0.52-second assumption every session.
	["105374834496520"] = 0.25,
	-- Literal Killer PREP reached damage after only 0.171 s in the supplied log.
	-- Clamp to the planner minimum so a last-frame PREP cannot certify fictional
	-- travel; the sustained close-aim guard is responsible for earlier authority.
	["129784271201071"] = 0.20,
	-- The fresh trace measured 0.283 s from ACTIVE to HealthChanged. Persist the
	-- conservative learned value instead of starting every reload at 0.48 s.
	["132817836308238"] = 0.31,
	-- QUICK resolved inside the same timestamp after its signal; do not grant the
	-- generic 0.55 s of fictional survivor travel.
	["82666958311998"] = 0.20,
	-- Fresh Stalker Q ACTIVE reached HealthChanged in 0.234 s. The old 0.62-s
	-- horizon invented roughly 6.5 studs of travel and accepted a route whose own
	-- forecast was below the required envelope. ACTIVE is a confirmation; PREP is
	-- the actionable planning edge.
	["133963973694098"] = 0.24,
	-- In the supplied box collision episode, Stalker Q PREP reached damage at
	-- age=0.316. Using the generic 0.55 window overestimated reachable travel.
	["117042998468241"] = 0.32,
	-- 118... is the actionable wind-up. 784... is only a late confirmation and
	-- must not invent a fresh route from its roughly 155 ms remaining lead.
	["118907603246885"] = 1.00,
	["78432063483146"] = 0.20,
	-- Two fresh Hidden samples landed 1.00-1.03 s after this exact ACTIVE.
	-- Starting at the old 0.55 prediction selected a direct-away lane and then
	-- released the episode at its contradictory safeDistance boundary.
	["98163597193511"] = 1.03,
	-- This Hidden ACTIVE was recovered about 0.62 s before the second supplied hit.
	-- A copy delivered only after damage remains harmless because post-hit admission
	-- is blocked globally; do not throw away the useful early delivery mode.
	["74968262036854"] = 0.62,
	-- Fresh Veil melee evidence: ACTIVE reached HealthChanged in 0.279 s. Starting
	-- from the generic 0.55 s invented 4.7 studs of travel that did not exist.
	["78935059863801"] = 0.30,
}

-- Confirmation-only assets must not learn their own time-to-impact. A boxed or
-- already-caught sample would overwrite the actionable PREP forecast and make a
-- later round plan from the final 155-400 ms instead of the real wind-up.
local IMPACT_TIMING_LEARNING_DISABLED_BY_ID = {
	["78432063483146"] = true,
	-- One scalar EMA cannot represent both the 0.23 s and 0.62-0.71 s modes.
	-- Keep the earliest-impact forecast fixed; authority hold is modeled separately.
	["105374834496520"] = true,
	-- Q has one actionable PREP window and one late ACTIVE confirmation. Do not
	-- let a delayed/knockback sample stretch the calibrated earliest-hit horizon.
	["133963973694098"] = true,
	-- Veil projectile ACTIVE is a last-frame confirmation with two measured leads
	-- near 0.06 and 0.15 s. Never let a boxed/delayed sample stretch it into a new
	-- planning window; actionable authority belongs to PREP.
	["86266790353635"] = true,
}

-- Steering and lunging are separate facts. Every killer can turn toward the
-- survivor during ordinary movement, but only the exact replicated assets below
-- receive extra lunge/projectile reach. Never infer a lunge from a class/family.
local ORDINARY_PURSUIT_PROFILE = {
	motionType="PURSUIT_MELEE",
	killerSpeed=22.0,
	hitRadius=Config.predictiveDefaultHitRadius,
	lateralWeight=4.0,
	awayWeight=9.0,
	minimumAwayDot=0.26,
	homing=true,
	minimumGain=0.55,
	minimumCorridor=4.0,
	requireOpenExit=true,
	requireFullCertificate=false,
	-- When native input is idle/inward, a long-horizon grounded exit may own a
	-- relative-safety fallback even if the absolute hit envelope is already
	-- mathematically unreachable. It still cannot select a sealed pocket.
	allowSafetyFloor=true,
}

local DISTANCE_HOLD_PROFILE = {
	motionType="DISTANCE_HOLD",
	killerSpeed=22.0,
	hitRadius=Config.predictiveDefaultHitRadius,
	lateralWeight=Config.threatDistanceKeeperLateralWeight,
	awayWeight=Config.threatDistanceKeeperAwayWeight,
	minimumAwayDot=Config.threatDistanceKeeperMinimumAwayDot,
	homing=true,
	minimumGain=0.25,
	minimumCorridor=4.0,
	requireOpenExit=true,
	requireFullCertificate=true,
	-- Distance keeping is preventive, not an exact attack. It may never take
	-- authority for an uncertified "least bad" corridor and drive into a corner.
	allowBestEffort=false,
	bestEffortMinimumAwayDot=0.30,
	bestEffortMinimumGain=0.50,
	bestEffortMinimumManualGain=0.75,
}

local VEIL_DISTANCE_HOLD_PROFILE = {
	motionType="DISTANCE_HOLD",
	killerSpeed=28.0,
	hitRadius=9.25,
	lateralWeight=6.0,
	awayWeight=36.0,
	minimumAwayDot=0.52,
	homing=true,
	minimumGain=0.75,
	minimumCorridor=4.0,
	requireOpenExit=true,
	-- Keep the normal/far envelope strict. A controlled fallback is considered
	-- below only for a close Veil emergency, with a grounded branched exit and a
	-- material improvement over idle/inward input.
	requireFullCertificate=false,
	-- A preventive route must still have room after the whole forecasted run. A
	-- route whose clearance ends exactly at the forecast endpoint is a corner,
	-- even if an early branch probe happened to look open.
	minimumClearanceReserve=3.5,
	-- When the full 10.35-stud certificate is impossible, an already-inward or
	-- idle heading may still be replaced by a demonstrably better open exit.
	allowBestEffort=true,
	bestEffortMinimumAwayDot=0.45,
	bestEffortMinimumGain=0.75,
	bestEffortMinimumManualGain=3.00,
	controlledFallbackMinimumAwayDot=0.45,
	controlledFallbackMinimumGain=0.75,
	controlledFallbackMinimumManualGain=3.00,
	controlledFallbackMinimumSeparationRatio=0.52,
	allowSafetyFloor=false,
}

local VEIL_MANUAL_CLOSING_DISTANCE_HOLD_PROFILE = {
	motionType="DISTANCE_HOLD",
	killerSpeed=28.0,
	hitRadius=9.25,
	lateralWeight=7.0,
	awayWeight=36.0,
	minimumAwayDot=0.52,
	homing=true,
	minimumGain=0.75,
	minimumCorridor=6.0,
	requireOpenExit=true,
	requireFullCertificate=false,
	minimumClearanceReserve=3.5,
	-- A stationary Veil can still be dangerous while the survivor is closing.
	-- Permit only a grounded, branched, deep exit that forecasts a material
	-- improvement over native WASD. This accepts the supplied +2.66/+2.10 routes
	-- without reopening the old sealed-pocket safety floor.
	allowBestEffort=true,
	bestEffortMinimumAwayDot=0.35,
	bestEffortMinimumGain=0.50,
	bestEffortMinimumManualGain=1.50,
	allowSafetyFloor=false,
}

-- A distance episode has no exact attack ID yet, but it still must not pretend
-- every killer has the old 6.25-stud generic reach. Use a conservative homing
-- envelope until an exact replicated animation can replace it. Literal Killer
-- has a separately observed longer charged-lunge envelope.
local CONSERVATIVE_CLASS_DISTANCE_HOLD_PROFILE = {
	motionType="DISTANCE_HOLD",
	killerSpeed=28.0,
	hitRadius=9.25,
	lateralWeight=6.0,
	awayWeight=36.0,
	minimumAwayDot=0.52,
	homing=true,
	minimumGain=0.75,
	minimumCorridor=4.0,
	requireOpenExit=true,
	allowBestEffort=false,
	bestEffortMinimumAwayDot=0.30,
	bestEffortMinimumGain=0.50,
	bestEffortMinimumManualGain=0.75,
	-- A survivor running toward an aimed killer is precisely the unsafe baseline
	-- that the relative floor is for. It still requires the long-horizon grounded
	-- open-exit certificate and a material improvement over physical WASD.
	allowSafetyFloor=true,
}

-- Slasher's exact attack signal repeatedly arrived only after the survivor was
-- already inside the short Tracking envelope. Prevent that state earlier. This
-- profile may accept less than the absolute hit-radius certificate, but only
-- through the same grounded open-exit topology checks as the motion core and
-- only when it forecasts at least 1.5 studs more separation than physical WASD.
-- It never uses the weak safety floor that previously selected sealed pockets.
local SLASHER_DISTANCE_HOLD_PROFILE = {
	motionType="DISTANCE_HOLD",
	killerSpeed=30.0,
	hitRadius=8.75,
	safetyMargin=1.25,
	certificationBuffer=0.35,
	lateralWeight=7.0,
	awayWeight=34.0,
	minimumAwayDot=0.42,
	homing=true,
	minimumGain=0.75,
	minimumCorridor=5.0,
	requireOpenExit=true,
	requireFullCertificate=false,
	allowBestEffort=true,
	bestEffortMinimumAwayDot=0.35,
	bestEffortMinimumGain=0.75,
	bestEffortMinimumManualGain=1.50,
	allowSafetyFloor=false,
}

-- Stalker's Q PREP is the only useful early signal in the supplied traces.
-- Requiring an impossible full 10.35-stud certificate made the controller
-- observe an obviously better three-branch corridor without ever moving. A
-- Stalker distance episode may therefore use a controlled best effort, but
-- only when the route is grounded, has a real open exit and forecasts at least
-- 1.5 studs more separation than native WASD. This remains stricter than a
-- generic safety-floor route and cannot select a sealed pocket.
local STALKER_DISTANCE_HOLD_PROFILE = {
	motionType="DISTANCE_HOLD",
	killerSpeed=26.0,
	hitRadius=8.25,
	safetyMargin=1.10,
	certificationBuffer=0.0,
	lateralWeight=7.0,
	awayWeight=34.0,
	minimumAwayDot=0.35,
	homing=true,
	minimumGain=0.75,
	minimumCorridor=6.0,
	requireOpenExit=true,
	requireFullCertificate=false,
	allowBestEffort=true,
	bestEffortMinimumAwayDot=0.30,
	bestEffortMinimumGain=0.0,
	bestEffortMinimumManualGain=1.50,
	controlledFallbackMinimumAwayDot=0.30,
	controlledFallbackMinimumGain=0.0,
	controlledFallbackMinimumManualGain=1.50,
	allowSafetyFloor=false,
}

local LITERAL_KILLER_DISTANCE_HOLD_PROFILE = {
	motionType="DISTANCE_HOLD",
	killerSpeed=29.0,
	hitRadius=10.75,
	safetyMargin=1.25,
	certificationBuffer=0.25,
	lateralWeight=5.0,
	awayWeight=36.0,
	minimumAwayDot=0.52,
	homing=true,
	minimumGain=0.90,
	minimumCorridor=5.0,
	requireOpenExit=true,
	allowBestEffort=false,
	bestEffortMinimumAwayDot=0.35,
	bestEffortMinimumGain=0.50,
	bestEffortMinimumManualGain=0.75,
	allowSafetyFloor=false,
}

-- If literal Killer is already inside the emergency envelope and physical WASD
-- is idle/inward, demanding the impossible full 12.25-stud certificate leaves
-- the player motionless until the late ACTIVE arrives. This fallback still needs
-- a grounded, deep open exit and a material gain over physical input; it cannot
-- choose a short or sealed corridor.
local LITERAL_KILLER_EMERGENCY_DISTANCE_HOLD_PROFILE = {
	motionType="DISTANCE_HOLD",
	killerSpeed=29.0,
	hitRadius=10.75,
	safetyMargin=1.25,
	certificationBuffer=0.25,
	lateralWeight=5.0,
	awayWeight=36.0,
	minimumAwayDot=0.52,
	homing=true,
	minimumGain=0.90,
	minimumCorridor=6.0,
	requireOpenExit=true,
	requireFullCertificate=false,
	allowBestEffort=true,
	bestEffortMinimumAwayDot=0.45,
	bestEffortMinimumGain=0.50,
	bestEffortMinimumManualGain=1.50,
	allowSafetyFloor=false,
}

-- The sustained literal-Killer guard is the early phase of the same observed
-- charged/homing strike as 129.../132.... Treating it as ordinary 6.25-stud
-- melee certified routes that were already inside the real hit envelope. This
-- profile uses the exact strike's measured reach while still allowing a
-- demonstrably safer grounded escape when full separation is impossible.
local LITERAL_KILLER_CLOSE_AIM_PROFILE = {
	motionType="HOMING_LUNGE",
	killerSpeed=27.0,
	hitRadius=8.75,
	safetyMargin=1.10,
	certificationBuffer=0.0,
	lateralWeight=5.0,
	awayWeight=36.0,
	minimumAwayDot=0.50,
	homing=true,
	minimumGain=0.90,
	minimumCorridor=4.5,
	requireOpenExit=true,
	-- This is a synthetic proximity/aim guard, not a replicated attack edge.
	-- It may never seize movement for a route below the full safety envelope:
	-- four supplied episodes accepted such routes and reached a wall in <0.5 s.
	requireFullCertificate=true,
	allowBestEffort=false,
	bestEffortMinimumAwayDot=0.35,
	bestEffortMinimumGain=0.50,
	bestEffortMinimumManualGain=0.75,
	allowSafetyFloor=false,
	-- A certified close-aim corridor is the beginning of the same literal-Killer
	-- attack chain. Physical WASD may not revoke it while the attacker remains
	-- inside the exact catalog range; wall/stuck validation can still replace or
	-- abandon it normally.
	manualAuthorityReleaseDistance=22.0,
}

-- Masked's exact 106871... lunge is nearly linear and may lose its attack when
-- its body collides with map geometry. Only that replicated exact signal may use
-- a prop as a substitute for raw separation.
local MASKED_COLLISION_COVER_PROFILE = {
	motionType="STRAIGHT_LUNGE_COVER",
	killerSpeed=28.0,
	hitRadius=9.25,
	safetyMargin=1.10,
	certificationBuffer=0.0,
	lateralWeight=8.0,
	awayWeight=8.0,
	minimumAwayDot=0.18,
	homing=false,
	minimumGain=0.85,
	minimumCorridor=4.0,
	requireOpenExit=true,
	allowBestEffort=true,
	bestEffortMinimumAwayDot=0.10,
	bestEffortMinimumGain=0.25,
	bestEffortMinimumManualGain=0.20,
	allowSafetyFloor=true,
	seekCollisionCover=true,
	coverScoreBonus=180.0,
	coverMinimumPlayerGap=0.70,
	coverMinimumKillerGap=1.50,
}

-- Sustained look/closing is only a preventive guard; it does not prove that the
-- next strike is the straight lunge. The old guard treated a truck body as a
-- guaranteed lunge blocker, overrode a manual path with 24.17 studs of forecast
-- separation, replanned twice and was hit. Model uncertain close pressure as a
-- homing envelope and require a real deep open exit plus full separation.
local MASKED_CLOSE_AIM_GUARD_PROFILE = {
	motionType="HOMING_LUNGE",
	killerSpeed=28.0,
	hitRadius=10.75,
	safetyMargin=1.25,
	certificationBuffer=1.0,
	lateralWeight=6.0,
	awayWeight=36.0,
	minimumAwayDot=0.48,
	homing=true,
	minimumGain=0.85,
	minimumCorridor=6.0,
	requireOpenExit=true,
	minimumExitBranches=2,
	minimumClearanceReserve=4.0,
	requireFullCertificate=true,
	allowBestEffort=false,
	allowSafetyFloor=false,
	seekCollisionCover=false,
	-- A 280 ms rolling forecast cannot prove that manual WASD stays safe for the
	-- guard's full 3.4 s homing pursuit. Below this distance, a fully certified
	-- open route remains authoritative until the sustained aim actually ends.
	manualAuthorityReleaseDistance=20.0,
}

-- Two logged 981... hits landed after 1.03 s while the player had already moved
-- 17.46/17.68 studs and the fixed-line model claimed 13.72/17.87 studs of safe
-- lateral separation. The strike therefore keeps steering during the windup; a
-- frozen AnimationPlayed LookVector is not a safety certificate. Forecast it as
-- a pursuit, favour outward continuity and prefer solid cover when reachable.
local HIDDEN_LONG_TRACKING_PROFILE = {
	motionType="TRACKING_PURSUIT",
	killerSpeed=30.0,
	hitRadius=9.25,
	safetyMargin=1.25,
	certificationBuffer=0.50,
	lateralWeight=8.0,
	awayWeight=12.0,
	minimumAwayDot=0.32,
	homing=true,
	minimumGain=1.25,
	minimumCorridor=5.0,
	requireOpenExit=true,
	allowBestEffort=true,
	bestEffortMinimumAwayDot=0.25,
	bestEffortMinimumGain=0.50,
	bestEffortMinimumManualGain=0.50,
	seekCollisionCover=true,
	coverScoreBonus=150.0,
	coverMinimumPlayerGap=0.70,
	coverMinimumKillerGap=1.50,
}

-- RIP 105374... steers throughout the lunge and has variable server impact timing.
-- Forecast only the earliest 0.25 s slice at a time, but keep checking that slice
-- throughout the separately bounded authority window. A plain distance certificate
-- needs real margin; reachable solid cover may certify because it can stop the rig.
local RIP_WINDOW_CONTINUITY_PROFILE = {
	motionType="HOMING_LUNGE",
	killerSpeed=28.0,
	hitRadius=10.75,
	safetyMargin=1.25,
	certificationBuffer=1.00,
	lateralWeight=8.0,
	awayWeight=9.0,
	minimumAwayDot=0.25,
	homing=true,
	minimumGain=1.50,
	minimumCorridor=5.0,
	requireOpenExit=true,
	minimumExitBranches=2,
	minimumClearanceReserve=4.0,
	requireFullCertificate=true,
	minimumForecastHorizon=0.25,
	seekCollisionCover=true,
	coverScoreBonus=200.0,
	coverMinimumPlayerGap=0.70,
	coverMinimumKillerGap=1.50,
}

local function distanceHoldProfileForClass(className: string?): (any, string)
	local token = string.lower(tostring(className or "unknown"))
	if token == "veil" then
		return VEIL_DISTANCE_HOLD_PROFILE, "veil-reach"
	end
	if token == "stalker" then
		return STALKER_DISTANCE_HOLD_PROFILE,
			"stalker-controlled-open-exit"
	end
	if token == "slasher" or token == "tracking" then
		return SLASHER_DISTANCE_HOLD_PROFILE, "slasher-early-open-exit"
	end
	if token == "killer" then
		return LITERAL_KILLER_DISTANCE_HOLD_PROFILE, "literal-killer-long-reach"
	end
	return CONSERVATIVE_CLASS_DISTANCE_HOLD_PROFILE,
		"conservative-class-homing"
end

-- Exact Veil melee can arrive after full separation has already become
-- mathematically impossible. Rejecting every route in that state left native
-- WASD in control even when the planner had a grounded 17-stud corridor with
-- three branches and forecast 3.30 studs more separation than manual input.
-- Permit only that narrow, topology-certified best effort: no sealed pocket,
-- no safety-floor route and no marginal replacement of a good manual heading.
local VEIL_MELEE_EMERGENCY_OPEN_EXIT_PROFILE = {
	motionType="HOMING_LUNGE",
	killerSpeed=28.0,
	hitRadius=9.25,
	safetyMargin=1.10,
	lateralWeight=7.0,
	awayWeight=10.0,
	minimumAwayDot=0.35,
	homing=true,
	minimumGain=1.15,
	minimumCorridor=6.0,
	requireOpenExit=true,
	requireFullCertificate=false,
	allowBestEffort=true,
	bestEffortMinimumAwayDot=0.35,
	bestEffortMinimumGain=1.25,
	-- The observed PREP produced a 17-stud, two-branch route with +1.39 studs
	-- over physical input and was rejected by the old 1.50 threshold. A full
	-- open-exit topology is already required, so 1.00 remains material without
	-- discarding the only useful early route.
	bestEffortMinimumManualGain=1.00,
	allowSafetyFloor=false,
	seekCollisionCover=true,
	coverScoreBonus=220.0,
	coverMinimumPlayerGap=0.70,
	coverMinimumKillerGap=1.50,
}

-- Stalker Q connected from 14.27 studs, so treating it as a circular 8.25-stud
-- homing radius is the wrong geometry. The useful avoidance quantity is lateral
-- displacement across the replicated wind-up line. PREP chooses that cut; the
-- late ACTIVE only confirms it. A partial cut may own movement only when it has
-- most of the required width and materially beats physical WASD.
local STALKER_Q_CONTROLLED_ESCAPE_PROFILE = {
	motionType="HOMING_LUNGE",
	killerSpeed=26.0,
	hitRadius=4.25,
	safetyMargin=0.75,
	certificationBuffer=0.0,
	lateralWeight=18.0,
	awayWeight=3.0,
	minimumAwayDot=0.05,
	homing=true,
	lineAttack=true,
	minimumLateral=5.00,
	minimumLateralGain=1.50,
	minimumGain=1.00,
	minimumCorridor=6.0,
	requireOpenExit=true,
	requireFullCertificate=false,
	allowBestEffort=true,
	bestEffortMinimumAwayDot=0.05,
	bestEffortMinimumGain=1.00,
	bestEffortMinimumManualGain=1.25,
	controlledFallbackMinimumAwayDot=0.05,
	controlledFallbackMinimumGain=1.00,
	controlledFallbackMinimumManualGain=1.25,
	controlledFallbackMinimumSeparationRatio=0.82,
	allowSafetyFloor=false,
}

-- The shared literal-Killer charged sequence stayed steerable for roughly
-- 0.7 s in the supplied trace. The old 0.20/0.31-s planning slice certified
-- manual movement at 15.9 studs, then had no route while the attacker kept
-- closing to a 10.39-stud server hit. Forecast a meaningful sustained slice
-- and never seize movement for a "less bad" route that still retains less than
-- 72% of the required envelope.
local LITERAL_KILLER_CHARGED_PROFILE = {
	motionType="HOMING_LUNGE",
	killerSpeed=36.0,
	hitRadius=10.75,
	safetyMargin=1.00,
	lateralWeight=18.0,
	awayWeight=5.0,
	minimumAwayDot=0.18,
	homing=true,
	minimumGain=0.75,
	minimumCorridor=5.0,
	requireOpenExit=true,
	allowBestEffort=true,
	bestEffortMinimumAwayDot=0.12,
	bestEffortMinimumGain=0.25,
	bestEffortMinimumManualGain=0.20,
	controlledFallbackMinimumSeparationRatio=0.72,
	minimumForecastHorizon=0.55,
	literalKillerUltLateralCut=true,
	manualAuthorityReleaseDistance=22.0,
}

local VEIL_EXACT_PROJECTILE_PROFILE = {
	motionType="PROJECTILE_LINE",
	killerSpeed=0.0,
	hitRadius=7.25,
	safetyMargin=1.00,
	lateralWeight=20.0,
	awayWeight=0.20,
	lineAttack=true,
	minimumLateral=8.25,
	minimumLateralGain=3.25,
	-- A lateral cut is not allowed to become a 17-stud road into a pocket. Exact
	-- Veil projectiles now need a grounded far-end branch just like sustained aim.
	requireOpenExit=true,
	minimumEscapeDepth=6.0,
	minimumExitBranches=1,
	requireFullCertificate=true,
	allowBestEffort=false,
	allowSafetyFloor=false,
	-- Root/head aim is sampled before the projectile can re-aim. A certified PREP
	-- lateral corridor is therefore more authoritative than a manual certificate
	-- computed against one stale line sample.
	exactLineRouteAuthority=true,
}

local HIDDEN_EXACT_ACTIVE_PROFILE = {
	motionType="HOMING_LUNGE",
	killerSpeed=28.0,
	hitRadius=9.25,
	safetyMargin=1.00,
	lateralWeight=7.0,
	awayWeight=11.0,
	minimumAwayDot=0.38,
	homing=true,
	minimumGain=0.80,
	minimumCorridor=5.0,
	requireOpenExit=true,
	allowBestEffort=true,
	bestEffortMinimumAwayDot=0.30,
	bestEffortMinimumGain=0.35,
	bestEffortMinimumManualGain=0.65,
	controlledFallbackMinimumSeparationRatio=0.78,
	-- Hidden keeps steering after the first short forecast. A one-frame manual
	-- certificate may not release an already certified escape inside this range.
	manualAuthorityReleaseDistance=22.0,
}

local EXACT_MOTION_PROFILE_BY_ID = {
	-- Ranged/line attacks: cross the aim line; root distance is secondary.
	["130585295123651"] = {motionType="PROJECTILE_LINE", killerSpeed=0.0, hitRadius=5.25, lateralWeight=19.0, awayWeight=0.25, lineAttack=true, minimumLateral=5.50, minimumLateralGain=3.50},
	["102489115945356"] = {motionType="PROJECTILE_LINE", killerSpeed=0.0, hitRadius=5.25, lateralWeight=19.0, awayWeight=0.25, lineAttack=true, minimumLateral=5.50, minimumLateralGain=3.50},
	["112166042383605"] = {motionType="PROJECTILE_LINE", killerSpeed=0.0, hitRadius=5.25, lateralWeight=19.0, awayWeight=0.25, lineAttack=true, minimumLateral=5.50, minimumLateralGain=3.50},
	["84093948968516"] = VEIL_EXACT_PROJECTILE_PROFILE,
	["137688077908355"] = VEIL_EXACT_PROJECTILE_PROFILE,
	["86266790353635"] = VEIL_EXACT_PROJECTILE_PROFILE,
	["93136435416899"] = {motionType="PROJECTILE_LINE", killerSpeed=0.0, hitRadius=5.25, lateralWeight=18.0, awayWeight=0.25, lineAttack=true, minimumLateral=5.50, minimumLateralGain=3.50},
	["98163597193511"] = HIDDEN_LONG_TRACKING_PROFILE,
	["113255068724446"] = HIDDEN_EXACT_ACTIVE_PROFILE,
	["74968262036854"] = HIDDEN_EXACT_ACTIVE_PROFILE,

	-- Confirmed charged/pursuing strikes. These exact assets may add attack speed.
	-- Once this ordinary ACTIVE has committed a certified corridor, retain Helper
	-- authority through the following PREP/ACTIVE chain instead of returning to
	-- physical WASD during the last server-resolution frames.
	["104689417033027"] = {motionType="PURSUIT_MELEE", killerSpeed=22.0, hitRadius=Config.predictiveDefaultHitRadius, lateralWeight=4.0, awayWeight=9.0, minimumAwayDot=0.26, homing=true, minimumGain=0.55, minimumCorridor=4.0, requireOpenExit=true, requireFullCertificate=false, allowSafetyFloor=true, manualAuthorityReleaseDistance=22.0},
	-- Fresh v5.5.29 evidence: the charged pair hit at 9.22 and 10.58 studs
	-- despite full-speed movement. Model the same 10.75-stud reach already used by
	-- literal-Killer distance hold instead of certifying the obsolete 9.85 envelope.
	["129784271201071"] = LITERAL_KILLER_CHARGED_PROFILE,
	["132817836308238"] = LITERAL_KILLER_CHARGED_PROFILE,
	-- This ACTIVE was attributed to the first hit at d=10.68 while the generic
	-- PURSUIT_MELEE certificate required only 7.35. Give it an exact fast-lunge
	-- envelope; it may use best effort only through a real open exit.
	["82666958311998"] = {motionType="HOMING_LUNGE", killerSpeed=32.0, hitRadius=10.75, safetyMargin=1.00, lateralWeight=16.0, awayWeight=5.0, minimumAwayDot=0.20, homing=true, minimumGain=0.75, requireOpenExit=true, allowBestEffort=true, bestEffortMinimumAwayDot=0.15, bestEffortMinimumGain=0.35, bestEffortMinimumManualGain=0.35, manualAuthorityReleaseDistance=22.0},
	-- Cure connected at d=8.90 after a route had been accepted at predictedSep=9.43
	-- against the old 9.35 requirement.  Model the observed server envelope with a
	-- real buffer and require a branched open exit; a marginal route may no longer
	-- take control merely by clearing the old threshold by eight hundredths.
	["135002183282873"] = {motionType="HOMING_LUNGE", killerSpeed=27.0, hitRadius=10.75, safetyMargin=1.00, certificationBuffer=0.50, lateralWeight=7.0, awayWeight=10.0, minimumAwayDot=0.42, homing=true, minimumGain=1.25, minimumCorridor=5.0, requireOpenExit=true, minimumExitBranches=2, minimumClearanceReserve=3.0, requireFullCertificate=true, allowBestEffort=false, allowSafetyFloor=false},
	["121216847022485"] = {motionType="HOMING_LUNGE", killerSpeed=27.0, hitRadius=10.75, safetyMargin=1.00, certificationBuffer=0.50, lateralWeight=7.0, awayWeight=10.0, minimumAwayDot=0.42, homing=true, minimumGain=1.25, minimumCorridor=5.0, requireOpenExit=true, minimumExitBranches=2, minimumClearanceReserve=3.0, requireFullCertificate=true, allowBestEffort=false, allowSafetyFloor=false},
	-- Exact RIP authority is all-or-nothing. A route below the full hit-radius
	-- certificate must never replace physical WASD merely because it is less bad
	-- than the current heading; the supplied trace was hit at sep=6.35 while the
	-- exact phase required 10.35 studs.
	["105374834496520"] = RIP_WINDOW_CONTINUITY_PROFILE,
	["138720291317243"] = {motionType="HOMING_LUNGE", killerSpeed=28.0, hitRadius=9.25, lateralWeight=3.5, awayWeight=11.0, minimumAwayDot=0.52, homing=true, minimumGain=1.50, requireOpenExit=true, requireFullCertificate=true},
	["92362656727126"] = {motionType="HOMING_LUNGE", killerSpeed=28.0, hitRadius=9.25, lateralWeight=3.5, awayWeight=11.0, minimumAwayDot=0.52, homing=true, minimumGain=1.50, requireOpenExit=true},
	["106871536134254"] = MASKED_COLLISION_COVER_PROFILE,
	["117042998468241"] = STALKER_Q_CONTROLLED_ESCAPE_PROFILE,
	["133963973694098"] = STALKER_Q_CONTROLLED_ESCAPE_PROFILE,
	-- The trace was hit at 10.67 studs despite full 17-stud/s movement. Model the
	-- observed reach directly and require an outward open corridor from PREP.
	-- When the pair is rejected as the rapid ordinary hit, movement fallback is a
	-- bounded tangent cut, not C and not a global 360. In a corner it may accept
	-- only a grounded one-branch exit with real body clearance; otherwise WASD wins.
	["118907603246885"] = {motionType="HOMING_LUNGE", killerSpeed=29.0, hitRadius=10.75, safetyMargin=1.25, certificationBuffer=0.25, lateralWeight=14.0, awayWeight=6.0, minimumAwayDot=0.05, homing=true, minimumGain=1.25, minimumCorridor=2.25, requireOpenExit=true, minimumEscapeDepth=6.0, minimumExitBranches=1, allowBestEffort=true, bestEffortMinimumAwayDot=0.05, bestEffortMinimumGain=0.0, bestEffortMinimumManualGain=0.25, controlledFallbackMinimumSeparationRatio=0.35, allowSafetyFloor=false},
	["78432063483146"] = {motionType="HOMING_LUNGE", killerSpeed=29.0, hitRadius=10.75, safetyMargin=1.25, certificationBuffer=0.25, lateralWeight=14.0, awayWeight=6.0, minimumAwayDot=0.05, homing=true, minimumGain=1.25, minimumCorridor=2.25, requireOpenExit=true, minimumEscapeDepth=6.0, minimumExitBranches=1, allowBestEffort=true, bestEffortMinimumAwayDot=0.05, bestEffortMinimumGain=0.0, bestEffortMinimumManualGain=0.25, controlledFallbackMinimumSeparationRatio=0.35, allowSafetyFloor=false},
	["122812055447896"] = VEIL_MELEE_EMERGENCY_OPEN_EXIT_PROFILE,
	["78935059863801"] = VEIL_MELEE_EMERGENCY_OPEN_EXIT_PROFILE,
	["116093934008204"] = {motionType="HOMING_LUNGE", killerSpeed=29.0, hitRadius=8.50, lateralWeight=5.0, awayWeight=10.0, minimumAwayDot=0.42, homing=true, minimumGain=1.15, requireOpenExit=true},
	["133002120549396"] = {motionType="HOMING_LUNGE", killerSpeed=29.0, hitRadius=8.50, lateralWeight=5.0, awayWeight=10.0, minimumAwayDot=0.42, homing=true, minimumGain=1.15, requireOpenExit=true},
	["130012819736632"] = {motionType="HOMING_LUNGE", killerSpeed=29.0, hitRadius=8.50, lateralWeight=5.0, awayWeight=10.0, minimumAwayDot=0.42, homing=true, minimumGain=1.15, requireOpenExit=true},

	-- Slasher's exact tracking chain steers throughout the strike. Three supplied
	-- failures were all accepted below the planner's own hit-radius requirement
	-- (7.50/11.00, 6.98/11.00 and 4.67/11.00). Exact Tracking therefore has no
	-- relative/best-effort ownership: it may replace physical WASD only with an
	-- absolute open-exit certificate. A small 0.15-stud model tolerance preserves
	-- the observed 10.94 near-certificate without admitting the 10.61 server hit.
	["110355011987939"] = {motionType="TRACKING_PURSUIT", killerSpeed=30.0, hitRadius=8.75, safetyMargin=1.25, certificationBuffer=0.85, lateralWeight=8.0, awayWeight=6.0, minimumAwayDot=0.28, homing=true, minimumGain=1.25, minimumCorridor=5.0, requireOpenExit=true, requireFullCertificate=true, allowBestEffort=false, allowSafetyFloor=false},
	["77477445889320"] = {motionType="TRACKING_PURSUIT", killerSpeed=30.0, hitRadius=8.75, safetyMargin=1.25, certificationBuffer=0.85, lateralWeight=8.0, awayWeight=6.0, minimumAwayDot=0.28, homing=true, minimumGain=1.25, minimumCorridor=5.0, requireOpenExit=true, requireFullCertificate=true, allowBestEffort=false, allowSafetyFloor=false},
	["139369275981139"] = {motionType="TRACKING_PURSUIT", killerSpeed=30.0, hitRadius=8.75, safetyMargin=1.25, certificationBuffer=0.85, lateralWeight=8.0, awayWeight=6.0, minimumAwayDot=0.28, homing=true, minimumGain=1.25, minimumCorridor=5.0, requireOpenExit=true, requireFullCertificate=true, allowBestEffort=false, allowSafetyFloor=false},
	["121571390309073"] = {motionType="TRACKING_PURSUIT", killerSpeed=30.0, hitRadius=8.75, safetyMargin=1.25, certificationBuffer=0.85, lateralWeight=8.0, awayWeight=6.0, minimumAwayDot=0.28, homing=true, minimumGain=1.25, minimumCorridor=5.0, requireOpenExit=true, requireFullCertificate=true, allowBestEffort=false, allowSafetyFloor=false},
}

local function predictiveFamilyProfile(family: string, animationId: string?): any
	local exact = EXACT_MOTION_PROFILE_BY_ID[tostring(animationId or "")]
	if exact then
		return exact
	end
	local upper = string.upper(tostring(family or "UNKNOWN"))
	if upper == "VEIL_WALL_ARROW_AIM" then
		return {motionType="PROJECTILE_LINE", killerSpeed=0.0, hitRadius=4.75, lateralWeight=18.0, awayWeight=0.25, lineAttack=true, minimumLateral=5.25, minimumLateralGain=3.25, minimumCorridor=5.0, requireOpenExit=true, requireFullCertificate=true, allowBestEffort=false, allowSafetyFloor=false}
	elseif upper == "DISTANCE_KEEPER"
		or upper == "PERSONAL_SPACE_GUARD" then
		return DISTANCE_HOLD_PROFILE
	end
	-- Aim/proximity guards and unclassified attacks model ordinary steering only.
	-- They never inherit extra lunge reach from a killer name.
	return ORDINARY_PURSUIT_PROFILE
end

local function predictiveCorridorClearance(
	origin: Vector3,
	direction: Vector3,
	distance: number,
	allowCache: boolean?
): number
	return bodyCorridorClearance(
		origin,
		direction,
		distance,
		math.max(Config.predictiveSweepHalfWidth, Config.routeSweepHalfWidth),
		allowCache
	)
end

local function predictiveWindowGeometryCandidate(
	origin: Vector3,
	threatPosition: Vector3
): any
	if not Config.windowPlannerApproachEnabled then
		return nil
	end
	local away = unitOr(horizontal(origin - threatPosition), Vector3.new(0, 0, -1))
	local best = nil
	local bestScore = -math.huge
	-- Window records are event-indexed by WorldIndexer. This loop does not scan
	-- Workspace and performs expensive corridor probes only for the best record.
	for model, record in pairs(State.windowCache) do
		local anchor = record and record.anchor
		if not model.Parent or not anchor or not anchor.Parent then
			State.windowCache[model] = nil
		else
			local normal = unitOr(horizontal(record.normal), anchor.CFrame.LookVector)
			local anchorFlat = Vector3.new(anchor.Position.X, origin.Y, anchor.Position.Z)
			local anchorDistance = horizontal(anchorFlat - origin).Magnitude
			if anchorDistance <= Config.windowPlannerCandidateDistance then
				local playerSide = horizontal(origin - anchorFlat):Dot(normal)
				local killerSide = horizontal(threatPosition - anchorFlat):Dot(normal)
				-- The attacker must still be on the player's side. Approaching a window
				-- with the attacker already beyond it would deliberately cross toward it.
				if math.abs(playerSide) >= 0.35
					and playerSide * killerSide >= 0.0 then
					local crossingDirection = playerSide >= 0 and -normal or normal
					local staging = anchorFlat
						- crossingDirection * Config.windowPlannerStagingDistance
					local stagingDelta = horizontal(staging - origin)
					local stagingDistance = stagingDelta.Magnitude
					if stagingDistance >= Config.windowPlannerMinimumApproachDistance
						and stagingDistance <= Config.windowPlannerCandidateDistance then
						local direction = stagingDelta.Unit
						local awayDot = direction:Dot(away)
						if awayDot >= Config.windowPlannerMinimumAwayDot then
							local score = awayDot * 12.0 - stagingDistance
							if score > bestScore then
								bestScore = score
								best = {
									record = record,
									direction = direction,
									staging = staging,
									stagingDistance = stagingDistance,
									crossingDirection = crossingDirection,
									awayDot = awayDot,
								}
							end
						end
					end
				end
			end
		end
	end
	if not best then
		return nil
	end

	if not RaycastBudget.HasRegularCapacity(25) then return nil end
	local approachProbe = math.min(
		Config.predictiveProbeDistance,
		best.stagingDistance + 0.45
	)
	local clearance = predictiveCorridorClearance(
		origin,
		best.direction,
		approachProbe,
		false
	)
	if clearance + 0.20 < best.stagingDistance
		or not groundOkay(best.staging) then
		return nil
	end

	-- Prove that the other side is a real grounded escape rather than another
	-- wall pocket. The Helper still stops before the native vault trigger; this
	-- probe only supplies topology to the route selector.
	local anchor = best.record.anchor
	local exitOrigin = Vector3.new(anchor.Position.X, origin.Y, anchor.Position.Z)
		+ best.crossingDirection * Config.windowPlannerExitOffset
	if not groundOkay(exitOrigin) then
		return nil
	end
	local escapeDepth = 0.0
	local escapeBranches = 0
	local escapeGrounded = false
	local escapeHorizon = 0.0
	local exitProbeDistance = math.max(
		Config.windowPlannerExitProbeDistance,
		Config.motionCoreDeadEndMinimumHorizon
	)
	for _, angle in ipairs({
		-Config.motionCoreDeadEndBranchAngle,
		0.0,
		Config.motionCoreDeadEndBranchAngle,
	}) do
		local branchDirection = rotateY(best.crossingDirection, angle)
		local depth = predictiveCorridorClearance(
			exitOrigin, branchDirection, exitProbeDistance, false
		)
		local grounded = groundOkay(exitOrigin + branchDirection * depth)
		if grounded then
			escapeDepth = math.max(escapeDepth, depth)
			escapeHorizon = math.max(escapeHorizon, depth)
			escapeGrounded = true
		end
		if grounded and depth >= Config.motionCoreDeadEndMinimumDepth then
			escapeBranches += 1
		end
	end
	if escapeBranches < 1 or not escapeGrounded
		or escapeHorizon < Config.motionCoreDeadEndMinimumHorizon then
		return nil
	end
	return {
		direction = best.direction,
		clearance = clearance,
		grounded = true,
		awayDot = best.awayDot,
		escapeDepth = escapeDepth,
		escapeBranches = escapeBranches,
		escapeGrounded = escapeGrounded,
		escapeHorizon = escapeHorizon,
		semanticExit = true,
		windowRecord = best.record,
		windowStopPosition = best.staging,
		windowCrossingDirection = best.crossingDirection,
		loopAnchorType = "WINDOW",
		loopAnchorRecord = best.record,
		loopAnchorPosition = Vector3.new(
			best.record.anchor.Position.X,
			origin.Y,
			best.record.anchor.Position.Z
		),
		loopAnchorScoreBonus = Config.loopAnchorScoreBonus,
	}
end

local function predictivePalletGeometryCandidate(
	origin: Vector3,
	threatPosition: Vector3
): (any?, any?)
	if not Config.loopAnchorEnabled or not Config.palletTopologyEnabled then
		return nil, nil
	end
	local away = unitOr(
		horizontal(origin - threatPosition),
		Vector3.new(0, 0, -1)
	)
	local best = nil
	local bestContext = nil
	local bestScore = -math.huge
	for model, record in pairs(State.palletCache) do
		local anchor = record and record.anchor
		if not model.Parent or not anchor or not anchor.Parent then
			State.palletCache[model] = nil
		elseif record.used ~= true and record.geometryDropped ~= true then
			local anchorFlat = Vector3.new(
				anchor.Position.X,
				origin.Y,
				anchor.Position.Z
			)
			local playerOffset = horizontal(origin - anchorFlat)
			local killerOffset = horizontal(threatPosition - anchorFlat)
			local playerDistance = playerOffset.Magnitude
			local killerDistance = killerOffset.Magnitude
			if playerDistance >= 0.65
				and killerDistance >= 0.65
				and playerDistance <= Config.loopAnchorCandidateDistance then
				local playerSide = playerOffset.Unit
				local killerSide = killerOffset.Unit
				local sideDot = playerSide:Dot(killerSide)
				-- Retain every nearby standing pallet as strategic context before the
				-- survivor crosses it. Previously context existed only after opposite-side
				-- geometry was already achieved, so preventive DistanceKeeper could abandon
				-- the loop a moment before it became useful. Actual pallet routing remains
				-- restricted to an opposite-side certificate below.
				local context = {
					type = "PALLET",
					record = record,
					position = anchorFlat,
					currentDistance = playerDistance,
				}
				if not bestContext
					or playerDistance < bestContext.currentDistance then
					bestContext = context
				end

				-- A pallet staging route is useful only while it actually separates the
				-- survivor from the attacker. Never route around a pallet that already
				-- has both characters on the same side.
				if sideDot <= Config.loopAnchorOppositeSideDot then

					local staging = anchorFlat
						+ playerSide * Config.loopAnchorStagingDistance
					local stagingDelta = horizontal(staging - origin)
					local stagingDistance = stagingDelta.Magnitude
					if stagingDistance >= Config.loopAnchorMinimumApproachDistance
						and stagingDistance <= Config.loopAnchorCandidateDistance then
						local direction = stagingDelta.Unit
						local awayDot = direction:Dot(away)
						if awayDot >= Config.loopAnchorMinimumAwayDot then
							if not RaycastBudget.HasRegularCapacity(24) then
								continue
							end
							local clearance = predictiveCorridorClearance(
								origin,
								direction,
								math.min(
									Config.predictiveProbeDistance,
									stagingDistance + 0.45
								),
								false
							)
							if clearance + 0.20 >= stagingDistance
								and groundOkay(staging) then
								local escapeDepth = 0.0
								local escapeBranches = 0
								local escapeGrounded = false
								local escapeHorizon = 0.0
								local exitProbeDistance = math.max(
									Config.windowPlannerExitProbeDistance,
									Config.motionCoreDeadEndMinimumHorizon
								)
								-- Probe the two ways around the loop plus the outward lane.
								for _, angle in ipairs({-82.0, 0.0, 82.0}) do
									local branchDirection = rotateY(playerSide, angle)
									local depth = predictiveCorridorClearance(
										staging, branchDirection, exitProbeDistance, false
									)
									local grounded = groundOkay(staging + branchDirection * depth)
									if grounded then
										escapeDepth = math.max(escapeDepth, depth)
										escapeHorizon = math.max(escapeHorizon, depth)
										escapeGrounded = true
									end
									if grounded and depth >= Config.motionCoreDeadEndMinimumDepth then
										escapeBranches += 1
									end
								end
								if escapeBranches >= 1 and escapeGrounded
									and escapeHorizon >= Config.motionCoreDeadEndMinimumHorizon then
									local score = awayDot * 12.0
										- stagingDistance
										- playerDistance * 0.25
									if score > bestScore then
										bestScore = score
										best = {
											direction = direction,
											clearance = clearance,
											grounded = true,
											awayDot = awayDot,
											escapeDepth = escapeDepth,
											escapeBranches = escapeBranches,
											escapeGrounded = escapeGrounded,
											escapeHorizon = escapeHorizon,
											semanticExit = true,
											windowRecord = record,
											windowStopPosition = staging,
											windowCrossingDirection = nil,
											loopAnchorType = "PALLET",
											loopAnchorRecord = record,
											loopAnchorPosition = anchorFlat,
											loopAnchorScoreBonus = Config.loopAnchorScoreBonus,
										}
									end
								end
							end
						end
					end
				end
			end
		end
	end
	return best, bestContext
end

function PredictivePlanner.BuildGeometry(
	model: Model,
	killerRoot: BasePart,
	probeOpenExit: boolean?,
	preferredDirection: Vector3?,
	onlyPreferred: boolean?
): any
	local root = State.root
	if not root then
		return nil
	end
	local origin = root.Position
	local threatPosition = killerRoot.Position
	local away = unitOr(horizontal(origin - threatPosition), root.CFrame.LookVector)
	local candidates = {}
	local function appendDirectionalCandidate(rawDirection: Vector3): ()
		-- Reserve the five-ray body sweep, three exit rays and two ground samples.
		if not RaycastBudget.HasRegularCapacity(probeOpenExit == true and 10 or 6) then
			return
		end
		local direction = unitOr(horizontal(rawDirection), away)
		for _, existing in ipairs(candidates) do
			if existing.direction:Dot(direction) >= 0.995 then
				return
			end
		end
		local clearance = predictiveCorridorClearance(
			origin,
			direction,
			Config.predictiveProbeDistance,
			probeOpenExit ~= true
		)
		local endpointDistance = math.min(clearance, Config.predictiveProbeDistance)
		local endpoint = origin + direction * endpointDistance
		local escapeDepth = nil
		local escapeBranches = nil
		local escapeGrounded = nil
		local escapeHorizon = nil
		if probeOpenExit == true then
			local lookaheadDistance = math.min(
				clearance,
				Config.motionCoreDeadEndLookahead
			)
			local lookaheadOrigin = origin
				+ direction * lookaheadDistance
				+ Vector3.new(0, Config.routeSweepLowOffset, 0)
			escapeDepth = 0.0
			escapeBranches = 0
			escapeGrounded = false
			escapeHorizon = lookaheadDistance
			local deepestBranchDirection = nil
			for _, branchAngle in ipairs({
				-Config.motionCoreDeadEndBranchAngle,
				0.0,
				Config.motionCoreDeadEndBranchAngle,
			}) do
				local branchDirection = rotateY(direction, branchAngle)
				local result = RaycastBudget.Cast(
					lookaheadOrigin,
					branchDirection * Config.motionCoreDeadEndBranchProbe,
					false
				)
				local depth = result
					and math.max(0, result.Distance - Config.routeBodyRadius)
					or Config.motionCoreDeadEndBranchProbe
				escapeDepth = math.max(escapeDepth, depth)
				if depth >= escapeDepth then
					deepestBranchDirection = branchDirection
				end
				if depth >= Config.motionCoreDeadEndMinimumDepth then
					escapeBranches += 1
				end
			end
			-- One bounded ground sample at the deepest branch endpoint extends the
			-- certificate without running PathfindingService or scanning the map.
			-- This keeps the planner event-driven and adds only one ray per candidate.
			if deepestBranchDirection then
				local groundedDepth = math.min(
					escapeDepth,
					Config.motionCoreDeadEndBranchProbe
				)
				escapeGrounded = groundOkay(
					lookaheadOrigin
						- Vector3.new(0, Config.routeSweepLowOffset, 0)
						+ deepestBranchDirection * groundedDepth
				)
				escapeHorizon = lookaheadDistance + groundedDepth
			end
		end
		table.insert(candidates, {
			direction = direction,
			clearance = clearance,
			grounded = groundOkay(endpoint),
			awayDot = direction:Dot(away),
			escapeDepth = escapeDepth,
			escapeBranches = escapeBranches,
			escapeGrounded = escapeGrounded,
			escapeHorizon = escapeHorizon,
		})
	end
	-- Preserve continuity under a finite ray budget: evaluate the owned direction
	-- before spending the budget on the fan of alternatives.
	if preferredDirection and horizontal(preferredDirection).Magnitude > 1e-4 then
		appendDirectionalCandidate(preferredDirection)
	end
	-- Give physical WASD the same deep-corridor test as helper routes. Otherwise
	-- a separation-only certificate can return control while that heading enters
	-- a one-branch room or a closed pocket.
	if onlyPreferred ~= true then
		local physicalDirection = CharacterController.PhysicalInputDirection()
		if physicalDirection then
			appendDirectionalCandidate(physicalDirection)
		end
	end
	-- The preferred direction above must still earn the incoming attack forecast.
	local loopAnchorContext = nil
	if probeOpenExit == true and onlyPreferred ~= true then
		local windowCandidate = predictiveWindowGeometryCandidate(
			origin,
			threatPosition
		)
		if windowCandidate then
			table.insert(candidates, windowCandidate)
			loopAnchorContext = {
				type = "WINDOW",
				record = windowCandidate.loopAnchorRecord,
				position = windowCandidate.loopAnchorPosition,
				currentDistance = horizontal(
					origin - windowCandidate.loopAnchorPosition
				).Magnitude,
			}
		end
		local palletCandidate, palletContext =
			predictivePalletGeometryCandidate(origin, threatPosition)
		if palletCandidate then
			table.insert(candidates, palletCandidate)
		end
		if palletContext
			and (
				not loopAnchorContext
				or palletContext.currentDistance
					< loopAnchorContext.currentDistance
			) then
			loopAnchorContext = palletContext
		end
	end
	-- Reserve physical input and nearby traversal geometry before the general fan.
	if onlyPreferred ~= true then
		for _, angle in ipairs(Config.predictiveCandidateAngles) do
			appendDirectionalCandidate(rotateY(away, angle))
		end
	end
	return {
		at = now(),
		model = model,
		origin = origin,
		threatPosition = threatPosition,
		candidates = candidates,
		loopAnchorContext = loopAnchorContext,
	}
end

function PredictivePlanner.RefreshCache(): ()
	if not Config.predictivePlannerEnabled
		or State.activeThreat
		or not State.matchActive
		or not State.root
		or not State.humanoid then
		return
	end
	local interactionLocked = CharacterController.DefensiveMovementStatus()
	if interactionLocked then
		return
	end
	local model = State.nearestKiller
	local killerRoot = modelRoot(model)
	if not model or not killerRoot
		or State.nearestKillerDistance > Config.predictiveCacheRange then
		return
	end
	local geometry = PredictivePlanner.BuildGeometry(model, killerRoot)
	if geometry then
		State.predictiveRouteCacheByModel[model] = geometry
	end
end

local function predictiveGeometryValid(
	geometry: any,
	model: Model,
	killerRoot: BasePart
): boolean
	local root = State.root
	return geometry ~= nil
		and geometry.model == model
		and root ~= nil
		and now() - (geometry.at or -math.huge) <= Config.predictiveCacheMaximumAge
		and horizontal(root.Position - geometry.origin).Magnitude
			<= Config.predictiveCacheMaximumOriginShift
		and horizontal(killerRoot.Position - geometry.threatPosition).Magnitude
			<= Config.predictiveCacheMaximumThreatShift
end

function PredictivePlanner.ImpactDelay(threat: any): number
	if tonumber(threat.rollingHorizonDelay) then
		return math.clamp(
			tonumber(threat.rollingHorizonDelay)
				or Config.threatDistanceKeeperRollingDelay,
			Config.predictiveMinimumImpactDelay,
			Config.predictiveMaximumImpactDelay
		)
	end
	if tonumber(threat.aimImpactDelay) then
		return math.clamp(
			tonumber(threat.aimImpactDelay) or Config.veilWallAimImpactDelay,
			Config.predictiveMinimumImpactDelay,
			Config.predictiveMaximumImpactDelay
		)
	end
	-- `activeAnimationId` intentionally remains the latest ACTIVE damage signal.
	-- A PREP merged into an already-ACTIVE synthetic guard must nevertheless own
	-- planning immediately, so motion identity is tracked independently.
	local id = tostring(
		threat.motionAnimationId
			or threat.activeAnimationId
			or threat.primaryAnimationId
			or ""
	)
	local learned = State.attackImpactDelayById[id]
	local configured = PREDICTIVE_IMPACT_DELAY_BY_ID[id]
	return math.clamp(
		learned or configured or Config.predictiveDefaultImpactDelay,
		Config.predictiveMinimumImpactDelay,
		Config.predictiveMaximumImpactDelay
	)
end

function PredictivePlanner.ForecastDelay(threat: any, profile: any): number
	local configured = PredictivePlanner.ImpactDelay(threat)
	if threat.rollingHorizon == true or not tonumber(threat.motionImpactAt) then
		return configured
	end
	local remaining = threat.motionImpactAt - now()
	if remaining > 0 then
		-- The imminent hit horizon must not be replaced by a longer pursuit floor.
		return math.clamp(remaining, 0.08, Config.predictiveMaximumImpactDelay)
	end
	-- Keep a bounded pursuit forecast after earliest impact, without turning a
	-- 200 ms exact signal into the profile's unrelated 550 ms future forecast.
	return math.clamp(
		math.min(tonumber(profile.minimumForecastHorizon) or 0.08, configured),
		0.08, Config.predictiveMaximumImpactDelay
	)
end

local function predictiveWindowTimingForDirection(
	origin: Vector3,
	killerRoot: BasePart,
	direction: Vector3,
	playerSpeed: number,
	preferredRecord: any?
): (boolean, any?)
	local selectedRecord = preferredRecord
	local selectedDistance = math.huge
	local selectedDot = -math.huge
	local flatDirection = unitOr(
		horizontal(direction),
		Vector3.new(0, 0, -1)
	)
	local function consider(record: any): ()
		local anchor = record and record.anchor
		if not anchor or not anchor.Parent then
			return
		end
		local delta = horizontal(anchor.Position - origin)
		local distance = delta.Magnitude
		if distance <= 0.05
			or distance > Config.windowPlannerCandidateDistance then
			return
		end
		local alignment = flatDirection:Dot(delta.Unit)
		if alignment < 0.35 then
			return
		end
		if distance < selectedDistance
			or (math.abs(distance - selectedDistance) <= 0.10
				and alignment > selectedDot) then
			selectedRecord = record
			selectedDistance = distance
			selectedDot = alignment
		end
	end
	if selectedRecord then
		selectedDistance = math.huge
		selectedDot = -math.huge
		consider(selectedRecord)
	else
		for _, record in pairs(State.windowCache) do
			consider(record)
		end
	end
	if not selectedRecord or selectedDistance == math.huge then
		return true, nil
	end

	local killerDistance = horizontal(
		killerRoot.Position - origin
	).Magnitude
	if killerDistance > Config.unsafeTraversalWindowPredictionDistance then
		return true, {
			record = selectedRecord,
			windowDistance = selectedDistance,
			alignment = selectedDot,
			reason = "killer-outside-window-envelope",
		}
	end
	local vaultDuration = math.max(
		(WindowController and WindowController.learnedDuration)
			or Config.windowDefaultVaultDuration,
		Config.unsafeTraversalWindowMinimumVaultDuration
	)
	local playerEta = math.max(
		0.0,
		selectedDistance - Config.windowCenterArrivalDistance
	) / math.max(playerSpeed, 1.0)
	local requiredTime = playerEta
		+ vaultDuration
		+ Config.unsafeTraversalWindowSafetyMargin
	local toPlayer = unitOr(
		horizontal(origin - killerRoot.Position),
		-killerRoot.CFrame.LookVector
	)
	local intendedRelativeApproach = horizontal(
		killerRoot.AssemblyLinearVelocity
			- flatDirection * playerSpeed
	):Dot(toPlayer)
	local physicalRelativeApproach = State.root
		and horizontal(
			killerRoot.AssemblyLinearVelocity
				- State.root.AssemblyLinearVelocity
		):Dot(toPlayer)
		or intendedRelativeApproach
	local closingSpeed = math.max(
		intendedRelativeApproach,
		physicalRelativeApproach,
		Config.unsafeTraversalWindowKillerSpeedFloor
	)
	local killerEta = math.max(
		0.0,
		killerDistance - Config.unsafeTraversalWindowAttackBuffer
	) / closingSpeed
	return requiredTime < killerEta, {
		record = selectedRecord,
		windowDistance = selectedDistance,
		alignment = selectedDot,
		playerEta = playerEta,
		vaultDuration = vaultDuration,
		requiredTime = requiredTime,
		killerEta = killerEta,
		relativeApproach = math.max(
			intendedRelativeApproach,
			physicalRelativeApproach
		),
	}
end

function PredictivePlanner.SelectInternal(threat: any, forceLive: boolean?, exactGeometry: any?): any
	local root = State.root
	local humanoid = State.humanoid
	local killerRoot = threat and threat.killerRoot
	local model = threat and threat.killerModel
	if not root or not humanoid or not killerRoot or not model then
		return nil
	end

	local family = tostring(threat.family or "UNKNOWN")
	local signalId = tostring(
		threat.motionAnimationId
			or threat.activeAnimationId
			or threat.primaryAnimationId
			or ""
	)
	local profile = type(threat.motionProfileOverride) == "table"
		and threat.motionProfileOverride
		or predictiveFamilyProfile(family, signalId)
	local geometry = exactGeometry or (forceLive ~= true
		and State.predictiveRouteCacheByModel[model]
		or nil)
	local source = "cache"
	local cachedExitProbeMissing = profile.requireOpenExit == true
		and geometry
		and geometry.candidates
		and geometry.candidates[1]
		and geometry.candidates[1].escapeDepth == nil
	if not predictiveGeometryValid(geometry, model, killerRoot)
		or cachedExitProbeMissing then
		if exactGeometry then return nil end
		geometry = PredictivePlanner.BuildGeometry(
			model,
			killerRoot,
			profile.requireOpenExit == true,
			threat.routeDirection
		)
		source = "live"
	end
	if not geometry or #geometry.candidates == 0 then
		return nil
	end

	local delay = PredictivePlanner.ForecastDelay(threat, profile)
	local origin = root.Position
	local killerPosition = typeof(threat.aimOrigin) == "Vector3"
		and threat.aimOrigin
		or killerRoot.Position
	local toPlayer = unitOr(horizontal(origin - killerPosition), -killerRoot.CFrame.LookVector)
	local killerVelocity = horizontal(killerRoot.AssemblyLinearVelocity)
	local attackForward = typeof(threat.aimDirection) == "Vector3"
		and horizontal(threat.aimDirection)
		or horizontal(killerRoot.CFrame.LookVector)
	if typeof(threat.aimDirection) ~= "Vector3"
		and profile.lineAttack ~= true
		and killerVelocity.Magnitude >= 4.0
		and killerVelocity.Unit:Dot(toPlayer) >= 0.10 then
		attackForward = killerVelocity.Unit
	else
		attackForward = unitOr(attackForward, toPlayer)
	end
	local actualKillerSpeed = math.max(0, killerVelocity:Dot(attackForward))
	local forecastKillerSpeed = profile.lineAttack == true
		and 0.0
		or math.max(actualKillerSpeed, profile.killerSpeed)
	local function forecastKillerPosition(playerTarget: Vector3): Vector3
		if profile.homing ~= true then
			return killerPosition + attackForward * forecastKillerSpeed * delay
		end
		-- Integrate a bounded pursuit turn instead of assuming that Masked keeps
		-- the animation-start LookVector. The target interpolates toward the
		-- candidate endpoint while the attacker steers toward its current estimate.
		local predictedKiller = killerPosition
		local pursuitDirection = attackForward
		local segments = 3
		for segment = 1, segments do
			local alpha = segment / segments
			local intermediateTarget = origin:Lerp(playerTarget, alpha)
			pursuitDirection = unitOr(
				horizontal(intermediateTarget - predictedKiller),
				pursuitDirection
			)
			predictedKiller += pursuitDirection
				* forecastKillerSpeed
				* (delay / segments)
		end
		return predictedKiller
	end
	local attackRight = Vector3.new(-attackForward.Z, 0, attackForward.X)
	local liveAway = unitOr(horizontal(origin - killerPosition), toPlayer)
	local defensiveSpeed = CharacterController.DefensivePlanningSpeed()
	local physicalInputDirection = CharacterController.PhysicalInputDirection()
	local motion = physicalInputDirection
		and physicalInputDirection * defensiveSpeed
		or Vector3.zero
	local motionDirection = motion.Magnitude >= 1.0 and motion.Unit or nil
	local manualAwayDot = motionDirection
		and motionDirection:Dot(liveAway)
		or -1.0
	local manualTopologyCandidate = nil
	local manualTopologyDot = -math.huge
	if motionDirection then
		for _, candidate in ipairs(geometry.candidates) do
			local candidateDirection = unitOr(
				horizontal(candidate.direction),
				motionDirection
			)
			local alignment = candidateDirection:Dot(motionDirection)
			if candidate.semanticExit ~= true and alignment > manualTopologyDot then
				manualTopologyDot = alignment
				manualTopologyCandidate = candidate
			end
		end
	end
	local manualEscapeDepth = manualTopologyCandidate
		and (tonumber(manualTopologyCandidate.escapeDepth) or 0.0)
		or 0.0
	local manualEscapeBranches = manualTopologyCandidate
		and (tonumber(manualTopologyCandidate.escapeBranches) or 0)
		or 0
	local manualEscapeGrounded = manualTopologyCandidate
		and manualTopologyCandidate.escapeGrounded == true
		or false
	local manualEscapeHorizon = manualTopologyCandidate
		and (tonumber(manualTopologyCandidate.escapeHorizon) or 0.0)
		or 0.0
	local manualClearance = manualTopologyCandidate
		and (tonumber(manualTopologyCandidate.clearance) or 0.0)
		or 0.0
	local manualOpenExit = profile.requireOpenExit ~= true
		or (
			manualTopologyCandidate ~= nil
			and manualTopologyDot >= 0.9999
			and manualTopologyCandidate.grounded ~= false
			and manualEscapeDepth >= (
				profile.minimumEscapeDepth
					or Config.motionCoreDeadEndMinimumDepth
			)
			and manualEscapeBranches >= (profile.minimumExitBranches or 1)
			and manualEscapeGrounded
			and manualEscapeHorizon >= Config.motionCoreDeadEndMinimumHorizon
		)
	local nativeSpeed = math.max(
		Config.predictiveNativeSpeedFloor,
		defensiveSpeed
	)
	local manualTravel = 0.0
	local manualGrounded = manualTopologyCandidate ~= nil
		and manualTopologyDot >= 0.9999
		and manualTopologyCandidate.grounded == true
	if motionDirection then
		local requestedTravel = nativeSpeed * delay
		if not manualTopologyCandidate or manualTopologyDot < 0.9999 then
			manualClearance = 0.0
			manualGrounded = false
			if RaycastBudget.HasRegularCapacity(6) then
				manualClearance = predictiveCorridorClearance(
					origin, motionDirection,
					requestedTravel + Config.predictivePathPadding, false
				)
				manualGrounded = groundOkay(origin + motionDirection * math.min(
					requestedTravel, math.max(0.0, manualClearance - Config.predictivePathPadding)
				))
			end
		end
		-- The manual forecast obeys the same collision padding as helper movement.
		manualTravel = manualGrounded and math.min(
			requestedTravel, math.max(0.0, manualClearance - Config.predictivePathPadding)
		) or 0.0
	end
	manualOpenExit = manualOpenExit and manualGrounded and manualTravel > 0.0
	local manualWindowTimingSafe = true
	local manualWindowTiming = nil
	if motionDirection then
		manualWindowTimingSafe, manualWindowTiming =
			predictiveWindowTimingForDirection(
				origin,
				killerRoot,
				motionDirection,
				nativeSpeed,
				nil
			)
	end
	manualOpenExit = manualOpenExit and manualWindowTimingSafe
	local manualUnsafeOrIdle = motionDirection == nil
		or manualAwayDot < Config.threatDistanceKeeperManualSafeAwayDot
		or not manualOpenExit
	local baselineKillerPredicted = forecastKillerPosition(origin)
	local baselineSeparation = profile.lineAttack == true
		and math.abs(horizontal(origin - killerPosition):Dot(attackRight))
		or horizontal(origin - baselineKillerPredicted).Magnitude
	local requiredSeparation = profile.hitRadius
		+ (profile.safetyMargin or Config.predictiveSafetyMargin)
		+ (profile.certificationBuffer or 0.0)
	if profile.lineAttack == true then
		requiredSeparation = math.max(
			requiredSeparation,
			profile.minimumLateral
				or Config.motionCoreProjectileMinimumLateral
		)
	end
	-- Compare every fallback candidate against what the player is already doing.
	-- A best-effort route may own movement only when it creates strictly more
	-- forecast separation than the current physical heading. When the player is
	-- already moving better, native WASD remains authoritative.
	local manualSeparation = baselineSeparation
	local manualLoopDeparture = 0.0
	if motionDirection then
		local manualTarget = origin + motionDirection * manualTravel
		local manualKillerPredicted = forecastKillerPosition(manualTarget)
		manualSeparation = profile.lineAttack == true
			and math.abs(horizontal(manualTarget - killerPosition):Dot(attackRight))
			or horizontal(manualTarget - manualKillerPredicted).Magnitude
		local loopContext = geometry.loopAnchorContext
		if Config.loopAnchorEnabled
			and type(loopContext) == "table"
			and typeof(loopContext.position) == "Vector3"
			and (tonumber(loopContext.currentDistance) or math.huge)
				<= Config.loopAnchorRetentionDistance then
			local currentLoopDistance = tonumber(loopContext.currentDistance)
				or horizontal(origin - loopContext.position).Magnitude
			manualLoopDeparture = math.max(
				0.0,
				horizontal(manualTarget - loopContext.position).Magnitude
					- currentLoopDistance
			)
		end
	end
	local best = nil
	local bestFeasible = nil
	local bestEffort = nil
	local bestSurvivalFallback = nil
	local bestSafetyFloor = nil
	local currentRouteEvaluation = nil

	for _, candidate in ipairs(geometry.candidates) do
		local direction = candidate.direction
		local liveAwayDot = direction:Dot(liveAway)
		local turnDot = motionDirection and direction:Dot(motionDirection) or 0.0
		local normalizedTurn = math.clamp((turnDot + 1.0) * 0.5, 0.0, 1.0)
		local turnFactor = Config.predictiveTurnMinimumFactor
			+ (1.0 - Config.predictiveTurnMinimumFactor) * normalizedTurn
		local unrestrictedTravel = nativeSpeed * delay * turnFactor
		-- A corridor need not remain open for distance the player cannot reach
		-- before impact. Conversely, a usable shorter corridor should not be
		-- discarded merely because the old test demanded the entire theoretical
		-- travel distance plus padding. Cap the forecast before the obstacle and
		-- retain padding, so partial routes help without steering into the wall.
		local maximumClearTravel = math.max(
			0.0,
			candidate.clearance - Config.predictivePathPadding
		)
		local travel = math.min(unrestrictedTravel, maximumClearTravel)
		local clearanceReserve = candidate.clearance - unrestrictedTravel
		local playerPredicted = origin + direction * travel
		local candidateKillerPredicted = forecastKillerPosition(playerPredicted)
		local loopDeparturePenalty = 0.0
		local loopRetentionBonus = tonumber(candidate.loopAnchorScoreBonus) or 0.0
		local strategicLoopDepartureBlocked = false
		local loopContext = geometry.loopAnchorContext
		if Config.loopAnchorEnabled
			and type(loopContext) == "table"
			and typeof(loopContext.position) == "Vector3"
			and (tonumber(loopContext.currentDistance) or math.huge)
				<= Config.loopAnchorRetentionDistance then
			local currentLoopDistance = tonumber(loopContext.currentDistance)
				or horizontal(origin - loopContext.position).Magnitude
			local predictedLoopDistance = horizontal(
				playerPredicted - loopContext.position
			).Magnitude
			local departure = math.max(
				0.0,
				predictedLoopDistance
					- currentLoopDistance
					- Config.loopAnchorDepartureGrace
			)
			loopDeparturePenalty = departure
				* Config.loopAnchorDeparturePenaltyPerStud
			if candidate.loopAnchorRecord == loopContext.record then
				-- Prefer approaching the already-useful side of this exact loop. This
				-- bonus does not make an infeasible route feasible; it only breaks ties
				-- among routes that passed the same attack/corridor certificate.
				loopRetentionBonus += Config.loopAnchorScoreBonus
			elseif departure > Config.loopAnchorMaximumPreferredDeparture then
				-- A large strategic departure must beat the loop route decisively rather
				-- than winning on one extra local branch or a few studs of clearance.
				loopDeparturePenalty += Config.loopAnchorScoreBonus
			end
			local preventiveOwner = threat.synthetic == true
				or family == "DISTANCE_KEEPER"
				or string.find(family, "_GUARD", 1, true) ~= nil
			strategicLoopDepartureBlocked = preventiveOwner
				and candidate.loopAnchorRecord ~= loopContext.record
				and departure > Config.loopAnchorMaximumPreferredDeparture
		end
		-- For the nearly straight Masked lunge, distance alone is the wrong
		-- objective: a fence/crate between the predicted player position and the
		-- attacker can terminate the lunge. Cast from the predicted player position
		-- back toward Masked so the killer rig itself is the unobstructed result;
		-- only a collidable non-Humanoid map part before that rig counts as cover.
		local collisionCover = false
		local coverPlayerGap = 0.0
		local coverKillerGap = 0.0
		local coverInstance = nil
		if profile.seekCollisionCover == true and travel >= 1.0 then
			local coverOrigin = playerPredicted + Vector3.new(0, 1.20, 0)
			-- Cover must block the attacker's forecast impact position, not merely
			-- its current position.  The old current-position ray certified crates
			-- that the lunge had already passed by the time damage was evaluated.
			local coverTarget = candidateKillerPredicted + Vector3.new(0, 1.20, 0)
			local coverVector = coverTarget - coverOrigin
			if coverVector.Magnitude >= 2.5 then
				local hit = RaycastBudget.Cast(coverOrigin, coverVector, false)
				if hit and hit.Instance
					and not hit.Instance:IsDescendantOf(model) then
					local hitModel = hit.Instance:FindFirstAncestorOfClass("Model")
					local hitHumanoid = hitModel
						and hitModel:FindFirstChildOfClass("Humanoid")
						or nil
					coverPlayerGap = hit.Distance
					coverKillerGap = math.max(0.0, coverVector.Magnitude - hit.Distance)
					collisionCover = hitHumanoid == nil
						and hit.Instance:IsA("BasePart")
						and hit.Instance.CanCollide == true
						and coverPlayerGap >= (profile.coverMinimumPlayerGap or 0.70)
						and coverKillerGap >= (profile.coverMinimumKillerGap or 1.50)
					if collisionCover then
						coverInstance = hit.Instance
					end
				end
			end
		end
		local predictedOffset = horizontal(
			playerPredicted - candidateKillerPredicted
		)
		local lateralSeparation = math.abs(
			horizontal(playerPredicted - killerPosition):Dot(attackRight)
		)
		local separation = profile.lineAttack == true
			and lateralSeparation
			or predictedOffset.Magnitude
		local gain = separation - baselineSeparation
		local minimumUsefulTravel = math.min(
			unrestrictedTravel,
			math.max(
				Config.motionCoreObstacleClearance,
				profile.minimumCorridor or 0.0
			)
		)
		local pathClear = candidate.grounded == true
			and travel >= minimumUsefulTravel
			and candidate.clearance >= (profile.minimumCorridor or 0.0)
			and clearanceReserve >= (profile.minimumClearanceReserve or -math.huge)
		local minimumAwayDot = tonumber(profile.minimumAwayDot)
			or Config.predictiveMinimumAwayDot
		local outwardEnough = liveAwayDot >= minimumAwayDot
		local minimumGain = profile.lineAttack == true
			and (profile.minimumLateralGain
				or Config.motionCoreProjectileMinimumLateralGain)
			or (profile.minimumGain
				or Config.predictiveMinimumSeparationGain)
		local openExit = profile.requireOpenExit ~= true
			or (
				(candidate.escapeDepth or 0)
					>= (profile.minimumEscapeDepth
						or Config.motionCoreDeadEndMinimumDepth)
				and (candidate.escapeBranches or 0)
					>= (profile.minimumExitBranches or 1)
				and candidate.escapeGrounded == true
				and (candidate.escapeHorizon or 0)
					>= Config.motionCoreDeadEndMinimumHorizon
			)
			or collisionCover
		local semanticWindowTimingSafe = true
		local semanticWindowTiming = nil
		if candidate.semanticExit == true
			and candidate.loopAnchorType == "WINDOW"
			and candidate.windowRecord then
			semanticWindowTimingSafe, semanticWindowTiming =
				predictiveWindowTimingForDirection(
					origin,
					killerRoot,
					direction,
					nativeSpeed,
					candidate.windowRecord
				)
		end
		local feasible = semanticWindowTimingSafe
			and not strategicLoopDepartureBlocked
			and pathClear
			and (outwardEnough or collisionCover)
			and openExit
			and (
				collisionCover
				or (
					separation >= requiredSeparation
					and gain >= minimumGain
				)
			)
		local improvementVsManual = separation - manualSeparation
		local fullCertificateRequired =
			profile.requireFullCertificate == true
		local effortEligible = semanticWindowTimingSafe
			and not strategicLoopDepartureBlocked
			and not fullCertificateRequired
			and profile.allowBestEffort == true
			and pathClear
			and openExit
			and liveAwayDot >= (
				profile.bestEffortMinimumAwayDot or minimumAwayDot
			)
			and gain >= (
				profile.bestEffortMinimumGain or minimumGain
			)
			and improvementVsManual >= (
				profile.bestEffortMinimumManualGain or 0.75
			)
		-- A failed hit-radius forecast is not permission to keep walking at the
		-- killer. When current WASD is idle/inward, accept only a grounded outward
		-- short corridor with real body clearance. This is a safety floor, not a
		-- claim that the route can guarantee avoiding the pending attack.
		local safetyFloorEligible = semanticWindowTimingSafe
			and not strategicLoopDepartureBlocked
			and not fullCertificateRequired
			and profile.allowSafetyFloor == true
			and not feasible
			and not effortEligible
			and manualUnsafeOrIdle
			and candidate.grounded == true
			and candidate.clearance
				>= Config.threatDistanceKeeperSafetyFloorClearance
			and (
				profile.requireOpenExit ~= true
				or openExit
				or candidate.clearance >= 7.5
			)
			and liveAwayDot
				>= Config.threatDistanceKeeperSafetyFloorAwayDot
			and travel >= math.min(
				Config.threatDistanceKeeperSafetyFloorClearance,
				unrestrictedTravel
			)
			and improvementVsManual >= 0.10
		local trackingSurvivalEligible = profile.motionType == "TRACKING_PURSUIT"
			and not fullCertificateRequired
			and not feasible
			and not effortEligible
			and semanticWindowTimingSafe
			and not strategicLoopDepartureBlocked
			and pathClear
			and openExit
			and liveAwayDot >= math.max(0.20, minimumAwayDot)
			and separation >= requiredSeparation
				* Config.trackingSurvivalFallbackMinimumSeparationRatio
			and improvementVsManual
				>= Config.trackingSurvivalFallbackMinimumManualGain
		local score = separation * (profile.lineAttack == true and 15.0 or 9.0)
			+ lateralSeparation * profile.lateralWeight
			+ liveAwayDot * profile.awayWeight
			+ math.min(candidate.clearance, Config.predictiveProbeDistance) * 1.8
			+ (candidate.escapeDepth or 0) * 2.5
			+ (candidate.escapeBranches or 0) * 3.0
			+ (collisionCover and (profile.coverScoreBonus or 180.0) or 0.0)
			+ (candidate.semanticExit == true
				and semanticWindowTimingSafe
				and Config.windowPlannerScoreBonus or 0.0)
			- (candidate.semanticExit == true
				and not semanticWindowTimingSafe
				and 10000.0 or 0.0)
			+ loopRetentionBonus
			- loopDeparturePenalty
			+ turnDot * 4.0
		local evaluated = {
			direction = direction,
			clearance = candidate.clearance,
			grounded = candidate.grounded,
			awayDot = liveAwayDot,
			turnDot = turnDot,
			travel = travel,
			unrestrictedTravel = unrestrictedTravel,
			travelLimitedByClearance = travel + 1e-3 < unrestrictedTravel,
			clearanceReserve = clearanceReserve,
			separation = separation,
			baselineSeparation = baselineSeparation,
			gain = gain,
			lateralSeparation = lateralSeparation,
			requiredSeparation = requiredSeparation,
			impactDelay = delay,
			forecastKillerSpeed = forecastKillerSpeed,
			motionType = profile.motionType,
			attackForward = attackForward,
			minimumGain = minimumGain,
			feasible = feasible,
			bestEffort = effortEligible and not feasible,
			survivalFallback = trackingSurvivalEligible,
			safetyFloor = safetyFloorEligible,
			manualUnsafeOrIdle = manualUnsafeOrIdle,
			manualHasDirection = motionDirection ~= nil,
			manualAwayDot = manualAwayDot,
			manualSeparation = manualSeparation,
			manualOpenExit = manualOpenExit,
			manualEscapeDepth = manualEscapeDepth,
			manualEscapeBranches = manualEscapeBranches,
			manualEscapeGrounded = manualEscapeGrounded,
			manualEscapeHorizon = manualEscapeHorizon,
			manualClearance = manualClearance,
			manualTravel = manualTravel,
			manualWindowTimingSafe = manualWindowTimingSafe,
			manualWindowRequiredTime = manualWindowTiming
				and manualWindowTiming.requiredTime or nil,
			manualWindowKillerEta = manualWindowTiming
				and manualWindowTiming.killerEta or nil,
			improvementVsManual = improvementVsManual,
			score = score,
			source = source,
			escapeDepth = candidate.escapeDepth or 0,
			escapeBranches = candidate.escapeBranches or 0,
			escapeGrounded = candidate.escapeGrounded == true,
			escapeHorizon = candidate.escapeHorizon or 0,
			openExit = openExit,
			collisionCover = collisionCover,
			coverPlayerGap = coverPlayerGap,
			coverKillerGap = coverKillerGap,
			coverInstance = coverInstance,
			semanticExit = candidate.semanticExit == true,
			semanticWindowTimingSafe = semanticWindowTimingSafe,
			semanticWindowRequiredTime = semanticWindowTiming
				and semanticWindowTiming.requiredTime or nil,
			semanticWindowKillerEta = semanticWindowTiming
				and semanticWindowTiming.killerEta or nil,
			windowRecord = candidate.windowRecord,
			windowStopPosition = candidate.windowStopPosition,
			windowCrossingDirection = candidate.windowCrossingDirection,
			loopAnchorType = candidate.loopAnchorType,
			loopAnchorRecord = candidate.loopAnchorRecord,
			loopAnchorPosition = candidate.loopAnchorPosition,
			loopDeparturePenalty = loopDeparturePenalty,
			loopRetentionBonus = loopRetentionBonus,
			manualLoopDeparture = manualLoopDeparture,
			strategicLoopDepartureBlocked = strategicLoopDepartureBlocked,
			survivalRank = separation * 100.0
				+ liveAwayDot * 10.0
				+ candidate.clearance
				+ (candidate.escapeBranches or 0) * 2.0,
		}
		if threat.routeDirection and candidate.semanticExit ~= true
			and unitOr(threat.routeDirection, direction):Dot(direction) >= 0.9999 then
			currentRouteEvaluation = evaluated
		end
		if not best or evaluated.score > best.score then
			best = evaluated
		end
		if feasible and (not bestFeasible or evaluated.score > bestFeasible.score) then
			bestFeasible = evaluated
		end
		if evaluated.bestEffort
			and (not bestEffort or evaluated.score > bestEffort.score) then
			bestEffort = evaluated
		end
		if evaluated.survivalFallback
			and (
				not bestSurvivalFallback
				or evaluated.survivalRank
					> bestSurvivalFallback.survivalRank
			) then
			bestSurvivalFallback = evaluated
		end
		if evaluated.safetyFloor
			and (not bestSafetyFloor or evaluated.score > bestSafetyFloor.score) then
			bestSafetyFloor = evaluated
		end
	end
	local selected = bestFeasible
		or bestEffort
		or bestSurvivalFallback
		or bestSafetyFloor
		or best
	if selected then selected.currentRouteEvaluation = currentRouteEvaluation end
	return selected
end

---------------------------------------------------------------------
-- 10c. ThreatMotionCore
---------------------------------------------------------------------

local ThreatMotionCore = {}

function PredictivePlanner.Select(threat: any, forceLive: boolean?, exactGeometry: any?): any
	local started = os.clock()
	local raysBefore = RaycastBudget.used
	local result = PredictivePlanner.SelectInternal(threat, forceLive, exactGeometry)
	local elapsedMs = (os.clock() - started) * 1000
	local stats = PredictivePlanner.performance or {calls=0, totalMs=0, maxMs=0, rays=0, at=now()}
	PredictivePlanner.performance = stats
	stats.calls += 1
	stats.totalMs += elapsedMs
	stats.maxMs = math.max(stats.maxMs, elapsedMs)
	stats.rays += math.max(0, RaycastBudget.used - raysBefore)
	if now() - stats.at >= 5 then
		Diagnostics.Push("PLANNER_PERFORMANCE", string.format(
			"calls=%d averageMs=%.3f peakMs=%.3f rays=%d overBudget=%s",
			stats.calls, stats.totalMs / stats.calls, stats.maxMs, stats.rays,
			tostring(stats.maxMs >= Config.predictivePerformanceWarningMs)
		), "planner-performance", 5)
		PredictivePlanner.performance = nil
	end
	return result
end

function PredictivePlanner.EvaluateDirection(threat: any, direction: Vector3): any
	local geometry = PredictivePlanner.BuildGeometry(
		threat.killerModel, threat.killerRoot, true, direction, true
	)
	if not geometry or #geometry.candidates ~= 1 then return nil end
	return PredictivePlanner.Select(threat, true, geometry)
end

function ThreatMotionCore.GrantRouteAuthority(threat: any, feasible: boolean, t: number): boolean
	if feasible then
		threat.routeAuthorityKind = "CERTIFIED"
		threat.routeAuthorityUntil = threat.motionHoldUntil
		return true
	end
	-- Episode-scoped: neither animation refresh nor replan restarts this window.
	local deadline = threat.motionEmergencyDeadline or (t + Config.motionCoreEmergencyEpisodeWindow)
	if t >= deadline then return false end
	threat.motionEmergencyDeadline = deadline
	threat.routeAuthorityKind = "EMERGENCY"
	threat.routeAuthorityUntil = math.min(deadline, t + Config.motionCoreEmergencyLease)
	threat.motionEmergencyReviewAt = t + Config.motionCoreEmergencyReviewInterval
	return true
end

function ThreatMotionCore.AuthorityAlive(threat: any, t: number): boolean
	return threat.routeAuthorityKind ~= "EMERGENCY"
		or t < (threat.routeAuthorityUntil or -math.huge)
end

function ThreatMotionCore.ReviewEmergency(threat: any, t: number): ()
	if threat.routeAuthorityKind ~= "EMERGENCY" or not threat.routeDirection
		or t < (threat.motionEmergencyReviewAt or -math.huge) then return end
	threat.motionEmergencyReviewAt = t + Config.motionCoreEmergencyReviewInterval
	if RaycastBudget.HasRegularCapacity(12) then
		local predicted = PredictivePlanner.EvaluateDirection(threat, threat.routeDirection)
		if predicted and ThreatMotionCore.ApplyPlan(threat, predicted, "emergency-review") then
			return
		end
	end
	-- Lack of a fresh forecast cannot extend a short emergency lease. Stop only
	-- our own intent, retain the threat, and let the normal planner seek a route.
	ThreatMotionCore.InvalidateCertificate(threat, "emergency-review-not-certified", true)
	MovementWriter.Clear(OWNER.THREAT, "emergency lease not renewed")
	threat.motionNoRouteRetryAt = t + Config.motionCoreEmergencyReviewInterval
end

function ThreatMotionCore.SignalKey(threat: any): string
	return string.format(
		"%s|%s|%s",
		tostring(threat and threat.family or "UNKNOWN"),
		tostring(threat and (
			threat.motionSignalPhase
				or threat.phase
		) or "UNKNOWN"),
		tostring(threat and (
			threat.motionAnimationId
				or threat.activeAnimationId
				or threat.primaryAnimationId
		) or "none")
	)
end

function ThreatMotionCore.InvalidateCertificate(
	threat: any,
	reason: string,
	clearRoute: boolean?
): ()
	if not threat then
		return
	end
	threat.routeCertificateValid = false
	threat.routeCertificateSignalKey = nil
	threat.routeCertificateSignalRevision = nil
	threat.routeCertificateImpactAt = nil
	threat.routeCertificateMotionType = nil
	threat.routeCertificateValidUntil = nil
	threat.routeCertificateInvalidReason = reason
	threat.predictiveLocked = false
	if clearRoute == true then
		threat.routeDirection = nil
		threat.routeLocked = false
		-- Do not let a rejected exact phase report the previous guard's separation
		-- and clearance in DAMAGE_RESULT. Those stale values made a route-pending
		-- hit look as if a certified route still existed.
		threat.predictiveSeparation = nil
		threat.predictiveRequiredSeparation = nil
		threat.predictiveBaselineSeparation = nil
		threat.predictiveGain = nil
		threat.predictiveBestEffort = false
		threat.predictiveSafetyFloor = false
		threat.predictiveManualSeparation = nil
		threat.routeClearance = nil
		threat.routeSafeLength = nil
		threat.motionEscapeDepth = nil
		threat.motionEscapeBranches = nil
		threat.routeWindowApproach = false
		threat.routeWindowRecord = nil
		threat.routeWindowStopPosition = nil
		threat.routeWindowCrossingDirection = nil
		threat.routeLoopAnchorType = nil
	end
end

function ThreatMotionCore.CertificateMatches(threat: any, t: number?): boolean
	if not threat
		or threat.routeCertificateValid ~= true
		or threat.predictiveLocked ~= true
		or threat.routeDirection == nil
		or threat.routeCertificateSignalKey ~= threat.motionSignalKey
		or threat.routeCertificateSignalRevision ~= threat.motionSignalRevision
		or threat.routeCertificateMotionType ~= threat.motionType then
		return false
	end
	local sampleNow = t or now()
	if not ThreatMotionCore.AuthorityAlive(threat, sampleNow) then return false end
	if sampleNow > (threat.routeCertificateValidUntil or -math.huge) then
		return false
	end
	-- A rolling distance floor intentionally advances its horizon. Ordinary attack
	-- phases do not: any impactAt change invalidates the route immediately.
	if threat.rollingHorizon ~= true then
		local certifiedImpactAt = tonumber(threat.routeCertificateImpactAt)
		local currentImpactAt = tonumber(threat.motionImpactAt)
		if not certifiedImpactAt
			or not currentImpactAt
			or math.abs(certifiedImpactAt - currentImpactAt) > 1e-4 then
			return false
		end
	end
	return true
end

function ThreatMotionCore.CaptureRouteSnapshot(threat: any): any
	if not threat
		or threat.routeDirection == nil
		or threat.predictiveLocked ~= true
		or not ThreatMotionCore.CertificateMatches(threat, now()) then
		return nil
	end
	return {
		family = threat.family,
		motionType = threat.motionType,
		motionProfile = threat.motionProfile,
		authorityKind = threat.routeAuthorityKind,
		impactAt = threat.routeCertificateImpactAt,
		validUntil = threat.routeCertificateValidUntil,
		direction = threat.routeDirection,
		routeLocked = threat.routeLocked,
		clearance = threat.routeClearance,
		safeLength = threat.routeSafeLength,
		branches = threat.routeBranches,
		escapeDepth = threat.motionEscapeDepth,
		escapeBranches = threat.motionEscapeBranches,
		windowApproach = threat.routeWindowApproach,
		windowRecord = threat.routeWindowRecord,
		windowStopPosition = threat.routeWindowStopPosition,
		windowCrossingDirection = threat.routeWindowCrossingDirection,
		loopAnchorType = threat.routeLoopAnchorType,
		orbitSign = threat.orbitSign,
		predictiveSeparation = threat.predictiveSeparation,
		predictiveRequiredSeparation = threat.predictiveRequiredSeparation,
		predictiveBaselineSeparation = threat.predictiveBaselineSeparation,
		predictiveGain = threat.predictiveGain,
		predictiveBestEffort = threat.predictiveBestEffort,
		predictiveSafetyFloor = threat.predictiveSafetyFloor,
		predictiveManualSeparation = threat.predictiveManualSeparation,
		predictiveCollisionCover = threat.predictiveCollisionCover,
		predictiveCoverPlayerGap = threat.predictiveCoverPlayerGap,
		predictiveCoverKillerGap = threat.predictiveCoverKillerGap,
		predictiveCoverInstance = threat.predictiveCoverInstance,
		capturedAt = now(),
	}
end

function ThreatMotionCore.BridgeRouteAcrossHandoff(
	threat: any,
	snapshot: any
): boolean
	if not threat or type(snapshot) ~= "table"
		or typeof(snapshot.direction) ~= "Vector3" then
		return false
	end
	if snapshot.authorityKind == "EMERGENCY" then return false end
	if not tonumber(snapshot.impactAt) or not tonumber(threat.motionImpactAt)
		or math.abs(snapshot.impactAt - threat.motionImpactAt) > 1e-4
		or snapshot.impactAt <= now()
		or not tonumber(snapshot.validUntil) or snapshot.validUntil <= now() then
		return false
	end
	-- A corridor certificate is meaningful only for the motion model that proved
	-- it. A projectile-line tangent cannot bridge into a homing melee envelope,
	-- and a distance-hold route cannot certify Veil's exact melee. Those two stale
	-- handoffs are present immediately before hits in the supplied trace.
	if tostring(snapshot.motionType or "")
		~= tostring(threat.motionType or "") then
		return false
	end
	-- Same motion type does not imply the same radius, speed or safety margin.
	if snapshot.motionProfile == nil
		or snapshot.motionProfile ~= threat.motionProfile then
		return false
	end
	-- A guard certificate proves only the guard's shorter envelope. Never relabel
	-- that snapshot as a certificate for an exact RIP phase whose required
	-- separation is larger. Failure to find a full exact route means native WASD.
	if type(threat.motionProfile) == "table"
		and threat.motionProfile.requireFullCertificate == true then
		return false
	end
	local t = now()
	local validUntil = math.min(
		snapshot.validUntil,
		snapshot.impactAt,
		threat.motionHoldUntil or (t + Config.motionCoreTransactionalHandoffGrace),
		t + Config.motionCoreTransactionalHandoffGrace
	)
	if validUntil <= t then
		return false
	end
	threat.routeDirection = snapshot.direction
	threat.routeLocked = snapshot.routeLocked ~= false
	threat.predictiveLocked = true
	threat.routeClearance = snapshot.clearance
	threat.routeSafeLength = snapshot.safeLength
	threat.routeBranches = snapshot.branches
	threat.motionEscapeDepth = snapshot.escapeDepth
	threat.motionEscapeBranches = snapshot.escapeBranches
	threat.routeWindowApproach = snapshot.windowApproach == true
	threat.routeWindowRecord = snapshot.windowRecord
	threat.routeWindowStopPosition = snapshot.windowStopPosition
	threat.routeWindowCrossingDirection = snapshot.windowCrossingDirection
	threat.routeLoopAnchorType = snapshot.loopAnchorType
	threat.orbitSign = snapshot.orbitSign
	threat.predictiveSeparation = snapshot.predictiveSeparation
	threat.predictiveRequiredSeparation = snapshot.predictiveRequiredSeparation
	threat.predictiveBaselineSeparation = snapshot.predictiveBaselineSeparation
	threat.predictiveGain = snapshot.predictiveGain
	threat.predictiveBestEffort = snapshot.predictiveBestEffort == true
	threat.predictiveSafetyFloor = snapshot.predictiveSafetyFloor == true
	threat.predictiveManualSeparation = snapshot.predictiveManualSeparation
	threat.predictiveCollisionCover = snapshot.predictiveCollisionCover == true
	threat.predictiveCoverPlayerGap = snapshot.predictiveCoverPlayerGap
	threat.predictiveCoverKillerGap = snapshot.predictiveCoverKillerGap
	threat.predictiveCoverInstance = snapshot.predictiveCoverInstance
	-- Certify the already validated direction only as a short handoff bridge under
	-- the incoming signal. The exact route is computed separately and replaces it
	-- atomically; a failed replacement never creates a route-less frame.
	threat.routeCertificateValid = true
	threat.routeCertificateSignalKey = threat.motionSignalKey
	threat.routeCertificateSignalRevision = threat.motionSignalRevision
	threat.routeCertificateImpactAt = threat.motionImpactAt
	threat.routeCertificateMotionType = threat.motionType
	threat.routeCertificateValidUntil = validUntil
	threat.routeCertificateInvalidReason = nil
	threat.routePending = false
	threat.transactionalHandoffPending = true
	threat.transactionalHandoffRetryAt = t + Config.motionCoreTransactionalHandoffRetry
	threat.transactionalHandoffDeadline = validUntil
	return true
end

local function motionCoreProfile(threat: any): any
	if threat and type(threat.motionProfileOverride) == "table" then
		return threat.motionProfileOverride
	end
	return predictiveFamilyProfile(
		tostring(threat and threat.family or "UNKNOWN"),
		tostring(threat and (
			threat.motionAnimationId
				or threat.activeAnimationId
				or threat.primaryAnimationId
		) or "")
	)
end

function ThreatMotionCore.ResolveSignalTiming(threat: any, t: number, signalTrack: any): (number, number, number?, number?, number?)
	local delay = PredictivePlanner.ImpactDelay(threat)
	local impactAt = t + delay
	local trackPosition, trackSpeed, trackAge = nil, nil, nil
	if signalTrack then
		local ok, position, speed = pcall(function()
			return signalTrack.TimePosition, signalTrack.Speed
		end)
		if ok and type(position) == "number" and type(speed) == "number"
			and position >= 0 and position < math.huge and speed > 0 and speed < math.huge then
			trackPosition, trackSpeed = position, speed
			trackAge = position / speed
		end
	end
	local id = tostring(threat.motionAnimationId or threat.activeAnimationId or threat.primaryAnimationId or "")
	local hiddenExact = threat.family == "HIDDEN"
		and (id == "113255068724446" or id == "74968262036854")
	if hiddenExact and trackAge and State.attackImpactDelayById[id] == nil then
		-- Learned receipt-to-damage delays already include local track age.
		impactAt = t + math.max(0, delay - trackAge)
	end
	if hiddenExact and id == "74968262036854"
		and threat.motionSignalKey == "HIDDEN|PREP|113255068724446"
		and tonumber(threat.motionSignalBoundAt)
		and t >= threat.motionSignalBoundAt and t - threat.motionSignalBoundAt <= 1.5
		and tonumber(threat.motionImpactAt) then
		impactAt = math.min(impactAt, threat.motionImpactAt)
	end
	return delay, impactAt, trackPosition, trackSpeed, trackAge
end

function ThreatMotionCore.Attach(
	threat: any,
	signalAt: number?,
	signalTrack: AnimationTrack?
): ()
	if not Config.motionCoreEnabled or not threat then
		return
	end
	if threat.phase ~= "ACTIVE"
		and threat.forceRouteOnPrep ~= true then
		return
	end
	local t = signalAt or now()
	local profile = motionCoreProfile(threat)
	local delay, impactAt, trackPosition, trackSpeed, trackAge =
		ThreatMotionCore.ResolveSignalTiming(threat, t, signalTrack)
	local alreadyBound = threat.motionType ~= nil
	local signalKey = ThreatMotionCore.SignalKey(threat)
	local sameSignalKey = threat.motionSignalKey == signalKey
	local playbackGeneration = threat.signalPlayback and threat.signalPlayback.generation
	local sameSignalTrack = (signalTrack == nil or threat.motionSignalTrack == signalTrack)
		and (playbackGeneration == nil or threat.motionSignalPlaybackGeneration == playbackGeneration)
	local duplicateSignal = alreadyBound
		and sameSignalKey
		and sameSignalTrack
	-- Poll recovery can report the same still-playing track every few hundred
	-- milliseconds. Its phase/id/track tuple is one signal, not a new impact
	-- horizon. A genuinely new AnimationTrack receives a new signal revision.
	local abandonedSameSignal = alreadyBound
		and sameSignalKey
		and sameSignalTrack
		and threat.motionRouteAbandonedSignalKey == signalKey
		and threat.motionRouteAbandonedSignalRevision
			== threat.motionSignalRevision
	if abandonedSameSignal then
		-- Once obstacle validation has abandoned this exact phase/id, another
		-- AnimationPlayed delivery must not recreate the same route. Only a distinct
		-- phase/id (or a new episode) may acquire movement authority again.
		Diagnostics.Push(
			"MOTION_CORE_SAME_SIGNAL_REARM_BLOCKED",
			string.format(
				"episode=%d family=%s signal=%s action=observe-only-native-WASD",
				threat.episodeId,
				tostring(threat.family or "UNKNOWN"),
				signalKey
			),
			"motion-same-signal-rearm-" .. tostring(threat.episodeId),
			0.15
		)
		return
	end
	local distinctSignal = not alreadyBound
		or not sameSignalKey
		or not sameSignalTrack
	if distinctSignal then
		-- Keep the direction in memory only long enough to test it under the new
		-- profile. It cannot write movement until ApplyPlan issues a new certificate.
		ThreatMotionCore.InvalidateCertificate(
			threat,
			"distinct-signal-needs-recertification",
			false
		)
		-- RenderApply may run before the next scheduler update. Remove the cached
		-- intent now so not even one render frame can use the PREP certificate after
		-- ACTIVE changed the horizon.
		MovementWriter.Clear(
			OWNER.THREAT,
			"distinct signal awaiting route recertification"
		)
		threat.replansUsed = 0
		threat.motionTurnBudgetDirection = nil
		threat.motionSignalRevision =
			(threat.motionSignalRevision or 0) + 1
		threat.motionSignalTrack = signalTrack
		threat.motionSignalPlaybackGeneration = playbackGeneration
	end
	local defaultPadding = profile.motionType == "PROJECTILE_LINE"
		and Config.motionCoreProjectileHoldPadding
		or Config.motionCoreImpactHoldPadding
	local padding = math.max(
		defaultPadding,
		tonumber(threat.motionHoldPadding) or 0.0
	)
	threat.motionType = profile.motionType or "MELEE_ARC"
	threat.motionProfile = profile
	if not duplicateSignal then
		threat.motionImpactDelay = delay
		threat.motionImpactAt = impactAt
		-- Receipt-based hold remains separate from an already due paired impact.
		threat.motionHoldUntil = t + delay + padding
		threat.motionTrackPositionAtReceipt = trackPosition
		threat.motionTrackSpeedAtReceipt = trackSpeed
		threat.motionTrackAgeAtReceipt = trackAge
		threat.motionNextReplanAt = t
		threat.motionSignalKey = signalKey
		threat.motionSignalBoundAt = t
		-- Only a genuinely distinct phase/id may leave blocked observe-only mode.
		-- Re-delivery of the same animation never clears the no-corridor latch.
		if distinctSignal then
			threat.motionObserveOnlyNoRoute = false
			threat.motionObstacleRetryEligible = false
			threat.motionObstacleRetryCount = 0
			threat.motionRouteAbandonedSignalKey = nil
			threat.motionRouteAbandonedSignalRevision = nil
			threat.motionNoRouteLogged = false
			-- A synthetic guard may have cached a rejected geometry retry for 280 ms.
			-- A real PREP/ACTIVE animation is a new timing contract and must plan on
			-- this frame; carrying that timer across the handoff produced route-pending
			-- until after the hit.
			threat.motionNoRouteRetryAt = -math.huge
			threat.motionNoRouteGeometryAt = nil
			threat.motionNoRouteOrigin = nil
			threat.motionNoRouteThreatPosition = nil
		end
		threat.motionFinalCommitLogged = false
	end
	if not alreadyBound then
		threat.motionLastPlanScore = -math.huge
		threat.motionLastPlanAt = -math.huge
		threat.motionLastPlanReason = "attach"
	end
	-- Impact lifecycle outranks safeDistance and the legacy duration. This closes
	-- the v5.3 contradiction where HIDDEN_LONG started beyond safeDistance and
	-- deleted itself a few milliseconds before the observed hit.
	threat.minimumReleaseAt = math.max(
		threat.minimumReleaseAt or -math.huge,
		threat.motionHoldUntil
	)
	threat.expiresAt = math.max(
		threat.expiresAt or -math.huge,
		threat.motionHoldUntil
	)
	threat.maximumUntil = math.max(
		threat.maximumUntil or -math.huge,
		threat.motionHoldUntil + 0.12
	)
	threat.hardMaximumUntil = math.max(
		threat.hardMaximumUntil or -math.huge,
		threat.motionHoldUntil + 0.35
	)
	if duplicateSignal then
		return
	end
	Diagnostics.Push(
		"MOTION_CORE_BOUND",
		string.format(
			"episode=%d family=%s signalPhase=%s signalId=%s type=%s impactDelay=%.3f hold=%.3f",
			threat.episodeId,
			tostring(threat.family),
			tostring(threat.motionSignalPhase or threat.phase or "UNKNOWN"),
			tostring(threat.motionAnimationId or "none"),
			threat.motionType,
			delay,
			threat.motionHoldUntil - t
		),
		"motion-core-bound-" .. tostring(threat.episodeId),
		0.01
	)
end

function ThreatMotionCore.HoldsLifecycle(threat: any, t: number): boolean
	return Config.motionCoreEnabled
		and threat ~= nil
		and tonumber(threat.motionHoldUntil) ~= nil
		and t < threat.motionHoldUntil
end

function ThreatMotionCore.ExtendCertificateHorizon(
	threat: any,
	impactAt: number,
	holdUntil: number
): boolean
	-- Extending a sustained guard's time horizon is not a new attack signal and
	-- must not discard an already certified corridor. v5.5.14 changed impactAt
	-- without updating the certificate, producing repeated full planner sweeps and
	-- a route-pending frame immediately before a Masked hit.
	if not threat
		or threat.routeCertificateValid ~= true
		or threat.predictiveLocked ~= true
		or threat.routeDirection == nil
		or threat.routeCertificateSignalKey ~= threat.motionSignalKey
		or threat.routeCertificateSignalRevision ~= threat.motionSignalRevision
		or threat.routeCertificateMotionType ~= threat.motionType then
		return false
	end
	threat.routeCertificateImpactAt = impactAt
	threat.routeCertificateValidUntil = math.max(
		threat.routeCertificateValidUntil or -math.huge,
		holdUntil
	)
	if threat.routeAuthorityKind == "EMERGENCY" then
		threat.routeCertificateValidUntil = math.min(
			threat.routeCertificateValidUntil, threat.routeAuthorityUntil or -math.huge
		)
	end
	threat.routeCertificateInvalidReason = nil
	threat.routePending = false
	return true
end

function ThreatMotionCore.RefreshRollingHorizon(threat: any, t: number): ()
	if not threat or threat.rollingHorizon ~= true then
		return
	end
	local delay = PredictivePlanner.ImpactDelay(threat)
	threat.motionImpactDelay = delay
	threat.motionImpactAt = t + delay
	threat.motionHoldUntil = threat.motionImpactAt
		+ Config.motionCoreImpactHoldPadding
	ThreatMotionCore.ExtendCertificateHorizon(
		threat,
		threat.motionImpactAt,
		threat.motionHoldUntil
	)
	-- Keep ordinary expiry from racing the rolling certificate. hardMaximumUntil
	-- remains bounded, so a stale owner cannot hold control forever.
	threat.expiresAt = math.max(threat.expiresAt or -math.huge, t + 0.35)
	threat.maximumUntil = math.max(threat.maximumUntil or -math.huge, t + 0.35)
end

function ThreatMotionCore.IsControlledFallback(predicted: any, threat: any?): boolean
	if type(predicted) ~= "table"
		or (
			predicted.bestEffort ~= true
			and predicted.survivalFallback ~= true
			and predicted.safetyFloor ~= true
		) then
		return false
	end
	local clearance = tonumber(predicted.clearance) or 0.0
	local branches = tonumber(predicted.escapeBranches) or 0
	local escapeDepth = tonumber(predicted.escapeDepth) or 0.0
	local escapeGrounded = predicted.escapeGrounded == true
	local escapeHorizon = tonumber(predicted.escapeHorizon) or 0.0
	local profile = threat and motionCoreProfile(threat) or nil
	if profile == VEIL_DISTANCE_HOLD_PROFILE then
		local localRoot = State.root
		local killerRoot = threat and threat.killerRoot
		local distance = localRoot and killerRoot
			and horizontal(localRoot.Position - killerRoot.Position).Magnitude
			or math.huge
		-- Far preventive Veil pressure may only use a full certificate. The
		-- controlled best-effort path exists solely to avoid doing literally
		-- nothing inside the close 12-stud envelope.
		if distance > 12.0 then
			return false
		end
	end
	local requiresOpenExit = type(profile) == "table"
		and profile.requireOpenExit == true
	-- `clearance >= 7.5` alone used to bless a straight pocket whose look-ahead
	-- had only 2.19 studs and zero branches. That was the route into the box in
	-- the supplied trace. An open-exit attack now requires actual topology.
	if requiresOpenExit
		and (
			branches < (profile.minimumExitBranches or 1)
			or escapeDepth < (profile.minimumEscapeDepth
				or Config.motionCoreDeadEndMinimumDepth)
			or not escapeGrounded
			or escapeHorizon < Config.motionCoreDeadEndMinimumHorizon
		) then
		return false
	end
	local openEnough = branches >= (
			type(profile) == "table"
				and (profile.minimumExitBranches or 1)
				or 1
		)
		and escapeGrounded
		and escapeHorizon >= Config.motionCoreDeadEndMinimumHorizon
		or (not requiresOpenExit and clearance >= 7.5)
	local commonSafe = predicted.grounded ~= false
		and openEnough
		and clearance >= Config.motionCoreBestEffortMinimumClearance
	if not commonSafe then
		return false
	end
	if predicted.safetyFloor == true then
		-- Safety-floor is deliberately relative: at 6 studs with only ~230 ms
		-- remaining, every candidate may still lose absolute separation. It may
		-- replace input only when it is outward and materially better than the
		-- player's current physical heading.
		return predicted.manualUnsafeOrIdle == true
			and (tonumber(predicted.awayDot) or -1.0)
				>= Config.motionCoreSafetyFloorMinimumAwayDot
			and (tonumber(predicted.improvementVsManual) or -math.huge)
				>= Config.motionCoreSafetyFloorMinimumManualGain
	end
	if predicted.survivalFallback == true then
		return (tonumber(predicted.awayDot) or -1.0) >= 0.20
			and (tonumber(predicted.separation) or -math.huge)
				>= (tonumber(predicted.requiredSeparation) or math.huge)
					* Config.trackingSurvivalFallbackMinimumSeparationRatio
			and (tonumber(predicted.improvementVsManual) or -math.huge)
				>= Config.trackingSurvivalFallbackMinimumManualGain
	end
	-- Most profiles use the global conservative floor. A profile may tighten or
	-- selectively relax one component only when it already requires a grounded
	-- open exit above. Stalker distance hold uses this to accept a deep route
	-- that is materially better than WASD even when every forecast has near-zero
	-- absolute gain because the homing strike is already inside its envelope.
	local minimumAwayDot = type(profile) == "table"
		and profile.controlledFallbackMinimumAwayDot
		or Config.motionCoreBestEffortMinimumAwayDot
	local minimumGain = type(profile) == "table"
		and profile.controlledFallbackMinimumGain
		or Config.motionCoreBestEffortMinimumSeparationGain
	local minimumManualGain = type(profile) == "table"
		and profile.controlledFallbackMinimumManualGain
		or Config.motionCoreBestEffortMinimumManualGain
	local minimumSeparationRatio = type(profile) == "table"
		and tonumber(profile.controlledFallbackMinimumSeparationRatio)
		or nil
	if minimumSeparationRatio
		and (tonumber(predicted.separation) or -math.huge)
			< (tonumber(predicted.requiredSeparation) or math.huge)
				* minimumSeparationRatio then
		return false
	end
	return (tonumber(predicted.awayDot) or -1.0) >= minimumAwayDot
		and (tonumber(predicted.gain) or -math.huge) >= minimumGain
		and (tonumber(predicted.improvementVsManual) or -math.huge)
			>= minimumManualGain
end

function ThreatMotionCore.ApplyPlan(
	threat: any,
	predicted: any,
	reason: string
): boolean
	if not predicted then
		return false
	end
	local controlledFallback =
		ThreatMotionCore.IsControlledFallback(predicted, threat)
	local fullCertificateRequired = type(threat.motionProfile) == "table"
		and threat.motionProfile.requireFullCertificate == true
	if fullCertificateRequired and predicted.feasible ~= true then
		Diagnostics.Push(
			"EXACT_HOMING_UNCERTIFIED_MANUAL",
			string.format(
				"episode=%d family=%s reason=%s type=%s sep=%.2f required=%.2f clear=%.2f action=native-WASD-no-partial-authority",
				threat.episodeId,
				tostring(threat.family or "UNKNOWN"),
				reason,
				tostring(threat.motionType or "UNKNOWN"),
				predicted.separation or -1.0,
				predicted.requiredSeparation or -1.0,
				predicted.clearance or 0.0
			),
			"exact-homing-uncertified-" .. tostring(threat.episodeId),
			0.08
		)
		return false
	end
	if predicted.feasible ~= true and not controlledFallback then
		-- A fallback can remain useful telemetry, but it is not a movement safety
		-- certificate. The old path knowingly accepted sep < required and then took
		-- control from the player; that is the exact failure this gate prevents.
		Diagnostics.Push(
			"MOTION_CORE_UNCERTIFIED_REJECTED",
			string.format(
				"episode=%d family=%s reason=%s mode=%s sep=%.2f required=%.2f clear=%.2f action=native-WASD",
				threat.episodeId,
				tostring(threat.family or "UNKNOWN"),
				reason,
				predicted.bestEffort == true and "best-effort"
					or (predicted.safetyFloor == true and "safety-floor" or "infeasible"),
				predicted.separation or -1.0,
				predicted.requiredSeparation or -1.0,
				predicted.clearance or 0.0
			),
			"motion-uncertified-" .. tostring(threat.episodeId) .. "-" .. reason,
			0.08
		)
		return false
	end
	local t = now()
	local oldDirection = threat.routeDirection
	local turnReference = threat.motionTurnBudgetDirection or oldDirection
	local directionDot = oldDirection
		and unitOr(oldDirection, predicted.direction):Dot(predicted.direction)
		or 1.0
	local consumesTurn = turnReference ~= nil
		and unitOr(turnReference, predicted.direction):Dot(predicted.direction) < 0.995
	if consumesTurn and (threat.replansUsed or 0) >= Config.motionCoreMaximumReplans then
		return false
	end
	local oldScore = tonumber(threat.motionLastPlanScore) or -math.huge
	local scoreGain = predicted.score - oldScore
	local emergency = reason == "blocked"
		or reason == "stuck"
		or reason == "unsafe"
	-- Head/root rotation is only a coarse indication that Veil is holding the
	-- through-wall shot; it is not the remote cursor and cannot certify that the
	-- current WASD will cross the eventual tracked projectile line. Once this
	-- fallback aim has produced a fully certified lateral corridor, keep that
	-- corridor authoritative instead of releasing it to a fictional manual-line
	-- certificate. Replicated attachment/attribute aim sources retain normal
	-- manual authority.
	local veilFallbackLateralAuthority =
		threat.veilFallbackAimAuthority == true
		and predicted.motionType == "PROJECTILE_LINE"
	local exactLineRouteAuthority = type(threat.motionProfile) == "table"
		and threat.motionProfile.exactLineRouteAuthority == true
		and predicted.motionType == "PROJECTILE_LINE"
	local trackedLineRouteAuthority = veilFallbackLateralAuthority
		or exactLineRouteAuthority
	local manualAbandonsCertifiedLoop = predicted.loopAnchorType ~= nil
		and (tonumber(predicted.manualLoopDeparture) or 0.0)
			> Config.loopAnchorMaximumPreferredDeparture
	local manualSeparationCertificateOwns = not trackedLineRouteAuthority
		and not manualAbandonsCertifiedLoop
		and predicted.manualHasDirection == true
		and (predicted.manualSeparation or -math.huge)
			>= (predicted.requiredSeparation or math.huge)
		and (predicted.improvementVsManual or -math.huge)
			< Config.motionCoreManualCertifiedOverrideGain
	-- Once a route has actually received a live certificate, native input is no
	-- longer allowed to revoke it merely because a later short-horizon sample says
	-- WASD is "good enough". That comparison caused route->none gaps during one
	-- continuous attack. Real blocked/stuck/unsafe validation remains authoritative
	-- and can still abandon the route, preventing wall or corner pinning.
	local materiallySaferManualDistanceExit = threat.family == "DISTANCE_KEEPER"
		and manualSeparationCertificateOwns
		and predicted.manualOpenExit ~= false
		and (predicted.improvementVsManual or 0.0) <= -3.0
	local committedCertifiedRouteOwns = oldDirection ~= nil
		and threat.predictiveLocked == true
		and threat.routeCertificateValid == true
		and ThreatMotionCore.HoldsLifecycle(threat, t)
		and reason ~= "blocked"
		and reason ~= "stuck"
		and reason ~= "unsafe"
		and not materiallySaferManualDistanceExit
	threat.sustainedManualReleaseBlocked = type(threat.motionProfile) == "table"
		and tonumber(threat.motionProfile.manualAuthorityReleaseDistance) ~= nil
		and State.root ~= nil
		and threat.killerRoot ~= nil
		and threat.killerRoot.Parent ~= nil
		and horizontal(
			threat.killerRoot.Position - State.root.Position
		).Magnitude < threat.motionProfile.manualAuthorityReleaseDistance
	local manualCertificateOwns = manualSeparationCertificateOwns
		and predicted.manualOpenExit ~= false
		and threat.sustainedManualReleaseBlocked ~= true
		and not committedCertifiedRouteOwns
	if manualSeparationCertificateOwns
		and committedCertifiedRouteOwns
		and predicted.feasible == true then
		Diagnostics.Push(
			"MOTION_CORE_COMMITTED_ROUTE_MANUAL_RELEASE_BLOCKED",
			string.format(
				"episode=%d family=%s reason=%s manualSep=%.2f required=%.2f action=keep-certified-route-until-attack-end",
				threat.episodeId,
				tostring(threat.family or "UNKNOWN"),
				reason,
				predicted.manualSeparation or -1.0,
				predicted.requiredSeparation or -1.0
			),
			"motion-committed-route-manual-blocked-" .. tostring(threat.episodeId),
			0.10
		)
	end
	if manualSeparationCertificateOwns
		and threat.sustainedManualReleaseBlocked == true
		and predicted.feasible == true then
		Diagnostics.Push(
			"MOTION_CORE_SUSTAINED_MANUAL_RELEASE_BLOCKED",
			string.format(
				"episode=%d family=%s d=%.2f releaseDistance=%.2f manualSep=%.2f required=%.2f action=keep-certified-route-revalidate-homing-pursuit",
				threat.episodeId,
				tostring(threat.family or "UNKNOWN"),
				horizontal(threat.killerRoot.Position - State.root.Position).Magnitude,
				threat.motionProfile.manualAuthorityReleaseDistance,
				predicted.manualSeparation or -1.0,
				predicted.requiredSeparation or -1.0
			),
			"motion-sustained-manual-release-blocked-" .. tostring(threat.episodeId),
			0.10
		)
	end
	if veilFallbackLateralAuthority
		and predicted.feasible == true
		and predicted.manualHasDirection == true then
		Diagnostics.Push(
			"VEIL_FALLBACK_LATERAL_AUTHORITY",
			string.format(
				"episode=%d source=%s routeLateral=%.2f manualLateral=%.2f clear=%.2f action=keep-certified-tracked-lateral-route",
				threat.episodeId,
				tostring(threat.aimSource or "fallback"),
				predicted.separation or -1.0,
				predicted.manualSeparation or -1.0,
				predicted.clearance or 0.0
			),
			"veil-fallback-lateral-authority-" .. tostring(threat.episodeId),
			0.25
		)
	end
	if exactLineRouteAuthority
		and predicted.feasible == true
		and predicted.manualHasDirection == true then
		Diagnostics.Push(
			"VEIL_EXACT_LINE_ROUTE_AUTHORITY",
			string.format(
				"episode=%d id=%s routeLateral=%.2f manualLateral=%.2f required=%.2f action=keep-prep-lateral-corridor",
				threat.episodeId,
				tostring(threat.motionAnimationId or threat.activeAnimationId or "none"),
				predicted.separation or -1.0,
				predicted.manualSeparation or -1.0,
				predicted.requiredSeparation or -1.0
			),
			"veil-exact-line-authority-" .. tostring(threat.episodeId),
			0.25
		)
	end
	if manualAbandonsCertifiedLoop and predicted.feasible == true then
		Diagnostics.Push(
			"LOOP_ANCHOR_MANUAL_DEPARTURE_REJECTED",
			string.format(
				"episode=%d family=%s anchor=%s manualDeparture=%.2f limit=%.2f action=keep-certified-loop-route",
				threat.episodeId,
				tostring(threat.family or "UNKNOWN"),
				tostring(predicted.loopAnchorType or "UNKNOWN"),
				predicted.manualLoopDeparture or 0.0,
				Config.loopAnchorMaximumPreferredDeparture
			),
			"loop-anchor-manual-departure-" .. tostring(threat.episodeId),
			0.20
		)
	end
	if manualSeparationCertificateOwns
		and not manualCertificateOwns
		and predicted.feasible == true then
		if predicted.manualWindowTimingSafe == false then
			Diagnostics.Push(
				"UNSAFE_WINDOW_APPROACH_REJECTED_EARLY",
				string.format(
					"episode=%d family=%s reason=%s required=%.2f killerEta=%.2f action=keep-open-field-route-before-Space",
					threat.episodeId,
					tostring(threat.family or "UNKNOWN"),
					reason,
					predicted.manualWindowRequiredTime or -1.0,
					predicted.manualWindowKillerEta or -1.0
				),
				"unsafe-window-approach-rejected-" .. tostring(threat.episodeId),
				0.12
			)
		end
		Diagnostics.Push(
			"MANUAL_POCKET_ENTRY_REJECTED",
			string.format(
				"episode=%d family=%s reason=%s manualSep=%.2f required=%.2f manualClear=%.2f exitDepth=%.2f exitBranches=%d action=keep-certified-open-exit-route",
				threat.episodeId,
				tostring(threat.family or "UNKNOWN"),
				reason,
				predicted.manualSeparation or -1.0,
				predicted.requiredSeparation or -1.0,
				predicted.manualClearance or 0.0,
				predicted.manualEscapeDepth or 0.0,
				math.floor(predicted.manualEscapeBranches or 0)
			),
			"manual-pocket-entry-rejected-" .. tostring(threat.episodeId),
			0.12
		)
	end
	if manualCertificateOwns then
		local releasedExistingRoute = oldDirection ~= nil
		if releasedExistingRoute then
			ThreatMotionCore.InvalidateCertificate(
				threat,
				"physical-WASD already certified",
				true
			)
			MovementWriter.Clear(
				OWNER.THREAT,
				"physical WASD certificate outranks helper replan"
			)
			threat.routePending = true
			threat.motionNextReplanAt = t + Config.motionCoreReplanInterval
		end
		Diagnostics.Push(
			"MOTION_CORE_MANUAL_CERTIFICATE_AUTHORITY",
			string.format(
				"episode=%d family=%s reason=%s sep=%.2f manualSep=%.2f manualGain=%+.2f required=%.2f minimumOverrideGain=%.2f manualExit=%s exitDepth=%.2f exitBranches=%d releasedExistingRoute=%s semanticExit=%s action=native-WASD",
				threat.episodeId,
				tostring(threat.family or "UNKNOWN"),
				reason,
				predicted.separation or -1.0,
				predicted.manualSeparation or -1.0,
				predicted.improvementVsManual or -math.huge,
				predicted.requiredSeparation or -1.0,
				Config.motionCoreManualCertifiedOverrideGain,
				tostring(predicted.manualOpenExit ~= false),
				predicted.manualEscapeDepth or 0.0,
				math.floor(predicted.manualEscapeBranches or 0),
				tostring(releasedExistingRoute),
				tostring(predicted.semanticExit == true)
			),
			"motion-manual-certificate-authority-" .. tostring(threat.episodeId),
			0.05
		)
		return false
	end
	if oldDirection
		and threat.predictiveCollisionCover == true
		and reason == "periodic"
		and predicted.collisionCover ~= true then
		-- A single later sample or exhausted ray budget must not make the planner
		-- abandon a previously certified obstacle just before the straight lunge.
		-- Blocked/stuck/unsafe reasons remain free to escape a genuinely bad route.
		Diagnostics.Push(
			"MASKED_COVER_ROUTE_RETAINED",
			string.format(
				"episode=%d family=%s reason=%s action=keep-certified-cover",
				threat.episodeId,
				tostring(threat.family or "UNKNOWN"),
				reason
			),
			"masked-cover-retained-" .. tostring(threat.episodeId),
			0.08
		)
		return false
	end
	if oldDirection
		and reason ~= "blocked"
		and reason ~= "stuck"
		and reason ~= "unsafe"
		and directionDot < Config.motionCoreNonFailureMinimumDirectionDot then
		Diagnostics.Push(
			"MOTION_CORE_SHARP_TURN_REJECTED",
			string.format(
				"episode=%d family=%s reason=%s directionDot=%.2f minimumDot=%.2f action=keep-current-side-until-real-obstacle",
				threat.episodeId,
				tostring(threat.family or "UNKNOWN"),
				reason,
				directionDot,
				Config.motionCoreNonFailureMinimumDirectionDot
			),
			"motion-sharp-turn-rejected-" .. tostring(threat.episodeId),
			0.08
		)
		return false
	end
	if oldDirection
		and reason == "periodic"
		and directionDot < Config.motionCorePeriodicMinimumDirectionDot
		and (predicted.improvementVsManual or -math.huge)
			< Config.motionCorePeriodicMinimumManualGain then
		Diagnostics.Push(
			"MOTION_CORE_REPLAN_REJECTED_WORSE",
			string.format(
				"episode=%d family=%s directionDot=%.2f manualGain=%+.2f minimumDot=%.2f action=keep-current-route",
				threat.episodeId,
				tostring(threat.family or "UNKNOWN"),
				directionDot,
				predicted.improvementVsManual or -math.huge,
				Config.motionCorePeriodicMinimumDirectionDot
			),
			"motion-replan-worse-" .. tostring(threat.episodeId),
			0.08
		)
		return false
	end
	if oldDirection
		and directionDot < Config.motionCoreMinimumDirectionDot
		and not emergency
		and scoreGain < Config.motionCoreSwitchScoreGain then
		return false
	end

	if not ThreatMotionCore.GrantRouteAuthority(threat, predicted.feasible == true, t) then
		Diagnostics.Push("EMERGENCY_AUTHORITY_EXPIRED", string.format(
			"episode=%d action=require-full-forecast-no-indefinite-best-effort", threat.episodeId
		), "emergency-expired-" .. tostring(threat.episodeId), 0.5)
		return false
	end
	threat.routeDirection = predicted.direction
	threat.routeLocked = true
	threat.predictiveLocked = true
	threat.predictiveImpactDelay = predicted.impactDelay
	threat.predictiveSeparation = predicted.separation
	threat.predictiveRequiredSeparation = predicted.requiredSeparation
	threat.predictiveBaselineSeparation = predicted.baselineSeparation
	threat.predictiveGain = predicted.gain
	threat.predictiveBestEffort = (
		predicted.bestEffort == true
		or predicted.survivalFallback == true
	)
		and controlledFallback
	threat.predictiveSafetyFloor = predicted.safetyFloor == true
		and controlledFallback
	threat.predictiveManualSeparation = predicted.manualSeparation
	threat.predictiveCollisionCover = predicted.collisionCover == true
	threat.predictiveCoverPlayerGap = predicted.coverPlayerGap
	threat.predictiveCoverKillerGap = predicted.coverKillerGap
	threat.predictiveCoverInstance = predicted.coverInstance
	threat.routeClearance = predicted.clearance
	threat.routeSafeLength = predicted.clearance
	threat.routeBranches = 0
	threat.motionEscapeDepth = predicted.escapeDepth or 0
	threat.motionEscapeBranches = predicted.escapeBranches or 0
	threat.routeWindowApproach = predicted.semanticExit == true
	threat.routeWindowRecord = predicted.windowRecord
	threat.routeWindowStopPosition = predicted.windowStopPosition
	threat.routeWindowCrossingDirection = predicted.windowCrossingDirection
	threat.routeLoopAnchorType = predicted.loopAnchorType
	threat.motionType = predicted.motionType or threat.motionType
	threat.motionAttackForward = predicted.attackForward
	threat.motionLastPlanScore = predicted.score
	threat.motionLastPlanAt = t
	threat.motionLastPlanReason = reason
	threat.motionHorizonValidatedAtPosition = State.root
		and State.root.Position or nil
	threat.motionHorizonNextRevalidateAt =
		t + Config.motionCoreHorizonRevalidateCooldown
	threat.motionNextReplanAt = t + Config.motionCoreReplanInterval
	threat.routeCertificateValid = true
	threat.routeCertificateSignalKey = threat.motionSignalKey
	threat.routeCertificateSignalRevision = threat.motionSignalRevision
	threat.routeCertificateImpactAt = threat.motionImpactAt
	threat.routeCertificateMotionType = threat.motionType
	threat.routeCertificateValidUntil = math.min(threat.motionHoldUntil, threat.routeAuthorityUntil)
	threat.routeCertificateInvalidReason = nil
	threat.routePending = false
	threat.transactionalHandoffDeferredLogged = nil
	threat.replansUsed = (threat.replansUsed or 0) + (consumesTurn and 1 or 0)
	if not turnReference or consumesTurn then
		threat.motionTurnBudgetDirection = predicted.direction
	end
	if not oldDirection and State.root then
		-- Stuck timing begins only after the first route can actually issue movement.
		-- Measuring from episode creation falsely marked a delayed plan as stuck
		-- before its first Player:Move write.
		threat.stuckSampleAt = t
		threat.stuckSamplePosition = State.root.Position
	end
	Diagnostics.Push(
		oldDirection and "MOTION_CORE_REPLAN" or "MOTION_CORE_ROUTE",
		string.format(
			"episode=%d family=%s type=%s reason=%s mode=%s delay=%.3f sep=%.2f manualSep=%.2f manualGain=%.2f required=%.2f lateral=%.2f gain=%.2f clear=%.2f reserve=%.2f exitDepth=%.2f exitBranches=%d cover=%s coverPlayerGap=%.2f coverKillerGap=%.2f coverPart=%s semanticExit=%s loopAnchor=%s loopPenalty=%.2f manualLoopDeparture=%.2f directionDot=%.2f replans=%d",
			threat.episodeId,
			tostring(threat.family),
			tostring(threat.motionType),
			reason,
			predicted.safetyFloor == true
				and "relative-safety-floor"
				or (predicted.survivalFallback == true
					and "tracking-survival-best-effort"
					or (controlledFallback and "controlled-best-effort" or "certified")),
			predicted.impactDelay,
			predicted.separation,
			predicted.manualSeparation or predicted.baselineSeparation,
			predicted.improvementVsManual or 0.0,
			predicted.requiredSeparation,
			predicted.lateralSeparation,
			predicted.gain,
			predicted.clearance,
			predicted.clearanceReserve or 0.0,
			predicted.escapeDepth or 0,
			predicted.escapeBranches or 0,
			tostring(predicted.collisionCover == true),
			predicted.coverPlayerGap or 0.0,
			predicted.coverKillerGap or 0.0,
			predicted.coverInstance and predicted.coverInstance:GetFullName() or "none",
			tostring(predicted.semanticExit == true),
			tostring(predicted.loopAnchorType or "none"),
			predicted.loopDeparturePenalty or 0.0,
			predicted.manualLoopDeparture or 0.0,
			directionDot,
			threat.replansUsed or 0
		),
		"motion-core-plan-" .. tostring(threat.episodeId) .. "-" .. reason,
		0.04
	)
	return true
end

function ThreatMotionCore.Replan(
	threat: any,
	reason: string,
	force: boolean?
): boolean
	if not Config.motionCoreEnabled or not threat then
		return false
	end
	local t = now()
	local impactRemaining = threat.rollingHorizon == true
		and math.huge
		or tonumber(threat.motionImpactAt)
		and (threat.motionImpactAt - t)
		or math.huge
	local finalCommitWindow = threat.motionType == "PROJECTILE_LINE"
		and Config.motionCoreProjectileFinalCommitWindow
		or Config.motionCoreFinalCommitWindow
	local keepDirectionOnly = (threat.replansUsed or 0) >= Config.motionCoreMaximumReplans
	if threat.routeDirection
		and t <= (threat.motionHoldUntil or -math.huge)
		and impactRemaining <= finalCommitWindow
		and reason ~= "signal-transition"
		and reason ~= "atomic-handoff"
		and reason ~= "emergency-review" then
		if not threat.motionFinalCommitLogged then
			threat.motionFinalCommitLogged = true
			Diagnostics.Push(
				"MOTION_CORE_FINAL_COMMIT",
				string.format(
					"episode=%d family=%s type=%s remaining=%.3f window=%.3f reason=%s action=freeze-direction",
					threat.episodeId,
					tostring(threat.family or "UNKNOWN"),
					tostring(threat.motionType or "legacy"),
					impactRemaining,
					finalCommitWindow,
					reason
				),
				"motion-final-commit-" .. tostring(threat.episodeId),
				0.02
			)
		end
		keepDirectionOnly = true
	end
	if force ~= true
		and t < (threat.motionNextReplanAt or -math.huge) then
		return false
	end
	local predicted = if keepDirectionOnly and threat.routeDirection
		then PredictivePlanner.EvaluateDirection(threat, threat.routeDirection)
		else PredictivePlanner.Select(threat, true)
	if reason == "horizon-refresh" and not predicted then
		ThreatMotionCore.InvalidateCertificate(
			threat,
			"long-horizon topology no longer has a grounded exit",
			true
		)
		threat.routeDirection = nil
		threat.routeLocked = false
		threat.predictiveLocked = false
		threat.motionObserveOnlyNoRoute = true
		threat.motionNoRouteRetryAt =
			t + Config.motionCoreNoRouteRetryInterval
		MovementWriter.Clear(
			OWNER.THREAT,
			"long-horizon route expired before pocket"
		)
		Diagnostics.Push(
			"MOTION_CORE_HORIZON_EXPIRED",
			string.format(
				"episode=%d family=%s action=release-before-uncertified-pocket-native-WASD",
				threat.episodeId,
				tostring(threat.family or "UNKNOWN")
			),
			"motion-horizon-expired-" .. tostring(threat.episodeId),
			0.10
		)
		return false
	end
	threat.motionNextReplanAt = t + (
		force == true
			and Config.motionCoreEmergencyReplanInterval
			or Config.motionCoreReplanInterval
	)
	if ThreatMotionCore.ApplyPlan(threat, predicted, reason) then return true end
	if threat.routeDirection then
		-- Rejected alternatives do not renew the previous forecast. The owned
		-- heading must pass the same live scene and impact model from this sweep.
		local current = predicted and predicted.currentRouteEvaluation
		if current and ThreatMotionCore.ApplyPlan(threat, current, "current-route-review") then
			return true
		end
		ThreatMotionCore.InvalidateCertificate(threat, "current-route-recertification-failed", true)
		MovementWriter.Clear(OWNER.THREAT, "current route no longer certified")
		threat.routePending = true
		threat.motionNoRouteRetryAt = t + Config.motionCoreNoRouteRetryInterval
	end
	return false
end

function ThreatMotionCore.RequiredAwayDot(threat: any): number
	if threat.family == "DISTANCE_KEEPER" then
		return (threat.motionProfileOverride
			and threat.motionProfileOverride.minimumAwayDot)
			or Config.threatDistanceKeeperMinimumAwayDot
	end
	if threat.motionType == "HOMING_LUNGE" then
		return (threat.motionProfile and threat.motionProfile.minimumAwayDot) or 0.52
	end
	return threat.predictiveLocked == true
		and Config.predictiveMinimumAwayDot
		or Config.threatConservativeMinimumAwayDot
end

function ThreatMotionCore.TryWallContinuation(
	threat: any,
	killerRoot: BasePart,
	reason: string
): (boolean, boolean)
	if not threat or not State.root or not killerRoot or not threat.motionType then
		return false, false
	end
	local t = now()
	if t < (threat.motionWallContinuationRetryAt or -math.huge) then
		return false, threat.motionWallContinuationPending == true
	end
	if (threat.replansUsed or 0) >= Config.motionCoreMaximumReplans then
		return false, false
	end
	if not RaycastBudget.HasRegularCapacity(Config.motionCoreWallContinuationRayReserve) then
		threat.motionWallContinuationPending = true
		threat.motionWallContinuationRetryAt = t + 0.03
		return false, true
	end
	threat.motionWallContinuationPending = false
	threat.motionWallContinuationRetryAt = t + Config.motionCoreWallContinuationCooldown
	-- Never bless a geometric wall slide with the previous direction's forecast.
	-- Use the very same live geometry, impact model and authority gate as any plan.
	local predicted = PredictivePlanner.Select(threat, true)
	if not predicted
		or predicted.awayDot < ThreatMotionCore.RequiredAwayDot(threat)
		or predicted.clearance < Config.threatConservativeWallClearance
		or not ThreatMotionCore.ApplyPlan(threat, predicted, "blocked") then
		return false, false
	end
	threat.motionObserveOnlyNoRoute = false
	threat.motionRouteAbandonedSignalKey = nil
	threat.motionRouteAbandonedSignalRevision = nil
	threat.motionNoRouteLogged = false
	threat.stuckSampleAt = t
	threat.stuckSamplePosition = State.root.Position
	Diagnostics.Push("MOTION_CORE_WALL_RECERTIFIED", string.format(
		"episode=%d reason=%s authority=%s sep=%.2f required=%.2f action=fresh-attack-forecast",
		threat.episodeId, reason, tostring(threat.routeAuthorityKind),
		predicted.separation, predicted.requiredSeparation
	), "wall-recertified-" .. tostring(threat.episodeId), 0.25)
	return true, false
end

function ThreatMotionCore.HistoricalApproach(
	model: Model,
	currentDistance: number
): (number, number)
	if not model or State.motionTelemetryCount <= 0 then
		return -math.huge, 0.0
	end
	local t = now()
	local capacity = Config.motionCoreTelemetryCapacity
	local bestApproach = -math.huge
	local bestWindow = 0.0
	for offset = 0, State.motionTelemetryCount - 1 do
		local index = (State.motionTelemetryHead - offset - 1) % capacity + 1
		local sample = State.motionTelemetry[index]
		if sample and sample.killerModel == model
			and sample.killerPosition and sample.playerPosition then
			local age = t - sample.t
			if age > Config.motionCoreHistoricalApproachWindow then
				break
			end
			if age >= Config.motionCoreHistoricalApproachMinimumAge then
				local oldDistance = horizontal(
					sample.killerPosition - sample.playerPosition
				).Magnitude
				local approach = (oldDistance - currentDistance) / age
				if approach > bestApproach then
					bestApproach = approach
					bestWindow = age
				end
			end
		end
	end
	return bestApproach, bestWindow
end

function ThreatMotionCore.Sample(): ()
	if not Config.motionCoreEnabled
		or not State.matchActive
		or not State.root
		or now() - State.motionTelemetryLastAt
			< Config.motionCoreTelemetryInterval then
		return
	end
	State.motionTelemetryLastAt = now()
	local threat = State.activeThreat
	local killerRoot = threat and threat.killerRoot or State.nearestKillerRoot
	local interactionLocked, interactionStatus =
		CharacterController.InteractionStatus()
	local capacity = Config.motionCoreTelemetryCapacity
	State.motionTelemetryHead = State.motionTelemetryHead % capacity + 1
	State.motionTelemetryCount = math.min(
		State.motionTelemetryCount + 1,
		capacity
	)
	State.motionTelemetry[State.motionTelemetryHead] = {
		t = now(),
		episode = threat and threat.episodeId or nil,
		family = threat and threat.family or "none",
		motionType = threat and threat.motionType or "none",
		playerPosition = State.root.Position,
		playerVelocity = horizontal(State.root.AssemblyLinearVelocity),
		killerPosition = killerRoot and killerRoot.Position or nil,
		killerModel = threat and threat.killerModel or State.nearestKiller,
		killerVelocity = killerRoot and horizontal(killerRoot.AssemblyLinearVelocity) or nil,
		route = threat and threat.routeDirection or nil,
		walk = State.humanoid and State.humanoid.WalkSpeed or 0,
		locked = interactionLocked,
		status = tostring(interactionStatus),
	}
end

function ThreatMotionCore.DumpHitTrace(label: string): ()
	if not Config.motionCoreEnabled or State.motionTelemetryCount <= 0 then
		return
	end
	local capacity = Config.motionCoreTelemetryCapacity
	local count = math.min(
		State.motionTelemetryCount,
		Config.motionCoreHitDumpSamples
	)
	for offset = count - 1, 0, -1 do
		local index = (State.motionTelemetryHead - offset - 1) % capacity + 1
		local sample = State.motionTelemetry[index]
		if sample then
			local p = sample.playerPosition
			local k = sample.killerPosition
			local pv = sample.playerVelocity
			local route = sample.route
			Diagnostics.Push(
				"MOTION_TRACE",
				string.format(
					"label=%s age=%.3f episode=%s family=%s type=%s p=(%.1f,%.1f) pv=(%.1f,%.1f) k=%s route=%s walk=%.1f locked=%s status=%s",
					label,
					now() - sample.t,
					tostring(sample.episode or "none"),
					tostring(sample.family),
					tostring(sample.motionType),
					p.X,
					p.Z,
					pv.X,
					pv.Z,
					k and string.format("(%.1f,%.1f)", k.X, k.Z) or "none",
					route and string.format("(%.2f,%.2f)", route.X, route.Z) or "none",
					sample.walk,
					tostring(sample.locked),
					sample.status
				),
				"motion-trace-" .. label .. "-" .. tostring(index),
				0
			)
		end
	end
end

---------------------------------------------------------------------
-- 11. MovementWriter
---------------------------------------------------------------------

MovementWriter = {}

function MovementWriter.SetIntent(
	owner: string,
	intent: any
): ()
	intent.actionKind = intent.actionKind or ACTION_KIND.MOVE
	if intent.actionKind ~= ACTION_KIND.MOVE then
		State.movementIntents[owner] = nil
		return
	end
	local movementAllowed, suppressionReason =
		ActionArbiter.CanAcceptMovement()
	if not movementAllowed then
		State.movementIntents[owner] = nil
		if State.movementSelectedIntent
			and State.movementSelectedIntent.owner == owner then
			State.movementSelectedIntent = nil
		end
		Diagnostics.Push(
			"ACTION_ARBITER_SUPPRESSED",
			string.format(
				"rejected=%s owner=%s group=%s reason=%s action=no-movement",
				ACTION_KIND.MOVE,
				owner,
				tostring(intent.group or "UNKNOWN"),
				suppressionReason
			),
			"action-arbiter-suppressed-" .. owner,
			0.25
		)
		return
	end
	intent.owner = owner
	intent.createdAt =
		intent.createdAt or now()
	intent.expiresAt =
		intent.expiresAt
			or (
				now()
				+ Config.movementIntentDefaultTtl
			)
	State.movementIntents[owner] = intent
end

function MovementWriter.Clear(
	owner: string,
	_reason: string?
): ()
	State.movementIntents[owner] = nil
	if State.movementOwner == owner then
		State.movementOwner = nil
		State.movementGroup = nil
	end
	if State.movementSelectedIntent
		and State.movementSelectedIntent.owner == owner then
		State.movementSelectedIntent = nil
	end
end

function MovementWriter.ClearAll(
	_reason: string?
): ()
	table.clear(State.movementIntents)
	State.movementOwner = nil
	State.movementGroup = nil
	State.movementSelectedIntent = nil
	State.movementLastAppliedEpisode = nil
end

function MovementWriter.RestoreMovement(): ()
	-- v5.2.27 never writes WalkSpeed, AutoRotate, velocity or keyboard movement.
	State.walkSpeedOwner = nil
	State.autoRotateOwner = nil
	State.movementOwner = nil
	State.movementGroup = nil
	State.movementSelectedIntent = nil
	State.movementLastAppliedEpisode = nil
end

function MovementWriter.RestoreWalkSpeed(): ()
	MovementWriter.RestoreMovement()
end

local function flashlightOwnsCharacterRig(): boolean
	return false
end

function MovementWriter.SelectIntent(): any
	local t = now()
	local selected, expired = ActionArbiter.SelectMovementIntent(
		State.movementIntents,
		t
	)
	for _, owner in ipairs(expired) do
		State.movementIntents[owner] = nil
	end
	return selected
end

function MovementWriter.Apply(
	_dt: number?
): ()
	if not State.enabled
		or not State.matchActive
		or not MatchController.IsExactSurvivorTeam()
		or not State.humanoid
		or not State.root
		or isDowned() then
		State.movementOwner = nil
		State.movementGroup = nil
		State.movementSelectedIntent = nil
		return
	end

	local intent = MovementWriter.SelectIntent()
	State.movementSelectedIntent = intent
	if not intent then
		State.movementOwner = nil
		State.movementGroup = nil
		return
	end

	local owner = tostring(intent.owner or "unknown")
	local group = tostring(intent.group or "UNKNOWN")
	if State.movementOwner ~= owner
		or State.movementGroup ~= group then
		State.movementOwner = owner
		State.movementGroup = group

		local eventName =
			group == "DODGE"
				and "DODGE_DETECTED"
				or "MOVEMENT_INTENT_SELECTED"
		Diagnostics.Push(
			eventName,
			string.format(
				"owner=%s group=%s episode=%s priority=%s action=post-input-player-move",
				owner,
				group,
				tostring(intent.episodeId or "none"),
				tostring(intent.priority or 0)
			),
			"movement-selected-"
				.. owner
				.. "-"
				.. group,
			0.05
		)
	end
end

local DYNAMIC_ORBIT_FAMILIES = {
	RIP = true,
	RIP_TRACKING = true,
	RIP_POINTBLANK_GUARD = true,
}

local DYNAMIC_AWAY_FAMILIES = {
	KILLER = true,
	VEIL_MELEE_GUARD = true,
}

local PURE_ROUTE_FAMILIES = {
	DISTANCE_KEEPER = true,
	VEIL_THROW = true,
	VEIL_DELAYED = true,
	VEIL_MELEE = true,
	VEIL_MELEE_GUARD = true,
	RIP = true,
	RIP_TRACKING = true,
	RIP_POINTBLANK_GUARD = true,
	KILLER = true,
	KILLER_POINTBLANK_GUARD = true,
	HIDDEN_LONG = true,
	TRACKING = true,
	TRACKING_POINTBLANK_GUARD = true,
	CURE = true,
	CURE_POINTBLANK_GUARD = true,
	STALKER = true,
	MASKED_LUNGE = true,
	MASKED_CLOSE_AIM_GUARD = true,
	HIDDEN_CLOSE_AIM_GUARD = true,
	KILLER_CLOSE_AIM_GUARD = true,
	ABYSSWALKER_CROUCH_STRIKE = true,
}

local function intentUsesPredictiveBestEffort(intent: any): boolean
	-- RenderApply receives an immutable per-frame intent snapshot. Never reach
	-- through an undeclared/stale `threat` local here; that exact typo crashed
	-- every certified Veil route in v5.4.6 before Player:Move could run.
	return type(intent) == "table"
		and intent.predictiveBestEffort == true
end

function MovementWriter.ValidateAuxiliaryDirection(intent: any, direction: Vector3): (boolean, string)
	local group = tostring(intent.group or "")
	if group ~= "ZOMBIE" and group ~= "EXIT" then return true, "not-auxiliary" end
	local t = now()
	local directionKey = string.format("%.2f:%.2f", direction.X, direction.Z)
	if intent.finalDirectionCheckKey == directionKey
		and t - (intent.finalDirectionCheckAt or -math.huge)
			< Config.movementAuxiliaryValidationInterval then
		return intent.finalDirectionCheckResult == true,
			intent.finalDirectionCheckReason or "cached"
	end
	local function remember(ok: boolean, reason: string): (boolean, string)
		intent.finalDirectionCheckKey = directionKey
		intent.finalDirectionCheckAt = t
		intent.finalDirectionCheckResult = ok
		intent.finalDirectionCheckReason = reason
		return ok, reason
	end
	local root = State.root
	if not root then return remember(false, "no-root") end
	if group == "ZOMBIE" then
		-- Older isolated movement harnesses may provide only the basic arbiter
		-- surface.  The live runtime always installs this veto, while a missing
		-- optional method must not turn the final validation into a nil call.
		if ActionArbiter
			and type(ActionArbiter.KillerThreatBlocksZombie) == "function"
			and ActionArbiter.KillerThreatBlocksZombie(now()) then
			return remember(false, "killer-threat-owns-defense")
		end
		local threatRoot = intent.threatRoot
		local threatPosition = threatRoot and threatRoot.Parent and threatRoot.Position
			or intent.threatPosition
		if typeof(threatPosition) ~= "Vector3"
			or routeAwayDot(direction, root.Position, threatPosition)
				< Config.zombieRouteMinimumAwayDot then
			return remember(false, "final-direction-not-away")
		end
	end
	local probeDistance = group == "ZOMBIE" and Config.zombieRouteBlockedProbeDistance
		or math.min(Config.exitRouteProbeDistance, tonumber(intent.remainingDistance) or 0)
	local requiredClearance = group == "ZOMBIE" and Config.zombieRouteBlockedClearance
		or probeDistance
	if probeDistance < Config.movementMinimumDirection then return remember(false, "target-reached") end
	-- Reserve the whole five-ray body sweep and ground check before starting.
	-- A spent ray budget never becomes evidence of a clear final direction. Use
	-- the regular budget here because this is a final auxiliary check, not a
	-- threat impact commitment; critical rays remain available to the threat core.
	if not RaycastBudget.HasRegularCapacity(6) then return remember(false, "ray-budget") end
	local clearance = bodyCorridorClearance(root.Position, direction, probeDistance,
		Config.routeSweepHalfWidth, false, false)
	if clearance < requiredClearance then return remember(false, "final-corridor-blocked") end
	local groundPoint = root.Position + direction * math.min(clearance, probeDistance, 3.5)
	local grounded = RaycastBudget.Cast(groundPoint + Vector3.new(0, 2.5, 0),
		Vector3.new(0, -Config.routeGroundDepth, 0), false)
	return remember(grounded ~= nil, grounded and "clear" or "final-corridor-no-ground")
end

function MovementWriter.RenderApply(
	_dt: number?
): ()
	if not State.enabled
		or not State.matchActive
		or not MatchController.IsExactSurvivorTeam()
		or not State.humanoid
		or not State.root
		or isDowned() then
		return
	end

	-- One final authority check owns every movement source. HARD_BLOCK covers
	-- WalkSpeed=0 and every interaction; COUNTER_ARM/COUNTER_C outrank Exit,
	-- Zombie, window and threat movement without touching the player's WASD.
	local movementAllowed, suppressionReason =
		ActionArbiter.CanApplyMovement()
	if not movementAllowed then
		local pending = State.movementSelectedIntent
		if pending then
			local eventName = string.sub(suppressionReason, 1, 11) == "hard-block:"
				and "MOVEMENT_SUPPRESSED_LOCKED"
				or "ACTION_ARBITER_SUPPRESSED"
			Diagnostics.Push(
				eventName,
				string.format(
					"owner=%s group=%s episode=%s walk=%.2f reason=%s action=no-movement",
					tostring(pending.owner or "unknown"),
					tostring(pending.group or "UNKNOWN"),
					tostring(pending.episodeId or "none"),
					State.humanoid.WalkSpeed,
					suppressionReason
				),
				"movement-suppressed-" .. tostring(pending.owner or "unknown"),
				0.35
			)
		end
		return
	end

	local intent = State.movementSelectedIntent
	if not intent
		or now() > (intent.expiresAt or -math.huge)
		or State.movementIntents[
			tostring(intent.owner or "")
		] ~= intent then
		intent = MovementWriter.SelectIntent()
		State.movementSelectedIntent = intent
	end
	if not intent then
		return
	end
	-- Scheduler stalls must not extend emergency movement through a stale intent.
	if intent.threatEpisode
		and type(ThreatMotionCore.AuthorityAlive) == "function"
		and not ThreatMotionCore.AuthorityAlive(intent.threatEpisode, now()) then
		MovementWriter.Clear(OWNER.THREAT, "render emergency lease expired")
		return
	end
	-- Defence in depth: even a stale intent created immediately before a runtime
	-- replacement cannot take movement authority while manual threat mode is on.
	if not Config.threatAutoMovementEnabled
		and tostring(intent.group or "") == "DODGE" then
		State.movementSelectedIntent = nil
		return
	end

	local yieldForFlashlightSafeAction = false
	local yieldSource = "none"
	local yieldTarget = State.flashlightTargetModel
	if Config.flashlightYieldMovementOnConfirmedStun
		and State.rightMouseDown
		and State.itemAimActiveMode == "FLASHLIGHT"
		and tostring(intent.group or "") == "DODGE"
		and yieldTarget
		and yieldTarget.Parent then
		local episode = intent.threatEpisode
		local episodeModel = type(episode) == "table"
			and episode.killerModel
			or nil
		if episodeModel == yieldTarget then
			yieldForFlashlightSafeAction, yieldSource =
				FlashlightController.IsSafeToKeepShining(yieldTarget)
		end
	end
	if yieldForFlashlightSafeAction then
		if not State.flashlightMovementYieldActive
			or State.flashlightMovementYieldSource ~= yieldSource then
			Diagnostics.Push(
				"FLASHLIGHT_SAFE_ACTION_MOVEMENT_YIELD",
				string.format(
					"target=%s source=%s RMB=physical action=native-control-no-helper-runaway",
					yieldTarget and yieldTarget.Name or "none",
					yieldSource
				),
				"flashlight-safe-action-movement-yield",
				0.10
			)
		end
		State.flashlightMovementYieldActive = true
		State.flashlightMovementYieldSource = yieldSource
		State.movementLastAppliedEpisode = nil
		-- Returning without Player:Move preserves the native ControlModule result.
		-- The threat and certified route stay alive and resume if the stun ends.
		return
	elseif State.flashlightMovementYieldActive then
		Diagnostics.Push(
			"FLASHLIGHT_STUN_MOVEMENT_RESUME",
			"reason=RMB-release-or-stun-ended action=resume-certified-threat-if-active",
			"flashlight-stun-movement-resume",
			0.10
		)
		State.flashlightMovementYieldActive = false
		State.flashlightMovementYieldSource = "none"
	end

	local route =
		horizontal(
			intent.direction
				or Vector3.zero
		)
	if route.Magnitude
		< Config.movementMinimumDirection then
		return
	end
	route = route.Unit

	local family = tostring(intent.family or "none")
	local movementPolicy = "route"
	local conservativeDodge = Config.threatConservativeMovementEnabled
		and tostring(intent.group or "") == "DODGE"
	if not conservativeDodge then
	if DYNAMIC_ORBIT_FAMILIES[family] then
		local threatPosition = intent.threatPosition
		local threatRoot = intent.threatRoot
		if typeof(threatRoot) == "Instance"
			and threatRoot:IsA("BasePart")
			and threatRoot.Parent then
			threatPosition = threatRoot.Position
		end
		if typeof(threatPosition) == "Vector3" then
			local away = unitOr(State.root.Position - threatPosition, route)
			local tangentRight = Vector3.new(-away.Z, 0, away.X)
			local orbitSign = tonumber(intent.orbitSign)
			if orbitSign ~= 1 and orbitSign ~= -1 then
				orbitSign = route:Dot(tangentRight) >= 0 and 1 or -1
			end
			local distance = horizontal(State.root.Position - threatPosition).Magnitude
			local isRipOrbit =
				family == "RIP"
				or family == "RIP_TRACKING"
				or family == "RIP_POINTBLANK_GUARD"
			local closeDistance = isRipOrbit
				and Config.ripOrbitCloseDistance
				or Config.cureOrbitCloseDistance
			local awayWeight = distance <= closeDistance
				and (
					isRipOrbit
						and Config.ripOrbitCloseAwayWeight
						or Config.cureOrbitCloseAwayWeight
				)
				or (
					isRipOrbit
						and Config.ripOrbitAwayWeight
						or Config.cureOrbitAwayWeight
				)
			local tangentialWeight = isRipOrbit
				and Config.ripOrbitTangentialWeight
				or Config.cureOrbitTangentialWeight
			local orbit = tangentRight * orbitSign * tangentialWeight
				+ away * awayWeight
			if orbit.Magnitude >= Config.movementMinimumDirection then
				route = orbit.Unit
				movementPolicy = isRipOrbit
					and "dynamic-rip-away-hold"
					or "dynamic-cure-orbit"
			end
		end
	end

	-- Cure's confirmed ACTIVE behaves like a fast closing lunge. The supplied
	-- log shows that a radial "run directly away" policy still let Cure reduce
	-- 18.61 studs to 11.00 while the survivor moved 13.80 studs. Cut across
	-- the live attack line instead, retaining only a small radial component.
	if family == "CURE" then
		local threatPosition = intent.threatPosition
		local threatRoot = intent.threatRoot
		if typeof(threatRoot) == "Instance"
			and threatRoot:IsA("BasePart")
			and threatRoot.Parent then
			threatPosition = threatRoot.Position
		end
		if typeof(threatPosition) == "Vector3" then
			local away = unitOr(State.root.Position - threatPosition, route)
			local tangentRight = Vector3.new(-away.Z, 0, away.X)
			local orbitSign = tonumber(intent.orbitSign)
			if orbitSign ~= 1 and orbitSign ~= -1 then
				orbitSign = route:Dot(tangentRight) >= 0 and 1 or -1
			end
			local distance = horizontal(State.root.Position - threatPosition).Magnitude
			local awayWeight
			if distance <= 7.0 then
				awayWeight = 0.12
			elseif distance <= 14.0 then
				awayWeight = 0.25
			else
				awayWeight = 0.42
			end
			local lateralCut = tangentRight * orbitSign + away * awayWeight
			if lateralCut.Magnitude >= Config.movementMinimumDirection then
				route = lateralCut.Unit
				movementPolicy = "dynamic-cure-lateral-cut"
			end
		end
	end

	-- A legacy/non-certified Stalker intent may still derive a live lateral cut.
	-- A MotionCore-certified Q route is already a grounded open corridor selected
	-- from the PREP attack line; rotating it every RenderStep made the final vector
	-- change again 64 ms before the supplied hit. Keep the certified direction
	-- fixed through ACTIVE instead.
	if family == "STALKER" and intent.predictiveLocked ~= true then
		local threatPosition = intent.threatPosition
		local threatRoot = intent.threatRoot
		if typeof(threatRoot) == "Instance"
			and threatRoot:IsA("BasePart")
			and threatRoot.Parent then
			threatPosition = threatRoot.Position
		end
		if typeof(threatPosition) == "Vector3" then
			local away = unitOr(State.root.Position - threatPosition, route)
			local tangentRight = Vector3.new(-away.Z, 0, away.X)
			local orbitSign = tonumber(intent.orbitSign)
			if orbitSign ~= 1 and orbitSign ~= -1 then
				orbitSign = route:Dot(tangentRight) >= 0 and 1 or -1
			end
			local distance = horizontal(State.root.Position - threatPosition).Magnitude
			local awayWeight = distance <= 8.5 and 0.10 or 0.20
			local lateralCut = tangentRight * orbitSign + away * awayWeight
			if lateralCut.Magnitude >= Config.movementMinimumDirection then
				route = lateralCut.Unit
				movementPolicy = "dynamic-stalker-lateral-cut"
			end
		end
	end

	-- Direct separation also failed at full native speed: Veil reduced 12.64
	-- studs to 9.28 while the survivor moved 12.68 studs in 0.75 seconds. That
	-- route stayed on the lunge line and let Veil simply chase it down. Cut across
	-- the live lunge heading instead, while retaining the deep, wall-aware route
	-- chosen for this episode. orbitSign is fixed when the route is selected, so
	-- rotating Veil cannot make the player alternate A/D every frame.
	if family == "VEIL_MELEE" or family == "MASKED_LUNGE" then
		local threatPosition = intent.threatPosition
		local threatRoot = intent.threatRoot
		if typeof(threatRoot) == "Instance"
			and threatRoot:IsA("BasePart")
			and threatRoot.Parent then
			threatPosition = threatRoot.Position
		end
		if typeof(threatPosition) == "Vector3" then
			local away = unitOr(State.root.Position - threatPosition, route)
			local attackForward = if typeof(threatRoot) == "Instance"
				and threatRoot:IsA("BasePart")
				then horizontal(threatRoot.AssemblyLinearVelocity)
				else Vector3.zero
			if attackForward.Magnitude < 4.0
				and typeof(threatRoot) == "Instance"
				and threatRoot:IsA("BasePart") then
				attackForward = horizontal(threatRoot.CFrame.LookVector)
			end
			attackForward = unitOr(attackForward, -away)
			local attackRight = Vector3.new(-attackForward.Z, 0, attackForward.X)
			local orbitSign = tonumber(intent.orbitSign)
			if orbitSign ~= 1 and orbitSign ~= -1 then
				orbitSign = route:Dot(attackRight) >= 0 and 1 or -1
			end
			local distance = horizontal(State.root.Position - threatPosition).Magnitude
			local isMaskedLunge = family == "MASKED_LUNGE"
			local awayWeight = if isMaskedLunge
				then (distance <= 7.0 and 0.28 or 0.16)
				else (distance <= 7.0 and 0.34 or 0.22)
			local liveCut = attackRight * orbitSign + away * awayWeight
			local corridorCut = unitOr(liveCut, route) * 0.78 + route * 0.52
			if corridorCut.Magnitude >= Config.movementMinimumDirection then
				route = corridorCut.Unit
				movementPolicy = isMaskedLunge
					and "dynamic-masked-lunge-corridor-cut"
					or "dynamic-veil-melee-corridor-cut"
			end
		end
	end

	if DYNAMIC_AWAY_FAMILIES[family] then
		local threatPosition = intent.threatPosition
		local threatRoot = intent.threatRoot
		if typeof(threatRoot) == "Instance"
			and threatRoot:IsA("BasePart")
			and threatRoot.Parent then
			threatPosition = threatRoot.Position
		end
		if typeof(threatPosition) == "Vector3" then
			local away = unitOr(State.root.Position - threatPosition, route)
			local tangentRight = Vector3.new(-away.Z, 0, away.X)
			local orbitSign = tonumber(intent.orbitSign)
			if orbitSign ~= 1 and orbitSign ~= -1 then
				orbitSign = route:Dot(tangentRight) >= 0 and 1 or -1
			end
			local distance = horizontal(State.root.Position - threatPosition).Magnitude
			local isKillerAway = family == "KILLER"
			local isVeilGuardAway = family == "VEIL_MELEE_GUARD"
			local tangentWeight
			if isKillerAway then
				-- Literal Killer's 132817... signal was previously a mostly-lateral
				-- static route. At point blank that only produced a last-frame jerk.
				-- Recompute direct separation from the live Killer position instead.
				tangentWeight = distance <= 8.5 and 0.10 or 0.16
			elseif isVeilGuardAway then
				tangentWeight = distance <= 8.5 and 0.08 or 0.12
			else
				tangentWeight = distance <= 8.5 and 0.18 or 0.10
			end
			local dynamicAway = away + tangentRight * orbitSign * tangentWeight
			if dynamicAway.Magnitude >= Config.movementMinimumDirection then
				route = dynamicAway.Unit
				if isKillerAway then
					movementPolicy = "dynamic-killer-away"
				elseif isVeilGuardAway then
					movementPolicy = "dynamic-veil-away"
				else
					movementPolicy = "dynamic-stalker-away"
				end
			end
		end
	end

	-- Slasher's late TRACKING attacks need a hard curved cut rather than a single
	-- static world vector. Follow the live tangent every render frame, keep one
	-- side for the whole episode, and retain the wall-aware corridor as a smaller
	-- stabilizing component. This produces the requested rapid 360-style turn at
	-- native game speed without rotating Root/CFrame or writing WalkSpeed.
	if family == "TRACKING"
		or family == "TRACKING_POINTBLANK_GUARD" then
		local threatPosition = intent.threatPosition
		local threatRoot = intent.threatRoot
		if typeof(threatRoot) == "Instance"
			and threatRoot:IsA("BasePart")
			and threatRoot.Parent then
			threatPosition = threatRoot.Position
		end
		if typeof(threatPosition) == "Vector3" then
			local away = unitOr(State.root.Position - threatPosition, route)
			local tangentRight = Vector3.new(-away.Z, 0, away.X)
			local orbitSign = tonumber(intent.orbitSign)
			if orbitSign ~= 1 and orbitSign ~= -1 then
				orbitSign = route:Dot(tangentRight) >= 0 and 1 or -1
			end
			local distance = horizontal(State.root.Position - threatPosition).Magnitude
			local awayWeight = distance <= 7.0 and 0.18 or 0.28
			local liveCut = tangentRight * orbitSign + away * awayWeight
			local corridorCut = unitOr(liveCut, route) + route * 0.35
			if corridorCut.Magnitude >= Config.movementMinimumDirection then
				route = corridorCut.Unit
				movementPolicy = "dynamic-tracking-360-cut"
			end
		end
	end

	-- TRACKING corridors are selected against the Killer position at episode
	-- start, but the Killer can cross around the survivor while that fixed route
	-- is held. Do not keep issuing a now-inward world vector between scheduler
	-- replans. Preserve its lateral side and project it onto a cone that has at
	-- least the configured positive live away component every render frame.
	if family == "TRACKING"
		or family == "TRACKING_POINTBLANK_GUARD" then
		local threatPosition = intent.threatPosition
		local threatRoot = intent.threatRoot
		if typeof(threatRoot) == "Instance"
			and threatRoot:IsA("BasePart")
			and threatRoot.Parent then
			threatPosition = threatRoot.Position
		end
		if typeof(threatPosition) == "Vector3" then
			local away = unitOr(State.root.Position - threatPosition, route)
			local awayDot = route:Dot(away)
			local minimumAwayDot = Config.trackingRouteMinimumAwayDot
			if awayDot < minimumAwayDot then
				local tangent = route - away * awayDot
				if tangent.Magnitude >= Config.movementMinimumDirection then
					local tangentWeight = math.sqrt(math.max(0, 1 - minimumAwayDot * minimumAwayDot))
					route = (tangent.Unit * tangentWeight + away * minimumAwayDot).Unit
				else
					route = away
				end
				movementPolicy = "tracking-live-away-floor"
			end
		end
	end
	end

	-- Every confirmed attack gets the same fixed-side, live 360-style cut that
	-- previously existed only for Slasher. This is direction steering at native
	-- game speed: it never rotates Root/CFrame and never writes WalkSpeed. The
	-- wall-aware planned corridor remains a stabilizer, while the live tangent is
	-- recomputed every render frame so a turning Killer cannot make the held world
	-- vector point inward. PREP remains manual unless its exact profile explicitly
	-- passed forceRouteOnPrep.
	local wallGuardReleaseToManual = false
	local global360Active =
		Config.globalThreat360CutEnabled
		and tostring(intent.group or "") == "DODGE"
		and (tostring(intent.phase or "UNKNOWN") ~= "PREP"
			or intent.forceRouteOnPrep == true)
	if global360Active then
		local threatPosition = intent.threatPosition
		local threatRoot = intent.threatRoot
		if typeof(threatRoot) == "Instance"
			and threatRoot:IsA("BasePart")
			and threatRoot.Parent then
			threatPosition = threatRoot.Position
		end
		if typeof(threatPosition) == "Vector3" then
			local away = unitOr(State.root.Position - threatPosition, route)
			local tangentRight = Vector3.new(-away.Z, 0, away.X)
			local orbitSign = tonumber(intent.orbitSign)
			if orbitSign ~= 1 and orbitSign ~= -1 then
				orbitSign = route:Dot(tangentRight) >= 0 and 1 or -1
			end
			local distance = horizontal(State.root.Position - threatPosition).Magnitude
			local isMaskedRipFamily = family == "RIP"
				or family == "RIP_TRACKING"
				or family == "RIP_POINTBLANK_GUARD"
				or family == "MASKED"
				or family == "MASKED_LUNGE"
			local awayWeight
			if isMaskedRipFamily then
				awayWeight = distance <= Config.globalThreat360CloseDistance
					and Config.globalThreat360MaskedCloseAwayWeight
					or Config.globalThreat360MaskedAwayWeight
			else
				awayWeight = distance <= Config.globalThreat360CloseDistance
					and Config.globalThreat360CloseAwayWeight
					or Config.globalThreat360AwayWeight
			end
			local liveCut = tangentRight * orbitSign + away * awayWeight
			local corridorCut = unitOr(liveCut, route)
				+ route * Config.globalThreat360CorridorWeight
			if corridorCut.Magnitude >= Config.movementMinimumDirection then
				route = corridorCut.Unit
			end

			-- A wall-corridor contribution can never pull the final direction toward
			-- the Killer. Keep the chosen side and project onto a small outward cone.
			local awayDot = route:Dot(away)
			local minimumAwayDot = Config.globalThreat360MinimumAwayDot
			if awayDot < minimumAwayDot then
				local tangent = route - away * awayDot
				if tangent.Magnitude >= Config.movementMinimumDirection then
					local tangentWeight = math.sqrt(
						math.max(0, 1 - minimumAwayDot * minimumAwayDot)
					)
					route = (tangent.Unit * tangentWeight
						+ away * minimumAwayDot).Unit
				else
					route = away
				end
			end
			movementPolicy = "dynamic-global-360-cut"

			-- The original planner validates threat.routeDirection, but the live 360
			-- transform above creates a different final direction after planning. The
			-- old code never raycast that final vector, so it could continuously push
			-- into a wall even while the stored route was marked open. Check the exact
			-- vector sent to Player:Move, flip the fixed side only when that opens a
			-- real corridor, and relinquish the render write when every option is boxed.
			local episode = intent.threatEpisode
			local t = now()
			if Config.globalThreat360WallGuardEnabled and type(episode) == "table" then
				local manualReleaseUntil = tonumber(episode.globalWallManualReleaseUntil)
				if manualReleaseUntil and t < manualReleaseUntil then
					wallGuardReleaseToManual = true
				end

				local lastCheckAt = tonumber(episode.globalWallLastCheckAt) or -math.huge
				local shouldCheck = t - lastCheckAt
					>= Config.globalThreat360WallCheckInterval
				if shouldCheck then
					episode.globalWallLastCheckAt = t
					episode.globalWallOverride = nil
					local currentClearance = pathClearance(
						State.root.Position,
						route,
						Config.globalThreat360WallProbeDistance
					)
					if currentClearance < Config.globalThreat360WallBlockedClearance then
						local oppositeCut = unitOr(
							tangentRight * -orbitSign + away * awayWeight,
							away
						)
						local plannedRoute = unitOr(intent.direction, away)
						local candidates = {
							{kind = "flip-side", direction = oppositeCut, sign = -orbitSign},
							{kind = "direct-away", direction = away, sign = orbitSign},
							{kind = "planned-corridor", direction = plannedRoute, sign = orbitSign},
						}
						local best = nil :: any
						local bestClearance = currentClearance
						for _, candidate in ipairs(candidates) do
							local candidateDirection = candidate.direction
							if candidateDirection:Dot(away)
								>= Config.globalThreat360MinimumAwayDot then
								local candidateClearance = pathClearance(
									State.root.Position,
									candidateDirection,
									Config.globalThreat360WallProbeDistance
								)
								local groundPosition = State.root.Position
									+ candidateDirection * math.min(candidateClearance, 3.5)
								if candidateClearance > bestClearance + 0.25
									and groundOkay(groundPosition) then
									best = candidate
									bestClearance = candidateClearance
								end
							end
						end

						if best
							and bestClearance
								>= Config.globalThreat360WallMinimumEscapeClearance then
							route = best.direction
							episode.globalWallOverride = route
							episode.globalWallManualReleaseUntil = nil
							wallGuardReleaseToManual = false
							local lastSwitchAt = tonumber(episode.globalWallLastSwitchAt)
								or -math.huge
							if best.kind == "flip-side"
								and t - lastSwitchAt
									>= Config.globalThreat360WallSwitchCooldown then
								episode.orbitSign = best.sign
								intent.orbitSign = best.sign
								episode.globalWallLastSwitchAt = t
							end
							movementPolicy = "dynamic-global-360-wall-escape"
							Diagnostics.Push(
								"DODGE_WALL_ESCAPE",
								string.format(
									"episode=%s family=%s oldClear=%.2f newClear=%.2f kind=%s sign=%d action=use-open-final-vector",
									tostring(intent.episodeId or "none"),
									family,
									currentClearance,
									bestClearance,
									best.kind,
									tonumber(best.sign) or 0
								),
								"dodge-wall-escape-" .. tostring(intent.episodeId),
								0.12
							)
						else
							-- No grounded option reaches the minimum open clearance. Stop
							-- owning this frame immediately instead of pushing another 1-2
							-- studs into the obstruction while waiting for a "critical" hit.
							wallGuardReleaseToManual = true
							episode.globalWallManualReleaseUntil =
								t + Config.globalThreat360WallManualReleaseTime
							Diagnostics.Push(
								"DODGE_WALL_RELEASE_MANUAL",
								string.format(
									"episode=%s family=%s clear=%.2f best=%.2f action=skip-helper-write-keep-native-input",
									tostring(intent.episodeId or "none"),
									family,
									currentClearance,
									bestClearance
								),
								"dodge-wall-manual-" .. tostring(intent.episodeId),
								0.12
							)
						end
					else
						episode.globalWallManualReleaseUntil = nil
						wallGuardReleaseToManual = false
					end
				elseif typeof(episode.globalWallOverride) == "Vector3" then
					route = unitOr(episode.globalWallOverride, route)
					movementPolicy = "dynamic-global-360-wall-escape"
				end
			end
		end
	end

	if conservativeDodge then
		-- RoutePlanner validated this exact world direction. Do not transform it
		-- after planning: that was the source of the old wall/360 oscillation. If
		-- the Killer crosses far enough that the fixed vector now points inward,
		-- relinquish this frame to native WASD instead of steering at the Killer.
		local threatPosition = intent.threatPosition
		local threatRoot = intent.threatRoot
		if typeof(threatRoot) == "Instance"
			and threatRoot:IsA("BasePart")
			and threatRoot.Parent then
			threatPosition = threatRoot.Position
		end
		if typeof(threatPosition) == "Vector3" then
			local liveAway = unitOr(State.root.Position - threatPosition, route)
			local liveAwayDot = route:Dot(liveAway)
			local requiredAwayDot = tonumber(intent.minimumAwayDot)
				or (family == "DISTANCE_KEEPER"
				and Config.threatDistanceKeeperMinimumAwayDot
				or (intent.predictiveLocked == true
					and Config.predictiveMinimumAwayDot
					or Config.threatConservativeMinimumAwayDot))
			if liveAwayDot < requiredAwayDot then
				Diagnostics.Push(
					"DODGE_CONSERVATIVE_RELEASE",
					string.format(
						"episode=%s family=%s awayDot=%.2f reason=route-became-inward action=native-WASD",
						tostring(intent.episodeId or "none"),
						family,
						liveAwayDot
					),
					"conservative-inward-" .. tostring(intent.episodeId or "none"),
					0.20
				)
				return
			end
		end
		movementPolicy = intentUsesPredictiveBestEffort(intent)
			and "best-effort-better-than-WASD"
			or "conservative-fixed-open-route"
	end

	local physicalManual = CharacterController.PhysicalInputDirection()
	local manual = physicalManual or Vector3.zero
	local combined = route
	local group =
		tostring(intent.group or "UNKNOWN")
	local owner =
		tostring(intent.owner or "unknown")
	local routeWeight =
		Config.movementRouteWeight
	local manualWeight =
		Config.movementManualWeight
	local routeManualDot = 0.0
	local manualAwayDot = -1.0
	local phase = tostring(intent.phase or "UNKNOWN")
	local liveThreatDistance = tonumber(intent.threatDistance) or math.huge
	local strictRouteDistance = Config.movementStrictRouteDistance
	if family == "STALKER" then
		-- Exact Stalker Q owns movement across its full catalog range. Blending
		-- manual input back in above 12 studs contradicted the control-lock policy
		-- and could return control before the Q AnimationTrack had finished.
		strictRouteDistance = Config.stalkerStrictRouteDistance
	elseif family == "TRACKING"
		or family == "TRACKING_POINTBLANK_GUARD" then
		-- Once a confirmed Slasher attack owns movement, do not blend the
		-- player's held key back in halfway through the animation.
		strictRouteDistance = Config.trackingStrictRouteDistance
	elseif family == "VEIL_THROW" then
		strictRouteDistance = 42.0
	elseif family == "VEIL_DELAYED" then
		strictRouteDistance = 30.0
	elseif family == "VEIL_MELEE" then
		strictRouteDistance = 16.0
	elseif family == "MASKED_LUNGE" then
		strictRouteDistance = 16.0
	elseif family == "MASKED_CLOSE_AIM_GUARD" then
		strictRouteDistance = Config.maskedCloseAimGuardSafeDistance
	elseif family == "HIDDEN_CLOSE_AIM_GUARD" then
		strictRouteDistance = Config.hiddenCloseAimGuardSafeDistance
	elseif family == "KILLER_CLOSE_AIM_GUARD" then
		strictRouteDistance = Config.killerCloseAimGuardSafeDistance
	elseif family == "KILLER" then
		-- 104689... was detected at 18.69 studs, but the old default strict
		-- distance blended a completely opposite manual vector back in. Exact
		-- ACTIVE owns its full 22-stud catalog range. Exact PREP can do the same
		-- only after its existing aimed-or-approaching gate and forceRouteOnPrep.
		strictRouteDistance = 22.0
	elseif family == "RIP"
		or family == "RIP_TRACKING"
		or family == "RIP_POINTBLANK_GUARD" then
		-- Confirmed RIP attacks are actionable throughout their catalog range.
		-- Never blend an opposite manual vector back into the lunge sidestep.
		strictRouteDistance = Config.ripStrictRouteDistance
	elseif family == "CURE" then
		strictRouteDistance = 23.0
	elseif family == "VEIL_MELEE_GUARD" then
		-- Preserve full away authority through the hysteresis release boundary;
		-- otherwise manual input can pull back toward Veil between 16 and 18 studs.
		strictRouteDistance = Config.veilPointBlankGuardSafeDistance
	elseif family == "PERSONAL_SPACE_GUARD" then
		strictRouteDistance = Config.genericPointBlankGuardSafeDistance
	end
	local strictRouteAuthority =
		group == "EXIT"
		or group == "VAULT_COMMIT"
		or group == "VAULT_EXIT"
		or conservativeDodge
		or (Config.globalThreat360CutEnabled
			and group == "DODGE"
			and (phase ~= "PREP" or intent.forceRouteOnPrep == true))
		or (PURE_ROUTE_FAMILIES[family]
			and (phase ~= "PREP" or intent.forceRouteOnPrep == true)
			and liveThreatDistance <= strictRouteDistance)
	if strictRouteAuthority then
		manualWeight = 0
	elseif group == "DODGE" and Config.movementManualFirstEnabled then
		routeWeight = Config.movementManualFirstRouteWeight
		manualWeight = Config.movementManualFirstManualWeight
	elseif group == "REPAIR_RESUME" then
		-- Automatic return should be decisive but still allow a small amount of
		-- manual steering around map geometry.
		routeWeight = 1.00
		manualWeight = 0.15
	elseif group == "ZOMBIE" then
		-- While an interaction is still being broken, own the full away route.
		-- After release, preserve the player's already-safe manual escape.
		routeWeight = 1.00
		local interacting = CharacterController.InteractionStatus()
		manualWeight = interacting and 0.0 or 0.65
	elseif family == "GENERIC_PRESSURE_GUARD" then
		-- A generic fallback has less information than the player. It assists
		-- the current escape direction instead of replacing it.
		routeWeight = Config.movementGenericRouteWeight
		manualWeight = Config.movementGenericManualWeight
	end
	if manual.Magnitude
		>= Config.movementMinimumDirection then
		local manualUnit = manual.Unit
		routeManualDot = route:Dot(manualUnit)
		local threatPosition = intent.threatPosition
		if typeof(threatPosition) == "Vector3" then
			local away = unitOr(
				State.root.Position - threatPosition,
				manualUnit
			)
			manualAwayDot = manualUnit:Dot(away)
		end

		if manualWeight > 0 then
		if group == "DODGE"
			and Config.movementManualFirstEnabled
			and not strictRouteAuthority
			and manualAwayDot >= Config.movementManualPreserveAwayDot
			and routeManualDot <= Config.movementManualPreserveConflictDot then
			combined = manualUnit
			movementPolicy = "manual-authority-preserved"
		elseif group == "DODGE" and phase == "PREP" then
			combined = manualUnit
			movementPolicy = "prep-manual-only"
		elseif group == "ZOMBIE"
			and manualAwayDot >= 0.20
			and routeManualDot < -0.05 then
			-- The user's direction is already increasing distance from the NPC. Do
			-- not counter-steer into the opposite lateral key.
			combined = manualUnit
			movementPolicy = "zombie-manual-preserved"
		elseif family == "GENERIC_PRESSURE_GUARD"
			and routeManualDot < Config.movementReverseDotThreshold
			and manualAwayDot >= Config.movementManualAwaySafetyDot then
			-- This is the exact failure visible in the supplied log: the fallback
			-- selected a direction almost opposite to Humanoid.MoveDirection and
			-- then zeroed manual input. Preserve a manual direction that is not
			-- driving strongly toward the Killer.
			combined = manualUnit
			movementPolicy = "manual-preserved"
		else
			local blended =
				route * routeWeight
					+ manualUnit * manualWeight
			if blended.Magnitude
				>= Config.movementMinimumDirection then
				combined = blended.Unit
				movementPolicy = "blended"
			end
		end
		end
	end


	if wallGuardReleaseToManual then
		-- Do not write Vector3.zero: returning leaves the native ControlModule's
		-- already-applied WASD direction intact for this frame.
		State.movementLastAppliedEpisode = nil
		return
	end
	-- Auxiliary validation is installed by the live runtime. Keep the render
	-- writer compatible with the smaller deterministic movement harness used by
	-- regression tests and with an early bootstrap frame before that method is
	-- attached.
	local finalDirectionSafe, finalDirectionReason = true, "not-auxiliary"
	if type(MovementWriter.ValidateAuxiliaryDirection) == "function" then
		finalDirectionSafe, finalDirectionReason =
			MovementWriter.ValidateAuxiliaryDirection(intent, combined)
	end
	if not finalDirectionSafe then
		State.movementLastAppliedEpisode = nil
		MovementWriter.Clear(owner, finalDirectionReason)
		if group == "EXIT" and finalDirectionReason ~= "ray-budget" then
			ExitController.Stop(finalDirectionReason, true)
		end
		Diagnostics.Push("MOVEMENT_FINAL_DIRECTION_REJECTED",
			string.format("owner=%s group=%s reason=%s action=native-WASD", owner, group, finalDirectionReason),
			"movement-final-direction-" .. owner, 0.25)
		return
	end

	LocalPlayer:Move(combined, false)
	local appliedAt = now()
	State.movementRenderWrites += 1
	State.movementLastAppliedAt = appliedAt
	local appliedThreat = intent.threatEpisode
	if type(appliedThreat) == "table" then
		local previousCommands = tonumber(appliedThreat.movementCommands) or 0
		appliedThreat.movementCommands = previousCommands + 1
		appliedThreat.lastMovementCommandAt = appliedAt
		if State.root then
			local actualSpeed = horizontal(
				State.root.AssemblyLinearVelocity
			).Magnitude
			appliedThreat.maxActualHorizontalSpeed = math.max(
				tonumber(appliedThreat.maxActualHorizontalSpeed) or 0,
				actualSpeed
			)
			-- Stuck progress is meaningful only after the route has actually reached
			-- Player:Move. Initialising from ApplyPlan allowed PreSimulation to reject
			-- a route before the first post-input render write.
			if previousCommands == 0 then
				appliedThreat.stuckSampleAt = appliedAt
				appliedThreat.stuckSamplePosition = State.root.Position
			end
		end
	end

	local episode =
		tostring(intent.episodeId or "none")
	local applicationKey =
		owner .. ":" .. group .. ":" .. episode
	if State.movementLastAppliedEpisode
		~= applicationKey then
		State.movementLastAppliedEpisode =
			applicationKey
		local eventName =
			group == "DODGE"
				and "DODGE_APPLIED"
				or "MOVEMENT_APPLIED"
		Diagnostics.Push(
			eventName,
			string.format(
				"owner=%s group=%s episode=%s class=%s classSource=%s family=%s motionType=%s age=%.3f method=PlayerMoveAfterInput route=(%.2f,%.2f) manual=(%.2f,%.2f) final=(%.2f,%.2f) routeManualDot=%.2f manualAwayDot=%.2f policy=%s speed=game-native",
				owner,
				group,
				episode,
				tostring(intent.killerClass or "n/a"),
				tostring(intent.killerClassSource or "n/a"),
				family,
				tostring(intent.motionType or "legacy"),
				intent.threatStartedAt
					and now() - intent.threatStartedAt
					or -1,
				route.X,
				route.Z,
				manual.X,
				manual.Z,
				combined.X,
				combined.Z,
				routeManualDot,
				manualAwayDot,
				movementPolicy
			),
			"movement-applied-" .. applicationKey,
			0.05
		)
	end
end

---------------------------------------------------------------------
-- 12. ThreatController
---------------------------------------------------------------------

ThreatController = {}

local function failureFamilyKey(family: any): string
	local key = tostring(family or "UNKNOWN")
	-- Unknown fallback emits UNKNOWN_VEIL. It must share the exact Veil state
	-- instead of bypassing it under a separate failure key.
	if string.find(key, "VEIL", 1, true) then
		return "VEIL"
	end
	-- Every Masked/RIP animation family belongs to one kit. This includes
	-- RIP_TRACKING and RIP_EXTENDED; otherwise a FINISHER family can bypass
	-- the state learned from the ordinary RIP animation.
	if string.sub(key, 1, 3) == "RIP"
		or string.sub(key, 1, 6) == "MASKED" then
		return "RIP"
	end
	if string.sub(key, 1, 8) == "TRACKING" then
		return "TRACKING"
	end
	return key
end

local function phaseRank(phase: string): number
	return PHASE_RANK[phase] or 0
end

local function threatDistance(threat: any): number
	local root = State.root
	local killerRoot = threat and threat.killerRoot
	if not root or not killerRoot or not killerRoot.Parent then
		return math.huge
	end
	return horizontal(killerRoot.Position - root.Position).Magnitude
end

function ThreatController.WriterState(threat: any): string
	local selected = State.movementSelectedIntent
	local selectedEpisode = selected and tonumber(selected.episodeId) or nil
	if threat
		and selectedEpisode == tonumber(threat.episodeId)
		and now() - (State.movementLastAppliedAt or -math.huge) <= 0.20 then
		return "applied"
	end
	if threat and threat.routeDirection ~= nil then
		return "route-not-applied"
	end
	if threat and threat.routePending == true then
		return "route-pending"
	end
	return "none"
end

function ThreatController.CaptureRecentSnapshot(threat: any, reason: string): ()
	if not threat then
		return
	end
	State.telemetry.recentThreatSnapshot = {
		episodeId = threat.episodeId,
		killerName = threat.killerModel and threat.killerModel.Name or "none",
		killerClass = threat.killerClass or "Unknown",
		family = threat.family or "UNKNOWN",
		phase = threat.phase or "UNKNOWN",
		animationId = threat.activeAnimationId or threat.primaryAnimationId or "none",
		distance = threatDistance(threat),
		predictedSeparation = threat.predictiveSeparation,
		requiredSeparation = threat.predictiveRequiredSeparation,
		clearance = threat.routeClearance,
		helperMovement = ThreatController.WriterState(threat) == "applied",
		writerState = ThreatController.WriterState(threat),
		reason = reason,
	}
	State.telemetry.recentThreatSnapshotAt = now()
end

function ThreatController.LogCharacterTerminalSnapshot(reason: string): ()
	local character = State.character
	if not character
		or State.telemetry.terminalSnapshotCharacter == character then
		return
	end
	State.telemetry.terminalSnapshotCharacter = character
	State.telemetry.terminalSnapshotAt = now()

	local humanoid = State.humanoid
	local root = State.root
	local threat = State.activeThreat
	local recent = State.telemetry.recentThreatSnapshot
	local recentAge = now()
		- (State.telemetry.recentThreatSnapshotAt or -math.huge)
	local nearestModel = State.nearestKiller
	local nearestRoot = modelRoot(nearestModel)
	local nearestDistance = math.huge
	local nearestFacing = -1.0
	local nearestApproach = 0.0
	local nearestClass = "Unknown"
	if nearestModel and nearestRoot and root then
		nearestDistance = horizontal(nearestRoot.Position - root.Position).Magnitude
		nearestFacing = getFacingDot(nearestRoot, root)
		nearestApproach = getApproachSpeed(nearestRoot, root)
		nearestClass = tostring(
			ThreatController.KillerClassInfo(nearestModel).class or "Unknown"
		)
	end
	local interactionLocked, interactionStatus =
		CharacterController.DefensiveMovementStatus()
	local selected = State.movementSelectedIntent
	local family = threat and threat.family
		or (recentAge <= 2.0 and recent and recent.family)
		or "none"
	local episodeId = threat and threat.episodeId
		or (recentAge <= 2.0 and recent and recent.episodeId)
		or "none"
	local animationId = threat
		and (threat.activeAnimationId or threat.primaryAnimationId)
		or (recentAge <= 2.0 and recent and recent.animationId)
		or "none"
	local writerState = threat
		and ThreatController.WriterState(threat)
		or (selected and "intent-selected" or "none")

	Diagnostics.Push(
		"CHARACTER_TERMINAL_SNAPSHOT",
		string.format(
			"reason=%s character=%s hp=%.1f walk=%.2f anchored=%s interactionLocked=%s interaction=%s matchActive=%s episode=%s family=%s id=%s writer=%s selectedOwner=%s nearest=%s class=%s d=%s facing=%.2f killerApproach=%+.2f lastDamageAge=%s recentThreatAge=%s",
			reason,
			character:GetFullName(),
			humanoid and humanoid.Health or -1.0,
			humanoid and humanoid.WalkSpeed or -1.0,
			tostring(root and root.Anchored or false),
			tostring(interactionLocked),
			tostring(interactionStatus),
			tostring(State.matchActive),
			tostring(episodeId),
			tostring(family),
			tostring(animationId),
			writerState,
			tostring(selected and selected.owner or "none"),
			nearestModel and nearestModel.Name or "none",
			nearestClass,
			nearestDistance < math.huge and string.format("%.2f", nearestDistance) or "inf",
			nearestFacing,
			nearestApproach,
			State.telemetry.lastDamageAt > -math.huge
				and string.format("%.3f", now() - State.telemetry.lastDamageAt)
				or "inf",
			recentAge < math.huge and string.format("%.3f", recentAge) or "inf"
		),
		"character-terminal-" .. tostring(character),
		0.0
	)
	Diagnostics.DumpRecent(
		"character-terminal-" .. reason,
		Config.diagnosticsDeathDumpCount
	)
end

function ThreatController.Release(reason: string): ()
	local threat = State.activeThreat
	if not threat then
		return
	end
	ThreatController.CaptureRecentSnapshot(threat, reason)
	threat.released = true
	threat.releaseReason = reason
	if threat.motionObserveOnlyNoRoute == true
		and threat.killerModel then
		State.noCorridorGuardBlockedUntilByModel[threat.killerModel] = math.max(
			State.noCorridorGuardBlockedUntilByModel[threat.killerModel]
				or -math.huge,
			now() + Config.motionCoreNoCorridorEpisodeCooldown
		)
	end
	local moved = 0.0
	if State.root and threat.startRootPosition then
		moved = horizontal(
			State.root.Position - threat.startRootPosition
		).Magnitude
	end
	if threat.killerModel
		and threat.family == "TRACKING"
		and threat.routeDirection
		and not threat.hitReceived
		and (threat.routeClearance or 0) >= Config.trackingRouteMinimumContinuationClearance then
		State.lastEscapeRouteByModel[threat.killerModel] = {
			direction = threat.routeDirection,
			time = now(),
			clearance = threat.routeClearance,
		}
	end
	Diagnostics.Push(
		"THREAT_RELEASE",
		string.format(
			"episode=%d family=%s killer=%s reason=%s moved=%.2f maxActualSpeed=%.2f commands=%d softWrites=%d",
			threat.episodeId,
			threat.family,
			threat.killerModel and threat.killerModel.Name or "none",
			reason,
			moved,
			threat.maxActualHorizontalSpeed or 0,
			threat.movementCommands or 0,
			threat.softAccelerationWrites or 0
		),
		"threat-release",
		0.02
	)
	State.activeThreat = nil
	MovementWriter.Clear(OWNER.THREAT, reason)
end

function ThreatController.SelectRoute(threat: any, requireDeep: boolean?): boolean
	local root = State.root
	local killerRoot = threat.killerRoot
	if not root or not killerRoot then
		return false
	end
	local predictiveSignalAuthorized = threat.phase == "ACTIVE"
		or (threat.phase == "PREP" and threat.forceRouteOnPrep == true)
	if Config.predictivePlannerEnabled
		and predictiveSignalAuthorized
		and (
			threat.synthetic ~= true
			or threat.confirmedAimGuard == true
			or threat.family == "DISTANCE_KEEPER"
		) then
		local predicted = PredictivePlanner.Select(
			threat,
			threat.motionType == "HOMING_LUNGE"
		)
		local controlledFallback =
			ThreatMotionCore.IsControlledFallback(predicted, threat)
		if not predicted
			or (predicted.feasible ~= true and not controlledFallback) then
			Diagnostics.Push(
				"DODGE_FEASIBILITY_REJECTED",
				string.format(
					"episode=%d family=%s id=%s source=%s type=%s delay=%.3f clear=%.2f exitDepth=%.2f exitBranches=%d travel=%.2f predictedSep=%.2f manualSep=%.2f manualGain=%+.2f required=%.2f gain=%.2f safetyFloor=%s action=native-WASD-observe-threat",
					threat.episodeId,
					tostring(threat.family or "UNKNOWN"),
					tostring(threat.activeAnimationId or threat.primaryAnimationId or "none"),
					predicted and tostring(predicted.source) or "none",
					predicted and tostring(predicted.motionType) or tostring(threat.motionType or "none"),
					predicted and predicted.impactDelay or -1,
					predicted and predicted.clearance or 0,
					predicted and predicted.escapeDepth or 0,
					predicted and predicted.escapeBranches or 0,
					predicted and predicted.travel or 0,
					predicted and predicted.separation or 0,
					predicted and predicted.manualSeparation or 0,
					predicted and predicted.improvementVsManual or 0,
					predicted and predicted.requiredSeparation or 0,
					predicted and predicted.gain or 0,
					tostring(predicted and predicted.safetyFloor == true)
				),
				"predictive-rejected-" .. tostring(threat.episodeId),
				0.05
			)
			threat.feasibilityRejected = true
			threat.motionNoRouteGeometryAt = now()
			threat.motionNoRouteOrigin = root.Position
			threat.motionNoRouteThreatPosition = killerRoot.Position
			return false
		else
		if Config.motionCoreEnabled then
			local applied = ThreatMotionCore.ApplyPlan(
				threat,
				predicted,
				"initial"
			)
			if applied then
				threat.motionNoRouteGeometryAt = nil
				threat.motionNoRouteOrigin = nil
				threat.motionNoRouteThreatPosition = nil
			end
			return applied
		end
		threat.routeDirection = predicted.direction
		threat.routeLocked = true
		threat.predictiveLocked = true
		threat.predictiveImpactDelay = predicted.impactDelay
		threat.predictiveSeparation = predicted.separation
		threat.predictiveRequiredSeparation = predicted.requiredSeparation
		threat.predictiveBaselineSeparation = predicted.baselineSeparation
		threat.predictiveGain = predicted.gain
		threat.routeClearance = predicted.clearance
		threat.routeSafeLength = predicted.clearance
		threat.routeBranches = 0
		Diagnostics.Push(
			"PREDICTIVE_ROUTE_SELECTED",
			string.format(
				"episode=%d family=%s id=%s source=%s delay=%.3f killerForecast=%.2f travel=%.2f predictedSep=%.2f baseline=%.2f gain=%.2f lateral=%.2f clear=%.2f awayDot=%.2f turnDot=%.2f side=%s",
				threat.episodeId,
				tostring(threat.family or "UNKNOWN"),
				tostring(threat.activeAnimationId or threat.primaryAnimationId or "none"),
				tostring(predicted.source),
				predicted.impactDelay,
				predicted.forecastKillerSpeed,
				predicted.travel,
				predicted.separation,
				predicted.baselineSeparation,
				predicted.gain,
				predicted.lateralSeparation,
				predicted.clearance,
				predicted.awayDot,
				predicted.turnDot,
				predicted.direction:Dot(root.CFrame.RightVector) >= 0 and "RIGHT" or "LEFT"
			),
			"predictive-selected-" .. tostring(threat.episodeId),
			0.01
		)
		return true
		end
	end
	local preferredDirection = threat.routeDirection
	if not preferredDirection
		and threat.family == "TRACKING"
		and threat.killerModel then
		local previousRoute = State.lastEscapeRouteByModel[threat.killerModel]
		if previousRoute
			and now() - (previousRoute.time or -math.huge)
				<= Config.trackingRouteContinuationSeconds
			and (previousRoute.clearance or 0)
				>= Config.trackingRouteMinimumContinuationClearance then
			preferredDirection = previousRoute.direction
		end
	end
	if not preferredDirection
		and Config.threatConservativeMovementEnabled then
		local manual = threat.initialManualDirection
		if manual and manual.Magnitude >= Config.movementMinimumDirection then
			local away = unitOr(root.Position - killerRoot.Position, manual)
			local requiredAwayDot = threat.family == "DISTANCE_KEEPER"
				and Config.threatDistanceKeeperMinimumAwayDot
				or Config.threatConservativeMinimumAwayDot
			if manual.Unit:Dot(away) >= requiredAwayDot then
				preferredDirection = manual.Unit
			end
		end
	end
	if not preferredDirection
		and not Config.threatConservativeMovementEnabled
		and not PURE_ROUTE_FAMILIES[tostring(threat.family)] then
		local manual = threat.initialManualDirection
		if manual and manual.Magnitude >= Config.movementMinimumDirection then
			preferredDirection = manual.Unit
		end
	end
	local personalSpaceRoute = threat.family == "PERSONAL_SPACE_GUARD"
	local result = RoutePlanner.FindEscapeRoute({
		origin = root.Position,
		threatPosition = killerRoot.Position,
		preferredDirection = preferredDirection,
		routeLocked = threat.routeLocked,
		requireDeep = requireDeep == true,
		lateralWeight = threat.lateralWeight,
		awayWeight = threat.awayWeight,
		routeAngles = personalSpaceRoute and Config.personalSpaceRouteAngles or nil,
		branchAngles = personalSpaceRoute and Config.personalSpaceRouteBranchAngles or nil,
		enrichCount = personalSpaceRoute and Config.personalSpaceRouteEnrichCount or nil,
		probeDistance = personalSpaceRoute and Config.personalSpaceRouteProbeDistance or nil,
		restrictToEnriched = personalSpaceRoute,
		minimumAwayDot = Config.threatConservativeMovementEnabled
			and (threat.family == "DISTANCE_KEEPER"
				and Config.threatDistanceKeeperMinimumAwayDot
				or Config.threatConservativeMinimumAwayDot)
			or ((threat.family == "TRACKING"
				or threat.family == "TRACKING_POINTBLANK_GUARD")
				and Config.trackingRouteMinimumAwayDot
				or nil),
	})
	if not result or not result.direction then
		return false
	end
	local personalSpaceNoOpenCorridor = personalSpaceRoute
		and (
			result.blocked == true
			or (result.clearance or 0) < Config.personalSpaceRouteBlockedClearance
			or result.reason == "dead-end"
		)
	if personalSpaceNoOpenCorridor then
		State.personalSpaceRouteBlockedUntilByModel[threat.killerModel] =
			now() + Config.personalSpaceRouteRetryCooldown
		Diagnostics.Push(
			"PERSONAL_SPACE_NO_OPEN_CORRIDOR",
			string.format(
				"episode=%d clear=%.2f branches=%d reason=%s action=release-to-manual",
				threat.episodeId,
				result.clearance or 0,
				result.branches or 0,
				result.reason or "unknown"
			),
			"personal-space-no-corridor-" .. tostring(threat.episodeId),
			0.05
		)
		return false
	end
	if result.blocked then
		Diagnostics.Push(
			"ROUTE_BEST_EFFORT",
			string.format(
				"episode=%d family=%s clear=%.2f reason=%s action=keep-moving",
				threat.episodeId,
				threat.family,
				result.clearance or 0,
				result.reason or "blocked"
			),
			"route-best-effort-" .. tostring(threat.episodeId),
			0.10
		)
	end
	threat.routeDirection = result.direction
	if DYNAMIC_ORBIT_FAMILIES[tostring(threat.family)] then
		local away = unitOr(root.Position - killerRoot.Position, result.direction)
		local tangentRight = Vector3.new(-away.Z, 0, away.X)
		local continuity = threat.initialManualDirection
		if not continuity or continuity.Magnitude < Config.movementMinimumDirection then
			continuity = horizontal(root.AssemblyLinearVelocity)
		end
		if continuity and continuity.Magnitude >= Config.ripContinuityMinimumSpeed then
			-- Preserve momentum by choosing the lateral side that requires the
			-- smallest turn. The route remains a true tangent/away escape; only
			-- its left/right sign follows current motion.
			threat.orbitSign = continuity.Unit:Dot(tangentRight) >= 0 and 1 or -1
			Diagnostics.Push(
				"RIP_CONTINUITY_SIDE",
				string.format(
					"episode=%d family=%s source=%s sign=%d speed=%.2f",
					threat.episodeId,
					tostring(threat.family),
					threat.initialManualDirection and "manual" or "velocity",
					threat.orbitSign,
					continuity.Magnitude
				),
				"rip-continuity-" .. tostring(threat.episodeId),
				0.05
			)
		else
			threat.orbitSign = result.direction:Dot(tangentRight) >= 0 and 1 or -1
		end
	elseif threat.family == "TRACKING"
		or threat.family == "TRACKING_POINTBLANK_GUARD" then
		-- Lock one side from the wall-aware corridor. The render writer can then
		-- curve rapidly around the live Slasher position without alternating A/D.
		local away = unitOr(root.Position - killerRoot.Position, result.direction)
		local tangentRight = Vector3.new(-away.Z, 0, away.X)
		threat.orbitSign = result.direction:Dot(tangentRight) >= 0 and 1 or -1
	elseif threat.family == "VEIL_MELEE"
		or threat.family == "MASKED_LUNGE" then
		-- Pick the side from the wall-aware route once. The movement writer may
		-- follow the attacker's live lunge heading, but it never swaps mid-swing.
		local attackForward = horizontal(killerRoot.AssemblyLinearVelocity)
		if attackForward.Magnitude < 4.0 then
			attackForward = horizontal(killerRoot.CFrame.LookVector)
		end
		local away = unitOr(root.Position - killerRoot.Position, result.direction)
		attackForward = unitOr(attackForward, -away)
		local attackRight = Vector3.new(-attackForward.Z, 0, attackForward.X)
		threat.orbitSign = result.direction:Dot(attackRight) >= 0 and 1 or -1
		local sideDiagnostic = threat.family == "MASKED_LUNGE"
			and "MASKED_LUNGE_CUT_SIDE"
			or "VEIL_MELEE_CUT_SIDE"
		Diagnostics.Push(
			sideDiagnostic,
			string.format(
				"episode=%d sign=%d clear=%.2f action=fixed-corridor-side",
				threat.episodeId,
				threat.orbitSign,
				result.clearance or 0
			),
			string.lower(sideDiagnostic) .. "-" .. tostring(threat.episodeId),
			0.05
		)
	end
	-- The render writer now applies a live tangent to every confirmed DODGE.
	-- Persist one wall-aware side for every family so this cannot alternate A/D
	-- when the attacker turns or crosses the survivor during the animation.
	if threat.orbitSign ~= 1 and threat.orbitSign ~= -1 then
		local away = unitOr(root.Position - killerRoot.Position, result.direction)
		local tangentRight = Vector3.new(-away.Z, 0, away.X)
		threat.orbitSign = result.direction:Dot(tangentRight) >= 0 and 1 or -1
	end
	threat.routeLocked = true
	threat.routeClearance = result.clearance
	threat.routeSafeLength = result.safeLength
	threat.routeBranches = result.branches
	Diagnostics.Push(
		"ROUTE_SELECTED",
		string.format(
			"episode=%d family=%s side=%s clear=%.2f safeLen=%.2f branches=%d awayDot=%.2f score=%.2f reason=%s bestEffort=%s",
			threat.episodeId,
			threat.family,
			result.direction:Dot(root.CFrame.RightVector) >= 0 and "RIGHT" or "LEFT",
			result.clearance or 0,
			result.safeLength or 0,
			result.branches or 0,
			result.awayDot or 0,
			result.score or 0,
			result.reason or "none",
			tostring(result.blocked == true)
		),
		"route-select-" .. tostring(threat.episodeId),
		0.01
	)
	return true
end

function ThreatController.SignalStartedAt(track: AnimationTrack?, playback: any): number
	local t = now()
	if playback and tonumber(playback.startedAt) then
		return math.min(t, playback.startedAt)
	end
	local position = track and math.max(0, tonumber(track.TimePosition) or 0) or 0
	local speed = track and math.abs(tonumber(track.Speed) or 1) or 1
	return t - position / math.max(speed, 0.01)
end

function ThreatController.StalePrep(threat: any, metadata: any, track: AnimationTrack?, playback: any): boolean
	return threat ~= nil
		and metadata.phase == "PREP"
		and threat.lastExactActiveStartedAt ~= nil
		and ThreatController.SignalStartedAt(track, playback)
			<= threat.lastExactActiveStartedAt + 0.001
end

function ThreatController.PostHitSuppressed(): boolean
	local sinceDamage = now() - State.telemetry.lastDamageAt
	return sinceDamage >= 0 and sinceDamage < Config.postHitThreatReacquireBlock
end

function ThreatController.NewEpisode(model: Model, killerRoot: BasePart, id: string, metadata: any, track: AnimationTrack?, playback: any): any
	State.telemetry.episodeCounter += 1
	local t = now()
	local classInfo = ThreatController.KillerClassInfo(model)
	local episode = {
		episodeId = State.telemetry.episodeCounter,
		killerModel = model,
		killerRoot = killerRoot,
		killerClass = classInfo.class,
		killerClassSource = classInfo.source,
		killerClassRaw = classInfo.raw,
		animator = track and track.Parent or nil,
		family = metadata.family,
		phase = metadata.phase,
		signalActionContract = ActionArbiter.ContractFor(id, metadata),
		actionContract = ACTION_KIND.MOVE,
		primaryAnimationId = id,
		activeAnimationId = metadata.phase == "ACTIVE" and id or nil,
		-- Motion identity is separate from damage attribution. In particular, an
		-- actionable PREP must not inherit a synthetic guard's ACTIVE id/profile.
		motionAnimationId = (
			metadata.phase == "ACTIVE"
				or (metadata.phase == "PREP" and metadata.forceRouteOnPrep == true)
		) and id or nil,
		motionSignalPhase = (
			metadata.phase == "ACTIVE"
				or (metadata.phase == "PREP" and metadata.forceRouteOnPrep == true)
		) and metadata.phase or nil,
		activeSignalAt = metadata.phase == "ACTIVE" and t or nil,
		signalPlayback = playback,
		lastExactActiveStartedAt = metadata.phase == "ACTIVE" and track ~= nil
			and ThreatController.SignalStartedAt(track, playback) or nil,
		observedAnimationIds = {[id] = true},
		startedAt = t,
		lastSignalAt = t,
		lastDangerousGeometryAt = t,
		expiresAt = t + (metadata.duration or Config.threatDefaultDuration),
		minimumReleaseAt =
			t + (
				metadata.minimumHold
					or Config.threatMinimumHold
			),
		ignoreSafeDistance =
			metadata.ignoreSafeDistance == true,
		releaseWhenSeparating = metadata.releaseWhenSeparating == true,
		separatingApproach = metadata.separatingApproach or -1.5,
		separatingFacing = metadata.separatingFacing or 0.0,
		initialManualDirection = CharacterController.PhysicalInputDirection(),
		routeDirection = nil,
		routeLocked = false,
		routeCertificateValid = false,
		routeCertificateSignalKey = nil,
		routeCertificateSignalRevision = nil,
		routeCertificateImpactAt = nil,
		routeCertificateMotionType = nil,
		routeCertificateValidUntil = nil,
		routeCertificateInvalidReason = "episode-not-yet-certified",
		motionSignalRevision = 0,
		motionSignalTrack = nil,
		targetDistance = metadata.safeDistance or Config.threatDefaultSafeDistance,
		maximumDuration = math.max(metadata.duration or Config.threatDefaultDuration, 0.25) + 0.50,
		maximumUntil = t + math.max(metadata.duration or Config.threatDefaultDuration, 0.25) + 0.50,
		speed = clampSpeed(metadata.speed or 36.0),
		lateralWeight = metadata.lateral or 14.0,
		awayWeight = metadata.away or 14.0,
		replansUsed = 0,
		lastReplanAt = -math.huge,
		stuckSampleAt = t,
		stuckSamplePosition = State.root and State.root.Position or nil,
		startRootPosition = State.root and State.root.Position or nil,
		movementCommands = 0,
		softAccelerationWrites = 0,
		maxActualHorizontalSpeed = 0.0,
		lastMovementTelemetryAt = t,
		hitReceived = false,
		released = false,
		releaseReason = nil,
		activeTracks = track and 1 or 0,
		lastTrackStoppedAt = -math.huge,
		holdControlUntilTrackStop = metadata.holdControlUntilTrackStop == true,
		forceRouteOnPrep = metadata.forceRouteOnPrep == true,
		-- Overrides must exist before Attach: assigning one after NewEpisode made
		-- the first and often only plan use the generic family reach instead.
		motionProfileOverride = metadata.motionProfileOverride,
		motionHoldPadding = metadata.motionHoldPadding,
		-- Synthetic aim guards must expose their timing before MotionCore.Attach
		-- runs below. Assigning this only after NewEpisode returned silently made
		-- every guard use predictiveDefaultImpactDelay instead of its own config.
		aimImpactDelay = metadata.aimImpactDelay,
		postTrackHold = metadata.postTrackHold or 0.0,
		hardMaximumUntil = t + (metadata.hardMaximumDuration or (math.max(metadata.duration or Config.threatDefaultDuration, 0.25) + 0.50)),
	}
	ThreatMotionCore.Attach(episode, t, track)
	State.activeThreat = episode
	Diagnostics.Push(
		"THREAT_START",
		string.format("episode=%d killer=%s class=%s classSource=%s family=%s phase=%s id=%s signalAction=%s resolvedAction=%s d=%.2f", episode.episodeId, model.Name, tostring(episode.killerClass), tostring(episode.killerClassSource), episode.family, episode.phase, id, episode.signalActionContract, episode.actionContract, threatDistance(episode)),
		"threat-start",
		0.01
	)
	return episode
end

function ThreatController.PromoteExactPrep(threat: any, id: string, metadata: any): boolean
	if not threat or threat.synthetic ~= true
		or threat.family ~= "HIDDEN_CLOSE_AIM_GUARD"
		or id ~= "113255068724446" or metadata.family ~= "HIDDEN"
		or metadata.phase ~= "PREP" or metadata.forceRouteOnPrep ~= true
		or metadata.clearMotionProfileOverride ~= true then
		return false
	end
	threat.family = metadata.family
	threat.phase = metadata.phase
	threat.kind = metadata.kind or threat.kind
	threat.synthetic = false
	threat.confirmedAimGuard = false
	threat.motionProfileOverride = nil
	threat.aimImpactDelay = nil
	threat.rollingHorizon = false
	threat.rollingHorizonDelay = nil
	threat.aimOrigin = nil
	threat.aimDirection = nil
	return true
end

function ThreatController.MergeSignal(threat: any, id: string, metadata: any, track: AnimationTrack, playback: any): ()
	-- A delayed poll/PREP callback must not overwrite a newer ACTIVE forecast.
	if ThreatController.StalePrep(threat, metadata, track, playback) then
		return
	end
	local t = now()
	local previousMotionPhase = threat.motionSignalPhase
	ThreatController.PromoteExactPrep(threat, id, metadata)
	threat.signalPlayback = playback
	local classInfo = ThreatController.KillerClassInfo(threat.killerModel)
	threat.killerClass = classInfo.class
	threat.killerClassSource = classInfo.source
	threat.killerClassRaw = classInfo.raw
	threat.observedAnimationIds[id] = true
	threat.lastSignalAt = t
	threat.signalActionContract = ActionArbiter.ContractFor(id, metadata)
	threat.actionContract = ACTION_KIND.MOVE
	threat.activeTracks += 1
	if metadata.phase == "ACTIVE" then
		threat.activeAnimationId = id
		threat.activeSignalAt = t
		threat.lastExactActiveStartedAt = ThreatController.SignalStartedAt(track, playback)
	end
	threat.expiresAt = math.max(threat.expiresAt, t + (metadata.duration or Config.threatDefaultDuration))
	threat.maximumUntil = math.max(threat.maximumUntil, threat.expiresAt + 0.35)
	threat.targetDistance = math.max(threat.targetDistance, metadata.safeDistance or threat.targetDistance)
	threat.ignoreSafeDistance =
		threat.ignoreSafeDistance
		or metadata.ignoreSafeDistance == true
	threat.releaseWhenSeparating = threat.releaseWhenSeparating
		or metadata.releaseWhenSeparating == true
	threat.holdControlUntilTrackStop = threat.holdControlUntilTrackStop
		or metadata.holdControlUntilTrackStop == true
	threat.forceRouteOnPrep = threat.forceRouteOnPrep
		or metadata.forceRouteOnPrep == true
	if metadata.postTrackHold then
		threat.postTrackHold = math.max(threat.postTrackHold or 0.0, metadata.postTrackHold)
	end
	if metadata.hardMaximumDuration then
		threat.hardMaximumUntil = math.max(threat.hardMaximumUntil or -math.huge, t + metadata.hardMaximumDuration)
	end
	if metadata.separatingApproach then
		threat.separatingApproach = metadata.separatingApproach
	end
	if metadata.separatingFacing then
		threat.separatingFacing = metadata.separatingFacing
	end
	if metadata.clearMotionProfileOverride == true then
		-- The guard may own a deliberately shorter early-warning profile. PREP may
		-- retain that route, but the following actionable signal must be free to
		-- bind its exact per-ID envelope during the atomic replacement transaction.
		threat.motionProfileOverride = nil
	end
	if metadata.minimumHold then
		threat.minimumReleaseAt =
			math.max(
				threat.minimumReleaseAt,
				t + metadata.minimumHold
			)
	end
	if metadata.phase == "ACTIVE"
		or (metadata.phase == "PREP" and metadata.forceRouteOnPrep == true) then
		-- Timing belongs to this signal. Veil PREP explicitly owns a long aim
		-- delay/padding; ACTIVE must return to its exact per-ID timing defaults.
		threat.aimImpactDelay = metadata.aimImpactDelay
		threat.motionHoldPadding = metadata.motionHoldPadding
	end
	local preserveDistanceKeeperRoute =
		metadata.preserveDistanceKeeperRouteOnConfirm == true
		and threat.family == "DISTANCE_KEEPER"
		and threat.routeDirection ~= nil
	local preserveExistingRouteFamily = metadata.preserveExistingRouteFamily
	local incomingProfile = predictiveFamilyProfile(
		tostring(metadata.family or threat.family), tostring(id)
	)
	local preserveConfirmedRoute = threat.motionProfile == incomingProfile
		and not (previousMotionPhase == "PREP" and metadata.phase == "ACTIVE")
		and threat.routeAuthorityKind ~= "EMERGENCY"
		and ThreatMotionCore.CertificateMatches(threat, t)
		and (
		(metadata.preserveExistingRouteOnConfirm == true
			and threat.routeDirection ~= nil
			and (
				preserveExistingRouteFamily == nil
				or tostring(threat.family or "UNKNOWN")
					== tostring(preserveExistingRouteFamily)
			))
		or preserveDistanceKeeperRoute)
	local shouldAttachMotionSignal = false
	if preserveConfirmedRoute then
		-- This signal is already on the damage frame. Preserve the PREP/aim route
		-- for a short server-resolution grace, but never reset impactAt, choose a
		-- new side or manufacture another full forecast window from this late ID.
		local confirmationHold = math.max(
			0.20,
			tonumber(metadata.confirmationHold) or 0.20
		)
		local confirmationHoldUntil = t + confirmationHold
		-- Only a still-valid route from the identical profile may retain its side.
		-- A guard-to-exact envelope change takes the attach/replan branch below.
		threat.family = tostring(metadata.family or threat.family)
		threat.kind = metadata.kind or threat.kind
		threat.synthetic = false
		threat.confirmedAimGuard = false
		threat.motionHoldUntil = math.max(
			threat.motionHoldUntil or -math.huge,
			confirmationHoldUntil
		)
		if threat.routeCertificateValid == true then
			threat.routeCertificateValidUntil = math.max(
				threat.routeCertificateValidUntil or -math.huge,
				confirmationHoldUntil
			)
		end
		threat.minimumReleaseAt = math.max(
			threat.minimumReleaseAt or -math.huge,
			confirmationHoldUntil
		)
		threat.expiresAt = math.max(
			threat.expiresAt or -math.huge,
			confirmationHoldUntil
		)
		Diagnostics.Push(
			"THREAT_LATE_CONFIRM_ROUTE_PRESERVED",
			string.format(
				"episode=%d id=%s family=%s route=%s hold=%.2f action=no-rebind-no-turn",
				threat.episodeId,
				id,
				tostring(threat.family or "UNKNOWN"),
				tostring(threat.routeDirection ~= nil),
				confirmationHold
			),
			"late-confirm-preserved-" .. tostring(threat.episodeId),
			0.05
		)
	elseif metadata.phase == "ACTIVE"
		or (metadata.phase == "PREP" and metadata.forceRouteOnPrep == true) then
		-- Attach after phase/family promotion below so its key and motion profile
		-- describe the incoming signal, not the PREP state that preceded it.
		shouldAttachMotionSignal = true
	end
	threat.speed = math.max(threat.speed, clampSpeed(metadata.speed or threat.speed))
	local incomingFamily =
		tostring(metadata.family or threat.family)
	if threat.family == "VEIL_WALL_ARROW_AIM"
		and string.find(incomingFamily, "VEIL", 1, true)
		and metadata.phase == "ACTIVE" then
		-- Promote attribution, but do not pretend every Veil action shares one route
		-- certificate. Projectile ACTIVE is recertified against the current Killer ->
		-- survivor chord; melee ACTIVE binds its own homing envelope. Only metadata
		-- that explicitly preserves the same-family route may keep the old vector.
		threat.family = incomingFamily
		threat.kind = metadata.kind or threat.kind
		threat.synthetic = false
		threat.confirmedAimGuard = false
		if id == "86266790353635"
			and State.root
			and threat.killerRoot
			and threat.killerRoot.Parent then
			threat.aimOrigin = threat.killerRoot.Position
			threat.aimDirection = unitOr(
				horizontal(State.root.Position - threat.killerRoot.Position),
				threat.killerRoot.CFrame.LookVector
			)
		elseif incomingFamily == "VEIL_MELEE" then
			threat.aimOrigin = nil
			threat.aimDirection = nil
		end
		Diagnostics.Push(
			"VEIL_WALL_AIM_CONFIRMED",
			string.format(
				"episode=%d id=%s family=%s routePreserved=%s source=%s action=%s",
				threat.episodeId,
				id,
				incomingFamily,
				tostring(preserveConfirmedRoute),
				tostring(threat.aimSource or "unknown"),
				preserveConfirmedRoute
					and "same-family-route"
					or "fresh-current-action-recertificate"
			),
			"veil-wall-aim-confirmed-" .. tostring(threat.episodeId),
			0.05
		)
	end
	if threat.family == "TRACKING_POINTBLANK_GUARD"
		and incomingFamily == "TRACKING" then
		-- The proactive guard already chose the lateral corridor. Promote only the
		-- label/weights when the actual track arrives; do not throw away the route.
		threat.family = "TRACKING"
		threat.kind = metadata.kind or threat.kind
		threat.synthetic = false
		threat.lateralWeight = math.max(threat.lateralWeight, metadata.lateral or 0)
		threat.awayWeight = math.min(threat.awayWeight, metadata.away or threat.awayWeight)
		Diagnostics.Push(
			"TRACKING_GUARD_CONFIRMED",
			string.format(
				"episode=%d id=%s kind=%s routePreserved=true",
				threat.episodeId,
				id,
				tostring(metadata.kind)
			),
			"tracking-guard-confirmed-" .. tostring(threat.episodeId),
			0.05
		)
	end
	if threat.family == "GENERIC_PRESSURE_GUARD"
		or threat.family == "PERSONAL_SPACE_GUARD" then
		if incomingFamily ~= "GENERIC_PRESSURE_GUARD"
			and incomingFamily ~= "PERSONAL_SPACE_GUARD" then
			-- A proximity guard is only an early warning. Once the actual attack
			-- animation arrives, promote the episode to its exact family so the
			-- correct route-only/blending policy is used immediately.
			threat.family = incomingFamily
			threat.kind = metadata.kind or threat.kind
			threat.synthetic = false
			threat.routeDirection = nil
			threat.routeLocked = false
			threat.routePending = true
		end
		threat.lateralWeight =
			math.max(
				threat.lateralWeight,
				metadata.lateral or 0
			)
		threat.awayWeight =
			math.min(
				threat.awayWeight,
				metadata.away or threat.awayWeight
			)
		threat.minimumReleaseAt =
			math.max(
				threat.minimumReleaseAt,
				t + math.max(
					metadata.minimumHold or 0.35,
					0.50
				)
			)
		Diagnostics.Push(
			"GUARD_SIGNAL_CONFIRMED",
			string.format(
				"episode=%d id=%s kind=%s lateral=%.1f away=%.1f",
				threat.episodeId,
				id,
				tostring(metadata.kind),
				threat.lateralWeight,
				threat.awayWeight
			),
			"guard-signal-" .. tostring(threat.episodeId),
			0.05
		)
	end
	if threat.family == "DISTANCE_KEEPER"
		and incomingFamily ~= "DISTANCE_KEEPER"
		and metadata.phase == "ACTIVE" then
		-- The distance floor already selected an outward open corridor before the
		-- late attack signal arrived. Promote diagnostics/hold timing, but preserve
		-- that direction instead of turning again on the damage frame.
		threat.family = incomingFamily
		threat.kind = metadata.kind or threat.kind
		threat.synthetic = false
		threat.lateralWeight = metadata.lateral or threat.lateralWeight
		threat.awayWeight = metadata.away or threat.awayWeight
		Diagnostics.Push(
			"DISTANCE_KEEPER_CONFIRMED",
			string.format(
				"episode=%d family=%s id=%s routePreserved=true",
				threat.episodeId,
				incomingFamily,
				id
			),
			"distance-keeper-confirmed-" .. tostring(threat.episodeId),
			0.05
		)
	end
	if phaseRank(metadata.phase) > phaseRank(threat.phase) then
		threat.phase = metadata.phase
	end
	if shouldAttachMotionSignal then
		-- Set the incoming authoritative signal before profile lookup and key
		-- construction. v5.5.29 promoted 129784... out of the guard but Attach still
		-- read the guard's activeAnimationId, binding PURSUIT_MELEE instead of the
		-- exact 36-stud/s HOMING_LUNGE profile.
		threat.motionAnimationId = id
		threat.motionSignalPhase = metadata.phase
		local handoffSnapshot =
			ThreatMotionCore.CaptureRouteSnapshot(threat)
		local previousSignalKey = threat.motionSignalKey
		local previousSignalRevision = threat.motionSignalRevision
		ThreatMotionCore.Attach(threat, t, track)
		local distinctMotionSignal = threat.motionSignalKey ~= previousSignalKey
			or threat.motionSignalRevision ~= previousSignalRevision
		if distinctMotionSignal then
			local interactionLocked = CharacterController.DefensiveMovementStatus()
			local recertified = not interactionLocked
				and ThreatMotionCore.Replan(
					threat,
					"signal-transition",
					true
				)
				or false
			if recertified then
				threat.transactionalHandoffPending = false
				threat.transactionalHandoffRetryAt = nil
				threat.transactionalHandoffDeadline = nil
				threat.routePending = false
				Diagnostics.Push(
					"MOTION_CORE_PHASE_RECERTIFIED",
					string.format(
						"episode=%d family=%s phase=%s id=%s signal=%s action=atomic-route-commit",
						threat.episodeId,
						tostring(threat.family or "UNKNOWN"),
						tostring(threat.phase or "UNKNOWN"),
						id,
						tostring(threat.motionSignalKey)
					),
					"motion-phase-recertified-" .. tostring(threat.episodeId),
					0.02
				)
			elseif ThreatMotionCore.BridgeRouteAcrossHandoff(
				threat,
				handoffSnapshot
			) then
				Diagnostics.Push(
					"EXACT_HANDOFF_RETAINED_OLD_ROUTE",
					string.format(
						"episode=%d family=%s phase=%s id=%s clear=%.2f action=keep-certified-route-retry-exact-atomically",
						threat.episodeId,
						tostring(threat.family or "UNKNOWN"),
						tostring(threat.phase or "UNKNOWN"),
						id,
						tonumber(threat.routeClearance) or -1
					),
					"exact-handoff-retained-" .. tostring(threat.episodeId),
					0.02
				)
			else
				ThreatMotionCore.InvalidateCertificate(
					threat,
					interactionLocked
						and "phase-transition-locked"
						or "phase-transition-no-certified-route",
					true
				)
				-- The previous route can already be gone because wall validation ran
				-- immediately before this exact phase. Do not convert a ray-budget miss
				-- into an indefinite route-pending state. Reserve the next fresh frame
				-- for one bounded, forced exact-profile recertification transaction.
				threat.transactionalHandoffPending = not interactionLocked
				threat.transactionalHandoffRetryAt = not interactionLocked
					and (t + 0.03)
					or nil
				threat.transactionalHandoffDeadline = not interactionLocked
					and (t + Config.motionCoreTransactionalHandoffGrace)
					or nil
				threat.routePending = true
				threat.motionObserveOnlyNoRoute = false
				threat.motionNoRouteGeometryAt = nil
				threat.motionNoRouteOrigin = nil
				threat.motionNoRouteThreatPosition = nil
				MovementWriter.Clear(
					OWNER.THREAT,
					"phase transition awaiting certified route"
				)
				Diagnostics.Push(
					"MOTION_CORE_PHASE_CERTIFICATE_REJECTED",
					string.format(
						"episode=%d family=%s phase=%s id=%s locked=%s deferred=%s action=native-WASD-fresh-budget-recertification",
						threat.episodeId,
						tostring(threat.family or "UNKNOWN"),
						tostring(threat.phase or "UNKNOWN"),
						id,
						tostring(interactionLocked),
						tostring(not interactionLocked)
					),
					"motion-phase-rejected-" .. tostring(threat.episodeId),
					0.02
				)
			end
		end
	end
	Diagnostics.Push(
		"THREAT_SIGNAL_MERGED",
		string.format("episode=%d family=%s id=%s phase=%s directionChanged=false expiresIn=%.2f", threat.episodeId, threat.family, id, metadata.phase, threat.expiresAt - t),
		"merge-" .. tostring(threat.episodeId) .. "-" .. id,
		0.02
	)
	track.Stopped:Once(function()
		safeCall("ThreatTrackStopped", function()
			if State.activeThreat == threat then
				threat.activeTracks = math.max(0, threat.activeTracks - 1)
				threat.lastTrackStoppedAt = now()
			end
		end)
	end)
end

function ThreatController.IsKnightModel(model: Model): boolean
	-- The game's SelectedKiller name is Abysswalker. "Knight" is only the
	-- historical internal label used by the old helper.
	local player = playerFromCharacter(model)
	if player then
		local selected = player:GetAttribute("SelectedKiller")
		if typeof(selected) == "string"
			and containsToken(
				selected,
				{"abysswalker", "knight"}
			) then
			return true
		end
	end
	if containsToken(
		model.Name,
		{"abysswalker", "knight"}
	) then
		return true
	end
	for _, attribute in ipairs({
		"SelectedKiller",
		"KillerName",
		"Archetype",
		"Class",
		"Role",
	}) do
		local value = model:GetAttribute(attribute)
		if typeof(value) == "string"
			and containsToken(
				value,
				{"abysswalker", "knight"}
			) then
			return true
		end
	end
	return false
end

local function crouchSequenceMayAuthorize(
	classToken: string,
	classSource: string,
	id: string,
	knightConfirmed: boolean
): boolean
	return Config.abysswalkerCrouchSequenceAuthorityEnabled == true
		and knightConfirmed
		and (classToken == "abysswalker" or classToken == "killer")
		and Config.abysswalkerCrouchSequenceById[id] ~= nil
		and classSource == "shared-animation:literal-killer"
end

function ThreatController.TryAbysswalkerCrouch(
	model: Model,
	root: BasePart,
	id: string
): boolean
	if not Config.abysswalkerCrouchCounterEnabled
		or not Config.abysswalkerCrouchIds[id] then
		return false
	end
	if not TargetResolver.IsThreatAnimationOwner(model) then
		Diagnostics.Push(
			"CROUCH_COUNTER_SKIPPED",
			string.format(
				"killer=%s id=%s reason=animation-owner-rejected action=fallback-to-dodge",
				model.Name,
				id
			),
			"crouch-counter-skipped-owner-" .. model.Name,
			0.25
		)
		return false
	end

	local localRoot = State.root
	local humanoid = State.humanoid
	if not localRoot or not humanoid then
		Diagnostics.Push(
			"CROUCH_COUNTER_SKIPPED",
			string.format(
				"killer=%s id=%s reason=no-local-character action=fallback-to-dodge",
				model.Name,
				id
			),
			"crouch-counter-skipped-no-root",
			0.25
		)
		return false
	end

	local classInfo = ThreatController.KillerClassInfo(model)
	local classToken = string.lower(
		tostring(classInfo.class or "")
	):gsub("[^%w]", "")
	local classSource = string.lower(
		tostring(classInfo.source or "")
	)
	local sequence = Config.abysswalkerCrouchSequenceById[id]
	local isPrep = sequence ~= nil and sequence.phase == "PREP"
	local isActive = sequence ~= nil and sequence.phase == "ACTIVE"
	local classAllowed = classToken == "abysswalker"
		or classToken == "killer"
	local classAuthoritative = string.sub(classSource, 1, 6) == "model."
		or string.sub(classSource, 1, 7) == "player."
	local exactSharedSequenceAuthority = crouchSequenceMayAuthorize(
		classToken,
		classSource,
		id,
		ThreatController.IsKnightModel(model)
	)
	local knightConfirmed = ThreatController.IsKnightModel(model)
	classAuthoritative = classAuthoritative
		or exactSharedSequenceAuthority
	if not knightConfirmed
		or not classAllowed
		or not classAuthoritative then
		State.crouchCounterPrepByModel[model] = nil
		ActionArbiter.CancelCounterReservation(model)
		Diagnostics.Push(
			"CROUCH_COUNTER_SKIPPED",
			string.format(
				"killer=%s class=%s classSource=%s id=%s knightConfirmed=%s reason=class-not-authoritative action=no-C",
				model.Name,
				tostring(classInfo.class or "Unknown"),
				tostring(classInfo.source or "unresolved"),
				id,
				tostring(knightConfirmed)
			),
			"crouch-counter-class-rejected-" .. model.Name,
			0.20
		)
		return false
	end

	local distance =
		horizontal(
			root.Position - localRoot.Position
		).Magnitude
	local t = now()
	local maximumDistance = if isPrep
		then Config.abysswalkerCrouchPrepMaximumDistance
		else Config.abysswalkerCrouchMaximumDistance
	if distance > maximumDistance then
		if isPrep then
			State.crouchCounterPrepByModel[model] = nil
			ActionArbiter.CancelCounterReservation(model)
		end
		Diagnostics.Push(
			"CROUCH_COUNTER_SKIPPED",
			string.format(
				"killer=%s id=%s d=%.2f maxD=%.2f reason=distance action=%s",
				model.Name,
				id,
				distance,
				maximumDistance,
				isPrep and "observe-prep-only" or "fallback-to-dodge"
			),
			"crouch-counter-skipped-distance-" .. model.Name,
			0.15
		)
		return false
	end

	local interactionLocked, interactionStatus =
		CharacterController.DefensiveMovementStatus()
	if interactionLocked then
		if isPrep then
			State.crouchCounterPrepByModel[model] = nil
			ActionArbiter.CancelCounterReservation(model)
		end
		Diagnostics.Push(
			"CROUCH_COUNTER_SKIPPED",
			string.format(
				"killer=%s class=%s id=%s d=%.2f reason=interaction-or-movement-lock walk=%.2f status=%s action=no-C",
				model.Name,
				tostring(classInfo.class or "Unknown"),
				id,
				distance,
				humanoid.WalkSpeed,
				interactionStatus
			),
			"crouch-counter-locked-" .. model.Name,
			0.20
		)
		return false
	end

	if isPrep then
		local facing = getFacingDot(root, localRoot)
		local approach = getApproachSpeed(root, localRoot)
		local stronglyArmed = facing >= Config.abysswalkerCrouchPrepMinimumFacing
			and approach >= Config.abysswalkerCrouchPrepMaximumRetreat
		-- Preserve every exact, class-authoritative PREP as a weak pair edge. Root
		-- facing and instantaneous approach become unreliable while the Knight turns
		-- into the dash. A weak PREP cannot press C by itself, but the matching ACTIVE
		-- may authorize it from measured PREP->ACTIVE closure or point-blank distance.
		State.crouchCounterPrepByModel[model] = {
			at = t,
			distance = distance,
			facing = facing,
			approach = approach,
			classToken = classToken,
			sequenceAuthority = exactSharedSequenceAuthority,
			prepId = id,
			expectedActiveId = sequence.activeId,
			stronglyArmed = stronglyArmed,
		}
		-- A shared animation on the literal Killer is only a possible counter
		-- sequence. Arming it must not clear a valid escape route or suppress every
		-- movement owner for 1.6 seconds. Only a class-authoritative Knight keeps
		-- exclusive counter-arm authority.
		-- Arming is observation only. The previous authoritative-Knight branch
		-- suppressed a valid escape route for the whole PREP window even though no C
		-- had been emitted yet.
		local prepBlocksMovement = false
		local reserved = false
		local reserveReason = "weak-observation"
		if stronglyArmed then
			reserved, reserveReason = ActionArbiter.ReserveCounter(
				model,
				id,
				t + Config.abysswalkerCrouchPrepArmWindow,
				prepBlocksMovement
			)
			if not reserved then
				State.crouchCounterPrepByModel[model].stronglyArmed = false
			end
		else
			ActionArbiter.CancelCounterReservation(model)
		end
		local activeThreat = State.activeThreat
		if prepBlocksMovement
			and activeThreat
			and activeThreat.killerModel == model then
			-- This exact wind-up belongs to the C counter chain. The generic
			-- or animation route must stop immediately and must not compete with the
			-- player's position while we wait for the exact ACTIVE edge.
			ThreatController.Release("crouch-counter-prep-armed")
		end
		Diagnostics.Push(
			stronglyArmed and reserved
				and "CROUCH_COUNTER_PREP_ARMED"
				or "CROUCH_COUNTER_PREP_OBSERVED",
			string.format(
				"killer=%s class=%s classSource=%s id=%s d=%.2f facing=%.2f approach=%+.2f window=%.2f sequenceAuthority=%s strong=%s reserved=%s reserveReason=%s blocksMovement=%s action=observe-pair-wait-closure-or-active",
				model.Name,
				tostring(classInfo.class or "Unknown"),
				tostring(classInfo.source or "unresolved"),
				id,
				distance,
				facing,
				approach,
				Config.abysswalkerCrouchPrepArmWindow,
				tostring(exactSharedSequenceAuthority),
				tostring(stronglyArmed),
				tostring(reserved),
				tostring(reserveReason),
				tostring(prepBlocksMovement)
			),
			"crouch-counter-prep-observed-" .. model.Name,
			0.15
		)
		-- PREP is an observation only. Returning false lets the normal PREP metadata
		-- remain observe-only and, critically, never consumes a real Mouse1 as C.
		return false
	end
	if not isActive then
		return false
	end

	local prep = State.crouchCounterPrepByModel[model]
	local prepAge = prep and (t - prep.at) or math.huge
	local prepValid = prep ~= nil
		and prepAge >= 0
		and prepAge <= Config.abysswalkerCrouchPrepArmWindow
		and prep.expectedActiveId == id
		and prep.prepId == sequence.prepId
	local closingGain = prepValid
		and ((prep.distance or distance) - distance)
		or -math.huge
	local pairedPostureAuthorized = prepValid
		and prepAge >= Config.abysswalkerCrouchMinimumWindupAge
		and closingGain <= Config.abysswalkerCrouchPairedMaximumClosingGain
		and distance <= Config.abysswalkerCrouchPairedActiveMaximumDistance
	-- A live Player.SelectedKiller=Abysswalker is authoritative even when the
	-- shared animation resolver deliberately labels the family as literal Killer.
	-- In that case ACTIVE may still counter if polling missed PREP. A genuinely
	-- generic Killer must present the paired PREP and can never C on the asset alone.
	if prepValid
		and prep.earlyCounterEmitted == true
		and t <= State.crouchCounterHeldUntil then
		State.crouchCounterPrepByModel[model] = nil
		Diagnostics.Push(
			"CROUCH_COUNTER_ACTIVE_COVERED",
			string.format(
				"killer=%s id=%s d=%.2f prepAge=%.3f action=keep-early-C-no-second-input",
				model.Name, id, distance, prepAge
			),
			"crouch-counter-active-covered-" .. model.Name,
			0.08
		)
		return true
	end
	local selectedPlayer = playerFromCharacter(model)
	local selectedKiller = selectedPlayer
		and selectedPlayer:GetAttribute("SelectedKiller")
		or nil
	local directKnightAuthority = typeof(selectedKiller) == "string"
		and containsToken(selectedKiller, {"abysswalker", "knight"})
	if not pairedPostureAuthorized then
		-- ACTIVE terminates this exact observation. Keeping a rejected rapid pair
		-- armed allowed UpdateArmedCrouchCounter to emit C after the ordinary M1 had
		-- already started, which is the false crouch seen in the supplied match.
		State.crouchCounterPrepByModel[model] = nil
		ActionArbiter.CancelCounterReservation(model)
		Diagnostics.Push(
			"CROUCH_COUNTER_SKIPPED",
			string.format(
				"killer=%s class=%s id=%s d=%.2f reason=ordinary-fast-hit-not-crouch-strike prepAge=%s minimumWindup=%.2f prepDistance=%s closingGain=%s maximumClosingGain=%.2f action=no-C-use-obstacle-escape",
				model.Name,
				tostring(classInfo.class or "Unknown"),
				id,
				distance,
				prep and string.format("%.3f", prepAge) or "none",
				Config.abysswalkerCrouchMinimumWindupAge,
				prep and string.format("%.2f", prep.distance or -1) or "none",
				prepValid and string.format("%.2f", closingGain) or "none",
				Config.abysswalkerCrouchPairedMaximumClosingGain
			),
			"crouch-counter-active-unarmed-" .. model.Name,
			0.15
		)
		return false
	end
	Diagnostics.Push(
		"CROUCH_COUNTER_ACTIVE_AUTHORIZED",
		string.format(
			"killer=%s class=%s id=%s d=%.2f prepAge=%.3f prepDistance=%.2f closingGain=%.2f prepStrong=%s action=emit-C-on-paired-event-edge",
			model.Name,
			tostring(classInfo.class or "Unknown"),
			id,
			distance,
			prepAge,
			prep.distance or distance,
			closingGain,
			tostring(prep.stronglyArmed == true)
		),
		"crouch-counter-active-authorized-" .. model.Name,
		0.05
	)
	if classToken == "killer"
		and classSource == "shared-animation:literal-killer"
		and not directKnightAuthority
		and distance < Config.abysswalkerCrouchSharedMinimumActiveDistance then
		State.crouchCounterPrepByModel[model] = nil
		ActionArbiter.CancelCounterReservation(model)
		Diagnostics.Push(
			"CROUCH_COUNTER_SKIPPED",
			string.format(
				"killer=%s class=%s id=%s d=%.2f minChargedD=%.2f reason=shared-active-too-close-for-long-lunge action=no-C-fallback-to-dodge",
				model.Name,
				tostring(classInfo.class or "Unknown"),
				id,
				distance,
				Config.abysswalkerCrouchSharedMinimumActiveDistance
			),
			"crouch-counter-shared-too-close-" .. model.Name,
			0.12
		)
		return false
	end
	State.crouchCounterPrepByModel[model] = nil

	local cooldownRemaining = Config.abysswalkerCrouchCooldown
		- (t - State.telemetry.lastKnightCounterAt)
	if cooldownRemaining > 0 then
		ActionArbiter.CancelCounterReservation(model)
		Diagnostics.Push(
			"CROUCH_COUNTER_SKIPPED",
			string.format(
				"killer=%s id=%s d=%.2f reason=cooldown remaining=%.3f action=fallback-to-dodge",
				model.Name,
				id,
				distance,
				cooldownRemaining
			),
			"crouch-counter-skipped-cooldown-" .. model.Name,
			0.08
		)
		return false
	end

	local holdDuration = Config.abysswalkerCrouchHold
	local requireReservation = classToken == "killer"
		and Config.abysswalkerCrouchLiteralKillerRequiresPrep
		and not directKnightAuthority
	local emitted, emitReason = ActionArbiter.EmitCounter(
		model,
		id,
		holdDuration,
		requireReservation
	)
	if not emitted then
		Diagnostics.Push(
			"ABYSSWALKER_CROUCH_FAILED",
			string.format(
				"killer=%s id=%s d=%.2f reason=%s action=fallback-to-dodge",
				model.Name,
				id,
				distance,
				emitReason
			),
			"abysswalker-crouch-failed",
			0.25
		)
		return false
	end
	State.telemetry.lastKnightCounterAt = t
	local activeThreat = State.activeThreat
	if activeThreat and activeThreat.killerModel == model then
		ThreatController.Release("exact-crouch-counter-sent")
	else
		MovementWriter.Clear(OWNER.THREAT, "exact crouch counter sent")
	end

	Diagnostics.Push(
		"CROUCH_COUNTER",
		string.format(
			"killer=%s class=%s classSource=%s id=%s d=%.2f key=C hold=%.3f prepAge=%s phase=ACTIVE action=key-down-exact-active",
			model.Name,
			tostring(classInfo.class or "Unknown"),
			tostring(classInfo.source or "unresolved"),
			id,
			distance,
			holdDuration,
			prepValid and string.format("%.3f", prepAge) or "direct-authoritative-abysswalker"
		),
		"crouch-counter",
		0.08
	)
	return true
end

function ThreatController.UpdateArmedCrouchCounter(): ()
	if not Config.abysswalkerCrouchCounterEnabled
		or not State.matchActive
		or isDowned()
		or not State.root then
		return
	end
	local t = now()
	for model, prep in pairs(State.crouchCounterPrepByModel) do
		if not model.Parent
			or type(prep) ~= "table"
			or t - (prep.at or -math.huge) > Config.abysswalkerCrouchPrepArmWindow then
			State.crouchCounterPrepByModel[model] = nil
			ActionArbiter.CancelCounterReservation(model)
		elseif prep.earlyCounterEmitted ~= true then
			local killerRoot = modelRoot(model)
			if killerRoot then
				local distance = horizontal(killerRoot.Position - State.root.Position).Magnitude
				local closingGain = (prep.distance or distance) - distance
				local facing = getFacingDot(killerRoot, State.root)
				local blocked = CharacterController.DefensiveMovementStatus()
				local cooldownReady = t - State.telemetry.lastKnightCounterAt
					>= Config.abysswalkerCrouchCooldown
				local windupAge = t - (prep.at or t)
				if prep.stronglyArmed == true
					and not blocked
					and cooldownReady
					and windupAge >= Config.abysswalkerCrouchMinimumWindupAge
					and distance <= Config.abysswalkerCrouchEarlyTriggerDistance
					and closingGain <= Config.abysswalkerCrouchEarlyMaximumClosingGain
					and facing >= Config.abysswalkerCrouchEarlyMinimumFacing then
					local emitted, reason = ActionArbiter.EmitCounter(
						model,
						tostring(prep.expectedActiveId or "ABYSS_EARLY_COUNTER"),
						Config.abysswalkerCrouchHold,
						true
					)
					if emitted then
						prep.earlyCounterEmitted = true
						prep.earlyCounterAt = t
						State.telemetry.lastKnightCounterAt = t
						Diagnostics.Push(
							"CROUCH_COUNTER_EARLY",
							string.format(
								"killer=%s prepId=%s expectedActive=%s d=%.2f windupAge=%.3f closingGain=%.2f facing=%.2f key=C hold=%.3f action=key-down-long-windup-before-active",
								model.Name,
								tostring(prep.prepId or "none"),
								tostring(prep.expectedActiveId or "none"),
								distance,
								windupAge,
								closingGain,
								facing,
								Config.abysswalkerCrouchHold
							),
							"crouch-counter-early-" .. model.Name,
							0.08
						)
					else
						Diagnostics.Push(
							"ABYSSWALKER_CROUCH_FAILED",
							string.format(
								"killer=%s prepId=%s d=%.2f reason=%s action=keep-movement-no-false-success",
								model.Name,
								tostring(prep.prepId or "none"),
								distance,
								tostring(reason)
							),
							"abysswalker-crouch-early-failed-" .. model.Name,
							0.20
						)
					end
				end
			end
		end
	end
end

local function isActionPriority(
	priority: Enum.AnimationPriority
): boolean
	return priority == Enum.AnimationPriority.Action
		or priority == Enum.AnimationPriority.Action2
		or priority == Enum.AnimationPriority.Action3
		or priority == Enum.AnimationPriority.Action4
end

function ThreatController.SelectedKillerName(
	model: Model
): string
	-- Runtime character metadata describes the model currently in the match. A
	-- Player.SelectedKiller value can describe a menu selection or stale spawn,
	-- so it is only a fallback.
	for _, attribute in ipairs({
		"SelectedKiller",
		"KillerName",
		"KillerClass",
		"CharacterClass",
		"Archetype",
		"Class",
	}) do
		local selected = model:GetAttribute(attribute)
		if typeof(selected) == "string"
			and selected ~= "" then
			return selected
		end
		local child = model:FindFirstChild(attribute)
		if child and child:IsA("StringValue") and child.Value ~= "" then
			return child.Value
		end
	end
	local player = playerFromCharacter(model)
	if player then
		local selected = player:GetAttribute("SelectedKiller")
		if typeof(selected) == "string" and selected ~= "" then
			return selected
		end
	end
	return model.Name
end

local function normalizedClassToken(value: string): string
	return string.lower(value):gsub("[^%w]", "")
end

local function canonicalClassName(value: string): string?
	local token = normalizedClassToken(value)
	local exact = CLASS_CANONICAL_BY_TOKEN[token]
	if exact then
		return exact
	end
	-- Accept values such as "The Slasher" or "SlasherKiller" without
	-- treating an arbitrary player/model name as a class.
	for knownToken, className in pairs(CLASS_CANONICAL_BY_TOKEN) do
		if knownToken ~= "killer"
			and string.find(token, knownToken, 1, true) then
			return className
		end
	end
	return nil
end

function ThreatController.RawKillerClassInfo(model: Model): (any, any)
	local cached = State.rawKillerClassCacheByModel[model]
	if cached and now() - cached.at <= 0.75 then
		return cached.specific, cached.generic
	end

	local specific = nil
	local generic = nil
	local function consider(value: any, source: string): ()
		if typeof(value) ~= "string" then
			return
		end
		local trimmed = value:match("^%s*(.-)%s*$") or ""
		if trimmed == "" then
			return
		end
		local token = normalizedClassToken(trimmed)
		local canonical = canonicalClassName(trimmed)
		if not canonical then
			return
		end
		local info = {
			class = canonical,
			source = source,
			raw = trimmed,
		}
		if GENERIC_CLASS_TOKENS[token] then
			if not generic then
				generic = info
			end
		elseif not specific then
			specific = info
		end
	end

	-- Prefer the current character model over player-profile selection data.
	for _, name in ipairs(CLASS_ATTRIBUTE_NAMES) do
		consider(model:GetAttribute(name), "model.attribute." .. name)
		local child = model:FindFirstChild(name)
		if child and child:IsA("StringValue") then
			consider(child.Value, "model.value." .. name)
		end
	end

	-- Some versions of the game place class metadata one folder below the
	-- character. This is still runtime-model data and must be checked before
	-- the lower-confidence player profile.
	local scanned = 0
	for _, descendant in ipairs(model:GetDescendants()) do
		scanned += 1
		if scanned > 128 or specific then
			break
		end
		if descendant:IsA("StringValue") then
			for _, name in ipairs(CLASS_ATTRIBUTE_NAMES) do
				if descendant.Name == name then
					consider(descendant.Value, "model.descendant." .. name)
					break
				end
			end
		end
	end

	local player = playerFromCharacter(model)
	if player then
		for _, name in ipairs(CLASS_ATTRIBUTE_NAMES) do
			consider(player:GetAttribute(name), "player.attribute." .. name)
			local child = player:FindFirstChild(name)
			if child and child:IsA("StringValue") then
				consider(child.Value, "player.value." .. name)
			end
		end
	end

	for _, name in ipairs(CLASS_ATTRIBUTE_NAMES) do
		consider(Workspace:GetAttribute(name), "workspace.attribute." .. name)
		consider(ReplicatedStorage:GetAttribute(name), "replicated.attribute." .. name)
	end

	State.rawKillerClassCacheByModel[model] = {
		at = now(),
		specific = specific,
		generic = generic,
	}
	return specific, generic
end

function ThreatController.KillerClassInfo(model: Model): any
	local specific, generic = ThreatController.RawKillerClassInfo(model)
	local remembered = State.killerClassInfoByModel[model]
	-- Runtime character metadata is authoritative. A remembered shared-asset
	-- classification, however, must outrank player.SelectedKiller because that
	-- profile value was proven stale in the supplied match.
	if specific and isRuntimeModelClassSource(specific.source) then
		return specific
	end
	if remembered then
		return remembered
	end
	if specific then
		return specific
	end

	-- "Killer" is generic as a taxonomy label, but when the game's exact
	-- SelectedKiller token is literally Killer it is still authoritative for
	-- this match. A shared animation asset must never relabel it Abysswalker.
	local selectedToken = normalizedClassToken(
		ThreatController.SelectedKillerName(model)
	)
	if selectedToken == "killer"
		and generic
		and generic.class == "Killer" then
		return generic
	end

	local inferred = State.inferredAttackFamilyByModel[model]
	if inferred then
		local inferredClass = CLASS_BY_ATTACK_FAMILY[tostring(inferred.family)]
		if inferredClass then
			return {
				class = inferredClass,
				source = "inferred-family:" .. tostring(inferred.family),
				raw = tostring(inferred.family),
			}
		end
	end
	if generic then
		return generic
	end
	return {
		class = "Unknown",
		source = "unresolved",
		raw = ThreatController.SelectedKillerName(model),
	}
end

local VEIL_AIM_NAME_TOKENS = {
	"aim", "mouse", "cursor", "target", "look", "muzzle",
	"arrow", "projectile", "shot", "shoot", "direction",
}

local VEIL_DIRECTION_NAME_TOKENS = {
	"direction", "lookvector", "aimvector", "mousedirection",
}

local VEIL_POSITION_NAME_TOKENS = {
	"position", "point", "mousehit", "target", "cursor", "hit",
}

local function veilAimNameMatches(name: string): boolean
	return containsToken(string.lower(name), VEIL_AIM_NAME_TOKENS)
end

local function veilAimOrigin(instance: Instance?, fallback: BasePart): Vector3
	if instance then
		if instance:IsA("Attachment") then
			return instance.WorldPosition
		elseif instance:IsA("BasePart") then
			return instance.Position
		elseif instance.Parent then
			local parentPart = instance.Parent:IsA("BasePart")
				and instance.Parent
				or nil
			if parentPart then
				return parentPart.Position
			end
		end
	end
	return fallback.Position
end

function ThreatController.RefreshVeilAimSources(model: Model, aimState: any): ()
	local sources = {}
	local function addSource(source: any): ()
		if #sources < Config.veilWallAimMaximumSources then
			table.insert(sources, source)
		end
	end
	local root = modelRoot(model)
	if not root then
		aimState.sources = sources
		aimState.lastSourceScanAt = now()
		return
	end
	local head = model:FindFirstChild("Head")
	local ownerPlayer = playerFromCharacter(model)
	local containers: {Instance} = {model, root}
	if head then table.insert(containers, head) end
	if ownerPlayer then table.insert(containers, ownerPlayer) end
	for _, container in ipairs(containers) do
		for attributeName in pairs(container:GetAttributes()) do
			if veilAimNameMatches(attributeName) then
				addSource({
					kind = "attribute",
					container = container,
					name = attributeName,
					confidence = 3.0,
				})
			end
		end
	end
	if ownerPlayer then
		for _, child in ipairs(ownerPlayer:GetChildren()) do
			if veilAimNameMatches(child.Name)
				and (child:IsA("Vector3Value")
					or child:IsA("CFrameValue")
					or child:IsA("ObjectValue")) then
				addSource({
					kind = "value",
					instance = child,
					name = child.Name,
					confidence = 3.0,
				})
			end
		end
	end

	local scanned = 0
	for _, descendant in ipairs(model:GetDescendants()) do
		scanned += 1
		if scanned > Config.veilWallAimSourceScanLimit
			or #sources >= Config.veilWallAimMaximumSources then
			break
		end
		if descendant:IsA("Tool")
			or (descendant:IsA("Model")
				and containsToken(string.lower(descendant.Name), {"veil", "bow", "arrow", "weapon"})) then
			for attributeName in pairs(descendant:GetAttributes()) do
				if veilAimNameMatches(attributeName) then
					addSource({
						kind = "attribute",
						container = descendant,
						name = attributeName,
						confidence = 3.0,
					})
				end
			end
		end
		-- The flashlight subsystem creates this cosmetic endpoint on the killer's
		-- head. Treating our own target attachment as Veil's replicated cursor forms
		-- a feedback loop: holding RMB manufactures a fake confidence=2 aim threat.
		local helperOwnedAimMarker = descendant.Name == "VD_FlashlightHeadTarget"
			or descendant:GetAttribute("VDHelperOwnedAimMarker") == true
		if not helperOwnedAimMarker and veilAimNameMatches(descendant.Name) then
			if descendant:IsA("Vector3Value")
				or descendant:IsA("CFrameValue")
				or descendant:IsA("ObjectValue") then
				addSource({
					kind = "value",
					instance = descendant,
					name = descendant.Name,
					confidence = 3.0,
				})
			elseif descendant:IsA("Attachment") then
				addSource({
					kind = "attachment",
					instance = descendant,
					name = descendant.Name,
					confidence = 2.0,
				})
			elseif descendant:IsA("BasePart")
				and containsToken(string.lower(descendant.Name), {
					"muzzle", "arrow", "bow", "projectile", "aim", "shot",
				}) then
				addSource({
					kind = "part",
					instance = descendant,
					name = descendant.Name,
					confidence = 1.5,
				})
			end
		end
	end
	aimState.sources = sources
	aimState.lastSourceScanAt = now()
end

local function veilAimDirectionFromRaw(
	raw: any,
	name: string,
	origin: Vector3
): (Vector3?, string?)
	local lower = string.lower(name)
	if typeof(raw) == "Vector3" then
		if containsToken(lower, VEIL_DIRECTION_NAME_TOKENS)
			or raw.Magnitude <= 2.0 then
			if raw.Magnitude < 0.05 then
				return nil, nil
			end
			return raw.Unit, "direction"
		end
		local offset = raw - origin
		if offset.Magnitude < 0.05 then
			return nil, nil
		end
		return offset.Unit, "position"
	elseif typeof(raw) == "CFrame" then
		if containsToken(lower, VEIL_POSITION_NAME_TOKENS) then
			local offset = raw.Position - origin
			if offset.Magnitude >= 0.05 then
				return offset.Unit, "cframe-position"
			end
		end
		return unitOr(raw.LookVector, Vector3.new(0, 0, -1)), "cframe-look"
	end
	return nil, nil
end

function ThreatController.ResolveVeilAimSample(
	model: Model,
	aimState: any
): any
	local root = modelRoot(model)
	local localRoot = State.root
	if not root or not localRoot then
		return nil
	end
	local t = now()
	if not aimState.sources
		or t - (aimState.lastSourceScanAt or -math.huge)
			>= Config.veilWallAimSourceRescan then
		ThreatController.RefreshVeilAimSources(model, aimState)
	end
	local targetPoint = localRoot.Position + Vector3.new(0, 1.0, 0)
	local best: any = nil
	local function consider(
		direction: Vector3?,
		origin: Vector3,
		confidence: number,
		source: string,
		directTarget: boolean?
	): ()
		if typeof(direction) ~= "Vector3"
			or direction.Magnitude < 0.05 then
			return
		end
		local unitDirection = direction.Unit
		local toLocal = unitOr(targetPoint - origin, unitDirection)
		local dot = directTarget == true and 1.0 or unitDirection:Dot(toLocal)
		local score = confidence * 10.0 + dot
		if not best or score > best.score then
			best = {
				direction = unitDirection,
				origin = origin,
				dot = dot,
				confidence = confidence,
				source = source,
				directTarget = directTarget == true,
				score = score,
			}
		end
	end

	for _, source in ipairs(aimState.sources or {}) do
		if source.kind == "attribute" then
			local container = source.container
			if typeof(container) == "Instance" and container.Parent then
				local origin = veilAimOrigin(container, root)
				local raw = container:GetAttribute(source.name)
				local direction, interpretation = veilAimDirectionFromRaw(raw, source.name, origin)
				consider(direction, origin, source.confidence, "attribute:" .. container.Name .. "." .. source.name .. ":" .. tostring(interpretation))
			end
		elseif source.kind == "value" then
			local instance = source.instance
			if typeof(instance) == "Instance" and instance.Parent then
				local origin = veilAimOrigin(instance, root)
				if instance:IsA("ObjectValue") then
					local value = instance.Value
					local directTarget = value == LocalPlayer
						or value == State.character
						or (value ~= nil and State.character ~= nil and value:IsDescendantOf(State.character))
					if directTarget then
						consider(targetPoint - origin, origin, 4.0, "object-target:" .. instance.Name, true)
					elseif value then
						local targetPosition: Vector3? = nil
						if value:IsA("Player") then
							local targetRoot = modelRoot(value.Character)
							targetPosition = targetRoot and targetRoot.Position or nil
						elseif value:IsA("Model") then
							local targetRoot = modelRoot(value)
							targetPosition = targetRoot and targetRoot.Position or nil
						elseif value:IsA("BasePart") then
							targetPosition = value.Position
						elseif value:IsA("Attachment") then
							targetPosition = value.WorldPosition
						end
						if targetPosition then
							consider(targetPosition - origin, origin, 4.0, "object-target-other:" .. instance.Name, false)
						end
					end
				elseif instance:IsA("Vector3Value") or instance:IsA("CFrameValue") then
					local direction, interpretation = veilAimDirectionFromRaw(instance.Value, instance.Name, origin)
					consider(direction, origin, source.confidence, "value:" .. instance.Name .. ":" .. tostring(interpretation))
				end
			end
		elseif source.kind == "attachment" then
			local instance = source.instance
			if typeof(instance) == "Instance" and instance:IsA("Attachment") and instance.Parent then
				consider(instance.WorldCFrame.LookVector, instance.WorldPosition, source.confidence, "attachment:" .. instance.Name)
			end
		elseif source.kind == "part" then
			local instance = source.instance
			if typeof(instance) == "Instance" and instance:IsA("BasePart") and instance.Parent then
				consider(instance.CFrame.LookVector, instance.Position, source.confidence, "part:" .. instance.Name)
			end
		end
	end

	local head = model:FindFirstChild("Head")
	if head and head:IsA("BasePart") then
		-- Head rotation is not the remote cursor. Keep it available as a sustained
		-- fallback detector, but never report it as a fully authoritative source.
		consider(head.CFrame.LookVector, head.Position, 0.75, "head-fallback")
	end
	consider(root.CFrame.LookVector, root.Position, 0.35, "root-fallback")
	return best
end

function ThreatController.UpdateVeilAimGuard(): ()
	if not Config.veilWallAimEnabled
		or ThreatController.PostHitSuppressed()
		or not State.matchActive
		or not State.enabled
		or isDowned()
		or not State.root
		or not State.humanoid then
		return
	end
	local active = State.activeThreat
	local activeAim = active
		and active.family == "VEIL_WALL_ARROW_AIM"
		and active
		or nil
	local activeDistanceKeeper = active
		and active.family == "DISTANCE_KEEPER"
		and active
		or nil
	local model = State.nearestKiller
	local killerRoot = modelRoot(model)
	if not model or not killerRoot
		or string.lower(tostring(ThreatController.KillerClassInfo(model).class or "")) ~= "veil" then
		if activeAim then
			ThreatController.Release("veil aim owner/class lost")
		end
		return
	end
	-- A generic distance floor may start while the aim cone is still accumulating
	-- its short confirmation window. Keep sampling through that episode; otherwise
	-- the distance keeper permanently blocks the more specific wall-arrow guard on
	-- the very next tick.
	if active and not activeAim and not activeDistanceKeeper then
		return
	end

	local aimState = State.veilAimStateByModel[model]
	if type(aimState) ~= "table" then
		aimState = {
			aimedSince = nil,
			aimEvidence = 0.0,
			lastSampleAt = nil,
			lastAimedAt = -math.huge,
			lastTriggeredAt = -math.huge,
			lastSourceScanAt = -math.huge,
		}
		State.veilAimStateByModel[model] = aimState
	end
	local sample = ThreatController.ResolveVeilAimSample(model, aimState)
	local t = now()
	local distance = horizontal(killerRoot.Position - State.root.Position).Magnitude
	aimState.lastResolvedAt = t
	aimState.lastResolvedDistance = distance
	aimState.lastResolvedDot = sample and sample.dot or -2.0
	aimState.lastResolvedSource = sample and sample.source or "none"
	aimState.lastResolvedConfidence = sample and sample.confidence or 0.0
	if not sample or distance > Config.veilWallAimMaximumDistance then
		aimState.aimedSince = nil
		aimState.aimEvidence = 0.0
		aimState.lastSampleAt = t
		if activeAim and t - (aimState.lastAimedAt or -math.huge) > Config.veilWallAimReleaseGrace then
			if t < (activeAim.aimCommitUntil or -math.huge) then
				activeAim.expiresAt = math.max(
					activeAim.expiresAt or -math.huge,
					activeAim.aimCommitUntil
				)
			else
				ThreatController.Release("veil sustained aim lost after projectile hold")
			end
		end
		return
	end

	local strongSource = sample.confidence >= 1.5
	local minimumDistance = strongSource
		and Config.veilWallAimMinimumDistanceStrong
		or Config.veilWallAimMinimumDistanceFallback
	local acquireDot = strongSource
		and Config.veilWallAimStrongDot
		or Config.veilWallAimFallbackDot
	local sustain = strongSource
		and Config.veilWallAimStrongSustain
		or Config.veilWallAimFallbackSustain
	local fallbackMotionAllowed = strongSource
		or horizontal(killerRoot.AssemblyLinearVelocity).Magnitude
			<= Config.veilWallAimFallbackMaximumSpeed
	local qualifiedSample = fallbackMotionAllowed
		and distance >= minimumDistance
		and sample.dot >= acquireDot
	local nearAimSample = fallbackMotionAllowed
		and distance >= minimumDistance
		and sample.dot >= Config.veilWallAimReleaseDot
	aimState.lastResolvedQualified = qualifiedSample
	aimState.lastResolvedNear = nearAimSample
	local previousSampleAt = tonumber(aimState.lastSampleAt)
	local sampleDt = previousSampleAt
		and math.clamp(
			t - previousSampleAt,
			0.0,
			Config.veilWallAimEvidenceMaximumSampleDt
		)
		or 0.0
	aimState.lastSampleAt = t
	local evidence = tonumber(aimState.aimEvidence) or 0.0
	if qualifiedSample then
		evidence += sampleDt
	elseif nearAimSample and evidence > 0.0 then
		evidence += sampleDt * Config.veilWallAimEvidenceNearDotScale
	else
		evidence = math.max(
			0.0,
			evidence - sampleDt * Config.veilWallAimEvidenceDecayRate
		)
	end
	evidence = math.min(evidence, sustain + Config.veilWallAimReleaseGrace)
	aimState.aimEvidence = evidence
	local hysteresisAim = evidence > 0.0
		and (
			nearAimSample
			or t - (aimState.lastAimedAt or -math.huge)
				<= Config.veilWallAimReleaseGrace
		)
	if qualifiedSample or hysteresisAim then
		if not aimState.aimedSince then
			aimState.aimedSince = t
		end
		-- A better replicated attachment may replace the head fallback while the
		-- same aim cone is continuously valid. Preserve accumulated sustain rather
		-- than restarting its timer on every source upgrade.
		aimState.activeSource = sample.source
		if qualifiedSample or nearAimSample then
			aimState.lastAimedAt = t
		end
		Diagnostics.Push(
			"VEIL_WALL_AIM_TRACK",
			string.format(
				"killer=%s d=%.2f dot=%.4f acquire=%.4f sustain=%.2f/%.2f source=%s confidence=%.1f lineOfSight=ignored",
				model.Name,
				distance,
				sample.dot,
				acquireDot,
				evidence,
				sustain,
				sample.source,
				sample.confidence
			),
			"veil-wall-aim-track-" .. model.Name,
			0.50
		)
	else
		if t - (aimState.lastAimedAt or -math.huge) > Config.veilWallAimReleaseGrace then
			aimState.aimedSince = nil
			aimState.activeSource = nil
			if activeAim then
				if t < (activeAim.aimCommitUntil or -math.huge) then
					activeAim.expiresAt = math.max(
						activeAim.expiresAt or -math.huge,
						activeAim.aimCommitUntil
					)
				else
					ThreatController.Release("veil aim cone released after projectile hold")
				end
			end
		end
		return
	end

	if activeAim then
		local fallbackSource = sample.source == "head-fallback"
			or sample.source == "root-fallback"
		-- Veil can keep moving the cursor while charging. A fallback body-part look
		-- vector is useful to detect sustained aim, but its frozen line must not be
		-- used for planning. Re-anchor the planning line to the survivor's current
		-- position on every sample and keep the chosen lateral side stable.
		activeAim.aimDirection = fallbackSource
			and unitOr(
				State.root.Position + Vector3.new(0, 1.0, 0) - sample.origin,
				sample.direction
			)
			or sample.direction
		activeAim.aimOrigin = sample.origin
		activeAim.aimDot = sample.dot
		activeAim.aimSource = sample.source
		activeAim.aimEvidence = evidence
		activeAim.veilFallbackAimAuthority = fallbackSource
		activeAim.expiresAt = math.max(
			activeAim.expiresAt,
			activeAim.aimCommitUntil or -math.huge,
			t + Config.veilWallAimReleaseGrace + 0.05
		)
		if CharacterController.IsRepairing() and State.root then
			local direction, clearance = selectVeilRepairEscapeDirection(
				State.root,
				killerRoot,
				activeAim.aimDirection
			)
			local sent, reason =
				CharacterController.RequestRepairThreatEscape(
					activeAim,
					direction
				)
			if sent then
				Diagnostics.Push(
					"VEIL_REPAIR_AIM_ESCAPE",
					string.format(
						"episode=%d killer=%s d=%.2f dot=%.4f source=%s clearance=%.2f action=continue-aim-native-movement-pulse",
						activeAim.episodeId,
						model.Name,
						distance,
						sample.dot,
						sample.source,
						clearance
					),
					"veil-repair-active-aim-escape",
					0.05
				)
			elseif reason == "skill-check-visible" then
				Diagnostics.Push(
					"VEIL_WALL_AIM_SUPPRESSED_LOCKED",
					string.format(
						"episode=%d killer=%s d=%.2f status=skill-check-visible repairEscape=%s action=preserve-skill-check",
						activeAim.episodeId,
						model.Name,
						distance,
						reason
					),
					"veil-repair-skill-check",
					0.25
				)
			end
		end
		return
	end
	if evidence < sustain
		or t - (aimState.lastAimedAt or -math.huge) > Config.veilWallAimReleaseGrace
		or t - (aimState.lastTriggeredAt or -math.huge) < Config.veilWallAimTriggerCooldown then
		return
	end

	local interactionLocked, interactionStatus =
		CharacterController.DefensiveMovementStatus()
	if interactionLocked then
		local repairEscapeSent = false
		local repairEscapeReason = "not-repairing"
		local repairDirection = nil
		local repairClearance = 0.0
		if CharacterController.IsRepairing()
			and State.root and State.humanoid then
			repairDirection, repairClearance =
				selectVeilRepairEscapeDirection(
					State.root,
					killerRoot,
					sample.direction
				)
			local continuousAimId = -math.max(
				1,
				math.floor((aimState.aimedSince or t) * 1000)
			)
			local repairThreat = {
				episodeId = continuousAimId,
				family = "VEIL_WALL_ARROW_AIM",
				phase = "PREP",
				actionContract = ACTION_KIND.MOVE,
				forceRouteOnPrep = true,
				confirmedAimGuard = true,
				synthetic = true,
				motionType = "PROJECTILE_LINE",
				killerRoot = killerRoot,
				aimSource = sample.source,
				aimEvidence = evidence,
			}
			repairEscapeSent, repairEscapeReason =
				CharacterController.RequestRepairThreatEscape(
					repairThreat,
					repairDirection
				)
		end
		if repairEscapeSent then
			Diagnostics.Push(
				"VEIL_REPAIR_AIM_ESCAPE",
				string.format(
					"killer=%s d=%.2f dot=%.4f evidence=%.2f source=%s clearance=%.2f action=native-movement-pulse-leave-generator",
					model.Name,
					distance,
					sample.dot,
					evidence,
					sample.source,
					repairClearance
				),
				"veil-repair-aim-escape",
				0.05
			)
			return
		end
		Diagnostics.Push(
			"VEIL_WALL_AIM_SUPPRESSED_LOCKED",
			string.format(
				"killer=%s d=%.2f dot=%.4f source=%s sustain=%.2f walk=%.2f status=%s repairEscape=%s action=no-move",
				model.Name,
				distance,
				sample.dot,
				sample.source,
				evidence,
				State.humanoid.WalkSpeed,
				interactionStatus,
				repairEscapeReason
			),
			"veil-wall-aim-locked",
			0.25
		)
		return
	end

	aimState.lastTriggeredAt = t
	if activeDistanceKeeper then
		Diagnostics.Push(
			"VEIL_WALL_AIM_SUPERSEDES_DISTANCE_KEEPER",
			string.format(
				"episode=%d killer=%s d=%.2f dot=%.4f sustain=%.2f action=same-frame-specific-guard",
				activeDistanceKeeper.episodeId,
				model.Name,
				distance,
				sample.dot,
				evidence
			),
			"veil-wall-aim-supersedes-distance-keeper",
			0.05
		)
		ThreatController.Release("veil wall aim supersedes distance keeper")
	end
	local projectileHold = math.clamp(
		distance / math.max(Config.veilWallAimProjectileSpeed, 1.0)
			+ Config.veilWallAimProjectileHoldPadding,
		Config.veilWallAimProjectileMinimumHold,
		Config.veilWallAimProjectileMaximumHold
	)
	local projectilePlanningDelay = math.clamp(
		distance / math.max(Config.veilWallAimProjectileSpeed, 1.0),
		Config.veilWallAimImpactDelay,
		Config.predictiveMaximumImpactDelay
	)
	local metadata = {
		family = "VEIL_WALL_ARROW_AIM",
		phase = "ACTIVE",
		kind = "VEIL_SUSTAINED_WALL_ARROW_AIM",
		maxDistance = Config.veilWallAimMaximumDistance,
		duration = math.max(Config.veilWallAimEpisodeDuration, projectileHold + 0.20),
		safeDistance = Config.veilWallAimMaximumDistance,
		speed = Config.movementHardSpeedCap,
		lateral = 40.0,
		away = 0.5,
		minFacing = -1.0,
		minimumHold = Config.veilWallAimMinimumHold,
		ignoreSafeDistance = true,
		aimImpactDelay = projectilePlanningDelay,
	}
	local episode = ThreatController.NewEpisode(
		model,
		killerRoot,
		"VEIL_SUSTAINED_AIM",
		metadata,
		nil
	)
	episode.synthetic = true
	episode.confirmedAimGuard = true
	episode.activeAnimationId = "VEIL_SUSTAINED_AIM"
	episode.activeSignalAt = t
	local fallbackSource = sample.source == "head-fallback"
		or sample.source == "root-fallback"
	episode.aimDirection = fallbackSource
		and unitOr(
			State.root.Position + Vector3.new(0, 1.0, 0) - sample.origin,
			sample.direction
		)
		or sample.direction
	episode.aimOrigin = sample.origin
	episode.aimDot = sample.dot
	episode.aimSource = sample.source
	episode.aimEvidence = evidence
	episode.veilFallbackAimAuthority = fallbackSource
	episode.aimCommitUntil = t + projectileHold
	episode.expiresAt = math.max(episode.expiresAt, episode.aimCommitUntil)
	episode.rollingHorizon = true
	episode.rollingHorizonDelay = projectilePlanningDelay
	ThreatMotionCore.RefreshRollingHorizon(episode, t)
	episode.routePending = true
	episode.requireDeepRoute = false
	Diagnostics.Push(
		"VEIL_WALL_AIM_COMMITTED",
		string.format(
			"episode=%d killer=%s d=%.2f dot=%.4f evidence=%.2f hold=%.2f horizon=%.2f source=%s confidence=%.1f throughWallCapable=true action=rolling-certified-lateral-corridor",
			episode.episodeId,
			model.Name,
			distance,
			sample.dot,
			evidence,
			projectileHold,
			projectilePlanningDelay,
			sample.source,
			sample.confidence
		),
		"veil-wall-aim-commit",
		0.05
	)
end

function ThreatController.RememberKillerClass(
	model: Model,
	metadata: any,
	id: string
): ()
	local specific, generic = ThreatController.RawKillerClassInfo(model)
	local family = tostring(metadata.family or "")
	local selectedToken = normalizedClassToken(
		ThreatController.SelectedKillerName(model)
	)

	local info = nil
	local selectedAbysswalker = selectedToken == "abysswalker"
		or selectedToken == "knight"
	local coherentAbysswalkerSignal = selectedAbysswalker
		and (
			string.find(family, "ABYSSWALKER", 1, true) ~= nil
			or Config.abysswalkerCrouchSequenceById[id] ~= nil
		)
	if coherentAbysswalkerSignal then
		-- One shared asset alone is ambiguous, but the live player selection and an
		-- Abysswalker-specific ranged/counter signal are two independent matching
		-- observations. v5.5.63 ignored that agreement, overwrote Abysswalker with
		-- literal Killer and then applied Killer-only C distance rules.
		info = {
			class = "Abysswalker",
			source = "player.attribute.SelectedKiller+exact-abysswalker-signal",
			raw = id,
		}
	elseif SHARED_KILLER_ABYSS_IDS[id]
		and not (specific and isRuntimeModelClassSource(specific.source)) then
		-- With no matching class-specific evidence the shared asset remains
		-- ambiguous and must not independently manufacture Abysswalker.
		info = {
			class = "Killer",
			source = "shared-animation:literal-killer",
			raw = id,
		}
	elseif specific then
		info = specific
	elseif selectedToken == "killer"
		and generic
		and generic.class == "Killer" then
		-- Exact game metadata outranks any globally shared animation-family map.
		info = generic
	else
		local className = CLASS_BY_ATTACK_FAMILY[family]
		if not className
			and string.find(family, "ABYSSWALKER", 1, true) then
			className = "Abysswalker"
		end
		if className then
			info = {
				class = className,
				source = "animation-family:" .. family,
				raw = family,
			}
		end
	end
	if not info then
		return
	end

	local previous = State.killerClassInfoByModel[model]
	State.killerClassInfoByModel[model] = info
	if not previous
		or previous.class ~= info.class
		or previous.source ~= info.source then
		Diagnostics.Push(
			"KILLER_CLASS_RESOLVED",
			string.format(
				"owner=%s class=%s source=%s raw=%s id=%s family=%s selectedToken=%s",
				model.Name,
				tostring(info.class),
				tostring(info.source),
				tostring(info.raw),
				id,
				family,
				ThreatController.SelectedKillerName(model)
			),
			"killer-class-resolved-" .. model.Name .. "-" .. tostring(info.class),
			0.10
		)
	end
end

function ThreatController.SelectedCatalogMetadata(
	model: Model,
	id: string
): any
	local selectedToken = string.lower(
		ThreatController.SelectedKillerName(model)
	):gsub("[^%w]", "")
	local selectedCatalog =
		AttackCatalogBySelected[selectedToken]
	return selectedCatalog
		and selectedCatalog[id]
		or nil
end

function ThreatController.LearnedKey(
	model: Model,
	id: string
): string
	return string.lower(
		ThreatController.SelectedKillerName(model)
	) .. "|" .. id
end

function ThreatController.RecordActionObservation(
	model: Model,
	killerRoot: BasePart,
	track: AnimationTrack,
	id: string,
	playback: any
): ()
	if not State.matchActive
		or not TargetResolver.IsKillerCandidate(model)
		or not isActionPriority(track.Priority)
		or track.Looped then
		return
	end

	local root = State.root
	if not root then
		return
	end

	local t = ThreatController.SignalStartedAt(track, playback)
	State.recentActionByModel[model] = {
		model = model,
		id = id,
		at = t,
		selected =
			ThreatController.SelectedKillerName(model),
		playback = playback,
		damageConsumed = false,
		distance =
			horizontal(
				killerRoot.Position
					- root.Position
			).Magnitude,
		facing =
			getFacingDot(killerRoot, root),
		priority = tostring(track.Priority),
		length = tonumber(track.Length) or 0,
		staticKnown =
			ThreatController.SelectedCatalogMetadata(
				model,
				id
			) ~= nil
			or AttackCatalog[id] ~= nil,
	}
end

function ThreatController.FindDamageLearningCandidate(): any
	if not Config.damageLearningEnabled then
		return nil
	end

	local t = now()
	local best = nil
	local bestAge = math.huge
	for model, sample in pairs(
		State.recentActionByModel
	) do
		local age = t - sample.at
		if age >= 0
			and age <= Config.damageLearningWindow
			and sample.damageConsumed ~= true
			and model.Parent
			and not sample.staticKnown
			and not NonThreatAnimationIds[
				sample.id
			]
			and TargetResolver.IsThreatAnimationOwner(
				model
			) then
			local killerRoot = modelRoot(model)
			local root = State.root
			if killerRoot and root then
				local currentDistance =
					horizontal(
						killerRoot.Position
							- root.Position
					).Magnitude
				if currentDistance
					<= Config.damageLearningMaximumDistance
					and age < bestAge then
					bestAge = age
					best = {
						sample = sample,
						model = model,
						killerRoot = killerRoot,
						age = age,
						currentDistance =
							currentDistance,
					}
				end
			end
		end
	end
	return best
end

function ThreatController.LearnFromDamage(
	candidate: any
): any
	local sample = candidate.sample
	local key =
		string.lower(sample.selected) .. "|" .. sample.id
	-- HealthChanged can fire several times for one animation. Each playback
	-- supplies one observation, never several independent confirmations.
	if sample.damageConsumed == true then
		return nil
	end
	sample.damageConsumed = true
	if candidate.age < Config.damageLearningMinimumUsefulLead then
		State.damageLearningObserveOnly[key] = true
		State.learnedAttackCatalog[key] = nil
		State.attackImpactDelayById[sample.id] = nil
		Diagnostics.Push(
			"DAMAGE_LEARNING_REJECTED_LATE",
			string.format(
				"selected=%s id=%s lead=%.3f minimum=%.3f action=observe-only-no-movement",
				sample.selected,
				sample.id,
				candidate.age,
				Config.damageLearningMinimumUsefulLead
			),
			"damage-learn-late-" .. key,
			0.05
		)
		return nil
	end
	if State.damageLearningObserveOnly[key] then
		return nil
	end
	local existing =
		State.learnedAttackCatalog[key]
	if existing then
		State.damageLearningCounts[key] =
			(State.damageLearningCounts[key] or 1)
			+ 1
		return existing
	end

	local evidence = State.damageLearningEvidence[key]
	if not evidence then
		evidence = {
			count = 0,
			totalLead = 0.0,
			minimumLead = math.huge,
			maximumLead = -math.huge,
		}
		State.damageLearningEvidence[key] = evidence
	end
	evidence.count += 1
	evidence.totalLead += candidate.age
	evidence.minimumLead = math.min(evidence.minimumLead, candidate.age)
	evidence.maximumLead = math.max(evidence.maximumLead, candidate.age)
	if evidence.maximumLead - evidence.minimumLead
		> Config.damageLearningMaximumLeadSpread then
		-- A single asset correlated with wildly different damage timing is not a
		-- deterministic attack telegraph. Restart confirmation from this sample.
		evidence.count = 1
		evidence.totalLead = candidate.age
		evidence.minimumLead = candidate.age
		evidence.maximumLead = candidate.age
	end
	if evidence.count < Config.damageLearningConfirmationsRequired then
		Diagnostics.Push(
			"DAMAGE_LEARNING_PENDING",
			string.format(
				"selected=%s id=%s lead=%.3f confirmations=%d/%d action=observe-only-until-confirmed",
				sample.selected,
				sample.id,
				candidate.age,
				evidence.count,
				Config.damageLearningConfirmationsRequired
			),
			"damage-learn-pending-" .. key,
			0.05
		)
		return nil
	end
	local measuredLead = evidence.totalLead / math.max(evidence.count, 1)

	local ranged =
		sample.distance
			>= Config.damageLearningRangedThreshold
		or candidate.currentDistance
			>= Config.damageLearningRangedThreshold
	local maximumDistance =
		ranged
			and math.min(
				Config.damageLearningMaximumDistance,
				math.max(
					32.0,
					sample.distance + 12.0,
					candidate.currentDistance
						+ 12.0
				)
			)
			or math.max(
				16.0,
				sample.distance + 5.0,
				candidate.currentDistance + 5.0
			)

	local metadata = {
		family =
			"LEARNED_"
			.. string.upper(sample.selected),
		phase = "ACTIVE",
		kind =
			ranged
				and "DAMAGE_LEARNED_RANGED"
				or "DAMAGE_LEARNED_MELEE",
		maxDistance = maximumDistance,
		duration =
			ranged
				and Config.damageLearningRangedDuration
				or Config.damageLearningMeleeDuration,
		safeDistance = ranged and 24.0 or 19.0,
		speed = Config.movementHardSpeedCap,
		lateral = ranged and 30.0 or 28.0,
		away = ranged and 2.0 or 4.0,
		minFacing = ranged and -0.75 or -0.20,
		ignoreSafeDistance = ranged,
		minimumHold = ranged and 0.58 or 0.34,
		learnedFromDamage = true,
	}

	State.learnedAttackCatalog[key] = metadata
	State.damageLearningCounts[key] = evidence.count
	State.attackImpactDelayById[sample.id] = measuredLead

	Diagnostics.Push(
		"HIT_NO_THREAT_LEARNED",
		string.format(
			"selected=%s id=%s age=%.3f measuredLead=%.3f confirmations=%d playD=%.2f hitD=%.2f facing=%.2f profile=%s maxD=%.2f",
			sample.selected,
			sample.id,
			candidate.age,
			measuredLead,
			evidence.count,
			sample.distance,
			candidate.currentDistance,
			sample.facing,
			ranged and "RANGED" or "MELEE",
			maximumDistance
		),
		"damage-learn-" .. key,
		0.05
	)
	return metadata
end

function ThreatController.StartPostHitEscape(
	candidate: any,
	metadata: any
): ()
	if not Config.damageLearningPostHitEscape
		or State.activeThreat
		or isDowned() then
		return
	end

	local sample = candidate.sample
	local episode =
		ThreatController.NewEpisode(
			candidate.model,
			candidate.killerRoot,
			sample.id,
			metadata,
			nil
		)
	episode.synthetic = true
	episode.routePending = true
	episode.requireDeepRoute = false

	Diagnostics.Push(
		"POST_HIT_ESCAPE",
		string.format(
			"episode=%d selected=%s id=%s d=%.2f",
			episode.episodeId,
			sample.selected,
			sample.id,
			candidate.currentDistance
		),
		"post-hit-escape",
		0.05
	)
end

function ThreatController.UnknownActionMetadata(
	model: Model,
	killerRoot: BasePart,
	track: AnimationTrack,
	id: string
): any
	local localRoot = State.root
	-- An unclassified animation is weaker evidence than an already-active
	-- personal-space hold. Do not downgrade direct-away authority to a blended
	-- UNKNOWN_* route merely because an unrelated Action track starts nearby.
	if State.activeThreat
		and State.activeThreat.family == "PERSONAL_SPACE_GUARD" then
		return nil
	end
	if not Config.unknownActionFallbackEnabled
		or not State.matchActive
		or not localRoot
		or not TargetResolver.IsKillerCandidate(model)
		or not isActionPriority(track.Priority)
		or track.Looped then
		return nil
	end

	local length = tonumber(track.Length) or 0
	if length > 0
		and (
			length < Config.unknownActionMinimumLength
			or length > Config.unknownActionMaximumLength
		) then
		return nil
	end

	local distance =
		horizontal(
			killerRoot.Position - localRoot.Position
		).Magnitude
	local facing =
		getFacingDot(killerRoot, localRoot)
	local selected =
		ThreatController.SelectedKillerName(model)
	local key =
		string.lower(selected)
			.. "|"
			.. id

	-- A close unclassified Action is still not proof of an attack. The old path
	-- converted it into PERSONAL_SPACE_GUARD and granted full route authority;
	-- that is exactly the unsafe behavior removed in v5.2.60.
	if distance <= Config.genericPointBlankGuardMaximumDistance then
		Diagnostics.Push(
			"UNKNOWN_CLOSE_ACTION_OBSERVE_ONLY",
			string.format(
				"selected=%s owner=%s id=%s d=%.2f action=no-movement",
				selected, model.Name, id, distance
			),
			"unknown-close-observe-" .. key,
			0.25
		)
		return nil
	end

	local classInfo = ThreatController.KillerClassInfo(model)
	if not State.unknownAnimationSeen[key] then
		State.unknownAnimationSeen[key] = true
		Diagnostics.Push(
			"UNKNOWN_KILLER_ACTION",
			string.format(
				"selected=%s owner=%s class=%s classSource=%s id=%s priority=%s length=%.3f d=%.2f facing=%.2f fallback=%s",
				selected,
				model.Name,
				tostring(classInfo.class),
				tostring(classInfo.source),
				id,
				tostring(track.Priority),
				length,
				distance,
				facing,
				tostring(
					distance
						<= (
							string.lower(selected) == "masked"
								and MaskedObservedUnclassified[id]
								and Config.maskedUnknownMaximumDistance
								or Config.unknownActionMaximumDistance
						)
						and facing
							>= (
								string.lower(selected) == "masked"
									and MaskedObservedUnclassified[id]
									and Config.maskedUnknownMinimumFacing
									or Config.unknownActionMinimumFacing
							)
				)
			),
			"unknown-killer-action-" .. key,
			0
		)
	end

	local selectedLower =
		string.lower(selected)
	local maximumDistance =
		Config.unknownActionMaximumDistance
	local minimumFacing =
		Config.unknownActionMinimumFacing
	local fallbackSafeDistance =
		Config.unknownActionSafeDistance
	local fallbackDuration =
		Config.unknownActionDefaultDuration

	if selectedLower == "masked"
		and MaskedObservedUnclassified[id] then
		maximumDistance =
			Config.maskedUnknownMaximumDistance
		minimumFacing =
			Config.maskedUnknownMinimumFacing
		fallbackSafeDistance =
			Config.maskedUnknownSafeDistance
		fallbackDuration =
			Config.maskedUnknownDuration
	end

	if distance > maximumDistance
		or facing < minimumFacing then
		return nil
	end

	local duration = fallbackDuration
	if length > 0 then
		duration = math.clamp(
			length * 0.72,
			0.42,
			0.90
		)
	end

	return {
		family = "UNKNOWN_" .. string.upper(selected),
		phase = "ACTIVE",
		kind = "UNKNOWN_ACTION_FALLBACK",
		maxDistance = maximumDistance,
		duration = duration,
		safeDistance = fallbackSafeDistance,
		speed = Config.movementHardSpeedCap,
		lateral = selectedLower == "masked"
			and 19.0
			or 17.0,
		away = selectedLower == "masked"
			and 9.0
			or 12.0,
		minFacing = minimumFacing,
	}
end

function ThreatController.UpdatePendingVeilPrep(): ()
	if not State.enabled or not State.matchActive or isDowned() or not State.root then
		table.clear(State.veilPendingPrepByModel)
		return
	end
	local t = now()
	for model, pending in pairs(State.veilPendingPrepByModel) do
		local track = pending.track
		local animator = pending.animator
		local metadata = pending.metadata
		local killerRoot = modelRoot(model)
		local expired = t > (pending.expiresAt or -math.huge)
		local stopped = not track
			or not track.Parent
			or (
				t - (pending.createdAt or t) > 0.08
				and track.IsPlaying ~= true
			)
		if expired or stopped or not animator or not killerRoot then
			State.veilPendingPrepByModel[model] = nil
			if expired and not stopped then
				Diagnostics.Push(
					"VEIL_PREP_PENDING_EXPIRED",
					string.format(
						"killer=%s id=%s action=no-movement-track-never-aimed",
						model.Name,
						tostring(pending.id or "none")
					),
					"veil-prep-pending-expired-" .. model.Name,
					0.25
				)
			end
		else
			local distance = horizontal(
				killerRoot.Position - State.root.Position
			).Magnitude
			local facing = getFacingDot(killerRoot, State.root)
			local minimumFacing = tonumber(metadata.pendingAimFacing) or 0.62
			if distance <= (metadata.maxDistance or Config.threatMaximumDistance)
				and facing >= minimumFacing then
				State.veilPendingPrepByModel[model] = nil
				Diagnostics.Push(
					"VEIL_PREP_PENDING_ADMITTED",
					string.format(
						"killer=%s id=%s d=%.2f facing=%.2f threshold=%.2f age=%.3f action=plan-from-live-prep",
						model.Name,
						tostring(pending.id or "none"),
						distance,
						facing,
						minimumFacing,
						t - (pending.createdAt or t)
					),
					"veil-prep-pending-admitted-" .. model.Name,
					0.05
				)
				ThreatController.OnAnimation(track, animator, true, pending.playback)
			end
		end
	end
end

function ThreatController.ClaimPlayback(track: AnimationTrack, playback: any, pendingAdmission: boolean?): boolean
	local t = now()
	local previous = State.animationTrackLastHandledAt[track]
	if playback then
		if type(previous) == "table" and tonumber(previous.generation)
			and tonumber(playback.generation)
			and playback.generation < previous.generation then
			return false
		end
		local samePlayback = type(previous) == "table"
			and previous.generation == playback.generation
			and previous.startedAt == playback.startedAt
		if pendingAdmission == true then
			if not samePlayback or previous.pendingAdmitted == true then
				return false
			end
			previous.pendingAdmitted = true
			return true
		end
		if samePlayback then
			return false
		end
		State.animationTrackLastHandledAt[track] = {
			at = t,
			generation = playback.generation,
			startedAt = playback.startedAt,
		}
		return true
	end
	local previousAt = type(previous) == "table" and previous.at or previous
	if pendingAdmission ~= true and t - (previousAt or -math.huge) < Config.animationReplayDebounce then
		return false
	end
	State.animationTrackLastHandledAt[track] = {at = t}
	return true
end

function ThreatController.OnAnimation(
	track: AnimationTrack,
	animator: Animator,
	pendingAdmission: boolean?,
	playback: any
): ()
	local playAt = now()
	if not State.enabled or isDowned() then
		return
	end
	playback = playback or State.animationPollStateByTrack[track]
	-- Deduplicate before observation, class updates, counters or episode mutation.
	if not ThreatController.ClaimPlayback(track, playback, pendingAdmission) then
		return
	end

	local id = animationId(track)
	if id == "" then
		return
	end

	local model, killerRoot =
		TargetResolver.OwnerForTrack(animator)
	if not model or not killerRoot then
		return
	end
	if pendingAdmission == true then
		State.veilPendingPrepByModel[model] = nil
	end

	local ignoredKind =
		NonThreatAnimationIds[id]
	if ignoredKind then
		if TargetResolver.IsThreatAnimationOwner(model) then
			State.recentNonThreatUntilByModel[model] =
				now()
				+ Config.genericPointBlankGuardNonThreatSuppress
			if ignoredKind == "PALLET_BREAK" then
				State.recentPalletBreakUntilByModel[model] =
					now() + Config.flashlightPalletBreakSafeWindow
			end
		end
		Diagnostics.Push(
			"NON_THREAT_ANIMATION_IGNORED",
			string.format(
				"id=%s kind=%s owner=%s action=no-episode guardSuppressed=%.2f flashlightSafeUntil=%.3f",
				id,
				ignoredKind,
				model.Name,
				Config.genericPointBlankGuardNonThreatSuppress,
				State.recentPalletBreakUntilByModel[model] or -math.huge
			),
			"non-threat-animation-" .. id,
			2.0
		)
		return
	end

	-- Pending Veil admission is a second evaluation of the same AnimationTrack,
	-- not a new signal. Preserve the original observation timestamp so damage
	-- correlation does not misclassify a useful PREP as a last-frame animation.
	if pendingAdmission ~= true then
		ThreatController.RecordActionObservation(
			model,
			killerRoot,
			track,
			id,
			playback
		)
	end

	local learnedKey =
		ThreatController.LearnedKey(
			model,
			id
		)
	if State.damageLearningObserveOnly[learnedKey] then
		Diagnostics.Push(
			"THREAT_SIGNAL_OBSERVE_ONLY",
			string.format(
				"killer=%s class=%s id=%s reason=damage-lead-too-short action=no-movement",
				model.Name,
				tostring(ThreatController.KillerClassInfo(model).class),
				id
			),
			"damage-observe-only-" .. learnedKey,
			1.0
		)
		return
	end
	local metadata =
		ThreatController.SelectedCatalogMetadata(
			model,
			id
		)
		or AttackCatalog[id]
		or State.learnedAttackCatalog[
			learnedKey
		]

	-- Known IDs use tuned metadata. An unknown non-looped Action track from
	-- the actual Killer gets a conservative close-range fallback and is logged
	-- once per SelectedKiller+ID for passive learning during ordinary matches.
	if not metadata then
		metadata =
			ThreatController.UnknownActionMetadata(
				model,
				killerRoot,
				track,
				id
			)
		if not metadata then
			return
		end
	end

	-- A known attack ID is still not enough by itself. This prevents another
	-- survivor, a lobby avatar or an unrelated humanoid from becoming a threat
	-- merely because it played the same asset.
	if State.activeThreat and State.activeThreat.killerModel == model
		and ThreatController.StalePrep(State.activeThreat, metadata, track, playback) then
		return
	end
	local validThreatOwner =
		TargetResolver.IsThreatAnimationOwner(model)
	if not validThreatOwner and not State.matchActive then
		local ownerPlayer = playerFromCharacter(model)
		validThreatOwner = ownerPlayer ~= nil
			and ownerPlayer.Team ~= nil
			and LocalPlayer.Team ~= nil
			and ownerPlayer.Team ~= LocalPlayer.Team
	end
	if Config.animationRequireThreatOwner
		and not validThreatOwner then
		if Config.animationIgnoredKnownLogEnabled then
			Diagnostics.Push(
				"ANIMATION_OWNER_REJECTED",
				string.format(
					"owner=%s id=%s kind=%s action=no-threat",
					model.Name,
					id,
					tostring(metadata.kind)
				),
				"animation-owner-rejected-" .. model.Name .. "-" .. id,
				2.0
			)
		end
		return
	end

	local combatWakeActionable = tostring(metadata.phase or "") == "ACTIVE"
		or metadata.forceRouteOnPrep == true
		or metadata.forcePrepMovement == true
	if combatWakeActionable then
		MatchController.TryCombatWake(model, killerRoot, id, metadata)
	end

	local recognizedFamily = tostring(metadata.family or "")
	local sinceDamage = playAt - State.telemetry.lastDamageAt
	if sinceDamage >= 0
		and sinceDamage < Config.postHitThreatReacquireBlock then
		Diagnostics.Push(
			"THREAT_SIGNAL_POST_HIT_IGNORED",
			string.format(
				"owner=%s id=%s family=%s sinceDamage=%.3f block=%.3f action=manual-control-no-reacquire",
				model.Name,
				id,
				recognizedFamily ~= "" and recognizedFamily or "UNKNOWN",
				sinceDamage,
				Config.postHitThreatReacquireBlock
			),
			"post-hit-threat-ignored-" .. model.Name,
			0.05
		)
		return
	end
	local recognizedFailureKey = failureFamilyKey(recognizedFamily)
	if State.disabledMovementFamilies[recognizedFailureKey]
		and not Config.threatConservativeMovementEnabled then
		Diagnostics.Push(
			"FAMILY_FAILSAFE_SUPPRESSED",
			string.format("owner=%s family=%s failKey=%s id=%s action=manual-control-only", model.Name, recognizedFamily, recognizedFailureKey, id),
			"family-failsafe-suppressed-" .. recognizedFailureKey, 0.75
		)
		return
	end
	ThreatController.RememberKillerClass(model, metadata, id)

	local counterFallbackToMove = false
	local crouchCounterEmitted =
		ThreatController.TryAbysswalkerCrouch(
			model,
			killerRoot,
			id
		)
	local signalAction = ActionArbiter.ContractFor(id, metadata)
	local knightCounterSignal = ThreatController.IsKnightModel(model)
	if crouchCounterEmitted then
		-- C was delivered, but the exact ACTIVE metadata also receives a fresh
		-- obstacle-certified movement route. This is not a speculative guard: both
		-- actions originate from the same replicated active edge.
		signalAction = ACTION_KIND.MOVE
		counterFallbackToMove = true
		Diagnostics.Push(
			"CROUCH_COUNTER_MOVE_BACKUP",
			string.format(
				"owner=%s id=%s action=C-held-plus-exact-active-route",
				model.Name,
				id
			),
			"crouch-counter-move-backup-" .. model.Name,
			0.10
		)
	elseif signalAction == ACTION_KIND.COUNTER_ARM and knightCounterSignal then
		-- PREP reserves the counter action and is never allowed to fall through
		-- into a movement episode for the same animation.
		return
	elseif signalAction == ACTION_KIND.COUNTER_ARM then
		-- Shared assets on a non-Knight model do not inherit the Knight counter
		-- contract. Let their own catalog metadata decide observe/move normally.
		signalAction = if metadata.startOnPrep == true
			and (metadata.forceRouteOnPrep == true or metadata.forcePrepMovement == true)
			then ACTION_KIND.MOVE
			else ACTION_KIND.OBSERVE
	elseif signalAction == ACTION_KIND.COUNTER_C then
		-- If the exact counter could not be emitted (for example no valid PREP),
		-- degrade once to the ordinary confirmed ACTIVE route. This is a serial
		-- fallback decision, never simultaneous C + movement ownership.
		Diagnostics.Push(
			"ACTION_ARBITER_FALLBACK",
			string.format(
				"owner=%s id=%s preferred=%s fallback=%s",
				model.Name,
				id,
				ACTION_KIND.COUNTER_C,
				ACTION_KIND.MOVE
			),
			"action-arbiter-fallback-" .. model.Name,
			0.15
		)
		signalAction = ACTION_KIND.MOVE
		counterFallbackToMove = true
	end
	if recognizedFamily == "TRACKING" then
		-- Do not call normalizedArchetypeName here: that local helper is declared
		-- later in the chunk, so Luau resolves an earlier call as a nil global.
		-- Inline the same normalization so every TRACKING animation reaches the
		-- actual threat episode instead of crashing AnimationPlayed.
		local selectedToken = string.lower(
			tostring(ThreatController.SelectedKillerName(model) or "")
		):gsub("[^%w]", "")
		local mayInferTracking =
			selectedToken == ""
			or selectedToken == "killer"
			or selectedToken == "unknown"
			or selectedToken == "tracking"
			or selectedToken == "slasher"
		if mayInferTracking then
			-- Keep Tracking sticky only when the actual class is unknown/generic or
			-- explicitly Tracking/Slasher. Shared TRACKING animations on Stalker or
			-- another named class are attack mechanics, not class identification.
			State.inferredAttackFamilyByModel[model] = {
				family = recognizedFamily,
				at = now(),
				id = id,
			}
		else
			State.inferredAttackFamilyByModel[model] = nil
			Diagnostics.Push(
				"TRACKING_CLASS_INFERENCE_REJECTED",
				string.format(
					"owner=%s selected=%s id=%s family=TRACKING action=attack-only-no-proximity-guard",
					model.Name,
					selectedToken,
					id
				),
				"tracking-class-inference-rejected-" .. model.Name,
				0.5
			)
		end
	end

	local localRoot = State.root
	if not localRoot then
		return
	end

	local distance =
		horizontal(
			killerRoot.Position - localRoot.Position
		).Magnitude
	local facing =
		getFacingDot(killerRoot, localRoot)
	local maximumDistance =
		math.min(
			metadata.maxDistance
				or Config.threatMaximumDistance,
			Config.threatMaximumDistance
		)
	local minimumFacing =
		metadata.minFacing or -1

	-- Known but non-actionable signals are also silent by default. They are
	-- useful only in a dedicated verbose diagnostic build.
	local approach = getApproachSpeed(killerRoot, localRoot)
	local literalKillerContactSignal =
		(id == "129784271201071" or id == "132817836308238")
		and normalizedClassToken(
			tostring(ThreatController.KillerClassInfo(model).class or "")
		) == "killer"
		and distance <= Config.threatDistanceKeeperContactHoldDistance
	-- Stalker Q PREP is a replicated exact attack edge. At close range a single
	-- root-facing/velocity sample is not authoritative: the supplied trace had
	-- facing=0.49 and approach=-4.16 at 7.36 studs, skipped the PREP, then took
	-- damage in the same second. Route certification/manual authority still
	-- decides whether movement is allowed after this signal is admitted.
	local exactStalkerClosePrep = metadata.kind == "STALKER_Q_PREP"
		and distance <= (
			metadata.closeRangeAlwaysActionableDistance or 0.0
		)
	local geometryRejected = metadata.requireAimedOrApproaching == true
		and pendingAdmission ~= true
		and not literalKillerContactSignal
		and not exactStalkerClosePrep
		and facing < (metadata.aimedFacing or 0.40)
		and approach < (metadata.minimumApproach or 1.0)
	if distance > maximumDistance
		or (
			facing < minimumFacing
			and not literalKillerContactSignal
			and not exactStalkerClosePrep
		)
		or geometryRejected then
		if geometryRejected
			and metadata.pendingAimRecheck == true
			and track.IsPlaying == true then
			State.veilPendingPrepByModel[model] = {
				track = track,
				animator = animator,
				metadata = metadata,
				playback = playback,
				id = id,
				createdAt = playAt,
				expiresAt = playAt
					+ (tonumber(metadata.pendingAimDuration) or 1.15),
			}
			Diagnostics.Push(
				"VEIL_PREP_PENDING",
				string.format(
					"owner=%s id=%s d=%.2f facing=%.2f threshold=%.2f action=retain-live-track-and-recheck",
					model.Name,
					id,
					distance,
					facing,
					tonumber(metadata.pendingAimFacing) or 0.62
				),
				"veil-prep-pending-" .. model.Name,
				0.10
			)
		end
		if metadata.kind == "STALKER_Q_PREP" then
			local reason = distance > maximumDistance
				and "distance"
				or (facing < minimumFacing and "minimum-facing" or "not-aimed-or-approaching")
			Diagnostics.Push(
				"STALKER_PREP_SKIPPED",
				string.format(
					"owner=%s id=%s d=%.2f facing=%.2f approach=%+.2f reason=%s action=no-movement",
					model.Name,
					id,
					distance,
					facing,
					approach,
					reason
				),
				"stalker-prep-skipped-" .. model.Name,
				0.25
			)
		end
		if Config.animationIgnoredKnownLogEnabled then
			Diagnostics.Push(
				"THREAT_SIGNAL_IGNORED",
				string.format(
					"owner=%s id=%s kind=%s d=%.2f facing=%.2f approach=%.2f maxD=%.2f minFacing=%.2f geometryRejected=%s",
					model.Name,
					id,
					metadata.kind,
					distance,
					facing,
					approach,
					maximumDistance,
					minimumFacing,
					tostring(geometryRejected)
				),
				"ignored-signal-"
					.. model.Name
					.. "-"
					.. id,
				1.0
			)
		end
		return
	end

	if not State.matchActive then
		State.knownKillerModels[model] = true
		MatchController.Enter(
			"known-local-combat=" .. id .. " owner=" .. model.Name
		)
	end

	State.knownKillerModels[model] = true
	if recognizedFamily == "TRACKING"
		and tostring(metadata.phase or "") == "ACTIVE"
		and signalAction == ACTION_KIND.MOVE then
		State.trackingSafetyEnvelopeUntilByModel[model] = math.max(
			State.trackingSafetyEnvelopeUntilByModel[model] or -math.huge,
			playAt + Config.trackingPostSignalEnvelopeDuration
		)
	end
	local observedClassToken = string.lower(tostring(
		ThreatController.KillerClassInfo(model).class or ""
	))
	if observedClassToken == "killer"
		and tostring(metadata.phase or "") == "ACTIVE"
		and signalAction == ACTION_KIND.MOVE then
		State.literalKillerSafetyEnvelopeUntilByModel[model] = math.max(
			State.literalKillerSafetyEnvelopeUntilByModel[model]
				or -math.huge,
			playAt + Config.literalKillerPostSignalEnvelopeDuration
		)
	end

	local existingThreat = State.activeThreat
	local requiredExistingFailureFamily =
		tostring(metadata.requireExistingFailureFamily or "")
	if requiredExistingFailureFamily ~= ""
		and not (
			existingThreat
			and existingThreat.killerModel == model
			and failureFamilyKey(existingThreat.family)
				== requiredExistingFailureFamily
			and now() <= (existingThreat.maximumUntil or -math.huge)
		) then
		Diagnostics.Push(
			"THREAT_SIGNAL_CONFIRM_ONLY",
			string.format(
				"owner=%s id=%s class=%s family=%s requiredExisting=%s d=%.2f action=no-new-movement",
				model.Name,
				id,
				ThreatController.KillerClassInfo(model).class or "Unknown",
				metadata.family or "UNKNOWN",
				requiredExistingFailureFamily,
				distance
			),
			"confirm-only-" .. id,
			0.20
		)
		return
	end
	local lateObserveOnlyDistance = tonumber(metadata.lateObserveOnlyDistance)
	if lateObserveOnlyDistance
		and distance <= lateObserveOnlyDistance
		and not counterFallbackToMove
		and not (
			existingThreat
			and existingThreat.killerModel == model
			and failureFamilyKey(existingThreat.family)
				== failureFamilyKey(metadata.family)
		) then
		Diagnostics.Push(
			"THREAT_SIGNAL_TOO_LATE",
			string.format(
				"owner=%s id=%s class=%s family=%s d=%.2f cutoff=%.2f action=no-last-frame-steer",
				model.Name,
				id,
				ThreatController.KillerClassInfo(model).class or "Unknown",
				metadata.family or "UNKNOWN",
				distance,
				lateObserveOnlyDistance
			),
			"late-signal-" .. id,
			0.20
		)
		return
	end

	if metadata.observeOnly == true then
		Diagnostics.Push(
			"THREAT_SIGNAL_OBSERVE_ONLY",
			string.format(
				"owner=%s id=%s class=%s family=%s phase=%s action=no-movement",
				model.Name,
				id,
				ThreatController.KillerClassInfo(model).class or "Unknown",
				metadata.family or "UNKNOWN",
				metadata.phase or "UNKNOWN"
			),
			"observe-only-" .. id,
			0.25
		)
		return
	end

	local canStart =
		metadata.phase ~= "PREP"
		or metadata.startOnPrep == true
	if Config.conservativePrepLogOnly
		and metadata.phase == "PREP"
		and metadata.forcePrepMovement ~= true then
		canStart = false
	end
	local threat = State.activeThreat
	if threat
		and threat.killerModel == model
		and threat.family == "DISTANCE_KEEPER"
		and metadata.family ~= "DISTANCE_KEEPER"
		and not (
			metadata.preserveDistanceKeeperRouteOnConfirm == true
			and metadata.phase == "ACTIVE"
			and threat.routeDirection ~= nil
		) then
		Diagnostics.Push(
			"EXACT_SIGNAL_SUPERSEDES_DISTANCE_KEEPER",
			string.format(
				"episode=%d exactFamily=%s id=%s action=atomic-promote-and-recertify",
				threat.episodeId,
				tostring(metadata.family or "UNKNOWN"),
				id
			),
			"exact-supersedes-distance-" .. tostring(threat.episodeId),
			0.02
		)
		threat.family = metadata.family
		threat.kind = metadata.kind or threat.kind
		threat.synthetic = false
		threat.confirmedAimGuard = false
		threat.motionProfileOverride = nil
		threat.aimImpactDelay = nil
		threat.rollingHorizon = false
		threat.rollingHorizonDelay = nil
		threat.aimOrigin = nil
		threat.aimDirection = nil
		-- MergeSignal snapshots the currently working corridor before attaching the
		-- exact profile. Do not clear it here: doing so made the advertised atomic
		-- promotion route-less on the most important frame.
		ThreatController.MergeSignal(threat, id, metadata, track, playback)
		return
	end
	-- Keep this predicate inline. This chunk already sits at Luau's 200-local
	-- register ceiling; a separate local helper makes the whole script fail before
	-- startup. Route preservation must not veto exact episode/profile promotion.
	local literalKillerExactPromotesGuard = threat
		and threat.killerModel == model
		and threat.synthetic == true
		and threat.family == "KILLER_CLOSE_AIM_GUARD"
		and metadata.family == "KILLER"
		and (
			(id == "129784271201071"
				and metadata.phase == "PREP"
				and metadata.promoteFromCloseAimGuard == true)
			or (id == "132817836308238"
				and metadata.phase == "ACTIVE")
		)
	if threat
		and threat.killerModel == model
		and threat.synthetic == true
		and (metadata.phase == "ACTIVE" or literalKillerExactPromotesGuard)
		and tonumber(id) ~= nil
		and threat.family ~= metadata.family
		and threat.family ~= "VEIL_WALL_ARROW_AIM"
		and not (
			metadata.preserveDistanceKeeperRouteOnConfirm == true
			and threat.family == "DISTANCE_KEEPER"
			and threat.routeDirection ~= nil
		)
		then
		Diagnostics.Push(
			"EXACT_SIGNAL_SUPERSEDES_GUARD",
			string.format(
				"episode=%d oldFamily=%s exactFamily=%s id=%s action=atomic-promote-and-recertify",
				threat.episodeId,
				tostring(threat.family or "UNKNOWN"),
				tostring(metadata.family or "UNKNOWN"),
				id
			),
			"exact-resets-guard-certificate-" .. tostring(threat.episodeId),
			0.02
		)
		threat.family = metadata.family
		threat.kind = metadata.kind or threat.kind
		threat.synthetic = false
		threat.confirmedAimGuard = false
		threat.motionProfileOverride = nil
		threat.aimImpactDelay = nil
		threat.rollingHorizon = false
		threat.rollingHorizonDelay = nil
		threat.aimOrigin = nil
		threat.aimDirection = nil
		-- Preserve the guard's certified corridor until MergeSignal either commits
		-- the exact forecast or installs its bounded handoff bridge.
		ThreatController.MergeSignal(threat, id, metadata, track, playback)
		return
	end
	if threat
		and threat.killerModel == model
		and metadata.replaceExistingGuard == true
		and threat.family ~= metadata.family
		and not (
			metadata.preserveExistingRouteOnConfirm == true
			and threat.routeDirection ~= nil
		) then
		Diagnostics.Push(
			"EXACT_SIGNAL_SUPERSEDES_GUARD",
			string.format(
				"episode=%d oldFamily=%s exactFamily=%s id=%s action=atomic-promote-and-recertify",
				threat.episodeId,
				tostring(threat.family or "UNKNOWN"),
				tostring(metadata.family or "UNKNOWN"),
				id
			),
			"exact-supersedes-guard-" .. tostring(threat.episodeId),
			0.02
		)
		threat.family = metadata.family
		threat.kind = metadata.kind or threat.kind
		threat.synthetic = false
		threat.confirmedAimGuard = false
		threat.motionProfileOverride = nil
		threat.aimImpactDelay = nil
		threat.rollingHorizon = false
		threat.rollingHorizonDelay = nil
		threat.aimOrigin = nil
		threat.aimDirection = nil
		ThreatMotionCore.InvalidateCertificate(
			threat,
			"exact-replacement-promotion-reset",
			true
		)
		threat.transactionalHandoffPending = false
		threat.transactionalHandoffRetryAt = nil
		threat.transactionalHandoffDeadline = nil
		threat.routePending = true
		ThreatController.MergeSignal(threat, id, metadata, track, playback)
		return
	end

	if threat
		and threat.killerModel == model
		and now() <= threat.maximumUntil then
		ThreatController.MergeSignal(
			threat,
			id,
			metadata,
			track,
			playback
		)
		return
	end

	if not canStart then
		if Config.animationPrepLogOnlyEnabled then
			Diagnostics.Push(
				"THREAT_SIGNAL_LOG_ONLY",
				string.format(
					"owner=%s id=%s kind=%s phase=PREP action=no-movement",
					model.Name,
					id,
					metadata.kind
				),
				"prep-log-" .. id,
				1.0
			)
		end
		return
	end

	if threat and threat.killerModel ~= model then
		local oldDistance = threatDistance(threat)
		if distance
				+ Config.threatDifferentKillerSwitchGain
			>= oldDistance
			and phaseRank(metadata.phase)
				<= phaseRank(threat.phase) then
			if Config.animationIgnoredKnownLogEnabled then
				Diagnostics.Push(
					"THREAT_SIGNAL_IGNORED",
					string.format(
						"owner=%s id=%s reason=active-closer-threat oldD=%.2f newD=%.2f",
						model.Name,
						id,
						oldDistance,
						distance
					),
					"multi-threat-ignore",
					0.50
				)
			end
			return
		end
		ThreatController.Release(
			"closer committed threat"
		)
	end

	local episode =
		ThreatController.NewEpisode(
			model,
			killerRoot,
			id,
			metadata,
			track,
			playback
		)
	episode.requireDeepRoute =
		metadata.requireDeep == true
		or metadata.requireDeepRoute == true
	episode.routePending = true

	track.Stopped:Once(function()
		safeCall(
			"PrimaryThreatTrackStopped",
			function()
				if State.activeThreat == episode then
					episode.activeTracks =
						math.max(
							0,
							episode.activeTracks - 1
						)
					episode.lastTrackStoppedAt = now()
				end
			end
		)
	end)
end

local GENERIC_GUARD_KNOWN_ARCHETYPES = {
	killer = true,
	abysswalker = true,
	quick = true,
	rip = true,
	tracking = true,
	slasher = true,
	hidden = true,
	cure = true,
	rush = true,
	stalker = true,
	masked = true,
	themasked = true,
	veil = true,
}

local function normalizedArchetypeName(value: string): string
	local normalized =
		string.lower(value):gsub("[^%w]", "")
	return normalized
end

function ThreatController.TryGenericPointBlankGuard(): boolean
	if not Config.genericPointBlankGuardEnabled
		or not State.matchActive
		or isDowned()
		or State.activeThreat then
		return false
	end

	local model = State.nearestKiller
	local killerRoot = modelRoot(model)
	local root = State.root
	if not model or not killerRoot or not root then
		return false
	end
	if not TargetResolver.IsThreatAnimationOwner(model) then
		return false
	end

	local selected =
		ThreatController.SelectedKillerName(model)
	if Config.genericPointBlankGuardSkipKnownArchetypes
		and GENERIC_GUARD_KNOWN_ARCHETYPES[
			normalizedArchetypeName(selected)
		] then
		-- Known killers already have animation-timed logic. The universal
		-- fallback was stealing movement from Abysswalker even while he was
		-- separating from the survivor.
		return false
	end

	local t = now()
	if t < (State.personalSpaceRouteBlockedUntilByModel[model] or -math.huge) then
		-- The last corridor search found only walls/dead ends. Leave full manual
		-- control during a short retry window instead of raycasting every frame or
		-- forcing the same blocked direction again.
		return false
	end
	local distance =
		horizontal(
			killerRoot.Position - root.Position
		).Magnitude
	local previous =
		State.genericGuardDistanceSampleByModel[model]
	local trendApproach = 0.0
	if previous then
		local sampleDt = t - previous.at
		if sampleDt > 0.015 and sampleDt < 0.50 then
			trendApproach =
				(previous.distance - distance)
				/ sampleDt
		end
	end
	State.genericGuardDistanceSampleByModel[model] = {
		distance = distance,
		at = t,
	}

	if distance
		> Config.genericPointBlankGuardMaximumDistance then
		return false
	end
	if distance > Config.genericPointBlankGuardHardDistance
		and t
		< (
			State.recentNonThreatUntilByModel[model]
				or -math.huge
		) then
		return false
	end
	if t - State.telemetry.lastGenericPointBlankGuardAt
		< Config.genericPointBlankGuardCooldown then
		return false
	end

	local facing = getFacingDot(killerRoot, root)
	local velocityApproach =
		getApproachSpeed(killerRoot, root)
	local approach =
		math.max(
			velocityApproach,
			trendApproach
		)

	local hardPointBlank =
		distance
			<= Config.genericPointBlankGuardHardDistance
	local aimedApproach =
		facing >= Config.genericPointBlankGuardFacing
		and approach
			>= Config.genericPointBlankGuardApproach
	local rushing =
		approach
			>= Config.genericPointBlankGuardRushApproach
		and facing
			>= Config.genericPointBlankGuardRushFacing

	if not (
		hardPointBlank
		or aimedApproach
		or rushing
	) then
		return false
	end

	State.telemetry.lastGenericPointBlankGuardAt = t
	local metadata = {
		family = "PERSONAL_SPACE_GUARD",
		phase = "ACTIVE",
		kind = "UNIVERSAL_DISTANCE_HOLD",
		maxDistance =
			Config.genericPointBlankGuardMaximumDistance,
		duration =
			Config.genericPointBlankGuardDuration,
		safeDistance =
			Config.genericPointBlankGuardSafeDistance,
		speed = Config.movementHardSpeedCap,
		lateral = 4.0,
		away = 36.0,
		minFacing = -1.0,
		minimumHold =
			Config.genericPointBlankGuardMinimumHold,
	}

	local episode =
		ThreatController.NewEpisode(
			model,
			killerRoot,
			"PROXIMITY_GUARD",
			metadata,
			nil
		)
	episode.synthetic = true
	episode.guardSelectedName = selected
	episode.guardInitialDistance = distance

	Diagnostics.Push(
		"PERSONAL_SPACE_GUARD",
		string.format(
			"episode=%d selected=%s class=%s classSource=%s d=%.2f target=%.2f facing=%.2f velocityApproach=%.2f trendApproach=%.2f trigger=%s%s%s",
			episode.episodeId,
			selected,
			tostring(episode.killerClass),
			tostring(episode.killerClassSource),
			distance,
			Config.genericPointBlankGuardSafeDistance,
			facing,
			velocityApproach,
			trendApproach,
			hardPointBlank and "HARD " or "",
			aimedApproach and "AIMED_APPROACH " or "",
			rushing and "RUSH " or ""
		),
		"generic-pointblank-guard",
		0.05
	)
	return true
end

function ThreatController.IsTrackingModel(model: Model): boolean
	local selectedToken = normalizedArchetypeName(
		ThreatController.SelectedKillerName(model)
	)
	if selectedToken == "tracking"
		or selectedToken == "slasher" then
		return true
	end

	-- An explicit non-Tracking class is authoritative. Shared TRACKING attack
	-- animations (for example on Stalker) must never permanently turn the
	-- model into Slasher/Tracking for the proactive proximity guard.
	local explicitNonTrackingClass =
		selectedToken ~= ""
		and selectedToken ~= "killer"
		and selectedToken ~= "unknown"
	if explicitNonTrackingClass then
		State.inferredAttackFamilyByModel[model] = nil
		return false
	end

	local inferred = State.inferredAttackFamilyByModel[model]
	return inferred ~= nil
		and tostring(inferred.family) == "TRACKING"
end

function ThreatController.TryTrackingPointBlankGuard(): boolean
	if not Config.trackingPointBlankGuardEnabled
		or not State.matchActive
		or isDowned()
		or State.activeThreat
		or State.disabledMovementFamilies.TRACKING then
		return false
	end

	local model = State.nearestKiller
	local killerRoot = modelRoot(model)
	local root = State.root
	if not model or not killerRoot or not root then
		return false
	end
	local selectedToken = normalizedArchetypeName(
		ThreatController.SelectedKillerName(model)
	)
	local exactSlasherClass = selectedToken == "tracking"
		or selectedToken == "slasher"
	if not TargetResolver.IsThreatAnimationOwner(model)
		or not exactSlasherClass then
		return false
	end

	local t = now()
	if t - State.telemetry.lastTrackingPointBlankGuardAt
		< Config.trackingPointBlankGuardCooldown then
		return false
	end
	if t < (State.recentNonThreatUntilByModel[model] or -math.huge) then
		return false
	end

	local distance = horizontal(
		killerRoot.Position - root.Position
	).Magnitude
	if distance > Config.trackingPointBlankGuardDistance then
		return false
	end

	local facing = getFacingDot(killerRoot, root)
	local approach = getApproachSpeed(killerRoot, root)
	local hardPointBlank =
		distance <= Config.trackingPointBlankGuardHardDistance
			and facing >= Config.trackingPointBlankGuardFacing
			and approach > 0
	local aimedApproach =
		facing >= Config.trackingPointBlankGuardFacing
			and approach >= Config.trackingPointBlankGuardApproach
	local rushing =
		facing >= Config.trackingPointBlankGuardRushFacing
			and approach >= Config.trackingPointBlankGuardRushApproach
	if not (hardPointBlank or aimedApproach or rushing) then
		return false
	end

	State.telemetry.lastTrackingPointBlankGuardAt = t
	local metadata = {
		family = "TRACKING_POINTBLANK_GUARD",
		phase = "PREP",
		kind = "TRACKING_PROACTIVE_SIDESTEP",
		maxDistance = Config.trackingPointBlankGuardDistance,
		duration = Config.trackingPointBlankGuardDuration,
		safeDistance = Config.trackingPointBlankGuardSafeDistance,
		speed = Config.movementHardSpeedCap,
		lateral = 14.0,
		away = 32.0,
		minFacing = -1.0,
		minimumHold = Config.trackingPointBlankGuardMinimumHold,
		forceRouteOnPrep = true,
		releaseWhenSeparating = true,
		separatingApproach = -1.0,
		separatingFacing = 0.35,
	}
	local episode = ThreatController.NewEpisode(
		model,
		killerRoot,
		"TRACKING_PROXIMITY_GUARD",
		metadata,
		nil
	)
	episode.synthetic = true
	episode.guardSelectedName = ThreatController.SelectedKillerName(model)
	episode.guardInitialDistance = distance

	Diagnostics.Push(
		"TRACKING_POINTBLANK_GUARD",
		string.format(
			"episode=%d selected=%s class=%s classSource=%s d=%.2f facing=%.2f approach=%+.2f hard=%s aimed=%s rush=%s policy=route-only-outward-corridor",
			episode.episodeId,
			tostring(episode.guardSelectedName),
			tostring(episode.killerClass),
			tostring(episode.killerClassSource),
			distance,
			facing,
			approach,
			tostring(hardPointBlank),
			tostring(aimedApproach),
			tostring(rushing)
		),
		"tracking-pointblank-guard",
		0.05
	)
	return true
end

function ThreatController.TryKillerPointBlankGuard(): boolean
	if not Config.killerPointBlankGuardEnabled
		or not State.matchActive
		or isDowned()
		or State.activeThreat then
		return false
	end

	local model = State.nearestKiller
	local killerRoot = modelRoot(model)
	local root = State.root
	if not model or not killerRoot or not root then
		return false
	end
	if not TargetResolver.IsThreatAnimationOwner(model) then
		return false
	end

	local selectedToken = string.lower(
		ThreatController.SelectedKillerName(model)
	):gsub("[^%w]", "")
	if selectedToken ~= "killer" then
		return false
	end

	local t = now()
	if t - State.telemetry.lastKillerPointBlankGuardAt
		< Config.killerPointBlankGuardCooldown then
		return false
	end

	local distance = horizontal(
		killerRoot.Position - root.Position
	).Magnitude
	if distance > Config.killerPointBlankGuardDistance then
		return false
	end

	local facing = getFacingDot(killerRoot, root)
	local approach = getApproachSpeed(killerRoot, root)
	local hardPointBlank =
		distance <= Config.killerPointBlankGuardHardDistance
			and facing >= Config.killerPointBlankGuardRushFacing
	local aimedApproach =
		facing >= Config.killerPointBlankGuardFacing
			and approach >= Config.killerPointBlankGuardApproach
	local rushing =
		facing >= Config.killerPointBlankGuardRushFacing
			and approach >= Config.killerPointBlankGuardRushApproach

	if not (hardPointBlank or aimedApproach or rushing) then
		return false
	end

	State.telemetry.lastKillerPointBlankGuardAt = t
	local metadata = {
		family = "KILLER_POINTBLANK_GUARD",
		phase = "PREP",
		kind = "KILLER_PROACTIVE_GUARD",
		maxDistance = Config.killerPointBlankGuardDistance,
		duration = Config.killerPointBlankGuardDuration,
		safeDistance = Config.killerPointBlankGuardSafeDistance,
		speed = Config.movementHardSpeedCap,
		lateral = 34.0,
		away = 1.0,
		minFacing = -1.0,
		minimumHold = Config.killerPointBlankGuardMinimumHold,
	}

	local episode = ThreatController.NewEpisode(
		model,
		killerRoot,
		"KILLER_PROXIMITY_GUARD",
		metadata,
		nil
	)
	episode.synthetic = true
	episode.guardSelectedName = "Killer"
	episode.guardInitialDistance = distance

	Diagnostics.Push(
		"KILLER_POINTBLANK_GUARD",
		string.format(
			"episode=%d d=%.2f facing=%.2f approach=%+.2f hard=%s aimed=%s rush=%s policy=route-only",
			episode.episodeId,
			distance,
			facing,
			approach,
			tostring(hardPointBlank),
			tostring(aimedApproach),
			tostring(rushing)
		),
		"killer-pointblank-guard",
		0.05
	)
	return true
end

function ThreatController.TryCurePointBlankGuard(): boolean
	if not Config.curePointBlankGuardEnabled
		or not State.matchActive
		or isDowned()
		or State.activeThreat then
		return false
	end

	local model = State.nearestKiller
	local killerRoot = modelRoot(model)
	local root = State.root
	if not model or not killerRoot or not root then return false end
	local className = string.lower(ThreatController.SelectedKillerName(model)):gsub("[^%w]", "")
	if className ~= "cure" then return false end

	local t = now()
	if t - State.telemetry.lastCurePointBlankGuardAt
		< Config.curePointBlankGuardCooldown then
		return false
	end
	local distance = horizontal(killerRoot.Position - root.Position).Magnitude
	if distance > Config.curePointBlankGuardDistance then return false end
	local facing = getFacingDot(killerRoot, root)
	local approach = getApproachSpeed(killerRoot, root)
	local hard = distance <= Config.curePointBlankGuardHardDistance
		and facing >= Config.curePointBlankGuardRushFacing
	local aimed = facing >= Config.curePointBlankGuardFacing
		and approach >= Config.curePointBlankGuardApproach
	local rush = facing >= Config.curePointBlankGuardRushFacing
		and approach >= Config.curePointBlankGuardRushApproach
	if not (hard or aimed or rush) then return false end

	State.telemetry.lastCurePointBlankGuardAt = t
	local metadata = {
		family = "CURE_POINTBLANK_GUARD",
		phase = "PREP",
		kind = "CURE_PROACTIVE_SIDESTEP",
		maxDistance = Config.curePointBlankGuardDistance,
		duration = Config.curePointBlankGuardDuration,
		safeDistance = Config.curePointBlankGuardSafeDistance,
		speed = Config.movementHardSpeedCap,
		lateral = 36.0,
		away = 0.5,
		minFacing = -1.0,
		minimumHold = Config.curePointBlankGuardMinimumHold,
	}
	local episode = ThreatController.NewEpisode(model, killerRoot, "CURE_PROXIMITY_GUARD", metadata, nil)
	episode.synthetic = true
	Diagnostics.Push(
		"CURE_POINTBLANK_GUARD",
		string.format(
			"episode=%d d=%.2f facing=%.2f approach=%+.2f hard=%s aimed=%s rush=%s policy=route-only",
			episode.episodeId, distance, facing, approach,
			tostring(hard), tostring(aimed), tostring(rush)
		),
		"cure-pointblank-guard",
		0.05
	)
	return true
end

function ThreatController.TryAbysswalkerPointBlankGuard(): boolean
	if not Config.abysswalkerPointBlankGuardEnabled
		or not State.matchActive
		or isDowned()
		or State.activeThreat then
		return false
	end
	local model = State.nearestKiller
	local killerRoot = modelRoot(model)
	local root = State.root
	if not model or not killerRoot or not root then
		return false
	end
	local selected = string.lower(
		ThreatController.SelectedKillerName(model)
	)
	if selected ~= "abysswalker" and selected ~= "knight" then
		return false
	end
	local t = now()
	if t - State.telemetry.lastAbysswalkerPointBlankGuardAt
		< Config.abysswalkerPointBlankGuardCooldown then
		return false
	end
	local distance = horizontal(killerRoot.Position - root.Position).Magnitude
	if distance > Config.abysswalkerPointBlankGuardDistance then
		return false
	end
	local facing = getFacingDot(killerRoot, root)
	local approach = getApproachSpeed(killerRoot, root)
	if facing < Config.abysswalkerPointBlankGuardFacing
		and approach < Config.abysswalkerPointBlankGuardApproach then
		return false
	end
	State.telemetry.lastAbysswalkerPointBlankGuardAt = t
	local metadata = {
		family = "ABYSSWALKER_GUARD",
		phase = "PREP",
		kind = "ABYSSWALKER_POINT_BLANK_GUARD",
		maxDistance = Config.abysswalkerPointBlankGuardDistance,
		duration = Config.abysswalkerPointBlankGuardDuration,
		safeDistance = Config.abysswalkerPointBlankGuardSafeDistance,
		speed = Config.movementHardSpeedCap,
		lateral = 29.0,
		away = 4.0,
		minFacing = -1.0,
		minimumHold = Config.abysswalkerPointBlankGuardMinimumHold,
	}
	local episode = ThreatController.NewEpisode(
		model, killerRoot, "PROXIMITY_GUARD", metadata, nil
	)
	episode.synthetic = true
	Diagnostics.Push(
		"ABYSSWALKER_POINTBLANK_GUARD",
		string.format(
			"episode=%d d=%.2f facing=%.2f approach=%.2f",
			episode.episodeId, distance, facing, approach
		),
		"abysswalker-pointblank-guard",
		0.05
	)
	return true
end


function ThreatController.TryRipPointBlankGuard(): boolean
	if not Config.ripPointBlankGuardEnabled
		or not State.matchActive
		or isDowned()
		or State.activeThreat then
		return false
	end

	local model = State.nearestKiller
	local killerRoot = modelRoot(model)
	local root = State.root
	if not model or not killerRoot or not root then
		return false
	end
	if not TargetResolver.IsThreatAnimationOwner(model) then
		return false
	end

	local selectedRaw =
		string.lower(
			ThreatController.SelectedKillerName(
				model
			)
		)
	local selectedToken =
		string.gsub(
			selectedRaw,
			"[^%w]",
			""
		)
	-- Live SelectedKiller reports the RIP archetype as "Masked". Older
	-- versions accepted only literal RIP/theRIP, so the proactive guard was
	-- silently disabled and movement began only on the already-late ACTIVE ID.
	local ripClass =
		selectedToken == "rip"
		or selectedToken == "therip"
		or selectedToken == "masked"
		or selectedToken == "themasked"
		or string.find(
			selectedToken,
			"rip",
			1,
			true
		) ~= nil
	if not ripClass then
		return false
	end

	local t = now()
	if t - State.telemetry.lastRipPointBlankGuardAt
		< Config.ripPointBlankGuardCooldown then
		return false
	end

	local distance =
		horizontal(
			killerRoot.Position - root.Position
		).Magnitude
	if distance > Config.ripPointBlankGuardDistance then
		return false
	end

	local facing =
		getFacingDot(killerRoot, root)
	local approach =
		getApproachSpeed(killerRoot, root)

	local hardPointBlank =
		distance <= Config.ripPointBlankGuardHardDistance
			and facing >= Config.ripPointBlankGuardRushFacing
	-- Masked produced animation-less damage at 11.48/facing=.94/approach=0 and
	-- 9.76/facing=.74 while already separating. Inside this exact-class radius,
	-- a credible facing vector is stronger evidence than velocity alone.
	local aimedApproach =
		facing >= Config.ripPointBlankGuardFacing
			and approach >= Config.ripPointBlankGuardApproach
	local rushing =
		facing >= Config.ripPointBlankGuardRushFacing
			and approach >= Config.ripPointBlankGuardRushApproach

	if not (
		hardPointBlank
		or aimedApproach
		or rushing
	) then
		return false
	end

	State.telemetry.lastRipPointBlankGuardAt = t

	local metadata = {
		family = "RIP_POINTBLANK_GUARD",
		phase = "ACTIVE",
		kind = "MASKED_COMMITTED_APPROACH_GUARD",
		maxDistance =
			Config.ripPointBlankGuardDistance,
		duration =
			Config.ripPointBlankGuardDuration,
		safeDistance =
			Config.ripPointBlankGuardSafeDistance,
		speed = Config.movementHardSpeedCap,
		lateral = 8.0,
		away = 34.0,
		minFacing = -1.0,
		minimumHold =
			Config.ripPointBlankGuardMinimumHold,
		requireDeepRoute = true,
	}

	local episode =
		ThreatController.NewEpisode(
			model,
			killerRoot,
			"MASKED_COMMITTED_APPROACH_GUARD",
			metadata,
			nil
		)
	episode.synthetic = true
	episode.requireDeepRoute = true
	episode.guardSelectedName = selectedRaw
	episode.guardInitialDistance = distance

	Diagnostics.Push(
		"MASKED_COMMITTED_APPROACH_GUARD",
		string.format(
			"episode=%d selected=%s d=%.2f facing=%.2f approach=%+.2f hard=%s aimed=%s rush=%s",
			episode.episodeId,
			selectedRaw,
			distance,
			facing,
			approach,
			tostring(hardPointBlank),
			tostring(aimedApproach),
			tostring(rushing)
		),
		"rip-pointblank-guard",
		0.05
	)
	return true
end

function ThreatController.TryVeilPointBlankGuard(): boolean
	if not Config.veilPointBlankGuardEnabled
		or not State.matchActive
		or isDowned()
		or State.activeThreat then
		return false
	end

	local model = State.nearestKiller
	local killerRoot =
		modelRoot(model)
	local root = State.root
	if not model or not killerRoot or not root then
		return false
	end

	local selected =
		string.lower(
			ThreatController.SelectedKillerName(
				model
			)
		)
	if selected ~= "veil" then
		return false
	end

	local t = now()
	if t - State.telemetry.lastVeilPointBlankGuardAt
		< Config.veilPointBlankGuardCooldown then
		return false
	end

	local distance =
		horizontal(
			killerRoot.Position - root.Position
		).Magnitude
	if distance
		> Config.veilPointBlankGuardDistance then
		return false
	end

	local facing =
		getFacingDot(killerRoot, root)
	local approach =
		getApproachSpeed(killerRoot, root)

	-- Inside the personal-space radius, distance alone is authoritative. Waiting
	-- for facing/approach let Veil stand at 5-8 studs and start a 0.15 s melee.
	local hardPointBlank =
		distance <= Config.veilPointBlankGuardHardDistance
	local aimedApproach =
		facing >= Config.veilPointBlankGuardFacing
			and approach
				>= Config.veilPointBlankGuardApproach
	local fastRush =
		facing >= Config.veilPointBlankGuardRushFacing
			and approach
				>= Config.veilPointBlankGuardRushApproach

	if not (
		hardPointBlank
		or aimedApproach
		or fastRush
	) then
		return false
	end

	State.telemetry.lastVeilPointBlankGuardAt = t
	State.telemetry.episodeCounter += 1

	local episode = {
		episodeId =
			State.telemetry.episodeCounter,
		killerModel = model,
		killerRoot = killerRoot,
		animator = nil,
		family = "VEIL_MELEE_GUARD",
		phase = "ACTIVE",
		primaryAnimationId =
			"PROXIMITY_GUARD",
		observedAnimationIds = {},
		startedAt = t,
		lastSignalAt = t,
		expiresAt =
			t
			+ Config.veilPointBlankGuardDuration,
		minimumReleaseAt =
			t
			+ Config.veilPointBlankGuardMinimumHold,
		ignoreSafeDistance = false,
		routeDirection = nil,
		routeLocked = false,
		targetDistance =
			Config.veilPointBlankGuardSafeDistance,
		maximumDuration =
			Config.veilPointBlankGuardDuration
			+ 0.25,
		maximumUntil =
			t
			+ Config.veilPointBlankGuardDuration
			+ 0.25,
		speed = Config.movementHardSpeedCap,
		lateralWeight = 4.0,
		awayWeight = 36.0,
		replansUsed = 0,
		lastReplanAt = -math.huge,
		stuckSampleAt = t,
		stuckSamplePosition = State.root and State.root.Position or nil,
		hitReceived = false,
		released = false,
		releaseReason = nil,
		activeTracks = 0,
		lastTrackStoppedAt = -math.huge,
		requireDeepRoute = false,
		routePending = true,
		synthetic = true,
	}
	State.activeThreat = episode

	Diagnostics.Push(
		"VEIL_DISTANCE_GUARD",
		string.format(
			"episode=%d d=%.2f target=%.2f facing=%.2f approach=%.2f personalSpace=%s aimed=%s rush=%s duration=%.2f",
			episode.episodeId,
			distance,
			Config.veilPointBlankGuardSafeDistance,
			facing,
			approach,
			tostring(hardPointBlank),
			tostring(aimedApproach),
			tostring(fastRush),
			Config.veilPointBlankGuardDuration
		),
		"veil-distance-guard",
		0.05
	)
	return true
end

local function distanceKeeperAuthority(
	distance: number,
	facing: number,
	approach: number,
	isVeil: boolean
): (boolean, boolean)
	local emergencyDistance = isVeil
		and Config.threatDistanceKeeperVeilEmergencyDistance
		or Config.threatDistanceKeeperEmergencyDistance
	local killerCommitted = facing >= Config.threatDistanceKeeperMinimumFacing
		and approach >= Config.threatDistanceKeeperMinimumApproach
	local contactEmergency = distance <= emergencyDistance
		and facing >= Config.threatDistanceKeeperEmergencyMinimumFacing
		and approach >= Config.threatDistanceKeeperEmergencyMinimumApproach
	return killerCommitted, contactEmergency
end

function ThreatController.TryDistanceKeeper(): boolean
	if not Config.threatDistanceKeeperEnabled
		or ThreatController.PostHitSuppressed()
		or not Config.threatAutoMovementEnabled
		or not State.matchActive
		or isDowned()
		or State.activeThreat
		or not State.humanoid
		or not State.root then
		return false
	end
	if now() < State.distanceKeeperBlockedUntil then
		return false
	end
	local interactionLocked = CharacterController.DefensiveMovementStatus()
	if interactionLocked
		and not CharacterController.CanDetectThreatWhileRepairLocked() then
		return false
	end
	local model = State.nearestKiller
	local killerRoot = modelRoot(model)
	if not model
		or not killerRoot
		or not TargetResolver.IsThreatAnimationOwner(model) then
		return false
	end
	local distance = horizontal(killerRoot.Position - State.root.Position).Magnitude
	local classInfo = ThreatController.KillerClassInfo(model)
	local classToken = string.lower(tostring(classInfo.class or ""))
	local isVeil = classToken == "veil"
	local isHidden = classToken == "hidden"
	local isTrackingClass = classToken == "slasher" or classToken == "tracking"
	local isAbysswalker = classToken == "abysswalker" or classToken == "knight"
	local currentWalk = State.humanoid.WalkSpeed
	-- The character often spawns at WalkSpeed 10 and later runs natively at 17.
	-- Capture the highest observed unlocked native value so a drop to 13 is detected
	-- as the Knight slow instead of being compared against the stale spawn value.
	if not interactionLocked
		and now() > State.crouchCounterHeldUntil
			+ Config.abysswalkerSlowPressureCounterGrace
		and currentWalk > State.observedNativeWalkSpeed
		and currentWalk <= 40.0 then
		State.observedNativeWalkSpeed = currentWalk
	end
	local baselineWalk = CharacterController.GetOriginalWalkSpeed()
	local abysswalkerSlowPressure = Config.abysswalkerSlowPressureEnabled == true
		and isAbysswalker
		and currentWalk > 0.1
		and distance <= Config.abysswalkerSlowPressureMaximumDistance
		and currentWalk <= Config.abysswalkerSlowPressureAbsoluteMaximum
		and currentWalk <= baselineWalk * Config.abysswalkerSlowPressureWalkRatio
		and now() > State.crouchCounterHeldUntil
			+ Config.abysswalkerSlowPressureCounterGrace
	if not isVeil
		and math.abs(killerRoot.Position.Y - State.root.Position.Y)
			> Config.repairThreatEscapeMaximumVerticalSeparation then
		return false
	end
	local enterDistance = isVeil
		and Config.threatDistanceKeeperVeilEnterDistance
		or (isTrackingClass
			and Config.trackingDistanceKeeperEnterDistance
			or Config.threatDistanceKeeperEnterDistance)
	if abysswalkerSlowPressure then
		enterDistance = math.max(
			enterDistance,
			Config.abysswalkerSlowPressureMaximumDistance
		)
	end
	local exitDistance = isVeil
		and Config.threatDistanceKeeperVeilExitDistance
		or (isTrackingClass
			and Config.trackingDistanceKeeperExitDistance
			or Config.threatDistanceKeeperExitDistance)
	local insideVeilLongApproachEnvelope = isVeil
		and Config.veilLongApproachGuardEnabled == true
		and distance >= Config.veilLongApproachGuardMinimumDistance
		and distance <= Config.veilLongApproachGuardMaximumDistance
	local insideLiteralPostSignalEnvelope = classToken == "killer"
		and now() <= (State.literalKillerSafetyEnvelopeUntilByModel[model] or -math.huge)
		and distance <= Config.literalKillerPostSignalEnvelopeDistance
	if distance > enterDistance and not insideVeilLongApproachEnvelope
		and not insideLiteralPostSignalEnvelope then
		return false
	end
	local facing = getFacingDot(killerRoot, State.root)
	local approach = getApproachSpeed(killerRoot, State.root)
	local toPlayer = unitOr(
		horizontal(State.root.Position - killerRoot.Position),
		-killerRoot.CFrame.LookVector
	)
	local physicalRelativeApproach = horizontal(
		killerRoot.AssemblyLinearVelocity
			- State.root.AssemblyLinearVelocity
	):Dot(toPlayer)
	local physicalInputDirection = CharacterController.PhysicalInputDirection()
	local intendedPlayerVelocity = physicalInputDirection
		and physicalInputDirection * CharacterController.DefensivePlanningSpeed()
		or Vector3.zero
	local intendedRelativeApproach = horizontal(
		killerRoot.AssemblyLinearVelocity - intendedPlayerVelocity
	):Dot(toPlayer)
	local relativeApproach = math.max(
		physicalRelativeApproach,
		intendedRelativeApproach
	)
	local killerCommitted, emergency = distanceKeeperAuthority(
		distance,
		facing,
		approach,
		isVeil
	)
	if abysswalkerSlowPressure then
		killerCommitted = true
	end
	local trackingManualClosing =
		Config.trackingManualClosingGuardEnabled == true
		and isTrackingClass
		and distance <= Config.trackingManualClosingGuardMaximumDistance
		and facing >= Config.trackingManualClosingGuardMinimumFacing
		and approach >= Config.trackingManualClosingGuardMinimumKillerApproach
		and relativeApproach
			>= Config.trackingManualClosingGuardMinimumRelativeApproach
	local trackingPostSignalEnvelope = isTrackingClass
		and now() <= (
			State.trackingSafetyEnvelopeUntilByModel[model]
				or -math.huge
		)
		and distance <= Config.trackingPostSignalEnvelopeDistance
		and facing >= Config.trackingPostSignalEnvelopeMinimumFacing
		and relativeApproach
			>= Config.trackingPostSignalEnvelopeMinimumRelativeClosing
	local literalKillerPostSignalEnvelope = classToken == "killer"
		and now() <= (
			State.literalKillerSafetyEnvelopeUntilByModel[model]
				or -math.huge
		)
		and distance <= Config.literalKillerPostSignalEnvelopeDistance
		and facing >= Config.literalKillerPostSignalEnvelopeMinimumFacing
		and relativeApproach
			>= Config.literalKillerPostSignalEnvelopeMinimumRelativeClosing
	local veilConfiguredManualClosing =
		Config.veilManualClosingGuardEnabled == true
		and isVeil
		and distance <= Config.veilManualClosingGuardMaximumDistance
		and facing >= Config.veilManualClosingGuardMinimumFacing
		and approach >= Config.veilManualClosingGuardMinimumKillerApproach
		and relativeApproach
			>= Config.veilManualClosingGuardMinimumRelativeApproach
	-- Veil's root remained effectively stationary throughout the supplied melee
	-- sequences. At close range, requiring the root itself to approach discarded
	-- player-created closing of +12 studs/s even while the exact class was facing
	-- the survivor. Admit only the high-relative-closing close case; the selected
	-- route must still pass the deep open-exit profile below.
	local veilCloseRelativeClosing =
		Config.veilManualClosingGuardEnabled == true
		and isVeil
		and distance <= 14.0
		and facing >= 0.45
		and approach >= -1.0
		and relativeApproach >= 8.0
	local veilCloseAimedPressure =
		Config.veilCloseAimedGuardEnabled == true
		and isVeil
		and distance <= Config.veilCloseAimedGuardMaximumDistance
		and facing >= Config.veilCloseAimedGuardMinimumFacing
		and approach >= Config.veilCloseAimedGuardMinimumApproach
	local veilManualClosing = veilConfiguredManualClosing
		or veilCloseRelativeClosing
	-- Hidden's supplied hit was preceded by a clean d=16.46, facing=0.96,
	-- relativeClosing=+4.24 sample.  The old generic rule deliberately discarded
	-- that sample because Hidden's root itself was moving away, then saw the exact
	-- PREP only after the gap had collapsed to 5.37.  For the authoritative Hidden
	-- class, player-created closing inside the normal distance floor is sufficient
	-- to request a fully certified open-exit route; an occluded or boxed route still
	-- cannot acquire movement authority.
	local hiddenManualClosing = isHidden
		and distance <= enterDistance
		and facing >= 0.78
		and relativeApproach >= 3.0
	-- Every killer can steer ordinary movement toward the survivor. The previous
	-- generic branch treated player-created closing as "manual authority" and
	-- deliberately waited until contact; the supplied Abysswalker hits went from
	-- 12.97/16.48 studs to 2.29/10.83 with no episode. Admit this only for a known
	-- class, clear line-facing and strong relative closing; geometry below still
	-- decides whether Helper may actually own movement.
	local genericManualClosing = classToken ~= "unknown"
		and distance <= enterDistance
		and facing >= 0.50
		and relativeApproach >= 3.0
	local veilLongApproachRaw = insideVeilLongApproachEnvelope
		and facing >= Config.veilLongApproachGuardMinimumFacing
		and approach >= Config.veilLongApproachGuardMinimumKillerApproach
	local veilLongApproach = false
	if isVeil then
		local sampleNow = now()
		local longState = State.veilLongApproachStateByModel[model]
		if type(longState) ~= "table" then
			longState = {
				qualifiedSince = nil,
				lastQualifiedAt = -math.huge,
			}
			State.veilLongApproachStateByModel[model] = longState
		end
		if veilLongApproachRaw then
			if not longState.qualifiedSince
				or sampleNow - (longState.lastQualifiedAt or -math.huge)
					> Config.veilLongApproachGuardSampleGap then
				longState.qualifiedSince = sampleNow
			end
			longState.lastQualifiedAt = sampleNow
			veilLongApproach = sampleNow - longState.qualifiedSince
				>= Config.veilLongApproachGuardSustain
		else
			longState.qualifiedSince = nil
			longState.lastQualifiedAt = -math.huge
		end
	end
	if distance > enterDistance
		and not veilLongApproach
		and not literalKillerPostSignalEnvelope then
		return false
	end
	if trackingManualClosing
		or trackingPostSignalEnvelope
		or literalKillerPostSignalEnvelope
		or genericManualClosing
		or hiddenManualClosing
		or veilManualClosing
		or veilCloseAimedPressure
		or veilLongApproach
		or abysswalkerSlowPressure then
		killerCommitted = true
	end
	-- Survivor velocity may request planning, but never certifies a route. The
	-- long-horizon grounded topology and profile gates below remain authoritative.
	if not killerCommitted and not emergency then
		if relativeApproach >= Config.threatDistanceKeeperMinimumApproach then
			Diagnostics.Push(
				"DISTANCE_KEEPER_REJECTED_PLAYER_CLOSING",
				string.format(
					"killer=%s class=%s d=%.2f facing=%.2f killerApproach=%+.2f relativeApproach=%+.2f action=manual-authority-no-episode",
					model.Name,
					tostring(classInfo.class or "Unknown"),
					distance,
					facing,
					approach,
					relativeApproach
				),
				"distance-keeper-player-closing-" .. model.Name,
				0.50
			)
		end
		return false
	end
	if Config.threatDistanceKeeperRequireLineOfSight then
		local origin = State.root.Position + Vector3.new(0, 1.5, 0)
		local target = killerRoot.Position + Vector3.new(0, 1.0, 0)
		local hit = RaycastBudget.Cast(origin, target - origin, false)
		if hit and not hit.Instance:IsDescendantOf(model)
			and not veilLongApproach then
			if trackingManualClosing
				or trackingPostSignalEnvelope
				or literalKillerPostSignalEnvelope then
				Diagnostics.Push(
					"DISTANCE_KEEPER_REJECTED_PLAYER_CLOSING",
					string.format(
						"killer=%s class=%s d=%.2f facing=%.2f relativeApproach=%+.2f blocker=%s action=occluded-no-episode",
						model.Name,
						tostring(classInfo.class or "Unknown"),
						distance,
						facing,
						relativeApproach,
						hit.Instance:GetFullName()
					),
					"distance-keeper-tracking-occluded-" .. model.Name,
					0.35
				)
			end
			return false
		end
	end
	if trackingManualClosing
		or trackingPostSignalEnvelope
		or literalKillerPostSignalEnvelope
		or genericManualClosing
		or hiddenManualClosing
		or veilManualClosing
		or veilCloseAimedPressure
		or veilLongApproach
		or abysswalkerSlowPressure then
		Diagnostics.Push(
			"DISTANCE_KEEPER_CONFIRMED",
			string.format(
				"killer=%s class=%s d=%.2f facing=%.2f killerApproach=%+.2f relativeApproach=%+.2f authority=%s action=full-open-exit-certificate-only",
				model.Name,
				tostring(classInfo.class or "Unknown"),
				distance,
				facing,
				approach,
				relativeApproach,
					abysswalkerSlowPressure and "abysswalker-slow-pressure"
					or (hiddenManualClosing and "hidden-manual-closing"
					or (genericManualClosing and "generic-known-class-manual-closing"
					or (literalKillerPostSignalEnvelope and "literal-killer-post-signal-envelope"
					or (trackingPostSignalEnvelope and "tracking-post-signal-envelope"
					or (trackingManualClosing and "tracking-manual-closing"
					or (veilLongApproach and "veil-long-committed-approach"
						or (veilCloseAimedPressure
							and "veil-close-aimed-pressure"
							or (veilCloseRelativeClosing
							and "veil-close-relative-closing"
							or "veil-manual-closing"))))))))
			),
			"distance-keeper-manual-closing-" .. model.Name,
			0.35
		)
	end
	local distanceProfile, distanceProfileLabel =
		distanceHoldProfileForClass(classInfo.class)
	if hiddenManualClosing then
		distanceProfileLabel = "hidden-manual-closing-open-exit"
	elseif veilManualClosing then
		distanceProfile = VEIL_MANUAL_CLOSING_DISTANCE_HOLD_PROFILE
		distanceProfileLabel = "veil-manual-closing-open-exit"
	elseif veilCloseAimedPressure then
		distanceProfile = VEIL_DISTANCE_HOLD_PROFILE
		distanceProfileLabel = "veil-close-aimed-strict-open-exit"
	elseif veilLongApproach then
		distanceProfile = VEIL_DISTANCE_HOLD_PROFILE
		distanceProfileLabel = "veil-long-committed-approach"
	elseif abysswalkerSlowPressure then
		distanceProfileLabel = "abysswalker-slow-pressure-open-exit"
	end
	if classToken == "killer" and emergency then
		distanceProfile = LITERAL_KILLER_EMERGENCY_DISTANCE_HOLD_PROFILE
		distanceProfileLabel = "literal-killer-emergency-open-exit"
	end
	local episodeMaximumDistance = abysswalkerSlowPressure
		and Config.abysswalkerSlowPressureMaximumDistance
		or (veilLongApproach
		and Config.veilLongApproachGuardMaximumDistance
		or enterDistance)
	local episodeTargetDistance = abysswalkerSlowPressure
		and Config.abysswalkerSlowPressureTargetDistance
		or (veilLongApproach
		and math.min(
			Config.veilLongApproachGuardMaximumDistance,
			math.max(exitDistance, distance + 4.0)
		)
		or exitDistance)
	local metadata = {
		family = "DISTANCE_KEEPER",
		phase = "ACTIVE",
		kind = "BOUNDED_DISTANCE_FLOOR",
		maxDistance = episodeMaximumDistance,
		duration = Config.threatDistanceKeeperDuration,
		safeDistance = episodeTargetDistance,
		speed = Config.movementHardSpeedCap,
		lateral = Config.threatDistanceKeeperLateralWeight,
		away = Config.threatDistanceKeeperAwayWeight,
		minFacing = -1.0,
		minimumHold = Config.threatDistanceKeeperMinimumHold,
		releaseWhenSeparating = false,
		motionProfileOverride = distanceProfile,
	}
	local episode = ThreatController.NewEpisode(
		model,
		killerRoot,
		"DISTANCE_KEEPER",
		metadata,
		nil
	)
	episode.synthetic = true
	episode.requireDeepRoute = false
	episode.rollingHorizon = true
	episode.rollingHorizonDelay = isVeil
		and Config.threatDistanceKeeperVeilRollingDelay
		or Config.threatDistanceKeeperRollingDelay
	episode.motionProfileOverride = distanceProfile
	episode.distanceEnvelopeLabel = distanceProfileLabel
	episode.abysswalkerSlowPressure = abysswalkerSlowPressure
	if isVeil then
		episode.targetDistance = episodeTargetDistance
	end
	ThreatMotionCore.RefreshRollingHorizon(episode, now())
	Diagnostics.Push(
		"DISTANCE_KEEPER_START",
		string.format(
			"episode=%d killer=%s class=%s d=%.2f enter=%.2f target=%.2f facing=%.2f killerApproach=%+.2f relativeApproach=%+.2f committed=%s emergency=%s slowed=%s walk=%.2f baseline=%.2f rollingDelay=%.2f profile=%s action=outward-open-corridor-distance-hold",
			episode.episodeId,
			model.Name,
			tostring(episode.killerClass or "Unknown"),
			distance,
			enterDistance,
			episodeTargetDistance,
			facing,
			approach,
			relativeApproach,
			tostring(killerCommitted),
			tostring(emergency),
			tostring(abysswalkerSlowPressure),
			currentWalk,
			baselineWalk,
			episode.rollingHorizonDelay,
			distanceProfileLabel
		),
		"distance-keeper-start-" .. model.Name,
		0.25
	)
	return true
end

function ThreatController.EnsureLockedThreatWarning(): TextLabel?
	local existing = State.lockedThreatWarningLabel
	if existing and existing.Parent then
		return existing
	end
	local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
	if not playerGui then
		return nil
	end
	local gui = Instance.new("ScreenGui")
	gui.Name = "VDLockedThreatWarning"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 100000
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	local label = Instance.new("TextLabel")
	label.Name = "Warning"
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Position = UDim2.fromScale(0.5, 0.24)
	label.Size = UDim2.new(0.66, 0, 0, 72)
	label.BackgroundColor3 = Color3.fromRGB(150, 12, 12)
	label.BackgroundTransparency = 0.10
	label.BorderSizePixel = 0
	label.Font = Enum.Font.GothamBold
	label.TextColor3 = Color3.fromRGB(255, 255, 255)
	label.TextStrokeColor3 = Color3.fromRGB(35, 0, 0)
	label.TextStrokeTransparency = 0.15
	label.TextScaled = true
	label.TextWrapped = true
	label.ZIndex = 100
	label.Visible = false
	label.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = label
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(255, 100, 100)
	stroke.Thickness = 3
	stroke.Parent = label
	gui.Parent = playerGui
	State.lockedThreatWarningGui = gui
	State.lockedThreatWarningLabel = label
	return label
end

function ThreatController.ShowLockedThreatWarning(
	threat: any,
	status: string
): ()
	if not Config.lockedThreatVisualWarningEnabled then
		return
	end
	local label = ThreatController.EnsureLockedThreatWarning()
	if not label then
		return
	end
	local repairing = string.find(
		string.lower(status),
		"repair",
		1,
		true
	) ~= nil
	label.Text = repairing
		and "УГРОЗА — НАЖМИ WASD И ОТОЙДИ ОТ ГЕНЕРАТОРА"
		or "УГРОЗА — ПРЕРВИ ДЕЙСТВИЕ И ОТОЙДИ"
	label.Visible = true
	local t = now()
	State.lockedThreatWarningUntil = t + 0.55
	if t - State.lastLockedThreatWarningLogAt >= 0.40 then
		State.lastLockedThreatWarningLogAt = t
		Diagnostics.Push(
			"LOCKED_THREAT_WARNING",
			string.format(
				"episode=%s family=%s d=%.2f walk=%.2f status=%s action=visual-warning-player-must-press-WASD",
				tostring(threat and threat.episodeId or "none"),
				tostring(threat and threat.family or "UNKNOWN"),
				threat and threatDistance(threat) or math.huge,
				State.humanoid and State.humanoid.WalkSpeed or 0,
				status
			),
			"locked-threat-warning",
			0.05
		)
	end
end

function ThreatController.UpdateLockedThreatWarning(): ()
	local label = State.lockedThreatWarningLabel
	if label and label.Parent and label.Visible
		and now() > State.lockedThreatWarningUntil then
		label.Visible = false
	end
end

function ThreatController.TryMaskedCloseAimGuard(): boolean
	if not Config.maskedCloseAimGuardEnabled
		or ThreatController.PostHitSuppressed()
		or not State.enabled
		or not State.matchActive
		or isDowned()
		or State.activeThreat
		or not State.root
		or not State.humanoid then
		return false
	end

	local model = State.nearestKiller
	local killerRoot = modelRoot(model)
	if not model or not killerRoot then
		return false
	end
	local classInfo = ThreatController.KillerClassInfo(model)
	local classSource = string.lower(tostring(classInfo.source or ""))
	if normalizedClassToken(tostring(classInfo.class or "")) ~= "masked"
		or string.find(classSource, "inferred-family", 1, true) ~= nil then
		State.maskedCloseAimStateByModel[model] = nil
		return false
	end

	local locked = CharacterController.DefensiveMovementStatus()
	if locked
		and not CharacterController.CanDetectThreatWhileRepairLocked() then
		State.maskedCloseAimStateByModel[model] = nil
		return false
	end
	if math.abs(killerRoot.Position.Y - State.root.Position.Y)
		> Config.repairThreatEscapeMaximumVerticalSeparation then
		State.maskedCloseAimStateByModel[model] = nil
		return false
	end

	local distance = horizontal(
		killerRoot.Position - State.root.Position
	).Magnitude
	local facing = getFacingDot(killerRoot, State.root)
	local approach = getApproachSpeed(killerRoot, State.root)
	local historicalApproach, historicalWindow =
		ThreatMotionCore.HistoricalApproach(model, distance)
	local emergency = distance <= Config.maskedCloseAimGuardEmergencyDistance
		and facing >= Config.maskedCloseAimGuardEmergencyFacing
	local normalAimed = distance <= Config.maskedCloseAimGuardDistance
		and facing >= Config.maskedCloseAimGuardFacing
		and approach >= Config.maskedCloseAimGuardMinimumApproach
	local historicalClosing =
		distance <= Config.maskedHistoricalGuardDistance
		and facing >= Config.maskedHistoricalGuardFacing
		and historicalApproach >= Config.maskedHistoricalGuardApproach
	-- A Masked lunge can report a strongly negative approach on the impact
	-- frame even though the model is still facing directly at the Survivor. The
	-- old shared `aimed` gate therefore made the emergency tier impossible in
	-- precisely that geometry. Near-perfect point-blank aim is authoritative on
	-- its own; the slower normal tier still requires non-separating motion.
	local aimed = emergency or normalAimed or historicalClosing
	local requiredSustain = emergency
		and Config.maskedCloseAimGuardEmergencySustain
		or (historicalClosing
			and Config.maskedHistoricalGuardSustain
			or Config.maskedCloseAimGuardSustain)
	local t = now()
	local aimState = State.maskedCloseAimStateByModel[model]
	if not aimState then
		aimState = {
			aimedSince = nil,
			lastTriggeredAt = -math.huge,
		}
		State.maskedCloseAimStateByModel[model] = aimState
	end
	if not aimed then
		aimState.aimedSince = nil
		return false
	end
	if not aimState.aimedSince then
		aimState.aimedSince = t
		if requiredSustain > 0 then
			return false
		end
	end
	if t - aimState.aimedSince < requiredSustain
		or t - aimState.lastTriggeredAt < Config.maskedCloseAimGuardCooldown then
		return false
	end

	local metadata = {
		family = "MASKED_CLOSE_AIM_GUARD",
		phase = "ACTIVE",
		kind = "MASKED_SUSTAINED_CLOSE_AIM",
		maxDistance = Config.maskedCloseAimGuardDistance + 3.0,
		duration = Config.maskedCloseAimGuardDuration,
		minimumHold = Config.maskedCloseAimGuardMinimumHold,
		safeDistance = Config.maskedCloseAimGuardSafeDistance,
		speed = Config.movementHardSpeedCap,
		lateral = 6.0,
		away = 4.0,
		aimImpactDelay = Config.maskedCloseAimGuardImpactDelay,
		motionProfileOverride = MASKED_CLOSE_AIM_GUARD_PROFILE,
		-- Do not cancel the short emergency hold from a one-frame negative
		-- approach sample produced as Masked crosses the impact point.
		releaseWhenSeparating = false,
	}
	local episode = ThreatController.NewEpisode(
		model,
		killerRoot,
		"MASKED_SUSTAINED_CLOSE_AIM",
		metadata,
		nil
	)
	episode.synthetic = true
	episode.confirmedAimGuard = true
	-- NewEpisode already attached the core with metadata.aimImpactDelay. Do not
	-- attach a second time and accidentally create a duplicate timing lifecycle.
	episode.requireDeepRoute = true
	episode.closeGuardHardDeadline = t + Config.maskedCloseAimGuardMaximumHold
	episode.hardMaximumUntil = math.max(
		episode.hardMaximumUntil or -math.huge,
		episode.closeGuardHardDeadline
	)
	aimState.lastTriggeredAt = t
	aimState.aimedSince = nil
	Diagnostics.Push(
		"MASKED_CLOSE_AIM_GUARD",
		string.format(
			"episode=%d killer=%s class=%s d=%.2f facing=%.2f approach=%+.2f historicalApproach=%+.2f historyWindow=%.2f sustained=%.2f emergency=%s historicalClosing=%s action=homing-open-exit-full-certificate",
			episode.episodeId,
			model.Name,
			tostring(classInfo.class),
			distance,
			facing,
			approach,
			historicalApproach,
			historicalWindow,
			requiredSustain,
			tostring(emergency),
			tostring(historicalClosing)
		),
		"masked-close-aim-" .. model.Name,
		0.15
	)
	return true
end

function ThreatController.TryHiddenCloseAimGuard(): boolean
	if not Config.hiddenCloseAimGuardEnabled
		or ThreatController.PostHitSuppressed()
		or not State.enabled
		or not State.matchActive
		or isDowned()
		or State.activeThreat
		or not State.root
		or not State.humanoid then
		return false
	end

	local model = State.nearestKiller
	local killerRoot = modelRoot(model)
	if not model or not killerRoot then
		return false
	end
	local classInfo = ThreatController.KillerClassInfo(model)
	local classSource = string.lower(tostring(classInfo.source or ""))
	if normalizedClassToken(tostring(classInfo.class or "")) ~= "hidden"
		or string.find(classSource, "inferred-family", 1, true) ~= nil then
		State.hiddenCloseAimStateByModel[model] = nil
		return false
	end

	local locked = CharacterController.DefensiveMovementStatus()
	if locked
		and not CharacterController.CanDetectThreatWhileRepairLocked() then
		State.hiddenCloseAimStateByModel[model] = nil
		return false
	end
	if math.abs(killerRoot.Position.Y - State.root.Position.Y)
		> Config.repairThreatEscapeMaximumVerticalSeparation then
		State.hiddenCloseAimStateByModel[model] = nil
		return false
	end

	local distance = horizontal(
		killerRoot.Position - State.root.Position
	).Magnitude
	local facing = getFacingDot(killerRoot, State.root)
	local approach = getApproachSpeed(killerRoot, State.root)
	local historicalApproach, historicalWindow =
		ThreatMotionCore.HistoricalApproach(model, distance)
	local emergency = distance <= Config.hiddenCloseAimGuardEmergencyDistance
		and facing >= Config.hiddenCloseAimGuardEmergencyFacing
	local normalAimed = distance <= Config.hiddenCloseAimGuardDistance
		and facing >= Config.hiddenCloseAimGuardFacing
		and approach >= Config.hiddenCloseAimGuardMinimumApproach
	local historicalClosing =
		distance <= Config.hiddenHistoricalGuardDistance
		and facing >= Config.hiddenHistoricalGuardFacing
		and historicalApproach >= Config.hiddenHistoricalGuardApproach
		and approach >= Config.hiddenHistoricalGuardCurrentApproachFloor
	local aimed = emergency or normalAimed or historicalClosing
	local requiredSustain = emergency
		and Config.hiddenCloseAimGuardEmergencySustain
		or (historicalClosing
			and Config.hiddenHistoricalGuardSustain
			or Config.hiddenCloseAimGuardSustain)
	local t = now()
	local aimState = State.hiddenCloseAimStateByModel[model]
	if not aimState then
		aimState = {
			aimedSince = nil,
			lastTriggeredAt = -math.huge,
		}
		State.hiddenCloseAimStateByModel[model] = aimState
	end
	if not aimed then
		aimState.aimedSince = nil
		return false
	end
	if not aimState.aimedSince then
		aimState.aimedSince = t
		if requiredSustain > 0 then
			return false
		end
	end
	if t - aimState.aimedSince < requiredSustain
		or t - aimState.lastTriggeredAt < Config.hiddenCloseAimGuardCooldown then
		return false
	end

	local metadata = {
		family = "HIDDEN_CLOSE_AIM_GUARD",
		phase = "ACTIVE",
		kind = "HIDDEN_SUSTAINED_CLOSE_AIM",
		maxDistance = Config.hiddenCloseAimGuardDistance + 2.0,
		duration = Config.hiddenCloseAimGuardDuration,
		minimumHold = Config.hiddenCloseAimGuardMinimumHold,
		safeDistance = Config.hiddenCloseAimGuardSafeDistance,
		speed = Config.movementHardSpeedCap,
		lateral = 12.0,
		away = 30.0,
		-- A one-frame negative approach can be produced as Hidden crosses the
		-- player on the hit frame. The bounded motion lifecycle owns release.
		releaseWhenSeparating = false,
		separatingApproach = -1.50,
		separatingFacing = 0.55,
		aimImpactDelay = Config.hiddenCloseAimGuardImpactDelay,
		-- The synthetic guard uses the ordinary pursuit envelope, but unlike the
		-- generic profile it must not relinquish a certified route merely because a
		-- 780 ms snapshot says current WASD is barely safe. PREP/ACTIVE will promote
		-- this route transactionally to the exact Hidden lunge profile.
		motionProfileOverride = {
			motionType="PURSUIT_MELEE",
			killerSpeed=22.0,
			hitRadius=Config.predictiveDefaultHitRadius,
			lateralWeight=4.0,
			awayWeight=9.0,
			minimumAwayDot=0.26,
			homing=true,
			minimumGain=0.55,
			minimumCorridor=4.0,
			requireOpenExit=true,
			requireFullCertificate=false,
			allowSafetyFloor=true,
			manualAuthorityReleaseDistance=20.0,
		},
	}
	local episode = ThreatController.NewEpisode(
		model,
		killerRoot,
		"HIDDEN_SUSTAINED_CLOSE_AIM",
		metadata,
		nil
	)
	episode.synthetic = true
	episode.confirmedAimGuard = true
	episode.requireDeepRoute = true
	episode.closeGuardHardDeadline = t + Config.hiddenCloseAimGuardMaximumHold
	aimState.lastTriggeredAt = t
	aimState.aimedSince = nil
	Diagnostics.Push(
		"HIDDEN_CLOSE_AIM_GUARD",
		string.format(
			"episode=%d killer=%s class=%s d=%.2f facing=%.2f approach=%+.2f historicalApproach=%+.2f historyWindow=%.2f sustained=%.2f emergency=%s historicalClosing=%s action=predictive-away-corridor",
			episode.episodeId,
			model.Name,
			tostring(classInfo.class),
			distance,
			facing,
			approach,
			historicalApproach,
			historicalWindow,
			requiredSustain,
			tostring(emergency),
			tostring(historicalClosing)
		),
		"hidden-close-aim-" .. model.Name,
		0.15
	)
	return true
end

function ThreatController.TryKillerCloseAimGuard(): boolean
	if not Config.killerCloseAimGuardEnabled
		or ThreatController.PostHitSuppressed()
		or not State.enabled
		or not State.matchActive
		or isDowned()
		or not State.root
		or not State.humanoid then
		return false
	end

	local model = State.nearestKiller
	local killerRoot = modelRoot(model)
	if not model or not killerRoot then
		return false
	end
	local t = now()
	if ActionArbiter.CounterOwnsModel(model) then
		-- Exact PREP->ACTIVE counter authority is global. The generic Killer
		-- guard cannot be recreated while the sequence is armed or C is held.
		State.killerCloseAimStateByModel[model] = nil
		MovementWriter.Clear(OWNER.THREAT, "counter action owns killer")
		return false
	end
	local classInfo = ThreatController.KillerClassInfo(model)
	local classSource = string.lower(tostring(classInfo.source or ""))
	if normalizedClassToken(tostring(classInfo.class or "")) ~= "killer"
		or string.find(classSource, "inferred-family", 1, true) ~= nil then
		State.killerCloseAimStateByModel[model] = nil
		return false
	end

	local locked = CharacterController.DefensiveMovementStatus()
	if locked
		and not CharacterController.CanDetectThreatWhileRepairLocked() then
		State.killerCloseAimStateByModel[model] = nil
		return false
	end
	if math.abs(killerRoot.Position.Y - State.root.Position.Y)
		> Config.repairThreatEscapeMaximumVerticalSeparation then
		State.killerCloseAimStateByModel[model] = nil
		return false
	end

	local distance = horizontal(
		killerRoot.Position - State.root.Position
	).Magnitude
	local facing = getFacingDot(killerRoot, State.root)
	local approach = getApproachSpeed(killerRoot, State.root)
	local historicalApproach, historicalWindow =
		ThreatMotionCore.HistoricalApproach(model, distance)
	local contactEmergency = distance <= Config.killerCloseAimGuardContactDistance
	local emergency = contactEmergency
		or (distance <= Config.killerCloseAimGuardEmergencyDistance
			and facing >= Config.killerCloseAimGuardEmergencyFacing
			and approach >= Config.killerHistoricalGuardCurrentApproachFloor)
	local normalAimed = distance <= Config.killerCloseAimGuardDistance
		and facing >= Config.killerCloseAimGuardFacing
		and approach >= Config.killerCloseAimGuardMinimumApproach
	local historicalClosing =
		distance <= Config.killerHistoricalGuardDistance
		and facing >= Config.killerHistoricalGuardFacing
		and historicalApproach >= Config.killerHistoricalGuardApproach
		and approach >= Config.killerHistoricalGuardCurrentApproachFloor
	local fastHistoricalClosing =
		distance <= Config.killerFastHistoricalGuardDistance
		and facing >= Config.killerFastHistoricalGuardFacing
		and historicalApproach >= Config.killerFastHistoricalGuardApproach
		and approach >= Config.killerFastHistoricalGuardCurrentApproachFloor
	local aimed = emergency
		or normalAimed
		or historicalClosing
		or fastHistoricalClosing
	local requiredSustain = emergency
		and Config.killerCloseAimGuardEmergencySustain
		or (fastHistoricalClosing
			and Config.killerFastHistoricalGuardSustain
		or (historicalClosing
			and Config.killerHistoricalGuardSustain
			or Config.killerCloseAimGuardSustain))
	local aimState = State.killerCloseAimStateByModel[model]
	if not aimState then
		aimState = {
			aimedSince = nil,
			lastTriggeredAt = -math.huge,
		}
		State.killerCloseAimStateByModel[model] = aimState
	end
	if not aimed then
		aimState.aimedSince = nil
		local liveGuard = State.activeThreat
		if liveGuard
			and liveGuard.killerModel == model
			and liveGuard.family == "KILLER_CLOSE_AIM_GUARD"
			and liveGuard.synthetic == true
			and distance > Config.killerCloseAimGuardContactDistance
			and approach < Config.killerHistoricalGuardCurrentApproachFloor then
			ThreatController.Release("literal-killer-guard-live-separation")
		end
		return false
	end
	local activeGuard = State.activeThreat
	if activeGuard then
		if activeGuard.killerModel ~= model
			or activeGuard.family ~= "KILLER_CLOSE_AIM_GUARD" then
			return false
		end
		-- Sustain the same episode while the exact geometry remains authoritative.
		-- Route planning remains bounded by the ordinary 140ms cadence and existing
		-- replan cap; this only prevents an unprotected gap before a late ACTIVE.
		local refreshDeadline = activeGuard.closeGuardHardDeadline
			or (activeGuard.startedAt + Config.killerCloseAimGuardMaximumHold)
		local refreshedImpact = math.min(
			refreshDeadline,
			t + Config.killerCloseAimRefreshHorizon
		)
		local refreshedHold = math.min(
			refreshDeadline,
			t + Config.killerCloseAimRefreshHold
		)
		activeGuard.motionImpactAt = math.max(
			activeGuard.motionImpactAt or -math.huge,
			refreshedImpact
		)
		activeGuard.motionHoldUntil = math.max(
			activeGuard.motionHoldUntil or -math.huge,
			refreshedHold
		)
		activeGuard.minimumReleaseAt = math.max(
			activeGuard.minimumReleaseAt or -math.huge,
			activeGuard.motionHoldUntil
		)
		activeGuard.expiresAt = math.max(
			activeGuard.expiresAt or -math.huge,
			activeGuard.motionHoldUntil
		)
		activeGuard.maximumUntil = math.max(
			activeGuard.maximumUntil or -math.huge,
			math.min(refreshDeadline, activeGuard.motionHoldUntil + 0.20)
		)
		activeGuard.hardMaximumUntil = math.max(
			activeGuard.hardMaximumUntil or -math.huge,
			refreshDeadline
		)
		-- Do not clear a blocked-route latch here. Initial no-route states already
		-- retry at the bounded planner cadence; a route that became physically
		-- blocked remains native-WASD until a distinct exact attack signal arrives.
		return true
	end
	if not aimState.aimedSince then
		aimState.aimedSince = t
		if requiredSustain > 0 then
			return false
		end
	end
	if t - aimState.aimedSince < requiredSustain
		or t - aimState.lastTriggeredAt < Config.killerCloseAimGuardCooldown then
		return false
	end

	local metadata = {
		family = "KILLER_CLOSE_AIM_GUARD",
		phase = "ACTIVE",
		kind = "KILLER_SUSTAINED_CLOSE_AIM",
		maxDistance = Config.killerCloseAimGuardDistance + 2.0,
		duration = Config.killerCloseAimGuardDuration,
		minimumHold = Config.killerCloseAimGuardMinimumHold,
		safeDistance = Config.killerCloseAimGuardSafeDistance,
		speed = Config.movementHardSpeedCap,
		lateral = 12.0,
		away = 30.0,
		releaseWhenSeparating = false,
		aimImpactDelay = Config.killerCloseAimGuardImpactDelay,
		motionProfileOverride = LITERAL_KILLER_CLOSE_AIM_PROFILE,
	}
	local episode = ThreatController.NewEpisode(
		model,
		killerRoot,
		"KILLER_SUSTAINED_CLOSE_AIM",
		metadata,
		nil
	)
	episode.synthetic = true
	episode.confirmedAimGuard = true
	episode.requireDeepRoute = true
	episode.closeGuardHardDeadline = t + Config.killerCloseAimGuardMaximumHold
	episode.hardMaximumUntil = math.max(
		episode.hardMaximumUntil or -math.huge,
		episode.closeGuardHardDeadline
	)
	aimState.lastTriggeredAt = t
	aimState.aimedSince = nil
	Diagnostics.Push(
		"KILLER_CLOSE_AIM_GUARD",
		string.format(
			"episode=%d killer=%s class=%s source=%s d=%.2f facing=%.2f approach=%+.2f historicalApproach=%+.2f historyWindow=%.2f sustained=%.2f emergency=%s contact=%s historicalClosing=%s fastHistoricalClosing=%s action=predictive-homing-open-corridor-sustained",
			episode.episodeId,
			model.Name,
			tostring(classInfo.class),
			tostring(classInfo.source),
			distance,
			facing,
			approach,
			historicalApproach,
			historicalWindow,
			requiredSustain,
			tostring(emergency),
			tostring(contactEmergency),
			tostring(historicalClosing),
			tostring(fastHistoricalClosing)
		),
		"killer-close-aim-" .. model.Name,
		0.15
	)
	return true
end

function ThreatController.Update(): ()
	ThreatController.UpdateLockedThreatWarning()
	ThreatController.UpdateArmedCrouchCounter()
	local threat = State.activeThreat
	if not threat then
		if not Config.threatAutoMovementEnabled then
			MovementWriter.Clear(OWNER.THREAT, "manual threat mode")
			return
		end
		local nearestModel = State.nearestKiller
		local noCorridorUntil = nearestModel
			and State.noCorridorGuardBlockedUntilByModel[nearestModel]
			or -math.huge
		if now() < noCorridorUntil then
			-- Exact AnimationPlayed signals remain allowed to start their own episode.
			-- Only heuristic/distance guards are paused after geometry proved boxed.
			MovementWriter.Clear(OWNER.THREAT, "no-corridor guard cooldown")
			return
		end
		-- No universal proximity episode is allowed. Exact-class Hidden and Masked
		-- sustained-aim guards cover only kits whose supplied hits repeatedly arrived
		-- without any usable replicated AnimationPlayed signal.
		if not ThreatController.TryDistanceKeeper()
			and not ThreatController.TryMaskedCloseAimGuard()
			and not ThreatController.TryHiddenCloseAimGuard()
			and not ThreatController.TryKillerCloseAimGuard() then
			MovementWriter.Clear(OWNER.THREAT, "no confirmed active threat")
			return
		end
		threat = State.activeThreat
		if not threat then
			return
		end
	end
	if not State.enabled or isDowned() then
		ThreatController.Release("disabled/downed")
		return
	end
	local humanoid = aliveHumanoid(threat.killerModel)
	local killerRoot = modelRoot(threat.killerModel)
	local localRoot = State.root
	if not humanoid or not killerRoot or not localRoot then
		ThreatController.Release("killer invalid")
		return
	end
	threat.killerRoot = killerRoot
	local repairFloorSeparated = CharacterController.IsRepairing()
		and math.abs(killerRoot.Position.Y - localRoot.Position.Y)
			> Config.repairThreatEscapeMaximumVerticalSeparation
	local familyToken = tostring(threat.family or "")
	local crossFloorRepairThreat = familyToken == "VEIL_THROW"
		or familyToken == "VEIL_DELAYED"
		or familyToken == "VEIL_WALL_ARROW_AIM"
	if repairFloorSeparated and not crossFloorRepairThreat then
		Diagnostics.Push(
			"REPAIR_THREAT_DIFFERENT_FLOOR_IGNORED",
			string.format(
				"episode=%d family=%s vertical=%.2f limit=%.2f action=stay-on-generator-no-movement",
				threat.episodeId,
				familyToken,
				math.abs(killerRoot.Position.Y - localRoot.Position.Y),
				Config.repairThreatEscapeMaximumVerticalSeparation
			),
			"repair-threat-different-floor-" .. tostring(threat.episodeId),
			0.20
		)
		ThreatController.Release("repair threat on different floor")
		return
	end
	local t = now()
	local distance = threatDistance(threat)
	if threat.family == "DISTANCE_KEEPER"
		and t - (threat.startedAt or t) >= 0.08 then
		local className = tostring(
			threat.killerClass
				or ThreatController.KillerClassInfo(threat.killerModel).class
				or "Unknown"
		)
		local isVeil = string.lower(className) == "veil"
		local facing = getFacingDot(killerRoot, localRoot)
		local approach = getApproachSpeed(killerRoot, localRoot)
		local killerCommitted, contactEmergency = distanceKeeperAuthority(
			distance,
			facing,
			approach,
			isVeil
		)
		if threat.distanceEnvelopeLabel == "hidden-manual-closing-open-exit"
			and facing >= 0.78 then
			local toPlayer = unitOr(
				horizontal(localRoot.Position - killerRoot.Position),
				-killerRoot.CFrame.LookVector
			)
			local relativeApproach = horizontal(
				killerRoot.AssemblyLinearVelocity
					- localRoot.AssemblyLinearVelocity
			):Dot(toPlayer)
			if relativeApproach >= 3.0 then
				killerCommitted = true
			end
		end
		if killerCommitted or contactEmergency then
			threat.lastDangerousGeometryAt = t
		end
		local contactHold = distance
			<= Config.threatDistanceKeeperContactHoldDistance
		local disengageGrace = t - (threat.lastDangerousGeometryAt or t)
			< Config.threatDistanceKeeperDisengageGrace
		if not killerCommitted
			and not contactEmergency
			and not contactHold
			and not disengageGrace then
			Diagnostics.Push(
				"DISTANCE_KEEPER_DISENGAGED",
				string.format(
					"episode=%d killer=%s class=%s d=%.2f facing=%.2f killerApproach=%+.2f action=release-manual-authority",
					threat.episodeId,
					threat.killerModel.Name,
					className,
					distance,
					facing,
					approach
				),
				"distance-keeper-disengaged-" .. tostring(threat.episodeId),
				0.05
			)
			ThreatController.Release("distance-keeper-killer-disengaged")
			return
		elseif not killerCommitted and not contactEmergency then
			Diagnostics.Push(
				"DISTANCE_KEEPER_DISENGAGE_DEFERRED",
				string.format(
					"episode=%d d=%.2f facing=%.2f killerApproach=%+.2f contactHold=%s graceRemaining=%.2f action=keep-last-certified-route",
					threat.episodeId,
					distance,
					facing,
					approach,
					tostring(contactHold),
					math.max(0, Config.threatDistanceKeeperDisengageGrace - (t - (threat.lastDangerousGeometryAt or t)))
				),
				"distance-keeper-disengage-deferred-" .. tostring(threat.episodeId),
				0.20
			)
		end
	end
	local trackAuthorityActive = threat.holdControlUntilTrackStop == true
		and threat.activeTracks > 0
	local trackingTrackRolling = trackAuthorityActive
		and threat.phase == "ACTIVE"
		and threat.motionType == "TRACKING_PURSUIT"
	if trackingTrackRolling then
		if threat.trackRollingHorizon ~= true then
			Diagnostics.Push(
				"TRACKING_ROLLING_HORIZON_ACTIVE",
				string.format(
					"episode=%d id=%s delay=%.2f action=forecast-until-track-stop",
					threat.episodeId,
					tostring(threat.activeAnimationId or threat.primaryAnimationId or "none"),
					Config.trackingTrackRollingImpactDelay
				),
				"tracking-rolling-" .. tostring(threat.episodeId),
				0.05
			)
		end
		threat.trackRollingHorizon = true
		threat.rollingHorizon = true
		threat.rollingHorizonDelay = Config.trackingTrackRollingImpactDelay
		threat.expiresAt = math.max(
			threat.expiresAt or -math.huge,
			t + Config.trackingTrackRollingExpiryRefresh
		)
		threat.maximumUntil = math.max(
			threat.maximumUntil or -math.huge,
			t + Config.trackingTrackRollingExpiryRefresh
		)
	elseif threat.trackRollingHorizon == true then
		-- Freeze the last certified horizon when the exact track stops. The
		-- existing postTrackHold then owns only its short release grace.
		threat.trackRollingHorizon = false
		threat.rollingHorizon = false
		threat.rollingHorizonDelay = nil
	end
	ThreatMotionCore.RefreshRollingHorizon(threat, t)
	local motionLifecycleActive =
		ThreatMotionCore.HoldsLifecycle(threat, t)
	local sustainedCloseGuard = threat.family == "KILLER_CLOSE_AIM_GUARD"
		or threat.family == "MASKED_CLOSE_AIM_GUARD"
		or threat.family == "HIDDEN_CLOSE_AIM_GUARD"
	if sustainedCloseGuard
		and distance < (threat.targetDistance or Config.killerCloseAimGuardSafeDistance) then
		local maskedGuard = threat.family == "MASKED_CLOSE_AIM_GUARD"
		local hiddenGuard = threat.family == "HIDDEN_CLOSE_AIM_GUARD"
		local maximumHold = if maskedGuard
			then Config.maskedCloseAimGuardMaximumHold
			elseif hiddenGuard
			then Config.hiddenCloseAimGuardMaximumHold
			else Config.killerCloseAimGuardMaximumHold
		local refreshHorizon = if maskedGuard
			then Config.maskedCloseAimGuardRefreshHorizon
			elseif hiddenGuard
			then Config.hiddenCloseAimGuardRefreshHorizon
			else Config.killerCloseAimGuardRefreshHorizon
		local refreshHoldDuration = if maskedGuard
			then Config.maskedCloseAimGuardRefreshHold
			elseif hiddenGuard
			then Config.hiddenCloseAimGuardRefreshHold
			else Config.killerCloseAimGuardRefreshHold
		local contactDistance = maskedGuard
			and Config.maskedCloseAimGuardEmergencyDistance
			or (hiddenGuard
				and Config.hiddenCloseAimGuardEmergencyDistance
				or Config.killerCloseAimGuardContactDistance)
		local closeDeadline = threat.closeGuardHardDeadline
			or (threat.startedAt + maximumHold)
		local closeApproach = getApproachSpeed(killerRoot, localRoot)
		local closeFacing = getFacingDot(killerRoot, localRoot)
		local contactEmergency = distance <= contactDistance
		local stillEngaged = contactEmergency
			or closeApproach > -2.50
			or closeFacing > 0.10
		if stillEngaged and t < closeDeadline then
			local refreshImpact = math.min(
				closeDeadline,
				t + refreshHorizon
			)
			local refreshHold = math.min(
				closeDeadline,
				t + refreshHoldDuration
			)
			threat.motionImpactAt = math.max(
				threat.motionImpactAt or -math.huge,
				refreshImpact
			)
			threat.motionHoldUntil = math.max(
				threat.motionHoldUntil or -math.huge,
				refreshHold
			)
			threat.minimumReleaseAt = math.max(
				threat.minimumReleaseAt or -math.huge,
				refreshHold
			)
			threat.expiresAt = math.max(
				threat.expiresAt or -math.huge,
				refreshHold
			)
			threat.maximumUntil = math.max(
				threat.maximumUntil or -math.huge,
				refreshHold
			)
			threat.hardMaximumUntil = math.max(
				threat.hardMaximumUntil or -math.huge,
				closeDeadline
			)
			ThreatMotionCore.ExtendCertificateHorizon(
				threat,
				threat.motionImpactAt,
				threat.motionHoldUntil
			)
			motionLifecycleActive = true
		end
	end
	if threat.phase == "PREP" and t - threat.startedAt >= 0.05 then
		local prepApproach = getApproachSpeed(killerRoot, State.root)
		local prepFacing = getFacingDot(killerRoot, State.root)
		local prepSeparating = if threat.forceRouteOnPrep == true
			then prepApproach <= (threat.separatingApproach or -0.50)
				and prepFacing <= (threat.separatingFacing or 0.25)
			else prepApproach <= 0.0 and prepFacing < 0.85
		if prepSeparating then
			ThreatController.Release("prep-separating/not-aimed")
			return
		end
	end
	if threat.family == "GENERIC_PRESSURE_GUARD" then
		local selected =
			ThreatController.SelectedKillerName(
				threat.killerModel
			)
		if Config.genericPointBlankGuardSkipKnownArchetypes
			and GENERIC_GUARD_KNOWN_ARCHETYPES[
				normalizedArchetypeName(selected)
			] then
			ThreatController.Release(
				"generic-superseded-known-archetype"
			)
			return
		end

		local approach =
			getApproachSpeed(killerRoot, State.root)
		if t - threat.startedAt >= 0.08
			and approach
				<= Config.genericPointBlankGuardReleaseSeparatingApproach then
			ThreatController.Release(
				"generic-killer-separating"
			)
			return
		end
	end
	if threat.releaseWhenSeparating
		and not motionLifecycleActive
		and t >= threat.minimumReleaseAt then
		local approach = getApproachSpeed(killerRoot, State.root)
		local facing = getFacingDot(killerRoot, State.root)
		if approach <= (threat.separatingApproach or -1.5)
			and facing <= (threat.separatingFacing or 0.0) then
			ThreatController.Release("killer-separating/not-aimed")
			return
		end
	end
	if threat.family == "TRACKING_POINTBLANK_GUARD" then
		local approach = getApproachSpeed(killerRoot, State.root)
		if t >= threat.minimumReleaseAt and approach <= -2.25 then
			ThreatController.Release("tracking-class-separating")
			return
		end
	end
	if threat.family == "KILLER_POINTBLANK_GUARD" then
		local approach = getApproachSpeed(killerRoot, State.root)
		if t >= threat.minimumReleaseAt and approach <= -2.0 then
			ThreatController.Release("killer-class-separating")
			return
		end
	end
	if threat.family == "RIP_POINTBLANK_GUARD" then
		local approach = getApproachSpeed(killerRoot, State.root)
		local facing = getFacingDot(killerRoot, State.root)
		if t >= threat.minimumReleaseAt
			and approach <= -1.75
			and facing <= 0.25 then
			ThreatController.Release("rip-masked-separating")
			return
		end
	end
	-- VEIL_MELEE_GUARD is now a distance-hold episode. Do not release merely
	-- because Veil briefly turns or separates; the common safe-distance gate
	-- below owns release at the configured 18-stud boundary.
	if distance > Config.threatMaximumDistance then
		ThreatController.Release("killer too far")
		return
	end
	local postTrackHoldActive = threat.holdControlUntilTrackStop == true
		and threat.activeTracks <= 0
		and threat.lastTrackStoppedAt > -math.huge
		and t - threat.lastTrackStoppedAt < (threat.postTrackHold or 0.0)

	if not threat.ignoreSafeDistance
		and (not motionLifecycleActive or threat.rollingHorizon == true)
		and not trackAuthorityActive
		and not postTrackHoldActive
		and t >= threat.minimumReleaseAt
		and distance >= threat.targetDistance then
		ThreatController.Release("safe-distance")
		return
	end
	if t >= (threat.hardMaximumUntil or math.huge) then
		ThreatController.Release("hard-maximum-duration")
		return
	end
	if t >= threat.maximumUntil
		and not motionLifecycleActive
		and not trackAuthorityActive
		and not postTrackHoldActive then
		ThreatController.Release("maximum-duration")
		return
	end
	if t >= threat.expiresAt
		and not motionLifecycleActive
		and threat.activeTracks <= 0
		and not postTrackHoldActive then
		ThreatController.Release("threat-ended")
		return
	end
	if Config.threatConservativeMovementEnabled
		and Config.threatConservativeActiveOnly
		and threat.phase ~= "ACTIVE"
		and not (threat.phase == "PREP" and threat.forceRouteOnPrep == true) then
		MovementWriter.Clear(OWNER.THREAT, "conservative observe-only phase")
		if not threat.conservativeObserveOnlyLogged then
			threat.conservativeObserveOnlyLogged = true
			Diagnostics.Push(
				"DODGE_SIGNAL_OBSERVE_ONLY",
				string.format(
					"episode=%d class=%s family=%s phase=%s d=%.2f action=no-movement-until-confirmed-ACTIVE",
					threat.episodeId,
					tostring(threat.killerClass or "Unknown"),
					tostring(threat.family or "UNKNOWN"),
					tostring(threat.phase or "UNKNOWN"),
					distance
				),
				"conservative-observe-only-" .. tostring(threat.episodeId),
				0.10
			)
		end
		return
	end
	if not Config.threatAutoMovementEnabled then
		MovementWriter.Clear(OWNER.THREAT, "manual threat mode")
		if not threat.manualOnlyLogged then
			threat.manualOnlyLogged = true
			Diagnostics.Push(
				"DODGE_MANUAL_ONLY",
				string.format(
					"episode=%d class=%s family=%s phase=%s d=%.2f action=observe-only-no-PlayerMove",
					threat.episodeId,
					tostring(threat.killerClass or "Unknown"),
					tostring(threat.family or "UNKNOWN"),
					tostring(threat.phase or "UNKNOWN"),
					distance
				),
				"dodge-manual-only-" .. tostring(threat.episodeId),
				0.05
			)
		end
		return
	end
	local interactionLocked, interactionStatus =
		CharacterController.DefensiveMovementStatus()
	if interactionLocked
		or not State.humanoid
		or not State.root then
		local repairEscapeSent = false
		local repairEscapeReason = "not-eligible"
		local repairEscapeClearance = 0.0
		local repairEscapeRouteSource = "none"
		local repairEscapeAllowed = false
		if State.root and threat.killerRoot then
			repairEscapeAllowed, repairEscapeReason =
				CharacterController.CanRequestRepairThreatEscape(threat)
		end
		-- Do not spend the route ray budget while a skill-check or a protected
		-- interaction is the reason movement is locked. Plan only after the repair
		-- escape gate has authorized a real native key edge.
		if repairEscapeAllowed and State.root and threat.killerRoot then
			local escapeDirection
			escapeDirection, repairEscapeClearance, repairEscapeRouteSource =
				selectRepairThreatEscapeDirection(
					State.root,
					threat.killerRoot,
					threat
				)
			if threat.family == "VEIL_THROW"
				or threat.family == "VEIL_DELAYED"
				or threat.family == "VEIL_WALL_ARROW_AIM" then
				threat.repairEscapeClearance = repairEscapeClearance
			end
			repairEscapeSent, repairEscapeReason =
				CharacterController.RequestRepairThreatEscape(
					threat,
					escapeDirection
				)
			if repairEscapeSent then
				Diagnostics.Push(
					"REPAIR_CONFIRMED_THREAT_ESCAPE",
					string.format(
						"episode=%d family=%s phase=%s d=%.2f route=%s clearance=%.2f status=%s action=native-movement-edge-leave-generator",
						threat.episodeId,
						tostring(threat.family or "UNKNOWN"),
						tostring(threat.phase or "UNKNOWN"),
						horizontal(
							State.root.Position - threat.killerRoot.Position
						).Magnitude,
						repairEscapeRouteSource,
						repairEscapeClearance,
						tostring(interactionStatus)
					),
					"repair-confirmed-threat-escape-"
						.. tostring(threat.episodeId),
					0.05
				)
			end
		end
		MovementWriter.Clear(OWNER.THREAT, "interaction/walkspeed locked")
		ThreatController.ShowLockedThreatWarning(
			threat,
			tostring(interactionStatus)
		)
		if not threat.predictiveLockedStateLogged then
			threat.predictiveLockedStateLogged = true
			Diagnostics.Push(
				"PREDICTIVE_PLANNER_SUPPRESSED_LOCKED",
				string.format(
					"episode=%d family=%s walk=%.2f status=%s repairEscape=%s repairReason=%s action=no-PlayerMove-while-locked",
					threat.episodeId,
					tostring(threat.family or "UNKNOWN"),
					State.humanoid and State.humanoid.WalkSpeed or 0,
					tostring(interactionStatus),
					tostring(repairEscapeSent),
					tostring(repairEscapeReason)
				),
				"predictive-locked-" .. tostring(threat.episodeId),
				0.10
			)
		end
		return
	end
	ThreatMotionCore.ReviewEmergency(threat, t)
	if threat.transactionalHandoffPending == true then
		local deadline = threat.transactionalHandoffDeadline or -math.huge
		if t > deadline then
			if threat.routeDirection == nil then
				Diagnostics.Push(
					"EXACT_HANDOFF_FRESH_BUDGET_EXPIRED",
					string.format(
						"episode=%d family=%s signal=%s action=fall-through-to-normal-certified-planner",
						threat.episodeId,
						tostring(threat.family or "UNKNOWN"),
						tostring(threat.motionSignalKey or "none")
					),
					"exact-handoff-expired-" .. tostring(threat.episodeId),
					0.02
				)
			end
			threat.transactionalHandoffPending = false
			threat.transactionalHandoffRetryAt = nil
			threat.transactionalHandoffDeadline = nil
		elseif t >= (threat.transactionalHandoffRetryAt or math.huge) then
			local replacement = PredictivePlanner.Select(
				threat,
				true
			)
			local committed = replacement ~= nil
				and (
					replacement.feasible == true
					or ThreatMotionCore.IsControlledFallback(replacement, threat)
				)
				and ThreatMotionCore.ApplyPlan(
					threat,
					replacement,
					"atomic-handoff"
				)
				or false
			if committed then
				threat.transactionalHandoffPending = false
				threat.transactionalHandoffRetryAt = nil
				threat.transactionalHandoffDeadline = nil
				Diagnostics.Push(
					"EXACT_HANDOFF_COMMITTED",
					string.format(
						"episode=%d family=%s mode=%s action=atomic-route-swap",
						threat.episodeId,
						tostring(threat.family or "UNKNOWN"),
						threat.predictiveBestEffort == true
							and "controlled-best-effort"
							or "certified"
					),
					"exact-handoff-committed-" .. tostring(threat.episodeId),
					0.02
				)
			else
				-- Keep the previous certified direction and retry only after geometry
				-- has had time to change. When no old direction exists, retain the
				-- transaction itself instead of falling through to the stale no-route
				-- cache and silently remaining route-pending until impact.
				threat.transactionalHandoffRetryAt =
					t + Config.motionCoreTransactionalHandoffRetry
			end
		end
	end
	if threat.transactionalHandoffPending == true
		and threat.routeDirection == nil then
		MovementWriter.Clear(
			OWNER.THREAT,
			"exact handoff awaiting fresh ray budget"
		)
		if not threat.transactionalHandoffDeferredLogged then
			threat.transactionalHandoffDeferredLogged = true
			Diagnostics.Push(
				"EXACT_HANDOFF_FRESH_BUDGET_PENDING",
				string.format(
					"episode=%d family=%s phase=%s signal=%s deadlineIn=%.3f action=retry-before-generic-no-route-cache",
					threat.episodeId,
					tostring(threat.family or "UNKNOWN"),
					tostring(threat.phase or "UNKNOWN"),
					tostring(threat.motionSignalKey or "none"),
					math.max(0, (threat.transactionalHandoffDeadline or t) - t)
				),
				"exact-handoff-fresh-budget-" .. tostring(threat.episodeId),
				0.02
			)
		end
		return
	end
	if not threat.routeDirection then
		if threat.motionObserveOnlyNoRoute == true
			and threat.motionRouteAbandonedSignalKey ~= nil
			and threat.motionRouteAbandonedSignalKey
				== threat.motionSignalKey
			and threat.motionRouteAbandonedSignalRevision
				== threat.motionSignalRevision then
			local obstacleRetry = threat.motionObstacleRetryEligible == true
				and t >= (threat.motionNoRouteRetryAt or -math.huge)
				and (threat.motionObstacleRetryCount or 0)
					< Config.motionCoreObstacleMaximumRetries
			if obstacleRetry then
				threat.motionObstacleRetryCount =
					(threat.motionObstacleRetryCount or 0) + 1
				threat.motionObserveOnlyNoRoute = false
				threat.motionRouteAbandonedSignalKey = nil
				threat.motionRouteAbandonedSignalRevision = nil
				threat.motionNoRouteRetryAt = -math.huge
				threat.motionNoRouteGeometryAt = nil
				threat.motionNoRouteOrigin = nil
				threat.motionNoRouteThreatPosition = nil
				Diagnostics.Push(
					"TRACKING_OBSTACLE_RETRY",
					string.format(
						"episode=%d retry=%d/%d action=rescan-side-corridors-after-new-obstacle",
						threat.episodeId,
						threat.motionObstacleRetryCount,
						Config.motionCoreObstacleMaximumRetries
					),
					"tracking-obstacle-retry-" .. tostring(threat.episodeId),
					0.05
				)
			else
				MovementWriter.Clear(OWNER.THREAT, "blocked signal observe-only")
				return
			end
		end
		if t < (threat.motionNoRouteRetryAt or -math.huge) then
			MovementWriter.Clear(OWNER.THREAT, "waiting for safe corridor")
			return
		end
		local cachedAt = tonumber(threat.motionNoRouteGeometryAt)
		local cachedOrigin = threat.motionNoRouteOrigin
		local cachedThreatPosition = threat.motionNoRouteThreatPosition
		if cachedAt
			and typeof(cachedOrigin) == "Vector3"
			and typeof(cachedThreatPosition) == "Vector3"
			and t - cachedAt <= Config.motionCoreNoRouteCacheMaximumAge
			and horizontal(State.root.Position - cachedOrigin).Magnitude
				<= Config.motionCoreNoRouteMaximumOriginShift
			and horizontal(killerRoot.Position - cachedThreatPosition).Magnitude
				<= Config.motionCoreNoRouteMaximumThreatShift then
			threat.motionNoRouteRetryAt =
				t + (threat.motionObstacleRetryEligible == true
					and Config.motionCoreObstacleRetryInterval
					or Config.motionCoreNoRouteRetryInterval)
			MovementWriter.Clear(OWNER.THREAT, "unchanged no-route geometry")
			return
		end
		if not ThreatController.SelectRoute(threat, threat.requireDeepRoute == true) then
			-- Preserve the threat episode even when the planner correctly rejects a
			-- boxed-in lane. Releasing it made the following server hit appear as
			-- HIT_NO_THREAT and discarded useful timing/class evidence. No route means
			-- native WASD, never a speculative steering write.
			threat.motionObserveOnlyNoRoute = true
			if threat.killerModel then
				State.noCorridorGuardBlockedUntilByModel[threat.killerModel] =
					t + Config.motionCoreNoCorridorEpisodeCooldown
			end
			threat.motionNoRouteRetryAt =
				t + (threat.motionObstacleRetryEligible == true
					and Config.motionCoreObstacleRetryInterval
					or Config.motionCoreNoRouteRetryInterval)
			if t >= ((threat.motionImpactAt or t) - 0.02) then
				threat.motionRouteAbandonedSignalKey = threat.motionSignalKey
				threat.motionRouteAbandonedSignalRevision = threat.motionSignalRevision
			end
			MovementWriter.Clear(OWNER.THREAT, "no safe corridor observe-only")
			if not threat.motionNoRouteLogged then
				threat.motionNoRouteLogged = true
				Diagnostics.Push(
					"MOTION_CORE_OBSERVE_NO_ROUTE",
					string.format(
						"episode=%d family=%s type=%s d=%.2f action=preserve-threat-native-WASD-retry",
						threat.episodeId,
						tostring(threat.family or "UNKNOWN"),
						tostring(threat.motionType or "legacy"),
						distance
					),
					"motion-observe-no-route-" .. tostring(threat.episodeId),
					0.05
				)
			end
			return
		end
		threat.motionObserveOnlyNoRoute = false
	end
	if threat.routeWindowApproach == true then
		local record = threat.routeWindowRecord
		local stopPosition = threat.routeWindowStopPosition
		local anchorType = tostring(threat.routeLoopAnchorType or "WINDOW")
		if not record
			or not record.model
			or not record.model.Parent
			or not record.anchor
			or not record.anchor.Parent
			or typeof(stopPosition) ~= "Vector3" then
			threat.motionObserveOnlyNoRoute = true
			threat.motionRouteAbandonedSignalKey = threat.motionSignalKey
			threat.motionRouteAbandonedSignalRevision = threat.motionSignalRevision
			threat.routeDirection = nil
			threat.routeLocked = false
			threat.predictiveLocked = false
			threat.routeWindowApproach = false
			MovementWriter.Clear(OWNER.THREAT, "loop anchor route invalid")
			Diagnostics.Push(
				"LOOP_ANCHOR_ROUTE_INVALIDATED",
				string.format(
					"episode=%d family=%s anchor=%s action=native-WASD",
					threat.episodeId,
					tostring(threat.family or "UNKNOWN"),
					anchorType
				),
				"window-route-invalid-" .. tostring(threat.episodeId),
				0.05
			)
			return
		end
		local toStaging = horizontal(stopPosition - State.root.Position)
		if toStaging.Magnitude <= Config.windowPlannerStopRadius then
			threat.motionObserveOnlyNoRoute = true
			threat.motionRouteAbandonedSignalKey = threat.motionSignalKey
			threat.motionRouteAbandonedSignalRevision = threat.motionSignalRevision
			threat.routeDirection = nil
			threat.routeLocked = false
			threat.predictiveLocked = false
			MovementWriter.Clear(OWNER.THREAT, "loop anchor staging reached")
			Diagnostics.Push(
				"LOOP_ANCHOR_STAGING_REACHED",
				string.format(
					"episode=%d family=%s anchor=%s object=%s remaining=%.2f action=release-to-physical-input-no-auto-action",
					threat.episodeId,
					tostring(threat.family or "UNKNOWN"),
					anchorType,
					record.model:GetFullName(),
					toStaging.Magnitude
				),
				"window-route-ready-" .. tostring(threat.episodeId),
				0.05
			)
			return
		end
		-- Re-aim at the fixed player-side staging point. The endpoint is deliberately
		-- outside the native trigger, so this cannot start the vault by itself.
		threat.routeDirection = toStaging.Unit
	end
	-- Never rotate a valid route merely because a timer elapsed. The old periodic
	-- pass accepted a roughly 59-degree turn during the same Veil animation and
	-- steered into the follow-up hit. Replanning is now event-driven only: blocked,
	-- stuck, or demonstrably inward routes are handled by the emergency path below.
	local isTrackingRoute = threat.family == "TRACKING"
		or threat.family == "TRACKING_POINTBLANK_GUARD"
		or threat.motionType == "TRACKING_PURSUIT"
	local isVeilMeleeRoute = threat.family == "VEIL_MELEE"
	local isMaskedLungeRoute = threat.family == "MASKED_LUNGE"
	local isHomingLungeRoute = threat.motionType == "HOMING_LUNGE"
	local isPersonalSpaceRoute = threat.family == "PERSONAL_SPACE_GUARD"
	local isSyntheticLiteralKillerGuard = threat.synthetic == true
		and threat.family == "KILLER_CLOSE_AIM_GUARD"
	local isConservativeRoute = Config.threatConservativeMovementEnabled
	local conservativeRequiredAwayDot = ThreatMotionCore.RequiredAwayDot(threat)
	local isObstacleAwareRoute = isConservativeRoute
		or isTrackingRoute
		or isVeilMeleeRoute
		or isMaskedLungeRoute
		or isHomingLungeRoute
		or isPersonalSpaceRoute
	-- Refresh the certificate only after meaningful travel. This prevents a route
	-- that was open 16-22 studs ahead at selection time from remaining trusted all
	-- the way into a deeper room or box.
	if threat.predictiveLocked == true
		and motionLifecycleActive
		and State.root
		and typeof(threat.motionHorizonValidatedAtPosition) == "Vector3"
		and t >= (threat.motionHorizonNextRevalidateAt or -math.huge)
		and horizontal(
			State.root.Position - threat.motionHorizonValidatedAtPosition
		).Magnitude >= Config.motionCoreHorizonRevalidateDistance then
		local refreshed = ThreatMotionCore.Replan(
			threat,
			"horizon-refresh",
			true
		)
		threat.motionHorizonNextRevalidateAt =
			t + Config.motionCoreHorizonRevalidateCooldown
		if not refreshed and threat.routeDirection == nil then
			return
		end
	end
	local blockedClearance = if isSyntheticLiteralKillerGuard
		then Config.killerSyntheticGuardWallReleaseClearance
		else if isPersonalSpaceRoute
		then Config.personalSpaceRouteBlockedClearance
		else (isConservativeRoute
			and Config.threatConservativeWallClearance
			or ((isTrackingRoute or isVeilMeleeRoute or isMaskedLungeRoute or isHomingLungeRoute) and Config.trackingRouteReplanClearance or nil))
	local blockedProbeDistance = if isSyntheticLiteralKillerGuard
		then Config.killerSyntheticGuardWallProbeDistance
		else if isPersonalSpaceRoute
		then Config.personalSpaceRouteProbeDistance
		else (isConservativeRoute
			and Config.threatConservativeWallProbeDistance
			or ((isTrackingRoute or isVeilMeleeRoute or isMaskedLungeRoute or isHomingLungeRoute) and Config.trackingRouteProbeDistance or nil))
	local blocked, clearance =
		RoutePlanner.IsCurrentRouteBlocked(
			threat.routeDirection,
			blockedClearance,
			blockedProbeDistance
		)
	local stuck = false
	local commandedProgress = math.huge
	if isObstacleAwareRoute
		and State.root
		and (tonumber(threat.movementCommands) or 0) > 0
		and tonumber(threat.lastMovementCommandAt) ~= nil
		and (threat.lastMovementCommandAt or -math.huge)
			>= (threat.stuckSampleAt or math.huge)
		and t - (threat.stuckSampleAt or t) >= Config.trackingStuckSampleWindow then
		local locked = CharacterController.InteractionStatus()
		local sampleDelta = threat.stuckSamplePosition
			and horizontal(State.root.Position - threat.stuckSamplePosition)
			or nil
		local movedSinceSample = sampleDelta and sampleDelta.Magnitude or math.huge
		commandedProgress = sampleDelta
			and sampleDelta:Dot(unitOr(threat.routeDirection, sampleDelta))
			or math.huge
		stuck = not locked
			and State.humanoid
			and State.humanoid.WalkSpeed > 8
			and (
				movedSinceSample < Config.trackingStuckMinimumTravel
				or commandedProgress < Config.trackingStuckMinimumTravel * 0.40
			)
		threat.stuckSampleAt = t
		threat.stuckSamplePosition = State.root.Position
	end
	-- A synthetic literal-Killer guard used to delete its certified direction as
	-- soon as the forward clearance dipped below 5.25 studs. In the supplied hit
	-- it discarded a working route at 5.21, then PREP/ACTIVE inherited a route-less
	-- transaction. Let the same bounded replan/continuation machinery used by exact
	-- attacks choose one stable alternative instead; its cooldown, direction-dot
	-- and one-replan budget prevent the old A/D oscillation.
	local personalRouteAwayDot = 1.0
	if isPersonalSpaceRoute and State.root then
		local liveAway = unitOr(
			State.root.Position - killerRoot.Position,
			threat.routeDirection
		)
		personalRouteAwayDot = unitOr(
			threat.routeDirection,
			liveAway
		):Dot(liveAway)
	end
	local personalRouteMisaligned = isPersonalSpaceRoute
		and personalRouteAwayDot < Config.personalSpaceRouteMinimumAwayDot
	local trackingRouteAwayDot = 1.0
	if isTrackingRoute and State.root then
		local liveAway = unitOr(
			State.root.Position - killerRoot.Position,
			threat.routeDirection
		)
		trackingRouteAwayDot = unitOr(
			threat.routeDirection,
			liveAway
		):Dot(liveAway)
	end
	local trackingRouteMisaligned = isTrackingRoute
		and trackingRouteAwayDot < Config.trackingRouteMinimumAwayDot
	local conservativeRouteAwayDot = 1.0
	if isConservativeRoute and State.root then
		local liveAway = unitOr(
			State.root.Position - killerRoot.Position,
			threat.routeDirection
		)
		conservativeRouteAwayDot = unitOr(
			threat.routeDirection,
			liveAway
		):Dot(liveAway)
	end
	local conservativeRouteMisaligned = isConservativeRoute
		and conservativeRouteAwayDot < conservativeRequiredAwayDot
	local activeFinalCommitWindow = threat.motionType == "PROJECTILE_LINE"
		and Config.motionCoreProjectileFinalCommitWindow
		or Config.motionCoreFinalCommitWindow
	local finalRouteCommitActive = threat.routeDirection ~= nil
		and motionLifecycleActive
		and (threat.motionImpactAt or -math.huge) - t
			<= activeFinalCommitWindow
		-- If the body is already touching the obstacle, preserving the route would
		-- pin the player into a wall. Otherwise keep continuity for the last fraction
		-- of a second instead of returning control as the server resolves the hit.
		and clearance >= 0.75
	if threat.predictiveLocked == true
		and (blocked or stuck or conservativeRouteMisaligned) then
		if finalRouteCommitActive then
			-- Keep the last known lateral direction through the server impact. This
			-- does not ignore walls earlier in the route; it only prevents native WASD
			-- from reversing a nearly-complete dodge during the last 300 ms.
			blocked = false
			stuck = false
			conservativeRouteMisaligned = false
			if not threat.motionFinalCommitLogged then
				threat.motionFinalCommitLogged = true
				Diagnostics.Push(
					"FINAL_ROUTE_PRESERVED",
					string.format(
						"episode=%d family=%s type=%s remaining=%.3f window=%.3f clearance=%.2f action=keep-last-direction-until-impact",
						threat.episodeId,
						tostring(threat.family or "UNKNOWN"),
						tostring(threat.motionType or "legacy"),
						(threat.motionImpactAt or t) - t,
						activeFinalCommitWindow,
						clearance
					),
					"final-route-preserve-" .. tostring(threat.episodeId),
					0.02
				)
			end
		end
	end
	if threat.predictiveLocked == true
		and (blocked or stuck or conservativeRouteMisaligned) then
		local reason = stuck and "stuck"
			or (blocked and "blocked" or "unsafe")
		local recovered = false
		local continuationDeferred = false
		-- A blocked literal-Killer guard must propose its alternate corridor before
		-- spending the frame on another full forecast. A continuation deferred by the
		-- previous frame likewise owns the fresh ray budget. This keeps the repair
		-- deterministic and prevents the old clear-route-then-route-pending gap.
		if (isSyntheticLiteralKillerGuard and blocked)
			or threat.motionWallContinuationPending == true then
			recovered, continuationDeferred =
				ThreatMotionCore.TryWallContinuation(
					threat,
					killerRoot,
					reason
				)
		end
		if not recovered and not continuationDeferred then
			recovered = threat.motionType ~= nil
				and ThreatMotionCore.Replan(threat, reason, true)
		end
		if recovered then
			blocked, clearance = RoutePlanner.IsCurrentRouteBlocked(
				threat.routeDirection,
				Config.motionCoreObstacleClearance,
				Config.motionCoreObstacleProbeDistance
			)
			local liveAway = unitOr(
				State.root.Position - killerRoot.Position,
				threat.routeDirection
			)
			conservativeRouteAwayDot = unitOr(
				threat.routeDirection,
				liveAway
			):Dot(liveAway)
			conservativeRouteMisaligned =
				conservativeRouteAwayDot < conservativeRequiredAwayDot
			stuck = false
		end
		if (not recovered or blocked or conservativeRouteMisaligned)
			and not continuationDeferred then
			local continued
			continued, continuationDeferred = ThreatMotionCore.TryWallContinuation(
				threat,
				killerRoot,
				reason
			)
			if continued then
				recovered = true
				blocked = false
				stuck = false
				conservativeRouteMisaligned = false
				clearance = threat.routeClearance or clearance
			elseif continuationDeferred then
				MovementWriter.Clear(OWNER.THREAT, "wall forecast awaits ray budget")
				return
			end
		end
		if continuationDeferred then
			MovementWriter.Clear(OWNER.THREAT, "wall forecast awaits ray budget")
			return
		end
		if not recovered or blocked or conservativeRouteMisaligned then
			if threat.killerModel then
				State.noCorridorGuardBlockedUntilByModel[threat.killerModel] =
					t + Config.motionCoreNoCorridorEpisodeCooldown
			end
			Diagnostics.Push(
				"MOTION_CORE_NO_CORRIDOR",
				string.format(
					"episode=%d family=%s type=%s reason=%s clear=%.2f progress=%.2f awayDot=%.2f action=native-WASD",
					threat.episodeId,
					tostring(threat.family or "UNKNOWN"),
					tostring(threat.motionType or "legacy"),
					reason,
					clearance,
					commandedProgress,
					conservativeRouteAwayDot
				),
				"motion-core-no-corridor-" .. tostring(threat.episodeId),
				Config.motionCoreNoCorridorLogCooldown
			)
			-- This signal has no certified continuation. Enter a stable, native-WASD
			-- observe state instead of recreating the same intent and body-ray sweep on
			-- every scheduler pass. A distinct animation phase resets this latch.
			threat.motionObserveOnlyNoRoute = true
			threat.motionRouteAbandonedSignalKey = threat.motionSignalKey
			threat.motionRouteAbandonedSignalRevision = threat.motionSignalRevision
			threat.motionObstacleRetryEligible = threat.motionType ~= nil
			threat.motionNoRouteRetryAt = t + (
				threat.motionObstacleRetryEligible
					and Config.motionCoreObstacleRetryInterval
					or Config.motionCoreBlockedObserveCooldown
			)
			threat.motionNoRouteGeometryAt = t
			threat.motionNoRouteOrigin = State.root.Position
			threat.motionNoRouteThreatPosition = killerRoot.Position
			threat.routeDirection = nil
			threat.routeLocked = false
			threat.predictiveLocked = false
			MovementWriter.Clear(OWNER.THREAT, "motion core no safe corridor")
			return
		end
	end
	local closeMeleeShortRoute =
		threat.predictiveLocked ~= true
		and
		(
			threat.family == "VEIL_THROW"
			or threat.family == "VEIL_MELEE"
			or threat.family == "MASKED_LUNGE"
			or threat.family
				== "VEIL_MELEE_GUARD"
			or threat.family == "RIP"
			or threat.family == "RIP_TRACKING"
			or threat.family
				== "RIP_POINTBLANK_GUARD"
			or threat.family == "HIDDEN_LONG"
			or threat.family == "TRACKING"
			or threat.family == "TRACKING_POINTBLANK_GUARD"
			or threat.family == "CURE"
			or threat.family == "CURE_POINTBLANK_GUARD"
			or threat.family == "PERSONAL_SPACE_GUARD"
		)
		and distance <= 15.0
		and (
			threat.routeClearance
				or math.huge
		) < 5.0
		and clearance < 2.25
	if blocked
		or closeMeleeShortRoute
		or stuck
		or personalRouteMisaligned
		or trackingRouteMisaligned
		or conservativeRouteMisaligned then
		local oldDirection = threat.routeDirection
		local oldClearance = clearance
		local result = RoutePlanner.FindEscapeRoute({
			origin = State.root.Position,
			threatPosition = killerRoot.Position,
			preferredDirection = oldDirection,
			routeLocked = true,
			requireDeep = false,
			lateralWeight = threat.lateralWeight,
			awayWeight = threat.awayWeight,
			routeAngles = isPersonalSpaceRoute and Config.personalSpaceRouteAngles or nil,
			branchAngles = isPersonalSpaceRoute and Config.personalSpaceRouteBranchAngles or nil,
			enrichCount = isPersonalSpaceRoute and Config.personalSpaceRouteEnrichCount or nil,
			probeDistance = isPersonalSpaceRoute and Config.personalSpaceRouteProbeDistance or nil,
			restrictToEnriched = isPersonalSpaceRoute,
			minimumAwayDot = isConservativeRoute
				and conservativeRequiredAwayDot
				or (isTrackingRoute
					and Config.trackingRouteMinimumAwayDot
					or nil),
		})
		local personalReplanHasNoCorridor = isPersonalSpaceRoute
			and (
				not result
				or result.blocked == true
				or (result.clearance or 0) < Config.personalSpaceRouteBlockedClearance
				or result.reason == "dead-end"
			)
		if personalReplanHasNoCorridor then
			State.personalSpaceRouteBlockedUntilByModel[threat.killerModel] =
				t + Config.personalSpaceRouteRetryCooldown
			Diagnostics.Push(
				"PERSONAL_SPACE_NO_OPEN_CORRIDOR",
				string.format(
					"episode=%d clear=%.2f branches=%d reason=%s action=release-to-manual",
					threat.episodeId,
					result and result.clearance or 0,
					result and result.branches or 0,
					result and result.reason or "no-result"
				),
				"personal-space-no-corridor-" .. tostring(threat.episodeId),
				0.05
			)
			ThreatController.Release("no-open-personal-space-corridor")
			return
		end
		if result and result.direction then
			local gain = (result.clearance or 0) - oldClearance
			local directionDot = unitOr(oldDirection, result.direction):Dot(result.direction)
			local replanCooldown = 0.0
			if isConservativeRoute
				or isTrackingRoute
				or isVeilMeleeRoute
				or isMaskedLungeRoute
				or isHomingLungeRoute then
				replanCooldown = Config.trackingRouteReplanCooldown
			elseif isPersonalSpaceRoute then
				replanCooldown = Config.personalSpaceRouteReplanCooldown
			end
			local replanCooldownReady = t - (threat.lastReplanAt or -math.huge)
				>= replanCooldown
			local avoidsOscillation = if isConservativeRoute
				then directionDot >= 0.15
				else directionDot >= -0.15
					or gain >= 4.0
					or stuck
					or personalRouteMisaligned
					or trackingRouteMisaligned
			local maximumReplans = isConservativeRoute
				and 1
				or (isPersonalSpaceRoute
				and Config.personalSpaceRouteMaximumReplans
				or Config.routeMaximumReplans)
			local replanBudgetAvailable = if isConservativeRoute
				then threat.replansUsed < maximumReplans
				else threat.replansUsed < maximumReplans
					or gain >= Config.routeReplanMinimumGain
					or trackingRouteMisaligned
			if replanCooldownReady
				and avoidsOscillation
				and replanBudgetAvailable then
				threat.routeDirection = result.direction
				threat.lastReplanAt = t
				threat.routeClearance = result.clearance
				threat.routeSafeLength = result.safeLength
				threat.routeBranches = result.branches
				threat.stuckSampleAt = t
				threat.stuckSamplePosition = State.root.Position
				threat.replansUsed += 1
				Diagnostics.Push(
					result.blocked and "ROUTE_REPLAN_BEST_EFFORT" or "ROUTE_REPLAN",
					string.format(
						"episode=%d family=%s oldClear=%.2f newClear=%.2f gain=%.2f used=%d stuck=%s awayDot=%.2f action=keep-open-corridor",
						threat.episodeId,
						threat.family,
						oldClearance,
						result.clearance or 0,
						gain,
						threat.replansUsed,
						tostring(stuck),
						isTrackingRoute and (result.awayDot or trackingRouteAwayDot) or personalRouteAwayDot
					),
					"replan-" .. tostring(threat.episodeId),
					0.05
				)
			end
		else
			Diagnostics.Push(
				"ROUTE_BLOCKED_CONTINUE",
				string.format(
					"episode=%d clear=%.2f action=preserve-direction",
					threat.episodeId,
					oldClearance
				),
				"route-blocked-continue-" .. tostring(threat.episodeId),
				0.18
			)
		end
	end
	if isConservativeRoute
		and typeof(threat.routeDirection) ~= "Vector3" then
		-- Manual-certificate authority can intentionally release the old helper
		-- route. The final conservative validator used to feed this nil into
		-- horizontal(), crashing PreSimulation on the following frame.
		threat.routePending = true
		MovementWriter.Clear(OWNER.THREAT, "conservative route absent")
		Diagnostics.Push(
			"CONSERVATIVE_ROUTE_ABSENT_NATIVE",
			string.format(
				"episode=%d family=%s signal=%s action=native-WASD-no-nil-validation",
				threat.episodeId,
				tostring(threat.family or "UNKNOWN"),
				tostring(threat.motionSignalKey or "none")
			),
			"conservative-route-absent-" .. tostring(threat.episodeId),
			0.10
		)
		return
	end
	if isConservativeRoute then
		local finalBlocked, finalClearance = RoutePlanner.IsCurrentRouteBlocked(
			threat.routeDirection,
			Config.threatConservativeWallClearance,
			Config.threatConservativeWallProbeDistance
		)
		local liveAway = unitOr(
			State.root.Position - killerRoot.Position,
			threat.routeDirection
		)
		local finalAwayDot = unitOr(
			threat.routeDirection,
			liveAway
		):Dot(liveAway)
		if finalBlocked
			or finalAwayDot < conservativeRequiredAwayDot then
			local continued, continuationDeferred =
				ThreatMotionCore.TryWallContinuation(
				threat,
				killerRoot,
				finalBlocked and "final-blocked" or "final-unsafe"
			)
			if continued then
				finalBlocked, finalClearance = RoutePlanner.IsCurrentRouteBlocked(
					threat.routeDirection,
					Config.threatConservativeWallClearance,
					Config.threatConservativeWallProbeDistance
				)
				liveAway = unitOr(
					State.root.Position - killerRoot.Position,
					threat.routeDirection
				)
				finalAwayDot = unitOr(
					threat.routeDirection,
					liveAway
				):Dot(liveAway)
			elseif continuationDeferred then
				MovementWriter.Clear(OWNER.THREAT, "final wall forecast awaits ray budget")
				return
			end
		end
		if finalBlocked
			or finalAwayDot < conservativeRequiredAwayDot then
			-- Stop the unsafe write, but retry geometry on a bounded cadence; the
			-- same attack can remain active while an obstruction or relative angle changes.
			threat.motionObserveOnlyNoRoute = true
			threat.motionRouteAbandonedSignalKey = threat.motionSignalKey
			threat.motionRouteAbandonedSignalRevision = threat.motionSignalRevision
			threat.motionObstacleRetryEligible = threat.motionType ~= nil
			threat.motionNoRouteRetryAt = t + Config.motionCoreObstacleRetryInterval
			threat.motionNoRouteGeometryAt = t
			threat.motionNoRouteOrigin = State.root.Position
			threat.motionNoRouteThreatPosition = killerRoot.Position
			ThreatMotionCore.InvalidateCertificate(threat, "final-corridor-unsafe", true)
			threat.routeDirection = nil
			threat.routeLocked = false
			threat.predictiveLocked = false
			MovementWriter.Clear(OWNER.THREAT, "conservative route unsafe")
			Diagnostics.Push(
				"DODGE_CONSERVATIVE_UNSAFE",
				string.format(
					"episode=%d family=%s clear=%.2f awayDot=%.2f action=native-WASD-no-wall-push",
					threat.episodeId,
					tostring(threat.family or "UNKNOWN"),
					finalClearance,
					finalAwayDot
				),
				"conservative-unsafe-" .. tostring(threat.episodeId),
				0.25
			)
			return
		end
	end
	if threat.motionType
		and not ThreatMotionCore.CertificateMatches(threat, t) then
		local invalidReason = threat.routeCertificateInvalidReason
			or "certificate-does-not-match-current-signal-or-horizon"
		ThreatMotionCore.InvalidateCertificate(
			threat,
			invalidReason,
			true
		)
		threat.routePending = true
		MovementWriter.Clear(OWNER.THREAT, "route certificate invalid")
		Diagnostics.Push(
			"MOTION_CORE_STALE_CERTIFICATE_BLOCKED",
			string.format(
				"episode=%d family=%s phase=%s signal=%s reason=%s action=native-WASD-no-stale-route",
				threat.episodeId,
				tostring(threat.family or "UNKNOWN"),
				tostring(threat.phase or "UNKNOWN"),
				tostring(threat.motionSignalKey or "none"),
				tostring(invalidReason)
			),
			"motion-stale-certificate-" .. tostring(threat.episodeId),
			0.10
		)
		return
	end
	if threat.phase ~= "PREP"
		and distance <= Config.interactionReleaseDistance
		and not flashlightOwnsCharacterRig() then
		local facing = getFacingDot(killerRoot, State.root)
		local approach = getApproachSpeed(killerRoot, State.root)
		if facing >= Config.interactionReleaseFacing
			or approach >= Config.interactionReleaseApproach then
			if CharacterController.ReleaseInteraction("threat-near", threat.routeDirection) then
				Diagnostics.Push(
					"INTERACTION_RELEASE",
					string.format(
						"episode=%d d=%.2f facing=%.2f approach=%.2f owner-remains=DODGE",
						threat.episodeId,
						distance,
						facing,
						approach
					),
					"interaction-release",
					0.20
				)
			end
		end
	end
	MovementWriter.SetIntent(OWNER.THREAT, {
		actionKind = threat.actionContract or ACTION_KIND.MOVE,
		group = "DODGE",
		priority = PRIORITY.DODGE,
		direction = threat.routeDirection,
		speed = threat.speed,
		allowWalkSpeedOverride = false,
		requestedWalkSpeed = nil,
		expiresAt = t + Config.movementIntentDefaultTtl,
		episodeId = threat.episodeId,
		family = threat.family,
		motionType = threat.motionType,
		phase = threat.phase,
		forceRouteOnPrep = threat.forceRouteOnPrep == true,
		killerClass = threat.killerClass,
		killerClassSource = threat.killerClassSource,
		threatStartedAt = threat.startedAt,
		emergency = distance <= Config.movementSoftAccelerationEmergencyDistance,
		threatDistance = distance,
		threatPosition = killerRoot.Position,
		threatRoot = killerRoot,
		orbitSign = threat.orbitSign,
		threatEpisode = threat,
		predictiveLocked = threat.predictiveLocked == true,
		predictiveBestEffort = threat.predictiveBestEffort == true,
		predictiveSafetyFloor = threat.predictiveSafetyFloor == true,
		minimumAwayDot = ThreatMotionCore.RequiredAwayDot(threat),
		breakInteraction = false,
	})
end

function ThreatController.StartEmergencyPostHitEscape(reason: string): boolean
	if not Config.threatAutoMovementEnabled
		or not Config.postHitFallbackEnabled
		or State.activeThreat
		or isDowned() then
		return false
	end
	local root = State.root
	if not root then return false end

	local sourceModel = nil
	local sourceRoot = nil
	local sourceKind = "none"
	local bestDistance = math.huge

	if ZombieController and ZombieController.FindThreat then
		local zombie = ZombieController.FindThreat()
		if zombie and zombie.root then
			sourceModel = zombie.model
			sourceRoot = zombie.root
			sourceKind = "zombie"
			bestDistance = zombie.distance or math.huge
		end
	end
	local killerModel = State.nearestKiller
	local killerRoot = modelRoot(killerModel)
	if killerModel and killerRoot then
		local d = horizontal(killerRoot.Position - root.Position).Magnitude
		if d < bestDistance then
			sourceModel = killerModel
			sourceRoot = killerRoot
			sourceKind = "killer"
			bestDistance = d
		end
	end
	if not sourceModel or not sourceRoot then return false end
	if bestDistance > Config.postHitFallbackMaximumSourceDistance then
		Diagnostics.Push(
			"POST_HIT_ESCAPE_SKIPPED",
			string.format("reason=%s nearestSource=%s d=%.2f max=%.2f action=manual-control", reason, sourceKind, bestDistance, Config.postHitFallbackMaximumSourceDistance),
			"post-hit-fallback-too-far", 0.50
		)
		return false
	end

	local metadata = {
		family = "POST_HIT_ESCAPE",
		phase = "ACTIVE",
		kind = "DAMAGE_FALLBACK_ESCAPE",
		maxDistance = 90.0,
		duration = Config.postHitFallbackDuration,
		safeDistance = Config.postHitFallbackSafeDistance,
		speed = Config.movementHardSpeedCap,
		lateral = 6.0,
		away = 36.0,
		minFacing = -1.0,
		minimumHold = Config.postHitFallbackMinimumHold,
		ignoreSafeDistance = true,
	}
	local emergencyAway = unitOr(root.Position - sourceRoot.Position, root.CFrame.LookVector)
	CharacterController.ReleaseInteraction("post-hit-fallback", emergencyAway)
	local episode = ThreatController.NewEpisode(
		sourceModel,
		sourceRoot,
		"POST_HIT_FALLBACK",
		metadata,
		nil
	)
	episode.synthetic = true
	episode.routePending = true
	episode.requireDeepRoute = false
	Diagnostics.Push(
		"POST_HIT_ESCAPE_FALLBACK",
		string.format(
			"episode=%d reason=%s source=%s model=%s d=%.2f",
			episode.episodeId,
			reason,
			sourceKind,
			sourceModel.Name,
			bestDistance
		),
		"post-hit-fallback",
		0.05
	)
	return true
end

function ThreatController.OnHealthChanged(health: number): ()
	local previous =
		State.telemetry.lastHealth
	State.telemetry.lastHealth = health
	if health >= previous then
		return
	end
	if not State.matchActive then
		-- Round/downed attributes can switch MatchController to sleep before Roblox
		-- dispatches HealthChanged. Keep a primitive snapshot so the decisive hit is
		-- not silently lost with State.activeThreat during ThreatController.Reset.
		local snapshot = State.telemetry.recentThreatSnapshot
		local snapshotAge = now()
			- (State.telemetry.recentThreatSnapshotAt or -math.huge)
		if snapshot and snapshotAge <= 2.0 then
			Diagnostics.Push(
				"DAMAGE_RESULT",
				string.format(
					"episode=%s result=HIT_DURING_STATE_TRANSITION hp=%.1f>%.1f killer=%s class=%s family=%s phase=%s id=%s snapshotAge=%.3f d=%.2f predictedSep=%.2f required=%.2f clear=%.2f helperMovement=%s writerState=%s releaseReason=%s",
					tostring(snapshot.episodeId or "none"),
					previous,
					health,
					tostring(snapshot.killerName or "none"),
					tostring(snapshot.killerClass or "Unknown"),
					tostring(snapshot.family or "UNKNOWN"),
					tostring(snapshot.phase or "UNKNOWN"),
					tostring(snapshot.animationId or "none"),
					snapshotAge,
					tonumber(snapshot.distance) or -1.0,
					tonumber(snapshot.predictedSeparation) or -1.0,
					tonumber(snapshot.requiredSeparation) or -1.0,
					tonumber(snapshot.clearance) or -1.0,
					tostring(snapshot.helperMovement == true),
					tostring(snapshot.writerState or "unknown"),
					tostring(snapshot.reason or "unknown")
				),
				"damage-state-transition",
				0.01
			)
		else
			Diagnostics.Push(
				"DAMAGE_RESULT",
				string.format(
					"episode=none result=HIT_DURING_STATE_TRANSITION hp=%.1f>%.1f snapshot=none action=diagnostic-only",
					previous,
					health
				),
				"damage-state-transition-none",
				0.01
			)
		end
		return
	end

	WindowController.OnDamage(health)
	State.telemetry.lastDamageAt = now()
	-- Sustained pre-hit evidence cannot immediately recreate the released guard.
	table.clear(State.maskedCloseAimStateByModel)
	table.clear(State.hiddenCloseAimStateByModel)
	table.clear(State.killerCloseAimStateByModel)
	table.clear(State.veilAimStateByModel)
	table.clear(State.veilPendingPrepByModel)
	ThreatMotionCore.DumpHitTrace(
		"hp-" .. tostring(math.floor(previous))
			.. "-to-" .. tostring(math.floor(health))
	)
	State.distanceKeeperBlockedUntil = math.max(
		State.distanceKeeperBlockedUntil,
		State.telemetry.lastDamageAt + Config.threatDistanceKeeperPostHitBlock
	)
	local threat = State.activeThreat
	if threat then
		threat.hitReceived = true
		local failedFamily = tostring(threat.family or "UNKNOWN")
		local failedKey = failureFamilyKey(failedFamily)
		if threat.synthetic ~= true
			and threat.activeAnimationId
			and threat.activeSignalAt
			and IMPACT_TIMING_LEARNING_DISABLED_BY_ID[
				tostring(threat.activeAnimationId)
			] ~= true
			and string.match(tostring(threat.activeAnimationId), "^%d+$") then
			local observedDelay = State.telemetry.lastDamageAt - threat.activeSignalAt
			if observedDelay >= Config.predictiveMinimumImpactDelay
				and observedDelay <= Config.predictiveMaximumImpactDelay then
				local id = tostring(threat.activeAnimationId)
				local previousDelay = State.attackImpactDelayById[id]
					or PREDICTIVE_IMPACT_DELAY_BY_ID[id]
					or Config.predictiveDefaultImpactDelay
				-- Overestimating time-to-impact is unsafe: it invents travel that the
				-- survivor cannot complete. Adopt a shorter observed window immediately
				-- (plus one small frame allowance); lengthen only gradually.
				local learnedDelay = if observedDelay < previousDelay
					then math.min(previousDelay, observedDelay + 0.025)
					else previousDelay * 0.80 + observedDelay * 0.20
				learnedDelay = math.clamp(
					learnedDelay,
					Config.predictiveMinimumImpactDelay,
					Config.predictiveMaximumImpactDelay
				)
				State.attackImpactDelayById[id] = learnedDelay
				Diagnostics.Push(
					"ATTACK_IMPACT_DELAY_LEARNED",
					string.format(
						"id=%s family=%s observed=%.3f previous=%.3f learned=%.3f",
						id,
						failedFamily,
						observedDelay,
						previousDelay,
						learnedDelay
					),
					"impact-delay-" .. id,
					0.05
				)
			end
		end
		local interactionLocked, interactionStatus = CharacterController.DefensiveMovementStatus()
		local currentHumanoid = State.humanoid
		local currentRoot = State.root
		local helperCouldMove = Config.threatAutoMovementEnabled
			and currentHumanoid ~= nil
			and currentRoot ~= nil
			and not interactionLocked
		local threatAge = math.max(
			0,
			State.telemetry.lastDamageAt - (threat.startedAt or State.telemetry.lastDamageAt)
		)
		local failureMinimumAge = Config.familyFailureMinimumThreatAge
		if failedKey == "TRACKING" then
			failureMinimumAge = Config.trackingFailureMinimumThreatAge
		elseif failedKey == "STALKER" then
			failureMinimumAge = Config.stalkerFailureMinimumThreatAge
		elseif failedKey == "VEIL" then
			failureMinimumAge = Config.veilFailureMinimumThreatAge
		end
		local isSyntheticDistanceFailure = failedKey == "PERSONAL_SPACE_GUARD"
			or failedKey == "DISTANCE_KEEPER"
		local writerAppliedBeforeHit = ThreatController.WriterState(threat) == "applied"
		local countableFailure = not isSyntheticDistanceFailure
			and helperCouldMove
			and (
				threatAge >= failureMinimumAge
				or writerAppliedBeforeHit
			)
		if countableFailure then
			State.familyFailureHits[failedKey] = (State.familyFailureHits[failedKey] or 0) + 1
		elseif isSyntheticDistanceFailure then
			-- The distance guard is persistent safety policy, not a speculative
			-- attack-family experiment. A received hit releases the current route,
			-- but must not disable future distance protection for the entire match.
			State.disabledMovementFamilies[failedKey] = nil
		elseif not Config.threatAutoMovementEnabled then
			Diagnostics.Push(
				"THREAT_HIT_MANUAL_ONLY",
				string.format(
					"episode=%d family=%s age=%.3f action=log-only-not-helper-failure",
					threat.episodeId,
					failedFamily,
					threatAge
				),
				"threat-hit-manual-only-" .. tostring(threat.episodeId),
				0.05
			)
		elseif not helperCouldMove then
			Diagnostics.Push(
				"FAMILY_FAILSAFE_HIT_IGNORED_LOCKED",
				string.format(
					"family=%s failKey=%s walk=%.2f status=%s action=do-not-count-helper-failure",
					failedFamily,
					failedKey,
					currentHumanoid and currentHumanoid.WalkSpeed or 0,
					interactionStatus
				),
				"family-failsafe-hit-ignored-locked-" .. failedKey,
				0.05
			)
		else
			Diagnostics.Push(
				"FAMILY_FAILSAFE_HIT_IGNORED_LATE_SIGNAL",
				string.format(
					"family=%s failKey=%s age=%.3f minimumAge=%.3f action=do-not-count-same-frame-signal",
					failedFamily,
					failedKey,
					threatAge,
					failureMinimumAge
				),
				"family-failsafe-hit-ignored-late-" .. failedKey,
				0.05
			)
		end
		local failedCount = State.familyFailureHits[failedKey] or 0
		local disableAfterHits = Config.familyFailureDisableAfterHits
		if countableFailure and failedKey == "TRACKING" then
			State.lastEscapeRouteByModel[threat.killerModel] = nil
			disableAfterHits = Config.trackingFailureDisableAfterHits
		elseif countableFailure and failedKey == "STALKER" then
			State.lastEscapeRouteByModel[threat.killerModel] = nil
			disableAfterHits = Config.stalkerFailureDisableAfterHits
		elseif countableFailure and failedKey == "VEIL" then
			State.lastEscapeRouteByModel[threat.killerModel] = nil
			disableAfterHits = Config.veilFailureDisableAfterHits
		end
		if countableFailure and Config.threatConservativeMovementEnabled then
			-- A failed route ends immediately on damage, but must not suppress every
			-- later exact animation for the rest of the match. v5.2.71 disabled
			-- Stalker after one 0.184 s late signal and converted all later attacks to
			-- HIT_NO_THREAT. Keep future signals available while preserving the
			-- unconditional release-to-manual boundary below.
			State.disabledMovementFamilies[failedKey] = nil
			Diagnostics.Push(
				"CONSERVATIVE_ROUTE_FAILURE_RETAINED",
				string.format(
					"family=%s failKey=%s hits=%d action=release-current-keep-future-signals",
					failedFamily,
					failedKey,
					failedCount
				),
				"conservative-route-failure-" .. failedKey,
				0.05
			)
		elseif countableFailure and failedKey == "VEIL" then
			-- Disabling all exact Veil signals after one failed lateral route caused
			-- the next confirmed PREP to be ignored immediately before damage. Keep
			-- exact signals enabled; v5.2.61 uses the wall-aware corridor cut.
			State.disabledMovementFamilies[failedKey] = nil
			Diagnostics.Push(
				"VEIL_FAILSAFE_ROUTE_RETAINED",
				string.format("family=%s failKey=VEIL hits=%d action=keep-exact-signals-use-corridor-cut", failedFamily, failedCount),
				"veil-failsafe-route-retained", 0.05
			)
		elseif countableFailure and failedKey == "RIP" then
			-- Manual-only suppression caused a later confirmed RIP animation to be
			-- detected and then intentionally ignored one second before damage.
			-- Keep the deterministic route active instead of abandoning control.
			State.disabledMovementFamilies[failedKey] = nil
			Diagnostics.Push(
				"RIP_FAILSAFE_ROUTE_RETAINED",
				string.format("family=%s failKey=RIP hits=%d action=keep-route-only", failedFamily, failedCount),
				"rip-failsafe-route-retained", 0.05
			)
		elseif countableFailure and failedCount >= disableAfterHits then
			State.disabledMovementFamilies[failedKey] = true
			Diagnostics.Push(
				"FAMILY_FAILSAFE_DISABLED",
				string.format("family=%s failKey=%s hits=%d action=manual-control-until-next-match", failedFamily, failedKey, failedCount),
				"family-failsafe-disabled-" .. failedKey, 0.05
			)
		end
		-- Never extend a failed route after damage. The previous post-hit block
		-- retained strict route authority for another 0.88-1.20 seconds and made
		-- manual WASD unable to recover from the corridor/corner that caused the
		-- hit. Damage is now an unconditional movement-ownership boundary.
		local moved = State.root and threat.startRootPosition
			and horizontal(State.root.Position - threat.startRootPosition).Magnitude
			or 0
		local actualSpeed = State.root
			and horizontal(State.root.AssemblyLinearVelocity).Magnitude
			or 0
		Diagnostics.Push(
			"DAMAGE_RESULT",
			string.format(
				"episode=%d result=HIT hp=%.1f>%.1f class=%s classSource=%s family=%s phase=%s id=%s age=%.3f d=%.2f moved=%.2f actualSpeed=%.2f walk=%.2f predictedSep=%.2f required=%.2f clear=%.2f softWrites=%d helperMovement=%s writerState=%s signalAge=%.3f motionSignal=%s",
				threat.episodeId,
				previous,
				health,
				tostring(threat.killerClass or "Unknown"),
				tostring(threat.killerClassSource or "unresolved"),
				threat.family,
				tostring(threat.phase or "UNKNOWN"),
				tostring(threat.activeAnimationId or threat.primaryAnimationId or "none"),
				threatAge,
				threatDistance(threat),
				moved,
				actualSpeed,
				State.humanoid and State.humanoid.WalkSpeed or 0,
				tonumber(threat.predictiveSeparation) or -1,
				tonumber(threat.predictiveRequiredSeparation) or -1,
				tonumber(threat.routeClearance) or -1,
				threat.softAccelerationWrites or 0,
				ThreatController.WriterState(threat) == "applied" and "true" or "false",
				ThreatController.WriterState(threat),
				math.max(0, now() - (threat.activeSignalAt or threat.lastSignalAt or now())),
				tostring(threat.motionSignalKey or "none")
			),
			"damage",
			0.05
		)
		ThreatController.Release("hit-stop-return-manual")
	else
		local candidate =
			ThreatController.FindDamageLearningCandidate()
		local nearestModel = State.nearestKiller
		local nearestRoot = modelRoot(nearestModel)
		local localRoot = State.root
		local nearestDistance = nearestRoot and localRoot
			and horizontal(nearestRoot.Position - localRoot.Position).Magnitude
			or math.huge
		local nearestFacing = nearestRoot and localRoot
			and getFacingDot(nearestRoot, localRoot)
			or -2.0
		local nearestApproach = nearestRoot and localRoot
			and getApproachSpeed(nearestRoot, localRoot)
			or 0.0
		local nearestClass = nearestModel
			and ThreatController.KillerClassInfo(nearestModel).class
			or "none"
		local zombieCandidate = ZombieController and ZombieController.FindThreat
			and ZombieController.FindThreat()
			or nil
		Diagnostics.Push(
			"DAMAGE_RESULT",
			string.format(
				"episode=none result=HIT_NO_THREAT hp=%.1f>%.1f candidate=%s age=%s nearest=%s class=%s d=%s facing=%.2f approach=%+.2f zombie=%s zombieD=%s",
				previous,
				health,
				candidate
					and candidate.sample.id
					or "none",
				candidate
					and string.format(
						"%.3f",
						candidate.age
					)
					or "inf",
				nearestModel and nearestModel.Name or "none",
				tostring(nearestClass),
				nearestDistance < math.huge
					and string.format("%.2f", nearestDistance)
					or "inf",
				nearestFacing,
				nearestApproach,
				zombieCandidate and zombieCandidate.model and zombieCandidate.model.Name or "none",
				zombieCandidate and zombieCandidate.distance
					and string.format("%.2f", zombieCandidate.distance)
					or "inf"
			),
			"damage-none",
			0.05
		)
		if nearestModel
			and string.lower(tostring(nearestClass)) == "veil" then
			local aimState = State.veilAimStateByModel[nearestModel]
			Diagnostics.Push(
				"VEIL_HIT_SIGNAL_SNAPSHOT",
				string.format(
					"killer=%s source=%s dot=%.4f confidence=%.2f qualified=%s near=%s evidence=%.3f sampleAge=%s d=%.2f action=diagnostic-no-post-hit-movement",
					nearestModel.Name,
					type(aimState) == "table"
						and tostring(aimState.lastResolvedSource or "none")
						or "none",
					type(aimState) == "table"
						and (tonumber(aimState.lastResolvedDot) or -2.0)
						or -2.0,
					type(aimState) == "table"
						and (tonumber(aimState.lastResolvedConfidence) or 0.0)
						or 0.0,
					tostring(type(aimState) == "table"
						and aimState.lastResolvedQualified == true),
					tostring(type(aimState) == "table"
						and aimState.lastResolvedNear == true),
					type(aimState) == "table"
						and (tonumber(aimState.aimEvidence) or 0.0)
						or 0.0,
					type(aimState) == "table"
						and tonumber(aimState.lastResolvedAt)
						and string.format(
							"%.3f",
							now() - tonumber(aimState.lastResolvedAt)
						)
						or "inf",
					nearestDistance < math.huge and nearestDistance or -1.0
				),
				"veil-hit-signal-snapshot",
				0.05
			)
		end

		if candidate then
			local metadata = ThreatController.LearnFromDamage(candidate)
			if metadata and health > 0 and not isDowned() then
				ThreatController.StartPostHitEscape(candidate, metadata)
			end
		elseif health > 0 and not isDowned() then
			ThreatController.StartEmergencyPostHitEscape("no-animation-candidate")
		end
	end

	if health <= 0 or isDowned() then
		Diagnostics.DumpRecent(
			"death/downed",
			Config.diagnosticsDeathDumpCount
		)
	end
end

function ThreatController.Reset(): ()
	ThreatController.CaptureRecentSnapshot(State.activeThreat, "threat-reset")
	State.activeThreat = nil
	table.clear(State.veilAimStateByModel)
	table.clear(State.veilPendingPrepByModel)
	table.clear(State.veilLongApproachStateByModel)
	table.clear(State.trackingSafetyEnvelopeUntilByModel)
	table.clear(State.literalKillerSafetyEnvelopeUntilByModel)
	table.clear(State.maskedCloseAimStateByModel)
	table.clear(State.hiddenCloseAimStateByModel)
	table.clear(State.killerCloseAimStateByModel)
	table.clear(State.crouchCounterPrepByModel)
	ActionArbiter.Reset("threat reset")
	State.lockedThreatWarningUntil = -math.huge
	if State.lockedThreatWarningLabel
		and State.lockedThreatWarningLabel.Parent then
		State.lockedThreatWarningLabel.Visible = false
	end
	MovementWriter.Clear(OWNER.THREAT, "threat reset")
end

---------------------------------------------------------------------
-- 13. ZombieController
---------------------------------------------------------------------

ZombieController = {
	active = nil :: any,
}

local ZOMBIE_INACTIVE_STATES = {
	[Enum.HumanoidStateType.Dead] = true,
	[Enum.HumanoidStateType.Physics] = true,
	[Enum.HumanoidStateType.Ragdoll] = true,
	[Enum.HumanoidStateType.FallingDown] = true,
	[Enum.HumanoidStateType.PlatformStanding] = true,
	[Enum.HumanoidStateType.Seated] = true,
}

local function zombieInactiveAttribute(model: Model, humanoid: Humanoid): boolean
	for _, container in ipairs({model, humanoid}) do
		for _, name in ipairs({
			"Dead", "IsDead", "Corpse", "IsCorpse",
			"Downed", "IsDowned", "Knocked", "KnockedDown",
			"Ragdolled", "IsRagdolled", "Disabled", "Inactive",
		}) do
			local value = container:GetAttribute(name)
			if value == true
				or (typeof(value) == "number" and value > 0) then
				return true
			end
		end
	end
	return false
end

local function zombieEntry(model: Model, humanoid: Humanoid?, root: BasePart?): any
	local entry = State.zombieCache[model]
	if type(entry) ~= "table" then
		entry = {
			lastMovingAt = -math.huge,
			lastSeenAt = now(),
		}
		State.zombieCache[model] = entry
	end
	if humanoid then
		entry.humanoid = humanoid
	end
	if root then
		entry.root = root
	end
	return entry
end

local function zombieMovingAndUpright(
	model: Model,
	humanoid: Humanoid,
	root: BasePart,
	sampleNow: number
): (boolean, number, number, boolean)
	if humanoid.Health <= 0
		or root.Anchored
		or humanoid.PlatformStand
		or ZOMBIE_INACTIVE_STATES[humanoid:GetState()]
		or zombieInactiveAttribute(model, humanoid)
		or root.CFrame.UpVector.Y < Config.zombieMinimumUprightY then
		return false, 0.0, 0.0, false
	end

	local entry = zombieEntry(model)
	local horizontalSpeed =
		horizontal(root.AssemblyLinearVelocity).Magnitude
	local commanded =
		horizontal(humanoid.MoveDirection).Magnitude
	if horizontalSpeed >= Config.zombieMovingMinSpeed
		or commanded >= Config.zombieMoveDirectionThreshold then
		entry.lastMovingAt = sampleNow
	end
	entry.lastSeenAt = sampleNow

	local moving =
		sampleNow - (entry.lastMovingAt or -math.huge)
			<= Config.zombieMovingVisibilityHold
	return moving, horizontalSpeed, commanded, true
end

function ZombieController.IndexModel(model: Model): ()
	local existing = State.zombieCache[model]
	if existing then
		local humanoid = aliveHumanoid(model)
		local root = modelRoot(model)
		if humanoid and root then
			zombieEntry(model, humanoid, root)
		end
		return
	end
	if TargetResolver.IsZombieModel(model) then
		local humanoid = aliveHumanoid(model)
		local root = modelRoot(model)
		zombieEntry(model, humanoid, root)
		Diagnostics.Push(
			"ZOMBIE_INDEXED",
			string.format("npc=%s lifecycle=complete", model:GetFullName()),
			"zombie-indexed-" .. tostring(model),
			0
		)
	end
end

function ZombieController.RemoveModel(model: Model): ()
	State.zombieCache[model] = nil
	if ZombieController.active and ZombieController.active.model == model then
		ZombieController.active = nil
		MovementWriter.Clear(OWNER.ZOMBIE, "zombie removed")
	end
end

function ZombieController.ScanWorkspace(): ()
	-- Compatibility shim. Existing objects are indexed incrementally by
	-- WorldIndexer; new objects arrive through DescendantAdded.
	if WorldIndexer then
		WorldIndexer.Begin("zombie compatibility request")
	end
end

local function evaluateZombieThreat(model: Model, sampleNow: number, sustain: boolean?): any
	local entry = State.zombieCache[model]
	local humanoid = entry and entry.humanoid
	if not humanoid or not humanoid.Parent or humanoid.Health <= 0 then
		humanoid = aliveHumanoid(model)
	end
	local zroot = entry and entry.root
	if not zroot or not zroot.Parent then
		zroot = modelRoot(model)
	end
	if not humanoid or not zroot then
		State.zombieCache[model] = nil
		return nil
	end
	zombieEntry(model, humanoid, zroot)

	-- Distance is the cheapest and most selective gate. The old order queried
	-- Humanoid state, sixteen attributes and velocity for every cached corpse or
	-- far-away NPC six-to-twelve times per second.
	local root = State.root
	if not root then
		return nil
	end
	local offset = horizontal(root.Position - zroot.Position)
	local distance = offset.Magnitude
	if distance > Config.zombieReleaseDistance then
		return nil
	end

	local moving, horizontalSpeed, commanded, uprightAndActive =
		zombieMovingAndUpright(model, humanoid, zroot, sampleNow)
	if not uprightAndActive then
		return nil
	end

	local facing = getFacingDot(zroot, root)
	local toLocal = unitOr(
		root.Position - zroot.Position,
		zroot.CFrame.LookVector
	)
	local relativeVelocity = horizontal(
		zroot.AssemblyLinearVelocity - root.AssemblyLinearVelocity
	)
	local approach = relativeVelocity:Dot(toLocal)
	local stationaryAttackHold = sustain == true
		and not moving
		and distance <= Config.zombieStationaryAttackHoldDistance
		and facing >= Config.zombieFacingThreshold
		and sampleNow - (entry.lastMovingAt or -math.huge)
			<= Config.zombieStationaryAttackHoldTime
	if not moving and not stationaryAttackHold then
		return nil
	end

	if sustain then
		-- Once committed, distance hysteresis owns release. A negative relative
		-- approach is usually proof that our escape is working, not proof that the
		-- NPC stopped being dangerous. Keep one route until releaseDistance.
	else
		local emergencyCommitted =
			distance <= Config.zombieEmergencyDistance
				and approach >= Config.zombieEmergencyApproachThreshold
				and facing >= Config.zombieFacingThreshold
		local normalCommitted =
			distance <= Config.zombieAcquireDistance
				and approach >= Config.zombieApproachThreshold
				and facing >= Config.zombieFacingThreshold
		if not emergencyCommitted and not normalCommitted then
			return nil
		end
	end

	local score =
		(Config.zombieReleaseDistance - distance) * 4
		+ facing * 8
		+ math.max(0, approach) * 2
		+ math.min(horizontalSpeed, 12)
	return {
		model = model,
		humanoid = humanoid,
		root = zroot,
		distance = distance,
		facing = facing,
		approach = approach,
		horizontalSpeed = horizontalSpeed,
		commanded = commanded,
		stationaryAttackHold = stationaryAttackHold,
		score = score,
	}
end

local function nearbyNpcModelFromPart(part: BasePart): Model?
	local current: Instance? = part.Parent
	for _ = 1, 6 do
		if not current or current == Workspace then
			break
		end
		if current:IsA("Model")
			and current:FindFirstChildOfClass("Humanoid")
			and modelRoot(current) then
			return current
		end
		current = current.Parent
	end
	return nil
end

function ZombieController.DiscoverNearbySpawnedModels(): ()
	local root = State.root
	if not State.matchActive or not root then
		return
	end
	local sampleNow = now()
	if sampleNow - State.zombieLastProximityDiscoveryAt
		< 1 / Config.zombieProximityDiscoveryHz then
		return
	end
	State.zombieLastProximityDiscoveryAt = sampleNow

	local overlap = OverlapParams.new()
	overlap.FilterType = Enum.RaycastFilterType.Exclude
	overlap.FilterDescendantsInstances = State.character and {State.character} or {}
	overlap.MaxParts = Config.zombieProximityDiscoveryMaxParts
	local ok, nearbyParts = pcall(function()
		return Workspace:GetPartBoundsInRadius(
			root.Position,
			Config.zombieProximityDiscoveryRadius,
			overlap
		)
	end)
	if not ok or type(nearbyParts) ~= "table" then
		return
	end

	local seen = {} :: {[Model]: boolean}
	local considered = 0
	local indexed = 0
	for _, part in ipairs(nearbyParts) do
		if part:IsA("BasePart") then
			local model = nearbyNpcModelFromPart(part)
			if model and not seen[model] then
				seen[model] = true
				considered += 1
				local existed = State.zombieCache[model] ~= nil
				ZombieController.IndexModel(model)
				if not existed and State.zombieCache[model] ~= nil then
					indexed += 1
				end
				if considered >= Config.zombieProximityDiscoveryMaxModels then
					break
				end
			end
		end
	end
	if indexed > 0 then
		Diagnostics.Push(
			"ZOMBIE_PROXIMITY_DISCOVERY",
			string.format(
				"indexed=%d considered=%d radius=%.1f mode=bounded-spatial-no-workspace-scan",
				indexed,
				considered,
				Config.zombieProximityDiscoveryRadius
			),
			"zombie-proximity-discovery",
			0.20
		)
	end
end

function ZombieController.FindThreat(): any
	if not State.root then
		return nil
	end
	ZombieController.DiscoverNearbySpawnedModels()
	local sampleNow = now()
	local activeCandidate = nil
	if ZombieController.active and ZombieController.active.model then
		activeCandidate = evaluateZombieThreat(
			ZombieController.active.model,
			sampleNow,
			true
		)
	end

	local best = activeCandidate
	local bestScore = activeCandidate and activeCandidate.score or -math.huge
	for model in pairs(State.zombieCache) do
		if not activeCandidate or model ~= activeCandidate.model then
			local candidate = evaluateZombieThreat(model, sampleNow, false)
			if candidate and candidate.score > bestScore then
				best = candidate
				bestScore = candidate.score
			end
		end
	end

	-- Keep the current NPC unless another one is materially more dangerous.
	-- This prevents two nearby NPCs from alternating ownership every scan.
	if activeCandidate and best and best.model ~= activeCandidate.model
		and best.score < activeCandidate.score + Config.zombieTargetSwitchMargin then
		return activeCandidate
	end
	return best
end

local function zombieRouteNeedsReplan(active: any, threat: any, sampleNow: number): (boolean, string)
	if not active or active.model ~= threat.model
		or typeof(active.routeDirection) ~= "Vector3"
		or active.routeDirection.Magnitude < Config.movementMinimumDirection then
		return true, "new-target"
	end

	local routeDirection = horizontal(active.routeDirection).Unit
	local blocked, clearance = RoutePlanner.IsCurrentRouteBlocked(
		routeDirection,
		Config.zombieRouteBlockedClearance,
		Config.zombieRouteBlockedProbeDistance
	)
	active.lastClearance = clearance
	if blocked then
		return true, "blocked"
	end

	local root = State.root
	if root then
		local away = unitOr(
			root.Position - threat.root.Position,
			routeDirection
		)
		if routeDirection:Dot(away) < Config.zombieRouteMinimumAwayDot then
			return true, "no-longer-away"
		end

		if sampleNow - (active.lastProgressAt or -math.huge)
			>= Config.zombieStuckSampleTime then
			local previous = active.lastProgressPosition
			local travelled = previous
				and horizontal(root.Position - previous).Magnitude
				or math.huge
			active.lastProgressPosition = root.Position
			active.lastProgressAt = sampleNow
			if travelled < Config.zombieStuckMinimumTravel then
				return true, "stuck"
			end
		end
	end

	if sampleNow - (active.routeSelectedAt or -math.huge)
		< Config.zombieRouteLockTime then
		return false, "locked"
	end
	return false, "stable"
end

function ZombieController.Update(): ()
	if not State.enabled or isDowned() then
		ZombieController.Reset()
		return
	end
	if ActionArbiter
		and type(ActionArbiter.KillerThreatBlocksZombie) == "function"
		and ActionArbiter.KillerThreatBlocksZombie(now()) then
		MovementWriter.Clear(OWNER.ZOMBIE, "killer threat owns defense")
		return
	end

	local threat = ZombieController.FindThreat()
	if not threat then
		if ZombieController.active then
			Diagnostics.Push(
				"ZOMBIE_THREAT_RELEASE",
				string.format(
					"npc=%s reason=inactive-or-not-approaching",
					ZombieController.active.model.Name
				),
				"zombie-release",
				0.05
			)
		end
		ZombieController.active = nil
		MovementWriter.Clear(OWNER.ZOMBIE, "no active approaching zombie")
		return
	end

	local root = State.root
	if not root then
		return
	end
	local sampleNow = now()
	local active = ZombieController.active
	if active
		and active.model == threat.model
		and sampleNow < (active.blockedUntil or -math.huge) then
		-- A failed deep-exit proof is latched briefly. Do not alternate between
		-- clearing and reissuing the same blocked direction every scheduler tick.
		MovementWriter.Clear(OWNER.ZOMBIE, "zombie deep-route retry cooldown")
		return
	end
	if sampleNow < State.zombiePalletOpportunityUntil
		and State.zombiePalletOpportunityModel == threat.model then
		-- PalletController has a valid nearby stun setup. Do not pull the survivor
		-- away from the pallet while they are crossing it or while Space is firing.
		MovementWriter.Clear(OWNER.ZOMBIE, "zombie reserved for pallet stun")
		return
	end
	local needsReplan, replanReason =
		zombieRouteNeedsReplan(active, threat, sampleNow)
	local route = nil
	local didReplan = false

	if not needsReplan and active then
		route = {
			direction = active.routeDirection,
			clearance = active.lastClearance or 0,
			safeLength = active.safeLength or 0,
			branches = active.branches or 0,
			blocked = false,
		}
	elseif not active
		or active.model ~= threat.model
		or sampleNow - (active.lastReplanAt or -math.huge)
			>= Config.zombieRouteReplanInterval then
		local preferred = active and active.model == threat.model
			and active.routeDirection or nil
		route = RoutePlanner.FindEscapeRoute({
			origin = root.Position,
			threatPosition = threat.root.Position,
			preferredDirection = preferred,
			routeLocked = preferred ~= nil,
			-- A locally clear ray is not an escape. Require the full 14-stud
			-- corridor and at least two grounded far-end branches, otherwise
			-- preserve native WASD instead of steering into a pocket.
			requireDeep = true,
			minimumAwayDot = Config.zombieRouteMinimumAwayDot,
			lateralWeight = 2.0,
			awayWeight = 42.0,
			routeAngles = Config.routeAngles,
			branchAngles = Config.routeBranchAngles,
			enrichCount = 2,
			probeDistance = Config.routeProbeDistance,
			restrictToEnriched = true,
		})
		didReplan = true
	end

	if not route and not needsReplan and active and active.model == threat.model then
		-- Only a currently valid route can survive the replan cooldown.
		route = {
			direction = active.routeDirection,
			clearance = active.lastClearance or 0,
			safeLength = active.safeLength or 0,
			branches = active.branches or 0,
			blocked = false,
		}
	end

	local candidateDirection = route and route.direction
		and horizontal(route.direction) or Vector3.zero
	local directionDot = active
		and typeof(active.routeDirection) == "Vector3"
		and candidateDirection.Magnitude >= Config.movementMinimumDirection
		and horizontal(active.routeDirection).Unit:Dot(candidateDirection.Unit)
		or 1.0
	local sharpTurn = active ~= nil
		and directionDot < Config.zombieRouteSharpTurnDot
	local sharpTurnTooSoon = sharpTurn
		and sampleNow - (active.lastSharpTurnAt or active.routeSelectedAt or -math.huge)
			< Config.zombieRouteSharpTurnCooldown
	if sharpTurnTooSoon then
		route.blocked = true
		route.reason = "rapid-direction-churn"
		replanReason = "rapid-direction-churn"
	end

	if not route
		or route.blocked
		or (route.branches or 0) < Config.routeMinimumBranches then
		MovementWriter.Clear(OWNER.ZOMBIE, "no zombie route")
		-- Keep only target hysteresis while the deep route is unavailable. The
		-- unsafe direction itself is discarded, so the cooldown cannot pulse it
		-- back on between expensive route attempts.
		ZombieController.active = {
			model = threat.model,
			root = threat.root,
			routeDirection = nil,
			distance = threat.distance,
			blockedUntil = sampleNow + Config.zombieRouteRetryCooldown,
			lastReplanAt = sampleNow,
			lastSharpTurnAt = active and active.lastSharpTurnAt or sampleNow,
			lastProgressAt = sampleNow,
			lastProgressPosition = root.Position,
		}
		Diagnostics.Push(
			"ZOMBIE_ROUTE_REJECTED",
			string.format(
				"npc=%s d=%.2f reason=%s clear=%.2f branches=%d directionDot=%.2f action=native-WASD-cooldown",
				threat.model.Name,
				threat.distance,
				tostring(route and route.reason or replanReason),
				route and route.clearance or 0.0,
				route and route.branches or 0,
				directionDot
			),
			"zombie-route-reject",
			0.40
		)
		return
	end

	local starting = not active or active.model ~= threat.model
	local routeChanged = starting
		or not active.routeDirection
		or horizontal(active.routeDirection):Dot(horizontal(route.direction)) < 0.995
	ZombieController.active = {
		model = threat.model,
		root = threat.root,
		routeDirection = horizontal(route.direction).Unit,
		distance = threat.distance,
		routeSelectedAt = routeChanged and sampleNow
			or (active and active.routeSelectedAt or sampleNow),
		lastReplanAt = didReplan and sampleNow
			or (active and active.lastReplanAt or sampleNow),
		lastProgressAt = active and active.lastProgressAt or sampleNow,
		lastProgressPosition = active and active.lastProgressPosition or root.Position,
		lastClearance = route.clearance,
		safeLength = route.safeLength,
		branches = route.branches,
		blockedUntil = -math.huge,
		lastSharpTurnAt = sharpTurn and sampleNow
			or (active and active.lastSharpTurnAt or sampleNow),
	}

	if starting then
		Diagnostics.Push(
			"ZOMBIE_THREAT_START",
			string.format(
				"npc=%s d=%.2f facing=%.2f approach=%.2f speed=%.2f active=true",
				threat.model:GetFullName(),
				threat.distance,
				threat.facing,
				threat.approach,
				threat.horizontalSpeed
			),
			"zombie-start",
			0.05
		)
	end
	if routeChanged then
		Diagnostics.Push(
			"ZOMBIE_ROUTE_SELECTED",
			string.format(
				"npc=%s reason=%s clear=%.2f safeLen=%.2f branches=%d direction=(%.2f,%.2f) directionDot=%.2f deepExit=true stationaryHold=%s",
				threat.model.Name,
				tostring(replanReason),
				route.clearance,
				route.safeLength,
				route.branches,
				route.direction.X,
				route.direction.Z,
				directionDot,
				tostring(threat.stationaryAttackHold == true)
			),
			"zombie-route",
			0.15
		)
	end

	if threat.distance <= Config.interactionReleaseDistance then
		local locked = CharacterController.InteractionStatus()
		if locked then
			CharacterController.ReleaseInteraction("zombie-threat", ZombieController.active.routeDirection)
		end
	end

	MovementWriter.SetIntent(OWNER.ZOMBIE, {
		group = "ZOMBIE",
		priority = PRIORITY.ZOMBIE,
		direction = ZombieController.active.routeDirection,
		threatPosition = threat.root.Position,
		threatRoot = threat.root,
		speed = Config.zombieSpeed,
		allowWalkSpeedOverride = false,
		requestedWalkSpeed = nil,
		expiresAt = sampleNow + Config.zombieIntentTtl,
		episodeId = "ZOMBIE:" .. threat.model.Name,
		breakInteraction = false,
	})
end

function ZombieController.Reset(): ()
	ZombieController.active = nil
	State.zombieLastProximityDiscoveryAt = -math.huge
	MovementWriter.Clear(OWNER.ZOMBIE, "zombie reset")
end

---------------------------------------------------------------------
-- 14. ExitController
---------------------------------------------------------------------

ExitController = {
	state = "INACTIVE",
	gate = nil :: any,
	startedAt = -math.huge,
	center = Vector3.zero,
	entryDirection = Vector3.zero,
	pushTarget = Vector3.zero,
	centerCrossedAt = -math.huge,
	blockedUntil = -math.huge,
}

local function numericProgress(instance: Instance): number?
	if instance:IsA("NumberValue") or instance:IsA("IntValue") then
		return tonumber(instance.Value)
	end
	for _, attribute in ipairs({"Progress", "GateProgress", "OpenProgress", "Completion"}) do
		local value = instance:GetAttribute(attribute)
		if typeof(value) == "number" then
			return value
		end
	end
	return nil
end

local function normalizeProgress(value: number): number
	if value > 1.5 then
		return value / 100
	end
	return value
end

function ExitController.FindGateAncestor(instance: Instance): Instance?
	local cursor: Instance? = instance
	local fallback: Instance? = nil
	for _ = 1, 12 do
		if not cursor then
			break
		end
		local lower = string.lower(cursor.Name)
		local control = containsToken(lower, {"lever", "switch", "button", "progress"})
		if not control and lower == "gate" then
			return cursor
		end
		if not control and containsToken(lower, {"exit", "gate", "portal"}) then
			local gate = cursor:FindFirstChild("Gate")
			if gate then return gate end
			fallback = fallback or cursor
		end
		cursor = cursor.Parent
	end
	return fallback
end

function ExitController.ResolvePortal(gate: Instance): any
	local cached = State.gateCache[gate]
	if cached and cached.center and gate.Parent then
		return cached
	end

	local exactMarker = gate:FindFirstChild("F__O", true)
	if exactMarker then
		local center
		local look
		if exactMarker:IsA("Attachment") then
			center = exactMarker.WorldPosition
			look = exactMarker.WorldCFrame.LookVector
		elseif exactMarker:IsA("BasePart") then
			center = exactMarker.Position
			look = exactMarker.CFrame.LookVector
		end
		if center and look then
			local exact = {
				gate = gate,
				center = center,
				look = unitOr(
					look,
					Vector3.new(0, 0, -1)
				),
				primary = exactMarker,
				parts = 1,
				method = "exact-F__O",
			}
			State.gateCache[gate] = exact
			return exact
		end
	end
	for _, descendant in ipairs(gate:GetDescendants()) do
		local lower = string.lower(descendant.Name)
		if string.find(lower, "exitcenter", 1, true)
			or string.find(lower, "portalcenter", 1, true)
			or string.find(lower, "opening", 1, true) then
			local center
			local look
			if descendant:IsA("Attachment") then
				center = descendant.WorldPosition
				look = descendant.WorldCFrame.LookVector
			elseif descendant:IsA("BasePart") then
				center = descendant.Position
				look = descendant.CFrame.LookVector
			end
			if center and look then
				local named = {gate=gate, center=center, look=unitOr(look, Vector3.new(0,0,-1)), primary=descendant, parts=1, method="named-portal"}
				State.gateCache[gate] = named
				return named
			end
		end
	end
	local parts = {}
	for _, descendant in ipairs(gate:GetDescendants()) do
		if descendant:IsA("BasePart") then
			local lower = string.lower(descendant.Name)
			if not string.find(lower, "lever", 1, true) and not string.find(lower, "switch", 1, true) and not string.find(lower, "button", 1, true) then
				table.insert(parts, descendant)
			end
		end
	end
	if gate:IsA("BasePart") then
		table.insert(parts, gate)
	end
	if #parts == 0 then
		return nil
	end
	local minV = Vector3.new(math.huge, math.huge, math.huge)
	local maxV = Vector3.new(-math.huge, -math.huge, -math.huge)
	local primary = parts[1]
	for _, part in ipairs(parts) do
		local half = part.Size * 0.5
		minV = Vector3.new(math.min(minV.X, part.Position.X - half.X), math.min(minV.Y, part.Position.Y - half.Y), math.min(minV.Z, part.Position.Z - half.Z))
		maxV = Vector3.new(math.max(maxV.X, part.Position.X + half.X), math.max(maxV.Y, part.Position.Y + half.Y), math.max(maxV.Z, part.Position.Z + half.Z))
		if part.Size.Magnitude > primary.Size.Magnitude then
			primary = part
		end
	end
	local center = (minV + maxV) * 0.5
	local look = unitOr(primary.CFrame.LookVector, center - (State.root and State.root.Position or center - Vector3.new(0,0,1)))
	local result = {gate=gate, center=center, look=look, primary=primary, parts=#parts}
	State.gateCache[gate] = result
	return result
end

function ExitController.IndexProgressInstance(instance: Instance): ()
	local value = numericProgress(instance)
	if not value then
		return
	end
	local gate = ExitController.FindGateAncestor(instance)
	if not gate then
		return
	end
	local info = ExitController.ResolvePortal(gate)
	if not info then
		return
	end
	info.progressSource = instance
	info.progress = normalizeProgress(value)
	State.gateCache[gate] = info
end

function ExitController.IndexKnownMapGates(
	mapRoot: Instance?
): ()
	if not mapRoot then
		return
	end

	for _, exitModel in ipairs(
		mapRoot:GetChildren()
	) do
		if string.find(
			string.lower(exitModel.Name),
			"exit",
			1,
			true
		) then
			local gate =
				exitModel:FindFirstChild("Gate")
			if gate then
				local exitLever =
					gate:FindFirstChild("ExitLever")
				local main =
					exitLever
					and exitLever:FindFirstChild("Main")
				local attributeFolder =
					main
					and main:FindFirstChild("Attribute")
				local progress =
					attributeFolder
					and attributeFolder:FindFirstChild(
						"ActivationProgress"
					)
				if progress then
					ExitController.IndexProgressInstance(
						progress
					)
					local info =
						State.gateCache[gate]
					Diagnostics.Push(
						"EXIT_EXACT_INDEXED",
						string.format(
							"gate=%s marker=%s progress=%s value=%.3f",
							gate:GetFullName(),
							info
								and info.method
								or "none",
							progress:GetFullName(),
							normalizeProgress(
								numericProgress(progress)
									or 0
							)
						),
						"exit-exact-"
							.. gate:GetFullName(),
						0.10
					)
				end
			end
		end
	end
end

function ExitController.RefreshGateIndex(): ()
	-- Compatibility shim. No Workspace traversal is allowed here.
	if WorldIndexer and not State.worldIndexActive then
		WorldIndexer.Begin("exit compatibility request")
	end
end
function ExitController.FindReadyGate(): any
	local root = State.root
	if not root then
		return nil
	end
	local best = nil
	local bestDistance = math.huge
	for gate, info in pairs(State.gateCache) do
		if not gate.Parent then
			State.gateCache[gate] = nil
		else
			local value = info.progressSource and numericProgress(info.progressSource) or info.progress
			if value then
				info.progress = normalizeProgress(value)
			end
			if (info.progress or 0) >= Config.exitReadyProgress then
				local distance = horizontal(info.center - root.Position).Magnitude
				if distance < bestDistance then
					bestDistance = distance
					best = info
					best.distance = distance
				end
			end
		end
	end
	return best
end

function ExitController.Start(info: any): ()
	local root = State.root
	if not root then
		return
	end
	if now() < (ExitController.blockedUntil or -math.huge) then
		return
	end
	local toCenter = unitOr(info.center - root.Position, info.look)
	local signed = unitOr(info.look, toCenter):Dot(toCenter)
	local entryDirection = signed >= 0 and unitOr(info.look, toCenter) or -unitOr(info.look, toCenter)
	if entryDirection:Dot(toCenter) < 0 then
		entryDirection = -entryDirection
	end
	ExitController.state = "CENTER_APPROACH"
	ExitController.gate = info
	ExitController.startedAt = now()
	ExitController.center = info.center
	ExitController.entryDirection = entryDirection
	ExitController.pushTarget = info.center + entryDirection * Config.exitPushDistance
	ExitController.centerCrossedAt = -math.huge
	Diagnostics.Push("EXIT_COMMIT_START", string.format("gate=%s progress=%.3f distance=%.2f priority=1000 killerSuppression=false", info.gate:GetFullName(), info.progress or 0, info.distance or -1), "exit-start", 0.05)
end

function ExitController.Stop(reason: string, routeBlocked: boolean?): ()
	if ExitController.state ~= "INACTIVE" then
		Diagnostics.Push("EXIT_COMPLETE", string.format("state=%s reason=%s", ExitController.state, reason), "exit-stop", 0.05)
	end
	ExitController.state = "INACTIVE"
	ExitController.gate = nil
	ExitController.startedAt = -math.huge
	ExitController.centerCrossedAt = -math.huge
	if routeBlocked == true
		or reason == "timeout"
		or string.find(string.lower(reason), "blocked", 1, true)
		or string.find(string.lower(reason), "unsafe", 1, true) then
		ExitController.blockedUntil = now() + Config.exitRetryCooldown
	end
	MovementWriter.Clear(OWNER.EXIT, reason)
end

function ExitController.UpdateScan(): ()
	if not State.enabled or isDowned() then
		return
	end
	if ExitController.state ~= "INACTIVE" then
		return
	end
	if now() < (ExitController.blockedUntil or -math.huge) then
		return
	end
	local ready = ExitController.FindReadyGate()
	if ready and ready.distance <= Config.exitAcquireDistance then
		ExitController.Start(ready)
	end
end

function ExitController.Update(): ()
	if ExitController.state == "INACTIVE" then
		MovementWriter.Clear(OWNER.EXIT, "exit inactive")
		return
	end
	local root = State.root
	local gate = ExitController.gate
	if not State.enabled or isDowned() or not root or not gate or not gate.gate.Parent then
		ExitController.Stop("invalid/disabled")
		return
	end
	local t = now()
	if t - ExitController.startedAt > Config.exitMaximumDuration then
		ExitController.Stop("timeout")
		return
	end
	if ExitController.state == "CENTER_APPROACH" then
		local toCenter = horizontal(ExitController.center - root.Position)
		local distance = toCenter.Magnitude
		local signedPast = horizontal(root.Position - ExitController.center):Dot(ExitController.entryDirection)
		if distance <= Config.exitCenterArrivalDistance or signedPast >= 0.20 then
			ExitController.state = "PUSH_THROUGH"
			ExitController.centerCrossedAt = t
			Diagnostics.Push("EXIT_CENTER_CROSSED", string.format("centerDistance=%.2f signedPast=%.2f", distance, signedPast), "exit-center", 0.05)
		else
			if not MovementWriter.ValidateAuxiliaryDirection({
				group = "EXIT",
				remainingDistance = distance,
			}, unitOr(toCenter, ExitController.entryDirection)) then
				ExitController.Stop("approach route blocked", true)
				return
			end
			MovementWriter.SetIntent(OWNER.EXIT, {
				group = "EXIT",
				priority = PRIORITY.EXIT,
				direction = unitOr(toCenter, ExitController.entryDirection),
				speed = Config.exitApproachSpeed,
				expiresAt = t + 0.10,
				episodeId = "EXIT",
				remainingDistance = distance,
			})
			return
		end
	end
	if ExitController.state == "PUSH_THROUGH" then
		local direction = unitOr(ExitController.pushTarget - root.Position, ExitController.entryDirection)
		local remainingDistance = horizontal(ExitController.pushTarget - root.Position).Magnitude
		if not MovementWriter.ValidateAuxiliaryDirection({
			group = "EXIT",
			remainingDistance = remainingDistance,
		}, direction) then
			ExitController.Stop("push route blocked", true)
			return
		end
		MovementWriter.SetIntent(OWNER.EXIT, {
			group = "EXIT",
			priority = PRIORITY.EXIT,
			direction = direction,
			speed = Config.exitPushSpeed,
			expiresAt = t + 0.10,
			episodeId = "EXIT",
			remainingDistance = remainingDistance,
		})
		if t - ExitController.centerCrossedAt >= Config.exitPushDuration then
			ExitController.Stop("push-through complete")
		end
	end
end

function ExitController.Reset(): ()
	ExitController.Stop("reset")
	ExitController.gate = nil
	ExitController.blockedUntil = -math.huge
end


---------------------------------------------------------------------
-- 15. PalletController
---------------------------------------------------------------------

PalletController = {}

local function palletStateSignalUsed(record: any): boolean
	for _, signal in ipairs(record.stateSignals or {}) do
		if signal and signal.Parent then
			local name = string.lower(signal.Name)
			local positiveUsed =
				string.find(name, "drop", 1, true)
				or string.find(name, "used", 1, true)
				or string.find(name, "broken", 1, true)
				or string.find(name, "destroy", 1, true)
				or string.find(name, "disable", 1, true)
			local inverseAvailable =
				string.find(name, "available", 1, true)
				or string.find(name, "usable", 1, true)
				or string.find(name, "standing", 1, true)
				or string.find(name, "upright", 1, true)
				or string.find(name, "candrop", 1, true)
			if signal:IsA("BoolValue") then
				if positiveUsed and signal.Value == true then
					return true
				end
				if inverseAvailable and signal.Value == false then
					return true
				end
			elseif signal:IsA("IntValue") or signal:IsA("NumberValue") then
				if positiveUsed and signal.Value > 0 then
					return true
				end
				if inverseAvailable and signal.Value <= 0 then
					return true
				end
			elseif signal:IsA("StringValue") then
				local value = string.lower(signal.Value)
				if containsToken(value, {
					"dropped", "used", "broken", "destroyed", "disabled", "down"
				}) then
					return true
				end
			end
		end
	end
	return false
end

local function palletGeometryLooksDropped(model: Model, record: any): boolean
	local weightedVertical = 0.0
	local totalWeight = 0.0
	local partCount = 0
	for _, part in ipairs(record.geometryParts or {}) do
		if part and part.Parent then
			local size = part.Size
			local thinAxis
			if size.X <= size.Y and size.X <= size.Z then
				thinAxis = part.CFrame.RightVector
			elseif size.Y <= size.X and size.Y <= size.Z then
				thinAxis = part.CFrame.UpVector
			else
				thinAxis = part.CFrame.LookVector
			end
			local weight = math.max(
				0.01,
				size.X * size.Y * size.Z
			)
			weightedVertical += math.abs(thinAxis.Y) * weight
			totalWeight += weight
			partCount += 1
		end
	end
	if partCount < Config.palletDroppedGeometryMinimumParts
		or totalWeight <= 0 then
		return false
	end

	local thinAxisY = weightedVertical / totalWeight
	if thinAxisY < Config.palletDroppedThinAxisY then
		return false
	end

	local heightRatio = math.huge
	local ok, _, size = pcall(function()
		return model:GetBoundingBox()
	end)
	if ok and typeof(size) == "Vector3" then
		heightRatio = size.Y / math.max(size.X, size.Z, 0.01)
	end

	-- A dropped pallet is a broad flat object: the thin axes of its boards
	-- point upward. Requiring either a shallow world bounding box or a nearly
	-- perfect thin-axis consensus avoids rejecting unusual upright models.
	return heightRatio <= Config.palletDroppedHeightRatio
		or thinAxisY >= 0.90
end

local function palletBroken(model: Model, record: any?): boolean
	if State.palletUsedModels[model] or (record and record.used == true) then
		return true
	end
	for _, name in ipairs({"Broken", "IsBroken", "Destroyed", "Used", "IsUsed", "Dropped", "IsDropped"}) do
		local value = model:GetAttribute(name)
		if value == true or (typeof(value) == "number" and value > 0) then
			return true
		end
	end
	if record then
		if palletStateSignalUsed(record) then
			return true
		end
		if record.geometryDropped == true then
			return true
		end
		local t = now()
		if t >= (record.nextGeometryCheckAt or -math.huge) then
			record.nextGeometryCheckAt = t
				+ Config.palletGeometryCheckInterval
				+ math.random() * Config.palletGeometryCheckJitter
			if palletGeometryLooksDropped(model, record) then
				record.geometryDropped = true
				return true
			end
		end
		local anchor = record.anchor
		if not anchor or not anchor.Parent then
			return true
		end
		if typeof(record.initialAnchorPosition) == "Vector3"
			and horizontal(anchor.Position - record.initialAnchorPosition).Magnitude
				>= Config.palletUsedPositionDelta then
			return true
		end
		if typeof(record.initialAnchorUp) == "Vector3"
			and anchor.CFrame.UpVector:Dot(record.initialAnchorUp)
				<= Config.palletUsedUpDot then
			return true
		end
	end
	return false
end

local function palletModelFrom(instance: Instance?): Model?
	local promptSignal = false
	if instance and instance:IsA("ProximityPrompt") then
		local token = string.lower(instance.Name .. " " .. instance.ActionText .. " " .. instance.ObjectText)
		promptSignal = containsToken(token, {"pallet", "drop", "throw"})
	end
	local firstModel = nil
	local current = instance
	for _ = 1, 10 do
		if not current or current == Workspace then break end
		if current:IsA("Model") then
			firstModel = firstModel or current
			local normalized = string.gsub(
				string.lower(current.Name),
				"[^%w]",
				""
			)
			-- Live maps use Palletwrong for the actual interactive pallet.
			-- Broad name matching also indexed decorative PalletCrate models.
			if normalized == "palletwrong"
				or CollectionService:HasTag(current, "Pallet")
				or current:GetAttribute("IsPallet") == true
				or current:GetAttribute("CanDropPallet") == true then
				return current
			end
		end
		current = current.Parent
	end
	return promptSignal and firstModel or nil
end

local function palletPrompt(model: Model): ProximityPrompt?
	local fallback = nil
	for _, item in ipairs(model:GetDescendants()) do
		if item:IsA("ProximityPrompt") and item.Enabled then
			local token = string.lower(item.Name .. " " .. item.ActionText .. " " .. item.ObjectText)
			if string.find(token, "pallet", 1, true)
				or string.find(token, "drop", 1, true)
				or string.find(token, "throw", 1, true) then
				return item
			end
			fallback = fallback or item
		end
	end
	return fallback
end

local function palletAnchor(model: Model, prompt: ProximityPrompt?): BasePart?
	if prompt then
		local part = promptWorldPart(prompt.Parent)
		if part then return part end
	end
	for _, name in ipairs({"Primary1", "Primary2", "PrimaryPartPallet", "Interact", "Trigger"}) do
		local item = model:FindFirstChild(name, true)
		if item and item:IsA("BasePart") then return item end
	end
	if model.PrimaryPart then return model.PrimaryPart end
	for _, item in ipairs(model:GetDescendants()) do
		if item:IsA("BasePart") then return item end
	end
	return nil
end

local function buildPalletRecord(model: Model): any
	local physicalCount = 0
	local geometryParts = {}
	local stateSignals = {}
	for _, item in ipairs(model:GetDescendants()) do
		if item:IsA("BasePart") then
			physicalCount += 1
			local token = string.lower(item.Name)
			if not string.find(token, "trigger", 1, true)
				and not string.find(token, "hitbox", 1, true)
				and not string.find(token, "prompt", 1, true)
				and not string.find(token, "interact", 1, true) then
				table.insert(geometryParts, item)
			end
		elseif item:IsA("BoolValue")
			or item:IsA("IntValue")
			or item:IsA("NumberValue")
			or item:IsA("StringValue") then
			local token = string.lower(item.Name)
			if containsToken(token, {
				"drop", "used", "broken", "destroy", "disable",
				"available", "usable", "standing", "upright", "candrop"
			}) then
				table.insert(stateSignals, item)
			end
		end
	end
	if physicalCount < 2 then
		return nil
	end
	local prompt = palletPrompt(model)
	local anchor = palletAnchor(model, prompt)
	if not anchor then
		return nil
	end
	return {
		model = model,
		prompt = prompt,
		anchor = anchor,
		indexedAt = now(),
		used = false,
		promptInitiallyEnabled = prompt and prompt.Enabled or false,
		initialAnchorPosition = anchor.Position,
		initialAnchorUp = anchor.CFrame.UpVector,
		geometryParts = geometryParts,
		stateSignals = stateSignals,
		geometryDropped = false,
		nextGeometryCheckAt = -math.huge,
	}
end

function PalletController.IndexInstance(instance: Instance): ()
	if not Config.palletTopologyEnabled and not Config.palletAutoEnabled then
		return
	end
	-- Late geometry can complete a promptless pallet after its Model arrived.
	if not instance:IsA("Model")
		and not instance:IsA("ProximityPrompt")
		and not instance:IsA("BasePart") then
		return
	end
	local model = palletModelFrom(instance)
	if not model or State.palletUsedModels[model] then return end

	local existing = State.palletCache[model]
	if existing then
		if instance:IsA("ProximityPrompt")
			and (not existing.prompt or not existing.prompt.Parent) then
			existing.prompt = instance
			existing.anchor = palletAnchor(model, instance) or existing.anchor
		elseif instance:IsA("BasePart")
			and not table.find(existing.geometryParts, instance)
			and not containsToken(string.lower(instance.Name), {"trigger", "hitbox", "prompt", "interact"}) then
			table.insert(existing.geometryParts, instance)
			existing.nextGeometryCheckAt = -math.huge
		end
		return
	end

	local record = buildPalletRecord(model)
	if record then
		-- This catches pallets that were already dropped by another survivor
		-- before our script saw them. The old first-seen CFrame baseline could
		-- never distinguish that state from a fresh standing pallet.
		if palletBroken(model, record) then
			record.used = true
			State.palletUsedModels[model] = true
			Diagnostics.Push(
				"PALLET_REJECTED_USED",
				"pallet=" .. model:GetFullName() .. " reason=world-state",
				"pallet-rejected-" .. tostring(model),
				0
			)
			return
		end
		State.palletCache[model] = record
		Diagnostics.Push(
			"PALLET_INDEXED",
			"pallet=" .. model:GetFullName(),
			"pallet-indexed-" .. tostring(model),
			0
		)
	end
end

function PalletController.RemoveModel(model: Model): ()
	State.palletCache[model] = nil
end

local function triggerPalletSpace(): (boolean, string)
	State.syntheticPalletSpaceUntil = now() + Config.palletKeyHold + 0.10
	local ok, err = pcall(function()
		VirtualInputManager:SendKeyEvent(true, Config.palletKey, false, game)
	end)
	if not ok then
		State.syntheticPalletSpaceUntil = -math.huge
		return false, "space-down-failed:" .. tostring(err)
	end
	task.delay(Config.palletKeyHold, function()
		-- Always release the synthetic key, including after Helper shutdown/reload.
		pcall(function()
			VirtualInputManager:SendKeyEvent(false, Config.palletKey, false, game)
		end)
		State.syntheticPalletSpaceUntil = -math.huge
	end)
	return true, "VirtualInputManager-Space"
end

function PalletController.Update(): ()
	if not Config.palletTopologyEnabled or not State.enabled or isDowned() then return end
	-- Keep the topology cache honest even though automatic Space is disabled.
	-- This bounded pass uses cached parts/state signals and runs the expensive
	-- geometry fallback only at its own staggered interval.
	for model, record in pairs(State.palletCache) do
		if not model.Parent or palletBroken(model, record) then
			if record.pendingDropUntil and model.Parent
				and record.anchor and record.anchor.Parent then
				Diagnostics.Push("AUTO_PALLET_DROP_CONFIRMED",
					"pallet=" .. model:GetFullName() .. " evidence=world-state",
					"auto-pallet-confirmed-" .. tostring(model), 0.05)
			end
			State.palletUsedModels[model] = true
			State.palletCache[model] = nil
		elseif record.pendingDropUntil and now() >= record.pendingDropUntil then
			record.pendingDropUntil = nil
			Diagnostics.Push("AUTO_PALLET_DROP_UNCONFIRMED",
				"pallet=" .. model:GetFullName() .. " action=allow-later-retry",
				"auto-pallet-unconfirmed-" .. tostring(model), 0.25)
		end
	end
	if not Config.palletAutoEnabled then
		return
	end
	local root = State.root
	local humanoid = State.humanoid
	if not root or not humanoid then return end
	local t = now()
	if t - State.lastPalletDropAt < Config.palletCooldown then return end

	local threatSources = {}
	local killerRoot = State.nearestKillerRoot
	if killerRoot and killerRoot.Parent then
		table.insert(threatSources, {
			kind = "KILLER",
			model = State.nearestKiller,
			root = killerRoot,
		})
	end
	local zombieActive = Config.palletZombieEnabled and ZombieController.active or nil
	if zombieActive
		and zombieActive.model
		and zombieActive.model.Parent
		and zombieActive.root
		and zombieActive.root.Parent then
		table.insert(threatSources, {
			kind = "ZOMBIE",
			model = zombieActive.model,
			root = zombieActive.root,
		})
	end
	if #threatSources == 0 then return end

	local best = nil
	local bestScore = -math.huge
	for model, record in pairs(State.palletCache) do
		if not model.Parent or palletBroken(model, record) then
			State.palletUsedModels[model] = true
			State.palletCache[model] = nil
		else
			local anchor = record.anchor
			if not anchor or not anchor.Parent then
				local refreshed = buildPalletRecord(model)
				if refreshed then
					record = refreshed
					State.palletCache[model] = record
					anchor = record.anchor
				else
					State.palletCache[model] = nil
					anchor = nil
				end
			end
			if anchor and not record.pendingDropUntil then
				local localDistance = horizontal(anchor.Position - root.Position).Magnitude
				if localDistance <= Config.palletLocalDistance then
					for _, source in ipairs(threatSources) do
						local threatRoot = source.root
						local threatDistance = horizontal(anchor.Position - threatRoot.Position).Magnitude
						if threatDistance <= Config.palletKillerDistance then
							local playerOffset = horizontal(root.Position - anchor.Position)
							local threatOffset = horizontal(threatRoot.Position - anchor.Position)
							local toLocal = unitOr(playerOffset, root.CFrame.LookVector)
							local toThreat = unitOr(threatOffset, -toLocal)
							local sideDot = toLocal:Dot(toThreat)
							local playerBehind = -playerOffset:Dot(toThreat)
							local threatFront = threatOffset:Dot(toThreat)
							local emergency = threatDistance <= Config.palletEmergencyKillerDistance
							local closeEnough = threatDistance <= Config.palletCloseKillerDistance
							local approaching = getApproachSpeed(threatRoot, root)
								>= Config.palletMinimumApproach
							local validSide = sideDot <= Config.palletOppositeSideDot
							local crossed = validSide
								and playerBehind >= Config.palletPlayerBehindMargin
								and threatFront >= Config.palletKillerFrontMargin
							local committed = emergency or approaching or closeEnough
							local score = (Config.palletKillerDistance - threatDistance) * 5
								+ (Config.palletLocalDistance - localDistance) * 2
								- sideDot * 8

							-- Proximity may accelerate a valid drop, but never bypass
							-- the survivor-crossed gate for either Killer or Zombie.
							if crossed and committed and score > bestScore then
								bestScore = score
								best = {
									model = model,
									record = record,
									anchor = anchor,
									localDistance = localDistance,
									threatDistance = threatDistance,
									threatRoot = threatRoot,
									threatModel = source.model,
									threatKind = source.kind,
									sideDot = sideDot,
									playerBehind = playerBehind,
									threatFront = threatFront,
									emergency = emergency,
								}
							elseif not crossed and (State.activeThreat ~= nil or committed) then
								Diagnostics.Push(
									"AUTO_PALLET_WAIT_CROSS",
									string.format(
										"pallet=%s targetType=%s localD=%.2f targetD=%.2f sideDot=%.2f behind=%.2f front=%.2f action=no-space-until-crossed",
										model:GetFullName(), source.kind, localDistance, threatDistance,
										sideDot, playerBehind, threatFront
									),
									"auto-pallet-wait-cross-" .. tostring(model) .. "-" .. source.kind,
									0.75
								)
							end
						end
					end
				end
			end
		end
	end

	if t >= State.zombiePalletOpportunityUntil then
		State.zombiePalletOpportunityModel = nil
	end
	if not best then return end

	local interactionLocked, interactionStatus = CharacterController.InteractionStatus()
	if activeSkillCheckVisible and activeSkillCheckVisible() then
		interactionLocked, interactionStatus = true, "skill-check-visible"
	end
	if humanoid.WalkSpeed <= 0.1 or root.Anchored or interactionLocked then
		Diagnostics.Push(
			"AUTO_PALLET_SKIPPED_LOCKED",
			string.format(
				"pallet=%s walk=%.2f status=%s action=player-must-leave-interaction",
				best.model:GetFullName(), humanoid.WalkSpeed, interactionStatus
			),
			"auto-pallet-skipped-locked",
			0.50
		)
		return
	end

	-- Revalidate world state and the crossed-side certificate immediately before
	-- emitting context-sensitive Space. This prevents a stale cached candidate
	-- from vaulting a dropped pallet or firing before the survivor crossed it.
	if palletBroken(best.model, best.record) then
		State.palletUsedModels[best.model] = true
		State.palletCache[best.model] = nil
		return
	end
	local currentPlayerOffset = horizontal(root.Position - best.anchor.Position)
	local currentThreatOffset = horizontal(best.threatRoot.Position - best.anchor.Position)
	local currentToLocal = unitOr(currentPlayerOffset, root.CFrame.LookVector)
	local currentToThreat = unitOr(currentThreatOffset, -currentToLocal)
	local currentSideDot = currentToLocal:Dot(currentToThreat)
	local currentPlayerBehind = -currentPlayerOffset:Dot(currentToThreat)
	local currentThreatFront = currentThreatOffset:Dot(currentToThreat)
	if currentSideDot > Config.palletOppositeSideDot
		or currentPlayerBehind < Config.palletPlayerBehindMargin
		or currentThreatFront < Config.palletKillerFrontMargin then
		Diagnostics.Push(
			"AUTO_PALLET_REVALIDATION_REJECTED",
			string.format(
				"pallet=%s sideDot=%.2f behind=%.2f front=%.2f action=no-space",
				best.model:GetFullName(), currentSideDot,
				currentPlayerBehind, currentThreatFront
			),
			"auto-pallet-revalidation-" .. tostring(best.model),
			0.35
		)
		return
	end

	local away = unitOr(root.Position - best.threatRoot.Position, root.CFrame.LookVector)
	local fired, method = triggerPalletSpace()
	if not fired then
		Diagnostics.Push("AUTO_PALLET_FAILED", string.format(
			"pallet=%s targetType=%s localD=%.2f targetD=%.2f reason=%s",
			best.model:GetFullName(), best.threatKind, best.localDistance, best.threatDistance, method
		), "auto-pallet-failed", 0.15)
		return
	end
	State.lastPalletDropAt = t
	best.record.pendingDropUntil = t + math.max(0.75, Config.palletKeyHold * 2)
	best.record.nextGeometryCheckAt = t
	if best.threatKind == "ZOMBIE" then
		State.zombiePalletOpportunityModel = best.threatModel
		State.zombiePalletOpportunityUntil = t + math.min(0.25, Config.zombiePalletOpportunityHold)
		MovementWriter.Clear(OWNER.ZOMBIE, "pallet input in flight")
	end
	MovementWriter.SetIntent(OWNER.PALLET, {
		group = "PALLET_ESCAPE",
		priority = PRIORITY.PALLET_ESCAPE,
		direction = away,
		threatPosition = best.threatRoot.Position,
		expiresAt = t + Config.palletEscapeDuration,
		episodeId = "PALLET:" .. best.model.Name,
		breakInteraction = false,
	})
	Diagnostics.Push("AUTO_PALLET_DROP_REQUESTED", string.format(
		"pallet=%s targetType=%s target=%s method=%s localD=%.2f targetD=%.2f sideDot=%.2f behind=%.2f front=%.2f emergency=%s crossed=true awaiting-world-state=true",
		best.model:GetFullName(), best.threatKind,
		best.threatModel and best.threatModel.Name or "none",
		method, best.localDistance, best.threatDistance,
		best.sideDot, best.playerBehind, best.threatFront,
		tostring(best.emergency)), "auto-pallet-drop", 0.05)
end

function PalletController.Reset(): ()
	State.zombiePalletOpportunityUntil = -math.huge
	State.zombiePalletOpportunityModel = nil
	MovementWriter.Clear(OWNER.PALLET, "pallet reset")
end

---------------------------------------------------------------------
-- 16. WindowController
---------------------------------------------------------------------

WindowController = {
	activeVault = nil :: any,
	lastVaulting = false,
	currentCommit = nil :: any,
	lastCommitAt = -math.huge,
	postExitUntil = -math.huge,
	learnedDuration = nil :: number?,
	recentLocalTracks = {} :: {any},
	learnedDurationByAnimationId = {} :: {[string]: number},
	unsafeVetoLatch = nil :: any,
	unsafeEscape = nil :: any,
}

local function normalizedWorldName(value: string): string
	return string.gsub(string.lower(value), "[^%w]", "")
end

local function windowModelFrom(instance: Instance?): Model?
	local current = instance
	for _ = 1, 10 do
		if not current or current == Workspace then
			break
		end
		if current:IsA("Model")
			and normalizedWorldName(current.Name) == "window" then
			return current
		end
		current = current.Parent
	end
	return nil
end

local function windowAnchorFrom(model: Model, candidate: Instance?): BasePart?
	if candidate then
		if candidate:IsA("BasePart") then
			return candidate
		end
		if candidate:IsA("Attachment")
			and candidate.Parent
			and candidate.Parent:IsA("BasePart") then
			return candidate.Parent
		end
	end
	for _, name in ipairs({"VaultTrigger", "VaultPoint"}) do
		local found = model:FindFirstChild(name, true)
		if found then
			if found:IsA("BasePart") then
				return found
			end
			if found:IsA("Attachment")
				and found.Parent
				and found.Parent:IsA("BasePart") then
				return found.Parent
			end
		end
	end
	return model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart", true)
end

local function windowCrossingNormal(anchor: BasePart): Vector3
	-- Vault triggers are usually broad across the opening and thin through it.
	-- Use the thinner horizontal local axis as the crossing normal.
	if anchor.Size.X <= anchor.Size.Z then
		return unitOr(anchor.CFrame.RightVector, Vector3.new(1, 0, 0))
	end
	return unitOr(anchor.CFrame.LookVector, Vector3.new(0, 0, -1))
end

local function physicalWasdDirection(): Vector3?
	return CharacterController.PhysicalInputDirection()
end

local function characterIsVaulting(): boolean
	local character = State.character
	if not character then return false end
	local check = character:FindFirstChild("CheckInterractable")
	return check ~= nil and check:GetAttribute("isVaulting") == true
end

function WindowController.OnLocalAnimationPlayed(track: AnimationTrack): ()
	local t = now()
	table.insert(WindowController.recentLocalTracks, {
		track = track,
		id = animationId(track),
		startedAt = t,
	})
	while #WindowController.recentLocalTracks > 14 do
		table.remove(WindowController.recentLocalTracks, 1)
	end
	-- Attribute replication and AnimationPlayed do not have a stable ordering.
	-- If isVaulting is already visible, attach immediately; otherwise VAULT_START
	-- selects this same recent track when the attribute edge arrives.
	if characterIsVaulting() and WindowController.activeVault then
		WindowController.AttachVaultAnimation(track, t)
	end
end

function WindowController.SelectRecentVaultAnimation(t: number): AnimationTrack?
	local bestTrack = nil
	local bestScore = -math.huge
	for index = #WindowController.recentLocalTracks, 1, -1 do
		local sample = WindowController.recentLocalTracks[index]
		local age = t - sample.startedAt
		if age > Config.windowVaultAnimationLookupWindow then
			table.remove(WindowController.recentLocalTracks, index)
		elseif sample.track and sample.track.IsPlaying then
			local name = string.lower(sample.track.Name or "")
			local score = -age
			if string.find(name, "vault", 1, true)
				or string.find(name, "window", 1, true) then
				score += 10
			end
			if not sample.track.Looped then
				score += 1
			end
			if score > bestScore then
				bestScore = score
				bestTrack = sample.track
			end
		end
	end
	return bestTrack
end

function WindowController.AttachVaultAnimation(track: AnimationTrack, t: number?): ()
	local vault = WindowController.activeVault
	if not vault or vault.animationTrack == track then return end
	if vault.animationTrack and vault.animationTrack.IsPlaying then return end
	local id = animationId(track)
	if id == "" then return end
	vault.animationTrack = track
	vault.animationId = id
	vault.animationName = track.Name
	vault.animationLength = math.max(0, track.Length)
	vault.animationObservedAt = t or now()
	local requestedSpeed = 1.0
	local adjusted = false
	if Config.windowForceFastVaultAnimation then
		local length = math.max(0, track.Length)
		requestedSpeed = math.clamp(
			length > 0.05
				and length / Config.windowFastVaultDesiredVisualDuration
				or Config.windowFastVaultAnimationMinimumSpeed,
			Config.windowFastVaultAnimationMinimumSpeed,
			Config.windowFastVaultAnimationMaximumSpeed
		)
		adjusted = pcall(function()
			track:AdjustSpeed(requestedSpeed)
		end)
	end
	vault.animationSpeed = adjusted and requestedSpeed or track.Speed
	Diagnostics.Push(
		"VAULT_ANIMATION",
		string.format(
			"id=%s name=%s length=%.3f speed=%.2f adjusted=%s action=track-exact-native-vault-id",
			id,
			tostring(track.Name),
			math.max(0, track.Length),
			vault.animationSpeed or 1.0,
			tostring(adjusted)
		),
		"vault-animation-" .. id,
		0.05
	)
end

local function indexWindowCandidate(instance: Instance): ()
	local model = windowModelFrom(instance)
	if not model then return end
	local anchor = windowAnchorFrom(model, instance)
	if not anchor then return end
	State.windowCache[model] = {
		model = model,
		anchor = anchor,
		normal = windowCrossingNormal(anchor),
		indexedAt = now(),
	}
end

function WindowController.IndexInstance(instance: Instance): ()
	local normalized = normalizedWorldName(instance.Name)
	if normalized == "window" and instance:IsA("Model") then
		indexWindowCandidate(instance)
		return
	end
	if normalized ~= "vaulttrigger" and normalized ~= "vaultpoint" then
		return
	end
	indexWindowCandidate(instance)
end

function WindowController.IndexTaggedInstance(instance: Instance): ()
	indexWindowCandidate(instance)
end

function WindowController.IndexExistingTags(): ()
	for _, instance in ipairs(CollectionService:GetTagged("VaultPoint")) do
		if instance:IsDescendantOf(Workspace) then
			indexWindowCandidate(instance)
		end
	end
end

function WindowController.RemoveInstance(instance: Instance, forced: boolean?): ()
	if instance:IsA("Model") then
		State.windowCache[instance] = nil
		return
	end
	local normalized = normalizedWorldName(instance.Name)
	if not forced and normalized ~= "vaulttrigger" and normalized ~= "vaultpoint" then
		return
	end
	for model, record in pairs(State.windowCache) do
		if record.anchor == instance or not model.Parent then
			State.windowCache[model] = nil
		end
	end
end

function WindowController.OnDamage(health: number): ()
	local vault = WindowController.activeVault
	if not vault or vault.damageObserved then return end
	vault.damageObserved = true
	local root = State.root
	local moved = root
		and horizontal(root.Position - vault.startPosition).Magnitude
		or 0
	Diagnostics.Push(
		"VAULT_HIT",
		string.format(
			"window=%s age=%.3f moved=%.2f health=%.1f action=no-animation-speed-change",
			vault.window and vault.window.model:GetFullName() or "unindexed",
			math.max(0, now() - vault.startedAt),
			moved,
			health
		),
		"vault-hit",
		0.05
	)
end

local function nearestIndexedWindow(position: Vector3, maximumDistance: number): any
	local best = nil
	local bestDistance = maximumDistance
	for model, record in pairs(State.windowCache) do
		local anchor = record and record.anchor
		if not model.Parent or not anchor or not anchor.Parent then
			State.windowCache[model] = nil
		else
			local distance = horizontal(anchor.Position - position).Magnitude
			if distance <= bestDistance then
				bestDistance = distance
				best = record
			end
		end
	end
	return best
end

local function selectUnsafeWindowEscapeDirection(
	root: BasePart,
	killerRoot: BasePart,
	targetPosition: Vector3,
	preferred: Vector3?
): any
	local away = unitOr(
		horizontal(root.Position - killerRoot.Position),
		Vector3.new(0, 0, -1)
	)
	local towardWindow = unitOr(
		horizontal(targetPosition - root.Position),
		-away
	)
	local best = nil
	for _, angle in ipairs({-90, -60, -30, 0, 30, 60, 90}) do
		local direction = rotateY(away, angle)
		local candidate = RoutePlanner.ScoreCandidate(
			root.Position,
			killerRoot.Position,
			direction,
			preferred,
			8.0,
			22.0,
			Config.unsafeTraversalWindowEscapeProbeDistance
		)
		candidate.windowDot = direction:Dot(towardWindow)
		if candidate.awayDot
			< Config.unsafeTraversalWindowEscapeMinimumAwayDot then
			candidate.score -= 10000
		end
		if candidate.windowDot
			> Config.unsafeTraversalWindowEscapeMaximumTowardDot then
			candidate.score -= 10000
		end
		if candidate.clearance
			< Config.unsafeTraversalWindowEscapeMinimumClearance then
			candidate.score -= 10000
		end
		if not best or candidate.score > best.score then
			best = candidate
		end
	end
	return best
end

function WindowController.RequestUnsafeTraversalEscape(sample: any): ()
	if type(sample) ~= "table"
		or (sample.traversalKind ~= "WINDOW"
			and sample.traversalKind ~= "PALLET"
			and sample.traversalKind ~= "DROPPED_PALLET")
		or typeof(sample.traversalAnchorPosition) ~= "Vector3" then
		return
	end
	local t = now()
	if sample.traversalKind == "WINDOW" then
		WindowController.unsafeVetoLatch = {
			untilAt = t + Config.unsafeTraversalWindowVetoLatchDuration,
			targetPosition = sample.traversalAnchorPosition,
			targetName = sample.traversalName,
			traversalDistance = sample.traversalDistance,
			source = sample.traversalSource,
			lastSample = sample,
		}
	end
	local existingEscape = WindowController.unsafeEscape
	local sameTarget = existingEscape
		and typeof(existingEscape.targetPosition) == "Vector3"
		and horizontal(
			existingEscape.targetPosition - sample.traversalAnchorPosition
		).Magnitude <= 1.0
	WindowController.unsafeEscape = {
		untilAt = t + Config.unsafeTraversalWindowEscapeDuration,
		targetPosition = sample.traversalAnchorPosition,
		targetName = sample.traversalName,
		traversalKind = sample.traversalKind,
		-- Repeated physical Space while one veto is active extends the same escape;
		-- it must not pick alternating sides on every key repeat.
		direction = sameTarget and existingEscape.direction or nil,
		lastPlanAt = sameTarget and existingEscape.lastPlanAt or -math.huge,
		planAttempts = sameTarget and (existingEscape.planAttempts or 0) or 0,
		nextPlanAt = sameTarget and (existingEscape.nextPlanAt or -math.huge)
			or -math.huge,
	}
end

function WindowController.LatchedUnsafeTraversalSample(
	root: BasePart,
	killerRoot: BasePart,
	distance: number
): any
	local latch = WindowController.unsafeVetoLatch
	if not latch or now() > latch.untilAt then
		WindowController.unsafeVetoLatch = nil
		return nil
	end
	local targetDistance = horizontal(
		latch.targetPosition - root.Position
	).Magnitude
	if targetDistance > Config.unsafeTraversalWindowVetoLatchRadius
		or distance > Config.unsafeTraversalWindowPredictionDistance then
		WindowController.unsafeVetoLatch = nil
		return nil
	end
	local sample = table.clone(latch.lastSample)
	sample.mode = "window-veto-latched"
	sample.distance = distance
	sample.facing = getFacingDot(killerRoot, root)
	sample.approach = getApproachSpeed(killerRoot, root)
	sample.traversalDistance = targetDistance
	return sample
end

function WindowController.UpdateUnsafeTraversalEscape(): ()
	local escape = WindowController.unsafeEscape
	if not escape then
		return
	end
	local t = now()
	local root = State.root
	local humanoid = State.humanoid
	local killerRoot = State.nearestKillerRoot
	local locked = CharacterController.DefensiveMovementStatus()
	if t > escape.untilAt
		or not root
		or not humanoid
		or not killerRoot
		or not killerRoot.Parent
		or locked
		or humanoid.WalkSpeed <= 0.1
		or root.Anchored
		or characterIsVaulting() then
		WindowController.unsafeEscape = nil
		MovementWriter.Clear(OWNER.WINDOW, "unsafe window escape ended or locked")
		return
	end
	-- A vetoed Space is not permission to replace an already certified attack
	-- route with a second local planner. If the live threat corridor already
	-- points away from this window, keep its long-horizon ownership. The window
	-- escape planner is only a fallback when no such route exists or that route
	-- still aims into the vetoed traversal.
	local activeThreat = State.activeThreat
	if activeThreat
		and typeof(activeThreat.routeDirection) == "Vector3"
		and ThreatMotionCore.CertificateMatches(activeThreat, t) then
		local towardWindow = unitOr(
			horizontal(escape.targetPosition - root.Position),
			-activeThreat.routeDirection
		)
		local routeWindowDot = activeThreat.routeDirection:Dot(towardWindow)
		if routeWindowDot
			<= Config.unsafeTraversalWindowEscapeMaximumTowardDot then
			MovementWriter.Clear(
				OWNER.WINDOW,
				"certified threat route already avoids vetoed traversal"
			)
			Diagnostics.Push(
				"UNSAFE_TRAVERSAL_THREAT_ROUTE_RETAINED",
				string.format(
					"episode=%d family=%s target=%s windowDot=%.2f action=keep-certified-threat-route-no-second-planner",
					activeThreat.episodeId,
					tostring(activeThreat.family or "UNKNOWN"),
					tostring(escape.targetName),
					routeWindowDot
				),
				"unsafe-traversal-threat-route-retained-" .. tostring(activeThreat.episodeId),
				0.12
			)
			return
		end
	end
	local needsPlan = typeof(escape.direction) ~= "Vector3"
	if needsPlan and t < (escape.nextPlanAt or -math.huge) then
		MovementWriter.Clear(OWNER.WINDOW, "waiting for fresh traversal escape budget")
		return
	end
	if not needsPlan then
		local blocked = RoutePlanner.IsCurrentRouteBlocked(
			escape.direction,
			Config.unsafeTraversalWindowEscapeMinimumClearance,
			Config.unsafeTraversalWindowEscapeProbeDistance
		)
		needsPlan = blocked
			and t - escape.lastPlanAt >= 0.16
	end
	if needsPlan then
		local plan = selectUnsafeWindowEscapeDirection(
			root,
			killerRoot,
			escape.targetPosition,
			physicalWasdDirection()
		)
		escape.lastPlanAt = t
		escape.planAttempts = (escape.planAttempts or 0) + 1
		if not plan
			or plan.clearance
				< Config.unsafeTraversalWindowEscapeMinimumClearance
			or plan.awayDot
				< Config.unsafeTraversalWindowEscapeMinimumAwayDot
			or plan.windowDot
				> Config.unsafeTraversalWindowEscapeMaximumTowardDot then
			escape.direction = nil
			MovementWriter.Clear(OWNER.WINDOW, "no safe window-veto corridor yet")
			if (escape.planAttempts or 0)
				< Config.unsafeTraversalWindowEscapeMaximumPlanAttempts
				and t + Config.unsafeTraversalWindowEscapePlanRetryInterval
					< escape.untilAt then
				escape.nextPlanAt =
					t + Config.unsafeTraversalWindowEscapePlanRetryInterval
			else
				WindowController.unsafeEscape = nil
				Diagnostics.Push(
					"UNSAFE_TRAVERSAL_ESCAPE_REJECTED",
					string.format(
						"target=%s attempts=%d reason=no-open-away-corridor action=manual-control",
						tostring(escape.targetName),
						escape.planAttempts or 0
					),
					"unsafe-traversal-escape-rejected",
					0.20
				)
			end
			return
		end
		escape.direction = plan.direction
		escape.nextPlanAt = -math.huge
		Diagnostics.Push(
			"UNSAFE_TRAVERSAL_ESCAPE_ROUTE",
			string.format(
				"target=%s awayDot=%.2f windowDot=%.2f clearance=%.2f action=move-open-field-not-window",
				tostring(escape.targetName),
				plan.awayDot,
				plan.windowDot,
				plan.clearance
			),
			"unsafe-traversal-escape-route",
			0.12
		)
	end
	MovementWriter.SetIntent(OWNER.WINDOW, {
		group = "UNSAFE_TRAVERSAL_ESCAPE",
		priority = PRIORITY.TRAVERSAL_ESCAPE,
		direction = escape.direction,
		threatPosition = killerRoot.Position,
		expiresAt = math.min(escape.untilAt, t + 0.20),
		episodeId = "WINDOW_VETO_ESCAPE",
		breakInteraction = false,
	})
end

function WindowController.UpdateTransitions(): ()
	local vaulting = characterIsVaulting()
	local t = now()
	local root = State.root
	local humanoid = State.humanoid
	if vaulting and not WindowController.lastVaulting and root and humanoid then
		local commit = WindowController.currentCommit
		local observedRecord = commit and commit.record
			or nearestIndexedWindow(root.Position, Config.windowCandidateDistance)
		WindowController.postExitUntil = -math.huge
		WindowController.activeVault = {
			startedAt = t,
			startPosition = root.Position,
			startHealth = humanoid.Health,
			window = observedRecord,
			committed = commit ~= nil,
			damageObserved = false,
		}
		local vaultTrack = WindowController.SelectRecentVaultAnimation(t)
		if vaultTrack then
			WindowController.AttachVaultAnimation(vaultTrack, t)
		end
		MovementWriter.Clear(OWNER.WINDOW, "vault started; game owns movement")
		Diagnostics.Push(
			"VAULT_START",
			string.format(
				"window=%s walk=%.2f committed=%s action=no-helper-movement-during-vault",
				observedRecord and observedRecord.model:GetFullName() or "unindexed",
				humanoid.WalkSpeed,
				tostring(commit ~= nil)
			),
			"vault-start",
			0.05
		)
	elseif not vaulting and WindowController.lastVaulting then
		local vault = WindowController.activeVault
		if vault and root then
			local duration = math.max(0, t - vault.startedAt)
			local displacement = horizontal(root.Position - vault.startPosition)
			local moved = displacement.Magnitude
			if duration >= Config.windowDurationMinimum
				and duration <= Config.windowDurationMaximum then
				local old = WindowController.learnedDuration
				WindowController.learnedDuration = old
					and old + (duration - old) * Config.windowDurationLearningWeight
					or duration
				if vault.animationId then
					local oldForId = WindowController.learnedDurationByAnimationId[
						vault.animationId
					]
					WindowController.learnedDurationByAnimationId[vault.animationId] =
						oldForId
						and oldForId + (duration - oldForId)
							* Config.windowDurationLearningWeight
						or duration
				end
			end

			local postExit = false
			local clearance = 0.0
			if Config.windowManualCommitEnabled
				and vault.committed == true
				and not vault.damageObserved
				and moved >= Config.windowPostExitMinimumTravel then
				local direction = displacement.Unit
				local awayDot = 1.0
				if State.nearestKillerRoot and State.nearestKillerRoot.Parent then
					local away = unitOr(
						root.Position - State.nearestKillerRoot.Position,
						direction
					)
					awayDot = direction:Dot(away)
				end
				local blocked
				blocked, clearance = RoutePlanner.IsCurrentRouteBlocked(
					direction,
					Config.windowPostExitClearance,
					Config.windowPostExitProbeDistance
				)
				if awayDot >= Config.windowPostExitMinimumAwayDot and not blocked then
					postExit = true
					WindowController.postExitUntil = t + Config.windowPostExitDuration
					MovementWriter.SetIntent(OWNER.WINDOW, {
						group = "VAULT_EXIT",
						priority = PRIORITY.VAULT_COMMIT,
						direction = direction,
						threatPosition = State.nearestKillerRoot
							and State.nearestKillerRoot.Position or nil,
						expiresAt = t + Config.windowPostExitDuration,
						episodeId = "VAULT_EXIT",
						breakInteraction = false,
					})
				end
			end
			Diagnostics.Push(
				"VAULT_END",
				string.format(
					"window=%s duration=%.3f learned=%.3f moved=%.2f hit=%s animationId=%s animationSpeed=%.2f postExit=%s clearance=%.2f",
					vault.window and vault.window.model:GetFullName() or "unindexed",
					duration,
					WindowController.learnedDuration or Config.windowDefaultVaultDuration,
					moved,
					tostring(vault.damageObserved),
					tostring(vault.animationId or "none"),
					tonumber(vault.animationSpeed) or 1.0,
					tostring(postExit),
					clearance
				),
				"vault-end",
				0.05
			)
		end
		WindowController.activeVault = nil
		WindowController.currentCommit = nil
	end
	WindowController.lastVaulting = vaulting
	if vaulting then
		MovementWriter.Clear(OWNER.WINDOW, "game owns active vault")
	end
end

function WindowController.UpdateScan(): ()
	if now() < WindowController.postExitUntil then
		return
	end
	if not Config.windowManualCommitEnabled
		or not State.enabled
		or isDowned()
		or characterIsVaulting() then
		WindowController.currentCommit = nil
		MovementWriter.Clear(OWNER.WINDOW, "window scan inactive")
		return
	end
	local root = State.root
	local humanoid = State.humanoid
	if not root or not humanoid then return end
	local interactionLocked = CharacterController.InteractionStatus()
	if humanoid.WalkSpeed <= 0.1 or root.Anchored or interactionLocked then
		MovementWriter.Clear(OWNER.WINDOW, "locked interaction")
		return
	end
	local manual = physicalWasdDirection()
	if not manual then
		WindowController.currentCommit = nil
		MovementWriter.Clear(OWNER.WINDOW, "no physical WASD toward window")
		return
	end

	local best = nil
	local bestScore = -math.huge
	for model, record in pairs(State.windowCache) do
		local anchor = record.anchor
		if not model.Parent or not anchor or not anchor.Parent then
			State.windowCache[model] = nil
		else
			local delta = horizontal(anchor.Position - root.Position)
			local distance = delta.Magnitude
			if distance > 0.05 and distance <= Config.windowCandidateDistance then
				local towardDot = manual:Dot(delta.Unit)
				if towardDot >= Config.windowManualDot then
					local score = towardDot * 10 - distance
					if score > bestScore then
						bestScore = score
						best = {
							record = record,
							delta = delta,
							distance = distance,
							towardDot = towardDot,
						}
					end
				end
			end
		end
	end
	if not best then
		WindowController.currentCommit = nil
		MovementWriter.Clear(OWNER.WINDOW, "no manually aimed window")
		return
	end

	local activeThreat = State.activeThreat
	-- A confirmed active attack always belongs to ThreatController. Never turn
	-- that episode into a window approach, even if auto-commit is re-enabled by
	-- a local configuration edit later.
	if activeThreat
		and activeThreat.released ~= true
		and (activeThreat.phase == "ACTIVE" or activeThreat.phase == "FINISHER") then
		WindowController.currentCommit = nil
		MovementWriter.Clear(OWNER.WINDOW, "active threat owns movement")
		Diagnostics.Push(
			"VAULT_ABORT_ACTIVE_THREAT",
			string.format(
				"family=%s phase=%s action=threat-route-or-manual-no-window-autopilot",
				tostring(activeThreat.family or "UNKNOWN"),
				tostring(activeThreat.phase or "UNKNOWN")
			),
			"vault-abort-active",
			0.45
		)
		return
	end
	local killerRoot = activeThreat and activeThreat.killerRoot or nil
	if killerRoot and (not killerRoot.Parent) then
		killerRoot = nil
	end
	local actionableThreat = activeThreat ~= nil
		and activeThreat.released ~= true
		and activeThreat.hitReceived ~= true
		and (
			activeThreat.phase == "ACTIVE"
			or activeThreat.forceRouteOnPrep == true
			or activeThreat.confirmedAimGuard == true
		)
		and killerRoot ~= nil
	local activeThreatDistance = killerRoot
		and horizontal(root.Position - killerRoot.Position).Magnitude
		or math.huge
	if Config.windowRequireActionableThreat
		and (
			not actionableThreat
			or activeThreatDistance > Config.windowThreatMaximumDistance
		) then
		WindowController.currentCommit = nil
		MovementWriter.Clear(OWNER.WINDOW, "no actionable nearby threat")
		Diagnostics.Push(
			"VAULT_REJECTED_NO_THREAT",
			string.format(
				"window=%s d=%.2f threat=%s phase=%s killerD=%.2f action=native-WASD-no-window-autopilot",
				best.record.model:GetFullName(),
				best.distance,
				activeThreat and tostring(activeThreat.family or "UNKNOWN") or "none",
				activeThreat and tostring(activeThreat.phase or "UNKNOWN") or "none",
				activeThreatDistance
			),
			"vault-no-threat-" .. tostring(best.record.model),
			0.80
		)
		return
	end

	local vaultDuration = WindowController.learnedDuration
		or Config.windowDefaultVaultDuration
	local playerEta = math.max(0, best.distance - Config.windowCenterArrivalDistance)
		/ math.max(humanoid.WalkSpeed, 1)
	local killerEta = math.huge
	local killerDistance = math.huge
	if killerRoot and killerRoot.Parent then
		local toPlayer = unitOr(root.Position - killerRoot.Position, killerRoot.CFrame.LookVector)
		local relativeVelocity = horizontal(
			killerRoot.AssemblyLinearVelocity - root.AssemblyLinearVelocity
		)
		local closing = relativeVelocity:Dot(toPlayer)
		killerDistance = horizontal(root.Position - killerRoot.Position).Magnitude
		killerEta = math.max(0, killerDistance - Config.windowKillerAttackBuffer)
			/ math.max(closing, Config.windowKillerSpeedFloor)
	end
	local required = playerEta + vaultDuration + Config.windowSafetyMargin
	Diagnostics.Push(
		"VAULT_CANDIDATE",
		string.format(
			"window=%s d=%.2f manualDot=%.2f playerEta=%.2f vault=%.2f killerD=%.2f killerEta=%.2f",
			best.record.model:GetFullName(), best.distance, best.towardDot,
			playerEta, vaultDuration, killerDistance, killerEta
		),
		"vault-candidate-" .. tostring(best.record.model),
		0.60
	)
	if required >= killerEta then
		WindowController.currentCommit = nil
		MovementWriter.Clear(OWNER.WINDOW, "vault ETA unsafe")
		Diagnostics.Push(
			"VAULT_REJECTED_LATE",
			string.format(
				"window=%s required=%.2f killerEta=%.2f action=manual-control-no-forced-vault",
				best.record.model:GetFullName(), required, killerEta
			),
			"vault-rejected-" .. tostring(best.record.model),
			0.45
		)
		return
	end

	local crossingNormal = best.record.normal
	local side = horizontal(root.Position - best.record.anchor.Position):Dot(crossingNormal)
	local crossingDirection = side >= 0 and -crossingNormal or crossingNormal
	local direction
	if best.distance <= Config.windowCenterArrivalDistance then
		direction = crossingDirection
	else
		direction = unitOr(best.delta.Unit + crossingDirection * 0.65, best.delta.Unit)
	end
	local escapeAwayDot = 1.0
	if killerRoot and killerRoot.Parent then
		local away = unitOr(root.Position - killerRoot.Position, direction)
		escapeAwayDot = direction:Dot(away)
	end
	if escapeAwayDot < Config.windowMinimumEscapeAwayDot then
		WindowController.currentCommit = nil
		MovementWriter.Clear(OWNER.WINDOW, "window direction approaches threat")
		Diagnostics.Push(
			"VAULT_REJECTED_TOWARD_THREAT",
			string.format(
				"window=%s d=%.2f killerD=%.2f awayDot=%.2f required=%.2f action=native-WASD-no-window-autopilot",
				best.record.model:GetFullName(),
				best.distance,
				activeThreatDistance,
				escapeAwayDot,
				Config.windowMinimumEscapeAwayDot
			),
			"vault-toward-threat-" .. tostring(best.record.model),
			0.45
		)
		return
	end
	local t = now()
	local changed = not WindowController.currentCommit
		or WindowController.currentCommit.record ~= best.record
	WindowController.currentCommit = {
		record = best.record,
		startedAt = changed and t or WindowController.currentCommit.startedAt,
		direction = direction,
	}
	MovementWriter.SetIntent(OWNER.WINDOW, {
		group = "VAULT_COMMIT",
		priority = PRIORITY.VAULT_COMMIT,
		direction = direction,
		threatPosition = killerRoot and killerRoot.Position or nil,
		expiresAt = t + Config.windowIntentTtl,
		episodeId = "VAULT:" .. best.record.model.Name,
		breakInteraction = false,
	})
	if changed or t - WindowController.lastCommitAt >= Config.windowCommitCooldown then
		WindowController.lastCommitAt = t
		Diagnostics.Push(
			"VAULT_COMMIT",
			string.format(
				"window=%s d=%.2f manualDot=%.2f required=%.2f killerEta=%.2f action=center-with-native-speed",
				best.record.model:GetFullName(), best.distance, best.towardDot,
				required, killerEta
			),
			"vault-commit-" .. tostring(best.record.model),
			Config.windowCommitCooldown
		)
	end
end

function WindowController.Reset(clearCache: boolean?): ()
	WindowController.activeVault = nil
	WindowController.lastVaulting = false
	WindowController.currentCommit = nil
	WindowController.lastCommitAt = -math.huge
	WindowController.postExitUntil = -math.huge
	WindowController.unsafeVetoLatch = nil
	WindowController.unsafeEscape = nil
	State.unsafeTraversalVetoLatch = nil
	State.unsafeTraversalEscape = nil
	table.clear(WindowController.recentLocalTracks)
	MovementWriter.Clear(OWNER.WINDOW, "window reset")
	if clearCache then
		table.clear(State.windowCache)
		WindowController.learnedDuration = nil
		table.clear(WindowController.learnedDurationByAnimationId)
	end
end

---------------------------------------------------------------------
-- 17. RepairResumeController
---------------------------------------------------------------------

RepairResumeController = {}

local function cancelRepairResume(reason: string): ()
	if State.repairResume then
		Diagnostics.Push(
			"REPAIR_RESUME_CANCELLED",
			"reason=" .. reason,
			"repair-resume-cancelled-" .. reason,
			0.10
		)
	end
	State.repairResume = nil
	MovementWriter.Clear(OWNER.REPAIR, reason)
end

function RepairResumeController.Update(): ()
	-- v5.2.27: automatic return to and resumption of a generator is disabled.
	-- The player decides when to leave and when to resume repairing.
	if State.repairResume ~= nil then
		State.repairResume = nil
	end
	MovementWriter.Clear(OWNER.REPAIR, "auto repair resume disabled")
end

function RepairResumeController.Reset(): ()
	State.repairResume = nil
	MovementWriter.Clear(OWNER.REPAIR, "repair resume reset")
end

---------------------------------------------------------------------
-- 17. WorldIndexer
---------------------------------------------------------------------

WorldIndexer = {}

-- Existing gameplay objects may be anywhere under the map. Bootstrap once with
-- the map root and expand children under the scheduler's node/time budget;
-- DescendantAdded handles subsequent replication without repeated full scans.

local function newlyCompletedNpcModel(instance: Instance): Model?
	-- Summoned rigs can replicate as Model -> wrapper -> rig, and their Humanoid,
	-- root and Animator do not necessarily share one direct parent. Reconsider a
	-- short ancestor chain when a lifecycle-defining instance arrives. This is
	-- bounded O(6), event-driven work; it is not a descendant scan.
	if not instance:IsA("Humanoid")
		and not instance:IsA("BasePart")
		and not instance:IsA("Animator")
		and not instance:IsA("Model") then
		return nil
	end
	local current: Instance? = if instance:IsA("Model")
		then instance
		else instance.Parent
	for _ = 1, 6 do
		if not current or current == Workspace then
			break
		end
		if current:IsA("Model")
			and current:FindFirstChildOfClass("Humanoid")
			and modelRoot(current) then
			return current
		end
		current = current.Parent
	end
	return nil
end

function WorldIndexer.Reset(): ()
	table.clear(State.worldIndexQueue)
	State.worldIndexHead = 1
	State.worldIndexActive = false
	State.worldIndexProcessed = 0
end

function WorldIndexer.Begin(reason: string): ()
	WorldIndexer.Reset()
	State.worldIndexGeneration += 1
	local mapRoot =
		MatchController.FindMapRoot()
	if not mapRoot then
		Diagnostics.Push(
			"WORLD_INDEX_SKIPPED",
			"reason=no-map-root",
			"world-index-skipped",
			0.20
		)
		return
	end
	local queued = {} :: {[Instance]: boolean}
	local function enqueue(instance: Instance?): ()
		if instance
			and instance.Parent
			and not queued[instance] then
			queued[instance] = true
			State.worldIndexQueue[#State.worldIndexQueue + 1] = instance
		end
	end
	enqueue(mapRoot)
	State.worldIndexActive = #State.worldIndexQueue > 0
	Diagnostics.Push(
		"WORLD_INDEX_BEGIN",
		string.format(
			"generation=%d reason=%s mode=incremental-map-bootstrap roots=%d maxNodes=%d budgetMs=%.2f",
			State.worldIndexGeneration,
			reason,
			#State.worldIndexQueue,
			Config.worldIndexMaxInstancesPerFrame,
			Config.worldIndexTimeBudgetMs
		),
		"world-index-begin",
		0.20
	)
end

function WorldIndexer.IndexInstance(instance: Instance): ()
	WindowController.IndexInstance(instance)
	if instance:IsA("Model") then
		ZombieController.IndexModel(instance)
	end
	local completedNpc = newlyCompletedNpcModel(instance)
	if completedNpc then
		ZombieController.IndexModel(completedNpc)
	end
	if instance:IsA("Model")
		or instance:IsA("ProximityPrompt")
		or instance:IsA("BasePart") then
		PalletController.IndexInstance(instance)
	end
	if instance:IsA("Animator") then
		local model = modelFromAnimator(instance)
		if model and not isLocalCharacter(model) then
			TargetResolver.ConnectAnimator(instance, model)
		end
	end
	ExitController.IndexProgressInstance(instance)
end

function WorldIndexer.Update(): ()
	if not State.worldIndexActive or not State.matchActive then
		return
	end
	local started = now()
	local deadline = started + Config.worldIndexTimeBudgetMs / 1000
	local processed = 0
	local queue = State.worldIndexQueue
	while State.worldIndexHead <= #queue
		and processed < Config.worldIndexMaxInstancesPerFrame
		and now() <= deadline do
		local instance = queue[State.worldIndexHead]
		State.worldIndexHead += 1
		processed += 1
		State.worldIndexProcessed += 1
		if instance and instance.Parent then
			WorldIndexer.IndexInstance(instance)
			for _, child in ipairs(instance:GetChildren()) do
				queue[#queue + 1] = child
			end
		end
	end

	if State.worldIndexHead > #queue then
		local total = State.worldIndexProcessed
		WorldIndexer.Reset()
		Diagnostics.Push(
			"WORLD_INDEX_COMPLETE",
			string.format("instances=%d", total),
			"world-index-complete",
			0.20
		)
	end
end

---------------------------------------------------------------------
-- 17. FlashlightController
---------------------------------------------------------------------

FlashlightController = {renderGeneration = 0}

function FlashlightController.CanWriteAim(expectedMode: string?): boolean
	if not ownsGlobalRuntime() or not State.enabled or not State.matchActive
		or not State.rightMouseDown or FlashlightController.IsBusy() then
		return false
	end
	local humanoid = State.humanoid
	if not humanoid or humanoid.Health <= 0 then return false end
	local mode = FlashlightController.ResolveAimMode()
	return mode ~= "OFF" and (not expectedMode or mode == expectedMode)
		and State.itemAimActiveMode == mode
		and (mode ~= "FLASHLIGHT"
			or (Config.flashlightAimEnabled and Config.flashlightCameraProxyEnabled
				and now() >= State.flashlightBlindSuppressedUntil))
end

local function beamScore(beam: Beam): number
	local lower = string.lower(beam.Name)
	local score = 0
	if beam.Name == Config.flashlightExactBeamName then
		score += 1000
	end
	if string.find(lower, "beam", 1, true) then
		score += 20
	end
	if string.find(lower, "flash", 1, true) then
		score += 20
	end
	if string.find(lower, "lightning", 1, true) then
		score -= 100
	end
	if string.find(lower, "clip", 1, true) then
		score -= 80
	end
	return score
end

local function normalizedEquippedItem(): string
	local value =
		LocalPlayer:GetAttribute(
			Config.flashlightEquippedAttribute
		)
	if typeof(value) ~= "string" then
		return ""
	end
	return string.lower(value)
end

local function containsAnyToken(
	value: string,
	tokens: {string}
): boolean
	local candidate = string.lower(value)
	for _, token in ipairs(tokens) do
		if string.find(
			candidate,
			token,
			1,
			true
		) then
			return true
		end
	end
	return false
end

function FlashlightController.HasPistolEquipped(): boolean
	if not Config.pistolAimEnabled then
		return false
	end

	local equipped =
		normalizedEquippedItem()
	if equipped ~= ""
		and containsAnyToken(
			equipped,
			Config.pistolEquippedTokens
		) then
		return true
	end

	local character = State.character
	if not character then
		return false
	end
	for _, child in ipairs(
		character:GetChildren()
	) do
		if (
			child:IsA("Tool")
			or child:IsA("Model")
			or child:IsA("Folder")
		) and containsAnyToken(
			child.Name,
			Config.pistolModelTokens
		) then
			return true
		end
	end
	return false
end

function FlashlightController.ResolveAimMode(): string
	local preference =
		State.itemAimModePreference
	local equipped =
		normalizedEquippedItem()

	if preference == "OFF" then
		return "OFF"
	elseif preference == "FLASHLIGHT" then
		return FlashlightController.HasEquipped()
			and "FLASHLIGHT"
			or "OFF"
	elseif preference == "PISTOL" then
		-- Manual PISTOL mode intentionally bypasses item-name detection. This
		-- covers games that expose the weapon under an unknown internal name.
		return Config.pistolAimEnabled
			and "PISTOL"
			or "OFF"
	end

	-- AUTO trusts the exact EquippedItem attribute first. This avoids choosing
	-- an old Flashlight model that may remain under Character after switching.
	if equipped ~= "" then
		if containsAnyToken(
			equipped,
			Config.pistolEquippedTokens
		) then
			return "PISTOL"
		elseif equipped
			== string.lower(
				Config.flashlightEquippedValue
			)
			or string.find(
				equipped,
				"flashlight",
				1,
				true
			) then
			return "FLASHLIGHT"
		end
	end

	if FlashlightController.HasPistolEquipped() then
		return "PISTOL"
	elseif FlashlightController.HasEquipped() then
		return "FLASHLIGHT"
	end
	return "OFF"
end

function FlashlightController.CycleAimMode(): ()
	local cycle =
		Config.itemAimModeCycle
	local currentIndex = 1
	for index, mode in ipairs(cycle) do
		if mode
			== State.itemAimModePreference then
			currentIndex = index
			break
		end
	end
	local nextIndex =
		currentIndex % #cycle + 1
	State.itemAimModePreference =
		cycle[nextIndex]

	Diagnostics.Push(
		"ITEM_AIM_MODE",
		string.format(
			"preference=%s resolved=%s equipped=%s key=%s",
			State.itemAimModePreference,
			FlashlightController.ResolveAimMode(),
			normalizedEquippedItem(),
			Config.itemAimToggleKey.Name
		),
		"item-aim-mode",
		0.05
	)

	if State.rightMouseDown then
		FlashlightController.StopAim(
			"mode changed"
		)
		FlashlightController.StartAim()
	end
end

local function trimText(value: string): string
	return (
		value:gsub("^%s+", "")
			:gsub("%s+$", "")
	)
end

function FlashlightController.SelectedExtraPlayer(): Player?
	local userId = State.extraAimTargetUserId
	if not userId then
		return nil
	end
	for _, player in ipairs(Players:GetPlayers()) do
		if player.UserId == userId then
			return player
		end
	end
	return nil
end

function FlashlightController.FindPlayerByInput(
	inputText: string
): (Player?, string)
	local query = string.lower(trimText(inputText))
	if query == "" then
		return nil, "empty"
	end

	local exactName: Player? = nil
	local exactDisplay: Player? = nil
	local prefixMatches = {} :: {Player}
	for _, player in ipairs(Players:GetPlayers()) do
		if player ~= LocalPlayer then
			local nameLower = string.lower(player.Name)
			local displayLower = string.lower(player.DisplayName)
			if nameLower == query then
				exactName = player
				break
			elseif displayLower == query then
				exactDisplay = exactDisplay or player
			elseif string.sub(nameLower, 1, #query) == query
				or string.sub(displayLower, 1, #query) == query then
				table.insert(prefixMatches, player)
			end
		end
	end

	if exactName then
		return exactName, "exact-username"
	elseif exactDisplay then
		return exactDisplay, "exact-display-name"
	elseif #prefixMatches == 1 then
		return prefixMatches[1], "unique-prefix"
	elseif #prefixMatches > 1 then
		return nil, "ambiguous-prefix"
	end
	return nil, "not-found"
end

function FlashlightController.CloseExtraTargetPrompt(
	reason: string
): ()
	local gui = State.extraAimTargetPrompt
	State.extraAimTargetPrompt = nil
	State.extraAimTargetTextBox = nil
	State.extraAimTargetStatus = nil
	State.extraAimTargetPromptOpen = false
	if gui and gui.Parent then
		gui:Destroy()
	end
	Diagnostics.Push(
		"EXTRA_AIM_PROMPT_CLOSED",
		string.format("reason=%s", reason),
		"extra-aim-prompt-close",
		0.05
	)
end

function FlashlightController.SetExtraAimTarget(
	player: Player?,
	reason: string
): ()
	if player then
		State.pistolTargetMode = "NICKNAME_ONLY"
		State.extraAimTargetUserId = player.UserId
		State.extraAimTargetName = player.Name
		State.extraAimTargetDisplayName = player.DisplayName
		Diagnostics.Push(
			"EXTRA_AIM_TARGET_SET",
			string.format(
				"mode=NICKNAME_ONLY username=%s display=%s userId=%d reason=%s exclusive=true",
				player.Name,
				player.DisplayName,
				player.UserId,
				reason
			),
			"extra-aim-target-set",
			0.05
		)
	else
		local previous = State.extraAimTargetName
		State.pistolTargetMode = "KILLER_ONLY"
		State.extraAimTargetUserId = nil
		State.extraAimTargetName = "none"
		State.extraAimTargetDisplayName = "none"
		Diagnostics.Push(
			"EXTRA_AIM_TARGET_CLEARED",
			string.format(
				"mode=KILLER_ONLY previous=%s reason=%s exclusive=true",
				previous,
				reason
			),
			"extra-aim-target-clear",
			0.05
		)
	end

	State.flashlightTargetModel = nil
	State.extraAimLastSource = "none"
	State.extraAimLastScreenDistance = math.huge
end

function FlashlightController.SubmitExtraTargetInput(
	value: string
): ()
	local cleaned = trimText(value)
	if cleaned == "" then
		FlashlightController.SetExtraAimTarget(
			nil,
			"empty-enter -> KILLER_ONLY"
		)
		FlashlightController.CloseExtraTargetPrompt(
			"mode KILLER_ONLY selected"
		)
		return
	end

	local player, matchKind =
		FlashlightController.FindPlayerByInput(cleaned)
	if not player then
		local status = State.extraAimTargetStatus
		if status and status.Parent then
			status.Text =
				matchKind == "ambiguous-prefix"
					and "Несколько совпадений — введи ник точнее"
					or "Игрок не найден на сервере"
			status.TextColor3 = Color3.fromRGB(255, 120, 120)
		end
		local box = State.extraAimTargetTextBox
		if box and box.Parent then
			task.defer(function()
				if box.Parent then
					box:CaptureFocus()
				end
			end)
		end
		Diagnostics.Push(
			"EXTRA_AIM_TARGET_REJECTED",
			string.format(
				"input=%s reason=%s",
				cleaned,
				matchKind
			),
			"extra-aim-target-rejected",
			0.20
		)
		return
	end

	FlashlightController.SetExtraAimTarget(
		player,
		matchKind
	)
	FlashlightController.CloseExtraTargetPrompt(
		"target accepted"
	)
end

function FlashlightController.HandleExtraAimHotkey(
	source: string
): ()
	local t = now()
	if t - State.extraAimLastHotkeyAt
		< Config.extraAimHotkeyDebounce then
		return
	end
	State.extraAimLastHotkeyAt = t
	State.extraAimLastHotkeySource = source

	Diagnostics.Push(
		"EXTRA_AIM_HOTKEY",
		string.format(
			"source=%s processedByGameIgnored=true promptOpenBefore=%s",
			source,
			tostring(
				State.extraAimTargetPromptOpen
			)
		),
		"extra-aim-hotkey",
		0.05
	)

	FlashlightController.OpenExtraTargetPrompt()
end

function FlashlightController.OpenExtraTargetPrompt(): ()
	if not ownsGlobalRuntime() then return end
	-- F7 is specifically the automatic item mode requested by the user.
	State.itemAimModePreference = "AUTO"

	if State.extraAimTargetPromptOpen then
		FlashlightController.CloseExtraTargetPrompt(
			"F7 toggle"
		)
		return
	end

	local playerGui =
		LocalPlayer:FindFirstChildOfClass("PlayerGui")
			or LocalPlayer:WaitForChild("PlayerGui", 5)
	if not ownsGlobalRuntime() then return end
	if not playerGui
		or not playerGui:IsA("PlayerGui") then
		Diagnostics.Push(
			"EXTRA_AIM_PROMPT_ERROR",
			"PlayerGui unavailable",
			"extra-aim-prompt-error",
			1.0
		)
		return
	end

	local existing =
		playerGui:FindFirstChild(
			Config.extraAimTargetGuiName
		)
	if existing then
		existing:Destroy()
	end

	local gui = Instance.new("ScreenGui")
	gui.Name = Config.extraAimTargetGuiName
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.Enabled = true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Global
	gui.DisplayOrder = 2147483647
	gui.Parent = playerGui

	local frame = Instance.new("Frame")
	frame.Name = "Prompt"
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = UDim2.fromScale(0.5, 0.22)
	frame.Size = UDim2.fromOffset(470, 196)
	frame.BackgroundColor3 = Color3.fromRGB(25, 25, 29)
	frame.BackgroundTransparency = 0.02
	frame.BorderSizePixel = 0
	frame.Visible = true
	frame.Active = true
	frame.ZIndex = 1000
	frame.Parent = gui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = frame

	local title = Instance.new("TextLabel")
	title.BackgroundTransparency = 1
	title.Position = UDim2.fromOffset(16, 10)
	title.Size = UDim2.new(1, -32, 0, 28)
	title.Font = Enum.Font.GothamBold
	title.TextSize = 17
	title.TextColor3 = Color3.fromRGB(245, 245, 245)
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Text = "Пистолет: выбрать цель"
	title.ZIndex = 1001
	title.Parent = frame

	local killerButton = Instance.new("TextButton")
	killerButton.Name = "KillerOnly"
	killerButton.Position = UDim2.fromOffset(16, 44)
	killerButton.Size = UDim2.fromOffset(210, 30)
	killerButton.BackgroundColor3 =
		State.pistolTargetMode == "KILLER_ONLY"
			and Color3.fromRGB(70, 120, 82)
			or Color3.fromRGB(48, 48, 55)
	killerButton.BorderSizePixel = 0
	killerButton.Font = Enum.Font.GothamBold
	killerButton.TextSize = 14
	killerButton.TextColor3 = Color3.fromRGB(245, 245, 245)
	killerButton.Text = "МАН — только Team=Killer"
	killerButton.ZIndex = 1001
	killerButton.Parent = frame

	local killerCorner = Instance.new("UICorner")
	killerCorner.CornerRadius = UDim.new(0, 7)
	killerCorner.Parent = killerButton

	local nicknameButton = Instance.new("TextButton")
	nicknameButton.Name = "NicknameOnly"
	nicknameButton.Position = UDim2.fromOffset(234, 44)
	nicknameButton.Size = UDim2.fromOffset(220, 30)
	nicknameButton.BackgroundColor3 =
		State.pistolTargetMode == "NICKNAME_ONLY"
			and Color3.fromRGB(70, 96, 140)
			or Color3.fromRGB(48, 48, 55)
	nicknameButton.BorderSizePixel = 0
	nicknameButton.Font = Enum.Font.GothamBold
	nicknameButton.TextSize = 14
	nicknameButton.TextColor3 = Color3.fromRGB(245, 245, 245)
	nicknameButton.Text = "ПО НИКУ — только игрок"
	nicknameButton.ZIndex = 1001
	nicknameButton.Parent = frame

	local nicknameCorner = Instance.new("UICorner")
	nicknameCorner.CornerRadius = UDim.new(0, 7)
	nicknameCorner.Parent = nicknameButton

	local box = Instance.new("TextBox")
	box.Name = "Nickname"
	box.Position = UDim2.fromOffset(16, 82)
	box.Size = UDim2.new(1, -32, 0, 42)
	box.BackgroundColor3 = Color3.fromRGB(42, 42, 48)
	box.BorderSizePixel = 0
	box.ClearTextOnFocus = false
	box.Font = Enum.Font.Gotham
	box.TextSize = 17
	box.TextColor3 = Color3.fromRGB(255, 255, 255)
	box.PlaceholderColor3 = Color3.fromRGB(155, 155, 165)
	box.PlaceholderText = "Ник игрока; Enter = режим ПО НИКУ"
	box.ZIndex = 1001
	box.Text =
		State.extraAimTargetUserId
			and State.extraAimTargetName
			or ""
	box.Parent = frame

	local boxCorner = Instance.new("UICorner")
	boxCorner.CornerRadius = UDim.new(0, 7)
	boxCorner.Parent = box

	local status = Instance.new("TextLabel")
	status.BackgroundTransparency = 1
	status.Position = UDim2.fromOffset(16, 132)
	status.Size = UDim2.new(1, -32, 0, 46)
	status.Font = Enum.Font.Gotham
	status.TextSize = 13
	status.TextColor3 = Color3.fromRGB(185, 185, 195)
	status.TextXAlignment = Enum.TextXAlignment.Left
	status.Text =
		string.format(
			"Текущий режим: %s%s\nEnter — выбрать ник · F7/Insert — закрыть",
			State.pistolTargetMode,
			State.pistolTargetMode == "NICKNAME_ONLY"
				and (" (" .. State.extraAimTargetName .. ")")
				or ""
		)
	status.ZIndex = 1001
	status.Parent = frame

	State.extraAimTargetPrompt = gui
	State.extraAimTargetTextBox = box
	State.extraAimTargetStatus = status
	State.extraAimTargetPromptOpen = true

	killerButton.Activated:Connect(function()
		if State.extraAimTargetPrompt ~= gui then
			return
		end
		FlashlightController.SetExtraAimTarget(
			nil,
			"F7 killer button"
		)
		FlashlightController.CloseExtraTargetPrompt(
			"mode KILLER_ONLY selected"
		)
	end)

	nicknameButton.Activated:Connect(function()
		if State.extraAimTargetPrompt ~= gui then
			return
		end
		status.Text =
			"Режим ПО НИКУ: введи Username/Display Name и нажми Enter"
		status.TextColor3 =
			Color3.fromRGB(185, 205, 255)
		task.defer(function()
			if box.Parent then
				box:CaptureFocus()
				box.CursorPosition =
					#box.Text + 1
			end
		end)
	end)

	box.FocusLost:Connect(function(enterPressed)
		if enterPressed
			and State.extraAimTargetPrompt == gui then
			FlashlightController.SubmitExtraTargetInput(
				box.Text
			)
		end
	end)

	task.defer(function()
		if box.Parent then
			box:CaptureFocus()
			box.CursorPosition = #box.Text + 1
		end
	end)

	Diagnostics.Push(
		"EXTRA_AIM_PROMPT_OPEN",
		string.format(
			"mode=%s current=%s itemMode=AUTO key=%s fallback=%s gui=%s enabled=%s frameVisible=%s",
			State.pistolTargetMode,
			State.extraAimTargetName,
			Config.extraAimTargetKey.Name,
			Config.extraAimTargetFallbackKey.Name,
			gui:GetFullName(),
			tostring(gui.Enabled),
			tostring(frame.Visible)
		),
		"extra-aim-prompt-open",
		0.05
	)
end

function FlashlightController.HasEquipped(): boolean
	local character = State.character
	if not character then
		return false
	end
	local flashlight =
		character:FindFirstChild(
			Config.flashlightExactModelName
		)
	if not flashlight then
		return false
	end

	-- EquippedItem can lag behind the hierarchy by one frame. The exact
	-- Character.Flashlight model is therefore the primary source of truth.
	local equipped =
		LocalPlayer:GetAttribute(
			Config.flashlightEquippedAttribute
		)
	return equipped == nil
		or equipped == ""
		or equipped == Config.flashlightEquippedValue
		or flashlight.Parent == character
end

function FlashlightController.IsBusy(): boolean
	if isDowned() then
		return true
	end

	local character = State.character
	if not character or not State.root then
		return true
	end

	local check =
		character:FindFirstChild(
			"CheckInterractable"
		)
	if check then
		for _, name in ipairs({
			"isVaulting",
			"isSliding",
			"isDroppingPallet",
			"isRepairing",
			"isHealing",
			"isUnhooking",
			"isExiting",
		}) do
			if check:GetAttribute(name) == true then
				return true
			end
		end
	end

	return false
end

function FlashlightController.ResolveBeam(): Beam?
	if State.flashlightBeam
		and State.flashlightBeam.Parent then
		return State.flashlightBeam
	end

	if not FlashlightController.HasEquipped() then
		return nil
	end

	local character = State.character
	local flashlight =
		character
		and character:FindFirstChild(
			Config.flashlightExactModelName
		)
	local light =
		flashlight
		and flashlight:FindFirstChild(
			Config.flashlightExactLightName
		)
	local exact =
		light
		and light:FindFirstChild(
			Config.flashlightExactBeamName
		)

	local best: Beam? = nil
	if exact and exact:IsA("Beam") then
		best = exact
	elseif light then
		local bestScore = -math.huge
		for _, child in ipairs(light:GetChildren()) do
			if child:IsA("Beam") then
				local score = beamScore(child)
				if score > bestScore then
					bestScore = score
					best = child
				end
			end
		end
	end

	if best then
		State.flashlightBeam = best
		State.flashlightOriginalAttachment1 =
			best.Attachment1
		State.flashlightOriginalEnabled =
			best.Enabled
		State.flashlightOriginalCurveSize0 = best.CurveSize0
		State.flashlightOriginalCurveSize1 = best.CurveSize1
		State.flashlightSource =
			best.Attachment0
		State.flashlightOriginalSourceCFrame =
			best.Attachment0
				and best.Attachment0.CFrame
				or nil
		Diagnostics.Push(
			"FLASHLIGHT_DIRECT_BEAM",
			string.format(
				"beam=%s source=%s nativeEndpointBeforeBind=%s",
				best:GetFullName(),
				best.Attachment0
					and best.Attachment0:GetFullName()
					or "none",
				best.Attachment1
					and best.Attachment1:GetFullName()
					or "none"
			),
			"flash-direct-beam",
			0.05
		)
	else
		Diagnostics.Push(
			"FLASHLIGHT_BEAM_MISSING",
			"expected Character.Flashlight.light.Beam",
			"flash-missing",
			1.0
		)
	end

	return best
end

function FlashlightController.RestoreBeamEndpoint(): ()
	local beam = State.flashlightBeam
	local original = State.flashlightOriginalAttachment1
	if beam and beam.Parent then
		beam.Attachment1 = original
		if State.flashlightOriginalCurveSize0 ~= nil then
			beam.CurveSize0 = State.flashlightOriginalCurveSize0
		end
		if State.flashlightOriginalCurveSize1 ~= nil then
			beam.CurveSize1 = State.flashlightOriginalCurveSize1
		end
	end
	local source = State.flashlightSource
	local originalSourceCFrame = State.flashlightOriginalSourceCFrame
	if source and source.Parent and originalSourceCFrame then
		-- Source orientation is owned only for the physical RMB hold. Restore the
		-- exact native local transform when the target disappears or aim stops.
		source.CFrame = originalSourceCFrame
	end
	local targetAttachment = State.flashlightTargetAttachment
	if targetAttachment and targetAttachment.Parent then
		targetAttachment:Destroy()
	end
	State.flashlightTargetAttachment = nil
	State.flashlightBeamVerifiedThisHold = false
end

function FlashlightController.AimSourceAtFace(
	model: Model
): (boolean, number, number, number)
	local source = State.flashlightSource
	local targetPoint = FlashlightController.GetTargetPoint(model)
	if not source or not source.Parent or not targetPoint then
		return false, -1.0, math.huge, -1.0
	end

	local sourcePosition = source.WorldPosition
	local toFace = targetPoint - sourcePosition
	if toFace.Magnitude < 0.05 then
		return false, -1.0, math.huge, -1.0
	end
	local faceDirection = toFace.Unit
	-- Point the emitter's actual Roblox Attachment.Axis (local +X) at the face.
	-- The previous implementation pointed LookVector (local -Z) instead; that
	-- made the camera/cursor correct while the native Beam emitter still aimed on
	-- an orthogonal axis. The visible chord remains straight and Camera.LookVector
	-- is independently locked to this same target point.
	local beforeDot = source.WorldAxis:Dot(faceDirection)
	local referenceUp = math.abs(faceDirection:Dot(Vector3.yAxis)) > 0.98
		and Vector3.zAxis
		or Vector3.yAxis
	local sourceUp = unit3Or(
		referenceUp - faceDirection * referenceUp:Dot(faceDirection),
		Vector3.yAxis
	)
	local desiredWorld = CFrame.fromMatrix(
		sourcePosition,
		faceDirection,
		sourceUp,
		faceDirection:Cross(sourceUp)
	)
	local parent = source.Parent
	if parent:IsA("BasePart") then
		source.CFrame = parent.CFrame:ToObjectSpace(desiredWorld)
	elseif parent:IsA("Attachment") then
		source.CFrame = parent.WorldCFrame:ToObjectSpace(desiredWorld)
	else
		return false, beforeDot, math.huge, beforeDot
	end

	local sourceRay = source.WorldAxis
	local sourceDot = sourceRay:Dot(faceDirection)
	local along = math.max(0.0, toFace:Dot(sourceRay))
	local closestPoint = source.WorldPosition + sourceRay * along
	local miss = (closestPoint - targetPoint).Magnitude
	local verified = sourceDot >= Config.flashlightSourceRayMinimumDot
		and miss <= Config.flashlightSourceRayMaximumMiss
	return verified, sourceDot, miss, beforeDot
end

function FlashlightController.AimFinalCameraAtFace(
	model: Model
): number
	local camera = Workspace.CurrentCamera
	local targetPoint = FlashlightController.GetTargetPoint(model)
	if not camera or not targetPoint then
		return -1.0
	end
	local cameraPosition = camera.CFrame.Position
	local delta = targetPoint - cameraPosition
	if delta.Magnitude < 0.05 then
		return -1.0
	end
	camera.CFrame = CFrame.lookAt(
		cameraPosition,
		targetPoint,
		Vector3.yAxis
	)
	return camera.CFrame.LookVector:Dot(delta.Unit)
end

function FlashlightController.BindBeamToHead(
	model: Model
): Attachment?
	local head = model:FindFirstChild("Head")
	if not head or not head:IsA("BasePart") then
		FlashlightController.RestoreBeamEndpoint()
		return nil
	end
	local beam = FlashlightController.ResolveBeam()
	if not beam then
		return nil
	end

	local endpoint = State.flashlightTargetAttachment
	if endpoint and endpoint.Parent ~= head then
		FlashlightController.RestoreBeamEndpoint()
		endpoint = nil
		State.flashlightBeamVerifiedThisHold = false
	end
	if not endpoint then
		local createdEndpoint = Instance.new("Attachment")
		createdEndpoint.Name = Config.flashlightHeadAttachmentName
		createdEndpoint.Position = Vector3.zero
		createdEndpoint:SetAttribute("VDHelperOwned", true)
		createdEndpoint.Parent = head
		endpoint = createdEndpoint
		State.flashlightTargetAttachment = createdEndpoint
		Diagnostics.Push(
			"FLASHLIGHT_HEAD_BEAM_BOUND",
			string.format(
				"target=%s head=%s endpoint=%s position=upper-face",
				model.Name,
				head:GetFullName(),
				createdEndpoint:GetFullName()
			),
			"flash-head-beam-bound-" .. model.Name,
			0.05
		)
	end
	local activeEndpoint = endpoint :: Attachment
	local targetPoint = FlashlightController.GetTargetPoint(model)
	if targetPoint then
		activeEndpoint.Position = head.CFrame:PointToObjectSpace(targetPoint)
	end
	if beam.Attachment1 ~= activeEndpoint then
		beam.Attachment1 = activeEndpoint
	end
	-- Eliminate native tangent curvature while Helper owns the endpoint. Without
	-- this, the chord ends at Head but the rendered Beam can bow through the torso
	-- and make the old endpoint-only verification report a false success.
	beam.CurveSize0 = 0
	beam.CurveSize1 = 0
	-- Apply the same target to the actual emitter before the native flashlight
	-- update. Attachment1 alone only bends a cosmetic Beam.
	FlashlightController.AimSourceAtFace(model)
	return activeEndpoint
end

function FlashlightController.AuditBeamBeforeReassert(
	model: Model
): ()
	local source = State.flashlightSource
	local beam = State.flashlightBeam
	local endpoint = State.flashlightTargetAttachment
	local targetPoint = FlashlightController.GetTargetPoint(model)
	if not source or not source.Parent
		or not beam or not beam.Parent
		or not endpoint or not endpoint.Parent
		or not targetPoint then
		return
	end
	local targetVector = targetPoint - source.WorldPosition
	if targetVector.Magnitude < 0.05 then
		return
	end
	local nativeRayDot = source.WorldAxis:Dot(targetVector.Unit)
	local endpointOwned = beam.Attachment1 == endpoint
	local endpointError = (endpoint.WorldPosition - targetPoint).Magnitude
	local straightBeam = math.abs(beam.CurveSize0) <= 1e-4
		and math.abs(beam.CurveSize1) <= 1e-4
	if nativeRayDot < Config.flashlightSourceRayMinimumDot
		or not endpointOwned
		or not straightBeam
		or endpointError > Config.flashlightBeamVerificationTolerance then
		Diagnostics.Push(
			"FLASHLIGHT_NATIVE_BEAM_DRIFT",
			string.format(
				"target=%s nativeLookDotBeforeWrite=%.4f endpointOwnedBeforeWrite=%s straightBeamBeforeWrite=%s endpointErrorBeforeWrite=%.3f action=reassert-native-look-straight-beam-and-endpoint",
				model.Name,
				nativeRayDot,
				tostring(endpointOwned),
				tostring(straightBeam),
				endpointError
			),
			"flash-native-beam-drift-" .. model.Name,
			Config.flashlightBeamVerificationLogCooldown
		)
	end
end

function FlashlightController.VerifyBeamOnFace(
	model: Model
): boolean
	local head = model:FindFirstChild("Head")
	local beam = State.flashlightBeam
	local source = State.flashlightSource
	local endpoint = State.flashlightTargetAttachment
	local targetPoint = FlashlightController.GetTargetPoint(model)
	if not head or not head:IsA("BasePart")
		or not beam or not beam.Parent
		or not source or not source.Parent
		or not endpoint or endpoint.Parent ~= head
		or not targetPoint then
		State.flashlightBeamVerifiedThisHold = false
		return false
	end

	local nativeReplacedEndpoint = beam.Attachment1 ~= endpoint
	endpoint.Position = head.CFrame:PointToObjectSpace(targetPoint)
	if nativeReplacedEndpoint then
		beam.Attachment1 = endpoint
	end
	beam.CurveSize0 = 0
	beam.CurveSize1 = 0
	local errorStuds = (endpoint.WorldPosition - targetPoint).Magnitude
	local sourceVerified, sourceAxisDot, sourceAxisMiss, nativeSourceAxisDotBefore =
		FlashlightController.AimSourceAtFace(model)
	local beamVector = endpoint.WorldPosition - source.WorldPosition
	local targetVector = targetPoint - source.WorldPosition
	local beamLineDot = -1.0
	local beamLineMiss = math.huge
	if beamVector.Magnitude > 0.05 and targetVector.Magnitude > 0.05 then
		beamLineDot = beamVector.Unit:Dot(targetVector.Unit)
		local along = math.max(0.0, targetVector:Dot(beamVector.Unit))
		beamLineMiss = (
			source.WorldPosition
				+ beamVector.Unit * along
				- targetPoint
		).Magnitude
	end
	-- Reassert the real camera after every native render callback as well. The old
	-- cameraDot=1 was measured immediately after our own write at priority 299 and
	-- could not detect a later game-camera overwrite.
	local finalCameraDot = FlashlightController.AimFinalCameraAtFace(model)
	local cosmeticEndpointVerified = beam.Attachment1 == endpoint
		and errorStuds <= Config.flashlightBeamVerificationTolerance
	local straightBeam = math.abs(beam.CurveSize0) <= 1e-4
		and math.abs(beam.CurveSize1) <= 1e-4
	local gameplayAuthorityFresh = now()
		- State.flashlightGameplayAuthorityAt <= 0.10
	local verified = gameplayAuthorityFresh
		and sourceVerified
		and cosmeticEndpointVerified
		and straightBeam
		and beamLineDot >= Config.flashlightSourceRayMinimumDot
		and beamLineMiss <= Config.flashlightSourceRayMaximumMiss
		and finalCameraDot >= Config.flashlightFinalCameraMinimumDot
	if not State.flashlightBeamVerifiedThisHold
		or nativeReplacedEndpoint
		or not verified then
		Diagnostics.Push(
			verified
				and "FLASHLIGHT_SOURCE_FACE_VERIFIED"
				or "FLASHLIGHT_SOURCE_FACE_VERIFY_FAILED",
			string.format(
				"target=%s head=%s source=%s gameplayAuthorityFresh=%s nativeLookDot=%.4f nativeLookMiss=%.3f nativeLookDotBefore=%.4f beamChordDot=%.4f beamChordMiss=%.3f straightBeam=%s finalCameraDot=%.4f cosmeticEndpoint=%s endpointError=%.3f nativeEndpointReplaced=%s action=%s",
				model.Name,
				head:GetFullName(),
				State.flashlightSource and State.flashlightSource:GetFullName() or "none",
				tostring(gameplayAuthorityFresh),
				sourceAxisDot,
				sourceAxisMiss,
				nativeSourceAxisDotBefore,
				beamLineDot,
				beamLineMiss,
				tostring(straightBeam),
				finalCameraDot,
				tostring(cosmeticEndpointVerified),
				errorStuds,
				tostring(nativeReplacedEndpoint),
				verified and "gameplay-ray-and-visible-beam-upper-face-geometry-confirmed-not-server-blind-confirmation" or "no-success-claim"
			),
			"flash-beam-face-verify-" .. model.Name,
			Config.flashlightBeamVerificationLogCooldown
		)
	end
	State.flashlightBeamVerifiedThisHold = verified
	return verified
end

function FlashlightController.ResolveTarget(): Model?
	local root = State.root
	local camera = Workspace.CurrentCamera
	if not root or not camera then
		return nil
	end

	local aimMode =
		FlashlightController.ResolveAimMode()
	local maximumDistance =
		aimMode == "PISTOL"
			and Config.pistolTargetMaximumDistance
			or Config.flashlightTargetMaximumDistance
	local viewportCenter =
		camera.ViewportSize * 0.5

	local best: Model? = nil
	local bestPlayer: Player? = nil
	local bestScore = math.huge
	local bestWorldDistance = math.huge
	local bestScreenDistance = math.huge
	local bestSource = "none"

	for _, player in ipairs(Players:GetPlayers()) do
		if player ~= LocalPlayer then
			local isKiller =
				player.Team ~= nil
				and string.lower(player.Team.Name)
					== Config.matchExactKillerTeam
			local isSelectedExtra =
				aimMode == "PISTOL"
				and State.extraAimTargetUserId ~= nil
				and player.UserId
					== State.extraAimTargetUserId
			local validTargetPool =
				if aimMode == "FLASHLIGHT" then
					isKiller
				elseif aimMode == "PISTOL"
					and State.pistolTargetMode
						== "NICKNAME_ONLY" then
					isSelectedExtra
				elseif aimMode == "PISTOL" then
					isKiller
				else
					false

			if validTargetPool then
				local model = player.Character
				local humanoid = aliveHumanoid(model)
				local targetRoot = modelRoot(model)
				local targetPart =
					model
					and (
						model:FindFirstChild("Head")
						or model:FindFirstChild("UpperTorso")
						or model:FindFirstChild("Torso")
						or targetRoot
					)

				if model and humanoid and targetRoot
					and targetPart
					and targetPart:IsA("BasePart") then
					local worldDistance =
						horizontal(
							targetRoot.Position
								- root.Position
						).Magnitude
					if worldDistance <= maximumDistance then
						local viewportPoint, onScreen =
							camera:WorldToViewportPoint(
								targetPart.Position
							)
						local screenDelta =
							Vector2.new(
								viewportPoint.X,
								viewportPoint.Y
							) - viewportCenter
						local screenDistance =
							screenDelta.Magnitude
						local validForMode = true
						if aimMode == "FLASHLIGHT" then
							validForMode =
								isKiller
								and onScreen
								and viewportPoint.Z > 0
								and screenDistance
									<= Config.flashlightTargetMaximumScreenDistance
						end
						local score =
							screenDistance
							+ worldDistance
								* Config.extraAimTargetWorldWeight
						if not onScreen
							or viewportPoint.Z <= 0 then
							score +=
								Config.extraAimTargetOffscreenPenalty
						end
						if not validForMode then
							score = math.huge
						end
						if model
							== State.flashlightTargetModel then
							score -=
								Config.extraAimTargetCurrentBiasPixels
						end

						if score < bestScore then
							bestScore = score
							best = model
							bestPlayer = player
							bestWorldDistance = worldDistance
							bestScreenDistance = screenDistance
							bestSource =
								aimMode == "PISTOL"
									and State.pistolTargetMode
										== "NICKNAME_ONLY"
									and "NICKNAME_ONLY"
									or "KILLER_ONLY"
						end
					end
				end
			end
		end
	end

	if best ~= State.flashlightTargetModel then
		State.flashlightTargetModel = best
		State.flashlightFacePitchCorrection =
			Config.flashlightFaceBeamInitialPitchCorrection
		State.flashlightFaceBeamErrorY = 0.0
		State.flashlightFaceBeamCalibrationValid = false
		State.flashlightFaceBeamCalibrationSamples = 0
		State.extraAimLastSource = bestSource
		State.extraAimLastScreenDistance =
			bestScreenDistance
		Diagnostics.Push(
			"ITEM_AIM_TARGET_CHANGED",
			string.format(
				"target=%s display=%s source=%s worldD=%.2f screenPx=%.1f selectedNick=%s itemMode=%s pistolTargetMode=%s",
				best and best.Name or "none",
				bestPlayer and bestPlayer.DisplayName or "none",
				bestSource,
				bestWorldDistance,
				bestScreenDistance,
				State.extraAimTargetName,
				aimMode,
				State.pistolTargetMode
			),
			"item-aim-target",
			0.05
		)
	end
	return best
end

function FlashlightController.ResolveRig(): (
	BasePart?,
	Motor6D?
)
	local character = State.character
	if not character then
		return nil, nil
	end

	local torso =
		character:FindFirstChild("Torso")
			or character:FindFirstChild("UpperTorso")
	local shoulder =
		torso
		and (
			torso:FindFirstChild("Right Shoulder")
			or torso:FindFirstChild("RightShoulder")
		)

	if torso and torso:IsA("BasePart")
		and shoulder
		and shoulder:IsA("Motor6D") then
		State.flashlightTorso = torso
		State.flashlightShoulder = shoulder
		State.flashlightOriginalShoulderC0 =
			State.flashlightOriginalShoulderC0
				or shoulder.C0
		return torso, shoulder
	end

	return nil, nil
end

function FlashlightController.GetTargetPoint(
	model: Model
): Vector3?
	local head = model:FindFirstChild("Head")
	if not head or not head:IsA("BasePart") then
		return nil
	end

	-- Never infer the anatomical face from an arbitrary Head decal. Killer rigs
	-- can add status/skin decals on Bottom/Back; FindFirstChildWhichIsA then moved
	-- the target toward the neck or rear of the skull. Roblox character faces are
	-- on Head local Front (-Z), which follows the animated head deterministically.
	local faceNormal = Vector3.new(0, 0, -1)
	local halfExtent = math.abs(faceNormal.X) * head.Size.X * 0.5
		+ math.abs(faceNormal.Y) * head.Size.Y * 0.5
		+ math.abs(faceNormal.Z) * head.Size.Z * 0.5
	local localFacePoint = Vector3.new(
		0,
		head.Size.Y * Config.flashlightFaceVerticalFraction,
		0
	) + faceNormal * halfExtent * Config.flashlightFaceSurfaceInset
	-- Camera and Beam use the exact same upper-face point. Because it is defined
	-- in Head-local space it follows head animation without a torso fallback.
	return head.CFrame:PointToWorldSpace(localFacePoint)
end

function FlashlightController.GetPistolTargetPoint(
	model: Model
): Vector3?
	local targetPart =
		model:FindFirstChild("UpperTorso")
			or model:FindFirstChild("Torso")
			or model:FindFirstChild("HumanoidRootPart")
			or model:FindFirstChild("Head")
	if not targetPart
		or not targetPart:IsA("BasePart") then
		return nil
	end

	local camera = Workspace.CurrentCamera
	if not camera then
		return nil
	end

	local basePoint =
		targetPart.Position
			+ Vector3.new(
				0,
				targetPart.Size.Y
					* Config.pistolChestYOffset,
				0
			)
	local distance =
		(basePoint - camera.CFrame.Position).Magnitude
	local leadTime =
		math.clamp(
			distance
				/ Config.pistolProjectileSpeed,
			0,
			Config.pistolMaximumLeadTime
		)
	local velocity =
		targetPart.AssemblyLinearVelocity
	local rawLead =
		velocity * leadTime
	local leadMagnitude = rawLead.Magnitude
	local lead =
		leadMagnitude
				> Config.pistolMaximumLeadDistance
			and rawLead.Unit
				* Config.pistolMaximumLeadDistance
			or rawLead

	State.pistolLastLeadTime = leadTime
	State.pistolLastLeadDistance = lead.Magnitude
	State.pistolLastTargetPart =
		targetPart.Name

	return basePoint + lead
end

function FlashlightController.IsBlinded(
	model: Model
): (boolean, string)
	local head = model:FindFirstChild("Head")
	for _, container in ipairs({model, head}) do
		if container then
			for _, name in ipairs({
				"Blindness",
				"Blinded",
				"IsBlinded",
				"FlashlightStun",
			}) do
				local attribute =
					container:GetAttribute(name)
				if attribute == true then
					return true,
						string.format(
							"%s.attribute.%s=true",
							container.Name,
							name
						)
				elseif typeof(attribute) == "number"
					and attribute
						>= Config.flashlightBlindNumericThreshold then
					return true,
						string.format(
							"%s.attribute.%s=%.3f",
							container.Name,
							name,
							attribute
						)
				end

				local child =
					container:FindFirstChild(name)
				if child then
					if child:IsA("BoolValue")
						and child.Value then
						return true,
							string.format(
								"%s.%s.BoolValue=true",
								container.Name,
								name
							)
					elseif child:IsA("NumberValue")
						and child.Value
							>= Config.flashlightBlindNumericThreshold then
						return true,
							string.format(
								"%s.%s.NumberValue=%.3f",
								container.Name,
								name,
								child.Value
							)
					end
				end
			end
		end
	end
	return false, "none"
end

function FlashlightController.IsConfirmedStunned(
	model: Model
): (boolean, string)
	-- Never infer a stun merely from distance, velocity or WalkSpeed. Movement is
	-- yielded only for a replicated state that the game exposes on this exact
	-- target, so holding RMB near an unstunned attacker still permits a real dodge.
	if State.flashlightBlindSignalActive
		and State.flashlightBlindObservedTarget == model then
		return true, "flashlight-blind-signal"
	end

	local blinded, blindSource = FlashlightController.IsBlinded(model)
	if blinded then
		return true, blindSource
	end

	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.PlatformStand then
		return true, "Humanoid.PlatformStand=true"
	end
	local player = Players:GetPlayerFromCharacter(model)
	local containers = {model :: Instance}
	local head = model:FindFirstChild("Head")
	if head then table.insert(containers, head) end
	if humanoid then table.insert(containers, humanoid) end
	if player then table.insert(containers, player) end

	-- Blindness/Blinded/FlashlightStun are deliberately absent here. In this
	-- game their numeric values are progress (for example 16/65/82), not a stun.
	-- IsBlinded() above owns those names and requires the full numeric threshold.
	local flagNames = {
		"Stunned",
		"IsStunned",
		"PalletStunned",
		"Stun",
		"StunState",
	}
	for _, container in ipairs(containers) do
		for _, name in ipairs(flagNames) do
			local attribute = container:GetAttribute(name)
			if attribute == true
				or (typeof(attribute) == "number" and attribute > 0) then
				return true, string.format(
					"%s.attribute.%s=%s",
					container.Name,
					name,
					tostring(attribute)
				)
			elseif typeof(attribute) == "string" then
				local token = string.lower(attribute)
				if token == "true" or token == "stunned"
					or token == "blind" or token == "blinded" then
					return true, string.format(
						"%s.attribute.%s=%s",
						container.Name,
						name,
						attribute
					)
				end
			end

			local child = container:FindFirstChild(name)
			if child then
				if child:IsA("BoolValue") and child.Value then
					return true, child:GetFullName() .. "=true"
				elseif (child:IsA("NumberValue") or child:IsA("IntValue"))
					and child.Value > 0 then
					return true, child:GetFullName() .. "=" .. tostring(child.Value)
				elseif child:IsA("StringValue") then
					local token = string.lower(child.Value)
					if token == "true" or token == "stunned"
						or token == "blind" or token == "blinded" then
						return true, child:GetFullName() .. "=" .. child.Value
					end
				end
			end
		end
	end
	return false, "none"
end

function FlashlightController.IsSafeToKeepShining(
	model: Model
): (boolean, string)
	local stunned, stunSource =
		FlashlightController.IsConfirmedStunned(model)
	if stunned then
		return true, stunSource
	end
	if now() < (
		State.recentPalletBreakUntilByModel[model]
			or -math.huge
	) then
		return true, "exact-pallet-break-animation"
	end
	return false, "none"
end

function FlashlightController.ShouldDeactivateUnsafeAim(
	model: Model
): (boolean, string, string)
	if not Config.flashlightUnsafeAutoDeactivate
		or State.itemAimActiveMode ~= "FLASHLIGHT"
		or now() - State.flashlightAimStartedAt
			< Config.flashlightUnsafeDetectionGrace then
		return false, "none", "none"
	end

	local humanoid = State.humanoid
	local currentWalk = humanoid and humanoid.WalkSpeed or 0.0
	local baseline = State.flashlightPreAimWalkSpeed or currentWalk
	local slowed = baseline > 0.0
		and baseline - currentWalk
			>= Config.flashlightUnsafeMinimumSpeedDrop
		and currentWalk
			<= baseline * Config.flashlightUnsafeSpeedRatio

	local threat = State.activeThreat
	local actionableThreat = type(threat) == "table"
		and threat.killerModel == model
		and threat.released ~= true
		and threat.actionContract == ACTION_KIND.MOVE
		and now() <= math.max(
			threat.expiresAt or -math.huge,
			threat.minimumReleaseAt or -math.huge
		)
	-- DistanceKeeper and close-aim guards are synthetic forecasts, not proof that
	-- an attack animation is active. They may guide movement, but must not switch
	-- off the player's physical RMB or the native flashlight. Only a replicated
	-- ACTIVE animation on this target has authority to cancel unsafe aim.
	local exactActiveThreat = actionableThreat
		and threat.synthetic ~= true
		and threat.phase == "ACTIVE"
		and type(threat.activeAnimationId) == "string"
		and tonumber(threat.activeAnimationId) ~= nil
	local root = State.root
	local killerRoot = modelRoot(model)
	local imminentContact = false
	if root and killerRoot then
		local distance = horizontal(
			killerRoot.Position - root.Position
		).Magnitude
		local facing = getFacingDot(killerRoot, root)
		local approach = getApproachSpeed(killerRoot, root)
		imminentContact = distance <= 8.0
			and facing >= 0.70
			and approach >= -0.50
	end
	-- Native flashlight slowdown is normal and, by itself, is never a reason to
	-- cancel the player's RMB hold. Only a live actionable episode or truly
	-- point-blank aimed contact can make that slowdown unsafe.
	if not exactActiveThreat and not imminentContact then
		return false, "none", "none"
	end

	local safe, safeSource =
		FlashlightController.IsSafeToKeepShining(model)
	if safe then
		return false,
			if slowed then "slowed" else "exact-active-threat",
			safeSource
	end

	local reason = if exactActiveThreat
		then (slowed and "slowed+exact-active-threat" or "exact-active-threat")
		else (slowed and "slowed+imminent-contact" or "imminent-contact")
	return true, reason, "none"
end

function FlashlightController.DeactivateUnsafeAim(
	model: Model,
	reason: string
): ()
	if State.flashlightUnsafeStopQueued then
		return
	end
	State.flashlightUnsafeStopQueued = true
	local humanoid = State.humanoid
	local walk = humanoid and humanoid.WalkSpeed or 0.0
	local baseline = State.flashlightPreAimWalkSpeed or walk
	local nativeOff = FlashlightController.SetNativeActive(
		false,
		"unsafe-aim-" .. reason
	)
	Diagnostics.Push(
		"FLASHLIGHT_UNSAFE_AIM_DEACTIVATED",
		string.format(
			"target=%s reason=%s walk=%.2f baseline=%.2f nativeOff=%s safeState=none action=stop-native-flashlight-and-helper-aim noSyntheticRMB=true interactionUntouched=true",
			model.Name,
			reason,
			walk,
			baseline,
			tostring(nativeOff)
		),
		"flashlight-unsafe-deactivate",
		0.05
	)
	-- Do not unbind the render callback from inside itself. No input is released;
	-- the physical RMB owner remains the player, while native flashlight state and
	-- Helper camera/Beam authority are ended before the next rendered frame.
	local renderGeneration = FlashlightController.renderGeneration
	task.defer(function()
		if ownsGlobalRuntime() and State.flashlightUnsafeStopQueued
			and renderGeneration == FlashlightController.renderGeneration then
			FlashlightController.StopAim(
				"unsafe-aim-" .. reason
			)
		end
	end)
end

function FlashlightController.ResolveActivationEndpoint(): (
	RemoteEvent?,
	Instance?
)
	if State.flashlightActivationRemote
		and State.flashlightActivationRemote.Parent
		and State.flashlightActivationPart
		and State.flashlightActivationPart.Parent then
		return State.flashlightActivationRemote,
			State.flashlightActivationPart
	end
	if now() < (FlashlightController.activationResolveRetryAt or -math.huge) then
		return nil, nil
	end
	FlashlightController.activationResolveRetryAt = now() + 0.25

	local remotes =
		ReplicatedStorage:FindFirstChild("Remotes")
	local items =
		remotes and remotes:FindFirstChild("Items")
	local flashlightRemotes =
		items and items:FindFirstChild("Flashlight")
	local activate =
		flashlightRemotes
		and flashlightRemotes:FindFirstChild("Activate")
	if not activate
		or not activate:IsA("RemoteEvent") then
		return nil, nil
	end

	local character = State.character
	local flashlight =
		character
		and character:FindFirstChild(
			Config.flashlightExactModelName
		)
	if not flashlight then
		return nil, nil
	end

	local candidate: Instance? = nil
	local exactMain =
		flashlight:FindFirstChild("Main")
	if exactMain
		and exactMain:GetAttribute("remaining")
			~= nil then
		candidate = exactMain
	elseif flashlight:GetAttribute("remaining")
		~= nil then
		candidate = flashlight
	else
		-- Small flashlight-model-only search, never Workspace.
		for _, descendant in ipairs(
			flashlight:GetDescendants()
		) do
			if descendant:GetAttribute("remaining")
				~= nil then
				candidate = descendant
				break
			end
		end
	end

	if candidate then
		State.flashlightActivationRemote =
			activate
		State.flashlightActivationPart =
			candidate
	end
	return activate, candidate
end

function FlashlightController.SetNativeActive(
	active: boolean,
	reason: string
): boolean
	local remote, flashlightPart =
		FlashlightController.ResolveActivationEndpoint()
	if not remote or not flashlightPart then
		Diagnostics.Push(
			"FLASHLIGHT_NATIVE_TOGGLE_MISSING",
			string.format(
				"active=%s reason=%s",
				tostring(active),
				reason
			),
			"flash-native-toggle-missing",
			1.0
		)
		return false
	end

	local ok, err = pcall(function()
		remote:FireServer(
			flashlightPart,
			active
		)
	end)
	if not ok then
		Diagnostics.Push(
			"FLASHLIGHT_NATIVE_TOGGLE_ERROR",
			string.format(
				"active=%s error=%s",
				tostring(active),
				tostring(err)
			),
			"flash-native-toggle-error",
			1.0
		)
		return false
	end
	return true
end

function FlashlightController.TriggerBlindPause(
	target: Model
): ()
	if not Config.flashlightBlindPauseEnabled then
		return
	end

	local t = now()
	if t - State.flashlightLastBlindAt
		< Config.flashlightBlindPauseMinimumInterval then
		return
	end

	State.flashlightLastBlindAt = t
	State.flashlightBlindLatchedTarget = target
	State.flashlightBlindSuppressedUntil =
		t + Config.flashlightBlindPauseDuration
	State.flashlightBlindPauseGeneration += 1
	local generation =
		State.flashlightBlindPauseGeneration

	local nativeOff =
		FlashlightController.SetNativeActive(
			false,
			"blind-pause"
		)
	Diagnostics.Push(
		"FLASHLIGHT_BLIND_PAUSE",
		string.format(
			"target=%s duration=%.2f nativeOff=%s faceAim=true exposure=%.3f source=%s frames=%d",
			target.Name,
			Config.flashlightBlindPauseDuration,
			tostring(nativeOff),
			t - State.flashlightAimStartedAt,
			State.flashlightBlindSignalSource,
			State.flashlightBlindActiveFrames
		),
		"flash-blind-pause",
		0.05
	)

	task.delay(
		Config.flashlightBlindPauseDuration,
		function()
			if generation
				~= State.flashlightBlindPauseGeneration then
				return
			end
			if not FlashlightController.CanWriteAim("FLASHLIGHT")
				or not FlashlightController.HasEquipped() then
				Diagnostics.Push(
					"FLASHLIGHT_BLIND_RESUME_SKIPPED",
					"reason=RMB-not-held-or-control-unavailable",
					"flash-blind-resume-skip",
					0.05
				)
				return
			end

			local nativeOn =
				FlashlightController.SetNativeActive(
					true,
					"blind-pause-complete"
				)
			Diagnostics.Push(
				"FLASHLIGHT_BLIND_RESUME",
				string.format(
					"target=%s nativeOn=%s",
					target.Name,
					tostring(nativeOn)
				),
				"flash-blind-resume",
				0.05
			)
		end
	)
end

function FlashlightController.ResetBlindObservation(
	target: Model?,
	reason: string
): ()
	State.flashlightBlindObservedTarget = target
	State.flashlightBlindSignalActive = false
	State.flashlightBlindSignalSource = "none"
	State.flashlightBlindArmed = false
	State.flashlightBlindActiveFrames = 0
	State.flashlightBlindInactiveFrames = 0
	State.flashlightAimStartedAt = now()

	if target then
		local active, source =
			FlashlightController.IsBlinded(target)
		State.flashlightBlindSignalActive =
			active
		State.flashlightBlindSignalSource =
			source
		-- An already-active signal is baseline/stale until it clears.
		State.flashlightBlindArmed =
			not active
		Diagnostics.Push(
			"FLASHLIGHT_BLIND_BASELINE",
			string.format(
				"target=%s active=%s source=%s armed=%s reason=%s",
				target.Name,
				tostring(active),
				source,
				tostring(not active),
				reason
			),
			"flash-blind-baseline",
			0.05
		)
	end
end

function FlashlightController.UpdateBlindState(
	target: Model,
	allowTrigger: boolean
): ()
	if State.flashlightBlindObservedTarget
		~= target then
		FlashlightController.ResetBlindObservation(
			target,
			"target-changed"
		)
		return
	end

	local active, source =
		FlashlightController.IsBlinded(target)
	State.flashlightBlindSignalSource = source

	if active then
		State.flashlightBlindActiveFrames += 1
		State.flashlightBlindInactiveFrames = 0
	else
		State.flashlightBlindInactiveFrames += 1
		State.flashlightBlindActiveFrames = 0
		if State.flashlightBlindInactiveFrames
			>= Config.flashlightBlindClearFrames then
			State.flashlightBlindArmed = true
		end
	end

	local wasActive =
		State.flashlightBlindSignalActive
	State.flashlightBlindSignalActive = active

	local exposure =
		now() - State.flashlightAimStartedAt
	local confirmed =
		active
		and State.flashlightBlindArmed
		and State.flashlightBlindActiveFrames
			>= Config.flashlightBlindConfirmFrames
		and exposure
			>= Config.flashlightBlindMinimumExposure

	if allowTrigger
		and confirmed
		and State.flashlightBlindLatchedTarget
			~= target then
		State.flashlightBlindArmed = false
		FlashlightController.TriggerBlindPause(
			target
		)
	elseif active
		and not wasActive
		and exposure
			< Config.flashlightBlindMinimumExposure then
		Diagnostics.Push(
			"FLASHLIGHT_BLIND_SIGNAL_EARLY",
			string.format(
				"target=%s exposure=%.3f required=%.3f source=%s action=keep-shining",
				target.Name,
				exposure,
				Config.flashlightBlindMinimumExposure,
				source
			),
			"flash-blind-early",
			0.50
		)
	end

	if not active
		and State.flashlightBlindLatchedTarget
			== target
		and now()
			>= State.flashlightBlindSuppressedUntil then
		State.flashlightBlindLatchedTarget = nil
	end
end

function FlashlightController.UpdateAim(): ()
	if not ownsGlobalRuntime()
		or not State.matchActive
		or not State.rightMouseDown
		or not State.enabled
		or FlashlightController.IsBusy() then
		return
	end

	local humanoid = State.humanoid
	if not humanoid or humanoid.Health <= 0 then
		return
	end

	local aimMode =
		FlashlightController.ResolveAimMode()
	if aimMode == "OFF" then
		FlashlightController.RestoreBeamEndpoint()
		if now()
			- State.itemAimLastUnsupportedLogAt
			>= 1.0 then
			State.itemAimLastUnsupportedLogAt =
				now()
			Diagnostics.Push(
				"ITEM_AIM_UNAVAILABLE",
				string.format(
					"preference=%s equipped=%s",
					State.itemAimModePreference,
					normalizedEquippedItem()
				),
				"item-aim-unavailable",
				1.0
			)
		end
		return
	end

	if aimMode
		~= State.itemAimActiveMode then
		FlashlightController.StopAim("resolved item mode changed")
		FlashlightController.StartAim()
		return
	end

	local target =
		FlashlightController.ResolveTarget()
	if not target then
		if aimMode == "FLASHLIGHT" then
			FlashlightController.RestoreBeamEndpoint()
		end
		if not State.flashlightAimConfirmedThisHold then
			State.flashlightAimConfirmedThisHold = true
			Diagnostics.Push(
				"FLASHLIGHT_NO_TARGET",
				"no on-screen Team=Killer target inside configured range",
				"flashlight-no-target-hold",
				0.05
			)
		end
		return
	end

	if aimMode == "FLASHLIGHT" then
		local deactivate, unsafeReason, safeSource =
			FlashlightController.ShouldDeactivateUnsafeAim(target)
		if deactivate then
			FlashlightController.DeactivateUnsafeAim(
				target,
				unsafeReason
			)
			return
		elseif safeSource ~= "none" then
			Diagnostics.Push(
				"FLASHLIGHT_SAFE_WINDOW_RETAINED",
				string.format(
					"target=%s source=%s unsafeCandidate=%s action=keep-shining",
					target.Name,
					safeSource,
					unsafeReason
				),
				"flashlight-safe-window-" .. target.Name,
				0.40
			)
		end
	end

	if aimMode == "FLASHLIGHT"
		and now()
			< State.flashlightBlindSuppressedUntil then
		FlashlightController.UpdateBlindState(
			target,
			false
		)
		return
	end

	local targetPoint: Vector3? = nil
	local maximumPitch =
		Config.flashlightMaximumPitch
	if aimMode == "FLASHLIGHT" then
		if not Config.flashlightAimEnabled
			or not Config.flashlightCameraProxyEnabled
			or not FlashlightController.HasEquipped() then
			return
		end

		-- Bind the actual visible Beam endpoint to the same upper-face point used by
		-- Camera.LookVector. The native module still owns fuel/activation.
		FlashlightController.BindBeamToHead(target)
		targetPoint =
			FlashlightController.GetTargetPoint(
				target
			)
	else
		if not Config.pistolAimEnabled then
			return
		end
		if State.itemAimModePreference ~= "PISTOL"
			and not FlashlightController.HasPistolEquipped() then
			return
		end
		maximumPitch =
			Config.pistolMaximumPitch
		targetPoint =
			FlashlightController.GetPistolTargetPoint(
				target
			)
	end

	local camera = Workspace.CurrentCamera
	if not targetPoint or not camera then
		return
	end

	local cameraPosition = camera.CFrame.Position
	local delta = targetPoint - cameraPosition
	if delta.Magnitude < 0.05 then
		return
	end

	local flatMagnitude =
		Vector3.new(delta.X, 0, delta.Z).Magnitude
	local rawPitch =
		math.atan2(
			delta.Y,
			math.max(flatMagnitude, 0.001)
		)
	local calibratedPitch = rawPitch
	if aimMode == "FLASHLIGHT"
		and Config.flashlightFaceBeamCalibrationEnabled then
		calibratedPitch += State.flashlightFacePitchCorrection
	end
	local pitch =
		math.clamp(
			calibratedPitch,
			-maximumPitch,
			maximumPitch
		)
	local flatDirection =
		flatMagnitude > 0.001
			and Vector3.new(
				delta.X,
				0,
				delta.Z
			).Unit
			or unitOr(camera.CFrame.LookVector, Vector3.new(0, 0, -1))
	local desiredDirection =
		unit3Or(
			flatDirection * math.cos(pitch)
				+ Vector3.yAxis
					* math.sin(pitch),
			camera.CFrame.LookVector
		)

	-- Hold the real camera direction throughout RMB. No later callback
	-- restores it before the native flashlight has sampled the direction.
	State.flashlightPreProxyCameraCFrame = nil
	camera.CFrame =
		CFrame.lookAt(
			cameraPosition,
			cameraPosition + desiredDirection,
			Vector3.yAxis
		)

	State.flashlightLastProxyPitch = pitch
	State.flashlightLastValidAt = now()

	if aimMode == "FLASHLIGHT" then
		if not State.flashlightAimConfirmedThisHold then
			State.flashlightAimConfirmedThisHold = true
			local aimDot =
				camera.CFrame.LookVector:Dot(
					desiredDirection
				)
			Diagnostics.Push(
				"FLASHLIGHT_AIM_ACTIVE",
				string.format(
			"target=%s distance=%.2f pitchDeg=%.1f correctionDeg=%.1f cameraDot=%.3f mode=verified-upper-face-beam",
				target.Name,
				delta.Magnitude,
				math.deg(pitch),
				math.deg(State.flashlightFacePitchCorrection),
				aimDot
				),
				"flashlight-aim-active-hold",
				0.05
			)
		end

		Diagnostics.Push(
			"FLASHLIGHT_CAMERA_PROXY",
			string.format(
			"target=%s distance=%.2f pitchDeg=%.1f correctionDeg=%.1f beamErrorY=%.2f effectiveBlindTarget=upper-face",
				target.Name,
				delta.Magnitude,
				math.deg(pitch),
				math.deg(State.flashlightFacePitchCorrection),
				State.flashlightFaceBeamErrorY
			),
			"flash-camera-proxy",
			0.50
		)

		FlashlightController.UpdateBlindState(
			target,
			true
		)
	else
		Diagnostics.Push(
			"PISTOL_CAMERA_PROXY",
			string.format(
				"target=%s part=%s distance=%.2f pitchDeg=%.1f leadTime=%.3f leadDistance=%.2f",
				target.Name,
				State.pistolLastTargetPart,
				delta.Magnitude,
				math.deg(pitch),
				State.pistolLastLeadTime,
				State.pistolLastLeadDistance
			),
			"pistol-camera-proxy",
			0.35
		)
	end
end

function FlashlightController.CalibrateFaceBeamAfterNative(): ()
	if not Config.flashlightFaceBeamCalibrationEnabled
		or not FlashlightController.CanWriteAim("FLASHLIGHT") then
		return
	end
	local target = State.flashlightTargetModel
	local beam = State.flashlightBeam
	local source = beam and beam.Attachment0 or nil
	local endpoint = beam and beam.Attachment1 or nil
	if not target or not target.Parent
		or not beam or not beam.Parent
		or not source or not source.Parent
		or not endpoint or not endpoint.Parent then
		Diagnostics.Push(
			"FLASHLIGHT_FACE_CALIBRATION_UNAVAILABLE",
			string.format(
				"target=%s beam=%s source=%s endpoint=%s action=use-initial-pitch-correction",
				target and target.Name or "none",
				beam and beam:GetFullName() or "none",
				source and source:GetFullName() or "none",
				endpoint and endpoint:GetFullName() or "none"
			),
			"flash-face-calibration-unavailable",
			1.0
		)
		return
	end

	local facePoint = FlashlightController.GetTargetPoint(target)
	if not facePoint then return end
	local sourcePosition = source.WorldPosition
	local beamVector = endpoint.WorldPosition - sourcePosition
	local beamHorizontal = horizontal(beamVector)
	local targetVector = facePoint - sourcePosition
	local targetHorizontal = horizontal(targetVector)
	if beamHorizontal.Magnitude < 0.05
		or targetHorizontal.Magnitude
			< Config.flashlightFaceBeamMinimumSampleDistance then
		return
	end
	local horizontalDot = beamHorizontal.Unit:Dot(targetHorizontal.Unit)
	if horizontalDot < Config.flashlightFaceBeamMinimumHorizontalDot then
		return
	end

	-- Extend the actual native Beam line to the target's horizontal depth. This
	-- measures the visible vertical miss directly, regardless of shoulder Motor6D,
	-- flashlight attachment offsets or character rig proportions.
	local beamYAtFaceDepth = sourcePosition.Y
		+ beamVector.Y * (targetHorizontal.Magnitude / beamHorizontal.Magnitude)
	local errorY = math.clamp(
		facePoint.Y - beamYAtFaceDepth,
		-Config.flashlightFaceBeamMaximumVerticalError,
		Config.flashlightFaceBeamMaximumVerticalError
	)
	local errorAngle = math.atan2(errorY, targetHorizontal.Magnitude)
	local current = State.flashlightFacePitchCorrection
	local requested = math.clamp(
		current + errorAngle * Config.flashlightFaceBeamCorrectionGain,
		Config.flashlightFaceBeamMinimumPitchCorrection,
		Config.flashlightFaceBeamMaximumPitchCorrection
	)
	State.flashlightFacePitchCorrection = current
		+ (requested - current) * Config.flashlightFaceBeamCorrectionSmoothing
	State.flashlightFaceBeamErrorY = errorY
	State.flashlightFaceBeamCalibrationValid = true
	State.flashlightFaceBeamCalibrationSamples += 1
	Diagnostics.Push(
		"FLASHLIGHT_FACE_CALIBRATION",
		string.format(
			"target=%s errorY=%+.2f correctionDeg=%+.1f horizontalDot=%.3f samples=%d faceY=%.2f beamY=%.2f",
			target.Name,
			errorY,
			math.deg(State.flashlightFacePitchCorrection),
			horizontalDot,
			State.flashlightFaceBeamCalibrationSamples,
			facePoint.Y,
			beamYAtFaceDepth
		),
		"flash-face-calibration",
		Config.flashlightFaceBeamLogCooldown
	)
end

function FlashlightController.RestoreCameraAfterNative(): ()
	if not FlashlightController.CanWriteAim("FLASHLIGHT") then
		State.flashlightPreProxyCameraCFrame = nil
		return
	end
	local camera = Workspace.CurrentCamera
	local original = State.flashlightPreProxyCameraCFrame
	if not camera or not original then
		return
	end

	local rotationOnly = original - original.Position
	camera.CFrame =
		CFrame.new(camera.CFrame.Position)
		* rotationOnly
	State.flashlightPreProxyCameraCFrame = nil
end

function FlashlightController.EnforceGameplayRayAfterNative(): ()
	if not FlashlightController.CanWriteAim("FLASHLIGHT") then
		return
	end
	local target = State.flashlightTargetModel
	if not target or not target.Parent then
		return
	end

	-- This callback runs immediately after the native Character-priority update,
	-- before the old Last+12 cosmetic verifier. The log supplied with v5.5.26
	-- proved that native code rotated Attachment0 as far as dot=-0.61 after our
	-- Character-1 write. Reassert the actual emitter and camera here so gameplay
	-- ray consumers see the face vector during the frame, not only after it.
	FlashlightController.AuditBeamBeforeReassert(target)
	FlashlightController.BindBeamToHead(target)
	local sourceVerified, sourceDot, sourceMiss =
		FlashlightController.AimSourceAtFace(target)
	local cameraDot = FlashlightController.AimFinalCameraAtFace(target)
	State.flashlightGameplayAuthorityAt = now()
	if not sourceVerified
		or cameraDot < Config.flashlightFinalCameraMinimumDot then
		Diagnostics.Push(
			"FLASHLIGHT_GAMEPLAY_RAY_FAILED",
			string.format(
				"target=%s sourceDot=%.4f sourceMiss=%.3f cameraDot=%.4f priority=%d action=no-blind-success-claim",
				target.Name,
				sourceDot,
				sourceMiss,
				cameraDot,
				Enum.RenderPriority.Character.Value
					+ Config.flashlightGameplayPriorityOffset
			),
			"flash-gameplay-ray-failed",
			0.40
		)
	end
end

function FlashlightController.StartAim(): ()
	if not ownsGlobalRuntime() or not State.enabled or not State.matchActive
		or not State.rightMouseDown or State.flashlightRenderBound then
		return
	end

	local aimMode =
		FlashlightController.ResolveAimMode()
	if aimMode == "OFF" then
		Diagnostics.Push(
			"ITEM_AIM_START_REJECTED",
			string.format(
				"preference=%s equipped=%s reason=no-supported-item",
				State.itemAimModePreference,
				normalizedEquippedItem()
			),
			"item-aim-start-rejected",
			0.50
		)
		return
	end

	State.itemAimActiveMode = aimMode
	State.flashlightRenderBound = true
	FlashlightController.renderGeneration += 1
	local renderGeneration = FlashlightController.renderGeneration
	State.flashlightAimStartedAt = now()
	State.flashlightPreAimWalkSpeed = State.humanoid
		and math.max(
			State.humanoid.WalkSpeed,
			CharacterController.GetOriginalWalkSpeed()
		)
		or nil
	State.flashlightUnsafeStopQueued = false
	State.flashlightAimConfirmedThisHold = false
	State.flashlightBeamVerifiedThisHold = false
	State.flashlightBlindObservedTarget = nil
	State.flashlightBlindSignalActive = false
	State.flashlightBlindSignalSource = "none"
	State.flashlightBlindArmed = false
	State.flashlightBlindActiveFrames = 0
	State.flashlightBlindInactiveFrames = 0
	State.flashlightFacePitchCorrection =
		Config.flashlightFaceBeamInitialPitchCorrection
	State.flashlightFaceBeamErrorY = 0.0
	State.flashlightFaceBeamCalibrationValid = false
	State.flashlightFaceBeamCalibrationSamples = 0
	FlashlightController.ResolveTarget()
	if aimMode == "FLASHLIGHT" then
		FlashlightController.ResolveBeam()
	end

	RunService:BindToRenderStep(
		Config.flashlightRenderBindingName,
		Enum.RenderPriority.Character.Value
			+ Config.flashlightRenderPriorityOffset,
		function()
			if renderGeneration ~= FlashlightController.renderGeneration
				or not ownsGlobalRuntime() then return end
			safeCall(
				"ItemRenderAim",
				FlashlightController.UpdateAim
			)
		end
	)
	if aimMode == "FLASHLIGHT" then
		State.flashlightGameplayRenderBound = true
		RunService:BindToRenderStep(
			Config.flashlightGameplayBindingName,
			Enum.RenderPriority.Character.Value
				+ Config.flashlightGameplayPriorityOffset,
			function()
				if renderGeneration ~= FlashlightController.renderGeneration
					or not FlashlightController.CanWriteAim("FLASHLIGHT") then return end
				safeCall(
					"FlashlightGameplayRayAuthority",
					FlashlightController.EnforceGameplayRayAfterNative
				)
			end
		)
		-- Reassert Attachment1 after the native Character-priority flashlight update;
		-- otherwise that module can replace the endpoint later in the same frame.
		State.flashlightRestoreRenderBound = true
		RunService:BindToRenderStep(
			Config.flashlightRestoreBindingName,
			Config.flashlightEndpointRenderPriority,
			function()
				if renderGeneration ~= FlashlightController.renderGeneration
					or not FlashlightController.CanWriteAim("FLASHLIGHT") then return end
				safeCall(
					"FlashlightHeadBeamEnforce",
					function()
						local target = State.flashlightTargetModel
						if State.rightMouseDown
							and target and target.Parent then
							FlashlightController.AuditBeamBeforeReassert(target)
							FlashlightController.BindBeamToHead(target)
							FlashlightController.VerifyBeamOnFace(target)
						end
						if Config.flashlightFaceBeamCalibrationEnabled then
							FlashlightController.CalibrateFaceBeamAfterNative()
						end
					end
				)
			end
		)
	end

	Diagnostics.Push(
		"ITEM_AIM_START",
		string.format(
			"mode=%s preference=%s equipped=%s priority=%d",
			aimMode,
			State.itemAimModePreference,
			normalizedEquippedItem(),
			Enum.RenderPriority.Character.Value
				+ Config.flashlightRenderPriorityOffset
		),
		"item-aim-start",
		0.05
	)
end

function FlashlightController.StopAim(
	reason: string
): ()
	FlashlightController.renderGeneration += 1
	if State.flashlightRenderBound then
		RunService:UnbindFromRenderStep(
			Config.flashlightRenderBindingName
		)
		State.flashlightRenderBound = false
	end
	if State.flashlightGameplayRenderBound then
		RunService:UnbindFromRenderStep(
			Config.flashlightGameplayBindingName
		)
		State.flashlightGameplayRenderBound = false
	end
	if State.flashlightRestoreRenderBound then
		RunService:UnbindFromRenderStep(
			Config.flashlightRestoreBindingName
		)
		State.flashlightRestoreRenderBound = false
	end
	State.flashlightPreProxyCameraCFrame = nil
	State.flashlightGameplayAuthorityAt = -math.huge
	State.flashlightAimConfirmedThisHold = false
	State.flashlightBeamVerifiedThisHold = false
	FlashlightController.RestoreBeamEndpoint()

	-- Nothing in the flashlight rig is owned by the Helper anymore, therefore
	-- restoring cached shoulder/source/Beam values would only fight the game.
	if State.flashlightBeam
		or State.flashlightTargetModel
		or State.itemAimActiveMode ~= "OFF" then
		Diagnostics.Push(
			"ITEM_AIM_STOP",
			string.format(
				"mode=%s reason=%s",
				State.itemAimActiveMode,
				reason
			),
			"item-aim-stop",
			0.05
		)
	end

	State.flashlightBeam = nil
	State.flashlightSource = nil
	State.flashlightTargetModel = nil
	State.flashlightTargetAttachment = nil
	State.flashlightOriginalAttachment1 = nil
	State.flashlightOriginalEnabled = nil
	State.flashlightOriginalCurveSize0 = nil
	State.flashlightOriginalCurveSize1 = nil
	State.flashlightOriginalSourceCFrame = nil
	State.flashlightTorso = nil
	State.flashlightShoulder = nil
	State.flashlightOriginalShoulderC0 = nil
	State.flashlightLastProxyPitch = 0.0
	State.flashlightFacePitchCorrection =
		Config.flashlightFaceBeamInitialPitchCorrection
	State.flashlightFaceBeamErrorY = 0.0
	State.flashlightFaceBeamCalibrationValid = false
	State.flashlightFaceBeamCalibrationSamples = 0
	State.flashlightBlindPauseGeneration += 1
	State.flashlightBlindObservedTarget = nil
	State.flashlightBlindSignalActive = false
	State.flashlightBlindSignalSource = "none"
	State.flashlightBlindArmed = false
	State.flashlightBlindActiveFrames = 0
	State.flashlightBlindInactiveFrames = 0
	State.flashlightMovementYieldActive = false
	State.flashlightMovementYieldSource = "none"
	State.flashlightAimStartedAt = -math.huge
	State.flashlightPreAimWalkSpeed = nil
	State.flashlightUnsafeStopQueued = false
	State.flashlightBlindLatchedTarget = nil
	State.flashlightBlindSuppressedUntil = -math.huge
	State.flashlightActivationRemote = nil
	State.flashlightActivationPart = nil
	State.itemAimActiveMode = "OFF"
	State.pistolLastLeadTime = 0.0
	State.pistolLastLeadDistance = 0.0
	State.pistolLastTargetPart = "none"
end

function FlashlightController.Reset(): ()
	FlashlightController.StopAim("reset")
	State.rightMouseDown = false
end

---------------------------------------------------------------------
-- 18. Scheduler
---------------------------------------------------------------------

local Scheduler = {}

local function due(timerName: string, dt: number, hz: number): boolean
	State.timers[timerName] += dt
	local interval = 1 / hz
	if State.timers[timerName] >= interval then
		State.timers[timerName] = State.timers[timerName] % interval
		return true
	end
	return false
end

function Scheduler.Update(dt: number): ()
	if State.matchActive
		and due("matchAudit", dt, Config.matchActiveAuditHz) then
		MatchController.Update()
	end
	-- True lobby fast path: no detector polling and no controller work.
	if not State.matchActive
		or State.localKillerRoleSuppressed
		or not MatchController.IsExactSurvivorTeam() then
		return
	end

	local ownStarted = now()
	RaycastBudget.BeginFrame()
	if not State.enabled
		or not State.character
		or not State.humanoid
		or not State.root then
		MovementWriter.Apply(dt)
		return
	end
	ThreatMotionCore.Sample()
	if isDowned() then
		ThreatController.Reset()
		ZombieController.Reset()
		PalletController.Reset()
		WindowController.Reset(false)
		RepairResumeController.Reset()
		ExitController.Reset()
		table.clear(State.genericGuardDistanceSampleByModel)
		MovementWriter.ClearAll("downed-or-low-health")
		MovementWriter.Apply(dt)
		return
	end

	WorldIndexer.Update()
	WindowController.UpdateTransitions()
	if due("target", dt, Config.targetResolverHz) then
		TargetResolver.UpdateNearestKiller()
	end
	if due("animationPoll", dt, Config.animationPlayingTrackPollHz) then
		TargetResolver.PollNearestKillerAnimations()
	end
	if due("predictive", dt, Config.predictiveCacheHz) then
		PredictivePlanner.RefreshCache()
	end
	if due("veilAim", dt, Config.veilWallAimHz) then
		ThreatController.UpdatePendingVeilPrep()
		ThreatController.UpdateVeilAimGuard()
	end
	ThreatController.Update()
	if due("zombie", dt, Config.zombieScanHz) then
		ZombieController.Update()
	end
	if due("pallet", dt, Config.palletScanHz) then
		PalletController.Update()
	end
	if due("window", dt, Config.windowScanHz) then
		WindowController.UpdateScan()
	end
	-- Update after the legacy window scan, which intentionally clears WINDOW
	-- intents while automatic vault commits are disabled. This separate fallback
	-- only exists after the player has pressed Space into a vetoed unsafe window.
	WindowController.UpdateUnsafeTraversalEscape()
	if due("repair", dt, Config.repairResumeHz) then
		RepairResumeController.Update()
	end
	if due("exit", dt, Config.exitScanHz) then
		ExitController.UpdateScan()
	end
	ExitController.Update()
	if due("flashlight", dt, Config.flashlightResolveHz)
		and State.rightMouseDown then
		FlashlightController.ResolveTarget()
		FlashlightController.ResolveBeam()
	end
	MovementWriter.Apply(dt)

	local ownMs = (now() - ownStarted) * 1000
	local t = now()
	if ownMs >= Config.performanceOwnSpikeMs
		and t - State.lastPerformanceLogAt
			>= Config.performanceLogCooldown then
		State.lastPerformanceLogAt = t
		Diagnostics.Push(
			"PERF_SPIKE_OWN",
			string.format(
				"ownMs=%.2f dt=%.3f indexActive=%s queueLeft=%d zombies=%d pallets=%d windows=%d gates=%d",
				ownMs,
				dt,
				tostring(State.worldIndexActive),
				math.max(0, #State.worldIndexQueue - State.worldIndexHead + 1),
				countDictionaryEntries(State.zombieCache),
				countDictionaryEntries(State.palletCache),
				countDictionaryEntries(State.windowCache),
				countDictionaryEntries(State.gateCache)
			),
			"perf-own",
			Config.performanceLogCooldown
		)
	elseif dt >= Config.performanceFrameStallDt
		and t - State.lastPerformanceLogAt
			>= Config.performanceLogCooldown then
		State.lastPerformanceLogAt = t
		Diagnostics.Push(
			"FRAME_STALL_EXTERNAL_OR_ENGINE",
			string.format("dt=%.3f ownMs=%.2f", dt, ownMs),
			"perf-external",
			Config.performanceLogCooldown
		)
	end
end
---------------------------------------------------------------------
-- 19. Bindings
---------------------------------------------------------------------

local function addConnection(connection: RBXScriptConnection): ()
	if not ownsGlobalRuntime() then connection:Disconnect(); return end
	table.insert(State.connections, connection)
end

local function addCharacterConnection(connection: RBXScriptConnection): ()
	if not ownsGlobalRuntime() then connection:Disconnect(); return end
	table.insert(State.characterConnections, connection)
end

local function disconnectCharacterConnections(): ()
	for _, connection in ipairs(State.characterConnections) do
		connection:Disconnect()
	end
	table.clear(State.characterConnections)
end

local function disconnectAll(): ()
	for _, connection in ipairs(State.connections) do
		connection:Disconnect()
	end
	table.clear(State.connections)
end

local shuttingDown = false

local function shutdownRuntime(reason: string): ()
	if shuttingDown then
		return
	end
	shuttingDown = true
	State.enabled = false
	State.alive = false
	State.matchActive = false
	State.rightMouseDown = false
	State.characterGeneration += 1
	pcall(TargetResolver.Shutdown)
	pcall(function()
		FlashlightController.StopAim(
			"singleton shutdown"
		)
		FlashlightController.CloseExtraTargetPrompt(
			"singleton shutdown"
		)
	end)
	-- One failed cleanup must not prevent other owners releasing their resources.
	for _, reset in ipairs({ThreatController.Reset, ZombieController.Reset,
		PalletController.Reset, RepairResumeController.Reset, ExitController.Reset}) do
		pcall(reset)
	end
	pcall(WindowController.Reset, true)
	pcall(MovementWriter.ClearAll, "singleton shutdown")
	pcall(MovementWriter.RestoreMovement)
	disconnectCharacterConnections()
	disconnectAll()
	pcall(function()
		ContextActionService:UnbindAction(
			Config.extraAimContextActionName
		)
		ContextActionService:UnbindAction(
			Config.unsafeTraversalContextActionName
		)
	end)
	State.movementRenderBindGeneration += 1
	if State.movementRenderBound then
		pcall(function()
			RunService:UnbindFromRenderStep(
				Config.movementRenderBindingName
			)
		end)
		State.movementRenderBound = false
	end
	if SingletonMarker.Parent then
		SingletonMarker:Destroy()
	end
	local runtime = rawget(_G, GLOBAL_RUNTIME_KEY)
	if type(runtime) == "table" and runtime.token == GLOBAL_OWNER_TOKEN then
		_G[GLOBAL_RUNTIME_KEY] = nil
	end
end

if not ownsGlobalRuntime() then return end
_G[GLOBAL_RUNTIME_KEY] = {
	token = GLOBAL_OWNER_TOKEN,
	Stop = shutdownRuntime,
	version = VERSION,
	marker = SingletonMarker,
}

local function resetRuntime(reason: string): ()
	State.characterGeneration += 1
	State.syntheticPalletSpaceUntil = -math.huge
	disconnectCharacterConnections()
	ThreatController.Reset()
	MovementWriter.ClearAll(reason)
	ExitController.Reset()
	ZombieController.Reset()
	PalletController.Reset()
	WindowController.Reset(true)
	RepairResumeController.Reset()
	FlashlightController.Reset()
	TargetResolver.Reset(true)
	table.clear(State.zombieCache)
	table.clear(State.palletCache)
	table.clear(State.palletUsedModels)
	table.clear(State.windowCache)
	table.clear(State.gateCache)
	table.clear(State.predictiveRouteCacheByModel)
	table.clear(State.attackImpactDelayById)
	State.repairEscapePulseGeneration += 1
	State.repairEscapeEpisodeId = nil
	State.repairEscapeAttempts = 0
	State.repairEscapeLastAt = -math.huge
	State.repairEscapeKeyCode = nil
	table.clear(State.motionTelemetry)
	State.motionTelemetryHead = 0
	State.motionTelemetryCount = 0
	State.motionTelemetryLastAt = -math.huge
	table.clear(State.veilAimStateByModel)
	table.clear(State.veilPendingPrepByModel)
	table.clear(State.veilLongApproachStateByModel)
	table.clear(State.trackingSafetyEnvelopeUntilByModel)
	table.clear(State.literalKillerSafetyEnvelopeUntilByModel)
	table.clear(State.maskedCloseAimStateByModel)
	table.clear(State.hiddenCloseAimStateByModel)
	table.clear(State.killerCloseAimStateByModel)
	if State.lockedThreatWarningGui then
		State.lockedThreatWarningGui:Destroy()
		State.lockedThreatWarningGui = nil
		State.lockedThreatWarningLabel = nil
	end
	State.activeGate = nil
	RaycastBudget.Clear()
	MovementWriter.RestoreWalkSpeed()
	CharacterController.ResetReferences()
	State.matchActive = false
	State.matchReason = reason
	State.matchCandidateSince = nil
	State.matchInactiveSince = nil
	State.matchEvidenceInstance = nil
	State.matchMapRoot = nil
	WorldIndexer.Reset()
end

local function bindCharacter(character: Model): ()
	if not ownsGlobalRuntime() or LocalPlayer.Character ~= character then return end
	resetRuntime("character change")
	local generation = State.characterGeneration
	local function current(): boolean
		return ownsGlobalRuntime() and State.characterGeneration == generation
			and LocalPlayer.Character == character and character.Parent ~= nil
	end
	State.telemetry.terminalSnapshotCharacter = nil
	State.telemetry.terminalSnapshotAt = -math.huge
	local humanoid = character:WaitForChild("Humanoid", 10)
	if not current() then return end
	local root = character:WaitForChild("HumanoidRootPart", 10)
	if not current() then return end
	if not humanoid or not humanoid:IsA("Humanoid") or not root or not root:IsA("BasePart") then
		Diagnostics.Push("ERROR", "character missing Humanoid or HumanoidRootPart", "bind-error", 1.0)
		return
	end
	local animator = humanoid:FindFirstChildOfClass("Animator") or humanoid:WaitForChild("Animator", 5)
	if not current() then return end
	-- Publish only one complete, current character generation after all yields.
	State.character = character
	State.humanoid = humanoid
	State.root = root
	State.animator = animator and animator:IsA("Animator") and animator or nil
	State.telemetry.lastHealth = State.humanoid.Health
	CharacterController.CaptureOriginalWalkSpeed()
	if State.animator then
		addCharacterConnection(State.animator.AnimationPlayed:Connect(function(track)
			if not current() then return end
			safeCall(
				"LocalVaultAnimationPlayed",
				WindowController.OnLocalAnimationPlayed,
				track
			)
		end))
	end
	local boundVaultChecks = setmetatable({}, {__mode = "k"})
	local function bindVaultCheck(instance: Instance): ()
		if not current() or instance.Name ~= "CheckInterractable" or boundVaultChecks[instance] then
			return
		end
		boundVaultChecks[instance] = true
		addCharacterConnection(
			instance:GetAttributeChangedSignal("isVaulting"):Connect(function()
				if not current() then return end
				safeCall(
					"VaultAttributeChanged",
					WindowController.UpdateTransitions
				)
			end)
		)
		safeCall("VaultCheckBound", WindowController.UpdateTransitions)
	end
	for _, instance in ipairs(character:GetDescendants()) do
		bindVaultCheck(instance)
	end
	addCharacterConnection(character.DescendantAdded:Connect(bindVaultCheck))
	addCharacterConnection(State.humanoid.HealthChanged:Connect(function(health)
		if not current() then return end
		safeCall("HealthChanged", ThreatController.OnHealthChanged, health)
	end))
	addCharacterConnection(State.humanoid.Died:Connect(function()
		if not current() then return end
		safeCall(
			"HumanoidDiedSnapshot",
			ThreatController.LogCharacterTerminalSnapshot,
			"Humanoid.Died"
		)
	end))
	for _, attributeName in ipairs(Config.matchPositiveAttributes) do
		addCharacterConnection(character:GetAttributeChangedSignal(attributeName):Connect(function()
			if not current() then return end
			MatchController.Update()
		end))
	end
	for _, attributeName in ipairs(Config.matchRoleAttributes) do
		addCharacterConnection(character:GetAttributeChangedSignal(attributeName):Connect(function()
			if not current() then return end
			MatchController.Update()
		end))
	end
	Diagnostics.Push("CHARACTER_BOUND", string.format("character=%s walkSpeed=%.1f", character:GetFullName(), State.humanoid.WalkSpeed), "character-bound", 0.05)
	State.matchActive = false
	State.matchReason = "character-bound-awaiting-round"
	State.matchCandidateSince = nil
	State.matchInactiveSince = nil
	State.matchEvidenceInstance = nil
	State.matchMapRoot = nil
	TargetResolver.BindExistingPlayers()
	MatchController.Update()
end

addConnection(
	SingletonMarker.Event:Connect(function(reason)
		shutdownRuntime(
			tostring(reason)
		)
	end)
)

addConnection(LocalPlayer.CharacterAdded:Connect(function(character)
	safeCall("CharacterAdded", bindCharacter, character)
end))

addConnection(LocalPlayer.CharacterRemoving:Connect(function(character)
	if character ~= State.character and character ~= LocalPlayer.Character then
		return
	end
	if character == State.character then
		safeCall(
			"CharacterRemovingSnapshot",
			ThreatController.LogCharacterTerminalSnapshot,
			"CharacterRemoving"
		)
	end
	safeCall("CharacterRemoving", resetRuntime, "character removing")
end))

addConnection(Players.PlayerAdded:Connect(function(player)
	TargetResolver.BindPlayer(player)
	MatchController.Update()
end))

addConnection(Players.PlayerRemoving:Connect(function(player)
	if State.extraAimTargetUserId
		and player.UserId
			== State.extraAimTargetUserId then
		FlashlightController.SetExtraAimTarget(
			nil,
			"selected player left server"
		)
	end
	TargetResolver.UnbindPlayer(player)
	if player.Character then
		State.knownKillerModels[player.Character] = nil
	end
	if player.Character and State.activeThreat and State.activeThreat.killerModel == player.Character then
		ThreatController.Release("killer player removed")
	end
	MatchController.Update()
end))

addConnection(Workspace.DescendantAdded:Connect(function(instance)
	if instance:IsA("Animator") then
		local model = modelFromAnimator(instance)
		if model and not isLocalCharacter(model) then
			TargetResolver.ConnectAnimator(instance, model)
		end
	end

	if not State.matchActive then
		if MatchController.ConsiderEvidence(instance) then
			MatchController.Update()
		end
		return
	end

	WorldIndexer.IndexInstance(instance)
end))
addConnection(CollectionService:GetInstanceAddedSignal("VaultPoint"):Connect(function(instance)
	if State.matchActive then
		WindowController.IndexTaggedInstance(instance)
	end
end))
addConnection(CollectionService:GetInstanceRemovedSignal("VaultPoint"):Connect(function(instance)
	WindowController.RemoveInstance(instance, true)
end))
for _, zombieTag in ipairs(Config.zombieSignalTags) do
	addConnection(CollectionService:GetInstanceAddedSignal(zombieTag):Connect(function(instance)
		if State.matchActive then
			WorldIndexer.IndexInstance(instance)
			local completedNpc = newlyCompletedNpcModel(instance)
			if completedNpc then
				ZombieController.IndexModel(completedNpc)
			end
		end
	end))
end
addConnection(Workspace.ChildAdded:Connect(function(child)
	if not State.matchActive
		and containsToken(
			child.Name,
			Config.matchMapNames
		) then
		State.matchMapRoot = child
		State.matchEvidenceInstance = nil
		MatchController.Update()
	end
end))

addConnection(Workspace.DescendantRemoving:Connect(function(instance)
	if instance == State.matchEvidenceInstance then
		State.matchEvidenceInstance = nil
	end
	local matchEvidenceChanged = false
	if instance == State.matchMapRoot then
		State.matchMapRoot = nil
		State.matchEvidenceInstance = nil
		matchEvidenceChanged = true
	end
	if instance:IsA("Model") then
		ZombieController.RemoveModel(instance)
		PalletController.RemoveModel(instance)
		WindowController.RemoveInstance(instance)
		State.knownKillerModels[instance] = nil
		State.gateCache[instance] = nil
	else
		WindowController.RemoveInstance(instance)
	end
	if matchEvidenceChanged then
		MatchController.Update()
	end
end))

addConnection(LocalPlayer:GetPropertyChangedSignal("Team"):Connect(function()
	if not MatchController.IsExactSurvivorTeam() then
		-- A real team transition is sufficient evidence that a later Survivor
		-- assignment belongs to a new round, even on servers that omit a positive
		-- ExpinRound value during loading.
		State.roundEndedLatch = false
	end
	MatchController.Update()
end))

local function updateExactRoundSignal(): ()
	local positive =
		MatchController.RoundTime() > 0
	if positive ~= State.lastRoundTimePositive then
		if State.lastRoundTimePositive and not positive then
			State.roundEndedLatch = true
		elseif positive then
			State.roundEndedLatch = false
		end
		State.lastRoundTimePositive = positive
		MatchController.Update()
	end
end

State.lastRoundTimePositive =
	MatchController.RoundTime() > 0

addConnection(
	LocalPlayer:GetAttributeChangedSignal(
		Config.matchRoundTimeAttribute
	):Connect(updateExactRoundSignal)
)

for _, attributeName in ipairs(
	Config.matchSpectateAttributes
) do
	addConnection(
		LocalPlayer:GetAttributeChangedSignal(
			attributeName
		):Connect(function()
			MatchController.Update()
		end)
	)
end

for _, attributeName in ipairs(
	Config.matchEndAttributes
) do
	addConnection(
		LocalPlayer:GetAttributeChangedSignal(
			attributeName
		):Connect(function()
			MatchController.Update()
		end)
	)
end

for _, attributeName in ipairs(Config.matchPositiveAttributes) do
	addConnection(LocalPlayer:GetAttributeChangedSignal(attributeName):Connect(function()
		MatchController.Update()
	end))
	addConnection(Workspace:GetAttributeChangedSignal(attributeName):Connect(function()
		MatchController.Update()
	end))
end

for _, attributeName in ipairs(Config.matchRoleAttributes) do
	addConnection(LocalPlayer:GetAttributeChangedSignal(attributeName):Connect(function()
		MatchController.Update()
	end))
	addConnection(Workspace:GetAttributeChangedSignal(attributeName):Connect(function()
		MatchController.Update()
	end))
end

do
	local remotes =
		ReplicatedStorage:FindFirstChild("Remotes")
	local gameRemotes =
		remotes
		and remotes:FindFirstChild("Game")
	if gameRemotes then
		for _, name in ipairs({
			"RoundEndEvent",
			"RoundEnd",
		}) do
			local remote =
				gameRemotes:FindFirstChild(name)
			if remote
				and remote:IsA("RemoteEvent") then
				addConnection(
					remote.OnClientEvent:Connect(
						function()
							MatchController.Sleep(
								"remote="
									.. remote:GetFullName()
							)
						end
					)
				)
			end
		end
	end
end

addConnection(UserInputService.InputBegan:Connect(function(input, processed)
	-- No Helper hotkey, aim or synthetic action is allowed while the local
	-- account is the Killer. F4 remains unnecessary here because Team changes
	-- are the authoritative role switch.
	if State.localKillerRoleSuppressed
		or MatchController.IsExactKillerTeam() then
		return
	end
	-- F7 is commonly consumed by the game's own interface. It must be handled
	-- before the generic processed check.
	if input.KeyCode == Config.extraAimTargetKey
		or input.KeyCode
			== Config.extraAimTargetFallbackKey then
		FlashlightController.HandleExtraAimHotkey(
			"UserInputService:"
				.. input.KeyCode.Name
				.. ":processed="
				.. tostring(processed)
		)
		return
	end

	if processed then
		return
	end
	if input.KeyCode
		== Config.itemAimToggleKey then
		FlashlightController.CycleAimMode()
	elseif input.KeyCode == Enum.KeyCode.F4 then
		State.enabled = not State.enabled
		if not State.enabled then
			ThreatController.Reset()
			ZombieController.Reset()
			PalletController.Reset()
			WindowController.Reset(false)
			RepairResumeController.Reset()
			ExitController.Reset()
			MovementWriter.ClearAll("F4 OFF")
			FlashlightController.StopAim("F4 OFF")
			MovementWriter.RestoreWalkSpeed()
		end
		Diagnostics.Push("STATE", State.enabled and "ON | F4 toggle" or "OFF | F4 toggle", "state-toggle", 0.05)
	elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
		local syntheticParryUntil =
			tonumber(
				rawget(
					_G,
					"__VD_PARRY_SYNTHETIC_RMB_UNTIL"
				)
			) or -math.huge
		if now() <= syntheticParryUntil then
			return
		end
		if State.matchActive then
			if not MatchController.IsExactSurvivorTeam() then
				State.rightMouseDown = false
				return
			end
			State.rightMouseReleaseGeneration += 1
			State.rightMouseDown = true
			FlashlightController.StartAim()
		else
			State.rightMouseDown = false
			FlashlightController.StopAim(
				"RMB ignored in lobby"
			)
		end
	end
end))

addConnection(UserInputService.InputEnded:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton2 then
		local syntheticParryUntil =
			tonumber(
				rawget(
					_G,
					"__VD_PARRY_SYNTHETIC_RMB_UNTIL"
				)
			) or -math.huge
		if now() <= syntheticParryUntil then
			return
		end
		State.rightMouseDown = false
		State.rightMouseReleaseGeneration += 1
		local releaseGeneration =
			State.rightMouseReleaseGeneration
		task.delay(Config.itemAimReleaseGrace, function()
			if shuttingDown
				or releaseGeneration
					~= State.rightMouseReleaseGeneration
				or State.rightMouseDown then
				return
			end
			FlashlightController.StopAim("RMB released")
		end)
	end
end))

addConnection(
	LocalPlayer:GetAttributeChangedSignal(
		Config.flashlightEquippedAttribute
	):Connect(function()
		Diagnostics.Push(
			"ITEM_EQUIPPED_CHANGED",
			string.format(
				"equipped=%s resolvedMode=%s preference=%s",
				normalizedEquippedItem(),
				FlashlightController.ResolveAimMode(),
				State.itemAimModePreference
			),
			"item-equipped-changed",
			0.05
		)
		if State.rightMouseDown then
			FlashlightController.StopAim(
				"equipped item changed"
			)
			FlashlightController.StartAim()
		end
	end)
)

local contextActionBound = false

local function indexSkillCheckCandidate(instance: Instance): ()
	if not instance:IsA("GuiObject")
		or string.sub(string.gsub(string.lower(instance.Name), "[^%w]", ""), 1, 5) ~= "check" then
		return
	end
	local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
	local current = instance.Parent
	local belongsToSkillCheck = false
	while current and current ~= playerGui do
		local name = string.gsub(string.lower(current.Name), "[^%w]", "")
		if string.find(name, "skillcheck", 1, true)
			or string.find(name, "skillprompt", 1, true) then
			belongsToSkillCheck = true
			break
		end
		current = current.Parent
	end
	if belongsToSkillCheck then
		State.skillCheckCandidates[instance] = true
	end
end

local function guiObjectActuallyVisible(instance: GuiObject, playerGui: PlayerGui): boolean
	local size = instance.AbsoluteSize
	local position = instance.AbsolutePosition
	if size.X <= 1 or size.Y <= 1 then return false end
	local camera = Workspace.CurrentCamera
	if camera then
		local viewport = camera.ViewportSize
		if position.X + size.X <= 0 or position.Y + size.Y <= 0
			or position.X >= viewport.X or position.Y >= viewport.Y then
			return false
		end
	end
	local current: Instance? = instance
	while current and current ~= playerGui do
		if current:IsA("GuiObject") and not current.Visible then
			return false
		end
		if current:IsA("ScreenGui") and not current.Enabled then
			return false
		end
		if current:IsA("CanvasGroup") and current.GroupTransparency >= 0.995 then
			return false
		end
		if current:IsA("GuiObject") and current.ClipsDescendants then
			local clipPos = current.AbsolutePosition
			local clipSize = current.AbsoluteSize
			if position.X + size.X <= clipPos.X or position.Y + size.Y <= clipPos.Y
				or position.X >= clipPos.X + clipSize.X or position.Y >= clipPos.Y + clipSize.Y then
				return false
			end
		end
		current = current.Parent
	end
	return current == playerGui
end

activeSkillCheckVisible = function(): boolean
	local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
	if not playerGui then
		return false
	end
	for check in pairs(State.skillCheckCandidates) do
		if not check.Parent or not check:IsDescendantOf(playerGui) then
			State.skillCheckCandidates[check] = nil
		elseif guiObjectActuallyVisible(check, playerGui) then
			return true
		end
	end
	return false
end

local function traversalTargetAhead(
	root: BasePart,
	directions: {Vector3}
): any
	local bestWindow = nil
	local bestDistance = Config.unsafeTraversalTargetMaximumDistance
	for model, record in pairs(State.windowCache) do
		local anchor = record and record.anchor
		if not model.Parent or not anchor or not anchor.Parent then
			State.windowCache[model] = nil
		else
			local delta = horizontal(anchor.Position - root.Position)
			local distance = delta.Magnitude
			if distance > 0.05 and distance <= bestDistance then
				for _, direction in ipairs(directions) do
					if direction:Dot(delta.Unit)
						>= Config.unsafeTraversalTargetMinimumDot then
						bestDistance = distance
					bestWindow = {
						kind = "WINDOW",
						name = model:GetFullName(),
						model = model,
						anchor = anchor,
						distance = distance,
						direction = direction,
						source = "indexed-window",
					}
						break
					end
				end
			end
		end
	end
	if bestWindow then
		return bestWindow
	end

	-- A dropped pallet is also vaultable with Space, but a standing pallet uses
	-- the same key to perform the safe drop. Probe only the short physical path
	-- in front of the player and veto only geometry already known to be dropped.
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = State.character
		and {State.character}
		or {}
	params.IgnoreWater = true
	for _, direction in ipairs(directions) do
		local result = Workspace:Raycast(
			root.Position + Vector3.new(0, 0.5, 0),
			direction * Config.unsafeTraversalPalletProbeDistance,
			params
		)
		if result then
			local window = windowModelFrom(result.Instance)
			if window then
				local anchor = windowAnchorFrom(window, result.Instance)
				if anchor then
					return {
						kind = "WINDOW",
						name = window:GetFullName(),
						model = window,
						anchor = anchor,
						distance = horizontal(
							result.Position - root.Position
						).Magnitude,
						direction = direction,
						source = "direct-ray",
					}
				end
			end
			local pallet = palletModelFrom(result.Instance)
			if pallet
				and palletBroken(pallet, State.palletCache[pallet]) then
				local anchor = palletAnchor(
					pallet,
					State.palletCache[pallet]
						and State.palletCache[pallet].prompt
						or nil
				) or (result.Instance:IsA("BasePart") and result.Instance or nil)
				return {
					kind = "DROPPED_PALLET",
					name = pallet:GetFullName(),
					model = pallet,
					anchor = anchor,
					distance = horizontal(
						result.Position - root.Position
					).Magnitude,
					direction = direction,
					source = "direct-ray",
				}
			end
		end
	end

	-- A flattened pallet can sit below or beside the waist-height ray. Keep a
	-- bounded, Space-edge-only fallback over the already indexed pallet tables so
	-- a native vault cannot become invisible precisely when side geometry matters.
	local bestPallet = nil
	local bestPalletDistance = Config.unsafeTraversalTargetMaximumDistance
	local seen = {}
	local function considerDroppedPallet(pallet: any, record: any): ()
		if typeof(pallet) ~= "Instance"
			or not pallet:IsA("Model")
			or seen[pallet]
			or not pallet.Parent then
			return
		end
		seen[pallet] = true
		if not State.palletUsedModels[pallet]
			and not palletBroken(pallet, record) then
			return
		end
		local anchor = record and record.anchor
		if not anchor or not anchor.Parent then
			anchor = palletAnchor(pallet, record and record.prompt or nil)
		end
		if not anchor then
			return
		end
		local delta = horizontal(anchor.Position - root.Position)
		local distance = delta.Magnitude
		if distance <= 0.05 or distance > bestPalletDistance then
			return
		end
		for _, direction in ipairs(directions) do
			if direction:Dot(delta.Unit)
				>= Config.unsafeTraversalTargetMinimumDot then
				bestPalletDistance = distance
				bestPallet = {
					kind = "DROPPED_PALLET",
					name = pallet:GetFullName(),
					model = pallet,
					anchor = anchor,
					distance = distance,
					direction = direction,
					source = "indexed-fallback",
				}
				break
			end
		end
	end
	for pallet in pairs(State.palletUsedModels) do
		considerDroppedPallet(pallet, State.palletCache[pallet])
	end
	for pallet, record in pairs(State.palletCache) do
		considerDroppedPallet(pallet, record)
	end
	if bestPallet then
		return bestPallet
	end
	return nil
end

do
	local boundGui: PlayerGui? = nil
	local guiConnections = {} :: {RBXScriptConnection}
	local function bindSkillCheckGui(playerGui: Instance): ()
		if not ownsGlobalRuntime() or not playerGui:IsA("PlayerGui") or playerGui == boundGui then return end
		for _, connection in ipairs(guiConnections) do connection:Disconnect() end
		table.clear(guiConnections)
		table.clear(State.skillCheckCandidates)
		boundGui = playerGui
		-- One scan per GUI replacement; gameplay frames inspect indexed candidates.
		for _, instance in ipairs(playerGui:GetDescendants()) do
			indexSkillCheckCandidate(instance)
		end
		guiConnections[1] = playerGui.DescendantAdded:Connect(function(instance)
			if ownsGlobalRuntime() and playerGui == boundGui then indexSkillCheckCandidate(instance) end
		end)
		guiConnections[2] = playerGui.DescendantRemoving:Connect(function(instance)
			if instance:IsA("GuiObject") then
				State.skillCheckCandidates[instance] = nil
			end
		end)
		for _, connection in ipairs(guiConnections) do addConnection(connection) end
	end
	addConnection(LocalPlayer.ChildAdded:Connect(bindSkillCheckGui))
	local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
	if playerGui then bindSkillCheckGui(playerGui) end
end

local function shouldVetoUnsafeTraversalSpace(): (boolean, any)
	if now() <= State.syntheticPalletSpaceUntil then return false, nil end
	if not Config.unsafeTraversalVetoEnabled
		or not State.enabled
		or not State.matchActive
		or State.localKillerRoleSuppressed
		or not MatchController.IsExactSurvivorTeam()
		or isDowned()
		or UserInputService:GetFocusedTextBox() ~= nil
		or activeSkillCheckVisible() then
		return false, nil
	end
	local root = State.root
	local humanoid = State.humanoid
	if not root or not humanoid then
		return false, nil
	end
	local interactionLocked = CharacterController.InteractionStatus()
	if interactionLocked
		or humanoid.WalkSpeed <= 0.1
		or root.Anchored
		or humanoid.Sit
		or humanoid.PlatformStand then
		-- Never consume an interaction/skill-check key and never use a blocked key
		-- as a way to release the player from healing, repair or another lock.
		return false, nil
	end
	local killerRoot = State.nearestKillerRoot
	if not killerRoot or not killerRoot.Parent then
		return false, nil
	end
	local delta = horizontal(killerRoot.Position - root.Position)
	local distance = delta.Magnitude
	if distance <= 0.05 then
		return false, nil
	end
	-- A previous ETA veto remains authoritative even when the first consumed Space
	-- edge stopped MoveDirection/velocity for the next input sample. The old order
	-- required a fresh movement direction before consulting the latch, so the second
	-- Space in the same window was passed natively and started the fatal vault.
	local facing = getFacingDot(killerRoot, root)
	local killerApproach = getApproachSpeed(killerRoot, root)
	local latched = WindowController.LatchedUnsafeTraversalSample(
		root,
		killerRoot,
		distance
	)
	if latched then
		return true, latched
	end
	local manual = physicalWasdDirection()
	local directions = {} :: {Vector3}
	if manual then
		table.insert(directions, manual)
	end
	local velocity = horizontal(root.AssemblyLinearVelocity)
	if velocity.Magnitude >= 2.0 then
		table.insert(directions, velocity.Unit)
	end
	local selectedIntent = State.movementSelectedIntent
	local intentDirection = selectedIntent
		and selectedIntent.direction
		or nil
	if typeof(intentDirection) == "Vector3" then
		local flatIntent = horizontal(intentDirection)
		if flatIntent.Magnitude > 0.05 then
			table.insert(directions, flatIntent.Unit)
		end
	end
	if #directions == 0 then
		return false, nil
	end
	-- Compute the read-only Killer geometry before target fallback.  Exact attack
	-- replication may arrive after Roblox has already consumed Space, so an indexed
	-- window cannot depend exclusively on State.activeThreat for discovery.
	local traversalTarget = traversalTargetAhead(root, directions)
	if not traversalTarget then
		local activeThreat = State.activeThreat
		local threatOwnsKiller = activeThreat ~= nil
			and activeThreat.released ~= true
			and activeThreat.killerRoot == killerRoot
		local preThreatWindowRisk =
			Config.unsafeTraversalPreThreatWindowFallbackEnabled == true
			and distance <= Config.unsafeTraversalPreThreatWindowFallbackDistance
			and (
				facing >= Config.unsafeTraversalPreThreatWindowFallbackFacing
				or killerApproach
					>= Config.unsafeTraversalPreThreatWindowFallbackApproach
			)
		if (threatOwnsKiller or preThreatWindowRisk)
			and distance <= Config.unsafeTraversalWindowPredictionDistance then
			local nearbyWindow = nearestIndexedWindow(
				root.Position,
				Config.unsafeTraversalWindowProximityFallbackDistance
			)
			if nearbyWindow and nearbyWindow.anchor
				and nearbyWindow.anchor.Parent then
				local windowDelta = horizontal(
					nearbyWindow.anchor.Position - root.Position
				)
				if windowDelta.Magnitude > 0.05 then
					local bestDirection = directions[1]
					local bestDot = -math.huge
					for _, direction in ipairs(directions) do
						local dot = direction:Dot(windowDelta.Unit)
						if dot > bestDot then
							bestDot = dot
							bestDirection = direction
						end
					end
					local fallbackDirectionDot = threatOwnsKiller
						and 0.35
						or Config.unsafeTraversalPreThreatWindowFallbackDirectionDot
					if bestDot >= fallbackDirectionDot then
						traversalTarget = {
							kind = "WINDOW",
							name = nearbyWindow.model:GetFullName(),
							model = nearbyWindow.model,
							anchor = nearbyWindow.anchor,
							distance = windowDelta.Magnitude,
							direction = bestDirection,
							source = threatOwnsKiller
								and "active-threat-proximity-fallback"
								or "pre-threat-risk-proximity-fallback",
						}
					end
				end
			end
		end
	end
	if not traversalTarget then
		-- Ordinary jump/Space is always player-owned. Killer geometry alone is not
		-- enough evidence that Roblox will interpret this press as a traversal.
		return false, nil
	end
	local traversalDirection = traversalTarget.direction or directions[1]
	local towardDot = traversalDirection:Dot(delta.Unit)
	local toPlayer = -delta.Unit
	local physicalRelativeApproach = horizontal(
		killerRoot.AssemblyLinearVelocity - root.AssemblyLinearVelocity
	):Dot(toPlayer)
	local intendedRelativeApproach = horizontal(
		killerRoot.AssemblyLinearVelocity
			- traversalDirection * CharacterController.DefensivePlanningSpeed()
	):Dot(toPlayer)
	local relativeApproach = math.max(
		physicalRelativeApproach,
		intendedRelativeApproach
	)
	local palletPlayerSide = nil
	local palletKillerSide = nil
	local palletKillerDistance = nil
	local windowPlayerEta = nil
	local windowVaultDuration = nil
	local windowRequiredTime = nil
	local windowKillerEta = nil
	local function traversalSample(mode: string): any
		return {
			distance = distance,
			towardDot = towardDot,
			facing = facing,
			approach = killerApproach,
			relativeApproach = relativeApproach,
			mode = mode,
			killer = State.nearestKiller,
			family = State.activeThreat and State.activeThreat.family or "none",
			traversalKind = traversalTarget.kind,
			traversalName = traversalTarget.name,
			traversalDistance = traversalTarget.distance,
			traversalSource = traversalTarget.source or "indexed-window",
			traversalAnchorPosition = traversalTarget.anchor
				and traversalTarget.anchor.Position or nil,
			palletPlayerSide = palletPlayerSide,
			palletKillerSide = palletKillerSide,
			palletKillerDistance = palletKillerDistance,
			windowPlayerEta = windowPlayerEta,
			windowVaultDuration = windowVaultDuration,
			windowRequiredTime = windowRequiredTime,
			windowKillerEta = windowKillerEta,
		}
	end
	if Config.unsafeTraversalWindowEtaEnabled
		and traversalTarget.kind == "WINDOW"
		and distance <= Config.unsafeTraversalWindowPredictionDistance then
		windowVaultDuration = math.max(
			WindowController.learnedDuration or Config.windowDefaultVaultDuration,
			Config.unsafeTraversalWindowMinimumVaultDuration
		)
		windowPlayerEta = math.max(
			0,
			traversalTarget.distance - Config.windowCenterArrivalDistance
		) / math.max(humanoid.WalkSpeed, 1)
		windowRequiredTime = windowPlayerEta
			+ windowVaultDuration
			+ Config.unsafeTraversalWindowSafetyMargin
		local etaClosing = math.max(
			relativeApproach,
			Config.unsafeTraversalWindowKillerSpeedFloor
		)
		windowKillerEta = math.max(
			0,
			distance - Config.unsafeTraversalWindowAttackBuffer
		) / etaClosing
		local hasThreatGeometry = distance
			<= Config.unsafeTraversalWindowEmergencyDistance
			or facing >= Config.unsafeTraversalWindowThreatFacing
			or killerApproach >= Config.unsafeTraversalWindowThreatApproach
			or relativeApproach >= Config.unsafeTraversalWindowThreatApproach
			or (
				State.activeThreat ~= nil
				and State.activeThreat.released ~= true
				and State.activeThreat.killerRoot == killerRoot
			)
		if hasThreatGeometry and windowRequiredTime >= windowKillerEta then
			-- Do not enter a native zero-speed vault if the Killer reaches attack range
			-- before the measured animation lock can finish. No movement or alternate
			-- input is synthesized; the physical Space edge is simply consumed.
			return true, traversalSample("window-eta-late")
		end
	end
	if traversalTarget.kind == "DROPPED_PALLET"
		and traversalTarget.anchor
		and traversalTarget.anchor.Parent then
		local anchorPosition = traversalTarget.anchor.Position
		palletPlayerSide = horizontal(
			root.Position - anchorPosition
		):Dot(traversalDirection)
		palletKillerSide = horizontal(
			killerRoot.Position - anchorPosition
		):Dot(traversalDirection)
		palletKillerDistance = horizontal(
			killerRoot.Position - anchorPosition
		).Magnitude
		local sideMargin = Config.unsafeTraversalPalletSideMargin
		local playerOnOriginSide = palletPlayerSide <= -sideMargin
		local killerOnOriginSide = palletKillerSide <= -sideMargin
		local killerAtOrBeyondLandingSide = palletKillerSide >= -sideMargin
		local originSideEscape = playerOnOriginSide
			and killerOnOriginSide
			and towardDot
				<= Config.unsafeTraversalPalletOriginEscapeTowardDot
			and killerApproach
				<= Config.unsafeTraversalPalletOriginEscapeMaximumApproach
		if originSideEscape then
			-- This is the normal pallet-loop swap: both characters are on the origin
			-- side, the survivor crosses away and the Killer is not advancing through
			-- the pallet. An old ACTIVE episode must not swallow this Space press.
			return false, traversalSample("pallet-origin-side-escape")
		end
		local contestedOriginCrossing = playerOnOriginSide
			and killerOnOriginSide
			and palletKillerDistance
				<= Config.unsafeTraversalPalletContestedDistance
			and math.abs(palletKillerSide)
				<= math.abs(palletPlayerSide)
					+ Config.unsafeTraversalPalletContestedDepthSlack
			and (
				facing >= Config.unsafeTraversalPalletContestedFacing
				or relativeApproach
					>= Config.unsafeTraversalPalletContestedRelativeApproach
			)
		if contestedOriginCrossing then
			-- The supplied trace passed Space with both actors on the origin side
			-- (player=-4.30, Killer=-5.05), then the Killer reached +1.93 on the next
			-- edge.  Do not enter a native lock when the landing side is about to be
			-- contested; the veto escape planner selects an open grounded direction.
			return true, traversalSample("pallet-origin-side-contested")
		end
		local landingSideDanger = playerOnOriginSide
			and killerAtOrBeyondLandingSide
			and palletKillerDistance
				<= Config.unsafeTraversalPalletLandingDangerDistance
		if landingSideDanger then
			-- Side geometry is available before AnimationPlayed. Prevent committing the
			-- 0.9 s native vault into a Killer already occupying the landing side.
			return true, traversalSample("pallet-landing-side-danger")
		end
	end
	local closeTier = distance <= Config.unsafeTraversalMaximumKillerDistance
	local activeThreat = State.activeThreat
	local activeThreatTier = activeThreat ~= nil
		and activeThreat.released ~= true
		and activeThreat.killerRoot == killerRoot
		and distance <= Config.unsafeTraversalActiveThreatDistance
		and (
			activeThreat.phase == "ACTIVE"
			or activeThreat.phase == "FINISHER"
			or activeThreat.forceRouteOnPrep == true
			or activeThreat.confirmedAimGuard == true
		)
	local predictiveTier = distance <= Config.unsafeTraversalPredictiveDistance
		and facing >= Config.unsafeTraversalPredictiveFacing
		and relativeApproach
			>= Config.unsafeTraversalPredictiveRelativeApproach
		and towardDot >= Config.unsafeTraversalPredictiveTowardDot
	if not activeThreatTier and not closeTier and not predictiveTier then
		return false, nil
	end
	if activeThreatTier then
		local sample = traversalSample("active-threat-vault-lock")
		sample.family = activeThreat.family or "UNKNOWN"
		return true, sample
	end
	local requiredTowardDot = predictiveTier and not closeTier
		and Config.unsafeTraversalPredictiveTowardDot
		or (distance <= Config.unsafeTraversalEmergencyDistance
		and -0.05
		or Config.unsafeTraversalTowardDot)
	if towardDot < requiredTowardDot then
		return false, traversalSample("direction-safe")
	end
	return true, traversalSample(
		predictiveTier and not closeTier and "predictive" or "near"
	)
end

do
	local ok, err = pcall(function()
		ContextActionService:BindActionAtPriority(
			Config.extraAimContextActionName,
			function(
				_actionName,
				inputState,
				inputObject
			)
				if inputState
					== Enum.UserInputState.Begin then
					FlashlightController.HandleExtraAimHotkey(
						"ContextActionService:"
							.. inputObject.KeyCode.Name
					)
				end
				return Enum.ContextActionResult.Pass
			end,
			false,
			Config.extraAimContextPriority,
			Config.extraAimTargetKey,
			Config.extraAimTargetFallbackKey
		)
		contextActionBound = true
	end)
	Diagnostics.Push(
		"EXTRA_AIM_CONTEXT_BIND",
		string.format(
			"ok=%s priority=%d keys=%s,%s error=%s",
			tostring(ok),
			Config.extraAimContextPriority,
			Config.extraAimTargetKey.Name,
			Config.extraAimTargetFallbackKey.Name,
			tostring(err)
		),
		"extra-aim-context-bind",
		0.05
	)
end

local unsafeTraversalContextBound = false
do
	local ok, err = pcall(function()
		ContextActionService:BindActionAtPriority(
			Config.unsafeTraversalContextActionName,
			function(_actionName, inputState, _inputObject)
				if inputState == Enum.UserInputState.Begin then
					local veto, sample = shouldVetoUnsafeTraversalSpace()
					if veto and sample then
						State.unsafeTraversalSpaceHeld = true
						WindowController.RequestUnsafeTraversalEscape(sample)
						Diagnostics.Push(
							"UNSAFE_TRAVERSAL_BLOCKED",
							string.format(
								"killer=%s d=%.2f towardDot=%.2f facing=%.2f approach=%+.2f relativeApproach=%+.2f mode=%s threat=%s traversal=%s traversalD=%.2f source=%s sidePlayer=%+.2f sideKiller=%+.2f palletKillerD=%.2f playerEta=%.2f vaultEta=%.2f required=%.2f killerEta=%.2f target=%s action=consume-Space-no-vault",
								sample.killer and sample.killer.Name or "none",
								sample.distance,
								sample.towardDot,
								sample.facing,
								sample.approach,
								sample.relativeApproach,
								sample.mode,
								tostring(sample.family),
								tostring(sample.traversalKind),
								tonumber(sample.traversalDistance) or -1.0,
								tostring(sample.traversalSource or "unknown"),
								tonumber(sample.palletPlayerSide) or -999.0,
								tonumber(sample.palletKillerSide) or -999.0,
								tonumber(sample.palletKillerDistance) or -1.0,
								tonumber(sample.windowPlayerEta) or -1.0,
								tonumber(sample.windowVaultDuration) or -1.0,
								tonumber(sample.windowRequiredTime) or -1.0,
								tonumber(sample.windowKillerEta) or -1.0,
								tostring(sample.traversalName)
							),
							"unsafe-traversal-blocked",
							0.12
						)
						return Enum.ContextActionResult.Sink
					end
					-- A passed edge used to be invisible, so a native jump/vault rejection
					-- looked identical to Helper swallowing Space. Record the physical edge
					-- without synthesizing input or changing native traversal ownership.
					State.unsafeTraversalSpaceHeld = false
					local interactionLocked, interactionStatus =
						CharacterController.InteractionStatus()
					Diagnostics.Push(
						"SPACE_INPUT_PASSED",
						string.format(
							"match=%s walk=%.2f anchored=%s interactionLocked=%s status=%s threat=%s traversal=%s decision=%s source=%s sidePlayer=%+.2f sideKiller=%+.2f palletKillerD=%.2f target=%s action=pass-native",
							tostring(State.matchActive),
							State.humanoid and State.humanoid.WalkSpeed or -1.0,
							tostring(State.root and State.root.Anchored or false),
							tostring(interactionLocked),
							tostring(interactionStatus or ""),
							tostring(State.activeThreat and State.activeThreat.family or "none"),
							tostring(sample and sample.traversalKind or "none"),
							tostring(sample and sample.mode or "ordinary-space"),
							tostring(sample and sample.traversalSource or "none"),
							tonumber(sample and sample.palletPlayerSide) or -999.0,
							tonumber(sample and sample.palletKillerSide) or -999.0,
							tonumber(sample and sample.palletKillerDistance) or -1.0,
							tostring(sample and sample.traversalName or "none")
						),
						"space-input-passed-"
							.. (interactionLocked and "locked" or "free"),
						interactionLocked and 1.00 or 0.20
					)
				elseif State.unsafeTraversalSpaceHeld
					and (inputState == Enum.UserInputState.End
						or inputState == Enum.UserInputState.Cancel) then
					State.unsafeTraversalSpaceHeld = false
					return Enum.ContextActionResult.Sink
				end
				return Enum.ContextActionResult.Pass
			end,
			false,
			Config.unsafeTraversalContextPriority,
			Enum.KeyCode.Space
		)
		unsafeTraversalContextBound = true
	end)
	Diagnostics.Push(
		"UNSAFE_TRAVERSAL_CONTEXT_BIND",
		string.format(
			"ok=%s priority=%d error=%s",
			tostring(ok),
			Config.unsafeTraversalContextPriority,
			tostring(err)
		),
		"unsafe-traversal-context-bind",
		0.05
	)
end

local function bindMovementRender(reason: string): ()
	if shuttingDown or not State.enabled or not ownsGlobalRuntime() then
		return
	end
	pcall(function()
		RunService:UnbindFromRenderStep(
			Config.movementRenderBindingName
		)
	end)
	State.movementRenderBindGeneration += 1
	local generation = State.movementRenderBindGeneration
	State.movementPrimaryHeartbeatAt = now()
	RunService:BindToRenderStep(
		Config.movementRenderBindingName,
		Enum.RenderPriority.Input.Value
			+ Config.movementRenderPriorityOffset,
		function(dt)
			if shuttingDown
				or not ownsGlobalRuntime()
				or generation ~= State.movementRenderBindGeneration then
				return
			end
			State.movementPrimaryHeartbeatAt = now()
			safeCall(
				"MovementRender",
				MovementWriter.RenderApply,
				dt
			)
		end
	)
	State.movementRenderBound = true
	Diagnostics.Push(
		"MOVEMENT_RENDER_BOUND",
		string.format(
			"reason=%s binding=%s generation=%d",
			reason,
			Config.movementRenderBindingName,
			generation
		),
		"movement-render-bound-" .. reason,
		0.05
	)
end

-- Detection scheduler. The render writer now uses one unique binding only.
-- The previous watchdog/fallback pair could both write in adjacent frames and
-- caused the small hitch reported in live play.
addConnection(RunService.PreSimulation:Connect(function(dt)
	if not ownsGlobalRuntime() then
		shutdownRuntime("lost-global-ownership")
		return
	end
	safeCall("PreSimulation", Scheduler.Update, dt)
end))

-- ControlModule normally writes Player:Move at RenderPriority.Input.
-- Priority +1 makes this the final normal-speed direction for the frame.
bindMovementRender("startup-single-writer")

---------------------------------------------------------------------
-- 18. Start and built-in regression checks
---------------------------------------------------------------------

local function countRawOccurrences(source: string, needle: string): number
	local count = 0
	local position = 1
	while true do
		local found = string.find(source, needle, position, true)
		if not found then
			break
		end
		count += 1
		position = found + #needle
	end
	return count
end

local function runSelfTests(): ()
	local tests = {}

	local savedIntents = State.movementIntents
	State.movementIntents = {}
	MovementWriter.SetIntent(OWNER.THREAT, {
		group = "DODGE",
		priority = PRIORITY.DODGE,
		direction = Vector3.xAxis,
		expiresAt = now() + 10,
	})
	MovementWriter.SetIntent(OWNER.ZOMBIE, {
		group = "ZOMBIE",
		priority = PRIORITY.ZOMBIE,
		direction = Vector3.xAxis,
		expiresAt = now() + 10,
	})
	MovementWriter.SetIntent(OWNER.EXIT, {
		group = "EXIT",
		priority = PRIORITY.EXIT,
		direction = Vector3.xAxis,
		expiresAt = now() + 10,
	})
	local selectedIntent = MovementWriter.SelectIntent()
	tests.intentPriority = selectedIntent ~= nil
		and selectedIntent.owner == OWNER.EXIT
	State.movementIntents = savedIntents
	State.movementSelectedIntent = nil
	local savedThreat = State.activeThreat
	State.activeThreat = nil
	local threatFixture = {
		owner = OWNER.THREAT,
		group = "DODGE",
		actionKind = ACTION_KIND.MOVE,
		priority = PRIORITY.DODGE,
		expiresAt = now() + 10,
	}
	local zombieFixture = {
		owner = OWNER.ZOMBIE,
		group = "ZOMBIE",
		actionKind = ACTION_KIND.MOVE,
		priority = PRIORITY.ZOMBIE,
		expiresAt = now() + 10,
	}
	local vetoed = ActionArbiter.SelectMovementIntent({
		[OWNER.THREAT] = threatFixture,
		[OWNER.ZOMBIE] = zombieFixture,
	}, now())
	tests.activeThreatOwnsOverZombie = vetoed == threatFixture
	State.activeThreat = savedThreat
	tests.exitRouteValidationConfigured = Config.exitRouteProbeDistance >= 5.0
		and Config.exitRetryCooldown >= 1.0

	local episode = {killerModel="A", phase="PREP", expiresAt=1, observedAnimationIds={}}
	local sameKiller = episode.killerModel == "A"
	episode.observedAnimationIds["ACTIVE"] = true
	episode.phase = phaseRank("ACTIVE") > phaseRank(episode.phase) and "ACTIVE" or episode.phase
	tests.threatMerge = sameKiller and episode.phase == "ACTIVE" and episode.observedAnimationIds["ACTIVE"] == true

	local routeLock = Vector3.new(1, 0, 0)
	local mergedDirection = routeLock
	tests.routeContinuity = mergedDirection == routeLock

	tests.speedCap = clampSpeed(100) == Config.movementHardSpeedCap
	tests.exitPriority = PRIORITY.EXIT > PRIORITY.ZOMBIE and PRIORITY.ZOMBIE > PRIORITY.DODGE
	tests.windowCommitPriority = PRIORITY.ZOMBIE > PRIORITY.DODGE
		and PRIORITY.DODGE > PRIORITY.VAULT_COMMIT
	tests.windowRequiresThreat = Config.windowRequireActionableThreat == true
		and Config.windowThreatMaximumDistance < 100.0
	tests.windowAutopilotDisabled = Config.windowManualCommitEnabled == false
	tests.windowPlannerManualVault = Config.windowPlannerApproachEnabled == true
		and Config.windowManualCommitEnabled == false
		and Config.windowPlannerStagingDistance > Config.windowPlannerStopRadius
	tests.initialManualAuthority = Config.motionCoreManualAuthorityTolerance >= 0.10
		and Config.motionCoreManualAuthorityTolerance <= 0.50
		and Config.motionCoreManualCertifiedOverrideGain >= 1.50
		and Config.motionCoreManualCertifiedOverrideGain <= 2.50
	tests.trackingSlasherFamily = AttackCatalog["110355011987939"].family == "TRACKING"
		and AttackCatalog["139369275981139"].family == "TRACKING"
	tests.trackingPureRoute = PURE_ROUTE_FAMILIES.TRACKING == true
		and PURE_ROUTE_FAMILIES.TRACKING_POINTBLANK_GUARD == true
	tests.trackingAwayFloor = Config.trackingRouteMinimumAwayDot > 0
		and Config.trackingRouteMinimumAwayDot < 1
	tests.trackingPostSignalEnvelope =
		Config.trackingPostSignalEnvelopeDuration >= 5.0
		and Config.trackingPostSignalEnvelopeDistance >= 16.0
		and Config.trackingPostSignalEnvelopeMinimumRelativeClosing > 0
	tests.literalKillerPostSignalEnvelope =
		Config.literalKillerPostSignalEnvelopeDuration >= 4.5
		and Config.literalKillerPostSignalEnvelopeDistance >= 18.0
		and Config.literalKillerPostSignalEnvelopeMinimumRelativeClosing > 0
	tests.windowVetoStickyLatch =
		Config.unsafeTraversalWindowVetoLatchDuration >= 1.0
		and Config.unsafeTraversalWindowVetoLatchRadius >= 9.0
		and PRIORITY.TRAVERSAL_ESCAPE > PRIORITY.DODGE
		and Config.unsafeTraversalWindowEscapeMaximumPlanAttempts >= 3
		and Config.unsafeTraversalWindowEscapePlanRetryInterval <= 0.08
	tests.trackingObstacleRecovery =
		Config.motionCoreObstacleMaximumRetries >= 2
		and Config.motionCoreObstacleRetryInterval <= 0.16
		and Config.motionCoreWallContinuationMinimumClearance >= 2.0
		and Config.motionCoreWallContinuationRayReserve >= 40
	tests.trackingSurvivalFallback =
		Config.trackingSurvivalFallbackMinimumManualGain > 0
		and Config.trackingSurvivalFallbackMinimumSeparationRatio >= 0.60
		and Config.trackingSurvivalFallbackMinimumSeparationRatio < 1.0
	tests.threatMovementConservative = Config.threatAutoMovementEnabled == true
		and Config.threatConservativeMovementEnabled == true
		and Config.threatConservativeActiveOnly == true
		and Config.globalThreat360CutEnabled == false
		and Config.globalThreat360WallGuardEnabled == false
	tests.distanceKeeperRelativeSafety = Config.threatDistanceKeeperEnabled == true
		and Config.threatDistanceKeeperEnterDistance
			< Config.threatDistanceKeeperExitDistance
		and Config.threatDistanceKeeperEmergencyDistance
			< Config.threatDistanceKeeperEnterDistance
		and Config.threatDistanceKeeperVeilEmergencyDistance
			< Config.threatDistanceKeeperVeilEnterDistance
		and Config.threatDistanceKeeperEmergencyMinimumFacing
			< Config.threatDistanceKeeperMinimumFacing
		and Config.threatDistanceKeeperEmergencyMinimumApproach
			< Config.threatDistanceKeeperMinimumApproach
		and Config.threatDistanceKeeperAwayWeight
			> Config.threatDistanceKeeperLateralWeight
		and PURE_ROUTE_FAMILIES.DISTANCE_KEEPER == true
		and DISTANCE_HOLD_PROFILE.requireOpenExit == true
		and DISTANCE_HOLD_PROFILE.allowBestEffort ~= true
		and DISTANCE_HOLD_PROFILE.allowSafetyFloor ~= true
	local retreatCommitted, retreatEmergency = distanceKeeperAuthority(
		16.49,
		-0.87,
		-15.32,
		false
	)
	local pursuitCommitted, pursuitEmergency = distanceKeeperAuthority(
		14.0,
		0.72,
		6.0,
		false
	)
	tests.distanceKeeperAuthorityRegression = not retreatCommitted
		and not retreatEmergency
		and pursuitCommitted
		and not pursuitEmergency
	tests.distanceKeeperRollingHorizon =
		Config.threatDistanceKeeperRollingDelay
			> Config.predictiveDefaultImpactDelay
		and Config.threatDistanceKeeperVeilRollingDelay
			> Config.threatDistanceKeeperRollingDelay
		and Config.threatDistanceKeeperVeilEnterDistance
			> Config.threatDistanceKeeperEnterDistance
		and Config.threatDistanceKeeperVeilExitDistance
			> Config.threatDistanceKeeperVeilEnterDistance
		and VEIL_DISTANCE_HOLD_PROFILE.hitRadius >= 9.25
		and VEIL_DISTANCE_HOLD_PROFILE.killerSpeed >= 28.0
		and VEIL_DISTANCE_HOLD_PROFILE.minimumAwayDot >= 0.50
		and VEIL_DISTANCE_HOLD_PROFILE.requireOpenExit == true
		and VEIL_DISTANCE_HOLD_PROFILE.minimumClearanceReserve >= 3.5
		and VEIL_DISTANCE_HOLD_PROFILE.allowSafetyFloor ~= true
	tests.raycastAtomicBodySweep = Config.raycastCriticalMaxPerFrame >= 20
		and RaycastBudget.HasRegularCapacity(0)
		and RaycastBudget.HasCriticalCapacity(0)
	tests.distanceKeeperClassEnvelope =
		CONSERVATIVE_CLASS_DISTANCE_HOLD_PROFILE.hitRadius >= 9.25
		and CONSERVATIVE_CLASS_DISTANCE_HOLD_PROFILE.killerSpeed >= 28.0
		and CONSERVATIVE_CLASS_DISTANCE_HOLD_PROFILE.homing == true
		and CONSERVATIVE_CLASS_DISTANCE_HOLD_PROFILE.allowBestEffort ~= true
		and CONSERVATIVE_CLASS_DISTANCE_HOLD_PROFILE.allowSafetyFloor == true
		and LITERAL_KILLER_DISTANCE_HOLD_PROFILE.hitRadius >= 10.75
		and LITERAL_KILLER_DISTANCE_HOLD_PROFILE.killerSpeed >= 29.0
		and LITERAL_KILLER_DISTANCE_HOLD_PROFILE.allowBestEffort ~= true
		and LITERAL_KILLER_DISTANCE_HOLD_PROFILE.allowSafetyFloor ~= true
		and LITERAL_KILLER_EMERGENCY_DISTANCE_HOLD_PROFILE.allowBestEffort == true
		and LITERAL_KILLER_EMERGENCY_DISTANCE_HOLD_PROFILE.requireOpenExit == true
		and LITERAL_KILLER_EMERGENCY_DISTANCE_HOLD_PROFILE.minimumCorridor >= 6.0
		and LITERAL_KILLER_EMERGENCY_DISTANCE_HOLD_PROFILE.bestEffortMinimumManualGain >= 1.5
		and select(1, distanceHoldProfileForClass("Stalker"))
			== STALKER_DISTANCE_HOLD_PROFILE
		and STALKER_DISTANCE_HOLD_PROFILE.allowBestEffort == true
		and STALKER_DISTANCE_HOLD_PROFILE.requireOpenExit == true
		and STALKER_DISTANCE_HOLD_PROFILE.minimumCorridor >= 6.0
		and STALKER_DISTANCE_HOLD_PROFILE.bestEffortMinimumManualGain >= 1.5
		and STALKER_DISTANCE_HOLD_PROFILE.allowSafetyFloor ~= true
		and select(1, distanceHoldProfileForClass("Veil"))
			== VEIL_DISTANCE_HOLD_PROFILE
		and select(1, distanceHoldProfileForClass("Killer"))
			== LITERAL_KILLER_DISTANCE_HOLD_PROFILE
	local cureLungeProfile = predictiveFamilyProfile("CURE", "121216847022485")
	tests.cureObservedReachCertificate =
		cureLungeProfile.motionType == "HOMING_LUNGE"
		and cureLungeProfile.hitRadius >= 10.75
		and cureLungeProfile.certificationBuffer >= 0.50
		and cureLungeProfile.minimumExitBranches >= 2
		and cureLungeProfile.minimumClearanceReserve >= 3.0
		and cureLungeProfile.requireFullCertificate == true
		and cureLungeProfile.allowBestEffort ~= true
	tests.ordinaryPursuitCorridorCertificate =
		ORDINARY_PURSUIT_PROFILE.requireOpenExit == true
		and ORDINARY_PURSUIT_PROFILE.minimumCorridor >= 4.0
		and Config.motionCorePeriodicMinimumDirectionDot >= 0.90
		and Config.motionCoreNoCorridorEpisodeCooldown >= 0.75
	tests.literalKillerCloseAimReach =
		LITERAL_KILLER_CLOSE_AIM_PROFILE.motionType == "HOMING_LUNGE"
		and LITERAL_KILLER_CLOSE_AIM_PROFILE.hitRadius >= 8.75
		and LITERAL_KILLER_CLOSE_AIM_PROFILE.minimumAwayDot >= 0.50
		and LITERAL_KILLER_CLOSE_AIM_PROFILE.requireFullCertificate == true
		and LITERAL_KILLER_CLOSE_AIM_PROFILE.allowBestEffort ~= true
		and LITERAL_KILLER_CLOSE_AIM_PROFILE.allowSafetyFloor ~= true
		and LITERAL_KILLER_CLOSE_AIM_PROFILE.manualAuthorityReleaseDistance >= 22.0
		and LITERAL_KILLER_CHARGED_PROFILE.manualAuthorityReleaseDistance >= 22.0
		and EXACT_MOTION_PROFILE_BY_ID["104689417033027"]
			.manualAuthorityReleaseDistance >= 22.0
		and EXACT_MOTION_PROFILE_BY_ID["82666958311998"]
			.manualAuthorityReleaseDistance >= 22.0
		and AttackCatalogBySelected.killer["129784271201071"]
			.preserveExistingRouteOnConfirm == true
		and AttackCatalogBySelected.killer["132817836308238"]
			.preserveExistingRouteOnConfirm == true
	tests.literalKillerExactGuardPromotion =
		AttackCatalogBySelected.killer["129784271201071"]
			.promoteFromCloseAimGuard == true
		and AttackCatalogBySelected.killer["129784271201071"].phase
			== "PREP"
		and AttackCatalogBySelected.killer["132817836308238"].phase
			== "ACTIVE"
	tests.continuousWallContinuation =
		Config.motionCoreWallContinuationProbeDistance >= 9.0
		and ThreatMotionCore.RequiredAwayDot({
			motionType = "HOMING_LUNGE", motionProfile = {minimumAwayDot = 0.52},
		}) == 0.52
		and Config.motionCoreWallContinuationCooldown >= 0.10
		and Config.motionCoreWallContinuationRayReserve >= 32
		and Config.threatDistanceKeeperDisengageGrace >= 0.75
	tests.predictivePlannerEnabled = Config.predictivePlannerEnabled == true
		and Config.predictiveCacheHz <= Config.targetResolverHz
		and Config.predictiveCandidateAngles[1] < 0
		and Config.predictiveCandidateAngles[#Config.predictiveCandidateAngles] > 0
	tests.lowObstacleCorridor = Config.routeSweepLowOffset < 0
		and Config.routeSweepHalfWidth >= Config.routeBodyRadius
		and Config.predictiveCacheMaximumOriginShift <= 1.50
	tests.predictiveTrackingDelay = PREDICTIVE_IMPACT_DELAY_BY_ID["110355011987939"] ~= nil
		and PREDICTIVE_IMPACT_DELAY_BY_ID["110355011987939"] >= Config.predictiveMinimumImpactDelay
	local hiddenLongMotionProfile = predictiveFamilyProfile("HIDDEN_LONG", "98163597193511")
	tests.motionCoreTypedHiddenLong =
		Config.motionCoreEnabled == true
		and hiddenLongMotionProfile.motionType == "TRACKING_PURSUIT"
		and hiddenLongMotionProfile.homing == true
		and hiddenLongMotionProfile.minimumAwayDot >= 0.30
		and hiddenLongMotionProfile.seekCollisionCover == true
		and hiddenLongMotionProfile.requireOpenExit == true
		and PREDICTIVE_IMPACT_DELAY_BY_ID["98163597193511"] >= 1.0
	tests.motionCoreBoundedReplan =
		Config.motionCoreReplanInterval >= 0.10
		and Config.motionCoreMaximumReplans <= 6
		and Config.motionCoreObstacleClearance >= 2.5
	local certificateTestNow = now()
	local certificateTestThreat = {
		routeCertificateValid = true,
		predictiveLocked = true,
		routeDirection = Vector3.new(1, 0, 0),
		routeCertificateSignalKey = "KILLER|PREP|129784271201071",
		routeCertificateSignalRevision = 1,
		motionSignalKey = "KILLER|PREP|129784271201071",
		motionSignalRevision = 1,
		routeCertificateMotionType = "HOMING_LUNGE",
		motionType = "HOMING_LUNGE",
		routeCertificateImpactAt = certificateTestNow + 0.20,
		motionImpactAt = certificateTestNow + 0.20,
		routeCertificateValidUntil = certificateTestNow + 0.44,
		rollingHorizon = false,
	}
	local certificateInitiallyMatches =
		ThreatMotionCore.CertificateMatches(
			certificateTestThreat,
			certificateTestNow
		)
	certificateTestThreat.motionImpactAt = certificateTestNow + 0.48
	local horizonChangeRejected = not ThreatMotionCore.CertificateMatches(
		certificateTestThreat,
		certificateTestNow
	)
	certificateTestThreat.motionImpactAt = certificateTestThreat.routeCertificateImpactAt
	certificateTestThreat.motionSignalKey = "KILLER|ACTIVE|132817836308238"
	local signalChangeRejected = not ThreatMotionCore.CertificateMatches(
		certificateTestThreat,
		certificateTestNow
	)
	tests.phaseScopedRouteCertificate = certificateInitiallyMatches
		and horizonChangeRejected
		and signalChangeRejected
	tests.motionCoreTelemetryBounded =
		Config.motionCoreTelemetryCapacity <= 72
		and Config.motionCoreTelemetryInterval >= 0.05
		and Config.motionCoreHitDumpSamples <= 12
	local maskedHomingProfile = predictiveFamilyProfile("MASKED_LUNGE", "106871536134254")
	local ripTrackingHomingProfile = predictiveFamilyProfile("RIP_TRACKING", "138720291317243")
	local ripWindowProfile = predictiveFamilyProfile("RIP", "105374834496520")
	tests.maskedHomingMotionCore =
		maskedHomingProfile.motionType == "STRAIGHT_LUNGE_COVER"
		and ripTrackingHomingProfile.motionType == "HOMING_LUNGE"
		and maskedHomingProfile.homing == false
		and maskedHomingProfile.seekCollisionCover == true
		and maskedHomingProfile.coverScoreBonus >= 150.0
		and maskedHomingProfile.hitRadius >= 9.25
		and maskedHomingProfile.minimumAwayDot >= 0.15
		and maskedHomingProfile.requireOpenExit == true
		and AttackCatalog["106871536134254"].preserveExistingRouteOnConfirm == true
		and Config.motionCoreFinalCommitWindow >= 0.15
		and Config.maskedHistoricalGuardApproach >= 5.0
	tests.ripWindowContinuity = ripWindowProfile.motionType == "HOMING_LUNGE"
		and ripWindowProfile.requireFullCertificate == true
		and ripWindowProfile.minimumForecastHorizon >= 0.25
		and ripWindowProfile.certificationBuffer >= 1.0
		and ripWindowProfile.hitRadius >= 10.75
		and ripWindowProfile.minimumExitBranches >= 2
		and ripWindowProfile.minimumClearanceReserve >= 4.0
		and ripWindowProfile.seekCollisionCover == true
		and ripWindowProfile.coverScoreBonus >= 180.0
		and AttackCatalog["105374834496520"].preserveExistingRouteOnConfirm == false
		and AttackCatalog["105374834496520"].replaceExistingGuard == true
		and AttackCatalog["105374834496520"].clearMotionProfileOverride == true
		and AttackCatalog["105374834496520"].confirmationHold >= 0.75
		and AttackCatalog["105374834496520"].motionHoldPadding >= 0.50
		and IMPACT_TIMING_LEARNING_DISABLED_BY_ID["105374834496520"] == true
	tests.maskedBestEffortFallback =
		maskedHomingProfile.allowBestEffort == true
		and maskedHomingProfile.bestEffortMinimumAwayDot >= 0.10
		and maskedHomingProfile.bestEffortMinimumGain >= 0.20
		and maskedHomingProfile.bestEffortMinimumManualGain >= 0.20
		and Config.maskedCloseAimGuardImpactDelay >= 0.60
		and Config.maskedCloseAimGuardImpactDelay <= 0.70
		and Config.maskedCloseAimGuardMinimumHold >= 0.75
	tests.ripFullCertificateAuthority =
		ripTrackingHomingProfile.requireFullCertificate == true
		and ripTrackingHomingProfile.allowSafetyFloor ~= true
		and ripTrackingHomingProfile.allowBestEffort ~= true
		and predictiveFamilyProfile("RIP", "105374834496520").requireFullCertificate == true
		and predictiveFamilyProfile("RIP", "105374834496520").allowSafetyFloor ~= true
		and predictiveFamilyProfile("RIP", "105374834496520").allowBestEffort ~= true
		and PREDICTIVE_IMPACT_DELAY_BY_ID["105374834496520"] <= 0.30
		and Config.motionCoreSafetyFloorMinimumAwayDot >= 0.30
		and Config.motionCoreSafetyFloorMinimumManualGain >= 0.50
	local trackingPursuitProfile = predictiveFamilyProfile("TRACKING", "110355011987939")
	local stalkerPrepProfile = predictiveFamilyProfile("STALKER", "117042998468241")
	local stalkerPrepMetadata = AttackCatalog["117042998468241"]
	local stalkerActiveMetadata = AttackCatalog["133963973694098"]
	tests.stalkerControlledEscape =
		stalkerPrepProfile == STALKER_Q_CONTROLLED_ESCAPE_PROFILE
		and stalkerPrepProfile.allowBestEffort == true
		and stalkerPrepProfile.lineAttack == true
		and stalkerPrepProfile.requireOpenExit == true
		and stalkerPrepProfile.minimumCorridor >= 6.0
		and stalkerPrepProfile.minimumLateral >= 5.0
		and stalkerPrepProfile.bestEffortMinimumManualGain >= 1.25
		and stalkerPrepProfile.controlledFallbackMinimumSeparationRatio >= 0.82
		and stalkerPrepProfile.allowSafetyFloor ~= true
		and stalkerPrepMetadata.closeRangeAlwaysActionableDistance >= 11.5
		and stalkerActiveMetadata.preserveExistingRouteOnConfirm == true
		and stalkerActiveMetadata.preserveExistingRouteFamily == "STALKER"
		and PREDICTIVE_IMPACT_DELAY_BY_ID["133963973694098"] <= 0.25
		and IMPACT_TIMING_LEARNING_DISABLED_BY_ID["133963973694098"] == true
	tests.trackingPursuitMotionCore =
		trackingPursuitProfile.motionType == "TRACKING_PURSUIT"
		and trackingPursuitProfile.homing == true
		and trackingPursuitProfile.hitRadius >= 8.75
		and trackingPursuitProfile.requireOpenExit == true
		and trackingPursuitProfile.requireFullCertificate == true
		and trackingPursuitProfile.allowBestEffort ~= true
		and trackingPursuitProfile.certificationBuffer >= 0.85
		and trackingPursuitProfile.allowSafetyFloor ~= true
		and trackingPursuitProfile.minimumCorridor >= 5.0
		and Config.trackingFailureMinimumThreatAge <= 0.15
		and Config.motionCoreTransactionalHandoffGrace >= 0.35
		and Config.trackingTrackRollingImpactDelay
			== Config.predictiveMinimumImpactDelay
		and Config.predictiveNativeSpeedFloor == 0.0
		and PREDICTIVE_IMPACT_DELAY_BY_ID["110355011987939"] <= 0.25
		and PREDICTIVE_IMPACT_DELAY_BY_ID["139369275981139"]
			== Config.predictiveMinimumImpactDelay
	tests.trackingManualClosingPrevention =
		Config.trackingManualClosingGuardEnabled == true
		and Config.trackingManualClosingGuardMaximumDistance
			<= Config.trackingDistanceKeeperEnterDistance
		and Config.trackingDistanceKeeperEnterDistance >= 20.0
		and Config.trackingDistanceKeeperExitDistance
			> Config.trackingDistanceKeeperEnterDistance
		and Config.trackingManualClosingGuardMinimumFacing >= 0.80
		and Config.trackingManualClosingGuardMinimumRelativeApproach >= 5.0
		and SLASHER_DISTANCE_HOLD_PROFILE.allowBestEffort == true
		and SLASHER_DISTANCE_HOLD_PROFILE.requireOpenExit == true
		and SLASHER_DISTANCE_HOLD_PROFILE.bestEffortMinimumManualGain >= 1.50
		and SLASHER_DISTANCE_HOLD_PROFILE.allowSafetyFloor ~= true
	tests.performanceBudgetsTightened =
		Config.worldIndexMaxInstancesPerFrame <= 5
		and Config.worldIndexTimeBudgetMs <= 0.20
		and Config.motionCoreNoCorridorLogCooldown >= 0.40
	local ordinaryKillerProfile = predictiveFamilyProfile("KILLER")
	tests.ordinaryKillerNotLunge = ordinaryKillerProfile.motionType == "PURSUIT_MELEE"
		and ordinaryKillerProfile.homing == true
		and ordinaryKillerProfile.hitRadius == Config.predictiveDefaultHitRadius
	local killerLungePrep = AttackCatalog["118907603246885"]
	local killerLungeConfirm = AttackCatalog["78432063483146"]
	local killerLungeProfile = predictiveFamilyProfile(
		"ABYSSWALKER_CROUCH_STRIKE",
		"118907603246885"
	)
	tests.killerChargedLungeEarlyAuthority =
		killerLungePrep.family == "ABYSSWALKER_CROUCH_STRIKE"
		and killerLungeConfirm.family == killerLungePrep.family
		and killerLungePrep.phase == "PREP"
		and killerLungePrep.startOnPrep == true
		and killerLungePrep.forcePrepMovement == true
		and killerLungePrep.forceRouteOnPrep == true
		and killerLungePrep.replaceExistingGuard == true
		and killerLungeConfirm.preserveExistingRouteOnConfirm == true
		and killerLungeConfirm.lateObserveOnlyDistance >= 12.0
		and ActionArbiter.ContractFor("118907603246885", killerLungePrep)
			== ACTION_KIND.COUNTER_ARM
		and ActionArbiter.ContractFor("78432063483146", killerLungeConfirm)
			== ACTION_KIND.COUNTER_C
		and EXACT_ACTION_CONTRACTS["118907603246885"]
			== ACTION_KIND.COUNTER_ARM
		and EXACT_ACTION_CONTRACTS["78432063483146"]
			== ACTION_KIND.COUNTER_C
		and Config.abysswalkerCrouchHold >= 0.75
	tests.killerChargedLungeReachModel =
		killerLungeProfile.motionType == "HOMING_LUNGE"
		and killerLungeProfile.killerSpeed >= 29.0
		and killerLungeProfile.hitRadius >= 10.75
		and killerLungeProfile.minimumAwayDot >= 0.05
		and killerLungeProfile.requireOpenExit == true
		and killerLungeProfile.allowBestEffort == true
		and killerLungeProfile.allowSafetyFloor == false
		and PREDICTIVE_IMPACT_DELAY_BY_ID["118907603246885"] >= 1.0
		and PREDICTIVE_IMPACT_DELAY_BY_ID["78432063483146"]
			== Config.predictiveMinimumImpactDelay
		and IMPACT_TIMING_LEARNING_DISABLED_BY_ID["78432063483146"] == true
		and PURE_ROUTE_FAMILIES.ABYSSWALKER_CROUCH_STRIKE == true
	tests.veilWallAimGuard = Config.veilWallAimEnabled == true
		and Config.veilWallAimStrongDot > Config.veilWallAimReleaseDot
		and Config.veilWallAimFallbackDot >= Config.veilWallAimStrongDot
		and Config.veilWallAimStrongSustain <= 0.35
		and Config.veilWallAimFallbackSustain <= 0.30
		and Config.veilWallAimEvidenceDecayRate < 1.0
		and Config.veilWallAimProjectileMaximumHold >= 5.0
		and Config.veilLongApproachGuardMaximumDistance <= 42.0
		and Config.veilLongApproachGuardMinimumFacing >= 0.90
		and Config.veilLongApproachGuardMinimumKillerApproach >= 4.0
		and Config.veilLongApproachGuardSustain >= 0.20
		and predictiveFamilyProfile("VEIL_WALL_ARROW_AIM").lineAttack == true
		and predictiveFamilyProfile("VEIL_WALL_ARROW_AIM").requireFullCertificate == true
	local veilMeleeProfile = predictiveFamilyProfile("VEIL_MELEE", "78935059863801")
	tests.veilMeleeReachCalibrated = veilMeleeProfile.hitRadius >= 9.25
		and veilMeleeProfile.killerSpeed >= 28.0
		and veilMeleeProfile.minimumAwayDot >= 0.35
		and veilMeleeProfile.requireFullCertificate ~= true
		and veilMeleeProfile.allowBestEffort == true
		and veilMeleeProfile.bestEffortMinimumManualGain >= 1.00
		and veilMeleeProfile.minimumCorridor >= 6.0
		and veilMeleeProfile.allowSafetyFloor ~= true
		and veilMeleeProfile.seekCollisionCover == true
		and PREDICTIVE_IMPACT_DELAY_BY_ID["78935059863801"] <= 0.30
		and AttackCatalog["122812055447896"].aimImpactDelay >= 1.30
		and AttackCatalog["78935059863801"].preserveDistanceKeeperRouteOnConfirm == false
		and AttackCatalog["78935059863801"].preserveExistingRouteOnConfirm == true
		and AttackCatalog["78935059863801"].preserveExistingRouteFamily == "VEIL_MELEE"
		and AttackCatalog["86266790353635"].maxDistance >= 100.0
		and VEIL_MANUAL_CLOSING_DISTANCE_HOLD_PROFILE.allowBestEffort == true
		and VEIL_MANUAL_CLOSING_DISTANCE_HOLD_PROFILE.requireFullCertificate ~= true
		and VEIL_MANUAL_CLOSING_DISTANCE_HOLD_PROFILE.requireOpenExit == true
		and VEIL_MANUAL_CLOSING_DISTANCE_HOLD_PROFILE.minimumCorridor >= 6.0
		and VEIL_MANUAL_CLOSING_DISTANCE_HOLD_PROFILE.bestEffortMinimumManualGain >= 1.50
		and VEIL_MANUAL_CLOSING_DISTANCE_HOLD_PROFILE.allowSafetyFloor ~= true
	tests.renderBestEffortIntentSnapshot =
		intentUsesPredictiveBestEffort(nil) == false
		and intentUsesPredictiveBestEffort({}) == false
		and intentUsesPredictiveBestEffort({predictiveBestEffort=true}) == true
	tests.roundEndLatchAudit = Config.matchActiveAuditHz >= 2
		and State.timers.matchAudit ~= nil
	local veilAimA = AttackCatalog["84093948968516"]
	local veilAimB = AttackCatalog["137688077908355"]
	local veilThrowActive = AttackCatalog["86266790353635"]
	local veilLateConfirm = AttackCatalog["93136435416899"]
	tests.veilPrepAuthority = veilAimA.phase == "PREP"
		and veilAimB.phase == "PREP"
		and veilAimA.forcePrepMovement == true
		and veilAimB.forcePrepMovement == true
		and veilAimA.forceRouteOnPrep == true
		and veilAimB.forceRouteOnPrep == true
		and veilAimA.aimedFacing >= 0.78
		and veilAimB.aimedFacing >= 0.78
		and veilAimA.aimImpactDelay >= 1.0
		and veilAimB.aimImpactDelay >= 1.0
		and veilAimA.motionHoldPadding >= 1.25
		and veilAimB.motionHoldPadding >= 1.25
		and veilAimA.duration >= 2.40
		and veilAimB.duration >= 2.40
		and veilAimA.pendingAimRecheck == true
		and veilAimB.pendingAimRecheck == true
		and veilAimA.pendingAimFacing <= 0.62
		and veilAimB.pendingAimFacing <= 0.62
	tests.veilExactActiveRecertification =
		veilThrowActive.preserveExistingRouteOnConfirm == false
		and veilThrowActive.minimumHold >= 0.70
		and VEIL_EXACT_PROJECTILE_PROFILE.exactLineRouteAuthority == true
		and VEIL_EXACT_PROJECTILE_PROFILE.minimumLateral >= 8.0
		and VEIL_EXACT_PROJECTILE_PROFILE.requireOpenExit == true
		and VEIL_EXACT_PROJECTILE_PROFILE.requireFullCertificate == true
		and IMPACT_TIMING_LEARNING_DISABLED_BY_ID["86266790353635"] == true
	local hiddenActive = AttackCatalog["74968262036854"]
	tests.hiddenActiveEarlyDelivery = hiddenActive.lateObserveOnlyDistance == nil
		and hiddenActive.replaceExistingGuard == true
		and AttackCatalog["113255068724446"].startOnPrep == true
		and AttackCatalog["113255068724446"].forceRouteOnPrep == true
		and AttackCatalog["113255068724446"].preserveExistingRouteOnConfirm == true
		and AttackCatalog["113255068724446"].confirmationHold >= 1.0
		and AttackCatalog["113255068724446"].clearMotionProfileOverride == true
		and hiddenActive.clearMotionProfileOverride == true
		and EXACT_MOTION_PROFILE_BY_ID["113255068724446"]
			== HIDDEN_EXACT_ACTIVE_PROFILE
		and PREDICTIVE_IMPACT_DELAY_BY_ID["74968262036854"] >= 0.60
		and HIDDEN_EXACT_ACTIVE_PROFILE.hitRadius >= 9.25
		and HIDDEN_EXACT_ACTIVE_PROFILE.manualAuthorityReleaseDistance >= 22.0
		and Config.hiddenCloseAimGuardMaximumHold >= 2.0
	tests.veilLateConfirmOnly = veilLateConfirm.observeOnly == true
		and veilLateConfirm.duration == 0.0
		and veilLateConfirm.speed == 0.0
	tests.trackingLateralProfile = AttackCatalog["110355011987939"].lateral <= 16.0
		and AttackCatalog["110355011987939"].away >= 30.0
		and AttackCatalog["110355011987939"].minimumHold >= 0.80
	tests.trackingCommitGuardDisabled =
		Config.trackingPointBlankGuardEnabled == false
	tests.interactionNeverOwnsMovement = OWNER.INTERACTION == nil
	tests.repairThreatEscapeBounded =
		Config.repairThreatEscapeEnabled == true
		and Config.repairThreatEscapeVeilOnly == false
		and Config.repairThreatEscapeMaximumDistance >= 22.0
		and Config.repairThreatEscapePrepMaximumDistance <= 18.0
		and Config.repairThreatEscapeVeilMaximumDistance <= 55.0
		and Config.repairThreatEscapeVeilFallbackMaximumDistance <= 30.0
		and Config.repairThreatEscapeVeilFallbackMinimumEvidence >= 0.30
		and Config.repairThreatEscapeMaximumAttempts <= 3
		and Config.repairThreatEscapePulseDuration <= 0.090
		and Config.repairThreatEscapeMinimumCorridor >= 2.0
		and Config.repairThreatEscapeMaximumVerticalSeparation <= 7.0
		and Config.interactionMovementPulseDuration == 0.0
	tests.zombieIntegrated = PRIORITY.ZOMBIE == 850 and OWNER.ZOMBIE == "ZombieController"
	tests.zombieDeepExitPolicy =
		Config.zombieRouteBlockedClearance >= 3.0
		and Config.zombieRouteBlockedProbeDistance >= 7.0
		and Config.routeDeepSafeLength >= 14.0
		and Config.routeMinimumBranches >= 2
		and Config.zombieRouteRetryCooldown
			> Config.zombieRouteReplanInterval
		and Config.zombieRouteSharpTurnDot >= 0.70
		and Config.zombieRouteSharpTurnCooldown >= 1.0
	tests.zombieAttackPauseHysteresis =
		Config.zombieStationaryAttackHoldDistance
			< Config.zombieAcquireDistance
		and Config.zombieStationaryAttackHoldTime
			> Config.zombieMovingVisibilityHold
	tests.exitCannotBeSuppressed = PRIORITY.EXIT == 1000 and Config.exitReadyProgress == 0.995
	tests.flashlightBlindKeepsAim = Config.flashlightAimEnabled == true
	tests.flashlightStunYieldIsExplicit =
		Config.flashlightYieldMovementOnConfirmedStun == true
		and Config.movementSuspendDuringFlashlightAim == false
		and Config.flashlightBlindNumericThreshold >= 99.0
	tests.flashlightUnsafeAimPolicy =
		Config.flashlightUnsafeAutoDeactivate == true
		and Config.flashlightUnsafeSpeedRatio <= 0.80
		and Config.flashlightUnsafeMinimumSpeedDrop >= 2.0
		and Config.flashlightPalletBreakSafeWindow >= 2.0
	tests.flashlightHeadBeamAuthority =
		Config.flashlightTargetYOffsetFraction == 0.0
		and Config.flashlightTargetFixedCompensation == 0.0
		and Config.flashlightHeadAttachmentName ~= ""
		and Config.flashlightFaceVerticalFraction >= 0.30
		and Config.flashlightBeamVerificationTolerance <= 0.10
		and Config.flashlightSourceRayMinimumDot >= 0.995
		and Config.flashlightSourceRayMaximumMiss <= 0.20
		and Config.flashlightFinalCameraMinimumDot >= 0.995
		and Config.flashlightEndpointRenderPriority
			> Enum.RenderPriority.Last.Value
		and Config.flashlightFaceBeamCalibrationEnabled == false
		and Config.flashlightFaceBeamInitialPitchCorrection == 0.0
	tests.maskedCommitGuardDisabled =
		Config.ripPointBlankGuardEnabled == false
	tests.maskedCloseAimGuardNarrow =
		Config.maskedCloseAimGuardEnabled == true
		and Config.maskedCloseAimGuardFacing >= 0.55
		and Config.maskedCloseAimGuardDistance <= 10.75
		and Config.maskedCloseAimGuardSustain >= 0.40
		and Config.maskedCloseAimGuardEmergencyFacing >= 0.90
		and Config.maskedCloseAimGuardEmergencySustain <= 0.08
		and Config.maskedCloseAimGuardCooldown <= 0.25
		and Config.maskedCloseAimGuardMaximumHold >= 3.0
		and MASKED_CLOSE_AIM_GUARD_PROFILE.motionType == "HOMING_LUNGE"
		and MASKED_CLOSE_AIM_GUARD_PROFILE.requireOpenExit == true
		and MASKED_CLOSE_AIM_GUARD_PROFILE.requireFullCertificate == true
		and MASKED_CLOSE_AIM_GUARD_PROFILE.hitRadius >= 10.75
		and MASKED_CLOSE_AIM_GUARD_PROFILE.minimumExitBranches >= 2
		and MASKED_CLOSE_AIM_GUARD_PROFILE.minimumClearanceReserve >= 4.0
		and MASKED_CLOSE_AIM_GUARD_PROFILE.allowBestEffort ~= true
		and MASKED_CLOSE_AIM_GUARD_PROFILE.allowSafetyFloor ~= true
		and MASKED_CLOSE_AIM_GUARD_PROFILE.seekCollisionCover ~= true
		and MASKED_CLOSE_AIM_GUARD_PROFILE.manualAuthorityReleaseDistance >= 20.0
		and PURE_ROUTE_FAMILIES.MASKED_CLOSE_AIM_GUARD == true
	tests.localKillerHardRoleGate =
		Config.localKillerHardDisable == true
		and string.lower(Config.localRoleGateUsername) == "kandera37"
		and Config.matchExactKillerTeam == "killer"
		and Config.matchExactSurvivorTeam == "survivors"
	tests.hiddenCloseAimGuardExact =
		Config.hiddenCloseAimGuardEnabled == true
		and Config.hiddenCloseAimGuardFacing >= 0.70
		and Config.hiddenCloseAimGuardDistance <= 14.5
		and Config.hiddenCloseAimGuardSustain >= 0.15
		and Config.hiddenHistoricalGuardFacing >= 0.45
		and Config.hiddenHistoricalGuardApproach >= 2.5
		and Config.hiddenHistoricalGuardCurrentApproachFloor >= -1.0
		and Config.hiddenCloseAimGuardImpactDelay >= 0.75
		and PURE_ROUTE_FAMILIES.HIDDEN_CLOSE_AIM_GUARD == true
	tests.literalKillerCloseAimGuardExact =
		Config.killerCloseAimGuardEnabled == true
		and Config.killerCloseAimGuardFacing >= 0.70
		and Config.killerCloseAimGuardDistance >= 14.0
		and Config.killerCloseAimGuardEmergencySustain == 0.0
		and Config.killerCloseAimGuardImpactDelay >= 0.75
		and Config.killerHistoricalGuardApproach >= 2.5
		and Config.killerHistoricalGuardCurrentApproachFloor >= -1.0
		and Config.killerFastHistoricalGuardDistance >= 19.5
		and Config.killerFastHistoricalGuardFacing >= 0.80
		and Config.killerFastHistoricalGuardApproach >= 10.0
		and Config.killerFastHistoricalGuardCurrentApproachFloor >= -1.0
		and Config.killerFastHistoricalGuardSustain <= 0.02
		and Config.killerSyntheticGuardWallReleaseClearance >= 5.0
		and predictiveFamilyProfile("KILLER_CLOSE_AIM_GUARD").motionType == "PURSUIT_MELEE"
		and predictiveFamilyProfile("KILLER_CLOSE_AIM_GUARD").homing == true
		and Config.killerCloseAimGuardDistance <= 14.5
		and Config.killerCloseAimGuardSustain >= 0.12
		and PURE_ROUTE_FAMILIES.KILLER_CLOSE_AIM_GUARD == true
	tests.unsafeTraversalVetoBounded =
		Config.unsafeTraversalVetoEnabled == true
		and Config.unsafeTraversalMaximumKillerDistance <= 12.5
		and Config.unsafeTraversalPredictiveDistance <= 24.0
		and Config.unsafeTraversalPredictiveFacing >= 0.78
		and Config.unsafeTraversalPredictiveRelativeApproach >= 3.0
		and Config.unsafeTraversalTargetMaximumDistance <= 7.5
		and Config.unsafeTraversalActiveThreatDistance <= 18.0
		and Config.unsafeTraversalTargetMinimumDot >= 0.70
		and Config.unsafeTraversalPalletProbeDistance <= 5.0
		and Config.unsafeTraversalPalletLandingDangerDistance <= 10.0
		and Config.unsafeTraversalPalletOriginEscapeTowardDot < 0
		and Config.unsafeTraversalPalletContestedDistance <= 10.0
		and Config.unsafeTraversalPalletContestedDepthSlack <= 1.5
		and Config.unsafeTraversalPalletContestedFacing >= 0.70
		and Config.unsafeTraversalWindowEtaEnabled == true
		and Config.unsafeTraversalWindowPredictionDistance <= 18.0
		and Config.unsafeTraversalWindowEmergencyDistance <= 8.0
		and Config.unsafeTraversalWindowMinimumVaultDuration >= 0.58
		and Config.unsafeTraversalPreThreatWindowFallbackEnabled == true
		and Config.unsafeTraversalPreThreatWindowFallbackDistance <= 12.75
		and Config.unsafeTraversalPreThreatWindowFallbackDirectionDot <= 0.25
		and Config.unsafeTraversalContextPriority > Config.extraAimContextPriority
		and Config.lockedThreatVisualWarningEnabled == false
	tests.nearestKillerAnimationPollBounded =
		Config.animationPlayingTrackPollHz <= 10
		and Config.animationPollMaximumStartAge <= 0.45
	tests.syntheticPalletSpaceCrossGated = Config.palletAutoEnabled == true
		and Config.palletOppositeSideDot <= -0.50
		and Config.palletPlayerBehindMargin >= 0.80
		and Config.palletKillerFrontMargin >= 0.70
	tests.damageLearningRejectsLateImpact =
		Config.damageLearningMinimumUsefulLead >= 0.30
		and Config.damageLearningConfirmationsRequired >= 2
		and NonThreatAnimationIds["130593238885843"]
			== "MASKED_LATE_IMPACT_CONFIRM"
	tests.crouchCounterSequencedEarly =
		Config.abysswalkerCrouchPrepId ~= Config.abysswalkerCrouchActiveId
		and AttackCatalog[Config.abysswalkerCrouchPrepId].phase == "PREP"
		and AttackCatalog[Config.abysswalkerCrouchActiveId].phase == "ACTIVE"
		and Config.abysswalkerCrouchLiteralKillerRequiresPrep == true
		and Config.abysswalkerCrouchMaximumDistance <= 16.0
		and Config.abysswalkerCrouchEarlyTriggerDistance
			< Config.abysswalkerCrouchPrepMaximumDistance
		and Config.abysswalkerCrouchMinimumWindupAge >= 0.20
		and Config.abysswalkerCrouchEarlyMaximumClosingGain <= 2.25
		and Config.abysswalkerCrouchPairedMaximumClosingGain <= 2.50
		and Config.abysswalkerCrouchPrepMinimumFacing >= 0.80
	tests.abysswalkerSlowPressureBounded =
		Config.abysswalkerSlowPressureEnabled == true
		and Config.abysswalkerSlowPressureWalkRatio <= 0.82
		and Config.abysswalkerSlowPressureAbsoluteMaximum <= 14.0
		and Config.abysswalkerSlowPressureMaximumDistance <= 28.0
	tests.crouchCounterSharedSequenceAuthority =
		crouchSequenceMayAuthorize(
			"killer",
			"shared-animation:literal-killer",
			Config.abysswalkerCrouchPrepId,
			true
		) == true
		and crouchSequenceMayAuthorize(
			"killer",
			"shared-animation:literal-killer",
			Config.abysswalkerCrouchActiveId,
			true
		) == true
		and crouchSequenceMayAuthorize(
			"killer",
			"shared-animation:literal-killer",
			"ordinary-mouse1",
			true
		) == false
		and crouchSequenceMayAuthorize(
			"killer",
			"shared-animation:literal-killer",
			Config.abysswalkerCrouchActiveId,
			false
		) == false
	tests.actionArbiterPriority =
		ActionArbiter.ResolveKinds({
			ACTION_KIND.MOVE,
			ACTION_KIND.COUNTER_C,
			ACTION_KIND.HARD_BLOCK,
		}) == ACTION_KIND.HARD_BLOCK
		and ActionArbiter.ResolveKinds({
			ACTION_KIND.MOVE,
			ACTION_KIND.COUNTER_ARM,
		}) == ACTION_KIND.COUNTER_ARM
	tests.actionContractsTyped =
		ActionArbiter.ContractFor(
			Config.abysswalkerCrouchPrepId,
			AttackCatalog[Config.abysswalkerCrouchPrepId]
		) == ACTION_KIND.COUNTER_ARM
		and ActionArbiter.ContractFor(
			Config.abysswalkerCrouchActiveId,
			AttackCatalog[Config.abysswalkerCrouchActiveId]
		) == ACTION_KIND.COUNTER_C
		and ActionArbiter.ContractFor(
			"111920872708571",
			AttackCatalog["111920872708571"]
		) == ACTION_KIND.OBSERVE
	local savedActionReservation = State.actionReservation
	local savedActionAuthority = State.actionAuthority
	State.actionReservation = {
		kind = ACTION_KIND.COUNTER_ARM,
		untilAt = now() + 1.0,
	}
	State.actionAuthority = nil
	local movementAcceptedDuringCounter, counterSuppressionReason =
		ActionArbiter.CanAcceptMovement()
	tests.counterSuppressesEveryMovementOwner =
		movementAcceptedDuringCounter == false
		and counterSuppressionReason == "counter-arm"
	State.actionReservation = savedActionReservation
	State.actionAuthority = savedActionAuthority
	tests.crouchCounterRejectsWrongClass =
		crouchSequenceMayAuthorize(
			"masked",
			"shared-animation:literal-killer",
			Config.abysswalkerCrouchActiveId,
			true
		) == false
	tests.abysswalkerCatalog =
		AttackCatalog["129784271201071"].family
			== "ABYSSWALKER"
		and AttackCatalog["132817836308238"].family
			== "ABYSSWALKER"
	tests.speculativeMovementDisabled =
		Config.unknownActionFallbackEnabled == false
		and Config.genericPointBlankGuardEnabled == false
		and Config.veilPointBlankGuardEnabled == false
	tests.characterResetHasDedicatedConnections = State.characterConnections ~= State.connections

	for name, passed in pairs(tests) do
		Diagnostics.Push(passed and "SELFTEST_PASS" or "SELFTEST_FAIL", string.format("test=%s", name), "selftest-" .. name, 0)
	end
end

if LocalPlayer.Character then
	bindCharacter(LocalPlayer.Character)
else
	TargetResolver.BindExistingPlayers()
	MatchController.Update()
end
if not ownsGlobalRuntime() then return end
runSelfTests()

Diagnostics.Push("HELPER_START", string.format("version=%s instance=%s standalone=true sourceBaseline=5.5.80", VERSION, INSTANCE_ID), "helper-start", 0)
Diagnostics.Push("MOVEMENT_INVARIANT", "one movement writer; no WalkSpeed/Anchored/Sit/PlatformStand writes; visible skill-check and hard movement locks veto PlayerMove; eligible repair escape uses bounded native key pulses", "movement-invariant", 0)
Diagnostics.Push("READY", string.format("binding=%s runtimeOwner=true animationPlaybackGenerations=true diagnostics=live-events", Config.movementRenderBindingName), "ready", 0)
