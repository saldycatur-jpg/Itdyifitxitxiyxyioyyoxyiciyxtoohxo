-- ============================================================================
-- KEMI // PLAY AI — Fixed: Skillcheck Reliability + Killer Escape Logic
--
-- Changes from previous build:
--   1. InitializeAutobuy → polling-based skillcheck processor.
--      Tracks moving Goal, handles GUI recreation, tolerates multiple checks.
--   2. Flee target selection → PathfindingService-based candidate scoring.
--      Avoids corners/dead-ends, prefers escape routes with path validity.
--
-- Everything else (generator navigation, generator interaction, killer
-- chase/attack, role watcher, shift hold, lifecycle, kill switch) is
-- preserved as-is.
-- ============================================================================

local Players             = game:GetService("Players")
local RunService          = game:GetService("RunService")
local PathfindingService  = game:GetService("PathfindingService")
local VirtualInputManager = game:GetService("VirtualInputManager")
local GuiService          = game:GetService("GuiService")

local localPlayer = Players.LocalPlayer
local playerGui   = localPlayer:WaitForChild("PlayerGui")

local function log(...) print("[KemiAI]", ...) end

-- ============================================================================
-- CONFIG
-- ============================================================================
local CONFIG = {
    BASE_WALKSPEED       = 16,
    WALKSPEED_FACTOR     = 1.1,

    KILLER_DETECT_RANGE  = 250,
    KILLER_HIT_RANGE     = 6,
    KILLER_HIT_TOL       = 1,
    KILLER_MAX_HITS      = 2,
    KILLER_HIT_COOLDOWN  = 1.2,
    KILLER_TARGET_RECHECK= 0.5,

    SURV_GEN_DETECT      = 350,
    SURV_GEN_ACTION_R    = 5,
    SURV_REGEN_INTERVAL  = 0.75,
    SURV_GEN_NO_PROGRESS = 2.5,
    SURV_FLEE_DIST       = 30,

    REPATH_INTERVAL      = 0.4,
    REPATH_DIST_THRESH   = 6,
    WAYPOINT_REACH_DIST  = 3,
    WAYPOINT_TIMEOUT     = 3,

    SKILLCHECK_SNAP_OFF     = 109,
    SKILLCHECK_TRIGGER_START= 104,
    SKILLCHECK_TRIGGER_END  = 118,
    TRIGGER_INTERVAL        = 0.05,
    SNAP_INTERVAL           = 0.08,   -- re-snap every 80ms while visible

    THREAT_SAMPLES       = 5,
    THREAT_SAMPLE_INT    = 0.18,
    THREAT_APPROACH_MIN  = 1.2,
    THREAT_EMERGENCY_D   = 12,
    THREAT_HYSTERESIS    = 1.6,
    THREAT_CLEAR_TIME    = 2.5,
    THREAT_MIN_VEL_DOT   = 0.35,

    -- Flee tuning
    FLEE_DISTANCE        = 40,
    FLEE_MIN_DIST_KILLER = 20,   -- endpoint must be at least this far from killer
    FLEE_REPICK_INTERVAL = 0.6,
    FLEE_REACHED_RADIUS  = 4,

    TOUCH_ID = 8822,
    ACTION_PATHS = {
        "Survivor-mob.Controls.action",
        "Survivor-mob.Controls.action.check",
        "Survivor-mob.Controls.check",
        "Killer-mob.Controls.action",
        "Killer-mob.Controls.attack",
        "Killer-mob.Controls.check",
    },
}

-- Compat names (kept from reference)
local ActionPath = CONFIG.ACTION_PATHS[1]
local TouchID    = CONFIG.TOUCH_ID

local config = _G.config
if type(config) ~= "table" then config = {} end
if config.autoSkillCheckEnabled == nil then config.autoSkillCheckEnabled = true end

-- ============================================================================
-- SHARED HELPERS
-- ============================================================================
local function getChar() return localPlayer.Character end
local function getHumanoid()
    local c = getChar()
    return c and c:FindFirstChildOfClass("Humanoid")
end
local function getRoot()
    local c = getChar()
    if not c then return nil end
    return c:FindFirstChild("HumanoidRootPart") or c:FindFirstChild("Torso")
end
local function dist(a, b)
    if not a or not b then return math.huge end
    return (a.Position - b.Position).Magnitude
end

