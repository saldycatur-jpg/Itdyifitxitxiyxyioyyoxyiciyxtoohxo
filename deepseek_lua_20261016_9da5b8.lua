-- ============================================================================
-- KEMI // PLAY AI — Fixed & Merged
-- Root causes fixed:
--   1. Role detection tidak lagi bergantung find() rapuh → exact Team.Name
--      match + attribute fallback (konsisten dgn AutoSkillCheck reference).
--   2. Generator container dicari multi-path, tidak hard-coded.
--   3. AutoSkillCheck diintegrasikan verbatim dan gated oleh
--      config.autoSkillCheckEnabled, di-reload saat role → Survivor.
--   4. Shift punya state tracker tunggal (hold/release) + semua jalur exit
--      melepas Shift (role change, CharacterRemoving, kill switch, evade,
--      interact-end).
--   5. startRoleWatcher = satu Heartbeat yang melakukan role detection +
--      AI dispatch + AutoSkillCheck arming. Tidak ada Heartbeat duplikat.
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

    THREAT_SAMPLES       = 5,
    THREAT_SAMPLE_INT    = 0.18,
    THREAT_APPROACH_MIN  = 1.2,
    THREAT_EMERGENCY_D   = 12,
    THREAT_HYSTERESIS    = 1.6,
    THREAT_CLEAR_TIME    = 2.5,
    THREAT_MIN_VEL_DOT   = 0.35,

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

-- Compat names from AutoSkillCheck reference
local ActionPath = CONFIG.ACTION_PATHS[1]
local TouchID    = CONFIG.TOUCH_ID

-- Config table (from caller env if it exists)
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
-- ROLE DETECTION (exact match like AutoSkillCheck reference + fallbacks)
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
    -- 1) Team (primary, matches AutoSkillCheck reference)
    local team = localPlayer.Team
    if team then
        local r = matchRoleName(team.Name)
        if r then return r end
    end

    -- 2) Player attribute fallback
    for _, k in ipairs({"Role", "Team", "RoleName", "GameRole"}) do
        local ok, v = pcall(function() return localPlayer:GetAttribute(k) end)
        if ok then
            local r = matchRoleName(v)
            if r then return r end
        end
    end

    -- 3) Character attribute fallback
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
-- SHIFT STATE (single tracker, guaranteed release)
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
-- AutoSkillCheck REFERENCE BLOCK (preserved verbatim, only harmless edits)
-- ============================================================================
local VisibilityConnection  = nil
local HeartbeatConnection   = nil  -- legacy name kept for compatibility
local currentRole           = nil
local roleWatcherConnection = nil

-- GetActionTarget: try all known action-button paths (defensive)
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

-- TriggerMobileButton: touch event on the resolved button
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

-- InitializeAutobuy: skillcheck watcher (single snap at appear + trigger-only)
local function InitializeAutobuy()
    task.spawn(function()
        local pg = localPlayer:FindFirstChild("PlayerGui")
        if not pg then return end
        local prompt = pg:FindFirstChild("SkillCheckPromptGui")
        if not prompt then
            prompt = pg:WaitForChild("SkillCheckPromptGui", 10)
        end
        if not prompt then return end
        local check = prompt:FindFirstChild("Check")
        if not check then return end
        if VisibilityConnection then VisibilityConnection:Disconnect() end

        local triggerCount = 0
        local MAX_TRIGGER = 99999999999
        local lastTriggerTime = 0
        local TRIGGER_INTERVAL = CONFIG.TRIGGER_INTERVAL
        local BIND_NAME_TRIGGER = "CyberTriggerSkillCheckLine"

        local function clearBinding()
            pcall(function()
                RunService:UnbindFromRenderStep(BIND_NAME_TRIGGER)
            end)
        end

        -- Helper: single snap Line ke Goal + 109
        local function snapLineOnce()
            local line = check:FindFirstChild("Line")
            local goal = check:FindFirstChild("Goal")
            if not line or not goal then return end
            local gr = goal.Rotation % 360
            line.Rotation = (gr + CONFIG.SKILLCHECK_SNAP_OFF) % 360
        end

        VisibilityConnection = check:GetPropertyChangedSignal("Visible"):Connect(function()
            if localPlayer.Team and localPlayer.Team.Name == "Survivors" and check.Visible then
                triggerCount = 0
                lastTriggerTime = 0
                clearBinding()

                -- SINGLE SNAP at appear; then let game animate freely.
                snapLineOnce()

                -- TRIGGER-ONLY MONITOR (no forced rotation after snap)
                RunService:BindToRenderStep(BIND_NAME_TRIGGER, Enum.RenderPriority.Last.Value, function()
                    if not check or not check.Parent or not check.Visible then return end
                    if triggerCount >= MAX_TRIGGER then return end

                    local currentLine = check:FindFirstChild("Line")
                    local currentGoal = check:FindFirstChild("Goal")
                    if not currentLine or not currentGoal then return end

                    local now = tick()
                    local lr = currentLine.Rotation % 360
                    local gr = currentGoal.Rotation % 360
                    local ss = (gr + CONFIG.SKILLCHECK_TRIGGER_START) % 360
                    local se = (gr + CONFIG.SKILLCHECK_TRIGGER_END) % 360
                    local inRange = false
                    if ss > se then
                        if lr >= ss or lr <= se then inRange = true end
                    else
                        if lr >= ss and lr <= se then inRange = true end
                    end

                    if inRange and (now - lastTriggerTime >= TRIGGER_INTERVAL) then
                        lastTriggerTime = now
                        triggerCount = triggerCount + 1
                        TriggerMobileButton()
                    end
                end)
            else
                clearBinding()
                triggerCount = 0
                lastTriggerTime = 0
            end
        end)
    end)
