-- ============================================================================
-- KEMI // PLAY AI — R23 (patched from R22)
--   R22 → R23 changes (targeted fixes):
--   [FIX-1] Repair cancel threshold aligned with evasion entry: EVADE_RADIUS
--           (25) instead of EVADE_EXIT_RADIUS (29) → eliminates repair
--           start/stop oscillation in the 25–29 hysteresis band.
--   [FIX-2] updateRepairSession active state: 1.5s grace on missing
--           isRepairing when gen progress is not rising, avoiding premature
--           "ended-naturally" + restart cycle during transient attr loss.
--   [FIX-3] handleFinishline + endgame fallback: active repositioning toward
--           exit area / map center instead of permanent Move(Vector3.zero)
--           when exit/finishline not yet detected.
--   [FIX-4] stopLeverSession when killer enters EVADE_RADIUS, consistent with
--           repair cancel; safe resume handled by handleExitPhase.
--   [FIX-5] Diagnostic logs on evade enter/exit, repair stop reason,
--           lever start/stop, gate open, and endgame search states.
--   Everything else (R22 P1–P8) preserved.
-- ============================================================================

local Players             = game:GetService("Players")
local RunService          = game:GetService("RunService")
local PathfindingService  = game:GetService("PathfindingService")
local VirtualInputManager = game:GetService("VirtualInputManager")
local GuiService          = game:GetService("GuiService")
local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local CollectionService   = game:GetService("CollectionService")

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
    SURV_GEN_NO_PROGRESS = 3.0,
    SURV_STUCK_WATCHDOG  = 10.0,
    SEARCH_STUCK_LOG     = 5.0,

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

    EVADE_RADIUS         = 25,
    EVADE_EXIT_RADIUS    = 29,
    EVADE_CANDIDATE_R    = 32,
    EVADE_RECALC_GAP     = 0.40,
    EVADE_COMMIT_UNTIL   = 1.2,
    EVADE_PROGRESS_TIMEOUT = 1.2,
    EVADE_PROGRESS_EPS   = 1.5,

    EVADE_GEN_MIN_DIST        = 30,
    EVADE_FARTHEST_GEN_MAX    = 300,
    EVADE_GEN_RECENT_TIMEOUT  = 8.0,
    EVADE_AWAY_FALLBACK_D     = 45,

    DODGE_EMERGENCY_D    = 7,
    DODGE_SIDE_STEP      = 10,
    PALLET_DROP_D        = 12,
    VAULT_USE_D          = 14,

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

    WAYPOINT_REACH_DIST  = 3.0,
    WAYPOINT_SKIP_DIST   = 3.5,
    WAYPOINT_Y_TOL       = 2.5,
    GOAL_REPATH_THRESH   = 8.0,
    CHASE_REPATH_THRESH  = 4.0,
    PATH_FAIL_COOLDOWN   = 10,
    PATH_CACHE_TTL       = 2.0,

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
    REPAIR_ATTR_GRACE       = 1.5,   -- [FIX-2] grace before ended-naturally

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
    repair       = { attr = "isRepairing",       hold = false, timeout = 1.5, cooldown = 0.5, remote = "repair" },
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
local function beginShiftInteract() return false end
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
local function distXZ(a,b)
    if not a or not b then return math.huge end
    local d = a.Position - b.Position
    return Vector3.new(d.X, 0, d.Z).Magnitude
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
-- ACTION BUTTON
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
-- REPAIR SESSION — CENTRALIZED, IDEMPOTENT
-- ============================================================================
local RepairSession = {
    id = 0,
    state = "idle",        -- idle | starting | active | stopping
    targetPoint = nil,
    targetGen = nil,
    startedAt = 0,
    retryCount = 0,
    stopReason = nil,
    lastProgress = nil,       -- [FIX-2]
    missedAttrSince = nil,    -- [FIX-2]
}

local function isRepairActive()
    return RepairSession.state == "starting" or RepairSession.state == "active"
end
local function isRepairSessionAlive()
    return RepairSession.state ~= "idle"
end

local function syncRepairSessionToActionState(now)
    if RepairSession.state == "starting" or RepairSession.state == "active" then
        ActionState.current = "repair"
        ActionState.phase = (RepairSession.state == "starting") and "starting" or "active"
        ActionState.target = RepairSession.targetGen
        ActionState.targetPoint = RepairSession.targetPoint
        ActionState.attributeName = "isRepairing"
        ActionState.isHold = false
        ActionState.startedAt = RepairSession.startedAt
        ActionState.interactMethod = "remote"
    end
end

