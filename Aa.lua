-- ============================================================================
-- KEMI // PLAY AI — Navigation Watchdog + GUI Persistence Fix
--
-- AUDIT-BASED FIXES (from deepseek_lua_20261016_081c73.lua):
--   F1: MOVE.failedTargets used Vector3 keys → blacklist never matched.
--       FIX: posKey() string keys.
--   F2: No watchdog for "should be moving but isn't" → AI stalled silently
--       until player nudged the character.
--       FIX: separate navWatchdog with jump fallback + abandon-target.
--   F3: GUI created once; if PlayerGui cleared on round transition, it was
--       never rebuilt.
--       FIX: ensureGuiAlive() called periodically from role watcher.
--   F4: THREAT_SAMPLE_INT too slow for fast killers.
--       FIX: 0.10s sampling + heading-based early warning.
--   F5: No diagnostic for "intentionally still" (interacting/repairing).
--       FIX: state-aware diagnostics in watchdog.
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
    DEBUG                = false,

    BASE_WALKSPEED       = 16,
    WALKSPEED_FACTOR     = 1.1,

    KILLER_DETECT_RANGE  = 250,
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

    -- Threat thresholds
    THREAT_WARNING_DIST  = 130,
    THREAT_ENTER_DIST    = 95,
    THREAT_EXIT_DIST     = 150,
    THREAT_EMERGENCY_D   = 28,
    THREAT_RAPID_CLOSE   = 10,     -- was 12 — trigger earlier
    THREAT_SAMPLE_INT    = 0.10,   -- was 0.15 — faster sampling
    THREAT_SAMPLE_COUNT  = 6,
    THREAT_CLEAR_TIME    = 1.5,
    THREAT_HEADING_DOT   = 0.7,    -- killer velocity toward us → "closing"

    FLEE_DISTANCE        = 40,
    FLEE_MIN_DIST_KILLER = 35,
    FLEE_REPICK_INTERVAL = 0.8,
    FLEE_REACHED_RADIUS  = 5,
    FLEE_SAFE_GEN_MAX    = 200,

    -- Pathfinding
    REPATH_INTERVAL      = 1.5,
    REPATH_DIST_THRESH   = 12,
    WAYPOINT_REACH_DIST  = 3.5,
    WAYPOINT_TIMEOUT     = 1.0,
    PATH_FAIL_THRESHOLD  = 3,
    PATH_FAIL_COOLDOWN   = 10,

    -- Navigation watchdog (NEW)
    NAV_STUCK_TIME       = 1.5,    -- seconds without movement → recovery
    NAV_PROGRESS_EPS     = 0.4,    -- studs; less than this counts as "not moving"
    NAV_MAX_RECOVERIES   = 3,      -- abandon target after this many failures
    NAV_LOG_INTERVAL     = 2.0,

    -- GUI persistence (NEW)
    GUI_CHECK_INTERVAL   = 2.0,

    -- Skillcheck (unchanged)
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

local function dlog(...)
    if CONFIG.DEBUG then print("[KemiAI-dbg]", ...) end
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

