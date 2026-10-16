-- ============================================================================
-- KEMI // PLAY AI — Core Basic Version
-- Served via backend → loaded after auth
-- Behavior:
--   • Spectator  : idle, tidak berinteraksi
--   • Killer     : chase survivor terdekat, lock + hit saat 5-7 studs (max 2x)
--   • Survivor   : cari generator terdekat, auto skillcheck (rotate),
--                  flee jika killer mendekat
--   • Movement   : pathfinding smooth, anti-tabrak
-- GUI hanya teks "AI ready" di pojok kiri bawah
-- ============================================================================

local Players            = game:GetService("Players")
local RunService         = game:GetService("RunService")
local PathfindingService = game:GetService("PathfindingService")
local ReplicatedStorage  = game:GetService("ReplicatedStorage")
local VirtualInputManager= game:GetService("VirtualInputManager")
local UserInputService   = game:GetService("UserInputService")
local GuiService         = game:GetService("GuiService")

local localPlayer = Players.LocalPlayer
local playerGui   = localPlayer:WaitForChild("PlayerGui")

-- ============================================================================
-- KONFIGURASI
-- ============================================================================
local CONFIG = {
    -- Speed
    BASE_WALKSPEED      = 16,
    EXTRA_WALKSPEED     = 0.7,       -- total = 16.7

    -- Killer behavior
    KILLER_DETECT_RANGE = 250,       -- cari survivor sampai jarak ini
    KILLER_HIT_RANGE    = 6,         -- 5-7 studs → lock + hit
    KILLER_HIT_RANGE_TOL= 1,         -- toleransi ±1 stud
    KILLER_MAX_HITS     = 2,         -- max 2 hit per survivor
    KILLER_HIT_COOLDOWN = 1.2,       -- jeda antar hit

    -- Survivor behavior
    SURV_GEN_DETECT     = 250,       -- cari generator sampai jarak ini
    SURV_GEN_ACTION_R   = 4,         -- radius interaksi generator
    SURV_FLEE_DIST      = 35,        -- jarak killer → mulai kabur
    SURV_REGEN_INTERVAL = 0.5,       -- cek ulang generator

    -- Movement / pathfinding
    REPATH_INTERVAL     = 0.4,       -- recompute path tiap X detik
    REPATH_DIST_THRESH = 6,          -- recompute kalau target geser > X studs
    WAYPOINT_REACH_DIST = 3,         -- dianggap sampai waypoint
    WAYPOINT_TIMEOUT    = 3,         -- kalau stuck > X detik, recompute

    -- Skillcheck (auto rotate)
    SKILLCHECK_START_TOL= 101,       -- range bawah (goal + 101)
    SKILLCHECK_END_TOL  = 115,       -- range atas  (goal + 115)
    SKILLCHECK_FORCE_OFF= 109,       -- paksa line ke goal + 109

    -- Action button path (killer attack & survivor interact)
    ACTION_PATHS = {
        "Survivor-mob.Controls.action",
        "Survivor-mob.Controls.action.check",
        "Survivor-mob.Controls.check",
        "Killer-mob.Controls.action",
        "Killer-mob.Controls.attack",
        "Killer-mob.Controls.check",
    },

    -- Touch ID untuk VirtualInputManager
    TOUCH_ID = 8822,
}

-- ============================================================================
-- GUI TEKS "AI ready" (pojok kiri bawah)
-- ============================================================================
local readyGui, readyLabel
do
    readyGui = Instance.new("ScreenGui")
    readyGui.Name = "KemiAI_Ready"
    readyGui.ResetOnSpawn = false
    readyGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    readyGui.IgnoreGuiInset = true
    readyGui.Parent = playerGui

    readyLabel = Instance.new("TextLabel")
    readyLabel.Name = "ReadyLabel"
    readyLabel.AnchorPoint = Vector2.new(0, 1)
    readyLabel.Position = UDim2.new(0, 14, 1, -14)
    readyLabel.Size = UDim2.new(0, 200, 0, 18)
    readyLabel.BackgroundTransparency = 1
    readyLabel.Text = "AI ready"
    readyLabel.TextColor3 = Color3.fromRGB(0, 255, 120)
    readyLabel.TextStrokeTransparency = 0.4
    readyLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
    readyLabel.Font = Enum.Font.GothamBold
    readyLabel.TextSize = 14
    readyLabel.TextXAlignment = Enum.TextXAlignment.Left
    readyLabel.Parent = readyGui
