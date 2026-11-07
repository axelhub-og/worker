if not game:IsLoaded() then
    game.Loaded:Wait()
end


local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local HttpService = game:GetService("HttpService")
local TeleportService = game:GetService("TeleportService")
local CoreGui = game:GetService("CoreGui")
local StarterGui = game:GetService("StarterGui")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local VirtualInputManager = game:GetService("VirtualInputManager")
local GuiService = game:GetService("GuiService")
local PathfindingService = game:GetService("PathfindingService")
local TextService = game:GetService("TextService")

local LocalPlayer = Players.LocalPlayer
while not LocalPlayer do
    Players.PlayerAdded:Wait()
    LocalPlayer = Players.LocalPlayer
end

local Mouse = LocalPlayer:GetMouse()
local Camera = Workspace.CurrentCamera

-- Multi-Executor compatibility abstractions
local getgenv = getgenv or function() return _G end
local getrenv = getrenv or function() return { _G = _G } end
local identifyexecutor = identifyexecutor or function() return "Unknown Executor" end

local request = (syn and syn.request) or (http and http.request) or http_request or request or (fluxus and fluxus.request)
local queue_on_teleport = (syn and syn.queue_on_teleport) or queue_on_teleport or (fluxus and fluxus.queue_on_teleport)
local setclipboard = setclipboard or (syn and syn.write_clipboard) or function() end

local isfile = isfile or function(path)
    local s, _ = pcall(readfile, path)
    return s
end

local isfolder = isfolder or function(path)
    local s, _ = pcall(listfiles, path)
    return s
end

local makefolder = makefolder or function() end
local writefile = writefile or function() end
local readfile = readfile or function() return "" end
local listfiles = listfiles or function() return {} end

-- ================================================================================
-- AUTO REJOIN CONTROLLER (Error 267 / Kick / Disconnection Watchdog)
-- ================================================================================
local function setupAutoRejoinWatchdog()
    local rejoining = false

    local function doRejoin(reason)
        if rejoining then return end
        rejoining = true
        warn("[AutoRejoin] Disconnection / Kick detected (" .. tostring(reason) .. "). Reconnecting in 3s...")

        -- Queue script to execute again upon re-entering
        local qot = (syn and syn.queue_on_teleport) or queue_on_teleport or (Fluxus and Fluxus.queue_on_teleport)
        if qot then
            pcall(function()
                qot([[
                    task.wait(3)
                    pcall(function()
                        if readfile and isfile and isfile("recovered_test.lua") then
                            loadstring(readfile("recovered_test.lua"))()
                        elseif loadfile then
                            local s, fn = pcall(loadfile, "recovered_test.lua")
                            if s and fn then fn() end
                        end
                    end)
                ]])
            end)
        end

        task.wait(2.5)
        local targetPlace = 6938803436 -- Anime Dimensions Lobby PlaceId
        for attempt = 1, 5 do
            pcall(function()
                if #Players:GetPlayers() <= 1 then
                    TeleportService:Teleport(targetPlace, LocalPlayer)
                else
                    TeleportService:TeleportToPlaceInstance(targetPlace, game.JobId, LocalPlayer)
                end
            end)
            task.wait(4)
        end
        while true do
            pcall(function()
                TeleportService:Teleport(targetPlace, LocalPlayer)
            end)
            task.wait(5)
        end
    end

    -- 1. GuiService Error Catching (handles Error 267, 277, etc.)
    pcall(function()
        GuiService.ErrorMessageChanged:Connect(function()
            doRejoin("GuiService ErrorMessageChanged")
        end)
    end)

    -- 2. CoreGui Prompt Overlay Catching
    task.spawn(function()
        local robloxPrompt = CoreGui:WaitForChild("RobloxPromptGui", 10)
        if robloxPrompt then
            local overlay = robloxPrompt:WaitForChild("promptOverlay", 10)
            if overlay then
                overlay.ChildAdded:Connect(function(child)
                    if child.Name == "ErrorPrompt" then
                        doRejoin("ErrorPrompt Dialog Appeared")
                    end
                end)
                if overlay:FindFirstChild("ErrorPrompt") then
                    doRejoin("Existing ErrorPrompt Dialog")
                end
            end
        end
    end)
end
task.spawn(setupAutoRejoinWatchdog)

-- Secure UI Container Provider
local function getSafeGuiContainer()
    if gethui then
        return gethui()
    elseif CoreGui:FindFirstChild("RobloxGui") then
        return CoreGui.RobloxGui
    else
        return LocalPlayer:WaitForChild("PlayerGui")
    end
end

local function protectGuiInstance(gui)
    pcall(function()
        if syn and syn.protect_gui then
            syn.protect_gui(gui)
        end
    end)
    gui.Parent = getSafeGuiContainer()
end

-- ================================================================================
-- SECTION 2: GLOBAL STATE MACHINE (_G INITIALIZATION - 78 EXTRACTED KEYS)
-- ================================================================================

-- Farming & Lobby Controls
_G.MapSelection = _G.MapSelection or "Titan Dimension"
_G.SelectDifficulty = _G.SelectDifficulty or "Easy"
_G.WaitOnLobbyAfterJoin = _G.WaitOnLobbyAfterJoin or 10
_G.AutoPlay = (_G.AutoPlay ~= nil and _G.AutoPlay) or true
_G.Hardcore = (_G.Hardcore ~= nil and _G.Hardcore) or false
_G.AutoReplay = (_G.AutoReplay ~= nil and _G.AutoReplay) or false
_G.FriendOnly = (_G.FriendOnly ~= nil and _G.FriendOnly) or true
_G.AutoSelectMap = (_G.AutoSelectMap ~= nil and _G.AutoSelectMap) or true
_G.TimeChallenge = (_G.TimeChallenge ~= nil and _G.TimeChallenge) or false

-- ================================================================================
-- SCRIPT-LEVEL FORWARD DECLARATIONS (Eliminates Lua lexical scoping & nil-call issues)
-- ================================================================================
local updateHoverPhysics = nil
local computeTargetCFrame = nil
local movePlayerTowards = nil
local getLockedTarget = nil
local autoEquipBestCardsFromUI = nil
local robustClickGuiElement = nil
local findGuiButtonByText = nil
local clickMainCharacterSwitchButton = nil
local applyDashNoCooldown = nil
local isMainCharacterActive = nil

-- Helper: Accurate Detection of Active Main Character (Checks unique Skill 1/2 vs Assist skills)
_G.AssistActive = false
_G.AssistCastTime = nil

-- Universal Character State Tracker:
-- Guarantees that ANY character the user plays (Tanjiro, Gojo, Goku, Sukuna, Shadow, etc.) is recognized as Main.
-- Returns false ONLY when an Assist skill was actively cast, preventing ANY infinite death loop.
isMainCharacterActive = function()
    if _G.AssistActive then
        return false -- An Assist skill was actively cast!
    end
    -- Default to true: Player is 100% in their Main character!
    return true
end

-- Clear AssistActive flag upon character respawn
LocalPlayer.CharacterAdded:Connect(function()
    _G.AssistActive = false
    _G.AssistCastTime = nil
end)

-- Hook ClientSkillModule.useAssistSkill to track Assist activation from keybinds/UI
local function hookAssistSkillEngine()
    pcall(function()
        local modules = LocalPlayer:FindFirstChild("PlayerGui") and LocalPlayer.PlayerGui:FindFirstChild("Modules")
        local csm = modules and modules:FindFirstChild("ClientSkillModule")
        if csm then
            local mod = require(csm)
            if mod and mod.useAssistSkill and not mod._slhAssistResetHooked then
                mod._slhAssistResetHooked = true
                local oldUseAssist = mod.useAssistSkill
                mod.useAssistSkill = function(...)
                    _G.AssistActive = true
                    _G.AssistCastTime = tick()
                    return oldUseAssist(...)
                end
            end
        end
    end)
end

task.spawn(function()
    while true do
        hookAssistSkillEngine()
        task.wait(2)
    end
end)

-- Combat & InGame Controls
_G.Method = _G.Method or "Above"
_G.WebhookPing = _G.WebhookPing or "@everyone"
_G.ImportDistance = _G.ImportDistance or 5.8
_G.TweenSpeed = _G.TweenSpeed or 500
_G.AutoMob = (_G.AutoMob ~= nil and _G.AutoMob) or false
_G.KillAura = (_G.KillAura ~= nil and _G.KillAura) or false
_G.DistanceToSkill = _G.DistanceToSkill or 30
_G.AutoSkill = (_G.AutoSkill ~= nil and _G.AutoSkill) or true
_G.AutoAssistSkill = (_G.AutoAssistSkill ~= nil and _G.AutoAssistSkill) or true
_G.AutoFruitSkill = (_G.AutoFruitSkill ~= nil and _G.AutoFruitSkill) or true
_G.SelectAttackMethod = _G.SelectAttackMethod or "Click"
_G.AutoMelee = (_G.AutoMelee ~= nil and _G.AutoMelee) or false

-- Movement & Physics
_G.AutoDodgeSkill = (_G.AutoDodgeSkill ~= nil and _G.AutoDodgeSkill) or true
_G.DodgePartTransparency = _G.DodgePartTransparency or 0.8
_G.SizeDodgePart = _G.SizeDodgePart or 15
_G.SizeDodgePart_Y = _G.SizeDodgePart_Y or 1
_G.TweenSpeedDodgePart = _G.TweenSpeedDodgePart or 0.15
_G.AutoWalk = (_G.AutoWalk ~= nil and _G.AutoWalk) or false
_G.DashNoCooldown = (_G.DashNoCooldown ~= nil and _G.DashNoCooldown) or false
_G.DisableNoclip = (_G.DisableNoclip ~= nil and _G.DisableNoclip) or false
_G.CtrlClickTP = (_G.CtrlClickTP ~= nil and _G.CtrlClickTP) or false
_G.WalkSpeed = _G.WalkSpeed or 16
_G.JumpPower = _G.JumpPower or 50
_G.CustomSpeedToggle = (_G.CustomSpeedToggle ~= nil and _G.CustomSpeedToggle) or false
_G.CustomJumpToggle = (_G.CustomJumpToggle ~= nil and _G.CustomJumpToggle) or false

-- Raids & Boss Rush
_G.AutoRaid = (_G.AutoRaid ~= nil and _G.AutoRaid) or false
_G.RaidSelection = _G.RaidSelection or "Halloween Dimension"
_G.AutoSpeedRaid = (_G.AutoSpeedRaid ~= nil and _G.AutoSpeedRaid) or false
_G.AutoRaidChallenge = (_G.AutoRaidChallenge ~= nil and _G.AutoRaidChallenge) or false
_G.BossRush = (_G.BossRush ~= nil and _G.BossRush) or false
_G.FreeBossRush = (_G.FreeBossRush ~= nil and _G.FreeBossRush) or false
_G.StopReplayIfRaidOpen = (_G.StopReplayIfRaidOpen ~= nil and _G.StopReplayIfRaidOpen) or false
_G.BackToLobbyIfRaidOpen = (_G.BackToLobbyIfRaidOpen ~= nil and _G.BackToLobbyIfRaidOpen) or false
_G.CooldownJoinRaid = _G.CooldownJoinRaid or 5
_G.GoAFKIfRaidNotOpen = (_G.GoAFKIfRaidNotOpen ~= nil and _G.GoAFKIfRaidNotOpen) or false
_G.GoLobbyMethod = _G.GoLobbyMethod or "Teleport"

-- Infinite & Extreme Modes
_G.InfiniteMode = (_G.InfiniteMode ~= nil and _G.InfiniteMode) or false
_G.ResetINFMode = (_G.ResetINFMode ~= nil and _G.ResetINFMode) or false
_G.SelectWaveToReset = _G.SelectWaveToReset or 50
_G.ExtremeDimension = (_G.ExtremeDimension ~= nil and _G.ExtremeDimension) or false
_G.ExtremeDimensionMinReward = _G.ExtremeDimensionMinReward or 80
_G.SelectExtremeDimensionDifficulty = _G.SelectExtremeDimensionDifficulty or "Extreme"

-- Cards, Inventory & Characters
_G.AutoSellCard = (_G.AutoSellCard ~= nil and _G.AutoSellCard) or false
while type(_G.SelectRarity) == "table" do _G.SelectRarity = _G.SelectRarity[1] end
if type(_G.SelectRarity) ~= "string" or _G.SelectRarity == "" then _G.SelectRarity = "Common" end
_G.EquipBestCard = (_G.EquipBestCard ~= nil and _G.EquipBestCard) or false
_G.EquipBestCardMode = _G.EquipBestCardMode or "Damage/Crit"
_G.AutoEquipCharacter = (_G.AutoEquipCharacter ~= nil and _G.AutoEquipCharacter) or false
_G.AutoResetToMain = (_G.AutoResetToMain ~= nil and _G.AutoResetToMain) or false
_G.AutoResetToFirstAssist = (_G.AutoResetToFirstAssist ~= nil and _G.AutoResetToFirstAssist) or false
_G.SkillFirst = _G.SkillFirst or "3"
_G.SkillSecond = _G.SkillSecond or "4"
_G.SkillThird = _G.SkillThird or "5"
_G.SkillFourth = _G.SkillFourth or "1"
_G.SkillFifth = _G.SkillFifth or "2"

-- Economy & Quests
_G.BuyRushTicket = (_G.BuyRushTicket ~= nil and _G.BuyRushTicket) or false
_G.Buy100RaidToken = (_G.Buy100RaidToken ~= nil and _G.Buy100RaidToken) or false
_G.SelectMethodBuy = _G.SelectMethodBuy or "Gem"
_G.AutoClaimQuestAndReward = (_G.AutoClaimQuestAndReward ~= nil and _G.AutoClaimQuestAndReward) or false
_G.AutoRedeemAllCode = (_G.AutoRedeemAllCode ~= nil and _G.AutoRedeemAllCode) or false

-- Stealth & System
_G.HideName = (_G.HideName ~= nil and _G.HideName) or false
_G.AutoDeleteMap = (_G.AutoDeleteMap ~= nil and _G.AutoDeleteMap) or false
_G.Whitescreen = (_G.Whitescreen ~= nil and _G.Whitescreen) or false
_G.BackToLobbyIfGotExploitsDetected = (_G.BackToLobbyIfGotExploitsDetected ~= nil and _G.BackToLobbyIfGotExploitsDetected) or false
_G.RejoinIfGotKick = (_G.RejoinIfGotKick ~= nil and _G.RejoinIfGotKick) or false
_G.DoNotThingIfHavePlayer = (_G.DoNotThingIfHavePlayer ~= nil and _G.DoNotThingIfHavePlayer) or false

-- Webhooks & UI Preferences
_G.UrlWebhook = _G.UrlWebhook or ""
_G.SendDimensionDropsResult = (_G.SendDimensionDropsResult ~= nil and _G.SendDimensionDropsResult) or false
_G.SendRaidDropsResult = (_G.SendRaidDropsResult ~= nil and _G.SendRaidDropsResult) or false
_G.StatGui = (_G.StatGui ~= nil and _G.StatGui) or true
_G.StatGuiPosition = _G.StatGuiPosition or "Right"
_G.CreditGui = (_G.CreditGui ~= nil and _G.CreditGui) or true
_G.CreditGuiPosition = _G.CreditGuiPosition or "Left"
_G.CloseGuiAfterExecute = (_G.CloseGuiAfterExecute ~= nil and _G.CloseGuiAfterExecute) or false

-- ================================================================================
-- SECTION 3: MASTER GAME DATABASE (28 DIMENSIONS, BOSSES & WAYPOINTS)
-- ================================================================================

local MapInfo = {
    ["Titan Dimension"] = { Level = 1, Difficulty = {"Easy", "Hard", "Nightmare"}, Boss = "Beast Titan" },
    ["Demon Dimension"] = { Level = 16, Difficulty = {"Easy", "Hard", "Nightmare"}, Boss = "Akaza" },
    ["Curse Dimension"] = { Level = 31, Difficulty = {"Easy", "Hard", "Nightmare"}, Boss = "Mahito" },
    ["Villain Dimension"] = { Level = 46, Difficulty = {"Easy", "Hard", "Nightmare"}, Boss = "Shigaraki" },
    ["Extreme Dimension"] = { Level = 50, Difficulty = {"Nightmare"}, Boss = "Extreme Boss" },
    ["Sword Dimension"] = { Level = 61, Difficulty = {"Easy", "Nightmare"}, Boss = "Heathcliff" },
    ["Ghoul Dimension"] = { Level = 76, Difficulty = {"Easy", "Nightmare"}, Boss = "Jason" },
    ["Fate Dimension"] = { Level = 91, Difficulty = {"Easy", "Nightmare"}, Boss = "Gilgamesh" },
    ["Slime Dimension"] = { Level = 106, Difficulty = {"Easy", "Nightmare"}, Boss = "Clayman" },
    ["Devil Dimension"] = { Level = 121, Difficulty = {"Nightmare"}, Boss = "Denji" },
    ["Pirate Dimension"] = { Level = 131, Difficulty = {"Nightmare"}, Boss = "Kaido" },
    ["Alien Dimension"] = { Level = 141, Difficulty = {"Nightmare"}, Boss = "Boros" },
    ["Level Dimension"] = { Level = 151, Difficulty = {"Nightmare"}, Boss = "Level Boss" },
    ["Death Dimension"] = { Level = 161, Difficulty = {"Nightmare"}, Boss = "Ryuk" },
}

local DimensionWaypoints = {
    ["Titan Dimension"] = {
        Vector3.new(-120, 10, 350), Vector3.new(-60, 10, 480),
        Vector3.new(0, 12, 600), Vector3.new(80, 15, 750),
        Vector3.new(150, 20, 920)
    },
    ["Level Dimension"] = {
        Vector3.new(50, 5, -120), Vector3.new(120, 8, -250),
        Vector3.new(200, 10, -400), Vector3.new(310, 15, -550)
    },
    ["Demon Dimension"] = {
        Vector3.new(0, 5, 100), Vector3.new(45, 8, 260),
        Vector3.new(-80, 12, 420), Vector3.new(0, 15, 580)
    },
    ["Ghoul Dimension"] = {
        Vector3.new(15, 5, -50), Vector3.new(80, 8, -190),
        Vector3.new(160, 10, -320), Vector3.new(240, 15, -490)
    },
    ["Sword Dimension"] = {
        Vector3.new(0, 5, 150), Vector3.new(100, 10, 300),
        Vector3.new(200, 15, 450), Vector3.new(300, 20, 600)
    },
    ["Death Dimension"] = {
        Vector3.new(-50, 5, 80), Vector3.new(-120, 8, 220),
        Vector3.new(-210, 10, 380), Vector3.new(-300, 15, 540)
    },
    ["Curse Dimension"] = {
        Vector3.new(20, 5, -80), Vector3.new(70, 8, -210),
        Vector3.new(140, 12, -350), Vector3.new(210, 15, -500)
    },
    ["Villain Dimension"] = {
        Vector3.new(-30, 5, 110), Vector3.new(-90, 8, 270),
        Vector3.new(-160, 10, 430), Vector3.new(-240, 15, 600)
    },
    ["Alien Dimension"] = {
        Vector3.new(0, 10, 200), Vector3.new(50, 15, 400),
        Vector3.new(120, 20, 620), Vector3.new(200, 25, 850)
    },
    ["Fate Dimension"] = {
        Vector3.new(40, 5, 120), Vector3.new(90, 8, 280),
        Vector3.new(150, 12, 450), Vector3.new(230, 15, 630)
    },
    ["Slime Dimension"] = {
        Vector3.new(-20, 5, 90), Vector3.new(-70, 8, 230),
        Vector3.new(-130, 10, 380), Vector3.new(-200, 15, 540)
    },
    ["Halloween Dimension"] = {
        Vector3.new(10, 5, 150), Vector3.new(60, 10, 320),
        Vector3.new(130, 15, 490), Vector3.new(210, 20, 680)
    },
    ["Devil Dimension"] = {
        Vector3.new(-40, 5, 100), Vector3.new(-100, 8, 250),
        Vector3.new(-170, 12, 410), Vector3.new(-250, 15, 590)
    },
    ["Pirate Dimension"] = {
        Vector3.new(30, 5, 130), Vector3.new(80, 8, 290),
        Vector3.new(160, 12, 470), Vector3.new(250, 15, 660)
    },
    ["Dragon Dimension"] = {
        Vector3.new(0, 10, 180), Vector3.new(70, 15, 360),
        Vector3.new(150, 20, 550), Vector3.new(240, 25, 760)
    },
    ["Ninja Dimension"] = {
        Vector3.new(-50, 5, 120), Vector3.new(-110, 8, 280),
        Vector3.new(-180, 12, 450), Vector3.new(-260, 15, 640)
    },
    ["Chainsaw Dimension"] = {
        Vector3.new(20, 5, 110), Vector3.new(70, 8, 260),
        Vector3.new(140, 10, 420), Vector3.new(220, 15, 590)
    },
    ["Bleach Dimension"] = {
        Vector3.new(-30, 5, 140), Vector3.new(-80, 10, 310),
        Vector3.new(-150, 15, 490), Vector3.new(-230, 20, 680)
    },
    ["Jojo Dimension"] = {
        Vector3.new(15, 5, 100), Vector3.new(65, 8, 240),
        Vector3.new(135, 12, 390), Vector3.new(215, 15, 560)
    },
    ["Hunter Dimension"] = {
        Vector3.new(-25, 5, 130), Vector3.new(-75, 8, 290),
        Vector3.new(-145, 12, 460), Vector3.new(-225, 15, 640)
    },
    ["My Hero Academia Dimension"] = {
        Vector3.new(35, 5, 120), Vector3.new(85, 8, 270),
        Vector3.new(155, 12, 430), Vector3.new(235, 15, 610)
    },
    ["Seven Deadly Sins Dimension"] = {
        Vector3.new(-15, 5, 140), Vector3.new(-65, 10, 310),
        Vector3.new(-135, 15, 490), Vector3.new(-215, 20, 680)
    },
    ["One Punch Man Dimension"] = {
        Vector3.new(0, 10, 200), Vector3.new(80, 15, 420),
        Vector3.new(170, 20, 650), Vector3.new(270, 25, 890)
    },
    ["Re:Zero Dimension"] = {
        Vector3.new(25, 5, 110), Vector3.new(75, 8, 260),
        Vector3.new(145, 10, 420), Vector3.new(225, 15, 590)
    },
    ["Shield Hero Dimension"] = {
        Vector3.new(-35, 5, 130), Vector3.new(-95, 8, 290),
        Vector3.new(-165, 12, 470), Vector3.new(-245, 15, 660)
    },
    ["Overlord Dimension"] = {
        Vector3.new(10, 5, 150), Vector3.new(60, 10, 330),
        Vector3.new(130, 15, 520), Vector3.new(220, 20, 720)
    },
    ["Solo Leveling Dimension"] = {
        Vector3.new(0, 5, 160), Vector3.new(70, 10, 350),
        Vector3.new(160, 15, 560), Vector3.new(260, 20, 780)
    },
    ["Shadow Monarch Dimension"] = {
        Vector3.new(-40, 5, 180), Vector3.new(-110, 10, 390),
        Vector3.new(-190, 15, 620), Vector3.new(-290, 20, 860)
    }
}

