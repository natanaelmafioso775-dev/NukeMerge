local Repo = "https://raw.githubusercontent.com/deividcomsono/Obsidian/main/"

local Library = loadstring(game:HttpGet(Repo .. "Library.lua"))()
local ThemeManager = loadstring(game:HttpGet(Repo .. "addons/ThemeManager.lua"))()
local SaveManager = loadstring(game:HttpGet(Repo .. "addons/SaveManager.lua"))()

local Options = Library.Options
local Toggles = Library.Toggles

local Window = Library:CreateWindow({
    Title = "Nuke Merge",
    Footer = "Auto Nuke Merger",
    Icon = "bomb",
    NotifySide = "Right",
    ShowCustomCursor = true,
    Resizable = true,
    Size = UDim2.fromOffset(600, 550),
})

local Tabs = {
    Main = Window:AddTab("Main", "bomb"),
    Upgrades = Window:AddTab("Upgrades", "trending-up"),
    ["UI Settings"] = Window:AddTab("UI Settings", "settings"),
}

-- Services
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local LocalPlayer = Players.LocalPlayer

-- Remotes
local NukeRemotes = ReplicatedStorage:WaitForChild("NukeRemotes")
local PickUpRemote = NukeRemotes:WaitForChild("PickUp")
local MergeRequestRemote = NukeRemotes:WaitForChild("MergeRequest")
local DropRemote = NukeRemotes:WaitForChild("Drop")
local PurchaseUpgradeRemote = NukeRemotes:WaitForChild("PurchaseUpgrade")
local StateUpdate = NukeRemotes:WaitForChild("StateUpdate")
local HoldStarted = NukeRemotes:WaitForChild("HoldStarted")
local HoldEnded = NukeRemotes:WaitForChild("HoldEnded")
local RequestLockBase = NukeRemotes:WaitForChild("RequestLockBase")
local LockStateUpdate = NukeRemotes:WaitForChild("LockStateUpdate")

-- Variaveis de estado
local state = {
    isHolding = false,
    holdingNuke = nil,
    busy = false,
    lastScan = 0,
    scanCount = 0,
    mergedCount = 0,
    pickedCount = 0,
    droppedCount = 0,
    holdTimer = 0,
    forceDropped = false,
}

local AutoMergeEnabled = false
local TeleportSpeed = 0.5
local FarmDelay = 0.2
local DropTimeout = 2.0
local PickUpRadius = 100

-- Variaveis de upgrade
local upgradeState = {
    cash = 0,
    upgrades = {},
}
local upgradeTypes = { "TIER", "LOCKBASE", "MAX" }
local autoUpgradeAllEnabled = false
local autoUpgradeEnabled = {
    TIER = false,
    LOCKBASE = false,
    MAX = false,
}
local upgradeConfig = {
    TIER = { delay = 1.0, maxBuys = 999, bought = 0 },
    LOCKBASE = { delay = 1.0, maxBuys = 999, bought = 0 },
    MAX = { delay = 1.0, maxBuys = 999, bought = 0 },
}
local lastUpgradeTimers = {}
local lastStatsUpdate = 0

-- Variaveis de Lock Base
local lockPhase = "free"
local autoLockEnabled = false
local lastLockTime = 0
LockStateUpdate.OnClientEvent:Connect(function(phase, remaining)
    lockPhase = phase or "free"
    if phase == "locked" or phase == "cooldown" then
        lastLockTime = os.clock()
    end
end)

-- Referencias dos labels
local BaseInfoLabel = nil
local NukeInfoLabel = nil
local StatusLabel = nil
local LockStatusLabel = nil

-- Cache da pasta de nukes
local cachedNukesFolder = nil

local function FindMyNukesFolder()
    if cachedNukesFolder and cachedNukesFolder.Parent then
        return cachedNukesFolder
    end
    cachedNukesFolder = nil

    local Bases = Workspace:FindFirstChild("Bases")
    if not Bases then return nil end

    for _, base in ipairs(Bases:GetChildren()) do
        local Nukes = base:FindFirstChild("Nukes")
        if Nukes then
            for _, nuke in ipairs(Nukes:GetChildren()) do
                if nuke:GetAttribute("OwnerUserId") == LocalPlayer.UserId then
                    cachedNukesFolder = Nukes
                    CurrentBase = base
                    return Nukes
                end
            end
        end
    end
    return nil
