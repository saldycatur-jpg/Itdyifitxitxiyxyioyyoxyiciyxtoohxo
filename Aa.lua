-- ============================================================================
-- KEMI // PLAY AI — Perception + Weighted Decision + FSM + Nav Controller
--
-- 4-layer architecture:
--   [1] PERCEPTION     updatePerception(now)
--   [2] WEIGHTS        computeThreatProb(), routeCost()
--   [3] STATE MACHINE  ST.* + hysteresis + target commitment
--   [4] NAVIGATION     single-owner controller, op-id, retry/backoff
--
-- All previously working features preserved:
--   GenDone remote, skillcheck, GUI persistence, generator discovery,
--   Killer AI, role watcher, lifecycle, kill switch.
-- ============================================================================

local Players             = game:GetService("Players")
local RunService          = game:GetService("RunService")
local PathfindingService  = game:GetService("PathfindingService")
local VirtualInputManager = game:GetService("VirtualInputManager")
local GuiService          = game:GetService("GuiService")
local ReplicatedStorage   = game:GetService("ReplicatedStorage")

local localPlayer = Players.LocalPlayer
local playerGui   = localPlayer:WaitForChild("PlayerGui")

local function log(...) print("[KemiAI]", ...) end

-- ============================================================================
-- CONFIG
-- ============================================================================
local CONFIG = {
    DEBUG                = false,

    BASE_WALKSPEED       = 16,
    WALKSPEED_FACTOR     = 1.1,

    KILLER_DETECT_RANGE  = 300,
    KILLER_HIT_RANGE     = 6,
    KILLER_HIT_TOL       = 1,
    KILLER_MAX_HITS      = 2,
    KILLER_HIT_COOLDOWN  = 1.2,
    KILLER_TARGET_RECHECK= 0.5,

    SURV_GEN_DETECT      = 400,
    SURV_GEN_ACTION_R    = 5,
    SURV_REGEN_INTERVAL  = 1.5,
    SURV_GEN_NO_PROGRESS = 3.0,
    SURV_STUCK_WATCHDOG  = 10.0,

    -- Threat thresholds (kept for fallback + hard overrides)
    THREAT_WARNING_DIST  = 160,
    THREAT_ENTER_DIST    = 115,
    THREAT_EXIT_DIST     = 180,
    THREAT_EMERGENCY_D   = 45,
    THREAT_RAPID_CLOSE   = 8,
    THREAT_SAMPLE_INT    = 0.08,
    THREAT_SAMPLE_COUNT  = 6,
    THREAT_CLEAR_TIME    = 1.5,
    THREAT_HEADING_DOT   = 0.55,

    -- Weighted threat model
    THREAT_ENTER_PROB    = 0.65,   -- P >= this  -> FLEE
    THREAT_EXIT_PROB     = 0.35,   -- P <= this  -> leave FLEE
    THREAT_BIAS          = -3.5,
    W_THREAT_DISTANCE    = 4.0,
    W_THREAT_CLOSING     = 2.5,
    W_THREAT_HEADING     = 1.5,
    W_THREAT_TTC         = 2.0,
    W_THREAT_PATH_RISK   = 1.0,

    -- Route model
    ROUTE_MAX_PATH       = 400,
    ROUTE_SAFE_DIST      = 80,
    W_ROUTE_LENGTH       = 1.0,
    W_ROUTE_THREAT       = 2.5,
    W_ROUTE_DEADEND      = 5.0,
    W_ROUTE_SWITCH       = 0.4,
    W_ROUTE_SAFETY       = 1.5,
    GEN_SWITCH_MARGIN    = 15,
    GEN_RESCAN_COOLDOWN  = 4.0,

    -- Normalization
    NORM_MAX_CLOSING     = 40,
    NORM_MAX_TTC         = 5.0,

    FLEE_DISTANCE        = 45,
    FLEE_MIN_DIST_KILLER = 40,
    FLEE_REPICK_INTERVAL = 0.9,
    FLEE_REACHED_RADIUS  = 6,
    FLEE_SAFE_GEN_MAX    = 220,
    FLEE_FANOUT_THROTTLE = 1.2,  -- seconds between full fanout checks

    -- Pathfinding
    REPATH_INTERVAL      = 2.0,
    REPATH_DIST_THRESH   = 14,
    WAYPOINT_REACH_DIST  = 3.5,
    WAYPOINT_SKIP_DIST   = 5.0,
    WAYPOINT_TIMEOUT     = 1.2,
    PATH_FAIL_THRESHOLD  = 3,
    PATH_FAIL_COOLDOWN   = 10,
    PATH_RETRY_BACKOFF   = {0.5, 1.0, 2.0, 4.0},

    -- Navigation watchdog
    NAV_STUCK_TIME       = 1.5,
    NAV_PROGRESS_EPS     = 0.5,
    NAV_MAX_RECOVERIES   = 3,
    NAV_LOG_INTERVAL     = 2.0,
    NAV_SIDESTEP_DIST    = 8,

    -- GUI persistence
    GUI_CHECK_INTERVAL   = 2.0,

    -- Skillcheck
    SKILLCHECK_SNAP_OFF     = 109,
    SKILLCHECK_TRIGGER_START= 104,
    SKILLCHECK_TRIGGER_END  = 118,
    TRIGGER_INTERVAL        = 0.05,
    SNAP_INTERVAL           = 0.08,
    SNAP_TO_TRIGGER_TICKS   = 2,

    GEN_PROGRESS_WEIGHT  = 0.6,
    GEN_KILLER_SAFE_DIST = 60,
    GEN_KILLER_PENALTY   = 8,
    GEN_DISCOVERY_DEPTH  = 3,
    GEN_CACHE_TTL        = 3,

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

local ActionPath = CONFIG.ACTION_PATHS[1]
local TouchID    = CONFIG.TOUCH_ID

local config = _G.config
if type(config) ~= "table" then config = {} end
if config.autoSkillCheckEnabled == nil then config.autoSkillCheckEnabled = true end

local function dlog(...) if CONFIG.DEBUG then print("[KemiAI-dbg]", ...) end end

-- ============================================================================
-- UTIL: math helpers
-- ============================================================================
local function clamp(x, lo, hi)
    if x ~= x then return lo end -- NaN guard
    if x < lo then return lo end
    if x > hi then return hi end
    return x
end

local function sigmoid(z)
    if z < -20 then return 0 end
    if z > 20 then return 1 end
    return 1 / (1 + math.exp(-z))
end

local function safeNum(x, fallback)
    if type(x) ~= "number" then return fallback end
    if x ~= x then return fallback end
    if x == math.huge or x == -math.huge then return fallback end
    return x
end

-- ============================================================================
-- WEIGHTS (configurable, initial guesses)
-- ============================================================================
local WEIGHTS = {
    threat = {
        bias       = CONFIG.THREAT_BIAS,
        distance   = CONFIG.W_THREAT_DISTANCE,
        closing    = CONFIG.W_THREAT_CLOSING,
        heading    = CONFIG.W_THREAT_HEADING,
        ttc        = CONFIG.W_THREAT_TTC,
        pathRisk   = CONFIG.W_THREAT_PATH_RISK,
    },
    route = {
        length     = CONFIG.W_ROUTE_LENGTH,
        threat     = CONFIG.W_ROUTE_THREAT,
        deadEnd    = CONFIG.W_ROUTE_DEADEND,
        switch     = CONFIG.W_ROUTE_SWITCH,
        safety     = CONFIG.W_ROUTE_SAFETY,
    },
}

-- ============================================================================
-- GEN DONE REMOTE
-- ============================================================================
local GenDoneRemote = nil

local function getGenDoneRemote()
    if GenDoneRemote and GenDoneRemote.Parent then return GenDoneRemote end
    local ok, rem = pcall(function()
        local remotes = ReplicatedStorage:FindFirstChild("Remotes")
        if not remotes then return nil end
        local gen = remotes:FindFirstChild("Generator")
        if not gen then return nil end
        return gen:FindFirstChild("GenDone")
    end)
    GenDoneRemote = ok and rem or nil
    return GenDoneRemote
end

local Repair = { active = false, cancelFired = false }

local function notifyRepairStarted()
    Repair.active = true
    Repair.cancelFired = false
end

local function notifyRepairEnded()
    Repair.active = false
    Repair.cancelFired = false
end

local function fireGenDone()
    if Repair.cancelFired then return end
    Repair.cancelFired = true
    local rem = getGenDoneRemote()
    if not rem then
        log("GenDone: remote not found")
        return
    end
    local ok, err = pcall(function()
        if rem:IsA("RemoteEvent") then rem:FireServer()
        elseif rem:IsA("BindableEvent") then rem:Fire()
        else error("GenDone: wrong class "..rem.ClassName) end
    end)
    if ok then log("GenDone: fired") else log("GenDone err: "..tostring(err)) end
end

-- ============================================================================
-- FORWARD DECLARATIONS
-- ============================================================================
local Survivor
local Killer

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
local function posKey(pos)
    if not pos then return "nil" end
    return string.format("%.1f|%.1f|%.1f", pos.X, pos.Y, pos.Z)
end

-- ============================================================================
-- GUI
-- ============================================================================
local readyGui, readyLabel = nil, nil

local function createReadyGui()
    if readyGui and readyGui.Parent then
        pcall(function() readyGui:Destroy() end)
    end
    local pg = localPlayer:FindFirstChild("PlayerGui")
    if not pg then return false end

    readyGui = Instance.new("ScreenGui")
    readyGui.Name = "KemiAI_Ready"
    readyGui.ResetOnSpawn = false
    readyGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    readyGui.IgnoreGuiInset = true
    readyGui.Parent = pg

    readyLabel = Instance.new("TextLabel")
    readyLabel.AnchorPoint = Vector2.new(0, 1)
    readyLabel.Position = UDim2.new(0, 14, 1, -14)
    readyLabel.Size = UDim2.new(0, 460, 0, 18)
    readyLabel.BackgroundTransparency = 1
    readyLabel.Text = "AI ready [waiting]"
    readyLabel.TextColor3 = Color3.fromRGB(0, 255, 120)
    readyLabel.TextStrokeTransparency = 0.4
    readyLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
    readyLabel.Font = Enum.Font.GothamBold
    readyLabel.TextSize = 14
    readyLabel.TextXAlignment = Enum.TextXAlignment.Left
    readyLabel.Parent = readyGui
    return true
end

local function ensureGuiAlive()
    local pg = localPlayer:FindFirstChild("PlayerGui")
    if not pg then return end
    if readyGui and readyGui.Parent == pg and readyLabel and readyLabel.Parent == readyGui then
        return
    end
    log("GUI missing → recreating")
    createReadyGui()
end

createReadyGui()

-- ============================================================================
-- ROLE DETECTION
-- ============================================================================
local function matchRoleName(n)
    if type(n) ~= "string" then return nil end
    if n == "Survivors" or n == "Survivor" then return "Survivor" end
    if n == "Killers"   or n == "Killer"   then return "Killer" end
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
-- SHIFT
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
-- ACTION BUTTON
-- ============================================================================
local ActionDiag = { lastWarn = 0, lastOK = 0, hits = 0, misses = 0 }

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
    if not (b and b:IsA("GuiObject")) then
        ActionDiag.misses = ActionDiag.misses + 1
        local now = tick()
        if now - ActionDiag.lastWarn > 3 then
            ActionDiag.lastWarn = now
            dlog(string.format("TriggerMobileButton: no target (miss=%d hit=%d)",
                ActionDiag.misses, ActionDiag.hits))
        end
        return false
    end
    local p, s, i = b.AbsolutePosition, b.AbsoluteSize, GuiService:GetGuiInset()
    local cx = p.X + (s.X / 2) + i.X
    local cy = p.Y + (s.Y / 2) + i.Y
    pcall(function()
        VirtualInputManager:SendTouchEvent(TouchID, 0, cx, cy)
        task.wait(0.02)
        VirtualInputManager:SendTouchEvent(TouchID, 2, cx, cy)
    end)
    ActionDiag.hits = ActionDiag.hits + 1
    return true
end

-- ============================================================================
-- SKILLCHECK
-- ============================================================================
local Skill = {
    rsConn = nil, wasVisible = false,
    lastSnapT = 0, lastTriggerT = 0,
    lastFoundLog = 0, failLogThrottle = 0,
    promptToken = 0, snapTick = 0, frameCounter = 0,
}

local function collectChecks(prompt)
    local out, seen = {}, {}
    local function tryAdd(obj)
        if not obj or seen[obj] then return end
        local line = obj:FindFirstChild("Line")
        local goal = obj:FindFirstChild("Goal")
        if line and goal and line:IsA("GuiObject") and goal:IsA("GuiObject") then
            seen[obj] = true
            table.insert(out, obj)
        end
    end
    tryAdd(prompt:FindFirstChild("Check"))
    for _, ch in ipairs(prompt:GetChildren()) do tryAdd(ch) end
    for _, ch in ipairs(prompt:GetChildren()) do
        if not seen[ch] then
            for _, sub in ipairs(ch:GetChildren()) do tryAdd(sub) end
        end
    end
    return out
end

local function resolveSkillPrompt()
    local pg = localPlayer:FindFirstChild("PlayerGui")
    if not pg then return nil, {} end
    local prompt = pg:FindFirstChild("SkillCheckPromptGui")
    if not prompt then return nil, {} end
    return prompt, collectChecks(prompt)
end

local function angleInSuccessZone(lr, gr)
    local ss = (gr + CONFIG.SKILLCHECK_TRIGGER_START) % 360
    local se = (gr + CONFIG.SKILLCHECK_TRIGGER_END) % 360
    if ss > se then return (lr >= ss or lr <= se)
    else return (lr >= ss and lr <= se) end
end

local function skillCheckTick()
    Skill.frameCounter = Skill.frameCounter + 1
    if not config.autoSkillCheckEnabled then Skill.wasVisible = false return end
    if getCurrentRole() ~= "Survivor" then Skill.wasVisible = false return end

    local _, checks = resolveSkillPrompt()
    if #checks == 0 then
        if Skill.wasVisible then log("Skillcheck: closed") end
        Skill.wasVisible = false
        return
    end
    local visible = {}
    for _, c in ipairs(checks) do if c.Visible then table.insert(visible, c) end end
    if #visible == 0 then Skill.wasVisible = false return end

    local now = tick()
    if not Skill.wasVisible then
        log("Skillcheck visible: count=", #visible)
        Skill.wasVisible = true
        Skill.lastSnapT = 0
        Skill.lastTriggerT = 0
        Skill.snapTick = 0
    end

    if #visible == 1 and (now - Skill.lastSnapT) >= CONFIG.SNAP_INTERVAL then
        Skill.lastSnapT = now
        Skill.snapTick = Skill.frameCounter
        local c = visible[1]
        local line = c:FindFirstChild("Line")
        local goal = c:FindFirstChild("Goal")
        if line and goal then
            local gr = goal.Rotation % 360
            line.Rotation = (gr + CONFIG.SKILLCHECK_SNAP_OFF) % 360
        end
    end

    local ticksSinceSnap = Skill.frameCounter - Skill.snapTick
    if Skill.snapTick > 0 and ticksSinceSnap < CONFIG.SNAP_TO_TRIGGER_TICKS then return end

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

local function InitializeAutobuy()
    if Skill.rsConn then return end
    Skill.rsConn = RunService.RenderStepped:Connect(function()
        local ok, err = pcall(skillCheckTick)
        if not ok then
            local now = tick()
            if now - Skill.failLogThrottle > 3 then
                Skill.failLogThrottle = now
                log("skillCheckTick err:", err)
            end
        end
    end)
    log("Skillcheck processor started")
end

-- ============================================================================
-- LAYER 1: PERCEPTION
-- ============================================================================
local PERCEPT = {
    now = 0,

    hasRoot = false,
    hasHum = false,
    humHealth = 0,
    myPos = Vector3.zero,
    myVel = Vector3.zero,

    -- Killer
    killerPlayer = nil,
    killerRoot = nil,
    killerPos = Vector3.zero,
    killerDist = math.huge,
    killerVel = Vector3.zero,
    killerSpeed = 0,
    killerApproach = 0,      -- smoothed (positive = closing)
    killerHeadingDot = 0,    -- 1=towards, -1=away
    killerTTC = math.huge,
    killerVisible = false,

    -- Threat
    threatLevel = "none",    -- none|warning|danger|critical
    threatProb = 0,
    threatConfirmed = false,

    -- Target
    targetGen = nil,
    targetPos = nil,
    targetDist = math.huge,
    targetPathValid = false,
    targetPathLen = 0,
}

local SAMPLE = {
    t = {},
    d = {},
    n = 0,
    head = 0,
    count = 0,
}

local function samplePush(t, d)
    SAMPLE.head = SAMPLE.head + 1
    if SAMPLE.head > CONFIG.THREAT_SAMPLE_COUNT then SAMPLE.head = 1 end
    SAMPLE.t[SAMPLE.head] = t
    SAMPLE.d[SAMPLE.head] = d
    if SAMPLE.count < CONFIG.THREAT_SAMPLE_COUNT then SAMPLE.count = SAMPLE.count + 1 end
end

local function sampleOldest()
    if SAMPLE.count == 0 then return nil, nil end
    local idx = SAMPLE.head - SAMPLE.count + 1
    while idx < 1 do idx = idx + CONFIG.THREAT_SAMPLE_COUNT end
    while idx > CONFIG.THREAT_SAMPLE_COUNT do idx = idx - CONFIG.THREAT_SAMPLE_COUNT end
    return SAMPLE.t[idx], SAMPLE.d[idx]
end

local function sampleReset()
    SAMPLE.t = {} SAMPLE.d = {} SAMPLE.n = 0
    SAMPLE.head = 0 SAMPLE.count = 0
end

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
    for _, k in ipairs({"Role", "Team", "RoleName", "GameRole"}) do
        local ok, v = pcall(function() return p:GetAttribute(k) end)
        if ok then
            local r = matchRoleName(v)
            if r then return r end
        end
    end
    local c = p.Character
    if c then
        for _, k in ipairs({"Role", "Team", "RoleName", "GameRole"}) do
            local ok, v = pcall(function() return c:GetAttribute(k) end)
            if ok then
                local r = matchRoleName(v)
                if r then return r end
            end
        end
    end
    return nil
end

local function nearestKiller()
    local myRoot = getRoot()
    if not myRoot then return nil end
    local myPos = myRoot.Position
    local best, bestD = nil, math.huge
    for _, p in ipairs(Players:GetPlayers()) do
        if roleOfPlayer(p) == "Killer" then
            local r = getPlayerRoot(p)
            if r then
                local d = (myPos - r.Position).Magnitude
                if d < bestD then bestD, best = d, p end
            end
        end
    end
    return best, bestD
end

local function updatePerception(now)
    PERCEPT.now = now

    local root = getRoot()
    local hum = getHumanoid()
    PERCEPT.hasRoot = root ~= nil
    PERCEPT.hasHum = hum ~= nil
    PERCEPT.humHealth = hum and hum.Health or 0
    PERCEPT.myPos = root and root.Position or Vector3.zero
    PERCEPT.myVel = root and root.AssemblyLinearVelocity or Vector3.zero

    -- Killer detection
    local killerP, kD = nearestKiller()
    PERCEPT.killerPlayer = killerP
    PERCEPT.killerRoot = killerP and getPlayerRoot(killerP) or nil
    PERCEPT.killerDist = safeNum(kD, math.huge)

    if PERCEPT.killerRoot then
        PERCEPT.killerPos = PERCEPT.killerRoot.Position
        local kv = PERCEPT.killerRoot.AssemblyLinearVelocity
        PERCEPT.killerVel = kv or Vector3.zero
        PERCEPT.killerSpeed = PERCEPT.killerVel.Magnitude

        local toMe = PERCEPT.myPos - PERCEPT.killerPos
        if toMe.Magnitude > 0.5 and PERCEPT.killerSpeed > 2 then
            PERCEPT.killerHeadingDot = PERCEPT.killerVel.Unit:Dot(toMe.Unit)
        else
            PERCEPT.killerHeadingDot = 0
        end

        -- TTC = distance / max(closing speed, epsilon)
        local closing = math.max(PERCEPT.killerApproach, 0.5)
        PERCEPT.killerTTC = PERCEPT.killerDist / closing

        -- Visibility via raycast (safe pcall)
        PERCEPT.killerVisible = false
        if root then
            local params = RaycastParams.new()
            params.FilterType = Enum.RaycastFilterType.Exclude
            params.FilterDescendantsInstances = { getChar() }
            local ok, res = pcall(function()
                return workspace:Raycast(root.Position, (PERCEPT.killerPos - root.Position), params)
            end)
            if ok and res then
                -- Something between us and killer
                PERCEPT.killerVisible = false
            else
                PERCEPT.killerVisible = true
            end
        end
    else
        PERCEPT.killerPos = Vector3.zero
        PERCEPT.killerVel = Vector3.zero
        PERCEPT.killerSpeed = 0
        PERCEPT.killerHeadingDot = 0
        PERCEPT.killerTTC = math.huge
        PERCEPT.killerVisible = false
    end

    -- Sample distance for approach rate
    if killerP then
        samplePush(now, PERCEPT.killerDist)
        local tOld, dOld = sampleOldest()
        if tOld and dOld then
            local dt = now - tOld
            if dt > 0.05 then
                local raw = (dOld - PERCEPT.killerDist) / dt
                -- Smooth: 70% old + 30% new (responds in ~2 samples)
                PERCEPT.killerApproach = PERCEPT.killerApproach * 0.7 + raw * 0.3
            end
        end
    else
        PERCEPT.killerApproach = 0
        sampleReset()
    end
end

-- ============================================================================
-- LAYER 2: WEIGHTED DECISION MODEL
-- ============================================================================
-- Threat probability P ∈ [0,1]
local function computeThreatProb()
    local d  = PERCEPT.killerDist
    if d >= CONFIG.KILLER_DETECT_RANGE then return 0 end
    if not PERCEPT.killerRoot then return 0 end

    -- Feature: distance closeness
    local xd = clamp((CONFIG.KILLER_DETECT_RANGE - d) / CONFIG.KILLER_DETECT_RANGE, 0, 1)

    -- Feature: closing speed (positive = approaching)
    local xc = clamp(PERCEPT.killerApproach / CONFIG.NORM_MAX_CLOSING, 0, 1)

    -- Feature: heading (dot) toward us
    local xh = clamp((PERCEPT.killerHeadingDot + 1) * 0.5, 0, 1)

    -- Feature: time-to-contact
    local xtc = 0
    if PERCEPT.killerTTC < CONFIG.NORM_MAX_TTC then
        xtc = clamp(1 - PERCEPT.killerTTC / CONFIG.NORM_MAX_TTC, 0, 1)
    end

    -- Feature: killer near our target/path
    local xr = 0
    if Survivor and Survivor.targetGen then
        local tPos = Survivor.approachPos or PERCEPT.myPos
        local killerToTarget = (PERCEPT.killerPos - tPos).Magnitude
        if killerToTarget < CONFIG.ROUTE_SAFE_DIST then
            xr = clamp(1 - killerToTarget / CONFIG.ROUTE_SAFE_DIST, 0, 1)
        end
    end

    local w = WEIGHTS.threat
    local z = w.bias
          + w.distance * xd
          + w.closing  * xc
          + w.heading  * xh
          + w.ttc      * xtc
          + w.pathRisk * xr

    return sigmoid(z)
end

-- Route cost (lower = better). Returns cost, valid, detail
local function routeCost(gen, myPos, killerPos, isCurrent)
    if not gen or not gen.Parent then return math.huge, false, "no-gen" end
    if updateGeneratorProgress(gen) then return math.huge, false, "complete" end

    local ap = genApproachPoint(gen)
    if not ap then return math.huge, false, "no-approach" end
    if isTargetBlacklisted(ap) then return math.huge, false, "blacklisted" end

    local straightD = (myPos - ap).Magnitude
    -- Approximate path length with 1.3x straight distance (heuristic)
    -- A proper implementation could ComputeAsync but that's blocking
    local approxPath = straightD * 1.3
    local xL = clamp(approxPath / CONFIG.ROUTE_MAX_PATH, 0, 1)

    -- Threat exposure along route: killer distance to target
    local xT = 0
    if killerPos then
        local kToTarget = (killerPos - ap).Magnitude
        if kToTarget < CONFIG.ROUTE_SAFE_DIST then
            xT = clamp(1 - kToTarget / CONFIG.ROUTE_SAFE_DIST, 0, 1)
        end
    end

    local xDE = 0  -- path validity assumed; only computePath knows

    local xS = isCurrent and 0 or 1

    local xSF = 1
    if killerPos then
        local kToTarget = (killerPos - ap).Magnitude
        xSF = clamp(kToTarget / CONFIG.ROUTE_SAFE_DIST, 0, 1)
    end

    local w = WEIGHTS.route
    local cost = w.length  * xL
               + w.threat  * xT
               + w.deadEnd * xDE
               + w.switch  * xS
               - w.safety  * xSF

    return cost, true, string.format("L=%.2f T=%.2f S=%.2f switch=%.0f", xL, xT, xSF, xS)
end

-- ============================================================================
-- GENERATOR DISCOVERY
-- ============================================================================
local function getGameValue(obj, key)
    if not obj or not key then return nil end
    local ok, v = pcall(function() return obj:GetAttribute(key) end)
    if ok and v ~= nil then return v end
    local ch = obj:FindFirstChild(key)
    if ch and (ch:IsA("NumberValue") or ch:IsA("IntValue") or ch:IsA("StringValue")) then
        return tonumber(ch.Value)
    end
    return nil
end

local function getGenProgress(gen)
    if not gen then return nil end
    local v = getGameValue(gen, "RepairProgress") or getGameValue(gen, "Progress")
    if v == nil then return nil end
    return tonumber(v)
end

local function updateGeneratorProgress(gen)
    if not gen or not gen.Parent then return true end
    local percent = getGenProgress(gen)
    if percent == nil then return false end
    return percent >= 100
end

local function isValidGenerator(obj)
    if not obj or not obj.Parent then return false end
    for _, ch in ipairs(obj:GetChildren()) do
        if ch:IsA("BasePart") and ch.Name:match("^GeneratorPoint%d+$") then return true end
    end
    if obj:GetAttribute("RepairProgress") or obj:GetAttribute("Progress") then return true end
    local p = obj:FindFirstChild("RepairProgress") or obj:FindFirstChild("Progress")
    if p and (p:IsA("NumberValue") or p:IsA("IntValue")) then return true end
    return false
end

local GenRegistry = { container = nil, list = {}, lastScan = 0, lastCount = -1, lastReason = "" }

local function scanContainerDirect()
    local map = workspace:FindFirstChild("Map")
    local paths = {
        map and map:FindFirstChild("Generators"),
        map and map:FindFirstChild("Generator"),
        workspace:FindFirstChild("Generators"),
        workspace:FindFirstChild("Generator"),
    }
    for _, c in ipairs(paths) do
        if c and c.Parent then return c, "known-path" end
    end
    return nil, nil
end

local function scanContainerRecursive()
    local function scan(root, depth)
        if depth > CONFIG.GEN_DISCOVERY_DEPTH or not root then return nil end
        for _, ch in ipairs(root:GetChildren()) do
            if ch:IsA("Folder") or ch:IsA("Model") then
                if ch.Name:lower():find("generator") then
                    for _, sub in ipairs(ch:GetChildren()) do
                        if isValidGenerator(sub) then return ch end
                    end
                end
                local found = scan(ch, depth + 1)
                if found then return found end
            end
        end
        return nil
    end
    local found = scan(workspace, 0)
    if found then return found, "recursive-scan" end
    return nil, nil
end

local function collectGeneratorsFrom(container)
    local out = {}
    local function scan(node, depth)
        if depth > CONFIG.GEN_DISCOVERY_DEPTH + 1 or not node then return end
        for _, ch in ipairs(node:GetChildren()) do
            if isValidGenerator(ch) then
                table.insert(out, ch)
            elseif ch:IsA("Folder") or ch:IsA("Model") then
                scan(ch, depth + 1)
            end
        end
    end
    scan(container, 0)
    return out
end

local function getGeneratorList()
    local now = tick()
    if GenRegistry.container and GenRegistry.container.Parent then
        if now - GenRegistry.lastScan < CONFIG.GEN_CACHE_TTL then
            return GenRegistry.list, GenRegistry.lastReason
        end
        local refreshed = collectGeneratorsFrom(GenRegistry.container)
        if #refreshed > 0 then
            GenRegistry.list = refreshed
            GenRegistry.lastScan = now
            return refreshed, GenRegistry.lastReason
        end
    end
    local container, reason = scanContainerDirect()
    if not container then container, reason = scanContainerRecursive() end
    if container then
        local list = collectGeneratorsFrom(container)
        GenRegistry.container = container
        GenRegistry.list = list
        GenRegistry.lastScan = now
        if GenRegistry.lastCount ~= #list then
            GenRegistry.lastCount = #list
            log(string.format("Generator container: %s (%s) → %d gens",
                container:GetFullName(), reason, #list))
        end
        GenRegistry.lastReason = reason
        return list, reason
    end
    if GenRegistry.lastCount ~= 0 then
        GenRegistry.lastCount = 0
        log("Generator container: not found")
    end
    GenRegistry.container = nil
    GenRegistry.list = {}
    GenRegistry.lastScan = now
    GenRegistry.lastReason = "not-found"
    return {}, "not-found"
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

-- ============================================================================
-- LAYER 4: NAVIGATION CONTROLLER
-- ============================================================================
local MOVE = {
    waypoints = {}, index = 1,
    lastRepath = 0, lastTargetPos = nil,
    lastPos = nil, stuckSince = 0, stuckLogT = 0,
    consecutiveFails = 0, failTargetKey = nil,
    failedTargets = {},
    lastFailLog = 0,
    jumpCooldown = 0,
    sideStepUntil = 0, sideStepDir = nil,
    opId = 0,               -- path operation identity
    retryCount = 0,
    retryNextT = 0,
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
    MOVE.opId = MOVE.opId + 1
    local thisOp = MOVE.opId
    local path = PathfindingService:CreatePath({
        AgentRadius = 2, AgentHeight = 5,
        AgentCanJump = true, AgentMaxSlope = 45,
        WaypointSpacing = 4,
    })
    local ok = pcall(function() path:ComputeAsync(root.Position, targetPos) end)
    if MOVE.opId ~= thisOp then return false end  -- stale result
    local key = posKey(targetPos)
    if ok and path.Status == Enum.PathStatus.Success then
        MOVE.waypoints = path:GetWaypoints()
        MOVE.index = 1
        MOVE.lastRepath = tick()
        MOVE.lastTargetPos = targetPos
        MOVE.stuckSince = 0
        MOVE.consecutiveFails = 0
        MOVE.failTargetKey = nil
        MOVE.retryCount = 0
        return true
    end
    MOVE.waypoints = {}
    MOVE.index = 1
    MOVE.lastRepath = tick()
    MOVE.lastTargetPos = targetPos
    if MOVE.failTargetKey == key then
        MOVE.consecutiveFails = MOVE.consecutiveFails + 1
    else
        MOVE.consecutiveFails = 1
        MOVE.failTargetKey = key
    end
    if MOVE.consecutiveFails >= CONFIG.PATH_FAIL_THRESHOLD then
        MOVE.failedTargets[key] = tick()
        log(string.format("Path fail x%d → blacklist %ds",
            MOVE.consecutiveFails, CONFIG.PATH_FAIL_COOLDOWN))
        MOVE.consecutiveFails = 0
        MOVE.failTargetKey = nil
    end
    return false
end

local function isTargetBlacklisted(targetPos)
    local key = posKey(targetPos)
    local t = MOVE.failedTargets[key]
    if not t then return false end
    if tick() - t > CONFIG.PATH_FAIL_COOLDOWN then
        MOVE.failedTargets[key] = nil
        return false
    end
    return true
end

local function tryJumpUnstick()
    local hum = getHumanoid()
    if not hum then return end
    local now = tick()
    if now - MOVE.jumpCooldown < 0.6 then return end
    MOVE.jumpCooldown = now
    pcall(function() hum.Jump = true end)
end

local function trySideStep(root, targetPos)
    local hum = getHumanoid()
    if not hum or not root then return end
    local toTarget = (targetPos - root.Position)
    if toTarget.Magnitude < 0.5 then return end
    local dir = toTarget.Unit
    local perp = Vector3.new(-dir.Z, 0, dir.X)
    if MOVE.sideStepDir then perp = -MOVE.sideStepDir end
    MOVE.sideStepDir = perp
    MOVE.sideStepUntil = tick() + 0.35
    hum:MoveTo(root.Position + perp * CONFIG.NAV_SIDESTEP_DIST)
end

local function stepMovement(targetPos)
    local hum = getHumanoid()
    local root = getRoot()
    if not hum or not root or not targetPos then return false end
    hum.WalkSpeed = CONFIG.BASE_WALKSPEED * CONFIG.WALKSPEED_FACTOR

    local now = tick()

    -- Already at target
    if (root.Position - targetPos).Magnitude <= CONFIG.WAYPOINT_REACH_DIST then
        hum:MoveTo(root.Position)
        return true
    end

    -- Side-step in progress
    if MOVE.sideStepUntil > now then return true end

    -- Stuck detection
    if MOVE.lastPos then
        local delta = (root.Position - MOVE.lastPos).Magnitude
        if delta < 0.15 then
            if MOVE.stuckSince == 0 then MOVE.stuckSince = now end
        else
            MOVE.stuckSince = 0
        end
    end
    MOVE.lastPos = root.Position

    local stuckFor = (MOVE.stuckSince > 0) and (now - MOVE.stuckSince) or 0
    local isStuck = stuckFor >= CONFIG.WAYPOINT_TIMEOUT

    local noWaypoints = (#MOVE.waypoints == 0) or (MOVE.index > #MOVE.waypoints)
    local targetMoved = MOVE.lastTargetPos
        and (targetPos - MOVE.lastTargetPos).Magnitude > CONFIG.REPATH_DIST_THRESH
    local timeValve = (now - MOVE.lastRepath) > CONFIG.REPATH_INTERVAL

    local needRepath = false
    if noWaypoints then needRepath = true
    elseif targetMoved then needRepath = true
    elseif isStuck then
        needRepath = true
        MOVE.stuckSince = 0
        tryJumpUnstick()
        if MOVE.consecutiveFails >= 2 then trySideStep(root, targetPos) end
        local now2 = tick()
        if now2 - MOVE.stuckLogT > 3 then
            MOVE.stuckLogT = now2
            log("Movement: stuck → repath+jump")
        end
    elseif timeValve and MOVE.index > (#MOVE.waypoints - 1) then needRepath = true
    end

    if needRepath then
        -- Retry backoff
        if now < MOVE.retryNextT then
            hum:MoveTo(root.Position)
            return true
        end
        if isTargetBlacklisted(targetPos) then
            hum:MoveTo(root.Position)
            return false
        end
        local ok = computePath(targetPos)
        if not ok then
            MOVE.retryCount = MOVE.retryCount + 1
            local idx = math.min(MOVE.retryCount, #CONFIG.PATH_RETRY_BACKOFF)
            MOVE.retryNextT = now + CONFIG.PATH_RETRY_BACKOFF[idx]
        end
    end

    -- Follow waypoints with look-ahead
    if #MOVE.waypoints > 0 and MOVE.index <= #MOVE.waypoints then
        local wp = MOVE.waypoints[MOVE.index]
        if wp and (root.Position - wp.Position).Magnitude < CONFIG.WAYPOINT_REACH_DIST then
            MOVE.index = MOVE.index + 1
            local nxt = MOVE.waypoints[MOVE.index]
            if nxt and (root.Position - nxt.Position).Magnitude < CONFIG.WAYPOINT_SKIP_DIST then
                MOVE.index = MOVE.index + 1
            end
            wp = MOVE.waypoints[MOVE.index]
        end
        if wp then
            if wp.Action == Enum.PathWaypointAction.Jump then hum.Jump = true end
            hum:MoveTo(wp.Position)
        else
            hum:MoveTo(targetPos)
        end
    else
        hum:MoveTo(root.Position)
    end
    return true
end

-- ============================================================================
-- NAV WATCHDOG
-- ============================================================================
local NAV_WD = { lastPos = nil, lastProgressT = 0, recoveryCount = 0, lastLog = 0 }

local function resetNavWatchdog()
    NAV_WD.lastPos = nil
    NAV_WD.lastProgressT = 0
    NAV_WD.recoveryCount = 0
    NAV_WD.lastLog = 0
end

local function navWatchdog(now, shouldBeMoving, stateName)
    local root = getRoot()
    if not root then return end

    if not shouldBeMoving then
        NAV_WD.lastPos = root.Position
        NAV_WD.lastProgressT = now
        NAV_WD.recoveryCount = 0
        return
    end

    if not NAV_WD.lastPos then
        NAV_WD.lastPos = root.Position
        NAV_WD.lastProgressT = now
        return
    end

    local moved = (root.Position - NAV_WD.lastPos).Magnitude
    if moved >= CONFIG.NAV_PROGRESS_EPS then
        NAV_WD.lastPos = root.Position
        NAV_WD.lastProgressT = now
        NAV_WD.recoveryCount = 0
        return
    end

    local since = now - NAV_WD.lastProgressT
    if since >= CONFIG.NAV_STUCK_TIME then
        NAV_WD.recoveryCount = NAV_WD.recoveryCount + 1
        if now - NAV_WD.lastLog > CONFIG.NAV_LOG_INTERVAL then
            NAV_WD.lastLog = now
            log(string.format("Watchdog: no-progress %.1fs in %s → rec #%d",
                since, tostring(stateName), NAV_WD.recoveryCount))
        end
        tryJumpUnstick()
        resetMove()
        MOVE.opId = MOVE.opId + 1  -- invalidate any in-flight path
        if NAV_WD.recoveryCount >= CONFIG.NAV_MAX_RECOVERIES then
            if Survivor and Survivor.targetGen then
                log("Watchdog: abandoning target")
                Survivor.failedGens[Survivor.targetGen] = now
                Survivor.State = "SearchingGenerator"
                Survivor.lastGenScan = 0
                Survivor.lastLoggedGen = nil
            end
            NAV_WD.recoveryCount = 0
        end
        NAV_WD.lastPos = root.Position
        NAV_WD.lastProgressT = now
    end
end

-- ============================================================================
-- FLEE TARGET (non-blocking: path check via cache only)
-- ============================================================================
local FLEE = { target = nil, lastPick = 0, lastLog = 0, lastFail = 0,
               lastGen = nil, lastFanout = 0 }

local function resetFlee()
    FLEE.target = nil
    FLEE.lastPick = 0
    FLEE.lastLog = 0
    FLEE.lastFail = 0
    FLEE.lastGen = nil
    FLEE.lastFanout = 0
end

local function rotateAroundY(v, rad)
    local c, s = math.cos(rad), math.sin(rad)
    return Vector3.new(v.X * c - v.Z * s, 0, v.X * s + v.Z * c)
end

-- Cheap path test: 1 blocking call, only called for ONE best candidate
local function tryPathOnce(fromPos, endPos)
    local path = PathfindingService:CreatePath({
        AgentRadius = 2, AgentHeight = 5,
        AgentCanJump = true, AgentMaxSlope = 45,
        WaypointSpacing = 4,
    })
    local ok = pcall(function() path:ComputeAsync(fromPos, endPos) end)
    return ok and path.Status == Enum.PathStatus.Success
end

local function pickSafeFleeGenerator(myPos, killerPos, exclude)
    local list = getGeneratorList()
    if #list == 0 then return nil, nil end

    local best, bestPos, bestCost = nil, nil, math.huge
    local now = tick()
    for _, gen in ipairs(list) do
        if gen.Parent and gen ~= exclude then
            if not updateGeneratorProgress(gen) then
                local ap = genApproachPoint(gen)
                if ap and not isTargetBlacklisted(ap) then
                    local cost, valid = routeCost(gen, myPos, killerPos, false)
                    if valid and cost < bestCost then
                        bestCost = cost
                        best = gen
                        bestPos = ap
                    end
                end
            end
        end
    end
    -- Validate only the best candidate (one ComputeAsync)
    if best and bestPos and tryPathOnce(myPos, bestPos) then
        return best, bestPos
    end
    return nil, nil
end

local function pickFleeTarget(root, killerRoot)
    local now = tick()
    local myPos = root.Position
    local killerPos = killerRoot.Position
    local dToKiller = (myPos - killerPos).Magnitude

    if FLEE.target then
        local reached = (myPos - FLEE.target).Magnitude < CONFIG.FLEE_REACHED_RADIUS
        local stale = (now - FLEE.lastPick) >= CONFIG.FLEE_REPICK_INTERVAL
        local targetDanger = (FLEE.target - killerPos).Magnitude < dToKiller
        if not reached and not stale and not targetDanger then
            return FLEE.target
        end
    end

    if dToKiller < CONFIG.THREAT_EMERGENCY_D then
        local away = Vector3.new(myPos.X - killerPos.X, 0, myPos.Z - killerPos.Z)
        if away.Magnitude < 0.01 then away = Vector3.new(1, 0, 0) end
        away = away.Unit
        local endPos = myPos + away * CONFIG.FLEE_DISTANCE
        FLEE.target = endPos
        FLEE.lastPick = now
        if now - FLEE.lastLog > 1 then
            FLEE.lastLog = now
            log("Flee: EMERGENCY bolt")
        end
        return endPos
    end

    -- Try safe gen only every FLEE_FANOUT_THROTTLE seconds
    if now - FLEE.lastFanout > CONFIG.FLEE_FANOUT_THROTTLE then
        FLEE.lastFanout = now
        local safeGen, safePos = pickSafeFleeGenerator(myPos, killerPos, Survivor.targetGen)
        if safeGen and safePos then
            FLEE.target = safePos
            FLEE.lastPick = now
            FLEE.lastGen = safeGen
            log(string.format("Flee → gen %s", safeGen:GetFullName()))
            return safePos
        end
    end

    -- Fan out from killer direction
    local away = Vector3.new(myPos.X - killerPos.X, 0, myPos.Z - killerPos.Z)
    if away.Magnitude < 0.01 then away = Vector3.new(1, 0, 0) end
    away = away.Unit

    local angles = { 0, 30, -30, 60, -60, 90, -90, 120, -120, 150, -150, 180 }
    local dist = CONFIG.FLEE_DISTANCE
    for _, deg in ipairs(angles) do
        local dir = rotateAroundY(away, math.rad(deg))
        local endPos = myPos + dir * dist
        if (endPos - killerPos).Magnitude >= CONFIG.FLEE_MIN_DIST_KILLER then
            FLEE.target = endPos
            FLEE.lastPick = now
            return endPos
        end
    end

    local fb = myPos + away * 22
    FLEE.target = fb
    FLEE.lastPick = now
    if now - FLEE.lastFail > 1 then
        FLEE.lastFail = now
        log("Flee: fallback")
    end
    return fb
end

-- ============================================================================
-- SURVIVOR AI (STATE MACHINE)
-- ============================================================================
Survivor = {
    State = "WaitingForCharacter",
    targetGen = nil, approachPos = nil,
    lastGenScan = 0, lastProgress = nil,
    lastProgressT = 0, failedGens = {},
    lastLoggedGen = nil, lastNoGenLog = 0,
    lastStateLog = 0, lastSearchLog = 0,
    lastSwitchT = 0,
    threatSafeSince = nil,     -- time since threat went below EXIT prob
    targetChosenAt = 0,
    targetScoreWhenChosen = 0,
}

local function survivorReset()
    Survivor.State = "WaitingForCharacter"
    Survivor.targetGen = nil
    Survivor.approachPos = nil
    Survivor.lastGenScan = 0
    Survivor.lastProgress = nil
    Survivor.lastProgressT = 0
    Survivor.failedGens = {}
    Survivor.lastLoggedGen = nil
    Survivor.lastNoGenLog = 0
    Survivor.lastSearchLog = 0
    Survivor.lastSwitchT = 0
    Survivor.threatSafeSince = nil
    Survivor.targetChosenAt = 0
    Survivor.targetScoreWhenChosen = 0
    resetMove()
    resetFlee()
    resetNavWatchdog()
    notifyRepairEnded()
    releaseShift()
end

local function setSurvivorState(newState, now, extraLog)
    if Survivor.State ~= newState then
        log(string.format("Survivor state: %s → %s %s",
            Survivor.State, newState, extraLog or ""))
        Survivor.lastStateLog = now
        Survivor.State = newState
    end
end

-- ============================================================================
-- SURVIVOR AI — decision flow
-- ============================================================================
local function survivorPickGenerator(now, killerPos)
    local myRoot = getRoot()
    if not myRoot then return false end

    local current = Survivor.targetGen
    local currentValid = current and current.Parent and not updateGeneratorProgress(current)

    -- Evaluate current candidate cost
    if currentValid then
        local cost, valid = routeCost(current, myRoot.Position, killerPos and killerPos.Position or nil, true)
        if valid then
            -- Consider switching
            local canSwitch = (now - Survivor.lastSwitchT) > CONFIG.GEN_RESCAN_COOLDOWN
            if canSwitch then
                local list = getGeneratorList()
                local bestCost, bestGen = math.huge, nil
                for _, g in ipairs(list) do
                    if g ~= current then
                        local c, ok = routeCost(g, myRoot.Position, killerPos and killerPos.Position or nil, false)
                        if ok and c < bestCost then
                            bestCost, bestGen = c, g
                        end
                    end
                end
                if bestGen and (bestCost + CONFIG.GEN_SWITCH_MARGIN) < cost then
                    Survivor.targetGen = bestGen
                    Survivor.approachPos = genApproachPoint(bestGen)
                    Survivor.lastSwitchT = now
                    Survivor.targetChosenAt = now
                    log(string.format("Survivor: switch → %s (Δcost=%.1f)",
                        bestGen:GetFullName(), cost - bestCost))
                    return true
                end
            end
            -- Retain current
            Survivor.approachPos = genApproachPoint(current)
            Survivor.lastGenScan = now
            if Survivor.lastLoggedGen ~= current then
                Survivor.lastLoggedGen = current
                log(string.format("Survivor: retain %s", current:GetFullName()))
            end
            return true
        end
    end

    -- Pick fresh
    local list = getGeneratorList()
    local bestCost, bestGen = math.huge, nil
    for _, g in ipairs(list) do
        local c, ok = routeCost(g, myRoot.Position, killerPos and killerPos.Position or nil, false)
        if ok and c < bestCost then
            bestCost, bestGen = c, g
        end
    end
    Survivor.targetGen = bestGen
    Survivor.approachPos = bestGen and genApproachPoint(bestGen)
    Survivor.lastGenScan = now
    Survivor.lastProgress = bestGen and getGenProgress(bestGen)
    Survivor.lastProgressT = now
    Survivor.lastSwitchT = now
    Survivor.targetChosenAt = now
    Survivor.targetScoreWhenChosen = bestCost
    if bestGen then
        log(string.format("Survivor: picked %s (cost=%.1f)", bestGen:GetFullName(), bestCost))
        Survivor.lastLoggedGen = bestGen
        return true
    end
    if now - Survivor.lastNoGenLog > 3 then
        Survivor.lastNoGenLog = now
        log("Survivor: no valid gen")
    end
    return false
end

local function SurvivorAI(now)
    local hum = getHumanoid()
    local root = getRoot()
    if not hum or not root or hum.Health <= 0 then
        Survivor.State = "WaitingForCharacter"
        notifyRepairEnded()
        releaseShift()
        return
    end

    -- ===== Compute threat probability from perception =====
    local P = computeThreatProb()
    PERCEPT.threatProb = P

    local killerRoot = PERCEPT.killerRoot
    local kD = PERCEPT.killerDist

    -- Hard override: emergency distance always triggers FLEE
    local emergency = (killerRoot and kD <= CONFIG.THREAT_EMERGENCY_D)
    -- Hard override: close + heading toward + closing fast
    local hardOverride = killerRoot
        and kD <= CONFIG.THREAT_ENTER_DIST
        and PERCEPT.killerHeadingDot >= 0.6
        and PERCEPT.killerApproach >= 5

    -- Hysteresis state
    local currentlyFleeing = (Survivor.State == "EvadingKiller")
    local wantFlee = currentlyFleeing and (P > CONFIG.THREAT_EXIT_PROB) or (P >= CONFIG.THREAT_ENTER_PROB)
    if emergency or hardOverride then wantFlee = true end

    -- Update safe timer
    if not wantFlee and P <= CONFIG.THREAT_EXIT_PROB then
        if not Survivor.threatSafeSince then Survivor.threatSafeSince = now end
    else
        Survivor.threatSafeSince = nil
    end

    -- If in FLEE, require stable safety for THREAT_CLEAR_TIME to exit
    if currentlyFleeing then
        local safeLongEnough = Survivor.threatSafeSince
            and (now - Survivor.threatSafeSince) >= CONFIG.THREAT_CLEAR_TIME
        if not wantFlee and safeLongEnough then
            log(string.format("Survivor: FLEE→OBJECTIVE (P=%.2f)", P))
            Survivor.State = "SearchingGenerator"
            Survivor.lastGenScan = 0
            Survivor.lastLoggedGen = nil
            Survivor.threatSafeSince = nil
            resetFlee()
            resetNavWatchdog()
        end
    end

    -- FLEE branch
    if Survivor.State == "EvadingKiller" or wantFlee then
        if Survivor.State ~= "EvadingKiller" then
            setSurvivorState("EvadingKiller", now,
                string.format("(P=%.2f d=%.1f)", P, kD))
        end

        -- Fire GenDone if we were repairing
        if Repair.active or Survivor.State == "InteractingWithGenerator" then
            fireGenDone()
            notifyRepairEnded()
        end

        if not killerRoot then
            -- No killer anymore → back to search
            Survivor.State = "SearchingGenerator"
            resetFlee()
            return
        end

        releaseShift()
        local fleeTarget = pickFleeTarget(root, killerRoot)
        holdShift()
        stepMovement(fleeTarget)
        navWatchdog(now, true, "EvadingKiller")
        return
    end

    -- ===== OBJECTIVE path =====
    -- AllDone check
    if Survivor.State == "AllDone" then
        if now - Survivor.lastGenScan > 3 then
            Survivor.lastGenScan = now
            local list = getGeneratorList()
            for _, g in ipairs(list) do
                if not updateGeneratorProgress(g) then
                    log("Survivor: new gen detected → resume")
                    Survivor.State = "SearchingGenerator"
                    Survivor.lastLoggedGen = nil
                    break
                end
            end
        end
        notifyRepairEnded()
        releaseShift()
        stopMoving()
        navWatchdog(now, false, "AllDone")
        return
    end

    -- (Re)select generator
    local targetLost = (not Survivor.targetGen or not Survivor.targetGen.Parent)
    local targetComplete = Survivor.targetGen and updateGeneratorProgress(Survivor.targetGen)

    if Survivor.State == "SearchingGenerator" or targetLost or targetComplete then
        local killerP = killerRoot and PERCEPT.killerPlayer or nil
        local killerPosObj = killerRoot
        if not survivorPickGenerator(now, killerPosObj) then
            local list = getGeneratorList()
            local anyLeft = false
            for _, gg in ipairs(list) do
                if not updateGeneratorProgress(gg) then anyLeft = true break end
            end
            if not anyLeft and #list > 0 then
                log("Survivor: all gens complete → AllDone")
                Survivor.State = "AllDone"
                notifyRepairEnded()
                releaseShift()
                stopMoving()
            else
                setSurvivorState("SearchingGenerator", now)
                notifyRepairEnded()
                releaseShift()
                if now - Survivor.lastSearchLog > CONFIG.SURV_STUCK_WATCHDOG then
                    Survivor.lastSearchLog = now
                    log(string.format("Survivor: still searching (%d gens)", #list))
                end
            end
            navWatchdog(now, false, "SearchingGenerator")
            return
        end
        setSurvivorState("MovingToGenerator", now)
    end

    local gen = Survivor.targetGen
    if not gen or not gen.Parent then
        Survivor.State = "SearchingGenerator"
        notifyRepairEnded()
        releaseShift()
        return
    end

    local prog = getGenProgress(gen)
    if prog and prog >= 100 then
        log("Survivor: gen complete → reselect")
        Survivor.State = "SearchingGenerator"
        Survivor.lastGenScan = 0
        Survivor.lastLoggedGen = nil
        notifyRepairEnded()
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
        -- Interact
        if Survivor.State ~= "InteractingWithGenerator" then
            setSurvivorState("InteractingWithGenerator", now)
            Survivor.lastProgress = getGenProgress(gen)
            Survivor.lastProgressT = now
            notifyRepairStarted()
        end
        stopMoving()
        releaseShift()
        TriggerMobileButton()
        navWatchdog(now, false, "InteractingWithGenerator")

        local curProg = getGenProgress(gen)
        if curProg and Survivor.lastProgress and curProg > Survivor.lastProgress then
            Survivor.lastProgress = curProg
            Survivor.lastProgressT = now
        end
        if now - Survivor.lastProgressT > CONFIG.SURV_GEN_NO_PROGRESS then
            log("Survivor: gen no progress → abandon")
            Survivor.failedGens[gen] = now
            Survivor.State = "SearchingGenerator"
            Survivor.lastGenScan = 0
            Survivor.lastLoggedGen = nil
            notifyRepairEnded()
            releaseShift()
        end
    else
        if Survivor.State ~= "MovingToGenerator" then
            setSurvivorState("MovingToGenerator", now, string.format("(d=%.1f)", d))
        end
        notifyRepairEnded()
        holdShift()
        local ok = stepMovement(ap)
        navWatchdog(now, true, "MovingToGenerator")
        if not ok then
            log("Survivor: target blacklisted → reselect")
            Survivor.State = "SearchingGenerator"
            Survivor.lastGenScan = 0
            Survivor.lastLoggedGen = nil
        end
    end
end

-- ============================================================================
-- KILLER AI
-- ============================================================================
Killer = {
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
            log(string.format("Killer ATTACK d=%.1f", d))
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
            log(string.format("Killer CHASE d=%.1f", d))
        end
        Killer.State = "Chasing"
        stepMovement(target.Position)
    end
end

-- ============================================================================
-- ROLE WATCHER
-- ============================================================================
local currentRole = nil
local roleWatcherConnection = nil
local lastGuiCheck = 0

local function onRoleChange(oldRole, newRole)
    log(string.format("Role: %s → %s", tostring(oldRole), tostring(newRole)))
    survivorReset()
    killerReset()
    resetThreatSafeState()
    resetNavWatchdog()

    if newRole == "Survivor" then
        if config.autoSkillCheckEnabled then
            log("AutoSkillCheck: arming")
            InitializeAutobuy()
        end
    elseif newRole == "Spectator" then
        notifyRepairEnded()
        releaseShift()
        stopMoving()
        resetFlee()
    end
end

-- Forward helper
function resetThreatSafeState()
    if Survivor then Survivor.threatSafeSince = nil end
    if PERCEPT then
        PERCEPT.threatProb = 0
        PERCEPT.threatLevel = "none"
        PERCEPT.threatConfirmed = false
    end
    if PERCEPT then
        PERCEPT.killerApproach = 0
    end
    if _G and _G.__kemi_sampleReset then _G.__kemi_sampleReset() end
end

local function startRoleWatcher()
    if roleWatcherConnection then return end
    roleWatcherConnection = RunService.Heartbeat:Connect(function()
        local now = tick()

        if now - lastGuiCheck > CONFIG.GUI_CHECK_INTERVAL then
            lastGuiCheck = now
            ensureGuiAlive()
        end

        local role = getCurrentRole()
        if role ~= currentRole then
            local old = currentRole
            currentRole = role
            onRoleChange(old, role)
        end

        -- Update perception EVERY heartbeat
        updatePerception(now)

        if readyLabel and readyLabel.Parent then
            local extra = ""
            if role == "Survivor" then
                extra = string.format(" [%s P=%.2f d=%.0f]",
                    Survivor.State, PERCEPT.threatProb, PERCEPT.killerDist)
            elseif role == "Killer" then
                extra = string.format(" [%s]", Killer.State)
            end
            readyLabel.Text = "AI ready ["..tostring(role).."]"..extra
        end

        local hum = getHumanoid()
        if not hum or hum.Health <= 0 then
            notifyRepairEnded()
            releaseShift()
            stopMoving()
            return
        end

        if role == "Survivor" then
            local ok, err = pcall(SurvivorAI, now)
            if not ok then log("SurvivorAI err:", err) end
        elseif role == "Killer" then
            local ok, err = pcall(KillerAI, now)
            if not ok then log("KillerAI err:", err) end
        else
            notifyRepairEnded()
            stopMoving()
            releaseShift()
        end
    end)
    log("Role watcher started")
end

-- Attach sample reset to _G for reset helper
_G.__kemi_sampleReset = sampleReset

startRoleWatcher()
InitializeAutobuy()

-- ============================================================================
-- LIFECYCLE
-- ============================================================================
localPlayer.CharacterAdded:Connect(function()
    log("CharacterAdded: resetting")
    survivorReset()
    killerReset()
    resetThreatSafeState()
    resetNavWatchdog()
    notifyRepairEnded()
    ensureGuiAlive()
end)

localPlayer.CharacterRemoving:Connect(function()
    notifyRepairEnded()
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
    if Skill.rsConn then
        Skill.rsConn:Disconnect()
        Skill.rsConn = nil
    end
    notifyRepairEnded()
    releaseShift()
    stopMoving()
    resetThreatSafeState()
    resetNavWatchdog()
    if readyGui then
        pcall(function() readyGui:Destroy() end)
        readyGui = nil
        readyLabel = nil
    end
    log("Stopped")
end

log("AI ready — 4-layer build loaded")
