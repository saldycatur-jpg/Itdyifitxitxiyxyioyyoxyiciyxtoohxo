-- ============================================================================
-- KEMI // PLAY AI — R15.1 (Incremental Upgrade)
--
--   Changelog R15.1 (incremental — semua fitur R15 dipertahankan):
--     [U1] cancelGeneratorInteraction(): pembatalan terverifikasi via
--          ReplicatedStorage/Remotes/Generator/Skillcheckvalidated (tipe
--          diperiksa; parameter dikirim sesuai tipe; tidak spam; cooldown;
--          log alasan; tunggu isRepairing=false dgn timeout).
--     [U2] Handing-state: bila isRepairing true tapi progres berhenti atau
--          killer >50 studs, lanjutkan; jika killer <50 → cancelGenerator
--          Interaction lalu evakuasi (tidak menunggu timeout normal).
--     [U3] ChaseStateMachine: DetectThreat, Escape, ApproachVault, Vault,
--          ApproachPallet, DropPallet, Juke, Recover, ResumeObjective.
--          Setiap state punya enter/exit/timeout/fallback.
--     [U4] Window validation: nama window dekoratif (window-c, window-b,
--          window-ab) ditolak. Vault hanya lewat GUI action + verifikasi
--          isVaulting. Pallet: verifikasi isDroppingPallet.
--     [U5] Fence_W4_Material_0: deteksi via nama, tidak menembus collision,
--          navigasi alternate waypoint + raycast lookahead.
--     [U6] Endgame: deteksi Exitpoint / exitPoint di Exit/ExitLever/Main,
--          mode Endgame mengalahkan semua objektif. Lever hold terverifikasi.
--     [U7] Dua gate → dua Fininshline: mapping struktural (LeverGoal anak
--          gate, Fininshline di parent sama). Tidak menebak via nama.
--     [U8] Prioritas global: ENDGAME > EVASION > RESCUE/HEAL > OBJECTIVE.
--     [U9] Observability: state transitions, cancellation reasons, gate
--          status, fininshline choice — semuanya via log dengan cooldown.
--     [U10] Server sebagai source of truth: atribut lokal tidak dipalsukan.
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

    TAP_ID  = 8822,
    HOLD_ID = 8823,

    -- [R15] Action state machine timings
    ACTION_START_TIMEOUT    = 1.5,
    ACTION_START_RETRIES    = 2,
    ACTION_STOP_VERIFY      = 1.0,
    ACTION_STOP_FORCE_CLEAR = 3.0,
    ACTION_FAIL_COOLDOWN    = 1.5,
    ACTION_BUSY_COOLDOWN    = 0.3,
    REPAIR_GIVEUP_TIME      = 3.0,
    REPAIR_PROGRESS_WATCH   = 3.0,

    -- [R15] Chase
    CHASE_VAULT_RANGE       = 12,
    CHASE_VAULT_COMMIT      = 8,
    CHASE_PALLET_RANGE      = 10,
    CHASE_PALLET_COMMIT     = 7,
    CHASE_SCAN_INTERVAL     = 3.0,

    -- [R15.1] NEW — Cancel interaction
    CANCEL_REASON_COOLDOWN  = 2.0,   -- min jarak antar log alasan sama
    CANCEL_VERIFY_TIMEOUT   = 1.5,   -- tunggu isRepairing=false setelah cancel
    CANCEL_RETRY_LIMIT      = 2,     -- retry cancel sebelum fallback
    HANDING_KILLER_NEAR     = 50,    -- ambang "handing waspada"

    -- [R15.1] NEW — Chase state machine
    CHASE_STUCK_TIMEOUT     = 4.0,
    JUKE_MIN_KILLER_DIST    = 6,
    JUKE_MAX_KILLER_DIST    = 12,
    JUKE_DURATION           = 0.6,
    JUKE_COOLDOWN           = 2.5,

    -- [R15.1] NEW — Fence
    FENCE_NAME_PATTERN      = "Fence_W4_Material_0",
    FENCE_LOOKAHEAD         = 6.0,
    FENCE_AVOID_RADIUS      = 5.0,

    -- [R15.1] NEW — Endgame
    ENDGAME_SCAN_INTERVAL   = 1.0,
    ENDGAME_LEVER_RANGE     = 6.0,
    ENDGAME_HOLD_TIMEOUT    = 6.0,
    ENDGAME_FINISH_RANGE    = 5.0,

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

-- [R15.1] Log throttling helper
local _logThrottle = {}
local function tlog(key, interval, fmt, ...)
    local now = tick()
    local last = _logThrottle[key] or 0
    if now - last >= interval then
        _logThrottle[key] = now
        log(string.format(fmt, ...))
    end
end

-- ============================================================================
-- [R15] ACTION DEFINITIONS & STATE
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
    -- [R15.1] lever hold untuk endgame
    leverHold    = { attr = "isExiting",         hold = true,  timeout = 2.0, cooldown = 0.5 },
}

local ACTION_BY_STATE = {
    RepairingGenerator = "repair",
    HealingSurvivor    = "heal",
    RescuingSurvivor   = "unhook",
    SelfHealing        = "selfHeal",
}

local ActionState = {
    current = nil, phase = "idle",
    target = nil, attributeName = nil, isHold = false,
    startedAt = 0, retryCount = 0,
    stopStartedAt = 0, cooldownUntil = 0,
    fallbackApplied = false,
    cancelReason = nil,
}

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
-- [R15.1] GENERATOR CANCEL — verifikasi server-side
-- ============================================================================
-- Remote kandidat untuk pembatalan interaksi generator.
-- Tidak di-hardcode diasumsikan "cancel"; tipe diperiksa saat runtime.
local CancelRemote = { instance = nil, checkedAt = 0, lastCallAt = 0, lastReason = nil }

local function getCancelRemote()
    local now = tick()
    if CancelRemote.instance and CancelRemote.instance.Parent then return CancelRemote.instance end
    if now - CancelRemote.checkedAt < 2.0 then return CancelRemote.instance end
    CancelRemote.checkedAt = now

    local remotesRoot = ReplicatedStorage:FindFirstChild("Remotes")
    if not remotesRoot then return nil end
    local genFolder = remotesRoot:FindFirstChild("Generator")
    if not genFolder then return nil end

    -- Prioritas nama yang secara semantik berarti "batal / validasi skillcheck".
    local candidates = {
        "Skillcheckvalidated", "SkillcheckValidated", "SkillcheckValid",
        "CancelRepair", "CancelGenerator", "RepairCancel", "StopRepair",
    }
    for _, name in ipairs(candidates) do
        local inst = genFolder:FindFirstChild(name)
        if inst and (inst:IsA("RemoteEvent") or inst:IsA("RemoteFunction")) then
            CancelRemote.instance = inst
            log(string.format("Cancel remote found: %s (%s)", inst:GetFullName(), inst.ClassName))
            return inst
        end
    end

    -- Fallback: scan children dengan kata kunci.
    for _, ch in ipairs(genFolder:GetChildren()) do
        local l = ch.Name:lower()
        if (l:find("cancel") or l:find("stop") or l:find("valid"))
            and (ch:IsA("RemoteEvent") or ch:IsA("RemoteFunction")) then
            CancelRemote.instance = ch
            log(string.format("Cancel remote (fallback): %s", ch:GetFullName()))
            return ch
        end
    end
    return nil
