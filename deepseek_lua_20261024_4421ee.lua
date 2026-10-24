-- ============================================================================
-- KEMI // PLAY AI — R27
-- R26 → R27 changes (FOCUSED: ExitLever/Escape + Evasion Freeze):
--   [E1]  scanExitGate → scanExitGates (multi-gate aware, dedup).
--   [E2]  checkExitAvailable → checkExitGates (cache list, rescan on change).
--   [E3]  isGateOpen → isGateVisiblyOpen: only trusts verifiable indicators
--         (Main.CanCollide==false, or GetAttributes() keys that actually exist).
--         leverGoal == nil NO LONGER implies "open".
--   [E4]  handleExitPhase iterates all gates, picks open gate first else the
--         nearest non-open gate with a live leverGoal. Falls back to Finishline
--         only after a short grace when all levers expired.
--   [E5]  handleFinishline is bound to the specific open gate's exitObj, so
--         it can't confuse two finishlines.
--   [V1]  updateChaseAction no longer blocks movement during phase=="stopping".
--   [V2]  driveEvasion now uses setGoal()+followStep() (PathfindingService)
--         for the generator waypoint; direct MoveTo reserved for short
--         validated lateral dodges only.
--   [V3]  Stuck detection blacklists the failed waypoint for a few seconds
--         so repicks don't deterministically reselect the same point.
--   [V4]  EVADE_ENTER_DIST = 70, EVADE_EXIT_DIST = 90, EVADE_WARN_DIST = 110.
--   [V5]  pickEvadeTarget simplified: farthest-from-killer generator first,
--         lateral fallback second, raw-away last.
--   [FIX] Removed two references to undefined global PathMemo.
-- ============================================================================

local Players             = game:GetService("Players")
local RunService          = game:GetService("RunService")
local PathfindingService  = game:GetService("PathfindingService")
local VirtualInputManager = game:GetService("VirtualInputManager")
local GuiService          = game:GetService("GuiService")
local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local CollectionService   = game:GetService("CollectionService")

local localPlayer = Players.LocalPlayer

local function log(...)  print("[KemiAI]", ...) end

-- ============================================================================
-- CONFIG
-- ============================================================================
local CONFIG = {
    DEBUG                = false,
    DEBUG_NAV            = false,
    DEBUG_PATH_VISUAL    = false,

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
    SURV_GEN_HYSTERESIS  = 2.5,
    SURV_GEN_NO_PROGRESS = 3.0,
    SURV_STUCK_WATCHDOG  = 10.0,
    SEARCH_STUCK_LOG     = 5.0,
    SEARCH_STUCK_RESCAN  = 15.0,

    GEN_POINT_PROXIMITY  = 3.5,
    GEN_SLOT_RECHECK     = 1.0,

    THREAT_WARNING_DIST  = 160,
    THREAT_ENTER_DIST    = 115,
    THREAT_EXIT_DIST     = 180,
    THREAT_EMERGENCY_D   = 45,
    THREAT_CLEAR_TIME    = 1.5,
    THREAT_HEADING_DOT   = 0.55,
    THREAT_P_ENTER       = 0.55,
    THREAT_P_EXIT        = 0.30,
    THREAT_TTC_HORIZON   = 6.0,

    -- [R27] Evasion (70-stud response, path-followed)
    EVADE_ENTER_DIST     = 70,
    EVADE_WARN_DIST      = 110,
    EVADE_EXIT_DIST      = 90,
    EVADE_EXIT_CONFIRM   = 1.0,
    EVADE_REPICK_INTERVAL= 2.0,
    EVADE_STUCK_TIMEOUT  = 1.5,
    EVADE_STUCK_EPS      = 1.5,
    EVADE_DODGE_DIST     = 12,
    EVADE_DODGE_COOLDOWN = 0.8,
    EVADE_DODGE_STEP     = 10,
    EVADE_MIN_TARGET_DK  = 20,
    EVADE_MAX_TARGET_DIST= 220,
    EVADE_TARGET_REACH   = 5,
    EVADE_FAILED_TARGET_TTL = 8.0,
    EVADE_KILLER_MOVE_THRESH = 25,

    THREAT_W = {
        bias=-4.2, w_distance=3.8, w_closing=2.5,
        w_heading=1.6, w_ttc=1.2, w_pathRisk=0.8,
    },

    PALLET_DROP_D        = 12,
    VAULT_USE_D          = 14,

    FLEE_DISTANCE        = 45,
    FLEE_MIN_DIST_KILLER = 40,
    FLEE_REPICK_INTERVAL = 1.5,
    FLEE_COMMIT_TIME     = 0.8,
    FLEE_REACHED_RADIUS  = 6,
    FLEE_SAFE_GEN_MAX    = 220,

    WAYPOINT_REACH_DIST  = 3.0,
    WAYPOINT_SKIP_DIST   = 3.5,
    WAYPOINT_Y_TOL       = 2.5,
    GOAL_REPATH_THRESH   = 8.0,
    CHASE_REPATH_THRESH  = 4.0,
    PATH_FAIL_COOLDOWN   = 10,
    PATH_CACHE_TTL       = 2.0,
    PATH_REFRESH_INTERVAL = 5.0,

    NAV_STUCK_TIME       = 2.0,
    NAV_PROGRESS_EPS     = 0.5,
    NAV_LOG_INTERVAL     = 2.0,
    SLOPE_STUCK_Y_TOL    = 1.2,

    AGENT_RADIUS         = 2,
    AGENT_HEIGHT         = 6,
    AGENT_MAX_SLOPE      = 55,
    AGENT_WAYPOINT_SPACING = 2.5,

    RESCUE_DETECT_RANGE  = 10000,
    RESCUE_SAFE_DIST     = 50,
    RESCUE_SAFE_DIST_FAST= 35,
    RESCUE_ACTION_R      = 5,

    RAYCAST_DIST         = 12,
    GUI_CHECK_INTERVAL   = 0.5,

    GEN_SWITCH_MARGIN    = 25,
    GEN_RESCAN_COOLDOWN  = 4.0,
    GEN_PROGRESS_WEIGHT  = 0.6,
    GEN_KILLER_SAFE_DIST = 60,
    GEN_KILLER_PENALTY   = 8,
    GEN_DISCOVERY_DEPTH  = 3,
    GEN_CACHE_TTL        = 3,

    TAP_ID  = 8822,
    HOLD_ID = 8823,

    ACTION_START_TIMEOUT    = 1.5,
    ACTION_START_RETRIES    = 2,
    ACTION_STOP_VERIFY      = 1.0,
    ACTION_STOP_FORCE_CLEAR = 3.0,
    ACTION_FAIL_COOLDOWN    = 1.5,
    ACTION_BUSY_COOLDOWN    = 0.3,
    REPAIR_GIVEUP_TIME      = 3.0,
    REPAIR_PROGRESS_WATCH   = 3.0,
    REPAIR_CONFIRM_GRACE    = 2.0,
    REPAIR_STOP_GRACE       = 2.0,
    REPAIR_NEXT_START_DELAY = 2.0,

    INTERACT_SHIFT_TIMEOUT  = 1.2,
    INTERACT_GUI_TIMEOUT    = 1.4,
    INTERACT_GUI_MAX_RETRY  = 1,
    INTERACT_GUI_RETRY_GAP  = 0.5,

    CHASE_TRIGGER_RADIUS    = 3.5,
    CHASE_APPROACH_TIMEOUT  = 3.0,

    CHASE_VAULT_RANGE       = 25,
    CHASE_VAULT_COMMIT      = 10,
    CHASE_PALLET_RANGE      = 25,
    CHASE_PALLET_COMMIT     = 9,
    CHASE_SCAN_INTERVAL     = 2.5,

    HANG_FAR_DIST           = 50,
    HANG_FORCE_CLEAR_TIME   = 2.5,

    EXIT_INTERACT_R         = 6,
    EXIT_SCAN_INTERVAL      = 1.0,
    FINISH_REACH_DIST       = 8,

    LEVER_INTERACT_TIMEOUT  = 15.0,
    LEVER_APPROACH_TIMEOUT  = 20.0,
    LEVER_RESCAN_INTERVAL   = 1.5,

    EXPECTED_GENS           = 5,
    GAME_END_SCAN_INTERVAL  = 1.0,
    FINISHLINE_RESCAN_GAP   = 2.0,

    FENCE_CACHE_TTL         = 8.0,
    FENCE_SCAN_DEPTH        = 8,
    FENCE_NAME_PATTERNS     = { "Fence_W4_Material_0", "Fence_W4", "FenceMaterial", "Fence" },
    FENCE_NEARBY_RADIUS     = 12,
    FENCE_MARGIN            = 2.5,

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

local Evasion
local Survivor  -- forward declare

local function nlog(fmt, ...)
    if CONFIG.DEBUG_NAV then print("[KemiAI-nav]", string.format(fmt, ...)) end
end

local function hasTagOrAttr(instance, name)
    if not instance then return false end
    local ok, has = pcall(function() return CollectionService:HasTag(instance, name) end)
    if ok and has then return true end
    local ok2, v = pcall(function() return instance:GetAttribute(name) end)
    if ok2 and v ~= nil and v ~= false then return true end
    return false
end

-- ============================================================================
-- ACTION DEFINITIONS
-- ============================================================================
local ACTION_DEFS = {
    repair       = { attr = "isRepairing",       hold = false, timeout = 1.5, cooldown = 0.5 },
    heal         = { attr = "isHealing",         hold = true,  timeout = 1.5, cooldown = 0.5 },
    selfHeal     = { attr = "isHealing",         hold = true,  timeout = 1.5, cooldown = 0.5, soft = true },
    exit         = { attr = "isExiting",         hold = true,  timeout = 1.5, cooldown = 0.5 },
    unhook       = { attr = "isUnhooking",       hold = true,  timeout = 1.5, cooldown = 0.5 },
    vault        = { attr = "isVaulting",        hold = false, timeout = 0.8, cooldown = 0.4, remote = "vault" },
    palletSlide  = { attr = "isSliding",         hold = false, timeout = 0.8, cooldown = 0.4, remote = "palletSlide" },
    palletDrop   = { attr = "isDroppingPallet",  hold = false, timeout = 0.8, cooldown = 0.6, remote = "palletDrop" },
    pumpkin      = { attr = "isVaulting",        hold = false, timeout = 0.8, cooldown = 0.4 },
    giftPickup   = { attr = "isVaulting",        hold = false, timeout = 0.8, cooldown = 0.4 },
    selfUnhook   = { attr = "selfUnhookHolding", hold = true,  timeout = 1.5, cooldown = 1.0 },
}

local ACTION_BY_STATE = {
    RepairingGenerator = "repair",
    HealingSurvivor    = "heal",
    RescuingSurvivor   = "unhook",
    SelfHealing        = "selfHeal",
    EscapingMap        = "exit",
}

local ActionState = {
    current = nil, phase = "idle",
    target = nil, targetPoint = nil,
    attributeName = nil, isHold = false,
    startedAt = 0, retryCount = 0,
    stopStartedAt = 0, cooldownUntil = 0,
    fallbackApplied = false,
    interactMethod = nil,
    interactStartedAt = 0,
    guiFallbackUsed = false,
    guiFallbackAt = 0,
    shiftActive = false,
}

-- ============================================================================
-- SHIFT STATE
-- ============================================================================
local Shift = { held = false }
local function pressShiftRaw()
    pcall(function() VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.LeftShift, false, game) end)
end
local function releaseShiftRaw()
    pcall(function() VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.LeftShift, false, game) end)
end
local function holdShift() if Shift.held then return end; Shift.held = true; pressShiftRaw() end
local function releaseShift() if not Shift.held then return end; Shift.held = false; releaseShiftRaw() end
local function endShiftInteract() if ActionState.shiftActive then ActionState.shiftActive = false end end

-- ============================================================================
-- REMOTES
-- ============================================================================
local function findRemote(...)
    local node = ReplicatedStorage
    for _, seg in ipairs({...}) do
        node = node and node:FindFirstChild(seg)
        if not node then return nil end
    end
    return node
end

local RepairRemoteCache
local function getRepairRemote()
    if RepairRemoteCache and RepairRemoteCache.Parent then return RepairRemoteCache end
    RepairRemoteCache = findRemote("Remotes", "Generator", "RepairEvent")
    return RepairRemoteCache
end

local VaultRemoteCache
local function getVaultRemote()
    if VaultRemoteCache and VaultRemoteCache.Parent then return VaultRemoteCache end
    VaultRemoteCache = findRemote("Remotes", "Window", "VaultEvent")
    return VaultRemoteCache
end

local PalletDropCache
local function getPalletDropRemote()
    if PalletDropCache and PalletDropCache.Parent then return PalletDropCache end
    PalletDropCache = findRemote("Remotes", "Pallet", "PalletDropEvent")
    return PalletDropCache
end

local PalletSlideCache
local function getPalletSlideRemote()
    if PalletSlideCache and PalletSlideCache.Parent then return PalletSlideCache end
    PalletSlideCache = findRemote("Remotes", "Pallet", "PalletSlideEvent")
    return PalletSlideCache
end

local CancelRepairRemoteCache
local function getCancelRepairRemote()
    if CancelRepairRemoteCache and CancelRepairRemoteCache.Parent then return CancelRepairRemoteCache end
    CancelRepairRemoteCache = findRemote("Remotes", "Generator", "Skillcheckvalidated")
    return CancelRepairRemoteCache
end

local GenDoneRemoteCache
local function getGenDoneRemote()
    if GenDoneRemoteCache and GenDoneRemoteCache.Parent then return GenDoneRemoteCache end
    GenDoneRemoteCache = findRemote("Remotes", "Generator", "GenDone")
    return GenDoneRemoteCache
end

local LeverRemoteCache
local function getLeverRemote()
    if LeverRemoteCache and LeverRemoteCache.Parent then return LeverRemoteCache end
    LeverRemoteCache = findRemote("Remotes", "Exit", "LeverEvent")
    return LeverRemoteCache
end

local function fireVault(target, sprinting)
    local rem = getVaultRemote()
    if not rem or not target or not target.Parent then return false end
    return pcall(function() rem:FireServer(target, sprinting == true) end)
end

local function firePalletDrop(target)
    local rem = getPalletDropRemote()
    if not rem or not target or not target.Parent then return false end
    return pcall(function() rem:FireServer(target) end)
end