end

-- ============================================================================
-- HELPER UMUM
-- ============================================================================
local function getChar()
    return localPlayer.Character
end

local function getHumanoid()
    local c = getChar()
    if not c then return nil end
    return c:FindFirstChildOfClass("Humanoid")
end

local function getRoot()
    local c = getChar()
    if not c then return nil end
    return c:FindFirstChild("HumanoidRootPart") or c:FindFirstChild("Torso")
end

local function distance(a, b)
    if not a or not b then return math.huge end
    return (a.Position - b.Position).Magnitude
end

-- ============================================================================
-- ROLE DETECTION
-- ============================================================================
local function getRole()
    local team = localPlayer.Team
    if not team then return "Spectator" end
    local n = team.Name:lower()
    if n:find("killer") or n:find("monster") or n:find("enemy") then
        return "Killer"
    elseif n:find("survivor") then
        return "Survivor"
    end
    return "Spectator"
end

-- ============================================================================
-- ACTION BUTTON HELPER
-- ============================================================================
local function findActionButton()
    for _, path in ipairs(CONFIG.ACTION_PATHS) do
        local cur = playerGui
        local ok = true
        for seg in string.gmatch(path, "[^%.]+") do
            cur = cur and cur:FindFirstChild(seg)
            if not cur then ok = false break end
        end
        if ok and cur and cur:IsA("GuiObject") and cur.Visible then
            local sz = cur.AbsoluteSize
            if sz.X > 0 and sz.Y > 0 then
                return cur
            end
        end
    end
    return nil
end

local function triggerActionButton()
    local btn = findActionButton()
    if not btn then return false end
    local p, s, i = btn.AbsolutePosition, btn.AbsoluteSize, GuiService:GetGuiInset()
    local cx = p.X + (s.X / 2) + i.X
    local cy = p.Y + (s.Y / 2) + i.Y
    pcall(function()
        VirtualInputManager:SendTouchEvent(CONFIG.TOUCH_ID, 0, cx, cy)
        task.wait(0.02)
        VirtualInputManager:SendTouchEvent(CONFIG.TOUCH_ID, 2, cx, cy)
    end)
    return true
end

-- ============================================================================
-- TARGETING
-- ============================================================================
local function isKillerPlayer(p)
    if not p or p == localPlayer then return false end
    if p.Team then
        local n = p.Team.Name:lower()
        if n:find("killer") or n:find("monster") or n:find("enemy") then
            return true
        end
    end
    return false
end

local function isSurvivorPlayer(p)
    if not p or p == localPlayer then return false end
    if p.Team then
        local n = p.Team.Name:lower()
        if n:find("survivor") then return true end
    end
    return false
end

local function getPlayerRoot(p)
    local c = p.Character
    if not c then return nil end
    return c:FindFirstChild("HumanoidRootPart") or c:FindFirstChild("Torso")
end

local function findNearestSurvivor(maxDist)
    maxDist = maxDist or CONFIG.KILLER_DETECT_RANGE
    local myRoot = getRoot()
    if not myRoot then return nil, nil end
    local best, bestD = nil, maxDist
    for _, p in ipairs(Players:GetPlayers()) do
        if isSurvivorPlayer(p) then
            local r = getPlayerRoot(p)
            if r then
                local d = distance(myRoot, r)
                if d < bestD then
                    bestD = d
                    best = p
                end
            end
        end
    end
    return best, bestD
end

