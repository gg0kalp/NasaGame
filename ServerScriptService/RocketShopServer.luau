--[[
	RocketShopServer (Script) -> ServerScriptService.RocketShopServer

	Sunucu tarafý (TÜM kritik kontroller burada; istemciye güvenilmez):
	  - Para        : player.leaderstats.Money (sadece sunucu yazar)
	  - Sahiplik, kuþanýlan roket, yakýt/yük yükseltmeleri, rekor -> DataStore
	  - Yükseltme fiyatlarý SUNUCUDA hesaplanýr (RocketConfig)
	  - Uçuþ: mesafe, yakýt ve kazanç sunucuda hesaplanýr, uçuþ bitince para ÖDENÝR
	  - Kuþanýlan roketin 3D modeli ServerStorage.RocketModels'dan RocketSpawn'a yerleþtirilir
	  - Shop_interface'e dokunan oyuncuya maðaza açtýrýlýr (oyuncu baþýna debounce)
	  - Her remote için hýz sýnýrý (spam korumasý)

	Oyuncu Attribute'larý (baþka sistemler okuyabilir):
	  EquippedRocket, RocketSpeed, RocketFuel, RocketCargo, IsFlying
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local DataStoreService = game:GetService("DataStoreService")
local RunService = game:GetService("RunService")

local RocketConfig = require(ReplicatedStorage:WaitForChild("RocketConfig"))
local SpaceConfig = require(ReplicatedStorage:WaitForChild("SpaceConfig"))

local DATASTORE_NAME = "RocketShop_v1"
local AUTOSAVE_INTERVAL = 90
local SHOP_TOUCH_DEBOUNCE = 2
local MIN_FLIGHT_SECONDS_BEFORE_END = 1.5

-- ============================================================
-- Remote'lar
-- ============================================================
local remotes = ReplicatedStorage:FindFirstChild("RocketShopRemotes")
if not remotes then
	remotes = Instance.new("Folder")
	remotes.Name = "RocketShopRemotes"
	remotes.Parent = ReplicatedStorage
end
local function getRemote(name)
	local remote = remotes:FindFirstChild(name)
	if not remote then
		remote = Instance.new("RemoteEvent")
		remote.Name = name
		remote.Parent = remotes
	end
	return remote
end
local RequestSync = getRemote("RequestSync")
local SyncData = getRemote("SyncData")
local PurchaseRocket = getRemote("PurchaseRocket")
local EquipRocket = getRemote("EquipRocket")
local UpgradeRocket = getRemote("UpgradeRocket")
local LaunchRocket = getRemote("LaunchRocket")
local EndFlight = getRemote("EndFlight")
local FlightStarted = getRemote("FlightStarted")
local FlightEnded = getRemote("FlightEnded")
local OpenShop = getRemote("OpenShop")
local Notify = getRemote("Notify")

-- ============================================================
-- Roket modelleri: ServerStorage.RocketModels = tek kaynak
-- Ýstemci önizlemesi için kopyalar ReplicatedStorage.RocketModels'a konur.
-- ============================================================
local rocketTemplates = ServerStorage:WaitForChild("RocketModels")

local function stripScripts(model)
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BaseScript") then
			d:Destroy()
		end
	end
end

local previewFolder = ReplicatedStorage:FindFirstChild("RocketModels")
if previewFolder then
	previewFolder:ClearAllChildren()
else
	previewFolder = Instance.new("Folder")
	previewFolder.Name = "RocketModels"
	previewFolder.Parent = ReplicatedStorage
end
for _, rocket in ipairs(RocketConfig.Rockets) do
	local template = rocketTemplates:FindFirstChild(rocket.ModelName)
	if template then
		local copy = template:Clone()
		stripScripts(copy)
		copy.Parent = previewFolder
	else
		warn("[RocketShop] ServerStorage.RocketModels içinde model yok: " .. rocket.ModelName .. " (roket: " .. rocket.Id .. ")")
	end
end

-- ============================================================
-- Dünyadaki roket (RocketSpawn)
-- ============================================================
local worldParent = workspace:FindFirstChild("GAME") or workspace
local worldRocket = nil

local function worldBounds(model)
	local minV = Vector3.new(math.huge, math.huge, math.huge)
	local maxV = Vector3.new(-math.huge, -math.huge, -math.huge)
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			local cf, half = d.CFrame, d.Size / 2
			local r, u, l = cf.RightVector, cf.UpVector, cf.LookVector
			local e = Vector3.new(
				math.abs(r.X) * half.X + math.abs(u.X) * half.Y + math.abs(l.X) * half.Z,
				math.abs(r.Y) * half.X + math.abs(u.Y) * half.Y + math.abs(l.Y) * half.Z,
				math.abs(r.Z) * half.X + math.abs(u.Z) * half.Y + math.abs(l.Z) * half.Z
			)
			minV = minV:Min(cf.Position - e)
			maxV = maxV:Max(cf.Position + e)
		end
	end
	return (minV + maxV) / 2, maxV - minV, minV
end

local function getSpawnPart()
	local part = workspace:FindFirstChild("RocketSpawn", true)
	if part then
		return part
	end
	warn("[RocketShop] RocketSpawn bulunamadý, geçici olarak oluþturuldu. Kendi yerinize taþýyýn.")
	part = Instance.new("Part")
	part.Name = "RocketSpawn"
	part.Anchored = true
	part.CanCollide = false
	part.Size = Vector3.new(10, 0.4, 10)
	part.Position = Vector3.new(0, 10, 0)
	part.Transparency = 0.5
	part.Parent = worldParent
	return part
end

local function removeWorldRocket()
	if worldRocket then
		worldRocket:Destroy()
		worldRocket = nil
	end
	local old = worldParent:FindFirstChild("ActiveRocket")
	if old then
		old:Destroy()
	end
end

local function placeWorldRocket(rocketId)
	local rocket = RocketConfig.GetById(rocketId)
	if not rocket then
		return
	end
	local template = rocketTemplates:FindFirstChild(rocket.ModelName)
	if not template then
		warn("[RocketShop] Dünyaya konacak model yok: " .. rocket.ModelName)
		return
	end
	removeWorldRocket()

	local model = template:Clone()
	model.Name = "ActiveRocket"
	stripScripts(model)
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			d.Anchored = true
		end
	end
	model.Parent = worldParent

	-- Modelin kendi duruþu korunur; sadece tabaný RocketSpawn'ýn üst yüzüne, merkezi RocketSpawn'a taþýnýr
	local spawnPart = getSpawnPart()
	local center, _, minV = worldBounds(model)
	local topY = spawnPart.Position.Y + spawnPart.Size.Y / 2
	local delta = Vector3.new(spawnPart.Position.X - center.X, topY - minV.Y, spawnPart.Position.Z - center.Z)
	model:PivotTo(model:GetPivot() + delta)
	model:SetAttribute("RocketId", rocketId)
	worldRocket = model
end

-- Fýrlatma animasyonu: dünyadaki roket alev/duman ile yükselir ve kaybolur
local function animateWorldLaunch()
	local model = worldRocket
	if not model then
		return
	end
	worldRocket = nil
	model.Name = "LaunchingRocket"

	local center, size, minV = worldBounds(model)
	local basePivot = model:GetPivot()
	local baseExhaust = Vector3.new(center.X, minV.Y, center.Z)

	local exhaust = Instance.new("Part")
	exhaust.Name = "Exhaust"
	exhaust.Anchored = true
	exhaust.CanCollide = false
	exhaust.CanTouch = false
	exhaust.CanQuery = false
	exhaust.Transparency = 1
	exhaust.Size = Vector3.new(4, 1, 4)
	exhaust.Position = baseExhaust
	exhaust.Parent = workspace

	local attachment = Instance.new("Attachment")
	attachment.Parent = exhaust

	local flameWidth = math.max(size.X, size.Z) * 0.45
	local fire = Instance.new("ParticleEmitter")
	fire.Texture = "rbxasset://textures/particles/fire_main.dds"
	fire.Color = ColorSequence.new(Color3.fromRGB(255, 210, 90), Color3.fromRGB(255, 70, 20))
	fire.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, flameWidth), NumberSequenceKeypoint.new(1, flameWidth * 0.2) })
	fire.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.1), NumberSequenceKeypoint.new(1, 1) })
	fire.Lifetime = NumberRange.new(0.5, 0.9)
	fire.Rate = 160
	fire.Speed = NumberRange.new(30, 50)
	fire.SpreadAngle = Vector2.new(6, 6)
	fire.EmissionDirection = Enum.NormalId.Bottom
	fire.LightEmission = 1
	fire.Parent = attachment

	local smoke = Instance.new("ParticleEmitter")
	smoke.Texture = "rbxasset://textures/particles/smoke_main.dds"
	smoke.Color = ColorSequence.new(Color3.fromRGB(200, 200, 210))
	smoke.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, flameWidth * 0.6), NumberSequenceKeypoint.new(1, flameWidth * 1.8) })
	smoke.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.4), NumberSequenceKeypoint.new(1, 1) })
	smoke.Lifetime = NumberRange.new(1.5, 2.5)
	smoke.Rate = 70
	smoke.Speed = NumberRange.new(10, 22)
	smoke.SpreadAngle = Vector2.new(18, 18)
	smoke.EmissionDirection = Enum.NormalId.Bottom
	smoke.Parent = attachment

	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(255, 150, 60)
	light.Range = 40
	light.Brightness = 3
	light.Parent = exhaust

	local duration = 8
	local startedAt = os.clock()
	local connection
	connection = RunService.Heartbeat:Connect(function()
		local alpha = (os.clock() - startedAt) / duration
		if alpha >= 1 or not model.Parent then
			connection:Disconnect()
			exhaust:Destroy()
			model:Destroy()
			return
		end
		local height = 900 * alpha * alpha
		model:PivotTo(basePivot + Vector3.new(0, height, 0))
		exhaust.Position = baseExhaust + Vector3.new(0, height, 0)
	end)
