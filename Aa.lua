-- ============================================================================
-- KEMI // PLAY AI — Rebuilt for robustness
-- Split into two independent AI drivers: SurvivorAI() and KillerAI().
-- Real-time role detection, generator interaction verification,
-- double-skillcheck aware, event-driven threat detection.
-- ============================================================================

local Players             = game:GetService("Players")
local RunService          = game:GetService("RunService")
local PathfindingService  = game:GetService("PathfindingService")
local VirtualInputManager = game:GetService("VirtualInputManager")
local GuiService          = game:GetService("GuiService")

local localPlayer = Players.LocalPlayer
local playerGui   = localPlayer:WaitForChild("PlayerGui")

-- ============================================================================
-- CONFIG
-- ============================================================================
local CONFIG = {
    -- Movement
    BASE_WALKSPEED       = 16,
    WALKSPEED_FACTOR     = 1.1,     -- safe boost (16 -> 17.6)

    -- Killer
    KILLER_DETECT_RANGE  = 250,
    KILLER_HIT_RANGE     = 6,
    KILLER_HIT_TOL       = 1,
    KILLER_MAX_HITS      = 2,
    KILLER_HIT_COOLDOWN  = 1.2,
    KILLER_TARGET_RECHECK= 0.5,

    -- Survivor
    SURV_GEN_DETECT      = 250,
    SURV_GEN_ACTION_R    = 4,
    SURV_REGEN_INTERVAL  = 0.5,
    SURV_GEN_NO_PROGRESS = 2.0,     -- seconds without progress -> abandon gen

    -- Pathfinding
    REPATH_INTERVAL      = 0.4,
    REPATH_DIST_THRESH   = 6,
    WAYPOINT_REACH_DIST  = 3,
    WAYPOINT_TIMEOUT     = 3,

    -- Skillcheck
    SKILLCHECK_START_TOL = 101,
    SKILLCHECK_END_TOL   = 115,
    SKILLCHECK_FORCE_OFF = 109,

    -- Threat detection (event-driven sampler + pattern analysis)
    THREAT_SAMPLES       = 5,
    THREAT_SAMPLE_INT    = 0.18,    -- ~5.5Hz sampling
    THREAT_APPROACH_MIN  = 1.2,     -- studs/s minimum closing rate
    THREAT_EMERGENCY_D   = 12,      -- hard emergency distance
    THREAT_HYSTERESIS    = 1.6,     -- must exceed flee*1.6 to re-engage
    THREAT_CLEAR_TIME    = 2.5,     -- seconds out of range to clear
    THREAT_MIN_VEL_DOT   = 0.35,    -- killer velocity must point toward us

    -- Input
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

local function log(...)
    print("[KemiAI]", ...)
end

-- ============================================================================
-- GUI (bottom-left "AI ready [role]")
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
readyLabel.Size = UDim2.new(0, 260, 0, 18)
readyLabel.BackgroundTransparency = 1
readyLabel.Text = "AI ready"
readyLabel.TextColor3 = Color3.fromRGB(0, 255, 120)
readyLabel.TextStrokeTransparency = 0.4
readyLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
readyLabel.Font = Enum.Font.GothamBold
readyLabel.TextSize = 14
readyLabel.TextXAlignment = Enum.TextXAlignment.Left
readyLabel.Parent = readyGui

-- ============================================================================
-- CORE HELPERS
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
local function alive(part)
    return part and part.Parent ~= nil
end

-- ============================================================================
-- ROLE DETECTION — real-time, tolerant of Team/Attribute/Character changes
-- ============================================================================
local function classifyName(n)
    if type(n) ~= "string" then return nil end
    n = n:lower()
    if n:find("killer") or n:find("monster") or n:find("enemy") then return "Killer" end
    if n:find("survivor") then return "Survivor" end
    return nil
end

local function detectRole()
    -- 1) Team
    local r = classifyName(localPlayer.Team and localPlayer.Team.Name)
    if r then return r end

    -- 2) Player attribute
    for _, key in ipairs({ "Role", "Team", "RoleName", "GameRole" }) do
        local v = localPlayer:GetAttribute(key)
        r = classifyName(v)
        if r then return r end
    end

    -- 3) Character attribute
    local char = getChar()
    if char then
        for _, key in ipairs({ "Role", "Team", "RoleName", "GameRole" }) do
            local v = char:GetAttribute(key)
            r = classifyName(v)
            if r then return r end
        end

        -- 4) Character name hint
        r = classifyName(char.Name)
        if r then return r end
    end

    return "Spectator"
