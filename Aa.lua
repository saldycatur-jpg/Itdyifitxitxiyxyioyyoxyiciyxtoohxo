-- ============================================================================
-- KEMI // PLAY AI — R19
--   Upgrade dari R18 dengan fokus:
--   [F1] Interaksi generator via Action button GUI (bukan LeftShift)
--   [F2] Evasion aman: tidak mendekati killer hanya untuk juke
--   [F3] Fix palletDrop / vault / emergency dodge
--   [F4] Rescue hook robust (multi-attribute + failure tracking)
--   [F5] Cancel repair terverifikasi (bebas gerak) + fallback input
--   [F6] ESP pathfinding (Part tipis di permukaan lantai)
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
    DEBUG_NAV            = false,   -- set true untuk ESP pathfinding

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

    EVADE_START_DIST     = 40,
    EVADE_JUKE_DIST      = 22,   -- [F2] 25 → 22 (turun 3 studs)
    JUKE_COMMIT_MIN_D    = 12,
    JUKE_COMMIT_MAX_D    = 22,
    DODGE_EMERGENCY_D    = 7,
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

    JUKE_SIDE_STEP       = 7,
    JUKE_BEHIND_OFFSET   = 8,
    JUKE_SIDE_TIMEOUT    = 1.4,
    JUKE_BEHIND_TIMEOUT  = 2.0,
    JUKE_PROGRESS_EPS    = 1.5,
    JUKE_PROGRESS_TIMEOUT= 0.9,
    JUKE_COOLDOWN        = 1.0,
    JUKE_ESCAPE_CANDIDATES = 12,
    JUKE_ESCAPE_ANGLES   = {0, 30, -30, 60, -60, 90, -90, 120, -120, 150, -150, 180},
    JUKE_ESCAPE_DIST     = 30,
    JUKE_SAFE_SIDE_MULT  = 0.85, -- [F2] side pos harus >= 85% jarak killer-awal

    WAYPOINT_REACH_DIST  = 4.5,
    WAYPOINT_SKIP_DIST   = 5.0,
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
    AGENT_WAYPOINT_SPACING = 3,

    RESCUE_DETECT_RANGE  = 10000,
    RESCUE_SAFE_DIST     = 50,
    RESCUE_ACTION_R      = 5,
    RESCUE_RETRY_GAP     = 5.0,  -- [F4] cooldown per target setelah gagal

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

    -- [F1] Interaksi generator: GUI adalah primary, tidak lagi LeftShift.
    INTERACT_METHOD         = "gui",
    INTERACT_GUI_TIMEOUT    = 1.4,
    INTERACT_GUI_MAX_RETRY  = 1,

    CHASE_VAULT_RANGE       = 14,
    CHASE_VAULT_COMMIT      = 10,
    CHASE_PALLET_RANGE      = 12,
    CHASE_PALLET_COMMIT     = 9,
    CHASE_SCAN_INTERVAL     = 2.5,
    PALLET_BLACKLIST_TTL    = 5.0,

    HANG_FAR_DIST           = 50,
    HANG_FORCE_CLEAR_TIME   = 2.5,

    EXIT_INTERACT_R         = 6,
    EXIT_SCAN_INTERVAL      = 1.0,
    FINISH_REACH_DIST       = 8,

    EXPECTED_GENS           = 5,
    GAME_END_SCAN_INTERVAL  = 1.0,

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
    repair       = { attr = "isRepairing",       hold = true,  timeout = 1.5, cooldown = 0.5 },
    heal         = { attr = "isHealing",         hold = true,  timeout = 1.5, cooldown = 0.5 },
    selfHeal     = { attr = "isHealing",         hold = true,  timeout = 1.5, cooldown = 0.5, soft = true },
    exit         = { attr = "isExiting",         hold = true,  timeout = 1.5, cooldown = 0.5 },
    unhook       = { attr = "isUnhooking",       hold = true,  timeout = 1.5, cooldown = 0.5 },
    vault        = { attr = "isVaulting",        hold = false, timeout = 0.8, cooldown = 0.4 },
    palletSlide  = { attr = "isSliding",         hold = false, timeout = 0.8, cooldown = 0.4 },
    palletDrop   = { attr = "isDroppingPallet",  hold = false, timeout = 0.8, cooldown = 0.6 },
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
-- SHIFT STATE (hanya untuk sprint; tidak lagi untuk interaksi)
-- ============================================================================
local Shift = { held = false }

local function pressShiftRaw()
    pcall(function()
        VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.LeftShift, false, game)
    end)
end

local function releaseShiftRaw()
    pcall(function()
        VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.LeftShift, false, game)
    end)
end

local function holdShift()
    if Shift.held then return end
    Shift.held = true
    pressShiftRaw()
end
local function releaseShift()
    if not Shift.held then return end
    Shift.held = false
    releaseShiftRaw()
end

-- [F1] Shift interact dinonaktifkan — tetap dipertahankan sebagai no-op
-- agar konsisten bila ada referensi lain.
local function beginShiftInteract() return false end
local function endShiftInteract()
    if not ActionState.shiftActive then return end
    ActionState.shiftActive = false
end

-- ============================================================================
-- CANCEL REPAIR REMOTE
-- ============================================================================
local Repair = { active = false, cancelFired = false }

local function notifyRepairStarted() Repair.active = true;  Repair.cancelFired = false end
local function notifyRepairEnded()   Repair.active = false; Repair.cancelFired = false end

local CancelRepairRemote = nil
local function getCancelRepairRemote()
    if CancelRepairRemote and CancelRepairRemote.Parent then return CancelRepairRemote end
    local ok, rem = pcall(function()
        local r = ReplicatedStorage:FindFirstChild("Remotes")
        if not r then return nil end
        local g = r:FindFirstChild("Generator")
        return g and g:FindFirstChild("Skillcheckvalidated") or nil
    end)
    CancelRepairRemote = ok and rem or nil
    return CancelRepairRemote
end

-- [F5] fireCancelRepair men-set Repair.cancelFired agar fireGenDone tidak
-- menyalahartikan cancel sebagai "gen done".
local function fireCancelRepair(gen, pt)
    local rem = getCancelRepairRemote()
    if not rem then return false end
    if not gen or not gen.Parent then return false end

    if not (pt and pt.Parent == gen and type(pt.Name) == "string"
            and pt.Name:match("^GeneratorPoint%d+$")) then
        pt = nil
        for _, ch in ipairs(gen:GetChildren()) do
            if ch:IsA("BasePart") and ch.Name:match("^GeneratorPoint%d+$") then
                pt = ch; break
            end
        end
    end
    if not pt then return false end

    local ok = pcall(function()
        if rem:IsA("RemoteEvent") then
            rem:FireServer("success", 1, gen, pt)
        elseif rem:IsA("BindableEvent") then
            rem:Fire("success", 1, gen, pt)
        end
    end)
    if ok then
        Repair.cancelFired = true
        dlog("[REPAIR] cancel remote fired")
    end
    return ok
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
    -- [F6] Pastikan ESP pathfinding tidak memblok raycast
    local vizFolder = workspace:FindFirstChild("KemiAI_PathViz")
    if vizFolder then table.insert(ignore, vizFolder) end
    params.FilterDescendantsInstances = ignore
    local dist_ = math.min(mag, maxDist or CONFIG.RAYCAST_DIST)
    return workspace:Raycast(fromPos, delta.Unit * dist_, params) == nil
end

local function rotateAroundY(v, rad)
    local c,s = math.cos(rad), math.sin(rad)
    return Vector3.new(v.X*c - v.Z*s, 0, v.X*s + v.Z*c)
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
    FenceCache.lastScan = now
    FenceCache.list = {}
    local function scan(node, depth)
        if depth > CONFIG.FENCE_SCAN_DEPTH or not node then return end
        local children = node:GetChildren()
        for _,ch in ipairs(children) do
            if ch:IsA("BasePart") and isFenceName(ch.Name) then
                table.insert(FenceCache.list, ch)
            elseif ch:IsA("Model") and isFenceName(ch.Name) then
                for _, sub in ipairs(ch:GetDescendants()) do
                    if sub:IsA("BasePart") then table.insert(FenceCache.list, sub) end
                end
            end
            if ch:IsA("Folder") or ch:IsA("Model") then
                scan(ch, depth+1)
            end
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
            if d < radius then
                table.insert(out, { part=f, dist=d })
            end
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
-- [F6] PATHFINDING ESP VISUALIZER
--   Part tipis berbasis Neon, non-collide, non-query, non-touch.
--   Dibersihkan otomatis saat waypoints kosong / DEBUG_NAV off / respawn.
-- ============================================================================
local PathViz = {
    folder = nil,
    waypointMarks = {},
    lineSegments = {},
    lastUpdate = 0,
    lastIndex = -1,
}

local function ensureVizFolder()
    if PathViz.folder and PathViz.folder.Parent then return PathViz.folder end
    local existing = workspace:FindFirstChild("KemiAI_PathViz")
    if existing then pcall(function() existing:Destroy() end) end
    local folder = Instance.new("Folder")
    folder.Name = "KemiAI_PathViz"
    folder.Parent = workspace
    PathViz.folder = folder
    return folder
end

local function clearPathViz()
    if PathViz.folder then
        for _, ch in ipairs(PathViz.folder:GetChildren()) do
            pcall(function() ch:Destroy() end)
        end
    end
    PathViz.waypointMarks = {}
    PathViz.lineSegments = {}
    PathViz.lastIndex = -1
