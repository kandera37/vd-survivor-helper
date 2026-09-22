--!strict
--[[
	VD STANDALONE AUTO-PARRY DAGGER v1.6 FIXED

	Standalone:
	  * does not require Survivor Helper
	  * exact local team: Survivors
	  * exact enemy team: Killer
	  * active only while Parrying Dagger is equipped in Character
	  * reacts only to close melee ACTIVE/FINISHER animations
	  * clean synthetic RMB edge; never holds movement keys
	  * F8 toggles; F10 stops
	  * minimal logs only

	Important:
	  This script sends a normal right-mouse input. It does not invoke damage,
	  parry, or item remotes directly.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local VirtualInputManager = game:GetService("VirtualInputManager")
local VirtualUser = game:GetService("VirtualUser")

local LocalPlayer = Players.LocalPlayer
if not LocalPlayer then
	error("VD AutoParry requires Players.LocalPlayer")
end

local TAG = "[VD PARRY v1.6]"
local SINGLETON_KEY = "__VD_STANDALONE_PARRY_DAGGER_V1"

type AttackProfile = {
	name: string,
	maxDistance: number,
	minFacing: number,
	delay: number,
	minDistance: number?,
	minClosing: number?,
	maximumEta: number?,
}

local CONFIG = {
	enabled = true,
	toggleKey = Enum.KeyCode.F8,
	stopKey = Enum.KeyCode.F10,

	exactSurvivorTeam = "Survivors",
	exactKillerTeam = "Killer",
	expAttribute = "ExpinRound",
	exactTeamRoundFallbackEnabled = true,

	defaultCloseDistance = 10.5,
	fallbackDistance = 4.75,
	fallbackFacing = 0.72,

	inputHold = 0.075,
	parryCooldown = 0.52,
	rebindInterval = 0.35,
	damageFailureWindow = 0.55,
	confirmationWindow = 1.10,

	-- Veil ACTIVE was observed only after closing became negative. Arm on PREP
	-- and fire while the lunge is still approaching.
	veilPrepId = "122812055447896",
	veilActiveId = "78935059863801",
	veilArmDuration = 0.82,
	veilArmMaximumDistance = 17.5,
	veilArmMinimumDistance = 4.25,
	veilArmMinimumFacing = 0.42,
	veilCancelFacing = 0.25,
	veilPassedDistance = 8.0,
	veilPassedClosing = -2.0,
	veilNearDistance = 7.0,
	veilMidDistance = 11.5,
	veilNearDelay = 0.015,
	veilMidDelay = 0.145,
	veilFarDelay = 0.245,
	veilActiveEmergencyMinimumDistance = 4.25,
	veilActiveEmergencyMaximumDistance = 7.25,
	veilActiveEmergencyFacing = 0.55,
	veilActiveEmergencyClosing = 0.25,

	-- Cure's ACTIVE animation was observed at d=2.5 after the useful parry
	-- window and once while facing away. Accept it only in the earlier,
	-- approaching geometry that was observed at d=7.31.
	cureMinimumDistance = 4.25,
	cureMaximumDistance = 9.25,
	cureMinimumFacing = 0.72,
	cureMinimumClosing = 1.25,
	cureMaximumEta = 1.05,

	-- RIP_TRACKING arrived at d=1.50 in the captured log. Use the killer class
	-- and live approach geometry to press before the late animation appears.
	ripMinimumDistance = 3.75,
	ripMaximumDistance = 9.25,
	ripMinimumFacing = 0.62,
	ripMinimumClosing = 1.25,
	ripMaximumEta = 0.90,
	ripProximityMinimumDistance = 4.25,
	ripProximityMaximumDistance = 8.75,
	ripProximityMinimumFacing = 0.72,
	ripProximityMinimumClosing = 3.00,
	ripProximityMaximumEta = 0.78,

	-- First-contact fallback when SelectedKiller is absent. This is deliberately
	-- much stricter than the learned RIP profile and only reacts to a real
	-- close lunge, not ordinary chasing.
	universalRushEnabled = true,
	universalRushMinimumDistance = 4.25,
	universalRushMaximumDistance = 8.25,
	universalRushMinimumFacing = 0.82,
	universalRushMinimumClosing = 5.00,
	universalRushMaximumEta = 0.68,
	universalRushReleaseDistance = 11.5,

	-- Unknown generic melee must never parry a killer who is facing away or
	-- already moving out of contact.
	genericMinimumDistance = 3.50,
	genericMaximumDistance = 8.75,
	genericMinimumFacing = 0.50,
	genericMinimumClosing = 0.75,
	genericMaximumEta = 1.10,

	unknownCloseFallback = false,
	minimalLogs = true,
}

-- ACTIVE/FINISHER melee tracks only.
-- PREP and ranged tracks are intentionally excluded.
local MELEE_ATTACKS: {[string]: AttackProfile} = {
	["82666958311998"] = {
		name = "QUICK",
		maxDistance = 10.5,
		minFacing = -0.05,
		delay = 0.000,
	},
	["138720291317243"] = {
		name = "RIP_TRACKING",
		minDistance = CONFIG.ripMinimumDistance,
		maxDistance = CONFIG.ripMaximumDistance,
		minFacing = CONFIG.ripMinimumFacing,
		minClosing = CONFIG.ripMinimumClosing,
		maximumEta = CONFIG.ripMaximumEta,
		delay = 0.000,
	},
	["110355011987939"] = {
		name = "TRACKING_MELEE",
		maxDistance = 10.5,
		minFacing = 0.15,
		delay = 0.000,
	},
	["77477445889320"] = {
		name = "TRACKING_LUNGE",
		maxDistance = 11.5,
		minFacing = 0.05,
		delay = 0.000,
	},
	["139369275981139"] = {
		name = "SLASHER",
		maxDistance = 10.5,
		minFacing = -0.05,
		delay = 0.000,
	},
	["121571390309073"] = {
		name = "TRACKING_FINISHER",
		maxDistance = 11.5,
		minFacing = -0.10,
		delay = 0.000,
	},
	["74968262036854"] = {
		name = "HIDDEN_ACTIVE",
		maxDistance = 10.5,
		minFacing = -0.15,
		delay = 0.000,
	},
	["135002183282873"] = {
		name = "CURE_MELEE_A",
		minDistance = CONFIG.cureMinimumDistance,
		maxDistance = CONFIG.cureMaximumDistance,
		minFacing = CONFIG.cureMinimumFacing,
		minClosing = CONFIG.cureMinimumClosing,
		maximumEta = CONFIG.cureMaximumEta,
		delay = 0.000,
	},
	["121216847022485"] = {
		name = "CURE_MELEE_B",
		minDistance = CONFIG.cureMinimumDistance,
		maxDistance = CONFIG.cureMaximumDistance,
		minFacing = CONFIG.cureMinimumFacing,
		minClosing = CONFIG.cureMinimumClosing,
		maximumEta = CONFIG.cureMaximumEta,
		delay = 0.000,
	},
	["78432063483146"] = {
		name = "ABYSSWALKER_MELEE",
		maxDistance = 10.5,
		minFacing = -0.05,
		delay = 0.000,
	},
	["118907603246885"] = {
		name = "ABYSSWALKER_LUNGE",
		maxDistance = 11.5,
		minFacing = 0.05,
		delay = 0.000,
	},
	["132817836308238"] = {
		name = "ABYSSWALKER_CHARGED",
		maxDistance = 11.5,
		minFacing = -0.05,
		delay = 0.000,
	},
	["123047897844134"] = {
		name = "ABYSSWALKER_CLOSE_CHAIN",
		maxDistance = 10.5,
		minFacing = -0.20,
		delay = 0.000,
	},
	["133002120549396"] = {
		name = "RUSH_ACTIVE_A",
		maxDistance = 11.5,
		minFacing = -0.05,
		delay = 0.000,
	},
	["130012819736632"] = {
		name = "RUSH_ACTIVE_B",
		maxDistance = 12.0,
		minFacing = -0.15,
		delay = 0.000,
	},
	["105374834496520"] = {
		name = "RIP_LUNGE",
		minDistance = CONFIG.ripMinimumDistance,
		maxDistance = CONFIG.ripMaximumDistance,
		minFacing = CONFIG.ripMinimumFacing,
		minClosing = CONFIG.ripMinimumClosing,
		maximumEta = CONFIG.ripMaximumEta,
		delay = 0.000,
	},
	["111920872708571"] = {
		name = "RIP_COMBO",
		maxDistance = 11.5,
		minFacing = -0.05,
		delay = 0.000,
	},
	["92362656727126"] = {
		name = "RIP_EXTENDED_A",
		maxDistance = 12.0,
		minFacing = -0.10,
		delay = 0.000,
	},
	["115244153053858"] = {
		name = "RIP_EXTENDED_B",
		maxDistance = 12.0,
		minFacing = -0.15,
		delay = 0.000,
	},
	["133963973694098"] = {
		name = "STALKER_ACTIVE",
		maxDistance = 11.5,
		minFacing = -0.15,
		delay = 0.000,
	},
	["79935565590141"] = {
		name = "MASKED_CLOSE",
		maxDistance = 10.5,
		minFacing = -0.05,
		delay = 0.000,
	},
	["133881825716964"] = {
		name = "MASKED_POINT_BLANK",
		maxDistance = 8.5,
		minFacing = 0.05,
		delay = 0.000,
	},
	["102055678391920"] = {
		name = "GENERIC_MELEE",
		minDistance = CONFIG.genericMinimumDistance,
		maxDistance = CONFIG.genericMaximumDistance,
		minFacing = CONFIG.genericMinimumFacing,
		minClosing = CONFIG.genericMinimumClosing,
		maximumEta = CONFIG.genericMaximumEta,
		delay = 0.000,
	},
}

local PARRIED_CONFIRM_ID = "85030641905220"

local NON_THREAT_IDS = {
	["111223305405046"] = true,
	["110466971021611"] = true,
	["102746205979822"] = true,
	["135181748009911"] = true,
}

local RIP_ANIMATION_IDS = {
	["138720291317243"] = true,
	["105374834496520"] = true,
	["111920872708571"] = true,
	["92362656727126"] = true,
	["115244153053858"] = true,
}

local state = {
	running = true,
	enabled = CONFIG.enabled,

	connections = {} :: {RBXScriptConnection},
	killerPlayer = nil :: Player?,
	killerCharacter = nil :: Model?,
	killerAnimator = nil :: Animator?,
	killerAnimationConnection = nil :: RBXScriptConnection?,
	killerCharacterConnection = nil :: RBXScriptConnection?,
	killerBindingGeneration = 0,
	pendingKillerCharacter = nil :: Model?,
	daggerScanCharacter = nil :: Model?,
	daggerScanResult = nil :: Instance?,
	daggerScanAt = -math.huge,

	localHumanoid = nil :: Humanoid?,
	localHealthConnection = nil :: RBXScriptConnection?,
	lastHealth = 0,

	lastBindCheck = -math.huge,
	lastParryAt = -math.huge,
	lastParryId = "none",
	lastParryName = "none",
	lastParryDistance = math.huge,
	lastConfirmedAt = -math.huge,
	learnedRipUserId = nil :: number?,
	universalRushLatched = false,

	veilArmedAt = -math.huge,
	veilArmedCharacter = nil :: Model?,
	veilArmedPrepDistance = math.huge,
	veilArmedBestDistance = math.huge,
	veilArmedLastDistance = math.huge,
	veilFireAt = math.huge,
	veilArmedFired = false,

	lastDaggerReady = false,
	warnedInputFailure = false,

	-- Synthetic RMB ownership. A generation token prevents an old delayed
	-- mouse-up from releasing a newer parry press.
	syntheticRmbDown = false,
	syntheticRmbX = 0,
	syntheticRmbY = 0,
	syntheticRmbBackend = "none",
	syntheticRmbGeneration = 0,
}

local previous = rawget(_G, SINGLETON_KEY)
if type(previous) == "table"
	and type(previous.stop) == "function" then
	pcall(previous.stop, "replaced")
end

local function now(): number
	return os.clock()
end

local function log(message: string): ()
	print(TAG .. " " .. message)
end

local function normalizeName(value: string): string
	return string.lower(value):gsub("[^%w]", "")
end

local function isParryingDaggerName(value: string): boolean
	local normalized = normalizeName(value)
	return string.find(
		normalized,
		"parryingdagger",
		1,
		true
	) ~= nil
		or (
			string.find(normalized, "parry", 1, true) ~= nil
			and string.find(normalized, "dagger", 1, true) ~= nil
		)
end

local function horizontal(value: Vector3): Vector3
	return Vector3.new(value.X, 0, value.Z)
end

-- Must be declared before activeSurvivorRound. In Luau a later local function
-- is not visible to an earlier function body, which previously made line 407
-- resolve modelRoot as a nil global whenever the exact-team fallback ran.
local function modelRoot(model: Model?): BasePart?
	if not model then
		return nil
	end
	return model:FindFirstChild("HumanoidRootPart")
		or model.PrimaryPart
end

local function activeSurvivorRound(): boolean
	local team = LocalPlayer.Team
	if not team
		or team.Name ~= CONFIG.exactSurvivorTeam then
		return false
	end

	local exp = tonumber(
		LocalPlayer:GetAttribute(
			CONFIG.expAttribute
		)
	) or 0
	if exp > 0 then
		return true
	end

	if CONFIG.exactTeamRoundFallbackEnabled then
		for _, player in ipairs(
			Players:GetPlayers()
		) do
			if player ~= LocalPlayer
				and player.Team
				and player.Team.Name
					== CONFIG.exactKillerTeam then
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
	end

	return false
end

local function animationId(track: AnimationTrack): string
	local animation = track.Animation
	local raw = animation and animation.AnimationId or ""
	return string.match(raw, "%d+") or ""
end

local function isActionPriority(
	priority: Enum.AnimationPriority
): boolean
	return priority == Enum.AnimationPriority.Action
		or priority == Enum.AnimationPriority.Action2
		or priority == Enum.AnimationPriority.Action3
		or priority == Enum.AnimationPriority.Action4
end

local function equippedParryingDagger(): Instance?
	local character = LocalPlayer.Character
	if not character then
		return nil
	end

	for _, child in ipairs(character:GetChildren()) do
		if (
			child:IsA("Tool")
			or child:IsA("Model")
			or child:IsA("Folder")
		) and isParryingDaggerName(child.Name) then
			return child
		end
	end

	-- Directly equipped tools stay immediate. Only the uncommon nested-model
	-- fallback is cached, including a negative result when no dagger is equipped.
	if state.daggerScanCharacter ~= character
		or now() - state.daggerScanAt >= CONFIG.rebindInterval then
		state.daggerScanCharacter = character
		state.daggerScanAt = now()
		state.daggerScanResult = nil
		for _, descendant in ipairs(character:GetDescendants()) do
			if isParryingDaggerName(descendant.Name) then
				local current: Instance? = descendant
				while current and current.Parent ~= character do
					current = current.Parent
				end
				if current and current.Parent == character then
					state.daggerScanResult = descendant
					break
				end
			end
		end
	end
	local cached = state.daggerScanResult
	if cached and cached:IsDescendantOf(character) and isParryingDaggerName(cached.Name) then
		return cached
	end

	local possibleAttributes = {
		"EquippedItem",
		"SelectedItem",
		"CurrentItem",
		"ItemName",
	}
	for _, attribute in ipairs(possibleAttributes) do
		local value =
			LocalPlayer:GetAttribute(attribute)
			or character:GetAttribute(attribute)
		if type(value) == "string"
			and isParryingDaggerName(value) then
			return character
		end
	end

	return nil
end

local function exactKillerPlayer(): Player?
	for _, player in ipairs(Players:GetPlayers()) do
		if player ~= LocalPlayer
			and player.Team
			and player.Team.Name
				== CONFIG.exactKillerTeam then
			return player
		end
	end
	return nil
end

local function selectedKillerToken(
	player: Player,
	character: Model?
): string
	local value =
		player:GetAttribute("SelectedKiller")
	if type(value) ~= "string"
		or value == "" then
		value =
			character
			and (
				character:GetAttribute(
					"SelectedKiller"
				)
				or character:GetAttribute(
					"KillerName"
				)
				or character:GetAttribute(
					"Archetype"
				)
			)
			or ""
	end
	return string.lower(
		tostring(value)
	):gsub("[^%w]", "")
end

local function isRipKiller(
	player: Player,
	character: Model?
): boolean
	local token =
		selectedKillerToken(
			player,
			character
		)
	return token == "rip"
		or token == "therip"
		or string.find(
			token,
			"rip",
			1,
			true
		) ~= nil
		or state.learnedRipUserId
			== player.UserId
end

local function localRootAndHumanoid(): (BasePart?, Humanoid?)
	local character = LocalPlayer.Character
	if not character then
		return nil, nil
	end
	local humanoid =
		character:FindFirstChildOfClass("Humanoid")
	local root = modelRoot(character)
	return root, humanoid
end

local function localCombatReady(): boolean
	local _, humanoid = localRootAndHumanoid()
	if not humanoid
		or humanoid.Health <= 20
		or humanoid:GetState()
			== Enum.HumanoidStateType.Dead then
		return false
	end

	local character = LocalPlayer.Character
	if not character then
		return false
	end
	for _, name in ipairs({
		"Downed",
		"Carried",
		"Hooked",
		"IsDowned",
	}) do
		if LocalPlayer:GetAttribute(name) == true
			or character:GetAttribute(name) == true then
			return false
		end
	end
	return true
end

local function attackGeometry(
	killerCharacter: Model
): (number?, number?, number?)
	local localRoot = localRootAndHumanoid()
	local killerRoot = modelRoot(killerCharacter)
	if not localRoot or not killerRoot then
		return nil, nil, nil
	end

	local offset =
		horizontal(
			localRoot.Position - killerRoot.Position
		)
	local distance = offset.Magnitude
	if distance <= 0.001 then
		return distance, 1, 0
	end

	local direction = offset.Unit
	local forward =
		horizontal(
			killerRoot.CFrame.LookVector
		)
	if forward.Magnitude <= 0.001 then
		forward = direction
	else
		forward = forward.Unit
	end

	local facing = forward:Dot(direction)
	local relativeVelocity =
		horizontal(
			killerRoot.AssemblyLinearVelocity
				- localRoot.AssemblyLinearVelocity
		)
	local closing = relativeVelocity:Dot(direction)

	return distance, facing, closing
end

local function clearVeilArm(): ()
	state.veilArmedAt = -math.huge
	state.veilArmedCharacter = nil
	state.veilArmedPrepDistance = math.huge
	state.veilArmedBestDistance = math.huge
	state.veilArmedLastDistance = math.huge
	state.veilFireAt = math.huge
	state.veilArmedFired = false
end

local function releaseSyntheticRightClick(force: boolean?): ()
	-- Invalidate every delayed release scheduled for an older press.
	state.syntheticRmbGeneration += 1

	local wasDown = state.syntheticRmbDown
	if not wasDown and not force then
		return
	end

	local mousePosition = UserInputService:GetMouseLocation()
	local x = wasDown and state.syntheticRmbX
		or math.floor(mousePosition.X)
	local y = wasDown and state.syntheticRmbY
		or math.floor(mousePosition.Y)
	state.syntheticRmbDown = false
	state.syntheticRmbBackend = "none"

	-- Send both supported mouse-up forms. Mouse-up is idempotent and this makes
	-- stop/reload safe even if the original backend changed or partially failed.
	pcall(function()
		VirtualInputManager:SendMouseButtonEvent(
			x,
			y,
			1,
			false,
			game,
			0
		)
	end)

	local camera = workspace.CurrentCamera
	if camera then
		pcall(function()
			VirtualUser:Button2Up(
				Vector2.new(x, y),
				camera.CFrame
			)
		end)
	end

	rawset(
		_G,
		"__VD_PARRY_SYNTHETIC_RMB_UNTIL",
		now()
	)
end

local function scheduleSyntheticRightClickRelease(
	generation: number
): ()
	task.delay(CONFIG.inputHold, function()
		if state.syntheticRmbGeneration == generation then
			releaseSyntheticRightClick()
		end
	end)
end

local function markSyntheticRightClickDown(
	x: number,
	y: number,
	backend: string
): number
	state.syntheticRmbGeneration += 1
	state.syntheticRmbDown = true
	state.syntheticRmbX = x
	state.syntheticRmbY = y
	state.syntheticRmbBackend = backend
	return state.syntheticRmbGeneration
end

local function sendRightClick(): (boolean, string)
	if UserInputService:GetFocusedTextBox() then
		return false, "textbox"
	end
	if UserInputService:IsMouseButtonPressed(
		Enum.UserInputType.MouseButton2
	) then
		return false, "physical-rmb-held"
	end

	local adapter = rawget(_G, "VDParryRightClick")
	if type(adapter) == "function" then
		-- The Helper ignores RMB while this marker is active. External adapters
		-- must receive the same protection as the built-in input backends.
		rawset(
			_G,
			"__VD_PARRY_SYNTHETIC_RMB_UNTIL",
			now() + CONFIG.inputHold + 0.16
		)
		local ok, result = pcall(adapter)
		-- Nil is accepted for backwards compatibility. An explicit false means
		-- the adapter declined or failed to send the click.
		if ok and result ~= false then
			return true, "external-adapter"
		end
		rawset(
			_G,
			"__VD_PARRY_SYNTHETIC_RMB_UNTIL",
			now()
		)
	end

	local mousePosition =
		UserInputService:GetMouseLocation()
	local x = math.floor(mousePosition.X)
	local y = math.floor(mousePosition.Y)

	-- Never let a stale delayed release from an older press interfere with the
	-- new edge. This also repairs a press left down by an interrupted reload.
	releaseSyntheticRightClick(true)

	rawset(
		_G,
		"__VD_PARRY_SYNTHETIC_RMB_UNTIL",
		now() + CONFIG.inputHold + 0.16
	)

	-- Force a clean up -> down edge.
	pcall(function()
		VirtualInputManager:SendMouseButtonEvent(
			x,
			y,
			1,
			false,
			game,
			0
		)
	end)

	local downOk = pcall(function()
		VirtualInputManager:SendMouseButtonEvent(
			x,
			y,
			1,
			true,
			game,
			0
		)
	end)
	if downOk then
		local generation = markSyntheticRightClickDown(
			x,
			y,
			"virtual-input"
		)
		scheduleSyntheticRightClickRelease(generation)
		return true, "virtual-input"
	end

	local camera = workspace.CurrentCamera
	if camera then
		local virtualOk = pcall(function()
			VirtualUser:Button2Down(
				Vector2.new(x, y),
				camera.CFrame
			)
		end)
		if virtualOk then
			local generation = markSyntheticRightClickDown(
				x,
				y,
				"virtual-user"
			)
			scheduleSyntheticRightClickRelease(generation)
			return true, "virtual-user"
		end
	end

	rawset(
		_G,
		"__VD_PARRY_SYNTHETIC_RMB_UNTIL",
		now()
	)
	return false, "input-failed"
end

local function profileGeometryAllowed(
	profile: AttackProfile,
	distance: number,
	facing: number,
	closing: number
): (boolean, string, number)
	local minimumDistance =
		profile.minDistance or 0
	local minimumClosing =
		profile.minClosing or -math.huge
	local maximumEta =
		profile.maximumEta or math.huge
	local eta =
		closing > 0.05
			and distance / closing
			or math.huge

	if distance < minimumDistance then
		return false, "too-late-pointblank", eta
	end
	if distance > profile.maxDistance then
		return false, "too-far", eta
	end
	if facing < profile.minFacing then
		return false, "not-facing-survivor", eta
	end
	if closing < minimumClosing then
		return false, "not-approaching-fast-enough", eta
	end
	if eta > maximumEta then
		return false, "eta-too-long", eta
	end

	return true, "accepted", eta
end

local function attemptParry(
	id: string,
	profile: AttackProfile,
	killerCharacter: Model,
	isFallback: boolean
): boolean
	if not state.running
		or not state.enabled
		or not activeSurvivorRound()
		or not localCombatReady() then
		return false
	end

	if not equippedParryingDagger() then
		return false
	end

	local t = now()
	if t - state.lastParryAt
		< CONFIG.parryCooldown then
		return false
	end

	local distance, facing, closing =
		attackGeometry(killerCharacter)
	if not distance or not facing or not closing then
		return false
	end

	local allowed, geometryReason, eta =
		profileGeometryAllowed(
			profile,
			distance,
			facing,
			closing
		)
	if not allowed then
		if string.find(
			profile.name,
			"CURE_",
			1,
			true
		)
			or string.find(
				profile.name,
				"RIP_",
				1,
				true
			)
			or profile.name
				== "GENERIC_MELEE" then
			log(
				string.format(
					"[PARRY_SKIP] attack=%s id=%s reason=%s d=%.2f facing=%.2f closing=%+.2f eta=%s",
					profile.name,
					id,
					geometryReason,
					distance,
					facing,
					closing,
					eta < math.huge
						and string.format("%.3f", eta)
						or "inf"
				)
			)
		end
		return false
	end

	local function fire(): boolean
		if not state.running
			or not state.enabled
			or not activeSurvivorRound()
			or not localCombatReady()
			or not equippedParryingDagger() then
			return false
		end

		local currentDistance,
			currentFacing,
			currentClosing =
				attackGeometry(killerCharacter)
		if not currentDistance
			or not currentFacing
			or not currentClosing then
			return false
		end

		local stillAllowed,
			currentGeometryReason,
			currentEta =
				profileGeometryAllowed(
					profile,
					currentDistance,
					currentFacing,
					currentClosing
				)
		if not stillAllowed then
			if string.find(
				profile.name,
				"CURE_",
				1,
				true
			)
				or string.find(
					profile.name,
					"RIP_",
					1,
					true
				)
				or profile.name
					== "GENERIC_MELEE" then
				log(
					string.format(
						"[PARRY_SKIP] attack=%s id=%s reason=%s d=%.2f facing=%.2f closing=%+.2f eta=%s stage=fire-recheck",
						profile.name,
						id,
						currentGeometryReason,
						currentDistance,
						currentFacing,
						currentClosing,
						currentEta < math.huge
							and string.format(
								"%.3f",
								currentEta
							)
							or "inf"
					)
				)
			end
			return false
		end

		local sent, method = sendRightClick()
		if not sent then
			if method == "input-failed"
				and not state.warnedInputFailure then
				state.warnedInputFailure = true
				warn(
					TAG
						.. " synthetic RMB unavailable; "
						.. "provide _G.VDParryRightClick"
				)
			end
			return false
		end

		state.lastParryAt = now()
		state.lastParryId = id
		state.lastParryName = profile.name
		state.lastParryDistance =
			currentDistance

		log(
			string.format(
				"[PARRY_INPUT] attack=%s id=%s d=%.2f facing=%.2f closing=%+.2f eta=%s method=%s fallback=%s t=%.3f",
				profile.name,
				id,
				currentDistance,
				currentFacing,
				currentClosing,
				currentEta < math.huge
					and string.format(
						"%.3f",
						currentEta
					)
					or "inf",
				method,
				tostring(isFallback),
				now()
			)
		)
		return true
	end

	if profile.delay > 0 then
		task.delay(profile.delay, fire)
		-- A delayed input has only been scheduled, not sent. Callers must not
		-- latch the attack until fire() actually succeeds.
		return false
	end

	return fire()
end



local function updateRipProximityParry(): ()
	if not state.running
		or not state.enabled
		or not activeSurvivorRound()
		or not localCombatReady()
		or not equippedParryingDagger() then
		return
	end

	if now() - state.lastParryAt
		< CONFIG.parryCooldown then
		return
	end

	local killer = exactKillerPlayer()
	local character =
		killer and killer.Character or nil
	if not killer or not character then
		return
	end

	local distance, facing, closing =
		attackGeometry(character)
	if not distance or not facing or not closing then
		return
	end

	if distance >= CONFIG.universalRushReleaseDistance
		or closing < -1.0 then
		state.universalRushLatched = false
	end
	if state.universalRushLatched then
		return
	end

	local knownRip =
		isRipKiller(killer, character)
	local minimumDistance =
		knownRip
			and CONFIG.ripProximityMinimumDistance
			or CONFIG.universalRushMinimumDistance
	local maximumDistance =
		knownRip
			and CONFIG.ripProximityMaximumDistance
			or CONFIG.universalRushMaximumDistance
	local minimumFacing =
		knownRip
			and CONFIG.ripProximityMinimumFacing
			or CONFIG.universalRushMinimumFacing
	local minimumClosing =
		knownRip
			and CONFIG.ripProximityMinimumClosing
			or CONFIG.universalRushMinimumClosing
	local maximumEta =
		knownRip
			and CONFIG.ripProximityMaximumEta
			or CONFIG.universalRushMaximumEta

	if not knownRip
		and not CONFIG.universalRushEnabled then
		return
	end

	local eta =
		closing > 0.05
			and distance / closing
			or math.huge
	if distance < minimumDistance
		or distance > maximumDistance
		or facing < minimumFacing
		or closing < minimumClosing
		or eta > maximumEta then
		return
	end

	local sent = attemptParry(
		knownRip
			and "RIP_PROXIMITY_GUARD"
			or "UNIVERSAL_RUSH_GUARD",
		{
			name =
				knownRip
					and "RIP_PROXIMITY_EARLY"
					or "UNIVERSAL_RUSH_EARLY",
			minDistance = minimumDistance,
			maxDistance = maximumDistance,
			minFacing = minimumFacing,
			minClosing = minimumClosing,
			maximumEta = maximumEta,
			delay = 0,
		},
		character,
		false
	)
	if sent then
		state.universalRushLatched = true
	end
end

local function armVeilPrep(
	killerCharacter: Model
): ()
	if not state.running
		or not state.enabled
		or not activeSurvivorRound()
		or not localCombatReady()
		or not equippedParryingDagger() then
		return
	end

	local distance, facing, closing =
		attackGeometry(killerCharacter)
	if not distance or not facing or not closing then
		return
	end

	if distance > CONFIG.veilArmMaximumDistance
		or distance < CONFIG.veilArmMinimumDistance
		or facing < CONFIG.veilArmMinimumFacing then
		return
	end

	local delay =
		if distance <= CONFIG.veilNearDistance then
			CONFIG.veilNearDelay
		elseif distance <= CONFIG.veilMidDistance then
			CONFIG.veilMidDelay
		else
			CONFIG.veilFarDelay

	local t = now()
	state.veilArmedAt = t
	state.veilArmedCharacter = killerCharacter
	state.veilArmedPrepDistance = distance
	state.veilArmedBestDistance = distance
	state.veilArmedLastDistance = distance
	state.veilFireAt = t + delay
	state.veilArmedFired = false

	log(
		string.format(
			"[VEIL_ARM] prepId=%s d=%.2f facing=%.2f closing=%+.2f scheduledDelay=%.3f",
			CONFIG.veilPrepId,
			distance,
			facing,
			closing,
			delay
		)
	)
end

local function updateVeilArmedParry(): ()
	local character =
		state.veilArmedCharacter
	if not character then
		return
	end

	local t = now()
	local age = t - state.veilArmedAt
	if age > CONFIG.veilArmDuration then
		clearVeilArm()
		return
	end
	if state.veilArmedFired then
		return
	end

	if not state.running
		or not state.enabled
		or not activeSurvivorRound()
		or not localCombatReady()
		or not equippedParryingDagger() then
		clearVeilArm()
		return
	end

	local distance, facing, closing =
		attackGeometry(character)
	if not distance or not facing or not closing then
		return
	end

	state.veilArmedBestDistance =
		math.min(
			state.veilArmedBestDistance,
			distance
		)

	if distance > CONFIG.veilArmMaximumDistance + 1.5
		or facing < CONFIG.veilCancelFacing then
		clearVeilArm()
		return
	end

	local clearlyPassed =
		distance <= CONFIG.veilPassedDistance
			and closing <= CONFIG.veilPassedClosing
			and age >= 0.12
	if clearlyPassed then
		log(
			string.format(
				"[VEIL_SKIP] reason=passed-before-fire age=%.3f d=%.2f facing=%.2f closing=%+.2f",
				age,
				distance,
				facing,
				closing
			)
		)
		clearVeilArm()
		return
	end

	state.veilArmedLastDistance = distance
	if t < state.veilFireAt then
		return
	end

	local sent = attemptParry(
		CONFIG.veilPrepId,
		{
			name = "VEIL_PREP_SCHEDULED",
			minDistance =
				CONFIG.veilArmMinimumDistance,
			maxDistance =
				CONFIG.veilArmMaximumDistance,
			minFacing =
				CONFIG.veilCancelFacing,
			delay = 0,
		},
		character,
		false
	)

	if sent then
		state.veilArmedFired = true
		log(
			string.format(
				"[VEIL_FIRE] age=%.3f scheduled=%.3f prepD=%.2f currentD=%.2f bestD=%.2f facing=%.2f closing=%+.2f",
				age,
				state.veilFireAt - state.veilArmedAt,
				state.veilArmedPrepDistance,
				distance,
				state.veilArmedBestDistance,
				facing,
				closing
			)
		)
	end
end

local function onKillerAnimation(
	track: AnimationTrack,
	killerCharacter: Model
): ()
	if not state.running then
		return
	end

	local id = animationId(track)
	if id == "" then
		return
	end

	if RIP_ANIMATION_IDS[id] then
		local player =
			Players:GetPlayerFromCharacter(
				killerCharacter
			)
		if player
			and state.learnedRipUserId
				~= player.UserId then
			state.learnedRipUserId =
				player.UserId
			log(
				string.format(
					"[RIP_LEARNED] player=%s userId=%d sourceId=%s",
					player.Name,
					player.UserId,
					id
				)
			)
		end
	end

	if NON_THREAT_IDS[id] then
		return
	end

	if id == CONFIG.veilPrepId then
		armVeilPrep(killerCharacter)
		return
	end

	if id == CONFIG.veilActiveId then
		if state.veilArmedCharacter ~= killerCharacter
			or now() - state.veilArmedAt > CONFIG.veilArmDuration then
			clearVeilArm()
		end
		local distance, facing, closing =
			attackGeometry(killerCharacter)
		if not state.veilArmedFired
			and localCombatReady()
			and distance
			and facing
			and closing
			and distance
				>= CONFIG.veilActiveEmergencyMinimumDistance
			and distance
				<= CONFIG.veilActiveEmergencyMaximumDistance
			and facing
				>= CONFIG.veilActiveEmergencyFacing
			and closing
				>= CONFIG.veilActiveEmergencyClosing then
			local sent = attemptParry(
				id,
				{
					name = "VEIL_ACTIVE_EMERGENCY",
					minDistance =
						CONFIG.veilActiveEmergencyMinimumDistance,
					maxDistance =
						CONFIG.veilActiveEmergencyMaximumDistance,
					minFacing =
						CONFIG.veilActiveEmergencyFacing,
					minClosing =
						CONFIG.veilActiveEmergencyClosing,
					delay = 0,
				},
				killerCharacter,
				false
			)
			if sent then
				state.veilArmedCharacter = killerCharacter
				state.veilArmedAt = now()
				state.veilArmedFired = true
			end
		end
		return
	end

	if id == PARRIED_CONFIRM_ID then
		if now() - state.lastParryAt
			<= CONFIG.confirmationWindow then
			state.lastConfirmedAt = now()
			log(
				string.format(
					"[PARRY_ANIMATION_CONFIRMED] attack=%s sourceId=%s confirmId=%s",
					state.lastParryName,
					state.lastParryId,
					id
				)
			)
		end
		return
	end

	local profile = MELEE_ATTACKS[id]
	if profile then
		attemptParry(
			id,
			profile,
			killerCharacter,
			false
		)
		return
	end

	if not CONFIG.unknownCloseFallback
		or not localCombatReady()
		or not isActionPriority(track.Priority) then
		return
	end

	local distance, facing =
		attackGeometry(killerCharacter)
	if not distance or not facing then
		return
	end

	-- Extremely strict fallback: unknown Action track only at point-blank range.
	if distance <= CONFIG.fallbackDistance
		and facing >= CONFIG.fallbackFacing then
		attemptParry(
			id,
			{
				name = "UNKNOWN_POINT_BLANK",
				maxDistance =
					CONFIG.fallbackDistance,
				minFacing =
					CONFIG.fallbackFacing,
				delay = 0,
			},
			killerCharacter,
			true
		)
	end
end

local function disconnectKillerBinding(): ()
	state.killerBindingGeneration += 1
	state.pendingKillerCharacter = nil
	state.learnedRipUserId = nil
	if state.killerAnimationConnection then
		state.killerAnimationConnection:Disconnect()
		state.killerAnimationConnection = nil
	end
	if state.killerCharacterConnection then
		state.killerCharacterConnection:Disconnect()
		state.killerCharacterConnection = nil
	end
	state.killerPlayer = nil
	state.killerCharacter = nil
	state.killerAnimator = nil
	state.universalRushLatched = false
	clearVeilArm()
end

local function bindKillerCharacter(
	player: Player,
	character: Model
): ()
	if not state.running
		or player ~= exactKillerPlayer()
		or player.Character ~= character then
		return
	end

	if state.killerCharacter == character
		and state.killerAnimator
		and state.killerAnimator.Parent then
		return
	end
	if state.pendingKillerCharacter == character then
		return
	end
	state.killerBindingGeneration += 1
	local generation = state.killerBindingGeneration
	state.pendingKillerCharacter = character
	local function stillCurrent(): boolean
		return state.running and state.killerBindingGeneration == generation
			and player == exactKillerPlayer() and player.Character == character
	end

	if state.killerAnimationConnection then
		state.killerAnimationConnection:Disconnect()
		state.killerAnimationConnection = nil
	end

	local humanoid =
		character:FindFirstChildOfClass("Humanoid")
		or character:WaitForChild(
			"Humanoid",
			2
		) :: Humanoid?
	if not humanoid or not stillCurrent() then
		if state.killerBindingGeneration == generation then state.pendingKillerCharacter = nil end
		return
	end

	local animator =
		humanoid:FindFirstChildOfClass("Animator")
		or humanoid:WaitForChild(
			"Animator",
			2
		) :: Animator?
	if not animator or not stillCurrent() then
		if state.killerBindingGeneration == generation then state.pendingKillerCharacter = nil end
		return
	end

	state.pendingKillerCharacter = nil
	if state.killerCharacter ~= character then state.learnedRipUserId = nil end
	state.killerPlayer = player
	state.killerCharacter = character
	state.killerAnimator = animator
	state.killerAnimationConnection =
		animator.AnimationPlayed:Connect(
			function(track)
				if not stillCurrent() then return end
				onKillerAnimation(
					track,
					character
				)
			end
		)
end

local function refreshKillerBinding(): ()
	if not state.running then
		return
	end

	local killer = exactKillerPlayer()
	if not killer then
		disconnectKillerBinding()
		return
	end
	if state.killerCharacter and state.killerCharacter ~= killer.Character then
		-- CharacterRemoving can race CharacterAdded. Tear down the old
		-- Animator connection before the replacement model is bound.
		disconnectKillerBinding()
	end

	if state.killerPlayer ~= killer then
		disconnectKillerBinding()
		state.killerPlayer = killer
		state.killerCharacterConnection =
			killer.CharacterAdded:Connect(
				function(character)
					task.defer(
						bindKillerCharacter,
						killer,
						character
					)
				end
			)
	end

	if killer.Character then
		bindKillerCharacter(
			killer,
			killer.Character
		)
	end
end

local function bindLocalHealth(): ()
	if not state.running then
		return
	end

	if state.localHealthConnection then
		state.localHealthConnection:Disconnect()
		state.localHealthConnection = nil
	end

	local _, humanoid = localRootAndHumanoid()
	state.localHumanoid = humanoid
	if not humanoid then
		return
	end

	state.lastHealth = humanoid.Health
	state.localHealthConnection =
		humanoid.HealthChanged:Connect(
			function(health)
				local previousHealth =
					state.lastHealth
				state.lastHealth = health

				if health < previousHealth
					and state.lastConfirmedAt < state.lastParryAt
					and now() - state.lastParryAt
						<= CONFIG.damageFailureWindow then
					log(
						string.format(
							"[PARRY_FAILED] hp=%.1f>%.1f attack=%s id=%s d=%.2f",
							previousHealth,
							health,
							state.lastParryName,
							state.lastParryId,
							state.lastParryDistance
						)
					)
				end
			end
		)
end

local function updateDaggerState(): ()
	local ready =
		activeSurvivorRound()
		and equippedParryingDagger() ~= nil
	if ready ~= state.lastDaggerReady then
		state.lastDaggerReady = ready
		if ready then
			log(
				"[DAGGER_READY] equipped=true autoParry=true"
			)
		else
			log(
				"[DAGGER_READY] equipped=false"
			)
		end
	end
end

local function addConnection(
	connection: RBXScriptConnection
): ()
	table.insert(state.connections, connection)
end

local function stop(reason: string?): ()
	if not state.running then
		-- A second stop must still repair a potentially stuck synthetic button.
		releaseSyntheticRightClick(true)
		return
	end
	state.running = false

	releaseSyntheticRightClick(true)
	disconnectKillerBinding()

	if state.localHealthConnection then
		state.localHealthConnection:Disconnect()
		state.localHealthConnection = nil
	end

	for _, connection in ipairs(state.connections) do
		connection:Disconnect()
	end
	table.clear(state.connections)

	local current = rawget(_G, SINGLETON_KEY)
	if type(current) == "table"
		and current.stop == stop then
		rawset(_G, SINGLETON_KEY, nil)
	end

	log("[STOP] reason=" .. tostring(reason or "manual"))
end

-- Repair a button that may have been left down by an older script version.
releaseSyntheticRightClick(true)

rawset(_G, SINGLETON_KEY, {
	stop = stop,
})

addConnection(
	LocalPlayer.CharacterAdded:Connect(
		function()
			state.learnedRipUserId = nil
			state.daggerScanAt = -math.huge
			task.delay(0.25, function()
				if state.running then
					bindLocalHealth()
				end
			end)
		end
	)
)

addConnection(
	UserInputService.InputBegan:Connect(
		function(input, gameProcessed)
			if gameProcessed then
				return
			end
			if input.KeyCode == CONFIG.toggleKey then
				state.enabled = not state.enabled
				if not state.enabled then
					releaseSyntheticRightClick(true)
					state.universalRushLatched = false
					clearVeilArm()
				end
				log(
					"[TOGGLE] enabled="
						.. tostring(state.enabled)
				)
			elseif input.KeyCode == CONFIG.stopKey then
				stop("F10")
			end
		end
	)
)

addConnection(
	RunService.Heartbeat:Connect(function()
		if not state.running then
			return
		end

		updateRipProximityParry()
		updateVeilArmedParry()

		local t = now()
		if t - state.lastBindCheck
			>= CONFIG.rebindInterval then
			state.lastBindCheck = t
			refreshKillerBinding()
			updateDaggerState()

			local _, humanoid =
				localRootAndHumanoid()
			if humanoid ~= state.localHumanoid then
				bindLocalHealth()
			end
		end
	end)
)

bindLocalHealth()
refreshKillerBinding()
updateDaggerState()

log(
	"[ACTIVE] F8 toggle | F10 stop | "
		.. "Survivors only | equipped Parrying Dagger only | "
		.. "RIP proximity early gate | Veil PREP early gate | Cure geometry gate | strict generic melee"
)
