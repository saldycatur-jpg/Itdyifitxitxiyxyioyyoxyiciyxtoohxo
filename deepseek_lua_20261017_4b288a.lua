-- ============================================================================
-- KEMI // PLAY AI — R6 (Stable Single-Path + Survivor States)
--
-- Perubahan besar vs R3:
--   R6  SINGLE stable path. PathFollower dengan 1 Path object. Repath HANYA jika:
--        (a) tag goal berubah (gen→flee→rescue→heal)
--        (b) posisi goal geser >8 stud
--        (c) Path.Blocked event
--        (d) stuck >2s (jump + recompute)
--       Tidak ada repath periodik. Tidak ada time-valve. Tidak ada auto-retry.
--   R7  Hapus REPATH_INTERVAL / PATH_RETRY_INTERVAL / pathMemo untuk main path.
--   R8  getSurvivorState(): dead/hooked/carried/knocked/canBeHealed/injured/healthy
--   R9  Rescue & Heal prioritas; cek jarak killer ke target >50 stud dulu.
--   R10 Hold action (repair/heal/unhook) vs tap (attack/vault). stopRepair =
--       endHoldAction() (game auto-detects release).
--   R11 Self-state early return: hooked/carried diam; knocked self-heal.
--   R12 Skillcheck dihapus, diganti loadstring Sk.lua saat startup.
--   R13 SURV_GEN_DETECT=10000, RESCUE_DETECT_RANGE=10000.
--
-- Killer avoidance, GenDone, GUI, role watcher tetap.
-- ============================================================================

local Players             = game:GetService("Players")
local RunService          = game:GetService("RunService")
local PathfindingService  = game:GetService("PathfindingService")
local VirtualInputManager = game:GetService("VirtualInputManager")
local GuiService          = game:GetService("GuiService")
local ReplicatedStorage   = game:GetService("ReplicatedStorage")

local localPlayer = Players.LocalPlayer
local playerGui   = localPlayer:WaitForChild("PlayerGui")

local function log(...)  print("[KemiAI]", ...) end
local function dlog(...) if CONFIG and CONFIG.DEBUG then print("[KemiAI-dbg]", ...) end end

-- ============================================================================
-- CONFIG
-- ============================================================================
local CONFIG = {
    DEBUG                = false,
    DEBUG_NAV            = false,

    BASE_WALKSPEED       = 16,
    WALKSPEED_FACTOR     = 1.1,

    -- Killer
    KILLER_DETECT_RANGE  = 300,
    KILLER_HIT_RANGE     = 6,
    KILLER_HIT_TOL       = 1,
    KILLER_MAX_HITS      = 2,
    KILLER_HIT_COOLDOWN  = 1.2,
    KILLER_TARGET_RECHECK= 0.5,

    -- Generator (R13: 10000)
    SURV_GEN_DETECT      = 10000,
    SURV_GEN_ACTION_R    = 5,
    SURV_GEN_NO_PROGRESS = 3.0,
    SURV_STUCK_WATCHDOG  = 10.0,
    SEARCH_STUCK_LOG     = 5.0,

    -- Threat
    THREAT_WARNING_DIST  = 160,
    THREAT_ENTER_DIST    = 115,
    THREAT_EXIT_DIST     = 180,
    THREAT_EMERGENCY_D   = 45,
    THREAT_CLEAR_TIME    = 1.5,
    THREAT_HEADING_DOT   = 0.55,
    THREAT_P_ENTER       = 0.55,
    THREAT_P_EXIT        = 0.30,
    THREAT_TTC_HORIZON   = 6.0,
    THREAT_W = {
        bias=-4.2, w_distance=3.8, w_closing=2.5,
        w_heading=1.6, w_ttc=1.2, w_pathRisk=0.8,
    },

    ROUTE_W = {
        w_length=1.0, w_exposure=2.2, w_deadEnd=0.6,
        w_switch=0.8, w_safety=1.4,
    },
    ROUTE_REF_LEN = 100,

    -- Flee
    FLEE_DISTANCE        = 45,
    FLEE_MIN_DIST_KILLER = 40,
    FLEE_REPICK_INTERVAL = 1.5,
    FLEE_COMMIT_TIME     = 0.8,
    FLEE_REACHED_RADIUS  = 6,
    FLEE_SAFE_GEN_MAX    = 220,

    -- Path following (STABLE)
    WAYPOINT_REACH_DIST  = 4.5,
    WAYPOINT_SKIP_DIST   = 5.0,
    GOAL_REPATH_THRESH   = 8.0,
    PATH_FAIL_COOLDOWN   = 10,
    PATH_CACHE_TTL       = 2.0,

    -- Stuck (hanya repath setelah 2s)
    NAV_STUCK_TIME       = 2.0,
    NAV_PROGRESS_EPS     = 0.5,
    NAV_LOG_INTERVAL     = 2.0,

    -- Rescue / Heal (R9)
    RESCUE_DETECT_RANGE  = 10000,
    RESCUE_SAFE_DIST     = 50,
    RESCUE_ACTION_R      = 5,

    RAYCAST_DIST         = 12,
    GUI_CHECK_INTERVAL   = 2.0,

    -- Gen selection
    GEN_SWITCH_MARGIN    = 25,
    GEN_RESCAN_COOLDOWN  = 4.0,
    GEN_PROGRESS_WEIGHT  = 0.6,
    GEN_KILLER_SAFE_DIST = 60,
    GEN_KILLER_PENALTY   = 8,
    GEN_DISCOVERY_DEPTH  = 3,
    GEN_CACHE_TTL        = 3,

    -- Action IDs
    TAP_ID  = 8822,
    HOLD_ID = 8823,

    ACTION_PATHS = {
        "Survivor-mob.Controls.action",
        "Survivor-mob.Controls.action.check",
        "Survivor-mob.Controls.check",
        "Killer-mob.Controls.action",
        "Killer-mob.Controls.attack",
        "Killer-mob.Controls.check",
    },

    -- R12: skillcheck external
    SKILLCHECK_URL = "https://raw.githubusercontent.com/saldycatur-jpg/Itdyifitxitxiyxyioyyoxyiciyxtoohxo/refs/heads/main/Sk.lua",
}

local config = _G.config
if type(config) ~= "table" then config = {} end
if config.autoSkillCheckEnabled == nil then config.autoSkillCheckEnabled = true end

local function nlog(fmt, ...)
    if CONFIG.DEBUG_NAV then print("[KemiAI-nav]", string.format(fmt, ...)) end
end

-- ============================================================================
-- R12: LOADSTRING SKILLCHECK
-- ============================================================================
task.spawn(function()
    local ok, err = pcall(function()
        local src = game:HttpGet(CONFIG.SKILLCHECK_URL)
        if not src or #src < 10 then error("empty source") end
        local fn = loadstring(src)
        if not fn then error("loadstring nil") end
        local ok2, err2 = pcall(fn)
        if not ok2 then error("runtime: "..tostring(err2)) end
    end)
    if ok then log("Skillcheck (Sk.lua) loaded")
    else log("Skillcheck load failed:", tostring(err)) end
end)

