local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local VirtualUser = game:GetService("VirtualUser")

local cloneref = (cloneref or clonereference or function(instance)
    return instance
end)
local ReplicatedStorage = cloneref(game:GetService("ReplicatedStorage"))

-- ============================================================================
-- 1. LOAD CONFIGS & MODULES
-- ============================================================================
local HalloweenConfig = nil
pcall(function()
    HalloweenConfig = require(ReplicatedStorage.Configs.HalloweenConfig)
end)

local FlightConfig = nil
pcall(function()
    FlightConfig = require(ReplicatedStorage.Configs.FlightConfig)
end)

local EventBus = nil
pcall(function()
    EventBus = require(ReplicatedStorage.Packages.EventBus)
end)

-- Safe Broom flight speed from game config
local BROOM_DEFAULT_SPEED = (FlightConfig and FlightConfig.Speed) or 90

-- Safe resting spot on Halloween Island
local HALLOWEEN_RESTING_POS = Vector3.new(885, 65, 230)

-- ============================================================================
-- 2. LOAD WINDUI
-- ============================================================================
local WindUI
do
    local ok, result = pcall(function()
        return require("./src/Init")
    end)

    if ok then
        WindUI = result
    else
        if cloneref(game:GetService("RunService")):IsStudio() then
            WindUI = require(cloneref(ReplicatedStorage:WaitForChild("WindUI"):WaitForChild("Init")))
        else
            WindUI = loadstring(game:HttpGet("https://raw.githubusercontent.com/Footagesus/WindUI/main/dist/main.lua"))()
        end
    end
end

-- ============================================================================
-- 3. WINDOW CREATION
-- ============================================================================
if getgenv()._AntEmpireWindUI then
    pcall(function()
        if getgenv()._AntEmpireWindUI.Destroy then
            getgenv()._AntEmpireWindUI:Destroy()
        elseif getgenv()._AntEmpireWindUI.Close then
            getgenv()._AntEmpireWindUI:Close()
        end
    end)
    getgenv()._AntEmpireWindUI = nil
end

local Window = WindUI:CreateWindow({
    Title = "Build An Ant Empire made by x2sun and Ud0",
    Folder = "antempirehub",
    Icon = "solar:cup-star-bold-duotone",
    NewElements = true,
    HideSearchBar = false,

    OpenButton = {
        Title = "Open Menu",
        CornerRadius = UDim.new(1, 0),
        StrokeThickness = 3,
        Enabled = true,
        Draggable = true,
        OnlyMobile = false,
        Scale = 0.5,

        Color = ColorSequence.new(
            Color3.fromHex("#ff8800"),
            Color3.fromHex("#ffbb00")
        ),
    },
    Topbar = {
        Height = 44,
        ButtonsType = "Mac",
    },
})

getgenv()._AntEmpireWindUI = Window

do
    Window:Tag({
        Title = "v1",
        Icon = "github",
        Color = Color3.fromHex("#1c1c1c"),
        Border = true,
    })
end

local Grey = Color3.fromHex("#83889E")

-- Cleanup existing worker
if getgenv().AntEmpireCandyEngine and getgenv().AntEmpireCandyEngine.Stop then
    pcall(getgenv().AntEmpireCandyEngine.Stop)
end
if getgenv()._AntCandyWorker then
    pcall(task.cancel, getgenv()._AntCandyWorker)
    getgenv()._AntCandyWorker = nil
end
if getgenv()._AntNoclipConn then
    pcall(function() getgenv()._AntNoclipConn:Disconnect() end)
    getgenv()._AntNoclipConn = nil
end

-- ============================================================================
-- 4. CONFIGURATION STATE
-- ============================================================================
getgenv().AntCandyConfig = getgenv().AntCandyConfig or {
    IsRunning = false,
    FlyMode = "Realistic", -- "Realistic" (90 studs/s broom speed) or "Instant" (Teleport)
    FlightSpeed = BROOM_DEFAULT_SPEED, -- studs/sec
    CollectDelay = 0.25, -- Seconds to wait before opening next chest
    AntiAfk = true,
    Status = "Idle",
    CollectedCount = 0,
    RemainingChests = 0
}