end

local function makeVizPart(name, parent)
    local p = Instance.new("Part")
    p.Name = name
    p.Anchored = true
    p.CanCollide = false
    p.CanQuery = false
    p.CanTouch = false
    p.Material = Enum.Material.Neon
    p.Transparency = 0.35
    p.Parent = parent
    return p
end

local function updatePathViz()
    if not CONFIG.DEBUG_NAV then
        if PathViz.folder and #PathViz.folder:GetChildren() > 0 then
            clearPathViz()
        end
        return
    end

    local wps = PathFollower and PathFollower.waypoints
    if not wps or #wps == 0 then
        if PathViz.folder and #PathViz.folder:GetChildren() > 0 then
            clearPathViz()
        end
        return
    end

    local folder = ensureVizFolder()

    -- Waypoint markers
    for i, wp in ipairs(wps) do
        local mark = PathViz.waypointMarks[i]
        if not mark or not mark.Parent then
            mark = makeVizPart("WP_"..i, folder)
            mark.Size = Vector3.new(1.2, 0.12, 1.2)
            PathViz.waypointMarks[i] = mark
        end
        mark.Position = Vector3.new(wp.Position.X, wp.Position.Y + 0.6, wp.Position.Z)
        if i == PathFollower.index then
            mark.Color = Color3.fromRGB(0, 255, 90)
            mark.Transparency = 0.15
        elseif i == PathFollower.index + 1 then
            mark.Color = Color3.fromRGB(255, 240, 0)
            mark.Transparency = 0.2
        else
            mark.Color = Color3.fromRGB(0, 160, 255)
            mark.Transparency = 0.45
        end
    end

    for i = #wps + 1, #PathViz.waypointMarks do
        local m = PathViz.waypointMarks[i]
        if m then pcall(function() m:Destroy() end) end
        PathViz.waypointMarks[i] = nil
    end

    -- Line segments
    local needed = #wps - 1
    for i = 1, needed do
        local seg = PathViz.lineSegments[i]
        if not seg or not seg.Parent then
            seg = makeVizPart("Line_"..i, folder)
            seg.Transparency = 0.5
            seg.Color = Color3.fromRGB(0, 200, 255)
            PathViz.lineSegments[i] = seg
        end
        local p1 = Vector3.new(wps[i].Position.X,     wps[i].Position.Y   + 0.55, wps[i].Position.Z)
        local p2 = Vector3.new(wps[i+1].Position.X,   wps[i+1].Position.Y + 0.55, wps[i+1].Position.Z)
        local mid = (p1 + p2) * 0.5
        local len = (p2 - p1).Magnitude
        if len > 0.1 then
            seg.Size = Vector3.new(0.3, 0.12, len)
            -- CFrame.lookAt(mid, p1): -Z menghadap p1 → +Z menghadap p2 (stretch antar WP)
            seg.CFrame = CFrame.lookAt(mid, p1)
        else
            seg.Size = Vector3.new(0, 0, 0)
        end
    end

    for i = needed + 1, #PathViz.lineSegments do
        local s = PathViz.lineSegments[i]
        if s then pcall(function() s:Destroy() end) end
        PathViz.lineSegments[i] = nil
    end

    PathViz.lastIndex = PathFollower.index
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
-- [F4] SURVIVOR STATE — multi-attribute + tag + child object
-- ============================================================================
local HOOK_ATTRS = {
    "IsHooked", "Hooked", "OnHook", "isHooked", "IsOnHook", "HookedState",
}
local CARRIED_ATTRS = {
    "IsCarried", "Carried", "isCarried", "BeingCarried", "IsHolding",
}
local KNOCKED_ATTRS = {
    "IsKnocked", "Knocked", "IsDowned", "Downed", "IsDying",
}

local function attrBool(obj, name)
    if not obj then return false end
    local ok, v = pcall(function() return obj:GetAttribute(name) end)
    return ok and v == true
end

local function childBoolIsTrue(obj, names)
    if not obj then return false end
    for _, n in ipairs(names) do
        local ch = obj:FindFirstChild(n)
        if ch and ch:IsA("BoolValue") and ch.Value then return true end
    end
    return false
end

local function getSurvivorState(p)
    p = p or localPlayer
    local char = p.Character
    if not char then return nil end
    local hum = char:FindFirstChildOfClass("Humanoid")
    if not hum then return nil end
    if hum.Health <= 0 then return "dead" end

    local root = getPlayerRoot(p)

    for _, a in ipairs(HOOK_ATTRS) do
        if attrBool(char, a) or attrBool(root, a) then return "hooked" end
    end
    if childBoolIsTrue(char, {"Hooked","IsHooked","OnHookValue"}) then return "hooked" end
    if hasTagOrAttr(char, "Hooked") or hasTagOrAttr(root, "Hooked") then return "hooked" end

    for _, a in ipairs(CARRIED_ATTRS) do
        if attrBool(char, a) or attrBool(root, a) then return "carried" end
    end
    if hasTagOrAttr(char, "Carried") or hasTagOrAttr(root, "Carried") then return "carried" end

    for _, a in ipairs(KNOCKED_ATTRS) do
        if attrBool(char, a) or attrBool(root, a) then return "knocked" end
    end
    local rt = char:FindFirstChild("RagdollTrigger")
    if rt and rt:IsA("BoolValue") and rt.Value == true then return "knocked" end

    if root and attrBool(root, "CanGetHealed") then return "canBeHealed" end
    if hum.Health <= 50 then return "injured" end
    return "healthy"
end

local function getSelfState() return getSurvivorState(localPlayer) end

-- ============================================================================
-- ACTION BUTTON (GUI touch simulation)
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

-- ============================================================================
-- ACTION STATE MACHINE
-- ============================================================================
local requestStopAction

local function startActionGeneric(actionName, target, targetPoint, def)
    if not def then return false end
    local now = tick()

    if ActionState.current == actionName
        and (ActionState.phase == "starting" or ActionState.phase == "active") then
        return true
    end
    if ActionState.current and ActionState.phase == "stopping" then return false end
    if ActionState.current and ActionState.current ~= actionName then
        requestStopAction()
        return false
    end
    if now < ActionState.cooldownUntil then return false end

    local char = getChar()
    if not char then return false end

    if def.attr and char:GetAttribute(def.attr) == true then
        ActionState.current = actionName
        ActionState.attributeName = def.attr
        ActionState.isHold = def.hold
        ActionState.phase = "active"
        ActionState.target = target
        ActionState.targetPoint = targetPoint
        ActionState.startedAt = now
        ActionState.retryCount = 0
        ActionState.interactMethod = "gui"
        ActionState.shiftActive = false
        return true
    end

    -- [F1] Semua aksi pakai GUI (Action button) sebagai primary
    local triggered
    if def.hold then triggered = beginHoldAction()
    else triggered = TriggerMobileButton(CONFIG.TAP_ID) end
    ActionState.interactMethod = "gui"
    if not triggered then
        ActionState.cooldownUntil = now + 1.0
        return false
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
    return true
end

local function startAction(actionName, target, targetPoint)
    local def = ACTION_DEFS[actionName]
    if not def then return false end
    return startActionGeneric(actionName, target, targetPoint, def)
end

-- [F5] Verifikasi pelepasan repair — cek apakah karakter benar-benar bebas.
local RepairCancel = { active = false, startPos = nil, attempts = 0, nextCheckAt = 0 }

local function markRepairCancelStarted()
    local root = getRoot()
    RepairCancel.active = true
    RepairCancel.startPos = root and root.Position or nil
    RepairCancel.attempts = 0
    RepairCancel.nextCheckAt = tick() + 0.4
end

local function resetRepairCancel()
    RepairCancel.active = false
    RepairCancel.startPos = nil
    RepairCancel.attempts = 0
    RepairCancel.nextCheckAt = 0
end

local function updateRepairCancel(root, hum, now)
    if not RepairCancel.active then return end
    if now < RepairCancel.nextCheckAt then return end
    RepairCancel.nextCheckAt = now + 0.4

    if not RepairCancel.startPos then
        RepairCancel.startPos = root.Position
        return
    end

    local moved = (root.Position - RepairCancel.startPos).Magnitude
    if moved > 2 then
        dlog("[REPAIR-CANCEL] freed (moved %.1f)", moved)
        resetRepairCancel()
        return
    end

    RepairCancel.attempts = RepairCancel.attempts + 1
    if RepairCancel.attempts == 1 then
        pcall(function() hum.Jump = true end)
        log("[REPAIR-CANCEL] tidak bergerak → jump")
    elseif RepairCancel.attempts == 2 then
        pcall(function()
            VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.W, false, game)
            task.delay(0.2, function()
                VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.W, false, game)
            end)
        end)
        log("[REPAIR-CANCEL] tidak bergerak → W")
    elseif RepairCancel.attempts >= 3 then
        pcall(function()
            VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.Escape, false, game)
            task.delay(0.05, function()
                VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.Escape, false, game)
            end)
        end)
        log("[REPAIR-CANCEL] tidak bergerak → Esc")
        RepairCancel.attempts = 2
    end
    RepairCancel.startPos = root.Position
end