-- ============================================================================
-- GEN DONE REMOTE
-- ============================================================================
local GenDoneRemote = nil
local function getGenDoneRemote()
    if GenDoneRemote and GenDoneRemote.Parent then return GenDoneRemote end
    local ok, rem = pcall(function()
        local r = ReplicatedStorage:FindFirstChild("Remotes")
        if not r then return nil end
        local g = r:FindFirstChild("Generator")
        return g and g:FindFirstChild("GenDone") or nil
    end)
    GenDoneRemote = ok and rem or nil
    return GenDoneRemote
end

local Repair = { active = false, cancelFired = false }
local function notifyRepairStarted() Repair.active = true; Repair.cancelFired = false end
local function notifyRepairEnded()   Repair.active = false; Repair.cancelFired = false end

local function fireGenDone()
    if Repair.cancelFired then return end
    Repair.cancelFired = true
    local rem = getGenDoneRemote()
    if not rem then return end
    pcall(function()
        if rem:IsA("RemoteEvent") then rem:FireServer()
        elseif rem:IsA("BindableEvent") then rem:Fire() end
    end)
end

-- ============================================================================
-- SHARED HELPERS
-- ============================================================================
local function getChar() return localPlayer.Character end
local function getHumanoid()
    local c = getChar(); return c and c:FindFirstChildOfClass("Humanoid")
end
local function getRoot()
    local c = getChar(); if not c then return nil end
    return c:FindFirstChild("HumanoidRootPart") or c:FindFirstChild("Torso")
end
local function getPlayerRoot(p)
    local c = p and p.Character
    if not c then return nil end
    return c:FindFirstChild("HumanoidRootPart") or c:FindFirstChild("Torso")
end
local function dist(a,b)
    if not a or not b then return math.huge end
    return (a.Position - b.Position).Magnitude
end
local function clamp(v, lo, hi)
    if v ~= v then return lo end
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end
local function sigmoid(z) z=clamp(z,-20,20); return 1/(1+math.exp(-z)) end

local function hasClearLine(fromPos, toPos, ignoreModel)
    if not fromPos or not toPos then return false end
    local delta = toPos - fromPos
    local mag = delta.Magnitude
    if mag < 0.5 then return true end
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    local ignore = { getChar() }
    if ignoreModel then table.insert(ignore, ignoreModel) end
    params.FilterDescendantsInstances = ignore
    return workspace:Raycast(fromPos, delta.Unit * math.min(mag, CONFIG.RAYCAST_DIST), params) == nil
end

local function rotateAroundY(v, rad)
    local c,s = math.cos(rad), math.sin(rad)
    return Vector3.new(v.X*c - v.Z*s, 0, v.X*s + v.Z*c)
end

-- ============================================================================
-- ROLE DETECTION
-- ============================================================================
local function matchRoleName(n)
    if type(n) ~= "string" then return nil end
    if n == "Survivors" or n == "Survivor" then return "Survivor" end
    if n == "Killers" or n == "Killer" then return "Killer" end
    local l = n:lower()
    if l:find("survivor") then return "Survivor" end
    if l:find("killer") or l:find("monster") then return "Killer" end
    return nil
end

local function getCurrentRole()
    if localPlayer.Team then
        local r = matchRoleName(localPlayer.Team.Name); if r then return r end
    end
    for _,k in ipairs({"Role","Team","RoleName","GameRole"}) do
        local ok,v = pcall(function() return localPlayer:GetAttribute(k) end)
        if ok then local r = matchRoleName(v); if r then return r end end
    end
    local c = getChar()
    if c then
        for _,k in ipairs({"Role","Team","RoleName","GameRole"}) do
            local ok,v = pcall(function() return c:GetAttribute(k) end)
            if ok then local r = matchRoleName(v); if r then return r end end
        end
    end
    return "Spectator"
end

local function roleOfPlayer(p)
    if not p or p == localPlayer then return nil end
    if p.Team then local r=matchRoleName(p.Team.Name); if r then return r end end
    for _,k in ipairs({"Role","Team","RoleName","GameRole"}) do
        local ok,v = pcall(function() return p:GetAttribute(k) end)
        if ok then local r=matchRoleName(v); if r then return r end end
    end
    local c = p.Character
    if c then
        for _,k in ipairs({"Role","Team","RoleName","GameRole"}) do
            local ok,v = pcall(function() return c:GetAttribute(k) end)
            if ok then local r=matchRoleName(v); if r then return r end end
        end
    end
    return nil
end

-- ============================================================================
-- R8: SURVIVOR STATE DETECTION
-- ============================================================================
local function getSurvivorState(p)
    p = p or localPlayer
    local char = p.Character
    if not char then return nil end
    local hum = char:FindFirstChildOfClass("Humanoid")
    if not hum then return nil end
    if hum.Health <= 0 then return "dead" end
    if char:GetAttribute("IsHooked") == true  then return "hooked" end
    if char:GetAttribute("IsCarried") == true then return "carried" end
    local rt = char:FindFirstChild("RagdollTrigger")
    if rt and rt:IsA("BoolValue") and rt.Value == true then return "knocked" end
    local root = getPlayerRoot(p)
    if root and root:GetAttribute("CanGetHealed") == true then return "canBeHealed" end
    if hum.Health <= 50 then return "injured" end
    return "healthy"
end

local function getSelfState() return getSurvivorState(localPlayer) end

-- ============================================================================
-- SHIFT
-- ============================================================================
local Shift = { held = false }
local function holdShift()
    if Shift.held then return end
    Shift.held = true
    pcall(function() VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.LeftShift, false, game) end)
end
local function releaseShift()
    if not Shift.held then return end
    Shift.held = false
    pcall(function() VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.LeftShift, false, game) end)
end

-- ============================================================================
-- ACTION BUTTON (tap + hold)
-- ============================================================================
local function GetActionTarget()
    for _, path in ipairs(CONFIG.ACTION_PATHS) do
        local cur = localPlayer:FindFirstChild("PlayerGui")
        if not cur then return nil end
        for seg in string.gmatch(path, "[^%.]+") do
            cur = cur and cur:FindFirstChild(seg)
        end
        if cur and cur:IsA("GuiObject") and cur.Visible then
            local sz = cur.AbsoluteSize
            if sz.X > 0 and sz.Y > 0 then return cur end
        end
    end
    return nil
end

local function getScreenPos(b)
    local p,s,i = b.AbsolutePosition, b.AbsoluteSize, GuiService:GetGuiInset()
    return p.X + s.X/2 + i.X, p.Y + s.Y/2 + i.Y
end

local function tapAction()
    local b = GetActionTarget()
    if not b then return false end
    local cx, cy = getScreenPos(b)
    pcall(function()
        VirtualInputManager:SendTouchEvent(CONFIG.TAP_ID, 0, cx, cy)
        task.wait(0.02)
        VirtualInputManager:SendTouchEvent(CONFIG.TAP_ID, 2, cx, cy)
    end)
    return true
end

local ActionHold = { active = false, pos = nil }

local function endHoldAction()
    if not ActionHold.active then return end
    local p = ActionHold.pos or {x=0,y=0}
    ActionHold.active = false
    ActionHold.pos = nil
    pcall(function()
        VirtualInputManager:SendTouchEvent(CONFIG.HOLD_ID, 2, p.x, p.y)
    end)
end