-- ============================================================================
-- GUI BADGE
-- ============================================================================
local readyGui = Instance.new("ScreenGui")
readyGui.Name = "KemiAI_Ready"
readyGui.ResetOnSpawn = false
readyGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
readyGui.IgnoreGuiInset = true
readyGui.Parent = playerGui

local readyLabel = Instance.new("TextLabel")
readyLabel.AnchorPoint = Vector2.new(0, 1)
readyLabel.Position = UDim2.new(0, 14, 1, -14)
readyLabel.Size = UDim2.new(0, 320, 0, 18)
readyLabel.BackgroundTransparency = 1
readyLabel.Text = "AI ready [waiting]"
readyLabel.TextColor3 = Color3.fromRGB(0, 255, 120)
readyLabel.TextStrokeTransparency = 0.4
readyLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
readyLabel.Font = Enum.Font.GothamBold
readyLabel.TextSize = 14
readyLabel.TextXAlignment = Enum.TextXAlignment.Left
readyLabel.Parent = readyGui

-- ============================================================================
-- ROLE DETECTION
-- ============================================================================
local function matchRoleName(n)
    if type(n) ~= "string" then return nil end
    if n == "Survivors" or n == "Survivor" then return "Survivor" end
    if n == "Killers"   or n == "Killer"   then return "Killer"   end
    local l = n:lower()
    if l:find("survivor") then return "Survivor" end
    if l:find("killer") or l:find("monster") or l:find("enemy") then return "Killer" end
    return nil
end

local function getCurrentRole()
    local team = localPlayer.Team
    if team then
        local r = matchRoleName(team.Name)
        if r then return r end
    end
    for _, k in ipairs({"Role", "Team", "RoleName", "GameRole"}) do
        local ok, v = pcall(function() return localPlayer:GetAttribute(k) end)
        if ok then
            local r = matchRoleName(v)
            if r then return r end
        end
    end
    local char = getChar()
    if char then
        for _, k in ipairs({"Role", "Team", "RoleName", "GameRole"}) do
            local ok, v = pcall(function() return char:GetAttribute(k) end)
            if ok then
                local r = matchRoleName(v)
                if r then return r end
            end
        end
    end
    return "Spectator"
end

-- ============================================================================
-- SHIFT STATE
-- ============================================================================
local Shift = { held = false }

local function holdShift()
    if Shift.held then return end
    Shift.held = true
    pcall(function()
        VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.LeftShift, false, game)
    end)
end

local function releaseShift()
    if not Shift.held then return end
    Shift.held = false
    pcall(function()
        VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.LeftShift, false, game)
    end)
end

-- ============================================================================
-- ACTION BUTTON HELPERS
-- ============================================================================
local function GetActionTarget()
    for _, path in ipairs(CONFIG.ACTION_PATHS) do
        local current = localPlayer:FindFirstChild("PlayerGui")
        if not current then return nil end
        for segment in string.gmatch(path, "[^%.]+") do
            current = current and current:FindFirstChild(segment)
        end
        if current and current:IsA("GuiObject") and current.Visible then
            local sz = current.AbsoluteSize
            if sz.X > 0 and sz.Y > 0 then
                return current
            end
        end
    end
    return nil
end

local function TriggerMobileButton()
    local b = GetActionTarget()
    if b and b:IsA("GuiObject") then
        local p, s, i = b.AbsolutePosition, b.AbsoluteSize, GuiService:GetGuiInset()
        local cx, cy = p.X + (s.X / 2) + i.X, p.Y + (s.Y / 2) + i.Y
        pcall(function()
            VirtualInputManager:SendTouchEvent(TouchID, 0, cx, cy)
            task.wait(0.02)
            VirtualInputManager:SendTouchEvent(TouchID, 2, cx, cy)
        end)
    end
end

-- ============================================================================
-- SKILLCHECK SYSTEM (POLLING-BASED — replaces signal-based InitializeAutobuy)
--
-- Root cause fixed:
--   • Previous code relied on GetPropertyChangedSignal("Visible"), which does
--     NOT fire if Visible was already true when we attached → snap and trigger
--     binding never installed.
--   • Previous code also captured a single Check reference; prompt recreation
--     and multi-check layouts were missed.
--   • Goal may move after appearance; a single snap becomes stale.
--
-- New approach:
--   • Heartbeat polling re-resolves prompt/checks each tick.
--   • Re-snap Line to Goal+offset every SNAP_INTERVAL (bounded rate, not
--     per-frame) while a SINGLE check is visible → tracks moving Goal.
--   • Double skillcheck: snap disabled; only trigger when Line already in range.
--   • Trigger attempts every TRIGGER_INTERVAL when in-range.
-- ============================================================================
local Skill = {
    hb = nil,
    wasVisible = false,
    lastSnapT = 0,
    lastTriggerT = 0,
}

