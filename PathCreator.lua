-- Made it open source cuz why not, obfuscation will just make it worse by lagging the game very hard

local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Localplayer = Players.LocalPlayer
local MyName = Localplayer.Name
local mouse = Localplayer:GetMouse()

-- Remotes & Folders
local Mover = ReplicatedStorage.Events.Gameplay:WaitForChild("Move")
local Attacker = ReplicatedStorage.Events.Gameplay:WaitForChild("SetAttackTarget")
local MapUnit = Workspace:WaitForChild("MapUnits")

-- Configuration States
local globalMoveToken = 0 -- Master loop kill-switch
local isCreatingPath = false
local isAutoMarchEnabled = false 
local selectedPathIndex = 1

-- Multi-Path Structures
local pathData = {
	[1] = { Waypoints = {}, Spheres = {}, Color = Color3.fromRGB(0, 255, 255), Name = "Cyan", Token = 0 },
	[2] = { Waypoints = {}, Spheres = {}, Color = Color3.fromRGB(231, 76, 60), Name = "Red", Token = 0 },
	[3] = { Waypoints = {}, Spheres = {}, Color = Color3.fromRGB(46, 204, 113), Name = "Green", Token = 0 },
	[4] = { Waypoints = {}, Spheres = {}, Color = Color3.fromRGB(241, 196, 15), Name = "Yellow", Token = 0 }
}

-- Comprehensive Game Data Tables
local troops_stats = {
	["Soldier"] = {AttackSpeed = 1.1, AttackRange = 6},
	["Heavy"] = {AttackSpeed = 2.1, AttackRange = 8},
	["Tank"] = {AttackSpeed = 3.1, AttackRange = 15},
	["Humvee"] = {AttackSpeed = 1.1, AttackRange = 8},
	["Artillery"] = {AttackSpeed = 5.1, AttackRange = 25},
	["Heli"] = {AttackSpeed = 1.1, AttackRange = 10},
}

local troops_cannotAttack = {
	["Tank"] = {["Heli"] = true, ["VTOL"] = true},
	["Humvee"] = {["Heli"] = true, ["VTOL"] = true},
	["Artillery"] = {["Heli"] = true, ["VTOL"] = true}
}

local buildings = {
	["CommandCenter"] = true, ["Generator"] = true, ["Refinery"] = true,
	["Wall"] = true, ["Turret"] = true, ["AirTurret"] = true,
	["Barracks"] = true, ["Garage"] = true, ["Hangar"] = true, ["ScienceLab"] = true,
}

local all_valid_targets = {
	["Worker"] = true, ["Soldier"] = true, ["Heavy"] = true, ["Tank"] = true,
	["MachineGunner"] = true, ["Humvee"] = true, ["Artillery"] = true,
	["RocketArtillery"] = true, ["Heli"] = true, ["VTOL"] = true
}

local raycastParams = RaycastParams.new()
raycastParams.FilterType = Enum.RaycastFilterType.Exclude

local function getUnitPosition(unit)
	if unit:IsA("Model") and unit.PrimaryPart then
		return unit.PrimaryPart.Position
	elseif unit:IsA("Model") and unit:FindFirstChild("HumanoidRootPart") then
		return unit.HumanoidRootPart.Position
	elseif unit:IsA("BasePart") then
		return unit.Position
	end
	return nil
end