local function startRepairSession(gen, pt)
    if RepairSession.state ~= "idle" then
        if RepairSession.targetPoint == pt then return true end
        stopRepairSession("switch-target")
    end
    if not pt or not pt.Parent or not gen or not gen.Parent then return false end
    local rem = getRepairRemote()
    if not rem then return false end

    RepairSession.id = RepairSession.id + 1
    RepairSession.state = "starting"
    RepairSession.targetPoint = pt
    RepairSession.targetGen = gen
    RepairSession.startedAt = tick()
    RepairSession.retryCount = 0
    RepairSession.stopReason = nil
    RepairSession.lastProgress = nil       -- [FIX-2]
    RepairSession.missedAttrSince = nil    -- [FIX-2]

    local ok = pcall(function() rem:FireServer(pt, true) end)
    if not ok then
        if CONFIG.DEBUG then log(string.format("[REPAIR] start #%d FAILED (pcall)", RepairSession.id)) end
        RepairSession.state = "idle"
        RepairSession.targetPoint = nil
        RepairSession.targetGen = nil
        return false
    end
    if CONFIG.DEBUG then
        log(string.format("[REPAIR] start #%d target=%s", RepairSession.id, pt:GetFullName()))
    end
    syncRepairSessionToActionState(tick())
    notifyRepairStarted()
    return true
end

function stopRepairSession(reason)
    if RepairSession.state == "idle" then return end
    if RepairSession.state == "stopping" then return end

    local pt  = RepairSession.targetPoint
    local gen = RepairSession.targetGen

    RepairSession.state = "stopping"
    RepairSession.stopReason = reason

    local rem = getRepairRemote()
    if rem and pt and pt.Parent then
        local ok = pcall(function() rem:FireServer(pt, false) end)
        if CONFIG.DEBUG then
            log(string.format("[REPAIR] stop #%d reason=%s remote=%s",
                RepairSession.id, tostring(reason), ok and "ok" or "fail"))
        end
    else
        if CONFIG.DEBUG then
            log(string.format("[REPAIR] stop #%d reason=%s (target gone / no remote)",
                RepairSession.id, tostring(reason)))
        end
    end
    if gen and gen.Parent and pt and pt.Parent then
        fireCancelRepair(gen, pt)
    end

    RepairSession.state = "idle"
    RepairSession.targetPoint = nil
    RepairSession.targetGen = nil
    RepairSession.stopReason = nil
    RepairSession.retryCount = 0
    RepairSession.lastProgress = nil       -- [FIX-2]
    RepairSession.missedAttrSince = nil    -- [FIX-2]

    if ActionState.current == "repair" then
        ActionState.current = nil
        ActionState.phase = "idle"
        ActionState.target = nil
        ActionState.targetPoint = nil
        ActionState.cooldownUntil = tick() + 0.5
    end
    notifyRepairEnded()
end

-- [FIX-2] Grace on missing isRepairing during active session:
--   * progress rise OR attr-return within REPAIR_ATTR_GRACE aborts the stop
--   * otherwise ends naturally after grace expires
local function updateRepairSession(now, char)
    if RepairSession.state == "idle" then
        if ActionState.current == "repair" then
            ActionState.current = nil
            ActionState.phase = "idle"
        end
        return
    end
    if not char then
        stopRepairSession("character-lost")
        return
    end

    local attrVal = (char:GetAttribute("isRepairing") == true)

    if RepairSession.state == "starting" then
        if attrVal then
            RepairSession.state = "active"
            if ActionState.current == "repair" then ActionState.phase = "active" end
            RepairSession.missedAttrSince = nil
        elseif now - RepairSession.startedAt > CONFIG.REPAIR_GIVEUP_TIME then
            if RepairSession.retryCount < 1 then
                RepairSession.retryCount = RepairSession.retryCount + 1
                local rem = getRepairRemote()
                if rem and RepairSession.targetPoint and RepairSession.targetPoint.Parent then
                    pcall(function() rem:FireServer(RepairSession.targetPoint, true) end)
                    RepairSession.startedAt = now
                    if CONFIG.DEBUG then
                        log(string.format("[REPAIR] retry #%d (attempt %d)",
                            RepairSession.id, RepairSession.retryCount))
                    end
                else
                    stopRepairSession("retry-target-gone")
                end
            else
                if CONFIG.DEBUG then log(string.format("[REPAIR] start timeout #%d", RepairSession.id)) end
                stopRepairSession("start-timeout")
            end
        end
    elseif RepairSession.state == "active" then
        -- Track current progress for verification
        local prog = RepairSession.targetGen and getGenProgress(RepairSession.targetGen)
        if prog and RepairSession.lastProgress and prog > RepairSession.lastProgress then
            RepairSession.missedAttrSince = nil
        end
        if prog then RepairSession.lastProgress = prog end

        if not attrVal then
            -- [FIX-2] Do NOT immediately kill; wait grace window & verify progress
            if not RepairSession.missedAttrSince then
                RepairSession.missedAttrSince = now
                if CONFIG.DEBUG then
                    log(string.format("[REPAIR] #%d isRepairing missing → grace", RepairSession.id))
                end
            elseif now - RepairSession.missedAttrSince > CONFIG.REPAIR_ATTR_GRACE then
                if CONFIG.DEBUG then log(string.format("[REPAIR] ended naturally #%d", RepairSession.id)) end
                stopRepairSession("ended-naturally")
            end
        else
            RepairSession.missedAttrSince = nil
        end
    end
end