local function findNearestKiller(maxDist)
    maxDist = maxDist or CONFIG.SURV_FLEE_DIST
    local myRoot = getRoot()
    if not myRoot then return nil, nil end
    local best, bestD = nil, maxDist
    for _, p in ipairs(Players:GetPlayers()) do
        if isKillerPlayer(p) then
            local r = getPlayerRoot(p)
            if r then
                local d = distance(myRoot, r)
                if d < bestD then
                    bestD = d
                    best = p
                end
            end
        end
    end
    return best, bestD
end

local function findNearestGenerator(maxDist)
    maxDist = maxDist or CONFIG.SURV_GEN_DETECT
    local myRoot = getRoot()
    if not myRoot then return nil end

    local map = workspace:FindFirstChild("Map")
    local gens = map and map:FindFirstChild("Generators")
    if not gens then return nil end

    local best, bestD = nil, maxDist
    for _, gen in ipairs(gens:GetChildren()) do
        -- Skip generator yang sudah selesai (RepairProgress >= 100)
        local progress = gen:GetAttribute("RepairProgress") or gen:GetAttribute("Progress")
        if progress == nil or (tonumber(progress) or 0) < 100 then
            local pos = nil
            -- Cari GeneratorPoint untuk titik pendekatan
            for _, ch in ipairs(gen:GetChildren()) do
                if ch:IsA("BasePart") and ch.Name:match("^GeneratorPoint%d+$") then
                    pos = ch.Position
                    break
                end
            end
            if not pos and gen:IsA("Model") and gen.PrimaryPart then
                pos = gen.PrimaryPart.Position
            end
            if pos then
                local d = (myRoot.Position - pos).Magnitude
                if d < bestD then
                    bestD = d
                    best = gen
                end
            end
        end
    end
    return best
end

local function getGeneratorApproachPoint(gen)
    -- Return posisi GeneratorPoint terdekat dari karakter lokal
    if not gen then return nil end
    local myRoot = getRoot()
    if not myRoot then return nil end
    local best, bestD = nil, math.huge
    for _, ch in ipairs(gen:GetChildren()) do
        if ch:IsA("BasePart") and ch.Name:match("^GeneratorPoint%d+$") then
            local d = (myRoot.Position - ch.Position).Magnitude
            if d < bestD then
                bestD = d
                best = ch
            end
        end
    end
    if best then return best.Position end
    if gen:IsA("Model") and gen.PrimaryPart then return gen.PrimaryPart.Position end
    return nil
end

-- ============================================================================
-- MOVEMENT (Pathfinding Smooth)
-- ============================================================================
local MOVE = {
    waypoints = {},
    index = 1,
    lastRepath = 0,
    lastTargetPos = nil,
    lastMoveTo = 0,
    stuckSince = 0,
    lastPos = nil,
}

local function stopMoving()
    local hum = getHumanoid()
    if hum then hum:Move(Vector3.zero, false) end
    MOVE.waypoints = {}
    MOVE.index = 1
end

local function computePath(targetPos)
    local char = getChar()
    if not char then return false end
    local root = getRoot()
    if not root then return false end

    local path = PathfindingService:CreatePath({
        AgentRadius = 2,
        AgentHeight = 5,
        AgentCanJump = true,
        AgentMaxSlope = 45,
        WaypointSpacing = 4,
    })

    local ok = pcall(function()
        path:ComputeAsync(root.Position, targetPos)
    end)

    if ok and path.Status == Enum.PathStatus.Success then
        MOVE.waypoints = path:GetWaypoints()
        MOVE.index = 1
        MOVE.lastRepath = tick()
        MOVE.lastTargetPos = targetPos
        MOVE.stuckSince = 0
        return true
    end

    -- fallback: pakai straight move
    MOVE.waypoints = {}
    MOVE.index = 1
    MOVE.lastRepath = tick()
    MOVE.lastTargetPos = targetPos
    return false
end

