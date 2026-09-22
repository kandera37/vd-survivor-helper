--!strict
--==============================================================
-- VD ASSIST ANTI-3-GEN v2.2 — SLOT-CAPACITY AWARE
--
-- Run order:
--   1. VD Assist v9.9 / v10.0
--   2. This file
--
-- Replaces BOTH:
--   VD_Assist_Anti3Gen_FinalThree_Patch_v1_0
--   VD_Assist_Anti3Gen_LateProgressGuard_v1_1
--
-- It keeps explicit final-three geometry lookahead, but fixes the late-game
-- mistake where a 0% generator could defeat a known started generator solely
-- because of the huge anti-3 normalized weight.
--
-- No Workspace rescan and no duplicate aura creation. It reuses Assist cache.
--==============================================================

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local localPlayer = Players.LocalPlayer
if not localPlayer then
	return
end

-- Stop both superseded patches and an older unified instance.
for _, key in ipairs({
	"__VD_ASSIST_ANTI3GEN_PATCH_V1_0",
	"__VD_ASSIST_ANTI3_LATE_PROGRESS_V1_1",
	"__VD_ASSIST_ANTI3GEN_UNIFIED_V1_2",
	"__VD_ASSIST_ANTI3GEN_UNIFIED_V1_3",
	"__VD_ASSIST_ANTI3GEN_UNIFIED_V1_4",
	"__VD_ASSIST_ANTI3GEN_UNIFIED_V2_0",
	"__VD_ASSIST_ANTI3GEN_UNIFIED_V2_1",
	"__VD_ASSIST_ANTI3GEN_UNIFIED_V2_2",
}) do
	local previous = rawget(_G, key)
	if type(previous) == "table"
		and type(previous.Stop) == "function" then
		pcall(previous.Stop)
	end
end

local KEY = "__VD_ASSIST_ANTI3GEN_UNIFIED_V2_2"

local CONFIG = {
	updateInterval = 0.25,
	spareGeneratorCount = 2,

	-- Normal target stability.
	switchHold = 1.40,
	switchMargin = 6.0,
	switchConfirmTime = 0.25,

	-- Explicit final-three geometry from the old v1.0 patch.
	antiWeightObjectives2 = 220,
	antiWeightObjectives3 = 145,
	antiWeightObjectives4 = 82,
	antiWeightEarly = 36,
	denseTripleMembershipBonus = 42,
	criticalFinalMinEdgeGap = 10.0,

	-- Normal convenience score.
	killerDangerDistance = 34.0,
	killerEmergencyDistance = 17.0,
	localDistanceWeight = 0.10,
	progressWeight = 0.62,
	repairerBonus = 8.0,
	-- A target must have a real repair position for the local survivor. Capacity
	-- comes from Assist's event-maintained generator entry; no Workspace scan.
	openSlotBonus = 12.0,
	extraOpenSlotBonus = 3.0,
	killerDangerPenalty = 1.60,

	-- Integrated late-progress guard.
	lateGuardMaxObjectives = 2,
	zeroProgressMaximum = 1.50,
	startedProgressMinimum = 6.00,
	lateProgressWeight = 2.20,
	lateRepairerBonus = 11.0,
	lateLocalDistanceWeight = 0.045,
	lateKillerDangerPenalty = 2.20,
	lateAntiRetentionWeight = 28.0,
	highProgressThreshold = 70.0,
	nearCompleteThreshold = 90.0,
	highProgressBonus = 18.0,
	nearCompleteBonus = 34.0,
	urgentLateSwitchConfirmTime = 0.12,
	-- Progress can be internally fractional while Assist/UI displays 0%. Keep a
	-- recently measured downward edge eligible for TAP through that zero band.
	regressionMinimumProgress = 0.0,
	regressionMinimumDrop = 0.03,
	regressionMinimumRate = 0.02,
	regressionLatchDuration = 2.25,
	regressionMaximumDistance = 170.0,
	regressionTapBonus = 420.0,
	finalObjectiveProgressWeight = 3.25,
	finalObjectiveRepairerBonus = 14.0,

	baseColor = Color3.fromRGB(190, 210, 235),
	bestColor = Color3.fromRGB(35, 245, 255),
	dangerColor = Color3.fromRGB(255, 145, 70),
}