end

-- ============================================================
-- Yardýmcýlar
-- ============================================================
local profiles = {} -- [player] = profil
local flights = {} -- [player] = uçuþ
local lastAction = {}
local shopTouch = {}

local function formatNumber(n)
	local s = tostring(math.floor(n + 0.5))
	local formatted = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	return (formatted:gsub("^,", ""))
end

local function allowed(player, key, interval)
	local now = os.clock()
	local record = lastAction[player]
	if not record then
		record = {}
		lastAction[player] = record
	end
	if record[key] and now - record[key] < interval then
		return false
	end
	record[key] = now
	return true
end

local function notify(player, message, kind)
	Notify:FireClient(player, message, kind)
end

local function sendSync(player)
	local profile = profiles[player]
	if not profile then
		return
	end
	local owned = {}
	for id in pairs(profile.Owned) do
		table.insert(owned, id)
	end
	SyncData:FireClient(player, {
		Owned = owned,
		Equipped = profile.Equipped,
		Upgrades = profile.Upgrades,
		BestDistance = profile.BestDistance,
		Flying = flights[player] ~= nil,
	})
end

local function levelsOf(profile, rocketId)
	local up = profile.Upgrades[rocketId]
	if not up then
		up = { Fuel = 0, Cargo = 0 }
		profile.Upgrades[rocketId] = up
	end
	return up