-- Panggil setiap frame. targetPos = Vector3 tujuan.
local function stepMovement(targetPos)
    local hum = getHumanoid()
    local root = getRoot()
    if not hum or not root then return end

    -- Set walkspeed konsisten
    hum.WalkSpeed = CONFIG.BASE_WALKSPEED + CONFIG.EXTRA_WALKSPEED

    local now = tick()

    -- Auto repath logic
    local needRepath = false
    if now - MOVE.lastRepath > CONFIG.REPATH_INTERVAL then
        needRepath = true
    end
    if MOVE.lastTargetPos then
        local moved = (targetPos - MOVE.lastTargetPos).Magnitude
        if moved > CONFIG.REPATH_DIST_THRESH then
            needRepath = true
        end
    end

    -- Detect stuck
    if MOVE.lastPos then
        local delta = (root.Position - MOVE.lastPos).Magnitude
        if delta < 0.15 then
            if MOVE.stuckSince == 0 then
                MOVE.stuckSince = now
            elseif now - MOVE.stuckSince > CONFIG.WAYPOINT_TIMEOUT then
                needRepath = true
                MOVE.stuckSince = 0
            end
        else
            MOVE.stuckSince = 0
        end
    end
    MOVE.lastPos = root.Position

    if needRepath then
        computePath(targetPos)
    end

    -- Follow waypoints
    if #MOVE.waypoints > 0 then
        local wp = MOVE.waypoints[MOVE.index]
        if wp then
            local distToWp = (root.Position - wp.Position).Magnitude
            if distToWp < CONFIG.WAYPOINT_REACH_DIST then
                MOVE.index = MOVE.index + 1
                wp = MOVE.waypoints[MOVE.index]
            end
            if wp then
                if wp.Action == Enum.PathWaypointAction.Jump then
                    hum.Jump = true
                end
                hum:MoveTo(wp.Position)
            else
                -- semua waypoint sudah dilalui → straight to target
                hum:MoveTo(targetPos)
            end
        end
    else
        -- tanpa waypoint (fallback)
        hum:MoveTo(targetPos)
    end
end

-- ============================================================================
-- CAMERA LOCK (dipakai killer saat akan hit)
-- ============================================================================
local camLockConn = nil

local function lockCameraTo(targetRoot)
    if camLockConn then
        camLockConn:Disconnect()
        camLockConn = nil
    end
    camLockConn = RunService.RenderStepped:Connect(function()
        local cam = workspace.CurrentCamera
        local myRoot = getRoot()
        if not cam or not myRoot or not targetRoot or not targetRoot.Parent then
            if camLockConn then
                camLockConn:Disconnect()
                camLockConn = nil
            end
            return
        end
        cam.CFrame = CFrame.lookAt(cam.CFrame.Position, targetRoot.Position)
    end)
end

local function unlockCamera()
    if camLockConn then
        camLockConn:Disconnect()
        camLockConn = nil
    end
end

-- ============================================================================
-- KILLER BEHAVIOR
-- ============================================================================
local killerState = {
    target = nil,
    targetPlayer = nil,
    hitCount = {},       -- [userId] = jumlah hit
    lastHitTime = 0,
    state = "idle",      -- idle | chase | hit | reposition
    lastTargetCheck = 0,
}

