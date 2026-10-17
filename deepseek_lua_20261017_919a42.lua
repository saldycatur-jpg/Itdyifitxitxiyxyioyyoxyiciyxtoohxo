-- ============================================================================
-- KEMI // PLAY AI — Stable Path + Survivor Actions (R5)
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

    KILLER_DETECT_RANGE  = 300,
    KILLER_HIT_RANGE     = 6,
    KILLER_HIT_TOL       = 1,
    KILLER_MAX_HITS      = 2,
    KILLER_HIT_COOLDOWN  = 1.2,
    KILLER_TARGET_RECHECK= 0.5,

    SURV_GEN_DETECT      = 10000,
    SURV_GEN_ACTION_R    = 5,
    SURV_REGEN_INTERVAL  = 3.0,
    SURV_GEN_NO_PROGRESS = 3.0,
    SURV_STUCK_WATCHDOG  = 10.0,
    SEARCH_STUCK_LOG     = 5.0,

    SURVIVOR_DETECT_RANGE = 200,
    HEAL_SAFE_DIST        = 50,
    UNHOOK_SAFE_DIST      = 50,
    HEAL_INTERACT_R       = 5,
    UNHOOK_INTERACT_R     = 6,
    SELF_HEAL_INTERVAL    = 0.5,

    THREAT_WARNING_DIST  = 160,
    THREAT_ENTER_DIST    = 115,
    THREAT_EXIT_DIST     = 180,
    THREAT_EMERGENCY_D   = 45,
    THREAT_RAPID_CLOSE   = 8,
    THREAT_SAMPLE_INT    = 0.08,
    THREAT_SAMPLE_COUNT  = 6,
    THREAT_CLEAR_TIME    = 1.5,
    THREAT_HEADING_DOT   = 0.55,
    THREAT_P_ENTER       = 0.55,
    THREAT_P_EXIT        = 0.30,
    THREAT_TTC_HORIZON   = 6.0,
    THREAT_W = {
        bias = -4.2, w_distance = 3.8, w_closing = 2.5,
        w_heading = 1.6, w_ttc = 1.2, w_pathRisk = 0.8,
    },
    ROUTE_W = {
        w_length = 1.0, w_exposure = 2.2, w_deadEnd = 0.6,
        w_switch = 0.8, w_safety = 1.4,
    },
    ROUTE_REF_LEN = 100,

    FLEE_DISTANCE        = 45,
    FLEE_MIN_DIST_KILLER = 40,
    FLEE_REPICK_INTERVAL = 1.5,
    FLEE_COMMIT_TIME     = 0.8,
    FLEE_REACHED_RADIUS  = 6,
    FLEE_SAFE_GEN_MAX    = 220,

    REPATH_INTERVAL      = 3.0,
    REPATH_DIST_THRESH   = 20,
    WAYPOINT_REACH_DIST  = 4.5,
    WAYPOINT_SKIP_DIST   = 5.0,
    WAYPOINT_TIMEOUT     = 1.2,
    PATH_FAIL_THRESHOLD  = 3,
    PATH_FAIL_COOLDOWN   = 10,
    PATH_CACHE_TTL       = 2.0,
    PATH_RETRY_INTERVAL  = 0.5,
    PATH_MAX_INFLIGHT    = 5,

    NAV_STUCK_TIME       = 0.8,
    NAV_PROGRESS_EPS     = 0.5,
    NAV_MAX_RECOVERIES   = 3,
    NAV_LOG_INTERVAL     = 2.0,
    NAV_SIDESTEP_DIST    = 8,
    NAV_SIDESTEP_TIME    = 0.35,
    NAV_STUCK_TO_SIDE    = 1,

    RAYCAST_DIST         = 12,
    GUI_CHECK_INTERVAL   = 2.0,

    GEN_SWITCH_MARGIN    = 60,
    GEN_RESCAN_COOLDOWN  = 6.0,

    SKILLCHECK_SCRIPT_URL = "",
    SKILLCHECK_SNAP_OFF     = 109,
    SKILLCHECK_TRIGGER_START= 104,
    SKILLCHECK_TRIGGER_END  = 118,
    TRIGGER_INTERVAL        = 0.05,

    GEN_PROGRESS_WEIGHT  = 0.6,
    GEN_KILLER_SAFE_DIST = 60,
    GEN_KILLER_PENALTY   = 8,
    GEN_DISCOVERY_DEPTH  = 5,
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

local TouchID = CONFIG.TOUCH_ID

local config = _G.config
if type(config) ~= "table" then config = {} end
if config.autoSkillCheckEnabled == nil then config.autoSkillCheckEnabled = true end

local function nlog(fmt, ...)
    if CONFIG.DEBUG_NAV then print("[KemiAI-nav]", string.format(fmt, ...)) end
end

-- ============================================================================
-- REMOTE / GEN DONE
-- ============================================================================
local function findRemoteInReplicatedStorage(...)
    local paths = { ... }
    for _, path in ipairs(paths) do
        local cur = ReplicatedStorage
        local ok = true
        for seg in string.gmatch(path, "[^%.]+") do
            cur = cur and cur:FindFirstChild(seg)
            if not cur then ok = false; break end
        end
        if ok and cur then return cur end
    end
    return nil
end

local function fireRemoteSafe(remote, ...)
    if not remote then return false end
    local ok, err = pcall(function()
        if remote:IsA("RemoteEvent") then
            remote:FireServer(...)
        elseif remote:IsA("BindableEvent") then
            remote:Fire(...)
        else
            error("not RemoteEvent/Bindable")
        end
    end)
    if not ok then dlog("remote fire error:", err) end
    return ok
end

local GenDoneRemote = nil
local function getGenDoneRemote()
    if GenDoneRemote and GenDoneRemote.Parent then return GenDoneRemote end
    GenDoneRemote = findRemoteInReplicatedStorage(
        "Remotes.Generator.GenDone",
        "Generator.GenDone",
        "GenDone"
    )
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
    fireRemoteSafe(rem)
    log("GenDone: fired")
end

-- ============================================================================
-- FORWARD DECLS
-- ============================================================================
local Survivor
local Killer

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
local function posKey(pos)
    if not pos then return "nil" end
    return string.format("%.1f|%.1f|%.1f", pos.X, pos.Y, pos.Z)
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
    local hit = workspace:Raycast(fromPos, delta.Unit * probeLen, params)
    return hit == nil
end

local function checkSelfState()
    local ch = getChar()
    local hum = getHumanoid()
    if not ch or not hum then return "unknown" end
    if hum.Health <= 0 then return "dead" end
    if ch:GetAttribute("IsHooked") == true then return "hooked" end
    if ch:GetAttribute("IsCarried") == true then return "carried" end
    local ragdoll = ch:FindFirstChild("RagdollTrigger")
    if ragdoll and ragdoll:IsA("BoolValue") and ragdoll.Value == true then
        return "downed"
    end
    if hum.Health <= 50 then return "injured" end
    return "healthy"
end

