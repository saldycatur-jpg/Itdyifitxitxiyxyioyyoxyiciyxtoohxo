-- ============================================================================
-- STANDALONE AUTO SKILL CHECK (LOADSTRING COMPATIBLE)
-- Persistent across rounds, role changes, and respawns.
-- Cukup jalankan via loadstring, tidak perlu interaksi lain.
-- ============================================================================

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local GuiService = game:GetService("GuiService")
local VirtualInputManager = game:GetService("VirtualInputManager")

local localPlayer = Players.LocalPlayer

-- ============================================================================
-- KONFIGURASI
-- ============================================================================
local CONFIG = {
    MAX_TRIGGER = 99999999999,
    TRIGGER_INTERVAL = 0.05,
    TOUCH_ID = 8822,
    ACTION_PATH = "Survivor-mob.Controls.action.check",
    BIND_NAME = "AutoSkillCheck_RenderBind",
    RANGE_START_OFFSET = 104,
    RANGE_END_OFFSET = 118,
    SNAP_OFFSET = 109,
}

-- ============================================================================
-- STATE PERSISTEN (getgenv agar tidak hilang antar eksekusi)
-- ============================================================================
local _G = (getgenv and getgenv()) or _G
if not _G.AutoSkillCheckState then
    _G.AutoSkillCheckState = {
        watchers = {},          -- koneksi persisten (tidak pernah diputus)
        sessionConns = {},      -- koneksi per-sesi (diputus saat ronde/ganti role)
        activeBindOwner = nil,  -- referensi check yang sedang di-bind
        initialized = false,
    }
end
local state = _G.AutoSkillCheckState

-- ============================================================================
-- UTILITY
-- ============================================================================
local function getPlayerGui()
    return localPlayer:FindFirstChild("PlayerGui")
end

local function GetActionTarget()
    local cur = getPlayerGui()
    if not cur then return nil end
    for seg in string.gmatch(CONFIG.ACTION_PATH, "[^%.]+") do
        cur = cur and cur:FindFirstChild(seg)
    end
    return cur
end

local function TriggerMobileButton()
    local b = GetActionTarget()
    if b and b:IsA("GuiObject") then
        local p, s, i = b.AbsolutePosition, b.AbsoluteSize, GuiService:GetGuiInset()
        local cx, cy = p.X + (s.X / 2) + i.X, p.Y + (s.Y / 2) + i.Y
        pcall(function()
            VirtualInputManager:SendTouchEvent(CONFIG.TOUCH_ID, 0, cx, cy)
            VirtualInputManager:SendTouchEvent(CONFIG.TOUCH_ID, 2, cx, cy)
        end)
    end
end

local function unbind()
    pcall(function()
        RunService:UnbindFromRenderStep(CONFIG.BIND_NAME)
    end)
    state.activeBindOwner = nil
end

local function clearSession()
    for _, c in ipairs(state.sessionConns) do
        pcall(function() c:Disconnect() end)
    end
    state.sessionConns = {}
    unbind()
end