local function killerTick()
    local myRoot = getRoot()
    local hum = getHumanoid()
    if not myRoot or not hum then return end

    -- Validasi target
    local now = tick()
    if now - killerState.lastTargetCheck > 1 then
        killerState.lastTargetCheck = now
        -- Kalau tidak ada target atau target sudah mati → cari baru
        local t = killerState.target
        local valid = t and t.Parent
            and t.Parent:FindFirstChildOfClass("Humanoid")
            and t.Parent:FindFirstChildOfClass("Humanoid").Health > 0
        if not valid then
            local p, d = findNearestSurvivor(CONFIG.KILLER_DETECT_RANGE)
            if p then
                killerState.targetPlayer = p
                killerState.target = getPlayerRoot(p)
            else
                killerState.targetPlayer = nil
                killerState.target = nil
            end
        end
    end

    local target = killerState.target
    local targetPlayer = killerState.targetPlayer
    if not target or not target.Parent then
        stopMoving()
        unlockCamera()
        killerState.state = "idle"
        return
    end

    local dist = distance(myRoot, target)

    if dist <= CONFIG.KILLER_HIT_RANGE + CONFIG.KILLER_HIT_RANGE_TOL then
        -- Lock + hit
        killerState.state = "hit"
        stopMoving()
        lockCameraTo(target)

        local uid = targetPlayer.UserId
        local hits = killerState.hitCount[uid] or 0
        if hits < CONFIG.KILLER_MAX_HITS
            and (now - killerState.lastHitTime) > CONFIG.KILLER_HIT_COOLDOWN then
            killerState.lastHitTime = now
            killerState.hitCount[uid] = hits + 1
            triggerActionButton()
        end

        -- Kalau sudah 2x hit → blacklist sementara
        if (killerState.hitCount[uid] or 0) >= CONFIG.KILLER_MAX_HITS then
            killerState.target = nil
            killerState.targetPlayer = nil
            unlockCamera()
        end
    else
        -- Chase
        killerState.state = "chase"
        unlockCamera()
        stepMovement(target.Position)
    end
end

-- ============================================================================
-- SURVIVOR BEHAVIOR
-- ============================================================================
local survivorState = {
    currentGen = nil,
    state = "idle",      -- idle | go_gen | repair | flee
    lastGenCheck = 0,
    fleeTarget = nil,
    lastFleeCheck = 0,
}

-- Autoskillcheck yang dipakai survivor
local skillCheckConn = nil
local skillVisibilityConn = nil
local skillForceConn = nil
local skillHoldConn = nil

local function stopAutoSkillCheckAI()
    if skillVisibilityConn then skillVisibilityConn:Disconnect() skillVisibilityConn = nil end
    if skillCheckConn     then skillCheckConn:Disconnect()     skillCheckConn = nil end
    if skillForceConn     then skillForceConn:Disconnect()     skillForceConn = nil end
    if skillHoldConn      then skillHoldConn:Disconnect()      skillHoldConn = nil end
end

local function startAutoSkillCheckAI()
    stopAutoSkillCheckAI()

    task.spawn(function()
        local prompt = playerGui:FindFirstChild("SkillCheckPromptGui")
        if not prompt then
            prompt = playerGui:WaitForChild("SkillCheckPromptGui", 10)
        end
        if not prompt then return end
        local check = prompt:FindFirstChild("Check")
        if not check then return end

        local FORCE_ACTIVE = true

        -- Paksa line ke goal (auto rotate) di priority Last
        skillForceConn = RunService:BindToRenderStep("KemiAI_ForceLine",
            Enum.RenderPriority.Last.Value,
            function()
                if not FORCE_ACTIVE then return end
                if not check or not check.Parent or not check.Visible then return end
                local line = check:FindFirstChild("Line")
                local goal = check:FindFirstChild("Goal")
                if not line or not goal then return end
                line.Rotation = (goal.Rotation + CONFIG.SKILLCHECK_FORCE_OFF) % 360
            end)

        skillVisibilityConn = check:GetPropertyChangedSignal("Visible"):Connect(function()
            if check.Visible then
                FORCE_ACTIVE = true
            end
        end)

        skillCheckConn = RunService.Heartbeat:Connect(function()
            if not check.Visible then return end
            local line = check:FindFirstChild("Line")
            local goal = check:FindFirstChild("Goal")
            if not line or not goal then return end
            local lr = line.Rotation % 360
            local gr = goal.Rotation % 360
            local ss = (gr + CONFIG.SKILLCHECK_START_TOL) % 360
            local se = (gr + CONFIG.SKILLCHECK_END_TOL) % 360
            local inRange
            if ss > se then
                inRange = (lr >= ss or lr <= se)
            else
                inRange = (lr >= ss and lr <= se)
            end
            if inRange then
                triggerActionButton()
            end
        end)
    end)
end