local runtime = {
	running = true,
	connections = {},
	lastUpdateAt = -math.huge,
	targetModel = nil,
	targetSince = -math.huge,
	pendingModel = nil,
	pendingSince = -math.huge,
	lastLoggedTarget = nil,
	lastLoggedMode = nil,
	lastLoggedSlots = nil,
	lastWaitLogAt = -math.huge,
	Stop = nil,
	markerGui = nil,
	markerAdornee = nil,
	markerTargetModel = nil,
	progressHistory = setmetatable({}, {__mode = "k"}),
	assistRuntime = nil,
	lastSnapshotRevision = -1,
}
_G[KEY] = runtime

local function remember(connection: RBXScriptConnection)
	table.insert(runtime.connections, connection)
	return connection
end

local function horizontalDistance(a: Vector3, b: Vector3): number
	local delta = Vector3.new(a.X - b.X, 0, a.Z - b.Z)
	return delta.Magnitude
end

--==============================================================
-- Final-three geometry
--==============================================================

local function sortedEdges(rows)
	local edges = {}
	for i = 1, #rows do
		for j = i + 1, #rows do
			table.insert(
				edges,
				horizontalDistance(
					rows[i].part.Position,
					rows[j].part.Position
				)
			)
		end
	end
	table.sort(edges)
	return edges
end

local function triangleMetrics(rows)
	if #rows ~= 3 then
		return {
			quality = 0,
			minEdge = 0,
			midEdge = 0,
			maxEdge = 0,
			perimeter = 0,
			area = 0,
		}
	end

	local edges = sortedEdges(rows)
	local a, b, c = edges[1], edges[2], edges[3]
	local semiperimeter = (a + b + c) * 0.5
	local areaSquared = math.max(
		0,
		semiperimeter
			* (semiperimeter - a)
			* (semiperimeter - b)
			* (semiperimeter - c)
	)
	local area = math.sqrt(areaSquared)

	return {
		quality =
			a * 3.00
			+ b * 1.35
			+ c * 0.30
			+ math.sqrt(area) * 1.15,
		minEdge = a,
		midEdge = b,
		maxEdge = c,
		perimeter = a + b + c,
		area = area,
	}
end

local function combinationsOfThree(rows)
	local result = {}
	for i = 1, #rows - 2 do
		for j = i + 1, #rows - 1 do
			for k = j + 1, #rows do
				table.insert(result, {
					rows[i],
					rows[j],
					rows[k],
				})
			end
		end
	end
	return result
end

local function densestTriple(rows)
	local bestTriple = nil
	local lowestQuality = math.huge
	local bestMetrics = nil

	for _, triple in ipairs(
		combinationsOfThree(rows)
	) do
		local metrics = triangleMetrics(triple)
		if metrics.quality < lowestQuality then
			lowestQuality = metrics.quality
			bestTriple = triple
			bestMetrics = metrics
		end
	end

	return bestTriple, bestMetrics
end

local function containsModel(rows, model)
	for _, row in ipairs(rows or {}) do
		if row.model == model then
			return true
		end
	end
	return false
end

local function withoutModel(rows, model)
	local result = {}
	for _, row in ipairs(rows) do
		if row.model ~= model then
			table.insert(result, row)
		end
	end
	return result
end

local function finalThreeLookahead(
	rows,
	finishModel,
	objectivesRemaining
)
	local remaining = withoutModel(rows, finishModel)

	if #remaining < 3 then
		return {
			quality = 0,
			minEdge = 0,
			midEdge = 0,
			maxEdge = 0,
			perimeter = 0,
			area = 0,
		}
	end

	if #remaining == 3
		or objectivesRemaining <= 2 then
		return triangleMetrics({
			remaining[1],
			remaining[2],
			remaining[3],
		})
	end

	if #remaining == 4
		or objectivesRemaining == 3 then
		local best = nil
		for _, nextFinish in ipairs(remaining) do
			local triple =
				withoutModel(
					remaining,
					nextFinish.model
				)
			local metrics =
				triangleMetrics(triple)
			if not best
				or metrics.quality > best.quality then
				best = metrics
			end
		end
		return best or triangleMetrics({
			remaining[1],
			remaining[2],
			remaining[3],
		})
	end

	local _, dangerous = densestTriple(remaining)
	return dangerous or triangleMetrics({
		remaining[1],
		remaining[2],
		remaining[3],
	})