end

-- Idempoten. Return: (confirmed, reason)
local function cancelGeneratorInteraction(reason)
    reason = reason or "unspecified"
    local now = tick()

    -- Cooldown — hindari spam.
    if now - CancelRemote.lastCallAt < 0.5 then
        return false, "cooldown"
    end

    local char = getChar()
    if not char then return false, "no-char" end

    -- Kalau server sudah menyatakan false → tidak perlu cancel.
    if char:GetAttribute("isRepairing") == false then
        return true, "already-false"
    end

    local rem = getCancelRemote()
    if not rem then
        tlog("cancel-no-remote", CONFIG.CANCEL_REASON_COOLDOWN,
            "cancelGeneratorInteraction: remote tidak ditemukan (%s)", reason)
        return false, "no-remote"
    end

    CancelRemote.lastCallAt = now
    CancelRemote.lastReason = reason
    log(string.format("cancelGeneratorInteraction: alasan=%s remote=%s",
        reason, rem.Name))

    -- Kirim sesuai tipe. Jika RemoteFunction → pcall:InvokeServer().
    -- Jika RemoteEvent → FireServer tanpa argumen kecuali ada bukti parameter
    -- tambahan. Jangan mengarang parameter.
    local ok = pcall(function()
        if rem:IsA("RemoteFunction") then
            rem:InvokeServer()
        elseif rem:IsA("RemoteEvent") then
            rem:FireServer()
        end
    end)
    if not ok then
        log("cancel remote call error")
        return false, "call-error"
    end

    -- Verifikasi: tunggu isRepairing menjadi false (timeout).
    local deadline = now + CONFIG.CANCEL_VERIFY_TIMEOUT
    while tick() < deadline do
        task.wait(0.05)
        local c = getChar()
        if not c then return false, "char-lost" end
        if c:GetAttribute("isRepairing") == false then
            log(string.format("cancelGeneratorInteraction: terkonfirmasi (%s)", reason))
            return true, "confirmed"
        end
    end
    tlog("cancel-timeout", CONFIG.CANCEL_REASON_COOLDOWN,
        "cancelGeneratorInteraction: timeout verifikasi (%s)", reason)
    return false, "timeout"
end

-- Helper: paksa lepas input hold + bersihkan action state setelah cancel.
local function releaseInteractionAfterCancel()
    endHoldAction()
    -- Jangan set atribut lokal — hanya bersihkan state internal.
    if ActionState.current == "repair" then
        ActionState.current = nil
        ActionState.phase = "idle"
        ActionState.cooldownUntil = tick() + CONFIG.ACTION_BUSY_COOLDOWN
        ActionState.cancelReason = "cancel-generator"
    end
    notifyRepairEnded()
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
-- SURVIVOR STATE DETECTION
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
-- [R15] ACTION STATE MACHINE
-- ============================================================================
local requestStopAction

local function startAction(actionName, target)
    local def = ACTION_DEFS[actionName]
    if not def then return false end
    local now = tick()

    if ActionState.current == actionName
        and (ActionState.phase == "starting" or ActionState.phase == "active") then
        return true
    end

    if ActionState.current and ActionState.phase == "stopping" then
        return false
    end

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
        ActionState.startedAt = now
        ActionState.retryCount = 0
        return true
    end

    local triggered
    if def.hold then
        triggered = beginHoldAction()
    else
        triggered = TriggerMobileButton(CONFIG.TAP_ID)
    end
    if not triggered then
        ActionState.cooldownUntil = now + 1.0
        return false
    end

    ActionState.current = actionName
    ActionState.phase = "starting"
    ActionState.target = target
    ActionState.attributeName = def.attr
    ActionState.isHold = def.hold
    ActionState.startedAt = now
    ActionState.retryCount = 0
    ActionState.fallbackApplied = false
    ActionState.cancelReason = nil
    return true
end

function requestStopAction()
    if not ActionState.current then return end
    if ActionState.phase == "stopping" then return end
    ActionState.phase = "stopping"
    ActionState.stopStartedAt = tick()
    ActionState.fallbackApplied = false
    endHoldAction()
end

local function updateActionState(now, char)
    if not ActionState.current then return end
    local def = ACTION_DEFS[ActionState.current]
    if not def then
        ActionState.current = nil; ActionState.phase = "idle"; return
    end

    local attrVal = def.attr and char and char:GetAttribute(def.attr) == true

    if ActionState.phase == "starting" then
        if attrVal then
            ActionState.phase = "active"
            ActionState.retryCount = 0
        elseif now - ActionState.startedAt > def.timeout then
            if def.soft then
                ActionState.phase = "active"
            elseif ActionState.retryCount < CONFIG.ACTION_START_RETRIES then
                ActionState.retryCount = ActionState.retryCount + 1
                if def.hold then
                    endHoldAction()
                    if beginHoldAction() then
                        ActionState.startedAt = now
                    else
                        ActionState.current = nil
                        ActionState.phase = "idle"
                        ActionState.cooldownUntil = now + CONFIG.ACTION_FAIL_COOLDOWN
                    end
                else
                    if TriggerMobileButton(CONFIG.TAP_ID) then
                        ActionState.startedAt = now
                    else
                        ActionState.current = nil
                        ActionState.phase = "idle"
                        ActionState.cooldownUntil = now + CONFIG.ACTION_FAIL_COOLDOWN
                    end
                end
            else
                log(string.format("Action %s failed (no attr)", ActionState.current))
                endHoldAction()
                ActionState.current = nil
                ActionState.phase = "idle"
                ActionState.cooldownUntil = now + CONFIG.ACTION_FAIL_COOLDOWN
            end
        end

    elseif ActionState.phase == "active" then
        if not attrVal and not def.soft then
            log(string.format("Action %s ended", ActionState.current))
            ActionState.current = nil
            ActionState.phase = "idle"
            ActionState.cooldownUntil = now + def.cooldown
        end

    elseif ActionState.phase == "stopping" then
        if not attrVal then
            ActionState.current = nil
            ActionState.phase = "idle"
            ActionState.cooldownUntil = now + CONFIG.ACTION_BUSY_COOLDOWN
        elseif now - ActionState.stopStartedAt > CONFIG.ACTION_STOP_VERIFY then
            if not ActionState.fallbackApplied then
                ActionState.fallbackApplied = true
                local root = getRoot()
                local hum = getHumanoid()
                if root and hum then
                    local dir = Vector3.new(math.random()-0.5, 0, math.random()-0.5)
                    if dir.Magnitude < 0.1 then dir = Vector3.new(1,0,0) end
                    hum:MoveTo(root.Position + dir.Unit * 6)
                    log(string.format("Action %s stop timeout → fallback move", ActionState.current))
                end
            end
            if now - ActionState.stopStartedAt > CONFIG.ACTION_STOP_FORCE_CLEAR then
                log(string.format("Action %s force-clear", ActionState.current))
                ActionState.current = nil
                ActionState.phase = "idle"
                ActionState.cooldownUntil = now + 1.0
            end
        end
    end