end

-- ============================================================================
-- CENTRALIZED SHIFT INPUT (hold/release with state tracking)
-- ============================================================================
local Shift = { held = false }

local function holdShift()
    if Shift.held then return end
    Shift.held = true
    pcall(function()
        VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.LeftShift, false, game)
    end)
    log("Shift HOLD")
end

local function releaseShift()
    if not Shift.held then return end
    Shift.held = false
    pcall(function()
        VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.LeftShift, false, game)
    end)
    log("Shift RELEASE")
end

-- ============================================================================
-- ACTION BUTTON (touch trigger)
-- ============================================================================
local function findActionButton()
    for _, path in ipairs(CONFIG.ACTION_PATHS) do
        local cur = playerGui
        local ok = true
        for seg in string.gmatch(path, "[^%.]+") do
            cur = cur and cur:FindFirstChild(seg)
            if not cur then ok = false break end
        end
        if ok and cur and cur:IsA("GuiObject") and cur.Visible then
            local sz = cur.AbsoluteSize
            if sz.X > 0 and sz.Y > 0 then
                return cur
            end
        end
    end
    return nil
end

local function triggerActionButton()
    local btn = findActionButton()
    if not btn then return false end
    local p, s, i = btn.AbsolutePosition, btn.AbsoluteSize, GuiService:GetGuiInset()
    local cx = p.X + (s.X * 0.5) + i.X
    local cy = p.Y + (s.Y * 0.5) + i.Y
    pcall(function()
        VirtualInputManager:SendTouchEvent(CONFIG.TOUCH_ID, 0, cx, cy)
        task.wait(0.02)
        VirtualInputManager:SendTouchEvent(CONFIG.TOUCH_ID, 2, cx, cy)
    end)
    return true
end

-- ============================================================================
-- MOVEMENT (pathfinding + waypoint follower)
-- ============================================================================
local MOVE = {
    waypoints = {},
    index = 1,
    lastRepath = 0,
    lastTargetPos = nil,
    lastPos = nil,
    stuckSince = 0,
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
        AgentRadius = 2,
        AgentHeight = 5,
        AgentCanJump = true,
        AgentMaxSlope = 45,
        WaypointSpacing = 4,
    })
    local ok = pcall(function()
        path:ComputeAsync(root.Position, targetPos)
    end)
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

-- stepMovement: moves character toward targetPos using pathfinding.
-- Returns true while actively moving.
local function stepMovement(targetPos)
    local hum = getHumanoid()
    local root = getRoot()
    if not hum or not root or not targetPos then return false end

    hum.WalkSpeed = CONFIG.BASE_WALKSPEED * CONFIG.WALKSPEED_FACTOR

    local now = tick()
    local needRepath = (now - MOVE.lastRepath > CONFIG.REPATH_INTERVAL)

    if MOVE.lastTargetPos then
        local moved = (targetPos - MOVE.lastTargetPos).Magnitude
        if moved > CONFIG.REPATH_DIST_THRESH then
            needRepath = true
        end
    end

    -- Stuck detection
    if MOVE.lastPos then
        local delta = (root.Position - MOVE.lastPos).Magnitude
        if delta < 0.15 then
            if MOVE.stuckSince == 0 then
                MOVE.stuckSince = now
            elseif now - MOVE.stuckSince > CONFIG.WAYPOINT_TIMEOUT then
                needRepath = true
                MOVE.stuckSince = 0
            end
        else
            MOVE.stuckSince = 0
        end
    end
    MOVE.lastPos = root.Position

    if needRepath then
        computePath(targetPos)
    end

    if #MOVE.waypoints > 0 then
        local wp = MOVE.waypoints[MOVE.index]
        if wp then
            local dWp = (root.Position - wp.Position).Magnitude
            if dWp < CONFIG.WAYPOINT_REACH_DIST then
                MOVE.index = MOVE.index + 1
                wp = MOVE.waypoints[MOVE.index]
            end
            if wp then
                if wp.Action == Enum.PathWaypointAction.Jump then
                    hum.Jump = true
                end
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