local function firePalletSlide(target, sprinting)
    local rem = getPalletSlideRemote()
    if not rem or not target or not target.Parent then return false end
    return pcall(function() rem:FireServer(target, sprinting == true) end)
end

local function fireCancelRepair(gen, pt)
    local rem = getCancelRepairRemote()
    if not rem or not gen or not gen.Parent or not pt or not pt.Parent then return false end
    if pt.Parent ~= gen then return false end
    if not (type(pt.Name) == "string" and pt.Name:match("^GeneratorPoint%d+$")) then return false end
    return pcall(function()
        if rem:IsA("RemoteEvent") then rem:FireServer("success", 1, gen, pt)
        elseif rem:IsA("BindableEvent") then rem:Fire("success", 1, gen, pt) end
    end)
end
_G.KemiAI_fireCancelRepair = fireCancelRepair

-- ============================================================================
-- LOADSTRING SKILLCHECK
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

local Repair = { active = false, cancelFired = false }
local function notifyRepairStarted() Repair.active = true; Repair.cancelFired = false end
local function notifyRepairEnded()   Repair.active = false; Repair.cancelFired = false end

local function fireGenDone()
    if Repair.cancelFired then return end
    Repair.cancelFired = true
    local rem = getGenDoneRemote(); if not rem then return end
    pcall(function()
        if rem:IsA("RemoteEvent") then rem:FireServer()
        elseif rem:IsA("BindableEvent") then rem:Fire() end
    end)
end

-- ============================================================================
-- HELPERS
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

local function hasClearLine(fromPos, toPos, ignoreModel, maxDist)
    if not fromPos or not toPos then return false end
    local delta = toPos - fromPos
    local mag = delta.Magnitude
    if mag < 0.5 then return true end
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    local ignore = { getChar() }
    if ignoreModel then table.insert(ignore, ignoreModel) end
    params.FilterDescendantsInstances = ignore
    local d_ = math.min(mag, maxDist or CONFIG.RAYCAST_DIST)
    return workspace:Raycast(fromPos, delta.Unit * d_, params) == nil
end

local function rotateAroundY(v, rad)
    local c,s = math.cos(rad), math.sin(rad)
    return Vector3.new(v.X*c - v.Z*s, 0, v.X*s + v.Z*c)
end

-- ============================================================================
-- PATH DEBUG VISUAL
-- ============================================================================
local PathDebug = { folder=nil, parts={}, lastSignature=nil, lastUpdate=0 }

local function pathDebugClear()
    for _, p in ipairs(PathDebug.parts) do
        if p and p.Parent then pcall(function() p:Destroy() end) end
    end
    PathDebug.parts = {}; PathDebug.lastSignature = nil
end
local function pathDebugFolder()
    if PathDebug.folder and PathDebug.folder.Parent then return PathDebug.folder end
    PathDebug.folder = Instance.new("Folder")
    PathDebug.folder.Name = "_KemiAI_PathDebug"
    PathDebug.folder.Parent = workspace
    return PathDebug.folder
end
local function raycastFloor(pos)
    if not pos then return pos end
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    local char = getChar()
    params.FilterDescendantsInstances = char and { char, PathDebug.folder } or { PathDebug.folder }
    local hit = workspace:Raycast(pos + Vector3.new(0, 6, 0), Vector3.new(0, -25, 0), params)
    if hit then return hit.Position + Vector3.new(0, 0.08, 0) end
    return pos
end
local function makeDebugBeam(fromPos, toPos, color, transparency)
    local delta = toPos - fromPos
    local len = delta.Magnitude
    if len < 0.1 then return nil end
    local part = Instance.new("Part")
    part.Name = "KemiPathSeg"; part.Anchored = true
    part.CanCollide = false; part.CanQuery = false; part.CanTouch = false
    part.Massless = true; part.Material = Enum.Material.Neon
    part.Size = Vector3.new(0.18, 0.06, len)
    part.CFrame = CFrame.lookAt(fromPos + delta * 0.5, toPos)
    part.Color = color; part.Transparency = transparency or 0.5
    part.Parent = pathDebugFolder()
    return part