local Config = getgenv().AntCandyConfig

-- ============================================================================
-- 5. ANTI-AFK HANDLER
-- ============================================================================
if not getgenv()._AntAntiAfkConn then
    getgenv()._AntAntiAfkConn = LocalPlayer.Idled:Connect(function()
        if Config.AntiAfk then
            VirtualUser:CaptureController()
            VirtualUser:ClickButton2(Vector2.zero)
        end
    end)
end

-- ============================================================================
-- 6. NOCLIP MANAGER
-- ============================================================================
local function EnableNoclip()
    if getgenv()._AntNoclipConn then return end
    getgenv()._AntNoclipConn = RunService.Stepped:Connect(function()
        if not Config.IsRunning then return end
        local char = LocalPlayer.Character
        if char then
            for _, part in ipairs(char:GetDescendants()) do
                if part:IsA("BasePart") and part.CanCollide then
                    part.CanCollide = false
                end
            end
        end
    end)
end

local function DisableNoclip()
    if getgenv()._AntNoclipConn then
        pcall(function() getgenv()._AntNoclipConn:Disconnect() end)
        getgenv()._AntNoclipConn = nil
    end
    local char = LocalPlayer.Character
    if char then
        for _, part in ipairs(char:GetDescendants()) do
            if part:IsA("BasePart") then
                part.CanCollide = true
            end
        end
    end
end

-- ============================================================================
-- 7. HELPER FUNCTIONS & CHEST ACQUISITION
-- ============================================================================
local function GetCharParts()
    local char = LocalPlayer.Character
    if not char then return nil, nil end
    local hrp = char:FindFirstChild("HumanoidRootPart")
    local hum = char:FindFirstChild("Humanoid")
    return hrp, hum
end

local function GetAvailablePumpkinChests()
    local hrp, _ = GetCharParts()
    local chests = {}

    for _, obj in ipairs(Workspace:GetChildren()) do
        if obj.Name == "Treasure" and obj:IsA("Model") then
            local prompt = obj:FindFirstChildWhichIsA("ProximityPrompt", true)
            local part = prompt and prompt.Parent
            if prompt and prompt.Enabled and part and part:IsA("BasePart") then
                local dist = hrp and (part.Position - hrp.Position).Magnitude or 0
                table.insert(chests, {
                    Model = obj,
                    Prompt = prompt,
                    Part = part,
                    Position = part.Position,
                    Distance = dist
                })
            end
        end
    end

    table.sort(chests, function(a, b)
        return a.Distance < b.Distance
    end)

    return chests
end

-- ============================================================================
-- 8. SAFE MOVEMENT CONTROLLER (BROOM SPEED GLIDE VS INSTANT)
-- ============================================================================
local activeMoveConn = nil

local function StopMovement()
    if activeMoveConn then
        pcall(function() activeMoveConn:Disconnect() end)
        activeMoveConn = nil
    end
    local hrp, _ = GetCharParts()
    if hrp then
        hrp.AssemblyLinearVelocity = Vector3.zero
        hrp.AssemblyAngularVelocity = Vector3.zero
    end
end

local function MoveToTarget(targetPos, arrivalDistance)
    arrivalDistance = arrivalDistance or 3.0
    local hrp, hum = GetCharParts()
    if not hrp or not hum or hum.Health <= 0 then return false end

    StopMovement()
    EnableNoclip()

    -- Instant Teleport Mode
    if Config.FlyMode == "Instant" then
        hrp.AssemblyLinearVelocity = Vector3.zero
        hrp.AssemblyAngularVelocity = Vector3.zero
        hrp.CFrame = CFrame.new(targetPos + Vector3.new(0, 1.5, 0))
        task.wait(0.1)
        return true
    end

    -- Realistic Broom Flight Mode (90 studs/sec - matches game config, completely safe)
    local speed = math.clamp(Config.FlightSpeed or BROOM_DEFAULT_SPEED, 30, 200)
    local startPos = hrp.Position
    local totalDist = (targetPos - startPos).Magnitude
    local maxDuration = (totalDist / speed) + 4.0
    local t0 = os.clock()
    local arrived = false

    activeMoveConn = RunService.Heartbeat:Connect(function(dt)
        if not Config.IsRunning or not hrp or not hrp.Parent or hum.Health <= 0 then
            arrived = true
            StopMovement()
            return
        end

        local curPos = hrp.Position
        local delta = targetPos - curPos
        local dist = delta.Magnitude

        if dist <= arrivalDistance or (os.clock() - t0 > maxDuration) then
            arrived = true
            StopMovement()
            return
        end

        local dir = delta.Unit
        hrp.AssemblyLinearVelocity = dir * speed
        hrp.AssemblyAngularVelocity = Vector3.zero
        hrp.CFrame = CFrame.new(curPos, curPos + dir)
    end)

    while not arrived and Config.IsRunning and hrp and hum.Health > 0 and (os.clock() - t0 <= maxDuration) do
        task.wait(0.03)
    end

    StopMovement()
    hrp.CFrame = CFrame.new(targetPos)
    task.wait(0.05)
    return true
