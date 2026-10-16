-- ============================================================================
-- KEMI // PLAY AI — Core Basic v2 (Fixed)
-- ============================================================================

local Players            = game:GetService("Players")
local RunService         = game:GetService("RunService")
local PathfindingService = game:GetService("PathfindingService")
local VirtualInputManager= game:GetService("VirtualInputManager")
local GuiService         = game:GetService("GuiService")

local localPlayer = Players.LocalPlayer
local playerGui   = localPlayer:WaitForChild("PlayerGui")

-- ============================================================================
-- KONFIGURASI
-- ============================================================================
local CONFIG = {
    BASE_WALKSPEED      = 16,
    CFRAME_BOOST        = 1.1,       -- boost CFrame per detik (studs)

    KILLER_DETECT_RANGE = 250,
    KILLER_HIT_RANGE    = 6,
    KILLER_HIT_RANGE_TOL= 1,
    KILLER_MAX_HITS     = 2,
    KILLER_HIT_COOLDOWN = 1.2,

    SURV_GEN_DETECT     = 250,
    SURV_GEN_ACTION_R   = 4,
    SURV_FLEE_DIST      = 35,
    SURV_REGEN_INTERVAL = 0.5,

    REPATH_INTERVAL     = 0.4,
    REPATH_DIST_THRESH  = 6,
    WAYPOINT_REACH_DIST = 3,
    WAYPOINT_TIMEOUT    = 3,

    SKILLCHECK_START_TOL= 101,
    SKILLCHECK_END_TOL  = 115,
    SKILLCHECK_FORCE_OFF= 109,
    SKILLCHECK_GOAL_JUMP= 30,        -- kalau goal lompat > X derajat → double skillcheck

    ACTION_PATHS = {
        "Survivor-mob.Controls.action",
        "Survivor-mob.Controls.action.check",
        "Survivor-mob.Controls.check",
        "Killer-mob.Controls.action",
        "Killer-mob.Controls.attack",
        "Killer-mob.Controls.check",
    },

    TOUCH_ID = 8822,
}

-- ============================================================================
-- GUI TEKS
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
    readyLabel.AnchorPoint = Vector2.new(0, 1)
    readyLabel.Position = UDim2.new(0, 14, 1, -14)
    readyLabel.Size = UDim2.new(0, 300, 0, 18)
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

local function setReadyText(t)
    if readyLabel and readyLabel.Parent then
        readyLabel.Text = t or "AI ready"
    end
end

-- ============================================================================
-- HELPER UMUM
-- ============================================================================
local function getChar() return localPlayer.Character end
local function getHumanoid()
    local c = getChar() if not c then return nil end
    return c:FindFirstChildOfClass("Humanoid")
end
local function getRoot()
    local c = getChar() if not c then return nil end
    return c:FindFirstChild("HumanoidRootPart") or c:FindFirstChild("Torso")
end
local function distance(a, b)
    if not a or not b then return math.huge end
    return (a.Position - b.Position).Magnitude
end

local function getRole()
    local team = localPlayer.Team
    if not team then return "Spectator" end
    local n = team.Name:lower()
    if n:find("killer") or n:find("monster") or n:find("enemy") then return "Killer" end
    if n:find("survivor") then return "Survivor" end
    return "Spectator"
end

-- ============================================================================
-- ACTION BUTTON (untuk killer hit)
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
            if sz.X > 0 and sz.Y > 0 then return cur end
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
-- SHIFT HOLD (untuk interaksi generator)
-- ============================================================================
local shiftHeld = false

local function setShiftHeld(held)
    if shiftHeld == held then return end
    shiftHeld = held
    pcall(function()
        if held then
            VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.LeftShift, false, game)
        else
            VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.LeftShift, false, game)
        end
    end)
end

local function releaseShift()
    setShiftHeld(false)
end

