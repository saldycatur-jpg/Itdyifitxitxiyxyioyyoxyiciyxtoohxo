-- ============================================================================
-- KEMI // PLAY AI — R4 (Stable Navigation + Full Survivor Actions)
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
    DEBUG = false, DEBUG_NAV = false,

    BASE_WALKSPEED   = 16,
    WALKSPEED_FACTOR = 1.1,

    -- Detection radii
    SURV_GEN_DETECT     = 10000,   -- user requirement
    SURV_SURVIVOR_SCAN  = 10000,
    SURV_GEN_ACTION_R   = 5,
    SURV_GEN_NO_PROGRESS= 3.0,
    SURV_STUCK_WATCHDOG = 15.0,

    -- Killer threat (unchanged defaults)
    KILLER_DETECT_RANGE = 300,
    KILLER_HIT_RANGE    = 6,
    KILLER_HIT_TOL      = 1,
    KILLER_MAX_HITS     = 2,
    KILLER_HIT_COOLDOWN = 1.2,
    KILLER_TARGET_RECHECK=0.5,

    THREAT_WARNING_DIST = 160,
    THREAT_ENTER_DIST   = 115,
    THREAT_EXIT_DIST    = 200,
    THREAT_EMERGENCY_D  = 45,
    THREAT_CLEAR_TIME   = 2.0,
    THREAT_HEADING_DOT  = 0.55,
    THREAT_P_ENTER      = 0.55,
    THREAT_P_EXIT       = 0.30,
    THREAT_TTC_HORIZON  = 6.0,
    THREAT_W = { bias=-4.2, w_distance=3.8, w_closing=2.5, w_heading=1.6, w_ttc=1.2, w_pathRisk=0.8 },

    -- Movement hysteresis (STRONGER now)
    REPATH_DIST_THRESH    = 30,
    WAYPOINT_REACH_DIST   = 5.0,
    WAYPOINT_SKIP_DIST    = 6.0,
    WAYPOINT_TIMEOUT      = 2.5,
    PATH_FAIL_THRESHOLD   = 3,
    PATH_FAIL_COOLDOWN    = 15,
    PATH_CACHE_TTL        = 5.0,
    PATH_RETRY_INTERVAL   = 1.5,
    PATH_MAX_INFLIGHT     = 3,

    -- Stuck handling
    NAV_STUCK_TIME     = 1.5,
    NAV_PROGRESS_EPS   = 1.0,
    NAV_MAX_RECOVERIES = 3,
    NAV_LOG_INTERVAL   = 3.0,
    NAV_SIDESTEP_DIST  = 8,
    NAV_SIDESTEP_TIME  = 0.35,
    NAV_STUCK_TO_SIDE  = 2,

    RAYCAST_DIST = 12,

    -- Generator target stability (STRONGER now)
    GEN_SWITCH_MARGIN  = 120,
    GEN_RESCAN_COOLDOWN= 15.0,
    GEN_PROGRESS_WEIGHT= 0.6,
    GEN_KILLER_SAFE_DIST = 60,
    GEN_KILLER_PENALTY = 8,
    GEN_DISCOVERY_DEPTH= 3,
    GEN_CACHE_TTL      = 5.0,
    GEN_FAILED_COOLDOWN= 20,       -- how long a failed gen is blacklisted

    -- Flee stability (STRONGER now)
    FLEE_DISTANCE       = 45,
    FLEE_MIN_DIST_KILLER= 40,
    FLEE_REPICK_INTERVAL= 3.0,
    FLEE_COMMIT_TIME    = 2.0,
    FLEE_REACHED_RADIUS = 6,
    FLEE_SAFE_GEN_MAX   = 300,
    FLEE_KILLER_MOVE_THRESH = 25,   -- repick if killer moved this far

    -- Decision cadence
    DECISION_INTERVAL = 0.25,
    RESCUE_SAFE_RADIUS = 50,
    HEAL_SAFE_RADIUS   = 50,
    SELF_KNOCK_HEAL    = 50,

    GUI_CHECK_INTERVAL = 2.0,

    TOUCH_ID = 8822,
    ACTION_PATHS = {
        "Survivor-mob.Controls.action",
        "Survivor-mob.Controls.action.check",
        "Survivor-mob.Controls.check",
        "Killer-mob.Controls.action",
        "Killer-mob.Controls.attack",
        "Killer-mob.Controls.check",
    },

    -- External skillcheck
    SKILLCHECK_URL = "https://raw.githubusercontent.com/saldycatur-jpg/Itdyifitxitxiyxyioyyoxyiciyxtoohxo/refs/heads/main/Sk.lua",
}

local ActionPath = CONFIG.ACTION_PATHS[1]
local TouchID    = CONFIG.TOUCH_ID

local config = _G.config
if type(config) ~= "table" then config = {} end
if config.autoSkillCheckEnabled == nil then config.autoSkillCheckEnabled = true end

-- ============================================================================
-- FORWARD DECLS
-- ============================================================================
local Survivor, Killer, Movement, Action

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
local function dist(a, b)
    if not a or not b then return math.huge end
    return (a.Position - b.Position).Magnitude
end
local function posKey(p)
    if not p then return "nil" end
    return string.format("%.1f|%.1f|%.1f", p.X, p.Y, p.Z)
end
local function clamp(v, lo, hi)
    if v ~= v then return lo end
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end
local function sigmoid(z)
    z = clamp(z, -20, 20)
    return 1 / (1 + math.exp(-z))
end
local function hasClearLine(fromPos, toPos, ignoreModel)
    if not fromPos or not toPos then return false end
    local delta = toPos - fromPos
    local mag = delta.Magnitude
    if mag < 0.5 then return true end
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    local ignoreList = {}
    if ignoreModel then table.insert(ignoreList, ignoreModel) end
    local ch = getChar()
    if ch then table.insert(ignoreList, ch) end
    if #ignoreList > 0 then params.FilterDescendantsInstances = ignoreList end
    local probeLen = math.min(mag, CONFIG.RAYCAST_DIST)
    return workspace:Raycast(fromPos, delta.Unit * probeLen, params) == nil
end

-- ============================================================================
-- ACTION STATE + FUNCTIONS (all isX attributes + remote bindings)
-- ============================================================================
Action = {
    isVaulting = false,
    isSliding = false,
    isDroppingPallet = false,
    isRepairing = false,
    isHealing = false,
    isExiting = false,
    isUnhooking = false,
    selfUnhookHolding = false,
    selfUnhookStartTime = 0,
    giftDropCooldown = false,
    currentName = nil,
    currentStart = 0,
    currentTarget = nil,
}