local function resolveSkillPrompt()
    local pg = localPlayer:FindFirstChild("PlayerGui")
    if not pg then return nil, {} end
    local prompt = pg:FindFirstChild("SkillCheckPromptGui")
    if not prompt then return nil, {} end
    local checks = {}
    for _, ch in ipairs(prompt:GetChildren()) do
        if ch:IsA("GuiObject") then
            local line = ch:FindFirstChild("Line")
            local goal = ch:FindFirstChild("Goal")
            if line and goal then
                table.insert(checks, ch)
            end
        end
    end
    return prompt, checks
end

local function angleInSuccessZone(lr, gr)
    local ss = (gr + CONFIG.SKILLCHECK_TRIGGER_START) % 360
    local se = (gr + CONFIG.SKILLCHECK_TRIGGER_END) % 360
    if ss > se then
        return (lr >= ss or lr <= se)
    else
        return (lr >= ss and lr <= se)
    end
end

local function skillCheckTick()
    -- Only run for Survivor with feature enabled
    if not config.autoSkillCheckEnabled then
        Skill.wasVisible = false
        return
    end
    local role = getCurrentRole()
    if role ~= "Survivor" then
        Skill.wasVisible = false
        return
    end

    local _, checks = resolveSkillPrompt()
    if #checks == 0 then
        if Skill.wasVisible then log("Skillcheck: closed") end
        Skill.wasVisible = false
        return
    end

    -- Filter visible checks only
    local visible = {}
    for _, c in ipairs(checks) do
        if c.Visible then table.insert(visible, c) end
    end
    if #visible == 0 then
        Skill.wasVisible = false
        return
    end

    local now = tick()
    if not Skill.wasVisible then
        log("Skillcheck visible: count=", #visible)
        Skill.wasVisible = true
        Skill.lastSnapT = 0
        Skill.lastTriggerT = 0
    end

    -- Re-snap Line → Goal + offset, only for single-check case
    if #visible == 1 and (now - Skill.lastSnapT) >= CONFIG.SNAP_INTERVAL then
        Skill.lastSnapT = now
        local c = visible[1]
        local line = c:FindFirstChild("Line")
        local goal = c:FindFirstChild("Goal")
        if line and goal then
            local gr = goal.Rotation % 360
            line.Rotation = (gr + CONFIG.SKILLCHECK_SNAP_OFF) % 360
        end
    end
    -- Note: for double skillcheck (#visible >= 2) we DO NOT force rotation.

    -- Trigger
    if (now - Skill.lastTriggerT) >= CONFIG.TRIGGER_INTERVAL then
        for _, c in ipairs(visible) do
            local line = c:FindFirstChild("Line")
            local goal = c:FindFirstChild("Goal")
            if line and goal then
                local lr = line.Rotation % 360
                local gr = goal.Rotation % 360
                if angleInSuccessZone(lr, gr) then
                    Skill.lastTriggerT = now
                    TriggerMobileButton()
                    break
                end
            end
        end
    end
end

-- Compatibility shim: some code paths call InitializeAutobuy() on role change.
-- The actual work now runs continuously via Skill.hb; this function only
-- ensures the heartbeat is connected and logs.
local function InitializeAutobuy()
    if Skill.hb then
        log("Skillcheck: already running")
        return
    end
    Skill.hb = RunService.Heartbeat:Connect(function()
        local ok, err = pcall(skillCheckTick)
        if not ok then log("skillCheckTick error:", err) end
    end)
    log("Skillcheck: processor started")
end

-- Compatibility aliases (do not remove; referenced elsewhere in reference scripts)
local VisibilityConnection  = nil  -- kept for API compat (unused now)
local HeartbeatConnection   = nil  -- kept for API compat (unused now)

-- ============================================================================
-- MOVEMENT (pathfinding + waypoint follower)
-- ============================================================================
local MOVE = {
    waypoints = {}, index = 1,
    lastRepath = 0, lastTargetPos = nil,
    lastPos = nil, stuckSince = 0,
}

local function resetMove()
    MOVE.waypoints = {}
    MOVE.index = 1
    MOVE.lastTargetPos = nil
    MOVE.lastPos = nil
    MOVE.stuckSince = 0
end

local function stopMoving()
    local hum = getHumanoid()
    if hum then hum:Move(Vector3.zero, false) end
    resetMove()
end

local function computePath(targetPos)
    local root = getRoot()
    if not root or not targetPos then return false end
    local path = PathfindingService:CreatePath({
        AgentRadius = 2, AgentHeight = 5,
        AgentCanJump = true, AgentMaxSlope = 45,
        WaypointSpacing = 4,
    })
    local ok = pcall(function() path:ComputeAsync(root.Position, targetPos) end)
    if ok and path.Status == Enum.PathStatus.Success then
        MOVE.waypoints = path:GetWaypoints()
        MOVE.index = 1
        MOVE.lastRepath = tick()
        MOVE.lastTargetPos = targetPos
        MOVE.stuckSince = 0
        return true
    end
    MOVE.waypoints = {}
    MOVE.index = 1
    MOVE.lastRepath = tick()
    MOVE.lastTargetPos = targetPos
    return false
end

local function stepMovement(targetPos)
    local hum = getHumanoid()
    local root = getRoot()
    if not hum or not root or not targetPos then return false end
    hum.WalkSpeed = CONFIG.BASE_WALKSPEED * CONFIG.WALKSPEED_FACTOR

    local now = tick()
    local needRepath = (now - MOVE.lastRepath > CONFIG.REPATH_INTERVAL)
    if MOVE.lastTargetPos and (targetPos - MOVE.lastTargetPos).Magnitude > CONFIG.REPATH_DIST_THRESH then
        needRepath = true
    end

    if MOVE.lastPos then
        local delta = (root.Position - MOVE.lastPos).Magnitude
        if delta < 0.15 then
            if MOVE.stuckSince == 0 then MOVE.stuckSince = now
            elseif now - MOVE.stuckSince > CONFIG.WAYPOINT_TIMEOUT then
                needRepath = true
                MOVE.stuckSince = 0
            end
        else
            MOVE.stuckSince = 0
        end
    end
    MOVE.lastPos = root.Position

    if needRepath then computePath(targetPos) end

    if #MOVE.waypoints > 0 then
        local wp = MOVE.waypoints[MOVE.index]
        if wp then
            if (root.Position - wp.Position).Magnitude < CONFIG.WAYPOINT_REACH_DIST then
                MOVE.index = MOVE.index + 1
                wp = MOVE.waypoints[MOVE.index]
            end
            if wp then
                if wp.Action == Enum.PathWaypointAction.Jump then hum.Jump = true end
                hum:MoveTo(wp.Position)
            else
                hum:MoveTo(targetPos)
            end
        end
    else
        hum:MoveTo(targetPos)
    end
    return true
end

-- ============================================================================
-- PLAYER / TARGET HELPERS
-- ============================================================================
local function getPlayerRoot(p)
    local c = p and p.Character
    if not c then return nil end
    return c:FindFirstChild("HumanoidRootPart") or c:FindFirstChild("Torso")
end

local function roleOfPlayer(p)
    if not p or p == localPlayer then return nil end
    if p.Team then
        local r = matchRoleName(p.Team.Name)
        if r then return r end
    end
    return nil
end

local function findNearestSurvivor(maxDist)
    maxDist = maxDist or CONFIG.KILLER_DETECT_RANGE
    local myRoot = getRoot()
    if not myRoot then return nil, math.huge end
    local best, bestD = nil, maxDist
    for _, p in ipairs(Players:GetPlayers()) do
        if roleOfPlayer(p) == "Survivor" then
            local r = getPlayerRoot(p)
            if r then
                local d = dist(myRoot, r)
                if d < bestD then bestD, best = d, p end
            end
        end
    end
    return best, bestD
end

local function findNearestKiller(maxDist)
    maxDist = maxDist or CONFIG.KILLER_DETECT_RANGE
    local myRoot = getRoot()
    if not myRoot then return nil, math.huge end
    local best, bestD = nil, maxDist
    for _, p in ipairs(Players:GetPlayers()) do
        if roleOfPlayer(p) == "Killer" then
            local r = getPlayerRoot(p)
            if r then
                local d = dist(myRoot, r)
                if d < bestD then bestD, best = d, p end
            end
        end
    end
    return best, bestD
end

-- ============================================================================
-- GENERATORS
-- ============================================================================
local function getGeneratorsContainer()
    local map = workspace:FindFirstChild("Map")
    local candidates = {
        map and map:FindFirstChild("Generators"),
        workspace:FindFirstChild("Generators"),
        map and map:FindFirstChild("Generator"),
        workspace:FindFirstChild("Generator"),
    }
    for _, c in ipairs(candidates) do
        if c then return c end
    end
    return nil
end

local function getGenProgress(gen)
    if not gen then return nil end
    local v = gen:GetAttribute("RepairProgress") or gen:GetAttribute("Progress")
    if v == nil then return nil end
    return tonumber(v)
end

local function genApproachPoint(gen)
    if not gen then return nil end
    local myRoot = getRoot()
    if not myRoot then return nil end
    local best, bestD = nil, math.huge
    for _, ch in ipairs(gen:GetChildren()) do
        if ch:IsA("BasePart") and ch.Name:match("^GeneratorPoint%d+$") then
            local d = (myRoot.Position - ch.Position).Magnitude
            if d < bestD then bestD, best = d, ch end
        end
    end
    if best then return best.Position end
    if gen:IsA("Model") and gen.PrimaryPart then return gen.PrimaryPart.Position end
    if gen:IsA("BasePart") then return gen.Position end
    for _, ch in ipairs(gen:GetChildren()) do
        if ch:IsA("BasePart") then return ch.Position end
    end
    return nil
end

local function findBestGenerator()
    local myRoot = getRoot()
    if not myRoot then return nil end
    local gens = getGeneratorsContainer()
    if not gens then return nil end
    local best, bestScore = nil, math.huge
    for _, gen in ipairs(gens:GetChildren()) do
        local prog = getGenProgress(gen)
        if prog == nil or prog < 100 then
            local ap = genApproachPoint(gen)
            if ap then
                local d = (myRoot.Position - ap).Magnitude
                if d < bestScore and d < CONFIG.SURV_GEN_DETECT then
                    bestScore, best = d, gen
                end
            end
        end
    end
    return best
end

-- ============================================================================
-- THREAT TRACKER
-- ============================================================================
local Threat = {
    samples = {}, lastSampleT = 0,
    confirmed = false, clearStart = nil,
}

local function resetThreat()
    Threat.samples = {}
    Threat.lastSampleT = 0
    Threat.confirmed = false
    Threat.clearStart = nil
end

local function updateThreat(now)
    local myRoot = getRoot()
    if not myRoot then resetThreat() return nil, nil, math.huge, false end

    local killer, kD = findNearestKiller(CONFIG.KILLER_DETECT_RANGE)
    if not killer then
        if Threat.confirmed then
            if not Threat.clearStart then Threat.clearStart = now
            elseif now - Threat.clearStart > CONFIG.THREAT_CLEAR_TIME then
                resetThreat()
            end
        end
        return nil, nil, math.huge, false
    end

    local killerRoot = getPlayerRoot(killer)

    if now - Threat.lastSampleT >= CONFIG.THREAT_SAMPLE_INT then
        Threat.lastSampleT = now
        table.insert(Threat.samples, { t = now, d = kD })
        while #Threat.samples > CONFIG.THREAT_SAMPLES do
            table.remove(Threat.samples, 1)
        end
    end

    if kD <= CONFIG.THREAT_EMERGENCY_D then
        Threat.confirmed = true
        Threat.clearStart = nil
        return killer, killerRoot, kD, true
    end

    if not Threat.confirmed and #Threat.samples >= CONFIG.THREAT_SAMPLES then
        local first, last = Threat.samples[1], Threat.samples[#Threat.samples]
        local dt = last.t - first.t
        if dt > 0 then
            local closing = (first.d - last.d) / dt
            local velOK = true
            if killerRoot then
                local v = killerRoot.AssemblyLinearVelocity
                if v.Magnitude > 1 then
                    local toMe = myRoot.Position - killerRoot.Position
                    if toMe.Magnitude > 0.5 then
                        velOK = (v.Unit:Dot(toMe.Unit)) > CONFIG.THREAT_MIN_VEL_DOT
                    end
                else
                    velOK = false
                end
            end
            if closing >= CONFIG.THREAT_APPROACH_MIN and velOK then
                Threat.confirmed = true
                Threat.clearStart = nil
                log("Threat CONFIRMED closing=", string.format("%.2f", closing))
            end
        end
    end

    if Threat.confirmed then
        local far = kD > CONFIG.SURV_FLEE_DIST * CONFIG.THREAT_HYSTERESIS
        if far then
            if not Threat.clearStart then Threat.clearStart = now
            elseif now - Threat.clearStart > CONFIG.THREAT_CLEAR_TIME then
                resetThreat()
                return killer, killerRoot, kD, false
            end
        else
            Threat.clearStart = nil
        end
    end

    return killer, killerRoot, kD, Threat.confirmed
end

-- ============================================================================
-- FLEE TARGET SELECTION (fixes corner trap)
--
-- Root cause fixed:
--   Previously fleeTarget = myPos + awayFromKiller * 42, computed purely from
--   killer position. If a wall was in that direction or AI stood in a corner,
--   pathfinding failed and AI walked into geometry.
--
-- New approach:
--   • Generate candidate directions by rotating the "away" vector around Y at
--     0°, ±45°, ±90°, ±135°, 180°.
--   • Try PathfindingService for each candidate (in order from smallest rotation
--     outward) until one succeeds AND its endpoint is > FLEE_MIN_DIST_KILLER
--     from the killer.
--   • Cache chosen target; only re-pick every FLEE_REPICK_INTERVAL or when
--     reached.
-- ============================================================================
local FLEE = {
    target = nil,
    lastPick = 0,
    lastLog = 0,
}

local function resetFlee()
    FLEE.target = nil
    FLEE.lastPick = 0
    FLEE.lastLog = 0
end

local function rotateAroundY(v, rad)
    local c, s = math.cos(rad), math.sin(rad)
    return Vector3.new(v.X * c - v.Z * s, 0, v.X * s + v.Z * c)
end

local function tryFleeCandidate(fromPos, endPos)
    local path = PathfindingService:CreatePath({
        AgentRadius = 2, AgentHeight = 5,
        AgentCanJump = true, AgentMaxSlope = 45,
        WaypointSpacing = 4,
    })
    local ok = pcall(function() path:ComputeAsync(fromPos, endPos) end)
    if ok and path.Status == Enum.PathStatus.Success then
        return true
    end
    return false
end

local function pickFleeTarget(root, killerRoot)
    local now = tick()
    local myPos = root.Position
    local killerPos = killerRoot.Position

    -- Return cached if still fresh and not reached
    if FLEE.target then
        local reached = (myPos - FLEE.target).Magnitude < CONFIG.FLEE_REACHED_RADIUS
        if not reached and (now - FLEE.lastPick) < CONFIG.FLEE_REPICK_INTERVAL then
            return FLEE.target
        end
    end

    -- Base away direction (Y zeroed)
    local away = myPos - killerPos
    away = Vector3.new(away.X, 0, away.Z)
    if away.Magnitude < 0.01 then away = Vector3.new(1, 0, 0) end
    away = away.Unit

    -- Try angles from smallest rotation to largest
    local angles = { 0, 45, -45, 90, -90, 135, -135, 180 }
    for _, deg in ipairs(angles) do
        local dir = rotateAroundY(away, math.rad(deg))
        local endPos = myPos + dir * CONFIG.FLEE_DISTANCE

        -- Endpoint must keep AI far from killer
        if (endPos - killerPos).Magnitude >= CONFIG.FLEE_MIN_DIST_KILLER then
            if tryFleeCandidate(myPos, endPos) then
                FLEE.target = endPos
                FLEE.lastPick = now
                if (now - FLEE.lastLog) > 1 then
                    FLEE.lastLog = now
                    log(string.format("Flee target: angle=%d dist=%.0f", deg, CONFIG.FLEE_DISTANCE))
                end
                return endPos
            end
        end
    end

    -- Fallback: shorter hop straight away from killer
    local fb = myPos + away * 22
    FLEE.target = fb
    FLEE.lastPick = now
    if (now - FLEE.lastLog) > 1 then
        FLEE.lastLog = now
        log("Flee fallback (all candidates failed)")
    end
    return fb
end

-- ============================================================================
-- SURVIVOR AI
-- ============================================================================
local Survivor = {
    State = "WaitingForCharacter",
    targetGen = nil, approachPos = nil,
    lastGenScan = 0, lastProgress = nil,
    lastProgressT = 0, failedGens = {},
}

local function survivorReset()
    Survivor.State = "WaitingForCharacter"
    Survivor.targetGen = nil
    Survivor.approachPos = nil
    Survivor.lastGenScan = 0
    Survivor.lastProgress = nil
    Survivor.lastProgressT = 0
    Survivor.failedGens = {}
    resetMove()
    resetFlee()
    releaseShift()
end

local function survivorPickGenerator(now)
    local g = findBestGenerator()
    if g and Survivor.failedGens[g] and (now - Survivor.failedGens[g]) < 8 then
        g = nil
    end
    Survivor.targetGen = g
    Survivor.approachPos = g and genApproachPoint(g)
    Survivor.lastGenScan = now
    Survivor.lastProgress = g and getGenProgress(g)
    Survivor.lastProgressT = now
    if g then
        log("Survivor gen target:", g:GetFullName())
    else
        log("Survivor: no valid generator found")
    end
    return g ~= nil
end

local function SurvivorAI(now)
    local hum = getHumanoid()
    local root = getRoot()
    if not hum or not root or hum.Health <= 0 then
        Survivor.State = "WaitingForCharacter"
        releaseShift()
        return
    end

    -- 1) Threat detection → evade using smarter flee target
    local killer, killerRoot, kD, threat = updateThreat(now)
    if threat and killerRoot then
        if Survivor.State ~= "EvadingKiller" then
            log("Survivor EVADE dist=", string.format("%.1f", kD))
            resetFlee()
        end
        Survivor.State = "EvadingKiller"
        local fleeTarget = pickFleeTarget(root, killerRoot)
        holdShift()
        stepMovement(fleeTarget)
        return
    end

    if Survivor.State == "EvadingKiller" then
        log("Survivor evade done")
        Survivor.State = "SearchingGenerator"
        Survivor.lastGenScan = 0
        resetFlee()
    end

    -- 2) Generator (re)selection
    local needRescan =
        Survivor.State == "SearchingGenerator"
        or (now - Survivor.lastGenScan > CONFIG.SURV_REGEN_INTERVAL)
        or (Survivor.targetGen and not Survivor.targetGen.Parent)

    if needRescan then
        if not survivorPickGenerator(now) then
            Survivor.State = "SearchingGenerator"
            releaseShift()
            stopMoving()
            return
        end
        Survivor.State = "MovingToGenerator"
    end

    local gen = Survivor.targetGen
    if not gen or not gen.Parent then
        Survivor.State = "SearchingGenerator"
        releaseShift()
        return
    end

    local prog = getGenProgress(gen)
    if prog and prog >= 100 then
        log("Survivor gen completed, reselect")
        Survivor.State = "SearchingGenerator"
        Survivor.lastGenScan = 0
        releaseShift()
        return
    end

    local ap = Survivor.approachPos or genApproachPoint(gen)
    if not ap then
        Survivor.State = "SearchingGenerator"
        return
    end
    Survivor.approachPos = ap

    local d = (root.Position - ap).Magnitude
    if d <= CONFIG.SURV_GEN_ACTION_R then
        -- 3) Interact with generator
        if Survivor.State ~= "InteractingWithGenerator" then
            log("Survivor INTERACT gen")
            Survivor.State = "InteractingWithGenerator"
            Survivor.lastProgress = getGenProgress(gen)
            Survivor.lastProgressT = now
        end
        stopMoving()
        releaseShift()
        TriggerMobileButton()

        local curProg = getGenProgress(gen)
        if curProg and Survivor.lastProgress and curProg > Survivor.lastProgress then
            Survivor.lastProgress = curProg
            Survivor.lastProgressT = now
        end
        if now - Survivor.lastProgressT > CONFIG.SURV_GEN_NO_PROGRESS then
            log("Survivor gen no progress, abandon")
            Survivor.failedGens[gen] = now
            Survivor.State = "SearchingGenerator"
            Survivor.lastGenScan = 0
            releaseShift()
        end
    else
        -- 4) Move toward generator
        if Survivor.State ~= "MovingToGenerator" then
            log("Survivor MOVE gen dist=", string.format("%.1f", d))
        end
        Survivor.State = "MovingToGenerator"
        holdShift()
        if not stepMovement(ap) then
            hum:MoveTo(ap)
        end
    end
