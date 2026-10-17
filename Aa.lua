-- ============================================================================
-- KEMI // PLAY AI — R7 (Generator Interaction + Chase State Fix)
--
-- Perubahan R14–R24 vs R6:
--   R14 GeneratorPoint awareness (1–4 slot per generator, cek slot kosong)
--   R15 genApproachPoint pilih slot kosong terdekat
--   R16 scoreGenerator tolak gen tanpa slot kosong
--   R17 Repair = holdShift() (bukan touch-hold)
--   R18 Repair session tracking + GenDone sekali per sesi
--   R19 Chase clear tegas (dist > EXIT_DIST ATAU P ≤ P_EXIT selama CLEAR_TIME)
--   R20 Post-chase fresh scan (target lama di-invalidate)
--   R21 Verify slot masih kosong saat repair
--   R22 Gen complete saat repair → releaseShift tanpa GenDone
--   R23 Debug log [Gen]/[Chase]/[Repair]
--   R24 State names diperjelas
--
-- Single PathFollower tetap: repath hanya jika tag berubah / goal geser >8 stud
-- / Path.Blocked / stuck >2s.
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
local function glog(fmt, ...) if CONFIG and CONFIG.DEBUG then print("[Gen]", string.format(fmt, ...)) end end
local function clog(fmt, ...) if CONFIG and CONFIG.DEBUG then print("[Chase]", string.format(fmt, ...)) end end
local function rlog(fmt, ...) if CONFIG and CONFIG.DEBUG then print("[Repair]", string.format(fmt, ...)) end end

-- ============================================================================
-- CONFIG
-- ============================================================================
local CONFIG = {
    DEBUG                = false,
    DEBUG_NAV            = false,

    BASE_WALKSPEED       = 16,
    WALKSPEED_FACTOR     = 1.1,

    KILLER_DETECT_RANGE  = 300,
    KILLER_HIT_RANGE     = 6,
    KILLER_HIT_TOL       = 1,
    KILLER_MAX_HITS      = 2,
    KILLER_HIT_COOLDOWN  = 1.2,
    KILLER_TARGET_RECHECK= 0.5,

    SURV_GEN_DETECT      = 10000,
    SURV_GEN_ACTION_R    = 5,
    SURV_GEN_NO_PROGRESS = 3.0,
    SURV_STUCK_WATCHDOG  = 10.0,
    SEARCH_STUCK_LOG     = 5.0,

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

    FLEE_DISTANCE        = 45,
    FLEE_MIN_DIST_KILLER = 40,
    FLEE_REPICK_INTERVAL = 1.5,
    FLEE_COMMIT_TIME     = 0.8,
    FLEE_REACHED_RADIUS  = 6,
    FLEE_SAFE_GEN_MAX    = 220,

    WAYPOINT_REACH_DIST  = 4.5,
    WAYPOINT_SKIP_DIST   = 5.0,
    GOAL_REPATH_THRESH   = 8.0,
    PATH_FAIL_COOLDOWN   = 10,
    PATH_CACHE_TTL       = 2.0,

    NAV_STUCK_TIME       = 2.0,
    NAV_PROGRESS_EPS     = 0.5,
    NAV_LOG_INTERVAL     = 2.0,

    RESCUE_DETECT_RANGE  = 10000,
    RESCUE_SAFE_DIST     = 50,
    RESCUE_ACTION_R      = 5,

    RAYCAST_DIST         = 12,
    GUI_CHECK_INTERVAL   = 2.0,

    GEN_SWITCH_MARGIN    = 25,
    GEN_RESCAN_COOLDOWN  = 4.0,
    GEN_PROGRESS_WEIGHT  = 0.6,
    GEN_KILLER_SAFE_DIST = 60,
    GEN_KILLER_PENALTY   = 8,
    GEN_DISCOVERY_DEPTH  = 3,
    GEN_CACHE_TTL        = 3,
    GEN_POINT_OCCUPIED_RADIUS = 4.0,   -- R14: studs

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

    SKILLCHECK_URL = "https://raw.githubusercontent.com/saldycatur-jpg/Itdyifitxitxiyxyioyyoxyiciyxtoohxo/refs/heads/main/Sk.lua",
}