-- ============================================================================
-- TARGETING
-- ============================================================================
local function isKillerPlayer(p)
    if not p or p == localPlayer then return false end
    if p.Team then
        local n = p.Team.Name:lower()
        if n:find("killer") or n:find("monster") or n:find("enemy") then return true end
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
    local c = p.Character if not c then return nil end
    return c:FindFirstChild("HumanoidRootPart") or c:FindFirstChild("Torso")
end

local function findNearestSurvivor(maxDist)
    maxDist = maxDist or CONFIG.KILLER_DETECT_RANGE
    local myRoot = getRoot() if not myRoot then return nil, nil end
    local best, bestD = nil, maxDist
    for _, p in ipairs(Players:GetPlayers()) do
        if isSurvivorPlayer(p) then
            local r = getPlayerRoot(p)
            if r then
                local d = distance(myRoot, r)
                if d < bestD then bestD = d best = p end
            end
        end
    end
    return best, bestD
end

local function findNearestKiller(maxDist)
    maxDist = maxDist or CONFIG.SURV_FLEE_DIST
    local myRoot = getRoot() if not myRoot then return nil, nil end
    local best, bestD = nil, maxDist
    for _, p in ipairs(Players:GetPlayers()) do
        if isKillerPlayer(p) then
            local r = getPlayerRoot(p)
            if r then
                local d = distance(myRoot, r)
                if d < bestD then bestD = d best = p end
            end
        end
    end
    return best, bestD
end

local function findNearestGenerator(maxDist)
    maxDist = maxDist or CONFIG.SURV_GEN_DETECT
    local myRoot = getRoot() if not myRoot then return nil end

    local map = workspace:FindFirstChild("Map")
    local gens = map and map:FindFirstChild("Generators")
    if not gens then return nil end

    local best, bestD = nil, maxDist
    for _, gen in ipairs(gens:GetChildren()) do
        local progress = gen:GetAttribute("RepairProgress") or gen:GetAttribute("Progress")
        if progress == nil or (tonumber(progress) or 0) < 100 then
            -- Ambil titik pendekatan (GeneratorPoint terdekat atau PrimaryPart)
            local pos = nil
            local myPos = myRoot.Position
            local bestPoint, bestPointD = nil, math.huge
            for _, ch in ipairs(gen:GetChildren()) do
                if ch:IsA("BasePart") and ch.Name:match("^GeneratorPoint%d+$") then
                    local d = (myPos - ch.Position).Magnitude
                    if d < bestPointD then bestPointD = d bestPoint = ch end
                end
            end
            if bestPoint then
                pos = bestPoint.Position
            elseif gen:IsA("Model") and gen.PrimaryPart then
                pos = gen.PrimaryPart.Position
            end
            if pos then
                local d = (myPos - pos).Magnitude
                if d < bestD then bestD = d best = gen end
            end
        end
    end
    return best
end

local function getGeneratorApproachPoint(gen)
    if not gen then return nil end
    local myRoot = getRoot() if not myRoot then return nil end
    local myPos = myRoot.Position
    local best, bestD = nil, math.huge
    for _, ch in ipairs(gen:GetChildren()) do
        if ch:IsA("BasePart") and ch.Name:match("^GeneratorPoint%d+$") then
            local d = (myPos - ch.Position).Magnitude
            if d < bestD then bestD = d best = ch end
        end
    end
    if best then return best.Position end
    if gen:IsA("Model") and gen.PrimaryPart then return gen.PrimaryPart.Position end
    return nil
end

-- ============================================================================
-- MOVEMENT
-- ============================================================================
local MOVE = {
    waypoints = {}, index = 1,
    lastRepath = 0, lastTargetPos = nil,
    stuckSince = 0, lastPos = nil,
    cframeBoost = CONFIG.CFRAME_BOOST,
}

local function stopMoving()
    local hum = getHumanoid()
    if hum then hum:Move(Vector3.zero, false) end
    MOVE.waypoints = {}
    MOVE.index = 1
end