end

-- ============================================================================
-- [R15] OPTIONAL REMOTE BINDING
-- ============================================================================
local CommonRemotes = { bound = false, conns = {} }

local function bindCommonRemotes()
    if CommonRemotes.bound then return end
    CommonRemotes.bound = true
    local remotesRoot = ReplicatedStorage:FindFirstChild("Remotes")
    if not remotesRoot then return end

    local function tryListen(name, cb)
        local ok, r = pcall(function() return remotesRoot:FindFirstChild(name, true) end)
        if ok and r and r:IsA("RemoteEvent") then
            local c = r.OnClientEvent:Connect(function(...)
                pcall(cb, ...)
            end)
            table.insert(CommonRemotes.conns, c)
        end
    end

    tryListen("RepairAnim", function() end)
    tryListen("HealAnim",   function() end)
    tryListen("VaultEvent", function() end)
    tryListen("PalletSlideEvent", function() end)
    tryListen("PalletDropEvent",  function() end)
    tryListen("HookPhase",  function() end)
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
-- [R15.1] FENCE HAZARD — Fence_W4_Material_0
-- ============================================================================
-- Cache: nama → instance. Digunakan untuk raycast lookahead terhadap pagar
-- yang tidak akurat di navmesh.
local FenceCache = { list = {}, lastScan = 0 }

local function isFenceCandidate(obj)
    if not obj or not obj:IsA("BasePart") then return false end
    local pattern = CONFIG.FENCE_NAME_PATTERN
    return obj.Name == pattern or obj.Name:find(pattern) ~= nil
end

local function scanFences(force)
    local now = tick()
    if not force and now - FenceCache.lastScan < 5.0 then return FenceCache.list end
    FenceCache.lastScan = now
    FenceCache.list = {}
    local function scan(node, depth)
        if depth > 5 or not node then return end
        for _, ch in ipairs(node:GetChildren()) do
            if isFenceCandidate(ch) then
                table.insert(FenceCache.list, ch)
            elseif ch:IsA("Folder") or ch:IsA("Model") then
                scan(ch, depth+1)
            end
        end
    end
    scan(workspace, 0)
    if #FenceCache.list > 0 then
        nlog("Fence candidates found: %d", #FenceCache.list)
    end
    return FenceCache.list
end

-- Return: true jika raycast mengenai fence dalam lookahead.
local function fenceBlockedAhead(fromPos, toPos)
    if not fromPos or not toPos then return false end
    local fences = scanFences()
    if #fences == 0 then return false end
    local delta = toPos - fromPos
    local mag = delta.Magnitude
    if mag < 0.1 then return false end
    local dir = delta.Unit
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = { getChar() }
    local hit = workspace:Raycast(fromPos, dir * math.min(mag, CONFIG.FENCE_LOOKAHEAD), params)
    if not hit then return false end
    for _, f in ipairs(fences) do
        if hit.Instance == f or hit.Instance:IsDescendantOf(f) then
            return true
        end
    end
    return false
end

-- Cari waypoint alternatif di sekitar tujuan bila fence menghalangi.
local function findFenceAvoidWaypoint(fromPos, toPos, rootPos)
    local delta = (toPos - fromPos)
    if delta.Magnitude < 0.5 then return toPos end
    local perp = Vector3.new(-delta.Z, 0, delta.X)
    if perp.Magnitude < 0.1 then perp = Vector3.new(1,0,0) end
    perp = perp.Unit
    local dist = math.min(delta.Magnitude, CONFIG.FENCE_AVOID_RADIUS * 2)
    local candidates = {
        fromPos + perp * dist,
        fromPos - perp * dist,
        fromPos + (perp * dist + delta.Unit * dist * 0.5),
        fromPos - (perp * dist - delta.Unit * dist * 0.5),
    }
    for _, c in ipairs(candidates) do
        if not fenceBlockedAhead(fromPos, c) then
            return c
        end
    end
    return toPos -- fallback: tetap ke tujuan asli; stuck-detector akan retry
end

-- ============================================================================
-- PATHFOLLOWER
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
    -- [R15.1]
    fenceAvoidPending = nil,
    fenceAvoidCooldown = 0,
}