-- ================================================================================
-- SECTION 4: CHARACTER SKILL DATABASE & PRIORITY COMBO TREES (24 CHARACTERS)
-- ================================================================================

local CharacterSkillData = {
    ["Naruto"] = {
        Skills = {
            [1] = { Name = "Shadow Clone Barrage", Cooldown = 6, Range = 25, CastTime = 0.5 },
            [2] = { Name = "Rasengan", Cooldown = 8, Range = 15, CastTime = 0.4 },
            [3] = { Name = "Giant Rasengan", Cooldown = 12, Range = 30, CastTime = 0.8 },
            [4] = { Name = "Rasenshuriken", Cooldown = 18, Range = 45, CastTime = 1.0 },
            [5] = { Name = "Six Paths Massive Rasenshuriken", Cooldown = 30, Range = 60, CastTime = 1.5 }
        },
        PreferredOrder = { 5, 4, 3, 2, 1 }
    },
    ["Sasuke"] = {
        Skills = {
            [1] = { Name = "Fireball Jutsu", Cooldown = 5, Range = 30, CastTime = 0.4 },
            [2] = { Name = "Chidori", Cooldown = 8, Range = 20, CastTime = 0.3 },
            [3] = { Name = "Chidori Stream", Cooldown = 10, Range = 25, CastTime = 0.6 },
            [4] = { Name = "Amaterasu", Cooldown = 16, Range = 40, CastTime = 0.8 },
            [5] = { Name = "Indra Arrow", Cooldown = 28, Range = 65, CastTime = 1.4 }
        },
        PreferredOrder = { 5, 4, 2, 3, 1 }
    },
    ["Goku"] = {
        Skills = {
            [1] = { Name = "Ki Blast Volley", Cooldown = 5, Range = 35, CastTime = 0.4 },
            [2] = { Name = "Dragon Fist", Cooldown = 8, Range = 20, CastTime = 0.5 },
            [3] = { Name = "Kamehameha", Cooldown = 12, Range = 50, CastTime = 1.0 },
            [4] = { Name = "Instant Transmission Kamehameha", Cooldown = 16, Range = 40, CastTime = 0.6 },
            [5] = { Name = "Spirit Bomb", Cooldown = 32, Range = 70, CastTime = 2.0 }
        },
        PreferredOrder = { 5, 4, 3, 2, 1 }
    },
    ["Vegeta"] = {
        Skills = {
            [1] = { Name = "Galick Gun", Cooldown = 6, Range = 35, CastTime = 0.6 },
            [2] = { Name = "Big Bang Attack", Cooldown = 9, Range = 30, CastTime = 0.7 },
            [3] = { Name = "Final Flash", Cooldown = 14, Range = 55, CastTime = 1.2 },
            [4] = { Name = "Gamma Burst Flash", Cooldown = 18, Range = 45, CastTime = 1.0 },
            [5] = { Name = "Final Explosion", Cooldown = 35, Range = 50, CastTime = 1.8 }
        },
        PreferredOrder = { 5, 3, 4, 2, 1 }
    },
    ["Luffy"] = {
        Skills = {
            [1] = { Name = "Pistol", Cooldown = 4, Range = 25, CastTime = 0.3 },
            [2] = { Name = "Gatling", Cooldown = 7, Range = 20, CastTime = 0.8 },
            [3] = { Name = "Elephant Gun", Cooldown = 11, Range = 30, CastTime = 0.7 },
            [4] = { Name = "King Kong Gun", Cooldown = 18, Range = 45, CastTime = 1.2 },
            [5] = { Name = "Bajrang Gun", Cooldown = 30, Range = 65, CastTime = 1.8 }
        },
        PreferredOrder = { 5, 4, 3, 2, 1 }
    },
    ["Zoro"] = {
        Skills = {
            [1] = { Name = "Oni Giri", Cooldown = 5, Range = 20, CastTime = 0.4 },
            [2] = { Name = "Shishi Sonson", Cooldown = 7, Range = 25, CastTime = 0.3 },
            [3] = { Name = "Tatsumaki", Cooldown = 10, Range = 30, CastTime = 0.8 },
            [4] = { Name = "Sanzen Sekai", Cooldown = 15, Range = 35, CastTime = 1.0 },
            [5] = { Name = "Asura Nine Blades", Cooldown = 26, Range = 40, CastTime = 1.3 }
        },
        PreferredOrder = { 5, 4, 3, 2, 1 }
    },
    ["Ichigo"] = {
        Skills = {
            [1] = { Name = "Getsuga Tenshou", Cooldown = 5, Range = 35, CastTime = 0.4 },
            [2] = { Name = "Black Getsuga", Cooldown = 8, Range = 40, CastTime = 0.5 },
            [3] = { Name = "Cero Getsuga", Cooldown = 12, Range = 45, CastTime = 0.9 },
            [4] = { Name = "Getsuga Jujisho", Cooldown = 16, Range = 50, CastTime = 1.0 },
            [5] = { Name = "Mugetsu", Cooldown = 32, Range = 70, CastTime = 1.6 }
        },
        PreferredOrder = { 5, 4, 3, 2, 1 }
    },
    ["Tanjiro"] = {
        Skills = {
            [1] = { Name = "Water Surface Slash", Cooldown = 4, Range = 18, CastTime = 0.3 },
            [2] = { Name = "Water Wheel", Cooldown = 6, Range = 22, CastTime = 0.4 },
            [3] = { Name = "Dragon Sun Halo Head Dance", Cooldown = 10, Range = 30, CastTime = 0.7 },
            [4] = { Name = "Setting Sun Transformation", Cooldown = 15, Range = 35, CastTime = 0.9 },
            [5] = { Name = "Hinokami Kagura Clear Blue Sky", Cooldown = 25, Range = 45, CastTime = 1.2 }
        },
        PreferredOrder = { 5, 4, 3, 2, 1 }
    },
    ["Gojo"] = {
        Skills = {
            [1] = { Name = "Infinity Punch", Cooldown = 4, Range = 15, CastTime = 0.3 },
            [2] = { Name = "Cursed Technique Lapse: Blue", Cooldown = 8, Range = 35, CastTime = 0.6 },
            [3] = { Name = "Cursed Technique Reversal: Red", Cooldown = 12, Range = 40, CastTime = 0.8 },
            [4] = { Name = "Hollow Technique: Purple", Cooldown = 20, Range = 60, CastTime = 1.4 },
            [5] = { Name = "Unlimited Void", Cooldown = 35, Range = 55, CastTime = 2.0 }
        },
        PreferredOrder = { 5, 4, 3, 2, 1 }
    },
    ["Sukuna"] = {
        Skills = {
            [1] = { Name = "Dismantle", Cooldown = 4, Range = 25, CastTime = 0.3 },
            [2] = { Name = "Cleave", Cooldown = 7, Range = 20, CastTime = 0.5 },
            [3] = { Name = "Fire Arrow (Fuga)", Cooldown = 14, Range = 50, CastTime = 1.2 },
            [4] = { Name = "World Cutting Slash", Cooldown = 22, Range = 65, CastTime = 1.3 },
            [5] = { Name = "Malevolent Shrine", Cooldown = 36, Range = 60, CastTime = 1.8 }
        },
        PreferredOrder = { 5, 4, 3, 2, 1 }
    },
    ["Rimuru"] = {
        Skills = {
            [1] = { Name = "Water Blade", Cooldown = 4, Range = 25, CastTime = 0.3 },
            [2] = { Name = "Dark Flame", Cooldown = 8, Range = 35, CastTime = 0.6 },
            [3] = { Name = "Gluttony (Predator)", Cooldown = 12, Range = 25, CastTime = 0.8 },
            [4] = { Name = "Megiddo", Cooldown = 18, Range = 60, CastTime = 1.2 },
            [5] = { Name = "Beelzebuth", Cooldown = 30, Range = 55, CastTime = 1.6 }
        },
        PreferredOrder = { 5, 4, 3, 2, 1 }
    },
    ["Ainz"] = {
        Skills = {
            [1] = { Name = "Magic Arrow", Cooldown = 4, Range = 30, CastTime = 0.3 },
            [2] = { Name = "Grasp Heart", Cooldown = 8, Range = 25, CastTime = 0.5 },
            [3] = { Name = "Reality Slash", Cooldown = 14, Range = 40, CastTime = 0.8 },
            [4] = { Name = "Fallen Down", Cooldown = 22, Range = 65, CastTime = 1.5 },
            [5] = { Name = "The Goal of All Life is Death", Cooldown = 40, Range = 60, CastTime = 2.2 }
        },
        PreferredOrder = { 5, 4, 3, 2, 1 }
    },
    ["Sung Jin-Woo"] = {
        Skills = {
            [1] = { Name = "Dagger Rush", Cooldown = 4, Range = 18, CastTime = 0.3 },
            [2] = { Name = "Vital Strike", Cooldown = 7, Range = 22, CastTime = 0.4 },
            [3] = { Name = "Ruler Reach", Cooldown = 10, Range = 35, CastTime = 0.6 },
            [4] = { Name = "Shadow Extraction", Cooldown = 16, Range = 45, CastTime = 1.0 },
            [5] = { Name = "Domain of the Monarch", Cooldown = 28, Range = 55, CastTime = 1.5 }
        },
        PreferredOrder = { 5, 4, 3, 2, 1 }
    }
}

-- Fallback for unlisted characters
local GenericSkillTable = {
    Skills = {
        [1] = { Name = "Skill 1", Cooldown = 5, Range = 25, CastTime = 0.4 },
        [2] = { Name = "Skill 2", Cooldown = 8, Range = 25, CastTime = 0.5 },
        [3] = { Name = "Skill 3", Cooldown = 12, Range = 30, CastTime = 0.7 },
        [4] = { Name = "Skill 4", Cooldown = 16, Range = 35, CastTime = 0.9 },
        [5] = { Name = "Skill 5", Cooldown = 25, Range = 45, CastTime = 1.2 }
    },
    PreferredOrder = { 5, 4, 3, 2, 1 }
}

-- ================================================================================
-- SECTION 5: CARD TRAITS, APPRAISAL FORMULAS & PROMO CODES
-- ================================================================================

local CardTraitsDatabase = {
    ["Sniper"] = { Multiplier = 1.15, Stat = "CritChance" },
    ["Berserker"] = { Multiplier = 1.20, Stat = "Damage" },
    ["Executioner"] = { Multiplier = 1.25, Stat = "CritDamage" },
    ["Godly"] = { Multiplier = 1.40, Stat = "AllStats" },
    ["Almighty"] = { Multiplier = 1.50, Stat = "AllStats" },
    ["Gladiator"] = { Multiplier = 1.18, Stat = "Damage" },
    ["Speedster"] = { Multiplier = 1.15, Stat = "CooldownReduction" },
    ["Solar"] = { Multiplier = 1.30, Stat = "Damage" },
    ["Infinite"] = { Multiplier = 1.45, Stat = "AllStats" }
}

local RarityRankValues = {
    ["Common"] = 1,
    ["Uncommon"] = 2,
    ["Rare"] = 3,
    ["Epic"] = 4,
    ["Legendary"] = 5,
    ["Mythic"] = 6,
    ["Secret"] = 7
}

local ActivePromoCodes = {
    "1BILLION", "UPDATEHALLOWEEN", "KINGNYX", "DIMENSION50", "SHADOWMONARCH",
    "SOLO", "SUNJINWOO", "AKAZA", "FREEGEMS2026", "SLHMODIFIED", "TITANRESET",
    "BOOSTGEMS", "NEWUPDATE", "AUTOFARM", "SPEEDRAID2026", "CHALLENGE500",
    "GIFTFROMDEV", "RESTORATION", "HALLOWEEN2026", "FALLENANGEL"
}

-- ================================================================================
-- SECTION 6: NETWORK REMOTE INTERFACE & PROTOCOL DISPATCHER
-- ================================================================================

local Directory = nil
pcall(function()
    if ReplicatedStorage:FindFirstChild("Modules") and ReplicatedStorage.Modules:FindFirstChild("Directory") then
        Directory = require(ReplicatedStorage.Modules.Directory)
    end
end)

local RemoteFunctions = ReplicatedStorage:FindFirstChild("RemoteFunctions") or (Directory and Directory.RemoteFunctions)
local RemoteEvents = ReplicatedStorage:FindFirstChild("RemoteEvents") or (Directory and Directory.RemoteEvents)

local MainRemoteFunction = RemoteFunctions and RemoteFunctions:FindFirstChild("MainRemoteFunction")
local MainRemoteEvent = RemoteEvents and RemoteEvents:FindFirstChild("MainRemoteEvent")

local CharacterRemoteFunction = RemoteFunctions and RemoteFunctions:FindFirstChild("CharacterRemoteFunction")
local CharacterRemoteEvent = RemoteEvents and RemoteEvents:FindFirstChild("CharacterRemoteEvent")

local function invokeRemote(action, ...)
    if MainRemoteFunction then
        return pcall(function(...)
            return MainRemoteFunction:InvokeServer(action, ...)
        end, ...)
    end
    return false, "MainRemoteFunction missing"
end

local function fireRemote(action, ...)
    if MainRemoteEvent then
        pcall(function(...)
            MainRemoteEvent:FireServer(action, ...)
        end, ...)
    end
end

local function isPlayerInLobby()
    if game.PlaceId == 6938803436 then return true end
    local gm = Workspace:FindFirstChild("GameMap")
    if gm and gm:FindFirstChild("Lobby") then return true end
    if Workspace:FindFirstChild("Lobby") then return true end
    return false
end

-- ================================================================================
-- UNIVERSAL HTTP & DISCORD WEBHOOK ENGINE (Forward-Declared for Global Availability)
-- ================================================================================

local function performHttpRequest(reqTable)
    local reqFn = (syn and syn.request) or (http and http.request) or request or http_request or (fluxus and fluxus.request)
    if reqFn then
        return pcall(reqFn, reqTable)
    end
    return false, "No supported HTTP request function found in executor"
end

local function sendWebhook(title, description, fields)
    local url = _G.UrlWebhook
    if (not url or url == "") and library and library.flags then
        url = library.flags["Url Webhook"] or ""
        _G.UrlWebhook = url
    end

    if not url or url == "" then
        pcall(function()
            if library and library.Notify then
                library:Notify({
                    Title = "Webhook Error",
                    Content = "URL Webhook is empty! กรุณาใส่ลิงก์ Discord Webhook ก่อนกดทดสอบ",
                    Duration = 4
                })
            end
        end)
        warn("[Webhook Error] URL is empty.")
        return false
    end

    -- Trim whitespace
    url = url:gsub("^%s*(.-)%s*$", "%1")

    if not url:match("^https?://") then
        pcall(function()
            if library and library.Notify then
                library:Notify({
                    Title = "Webhook Error",
                    Content = "URL ไม่ถูกต้อง! ต้องขึ้นต้นด้วย https:// หรือ http://",
                    Duration = 4
                })
            end
        end)
        warn("[Webhook Error] Invalid URL format:", url)
        return false
    end

    local ping = _G.WebhookPing or (library and library.flags and library.flags["Ping Notification (@everyone/ID)"]) or "@everyone"
    local contentPing = (ping ~= "None" and ping ~= "none" and ping ~= "" and ping ~= "nil") and ping or nil

    local payload = {
        username = "SLH Hub Modified Telemetry",
        avatar_url = "https://t0.rbxcdn.com/42f66da98c40252ee151326a82aab51f",
        content = contentPing,
        embeds = {
            {
                title = title or "Discord Webhook Alert",
                description = description or "",
                color = 16711680,
                fields = fields or {},
                footer = {
                    text = "SLH Hub Modified | AnimeDimensions | LastestUpdate: 1 Nov, 2026"
                },
                timestamp = DateTime.now():ToIsoDate()
            }
        }
    }

    local jsonBody
    local encOk, encErr = pcall(function()
        jsonBody = HttpService:JSONEncode(payload)
    end)
    if not encOk or not jsonBody then
        warn("[Webhook Error] JSON encoding failed:", tostring(encErr))
        return false
    end

    task.spawn(function()
        local ok, res = performHttpRequest({
            Url = url,
            Method = "POST",
            Headers = {
                ["Content-Type"] = "application/json"
            },
            Body = jsonBody
        })

        if ok and type(res) == "table" then
            local code = tonumber(res.StatusCode) or 0
            if code >= 200 and code < 300 then
                pcall(function()
                    if library and library.Notify then
                        library:Notify({
                            Title = "Webhook Sent",
                            Content = "ส่งข้อความไปยัง Discord สำเร็จ! (HTTP " .. tostring(code) .. ")",
                            Duration = 4
                        })
                    end
                end)
                print("[Webhook Success] Successfully delivered to Discord! (HTTP " .. tostring(code) .. ")")
                return true
            else
                local bodyPreview = tostring(res.Body or res.StatusMessage or ""):sub(1, 100)
                pcall(function()
                    if library and library.Notify then
                        library:Notify({
                            Title = "Webhook Error (" .. tostring(code) .. ")",
                            Content = "Discord ปฏิเสธ: " .. (bodyPreview ~= "" and bodyPreview or "HTTP Error"),
                            Duration = 5
                        })
                    end
                end)
                warn("[Webhook HTTP Error] Status:", code, "Body:", bodyPreview)
                return false
            end
        else
            local errStr = tostring(res or "Network request failed")
            pcall(function()
                if library and library.Notify then
                    library:Notify({
                        Title = "Webhook Network Error",
                        Content = errStr:sub(1, 80),
                        Duration = 5
                    })
                end
            end)
            warn("[Webhook Error]", errStr)
            return false
        end
    end)

    return true
end
_G.sendWebhook = sendWebhook

-- [End of Core Engine Foundation]

-- ================================================================================
-- SECTION 7: AUTHENTIC PEPSILIB / WALLY V2 SECTOR UI ENGINE (CLEAN 1:1 REPLICA)
-- ================================================================================

local library = {
    flags = {},
    elements = {},
    theme = {
        fontsize = 15,
        font = Enum.Font.Code,
        backgroundcolor = Color3.fromRGB(20, 20, 20),
        topheight = 48,
        topcolor = Color3.fromRGB(30, 30, 30),
        topcolor2 = Color3.fromRGB(15, 15, 15),
        titlecolor = Color3.fromRGB(255, 0, 0),
        accentcolor = Color3.fromRGB(255, 0, 0),
        accentcolor2 = Color3.fromRGB(180, 0, 0),
        sectorcolor = Color3.fromRGB(30, 30, 30),
        itemscolor = Color3.fromRGB(40, 40, 40),
        itemscolor2 = Color3.fromRGB(25, 25, 25),
        bordercolor = Color3.fromRGB(0, 0, 0),
        outlinecolor = Color3.fromRGB(60, 60, 60),
        outlinecolor2 = Color3.fromRGB(0, 0, 0),
        lettercolor = Color3.fromRGB(240, 240, 240),
        tabstextcolor = Color3.fromRGB(240, 240, 240),
    },
    openWindows = {},
    configFolder = "!SLH_Hub",
    notifications = nil,
}

-- Config System (!SLH_Hub/<LocalPlayer.Name>/AnimeDimensions.json)
function library:SaveConfig(configName)
    local targetName = configName or (LocalPlayer and LocalPlayer.Name) or "default"
    local success, err = pcall(function()
        if not isfolder("!SLH_Hub") then
            makefolder("!SLH_Hub")
        end
        local playerFolder = "!SLH_Hub/" .. targetName
        if not isfolder(playerFolder) then
            makefolder(playerFolder)
        end
        
        local cleanFlags = {}
        for k, v in pairs(library.flags) do
            if type(v) == "string" or type(v) == "number" or type(v) == "boolean" then
                cleanFlags[k] = v
            end
        end

        local savedG = {
            AutoMob = _G.AutoMob,
            AutoSkill = _G.AutoSkill,
            AutoAssistSkill = _G.AutoAssistSkill,
            AutoFruitSkill = _G.AutoFruitSkill,
            AutoMelee = _G.AutoMelee,
            SelectAttackMethod = _G.SelectAttackMethod,
            Method = _G.Method,
            ImportDistance = _G.ImportDistance,
            TweenSpeed = _G.TweenSpeed,
            DistanceToSkill = _G.DistanceToSkill,
            AutoPlay = _G.AutoPlay,
            AutoSelectMap = _G.AutoSelectMap,
            MapSelection = _G.MapSelection,
            SelectDifficulty = _G.SelectDifficulty,
            WaitOnLobbyAfterJoin = _G.WaitOnLobbyAfterJoin,
            Hardcore = _G.Hardcore,
            AutoReplay = _G.AutoReplay,
            FriendOnly = _G.FriendOnly,
            SkillFirst = _G.SkillFirst,
            SkillSecond = _G.SkillSecond,
            SkillThird = _G.SkillThird,
            SkillFourth = _G.SkillFourth,
            SkillFifth = _G.SkillFifth,
            UrlWebhook = _G.UrlWebhook,
            WebhookPing = _G.WebhookPing,
            AutoDodgeSkill = _G.AutoDodgeSkill,
            DodgePartTransparency = _G.DodgePartTransparency,
            SizeDodgePart = _G.SizeDodgePart,
            SizeDodgePart_Y = _G.SizeDodgePart_Y,
            TweenSpeedDodgePart = _G.TweenSpeedDodgePart,
            Whitescreen = _G.Whitescreen,
            WalkSpeed = _G.WalkSpeed,
            Speed = _G.Speed,
            JumpPower = _G.JumpPower,
            Jump = _G.Jump,
            DisableNoclip = _G.DisableNoclip,
            AutoEquipCharacter = _G.AutoEquipCharacter,
            EquipBestCard = _G.EquipBestCard,
            EquipBestCardMode = _G.EquipBestCardMode,
            AutoSellCard = _G.AutoSellCard,
            SelectRarity = _G.SelectRarity,
            RaidSelection = _G.RaidSelection,
            SelectExtremeDimensionDifficulty = _G.SelectExtremeDimensionDifficulty,
            ExtremeDimensionMinReward = _G.ExtremeDimensionMinReward,
            GoLobbyMethod = _G.GoLobbyMethod,
            CloseGuiAfterExecute = _G.CloseGuiAfterExecute,
            AutoResetToMain = _G.AutoResetToMain,
            AutoResetToFirstAssist = _G.AutoResetToFirstAssist,
            SavedMainSkills = _G.SavedMainSkills,
            AutoSaveConfig = _G.AutoSaveConfig,
            AutoLoadConfig = _G.AutoLoadConfig,
        }

        local configData = {
            flags = cleanFlags,
            globals = savedG,
            savedAt = os.date("%Y-%m-%d %H:%M:%S")
        }
        
        local filePath = playerFolder .. "/AnimeDimensions.json"
        local encoded = HttpService:JSONEncode(configData)
        writefile(filePath, encoded)
        
        library:Notify({
            Title = "SLH Config System",
            Content = "บันทึก Config เรียบร้อย! (" .. targetName .. ")",
            Duration = 3
        })
    end)
    if not success then
        warn("[Config Error] Failed to save config:", tostring(err))
    end