function requestStopAction()
    if not ActionState.current then return end
    if ActionState.phase == "stopping" then return end

    if ActionState.current == "repair" then
        local gen = ActionState.target
        local pt  = ActionState.targetPoint
        if gen and gen.Parent then
            local fired = fireCancelRepair(gen, pt)
            if fired then dlog("repair cancel fired")
            else log("repair cancel: remote fire failed") end
        end
        markRepairCancelStarted()
    end

    ActionState.phase = "stopping"
    ActionState.stopStartedAt = tick()
    ActionState.fallbackApplied = false
    endHoldAction()
    endShiftInteract()
end

-- [F1] Fallback shift dinonaktifkan; GUI sudah primary. Fungsi tetap ada
-- agar referensi lama tidak error.
local function tryGuiRepairFallback(_now)
    return false
end

local function updateActionState(now, char)
    if not ActionState.current then return end
    local def = ACTION_DEFS[ActionState.current]
    if not def then ActionState.current = nil; ActionState.phase = "idle"; return end

    local attrVal = def.attr and char and char:GetAttribute(def.attr) == true

    if ActionState.phase == "starting" then
        if attrVal then
            ActionState.phase = "active"
            ActionState.retryCount = 0
        else
            if ActionState.current == "repair" then
                tryGuiRepairFallback(now)
            end

            local startTimeout = def.timeout
            if ActionState.current == "repair" then
                startTimeout = CONFIG.INTERACT_GUI_TIMEOUT
            end

            if now - ActionState.interactStartedAt > startTimeout then
                if def.soft then
                    ActionState.phase = "active"
                elseif ActionState.retryCount < CONFIG.ACTION_START_RETRIES then
                    ActionState.retryCount = ActionState.retryCount + 1
                    if def.hold then
                        endHoldAction()
                        endShiftInteract()
                        local ok2 = beginHoldAction()
                        if ok2 then
                            ActionState.interactStartedAt = now
                            ActionState.interactMethod = "gui"
                        else
                            ActionState.current = nil; ActionState.phase = "idle"
                            ActionState.cooldownUntil = now + CONFIG.ACTION_FAIL_COOLDOWN
                        end
                    else
                        if TriggerMobileButton(CONFIG.TAP_ID) then
                            ActionState.interactStartedAt = now
                        else
                            ActionState.current = nil; ActionState.phase = "idle"
                            ActionState.cooldownUntil = now + CONFIG.ACTION_FAIL_COOLDOWN
                        end
                    end
                else
                    log(string.format("Action %s failed (no attr)", ActionState.current))
                    endHoldAction()
                    endShiftInteract()
                    ActionState.current = nil; ActionState.phase = "idle"
                    ActionState.cooldownUntil = now + CONFIG.ACTION_FAIL_COOLDOWN
                end
            end
        end
    elseif ActionState.phase == "active" then
        if not attrVal and not def.soft then
            log(string.format("Action %s ended", ActionState.current))
            endShiftInteract()
            ActionState.current = nil; ActionState.phase = "idle"
            ActionState.cooldownUntil = now + def.cooldown
        end
    elseif ActionState.phase == "stopping" then
        if not attrVal then
            endShiftInteract()
            ActionState.current = nil; ActionState.phase = "idle"
            ActionState.cooldownUntil = now + CONFIG.ACTION_BUSY_COOLDOWN
        elseif now - ActionState.stopStartedAt > CONFIG.ACTION_STOP_VERIFY then
            if not ActionState.fallbackApplied then
                ActionState.fallbackApplied = true
                local root = getRoot(); local hum = getHumanoid()
                if root and hum then
                    local dir = Vector3.new(math.random()-0.5, 0, math.random()-0.5)
                    if dir.Magnitude < 0.1 then dir = Vector3.new(1,0,0) end
                    hum:MoveTo(root.Position + dir.Unit * 6)
                end
            end
            if now - ActionState.stopStartedAt > CONFIG.ACTION_STOP_FORCE_CLEAR then
                log(string.format("Action %s force-clear", ActionState.current))
                endShiftInteract()
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
    local myRoot = getRoot(); if not myRoot then return {} end
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
}