local function survivorTick()
    local myRoot = getRoot()
    local hum = getHumanoid()
    if not myRoot or not hum then return end

    local now = tick()

    -- Cek killer terdekat → flee
    local killer, kD = findNearestKiller(CONFIG.SURV_FLEE_DIST)
    if killer then
        survivorState.state = "flee"
        -- Hitung arah menjauh
        local killerRoot = getPlayerRoot(killer)
        if killerRoot then
            local away = (myRoot.Position - killerRoot.Position)
            if away.Magnitude > 0.5 then
                away = away.Unit
            else
                away = Vector3.new(1, 0, 0)
            end
            -- Target menjauh ~40 studs, sedikit dibiaskan biar tidak tabrak
            local fleeTarget = myRoot.Position + away * 40
            stepMovement(fleeTarget)
        end
        return
    end

    -- Tidak ada killer → cari generator terdekat
    if now - survivorState.lastGenCheck > CONFIG.SURV_REGEN_INTERVAL
        or (survivorState.currentGen and not survivorState.currentGen.Parent) then
        survivorState.lastGenCheck = now
        local gen = findNearestGenerator(CONFIG.SURV_GEN_DETECT)
        survivorState.currentGen = gen
    end

    local gen = survivorState.currentGen
    if not gen then
        -- Tidak ada generator → idle
        survivorState.state = "idle"
        stopMoving()
        return
    end

    -- Cek apakah generator sudah selesai
    local progress = gen:GetAttribute("RepairProgress") or gen:GetAttribute("Progress")
    if progress and tonumber(progress) and tonumber(progress) >= 100 then
        survivorState.currentGen = nil
        return
    end

    local approach = getGeneratorApproachPoint(gen)
    if not approach then
        stopMoving()
        return
    end

    local dist = (myRoot.Position - approach).Magnitude

    if dist <= CONFIG.SURV_GEN_ACTION_R then
        -- Di dekat generator → repair
        survivorState.state = "repair"
        stopMoving()
        -- Trigger action button untuk repair
        triggerActionButton()
    else
        -- Jalan menuju generator
        survivorState.state = "go_gen"
        stepMovement(approach)
    end
end

-- ============================================================================
-- MAIN AI TICK
-- ============================================================================
local mainConn = RunService.Heartbeat:Connect(function()
    -- Pastikan GUI ready label ada
    if readyLabel and readyLabel.Parent then
        readyLabel.Text = "AI ready"
    end

    local char = getChar()
    if not char then return end
    local hum = getHumanoid()
    if not hum or hum.Health <= 0 then return end

    local role = getRole()

    if role == "Spectator" then
        -- Diam saja
        stopMoving()
        unlockCamera()
        stopAutoSkillCheckAI()
        return
    end

    if role == "Killer" then
        stopAutoSkillCheckAI()      -- killer tidak pakai skillcheck
        killerTick()
    elseif role == "Survivor" then
        -- Pastikan auto skillcheck aktif selama jadi survivor
        if not skillCheckConn then
            startAutoSkillCheckAI()
        end
        survivorTick()
    end
end)

-- ============================================================================
-- CLEANUP: kalau karakter respawn, reset state
-- ============================================================================
localPlayer.CharacterAdded:Connect(function()
    -- Reset semua state
    killerState.target = nil
    killerState.targetPlayer = nil
    killerState.state = "idle"
    survivorState.currentGen = nil
    survivorState.state = "idle"
    MOVE.waypoints = {}
    MOVE.index = 1
    MOVE.lastTargetPos = nil
    MOVE.lastPos = nil
    unlockCamera()
    stopAutoSkillCheckAI()
end)

-- Kill switch: lewat _G supaya bisa di-stop dari luar kalau perlu
_G.KemiAI_Stop = function()
    if mainConn then mainConn:Disconnect() mainConn = nil end
    stopAutoSkillCheckAI()
    stopMoving()
    unlockCamera()
    if readyGui then pcall(function() readyGui:Destroy() end) readyGui = nil end
    print("[KemiAI] Stopped")
end