end

local function applyAttributes(player)
	local profile = profiles[player]
	if not profile then
		return
	end
	local rocket = RocketConfig.GetById(profile.Equipped)
	if not rocket then
		return
	end
	local up = levelsOf(profile, rocket.Id)
	local stats = RocketConfig.GetFlightStats(rocket, up.Cargo, up.Fuel)
	player:SetAttribute("EquippedRocket", rocket.Id)
	player:SetAttribute("RocketSpeed", math.floor(stats.MaxSpeed))
	player:SetAttribute("RocketFuel", math.floor(stats.FuelCapacity))
	player:SetAttribute("RocketCargo", math.floor(stats.CargoKg))
end

-- ============================================================
-- Kayýt / Yükleme
-- ============================================================
local function loadProfile(player)
	local success, saved = pcall(function()
		return DataStoreService:GetDataStore(DATASTORE_NAME):GetAsync("Player_" .. player.UserId)
	end)

	local profile = {
		Owned = {},
		Equipped = RocketConfig.DefaultRocketId,
		Upgrades = {},
		BestDistance = 0,
		Flights = 0,
		CanSave = success, -- yükleme baþarýsýzsa eski veriyi ezmemek için kaydetme
	}
	local money = RocketConfig.StartingMoney
	local equippedCandidate

	if success then
		if type(saved) == "table" then
			if type(saved.Money) == "number" then
				money = math.max(0, math.floor(saved.Money))
			end
			if type(saved.Owned) == "table" then
				for _, id in ipairs(saved.Owned) do
					if type(id) == "string" and RocketConfig.GetById(id) then
						profile.Owned[id] = true
					end
				end
			end
			if type(saved.Upgrades) == "table" then
				for id, up in pairs(saved.Upgrades) do
					if type(id) == "string" and RocketConfig.GetById(id) and type(up) == "table" then
						profile.Upgrades[id] = {
							Fuel = RocketConfig.ClampLevel("Fuel", tonumber(up.Fuel) or 0),
							Cargo = RocketConfig.ClampLevel("Cargo", tonumber(up.Cargo) or 0),
						}
					end
				end
			end
			if type(saved.Equipped) == "string" then
				equippedCandidate = saved.Equipped
			end
			profile.BestDistance = tonumber(saved.BestDistance) or 0
			profile.Flights = tonumber(saved.Flights) or 0
		end
	else
		warn("[RocketShop] DataStore yüklenemedi (" .. tostring(saved) .. "). Bu oturumda ilerleme kaydedilmeyecek.")
	end

	profile.Owned[RocketConfig.DefaultRocketId] = true
	for id in pairs(profile.Owned) do
		levelsOf(profile, id)
	end
	if equippedCandidate and profile.Owned[equippedCandidate] and RocketConfig.GetById(equippedCandidate) then
		profile.Equipped = equippedCandidate
	end
	return profile, money