end

-- ============================================================================
-- KILLER AI
-- ============================================================================
local Killer = {
    State = "WaitingForCharacter",
    target = nil, targetPlayer = nil,
    hitCount = {}, lastHitT = 0, lastCheck = 0,
}

local function killerReset()
    Killer.State = "WaitingForCharacter"
    Killer.target = nil
    Killer.targetPlayer = nil
    Killer.hitCount = {}
    Killer.lastHitT = 0
    Killer.lastCheck = 0
    resetMove()
    releaseShift()
end

local function KillerAI(now)
    local root = getRoot()
    local hum = getHumanoid()
    if not root or not hum or hum.Health <= 0 then
        Killer.State = "WaitingForCharacter"
        return
    end

    if now - Killer.lastCheck > CONFIG.KILLER_TARGET_RECHECK then
        Killer.lastCheck = now
        local t = Killer.target
        local tHum = t and t.Parent and t.Parent:FindFirstChildOfClass("Humanoid")
        local valid = tHum and tHum.Health > 0
        if not valid then
            local p = findNearestSurvivor(CONFIG.KILLER_DETECT_RANGE)
            Killer.targetPlayer = p
            Killer.target = p and getPlayerRoot(p) or nil
        end
    end

    local target = Killer.target
    if not target or not target.Parent then
        Killer.State = "Idle"
        stopMoving()
        return
    end

    local d = dist(root, target)
    if d <= CONFIG.KILLER_HIT_RANGE + CONFIG.KILLER_HIT_TOL then
        if Killer.State ~= "Attacking" then
            log("Killer ATTACK dist=", string.format("%.1f", d))
        end
        Killer.State = "Attacking"
        stopMoving()

        local uid = Killer.targetPlayer and Killer.targetPlayer.UserId or 0
        local hits = Killer.hitCount[uid] or 0
        if hits < CONFIG.KILLER_MAX_HITS and (now - Killer.lastHitT) > CONFIG.KILLER_HIT_COOLDOWN then
            Killer.lastHitT = now
            Killer.hitCount[uid] = hits + 1
            TriggerMobileButton()
        end
        if (Killer.hitCount[uid] or 0) >= CONFIG.KILLER_MAX_HITS then
            Killer.target = nil
            Killer.targetPlayer = nil
            Killer.State = "Idle"
        end
    else
        if Killer.State ~= "Chasing" then
            log("Killer CHASE dist=", string.format("%.1f", d))
        end
        Killer.State = "Chasing"
        stepMovement(target.Position)
    end