-- Helper function to safely fetch your own team number (yields briefly if it hasn't replicated yet)
local function getMyTeamNumber()
	for _, unit in MapUnit:GetChildren() do
		if unit:GetAttribute("Owner") == MyName then
			local myTeam = unit:GetAttribute("Team")
			if myTeam then return myTeam end
		end
	end
	return nil
end

local function destroySinglePath(index)
	local path = pathData[index]
	path.Token = path.Token + 1
	
	for _, sphere in path.Spheres do
		if sphere then sphere:Destroy() end
	end
	table.clear(path.Waypoints)
	table.clear(path.Spheres)
	print("[Hivemind] Track " .. path.Name .. " cleared and halted.")
end

local function destroyAllPaths()
	globalMoveToken = globalMoveToken + 1 -- Safely terminates all background independent unit threads
	for i = 1, 4 do
		destroySinglePath(i)
	end
	print("[Hivemind] All strategic channels completely wiped.")
end

local function placeWaypoint(position)
	local path = pathData[selectedPathIndex]
	table.insert(path.Waypoints, position)
	
	local sphere = Instance.new("Part")
	sphere.Name = path.Name .. "Node_" .. #path.Waypoints
	sphere.Shape = Enum.PartType.Ball
	sphere.Size = Vector3.new(1,1,1)
	sphere.Position = position + Vector3.new(0, 1, 0)
	sphere.Color = path.Color
	sphere.Material = Enum.Material.Neon
	sphere.Anchored = true
	sphere.CanCollide = false
	sphere.CanQuery = false
	sphere.CanTouch = false
	sphere.Parent = Workspace
	
	local bg = Instance.new("BillboardGui")
	bg.Size = UDim2.new(0, 50, 0, 30)
	bg.AlwaysOnTop = true
	bg.StudsOffset = Vector3.new(0, 3, 0)
	bg.Parent = sphere
	
	local tl = Instance.new("TextLabel")
	tl.Size = UDim2.new(1, 0, 1, 0)
	tl.BackgroundTransparency = 1
	tl.TextColor3 = Color3.new(1, 1, 1)
	tl.TextSize = 16
	tl.Font = Enum.Font.SourceSansBold
	tl.Text = path.Name:sub(1,1) .. #path.Waypoints
	tl.Parent = bg

	table.insert(path.Spheres, sphere)
end

-- Scan surroundings for valid enemy elements to engage (Ignoring Allies & Y-Axis Altitude)
local function findPriorityTarget(object, currentPos, myType, stats, myTeamNumber)
	local bestTarget = nil
	local closestDist = stats.AttackRange

	for _, potentialTarget in MapUnit:GetChildren() do
		-- Skip checking dead elements
		if potentialTarget:GetAttribute("Health") and potentialTarget:GetAttribute("Health") <= 0 then continue end
		
		-- FIX: Check team alliance. If the target's Team attribute matches your own, IGNORE completely.
		local foreignTeam = potentialTarget:GetAttribute("Team")
		if myTeamNumber and foreignTeam and foreignTeam == myTeamNumber then continue end
		
		-- Extra fallback check for your own username
		if potentialTarget:GetAttribute("Owner") == MyName then continue end
		
		local tName = potentialTarget.Name
		if all_valid_targets[tName] or buildings[tName] then
			if troops_cannotAttack[myType] and troops_cannotAttack[myType][tName] then continue end
			
			local tPos = getUnitPosition(potentialTarget)
			if tPos then
				local horizontalVector = Vector2.new(currentPos.X - tPos.X, currentPos.Z - tPos.Z)
				local dist = horizontalVector.Magnitude
				
				if dist <= closestDist then
					closestDist = dist
					bestTarget = potentialTarget
				end
			end
		end
	end
	return bestTarget
end

-- Isolated multi-threaded loop managing movement & combat for ONE individual unit
local function trackSingleUnitIndependent(object, targetPathIdx, baseOffset, baseArrivalDistance, assignedPathToken, assignedGlobalToken)
	local myType = object.Name
	local stats = troops_stats[myType] or {AttackSpeed = 1.5, AttackRange = 8}
	
	local currentIdx = 1
	local lastAttackTime = 0
	local lastMoveTime = 0

	while pathData[targetPathIdx].Token == assignedPathToken and globalMoveToken == assignedGlobalToken do
		if not object:GetAttribute("Health") or object:GetAttribute("Health") <= 0 then break end
		
		local currentPos = getUnitPosition(object)
		if not currentPos then break end
		
		-- Dynamically verify active team context numbers before checking threat maps
		local myTeamNumber = object:GetAttribute("Team") or getMyTeamNumber()
		
		-- COMBAT LAYER
		local target = findPriorityTarget(object, currentPos, myType, stats, myTeamNumber)
		if target then
			if os.clock() - lastAttackTime >= stats.AttackSpeed then
				Attacker:FireServer({object}, target)
				lastAttackTime = os.clock()
			end
			task.wait(0.1) -- Rapid tick ensures combat triggers instantly when facing valid enemies
			continue 
		end
		
		-- NAVIGATION LAYER
		if os.clock() - lastMoveTime >= 0.3 then
			local activePathWaypoints = pathData[targetPathIdx].Waypoints
			local baseWaypoint = activePathWaypoints[currentIdx]
			
			if not baseWaypoint then break end
			
			local personalizedWaypoint = baseWaypoint + baseOffset
			if baseOffset.Magnitude > 0 then
				local rayResult = Workspace:Raycast(baseWaypoint, baseOffset, raycastParams)
				if rayResult then personalizedWaypoint = baseWaypoint end 
			end
			
			local horizontalMoveVector = Vector2.new(currentPos.X - personalizedWaypoint.X, currentPos.Z - personalizedWaypoint.Z)
			local distance = horizontalMoveVector.Magnitude
			
			local dynamicArrival = baseArrivalDistance
			if currentIdx == #activePathWaypoints then dynamicArrival = 5 end 
			
			if distance <= dynamicArrival then
				currentIdx = currentIdx + 1
				baseWaypoint = activePathWaypoints[currentIdx]
				if not baseWaypoint then break end
				personalizedWaypoint = baseWaypoint + baseOffset
			end
			
			Mover:FireServer({object}, personalizedWaypoint)
			lastMoveTime = os.clock()
		end
		
		task.wait(0.1)
	end
end

local function deploySingleUnit(object)
	if not object:GetAttribute("Owner") then
		object:GetAttributeChangedSignal("Owner"):Wait()
	end
	
	if object:GetAttribute("Owner") ~= MyName or (object:GetAttribute("Health") and object:GetAttribute("Health") <= 0) then 
		return 
	end

	local uPos = getUnitPosition(object)
	if not uPos then return end
	
	local closestPathIdx = nil
	local closestDistance = math.huge
	
	for i = 1, 4 do
		local path = pathData[i]
		if #path.Waypoints > 0 then
			local dist = (uPos - path.Waypoints[1]).Magnitude 
			if dist < closestDistance then
				closestDistance = dist
				closestPathIdx = i
			end
		end
	end
	
	if closestPathIdx then
		local rng = Random.new()
		
		-- FIX: Check for the custom box value. If it's 0 or empty, use a compact fallback
		local screenGui = Localplayer.PlayerGui:FindFirstChild("HivemindControlPanel")
		local customSpread = 0
		if screenGui and screenGui:FindFirstChild("Frame") and screenGui.Frame:FindFirstChild("InputSpread") then
			customSpread = tonumber(screenGui.Frame.InputSpread.Text) or 0
		end
		
		local actualSpread = (customSpread == 0) and 6 or customSpread
		local baseOffset = Vector3.new(rng:NextNumber(-actualSpread, actualSpread), 0, rng:NextNumber(-actualSpread, actualSpread))
		
		task.spawn(trackSingleUnitIndependent, object, closestPathIdx, baseOffset, 6, pathData[closestPathIdx].Token, globalMoveToken)
	end
end

local function StartMoveAllUnits()
	globalMoveToken = globalMoveToken + 1 
	
	local validUnits = {}
	local unitCount = 0

	for _, object in MapUnit:GetChildren() do
		if troops_stats[object.Name] then
			if object:GetAttribute("Owner") == MyName and object:GetAttribute("Health") > 0 then
				table.insert(validUnits, object)
				unitCount = unitCount + 1
			end
		end
	end

	if unitCount == 0 then return end
	raycastParams.FilterDescendantsInstances = {MapUnit}
	
	-- FIX: Look up the value typed inside the UI TextBox
	local screenGui = Localplayer.PlayerGui:FindFirstChild("HivemindControlPanel")
	local customSpread = 0
	if screenGui and screenGui:FindFirstChild("Frame") and screenGui.Frame:FindFirstChild("InputSpread") then
		customSpread = tonumber(screenGui.Frame.InputSpread.Text) or 0
	end
	
	-- If 0, apply the original dynamic calculation. Otherwise, lock strictly to your custom size
	local spreadRange = (customSpread == 0) and math.clamp(unitCount * 0.10, 4, 12) or customSpread
	local baseArrivalDistance = math.clamp(spreadRange, 4, 12) -- Matches arrival to your custom tight lines
	local rng = Random.new()
	
	for _, object in validUnits do
		local uPos = getUnitPosition(object)
		if not uPos then continue end
		
		local closestPathIdx = nil
		local closestDistance = math.huge
		
		for i = 1, 4 do
			local path = pathData[i]
			if #path.Waypoints > 0 then
				local dist = (uPos - path.Waypoints[1]).Magnitude
				if dist < closestDistance then
					closestDistance = dist
					closestPathIdx = i
				end
			end
		end
		
		if closestPathIdx then
			local baseOffset = Vector3.new(
				rng:NextNumber(-spreadRange, spreadRange),
				0,
				rng:NextNumber(-spreadRange, spreadRange)
			)
			task.spawn(trackSingleUnitIndependent, object, closestPathIdx, baseOffset, baseArrivalDistance, pathData[closestPathIdx].Token, globalMoveToken)
		end
	end
end

MapUnit.ChildAdded:Connect(function(child)
	if isAutoMarchEnabled and troops_stats[child.Name] then
		task.wait(0.2)
		deploySingleUnit(child)
	end
end)

mouse.Button1Down:Connect(function()
	if isCreatingPath and mouse.Target then
		placeWaypoint(mouse.Hit.Position)
	end
end)

local function setupControlUI()
	local sg = Instance.new("ScreenGui")
	sg.Name = "HivemindControlPanel"
	sg.ResetOnSpawn = false
	sg.Parent = Localplayer:WaitForChild("PlayerGui")
	
	local frame = Instance.new("Frame")
	frame.Size = UDim2.new(0, 160, 0, 335) -- Expanded frame window size
	frame.Position = UDim2.new(1, -180, 1, -385)
	frame.BackgroundTransparency = 0.4
	frame.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
	frame.BorderSizePixel = 0
	frame.Parent = sg
	Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 8)
	
	local tabFrame = Instance.new("Frame")
	tabFrame.Size = UDim2.new(0, 140, 0, 28)
	tabFrame.Position = UDim2.new(0, 10, 0, 12)
	tabFrame.BackgroundTransparency = 0.7
	tabFrame.BackgroundColor3 = Color3.new(0, 0, 0)
	tabFrame.Parent = frame
	Instance.new("UICorner", tabFrame).CornerRadius = UDim.new(0, 4)
	
	local colors = {
		Color3.fromRGB(0, 255, 255),
		Color3.fromRGB(231, 76, 60),
		Color3.fromRGB(46, 204, 113),
		Color3.fromRGB(241, 196, 15)
	}
	
	local tabBorders = {}
	
	for i = 1, 4 do
		local tBtn = Instance.new("TextButton")
		tBtn.Size = UDim2.new(0, 28, 0, 22)
		tBtn.Position = UDim2.new(0, 5 + (i-1) * 33, 0, 3)
		tBtn.BackgroundColor3 = colors[i]
		tBtn.Text = ""
		tBtn.Parent = tabFrame
		Instance.new("UICorner", tBtn).CornerRadius = UDim.new(0, 4)
		
		local stroke = Instance.new("UIStroke")
		stroke.Thickness = 3
		stroke.Color = Color3.fromRGB(0, 255, 4)
		stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		stroke.Enabled = (i == 1)
		stroke.Parent = tBtn
		tabBorders[i] = stroke
		
		tBtn.MouseButton1Click:Connect(function()
			selectedPathIndex = i
			for idx, border in tabBorders do
				border.Enabled = (idx == i)
			end
			print("[Hivemind] Active focus shifted to Path: " .. pathData[i].Name)
		end)
	end
	
	local btnCreate = Instance.new("TextButton")
	btnCreate.Size = UDim2.new(0, 140, 0, 35)
	btnCreate.Position = UDim2.new(0, 10, 0, 50)
	btnCreate.BackgroundColor3 = Color3.fromRGB(46, 117, 89)
	btnCreate.TextColor3 = Color3.new(1, 1, 1)
	btnCreate.Font = Enum.Font.SourceSansBold
	btnCreate.TextSize = 15
	btnCreate.Text = "Create Path: OFF"
	btnCreate.Parent = frame
	Instance.new("UICorner", btnCreate).CornerRadius = UDim.new(0, 6)
	
	btnCreate.MouseButton1Click:Connect(function()
		isCreatingPath = not isCreatingPath
		if isCreatingPath then
			btnCreate.Text = "Create Path: ON"
			btnCreate.BackgroundColor3 = Color3.fromRGB(39, 174, 96)
		else
			btnCreate.Text = "Create Path: OFF"
			btnCreate.BackgroundColor3 = Color3.fromRGB(46, 117, 89)
		end
	end)
	
	local btnMove = Instance.new("TextButton")
	btnMove.Size = UDim2.new(0, 140, 0, 35)
	btnMove.Position = UDim2.new(0, 10, 0, 95)
	btnMove.BackgroundColor3 = Color3.fromRGB(41, 128, 185)
	btnMove.TextColor3 = Color3.new(1, 1, 1)
	btnMove.Font = Enum.Font.SourceSansBold
	btnMove.TextSize = 15
	btnMove.Text = "Start Move All"
	btnMove.Parent = frame
	Instance.new("UICorner", btnMove).CornerRadius = UDim.new(0, 6)
	btnMove.MouseButton1Click:Connect(StartMoveAllUnits)
	
	local btnAuto = Instance.new("TextButton")
	btnAuto.Size = UDim2.new(0, 140, 0, 35)
	btnAuto.Position = UDim2.new(0, 10, 0, 140)
	btnAuto.BackgroundColor3 = Color3.fromRGB(44, 62, 80)
	btnAuto.TextColor3 = Color3.new(1, 1, 1)
	btnAuto.Font = Enum.Font.SourceSansBold
	btnAuto.TextSize = 15
	btnAuto.Text = "Auto March: OFF"
	btnAuto.Parent = frame
	Instance.new("UICorner", btnAuto).CornerRadius = UDim.new(0, 6)
	
	btnAuto.MouseButton1Click:Connect(function()
		isAutoMarchEnabled = not isAutoMarchEnabled
		if isAutoMarchEnabled then
			btnAuto.Text = "Auto March: ON"
			btnAuto.BackgroundColor3 = Color3.fromRGB(142, 68, 173)
		else
			btnAuto.Text = "Auto March: OFF"
			btnAuto.BackgroundColor3 = Color3.fromRGB(44, 62, 80)
		end
	end)
	
	local btnDestroySelected = Instance.new("TextButton")
	btnDestroySelected.Size = UDim2.new(0, 140, 0, 35)
	btnDestroySelected.Position = UDim2.new(0, 10, 0, 185)
	btnDestroySelected.BackgroundColor3 = Color3.fromRGB(192, 57, 43)
	btnDestroySelected.TextColor3 = Color3.new(1, 1, 1)
	btnDestroySelected.Font = Enum.Font.SourceSansBold
	btnDestroySelected.TextSize = 14
	btnDestroySelected.Text = "Destroy Current Path"
	btnDestroySelected.Parent = frame
	Instance.new("UICorner", btnDestroySelected).CornerRadius = UDim.new(0, 6)
	btnDestroySelected.MouseButton1Click:Connect(function()
		destroySinglePath(selectedPathIndex)
	end)
	
	local btnDestroyAll = Instance.new("TextButton")
	btnDestroyAll.Size = UDim2.new(0, 140, 0, 35)
	btnDestroyAll.Position = UDim2.new(0, 10, 0, 230)
	btnDestroyAll.BackgroundColor3 = Color3.fromRGB(192, 57, 43)
	btnDestroyAll.TextColor3 = Color3.new(1, 1, 1)
	btnDestroyAll.Font = Enum.Font.SourceSansBold
	btnDestroyAll.TextSize = 14
	btnDestroyAll.Text = "Destroy All Paths"
	btnDestroyAll.Parent = frame
	Instance.new("UICorner", btnDestroyAll).CornerRadius = UDim.new(0, 6)
	btnDestroyAll.MouseButton1Click:Connect(destroyAllPaths)
	
	-- NEW FIELD: The Numeric Spread Input Box Box
	local inputSpread = Instance.new("TextBox")
	inputSpread.Name = "InputSpread"
	inputSpread.Size = UDim2.new(0, 140, 0, 30)
	inputSpread.Position = UDim2.new(0, 10, 0, 280) -- Anchored at the bottom of the card
	inputSpread.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
	inputSpread.TextColor3 = Color3.fromRGB(240, 240, 240)
	inputSpread.PlaceholderColor3 = Color3.fromRGB(130, 130, 130)
	inputSpread.Font = Enum.Font.SourceSans
	inputSpread.TextSize = 15
	inputSpread.Text = "0" -- Starts at 0 default spread configuration
	inputSpread.PlaceholderText = "Units Spread (0 = Default)"
	inputSpread.ClearTextOnFocus = false
	inputSpread.Parent = frame
	Instance.new("UICorner", inputSpread).CornerRadius = UDim.new(0, 4)
	
	-- Forces the text box to filter out non-numeric characters automatically
	inputSpread:GetPropertyChangedSignal("Text"):Connect(function()
		local cleaned = inputSpread.Text:gsub("[^%d]", "")
		if cleaned ~= inputSpread.Text then
			inputSpread.Text = cleaned
		end
	end)
end

setupControlUI()