end

--==============================================================
-- Generator cache and scoring
--==============================================================

local function collectRows()
	local assist =
		rawget(_G, "__VD_ASSIST_V9_6_AIM_INSPECTOR")
	if type(assist) ~= "table"
		or assist.running ~= true
		or type(assist.GetAnti3Snapshot) ~= "function" then
		return nil, nil
	end
	runtime.assistRuntime = assist
	if assist.anti3Owner == runtime then
		assist.anti3Owner = nil
	end
	local ok, snapshot = pcall(assist.GetAnti3Snapshot)
	if not ok or type(snapshot) ~= "table"
		or type(snapshot.rows) ~= "table" then
		return nil, nil
	end
	if snapshot.apiVersion ~= 2 then
		return nil, nil
	end
	-- Claim ownership only after the API and row shape are compatible. A stale
	-- Assist table must never be left believing this instance owns its target.
	assist.anti3Owner = runtime
	runtime.lastSnapshotRevision = snapshot.revision or -1

	local root = snapshot.localRoot
	local kRoot = snapshot.killerRoot
	local rows = {}
	local sampleAt = tonumber(snapshot.updatedAt) or os.clock()
	local snapshotRevision = tonumber(snapshot.revision) or -1

	for _, sourceRow in ipairs(snapshot.rows) do
		local model = sourceRow.model
		local entry = sourceRow.entry
		local part = sourceRow.part
		if typeof(model) == "Instance" and model.Parent
			and type(entry) == "table"
			and typeof(part) == "Instance" and part.Parent
			and sourceRow.complete ~= true
			and sourceRow.unusable ~= true then
			local slotCapacity = tonumber(sourceRow.slotCapacity)
				or tonumber(entry.currentSlotCapacity)
			local occupiedSlots = tonumber(sourceRow.occupiedSlots)
				or tonumber(entry.currentOccupiedSlots)
			if slotCapacity then
				slotCapacity = math.max(1, math.floor(slotCapacity + 0.5))
			end
			occupiedSlots = math.max(0, math.floor((occupiedSlots or 0) + 0.5))
			local availableSlots = slotCapacity
				and math.max(0, slotCapacity - occupiedSlots)
				or nil
			local localAtGen = sourceRow.localAtGen == true
			local slotsFull = sourceRow.slotsFull == true
				or (slotCapacity ~= nil and occupiedSlots >= slotCapacity)
			local joinable = localAtGen or not slotsFull
			local progress = math.clamp(tonumber(sourceRow.progress) or 0, 0, 100)
			local progressKnown = sourceRow.progressKnown == true
			local history = runtime.progressHistory[model]
			local regressionRate = 0
			local regressionDrop = 0
			local regressionUntil = history
				and (history.regressionUntil or -math.huge)
				or -math.huge
			if history and history.revision == snapshotRevision then
				regressionDrop = history.regressionDrop or 0
				regressionRate = history.regressionRate or 0
			elseif progressKnown and history and history.known
				and history.revision ~= snapshotRevision then
				local dt = sampleAt - history.at
				if dt > 0.05 and progress < history.progress then
					regressionDrop = history.progress - progress
					regressionRate = regressionDrop / dt
					if regressionDrop >= CONFIG.regressionMinimumDrop
						and regressionRate >= CONFIG.regressionMinimumRate then
						regressionUntil = sampleAt
							+ CONFIG.regressionLatchDuration
					end
				elseif progress > history.progress + 0.02 then
					-- A positive edge means somebody tapped/repaired it; clear the old
					-- regression request immediately.
					regressionUntil = -math.huge
				end
			end
			if not history or history.revision ~= snapshotRevision then
				runtime.progressHistory[model] = {
					progress = progress,
					known = progressKnown,
					at = sampleAt,
					revision = snapshotRevision,
					regressionDrop = regressionDrop,
					regressionRate = regressionRate,
					regressionUntil = regressionUntil,
				}
			end
			local repairers = math.max(0, tonumber(sourceRow.repairers) or 0)
			table.insert(rows, {
				model = model,
				entry = entry,
				part = part,
				progress = progress,
				progressKnown = progressKnown,
				repairers = repairers,
				slotCapacity = slotCapacity,
				occupiedSlots = occupiedSlots,
				availableSlots = availableSlots,
				slotsFull = slotsFull,
				eligible = joinable,
				localAtGen = localAtGen,
				distance = root and horizontalDistance(root.Position, part.Position) or math.huge,
				killerDistance = kRoot and horizontalDistance(kRoot.Position, part.Position) or math.huge,
				regressionDrop = regressionDrop,
				regressionRate = regressionRate,
				regressing = progressKnown
					and repairers <= 0
					and progress >= CONFIG.regressionMinimumProgress
					and (
						(regressionDrop >= CONFIG.regressionMinimumDrop
							and regressionRate >= CONFIG.regressionMinimumRate)
						or sampleAt <= regressionUntil
					),
			})
		end
	end

	return rows, math.max(0, tonumber(snapshot.objectivesRemaining) or 0), snapshot