local config = _G.config
if type(config) ~= "table" then config = {} end
if config.autoSkillCheckEnabled == nil then config.autoSkillCheckEnabled = true end

local function nlog(fmt, ...) if CONFIG.DEBUG_NAV then print("[KemiAI-nav]", string.format(fmt, ...)) end end

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

local function fireGenDone()
    local rem = getGenDoneRemote()
    if not rem then rlog("GenDone remote not found"); return end
    local ok, err = pcall(function()
        if rem:IsA("RemoteEvent") then rem:FireServer()
        elseif rem:IsA("BindableEvent") then rem:Fire() end
    end)
    if ok then rlog("GenDone fired") else rlog("GenDone error: %s", tostring(err)) end
end

-- R18: Repair session tracking
local Repair = { active = false, sessionId = 0, firedForSession = 0 }

local function beginRepairSession()
    Repair.active = true
    Repair.sessionId = Repair.sessionId + 1
    rlog("session %d begin", Repair.sessionId)
end

local function endRepairSession(sendGenDone)
    if not Repair.active then return end
    Repair.active = false
    if sendGenDone and Repair.firedForSession ~= Repair.sessionId then
        Repair.firedForSession = Repair.sessionId
        fireGenDone()
    end
    rlog("session %d end (sendGenDone=%s)", Repair.sessionId, tostring(sendGenDone))
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
-- SHIFT (repair = hold; sprint = hold; release = stop both)
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
-- ACTION BUTTON (tap + hold touch) — for heal / unhook / attack / self-heal
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
    ActionHold.active = false; ActionHold.pos = nil
    pcall(function() VirtualInputManager:SendTouchEvent(CONFIG.HOLD_ID, 2, p.x, p.y) end)
end
local function beginHoldAction()
    if ActionHold.active then return true end
    local b = GetActionTarget()
    if not b then return false end
    local cx, cy = getScreenPos(b)
    ActionHold.active = true; ActionHold.pos = {x=cx, y=cy}
    pcall(function() VirtualInputManager:SendTouchEvent(CONFIG.HOLD_ID, 0, cx, cy) end)
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
                 primary=nil, primaryRoot=nil, primaryDist=math.huge }

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

-- R19: chase clear lebih tegas (dist > EXIT_DIST atau P <= P_EXIT selama CLEAR_TIME)
local function updateThreat(now)
    local myRoot = getRoot()
    if not myRoot then resetThreat(); return nil,nil,math.huge,false,0 end
    local killers = evaluateKillers()
    if #killers == 0 then
        if THREAT.confirmed then
            THREAT.clearStart = THREAT.clearStart or now
            if now - THREAT.clearStart > CONFIG.THREAT_CLEAR_TIME then
                clog("EXIT: no killer")
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
        clog("ENTER [%s] d=%.1f P=%.2f", tier, primary.dist, P)
    end

    if THREAT.confirmed then
        local farEnough = primary.dist > CONFIG.THREAT_EXIT_DIST
        local safeP = P <= CONFIG.THREAT_P_EXIT
        if farEnough or safeP then
            THREAT.clearStart = THREAT.clearStart or now
            if now - THREAT.clearStart > CONFIG.THREAT_CLEAR_TIME then
                clog("EXIT d=%.1f P=%.2f far=%s safeP=%s",
                    primary.dist, P, tostring(farEnough), tostring(safeP))
                resetThreat()
                return primary.player, killerRoot, primary.dist, false, 0
            end
        else
            THREAT.clearStart = nil
        end
    end

    THREAT.P = P; THREAT.level = tier
    THREAT.primary = primary.player; THREAT.primaryRoot = killerRoot
    THREAT.primaryDist = primary.dist
    return primary.player, killerRoot, primary.dist, THREAT.confirmed, P
end