local function resetActionState()
    for k in pairs(Action) do
        if type(Action[k]) == "boolean" then Action[k] = false end
    end
    Action.currentName = nil
    Action.currentStart = 0
    Action.currentTarget = nil
    Action.selfUnhookStartTime = 0
end

local function setAction(name, on, target)
    if on then
        Action[name] = true
        Action.currentName = name
        Action.currentStart = tick()
        Action.currentTarget = target
    else
        Action[name] = false
        if Action.currentName == name then
            Action.currentName = nil
            Action.currentTarget = nil
        end
    end
end

-- Remotes (bounded by bindCommonRemotes)
local Remotes = {}
local function findRemote(parent, ...)
    local cur = parent
    for _, n in ipairs({...}) do
        if not cur then return nil end
        cur = cur:FindFirstChild(n)
    end
    return cur
end

local function bindCommonRemotes()
    Remotes = {}
    local r = ReplicatedStorage:FindFirstChild("Remotes")
    if not r then return end
    local function T(name, ...)
        local obj = findRemote(r, ...)
        if obj then Remotes[name] = obj end
    end
    T("RepairAnim", "Generator", "RepairAnim")
    T("HealAnim",   "Healing",   "HealAnim")
    T("HealingReset","Healing",  "Reset")
    T("VaultEvent",  "Vault",    "VaultEvent")
    T("PalletSlideEvent","Pallet","PalletSlideEvent")
    T("PalletDropEvent","Pallet","PalletDropEvent")
    T("HookPhase",   "Hook",     "HookPhase")
    T("SelfUnHookEvent","Hook",  "SelfUnHookEvent")

    local function on(evt, cb)
        if evt and evt:IsA("RemoteEvent") then
            pcall(function() evt.OnClientEvent:Connect(cb) end)
        end
    end
    on(Remotes.RepairAnim, function() if Action.isRepairing then Action.stopRepair() end end)
    on(Remotes.HealAnim,   function() if Action.isHealing then Action.stopHeal() end end)
    on(Remotes.VaultEvent, function() if Action.isVaulting then setAction("isVaulting", false) end end)
    on(Remotes.PalletSlideEvent, function() if Action.isSliding then setAction("isSliding", false) end end)
    on(Remotes.PalletDropEvent,  function() if Action.isDroppingPallet then setAction("isDroppingPallet", false) end end)
    on(Remotes.HookPhase,  function() resetActionState() end)
end

-- Action start/stop public functions
function Action.startVault()          setAction("isVaulting", true, "vault"); TriggerMobileButton() end
function Action.startPalletSlide()    setAction("isSliding", true, "slide");  TriggerMobileButton() end
function Action.startPalletDrop()     setAction("isDroppingPallet", true, "drop"); TriggerMobileButton() end
function Action.startRepair(gen)      setAction("isRepairing", true, gen); TriggerMobileButton() end
function Action.stopRepair()          setAction("isRepairing", false); if Remotes.RepairAnim then end end
function Action.startHeal(t)          setAction("isHealing", true, t); TriggerMobileButton() end
function Action.stopHeal()            setAction("isHealing", false) end
function Action.startExit()           setAction("isExiting", true, "exit"); TriggerMobileButton() end
function Action.stopExit()            setAction("isExiting", false) end
function Action.startUnhook(t)        setAction("isUnhooking", true, t); TriggerMobileButton() end
function Action.startPumpkin()        setAction("isVaulting", true, "pumpkin"); TriggerMobileButton() end
function Action.startGiftPickup()     setAction("isVaulting", true, "gift"); TriggerMobileButton() end
function Action.startSelfUnhook()
    Action.selfUnhookHolding = true
    Action.selfUnhookStartTime = tick()
    if Remotes.SelfUnHookEvent and Remotes.SelfUnHookEvent:IsA("RemoteEvent") then
        pcall(function() Remotes.SelfUnHookEvent:FireServer() end)
    end
end
function Action.tryPutDownGift()
    Action.giftDropCooldown = true
    task.delay(2, function() Action.giftDropCooldown = false end)
end
function Action.fireSelfUnhook()
    if Remotes.SelfUnHookEvent and Remotes.SelfUnHookEvent:IsA("RemoteEvent") then
        pcall(function() Remotes.SelfUnHookEvent:FireServer() end)
    end
end
function Action.fireResetHeal()
    if Remotes.HealingReset and Remotes.HealingReset:IsA("RemoteEvent") then
        pcall(function() Remotes.HealingReset:FireServer() end)
    end
end
function Action.fireStopEmote()
    local gui = localPlayer:FindFirstChild("PlayerGui")
    local emote = gui and gui:FindFirstChild("EmoteHandler")
    if emote and emote:IsA("RemoteEvent") then
        pcall(function() emote:FireServer("Stop") end)
    end
end
function Action.reset() resetActionState() end

-- ============================================================================
-- MOTION CONTROLLER (SINGLE PATH, HARDENED)
-- ============================================================================
Movement = {
    path = nil,
    target = nil,
    targetReason = "",
    targetSince = 0,
    waypoints = {},
    index = 1,
    status = "Idle",            -- Idle | Computing | Following | Failed | Blocked
    lastRecalcAt = 0,
    lastRecalcReason = "",
    computing = false,
    pendingTarget = nil,
    blockedConn = nil,
    pathInvalidated = false,
    consecutiveFail = 0,
    failTargetKey = nil,
    failedTargets = {},          -- posKey -> tick of blacklisting
    stuckSince = 0,
    lastPos = nil,
    sideStepUntil = 0,
    sideStepDir = nil,
    jumpCooldown = 0,
    pathMemo = {},
    lastMoveTo = nil,
    navLog = 0,
}