end

local function saveProfile(player)
	local profile = profiles[player]
	if not profile or not profile.CanSave or not profile.Money then
		return
	end
	local owned = {}
	for id in pairs(profile.Owned) do
		table.insert(owned, id)
	end
	local payload = {
		Money = profile.Money.Value,
		Owned = owned,
		Equipped = profile.Equipped,
		Upgrades = profile.Upgrades,
		BestDistance = profile.BestDistance,
		Flights = profile.Flights,
	}
	for attempt = 1, 3 do
		local ok, err = pcall(function()
			DataStoreService:GetDataStore(DATASTORE_NAME):SetAsync("Player_" .. player.UserId, payload)
		end)
		if ok then
			return true
		end
		warn("[RocketShop] Kayýt hatasý (deneme " .. attempt .. "): " .. tostring(err))
		task.wait(1)
	end
	return false
end

-- ============================================================
-- Uçuþ
-- ============================================================
local function finishFlight(player, flight, endedEarly)
	if flights[player] ~= flight then
		return
	end
	flights[player] = nil
	player:SetAttribute("IsFlying", false)

	local profile = profiles[player]
	local stats = flight.Stats
	local elapsed = math.clamp(workspace:GetServerTimeNow() - flight.StartedAt, 0, stats.Duration)
	local distance = RocketConfig.DistanceAt(stats, elapsed)
	local earnings = RocketConfig.EarningsFor(stats, distance)

	local newRecord = false
	if profile and profile.Money then
		profile.Money.Value += earnings
		profile.Flights += 1
		if distance > profile.BestDistance then
			profile.BestDistance = distance
			newRecord = true
		end
	end

	local reached = SpaceConfig.GetLastReached(distance)
	if player.Parent then
		FlightEnded:FireClient(player, {
			RocketId = flight.RocketId,
			Distance = distance,
			Earnings = earnings,
			Time = elapsed,
			FuelUsed = stats.BurnRate * elapsed,
			OutOfFuel = (not endedEarly) and elapsed >= stats.Duration - 0.05,
			Reached = reached and reached.Name or nil,
			NewRecord = newRecord,
			EarnMult = stats.EarnMult,
		})
		sendSync(player)
		task.spawn(saveProfile, player)
	end

	-- Roket birkaç saniye sonra rampaya geri döner
	task.delay(2, function()
		if not worldRocket and profile and RocketConfig.GetById(profile.Equipped) then
			placeWorldRocket(profile.Equipped)
		end
	end)
end