local function isSurvivorPlayer(p)
    if not p or p == localPlayer then return false end
    return classifyName(p.Team and p.Team.Name) == "Survivor"
end

local function isKillerPlayer(p)
    if not p or p == localPlayer then return false end
    return classifyName(p.Team and p.Team.Name) == "Killer"
end

local function findNearestSurvivor(maxDist)
    maxDist = maxDist or CONFIG.KILLER_DETECT_RANGE
    local myRoot = getRoot()
    if not myRoot then return nil, math.huge end
    local best, bestD = nil, maxDist
    for _, p in ipairs(Players:GetPlayers()) do
        if isSurvivorPlayer(p) then
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
        if isKillerPlayer(p) then
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
    return nil
end

local function findBestGenerator()
    local myRoot = getRoot()
    if not myRoot then return nil end
    local map = workspace:FindFirstChild("Map")
    local gens = map and map:FindFirstChild("Generators")
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
-- SKILLCHECK SYSTEM
--   Detects one or more visible Check instances.
--   - Single check  : force line into goal zone, trigger when in range.
--   - Double check  : NO forced rotation, only trigger if already in range.
-- ============================================================================
local Skill = {
    prompt = nil,
    active = false,
    double = false,
}

local function getPrompt()
    if Skill.prompt and Skill.prompt.Parent then return Skill.prompt end
    Skill.prompt = playerGui:FindFirstChild("SkillCheckPromptGui")
    return Skill.prompt
end

local function getVisibleChecks()
    local prompt = getPrompt()
    if not prompt then return {} end
    local out = {}
    for _, ch in ipairs(prompt:GetChildren()) do
        if ch:IsA("GuiObject") and ch.Name:match("^Check") and ch.Visible then
            if ch:FindFirstChild("Line") and ch:FindFirstChild("Goal") then
                table.insert(out, ch)
            end
        end
    end
    return out
end

local function angleInRange(lr, gr)
    local ss = (gr + CONFIG.SKILLCHECK_START_TOL) % 360
    local se = (gr + CONFIG.SKILLCHECK_END_TOL) % 360
    if ss > se then
        return (lr >= ss or lr <= se)
    else
        return (lr >= ss and lr <= se)
    end
end

local function skillcheckTick()
    local checks = getVisibleChecks()
    local n = #checks
    if n == 0 then
        if Skill.active then log("Skillcheck: idle") end
        Skill.active = false
        Skill.double = false
        return
    end

    if not Skill.active then
        log("Skillcheck: appear, count=", n)
    end
    Skill.active = true
    Skill.double = (n >= 2)

    if not Skill.double then
        -- Single check: force line into goal zone
        local check = checks[1]
        local line = check:FindFirstChild("Line")
        local goal = check:FindFirstChild("Goal")
        if line and goal then
            line.Rotation = (goal.Rotation + CONFIG.SKILLCHECK_FORCE_OFF) % 360
        end
    end

    -- Trigger action button for any check currently in success range
    for _, check in ipairs(checks) do
        local line = check:FindFirstChild("Line")
        local goal = check:FindFirstChild("Goal")
        if line and goal then
            local lr = line.Rotation % 360
            local gr = goal.Rotation % 360
            if angleInRange(lr, gr) then
                triggerActionButton()
            end
        end
    end
end

-- ============================================================================
-- THREAT TRACKER (killer detection with pattern analysis)
-- ============================================================================
local Threat = {
    samples = {},
    lastSampleT = 0,
    confirmed = false,
    clearStart = nil,
}

local function resetThreat()
    Threat.samples = {}
    Threat.lastSampleT = 0
    Threat.confirmed = false
    Threat.clearStart = nil
end