-- String key for Vector3 — fixes F1 (Vector3 as table key doesn't hash by value)
local function posKey(pos)
    if not pos then return "nil" end
    return string.format("%.1f|%.1f|%.1f", pos.X, pos.Y, pos.Z)
end

-- ============================================================================
-- GUI (extracted to function for recreation — fixes F3)
-- ============================================================================
local readyGui = nil
local readyLabel = nil

local function createReadyGui()
    -- Cleanup any stale reference first
    if readyGui and readyGui.Parent then
        pcall(function() readyGui:Destroy() end)
    end

    local pg = localPlayer:FindFirstChild("PlayerGui")
    if not pg then
        dlog("createReadyGui: PlayerGui not available")
        return false
    end

    readyGui = Instance.new("ScreenGui")
    readyGui.Name = "KemiAI_Ready"
    readyGui.ResetOnSpawn = false
    readyGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    readyGui.IgnoreGuiInset = true
    readyGui.Parent = pg

    readyLabel = Instance.new("TextLabel")
    readyLabel.AnchorPoint = Vector2.new(0, 1)
    readyLabel.Position = UDim2.new(0, 14, 1, -14)
    readyLabel.Size = UDim2.new(0, 420, 0, 18)
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
            dlog(string.format("TriggerMobileButton: no target (misses=%d hits=%d)",
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
    local now = tick()
    if now - ActionDiag.lastOK > 5 then
        ActionDiag.lastOK = now
        dlog(string.format("TriggerMobileButton: fired at %s", b:GetFullName()))
    end
    return true
end

-- ============================================================================
-- SKILLCHECK (unchanged mechanism — verified working)
-- ============================================================================
local Skill = {
    rsConn = nil,
    wasVisible = false,
    lastSnapT = 0,
    lastTriggerT = 0,
    lastFoundLog = 0,
    failLogThrottle = 0,
    promptToken = 0,
    lastPromptTokenSeen = 0,
    snapTick = 0,
    frameCounter = 0,
}

local function collectChecks(prompt)
    local out = {}
    local seen = {}
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
    if ss > se then
        return (lr >= ss or lr <= se)
    else
        return (lr >= ss and lr <= se)
    end
end

local function skillCheckTick()
    Skill.frameCounter = Skill.frameCounter + 1

    if not config.autoSkillCheckEnabled then
        Skill.wasVisible = false
        return
    end
    if getCurrentRole() ~= "Survivor" then
        Skill.wasVisible = false
        return
    end

    local _, checks = resolveSkillPrompt()
    if #checks == 0 then
        if Skill.wasVisible then log("Skillcheck: closed") end
        Skill.wasVisible = false
        return
    end

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
        Skill.snapTick = 0
        Skill.promptToken = Skill.promptToken + 1
        Skill.lastPromptTokenSeen = Skill.promptToken
    end

    -- Snap (single check only)
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

    -- Wait after snap
    local ticksSinceSnap = Skill.frameCounter - Skill.snapTick
    if Skill.snapTick > 0 and ticksSinceSnap < CONFIG.SNAP_TO_TRIGGER_TICKS then
        return
    end

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

local function InitializeAutobuy()
    if Skill.rsConn then
        dlog("Skillcheck: already running")
        return
    end
    Skill.rsConn = RunService.RenderStepped:Connect(function()
        local ok, err = pcall(skillCheckTick)
        if not ok then
            local now = tick()
            if now - Skill.failLogThrottle > 3 then
                Skill.failLogThrottle = now
                log("skillCheckTick error:", err)
            end
        end
    end)
    log("Skillcheck processor started")
end

-- ============================================================================
-- MOVEMENT (with string-key blacklist — F1 fix)
-- ============================================================================
local MOVE = {
    waypoints = {}, index = 1,
    lastRepath = 0, lastTargetPos = nil,
    lastPos = nil, stuckSince = 0,
    stuckLogT = 0,
    consecutiveFails = 0,
    failTargetKey = nil,
    failedTargets = {},     -- [posKeyString] = timestamp
    lastFailLog = 0,
    jumpCooldown = 0,
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
    local key = posKey(targetPos)
    if ok and path.Status == Enum.PathStatus.Success then
        MOVE.waypoints = path:GetWaypoints()
        MOVE.index = 1
        MOVE.lastRepath = tick()
        MOVE.lastTargetPos = targetPos
        MOVE.stuckSince = 0
        MOVE.consecutiveFails = 0
        MOVE.failTargetKey = nil
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
        local now = tick()
        if now - MOVE.lastFailLog > 3 then
            MOVE.lastFailLog = now
            log(string.format("Path fail x%d → blacklist target for %ds",
                MOVE.consecutiveFails, CONFIG.PATH_FAIL_COOLDOWN))
        end
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

-- Attempt to unstick via jump. Roblox Humanoid can get stuck on small ledges.
local function tryJumpUnstick()
    local hum = getHumanoid()
    if not hum then return end
    local now = tick()
    if now - MOVE.jumpCooldown < 1.0 then return end
    MOVE.jumpCooldown = now
    pcall(function() hum.Jump = true end)
    dlog("tryJumpUnstick fired")
end

local function stepMovement(targetPos)
    local hum = getHumanoid()
    local root = getRoot()
    if not hum or not root or not targetPos then return false end
    hum.WalkSpeed = CONFIG.BASE_WALKSPEED * CONFIG.WALKSPEED_FACTOR

    local now = tick()

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
    local timeValveExpired = (now - MOVE.lastRepath) > CONFIG.REPATH_INTERVAL

    local needRepath = false
    if noWaypoints then
        needRepath = true
    elseif targetMoved then
        needRepath = true
    elseif isStuck then
        needRepath = true
        MOVE.stuckSince = 0
        tryJumpUnstick()
        local now2 = tick()
        if now2 - MOVE.stuckLogT > 3 then
            MOVE.stuckLogT = now2
            log("Movement: stuck → repath + jump")
        end
    elseif timeValveExpired and (#MOVE.waypoints > 0 and MOVE.index > (#MOVE.waypoints - 1)) then
        needRepath = true
    end

    if needRepath then
        if isTargetBlacklisted(targetPos) then
            hum:MoveTo(root.Position)
            return false
        end
        computePath(targetPos)
    end

    if #MOVE.waypoints > 0 and MOVE.index <= #MOVE.waypoints then
        local wp = MOVE.waypoints[MOVE.index]
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
    else
        hum:MoveTo(root.Position)
    end
    return true
end

-- ============================================================================
-- NAVIGATION WATCHDOG (F2 fix)
--
-- Purpose: independently verify that AI is making real positional progress
-- when it *should* be moving. Detects the classic "stuck on wall / hidden
-- error / MoveTo reverted" case which previously required manual player
-- input to clear.
-- ============================================================================
local NAV_WD = {
    lastPos = nil,
    lastProgressT = 0,
    recoveryCount = 0,
    lastLog = 0,
    lastStateWhenChecked = nil,
}

local function resetNavWatchdog()
    NAV_WD.lastPos = nil
    NAV_WD.lastProgressT = 0
    NAV_WD.recoveryCount = 0
    NAV_WD.lastLog = 0
    NAV_WD.lastStateWhenChecked = nil
end

-- shouldBeMoving: true when the AI expects positional change this frame.
-- Call from SurvivorAI after state transitions.
local function navWatchdog(now, shouldBeMoving, stateName)
    local root = getRoot()
    if not root then return end

    if not shouldBeMoving then
        -- Voluntary standstill: keep baseline fresh, do not count
        NAV_WD.lastPos = root.Position
        NAV_WD.lastProgressT = now
        NAV_WD.recoveryCount = 0
        NAV_WD.lastStateWhenChecked = stateName
        return
    end

    if not NAV_WD.lastPos then
        NAV_WD.lastPos = root.Position
        NAV_WD.lastProgressT = now
        NAV_WD.lastStateWhenChecked = stateName
        return
    end

    local moved = (root.Position - NAV_WD.lastPos).Magnitude

    if moved >= CONFIG.NAV_PROGRESS_EPS then
        -- Real progress
        NAV_WD.lastPos = root.Position
        NAV_WD.lastProgressT = now
        NAV_WD.recoveryCount = 0
        NAV_WD.lastStateWhenChecked = stateName
        return
    end

    -- No meaningful progress
    local sinceProgress = now - NAV_WD.lastProgressT
    if sinceProgress >= CONFIG.NAV_STUCK_TIME then
        NAV_WD.recoveryCount = NAV_WD.recoveryCount + 1
        if now - NAV_WD.lastLog > CONFIG.NAV_LOG_INTERVAL then
            NAV_WD.lastLog = now
            log(string.format("Watchdog: no-progress %.1fs in %s → recovery #%d",
                sinceProgress, tostring(stateName), NAV_WD.recoveryCount))
        end

        -- Recovery step 1: jump and clear waypoints
        tryJumpUnstick()
        resetMove()

        -- Recovery step 2+: abandon current target
        if NAV_WD.recoveryCount >= CONFIG.NAV_MAX_RECOVERIES then
            if Survivor and Survivor.targetGen then
                log("Watchdog: abandoning target after repeated no-progress")
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
-- PLAYER HELPERS
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

-- ============================================================================
-- GENERATOR DISCOVERY (unchanged)
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
        if ch:IsA("BasePart") and ch.Name:match("^GeneratorPoint%d+$") then
            return true
        end
    end
    if obj:GetAttribute("RepairProgress") or obj:GetAttribute("Progress") then
        return true
    end
    local p = obj:FindFirstChild("RepairProgress") or obj:FindFirstChild("Progress")
    if p and (p:IsA("NumberValue") or p:IsA("IntValue")) then
        return true
    end
    return false
end

local GenRegistry = {
    container = nil, list = {}, lastScan = 0,
    lastCount = -1, lastReason = "",
}

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
    if not container then
        container, reason = scanContainerRecursive()
    end
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
-- FIND BEST GENERATOR (with string-key blacklist check)
-- ============================================================================
local function findBestGenerator(myRoot, killerPos, excludedGen)
    if not myRoot then return nil, "no-root" end
    local list, listReason = getGeneratorList()
    if #list == 0 then return nil, "list-empty ("..tostring(listReason)..")" end

    local best, bestScore, bestReason = nil, math.huge, ""
    local candidates, complete, noApproach, blacklisted = 0, 0, 0, 0
    local now = tick()

    for _, gen in ipairs(list) do
        if gen.Parent then
            if updateGeneratorProgress(gen) then
                complete = complete + 1
            elseif gen ~= excludedGen then
                local prog = getGenProgress(gen)
                local ap = genApproachPoint(gen)
                if ap then
                    if isTargetBlacklisted(ap) then
                        blacklisted = blacklisted + 1
                    else
                        local d = (myRoot.Position - ap).Magnitude
                        if d <= CONFIG.SURV_GEN_DETECT then
                            candidates = candidates + 1
                            local score = d - (prog or 0) * CONFIG.GEN_PROGRESS_WEIGHT
                            if killerPos then
                                local dK = (ap - killerPos).Magnitude
                                if dK < CONFIG.GEN_KILLER_SAFE_DIST then
                                    score = score + (CONFIG.GEN_KILLER_SAFE_DIST - dK) * CONFIG.GEN_KILLER_PENALTY
                                end
                            end
                            if Survivor.failedGens[gen] and (now - Survivor.failedGens[gen]) < 8 then
                                score = score + 1000
                            end
                            if score < bestScore then
                                bestScore = score
                                best = gen
                                bestReason = string.format("d=%.0f prog=%s score=%.1f",
                                    d, prog and string.format("%.0f", prog) or "?", score)
                            end
                        end
                    end
                else
                    noApproach = noApproach + 1
                end
            end
        end
    end

    if best then return best, bestReason end
    return nil, string.format("cand=%d complete=%d noApp=%d bl=%d",
        candidates, complete, noApproach, blacklisted)
end

-- ============================================================================
-- THREAT TRACKER (faster sampling + heading — F4 fix)
-- ============================================================================
local THREAT = {
    samples = {}, lastSampleT = 0,
    confirmed = false, clearStart = nil,
    approachRate = 0,
    level = "none",
    primary = nil, primaryRoot = nil, primaryDist = math.huge,
}

local function resetThreat()
    THREAT.samples = {}
    THREAT.lastSampleT = 0
    THREAT.confirmed = false
    THREAT.clearStart = nil
    THREAT.approachRate = 0
    THREAT.level = "none"
    THREAT.primary = nil
    THREAT.primaryRoot = nil
    THREAT.primaryDist = math.huge
end

local function evaluateKillers()
    local myRoot = getRoot()
    if not myRoot then return {} end
    local myPos = myRoot.Position
    local out = {}
    for _, p in ipairs(Players:GetPlayers()) do
        if roleOfPlayer(p) == "Killer" then
            local r = getPlayerRoot(p)
            if r then
                table.insert(out, { player = p, root = r, dist = (myPos - r.Position).Magnitude })
            end
        end
    end
    table.sort(out, function(a, b) return a.dist < b.dist end)
    return out
end

local function updateThreat(now)
    local myRoot = getRoot()
    if not myRoot then resetThreat() return nil, nil, math.huge, false end

    local killers = evaluateKillers()
    if #killers == 0 then
        if THREAT.confirmed then
            if not THREAT.clearStart then THREAT.clearStart = now end
            if now - THREAT.clearStart > CONFIG.THREAT_CLEAR_TIME then
                log("Threat cleared: no killer")
                resetThreat()
            end
        end
        return nil, nil, math.huge, false
    end

    local primary = killers[1]
    local kD = primary.dist
    local killerRoot = primary.root

    -- Heading check: is killer velocity pointing toward us?
    local headingToward = false
    if killerRoot then
        local v = killerRoot.AssemblyLinearVelocity
        if v and v.Magnitude > 2 then
            local toMe = (myRoot.Position - killerRoot.Position)
            if toMe.Magnitude > 0.5 then
                headingToward = v.Unit:Dot(toMe.Unit) > CONFIG.THREAT_HEADING_DOT
            end
        end
    end

    if now - THREAT.lastSampleT >= CONFIG.THREAT_SAMPLE_INT then
        THREAT.lastSampleT = now
        table.insert(THREAT.samples, { t = now, d = kD })
        while #THREAT.samples > CONFIG.THREAT_SAMPLE_COUNT do
            table.remove(THREAT.samples, 1)
        end
        if #THREAT.samples >= 2 then
            local f, l = THREAT.samples[1], THREAT.samples[#THREAT.samples]
            local dt = l.t - f.t
            if dt > 0.05 then
                THREAT.approachRate = (f.d - l.d) / dt
            end
        end
    end

    local newLevel = "none"
    if kD <= CONFIG.THREAT_EMERGENCY_D then
        newLevel = "critical"
    elseif kD <= CONFIG.THREAT_ENTER_DIST then
        newLevel = "danger"
    elseif kD <= CONFIG.THREAT_WARNING_DIST then
        newLevel = "warning"
    elseif THREAT.approachRate >= CONFIG.THREAT_RAPID_CLOSE and headingToward then
        newLevel = "warning"
    end

    if newLevel ~= "none" and not THREAT.confirmed then
        THREAT.confirmed = true
        THREAT.clearStart = nil
        log(string.format("Threat CONFIRMED [%s]: dist=%.1f rate=%.1f heading=%s",
            newLevel, kD, THREAT.approachRate, tostring(headingToward)))
    end
    THREAT.level = newLevel

    if THREAT.confirmed and newLevel == "none" then
        if kD > CONFIG.THREAT_EXIT_DIST then
            if not THREAT.clearStart then THREAT.clearStart = now end
            if now - THREAT.clearStart > CONFIG.THREAT_CLEAR_TIME then
                log(string.format("Threat cleared: dist=%.1f > exit", kD))
                resetThreat()
                return primary.player, killerRoot, kD, false
            end
        else
            THREAT.clearStart = nil
        end
    end

    THREAT.primary = primary.player
    THREAT.primaryRoot = killerRoot
    THREAT.primaryDist = kD

    return primary.player, killerRoot, kD, THREAT.confirmed
end

-- ============================================================================
-- FLEE TARGET (with string-key blacklist)
-- ============================================================================
local FLEE = { target = nil, lastPick = 0, lastLog = 0, lastFail = 0, lastGen = nil }

local function resetFlee()
    FLEE.target = nil
    FLEE.lastPick = 0
    FLEE.lastLog = 0
    FLEE.lastFail = 0
    FLEE.lastGen = nil
end

local function rotateAroundY(v, rad)
    local c, s = math.cos(rad), math.sin(rad)
    return Vector3.new(v.X * c - v.Z * s, 0, v.X * s + v.Z * c)
end

local function tryPath(fromPos, endPos)
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

    local best, bestPos, bestScore = nil, nil, math.huge
    local now = tick()
    for _, gen in ipairs(list) do
        if gen.Parent and gen ~= exclude then
            if not updateGeneratorProgress(gen) then
                local ap = genApproachPoint(gen)
                if ap and not isTargetBlacklisted(ap) then
                    local dAI = (myPos - ap).Magnitude
                    local dKiller = (ap - killerPos).Magnitude
                    if dAI <= CONFIG.FLEE_SAFE_GEN_MAX and dKiller >= CONFIG.FLEE_MIN_DIST_KILLER then
                        local prog = getGenProgress(gen) or 0
                        local score = dAI * 0.5 - prog * 0.3 - dKiller * 0.4
                        if Survivor.failedGens[gen] and (now - Survivor.failedGens[gen]) < 8 then
                            score = score + 5000
                        end
                        if score < bestScore then
                            if tryPath(myPos, ap) then
                                bestScore = score
                                best = gen
                                bestPos = ap
                            end
                        end
                    end
                end
            end
        end
    end
    return best, bestPos
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

    local safeGen, safePos = pickSafeFleeGenerator(myPos, killerPos, Survivor.targetGen)
    if safeGen and safePos then
        FLEE.target = safePos
        FLEE.lastPick = now
        FLEE.lastGen = safeGen
        if now - FLEE.lastLog > 1 then
            FLEE.lastLog = now
            log(string.format("Flee → gen %s", safeGen:GetFullName()))
        end
        return safePos
    end

    local away = Vector3.new(myPos.X - killerPos.X, 0, myPos.Z - killerPos.Z)
    if away.Magnitude < 0.01 then away = Vector3.new(1, 0, 0) end
    away = away.Unit

    local angles = { 0, 30, -30, 60, -60, 90, -90, 120, -120, 150, -150, 180 }
    local distances = { CONFIG.FLEE_DISTANCE, CONFIG.FLEE_DISTANCE * 0.7 }

    for _, d in ipairs(distances) do
        for _, deg in ipairs(angles) do
            local dir = rotateAroundY(away, math.rad(deg))
            local endPos = myPos + dir * d
            if (endPos - killerPos).Magnitude >= CONFIG.FLEE_MIN_DIST_KILLER then
                if tryPath(myPos, endPos) then
                    FLEE.target = endPos
                    FLEE.lastPick = now
                    return endPos
                end
            end
        end
    end

    local fb = myPos + away * 22
    FLEE.target = fb
    FLEE.lastPick = now
    if now - FLEE.lastFail > 1 then
        FLEE.lastFail = now
        log("Flee: fallback (all candidates failed)")
    end
    return fb
end

-- ============================================================================
-- SURVIVOR AI (with watchdog integration — F2 fix)
-- ============================================================================
Survivor = {
    State = "WaitingForCharacter",
    targetGen = nil, approachPos = nil,
    lastGenScan = 0, lastProgress = nil,
    lastProgressT = 0, failedGens = {},
    lastLoggedGen = nil,
    lastNoGenLog = 0,
    lastStateLog = 0,
    lastSearchLog = 0,
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
    resetMove()
    resetFlee()
    resetNavWatchdog()
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

local function survivorPickGenerator(now, killerPos, exclude)
    local myRoot = getRoot()
    if not myRoot then return false end
    local g, reason = findBestGenerator(myRoot, killerPos, exclude)
    Survivor.targetGen = g
    Survivor.approachPos = g and genApproachPoint(g)
    Survivor.lastGenScan = now
    Survivor.lastProgress = g and getGenProgress(g)
    Survivor.lastProgressT = now

    if g then
        if Survivor.lastLoggedGen ~= g then
            Survivor.lastLoggedGen = g
            log(string.format("Survivor: picked gen %s (%s)", g:GetFullName(), reason))
        end
        return true
    end

    if now - Survivor.lastNoGenLog > 3 then
        Survivor.lastNoGenLog = now
        log("Survivor: no valid gen. " .. tostring(reason))
    end
    return false
end

local function SurvivorAI(now)
    local hum = getHumanoid()
    local root = getRoot()
    if not hum or not root or hum.Health <= 0 then
        Survivor.State = "WaitingForCharacter"
        releaseShift()
        return
    end

    -- 1) THREAT — always first
    local killer, killerRoot, kD, threat = updateThreat(now)
    if threat and killerRoot then
        if Survivor.State ~= "EvadingKiller" then
            setSurvivorState("EvadingKiller", now, string.format("(dist=%.1f lvl=%s)",
                kD, THREAT.level))
        end
        -- Explicitly release repair-related state
        releaseShift()
        local fleeTarget = pickFleeTarget(root, killerRoot)
        holdShift()
        stepMovement(fleeTarget)
        navWatchdog(now, true, "EvadingKiller")
        return
    end

    -- 2) Exit evade
    if Survivor.State == "EvadingKiller" then
        log("Survivor: evade done → resume")
        Survivor.State = "SearchingGenerator"
        Survivor.lastGenScan = 0
        Survivor.lastLoggedGen = nil
        resetFlee()
        resetNavWatchdog()
    end

    -- 3) AllDone
    if Survivor.State == "AllDone" then
        if now - Survivor.lastGenScan > 3 then
            Survivor.lastGenScan = now
            local g = findBestGenerator(getRoot(), nil)
            if g then
                log("Survivor: new gen after AllDone → resume")
                Survivor.State = "SearchingGenerator"
                Survivor.lastLoggedGen = nil
            end
        end
        releaseShift()
        stopMoving()
        navWatchdog(now, false, "AllDone")
        return
    end

    -- 4) Generator (re)selection
    local needRescan =
        Survivor.State == "SearchingGenerator"
        or (now - Survivor.lastGenScan > CONFIG.SURV_REGEN_INTERVAL)
        or (Survivor.targetGen and not Survivor.targetGen.Parent)

    if needRescan then
        local killers = evaluateKillers()
        local killerPos = nil
        if #killers > 0 then
            local kr = killers[1].root
            if kr then killerPos = kr.Position end
        end

        if not survivorPickGenerator(now, killerPos, nil) then
            local list = getGeneratorList()
            local anyLeft = false
            for _, gg in ipairs(list) do
                if not updateGeneratorProgress(gg) then
                    anyLeft = true
                    break
                end
            end
            if not anyLeft and #list > 0 then
                log("Survivor: all generators complete → AllDone")
                Survivor.State = "AllDone"
                releaseShift()
                stopMoving()
            else
                setSurvivorState("SearchingGenerator", now)
                releaseShift()
                if now - Survivor.lastSearchLog > CONFIG.SURV_STUCK_WATCHDOG then
                    Survivor.lastSearchLog = now
                    log(string.format("Survivor: still searching (%.1fs). %d gens in list",
                        CONFIG.SURV_STUCK_WATCHDOG, #list))
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
        releaseShift()
        return
    end

    local prog = getGenProgress(gen)
    if prog and prog >= 100 then
        log("Survivor: gen complete → reselect")
        Survivor.State = "SearchingGenerator"
        Survivor.lastGenScan = 0
        Survivor.lastLoggedGen = nil
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
        if Survivor.State ~= "InteractingWithGenerator" then
            setSurvivorState("InteractingWithGenerator", now)
            Survivor.lastProgress = getGenProgress(gen)
            Survivor.lastProgressT = now
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
            releaseShift()
        end
    else
        if Survivor.State ~= "MovingToGenerator" then
            setSurvivorState("MovingToGenerator", now, string.format("(dist=%.1f)", d))
        end
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
-- KILLER AI (unchanged)
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
            log(string.format("Killer ATTACK dist=%.1f", d))
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
            log(string.format("Killer CHASE dist=%.1f", d))
        end
        Killer.State = "Chasing"
        stepMovement(target.Position)
    end
end

-- ============================================================================
-- ROLE WATCHER (with GUI watchdog — F3 fix)
-- ============================================================================
local currentRole = nil
local roleWatcherConnection = nil
local lastGuiCheck = 0

local function onRoleChange(oldRole, newRole)
    log(string.format("Role: %s → %s", tostring(oldRole), tostring(newRole)))
    survivorReset()
    killerReset()
    resetThreat()
    resetNavWatchdog()

    if newRole == "Survivor" then
        if config.autoSkillCheckEnabled then
            log("AutoSkillCheck: arming")
            InitializeAutobuy()
        end
    elseif newRole == "Spectator" then
        releaseShift()
        stopMoving()
        resetFlee()
    end
    -- Killer: state handled by KillerAI
end

local function startRoleWatcher()
    if roleWatcherConnection then return end
    roleWatcherConnection = RunService.Heartbeat:Connect(function()
        local now = tick()

        -- GUI lifecycle check (independent of role)
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

        if readyLabel and readyLabel.Parent then
            local extra = ""
            if role == "Survivor" then
                extra = string.format(" [%s]", Survivor.State)
            elseif role == "Killer" then
                extra = string.format(" [%s]", Killer.State)
            end
            readyLabel.Text = "AI ready ["..tostring(role).."]"..extra
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
    resetNavWatchdog()
    ensureGuiAlive()
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
    if Skill.rsConn then
        Skill.rsConn:Disconnect()
        Skill.rsConn = nil
    end
    releaseShift()
    stopMoving()
    resetThreat()
    resetFlee()
    resetNavWatchdog()
    if readyGui then
        pcall(function() readyGui:Destroy() end)
        readyGui = nil
        readyLabel = nil
    end
    log("Stopped")
end

log("AI ready — watchdog + GUI persistence build loaded")