end

local function antiWeight(objectivesRemaining)
	if objectivesRemaining <= 1 then
		return 0
	end
	if objectivesRemaining <= 2 then
		return CONFIG.antiWeightObjectives2
	end
	if objectivesRemaining == 3 then
		return CONFIG.antiWeightObjectives3
	end
	if objectivesRemaining == 4 then
		return CONFIG.antiWeightObjectives4
	end
	return CONFIG.antiWeightEarly
end

local function baseScoreRows(
	rows,
	objectivesRemaining
)
	local compactTriple = densestTriple(rows)
	local scored = {}
	local minAnti = math.huge
	local maxAnti = -math.huge
	local bestFinalMinEdge = -math.huge

	for _, row in ipairs(rows) do
		local lookahead = finalThreeLookahead(
			rows,
			row.model,
			objectivesRemaining
		)
		row.antiMetrics = lookahead
		row.antiRaw = lookahead.quality
		minAnti = math.min(minAnti, row.antiRaw)
		maxAnti = math.max(maxAnti, row.antiRaw)
		bestFinalMinEdge = math.max(
			bestFinalMinEdge,
			lookahead.minEdge or 0
		)
	end

	local range = math.max(1, maxAnti - minAnti)
	local weight = antiWeight(objectivesRemaining)

	for _, row in ipairs(rows) do
		row.antiNormalized =
			(row.antiRaw - minAnti) / range

		local score =
			row.progress * CONFIG.progressWeight
			+ row.repairers
				* CONFIG.repairerBonus
			- math.min(row.distance, 300)
				* CONFIG.localDistanceWeight
			+ row.antiNormalized * weight
		if row.availableSlots ~= nil and row.availableSlots > 0 then
			score += CONFIG.openSlotBonus
				+ math.max(0, math.min(row.availableSlots, 3) - 1)
					* CONFIG.extraOpenSlotBonus
		end

		if containsModel(
			compactTriple,
			row.model
		) then
			score +=
				CONFIG.denseTripleMembershipBonus
		end

		if row.killerDistance
			< CONFIG.killerDangerDistance then
			score -= (
				CONFIG.killerDangerDistance
					- row.killerDistance
			) * CONFIG.killerDangerPenalty
		end

		if objectivesRemaining == 2
			and row.antiMetrics.minEdge
				< bestFinalMinEdge
					- CONFIG.criticalFinalMinEdgeGap then
			score -= 260
		end

		if row.progress >= 92 then
			score += 22
		end

		row.score = score
		if row.eligible ~= false then
			table.insert(scored, row)
		end
	end

	table.sort(scored, function(a, b)
		if math.abs(a.score - b.score) > 0.001 then
			return a.score > b.score
		end
		return a.antiRaw > b.antiRaw
	end)

	return scored, minAnti, range
end

local function lateStartedScore(row): number
	local score =
		row.progress * CONFIG.lateProgressWeight
		+ row.repairers
			* CONFIG.lateRepairerBonus
		- math.min(row.distance, 300)
			* CONFIG.lateLocalDistanceWeight
		+ (row.antiNormalized or 0)
			* CONFIG.lateAntiRetentionWeight

	if row.progress
		>= CONFIG.highProgressThreshold then
		score += CONFIG.highProgressBonus
	end
	if row.progress
		>= CONFIG.nearCompleteThreshold then
		score += CONFIG.nearCompleteBonus
	end

	if row.killerDistance
		< CONFIG.killerDangerDistance then
		score -= (
			CONFIG.killerDangerDistance
				- row.killerDistance
		) * CONFIG.lateKillerDangerPenalty
	end

	if row.killerDistance
		< CONFIG.killerEmergencyDistance then
		score -= 150
	end

	return score