end

-- Le o texto do OverheadNuke.TextLabel
local function GetNukeNumber(nuke)
    if type(nuke) ~= "userdata" then return tostring(nuke) end
    local overhead = nuke:FindFirstChild("OverheadNuke")
    if overhead then
        local textLabel = overhead:FindFirstChild("TextLabel")
        if textLabel then
            return textLabel.Text
        end
    end
    return nil
end

-- Eventos do servidor
HoldStarted.OnClientEvent:Connect(function(nukeInstance)
    state.isHolding = true
    state.holdingNuke = nukeInstance
    state.holdTimer = os.clock()
    state.forceDropped = false
    if StatusLabel then
        local num = GetNukeNumber(nukeInstance) or "?"
        StatusLabel:SetText("Holding nuke: " .. num)
    end
end)

HoldEnded.OnClientEvent:Connect(function()
    state.isHolding = false
    state.holdingNuke = nil
    state.forceDropped = false
    if StatusLabel then
        StatusLabel:SetText("Not holding anything")
    end
end)

-- Atualizacoes de estado do servidor (cash, upgrades)
StateUpdate.OnClientEvent:Connect(function(data)
    if data then
        if data.cash then upgradeState.cash = data.cash end
        if data.upgrades then upgradeState.upgrades = data.upgrades end
    end
end)

-- Funcao para comprar upgrade
local function BuyUpgrade(upgradeType)
    pcall(function()
        PurchaseUpgradeRemote:FireServer(upgradeType)
    end)
    Library:Notify({ Title = "Upgrade", Description = upgradeType .. " purchased!", Time = 2 })
end

-- Loop de auto upgrade
local function PerformUpgradeScan()
    local isAllEnabled = autoUpgradeAllEnabled
    for _, utype in ipairs(upgradeTypes) do
        if autoUpgradeEnabled[utype] or isAllEnabled then
            local upg = upgradeState.upgrades[utype]
            local cfg = upgradeConfig[utype]
            if upg and not upg.maxed and cfg.bought < cfg.maxBuys then
                BuyUpgrade(utype)
                cfg.bought = cfg.bought + 1
                task.wait(0.3)
                return
            end
        end
    end
end

-- Funcao para travar base
local function FireLockBase()
    pcall(function()
        RequestLockBase:FireServer()
    end)
end

-- Forcar drop
local function ForceDrop()
    if not state.isHolding or state.forceDropped then return end
    state.forceDropped = true
    state.droppedCount = state.droppedCount + 1

    local char = LocalPlayer.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if root then
        pcall(function()
            DropRemote:FireServer(root.CFrame)
        end)
    end

    state.isHolding = false
    state.holdingNuke = nil
    state.busy = false
end

-- Teleportar
local function TeleportTo(position)
    local char = LocalPlayer.Character
    if char and char:FindFirstChild("HumanoidRootPart") then
        char.HumanoidRootPart.CFrame = CFrame.new(position + Vector3.new(0, 5, 0))
    end
end