local function initPath()
    if PathFollower.path then return end
    PathFollower.path = PathfindingService:CreatePath({
        AgentRadius = CONFIG.AGENT_RADIUS,
        AgentHeight = CONFIG.AGENT_HEIGHT,
        AgentCanJump = true,
        AgentMaxSlope = CONFIG.AGENT_MAX_SLOPE,
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
    PathFollower.lastMoveTo = nil
    PathFollower.lastWP = nil; PathFollower.lastWPSince = 0
    PathFollower.strafeAttempts = 0
    disconnectBlocked()
    -- [F6] Bersihkan visualisasi saat path dibatalkan
    if PathViz.folder and #PathViz.folder:GetChildren() > 0 then
        clearPathViz()
    end
end

local function setGoal(pos, tag)
    if not pos then return end
    initPath()
    local tagChanged = PathFollower.goalTag ~= tag
    local thresh = (tag == "chase") and CONFIG.CHASE_REPATH_THRESH or CONFIG.GOAL_REPATH_THRESH
    local posChanged = (not PathFollower.goalPos)
        or ((PathFollower.goalPos - pos).Magnitude > thresh)
    if tagChanged or posChanged then
        PathFollower.pendingPos = pos
        PathFollower.pendingTag = tag
    end
end

local function computePending()
    local root = getRoot(); if not root then return end
    local pos = PathFollower.pendingPos; local tag = PathFollower.pendingTag
    if not pos then return end
    if PathFollower.lastFailPos
        and tick() < PathFollower.failCooldownUntil
        and (PathFollower.lastFailPos - pos).Magnitude < 5 then
        PathFollower.pendingPos = nil; PathFollower.pendingTag = nil
        return
    end
    PathFollower.computing = true
    PathFollower.pendingPos = nil; PathFollower.pendingTag = nil
    local ok = pcall(function() PathFollower.path:ComputeAsync(root.Position, pos) end)
    PathFollower.computing = false
    if ok and PathFollower.path.Status == Enum.PathStatus.Success then
        PathFollower.goalPos = pos; PathFollower.goalTag = tag
        PathFollower.waypoints = PathFollower.path:GetWaypoints()
        PathFollower.index = 2
        PathFollower.stuckSince = 0; PathFollower.failCount = 0
        PathFollower.lastMoveTo = nil
        PathFollower.slopeStuckSince = 0
        disconnectBlocked()
        PathFollower.blockedConn = PathFollower.path.Blocked:Connect(function(idx)
            if idx >= (PathFollower.index or 1) then
                PathFollower.goalPos = nil
                log(string.format("Path blocked @%d → recompute", idx))
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

local function handleStuck(root, hum, now)
    if PathFollower.lastPos then
        local dPos = root.Position - PathFollower.lastPos
        local horiz = Vector3.new(dPos.X, 0, dPos.Z).Magnitude
        local dY = math.abs(dPos.Y)
        local movedHoriz = horiz >= CONFIG.NAV_PROGRESS_EPS
        local movedVert  = dY >= CONFIG.SLOPE_STUCK_Y_TOL

        if not movedHoriz and not movedVert then
            PathFollower.stuckSince = (PathFollower.stuckSince == 0) and now or PathFollower.stuckSince
            if now - PathFollower.stuckSince > CONFIG.NAV_STUCK_TIME then
                if now - PathFollower.lastStuckLog > CONFIG.NAV_LOG_INTERVAL then
                    PathFollower.lastStuckLog = now
                    log("Path: stuck >2s (h/v)")
                end
                if PathFollower.strafeAttempts < 2 then
                    PathFollower.strafeAttempts = PathFollower.strafeAttempts + 1
                    local fences = findNearbyFences(root.Position, 12, 3)
                    local perp
                    if #fences > 0 then
                        local f = fences[1]
                        local toFence = Vector3.new(f.Position.X - root.Position.X, 0, f.Position.Z - root.Position.Z)
                        if toFence.Magnitude > 0.5 then
                            perp = Vector3.new(-toFence.Z, 0, toFence.X).Unit
                        end
                    end
                    if not perp then
                        perp = Vector3.new(1, 0, 0)
                        if PathFollower.lastMoveTo then
                            local toWP = PathFollower.lastMoveTo - root.Position
                            if Vector3.new(toWP.X,0,toWP.Z).Magnitude > 0.5 then
                                local fwd = Vector3.new(toWP.X, 0, toWP.Z).Unit
                                perp = Vector3.new(-fwd.Z, 0, fwd.X)
                            end
                        end
                    end
                    local side = PathFollower.strafeDir
                    PathFollower.strafeDir = -PathFollower.strafeDir
                    local target = root.Position + perp * side * 8
                    if not isNearFence(target, CONFIG.FENCE_MARGIN) then
                        hum:MoveTo(target)
                        PathFollower.stuckSince = 0
                        PathFollower.lastPos = root.Position
                        return
                    end
                end
                pcall(function() hum.Jump = true end)
                PathFollower.goalPos = nil
                PathFollower.stuckSince = 0
                PathFollower.index = 1
                PathFollower.strafeAttempts = 0
            end
        else
            PathFollower.stuckSince = 0
            if movedHoriz then PathFollower.strafeAttempts = 0 end
        end

        if movedHoriz and dY > CONFIG.SLOPE_STUCK_Y_TOL * 2 and dPos.Y < 0 then
            PathFollower.slopeStuckSince = (PathFollower.slopeStuckSince == 0) and now or PathFollower.slopeStuckSince
            if now - PathFollower.slopeStuckSince > 3 then
                nlog("slope slide detected → force repath")
                PathFollower.goalPos = nil
                PathFollower.slopeStuckSince = 0
            end
        else
            PathFollower.slopeStuckSince = 0
        end
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
        else
            break
        end
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
        AgentRadius = CONFIG.AGENT_RADIUS,
        AgentHeight = CONFIG.AGENT_HEIGHT,
        AgentCanJump = true,
        AgentMaxSlope = CONFIG.AGENT_MAX_SLOPE,
        WaypointSpacing = CONFIG.AGENT_WAYPOINT_SPACING,
    })
    local ok = pcall(function() p:ComputeAsync(fromPos, endPos) end)
    local success = ok and p.Status == Enum.PathStatus.Success
    PathMemo[k] = { t=tick(), ok=success }
    return success
end

-- ============================================================================
-- ESCAPE CANDIDATE SCORING
-- ============================================================================
local function sampleEscapeCandidates(myPos, killerPos, myRoot, hum, radius)
    radius = radius or CONFIG.JUKE_ESCAPE_DIST
    local candidates = {}
    local baseAway
    if killerPos then
        baseAway = Vector3.new(myPos.X - killerPos.X, 0, myPos.Z - killerPos.Z)
        if baseAway.Magnitude < 0.01 then baseAway = Vector3.new(1,0,0) end
        baseAway = baseAway.Unit
    else
        baseAway = Vector3.new(1,0,0)
    end

    for _, deg in ipairs(CONFIG.JUKE_ESCAPE_ANGLES) do
        local dir = rotateAroundY(baseAway, math.rad(deg))
        local endPos = myPos + dir * radius

        if hasClearLine(myPos, endPos, nil, radius + 2) then
            local nearFence = isNearFence(endPos, CONFIG.FENCE_MARGIN)
            local pathOK = tryPath(myPos, endPos)

            if pathOK then
                local score = 0
                if killerPos then
                    local endKD = (endPos - killerPos).Magnitude
                    score = score + clamp(endKD / CONFIG.FLEE_MIN_DIST_KILLER, 0, 2) * 3
                end
                local open = hasClearLine(endPos, endPos + dir * 15, nil, 16) and 1 or 0
                score = score + open * 1.5
                if nearFence then score = score - 2.5 end
                if deg == 0 then score = score + 0.8 end
                if math.abs(deg) >= 120 then score = score - 0.6 end

                table.insert(candidates, {
                    pos = endPos, dir = dir, deg = deg, score = score,
                    endKD = killerPos and (endPos - killerPos).Magnitude or math.huge,
                })
            end
        end
    end
    table.sort(candidates, function(a,b) return a.score > b.score end)
    return candidates
end

local function pickBestEscape(myPos, killerPos, myRoot, hum)
    local candidates = sampleEscapeCandidates(myPos, killerPos, myRoot, hum, CONFIG.JUKE_ESCAPE_DIST)
    if #candidates == 0 then return nil end
    local best = candidates[1]
    dlog("[ESCAPE] best deg=%d score=%.2f endKD=%.1f",
        best.deg, best.score, best.endKD)
    return best
end

-- ============================================================================
-- [F2] EVADE STATE MACHINE — AMAN, tidak mendekati killer
-- ============================================================================
local Evade = {
    phase        = "idle",
    side         = nil,
    sideTarget   = nil,
    behindTarget = nil,   -- opsional; boleh nil
    escapeTarget = nil,
    killerStartPos = nil,
    killerFwdStart = nil,
    phaseStartedAt = 0,
    jukeStartedAt = 0,
    lastProgressPos = nil,
    lastProgressT = 0,
    lastJukeAt = 0,
    aborted = false,
    reason = "",
}

local function resetEvade(reason)
    if Evade.phase ~= "idle" and reason then dlog("[EVADE] reset: %s", reason) end
    Evade.phase = "idle"
    Evade.side = nil
    Evade.sideTarget = nil
    Evade.behindTarget = nil
    Evade.escapeTarget = nil
    Evade.killerStartPos = nil
    Evade.killerFwdStart = nil
    Evade.phaseStartedAt = 0
    Evade.jukeStartedAt = 0
    Evade.lastProgressPos = nil
    Evade.lastProgressT = 0
    Evade.aborted = false
    Evade.reason = reason or ""
end

local function getKillerForward(killerRoot)
    if not killerRoot then return nil end
    local v = killerRoot.AssemblyLinearVelocity
    if v and Vector3.new(v.X, 0, v.Z).Magnitude > 3 then
        return Vector3.new(v.X, 0, v.Z).Unit
    end
    local lv = killerRoot.CFrame.LookVector
    local f = Vector3.new(lv.X, 0, lv.Z)
    if f.Magnitude < 0.01 then return nil end
    return f.Unit
end

-- [F2] Juke baru:
--   1) Side target dihitung dari posisi PLAYER (lateral), BUKAN dari killer.
--   2) Behind target hanya dipakai jika killer bergerak MENJAUH (overshoot).
--   3) Setiap side/behind wajib validasi line + path + fence + jarak-ke-killer.
local function tryStartJuke(root, killerRoot)
    local now = tick()
    if now - Evade.lastJukeAt < CONFIG.JUKE_COOLDOWN then return false, "cooldown" end

    local toKiller = Vector3.new(killerRoot.Position.X - root.Position.X, 0,
                                  killerRoot.Position.Z - root.Position.Z)
    local kD = toKiller.Magnitude
    if kD < CONFIG.JUKE_COMMIT_MIN_D or kD > CONFIG.JUKE_COMMIT_MAX_D then
        return false, string.format("dist %.1f out-of-window", kD)
    end
    if toKiller.Magnitude < 0.5 then return false, "zero-dist" end
    local toKillerDir = toKiller.Unit

    local killerFwd = getKillerForward(killerRoot) or (-toKillerDir)
    -- Apakah killer menjauh dari player? (dipakai untuk izin behind maneuver)
    local killerMovingAway = (killerFwd:Dot(toKillerDir) > 0.25)

    -- Perp terhadap arah player→killer (basis lateral dari PLAYER)
    local perpBase = Vector3.new(-toKillerDir.Z, 0, toKillerDir.X).Unit

    local minSideDistK = kD * CONFIG.JUKE_SAFE_SIDE_MULT

    local bestSide, bestSidePos, bestBehindPos, bestScore = nil, nil, nil, -math.huge
    for _, side in ipairs({1, -1}) do
        local perp = perpBase * side
        local sidePos = root.Position + perp * CONFIG.JUKE_SIDE_STEP

        local sideLineOK  = hasClearLine(root.Position, sidePos, nil, CONFIG.JUKE_SIDE_STEP + 2)
        local sideClear   = not isNearFence(sidePos, CONFIG.FENCE_MARGIN)
        local sidePathOK  = tryPath(root.Position, sidePos)
        local sideKDist   = (sidePos - killerRoot.Position).Magnitude

        -- Side tidak boleh lebih dekat ke killer dari threshold aman
        if sideLineOK and sideClear and sidePathOK and sideKDist >= minSideDistK then
            -- Behind hanya jika killer bergerak menjauh
            local behindPos = nil
            if killerMovingAway then
                local testBehind = killerRoot.Position
                    + killerFwd * CONFIG.JUKE_BEHIND_OFFSET
                    + perp * 2
                local behindLineOK = hasClearLine(sidePos, testBehind, nil, 20)
                local behindClear  = not isNearFence(testBehind, CONFIG.FENCE_MARGIN)
                local behindPathOK = tryPath(sidePos, testBehind)
                local behindKDist  = (testBehind - killerRoot.Position).Magnitude
                if behindLineOK and behindClear and behindPathOK and behindKDist >= 4 then
                    behindPos = testBehind
                end
            end

            local toSide = (sidePos - killerRoot.Position)
            local sideScore = 0
            if toSide.Magnitude > 0.01 then
                sideScore = -toSide.Unit:Dot(killerFwd) * 4
            end
            sideScore = sideScore - (root.Position - sidePos).Magnitude * 0.2
            sideScore = sideScore + (sideKDist - kD) * 0.6

            if sideScore > bestScore then
                bestScore, bestSide, bestSidePos, bestBehindPos = sideScore, side, sidePos, behindPos
            end
        end
    end

    if not bestSide then return false, "no-safe-side" end

    -- Escape candidate dari posisi akhir (behind atau side)
    local escapeRef = bestBehindPos or bestSidePos
    local escCands = sampleEscapeCandidates(
        escapeRef, killerRoot.Position, root, nil, CONFIG.JUKE_ESCAPE_DIST)
    local escape = escCands[1]
    if not escape then
        return false, "no-escape-plan"
    end

    Evade.phase = "side"
    Evade.side = bestSide
    Evade.sideTarget = bestSidePos
    Evade.behindTarget = bestBehindPos  -- boleh nil
    Evade.escapeTarget = escape.pos
    Evade.killerStartPos = killerRoot.Position
    Evade.killerFwdStart = killerFwd
    Evade.phaseStartedAt = now
    Evade.jukeStartedAt = now
    Evade.lastProgressPos = root.Position
    Evade.lastProgressT = now
    Evade.lastJukeAt = now
    Evade.aborted = false
    Evade.reason = ""
    log(string.format("[JUKE] commit side=%s behind=%s d=%.1f score=%.2f",
        bestSide > 0 and "R" or "L", bestBehindPos and "y" or "n", kD, bestScore))
    return true