end

local function chooseStartedTarget(scored)
	local started = {}
	for _, row in ipairs(scored) do
		if row.progressKnown
			and row.progress
				>= CONFIG.startedProgressMinimum then
			row.lateProgressScore =
				lateStartedScore(row)
			table.insert(started, row)
		end
	end

	if #started == 0 then
		return nil, started
	end

	local safe = {}
	for _, row in ipairs(started) do
		if row.killerDistance
			>= CONFIG.killerEmergencyDistance then
			table.insert(safe, row)
		end
	end

	local pool = #safe > 0 and safe or started
	table.sort(pool, function(a, b)
		if math.abs(
			a.lateProgressScore
				- b.lateProgressScore
		) > 0.001 then
			return a.lateProgressScore
				> b.lateProgressScore
		end
		if math.abs(a.progress - b.progress)
			> 0.001 then
			return a.progress > b.progress
		end
		return a.distance < b.distance
	end)

	return pool[1], started
end

local function selectTarget(
	rows,
	objectivesRemaining
)
	if #rows == 0 then
		return nil, {}, "none", nil, 0
	end

	local scored = baseScoreRows(
		rows,
		objectivesRemaining
	)
	local baseCandidate = scored[1]
	local candidate = baseCandidate
	local mode = "anti3"
	local startedCount = 0

	local regressionCandidates = {}
	for _, row in ipairs(scored) do
		if row.regressing
			and row.distance <= CONFIG.regressionMaximumDistance
			and row.killerDistance >= CONFIG.killerEmergencyDistance then
			row.regressionScore = CONFIG.regressionTapBonus
				+ row.progress * 1.8
				+ row.regressionRate * 35
				- row.distance * 0.10
			table.insert(regressionCandidates, row)
		end
	end
	table.sort(regressionCandidates, function(a, b)
		return a.regressionScore > b.regressionScore
	end)
	if regressionCandidates[1] then
		candidate = regressionCandidates[1]
		candidate.score = candidate.regressionScore
		mode = "regression-tap"
		return candidate, scored, mode, baseCandidate, startedCount
	end

	if objectivesRemaining <= 1 then
		for _, row in ipairs(scored) do
			row.finalProgressScore = row.progress * CONFIG.finalObjectiveProgressWeight
				+ row.repairers * CONFIG.finalObjectiveRepairerBonus
				- math.min(row.distance, 300) * CONFIG.lateLocalDistanceWeight
			if row.availableSlots ~= nil and row.availableSlots > 0 then
				row.finalProgressScore += CONFIG.openSlotBonus
			end
			if row.killerDistance < CONFIG.killerDangerDistance then
				row.finalProgressScore -= (CONFIG.killerDangerDistance - row.killerDistance)
					* CONFIG.lateKillerDangerPenalty
			end
			if row.killerDistance < CONFIG.killerEmergencyDistance then
				row.finalProgressScore -= 180
			end
		end
		table.sort(scored, function(a, b)
			return a.finalProgressScore > b.finalProgressScore
		end)
		candidate = scored[1]
		candidate.score = candidate.finalProgressScore
		mode = "final-progress"
		return candidate, scored, mode, baseCandidate, startedCount
	end

	if objectivesRemaining
		<= CONFIG.lateGuardMaxObjectives then
		local startedCandidate, startedRows =
			chooseStartedTarget(scored)
		startedCount = #startedRows

		local baseIsZero =
			not baseCandidate
			or not baseCandidate.progressKnown
			or baseCandidate.progress
				<= CONFIG.zeroProgressMaximum

		if baseIsZero and startedCandidate then
			candidate = startedCandidate
			mode = "late-progress"
		end
	end

	return candidate,
		scored,
		mode,
		baseCandidate,
		startedCount
end

local function findRow(rows, model)
	for _, row in ipairs(rows) do
		if row.model == model then
			return row
		end
	end
	return nil
end