end

-- ============================================================================
-- ROLE CHANGE HANDLER + MAIN WATCHER
-- ============================================================================
local currentRole = nil
local roleWatcherConnection = nil

local function onRoleChange(oldRole, newRole)
    log("Role:", tostring(oldRole), "->", newRole)
    survivorReset()
    killerReset()
    resetThreat()

    if newRole == "Survivor" then
        if config.autoSkillCheckEnabled then
            log("AutoSkillCheck: arming")
            InitializeAutobuy()
        end
    end
end

local function startRoleWatcher()
    if roleWatcherConnection then return end
    roleWatcherConnection = RunService.Heartbeat:Connect(function()
        local now = tick()
        local role = getCurrentRole()

        if role ~= currentRole then
            local old = currentRole
            currentRole = role
            onRoleChange(old, role)
        end

        if readyLabel and readyLabel.Parent then
            readyLabel.Text = "AI ready ["..tostring(role).."]"
        end

        local hum = getHumanoid()
        if not hum or hum.Health <= 0 then
            releaseShift()
            stopMoving()
            return
        end

        if role == "Survivor" then
            local ok, err = pcall(SurvivorAI, now)
            if not ok then log("SurvivorAI error:", err) end
        elseif role == "Killer" then
            local ok, err = pcall(KillerAI, now)
            if not ok then log("KillerAI error:", err) end
        else
            stopMoving()
            releaseShift()
        end
    end)
    log("Role watcher started")
end

startRoleWatcher()

-- Ensure skillcheck processor is running from the start (it self-gates by role)
InitializeAutobuy()

-- ============================================================================
-- LIFECYCLE
-- ============================================================================
localPlayer.CharacterAdded:Connect(function()
    log("CharacterAdded: resetting drivers")
    survivorReset()
    killerReset()
    resetThreat()
    resetFlee()
end)

localPlayer.CharacterRemoving:Connect(function()
    releaseShift()
    stopMoving()
end)

-- ============================================================================
-- KILL SWITCH
-- ============================================================================
_G.KemiAI_Stop = function()
    if roleWatcherConnection then
        roleWatcherConnection:Disconnect()
        roleWatcherConnection = nil
    end
    if Skill.hb then
        Skill.hb:Disconnect()
        Skill.hb = nil
    end
    releaseShift()
    stopMoving()
    resetThreat()
    resetFlee()
    if readyGui then
        pcall(function() readyGui:Destroy() end)
        readyGui = nil
    end
    log("Stopped")
end

log("AI ready — skillcheck + flee build loaded")