-- Returns: killerPlayer, killerRoot, distance, isThreat
local function updateThreat(now)
    local myRoot = getRoot()
    if not myRoot then resetThreat() return nil, nil, math.huge, false end

    local killer, kD = findNearestKiller(CONFIG.KILLER_DETECT_RANGE)
    if not killer then
        if Threat.confirmed then
            if not Threat.clearStart then Threat.clearStart = now
            elseif now - Threat.clearStart > CONFIG.THREAT_CLEAR_TIME then
                log("Threat: cleared (no killer)")
                resetThreat()
            end
        end
        return nil, nil, math.huge, false
    end

    local killerRoot = getPlayerRoot(killer)

    -- Sample
    if now - Threat.lastSampleT >= CONFIG.THREAT_SAMPLE_INT then
        Threat.lastSampleT = now
        table.insert(Threat.samples, { t = now, d = kD, pos = killerRoot and killerRoot.Position })
        while #Threat.samples > CONFIG.THREAT_SAMPLES do
            table.remove(Threat.samples, 1)
        end
    end

    -- Emergency override
    if kD <= CONFIG.THREAT_EMERGENCY_D then
        if not Threat.confirmed then log("Threat: EMERGENCY at", string.format("%.1f", kD)) end
        Threat.confirmed = true
        Threat.clearStart = nil
        return killer, killerRoot, kD, true
    end

    -- Pattern analysis
    if not Threat.confirmed and #Threat.samples >= CONFIG.THREAT_SAMPLES then
        local first = Threat.samples[1]
        local last = Threat.samples[#Threat.samples]
        local dt = last.t - first.t
        if dt > 0 then
            local closing = (first.d - last.d) / dt  -- studs/s (positive = approaching)

            -- Killer velocity toward us?
            local velOK = true
            if killerRoot then
                local v = killerRoot.AssemblyLinearVelocity
                if v.Magnitude > 1 then
                    local toMe = (myRoot.Position - killerRoot.Position)
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
                log("Threat: CONFIRMED, closing=", string.format("%.2f", closing))
            end
        end
    end

    -- Hysteresis: allow clearing only when far enough for long enough
    if Threat.confirmed then
        local far = kD > CONFIG.SURV_FLEE_DIST * CONFIG.THREAT_HYSTERESIS
        if far then
            if not Threat.clearStart then
                Threat.clearStart = now
            elseif now - Threat.clearStart > CONFIG.THREAT_CLEAR_TIME then
                log("Threat: cleared (killer far)")
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
-- SURVIVOR AI  (local function, independent state & lifecycle)
-- ============================================================================
local Survivor = {
    State = "WaitingForCharacter",
    targetGen = nil,
    approachPos = nil,
    lastGenScan = 0,
    interactStart = nil,
    lastProgress = nil,
    lastProgressT = 0,
    failedGens = {},   -- [gen] = timestamp of failure
}

local function survivorReset()
    Survivor.State = "WaitingForCharacter"
    Survivor.targetGen = nil
    Survivor.approachPos = nil
    Survivor.lastGenScan = 0
    Survivor.interactStart = nil
    Survivor.lastProgress = nil
    Survivor.lastProgressT = 0
    Survivor.failedGens = {}
    resetMove()
    releaseShift()
end

local function survivorPickGenerator(now)
    local g = findBestGenerator()
    if g and Survivor.failedGens[g] and (now - Survivor.failedGens[g]) < 8 then
        g = nil -- skip recently failed gen for a while
    end
    Survivor.targetGen = g
    Survivor.approachPos = g and genApproachPoint(g)
    Survivor.lastGenScan = now
    Survivor.interactStart = nil
    Survivor.lastProgress = g and getGenProgress(g)
    Survivor.lastProgressT = now
    if g then
        log("Survivor: new gen target", g:GetFullName())
    else
        log("Survivor: no valid generator found")
    end
end

local function survivorTick(now)
    SurvivorAI(now)
end

local function SurvivorAI(now)
    local hum = getHumanoid()
    local root = getRoot()
    if not hum or not root or hum.Health <= 0 then
        Survivor.State = "WaitingForCharacter"
        releaseShift()
        return
    end

    -- Skillcheck can appear any time. Handle it before movement decisions.
    skillcheckTick()

    -- Threat detection
    local killerP, killerRoot, kD, threat = updateThreat(now)

    if threat and killerRoot then
        -- Evade
        if Survivor.State ~= "EvadingKiller" then
            log("Survivor: EvadingKiller (dist=", string.format("%.1f", kD), ")")
        end
        Survivor.State = "EvadingKiller"
        Survivor.interactStart = nil

        -- Compute flee direction
        local away = (root.Position - killerRoot.Position)
        if away.Magnitude < 0.5 then
            away = Vector3.new(1, 0, 0)
        else
            away = away.Unit
        end
        -- Blend a small tangent to avoid running straight into walls
        local tangent = Vector3.new(-away.Z, 0, away.X)
        local fleeDir = (away * 0.85 + tangent * 0.15).Unit
        local fleeTarget = root.Position + fleeDir * 42

        holdShift()
        stepMovement(fleeTarget)
        return
    end

    -- Threat cleared -> Returning to work
    if Survivor.State == "EvadingKiller" then
        log("Survivor: Evade finished -> searching gen")
        Survivor.State = "SearchingGenerator"
        Survivor.lastGenScan = 0
    end

    -- Generator reselection / validation
    local now2 = now
    if Survivor.State == "SearchingGenerator"
        or now2 - Survivor.lastGenScan > CONFIG.SURV_REGEN_INTERVAL
        or (Survivor.targetGen and not Survivor.targetGen.Parent)
    then
        survivorPickGenerator(now2)
        if not Survivor.targetGen then
            Survivor.State = "WaitingForCharacter"
            releaseShift()
            stopMoving()
            return
        end
        Survivor.State = "MovingToGenerator"
    end

    -- Validate current gen still valid
    local gen = Survivor.targetGen
    if not gen or not gen.Parent then
        Survivor.State = "SearchingGenerator"
        releaseShift()
        return
    end
    local prog = getGenProgress(gen)
    if prog and prog >= 100 then
        log("Survivor: gen completed, reselect")
        Survivor.State = "SearchingGenerator"
        Survivor.lastGenScan = 0
        releaseShift()
        return
    end

    -- Refresh approach point
    local ap = Survivor.approachPos or genApproachPoint(gen)
    if not ap then
        Survivor.State = "SearchingGenerator"
        return
    end
    Survivor.approachPos = ap

    local d = (root.Position - ap).Magnitude
    if d <= CONFIG.SURV_GEN_ACTION_R then
        -- Interact with generator
        if Survivor.State ~= "InteractingWithGenerator" then
            log("Survivor: InteractingWithGenerator")
            Survivor.State = "InteractingWithGenerator"
            Survivor.interactStart = now
            Survivor.lastProgress = getGenProgress(gen)
            Survivor.lastProgressT = now
        end

        stopMoving()
        holdShift()                 -- hold Shift while interacting
        triggerActionButton()

        -- Verify progress is actually moving
        local curProg = getGenProgress(gen)
        if curProg and Survivor.lastProgress and curProg > Survivor.lastProgress then
            Survivor.lastProgress = curProg
            Survivor.lastProgressT = now
        end
        if now - Survivor.lastProgressT > CONFIG.SURV_GEN_NO_PROGRESS then
            log("Survivor: gen not progressing, abandon & repick")
            Survivor.failedGens[gen] = now
            Survivor.State = "SearchingGenerator"
            Survivor.lastGenScan = 0
            releaseShift()
        end
    else
        -- Move toward generator
        if Survivor.State ~= "MovingToGenerator" then
            log("Survivor: MovingToGenerator (dist=", string.format("%.1f", d), ")")
        end
        Survivor.State = "MovingToGenerator"
        holdShift()
        local moved = stepMovement(ap)
        if not moved then
            -- Path failed -> try once more with fallback straight-move
            hum:MoveTo(ap)
        end
    end
end

-- ============================================================================
-- KILLER AI  (local function, independent state & lifecycle)
-- ============================================================================
local Killer = {
    State = "WaitingForCharacter",
    target = nil,
    targetPlayer = nil,
    hitCount = {},
    lastHitT = 0,
    lastCheck = 0,
}

local function killerReset()
    Killer.State = "WaitingForCharacter"
    Killer.target = nil
    Killer.targetPlayer = nil
    Killer.hitCount = {}
    Killer.lastHitT = 0
    Killer.lastCheck = 0
    resetMove()
    releaseShift()  -- killer shouldn't hold Shift; keep safe
end

local function KillerAI(now)
    local root = getRoot()
    local hum = getHumanoid()
    if not root or not hum or hum.Health <= 0 then
        Killer.State = "WaitingForCharacter"
        return
    end

    -- Periodically validate / acquire target
    if now - Killer.lastCheck > CONFIG.KILLER_TARGET_RECHECK then
        Killer.lastCheck = now
        local t = Killer.target
        local tHum = t and t.Parent and t.Parent:FindFirstChildOfClass("Humanoid")
        local valid = tHum and tHum.Health > 0
        if not valid then
            local p, _ = findNearestSurvivor(CONFIG.KILLER_DETECT_RANGE)
            Killer.targetPlayer = p
            Killer.target = p and getPlayerRoot(p) or nil
            if p then log("Killer: target acquired", p.Name) end
        end
    end

    local target = Killer.target
    if not target or not target.Parent then
        Killer.State = "Idle"
        stopMoving()
        return
    end

    local d = dist(root, target)
    local targetPlayer = Killer.targetPlayer

    if d <= CONFIG.KILLER_HIT_RANGE + CONFIG.KILLER_HIT_TOL then
        if Killer.State ~= "Attacking" then
            log("Killer: Attacking (dist=", string.format("%.1f", d), ")")
        end
        Killer.State = "Attacking"
        stopMoving()

        local uid = targetPlayer and targetPlayer.UserId or 0
        local hits = Killer.hitCount[uid] or 0
        if hits < CONFIG.KILLER_MAX_HITS
            and (now - Killer.lastHitT) > CONFIG.KILLER_HIT_COOLDOWN then
            Killer.lastHitT = now
            Killer.hitCount[uid] = hits + 1
            triggerActionButton()
            log("Killer: hit", Killer.hitCount[uid])
        end
        if (Killer.hitCount[uid] or 0) >= CONFIG.KILLER_MAX_HITS then
            Killer.target = nil
            Killer.targetPlayer = nil
            Killer.State = "Idle"
        end
    else
        if Killer.State ~= "Chasing" then
            log("Killer: Chasing (dist=", string.format("%.1f", d), ")")
        end
        Killer.State = "Chasing"
        stepMovement(target.Position)
    end
end

-- ============================================================================
-- ROLE-DRIVEN DISPATCHER (single Heartbeat, split behavior)
-- ============================================================================
local lastRole = nil

local function onRoleChange(newRole)
    log("Role changed:", lastRole, "->", newRole)
    -- Reset both drivers cleanly; whichever role is now active will re-init itself.
    survivorReset()
    killerReset()
    resetThreat()
    if newRole == "Survivor" then
        log("SurvivorAI: armed")
    elseif newRole == "Killer" then
        log("KillerAI: armed")
    else
        log("Spectator: idle")
    end
end

local heartbeatConn = RunService.Heartbeat:Connect(function()
    local now = tick()

    -- Role real-time detection
    local role = detectRole()
    if role ~= lastRole then
        lastRole = role
        onRoleChange(role)
    end

    -- Update GUI badge
    if readyLabel and readyLabel.Parent then
        readyLabel.Text = "AI ready ["..tostring(role).."]"
    end

    -- Character guard
    local hum = getHumanoid()
    if not hum or hum.Health <= 0 then
        releaseShift()
        stopMoving()
        return
    end

    -- Dispatch
    if role == "Survivor" then
        SurvivorAI(now)
    elseif role == "Killer" then
        KillerAI(now)
    else
        -- Spectator: nothing, ensure clean
        stopMoving()
        releaseShift()
    end
end)

-- ============================================================================
-- LIFECYCLE — character added / removed, keep AI alive across resets
-- ============================================================================
localPlayer.CharacterAdded:Connect(function()
    log("CharacterAdded: resetting drivers")
    survivorReset()
    killerReset()
    resetThreat()
    -- lastRole stays the same; role detection will re-arm on next heartbeat.
end)

localPlayer.CharacterRemoving:Connect(function()
    releaseShift()
    stopMoving()
end)

-- ============================================================================
-- KILL SWITCH
-- ============================================================================
_G.KemiAI_Stop = function()
    if heartbeatConn then
        heartbeatConn:Disconnect()
        heartbeatConn = nil
    end
    releaseShift()
    stopMoving()
    resetThreat()
    if readyGui then
        pcall(function() readyGui:Destroy() end)
        readyGui = nil
    end
    log("Stopped")
end

log("AI ready — survivor/killer split build loaded")