-- ============================================================================
-- CORE: BIND SKILL CHECK
-- ============================================================================
local function bindCheck(check)
    if not check or not check:IsA("GuiObject") then return end

    local triggerCount = 0
    local lastTriggerTime = 0

    local function snapLineOnce()
        local line = check:FindFirstChild("Line")
        local goal = check:FindFirstChild("Goal")
        if not line or not goal then return end
        local gr = goal.Rotation % 360
        line.Rotation = (gr + CONFIG.SNAP_OFFSET) % 360
    end

    local function startActivePhase()
        triggerCount = 0
        lastTriggerTime = 0
        unbind()
        snapLineOnce()
        state.activeBindOwner = check

        RunService:BindToRenderStep(CONFIG.BIND_NAME, Enum.RenderPriority.Last.Value, function()
            if not check or not check.Parent or not check.Visible then
                return
            end
            if triggerCount >= CONFIG.MAX_TRIGGER then
                return
            end

            local line = check:FindFirstChild("Line")
            local goal = check:FindFirstChild("Goal")
            if not line or not goal then return end

            local now = tick()
            local lr = line.Rotation % 360
            local gr = goal.Rotation % 360
            local ss = (gr + CONFIG.RANGE_START_OFFSET) % 360
            local se = (gr + CONFIG.RANGE_END_OFFSET) % 360
            local inRange = false

            if ss > se then
                if lr >= ss or lr <= se then inRange = true end
            else
                if lr >= ss and lr <= se then inRange = true end
            end

            if inRange and (now - lastTriggerTime >= CONFIG.TRIGGER_INTERVAL) then
                lastTriggerTime = now
                triggerCount = triggerCount + 1
                TriggerMobileButton()
            end
        end)
    end

    local visConn = check:GetPropertyChangedSignal("Visible"):Connect(function()
        if localPlayer.Team and localPlayer.Team.Name == "Survivors" and check.Visible then
            startActivePhase()
        else
            if state.activeBindOwner == check then
                unbind()
            end
        end
    end)
    table.insert(state.sessionConns, visConn)

    -- Jika saat di-bind sudah visible
    if check.Visible and localPlayer.Team and localPlayer.Team.Name == "Survivors" then
        startActivePhase()
    end
end

-- ============================================================================
-- ATTACH KE SKILL CHECK PROMPT
-- ============================================================================
local function attachToPrompt(prompt)
    if not prompt then return end

    -- Bind check yang sudah ada
    local existing = prompt:FindFirstChild("Check")
    if existing then
        bindCheck(existing)
    end

    -- Pantau check baru (setiap skill check baru dibuat ulang)
    local conn = prompt.ChildAdded:Connect(function(child)
        if child.Name == "Check" then
            task.wait(0.05)
            bindCheck(child)
        end
    end)
    table.insert(state.sessionConns, conn)
end

local function InitializeAutobuy()
    local pg = getPlayerGui()
    if not pg then return end

    local prompt = pg:FindFirstChild("SkillCheckPromptGui")
    if not prompt then
        prompt = pg:WaitForChild("SkillCheckPromptGui", 10)
    end
    if not prompt then return end

    attachToPrompt(prompt)
end

-- ============================================================================
-- PERSISTENT WATCHERS (tidak pernah diputus selama executor aktif)
-- ============================================================================
local function startPersistentWatchers()
    -- 1. SkillCheckPromptGui dibuat ulang (umumnya tiap ronde / tiap skill check)
    local pg = getPlayerGui()
    if pg then
        local c1 = pg.ChildAdded:Connect(function(child)
            if child.Name == "SkillCheckPromptGui" then
                task.wait(0.2)
                attachToPrompt(child)
            end
        end)
        table.insert(state.watchers, c1)
    end

    -- 2. PlayerGui dibuat ulang (jarang, tapi bisa terjadi)
    local c2 = localPlayer.ChildAdded:Connect(function(child)
        if child.Name == "PlayerGui" then
            task.wait(0.5)
            clearSession()
            InitializeAutobuy()
        end
    end)
    table.insert(state.watchers, c2)

    -- 3. Karakter respawn (round transition / mati)
    local c3 = localPlayer.CharacterAdded:Connect(function()
        task.wait(1)
        clearSession()
        InitializeAutobuy()
    end)
    table.insert(state.watchers, c3)

    -- 4. Perubahan Team (Survivor <-> Killer <-> Spectator)
    local c4 = localPlayer:GetPropertyChangedSignal("Team"):Connect(function()
        task.wait(0.5)
        clearSession()
        if localPlayer.Team and localPlayer.Team.Name == "Survivors" then
            InitializeAutobuy()
        end
    end)
    table.insert(state.watchers, c4)
end

-- ============================================================================
-- ENTRY POINT
-- ============================================================================
local function main()
    print("[AutoSkillCheck] Standalone script loading...")

    if not state.initialized then
        startPersistentWatchers()
        state.initialized = true
    else
        -- Sudah pernah dijalankan: hanya refresh sesi
        clearSession()
    end

    task.wait(0.5)
    InitializeAutobuy()

    print("[AutoSkillCheck] Active - persist across rounds, respawns, and role changes")
end

main()