local function beginHoldAction()
    if ActionHold.active then return true end
    local b = GetActionTarget()
    if not b then return false end
    local cx, cy = getScreenPos(b)
    ActionHold.active = true
    ActionHold.pos = {x=cx, y=cy}
    pcall(function()
        VirtualInputManager:SendTouchEvent(CONFIG.HOLD_ID, 0, cx, cy)
    end)
    return true
end

-- ============================================================================
-- PERCEPTION
-- ============================================================================
local Perception = { smoothClosing=0, lastKD=nil, lastSampleT=0 }
local function resetPerception()
    Perception.smoothClosing = 0
    Perception.lastKD = nil
    Perception.lastSampleT = 0
end

local function perceiveThreat(now, killerRoot)
    local myRoot = getRoot()
    if not myRoot or not killerRoot or not killerRoot.Parent then return nil end
    local kD = (myRoot.Position - killerRoot.Position).Magnitude
    local instant = 0
    if Perception.lastKD then
        local dt = now - Perception.lastSampleT
        if dt > 0.01 then instant = (Perception.lastKD - kD)/dt end
    end
    Perception.lastKD = kD
    Perception.lastSampleT = now
    Perception.smoothClosing = Perception.smoothClosing*0.65 + instant*0.35
    local closing = Perception.smoothClosing
    local headingDot = 0
    local v = killerRoot.AssemblyLinearVelocity
    if v and v.Magnitude > 2 then
        local toMe = myRoot.Position - killerRoot.Position
        if toMe.Magnitude > 0.5 then headingDot = clamp(v.Unit:Dot(toMe.Unit), 0, 1) end
    end
    local ttc = (closing > 1) and (kD/closing) or math.huge
    local pathRisk = 0
    if Survivor and Survivor.approachPos then
        local dK = (Survivor.approachPos - killerRoot.Position).Magnitude
        pathRisk = clamp(1 - dK/CONFIG.GEN_KILLER_SAFE_DIST, 0, 1)
    end
    return { kD=kD, closing=closing, headingDot=headingDot, ttc=ttc,
             pathRisk=pathRisk, killerRoot=killerRoot, myRoot=myRoot }
end

local function computeThreatProbability(f)
    if not f then return 0 end
    local xD = clamp(1 - f.kD/CONFIG.THREAT_WARNING_DIST, 0, 1)
    local xC = clamp(f.closing/40, -1, 1)
    local xH = f.headingDot
    local xT = (f.ttc < CONFIG.THREAT_TTC_HORIZON and f.ttc > 0)
        and clamp(1 - f.ttc/CONFIG.THREAT_TTC_HORIZON, 0, 1) or 0
    local W = CONFIG.THREAT_W
    local z = W.bias + W.w_distance*xD + W.w_closing*xC + W.w_heading*xH
            + W.w_ttc*xT + W.w_pathRisk*f.pathRisk
    if f.kD <= CONFIG.THREAT_EMERGENCY_D then return 1.0 end
    return sigmoid(z)
end

local THREAT = { confirmed=false, clearStart=nil, level="none", P=0,
                 primary=nil, primaryRoot=nil, primaryDist=math.huge, lastLogP=0 }

local function resetThreat()
    THREAT.confirmed=false; THREAT.clearStart=nil; THREAT.level="none"; THREAT.P=0
    THREAT.primary=nil; THREAT.primaryRoot=nil; THREAT.primaryDist=math.huge
    resetPerception()
end

local function evaluateKillers()
    local myRoot = getRoot()
    if not myRoot then return {} end
    local myPos = myRoot.Position
    local out = {}
    for _,p in ipairs(Players:GetPlayers()) do
        if roleOfPlayer(p) == "Killer" then
            local r = getPlayerRoot(p)
            if r then table.insert(out, { player=p, root=r, dist=(myPos - r.Position).Magnitude }) end
        end
    end
    table.sort(out, function(a,b) return a.dist < b.dist end)
    return out
end

local function updateThreat(now)
    local myRoot = getRoot()
    if not myRoot then resetThreat(); return nil,nil,math.huge,false,0 end
    local killers = evaluateKillers()
    if #killers == 0 then
        if THREAT.confirmed then
            THREAT.clearStart = THREAT.clearStart or now
            if now - THREAT.clearStart > CONFIG.THREAT_CLEAR_TIME then
                log("Threat cleared: no killer")
                resetThreat()
            end
        end
        return nil,nil,math.huge,false,0
    end
    local primary = killers[1]
    local killerRoot = primary.root
    local features = perceiveThreat(now, killerRoot)
    local P = computeThreatProbability(features)
    if primary.dist <= CONFIG.THREAT_EMERGENCY_D then P = 1 end
    local tier = "none"
    if primary.dist <= CONFIG.THREAT_EMERGENCY_D then tier = "critical"
    elseif primary.dist <= CONFIG.THREAT_ENTER_DIST then tier = "danger"
    elseif primary.dist <= CONFIG.THREAT_WARNING_DIST then tier = "warning" end
    if not THREAT.confirmed and P >= CONFIG.THREAT_P_ENTER then
        THREAT.confirmed = true; THREAT.clearStart = nil
        log(string.format("Threat ENTER [%s]: d=%.1f P=%.2f", tier, primary.dist, P))
    end
    if THREAT.confirmed and P <= CONFIG.THREAT_P_EXIT then
        if primary.dist > CONFIG.THREAT_EXIT_DIST then
            THREAT.clearStart = THREAT.clearStart or now
            if now - THREAT.clearStart > CONFIG.THREAT_CLEAR_TIME then
                log(string.format("Threat EXIT: d=%.1f", primary.dist))
                resetThreat()
                return primary.player, killerRoot, primary.dist, false, 0
            end
        else THREAT.clearStart = nil end
    end
    THREAT.P = P; THREAT.level = tier
    THREAT.primary = primary.player; THREAT.primaryRoot = killerRoot
    THREAT.primaryDist = primary.dist
    return primary.player, killerRoot, primary.dist, THREAT.confirmed, P
end

-- ============================================================================
-- R6: PATHFOLLOWER — one stable path
-- ============================================================================
local PathFollower = {
    path = nil,
    goalPos = nil, goalTag = nil,
    waypoints = {}, index = 1,
    computing = false,
    pendingPos = nil, pendingTag = nil,
    lastMoveTo = nil,
    lastPos = nil, stuckSince = 0, lastStuckLog = 0,
    blockedConn = nil,
    failCount = 0, lastFailPos = nil, failCooldownUntil = 0,
}

local function initPath()
    if PathFollower.path then return end
    PathFollower.path = PathfindingService:CreatePath({
        AgentRadius = 2, AgentHeight = 5,
        AgentCanJump = true, AgentMaxSlope = 45,
        WaypointSpacing = 4,
    })
end

local function disconnectBlocked()
    if PathFollower.blockedConn then
        pcall(function() PathFollower.blockedConn:Disconnect() end)
        PathFollower.blockedConn = nil
    end
end

local function cancelGoal()
    PathFollower.goalPos = nil
    PathFollower.goalTag = nil
    PathFollower.waypoints = {}
    PathFollower.index = 1
    PathFollower.pendingPos = nil
    PathFollower.pendingTag = nil
    PathFollower.lastMoveTo = nil
    disconnectBlocked()
end