-- ============================================================================
-- LEVER SESSION — EXIT GATE
-- ============================================================================
local LeverSession = {
    state = "idle",           -- idle | approaching | interacting | gateOpen | finished
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
        if ActionState.current == "repair"
            and (ActionState.phase == "starting" or ActionState.phase == "active") then
            return true
        end
        if now < ActionState.cooldownUntil then return false end
        if not targetPoint or not targetPoint.Parent then return false end
        local ok = startRepairSession(target, targetPoint)
        return ok
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
    if RepairSession.state ~= "idle" or ActionState.current == "repair" then
        stopRepairSession("requestStopAction")
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
local PathFollower = {
    path = nil, goalPos = nil, goalTag = nil,
    waypoints = {}, index = 1, computing = false,
    pendingPos = nil, pendingTag = nil, lastMoveTo = nil,
    lastPos = nil, stuckSince = 0, lastStuckLog = 0,
    blockedConn = nil, failCount = 0, lastFailPos = nil, failCooldownUntil = 0,
    slopeStuckSince = 0, lastWP = nil, lastWPSince = 0,
    strafeDir = 1, strafeAttempts = 0,
    computeGeneration = 0,
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
            PathFollower.goalPos = nil
            PathFollower.stuckSince = 0
            PathFollower.index = 1
            PathFollower.strafeAttempts = 0
            PathFollower.pendingPos = nil
            PathFollower.pendingTag = nil
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
    handleStuck(root, hum, now)
    if #PathFollower.waypoints == 0 or PathFollower.index > #PathFollower.waypoints then
        if PathFollower.goalPos then hum:MoveTo(PathFollower.goalPos) end
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
        if PathFollower.goalPos then hum:MoveTo(PathFollower.goalPos) end
        return true
    end
    if wp.Action == Enum.PathWaypointAction.Jump then hum.Jump = true end
    hum:MoveTo(wp.Position)
    PathFollower.lastMoveTo = wp.Position
    return true
end

local PathMemo = {}
local function tryPath(fromPos, endPos)
    local k = tostring(fromPos).."→"..tostring(endPos)
    local cached = PathMemo[k]
    if cached and (tick() - cached.t) < CONFIG.PATH_CACHE_TTL then return cached.ok end
    local p = PathfindingService:CreatePath({
        AgentRadius = CONFIG.AGENT_RADIUS, AgentHeight = CONFIG.AGENT_HEIGHT,
        AgentCanJump = true, AgentMaxSlope = CONFIG.AGENT_MAX_SLOPE,
        WaypointSpacing = CONFIG.AGENT_WAYPOINT_SPACING,
    })
    local ok = pcall(function() p:ComputeAsync(fromPos, endPos) end)
    local success = ok and p.Status == Enum.PathStatus.Success
    PathMemo[k] = { t=tick(), ok=success }
    return success
end

-- ============================================================================
-- EVASION
-- ============================================================================
local Evasion = {
    active = false,
    targetPos = nil,
    targetKind = nil,
    targetGen = nil,
    targetSince = 0,
    lastProgressPos = nil,
    lastProgressT = 0,
    lastEscapeRecalc = 0,
    dodgeSide = 1,
    reachedGens = {},
}

local function resetEvasion(reason)
    if Evasion.active and reason and CONFIG.DEBUG then
        log("[EVADE] reset: %s", reason)
    end
    Evasion.active = false
    Evasion.targetPos = nil
    Evasion.targetKind = nil
    Evasion.targetGen = nil
    Evasion.targetSince = 0
    Evasion.lastProgressPos = nil
    Evasion.lastProgressT = 0
    Evasion.lastEscapeRecalc = 0
    Evasion.reachedGens = {}
end

local function getAwayVector(myPos, killerPos)
    local d = Vector3.new(myPos.X - killerPos.X, 0, myPos.Z - killerPos.Z)
    if d.Magnitude < 0.5 then return Vector3.new(1, 0, 0) end
    return d.Unit
end

local EVADE_ANGLES = {0, 30, -30, 60, -60, 90, -90}

local function pickEscapeTarget(myPos, killerPos, radius)
    radius = radius or CONFIG.EVADE_CANDIDATE_R
    local away = getAwayVector(myPos, killerPos)
    local best, bestScore = nil, -math.huge

    for _, deg in ipairs(EVADE_ANGLES) do
        local dir = rotateAroundY(away, math.rad(deg))
        local endPos = myPos + dir * radius
        if hasClearLine(myPos, endPos, nil, radius + 3) and not isNearFence(endPos, CONFIG.FENCE_MARGIN) then
            if tryPath(myPos, endPos) then
                local endKD = (endPos - killerPos).Magnitude
                local score = clamp(endKD / CONFIG.FLEE_MIN_DIST_KILLER, 0, 2) * 4
                local open = hasClearLine(endPos, endPos + dir * 15, nil, 16)
                if open then score = score + 1.5 end
                if deg == 0 then score = score + 0.8 end
                if math.abs(deg) >= 90 then score = score - 1.0 end
                if score > bestScore then
                    bestScore = score
                    best = { pos=endPos, dir=dir, deg=deg, endKD=endKD, score=score, kind="short" }
                end
            end
        end
    end
    return best
end

local function isGenReachable(gen, myPos)
    if not gen or not gen.Parent then return nil end
    if updateGeneratorProgress(gen) then return nil end
    local occ = getGenOccupancyMap(gen)
    local pts = genPoints(gen)
    local bestPt, bestPtD = nil, math.huge
    local anyPoint = nil
    for _, pt in ipairs(pts) do
        if not anyPoint then anyPoint = pt end
        if not occ[pt] then
            local d = (pt.Position - myPos).Magnitude
            if d < bestPtD then bestPtD, bestPt = d, pt end
        end
    end
    local waypoint
    if bestPt then
        waypoint = bestPt.Position
    elseif gen:IsA("Model") and gen.PrimaryPart then
        waypoint = gen.PrimaryPart.Position
    elseif gen:IsA("BasePart") then
        waypoint = gen.Position
    elseif anyPoint then
        waypoint = anyPoint.Position
    else
        for _, ch in ipairs(gen:GetChildren()) do
            if ch:IsA("BasePart") then waypoint = ch.Position; break end
        end
    end
    if not waypoint then return nil end
    return waypoint, (waypoint - myPos).Magnitude
end

local function cleanupReachedGens(now)
    for gen, t in pairs(Evasion.reachedGens) do
        if (now - t) > CONFIG.EVADE_GEN_RECENT_TIMEOUT or not gen or not gen.Parent then
            Evasion.reachedGens[gen] = nil
        end
    end
end

local function pickFarthestGenEscape(myPos, killerPos, now)
    local list = getGeneratorList()
    if #list == 0 then return nil end
    cleanupReachedGens(now)
    local away = getAwayVector(myPos, killerPos)
    local best, bestScore = nil, -math.huge
    for _, gen in ipairs(list) do
        if gen and gen.Parent and not Evasion.reachedGens[gen] then
            local wp, dAI = isGenReachable(gen, myPos)
            if wp and dAI
                and dAI >= CONFIG.EVADE_GEN_MIN_DIST
                and dAI <= CONFIG.EVADE_FARTHEST_GEN_MAX then
                local dK = (wp - killerPos).Magnitude
                if dK > CONFIG.FLEE_MIN_DIST_KILLER then
                    local toGenFlat = Vector3.new(wp.X - myPos.X, 0, wp.Z - myPos.Z)
                    if toGenFlat.Magnitude > 0.1 then
                        local awayDot = toGenFlat.Unit:Dot(away)
                        if awayDot > -0.2 then
                            local score = (dAI / 100) * 2.0
                                        + (math.min(dK, 250) / 100) * 3.0
                                        + awayDot * 3.0
                            if score > bestScore then
                                bestScore = score
                                best = {
                                    pos = wp, gen = gen, dAI = dAI, dK = dK,
                                    score = score, kind = "gen",
                                }
                            end
                        end
                    end
                end
            end
        end
    end
    if best then
        if not tryPath(myPos, best.pos) then
            if CONFIG.DEBUG then log("[EVADE] gen top candidate path failed → fallback") end
            return nil
        end
        if CONFIG.DEBUG then
            log(string.format("[EVADE] picked GEN %s dAI=%.1f dK=%.1f score=%.1f",
                best.gen:GetFullName(), best.dAI, best.dK, best.score))
        end
    end
    return best
end

local function evadeTargetStillValid(targetPos, myPos, killerPos)
    if not targetPos then return false end
    local dAI = (myPos - targetPos).Magnitude
    if dAI < CONFIG.FLEE_REACHED_RADIUS - 1 then return false end
    local dK = (targetPos - killerPos).Magnitude
    if dK < CONFIG.DODGE_EMERGENCY_D then return false end
    return true
end

local function updateEvasionGating(root, killerRoot, kD, now)
    if not Evasion.active then
        if killerRoot and kD <= CONFIG.EVADE_RADIUS then
            Evasion.active = true
            Evasion.targetPos = nil
            Evasion.lastProgressPos = root.Position
            Evasion.lastProgressT = now
            if CONFIG.DEBUG then log("[EVADE] enter kD=%.1f (radius=%d)", kD, CONFIG.EVADE_RADIUS) end
        end
    else
        if not killerRoot or kD > CONFIG.EVADE_EXIT_RADIUS then
            if CONFIG.DEBUG then log("[EVADE] exit kD=%.1f", kD or -1) end
            resetEvasion("killer-far-or-gone")
        end
    end
    return Evasion.active
end

local function evasionMove(root, killerRoot, hum, now)
    local kD = (root.Position - killerRoot.Position).Magnitude

    if kD < CONFIG.DODGE_EMERGENCY_D then
        local away = Vector3.new(root.Position.X - killerRoot.Position.X, 0,
                                  root.Position.Z - killerRoot.Position.Z)
        if away.Magnitude > 0.5 then
            away = away.Unit
            local perp = Vector3.new(-away.Z, 0, away.X)
            local side = Evasion.dodgeSide or 1
            local candidates = {
                root.Position + perp * side * CONFIG.DODGE_SIDE_STEP,
                root.Position - perp * side * CONFIG.DODGE_SIDE_STEP,
                root.Position + away * CONFIG.DODGE_SIDE_STEP,
            }
            for _, tgt in ipairs(candidates) do
                if hasClearLine(root.Position, tgt) and not isNearFence(tgt, CONFIG.FENCE_MARGIN) then
                    holdShift()
                    hum:MoveTo(tgt)
                    Evasion.lastProgressPos = root.Position
                    Evasion.lastProgressT = now
                    if CONFIG.DEBUG then log("[EVADE] emergency dodge kD=%.1f", kD) end
                    return
                end
            end
            Evasion.dodgeSide = -side
        end
    end

    local needRecalc = false
    if not Evasion.targetPos then
        needRecalc = true
    else
        local dTarget = (root.Position - Evasion.targetPos).Magnitude
        if dTarget < CONFIG.FLEE_REACHED_RADIUS then
            if Evasion.targetKind == "gen" and Evasion.targetGen then
                Evasion.reachedGens[Evasion.targetGen] = now
            end
            needRecalc = true
            if CONFIG.DEBUG then log("[EVADE] target reached (kind=%s d=%.1f)", tostring(Evasion.targetKind), dTarget) end
        elseif not evadeTargetStillValid(Evasion.targetPos, root.Position, killerRoot.Position) then
            needRecalc = true
            if CONFIG.DEBUG then log("[EVADE] target invalidated") end
        end

        if Evasion.lastProgressT > 0 and (now - Evasion.lastProgressT) > CONFIG.EVADE_PROGRESS_TIMEOUT then
            local progress = (root.Position - Evasion.lastProgressPos).Magnitude
            if progress < CONFIG.EVADE_PROGRESS_EPS then
                needRecalc = true
                if CONFIG.DEBUG then log("[EVADE] no progress (%.1f) → repick", progress) end
            end
            Evasion.lastProgressPos = root.Position
            Evasion.lastProgressT = now
        end

        if needRecalc and Evasion.targetSince > 0
            and (now - Evasion.targetSince) < CONFIG.EVADE_COMMIT_UNTIL then
            if Evasion.targetPos and evadeTargetStillValid(Evasion.targetPos, root.Position, killerRoot.Position) then
                needRecalc = false
            end
        end
    end

    local repicked = false
    if needRecalc then
        local emergency = kD < CONFIG.DODGE_EMERGENCY_D * 2
        local picked = nil

        if emergency then
            picked = pickEscapeTarget(root.Position, killerRoot.Position, CONFIG.EVADE_CANDIDATE_R)
        end

        if not picked then
            picked = pickFarthestGenEscape(root.Position, killerRoot.Position, now)
        end

        if not picked then
            picked = pickEscapeTarget(root.Position, killerRoot.Position, CONFIG.EVADE_CANDIDATE_R)
        end

        if not picked then
            local away = getAwayVector(root.Position, killerRoot.Position)
            local awayTgt = root.Position + away * CONFIG.EVADE_AWAY_FALLBACK_D
            for _, deg in ipairs({-30, 30, -60, 60, -90, 90}) do
                local dir = rotateAroundY(away, math.rad(deg))
                local tgt = root.Position + dir * CONFIG.EVADE_AWAY_FALLBACK_D
                if hasClearLine(root.Position, tgt, nil, CONFIG.EVADE_AWAY_FALLBACK_D + 3)
                    and not isNearFence(tgt, CONFIG.FENCE_MARGIN) then
                    awayTgt = tgt; break
                end
            end
            picked = { pos = awayTgt, kind = "away" }
            if CONFIG.DEBUG then log("[EVADE] fallback AWAY") end
        end

        Evasion.targetPos = picked.pos
        Evasion.targetKind = picked.kind
        Evasion.targetGen = picked.gen
        Evasion.targetSince = now
        Evasion.lastEscapeRecalc = now
        Evasion.lastProgressPos = root.Position
        Evasion.lastProgressT = now
        repicked = true
    end

    if Evasion.targetPos then
        holdShift()
        setGoal(Evasion.targetPos, "evade", repicked)
        followStep()
    else
        local away = getAwayVector(root.Position, killerRoot.Position)
        local fb = root.Position + away * CONFIG.EVADE_AWAY_FALLBACK_D
        holdShift()
        setGoal(fb, "evade", true)
        followStep()
    end
end

-- ============================================================================
-- CHASE ACTION
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
        end
        if ActionState.phase == "starting" and d > CONFIG.CHASE_TRIGGER_RADIUS then
            hum:MoveTo(t.Position)
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
        return true
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
    local candidates = 0
    for _,w in ipairs(ObstacleCache.windows) do
        if w.Parent then
            candidates = candidates + 1
            local d = (myPos - w.Position).Magnitude
            if d < bestD then
                local dKW = (killerPos - w.Position).Magnitude
                local dKM = (killerPos - myPos).Magnitude
                if dKW > dKM - 3 then
                    if hasClearLine(myPos, w.Position) then bestD = d; best = w end
                end
            end
        end
    end
    if CONFIG.DEBUG and best then
        log("[CHASE] vault candidate %s d=%.1f (scanned=%d)", best:GetFullName(), bestD, candidates)
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
    local candidates = 0
    for _,p in ipairs(ObstacleCache.pallets) do
        if p.Parent then
            candidates = candidates + 1
            local d = (myPos - p.Position).Magnitude
            if d < bestD then
                local toKiller = killerPos - myPos
                local toPallet = p.Position - myPos
                if toKiller.Magnitude > 0.1 and toPallet.Magnitude > 0.1 then
                    local dot = toKiller.Unit:Dot(toPallet.Unit)
                    if dot > 0.5 and hasClearLine(myPos, p.Position) then
                        bestD = d; best = p
                    end
                end
            end
        end
    end
    if CONFIG.DEBUG and best then
        log("[CHASE] pallet candidate %s d=%.1f (scanned=%d)", best:GetFullName(), bestD, candidates)
    end
    return best
end

-- ============================================================================
-- EXIT GATE SCAN
-- ============================================================================
local ExitCache = { detected=false, exitObj=nil, leverGoal=nil, lastScan=0 }

local function scanExitGate()
    local map = workspace:FindFirstChild("Map")
    if not map then
        for _, folder in ipairs(workspace:GetChildren()) do
            local nm = folder.Name
            if folder:IsA("Folder") or folder:IsA("Model") then
                if nm:match("^Exit") or nm:lower():find("exit") or nm:lower():find("gate") then
                    local lg = folder:FindFirstChild("LeverGoal", true)
                    if lg and lg:IsA("BasePart") then
                        return true, folder, lg
                    end
                end
            end
        end
        return false, nil, nil
    end
    for _, folder in ipairs(map:GetChildren()) do
        local nm = folder.Name
        if nm:match("^Exit") or nm:lower():find("exit") or nm:lower():find("gate") then
            local exitLever = folder:FindFirstChild("ExitLever")
            if exitLever then
                local lg = exitLever:FindFirstChild("LeverGoal", true)
                if lg and lg:IsA("BasePart") then
                    return true, exitLever, lg
                end
            end
            local lg = folder:FindFirstChild("LeverGoal", true)
            if lg and lg:IsA("BasePart") then
                return true, folder, lg
            end
        end
    end
    return false, nil, nil
end

local function checkExitAvailable(now)
    local cacheAlive = ExitCache.leverGoal and ExitCache.leverGoal.Parent
    if now - ExitCache.lastScan < CONFIG.LEVER_RESCAN_INTERVAL and cacheAlive then
        return ExitCache.detected, ExitCache.exitObj, ExitCache.leverGoal
    end
    ExitCache.lastScan = now
    local detected, exitObj, lg = scanExitGate()
    if detected ~= ExitCache.detected then
        if detected then log("[EXIT] Exit lever detected")
        else log("[EXIT] Exit lever gone") end
    end
    ExitCache.detected = detected
    ExitCache.exitObj = exitObj
    ExitCache.leverGoal = lg
    return detected, exitObj, lg
end

local function isGateOpen(exitObj, leverGoal)
    if not exitObj then return false end
    if leverGoal and leverGoal.Parent then
        for _, key in ipairs({"Used","Activated","Opened","Done","Inactive","IsOpen","Consumed"}) do
            local ok, v = pcall(function() return leverGoal:GetAttribute(key) end)
            if ok and (v == true) then return true end
            if hasTagOrAttr(leverGoal, key) then return true end
        end
        local main = exitObj:FindFirstChild("Main")
        if main and main:IsA("BasePart") and main.CanCollide == false then return true end
    else
        return true
    end
    return false
end

local function findNearestFinishline(fromPos)
    local candidates = {}
    local function scan(node, depth)
        if depth > 6 or not node then return end
        for _,ch in ipairs(node:GetChildren()) do
            if ch:IsA("BasePart") then
                local nm = ch.Name
                if nm == "Finishline" or nm == "Fininshline" or nm == "FinishLine"
                    or nm == "Fininshline1" or nm:lower() == "finishline" or nm:lower() == "fininshline" then
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
    stopRepairSession("survivorReset")
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
                stopRepairSession("state-leave-repair")
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
                stopRepairSession("hang-watchdog-killer-close")
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

-- [FIX-3] Active repositioning instead of standing still while searching
local function mapCenterPos()
    local map = workspace:FindFirstChild("Map")
    if not map then return nil end
    if map:IsA("Model") then
        local ok, bb = pcall(function() return map:GetBoundingBox() end)
        if ok and bb then return bb.Position end
    end
    local sum, count = Vector3.zero, 0
    local function scan(node, depth)
        if depth > 2 or not node then return end
        for _, ch in ipairs(node:GetChildren()) do
            if ch:IsA("BasePart") then sum = sum + ch.Position; count = count + 1
            elseif ch:IsA("Folder") or ch:IsA("Model") then scan(ch, depth+1) end
        end
    end
    pcall(scan, map, 0)
    if count > 0 then return sum / count end
    return nil
end

local function handleFinishline(now, root, hum, exitObj, leverGoal)
    if not Survivor.exitFinishline or not Survivor.exitFinishline.Parent then
        if now - (Survivor.lastFinishlineSearch or 0) > CONFIG.FINISHLINE_RESCAN_GAP then
            Survivor.lastFinishlineSearch = now
            local refPos = (leverGoal and leverGoal.Position)
                        or (exitObj and exitObj:IsA("BasePart") and exitObj.Position)
                        or root.Position
            Survivor.exitFinishline = findNearestFinishline(refPos)
            if Survivor.exitFinishline then
                log("[EXIT] gate open → heading to "..Survivor.exitFinishline:GetFullName())
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
        -- [FIX-3] Actively reposition toward exit/lever area instead of freezing
        local anchor = (leverGoal and leverGoal.Parent and leverGoal.Position)
                    or (exitObj and exitObj:IsA("BasePart") and exitObj.Position)
                    or nil
        if anchor then
            local dA = (root.Position - anchor).Magnitude
            if dA > 6 then
                holdShift()
                setGoal(anchor, "exit")
                followStep()
            else
                -- small strafe around anchor to trigger finishline scan from multiple views
                local angle = (now * 0.6) % (math.pi * 2)
                local dir = Vector3.new(math.cos(angle), 0, math.sin(angle))
                local tgt = anchor + dir * 8
                if hasClearLine(root.Position, tgt) then
                    holdShift()
                    setGoal(tgt, "exit")
                    followStep()
                else
                    hum:Move(Vector3.zero, false)
                end
            end
        else
            hum:Move(Vector3.zero, false)
        end
    end
    return true
end

local function handleExitPhase(now, root, hum)
    local detected, exitObj, leverGoal = checkExitAvailable(now)
    if not detected then
        if LeverSession.state ~= "idle" and LeverSession.state ~= "finished" then
            stopLeverSession("no-exit-detected")
        end
        return false
    end

    if isGateOpen(exitObj, leverGoal) then
        if LeverSession.state == "interacting" or LeverSession.state == "approaching" then
            stopLeverSession("gate-open")
        end
        LeverSession.state = "gateOpen"
        return handleFinishline(now, root, hum, exitObj, leverGoal)
    end

    if not leverGoal or not leverGoal.Parent then
        return handleFinishline(now, root, hum, exitObj, leverGoal)
    end

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

        if RepairSession.state ~= "idle" then
            stopRepairSession("exit-lever")
        end
        if ActionState.current and ActionState.current ~= "exit" then
            requestStopAction()
        end

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
            if CONFIG.DEBUG then log("[LEVER] in range → interact") end
        end
        setSurvivorState("EscapingMap", now, "(interacting lever)")
    else
        if LeverSession.state == "idle" then
            LeverSession.state = "approaching"
            LeverSession.target = leverGoal
            LeverSession.startedAt = now
            if CONFIG.DEBUG then log("[LEVER] approaching d="..string.format("%.1f", d)) end
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
    stopRepairSession("knocked")
    stopLeverSession("knocked")
    endHoldAction(); releaseShift(); endShiftInteract(); cancelGoal()
    resetEvasion("knocked"); clearChaseAction()
    if hum then hum:Move(Vector3.zero, false) end
end

local function enterBeingHealed(now, hum)
    setSurvivorState("BeingHealed", now)
    stopRepairSession("being-healed")
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
        stopRepairSession("dead-or-nohum")
        stopLeverSession("dead-or-nohum")
        notifyRepairEnded(); releaseShift(); endHoldAction(); endShiftInteract(); cancelGoal()
        resetEvasion("dead-or-nohum"); clearChaseAction()
        return
    end

    local char = getChar()
    local selfState = getSelfState()

    if selfState == "dead" then
        setSurvivorState("Dead", now)
        stopRepairSession("dead"); stopLeverSession("dead")
        endHoldAction(); releaseShift(); endShiftInteract(); cancelGoal()
        resetEvasion("dead"); clearChaseAction()
        return
    end
    if selfState == "hooked" then
        setSurvivorState("Hooked", now)
        stopRepairSession("hooked"); stopLeverSession("hooked")
        endHoldAction(); releaseShift(); endShiftInteract(); cancelGoal()
        resetEvasion("hooked"); clearChaseAction()
        return
    end
    if selfState == "carried" then
        setSurvivorState("Carried", now)
        stopRepairSession("carried"); stopLeverSession("carried")
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

    -- [FIX-1][FIX-4] Align cancel threshold with evasion entry (25) and
    -- also stop lever interaction on killer proximity
    if killerRoot and kD <= CONFIG.EVADE_RADIUS then
        if RepairSession.state ~= "idle" then
            stopRepairSession(string.format("killer-near kD=%.1f", kD))
        end
        if LeverSession.state == "interacting" or LeverSession.state == "approaching" then
            stopLeverSession(string.format("killer-near kD=%.1f", kD))
        end
        if ActionState.current and ActionState.current ~= "vault"
            and ActionState.current ~= "palletDrop" and ActionState.current ~= "palletSlide" then
            if ActionState.phase ~= "stopping" then requestStopAction() end
        end
    end

    -- [P5] Evasion has sole MoveTo authority while active
    local evActive = updateEvasionGating(root, killerRoot, kD, now)
    if evActive and killerRoot then
        setSurvivorState("EvadingKiller", now, string.format("(d=%.1f P=%.2f)", kD, P or 0))

        if ChaseAction.kind then
            if updateChaseAction(root, hum, now) then return end
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

        evasionMove(root, killerRoot, hum, now)
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

    -- Endgame
    local endgameActive, endgameReason = checkEndgame(now)
    if endgameActive then
        if handleExitPhase(now, root, hum) then return end
        setSurvivorState("EscapingMap", now, "("..tostring(endgameReason).." - awaiting exit)")
        -- [FIX-3] Actively wander toward map center while exit not yet detected
        local centerPos = mapCenterPos()
        if centerPos and (root.Position - centerPos).Magnitude > 15 then
            holdShift()
            setGoal(centerPos, "exit-search")
            followStep()
        else
            -- At center; rescan while idling (checkExitAvailable polled each tick)
            if now - (Survivor.lastFinishlineSearch or 0) > CONFIG.FINISHLINE_RESCAN_GAP then
                Survivor.lastFinishlineSearch = now
                if not Survivor.exitFinishline or not Survivor.exitFinishline.Parent then
                    Survivor.exitFinishline = findNearestFinishline(root.Position)
                end
            end
            if Survivor.exitFinishline and Survivor.exitFinishline.Parent then
                holdShift()
                setGoal(Survivor.exitFinishline.Position, "finish")
                followStep()
            else
                hum:Move(Vector3.zero, false)
            end
        end
        return
    end

    -- Rescue
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

    -- Heal
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

    -- Normal objective
    if Survivor.State == "AllDone" then
        if now - Survivor.lastGenScan > 3 then
            Survivor.lastGenScan = now
            if findBestGenerator(root, nil) then
                Survivor.State = "SearchingGenerator"
                Survivor.lastLoggedGen = nil
            end
        end
        if RepairSession.state ~= "idle" then stopRepairSession("allDone") end
        notifyRepairEnded(); releaseShift(); endHoldAction(); endShiftInteract(); cancelGoal()
        return
    end

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
        stopRepairSession("no-slot")
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
    if d <= CONFIG.SURV_GEN_ACTION_R then
        if not isApproachPointAvailable(gen, ap) then
            Survivor.targetGen = nil; Survivor.approachPos = nil
            setSurvivorState("SearchingGenerator", now)
            stopRepairSession("slot-taken")
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

        hum:Move(Vector3.zero, false)

        if RepairSession.state == "idle" and now >= ActionState.cooldownUntil then
            local pt = findNearestGeneratorPoint(gen, ap)
            if pt then
                startAction("repair", gen, pt)
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
            stopRepairSession("no-progress")
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
        if RepairSession.state ~= "idle" then stopRepairSession("moving-to-gen") end
        if ActionState.current == "repair" then requestStopAction() end
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
-- GUI
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
    readyLabel.Size = UDim2.new(0,600,0,18)
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
-- ROLE WATCHER + MAIN LOOP
-- ============================================================================
local currentRole = nil
local roleWatcherConnection = nil
local lastGuiCheck = 0
local function onRoleChange(old, new)
    log(string.format("Role: %s → %s", tostring(old), tostring(new)))
    survivorReset(); killerReset(); resetThreat()
    ActionState.current = nil; ActionState.phase = "idle"
    ActionState.targetPoint = nil; ActionState.cooldownUntil = 0
    ActionState.shiftActive = false
    ExitCache.detected = false; ExitCache.leverGoal = nil; ExitCache.exitObj = nil; ExitCache.lastScan = 0
    resetGameEnd(); resetEvasion("role-change"); clearChaseAction()
    stopRepairSession("role-change")
    stopLeverSession("role-change")
    RepairSession.id = 0
    if new == "Spectator" then
        endHoldAction(); endShiftInteract(); releaseShift(); cancelGoal()
    end
    ensureGuiAlive()
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
            stopRepairSession("no-hum")
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
            if RepairSession.state ~= "idle" then stopRepairSession("spectator") end
            if LeverSession.state ~= "idle" then stopLeverSession("spectator") end
        end

        local okV, errV = pcall(updatePathDebug)
        if not okV then log("PathDebug error:", errV) end
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
    stopRepairSession("character-added")
    stopLeverSession("character-added")
    RepairSession.id = 0
    notifyRepairEnded(); endHoldAction(); endShiftInteract()
    if CONFIG.DEBUG_PATH_VISUAL then pathDebugClear() end
    ensureGuiAlive()
end)
localPlayer.CharacterRemoving:Connect(function()
    stopRepairSession("character-removing")
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
    stopRepairSession("kill-switch")
    stopLeverSession("kill-switch")
    notifyRepairEnded(); releaseShift(); endHoldAction(); endShiftInteract(); cancelGoal()
    resetThreat(); resetPerception(); resetEvasion("kill-switch")
    clearChaseAction()
    ActionState.current = nil; ActionState.phase = "idle"
    ActionState.targetPoint = nil; ActionState.cooldownUntil = 0
    ActionState.shiftActive = false
    pathDebugClear()
    if PathDebug.folder and PathDebug.folder.Parent then
        pcall(function() PathDebug.folder:Destroy() end)
    end
    PathDebug.folder = nil
    if readyGui then pcall(function() readyGui:Destroy() end); readyGui=nil; readyLabel=nil end
    log("Stopped")
end

log("AI ready — R23 (evasion-cancel aligned 25, repair grace, active endgame search, lever stop on killer proximity)")
