--[[
Fruit Hunter (Blox Fruits / Delta-oriented prototype)

IMPORTANT:
- Standalone; does not load Teddy Hub or reuse its obfuscated code.
- Teddy Hub's exact fruit-server discovery routine could not be recovered from the
  uploaded virtualized/obfuscated HopBoss.lua. This script therefore scans public
  server instances and verifies fruit presence AFTER joining each candidate.
- Roblox does not expose live fruit-spawn state in the public server-list API, so
  pre-selecting a fruit-containing server with certainty is not possible here.
- Game updates may change fruit Tool names, ToolTip values, or the StoreFruit remote.
- Use at your own risk; this is not an official Roblox feature.
]]

repeat task.wait() until game:IsLoaded()

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local HttpService = game:GetService("HttpService")
local TeleportService = game:GetService("TeleportService")
local UserInputService = game:GetService("UserInputService")
local LocalPlayer = Players.LocalPlayer
local PlaceId = game.PlaceId
local JobId = game.JobId

local ENV = (getgenv and getgenv()) or _G
ENV.__FRUIT_HUNTER = ENV.__FRUIT_HUNTER or { enabled = false, visited = {}, logs = {} }
local State = ENV.__FRUIT_HUNTER
State.enabled = State.enabled == true
State.busy = false
State.decision = nil
State.currentFruit = nil
State.lastAction = "Idle"

local function log(msg)
    local stamp = os.date("%H:%M:%S")
    local line = ("[%s] %s"):format(stamp, tostring(msg))
    table.insert(State.logs, 1, line)
    while #State.logs > 80 do table.remove(State.logs) end
    State.lastAction = tostring(msg)
    if _G.FruitHunterRefresh then pcall(_G.FruitHunterRefresh) end
    print("[FruitHunter] " .. line)
end

local function getCharacter()
    local char = LocalPlayer.Character or LocalPlayer.CharacterAdded:Wait()
    local hum = char:FindFirstChildOfClass("Humanoid")
    local root = char:FindFirstChild("HumanoidRootPart")
    return char, hum, root
end

local function isFruitTool(obj)
    if not obj or not obj:IsA("Tool") then return false end
    local tip = tostring(obj.ToolTip or "")
    local name = obj.Name
    -- Natural Blox Fruits appear as Tools with a Handle; avoid player inventory.
    if not obj:FindFirstChild("Handle") then return false end
    if tip:lower():find("fruit") then return true end
    -- Fallback for versions where ToolTip is blank. Keep common fruit naming shape.
    if name:find("%-") and not name:lower():find("sword") then return true end
    return false
end

local function isInWorkspace(tool)
    return tool and tool.Parent and tool:IsDescendantOf(workspace)
end

local function findSpawnedFruits()
    local found, seen = {}, {}
    for _, obj in ipairs(workspace:GetDescendants()) do
        if obj:IsA("Tool") and isFruitTool(obj) and isInWorkspace(obj) and not seen[obj] then
            seen[obj] = true
            table.insert(found, obj)
        end
    end
    table.sort(found, function(a,b) return a.Name < b.Name end)
    return found
end

local function moveToFruit(tool)
    local handle = tool:FindFirstChild("Handle")
    if not handle then return false, "Fruit has no Handle" end
    local char, hum, root = getCharacter()
    if not hum or not root then return false, "Character is unavailable" end
    log("Moving to spawned fruit: " .. tool.Name)

    -- Smooth movement; intentionally no NoClip / CanCollide manipulation.
    local destination = handle.CFrame + Vector3.new(0, 3, 0)
    local distance = (root.Position - destination.Position).Magnitude
    local duration = math.clamp(distance / 180, 0.35, 5)
    local tween = TweenService:Create(root, TweenInfo.new(duration, Enum.EasingStyle.Linear), {CFrame = destination})
    tween:Play()
    local start = os.clock()
    while tween.PlaybackState == Enum.PlaybackState.Playing and os.clock() - start < duration + 2 do
        if not State.enabled or not isInWorkspace(tool) then tween:Cancel(); return false, "Stopped or fruit disappeared" end
        task.wait(0.1)
    end
    tween:Cancel()
    -- Allow the game's natural touch/pickup handling to run.
    for _ = 1, 30 do
        if not isInWorkspace(tool) then break end
        task.wait(0.1)
    end
    local backpack = LocalPlayer:FindFirstChildOfClass("Backpack")
    local character = LocalPlayer.Character
    if (backpack and backpack:FindFirstChild(tool.Name)) or (character and character:FindFirstChild(tool.Name)) then
        return true, "Fruit entered inventory"
    end
    if not isInWorkspace(tool) then return true, "Fruit disappeared after contact; verify inventory" end
    return false, "Fruit did not enter inventory; pickup not confirmed"