-- R6: set goal — only requests recompute if tag changed or pos moved > threshold
local function setGoal(pos, tag)
    if not pos then return end
    initPath()
    local tagChanged = PathFollower.goalTag ~= tag
    local posChanged = (not PathFollower.goalPos)
        or ((PathFollower.goalPos - pos).Magnitude > CONFIG.GOAL_REPATH_THRESH)
    if tagChanged or posChanged then
        PathFollower.pendingPos = pos
        PathFollower.pendingTag = tag
    end
end

local function computePending()
    local root = getRoot()
    if not root then return end
    local pos = PathFollower.pendingPos
    local tag = PathFollower.pendingTag
    if not pos then return end
    if PathFollower.lastFailPos
        and tick() < PathFollower.failCooldownUntil
        and (PathFollower.lastFailPos - pos).Magnitude < 5 then
        PathFollower.pendingPos = nil; PathFollower.pendingTag = nil
        return
    end
    PathFollower.computing = true
    PathFollower.pendingPos = nil
    PathFollower.pendingTag = nil
    nlog("Path compute → %s tag=%s", tostring(pos), tostring(tag))
    local ok = pcall(function() PathFollower.path:ComputeAsync(root.Position, pos) end)
    PathFollower.computing = false
    if ok and PathFollower.path.Status == Enum.PathStatus.Success then
        PathFollower.goalPos = pos
        PathFollower.goalTag = tag
        PathFollower.waypoints = PathFollower.path:GetWaypoints()
        PathFollower.index = 2
        PathFollower.stuckSince = 0
        PathFollower.failCount = 0
        PathFollower.lastMoveTo = nil
        disconnectBlocked()
        PathFollower.blockedConn = PathFollower.path.Blocked:Connect(function(idx)
            if idx >= (PathFollower.index or 1) then
                PathFollower.goalPos = nil
                nlog("Path blocked @%d → recompute", idx)
            end
        end)
    else
        PathFollower.failCount = PathFollower.failCount + 1
        PathFollower.lastFailPos = pos
        PathFollower.failCooldownUntil = tick() + math.min(1.0 * PathFollower.failCount, 5)
        log(string.format("Path fail (attempt %d): %s", PathFollower.failCount,
            tostring(PathFollower.path and PathFollower.path.Status)))
    end
end

-- R6: follow step. Recompute only on stuck >2s (with jump)
local function followStep()
    local root = getRoot()
    local hum = getHumanoid()
    if not root or not hum then return false end
    hum.WalkSpeed = CONFIG.BASE_WALKSPEED * CONFIG.WALKSPEED_FACTOR

    if PathFollower.pendingPos and not PathFollower.computing then computePending() end

    -- Stuck detection
    local now = tick()
    if PathFollower.lastPos then
        local moved = (root.Position - PathFollower.lastPos).Magnitude
        if moved < CONFIG.NAV_PROGRESS_EPS then
            PathFollower.stuckSince = (PathFollower.stuckSince == 0) and now or PathFollower.stuckSince
            if now - PathFollower.stuckSince > CONFIG.NAV_STUCK_TIME then
                if now - PathFollower.lastStuckLog > CONFIG.NAV_LOG_INTERVAL then
                    PathFollower.lastStuckLog = now
                    log("Path: stuck >2s → jump + recompute")
                end
                pcall(function() hum.Jump = true end)
                PathFollower.goalPos = nil
                PathFollower.stuckSince = 0
                PathFollower.index = 1
                if PathFollower.pendingPos == nil and PathFollower.goalPos == nil then
                    PathFollower.pendingPos = nil
                end
            end
        else
            PathFollower.stuckSince = 0
        end
    end
    PathFollower.lastPos = root.Position

    if #PathFollower.waypoints == 0 or PathFollower.index > #PathFollower.waypoints then
        if PathFollower.goalPos then hum:MoveTo(PathFollower.goalPos) end
        return true
    end

    local wp = PathFollower.waypoints[PathFollower.index]
    while wp and (root.Position - wp.Position).Magnitude < CONFIG.WAYPOINT_REACH_DIST do
        PathFollower.index = PathFollower.index + 1
        wp = PathFollower.waypoints[PathFollower.index]
    end
    if not wp then
        if PathFollower.goalPos then hum:MoveTo(PathFollower.goalPos) end
        return true
    end
    if wp.Action == Enum.PathWaypointAction.Jump then hum.Jump = true end
    hum:MoveTo(wp.Position)
    PathFollower.lastMoveTo = wp.Position
    return true
end

local function reachedGoal(threshold)
    local root = getRoot()
    if not root or not PathFollower.goalPos then return false end
    return (root.Position - PathFollower.goalPos).Magnitude <= (threshold or 5)
end

-- ============================================================================
-- tryPath (lightweight — used only for flee candidate validation)
-- ============================================================================
local PathMemo = {}
local function tryPath(fromPos, endPos)
    local k = tostring(fromPos).."→"..tostring(endPos)
    local cached = PathMemo[k]
    if cached and (tick() - cached.t) < CONFIG.PATH_CACHE_TTL then return cached.ok end
    local p = PathfindingService:CreatePath({
        AgentRadius = 2, AgentHeight = 5, AgentCanJump = true,
        AgentMaxSlope = 45, WaypointSpacing = 4,
    })
    local ok = pcall(function() p:ComputeAsync(fromPos, endPos) end)
    local success = ok and p.Status == Enum.PathStatus.Success
    PathMemo[k] = { t=tick(), ok=success }
    return success
end

-- ============================================================================
-- GENERATOR DISCOVERY
-- ============================================================================
local function getGameValue(obj, key)
    if not obj or not key then return nil end
    local ok,v = pcall(function() return obj:GetAttribute(key) end)
    if ok and v ~= nil then return v end
    local ch = obj:FindFirstChild(key)
    if ch and (ch:IsA("NumberValue") or ch:IsA("IntValue")) then return tonumber(ch.Value) end
    return nil
end

local function getGenProgress(gen)
    if not gen then return nil end
    return tonumber(getGameValue(gen, "RepairProgress") or getGameValue(gen, "Progress"))
end

local function updateGeneratorProgress(gen)
    if not gen or not gen.Parent then return true end
    local p = getGenProgress(gen)
    if p == nil then return false end
    return p >= 100
end

local function isValidGenerator(obj)
    if not obj or not obj.Parent then return false end
    for _,ch in ipairs(obj:GetChildren()) do
        if ch:IsA("BasePart") and ch.Name:match("^GeneratorPoint%d+$") then return true end
    end
    if obj:GetAttribute("RepairProgress") or obj:GetAttribute("Progress") then return true end
    return false
end

local GenRegistry = { container=nil, list={}, lastScan=0, lastCount=-1, lastReason="" }

local function scanContainerDirect()
    local map = workspace:FindFirstChild("Map")
    local paths = {
        map and map:FindFirstChild("Generators"),
        map and map:FindFirstChild("Generator"),
        workspace:FindFirstChild("Generators"),
        workspace:FindFirstChild("Generator"),
    }
    for _,c in ipairs(paths) do if c and c.Parent then return c, "known-path" end end
    return nil, nil
end