-- ============================================================================
-- SKILLCHECK STATE (dideklarasikan SEBELUM pressActionButton)
-- ============================================================================
local SkillState = {
    active = false,
    bindName = "KemiAI_SkillCheck_Trigger",
    triggerInterval = CONFIG.TRIGGER_INTERVAL,
    lastTrigger = 0,
    triggerCount = 0,
    visConn = nil,
    promptConn = nil,
    currentCheck = nil,
}

-- ============================================================================
-- ACTIONS MODULE
-- ============================================================================
local Actions = {}
local ActionState = {
    lastHealPress = 0,
    lastUnhookPress = 0,
    lastRepairPress = 0,
}

local function setLocalAttr(key, val)
    local ch = getChar()
    if ch then pcall(function() ch:SetAttribute(key, val) end) end
end

-- Primary action button trigger (SKIP jika skill check aktif)
local function pressActionButton()
    -- CRITICAL: jangan menekan action button saat skill check aktif
    if SkillState.active then
        return false
    end

    local b = nil
    local pg = localPlayer:FindFirstChild("PlayerGui")
    if not pg then return false end

    for _, path in ipairs(CONFIG.ACTION_PATHS) do
        local current = pg
        for segment in string.gmatch(path, "[^%.]+") do
            current = current and current:FindFirstChild(segment)
        end
        if current and current:IsA("GuiObject") and current.Visible then
            local sz = current.AbsoluteSize
            if sz.X > 0 and sz.Y > 0 then
                b = current
                break
            end
        end
    end

    if not b then return false end

    local p, s, i = b.AbsolutePosition, b.AbsoluteSize, GuiService:GetGuiInset()
    local cx = p.X + (s.X / 2) + i.X
    local cy = p.Y + (s.Y / 2) + i.Y
    pcall(function()
        VirtualInputManager:SendTouchEvent(TouchID, 0, cx, cy)
        task.wait(0)
        VirtualInputManager:SendTouchEvent(TouchID, 2, cx, cy)
    end)
    return true
end

function Actions.startRepair()
    setLocalAttr("isRepairing", true)
    ActionState.lastRepairPress = tick()
    pressActionButton()
end
function Actions.stopRepair()
    setLocalAttr("isRepairing", false)
    pressActionButton()
end
function Actions.startHeal()
    setLocalAttr("isHealing", true)
    ActionState.lastHealPress = tick()
    pressActionButton()
end
function Actions.stopHeal()
    setLocalAttr("isHealing", false)
    pressActionButton()
    local reset = findRemoteInReplicatedStorage(
        "Remotes.Healing.Reset", "Healing.Reset", "Remotes.HealReset"
    )
    if reset then fireRemoteSafe(reset) end
end
function Actions.startUnhook()
    setLocalAttr("isUnhooking", true)
    ActionState.lastUnhookPress = tick()
    pressActionButton()
end
function Actions.stopUnhook()
    setLocalAttr("isUnhooking", false)
    pressActionButton()
end
function Actions.startVault()
    setLocalAttr("isVaulting", true)
    pressActionButton()
end
function Actions.startPalletSlide()
    setLocalAttr("isSliding", true)
    pressActionButton()
end
function Actions.startPalletDrop()
    setLocalAttr("isDroppingPallet", true)
    pressActionButton()
end
function Actions.startExit()
    setLocalAttr("isExiting", true)
    pressActionButton()
end
function Actions.stopExit()
    setLocalAttr("isExiting", false)
    pressActionButton()
end
function Actions.fireSelfUnhook()
    local rem = findRemoteInReplicatedStorage(
        "Remotes.SelfUnHookEvent", "SelfUnHookEvent",
        "Remotes.Survivor.SelfUnHookEvent"
    )
    if rem then fireRemoteSafe(rem) end
    pressActionButton()
end
function Actions.fireResetHeal()
    local rem = findRemoteInReplicatedStorage(
        "Remotes.Healing.Reset", "Healing.Reset"
    )
    if rem then fireRemoteSafe(rem) end
end
function Actions.fireStopEmote()
    local rem = findRemoteInReplicatedStorage(
        "Remotes.EmoteHandler", "EmoteHandler",
        "Remotes.Survivor.EmoteHandler"
    )
    if rem then fireRemoteSafe(rem) end
end

function Actions.bindCommonRemotes()
    local map = {
        { names = { "Remotes.RepairAnim", "RepairAnim" }, attr = "isRepairing" },
        { names = { "Remotes.HealAnim", "HealAnim" }, attr = "isHealing" },
        { names = { "Remotes.VaultEvent", "VaultEvent" }, attr = "isVaulting" },
        { names = { "Remotes.PalletSlideEvent", "PalletSlideEvent" }, attr = "isSliding" },
        { names = { "Remotes.PalletDropEvent", "PalletDropEvent" }, attr = "isDroppingPallet" },
        { names = { "Remotes.HookPhase", "HookPhase" }, attr = nil },
    }
    for _, entry in ipairs(map) do
        local rem = findRemoteInReplicatedStorage(table.unpack(entry.names))
        if rem and rem:IsA("RemoteEvent") then
            pcall(function()
                rem.OnClientEvent:Connect(function()
                    if entry.attr then
                        setLocalAttr(entry.attr, false)
                    end
                end)
            end)
        end
    end
end

-- ============================================================================
-- GUI
-- ============================================================================
local readyGui, readyLabel = nil, nil

local function createReadyGui()
    if readyGui and readyGui.Parent then pcall(function() readyGui:Destroy() end) end
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
    if readyGui and readyGui.Parent == pg and readyLabel and readyLabel.Parent == readyGui then return end
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
    if n == "Killers" or n == "Killer" then return "Killer" end
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
    for _, k in ipairs({"Role","Team","RoleName","GameRole"}) do
        local ok, v = pcall(function() return localPlayer:GetAttribute(k) end)
        if ok then local r = matchRoleName(v); if r then return r end end
    end
    local char = getChar()
    if char then
        for _, k in ipairs({"Role","Team","RoleName","GameRole"}) do
            local ok, v = pcall(function() return char:GetAttribute(k) end)
            if ok then local r = matchRoleName(v); if r then return r end end
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
-- SKILLCHECK (Native Trigger)
-- ============================================================================
local Skill = { rsConn = nil }  -- compat stub

local function TriggerSkillCheckButton()
    local current = localPlayer:FindFirstChild("PlayerGui")
    if not current then return false end
    for _, seg in ipairs({"Survivor-mob", "Controls", "action", "check"}) do
        current = current and current:FindFirstChild(seg)
    end
    if not current or not current:IsA("GuiObject") then return false end
    if not current.Visible then return false end
    local sz = current.AbsoluteSize
    if sz.X <= 0 or sz.Y <= 0 then return false end
    local p, s, i = current.AbsolutePosition, current.AbsoluteSize, GuiService:GetGuiInset()
    local cx = p.X + (s.X / 2) + i.X
    local cy = p.Y + (s.Y / 2) + i.Y
    pcall(function()
        VirtualInputManager:SendTouchEvent(CONFIG.TOUCH_ID, 0, cx, cy)
        VirtualInputManager:SendTouchEvent(CONFIG.TOUCH_ID, 2, cx, cy)
    end)
    return true
end