end

local function findFruitToolInInventory(name)
    local backpack = LocalPlayer:FindFirstChildOfClass("Backpack")
    local char = LocalPlayer.Character
    return (backpack and backpack:FindFirstChild(name)) or (char and char:FindFirstChild(name))
end

local function storeFruit(tool)
    if not tool then return false, "Fruit tool not found in inventory" end
    local remotes = ReplicatedStorage:FindFirstChild("Remotes")
    local comm = remotes and remotes:FindFirstChild("CommF_")
    if not comm then return false, "CommF_ remote unavailable" end
    local ok, result = pcall(function()
        -- Common Blox Fruits storage invocation; exact arguments can change by update.
        return comm:InvokeServer("StoreFruit", tool.Name, tool)
    end)
    if not ok then return false, tostring(result) end
    task.wait(0.5)
    if findFruitToolInInventory(tool.Name) then
        -- Some versions leave the tool visible after an unsuccessful store.
        return false, "Store request returned but fruit remains in inventory"
    end
    return true, tostring(result)
end

local function decisionPause(toolName)
    State.decision = nil
    log("Storage failed for " .. toolName .. ". Waiting up to 20 seconds for your choice.")
    for remaining = 20, 1, -1 do
        if not State.enabled then return "stop" end
        State.countdown = remaining
        if _G.FruitHunterRefresh then pcall(_G.FruitHunterRefresh) end
        if State.decision then return State.decision end
        task.wait(1)
    end
    log("20-second decision window expired; stopping Auto Farm for safety.")
    State.enabled = false
    return "stop"
end

local function waitAfterDisposition()
    for remaining = 10, 1, -1 do
        if not State.enabled then return false end
        State.countdown = remaining
        if _G.FruitHunterRefresh then pcall(_G.FruitHunterRefresh) end
        task.wait(1)
    end
    State.countdown = nil
    return State.enabled
end

local function getServerPage(cursor)
    local url = ("https://games.roblox.com/v1/games/%d/servers/Public?sortOrder=Asc&limit=100%s")
        :format(PlaceId, cursor and ("&cursor=" .. HttpService:UrlEncode(cursor)) or "")
    local requestFn = (syn and syn.request) or (http and http.request) or request
    if type(requestFn) ~= "function" then return nil, "Executor HTTP request function unavailable" end
    local ok, response = pcall(requestFn, {Url = url, Method = "GET"})
    if not ok or not response then return nil, tostring(response) end
    local body = response.Body or response.body
    if type(body) ~= "string" then return nil, "Empty server-list response" end
    local decodedOk, decoded = pcall(HttpService.JSONDecode, HttpService, body)
    if not decodedOk then return nil, "Could not decode server list" end
    return decoded
end

local function nextCandidateServer()
    local cursor = nil
    for page = 1, 8 do
        if not State.enabled then return nil end
        local data, err = getServerPage(cursor)
        if not data then log("Server list error: " .. tostring(err)); return nil end
        for _, server in ipairs(data.data or {}) do
            local id = server.id
            local playing = tonumber(server.playing) or 0
            local maxPlayers = tonumber(server.maxPlayers) or 0
            if id and id ~= JobId and playing < maxPlayers and not State.visited[id] then
                State.visited[id] = true
                return id
            end
        end
        cursor = data.nextPageCursor
        if not cursor then break end
    end
    return nil
end

local function queueRejoin()
    local queue = queue_on_teleport or queueonteleport or (syn and syn.queue_on_teleport)
    if type(queue) == "function" then
        local source = (ENV.__FRUIT_HUNTER_SOURCE or "")
        if source ~= "" then pcall(queue, source) end
    end
end

local function hopCandidate()
    if not State.enabled then return false end
    local serverId = nextCandidateServer()
    if not serverId then
        log("No unvisited public candidate found. Clearing visited list and retrying.")
        State.visited = {[JobId] = true}
        task.wait(2)
        serverId = nextCandidateServer()
    end
    if not serverId then log("No candidate server available right now."); return false end
    log("Joining candidate server " .. serverId .. "; fruit presence will be verified after joining.")
    queueRejoin()
    local ok, err = pcall(function()
        TeleportService:TeleportToPlaceInstance(PlaceId, serverId, LocalPlayer)
    end)
    if not ok then log("Teleport failed: " .. tostring(err)); return false end
    return true
end