local function computePath(targetPos)
    local root = getRoot() if not root then return false end
    local path = PathfindingService:CreatePath({
        AgentRadius = 2, AgentHeight = 5,
        AgentCanJump = true, AgentMaxSlope = 45,
        WaypointSpacing = 4,
    })
    local ok = pcall(function() path:ComputeAsync(root.Position, targetPos) end)
    if ok and path.Status == Enum.PathStatus.Success then
        MOVE.waypoints = path:GetWaypoints()
        MOVE.index = 1
        MOVE.lastRepath = tick()
        MOVE.lastTargetPos = targetPos
        MOVE.stuckSince = 0
        return true
    end
    MOVE.waypoints = {}
    MOVE.index = 1
    MOVE.lastRepath = tick()
    MOVE.lastTargetPos = targetPos
    return false
end

-- stepMovement dengan CFrame boost
local function stepMovement(targetPos, dt)
    local hum = getHumanoid()
    local root = getRoot()
    if not hum or not root then return end

    -- WalkSpeed normal
    hum.WalkSpeed = CONFIG.BASE_WALKSPEED

    local now = tick()

    -- Auto repath
    local needRepath = false
    if now - MOVE.lastRepath > CONFIG.REPATH_INTERVAL then needRepath = true end
    if MOVE.lastTargetPos then
        if (targetPos - MOVE.lastTargetPos).Magnitude > CONFIG.REPATH_DIST_THRESH then
            needRepath = true
        end
    end

    -- Stuck detection
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

    if needRepath then computePath(targetPos) end

    -- Follow waypoints
    if #MOVE.waypoints > 0 then
        local wp = MOVE.waypoints[MOVE.index]
        if wp then
            if (root.Position - wp.Position).Magnitude < CONFIG.WAYPOINT_REACH_DIST then
                MOVE.index = MOVE.index + 1
                wp = MOVE.waypoints[MOVE.index]
            end
            if wp then
                if wp.Action == Enum.PathWaypointAction.Jump then hum.Jump = true end
                hum:MoveTo(wp.Position)
            else
                hum:MoveTo(targetPos)
            end
        end
    else
        hum:MoveTo(targetPos)
    end

    -- ===== CFrame boost (1.1 studs/detik) =====
    -- Aplikasikan setelah MoveTo, agar arah tetap sesuai
    local dtSafe = (type(dt) == "number" and dt > 0) and dt or (1/60)
    local moveDir = targetPos - root.Position
    moveDir = Vector3.new(moveDir.X, 0, moveDir.Z) -- hanya horizontal
    if moveDir.Magnitude > 0.5 then
        moveDir = moveDir.Unit
        root.CFrame = root.CFrame + moveDir * MOVE.cframeBoost * dtSafe
    end
end

-- ============================================================================
-- CAMERA LOCK
-- ============================================================================
local camLockConn = nil
local function lockCameraTo(targetRoot)
    if camLockConn then camLockConn:Disconnect() camLockConn = nil end
    camLockConn = RunService.RenderStepped:Connect(function()
        local cam = workspace.CurrentCamera
        local myRoot = getRoot()
        if not cam or not myRoot or not targetRoot or not targetRoot.Parent then
            if camLockConn then camLockConn:Disconnect() camLockConn = nil end
            return
        end
        cam.CFrame = CFrame.lookAt(cam.CFrame.Position, targetRoot.Position)
    end)
end
local function unlockCamera()
    if camLockConn then camLockConn:Disconnect() camLockConn = nil end
end

-- ============================================================================
-- KILLER BEHAVIOR
-- ============================================================================
local killerState = {
    target = nil, targetPlayer = nil,
    hitCount = {}, lastHitTime = 0,
    state = "idle", lastTargetCheck = 0,
}