local function logPath(reason)
    if CONFIG.DEBUG_NAV then
        log(string.format("[MOVE] status=%s target=%s reason=%s wp=%d/%d",
            Movement.status, posKey(Movement.target), reason,
            Movement.index, #Movement.waypoints))
    end
end

local function disconnectBlocked()
    if Movement.blockedConn then
        pcall(function() Movement.blockedConn:Disconnect() end)
        Movement.blockedConn = nil
    end
end

function Movement:clear(reason)
    disconnectBlocked()
    self.waypoints = {}
    self.index = 1
    self.lastMoveTo = nil
    self.stuckSince = 0
    self.lastPos = nil
    if self.status ~= "Idle" then
        self.status = "Idle"
        logPath(reason or "clear")
    end
end

function Movement:abandonTarget(reason)
    self:clear(reason)
    self.target = nil
    self.targetReason = ""
end

function Movement:isBlacklisted(pos)
    if not pos then return true end
    local key = posKey(pos)
    local t = self.failedTargets[key]
    if not t then return false end
    if tick() - t > CONFIG.GEN_FAILED_COOLDOWN then
        self.failedTargets[key] = nil
        return false
    end
    return true
end

function Movement:blacklist(pos)
    if not pos then return end
    self.failedTargets[posKey(pos)] = tick()
end

local function installWaypoints(targetPos, path)
    Movement.waypoints = path:GetWaypoints()
    Movement.index = 1
    Movement.lastRecalcAt = tick()
    Movement.lastRecalcReason = "installed"
    Movement.status = "Following"
    Movement.consecutiveFail = 0
    Movement.failTargetKey = nil
    Movement.pathInvalidated = false
    Movement.lastPos = nil
    Movement.stuckSince = 0
    logPath("installed")
end

local function computePath(targetPos, reason)
    local root = getRoot()
    if not root or not targetPos then return end
    -- guard: if already computing to same target, defer
    if Movement.computing then
        Movement.pendingTarget = targetPos
        return
    end
    disconnectBlocked()
    Movement.computing = true
    Movement.status = "Computing"
    Movement.target = targetPos
    Movement.targetSince = tick()
    Movement.targetReason = reason or "manual"
    Movement.lastRecalcReason = reason or "manual"
    logPath("computing: "..(reason or "manual"))

    local path = PathfindingService:CreatePath({
        AgentRadius = 3, AgentHeight = 6,
        AgentCanJump = true, AgentMaxSlope = 45,
        WaypointSpacing = 4,
    })
    local ok = pcall(function() path:ComputeAsync(root.Position, targetPos) end)
    Movement.computing = false

    if Movement.pendingTarget and Movement.pendingTarget ~= targetPos then
        local next_ = Movement.pendingTarget
        Movement.pendingTarget = nil
        Movement.path = path
        computePath(next_, "superseded")
        return
    end
    Movement.pendingTarget = nil

    if ok and path.Status == Enum.PathStatus.Success then
        Movement.path = path
        installWaypoints(targetPos, path)
        Movement.blockedConn = path.Blocked:Connect(function(idx)
            -- only react if blocked waypoint is at or ahead of us
            if idx and idx >= Movement.index then
                Movement.pathInvalidated = true
                dlog("Blocked at idx=%d (cur=%d)", idx, Movement.index)
            end
        end)
    else
        -- failure
        Movement.status = "Failed"
        Movement.waypoints = {}
        Movement.index = 1
        Movement.lastRecalcAt = tick()
        local key = posKey(targetPos)
        if Movement.failTargetKey == key then
            Movement.consecutiveFail = Movement.consecutiveFail + 1
        else
            Movement.consecutiveFail = 1
            Movement.failTargetKey = key
        end
        if Movement.consecutiveFail >= CONFIG.PATH_FAIL_THRESHOLD then
            Movement:blacklist(targetPos)
            Movement.consecutiveFail = 0
            Movement.failTargetKey = nil
            log(string.format("PathFailed → blacklist target=%s", posKey(targetPos)))
        else
            log(string.format("PathFailed target=%s (try %d/%d) status=%s",
                posKey(targetPos), Movement.consecutiveFail, CONFIG.PATH_FAIL_THRESHOLD,
                tostring(path.Status)))
        end
    end
end

-- Public: request new target (only Decision calls this)
function Movement:setTarget(pos, reason)
    if not pos then return end
    if self.target and (self.target - pos).Magnitude < 1 then
        return -- same target, no-op
    end
    if self:isBlacklisted(pos) then return end
    if self.computing then
        self.pendingTarget = pos
        return
    end
    computePath(pos, reason)
end

-- Public: invalidate path (e.g. Blocked event or failed waypoint)
function Movement:invalidate(reason)
    self.pathInvalidated = true
    self.lastRecalcReason = reason or "invalid"
end

local function tryJump()
    local hum = getHumanoid()
    if not hum then return end
    local now = tick()
    if now - Movement.jumpCooldown < 0.6 then return end
    Movement.jumpCooldown = now
    pcall(function() hum.Jump = true end)
end

local function trySideStep(root, targetPos)
    local hum = getHumanoid()
    if not hum or not root then return end
    local toT = (targetPos - root.Position)
    if toT.Magnitude < 0.5 then return end
    local dir = toT.Unit
    local perp = Vector3.new(-dir.Z, 0, dir.X)
    if Movement.sideStepDir then perp = -Movement.sideStepDir end
    Movement.sideStepDir = perp
    Movement.sideStepUntil = tick() + CONFIG.NAV_SIDESTEP_TIME
    hum:MoveTo(root.Position + perp * CONFIG.NAV_SIDESTEP_DIST)
end

-- Called every Heartbeat — lightweight, only follows waypoints
function Movement:step(now)
    local hum = getHumanoid()
    local root = getRoot()
    if not hum or not root then return end
    hum.WalkSpeed = CONFIG.BASE_WALKSPEED * CONFIG.WALKSPEED_FACTOR

    if not self.target then
        if self.status ~= "Idle" then self.status = "Idle" end
        return
    end
    local target = self.target

    -- Reached final target?
    if (root.Position - target).Magnitude <= CONFIG.WAYPOINT_REACH_DIST then
        hum:MoveTo(root.Position)
        return
    end

    if self.sideStepUntil > now then return end

    -- Stuck detection (lightweight)
    if self.lastPos then
        local d = (root.Position - self.lastPos).Magnitude
        if d < 0.2 then
            if self.stuckSince == 0 then self.stuckSince = now end
        else
            self.stuckSince = 0
        end
    end
    self.lastPos = root.Position

    -- If Computing, just MoveTo target directly (avoid standing still)
    if self.status == "Computing" then
        if self.lastMoveTo ~= target then
            self.lastMoveTo = target
            hum:MoveTo(target)
        end
        return
    end

    -- If Failed: only move if clear line to target (short distance only)
    if self.status == "Failed" then
        if (root.Position - target).Magnitude < 30 and hasClearLine(root.Position, target) then
            hum:MoveTo(target)
            self.lastMoveTo = target
        end
        return
    end

    -- If no waypoints left (path exhausted) but not at target: request repath
    if (#self.waypoints == 0 or self.index > #self.waypoints) then
        if now - self.lastRecalcAt > CONFIG.PATH_RETRY_INTERVAL then
            computePath(target, "waypoints-exhausted")
        end
        return
    end

    -- Follow current waypoint
    local wp = self.waypoints[self.index]
    if wp then
        if (root.Position - wp.Position).Magnitude < CONFIG.WAYPOINT_REACH_DIST then
            self.index = self.index + 1
            local nxt = self.waypoints[self.index]
            if nxt and (root.Position - nxt.Position).Magnitude < CONFIG.WAYPOINT_SKIP_DIST then
                self.index = self.index + 1
            end
            wp = self.waypoints[self.index]
        end
    end
    if wp then
        if wp.Action == Enum.PathWaypointAction.Jump then tryJump() end
        if self.lastMoveTo ~= wp.Position then
            self.lastMoveTo = wp.Position
            hum:MoveTo(wp.Position)
            if CONFIG.DEBUG_NAV and now - self.navLog > 1 then
                self.navLog = now
                dlog("[MOVE] follow wp=%d/%d", self.index, #self.waypoints)
            end
        end
    else
        hum:MoveTo(target)
    end

    -- Stuck handling — only if genuinely stuck for WAYPOINT_TIMEOUT
    if self.stuckSince > 0 and (now - self.stuckSince) >= CONFIG.NAV_STUCK_TIME then
        tryJump()
        trySideStep(root, target)
        self.stuckSince = 0
        self.lastRecalcReason = "stuck"
        computePath(target, "stuck")
    end
end

-- ============================================================================
-- PERCEPTION / THREAT
-- ============================================================================
local THREAT = {
    confirmed = false, clearStart = nil, P = 0,
    primary = nil, primaryRoot = nil, primaryDist = math.huge,
    smoothClosing = 0, lastKD = nil, lastSampleT = 0,
}

local function resetThreat()
    THREAT.confirmed = false
    THREAT.clearStart = nil
    THREAT.P = 0
    THREAT.primary = nil
    THREAT.primaryRoot = nil
    THREAT.primaryDist = math.huge
    THREAT.smoothClosing = 0
    THREAT.lastKD = nil
    THREAT.lastSampleT = 0
end

local function roleOfPlayer(p)
    if not p or p == localPlayer then return nil end
    if p.Team then
        local n = p.Team.Name
        if n == "Survivors" or n == "Survivor" then return "Survivor" end
        if n == "Killers" or n == "Killer" then return "Killer" end
        local l = n:lower()
        if l:find("survivor") then return "Survivor" end
        if l:find("killer") or l:find("monster") or l:find("enemy") then return "Killer" end
    end
    return nil
end
local function getPlayerRoot(p)
    local c = p and p.Character
    if not c then return nil end
    return c:FindFirstChild("HumanoidRootPart") or c:FindFirstChild("Torso")
end

local function evaluateKillers()
    local myRoot = getRoot()
    if not myRoot then return {} end
    local out = {}
    for _, p in ipairs(Players:GetPlayers()) do
        if roleOfPlayer(p) == "Killer" then
            local r = getPlayerRoot(p)
            if r then
                table.insert(out, { player = p, root = r, dist = (myRoot.Position - r.Position).Magnitude })
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

    -- instant closing rate
    local instant = 0
    if THREAT.lastKD then
        local dt = now - THREAT.lastSampleT
        if dt > 0.01 then instant = (THREAT.lastKD - kD) / dt end
    end
    THREAT.lastKD = kD
    THREAT.lastSampleT = now
    THREAT.smoothClosing = THREAT.smoothClosing * 0.65 + instant * 0.35

    local headingDot = 0
    local v = killerRoot.AssemblyLinearVelocity
    if v and v.Magnitude > 2 then
        local toMe = myRoot.Position - killerRoot.Position
        if toMe.Magnitude > 0.5 then
            headingDot = clamp(v.Unit:Dot(toMe.Unit), 0, 1)
        end
    end
    local xDist = clamp(1 - kD / CONFIG.THREAT_WARNING_DIST, 0, 1)
    local xClos = clamp(THREAT.smoothClosing / 40, -1, 1)
    local xHead = headingDot
    local ttc = math.huge
    if THREAT.smoothClosing > 1 then ttc = kD / THREAT.smoothClosing end
    local xTTC = 0
    if ttc < CONFIG.THREAT_TTC_HORIZON and ttc > 0 then
        xTTC = clamp(1 - ttc / CONFIG.THREAT_TTC_HORIZON, 0, 1)
    end
    local W = CONFIG.THREAT_W
    local z = W.bias + W.w_distance*xDist + W.w_closing*xClos + W.w_heading*xHead + W.w_ttc*xTTC
    local P = sigmoid(z)
    if kD <= CONFIG.THREAT_EMERGENCY_D then P = 1 end

    if not THREAT.confirmed and P >= CONFIG.THREAT_P_ENTER then
        THREAT.confirmed = true
        THREAT.clearStart = nil
        log(string.format("Threat ENTER: d=%.1f P=%.2f", kD, P))
    end
    if THREAT.confirmed and P <= CONFIG.THREAT_P_EXIT and kD > CONFIG.THREAT_EXIT_DIST then
        if not THREAT.clearStart then THREAT.clearStart = now end
        if now - THREAT.clearStart > CONFIG.THREAT_CLEAR_TIME then
            log(string.format("Threat EXIT: d=%.1f P=%.2f", kD, P))
            resetThreat()
            return primary.player, killerRoot, kD, false
        end
    else
        THREAT.clearStart = nil
    end
    THREAT.P = P
    THREAT.primary = primary.player
    THREAT.primaryRoot = killerRoot
    THREAT.primaryDist = kD
    return primary.player, killerRoot, kD, THREAT.confirmed
end

-- ============================================================================
-- SURVIVOR SCANNER (injured / hooked / carried / ragdoll)
-- ============================================================================
local function scanSurvivors()
    local out = { injured = {}, hooked = {}, carried = {}, healable = {}, rescued = false }
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= localPlayer and roleOfPlayer(p) == "Survivor" then
            local char = p.Character
            local hum = char and char:FindFirstChildOfClass("Humanoid")
            if char and hum and hum.Health > 0 then
                local isHooked = char:GetAttribute("IsHooked") == true
                local isCarried = char:GetAttribute("IsCarried") == true
                local rp = char:FindFirstChild("HumanoidRootPart")
                local canHeal = rp and rp:GetAttribute("CanGetHealed") == true
                local rag = char:FindFirstChild("RagdollTrigger")
                local isRagdoll = rag and rag.Value == true
                if isHooked then
                    table.insert(out.hooked, p)
                elseif isCarried then
                    table.insert(out.carried, p)
                elseif hum.Health <= 50 and not isRagdoll and canHeal then
                    table.insert(out.healable, p)
                end
            end
        end
    end
    return out
end

-- ============================================================================
-- GENERATOR DISCOVERY (unchanged semantics)
-- ============================================================================
local function getGameValue(obj, key)
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
local function isGenComplete(gen)
    if not gen or not gen.Parent then return true end
    local p = getGenProgress(gen)
    return p ~= nil and p >= 100
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

local GenRegistry = { container = nil, list = {}, lastScan = 0 }

local function scanContainerDirect()
    local map = workspace:FindFirstChild("Map")
    for _, c in ipairs({
        map and map:FindFirstChild("Generators"),
        map and map:FindFirstChild("Generator"),
        workspace:FindFirstChild("Generators"),
        workspace:FindFirstChild("Generator"),
    }) do
        if c and c.Parent then return c end
    end
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
    end
    return scan(workspace, 0)
end
local function collectGens(container)
    local out = {}
    local function scan(node, depth)
        if depth > CONFIG.GEN_DISCOVERY_DEPTH + 1 or not node then return end
        for _, ch in ipairs(node:GetChildren()) do
            if isValidGenerator(ch) then table.insert(out, ch)
            elseif ch:IsA("Folder") or ch:IsA("Model") then scan(ch, depth + 1) end
        end
    end
    scan(container, 0)
    return out
end

local function getGeneratorList()
    local now = tick()
    if GenRegistry.container and GenRegistry.container.Parent then
        if now - GenRegistry.lastScan < CONFIG.GEN_CACHE_TTL then
            return GenRegistry.list
        end
        local refreshed = collectGens(GenRegistry.container)
        if #refreshed > 0 then
            GenRegistry.list = refreshed
            GenRegistry.lastScan = now
            return refreshed
        end
    end
    local c = scanContainerDirect() or scanContainerRecursive()
    if c then
        GenRegistry.container = c
        GenRegistry.list = collectGens(c)
        GenRegistry.lastScan = now
        return GenRegistry.list
    end
    GenRegistry.container = nil
    GenRegistry.list = {}
    GenRegistry.lastScan = now
    return {}
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
-- DECISION CONTROLLER (priority based, single intent per tick)
-- ============================================================================
local Decision = {
    lastTick = 0,
    state = "Idle",
    intent = nil,
    intentTarget = nil,
    intentReason = "",
    killerChased = false,
    chaseAnchor = nil,       -- killer position when chase started
    chaseSince = 0,
    targetGen = nil,
    targetGenSince = 0,
    targetGenReason = "",
    rescueTarget = nil,
    healTarget = nil,
    lastLog = 0,
}

local function resetDecision()
    Decision.state = "Idle"
    Decision.intent = nil
    Decision.intentTarget = nil
    Decision.intentReason = ""
    Decision.killerChased = false
    Decision.chaseAnchor = nil
    Decision.chaseSince = 0
    Decision.targetGen = nil
    Decision.targetGenSince = 0
    Decision.targetGenReason = ""
    Decision.rescueTarget = nil
    Decision.healTarget = nil
end

local function setIntent(name, target, reason)
    if Decision.intent ~= name or (target and Decision.intentTarget ~= target) then
        Decision.intent = name
        Decision.intentTarget = target
        Decision.intentReason = reason or ""
        if CONFIG.DEBUG then
            log(string.format("[DEC] %s → %s (%s)",
                tostring(Decision.state), name, reason or ""))
        end
    end
end

local function stopActionsForPriority()
    if Action.isRepairing then Action.stopRepair() end
    if Action.isHealing then Action.stopHeal() end
    if Action.isExiting then Action.stopExit() end
    if Action.isUnhooking then setAction("isUnhooking", false) end
end

-- Score generator for target selection
local function scoreGen(gen, myRoot, killerPos)
    if not gen or not gen.Parent or isGenComplete(gen) then return math.huge end
    local ap = genApproachPoint(gen)
    if not ap or Movement:isBlacklisted(ap) then return math.huge end
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
    return score
end

local function pickBestGenerator(killerPos)
    local myRoot = getRoot()
    if not myRoot then return nil end
    local list = getGeneratorList()
    local best, bestScore = nil, math.huge
    for _, gen in ipairs(list) do
        if not isGenComplete(gen) then
            local s = scoreGen(gen, myRoot, killerPos)
            if s < bestScore then best, bestScore = gen, s end
        end
    end
    return best, bestScore
end

-- Validate current generator target; return true if still valid
local function genTargetValid(gen)
    if not gen or not gen.Parent then return false end
    if isGenComplete(gen) then return false end
    local ap = genApproachPoint(gen)
    if not ap or Movement:isBlacklisted(ap) then return false end
    return true
end

-- ============================================================================
-- FLEE TARGET (hysteresis)
-- ============================================================================
local FLEE = {
    target = nil, lastPick = 0, commitUntil = 0,
    killerAnchor = nil, lastLog = 0,
}

local function resetFlee()
    FLEE.target = nil
    FLEE.lastPick = 0
    FLEE.commitUntil = 0
    FLEE.killerAnchor = nil
end

local function rotateY(v, rad)
    local c, s = math.cos(rad), math.sin(rad)
    return Vector3.new(v.X*c - v.Z*s, 0, v.X*s + v.Z*c)
end

local function pickSafeFleeGen(myPos, killerPos, exclude)
    local list = getGeneratorList()
    local best, bestPos, bestCost = nil, nil, math.huge
    for _, gen in ipairs(list) do
        if gen.Parent and gen ~= exclude and not isGenComplete(gen) then
            local ap = genApproachPoint(gen)
            if ap and not Movement:isBlacklisted(ap) then
                local dAI = (myPos - ap).Magnitude
                if dAI <= CONFIG.FLEE_SAFE_GEN_MAX then
                    local dK = (ap - killerPos).Magnitude
                    if dK >= CONFIG.FLEE_MIN_DIST_KILLER then
                        local cost = dAI * 0.2 - dK
                        if cost < bestCost then bestCost = cost; best = gen; bestPos = ap end
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

    -- Emergency bolt
    if dToKiller < CONFIG.THREAT_EMERGENCY_D then
        local away = Vector3.new(myPos.X - killerPos.X, 0, myPos.Z - killerPos.Z)
        if away.Magnitude < 0.01 then away = Vector3.new(1, 0, 0) end
        away = away.Unit
        FLEE.target = myPos + away * CONFIG.FLEE_DISTANCE
        FLEE.lastPick = now
        FLEE.commitUntil = now + CONFIG.FLEE_COMMIT_TIME
        FLEE.killerAnchor = killerPos
        return FLEE.target
    end

    -- Retain current flee target unless clearly invalid
    if FLEE.target and FLEE.killerAnchor then
        local reached = (myPos - FLEE.target).Magnitude < CONFIG.FLEE_REACHED_RADIUS
        local targetWorse = (FLEE.target - killerPos).Magnitude < dToKiller
        local killerMoved = (killerPos - FLEE.killerAnchor).Magnitude > CONFIG.FLEE_KILLER_MOVE_THRESH
        local commitActive = now < FLEE.commitUntil
        if not reached and not targetWorse and (commitActive or not killerMoved) then
            return FLEE.target
        end
    end

    -- Try safe gen
    local safeGen, safePos = pickSafeFleeGen(myPos, killerPos, Decision.targetGen)
    if safeGen and safePos then
        FLEE.target = safePos
        FLEE.lastPick = now
        FLEE.commitUntil = now + CONFIG.FLEE_COMMIT_TIME
        FLEE.killerAnchor = killerPos
        return safePos
    end

    -- Angular fan
    local away = Vector3.new(myPos.X - killerPos.X, 0, myPos.Z - killerPos.Z)
    if away.Magnitude < 0.01 then away = Vector3.new(1, 0, 0) end
    away = away.Unit
    for _, deg in ipairs({0, 45, -45, 90, -90, 135, -135, 180}) do
        local dir = rotateY(away, math.rad(deg))
        local endPos = myPos + dir * CONFIG.FLEE_DISTANCE
        if (endPos - killerPos).Magnitude >= CONFIG.FLEE_MIN_DIST_KILLER
            and hasClearLine(myPos, endPos) then
            FLEE.target = endPos
            FLEE.lastPick = now
            FLEE.commitUntil = now + CONFIG.FLEE_COMMIT_TIME
            FLEE.killerAnchor = killerPos
            return endPos
        end
    end

    -- Fallback
    FLEE.target = myPos + away * 22
    FLEE.lastPick = now
    FLEE.commitUntil = now + CONFIG.FLEE_COMMIT_TIME
    FLEE.killerAnchor = killerPos
    return FLEE.target
end

-- ============================================================================
-- GUI + MOBILE BUTTON
-- ============================================================================
local readyGui, readyLabel
local function createReadyGui()
    if readyGui and readyGui.Parent then pcall(function() readyGui:Destroy() end) end
    local pg = localPlayer:FindFirstChild("PlayerGui")
    if not pg then return end
    readyGui = Instance.new("ScreenGui")
    readyGui.Name = "KemiAI_Ready"
    readyGui.ResetOnSpawn = false
    readyGui.IgnoreGuiInset = true
    readyGui.Parent = pg
    readyLabel = Instance.new("TextLabel")
    readyLabel.AnchorPoint = Vector2.new(0, 1)
    readyLabel.Position = UDim2.new(0, 14, 1, -14)
    readyLabel.Size = UDim2.new(0, 600, 0, 18)
    readyLabel.BackgroundTransparency = 1
    readyLabel.Text = "AI ready"
    readyLabel.TextColor3 = Color3.fromRGB(0, 255, 120)
    readyLabel.TextStrokeTransparency = 0.4
    readyLabel.Font = Enum.Font.GothamBold
    readyLabel.TextSize = 14
    readyLabel.TextXAlignment = Enum.TextXAlignment.Left
    readyLabel.Parent = readyGui
end
createReadyGui()

local ActionDiag = { lastWarn = 0, hits = 0, misses = 0 }
function GetActionTarget()
    for _, path in ipairs(CONFIG.ACTION_PATHS) do
        local cur = localPlayer:FindFirstChild("PlayerGui")
        if not cur then return nil end
        for seg in string.gmatch(path, "[^%.]+") do
            cur = cur and cur:FindFirstChild(seg)
        end
        if cur and cur:IsA("GuiObject") and cur.Visible then
            if cur.AbsoluteSize.X > 0 and cur.AbsoluteSize.Y > 0 then return cur end
        end
    end
    return nil
end
function TriggerMobileButton()
    local b = GetActionTarget()
    if not b then
        ActionDiag.misses = ActionDiag.misses + 1
        return false
    end
    local p, s, i = b.AbsolutePosition, b.AbsoluteSize, GuiService:GetGuiInset()
    local cx, cy = p.X + s.X/2 + i.X, p.Y + s.Y/2 + i.Y
    pcall(function()
        VirtualInputManager:SendTouchEvent(TouchID, 0, cx, cy)
        task.wait(0.02)
        VirtualInputManager:SendTouchEvent(TouchID, 2, cx, cy)
    end)
    ActionDiag.hits = ActionDiag.hits + 1
    return true
end

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
-- EXTERNAL SKILLCHECK LOADER (no internal skillcheck)
-- ============================================================================
local SkillcheckLoaded = false
local function loadExternalSkillcheck()
    if SkillcheckLoaded then return end
    if not config.autoSkillCheckEnabled then return end
    local url = CONFIG.SKILLCHECK_URL
    local function fetch(u)
        for _, fn in ipairs({
            function() return game:HttpGet(u) end,
            function() return game:HttpGetAsync(u) end,
            function()
                local ok, r = pcall(function() return request({Url=u, Method="GET"}) end)
                if ok and r then return r.Body end
            end,
            function()
                local ok, r = pcall(function() return syn.request({Url=u, Method="GET"}) end)
                if ok and r then return r.Body end
            end,
        }) do
            local ok, res = pcall(fn)
            if ok and type(res) == "string" and #res > 0 then return res end
        end
    end
    task.spawn(function()
        local src = fetch(url)
        if not src then log("Skillcheck: fetch failed"); return end
        local fn, err = loadstring(src)
        if not fn then log("Skillcheck: loadstring failed - "..tostring(err)); return end
        local ok, res = pcall(fn)
        if ok then
            SkillcheckLoaded = true
            log("Skillcheck: external script loaded")
        else
            log("Skillcheck: runtime error - "..tostring(res))
        end
    end)
end

-- ============================================================================
-- SELF-STATE HELPERS
-- ============================================================================
local function selfIsHooked()
    local c = getChar()
    return c and c:GetAttribute("IsHooked") == true
end
local function selfIsCarried()
    local c = getChar()
    return c and c:GetAttribute("IsCarried") == true
end
local function selfIsKnocked()
    local h = getHumanoid()
    return h and h.Health > 0 and h.Health <= 50
end
local function selfIsRagdoll()
    local c = getChar()
    local r = c and c:FindFirstChild("RagdollTrigger")
    return r and r.Value == true
end

-- ============================================================================
-- SURVIVOR AI (priority-based decision)
-- ============================================================================
Survivor = { State = "WaitingForCharacter" }

local function setSurvState(name, reason)
    if Survivor.State ~= name then
        log(string.format("Survivor: %s → %s (%s)",
            Survivor.State, name, reason or ""))
        Survivor.State = name
    end
end

local function SurvivorAI(now)
    local hum = getHumanoid()
    local root = getRoot()
    if not hum or not root or hum.Health <= 0 then
        setSurvState("WaitingForCharacter", "no-hum")
        Movement:clear("no-hum")
        return
    end

    -- Priority 1: self-hooked → do nothing except idle
    if selfIsHooked() then
        setSurvState("SelfHooked", "self hooked")
        stopActionsForPriority()
        Movement:clear("self-hooked")
        Action.startSelfUnhook() -- attempt self unhook (safe to call repeatedly)
        return
    end

    -- Priority 2: killer chase
    local killer, killerRoot, kD, threat = updateThreat(now)
    if threat and killerRoot then
        if Survivor.State ~= "EvadingKiller" then
            setSurvState("EvadingKiller", string.format("killer d=%.0f", kD))
            stopActionsForPriority()
            Decision.killerChased = true
            Decision.chaseSince = now
            Decision.chaseAnchor = killerRoot.Position
            Action.reset()
        end
        holdShift()
        local fleePos = pickFleeTarget(root, killerRoot)
        -- Only set target if changed significantly
        if not Movement.target or (Movement.target - fleePos).Magnitude > 8 then
            Movement:setTarget(fleePos, "evade")
        end
        Movement:step(now)
        return
    end

    -- Exit evade → resume decision
    if Survivor.State == "EvadingKiller" then
        log("Survivor: evade done → resume decision")
        setSurvState("Idle", "evade done")
        releaseShift()
        Movement:clear("evade done")
        resetFlee()
    end

    -- Priority 3: self-knocked / self-recovery
    if selfIsKnocked() or selfIsRagdoll() then
        setSurvState("SelfKnocked", "hp<=50 or ragdoll")
        stopActionsForPriority()
        Movement:clear("self-knocked")
        -- Stay put; if can heal, do so
        local rp = root
        if rp and rp:GetAttribute("CanGetHealed") == true then
            Action.startHeal(localPlayer.Character)
        end
        return
    end

    -- Priority 4: rescue hooked survivor (only if no killer within RESCUE_SAFE_RADIUS)
    local others = scanSurvivors()
    if #others.hooked > 0 then
        local killers = evaluateKillers()
        local nearestKillerDist = (#killers > 0) and killers[1].dist or math.huge
        for _, p in ipairs(others.hooked) do
            local pr = getPlayerRoot(p)
            if pr then
                local hookToKiller = nearestKillerDist == math.huge and math.huge
                    or ((#killers > 0) and (pr.Position - killers[1].root.Position).Magnitude or math.huge)
                if hookToKiller > CONFIG.RESCUE_SAFE_RADIUS then
                    local d = (root.Position - pr.Position).Magnitude
                    if d < CONFIG.SURV_SURVIVOR_SCAN then
                        if Decision.rescueTarget ~= p then
                            Decision.rescueTarget = p
                            setSurvState("Rescuing", string.format("%s d=%.0f", p.Name, d))
                        end
                        if d <= CONFIG.SURV_GEN_ACTION_R then
                            Action.startUnhook(p)
                            Movement:clear("at-hook")
                        else
                            Movement:setTarget(pr.Position, "rescue")
                            Movement:step(now)
                        end
                        return
                    end
                end
            end
        end
        Decision.rescueTarget = nil
    end

    -- Priority 5: heal injured survivor (only if > HEAL_SAFE_RADIUS from killer)
    if #others.healable > 0 then
        local killers = evaluateKillers()
        local nearestKillerDist = (#killers > 0) and killers[1].dist or math.huge
        local bestHeal, bestHealDist = nil, math.huge
        for _, p in ipairs(others.healable) do
            local pr = getPlayerRoot(p)
            if pr then
                local toKiller = (#killers > 0) and (pr.Position - killers[1].root.Position).Magnitude or math.huge
                if toKiller > CONFIG.HEAL_SAFE_RADIUS then
                    local d = (root.Position - pr.Position).Magnitude
                    if d < bestHealDist then bestHeal, bestHealDist = p, d end
                end
            end
        end
        if bestHeal then
            if Decision.healTarget ~= bestHeal then
                Decision.healTarget = bestHeal
                setSurvState("Healing", string.format("%s d=%.0f", bestHeal.Name, bestHealDist))
            end
            if bestHealDist <= CONFIG.SURV_GEN_ACTION_R then
                Action.startHeal(bestHeal)
                Movement:clear("at-heal")
            else
                local pr = getPlayerRoot(bestHeal)
                Movement:setTarget(pr.Position, "heal")
                Movement:step(now)
            end
            return
        end
        Decision.healTarget = nil
    end

    -- Priority 6: generator / exit objective
    -- Validate current gen target
    if Decision.targetGen then
        if not genTargetValid(Decision.targetGen) then
            log(string.format("Survivor: gen %s invalid → reselect",
                Decision.targetGen:GetFullName()))
            Decision.targetGen = nil
        end
    end

    -- Only pick new gen if no current target (never rescan for stability)
    if not Decision.targetGen then
        local killers = evaluateKillers()
        local killerPos = (#killers > 0) and killers[1].root.Position or nil
        local g, score = pickBestGenerator(killerPos)
        if g then
            Decision.targetGen = g
            Decision.targetGenSince = now
            Decision.targetGenReason = string.format("best-score=%.0f", score or -1)
            log(string.format("Survivor: gen target = %s (%s)",
                g:GetFullName(), Decision.targetGenReason))
        end
    end

    if Decision.targetGen then
        local ap = genApproachPoint(Decision.targetGen)
        if ap then
            local d = (root.Position - ap).Magnitude
            if d <= CONFIG.SURV_GEN_ACTION_R then
                setSurvState("InteractingWithGenerator", "reached gen")
                Movement:clear("at-gen")
                if not Action.isRepairing then
                    Action.startRepair(Decision.targetGen)
                end
                holdShift()
                -- progress watchdog
                if not Survivor.progressWatch then
                    Survivor.progressWatch = { t = now, last = getGenProgress(Decision.targetGen) or 0 }
                end
                local pw = Survivor.progressWatch
                local cur = getGenProgress(Decision.targetGen) or 0
                if cur > pw.last then pw.last = cur; pw.t = now end
                if now - pw.t > CONFIG.SURV_GEN_NO_PROGRESS then
                    log("Survivor: gen no progress → abandon")
                    Movement:blacklist(ap)
                    Decision.targetGen = nil
                    Action.stopRepair()
                    Survivor.progressWatch = nil
                end
                return
            else
                setSurvState("MovingToGenerator", string.format("d=%.0f", d))
                holdShift()
                Movement:setTarget(ap, "gen")
                Movement:step(now)
                return
            end
        else
            Decision.targetGen = nil
        end
    end

    -- Nothing to do
    setSurvState("Idle", "no objective")
    stopActionsForPriority()
    releaseShift()
    Movement:clear("idle")
end

-- ============================================================================
-- KILLER AI (unchanged from original, minimal)
-- ============================================================================
Killer = {
    State = "WaitingForCharacter",
    target = nil, targetPlayer = nil,
    hitCount = {}, lastHitT = 0, lastCheck = 0,
}
local function findNearestSurvivor(maxDist)
    maxDist = maxDist or CONFIG.KILLER_DETECT_RANGE
    local myRoot = getRoot(); if not myRoot then return nil end
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
    return best
end

local function KillerAI(now)
    local root = getRoot()
    local hum = getHumanoid()
    if not root or not hum or hum.Health <= 0 then
        Killer.State = "WaitingForCharacter"; return
    end
    if now - Killer.lastCheck > CONFIG.KILLER_TARGET_RECHECK then
        Killer.lastCheck = now
        local tHum = Killer.target and Killer.target.Parent and Killer.target.Parent:FindFirstChildOfClass("Humanoid")
        if not (tHum and tHum.Health > 0) then
            local p = findNearestSurvivor()
            Killer.targetPlayer = p
            Killer.target = p and getPlayerRoot(p) or nil
        end
    end
    if not Killer.target or not Killer.target.Parent then
        Killer.State = "Idle"; Movement:clear("killer idle"); return
    end
    local d = dist(root, Killer.target)
    if d <= CONFIG.KILLER_HIT_RANGE + CONFIG.KILLER_HIT_TOL then
        Killer.State = "Attacking"
        Movement:clear("killer attack")
        local uid = Killer.targetPlayer and Killer.targetPlayer.UserId or 0
        local hits = Killer.hitCount[uid] or 0
        if hits < CONFIG.KILLER_MAX_HITS and (now - Killer.lastHitT) > CONFIG.KILLER_HIT_COOLDOWN then
            Killer.lastHitT = now
            Killer.hitCount[uid] = hits + 1
            TriggerMobileButton()
        end
        if (Killer.hitCount[uid] or 0) >= CONFIG.KILLER_MAX_HITS then
            Killer.target = nil; Killer.targetPlayer = nil; Killer.State = "Idle"
        end
    else
        Killer.State = "Chasing"
        Movement:setTarget(Killer.target.Position, "chase")
        Movement:step(now)
    end
end

-- ============================================================================
-- ROLE WATCHER + MAIN LOOP
-- ============================================================================
local currentRole = nil
local mainConn = nil
local lastDecision = 0
local lastGuiCheck = 0

local function getCurrentRole()
    local team = localPlayer.Team
    if team then
        if team.Name == "Survivors" or team.Name == "Survivor" then return "Survivor" end
        if team.Name == "Killers" or team.Name == "Killer" then return "Killer" end
    end
    return "Spectator"
end

local function onRoleChange(oldRole, newRole)
    log(string.format("Role: %s → %s", tostring(oldRole), tostring(newRole)))
    resetActionState()
    resetThreat()
    resetFlee()
    resetDecision()
    Movement:abandonTarget("role change")
    Movement.failedTargets = {}
    Survivor.State = "WaitingForCharacter"
    Killer.State = "WaitingForCharacter"
    Survivor.progressWatch = nil
    releaseShift()
    if newRole == "Survivor" then
        loadExternalSkillcheck()
    end
end

local function startMain()
    if mainConn then return end
    mainConn = RunService.Heartbeat:Connect(function()
        local now = tick()

        -- GUI refresh
        if now - lastGuiCheck > CONFIG.GUI_CHECK_INTERVAL then
            lastGuiCheck = now
            if not (readyGui and readyGui.Parent) then createReadyGui() end
        end

        -- Role detection
        local role = getCurrentRole()
        if role ~= currentRole then
            local old = currentRole
            currentRole = role
            onRoleChange(old, role)
        end

        -- Label update
        if readyLabel and readyLabel.Parent then
            local extra = ""
            if role == "Survivor" then
                extra = string.format(" [%s] %s", Survivor.State, Decision.intent or "-")
            elseif role == "Killer" then
                extra = string.format(" [%s]", Killer.State)
            end
            readyLabel.Text = "AI ["..tostring(role).."]"..extra
        end

        -- Health
        local hum = getHumanoid()
        if not hum or hum.Health <= 0 then
            Movement:clear("dead")
            releaseShift()
            resetActionState()
            return
        end

        -- Run AI
        if role == "Survivor" then
            local ok, err = pcall(SurvivorAI, now)
            if not ok then log("SurvivorAI err:", err) end
        elseif role == "Killer" then
            local ok, err = pcall(KillerAI, now)
            if not ok then log("KillerAI err:", err) end
        else
            Movement:clear("spectator")
            releaseShift()
            resetActionState()
        end
    end)
    log("Main loop started")
end

-- Character lifecycle
localPlayer.CharacterAdded:Connect(function()
    task.wait(0.2)
    resetActionState()
    resetThreat()
    resetFlee()
    resetDecision()
    Movement:abandonTarget("respawn")
    Movement.failedTargets = {}
    Survivor.State = "WaitingForCharacter"
    Killer.State = "WaitingForCharacter"
    Survivor.progressWatch = nil
    createReadyGui()
    bindCommonRemotes()
end)

localPlayer.CharacterRemoving:Connect(function()
    Movement:abandonTarget("removing")
    releaseShift()
    resetActionState()
end)

-- ============================================================================
-- BOOT
-- ============================================================================
bindCommonRemotes()
startMain()
loadExternalSkillcheck()

_G.KemiAI_Stop = function()
    if mainConn then mainConn:Disconnect(); mainConn = nil end
    Movement:abandonTarget("stop")
    releaseShift()
    resetActionState()
    resetThreat()
    resetFlee()
    resetDecision()
    if readyGui then pcall(function() readyGui:Destroy() end); readyGui = nil; readyLabel = nil end
    log("Stopped")
end

log("AI ready — R4 Stable Navigation loaded")