local function runCurrentServer()
    while State.enabled do
        local fruits = findSpawnedFruits()
        if #fruits == 0 then
            log("No naturally spawned fruit detected in this server.")
            return false
        end
        log(("Detected %d naturally spawned fruit(s)."):format(#fruits))
        local didAny = false
        for _, fruit in ipairs(fruits) do
            if not State.enabled then return false end
            if isInWorkspace(fruit) then
                State.currentFruit = fruit.Name
                local collected, collectMsg = moveToFruit(fruit)
                if collected then
                    didAny = true
                    log("Pickup result: " .. collectMsg)
                    local owned = findFruitToolInInventory(fruit.Name)
                    if owned then
                        log("Attempting to store " .. fruit.Name .. "...")
                        local stored, storeMsg = storeFruit(owned)
                        if stored then
                            log("Stored " .. fruit.Name .. ".")
                            if not waitAfterDisposition() then return false end
                        else
                            log("Could not confirm storage: " .. storeMsg)
                            local choice = decisionPause(fruit.Name)
                            if choice == "retry" then
                                local retryTool = findFruitToolInInventory(fruit.Name)
                                local retryOk, retryMsg = storeFruit(retryTool)
                                log(retryOk and ("Stored " .. fruit.Name .. " on retry.") or ("Retry failed: " .. tostring(retryMsg)))
                                if retryOk then if not waitAfterDisposition() then return false end else return false end
                            elseif choice == "skip" then
                                log("Skipped " .. fruit.Name .. "; continuing after 10 seconds.")
                                if not waitAfterDisposition() then return false end
                            else
                                return false
                            end
                        end
                    else
                        log("Fruit pickup was not confirmed in Backpack/Character.")
                    end
                else
                    log("Collection failed: " .. collectMsg)
                end
            end
        end
        if not didAny then return false end
        -- Rescan in case another natural fruit spawned while collecting.
        task.wait(1)
    end
    return false
end

-- Mobile-friendly UI
local gui = Instance.new("ScreenGui")
gui.Name = "FruitHunterUI"
gui.ResetOnSpawn = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
pcall(function() gui.Parent = game:GetService("CoreGui") end)
if not gui.Parent then gui.Parent = LocalPlayer:WaitForChild("PlayerGui") end

local frame = Instance.new("Frame")
frame.Size = UDim2.fromOffset(310, 330)
frame.Position = UDim2.new(0, 18, 0.35, 0)
frame.BackgroundColor3 = Color3.fromRGB(24, 25, 32)
frame.BorderSizePixel = 0
frame.Parent = gui
Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 12)
local stroke = Instance.new("UIStroke", frame); stroke.Color = Color3.fromRGB(105, 90, 180); stroke.Thickness = 1.4

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, -16, 0, 34); title.Position = UDim2.fromOffset(8, 4)
title.BackgroundTransparency = 1; title.Text = "🍈 FRUIT HUNTER"; title.TextColor3 = Color3.new(1,1,1)
title.Font = Enum.Font.GothamBold; title.TextSize = 16; title.TextXAlignment = Enum.TextXAlignment.Left; title.Parent = frame

local toggle = Instance.new("TextButton")
toggle.Size = UDim2.new(1, -16, 0, 34); toggle.Position = UDim2.fromOffset(8, 42)
toggle.BackgroundColor3 = Color3.fromRGB(65, 115, 80); toggle.TextColor3 = Color3.new(1,1,1)
toggle.Font = Enum.Font.GothamBold; toggle.TextSize = 14; toggle.Text = "AUTO FARM: OFF"; toggle.Parent = frame
Instance.new("UICorner", toggle).CornerRadius = UDim.new(0, 8)

local status = Instance.new("TextLabel")
status.Size = UDim2.new(1, -16, 0, 42); status.Position = UDim2.fromOffset(8, 80)
status.BackgroundColor3 = Color3.fromRGB(35, 36, 46); status.TextColor3 = Color3.fromRGB(230,230,240)
status.Font = Enum.Font.Gotham; status.TextSize = 12; status.TextWrapped = true; status.Text = "Status: Idle"; status.Parent = frame
Instance.new("UICorner", status).CornerRadius = UDim.new(0, 7)

local buttons = Instance.new("Frame")
buttons.Size = UDim2.new(1, -16, 0, 30); buttons.Position = UDim2.fromOffset(8, 126)
buttons.BackgroundTransparency = 1; buttons.Parent = frame
local layout = Instance.new("UIListLayout", buttons); layout.FillDirection = Enum.FillDirection.Horizontal; layout.Padding = UDim.new(0, 5)
local function makeButton(text, color)
    local b = Instance.new("TextButton"); b.Size = UDim2.new(1/3, -4, 1, 0); b.BackgroundColor3 = color
    b.Text = text; b.TextColor3 = Color3.new(1,1,1); b.Font = Enum.Font.GothamBold; b.TextSize = 11
    b.Parent = buttons; Instance.new("UICorner", b).CornerRadius = UDim.new(0, 6); return b