local function effectiveScore(row, mode)
	if not row then
		return -math.huge
	end
	if mode == "regression-tap" then
		return row.regressionScore or -math.huge
	end
	if mode == "final-progress" then
		return row.finalProgressScore or -math.huge
	end
	if mode == "late-progress" then
		if row.progressKnown
			and row.progress
				>= CONFIG.startedProgressMinimum then
			row.lateProgressScore =
				row.lateProgressScore
					or lateStartedScore(row)
			return row.lateProgressScore
		end
		return -math.huge
	end
	return row.score or -math.huge
end

local function sameColor(
	a: Color3,
	b: Color3
): boolean
	return math.abs(a.R - b.R) < 0.03
		and math.abs(a.G - b.G) < 0.03
		and math.abs(a.B - b.B) < 0.03
end

local function ensureMarker(adoree: Instance?)
	if runtime.markerGui and (not runtime.markerGui.Parent or runtime.markerAdornee ~= adoree) then
		runtime.markerGui:Destroy()
		runtime.markerGui = nil
		runtime.markerAdornee = nil
	end
	if not adoree then
		return nil
	end
	if runtime.markerGui then
		return runtime.markerGui
	end
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "VD_Anti3Marker"
	billboard.AlwaysOnTop = true
	billboard.LightInfluence = 0
	billboard.MaxDistance = 140
	billboard.Size = UDim2.fromOffset(74, 24)
	billboard.StudsOffset = Vector3.new(0, 6.0, 0)
	billboard.Adornee = adoree
	billboard.Parent = adoree
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1,1)
	label.Font = Enum.Font.GothamBold
	label.TextScaled = true
	label.Text = "ANTI3"
	label.TextColor3 = CONFIG.bestColor
	label.TextStrokeTransparency = 0.10
	label.TextStrokeColor3 = Color3.new(0,0,0)
	label.Parent = billboard
	runtime.markerGui = billboard
	runtime.markerAdornee = adoree
	return billboard
end

local function updateMarker(chosen)
	local chosenModel = chosen and chosen.model or nil
	if runtime.markerTargetModel == chosenModel
		and runtime.markerGui
		and runtime.markerGui.Parent then
		return
	end
	runtime.markerTargetModel = chosenModel
	if not chosen or not chosen.part or not chosen.part.Parent then
		if runtime.markerGui then
			runtime.markerGui.Enabled = false
		end
		return
	end
	local gui = ensureMarker(chosen.part)
	if gui then
		gui.Adornee = chosen.part
		gui.Enabled = true
		runtime.markerAdornee = chosen.part
	end
end

local function applyVisuals(rows, chosen, visible)
	if not visible then
		updateMarker(nil)
		return
	end
	for _, row in ipairs(rows) do
		local highlight = row.entry.highlight
		if highlight
			and highlight.Parent
			and highlight.Enabled then
			local color

			if chosen
				and row.model == chosen.model then
				color = CONFIG.bestColor
				highlight.FillTransparency = 0.88
				highlight.OutlineTransparency = 0.06
			elseif row.killerDistance
				< CONFIG.killerDangerDistance then
				color = CONFIG.dangerColor
				highlight.FillTransparency = 0.90
				highlight.OutlineTransparency = 0.10
			else
				color = CONFIG.baseColor
				highlight.FillTransparency = 0.90
				highlight.OutlineTransparency = 0.12
			end

			if not sameColor(
				highlight.FillColor,
				color
			) then
				highlight.FillColor = color
				highlight.OutlineColor = color
			end
			row.entry.visualColor = color
			row.entry.visualFill = highlight.FillTransparency
			row.entry.visualOutline = highlight.OutlineTransparency
			row.entry.visualEnabled = highlight.Enabled
		end
	end
	updateMarker(chosen)
end