-- Funcao principal - igual ao performSequence do CHAD
local function PerformSequence()
    if state.busy then return end

    local nukesFolder = FindMyNukesFolder()
    if not nukesFolder then return end

    local char = LocalPlayer.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if not root then return end

    -- Coletar nukes no chao agrupadas por numero
    local floorNukes = {}
    for _, nuke in ipairs(nukesFolder:GetChildren()) do
        if nuke:IsA("BasePart") then
            local nukeState = nuke:GetAttribute("State")
            if nukeState == "floor" or nukeState == "based" then
                local dx = nuke.Position.X - root.Position.X
                local dz = nuke.Position.Z - root.Position.Z
                local dist = math.sqrt(dx * dx + dz * dz)

                if dist <= PickUpRadius then
                    local numero = GetNukeNumber(nuke)
                    if numero then
                        if not floorNukes[numero] then
                            floorNukes[numero] = {}
                        end
                        table.insert(floorNukes[numero], {
                            instance = nuke,
                            dist = dist,
                        })
                    end
                end
            end
        end
    end

    -- Cenario 1: Esta segurando um nuke
    if state.isHolding then
        local heldNumber = GetNukeNumber(state.holdingNuke)
        local pairExists = false

        if heldNumber and floorNukes[heldNumber] then
            for _, nukeData in ipairs(floorNukes[heldNumber]) do
                if nukeData.instance ~= state.holdingNuke then
                    pairExists = true
                    break
                end
            end
        end

        if not pairExists then
            -- Drop: solta o nuke (sem par)
            state.busy = true
            state.droppedCount = state.droppedCount + 1
            ForceDrop()
            task.wait(FarmDelay)
            state.busy = false
        end
        return
    end

    -- Cenario 2: Tem 2+ nukes com o MESMO numero no chao
    for numero, nukeGroup in pairs(floorNukes) do
        if #nukeGroup >= 2 then
            table.sort(nukeGroup, function(a, b) return a.dist < b.dist end)

            local targetNuke = nukeGroup[1].instance
            local mergeTarget = nukeGroup[2].instance

            state.busy = true
            state.pickedCount = state.pickedCount + 1

            -- PASSO 1: TP ate o primeiro nuke
            TeleportTo(targetNuke.Position)
            task.wait(TeleportSpeed)

            -- PASSO 2: PickUp
            pcall(function()
                PickUpRemote:FireServer(targetNuke)
            end)

            -- PASSO 3: Aguardar segurar
            task.spawn(function()
                local timeout = os.clock() + DropTimeout
                while not state.isHolding and os.clock() < timeout do
                    task.wait(0.05)
                end

                if state.isHolding then
                    task.wait(FarmDelay)

                    -- PASSO 4: TP ate o segundo nuke (merge)
                    if mergeTarget and mergeTarget.Parent then
                        TeleportTo(mergeTarget.Position)
                        task.wait(TeleportSpeed)

                        -- PASSO 5: Merge
                        state.mergedCount = state.mergedCount + 1
                        pcall(function()
                            MergeRequestRemote:FireServer(mergeTarget)
                        end)

                        Library:Notify({
                            Title = "Nuke Merge",
                            Description = "Merge " .. numero .. " + " .. numero .. " done!",
                            Time = 2,
                        })
                    end
                end

                task.wait(FarmDelay)
                state.busy = false
            end)

            return -- Apenas uma sequencia por scan
        end
    end
end

-- Atualiza labels
local function UpdateInfoLabels()
    if not NukeInfoLabel then return end

    local floorNukes = {}
    local nukesFolder = FindMyNukesFolder()
    if nukesFolder then
        for _, nuke in ipairs(nukesFolder:GetChildren()) do
            if nuke:IsA("BasePart") then
                local nukeState = nuke:GetAttribute("State")
                if nukeState == "floor" or nukeState == "based" then
                    local num = GetNukeNumber(nuke) or "?"
                    if not floorNukes[num] then floorNukes[num] = 0 end
                    floorNukes[num] = floorNukes[num] + 1
                end
            end
        end
    end

    local infoText = "Floor nukes:\n"
    for num, count in pairs(floorNukes) do
        infoText = infoText .. "  " .. num .. ": " .. count .. "x\n"
    end
    if next(floorNukes) == nil then
        infoText = infoText .. "  (none)"
    end

    infoText = infoText .. "\nPickUps: " .. state.pickedCount .. " | Merges: " .. state.mergedCount .. " | Drops: " .. state.droppedCount

    NukeInfoLabel:SetText(infoText)

    if BaseInfoLabel and CurrentBase then
        BaseInfoLabel:SetText("Base: " .. CurrentBase.Name)
    end
end