end
local retryBtn = makeButton("RETRY STORE", Color3.fromRGB(54, 104, 150))
local skipBtn = makeButton("SKIP", Color3.fromRGB(135, 100, 48))
local stopBtn = makeButton("STOP", Color3.fromRGB(145, 60, 65))

local logTitle = Instance.new("TextLabel")
logTitle.Size = UDim2.new(1, -16, 0, 20); logTitle.Position = UDim2.fromOffset(8, 162)
logTitle.BackgroundTransparency = 1; logTitle.Text = "ACTIVITY LOG"; logTitle.TextColor3 = Color3.fromRGB(190,180,255)
logTitle.Font = Enum.Font.GothamBold; logTitle.TextSize = 12; logTitle.TextXAlignment = Enum.TextXAlignment.Left; logTitle.Parent = frame

local logBox = Instance.new("ScrollingFrame")
logBox.Size = UDim2.new(1, -16, 0, 138); logBox.Position = UDim2.fromOffset(8, 184)
logBox.BackgroundColor3 = Color3.fromRGB(17,18,24); logBox.BorderSizePixel = 0; logBox.ScrollBarThickness = 4
logBox.CanvasSize = UDim2.new(); logBox.Parent = frame
Instance.new("UICorner", logBox).CornerRadius = UDim.new(0, 7)
local logText = Instance.new("TextLabel")
logText.Size = UDim2.new(1, -12, 0, 0); logText.Position = UDim2.fromOffset(6, 5)
logText.AutomaticSize = Enum.AutomaticSize.Y; logText.BackgroundTransparency = 1
logText.TextColor3 = Color3.fromRGB(210,210,220); logText.Font = Enum.Font.Code; logText.TextSize = 10
logText.TextXAlignment = Enum.TextXAlignment.Left; logText.TextYAlignment = Enum.TextYAlignment.Top
logText.TextWrapped = true; logText.Parent = logBox

_G.FruitHunterRefresh = function()
    if not gui.Parent then return end
    toggle.Text = State.enabled and "AUTO FARM: ON" or "AUTO FARM: OFF"
    toggle.BackgroundColor3 = State.enabled and Color3.fromRGB(45,125,75) or Color3.fromRGB(65,75,85)
    local suffix = State.countdown and (" | " .. tostring(State.countdown) .. "s") or ""
    status.Text = "Status: " .. tostring(State.lastAction or "Idle") .. suffix .. (State.currentFruit and ("\nFruit: " .. State.currentFruit) or "")
    logText.Text = table.concat(State.logs, "\n")
    logBox.CanvasSize = UDim2.fromOffset(0, logText.AbsoluteSize.Y + 10)
end

toggle.MouseButton1Click:Connect(function()
    State.enabled = not State.enabled
    if State.enabled then
        log("Auto Farm enabled.")
        if not State.busy then
            task.spawn(function()
                State.busy = true
                while State.enabled do
                    local found = runCurrentServer()
                    if not State.enabled then break end
                    if found then
                        log("Finished current server fruit scan; hopping for the next fruit server.")
                    else
                        log("Current server has no remaining collectible fruit; searching another candidate.")
                    end
                    local hopped = hopCandidate()
                    if not hopped then task.wait(4) end
                    -- Teleport normally replaces this client; queued execution resumes if supported.
                    if hopped then break end
                end
                State.busy = false
                State.countdown = nil
                log("Auto Farm stopped.")
            end)
        end
    else
        State.decision = "stop"
        log("Auto Farm disabled by user.")
    end
    _G.FruitHunterRefresh()
end)

retryBtn.MouseButton1Click:Connect(function() State.decision = "retry"; log("Retry storage selected.") end)
skipBtn.MouseButton1Click:Connect(function() State.decision = "skip"; log("Skip selected.") end)
stopBtn.MouseButton1Click:Connect(function() State.enabled = false; State.decision = "stop"; log("Stop selected."); _G.FruitHunterRefresh() end)

-- Drag window on touch or mouse
local dragging, dragStart, startPos = false, nil, nil
title.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        dragging = true; dragStart = input.Position; startPos = frame.Position
    end
end)
UserInputService.InputChanged:Connect(function(input)
    if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
        local delta = input.Position - dragStart
        frame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
    end
end)
UserInputService.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then dragging = false end
end)

log("UI loaded. Auto Farm is OFF. Scan current server first when enabled.")
_G.FruitHunterRefresh()