end

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
-- GENERATORS (defensive multi-path search)
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
-- THREAT TRACKER (pattern-based, event-driven)
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
-- SURVIVOR AI (independent local function)
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

    -- 1) Threat detection
    local killer, killerRoot, kD, threat = updateThreat(now)
    if threat and killerRoot then
        if Survivor.State ~= "EvadingKiller" then
            log("Survivor EVADE dist=", string.format("%.1f", kD))
        end
        Survivor.State = "EvadingKiller"
        local away = root.Position - killerRoot.Position
        if away.Magnitude < 0.5 then away = Vector3.new(1, 0, 0) else away = away.Unit end
        local tangent = Vector3.new(-away.Z, 0, away.X)
        local fleeDir = (away * 0.85 + tangent * 0.15).Unit
        local fleeTarget = root.Position + fleeDir * 42
        holdShift()
        stepMovement(fleeTarget)
        return
    end

    if Survivor.State == "EvadingKiller" then
        log("Survivor evade done")
        Survivor.State = "SearchingGenerator"
        Survivor.lastGenScan = 0
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
        -- 3) Interact
        if Survivor.State ~= "InteractingWithGenerator" then
            log("Survivor INTERACT gen")
            Survivor.State = "InteractingWithGenerator"
            Survivor.lastProgress = getGenProgress(gen)
            Survivor.lastProgressT = now
        end
        stopMoving()
        releaseShift()            -- release Shift during interaction
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
        -- 4) Move toward generator (hold Shift)
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
-- KILLER AI (independent local function)
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
    else
        -- Stop skillcheck for other roles
        if VisibilityConnection then
            pcall(function() VisibilityConnection:Disconnect() end)
            VisibilityConnection = nil
        end
        pcall(function() RunService:UnbindFromRenderStep("CyberTriggerSkillCheckLine") end)
    end
end

local function startRoleWatcher()
    if roleWatcherConnection then return end
    roleWatcherConnection = RunService.Heartbeat:Connect(function()
        local now = tick()
        local role = getCurrentRole()

        -- Role transition
        if role ~= currentRole then
            local old = currentRole
            currentRole = role
            onRoleChange(old, role)
        end

        -- GUI badge
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

        -- Dispatch (each wrapped in pcall so one error can't kill the loop)
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

-- ============================================================================
-- LIFECYCLE
-- ============================================================================
localPlayer.CharacterAdded:Connect(function()
    log("CharacterAdded: resetting drivers")
    survivorReset()
    killerReset()
    resetThreat()
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
    if VisibilityConnection then
        pcall(function() VisibilityConnection:Disconnect() end)
        VisibilityConnection = nil
    end
    pcall(function() RunService:UnbindFromRenderStep("CyberTriggerSkillCheckLine") end)
    releaseShift()
    stopMoving()
    resetThreat()
    if readyGui then
        pcall(function() readyGui:Destroy() end)
        readyGui = nil
    end
    log("Stopped")
end

log("AI ready — merged build loaded")