end
local function updatePathDebug()
    if not CONFIG.DEBUG_PATH_VISUAL then
        if #PathDebug.parts > 0 then pathDebugClear() end
        return
    end
    local wps = PathFollower and PathFollower.waypoints
    local idx = PathFollower and PathFollower.index or 1
    local root = getRoot()
    if not wps or #wps == 0 or not root then
        if #PathDebug.parts > 0 then pathDebugClear() end
        return
    end
    local now = tick()
    local sig = tostring(#wps)..":"..tostring(idx)
    for i = math.max(1, idx - 1), math.min(#wps, idx + 2) do
        local w = wps[i]
        sig = sig.."|"..string.format("%.1f,%.1f,%.1f", w.Position.X, w.Position.Y, w.Position.Z)
    end
    if sig == PathDebug.lastSignature and (now - PathDebug.lastUpdate) < 0.15 then return end
    PathDebug.lastSignature = sig; PathDebug.lastUpdate = now
    pathDebugClear()
    local prev = raycastFloor(root.Position)
    for i = math.max(1, idx - 1), #wps do
        local w = wps[i]
        local wFloor = raycastFloor(w.Position)
        local isCurrent = (i == idx)
        local color = isCurrent and Color3.fromRGB(255, 200, 0) or Color3.fromRGB(0, 255, 120)
        local tr = isCurrent and 0.30 or 0.55
        local part = makeDebugBeam(prev, wFloor, color, tr)
        if part then table.insert(PathDebug.parts, part) end
        prev = wFloor
    end
end

-- ============================================================================
-- FENCE SCANNER
-- ============================================================================
local FenceCache = { list = {}, lastScan = 0 }
local function isFenceName(nm)
    if type(nm) ~= "string" then return false end
    for _, pat in ipairs(CONFIG.FENCE_NAME_PATTERNS) do
        if nm == pat then return true end
        if nm:find(pat, 1, true) then return true end
    end
    return false
end
local function scanFences(force)
    local now = tick()
    if not force and (now - FenceCache.lastScan) < CONFIG.FENCE_CACHE_TTL then return end
    FenceCache.lastScan = now; FenceCache.list = {}
    local function scan(node, depth)
        if depth > CONFIG.FENCE_SCAN_DEPTH or not node then return end
        for _,ch in ipairs(node:GetChildren()) do
            if ch:IsA("BasePart") and isFenceName(ch.Name) then
                table.insert(FenceCache.list, ch)
            elseif ch:IsA("Model") and isFenceName(ch.Name) then
                for _, sub in ipairs(ch:GetDescendants()) do
                    if sub:IsA("BasePart") then table.insert(FenceCache.list, sub) end
                end
            end
            if ch:IsA("Folder") or ch:IsA("Model") then scan(ch, depth+1) end
        end
    end
    pcall(scan, workspace, 0)
end
local function findNearbyFences(pos, radius, maxCount)
    scanFences(false)
    radius = radius or CONFIG.FENCE_NEARBY_RADIUS
    maxCount = maxCount or 6
    local out = {}
    for _, f in ipairs(FenceCache.list) do
        if f.Parent then
            local d = (f.Position - pos).Magnitude
            if d < radius then table.insert(out, { part=f, dist=d }) end
        end
    end
    table.sort(out, function(a,b) return a.dist < b.dist end)
    local result = {}
    for i=1, math.min(maxCount, #out) do result[i] = out[i].part end
    return result
end
local function isNearFence(pos, margin)
    if not pos then return false end
    margin = margin or CONFIG.FENCE_MARGIN
    local fences = findNearbyFences(pos, margin + 3, 8)
    if #fences == 0 then return false end
    for _, f in ipairs(fences) do
        local sz = f.Size
        local bboxR = math.max(sz.X, sz.Y, sz.Z) * 0.5
        local d = (f.Position - pos).Magnitude - bboxR
        if d < margin then return true, f end
    end
    return false, nil
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
-- SURVIVOR STATE DETECTION
-- ============================================================================
local function attrOrChildBool(inst, names)
    if not inst then return false end
    for _, key in ipairs(names) do
        local ok, v = pcall(function() return inst:GetAttribute(key) end)
        if ok and v == true then return true end
        local ch = inst:FindFirstChild(key)
        if ch and ch:IsA("BoolValue") and ch.Value then return true end
    end
    return false
end

local KNOCK_ATTRS = {
    "IsKnocked","isKnocked","Knocked","IsDowned","Downed",
    "IsIncapacitated","Incapacitated","isDowned","isIncapacitated",
}

local function getSurvivorState(p)
    p = p or localPlayer
    local char = p.Character
    if not char then return nil end
    local hum = char:FindFirstChildOfClass("Humanoid")
    if not hum then return nil end
    if hum.Health <= 0 then return "dead" end
    if attrOrChildBool(char, {"IsHooked","Hooked","OnHook","Hanging","IsOnHook"}) then return "hooked" end
    if attrOrChildBool(char, {"IsCarried","Carried","IsBeingCarried"}) then return "carried" end
    if attrOrChildBool(char, KNOCK_ATTRS) then return "knocked" end
    local rt = char:FindFirstChild("RagdollTrigger")
    if rt and rt:IsA("BoolValue") and rt.Value == true then return "knocked" end
    local root = getPlayerRoot(p)
    if root and root:GetAttribute("CanGetHealed") == true then return "canBeHealed" end
    if hum.Health <= 50 then return "injured" end
    return "healthy"
end
local function getSelfState() return getSurvivorState(localPlayer) end

-- ============================================================================
-- GUI ACTION HELPERS
-- ============================================================================
local function GetActionTarget()
    local pg = localPlayer:FindFirstChild("PlayerGui")
    if not pg then return nil end
    for _, path in ipairs(CONFIG.ACTION_PATHS) do
        local cur = pg
        local ok = true
        for seg in string.gmatch(path, "[^%.]+") do
            if not cur then ok = false; break end
            cur = cur:FindFirstChild(seg)
        end
        if ok and cur and cur:IsA("GuiObject") and cur.Visible then
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
local function TriggerMobileButton(touchId)
    touchId = touchId or CONFIG.TAP_ID
    local b = GetActionTarget()
    if not (b and b:IsA("GuiObject")) then return false end
    local p = b
    while p do
        if p:IsA("GuiObject") and not p.Visible then return false end
        p = p.Parent
    end
    local ap, sz, inset = b.AbsolutePosition, b.AbsoluteSize, GuiService:GetGuiInset()
    if sz.X <= 0 or sz.Y <= 0 then return false end
    local cx = ap.X + sz.X/2 + inset.X
    local cy = ap.Y + sz.Y/2 + inset.Y
    local ok = pcall(function()
        VirtualInputManager:SendTouchEvent(touchId, 0, cx, cy)
        task.wait(0.02)
        VirtualInputManager:SendTouchEvent(touchId, 2, cx, cy)
    end)
    return ok, cx, cy
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
    local b = GetActionTarget(); if not b then return false end
    local cx, cy = getScreenPos(b)
    ActionHold.active = true; ActionHold.pos = {x=cx, y=cy}
    pcall(function() VirtualInputManager:SendTouchEvent(CONFIG.HOLD_ID, 0, cx, cy) end)
    return true
end
local function tapAction()
    local b = GetActionTarget(); if not b then return false end
    local cx, cy = getScreenPos(b)
    pcall(function()
        VirtualInputManager:SendTouchEvent(CONFIG.TAP_ID, 0, cx, cy)
        task.wait(0.02)
        VirtualInputManager:SendTouchEvent(CONFIG.TAP_ID, 2, cx, cy)
    end)
    return true
end

-- ============================================================================
-- REPAIR SESSION — SIMPLE FSM, REMOTE-ONLY START
-- ============================================================================
local RepairSession = {
    state        = "idle",
    targetPoint  = nil,
    targetGen    = nil,
    startedAt    = 0,
    lastConfirmAt= 0,
    lastProgress = nil,
    lastProgressAt = 0,
    nextStartAt  = 0,
    stopAt       = 0,
    lastStopReason = nil,
}

local function isRepairActive()
    return RepairSession.state == "starting" or RepairSession.state == "active"
end

local function startRepair(gen, pt)
    if RepairSession.state == "active" or RepairSession.state == "starting" then
        if RepairSession.targetPoint == pt then return true end
        return false
    end
    if RepairSession.state == "stopping" then return false end
    if not gen or not gen.Parent or not pt or not pt.Parent then return false end

    local rem = getRepairRemote()
    if not rem then
        if CONFIG.DEBUG then log("[REPAIR] no RepairEvent remote in ReplicatedStorage") end
        return false
    end

    local ok = pcall(function() rem:FireServer(pt, true) end)
    if not ok then
        if CONFIG.DEBUG then log("[REPAIR] FireServer(pt,true) error") end
        return false
    end

    local now = tick()
    RepairSession.state          = "starting"
    RepairSession.targetPoint    = pt
    RepairSession.targetGen      = gen
    RepairSession.startedAt      = now
    RepairSession.lastConfirmAt  = 0
    RepairSession.lastProgress   = getGenProgress(gen)
    RepairSession.lastProgressAt = now
    RepairSession.stopAt         = 0

    notifyRepairStarted()
    if CONFIG.DEBUG then log(string.format("[REPAIR] start sent → %s", pt:GetFullName())) end
    return true
end

local function stopRepair(reason)
    if RepairSession.state == "idle" or RepairSession.state == "stopping" then return end

    local pt  = RepairSession.targetPoint
    local gen = RepairSession.targetGen

    RepairSession.state = "stopping"
    RepairSession.stopAt = tick()
    RepairSession.lastStopReason = reason

    local rem = getRepairRemote()
    if rem and pt and pt.Parent then
        pcall(function() rem:FireServer(pt, false) end)
    end

    if CONFIG.DEBUG then
        log(string.format("[REPAIR] stop reason=%s target=%s",
            tostring(reason), pt and pt:GetFullName() or "<gone>"))
    end
end

local function updateRepairSession(now, char)
    if RepairSession.state == "idle" then return end

    local attrVal = char and char:GetAttribute("isRepairing") == true

    if RepairSession.state == "starting" or RepairSession.state == "active" then
        local prog = getGenProgress(RepairSession.targetGen)
        local progressed = prog and RepairSession.lastProgress and prog > RepairSession.lastProgress
        if progressed then
            RepairSession.lastProgress = prog
            RepairSession.lastProgressAt = now
        end

        if attrVal or progressed then
            RepairSession.lastConfirmAt = now
            if RepairSession.state == "starting" then
                RepairSession.state = "active"
                if CONFIG.DEBUG then log("[REPAIR] confirmed active") end
            end
        end

        if RepairSession.state == "starting" then
            if now - RepairSession.startedAt > CONFIG.REPAIR_GIVEUP_TIME then
                if Survivor and Survivor.failedGens and RepairSession.targetGen then
                    Survivor.failedGens[RepairSession.targetGen] = now
                end
                RepairSession.nextStartAt = now + CONFIG.REPAIR_NEXT_START_DELAY
                stopRepair("start-timeout")
            end
        elseif RepairSession.state == "active" then
            local shouldEnd, endReason = false, nil
            if not RepairSession.targetPoint or not RepairSession.targetPoint.Parent then
                shouldEnd, endReason = true, "target-gone"
            elseif not RepairSession.targetGen or not RepairSession.targetGen.Parent then
                shouldEnd, endReason = true, "gen-gone"
            elseif updateGeneratorProgress(RepairSession.targetGen) then
                shouldEnd, endReason = true, "gen-complete"
            elseif now - RepairSession.lastConfirmAt > CONFIG.REPAIR_CONFIRM_GRACE then
                shouldEnd, endReason = true, "no-signal"
                if Survivor and Survivor.failedGens and RepairSession.targetGen then
                    Survivor.failedGens[RepairSession.targetGen] = now
                end
            end
            if shouldEnd then
                RepairSession.nextStartAt = now + CONFIG.REPAIR_NEXT_START_DELAY
                stopRepair(endReason)
            end
        end
    elseif RepairSession.state == "stopping" then
        if not attrVal then
            RepairSession.state = "idle"
            RepairSession.targetPoint = nil
            RepairSession.targetGen = nil
        elseif now - RepairSession.stopAt > CONFIG.REPAIR_STOP_GRACE then
            RepairSession.state = "idle"
            RepairSession.targetPoint = nil
            RepairSession.targetGen = nil
        end
    end
end

-- ============================================================================
-- LEVER SESSION — EXIT GATE
-- ============================================================================
local LeverSession = {
    state = "idle",
    target = nil,
    startedAt = 0,
    lastScanAt = 0,
}

local function fireLeverStart(target)
    local rem = getLeverRemote()
    if not rem or not target or not target.Parent then return false end
    return pcall(function() rem:FireServer(target, true) end)
end
local function fireLeverStop(target)
    local rem = getLeverRemote()
    if not rem or not target or not target.Parent then return false end
    return pcall(function() rem:FireServer(target, false) end)
end

local function stopLeverSession(reason)
    if LeverSession.state == "idle" then return end
    local t = LeverSession.target
    if t and t.Parent and (LeverSession.state == "interacting" or LeverSession.state == "approaching") then
        fireLeverStop(t)
        if CONFIG.DEBUG then log("[LEVER] stop reason="..tostring(reason)) end
    end
    LeverSession.state = "idle"
    LeverSession.target = nil
    LeverSession.startedAt = 0
end

local function startLeverSession(target)
    if LeverSession.state ~= "idle" then return false end
    if not target or not target.Parent or not target:IsA("BasePart") then return false end
    local rem = getLeverRemote()
    if not rem then return false end
    LeverSession.target = target
    LeverSession.state = "interacting"
    LeverSession.startedAt = tick()
    local ok = fireLeverStart(target)
    if not ok then
        LeverSession.state = "idle"
        LeverSession.target = nil
        return false
    end
    if CONFIG.DEBUG then log("[LEVER] start target="..target:GetFullName()) end
    return true
end

-- ============================================================================
-- ACTION STATE MACHINE (non-repair actions)
-- ============================================================================
local function fireRemoteAction(def, actionName)
    if not def or not def.remote then return false end
    if def.remote == "vault" then
        return fireVault(ActionState.target, true)
    elseif def.remote == "palletDrop" then
        return firePalletDrop(ActionState.target)
    elseif def.remote == "palletSlide" then
        return firePalletSlide(ActionState.target, true)
    end
    return false
end

local function startActionGeneric(actionName, target, targetPoint, def)
    if not def then return false end
    local now = tick()

    if actionName == "repair" then
        if not targetPoint or not targetPoint.Parent then return false end
        return startRepair(target, targetPoint)
    end

    if ActionState.current == actionName
        and (ActionState.phase == "starting" or ActionState.phase == "active") then
        return true
    end
    if ActionState.current and ActionState.phase == "stopping" then return false end
    if ActionState.current and ActionState.current ~= actionName then
        requestStopAction(); return false
    end
    if now < ActionState.cooldownUntil then return false end

    local char = getChar(); if not char then return false end

    if def.attr and char:GetAttribute(def.attr) == true then
        ActionState.current = actionName
        ActionState.attributeName = def.attr
        ActionState.isHold = def.hold
        ActionState.phase = "active"
        ActionState.target = target
        ActionState.targetPoint = targetPoint
        ActionState.startedAt = now
        ActionState.retryCount = 0
        ActionState.interactMethod = def.remote or "gui"
        ActionState.shiftActive = false
        return true
    end

    ActionState.current = actionName
    ActionState.phase = "starting"
    ActionState.target = target
    ActionState.targetPoint = targetPoint
    ActionState.attributeName = def.attr
    ActionState.isHold = def.hold
    ActionState.startedAt = now
    ActionState.retryCount = 0
    ActionState.fallbackApplied = false
    ActionState.guiFallbackUsed = false
    ActionState.interactStartedAt = now
    ActionState.interactMethod = def.remote or "gui"
    ActionState.shiftActive = false

    local triggered
    if def.remote then
        triggered = fireRemoteAction(def, actionName)
    elseif def.hold then
        triggered = beginHoldAction()
    else
        triggered = TriggerMobileButton(CONFIG.TAP_ID)
    end

    if not triggered then
        ActionState.current = nil; ActionState.phase = "idle"
        ActionState.cooldownUntil = now + 1.0
        return false
    end
    return true
end

local function startAction(actionName, target, targetPoint)
    local def = ACTION_DEFS[actionName]
    if not def then return false end
    return startActionGeneric(actionName, target, targetPoint, def)
end

function requestStopAction()
    if RepairSession.state == "active" or RepairSession.state == "starting" then
        stopRepair("requestStopAction")
    end
    if not ActionState.current then return end
    if ActionState.phase == "stopping" then return end
    local def = ACTION_DEFS[ActionState.current]
    if not def then
        ActionState.current = nil; ActionState.phase = "idle"; return
    end
    ActionState.phase = "stopping"
    ActionState.stopStartedAt = tick()
    ActionState.fallbackApplied = false
    endHoldAction()
    endShiftInteract()
end

local function updateActionState(now, char)
    if not ActionState.current then return end
    if ActionState.current == "repair" then return end

    local def = ACTION_DEFS[ActionState.current]
    if not def then ActionState.current = nil; ActionState.phase = "idle"; return end

    local attrVal = def.attr and char and char:GetAttribute(def.attr) == true

    if ActionState.phase == "starting" then
        if attrVal then
            ActionState.phase = "active"; ActionState.retryCount = 0
        else
            local startTimeout = def.timeout
            if now - ActionState.interactStartedAt > startTimeout then
                if def.soft then
                    ActionState.phase = "active"
                elseif ActionState.retryCount < CONFIG.ACTION_START_RETRIES then
                    ActionState.retryCount = ActionState.retryCount + 1
                    local ok2
                    if def.remote then
                        ok2 = fireRemoteAction(def, ActionState.current)
                    elseif def.hold then
                        endHoldAction(); ok2 = beginHoldAction()
                    else
                        ok2 = TriggerMobileButton(CONFIG.TAP_ID)
                    end
                    if ok2 then
                        ActionState.interactStartedAt = now
                    else
                        ActionState.current = nil; ActionState.phase = "idle"
                        ActionState.cooldownUntil = now + CONFIG.ACTION_FAIL_COOLDOWN
                    end
                else
                    log(string.format("Action %s failed (no attr)", ActionState.current))
                    endHoldAction(); endShiftInteract()
                    ActionState.current = nil; ActionState.phase = "idle"
                    ActionState.cooldownUntil = now + CONFIG.ACTION_FAIL_COOLDOWN
                end
            end
        end
    elseif ActionState.phase == "active" then
        if not attrVal and not def.soft then
            log(string.format("Action %s ended", ActionState.current))
            endHoldAction(); endShiftInteract()
            ActionState.current = nil; ActionState.phase = "idle"
            ActionState.cooldownUntil = now + def.cooldown
        end
    elseif ActionState.phase == "stopping" then
        if not attrVal then
            endHoldAction(); endShiftInteract()
            ActionState.current = nil; ActionState.phase = "idle"
            ActionState.cooldownUntil = now + CONFIG.ACTION_BUSY_COOLDOWN
        elseif now - ActionState.stopStartedAt > CONFIG.ACTION_STOP_VERIFY then
            if not ActionState.fallbackApplied then
                ActionState.fallbackApplied = true
                local root = getRoot(); local hum = getHumanoid()
                if root and hum and not (Evasion and Evasion.active) then
                    local dir = Vector3.new(math.random()-0.5, 0, math.random()-0.5)
                    if dir.Magnitude < 0.1 then dir = Vector3.new(1,0,0) end
                    hum:MoveTo(root.Position + dir.Unit * 6)
                end
            end
            if now - ActionState.stopStartedAt > CONFIG.ACTION_STOP_FORCE_CLEAR then
                log(string.format("Action %s force-clear", ActionState.current))
                endHoldAction(); endShiftInteract()
                ActionState.current = nil; ActionState.phase = "idle"
                ActionState.cooldownUntil = now + 1.0
            end
        end
    end
end

-- ============================================================================
-- PERCEPTION
-- ============================================================================
local Perception = { smoothClosing=0, lastKD=nil, lastSampleT=0 }
local function resetPerception()
    Perception.smoothClosing = 0; Perception.lastKD = nil; Perception.lastSampleT = 0
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
    Perception.lastKD = kD; Perception.lastSampleT = now
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
    local myRoot = getRoot(); if not myRoot then return {} end
    local myPos = myRoot.Position; local out = {}
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
        THREAT.P = 0
        if THREAT.confirmed then
            THREAT.clearStart = THREAT.clearStart or now
            if now - THREAT.clearStart > CONFIG.THREAT_CLEAR_TIME then resetThreat() end
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
        if CONFIG.DEBUG then log(string.format("Threat ENTER [%s]: d=%.1f P=%.2f", tier, primary.dist, P)) end
    end
    if THREAT.confirmed and P <= CONFIG.THREAT_P_EXIT then
        if primary.dist > CONFIG.THREAT_EXIT_DIST then
            THREAT.clearStart = THREAT.clearStart or now
            if now - THREAT.clearStart > CONFIG.THREAT_CLEAR_TIME then
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
-- PATHFOLLOWER
-- ============================================================================
PathFollower = {
    path = nil, goalPos = nil, goalTag = nil,
    waypoints = {}, index = 1, computing = false,
    pendingPos = nil, pendingTag = nil, lastMoveTo = nil,
    lastPos = nil, stuckSince = 0, lastStuckLog = 0,
    blockedConn = nil, failCount = 0, lastFailPos = nil, failCooldownUntil = 0,
    slopeStuckSince = 0, lastWP = nil, lastWPSince = 0,
    strafeDir = 1, strafeAttempts = 0,
    computeGeneration = 0,
    lastComputeAt = 0,
}
local function initPath()
    if PathFollower.path then return end
    PathFollower.path = PathfindingService:CreatePath({
        AgentRadius = CONFIG.AGENT_RADIUS, AgentHeight = CONFIG.AGENT_HEIGHT,
        AgentCanJump = true, AgentMaxSlope = CONFIG.AGENT_MAX_SLOPE,
        WaypointSpacing = CONFIG.AGENT_WAYPOINT_SPACING,
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
    PathFollower.lastMoveTo = nil; PathFollower.lastWP = nil; PathFollower.lastWPSince = 0
    PathFollower.strafeAttempts = 0
    PathFollower.lastComputeAt = 0
    disconnectBlocked()
    if CONFIG.DEBUG_PATH_VISUAL then pathDebugClear() end
end

local function setGoal(pos, tag, force)
    if not pos then return end
    initPath()
    local tagChanged = PathFollower.goalTag ~= tag
    local thresh = (tag == "chase") and CONFIG.CHASE_REPATH_THRESH or CONFIG.GOAL_REPATH_THRESH
    local posChanged = (not PathFollower.goalPos)
        or ((PathFollower.goalPos - pos).Magnitude > thresh)
    if force or tagChanged or posChanged then
        PathFollower.pendingPos = pos; PathFollower.pendingTag = tag
    end
end

local function computePending()
    local root = getRoot(); if not root then return end
    local pos = PathFollower.pendingPos; local tag = PathFollower.pendingTag
    if not pos then return end
    if PathFollower.lastFailPos and tick() < PathFollower.failCooldownUntil
        and (PathFollower.lastFailPos - pos).Magnitude < 5 then
        PathFollower.pendingPos = nil; PathFollower.pendingTag = nil
        return
    end
    PathFollower.computing = true
    PathFollower.pendingPos = nil; PathFollower.pendingTag = nil
    PathFollower.computeGeneration = (PathFollower.computeGeneration or 0) + 1
    local myGen = PathFollower.computeGeneration
    local ok = pcall(function() PathFollower.path:ComputeAsync(root.Position, pos) end)
    if PathFollower.computeGeneration ~= myGen then
        PathFollower.computing = false
        return
    end
    PathFollower.computing = false
    if ok and PathFollower.path.Status == Enum.PathStatus.Success then
        PathFollower.goalPos = pos; PathFollower.goalTag = tag
        PathFollower.waypoints = PathFollower.path:GetWaypoints()
        PathFollower.index = 2
        PathFollower.stuckSince = 0; PathFollower.failCount = 0
        PathFollower.lastMoveTo = nil; PathFollower.slopeStuckSince = 0
        PathFollower.lastComputeAt = tick()
        disconnectBlocked()
        PathFollower.blockedConn = PathFollower.path.Blocked:Connect(function(idx)
            if idx >= (PathFollower.index or 1) then
                PathFollower.goalPos = nil
                PathFollower.computeGeneration = (PathFollower.computeGeneration or 0) + 1
                if CONFIG.DEBUG_NAV then nlog("Path blocked @%d → recompute", idx) end
            end
        end)
    else
        PathFollower.failCount = PathFollower.failCount + 1
        PathFollower.lastFailPos = pos
        PathFollower.failCooldownUntil = tick() + math.min(1.0 * PathFollower.failCount, 5)
        if CONFIG.DEBUG_NAV and PathFollower.failCount >= 2 then
            nlog("Path fail #%d → %s", PathFollower.failCount, tostring(pos))
        end
        if PathFollower.goalPos
            and (PathFollower.goalPos - pos).Magnitude > 8 then
            PathFollower.goalPos = nil; PathFollower.goalTag = nil
            PathFollower.waypoints = {}; PathFollower.index = 1
            if CONFIG.DEBUG_NAV then nlog("Path fail → clear stale goal") end
        end
    end
end

local function handleStuck(root, hum, now)
    if not PathFollower.lastPos then
        PathFollower.lastPos = root.Position
        return
    end
    local dPos = root.Position - PathFollower.lastPos
    local horiz = Vector3.new(dPos.X, 0, dPos.Z).Magnitude
    local dY = math.abs(dPos.Y)
    local movedHoriz = horiz >= CONFIG.NAV_PROGRESS_EPS
    local movedVert  = dY >= CONFIG.SLOPE_STUCK_Y_TOL

    if not movedHoriz and not movedVert then
        PathFollower.stuckSince = (PathFollower.stuckSince == 0) and now or PathFollower.stuckSince
        if now - PathFollower.stuckSince > CONFIG.NAV_STUCK_TIME then
            local currentWP = PathFollower.waypoints[PathFollower.index]
            local dir = nil
            if currentWP then
                local toWP = currentWP.Position - root.Position
                local flat = Vector3.new(toWP.X, 0, toWP.Z)
                if flat.Magnitude > 0.5 then dir = flat.Unit end
            end
            if not dir and PathFollower.lastMoveTo then
                local toG = PathFollower.lastMoveTo - root.Position
                local flat = Vector3.new(toG.X, 0, toG.Z)
                if flat.Magnitude > 0.5 then dir = flat.Unit end
            end

            if dir and PathFollower.strafeAttempts < 2 then
                local perp = Vector3.new(-dir.Z, 0, dir.X)
                local side = PathFollower.strafeDir
                PathFollower.strafeDir = -PathFollower.strafeDir
                for _, offset in ipairs({2.0, 3.0}) do
                    local tgtA = root.Position + perp * side * offset + dir * 2.5
                    if hasClearLine(root.Position, tgtA, nil, offset + 4)
                        and not isNearFence(tgtA, CONFIG.FENCE_MARGIN) then
                        hum:MoveTo(tgtA)
                        PathFollower.stuckSince = 0
                        PathFollower.lastPos = root.Position
                        PathFollower.strafeAttempts = PathFollower.strafeAttempts + 1
                        nlog("stuck micro-correction side=%d off=%.1f", side, offset)
                        return
                    end
                    local tgtB = root.Position - perp * side * offset + dir * 2.5
                    if hasClearLine(root.Position, tgtB, nil, offset + 4)
                        and not isNearFence(tgtB, CONFIG.FENCE_MARGIN) then
                        hum:MoveTo(tgtB)
                        PathFollower.stuckSince = 0
                        PathFollower.lastPos = root.Position
                        PathFollower.strafeAttempts = PathFollower.strafeAttempts + 1
                        nlog("stuck micro-correction side=-%d off=%.1f", side, offset)
                        return
                    end
                end
            end

            if dir then
                local params = RaycastParams.new()
                params.FilterType = Enum.RaycastFilterType.Exclude
                local ch = getChar()
                params.FilterDescendantsInstances = ch and { ch } or {}
                local hit = workspace:Raycast(root.Position, dir * 3, params)
                if hit and hit.Normal.Y > 0.4 and (hit.Position.Y - root.Position.Y) < 3
                    and (hit.Position.Y - root.Position.Y) > 0.3 then
                    pcall(function() hum.Jump = true end)
                    PathFollower.stuckSince = 0
                    PathFollower.lastPos = root.Position
                    nlog("stuck jump (step-up)")
                    return
                end
            end

            nlog("stuck force repath")
            local keepPos = PathFollower.goalPos
            local keepTag = PathFollower.goalTag
            PathFollower.waypoints = {}
            PathFollower.index = 1
            PathFollower.stuckSince = 0
            PathFollower.strafeAttempts = 0
            PathFollower.pendingPos = keepPos
            PathFollower.pendingTag = keepTag
            PathFollower.lastComputeAt = 0
            PathFollower.computeGeneration = (PathFollower.computeGeneration or 0) + 1
        end
    else
        PathFollower.stuckSince = 0
        if movedHoriz then PathFollower.strafeAttempts = 0 end
    end

    if movedHoriz and dPos.Y < -CONFIG.SLOPE_STUCK_Y_TOL * 2 then
        PathFollower.slopeStuckSince = (PathFollower.slopeStuckSince == 0) and now or PathFollower.slopeStuckSince
        if now - PathFollower.slopeStuckSince > 3 then
            PathFollower.goalPos = nil; PathFollower.slopeStuckSince = 0
        end
    else
        PathFollower.slopeStuckSince = 0
    end

    PathFollower.lastPos = root.Position
end

local function followStep()
    local root = getRoot(); local hum = getHumanoid()
    if not root or not hum then return false end
    hum.WalkSpeed = CONFIG.BASE_WALKSPEED * CONFIG.WALKSPEED_FACTOR
    if PathFollower.pendingPos and not PathFollower.computing then computePending() end
    local now = tick()

    if PathFollower.goalPos and not PathFollower.pendingPos and not PathFollower.computing then
        if (now - (PathFollower.lastComputeAt or 0)) > CONFIG.PATH_REFRESH_INTERVAL then
            PathFollower.pendingPos = PathFollower.goalPos
            PathFollower.pendingTag = PathFollower.goalTag
        end
    end

    handleStuck(root, hum, now)
    if #PathFollower.waypoints == 0 or PathFollower.index > #PathFollower.waypoints then
        if PathFollower.pendingPos then
            hum:MoveTo(PathFollower.pendingPos)
        elseif PathFollower.goalPos then
            hum:MoveTo(PathFollower.goalPos)
        end
        return true
    end
    local wp = PathFollower.waypoints[PathFollower.index]
    while wp do
        local dxz = Vector3.new(root.Position.X - wp.Position.X, 0, root.Position.Z - wp.Position.Z).Magnitude
        local dy  = math.abs(root.Position.Y - wp.Position.Y)
        if dxz < CONFIG.WAYPOINT_REACH_DIST and dy < CONFIG.WAYPOINT_Y_TOL then
            PathFollower.index = PathFollower.index + 1
            wp = PathFollower.waypoints[PathFollower.index]
        elseif dxz < CONFIG.WAYPOINT_SKIP_DIST and dy >= CONFIG.WAYPOINT_Y_TOL then
            PathFollower.index = PathFollower.index + 1
            wp = PathFollower.waypoints[PathFollower.index]
        else break end
    end
    if not wp then
        if PathFollower.pendingPos then
            hum:MoveTo(PathFollower.pendingPos)
        elseif PathFollower.goalPos then
            hum:MoveTo(PathFollower.goalPos)
        end
        return true
    end
    if wp.Action == Enum.PathWaypointAction.Jump then hum.Jump = true end
    hum:MoveTo(wp.Position)
    PathFollower.lastMoveTo = wp.Position
    return true
end

-- ============================================================================
-- [R27] EVASION — SIMPLE, PATH-FOLLOWED, DISTANCE-DRIVEN
-- ============================================================================
Evasion = {
    active = false,
    targetPos = nil,
    targetSince = 0,
    lastPos = nil,
    lastPosT = 0,
    lastKillerPos = nil,
    stuckCount = 0,
    dodgeUntil = 0,
    dodgeSide = 1,
    safeSince = nil,
    lastPickReason = nil,
    failedTargets = {},
    lastLogAt = 0,
}

local function resetEvasion(reason)
    if Evasion.active and reason and CONFIG.DEBUG then
        log("[EVADE] reset: "..tostring(reason))
    end
    Evasion.active = false
    Evasion.targetPos = nil
    Evasion.targetSince = 0
    Evasion.lastPos = nil
    Evasion.lastPosT = 0
    Evasion.lastKillerPos = nil
    Evasion.stuckCount = 0
    Evasion.dodgeUntil = 0
    Evasion.safeSince = nil
    Evasion.lastPickReason = nil
    Evasion.failedTargets = {}
end

local function getAwayVector(myPos, killerPos)
    local d = Vector3.new(myPos.X - killerPos.X, 0, myPos.Z - killerPos.Z)
    if d.Magnitude < 0.5 then return Vector3.new(1, 0, 0) end
    return d.Unit
end

local function posKey(p)
    return string.format("%.1f|%.1f|%.1f", p.X, p.Y, p.Z)
end

local function isTargetFailedRecently(pos, now)
    local key = posKey(pos)
    local t = Evasion.failedTargets[key]
    if not t then return false end
    if now - t > CONFIG.EVADE_FAILED_TARGET_TTL then
        Evasion.failedTargets[key] = nil
        return false
    end
    return true
end

local function markTargetFailed(pos, now)
    Evasion.failedTargets[posKey(pos)] = now
end

local function updateEvasionGating(killerRoot, kD, now)
    if not Evasion.active then
        if killerRoot then
            local enter = false
            if kD <= CONFIG.EVADE_ENTER_DIST then
                enter = true
            elseif kD <= CONFIG.EVADE_WARN_DIST and THREAT.confirmed then
                enter = true
            end
            if enter then
                Evasion.active = true
                Evasion.safeSince = nil
                Evasion.targetPos = nil
                Evasion.targetSince = 0
                Evasion.stuckCount = 0
                Evasion.dodgeUntil = 0
                Evasion.failedTargets = {}
                local root = getRoot()
                Evasion.lastPos = root and root.Position
                Evasion.lastPosT = now
                Evasion.lastKillerPos = killerRoot.Position
                cancelGoal()
                if CONFIG.DEBUG then
                    log(string.format("[EVADE] ENTER d=%.1f confirm=%s",
                        kD, tostring(THREAT.confirmed)))
                end
            end
        end
    else
        local safe = false
        if (not killerRoot) or kD >= CONFIG.EVADE_EXIT_DIST then
            safe = true
        end
        if safe then
            Evasion.safeSince = Evasion.safeSince or now
            if now - Evasion.safeSince >= CONFIG.EVADE_EXIT_CONFIRM then
                if CONFIG.DEBUG then
                    log(string.format("[EVADE] EXIT safe d=%.1f", kD))
                end
                resetEvasion("safe-confirmed")
            end
        else
            Evasion.safeSince = nil
        end
    end
    return Evasion.active
end

-- [R27] Simplified picker: farthest generator from killer first.
local function pickEvadeTarget(myPos, killerPos, now)
    local list = getGeneratorList()
    local candidates = {}
    for _, gen in ipairs(list) do
        if gen and gen.Parent and not updateGeneratorProgress(gen) then
            local occ = getGenOccupancyMap(gen)
            local pts = genPoints(gen)
            for _, pt in ipairs(pts) do
                if not occ[pt] then
                    local dK = (pt.Position - killerPos).Magnitude
                    local dAI = (pt.Position - myPos).Magnitude
                    -- Exclude points we're already on / failed recently
                    if dAI > 5
                        and dK >= CONFIG.EVADE_MIN_TARGET_DK
                        and dAI <= CONFIG.EVADE_MAX_TARGET_DIST
                        and not isTargetFailedRecently(pt.Position, now) then
                        table.insert(candidates, { pos = pt.Position, dK = dK, dAI = dAI })
                    end
                end
            end
        end
    end
    table.sort(candidates, function(a,b) return a.dK > b.dK end)
    if #candidates > 0 then
        local c = candidates[1]
        return c.pos, string.format("gen(farthest dK=%.1f dAI=%.1f)", c.dK, c.dAI)
    end

    local away = getAwayVector(myPos, killerPos)
    local angles = { 30, -30, 55, -55, 80, -80, 110, -110, 140, -140 }
    for _, deg in ipairs(angles) do
        local dir = rotateAroundY(away, math.rad(deg))
        for _, d in ipairs({ 30, 20, 15 }) do
            local candidate = myPos + dir * d
            local dK = (candidate - killerPos).Magnitude
            if dK > CONFIG.EVADE_MIN_TARGET_DK
               and hasClearLine(myPos, candidate, nil, d + 4)
               and not isNearFence(candidate, CONFIG.FENCE_MARGIN) then
                return candidate, string.format("lateral(%d° @ %dm)", deg, d)
            end
        end
    end

    return myPos + away * 15, "raw-away"
end

local function driveEvasion(root, killerRoot, hum, now)
    local myPos = root.Position
    local killerPos = killerRoot.Position
    local kD = (myPos - killerPos).Magnitude

    -- (A) Emergency lateral dodge (short-range, validated clear-line)
    if kD < CONFIG.EVADE_DODGE_DIST and now >= Evasion.dodgeUntil then
        local away = getAwayVector(myPos, killerPos)
        local perp = Vector3.new(-away.Z, 0, away.X)
        local side = Evasion.dodgeSide
        Evasion.dodgeSide = -side
        local dodgeTarget = myPos + perp * side * CONFIG.EVADE_DODGE_STEP + away * 3
        if hasClearLine(myPos, dodgeTarget, nil, CONFIG.EVADE_DODGE_STEP + 5)
           and not isNearFence(dodgeTarget, CONFIG.FENCE_MARGIN) then
            cancelGoal()
            holdShift()
            hum:MoveTo(dodgeTarget)
            Evasion.dodgeUntil = now + CONFIG.EVADE_DODGE_COOLDOWN
            Evasion.lastPos = myPos
            Evasion.lastPosT = now
            if CONFIG.DEBUG then
                log(string.format("[EVADE] dodge side=%d kD=%.1f", side, kD))
            end
            return
        end
    end

    -- (B) Determine if we need a new waypoint
    local needRepick, reason = false, nil
    if not Evasion.targetPos then
        needRepick = true; reason = "no-target"
    else
        local dTgt = (myPos - Evasion.targetPos).Magnitude
        local dTgtK = (Evasion.targetPos - killerPos).Magnitude
        local killerMoved = Evasion.lastKillerPos
            and (killerPos - Evasion.lastKillerPos).Magnitude or 0
        if dTgt < CONFIG.EVADE_TARGET_REACH then
            needRepick = true; reason = "reached"
            markTargetFailed(Evasion.targetPos, now)
        elseif dTgtK < CONFIG.EVADE_MIN_TARGET_DK then
            needRepick = true; reason = "target-near-killer"
        elseif killerMoved > CONFIG.EVADE_KILLER_MOVE_THRESH then
            needRepick = true; reason = string.format("killer-moved(%.0f)", killerMoved)
        elseif isTargetFailedRecently(Evasion.targetPos, now) then
            needRepick = true; reason = "target-blacklisted"
        end
    end

    -- (C) Stuck detection
    if Evasion.lastPos and (now - Evasion.lastPosT) > CONFIG.EVADE_STUCK_TIMEOUT then
        local progress = (myPos - Evasion.lastPos).Magnitude
        if progress < CONFIG.EVADE_STUCK_EPS then
            needRepick = true
            reason = string.format("stuck(%.2f)", progress)
            Evasion.stuckCount = Evasion.stuckCount + 1
            if Evasion.targetPos then markTargetFailed(Evasion.targetPos, now) end
            cancelGoal()
            if CONFIG.DEBUG then
                log(string.format("[EVADE] stuck progress=%.2f count=%d",
                    progress, Evasion.stuckCount))
            end
        end
        Evasion.lastPos = myPos
        Evasion.lastPosT = now
    end

    -- (D) Pick new target if needed
    if needRepick then
        local newTarget, pickReason = pickEvadeTarget(myPos, killerPos, now)
        if newTarget then
            Evasion.targetPos = newTarget
            Evasion.targetSince = now
            Evasion.lastPickReason = pickReason
            Evasion.lastKillerPos = killerPos
            cancelGoal()
            if CONFIG.DEBUG and (now - Evasion.lastLogAt > 0.5) then
                Evasion.lastLogAt = now
                log(string.format("[EVADE] pick (%s) reason=%s dK=%.1f dAI=%.1f",
                    tostring(pickReason), tostring(reason),
                    (newTarget - killerPos).Magnitude,
                    (newTarget - myPos).Magnitude))
            end
        end
    end

    -- (E) Move via PathfindingService
    holdShift()
    if Evasion.targetPos then
        setGoal(Evasion.targetPos, "evade", false)
        followStep()
    else
        local away = getAwayVector(myPos, killerPos)
        hum:MoveTo(myPos + away * 20)
    end
end

-- ============================================================================
-- CHASE ACTION (vault/palletDrop)
-- ============================================================================
local ChaseAction = { kind=nil, target=nil, startedAt=0, everActive=false }

local function clearChaseAction()
    ChaseAction.kind = nil
    ChaseAction.target = nil
    ChaseAction.startedAt = 0
    ChaseAction.everActive = false
end

local function updateChaseAction(root, hum, now)
    if not ChaseAction.kind or not ChaseAction.target then return false end
    local t = ChaseAction.target

    if not t.Parent then
        clearChaseAction(); return false
    end

    if now - ChaseAction.startedAt > CONFIG.CHASE_APPROACH_TIMEOUT then
        if CONFIG.DEBUG then log("[CHASE] "..ChaseAction.kind.." timeout → cancel") end
        if ActionState.current == ChaseAction.kind then requestStopAction() end
        clearChaseAction()
        return false
    end

    local d = (root.Position - t.Position).Magnitude

    if ActionState.current == ChaseAction.kind then
        if ActionState.phase == "active" then
            ChaseAction.everActive = true
            return true
        elseif ActionState.phase == "starting" then
            -- [R27] Always keep moving toward target during confirmation
            hum:MoveTo(t.Position)
            return true
        elseif ActionState.phase == "stopping" then
            -- [R27] Let driveEvasion handle movement during stopping
            return false
        end
        return true
    end

    if ChaseAction.everActive then
        if CONFIG.DEBUG then log("[CHASE] "..ChaseAction.kind.." completed") end
        clearChaseAction()
        return false
    end

    if d <= CONFIG.CHASE_TRIGGER_RADIUS then
        if now >= ActionState.cooldownUntil then
            if startAction(ChaseAction.kind, t) then return true end
        end
        clearChaseAction()
        return false
    else
        hum:MoveTo(t.Position)
        return true
    end
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
    local p = getGenProgress(gen); if p == nil then return false end
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
        map and map:FindFirstChild("new Generators"),
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
    scan(container, 0); return out
end
local function getGeneratorList()
    local now = tick()
    if GenRegistry.container and GenRegistry.container.Parent then
        if now - GenRegistry.lastScan < CONFIG.GEN_CACHE_TTL then
            return GenRegistry.list, GenRegistry.lastReason
        end
        local refreshed = collectGeneratorsFrom(GenRegistry.container)
        if #refreshed > 0 then
            GenRegistry.list = refreshed; GenRegistry.lastScan = now
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
    if GenRegistry.lastCount ~= 0 then
        GenRegistry.lastCount = 0; log("Generator container: not found")
    end
    GenRegistry.container = nil; GenRegistry.list = {}; GenRegistry.lastScan = now
    GenRegistry.lastReason = "not-found"
    return {}, "not-found"
end

-- ============================================================================
-- GEN POINTS / OCCUPANCY
-- ============================================================================
local function genPoints(gen)
    local out = {}
    if not gen then return out end
    for _, ch in ipairs(gen:GetChildren()) do
        if ch:IsA("BasePart") and ch.Name:match("^GeneratorPoint%d+$") then
            table.insert(out, ch)
        end
    end
    return out
end
local function findNearestGeneratorPoint(gen, pos)
    if not gen or not pos then return nil end
    local best, bestD = nil, math.huge
    for _, pt in ipairs(genPoints(gen)) do
        local d = (pt.Position - pos).Magnitude
        if d < bestD then bestD, best = d, pt end
    end
    return best
end
local function getGenOccupancyMap(gen)
    local occ = {}
    if not gen or not gen.Parent then return occ end
    local pts = genPoints(gen)
    for _, pt in ipairs(pts) do
        for _, attr in ipairs({"Occupied","IsOccupied","InUse","IsInUse",
                               "User","Occupant","Survivor","Character","Owner","Player"}) do
            local ok, v = pcall(function() return pt:GetAttribute(attr) end)
            if ok and v ~= nil then
                if typeof(v) == "Instance" then
                    local p = Players:GetPlayerFromCharacter(v)
                    if p and p ~= localPlayer then occ[pt] = p end
                elseif v == true then occ[pt] = true end
            end
        end
        for _, c2 in ipairs(pt:GetChildren()) do
            if c2:IsA("ObjectValue") and c2.Value then
                local p = Players:GetPlayerFromCharacter(c2.Value)
                if p and p ~= localPlayer then occ[pt] = p end
            end
            if c2:IsA("BoolValue")
                and (c2.Name:lower():find("occupied") or c2.Name:lower():find("inuse")) then
                if c2.Value then occ[pt] = true end
            end
        end
    end
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= localPlayer and roleOfPlayer(p) == "Survivor" then
            local r = getPlayerRoot(p)
            if r then
                local st = getSurvivorState(p)
                if st and st ~= "dead" and st ~= "hooked" and st ~= "carried" then
                    local near, nearD = nil, CONFIG.GEN_POINT_PROXIMITY
                    for _, pt in ipairs(pts) do
                        if not occ[pt] then
                            local d = (r.Position - pt.Position).Magnitude
                            if d < nearD then nearD, near = d, pt end
                        end
                    end
                    if near then occ[near] = p end
                end
            end
        end
    end
    return occ
end
local function genBestAvailablePoint(gen, myRoot)
    if not gen or not gen.Parent then return nil, nil end
    local pts = genPoints(gen)
    if #pts == 0 then
        if gen:IsA("Model") and gen.PrimaryPart then return gen.PrimaryPart.Position, nil end
        if gen:IsA("BasePart") then return gen.Position, nil end
        for _,ch in ipairs(gen:GetChildren()) do
            if ch:IsA("BasePart") then return ch.Position, nil end
        end
        return nil, nil
    end
    local occ = getGenOccupancyMap(gen)
    local best, bestD = nil, math.huge
    for _, pt in ipairs(pts) do
        if not occ[pt] then
            if myRoot then
                local d = (myRoot.Position - pt.Position).Magnitude
                if d < bestD then bestD, best = d, pt end
            elseif not best then best = pt end
        end
    end
    if best then return best.Position, best end
    return nil, nil
end
local function isApproachPointAvailable(gen, apPos)
    if not gen or not apPos then return false end
    local pts = genPoints(gen); if #pts == 0 then return true end
    local occ = getGenOccupancyMap(gen)
    for _, pt in ipairs(pts) do
        if (pt.Position - apPos).Magnitude < 1.0 then return not occ[pt] end
    end
    return false
end

-- ============================================================================
-- GEN SCORING
-- ============================================================================
local TargetBlacklist = {}
local function isTargetBlacklisted(pos)
    if not pos then return false end
    local key = string.format("%.1f|%.1f|%.1f", pos.X, pos.Y, pos.Z)
    local t = TargetBlacklist[key]; if not t then return false end
    if tick() - t > CONFIG.PATH_FAIL_COOLDOWN then TargetBlacklist[key] = nil; return false end
    return true
end
local function scoreGenerator(gen, myRoot, killerPos)
    if not gen or not gen.Parent or not myRoot then return math.huge end
    if updateGeneratorProgress(gen) then return math.huge end
    local ap, pt = genBestAvailablePoint(gen, myRoot)
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
-- ENDGAME TRACKER
-- ============================================================================
local GameEnd = {
    completedGens  = {},
    completedCount = 0,
    lastScan       = 0,
    genEndgame     = false,
    lastSurvivorEndgame = false,
    endgameActive  = false,
    endgameReason  = nil,
    lastCompleteLog = 0,
}

local function hasActiveKiller()
    for _, p in ipairs(Players:GetPlayers()) do
        if roleOfPlayer(p) == "Killer" then
            if p.Character then
                local hum = p.Character:FindFirstChildOfClass("Humanoid")
                if hum and hum.Health > 0 then return true end
            end
        end
    end
    return false
end

local function countActiveSurvivors()
    local count = 0
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= localPlayer and roleOfPlayer(p) == "Survivor" then
            local st = getSurvivorState(p)
            if st == nil then
                if p.Character and p.Character:FindFirstChildOfClass("Humanoid") then
                    count = count + 1
                end
            elseif st ~= "dead" then
                count = count + 1
            end
        end
    end
    return count
end

local function updateGameEnd(now)
    if GameEnd.endgameActive then return end
    if now - GameEnd.lastScan < CONFIG.GAME_END_SCAN_INTERVAL then return end
    GameEnd.lastScan = now

    local list = getGeneratorList()
    for _, gen in ipairs(list) do
        if gen and gen.Parent then
            local prog = getGenProgress(gen)
            if prog and prog >= 100 then
                if not GameEnd.completedGens[gen] then
                    GameEnd.completedGens[gen] = true
                    GameEnd.completedCount = GameEnd.completedCount + 1
                    if CONFIG.DEBUG then
                        log(string.format("[ENDGAME] gen completed (%d/%d): %s",
                            GameEnd.completedCount, CONFIG.EXPECTED_GENS, gen:GetFullName()))
                    end
                end
            end
        end
    end

    if GameEnd.completedCount >= CONFIG.EXPECTED_GENS then
        GameEnd.genEndgame = true
    end
end

local function checkEndgame(now)
    if GameEnd.endgameActive then return true, GameEnd.endgameReason end

    updateGameEnd(now)
    if GameEnd.genEndgame then
        GameEnd.endgameActive = true
        GameEnd.endgameReason = "5gens"
        log(string.format("[ENDGAME] activated: %d/%d generators complete",
            GameEnd.completedCount, CONFIG.EXPECTED_GENS))
        return true, GameEnd.endgameReason
    end

    if hasActiveKiller() and countActiveSurvivors() == 0 then
        GameEnd.endgameActive = true
        GameEnd.lastSurvivorEndgame = true
        GameEnd.endgameReason = "lastSurvivor"
        log("[ENDGAME] activated: AI is last active survivor (killer present)")
        return true, GameEnd.endgameReason
    end

    return false, nil
end

local function resetGameEnd()
    GameEnd.completedGens = {}
    GameEnd.completedCount = 0
    GameEnd.lastScan = 0
    GameEnd.genEndgame = false
    GameEnd.lastSurvivorEndgame = false
    GameEnd.endgameActive = false
    GameEnd.endgameReason = nil
    GameEnd.lastCompleteLog = 0
end

-- ============================================================================
-- CHASE OBSTACLE (vault / pallet)
-- ============================================================================
local ObstacleCache = { windows = {}, pallets = {}, lastScan = 0 }

local function isRealWindow(name)
    if name == "Window" then return true end
    if name:match("^Window%d+$") then return true end
    return false
end
local function isRealPallet(name)
    if name == "Pallet" then return true end
    if name:match("^Pallet%d+$") then return true end
    if name:match("^PalletPoint%d+$") then return true end
    return false
end
local function scanObstacles(force)
    local now = tick()
    if not force and (now - ObstacleCache.lastScan) < CONFIG.CHASE_SCAN_INTERVAL then return end
    ObstacleCache.lastScan = now
    ObstacleCache.windows = {}; ObstacleCache.pallets = {}
    local function scan(node, depth)
        if depth > 4 or not node then return end
        for _,ch in ipairs(node:GetChildren()) do
            if ch:IsA("BasePart") then
                if isRealWindow(ch.Name) then table.insert(ObstacleCache.windows, ch)
                elseif isRealPallet(ch.Name) then table.insert(ObstacleCache.pallets, ch) end
            elseif ch:IsA("Folder") or ch:IsA("Model") then
                scan(ch, depth+1)
            end
        end
    end
    pcall(scan, workspace, 0)
end

local function findChaseVaultWindow(myRoot, killerRoot, maxDist)
    if not myRoot or not killerRoot then return nil end
    scanObstacles()
    maxDist = maxDist or CONFIG.CHASE_VAULT_RANGE
    local myPos = myRoot.Position
    local killerPos = killerRoot.Position
    local best, bestD = nil, maxDist
    for _,w in ipairs(ObstacleCache.windows) do
        if w.Parent then
            local d = (myPos - w.Position).Magnitude
            if d < bestD then
                local dKW = (killerPos - w.Position).Magnitude
                local dKM = (killerPos - myPos).Magnitude
                if dKW > dKM - 3 then
                    if hasClearLine(myPos, w.Position, nil, d + 2) then bestD = d; best = w end
                end
            end
        end
    end
    return best
end

local function findPalletForDrop(myRoot, killerRoot, maxDist)
    if not myRoot or not killerRoot then return nil end
    scanObstacles()
    maxDist = maxDist or CONFIG.CHASE_PALLET_RANGE
    local myPos = myRoot.Position
    local killerPos = killerRoot.Position
    local best, bestD = nil, maxDist
    for _,p in ipairs(ObstacleCache.pallets) do
        if p.Parent then
            local d = (myPos - p.Position).Magnitude
            if d < bestD then
                local toKiller = killerPos - myPos
                local toPallet = p.Position - myPos
                if toKiller.Magnitude > 0.1 and toPallet.Magnitude > 0.1 then
                    local dot = toKiller.Unit:Dot(toPallet.Unit)
                    if dot > 0.5 and hasClearLine(myPos, p.Position, nil, d + 2) then
                        bestD = d; best = p
                    end
                end
            end
        end
    end
    return best
end

-- ============================================================================
-- [R27] EXIT GATE SCAN — multiple gates, verified open indicators
-- ============================================================================
local ExitCache = {
    gates = {},
    lastScan = 0,
    everHadGates = false,
    lastDiag = 0,
    allExpiredSince = nil,
    openGateExitObj = nil,
}

local function scanExitGates()
    local out = {}
    local root = workspace:FindFirstChild("Map") or workspace

    local function addGate(exitObj, leverGoal)
        if not exitObj then return end
        for _, g in ipairs(out) do
            if g.exitObj == exitObj then
                if not g.leverGoal and leverGoal then g.leverGoal = leverGoal end
                return
            end
        end
        table.insert(out, { exitObj = exitObj, leverGoal = leverGoal })
    end

    local function isExitFolderName(nm)
        if type(nm) ~= "string" then return false end
        return nm:match("^Exit") or nm:lower():find("exit") or nm:lower():find("gate")
    end

    for _, folder in ipairs(root:GetChildren()) do
        if (folder:IsA("Folder") or folder:IsA("Model")) and isExitFolderName(folder.Name) then
            local foundLevers = false
            for _, child in ipairs(folder:GetChildren()) do
                if child.Name == "ExitLever" or child.Name:match("^ExitLever%d+$") then
                    foundLevers = true
                    local lg = child:FindFirstChild("LeverGoal", true)
                    addGate(child, (lg and lg:IsA("BasePart")) and lg or nil)
                end
            end
            if not foundLevers then
                local lg = folder:FindFirstChild("LeverGoal", true)
                addGate(folder, (lg and lg:IsA("BasePart")) and lg or nil)
            end
        end
    end
    return out
end

local function checkExitGates(now)
    local cacheValid = (#ExitCache.gates > 0)
        and (now - ExitCache.lastScan < CONFIG.LEVER_RESCAN_INTERVAL)
    if cacheValid then
        local alive = true
        for _, g in ipairs(ExitCache.gates) do
            if not g.exitObj or not g.exitObj.Parent then alive = false; break end
        end
        if alive then return ExitCache.gates end
    end

    ExitCache.lastScan = now
    local fresh = scanExitGates()

    if #fresh ~= #ExitCache.gates then
        log(string.format("[EXIT] gate scan: %d gate(s) found", #fresh))
        for i, g in ipairs(fresh) do
            log(string.format("  [%d] exit=%s leverGoal=%s",
                i,
                g.exitObj:GetFullName(),
                (g.leverGoal and g.leverGoal:GetFullName()) or "<none>"))
        end
    end
    ExitCache.gates = fresh
    if #fresh > 0 then ExitCache.everHadGates = true end
    return fresh
end

-- [R27] Only trusts indicators we can actually observe at runtime.
local function isGateVisiblyOpen(gate)
    if not gate then return false, nil end
    local exitObj = gate.exitObj
    if exitObj and exitObj.Parent then
        local main = exitObj:FindFirstChild("Main")
        if main and main:IsA("BasePart") then
            if main.CanCollide == false then
                return true, "Main.CanCollide=false"
            end
            local mattrs = main:GetAttributes()
            for _, key in ipairs({"Used","Opened","IsOpen","Activated"}) do
                if mattrs[key] == true then return true, "Main.attr:"..key end
            end
        end
        local eattrs = exitObj:GetAttributes()
        for _, key in ipairs({"Used","Opened","IsOpen","Activated","Done","Consumed"}) do
            if eattrs[key] == true then return true, "exitObj.attr:"..key end
        end
    end
    local leverGoal = gate.leverGoal
    if leverGoal and leverGoal.Parent then
        local lattrs = leverGoal:GetAttributes()
        for _, key in ipairs({"Used","Opened","IsOpen","Activated","Done","Consumed","Inactive"}) do
            if lattrs[key] == true then return true, "leverGoal.attr:"..key end
        end
    end
    return false, nil
end

local function findNearestFinishline(fromPos)
    local candidates = {}
    local function scan(node, depth)
        if depth > 6 or not node then return end
        for _,ch in ipairs(node:GetChildren()) do
            if ch:IsA("BasePart") then
                local lower = ch.Name:lower()
                if lower:find("finish") or lower:find("fininsh")
                    or lower == "goal" or lower == "endgoal"
                    or lower == "endpoint" or lower == "endline"
                    or lower == "escapepoint" or lower == "escapedoor" then
                    table.insert(candidates, ch)
                end
            elseif ch:IsA("Folder") or ch:IsA("Model") then
                scan(ch, depth+1)
            end
        end
    end
    pcall(scan, workspace, 0)
    if #candidates == 0 then return nil end
    if #candidates == 1 then return candidates[1] end
    local best, bestD = nil, math.huge
    for _, c in ipairs(candidates) do
        local d = (c.Position - fromPos).Magnitude
        if d < bestD then bestD, best = d, c end
    end
    return best
end

-- ============================================================================
-- RESCUE / HEAL
-- ============================================================================
local function findHookedTarget()
    local myRoot = getRoot(); if not myRoot then return nil end
    local best, bestD = nil, math.huge
    for _,p in ipairs(Players:GetPlayers()) do
        if p ~= localPlayer and roleOfPlayer(p) == "Survivor" then
            local st = getSurvivorState(p)
            if st == "hooked" then
                local r = getPlayerRoot(p)
                if r then
                    local d = (myRoot.Position - r.Position).Magnitude
                    if d < bestD and d <= CONFIG.RESCUE_DETECT_RANGE then
                        bestD = d; best = { player=p, root=r }
                    end
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
local function isKillerSafeForRescue(killerRoot, hookedRoot)
    if not killerRoot or not hookedRoot then return true end
    local kDist = (hookedRoot.Position - killerRoot.Position).Magnitude
    if kDist > CONFIG.RESCUE_SAFE_DIST then return true end
    local v = killerRoot.AssemblyLinearVelocity
    if v and v.Magnitude > 5 then
        local toHooked = hookedRoot.Position - killerRoot.Position
        if toHooked.Magnitude > 0.1 and v.Unit:Dot(toHooked.Unit) < -0.5 then
            if kDist > CONFIG.RESCUE_SAFE_DIST_FAST then return true end
        end
    end
    return false
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
    forceRescan = false,
    lastSlotCheck = 0,
    repairWaitStart = 0,
    lastVaultAttempt = 0,
    lastPalletAttempt = 0,
    lastRescueBlockedLog = 0,
    hangDetectStart = 0,
    exitFinishline = nil,
    lastFinishlineSearch = 0,
    lastKnockLog = 0,
}

local function survivorReset()
    Survivor.State = "WaitingForCharacter"
    Survivor.targetGen = nil; Survivor.approachPos = nil
    Survivor.lastGenScan = 0; Survivor.lastProgress = nil; Survivor.lastProgressT = 0
    Survivor.failedGens = {}
    Survivor.lastLoggedGen = nil; Survivor.lastNoGenLog = 0
    Survivor.lastSearchLog = 0; Survivor.lastSwitchT = 0
    Survivor.searchStateSince = 0; Survivor.lastSearchDiag = 0
    Survivor.forceRescan = false
    Survivor.lastSlotCheck = 0
    Survivor.repairWaitStart = 0
    Survivor.lastVaultAttempt = 0; Survivor.lastPalletAttempt = 0
    Survivor.lastRescueBlockedLog = 0
    Survivor.hangDetectStart = 0
    Survivor.exitFinishline = nil
    Survivor.lastFinishlineSearch = 0
    Survivor.lastKnockLog = 0
    cancelGoal(); resetThreat(); resetPerception()
    resetEvasion("survivorReset")
    clearChaseAction()
    stopRepair("survivorReset")
    stopLeverSession("survivorReset")
    releaseShift(); endHoldAction(); endShiftInteract()
end

local function setSurvivorState(newState, now, extra)
    if Survivor.State ~= newState then
        local oldState = Survivor.State
        local oldAction = ACTION_BY_STATE[oldState]
        local newAction = ACTION_BY_STATE[newState]
        if oldAction and ActionState.current == oldAction and oldAction ~= newAction then
            requestStopAction()
        end
        if oldState == "RepairingGenerator" and newState ~= "RepairingGenerator" then
            fireGenDone(); notifyRepairEnded()
            if RepairSession.state ~= "idle" then
                stopRepair("state-leave-repair")
            end
        end
        log(string.format("Survivor: %s → %s %s", oldState, newState, extra or ""))
        Survivor.lastStateLog = now
        Survivor.State = newState
        if newState ~= "SearchingGenerator" then Survivor.searchStateSince = 0 end
    end
end

local function survivorPickGenerator(now, killerPos, exclude)
    local myRoot = getRoot(); if not myRoot then return false end
    local current = Survivor.targetGen
    local currentValid = current and current.Parent and not updateGeneratorProgress(current)

    local currentAp, currentPt = nil, nil
    if currentValid then
        currentAp, currentPt = genBestAvailablePoint(current, myRoot)
        if not currentAp then
            if now - (Survivor.lastNoGenLog or 0) > 3 then
                Survivor.lastNoGenLog = now
                if CONFIG.DEBUG then log("Survivor: current gen slots all occupied → re-evaluate") end
            end
            currentValid = false
        end
    end

    local currentScore = currentValid and scoreGenerator(current, myRoot, killerPos) or math.huge
    local currentBl = currentValid and isTargetBlacklisted(currentAp or Vector3.zero)

    if Survivor.forceRescan then
        Survivor.forceRescan = false
        currentValid = false
    end

    if currentValid and currentScore < math.huge and not currentBl then
        if (now - Survivor.lastSwitchT) > CONFIG.GEN_RESCAN_COOLDOWN then
            local newGen = findBestGenerator(myRoot, killerPos, exclude)
            if newGen and newGen ~= current then
                local ns = scoreGenerator(newGen, myRoot, killerPos)
                if ns < currentScore - CONFIG.GEN_SWITCH_MARGIN then
                    Survivor.targetGen = newGen
                    Survivor.approachPos = select(1, genBestAvailablePoint(newGen, myRoot))
                    Survivor.lastSwitchT = now
                    if CONFIG.DEBUG then
                        log(string.format("Survivor: switch → %s (Δ=%.1f)",
                            newGen:GetFullName(), currentScore - ns))
                    end
                    return true
                end
            end
        end
        Survivor.approachPos = currentAp
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
            Survivor.approachPos = currentAp
            Survivor.lastGenScan = now
            return true
        end
        if now - Survivor.lastNoGenLog > 3 then
            Survivor.lastNoGenLog = now
            log("Survivor: no gen | "..tostring(reason))
        end
        return false
    end

    Survivor.targetGen = g
    Survivor.approachPos = select(1, genBestAvailablePoint(g, myRoot))
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

local function hangWatchdog(now)
    if not ActionState.current and RepairSession.state == "idle" and LeverSession.state == "idle" then
        Survivor.hangDetectStart = 0; return
    end
    local killers = evaluateKillers()
    local kD = (#killers > 0) and killers[1].dist or math.huge

    if Survivor.hangDetectStart == 0 then Survivor.hangDetectStart = now; return end
    local hangDur = now - Survivor.hangDetectStart

    if kD <= CONFIG.HANG_FAR_DIST then
        if ActionState.current ~= "vault" and ActionState.current ~= "palletDrop"
            and ActionState.current ~= "palletSlide" and ActionState.current ~= "exit" then
            if ActionState.phase ~= "stopping" then
                requestStopAction()
            end
            if RepairSession.state ~= "idle" then
                stopRepair("hang-watchdog-killer-close")
            end
        end
    else
        if hangDur > CONFIG.HANG_FORCE_CLEAR_TIME then
            if ActionState.phase == "stopping" then
                ActionState.current = nil; ActionState.phase = "idle"
                ActionState.cooldownUntil = now + 0.5
                endHoldAction(); endShiftInteract()
            elseif ActionState.phase == "active" and hangDur > 20 then
                ActionState.current = nil; ActionState.phase = "idle"
                ActionState.cooldownUntil = now + 0.5
                endHoldAction(); endShiftInteract()
            end
            Survivor.hangDetectStart = 0
        end
    end
end

-- [R27] Finishline bound to specific open gate's exitObj
local function handleFinishline(now, root, hum, exitObj, leverGoal)
    local gateRef = exitObj or leverGoal
    if ExitCache.openGateExitObj ~= gateRef then
        ExitCache.openGateExitObj = gateRef
        Survivor.exitFinishline = nil
        Survivor.lastFinishlineSearch = 0
    end

    if not Survivor.exitFinishline or not Survivor.exitFinishline.Parent then
        if now - (Survivor.lastFinishlineSearch or 0) > CONFIG.FINISHLINE_RESCAN_GAP then
            Survivor.lastFinishlineSearch = now
            local refPos = (leverGoal and leverGoal.Parent and leverGoal.Position)
                        or (exitObj and exitObj:IsA("BasePart") and exitObj.Position)
                        or (exitObj and exitObj.PrimaryPart and exitObj.PrimaryPart.Position)
                        or root.Position
            Survivor.exitFinishline = findNearestFinishline(refPos)
            if Survivor.exitFinishline then
                log("[EXIT] gate open → Finishline target: "..Survivor.exitFinishline:GetFullName())
            else
                log("[EXIT] gate open but no finishline part found near "..tostring(refPos).." (will retry)")
            end
        end
    end
    setSurvivorState("EscapingMap", now, "(gate open)")
    if Survivor.exitFinishline and Survivor.exitFinishline.Parent then
        local dF = (root.Position - Survivor.exitFinishline.Position).Magnitude
        if dF <= CONFIG.FINISH_REACH_DIST then
            log("[EXIT] FINISH REACHED!")
            hum:Move(Vector3.zero, false)
            cancelGoal()
            if LeverSession.state ~= "idle" and LeverSession.state ~= "finished" then
                stopLeverSession("finished")
            end
            LeverSession.state = "finished"
            return true
        end
        holdShift()
        setGoal(Survivor.exitFinishline.Position, "finish")
        followStep()
    else
        hum:Move(Vector3.zero, false)
    end
    return true
end

-- [R27] Multi-gate handling
local function handleExitPhase(now, root, hum)
    local gates = checkExitGates(now)
    if #gates == 0 then
        if LeverSession.state ~= "idle" and LeverSession.state ~= "finished" then
            stopLeverSession("no-gates")
        end
        if ExitCache.everHadGates then
            ExitCache.allExpiredSince = ExitCache.allExpiredSince or now
            if now - ExitCache.allExpiredSince > 3 then
                if CONFIG.DEBUG then log("[EXIT] All gates gone - assuming endgame") end
                return handleFinishline(now, root, hum, nil, nil)
            end
        end
        return false
    end

    local openGate, openReason = nil, nil
    local candidates = {}
    for _, gate in ipairs(gates) do
        local isOpen, reason = isGateVisiblyOpen(gate)
        if isOpen then
            if not openGate then openGate = gate; openReason = reason end
        elseif gate.leverGoal and gate.leverGoal.Parent then
            local d = (root.Position - gate.leverGoal.Position).Magnitude
            table.insert(candidates, { gate = gate, dist = d })
        end
    end

    if openGate then
        if LeverSession.state == "interacting" or LeverSession.state == "approaching" then
            stopLeverSession("gate-open:"..tostring(openReason))
        end
        LeverSession.state = "gateOpen"
        return handleFinishline(now, root, hum, openGate.exitObj, openGate.leverGoal)
    end

    if #candidates == 0 then
        ExitCache.allExpiredSince = ExitCache.allExpiredSince or now
        if now - ExitCache.lastDiag > 3 then
            ExitCache.lastDiag = now
            log(string.format("[EXIT] %d gate(s), none visibly open, no live leverGoal (%.1fs)",
                #gates, now - ExitCache.allExpiredSince))
        end
        if now - ExitCache.allExpiredSince > 3 then
            if CONFIG.DEBUG then log("[EXIT] All gate levers expired - proceeding to finishline") end
            return handleFinishline(now, root, hum,
                gates[1] and gates[1].exitObj or nil, nil)
        end
        return false
    end
    ExitCache.allExpiredSince = nil

    table.sort(candidates, function(a,b) return a.dist < b.dist end)
    local targetGate = candidates[1].gate
    local leverGoal = targetGate.leverGoal
    local d = (root.Position - leverGoal.Position).Magnitude

    if LeverSession.state == "interacting"
        and now - LeverSession.startedAt > CONFIG.LEVER_INTERACT_TIMEOUT then
        if CONFIG.DEBUG then log("[LEVER] interact timeout") end
        stopLeverSession("interact-timeout")
    end
    if LeverSession.state == "approaching"
        and now - LeverSession.startedAt > CONFIG.LEVER_APPROACH_TIMEOUT then
        if CONFIG.DEBUG then log("[LEVER] approach timeout") end
        stopLeverSession("approach-timeout")
    end

    if d <= CONFIG.EXIT_INTERACT_R then
        hum:Move(Vector3.zero, false)
        cancelGoal()
        if RepairSession.state ~= "idle" then stopRepair("exit-lever") end
        if ActionState.current and ActionState.current ~= "exit" then requestStopAction() end

        if LeverSession.state == "idle" then
            startLeverSession(leverGoal)
        elseif LeverSession.state == "interacting" then
            if LeverSession.target ~= leverGoal then
                stopLeverSession("target-changed")
                startLeverSession(leverGoal)
            end
        elseif LeverSession.state == "approaching" then
            LeverSession.target = leverGoal
            LeverSession.state = "interacting"
            LeverSession.startedAt = now
            fireLeverStart(leverGoal)
        end
        setSurvivorState("EscapingMap", now, "(interacting lever)")
    else
        if LeverSession.state == "idle" then
            LeverSession.state = "approaching"
            LeverSession.target = leverGoal
            LeverSession.startedAt = now
        elseif LeverSession.state == "interacting" then
            stopLeverSession("out-of-range")
            LeverSession.state = "approaching"
            LeverSession.target = leverGoal
            LeverSession.startedAt = now
        end
        setSurvivorState("EscapingMap", now, string.format("(to lever d=%.1f)", d))
        holdShift()
        setGoal(leverGoal.Position, "exit")
        followStep()
    end
    return true
end

local function enterKnockedIdle(now, hum)
    if Survivor.State ~= "KnockedIdle" then
        if now - (Survivor.lastKnockLog or 0) > 1 then
            Survivor.lastKnockLog = now
            log("[KNOCK] AI knocked → KnockedIdle (idle, no selfHeal)")
        end
    end
    setSurvivorState("KnockedIdle", now)
    stopRepair("knocked")
    stopLeverSession("knocked")
    endHoldAction(); releaseShift(); endShiftInteract(); cancelGoal()
    resetEvasion("knocked"); clearChaseAction()
    if hum then hum:Move(Vector3.zero, false) end
end

local function enterBeingHealed(now, hum)
    setSurvivorState("BeingHealed", now)
    stopRepair("being-healed")
    stopLeverSession("being-healed")
    endHoldAction(); releaseShift(); endShiftInteract(); cancelGoal()
    resetEvasion("being-healed"); clearChaseAction()
    if hum then hum:Move(Vector3.zero, false) end
end

local function SurvivorAI(now)
    local hum = getHumanoid()
    local root = getRoot()
    if not hum or not root or hum.Health <= 0 then
        Survivor.State = "WaitingForCharacter"
        stopRepair("dead-or-nohum")
        stopLeverSession("dead-or-nohum")
        notifyRepairEnded(); releaseShift(); endHoldAction(); endShiftInteract(); cancelGoal()
        resetEvasion("dead-or-nohum"); clearChaseAction()
        return
    end

    local char = getChar()
    local selfState = getSelfState()

    if selfState == "dead" then
        setSurvivorState("Dead", now)
        stopRepair("dead"); stopLeverSession("dead")
        endHoldAction(); releaseShift(); endShiftInteract(); cancelGoal()
        resetEvasion("dead"); clearChaseAction()
        return
    end
    if selfState == "hooked" then
        setSurvivorState("Hooked", now)
        stopRepair("hooked"); stopLeverSession("hooked")
        endHoldAction(); releaseShift(); endShiftInteract(); cancelGoal()
        resetEvasion("hooked"); clearChaseAction()
        return
    end
    if selfState == "carried" then
        setSurvivorState("Carried", now)
        stopRepair("carried"); stopLeverSession("carried")
        endHoldAction(); releaseShift(); endShiftInteract(); cancelGoal()
        resetEvasion("carried"); clearChaseAction()
        return
    end
    if selfState == "knocked" then
        enterKnockedIdle(now, hum)
        return
    end
    if char and char:GetAttribute("IsBeingHealed") == true then
        enterBeingHealed(now, hum)
        return
    end

    hangWatchdog(now)

    local killer, killerRoot, kD, threat, P = updateThreat(now)

    -- ========================================================================
    -- [R27] EVASION BRANCH
    -- ========================================================================
    local evActive = updateEvasionGating(killerRoot, kD, now)
    if evActive then
        local extraDesc
        if killerRoot then
            extraDesc = string.format("(d=%.1f)", kD)
        else
            extraDesc = "(killer-lost)"
        end
        setSurvivorState("EvadingKiller", now, extraDesc)

        if RepairSession.state == "active" or RepairSession.state == "starting" then
            stopRepair("evasion-enter")
        end
        if LeverSession.state ~= "idle" and LeverSession.state ~= "finished" then
            stopLeverSession("evasion-enter")
        end
        if ActionState.current
            and ActionState.current ~= "vault"
            and ActionState.current ~= "palletDrop"
            and ActionState.current ~= "palletSlide" then
            if ActionState.phase ~= "stopping" then
                requestStopAction()
            end
        end

        if killerRoot then
            if ChaseAction.kind then
                if updateChaseAction(root, hum, now) then return end
            end
            if not ChaseAction.kind and kD <= CONFIG.VAULT_USE_D
                and (now - Survivor.lastVaultAttempt) > 1.0 then
                local vault = findChaseVaultWindow(root, killerRoot, CONFIG.CHASE_VAULT_RANGE)
                if vault then
                    ChaseAction.kind = "vault"
                    ChaseAction.target = vault
                    ChaseAction.startedAt = now
                    Survivor.lastVaultAttempt = now
                    if CONFIG.DEBUG then log("[CHASE] vault @ "..vault:GetFullName()) end
                    if updateChaseAction(root, hum, now) then return end
                end
            end
            if not ChaseAction.kind and kD <= CONFIG.PALLET_DROP_D
                and (now - Survivor.lastPalletAttempt) > 1.0 then
                local pallet = findPalletForDrop(root, killerRoot, CONFIG.CHASE_PALLET_RANGE)
                if pallet then
                    ChaseAction.kind = "palletDrop"
                    ChaseAction.target = pallet
                    ChaseAction.startedAt = now
                    Survivor.lastPalletAttempt = now
                    if CONFIG.DEBUG then log("[CHASE] palletDrop @ "..pallet:GetFullName()) end
                    if updateChaseAction(root, hum, now) then return end
                end
            end
            driveEvasion(root, killerRoot, hum, now)
        else
            -- Killer lost but gating hasn't cleared: keep following last waypoint via path
            holdShift()
            if Evasion.targetPos then
                setGoal(Evasion.targetPos, "evade", false)
                followStep()
            end
        end
        return
    end

    if Survivor.State == "EvadingKiller" then
        local endgameNow = GameEnd.endgameActive
        endHoldAction(); releaseShift(); endShiftInteract()
        cancelGoal(); resetEvasion("evade-done"); clearChaseAction()
        if endgameNow then
            log("Survivor: evade done → resume endgame")
        else
            log("Survivor: evade done → re-evaluate")
            Survivor.targetGen = nil; Survivor.approachPos = nil
            Survivor.lastGenScan = 0; Survivor.lastSwitchT = 0
            Survivor.lastLoggedGen = nil; Survivor.forceRescan = true
            setSurvivorState("SearchingGenerator", now)
        end
    end

    local endgameActive, endgameReason = checkEndgame(now)
    if endgameActive then
        if handleExitPhase(now, root, hum) then return end
        setSurvivorState("EscapingMap", now, "("..tostring(endgameReason).." - awaiting exit)")
        if Survivor.exitFinishline and Survivor.exitFinishline.Parent then
            local dF = (root.Position - Survivor.exitFinishline.Position).Magnitude
            if dF > CONFIG.FINISH_REACH_DIST then
                holdShift()
                setGoal(Survivor.exitFinishline.Position, "finish")
                followStep()
            end
        else
            hum:Move(Vector3.zero, false)
        end
        return
    end

    do
        local rt, rd = findHookedTarget()
        if rt then
            local safe = isKillerSafeForRescue(killerRoot, rt.root)
            if safe then
                setSurvivorState("RescuingSurvivor", now, string.format("(d=%.1f)", rd))
                holdShift()
                if rd <= CONFIG.RESCUE_ACTION_R then
                    hum:Move(Vector3.zero, false)
                    cancelGoal()
                    if ActionState.current ~= "unhook" and now >= ActionState.cooldownUntil then
                        startAction("unhook", rt.root)
                    end
                else
                    if ActionState.current == "unhook" then requestStopAction() end
                    setGoal(rt.root.Position, "rescue")
                    followStep()
                end
                return
            else
                if now - Survivor.lastRescueBlockedLog > 5 then
                    Survivor.lastRescueBlockedLog = now
                    if CONFIG.DEBUG then
                        local kDist = killerRoot and (rt.root.Position - killerRoot.Position).Magnitude or math.huge
                        log(string.format("[RESCUE] blocked: hooked=%s kDist=%.1f safe=%.1f",
                            rt.player.Name, kDist, CONFIG.RESCUE_SAFE_DIST))
                    end
                end
            end
        end
    end

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
                    if ActionState.current ~= "heal" and now >= ActionState.cooldownUntil then
                        startAction("heal", ht.root)
                    end
                else
                    if ActionState.current == "heal" then requestStopAction() end
                    setGoal(ht.root.Position, "heal")
                    followStep()
                end
                return
            end
        end
    end

    if Survivor.State == "AllDone" then
        if now - Survivor.lastGenScan > 3 then
            Survivor.lastGenScan = now
            if findBestGenerator(root, nil) then
                Survivor.State = "SearchingGenerator"
                Survivor.lastLoggedGen = nil
            end
        end
        if RepairSession.state ~= "idle" then stopRepair("allDone") end
        notifyRepairEnded(); releaseShift(); endHoldAction(); endShiftInteract(); cancelGoal()
        return
    end

    if Survivor.State == "SearchingGenerator" then
        Survivor.searchStateSince = (Survivor.searchStateSince == 0) and now or Survivor.searchStateSince
        local searchDur = now - Survivor.searchStateSince
        if searchDur > CONFIG.SEARCH_STUCK_RESCAN then
            log(string.format("[DIAG] Stuck searching %.1fs → force cache clear + rescan", searchDur))
            GenRegistry.container = nil
            GenRegistry.list = {}
            GenRegistry.lastScan = 0
            GenRegistry.lastCount = -1
            GenRegistry.lastReason = ""
            for k in pairs(TargetBlacklist) do TargetBlacklist[k] = nil end
            -- [FIX] Removed: for k in pairs(PathMemo) do PathMemo[k] = nil end
            Survivor.forceRescan = true
            Survivor.searchStateSince = now
        end
        if searchDur > CONFIG.SEARCH_STUCK_LOG
            and now - Survivor.lastSearchDiag > CONFIG.SEARCH_STUCK_LOG then
            Survivor.lastSearchDiag = now
            local list, reason = getGeneratorList()
            log(string.format("[SearchDiag] %.1fs | list=%d reason=%s",
                searchDur, #list, tostring(reason)))
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
                cancelGoal(); endHoldAction(); endShiftInteract()
                notifyRepairEnded(); releaseShift()
            else
                setSurvivorState("SearchingGenerator", now)
                cancelGoal(); endHoldAction(); endShiftInteract()
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
        cancelGoal(); endHoldAction(); endShiftInteract()
        return
    end

    local ap = Survivor.approachPos
    local validAp = select(1, genBestAvailablePoint(gen, root))
    if not validAp then
        Survivor.targetGen = nil; Survivor.approachPos = nil
        setSurvivorState("SearchingGenerator", now)
        stopRepair("no-slot")
        endHoldAction(); endShiftInteract(); notifyRepairEnded(); cancelGoal()
        return
    end
    if (not ap) or (not isApproachPointAvailable(gen, ap))
        or ((validAp - ap).Magnitude > 3.0) then
        ap = validAp
        Survivor.approachPos = ap
    else
        ap = Survivor.approachPos
    end

    local d = (root.Position - ap).Magnitude
    local inActionRange = (d <= CONFIG.SURV_GEN_ACTION_R)
    local inHysteresis  = (d <= CONFIG.SURV_GEN_ACTION_R + CONFIG.SURV_GEN_HYSTERESIS)
    local stayInRepair  = (Survivor.State == "RepairingGenerator" and inHysteresis)

    if inActionRange or stayInRepair then
        if not isApproachPointAvailable(gen, ap) then
            Survivor.targetGen = nil; Survivor.approachPos = nil
            setSurvivorState("SearchingGenerator", now)
            stopRepair("slot-taken")
            endHoldAction(); endShiftInteract(); notifyRepairEnded(); cancelGoal()
            return
        end

        if Survivor.State ~= "RepairingGenerator" then
            setSurvivorState("RepairingGenerator", now)
            Survivor.lastProgress = getGenProgress(gen)
            Survivor.lastProgressT = now
            Survivor.repairWaitStart = now
            notifyRepairStarted()
            cancelGoal()
            releaseShift()
            if CONFIG.DEBUG then log("Survivor: repair start "..gen:GetFullName()) end
        end

        if inActionRange then
            hum:Move(Vector3.zero, false)
        else
            hum:MoveTo(ap)
        end

        if RepairSession.state == "idle" and now >= RepairSession.nextStartAt then
            local pt = findNearestGeneratorPoint(gen, ap)
            if pt then
                startRepair(gen, pt)
            end
        end

        local cur = getGenProgress(gen)
        if cur and Survivor.lastProgress and cur > Survivor.lastProgress then
            Survivor.lastProgress = cur
            Survivor.lastProgressT = now
            Survivor.repairWaitStart = now
        end
        if now - Survivor.lastProgressT > CONFIG.REPAIR_PROGRESS_WATCH then
            log("Survivor: gen no progress → abandon & blacklist")
            Survivor.failedGens[gen] = now
            setSurvivorState("SearchingGenerator", now)
            Survivor.lastGenScan = 0; Survivor.lastLoggedGen = nil
            stopRepair("no-progress")
            endHoldAction(); endShiftInteract(); notifyRepairEnded(); cancelGoal()
            return
        end

        if RepairSession.state == "idle"
            and now - Survivor.repairWaitStart > CONFIG.REPAIR_GIVEUP_TIME then
            log("Survivor: repair can't start → abandon gen")
            Survivor.failedGens[gen] = now
            Survivor.targetGen = nil; Survivor.approachPos = nil
            setSurvivorState("SearchingGenerator", now)
            endHoldAction(); endShiftInteract(); notifyRepairEnded(); cancelGoal()
            return
        end
    else
        setSurvivorState("MovingToGenerator", now, string.format("(d=%.1f)", d))
        if RepairSession.state ~= "idle" then stopRepair("moving-to-gen") end
        if now - (Survivor.lastSlotCheck or 0) > CONFIG.GEN_SLOT_RECHECK then
            Survivor.lastSlotCheck = now
            if not isApproachPointAvailable(gen, ap) then
                Survivor.targetGen = nil; Survivor.approachPos = nil
                setSurvivorState("SearchingGenerator", now)
                endHoldAction(); endShiftInteract(); notifyRepairEnded(); cancelGoal()
                return
            end
        end
        notifyRepairEnded()
        endHoldAction(); endShiftInteract()
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
    cancelGoal(); releaseShift(); endHoldAction(); endShiftInteract()
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
-- GUI STATUS
-- ============================================================================
local readyGui, readyLabel = nil, nil
local guiWatchConn = nil
local guiRecreateCount = 0
local lastGuiRecreateLog = 0
local function createReadyGui()
    if readyGui then pcall(function() readyGui:Destroy() end); readyGui = nil end
    readyLabel = nil
    local pg = localPlayer:FindFirstChild("PlayerGui"); if not pg then return false end
    readyGui = Instance.new("ScreenGui")
    readyGui.Name = "KemiAI_Ready"; readyGui.ResetOnSpawn = false
    readyGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    readyGui.IgnoreGuiInset = true; readyGui.Enabled = true
    readyGui.DisplayOrder = 1000; readyGui.Parent = pg
    readyLabel = Instance.new("TextLabel")
    readyLabel.AnchorPoint = Vector2.new(0,1)
    readyLabel.Position = UDim2.new(0,14,1,-14)
    readyLabel.Size = UDim2.new(0,700,0,18)
    readyLabel.BackgroundTransparency = 1
    readyLabel.Text = "AI ready [waiting]"
    readyLabel.TextColor3 = Color3.fromRGB(0,255,120)
    readyLabel.TextStrokeTransparency = 0.4
    readyLabel.TextStrokeColor3 = Color3.fromRGB(0,0,0)
    readyLabel.Font = Enum.Font.GothamBold
    readyLabel.TextSize = 14
    readyLabel.TextXAlignment = Enum.TextXAlignment.Left
    readyLabel.Visible = true; readyLabel.Parent = readyGui
    return true
end
local function bindGuiWatch()
    if guiWatchConn then pcall(function() guiWatchConn:Disconnect() end); guiWatchConn = nil end
    local pg = localPlayer:FindFirstChild("PlayerGui"); if not pg then return end
    guiWatchConn = pg.ChildRemoved:Connect(function(child)
        if child == readyGui then
            task.defer(function()
                if readyGui and not readyGui.Parent then
                    if createReadyGui() then bindGuiWatch() end
                end
            end)
        end
    end)
end
local function ensureGuiAlive()
    local pg = localPlayer:FindFirstChild("PlayerGui"); if not pg then return end
    local needsRecreate = true
    if readyGui and readyGui.Parent == pg and readyGui.Enabled == true
        and readyLabel and readyLabel.Parent == readyGui and readyLabel.Visible == true then
        needsRecreate = false
    end
    if needsRecreate then
        guiRecreateCount = guiRecreateCount + 1
        local now = tick()
        if now - lastGuiRecreateLog > 1 then
            lastGuiRecreateLog = now
            if CONFIG.DEBUG then log(string.format("GUI recreate (#%d)", guiRecreateCount)) end
        end
        if createReadyGui() then bindGuiWatch() end
    end
end

createReadyGui()
bindGuiWatch()

-- ============================================================================
-- MAP CACHE INVALIDATION
-- ============================================================================
local function resetMapCaches()
    GenRegistry.container = nil
    GenRegistry.list = {}
    GenRegistry.lastScan = 0
    GenRegistry.lastCount = -1
    GenRegistry.lastReason = ""
    for k in pairs(TargetBlacklist) do TargetBlacklist[k] = nil end
    -- [FIX] Removed: for k in pairs(PathMemo) do PathMemo[k] = nil end
    FenceCache.list = {}; FenceCache.lastScan = 0
    ObstacleCache.windows = {}; ObstacleCache.pallets = {}; ObstacleCache.lastScan = 0
end

-- ============================================================================
-- ROLE WATCHER + MAIN LOOP
-- ============================================================================
local currentRole = nil
local roleWatcherConnection = nil
local lastGuiCheck = 0
local hbRunning = false
local function onRoleChange(old, new)
    log(string.format("Role: %s → %s", tostring(old), tostring(new)))
    survivorReset(); killerReset(); resetThreat()
    resetMapCaches()
    ActionState.current = nil; ActionState.phase = "idle"
    ActionState.targetPoint = nil; ActionState.cooldownUntil = 0
    ActionState.shiftActive = false
    -- [R27] Reset exit cache
    ExitCache.gates = {}
    ExitCache.everHadGates = false
    ExitCache.lastScan = 0
    ExitCache.openGateExitObj = nil
    ExitCache.allExpiredSince = nil
    resetGameEnd(); resetEvasion("role-change"); clearChaseAction()
    stopRepair("role-change")
    stopLeverSession("role-change")
    RepairSession.state = "idle"
    RepairSession.targetPoint = nil
    RepairSession.targetGen = nil
    RepairSession.nextStartAt = 0
    if new == "Survivor" then
        Survivor.forceRescan = true
        Survivor.lastGenScan = 0
        Survivor.lastSwitchT = 0
        Survivor.searchStateSince = 0
    end
    if new == "Spectator" then
        endHoldAction(); endShiftInteract(); releaseShift(); cancelGoal()
    end
    ensureGuiAlive()
end
local function startRoleWatcher()
    if roleWatcherConnection then return end
    roleWatcherConnection = RunService.Heartbeat:Connect(function()
        if hbRunning then return end
        hbRunning = true
        pcall(function()
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
                if role == "Survivor" then
                    local ev = Evasion.active and "/evade" or ""
                    local ca = ChaseAction.kind and ("/chase:"..ChaseAction.kind) or ""
                    local rs = (RepairSession.state ~= "idle") and ("/repair:"..RepairSession.state) or ""
                    local ls = (LeverSession.state ~= "idle") and ("/lever:"..LeverSession.state) or ""
                    local eg = GameEnd.endgameActive and ("/ENDGAME("..tostring(GameEnd.endgameReason)..")") or ""
                    extra = string.format(" [%s%s%s%s%s%s]",
                        Survivor.State,
                        ActionState.current and ("/"..ActionState.current) or "",
                        ev, ca, rs, ls..eg)
                elseif role == "Killer" then
                    extra = string.format(" [%s]", Killer.State)
                end
                readyLabel.Text = "AI ready ["..tostring(role).."]"..extra
            end
            local hum = getHumanoid()
            if not hum or hum.Health <= 0 then
                stopRepair("no-hum")
                stopLeverSession("no-hum")
                notifyRepairEnded(); releaseShift(); endHoldAction(); endShiftInteract(); cancelGoal()
                return
            end
            local char = getChar()

            local okR, errR = pcall(updateRepairSession, now, char)
            if not okR then log("updateRepairSession error:", errR) end

            local okA, errA = pcall(updateActionState, now, char)
            if not okA then log("updateActionState error:", errA) end

            if role == "Survivor" then
                local ok, err = pcall(SurvivorAI, now)
                if not ok then log("SurvivorAI error:", err) end
            elseif role == "Killer" then
                local ok, err = pcall(KillerAI, now)
                if not ok then log("KillerAI error:", err) end
            else
                endHoldAction(); endShiftInteract(); releaseShift(); cancelGoal()
                if RepairSession.state ~= "idle" then stopRepair("spectator") end
                if LeverSession.state ~= "idle" then stopLeverSession("spectator") end
            end

            local okV, errV = pcall(updatePathDebug)
            if not okV then log("PathDebug error:", errV) end
        end)
        hbRunning = false
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
    ActionState.current = nil; ActionState.phase = "idle"
    ActionState.targetPoint = nil; ActionState.cooldownUntil = 0
    ActionState.shiftActive = false
    resetGameEnd(); resetEvasion("character-added"); clearChaseAction()
    stopRepair("character-added")
    stopLeverSession("character-added")
    RepairSession.state = "idle"
    RepairSession.targetPoint = nil
    RepairSession.targetGen = nil
    notifyRepairEnded(); endHoldAction(); endShiftInteract()
    if CONFIG.DEBUG_PATH_VISUAL then pathDebugClear() end
    ensureGuiAlive()
end)
localPlayer.CharacterRemoving:Connect(function()
    stopRepair("character-removing")
    stopLeverSession("character-removing")
    notifyRepairEnded(); releaseShift(); endHoldAction(); endShiftInteract(); cancelGoal()
    resetEvasion("character-removing"); clearChaseAction()
    ActionState.current = nil; ActionState.phase = "idle"
    ActionState.targetPoint = nil; ActionState.cooldownUntil = 0
    ActionState.shiftActive = false
    if CONFIG.DEBUG_PATH_VISUAL then pathDebugClear() end
end)

-- ============================================================================
-- KILL SWITCH
-- ============================================================================
_G.KemiAI_Stop = function()
    if roleWatcherConnection then roleWatcherConnection:Disconnect(); roleWatcherConnection = nil end
    if guiWatchConn then pcall(function() guiWatchConn:Disconnect() end); guiWatchConn = nil end
    stopRepair("kill-switch")
    stopLeverSession("kill-switch")
    notifyRepairEnded(); releaseShift(); endHoldAction(); endShiftInteract(); cancelGoal()
    resetThreat(); resetPerception(); resetEvasion("kill-switch")
    clearChaseAction()
    ActionState.current = nil; ActionState.phase = "idle"
    ActionState.targetPoint = nil; ActionState.cooldownUntil = 0
    ActionState.shiftActive = false
    RepairSession.state = "idle"
    RepairSession.targetPoint = nil
    RepairSession.targetGen = nil
    pathDebugClear()
    if PathDebug.folder and PathDebug.folder.Parent then
        pcall(function() PathDebug.folder:Destroy() end)
    end
    PathDebug.folder = nil
    if readyGui then pcall(function() readyGui:Destroy() end); readyGui=nil; readyLabel=nil end
    log("Stopped")
end

log("AI ready — R27 (multi-gate exit + path-followed 70-stud evasion)")