-- ============================================================
-- Oyuncu giriþi / çýkýþý
-- ============================================================
local function onPlayerAdded(player)
	local leaderstats = Instance.new("Folder")
	leaderstats.Name = "leaderstats"
	local money = Instance.new("IntValue")
	money.Name = "Money"
	money.Value = 0
	money.Parent = leaderstats
	leaderstats.Parent = player

	local profile, startMoney = loadProfile(player)
	if not player.Parent then
		return
	end
	profile.Money = money
	money.Value = startMoney
	profiles[player] = profile
	player:SetAttribute("IsFlying", false)
	applyAttributes(player)
	if not worldRocket then
		placeWorldRocket(profile.Equipped)
	end
	sendSync(player)
end

local function onPlayerRemoving(player)
	local flight = flights[player]
	if flight then
		finishFlight(player, flight, true) -- çýkan oyuncunun uçuþu da ödenir
	end
	saveProfile(player)
	profiles[player] = nil
	lastAction[player] = nil
	shopTouch[player] = nil
end

Players.PlayerAdded:Connect(function(player)
	task.spawn(onPlayerAdded, player)
end)
Players.PlayerRemoving:Connect(onPlayerRemoving)
for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(onPlayerAdded, player)
end

task.spawn(function()
	while true do
		task.wait(AUTOSAVE_INTERVAL)
		for player in pairs(profiles) do
			task.spawn(saveProfile, player)
		end
	end
end)

game:BindToClose(function()
	local pending = 0
	for player in pairs(profiles) do
		pending += 1
		task.spawn(function()
			local flight = flights[player]
			if flight then
				finishFlight(player, flight, true)
			end
			saveProfile(player)
			pending -= 1
		end)
	end
	local startedAt = os.clock()
	while pending > 0 and os.clock() - startedAt < 25 do
		task.wait(0.1)
	end
end)

-- ============================================================
-- Remote olaylarý
-- ============================================================
RequestSync.OnServerEvent:Connect(function(player)
	if not allowed(player, "Sync", 1) then
		return
	end
	task.spawn(function()
		local waited = 0
		while player.Parent and not profiles[player] and waited < 30 do
			task.wait(0.2)
			waited += 0.2
		end
		sendSync(player)
		-- Uçuþ sýrasýnda istemci yeniden baðlanýrsa uçuþ bilgisini tekrar yolla
		local flight = flights[player]
		if flight then
			FlightStarted:FireClient(player, { RocketId = flight.RocketId, StartTime = flight.StartedAt, Stats = flight.Stats })
		end
	end)
end)

PurchaseRocket.OnServerEvent:Connect(function(player, rocketId)
	if not allowed(player, "Purchase", 0.3) then
		return
	end
	if typeof(rocketId) ~= "string" then
		return
	end
	local rocket = RocketConfig.GetById(rocketId)
	local profile = profiles[player]
	if not rocket or not profile then
		return
	end
	if profile.Owned[rocketId] then
		notify(player, "You already own " .. rocket.Name .. ".", "info")
		sendSync(player)
		return
	end
	local money = profile.Money
	if money.Value < rocket.Price then
		notify(player, "Not enough money! You need " .. formatNumber(rocket.Price - money.Value) .. " more.", "error")
		return
	end
	money.Value -= rocket.Price
	profile.Owned[rocketId] = true
	levelsOf(profile, rocketId)
	sendSync(player)
	notify(player, rocket.Name .. " purchased!", "success")
	task.spawn(saveProfile, player)
end)

EquipRocket.OnServerEvent:Connect(function(player, rocketId)
	if not allowed(player, "Equip", 0.3) then
		return
	end
	if typeof(rocketId) ~= "string" then
		return
	end
	local rocket = RocketConfig.GetById(rocketId)
	local profile = profiles[player]
	if not rocket or not profile then
		return
	end
	if flights[player] then
		notify(player, "You can't change rockets during a flight.", "error")
		return
	end
	if not profile.Owned[rocketId] then
		notify(player, "You don't own this rocket yet.", "error")
		return
	end
	if profile.Equipped == rocketId then
		sendSync(player)
		return
	end
	profile.Equipped = rocketId
	applyAttributes(player)
	placeWorldRocket(rocketId) -- dünyadaki roketi deðiþtir
	sendSync(player)
	notify(player, rocket.Name .. " equipped!", "success")
	task.spawn(saveProfile, player)
end)