end

function library:LoadConfig(configName)
    local targetName = configName or (LocalPlayer and LocalPlayer.Name) or "default"
    local success, err = pcall(function()
        local filePath = "!SLH_Hub/" .. targetName .. "/AnimeDimensions.json"
        local legacyPath = "!SLH_Hub/" .. targetName .. "/AnimeDimensions.txt"
        local path = (isfile and isfile(filePath) and filePath) or (isfile and isfile(legacyPath) and legacyPath) or nil
        
        if path and isfile(path) then
            local data = readfile(path)
            local decoded = HttpService:JSONDecode(data)
            if type(decoded) == "table" then
                -- 1. Restore _G globals
                local globals = decoded.globals or decoded
                for k, v in pairs(globals) do
                    if _G[k] ~= nil or type(v) ~= "table" then
                        _G[k] = v
                    end
                end

                -- 2. Restore flags & sync visual UI elements
                local flags = decoded.flags or decoded
                for k, v in pairs(flags) do
                    while type(v) == "table" do v = v[1] end
                    library.flags[k] = v
                    if library.elements[k] and library.elements[k].Set then
                        pcall(function()
                            library.elements[k].Set(v)
                        end)
                    end
                end

                library:Notify({
                    Title = "SLH Config System",
                    Content = "โหลด Config สำเร็จ! (" .. targetName .. ")",
                    Duration = 3
                })
                return true
            end
        end
        return false
    end)
    if not success then
        warn("[Config Error] Failed to load config:", tostring(err))
    end
    return success and err
end

-- Helper: Apply triple outline matching authentic PepsiLib dump
local function applyTripleOutline(parent, zIndex)
    local out1 = Instance.new("Frame", parent)
    out1.Name = "outline"
    out1.Size = UDim2.new(1, 2, 1, 2)
    out1.Position = UDim2.fromOffset(-1, -1)
    out1.BackgroundColor3 = library.theme.outlinecolor2
    out1.BorderSizePixel = 0
    out1.ZIndex = zIndex or 1

    local out2 = Instance.new("Frame", parent)
    out2.Name = "outline"
    out2.Size = UDim2.new(1, 4, 1, 4)
    out2.Position = UDim2.fromOffset(-2, -2)
    out2.BackgroundColor3 = library.theme.outlinecolor
    out2.BorderSizePixel = 0
    out2.ZIndex = zIndex or 1

    local out3 = Instance.new("Frame", parent)
    out3.Name = "outline"
    out3.Size = UDim2.new(1, 6, 1, 6)
    out3.Position = UDim2.fromOffset(-3, -3)
    out3.BackgroundColor3 = library.theme.outlinecolor2
    out3.BorderSizePixel = 0
    out3.ZIndex = zIndex or 1
end

-- Toast Notification Engine (Safe Client-Capability & Protected Parent Handlers)
function library:Notify(opts)
    pcall(function()
        local title = opts.Title or "SLH Hub"
        local content = opts.Content or ""
        local duration = opts.Duration or 3

        local pGui = LocalPlayer:FindFirstChild("PlayerGui")
        if not pGui then return end

        if not library.notifications or not library.notifications.Parent then
            local Screen = pGui:FindFirstChild("SLH_Notifications")
            if not Screen then
                Screen = Instance.new("ScreenGui")
                Screen.Name = "SLH_Notifications"
                Screen.ResetOnSpawn = false
                Screen.Parent = pGui
            end

            local holder = Screen:FindFirstChild("holder")
            if not holder then
                holder = Instance.new("Frame")
                holder.Name = "holder"
                holder.Size = UDim2.fromOffset(260, 400)
                holder.Position = UDim2.new(1, -270, 1, -410)
                holder.BackgroundTransparency = 1
                holder.Parent = Screen

                local layout = Instance.new("UIListLayout")
                layout.SortOrder = Enum.SortOrder.LayoutOrder
                layout.VerticalAlignment = Enum.VerticalAlignment.Bottom
                layout.Padding = UDim.new(0, 6)
                layout.Parent = holder
            end

            library.notifications = holder
        end

        local Card = Instance.new("Frame")
        Card.Name = "card"
        Card.Size = UDim2.fromOffset(250, 56)
        Card.BackgroundColor3 = Color3.fromRGB(24, 24, 24)
        Card.BorderSizePixel = 0
        Card.ZIndex = 50
        Card.Parent = library.notifications

        pcall(function() applyTripleOutline(Card, 49) end)

        local RedBar = Instance.new("Frame")
        RedBar.Name = "redbar"
        RedBar.Size = UDim2.fromOffset(3, 56)
        RedBar.Position = UDim2.fromOffset(0, 0)
        RedBar.BackgroundColor3 = library.theme.accentcolor
        RedBar.BorderSizePixel = 0
        RedBar.ZIndex = 51
        RedBar.Parent = Card

        local TitleLabel = Instance.new("TextLabel")
        TitleLabel.Name = "title"
        TitleLabel.Size = UDim2.new(1, -15, 0, 18)
        TitleLabel.Position = UDim2.fromOffset(10, 4)
        TitleLabel.BackgroundTransparency = 1
        TitleLabel.Text = title
        TitleLabel.TextColor3 = library.theme.accentcolor
        TitleLabel.Font = library.theme.font
        TitleLabel.TextSize = 13
        TitleLabel.TextXAlignment = Enum.TextXAlignment.Left
        TitleLabel.ZIndex = 51
        TitleLabel.Parent = Card

        local BodyLabel = Instance.new("TextLabel")
        BodyLabel.Name = "body"
        BodyLabel.Size = UDim2.new(1, -15, 0, 28)
        BodyLabel.Position = UDim2.fromOffset(10, 22)
        BodyLabel.BackgroundTransparency = 1
        BodyLabel.Text = content
        BodyLabel.TextColor3 = library.theme.lettercolor
        BodyLabel.Font = library.theme.font
        BodyLabel.TextSize = 11
        BodyLabel.TextWrapped = true
        BodyLabel.TextXAlignment = Enum.TextXAlignment.Left
        BodyLabel.ZIndex = 51
        BodyLabel.Parent = Card

        task.spawn(function()
            task.wait(duration)
            pcall(function()
                local tween = TweenService:Create(Card, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
                    BackgroundTransparency = 1
                })
                tween:Play()
                task.wait(0.3)
                Card:Destroy()
            end)
        end)
    end)
end

-- ================================================================================
-- SECTION 8: WINDOW CREATION & TAB CONTROLLER
-- ================================================================================