local function update()
	local rows, objectivesRemaining, snapshot = collectRows()

	if not rows then
		updateMarker(nil)
		runtime.targetModel = nil
		runtime.pendingModel = nil
		_G.VDGenRecommendation = nil
		_G.VDGenRecommendationInfo = nil
		local now = os.clock()
		if now - runtime.lastWaitLogAt >= 3 then
			runtime.lastWaitLogAt = now
			print(
				"[VD ASSIST ANTI3 v2.2][WAIT] "
					.. "run VD Assist v10 data API first"
			)
		end
		return
	end

	if objectivesRemaining <= 0
		or #rows == 0 then
		runtime.targetModel = nil
		runtime.pendingModel = nil
		updateMarker(nil)
		_G.VDGenRecommendation = nil
		_G.VDGenRecommendationInfo = nil
		return
	end

	local candidate,
		scored,
		mode,
		baseCandidate,
		startedCount =
		selectTarget(rows, objectivesRemaining)

	if not candidate then
		runtime.targetModel = nil
		runtime.pendingModel = nil
		updateMarker(nil)
		_G.VDGenRecommendation = nil
		_G.VDGenRecommendationInfo = nil
		return
	end

	local now = os.clock()
	local current =
		findRow(scored, runtime.targetModel)
	local urgentLateSwitch =
		(mode == "regression-tap")
		or (mode == "late-progress"
		and (
			not current
			or not current.progressKnown
			or current.progress
				<= CONFIG.zeroProgressMaximum
		))

	if runtime.targetModel == nil then
		runtime.targetModel = candidate.model
		runtime.targetSince = now
		runtime.pendingModel = nil
	elseif not current and candidate.model ~= runtime.targetModel then
		-- Completed, destroyed or newly-full targets must disappear immediately;
		-- normal switch hysteresis must not keep pointing at a generator with no
		-- repair position for the local survivor.
		runtime.targetModel = candidate.model
		runtime.targetSince = now
		runtime.pendingModel = nil
	elseif current
		and candidate.model ~= current.model
		and not urgentLateSwitch
		and now - runtime.targetSince
			< CONFIG.switchHold
		and effectiveScore(candidate, mode)
			< effectiveScore(current, mode)
				+ CONFIG.switchMargin then
		candidate = current
		runtime.pendingModel = nil
	elseif candidate.model ~= runtime.targetModel then
		local confirmTime =
			urgentLateSwitch
				and CONFIG
					.urgentLateSwitchConfirmTime
				or CONFIG.switchConfirmTime

		if runtime.pendingModel
			~= candidate.model then
			runtime.pendingModel =
				candidate.model
			runtime.pendingSince = now
			return
		end

		if now - runtime.pendingSince
			< confirmTime then
			return
		end

		runtime.targetModel = candidate.model
		runtime.targetSince = now
		runtime.pendingModel = nil
	end

	applyVisuals(rows, candidate, snapshot.visible == true)
	if runtime.markerGui then
		local label = runtime.markerGui:FindFirstChildOfClass("TextLabel")
		if label then
			local modeText = if mode == "regression-tap"
				then "TAP"
				elseif mode == "final-progress"
				then "FINAL"
				else "ANTI3"
			local slotText = if candidate.slotCapacity
				then string.format(" %d/%d", candidate.occupiedSlots, candidate.slotCapacity)
				else " ?/?"
			label.Text = modeText .. slotText
		end
	end

	_G.VDGenRecommendation = candidate.model
	_G.VDGenRecommendationInfo = {
		source = "anti3-data-owner-v2.2",
		mode = mode,
		objectivesRemaining = objectivesRemaining,
		progress = candidate.progress,
		progressKnown = candidate.progressKnown,
		repairers = candidate.repairers,
		slotCapacity = candidate.slotCapacity,
		occupiedSlots = candidate.occupiedSlots,
		availableSlots = candidate.availableSlots,
		localAtGen = candidate.localAtGen,
		score = effectiveScore(candidate, mode),
		baseCandidate = baseCandidate
			and baseCandidate.model
			or nil,
		baseProgress = baseCandidate
			and baseCandidate.progress
			or nil,
		startedCandidates = startedCount,
		finalThreeQuality =
			candidate.antiMetrics.quality,
		finalThreeMinEdge =
			candidate.antiMetrics.minEdge,
		finalThreePerimeter =
			candidate.antiMetrics.perimeter,
		killerDistance =
			candidate.killerDistance,
		regressing = candidate.regressing == true,
		regressionRate = candidate.regressionRate or 0,
		regressionDrop = candidate.regressionDrop or 0,
	}

	local slotLogKey = string.format(
		"%d/%s",
		candidate.occupiedSlots or 0,
		candidate.slotCapacity and tostring(candidate.slotCapacity) or "?"
	)
	if runtime.lastLoggedTarget
		~= candidate.model
		or runtime.lastLoggedMode ~= mode
		or runtime.lastLoggedSlots ~= slotLogKey then
		runtime.lastLoggedTarget =
			candidate.model
		runtime.lastLoggedMode = mode
		runtime.lastLoggedSlots = slotLogKey

		print(string.format(
			"[VD ASSIST ANTI3 v2.2][TARGET] "
				.. "mode=%s objectives=%d unfinished=%d "
				.. "progress=%.1f known=%s repairers=%d slots=%d/%s open=%s "
				.. "baseProgress=%.1f score=%.1f "
				.. "final3Min=%.1f final3Perimeter=%.1f regressing=%s regressionRate=%.3f",
			mode,
			objectivesRemaining,
			#rows,
			candidate.progress,
			tostring(candidate.progressKnown),
			candidate.repairers,
			candidate.occupiedSlots or 0,
			candidate.slotCapacity and tostring(candidate.slotCapacity) or "?",
			candidate.availableSlots and tostring(candidate.availableSlots) or "?",
			baseCandidate
				and baseCandidate.progress
				or 0,
			effectiveScore(candidate, mode),
			candidate.antiMetrics.minEdge or 0,
			candidate.antiMetrics.perimeter or 0,
			tostring(candidate.regressing == true),
			candidate.regressionRate or 0
		))

		if mode == "late-progress" then
			print(string.format(
				"[VD ASSIST ANTI3 v2.2]"
					.. "[ZERO_GEN_BLOCKED] "
					.. "base=%s baseProgress=%.1f "
					.. "target=%s targetProgress=%.1f "
					.. "startedCandidates=%d",
				baseCandidate
					and baseCandidate.model:GetFullName()
					or "none",
				baseCandidate
					and baseCandidate.progress
					or 0,
				candidate.model:GetFullName(),
				candidate.progress,
				startedCount
			))
		end
	end