local function killerTick(dt)
    local myRoot = getRoot()
    local hum = getHumanoid()
    if not myRoot or not hum then return end

    local now = tick()
    if now - killerState.lastTargetCheck > 1 then
        killerState.lastTargetCheck = now
        local t = killerState.target
        local valid = t and t.Parent
            and t.Parent:FindFirstChildOfClass("Humanoid")
            and t.Parent:FindFirstChildOfClass("Humanoid").Health > 0
        if not valid then
            local p = findNearestSurvivor(CONFIG.KILLER_DETECT_RANGE)
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

        if (killerState.hitCount[uid] or 0) >= CONFIG.KILLER_MAX_HITS then
            killerState.target = nil
            killerState.targetPlayer = nil
            unlockCamera()
        end
    else
        killerState.state = "chase"
        unlockCamera()
        stepMovement(target.Position, dt)
    end
end

-- ============================================================================
-- AUTO SKILLCHECK (dengan deteksi double skillcheck)
-- ============================================================================
local skillCheckConn = nil
local skillVisibilityConn = nil
local skillForceConn = nil

local function stopAutoSkillCheckAI()
    if skillVisibilityConn then skillVisibilityConn:Disconnect() skillVisibilityConn = nil end
    if skillCheckConn     then skillCheckConn:Disconnect()     skillCheckConn = nil end
    if skillForceConn     then
        pcall(function() RunService:UnbindFromRenderStep("KemiAI_ForceLine") end)
        skillForceConn = nil
    end
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

        -- state lokal untuk force rotation
        local forceRotation = false
        local initialGoalRot = nil

        skillForceConn = RunService:BindToRenderStep("KemiAI_ForceLine",
            Enum.RenderPriority.Last.Value,
            function()
                if not check or not check.Parent or not check.Visible then
                    initialGoalRot = nil
                    forceRotation = false
                    return
                end
                if not forceRotation then return end

                local line = check:FindFirstChild("Line")
                local goal = check:FindFirstChild("Goal")
                if not line or not goal then return end

                local gr = goal.Rotation % 360

                -- Deteksi double skillcheck: goal lompat signifikan
                if initialGoalRot == nil then
                    initialGoalRot = gr
                else
                    local diff = math.abs(((gr - initialGoalRot + 180) % 360) - 180)
                    if diff > CONFIG.SKILLCHECK_GOAL_JUMP then
                        -- Double skillcheck terdeteksi → matikan force rotate
                        forceRotation = false
                        initialGoalRot = nil
                        return
                    end
                end

                -- Force line ke goal + 109
                line.Rotation = (gr + CONFIG.SKILLCHECK_FORCE_OFF) % 360
            end)

        -- Aktifkan forceRotation saat skillcheck visible
        skillVisibilityConn = check:GetPropertyChangedSignal("Visible"):Connect(function()
            if check.Visible then
                forceRotation = true
                initialGoalRot = nil
            else
                forceRotation = false
                initialGoalRot = nil
            end
        end)

        -- Trigger action button saat line dalam range
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

-- ============================================================================
-- SURVIVOR BEHAVIOR
-- ============================================================================
local survivorState = {
    currentGen = nil,
    state = "idle",       -- idle | go_gen | repair | flee
    lastGenCheck = 0,
}

local function survivorTick(dt)
    local myRoot = getRoot()
    local hum = getHumanoid()
    if not myRoot or not hum then return end

    local now = tick()

    -- Cek killer terdekat → flee
    local killer = findNearestKiller(CONFIG.SURV_FLEE_DIST)
    if killer then
        survivorState.state = "flee"
        releaseShift()  -- tidak interact saat kabur
        local killerRoot = getPlayerRoot(killer)
        if killerRoot then
            local away = myRoot.Position - killerRoot.Position
            if away.Magnitude > 0.5 then away = away.Unit
            else away = Vector3.new(1, 0, 0) end
            local fleeTarget = myRoot.Position + away * 40
            stepMovement(fleeTarget, dt)
        end
        return
    end

    -- Cari generator terdekat (refresh periodik)
    if now - survivorState.lastGenCheck > CONFIG.SURV_REGEN_INTERVAL
        or (survivorState.currentGen and not survivorState.currentGen.Parent) then
        survivorState.lastGenCheck = now
        survivorState.currentGen = findNearestGenerator(CONFIG.SURV_GEN_DETECT)
    end

    local gen = survivorState.currentGen
    if not gen then
        survivorState.state = "idle"
        stopMoving()
        releaseShift()
        return
    end

    -- Cek selesai
    local progress = gen:GetAttribute("RepairProgress") or gen:GetAttribute("Progress")
    if progress and tonumber(progress) and tonumber(progress) >= 100 then
        survivorState.currentGen = nil
        releaseShift()
        return
    end

    local approach = getGeneratorApproachPoint(gen)
    if not approach then
        stopMoving()
        releaseShift()
        return
    end

    local dist = (myRoot.Position - approach).Magnitude

    if dist <= CONFIG.SURV_GEN_ACTION_R then
        -- ===== Interaksi generator: HOLD SHIFT =====
        survivorState.state = "repair"
        stopMoving()
        setShiftHeld(true)
    else
        -- ===== Jalan ke generator =====
        survivorState.state = "go_gen"
        releaseShift()
        stepMovement(approach, dt)
    end