local function scanContainerRecursive()
    local function scan(root, depth)
        if depth > CONFIG.GEN_DISCOVERY_DEPTH or not root then return nil end
        for _,ch in ipairs(root:GetChildren()) do
            if ch:IsA("Folder") or ch:IsA("Model") then
                if ch.Name:lower():find("generator") then
                    for _,sub in ipairs(ch:GetChildren()) do
                        if isValidGenerator(sub) then return ch end
                    end
                end
                local f = scan(ch, depth+1)
                if f then return f end
            end
        end
        return nil
    end
    local f = scan(workspace, 0)
    return f, f and "recursive-scan" or nil
end

local function collectGeneratorsFrom(container)
    local out = {}
    local function scan(node, depth)
        if depth > CONFIG.GEN_DISCOVERY_DEPTH + 1 or not node then return end
        for _,ch in ipairs(node:GetChildren()) do
            if isValidGenerator(ch) then table.insert(out, ch)
            elseif ch:IsA("Folder") or ch:IsA("Model") then scan(ch, depth+1) end
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
    local c, reason = scanContainerDirect()
    if not c then c, reason = scanContainerRecursive() end
    if c then
        local list = collectGeneratorsFrom(c)
        GenRegistry.container = c; GenRegistry.list = list
        GenRegistry.lastScan = now; GenRegistry.lastReason = reason
        if GenRegistry.lastCount ~= #list then
            GenRegistry.lastCount = #list
            log(string.format("Generator container: %s (%s) → %d gens",
                c:GetFullName(), reason, #list))
        end
        return list, reason
    end
    if GenRegistry.lastCount ~= 0 then GenRegistry.lastCount = 0; log("Generator container: not found") end
    GenRegistry.container = nil; GenRegistry.list = {}; GenRegistry.lastScan = now
    GenRegistry.lastReason = "not-found"
    return {}, "not-found"
end

local function genApproachPoint(gen)
    if not gen then return nil end
    local myRoot = getRoot(); if not myRoot then return nil end
    local best, bestD = nil, math.huge
    for _,ch in ipairs(gen:GetChildren()) do
        if ch:IsA("BasePart") and ch.Name:match("^GeneratorPoint%d+$") then
            local d = (myRoot.Position - ch.Position).Magnitude
            if d < bestD then bestD, best = d, ch end
        end
    end
    if best then return best.Position end
    if gen:IsA("Model") and gen.PrimaryPart then return gen.PrimaryPart.Position end
    if gen:IsA("BasePart") then return gen.Position end
    for _,ch in ipairs(gen:GetChildren()) do
        if ch:IsA("BasePart") then return ch.Position end
    end
    return nil
end

-- ============================================================================
-- GEN SCORING
-- ============================================================================
local TargetBlacklist = {}
local function isTargetBlacklisted(pos)
    if not pos then return false end
    local key = string.format("%.1f|%.1f|%.1f", pos.X, pos.Y, pos.Z)
    local t = TargetBlacklist[key]
    if not t then return false end
    if tick() - t > CONFIG.PATH_FAIL_COOLDOWN then TargetBlacklist[key] = nil; return false end
    return true
end

local function scoreGenerator(gen, myRoot, killerPos)
    if not gen or not gen.Parent or not myRoot then return math.huge end
    if updateGeneratorProgress(gen) then return math.huge end
    local ap = genApproachPoint(gen); if not ap then return math.huge end
    if isTargetBlacklisted(ap) then return math.huge end
    local d = (myRoot.Position - ap).Magnitude
    if d > CONFIG.SURV_GEN_DETECT then return math.huge end
    local prog = getGenProgress(gen) or 0
    local score = d - prog * CONFIG.GEN_PROGRESS_WEIGHT
    if killerPos then
        local dK = (ap - killerPos).Magnitude
        if dK < CONFIG.GEN_KILLER_SAFE_DIST then
            score = score + (CONFIG.GEN_KILLER_SAFE_DIST - dK) * CONFIG.GEN_KILLER_PENALTY
        end
    end
    if Survivor and Survivor.failedGens[gen] and (tick() - Survivor.failedGens[gen]) < 8 then
        score = score + 1000
    end
    return score
end

local function findBestGenerator(myRoot, killerPos, excludedGen)
    if not myRoot then return nil, "no-root" end
    local list, reason = getGeneratorList()
    if #list == 0 then return nil, "list-empty ("..tostring(reason)..")" end
    local best, bestScore = nil, math.huge
    for _,gen in ipairs(list) do
        if gen.Parent and gen ~= excludedGen then
            local s = scoreGenerator(gen, myRoot, killerPos)
            if s < bestScore then bestScore = s; best = gen end
        end
    end
    if best then return best, string.format("score=%.1f", bestScore) end
    return nil, "no-candidate"
end

-- ============================================================================
-- FLEE TARGET
-- ============================================================================
local FLEE = { target=nil, lastPick=0, lastLog=0, lastFail=0,
               lastGen=nil, commitUntil=0, commitTarget=nil }

local function resetFlee()
    FLEE.target=nil; FLEE.lastPick=0; FLEE.lastLog=0; FLEE.lastFail=0
    FLEE.lastGen=nil; FLEE.commitUntil=0; FLEE.commitTarget=nil
end

local function pickSafeFleeGenerator(myPos, killerPos, exclude)
    local list = getGeneratorList(); if #list == 0 then return nil, nil end
    local best, bestPos, bestCost = nil, nil, math.huge
    for _,gen in ipairs(list) do
        if gen.Parent and gen ~= exclude and not updateGeneratorProgress(gen) then
            local ap = genApproachPoint(gen)
            if ap and not isTargetBlacklisted(ap) then
                local dAI = (myPos - ap).Magnitude
                if dAI <= CONFIG.FLEE_SAFE_GEN_MAX and tryPath(myPos, ap) then
                    local prog = getGenProgress(gen) or 0
                    local c = CONFIG.ROUTE_W.w_length * clamp(dAI*1.15/CONFIG.ROUTE_REF_LEN,0,2)
                    if killerPos then
                        local dE = (ap - killerPos).Magnitude
                        c = c + CONFIG.ROUTE_W.w_exposure * clamp(1 - dE/CONFIG.GEN_KILLER_SAFE_DIST,0,1)
                        c = c - CONFIG.ROUTE_W.w_safety * clamp(dE/CONFIG.FLEE_MIN_DIST_KILLER,0,1)
                    end
                    c = c - prog * 0.002
                    if c < bestCost then bestCost = c; best = gen; bestPos = ap end
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
    local dK = (myPos - killerPos).Magnitude

    if FLEE.target and FLEE.commitTarget == FLEE.target then
        local reached = (myPos - FLEE.target).Magnitude < CONFIG.FLEE_REACHED_RADIUS
        local danger = (FLEE.target - killerPos).Magnitude < dK
        local commitActive = now < FLEE.commitUntil
        local repickReady = (now - FLEE.lastPick) >= CONFIG.FLEE_REPICK_INTERVAL
        if not reached and not danger and (commitActive or not repickReady) then
            return FLEE.target
        end
    end

    if dK < CONFIG.THREAT_EMERGENCY_D then
        local away = Vector3.new(myPos.X - killerPos.X, 0, myPos.Z - killerPos.Z)
        if away.Magnitude < 0.01 then away = Vector3.new(1,0,0) end
        local tgt = myPos + away.Unit * CONFIG.FLEE_DISTANCE
        FLEE.target=tgt; FLEE.lastPick=now; FLEE.commitTarget=tgt
        FLEE.commitUntil = now + CONFIG.FLEE_COMMIT_TIME
        return tgt
    end

    local safeGen, safePos = pickSafeFleeGenerator(myPos, killerPos, Survivor.targetGen)
    if safeGen and safePos then
        FLEE.target=safePos; FLEE.lastPick=now; FLEE.lastGen=safeGen
        FLEE.commitTarget=safePos; FLEE.commitUntil = now + CONFIG.FLEE_COMMIT_TIME
        return safePos
    end

    local away = Vector3.new(myPos.X - killerPos.X, 0, myPos.Z - killerPos.Z)
    if away.Magnitude < 0.01 then away = Vector3.new(1,0,0) end
    away = away.Unit
    local angles = {0, 45, -45, 90, -90, 135, -135, 180}
    local distances = {CONFIG.FLEE_DISTANCE, CONFIG.FLEE_DISTANCE*0.7}
    for _,d in ipairs(distances) do
        for _,deg in ipairs(angles) do
            local dir = rotateAroundY(away, math.rad(deg))
            local endPos = myPos + dir * d
            if (endPos - killerPos).Magnitude >= CONFIG.FLEE_MIN_DIST_KILLER
                and hasClearLine(myPos, endPos) and tryPath(myPos, endPos) then
                FLEE.target=endPos; FLEE.lastPick=now; FLEE.commitTarget=endPos
                FLEE.commitUntil = now + CONFIG.FLEE_COMMIT_TIME
                return endPos
            end
        end
    end
    local fb = myPos + away * 22
    FLEE.target=fb; FLEE.lastPick=now; FLEE.commitTarget=fb
    FLEE.commitUntil = now + CONFIG.FLEE_COMMIT_TIME
    return fb
end

-- ============================================================================
-- R9: RESCUE / HEAL TARGETS
-- ============================================================================
local function findHookedTarget()
    local myRoot = getRoot(); if not myRoot then return nil end
    local best, bestD = nil, math.huge
    for _,p in ipairs(Players:GetPlayers()) do
        if p ~= localPlayer and roleOfPlayer(p) == "Survivor"
            and getSurvivorState(p) == "hooked" then
            local r = getPlayerRoot(p)
            if r then
                local d = (myRoot.Position - r.Position).Magnitude
                if d < bestD and d <= CONFIG.RESCUE_DETECT_RANGE then
                    bestD = d; best = { player=p, root=r }
                end
            end
        end
    end
    return best, bestD
end

local function findHealTarget()
    local myRoot = getRoot(); if not myRoot then return nil end
    local best, bestD = nil, math.huge
    for _,p in ipairs(Players:GetPlayers()) do
        if p ~= localPlayer and roleOfPlayer(p) == "Survivor" then
            local st = getSurvivorState(p)
            if st == "knocked" or st == "canBeHealed" then
                local r = getPlayerRoot(p)
                if r then
                    local d = (myRoot.Position - r.Position).Magnitude
                    if d < bestD and d <= CONFIG.RESCUE_DETECT_RANGE then
                        bestD = d; best = { player=p, root=r, state=st }
                    end
                end
            end
        end
    end
    return best, bestD
end

-- ============================================================================
-- SURVIVOR AI
-- ============================================================================
Survivor = {
    State = "WaitingForCharacter",
    targetGen = nil, approachPos = nil,
    lastGenScan = 0, lastProgress = nil, lastProgressT = 0,
    failedGens = {},
    lastLoggedGen = nil, lastNoGenLog = 0,
    lastStateLog = 0, lastSearchLog = 0, lastSwitchT = 0,
    searchStateSince = 0, lastSearchDiag = 0,
}

local function survivorReset()
    Survivor.State = "WaitingForCharacter"
    Survivor.targetGen = nil; Survivor.approachPos = nil
    Survivor.lastGenScan = 0; Survivor.lastProgress = nil; Survivor.lastProgressT = 0
    Survivor.failedGens = {}
    Survivor.lastLoggedGen = nil; Survivor.lastNoGenLog = 0
    Survivor.lastSearchLog = 0; Survivor.lastSwitchT = 0
    Survivor.searchStateSince = 0; Survivor.lastSearchDiag = 0
    cancelGoal(); resetFlee(); resetThreat(); resetPerception()
    notifyRepairEnded(); releaseShift(); endHoldAction()
end

local function setSurvivorState(newState, now, extra)
    if Survivor.State ~= newState then
        log(string.format("Survivor: %s → %s %s", Survivor.State, newState, extra or ""))
        Survivor.lastStateLog = now
        Survivor.State = newState
        if newState ~= "SearchingGenerator" then Survivor.searchStateSince = 0 end
    end
end

local function survivorPickGenerator(now, killerPos, exclude)
    local myRoot = getRoot(); if not myRoot then return false end
    local current = Survivor.targetGen
    local currentValid = current and current.Parent and not updateGeneratorProgress(current)
    local currentScore = currentValid and scoreGenerator(current, myRoot, killerPos) or math.huge
    local currentBl = currentValid and isTargetBlacklisted(genApproachPoint(current) or Vector3.zero)

    if currentValid and currentScore < math.huge and not currentBl then
        if (now - Survivor.lastSwitchT) > CONFIG.GEN_RESCAN_COOLDOWN then
            local newGen = findBestGenerator(myRoot, killerPos, exclude)
            if newGen and newGen ~= current then
                local ns = scoreGenerator(newGen, myRoot, killerPos)
                if ns < currentScore - CONFIG.GEN_SWITCH_MARGIN then
                    Survivor.targetGen = newGen
                    Survivor.approachPos = genApproachPoint(newGen)
                    Survivor.lastSwitchT = now
                    log(string.format("Survivor: switch → %s (Δ=%.1f)",
                        newGen:GetFullName(), currentScore - ns))
                    return true
                end
            end
        end
        Survivor.approachPos = genApproachPoint(current)
        Survivor.lastGenScan = now
        if Survivor.lastLoggedGen ~= current then
            Survivor.lastLoggedGen = current
            log("Survivor: retain "..current:GetFullName())
        end
        return true
    end

    local g, reason = findBestGenerator(myRoot, killerPos, exclude)
    if not g then
        if currentValid then
            Survivor.approachPos = genApproachPoint(current)
            Survivor.lastGenScan = now
            if now - Survivor.lastNoGenLog > 3 then
                Survivor.lastNoGenLog = now
                log(string.format("Survivor: pick fail (%s) → retain %s",
                    tostring(reason), current:GetFullName()))
            end
            return true
        end
        if now - Survivor.lastNoGenLog > 3 then
            Survivor.lastNoGenLog = now
            log("Survivor: no gen | "..tostring(reason))
        end
        return false
    end

    Survivor.targetGen = g
    Survivor.approachPos = genApproachPoint(g)
    Survivor.lastGenScan = now
    Survivor.lastProgress = getGenProgress(g)
    Survivor.lastProgressT = now
    Survivor.lastSwitchT = now
    if Survivor.lastLoggedGen ~= g then
        Survivor.lastLoggedGen = g
        log(string.format("Survivor: picked %s (%s)", g:GetFullName(), reason))
    end
    return true
end

local function SurvivorAI(now)
    local hum = getHumanoid()
    local root = getRoot()
    if not hum or not root or hum.Health <= 0 then
        Survivor.State = "WaitingForCharacter"
        notifyRepairEnded(); releaseShift(); endHoldAction(); cancelGoal()
        return
    end

    -- R11: SELF STATE early return
    local selfState = getSelfState()
    if selfState == "dead" then
        setSurvivorState("Dead", now)
        endHoldAction(); releaseShift(); cancelGoal()
        return
    end
    if selfState == "hooked" then
        setSurvivorState("Hooked", now)
        endHoldAction(); releaseShift(); cancelGoal()
        return
    end
    if selfState == "carried" then
        setSurvivorState("Carried", now)
        endHoldAction(); releaseShift(); cancelGoal()
        return
    end
    if selfState == "knocked" then
        -- stay still + hold action (self-heal)
        setSurvivorState("SelfHealing", now)
        releaseShift(); cancelGoal()
        hum:Move(Vector3.zero, false)
        beginHoldAction()
        return
    end

    -- Threat check
    local killer, killerRoot, kD, threat, P = updateThreat(now)
    if threat and killerRoot then
        -- R10: stop repair FIRST before fleeing
        if Survivor.State == "RepairingGenerator" or Repair.active then
            endHoldAction()
            fireGenDone()
            notifyRepairEnded()
            log("Survivor: interrupted repair → flee")
        end
        setSurvivorState("EvadingKiller", now, string.format("(d=%.1f P=%.2f)", kD, P or 0))
        releaseShift()
        local fleeTarget = pickFleeTarget(root, killerRoot)
        holdShift()
        setGoal(fleeTarget, "flee")
        followStep()
        return
    end

    -- leaving evade
    if Survivor.State == "EvadingKiller" then
        log("Survivor: evade done → resume")
        endHoldAction(); releaseShift()
        cancelGoal(); resetFlee()
    end

    -- R9: RESCUE priority (killer >50 stud dari hooked)
    do
        local rt, rd = findHookedTarget()
        if rt then
            local kDist = killerRoot and (rt.root.Position - killerRoot.Position).Magnitude or math.huge
            if kDist > CONFIG.RESCUE_SAFE_DIST then
                setSurvivorState("RescuingSurvivor", now, string.format("(d=%.1f)", rd))
                holdShift()
                if rd <= CONFIG.RESCUE_ACTION_R then
                    hum:Move(Vector3.zero, false)
                    cancelGoal()
                    beginHoldAction()
                else
                    endHoldAction()
                    setGoal(rt.root.Position, "rescue")
                    followStep()
                end
                return
            end
        end
    end

    -- R9: HEAL priority (killer >50 stud dari target)
    do
        local ht, hd = findHealTarget()
        if ht then
            local kDist = killerRoot and (ht.root.Position - killerRoot.Position).Magnitude or math.huge
            if kDist > CONFIG.RESCUE_SAFE_DIST then
                setSurvivorState("HealingSurvivor", now, string.format("(d=%.1f)", hd))
                holdShift()
                if hd <= CONFIG.RESCUE_ACTION_R then
                    hum:Move(Vector3.zero, false)
                    cancelGoal()
                    beginHoldAction()
                else
                    endHoldAction()
                    setGoal(ht.root.Position, "heal")
                    followStep()
                end
                return
            end
        end
    end

    -- ================== DEFAULT: GENERATOR REPAIR ==================
    if Survivor.State == "AllDone" then
        if now - Survivor.lastGenScan > 3 then
            Survivor.lastGenScan = now
            if findBestGenerator(root, nil) then
                Survivor.State = "SearchingGenerator"
                Survivor.lastLoggedGen = nil
            end
        end
        notifyRepairEnded(); releaseShift(); endHoldAction(); cancelGoal()
        return
    end

    -- R4: search watchdog
    if Survivor.State == "SearchingGenerator" then
        Survivor.searchStateSince = (Survivor.searchStateSince == 0) and now or Survivor.searchStateSince
        if now - Survivor.searchStateSince > CONFIG.SEARCH_STUCK_LOG
            and now - Survivor.lastSearchDiag > CONFIG.SEARCH_STUCK_LOG then
            Survivor.lastSearchDiag = now
            local list, reason = getGeneratorList()
            log(string.format("[SearchDiag] %.1fs | list=%d reason=%s",
                now - Survivor.searchStateSince, #list, tostring(reason)))
        end
    end

    local targetLost = (not Survivor.targetGen or not Survivor.targetGen.Parent)
    local targetComplete = Survivor.targetGen and updateGeneratorProgress(Survivor.targetGen)

    if Survivor.State == "SearchingGenerator" or targetLost or targetComplete
        or not Survivor.targetGen then
        local killers = evaluateKillers()
        local killerPos = (#killers > 0) and killers[1].root and killers[1].root.Position or nil
        if not survivorPickGenerator(now, killerPos, nil) then
            local list = getGeneratorList()
            local anyLeft = false
            for _,gg in ipairs(list) do
                if not updateGeneratorProgress(gg) then anyLeft = true; break end
            end
            if not anyLeft and #list > 0 then
                setSurvivorState("AllDone", now)
                cancelGoal(); endHoldAction()
                notifyRepairEnded(); releaseShift()
            else
                setSurvivorState("SearchingGenerator", now)
                cancelGoal(); endHoldAction()
                notifyRepairEnded(); releaseShift()
            end
            return
        end
        setSurvivorState("MovingToGenerator", now)
    end

    local gen = Survivor.targetGen
    if not gen or not gen.Parent then
        setSurvivorState("SearchingGenerator", now)
        cancelGoal(); return
    end

    local prog = getGenProgress(gen)
    if prog and prog >= 100 then
        setSurvivorState("SearchingGenerator", now)
        cancelGoal(); endHoldAction()
        return
    end

    local ap = Survivor.approachPos or genApproachPoint(gen)
    if not ap then setSurvivorState("SearchingGenerator", now); return end
    Survivor.approachPos = ap

    local d = (root.Position - ap).Magnitude
    if d <= CONFIG.SURV_GEN_ACTION_R then
        -- At generator → HOLD action to repair
        if Survivor.State ~= "RepairingGenerator" then
            setSurvivorState("RepairingGenerator", now)
            Survivor.lastProgress = getGenProgress(gen)
            Survivor.lastProgressT = now
            notifyRepairStarted()
            cancelGoal()
        end
        hum:Move(Vector3.zero, false)
        releaseShift()
        beginHoldAction()
        local cur = getGenProgress(gen)
        if cur and Survivor.lastProgress and cur > Survivor.lastProgress then
            Survivor.lastProgress = cur
            Survivor.lastProgressT = now
        end
        if now - Survivor.lastProgressT > CONFIG.SURV_GEN_NO_PROGRESS then
            log("Survivor: gen no progress → abandon")
            Survivor.failedGens[gen] = now
            setSurvivorState("SearchingGenerator", now)
            Survivor.lastGenScan = 0; Survivor.lastLoggedGen = nil
            endHoldAction(); notifyRepairEnded(); cancelGoal()
        end
    else
        setSurvivorState("MovingToGenerator", now, string.format("(d=%.1f)", d))
        notifyRepairEnded()
        endHoldAction()
        holdShift()
        setGoal(ap, "gen")
        followStep()
    end
end

-- ============================================================================
-- KILLER AI
-- ============================================================================
local Killer = { State="WaitingForCharacter", target=nil, targetPlayer=nil,
                 hitCount={}, lastHitT=0, lastCheck=0 }

local function killerReset()
    Killer.State="WaitingForCharacter"; Killer.target=nil; Killer.targetPlayer=nil
    Killer.hitCount={}; Killer.lastHitT=0; Killer.lastCheck=0
    cancelGoal(); releaseShift(); endHoldAction()
end

local function findNearestSurvivor(maxDist)
    maxDist = maxDist or CONFIG.KILLER_DETECT_RANGE
    local myRoot = getRoot(); if not myRoot then return nil, math.huge end
    local best, bestD = nil, maxDist
    for _,p in ipairs(Players:GetPlayers()) do
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
        Killer.State = "WaitingForCharacter"; return
    end
    if now - Killer.lastCheck > CONFIG.KILLER_TARGET_RECHECK then
        Killer.lastCheck = now
        local t = Killer.target
        local tHum = t and t.Parent and t.Parent:FindFirstChildOfClass("Humanoid")
        if not (tHum and tHum.Health > 0) then
            local p = findNearestSurvivor(CONFIG.KILLER_DETECT_RANGE)
            Killer.targetPlayer = p
            Killer.target = p and getPlayerRoot(p) or nil
        end
    end
    local target = Killer.target
    if not target or not target.Parent then
        Killer.State = "Idle"
        cancelGoal(); hum:Move(Vector3.zero, false)
        return
    end
    local d = dist(root, target)
    if d <= CONFIG.KILLER_HIT_RANGE + CONFIG.KILLER_HIT_TOL then
        if Killer.State ~= "Attacking" then
            log(string.format("Killer ATTACK d=%.1f", d)); Killer.State = "Attacking"
        end
        cancelGoal(); hum:Move(Vector3.zero, false)
        local uid = Killer.targetPlayer and Killer.targetPlayer.UserId or 0
        local hits = Killer.hitCount[uid] or 0
        if hits < CONFIG.KILLER_MAX_HITS and (now - Killer.lastHitT) > CONFIG.KILLER_HIT_COOLDOWN then
            Killer.lastHitT = now
            Killer.hitCount[uid] = hits + 1
            tapAction()
        end
        if (Killer.hitCount[uid] or 0) >= CONFIG.KILLER_MAX_HITS then
            Killer.target=nil; Killer.targetPlayer=nil; Killer.State="Idle"
        end
    else
        if Killer.State ~= "Chasing" then
            log(string.format("Killer CHASE d=%.1f", d)); Killer.State = "Chasing"
        end
        setGoal(target.Position, "chase")
        followStep()
    end
end

-- ============================================================================
-- GUI
-- ============================================================================
local readyGui, readyLabel = nil, nil

local function createReadyGui()
    if readyGui and readyGui.Parent then pcall(function() readyGui:Destroy() end) end
    local pg = localPlayer:FindFirstChild("PlayerGui"); if not pg then return end
    readyGui = Instance.new("ScreenGui")
    readyGui.Name = "KemiAI_Ready"
    readyGui.ResetOnSpawn = false
    readyGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    readyGui.IgnoreGuiInset = true
    readyGui.Parent = pg
    readyLabel = Instance.new("TextLabel")
    readyLabel.AnchorPoint = Vector2.new(0,1)
    readyLabel.Position = UDim2.new(0,14,1,-14)
    readyLabel.Size = UDim2.new(0,520,0,18)
    readyLabel.BackgroundTransparency = 1
    readyLabel.Text = "AI ready [waiting]"
    readyLabel.TextColor3 = Color3.fromRGB(0,255,120)
    readyLabel.TextStrokeTransparency = 0.4
    readyLabel.TextStrokeColor3 = Color3.fromRGB(0,0,0)
    readyLabel.Font = Enum.Font.GothamBold
    readyLabel.TextSize = 14
    readyLabel.TextXAlignment = Enum.TextXAlignment.Left
    readyLabel.Parent = readyGui
end

local function ensureGuiAlive()
    local pg = localPlayer:FindFirstChild("PlayerGui"); if not pg then return end
    if readyGui and readyGui.Parent == pg and readyLabel and readyLabel.Parent == readyGui then return end
    log("GUI missing → recreate"); createReadyGui()
end

createReadyGui()

-- ============================================================================
-- ROLE WATCHER
-- ============================================================================
local currentRole = nil
local roleWatcherConnection = nil
local lastGuiCheck = 0

local function onRoleChange(old, new)
    log(string.format("Role: %s → %s", tostring(old), tostring(new)))
    survivorReset(); killerReset(); resetThreat()
    if new == "Spectator" then endHoldAction(); releaseShift(); cancelGoal() end
end

local function startRoleWatcher()
    if roleWatcherConnection then return end
    roleWatcherConnection = RunService.Heartbeat:Connect(function()
        local now = tick()
        if now - lastGuiCheck > CONFIG.GUI_CHECK_INTERVAL then
            lastGuiCheck = now; ensureGuiAlive()
        end
        local role = getCurrentRole()
        if role ~= currentRole then
            local old = currentRole; currentRole = role
            onRoleChange(old, role)
        end
        if readyLabel and readyLabel.Parent then
            local extra = ""
            if role == "Survivor" then extra = string.format(" [%s]", Survivor.State)
            elseif role == "Killer" then extra = string.format(" [%s]", Killer.State) end
            readyLabel.Text = "AI ready ["..tostring(role).."]"..extra
        end
        local hum = getHumanoid()
        if not hum or hum.Health <= 0 then
            notifyRepairEnded(); releaseShift(); endHoldAction(); cancelGoal(); return
        end
        if role == "Survivor" then
            local ok, err = pcall(SurvivorAI, now)
            if not ok then log("SurvivorAI error:", err) end
        elseif role == "Killer" then
            local ok, err = pcall(KillerAI, now)
            if not ok then log("KillerAI error:", err) end
        else
            endHoldAction(); releaseShift(); cancelGoal()
        end
    end)
    log("Role watcher started")
end

startRoleWatcher()

-- ============================================================================
-- LIFECYCLE
-- ============================================================================
localPlayer.CharacterAdded:Connect(function()
    log("CharacterAdded: reset")
    survivorReset(); killerReset(); resetThreat()
    notifyRepairEnded(); endHoldAction()
    ensureGuiAlive()
end)

localPlayer.CharacterRemoving:Connect(function()
    notifyRepairEnded(); releaseShift(); endHoldAction(); cancelGoal()
end)

-- ============================================================================
-- KILL SWITCH
-- ============================================================================
_G.KemiAI_Stop = function()
    if roleWatcherConnection then roleWatcherConnection:Disconnect(); roleWatcherConnection = nil end
    notifyRepairEnded(); releaseShift(); endHoldAction(); cancelGoal()
    resetThreat(); resetFlee(); resetPerception()
    if readyGui then pcall(function() readyGui:Destroy() end); readyGui=nil; readyLabel=nil end
    log("Stopped")
end

log("AI ready — R6 stable single-path + survivor states loaded")