-- Loop principal
RunService.Heartbeat:Connect(function()
    if not AutoMergeEnabled then return end
    local now = os.clock()

    -- Timeout: se segurando por mais que DropTimeout sem acao
    if state.isHolding and not state.forceDropped and not state.busy then
        if now - state.holdTimer >= DropTimeout then
            ForceDrop()
        end
    end

    if now - state.lastScan >= FarmDelay then
        state.lastScan = now
        state.scanCount = state.scanCount + 1
        PerformSequence()
    end

    -- Atualizar labels a cada 30 scans
    if state.scanCount % 30 == 0 then
        UpdateInfoLabels()
        -- Atualizar status do lock
        if LockStatusLabel then
            if lockPhase == "free" then
                LockStatusLabel:SetText("Lock: Free")
            elseif lockPhase == "locked" then
                LockStatusLabel:SetText("Lock: Locked")
            elseif lockPhase == "cooldown" then
                LockStatusLabel:SetText("Lock: Cooldown")
            end
        end
    end

    -- Auto Lock Base: try to lock when free
    if autoLockEnabled and lockPhase == "free" then
        if now - lastLockTime >= 5 then
            FireLockBase()
            lastLockTime = now
            Library:Notify({ Title = "Lock Base", Description = "Locking base...", Time = 1 })
        end
    end

    -- Auto Upgrade scan com delay individual por upgrade
    local hasAnyUpgrade = autoUpgradeAllEnabled
    if not hasAnyUpgrade then
        for _, utype in ipairs(upgradeTypes) do
            if autoUpgradeEnabled[utype] then
                hasAnyUpgrade = true
                break
            end
        end
    end

    if hasAnyUpgrade then
        for _, utype in ipairs(upgradeTypes) do
            local cfg = upgradeConfig[utype]
            if autoUpgradeEnabled[utype] or autoUpgradeAllEnabled then
                if not lastUpgradeTimers[utype] then
                    lastUpgradeTimers[utype] = 0
                end
                if now - lastUpgradeTimers[utype] >= cfg.delay then
                    lastUpgradeTimers[utype] = now
                    local upg = upgradeState.upgrades[utype]
                    if upg and not upg.maxed and cfg.bought < cfg.maxBuys then
                        BuyUpgrade(utype)
                        cfg.bought = cfg.bought + 1
                    end
                end
            end
        end
    end
end)

-- Parar merge
local function StopMerge()
    AutoMergeEnabled = false
    state.busy = false
    if state.isHolding then
        ForceDrop()
    end
end

-- UI Principal
local MainGroup = Tabs.Main:AddLeftGroupbox("Controls", "settings")

BaseInfoLabel = MainGroup:AddLabel({
    Text = "Base: Detecting...",
    DoesWrap = true,
})

StatusLabel = MainGroup:AddLabel({
    Text = "Idle",
    DoesWrap = true,
})

LockStatusLabel = MainGroup:AddLabel({
    Text = "Lock: ---",
    DoesWrap = true,
})

MainGroup:AddDivider()

MainGroup:AddToggle("AutoMerge", {
    Text = "Auto Merge",
    Default = false,
    Tooltip = "TP → PickUp → TP → Merge (only works with same number pairs)",
    Callback = function(Value)
        AutoMergeEnabled = Value
        if Value then
            if StatusLabel then
                StatusLabel:SetText("Auto Merge ACTIVE")
            end
        else
            StopMerge()
            if StatusLabel then
                StatusLabel:SetText("Auto Merge PAUSED")
            end
        end
    end,
})

MainGroup:AddDivider()

MainGroup:AddToggle("AutoLockBase", {
    Text = "Auto Lock Base",
    Default = false,
    Tooltip = "Locks the base automatically when free",
    Callback = function(Value)
        autoLockEnabled = Value
        if Value then
            Library:Notify({ Title = "Lock Base", Description = "Auto Lock ENABLED!", Time = 2 })
            FireLockBase()
        else
            Library:Notify({ Title = "Lock Base", Description = "Auto Lock DISABLED", Time = 2 })
        end
    end,
})

MainGroup:AddDivider()

MainGroup:AddLabel({ Text = "Settings", Size = 14 })

MainGroup:AddSlider("TeleportSpeed", {
    Text = "TP Speed",
    Default = 0.5,
    Min = 0.1,
    Max = 2,
    Rounding = 1,
    Suffix = "s",
    Callback = function(Value)
        TeleportSpeed = Value
    end,
})

MainGroup:AddSlider("FarmDelay", {
    Text = "Scan Interval",
    Default = 0.2,
    Min = 0.05,
    Max = 2,
    Rounding = 2,
    Suffix = "s",
    Callback = function(Value)
        FarmDelay = Value
    end,
})