UpgradeRocket.OnServerEvent:Connect(function(player, rocketId, kind, targetLevel)
	if not allowed(player, "Upgrade", 0.3) then
		return
	end
	if typeof(rocketId) ~= "string" or typeof(kind) ~= "string" or typeof(targetLevel) ~= "number" then
		return
	end
	if kind ~= "Fuel" and kind ~= "Cargo" then
		return
	end
	if targetLevel ~= targetLevel or targetLevel == math.huge or targetLevel == -math.huge then
		return
	end
	local rocket = RocketConfig.GetById(rocketId)
	local profile = profiles[player]
	if not rocket or not profile then
		return
	end
	if flights[player] then
		notify(player, "You can't upgrade during a flight.", "error")
		return
	end
	if not profile.Owned[rocketId] then
		notify(player, "Buy this rocket before upgrading it.", "error")
		return
	end

	local levels = levelsOf(profile, rocketId)
	local current = levels[kind]
	local target = RocketConfig.ClampLevel(kind, targetLevel)
	if target <= current then
		notify(player, "Already at that level.", "info")
		sendSync(player)
		return
	end

	local cost = RocketConfig.GetUpgradeTotal(rocket, kind, current, target) -- fiyat SUNUCUDA hesaplanýr
	local money = profile.Money
	if money.Value < cost then
		notify(player, "Not enough money! You need " .. formatNumber(cost - money.Value) .. " more.", "error")
		return
	end

	money.Value -= cost
	levels[kind] = target
	if profile.Equipped == rocketId then
		applyAttributes(player)
	end
	sendSync(player)
	notify(player, (kind == "Fuel" and "Fuel Capacity" or "Cargo Capacity") .. " upgraded to level " .. target .. "!", "success")
	task.spawn(saveProfile, player)
end)

LaunchRocket.OnServerEvent:Connect(function(player)
	if not allowed(player, "Launch", RocketConfig.LaunchCooldown) then
		return
	end
	local profile = profiles[player]
	if not profile then
		return
	end
	if flights[player] then
		return
	end
	-- Sadece KUÞANILMIÞ ve SAHÝP OLUNAN roket fýrlatýlýr; istemci roket seçemez.
	local rocket = RocketConfig.GetById(profile.Equipped)
	if not rocket or not profile.Owned[rocket.Id] then
		notify(player, "Equip a rocket you own to launch.", "error")
		return
	end

	local levels = levelsOf(profile, rocket.Id)
	local stats = RocketConfig.GetFlightStats(rocket, levels.Cargo, levels.Fuel)
	local flight = {
		RocketId = rocket.Id,
		Stats = stats,
		StartedAt = workspace:GetServerTimeNow(),
	}
	flights[player] = flight
	player:SetAttribute("IsFlying", true)

	FlightStarted:FireClient(player, { RocketId = rocket.Id, StartTime = flight.StartedAt, Stats = stats })
	animateWorldLaunch()

	-- Yakýt bitince uçuþ sunucuda kendiliðinden sonlanýr
	task.delay(stats.Duration + 0.25, function()
		finishFlight(player, flight, false)
	end)
end)

EndFlight.OnServerEvent:Connect(function(player)
	if not allowed(player, "EndFlight", 0.5) then
		return
	end
	local flight = flights[player]
	if not flight then
		return
	end
	if workspace:GetServerTimeNow() - flight.StartedAt < MIN_FLIGHT_SECONDS_BEFORE_END then
		return
	end
	finishFlight(player, flight, true)
end)

-- ============================================================
-- Shop_interface dokunma sistemi
-- ============================================================
local shopPart = workspace:FindFirstChild("Shop_interface", true)
if shopPart and shopPart:IsA("BasePart") then
	shopPart.Anchored = true
	shopPart.CanTouch = true
	shopPart.Touched:Connect(function(hit)
		local character = hit:FindFirstAncestorOfClass("Model")
		local player = character and Players:GetPlayerFromCharacter(character)
		if not player or flights[player] then
			return
		end
		local now = os.clock()
		if shopTouch[player] and now - shopTouch[player] < SHOP_TOUCH_DEBOUNCE then
			return
		end
		shopTouch[player] = now
		OpenShop:FireClient(player) -- istemci zaten açýksa tekrar açmaz
	end)
else
	warn("[RocketShop] Shop_interface bulunamadý; dokunarak maðaza açma çalýþmayacak.")
end