end

local function updateEvade(root, killerRoot, hum, now)
    if Evade.phase == "idle" then return false end

    local kD = (root.Position - killerRoot.Position).Magnitude
    local phaseAge = now - Evade.phaseStartedAt

    -- Progress watchdog (hanya untuk side/behind)
    if Evade.phase == "side" or Evade.phase == "behind" then
        if now - Evade.lastProgressT > CONFIG.JUKE_PROGRESS_TIMEOUT then
            local moved = (root.Position - Evade.lastProgressPos).Magnitude
            if moved < CONFIG.JUKE_PROGRESS_EPS then
                log("[JUKE] no progress → abort")
                resetEvade("no-progress")
                return false
            end
            Evade.lastProgressPos = root.Position
            Evade.lastProgressT = now
        end
    end

    -- Emergency dodge ketika killer sangat dekat
    if kD < CONFIG.DODGE_EMERGENCY_D and Evade.phase ~= "escape" then
        local toKiller = Vector3.new(killerRoot.Position.X - root.Position.X, 0,
                                      killerRoot.Position.Z - root.Position.Z)
        if toKiller.Magnitude > 0.5 then
            local perp = Vector3.new(-toKiller.Z, 0, toKiller.X).Unit
            local side = (math.random() < 0.5) and 1 or -1
            local target = root.Position + perp * side * 9
            if hasClearLine(root.Position, target) and not isNearFence(target, CONFIG.FENCE_MARGIN) then
                hum:MoveTo(target)
                Evade.lastProgressPos = root.Position
                Evade.lastProgressT = now
                dlog("[EVADE] emergency dodge side=%d kD=%.1f", side, kD)
                return true
            end
        end
    end

    if Evade.phase == "side" then
        local sideDist = (root.Position - Evade.sideTarget).Magnitude
        if sideDist < 3 then
            if Evade.behindTarget then
                -- Cek apakah killer masih bergerak menjauh sebelum behind
                local killerFwdNow = getKillerForward(killerRoot)
                local toPlayerNow = Vector3.new(root.Position.X - killerRoot.Position.X,
                                                 0, root.Position.Z - killerRoot.Position.Z)
                local movingAwayNow = false
                if killerFwdNow and toPlayerNow.Magnitude > 0.1 then
                    movingAwayNow = killerFwdNow:Dot(toPlayerNow.Unit) > 0.15
                end
                if movingAwayNow then
                    Evade.phase = "behind"
                    Evade.phaseStartedAt = now
                    Evade.lastProgressPos = root.Position
                    Evade.lastProgressT = now
                    log("[JUKE] phase=behind")
                else
                    Evade.phase = "escape"
                    Evade.phaseStartedAt = now
                    log("[JUKE] phase=escape (killer berhenti menjauh)")
                end
            else
                Evade.phase = "escape"
                Evade.phaseStartedAt = now
                log("[JUKE] phase=escape (tanpa behind)")
            end
        elseif phaseAge > CONFIG.JUKE_SIDE_TIMEOUT then
            log("[JUKE] side timeout → escape fallback")
            Evade.phase = "escape"
            Evade.phaseStartedAt = now
        else
            local sideKillerDist = (Evade.sideTarget - killerRoot.Position).Magnitude
            if sideKillerDist < 5 then
                log("[JUKE] side killer too close → escape fallback")
                Evade.phase = "escape"
                Evade.phaseStartedAt = now
            else
                hum:MoveTo(Evade.sideTarget)
                return true
            end
        end
    end

    if Evade.phase == "behind" then
        if not Evade.behindTarget then
            Evade.phase = "escape"
            Evade.phaseStartedAt = now
        else
            local behindDist = (root.Position - Evade.behindTarget).Magnitude
            if behindDist < 3 then
                Evade.phase = "escape"
                Evade.phaseStartedAt = now
                log("[JUKE] phase=escape (behind reached)")
            elseif phaseAge > CONFIG.JUKE_BEHIND_TIMEOUT then
                log("[JUKE] behind timeout → escape")
                Evade.phase = "escape"
                Evade.phaseStartedAt = now
            else
                hum:MoveTo(Evade.behindTarget)
                return true
            end
        end
    end

    if Evade.phase == "escape" then
        if not Evade.escapeTarget then
            resetEvade("no-escape-target")
            return false
        end
        local escKD = (Evade.escapeTarget - killerRoot.Position).Magnitude
        if escKD < CONFIG.DODGE_EMERGENCY_D then
            local best = pickBestEscape(root.Position, killerRoot.Position, root, hum)
            if best then
                Evade.escapeTarget = best.pos
                Evade.phaseStartedAt = now
            else
                resetEvade("escape-compromised")
                return false
            end
        end
        setGoal(Evade.escapeTarget, "escape")
        followStep()
        if (root.Position - Evade.escapeTarget).Magnitude < CONFIG.FLEE_REACHED_RADIUS then
            log("[JUKE] escape reached → idle")
            resetEvade("escape-done")
            return false
        end
        return true
    end

    if phaseAge > (CONFIG.JUKE_SIDE_TIMEOUT + CONFIG.JUKE_BEHIND_TIMEOUT + 2) then
        log("[JUKE] total timeout → abort")
        resetEvade("total-timeout")
    end
    return false
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
                elseif v == true then
                    occ[pt] = true
                end
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
            elseif not best then
                best = pt
            end
        end
    end
    if best then return best.Position, best end
    return nil, nil
end

local function isApproachPointAvailable(gen, apPos)
    if not gen or not apPos then return false end
    local pts = genPoints(gen)
    if #pts == 0 then return true end
    local occ = getGenOccupancyMap(gen)
    for _, pt in ipairs(pts) do
        if (pt.Position - apPos).Magnitude < 1.0 then
            return not occ[pt]
        end
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
    local t = TargetBlacklist[key]
    if not t then return false end
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
-- GAME END TRACKER
-- ============================================================================
local GameEnd = {
    seenGenerators      = {},
    completedGenerators = {},
    seenCount           = 0,
    doneCount           = 0,
    lastScan            = 0,
    gameComplete        = false,
    lastCompleteLog     = 0,
}

local function genPosKey(gen)
    if not gen then return nil end
    local ok, pos = pcall(function()
        if gen:IsA("BasePart") then return gen.Position end
        if gen:IsA("Model") and gen.PrimaryPart then return gen.PrimaryPart.Position end
        local p1 = gen:FindFirstChild("GeneratorPoint1")
        if p1 and p1:IsA("BasePart") then return p1.Position end
        local bp = gen:FindFirstChildWhichIsA("BasePart", true)
        if bp then return bp.Position end
        return nil
    end)
    if not ok or not pos then return nil end
    return string.format("%.0f_%.0f_%.0f", pos.X, pos.Y, pos.Z)
end

local function updateGameEnd(now)
    if now - GameEnd.lastScan < CONFIG.GAME_END_SCAN_INTERVAL then return end
    GameEnd.lastScan = now

    local list = getGeneratorList()
    for _, gen in ipairs(list) do
        if gen and gen.Parent then
            local key = genPosKey(gen)
            if key then
                if not GameEnd.seenGenerators[key] then
                    GameEnd.seenGenerators[key] = true
                    GameEnd.seenCount = GameEnd.seenCount + 1
                end
                local prog = getGenProgress(gen)
                if prog and prog >= 100 then
                    if not GameEnd.completedGenerators[key] then
                        GameEnd.completedGenerators[key] = true
                        GameEnd.doneCount = GameEnd.doneCount + 1
                    end
                end
            end
        end
    end
end

local function hasActiveKiller()
    for _, p in ipairs(Players:GetPlayers()) do
        if roleOfPlayer(p) == "Killer" then
            if p.Character and p.Character:FindFirstChildOfClass("Humanoid") then
                return true
            end
        end
    end
    return false
end

local function hasOtherActiveSurvivors()
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= localPlayer and roleOfPlayer(p) == "Survivor" then
            local st = getSurvivorState(p)
            if st and st ~= "dead" then return true end
            if not st and p.Character and p.Character:FindFirstChildOfClass("Humanoid") then return true end
        end
    end
    return false
end

local function checkGameComplete(now)
    if GameEnd.gameComplete then return true end
    if GameEnd.seenCount < CONFIG.EXPECTED_GENS then return false end
    if GameEnd.doneCount < CONFIG.EXPECTED_GENS then return false end
    if not hasActiveKiller() then return false end
    if hasOtherActiveSurvivors() then return false end
    GameEnd.gameComplete = true
    if now - GameEnd.lastCompleteLog > 5 then
        GameEnd.lastCompleteLog = now
        log(string.format("[GAME END] %d/%d gens done",
            GameEnd.doneCount, GameEnd.seenCount))
    end
    return true
end