end

-- ============================================================================
-- MAIN AI TICK
-- ============================================================================
local lastRole = nil
local lastRoleChangeTime = 0

local mainConn = RunService.Heartbeat:Connect(function(dt)
    local char = getChar()
    if not char then
        setReadyText("AI: no character")
        return
    end
    local hum = getHumanoid()
    if not hum or hum.Health <= 0 then
        setReadyText("AI: dead")
        return
    end

    local role = getRole()
    local now = tick()

    -- ===== ROLE CHANGE DETECTION =====
    if role ~= lastRole then
        lastRole = role
        lastRoleChangeTime = now

        -- Reset semua state saat role berubah
        killerState.target = nil
        killerState.targetPlayer = nil
        killerState.hitCount = {}
        killerState.state = "idle"
        killerState.lastTargetCheck = 0

        survivorState.currentGen = nil
        survivorState.state = "idle"
        survivorState.lastGenCheck = 0

        MOVE.waypoints = {}
        MOVE.index = 1
        MOVE.lastTargetPos = nil
        MOVE.lastPos = nil
        MOVE.stuckSince = 0

        releaseShift()
        unlockCamera()
        stopAutoSkillCheckAI()

        -- Force fresh generator scan untuk survivor
        if role == "Survivor" then
            task.wait(0.1)
            survivorState.lastGenCheck = 0
        end
    end

    -- ===== DISPATCH =====
    if role == "Spectator" then
        stopMoving()
        unlockCamera()
        releaseShift()
        stopAutoSkillCheckAI()
        setReadyText("AI: spectator")
        return
    end

    if role == "Killer" then
        stopAutoSkillCheckAI()
        releaseShift()
        setReadyText("AI: killer")
        killerTick(dt)
    elseif role == "Survivor" then
        if not skillCheckConn then
            startAutoSkillCheckAI()
        end
        setReadyText("AI: survivor")
        survivorTick(dt)
    end
end)

-- ============================================================================
-- CLEANUP ON RESPAWN
-- ============================================================================
localPlayer.CharacterAdded:Connect(function()
    killerState.target = nil
    killerState.targetPlayer = nil
    killerState.hitCount = {}
    killerState.state = "idle"

    survivorState.currentGen = nil
    survivorState.state = "idle"
    survivorState.lastGenCheck = 0

    MOVE.waypoints = {}
    MOVE.index = 1
    MOVE.lastTargetPos = nil
    MOVE.lastPos = nil

    releaseShift()
    unlockCamera()
    stopAutoSkillCheckAI()
end)

-- ============================================================================
-- KILL SWITCH
-- ============================================================================
_G.KemiAI_Stop = function()
    if mainConn then mainConn:Disconnect() mainConn = nil end
    stopAutoSkillCheckAI()
    stopMoving()
    unlockCamera()
    releaseShift()
    if readyGui then pcall(function() readyGui:Destroy() end) readyGui = nil end
    print("[KemiAI] Stopped")
end

print("[KemiAI] AI v2 ready — role-reactive core loaded")