local function stopSkillCheckBinding()
    pcall(function() RunService:UnbindFromRenderStep(SkillState.bindName) end)
    SkillState.active = false
    SkillState.currentCheck = nil
    if SkillState.visConn then
        pcall(function() SkillState.visConn:Disconnect() end)
        SkillState.visConn = nil
    end
end

local function startSkillCheckBinding(check)
    if not check then return end
    stopSkillCheckBinding()
    SkillState.currentCheck = check

    -- Snap Line ke Goal + offset sekali
    local line = check:FindFirstChild("Line")
    local goal = check:FindFirstChild("Goal")
    if line and goal then
        local gr = goal.Rotation % 360
        line.Rotation = (gr + CONFIG.SKILLCHECK_SNAP_OFF) % 360
    end

    SkillState.lastTrigger = 0
    SkillState.triggerCount = 0
    SkillState.active = true

    RunService:BindToRenderStep(SkillState.bindName, Enum.RenderPriority.Last.Value, function()
        local s = SkillState
        if not s.active then return end
        local c = s.currentCheck
        if not c or not c.Parent or not c.Visible then return end

        local ln = c:FindFirstChild("Line")
        local gl = c:FindFirstChild("Goal")
        if not ln or not gl then return end

        local lr = ln.Rotation % 360
        local gr = gl.Rotation % 360
        local ss = (gr + CONFIG.SKILLCHECK_TRIGGER_START) % 360
        local se = (gr + CONFIG.SKILLCHECK_TRIGGER_END) % 360
        local inRange = false
        if ss > se then
            if lr >= ss or lr <= se then inRange = true end
        else
            if lr >= ss and lr <= se then inRange = true end
        end

        if inRange then
            local now = tick()
            if now - s.lastTrigger >= s.triggerInterval then
                s.lastTrigger = now
                s.triggerCount = s.triggerCount + 1
                TriggerSkillCheckButton()
            end
        end
    end)
end

local function bindSkillCheck(check)
    if not check then return end
    if SkillState.visConn then
        pcall(function() SkillState.visConn:Disconnect() end)
        SkillState.visConn = nil
    end
    SkillState.visConn = check:GetPropertyChangedSignal("Visible"):Connect(function()
        if localPlayer.Team and localPlayer.Team.Name == "Survivors" and check.Visible then
            startSkillCheckBinding(check)
        else
            stopSkillCheckBinding()
        end
    end)
    if check.Visible and localPlayer.Team and localPlayer.Team.Name == "Survivors" then
        startSkillCheckBinding(check)
    end
end

local function InitializeAutobuy()
    if not config.autoSkillCheckEnabled then
        log("Skillcheck: disabled by config")
        return
    end

    stopSkillCheckBinding()
    if SkillState.promptConn then
        pcall(function() SkillState.promptConn:Disconnect() end)
        SkillState.promptConn = nil
    end

    task.spawn(function()
        local pg = localPlayer:FindFirstChild("PlayerGui")
        if not pg then return end
        local prompt = pg:FindFirstChild("SkillCheckPromptGui")
        if not prompt then prompt = pg:WaitForChild("SkillCheckPromptGui", 10) end
        if not prompt then log("Skillcheck: prompt GUI not found"); return end

        local existingCheck = prompt:FindFirstChild("Check")
        if existingCheck then bindSkillCheck(existingCheck) end

        SkillState.promptConn = prompt.ChildAdded:Connect(function(child)
            if child.Name == "Check" then
                task.wait(0.05)
                bindSkillCheck(child)
            end
        end)

        log("Skillcheck: native trigger initialized")
    end)
end

-- ============================================================================
-- L1 — PERCEPTION
-- ============================================================================
local Perception = { smoothClosing = 0, lastKD = nil, lastSampleT = 0 }

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
        if dt > 0.01 then instant = (Perception.lastKD - kD) / dt end
    end
    Perception.lastKD = kD
    Perception.lastSampleT = now
    local alpha = 0.35
    Perception.smoothClosing = Perception.smoothClosing * (1 - alpha) + instant * alpha
    local closing = Perception.smoothClosing
    local headingDot = 0
    local v = killerRoot.AssemblyLinearVelocity
    if v and v.Magnitude > 2 then
        local toMe = myRoot.Position - killerRoot.Position
        if toMe.Magnitude > 0.5 then headingDot = clamp(v.Unit:Dot(toMe.Unit), 0, 1) end
    end
    local ttc = math.huge
    if closing > 1 then ttc = kD / closing end
    local pathRisk = 0
    if Survivor and Survivor.approachPos then
        local dKTarget = (Survivor.approachPos - killerRoot.Position).Magnitude
        pathRisk = clamp(1 - dKTarget / CONFIG.GEN_KILLER_SAFE_DIST, 0, 1)
    end
    return { kD = kD, closing = closing, headingDot = headingDot, ttc = ttc,
             pathRisk = pathRisk, killerRoot = killerRoot, myRoot = myRoot }
end

-- ============================================================================
-- L2 — WEIGHTED MODELS
-- ============================================================================
local function computeThreatProbability(f)
    if not f then return 0 end
    local xDistance = clamp(1 - f.kD / CONFIG.THREAT_WARNING_DIST, 0, 1)
    local xClosing  = clamp(f.closing / 40, -1, 1)
    local xHeading  = f.headingDot
    local xTTC = 0
    if f.ttc < CONFIG.THREAT_TTC_HORIZON and f.ttc > 0 then
        xTTC = clamp(1 - f.ttc / CONFIG.THREAT_TTC_HORIZON, 0, 1)
    end
    local W = CONFIG.THREAT_W
    local z = W.bias
        + W.w_distance * xDistance
        + W.w_closing  * xClosing
        + W.w_heading  * xHeading
        + W.w_ttc      * xTTC
        + W.w_pathRisk * f.pathRisk
    if f.kD <= CONFIG.THREAT_EMERGENCY_D then return 1.0 end
    return sigmoid(z)
end

local function routeCost(candidatePos, pathLen, killerPos, isSwitch)
    local W = CONFIG.ROUTE_W
    local normLen = clamp(pathLen / CONFIG.ROUTE_REF_LEN, 0, 2)
    local exposure, safety = 0, 0
    if killerPos then
        local dEnd = (candidatePos - killerPos).Magnitude
        exposure = clamp(1 - dEnd / CONFIG.GEN_KILLER_SAFE_DIST, 0, 1)
        safety   = clamp(dEnd / CONFIG.FLEE_MIN_DIST_KILLER, 0, 1)
    end
    return W.w_length * normLen + W.w_exposure * exposure
         + W.w_deadEnd * 0 + W.w_switch * (isSwitch and 1 or 0)
         - W.w_safety * safety
end

-- ============================================================================
-- L4 — NAVIGATION CONTROLLER
-- ============================================================================
local PATH = {
    state = "Idle", inFlightTarget = nil, pendingTarget = nil,
    lastFailReason = nil, lastFailT = 0, lastFailLogT = 0,
    computeCount = 0, failCount = 0,
}

local function resetPathState()
    PATH.state = "Idle"
    PATH.inFlightTarget = nil
    PATH.pendingTarget = nil
    PATH.lastFailReason = nil
    PATH.lastFailT = 0
end

local function setPathState(s, targetPos)
    if PATH.state ~= s then
        PATH.state = s
        nlog("PATH state → %s", s)
    end