-- ============================================================================
-- R6: PATHFOLLOWER (single path)
-- ============================================================================
local PathFollower = {
    path = nil, goalPos = nil, goalTag = nil,
    waypoints = {}, index = 1, computing = false,
    pendingPos = nil, pendingTag = nil, lastMoveTo = nil,
    lastPos = nil, stuckSince = 0, lastStuckLog = 0,
    blockedConn = nil, failCount = 0,
    lastFailPos = nil, failCooldownUntil = 0,
}

local function initPath()
    if PathFollower.path then return end
    PathFollower.path = PathfindingService:CreatePath({
        AgentRadius = 2, AgentHeight = 5, AgentCanJump = true,
        AgentMaxSlope = 45, WaypointSpacing = 4,
    })
end

local function disconnectBlocked()
    if PathFollower.blockedConn then
        pcall(function() PathFollower.blockedConn:Disconnect() end)
        PathFollower.blockedConn = nil
    end
end

local function cancelGoal()
    PathFollower.goalPos = nil; PathFollower.goalTag = nil
    PathFollower.waypoints = {}; PathFollower.index = 1
    PathFollower.pendingPos = nil; PathFollower.pendingTag = nil
    PathFollower.lastMoveTo = nil
    disconnectBlocked()
end

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
    local root = getRoot(); if not root then return end
    local pos = PathFollower.pendingPos
    local tag = PathFollower.pendingTag
    if not pos then return end
    if PathFollower.lastFailPos and tick() < PathFollower.failCooldownUntil
        and (PathFollower.lastFailPos - pos).Magnitude < 5 then
        PathFollower.pendingPos = nil; PathFollower.pendingTag = nil
        return
    end
    PathFollower.computing = true
    PathFollower.pendingPos = nil; PathFollower.pendingTag = nil
    nlog("compute tag=%s pos=%s", tostring(tag), tostring(pos))
    local ok = pcall(function() PathFollower.path:ComputeAsync(root.Position, pos) end)
    PathFollower.computing = false
    if ok and PathFollower.path.Status == Enum.PathStatus.Success then
        PathFollower.goalPos = pos; PathFollower.goalTag = tag
        PathFollower.waypoints = PathFollower.path:GetWaypoints()
        PathFollower.index = 2; PathFollower.stuckSince = 0
        PathFollower.failCount = 0; PathFollower.lastMoveTo = nil
        disconnectBlocked()
        PathFollower.blockedConn = PathFollower.path.Blocked:Connect(function(idx)
            if idx >= (PathFollower.index or 1) then
                PathFollower.goalPos = nil
                nlog("blocked @%d → recompute", idx)
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

local function followStep()
    local root = getRoot(); local hum = getHumanoid()
    if not root or not hum then return false end
    hum.WalkSpeed = CONFIG.BASE_WALKSPEED * CONFIG.WALKSPEED_FACTOR

    if PathFollower.pendingPos and not PathFollower.computing then computePending() end

    local now = tick()
    if PathFollower.lastPos then
        local moved = (root.Position - PathFollower.lastPos).Magnitude
        if moved < CONFIG.NAV_PROGRESS_EPS then
            PathFollower.stuckSince = (PathFollower.stuckSince == 0) and now or PathFollower.stuckSince
            if now - PathFollower.stuckSince > CONFIG.NAV_STUCK_TIME then
                if now - PathFollower.lastStuckLog > CONFIG.NAV_LOG_INTERVAL then
                    PathFollower.lastStuckLog = now
                    log("Path stuck >2s → jump + recompute")
                end
                pcall(function() hum.Jump = true end)
                PathFollower.goalPos = nil; PathFollower.stuckSince = 0; PathFollower.index = 1
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

-- ============================================================================
-- tryPath (only for flee candidate validation)
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
-- GENERATOR DISCOVERY + R14 POINT AWARENESS
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

local function isGeneratorCompleted(gen)
    if not gen or not gen.Parent then return true end
    local p = getGenProgress(gen)
    if p == nil then return false end
    return p >= 100
end

-- R14: collect GeneratorPoint1..N (N = 1..4, never assume 4)
local function getGeneratorPoints(gen)
    local out = {}
    if not gen then return out end
    for _, ch in ipairs(gen:GetChildren()) do
        if ch:IsA("BasePart") and ch.Name:match("^GeneratorPoint%d+$") then
            table.insert(out, ch)
        end
    end
    table.sort(out, function(a,b) return a.Name < b.Name end)
    return out
end

-- R14: slot occupancy — multiple detection methods
local function isGeneratorPointOccupied(point)
    if not point or not point.Parent then return true, "invalid" end

    -- Method 1: explicit attributes on the point
    if point:GetAttribute("Occupied") == true then return true, "attr-Occupied" end
    if point:GetAttribute("Survivor") ~= nil then return true, "attr-Survivor" end
    if point:GetAttribute("Occupant") ~= nil then return true, "attr-Occupant" end

    -- Method 2: ObjectValue child pointing to a character
    for _, ch in ipairs(point:GetChildren()) do
        if ch:IsA("ObjectValue") and ch.Value then return true, "objvalue" end
    end

    -- Method 3: nearby survivor (excluding self)
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= localPlayer and roleOfPlayer(p) == "Survivor" then
            local r = getPlayerRoot(p)
            if r and r.Parent then
                local d = (r.Position - point.Position).Magnitude
                if d <= CONFIG.GEN_POINT_OCCUPIED_RADIUS then
                    local char = p.Character
                    if char then
                        local rep = char:GetAttribute("isRepairing")
                        if rep == true then return true, "prox-repairing" end
                        if rep == nil then return true, "prox-nil" end
                    end
                end
            end
        end
    end
    return false, "free"
end

local function getAvailableGeneratorPoints(gen)
    local all = getGeneratorPoints(gen)
    local avail = {}
    for _, pt in ipairs(all) do
        local occ = isGeneratorPointOccupied(pt)
        if not occ then table.insert(avail, pt) end
    end
    return avail, all
end

-- R14/R16: full availability check
local function isGeneratorAvailable(gen)
    if not gen or not gen.Parent then return false, 0, 0 end
    if isGeneratorCompleted(gen) then return false, 0, 0 end
    local avail, all = getAvailableGeneratorPoints(gen)
    return #avail > 0, #avail, #all
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
            glog("container %s (%s) → %d gens", c:GetFullName(), reason, #list)
        end
        return list, reason
    end
    if GenRegistry.lastCount ~= 0 then GenRegistry.lastCount = 0; glog("container not found") end
    GenRegistry.container = nil; GenRegistry.list = {}; GenRegistry.lastScan = now
    GenRegistry.lastReason = "not-found"
    return {}, "not-found"
end

-- R15: prefer nearest AVAILABLE point (fallback to nearest any point)
local function genApproachPoint(gen)
    if not gen then return nil end
    local myRoot = getRoot(); if not myRoot then return nil end
    local avail, all = getAvailableGeneratorPoints(gen)
    local points = #avail > 0 and avail or all
    local best, bestD = nil, math.huge
    for _, pt in ipairs(points) do
        local d = (myRoot.Position - pt.Position).Magnitude
        if d < bestD then bestD, best = d, pt end
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

-- R16: scoreGenerator rejects gen with no available slot
local function scoreGenerator(gen, myRoot, killerPos)
    if not gen or not gen.Parent or not myRoot then return math.huge end
    if isGeneratorCompleted(gen) then return math.huge end
    local available, availCount, totalPoints = isGeneratorAvailable(gen)
    if not available then return math.huge end
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
    local best, bestScore, bestReason = nil, math.huge, ""
    local candCount, skippedCompleted, skippedFull, skippedBl = 0, 0, 0, 0
    for _,gen in ipairs(list) do
        if gen.Parent and gen ~= excludedGen then
            if isGeneratorCompleted(gen) then
                skippedCompleted = skippedCompleted + 1
            else
                local avail, availCount, totalPoints = isGeneratorAvailable(gen)
                if not avail then
                    skippedFull = skippedFull + 1
                else
                    local ap = genApproachPoint(gen)
                    if ap and isTargetBlacklisted(ap) then
                        skippedBl = skippedBl + 1
                    else
                        local s = scoreGenerator(gen, myRoot, killerPos)
                        if s < math.huge then
                            candCount = candCount + 1
                            if s < bestScore then
                                bestScore = s; best = gen
                                bestReason = string.format("score=%.1f avail=%d/%d",
                                    s, availCount, totalPoints)
                            end
                        end
                    end
                end
            end
        end
    end
    if best then return best, bestReason end
    return nil, string.format("cand=%d done=%d full=%d bl=%d",
        candCount, skippedCompleted, skippedFull, skippedBl)
end

-- ============================================================================
-- FLEE
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
        if gen.Parent and gen ~= exclude and not isGeneratorCompleted(gen) then
            local avail = isGeneratorAvailable(gen)
            if avail then
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
    State = "IDLE",
    targetGen = nil, approachPos = nil,
    lastGenScan = 0, lastProgress = nil, lastProgressT = 0,
    failedGens = {},
    lastLoggedGen = nil, lastNoGenLog = 0,
    lastStateLog = 0, lastSearchLog = 0, lastSwitchT = 0,
    searchStateSince = 0, lastSearchDiag = 0,
}

local function survivorReset()
    Survivor.State = "IDLE"
    Survivor.targetGen = nil; Survivor.approachPos = nil
    Survivor.lastGenScan = 0; Survivor.lastProgress = nil; Survivor.lastProgressT = 0
    Survivor.failedGens = {}
    Survivor.lastLoggedGen = nil; Survivor.lastNoGenLog = 0
    Survivor.lastSearchLog = 0; Survivor.lastSwitchT = 0
    Survivor.searchStateSince = 0; Survivor.lastSearchDiag = 0
    cancelGoal(); resetFlee(); resetThreat(); resetPerception()
    endRepairSession(false); releaseShift(); endHoldAction()
end

local function setSurvivorState(newState, now, extra)
    if Survivor.State ~= newState then
        log(string.format("[Survivor] %s → %s %s", Survivor.State, newState, extra or ""))
        Survivor.lastStateLog = now
        Survivor.State = newState
        if newState ~= "SEARCH_GENERATOR" then Survivor.searchStateSince = 0 end
    end
end

-- R6 + R14 + R20: forceNew param untuk post-chase fresh scan
local function survivorPickGenerator(now, killerPos, exclude, forceNew)
    local myRoot = getRoot(); if not myRoot then return false end
    local current = Survivor.targetGen
    local currentAvail, currAvailCount, currTotalPoints = false, 0, 0
    if current and current.Parent then
        currentAvail, currAvailCount, currTotalPoints = isGeneratorAvailable(current)
    end
    if forceNew then currentAvail = false end

    if currentAvail and currAvailCount > 0 then
        if (now - Survivor.lastSwitchT) > CONFIG.GEN_RESCAN_COOLDOWN then
            local newGen = findBestGenerator(myRoot, killerPos, exclude)
            if newGen and newGen ~= current then
                local curScore = scoreGenerator(current, myRoot, killerPos)
                local newScore = scoreGenerator(newGen, myRoot, killerPos)
                if newScore < curScore - CONFIG.GEN_SWITCH_MARGIN then
                    Survivor.targetGen = newGen
                    Survivor.approachPos = genApproachPoint(newGen)
                    Survivor.lastSwitchT = now
                    glog("switch → %s (cur=%.1f new=%.1f)",
                        newGen:GetFullName(), curScore, newScore)
                    return true
                end
            end
        end
        Survivor.approachPos = genApproachPoint(current)
        Survivor.lastGenScan = now
        if Survivor.lastLoggedGen ~= current then
            Survivor.lastLoggedGen = current
            glog("retain %s (avail=%d/%d)", current:GetFullName(), currAvailCount, currTotalPoints)
        end
        return true
    end

    local g, reason = findBestGenerator(myRoot, killerPos, exclude)
    if not g then
        if now - Survivor.lastNoGenLog > 3 then
            Survivor.lastNoGenLog = now
            glog("no valid gen | "..tostring(reason))
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
        local a, t = getAvailableGeneratorPoints(g)
        glog("picked %s (%s) avail=%d/%d", g:GetFullName(), reason, #a, #t)
    end
    return true
end

local function SurvivorAI(now)
    local hum = getHumanoid()
    local root = getRoot()
    if not hum or not root or hum.Health <= 0 then
        Survivor.State = "IDLE"
        endRepairSession(true); releaseShift(); endHoldAction(); cancelGoal()
        return
    end

    -- R11: SELF STATE early return
    local selfState = getSelfState()
    if selfState == "dead" then
        setSurvivorState("DEAD", now)
        endRepairSession(true); releaseShift(); endHoldAction(); cancelGoal()
        return
    end
    if selfState == "hooked" then
        setSurvivorState("HOOKED", now)
        endRepairSession(true); releaseShift(); endHoldAction(); cancelGoal()
        return
    end
    if selfState == "carried" then
        setSurvivorState("CARRIED", now)
        endRepairSession(true); releaseShift(); endHoldAction(); cancelGoal()
        return
    end
    if selfState == "knocked" then
        setSurvivorState("SELF_HEALING", now)
        endRepairSession(true); releaseShift(); cancelGoal()
        hum:Move(Vector3.zero, false)
        beginHoldAction()
        return
    end

    -- Threat check
    local killer, killerRoot, kD, threat, P = updateThreat(now)
    if threat and killerRoot then
        -- R10/R17: stop repair FIRST (release shift) before fleeing
        if Survivor.State == "REPAIRING" or Repair.active then
            log("Survivor: interrupted repair → flee")
            endRepairSession(true)
            releaseShift()
        end
        setSurvivorState("CHASE_ESCAPE", now, string.format("(d=%.1f P=%.2f)", kD, P or 0))
        local fleeTarget = pickFleeTarget(root, killerRoot)
        holdShift()
        setGoal(fleeTarget, "flee")
        followStep()
        return
    end

    -- R20: leaving CHASE → fresh scan
    if Survivor.State == "CHASE_ESCAPE" then
        clog("evade done → fresh scan (was target=%s)",
            Survivor.targetGen and Survivor.targetGen:GetFullName() or "nil")
        endRepairSession(false)
        releaseShift(); endHoldAction()
        cancelGoal(); resetFlee()
        Survivor.targetGen = nil
        Survivor.approachPos = nil
        Survivor.lastGenScan = 0
        Survivor.lastLoggedGen = nil
        Survivor.State = "SEARCH_GENERATOR"
    end

    -- R9: RESCUE priority
    do
        local rt, rd = findHookedTarget()
        if rt then
            local kDist = killerRoot and (rt.root.Position - killerRoot.Position).Magnitude or math.huge
            if kDist > CONFIG.RESCUE_SAFE_DIST then
                setSurvivorState("RESCUING", now, string.format("(d=%.1f)", rd))
                endRepairSession(true); releaseShift()
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

    -- R9: HEAL priority
    do
        local ht, hd = findHealTarget()
        if ht then
            local kDist = killerRoot and (ht.root.Position - killerRoot.Position).Magnitude or math.huge
            if kDist > CONFIG.RESCUE_SAFE_DIST then
                setSurvivorState("HEALING", now, string.format("(d=%.1f)", hd))
                endRepairSession(true); releaseShift()
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
    if Survivor.State == "ALL_DONE" then
        if now - Survivor.lastGenScan > 3 then
            Survivor.lastGenScan = now
            if findBestGenerator(root, nil) then
                Survivor.State = "SEARCH_GENERATOR"
                Survivor.lastLoggedGen = nil
            end
        end
        endRepairSession(false); releaseShift(); endHoldAction(); cancelGoal()
        return
    end

    if Survivor.State == "SEARCH_GENERATOR" then
        Survivor.searchStateSince = (Survivor.searchStateSince == 0) and now or Survivor.searchStateSince
        if now - Survivor.searchStateSince > CONFIG.SEARCH_STUCK_LOG
            and now - Survivor.lastSearchDiag > CONFIG.SEARCH_STUCK_LOG then
            Survivor.lastSearchDiag = now
            local list, reason = getGeneratorList()
            glog("[SearchDiag] %.1fs | list=%d reason=%s",
                now - Survivor.searchStateSince, #list, tostring(reason))
        end
    end

    local targetLost = (not Survivor.targetGen or not Survivor.targetGen.Parent)
    local targetComplete = Survivor.targetGen and isGeneratorCompleted(Survivor.targetGen)

    if Survivor.State == "SEARCH_GENERATOR" or targetLost or targetComplete or not Survivor.targetGen then
        local killers = evaluateKillers()
        local killerPos = (#killers > 0) and killers[1].root and killers[1].root.Position or nil
        if not survivorPickGenerator(now, killerPos, nil, false) then
            local list = getGeneratorList()
            local anyLeft = false
            for _,gg in ipairs(list) do
                if not isGeneratorCompleted(gg) then anyLeft = true; break end
            end
            if not anyLeft and #list > 0 then
                setSurvivorState("ALL_DONE", now)
                cancelGoal(); endHoldAction()
                endRepairSession(false); releaseShift()
            else
                setSurvivorState("SEARCH_GENERATOR", now)
                cancelGoal(); endHoldAction()
                endRepairSession(false); releaseShift()
            end
            return
        end
        setSurvivorState("MOVING_TO_GENERATOR", now)
    end

    local gen = Survivor.targetGen
    if not gen or not gen.Parent then
        setSurvivorState("SEARCH_GENERATOR", now)
        cancelGoal(); return
    end

    if isGeneratorCompleted(gen) then
        glog("target %s completed mid-travel → reselect", gen:GetFullName())
        setSurvivorState("SEARCH_GENERATOR", now)
        cancelGoal(); endRepairSession(true); releaseShift()
        return
    end

    local ap = Survivor.approachPos or genApproachPoint(gen)
    if not ap then setSurvivorState("SEARCH_GENERATOR", now); return end
    Survivor.approachPos = ap

    local d = (root.Position - ap).Magnitude
    if d <= CONFIG.SURV_GEN_ACTION_R then
        -- R17: REPAIR = holdShift (not touch-hold)
        if Survivor.State ~= "REPAIRING" then
            setSurvivorState("REPAIRING", now)
            Survivor.lastProgress = getGenProgress(gen)
            Survivor.lastProgressT = now
            beginRepairSession()
            cancelGoal()
        end
        hum:Move(Vector3.zero, false)
        holdShift()

        -- R22: gen complete while repairing
        local cur = getGenProgress(gen)
        if cur and cur >= 100 then
            rlog("gen %s complete → release + reselect", gen:GetFullName())
            endRepairSession(false)
            releaseShift()
            setSurvivorState("SEARCH_GENERATOR", now)
            Survivor.targetGen = nil
            Survivor.lastGenScan = 0
            Survivor.lastLoggedGen = nil
            return
        end

        if cur and Survivor.lastProgress and cur > Survivor.lastProgress then
            Survivor.lastProgress = cur
            Survivor.lastProgressT = now
        end
        if now - Survivor.lastProgressT > CONFIG.SURV_GEN_NO_PROGRESS then
            rlog("gen %s no progress → abandon", gen:GetFullName())
            Survivor.failedGens[gen] = now
            endRepairSession(true)
            releaseShift()
            setSurvivorState("SEARCH_GENERATOR", now)
            Survivor.targetGen = nil
            Survivor.lastGenScan = 0
            Survivor.lastLoggedGen = nil
            return
        end

        -- R21: verify slot still available
        local stillAvail = false
        for _, pt in ipairs(getGeneratorPoints(gen)) do
            if (root.Position - pt.Position).Magnitude <= CONFIG.SURV_GEN_ACTION_R + 1 then
                if not isGeneratorPointOccupied(pt) then
                    stillAvail = true; break
                end
            end
        end
        if not stillAvail then
            rlog("slot lost on %s → reselect", gen:GetFullName())
            endRepairSession(true)
            releaseShift()
            setSurvivorState("SEARCH_GENERATOR", now)
            Survivor.targetGen = nil
            Survivor.lastGenScan = 0
            Survivor.lastLoggedGen = nil
            return
        end
    else
        setSurvivorState("MOVING_TO_GENERATOR", now, string.format("(d=%.1f)", d))
        endRepairSession(true)
        endHoldAction()
        holdShift()
        setGoal(ap, "gen")
        followStep()
    end
end

-- ============================================================================
-- KILLER AI
-- ============================================================================
local Killer = { State="IDLE", target=nil, targetPlayer=nil,
                 hitCount={}, lastHitT=0, lastCheck=0 }

local function killerReset()
    Killer.State="IDLE"; Killer.target=nil; Killer.targetPlayer=nil
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
    local root = getRoot(); local hum = getHumanoid()
    if not root or not hum or hum.Health <= 0 then Killer.State = "IDLE"; return end
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
        Killer.State = "IDLE"; cancelGoal(); hum:Move(Vector3.zero, false); return
    end
    local d = dist(root, target)
    if d <= CONFIG.KILLER_HIT_RANGE + CONFIG.KILLER_HIT_TOL then
        if Killer.State ~= "ATTACKING" then
            log(string.format("[Killer] ATTACK d=%.1f", d)); Killer.State = "ATTACKING"
        end
        cancelGoal(); hum:Move(Vector3.zero, false)
        local uid = Killer.targetPlayer and Killer.targetPlayer.UserId or 0
        local hits = Killer.hitCount[uid] or 0
        if hits < CONFIG.KILLER_MAX_HITS and (now - Killer.lastHitT) > CONFIG.KILLER_HIT_COOLDOWN then
            Killer.lastHitT = now; Killer.hitCount[uid] = hits + 1
            tapAction()
        end
        if (Killer.hitCount[uid] or 0) >= CONFIG.KILLER_MAX_HITS then
            Killer.target=nil; Killer.targetPlayer=nil; Killer.State="IDLE"
        end
    else
        if Killer.State ~= "CHASING" then
            log(string.format("[Killer] CHASE d=%.1f", d)); Killer.State = "CHASING"
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
    readyGui.Name = "KemiAI_Ready"; readyGui.ResetOnSpawn = false
    readyGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    readyGui.IgnoreGuiInset = true; readyGui.Parent = pg
    readyLabel = Instance.new("TextLabel")
    readyLabel.AnchorPoint = Vector2.new(0,1)
    readyLabel.Position = UDim2.new(0,14,1,-14)
    readyLabel.Size = UDim2.new(0,600,0,18)
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
    log(string.format("[Role] %s → %s", tostring(old), tostring(new)))
    survivorReset(); killerReset(); resetThreat()
    if new == "Spectator" then endRepairSession(true); releaseShift(); endHoldAction(); cancelGoal() end
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
            endRepairSession(true); releaseShift(); endHoldAction(); cancelGoal(); return
        end
        if role == "Survivor" then
            local ok, err = pcall(SurvivorAI, now)
            if not ok then log("SurvivorAI error:", err) end
        elseif role == "Killer" then
            local ok, err = pcall(KillerAI, now)
            if not ok then log("KillerAI error:", err) end
        else
            endRepairSession(true); releaseShift(); endHoldAction(); cancelGoal()
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
    endRepairSession(false); endHoldAction(); ensureGuiAlive()
end)

localPlayer.CharacterRemoving:Connect(function()
    endRepairSession(true); releaseShift(); endHoldAction(); cancelGoal()
end)

-- ============================================================================
-- KILL SWITCH
-- ============================================================================
_G.KemiAI_Stop = function()
    if roleWatcherConnection then roleWatcherConnection:Disconnect(); roleWatcherConnection = nil end
    endRepairSession(true); releaseShift(); endHoldAction(); cancelGoal()
    resetThreat(); resetFlee(); resetPerception()
    if readyGui then pcall(function() readyGui:Destroy() end); readyGui=nil; readyLabel=nil end
    log("Stopped")
end

log("AI ready — R7 generator + chase state fix loaded")