MainGroup:AddSlider("DropTimeoutSlider", {
    Text = "Drop Timeout",
    Default = 2,
    Min = 0.5,
    Max = 5,
    Rounding = 1,
    Suffix = "s",
    Callback = function(Value)
        DropTimeout = Value
    end,
})

MainGroup:AddSlider("PickUpRadius", {
    Text = "PickUp Radius",
    Default = 100,
    Min = 10,
    Max = 200,
    Rounding = 0,
    Suffix = "studs",
    Callback = function(Value)
        PickUpRadius = Value
    end,
})

MainGroup:AddDivider()

NukeInfoLabel = MainGroup:AddLabel({
    Text = "Floor nukes:\n  (none)",
    DoesWrap = true,
})

MainGroup:AddDivider()

local InfoGroup = Tabs.Main:AddRightGroupbox("Actions", "info")

InfoGroup:AddButton({
    Text = "Scan Manual",
    Tooltip = "Run manual scan now",
    Func = function()
        if state.busy then
            Library:Notify({ Title = "Busy", Description = "Waiting for current sequence...", Time = 2 })
            return
        end
        PerformSequence()
        UpdateInfoLabels()
        Library:Notify({ Title = "Scan", Description = "Sequence executed!", Time = 2 })
    end,
})

InfoGroup:AddButton({
    Text = "Drop Nuke",
    Tooltip = "Drop the nuke you're holding",
    Func = function()
        if state.isHolding then
            ForceDrop()
            Library:Notify({ Title = "Drop", Description = "Nuke dropped!", Time = 2 })
        else
            Library:Notify({ Title = "Drop", Description = "Not holding anything", Time = 2 })
        end
    end,
})

InfoGroup:AddButton({
    Text = "Lock Base Now",
    Tooltip = "Lock the base immediately",
    Func = function()
        FireLockBase()
        Library:Notify({ Title = "Lock Base", Description = "Requesting lock...", Time = 2 })
    end,
})

InfoGroup:AddButton({
    Text = "Reset Stats",
    Tooltip = "Reset counters",
    Func = function()
        state.pickedCount = 0
        state.mergedCount = 0
        state.droppedCount = 0
        UpdateInfoLabels()
        Library:Notify({ Title = "Stats", Description = "Counters reset", Time = 2 })
    end,
})

-- Tab Upgrades
local UpgradeGroup = Tabs.Upgrades:AddLeftGroupbox("Auto Buy", "shopping-cart")

UpgradeGroup:AddToggle("AutoUpgradeAll", {
    Text = "Auto Buy ALL (3 upgrades)",
    Default = false,
    Tooltip = "Buys TIER, LOCKBASE and MAX automatically",
    Callback = function(Value)
        autoUpgradeAllEnabled = Value
        if Value then
            Library:Notify({ Title = "Upgrade", Description = "Auto Buy ALL enabled!", Time = 2 })
            PerformUpgradeScan()
        end
    end,
})

UpgradeGroup:AddDivider()

-- TIER
UpgradeGroup:AddToggle("AutoUpgradeTIER", {
    Text = "Auto TIER",
    Default = false,
    Tooltip = "Buys TIER upgrade automatically",
    Callback = function(Value)
        autoUpgradeEnabled.TIER = Value
        if Value then
            BuyUpgrade("TIER")
        end
    end,
})

UpgradeGroup:AddSlider("UpgradeDelayTIER", {
    Text = "TIER Delay",
    Default = 1.0,
    Min = 0.5,
    Max = 5,
    Rounding = 1,
    Suffix = "s",
    Callback = function(Value)
        upgradeConfig.TIER.delay = Value
    end,
})

UpgradeGroup:AddSlider("UpgradeMaxTIER", {
    Text = "TIER Max Buys",
    Default = 999,
    Min = 1,
    Max = 999,
    Rounding = 0,
    Callback = function(Value)
        upgradeConfig.TIER.maxBuys = Value
    end,
})

-- LOCKBASE
UpgradeGroup:AddToggle("AutoUpgradeLOCKBASE", {
    Text = "Auto LOCKBASE",
    Default = false,
    Tooltip = "Buys LOCKBASE upgrade automatically",
    Callback = function(Value)
        autoUpgradeEnabled.LOCKBASE = Value
        if Value then
            BuyUpgrade("LOCKBASE")
        end
    end,
})