end

-- ============================================================================
-- 9. AUTONOMOUS CANDY COLLECTION ENGINE
-- ============================================================================
local workerThread = nil

local function OpenPumpkinChest(chest)
    local prompt = chest.Prompt
    if not prompt or not prompt.Parent or not prompt.Enabled then return end

    local hrp, hum = GetCharParts()
    if not hrp or not hum then return end

    -- Position character slightly above chest
    local openPos = chest.Position + Vector3.new(0, 2.0, 0)
    hrp.AssemblyLinearVelocity = Vector3.zero
    hrp.CFrame = CFrame.new(openPos, chest.Position)

    task.wait(0.1)

    -- Trigger proximity prompt
    pcall(function()
        fireproximityprompt(prompt, 0)
    end)

    -- Wait until prompt disables (confirming server open)
    local t0 = os.clock()
    while prompt.Enabled and (os.clock() - t0 < 1.2) and Config.IsRunning do
        task.wait(0.05)
    end

    Config.CollectedCount = Config.CollectedCount + 1
    task.wait(math.clamp(Config.CollectDelay, 0.1, 1.5))
end

local function StartCandyWorker()
    if workerThread then
        task.cancel(workerThread)
        workerThread = nil
    end

    Config.IsRunning = true
    EnableNoclip()

    workerThread = task.spawn(function()
        while Config.IsRunning do
            local hrp, hum = GetCharParts()
            if not hrp or not hum or hum.Health <= 0 then
                task.wait(1)
                continue
            end

            local availableChests = GetAvailablePumpkinChests()
            Config.RemainingChests = #availableChests

            if #availableChests > 0 then
                for idx, chest in ipairs(availableChests) do
                    if not Config.IsRunning then break end
                    if not chest.Prompt or not chest.Prompt.Enabled then continue end

                    Config.Status = string.format("กำลังบินไปเปิด Pumpkin Chest [%d/%d] (ระยะ %.0f studs)...", idx, #availableChests, chest.Distance)
                    
                    local arrived = MoveToTarget(chest.Position + Vector3.new(0, 2.5, 0), 4.0)
                    if arrived and Config.IsRunning and chest.Prompt and chest.Prompt.Enabled then
                        Config.Status = string.format("กำลังเก็บ Candy จากหีบ [%d/%d]...", idx, #availableChests)
                        OpenPumpkinChest(chest)
                    end

                    task.wait(0.05)
                end
            else
                Config.Status = "เก็บ Candy หมดเกาะแล้ว กำลังรอ Pumpkin Chest เกิดใหม่..."
                -- Fly to safe observation position on the Halloween Island
                local curDist = (hrp.Position - HALLOWEEN_RESTING_POS).Magnitude
                if curDist > 15 then
                    MoveToTarget(HALLOWEEN_RESTING_POS, 5.0)
                end
                task.wait(1.5)
            end

            task.wait(0.2)
        end

        StopMovement()
        DisableNoclip()
        Config.Status = "Idle"
    end)

    getgenv()._AntCandyWorker = workerThread
end

local function StopCandyWorker()
    Config.IsRunning = false
    Config.Status = "Stopped"
    if workerThread then
        task.cancel(workerThread)
        workerThread = nil
    end
    if getgenv()._AntCandyWorker then
        pcall(task.cancel, getgenv()._AntCandyWorker)
        getgenv()._AntCandyWorker = nil
    end
    StopMovement()
    DisableNoclip()
end

getgenv().AntEmpireCandyEngine = {
    Start = StartCandyWorker,
    Stop = StopCandyWorker,
    GetChests = GetAvailablePumpkinChests
}

-- ============================================================================
-- 10. WINDUI HOME TAB & CONTROLS
-- ============================================================================
local HomeTab = Window:Tab({
    Title = "Home",
    Desc = "Autonomous Halloween Candy Harvester",
    Icon = "solar:star-fall-bold",
    IconColor = Grey,
    IconShape = "Square",
    Border = true,
})

local StatusLabel = HomeTab:Paragraph({
    Title = "สถานะระบบฟาร์ม Candy",
    Desc = "Status: Idle",
})

local StatsLabel = HomeTab:Paragraph({
    Title = "สถิติการเก็บ Candy",
    Desc = "เปิดหีบแล้ว: 0 ใบ | หีบที่เหลือในแมพ: 0 ใบ",
})

task.spawn(function()
    while true do
        if StatusLabel and StatusLabel.SetDesc then
            pcall(function()
                StatusLabel:SetDesc("สถานะ: " .. tostring(Config.Status))
            end)
        end
        if StatsLabel and StatsLabel.SetDesc then
            pcall(function()
                StatsLabel:SetDesc(string.format(
                    "เปิดหีบสำเร็จ: %d ใบ\nหีบ Candy ที่พร้อมเก็บในแมพ: %d ใบ",
                    Config.CollectedCount,
                    Config.RemainingChests
                ))
            end)
        end
        task.wait(0.5)
    end
end)

HomeTab:Toggle({
    Title = "เปิดระบบ Auto Farm Candy",
    Desc = "บินหาและเก็บ Candy จาก Pumpkin Chest ทั่วทั้งแมพฮาโลวีนอัตโนมัติ (วนลูปตลอดเวลา)",
    Value = Config.IsRunning,
    Callback = function(val)
        if val then
            StartCandyWorker()
        else
            StopCandyWorker()
        end
    end
})

HomeTab:Dropdown({
    Title = "โหมดการเคลื่อนที่",
    Desc = "เลือกรูปแบบการบินเก็บหีบ",
    Values = {
        "บินสมจริง (Broom Speed 90 studs/s - ปลอดภัย 100% แนะนำ)",
        "วาร์ปทันที (Instant Teleport)"
    },
    Value = "บินสมจริง (Broom Speed 90 studs/s - ปลอดภัย 100% แนะนำ)",
    Multi = false,
    AllowNone = false,
    Callback = function(val)
        if val:find("บินสมจริง") then
            Config.FlyMode = "Realistic"
        else
            Config.FlyMode = "Instant"
        end
    end
})

HomeTab:Slider({
    Title = "ความเร็วในการบิน (Studs/sec)",
    Desc = "ความเร็วการบินแบบสมจริง (ค่ามาตรฐาน 90 studs/s เท่ากับไม้กวาดในเกม)",
    Step = 5,
    Value = {
        Min = 40,
        Max = 180,
        Default = 90,
    },
    Callback = function(val)
        Config.FlightSpeed = val
    end
})

HomeTab:Slider({
    Title = "ระยะเวลาหน่วงก่อนเปิดหีบถัดไป (Delay)",
    Desc = "ปรับความหน่วงเพื่อความปลอดภัยและลดภาระเซิร์ฟเวอร์",
    Step = 0.05,
    Value = {
        Min = 0.1,
        Max = 1.0,
        Default = 0.25,
    },
    Callback = function(val)
        Config.CollectDelay = val
    end
})

HomeTab:Toggle({
    Title = "ระบบ Anti-AFK",
    Desc = "ป้องกันหลุดออกจากเกมกรณีปล่อยฟาร์มยาวเกิน 20 นาที",
    Value = Config.AntiAfk,
    Callback = function(val)
        Config.AntiAfk = val
    end
})