local function resetGameEnd()
    GameEnd.seenGenerators = {}
    GameEnd.completedGenerators = {}
    GameEnd.seenCount = 0
    GameEnd.doneCount = 0
    GameEnd.gameComplete = false
    GameEnd.lastScan = 0
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
    local myRoot = getRoot()
    local best, bestPos, bestCost = nil, nil, math.huge
    for _,gen in ipairs(list) do
        if gen.Parent and gen ~= exclude and not updateGeneratorProgress(gen) then
            local ap = select(1, genBestAvailablePoint(gen, myRoot))
            if ap and not isTargetBlacklisted(ap) then
                local dAI = (myPos - ap).Magnitude
                local dAK = killerPos and (ap - killerPos).Magnitude or math.huge
                local safeEnough = (not killerPos) or (dAK >= CONFIG.FLEE_MIN_DIST_KILLER)
                if safeEnough and dAI <= CONFIG.FLEE_SAFE_GEN_MAX and tryPath(myPos, ap) then
                    if not isNearFence(ap, CONFIG.FENCE_MARGIN + 1) then
                        local prog = getGenProgress(gen) or 0
                        local c = CONFIG.ROUTE_W.w_length * clamp(dAI*1.15/CONFIG.ROUTE_REF_LEN,0,2)
                        if killerPos then
                            c = c + CONFIG.ROUTE_W.w_exposure * clamp(1 - dAK/CONFIG.GEN_KILLER_SAFE_DIST,0,1)
                            c = c - CONFIG.ROUTE_W.w_safety * clamp(dAK/CONFIG.FLEE_MIN_DIST_KILLER,0,1)
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
        local best = pickBestEscape(myPos, killerPos, root, nil)
        if best then
            FLEE.target = best.pos; FLEE.lastPick = now
            FLEE.commitTarget = best.pos
            FLEE.commitUntil = now + CONFIG.FLEE_COMMIT_TIME
            return best.pos
        end
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

    local best = pickBestEscape(myPos, killerPos, root, nil)
    if best then
        FLEE.target = best.pos; FLEE.lastPick = now
        FLEE.commitTarget = best.pos
        FLEE.commitUntil = now + CONFIG.FLEE_COMMIT_TIME
        return best.pos
    end
    local away = Vector3.new(myPos.X - killerPos.X, 0, myPos.Z - killerPos.Z)
    if away.Magnitude < 0.01 then away = Vector3.new(1,0,0) end
    local fb = myPos + away.Unit * 22
    FLEE.target=fb; FLEE.lastPick=now; FLEE.commitTarget=fb
    FLEE.commitUntil = now + CONFIG.FLEE_COMMIT_TIME
    return fb
end

-- ============================================================================
-- CHASE OBSTACLE
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
    ObstacleCache.windows = {}
    ObstacleCache.pallets = {}
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

-- [F3] Pallet blacklist
local PalletBlacklist = {}
local function isPalletBlacklisted(p)
    local t = PalletBlacklist[p]
    return t and (tick() - t) < CONFIG.PALLET_BLACKLIST_TTL
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
                    if hasClearLine(myPos, w.Position) then bestD = d; best = w end
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
        if p.Parent and not isPalletBlacklisted(p) then
            local d = (myPos - p.Position).Magnitude
            if d < bestD then
                local toKiller = killerPos - myPos
                local toPallet = p.Position - myPos
                if toKiller.Magnitude > 0.1 and toPallet.Magnitude > 0.1 then
                    local dot = toKiller.Unit:Dot(toPallet.Unit)
                    if dot > 0.5 and tryPath(myPos, p.Position) then
                        bestD = d; best = p
                    end
                end
            end
        end
    end
    return best
end

-- ============================================================================
-- EXIT GATE
-- ============================================================================
local ExitManager = { detected = false, exitLever = nil, leverGoal = nil,
                      lastScan = 0, gateOpen = false, finishline = nil }

local function scanExitGate()
    local map = workspace:FindFirstChild("Map")
    if not map then return false, nil, nil end
    for _, folder in ipairs(map:GetChildren()) do
        if folder.Name:match("^Exit") then
            local exitLever = folder:FindFirstChild("ExitLever")
            if exitLever then
                local main = exitLever:FindFirstChild("Main")
                if main and hasTagOrAttr(main, "Exitpoint") then
                    local lg = exitLever:FindFirstChild("LeverGoal", true)
                    return true, exitLever, lg
                end
            end
        end
    end
    return false, nil, nil
end

local function checkExitAvailable()
    local now = tick()
    if now - ExitManager.lastScan < CONFIG.EXIT_SCAN_INTERVAL then
        return ExitManager.detected, ExitManager.exitLever, ExitManager.leverGoal
    end
    ExitManager.lastScan = now
    local detected, lever, lg = scanExitGate()
    if detected ~= ExitManager.detected then
        ExitManager.detected = detected
        if detected then log("[EXIT] Exitpoint detected → endgame active!")
        else log("[EXIT] Exitpoint gone") end
    end
    ExitManager.exitLever = lever
    ExitManager.leverGoal = lg
    return detected, lever, lg
end

local function isGateOpen()
    local detected, exitLever, leverGoal = checkExitAvailable()
    if not detected then return false end
    if not leverGoal or not leverGoal.Parent then return true end
    for _, key in ipairs({"Used","Activated","Opened","Done","Inactive","IsOpen","Consumed"}) do
        local ok, v = pcall(function() return leverGoal:GetAttribute(key) end)
        if ok and (v == true) then return true end
        if hasTagOrAttr(leverGoal, key) then return true end
    end
    local main = exitLever and exitLever:FindFirstChild("Main")
    if main and main:IsA("BasePart") and main.CanCollide == false then return true end
    return false
end