end

local MOVE = {
    waypoints = {}, index = 1,
    lastRepath = 0, lastTargetPos = nil,
    lastPos = nil, stuckSince = 0,
    stuckLogT = 0, consecutiveFails = 0,
    failTargetKey = nil, failedTargets = {},
    lastFailLog = 0, jumpCooldown = 0,
    sideStepUntil = 0, sideStepDir = nil,
    stuckCount = 0, blockedConn = nil,
    pathMemo = {}, lastMoveToTarget = nil,
}

local function clearBlockedListener()
    if MOVE.blockedConn then
        pcall(function() MOVE.blockedConn:Disconnect() end)
        MOVE.blockedConn = nil
    end
end

local function resetMove()
    MOVE.waypoints = {}
    MOVE.index = 1
    MOVE.lastTargetPos = nil
    MOVE.lastPos = nil
    MOVE.stuckSince = 0
    MOVE.lastMoveToTarget = nil
    clearBlockedListener()
    if PATH.state == "Following" then setPathState("Idle") end
end

local function stopMoving()
    local hum = getHumanoid()
    if hum then hum:Move(Vector3.zero, false) end
    resetMove()
end

local function installWaypoints(targetPos, path)
    MOVE.waypoints = path:GetWaypoints()
    MOVE.index = 1
    MOVE.lastRepath = tick()
    MOVE.lastTargetPos = targetPos
    MOVE.stuckSince = 0
    MOVE.consecutiveFails = 0
    MOVE.failTargetKey = nil
    setPathState("Following", targetPos)
    nlog("WaypointsInstalled count=%d", #MOVE.waypoints)
end

local function handlePathFailure(targetPos, reason)
    MOVE.waypoints = {}
    MOVE.index = 1
    MOVE.lastRepath = tick()
    MOVE.lastTargetPos = targetPos
    PATH.lastFailReason = reason
    PATH.lastFailT = tick()
    PATH.failCount = PATH.failCount + 1
    setPathState("Failed", targetPos)
    local key = posKey(targetPos)
    if MOVE.failTargetKey == key then
        MOVE.consecutiveFails = MOVE.consecutiveFails + 1
    else
        MOVE.consecutiveFails = 1
        MOVE.failTargetKey = key
    end
    if MOVE.consecutiveFails >= CONFIG.PATH_FAIL_THRESHOLD then
        MOVE.failedTargets[key] = tick()
        MOVE.consecutiveFails = 0
        MOVE.failTargetKey = nil
    end
    local now = tick()
    if now - PATH.lastFailLogT > 1 then
        PATH.lastFailLogT = now
        log(string.format("PathFailed reason=%s consecutive=%d",
            tostring(reason), MOVE.consecutiveFails))
    end
end

local function requestPath(targetPos)
    if not targetPos then return end
    if PATH.state == "Computing" then
        PATH.pendingTarget = targetPos
        return
    end
    local root = getRoot()
    if not root then return end
    local current = targetPos
    local iterations = 0
    while current and iterations < CONFIG.PATH_MAX_INFLIGHT do
        iterations = iterations + 1
        clearBlockedListener()
        setPathState("Computing", current)
        PATH.inFlightTarget = current
        PATH.computeCount = PATH.computeCount + 1
        local path = PathfindingService:CreatePath({
            AgentRadius = 2, AgentHeight = 5,
            AgentCanJump = true, AgentMaxSlope = 45,
            WaypointSpacing = 4,
        })
        local ok = pcall(function() path:ComputeAsync(root.Position, current) end)
        PATH.inFlightTarget = nil
        if PATH.pendingTarget and PATH.pendingTarget ~= current then
            current = PATH.pendingTarget
            PATH.pendingTarget = nil
        else
            PATH.pendingTarget = nil
            if ok and path.Status == Enum.PathStatus.Success then
                installWaypoints(current, path)
                pcall(function()
                    MOVE.blockedConn = path.Blocked:Connect(function(blockedIdx)
                        if blockedIdx and blockedIdx >= (MOVE.index or 1) then
                            MOVE.lastRepath = 0
                        end
                    end)
                end)
            else
                local reason = "compute error"
                if path and path.Status then reason = tostring(path.Status) end
                handlePathFailure(current, reason)
            end
            return
        end
    end
    setPathState("Idle")
    PATH.pendingTarget = nil
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

local function tryPath(fromPos, endPos)
    local k = posKey(fromPos) .. "→" .. posKey(endPos)
    local cached = MOVE.pathMemo[k]
    if cached and (tick() - cached.t) < CONFIG.PATH_CACHE_TTL then
        return cached.ok
    end
    local path = PathfindingService:CreatePath({
        AgentRadius = 2, AgentHeight = 5,
        AgentCanJump = true, AgentMaxSlope = 45,
        WaypointSpacing = 4,
    })
    local ok = pcall(function() path:ComputeAsync(fromPos, endPos) end)
    local success = ok and path.Status == Enum.PathStatus.Success
    MOVE.pathMemo[k] = { t = tick(), ok = success }
    return success
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
    local now = tick()
    local toT = (targetPos - root.Position)
    if toT.Magnitude < 0.5 then return end
    local dir = toT.Unit
    local perp = Vector3.new(-dir.Z, 0, dir.X)
    if MOVE.sideStepDir then perp = -MOVE.sideStepDir end
    MOVE.sideStepDir = perp
    MOVE.sideStepUntil = now + CONFIG.NAV_SIDESTEP_TIME
    hum:MoveTo(root.Position + perp * CONFIG.NAV_SIDESTEP_DIST)
end

local function stepMovement(targetPos)
    local hum = getHumanoid()
    local root = getRoot()
    if not hum or not root or not targetPos then return false end
    hum.WalkSpeed = CONFIG.BASE_WALKSPEED * CONFIG.WALKSPEED_FACTOR
    local now = tick()

    if (root.Position - targetPos).Magnitude <= CONFIG.WAYPOINT_REACH_DIST then
        hum:MoveTo(root.Position)
        if PATH.state == "Following" then setPathState("Idle", targetPos) end
        return true
    end

    if MOVE.sideStepUntil > now then return true end

    if MOVE.lastPos then
        local delta = (root.Position - MOVE.lastPos).Magnitude
        if delta < 0.15 then
            if MOVE.stuckSince == 0 then MOVE.stuckSince = now end
        else
            MOVE.stuckSince = 0
            MOVE.stuckCount = 0
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
    if PATH.state ~= "Computing" then
        if noWaypoints then needRepath = true
        elseif targetMoved then needRepath = true
        elseif isStuck then
            needRepath = true
            MOVE.stuckSince = 0
            MOVE.stuckCount = MOVE.stuckCount + 1
            tryJumpUnstick()
            if MOVE.stuckCount >= CONFIG.NAV_STUCK_TO_SIDE then
                trySideStep(root, targetPos)
                MOVE.stuckCount = 0
            end
        elseif timeValveExpired and (#MOVE.waypoints > 0 and MOVE.index > (#MOVE.waypoints - 1)) then
            needRepath = true
        end
    end

    if needRepath and not isTargetBlacklisted(targetPos) then
        requestPath(targetPos)
    elseif needRepath and isTargetBlacklisted(targetPos) then
        hum:MoveTo(root.Position)
        setPathState("Idle")
        return false
    end

    if PATH.state == "Following" and #MOVE.waypoints > 0 and MOVE.index <= #MOVE.waypoints then
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
            MOVE.lastMoveToTarget = wp.Position
            hum:MoveTo(wp.Position)
        else
            hum:MoveTo(targetPos)
        end
    elseif PATH.state == "Computing" then
        if not MOVE.lastMoveToTarget then
            hum:MoveTo(targetPos)
            MOVE.lastMoveToTarget = targetPos
        end
    elseif PATH.state == "Failed" then
        if hasClearLine(root.Position, targetPos) then
            hum:MoveTo(targetPos)
            MOVE.lastMoveToTarget = targetPos
        else
            trySideStep(root, targetPos)
        end
        if (now - PATH.lastFailT) > CONFIG.PATH_RETRY_INTERVAL then
            if not isTargetBlacklisted(targetPos) then requestPath(targetPos)
            else setPathState("Idle") end
        end
    else
        if not isTargetBlacklisted(targetPos) then requestPath(targetPos) end
    end
    return true
end

-- ============================================================================
-- NAV WATCHDOG
-- ============================================================================
local NAV_WD = { lastPos = nil, lastProgressT = 0, recoveryCount = 0, lastLog = 0 }
local function resetNavWatchdog()
    NAV_WD.lastPos = nil; NAV_WD.lastProgressT = 0
    NAV_WD.recoveryCount = 0; NAV_WD.lastLog = 0
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
        if PATH.state == "Computing" then
            NAV_WD.lastPos = root.Position
            NAV_WD.lastProgressT = now
            return
        end
        NAV_WD.recoveryCount = NAV_WD.recoveryCount + 1
        if now - NAV_WD.lastLog > CONFIG.NAV_LOG_INTERVAL then
            NAV_WD.lastLog = now
            log(string.format("Watchdog: no-progress %.1fs in %s",
                since, tostring(stateName)))
        end
        tryJumpUnstick()
        resetMove()
        if NAV_WD.recoveryCount >= CONFIG.NAV_MAX_RECOVERIES then
            if Survivor and Survivor.targetGen then
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
    for _, k in ipairs({"Role","Team","RoleName","GameRole"}) do
        local ok, v = pcall(function() return p:GetAttribute(k) end)
        if ok then local r = matchRoleName(v); if r then return r end end
    end
    local c = p.Character
    if c then
        for _, k in ipairs({"Role","Team","RoleName","GameRole"}) do
            local ok, v = pcall(function() return c:GetAttribute(k) end)
            if ok then local r = matchRoleName(v); if r then return r end end
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

local function findInjuredSurvivor(myPos, killerPos)
    local best, bestChar, bestPos, bestDist = nil, nil, nil, CONFIG.SURVIVOR_DETECT_RANGE
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= localPlayer and roleOfPlayer(p) == "Survivor" then
            local c = p.Character
            if c then
                local h = c:FindFirstChildOfClass("Humanoid")
                local r = c:FindFirstChild("HumanoidRootPart")
                if h and r and h.Health > 0 and h.Health <= 50 then
                    local canHeal = r:GetAttribute("CanGetHealed") == true
                    local notHooked = c:GetAttribute("IsHooked") ~= true
                    local notCarried = c:GetAttribute("IsCarried") ~= true
                    if canHeal and notHooked and notCarried then
                        local killerFar = true
                        if killerPos then
                            killerFar = (r.Position - killerPos).Magnitude > CONFIG.HEAL_SAFE_DIST
                        end
                        if killerFar then
                            local d = (myPos - r.Position).Magnitude
                            if d < bestDist then
                                bestDist = d
                                best = p
                                bestChar = c
                                bestPos = r.Position
                            end
                        end
                    end
                end
            end
        end
    end
    return best, bestChar, bestPos, bestDist
end

local function findHookedSurvivor(myPos, killerPos)
    local best, bestChar, bestPos, bestDist = nil, nil, nil, CONFIG.SURVIVOR_DETECT_RANGE
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= localPlayer and roleOfPlayer(p) == "Survivor" then
            local c = p.Character
            if c then
                local r = c:FindFirstChild("HumanoidRootPart")
                if r and c:GetAttribute("IsHooked") == true then
                    local killerFar = true
                    if killerPos then
                        killerFar = (r.Position - killerPos).Magnitude > CONFIG.UNHOOK_SAFE_DIST
                    end
                    if killerFar then
                        local d = (myPos - r.Position).Magnitude
                        if d < bestDist then
                            bestDist = d
                            best = p
                            bestChar = c
                            bestPos = r.Position
                        end
                    end
                end
            end
        end
    end
    return best, bestChar, bestPos, bestDist
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
-- SCORE / FIND GENERATOR
-- ============================================================================
local function scoreGenerator(gen, myRoot, killerPos)
    if not gen or not gen.Parent or not myRoot then return math.huge end
    if updateGeneratorProgress(gen) then return math.huge end
    local ap = genApproachPoint(gen)
    if not ap then return math.huge end
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
    local list, listReason = getGeneratorList()
    if #list == 0 then return nil, "list-empty ("..tostring(listReason)..")" end
    local best, bestScore, bestReason = nil, math.huge, ""
    local candidates, complete, noApproach, blacklisted = 0, 0, 0, 0
    local minDist = math.huge
    for _, gen in ipairs(list) do
        if gen.Parent then
            if updateGeneratorProgress(gen) then
                complete = complete + 1
            elseif gen ~= excludedGen then
                local ap = genApproachPoint(gen)
                if ap then
                    if isTargetBlacklisted(ap) then
                        blacklisted = blacklisted + 1
                    else
                        local d = (myRoot.Position - ap).Magnitude
                        if d < minDist then minDist = d end
                        local s = scoreGenerator(gen, myRoot, killerPos)
                        if s < math.huge then
                            candidates = candidates + 1
                            if s < bestScore then
                                bestScore = s
                                best = gen
                                bestReason = string.format("score=%.1f", s)
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
    return nil, string.format("cand=%d complete=%d noApp=%d bl=%d minD=%.0f",
        candidates, complete, noApproach, blacklisted,
        minDist == math.huge and -1 or minDist)
end

-- ============================================================================
-- THREAT TRACKER
-- ============================================================================
local THREAT = { confirmed = false, clearStart = nil, level = "none", P = 0,
    primary = nil, primaryRoot = nil, primaryDist = math.huge, lastLogP = 0 }

local function resetThreat()
    THREAT.confirmed = false
    THREAT.clearStart = nil
    THREAT.level = "none"
    THREAT.P = 0
    THREAT.primary = nil
    THREAT.primaryRoot = nil
    THREAT.primaryDist = math.huge
    resetPerception()
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
    if not myRoot then resetThreat() return nil, nil, math.huge, false, 0 end
    local killers = evaluateKillers()
    if #killers == 0 then
        if THREAT.confirmed then
            if not THREAT.clearStart then THREAT.clearStart = now end
            if now - THREAT.clearStart > CONFIG.THREAT_CLEAR_TIME then
                resetThreat()
            end
        end
        return nil, nil, math.huge, false, 0
    end
    local primary = killers[1]
    local kD = primary.dist
    local killerRoot = primary.root
    local features = perceiveThreat(now, killerRoot)
    local P = computeThreatProbability(features)
    if kD <= CONFIG.THREAT_EMERGENCY_D then P = 1 end
    if not THREAT.confirmed and P >= CONFIG.THREAT_P_ENTER then
        THREAT.confirmed = true
        THREAT.clearStart = nil
        log(string.format("Threat ENTER: d=%.1f P=%.2f", kD, P))
    end
    if THREAT.confirmed and P <= CONFIG.THREAT_P_EXIT then
        if kD > CONFIG.THREAT_EXIT_DIST then
            if not THREAT.clearStart then THREAT.clearStart = now end
            if now - THREAT.clearStart > CONFIG.THREAT_CLEAR_TIME then
                resetThreat()
                return primary.player, killerRoot, kD, false, 0
            end
        else
            THREAT.clearStart = nil
        end
    end
    THREAT.P = P
    THREAT.primary = primary.player
    THREAT.primaryRoot = killerRoot
    THREAT.primaryDist = kD
    return primary.player, killerRoot, kD, THREAT.confirmed, P
end

-- ============================================================================
-- FLEE TARGET
-- ============================================================================
local FLEE = { target = nil, lastPick = 0, lastLog = 0, lastFail = 0,
    lastGen = nil, commitUntil = 0, commitTarget = nil }

local function resetFlee()
    FLEE.target = nil; FLEE.lastPick = 0; FLEE.lastLog = 0
    FLEE.lastFail = 0; FLEE.lastGen = nil
    FLEE.commitUntil = 0; FLEE.commitTarget = nil
end

local function rotateAroundY(v, rad)
    local c, s = math.cos(rad), math.sin(rad)
    return Vector3.new(v.X * c - v.Z * s, 0, v.X * s + v.Z * c)
end

local function pickSafeFleeGenerator(myPos, killerPos, exclude)
    local list = getGeneratorList()
    if #list == 0 then return nil, nil end
    local best, bestPos, bestCost = nil, nil, math.huge
    for _, gen in ipairs(list) do
        if gen.Parent and gen ~= exclude then
            if not updateGeneratorProgress(gen) then
                local ap = genApproachPoint(gen)
                if ap and not isTargetBlacklisted(ap) then
                    local dAI = (myPos - ap).Magnitude
                    if dAI <= CONFIG.FLEE_SAFE_GEN_MAX then
                        local prog = getGenProgress(gen) or 0
                        if tryPath(myPos, ap) then
                            local c = routeCost(ap, dAI * 1.15, killerPos, gen ~= Survivor.targetGen)
                            c = c - prog * 0.002
                            if c < bestCost then bestCost = c; best = gen; bestPos = ap end
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

    if FLEE.target and FLEE.commitTarget == FLEE.target then
        local reached = (myPos - FLEE.target).Magnitude < CONFIG.FLEE_REACHED_RADIUS
        local targetDanger = (FLEE.target - killerPos).Magnitude < dToKiller
        local commitActive = now < FLEE.commitUntil
        local repickReady = (now - FLEE.lastPick) >= CONFIG.FLEE_REPICK_INTERVAL
        if not reached and not targetDanger and (commitActive or not repickReady) then
            return FLEE.target
        end
    end

    if dToKiller < CONFIG.THREAT_EMERGENCY_D then
        local away = Vector3.new(myPos.X - killerPos.X, 0, myPos.Z - killerPos.Z)
        if away.Magnitude < 0.01 then away = Vector3.new(1, 0, 0) end
        away = away.Unit
        local endPos = myPos + away * CONFIG.FLEE_DISTANCE
        FLEE.target = endPos; FLEE.lastPick = now
        FLEE.commitTarget = endPos; FLEE.commitUntil = now + CONFIG.FLEE_COMMIT_TIME
        return endPos
    end

    local safeGen, safePos = pickSafeFleeGenerator(myPos, killerPos, Survivor.targetGen)
    if safeGen and safePos then
        FLEE.target = safePos; FLEE.lastPick = now; FLEE.lastGen = safeGen
        FLEE.commitTarget = safePos; FLEE.commitUntil = now + CONFIG.FLEE_COMMIT_TIME
        return safePos
    end

    local away = Vector3.new(myPos.X - killerPos.X, 0, myPos.Z - killerPos.Z)
    if away.Magnitude < 0.01 then away = Vector3.new(1, 0, 0) end
    away = away.Unit
    local angles = { 0, 45, -45, 90, -90, 135, -135, 180 }
    for _, deg in ipairs(angles) do
        local dir = rotateAroundY(away, math.rad(deg))
        local endPos = myPos + dir * CONFIG.FLEE_DISTANCE
        if (endPos - killerPos).Magnitude >= CONFIG.FLEE_MIN_DIST_KILLER then
            if hasClearLine(myPos, endPos) and tryPath(myPos, endPos) then
                FLEE.target = endPos; FLEE.lastPick = now
                FLEE.commitTarget = endPos; FLEE.commitUntil = now + CONFIG.FLEE_COMMIT_TIME
                return endPos
            end
        end
    end

    local fb = myPos + away * 22
    FLEE.target = fb; FLEE.lastPick = now
    FLEE.commitTarget = fb; FLEE.commitUntil = now + CONFIG.FLEE_COMMIT_TIME
    return fb
end

-- ============================================================================
-- SURVIVOR STATE
-- ============================================================================
Survivor = {
    State = "WaitingForCharacter",
    targetGen = nil, approachPos = nil,
    lastGenScan = 0, lastProgress = nil,
    lastProgressT = 0, failedGens = {},
    lastLoggedGen = nil, lastNoGenLog = 0,
    lastStateLog = 0, lastSearchLog = 0,
    lastSwitchT = 0, searchStateSince = 0, lastSearchDiag = 0,
    helpTarget = nil, helpChar = nil, helpPos = nil,
    lastSelfHealPress = 0,
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
    Survivor.searchStateSince = 0
    Survivor.lastSearchDiag = 0
    Survivor.helpTarget = nil
    Survivor.helpChar = nil
    Survivor.helpPos = nil
    Survivor.lastSelfHealPress = 0
    resetMove(); resetFlee(); resetNavWatchdog()
    resetPerception(); resetPathState()
    notifyRepairEnded()
    releaseShift()
end

local function setSurvivorState(newState, now, extraLog)
    if Survivor.State ~= newState then
        log(string.format("Survivor state: %s → %s %s",
            Survivor.State, newState, extraLog or ""))
        Survivor.lastStateLog = now
        Survivor.State = newState
        if newState ~= "SearchingGenerator" then
            Survivor.searchStateSince = 0
        end
    end
end

local function survivorPickGenerator(now, killerPos, exclude)
    local myRoot = getRoot()
    if not myRoot then return false end
    local current = Survivor.targetGen
    local currentValid = current and current.Parent and not updateGeneratorProgress(current)
    local currentScore = currentValid and scoreGenerator(current, myRoot, killerPos) or math.huge
    local currentBlacklisted = currentValid and isTargetBlacklisted(Survivor.approachPos or Vector3.zero)

    if currentValid and currentScore < math.huge and not currentBlacklisted then
        if (now - Survivor.lastSwitchT) > CONFIG.GEN_RESCAN_COOLDOWN then
            local newGen, reason = findBestGenerator(myRoot, killerPos, exclude)
            if newGen and newGen ~= current then
                local newScore = scoreGenerator(newGen, myRoot, killerPos)
                if newScore < currentScore - CONFIG.GEN_SWITCH_MARGIN then
                    Survivor.targetGen = newGen
                    Survivor.approachPos = genApproachPoint(newGen)
                    Survivor.lastSwitchT = now
                    log(string.format("Survivor: switch → %s (Δ=%.1f)",
                        newGen:GetFullName(), currentScore - newScore))
                    return true
                end
            end
        end
        Survivor.lastGenScan = now
        if Survivor.lastLoggedGen ~= current then
            Survivor.lastLoggedGen = current
            log(string.format("Survivor: retain gen %s", current:GetFullName()))
        end
        return true
    end

    local g, reason = findBestGenerator(myRoot, killerPos, exclude)
    if not g then
        if currentValid then
            Survivor.lastGenScan = now
            if now - Survivor.lastNoGenLog > 3 then
                Survivor.lastNoGenLog = now
                log(string.format("Survivor: pick failed (%s) — retaining %s",
                    tostring(reason), current:GetFullName()))
            end
            return true
        end
        if now - Survivor.lastNoGenLog > 3 then
            Survivor.lastNoGenLog = now
            log("Survivor: no valid gen | "..tostring(reason))
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
        log(string.format("Survivor: picked gen %s (%s)", g:GetFullName(), reason))
    end
    return true
end

local function SurvivorAI(now)
    local hum = getHumanoid()
    local root = getRoot()
    if not hum or not root or hum.Health <= 0 then
        setSurvivorState("WaitingForCharacter", now)
        releaseShift()
        return
    end

    if Survivor.State == "SearchingGenerator" then
        if Survivor.searchStateSince == 0 then Survivor.searchStateSince = now end
        if now - Survivor.searchStateSince > CONFIG.SEARCH_STUCK_LOG
            and now - Survivor.lastSearchDiag > CONFIG.SEARCH_STUCK_LOG then
            Survivor.lastSearchDiag = now
            local list, reason = getGeneratorList()
            log(string.format("[SearchDiag] stuck %.1fs | list=%d reason=%s",
                now - Survivor.searchStateSince, #list, tostring(reason)))
        end
    end

    local selfState = checkSelfState()
    if selfState == "hooked" then
        setSurvivorState("Hooked", now)
        releaseShift()
        stopMoving()
        return
    end
    if selfState == "carried" then
        setSurvivorState("Carried", now)
        releaseShift()
        stopMoving()
        return
    end

    local killer, killerRoot, kD, threat, P = updateThreat(now)
    if threat and killerRoot then
        local wasRepairing = (Survivor.State == "InteractingWithGenerator") or Repair.active
        local wasHealing = (Survivor.State == "HealingSurvivor") or (Survivor.State == "SelfHealing")
        if wasRepairing then
            Actions.stopRepair()
            fireGenDone()
            notifyRepairEnded()
        end
        if wasHealing then
            Actions.stopHeal()
        end
        if Survivor.State ~= "EvadingKiller" then
            setSurvivorState("EvadingKiller", now,
                string.format("(d=%.1f P=%.2f)", kD, P or 0))
        end
        releaseShift()
        local fleeTarget = pickFleeTarget(root, killerRoot)
        holdShift()
        stepMovement(fleeTarget)
        navWatchdog(now, true, "EvadingKiller")
        return
    end

    if Survivor.State == "EvadingKiller" then
        log("Survivor: evade done → resume")
        setSurvivorState("SearchingGenerator", now)
        Survivor.lastGenScan = 0
        Survivor.lastLoggedGen = nil
        resetFlee(); resetNavWatchdog(); resetPathState(); resetMove()
    end

    if selfState == "downed" then
        setSurvivorState("SelfHealing", now)
        releaseShift()
        stopMoving()
        if now - Survivor.lastSelfHealPress > CONFIG.SELF_HEAL_INTERVAL then
            Survivor.lastSelfHealPress = now
            Actions.startHeal()
        end
        return
    end

    if Survivor.State == "AllDone" then
        if now - Survivor.lastGenScan > 3 then
            Survivor.lastGenScan = now
            local g = findBestGenerator(getRoot(), nil)
            if g then
                setSurvivorState("SearchingGenerator", now)
                Survivor.lastLoggedGen = nil
            end
        end
        releaseShift(); stopMoving()
        navWatchdog(now, false, "AllDone")
        return
    end

    local killers = evaluateKillers()
    local killerPos = (#killers > 0) and killers[1].root and killers[1].root.Position or nil

    local hookedPlayer, hookedChar, hookedPos, hookedDist =
        findHookedSurvivor(root.Position, killerPos)
    if hookedChar and hookedPos then
        if Survivor.State ~= "GoingToUnhook" or Survivor.helpTarget ~= hookedPlayer then
            setSurvivorState("GoingToUnhook", now,
                string.format("(target=%s d=%.1f)", hookedPlayer.Name, hookedDist))
            Survivor.helpTarget = hookedPlayer
            Survivor.helpChar = hookedChar
            Survivor.helpPos = hookedPos
            resetMove()
        end
        if hookedDist <= CONFIG.UNHOOK_INTERACT_R then
            setSurvivorState("Unhooking", now)
            releaseShift(); stopMoving()
            Actions.startUnhook()
        else
            holdShift()
            stepMovement(hookedPos)
            navWatchdog(now, true, "GoingToUnhook")
        end
        return
    end

    local injuredPlayer, injuredChar, injuredPos, injuredDist =
        findInjuredSurvivor(root.Position, killerPos)
    if injuredChar and injuredPos then
        if Survivor.State ~= "GoingToHeal" or Survivor.helpTarget ~= injuredPlayer then
            setSurvivorState("GoingToHeal", now,
                string.format("(target=%s d=%.1f)", injuredPlayer.Name, injuredDist))
            Survivor.helpTarget = injuredPlayer
            Survivor.helpChar = injuredChar
            Survivor.helpPos = injuredPos
            resetMove()
        end
        if injuredDist <= CONFIG.HEAL_INTERACT_R then
            setSurvivorState("HealingSurvivor", now)
            releaseShift(); stopMoving()
            Actions.startHeal()
        else
            holdShift()
            stepMovement(injuredPos)
            navWatchdog(now, true, "GoingToHeal")
        end
        return
    end

    Survivor.helpTarget = nil
    Survivor.helpChar = nil
    Survivor.helpPos = nil

    local targetLost = (not Survivor.targetGen or not Survivor.targetGen.Parent)
    local targetComplete = Survivor.targetGen and updateGeneratorProgress(Survivor.targetGen)

    if Survivor.State == "SearchingGenerator" or targetLost or targetComplete then
        if not survivorPickGenerator(now, killerPos, nil) then
            local list = getGeneratorList()
            local anyLeft = false
            for _, gg in ipairs(list) do
                if not updateGeneratorProgress(gg) then anyLeft = true; break end
            end
            if not anyLeft and #list > 0 then
                log("Survivor: all generators complete → AllDone")
                setSurvivorState("AllDone", now)
                notifyRepairEnded(); releaseShift(); stopMoving()
            else
                setSurvivorState("SearchingGenerator", now)
                notifyRepairEnded(); releaseShift()
            end
            navWatchdog(now, false, "SearchingGenerator")
            return
        end
        setSurvivorState("MovingToGenerator", now)
    end

    local gen = Survivor.targetGen
    if not gen or not gen.Parent then
        setSurvivorState("SearchingGenerator", now)
        notifyRepairEnded(); releaseShift()
        return
    end

    local prog = getGenProgress(gen)
    if prog and prog >= 100 then
        log("Survivor: gen complete → reselect")
        setSurvivorState("SearchingGenerator", now)
        Survivor.lastGenScan = 0
        Survivor.lastLoggedGen = nil
        notifyRepairEnded(); releaseShift()
        return
    end

    local ap = Survivor.approachPos
    if not ap then
        ap = genApproachPoint(gen)
        Survivor.approachPos = ap
        if not ap then setSurvivorState("SearchingGenerator", now); return end
    end

    local d = (root.Position - ap).Magnitude
    if d <= CONFIG.SURV_GEN_ACTION_R then
        if Survivor.State ~= "InteractingWithGenerator" then
            setSurvivorState("InteractingWithGenerator", now)
            Survivor.lastProgress = getGenProgress(gen)
            Survivor.lastProgressT = now
            notifyRepairStarted()
            Actions.startRepair()
        end
        stopMoving(); releaseShift()
        if now - ActionState.lastRepairPress > 1.0 then
            Actions.startRepair()
        end
        navWatchdog(now, false, "InteractingWithGenerator")
        local curProg = getGenProgress(gen)
        if curProg and Survivor.lastProgress and curProg > Survivor.lastProgress then
            Survivor.lastProgress = curProg
            Survivor.lastProgressT = now
        end
        if now - Survivor.lastProgressT > CONFIG.SURV_GEN_NO_PROGRESS then
            log("Survivor: gen no progress → abandon")
            Survivor.failedGens[gen] = now
            setSurvivorState("SearchingGenerator", now)
            Survivor.lastGenScan = 0
            Survivor.lastLoggedGen = nil
            notifyRepairEnded(); releaseShift()
        end
    else
        if Survivor.State ~= "MovingToGenerator" then
            setSurvivorState("MovingToGenerator", now, string.format("(d=%.1f)", d))
        end
        notifyRepairEnded()
        holdShift()
        local engaged = stepMovement(ap)
        navWatchdog(now, true, "MovingToGenerator")
        if not engaged then
            log("Survivor: nav failed → reselect")
            setSurvivorState("SearchingGenerator", now)
            Survivor.lastGenScan = 0
            Survivor.lastLoggedGen = nil
            resetPathState()
        end
    end
end

-- ============================================================================
-- KILLER AI
-- ============================================================================
Killer = { State = "WaitingForCharacter", target = nil, targetPlayer = nil,
    hitCount = {}, lastHitT = 0, lastCheck = 0 }

local function killerReset()
    Killer.State = "WaitingForCharacter"
    Killer.target = nil
    Killer.targetPlayer = nil
    Killer.hitCount = {}
    Killer.lastHitT = 0
    Killer.lastCheck = 0
    resetMove(); resetPathState(); releaseShift()
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
        Killer.State = "Idle"; stopMoving(); return
    end
    local d = dist(root, target)
    if d <= CONFIG.KILLER_HIT_RANGE + CONFIG.KILLER_HIT_TOL then
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
            Killer.target = nil; Killer.targetPlayer = nil; Killer.State = "Idle"
        end
    else
        Killer.State = "Chasing"
        stepMovement(target.Position)
    end
end

-- ============================================================================
-- TRIGGER BUTTON (compat wrapper)
-- ============================================================================
local ActionDiag = { lastWarn = 0, hits = 0, misses = 0 }

local function TriggerMobileButton()
    local ok = pressActionButton()
    if ok then ActionDiag.hits = ActionDiag.hits + 1
    else ActionDiag.misses = ActionDiag.misses + 1 end
    return ok
end

-- ============================================================================
-- ROLE WATCHER
-- ============================================================================
local currentRole = nil
local roleWatcherConnection = nil
local lastGuiCheck = 0

local function onRoleChange(oldRole, newRole)
    log(string.format("Role: %s → %s", tostring(oldRole), tostring(newRole)))
    survivorReset(); killerReset(); resetThreat()
    resetNavWatchdog(); resetPathState()
    if newRole == "Survivor" then
        if config.autoSkillCheckEnabled then
            log("Skillcheck: arming (external)")
            InitializeAutobuy()
        end
    elseif newRole == "Spectator" then
        notifyRepairEnded(); releaseShift(); stopMoving(); resetFlee()
    end
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
            notifyRepairEnded(); releaseShift(); stopMoving(); return
        end
        if role == "Survivor" then
            local ok, err = pcall(SurvivorAI, now)
            if not ok then log("SurvivorAI error:", err) end
        elseif role == "Killer" then
            local ok, err = pcall(KillerAI, now)
            if not ok then log("KillerAI error:", err) end
        else
            notifyRepairEnded(); stopMoving(); releaseShift()
        end
    end)
    log("Role watcher started")
end

-- ============================================================================
-- INIT
-- ============================================================================
Actions.bindCommonRemotes()

startRoleWatcher()
InitializeAutobuy()

-- ============================================================================
-- LIFECYCLE
-- ============================================================================
localPlayer.CharacterAdded:Connect(function()
    log("CharacterAdded: resetting drivers")
    survivorReset(); killerReset(); resetThreat()
    resetFlee(); resetNavWatchdog(); resetPerception(); resetPathState()
    notifyRepairEnded()
    ensureGuiAlive()
end)

localPlayer.CharacterRemoving:Connect(function()
    notifyRepairEnded(); releaseShift(); stopMoving()
end)

-- ============================================================================
-- KILL SWITCH
-- ============================================================================
_G.KemiAI_Stop = function()
    if roleWatcherConnection then roleWatcherConnection:Disconnect(); roleWatcherConnection = nil end
    if Skill.rsConn then Skill.rsConn:Disconnect(); Skill.rsConn = nil end
    if SkillState.visConn then SkillState.visConn:Disconnect(); SkillState.visConn = nil end
    if SkillState.promptConn then SkillState.promptConn:Disconnect(); SkillState.promptConn = nil end
    pcall(function() RunService:UnbindFromRenderStep(SkillState.bindName) end)
    SkillState.active = false
    notifyRepairEnded(); releaseShift(); stopMoving()
    resetThreat(); resetFlee(); resetNavWatchdog(); resetPathState()
    if readyGui then pcall(function() readyGui:Destroy() end); readyGui = nil; readyLabel = nil end
    log("Stopped")
end

log("AI ready — Stable Path + Survivor