UpgradeGroup:AddSlider("UpgradeDelayLOCKBASE", {
    Text = "LOCKBASE Delay",
    Default = 1.0,
    Min = 0.5,
    Max = 5,
    Rounding = 1,
    Suffix = "s",
    Callback = function(Value)
        upgradeConfig.LOCKBASE.delay = Value
    end,
})

UpgradeGroup:AddSlider("UpgradeMaxLOCKBASE", {
    Text = "LOCKBASE Max Buys",
    Default = 999,
    Min = 1,
    Max = 999,
    Rounding = 0,
    Callback = function(Value)
        upgradeConfig.LOCKBASE.maxBuys = Value
    end,
})

-- MAX
UpgradeGroup:AddToggle("AutoUpgradeMAX", {
    Text = "Auto MAX",
    Default = false,
    Tooltip = "Buys MAX upgrade automatically",
    Callback = function(Value)
        autoUpgradeEnabled.MAX = Value
        if Value then
            BuyUpgrade("MAX")
        end
    end,
})

UpgradeGroup:AddSlider("UpgradeDelayMAX", {
    Text = "MAX Delay",
    Default = 1.0,
    Min = 0.5,
    Max = 5,
    Rounding = 1,
    Suffix = "s",
    Callback = function(Value)
        upgradeConfig.MAX.delay = Value
    end,
})

UpgradeGroup:AddSlider("UpgradeMaxMAX", {
    Text = "MAX Max Buys",
    Default = 999,
    Min = 1,
    Max = 999,
    Rounding = 0,
    Callback = function(Value)
        upgradeConfig.MAX.maxBuys = Value
    end,
})

UpgradeGroup:AddDivider()

local ManualGroup = Tabs.Upgrades:AddRightGroupbox("Manual", "hand")

ManualGroup:AddButton({
    Text = "Buy TIER",
    Tooltip = "Buy TIER upgrade manually",
    Func = function()
        BuyUpgrade("TIER")
    end,
})

ManualGroup:AddButton({
    Text = "Buy LOCKBASE",
    Tooltip = "Buy LOCKBASE upgrade manually",
    Func = function()
        BuyUpgrade("LOCKBASE")
    end,
})

ManualGroup:AddButton({
    Text = "Buy MAX",
    Tooltip = "Buy MAX upgrade manually",
    Func = function()
        BuyUpgrade("MAX")
    end,
})

-- UI Settings
local MenuGroup = Tabs["UI Settings"]:AddLeftGroupbox("Menu", "wrench")

MenuGroup:AddToggle("KeybindMenuOpen", {
    Default = Library.KeybindFrame.Visible,
    Text = "Open Keybind Menu",
    Callback = function(value)
        Library.KeybindFrame.Visible = value
    end,
})

MenuGroup:AddDropdown("NotificationSide", {
    Values = { "Left", "Right" },
    Default = "Right",
    Text = "Notification Side",
    Callback = function(Value)
        Library:SetNotifySide(Value)
    end,
})

MenuGroup:AddDivider()
MenuGroup:AddLabel("Menu bind"):AddKeyPicker("MenuKeybind", {
    Default = "RightShift",
    NoUI = true,
    Text = "Menu keybind",
})

Library.ToggleKeybind = Options.MenuKeybind

-- Addons
ThemeManager:SetLibrary(Library)
SaveManager:SetLibrary(Library)
SaveManager:IgnoreThemeSettings()
SaveManager:SetIgnoreIndexes({ "MenuKeybind" })

ThemeManager:SetFolder("NukeMerge")
SaveManager:SetFolder("NukeMerge/settings")
SaveManager:BuildConfigSection(Tabs["UI Settings"])
ThemeManager:ApplyToTab(Tabs["UI Settings"])

SaveManager:LoadAutoloadConfig()

task.spawn(function()
    task.wait(1)
    UpdateInfoLabels()
end)

Library:Notify({
    Title = "Nuke Merge",
    Description = "Script loaded! Auto Lock included",
    Time = 3,
    Icon = "bomb",
})
