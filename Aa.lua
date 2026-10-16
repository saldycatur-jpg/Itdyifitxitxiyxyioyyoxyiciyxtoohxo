--// MINI RUNNING TEXT GUI
--// Dibuat oleh Kemi

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- Hapus GUI lama jika ada
local oldGui = playerGui:FindFirstChild("MiniRunningGUI")
if oldGui then
    oldGui:Destroy()
end

-- ScreenGui
local gui = Instance.new("ScreenGui")
gui.Name = "MiniRunningGUI"
gui.ResetOnSpawn = false
gui.Parent = playerGui

-- Frame utama
local frame = Instance.new("Frame")
frame.Name = "MainFrame"
frame.Size = UDim2.new(0, 230, 0, 45)
frame.Position = UDim2.new(0.5, -115, 0.15, 0)
frame.BackgroundColor3 = Color3.fromRGB(18, 20, 28)
frame.BorderSizePixel = 0
frame.ClipsDescendants = true
frame.Parent = gui

local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 8)
corner.Parent = frame

-- Garis aksen
local stroke = Instance.new("UIStroke")
stroke.Color = Color3.fromRGB(0, 220, 255)
stroke.Thickness = 1
stroke.Parent = frame

-- Area teks berjalan
local textArea = Instance.new("Frame")
textArea.Size = UDim2.new(1, -38, 1, 0)
textArea.Position = UDim2.new(0, 8, 0, 0)
textArea.BackgroundTransparency = 1
textArea.ClipsDescendants = true
textArea.Parent = frame

-- Teks
local text = Instance.new("TextLabel")
text.Size = UDim2.new(0, 400, 1, 0)
text.Position = UDim2.new(1, 0, 0, 0)
text.BackgroundTransparency = 1
text.Text = "WELCOME SCRIPT BY KEMI  |  SYSTEM READY  |  "
text.TextColor3 = Color3.fromRGB(0, 230, 255)
text.Font = Enum.Font.GothamMedium
text.TextSize = 13
text.TextXAlignment = Enum.TextXAlignment.Left
text.TextWrapped = false
text.Parent = textArea

-- Tombol Close
local close = Instance.new("TextButton")
close.Size = UDim2.new(0, 28, 0, 28)
close.Position = UDim2.new(1, -33, 0.5, -14)
close.BackgroundColor3 = Color3.fromRGB(38, 42, 52)
close.Text = "X"
close.TextColor3 = Color3.fromRGB(255, 90, 100)
close.Font = Enum.Font.GothamBold
close.TextSize = 12
close.AutoButtonColor = true
close.Parent = frame

local closeCorner = Instance.new("UICorner")
closeCorner.CornerRadius = UDim.new(0, 6)
closeCorner.Parent = close

-- Animasi teks berjalan
local running = true

task.spawn(function()
    while running and gui.Parent do
        text.Position = UDim2.new(1, 0, 0, 0)

        local tween = TweenService:Create(
            text,
            TweenInfo.new(
                8,
                Enum.EasingStyle.Linear,
                Enum.EasingDirection.Out
            ),
            {
                Position = UDim2.new(0, -400, 0, 0)
            }
        )

        tween:Play()
        tween.Completed:Wait()
    end
end)

-- Tutup GUI
close.Activated:Connect(function()
    running = false

    local tween = TweenService:Create(
        frame,
        TweenInfo.new(0.2),
        {
            BackgroundTransparency = 1,
            Size = UDim2.new(0, 0, 0, 0)
        }
    )

    tween:Play()
    tween.Completed:Wait()

    gui:Destroy()
end)