end

remember(RunService.Heartbeat:Connect(function()
	if not runtime.running then
		return
	end

	local now = os.clock()
	if now - runtime.lastUpdateAt
		< CONFIG.updateInterval then
		return
	end
	runtime.lastUpdateAt = now

	-- Main Assist writes its own target on Heartbeat. Defer so this unified
	-- anti-3 recommendation is the final visible result.
	task.defer(function()
		if runtime.running then
			update()
		end
	end)
end))

function runtime.Stop()
	if not runtime.running then
		return
	end
	runtime.running = false

	for _, connection in ipairs(
		runtime.connections
	) do
		if connection.Connected then
			connection:Disconnect()
		end
	end
	table.clear(runtime.connections)
	if runtime.markerGui then
		runtime.markerGui:Destroy()
		runtime.markerGui = nil
		runtime.markerAdornee = nil
		runtime.markerTargetModel = nil
	end

	if rawget(_G, KEY) == runtime then
		_G[KEY] = nil
	end
	local assist = runtime.assistRuntime
	if type(assist) == "table" and assist.anti3Owner == runtime then
		assist.anti3Owner = nil
		_G.VDGenRecommendation = assist.baseGeneratorRecommendation
		_G.VDGenRecommendationInfo = assist.baseGeneratorRecommendationInfo
	end

	print("[VD ASSIST ANTI3 v2.2][STOP]")
end

_G.StopVDAssistAnti3Unified = runtime.Stop

print(
	"[VD ASSIST ANTI3 v2.2][START] "
		.. "Assist API owner + final-three + regression-tap + final-progress + slot-capacity"
)
print(
	"[VD ASSIST ANTI3 v2.2][RULE] "
		.. "killer position comes from Assist API; regressing safe generators get REGRESSION_TAP; "
		.. "occupied/capacity is authoritative and a full generator is ineligible unless local player is already repairing it; "
		.. "a measured fractional regression remains TAP-eligible while displayed progress is 0%; "
		.. "with one objective geometry is disabled and real progress owns the choice; "
		.. "with two objectives 0% cannot beat known >=6% progress unless none is started"
)
print(
	"[VD ASSIST ANTI3 v2.2][REPLACES] "
		.. "do not run FinalThree v1.0 or LateProgress v1.1"
)