local function findNearestFinishline(fromPos)
    local candidates = {}
    local function scan(node, depth)
        if depth > 6 or not node then return end
        for _,ch in ipairs(node:GetChildren()) do
            if ch:IsA("BasePart") then
                local nm = ch.Name
                if nm == "Finishline" or nm == "Fininshline" or nm == "FinishLine" then
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
    forceRescan = false,
    lastSlotCheck = 0,
    repairWaitStart = 0,
    lastVaultAttempt = 0,
    lastPalletAttempt = 0,
    lastPalletTarget = nil,
    lastPalletSuccess = 0,
    hangDetectStart = 0,
    exitFinishline = nil,
    -- [F4] Track rescue failures
    failedRescues = {},
    currentRescueTarget = nil,
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
    Survivor.lastVaultAttempt = 0
    Survivor.lastPalletAttempt = 0
    Survivor.lastPalletTarget = nil
    Survivor.lastPalletSuccess = 0
    Survivor.hangDetectStart = 0
    Survivor.exitFinishline = nil
    Survivor.failedRescues = {}
    Survivor.currentRescueTarget = nil
    PalletBlacklist = {}
    cancelGoal(); resetFlee(); resetThreat(); resetPerception()
    resetEvade("survivorReset")
    resetRepairCancel()
    notifyRepairEnded(); releaseShift(); endHoldAction(); endShiftInteract()
    clearPathViz()
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
            -- [F5] fireGenDone sudah cek Repair.cancelFired
            fireGenDone()
            notifyRepairEnded()
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
                log("Survivor: current gen slots all occupied → re-evaluate")
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
                    log(string.format("Survivor: switch → %s (Δ=%.1f)",
                        newGen:GetFullName(), currentScore - ns))
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
    if not ActionState.current then
        Survivor.hangDetectStart = 0
        return
    end
    local killers = evaluateKillers()
    local kD = (#killers > 0) and killers[1].dist or math.huge

    if Survivor.hangDetectStart == 0 then
        Survivor.hangDetectStart = now
        return
    end
    local hangDur = now - Survivor.hangDetectStart

    if kD <= CONFIG.HANG_FAR_DIST then
        if ActionState.current ~= "vault"
            and ActionState.current ~= "palletDrop"
            and ActionState.current ~= "palletSlide"
            and ActionState.current ~= "exit" then
            if ActionState.phase ~= "stopping" then
                log(string.format("[HANG] killer close (d=%.0f) action=%s → force stop",
                    kD, ActionState.current))
                requestStopAction()
            end
        end
    else
        if hangDur > CONFIG.HANG_FORCE_CLEAR_TIME then
            if ActionState.phase == "stopping" then
                log("[HANG] stuck in stopping → force clear")
                ActionState.current = nil; ActionState.phase = "idle"
                ActionState.cooldownUntil = now + 0.5
                endHoldAction(); endShiftInteract()
            elseif ActionState.phase == "active" and hangDur > 20 then
                log("[HANG] active too long & killer far → clear")
                ActionState.current = nil; ActionState.phase = "idle"
                ActionState.cooldownUntil = now + 0.5
                endHoldAction(); endShiftInteract()
            end
            Survivor.hangDetectStart = 0
        end
    end
end

local function handleExitPhase(now, root, hum)
    local detected, exitLever, leverGoal = checkExitAvailable()
    if not detected then return false end

    if isGateOpen() then
        if not Survivor.exitFinishline or not Survivor.exitFinishline.Parent then
            local refPos = (leverGoal and leverGoal.Position)
                        or (exitLever and exitLever:FindFirstChild("Main") and
                            exitLever.Main.Position)
                        or root.Position
            Survivor.exitFinishline = findNearestFinishline(refPos)
            if Survivor.exitFinishline then
                log("[EXIT] gate open → heading to "..Survivor.exitFinishline:GetFullName())
            end
        end
        setSurvivorState("EscapingMap", now, "(gate open)")
        if Survivor.exitFinishline then
            local dF = (root.Position - Survivor.exitFinishline.Position).Magnitude
            if dF <= CONFIG.FINISH_REACH_DIST then
                log("[EXIT] FINISH REACHED!")
                hum:Move(Vector3.zero, false)
                cancelGoal()
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

    if leverGoal and leverGoal.Parent then
        setSurvivorState("EscapingMap", now, "(holding lever)")
        local d = (root.Position - leverGoal.Position).Magnitude
        if d <= CONFIG.EXIT_INTERACT_R then
            hum:Move(Vector3.zero, false)
            cancelGoal()
            if ActionState.current ~= "exit" and now >= ActionState.cooldownUntil then
                startAction("exit", leverGoal)
            end
        else
            if ActionState.current == "exit" then requestStopAction() end
            holdShift()
            setGoal(leverGoal.Position, "exit")
            followStep()
        end
        return true
    end

    if not Survivor.exitFinishline or not Survivor.exitFinishline.Parent then
        Survivor.exitFinishline = findNearestFinishline(root.Position)
    end
    if Survivor.exitFinishline then
        setSurvivorState("EscapingMap", now, "(no lever)")
        local dF = (root.Position - Survivor.exitFinishline.Position).Magnitude
        if dF <= CONFIG.FINISH_REACH_DIST then
            hum:Move(Vector3.zero, false)
            cancelGoal()
            return true
        end
        holdShift()
        setGoal(Survivor.exitFinishline.Position, "finish")
        followStep()
    end
    return true
end

local function SurvivorAI(now)
    local hum = getHumanoid()
    local root = getRoot()
    if not hum or not root or hum.Health <= 0 then
        Survivor.State = "WaitingForCharacter"
        notifyRepairEnded(); releaseShift(); endHoldAction(); endShiftInteract(); cancelGoal()
        resetEvade("dead-or-nohum")
        return
    end

    local selfState = getSelfState()
    if selfState == "dead" then
        setSurvivorState("Dead", now)
        endHoldAction(); releaseShift(); endShiftInteract(); cancelGoal(); resetEvade("dead")
        return
    end
    if selfState == "hooked" then
        setSurvivorState("Hooked", now)
        endHoldAction(); releaseShift(); endShiftInteract(); cancelGoal(); resetEvade("hooked")
        return
    end
    if selfState == "carried" then
        setSurvivorState("Carried", now)
        endHoldAction(); releaseShift(); endShiftInteract(); cancelGoal(); resetEvade("carried")
        return
    end
    if selfState == "knocked" then
        setSurvivorState("SelfHealing", now)
        releaseShift(); cancelGoal(); resetEvade("knocked")
        hum:Move(Vector3.zero, false)
        if ActionState.current ~= "selfHeal" then
            if ActionState.current then
                if ActionState.phase ~= "stopping" then requestStopAction() end
            elseif now >= ActionState.cooldownUntil then
                startAction("selfHeal", nil)
            end
        end
        return
    end

    hangWatchdog(now)

    updateGameEnd(now)
    if checkGameComplete(now) then
        setSurvivorState("AllDone", now, "(game end)")
        endHoldAction(); releaseShift(); endShiftInteract(); cancelGoal(); resetEvade("game-end")
        notifyRepairEnded()
        return
    end

    -- EXIT PHASE
    do
        local detected = checkExitAvailable()
        if detected then
            local killers = evaluateKillers()
            local killerClose = (#killers > 0 and killers[1].dist < 30)
            if not killerClose then
                if handleExitPhase(now, root, hum) then return end
            end
        end
    end

    local killer, killerRoot, kD, threat, P = updateThreat(now)

    -- EVADE — state machine aktif
    if Evade.phase ~= "idle" then
        if not killerRoot then
            resetEvade("killer-gone")
        elseif updateEvade(root, killerRoot, hum, now) then
            return
        end
    end

    local inEvadeBand = threat and killerRoot and (kD <= CONFIG.EVADE_START_DIST)
    if inEvadeBand then
        if ActionState.current and ActionState.current ~= "vault"
            and ActionState.current ~= "palletDrop" and ActionState.current ~= "palletSlide" then
            if ActionState.phase ~= "stopping" then requestStopAction() end
        end
        setSurvivorState("EvadingKiller", now, string.format("(d=%.1f P=%.2f)", kD, P or 0))

        -- [F5] Verifikasi karakter benar-benar bebas setelah cancel repair
        if ActionState.current == "repair" and ActionState.phase == "stopping" then
            if not RepairCancel.active then
                markRepairCancelStarted()
            end
        end
        updateRepairCancel(root, hum, now)

        local emergency = (kD <= CONFIG.DODGE_EMERGENCY_D)

        -- [F3] Pallet drop (prioritaskan jika dekat)
        if ActionState.current ~= "palletDrop"
            and (now - Survivor.lastPalletAttempt) > 1.0
            and kD <= CONFIG.PALLET_DROP_D then
            local pallet = findPalletForDrop(root, killerRoot, CONFIG.CHASE_PALLET_RANGE)
            if pallet
                and (root.Position - pallet.Position).Magnitude < CONFIG.CHASE_PALLET_COMMIT
                and not isPalletBlacklisted(pallet) then
                if startAction("palletDrop", pallet) then
                    Survivor.lastPalletAttempt = now
                    Survivor.lastPalletTarget = pallet
                    hum:Move(Vector3.zero, false)
                    log("[PALLET] drop @ "..pallet:GetFullName())
                    return
                end
            end
        end

        -- [F3] Vault window
        if ActionState.current ~= "vault"
            and (now - Survivor.lastVaultAttempt) > 1.0
            and kD <= CONFIG.VAULT_USE_D then
            local vault = findChaseVaultWindow(root, killerRoot, CONFIG.CHASE_VAULT_RANGE)
            if vault and (root.Position - vault.Position).Magnitude < CONFIG.CHASE_VAULT_COMMIT then
                if startAction("vault", vault) then
                    Survivor.lastVaultAttempt = now
                    holdShift()
                    hum:MoveTo(vault.Position)
                    log("[VAULT] window @ "..vault:GetFullName())
                    return
                end
            end
        end

        -- Emergency: skip juke, langsung flee
        if emergency then
            local fleeTarget = pickFleeTarget(root, killerRoot)
            if fleeTarget then
                holdShift()
                setGoal(fleeTarget, "flee")
                followStep()
            end
            return
        end

        -- Juke attempt (normal window)
        if kD <= CONFIG.EVADE_JUKE_DIST and kD >= CONFIG.JUKE_COMMIT_MIN_D then
            if Evade.phase == "idle" then
                local ok, why = tryStartJuke(root, killerRoot)
                if ok then
                    if updateEvade(root, killerRoot, hum, now) then
                        holdShift()
                        return
                    end
                else
                    dlog("[JUKE] skip: %s", why or "?")
                end
            end
        end

        -- Vault ongoing
        if ActionState.current == "vault" and ActionState.target then
            hum:MoveTo(ActionState.target.Position)
            return
        end
        -- Pallet ongoing (stop in place)
        if ActionState.current == "palletDrop" then
            hum:Move(Vector3.zero, false)
            return
        end

        -- Regular flee
        local fleeTarget = pickFleeTarget(root, killerRoot)
        if fleeTarget then
            holdShift()
            setGoal(fleeTarget, "flee")
            followStep()
        end
        return
    elseif threat and killerRoot then
        if kD <= CONFIG.THREAT_WARNING_DIST * 0.7 then
            if ActionState.current == "repair" or ActionState.current == "heal"
                or ActionState.current == "unhook" then
                if ActionState.phase ~= "stopping" then
                    requestStopAction()
                end
            end
        end
    end

    -- [F3] Bersihkan pallet attempt lama
    if Survivor.lastPalletAttempt and (now - Survivor.lastPalletAttempt) > 3
        and ActionState.current ~= "palletDrop" then
        local success = (Survivor.lastPalletSuccess or 0) > Survivor.lastPalletAttempt
        if not success and Survivor.lastPalletTarget and Survivor.lastPalletTarget.Parent then
            PalletBlacklist[Survivor.lastPalletTarget] = now
            log("[PALLET] blacklisted (gagal) "..Survivor.lastPalletTarget:GetFullName())
        end
        Survivor.lastPalletAttempt = nil
        Survivor.lastPalletTarget = nil
    end

    if Survivor.State == "EvadingKiller" then
        log("Survivor: evade done → re-evaluate")
        endHoldAction(); releaseShift(); endShiftInteract()
        cancelGoal(); resetFlee(); resetEvade("evade-done")
        resetRepairCancel()
        Survivor.targetGen = nil; Survivor.approachPos = nil
        Survivor.lastGenScan = 0; Survivor.lastSwitchT = 0
        Survivor.lastLoggedGen = nil; Survivor.forceRescan = true
        setSurvivorState("SearchingGenerator", now)
    end

    -- RESCUE (hook)
    do
        local rt, rd = findHookedTarget()
        if rt then
            -- [F4] Cek failure cache
            local failAt = Survivor.failedRescues[rt.player]
            local blocked = failAt and (now - failAt) < CONFIG.RESCUE_RETRY_GAP
            if not blocked then
                local kDist = killerRoot and (rt.root.Position - killerRoot.Position).Magnitude or math.huge
                if kDist > CONFIG.RESCUE_SAFE_DIST then
                    setSurvivorState("RescuingSurvivor", now, string.format("(d=%.1f)", rd))
                    Survivor.currentRescueTarget = rt.player
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
                end
            end
        end
    end

    -- [F4] Verifikasi rescue: kalau unhook tidak menghasilkan apa-apa selama 2 detik,
    -- blacklist target sementara
    if Survivor.currentRescueTarget then
        if ActionState.current == "unhook" and ActionState.phase == "starting" then
            if (now - ActionState.startedAt) > 2.0 then
                Survivor.failedRescues[Survivor.currentRescueTarget] = now
                log("[RESCUE] unhook gagal → blacklist target 5s")
                Survivor.currentRescueTarget = nil
                requestStopAction()
            end
        elseif ActionState.current ~= "unhook" then
            -- Unhook sukses atau idle → clear
            if getSurvivorState(Survivor.currentRescueTarget) ~= "hooked" then
                dlog("[RESCUE] target sudah tidak hooked")
            end
            Survivor.currentRescueTarget = nil
        end
    end

    -- HEAL
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

    -- GENERATOR
    if Survivor.State == "AllDone" then
        if now - Survivor.lastGenScan > 3 then
            Survivor.lastGenScan = now
            if findBestGenerator(root, nil) then
                Survivor.State = "SearchingGenerator"
                Survivor.lastLoggedGen = nil
            end
        end
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
        log(string.format("Survivor: gen %s progress=%.1f → done", gen:GetFullName(), prog))
        setSurvivorState("SearchingGenerator", now)
        cancelGoal(); endHoldAction(); endShiftInteract()
        return
    end

    local ap = Survivor.approachPos
    local validAp = select(1, genBestAvailablePoint(gen, root))
    if not validAp then
        log("Survivor: no available slot → re-evaluate")
        Survivor.targetGen = nil; Survivor.approachPos = nil
        setSurvivorState("SearchingGenerator", now)
        endHoldAction(); endShiftInteract(); notifyRepairEnded(); cancelGoal()
        return
    end
    if (not ap) or (not isApproachPointAvailable(gen, ap))
        or ((validAp - ap).Magnitude > 3.0) then
        if ap and (not isApproachPointAvailable(gen, ap)) then
            log("Survivor: approach point taken → switch slot")
        end
        ap = validAp
        Survivor.approachPos = ap
    else
        ap = Survivor.approachPos
    end

    local d = (root.Position - ap).Magnitude
    if d <= CONFIG.SURV_GEN_ACTION_R then
        if not isApproachPointAvailable(gen, ap) then
            log("Survivor: arrival slot occupied → re-evaluate")
            Survivor.targetGen = nil; Survivor.approachPos = nil
            setSurvivorState("SearchingGenerator", now)
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
            log("Survivor: repair start attempt "..gen:GetFullName())
        end

        hum:Move(Vector3.zero, false)

        if ActionState.current == "repair" then
            Survivor.repairWaitStart = now
        elseif ActionState.current == nil and now >= ActionState.cooldownUntil then
            local pt = findNearestGeneratorPoint(gen, ap)
            if startAction("repair", gen, pt) then
                dlog("repair started method=%s gen=%s",
                    tostring(ActionState.interactMethod),
                    gen:GetFullName())
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
            endHoldAction(); endShiftInteract(); notifyRepairEnded(); cancelGoal()
            return
        end

        if ActionState.current ~= "repair"
            and now - Survivor.repairWaitStart > CONFIG.REPAIR_GIVEUP_TIME then
            log("Survivor: repair can't start ("..tostring(ActionState.phase)..") → abandon gen")
            Survivor.failedGens[gen] = now
            Survivor.targetGen = nil; Survivor.approachPos = nil
            setSurvivorState("SearchingGenerator", now)
            endHoldAction(); endShiftInteract(); notifyRepairEnded(); cancelGoal()
            return
        end
    else
        setSurvivorState("MovingToGenerator", now, string.format("(d=%.1f)", d))
        if ActionState.current == "repair" then requestStopAction() end
        if now - (Survivor.lastSlotCheck or 0) > CONFIG.GEN_SLOT_RECHECK then
            Survivor.lastSlotCheck = now
            if not isApproachPointAvailable(gen, ap) then
                log("Survivor: slot filled mid-travel → re-evaluate")
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
    clearPathViz()
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
    if readyGui then
        pcall(function() readyGui:Destroy() end)
        readyGui = nil
    end
    readyLabel = nil
    local pg = localPlayer:FindFirstChild("PlayerGui")
    if not pg then return false end
    readyGui = Instance.new("ScreenGui")
    readyGui.Name = "KemiAI_Ready"
    readyGui.ResetOnSpawn = false
    readyGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    readyGui.IgnoreGuiInset = true
    readyGui.Enabled = true
    readyGui.DisplayOrder = 1000
    readyGui.Parent = pg
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
    readyLabel.Visible = true
    readyLabel.Parent = readyGui
    return true
end

local function bindGuiWatch()
    if guiWatchConn then
        pcall(function() guiWatchConn:Disconnect() end)
        guiWatchConn = nil
    end
    local pg = localPlayer:FindFirstChild("PlayerGui")
    if not pg then return end
    guiWatchConn = pg.ChildRemoved:Connect(function(child)
        if child == readyGui then
            log("GUI removed by game → recreate")
            task.defer(function()
                if readyGui and not readyGui.Parent then
                    if createReadyGui() then bindGuiWatch() end
                end
            end)
        end
    end)
end

local function ensureGuiAlive()
    local pg = localPlayer:FindFirstChild("PlayerGui")
    if not pg then return end
    local needsRecreate = true
    if readyGui
        and readyGui.Parent == pg
        and readyGui.Enabled == true
        and readyLabel
        and readyLabel.Parent == readyGui
        and readyLabel.Visible == true then
        needsRecreate = false
    end
    if needsRecreate then
        guiRecreateCount = guiRecreateCount + 1
        local now = tick()
        if now - lastGuiRecreateLog > 1 then
            lastGuiRecreateLog = now
            log(string.format("GUI recreate (#%d)", guiRecreateCount))
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
local lastVizUpdate = 0

local function onRoleChange(old, new)
    log(string.format("Role: %s → %s", tostring(old), tostring(new)))
    survivorReset(); killerReset(); resetThreat()
    ActionState.current = nil
    ActionState.phase = "idle"
    ActionState.targetPoint = nil
    ActionState.cooldownUntil = 0
    ActionState.shiftActive = false
    ExitManager.detected = false; ExitManager.leverGoal = nil; ExitManager.exitLever = nil
    ExitManager.gateOpen = false; ExitManager.finishline = nil
    resetGameEnd()
    resetEvade("role-change")
    resetRepairCancel()
    if new == "Spectator" then
        endHoldAction(); endShiftInteract(); releaseShift(); cancelGoal()
    end
    clearPathViz()
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
                local ev = (Evade.phase ~= "idle") and ("/evade:"..Evade.phase) or ""
                extra = string.format(" [%s%s%s]",
                    Survivor.State,
                    ActionState.current and ("/"..ActionState.current) or "",
                    ev)
            elseif role == "Killer" then
                extra = string.format(" [%s]", Killer.State)
            end
            readyLabel.Text = "AI ready ["..tostring(role).."]"..extra
        end

        -- [F6] Path ESP update throttled
        if now - lastVizUpdate > 0.12 then
            lastVizUpdate = now
            if CONFIG.DEBUG_NAV then
                updatePathViz()
            elseif PathViz.folder and #PathViz.folder:GetChildren() > 0 then
                clearPathViz()
            end
        end

        local hum = getHumanoid()
        if not hum or hum.Health <= 0 then
            notifyRepairEnded(); releaseShift(); endHoldAction(); endShiftInteract(); cancelGoal()
            return
        end

        local char = getChar()
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
    ActionState.current = nil
    ActionState.phase = "idle"
    ActionState.targetPoint = nil
    ActionState.cooldownUntil = 0
    ActionState.shiftActive = false
    resetGameEnd()
    resetEvade("character-added")
    resetRepairCancel()
    notifyRepairEnded(); endHoldAction(); endShiftInteract()
    clearPathViz()
    ensureGuiAlive()
end)

localPlayer.CharacterRemoving:Connect(function()
    notifyRepairEnded(); releaseShift(); endHoldAction(); endShiftInteract(); cancelGoal()
    resetEvade("character-removing")
    resetRepairCancel()
    ActionState.current = nil
    ActionState.phase = "idle"
    ActionState.targetPoint = nil
    ActionState.cooldownUntil = 0
    ActionState.shiftActive = false
    clearPathViz()
end)

-- ============================================================================
-- KILL SWITCH
-- ============================================================================
_G.KemiAI_Stop = function()
    if roleWatcherConnection then roleWatcherConnection:Disconnect(); roleWatcherConnection = nil end
    if guiWatchConn then pcall(function() guiWatchConn:Disconnect() end); guiWatchConn = nil end
    notifyRepairEnded(); releaseShift(); endHoldAction(); endShiftInteract(); cancelGoal()
    resetThreat(); resetFlee(); resetPerception(); resetEvade("kill-switch")
    resetRepairCancel()
    ActionState.current = nil
    ActionState.phase = "idle"
    ActionState.targetPoint = nil
    ActionState.cooldownUntil = 0
    ActionState.shiftActive = false
    clearPathViz()
    if readyGui then pcall(function() readyGui:Destroy() end); readyGui=nil; readyLabel=nil end
    log("Stopped")
end

log("AI ready — R19 (GUI interact + safe juke + pallet fix + rescue robust + repair-cancel verified + path ESP)")