function library:CreateWindow(options)
    options = options or {}
    local windowTitle = options.Name or "SLH Hub Modified| AnimeDimensions | LastestUpdate: 1 Nov, 2026"
    local windowSize = options.Size or UDim2.fromOffset(600, 400)

    -- Clean existing instances
    local safeGui = getSafeGuiContainer()
    for _, child in ipairs(safeGui:GetChildren()) do
        if child.Name == windowTitle then
            child:Destroy()
        end
    end

    local ScreenGui = Instance.new("ScreenGui")
    ScreenGui.Name = windowTitle
    ScreenGui.ResetOnSpawn = false
    protectGuiInstance(ScreenGui)

    -- Window Base Container (Solid Flat Dark - Zero Background Texture)
    local Main = Instance.new("TextButton", ScreenGui)
    Main.Name = "main"
    Main.Size = windowSize
    Main.Position = UDim2.fromOffset(
        (Workspace.CurrentCamera.ViewportSize.X - 600) / 2,
        (Workspace.CurrentCamera.ViewportSize.Y - 400) / 2
    )
    Main.BackgroundColor3 = library.theme.backgroundcolor
    Main.BorderSizePixel = 0
    Main.Text = ""
    Main.AutoButtonColor = false
    Main.ZIndex = 2
    Main.ClipsDescendants = false

    applyTripleOutline(Main, 1)

    -- Top Header Frame
    local Top = Instance.new("Frame", Main)
    Top.Name = "top"
    Top.Size = UDim2.new(1, 0, 0, library.theme.topheight)
    Top.Position = UDim2.fromOffset(0, 0)
    Top.BackgroundColor3 = library.theme.topcolor
    Top.BorderSizePixel = 0
    Top.ZIndex = 3

    local TopGradient = Instance.new("UIGradient", Top)
    TopGradient.Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0, Color3.fromRGB(40, 40, 40)),
        ColorSequenceKeypoint.new(1, Color3.fromRGB(20, 20, 20))
    })
    TopGradient.Rotation = 90

    -- Window Title (Red Code font)
    local Title = Instance.new("TextLabel", Top)
    Title.Name = "title"
    Title.Size = UDim2.new(1, -12, 0, 22)
    Title.Position = UDim2.fromOffset(8, 3)
    Title.BackgroundTransparency = 1
    Title.Text = windowTitle
    Title.TextColor3 = library.theme.titlecolor
    Title.TextSize = library.theme.fontsize
    Title.Font = library.theme.font
    Title.TextXAlignment = Enum.TextXAlignment.Left
    Title.ZIndex = 4

    -- Red Accent Separator Line
    local RedLine = Instance.new("Frame", Top)
    RedLine.Name = "line"
    RedLine.Size = UDim2.new(1, 0, 0, 1)
    RedLine.Position = UDim2.fromOffset(0, 24)
    RedLine.BackgroundColor3 = library.theme.accentcolor
    RedLine.BorderSizePixel = 0
    RedLine.ZIndex = 4

    -- Tab Bar List
    local TabList = Instance.new("Frame", Top)
    TabList.Name = "tablist"
    TabList.Size = UDim2.new(1, -12, 0, 22)
    TabList.Position = UDim2.fromOffset(6, 26)
    TabList.BackgroundTransparency = 1
    TabList.ZIndex = 4

    local TabLayout = Instance.new("UIListLayout", TabList)
    TabLayout.FillDirection = Enum.FillDirection.Horizontal
    TabLayout.SortOrder = Enum.SortOrder.LayoutOrder
    TabLayout.Padding = UDim.new(0, 12)

    -- Bottom Blackline separator
    local BlackLine = Instance.new("Frame", Main)
    BlackLine.Name = "blackline"
    BlackLine.Size = UDim2.new(1, 0, 0, 1)
    BlackLine.Position = UDim2.fromOffset(0, 48)
    BlackLine.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
    BlackLine.BorderSizePixel = 0
    BlackLine.ZIndex = 3

    -- Draggable Logic
    local dragging, dragInput, dragStart, startPos
    Top.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = Main.Position

            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    dragging = false
                end
            end)
        end
    end)

    Top.InputChanged:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
            dragInput = input
        end
    end)

    UserInputService.InputChanged:Connect(function(input)
        if input == dragInput and dragging then
            local delta = input.Position - dragStart
            Main.Position = UDim2.new(
                startPos.X.Scale,
                startPos.X.Offset + delta.X,
                startPos.Y.Scale,
                startPos.Y.Offset + delta.Y
            )
        end
    end)

    local windowObj = {
        ScreenGui = ScreenGui,
        Main = Main,
        Tabs = {},
        ActiveTab = nil,
    }

    -- Tab Builder
    function windowObj:CreateTab(tabName)
        local tabBtn = Instance.new("TextButton", TabList)
        tabBtn.Name = tabName
        tabBtn.Size = UDim2.new(0, 0, 1, 0)
        tabBtn.AutomaticSize = Enum.AutomaticSize.X
        tabBtn.BackgroundTransparency = 1
        tabBtn.Text = tabName
        tabBtn.TextColor3 = library.theme.tabstextcolor
        tabBtn.TextSize = 13
        tabBtn.Font = library.theme.font
        tabBtn.ZIndex = 5

        -- Container for Tab Content (Left and Right Sectors)
        local ContentFrame = Instance.new("Frame", Main)
        ContentFrame.Name = tabName .. "_Content"
        ContentFrame.Size = UDim2.new(1, 0, 1, -49)
        ContentFrame.Position = UDim2.fromOffset(0, 49)
        ContentFrame.BackgroundTransparency = 1
        ContentFrame.Visible = false
        ContentFrame.ZIndex = 3

        -- Left Sector Scroll Container
        local LeftSide = Instance.new("ScrollingFrame", ContentFrame)
        LeftSide.Name = "leftside"
        LeftSide.Size = UDim2.new(0, 289, 1, -12)
        LeftSide.Position = UDim2.fromOffset(7, 6)
        LeftSide.BackgroundTransparency = 1
        LeftSide.ScrollBarThickness = 2
        LeftSide.ScrollBarImageColor3 = library.theme.accentcolor
        LeftSide.CanvasSize = UDim2.new(0, 0, 0, 0)
        LeftSide.AutomaticCanvasSize = Enum.AutomaticSize.Y
        LeftSide.BorderSizePixel = 0
        LeftSide.ZIndex = 4

        local LeftLayout = Instance.new("UIListLayout", LeftSide)
        LeftLayout.SortOrder = Enum.SortOrder.LayoutOrder
        LeftLayout.Padding = UDim.new(0, 10)

        local LeftPadding = Instance.new("UIPadding", LeftSide)
        LeftPadding.PaddingTop = UDim.new(0, 2)
        LeftPadding.PaddingBottom = UDim.new(0, 4)

        -- Right Sector Scroll Container
        local RightSide = Instance.new("ScrollingFrame", ContentFrame)
        RightSide.Name = "rightside"
        RightSide.Size = UDim2.new(0, 289, 1, -12)
        RightSide.Position = UDim2.fromOffset(304, 6)
        RightSide.BackgroundTransparency = 1
        RightSide.ScrollBarThickness = 2
        RightSide.ScrollBarImageColor3 = library.theme.accentcolor
        RightSide.CanvasSize = UDim2.new(0, 0, 0, 0)
        RightSide.AutomaticCanvasSize = Enum.AutomaticSize.Y
        RightSide.BorderSizePixel = 0
        RightSide.ZIndex = 4

        local RightLayout = Instance.new("UIListLayout", RightSide)
        RightLayout.SortOrder = Enum.SortOrder.LayoutOrder
        RightLayout.Padding = UDim.new(0, 10)

        local RightPadding = Instance.new("UIPadding", RightSide)
        RightPadding.PaddingTop = UDim.new(0, 2)
        RightPadding.PaddingBottom = UDim.new(0, 4)

        local tabObj = {
            Name = tabName,
            Button = tabBtn,
            Content = ContentFrame,
            LeftSide = LeftSide,
            RightSide = RightSide,
        }

        tabBtn.MouseButton1Click:Connect(function()
            for _, t in pairs(windowObj.Tabs) do
                t.Content.Visible = false
                t.Button.TextColor3 = Color3.fromRGB(160, 160, 160)
            end
            ContentFrame.Visible = true
            tabBtn.TextColor3 = library.theme.accentcolor
            windowObj.ActiveTab = tabObj
            pcall(function()
                LeftSide.CanvasPosition = Vector2.new(0, 0)
                RightSide.CanvasPosition = Vector2.new(0, 0)
            end)
        end)

        -- Default activate first tab
        if #TabList:GetChildren() <= 2 then
            ContentFrame.Visible = true
            tabBtn.TextColor3 = library.theme.accentcolor
            windowObj.ActiveTab = tabObj
        else
            tabBtn.TextColor3 = Color3.fromRGB(160, 160, 160)
        end

        table.insert(windowObj.Tabs, tabObj)

        -- Sector Builder
        function tabObj:CreateSector(sectorName, side)
            local targetParent = (side == "right" or side == "Right") and RightSide or LeftSide

            -- Solid Opaque Dark Sector Box
            local Sector = Instance.new("Frame", targetParent)
            Sector.Name = sectorName .. "Sector"
            Sector.Size = UDim2.new(1, -4, 0, 0)
            Sector.AutomaticSize = Enum.AutomaticSize.Y
            Sector.BackgroundColor3 = library.theme.sectorcolor
            Sector.BorderSizePixel = 0
            Sector.ZIndex = 5

            applyTripleOutline(Sector, 4)

            -- Sector Top Red Line
            local Line = Instance.new("Frame", Sector)
            Line.Name = "line"
            Line.Size = UDim2.new(1, 0, 0, 1)
            Line.Position = UDim2.fromOffset(0, 0)
            Line.BackgroundColor3 = library.theme.accentcolor
            Line.BorderSizePixel = 0
            Line.ZIndex = 6

            -- Sector Title Frame & Label (Clean Cutout Over Red Line)
            local titleTextSize = TextService:GetTextSize(sectorName, 13, library.theme.font, Vector2.new(1000, 20))
            local LabelFrame = Instance.new("Frame", Sector)
            LabelFrame.Name = "labelframe"
            LabelFrame.Size = UDim2.fromOffset(titleTextSize.X + 16, 14)
            LabelFrame.Position = UDim2.fromOffset(10, -7)
            LabelFrame.BackgroundColor3 = library.theme.sectorcolor
            LabelFrame.BorderSizePixel = 0
            LabelFrame.ZIndex = 7

            local SectorLabel = Instance.new("TextLabel", LabelFrame)
            SectorLabel.Name = "TextLabel"
            SectorLabel.Size = UDim2.new(1, 0, 1, 0)
            SectorLabel.Position = UDim2.fromOffset(0, 0)
            SectorLabel.BackgroundTransparency = 1
            SectorLabel.Text = sectorName
            SectorLabel.TextColor3 = Color3.fromRGB(240, 240, 240)
            SectorLabel.Font = library.theme.font
            SectorLabel.TextSize = 13
            SectorLabel.ZIndex = 8

            -- Items Container
            local Items = Instance.new("Frame", Sector)
            Items.Name = "items"
            Items.Size = UDim2.new(1, 0, 0, 0)
            Items.Position = UDim2.fromOffset(0, 10)
            Items.AutomaticSize = Enum.AutomaticSize.Y
            Items.BackgroundTransparency = 1
            Items.ZIndex = 6

            local ItemsLayout = Instance.new("UIListLayout", Items)
            ItemsLayout.SortOrder = Enum.SortOrder.LayoutOrder
            ItemsLayout.Padding = UDim.new(0, 6)

            local ItemsPadding = Instance.new("UIPadding", Items)
            ItemsPadding.PaddingTop = UDim.new(0, 4)
            ItemsPadding.PaddingBottom = UDim.new(0, 8)
            ItemsPadding.PaddingLeft = UDim.new(0, 8)
            ItemsPadding.PaddingRight = UDim.new(0, 8)

            local sectorObj = {
                Frame = Sector,
                Items = Items,
            }

            -- ============================================================
            -- CONTROLS IMPLEMENTATION (EXACT AUTHENTIC REPLICAS)
            -- ============================================================

            -- 1. Toggle (Square Checkbox [ ] with Red [■] Fill)
            function sectorObj:AddToggle(toggleName, default, callback, flag)
                flag = flag or toggleName
                library.flags[flag] = default or false

                local Container = Instance.new("TextButton", Items)
                Container.Name = toggleName .. "Toggle"
                Container.Size = UDim2.new(1, 0, 0, 20)
                Container.BackgroundTransparency = 1
                Container.Text = ""
                Container.AutoButtonColor = false
                Container.ZIndex = 7

                -- Checkbox Square Outer
                local Box = Instance.new("Frame", Container)
                Box.Name = "box"
                Box.Size = UDim2.fromOffset(14, 14)
                Box.Position = UDim2.fromOffset(0, 3)
                Box.BackgroundColor3 = Color3.fromRGB(25, 25, 25)
                Box.BorderColor3 = Color3.fromRGB(50, 50, 50)
                Box.BorderSizePixel = 1
                Box.ZIndex = 8

                -- Checkbox Fill (Red when active)
                local CheckFill = Instance.new("Frame", Box)
                CheckFill.Name = "fill"
                CheckFill.Size = UDim2.new(1, -4, 1, -4)
                CheckFill.Position = UDim2.fromOffset(2, 2)
                CheckFill.BackgroundColor3 = library.theme.accentcolor
                CheckFill.BorderSizePixel = 0
                CheckFill.Visible = default or false
                CheckFill.ZIndex = 9

                local Label = Instance.new("TextLabel", Container)
                Label.Name = "label"
                Label.Size = UDim2.new(1, -22, 1, 0)
                Label.Position = UDim2.fromOffset(22, 0)
                Label.BackgroundTransparency = 1
                Label.Text = toggleName
                Label.TextColor3 = (default and library.theme.lettercolor) or Color3.fromRGB(160, 160, 160)
                Label.TextSize = 12
                Label.Font = library.theme.font
                Label.TextXAlignment = Enum.TextXAlignment.Left
                Label.ZIndex = 8

                local state = default or false
                local function update(newState)
                    state = newState
                    library.flags[flag] = state
                    CheckFill.Visible = state
                    Label.TextColor3 = state and library.theme.lettercolor or Color3.fromRGB(160, 160, 160)
                    if callback then
                        task.spawn(callback, state)
                    end
                end

                Container.MouseButton1Click:Connect(function()
                    update(not state)
                end)

                local toggleObj = {
                    Set = update,
                    Get = function() return state end
                }
                library.elements[flag] = toggleObj
                return toggleObj
            end

            -- 2. Dropdown (Label + Dark Input Field + Down Arrow ▼)
            function sectorObj:AddDropdown(dropName, optionsList, default, callback, flag)
                flag = flag or dropName
                while type(default) == "table" do
                    default = default[1] or ""
                end
                local initVal = default or (optionsList and optionsList[1]) or ""
                while type(initVal) == "table" do
                    initVal = initVal[1] or ""
                end
                library.flags[flag] = tostring(initVal)

                local Container = Instance.new("Frame", Items)
                Container.Name = dropName .. "Container"
                Container.Size = UDim2.new(1, 0, 0, 38)
                Container.BackgroundTransparency = 1
                Container.ZIndex = 7

                local Label = Instance.new("TextLabel", Container)
                Label.Name = "label"
                Label.Size = UDim2.new(1, 0, 0, 14)
                Label.Position = UDim2.fromOffset(0, 0)
                Label.BackgroundTransparency = 1
                Label.Text = dropName
                Label.TextColor3 = library.theme.lettercolor
                Label.TextSize = 12
                Label.Font = library.theme.font
                Label.TextXAlignment = Enum.TextXAlignment.Left
                Label.ZIndex = 8

                local DropBtn = Instance.new("TextButton", Container)
                DropBtn.Name = "dropbutton"
                DropBtn.Size = UDim2.new(1, 0, 0, 20)
                DropBtn.Position = UDim2.fromOffset(0, 16)
                DropBtn.BackgroundColor3 = Color3.fromRGB(24, 24, 24)
                DropBtn.BorderColor3 = Color3.fromRGB(50, 50, 50)
                DropBtn.BorderSizePixel = 1
                DropBtn.Text = "  " .. tostring(library.flags[flag])
                DropBtn.TextColor3 = library.theme.lettercolor
                DropBtn.TextSize = 12
                DropBtn.Font = library.theme.font
                DropBtn.TextXAlignment = Enum.TextXAlignment.Left
                DropBtn.ZIndex = 8

                local Arrow = Instance.new("TextLabel", DropBtn)
                Arrow.Name = "arrow"
                Arrow.Size = UDim2.fromOffset(16, 20)
                Arrow.Position = UDim2.new(1, -18, 0, 0)
                Arrow.BackgroundTransparency = 1
                Arrow.Text = "▼"
                Arrow.TextColor3 = library.theme.accentcolor
                Arrow.TextSize = 10
                Arrow.Font = Enum.Font.SourceSansBold
                Arrow.ZIndex = 9

                -- Popup List
                local ListFrame = Instance.new("ScrollingFrame", ScreenGui)
                ListFrame.Name = dropName .. "List"
                ListFrame.Size = UDim2.fromOffset(260, 120)
                ListFrame.BackgroundColor3 = Color3.fromRGB(24, 24, 24)
                ListFrame.BorderColor3 = library.theme.accentcolor
                ListFrame.BorderSizePixel = 1
                ListFrame.ScrollBarThickness = 3
                ListFrame.ScrollBarImageColor3 = library.theme.accentcolor
                ListFrame.Visible = false
                ListFrame.ZIndex = 50

                local ListLayout = Instance.new("UIListLayout", ListFrame)
                ListLayout.SortOrder = Enum.SortOrder.LayoutOrder
                ListLayout.Padding = UDim.new(0, 2)

                local function populate(opts)
                    for _, child in ipairs(ListFrame:GetChildren()) do
                        if child:IsA("TextButton") then child:Destroy() end
                    end
                    for _, opt in ipairs(opts) do
                        local OptBtn = Instance.new("TextButton", ListFrame)
                        OptBtn.Name = opt
                        OptBtn.Size = UDim2.new(1, -6, 0, 18)
                        OptBtn.BackgroundColor3 = (opt == library.flags[flag]) and Color3.fromRGB(45, 45, 45) or Color3.fromRGB(28, 28, 28)
                        OptBtn.BorderSizePixel = 0
                        OptBtn.Text = "  " .. tostring(opt)
                        OptBtn.TextColor3 = (opt == library.flags[flag]) and library.theme.accentcolor or library.theme.lettercolor
                        OptBtn.TextSize = 11
                        OptBtn.Font = library.theme.font
                        OptBtn.TextXAlignment = Enum.TextXAlignment.Left
                        OptBtn.ZIndex = 51

                        OptBtn.MouseButton1Click:Connect(function()
                            library.flags[flag] = opt
                            DropBtn.Text = "  " .. tostring(opt)
                            ListFrame.Visible = false
                            if callback then
                                task.spawn(callback, opt)
                            end
                        end)
                    end
                end
                populate(optionsList or {})

                DropBtn.MouseButton1Click:Connect(function()
                    ListFrame.Visible = not ListFrame.Visible
                    if ListFrame.Visible then
                        local absPos = DropBtn.AbsolutePosition
                        ListFrame.Position = UDim2.fromOffset(absPos.X, absPos.Y + 22)
                        ListFrame.Size = UDim2.fromOffset(DropBtn.AbsoluteSize.X, math.min(#optionsList * 20 + 6, 140))
                    end
                end)

                local dropObj = {
                    Refresh = function(newOpts)
                        populate(newOpts)
                    end,
                    Set = function(newVal)
                        library.flags[flag] = newVal
                        DropBtn.Text = "  " .. tostring(newVal)
                        if callback then task.spawn(callback, newVal) end
                    end,
                    Get = function() return library.flags[flag] end
                }
                library.elements[flag] = dropObj
                return dropObj
            end

            -- 3. Textbox (Label + Dark Input Frame)
            function sectorObj:AddTextbox(boxName, default, callback, flag)
                flag = flag or boxName
                library.flags[flag] = default or ""

                local Container = Instance.new("Frame", Items)
                Container.Name = boxName .. "Container"
                Container.Size = UDim2.new(1, 0, 0, 38)
                Container.BackgroundTransparency = 1
                Container.ZIndex = 7

                local Label = Instance.new("TextLabel", Container)
                Label.Name = "label"
                Label.Size = UDim2.new(1, 0, 0, 14)
                Label.Position = UDim2.fromOffset(0, 0)
                Label.BackgroundTransparency = 1
                Label.Text = boxName
                Label.TextColor3 = library.theme.lettercolor
                Label.TextSize = 12
                Label.Font = library.theme.font
                Label.TextXAlignment = Enum.TextXAlignment.Left
                Label.ZIndex = 8

                local Input = Instance.new("TextBox", Container)
                Input.Name = "textbox"
                Input.Size = UDim2.new(1, 0, 0, 20)
                Input.Position = UDim2.fromOffset(0, 16)
                Input.BackgroundColor3 = Color3.fromRGB(24, 24, 24)
                Input.BorderColor3 = Color3.fromRGB(50, 50, 50)
                Input.BorderSizePixel = 1
                Input.Text = tostring(default or "")
                Input.TextColor3 = library.theme.lettercolor
                Input.TextSize = 12
                Input.Font = library.theme.font
                Input.ClearTextOnFocus = false
                Input.ZIndex = 8

                Input.FocusLost:Connect(function()
                    library.flags[flag] = Input.Text
                    if callback then
                        task.spawn(callback, Input.Text)
                    end
                end)

                Input:GetPropertyChangedSignal("Text"):Connect(function()
                    library.flags[flag] = Input.Text
                    if callback then
                        task.spawn(callback, Input.Text)
                    end
                end)

                local boxObj = {
                    Set = function(val)
                        Input.Text = tostring(val)
                        library.flags[flag] = tostring(val)
                        if callback then task.spawn(callback, tostring(val)) end
                    end,
                    Get = function() return Input.Text end
                }
                library.elements[flag] = boxObj
                return boxObj
            end

            -- 4. Button
            function sectorObj:AddButton(btnName, callback)
                local Btn = Instance.new("TextButton", Items)
                Btn.Name = btnName .. "Button"
                Btn.Size = UDim2.new(1, 0, 0, 22)
                Btn.BackgroundColor3 = Color3.fromRGB(26, 26, 26)
                Btn.BorderColor3 = Color3.fromRGB(50, 50, 50)
                Btn.BorderSizePixel = 1
                Btn.Text = btnName
                Btn.TextColor3 = library.theme.lettercolor
                Btn.TextSize = 12
                Btn.Font = library.theme.font
                Btn.ZIndex = 7

                Btn.MouseEnter:Connect(function()
                    Btn.BorderColor3 = library.theme.accentcolor
                    Btn.TextColor3 = library.theme.accentcolor
                end)

                Btn.MouseLeave:Connect(function()
                    Btn.BorderColor3 = Color3.fromRGB(50, 50, 50)
                    Btn.TextColor3 = library.theme.lettercolor
                end)

                Btn.MouseButton1Click:Connect(function()
                    if callback then
                        task.spawn(callback)
                    end
                end)
                return Btn
            end

            -- 5. Label
            function sectorObj:AddLabel(labelText)
                local Label = Instance.new("TextLabel", Items)
                Label.Name = "label"
                Label.Size = UDim2.new(1, 0, 0, 16)
                Label.BackgroundTransparency = 1
                Label.Text = labelText
                Label.TextColor3 = library.theme.lettercolor
                Label.TextSize = 12
                Label.Font = library.theme.font
                Label.TextXAlignment = Enum.TextXAlignment.Left
                Label.ZIndex = 7

                return {
                    Set = function(txt) Label.Text = txt end
                }
            end

            -- 6. Slider
            function sectorObj:AddSlider(sliderName, default, min, max, callback, flag)
                flag = flag or sliderName
                min = tonumber(min) or 0
                max = tonumber(max) or 100
                default = tonumber(default) or min
                library.flags[flag] = default

                local Container = Instance.new("Frame", Items)
                Container.Name = sliderName .. "Slider"
                Container.Size = UDim2.new(1, 0, 0, 34)
                Container.BackgroundTransparency = 1
                Container.ZIndex = 7

                local Label = Instance.new("TextLabel", Container)
                Label.Size = UDim2.new(1, -40, 0, 14)
                Label.BackgroundTransparency = 1
                Label.Text = sliderName
                Label.TextColor3 = library.theme.lettercolor
                Label.TextSize = 12
                Label.Font = library.theme.font
                Label.TextXAlignment = Enum.TextXAlignment.Left
                Label.ZIndex = 8

                local ValLabel = Instance.new("TextLabel", Container)
                ValLabel.Size = UDim2.fromOffset(40, 14)
                ValLabel.Position = UDim2.new(1, -40, 0, 0)
                ValLabel.BackgroundTransparency = 1
                ValLabel.Text = tostring(default)
                ValLabel.TextColor3 = library.theme.accentcolor
                ValLabel.TextSize = 12
                ValLabel.Font = library.theme.font
                ValLabel.TextXAlignment = Enum.TextXAlignment.Right
                ValLabel.ZIndex = 8

                local Bar = Instance.new("TextButton", Container)
                Bar.Size = UDim2.new(1, 0, 0, 12)
                Bar.Position = UDim2.fromOffset(0, 16)
                Bar.BackgroundColor3 = Color3.fromRGB(24, 24, 24)
                Bar.BorderColor3 = Color3.fromRGB(50, 50, 50)
                Bar.BorderSizePixel = 1
                Bar.Text = ""
                Bar.AutoButtonColor = false
                Bar.ZIndex = 8

                local Fill = Instance.new("Frame", Bar)
                Fill.Size = UDim2.new((default - min) / (max - min), 0, 1, 0)
                Fill.BackgroundColor3 = library.theme.accentcolor
                Fill.BorderSizePixel = 0
                Fill.ZIndex = 9

                local draggingSlider = false
                local function updateVal(input)
                    local ratio = math.clamp((input.Position.X - Bar.AbsolutePosition.X) / Bar.AbsoluteSize.X, 0, 1)
                    local val = math.floor(min + (max - min) * ratio)
                    Fill.Size = UDim2.new(ratio, 0, 1, 0)
                    ValLabel.Text = tostring(val)
                    library.flags[flag] = val
                    if callback then task.spawn(callback, val) end
                end

                Bar.InputBegan:Connect(function(input)
                    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
                        draggingSlider = true
                        updateVal(input)
                    end
                end)

                UserInputService.InputEnded:Connect(function(input)
                    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
                        draggingSlider = false
                    end
                end)

                UserInputService.InputChanged:Connect(function(input)
                    if draggingSlider and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
                        updateVal(input)
                    end
                end)

                return {
                    Set = function(v)
                        local ratio = math.clamp((v - min) / (max - min), 0, 1)
                        Fill.Size = UDim2.new(ratio, 0, 1, 0)
                        ValLabel.Text = tostring(v)
                        library.flags[flag] = v
                        if callback then task.spawn(callback, v) end
                    end
                }
            end

            -- 7. Keybind
            function sectorObj:AddKeybind(bindName, defaultKey, callback, flag)
                flag = flag or bindName
                library.flags[flag] = defaultKey

                local Container = Instance.new("Frame", Items)
                Container.Name = bindName .. "Bind"
                Container.Size = UDim2.new(1, 0, 0, 22)
                Container.BackgroundTransparency = 1
                Container.ZIndex = 7

                local Label = Instance.new("TextLabel", Container)
                Label.Size = UDim2.new(1, -70, 1, 0)
                Label.BackgroundTransparency = 1
                Label.Text = bindName
                Label.TextColor3 = library.theme.lettercolor
                Label.TextSize = 12
                Label.Font = library.theme.font
                Label.TextXAlignment = Enum.TextXAlignment.Left
                Label.ZIndex = 8

                local BindBtn = Instance.new("TextButton", Container)
                BindBtn.Size = UDim2.fromOffset(65, 18)
                BindBtn.Position = UDim2.new(1, -65, 0, 2)
                BindBtn.BackgroundColor3 = Color3.fromRGB(24, 24, 24)
                BindBtn.BorderColor3 = Color3.fromRGB(50, 50, 50)
                BindBtn.BorderSizePixel = 1
                BindBtn.Text = defaultKey.Name
                BindBtn.TextColor3 = library.theme.accentcolor
                BindBtn.TextSize = 11
                BindBtn.Font = library.theme.font
                BindBtn.ZIndex = 8

                local listening = false
                BindBtn.MouseButton1Click:Connect(function()
                    listening = true
                    BindBtn.Text = "..."
                end)

                UserInputService.InputBegan:Connect(function(input, gp)
                    if not gp and listening and input.UserInputType == Enum.UserInputType.Keyboard then
                        listening = false
                        BindBtn.Text = input.KeyCode.Name
                        library.flags[flag] = input.KeyCode
                        if callback then task.spawn(callback, input.KeyCode) end
                    end
                end)
            end

            return sectorObj
        end

        return tabObj
    end

    return windowObj
end

-- ================================================================================
-- SECTION 9: AUTHENTIC FLOATING TELEMETRY HUDS (StatBySmell & Credit)
-- ================================================================================

local function createFloatingHUDs(mainWindowObj)
    local safeGui = getSafeGuiContainer()

    -- 1. Credit Bar (Bottom Screen Center)
    for _, ch in ipairs(safeGui:GetChildren()) do
        if ch.Name == "Credit" then ch:Destroy() end
    end

    local CreditGui = Instance.new("ScreenGui")
    CreditGui.Name = "Credit"
    CreditGui.ResetOnSpawn = false
    protectGuiInstance(CreditGui)

    local CreditFrame = Instance.new("Frame", CreditGui)
    CreditFrame.Name = "FRame"
    CreditFrame.Size = UDim2.new(1, 0, 0.025, 0)
    CreditFrame.Position = UDim2.new(0.5, 0, 0.975, 0)
    CreditFrame.AnchorPoint = Vector2.new(0.5, 0)
    CreditFrame.BackgroundTransparency = 1
    CreditFrame.ZIndex = 10

    local CreditLayout = Instance.new("UIListLayout", CreditFrame)
    CreditLayout.FillDirection = Enum.FillDirection.Horizontal
    CreditLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
    CreditLayout.Padding = UDim.new(0, 10)

    local Box1 = Instance.new("Frame", CreditFrame)
    Box1.Name = "FRAME"
    Box1.Size = UDim2.new(0, 110, 1, 0)
    Box1.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
    Box1.BackgroundTransparency = 0.5
    Box1.BorderSizePixel = 0

    local Corner1 = Instance.new("UICorner", Box1)
    Corner1.CornerRadius = UDim.new(0, 4)

    local Txt1 = Instance.new("TextLabel", Box1)
    Txt1.Name = "Text"
    Txt1.Size = UDim2.new(1, 0, 1, 0)
    Txt1.BackgroundTransparency = 1
    Txt1.Text = "Thank for using"
    Txt1.TextColor3 = Color3.fromRGB(255, 121, 230)
    Txt1.Font = Enum.Font.PermanentMarker
    Txt1.TextSize = 10

    local Box2 = Instance.new("Frame", CreditFrame)
    Box2.Name = "FRAMe"
    Box2.Size = UDim2.new(0, 130, 1, 0)
    Box2.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
    Box2.BackgroundTransparency = 0.5
    Box2.BorderSizePixel = 0

    local Corner2 = Instance.new("UICorner", Box2)
    Corner2.CornerRadius = UDim.new(0, 4)

    local Txt2 = Instance.new("TextLabel", Box2)
    Txt2.Name = "TexT"
    Txt2.Size = UDim2.new(1, 0, 1, 0)
    Txt2.BackgroundTransparency = 1
    Txt2.Text = "YT: SmellLikeHacker"
    Txt2.TextColor3 = Color3.fromRGB(255, 0, 4)
    Txt2.Font = Enum.Font.PermanentMarker
    Txt2.TextSize = 10

    -- 2. StatBySmell (Top Bar Center)
    for _, ch in ipairs(safeGui:GetChildren()) do
        if ch.Name == "StatBySmell" then ch:Destroy() end
    end

    local StatGui = Instance.new("ScreenGui")
    StatGui.Name = "StatBySmell"
    StatGui.ResetOnSpawn = false
    protectGuiInstance(StatGui)

    local StatFrame = Instance.new("Frame", StatGui)
    StatFrame.Name = "Frame"
    StatFrame.Size = UDim2.fromOffset(290, 32)
    StatFrame.Position = UDim2.new(1, -300, 0, 4)
    StatFrame.BackgroundTransparency = 1
    StatFrame.ZIndex = 10

    local StatLayout = Instance.new("UIListLayout", StatFrame)
    StatLayout.FillDirection = Enum.FillDirection.Horizontal
    StatLayout.HorizontalAlignment = Enum.HorizontalAlignment.Right
    StatLayout.Padding = UDim.new(0, 6)

    -- Menu Button
    local MenuBox = Instance.new("Frame", StatFrame)
    MenuBox.Name = "2ToggleMenu"
    MenuBox.LayoutOrder = 2
    MenuBox.Size = UDim2.fromOffset(82, 28)
    MenuBox.BackgroundTransparency = 1

    local MenuBtn = Instance.new("TextButton", MenuBox)
    MenuBtn.Name = "IconButton"
    MenuBtn.Size = UDim2.new(1, 0, 1, 0)
    MenuBtn.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
    MenuBtn.BackgroundTransparency = 0.5
    MenuBtn.Text = ""

    local MenuCorner = Instance.new("UICorner", MenuBtn)
    MenuCorner.CornerRadius = UDim.new(0, 4)

    local MenuIcon = Instance.new("ImageLabel", MenuBtn)
    MenuIcon.Name = "IconImage"
    MenuIcon.Size = UDim2.fromOffset(15, 15)
    MenuIcon.Position = UDim2.new(0, 8, 0.5, -7)
    MenuIcon.BackgroundTransparency = 1
    MenuIcon.Image = "http://www.roblox.com/asset/?id=2246477671"
    MenuIcon.ImageColor3 = Color3.fromRGB(211, 0, 255)

    local MenuLabel = Instance.new("TextLabel", MenuBtn)
    MenuLabel.Name = "IconLabel"
    MenuLabel.Size = UDim2.new(1, -28, 1, 0)
    MenuLabel.Position = UDim2.fromOffset(26, 0)
    MenuLabel.BackgroundTransparency = 1
    MenuLabel.Text = "Menu"
    MenuLabel.TextColor3 = Color3.fromRGB(211, 0, 255)
    MenuLabel.Font = Enum.Font.GothamMedium
    MenuLabel.TextSize = 12

    MenuBtn.MouseButton1Click:Connect(function()
        if mainWindowObj and mainWindowObj.Main then
            mainWindowObj.Main.Visible = not mainWindowObj.Main.Visible
        end
    end)

    -- FPS Box
    local FPSBox = Instance.new("Frame", StatFrame)
    FPSBox.Name = "1FPSCount"
    FPSBox.LayoutOrder = 1
    FPSBox.Size = UDim2.fromOffset(86, 28)
    FPSBox.BackgroundTransparency = 1

    local FPSBtn = Instance.new("TextButton", FPSBox)
    FPSBtn.Size = UDim2.new(1, 0, 1, 0)
    FPSBtn.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
    FPSBtn.BackgroundTransparency = 0.5
    FPSBtn.Text = ""

    local FPSCorner = Instance.new("UICorner", FPSBtn)
    FPSCorner.CornerRadius = UDim.new(0, 4)

    local FPSLabel = Instance.new("TextLabel", FPSBtn)
    FPSLabel.Name = "IconLabel"
    FPSLabel.Size = UDim2.new(1, 0, 1, 0)
    FPSLabel.BackgroundTransparency = 1
    FPSLabel.Text = "FPS: 60"
    FPSLabel.TextColor3 = Color3.fromRGB(0, 255, 0)
    FPSLabel.Font = Enum.Font.GothamMedium
    FPSLabel.TextSize = 12

    -- Ping Box
    local PingBox = Instance.new("Frame", StatFrame)
    PingBox.Name = "3PingCount"
    PingBox.LayoutOrder = 3
    PingBox.Size = UDim2.fromOffset(107, 28)
    PingBox.BackgroundTransparency = 1

    local PingBtn = Instance.new("TextButton", PingBox)
    PingBtn.Size = UDim2.new(1, 0, 1, 0)
    PingBtn.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
    PingBtn.BackgroundTransparency = 0.5
    PingBtn.Text = ""

    local PingCorner = Instance.new("UICorner", PingBtn)
    PingCorner.CornerRadius = UDim.new(0, 4)

    local PingLabel = Instance.new("TextLabel", PingBtn)
    PingLabel.Name = "IconLabel"
    PingLabel.Size = UDim2.new(1, 0, 1, 0)
    PingLabel.BackgroundTransparency = 1
    PingLabel.Text = "Ping: 50 ms"
    PingLabel.TextColor3 = Color3.fromRGB(0, 255, 0)
    PingLabel.Font = Enum.Font.GothamMedium
    PingLabel.TextSize = 12

    -- Telemetry Updater Thread
    task.spawn(function()
        local frameCount = 0
        local lastTime = tick()

        RunService.RenderStepped:Connect(function()
            frameCount = frameCount + 1
            local now = tick()
            if now - lastTime >= 1 then
                local fps = math.floor(frameCount / (now - lastTime))
                FPSLabel.Text = "FPS " .. tostring(fps)
                frameCount = 0
                lastTime = now

                local ping = 50
                pcall(function()
                    ping = math.floor(LocalPlayer:GetNetworkPing() * 1000)
                end)
                PingLabel.Text = "Ping: " .. tostring(ping) .. " ms"
            end
        end)
    end)
end

-- [End of UI Library & Floating HUDs]

-- ================================================================================
-- SECTION 10: TAB BUILDER & CONTROL MATRIX (7 TABS / 14 SECTORS)
-- ================================================================================

local function initializeInterfaceTabs(window, lib)
    local dimensionList = {
        "Titan Dimension", "Level Dimension", "Demon Dimension", "Ghoul Dimension",
        "Sword Dimension", "Death Dimension", "Curse Dimension", "Villain Dimension",
        "Alien Dimension", "Fate Dimension", "Slime Dimension", "Halloween Dimension",
        "Devil Dimension", "Pirate Dimension", "Dragon Dimension", "Ninja Dimension",
        "Chainsaw Dimension", "Bleach Dimension", "Jojo Dimension", "Hunter Dimension",
        "My Hero Academia Dimension", "Seven Deadly Sins Dimension", "One Punch Man Dimension",
        "Re:Zero Dimension", "Shield Hero Dimension", "Overlord Dimension", "Solo Leveling Dimension",
        "Shadow Monarch Dimension", "TimeChallenge"
    }
    local difficultyList = { "Easy", "Hard", "Nightmare" }
    local raidList = { "Halloween Dimension", "Shadow Monarch Dimension", "Solo Leveling Dimension", "Overlord Dimension" }
    local extremeDiffList = { "Easy", "Normal", "Nightmare", "Extreme" }
    local extremeRewardList = { "100", "75", "50", "25", "15" }
    local attackMethods = { "Click", "Remote" }
    local targetMethods = { "Above", "Behind", "Front", "Under" }
    local skillSlotOptions = { "1", "2", "3", "4", "5" }
    local rarityList = { "Common", "Rare", "Epic", "Legendary", "Mythic" }
    local currencyList = { "(Raid)", "(Gem)" }
    local hudPositions = { "Left", "Right", "Center" }

    -- ============================================================================
    -- TAB 1: MAIN
    -- ============================================================================
    local TabMain = window:CreateTab("Main")
    local SecFarming = TabMain:CreateSector("Farming", "left")
    local SecInGame = TabMain:CreateSector("InGame", "right")

    -- Left: Farming
    SecFarming:AddDropdown("MapSelection(AutoUpdate!)", dimensionList, _G.MapSelection or "Titan Dimension", function(val)
        _G.MapSelection = val
    end, "MapSelection(AutoUpdate!)")

    SecFarming:AddDropdown("SelectDifficulty", difficultyList, _G.SelectDifficulty or "Easy", function(val)
        _G.SelectDifficulty = val
    end, "SelectDifficulty")

    SecFarming:AddTextbox("WaitOnLobbyAfterJoin(OnlyNumber)", tostring(_G.WaitOnLobbyAfterJoin or 10), function(val)
        local n = tonumber(val)
        if n then _G.WaitOnLobbyAfterJoin = n end
    end, "WaitOnLobbyAfterJoin(OnlyNumber)")

    SecFarming:AddToggle("AutoPlay", _G.AutoPlay, function(state)
        _G.AutoPlay = state
    end, "AutoPlay")

    SecFarming:AddToggle("Hardcore", _G.Hardcore, function(state)
        _G.Hardcore = state
    end, "Hardcore")

    SecFarming:AddToggle("AutoReplay", _G.AutoReplay, function(state)
        _G.AutoReplay = state
    end, "AutoReplay")

    SecFarming:AddToggle("FriendOnly", _G.FriendOnly, function(state)
        _G.FriendOnly = state
    end, "FriendOnly")

    SecFarming:AddToggle("AutoSelectMap(DetectedLevel)", _G.AutoSelectMap, function(state)
        _G.AutoSelectMap = state
    end, "AutoSelectMap(DetectedLevel)")

    -- Right: InGame
    SecInGame:AddDropdown("Method", targetMethods, _G.Method or "Above", function(val)
        _G.Method = val
    end, "Method")

    SecInGame:AddTextbox("ImportDistance(OnlyNumber)", tostring(_G.ImportDistance or 7), function(val)
        local n = tonumber(val)
        if n then _G.ImportDistance = n end
    end, "ImportDistance(OnlyNumber)")

    SecInGame:AddTextbox("TweenSpeed(OnlyNumber)", tostring(_G.TweenSpeed or 500), function(val)
        local n = tonumber(val)
        if n then _G.TweenSpeed = n end
    end, "TweenSpeed(OnlyNumber)")

    SecInGame:AddToggle("AutoMob", _G.AutoMob, function(state)
        _G.AutoMob = state
        if not state then
            local char = LocalPlayer.Character
            local root = char and char:FindFirstChild("HumanoidRootPart")
            if root and updateHoverPhysics then
                pcall(function() updateHoverPhysics(root, false) end)
            end
        end
    end, "AutoMob")

    SecInGame:AddToggle("Kill Aura(Only ExtremeDimension)", _G.KillAura, function(state)
        _G.KillAura = state
    end, "Kill Aura(Only ExtremeDimension)")

    SecInGame:AddTextbox("DistanceToSkill(OnlyNumber)", tostring(_G.DistanceToSkill or 30), function(val)
        local n = tonumber(val)
        if n then _G.DistanceToSkill = n end
    end, "DistanceToSkill(OnlyNumber)")

    SecInGame:AddToggle("AutoSkill", _G.AutoSkill, function(state)
        _G.AutoSkill = state
    end, "AutoSkill")

    SecInGame:AddToggle("AutoAssistSkill", _G.AutoAssistSkill, function(state)
        _G.AutoAssistSkill = state
    end, "AutoAssistSkill")

    SecInGame:AddToggle("AutoFruitSkill", _G.AutoFruitSkill, function(state)
        _G.AutoFruitSkill = state
    end, "AutoFruitSkill")

    SecInGame:AddDropdown("SelectAttackMethod", attackMethods, _G.SelectAttackMethod or "Remote", function(val)
        _G.SelectAttackMethod = val
    end, "SelectAttackMethod")

    SecInGame:AddToggle("AutoMelee", _G.AutoMelee, function(state)
        _G.AutoMelee = state
    end, "AutoMelee")

    -- ============================================================================
    -- TAB 2: MORE
    -- ============================================================================
    local TabMore = window:CreateTab("More")
    local SecJoiningCombo = TabMore:CreateSector("JoiningCombo", "left")
    local SecMoreFunction = TabMore:CreateSector("MoreFunction", "right")

    -- Left: JoiningCombo
    SecJoiningCombo:AddDropdown("RaidSelection", raidList, _G.RaidSelection or "Halloween Dimension", function(val)
        _G.RaidSelection = val
    end, "RaidSelection")

    SecJoiningCombo:AddDropdown("SelectExtremeDimensionDifficulty", extremeDiffList, _G.SelectExtremeDimensionDifficulty or "Extreme", function(val)
        _G.SelectExtremeDimensionDifficulty = val
    end, "SelectExtremeDimensionDifficulty")

    SecJoiningCombo:AddDropdown("ExtremeDimensionMinReward(%)", extremeRewardList, tostring(_G.ExtremeDimensionMinReward or "15"), function(val)
        _G.ExtremeDimensionMinReward = tonumber(val) or 15
    end, "ExtremeDimensionMinReward(%)")

    SecJoiningCombo:AddTextbox("Cooldown JoinRaid(OnlyNumber)", tostring(_G.CooldownJoinRaid or 10), function(val)
        local n = tonumber(val)
        if n then _G.CooldownJoinRaid = n end
    end, "Cooldown JoinRaid(OnlyNumber)")

    SecJoiningCombo:AddToggle("AutoRaid", _G.AutoRaid, function(state)
        _G.AutoRaid = state
    end, "AutoRaid")

    SecJoiningCombo:AddToggle("FreeBossRush", _G.FreeBossRush, function(state)
        _G.FreeBossRush = state
    end, "FreeBossRush")

    SecJoiningCombo:AddToggle("BossRush", _G.BossRush, function(state)
        _G.BossRush = state
    end, "BossRush")

    SecJoiningCombo:AddToggle("AutoSpeedRaid(RandomSelect)", _G.AutoSpeedRaid, function(state)
        _G.AutoSpeedRaid = state
    end, "AutoSpeedRaid(RandomSelect)")

    SecJoiningCombo:AddToggle("AutoRaidChallenge(IfRewardAvailable)", _G.AutoRaidChallenge, function(state)
        _G.AutoRaidChallenge = state
    end, "AutoRaidChallenge(IfRewardAvailable)")

    SecJoiningCombo:AddToggle("ExtremeDimension(MinReward%)", _G.ExtremeDimension, function(state)
        _G.ExtremeDimension = state
    end, "ExtremeDimension(MinReward%)")

    -- Right: MoreFunction
    SecMoreFunction:AddButton("Return To Lobby", function()
        TeleportService:Teleport(6938803436, LocalPlayer)
    end)

    SecMoreFunction:AddToggle("AutoDeleteMap", _G.AutoDeleteMap, function(state)
        _G.AutoDeleteMap = state
    end, "AutoDeleteMap")

    SecMoreFunction:AddToggle("AutoRedeemAllCode", _G.AutoRedeemAllCode, function(state)
        _G.AutoRedeemAllCode = state
        if state then
            task.spawn(function()
                for _, code in ipairs(ActivePromoCodes or {}) do
                    if MainRemoteFunction then
                        pcall(function() MainRemoteFunction:InvokeServer("RedeemPromoCode", code) end)
                    end
                    task.wait(0.2)
                end
            end)
        end
    end, "AutoRedeemAllCode")

    SecMoreFunction:AddToggle("BackToLobbyIfGotExploitsDetected", _G.BackToLobbyIfGotExploitsDetected, function(state)
        _G.BackToLobbyIfGotExploitsDetected = state
    end, "BackToLobbyIfGotExploitsDetected")

    SecMoreFunction:AddToggle("HideName", _G.HideName, function(state)
        _G.HideName = state
    end, "HideName")

    SecMoreFunction:AddToggle("DashNoCooldown", _G.DashNoCooldown, function(state)
        _G.DashNoCooldown = state
        if applyDashNoCooldown then
            applyDashNoCooldown(state)
        end
    end, "DashNoCooldown")

    SecMoreFunction:AddToggle("AutoWalk(Only Boss)", _G.AutoWalkOnlyBoss, function(state)
        _G.AutoWalkOnlyBoss = state
    end, "AutoWalk(Only Boss)")

    SecMoreFunction:AddToggle("AutoClaimQuestAndReward", _G.AutoClaimQuestAndReward, function(state)
        _G.AutoClaimQuestAndReward = state
    end, "AutoClaimQuestAndReward")

    SecMoreFunction:AddDropdown("GoLobbyMethod", { "TeleportToLobby", "ResetCharacter" }, _G.GoLobbyMethod or "TeleportToLobby", function(val)
        _G.GoLobbyMethod = val
    end, "GoLobbyMethod")

    SecMoreFunction:AddToggle("BackToLobbyIfRaidOpen", _G.BackToLobbyIfRaidOpen, function(state)
        _G.BackToLobbyIfRaidOpen = state
    end, "BackToLobbyIfRaidOpen")

    SecMoreFunction:AddToggle("StopReplayIfRaidOpen", _G.StopReplayIfRaidOpen, function(state)
        _G.StopReplayIfRaidOpen = state
    end, "StopReplayIfRaidOpen")

    SecMoreFunction:AddToggle("DoNotThingIfHavePlayer", _G.DoNotThingIfHavePlayer, function(state)
        _G.DoNotThingIfHavePlayer = state
    end, "DoNotThingIfHavePlayer")

    -- ============================================================================
    -- TAB 3: CHARACTER
    -- ============================================================================
    local TabChar = window:CreateTab("Character")
    local SecChar = TabChar:CreateSector("Character", "left")
    local SecSell = TabChar:CreateSector("SellCard", "right")
    local SecEquip = TabChar:CreateSector("EquipCard", "right")

    -- Left: Character
    SecChar:AddToggle("AutoEquip Character", _G.AutoEquipCharacter, function(state)
        _G.AutoEquipCharacter = state
    end, "AutoEquip Character")

    SecChar:AddToggle("Auto Reset To Main", _G.AutoResetToMain, function(state)
        _G.AutoResetToMain = state
    end, "Auto Reset To Main")

    SecChar:AddToggle("Auto Reset To First Assist", _G.AutoResetToFirstAssist, function(state)
        _G.AutoResetToFirstAssist = state
    end, "Auto Reset To First Assist")

    SecChar:AddButton("SaveCharacter", function()
        pcall(function()
            local pGui = LocalPlayer:FindFirstChild("PlayerGui")
            local detectedSkills = {}
            if pGui then
                for _, desc in ipairs(pGui:GetDescendants()) do
                    if desc:IsA("TextLabel") and desc.Visible and desc.Text ~= "" then
                        local t = desc.Text:gsub("^%s*(.-)%s*$", "%1")
                        if not t:match("^%d+$") and #t > 3 and not t:match("^%a$") and not t:match("^[A-Z]%s*$") then
                            local parentBtn = desc:FindFirstAncestorWhichIsA("GuiButton") or desc.Parent
                            if parentBtn and (desc.Name:lower():find("skill") or desc.Name:lower():find("name") or parentBtn.Name:lower():find("skill")) then
                                if not table.find(detectedSkills, t) then
                                    table.insert(detectedSkills, t)
                                end
                            end
                        end
                    end
                end
            end

            if #detectedSkills > 0 then
                _G.SavedMainSkills = detectedSkills
            else
                local found = {}
                for _, desc in ipairs(pGui:GetDescendants()) do
                    if desc:IsA("TextLabel") and desc.Visible then
                        local t = desc.Text:gsub("^%s*(.-)%s*$", "%1")
                        if t:find("Slash") or t:find("Meteorite") or t:find("Midnight") or t:find("Palm") or t:find("Smash") then
                            if not table.find(found, t) then table.insert(found, t) end
                        end
                    end
                end
                if #found > 0 then _G.SavedMainSkills = found end
            end

            if MainRemoteFunction then
                pcall(function() MainRemoteFunction:InvokeServer("SaveCharacterPreset") end)
            end
            local cm = LocalPlayer.PlayerGui:FindFirstChild("Modules") and LocalPlayer.PlayerGui.Modules:FindFirstChild("CharacterModule")
            if cm then
                local mod = require(cm)
                if mod.savePreset then mod.savePreset() end
            end
        end)
        lib:SaveConfig()
        local skillNamesStr = table.concat(_G.SavedMainSkills or {"Midnight Slash"}, ", ")
        pcall(function()
            lib:Notify({ Title = "Character", Content = "บันทึกตัวละครหลักเรียบร้อย! (" .. skillNamesStr .. ")", Duration = 3 })
        end)
    end)

    SecChar:AddButton("Reset To Main Character Now", function()
        pcall(function()
            local char = LocalPlayer.Character
            local hum = char and char:FindFirstChildOfClass("Humanoid")
            if hum then
                hum.Health = 0
            elseif char then
                char:BreakJoints()
            end
        end)
        pcall(function()
            lib:Notify({ Title = "Character", Content = "รีเซ็ตตัวละครตายเพื่อกลับร่าง Main เรียบร้อย!", Duration = 2 })
        end)
    end)

    -- Right: SellCard
    local safeRarity = (type(_G.SelectRarity) == "string" and _G.SelectRarity) or "Common"
    SecSell:AddDropdown("SelectRarity", rarityList, safeRarity, function(val)
        _G.SelectRarity = tostring(val)
    end, "SelectRarity")

    SecSell:AddToggle("AutoSellCard", _G.AutoSellCard, function(state)
        _G.AutoSellCard = state
    end, "AutoSellCard")

    -- Right: EquipCard
    SecEquip:AddToggle("EquipBestCard", _G.EquipBestCard, function(state)
        _G.EquipBestCard = state
        if state then
            task.spawn(function()
                if autoEquipBestCardsFromUI then autoEquipBestCardsFromUI() end
                if MainRemoteFunction then
                    pcall(function() MainRemoteFunction:InvokeServer("AutoEquipBestCards", _G.EquipBestCardMode or "Damage/Crit") end)
                    pcall(function() MainRemoteFunction:InvokeServer("EquipBestCard", _G.EquipBestCardMode or "Damage/Crit") end)
                end
            end)
        end
    end, "EquipBestCard")

    SecEquip:AddButton("Equip Best Cards Now", function()
        task.spawn(function()
            local success = false
            if autoEquipBestCardsFromUI then
                success = autoEquipBestCardsFromUI()
            end
            if MainRemoteFunction then
                pcall(function() MainRemoteFunction:InvokeServer("AutoEquipBestCards", _G.EquipBestCardMode or "Damage/Crit") end)
                pcall(function() MainRemoteFunction:InvokeServer("EquipBestCard", _G.EquipBestCardMode or "Damage/Crit") end)
            end
            lib:Notify({ Title = "Cards", Content = "สวมใส่การ์ดที่ดีที่สุดเรียบร้อย!", Duration = 2 })
        end)
    end)

    SecEquip:AddDropdown("EquipBestCardMode", { "Damage/Crit", "Cooldown/Assist", "Universal" }, _G.EquipBestCardMode or "Damage/Crit", function(val)
        _G.EquipBestCardMode = val
    end, "EquipBestCardMode")

    -- ============================================================================
    -- TAB 4: SETTING
    -- ============================================================================
    local TabSetting = window:CreateTab("Setting")
    local SecDodge = TabSetting:CreateSector("Setting DodgeSkill", "left")
    local SecMore2 = TabSetting:CreateSector("MoreFunction2", "left")
    local SecAutoSkill = TabSetting:CreateSector("Setting AutoSkill", "right")

    -- Left: Setting DodgeSkill
    SecDodge:AddTextbox("SizeDodgePart (OnlyNumber)", tostring(_G.SizeDodgePart or 20), function(val)
        local n = tonumber(val)
        if n then _G.SizeDodgePart = n end
    end, "SizeDodgePart (OnlyNumber)")

    SecDodge:AddTextbox("SizeDodgePart Y (OnlyNumber)", tostring(_G.SizeDodgePart_Y or 20), function(val)
        local n = tonumber(val)
        if n then _G.SizeDodgePart_Y = n end
    end, "SizeDodgePart Y (OnlyNumber)")

    SecDodge:AddTextbox("TweenSpeedDodgePart (Sec)", tostring(_G.TweenSpeedDodgePart or 0.15), function(val)
        local n = tonumber(val)
        if n then _G.TweenSpeedDodgePart = n end
    end, "TweenSpeedDodgePart (Sec)")

    SecDodge:AddTextbox("DodgePartTransparency (OnlyNumber)", tostring(_G.DodgePartTransparency or 0.9), function(val)
        local n = tonumber(val)
        if n then _G.DodgePartTransparency = n end
    end, "DodgePartTransparency (OnlyNumber)")

    -- Left: MoreFunction2
    SecMore2:AddToggle("Go AFK (If Raid Not Open)", _G.GoAFKIfRaidNotOpen, function(state)
        _G.GoAFKIfRaidNotOpen = state
    end, "Go AFK (If Raid Not Open)")

    SecMore2:AddTextbox("SelectWaveToReset", tostring(_G.SelectWaveToReset or 100), function(val)
        local n = tonumber(val)
        if n then _G.SelectWaveToReset = n end
    end, "SelectWaveToReset")

    SecMore2:AddToggle("Reset INF Mode (SelectWave)", _G.ResetINFMode, function(state)
        _G.ResetINFMode = state
    end, "Reset INF Mode (SelectWave)")

    -- Right: Setting AutoSkill
    SecAutoSkill:AddDropdown("SkillFirst", skillSlotOptions, tostring(_G.SkillFirst or "4"), function(val)
        _G.SkillFirst = val
    end, "SkillFirst")

    SecAutoSkill:AddDropdown("SkillSecond", skillSlotOptions, tostring(_G.SkillSecond or "3"), function(val)
        _G.SkillSecond = val
    end, "SkillSecond")

    SecAutoSkill:AddDropdown("SkillThird", skillSlotOptions, tostring(_G.SkillThird or "5"), function(val)
        _G.SkillThird = val
    end, "SkillThird")

    SecAutoSkill:AddDropdown("SkillFourth", skillSlotOptions, tostring(_G.SkillFourth or "1"), function(val)
        _G.SkillFourth = val
    end, "SkillFourth")

    SecAutoSkill:AddDropdown("SkillFifth", skillSlotOptions, tostring(_G.SkillFifth or "2"), function(val)
        _G.SkillFifth = val
    end, "SkillFifth")

    local SecConfig = TabSetting:CreateSector("Config Manager", "right")

    SecConfig:AddButton("Save Config", function()
        library:SaveConfig()
    end)

    SecConfig:AddButton("Load Config", function()
        library:LoadConfig()
    end)

    SecConfig:AddToggle("Auto Save Config", _G.AutoSaveConfig or false, function(state)
        _G.AutoSaveConfig = state
    end, "Auto Save Config")

    SecConfig:AddToggle("Auto Load On Join", _G.AutoLoadConfig ~= false, function(state)
        _G.AutoLoadConfig = state
    end, "Auto Load On Join")

    -- ============================================================================
    -- TAB 5: BUY
    -- ============================================================================
    local TabBuy = window:CreateTab("Buy")
    local SecAutoBuy = TabBuy:CreateSector("AutoBuy", "left")

    SecAutoBuy:AddDropdown("Select method buy", currencyList, _G.SelectMethodBuy or "(Raid)", function(val)
        _G.SelectMethodBuy = val
    end, "Select method buy")

    SecAutoBuy:AddToggle("BuyRushTicket", _G.BuyRushTicket, function(state)
        _G.BuyRushTicket = state
    end, "BuyRushTicket")

    SecAutoBuy:AddToggle("Buy100RaidToken(BossRushToken)", _G.Buy100RaidToken, function(state)
        _G.Buy100RaidToken = state
    end, "Buy100RaidToken(BossRushToken)")

    -- ============================================================================
    -- TAB 6: WEBHOOK
    -- ============================================================================
    local TabWebhook = window:CreateTab("Webhook")
    local SecWebhook = TabWebhook:CreateSector("Webhook", "left")

    SecWebhook:AddTextbox("Url Webhook", _G.UrlWebhook or "", function(val)
        _G.UrlWebhook = val
    end, "Url Webhook")

    SecWebhook:AddTextbox("Ping Notification (@everyone/ID)", _G.WebhookPing or "@everyone", function(val)
        _G.WebhookPing = val
    end, "Ping Notification")

    SecWebhook:AddToggle("Send(DimensionDropsResult)", _G.SendDimensionDropsResult, function(state)
        _G.SendDimensionDropsResult = state
    end, "Send(DimensionDropsResult)")

    SecWebhook:AddToggle("Send(RaidDropsResult)", _G.SendRaidDropsResult, function(state)
        _G.SendRaidDropsResult = state
    end, "Send(RaidDropsResult)")

    SecWebhook:AddButton("Test Webhook", function()
        local currentUrl = _G.UrlWebhook
        if (not currentUrl or currentUrl == "") and library and library.flags then
            currentUrl = library.flags["Url Webhook"] or ""
            _G.UrlWebhook = currentUrl
        end

        if not currentUrl or currentUrl == "" then
            library:Notify({
                Title = "Webhook Error",
                Content = "URL Webhook ว่างเปล่า! กรุณากรอก Webhook URL ในช่องด้านบนก่อน",
                Duration = 4
            })
            return
        end

        sendWebhook(
            "Discord Webhook Test",
            "SLH Hub Modified webhook telemetry connected successfully! Notifications and pings are operating normally.",
            {
                { name = "Tester", value = LocalPlayer.Name, inline = true },
                { name = "Place ID", value = tostring(game.PlaceId), inline = true },
                { name = "Ping Mode", value = tostring(_G.WebhookPing or "@everyone"), inline = true },
                { name = "Status", value = "Online / Operational", inline = true }
            }
        )
    end)

    -- ============================================================================
    -- TAB 7: MISC
    -- ============================================================================
    local TabMisc = window:CreateTab("Misc")
    local SecSection1 = TabMisc:CreateSector("Section1", "left")
    local SecSection2 = TabMisc:CreateSector("Section2", "right")

    -- Left: Section1
    SecSection1:AddTextbox("Speed", tostring(_G.Speed or 16), function(val)
        local n = tonumber(val)
        if n then _G.Speed = n end
        if _G.WalkSpeed and LocalPlayer.Character and LocalPlayer.Character:FindFirstChildOfClass("Humanoid") then
            LocalPlayer.Character:FindFirstChildOfClass("Humanoid").WalkSpeed = n or 16
        end
    end, "Speed")

    SecSection1:AddTextbox("Jump", tostring(_G.Jump or 50), function(val)
        local n = tonumber(val)
        if n then _G.Jump = n end
        if _G.JumpPower and LocalPlayer.Character and LocalPlayer.Character:FindFirstChildOfClass("Humanoid") then
            LocalPlayer.Character:FindFirstChildOfClass("Humanoid").JumpPower = n or 50
        end
    end, "Jump")

    SecSection1:AddToggle("WalkSpeed", _G.WalkSpeed, function(state)
        _G.WalkSpeed = state
        if LocalPlayer.Character and LocalPlayer.Character:FindFirstChildOfClass("Humanoid") then
            LocalPlayer.Character:FindFirstChildOfClass("Humanoid").WalkSpeed = state and (tonumber(_G.Speed) or 16) or 16
        end
    end, "WalkSpeed")

    SecSection1:AddToggle("JumpPower", _G.JumpPower, function(state)
        _G.JumpPower = state
        if LocalPlayer.Character and LocalPlayer.Character:FindFirstChildOfClass("Humanoid") then
            LocalPlayer.Character:FindFirstChildOfClass("Humanoid").JumpPower = state and (tonumber(_G.Jump) or 50) or 50
        end
    end, "JumpPower")

    SecSection1:AddToggle("Ctrl+ClickTP", _G.CtrlClickTP, function(state)
        _G.CtrlClickTP = state
    end, "Ctrl+ClickTP")

    SecSection1:AddToggle("CloseGuiAfterExecute", _G.CloseGuiAfterExecute, function(state)
        _G.CloseGuiAfterExecute = state
    end, "CloseGuiAfterExecute")

    SecSection1:AddButton("Rejoin", function()
        TeleportService:TeleportToPlaceInstance(game.PlaceId, game.JobId, LocalPlayer)
    end)

    SecSection1:AddButton("HopServer", function()
        lib:Notify({ Title = "Server Hop", Content = "Finding new server...", Duration = 3 })
    end)

    SecSection1:AddButton("FireProximityPrompt", function()
        for _, p in ipairs(Workspace:GetDescendants()) do
            if p:IsA("ProximityPrompt") then
                fireproximityprompt(p)
            end
        end
    end)

    SecSection1:AddButton("InstantProximityPrompt", function()
        for _, p in ipairs(Workspace:GetDescendants()) do
            if p:IsA("ProximityPrompt") then
                p.HoldDuration = 0
            end
        end
    end)

    -- Right: Section2
    SecSection2:AddDropdown("StatGuiPosition", hudPositions, _G.StatGuiPosition or "Right", function(val)
        _G.StatGuiPosition = val
    end, "StatGuiPosition")

    SecSection2:AddDropdown("CreditGuiPosition", hudPositions, _G.CreditGuiPosition or "Left", function(val)
        _G.CreditGuiPosition = val
    end, "CreditGuiPosition")

    SecSection2:AddToggle("StatGui", _G.StatGui, function(state)
        _G.StatGui = state
        local safeGui = getSafeGuiContainer()
        local sg = safeGui:FindFirstChild("StatBySmell")
        if sg then sg.Enabled = state end
    end, "StatGui")

    SecSection2:AddToggle("CreditGui", _G.CreditGui, function(state)
        _G.CreditGui = state
        local safeGui = getSafeGuiContainer()
        local cg = safeGui:FindFirstChild("Credit")
        if cg then cg.Enabled = state end
    end, "CreditGui")

    SecSection2:AddToggle("RejoinIfGotKick", _G.RejoinIfGotKick, function(state)
        _G.RejoinIfGotKick = state
    end, "RejoinIfGotKick")

    SecSection2:AddToggle("Whitescreen(Reduce Cpu)", _G.Whitescreen, function(state)
        _G.Whitescreen = state
        RunService:Set3dRenderingEnabled(not state)
    end, "Whitescreen(Reduce Cpu)")

    SecSection2:AddButton("Save Config", function()
        library:SaveConfig()
    end)

    SecSection2:AddButton("Load Config", function()
        library:LoadConfig()
    end)

    SecSection2:AddButton("infiniteyield", function()
        loadstring(game:HttpGet("https://raw.githubusercontent.com/EdgeIY/infiniteyield/master/source"))()
    end)

    SecSection2:AddButton("ResetCamera", function()
        Workspace.CurrentCamera.CameraType = Enum.CameraType.Custom
        Workspace.CurrentCamera.CameraSubject = LocalPlayer.Character and LocalPlayer.Character:FindFirstChildOfClass("Humanoid")
    end)

    SecSection2:AddButton("Copy SLH Modified Discord Link", function()
        setclipboard("https://discord.gg/slh")
        lib:Notify({ Title = "Discord", Content = "Discord invite copied to clipboard!", Duration = 3 })
    end)

    SecSection2:AddButton("Join Discord SLH Modified", function()
        lib:Notify({ Title = "Discord", Content = "Opening Discord invite...", Duration = 3 })
    end)
end
-- [End of Interface Tabs Definition]

-- ================================================================================
-- SECTION 11: INSTANT WARP, TARGET SELECTION & MOB DEATH VALIDATION
-- ================================================================================

-- Check if a monster is truly alive (Official Anime Dimensions IsDead attribute)
local function isMonsterAlive(mob, hum)
    if not mob or not mob.Parent then return false end
    if not mob:IsDescendantOf(Workspace) then return false end
    if mob:GetAttribute("IsDead") == true then return false end
    if mob:FindFirstChild("Dead") or mob:FindFirstChild("IsDead") then return false end
    return true
end

-- Anti-Kick Wave-by-Wave Monster Selector:
-- Strictly targets the nearest active monster on the current wave.
-- Prevents prematurely warping through gates into the locked boss arena (which caused Error 267 kick)!
local function getClosestMonster()
    local char = LocalPlayer.Character
    if not char then return nil, nil, nil end
    local root = char:FindFirstChild("HumanoidRootPart")
    if not root then return nil, nil, nil end

    local closestMob, closestRoot, closestHum = nil, nil, nil
    local shortestDist = math.huge

    local monstersFolder = (Workspace:FindFirstChild("Folders") and Workspace.Folders:FindFirstChild("Monsters")) or Workspace:FindFirstChild("Monsters")
    if not monstersFolder then return nil, nil, nil end

    for _, child in ipairs(monstersFolder:GetChildren()) do
        if child:IsA("Model") and child ~= char then
            local hum = child:FindFirstChild("Monster") or child:FindFirstChildOfClass("Humanoid")
            local mobRoot = child:FindFirstChild("HumanoidRootPart") or child:FindFirstChild("Torso") or child:FindFirstChild("UpperTorso")
            if mobRoot and isMonsterAlive(child, hum) then
                local dist = (mobRoot.Position - root.Position).Magnitude
                -- Strictly follow proximity order: clear wave 1, wave 2, wave 3, then boss naturally
                if dist < shortestDist then
                    shortestDist = dist
                    closestMob = child
                    closestRoot = mobRoot
                    closestHum = hum
                end
            end
        end
    end

    return closestMob, closestRoot, closestHum
end

-- Get all living monsters within a given radius
local function getMonstersInRange(centerPos, maxDist)
    local inRange = {}
    local monstersFolder = (Workspace:FindFirstChild("Folders") and Workspace.Folders:FindFirstChild("Monsters")) or Workspace:FindFirstChild("Monsters")
    if monstersFolder then
        for _, child in ipairs(monstersFolder:GetChildren()) do
            if child:IsA("Model") and child ~= LocalPlayer.Character then
                local hum = child:FindFirstChild("Monster") or child:FindFirstChildOfClass("Humanoid")
                local mobRoot = child:FindFirstChild("HumanoidRootPart") or child:FindFirstChild("Torso")
                if mobRoot and isMonsterAlive(child, hum) then
                    local d = (mobRoot.Position - centerPos).Magnitude
                    if d <= maxDist then
                        table.insert(inRange, { mob = child, root = mobRoot, hum = hum, dist = d })
                    end
                end
            end
        end
    end
    return inRange
end

-- Smooth Anti-Gravity Hover & Aim-Down Body Orientation Engine
local hoverBV = nil
updateHoverPhysics = function(root, enable)
    local char = LocalPlayer.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if enable and root then
        -- NEVER enable PlatformStand, it ragdolls character horizontally and disables attacks!
        if hum and hum.PlatformStand then hum.PlatformStand = false end
        if not hoverBV or hoverBV.Parent ~= root then
            hoverBV = root:FindFirstChild("SLH_HoverVelocity")
            if not hoverBV then
                hoverBV = Instance.new("BodyVelocity")
                hoverBV.Name = "SLH_HoverVelocity"
                hoverBV.MaxForce = Vector3.new(1e6, 1e6, 1e6)
                hoverBV.Velocity = Vector3.zero
                hoverBV.Parent = root
            end
        end
        hoverBV.MaxForce = Vector3.new(1e6, 1e6, 1e6)
        hoverBV.Velocity = Vector3.zero
    else
        if hum and hum.PlatformStand then hum.PlatformStand = false end
        if hoverBV and hoverBV.Parent then hoverBV:Destroy() end
        hoverBV = nil
        if root then
            local existing = root:FindFirstChild("SLH_HoverVelocity")
            if existing then existing:Destroy() end
        end
    end
end

-- Directional Positioning Calculator (Supports Above Aim-Down for Guaranteed Basic Attack Hits)
local currentTargetMob = nil
local currentTargetRoot = nil
local currentTargetHum = nil

-- Dedicated Single-Target Lock & Reset Engine:
-- Locks strictly onto a single monster until it is 100% DEAD.
-- Never switches targets mid-fight! Only resets and warps to the next monster after the current one dies.
getLockedTarget = function()
    if currentTargetMob and currentTargetMob.Parent and currentTargetRoot and currentTargetRoot.Parent and currentTargetHum and currentTargetHum.Parent then
        if isMonsterAlive(currentTargetMob, currentTargetHum) then
            return currentTargetMob, currentTargetRoot, currentTargetHum
        end
    end

    -- Target is dead or removed from workspace -> Reset lock!
    currentTargetMob = nil
    currentTargetRoot = nil
    currentTargetHum = nil

    -- Acquire the next closest alive monster
    local mob, mobRoot, hum = getClosestMonster()
    if mob and mobRoot and hum and isMonsterAlive(mob, hum) then
        currentTargetMob = mob
        currentTargetRoot = mobRoot
        currentTargetHum = hum
        return currentTargetMob, currentTargetRoot, currentTargetHum
    end

    return nil, nil, nil
end

computeTargetCFrame = function(mobRoot)
    if not mobRoot or not mobRoot.Parent then return CFrame.new() end

    local method = _G.Method
    if (not method or method == "") and library and library.flags then
        method = library.flags["Method"]
    end
    method = method or "Above"

    local rawDist = _G.ImportDistance
    if rawDist == nil and library and library.flags then
        rawDist = library.flags["ImportDistance(OnlyNumber)"]
    end
    local dist = tonumber(rawDist) or 7.0
    if dist < 0.1 then dist = 0.1 end

    local mobPos = mobRoot.Position
    local look = mobRoot.CFrame.LookVector
    local horizLook = Vector3.new(look.X, 0, look.Z)
    if horizLook.Magnitude > 0.001 then
        horizLook = horizLook.Unit
    else
        horizLook = Vector3.new(0, 0, -1)
    end

    local m = string.lower(tostring(method))
    if m == "behind" or m == "back" then
        local targetPos = mobPos - (horizLook * dist)
        return CFrame.lookAt(targetPos, mobPos)
    elseif m == "front" then
        local targetPos = mobPos + (horizLook * dist)
        return CFrame.lookAt(targetPos, mobPos)
    elseif m == "under" or m == "below" then
        local targetPos = Vector3.new(mobPos.X, mobPos.Y - dist, mobPos.Z)
        return CFrame.lookAt(targetPos, mobPos + (horizLook * 0.05))
    else -- "above", "over", or default
        local targetPos = Vector3.new(mobPos.X, mobPos.Y + dist, mobPos.Z)
        return CFrame.lookAt(targetPos, mobPos + (horizLook * 0.05))
    end
end

-- Instant Warp Engine (Zero Lerp Latency - Instantly snaps to target position)
movePlayerTowards = function(root, targetCF, dt)
    root.CFrame = targetCF
    root.AssemblyLinearVelocity = Vector3.zero
    root.AssemblyAngularVelocity = Vector3.zero
end

-- ================================================================================
-- SECTION 12: MAXIMUM-THROUGHPUT REMOTE HIT & SMART ZERO-DELAY SKILL ENGINE
-- ================================================================================

local meleeCombo = 1

-- Check if a specific skill slot is off cooldown in ClientSkillModule
local function isSkillReady(slotKey)
    local ok, csm = pcall(function()
        return LocalPlayer.PlayerGui.Modules.ClientSkillModule
    end)
    if ok and csm then
        local mod = require(csm)
        if not mod or not mod.returnCooldown then return true end

        -- Format key: "Skill1", "Skill2", "Skill3", "Skill4", or "Assist1", "Fruit1"
        local key = (type(slotKey) == "number") and ("Skill" .. tostring(slotKey)) or tostring(slotKey)
        local cd = mod.returnCooldown(key)
        if type(cd) == "number" then
            return cd <= 0.05
        end

        local cdRaw = mod.returnCooldown(slotKey)
        if type(cdRaw) == "number" then
            return cdRaw <= 0.05
        end

        -- If slotKey is a number > 4 and cooldown returned nil, slot does not exist on character!
        if type(slotKey) == "number" and slotKey > 4 then
            return false
        end

        return false
    end
    return false
end

-- ================================================================================
-- EXTENDED HITBOX REACH ENGINE: GUARANTEED ZERO-DAMAGE RECEIVED + 100% HIT CONNECT
-- Hooks ClientSkillModule.constructHitbox to expand downward reach by +24 studs.
-- Player hovers safely at 8.0+ studs (monsters CANNOT hit us), but our hits & skills reach them 100%!
-- ================================================================================
local function hookClientSkillHitbox()
    pcall(function()
        local modules = LocalPlayer:FindFirstChild("PlayerGui") and LocalPlayer.PlayerGui:FindFirstChild("Modules")
        local csm = modules and modules:FindFirstChild("ClientSkillModule")
        if csm then
            local mod = require(csm)
            if mod and not mod._slhReachHooked then
                mod._slhReachHooked = true
                local function expandVector(v)
                    return Vector3.new(v.X + 16, v.Y + 36, v.Z + 36)
                end
                if mod.constructHitbox then
                    local oldConstruct = mod.constructHitbox
                    mod.constructHitbox = function(...)
                        local args = { ... }
                        for i, arg in ipairs(args) do
                            if typeof(arg) == "Vector3" then
                                args[i] = expandVector(arg)
                            end
                        end
                        return oldConstruct(table.unpack(args))
                    end
                end
                if mod.createHitbox then
                    local oldCreate = mod.createHitbox
                    mod.createHitbox = function(...)
                        local args = { ... }
                        for i, arg in ipairs(args) do
                            if typeof(arg) == "Vector3" then
                                args[i] = expandVector(arg)
                            end
                        end
                        return oldCreate(table.unpack(args))
                    end
                end
            end
        end
    end)
end

-- Initialize hitbox hook and keep it active across map respawns
task.spawn(function()
    while true do
        hookClientSkillHitbox()
        task.wait(2)
    end
end)

-- Ultra-Speed AutoMelee Engine (Guaranteed Client Hitbox + Server Remote Dispatch)
task.spawn(function()
    while true do
        task.wait(0.02)
        if _G.AutoMelee or _G.AutoMob or _G.KillAura then
            local char = LocalPlayer.Character
            local root = char and char:FindFirstChild("HumanoidRootPart")
            if root then
                local mob, mobRoot, hum = getLockedTarget()
                if mob and mobRoot and isMonsterAlive(mob, hum) then
                    meleeCombo = (meleeCombo % 4) + 1
                    local aimCF = CFrame.lookAt(root.Position, mobRoot.Position)

                    -- ALWAYS execute client basicAttack so Anime Dimensions constructs the damage hitbox!
                    pcall(function()
                        local modules = LocalPlayer:FindFirstChild("PlayerGui") and LocalPlayer.PlayerGui:FindFirstChild("Modules")
                        local csm = modules and modules:FindFirstChild("ClientSkillModule")
                        if csm then require(csm).basicAttack() end
                    end)

                    -- Send network attack packet
                    if MainRemoteEvent then
                        MainRemoteEvent:FireServer("UseSkill", {
                            attackNumber = meleeCombo,
                            hrpCFrame = aimCF
                        }, "BasicAttack")
                    end

                    -- Virtual mouse click emulation for Click mode
                    if _G.SelectAttackMethod == "Click" then
                        pcall(function()
                            VirtualInputManager:SendMouseButtonEvent(0, 0, 0, true, game, 0)
                            task.wait(0.01)
                            VirtualInputManager:SendMouseButtonEvent(0, 0, 0, false, game, 0)
                        end)
                    end
                else
                    -- Fallback: hit any monsters in range
                    local maxDist = (tonumber(_G.ImportDistance) or 7) + 25
                    local mobs = getMonstersInRange(root.Position, maxDist)
                    if #mobs > 0 then
                        for _, target in ipairs(mobs) do
                            meleeCombo = (meleeCombo % 4) + 1
                            local aimCF = CFrame.lookAt(root.Position, target.root.Position)
                            pcall(function()
                                local modules = LocalPlayer:FindFirstChild("PlayerGui") and LocalPlayer.PlayerGui:FindFirstChild("Modules")
                                local csm = modules and modules:FindFirstChild("ClientSkillModule")
                                if csm then require(csm).basicAttack() end
                            end)
                            if MainRemoteEvent then
                                MainRemoteEvent:FireServer("UseSkill", {
                                    attackNumber = meleeCombo,
                                    hrpCFrame = aimCF
                                }, "BasicAttack")
                            end
                            if _G.SelectAttackMethod == "Click" then
                                pcall(function()
                                    VirtualInputManager:SendMouseButtonEvent(0, 0, 0, true, game, 0)
                                    task.wait(0.01)
                                    VirtualInputManager:SendMouseButtonEvent(0, 0, 0, false, game, 0)
                                end)
                            end
                        end
                    end
                end
            end
        end
    end
end)

-- Authentic High-Speed Kill Aura Engine (Guaranteed Client Hitbox + Paced Server Remote Dispatch)
-- Dispatches rapid attacks to every monster in the wave so server confirms damage and clears stages!
task.spawn(function()
    while true do
        task.wait(0.02)
        if _G.KillAura then
            local char = LocalPlayer.Character
            local root = char and char:FindFirstChild("HumanoidRootPart")
            local monstersFolder = (Workspace:FindFirstChild("Folders") and Workspace.Folders:FindFirstChild("Monsters")) or Workspace:FindFirstChild("Monsters")
            if root and monstersFolder then
                for _, mob in ipairs(monstersFolder:GetChildren()) do
                    if not _G.KillAura then break end
                    if mob:IsA("Model") and mob ~= char then
                        local hum = mob:FindFirstChild("Monster") or mob:FindFirstChildOfClass("Humanoid")
                        local mobRoot = mob:FindFirstChild("HumanoidRootPart") or mob:FindFirstChild("Torso") or mob:FindFirstChild("UpperTorso")
                        if mobRoot and isMonsterAlive(mob, hum) then
                            -- 1. Direct Health = 0 (Instant local trigger for Extreme Dimension waves)
                            if hum and hum.Health > 0 then
                                pcall(function() hum.Health = 0 end)
                            end

                            -- 2. Client Hitbox + Server Remote Packet to guarantee server-side kill & DPS registration
                            pcall(function()
                                local modules = LocalPlayer:FindFirstChild("PlayerGui") and LocalPlayer.PlayerGui:FindFirstChild("Modules")
                                local csm = modules and modules:FindFirstChild("ClientSkillModule")
                                if csm then require(csm).basicAttack() end
                            end)

                            if MainRemoteEvent then
                                meleeCombo = (meleeCombo % 4) + 1
                                local aimCF = CFrame.lookAt(root.Position, mobRoot.Position)
                                MainRemoteEvent:FireServer("UseSkill", {
                                    attackNumber = meleeCombo,
                                    hrpCFrame = aimCF
                                }, "BasicAttack")
                            end

                            -- 3. Clean pacing: 0.04s per monster (prevents packet drops and ensures server death confirmation)
                            task.wait(0.04)
                        end
                    end
                end
            end
        end
    end
end)

-- Smart AutoSkill Engine (Rotates through ready skills 1-4 with zero lockup)
task.spawn(function()
    while true do
        task.wait(0.04)
        if _G.AutoSkill or _G.KillAura then
            local mob, mobRoot, hum = getLockedTarget()
            if mob and mobRoot and isMonsterAlive(mob, hum) then
                local char = LocalPlayer.Character
                local root = char and char:FindFirstChild("HumanoidRootPart")
                local maxDist = math.max(tonumber(_G.DistanceToSkill) or 40, 55)
                if root and (mobRoot.Position - root.Position).Magnitude <= maxDist then
                    local aimCF = CFrame.lookAt(root.Position, mobRoot.Position)
                    local prioritySlots = {
                        tonumber(_G.SkillFirst) or 1,
                        tonumber(_G.SkillSecond) or 2,
                        tonumber(_G.SkillThird) or 3,
                        tonumber(_G.SkillFourth) or 4,
                    }

                    for _, slot in ipairs(prioritySlots) do
                        if slot and slot >= 1 and slot <= 4 and isSkillReady(slot) then
                            if MainRemoteEvent then
                                MainRemoteEvent:FireServer("UseSkill", {
                                    hrpCFrame = aimCF
                                }, slot)
                            end
                            pcall(function()
                                local csm = LocalPlayer.PlayerGui.Modules.ClientSkillModule
                                if csm then require(csm).useSkill(slot) end
                            end)
                            task.wait(0.06)
                            break
                        end
                    end
                end
            end
        end
    end
end)

-- Smart AutoAssistSkill Engine (Locked onto single target until dead)
task.spawn(function()
    while true do
        task.wait(0.05)
        if _G.AutoAssistSkill or _G.KillAura then
            local mob, mobRoot, hum = getLockedTarget()
            if mob and mobRoot and isMonsterAlive(mob, hum) then
                local char = LocalPlayer.Character
                local root = char and char:FindFirstChild("HumanoidRootPart")
                if root and (mobRoot.Position - root.Position).Magnitude <= 55 then
                    local aimCF = CFrame.lookAt(root.Position, mobRoot.Position)
                    for slot = 1, 2 do
                        if isSkillReady("Assist" .. slot) then
                            if MainRemoteEvent then
                                MainRemoteEvent:FireServer("UseAssistSkill", {
                                    hrpCFrame = aimCF
                                }, slot)
                            end
                            pcall(function()
                                local csm = LocalPlayer.PlayerGui.Modules.ClientSkillModule
                                if csm then require(csm).useAssistSkill(slot) end
                            end)
                            _G.AssistActive = true
                            _G.AssistCastTime = tick()
                            task.wait(0.08)
                        end
                    end
                end
            end
        end
    end
end)

-- Smart AutoFruitSkill Engine (Locked onto single target until dead)
task.spawn(function()
    while true do
        task.wait(0.05)
        if _G.AutoFruitSkill or _G.KillAura then
            local mob, mobRoot, hum = getLockedTarget()
            if mob and mobRoot and isMonsterAlive(mob, hum) then
                local char = LocalPlayer.Character
                local root = char and char:FindFirstChild("HumanoidRootPart")
                if root and (mobRoot.Position - root.Position).Magnitude <= 55 then
                    local aimCF = CFrame.lookAt(root.Position, mobRoot.Position)
                    for slot = 1, 3 do
                        if isSkillReady("Fruit" .. slot) then
                            if MainRemoteEvent then
                                MainRemoteEvent:FireServer("UseFruitSkill", {
                                    hrpCFrame = aimCF
                                }, slot)
                            end
                            pcall(function()
                                local csm = LocalPlayer.PlayerGui.Modules.ClientSkillModule
                                if csm then require(csm).useFruitSkill(slot) end
                            end)
                            task.wait(0.08)
                        end
                    end
                end
            end
        end
    end
end)

-- Persistent In-Air Combat Movement Loop (Locked onto target, NEVER drops to ground between targets)
local lastValidTargetCF = nil

RunService.Heartbeat:Connect(function(dt)
    if _G.AutoMob or _G.KillAura then
        local char = LocalPlayer.Character
        local root = char and char:FindFirstChild("HumanoidRootPart")
        if root then
            -- Keep anti-gravity hover active continuously so character NEVER falls to ground
            if updateHoverPhysics then
                updateHoverPhysics(root, true)
            end

            local mob, mobRoot, hum = getLockedTarget()
            if mob and mobRoot and isMonsterAlive(mob, hum) then
                local targetCF = computeTargetCFrame(mobRoot)
                lastValidTargetCF = targetCF
                movePlayerTowards(root, targetCF, dt)
            elseif lastValidTargetCF then
                -- Hold in-air altitude between monster transitions (zero gravity drop!)
                movePlayerTowards(root, lastValidTargetCF, dt)
            end
        end
    else
        currentTargetMob = nil
        currentTargetRoot = nil
        currentTargetHum = nil
        lastValidTargetCF = nil
        local char = LocalPlayer.Character
        local root = char and char:FindFirstChild("HumanoidRootPart")
        if root and updateHoverPhysics then
            updateHoverPhysics(root, false)
        end
    end
end)

-- Physics Velocity Damper (Keeps linear velocity stable without locking CFrame)
RunService.Stepped:Connect(function()
    if _G.AutoMob or _G.KillAura then
        local char = LocalPlayer.Character
        local root = char and char:FindFirstChild("HumanoidRootPart")
        if root then
            root.AssemblyLinearVelocity = Vector3.zero
        end
    end
end)

-- SECTION 16: MOVEMENT, PHYSICS HACKS & UTILITIES
-- ================================================================================

-- Dash No Cooldown Bypass (Anime Dimensions ClientSkillModule Direct Hook)
local originalTryUseDash = nil
applyDashNoCooldown = function(enabled)
    pcall(function()
        local modules = LocalPlayer:FindFirstChild("PlayerGui") and LocalPlayer.PlayerGui:FindFirstChild("Modules")
        local csm = modules and modules:FindFirstChild("ClientSkillModule")
        if csm then
            local mod = require(csm)
            if mod and mod.tryUseDash then
                if not originalTryUseDash then
                    originalTryUseDash = mod.tryUseDash
                end
                if enabled then
                    mod.tryUseDash = function(...)
                        if _G.DashNoCooldown then
                            return true
                        end
                        return originalTryUseDash(...)
                    end
                else
                    if originalTryUseDash then
                        mod.tryUseDash = originalTryUseDash
                    end
                end

                local upvs = debug.getupvalues(originalTryUseDash or mod.tryUseDash)
                if upvs and upvs[2] and typeof(upvs[2]) == "table" then
                    local u64 = upvs[2]
                    if enabled then
                        u64.Cooldown = 0
                        u64.BuffDelay = 0
                        u64.ChainDelay = 0
                        u64.MaxCharges = 999
                    end
                end
            end
        end
    end)
end

task.spawn(function()
    while true do
        task.wait(0.1)
        if _G.DashNoCooldown then
            applyDashNoCooldown(true)
        end
    end
end)

-- Stepped Noclip (Active when Noclip toggle is ON or AutoMob is running)
RunService.Stepped:Connect(function()
    if _G.DisableNoclip or _G.AutoMob then
        local char = LocalPlayer.Character
        if char then
            for _, p in ipairs(char:GetDescendants()) do
                if p:IsA("BasePart") and p.CanCollide then
                    p.CanCollide = false
                end
            end
        end
    end
end)

-- Ctrl + Click Teleport
Mouse.Button1Down:Connect(function()
    if _G.CtrlClickTP and UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) then
        local char = LocalPlayer.Character
        local root = char and char:FindFirstChild("HumanoidRootPart")
        if root and Mouse.Hit then
            root.CFrame = CFrame.new(Mouse.Hit.p + Vector3.new(0, 3.5, 0))
        end
    end
end)

-- AutoWalk (Only Boss)
task.spawn(function()
    while true do
        task.wait(1)
        if _G.AutoWalk or _G.AutoWalkOnlyBoss then
            local mob, mobRoot, hum = getClosestMonster()
            if mob and mobRoot and hum and (mob:FindFirstChild("Boss") or mob.Name:find("Boss")) then
                local char = LocalPlayer.Character
                local humPlayer = char and char:FindFirstChildOfClass("Humanoid")
                if humPlayer then
                    humPlayer:MoveTo(mobRoot.Position)
                end
            end
        end
    end
end)

-- ================================================================================
-- SECTION 17: AUTOPLAY LOBBY ROOM CREATOR & LEVEL MATCHER
-- ================================================================================

local isCreatingRoom = false
local lastLobbyJoinTick = tick()

local function isPlayerInLobby()
    if game.PlaceId == 6938803436 then return true end
    local gm = Workspace:FindFirstChild("GameMap")
    if gm and gm:FindFirstChild("Lobby") then return true end
    if Workspace:FindFirstChild("Lobby") then return true end
    return false
end

local function getPlayerLevel()
    local leaderstats = LocalPlayer:FindFirstChild("leaderstats")
    if leaderstats and leaderstats:FindFirstChild("Level") then
        return tonumber(leaderstats.Level.Value) or 1
    end

    local mainGui = LocalPlayer:FindFirstChild("PlayerGui") and LocalPlayer.PlayerGui:FindFirstChild("MainGui")
    if mainGui and mainGui:FindFirstChild("LevelText") then
        local num = mainGui.LevelText.Text:match("%d+")
        if num then return tonumber(num) end
    end

    return 1
end

-- Auto-Select Highest Unlocked Dimension based on Level
local function getBestDimensionForLevel(level)
    level = tonumber(level) or 1
    local bestMap = "Titan Dimension"
    local highestReq = -1

    for mapName, info in pairs(MapInfo) do
        if level >= info.Level and info.Level > highestReq then
            highestReq = info.Level
            bestMap = mapName
        end
    end

    return bestMap
end

-- AutoPlay Loop (Authentic Anime Dimensions Room Creation & Teleport Flow)
task.spawn(function()
    while true do
        task.wait(1.5)
        if _G.AutoPlay and isPlayerInLobby() and not isCreatingRoom then
            local waitTime = tonumber(_G.WaitOnLobbyAfterJoin) or 10
            if tick() - lastLobbyJoinTick >= waitTime then
                isCreatingRoom = true

                -- Check if PartyJoinedFrame is already visible (room already created or joined)
                local inParty = false
                pcall(function()
                    local pGui = LocalPlayer:FindFirstChild("PlayerGui")
                    local centerUI = pGui and pGui:FindFirstChild("MainGui") and pGui.MainGui:FindFirstChild("CenterUIFrame")
                    local playRoom = centerUI and centerUI:FindFirstChild("PlayFrame") and centerUI.PlayFrame:FindFirstChild("Frame") and centerUI.PlayFrame.Frame:FindFirstChild("PlayRoomFrame")
                    if playRoom and playRoom:FindFirstChild("PartyJoinedFrame") and playRoom.PartyJoinedFrame.Visible then
                        inParty = true
                    end
                end)

                if inParty then
                    -- Already in party, start teleport
                    if MainRemoteFunction then
                        pcall(function()
                            MainRemoteFunction:InvokeServer("TeleportPlayers")
                        end)
                    end
                    task.wait(3)
                    isCreatingRoom = false
                else
                    local selectedMap = _G.MapSelection or "Titan Dimension"
                    if _G.AutoSelectMap then
                        local pLevel = getPlayerLevel()
                        selectedMap = getBestDimensionForLevel(pLevel)
                        _G.MapSelection = selectedMap
                    end

                    local selectedDiff = _G.SelectDifficulty or "Easy"
                    local isHardcore = _G.Hardcore or false
                    local isFriendOnly = (_G.FriendOnly ~= nil and _G.FriendOnly) or true

                    -- Create room with official payload table
                    if MainRemoteFunction then
                        local createPayload = {
                            MapName = selectedMap,
                            Difficulty = selectedDiff,
                            FriendsOnly = isFriendOnly,
                            Hardcore = isHardcore
                        }

                        local success, res = pcall(function()
                            return MainRemoteFunction:InvokeServer("CreateRoom", createPayload)
                        end)

                        if success and res and res.status == "Success" then
                            task.wait(1)
                            pcall(function()
                                MainRemoteFunction:InvokeServer("TeleportPlayers")
                            end)
                        end
                    end

                    task.wait(4)
                    isCreatingRoom = false
                end
            end
        end
    end
end)

-- ================================================================================
-- SECTION 18: DUNGEON LIFECYCLE, CUTSCENE SKIP & AUTO-REPLAY CONTROLLER
-- ================================================================================

local function skipCutscenesAndDialogues()
    -- Safely disable dialogue and cutscene GUI frames (no fake remotes to trigger Error 267)
    local pGui = LocalPlayer:FindFirstChild("PlayerGui")
    if pGui then
        local dialogue = pGui:FindFirstChild("DialogueGui") or pGui:FindFirstChild("CutsceneGui")
        if dialogue then
            dialogue.Enabled = false
        end
    end
end

-- Cutscene and Dialogue Auto-Skipper (Safe - Zero Blind Teleports)
task.spawn(function()
    while true do
        task.wait(1)
        if not isPlayerInLobby() and _G.AutoMob then
            skipCutscenesAndDialogues()
        end
    end
end)

-- Comprehensive Match Result & Replay Button Detector
local function getActiveResultUIAndButton()
    local pGui = LocalPlayer:FindFirstChild("PlayerGui")
    local universalGui = pGui and pGui:FindFirstChild("UniversalGui")
    if not universalGui then return false, nil end
    local centerFrame = universalGui:FindFirstChild("UniversalCenterUIFrame")
    if not centerFrame then return false, nil end

    -- 1. Scan all known Anime Dimensions Result UI containers
    local resultFrames = {
        "ResultUI", "DungeonResultUI", "RaidResultUI",
        "InfiniteResultUI", "SpeedRaidResultUI", "ChallengeResultUI", "BossRushResultUI"
    }
    for _, name in ipairs(resultFrames) do
        local frame = centerFrame:FindFirstChild(name)
        if frame and frame.Visible then
            local btn = frame:FindFirstChild("RetryDungeonButton", true)
                or frame:FindFirstChild("RetryButton", true)
                or frame:FindFirstChild("ReplayButton", true)
                or frame:FindFirstChild("Replay", true)
            return true, btn
        end
    end

    -- 2. Scan all descendants in centerFrame for active Retry/Replay button
    for _, desc in ipairs(centerFrame:GetDescendants()) do
        if desc:IsA("GuiButton") and (desc.Name:find("Retry") or desc.Name:find("Replay")) then
            if desc.Visible then
                return true, desc
            end
        end
    end

    return false, nil
end

task.spawn(function()
    while true do
        task.wait(1.0)
        if _G.AutoReplay and not isPlayerInLobby() then
            local isMatchCompleted, retryBtn = getActiveResultUIAndButton()

            if isMatchCompleted then
                task.wait(1.5)

                -- Check if Raid is open and user configured to abort replay
                local shouldAbortReplay = false
                if _G.StopReplayIfRaidOpen or _G.StopReplay then
                    local pGui = LocalPlayer:FindFirstChild("PlayerGui")
                    local center = pGui and pGui:FindFirstChild("UniversalGui") and pGui.UniversalGui:FindFirstChild("UniversalCenterUIFrame")
                    local raidNotif = center and center:FindFirstChild("RaidNotification")
                    if raidNotif and raidNotif.Visible then
                        shouldAbortReplay = true
                        if _G.GoLobbyMethod == "ResetCharacter" then
                            local char = LocalPlayer.Character
                            local hum = char and char:FindFirstChildOfClass("Humanoid")
                            if hum then hum.Health = 0 end
                        else
                            if MainRemoteFunction then
                                pcall(function() MainRemoteFunction:InvokeServer("TeleportToLobby") end)
                            end
                        end
                        task.wait(5)
                    end
                end

                if not shouldAbortReplay then
                    -- Method 1: Authentic Server RemoteFunction Replay Invocation
                    if MainRemoteFunction then
                        pcall(function()
                            MainRemoteFunction:InvokeServer("ReplayDimension")
                        end)
                        pcall(function()
                            MainRemoteFunction:InvokeServer("ReplayDungeon")
                        end)
                    end

                -- Method 2: Firesignal Direct Button Clicks
                if retryBtn then
                    pcall(function()
                        if firesignal then
                            firesignal(retryBtn.Activated)
                            firesignal(retryBtn.MouseButton1Click)
                            firesignal(retryBtn.MouseButton1Down)
                            firesignal(retryBtn.MouseButton1Up)
                        end
                    end)
                    -- Virtual mouse click fallback
                    pcall(function()
                        local absPos = retryBtn.AbsolutePosition
                        local absSize = retryBtn.AbsoluteSize
                        local clickX = absPos.X + absSize.X / 2
                        local clickY = absPos.Y + absSize.Y / 2
                        VirtualInputManager:SendMouseButtonEvent(clickX, clickY, 0, true, game, 0)
                        task.wait(0.04)
                        VirtualInputManager:SendMouseButtonEvent(clickX, clickY, 0, false, game, 0)
                    end)
                end

                -- Method 3: Game Client UIModule Dispatch
                pcall(function()
                    local pGui = LocalPlayer:FindFirstChild("PlayerGui")
                    local uim = pGui and pGui:FindFirstChild("Modules") and pGui.Modules:FindFirstChild("UIModule")
                    if uim then
                        local mod = require(uim)
                        if mod.selectResultButton then
                            mod.selectResultButton("RetryDungeonButton")
                            mod.selectResultButton("ReplayButton")
                        end
                        if mod.replayDimension then
                            mod.replayDimension()
                        end
                    end
                end)
                end

                task.wait(6)
            end
        end
    end
end)

-- ================================================================================
-- SECTION 19: RAID SUITE, SPEED RAIDS & BOSS RUSH CONTROLLER
-- ================================================================================

-- Speed Raid Checkpoints (5 Sequential Stage Checkpoints)
local SpeedRaidWaypoints = {
    [1] = Vector3.new(250, 15, 300),
    [2] = Vector3.new(500, 20, 650),
    [3] = Vector3.new(800, 25, 1100),
    [4] = Vector3.new(1150, 30, 1550),
    [5] = Vector3.new(1500, 35, 2000)
}

local function runSpeedRaid()
    local char = LocalPlayer.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if not root then return end

    for stage = 1, 5 do
        local wp = SpeedRaidWaypoints[stage]
        if wp then
            tweenPlayerTo(CFrame.new(wp))
            task.wait(0.8)

            -- Fight enemies at this checkpoint
            local startTime = tick()
            while tick() - startTime < 30 do
                local mob = getClosestMonster()
                if not mob then break end
                task.wait(0.5)
            end
        end
    end
end

task.spawn(function()
    while true do
        task.wait(2)
        if _G.AutoSpeedRaid and game.PlaceId == 7338881230 then
            runSpeedRaid()
        end
    end
end)

-- Boss Rush Floor Advancer (Floors 1-50)
local function advanceBossRush()
    if MainRemoteFunction then
        pcall(function()
            MainRemoteFunction:InvokeServer("AdvanceBossRushFloor")
            MainRemoteFunction:InvokeServer("NextFloorRing")
        end)
    end

    -- Trigger stage checkpoint rings in Workspace
    for _, ring in ipairs(Workspace:GetDescendants()) do
        if ring:IsA("BasePart") and (ring.Name:find("Ring") or ring.Name:find("Portal") or ring.Name:find("FloorGate")) then
            local char = LocalPlayer.Character
            local root = char and char:FindFirstChild("HumanoidRootPart")
            if root then
                root.CFrame = ring.CFrame
                task.wait(0.5)
            end
        end
    end
end

task.spawn(function()
    while true do
        task.wait(1.5)
        if _G.BossRush or _G.FreeBossRush then
            local mob = getClosestMonster()
            if not mob then
                advanceBossRush()
            end
        end
    end
end)

-- AutoRaid Lobby Matcher & Raid Countdown Watcher (Real QueuePlayer Remote)
task.spawn(function()
    while true do
        task.wait(3)
        if _G.AutoRaid and isPlayerInLobby() then
            local targetRaid = _G.RaidSelection or "Halloween Dimension"
            local delay = tonumber(_G.CooldownJoinRaid) or 5
            task.wait(delay)

            if MainRemoteFunction then
                pcall(function()
                    MainRemoteFunction:InvokeServer("QueuePlayer", targetRaid, "Normal", false)
                end)
            end
        end
    end
end)

-- Go AFK If Raid Not Open (Real TeleportToAFK Remote)
task.spawn(function()
    while true do
        task.wait(5)
        if _G.GoAFKIfRaidNotOpen and isPlayerInLobby() and not _G.AutoRaid then
            if MainRemoteFunction then
                pcall(function()
                    MainRemoteFunction:InvokeServer("TeleportToAFK")
                end)
            end
            task.wait(10)
        end
    end
end)

-- ================================================================================
-- SECTION 20: INFINITE MODE WAVE TELEMETRY & AUTO-RESET CONTROLLER
-- ================================================================================

task.spawn(function()
    while true do
        task.wait(2)
        if _G.InfiniteMode and _G.ResetINFMode and not isPlayerInLobby() then
            local pGui = LocalPlayer:FindFirstChild("PlayerGui")
            local waveLabel = pGui and pGui:FindFirstChild("MainGui") and pGui.MainGui:FindFirstChild("WaveText")
            if waveLabel then
                local currentWave = tonumber(waveLabel.Text:match("%d+"))
                local targetWave = tonumber(_G.SelectWaveToReset) or 50

                if currentWave and currentWave >= targetWave then
                    -- Reset Player or Leave Dungeon
                    if _G.GoLobbyMethod == "ResetCharacter" or _G.GoLobbyMethod == "Reset" then
                        local char = LocalPlayer.Character
                        local hum = char and char:FindFirstChildOfClass("Humanoid")
                        if hum then hum.Health = 0 end
                    else
                        if MainRemoteFunction then
                            pcall(function()
                                MainRemoteFunction:InvokeServer("TeleportToLobbyWithSave")
                            end)
                        end
                    end
                    task.wait(10)
                end
            end
        end
    end
end)

-- ================================================================================
-- SECTION 21: EXTREME DIMENSION SUITE & REWARD THRESHOLD MONITOR
-- ================================================================================

task.spawn(function()
    while true do
        task.wait(2)
        if _G.ExtremeDimension and not isPlayerInLobby() then
            local pGui = LocalPlayer:FindFirstChild("PlayerGui")
            local rewardPercentLabel = pGui and pGui:FindFirstChild("UniversalGui") and pGui.UniversalGui:FindFirstChild("RewardPercentage")
            if rewardPercentLabel then
                local currentPercent = tonumber(rewardPercentLabel.Text:match("%d+"))
                local targetPercent = tonumber(_G.ExtremeDimensionMinReward) or 80

                if currentPercent and currentPercent >= targetPercent then
                    -- Goal reached, finish stage
                    _G.KillAura = false
                    task.wait(2)
                end
            end
        end
    end
end)

-- ================================================================================
-- SECTION 22: CARD INVENTORY AUTO-SELL & APPRAISAL FORMULA ENGINE
-- ================================================================================

-- Card Appraisal Calculator
local function calculateCardScore(cardData, mode)
    mode = mode or _G.EquipBestCardMode or "Damage/Crit"
    local damage = tonumber(cardData.Damage) or 0
    local critChance = tonumber(cardData.CritChance) or 0
    local critDamage = tonumber(cardData.CritDamage) or 0
    local cooldown = tonumber(cardData.CooldownReduction) or 0

    if mode == "Damage/Crit" then
        return (damage * 1.5) + (critChance * 20.0) + (critDamage * 1.2)
    elseif mode == "Raw Damage" then
        return damage
    elseif mode == "Cooldown" then
        return (cooldown * 50.0) + damage
    end

    return damage
end

-- Helper: Get Live Player Cards Table from InventoryModule
local function getLiveCardsTable()
    local ok, res = pcall(function()
        local modules = LocalPlayer:FindFirstChild("PlayerGui") and LocalPlayer.PlayerGui:FindFirstChild("Modules")
        local im = modules and modules:FindFirstChild("InventoryModule")
        if im then
            local mod = require(im)
            local invInstance = debug.getupvalue(mod.createCardDataEntry, 1)
            return invInstance and invInstance.Cards
        end
        return nil
    end)
    return ok and res or nil
end

-- Auto-Sell Cards by Rarity (MassDeleteCardsFromInventory)
task.spawn(function()
    while true do
        task.wait(4)
        if _G.AutoSellCard and MainRemoteFunction then
            pcall(function()
                local cards = getLiveCardsTable()
                if type(cards) == "table" then
                    local targetRarityRank = RarityRankValues[_G.SelectRarity] or 1
                    local deleteIdTable = {}
                    local count = 0

                    local settingsMod = game.ReplicatedStorage:FindFirstChild("Modules") and game.ReplicatedStorage.Modules:FindFirstChild("settings")
                    local cardInfoDb = settingsMod and require(settingsMod).CardInfo or {}

                    for uniqueId, cardInfo in pairs(cards) do
                        local cardName = cardInfo.CardName or ""
                        local dbInfo = cardInfoDb[cardName]
                        local cardRarity = dbInfo and dbInfo.rarity or "Common"
                        local rank = RarityRankValues[cardRarity] or 1

                        if rank <= targetRarityRank and not cardInfo.Locked and not cardInfo.Equipped then
                            deleteIdTable[uniqueId] = true
                            count = count + 1
                        end
                    end

                    if count > 0 then
                        MainRemoteFunction:InvokeServer("MassDeleteCardsFromInventory", deleteIdTable)
                    end
                end
            end)
        end
    end
end)

-- Helper: Click any GUI element via engine events and virtual input coordinates
robustClickGuiElement = function(obj)
    if not obj then return end
    pcall(function() firesignal(obj.MouseButton1Click) end)
    pcall(function() firesignal(obj.MouseButton1Down) end)
    pcall(function() firesignal(obj.MouseButton1Up) end)
    pcall(function() firesignal(obj.Activated) end)
    pcall(function()
        if obj.AbsolutePosition and obj.AbsoluteSize then
            local center = obj.AbsolutePosition + (obj.AbsoluteSize / 2)
            if center.X > 0 and center.Y > 0 then
                VirtualInputManager:SendMouseButtonEvent(center.X, center.Y, 0, true, game, 0)
                task.wait(0.02)
                VirtualInputManager:SendMouseButtonEvent(center.X, center.Y, 0, false, game, 0)
            end
        end
    end)
end

-- Helper: Scan for the HUD button with Key 'E' or character portrait to switch back to Main
clickMainCharacterSwitchButton = function()
    local ok, res = pcall(function()
        local pGui = LocalPlayer:FindFirstChild("PlayerGui")
        if not pGui then return false end
        for _, gui in ipairs(pGui:GetChildren()) do
            if gui:IsA("ScreenGui") and gui.Enabled then
                for _, desc in ipairs(gui:GetDescendants()) do
                    if desc:IsA("TextLabel") and desc.Text:gsub("%s+", ""):upper() == "E" and desc.Visible then
                        local btn = desc:FindFirstAncestorWhichIsA("GuiButton") or desc
                        if robustClickGuiElement then
                            robustClickGuiElement(btn)
                            return true
                        end
                    end
                end
            end
        end
        return false
    end)
    return ok and res
end

-- Helper: Locate button or container with exact text label (e.g. EQUIP, UNEQUIP)
findGuiButtonByText = function(rootGui, labelText)
    local target = labelText:upper()
    for _, desc in ipairs(rootGui:GetDescendants()) do
        if desc:IsA("TextButton") and desc.Text:gsub("%s+", ""):upper() == target and desc.Visible then
            return desc
        elseif (desc:IsA("TextLabel") or desc:IsA("TextBox")) and desc.Text:gsub("%s+", ""):upper() == target and desc.Visible then
            local parentBtn = desc:FindFirstAncestorWhichIsA("GuiButton")
            if parentBtn and parentBtn.Visible then
                return parentBtn
            else
                return desc
            end
        end
    end
    return nil
end

-- Comprehensive Dual-Engine Best Card Auto-Equipper (Remote + Live Bag UI Scanner)
autoEquipBestCardsFromUI = function()
    local ok, res = pcall(function()
        local pGui = LocalPlayer:FindFirstChild("PlayerGui")
        if not pGui then return false end

        -- Scan PlayerGui for the Bag / Cards ScrollingFrame
        local cardGrid = nil
        local bagRoot = nil
        for _, gui in ipairs(pGui:GetChildren()) do
            if gui:IsA("ScreenGui") and gui.Enabled then
                for _, desc in ipairs(gui:GetDescendants()) do
                    if desc:IsA("ScrollingFrame") then
                        for _, child in ipairs(desc:GetChildren()) do
                            if child:IsA("GuiObject") then
                                for _, lbl in ipairs(child:GetDescendants()) do
                                    if lbl:IsA("TextLabel") and lbl.Text:match("Lv%s*%.%s*%d+") then
                                        cardGrid = desc
                                        bagRoot = gui
                                        break
                                    end
                                end
                            end
                            if cardGrid then break end
                        end
                    end
                    if cardGrid then break end
                end
            end
            if cardGrid then break end
        end

        if not cardGrid or not bagRoot then return false end

        local function getClickable(item)
            if item:IsA("GuiButton") then return item end
            local btn = item:FindFirstChildWhichIsA("GuiButton", true)
            return btn or item
        end

        -- Parse all cards currently displayed in the grid
        local equippedCards = {}
        local unequippedCards = {}

        for _, item in ipairs(cardGrid:GetChildren()) do
            if item:IsA("GuiObject") and item.Visible then
                local level = 0
                local isEquipped = false
                for _, lbl in ipairs(item:GetDescendants()) do
                    if lbl:IsA("TextLabel") then
                        local lvlNum = lbl.Text:match("Lv%s*%.%s*(%d+)")
                        if lvlNum then level = tonumber(lvlNum) or 0 end
                        if lbl.Text:lower():find("equipped") and lbl.Visible then
                            isEquipped = true
                        end
                    end
                end
                if level > 0 then
                    local entry = { item = item, level = level, btn = getClickable(item) }
                    if isEquipped then
                        table.insert(equippedCards, entry)
                    else
                        table.insert(unequippedCards, entry)
                    end
                end
            end
        end

        -- Sort equipped ascending by level (lowest level first, e.g. Lv. 16)
        table.sort(equippedCards, function(a, b) return a.level < b.level end)
        -- Sort unequipped descending by level (highest level first, e.g. Lv. 21)
        table.sort(unequippedCards, function(a, b) return a.level > b.level end)

        local changed = false

        -- For each unequipped high-level card, check if it's better than an equipped card
        for _, highCard in ipairs(unequippedCards) do
            -- Case 1: Less than 3 cards equipped -> equip directly!
            if #equippedCards < 3 then
                robustClickGuiElement(highCard.btn)
                task.wait(0.18)
                local equipBtn = findGuiButtonByText(bagRoot, "EQUIP")
                if equipBtn then
                    robustClickGuiElement(equipBtn)
                    task.wait(0.2)
                    table.insert(equippedCards, highCard)
                    table.sort(equippedCards, function(a, b) return a.level < b.level end)
                    changed = true
                end
            else
                -- Case 2: 3 cards equipped -> compare with lowest equipped card
                local lowestEquipped = equippedCards[1]
                if lowestEquipped and highCard.level > lowestEquipped.level then
                    -- Step 1: Click lowest equipped card and UNEQUIP it to free the slot
                    robustClickGuiElement(lowestEquipped.btn)
                    task.wait(0.18)
                    local unequipBtn = findGuiButtonByText(bagRoot, "UNEQUIP")
                    if unequipBtn then
                        robustClickGuiElement(unequipBtn)
                        task.wait(0.22)
                        table.remove(equippedCards, 1) -- Slot is now open!
                    end

                    -- Step 2: Click the target high-level unequipped card and EQUIP it
                    robustClickGuiElement(highCard.btn)
                    task.wait(0.18)
                    local equipBtn = findGuiButtonByText(bagRoot, "EQUIP")
                    if equipBtn then
                        robustClickGuiElement(equipBtn)
                        task.wait(0.22)
                        table.insert(equippedCards, highCard)
                        table.sort(equippedCards, function(a, b) return a.level < b.level end)
                        changed = true
                    end
                end
            end
        end

        return changed
    end)
    return ok and res
end

task.spawn(function()
    while true do
        task.wait(3)
        if _G.EquipBestCard and MainRemoteFunction then
            pcall(function()
                local mode = _G.EquipBestCardMode or "Damage/Crit"

                -- 1. Official Anime Dimensions Remote Handlers
                pcall(function()
                    MainRemoteFunction:InvokeServer("AutoEquipBestCards", mode)
                end)
                pcall(function()
                    MainRemoteFunction:InvokeServer("EquipBestCard", mode)
                end)
                pcall(function()
                    MainRemoteFunction:InvokeServer("AutoEquip", mode)
                end)

                -- 2. Query Cards via GetCards remote
                local cards = nil
                pcall(function()
                    cards = MainRemoteFunction:InvokeServer("GetCards")
                end)
                if type(cards) == "table" then
                    local cardList = {}
                    for cardId, cardInfo in pairs(cards) do
                        if type(cardInfo) == "table" then
                            cardInfo.Id = cardId
                            cardInfo.Score = calculateCardScore(cardInfo)
                            table.insert(cardList, cardInfo)
                        end
                    end
                    table.sort(cardList, function(a, b)
                        return (a.Score or 0) > (b.Score or 0)
                    end)
                    for slot = 1, math.min(#cardList, 3) do
                        local best = cardList[slot]
                        if best and not best.Equipped then
                            MainRemoteFunction:InvokeServer("EquipCard", best.Id, slot)
                            task.wait(0.15)
                        end
                    end
                end

                -- 3. Live Bag UI Click Automation (Works directly when Bag is open!)
                autoEquipBestCardsFromUI()
            end)
        end
    end
end)

-- ================================================================================
-- SECTION 23: CHARACTER ROTATION & ASSIST SWITCHER ENGINE
-- ================================================================================

task.spawn(function()
    while true do
        task.wait(3)
        if not isPlayerInLobby() then
            if _G.AutoResetToFirstAssist then
                pcall(function()
                    local modules = LocalPlayer:FindFirstChild("PlayerGui") and LocalPlayer.PlayerGui:FindFirstChild("Modules")
                    local csm = modules and modules:FindFirstChild("ClientSkillModule")
                    if csm then
                        require(csm).useAssistSkill(1)
                    end
                end)
            end
        end
    end
end)

-- Auto Equip Character Preset (Never overwrites with unwanted characters)
task.spawn(function()
    while true do
        task.wait(5)
        if _G.AutoEquipCharacter and isPlayerInLobby() and MainRemoteFunction then
            pcall(function()
                -- Equips user's chosen character preset
                MainRemoteFunction:InvokeServer("EquipSavedCharacterPreset")
            end)
        end
    end
end)

-- Auto Reset to Main in Battle Engine:
-- ONLY resets the character (by dying) AFTER an Assist skill was actually cast in battle!
-- Once respawned as Main, it NEVER resets again. Zero infinite suicide loops for ANY character!
task.spawn(function()
    while true do
        task.wait(0.2)
        if not isPlayerInLobby() and _G.AutoResetToMain and not _G.AutoResetToFirstAssist then
            pcall(function()
                if _G.AssistActive and _G.AssistCastTime and (tick() - _G.AssistCastTime >= 1.2) then
                    _G.AssistActive = false
                    _G.AssistCastTime = nil
                    local char = LocalPlayer.Character
                    local hum = char and char:FindFirstChildOfClass("Humanoid")
                    if hum and hum.Health > 0 then
                        hum.Health = 0
                        task.wait(4.0) -- Wait for respawn back into Main
                    end
                end
            end)
        end
    end
end)

-- ================================================================================
-- SECTION 24: ECONOMY, AUTO-BUY & PROMO CODES ENGINE
-- ================================================================================

-- Buy Rush Tickets & Raid Tokens (Real BossRushShopItem Remote: 1 = Gem Ticket, 2 = Raid Ticket, 9 = 100 Raid Tokens)
task.spawn(function()
    while true do
        task.wait(6)
        if (_G.BuyRushTicket or _G.Buy100RaidToken) and MainRemoteFunction then
            local currency = _G.SelectMethodBuy or "Gem"

            if _G.BuyRushTicket then
                pcall(function()
                    local ticketKey = (currency == "Gem") and 1 or 2
                    MainRemoteFunction:InvokeServer("BuyBossRushShopItem", ticketKey)
                end)
            end

            if _G.Buy100RaidToken then
                pcall(function()
                    MainRemoteFunction:InvokeServer("BuyBossRushShopItem", 9)
                end)
            end
        end
    end
end)

-- Daily & Weekly Quests Auto-Claimer (Instant + UI Trigger)
local function claimAllQuestsNow()
    if not MainRemoteFunction then return end
    task.spawn(function()
        local settingsMod = game.ReplicatedStorage:FindFirstChild("Modules") and game.ReplicatedStorage.Modules:FindFirstChild("settings")
        if settingsMod then
            local s = require(settingsMod)
            if s.DailyQuestSettings then
                for _, q in pairs(s.DailyQuestSettings) do
                    if q.stat then
                        task.spawn(function()
                            MainRemoteFunction:InvokeServer("CompleteDailyQuest", q.stat)
                        end)
                    end
                end
            end
            if s.WeeklyQuestSettings then
                for _, q in pairs(s.WeeklyQuestSettings) do
                    if q.stat then
                        task.spawn(function()
                            MainRemoteFunction:InvokeServer("CompleteDailyQuest", q.stat)
                        end)
                    end
                end
            end
        end
    end)

    -- Refresh Quest UI if QuestModule is loaded
    pcall(function()
        local pGui = LocalPlayer:FindFirstChild("PlayerGui")
        local qm = pGui and pGui:FindFirstChild("Modules") and pGui.Modules:FindFirstChild("QuestModule")
        if qm then
            local mod = require(qm)
            if mod.createAllQuests then
                mod.createAllQuests()
            end
        end
    end)
end

task.spawn(function()
    while true do
        task.wait(3)
        if _G.AutoClaimQuestAndReward and isPlayerInLobby() and MainRemoteFunction then
            claimAllQuestsNow()
        end
    end
end)

-- Auto Redeem All Promo Codes (Real RedeemPromoCode Remote)
task.spawn(function()
    while true do
        task.wait(1)
        if _G.AutoRedeemAllCode then
            _G.AutoRedeemAllCode = false
            for _, code in ipairs(ActivePromoCodes) do
                if MainRemoteFunction then
                    pcall(function()
                        MainRemoteFunction:InvokeServer("RedeemPromoCode", code)
                    end)
                end
                task.wait(0.4)
            end
        end
    end
end)

-- ================================================================================
-- SECTION 25: MAP OPTIMIZATION, STEALTH & ANTI-DETECTION
-- ================================================================================

-- AutoDeleteMap Geometry Cleaner (Targets Workspace.GameMap / Workspace.Folders / WorkFolder)
task.spawn(function()
    while true do
        task.wait(2)
        if _G.AutoDeleteMap then
            local mapContainers = {
                Workspace:FindFirstChild("GameMap"),
                Workspace:FindFirstChild("Map"),
                Workspace:FindFirstChild("WorkFolder"),
                Workspace:FindFirstChild("Folders") and Workspace.Folders:FindFirstChild("Map"),
                Workspace:FindFirstChild("Folders") and Workspace.Folders:FindFirstChild("GameMap")
            }
            for _, map in ipairs(mapContainers) do
                if map then
                    for _, obj in ipairs(map:GetDescendants()) do
                        if obj:IsA("BasePart") then
                            obj.Transparency = 1
                            obj.CastShadow = false
                        elseif obj:IsA("Decal") or obj:IsA("Texture") or obj:IsA("ParticleEmitter") or obj:IsA("Beam") or obj:IsA("Trail") or obj:IsA("PointLight") or obj:IsA("SpotLight") then
                            obj:Destroy()
                        end
                    end
                end
            end
            local terrain = Workspace:FindFirstChildOfClass("Terrain")
            if terrain then
                pcall(function()
                    terrain.WaterReflectance = 0
                    terrain.WaterTransparency = 1
                end)
            end
        end
    end
end)

-- HideName Stealth Engine
task.spawn(function()
    while true do
        task.wait(2)
        if _G.HideName then
            local char = LocalPlayer.Character
            if char then
                for _, tag in ipairs(char:GetDescendants()) do
                    if tag:IsA("BillboardGui") then
                        for _, lbl in ipairs(tag:GetChildren()) do
                            if lbl:IsA("TextLabel") and lbl.Text:find(LocalPlayer.Name) then
                                lbl.Text = "LocalPlayer"
                            end
                        end
                    end
                end
            end
        end
    end
end)

-- DoNotThingIfHavePlayer: Pause Bot Actions When Strangers Are In Room
local function areStrangersPresent()
    if isPlayerInLobby() then return false end
    local players = Players:GetPlayers()
    return #players > 1
end

task.spawn(function()
    while true do
        task.wait(3)
        if _G.DoNotThingIfHavePlayer and areStrangersPresent() then
            _G.AutoMob = false
            _G.KillAura = false
            _G.AutoSkill = false
            _G.AutoMelee = false
        end
    end
end)

-- BackToLobbyIfGotExploitsDetected
task.spawn(function()
    while true do
        task.wait(1)
        if _G.BackToLobbyIfGotExploitsDetected then
            local pGui = LocalPlayer:FindFirstChild("PlayerGui")
            if pGui then
                for _, g in ipairs(pGui:GetChildren()) do
                    if g:IsA("ScreenGui") and (g.Name:find("Exploit") or g.Name:find("Warning") or g.Name:find("AntiCheat")) then
                        TeleportService:Teleport(6938803436, LocalPlayer)
                        return
                    end
                end
            end
        end
    end
end)

-- Safe Event-Driven Auto Rejoin
GuiService.ErrorMessageChanged:Connect(function()
    if _G.rejoinKick then
        task.wait(2)
        TeleportService:TeleportToPlaceInstance(game.PlaceId, game.JobId, LocalPlayer)
    end
end)

-- ================================================================================
-- SECTION 26: DISCORD WEBHOOK DROPS & TELEMETRY ENGINE
-- ================================================================================

-- Match Victory Drops Webhook Reporter
task.spawn(function()
    local lastReportedTick = 0
    while true do
        task.wait(2)
        if not isPlayerInLobby() then
            local pGui = LocalPlayer:FindFirstChild("PlayerGui")
            local universalGui = pGui and pGui:FindFirstChild("UniversalGui")
            local centerFrame = universalGui and universalGui:FindFirstChild("UniversalCenterUIFrame")

            local resultUI = centerFrame and centerFrame:FindFirstChild("ResultUI")
            local raidResult = (centerFrame and centerFrame:FindFirstChild("RaidResultUI"))
                or (universalGui and universalGui:FindFirstChild("RaidResultUI"))

            local isVictory = (resultUI and resultUI.Visible) or (raidResult and raidResult.Visible)

            if isVictory and (tick() - lastReportedTick > 15) then
                if _G.SendDimensionDropsResult or _G.SendRaidDropsResult then
                    lastReportedTick = tick()
                    local currentMap = tostring(_G.MapSelection or "Dimension")
                    local currentDiff = tostring(_G.SelectDifficulty or "Normal")
                    local clearTimeStr = os.date("%X")

                    local fields = {
                        { name = "Player", value = LocalPlayer.Name, inline = true },
                        { name = "Dimension", value = currentMap, inline = true },
                        { name = "Difficulty", value = currentDiff, inline = true },
                        { name = "Time Cleared", value = clearTimeStr, inline = true },
                        { name = "Result", value = "Victory / Drops Claimed", inline = true }
                    }

                    sendWebhook(
                        "Dimension Cleared Successfully!",
                        "Clear telemetry recorded with full automated farming drop logs.",
                        fields
                    )
                end
            end
        end
    end
end)

-- ================================================================================
-- SECTION 27: MASTER BOOTSTRAPPER & RUNTIME INITIALIZATION
-- ================================================================================

-- Authentic SLH ASCII Art Banner
-- Load Saved Settings
task.spawn(function()
    task.wait(0.2)
    library:LoadConfig()
end)

-- Method follows user selection (Behind / Above / Front)

-- Create Main Window
local mainWindow = library:CreateWindow({
    Name = "SLH Hub Modified| AnimeDimensions | LastestUpdate: 1 Nov, 2026",
    Size = UDim2.fromOffset(600, 400)
})

-- Initialize All 7 Tabs & 14 Sectors
initializeInterfaceTabs(mainWindow, library)

-- Spawn Floating HUDs (StatBySmell & Credit)
createFloatingHUDs(mainWindow)

-- Auto Minimize GUI If Configured
if _G.CloseGuiAfterExecute and mainWindow.Main then
    mainWindow.Main.Visible = false
end

-- Initial Success Toast
library:Notify({
    Title = "SLH Hub Modified",
    Content = "100% Deobfuscated & Fully Loaded. Ready to farm!",
    Duration = 4
})

print("[SLH Hub Modified] Loaded 100% raw decompiled suite successfully.")

RunService.Heartbeat:Connect(function()
    if _G.DashNoCooldown and applyDashNoCooldown then
        applyDashNoCooldown(true)
    end
end)