local function initPath()
    if PathFollower.path then return end
    PathFollower.path = PathfindingService:CreatePath({
        AgentRadius = 2, AgentHeight = 5,
        AgentCanJump = true, AgentMaxSlope = 50,
        WaypointSpacing = 3,
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
    PathFollower.fenceAvoidPending = nil
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
        nlog("setGoal reason=%s pos=%s", tagChanged and "tag" or "pos",
            tostring(pos))
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

local function followStep()
    local root = getRoot()
    local hum = getHumanoid()
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
                    log("Path: stuck >2s → jump + recompute")
                end
                pcall(function() hum.Jump = true end)
                PathFollower.goalPos = nil
                PathFollower.stuckSince = 0
                PathFollower.index = 1
                -- [R15.1] paksa repath dari posisi sekarang
                if PathFollower.pendingPos == nil then
                    PathFollower.pendingPos = PathFollower.goalPos
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

    -- [R15.1] Lookahead fence avoidance.
    if now > PathFollower.fenceAvoidCooldown then
        if fenceBlockedAhead(root.Position, wp.Position) then
            local alt = findFenceAvoidWaypoint(root.Position, wp.Position, root.Position)
            if alt and (alt - wp.Position).Magnitude > 0.5 then
                nlog("fence avoid: %s → %s", tostring(wp.Position), tostring(alt))
                hum:MoveTo(alt)
                PathFollower.fenceAvoidCooldown = now + 0.4
                return true
            end
        end
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
-- tryPath
-- ============================================================================
local PathMemo = {}
local function tryPath(fromPos, endPos)
    local k = tostring(fromPos).."→"..tostring(endPos)
    local cached = PathMemo[k]
    if cached and (tick() - cached.t) < CONFIG.PATH_CACHE_TTL then return cached.ok end
    local p = PathfindingService:CreatePath({
        AgentRadius = 2, AgentHeight = 5, AgentCanJump = true,
        AgentMaxSlope = 50, WaypointSpacing = 3,
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

-- ============================================================================
-- GENERATOR POINT / SLOT AWARENESS
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
        return genApproachPoint(gen), nil
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
        log(string.format("Flee: emergency away d=%.1f", dK))
        return tgt
    end

    local safeGen, safePos = pickSafeFleeGenerator(myPos, killerPos, Survivor.targetGen)
    if safeGen and safePos then
        FLEE.target=safePos; FLEE.lastPick=now; FLEE.lastGen=safeGen
        FLEE.commitTarget=safePos; FLEE.commitUntil = now + CONFIG.FLEE_COMMIT_TIME
        log(string.format("Flee: toward safe gen %s", safeGen:GetFullName()))
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
-- [R15.1] CHASE STATE MACHINE
-- ============================================================================
-- States:
--   DetectThreat     : mulai ancaman, observasi singkat
--   Escape           : jalankan pickFleeTarget + followStep (loop utama)
--   ApproachVault    : set goal menuju window valid
--   Vault            : jalankan aksi vault + verify
--   ApproachPallet   : set goal menuju pallet valid
--   DropPallet       : jalankan aksi drop pallet + verify
--   Juke             : manuver pendek (360 spin/backstep) dengan guard
--   Recover          : setelah vault/pallet selesai, putuskan lanjut escape
--   ResumeObjective  : keluar dari chase, kembali ke generator/rescue
local ChaseState = {
    state = "Idle",
    enteredAt = 0,
    timeout = 0,
    target = nil,
    reason = "",
    lastJukeAt = 0,
    lastVaultAt = 0,
    lastPalletAt = 0,
    vaultTarget = nil,
    palletTarget = nil,
}

local function chaseSetState(newState, reason)
    if ChaseState.state == newState then return end
    log(string.format("Chase: %s → %s %s", ChaseState.state, newState, reason or ""))
    ChaseState.state = newState
    ChaseState.enteredAt = tick()
    ChaseState.reason = reason or ""
    if newState == "Vault" then ChaseState.lastVaultAt = tick() end
    if newState == "DropPallet" then ChaseState.lastPalletAt = tick() end
    if newState == "Juke" then ChaseState.lastJukeAt = tick() end
end

local function chaseReset()
    ChaseState.state = "Idle"
    ChaseState.enteredAt = 0
    ChaseState.timeout = 0
    ChaseState.target = nil
    ChaseState.vaultTarget = nil
    ChaseState.palletTarget = nil
end

-- Window valid check: bukan nama dekoratif, ada, visible enough, ada action attr.
local DECORATIVE_WINDOW_NAMES = {
    ["window-c"] = true, ["window-b"] = true, ["window-ab"] = true,
    ["Window-c"] = true, ["Window-b"] = true, ["Window-ab"] = true,
}

local function isValidVaultWindow(w)
    if not w or not w.Parent then return false end
    local nm = w.Name
    if DECORATIVE_WINDOW_NAMES[nm] then return false end
    -- window harus nama persis "window" atau mengandung "VaultPoint"/"VaultZone"
    if nm == "window" or nm == "Window" then return true end
    if nm:find("VaultPoint") or nm:find("VaultZone") or nm:find("VaultWindow") then
        return true
    end
    return false
end

local ObstacleCache = { windows = {}, pallets = {}, lastScan = 0 }

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
                local nm = ch.Name
                if isValidVaultWindow(ch) then
                    table.insert(ObstacleCache.windows, ch)
                elseif nm:match("^Pallet") or nm:find("PalletPoint") then
                    table.insert(ObstacleCache.pallets, ch)
                end
            elseif ch:IsA("Folder") or ch:IsA("Model") then
                scan(ch, depth+1)
            end
        end
    end
    scan(workspace, 0)
end

local function findChaseVaultWindow(myRoot, killerRoot, maxDist)
    if not myRoot or not killerRoot then return nil end
    scanObstacles()
    maxDist = maxDist or CONFIG.CHASE_VAULT_RANGE
    local myPos = myRoot.Position
    local killerPos = killerRoot.Position
    local best, bestD = nil, maxDist
    for _,w in ipairs(ObstacleCache.windows) do
        if w.Parent and isValidVaultWindow(w) then
            local d = (myPos - w.Position).Magnitude
            if d < bestD then
                local dKW = (killerPos - w.Position).Magnitude
                local dKM = (killerPos - myPos).Magnitude
                if dKW > dKM - 3 then
                    if hasClearLine(myPos, w.Position) then
                        bestD = d
                        best = w
                    end
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
                    if dot > 0.5 then
                        bestD = d
                        best = p
                    end
                end
            end
        end
    end
    return best
end

-- Juke guard: hanya jika killer sangat dekat, ada ruang, cooldown siap.
local function tryJuke(root, hum, killerRoot, kD)
    local now = tick()
    if now - ChaseState.lastJukeAt < CONFIG.JUKE_COOLDOWN then return false end
    if kD < CONFIG.JUKE_MIN_KILLER_DIST or kD > CONFIG.JUKE_MAX_KILLER_DIST then return false end
    -- Perlu ruang: raycast ke belakang harus clear.
    local backDir = -(root.CFrame.LookVector)
    local probePos = root.Position + backDir * 4
    if not hasClearLine(root.Position, probePos) then return false end
    chaseSetState("Juke", "killer d="..string.format("%.1f", kD))
    ChaseState.timeout = now + CONFIG.JUKE_DURATION
    -- Manuver: spin pendek + backstep.
    hum:Move(root.Position + backDir * 3)
    return true
end

-- Return: true jika chase selesai/menangani frame ini.
local function updateChase(now, root, hum, killerRoot, kD)
    if not killerRoot or kD > CONFIG.THREAT_EXIT_DIST then
        -- selesai
        chaseSetState("ResumeObjective", "killer away")
        return true
    end

    local s = ChaseState.state
    local since = now - ChaseState.enteredAt

    if s == "DetectThreat" then
        if since > 0.15 then
            chaseSetState("Escape", "init")
        end
        return true

    elseif s == "Escape" then
        -- Coba vault jika memungkinkan
        if kD < 40 and ActionState.current ~= "vault"
            and now - ChaseState.lastVaultAt > 1.5 then
            local vault = findChaseVaultWindow(root, killerRoot, CONFIG.CHASE_VAULT_RANGE)
            if vault and (root.Position - vault.Position).Magnitude < CONFIG.CHASE_VAULT_COMMIT then
                ChaseState.vaultTarget = vault
                chaseSetState("Vault", "window="..vault.Name)
                return true
            end
        end
        -- Coba pallet
        if kD < 30 and ActionState.current ~= "palletDrop"
            and now - ChaseState.lastPalletAt > 1.5 then
            local pallet = findPalletForDrop(root, killerRoot, CONFIG.CHASE_PALLET_RANGE)
            if pallet and (root.Position - pallet.Position).Magnitude < CONFIG.CHASE_PALLET_COMMIT then
                ChaseState.palletTarget = pallet
                chaseSetState("DropPallet", "pallet="..pallet.Name)
                return true
            end
        end
        -- Coba juke
        if tryJuke(root, hum, killerRoot, kD) then return true end
        -- Normal escape
        local fleeTarget = pickFleeTarget(root, killerRoot)
        holdShift()
        setGoal(fleeTarget, "flee")
        followStep()
        return true

    elseif s == "Vault" then
        local w = ChaseState.vaultTarget
        if not w or not w.Parent then
            chaseSetState("Escape", "vault target hilang")
            return true
        end
        -- Mulai aksi jika belum
        if ActionState.current ~= "vault" then
            if (root.Position - w.Position).Magnitude > CONFIG.CHASE_VAULT_COMMIT then
                chaseSetState("ApproachVault", "menuju window")
                return true
            end
            if not startAction("vault", w) then
                chaseSetState("Escape", "vault start gagal")
                return true
            end
        end
        -- Follow arah window saat vaulting
        hum:MoveTo(w.Position)
        holdShift()
        -- Selesai? attr false dan cukup waktu
        local char = getChar()
        if ActionState.phase == "idle"
            and (not char or char:GetAttribute("isVaulting") ~= true)
            and since > 0.5 then
            chaseSetState("Recover", "vault selesai")
        end
        return true

    elseif s == "ApproachVault" then
        local w = ChaseState.vaultTarget
        if not w or not w.Parent then
            chaseSetState("Escape", "approach vault target hilang")
            return true
        end
        holdShift()
        setGoal(w.Position, "vault-approach")
        followStep()
        if (root.Position - w.Position).Magnitude < CONFIG.CHASE_VAULT_COMMIT then
            chaseSetState("Vault", "reach window")
        end
        return true

    elseif s == "DropPallet" then
        local p = ChaseState.palletTarget
        if not p or not p.Parent then
            chaseSetState("Escape", "pallet target hilang")
            return true
        end
        if (root.Position - p.Position).Magnitude > CONFIG.CHASE_PALLET_COMMIT then
            chaseSetState("ApproachPallet", "menuju pallet")
            return true
        end
        hum:Move(Vector3.zero, false)
        if ActionState.current ~= "palletDrop" then
            if not startAction("palletDrop", p) then
                chaseSetState("Escape", "pallet start gagal")
                return true
            end
        end
        local char = getChar()
        if ActionState.phase == "idle"
            and (not char or char:GetAttribute("isDroppingPallet") ~= true)
            and since > 0.5 then
            chaseSetState("Recover", "pallet selesai")
        end
        return true

    elseif s == "ApproachPallet" then
        local p = ChaseState.palletTarget
        if not p or not p.Parent then
            chaseSetState("Escape", "approach pallet target hilang")
            return true
        end
        holdShift()
        setGoal(p.Position, "pallet-approach")
        followStep()
        if (root.Position - p.Position).Magnitude < CONFIG.CHASE_PALLET_COMMIT then
            chaseSetState("DropPallet", "reach pallet")
        end
        return true

    elseif s == "Juke" then
        if now > ChaseState.timeout then
            chaseSetState("Escape", "juke selesai")
        end
        return true

    elseif s == "Recover" then
        if since > 0.6 then
            chaseSetState("Escape", "recover selesai")
        end
        return true

    elseif s == "ResumeObjective" then
        return false
    end
    return true
end

-- ============================================================================
-- [R15.1] ENDGAME SYSTEM
-- ============================================================================
-- Deteksi penanda exit:
--   - Attribute "Exitpoint"/"exitPoint" pada part/object
--   - CollectionService tag "Exitpoint"/"exitPoint"
--   - Nama "Exitpoint"/"exitPoint"
-- Gate dianggap terbuka jika salah satu dari:
--   - Atribut gate "Opened"/"IsOpen"/"Open" bernilai true
--   - Anak LeverGoal sudah hilang / disabled (tidak bisa diinteraksikan)
-- Fininshline (perhatikan salah ketik nama proyek) dihubungkan ke gate jika:
--   - Berada di parent yang sama dengan gate
--   - Atau berada di folder/folder yang sama (heuristik struktural)
local Endgame = {
    active = false,
    state = "Inactive", -- Inactive | FindGate | GoToLever | HoldLever | GoToFinish | Done
    gate = nil,
    lever = nil,
    finish = nil,
    enteredAt = 0,
    lastScan = 0,
    holdStartedAt = 0,
    reason = "",
}

local function exitMarkersIn(obj)
    local out = {}
    if not obj then return out end
    local function check(inst)
        if not inst then return end
        local okA, v1 = pcall(function() return inst:GetAttribute("Exitpoint") end)
        local okB, v2 = pcall(function() return inst:GetAttribute("exitPoint") end)
        if (okA and v1 ~= nil and v1 ~= false) or (okB and v2 ~= nil and v2 ~= false) then
            table.insert(out, inst)
        end
        if CollectionService:HasTag(inst, "Exitpoint") or CollectionService:HasTag(inst, "exitPoint") then
            table.insert(out, inst)
        end
    end
    check(obj)
    for _, ch in ipairs(obj:GetDescendants()) do
        if ch:IsA("BasePart") then
            if ch.Name == "Exitpoint" or ch.Name == "exitPoint" or ch.Name:find("Exitpoint") then
                table.insert(out, ch)
            else
                check(ch)
            end
        end
    end
    return out
end

local function findExitFolders()
    local map = workspace:FindFirstChild("Map")
    local candidates = {}
    if map then
        local ex = map:FindFirstChild("Exit")
        if ex then
            local el = ex:FindFirstChild("ExitLever")
            if el then
                local m = el:FindFirstChild("Main")
                if m then table.insert(candidates, m) end
                table.insert(candidates, el)
            end
            table.insert(candidates, ex)
        end
    end
    return candidates
end

-- Kumpulkan gate + lever + finish yang saling berkaitan secara struktural.
local function mapGateLeverFinish()
    local mapping = {}
    local exitFolders = findExitFolders()
    for _, folder in ipairs(exitFolders) do
        -- scan langsung anak-anak: gate, LeverGoal, Fininshline
        local gates, levers, finishes = {}, {}, {}
        local function scan(node, depth)
            if depth > 3 or not node then return end
            for _, ch in ipairs(node:GetChildren()) do
                local nm = ch.Name
                if nm:find("Gate") and not nm:find("Lever") then
                    table.insert(gates, ch)
                elseif nm:find("LeverGoal") or nm == "LeverGoal" or nm:find("Lever") then
                    table.insert(levers, ch)
                elseif nm:find("Fininshline") or nm:find("Finishline") or nm:find("FinishLine") then
                    table.insert(finishes, ch)
                elseif ch:IsA("Folder") or ch:IsA("Model") then
                    scan(ch, depth+1)
                end
            end
        end
        scan(folder, 0)
        -- Bangun mapping dengan parent yang sama
        for _, gate in ipairs(gates) do
            local parent = gate.Parent
            local gateLevers = {}
            local gateFinishes = {}
            for _, lv in ipairs(levers) do
                if lv.Parent == parent
                    or (lv.Parent and lv.Parent.Parent == parent)
                    or (lv:FindFirstAncestor(gate.Name))
                    or (gate:FindFirstAncestor(lv.Parent and lv.Parent.Name or "")) then
                    table.insert(gateLevers, lv)
                end
            end
            for _, f in ipairs(finishes) do
                if f.Parent == parent
                    or (f.Parent and f.Parent.Parent == parent) then
                    table.insert(gateFinishes, f)
                end
            end
            if #gateLevers > 0 or #gateFinishes > 0 then
                table.insert(mapping, {
                    gate = gate,
                    levers = gateLevers,
                    finishes = gateFinishes,
                    hasExitMarker = (#exitMarkersIn(gate) > 0),
                })
            end
        end
    end
    return mapping
end

local function gateIsOpen(gate)
    if not gate or not gate.Parent then return false end
    for _, key in ipairs({"Opened","IsOpen","Open","Activated","Done"}) do
        local ok, v = pcall(function() return gate:GetAttribute(key) end)
        if ok and v == true then return true end
    end
    -- Fallback: tidak ada LeverGoal anak yang masih visible.
    local stillHasLever = false
    for _, ch in ipairs(gate:GetDescendants()) do
        if ch.Name:find("LeverGoal") then stillHasLever = true; break end
    end
    return not stillHasLever
end

local function updateEndgame(now, root, hum)
    -- Scan berkala
    if now - Endgame.lastScan < CONFIG.ENDGAME_SCAN_INTERVAL then
        return Endgame.active
    end
    Endgame.lastScan = now

    -- Cari marker exit — aktifkan Endgame jika ditemukan
    local exitMarkers = {}
    for _, folder in ipairs(findExitFolders()) do
        for _, m in ipairs(exitMarkersIn(folder)) do
            table.insert(exitMarkers, m)
        end
    end
    if #exitMarkers == 0 and not Endgame.active then
        return false
    end
    if #exitMarkers > 0 and not Endgame.active then
        Endgame.active = true
        Endgame.state = "FindGate"
        Endgame.enteredAt = now
        log(string.format("Endgame AKTIF — marker=%s", exitMarkers[1]:GetFullName()))
        -- stop semua objective
        cancelGoal(); endHoldAction(); releaseShift()
    end
    if not Endgame.active then return false end

    local mapping = mapGateLeverFinish()
    if #mapping == 0 then
        tlog("endgame-no-map", 3.0, "Endgame: mapping gate tidak ditemukan")
        return true
    end

    -- Pilih gate yang belum terbuka, prioritas terdekat
    local bestGate, bestDist = nil, math.huge
    for _, m in ipairs(mapping) do
        if not gateIsOpen(m.gate) then
            local gp = (m.gate:IsA("Model") and m.gate.PrimaryPart and m.gate.PrimaryPart.Position)
                or (m.gate:IsA("BasePart") and m.gate.Position)
            if not gp then
                local any = m.gate:FindFirstChildWhichIsA("BasePart", true)
                gp = any and any.Position
            end
            if gp then
                local d = (root.Position - gp).Magnitude
                if d < bestDist then bestDist = d; bestGate = m end
            end
        end
    end

    if Endgame.state == "FindGate" then
        if not bestGate then
            -- semua terbuka → cari finish
            Endgame.state = "GoToFinish"
            local finishes = {}
            for _, m in ipairs(mapping) do
                for _, f in ipairs(m.finishes) do
                    if gateIsOpen(m.gate) then
                        table.insert(finishes, f)
                    end
                end
            end
            -- Pilih finish terdekat
            local bestFinish, bestFD = nil, math.huge
            for _, f in ipairs(finishes) do
                local fp = (f:IsA("Model") and f.PrimaryPart and f.PrimaryPart.Position)
                    or (f:IsA("BasePart") and f.Position)
                if fp then
                    local d = (root.Position - fp).Magnitude
                    if d < bestFD then bestFD = d; bestFinish = f end
                end
            end
            Endgame.finish = bestFinish
            if bestFinish then
                log("Endgame: menuju Fininshline "..bestFinish:GetFullName())
            end
            return true
        end
        Endgame.gate = bestGate.gate
        Endgame.lever = bestGate.levers[1]
        Endgame.state = "GoToLever"
        Endgame.enteredAt = now
        log(string.format("Endgame: gate=%s lever=%s",
            bestGate.gate.Name,
            Endgame.lever and Endgame.lever.Name or "nil"))
        return true

    elseif Endgame.state == "GoToLever" then
        local lever = Endgame.lever
        if not lever or not lever.Parent then
            Endgame.state = "FindGate"; return true
        end
        local lp = (lever:IsA("Model") and lever.PrimaryPart and lever.PrimaryPart.Position)
            or (lever:IsA("BasePart") and lever.Position)
            or (function()
                local p = lever:FindFirstChildWhichIsA("BasePart", true)
                return p and p.Position
            end)()
        if not lp then Endgame.state = "FindGate"; return true end
        local d = (root.Position - lp).Magnitude
        if d <= CONFIG.ENDGAME_LEVER_RANGE then
            Endgame.state = "HoldLever"
            Endgame.holdStartedAt = now
            return true
        end
        holdShift()
        setGoal(lp, "endgame-lever")
        followStep()
        return true

    elseif Endgame.state == "HoldLever" then
        local lever = Endgame.lever
        local char = getChar()
        hum:Move(Vector3.zero, false)
        if not lever or not lever.Parent then
            Endgame.state = "GoToFinish"; return true
        end
        -- Tekan hold via GUI action (leverHold).
        if ActionState.current ~= "leverHold" then
            if not startAction("leverHold", lever) then
                -- retry berikut frame
            end
        end
        local verified = char and char:GetAttribute("isExiting") == true
        if verified then
            Endgame.holdStartedAt = now
        end
        -- Timeout: jika terlalu lama tidak terverifikasi, coba lepas & ulang
        if now - Endgame.holdStartedAt > CONFIG.ENDGAME_HOLD_TIMEOUT then
            tlog("endgame-hold-timeout", 2.0, "Endgame: lever hold timeout — cek gate")
            endHoldAction()
            if ActionState.current == "leverHold" then requestStopAction() end
            if gateIsOpen(Endgame.gate) then
                Endgame.state = "GoToFinish"
                log("Endgame: gate terbuka → GoToFinish")
            else
                Endgame.state = "GoToLever"
            end
        end
        return true

    elseif Endgame.state == "GoToFinish" then
        local finishes = {}
        for _, m in ipairs(mapping) do
            if gateIsOpen(m.gate) then
                for _, f in ipairs(m.finishes) do table.insert(finishes, f) end
            end
        end
        if #finishes == 0 then
            tlog("endgame-no-finish", 3.0, "Endgame: tidak ada Fininshline valid")
            return true
        end
        local bestFinish, bestFD = nil, math.huge
        for _, f in ipairs(finishes) do
            local fp = (f:IsA("Model") and f.PrimaryPart and f.PrimaryPart.Position)
                or (f:IsA("BasePart") and f.Position)
            if fp then
                local d = (root.Position - fp).Magnitude
                if d < bestFD then bestFD = d; bestFinish = f end
            end
        end
        if not bestFinish then return true end
        Endgame.finish = bestFinish
        local fp = (bestFinish:IsA("Model") and bestFinish.PrimaryPart and bestFinish.PrimaryPart.Position)
            or (bestFinish:IsA("BasePart") and bestFinish.Position)
        if not fp then return true end
        if (root.Position - fp).Magnitude <= CONFIG.ENDGAME_FINISH_RANGE then
            Endgame.state = "Done"
            log("Endgame: sampai di Fininshline "..bestFinish:GetFullName())
            hum:Move(Vector3.zero, false)
            return true
        end
        holdShift()
        setGoal(fp, "endgame-finish")
        followStep()
        return true
    end
    return false
end

-- ============================================================================
-- RESCUE / HEAL TARGETS
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
-- [R15.1] HANDING STATE (interaksi indikator masih aktif tapi progress stop)
-- ============================================================================
-- Aturan:
--   - Jika killer > HANDING_KILLER_NEAR (50): lanjutkan repair seperti biasa.
--   - Jika killer <= 50: cancelGeneratorInteraction + evakuasi.
local Handing = { lastCheckAt = 0, level = "none" }

local function updateHanding(now, char, killerRoot, kD)
    if not char then Handing.level = "none"; return end
    local isRepairing = char:GetAttribute("isRepairing") == true
    if not isRepairing then Handing.level = "none"; return end

    if now - Handing.lastCheckAt < 0.25 then return end
    Handing.lastCheckAt = now

    if not killerRoot then Handing.level = "safe"; return end
    if kD > CONFIG.HANDING_KILLER_NEAR then
        Handing.level = "safe"
    elseif kD <= CONFIG.HANDING_KILLER_NEAR and kD > 30 then
        Handing.level = "wary"
    else
        Handing.level = "danger"
    end
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
    cancelGoal(); resetFlee(); resetThreat(); resetPerception()
    notifyRepairEnded(); releaseShift(); endHoldAction()
    chaseReset()
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

-- [R15.1] Prioritas global: ENDGAME > EVASION > RESCUE/HEAL > OBJECTIVE
local function SurvivorAI(now)
    local hum = getHumanoid()
    local root = getRoot()
    if not hum or not root or hum.Health <= 0 then
        Survivor.State = "WaitingForCharacter"
        notifyRepairEnded(); releaseShift(); endHoldAction(); cancelGoal()
        chaseReset()
        return
    end

    local selfState = getSelfState()
    if selfState == "dead" then
        setSurvivorState("Dead", now)
        endHoldAction(); releaseShift(); cancelGoal(); chaseReset()
        return
    end
    if selfState == "hooked" then
        setSurvivorState("Hooked", now)
        endHoldAction(); releaseShift(); cancelGoal(); chaseReset()
        return
    end
    if selfState == "carried" then
        setSurvivorState("Carried", now)
        endHoldAction(); releaseShift(); cancelGoal(); chaseReset()
        return
    end
    if selfState == "knocked" then
        setSurvivorState("SelfHealing", now)
        releaseShift(); cancelGoal(); chaseReset()
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

    -- ============ [R15.1] PRIORITY 1: ENDGAME ============
    if updateEndgame(now, root, hum) then
        -- Endgame sedang aktif; hentikan semua state lain.
        if ActionState.current == "repair" or ActionState.current == "heal"
            or ActionState.current == "unhook" then
            if ActionState.phase ~= "stopping" then requestStopAction() end
        end
        setSurvivorState("Endgame", now, "("..Endgame.state..")")
        return
    end

    -- ============ PRIORITY 2: EVASION ============
    local killer, killerRoot, kD, threat, P = updateThreat(now)
    local char = getChar()
    updateHanding(now, char, killerRoot, kD)

    -- [R15.1] Cancel generator SAAT killer dekat, verifikasi server.
    if char and char:GetAttribute("isRepairing") == true and killerRoot
        and kD <= CONFIG.HANDING_KILLER_NEAR then
        log(string.format("Handing: killer d=%.1f ≤ %d → cancel interaksi",
            kD, CONFIG.HANDING_KILLER_NEAR))
        local confirmed, reason = cancelGeneratorInteraction(
            string.format("killer-close:%.1f", kD))
        if confirmed then
            releaseInteractionAfterCancel()
        else
            -- Server belum konfirmasi — state transisi sementara, jangan fake attr.
            log("Handing: cancel belum terkonfirmasi ("..tostring(reason)..")")
            endHoldAction()  -- lepas input hold tetap sah
        end
    end

    if threat and killerRoot then
        if ActionState.current and ActionState.current ~= "vault"
            and ActionState.current ~= "palletDrop"
            and ActionState.current ~= "palletSlide" then
            if ActionState.phase ~= "stopping" then
                requestStopAction()
            end
        end
        setSurvivorState("EvadingKiller", now, string.format("(d=%.1f P=%.2f)", kD, P or 0))

        -- [R15.1] Chase state machine.
        if ChaseState.state == "Idle" or ChaseState.state == "ResumeObjective" then
            chaseSetState("DetectThreat", "killer entered")
        end
        updateChase(now, root, hum, killerRoot, kD)
        return
    end

    -- Transisi keluar evade
    if Survivor.State == "EvadingKiller" then
        log("Survivor: evade done → re-evaluate generator from current position")
        endHoldAction(); releaseShift()
        cancelGoal(); resetFlee()
        chaseReset()
        Survivor.targetGen = nil
        Survivor.approachPos = nil
        Survivor.lastGenScan = 0
        Survivor.lastSwitchT = 0
        Survivor.lastLoggedGen = nil
        Survivor.forceRescan = true
        setSurvivorState("SearchingGenerator", now)
    end

    -- ============ PRIORITY 3: RESCUE ============
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

    -- ============ PRIORITY 3b: HEAL ============
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

    -- ============ PRIORITY 4: OBJECTIVE ============
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
        log(string.format("Survivor: gen %s progress=%.1f → done, re-evaluate",
            gen:GetFullName(), prog))
        setSurvivorState("SearchingGenerator", now)
        cancelGoal(); endHoldAction()
        return
    end

    local ap = Survivor.approachPos
    local validAp = select(1, genBestAvailablePoint(gen, root))
    if not validAp then
        log("Survivor: no available slot on current gen → re-evaluate")
        Survivor.targetGen = nil
        Survivor.approachPos = nil
        setSurvivorState("SearchingGenerator", now)
        endHoldAction(); notifyRepairEnded(); cancelGoal()
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
            Survivor.targetGen = nil
            Survivor.approachPos = nil
            setSurvivorState("SearchingGenerator", now)
            endHoldAction(); notifyRepairEnded(); cancelGoal()
            return
        end

        if Survivor.State ~= "RepairingGenerator" then
            setSurvivorState("RepairingGenerator", now)
            Survivor.lastProgress = getGenProgress(gen)
            Survivor.lastProgressT = now
            Survivor.repairWaitStart = now
            notifyRepairStarted()
            cancelGoal()
            log("Survivor: repair start attempt "..gen:GetFullName())
        end

        hum:Move(Vector3.zero, false)
        releaseShift()

        if ActionState.current == "repair" then
            Survivor.repairWaitStart = now
        elseif ActionState.current == nil and now >= ActionState.cooldownUntil then
            startAction("repair", gen)
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
            endHoldAction(); notifyRepairEnded(); cancelGoal()
            return
        end

        if ActionState.current ~= "repair"
            and now - Survivor.repairWaitStart > CONFIG.REPAIR_GIVEUP_TIME then
            log("Survivor: repair can't start ("..tostring(ActionState.phase)..") → abandon gen")
            Survivor.failedGens[gen] = now
            Survivor.targetGen = nil
            Survivor.approachPos = nil
            setSurvivorState("SearchingGenerator", now)
            endHoldAction(); notifyRepairEnded(); cancelGoal()
            return
        end
    else
        setSurvivorState("MovingToGenerator", now, string.format("(d=%.1f)", d))
        if ActionState.current == "repair" then requestStopAction() end
        if now - (Survivor.lastSlotCheck or 0) > CONFIG.GEN_SLOT_RECHECK then
            Survivor.lastSlotCheck = now
            if not isApproachPointAvailable(gen, ap) then
                log("Survivor: slot filled mid-travel → re-evaluate")
                Survivor.targetGen = nil
                Survivor.approachPos = nil
                setSurvivorState("SearchingGenerator", now)
                endHoldAction(); notifyRepairEnded(); cancelGoal()
                return
            end
        end
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
    readyLabel.Size = UDim2.new(0,720,0,18)
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
    ActionState.current = nil
    ActionState.phase = "idle"
    ActionState.cooldownUntil = 0
    Endgame.active = false
    Endgame.state = "Inactive"
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
            if role == "Survivor" then
                extra = string.format(" [%s%s%s]",
                    Survivor.State,
                    ActionState.current and ("/"..ActionState.current) or "",
                    Endgame.active and ("/ENDGAME:"..Endgame.state) or "")
            elseif role == "Killer" then
                extra = string.format(" [%s]", Killer.State)
            end
            readyLabel.Text = "AI ready ["..tostring(role).."]"..extra
        end
        local hum = getHumanoid()
        if not hum or hum.Health <= 0 then
            notifyRepairEnded(); releaseShift(); endHoldAction(); cancelGoal(); return
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
            endHoldAction(); releaseShift(); cancelGoal()
        end
    end)
    log("Role watcher started")
end

bindCommonRemotes()
startRoleWatcher()

-- ============================================================================
-- LIFECYCLE
-- ============================================================================
localPlayer.CharacterAdded:Connect(function()
    log("CharacterAdded: reset")
    survivorReset(); killerReset(); resetThreat()
    ActionState.current = nil
    ActionState.phase = "idle"
    ActionState.cooldownUntil = 0
    Endgame.active = false
    Endgame.state = "Inactive"
    notifyRepairEnded(); endHoldAction()
    ensureGuiAlive()
end)

localPlayer.CharacterRemoving:Connect(function()
    notifyRepairEnded(); releaseShift(); endHoldAction(); cancelGoal()
    ActionState.current = nil
    ActionState.phase = "idle"
    ActionState.cooldownUntil = 0
    Endgame.active = false
    Endgame.state = "Inactive"
end)

-- ============================================================================
-- KILL SWITCH
-- ============================================================================
_G.KemiAI_Stop = function()
    if roleWatcherConnection then roleWatcherConnection:Disconnect(); roleWatcherConnection = nil end
    for _,c in ipairs(CommonRemotes.conns) do pcall(function() c:Disconnect() end) end
    CommonRemotes.conns = {}
    CommonRemotes.bound = false
    notifyRepairEnded(); releaseShift(); endHoldAction(); cancelGoal()
    resetThreat(); resetFlee(); resetPerception()
    ActionState.current = nil
    ActionState.phase = "idle"
    ActionState.cooldownUntil = 0
    Endgame.active = false
    Endgame.state = "Inactive"
    chaseReset()
    if readyGui then pcall(function() readyGui:Destroy() end); readyGui=nil; readyLabel=nil end
    log("Stopped")
end

log("AI ready — R15.1 incremental upgrade (cancel + chase SM + endgame + fence)")
