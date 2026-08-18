local Players = game:GetService("Players")
local Player = Players.LocalPlayer
local LocalPlayer = Player
local Character = Player.Character or Player.CharacterAdded:Wait()

-- Forward decls (phải trước CharacterAdded): Impel module gán sau, tránh global + giảm local registers
local ImpelNav, IMPEL_WAYPOINTS
local impelStart, impelStop
local saveImpelSpawn, setCurrentWaypointByKey, teleportToWaypoint
local autoAllocateStats

-- ================== CHARACTER RESPAWN HANDLER ==================
-- Khi nguoi choi chet va respawn, Character moi duoc tao ra.
-- Can cap nhat bien Character va dung cac he thong dang chay
-- de tranh crash "attempt to index nil value" tren xac cu.

Player.CharacterAdded:Connect(function(newChar)
 -- Cap nhat tham chieu Character sang nhan vat moi
 Character = newChar

 -- Doi nhan vat moi load xong (co Humanoid va HRP)
 local humanoid = newChar:WaitForChild("Humanoid", 10)
 local hrp      = newChar:WaitForChild("HumanoidRootPart", 10)

 -- Dung fly neu dang bay (tranh BodyVelocity/BodyGyro bi "treo" tren xac cu)
 if Status and Status.Fly and stopFly then
  stopFly()
 end
 -- Dung ImpelDown navigation va xoa cache (vi tri nguoi choi thay doi hoan toan)
 if ImpelNav and impelStop then
  impelStop(true) -- true = xoa cache
 end

 -- Reset flyMode dua tren vi tri hien tai cua nhan vat moi
 if isPlayerAboveGroundLevel and Fly then
  if isPlayerAboveGroundLevel() then
   Fly.flyMode = "Height"
  else
   Fly.flyMode = "Low"
  end
 end

 print("[RULRT] Character respawned - all systems reset.")
end)


local Fluent = loadstring(game:HttpGet("https://github.com/dawid-scripts/Fluent/releases/latest/download/main.lua"))()
local SaveManager = loadstring(game:HttpGet("https://raw.githubusercontent.com/dawid-scripts/Fluent/master/Addons/SaveManager.lua"))()
local InterfaceManager = loadstring(game:HttpGet("https://raw.githubusercontent.com/dawid-scripts/Fluent/master/Addons/InterfaceManager.lua"))()

local Version = "2.0.0"
local Window = Fluent:CreateWindow({
 Title = "RULRT " .. tostring(Version),
 SubTitle = "by Thuc",
 TabWidth = 160,
 Size = UDim2.fromOffset(580, 460),
 Acrylic = true,
 Theme = "Dark",
 -- Mobile: không dùng phím (không có bàn phím) — chỉ bật/tắt bằng nút/thanh trên màn hình
 MinimizeKey = (game:GetService("UserInputService").TouchEnabled == true) and nil or Enum.KeyCode.LeftControl
})
local Tabs = {
 Main       = Window:AddTab({ Title = "Main",        Icon = ""         }),
 Navigation = Window:AddTab({ Title = "Navigation",  Icon = ""         }),
 ImpelDown  = Window:AddTab({ Title = "Impel Down",  Icon = ""         }),
 Tools      = Window:AddTab({ Title = "Tools",       Icon = ""         }),
 Settings   = Window:AddTab({ Title = "Settings",    Icon = "settings" })
}

local Options = Fluent.Options

SaveManager:SetLibrary(Fluent)
InterfaceManager:SetLibrary(Fluent)
SaveManager:IgnoreThemeSettings()
SaveManager:SetIgnoreIndexes({})
InterfaceManager:SetFolder("RULRT")
SaveManager:SetFolder("RULRT/specific-game")

pcall(function() InterfaceManager:BuildInterfaceSection(Tabs.Settings) end)
pcall(function() SaveManager:BuildInterfaceSection(Tabs.Settings) end)

-- ================== SERVICES & REFS ==================

local RunService        = game:GetService("RunService")
local UserInputService  = game:GetService("UserInputService")
local PathfindingService = game:GetService("PathfindingService")
local TweenService      = game:GetService("TweenService")
local Stats            = game.ReplicatedStorage:WaitForChild("Stats" .. Player.Name, 15)
local NPCs             = game.workspace.NPCs
local Islands          = game.workspace.Islands
local Event            = game.ReplicatedStorage:FindFirstChild("Events")
local StamRequest      = Event:FindFirstChild("StamRequest")
local CombatAnimations = game:GetService("ReplicatedStorage"):WaitForChild("CombatAnimations", 10)
local Skills           = Stats.Skills
local Util             = game.ReplicatedStorage:FindFirstChild("Util")
local Movement         = Util.Movement

-- ================== CONSTANTS ==================

local BASE_Y                  = -2.7    -- do cao mat dat chuan
local HEIGHT_LIMIT            = 7       -- neu cao hon muc nay la dang bay
local ATTACK_RANGE            = 10      -- server nhận damage trong ~10 studs (hover trên đầu target cao ~8-9)
local ATTACK_RANGE_SOFT       = 9.5     -- ngưỡng an toàn khi gửi damage (tránh mép bị từ chối)

local BOOST_HEIGHT            = 500     -- do cao muc tieu khi ne vat can (studs)
local BOOST_TOLERANCE         = 1       -- sai so cho phep khi dat do cao (studs)
local VERTICAL_BOOST_SPEED    = 60      -- toc do len/xuong khi chuyen trang thai (studs/s)

local OBSTACLE_CHECK_DISTANCE = 8      -- khoang raycast kiem tra vat can (studs)
local FAR_DISTANCE_THRESHOLD  = 3500   -- khoang cach "xa" -> uu tien bay cao

-- Stamina drain dinh ky: cu moi STAMINA_DRAIN_INTERVAL giay tru 1 lan
local STAMINA_DRAIN_INTERVAL  = 0.3    -- giay
-- Stamina drain bo sung khi dang bay thang len/xuong
local VERTICAL_DRAIN_INTERVAL = 0.5    -- giay (thap hon de phan anh ton suc hon khi leo/ha)

local MAX_SPEED = 150   -- studs/giay, vuot nguong -> bat thuong
local MIN_SPEED = 1     -- studs/giay, thap hon muc nay (gan dung yen) khi dang bay -> bat thuong

-- Do cao toi thieu khi manual fly (tranh tam danh cua quai mat dat)
-- Neu nguoi choi bay o do cao thap hon muc nay, se tu dong nang len
local MIN_FLY_HEIGHT = 25  -- studs tinh tu mat dat (BASE_Y)

-- ================== STATE ==================

local Status = {
 Idle  = false,
 Walk  = false,
 Fly   = false,
 Farm  = false,
 Impel = false,
}

local Fly = {
 flyConnection   = nil,
 flyMode         = "Low",
 flyBV           = nil,
 flyGyro         = nil,
 flyTarget       = nil,
 flySpeed        = 30,
 -- Watchdog
 lastPos         = nil,
 stuckTimer      = 0,
 desiredY        = nil,
 -- Collision rerouting
 collisionTimer  = 0,   -- dem thoi gian bi va cham lien tuc
 isRerouting     = false, -- dang chay path de ne vat can
}

local Functions = {
 HakiAllwayOn = true,
}

-- ================== FORWARD DECLARATIONS ==================

local startManualFly, startAutoFly, stopFly, AllwayHaki
local FlyPathfinder -- định nghĩa đầy đủ ở engine pathfinder (tránh xung đột scope)

-- ================== FLY WATCHDOG ==================
--[[
 Chay doc lap voi flyConnection tren RunService.Heartbeat.
 Muc dich: phat hien va tu heal cac sự co fly ma flyConnection khong biet:
   - Nhan vat bi ket (khong di chuyen dù dang bay)
   - Do cao sai qua nhieu so voi Fly.desiredY
   - flyBV/flyGyro mat tich
   - PlatformStand bi reset

 Neu phat hien van de:
   * Tao lai physics objects bi mat
* Re-enforce PlatformStand
   * Neu stuck qua FLY_STUCK_TIMEOUT giay -> warn, thu reset nhe
]]
local FLY_STUCK_TIMEOUT  = 1.0   -- giay: kẹt quá ngưỡng này là can thiệp (đẩy thoát)
local FLY_STUCK_ESCAPE   = 2     -- số lần đẩy thoát; quá số này mà vẫn kẹt → DỪNG BAY hẳn
local FLY_HEIGHT_EPSILON = 10    -- studs: sai lech do cao toi da chap nhan

RunService.Heartbeat:Connect(function(dt)
 if not Status.Fly then
  Fly.stuckTimer = 0
  Fly.lastPos    = nil
  return
 end

 -- QUAN TRONG: Truy cap Character truc tiep thay vi qua helper function
 -- vi getHumanoidRootPart/getHumanoid la local duoc dinh nghia SAU watchdog
 -- -> closure khong thay -> goi nil -> spam loi. Character duoc khai bao tu dau file.
 local hrp = Character and Character:FindFirstChild("HumanoidRootPart")
 if not hrp or not hrp.Parent then return end

 local currentPos = hrp.Position

 -- === Kiem tra 1: PlatformStand ===
 local hum = Character and Character:FindFirstChildOfClass("Humanoid")
 if hum and not hum.PlatformStand then
  hum.PlatformStand = true
 end

 -- === Kiem tra 2: Physics objects con song ===
 if not Fly.flyBV or not Fly.flyBV.Parent then
  local bv = Instance.new("BodyVelocity")
  bv.MaxForce = Vector3.new(1,1,1) * math.huge
  bv.Velocity = Vector3.new(0,0,0)
  bv.Parent   = hrp
  Fly.flyBV   = bv
  print("[Watchdog] BodyVelocity duoc tao lai.")
 end
 if not Fly.flyGyro or not Fly.flyGyro.Parent then
  local gyro = Instance.new("BodyGyro")
  gyro.MaxTorque = Vector3.new(1,1,1) * math.huge
  gyro.P         = 3000
  gyro.D         = 100
  gyro.CFrame    = hrp.CFrame
  gyro.Parent    = hrp
  Fly.flyGyro    = gyro
  print("[Watchdog] BodyGyro duoc tao lai.")
 end

 -- === Kiem tra 3: Do cao lech qua nhieu ===
 if Fly.desiredY and VERTICAL_BOOST_SPEED then
  local yDiff = math.abs(currentPos.Y - Fly.desiredY)
  if yDiff > FLY_HEIGHT_EPSILON then
   local correction = (Fly.desiredY - currentPos.Y > 0) and 1 or -1
   if Fly.flyBV and Fly.flyBV.Parent then
    local cur = Fly.flyBV.Velocity
    Fly.flyBV.Velocity = Vector3.new(cur.X, correction * VERTICAL_BOOST_SPEED * 1.5, cur.Z)
   end
  end
 end

 -- === Kiem tra 4: Phat hien bi ket (stuck) ===
 if Fly.lastPos then
  local moved = (currentPos - Fly.lastPos).Magnitude
  local hasMoveCommand = Fly.flyBV and Fly.flyBV.Velocity.Magnitude > 0.1
  if hasMoveCommand and moved < 0.5 then
   Fly.stuckTimer = Fly.stuckTimer + dt
   if Fly.stuckTimer >= FLY_STUCK_TIMEOUT then
    -- Đẩy thoát (chống kẹt tường/cây) — nhưng đếm số lần để dừng hẳn nếu kẹt dai dẳng
    if Fly.flyBV and Fly.flyBV.Parent then
     local v = Fly.flyBV.Velocity
     if VERTICAL_BOOST_SPEED then
      Fly.flyBV.Velocity = v * 2 + Vector3.new(0, VERTICAL_BOOST_SPEED, 0)
     end
    end
    Fly.stuckTimer = 0
    Fly.stuckNudges = (Fly.stuckNudges or 0) + 1
    print("[Watchdog] Phat hien bi ket, dang co thoat (lan " .. Fly.stuckNudges .. ")...")
   end
  else
   Fly.stuckTimer = 0
   Fly.stuckNudges = 0
  end
  -- Kẹt dai dẳng (đã đẩy thoát nhiều lần mà không thoát) → DỪNG BAY hẳn, không lơ lửng
  if (Fly.stuckNudges or 0) >= FLY_STUCK_ESCAPE then
   Fly.stuckTimer = 0
   Fly.stuckNudges = 0
   print("[Watchdog] Ket qua lau khong thoat — DUNG BAY")
   pcall(notify, "[Watchdog] Bay bị kẹt không thoát được — đã dừng bay", 4)
   stopFly()
  end
 end
 Fly.lastPos = currentPos
end)

-- ================== NOTIFICATION ==================

local function notify(content, duration)
 pcall(function()
  Fluent:Notify({
   Title    = "RULRT",
   Content  = content,
   Duration = duration or 3
  })
 end)
end

-- ================== SHARED STATUS (dùng chung cả script) ==================
-- Mọi hệ thống (AutoFarm, ImpelDown, Fly, IslandFly, NavFly, Haki)
-- đều ghi vào Status này để biết hệ thống nào đang hoạt động.
local SharedStatus = { label = nil }

local SHARED_STATUS_ICONS = {
 Idle         = "⏸️",
 Fly          = "✈️",
 Farm         = "⚔️",
 Bay          = "✈️",
 Looting      = "📦",
 OpenLock     = "🔑",
 Pathfind     = "🧭",
 WaitingQuest = "📜",
 KillDone     = "✅",
 QuestDone    = "🏆",
 UpdateStats  = "📊",
 Haki         = "🟣",
 Off          = "⛔",
}

--- module: "AutoFarm" | "ImpelDown" | "Fly" | "IslandFly" | "NavFly" | "Haki"
--- status: ten status, detail: mo ta
local function setSharedStatus(module, status, detail)
 if SharedStatus.label then
  pcall(function()
   local icon = SHARED_STATUS_ICONS[status] or "•"
   SharedStatus.label:SetTitle(string.format("%s [%s] %s", icon, module, status))
   SharedStatus.label:SetDesc(detail or "")
  end)
 end
end

-- ================== UI SETUP ==================

 do
Tabs.Main:AddParagraph({
  Title   = "Paragraph",
  Content = "Hi, Welcome!"
 })
end

-- Status dung chung toan script (moi he thong ghi vao day)
local SharedStatusParagraph = Tabs.Main:AddParagraph({
 Title   = "• [Script] Idle",
 Content = "Chua co he thong nao hoat dong"
})
SharedStatus.label = SharedStatusParagraph

local FlyToggle = Tabs.Main:AddToggle("Fly", { Title = "Fly", Default = false })
FlyToggle:OnChanged(function()
 local active = Options.Fly.Value
 notify("Fly: " .. tostring(active), 3)
 if active then
  setSharedStatus("Fly", "Fly", "Manual Fly dang bat")
  if startManualFly then startManualFly() end
 else
  setSharedStatus("Fly", "Idle", "Manual Fly da tat")
  if stopFly then stopFly() end
 end
end)
-- KHONG goi SetValue(false) o day vi se trigger OnChanged ngay khi cac ham chua duoc dinh nghia
-- SetValue se duoc goi o cuoi file sau khi tat ca ham san sang

local SpeedFlySlider = Tabs.Main:AddSlider("SpeedFly", {
 Title       = "SpeedFly",
 Description = "Change your fly speed",
 Default     = 30,
 Min         = 0,
 Max         = 100,
 Rounding    = 1,
 Callback    = function(value)
  Fly.flySpeed = value
 end
})
SpeedFlySlider:OnChanged(function(value)
 Fly.flySpeed = value
end)

local AutoHakiToggle = Tabs.Main:AddToggle("AutoHaki", { Title = "Auto Haki (Always On)", Default = true })
AutoHakiToggle:OnChanged(function()
 local active = Options.AutoHaki.Value
 Functions.HakiAllwayOn = active
 notify("Auto Haki: " .. tostring(active), 3)
 setSharedStatus("Haki", active and "Haki" or "Idle", active and "Auto Haki dang bat" or "Auto Haki da tat")
 -- Khong goi AllwayHaki o day nua; loop o duoi se tu xu ly
end)
-- Su dung IgnoreChangedSignal de SetValue khong trigger OnChanged ngay lap tuc
-- (tranh viec haki bi bat nguoc lai khi script moi chay)
Options.AutoHaki:SetValue(true)

-- Loop kiem tra lien tuc: neu HakiAllwayOn == true thi giu haki luon bat
RunService.Heartbeat:Connect(function()
 if Functions.HakiAllwayOn and AllwayHaki then
  AllwayHaki(true)
 end
end)

-- ── Island Fly UI (phai khai bao sau ISLAND NAVIGATION o duoi) ──
-- Dung do cac ham getIslandList / flyToIsland duoc dinh nghia sau,
-- nen phan UI nay se duoc thiet lap trong block do...end o cuoi file
-- sau khi tat ca ham san sang.

-- ================== BOSS TIMER ==================
--[[
 FIX cac loi trong readNextBossSpawnTime:
   1. now/timeData dong bang -> dung ham de tinh lai moi lan
   2. diff < 0 (truoc 1AM): tra ve 1AM NGAY MAI, khong phai 1AM da qua
   3. timeLeft == interval (dung gio spawn): xu ly thanh 0
   4. Them loop cap nhat moi giay + thong bao sap spawn
]]

--- Tinh thoi gian den lan spawn ke tiep dua tren gio 1AM Viet Nam + interval
--- Mui gio: UTC+7 (Viet Nam)
--- Tra ve: nextSpawnTime (Unix timestamp), secondsLeft (so)
local VN_UTC_OFFSET = 7 * 3600  -- 25200 giay (UTC+7)

local function readNextBossSpawnTime(intervalMinutes)
 local t           = os.time()  -- UTC timestamp (Roblox mac dinh)
 local intervalSec = intervalMinutes * 60

 -- Chuyen sang gio Viet Nam (UTC+7) de xac dinh "ngay hom nay" theo VN
 local vnTime = t + VN_UTC_OFFSET
 local vnData = os.date("!*t", vnTime)  -- "!" = parse theo UTC (ta da cong offset roi)

 -- Tinh so giay da troi trong ngay VN
 local secondsInDayVN = vnData.hour * 3600 + vnData.min * 60 + vnData.sec
 -- Midnight (0h) VN hom nay (trong khong gian VN)
 local midnightVN = vnTime - secondsInDayVN
 -- 1AM VN hom nay (trong khong gian VN)
 local oneAM_VN = midnightVN + 3600

 -- Chuyen 1AM VN ve UTC timestamp de so sanh voi os.time()
 local baseOneAM = oneAM_VN - VN_UTC_OFFSET

 local diff = t - baseOneAM

 -- Neu truoc 1AM VN (diff < 0) -> lan spawn dau la chinh baseOneAM
 if diff < 0 then
  return baseOneAM, -diff
 end

 -- Tinh so giay da qua trong chu ky hien tai
 local timePassed = diff % intervalSec
 local timeLeft   = intervalSec - timePassed

 -- Neu dung gio spawn (timePassed == 0) -> boss vua spawn -> dat ve 0
 if timePassed == 0 then
  timeLeft = 0
 end

 return t + timeLeft, timeLeft
end

local function formatSecondsToHMS(seconds)
 seconds = math.max(0, math.floor(seconds))
 local h = math.floor(seconds / 3600)
 local m = math.floor((seconds % 3600) / 60)
 local s = seconds % 60
 return string.format("%02d:%02d:%02d", h, m, s)
end

-- ================== BOSS SPAWN NOTIFICATION ==================
--[[
 He thong theo doi thoi gian spawn va gui thong bao khi sap den.
 Cac nguong thong bao:
   * 5 phut truoc  -> warn 1 lan
   * 1 phut truoc  -> warn 1 lan
   * Dung gio spawn -> thong bao spawn
 Moi boss co bang notified de tranh spam thong bao.
]]

local BOSS_LIST = {
 { name = "Mihawk",   intervalMinutes = 120 },
 { name = "Roger",    intervalMinutes = 90  },
 { name = "SoulKing", intervalMinutes = 60  },
}

-- Nguong thong bao (giay): [ so_giay_con_lai ] = "noi_dung"
local NOTIFY_THRESHOLDS = {
 { seconds = 300, label = "5 phut"  },
 { seconds = 60,  label = "1 phut"  },
 { seconds = 0,   label = "SPAWN"   },
}

-- Bang luu trang thai thong bao cua tung boss
-- notified[bossName][thresholdSeconds] = true/false
local bossNotified = {}
for _, boss in ipairs(BOSS_LIST) do
 bossNotified[boss.name] = {}
 for _, th in ipairs(NOTIFY_THRESHOLDS) do
  bossNotified[boss.name][th.seconds] = false
 end
end

-- Luu thoi gian kiem tra cuoi cung de chi chay moi ~1 giay
local lastBossCheck = 0

RunService.Heartbeat:Connect(function()
 local now = os.time()
 -- Chi kiem tra moi 1 giay (tranh spam call os.time qua nhieu)
 if now - lastBossCheck < 1 then return end
 lastBossCheck = now

 for _, boss in ipairs(BOSS_LIST) do
  local _, secondsLeft = readNextBossSpawnTime(boss.intervalMinutes)

  for _, th in ipairs(NOTIFY_THRESHOLDS) do
   -- Da gui thong bao nay roi -> bo qua
   if bossNotified[boss.name][th.seconds] then
    -- Reset neu thoi gian da vuot qua nguong (tuc la chu ky moi bat dau)
    -- Vi du: sau khi boss spawn (secondsLeft=0), chu ky moi co secondsLeft lon
    -- -> dat lai de chuan bi cho lan tiep
    if secondsLeft > th.seconds + 30 then
     bossNotified[boss.name][th.seconds] = false
    end
   else
    -- Kiem tra xem co nam trong cua so thong bao khong
    -- Cua so: [th.seconds-5 , th.seconds] (5 giay sai so chap nhan)
    if secondsLeft <= th.seconds + 5 and secondsLeft >= math.max(0, th.seconds - 5) then
     bossNotified[boss.name][th.seconds] = true

     local msg
     if th.seconds == 0 then
      msg = string.format(
       "⚔️ %s DA SPAWN! Nhanh len!",
       boss.name
      )
     else
      msg = string.format(
       "⏰ %s spawn sau %s! (con %s)",
       boss.name,
       th.label,
       formatSecondsToHMS(secondsLeft)
      )
     end

     -- Gui thong bao (pcall phong truong hop Fluent chua san sang)
     pcall(function()
      Fluent:Notify({
       Title    = "Boss Timer",
Content  = msg,
       Duration = (th.seconds == 0) and 10 or 6
      })
     end)
     print("[BossTimer] " .. msg)
    end
   end
  end
 end
end)

-- ================== CHARACTER HELPERS ==================

local function getHumanoidRootPart()
 return Character and Character:FindFirstChild("HumanoidRootPart")
end

local function getHumanoid()
 return Character and Character:FindFirstChildOfClass("Humanoid")
end

local function isPlayerAlive()
 local humanoid = getHumanoid()
 return humanoid and humanoid.Health > 0
end

--- Lay vi tri hien tai cua nhan vat (uu tien CFrameValue "realPos" do server cap nhat)
local function getPlayerPosition()
 local realPos = Character and Character:FindFirstChild("realPos")
 if realPos and realPos:IsA("CFrameValue") then
  return realPos.Value.Position
 end
 local hrp = getHumanoidRootPart()
 return hrp and hrp.Position
end

--- Kiem tra nhan vat dang tren khong (cao hon HEIGHT_LIMIT so voi BASE_Y)
local function isPlayerAboveGroundLevel()
 local pos = getPlayerPosition()
 if not pos then return false end
 return math.abs(pos.Y - BASE_Y) > HEIGHT_LIMIT
end

-- ================== POSITION & DISTANCE HELPERS ==================

local function getPositionOf(obj)
 if obj:IsA("BasePart") then
  return obj.Position
 elseif obj:IsA("Model") then
  if obj.PrimaryPart then
   return obj.PrimaryPart.Position
  end
  local hrp = obj:FindFirstChild("HumanoidRootPart")
  if hrp then return hrp.Position end
 end
 return nil
end

--- Khoang cach Euclidean giua 2 Vector3
local function getDistanceBetweenPoints(pos1, pos2)
 return (pos1 - pos2).Magnitude
end

--- Khoang cach giua 2 Instance (BasePart hoac Model)
--- Tra ve math.huge neu khong lay duoc vi tri
local function getDistanceBetweenObjects(obj1, obj2)
 local pos1 = getPositionOf(obj1)
 local pos2 = getPositionOf(obj2)
 if not (pos1 and pos2) then
  return math.huge
 end
 return (pos1 - pos2).Magnitude
end

-- ================== STAMINA & SKILL CALLS ==================

--- Goi Sky Walk (geppo) de giam stamina khi co BlackLeg
local function callSkyWalk()
 local char = Player.Character
 local hrp  = getHumanoidRootPart()
 if not (char and hrp) then return false end

 local args = {
  "Sky Walk",
  {
   char = char,
   cf   = hrp.CFrame
  }
 }
 game:GetService("ReplicatedStorage"):WaitForChild("Events"):WaitForChild("Skill"):InvokeServer(unpack(args))
 return true
end

--- Kiểm tra có BlackLeg trong túi đồ (Backpack / trên tay / Inventory JSON)
local function hasBlackLeg()
 local char = Player.Character
 local bp   = Player:FindFirstChild("Backpack")
 if (char and char:FindFirstChild("BlackLeg")) or (bp and bp:FindFirstChild("BlackLeg")) then
  return true
 end
 local pStats = game:GetService("ReplicatedStorage"):FindFirstChild("Stats" .. Player.Name)
 local invObj = pStats and pStats:FindFirstChild("Inventory") and pStats.Inventory:FindFirstChild("Inventory")
 if invObj and invObj:IsA("StringValue") and invObj.Value ~= "" then
  local HttpService = game:GetService("HttpService")
  local ok, parsed = pcall(function() return HttpService:JSONDecode(invObj.Value) end)
  if ok and type(parsed) == "table" then
   for k, v in pairs(parsed) do
    if string.find(string.lower(k), "blackleg") and ((type(v) == "number" and v > 0) or v == true) then
     return true
    end
   end
  end
 end
 return false
end

--- Tru stamina bằng Sky Walk — CHỈ khi có BlackLeg trong túi đồ (bỏ Dash/takestam)
--- Tra ve false neu khong the tru (khong co BlackLeg → nên dừng bay)
local function drainStamina()
 if not hasBlackLeg() then return false end
 pcall(callSkyWalk)
 return true
end

-- ================== HAKI ==================

local function callActivateHaki()
 game:GetService("ReplicatedStorage"):WaitForChild("Events"):WaitForChild("Haki"):FireServer("Buso")
end

AllwayHaki = function(active)
    if not active then return end

    -- Kiểm tra trạng thái Haki thực tế từ Stats
    local pStats = Stats
    local statsChild = pStats and pStats:FindFirstChild("Stats")

    -- [TRƯỜNG HỢP 1]: BusoActivated = true → Haki đang BẬT vĩnh viễn (Impel Down) → không cần bật lại
    local busoActivated = statsChild and statsChild:FindFirstChild("BusoActivated")
    if busoActivated and busoActivated.Value == true then
        return -- Haki đang ON vĩnh viễn, bỏ qua
    end

    -- [TRƯỜNG HỢP 2]: BusoBar tồn tại → chế độ Haki bình thường (bật khi đầy bar)
    local ok, busoBar = pcall(function() return pStats:WaitForChild("BusoBar", 1) end)
    if ok and busoBar then
        local maxVal = busoBar.MaxValue
        local curVal = busoBar.Value
        if curVal >= maxVal then
            callActivateHaki()
        end
        return
    end

    -- [TRƯỜNG HỢP 3]: Không có BusoBar, không có BusoActivated → cứ bật thử
    callActivateHaki()
end
AllwayHaki(Functions.HakiAllwayOn)

-- ================== BLOCK ==================

local function startBlock()
 game:GetService("ReplicatedStorage"):WaitForChild("Events"):WaitForChild("Block"):InvokeServer(true, "Melee", true)
end

local function stopBlock()
 game:GetService("ReplicatedStorage"):WaitForChild("Events"):WaitForChild("Block"):InvokeServer(false, "Melee")
end

local function callBlock(active)
 if active then startBlock() else stopBlock() end
end

-- ================== NPC TRACKING ==================

local npcEntries = {} -- [npcInstance] = { Humanoid, HRP, Info }

local function trackNPC(npc)
 local humanoid = npc:FindFirstChildOfClass("Humanoid")
 local hrp      = npc:FindFirstChild("HumanoidRootPart")
 local info     = npc:FindFirstChild("Info")

 if not (humanoid and hrp) then return end

 local entry = { Humanoid = humanoid, HRP = hrp, Info = info }
 npcEntries[npc] = entry

 humanoid.Died:Connect(function()
  npcEntries[npc] = nil
 end)
 npc.AncestryChanged:Connect(function(_, parent)
  if not parent then
   npcEntries[npc] = nil
  end
 end)
 return entry
end

for _, npc in ipairs(NPCs:GetChildren()) do
 trackNPC(npc)
end
NPCs.ChildAdded:Connect(trackNPC)

-- Khai báo trước các hàm Impel Down được Watcher gọi
local killMonster
local killImpelMonster
local impelSetStatus

local function isNPCTargetingPlayer(info)
    if not info then return false end
    local targetVal = info:FindFirstChild("Target")
    if not targetVal then return false end

    local myName = LocalPlayer and LocalPlayer.Name
    if not myName then return false end

    -- Cách 1: ObjectValue – .Value là Instance, kiểm tra theo Name
    if targetVal:IsA("ObjectValue") and targetVal.Value then
        local t = targetVal.Value
        -- So sánh tên: t.Name == tên người chơi
        if t.Name == myName then return true end
        -- Hoặc target là Character/part thuộc Character
        local char = Character or LocalPlayer.Character
        if t == char or t == LocalPlayer or (char and (t == char.PrimaryPart or t:IsDescendantOf(char))) then
            return true
        end
    end

    -- Cách 2: StringValue – .Value là string tên người chơi
    if targetVal:IsA("StringValue") and targetVal.Value ~= "" then
        if targetVal.Value == myName or string.lower(targetVal.Value) == string.lower(myName) then
            return true
        end
    end

    return false
end

-- Background watcher: Liên tục kiểm tra NPC nào có Target == tên người chơi
-- Nếu phát hiện → ÉP người chơi sang trạng thái tấn công ngay
local npcTargetWatcherConn = nil
local _isHandlingNPCTarget = false

local function stopNPCTargetWatcher()
    if npcTargetWatcherConn then
        npcTargetWatcherConn:Disconnect()
        npcTargetWatcherConn = nil
    end
end

local function startNPCTargetWatcher()
    stopNPCTargetWatcher()
    local myName = LocalPlayer and LocalPlayer.Name
    if not myName then return end

    print("👁️ [NPCTargetWatcher] BẮT ĐẦU THEO DÕI NPC TARGET...")

    npcTargetWatcherConn = RunService.Heartbeat:Connect(function()
        if _isHandlingNPCTarget then return end
        if not isPlayerAlive() then return end
        -- Hành lang w-2 ↔ w-3: không quan tâm Target quái, không ngắt bay
        if ImpelNav and ImpelNav.ignoreMonsterTargets then return end

        local npcFolder = workspace:FindFirstChild("NPCs")
        if not npcFolder then return end

        for _, npc in ipairs(npcFolder:GetChildren()) do
            if npc:IsA("Model") then
                local info = npc:FindFirstChild("Info")
                if info then
                    local targetVal = info:FindFirstChild("Target")
                    if targetVal then
                        local isTargeting = false

                        if targetVal:IsA("ObjectValue") and targetVal.Value then
                            local t = targetVal.Value
                            if t.Name == myName then isTargeting = true end
                            local char = Character or LocalPlayer.Character
                            if char and not isTargeting and (t == char or t:IsDescendantOf(char)) then
                                isTargeting = true
                            end
                        elseif targetVal:IsA("StringValue") and targetVal.Value ~= "" then
                            if string.lower(targetVal.Value) == string.lower(myName) then
                                isTargeting = true
                            end
                        end

                        if isTargeting then
                            local hum = npc:FindFirstChildOfClass("Humanoid")
                            local hrp = npc:FindFirstChild("HumanoidRootPart")
                            if hum and hrp and hum.Health > 0 then
                                _isHandlingNPCTarget = true
                                local npcData = {
                                    Model         = npc,
                                    HRP           = hrp,
                                    Health        = hum.Health,
                                    MaxHealth     = hum.MaxHealth,
                                    Distance      = (getPlayerPosition() and (hrp.Position - getPlayerPosition()).Magnitude) or 0,
                                    Position      = hrp.Position,
                                    IsTargetingMe = true,
                                }
                                warn(string.format("🚨 [NPCTargetWatcher] NPC '%s' đang TARGET bạn! Ép sang chiến đấu...", npc.Name))
                                if impelSetStatus then impelSetStatus("Farm", string.format("⚠️ NPC '%s' Target bạn! Tấn công ngay!", npc.Name)) end
                                notify(string.format("🚨 NPC '%s' đang Target bạn!", npc.Name), 4)

                                -- Dừng bay nếu đang bay
                                pcall(function() FlyPathfinder.CleanupPhysics() end)

                                -- Tấn công cho đến khi chết
                                local speed = (Options and Options.ImpelSpeed and tonumber(Options.ImpelSpeed.Value)) or 75
                                task.spawn(function()
                                    if killImpelMonster then
                                        pcall(function() killImpelMonster(npcData, speed) end)
                                    end
                                    _isHandlingNPCTarget = false
                                end)
                                return -- Thôi check các NPC khác – đợi xử lý xong
                            end
                        end
                    end
                end
            end
        end
    end)
end


local function getNPCSnapshot()
    local npcs, monsters = {}, {}
    local playerPos = getPlayerPosition()

    for npc, data in pairs(npcEntries) do
        if data.Humanoid.Health > 0 then
            local isTargeting = isNPCTargetingPlayer(data.Info)
            local isHostile   = (data.Info and data.Info:FindFirstChild("Hostile") and data.Info.Hostile.Value) or isTargeting
            local snapshot = {
                Model         = npc,
                Distance      = playerPos and getDistanceBetweenPoints(data.HRP.Position, playerPos) or math.huge,
                Health        = data.Humanoid.Health,
                MaxHealth     = data.Humanoid.MaxHealth,
                Position      = data.HRP.Position,
                CFrame        = data.HRP.CFrame,
                IsTargetingMe = isTargeting,
            }
            if isHostile then
                table.insert(monsters, snapshot)
            else
                table.insert(npcs, snapshot)
            end
        end
    end
    return npcs, monsters
end

-- ================== QUEST HELPERS ==================

local QUEST_ACTIONS = { "Clear", "Defeat", "Hunt", "Slay", "Kill", "Eliminate", "Beat", "Fight" }

-- Lay danh sach quest da hoan thanh tu ReplicatedStorage.Stats<Player>.Quest.CompletedQuests (JSON array)
-- Tra ve table { [questName] = true } de lookup O(1)
local function getCompletedQuests()
 local completed = {}
 local rs = game:GetService("ReplicatedStorage")
 local HttpService = game:GetService("HttpService")
 local pStats = rs:FindFirstChild("Stats" .. Player.Name)
    or (rs:FindFirstChild("Stats") and rs.Stats:FindFirstChild(Player.Name))
 local questFolder = pStats and pStats:FindFirstChild("Quest")
 local completedVal = questFolder and questFolder:FindFirstChild("CompletedQuests")
 local raw = completedVal and completedVal.Value or ""
 if raw and raw ~= "" then
  local ok, decoded = pcall(function()
   return HttpService:JSONDecode(raw)
  end)
  if ok and type(decoded) == "table" then
   for _, name in ipairs(decoded) do
    completed[name] = true
   end
  end
 end
 return completed
end

-- Load tat ca quest definitions tu ReplicatedStorage.Modules.NPCInteractions.Talks
-- Moi ModuleScript phai tra ve table co QuestName. _Island duoc inject tu ten thu muc cha.
-- Ket qua duoc cache sau lan goi dau tien de tranh require() nhieu lan.
local _allQuestsCache = nil
local function loadAllQuests()
 if _allQuestsCache then return _allQuestsCache end
 local quests = {}
 local rs = game:GetService("ReplicatedStorage")
 local talksFolder = rs:FindFirstChild("Modules")
 if talksFolder then
  talksFolder = talksFolder:FindFirstChild("NPCInteractions")
  if talksFolder then
   talksFolder = talksFolder:FindFirstChild("Talks")
  end
 end
 if not talksFolder then
  _allQuestsCache = quests
  return quests
 end
 for _, descendant in ipairs(talksFolder:GetDescendants()) do
  if descendant:IsA("ModuleScript") then
   local ok, questData = pcall(function()
    return require(descendant)
   end)
   if ok and type(questData) == "table" and questData.QuestName then
    local parent = descendant.Parent
    if parent and parent ~= talksFolder then
     questData._Island = parent.Name
    else
     questData._Island = "Khong ro"
    end
    table.insert(quests, questData)
   end
  end
 end
 _allQuestsCache = quests
 return quests
end

-- Kiem tra xem mot mob co phai boss khong (theo ten hoac folder Replication.Bosses)
local function isBoss(mobName)
 if not mobName then return false end
 if string.find(string.lower(mobName), "boss") then return true end
 local rs = game:GetService("ReplicatedStorage")
 local bossesFolder = rs:FindFirstChild("Replication")
 if bossesFolder then bossesFolder = bossesFolder:FindFirstChild("Bosses") end
 if bossesFolder and bossesFolder:FindFirstChild(mobName) then return true end
 return false
end
_G.isBoss = isBoss

-- Cache ket qua getQuestLocations (goi server 1 lan duy nhat, khong spam remote)
local _cachedQuestLocations = nil
local function getQuestLocationsCache()
 if _cachedQuestLocations then return _cachedQuestLocations end
 local events = game:GetService("ReplicatedStorage"):FindFirstChild("Events")
 local remote  = events and events:FindFirstChild("Quest")
 if remote then
  local ok, result = pcall(function() return remote:InvokeServer({ "getQuestLocations" }) end)
  if ok and type(result) == "table" then
   _cachedQuestLocations = result
   return result
  end
 end
 _cachedQuestLocations = {}
 return _cachedQuestLocations
end

-- Lay CFrame tu bat ky Instance (BasePart, Model, hoac co chứa BasePart)
local function getInstanceCFrame(inst)
 if not inst then return nil end
 if inst:IsA("BasePart") then return inst.CFrame end
 if inst:IsA("Model") then
  local pp = inst.PrimaryPart or inst:FindFirstChild("HumanoidRootPart")
  if pp then return pp.CFrame end
  return inst:GetPivot()
 end
 local part = inst:FindFirstChildWhichIsA("BasePart", true)
 return part and part.CFrame or nil
end

-- Lay toa do NPC theo 3 tang uu tien:
--   1. Workspace.NPCs (recursive, lay ca realPos / SpawnCFrame neu model chua co HRP)
--   2. Cache getQuestLocations tu server (goi 1 lan, khong spam)
--   3. Tra ve nil (se dung db.position tu QuestDB)
local function getNPCPosition(npcName)
 if not npcName or npcName == "" then return nil end

 -- Tang 1: Workspace.NPCs (tim de quy)
 local npcsFolder = workspace:FindFirstChild("NPCs")
 if npcsFolder then
  local npcModel = npcsFolder:FindFirstChild(npcName, true) -- recursive
  if npcModel then
   local cf = getInstanceCFrame(npcModel)
   if cf then return cf.Position end
   -- Fallback: realPos CFrameValue
   local realPos = npcModel:FindFirstChild("realPos")
   if realPos and realPos:IsA("CFrameValue") then return realPos.Value.Position end
   -- Fallback: Info.SpawnCFrame
   local info = npcModel:FindFirstChild("Info")
   if info then
    local spawnCF = info:FindFirstChild("SpawnCFrame")
    if spawnCF and spawnCF:IsA("CFrameValue") then return spawnCF.Value.Position end
   end
  end
 end

 -- Tang 2: getQuestLocations tu server (cached)
 local locs = getQuestLocationsCache()
 local cf = locs[npcName]
 if cf then
  if typeof(cf) == "CFrame"   then return cf.Position end
  if typeof(cf) == "Vector3"  then return cf end
 end

 return nil
end
_G.getNPCPosition = getNPCPosition

-- ================== QUEST DATABASE ==================
-- Tra cứu quest theo tên NPC giao quest (key).
-- position = nil → SẼ THÊM TỌA ĐỘ SAU (Vector3).
-- count = nil → chưa có số liệu chính xác.
-- action = "awaken" → quest thức tỉnh (không phải diệt).
local QuestDB = {
 -- ===== BIỂN 1 (FIRST SEA) =====
 -- 1. Town of Beginnings
 ["Daph"]  = { island = "Town of Beginnings", minLevel = 0,  targets = "Bandit",      count = 10, action = "kill", quest = "Help Daph", position = Vector3.new(-575.4163, 5.0742, -3434.5330) },
 ["Ronny"] = { island = "Town of Beginnings", minLevel = 5,  targets = "Bandit Boss",  count = 1,  action = "kill", position = Vector3.new(-540.1252, 5.0742, -3288.3198) },
 -- 2. Sandora
 ["Noah"]  = { island = "Sandora", minLevel = 11, targets = "Desert Bandit", count = 7, action = "kill", position = Vector3.new(-1710.6161, 3.9746, -3375.1345) },
 -- 3. Shell's Town
 ["Robert"] = { island = "Shell's Town", minLevel = 20, targets = "Corrupt Marines",  count = 8, action = "kill", position = Vector3.new(-1444.9070, 9.8750, -5102.1353) },
 ["Kevin"]  = { island = "Shell's Town", minLevel = 25, targets = "Shell's Bandits",  count = 8, action = "kill", position = Vector3.new(-1223.4202, 63.5007, -5189.7456) },
 ["Gozen"]  = { island = "Shell's Town", minLevel = 30, targets = "Axe Hand Logan",   count = 1, action = "kill", position = nil },
 -- NPC quest chưa có thông tin (chỉ mới có tọa độ)
 ["Zen"]   = { island = nil, minLevel = nil, targets = nil, count = nil, action = "kill", position = Vector3.new(-3172.5718, 11.7344, -5229.1821) },
 
 ["Zhen"]  = { island = nil, minLevel = nil, targets = nil, count = nil, action = "kill", position = Vector3.new(4094.6816, 1818.9696, -9831.1533) },
 -- 4. Island of Zou
 ["Zou Quest NPC"] = { island = "Island of Zou", minLevel = 35, targets = "Mink Inhabitants / Zou Inhabitants", count = 10, action = "kill", position = nil },
 -- 5. Restaurant Baratie
 ["Baratie Quest NPC"] = { island = "Restaurant Baratie", minLevel = 40, targets = "Krieg Pirates", count = 8, action = "kill", position = nil },
 -- 6. Orange Town
 ["Orange Town NPC"] = { island = "Orange Town", minLevel = 50, targets = "Star Clown", count = 1, action = "kill", position = nil },
 -- 7. Sphinx Island
 ["Gonny"]            = { island = "Sphinx Island", minLevel = 60, targets = "Monkeys",      count = 10, action = "kill", position = Vector3.new(-4248.5020, 42.1641, -8931.3633) },
 ["Sphinx Boss NPC"]  = { island = "Sphinx Island", minLevel = 65, targets = "Gorilla King", count = 1,  action = "kill", position = nil },
 -- 8. Arlong Park
 ["Waby"] = { island = "Arlong Park", minLevel = 70, targets = "Saw Shark Pirates", count = 10, action = "kill", position = Vector3.new(-1888.4865, 12.2969, -10229.8213) },
 ["Vi"]   = { island = "Arlong Park", minLevel = 80, targets = "Saw Shark",         count = 1,  action = "kill", position = nil },
 -- 9. Land of the Sky (Skypiea)
 ["Vego"]              = { island = "Land of the Sky (Skypiea)", minLevel = 105, targets = "Sky Bandits",            count = 5,  action = "kill", position = nil },
 ["Sky Castle NPC"]    = { island = "Land of the Sky (Skypiea)", minLevel = 110, targets = "Castle Guards",          count = 5,  action = "kill", position = nil },
 ["Sky Boss NPC"]      = { island = "Land of the Sky (Skypiea)", minLevel = 135, targets = "Head Guardian",          count = 1,  action = "kill", position = nil },
 ["Bibby"]             = { island = "Land of the Sky (Skypiea)", minLevel = 145, targets = "Malcolm Undermen",       count = 6,  action = "kill", position = nil },
 ["Viva"]              = { island = "Land of the Sky (Skypiea)", minLevel = 150, targets = "Malcolm",                count = 1,  action = "kill", position = nil },
 ["Golden City NPC"]   = { island = "Land of the Sky (Skypiea)", minLevel = 155, targets = "Enel / Thunder God",     count = 1,  action = "kill", position = nil },
 -- 10. Gravito's Fort
 ["Miska"] = { island = "Gravito's Fort", minLevel = 160, targets = "Gravito's Undermen", count = 4, action = "kill", position = Vector3.new(179.6954, 41.4688, -11659.6855) },
 ["Yourg"] = { island = "Gravito's Fort", minLevel = 180, targets = "Gravito's Guards",   count = 3, action = "kill", position = nil },
 ["Verga"] = { island = "Gravito's Fort", minLevel = 190, targets = "Gravito",            count = 1, action = "kill", position = nil },
 -- 11. Fishman Island
 ["Becky"] = { island = "Fishman Island", minLevel = 190, targets = "Fishman Karate Users", count = 5, action = "kill", position = nil },
 ["Jenny"] = { island = "Fishman Island", minLevel = 210, targets = "Ryu",                  count = 1, action = "kill", position = nil },
 ["Janny"] = { island = "Fishman Island", minLevel = 230, targets = "Neptune",              count = 1, action = "kill", position = nil },
 -- 12. Marine Fort G-1
 ["Wane"]          = { island = "Marine Fort G-1", minLevel = 215, targets = "Marine Fort Snipers", count = nil, action = "kill", position = Vector3.new(-6087.3936, 75.1094, -11266.0762) },
 ["Pichu"]         = { island = "Marine Fort G-1", minLevel = 250, targets = "Marine Fort Gunners", count = nil, action = "kill", position = nil },
 ["G-1 Boss NPC"]  = { island = "Marine Fort G-1", minLevel = 280, targets = "Flame Admiral Zeke",  count = 1,  action = "kill", position = nil },

 -- ===== BIỂN 2 (SECOND SEA) =====
 -- 1. Desert Kingdom (Alabasta)
 ["Zaki"]          = { island = "Thriller Bark", minLevel = 325, targets = "Zombie", count = 10, action = "kill", position = nil },
 ["City Criminal"] = { island = "Thriller Bark", minLevel = 350, targets = "Zombie Knight", count = 6,  action = "kill", position = nil },
 ["Pharaoh NPC"]   = { island = "Desert Kingdom (Alabasta)", minLevel = 340, targets = "Pharaoh Akshan",     count = nil, action = "awaken", position = nil },
 ["Samira"]        = { island = "Desert Kingdom (Alabasta)", minLevel = 375, targets = "Pharaoh Akshan",     count = 1,  action = "kill", position = nil },
 -- 2. Crab Cave
 ["Zerus"]           = { island = "Crab Cave",            minLevel = 350, targets = "Crab Minions", count = 5, action = "kill", position = nil },
 ["Crab Boss NPC"]   = { island = "Crab Cave",            minLevel = 375, targets = "Crab King",    count = 1, action = "kill", position = nil },
 -- 3. Thriller Bark
 ["Zombie Knight Quest NPC"] = { island = "Thriller Bark", minLevel = 350, targets = "Zombie Knights", count = 6,  action = "kill", position = nil },
 ["Graveyard Zombie NPC"]    = { island = "Thriller Bark", minLevel = 350, targets = "Zombies",       count = nil, action = "kill", position = nil },
 -- 4. Rose Kingdom (Dressrosa) — NPC còn gọi là "PJ"
 ["Rose Kingdom NPC"] = { island = "Rose Kingdom (Dressrosa)", minLevel = 425, targets = "Crazy Wolves", count = 6, action = "kill", position = nil },
}

--- Bỏ động từ đầu câu + số lượng, giữ nguyên phần còn lại làm tên target
--- "Clear Gravito's Undermen" → "Gravito's Undermen"
local function parseQuestTarget(text)
 local t = text
 for _, act in ipairs(QUEST_ACTIONS) do
  if t:sub(1, #act) == act then t = t:sub(#act + 1) break end
 end
 t = t:gsub("^%s+", ""):gsub("^%d+", ""):gsub("^%s+", "")
 return t
end

-- Lấy tên target TỪ TEXT TIẾN TRÌNH: "0 / 4 bandit" hoặc "0/4 bandit" → "bandit"
-- Đây là nguồn chính xác nhất (QuestName chỉ là tên NPC giao quest, tiến trình mới ghi tên quái cần giết)
local function parseTargetFromProgress(progressText)
 if not progressText or progressText == "" then return nil end
 local t = tostring(progressText):gsub("^%s*%d+%s*/%s*%d+%s*", "")
 t = t:gsub("^%s+", ""):gsub("%s+$", "")
 if t == "" then return nil end
 return t
end

--- Kiểm tra quest hiện tại của người chơi
--- Trả về nil nếu không có quest; ngược lại trả về { Active, Text, Target, Progress, ProgressText }
local function getQuestInfo()
 local pg    = Player and Player:FindFirstChild("PlayerGui")
 local quest = pg    and pg:FindFirstChild("Quest")
 -- Quest GUI tắt/ẩn = không còn quest
 if not quest or (quest and typeof(quest) == "Instance" and quest.Enabled == false) then return nil end
 local main  = quest:FindFirstChild("Main")
 if not main or (main:IsA("GuiObject") and main.Visible == false) then return nil end
 local info  = main  and main:FindFirstChild("Info")
 local top   = info  and info:FindFirstChild("Top")
 if not top then return nil end

 local qName = top:FindFirstChild("QuestName")
 if not qName then return nil end
 local text = tostring(qName.Text or ""):gsub("%s+$", "")
 if text == "" then return nil end

 -- Progress: "0 / 4 Gravito's Undermen" → { current = 0, total = 4 }
 local progress = nil
 local progUI = top:FindFirstChild("Progress")
 if progUI then
  local cur, tot = tostring(progUI.Text):match("(%d+)%s*/%s*(%d+)")
  if cur and tot then progress = { current = tonumber(cur), total = tonumber(tot) } end
 end

 return {
  Active       = true,
  Text         = text,
  Target       = parseTargetFromProgress(progUI and tostring(progUI.Text) or "") or parseQuestTarget(text),
  Progress     = progress,
  ProgressText = progUI and tostring(progUI.Text) or "",
 }
end

--- Lấy tên NPC giao quest đang nhận: ReplicatedStorage.Stats<Player.Name>.Quest.CurrentQuest.Value
--- Trả về nil nếu không đọc được / chưa có quest. Nếu Value là Instance (ObjectValue) thì lấy .Name
local function getCurrentQuestNPC()
 local stats = game:GetService("ReplicatedStorage"):FindFirstChild("Stats" .. (Player and Player.Name or ""))
 local quest = stats and stats:FindFirstChild("Quest")
 local v = quest and quest:FindFirstChild("CurrentQuest")
 if not v or not v:IsA("ValueBase") or v.Value == nil then return nil end
  local val = v.Value
  if typeof(val) == "string" and val ~= "" then return val end
  if typeof(val) == "Instance" then return val.Name end
  return nil
end

--- Chuyển chuỗi CurrentQuest.Value (game lưu TÊN QUEST, vd "Help Daph") thành tên NPC trong QuestDB (vd "Daph")
--- Thứ tự: tra thẳng → bỏ tiền tố "Help " → tra ngược theo db.quest / "Help <tên>". Trả về nil nếu không khớp
local function resolveQuestNPC(raw)
 if not raw then return nil end
 raw = tostring(raw):gsub("^%s+", ""):gsub("%s+$", "")
 if raw == "" then return nil end
 if QuestDB[raw] then return raw end
 local stripped = raw:gsub("^[Hh]elp%s+", "")
 if stripped ~= raw and QuestDB[stripped] then return stripped end
 for name, db in pairs(QuestDB) do
  if db.quest == raw or ("Help " .. name) == raw or ("Help " .. name):lower() == raw:lower() then
   return name
  end
 end
 return nil
end

--- Quét toàn bộ NPC, trả về tối đa maxCount con trùng tên chính xác (gần nhất trước)
local function getNPCsByName(exactName, maxCount)
 local results = {}
 for npc, data in pairs(npcEntries) do
  local alive = data.Humanoid and data.Humanoid.Health > 0
  if alive and npc.Name == exactName then
   local playerPos = getPlayerPosition()
   table.insert(results, {
    Model         = npc,
    HRP           = data.HRP,
    Distance      = playerPos and (data.HRP.Position - playerPos).Magnitude or math.huge,
    Health        = data.Humanoid.Health,
    MaxHealth     = data.Humanoid.MaxHealth,
    Position      = data.HRP.Position,
    IsTargetingMe = false,
   })
  end
 end
 table.sort(results, function(a, b) return (a.Distance or math.huge) < (b.Distance or math.huge) end)
 if maxCount and maxCount > 0 and #results > maxCount then
  for i = #results, maxCount + 1, -1 do table.remove(results, i) end
 end
 return results
end

-- ================== ITEM & WEAPON HELPERS ==================

local function findItem(itemType, name, container)
 local root
 if typeof(container) == "Instance" then
  root = container
 elseif container == "Backpack" then
  root = Player:FindFirstChild("Backpack")
 elseif container == "Character" then
  root = Character or Player.Character
 end
 if not root then return false end

 if name then
  local item = root:FindFirstChild(name)
  if item and item:IsA(itemType) then
return true, item, item:GetAttributes()
  end
  return false
 else
  local results = {}
  for _, item in ipairs(root:GetChildren()) do
   if item:IsA(itemType) then
    table.insert(results, { Item = item, Attributes = item:GetAttributes() })
   end
  end
  return #results > 0, results
 end
end

-- Nhận diện tool fighting style (Combat / Melee / BlackLeg...): trong Animations của
-- nó có ít nhất 1 Animation tên chứa "Punch" → coi là style tool (đánh Melee nhưng CẦM tool)
local function hasPunchAnimation(tool)
 if not tool then return false end
 local found = false
 pcall(function()
  for _, child in ipairs(tool:GetDescendants()) do
   if child:IsA("Animation") and string.find(child.Name, "Punch") then
    found = true
    break
   end
  end
 end)
 return found
end

local function getWeaponTools(container)
 local root
 if typeof(container) == "Instance" then
  root = container
 elseif container == "Backpack" then
  root = Player:FindFirstChild("Backpack")
 elseif container == "Character" then
  root = Character or Player.Character
 end
 if not root then return {} end

local weapons = {}
 for _, item in ipairs(root:GetChildren()) do
  if item:IsA("Tool") and (item:GetAttribute("Category") == "Weapons" or item:FindFirstChild("SwordEquip") or hasPunchAnimation(item)) then
   table.insert(weapons, item)
  end
 end
 return weapons
end

local TypeToStat = {
 Melee      = "Strength",
 Sword      = "SwordMastery",
 DevilFruit = "DevilFruitMastery",
}
local StatToType = {}
for toolType, statName in pairs(TypeToStat) do
 StatToType[statName] = toolType
end

local function getStatPointHighest()
 local p = {
  Stats.Stats.Stamina,
  Stats.Stats.Strength,
  Stats.Stats.SwordMastery,
  Stats.Stats.GunMastery,
  Stats.Stats.DevilFruitMastery,
  Stats.Stats.Defense,
 }
 local highestStat, highestValue = nil, -math.huge
 for _, stat in ipairs(p) do
  if stat then
   local val = tonumber(stat.Value)
   if val and val > highestValue then
    highestValue = val
    highestStat  = stat
   end
  end
 end
 return highestStat, highestValue
end

local function getToolType(tool)
 if tool:GetAttribute("devilFruit") then return "DevilFruit" end
 if tool:FindFirstChild("SwordEquip") then return "Sword" end
 if hasPunchAnimation(tool) then return "Melee" end
 local combat = tool:FindFirstChild("Combat")
 if combat and combat:IsA("BoolValue") then return "Melee" end
 return nil
end

local function chooseBestWeapon(container)
 local weapons = getWeaponTools(container)
 if #weapons == 0 then return nil end

 local toolsByType = {}
 for _, tool in ipairs(weapons) do
  local toolType = getToolType(tool)
  if toolType and not toolsByType[toolType] then
   toolsByType[toolType] = tool
  end
 end

 local highestStat, _ = getStatPointHighest()
 if not highestStat then return nil end

 local preferredType = StatToType[highestStat.Name]
 if preferredType and toolsByType[preferredType] then
  return toolsByType[preferredType], preferredType
 end

 local bestTool, bestType, bestValue = nil, nil, -math.huge
 for toolType, tool in pairs(toolsByType) do
  local statName  = TypeToStat[toolType]
  local statValue = Stats.Stats[statName] and Stats.Stats[statName].Value or -math.huge
  if statValue > bestValue then
   bestValue = statValue
   bestTool  = tool
   bestType  = toolType
  end
 end
 return bestTool, bestType
end

local function equipWeapon(tool)
 if not tool then return false end
 if tool.Parent == Character then return true end
 local humanoid = getHumanoid()
 if not humanoid then return false end
 humanoid:EquipTool(tool)
 return true
end
-- ================== COMBAT ==================

local ToolTypeToCombatType = {
 Melee      = "Melee",
 DevilFruit = "Melee",
 Sword      = "Sword",
}

local function getNearestMonster(maxDistance, preferLowHealth)
    maxDistance = maxDistance or 3500
    local _, monsters = getNPCSnapshot()
    local nearest = nil
    local shortestDist = maxDistance
    local lowestHealthPercent = 1
    local nearestTargetingMe = nil
    local shortestDistTargeting = maxDistance

    for _, data in ipairs(monsters) do
        if data and data.Health and data.Health > 0 then
            -- ƯU TIÊN SỐ 1: Bất kỳ quái nào có Target là người chơi
            if data.IsTargetingMe and data.Distance < shortestDistTargeting then
                shortestDistTargeting = data.Distance
                nearestTargetingMe = data
            end

            if preferLowHealth then
                local pct = data.Health / data.MaxHealth
                if data.Distance < shortestDist and pct < lowestHealthPercent then
                    lowestHealthPercent = pct
                    nearest = data
                end
            else
                if data.Distance < shortestDist then
                    shortestDist = data.Distance
                    nearest = data
                end
            end
        end
    end

    if nearestTargetingMe then
        return nearestTargetingMe
    end

    return nearest
end

-- ==============================================================================
--  AAB ENGINE: SwordInfo + Animation Resolver + M1 Combo Attack
--  Học từ AAB(ATTACK AND BLOCK).lua và AutoAttack_backup.lua
-- ==============================================================================

-- Fetch SwordInfo cooldown từ GitHub (giúp cooldown luôn chính xác theo từng kiếm)
local AAB_SwordInfo = {}
pcall(function()
    local raw = game:HttpGet("https://raw.githubusercontent.com/NguyenTriThuc2010/Info-Game/main/InfoSword.lua")
    if raw and #raw > 0 then
        local loaded = loadstring(raw)()
        if type(loaded) == "table" then AAB_SwordInfo = loaded end
    end
end)

local AAB_Modules     = game:GetService("ReplicatedStorage"):FindFirstChild("Modules")
local AAB_SwordHandle = AAB_Modules and AAB_Modules:FindFirstChild("SwordHandle")
local AAB_SwordsFolder = AAB_SwordHandle and AAB_SwordHandle:FindFirstChild("Swords")
local AAB_CombatRegister = Event and Event:FindFirstChild("CombatRegister")

local AAB_Config = {
    COMBO_SIZE     = 5,
    M1_MODE        = "Ground",
    FAST_ATTACK    = false, -- BẮT BUỘC sync: swingsfx xong mới damage (tránh lúc trúng lúc hụt)
    MELEE_DELAY    = 0.005,  -- x4 tốc độ chém (0.12 gốc)
    DELAY_OFFSET   = 0.0,
    FINISHER_DELAY = 0.5, -- x4 tốc độ chém (1.5 gốc)
    HITBOX_DURATION = 0.14, -- x4 tốc độ chém: anim chạy nhanh gấp bốn (0.55 gốc)
}

-- Khóa 1 đòn tại một thời điểm (chống chồng InvokeServer)
local AAB_attackLock = false
local AAB_attackLockUntil = 0

-- Lấy FightingStyle từ Stats (Dullahan, BlackLeg, Rokushiki...)
local function getFightingStyle()
    local statsFolder = game:GetService("ReplicatedStorage"):FindFirstChild("Stats" .. Player.Name)
    local stats = statsFolder and statsFolder:FindFirstChild("Stats")
    local fs = stats and stats:FindFirstChild("FightingStyle")
    if fs and fs:IsA("StringValue") and fs.Value ~= "" then return fs.Value end
    return "Melee"
end

-- Cooldown chính xác theo SwordInfo, fallback MELEE_DELAY
-- Chia 4 để x4 tốc độ chém
local function getAABCooldown(weaponName, combatType)
    if combatType == "Sword" then
        local info = AAB_SwordInfo[weaponName]
        if info and info.cooldown then return info.cooldown / 4 + AAB_Config.DELAY_OFFSET end
        return 0.075 + AAB_Config.DELAY_OFFSET
    end
    return AAB_Config.MELEE_DELAY + AAB_Config.DELAY_OFFSET
end

-- Lấy thông tin vũ khí: chỉ cần SwordEquip = Kiếm, devilFruit = DevilFruit, còn lại = Võ
local function getAABWeaponInfo()
    local char = LocalPlayer.Character
    if not char then return getFightingStyle(), "Melee", nil end
    local hum = getHumanoid()

    -- Ưu tiên tool đang cầm trên tay
    local tool = char:FindFirstChildWhichIsA("Tool")
    if tool then
        if tool:FindFirstChild("SwordEquip") then
            return tool.Name, "Sword", tool
        elseif tool:GetAttribute("devilFruit") then
            return tool.Name, "DevilFruit", tool
        elseif hasPunchAnimation(tool) then
            return getFightingStyle(), "Melee", tool
        else
            return getFightingStyle(), "Melee", nil
        end
    end

    -- Tìm kiếm trong Backpack: ưu tiên Kiếm (SwordEquip), kế tới style tool (có Punch anim)
    local bp = LocalPlayer:FindFirstChild("Backpack")
    if bp then
        for _, t in ipairs(bp:GetChildren()) do
            if t:IsA("Tool") and t:FindFirstChild("SwordEquip") then
                return t.Name, "Sword", t
            end
        end
        for _, t in ipairs(bp:GetChildren()) do
            if t:IsA("Tool") and hasPunchAnimation(t) then
                return getFightingStyle(), "Melee", t
            end
        end
    end

    return getFightingStyle(), "Melee", nil
end

-- Resolver animation đúng chuẩn theo combo step và Kiếm/Võ
local function resolveAABAnimation(combatType, weaponName, comboIndex, mode)
    local animFolder, animName = nil, nil

    if combatType == "Sword" then
        if AAB_SwordsFolder then
            local swordDir = AAB_SwordsFolder:FindFirstChild(weaponName)
            if swordDir and swordDir:FindFirstChild("Slashes") then
                animFolder = swordDir.Slashes
            end
        end
        if comboIndex == 1 then animName = "Dash"
        elseif comboIndex <= 3 then animName = "Slash" .. comboIndex
        else animName = (mode == "Air" and "AirSlash" or "GroundSlash") .. comboIndex end
    else
        local style = getFightingStyle()
        if CombatAnimations then
            animFolder = CombatAnimations:FindFirstChild(weaponName)
                or CombatAnimations:FindFirstChild(style)
                or CombatAnimations:FindFirstChild("Melee")
        end
        if comboIndex == 1 then animName = "Dash"
        elseif comboIndex <= 3 then animName = "Punch" .. comboIndex
        else animName = (mode == "Air" and "AirPunch" or "GroundPunch") .. comboIndex end
    end

    local animObj = nil
    if animFolder and animName then
        animObj = animFolder:FindFirstChild(animName)
        if not animObj then
            animObj = animFolder:FindFirstChild("Dash")
                or animFolder:FindFirstChild(combatType == "Sword" and "Slash1" or "Punch1")
                or animFolder:GetChildren()[1]
        end
    end
    return animObj, animName
end

-- Tracking combo state cho callAttack
local AAB_comboStep = 0
local AAB_lastComboTime = 0
local AAB_COMBO_RESET_TIME = 2.0 -- reset combo nếu nghỉ quá 2s
-- Cờ tư thế: main loop (killMonster) đặt mỗi frame, callAttack dùng chung
-- → tránh lật pose qua lại giữa "kéo" và "chém" cùng 1 frame
local AAB_hoverDive = nil

-- ================== FACE LOOK MODE ==================
-- true  = chế độ "nằm ngang": xoay thân/đầu hướng thẳng về target (lên/xuống/ngang theo 3D)
-- false = Bình thường: chỉ xoay ngang như cũ (level)
local FaceLook = {
 active       = false,
 targetGetter = nil,   -- function() return Vector3 end — lấy vị trí target mỗi frame
}

local function setFaceMode(active, targetGetter)
 FaceLook.active = active
 FaceLook.targetGetter = active and targetGetter or nil
end

-- Xoay nhân vật nhìn về target qua BodyGyro only (không ghi hrp.CFrame — anti-cheat)
-- tiltMode = "dive": body nằm ngang úp mặt xuống target — CHỈ đổi gyro,
-- lookCF trả về vẫn là bản thẳng (giữ damageArgs[6] như cũ cho server)
local function faceTowardPosition(hrp, targetPos, gyro, tiltMode)
    if not (hrp and targetPos) then return hrp and hrp.CFrame or CFrame.new() end

    -- +90° quanh trục phải: đầu (local +Y) xoay về hướng nhìn (+Z) → nằm ngang úp mặt
    local diveTilt = (tiltMode == "dive") and CFrame.Angles(math.pi / 2, 0, 0) or nil

    -- FaceLook override: hướng mặt thẳng vào target (nghiêng lên/xuống theo 3D)
    if FaceLook.active and FaceLook.targetGetter then
        local t = FaceLook.targetGetter()
        if t then
            local lookCF = CFrame.lookAt(hrp.Position, t)
            local setCF = diveTilt and (lookCF * diveTilt) or lookCF
            if gyro and gyro.Parent then
                gyro.CFrame = setCF
            elseif FlyPathfinder and FlyPathfinder.currentGyro and FlyPathfinder.currentGyro.Parent then
                FlyPathfinder.currentGyro.CFrame = setCF
            elseif Fly and Fly.flyGyro and Fly.flyGyro.Parent then
                Fly.flyGyro.CFrame = setCF
            end
            return lookCF
        end
    end

    local flat = Vector3.new(targetPos.X, hrp.Position.Y, targetPos.Z)
    local lookAt = ((flat - hrp.Position).Magnitude > 0.15) and flat or targetPos
    local lookCF = CFrame.lookAt(hrp.Position, lookAt)
    local setCF = diveTilt and (lookCF * diveTilt) or lookCF
    if gyro and gyro.Parent then
        gyro.CFrame = setCF
    elseif FlyPathfinder and FlyPathfinder.currentGyro and FlyPathfinder.currentGyro.Parent then
        FlyPathfinder.currentGyro.CFrame = setCF
    elseif Fly and Fly.flyGyro and Fly.flyGyro.Parent then
        Fly.flyGyro.CFrame = setCF
    end
    -- Không gán hrp.CFrame (kể cả xoay) — anti-cheat
    return lookCF
end

-- Xoay theo hướng bay / di chuyển
local function faceMoveDirection(hrp, moveDir, gyro)
    if not (hrp and moveDir and moveDir.Magnitude > 0.05) then return end
    local flat = Vector3.new(moveDir.X, 0, moveDir.Z)
    if flat.Magnitude < 0.05 then
        flat = moveDir
    end
    faceTowardPosition(hrp, hrp.Position + flat.Unit * 5, gyro)
end

-- Đảm bảo target muốn đánh VẪN CÒN SỐNG + còn trong world
-- Trả về: alive, humanoid, hrp (đã refresh vào target)
local function isCombatTargetAlive(target)
    if not target then return false, nil, nil end
    local model = target.Model
    if typeof(target) == "Instance" and target:IsA("Model") then
        model = target
    end
    if not model or not model.Parent then
        return false, nil, nil
    end

    local hum = model:FindFirstChildOfClass("Humanoid")
    if not hum or not hum.Parent then
        return false, nil, nil
    end
    if hum.Health <= 0 then
        return false, hum, nil
    end
    local stateOk, state = pcall(function() return hum:GetState() end)
    if stateOk and state == Enum.HumanoidStateType.Dead then
        return false, hum, nil
    end

    local hrp = model:FindFirstChild("HumanoidRootPart") or target.HRP
    if not hrp or not hrp.Parent then
        return false, hum, nil
    end

    -- Refresh snapshot
    if type(target) == "table" then
        target.Model = model
        target.HRP = hrp
        target.Health = hum.Health
        target.MaxHealth = hum.MaxHealth
        target.Position = hrp.Position
    end
    return true, hum, hrp
end

-- Part có phải "tường ảo" game thiết kế cho đi xuyên qua không?
-- Nguồn sự thật duy nhất cho cả 3 hệ thống (combat / fly / navfly)
local function isPassThroughPart(part, targetModel)
    if not part or not part:IsA("BasePart") then return false end
    if not part.CanCollide then return true end
    if part.Material == Enum.Material.ForceField and part.Transparency >= 0.98 then return true end
    if targetModel and part:IsDescendantOf(targetModel) then return true end
    local char = LocalPlayer.Character
    if char and part:IsDescendantOf(char) then return true end
    local effects = workspace:FindFirstChild("Effects")
    if effects and part:IsDescendantOf(effects) then return true end
    local npcs = workspace:FindFirstChild("NPCs")
    if npcs and part:IsDescendantOf(npcs) then return true end
    return false
end

-- Part có phải tường/vật cản cứng không (bỏ qua loot, effect, nhân vật, NPC)
local function isBlockingWallPart(part, targetModel)
    if not part or not part:IsA("BasePart") then return false end
    if isPassThroughPart(part, targetModel) then return false end
    if part.Transparency >= 0.95 then return false end
    return true
end

-- ================== VISUAL DEBUG (Drawing 2D) ==================
local VisualDebug = {
    active = false,
    rays   = {}, -- { from=Vector3, to=Vector3, color=Color3 }
    conn   = nil,
    lines  = {}, -- pool Drawing.Line
    dots   = {}, -- pool Drawing.Circle
}

local DEBUG_RAY_COLORS = {
    clear   = Color3.fromRGB(80, 220, 120), -- xanh: thông / tường ảo đi qua được
    blocked = Color3.fromRGB(255, 90, 90),  -- đỏ: tường thật chặn
    steer   = Color3.fromRGB(255, 200, 60), -- vàng: hướng né đang bay
}

-- Ghi 1 ray vào cache (chỉ khi toggle bật; đầy 16 thì ghi đè cũ nhất)
local function debugRecordRay(fromPos, toPos, color)
    if not VisualDebug.active then return end
    if not (fromPos and toPos) then return end
    local rays = VisualDebug.rays
    if #rays >= 16 then table.remove(rays, 1) end
    table.insert(rays, { from = fromPos, to = toPos, color = color })
end

-- Bật/tắt Visual Debug (gọi từ toggle UI)
local function debugSetEnabled(on)
    if on and not Drawing then
        notify("Executor không hỗ trợ Drawing API — không thể bật Visual Debug", 4)
        return false
    end
    VisualDebug.active = on
    if on then
        if not VisualDebug.conn then
            VisualDebug.conn = RunService.RenderStepped:Connect(function()
                local cam = workspace.CurrentCamera
                if not cam then return end
                local lines, dots = VisualDebug.lines, VisualDebug.dots
                for _, l in ipairs(lines) do l.Visible = false end
                for _, d in ipairs(dots) do d.Visible = false end
                local li, di = 1, 1
                for _, ray in ipairs(VisualDebug.rays) do
                    local okA, vA = pcall(function() return cam:WorldToViewportPoint(ray.from) end)
                    local okB, vB = pcall(function() return cam:WorldToViewportPoint(ray.to) end)
                    if okA and okB and vA.Z > 0 and vB.Z > 0 then
                        local line = lines[li]
                        if not line then
                            line = Drawing.new("Line")
                            line.Thickness = 2
                            line.Transparency = 0.5
                            table.insert(lines, line)
                        end
                        line.From = Vector2.new(vA.X, vA.Y)
                        line.To   = Vector2.new(vB.X, vB.Y)
                        line.Color = ray.color
                        line.Visible = true
                        li = li + 1

                        local dot = dots[di]
                        if not dot then
                            dot = Drawing.new("Circle")
                            dot.Thickness = 3
                            dot.Radius = 4
                            dot.Filled = false
                            dot.Transparency = 0.5
                            table.insert(dots, dot)
                        end
                        dot.Position = Vector2.new(vB.X, vB.Y)
                        dot.Color = ray.color
                        dot.Visible = true
                        di = di + 1
                    end
                end
                VisualDebug.rays = {}
            end)
        end
    else
        if VisualDebug.conn then
            VisualDebug.conn:Disconnect()
            VisualDebug.conn = nil
        end
        VisualDebug.rays = {}
    end
    return true
end

-- Tường lớn / dày / cao: ngăn 2 không gian
local function isLargeThickWall(part, measuredThickness)
    if not part then return false end
    local sz = part.Size
    local maxAxis = math.max(sz.X, sz.Y, sz.Z)
    local minAxis = math.min(sz.X, sz.Y, sz.Z)
    if measuredThickness and measuredThickness >= 2.5 then
        return true
    end
    -- Cao + dày, hoặc khối rất lớn
    if sz.Y >= 10 and minAxis >= 2.5 then return true end
    if sz.Y >= 8 and math.max(sz.X, sz.Z) >= 6 and minAxis >= 2 then return true end
    if maxAxis >= 24 then return true end
    return false
end

-- true = bị tường lớn chắn (KHÁC không gian) → nên bỏ qua target
local function isSeparatedByThickWall(fromPos, toPos, targetModel, skipDraw)
    if not (fromPos and toPos) then return true end
    local diff = toPos - fromPos
    local dist = diff.Magnitude
    if dist <= 1.5 then return false end

    local rp = RaycastParams.new()
    rp.FilterType = Enum.RaycastFilterType.Exclude
    local excludes = {}
    local char = LocalPlayer.Character
    if char then table.insert(excludes, char) end
    if targetModel then table.insert(excludes, targetModel) end
    local effects = workspace:FindFirstChild("Effects")
    if effects then table.insert(excludes, effects) end
    rp.FilterDescendantsInstances = excludes
    rp.IgnoreWater = true

    local blockedRays = 0
    local thickHit = false
    local heightOffsets = { 0.5, 2.5, 5.0 } -- thấp / ngực / đầu — tường cao chắn nhiều tia

    for _, yOff in ipairs(heightOffsets) do
        local origin = fromPos + Vector3.new(0, yOff, 0)
        local goal = toPos + Vector3.new(0, yOff, 0)
        local dir = goal - origin
        if dir.Magnitude < 0.5 then
            -- ok
        else
            local hit = workspace:Raycast(origin, dir, rp)
            local wallHit = hit and isBlockingWallPart(hit.Instance, targetModel)
            if not skipDraw then
                debugRecordRay(origin, goal, wallHit and DEBUG_RAY_COLORS.blocked or DEBUG_RAY_COLORS.clear)
            end
            if wallHit then
                blockedRays = blockedRays + 1

                -- Đo bề dày: ray ngược từ phía target
                local backHit = workspace:Raycast(goal, origin - goal, rp)
                local thickness = nil
                if backHit and backHit.Instance == hit.Instance then
                    thickness = (hit.Position - backHit.Position).Magnitude
                elseif backHit and isBlockingWallPart(backHit.Instance, targetModel) then
                    -- Hai phía đều đụng tường cứng khác nhau → ngăn cách không gian
                    thickHit = true
                end

                if isLargeThickWall(hit.Instance, thickness) then
                    thickHit = true
                end
            end
        end
    end

    -- Tường dày/lớn rõ ràng, hoặc ≥2/3 tia bị chắn
    if thickHit then return true end
    if blockedRays >= 2 then return true end
    return false
end

-- ================== BAY VƯỢT TƯỜNG THEO TIA NGANG ĐẦU ==================
-- Muốn bay tới target mà bị tường chắn: nếu tia NGANG ĐẦU (offset 5.0) THÔNG nhưng
-- 2 tia thấp (0.5 / 2.5) bị chặn → tường KHÔNG quá cao → chỉ cần bay lên tới đỉnh tường
-- + margin là 2 tia còn lại cũng khớp thông → trả về độ cao cần bay (thay vì vọt 500 studs).
-- Trả nil nếu: không bị chặn đủ 2 tia / cả 3 tia chặn (tường quá cao) / tường dày lớn (khác không gian)
local FLY_OVER_WALL_MARGIN = 2.5
local function getWallClimbFlyY(fromPos, toPos)
 if not (fromPos and toPos) then return nil end
 local diff = toPos - fromPos
 if diff.Magnitude <= 1.5 then return nil end

 local rp = RaycastParams.new()
 rp.FilterType = Enum.RaycastFilterType.Exclude
 rp.IgnoreWater = true
 local excludes = { Character }
 local effects = workspace:FindFirstChild("Effects")
 if effects then table.insert(excludes, effects) end
 rp.FilterDescendantsInstances = excludes

 local blockedRays = 0
 local topClear = false
 local maxWallTop = nil
 for i, yOff in ipairs({ 0.5, 2.5, 5.0 }) do
  local origin = fromPos + Vector3.new(0, yOff, 0)
  local goal = toPos + Vector3.new(0, yOff, 0)
  local dir = goal - origin
  if dir.Magnitude < 0.5 then
   if i == 3 then topClear = true end
  else
   local hit = workspace:Raycast(origin, dir, rp)
   local wallHit = hit and isBlockingWallPart(hit.Instance)
   if i == 3 then
    topClear = not wallHit
   end
   if wallHit then
    blockedRays = blockedRays + 1
    -- Tường dày/lớn = khác không gian → không bay vượt được
    if isLargeThickWall(hit.Instance) then return nil end
    local topY = getWallTopYFromHit(hit, rp)
    if topY and (maxWallTop == nil or topY > maxWallTop) then maxWallTop = topY end
   end
  end
 end
 -- Cần ≥2 tia chặn + tia đầu thông + đo được đỉnh → bay lên đỉnh tường + margin
 if not (blockedRays >= 2 and topClear and maxWallTop) then return nil end
 return maxWallTop + FLY_OVER_WALL_MARGIN
end

-- Cùng không gian chiến đấu với target? (không bị tường lớn chắn)
-- Khi đã sát target (< 8 studs): bỏ qua check tường — tránh false-positive trần/sàn khi hover
local function isSameCombatSpace(target)
    local alive, _, targetHRP = isCombatTargetAlive(target)
    if not alive or not targetHRP then return false end
    local myHRP = getHumanoidRootPart()
    if not myHRP then return false end

    local dist = (myHRP.Position - targetHRP.Position).Magnitude
    if dist <= (ATTACK_RANGE + 1) then
        return true
    end

    local model = target.Model
    if isSeparatedByThickWall(myHRP.Position, targetHRP.Position, model) then
        return false
    end
    return true
end

-- ================== SKY BRIDGE (CẦU TRỜI QUA TƯỜNG) ==================
-- Kiểm tra có vượt được tường lớn / sang không gian khác bằng đường trên cao không.
-- 3 tia:
--   1. Tia LÊN từ HRP target: dóng TỚI KHI CHẠM TRẦN, đo headroom thật (tối đa 15)
--      → topY = targetPos.Y + headroom đo được (MỨC VƯỢT theo tia của TARGET)
--   2. Tia LÊN từ player: dóng THÊM tới khi bằng topY — chạm trần trước khi đủ → fail
--   3. Tia NGANG nối 2 điểm ở độ cao topY: không được chạm tường
-- Cả 3 thông → trả về topY; ngược lại → nil (không qua được)
local SKY_BRIDGE_CLEARANCE = 15
local function getSkyBridgeOverWall(fromPos, toPos)
    if not (fromPos and toPos) then return nil end
    local rp = RaycastParams.new()
    rp.FilterType = Enum.RaycastFilterType.Exclude
    rp.IgnoreWater = true
    local excludes = { Character }
    local effects = workspace:FindFirstChild("Effects")
    if effects then table.insert(excludes, effects) end
    rp.FilterDescendantsInstances = excludes

    -- 1. Tia LÊN từ target: dóng cho tới khi chạm trần, đo headroom THẬT (tối đa 15).
    --    Mức vượt topY = targetPos.Y + headroom đo được — KHÔNG cố định 15 studs
    local headroom
    local targetUpHit = workspace:Raycast(toPos, Vector3.new(0, SKY_BRIDGE_CLEARANCE, 0), rp)
    if not targetUpHit then
        headroom = SKY_BRIDGE_CLEARANCE
    elseif isBlockingWallPart(targetUpHit.Instance) then
        headroom = math.max(0, targetUpHit.Position.Y - toPos.Y)
    else
        headroom = SKY_BRIDGE_CLEARANCE -- phần ảo (pass-through) không tính là trần
    end
    if headroom < 1 then return nil end -- target bị trần sát đầu → không vượt được
    local topY = toPos.Y + headroom
    debugRecordRay(toPos, toPos + Vector3.new(0, headroom, 0), DEBUG_RAY_COLORS.steer)

    -- 2. Tia LÊN từ player: dóng THÊM cho tới khi bằng mức của target.
    --    cần leo = topY - fromPos.Y; chạm trần thật trước khi đủ → không qua được
    local requiredClimb = topY - fromPos.Y
    if requiredClimb > 1 then
        local climbHit = workspace:Raycast(fromPos, Vector3.new(0, requiredClimb + 1, 0), rp)
        if climbHit and isBlockingWallPart(climbHit.Instance) and climbHit.Position.Y < topY - 1 then
            return nil
        end
        debugRecordRay(fromPos, fromPos + Vector3.new(0, requiredClimb, 0), DEBUG_RAY_COLORS.steer)
    end

    -- 3. Tia ngang nối 2 điểm trên cao
    local topFrom = Vector3.new(fromPos.X, topY, fromPos.Z)
    local sideHit = workspace:Raycast(topFrom, toPos - topFrom, rp)
    if sideHit and isBlockingWallPart(sideHit.Instance) then
        return nil
    end
    debugRecordRay(topFrom, toPos, DEBUG_RAY_COLORS.steer)

    return topY
end

-- Khoảng cách combat: lấy MAX(hrp, realPos) — server dùng vị trí thật, HRP có thể bay trước
local function getCombatDistanceTo(targetPos)
    local hrp = getHumanoidRootPart()
    if not (hrp and targetPos) then return math.huge, math.huge, math.huge end
    local visual = (hrp.Position - targetPos).Magnitude
    local serverP = getPlayerPosition() or hrp.Position
    local server = (serverP - targetPos).Magnitude
    return math.max(visual, server), visual, server
end

-- Multi Attack: 1 vung chém trúng nhiều quái đứng gần nhau
local MultiAttack = {
    enabled    = true,
    maxTargets = 4,
    range      = ATTACK_RANGE, -- bán kính tính từ quái chính
}

-- Gom quái khác gần quái chính + gần player, còn sống, không bị tường chắn
-- Trả về list HRP phụ (không gồm quái chính)
local function getNearbyAttackTargets(monster, primaryHRP)
    if not MultiAttack.enabled or not primaryHRP then return {} end
    local myHRP = getHumanoidRootPart()
    if not myHRP then return {} end
    local list = {}
    local primaryModel = monster and monster.Model
    for npc, data in pairs(npcEntries) do
        if npc ~= primaryModel and data.Humanoid.Health > 0 then
            local hrp = data.HRP
            if hrp and hrp.Parent then
                local dTarget = (hrp.Position - primaryHRP.Position).Magnitude
                local dPlayer = (hrp.Position - myHRP.Position).Magnitude
                if dTarget <= MultiAttack.range and dPlayer <= ATTACK_RANGE_SOFT + 0.5 then
                    table.insert(list, hrp)
                    if #list >= MultiAttack.maxTargets then break end
                end
            end
        end
    end
    return list
end

-- forcedTarget: snapshot quái đang farm (tránh callAttack nhầm quái khác / miss)
-- Trả về true nếu đã gửi đòn thành công
local function callAttack(forcedTarget)
    -- Mutex: tránh 2 đòn chồng (swingsfx/damage lệch → lúc có lúc không)
    local nowLock = tick()
    if AAB_attackLock or nowLock < AAB_attackLockUntil then
        return false
    end
    AAB_attackLock = true

    local function unlock()
        AAB_attackLock = false
    end

    local okAttack, result = pcall(function()
        local monster = forcedTarget
        if not monster then
            monster = getNearestMonster(ATTACK_RANGE + 8)
        end
        if not monster then return false end

        local alive, targetHum, targetHRP = isCombatTargetAlive(monster)
        if not alive or not targetHRP then
            return false
        end

        if not isSameCombatSpace(monster) then
            return false
        end

        local hrp = getHumanoidRootPart()
        local hum = getHumanoid()
        if not (hrp and hum and isPlayerAlive()) then return false end

        -- Ép mặt qua BodyGyro only (không CFrame — anti-cheat)
        faceTowardPosition(hrp, targetHRP.Position, FlyPathfinder and FlyPathfinder.currentGyro, AAB_hoverDive)

        local combatDist, visualDist, serverDist = getCombatDistanceTo(targetHRP.Position)
        -- Server từ chối ngoài ~7 studs; chỉ đánh khi visual + realPos đều trong tầm an toàn
        if visualDist > ATTACK_RANGE_SOFT or serverDist > ATTACK_RANGE_SOFT then
            return false
        end

        alive = isCombatTargetAlive(monster)
        if not alive then return false end

        local now = tick()
        if now - AAB_lastComboTime > AAB_COMBO_RESET_TIME then
            AAB_comboStep = 0
        end
        AAB_comboStep = (AAB_comboStep % AAB_Config.COMBO_SIZE) + 1
        AAB_lastComboTime = now

        local weaponName, combatType, tool = getAABWeaponInfo()
        -- DevilFruit không phải whitelist damage → fallback Melee/FightingStyle
        if combatType == "DevilFruit" then
            combatType = "Melee"
            weaponName = getFightingStyle()
            tool = nil
            if hum then pcall(function() hum:UnequipTools() end) end
        end

        if tool then
            local needEquip = tool.Parent ~= (Character or LocalPlayer.Character)
            equipWeapon(tool)
            if needEquip then
                -- Chờ tool lên tay trước khi swingsfx (tránh Weapon error / miss)
                local deadline = tick() + 0.35
                while tick() < deadline do
                    local char = Character or LocalPlayer.Character
                    if char and tool.Parent == char then break end
                    task.wait(0.03)
                end
            end
        elseif combatType == "Melee" then
            local held = Character and Character:FindFirstChildWhichIsA("Tool")
            if held and held:FindFirstChild("SwordEquip") then hum:UnequipTools() end
        end

        -- Refresh HRP sau equip (tránh stale)
        alive, targetHum, targetHRP = isCombatTargetAlive(monster)
        if not alive or not targetHRP then return false end
        hrp = getHumanoidRootPart()
        if not hrp then return false end
        faceTowardPosition(hrp, targetHRP.Position, FlyPathfinder and FlyPathfinder.currentGyro, AAB_hoverDive)

        local mode = (AAB_comboStep >= 4) and AAB_Config.M1_MODE or "Ground"
        local hum2 = getHumanoid()
        -- PlatformStand/fly → MoveDirection thường = 0; đòn 1 không dash cho ổn định
        local isDashing = false

        local animObj, animName = resolveAABAnimation(combatType, weaponName, AAB_comboStep, mode)
        local animSpeed = 1.6666666269302368
        if animObj and animObj:IsA("Animation") then
            pcall(function()
                local track = hum:LoadAnimation(animObj)
                local len = track.Length > 0 and track.Length or 1.0
                animSpeed = len / AAB_Config.HITBOX_DURATION
                track:Play(0.05, 1.5, animSpeed)
            end)
        end

        pcall(function()
            if _G.PlayEffect then
                _G.PlayEffect("CustomSwing", nil, {
                    Character or LocalPlayer.Character,
                    AAB_comboStep,
                    weaponName,
                    mode,
                    isDashing,
                })
            end
        end)

        local sfxType = combatType == "Sword" and "Sword" or "Melee"
        local swingArgs = {
            "swingsfx", sfxType, AAB_comboStep, mode, isDashing, animObj, animSpeed, 1.5
        }

        local damageWeapon = combatType == "Sword" and "Sword" or weaponName
        local damageTargets = getNearbyAttackTargets(monster, targetHRP)
        table.insert(damageTargets, 1, targetHRP)
        local damageArgs = {
            "damage",
            damageTargets,
            damageWeapon,
            { AAB_comboStep, mode, damageWeapon },
            true,
            lookCF,
            aircombo = mode,
        }

        if not AAB_CombatRegister or not AAB_CombatRegister.Parent then
            AAB_CombatRegister = Event and Event:FindFirstChild("CombatRegister")
        end
        if not AAB_CombatRegister then
            warn("[callAttack] Không tìm thấy CombatRegister — bỏ đòn")
            return false
        end

        if not isCombatTargetAlive(monster) then
            return false
        end

        -- SYNC bắt buộc: swingsfx TRƯỚC → damage SAU (docs: không có swingsfx = server từ chối)
        local swingOk = pcall(function() AAB_CombatRegister:InvokeServer(swingArgs) end)
        if not swingOk then
            task.wait(0.05)
            swingOk = pcall(function() AAB_CombatRegister:InvokeServer(swingArgs) end)
        end

        if not isCombatTargetAlive(monster) then
            return swingOk
        end

        -- Re-face ngay trước damage
        hrp = getHumanoidRootPart()
        alive, _, targetHRP = isCombatTargetAlive(monster)
        if hrp and targetHRP then
            lookCF = faceTowardPosition(hrp, targetHRP.Position, FlyPathfinder and FlyPathfinder.currentGyro, AAB_hoverDive)
            -- Refresh multi-target list (lọc con đã chết trong khoảng thời gian chờ swingsfx)
            local freshTargets = getNearbyAttackTargets(monster, targetHRP)
            table.insert(freshTargets, 1, targetHRP)
            damageArgs[2] = freshTargets
            damageArgs[6] = lookCF
        end

        local dmgOk = pcall(function() AAB_CombatRegister:InvokeServer(damageArgs) end)
        if not dmgOk then
            task.wait(0.05)
            if isCombatTargetAlive(monster) then
                pcall(function() AAB_CombatRegister:InvokeServer(swingArgs) end)
                pcall(function() AAB_CombatRegister:InvokeServer(damageArgs) end)
            end
        end

        local dynDelay = getAABCooldown(weaponName, combatType)
        if AAB_comboStep == AAB_Config.COMBO_SIZE then
            task.wait(AAB_Config.FINISHER_DELAY)
        else
            task.wait(math.max(dynDelay, AAB_Config.MELEE_DELAY))
        end
        return true
    end)

    unlock()
    AAB_attackLockUntil = tick() + 0.02
    if not okAttack then
        warn("[callAttack] lỗi: " .. tostring(result))
        return false
    end
    return result and true or false
end

-- ================== ISLAND NAVIGATION ==================

--- Lay danh sach tat ca dao trong workspace.Islands
--- Tra ve: { ["TenDao"] = Vector3Position, ... }
local function getIslandList()
 local list = {}
 for _, island in ipairs(Islands:GetChildren()) do
  local pos = getPositionOf(island)
  if pos then
   list[island.Name] = pos
  end
 end
 return list
end

--- Lay vi tri cua 1 dao cu the theo ten
--- Tra ve Vector3 hoac nil neu khong tim thay
local function getIslandPosition(islandName)
 local island = Islands:FindFirstChild(islandName)
 if not island then return nil end
 return getPositionOf(island)
end
--- Lay danh sach ten dao (sorted A-Z) de dung trong dropdown
local function getIslandNamesSorted()
 local names = {}
 for _, island in ipairs(Islands:GetChildren()) do
  if getPositionOf(island) then
   table.insert(names, island.Name)
  end
 end
 table.sort(names)
 return names
end

-- State cho Island Fly
local IslandFly = {
 selectedIsland = nil,   -- ten dao dang chon
 active         = false, -- dang bay toi dao hay khong
}

--- Bat dau bay toi dao da chon
local function flyToSelectedIsland()
 if not IslandFly.selectedIsland then
  notify("Chua chon dao!", 3)
  return
 end

 local targetName = IslandFly.selectedIsland

 -- targetGetter: goi moi frame de lay vi tri moi nhat (dao co the la moving island)
 local function targetGetter()
  return getIslandPosition(targetName)
 end

 local function onArrive()
  notify("Da den dao: " .. targetName, 4)
  IslandFly.active = false
  -- Tu dong tat toggle neu co
  if Options.IslandFly then
   Options.IslandFly:SetValue(false)
  end
 end

 startAutoFly(targetGetter, onArrive, 20)
end

--- Dung bay toi dao
local function stopIslandFly()
 IslandFly.active = false
 stopFly()
end

-- ================== FLY: PHYSICS OBJECTS ==================

stopFly = function()
 -- Dừng FlyPathfinder nếu đang chiếm quyền bay (tránh 2 engine cùng lúc)
 if FlyPathfinder and FlyPathfinder.isNavigating then
  FlyPathfinder.isNavigating = false
  FlyPathfinder.ownerToken = (FlyPathfinder.ownerToken or 0) + 1
  pcall(function() FlyPathfinder.CleanupPhysics() end)
 end
 if Fly.flyBV then
  Fly.flyBV:Destroy()
  Fly.flyBV = nil
 end
 if Fly.flyGyro then
  Fly.flyGyro:Destroy()
  Fly.flyGyro = nil
 end
 if Fly.flyConnection then
  Fly.flyConnection:Disconnect()
  Fly.flyConnection = nil
 end
 Status.Fly    = false
 Fly.flyTarget = nil
 -- Reset watchdog state
 Fly.desiredY   = nil
 Fly.lastPos    = nil
 Fly.stuckTimer = 0

 local humanoid = getHumanoid()
 if humanoid then
  humanoid.PlatformStand = false
 end
end

-- ================== BIỂN / ĐẤT DƯỚI CHÂN (dùng cho MỌI kiểu bay) ==================
-- Định nghĩa TRƯỚC fly engine: fly loop có thể chạy NGAY khi script mới load được 1 phần
-- (toggle Fly bật sớm) → KHÔNG được phụ thuộc QuestAPI (khởi tạo muộn hơn trong file)
--- Nhận diện 1 Part có phải NƯỚC/BIỂN không (IsWater / Material Water / tên chứa water|ocean|sea|wave)
local function isWaterPart(part)
 if not part or not part:IsA("BasePart") then return false end
 if part:IsA("Water") or part.Material == Enum.Material.Water then return true end
 local n = (part.Name .. " " .. tostring(part.Parent and part.Parent.Name or "")):lower()
 return n:find("water", 1, true) or n:find("ocean", 1, true)
  or n:find("sea", 1, true) or n:find("wave", 1, true)
end

-- ================== SEA CONFIG: phân biệt Sea 1 / Sea 2 theo Place ID ==================
-- Executor chạy trong game → game.PlaceId cho biết đang ở biển nào
local SEA_CONFIGS = {
 [3978370137] = { label = "Sea 1", surfaceY = -2.7 }, -- Sea 1 (user xác nhận)
 -- [<id Sea 2>] = { label = "Sea 2", surfaceY = <chờ cung cấp> }, -- user sẽ gửi sau
}
local seaConfigCache = nil
local function getSeaConfig()
 if not seaConfigCache then
  local cfg = SEA_CONFIGS[game.PlaceId]
  if not cfg then cfg = { label = "Unknown", surfaceY = -2.7 } end -- fallback mặc định như Sea 1
  seaConfigCache = cfg
  print(string.format("[Sea] PlaceId=%d → %s (mặt nước y=%.1f)", game.PlaceId, cfg.label, cfg.surfaceY))
 end
 return seaConfigCache
end

--- Y mặt biển của biển đang chơi (Sea 1 = -2.7)
local seaSurfaceY = function()
 return getSeaConfig().surfaceY
end

--- TẤM ĐẾ BIỂN 3x3 (vô hình, rắn): luôn bám theo player ở đúng cao độ mặt biển — "chuẩn vật lý"
--- để phân biệt đang trên BIỂN hay trên một bề mặt khác
local SeaProbe = nil
local function getSeaProbe()
 if not SeaProbe or not SeaProbe.Parent then
  SeaProbe = Instance.new("Part")
  SeaProbe.Name = "SeaProbe"
  SeaProbe.Size = Vector3.new(3, 0.2, 3)
  SeaProbe.Anchored = true
  SeaProbe.CanCollide = true -- raycast mặc định (RespectCanCollide=true) bắt được như vật rắn
  SeaProbe.CanTouch = false
  SeaProbe.CastShadow = false
  SeaProbe.Transparency = 1
  SeaProbe.Material = Enum.Material.Water
  SeaProbe.Parent = workspace
 end
 return SeaProbe
end

--- Xác định bề mặt dưới pos bằng tấm đế biển:
---  - ray xuống đúng tới mặt biển (y = seaSurfaceY()):
---     * trúng SeaProbe đầu tiên → đang đứng trên MẶT BIỂN → (surfaceY, true)
---     * trúng vật RẮN khác trước đế (vật cản: đảo/lòng đất/thuyền/cầu...) → (Y vật đó, false)
---       vật thuộc tổ tiên "Ocean" (sóng/tàu của biển) vẫn tính BIỂN → (Y đó, true)
---     * không trúng gì → nil
---  - pos.Y <= mặt nước (ngập nước) → (surfaceY, true)
---  - RespectCanCollide mặc định TRUE: ray KHÔNG xuyên vật rắn (không xuyên lòng đất)
local groundOrSeaBelow = function(pos, depth)
 pos = pos or getPlayerPosition()
 if not pos then return nil end
 local surfaceY = seaSurfaceY()
 if pos.Y <= surfaceY + 0.5 then return surfaceY, true end -- ngập/ở mức mặt nước
 local probe = getSeaProbe()
 probe.Position = Vector3.new(pos.X, surfaceY, pos.Z)
 local rp = RaycastParams.new()
 rp.FilterType = Enum.RaycastFilterType.Exclude
 rp.FilterDescendantsInstances = { Character }
 local hit = workspace:Raycast(pos, Vector3.new(0, -(pos.Y - surfaceY), 0), rp)
 if not hit then return nil end
 if hit.Instance == probe then return surfaceY, true end -- đầu tiên là đế → đang trên biển
 local p = hit.Instance
 while p do
  if p.Name == "Ocean" then return surfaceY, true end -- sóng/tàu thuộc biển: dùng MẶT BIỂN cố định, không phải đỉnh sóng
  p = p.Parent
 end
 return hit.Position.Y, false -- vật cản/bề mặt khác → đang đứng trên mặt đất
end

--- Kiểm tra bên dưới chân (raycast xuống 15 studs) là ĐẤT (false) hay BIỂN/NƯỚC (true).
--- Trả nil nếu không xác định được. Bắt đầu ray 4 studs dưới HRP tránh trúng thân mình
local waterBelow15 = function(feetPos)
 feetPos = feetPos or getPlayerPosition()
 if not feetPos then return nil end
local start = feetPos - Vector3.new(0, 4, 0)
  for i = 1, 3 do
   local raycraft = start - Vector3.new(0, (i - 1) * 5, 0)
   local rp = RaycastParams.new()
   rp.RespectCanCollide = false -- nước CanCollide=false vẫn đếm là nước
   local hit = workspace:Raycast(raycraft, Vector3.new(0, -15, 0), rp)
  local part = hit and hit.Instance or nil
  if part and part:IsA("BasePart") then
   local model = part:FindFirstAncestorOfClass("Model")
   if model then
    local parent = model.Parent
    -- Trúng nhân vật/đồ của mình → bỏ qua, thử ray dịch xuống dưới
    if parent and (parent.Name == "PlayerCharacters" or (parent:IsA("Folder") and parent.Name:lower():find("player", 1, true))) then
     continue
    end
   end
   return isWaterPart(part)
  end
 end
 return nil
end

-- ================== BAY THẤP TRÊN BIỂN ==================
-- Game chỉ coi bay CAO (> FLIGHT_HEIGHT_MIN = 15 studs trên mặt đất/nước) là bất hợp pháp:
-- server bắt buộc stamina phải TIÊU HAO khi bay cao. Nếu KHÔNG có cách tiêu hao (không BlackLeg
-- → drainStamina() trả false) thì MỌI kiểu bay (SkyCruise / manual / auto) phải HẠ THẤP
-- sát mặt nước (SEA_LOW_FLY_MARGIN studs) khi đi qua BIỂN → watchdog không bao giờ kích hoạt.
local SEA_LOW_FLY_MARGIN = 2   -- bay sát mặt nước: dưới ngưỡng watchdog 15, đủ cao khỏi sóng
local drainOkCache = { value = nil, at = 0 }
local DRAIN_CACHE_SECONDS = 2

--- Có cách tiêu hao stamina không (BlackLeg → Sky Walk)? Cache 2s — hasBlackLeg() đọc inventory JSON đắt
local canDrainStamina = function()
 local nowT = os.clock()
 if drainOkCache.value == nil or nowT - drainOkCache.at > DRAIN_CACHE_SECONDS then
  drainOkCache.value = hasBlackLeg()
  drainOkCache.at = nowT
 end
 return drainOkCache.value == true
end

--- CHẾ ĐỘ BAY THẤP TRÊN BIỂN: trả về mặt nước Y nếu bên dưới là BIỂN và KHÔNG có cách tiêu hao
--- stamina (→ phải hạ sát mặt nước). Trả nil → bay bình thường (đất / có BlackLeg).
local seaFlyLowActive = function(pos)
 if canDrainStamina() then return nil end
 local y, isSea = groundOrSeaBelow(pos or getPlayerPosition())
 if isSea == true and y then return y end
 return nil
end

--- Tao BodyVelocity + BodyGyro gan vao HRP, tra ve ca 2 de caller luu lai
local function createFlyPhysicsObjects(hrp)
 local bv = Instance.new("BodyVelocity")
 bv.MaxForce = Vector3.new(1, 1, 1) * math.huge
 bv.Velocity = Vector3.new(0, 0, 0)
 bv.Parent   = hrp

 local gyro = Instance.new("BodyGyro")
 gyro.MaxTorque = Vector3.new(1, 1, 1) * math.huge
 gyro.P         = 3000
 gyro.D         = 100
 gyro.CFrame    = hrp.CFrame
 gyro.Parent    = hrp

 return bv, gyro
end

--- Kiem tra dieu kien truoc khi bat dau bay
--- Tra ve: ok (bool), hrp, humanoid
local function validateAndPrepareFly()
 if Status.Idle or Status.Walk then
  return false
 end
 if Status.Fly then
  stopFly()
 end
 local hrp      = getHumanoidRootPart()
 local humanoid = getHumanoid()
 if not (hrp and humanoid and isPlayerAlive()) then
  return false
 end
 return true, hrp, humanoid
end

-- ================== FLY: OBSTACLE DETECTION ==================

--- Bo qua part "tường ảo" (CanCollide=false...) trong kết quả raycast thô
--- Tra ve: hit hoac nil
local function filterPassThroughHit(hit)
 if hit and isPassThroughPart(hit.Instance) then return nil end
 return hit
end
--- Raycast thang phia truoc theo huong horizontalDir
local function castRayForward(hrp, direction, maxDistance)
 local params = RaycastParams.new()
 params.FilterType                 = Enum.RaycastFilterType.Exclude
 params.FilterDescendantsInstances = { Character }
 local hit = filterPassThroughHit(workspace:Raycast(hrp.Position, direction.Unit * maxDistance, params))
 debugRecordRay(hrp.Position, hrp.Position + direction.Unit * maxDistance, hit and DEBUG_RAY_COLORS.blocked or DEBUG_RAY_COLORS.clear)
 return hit
end
--- Kiem tra xem co can bay len do cao boost hay khong
--- Tra ve: shouldBoost (bool), reason (string|nil)
local function shouldFlyAtBoostHeight(hrp, horizontalDir, remainingDistance)
 if not hrp then return false end

 local hit = castRayForward(hrp, horizontalDir, OBSTACLE_CHECK_DISTANCE)
 if hit then
  return true, "Obstacle"
 end
 if remainingDistance and remainingDistance > FAR_DISTANCE_THRESHOLD then
  return true, "FarDistance"
 end
 return false
end

-- ================== FLY: STAMINA DRAIN ==================
--[[
 SUA LOI TIMING STAMINA (v1 -> v2):

 v1 dung 1 accumulator chung cho ca ngang lan doc:
   - Khi bay thang len/xuong, checkSpeedFly dua vao realPos (update cham) ->
     khong phat hien duoc di chuyen doc -> bo luot tru stamina.
   - checkHeight cung co the khong kip cap nhat -> bo luot.

 v2 tach thanh 2 accumulator doc lap:
   * stamAccum     : drain theo STAMINA_DRAIN_INTERVAL (0.8s), luon chay du
                     dang bay ngang hay dung yen tren khong.
   * vertStamAccum : drain theo VERTICAL_DRAIN_INTERVAL (0.5s), chi chay
                     khi |yDiff| > BOOST_TOLERANCE (dang thuc su di chuyen doc).
 
 Nho vay du bay theo chieu nao, toc do nao cung duoc tru stamina dung nhip.
]]

--- Drain dinh ky cho di chuyen ngang (dung cho ca manual lan auto fly)
--- Tra ve false neu stamina khong the drain (nen dung bay)
local function tickHorizontalStaminaDrain(stamAccum, dt)
 stamAccum.value = stamAccum.value + dt
 if stamAccum.value >= STAMINA_DRAIN_INTERVAL then
  stamAccum.value = stamAccum.value - STAMINA_DRAIN_INTERVAL
  local ok = drainStamina()
  if not ok then
   return false
  end
 end
 return true
end

--- Drain bo sung khi dang di chuyen theo chieu doc (len hoac xuong)
--- Chi tinh khi isMovingVertically == true
--- Reset accumulator ve 0 khi khong di chuyen doc (tranh burst khi bat dau lai)
--- Tra ve false neu stamina khong the drain
local function tickVerticalStaminaDrain(vertStamAccum, dt, isMovingVertically)
 if not isMovingVertically then
  vertStamAccum.value = 0
  return true
 end
 vertStamAccum.value = vertStamAccum.value + dt
 if vertStamAccum.value >= VERTICAL_DRAIN_INTERVAL then
  vertStamAccum.value = vertStamAccum.value - VERTICAL_DRAIN_INTERVAL
  local ok = drainStamina()
  if not ok then
   return false
  end
 end
 return true
end

-- ================== FLY: VELOCITY CALCULATORS ==================

--- Tinh velocity ngang dua tren input WASD cua nguoi choi (manual fly)
--- Tra ve: velocity (Vector3), moveDir (Vector3, co the zero)
local function calculateManualHorizontalVelocity(camCFrame, flySpeed)
 local moveDir = Vector3.new(0, 0, 0)
 if UserInputService:IsKeyDown(Enum.KeyCode.W)           then moveDir = moveDir + camCFrame.LookVector  end
 if UserInputService:IsKeyDown(Enum.KeyCode.S)           then moveDir = moveDir - camCFrame.LookVector  end
 if UserInputService:IsKeyDown(Enum.KeyCode.A)           then moveDir = moveDir - camCFrame.RightVector end
if UserInputService:IsKeyDown(Enum.KeyCode.D)           then moveDir = moveDir + camCFrame.RightVector end
 if UserInputService:IsKeyDown(Enum.KeyCode.Space)       then moveDir = moveDir + Vector3.new(0, 1, 0)  end
 if UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) then moveDir = moveDir - Vector3.new(0, 1, 0)  end

 if moveDir.Magnitude > 0 then
  moveDir = moveDir.Unit
  return moveDir * flySpeed, moveDir
 end
 return Vector3.new(0, 0, 0), Vector3.new(0, 0, 0)
end

--- Tinh velocity ngang huong ve vi tri muc tieu (auto fly)
--- Tra ve: velocity (Vector3), horizontalDir (Vector3|nil), flatDistance (number)
local function calculateAutoHorizontalVelocity(hrpPos, targetPos, arriveDistance, flySpeed)
 local flatTarget = Vector3.new(targetPos.X, hrpPos.Y, targetPos.Z)
 local toTarget   = flatTarget - hrpPos
 local flatDist   = toTarget.Magnitude

 if flatDist > arriveDistance then
  local dir = toTarget.Unit
  return dir * flySpeed, dir, flatDist
 end
 return Vector3.new(0, 0, 0), nil, flatDist
end

--- Tinh velocity doc de dat den desiredY
--- Tra ve: verticalVelocity (number), isMovingVertically (bool)
local function calculateVerticalVelocity(currentY, desiredY)
 local yDiff = desiredY - currentY
 if math.abs(yDiff) > BOOST_TOLERANCE then
  local direction = (yDiff > 0) and 1 or -1
  return direction * VERTICAL_BOOST_SPEED, true
 end
 return 0, false
end

-- ================== FLY MODE 1: MANUAL (WASD) ==================

startManualFly = function()
 if Status.Fly then stopFly() end
 local ok, hrp, humanoid = validateAndPrepareFly()
 if not ok then return end

 Status.Fly             = true
 humanoid.PlatformStand = true

 local bv, gyro = createFlyPhysicsObjects(hrp)
 Fly.flyBV   = bv
 Fly.flyGyro = gyro

 -- 2 accumulator tach biet de drain stamina dung cho tung chieu chuyen dong
 local stamAccum     = { value = 0 } -- drain ngang / dung yen tren khong
 local vertStamAccum = { value = 0 } -- drain doc (len/xuong Space/Ctrl)

 -- FIX: Tru stamina ngay lap tuc khi bat dau bay (tranh delay lan dau)
 drainStamina()

 Fly.flyConnection = RunService.RenderStepped:Connect(function(dt)
  -- Kiem tra trang thai song con co ban
  if not Status.Fly or not hrp or not hrp.Parent or not isPlayerAlive() then
   stopFly()
   return
  end

  -- [ANTI-KNOCKBACK] Re-enforce PlatformStand moi frame
  -- Khi bi quai danh, game co the reset PlatformStand -> mat fly
  -- Viec set lai moi frame dam bao fly luon duy tri
  humanoid = getHumanoid()
  if humanoid then
   humanoid.PlatformStand = true
  end

  -- [ANTI-KNOCKBACK] Kiem tra bv/gyro con song khong, neu bi xoa thi tao lai
  -- Mot so game script hoac effect co the destroy cac BodyMover nay
  if not bv or not bv.Parent then
   bv = Instance.new("BodyVelocity")
   bv.MaxForce = Vector3.new(1,1,1) * math.huge
   bv.Velocity = Vector3.new(0,0,0)
   bv.Parent   = hrp
   Fly.flyBV   = bv
  end
  if not gyro or not gyro.Parent then
   gyro = Instance.new("BodyGyro")
gyro.MaxTorque = Vector3.new(1,1,1) * math.huge
   gyro.P         = 3000
   gyro.D         = 100
   gyro.CFrame    = hrp.CFrame
   gyro.Parent    = hrp
   Fly.flyGyro    = gyro
  end

  local camCFrame = workspace.CurrentCamera.CFrame
  local velocity, moveDir = calculateManualHorizontalVelocity(camCFrame, Fly.flySpeed)

  -- [MIN HEIGHT] San dong MỖI FRAME: mat dat/nuoc that duoi chan + 2 studs
  -- (IgnoreWater=false de bat ca mat nuoc); san TUYET DOI = BASE_Y (-2.7) —
  -- cho phep moi loai bay bay thap tuy y, khong bao gio thap hon BASE_Y
  -- BIỂN + không drain được stamina (không BlackLeg) → san = sát mặt nước + margin,
  -- KHÓA độ cao (Space không bay cao hơn được), ép hạ thấp nếu đang bay cao
  local currentY  = hrp.Position.Y
  local minY      = BASE_Y
  local seaLowY   = seaFlyLowActive()
  local floorRp = RaycastParams.new()
  floorRp.FilterType = Enum.RaycastFilterType.Exclude
  floorRp.FilterDescendantsInstances = { Character }
  local floorHit = workspace:Raycast(hrp.Position, Vector3.new(0, -250, 0), floorRp)
  if seaLowY then
   minY = seaLowY + SEA_LOW_FLY_MARGIN
  elseif floorHit then
   minY = math.max(BASE_Y, floorHit.Position.Y + 2)
  end
  local yVelocity = 0
  local isMovingVertically = UserInputService:IsKeyDown(Enum.KeyCode.Space)
   or UserInputService:IsKeyDown(Enum.KeyCode.LeftControl)

  if UserInputService:IsKeyDown(Enum.KeyCode.Space) then
   -- Trên biển (không drain được): chặn bay cao hơn sát mặt nước
   if seaLowY and currentY >= seaLowY + SEA_LOW_FLY_MARGIN - BOOST_TOLERANCE then
    yVelocity = 0
   else
    yVelocity = VERTICAL_BOOST_SPEED
   end
  elseif UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) then
   if currentY > minY + BOOST_TOLERANCE then
    yVelocity = -VERTICAL_BOOST_SPEED
   else
    yVelocity = 0
    isMovingVertically = false
   end
  elseif seaLowY and currentY > seaLowY + SEA_LOW_FLY_MARGIN + BOOST_TOLERANCE then
   -- Đang cao hơn cap trên biển → TỰ HẠ xuống sát mặt nước
   yVelocity = -VERTICAL_BOOST_SPEED
   isMovingVertically = true
  elseif currentY < minY - BOOST_TOLERANCE then
   yVelocity = VERTICAL_BOOST_SPEED
   isMovingVertically = true
  end

  -- Cap nhat desiredY cho Watchdog theo doi
  Fly.desiredY = minY

  if velocity.Magnitude > 0 then
   bv.Velocity = velocity + Vector3.new(0, yVelocity, 0)
   -- Xoay nhan vat theo huong di chuyen ngang (bo qua Y de khong nghieng)
   local flatDir = Vector3.new(moveDir.X, 0, moveDir.Z)
   if flatDir.Magnitude > 0.01 then
    gyro.CFrame = CFrame.new(hrp.Position, hrp.Position + flatDir)
   end
  else
   bv.Velocity = Vector3.new(0, yVelocity, 0)
  end

  -- Drain stamina: ngang (lien tuc) + doc (them khi leo/ha)
  -- BIỂN + không drain được stamina (không BlackLeg) → bỏ drain (bay thấp sát nước là hợp lệ)
  local horizOk, vertOk = true, true
  if not seaLowY then
   horizOk = tickHorizontalStaminaDrain(stamAccum, dt)
   vertOk  = tickVerticalStaminaDrain(vertStamAccum, dt, isMovingVertically)
  end
  if not horizOk or not vertOk then
   stopFly()
  end
 end)
end

-- ================== FLY MODE 2: AUTO FLY TO TARGET ==================
--[[
 targetGetter  : ham khong tham so, tra ve Vector3 (vi tri dich)
 onArrive      : (optional) callback khi da den du gan
 arriveDistance: (optional) khoang cach tinh la "da den" (mac dinh 4 studs)
]]

startAutoFly = function(targetGetter, onArrive, arriveDistance)
 if Status.Fly then stopFly() end
 arriveDistance = arriveDistance or 4

 local ok, hrp, humanoid = validateAndPrepareFly()
 if not ok then return end
 if typeof(targetGetter) ~= "function" then return end

 Status.Fly             = true
 Fly.flyTarget          = targetGetter
 humanoid.PlatformStand = true

 local bv, gyro = createFlyPhysicsObjects(hrp)
 Fly.flyBV   = bv
 Fly.flyGyro = gyro

 -- 2 accumulator tach biet
 local stamAccum     = { value = 0 } -- drain ngang
 local vertStamAccum = { value = 0 } -- drain doc (len/xuong ne vat can)

 -- FIX: Tru stamina ngay lap tuc khi bat dau bay (tranh delay lan dau)
 drainStamina()

 Fly.flyConnection = RunService.RenderStepped:Connect(function(dt)
  -- Kiem tra trang thai song con co ban
  if not Status.Fly or not hrp or not hrp.Parent or not isPlayerAlive() then
   stopFly()
   return
  end
-- [ANTI-KNOCKBACK] Re-enforce PlatformStand moi frame
  humanoid = getHumanoid()
  if humanoid then
   humanoid.PlatformStand = true
  end

  -- [ANTI-KNOCKBACK] Tao lai bv/gyro neu bi game xoa
  if not bv or not bv.Parent then
   bv = Instance.new("BodyVelocity")
   bv.MaxForce = Vector3.new(1,1,1) * math.huge
   bv.Velocity = Vector3.new(0,0,0)
   bv.Parent   = hrp
   Fly.flyBV   = bv
  end
  if not gyro or not gyro.Parent then
   gyro = Instance.new("BodyGyro")
   gyro.MaxTorque = Vector3.new(1,1,1) * math.huge
   gyro.P         = 3000
   gyro.D         = 100
   gyro.CFrame    = hrp.CFrame
   gyro.Parent    = hrp
   Fly.flyGyro    = gyro
  end

  local targetPos = targetGetter()
  if not targetPos then
   stopFly()
   return
  end

  -- Tinh velocity ngang
  local horizVelocity, horizontalDir, flatDistance =
   calculateAutoHorizontalVelocity(hrp.Position, targetPos, arriveDistance, Fly.flySpeed)

  if horizontalDir then
   -- Dang bay ve phia muc tieu -> xoay nhan vat theo huong ngang
   gyro.CFrame = CFrame.new(hrp.Position, hrp.Position + horizontalDir)
  elseif onArrive then
   onArrive()
  end

  -- Xac dinh do cao dich
  -- CANH BAO: Khong dung BASE_Y truc tiep lam desiredY vi tren bien
  -- BASE_Y = -2.7 thap hon mat nuoc (Y~0) -> nhan vat bi keo xuong long bien!
  -- Thay vao do: raycast xuong duoi de tim mat dat/bien thuc, giu cao hon MIN_FLY_HEIGHT
  -- BIỂN + không drain được stamina (không BlackLeg) → desiredY = sát mặt nước, KHÔNG boost
  local seaLowY = seaFlyLowActive(hrp.Position)
  local needBoost = false
  if horizontalDir and not seaLowY then
   needBoost = shouldFlyAtBoostHeight(hrp, horizontalDir, flatDistance)
  end

  -- San toi thieu: mat dat/bien thuc duoi chan + 2 studs (cho phep bay THAP;
  -- tren bien khong ray toi dat -> fallback BASE_Y + MIN_FLY_HEIGHT giu tren mat nuoc)
  local downParams = RaycastParams.new()
  downParams.FilterType = Enum.RaycastFilterType.Exclude
  downParams.FilterDescendantsInstances = { Character }
  local downHit = workspace:Raycast(hrp.Position, Vector3.new(0, -250, 0), downParams)
  local terrainFloor = downHit and (downHit.Position.Y + 2)
                                or (BASE_Y + MIN_FLY_HEIGHT)

  local desiredY
  if seaLowY then
   -- Trên biển + không drain được stamina: bay SÁT MẶT NƯỚC, không vọt cao (watchdog không bắt)
   needBoost = false
   Fly.bridgeActive = false
   desiredY = seaLowY + SEA_LOW_FLY_MARGIN
  elseif needBoost then
   -- Vat can phia truoc: uu tien "cau troi" — leo DUNG toi do cao vuot tuong
   -- (targetTop.Y) thay vi phong 500 studs; khong co cau troi -> vọt cao nhu cu
   local wallSeparated = isSeparatedByThickWall(hrp.Position, targetPos, nil, true)
   if wallSeparated then
    -- BAY VƯỢT TƯỜNG: tia ngang đầu (5.0) thông → leo ĐÚNG tới đỉnh tường + margin
    -- (2 tia thấp còn lại tự khớp thông), không phóng 500 studs
    local climbY = getWallClimbFlyY(hrp.Position, targetPos)
    if climbY then
     desiredY = climbY
     Fly.bridgeActive = false
    else
     local bridgeY = getSkyBridgeOverWall(hrp.Position, targetPos)
     if bridgeY then
      desiredY = bridgeY
      Fly.bridgeActive = true
     else
      desiredY = BASE_Y + BOOST_HEIGHT
      Fly.bridgeActive = false
     end
    end
   else
    desiredY = BASE_Y + BOOST_HEIGHT
    Fly.bridgeActive = false
   end
  else
   -- Da QUA tuong (het vat can): ha xuong bay binh thuong, tiep tuc muc dich
   if Fly.bridgeActive and not isSeparatedByThickWall(hrp.Position, targetPos, nil, true) then
    desiredY = terrainFloor
    Fly.bridgeActive = false
   else
    -- CHE DO BAY CRUISING: giu do cao hien tai, khong tu ha xuong
    -- Logic:
    --   1. Raycast xuong de tim mat dat/bien thuc (san toi thieu)
    --   2. desiredY = max(do_cao_hien_tai, san_toi_thieu)
    --      -> Neu dang bay cao: giu nguyen (khong ha xuong)
    --      -> Neu bi day xuong thap hon san: tu dong len de tranh lun vao dat/bien
    desiredY = math.max(hrp.Position.Y, terrainFloor)
   end
  end

  -- Cap nhat desiredY cho Watchdog theo doi
  Fly.desiredY = desiredY

  -- Tinh velocity doc
  local vertVelocity, isMovingVertically = calculateVerticalVelocity(hrp.Position.Y, desiredY)

  -- Ap dung velocity tong hop
  bv.Velocity = horizVelocity + Vector3.new(0, vertVelocity, 0)

  -- Drain stamina: ngang + doc rieng biet
  -- BIỂN + không drain được stamina (không BlackLeg) → bỏ drain (bay thấp sát nước là hợp lệ)
  local horizOk, vertOk = true, true
  if not seaLowY then
   horizOk = tickHorizontalStaminaDrain(stamAccum, dt)
   vertOk  = tickVerticalStaminaDrain(vertStamAccum, dt, isMovingVertically)
  end
  if not horizOk or not vertOk then
   stopFly()
  end
 end)
end

-- ================== INIT ==================
if isPlayerAboveGroundLevel() then
 Fly.flyMode = "Height"
else
 Fly.flyMode = "Low"
end

-- Dat SetValue sau khi tat ca ham (startManualFly, stopFly) da duoc dinh nghia
-- Tranh loi "attempt to call a nil value" khi OnChanged duoc trigger ngay lap tuc
Options.Fly:SetValue(false)

-- ================== UI: ISLAND FLY ==================
-- Phan UI nay dat cuoi file vi can cac ham Island Navigation da san sang

do
 local islandNames = getIslandNamesSorted()

 if #islandNames == 0 then
  -- Khong tim thay dao nao trong workspace.Islands
  Tabs.Main:AddParagraph({
   Title   = "Island Fly",
   Content = "Khong tim thay dao nao trong workspace.Islands"
  })
 else
  -- Dropdown chon dao
  local IslandDropdown = Tabs.Main:AddDropdown("IslandSelect", {
   Title       = "Choose Island",
   Description = "Choose Island to fly " .. "(" .. #islandNames .. " dao)",
   Values      = islandNames,
   Default     = islandNames[1],
   Multi       = false,
   Callback    = function(value)
    IslandFly.selectedIsland = value
    notify("Choose Island: " .. tostring(value), 2)
   end
  })
  -- Set mac dinh dao dau tien
  IslandFly.selectedIsland = islandNames[1]

  -- Toggle bat/tat bay toi dao
  local IslandFlyToggle = Tabs.Main:AddToggle("IslandFly", {
   Title   = "Fly To Island",
   Default = false
  })
  IslandFlyToggle:OnChanged(function()
   local active = Options.IslandFly.Value
   IslandFly.active = active
   if active then
    notify("Flying in: " .. tostring(IslandFly.selectedIsland), 3)
    setSharedStatus("IslandFly", "Bay", "Bay toi dao: " .. tostring(IslandFly.selectedIsland))
    flyToSelectedIsland()
   else
    notify("Flying in Island", 2)
    setSharedStatus("IslandFly", "Idle", "Bay dao da tat")
    stopIslandFly()
   end
  end)
  Options.IslandFly:SetValue(false)
 end
end

-- ================== UI: AUTO FARM (QUEST) ==================
-- Farm theo Quest hien tai: Target + maxCount lay tu getQuestInfo()

local AutoFarm = {
 active            = false,
 speed             = 75,
 statusLabel       = nil,
 lastUpgradeCheck  = 0, -- lan cuoi kiem tra quest DB khi len cap (giay)
  hadQuest          = false, -- đang có quest farm được (dùng phát hiện hủy quest THỦ CÔNG)
}
-- ================== AUTO QUEST ==================
-- Dinh nghia TRUOC autoFarmLoop (khong phu thuoc initImpelDownModule) - fix loi "index nil findAvailable"
local QuestAPI = {}
_G.QuestAPI = QuestAPI
print("[AutoQuest] QuestAPI ready (dinh nghia truoc autoFarmLoop)")

-- Cấp người chơi: Stats<Player>.Stats.Level (IntValue)
QuestAPI.getPlayerLevel = function()
 local rs = game:GetService("ReplicatedStorage")
 local pStats = rs:FindFirstChild("Stats" .. Player.Name) or (rs:FindFirstChild("Stats") and rs.Stats:FindFirstChild(Player.Name))
 local s = pStats and pStats:FindFirstChild("Stats")
 local lv = s and s:FindFirstChild("Level")
 return (lv and tonumber(lv.Value)) or 0
end

-- ================== QUEST REMOTE AN TOÀN ==================
-- Server chỉ nhận quest trong ~5 studs. MỌI invoke quest remote đều qua:
--   1. questInvokeAllowed() — rate-limit chung tối đa 1 lần / 5s (chống spam → anti-cheat)
--   2. Cổng khoảng cách 5 studs theo serverPos (vị trí server thấy) — gọi từ xa = nghi exploit = BAN
--   3. NPC model phải hiện diện trong workspace gần vị trí — remote chỉ chạy khi có chứng cứ thực tế

QuestAPI.lastQuestInvoke = 0
local function questInvokeAllowed()
 local nowT = os.clock()
 if nowT - QuestAPI.lastQuestInvoke < 5 then return false end
 QuestAPI.lastQuestInvoke = nowT
 return true
end

-- Khoảng cách tối đa để gọi takequest — server chỉ nhận quest trong ~5 studs
local QUEST_TAKE_RANGE = 5
-- Bán kính tìm model NPC phải hiện diện quanh tọa độ QuestDB (cứng: không có model = không gọi remote)
local QUEST_NPC_MODEL_RANGE = 50
-- NPC xa hơn mức này mà model chưa load (streaming) → vẫn bay thẳng tới tọa độ QuestDB
local QUEST_FAR_DISTANCE = 1000

-- Nhận quest: Events.Quest:InvokeServer({ "takequest", questName })
QuestAPI.takeQuest = function(questName)
 if not questName then return false end
 if not questInvokeAllowed() then return false end
 local events = game:GetService("ReplicatedStorage"):FindFirstChild("Events")
 local remote = events and events:FindFirstChild("Quest")
 if not remote then return false end
 local ok = pcall(function() remote:InvokeServer({ "takequest", questName }) end)
 return ok
end

-- Hủy quest hiện tại: Events.Quest:InvokeServer({ "quit" }) — dùng chung rate-limit 5s
QuestAPI.cancelQuest = function()
 if not questInvokeAllowed() then return false end
 local events = game:GetService("ReplicatedStorage"):FindFirstChild("Events")
 local remote = events and events:FindFirstChild("Quest")
 if not remote then return false end
 local ok = pcall(function() remote:InvokeServer({ "quit" }) end)
 return ok
end

-- Kiểm tra NPC quest có thực sự tồn tại trong workspace quanh tọa độ (an toàn tuyệt đối)
QuestAPI.npcPresent = function(npcName, position)
 if not (npcName and position) then return false end
 return QuestAPI.getNPCModel(npcName, position) ~= nil
end

-- Tìm model NPC thật quanh tọa độ — ưu tiên model khớp tên (chính xác -> chứa tên -> bất kỳ)
QuestAPI.getNPCModel = function(npcName, position)
 if not position then return nil end
 local best, bestScore = nil, 0
 for _, model in ipairs(workspace:GetDescendants()) do
  if model:IsA("Model") then
   local root = model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart
   if root and (root.Position - position).Magnitude <= QUEST_NPC_MODEL_RANGE then
    local score = (model.Name == npcName) and 3 or (model.Name:find(npcName, 1, true) and 2) or 1
    if score > bestScore then best, bestScore = model, score end
   end
  end
 end
 return best
end

-- ================== DISCOVER QUEST NAME THẬT ==================
-- BẮT BUỘC kiểm tra quest cần nhận — KHÔNG được mặc định nhận quest của NPC bất kỳ:
--   1. db.quest (QuestDB ghi rõ tên quest)
--   2. Chuỗi quest-like trong model NPC (ProximityPrompt / BillboardGui-SurfaceGui / StringValue / tên model)
--   3. Không chứng minh được → trả fallback + nguồn nil → goTake TỪ CHỐI nhận (tránh nhận nhầm)
local QUEST_NAME_BLACKLIST = { "press", "required", "accept", "interact", "to start", "to accept", "hold", "click", "quest request" }
local function looksLikeQuestName(text)
 text = tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
 if text == "" or #text < 3 or #text > 120 then return nil end
 local low = text:lower()
 for _, w in ipairs(QUEST_NAME_BLACKLIST) do
  if low:find(w, 1, true) and #text <= 30 then return nil end
 end
 -- "Quest" / "Quest!" đứng một mình = label UI, không phải tên quest
 if #text <= 12 and low:find("quest", 1, true) then return nil end
 -- Nhãn YÊU CẦU CẤP: "Level 20+", "Level: 20", "Level 20" (billboard NPC) — KHÔNG phải tên quest
 if low:match("^level%s?%d+%s*[%+%:]") then return nil end
 if low:find("^level %d+$") then return nil end
 -- Ưu tiên cú pháp quest đặc trưng: Help X / Level N <nội dung> / động từ hành động
 if low:find("help ") or low:find("^level %d+%s+%a") or low:find("kill ") or low:find("defeat ")
  or low:find("clear ") or low:find("slay ") or low:find("catch ") or low:find("collect ")
  or low:find("awaken ") then
  return text
 end
 -- Chuỗi in hoa đầu câu, không phải label UI thường gặp
 if text:find("^%u%l") and #text > 12 then
  return text
 end
 return nil
end

QuestAPI.discoverQuestName = function(npcName, db, npcModel)
 -- 1. QuestDB ghi rõ = nguồn tin cậy nhất
 if db and db.quest then return db.quest, "QuestDB" end
 -- 2. Tên model thật → "Help <tên model>" (DB key có thể khác tên thật, vd Daph vs Daphne)
 if npcModel then
  local modelName = tostring(npcModel.Name or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if modelName ~= "" and modelName ~= npcName then
   local q = looksLikeQuestName("Help " .. modelName)
   if q then return q, "model.Name" end
  end
  -- 3. ProximityPrompt / GUI / StringValue chứa chuỗi quest-like
  for _, child in ipairs(npcModel:GetDescendants()) do
   if child:IsA("ProximityPrompt") then
    local q = looksLikeQuestName(child.ObjectText) or looksLikeQuestName(child.ActionText)
    if q then return q, "ProximityPrompt" end
   elseif child:IsA("StringValue") and child.Name:lower():find("quest") then
    local q = looksLikeQuestName(child.Value)
    if q then return q, "StringValue." .. child.Name end
   elseif (child:IsA("TextLabel") or child:IsA("TextButton") or child:IsA("TextBox"))
    and (child:FindFirstAncestorOfClass("BillboardGui") or child:FindFirstAncestorOfClass("SurfaceGui")) then
    local q = looksLikeQuestName(child.Text)
    if q then return q, "GUI" end
   end
  end
  -- 4. Mọi StringValue quest-like còn lại trong model
  for _, child in ipairs(npcModel:GetDescendants()) do
   if child:IsA("StringValue") then
    local q = looksLikeQuestName(child.Value)
    if q then return q, "StringValue" end
   end
  end
 end
 -- 5. KHÔNG chứng minh được → fallback tên giả, nguồn nil (goTake sẽ từ chối)
 return "Help " .. npcName, nil
end

-- ================== BIỂN / ĐẤT DƯỚI CHÂN (WRAPPER QUESTAPI) ==================
QuestAPI.groundOrSeaBelow = groundOrSeaBelow
QuestAPI.canDrainStamina  = canDrainStamina
QuestAPI.seaFlyLowActive  = seaFlyLowActive
QuestAPI.waterBelow15     = waterBelow15

-- NPC quest khả dụng: BẮT BUỘC chỉ chọn quest có minLevel CAO NHẤT phù hợp cấp người chơi.
-- TUYỆT ĐỐI KHÔNG bay tới hay nhận bất kỳ quest nào thấp hơn cấp hiện tại!
QuestAPI.skipUntil = {}
QuestAPI.pauseUntil = 0

-- Lấy minLevel cao nhất khả dụng cho người chơi hiện tại (loại bỏ quest đã xong)
QuestAPI.getMaxMinLevel = function()
 local lvl = QuestAPI.getPlayerLevel()
 local completed = getCompletedQuests()
 local nowT = os.clock()
 local maxMin = -1
 
 -- Vòng 1: Tìm minLevel cao nhất trong các quest chưa bị skip và chưa hoàn thành
 for npcName, db in pairs(QuestDB) do
  local questKey = db.quest or ("Help " .. npcName)
  local alreadyDone = completed[questKey] or completed[npcName]
  if db.minLevel and db.minLevel <= lvl and not alreadyDone then
   if not (QuestAPI.skipUntil[npcName] and QuestAPI.skipUntil[npcName] > nowT) then
    if db.minLevel > maxMin then
     maxMin = db.minLevel
    end
   end
  end
 end
 
 -- Vòng 2: Nếu tất cả NPC ở cấp cao nhất đang bị skip, lấy minLevel cao nhất bỏ qua skip (để không bị hạ cấp)
 if maxMin == -1 then
  for npcName, db in pairs(QuestDB) do
   local questKey = db.quest or ("Help " .. npcName)
   local alreadyDone = completed[questKey] or completed[npcName]
   if db.minLevel and db.minLevel <= lvl and not alreadyDone then
    if db.minLevel > maxMin then
     maxMin = db.minLevel
    end
   end
  end
 end
 
 return maxMin
end

-- Tìm quest phù hợp nhất: CHỈ CHỌN quest có minLevel == maxMinLevel (cấp cao nhất).
QuestAPI.findAvailable = function()
 if os.clock() < QuestAPI.pauseUntil then return nil end
 local lvl = QuestAPI.getPlayerLevel()
 local maxMin = QuestAPI.getMaxMinLevel()
 if maxMin < 0 then return nil end
 
 local myPos = getPlayerPosition()
 local nowT = os.clock()
 local completed = getCompletedQuests()
 local bestName, bestDb, bestDist = nil, nil, math.huge
 
 for npcName, db in pairs(QuestDB) do
  local questKey = db.quest or ("Help " .. npcName)
  local alreadyDone = completed[questKey] or completed[npcName]
  -- BẮT BUỘC: minLevel PHẢI ĐÚNG BẬC CAO NHẤT (== maxMin). Không nhận quest thấp hơn!
  if db.minLevel and db.minLevel == maxMin
   and not alreadyDone
   and not (QuestAPI.skipUntil[npcName] and QuestAPI.skipUntil[npcName] > nowT) then
   local pos = db.position or getNPCPosition(npcName)
   if pos then
    db.position = pos
    local d = myPos and (pos - myPos).Magnitude or 0
    if d < bestDist then
     bestName, bestDb, bestDist = npcName, db, d
    end
   elseif not bestName then
    bestName, bestDb = npcName, db
   end
  end
 end
 return bestName, bestDb
end

-- Bán kính "đứng gần NPC quest" để kích hoạt quest đó
local QUEST_NEAR_RADIUS = 3

-- Tìm NPC quest gần nhất nhưng CHỈ trong danh sách quest CÙNG BẬC CẤP CAO NHẤT (minLevel == maxMin).
QuestAPI.findNearest = function(excludeName, anyDistance)
 if os.clock() < QuestAPI.pauseUntil then return nil end
 local lvl = QuestAPI.getPlayerLevel()
 local maxMin = QuestAPI.getMaxMinLevel()
 if maxMin < 0 then return nil end

 local myPos = getPlayerPosition()
 local nowT = os.clock()
 local completed = getCompletedQuests()
 local bestName, bestDb, bestDist = nil, nil, math.huge

 for npcName, db in pairs(QuestDB) do
  local questKey = db.quest or ("Help " .. npcName)
  local alreadyDone = completed[questKey] or completed[npcName]
  -- BẮT BUỘC: minLevel PHẢI ĐÚNG BẬC CAO NHẤT (== maxMin). Tuyệt đối không chọn quest cấp thấp hơn!
  if npcName ~= excludeName
   and db.minLevel and db.minLevel == maxMin
   and not alreadyDone
   and not (QuestAPI.skipUntil[npcName] and QuestAPI.skipUntil[npcName] > nowT) then
   local pos = db.position or getNPCPosition(npcName)
   if pos then
    db.position = pos
    local d = myPos and (pos - myPos).Magnitude or 0
    if d <= QUEST_NEAR_RADIUS or anyDistance then
     if d < bestDist then
      bestName, bestDb, bestDist = npcName, db, d
     end
    end
   end
  end
 end
 return bestName, bestDb
end

-- Bay tới NPC + nhận quest (chỉ nhận quest hợp lệ và đúng cấp)
QuestAPI.goTake = function(npcName, db, speed)
 local fp = _G.FlyPathfinder
 if not (npcName and db) then return false end
 local npcPos = db.position or getNPCPosition(npcName)
 if not npcPos then
  QuestAPI.skipUntil[npcName] = os.clock() + 30
  return false
 end
 if not db.position then db.position = npcPos end

 -- CỔNG KIỂM TRA CẤP BẮT BUỘC:
 -- 1. Không nhận quest nếu cấp người chơi chưa đủ (lvlGate < minLevel)
 -- 2. Không nhận quest nếu minLevel THẤP HƠN cấp tối đa khả dụng của người chơi!
 local lvlGate = QuestAPI.getPlayerLevel()
 local maxMin = QuestAPI.getMaxMinLevel()
 if db.minLevel then
  if lvlGate and lvlGate < db.minLevel then
   print(string.format("[QuestAPI] Tu choi NPC '%s' vi chua du cap (%d < %d)", npcName, lvlGate or 0, db.minLevel))
   QuestAPI.skipUntil[npcName] = os.clock() + 30
   return false
  end
  if maxMin and maxMin > 0 and db.minLevel < maxMin then
   print(string.format("[QuestAPI] TU CHOI NPC '%s' (minLevel %d) vi thap hon quest cap cao nhat (%d)", npcName, db.minLevel, maxMin))
   QuestAPI.skipUntil[npcName] = os.clock() + 60
   return false
  end
 end

 -- Kiểm tra quest đã hoàn thành chưa
 local completed = getCompletedQuests()
 local questKey = db.quest or ("Help " .. npcName)
 if completed[questKey] or completed[npcName] then
  print(string.format("[QuestAPI] Tu choi NPC '%s' vi da hoan thanh", npcName))
  return false
 end

 -- Cổng 1: NPC phải thực sự tồn tại quanh tọa độ
 local npcModel = QuestAPI.npcPresent(npcName, npcPos) and QuestAPI.getNPCModel(npcName, npcPos) or nil
 local modelFar = false
 if not npcModel then
  local myPos0 = getPlayerPosition()
  if myPos0 then modelFar = (npcPos - myPos0).Magnitude > QUEST_FAR_DISTANCE end
  if not modelFar then
   QuestAPI.skipUntil[npcName] = os.clock() + 30
   return false
  end
 end

 -- BƯỚC BẮT BUỘC: xác minh QUEST CẦN NHẬN
 local questName, questSource = QuestAPI.discoverQuestName(npcName, db, npcModel)
 if not questSource and modelFar then
  if fp then fp.FlyTo(npcPos, speed or 75, nil, "quest") end
  npcModel = QuestAPI.getNPCModel(npcName, npcPos)
  questName, questSource = QuestAPI.discoverQuestName(npcName, db, npcModel)
 end
 if not questSource then
  QuestAPI.skipUntil[npcName] = os.clock() + 30
  return false
 end

 if fp then fp.FlyTo(npcPos, speed or 75, nil, "quest") end

 local function inRange()
  local myPos = getPlayerPosition()
  return (myPos and (myPos - npcPos).Magnitude <= QUEST_TAKE_RANGE) or false
 end

 -- Ép tới gần NPC trước khi gọi remote
 local t0 = os.clock()
 while os.clock() - t0 < 8 do
  if not AutoFarm.active then return false end
  if inRange() then break end
  local myHrp = getHumanoidRootPart()
  if fp and myHrp and fp.currentBV and fp.currentBV.Parent then
   local d = (npcPos - myHrp.Position).Magnitude
   fp.currentBV.Velocity = (npcPos - myHrp.Position).Unit * math.clamp(d * 5, 10, speed or 75)
  end
  task.wait(0.15)
 end

 if not inRange() or QuestAPI.waterBelow15(nil) == true then
  QuestAPI.skipUntil[npcName] = os.clock() + 30
  return false
 end

 for attempt = 1, 2 do
  if not AutoFarm.active then return false end
  if not inRange() then
   local tp = os.clock()
   while os.clock() - tp < 3 do
    if not inRange() then
     local myHrp = getHumanoidRootPart()
     if fp and myHrp and fp.currentBV and fp.currentBV.Parent then
      local d = (npcPos - myHrp.Position).Magnitude
      fp.currentBV.Velocity = (npcPos - myHrp.Position).Unit * math.clamp(d * 5, 10, speed or 75)
     end
     task.wait(0.15)
    else break end
   end
   if not inRange() then QuestAPI.skipUntil[npcName] = os.clock() + 30; return false end
  end

  QuestAPI.takeQuest(questName)
  task.wait(1.5)
  local q = getQuestInfo()
  if not q then
   if not getCurrentQuestNPC() then QuestAPI.skipUntil[npcName] = os.clock() + 30; return false end
   return true
  end
  if q.Text and q.Text ~= "" and q.Text ~= questName then
   task.wait(4.0)
   QuestAPI.cancelQuest()
   if attempt == 1 then task.wait(5.6); continue end
   break
  end
  if q.Progress and (q.Progress.total - q.Progress.current) > 0 then
   return true
  end
 end
 QuestAPI.skipUntil[npcName] = os.clock() + 30
 return false
end


--- Cap nhat Status AutoFarm len UI (title + desc) va console
--- currentTag la bien CUC BO (nhu ImpelDown) de tranh local registers
local AUTO_FARM_STATUS_ICONS = {
 Idle          = "⏸️ Idle",
 WaitingQuest  = "📜 Chờ Quest",
 Farm          = "⚔️ Farm",
 Bay           = "✈️ Bay",
 KillDone      = "✅ Hạ xong",
 QuestDone     = "🏆 Xong Quest",
 Off           = "⛔ OFF",
}
local function setAutoFarmStatus(status, detail)
 if not status then status = "Idle" end
 local currentTag = "Idle"
 local descText = detail or ""
 if AUTO_FARM_STATUS_ICONS[status] then
  currentTag = status
 end
 local titleText = string.format("Trạng thái: %s", AUTO_FARM_STATUS_ICONS[currentTag] or currentTag)
 if AutoFarm.statusLabel then
  pcall(function()
   AutoFarm.statusLabel:SetTitle(titleText)
   if descText ~= "" then
    AutoFarm.statusLabel:SetDesc(descText)
   end
  end)
 end
 setSharedStatus("AutoFarm", currentTag, descText)
 print(string.format("[AutoFarm][%s] %s", currentTag, descText))
end

local function autoFarmLoop()
 setAutoFarmStatus("Idle", "Auto Farm đã bật — đang chờ Quest")
 while AutoFarm.active and isPlayerAlive() do
  local quest = getQuestInfo()
if not quest then
    if AutoFarm.hadQuest then
     -- NGƯỜI CHƠI cố tình HỦY quest giữa lúc farm → reset MỌI cooldown (pauseUntil/skipUntil
     -- còn 30s) để ĐI NHẬN QUEST MỚI NGAY, không kẹt "WaitingQuest" chờ hết giờ
     AutoFarm.hadQuest = false
     QuestAPI.pauseUntil = 0
     QuestAPI.skipUntil = {}
     setAutoFarmStatus("WaitingQuest", "Quest bị HỦY thủ công — reset cooldown, nhận quest mới ngay")
     print("[AutoFarm] Quest bi Huy thu cong — reset pauseUntil/skipUntil, nhan quest moi ngay")
    end
    if Options.AutoQuest.Value then
     -- Điều kiện kích hoạt: ĐỨNG GẦN NPC quest muốn farm (≤ QUEST_NEAR_RADIUS studs) + bật farm
     -- → nhận quest của NPC đó NGAY. Không đứng gần NPC nào → chọn quest hợp lý theo cấp.
     local npcName, db = QuestAPI.findNearest()
     if not npcName then
      npcName, db = QuestAPI.findAvailable()
     end
     if npcName then
      setAutoFarmStatus("Bay", string.format("Bay tới NPC quest: %s", npcName))
      local took = QuestAPI.goTake(npcName, db, AutoFarm.speed)
      if not took then
       -- Không thể bay tới quest hợp lý (NPC mất/tọa độ sai/không nhận được)
       -- → fallback: nhận quest GẦN NHẤT (bất kể khoảng cách, loại NPC vừa fail)
       local nearName, nearDb = QuestAPI.findNearest(npcName, true)
       if nearName then
        setAutoFarmStatus("Bay", string.format("Fallback quest gần nhất: %s", nearName))
        QuestAPI.goTake(nearName, nearDb, AutoFarm.speed)
       end
      end
      task.wait(0.3)
     else
      setAutoFarmStatus("WaitingQuest", "Không có NPC quest hợp lệ (tọa độ/cấp) — quét lại sau 1.5s")
      task.wait(1.5)
     end
   else
    -- Chua co quest -> cho quest moi
    setAutoFarmStatus("WaitingQuest", "Chưa có Quest — quét lại sau 1.5s")
    task.wait(1.5)
   end
  else
   -- Đang có quãng quest farm được — nếu quest biến mất đột ngột = người chơi HỦY thủ công
   AutoFarm.hadQuest = true
   -- Chỉ hủy quest khi KHÔNG farm được gì: không resolve được NPC lẫn target.
   -- Target lấy từ text tiến trình ("0/8 Bandit" → "Bandit") nên hầu hết quest đều farm được —
   -- không cần tọa độ NPC để giết quái, tọa độ chỉ cần khi nhận quest KẾ tiếp
   local questNPC = getCurrentQuestNPC()
   local npcName = questNPC and resolveQuestNPC(questNPC) or nil
   local db = npcName and QuestDB[npcName] or nil
   local targetKnown = quest.Target and quest.Target ~= ""
   if not (db and db.position) and not targetKnown then
    if Options.AutoQuest.Value then
     -- Hủy quest + dừng nhận lại 30s (chống vòng lặp hủy→nhận spam remote → tránh ban)
     setAutoFarmStatus("WaitingQuest", string.format("Hủy quest '%s' — NPC '%s' không xác định được tọa độ",
      tostring(quest.Target or "?"), tostring(questNPC or "?")))
QuestAPI.cancelQuest()
      AutoFarm.hadQuest = false -- bot TỰ hủy → KHÔNG reset cooldown (chống spam hủy→nhận)
      QuestAPI.pauseUntil = os.clock() + 30
     task.wait(1.0)
    else
     setAutoFarmStatus("WaitingQuest", string.format("Skip quest '%s' — NPC '%s' không xác định được tọa độ",
      tostring(quest.Target or "?"), tostring(questNPC or "?")))
     task.wait(1.5)
    end
    continue
end
    -- [QUEST THẤP HƠN CẤP TỐI ĐA] Nếu quest hiện tại minLevel < max minLevel khả dụng
    -- → BẮT BUỘC HỦY NGAY LẬP TỨC để nhận quest đúng cấp cao nhất (tuyệt đối không farm tiếp quest thấp hơn cấp!)
    if Options.AutoQuest.Value and db and db.minLevel then
     local maxMin = QuestAPI.getMaxMinLevel()
     if maxMin and maxMin > 0 and db.minLevel < maxMin then
      setAutoFarmStatus("WaitingQuest", string.format(
       "Quest '%s' (minLevel %d) thấp hơn cấp tối đa %d → HỦY NGAY để nhận quest đúng cấp",
       npcName or "?", db.minLevel, maxMin))
      QuestAPI.cancelQuest()
      AutoFarm.hadQuest = false
      QuestAPI.pauseUntil = 0 -- nhận quest mới ngay
      task.wait(0.5)
      continue
     end
    end
    -- [LÊN CẤP → QUEST MỚI] Định kỳ 8s: nếu cấp mới mở khóa NPC quest bậc CAO HƠN
    -- quest hiện tại (có position + minLevel + targets, không trong cooldown) → hủy
    -- quest cũ, nhận quest mới NGAY (quest mới = minLevel cao nhất <= cấp hiện tại)
    if Options.AutoQuest.Value and db and db.minLevel then
    if os.clock() - AutoFarm.lastUpgradeCheck >= 8 then
     AutoFarm.lastUpgradeCheck = os.clock()
     local lvl = QuestAPI.getPlayerLevel()
     local nowT = os.clock()
     local betterName, betterDb, betterMin = nil, nil, db.minLevel
     for npcName2, db2 in pairs(QuestDB) do
      if db2.position and db2.minLevel and db2.targets and db2.minLevel <= lvl
       and db2.minLevel > betterMin
       and not (QuestAPI.skipUntil[npcName2] and QuestAPI.skipUntil[npcName2] > nowT) then
       betterName, betterDb, betterMin = npcName2, db2, db2.minLevel
      end
     end
     if betterName then
      setAutoFarmStatus("WaitingQuest", string.format(
       "Lên cấp %d — mở khóa quest '%s' — hủy quest cũ '%s'", lvl, betterName, npcName))
QuestAPI.cancelQuest()
       AutoFarm.hadQuest = false -- bot tự hủy để đổi quest → không coi là hủy thủ công
       QuestAPI.pauseUntil = 0 -- nhận quest mới ngay, không chờ cooldown 30s
      QuestAPI.goTake(betterName, betterDb, AutoFarm.speed)
      task.wait(0.3)
      continue
     end
    end
   end
   -- maxCount = so con CON can giet (tien trinh tong - da giet)
   local remaining = quest.Progress
    and (quest.Progress.total - quest.Progress.current)
    or 1
   if remaining <= 0 then
    -- Xong quest
    if Options.AutoQuest.Value then
     -- Tự bay lại NPC quest để nhận quest KẾ TIẾP (chu trình khép kín)
     setAutoFarmStatus("QuestDone", string.format("Đã xong: %s — bay tới NPC nhận quest mới", quest.Target))
     local questNPC = getCurrentQuestNPC()
     local dbName = questNPC and resolveQuestNPC(questNPC) or nil
     local db = dbName and QuestDB[dbName] or nil
if not (db and db.position) then
       -- Đứng gần NPC quest muốn farm → nhận quest gần nhất; không thì quest hợp lý theo cấp
       dbName, db = QuestAPI.findNearest()
       if not dbName then
        dbName, db = QuestAPI.findAvailable()
       end
      end
     if dbName and db then
      QuestAPI.goTake(dbName, db, AutoFarm.speed)
      task.wait(0.3)
     else
      setAutoFarmStatus("WaitingQuest", "Không có NPC quest hợp lệ (tọa độ/cấp) — quét lại sau 1.5s")
      task.wait(1.5)
     end
    else
     -- Xong quest, cho quest moi
     setAutoFarmStatus("QuestDone", string.format("Đã xong: %s (%s)", quest.Target, quest.ProgressText))
     task.wait(1.5)
    end
   else
    local found = getNPCsByName(quest.Target, remaining)
    if #found == 0 then
     -- Chua spawn / het NPC trung ten -> quet lai
     setAutoFarmStatus("WaitingQuest", string.format("Không thấy '%s' (%d/%d) — chờ spawn", quest.Target,
      quest.Progress and quest.Progress.current or 0,
      quest.Progress and quest.Progress.total or 0))
     task.wait(1.5)
    else
     for _, npc in ipairs(found) do
      if not AutoFarm.active then break end
      setAutoFarmStatus("Farm", string.format("Đang tiêu diệt: %s (%d/%d)", npc.Model and npc.Model.Name or "?",
       quest.Progress and quest.Progress.current or 0,
       quest.Progress and quest.Progress.total or 0))
      killMonster(npc, AutoFarm.speed, {
       activeCheck = function() return AutoFarm.active end,
       logTag      = "[AutoFarm]",
       useFaceLook = true,
      })
      setAutoFarmStatus("KillDone", string.format("Đã hạ: %s — quét tiếp", npc.Model and npc.Model.Name or "?"))
      task.wait(0.15)
     end
    end
   end
  end
 end
 setAutoFarmStatus("Off", "Auto Farm đã tắt")
end

Tabs.Main:AddParagraph({
 Title   = "Auto Farm",
 Content = "Tu dong farm theo Quest hien tai (Target + tien trinh)"
})

local AutoFarmStatusParagraph = Tabs.Main:AddParagraph({
 Title   = "Trạng thái: ⏸️ Idle",
 Content = "Auto Farm chưa bật"
})
AutoFarm.statusLabel = AutoFarmStatusParagraph

local AutoFarmToggle = Tabs.Main:AddToggle("AutoFarm", {
 Title   = "Auto Farm (Quest)",
 Default = false
})
AutoFarmToggle:OnChanged(function()
 local active = Options.AutoFarm.Value
 AutoFarm.active = active
 if active then
  notify("Auto Farm: ON", 3)
  setAutoFarmStatus("Idle", "Đang bật — chờ Quest")
  task.spawn(autoFarmLoop)
 else
  notify("Auto Farm: OFF", 2)
  setFaceMode(false)
  -- Stop() = isNavigating=false + ownerToken++ + CleanupPhysics → FlyTo loop đang chạy
  -- phải thoát ngay ở heartbeat kế tiếp (CleanupPhysics trần chỉ xóa BV, loop sẽ tự tạo lại!)
  pcall(function() FlyPathfinder.Stop() end)
  setAutoFarmStatus("Off", "Auto Farm đã tắt")
 end
end)
Options.AutoFarm:SetValue(false)

local AutoFarmSpeed = Tabs.Main:AddSlider("AutoFarmSpeed", {
 Title       = "Auto Farm Speed",
 Description = "Toc do bay toi target (studs/giay)",
 Default     = 75,
 Min         = 20,
 Max         = 200,
 Rounding    = 1,
 Callback    = function(value)
  AutoFarm.speed = value
 end
})

local MultiAttackToggle = Tabs.Main:AddToggle("MultiAttack", {
 Title       = "Multi Attack",
 Description = "1 cú chém trúng nhiều quái đứng gần nhau (tối đa 4 con)",
 Default     = true,
})
MultiAttackToggle:OnChanged(function()
 MultiAttack.enabled = Options.MultiAttack.Value
 notify("Multi Attack: " .. (MultiAttack.enabled and "ON" or "OFF"), 2)
end)
Options.MultiAttack:SetValue(true)

local AutoQuestToggle = Tabs.Main:AddToggle("AutoQuest", {
 Title       = "Auto Quest",
 Description = "Tự bay tới NPC quest + nhận quest (chỉ invoke khi NPC trong 5 studs). CẢNH BÁO: gọi remote Quest sai cách = BAN — test trên alt trước!",
 Default     = false,
})
AutoQuestToggle:OnChanged(function()
 notify("Auto Quest: " .. (Options.AutoQuest.Value and "ON" or "OFF"), 2)
end)

-- ==============================================================================
-- IMPEL DOWN: SMART FLY WAYPOINTS + CHEST LOOT + AUTO STATS + COMBAT
-- Chạy trong function riêng: executor chỉ cho tối đa 200 local/function
-- ==============================================================================

local function initImpelDownModule()

local SWORD_TIERS = {
    ["yoru"]          = 1,
    ["dark blade"]    = 1,
    ["roger's ace"]   = 2,
    ["ace"]           = 2,
    ["gravity blade"] = 3,
    ["kiribachi"]     = 4,
    ["katana"]        = 5,
}

local HELMET_TIERS = {
    ["sunken armor helmet"] = 1,
    ["sunken helmet"]       = 1,
    ["helmet"]              = 2,
}

local OUTFIT_TIERS = {
    ["mochi emperor's outfit"]         = 1,
    ["mochi emperor"]                  = 1,
    ["resurrected ba'al's outfit 2.0"] = 2,
    ["ba'al's outfit"]                 = 2,
    ["ba'al"]                          = 2,
}

-- Load WayPoints từ GitHub (file định nghĩa WayPoint_Floor2, không return sẵn)
local ImpelWayPoints_Raw = nil
pcall(function()
    local src = game:HttpGet(
        "https://raw.githubusercontent.com/NguyenTriThuc2010/Info-Game/main/WayPoint.lua"
    )
    local res = loadstring(src .. "\nreturn WayPoint_Floor2")()
    if type(res) == "table" then
        ImpelWayPoints_Raw = res
    end
end)

if not ImpelWayPoints_Raw then
    ImpelWayPoints_Raw = {
        ["w-3"] = {Vector3.new(2664.0088, 2075.4463, -15527.9209)}, -- Setup & Loot
        ["w-2"] = {Vector3.new(2952.1421, 2075.4463, -13970.9990)}, -- Setup & Loot
        ["w-1"] = {Vector3.new(2662.7590, 2075.4463, -15383.0781)}, -- Setup & Loot
        ["w1"]  = {Vector3.new(3204.1733, 2380.4231, -20268.9473)},
        ["w2"]  = {Vector3.new(3201.6421, 2378.4231, -20396.3691)},
        ["w3"]  = {Vector3.new(2924.6733, 2378.4231, -20395.4941)},
        ["w4"]  = {Vector3.new(2918.0952, 2378.3762, -20565.9004)},
        ["w5"]  = {Vector3.new(3198.9077, 2343.3762, -20535.4473)},
        ["w6"]  = {Vector3.new(2730.2200, 2380.3762, -20648.1660)},
        ["w7"]  = {Vector3.new(2447.0793, 2380.3762, -20649.7441)},
        ["w8"]  = {Vector3.new(3196.4233, 2378.4231, -20407.6816)},
        ["w9"]  = {Vector3.new(3199.0015, 2378.3762, -20620.8848)},
        ["w10"] = {Vector3.new(3197.8296, 2375.4856, -20732.7754)}, -- end floor 1
        ["w11"] = {Vector3.new(4964.9712, 2306.3293, -20695.0566)},
        ["w12"] = {Vector3.new(4780.8774, 2306.3293, -20771.0879)},
        ["w13"] = {Vector3.new(5132.0215, 2308.0579, -20791.3262)},
        ["w14"] = {Vector3.new(5161.8618, 2306.3293, -20798.8223)},
        ["w15"] = {Vector3.new(4943.2056, 2333.3293, -20909.9941)},
        ["w16"] = {Vector3.new(4844.4917, 2368.3293, -20992.8125)},
        ["w17"] = {Vector3.new(4845.2363, 2398.8293, -20870.1191)},
        ["w18"] = {Vector3.new(5269.4868, 2398.1262, -20806.8691)},
        ["w19"] = {Vector3.new(5535.2056, 2405.8293, -20811.5723)},
        ["w20"] = {Vector3.new(5598.9399, 2499.8293, -20958.6035)},
        ["w21"] = {Vector3.new(5668.8779, 2481.7200, -20526.8535)}, -- end floor 2
    }
end

-- Waypoint đánh dấu hết 1 floor mê cung (ưu tiên tìm Effects.Zones.End)
local MAZE_END_KEYS = {
    ["w10"] = true,
    ["w21"] = true,
}

IMPEL_WAYPOINTS = {}
do
    local keys = {}
    for k in pairs(ImpelWayPoints_Raw) do
        if type(k) == "string" and k ~= "" and k:match("^w%-?%d+$") then
            table.insert(keys, k)
        end
    end

    -- Sắp xếp số âm và số dương: w-3 (-3) < w-2 (-2) < w-1 (-1) < w1 (1) < w10 (10)
    table.sort(keys, function(a, b)
        local na = tonumber(a:match("%-?%d+")) or 0
        local nb = tonumber(b:match("%-?%d+")) or 0
        return na < nb
    end)

    for _, k in ipairs(keys) do
        local entry = ImpelWayPoints_Raw[k]
        local pos = (type(entry) == "table" and entry[1]) or (typeof(entry) == "Vector3" and entry)
        if pos and typeof(pos) == "Vector3" then
            table.insert(IMPEL_WAYPOINTS, {
                Key = k,
                Position = pos,
                IsMazeEnd = MAZE_END_KEYS[k] == true,
            })
        end
    end
end

ImpelNav = {
    active            = false,
    currentWP         = 1,
    currentKey        = "w-3", -- Key chuẩn của W hiện tại (ưu tiên hơn index)
    spawnKey          = "w-3", -- Checkpoint: tắt/bật lại sẽ resume từ đây (không về w-3)
    statusLabel       = nil,
    currentStatus     = "Idle", -- "Bay", "Farm", "Loot", "OpenLock", "Idle"
    currentBV         = nil,
    currentGyro       = nil,
    taskThread        = nil,
    activeLootTasks   = {},
    ignoreMonsterTargets = false, -- true khi bay hành lang w-2 ↔ w-3
}

-- Forward decl: Key handcuff gate (định nghĩa đầy đủ ở HANDCUFF KEY UNLOCK ENGINE)
local playerHandcuffKeyStillExists, ensureHandcuffsUnlockedBeforeNextWP, unlockHandcuffsIfCuffed
local findMyHandcuffKey

local IMPEL_SPAWN_FILE = "WarFruit_ImpelSpawn.txt"

local function findWPIndexByKey(key)
    if not key or key == "" then return nil end
    for i, wp in ipairs(IMPEL_WAYPOINTS) do
        if wp.Key == key then return i end
    end
    return nil
end

local function getWaypointByKey(key)
    local idx = findWPIndexByKey(key)
    return idx and IMPEL_WAYPOINTS[idx] or nil, idx
end

-- Luôn lấy đúng waypoint cho "W hiện tại" theo Key (không tin index lệch)
local function resolveCurrentWaypoint()
    if #IMPEL_WAYPOINTS == 0 then
        return nil, nil
    end

    -- 1) Ưu tiên currentKey / spawnKey
    local key = ImpelNav.currentKey or ImpelNav.spawnKey
    if key and key ~= "" then
        local wp, idx = getWaypointByKey(key)
        if wp and idx then
            ImpelNav.currentWP = idx
            ImpelNav.currentKey = wp.Key
            return wp, idx
        end
    end

    -- 2) Theo index hợp lệ
    local idx = tonumber(ImpelNav.currentWP)
    if idx and idx >= 1 and idx <= #IMPEL_WAYPOINTS then
        local wp = IMPEL_WAYPOINTS[idx]
        ImpelNav.currentWP = idx
        ImpelNav.currentKey = wp.Key
        return wp, idx
    end

    -- 3) Fallback: WP gần nhất với người chơi (trong 50 studs)
    local pos = getPlayerPosition and getPlayerPosition() or nil
    if pos then
        local bestIdx, bestDist = nil, 50
        for i, wp in ipairs(IMPEL_WAYPOINTS) do
            local d = (wp.Position - pos).Magnitude
            if d < bestDist then
                bestDist = d
                bestIdx = i
            end
        end
        if bestIdx then
            local wp = IMPEL_WAYPOINTS[bestIdx]
            ImpelNav.currentWP = bestIdx
            ImpelNav.currentKey = wp.Key
            ImpelNav.spawnKey = wp.Key
            print(string.format("📌 [ImpelDown] Đồng bộ W hiện tại theo vị trí → [%s]", wp.Key))
            return wp, bestIdx
        end
    end

    -- 4) Cuối cùng: w đầu danh sách
    local wp = IMPEL_WAYPOINTS[1]
    ImpelNav.currentWP = 1
    ImpelNav.currentKey = wp.Key
    return wp, 1
end

function setCurrentWaypointByKey(key)
    local wp, idx = getWaypointByKey(key)
    if not wp then
        warn(string.format("⚠️ [ImpelDown] Không tìm thấy waypoint key '%s'", tostring(key)))
        return nil, nil
    end
    ImpelNav.currentWP = idx
    ImpelNav.currentKey = wp.Key
    ImpelNav.spawnKey = wp.Key
    return wp, idx
end

local function getNextWaypoint(currentIdx)
    local idx = (currentIdx or ImpelNav.currentWP or 0) + 1
    if idx < 1 or idx > #IMPEL_WAYPOINTS then
        return nil, nil
    end
    return IMPEL_WAYPOINTS[idx], idx
end

-- Hành lang setup w-2 ↔ w-3: không đánh / không đuổi Target
local function isW2W3Pair(a, b)
    a, b = tostring(a or ""), tostring(b or "")
    return (a == "w-2" and b == "w-3") or (a == "w-3" and b == "w-2")
end

local function shouldIgnoreTargetsForFlightTo(destKey)
    destKey = tostring(destKey or "")
    if destKey ~= "w-2" and destKey ~= "w-3" then return false end
    local otherKey = (destKey == "w-2") and "w-3" or "w-2"
    local dest = getWaypointByKey(destKey)
    local other = getWaypointByKey(otherKey)
    local pos = getPlayerPosition and getPlayerPosition()
    if not (dest and other and pos) then return false end
    local dDest = (pos - dest.Position).Magnitude
    local dOther = (pos - other.Position).Magnitude
    -- Còn xa đích và đang gần (hoặc vừa rời) WP kia → đang đi w-2 ↔ w-3
    return dDest > 150 and dOther < 500
end

local function beginIgnoreMonsterTargets(reason)
    ImpelNav.ignoreMonsterTargets = true
    print("🚫 [ImpelDown] Bỏ qua Target quái (" .. tostring(reason) .. ")")
end

local function endIgnoreMonsterTargets()
    ImpelNav.ignoreMonsterTargets = false
end

local function withIgnoreMonsterTargets(reason, fn)
    beginIgnoreMonsterTargets(reason)
    local ok, result = pcall(fn)
    endIgnoreMonsterTargets()
    if not ok then
        warn("⚠️ [ImpelDown] Transit w-2/w-3 lỗi: " .. tostring(result))
        return false
    end
    return result
end

function saveImpelSpawn(key)
    if not key or key == "" then return end
    local wp, idx = getWaypointByKey(key)
    if not wp then
        warn(string.format("⚠️ [ImpelDown] Bỏ qua save spawn — key '%s' không có trong danh sách WP", tostring(key)))
        return
    end
    ImpelNav.spawnKey = wp.Key
    ImpelNav.currentKey = wp.Key
    ImpelNav.currentWP = idx
    pcall(function()
        if writefile then writefile(IMPEL_SPAWN_FILE, tostring(wp.Key)) end
    end)
    print(string.format("📌 [ImpelDown] Đã set spawn checkpoint: [%s] (index %d)", wp.Key, idx))
end

local function loadImpelSpawn()
    local key = nil
    pcall(function()
        if isfile and readfile and isfile(IMPEL_SPAWN_FILE) then
            key = tostring(readfile(IMPEL_SPAWN_FILE)):gsub("%s+", "")
        end
    end)
    if key and key ~= "" then
        local wp, idx = getWaypointByKey(key)
        if wp then
            ImpelNav.spawnKey = wp.Key
            ImpelNav.currentKey = wp.Key
            ImpelNav.currentWP = idx
            return wp.Key
        end
    end
    local fallback = (IMPEL_WAYPOINTS[1] and IMPEL_WAYPOINTS[1].Key) or "w-3"
    ImpelNav.spawnKey = fallback
    ImpelNav.currentKey = fallback
    ImpelNav.currentWP = 1
    return fallback
end

-- Bay tới WP (BodyVelocity) — KHÔNG CFrame teleport (anti-cheat)
function teleportToWaypoint(wp)
    if not wp or not wp.Position then return false end
    local hrp = getHumanoidRootPart()
    if not hrp then return false end

    local dest = wp.Position + Vector3.new(0, 4, 0)
    local dist = (hrp.Position - dest).Magnitude
    if dist <= 8 then
        if wp.Key then setCurrentWaypointByKey(wp.Key) end
        return true
    end

    if FlyPathfinder and FlyPathfinder.isNavigating then
        pcall(function() FlyPathfinder.Stop() end)
    end

    local speed = 75
    pcall(function()
        speed = tonumber(Options and Options.ImpelSpeed and Options.ImpelSpeed.Value) or 75
    end)
    speed = math.clamp(speed, 30, 120)

    local arrived = false
    local function doFly()
        if FlyPathfinder and FlyPathfinder.FlyTo then
            -- Gần: DirectLow; xa: Smart3D rồi DirectLow tinh chỉnh
            if dist <= 150 then
                arrived = FlyPathfinder.FlyTo(dest, speed, "DirectLow", "impeldown")
            else
                arrived = FlyPathfinder.FlyTo(dest, speed, "Smart3D", "impeldown")
                hrp = getHumanoidRootPart()
                if hrp and (hrp.Position - dest).Magnitude > 25 then
                    arrived = FlyPathfinder.FlyTo(dest, math.min(speed, 70), "DirectLow", "impeldown") or arrived
                end
            end
        end
    end
    if shouldIgnoreTargetsForFlightTo(wp.Key) then
        withIgnoreMonsterTargets("bay " .. tostring(wp.Key) .. " (hành lang w-2 ↔ w-3)", doFly)
    else
        doFly()
    end

    hrp = getHumanoidRootPart()
    local nearEnough = hrp and (hrp.Position - wp.Position).Magnitude <= 25
    if wp.Key then
        setCurrentWaypointByKey(wp.Key)
    end
    return arrived or nearEnough == true
end

pcall(loadImpelSpawn)

local function impelCleanupPhysics()
    if ImpelNav.currentBV and ImpelNav.currentBV.Parent then
        pcall(function() ImpelNav.currentBV:Destroy() end)
    end
    ImpelNav.currentBV = nil

    if ImpelNav.currentGyro and ImpelNav.currentGyro.Parent then
        pcall(function() ImpelNav.currentGyro:Destroy() end)
    end
    ImpelNav.currentGyro = nil

    if FlyPathfinder and FlyPathfinder.CleanupPhysics then
        pcall(FlyPathfinder.CleanupPhysics)
    end

    local hrp = getHumanoidRootPart()
    if hrp then
        for _, child in ipairs(hrp:GetChildren()) do
            if child:IsA("BodyVelocity") or child:IsA("BodyGyro") or child:IsA("BodyPosition")
            or child:IsA("LinearVelocity") or child:IsA("AlignOrientation") then
                pcall(function() child:Destroy() end)
            end
        end
        pcall(function()
            hrp.Velocity = Vector3.zero
            hrp.RotVelocity = Vector3.zero
        end)
    end

    local hum = getHumanoid()
    if hum then
        hum.PlatformStand = false
        pcall(function() hum:ChangeState(Enum.HumanoidStateType.GettingUp) end)
    end

    pcall(stopFly)
end

impelSetStatus = function(status, detail)
    if not status then return end
    local validStatuses = {
        Bay             = true,
        Farm            = true,
        Looting         = true,
        Loot            = true,
        updateStats     = true,
        UpdateStats     = true,
        OpenLock        = true,
        CheckInventory  = true,
        Pathfind        = true,
        TimDuong        = true,
        Idle            = true,
    }
    local currentTag = "Idle"
    local descText = ""

    if validStatuses[status] then
        currentTag = status
        descText = detail or ""
    else
        descText = tostring(status)
        if string.find(descText, "còng") or string.find(descText, "Key") then
            currentTag = "OpenLock"
        elseif string.find(descText, "mê cung") or string.find(descText, "Pathfind") or string.find(descText, "tìm đường") or string.find(descText, "Tìm đường") then
            currentTag = "Pathfind"
        elseif string.find(descText, "Bay") or string.find(descText, "bay") then
            currentTag = "Bay"
        elseif string.find(descText, "đánh") or string.find(descText, "quái") or string.find(descText, "kill") then
            currentTag = "Farm"
        elseif string.find(descText, "rương") or string.find(descText, "Loot") or string.find(descText, "nhặt") then
            currentTag = "Looting"
        elseif string.find(descText, "Stat") or string.find(descText, "stat") or string.find(descText, "Haki") then
            currentTag = "UpdateStats"
        elseif string.find(descText, "kiếm") or string.find(descText, "Kiếm") or string.find(descText, "Backpack") or string.find(descText, "túi") then
            currentTag = "CheckInventory"
        end
    end

    if currentTag == "Loot" then currentTag = "Looting" end
    if currentTag == "updateStats" then currentTag = "UpdateStats" end
    if currentTag == "TimDuong" then currentTag = "Pathfind" end

    ImpelNav.currentStatus = currentTag
    local icons = {
        Bay             = "✈️ Bay",
        Farm            = "⚔️ Farm",
        Looting         = "📦 Looting",
        UpdateStats     = "📊 UpdateStats",
        OpenLock        = "🔑 OpenLock",
        CheckInventory  = "🎒 CheckInventory",
        Pathfind        = "🧭 Tìm đường",
        Idle            = "⏸️ Idle",
    }
    local titleText = string.format("Trạng thái: %s", icons[currentTag] or currentTag)

    if ImpelNav.statusLabel then
        pcall(function()
            ImpelNav.statusLabel:SetTitle(titleText)
            if descText ~= "" then
                ImpelNav.statusLabel:SetDesc(descText)
            end
        end)
    end
    setSharedStatus("ImpelDown", currentTag, descText)
    print(string.format("[ImpelDown][%s] %s", currentTag, descText))
end

-- Kiểm tra kiếm trực tiếp trong LocalPlayer.Backpack
-- Chỉ cần Tool có child "SwordEquip" là kiếm
local function checkSwordInBackpack()
    local backpack = LocalPlayer:FindFirstChild("Backpack")
    local char = LocalPlayer.Character

    local function scanContainer(container)
        if not container then return false, nil end
        for _, tool in ipairs(container:GetChildren()) do
            if tool:IsA("Tool") and tool:FindFirstChild("SwordEquip") then
                return true, tool.Name
            end
        end
        return false, nil
    end

    local foundInBackpack, nameB = scanContainer(backpack)
    if foundInBackpack then return true, nameB, "Backpack" end

    local foundInChar, nameC = scanContainer(char)
    if foundInChar then return true, nameC, "Character" end

    return false, nil, nil
end

-- Stats & Inventory Helper Functions
local function getPlayerStatsFolder()
    local folder = game.ReplicatedStorage:FindFirstChild("Stats" .. Player.Name)
    if not folder then
        local mainStats = game.ReplicatedStorage:FindFirstChild("Stats")
        if mainStats then folder = mainStats:FindFirstChild(Player.Name) end
    end
    return folder
end

local function getBusoMasteryValue()
    local pStats = getPlayerStatsFolder()
    local s = pStats and pStats:FindFirstChild("Stats")
    local buso = s and s:FindFirstChild("BusoMastery")
    return (buso and tonumber(buso.Value)) or 0
end

local function getInventoryTable()
    local pStats = getPlayerStatsFolder()
    local invFolder = pStats and pStats:FindFirstChild("Inventory")
    local invObj = invFolder and invFolder:FindFirstChild("Inventory")
    if invObj and invObj:IsA("StringValue") and invObj.Value ~= "" then
        local HttpService = game:GetService("HttpService")
        local ok, parsed = pcall(function() return HttpService:JSONDecode(invObj.Value) end)
        if ok and type(parsed) == "table" then return parsed end
    end
    return {}
end

local function hasItemInInventory(itemName)
    local inv = getInventoryTable()
    local count = inv[itemName]
    if count and count > 0 then return true, count end
    local lower = string.lower(itemName)
    for k, v in pairs(inv) do
        if string.lower(k) == lower and v > 0 then return true, v end
    end
    return false, 0
end

local function getBestSwordTierInInventory()
    local inv = getInventoryTable()
    local best = math.huge
    for k, v in pairs(inv) do
        local lowerKey = string.lower(k)
        for sName, sTier in pairs(SWORD_TIERS) do
            if string.find(lowerKey, sName) and (v == true or (type(v) == "number" and v > 0)) then
                if sTier < best then best = sTier end
            end
        end
    end
    return best
end

local function getBestHelmetTierInInventory()
    local inv = getInventoryTable()
    local best = math.huge
    for k, v in pairs(inv) do
        local lowerKey = string.lower(k)
        for hName, hTier in pairs(HELMET_TIERS) do
            if string.find(lowerKey, hName) and (v == true or (type(v) == "number" and v > 0)) then
                if hTier < best then best = hTier end
            end
        end
    end
    return best
end

local function getBestOutfitTierInInventory()
    local inv = getInventoryTable()
    local best = math.huge
    for k, v in pairs(inv) do
        local lowerKey = string.lower(k)
        for oName, oTier in pairs(OUTFIT_TIERS) do
            if string.find(lowerKey, oName) and (v == true or (type(v) == "number" and v > 0)) then
                if oTier < best then best = oTier end
            end
        end
    end
    return best
end

-- Helper getNil tìm RemoteEvent trong nil instances
local function getNil(name, class)
    if not getnilinstances then return nil end
    local ok, list = pcall(getnilinstances)
    if ok and type(list) == "table" then
        for _, v in next, list do
            if v.ClassName == class and v.Name == name then
                return v
            end
        end
    end
    return nil
end

local function equipToolByKeyword(keyword)
    local char = LocalPlayer.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if not char or not hum then return false end

    local lowerKey = string.lower(keyword)

    -- Kiểm tra nếu đang cầm trên tay
    for _, t in ipairs(char:GetChildren()) do
        if t:IsA("Tool") and string.find(string.lower(t.Name), lowerKey) then
            return true, t
        end
    end

    -- Tìm trong Backpack để cầm lên tay
    local backpack = LocalPlayer:FindFirstChild("Backpack")
    if backpack then
        for _, t in ipairs(backpack:GetChildren()) do
            if t:IsA("Tool") and string.find(string.lower(t.Name), lowerKey) then
                hum:EquipTool(t)
                task.wait(0.25)
                return true, t
            end
        end
    end

    return false
end

-- Tự động kích hoạt Haki nếu có Spirit Essence trong người (chỉ 1 lần)
local _hakiAlreadyActivated = false
local function autoCheckAndActivateHaki()
    -- Kiểm tra Haki có đang bật vĩnh viễn không (trường hợp Impel Down)
    local pStats = getPlayerStatsFolder()
    local statsChild = pStats and pStats:FindFirstChild("Stats")
    local busoActivated = statsChild and statsChild:FindFirstChild("BusoActivated")
    if busoActivated and busoActivated.Value == true then
        print("✨ [AutoHaki] Haki đang BẬT VĨNH VIỄN (BusoActivated = true) → Không cần dùng Spirit Essence.")
        _hakiAlreadyActivated = true
        return true
    end

    -- Kiểm tra BusoMastery: nếu đã có Haki (> 0) rồi thì bỏ qua
    local busoVal = getBusoMasteryValue()
    if busoVal > 0 then
        print(string.format("✨ [AutoHaki] Đã có Haki rồi (BusoMastery = %d) → Không cần dùng Spirit Essence.", busoVal))
        _hakiAlreadyActivated = true
        return true
    end

    if _hakiAlreadyActivated then return false end

    -- Thử cầm Spirit Essence nếu có
    equipToolByKeyword("Spirit Essence")

    print("🔮 [AutoHaki] Kích hoạt Haki bằng Spirit Essence...")
    local args = { true }

    -- 1. Tìm qua getNil("RemoteEvent", "RemoteEvent")
    local nilEvent = getNil("RemoteEvent", "RemoteEvent")
    if nilEvent then
        pcall(function() nilEvent:FireServer(unpack(args)) end)
        print("✅ [AutoHaki] ĐÃ TỰ ĐỘNG KÍCH HOẠT HAKI QUA GETNIL THÀNH CÔNG!")
        _hakiAlreadyActivated = true
        task.wait(0.3)
        return true
    end

    -- 2. Fallback: Instance.new("RemoteEvent", nil):FireServer(unpack(args))
    pcall(function()
        local re = Instance.new("RemoteEvent", nil)
        re:FireServer(unpack(args))
    end)
    print("✨ [AutoHaki] ĐÃ GỬI REMOTEEVENT(NIL) KÍCH HOẠT HAKI THÀNH CÔNG!")
    _hakiAlreadyActivated = true
    task.wait(0.3)
    return true
end

-- Tự động dùng SP Reset Essence nếu stats bị lệch (chưa đạt Def 775)
local function autoCheckAndResetStats(targetDefense)
    targetDefense = targetDefense or 775
    local pStats = getPlayerStatsFolder()
    if not pStats then return false end
    local s = pStats:FindFirstChild("Stats")
    if not s then return false end

    local defObj = s:FindFirstChild("Defense")
    local swordObj = s:FindFirstChild("SwordMastery")
    local strObj = s:FindFirstChild("Strength")
    local gunObj = s:FindFirstChild("GunMastery")
    local fruitObj = s:FindFirstChild("DevilFruitMastery")

    local curDef = defObj and tonumber(defObj.Value) or 0
    local curSword = swordObj and tonumber(swordObj.Value) or 0
    local curStr = strObj and tonumber(strObj.Value) or 0
    local curGun = gunObj and tonumber(gunObj.Value) or 0
    local curFruit = fruitObj and tonumber(fruitObj.Value) or 0

    local isMisallocated = (curStr > 0) or (curGun > 0) or (curFruit > 0) or (curDef ~= targetDefense and curSword > 0)
    if not isMisallocated then return false end

    local hasReset, tool = equipToolByKeyword("sp reset")
    if not hasReset then hasReset, tool = equipToolByKeyword("reset essence") end

    if hasReset then
        print(string.format("🔄 [AutoReset] Stats chưa chuẩn (Def: %d/%d) & có SP Reset Essence -> Tự động Reset...", curDef, targetDefense))
        local ok, nilInst = pcall(getNilRemote, "RemoteEvent", "RemoteEvent")
        if ok and nilInst then
            pcall(function() nilInst:FireServer(true) end)
            print("✅ [AutoReset] Đã gửi lệnh Reset Stats! Đợi cập nhật điểm...")
            task.wait(0.6)
            return true
        end
    end
    return false
end

-- Auto Stat Allocation (Defense = 775 -> Kiếm)
function autoAllocateStats(targetDefense)
    targetDefense = targetDefense or 775

    -- 1. Tự động dùng Spirit Essence mở Haki nếu có trong người
    autoCheckAndActivateHaki()

    -- 2. Tự động dùng SP Reset Essence nếu stats bị lệch
    autoCheckAndResetStats(targetDefense)

    -- 3. Nâng điểm SkillPoints hiện có
    local pStats = getPlayerStatsFolder()
    if not pStats then return end
    local s = pStats:FindFirstChild("Stats")
    if not s then return end

    local spObj = s:FindFirstChild("SkillPoints")
    local defObj = s:FindFirstChild("Defense")
    local swordObj = s:FindFirstChild("SwordMastery")
    if not spObj then return end

    local sp = tonumber(spObj.Value) or 0
    if sp <= 0 then return end

    local curDef = defObj and tonumber(defObj.Value) or 0
    local statsEv = Event and Event:FindFirstChild("stats")
    if not statsEv then return end

    -- Nâng Defense trước
    if curDef < targetDefense then
        local needed = targetDefense - curDef
        local addDef = math.min(needed, sp)
        if addDef > 0 then
            print(string.format("🛡️ [AutoStat] Nâng %d điểm vào Defense (%d/%d)...", addDef, curDef, targetDefense))
            for i = 1, addDef do
                pcall(function() statsEv:FireServer("Defense", nil, 1) end)
                task.wait(0.02)
            end
            sp = sp - addDef
        end
    end

    -- Dồn hết còn lại vào SwordMastery
    if sp > 0 then
        print(string.format("⚔️ [AutoStat] Nâng %d điểm còn lại vào SwordMastery...", sp))
        for i = 1, sp do
            pcall(function() statsEv:FireServer("SwordMastery", nil, 1) end)
            task.wait(0.02)
        end
    end
end

-- Chest & Loot System
local function forceTriggerPrompt(prompt)
    if not prompt or not prompt.Parent or not prompt.Enabled then return false end
    pcall(function()
        prompt.HoldDuration = 0
        prompt.RequiresLineOfSight = false
    end)
    pcall(function() fireproximityprompt(prompt) end)
    pcall(function() fireproximityprompt(prompt, 0) end)
    pcall(function() fireproximityprompt(prompt, 0, true) end)
    pcall(function() game:GetService("ProximityPromptService"):FirePromptTriggered(prompt) end)
    pcall(function()
        prompt:InputHoldBegin()
        task.defer(function() pcall(function() prompt:InputHoldEnd() end) end)
    end)
    return true
end

local function identifyLootItem(item)
    if not item or not item.Parent then return nil, nil end
    local pp = item:FindFirstChildWhichIsA("ProximityPrompt", true)
    if not pp then return nil, nil end

    local name = string.lower(item.Name)
    local objText = pp.ObjectText and string.lower(pp.ObjectText) or ""
    local combined = name .. " | " .. objText

    if string.find(combined, "spirit essence") then
        return "Spirit Essence", "essence"
    elseif string.find(combined, "sp reset essence") or string.find(combined, "sp reset") then
        return "SP Reset Essence", "essence"
    elseif string.find(combined, "mochi emperor's outfit") or string.find(combined, "mochi emperor") then
        return "Mochi Emperor's Outfit", "outfit", 1
    elseif string.find(combined, "ba'al's outfit") or string.find(combined, "resurrected ba'al") then
        return "Resurrected Ba'al's Outfit 2.0", "outfit", 2
    elseif string.find(combined, "anniversary lantern") then
        return "Anniversary Lantern", "item"
    elseif string.find(combined, "virtuous cupid queen's wings") or string.find(combined, "cupid queen's wings") or string.find(combined, "cupid queen") then
        return "Virtuous Cupid Queen's Wings", "cape"
    elseif string.find(combined, "yoru") or string.find(combined, "dark blade") then
        return "Yoru", "sword", 1
    elseif string.find(combined, "roger's ace") or (string.find(combined, "ace") and (string.find(combined, "sword") or string.find(combined, "blade") or objText ~= "")) then
        return "Roger's Ace", "sword", 2
    elseif string.find(combined, "gravity blade") then
        return "Gravity Blade", "sword", 3
    elseif string.find(combined, "kiribachi") then
        return "Kiribachi", "sword", 4
    elseif string.find(combined, "ryu's katana") or string.find(combined, "katana") then
        return item.Name, "sword", 5
    elseif string.find(combined, "sunken armor helmet") or string.find(combined, "sunken helmet") then
        return "Sunken Armor Helmet", "helmet", 1
    elseif string.find(combined, "helmet") then
        return item.Name, "helmet", 2
    end
    return nil, nil
end

local function isChestModel(model)
    if not model or not model:IsA("Model") then return false end
    local matched = 0
    for _, name in ipairs({ "Lock", "Model", "Top" }) do
        if model:FindFirstChild(name) then matched = matched + 1 end
    end
    return matched >= 2
end

local function hasAnySword()
    local has, _ = checkSwordInBackpack()
    return has
end

local function checkAndEnforceWeaponLoot()
    if not hasAnySword() then
        if Options and Options.ImpelChestLoot and not Options.ImpelChestLoot.Value then
            Options.ImpelChestLoot:SetValue(true)
            notify("⚠️ Không có kiếm trong người! Đã tự động BẬT mở rương & nhặt đồ rơi.", 5)
            print("⚠️ [ImpelDown] Không tìm thấy Kiếm -> Tự động BẬT Mở rương & Nhặt đồ!")
        end
        return true
    end
    return false
end

local function getChestRootPart(model)
    if not model then return nil end
    local top = model:FindFirstChild("Top")
    if top then
        if top:IsA("BasePart") then return top end
        local bp = top:FindFirstChildWhichIsA("BasePart") if bp then return bp end
    end
    local lock = model:FindFirstChild("Lock")
    if lock then
        if lock:IsA("BasePart") then return lock end
        local bp = lock:FindFirstChildWhichIsA("BasePart") if bp then return bp end
    end
    local inner = model:FindFirstChild("Model")
    if inner then
        local bp = inner:FindFirstChildWhichIsA("BasePart") if bp then return bp end
    end
    return model:FindFirstChildWhichIsA("BasePart", true) or model.PrimaryPart
end

local function getChestProximityPrompt(model)
    if not model then return nil end
    local pp = model:FindFirstChildOfClass("ProximityPrompt")
    if pp then return pp end
    for _, child in ipairs(model:GetChildren()) do
        if tonumber(child.Name) then
            local pp2 = child:FindFirstChildOfClass("ProximityPrompt")
            if pp2 then return pp2 end
        end
    end
    return model:FindFirstChildWhichIsA("ProximityPrompt", true)
end

-- Part / Model gốc của item loot (chỗ gắn ProximityPrompt)
local function getLootRootPart(obj, pp)
    if pp and pp.Parent and pp.Parent:IsA("BasePart") then
        return pp.Parent
    end
    if obj and obj:IsA("BasePart") then
        return obj
    end
    if obj and obj:IsA("Model") then
        return obj.PrimaryPart or obj:FindFirstChildWhichIsA("BasePart", true)
    end
    if obj then
        return obj:FindFirstChildWhichIsA("BasePart", true)
    end
    return nil
end

-- Đưa Part item lên sát HumanoidRootPart để nhặt (không dịch chuyển người chơi)
-- Anti-cheat: chỉ move item trong Effects/workspace, không gán hrp.CFrame
local function bringLootToPlayer(obj, pp)
    local hrp = getHumanoidRootPart()
    if not hrp then return false end

    local part = getLootRootPart(obj, pp)
    if not part or not part.Parent then return false end

    -- Đặt Part ngay tại / sát HRP để ProximityPrompt nhận người chơi
    local destCF = hrp.CFrame * CFrame.new(0, 0.5, 0)

    if pp then
        pcall(function()
            pp.HoldDuration = 0
            pp.RequiresLineOfSight = false
            pp.Enabled = true
            if typeof(pp.MaxActivationDistance) == "number" then
                pp.MaxActivationDistance = math.max(pp.MaxActivationDistance, 12)
            end
        end)
    end

    local ok = pcall(function()
        if obj and obj:IsA("Model") then
            for _, p in ipairs(obj:GetDescendants()) do
                if p:IsA("BasePart") then
                    p.Anchored = true
                    p.CanCollide = false
                end
            end
            if obj.PivotTo then
                obj:PivotTo(destCF)
            elseif obj.PrimaryPart then
                obj:SetPrimaryPartCFrame(destCF)
            else
                local root = getLootRootPart(obj, pp)
                if root then
                    local delta = destCF.Position - root.Position
                    for _, p in ipairs(obj:GetDescendants()) do
                        if p:IsA("BasePart") then
                            p.CFrame = p.CFrame + delta
                        end
                    end
                end
            end
            return
        end

        -- BasePart đơn / object lỏng
        local delta = destCF.Position - part.Position
        local container = obj or part
        if container:IsA("BasePart") then
            container.Anchored = true
            container.CanCollide = false
            container.CFrame = destCF
        else
            for _, p in ipairs(container:GetDescendants()) do
                if p:IsA("BasePart") then
                    p.Anchored = true
                    p.CanCollide = false
                    p.CFrame = p.CFrame + delta
                end
            end
            if part:IsA("BasePart") then
                part.Anchored = true
                part.CanCollide = false
                part.CFrame = destCF
            end
        end
    end)

    return ok == true
end

-- Nhặt item: bay tới → kéo Part lên HRP → fire prompt (định nghĩa sau flyCloseForInteract)
local pickupLootItem

-- Sky Cruise Flight Engine for Waypoints
local function getHighestAltitudeOnPath(startP, endP)
    local maxY = math.max(startP.Y, endP.Y)
    local hDist = Vector3.new(endP.X - startP.X, 0, endP.Z - startP.Z).Magnitude
    local count = math.clamp(math.floor(hDist / 40), 3, 20)
    local rp = RaycastParams.new()
    rp.FilterType = Enum.RaycastFilterType.Exclude
    rp.FilterDescendantsInstances = { Character }
    rp.IgnoreWater = true
    for i = 1, count do
        local alpha = i / count
        local mid = startP:Lerp(endP, alpha)
        local res = filterPassThroughHit(workspace:Raycast(Vector3.new(mid.X, 1200, mid.Z), Vector3.new(0, -1400, 0), rp))
        if res and res.Position.Y > maxY then maxY = res.Position.Y end
    end
    return maxY
end

-- Phát hiện địa hình không bằng phẳng (đồi/dốc) dọc đường thẳng — để mode auto
-- chọn Smart3D (PathfindingService nhận diện con đường dốc) thay vì SkyCruise
-- (phóng thẳng đứng lên trời). Quét giống getHighestAltitudeOnPath: mỗi 40 studs.
local TERRAIN_ROUGHNESS = 4
local function hasSignificantTerrainChange(startP, endP)
    local hDist = Vector3.new(endP.X - startP.X, 0, endP.Z - startP.Z).Magnitude
    local count = math.clamp(math.floor(hDist / 40), 3, 20)
    local rp = RaycastParams.new()
    rp.FilterType = Enum.RaycastFilterType.Exclude
    rp.FilterDescendantsInstances = { Character }
    rp.IgnoreWater = true
    local minY, maxY, samples = math.huge, -math.huge, 0
    for i = 1, count do
        local alpha = i / count
        local mid = startP:Lerp(endP, alpha)
        local res = filterPassThroughHit(workspace:Raycast(Vector3.new(mid.X, 1200, mid.Z), Vector3.new(0, -1400, 0), rp))
        if res then
            samples = samples + 1
            local y = res.Position.Y
            if y < minY then minY = y end
            if y > maxY then maxY = y end
        end
    end
    if samples < 2 then return false end
    return (maxY - minY) > TERRAIN_ROUGHNESS
end

-- ==============================================================================
--  FLYPATHFINDER ENGINE — ZERO-COLLISION 3D FLIGHT
--  Đảm bảo: (1) không tranh BodyVelocity với Manual/Auto/NavFly
--            (2) không bao giờ đẩy nhân vật vào tường rắn
-- ==============================================================================

FlyPathfinder = {
    Config = {
        FlySpeed             = 75,
        VerticalAscentSpeed  = 90,
        CruiseAltitudeOffset = 35,
        MinCruiseAltitude    = 60,
        ArrivalThreshold     = 2, -- Sát đích để còn E / ProximityPrompt (~5)
        EnableNoClip         = false, -- Giữ va chạm vật lý; né tường bằng steering
        -- Anti-collision
        LookAhead            = 12,   -- studs quét phía trước
        Clearance            = 3.5,  -- bán kính an toàn quanh nhân vật
        NearStopDistance     = 2.2,  -- nếu tường sát hơn mức này → dừng component xuyên tường
    },
    isNavigating = false,
    currentBV    = nil,
    currentGyro  = nil,
    ownerToken   = 0, -- tăng mỗi lần FlyTo / Stop để hủy loop cũ
    currentTask  = nil, -- nhãn mục đích bay: "quest" / "farm" / "hover" / "impeldown" / "misc"
    taskBlocked  = {},  -- map task → timestamp hết hạn chặn (blockTask)
}

-- ================== FLIGHT STAMINA WATCHDOG ==================
-- Khi đang bay (FlyPathfinder) cao > 15 studs so với mặt đất mà stamina
-- không đổi trong 0.15s → Sky Walk bị server từ chối (bay bất hợp pháp)
-- → hủy bay ngay + chặn cất cánh lại vài giây.
local FLIGHT_HEIGHT_MIN          = 15
local STAMINA_FREEZE_LIMIT       = 3
local FLIGHT_BLOCK_AFTER_CANCEL  = 2
local flightBlockedUntil         = 0

-- Lưu tham số FlyTo cuối cùng để auto-resume sau watchdog cancel
local lastFlyToParams            = nil
-- Lưu task bị watchdog hủy để auto-resume sau block hết
local watchdogCancelledTask      = nil

local function cancelFlightByWatchdog(reason)
    -- Lưu thông tin chuyến bay bị hủy để auto-resume sau block hết
    if FlyPathfinder.currentTask and lastFlyToParams then
        watchdogCancelledTask = {
            taskName     = FlyPathfinder.currentTask,
            destination  = lastFlyToParams.destination,
            speed        = lastFlyToParams.speed,
            mode         = lastFlyToParams.mode,
            resumeAfter  = os.clock() + FLIGHT_BLOCK_AFTER_CANCEL
        }
    end
    flightBlockedUntil = os.clock() + FLIGHT_BLOCK_AFTER_CANCEL
    if FlyPathfinder.isNavigating then
        FlyPathfinder.Stop()
    end
    pcall(notify, "[FlightWatchdog] " .. reason, 4)
end

FlyPathfinder.isFlightBlocked = function()
    return os.clock() < flightBlockedUntil
end

-- Dừng/chặn bay theo loại task ("quest", "farm", "impeldown", ...)
FlyPathfinder.isTaskBlocked = function(taskName)
    local untilT = FlyPathfinder.taskBlocked[taskName]
    return untilT and os.clock() < untilT or false
end

FlyPathfinder.blockTask = function(taskName, seconds)
    FlyPathfinder.taskBlocked[taskName] = os.clock() + (seconds or 3)
end

FlyPathfinder.cancelTask = function(taskName, seconds)
    if FlyPathfinder.currentTask == taskName then
        print(string.format("[Fly] Hủy chuyến bay task=%s theo yêu cầu", taskName))
        FlyPathfinder.blockTask(taskName, seconds or 3)
        if FlyPathfinder.isNavigating then
            FlyPathfinder.Stop()
        end
    end
end

local staminaWatch = { lastValue = nil, lastChange = 0 }
RunService.Heartbeat:Connect(function()
    -- AUTO-RESUME: nếu có task bị watchdog hủy và block đã hết → gọi lại FlyTo
    if watchdogCancelledTask and os.clock() >= watchdogCancelledTask.resumeAfter then
        local t = watchdogCancelledTask
        watchdogCancelledTask = nil
        -- Chỉ resume nếu không có flight mới đang chạy và không bị block
        if not FlyPathfinder.isFlightBlocked() and not FlyPathfinder.isNavigating then
            print(string.format("[FlightWatchdog] Auto-resume task=%s sau block %ds", t.taskName, FLIGHT_BLOCK_AFTER_CANCEL))
            FlyPathfinder.FlyTo(t.destination, t.speed, t.mode, t.taskName)
        end
    end

    if not FlyPathfinder.isNavigating then
        staminaWatch.lastValue = nil
        return
    end
    local hrp = getHumanoidRootPart()
    if not (hrp and isPlayerAlive()) then return end

    -- MẶT BIỂN = 1 MẶT ĐẤT: watchdog chỉ quét XUỐNG TỚI TẤM ĐẾ BIỂN 3x3 (y = mặt biển, Sea 1:
    -- -2.7) — chạm đế là DỪNG, KHÔNG scan qua (không tính đỉnh sóng, không xuyên xuống đáy):
    --   - chạm SeaProbe đầu tiên  → đang trên BIỂN → groundY = mặt biển (seaSurfaceY)
    --   - chạm vật rắn khác trước (đảo/đất)      → groundY = Y mặt đất đó
    local groundY = groundOrSeaBelow(hrp.Position)
    local height = groundY and (hrp.Position.Y - groundY) or 300
    if height <= FLIGHT_HEIGHT_MIN then
        staminaWatch.lastValue = nil
        return
    end

    local stamFolder = Stats and Stats:FindFirstChild("Stats")
    local stam = stamFolder and stamFolder:FindFirstChild("Stamina")
    if not stam then return end

    local now = os.clock()
    local v = stam.Value
    if v ~= staminaWatch.lastValue then
        staminaWatch.lastValue = v
        staminaWatch.lastChange = now
    elseif now - staminaWatch.lastChange > STAMINA_FREEZE_LIMIT then
        staminaWatch.lastValue = nil
        cancelFlightByWatchdog(string.format(
            "TASK=%s stamina đứng im %.2fs khi bay cao %.0f studs — HỦY BAY",
            FlyPathfinder.currentTask or "misc", now - staminaWatch.lastChange, height
        ))
    end
end)

-- ================== POSE PIN (GHIM TƯ THẾ) ==================
-- Game dựng thẳng nhân vật khi chạy anim swing (root motion) → ghim lại MỖI FRAME
-- bằng BodyGyro (không ghi hrp.CFrame — anti-cheat). Chạy độc lập với combat loop
-- nên trong lúc callAttack bận chém vẫn giữ được tư thế nằm ngang.
local PosePin = { active = false, dive = false, targetGetter = nil, lastUpdate = 0 }
local function setPosePin(active, dive, targetGetter)
    PosePin.active = active
    PosePin.dive = dive
    PosePin.targetGetter = active and targetGetter or nil
    if active then PosePin.lastUpdate = os.clock() end
end

RunService.Heartbeat:Connect(function()
    if not PosePin.active then return end
    -- An toàn: combat loop ngừng cập nhật 1.5s (exit path sót) → tự tắt pin
    if os.clock() - PosePin.lastUpdate > 1.5 then
        PosePin.active = false
        return
    end
    local gyro = FlyPathfinder.currentGyro
    local hrp = getHumanoidRootPart()
    local t = PosePin.targetGetter and PosePin.targetGetter()
    if not (gyro and gyro.Parent and hrp and t) then return end
    local cf = CFrame.lookAt(hrp.Position, t)
    if PosePin.dive then cf = cf * CFrame.Angles(math.pi / 2, 0, 0) end
    gyro.CFrame = cf
end)

-- Kiểm tra xem 1 Part có thực sự là vật cản cứng chặn đường không (CanCollide = true)
local function isSolidObstacle(part)
    if not part or not part:IsA("BasePart") then return false end
    -- Dùng chung 1 nguồn sự thật: part "ảo" (CanCollide=false, forcefield, Effects...) → đi qua được
    return not isPassThroughPart(part)
end

-- Bắn tia Raycast thông minh xuyên qua các vật thể có thể đi qua (CanCollide = false)
local function castSolidRay(origin, direction, rp, maxAttempts)
    maxAttempts = maxAttempts or 6
    local currentOrigin = origin
    local remainingVector = direction

    local baseExcludes = rp and rp.FilterDescendantsInstances or { Character }
    local customRP = RaycastParams.new()
    customRP.FilterType = Enum.RaycastFilterType.Exclude
    customRP.IgnoreWater = true

    local tempExcludes = {}
    for _, inst in ipairs(baseExcludes) do table.insert(tempExcludes, inst) end

    for i = 1, maxAttempts do
        customRP.FilterDescendantsInstances = tempExcludes
        local result = workspace:Raycast(currentOrigin, remainingVector, customRP)
        if not result then
            return nil -- Đường đi hoàn toàn thông thoáng
        end

        -- Nếu gặp vật cản rắn chắc thực sự (CanCollide = true)
        if isSolidObstacle(result.Instance) then
            return result
        else
            -- Vật thể này đi qua được -> Thêm vào danh sách bỏ qua và tiếp tục bắn tia
            table.insert(tempExcludes, result.Instance)
            local hitPos = result.Position
            local travelled = (hitPos - currentOrigin).Magnitude
            if travelled >= remainingVector.Magnitude - 0.2 then
                return nil
            end
            currentOrigin = hitPos + remainingVector.Unit * 0.05
            remainingVector = (origin + direction) - currentOrigin
            if remainingVector.Magnitude <= 0.2 then
                return nil
            end
        end
    end
    return nil
end

-- Kiểm tra đường nhìn 3D có bị tường cản không (Capsule Raycast đa tia)
local function has3DLineOfSight(fromPos, toPos, ignoreInstances)
    local diff = toPos - fromPos
    local dist = diff.Magnitude
    if dist <= 1 then return true end

    local rp = RaycastParams.new()
    rp.FilterType = Enum.RaycastFilterType.Exclude
    rp.FilterDescendantsInstances = ignoreInstances or { Character }
    rp.IgnoreWater = true

    -- 1. Tia trung tâm (chỉ tính vật cản cứng không đi qua được)
    local hitCenter = castSolidRay(fromPos, diff, rp)
    if hitCenter then return false end

    -- 2. Đa tia 2 bên hông (bán kính 2 studs) để chắc chắn không va quẹt mép tường/cửa
    local dirUnit = diff.Unit
    local rightVec = dirUnit:Cross(Vector3.new(0, 1, 0))
    if rightVec.Magnitude > 0.1 then
        rightVec = rightVec.Unit * 2.0
        local hitLeft = castSolidRay(fromPos - rightVec, diff, rp)
        if hitLeft then return false end
        local hitRight = castSolidRay(fromPos + rightVec, diff, rp)
        if hitRight then return false end
    end

    -- 3. Tia phía trên đầu (+2.5 studs)
    local hitTop = castSolidRay(fromPos + Vector3.new(0, 2.5, 0), diff, rp)
    if hitTop then return false end

    return true
end

-- ================== ZERO-COLLISION STEERING ==================
-- Trả về hướng bay đã lọc: KHÔNG BAO GIỜ có thành phần xuyên vào tường rắn.
local function isDirClear(origin, dir, dist, ignoreInstances)
    if dir.Magnitude < 0.01 then return false end
    local rp = RaycastParams.new()
    rp.FilterType = Enum.RaycastFilterType.Exclude
    rp.FilterDescendantsInstances = ignoreInstances or { Character }
    rp.IgnoreWater = true
    local unit = dir.Unit
    local look = math.max(dist, FlyPathfinder.Config.LookAhead or 12)
    -- Tâm + 4 offset clearance (capsule nhẹ)
    local clearR = FlyPathfinder.Config.Clearance or 3.5
    local right = unit:Cross(Vector3.new(0, 1, 0))
    if right.Magnitude < 0.1 then
        right = unit:Cross(Vector3.new(1, 0, 0))
    end
    right = right.Unit * (clearR * 0.55)
    local up = Vector3.new(0, clearR * 0.55, 0)
    local probes = {
        origin,
        origin + right,
        origin - right,
        origin + up,
        origin - up * 0.4,
    }
    for _, o in ipairs(probes) do
        if castSolidRay(o, unit * look, rp) then
            return false
        end
    end
    return true
end

-- Đo đỉnh của tường đang chắn: đi raycast lên từ điểm trúng đến khi hết chạm
-- Trả về Y đỉnh tường (chưa + margin), hoặc nil nếu không đo được
-- Cache theo vị trí chạm (đổi < 1 stud thì dùng lại kết quả) để không scan lại mỗi frame
local wallTopCache = { pos = nil, topY = nil }
local function getWallTopYFromHit(hit, rp)
    if not hit then return nil end
    local hPos = hit.Position
    if wallTopCache.pos and (hPos - wallTopCache.pos).Magnitude < 1 then
        return wallTopCache.topY
    end
    local y = hPos.Y
    local maxScan = y + 200
    while y < maxScan do
        local upHit = workspace:Raycast(Vector3.new(hPos.X, y + 1, hPos.Z), Vector3.new(0, 20, 0), rp)
        if not upHit then break end
        y = upHit.Position.Y
    end
    local topY = (y < maxScan) and y or nil
    wallTopCache.pos = hPos
    wallTopCache.topY = topY
    return topY
end

-- Giới hạn leo cao: nếu player đã ngang/trên đỉnh tường thì bỏ component lên (đi ngang/slide)
-- Hysteresis: khi đã flatten thì giữ 1s, không toggle mỗi frame → hết giật lên xuống
local climbClampState = { flat = false, deadline = 0 }
local function clampClimbDir(candidate, origin, wallTopY)
    if not candidate then return candidate end
    local now = os.clock()
    local aboveTop = wallTopY and (origin.Y >= wallTopY - 1.5)
    if aboveTop then
        climbClampState.flat = true
        climbClampState.deadline = now + 1.0
    elseif climbClampState.flat and now >= climbClampState.deadline then
        if wallTopY and origin.Y >= wallTopY - 4 then
            climbClampState.deadline = now + 1.0
        else
            climbClampState.flat = false
        end
    end
    if climbClampState.flat and candidate.Y > 0.12 then
        local flat = Vector3.new(candidate.X, 0, candidate.Z)
        if flat.Magnitude > 0.05 then
            return flat.Unit
        end
    end
    return candidate
end

local function resolveCollisionFreeDir(origin, desiredDir, ignoreInstances, preferSide)
    if not desiredDir or desiredDir.Magnitude < 0.01 then
        return Vector3.new(0, 1, 0), preferSide or 0
    end
    local dir = desiredDir.Unit
    local look = FlyPathfinder.Config.LookAhead or 12
    local rp = RaycastParams.new()
    rp.FilterType = Enum.RaycastFilterType.Exclude
    rp.FilterDescendantsInstances = ignoreInstances or { Character }
    rp.IgnoreWater = true

    -- Đường thẳng thông → giữ nguyên
    if isDirClear(origin, dir, look, ignoreInstances) then
        return dir, 0
    end

    local hit = castSolidRay(origin, dir * look, rp)
    local n = hit and hit.Normal or Vector3.new(0, 1, 0)
    -- Đo đỉnh tường đang chắn (chỉ khi cần né) — player ngang đỉnh rồi thì cấm leo tiếp
    local wallTopY = getWallTopYFromHit(hit, rp)

    -- Slide dọc tường (bỏ thành phần xuyên normal)
    local slid = dir - n * dir:Dot(n)
    if slid.Magnitude > 0.12 then
        slid = slid.Unit
        local boosted = (slid + Vector3.new(0, 0.45, 0)).Unit
        boosted = clampClimbDir(boosted, origin, wallTopY)
        if isDirClear(origin, boosted, look * 0.7, ignoreInstances) then
            return boosted, preferSide or 0
        end
        if isDirClear(origin, slid, look * 0.7, ignoreInstances) then
            return slid, preferSide or 0
        end
    end

    -- Ứng viên né: lên / trái / phải (giữ cùng phía nếu đã chọn)
    local right = dir:Cross(Vector3.new(0, 1, 0))
    if right.Magnitude < 0.1 then
        right = Vector3.new(1, 0, 0)
    else
        right = right.Unit
    end
    local side = preferSide or 0
    if side == 0 then
        side = (n:Dot(right) >= 0) and 1 or -1
    end

    local candidates = {
        (dir + Vector3.new(0, 1.8, 0)).Unit,
        (dir + right * side * 1.4 + Vector3.new(0, 1.1, 0)).Unit,
        (right * side + Vector3.new(0, 1.2, 0)).Unit,
        (dir + right * (-side) * 1.4 + Vector3.new(0, 1.1, 0)).Unit,
        Vector3.new(0, 1, 0),
        (n + Vector3.new(0, 1.5, 0)).Unit,
        (-dir + Vector3.new(0, 1.2, 0)).Unit,
    }

    for _, c in ipairs(candidates) do
        c = clampClimbDir(c, origin, wallTopY)
        if isDirClear(origin, c, look * 0.65, ignoreInstances) then
            local newSide = preferSide or side
            if c:Dot(right) > 0.25 then newSide = 1
            elseif c:Dot(right) < -0.25 then newSide = -1 end
            return c.Unit, newSide
        end
    end

    -- Phương án cuối: đẩy ra khỏi tường + lên (không đâm xuyên)
    return clampClimbDir((n * 1.2 + Vector3.new(0, 1.6, 0)).Unit, origin, wallTopY), side
end

-- Chặn thành phần vận tốc đang đâm vào tường sát người
local function sanitizeVelocity(origin, velocity, ignoreInstances)
    if not velocity or velocity.Magnitude < 0.05 then
        return Vector3.zero
    end
    local near = FlyPathfinder.Config.NearStopDistance or 2.2
    local rp = RaycastParams.new()
    rp.FilterType = Enum.RaycastFilterType.Exclude
    rp.FilterDescendantsInstances = ignoreInstances or { Character }
    rp.IgnoreWater = true

    local dir = velocity.Unit
    local hit = castSolidRay(origin, dir * math.max(near, velocity.Magnitude * 0.05), rp)
    if not hit then
        return velocity
    end

    -- Nếu va sát: loại bỏ xuyên tường, chỉ giữ slide + lên
    local n = hit.Normal
    local into = velocity:Dot(n)
    if into < 0 then
        velocity = velocity - n * into
    end
    -- Đo đỉnh tường đang trượt: nếu đã ngang/trên đỉnh thì bỏ thành phần đẩy lên
    local wallTopY = getWallTopYFromHit(hit, rp)
    -- Ép thêm thành phần thoát tường
    if wallTopY and origin.Y >= wallTopY - 1.5 then
        -- Đang ở đỉnh tường: thoát ngang là chính, không leo tiếp
        velocity = velocity + n * 8
    else
        velocity = velocity + n * 8 + Vector3.new(0, 6, 0)
    end
    if velocity.Magnitude > 0.05 then
        return velocity
    end
    return (n + Vector3.new(0, 1, 0)).Unit * 20
end

-- Nhả / chiếm quyền điều khiển bay (tránh xung đột nhiều BodyVelocity)
local function releaseLegacyFlyControllers()
    -- Ngắt loop Manual/Auto fly — không đụng NavFly (khai báo sau trong file)
    if Fly then
        if Fly.flyConnection then
            pcall(function() Fly.flyConnection:Disconnect() end)
            Fly.flyConnection = nil
        end
        if Fly.flyBV and Fly.flyBV.Parent then
            pcall(function() Fly.flyBV:Destroy() end)
        end
        if Fly.flyGyro and Fly.flyGyro.Parent then
            pcall(function() Fly.flyGyro:Destroy() end)
        end
        Fly.flyBV = nil
        Fly.flyGyro = nil
        Fly.flyTarget = nil
        Fly.desiredY = nil
        Fly.stuckTimer = 0
        Fly.collisionTimer = 0
        Fly.isRerouting = false
    end
    if Status then
        Status.Fly = false
    end
end

local function claimFlightOwnership(hrp)
    releaseLegacyFlyControllers()
    if not hrp then return end
    for _, child in ipairs(hrp:GetChildren()) do
        if child:IsA("BodyVelocity") or child:IsA("BodyGyro")
            or child:IsA("BodyPosition") or child:IsA("LinearVelocity")
            or child:IsA("AlignOrientation") or child:IsA("AlignPosition") then
            if child.Name ~= "FlyPathfinder_BV" and child.Name ~= "FlyPathfinder_Gyro" then
                pcall(function() child:Destroy() end)
            end
        end
    end
end

-- Tính toán danh sách node đường đi 3D tránh tường bằng PathfindingService
local function compute3DWaypoints(startPos, targetPos, ignoreInstances)
    -- Nếu đường thẳng hoàn toàn thông thoáng -> Bay trực tiếp
    if has3DLineOfSight(startPos, targetPos, ignoreInstances) then
        return { startPos, targetPos }
    end

    local path = PathfindingService:CreatePath({
        AgentRadius     = 3.5,
        AgentHeight     = 6,
        AgentCanJump    = true,
        WaypointSpacing = 4,
        Costs = {
            Water   = 20,
            Doorway = 1,
        }
    })

    local ok = pcall(function()
        path:ComputeAsync(startPos, targetPos)
    end)

    if ok and path.Status == Enum.PathStatus.Success then
        local rawWps = path:GetWaypoints()
        local points = {}
        for _, wp in ipairs(rawWps) do
            -- Nâng cao hơn mặt sàn (+5.0 studs) để bay lướt cao thoáng đẹp mắt
            table.insert(points, wp.Position + Vector3.new(0, 5.0, 0))
        end
        if #points > 0 then
            -- Điểm CUỐI phải đúng vị trí vật thể (không +Y) để còn trong tầm E / ProximityPrompt
            points[#points] = targetPos
            return points
        end
    end

    return { startPos, targetPos }
end

-- ==============================================================================
--  TERRAIN-FOLLOW PATH — "tìm đường bay chi tiết & cẩn thận"
--  Dùng khi KHÔNG thể tiêu hao stamina (không BlackLeg): luật game + watchdog chỉ
--  cho phép bay cao ≤ 15 studs → lộ trình phải BÁM SÁT bề mặt từng đoạn:
--    - trên BIỂN       → mặt nước + SEA_LOW_FLY_MARGIN (2 studs)
--    - trên ĐẤT/đảo    → mặt đất + TERRAIN_FOLLOW_MARGIN (8 studs)
--  Lấy đường từ PathfindingService (đi men theo dốc/bãi biển, né vách đứng, không
--  lội qua biển bằng đường đi bộ dài) rồi quét lại Y từng waypoint bằng tấm đế biển
--  (SeaProbe = vật chặn) — PFS fail → mẫu thẳng mỗi TERRAIN_SAMPLE_STEP studs.
--  Nén bớt waypoint nhìn thẳng được để đi tắt không tạt qua từng điểm.
local TERRAIN_SAMPLE_STEP    = 24
local TERRAIN_SCAN_SAMPLES   = 60
local TERRAIN_FOLLOW_MARGIN  = 8  -- trên đất: cao hơn mặt đất 8 studs (≤ ngưỡng 15 watchdog)
local function computeTerrainFollowPath(startPos, targetPos, ignoreInstances)
 local rawWps = nil
 local ok = pcall(function()
  local path = PathfindingService:CreatePath({
   AgentRadius     = 3.5,
   AgentHeight     = 6,
   AgentCanJump    = true,
   WaypointSpacing = 4,
   Costs = { Water = 20, Doorway = 1 },
  })
  path:ComputeAsync(startPos, targetPos)
  if path.Status == Enum.PathStatus.Success then
   rawWps = path:GetWaypoints()
  end
 end)

 local pts = {}
 if ok and rawWps and #rawWps >= 2 then
  for _, wp in ipairs(rawWps) do
   table.insert(pts, wp.Position)
  end
 else
  -- PFS không ra đường (giữa biển xa) → mẫu thẳng theo Terrain
  local hDist = Vector3.new(targetPos.X - startPos.X, 0, targetPos.Z - startPos.Z).Magnitude
  local n = math.clamp(math.floor(hDist / TERRAIN_SAMPLE_STEP), 2, TERRAIN_SCAN_SAMPLES - 1)
  for i = 0, n do
   table.insert(pts, startPos:Lerp(targetPos, i / n))
  end
 end

 -- Chi tiết từng waypoint: bám mặt đất / sát mặt nước (groundOrSeaBelow → SeaProbe = vật chặn)
 for i, pt in ipairs(pts) do
  local baseY, isSea = groundOrSeaBelow(pt)
  if baseY then
   pt = Vector3.new(pt.X, isSea == true and (baseY + SEA_LOW_FLY_MARGIN) or (baseY + TERRAIN_FOLLOW_MARGIN), pt.Z)
  end
  if i == #pts then pt = targetPos end -- điểm cuối đúng vị trí NPC (E / ProximityPrompt)
  pts[i] = pt
 end

 -- Nén bỏ waypoint nhìn thẳng được (đi tắt nhưng vẫn an toàn)
 local compact = { pts[1] }
 for i = 2, #pts do
  local kept = compact[#compact]
  if not has3DLineOfSight(kept, pts[i], ignoreInstances) then
   table.insert(compact, pts[i])
  end
 end
 if #compact == 1 then table.insert(compact, targetPos) end
 compact[#compact] = targetPos
 print(string.format("[Fly] Terrain-Follow: %d waypoints (PFS=%s)", #compact, ok and rawWps and #rawWps >= 2 and "OK" or "FALLBACK"))
 return compact
end

-- ==============================================================================
--  FLY3D CHUNK — A* 3D tìm đường bay NHANH NHẤT quanh vật cản (cây/tường/đồi)
--  Chỉ tính ≤ FLY3D_CHUNK_WPS waypoint (5) mỗi lần tới sub-goal (cách ~70 studs) —
--  hết 5 waypoint lại tính chunk mới → không build cả đường dài 1 lúc → KHÔNG LAG.
--  Vùng dò: rộng ±FLY3D_CORRIDOR (100 studs) mỗi bên đường thẳng current→subGoal,
--  bước FLY3D_STEP (14 studs); tầng cao: đất+8 / +20 / +45 (tầng cao chỉ khi drain OK;
--  noDrain → bám địa hình, vòng qua bên hông cây/tường cao — giữ hợp pháp ≤ 15 studs).
--  Cạnh hợp lệ = raycast thông suốt (IgnoreWater, bỏ Character) → cây/tường chặn =
--  không có cạnh → A* phải vòng. Fallback: LOS thẳng → PFS cục bộ → thẳng tay.
local FLY3D_CHUNK_WPS  = 5
local FLY3D_CHUNK_DIST = 70
local FLY3D_STEP       = 14
local FLY3D_CORRIDOR   = 100
local FLY3D_MAX_NODES  = 900
local function computeFly3DChunk(currentPos, subGoal, ignoreList, noDrain)
 if noDrain then
  -- Không drain được stamina: chỉ bay ≤ 15 studs → bám địa hình (biển: mặt nước+2, đất: +8),
  -- chunk tối đa 5 waypoint; cây/tường cao → vòng qua bên hông (đường PFS men theo địa hình)
  local path = computeTerrainFollowPath(currentPos, subGoal, ignoreList)
  if #path <= FLY3D_CHUNK_WPS then return path end
  local slim = { path[1] }
  for i = 2, #path do
   local kept = slim[#slim]
   if not has3DLineOfSight(kept, path[i], ignoreList) then table.insert(slim, path[i]) end
   if #slim >= FLY3D_CHUNK_WPS - 1 then break end
  end
  if #slim == 1 then table.insert(slim, subGoal) end
  slim[#slim] = subGoal
  return slim
 end

 if has3DLineOfSight(currentPos, subGoal, ignoreList) then return { currentPos, subGoal } end

 -- Lưới node 3D quanh đoạn current→subGoal: dọc theo tuyến, ngang ±100, 3 tầng cao
 local dirH = Vector3.new(subGoal.X - currentPos.X, 0, subGoal.Z - currentPos.Z)
 local hLen = dirH.Magnitude
 if hLen < 0.01 then return { currentPos, subGoal } end
 dirH = dirH.Unit
 local perp = Vector3.new(-dirH.Z, 0, dirH.X)
 local alongCount = math.clamp(math.floor(hLen / FLY3D_STEP), 1, 6)
 local sideCount  = math.clamp(math.floor(FLY3D_CORRIDOR / FLY3D_STEP), 1, 7)
 local layers     = { 8, 20, 45 }
 local nodes, nodeIdx = {}, {}
 local function addNode(pos)
  if #nodes >= FLY3D_MAX_NODES then return nil end
  local idx = #nodes + 1
  nodes[idx] = { pos = pos, g = math.huge, f = math.huge, prev = nil, closed = false }
  return idx
 end
 local function nodeKey(pos)
  return string.format("%d|%d|%d", math.floor(pos.X / 2), math.floor(pos.Z / 2), math.floor(pos.Y / 2))
 end
 -- Xếp node theo ô lưới 2x2 studs để tìm láng giềng nhanh
 local grid = {}
 local function indexNode(pos)
  local k = nodeKey(pos)
  local cell = grid[k]
  if not cell then cell = {} grid[k] = cell end
  local idx = addNode(pos)
  if idx then cell[#cell + 1] = idx end
  return idx
 end
 -- Rải node theo địa hình từng cột
 local cols = {}
 for a = 0, alongCount do
  for s = -sideCount, sideCount do
   local base = currentPos + dirH * (a * FLY3D_STEP) + perp * (s * FLY3D_STEP)
   local groundY = groundOrSeaBelow(base) or currentPos.Y
   for _, off in ipairs(layers) do
    indexNode(Vector3.new(base.X, groundY + off, base.Z))
   end
  end
 end
 local startIdx = indexNode(currentPos)
 local goalIdx  = indexNode(subGoal)
 if not (startIdx and goalIdx) then return { currentPos, subGoal } end

 -- Cạnh: nối node trong cùng ô lưới & 8 ô láng giềng (bán kính ~2*FLY3D_STEP), chỉ khi raycast thông
 local dir = {}
 local function neighbors(idx)
  local out = {}
  local p = nodes[idx].pos
  local cx, cy = math.floor(p.X / 2), math.floor(p.Z / 2)
  for dx = -1, 1 do
   for dz = -1, 1 do
    local cell = grid[string.format("%d|%d|%d", cx + dx, cy + dz, math.floor(p.Y / 2))]
    if cell then
     for _, j in ipairs(cell) do
      if j ~= idx then
       local q = nodes[j].pos
       local d = (q - p).Magnitude
       if d <= FLY3D_STEP * 2.1 then out[#out + 1] = { idx = j, d = d } end
      end
     end
    end
   end
  end
  return out
 end

 -- A* (heuristic = khoảng cách 3D → đường ngắn nhất)
 local open = {}
 nodes[startIdx].g = 0
 nodes[startIdx].f = (subGoal - currentPos).Magnitude
 table.insert(open, startIdx)
 local rp = RaycastParams.new()
 rp.FilterType = Enum.RaycastFilterType.Exclude
 rp.FilterDescendantsInstances = ignoreList
 rp.IgnoreWater = true
 local function heapPop()
  local best, bestF = 1, math.huge
  for i = 1, #open do
   local f = nodes[open[i]].f
   if f < bestF then best, bestF = i, f end
  end
  return table.remove(open, best)
 end
 local reached = false
 local guard = 0
 while #open > 0 and guard < 3000 do
  guard = guard + 1
  local cur = heapPop()
  if not cur then break end
  local cn = nodes[cur]
  if cn.closed then continue end
  cn.closed = true
  if cur == goalIdx then reached = true break end
  for _, nb in ipairs(neighbors(cur)) do
   local nn = nodes[nb.idx]
   if not nn.closed then
    local ng = cn.g + nb.d
    if ng < nn.g then
     nn.g = ng
     nn.f = ng + (subGoal - nn.pos).Magnitude
     nn.prev = cur
     table.insert(open, nb.idx)
    end
   end
  end
 end

 if not reached then
  -- A* fail (hi hữu) → PFS cục bộ rồi thẳng tay
  local pts = { currentPos }
  local ok2 = pcall(function()
   local p2 = PathfindingService:CreatePath({ AgentRadius = 3.5, AgentHeight = 6, AgentCanJump = true, WaypointSpacing = 6 })
   p2:ComputeAsync(currentPos, subGoal)
   if p2.Status == Enum.PathStatus.Success then
    for _, wp in ipairs(p2:GetWaypoints()) do table.insert(pts, wp.Position) end
   end
  end)
  table.insert(pts, subGoal)
  if #pts > 2 then return pts end
  return { currentPos, subGoal }
 end

 -- Dựng lại đường + nén LOS
 local rev = {}
 local cur = goalIdx
 while cur and cur ~= startIdx do
  table.insert(rev, 1, nodes[cur].pos)
  cur = nodes[cur].prev
 end
 table.insert(rev, 1, currentPos)
 local compact = { rev[1] }
 for i = 2, #rev do
  local kept = compact[#compact]
  if not has3DLineOfSight(kept, rev[i], ignoreList) then
   table.insert(compact, rev[i])
  end
 end
 if #compact == 1 then table.insert(compact, subGoal) end
 compact[#compact] = subGoal
 -- Giới hạn 5 waypoint/chunk (cắt bớt node giữa thừa, luôn giữ 2 đầu)
 if #compact > FLY3D_CHUNK_WPS then
  local c2 = { compact[1] }
  for i = 2, #compact - 1 do
   if #c2 >= FLY3D_CHUNK_WPS - 1 then break end
   table.insert(c2, compact[i])
  end
  table.insert(c2, compact[#compact])
  compact = c2
 end
 return compact
end

function FlyPathfinder.SetupPhysics()
    local hrp = getHumanoidRootPart()
    local hum = getHumanoid()
    if not hrp then return false end

    claimFlightOwnership(hrp)

    if hum then hum.PlatformStand = true end

    if not FlyPathfinder.currentBV or not FlyPathfinder.currentBV.Parent then
        local bv = Instance.new("BodyVelocity")
        bv.Name = "FlyPathfinder_BV"
        bv.MaxForce = Vector3.new(1, 1, 1) * math.huge
        bv.Velocity = Vector3.zero
        bv.Parent = hrp
        FlyPathfinder.currentBV = bv
    end

    if not FlyPathfinder.currentGyro or not FlyPathfinder.currentGyro.Parent then
        local gyro = Instance.new("BodyGyro")
        gyro.Name = "FlyPathfinder_Gyro"
        gyro.MaxTorque = Vector3.new(1, 1, 1) * math.huge
        gyro.P = 5000
        gyro.D = 800
        gyro.CFrame = hrp.CFrame
        gyro.Parent = hrp
        FlyPathfinder.currentGyro = gyro
    end

    -- Giữ va chạm thân (không noclip) — né tường bằng steering zero-collision
    local char = Character or LocalPlayer.Character
    if char then
        for _, p in ipairs(char:GetDescendants()) do
            if p:IsA("BasePart") and (p.Name == "Torso" or p.Name == "UpperTorso" or p.Name == "LowerTorso" or string.find(p.Name, "Leg")) then
                p.CanCollide = true
            end
        end
    end

    return true
end

function FlyPathfinder.CleanupPhysics()
    if FlyPathfinder.currentBV and FlyPathfinder.currentBV.Parent then
        pcall(function() FlyPathfinder.currentBV:Destroy() end)
    end
    FlyPathfinder.currentBV = nil

    if FlyPathfinder.currentGyro and FlyPathfinder.currentGyro.Parent then
        pcall(function() FlyPathfinder.currentGyro:Destroy() end)
    end
    FlyPathfinder.currentGyro = nil

    local hum = getHumanoid()
    if hum then
        hum.PlatformStand = false
    end
end

function FlyPathfinder.Stop()
    FlyPathfinder.isNavigating = false
    FlyPathfinder.currentTask   = nil
    FlyPathfinder.ownerToken = (FlyPathfinder.ownerToken or 0) + 1
    FlyPathfinder.CleanupPhysics()
end

function FlyPathfinder.FlyTo(destination, customSpeed, customMode, taskName)
    local hrp = getHumanoidRootPart()
    if not (hrp and isPlayerAlive()) then return false end
    if FlyPathfinder.isFlightBlocked() then return false end
    taskName = taskName or "misc"
    if FlyPathfinder.isTaskBlocked(taskName) then return false end

    -- Lưu tham số FlyTo để watchdog có thể auto-resume sau cancel
    lastFlyToParams = {
        destination = destination,
        speed       = customSpeed,
        mode        = customMode,
        taskName    = taskName
    }
    -- FlyTo mới ưu tiên: xóa task cancelled cũ (task mới ghi đè)
    watchdogCancelledTask = nil

    local targetPos = nil
    if typeof(destination) == "Vector3" then
        targetPos = destination
    elseif typeof(destination) == "CFrame" then
        targetPos = destination.Position
    elseif typeof(destination) == "Instance" then
        local p = destination:IsA("BasePart") and destination or (destination:IsA("Model") and (destination.PrimaryPart or destination:FindFirstChildWhichIsA("BasePart")))
        targetPos = p and p.Position or nil
    end

    if not targetPos then return false end

    -- Hủy lộ trình cũ + chiếm quyền bay (không xung đột engine)
    FlyPathfinder.Stop()
    FlyPathfinder.ownerToken = (FlyPathfinder.ownerToken or 0) + 1
    local myToken = FlyPathfinder.ownerToken

    FlyPathfinder.isNavigating = true
    FlyPathfinder.SetupPhysics()

    local speed = tonumber(customSpeed) or (Options and Options.ImpelSpeed and tonumber(Options.ImpelSpeed.Value)) or FlyPathfinder.Config.FlySpeed
    local startPos = hrp.Position
    local totalDist = (targetPos - startPos).Magnitude

    FlyPathfinder.currentTask = taskName
    print(string.format("[Fly] TASK=%s mode=%s → (%.1f, %.1f, %.1f) | dist=%.0f studs",
        taskName, customMode or "auto", targetPos.X, targetPos.Y, targetPos.Z, totalDist))
    local ignoreList = { Character }

    local stamTimer = 0
    local lastT = tick()
    local function tickStam()
        local now = tick()
        stamTimer = stamTimer + (now - lastT)
        lastT = now
        if stamTimer >= 0.35 then
            stamTimer = 0
            pcall(drainStamina)
        end
    end

    local function stillMine()
        return FlyPathfinder.isNavigating and FlyPathfinder.ownerToken == myToken and isPlayerAlive()
    end

    local function applySafeVelocity(moveDir, curSpeed)
        hrp = getHumanoidRootPart()
        if not hrp then return end
        local safeDir, _ = resolveCollisionFreeDir(hrp.Position, moveDir, ignoreList, nil)
        local vel = safeDir * curSpeed
        vel = sanitizeVelocity(hrp.Position, vel, ignoreList)
        if FlyPathfinder.currentBV and FlyPathfinder.currentBV.Parent then
            FlyPathfinder.currentBV.Velocity = vel
        end
        faceMoveDirection(hrp, safeDir, FlyPathfinder.currentGyro)
    end

    pcall(drainStamina)

    local rp = RaycastParams.new()
    rp.FilterType = Enum.RaycastFilterType.Exclude
    rp.FilterDescendantsInstances = ignoreList
    rp.IgnoreWater = true

    local ceilingHit = filterPassThroughHit(workspace:Raycast(startPos, Vector3.new(0, 60, 0), rp))
    local directHit  = castSolidRay(startPos, (targetPos - startPos), rp)

    local mode = customMode
    local noDrain = not canDrainStamina() -- không BlackLeg → luật game chỉ cho bay cao ≤ 15 studs
    if not mode then
        -- Địa hình không bằng phẳng (đồi/dốc) hoặc đích cao hơn → Smart3D:
        -- PathfindingService nhận diện con đường dốc, thay vì SkyCruise vọt lên trời
        local roughTerrain = hasSignificantTerrainChange(startPos, targetPos)
            or (targetPos.Y - startPos.Y > 4)
        if roughTerrain
            or (totalDist <= 80) or (directHit ~= nil) or (ceilingHit ~= nil) or (targetPos.Y < startPos.Y - 8) then
            mode = "Smart3D"
        else
            mode = "SkyCruise"
        end
    end
    -- Không drain được stamina: SkyCruise bay cao 60+ giữa biển = BẤT HỢP PHÁP (RULRT/watchdog)
    -- → buộc Terrain-Follow (Smart3D + computeTerrainFollowPath) bám mặt đất/sát mặt nước
    if noDrain and (mode == "SkyCruise" or mode == nil or mode == "auto") then
        print("[Fly] Không drain được stamina (không BlackLeg) → SkyCruise → Terrain-Follow (bám mặt đất/sát mặt nước)")
        mode = "Smart3D"
    end

    local arrived = false

    -- Smart3D = Fly3D CHUNK: mỗi lần chỉ tìm ≤ FLY3D_CHUNK_WPS waypoint (5) tới sub-goal
    -- cách ~70 studs; hết chunk → tính chunk kế từ vị trí hiện tại → không build cả đường
    -- dài 1 lúc → KHÔNG LAG. A* 3D vòng qua cây/tường (drain OK); bám địa hình khi không
    -- drain được stamina (noDrain) — vòng qua bên hông cây cao, giữ hợp pháp ≤ 15 studs.
    local function smart3DFly()
        local waypoints = {}
        local wpIndex = 1
        local totalWps = 0
        local subGoalIdx = 0
        local isLastChunk = false
        local function replanChunk()
         local hrpN = getHumanoidRootPart()
         if not hrpN then return false end
         subGoalIdx = subGoalIdx + 1
         local dx = targetPos.X - startPos.X
         local dz = targetPos.Z - startPos.Z
         local hDist = math.max(1, math.sqrt(dx * dx + dz * dz))
         local frac = math.min(1, (subGoalIdx * FLY3D_CHUNK_DIST) / hDist)
         local sg = Vector3.new(startPos.X + dx * frac, hrpN.Position.Y, startPos.Z + dz * frac)
         isLastChunk = frac >= 1
         if isLastChunk then sg = targetPos end
         waypoints = computeFly3DChunk(hrpN.Position, sg, ignoreList, noDrain)
         wpIndex = 1
         totalWps = #waypoints
         if totalWps == 0 then waypoints = { sg } totalWps = 1 end
         return true
        end
        local startTime = os.clock()
        local timeout = math.clamp((totalDist / math.max(speed, 50)) * 2.5 + 6, 5, 45)

        local lastPos = startPos
        local lastMoveDir = nil
        local lastAvoidSide = 0
        local reverseHits = 0
        local stuckAccum = 0
        local escapeUntil = 0
        local lastHB = os.clock()
        local repathCooldown = 0

        replanChunk()

        while stillMine() and (os.clock() - startTime < timeout) do
            hrp = getHumanoidRootPart()
            if not hrp then break end
            -- Đảm bảo không bị engine khác cướp BV giữa chừng
            if not FlyPathfinder.currentBV or not FlyPathfinder.currentBV.Parent then
                FlyPathfinder.SetupPhysics()
            end
            tickStam()

            local now = os.clock()
            local dt = math.clamp(now - lastHB, 0.001, 0.1)
            lastHB = now

            if wpIndex > totalWps then
                if isLastChunk then
                    arrived = true
                    break
                end
                -- Hết chunk → tìm chunk kế (≤5 waypoint, đồ thị nhỏ → repath nhanh, không lag)
                replanChunk()
                if wpIndex > totalWps then break end
            end

            local curWp = waypoints[wpIndex]

            if wpIndex < totalWps then
                local nextWp = waypoints[wpIndex + 1]
                if has3DLineOfSight(hrp.Position, nextWp, ignoreList) then
                    wpIndex = wpIndex + 1
                    curWp = nextWp
                end
            end

            local diff = curWp - hrp.Position
            local dist = diff.Magnitude

            if dist <= (wpIndex == totalWps and FlyPathfinder.Config.ArrivalThreshold or 4.0) then
                wpIndex = wpIndex + 1
                if wpIndex > totalWps then
                    if isLastChunk then
                        arrived = true
                        break
                    end
                    replanChunk()
                    if wpIndex > totalWps then break end
                end
                curWp = waypoints[wpIndex]
                diff = curWp - hrp.Position
                dist = diff.Magnitude
            end

            local moveDir = dist > 0.05 and diff.Unit or Vector3.new(0, 1, 0)

            local moved = (hrp.Position - lastPos).Magnitude
            local wantSpeed = (FlyPathfinder.currentBV and FlyPathfinder.currentBV.Velocity.Magnitude) or 0
            if wantSpeed > 8 and moved < 0.12 then
                stuckAccum = stuckAccum + dt
            else
                stuckAccum = math.max(0, stuckAccum - dt * 0.5)
            end

            if lastMoveDir and moveDir:Dot(lastMoveDir) < -0.25 then
                reverseHits = reverseHits + 1
            else
                reverseHits = math.max(0, reverseHits - 1)
            end

            local inEscape = now < escapeUntil
            if (stuckAccum > 0.7 or reverseHits >= 5) and not inEscape then
                escapeUntil = now + 1.0
                stuckAccum = 0
                reverseHits = 0
                lastAvoidSide = 0
                if wpIndex < totalWps then
                    wpIndex = wpIndex + 1
                    curWp = waypoints[wpIndex]
                    diff = curWp - hrp.Position
                    dist = diff.Magnitude
                    moveDir = dist > 0.05 and diff.Unit or Vector3.new(0, 1, 0)
                end
                -- Repath kẹt: tính chunk mới từ vị trí hiện tại (nhanh — đồ thị cục bộ nhỏ)
                if now >= repathCooldown then
                    repathCooldown = now + 2.5
                    replanChunk()
                    print("♻️ [FlyPathfinder] Repath Fly3D chunk")
                end
            end

            if inEscape or now < escapeUntil then
                local toGoal = targetPos - hrp.Position
                local flat = Vector3.new(toGoal.X, 0, toGoal.Z)
                moveDir = (Vector3.new(0, 1.4, 0) + (flat.Magnitude > 1 and flat.Unit or moveDir)).Unit
                -- Escape cũng không leo quá đỉnh tường đang chắn
                local escRP = RaycastParams.new()
                escRP.FilterType = Enum.RaycastFilterType.Exclude
                escRP.FilterDescendantsInstances = ignoreList
                escRP.IgnoreWater = true
                local escHit = castSolidRay(hrp.Position, moveDir * (FlyPathfinder.Config.LookAhead or 12), escRP)
                moveDir = clampClimbDir(moveDir, hrp.Position, getWallTopYFromHit(escHit, escRP))
            elseif dist > 4 then
                local safeDir, side = resolveCollisionFreeDir(hrp.Position, moveDir, ignoreList, lastAvoidSide)
                moveDir = safeDir
                lastAvoidSide = side
            end

            local curSpeed = (wpIndex == totalWps) and math.clamp(dist * 5, 10, speed) or speed
            if reverseHits >= 2 then
                curSpeed = math.min(curSpeed, 35)
            end
            if now < escapeUntil then
                curSpeed = math.min(speed, 70)
            end

            local vel = moveDir * curSpeed
            vel = sanitizeVelocity(hrp.Position, vel, ignoreList)
            if FlyPathfinder.currentBV then
                FlyPathfinder.currentBV.Velocity = vel
            end
            if reverseHits < 3 or now < escapeUntil then
                faceMoveDirection(hrp, moveDir, FlyPathfinder.currentGyro)
            end

            lastPos = hrp.Position
            lastMoveDir = moveDir
            RunService.Heartbeat:Wait()
        end
        return arrived
    end

    if mode == "DirectLow" then
        -- Bay thẳng thấp tới đích: né trái/phải, hạn chế leo cao (anti-cheat: không teleport)
        local startTime = os.clock()
        local timeout = math.clamp((totalDist / math.max(speed, 40)) * 2.2 + 4, 4, 28)
        local maxY = targetPos.Y + 8
        local lastAvoidSide = 0
        local lastHB = os.clock()
        -- Phát hiện kẹt nhanh: 1.5s không tiến gần đích → thoát sớm → chuyển Fly3D chunk
        local progT = os.clock()
        local progDist = 1e9

        while stillMine() and (os.clock() - startTime < timeout) do
            hrp = getHumanoidRootPart()
            if not hrp then break end
            if not FlyPathfinder.currentBV or not FlyPathfinder.currentBV.Parent then
                FlyPathfinder.SetupPhysics()
            end
            tickStam()

            local now = os.clock()
            local dt = math.clamp(now - lastHB, 0.001, 0.1)
            lastHB = now

            local toTarget = targetPos - hrp.Position
            local dist = toTarget.Magnitude
            -- Kẹt nhanh: 1.5s không tiến gần đích (khoảng cách không giảm) → thoát sớm
            if os.clock() - progT > 1.5 then
                if dist > 12 and dist >= progDist - 0.5 then
                    print("[Fly] DirectLow không tiến gần (kẹt cây/tường) → chuyển Fly3D chunk")
                    break
                end
                progDist = dist
                progT = os.clock()
            end
            if dist <= FlyPathfinder.Config.ArrivalThreshold then
                arrived = true
                break
            end

            -- Giữ độ cao gần đích (không leo ngọn cây)
            local desired = Vector3.new(targetPos.X, math.min(targetPos.Y, maxY), targetPos.Z)
            local move = desired - hrp.Position
            if move.Magnitude < 0.05 then
                move = toTarget
            end

            -- Né: ưu tiên ngang, hạn chế component lên
            local moveDir, side = resolveCollisionFreeDir(hrp.Position, move, ignoreList, lastAvoidSide)
            lastAvoidSide = side
            -- Nếu steering muốn bay lên quá cao → ép nghiêng ngang
            if hrp.Position.Y >= maxY - 1 and moveDir.Y > 0.15 then
                local flat = Vector3.new(moveDir.X, 0, moveDir.Z)
                if flat.Magnitude > 0.08 then
                    moveDir = flat.Unit
                else
                    moveDir = Vector3.new(moveDir.X, -0.35, moveDir.Z)
                    if moveDir.Magnitude > 0.01 then moveDir = moveDir.Unit end
                end
            elseif moveDir.Y > 0.55 then
                moveDir = Vector3.new(moveDir.X, 0.25, moveDir.Z)
                if moveDir.Magnitude > 0.01 then moveDir = moveDir.Unit end
            end

            -- Đang cao hơn maxY: ưu tiên hạ
            if hrp.Position.Y > maxY then
                local downBias = Vector3.new(move.X, (hoverY or targetPos.Y) - hrp.Position.Y, move.Z)
                -- hoverY không tồn tại ở đây — dùng targetPos.Y
                downBias = Vector3.new(move.X, targetPos.Y - hrp.Position.Y, move.Z)
                if downBias.Magnitude > 0.05 then
                    moveDir = downBias.Unit
                else
                    moveDir = Vector3.new(0, -1, 0)
                end
            end

            local curSpeed = math.clamp(dist * 4.5, 14, speed)
            local vel = moveDir * curSpeed
            vel = sanitizeVelocity(hrp.Position, vel, ignoreList)
            if FlyPathfinder.currentBV then
                FlyPathfinder.currentBV.Velocity = vel
            end
            faceMoveDirection(hrp, moveDir, FlyPathfinder.currentGyro)
            RunService.Heartbeat:Wait()
        end

        if FlyPathfinder.currentBV and FlyPathfinder.currentBV.Parent then
            FlyPathfinder.currentBV.Velocity = Vector3.zero
        end

        -- DirectLow kẹt / không tới được (cây/tường chắn) → chuyển sang Fly3D chunk (A* 3D)
        if not arrived and stillMine() and FlyPathfinder.ownerToken == myToken then
            print("[Fly] DirectLow kẹt → chuyển Fly3D chunk (A* 3D)")
            arrived = smart3DFly()
        end

    elseif mode == "Smart3D" then
        arrived = smart3DFly()
    else
    -- SKYCRUISE: cất cánh → lướt tầng cao → hạ cánh (mỗi bước đều sanitize va chạm)
    -- BIỂN + không drain được stamina (không BlackLeg) → bay SÁT MẶT NƯỚC thay vì cao 60 studs
    -- (dưới ngưỡng watchdog 15 studs → không bao giờ bị hủy bay giữa biển)
    local seaLowY = seaFlyLowActive(startPos)
    local highY = getHighestAltitudeOnPath(startPos, targetPos)
    local cruiseY
    if seaLowY then
     cruiseY = seaLowY + SEA_LOW_FLY_MARGIN
     print("[Fly] SkyCruise trên BIỂN + không drain được stamina → bay sát mặt nước (thấp)")
    else
     cruiseY = math.max(highY + FlyPathfinder.Config.CruiseAltitudeOffset, startPos.Y, targetPos.Y + 2, FlyPathfinder.Config.MinCruiseAltitude or 0)
    end

        local climbTimeout = os.clock()
        while stillMine() and (os.clock() - climbTimeout < 8) do
            hrp = getHumanoidRootPart()
            if not hrp then break end
            tickStam()
            local yDiff = cruiseY - hrp.Position.Y
            if math.abs(yDiff) <= 6 then break end

            local yDir = math.sign(yDiff)
            applySafeVelocity(Vector3.new(0, yDir, 0), math.clamp(math.abs(yDiff) * 3, 20, 90))
            faceTowardPosition(hrp, targetPos, FlyPathfinder.currentGyro)
            RunService.Heartbeat:Wait()
        end

        local skyTarget = Vector3.new(targetPos.X, cruiseY, targetPos.Z)
        local flyTimeout = os.clock()
        local hTotal = Vector3.new(skyTarget.X - startPos.X, 0, skyTarget.Z - startPos.Z).Magnitude
        local hLimit = math.clamp((hTotal / speed) * 2 + 5, 4, 35)

        while stillMine() and (os.clock() - flyTimeout < hLimit) do
            hrp = getHumanoidRootPart()
            if not hrp then break end
            tickStam()
            local diff = skyTarget - hrp.Position
            local hDist = Vector3.new(diff.X, 0, diff.Z).Magnitude
            if hDist <= 8 then break end

            local dir = Vector3.new(diff.X, (cruiseY - hrp.Position.Y) * 0.15, diff.Z)
            if dir.Magnitude < 0.05 then dir = Vector3.new(diff.X, 0, diff.Z) end
            applySafeVelocity(dir, speed)
            RunService.Heartbeat:Wait()
        end

        local landTimeout = os.clock()
        while stillMine() and (os.clock() - landTimeout < 8) do
            hrp = getHumanoidRootPart()
            if not hrp then break end
            tickStam()
            local diff = targetPos - hrp.Position
            local dist = diff.Magnitude
            if dist <= FlyPathfinder.Config.ArrivalThreshold then
                arrived = true
                break
            end

            -- Gần đích: bay thẳng hơn, vẫn sanitize để không kẹt sàn/tường
            local landSpeed = math.clamp(dist * 4, 12, speed)
            local landDir = diff
            if dist > 6 then
                landDir = resolveCollisionFreeDir(hrp.Position, diff, ignoreList, 0)
            end
            local vel = landDir.Unit * landSpeed
            vel = sanitizeVelocity(hrp.Position, vel, ignoreList)
            if FlyPathfinder.currentBV then
                FlyPathfinder.currentBV.Velocity = vel
            end
            faceMoveDirection(hrp, landDir, FlyPathfinder.currentGyro)
            RunService.Heartbeat:Wait()
        end
    end

    if FlyPathfinder.ownerToken == myToken then
        FlyPathfinder.isNavigating = false
        FlyPathfinder.currentTask   = nil
        FlyPathfinder.CleanupPhysics()
    end
    return arrived
end

local function flyToWaypointSky(targetPos, speed)
    return FlyPathfinder.FlyTo(targetPos, speed, nil, "impeldown")
end

_G.FlyPathfinder = FlyPathfinder


-- Tìm Zones.End của floor hiện tại (mỗi floor mê cung có Effects.Zones.End)
local function findFloorEndZone()
    local effects = workspace:FindFirstChild("Effects")
    local zones = effects and effects:FindFirstChild("Zones")
    local endZone = zones and zones:FindFirstChild("End")
    if not endZone then
        -- Fallback: tìm Part/Model tên End trong Zones
        if zones then
            for _, child in ipairs(zones:GetChildren()) do
                if string.lower(child.Name) == "end" then
                    endZone = child
                    break
                end
            end
        end
    end
    if not endZone then return nil end

    if endZone:IsA("BasePart") then
        return endZone.Position, endZone
    elseif endZone:IsA("Model") then
        local p = endZone.PrimaryPart or endZone:FindFirstChildWhichIsA("BasePart", true)
        return p and p.Position or nil, endZone
    elseif endZone:IsA("Folder") or endZone:IsA("Configuration") then
        local p = endZone:FindFirstChildWhichIsA("BasePart", true)
        return p and p.Position or nil, endZone
    end
    return nil, endZone
end

-- Farm xong -> tìm đường ra mê cung (Smart3D, không xuyên tường)
-- Ưu tiên: Zones.End khi đang ở waypoint end-floor; không thì bay tới nextWP
local function pathfindOutOfMaze(currentWp, nextWp, speed)
    if not ImpelNav.active then return false end

    -- HARD GATE: Key còn tồn tại = chưa mở khóa → cấm bay
    if playerHandcuffKeyStillExists and playerHandcuffKeyStillExists() then
        warn("🔑 [Pathfind] ABORT: Key của bạn vẫn còn tồn tại (chưa dùng) → không bay W kế")
        notify("🔑 Key còn = chưa mở khóa — hủy bay W kế", 5)
        if ensureHandcuffsUnlockedBeforeNextWP then
            if not ensureHandcuffsUnlockedBeforeNextWP(speed) then
                return false
            end
        else
            return false
        end
        if playerHandcuffKeyStillExists() then
            return false
        end
    end

    local destPos = nil
    local destLabel = nil

    if currentWp and currentWp.IsMazeEnd then
        local endPos = findFloorEndZone()
        if endPos then
            destPos = endPos
            destLabel = "Zones.End (lối ra floor)"
        end
    end

    if not destPos and nextWp then
        destPos = nextWp.Position
        destLabel = string.format("waypoint [%s]", nextWp.Key)
    end

    if not destPos and currentWp and currentWp.IsMazeEnd then
        -- End zone chưa stream: vẫn đi next WP nếu có
        if nextWp then
            destPos = nextWp.Position
            destLabel = string.format("waypoint [%s] (chưa thấy Zones.End)", nextWp.Key)
        end
    end

    if not destPos then
        warn("[ImpelDown][Pathfind] Không có đích để tìm đường ra mê cung!")
        return false
    end

    -- Check lại ngay trước khi FlyTo
    if playerHandcuffKeyStillExists and playerHandcuffKeyStillExists() then
        warn("🔑 [Pathfind] ABORT trước FlyTo: Key vẫn còn")
        return false
    end

    impelSetStatus("Pathfind", string.format("Tìm đường ra mê cung → %s", destLabel))
    print(string.format("🧭 [ImpelDown] Farm xong → Smart3D tìm đường ra mê cung tới %s", destLabel))

    local ignoreTransit = isW2W3Pair(currentWp and currentWp.Key, nextWp and nextWp.Key)
        or shouldIgnoreTargetsForFlightTo(nextWp and nextWp.Key)
    if ignoreTransit then
        beginIgnoreMonsterTargets(string.format("pathfind %s → %s (không Target quái)",
            tostring(currentWp and currentWp.Key), destLabel))
    end

    local arrived = FlyPathfinder.FlyTo(destPos, speed, "Smart3D", "impeldown")
    if arrived then
        print(string.format("✅ [ImpelDown] Đã thoát đoạn mê cung → %s", destLabel))
    else
        warn(string.format("⚠️ [ImpelDown] Pathfind chưa tới đích (%s), thử SkyCruise fallback...", destLabel))
        arrived = FlyPathfinder.FlyTo(destPos, speed, "SkyCruise", "impeldown")
    end

    if ignoreTransit then
        endIgnoreMonsterTargets()
    end
    return arrived
end

-- Tầm cần tiến sát để ProximityPrompt / phím E còn hiệu lực
local function getInteractRange(prompt)
    if prompt and typeof(prompt.MaxActivationDistance) == "number" and prompt.MaxActivationDistance > 0 then
        return math.max(2, prompt.MaxActivationDistance * 0.7)
    end
    return 3.5
end

-- Bay THẤP thẳng tới mục tiêu interact (Key/rương/loot).
-- - Không CFrame teleport (anti-cheat)
-- - Không SkyCruise (raycast đỉnh cây → bay lên cây)
-- - Né vật cản sang TRÁI/PHẢI, hạn chế bay lên cao hơn Key
local function flyCloseForInteract(targetPos, prompt, speed)
    local range = getInteractRange(prompt)
    local hoverPos = targetPos + Vector3.new(0, 2.5, 0)
    local maxY = targetPos.Y + 8 -- không cho leo cao kiểu ngọn cây

    local hrp = getHumanoidRootPart()
    if not hrp then return false end
    if (hrp.Position - targetPos).Magnitude <= range then
        return true
    end

    if FlyPathfinder and FlyPathfinder.isNavigating then
        pcall(function() FlyPathfinder.Stop() end)
    end

    -- Dùng mode DirectLow của FlyPathfinder (bay thấp, không teleport)
    local flySpeed = math.min(tonumber(speed) or 75, 70)
    local arrived = FlyPathfinder.FlyTo(hoverPos, flySpeed, "DirectLow", "hover")

    hrp = getHumanoidRootPart()
    if not hrp then return arrived end

    -- Nếu lệch Y quá cao (bị steering đẩy lên cây): hạ xuống bằng bay, không snap
    if hrp.Position.Y > maxY + 2 then
        FlyPathfinder.FlyTo(Vector3.new(hrp.Position.X, hoverPos.Y, hrp.Position.Z), math.min(flySpeed, 55), "DirectLow", "hover")
        hrp = getHumanoidRootPart()
        if hrp and (hrp.Position - targetPos).Magnitude > range then
            FlyPathfinder.FlyTo(hoverPos, flySpeed, "DirectLow", "hover")
            hrp = getHumanoidRootPart()
        end
    elseif (hrp.Position - targetPos).Magnitude > range then
        -- Còn xa ngang: bay lại lần nữa, vẫn DirectLow
        FlyPathfinder.FlyTo(hoverPos, flySpeed, "DirectLow", "hover")
        hrp = getHumanoidRootPart()
    end

    return hrp ~= nil and (hrp.Position - targetPos).Magnitude <= (range + 4)
end

-- Nhặt item: (1) bay tới vị trí item (2) dịch chuyển Part item lên HRP (3) fire prompt
pickupLootItem = function(obj, pp, speed)
    if not obj or not obj.Parent then return false end
    pp = pp or obj:FindFirstChildWhichIsA("ProximityPrompt", true)
    if not pp then return false end

    local pPos = (pp.Parent and pp.Parent:IsA("BasePart") and pp.Parent.Position)
        or (obj:IsA("BasePart") and obj.Position)
        or (getLootRootPart(obj, pp) and getLootRootPart(obj, pp).Position)

    -- Bước 1: vẫn bay tới item
    if pPos then
        flyCloseForInteract(pPos, pp, speed)
    end
    if not ImpelNav.active or not obj.Parent then return false end

    -- Bước 2 + 3: kéo Part lên HRP rồi trigger (giữ sát HRP mỗi lần thử)
    local attempts = 0
    while ImpelNav.active and obj and obj.Parent and pp and pp.Parent and attempts < 15 do
        bringLootToPlayer(obj, pp)
        attempts = attempts + 1
        forceTriggerPrompt(pp)
        if not pp.Enabled then break end
        -- Item đã biến mất = nhặt thành công
        if not obj.Parent then break end
        task.wait(0.1)
    end
    return true
end

-- ==============================================================================
--  FULL LOOT AREA SEQUENCE: QUÉT & BAY TỚI MỞ HẾT TẤT CẢ RƯƠNG + NHẶT HẾT DROPS
-- ==============================================================================
local function fullLootAreaSequence(centerPos, radius, maxDuration)
    maxDuration = maxDuration or 15
    local startTime = os.clock()
    local speed = (Options and Options.ImpelSpeed and Options.ImpelSpeed.Value) or 75
    checkAndEnforceWeaponLoot()

    print(string.format("📦🔍 [ImpelDown Loot] Bắt đầu quét mở rương & nhặt toàn bộ đồ trong phạm vi %d studs...", radius))

    while ImpelNav.active and (os.clock() - startTime < maxDuration) do
        local acted = false
        local folders = { workspace:FindFirstChild("Effects"), workspace }

        -- 1. TÌM VÀ MỞ TẤT CẢ RƯƠNG CHƯA MỞ TRONG PHẠM VI
        for _, folder in ipairs(folders) do
            if folder then
                for _, obj in ipairs(folder:GetChildren()) do
                    if isChestModel(obj) then
                        local pp = getChestProximityPrompt(obj)
                        if pp and pp.Enabled then
                            local chestPart = getChestRootPart(obj)
                            if chestPart and (chestPart.Position - centerPos).Magnitude <= radius then
                                acted = true
                                local chestName = pp.ObjectText ~= "" and pp.ObjectText or obj.Name
                                impelSetStatus("Looting", string.format("Bay tới mở rương: %s", chestName))
                                print(string.format("📦⚡ [ImpelDown Loot] Tiếp cận mở rương '%s'...", chestName))

                                flyCloseForInteract(chestPart.Position, pp, speed)

                                local attempts = 0
                                while ImpelNav.active and pp and pp.Enabled and pp.Parent and attempts < 10 do
                                    local hrpNow = getHumanoidRootPart()
                                    local interactRange = getInteractRange(pp)
                                    if hrpNow and (hrpNow.Position - chestPart.Position).Magnitude > interactRange then
                                        flyCloseForInteract(chestPart.Position, pp, speed)
                                    end
                                    attempts = attempts + 1
                                    forceTriggerPrompt(pp)
                                    task.wait(0.12)
                                end
                                task.wait(0.3) -- Chờ rương vỡ / item bung ra
                            end
                        end
                    end
                end
            end
        end

        -- 2. TÌM VÀ NHẶT TẤT CẢ CÁC MÓN ĐỒ RƠI TRONG PHẠM VI
        for _, folder in ipairs(folders) do
            if folder then
                for _, obj in ipairs(folder:GetChildren()) do
                    if not isChestModel(obj) then
                        local pp = obj:FindFirstChildWhichIsA("ProximityPrompt", true)
                        if pp and pp.Enabled then
                            local itemName, itemCat, tierRank = identifyLootItem(obj)
                            if itemName then
                                local shouldPick = false
                                if itemName == "Spirit Essence" then
                                    local busoVal = getBusoMasteryValue()
                                    local hasSpirit = hasItemInInventory("Spirit Essence")
                                    if busoVal == 0 and not hasSpirit then shouldPick = true end
                                elseif itemName == "SP Reset Essence" then
                                    shouldPick = true
                                elseif itemCat == "sword" then
                                    local hasSword = checkSwordInBackpack()
                                    if not hasSword or (tierRank and getBestSwordTierInInventory() > tierRank) then
                                        shouldPick = true
                                    end
                                elseif itemCat == "helmet" then
                                    if tierRank and getBestHelmetTierInInventory() > tierRank then shouldPick = true end
                                elseif itemCat == "outfit" then
                                    if tierRank and getBestOutfitTierInInventory() > tierRank then shouldPick = true end
                                else
                                    shouldPick = true
                                end

                                if shouldPick then
                                    local pPos = (pp.Parent:IsA("BasePart") and pp.Parent.Position) or (obj:IsA("BasePart") and obj.Position)
                                    if pPos and (pPos - centerPos).Magnitude <= radius then
                                        acted = true
                                        impelSetStatus("Looting", string.format("Bay tới nhặt: %s", itemName))
                                        print(string.format("⚡💎 [ImpelDown Loot] Bay tới → kéo Part lên HRP: '%s'...", itemName))

                                        pickupLootItem(obj, pp, speed)
                                        task.wait(0.15)
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end

        -- Nếu không còn rương nào chưa mở và không còn item nào trên đất -> ĐÃ XONG
        if not acted then
            print("✨ [ImpelDown Loot] ĐÃ MỞ HẾT TẤT CẢ RƯƠNG VÀ NHẶT SẠCH TOÀN BỘ ĐỒ TRONG KHU VỰC!")
            break
        end

        task.wait(0.3)
    end
end

local function scanAndLootArea(centerPos, radius)
    fullLootAreaSequence(centerPos, radius, 12)
end

-- Vị trí hover: CÁCH ĐẦU target 5 studs (Head part nếu có, ngược lại HRP + 8)
-- Clamp an toàn trong khoảng HRP+1..HRP+12 (tầm server ~10)
local function getHeadHoverPosition(targetHRP)
    if not targetHRP then return nil end
    local model = targetHRP.Parent
    local head = model and model:FindFirstChild("Head")
    local y = (head and head.Position) and (head.Position.Y + 5.0) or (targetHRP.Position.Y + 8.0)
    y = math.max(targetHRP.Position.Y + 1.0, math.min(y, targetHRP.Position.Y + 12.0))
    return Vector3.new(targetHRP.Position.X, y, targetHRP.Position.Z)
end

-- Kéo nhân vật tới target khi combat: hover đơn giản, KHÔNG steering
-- (isSameCombatSpace đã chặn target qua tường từ trước — steering gây giật lên xuống)
-- Tốc độ tỉ lệ khoảng cách + dead zone: càng gần càng chậm, sát thì dừng hẳn
-- Trả về hướng bay để xoay mặt (nil = đã sát, không kéo)
local function pullTowardSafe(hrp, targetPos, maxSpeed)
    if not (hrp and targetPos) then return nil end
    local diff = targetPos - hrp.Position
    local d = diff.Magnitude
    if d < 0.7 then
        if FlyPathfinder.currentBV and FlyPathfinder.currentBV.Parent then
            FlyPathfinder.currentBV.Velocity = Vector3.zero
        end
        return nil
    end
    local spd = math.min(math.max(d * 5, 8), maxSpeed or 70)
    local moveDir = diff.Unit
    if FlyPathfinder.currentBV and FlyPathfinder.currentBV.Parent then
        FlyPathfinder.currentBV.Velocity = moveDir * spd
    end
    return moveDir
end

-- Bay né sau khi đánh xong combo: lên cao thẳng từ vị trí đứng (tránh phản đòn), không xuyên trần
local function getRetreatPosition(hrp)
    if not hrp then return nil end
    local params = RaycastParams.new()
    params.FilterType                 = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = { Character }
    local upHit = filterPassThroughHit(workspace:Raycast(hrp.Position, Vector3.new(0, 40, 0), params))
    local ceilingY = upHit and upHit.Position.Y or (hrp.Position.Y + 40)
    local targetY = math.min(hrp.Position.Y + 12, ceilingY - 3)
    return Vector3.new(hrp.Position.X, targetY, hrp.Position.Z)
end

killMonster = function(npcData, speed, opts)
    opts = opts or {}
    local activeCheck = opts.activeCheck or function() return true end -- ai gọi thì cung cấp điều kiện chạy
    local logTag      = opts.logTag or "[Kill]"
    local onKilled    = opts.onKilled              -- callback khi target CHẾT thật (nhận myPos)
    local useFaceLook = opts.useFaceLook           -- true = bật FaceLook 3D hướng mặt về target

    -- Equip vũ khí ngay khi bắt đầu combat (không đợi cú chém đầu)
    local eqTool, _ = chooseBestWeapon("Backpack")
    if eqTool then
        pcall(equipWeapon, eqTool)
    end

    local faceEnabled = false
    local function poseTargetGetter()
        local alive, _, h = isCombatTargetAlive(npcData)
        return alive and h and h.Position or nil
    end
    local function enableFace()
        if not faceEnabled then
            faceEnabled = true
            if useFaceLook then setFaceMode(true, poseTargetGetter) end
            setPosePin(true, false, poseTargetGetter)
        end
    end
    local function disableFace()
        if faceEnabled then
            faceEnabled = false
            if useFaceLook then setFaceMode(false) end
            setPosePin(false)
        end
    end

    -- Không bay tới / đánh nếu target đã chết
    local alive0, _, hrp0 = isCombatTargetAlive(npcData)
    if not alive0 then
        print("⏭️ " .. logTag .. " Bỏ qua target đã chết / despawn")
        return false
    end

    -- Khác không gian (bị tường lớn/dày/cao chắn) → bỏ qua
    if not isSameCombatSpace(npcData) then
        print(string.format("🧱 %s Bỏ qua '%s' — bị tường lớn chắn / khác không gian",
            logTag, tostring(npcData.Model and npcData.Model.Name)))
        return false
    end

    local targetTag = npcData.IsTargetingMe and " [ĐANG TARGET BẠN ⚠️]" or ""
    print(string.format("⚔️ %s Quái mục tiêu: %s%s (%.0f studs) -> Tới kill...", logTag, npcData.Model.Name, targetTag, npcData.Distance or 0))

    -- Bật FaceLook 3D TRƯỚC khi bay: lúc tiếp cận cũng hướng mặt vào target
    enableFace()

    -- Bay tới chỗ quái ĐÚNG CÁCH BAY TỚI QUEST: đích = vị trí THẤP (HRP quái) như vị trí NPC
    -- → SkyCruise/Smart3D hạ sát xuống thấp theo địa hình, không bay tới điểm cao trên đầu.
    -- Lên vị trí đánh trên đầu (head+5) thì loop combat tự kéo ngắn bằng BV.
    local approachPos = hrp0.Position
    flyToWaypointSky(approachPos, speed)

    -- Sau khi bay tới: nếu đã chết hoặc bị tường chắn → dừng
    if not isCombatTargetAlive(npcData) then
        print("⏭️ " .. logTag .. " Target chết khi đang tiếp cận — dừng")
        disableFace()
        return false
    end
    if not isSameCombatSpace(npcData) then
        print("🧱 " .. logTag .. " Sau tiếp cận vẫn bị tường chắn — bỏ qua")
        FlyPathfinder.CleanupPhysics()
        disableFace()
        return false
    end

    FlyPathfinder.SetupPhysics()

    local startTime = os.clock()
    local missStreak = 0
    while activeCheck() and isPlayerAlive() do
        -- Đảm bảo BV/Gyro còn sống (phòng mọi đường phá physics từ bên ngoài)
        if not FlyPathfinder.currentBV or not FlyPathfinder.currentBV.Parent then
            FlyPathfinder.SetupPhysics()
        end

        local alive, hum, targetHRP = isCombatTargetAlive(npcData)
        if not alive then
            local name = (npcData.Model and npcData.Model.Name) or "?"
            print("✅ " .. logTag .. " Target hết sống / đã hạ: " .. tostring(name))
            FlyPathfinder.CleanupPhysics()
            task.wait(0.3)
            local myPos = getPlayerPosition()
            if myPos and onKilled then
                pcall(onKilled, myPos)
            end
            break
        end

        -- Đang combat mà đột nhiên bị tường chắn (lệch phòng) → bỏ
        if not isSameCombatSpace(npcData) then
            print("🧱 " .. logTag .. " Mất cùng không gian với target — bỏ qua")
            break
        end
        if os.clock() - startTime > 25 then
            warn("⚠️ " .. logTag .. " Timeout kill: " .. tostring(npcData.Model and npcData.Model.Name))
            break
        end

        local hrp = getHumanoidRootPart()
        local canSwing = false
        if hrp and targetHRP then
            local targetHover = getHeadHoverPosition(targetHRP) or (targetHRP.Position + Vector3.new(0, 1.0, 0))
            local diff = targetHover - hrp.Position
            local distHRP = diff.Magnitude
            -- Dùng khoảng cách server (realPos) — HRP bay trước hay khiến “đứng sát mà không đánh”
            local combatDist, visualDist, serverDist = getCombatDistanceTo(targetHRP.Position)

            local needClose = (serverDist > ATTACK_RANGE_SOFT) or (visualDist > ATTACK_RANGE_SOFT) or (distHRP > 2.0)
            -- Tư thế: ĐÁNH (trong tầm) = nằm ngang; BAY (né/kéo tới, ngoài tầm) = đứng
            canSwing = serverDist <= ATTACK_RANGE_SOFT and visualDist <= ATTACK_RANGE_SOFT
            AAB_hoverDive = canSwing and "dive" or nil
            -- POSE PIN: cập nhật tư thế cho heartbeat ghim (dive = nằm ngang)
            PosePin.dive = canSwing
            PosePin.lastUpdate = os.clock()
            if needClose then
                local moveDir = diff.Magnitude > 0.1 and diff.Unit or Vector3.new(0, 0, -1)
                -- Visual sát nhưng server còn xa: kéo mạnh hơn bằng BV (không CFrame)
                local pullMul = (visualDist <= ATTACK_RANGE_SOFT and serverDist > ATTACK_RANGE_SOFT) and 7 or 5
                local safeDir = pullTowardSafe(hrp, targetHover, math.clamp(math.max(distHRP, serverDist) * pullMul, 14, speed))
                -- Luôn xoay mặt về target (dù đang kéo ngang/kéo xuống hay lên đầu)
                -- Dive ổn định: còn gần điểm hover (<=4.5) thì giữ tư thế nằm ngang
                -- (ngưỡng distHRP>2.0 cũ làm tư thế lật qua lại mỗi frame khi quái cử động nhẹ)
                faceTowardPosition(hrp, targetHRP.Position, FlyPathfinder.currentGyro, AAB_hoverDive)
            else
                if FlyPathfinder.currentBV then
                    FlyPathfinder.currentBV.Velocity = Vector3.zero
                end
                faceTowardPosition(hrp, targetHRP.Position, FlyPathfinder.currentGyro, AAB_hoverDive)
            end
        end

        if not isCombatTargetAlive(npcData) then
            break
        end

        if not canSwing then
            missStreak = missStreak + 1
            if missStreak >= 2 then
                local hrp2 = getHumanoidRootPart()
                local stillAlive, _, tHRP = isCombatTargetAlive(npcData)
                if stillAlive and hrp2 and tHRP then
                    local pull = (getHeadHoverPosition(tHRP) or (tHRP.Position + Vector3.new(0, 1.0, 0))) - hrp2.Position
                    pullTowardSafe(hrp2, getHeadHoverPosition(tHRP) or (tHRP.Position + Vector3.new(0, 1.0, 0)), math.min(speed, 70))
                    faceTowardPosition(hrp2, tHRP.Position, FlyPathfinder.currentGyro)
                elseif not stillAlive then
                    break
                end
                missStreak = 0
            end
            task.wait()
        else
            local hit = callAttack(npcData)
            if hit then
                missStreak = 0
                -- Đánh xong đòn cuối combo → bay né lên cao tránh bị phản đòn
                -- KHÔNG dùng flyToWaypointSky: nó CleanupPhysics ở cuối → mất BV giữa combat
                if AAB_comboStep == AAB_Config.COMBO_SIZE then
                    local hrpR = getHumanoidRootPart()
                    local stillAlive, _, retreatTarget = isCombatTargetAlive(npcData)
                    if hrpR and stillAlive then
                        PosePin.dive = false -- né lên: tư thế đứng, không ghim nằm ngang
                        local retreatPos = getRetreatPosition(hrpR)
                        if retreatPos then
                            local t0 = os.clock()
                            while os.clock() - t0 < 0.6 do
                                local h = getHumanoidRootPart()
                                if not h then break end
                                if (retreatPos - h.Position).Magnitude <= 1.5 then break end
                                pullTowardSafe(h, retreatPos, math.max(speed, 70))
                                -- Luôn hướng mặt về target khi né
                                if retreatTarget and retreatTarget.Parent then
                                    faceTowardPosition(h, retreatTarget.Position, FlyPathfinder.currentGyro)
                                end
                                task.wait()
                            end
                            -- Chờ phản đòn trôi qua → loop sẽ kéo về đầu target tiếp
                            task.wait(0.5)
                        end
                    end
                end
            else
                missStreak = missStreak + 1
                if missStreak >= 2 then
                    local hrp2 = getHumanoidRootPart()
                    local stillAlive, _, tHRP = isCombatTargetAlive(npcData)
                    if stillAlive and hrp2 and tHRP then
                        pullTowardSafe(hrp2, getHeadHoverPosition(tHRP) or (tHRP.Position + Vector3.new(0, 1.0, 0)), math.min(speed, 70))
                        faceTowardPosition(hrp2, tHRP.Position, FlyPathfinder.currentGyro)
                    elseif not stillAlive then
                        break
                    end
                    missStreak = 0
                end
                task.wait()
            end
        end
    end

    disableFace()
    FlyPathfinder.CleanupPhysics()
    return true
end

-- === Wrapper giữ nguyên API cũ cho ImpelDown (watcher + killNearbyMonsters không phải sửa) ===
killImpelMonster = function(npcData, speed)
    return killMonster(npcData, speed, {
        activeCheck = function() return ImpelNav.active end,
        logTag      = "[ImpelDown]",
        onKilled    = function(myPos)
            if Options.ImpelChestLoot and Options.ImpelChestLoot.Value then
                scanAndLootArea(myPos, 60)
            end
        end,
    })
end

-- Tiêu diệt quái quanh khu vực; quét lại đến khi hết quái CÒN SỐNG
local function killNearbyMonsters(centerPos, scanRadius, speed)
    local anyFought = false
    local round = 0

    while ImpelNav.active and round < 10 do
        round = round + 1
        local scanPos = getPlayerPosition() or centerPos
        if not scanPos then break end

        local _, monsters = getNPCSnapshot()
        local targetList = {}

        for _, m in ipairs(monsters) do
            -- Chỉ lấy quái còn sống + cùng không gian (không bị tường lớn chắn)
            if isCombatTargetAlive(m) and isSameCombatSpace(m) then
                local dist = (m.Position - scanPos).Magnitude
                local inRange = dist <= (tonumber(scanRadius) or 80)
                -- w-2 ↔ w-3: không đuổi Target ngoài bán kính
                local atSetupCorridor = ImpelNav.currentKey == "w-2" or ImpelNav.currentKey == "w-3"
                    or ImpelNav.ignoreMonsterTargets
                local chaseAggro = m.IsTargetingMe and not atSetupCorridor
                if inRange or chaseAggro then
                    table.insert(targetList, m)
                end
            elseif isCombatTargetAlive(m) and not isSameCombatSpace(m) then
                -- Log nhẹ khi bỏ quái sau tường (tránh spam: chỉ targeting)
                if m.IsTargetingMe and not ImpelNav.ignoreMonsterTargets then
                    print(string.format("🧱 [ImpelDown] Bỏ '%s' (đang target bạn nhưng bị tường chắn)", tostring(m.Model and m.Model.Name)))
                end
            end
        end

        table.sort(targetList, function(a, b)
            if a.IsTargetingMe and not b.IsTargetingMe then return true end
            if not a.IsTargetingMe and b.IsTargetingMe then return false end
            return (a.Distance or 0) < (b.Distance or 0)
        end)

        if #targetList == 0 then
            if anyFought then
                impelSetStatus("Farm", "Đã clear quái còn sống — chuyển bước tiếp theo")
            else
                impelSetStatus("Farm", "Không còn quái sống trong phạm vi")
            end
            break
        end

        impelSetStatus("Farm", string.format("Còn %d quái sống — tiếp tục giết (vòng %d)", #targetList, round))
        anyFought = true

        for _, m in ipairs(targetList) do
            if not ImpelNav.active then break end
            if isCombatTargetAlive(m) then
                local tag = m.IsTargetingMe and " [ĐANG TARGET BẠN ⚠️]" or ""
                impelSetStatus("Farm", string.format("Tiêu diệt: %s%s", tostring(m.Model.Name), tag))
                killImpelMonster(m, speed)
                task.wait(0.15)
            end
        end
    end

    return anyFought
end

-- ==============================================================================
--  HANDCUFF KEY UNLOCK ENGINE
--  Quy tắc cứng: Key của người chơi CÒN TỒN TẠI trong workspace.Effects
--                = chưa dùng = CHƯA mở khóa = CẤM bay / tăng W
-- ==============================================================================

local function getKeyRootPart(keyInstance)
    if not keyInstance then return nil end
    if keyInstance:IsA("BasePart") then return keyInstance end
    if keyInstance:IsA("Model") then
        return keyInstance.PrimaryPart
            or keyInstance:FindFirstChild("Key")
            or keyInstance:FindFirstChildWhichIsA("BasePart", true)
    end
    return keyInstance:FindFirstChildWhichIsA("BasePart", true)
end

local function getKeyProximityPrompt(keyInstance)
    if not keyInstance then return nil end
    return keyInstance:FindFirstChildWhichIsA("ProximityPrompt", true)
end

local function getKeyOwnerText(keyInstance)
    local pp = getKeyProximityPrompt(keyInstance)
    if pp then
        if pp.ObjectText and pp.ObjectText ~= "" then return pp.ObjectText end
        if pp.ActionText and pp.ActionText ~= "" then return pp.ActionText end
    end
    return keyInstance.Name
end

-- ObjectText chuẩn: "[PlayerName]'s Handcuff Key"
local function normalizeOwnerText(ownerText)
    if not ownerText or ownerText == "" then return "" end
    local text = string.lower(ownerText)
    text = string.gsub(text, "\226\128\152", "'") -- ‘
    text = string.gsub(text, "\226\128\153", "'") -- ’
    text = string.gsub(text, "\226\128\154", "'") -- ‚
    text = string.gsub(text, "`", "'")
    return text
end

local function isMyHandcuffKeyOwnerText(ownerText)
    if not ownerText or ownerText == "" then return false end
    local p = LocalPlayer or Player
    if not p then return false end
    local text = normalizeOwnerText(ownerText)
    local myName = string.lower(p.Name or "")
    local myDisplay = string.lower(p.DisplayName or "")

    local hasName = (myName ~= "" and string.find(text, myName, 1, true))
        or (myDisplay ~= "" and string.find(text, myDisplay, 1, true))
    if not hasName then return false end

    -- Handcuff key (chấp nhận nhiều biến thể ObjectText/ActionText)
    if string.find(text, "handcuff")
        or string.find(text, "hand cuff")
        or string.find(text, "cuff")
        or string.find(text, "unlock")
        or string.find(text, "key") then
        return true
    end
    return false
end

local function debugDumpAllEffectKeys()
    local effects = workspace:FindFirstChild("Effects")
    if not effects then
        warn("[Handcuffs] workspace.Effects không tồn tại")
        return
    end
    local p = LocalPlayer or Player
    print(string.format("🔑 [KeyScan] Player=%s / Display=%s | quét Effects:",
        tostring(p and p.Name), tostring(p and p.DisplayName)))
    local n = 0
    for _, obj in ipairs(effects:GetDescendants()) do
        local isKeyName = string.lower(obj.Name) == "key"
        local isPrompt = obj:IsA("ProximityPrompt")
        if isKeyName or isPrompt then
            n = n + 1
            local owner = isPrompt
                and ((obj.ObjectText ~= "" and obj.ObjectText) or obj.ActionText or "")
                or getKeyOwnerText(obj)
            local mine = isMyHandcuffKeyOwnerText(owner)
            print(string.format("  #%d %s | owner='%s' | isMine=%s | class=%s",
                n, obj:GetFullName(), tostring(owner), tostring(mine), obj.ClassName))
        end
    end
    if n == 0 then
        print("  (không có Key/ProximityPrompt trong Effects)")
    end
end

local function considerHandcuffCandidate(obj, pp, rootPart, myPos, best)
    if not obj or not obj.Parent or not rootPart or not rootPart.Parent then
        return best
    end
    local ownerText = ""
    if pp then
        ownerText = (pp.ObjectText and pp.ObjectText ~= "" and pp.ObjectText)
            or (pp.ActionText and pp.ActionText ~= "" and pp.ActionText)
            or ""
    end
    if ownerText == "" then
        ownerText = getKeyOwnerText(obj)
    end
    if not isMyHandcuffKeyOwnerText(ownerText) then
        return best
    end
    local dist = myPos and (rootPart.Position - myPos).Magnitude or 0
    local score = dist - (pp and 100000 or 0)
    if score < best.dist then
        best.dist = score
        best.obj, best.pp, best.part = obj, pp, rootPart
    end
    return best
end

-- Key còn tồn tại (Parent còn) = chưa được dùng. KHÔNG cần Prompt.Enabled.
-- Quét cả object tên Key VÀ mọi ProximityPrompt có ObjectText handcuff của mình.
findMyHandcuffKey = function()
    local effects = workspace:FindFirstChild("Effects")
    local searchRoots = {}
    if effects then table.insert(searchRoots, effects) end
    table.insert(searchRoots, workspace)

    local best = { obj = nil, pp = nil, part = nil, dist = math.huge }
    local hrp = getHumanoidRootPart()
    local myPos = hrp and hrp.Position
    local seen = {}

    for _, root in ipairs(searchRoots) do
        for _, obj in ipairs(root:GetDescendants()) do
            -- 1) Object tên Key (giống KeyESP)
            if string.lower(obj.Name) == "key" and not seen[obj] then
                seen[obj] = true
                local pp = getKeyProximityPrompt(obj)
                local rootPart = getKeyRootPart(obj)
                best = considerHandcuffCandidate(obj, pp, rootPart, myPos, best)
            end
            -- 2) ProximityPrompt trực tiếp (ObjectText có tên player + handcuff/key)
            if obj:IsA("ProximityPrompt") and not seen[obj] then
                seen[obj] = true
                local ownerText = (obj.ObjectText ~= "" and obj.ObjectText) or obj.ActionText or ""
                if isMyHandcuffKeyOwnerText(ownerText) then
                    local host = obj.Parent
                    local keyObj = host
                    if host and string.lower(host.Name) ~= "key" and host.Parent
                        and string.lower(host.Parent.Name) == "key" then
                        keyObj = host.Parent
                    end
                    local rootPart = getKeyRootPart(keyObj) or (host and host:IsA("BasePart") and host)
                        or (host and host:FindFirstChildWhichIsA("BasePart"))
                    best = considerHandcuffCandidate(keyObj or host, obj, rootPart, myPos, best)
                end
            end
        end
        if best.obj and root == effects then
            break
        end
    end

    return best.obj, best.pp, best.part
end

-- TRUE = Key của player vẫn còn trên map (chưa dùng) → chưa mở khóa
playerHandcuffKeyStillExists = function()
    local keyObj, _, keyPart = findMyHandcuffKey()
    if not keyObj then return false end
    if not keyObj.Parent then return false end
    if keyPart and not keyPart.Parent then return false end
    return true
end

-- Chờ Effects/Key stream về (tránh bay sớm khi Key chưa kịp load → false "đã mở")
local function waitForHandcuffKeySettle(maxWait)
    maxWait = maxWait or 2.5
    local deadline = os.clock() + maxWait
    local sawKey = false
    while ImpelNav.active and os.clock() < deadline do
        if playerHandcuffKeyStillExists() then
            sawKey = true
            -- Key đã thấy → ổn định thêm chút rồi return
            task.wait(0.15)
            return true
        end
        task.wait(0.12)
    end
    return sawKey
end

local function isStillHandcuffed()
    return playerHandcuffKeyStillExists()
end

-- Chờ Key biến mất (đã dùng). Không bao giờ coi là xong nếu Key còn.
local function waitUntilMyKeyDestroyed(timeoutSec)
    timeoutSec = timeoutSec or 8
    local deadline = os.clock() + timeoutSec
    while ImpelNav.active and os.clock() < deadline do
        if not playerHandcuffKeyStillExists() then
            return true
        end
        task.wait(0.1)
    end
    return not playerHandcuffKeyStillExists()
end

-- Mở còng: bay tới Key + E. Chỉ return true khi Key ĐÃ BIẾN MẤT.
unlockHandcuffsIfCuffed = function(customSpeed)
    if not playerHandcuffKeyStillExists() then
        return true
    end

    local speed = customSpeed or (Options and Options.ImpelSpeed and Options.ImpelSpeed.Value) or 75
    local round = 0

    -- Lặp đến khi Key biến mất hoặc user dừng (không có “timeout cho phép đi tiếp”)
    while ImpelNav.active and playerHandcuffKeyStillExists() do
        round = round + 1
        local keyObj, pp, keyPart = findMyHandcuffKey()
        if not keyObj or not keyPart then
            -- Không tìm thấy trong frame này — đợi key load / re-scan
            task.wait(0.25)
            if not playerHandcuffKeyStillExists() then
                break
            end
            if round % 8 == 0 then
                warn("⚠️ [Handcuffs] Key vẫn được đánh dấu còn nhưng chưa resolve được Part — quét lại...")
            end
        else
            local ownerText = getKeyOwnerText(keyObj)
            print(string.format(
                "🔑⚡ [Handcuffs] KEY CÒN TỒN TẠI (chưa dùng) lần %d: '%s' @ %s",
                round, ownerText, keyPart:GetFullName()
            ))
            notify("🔑 Key còn tồn tại = chưa mở khóa — đang mở TRƯỚC khi sang W", 4)
            impelSetStatus("OpenLock", string.format("Key còn → mở khóa (lần %d) — CẤM bay W kế", round))

            if FlyPathfinder and FlyPathfinder.isNavigating then
                pcall(function() FlyPathfinder.Stop() end)
            end

            -- Bay sát key — không SkyCruise, không CFrame (tránh leo cây / anti-cheat)
            flyCloseForInteract(keyPart.Position, pp, speed)
            if not ImpelNav.active then return false end

            -- Snap + trigger nhiều lần; mỗi lần check Key còn không
            local attempts = 0
            local interactRange = getInteractRange(pp)
            local burstDeadline = os.clock() + 15
            while ImpelNav.active and playerHandcuffKeyStillExists() and attempts < 50 and os.clock() < burstDeadline do
                keyObj, pp, keyPart = findMyHandcuffKey()
                if not (keyObj and keyPart and keyPart.Parent) then
                    break
                end

                local hrp = getHumanoidRootPart()
                if hrp then
                    local dist = (hrp.Position - keyPart.Position).Magnitude
                    if dist > interactRange + 1 then
                        -- Luôn bay thấp tới Key — không CFrame snap (anti-cheat)
                        flyCloseForInteract(keyPart.Position, pp, speed)
                    else
                        attempts = attempts + 1
                        faceTowardPosition(hrp, keyPart.Position, FlyPathfinder and FlyPathfinder.currentGyro)
                        if pp and pp.Parent then
                            print(string.format("🔑⚡ [Handcuffs] Trigger E (#%d) — Key vẫn còn = chưa mở", attempts))
                            -- Không phụ thuộc prompt.Enabled (đôi khi disabled đến khi sát)
                            pcall(function()
                                pp.HoldDuration = 0
                                pp.RequiresLineOfSight = false
                                pp.Enabled = true
                            end)
                            if not forceTriggerPrompt(pp) then
                                pcall(function() fireproximityprompt(pp) end)
                                pcall(function() fireproximityprompt(pp, 0) end)
                                pcall(function()
                                    pp:InputHoldBegin()
                                    task.defer(function() pcall(function() pp:InputHoldEnd() end) end)
                                end)
                            end
                        else
                            warn("⚠️ [Handcuffs] Key còn nhưng Prompt thiếu — chờ Prompt / bay sát lại")
                        end
                    end
                end
                task.wait(0.18)

                if not playerHandcuffKeyStillExists() then
                    break
                end
            end
        end

        if playerHandcuffKeyStillExists() then
            warn("⚠️ [Handcuffs] Key VẪN CÒN TỒN TẠI sau vòng mở — chưa cho bay W kế, thử lại...")
            task.wait(0.5)
        end

        -- Tránh spam vô hạn nếu user AFK: vẫn không cho đi tiếp, chỉ nghỉ nhẹ
        if round >= 40 then
            notify("🔑 Key vẫn còn sau nhiều lần thử — tiếp tục mở, không chuyển W", 5)
            round = 0
        end
    end

    if not ImpelNav.active then return false end

    -- Xác nhận cuối: phải đợi Key destroy thật
    if playerHandcuffKeyStillExists() then
        warn("❌ [Handcuffs] Key vẫn tồn tại → CHƯA mở khóa → CẤM chuyển W")
        impelSetStatus("OpenLock", "⛔ Key còn tồn tại — chưa mở khóa")
        return false
    end

    -- Double-check ngắn (tránh race destroy muộn)
    if not waitUntilMyKeyDestroyed(2) then
        return false
    end

    print("🔓✨ [Handcuffs] Key đã biến mất (= đã dùng) — mở khóa OK")
    notify("🔓 Key đã dùng / biến mất — mới được bay W kế", 3)
    impelSetStatus("OpenLock", "Key đã biến mất — mở khóa xong")
    task.wait(0.4)
    return true
end

-- Gate cứng trước mọi pathfind / tăng W / bay tới W
ensureHandcuffsUnlockedBeforeNextWP = function(speed)
    if playerHandcuffKeyStillExists() then
        print("🔑 [Handcuffs] GATE: Key của bạn VẪN CÒN → chặn chuyển W / bay")
        pcall(debugDumpAllEffectKeys)
        impelSetStatus("OpenLock", "⛔ Key còn tồn tại — chặn bay W kế")
        local ok = unlockHandcuffsIfCuffed(speed)
        if not ok or playerHandcuffKeyStillExists() then
            warn("❌ [Handcuffs] GATE FAIL: Key vẫn còn — không pathfind / không tăng W")
            pcall(debugDumpAllEffectKeys)
            notify("❌ Key còn = chưa mở khóa — giữ nguyên W", 5)
            return false
        end
    end

    if playerHandcuffKeyStillExists() then
        return false
    end
    return true
end

-- OpenLock trước, rồi Loot — chỉ return true khi sẵn sàng bay W kế
local function openLockThenLootBeforeTravel(speed, lootRadius)
    lootRadius = lootRadius or 60
    if not ensureHandcuffsUnlockedBeforeNextWP(speed) then
        return false
    end
    if Options.ImpelChestLoot and Options.ImpelChestLoot.Value then
        impelSetStatus("Looting", "Loot sau khi mở còng — trước khi bay W")
        local curPos = getPlayerPosition()
        if curPos then
            scanAndLootArea(curPos, lootRadius)
        end
        task.wait(0.3)
    end
    -- Check lại: Key có thể xuất hiện giữa lúc loot
    if playerHandcuffKeyStillExists() then
        warn("🔑 [ImpelDown] Key xuất hiện lại sau loot — mở lại trước khi bay")
        if not ensureHandcuffsUnlockedBeforeNextWP(speed) then
            return false
        end
    end
    return true
end

function impelStop()
    ImpelNav.active = false
    ImpelNav.ignoreMonsterTargets = false
    stopNPCTargetWatcher()
    if ImpelNav.taskThread then
        task.cancel(ImpelNav.taskThread)
        ImpelNav.taskThread = nil
    end
    impelCleanupPhysics()
    if Options.ImpelNavToggle and Options.ImpelNavToggle.Value then
        Options.ImpelNavToggle:SetValue(false)
    end
    impelSetStatus("Idle", "Đã dừng Auto Farm Impel Down")
end

local MAIN_GAME_PLACE_ID = 7465136166

function impelStart()
    -- Kiểm tra Place ID: Không chạy nếu đang ở Main Game (7465136166)
    if game.PlaceId == MAIN_GAME_PLACE_ID then
        notify("⚠️ Impel Down chỉ hoạt động trong Dungeon (PlaceId khác 7465136166)!", 6)
        impelSetStatus("⚠️ Đang ở Main Game. Hãy vào Dungeon Impel Down!")
        if Options.ImpelNavToggle then
            Options.ImpelNavToggle:SetValue(false)
        end
        return
    end

    if ImpelNav.active then impelStop() return end
    ImpelNav.active = true
    startNPCTargetWatcher()

    ImpelNav.taskThread = task.spawn(function()
        local speed = tonumber(Options.ImpelSpeed and Options.ImpelSpeed.Value) or 75
        local scanRadius = tonumber(Options.ImpelScanRadius and Options.ImpelScanRadius.Value) or 80

        -- Spawn checkpoint: dropdown / file đã lưu (không bắt buộc về w-3)
        local spawnKey = ImpelNav.spawnKey or ImpelNav.currentKey or "w-3"
        if Options.ImpelSpawnWP and Options.ImpelSpawnWP.Value and Options.ImpelSpawnWP.Value ~= "" then
            spawnKey = Options.ImpelSpawnWP.Value
        end
        local startWp, startIdx = getWaypointByKey(spawnKey)
        if not startWp then
            startWp, startIdx = resolveCurrentWaypoint()
            spawnKey = startWp and startWp.Key or "w-3"
        end
        local skipSetup = (startIdx or 1) > 1 or (startWp and startWp.Key ~= "w-3")

        print(string.format("🚀 [ImpelDown] Bắt đầu từ spawn [%s] (index %d/%d)%s",
            tostring(spawnKey), startIdx or 1, #IMPEL_WAYPOINTS, skipSetup and " — bỏ qua setup w-3" or ""))

        if skipSetup and startWp then
            -- Resume: OpenLock TRƯỚC, rồi mới bay tới W (không teleport)
            impelSetStatus("OpenLock", string.format("Resume [%s] — mở còng TRƯỚC khi bay", startWp.Key))
            waitForHandcuffKeySettle(2.0)
            if not ensureHandcuffsUnlockedBeforeNextWP(speed) then
                notify("❌ Chưa mở còng — dừng Impel để tránh bay nhầm W", 6)
                impelStop()
                return
            end
            setCurrentWaypointByKey(startWp.Key)
            impelSetStatus("Pathfind", string.format("Resume spawn [%s] — đã mở còng", startWp.Key))
            teleportToWaypoint(startWp)
            saveImpelSpawn(startWp.Key)
            task.wait(0.4)
            if not openLockThenLootBeforeTravel(speed, 50) then
                notify("❌ Resume: chưa mở còng/loot — dừng", 6)
                impelStop()
                return
            end
        else
            -- =========================================================================
            -- w-3 SETUP PIPELINE (cứng):
            --   1) OpenLock (mở còng)
            --   2) Looting (lặp đến khi đủ điều kiện: có kiếm)
            --   3) Đủ điều kiện → ResetStat + nâng stat
            --   4) Done → sang farm / W kế
            -- =========================================================================
            saveImpelSpawn("w-3")
            setCurrentWaypointByKey("w-3")

            -- ----- 1) OpenLock -----
            impelSetStatus("OpenLock", "[w-3] 1/4 Mở còng TRƯỚC loot / stat...")
            waitForHandcuffKeySettle(2.5)
            if not ensureHandcuffsUnlockedBeforeNextWP(speed) then
                notify("❌ [w-3] Chưa mở còng — dừng setup", 6)
                impelStop()
                return
            end
            if not ImpelNav.active then return end

            -- Bay gần vùng w-3 nếu đang rất xa (sau khi đã mở còng)
            local w3_point = IMPEL_WAYPOINTS[1]
            if w3_point and w3_point.Key == "w-3" then
                local hrp0 = getHumanoidRootPart()
                local d0 = hrp0 and (hrp0.Position - w3_point.Position).Magnitude or 0
                if d0 > 80 then
                    impelSetStatus("Bay", "[w-3] Đã mở còng → bay tới vùng loot...")
                    if not ensureHandcuffsUnlockedBeforeNextWP(speed) then
                        notify("❌ Key còn — không bay tới w-3", 5)
                        impelStop()
                        return
                    end
                    teleportToWaypoint(w3_point)
                end
            end

            if Options.ImpelChestLoot then
                Options.ImpelChestLoot:SetValue(true)
            end

            -- ----- 2) Looting đến khi đủ điều kiện (có kiếm) -----
            local hasSword, swordName, swordLoc = false, nil, nil
            local searchCount = 0
            local MAX_LOOT_ROUNDS = 5

            while ImpelNav.active do
                -- Key bung ra giữa loot → mở lại trước khi loot tiếp
                if playerHandcuffKeyStillExists() then
                    impelSetStatus("OpenLock", "[w-3] Key còn trong lúc loot — mở lại...")
                    if not ensureHandcuffsUnlockedBeforeNextWP(speed) then
                        notify("🔑 [w-3] Key còn — giữ loot, không ResetStat", 4)
                        task.wait(0.8)
                    end
                end

                searchCount = searchCount + 1
                local scanDist = math.min(80 + ((searchCount - 1) * 25), 200)
                impelSetStatus("Looting", string.format(
                    "[w-3] 2/4 Looting (lần %d/%d, %d studs) — chờ đủ kiếm...",
                    searchCount, MAX_LOOT_ROUNDS, scanDist
                ))
                print(string.format("📦 [w-3] Loot round %d/%d (%d studs)", searchCount, MAX_LOOT_ROUNDS, scanDist))

                local myPos = getPlayerPosition()
                if myPos then
                    fullLootAreaSequence(myPos, scanDist, searchCount == 1 and 25 or 15)
                end
                task.wait(0.4)

                hasSword, swordName, swordLoc = checkSwordInBackpack()
                print(string.format("🎒 [w-3] Check kiếm: %s | %s | %s",
                    hasSword and "CÓ ✅" or "CHƯA ❌",
                    tostring(swordName), tostring(swordLoc)))

                if hasSword then
                    notify(string.format("✅ [w-3] Đủ điều kiện — có kiếm: %s", tostring(swordName)), 3)
                    break
                end

                if searchCount >= MAX_LOOT_ROUNDS then
                    warn("⚠️ [w-3] Hết vòng loot vẫn chưa có kiếm — vẫn qua ResetStat rồi Done")
                    notify("⚠️ [w-3] Chưa có kiếm sau loot — tiếp tục ResetStat", 5)
                    break
                end

                notify(string.format("⚠️ Chưa đủ kiếm — loot lại (%d studs)...", scanDist), 3)
            end

            if not ImpelNav.active then return end

            -- Gate: vẫn còn Key → không ResetStat / không Done
            if not ensureHandcuffsUnlockedBeforeNextWP(speed) then
                notify("❌ [w-3] Key còn sau loot — dừng (không ResetStat)", 6)
                impelStop()
                return
            end

            pcall(checkAndEnforceWeaponLoot)

            -- ----- 3) Đủ điều kiện → ResetStat + nâng stat -----
            impelSetStatus("UpdateStats", "[w-3] 3/4 Đủ điều kiện → Haki + ResetStat + nâng Defense 775 → Kiếm")
            print("📊 [w-3] Bắt đầu ResetStat / nâng stat (sau loot)...")
            autoCheckAndActivateHaki()
            task.wait(0.4)
            autoCheckAndResetStats(775)
            task.wait(0.7)
            if Options.ImpelAutoStats and Options.ImpelAutoStats.Value then
                autoAllocateStats(775)
            end
            task.wait(0.3)

            -- ----- 4) Done -----
            impelSetStatus("Idle", "[w-3] 4/4 DONE setup — sẵn sàng farm / sang W kế")
            print("✨ [w-3] SETUP DONE: OpenLock → Loot → Stat → xong")
            notify("✅ [w-3] Setup xong (còng + loot + stat)", 4)

            if not ImpelNav.active then return end

            -- Gate cuối trước khi set W kế
            if not openLockThenLootBeforeTravel(speed, 50) then
                notify("❌ [w-3] Gate cuối fail (còng/loot) — không bay sang w-2", 6)
                impelStop()
                return
            end

            local w2 = getWaypointByKey("w-2")
            if w2 then
                setCurrentWaypointByKey("w-2")
                saveImpelSpawn("w-2")
            else
                local _, idx2 = resolveCurrentWaypoint()
                ImpelNav.currentWP = math.min((idx2 or 1) + 1, #IMPEL_WAYPOINTS)
                local n = IMPEL_WAYPOINTS[ImpelNav.currentWP]
                if n then setCurrentWaypointByKey(n.Key) end
            end
        end

        -- =========================================================================
        -- BƯỚC 2: Farm → OpenLock → Loot → Pathfind (CẤM bay nếu còn Key)
        -- =========================================================================
        while ImpelNav.active do
            local wp, wpIdx = resolveCurrentWaypoint()
            if not wp or not wpIdx or wpIdx > #IMPEL_WAYPOINTS then
                if openLockThenLootBeforeTravel(speed, 50) then
                    local endPos = findFloorEndZone()
                    if endPos then
                        pathfindOutOfMaze({ Key = "end", IsMazeEnd = true }, nil, speed)
                    end
                end
                impelSetStatus("Idle", "🏁 Đã hoàn thành tất cả Waypoint Impel Down!")
                notify("Hoàn thành Impel Down!", 5)
                impelStop()
                break
            end

            setCurrentWaypointByKey(wp.Key)
            local nextWp, nextIdx = getNextWaypoint(wpIdx)

            print(string.format("📍 [ImpelDown] W hiện tại = [%s] (index %d) | tiếp theo = [%s]",
                wp.Key, wpIdx, nextWp and nextWp.Key or "HẾT"))

            saveImpelSpawn(wp.Key)
            if Options.ImpelSpawnWP then
                pcall(function() Options.ImpelSpawnWP:SetValue(wp.Key) end)
            end

            -- 1) OpenLock trước mọi bay/farm
            if playerHandcuffKeyStillExists() then
                impelSetStatus("OpenLock", string.format("Key còn tại [%s] — mở TRƯỚC khi bay/farm", wp.Key))
                if not ensureHandcuffsUnlockedBeforeNextWP(speed) then
                    notify("🔑 Key còn — không bay, giữ W và thử lại", 4)
                    task.wait(1.0)
                end
            end

            if ImpelNav.active and not playerHandcuffKeyStillExists() then
                local hrpNow = getHumanoidRootPart()
                local distToThisWp = hrpNow and (hrpNow.Position - wp.Position).Magnitude or math.huge
                local alreadyNear = distToThisWp <= 12

                if not alreadyNear then
                    if not ensureHandcuffsUnlockedBeforeNextWP(speed) then
                        notify("🔑 Key còn — hủy bay tới W", 4)
                        task.wait(0.8)
                    else
                        impelSetStatus("Pathfind", string.format("Tìm đường tới [%s] (%d/%d)...", wp.Key, wpIdx, #IMPEL_WAYPOINTS))
                        local ignoreTransit = shouldIgnoreTargetsForFlightTo(wp.Key)
                            or isW2W3Pair(ImpelNav.currentKey, wp.Key)
                        if ignoreTransit then
                            beginIgnoreMonsterTargets(string.format("bay tới [%s] — không Target quái", wp.Key))
                        end
                        local arrived = FlyPathfinder.FlyTo(wp.Position, speed, "Smart3D", "impeldown")
                        if not arrived then
                            arrived = flyToWaypointSky(wp.Position, speed)
                        end
                        if ignoreTransit then
                            endIgnoreMonsterTargets()
                        end
                        if not arrived or not ImpelNav.active then break end

                        hrpNow = getHumanoidRootPart()
                        if hrpNow and (hrpNow.Position - wp.Position).Magnitude > 25 then
                            warn(string.format("⚠️ [ImpelDown] Lệch khỏi [%s] sau pathfind → bay lại đúng WP", wp.Key))
                            teleportToWaypoint(wp)
                        end
                    end
                else
                    print(string.format("🧭 [ImpelDown] Đã sát đúng [%s] (%.1f studs) → Farm ngay", wp.Key, distToThisWp))
                end

                if ImpelNav.active and not playerHandcuffKeyStillExists() then
                    impelSetStatus("Farm", string.format("[%s] Bắt đầu đánh quái...", wp.Key))
                    local myPos = getPlayerPosition()
                    if myPos then
                        killNearbyMonsters(myPos, scanRadius, speed)

                        local extra = 0
                        while ImpelNav.active and extra < 3 do
                            extra = extra + 1
                            local pos2 = getPlayerPosition()
                            if not pos2 then break end
                            local _, left = getNPCSnapshot()
                            local still = 0
                            for _, m in ipairs(left) do
                                if isCombatTargetAlive(m) and isSameCombatSpace(m) then
                                    local d = (m.Position - pos2).Magnitude
                                    local atSetupCorridor = ImpelNav.currentKey == "w-2" or ImpelNav.currentKey == "w-3"
                                        or ImpelNav.ignoreMonsterTargets
                                    if d <= scanRadius or (m.IsTargetingMe and not atSetupCorridor) then
                                        still = still + 1
                                    end
                                end
                            end
                            if still == 0 then break end
                            impelSetStatus("Farm", string.format("Còn %d quái sống — tiếp tục giết trước khi sang WP", still))
                            killNearbyMonsters(pos2, scanRadius, speed)
                        end

                        if Options.ImpelAutoStats and Options.ImpelAutoStats.Value then
                            impelSetStatus("UpdateStats", "Cập nhật Stats sau Farm...")
                            autoAllocateStats(775)
                        end
                    end

                    if ImpelNav.active then
                        -- 2) OpenLock → Loot → mới được pathfind / tăng W
                        if playerHandcuffKeyStillExists() then
                            print(string.format(
                                "🔑 [ImpelDown] GATE tại [%s]: Key còn → OpenLock+Loot, không bay [%s]",
                                tostring(wp.Key), tostring(nextWp and nextWp.Key or "?")
                            ))
                        end

                        if not openLockThenLootBeforeTravel(speed, 60) or playerHandcuffKeyStillExists() then
                            warn(string.format("❌ [ImpelDown] Chưa tháo còng/loot tại [%s] — GIỮ W, không bay [%s]",
                                tostring(wp.Key), tostring(nextWp and nextWp.Key or "?")))
                            notify("❌ Phải tháo còng + loot xong mới được bay W kế", 5)
                            impelSetStatus("OpenLock", "⛔ Key còn / chưa loot — giữ W hiện tại")
                            task.wait(1.0)
                        else
                            if nextWp then
                                impelSetStatus("Pathfind", string.format("Đã mở còng + loot → [%s]", nextWp.Key))
                            elseif wp.IsMazeEnd then
                                impelSetStatus("Pathfind", "Đã mở còng + loot → Zones.End")
                            else
                                impelSetStatus("Pathfind", "Đã mở còng + loot → tìm đường tiếp")
                            end

                            if playerHandcuffKeyStillExists() then
                                warn("🔑 [ImpelDown] Key xuất hiện lại trước pathfind — abort")
                            elseif nextWp or wp.IsMazeEnd then
                                local escaped = pathfindOutOfMaze(wp, nextWp, speed)
                                if not escaped and not ImpelNav.active then break end
                            end

                            if playerHandcuffKeyStillExists() then
                                warn("❌ [ImpelDown] Key vẫn còn sau pathfind — KHÔNG tăng W")
                                notify("🔑 Key còn — không chuyển W", 4)
                            elseif nextWp and nextIdx then
                                setCurrentWaypointByKey(nextWp.Key)
                                saveImpelSpawn(nextWp.Key)
                            else
                                ImpelNav.currentWP = #IMPEL_WAYPOINTS + 1
                                ImpelNav.currentKey = nil
                            end
                        end
                    end
                end
            end

            task.wait(0.3)
        end

        ImpelNav.active = false
    end)
end

end -- end initImpelDownModule
local initOk, initErr = pcall(initImpelDownModule)
print(string.format("[Init] initImpelDownModule: %s", initOk and "OK" or ("LOI - " .. tostring(initErr))))

-- ================== UI: IMPEL DOWN TAB ==================

do
    Tabs.ImpelDown:AddParagraph({
        Title   = "Impel Down Auto Farm (Sky Waypoints)",
        Content = "w-3: OpenLock → Loot (đủ kiếm) → ResetStat/nâng stat → Done. Sau đó: OpenLock → Loot → mới bay W kế."
    })

    local statusParagraph = Tabs.ImpelDown:AddParagraph({
        Title   = "Sẵn sàng.",
        Content = string.format("Tổng %d WP | Spawn: [%s]", #IMPEL_WAYPOINTS, tostring(ImpelNav.spawnKey or "w-3"))
    })
    ImpelNav.statusLabel = statusParagraph

    -- Danh sách WP cho spawn dropdown
    local wpKeys = {}
    for _, wp in ipairs(IMPEL_WAYPOINTS) do
        table.insert(wpKeys, wp.Key)
    end
    if #wpKeys == 0 then wpKeys = {"w-3"} end

    local spawnDefault = ImpelNav.spawnKey or "w-3"
    do
        local ok = false
        for _, k in ipairs(wpKeys) do
            if k == spawnDefault then ok = true break end
        end
        if not ok then spawnDefault = wpKeys[1] end
    end

    Tabs.ImpelDown:AddDropdown("ImpelSpawnWP", {
        Title       = "Spawn Checkpoint (bắt đầu từ WP)",
        Description = "Tắt rồi bật lại sẽ resume từ WP này — không bay về w-3",
        Values      = wpKeys,
        Default     = spawnDefault,
        Callback    = function(value)
            if value and value ~= "" then
                saveImpelSpawn(value)
                notify("Spawn set: [" .. value .. "]", 2)
            end
        end
    })

    Tabs.ImpelDown:AddButton({
        Title       = "Đặt Spawn = WP hiện tại / đang chọn",
        Description = "Lưu checkpoint + bay tới WP đó (không teleport)",
        Callback    = function()
            local key = (Options.ImpelSpawnWP and Options.ImpelSpawnWP.Value) or ImpelNav.spawnKey or ImpelNav.currentKey or "w-3"
            local wp, idx = setCurrentWaypointByKey(key)
            if not wp then
                notify("Không tìm thấy waypoint key: " .. tostring(key), 3)
                return
            end
            saveImpelSpawn(wp.Key)
            teleportToWaypoint(wp)
            notify(string.format("📌 Spawn = [%s] (index %d)", wp.Key, idx), 3)
            impelSetStatus("Idle", string.format("Spawn checkpoint: [%s]", wp.Key))
        end
    })

    -- Toggle Bắt đầu / Dừng
    local ImpelNavToggle = Tabs.ImpelDown:AddToggle("ImpelNavToggle", {
        Title   = "Bắt đầu / Dừng Auto Farm Impel Down",
        Default = false
    })
    ImpelNavToggle:OnChanged(function()
        local active = Options.ImpelNavToggle.Value
        if active then
            impelStart()
        else
            impelStop()
        end
    end)

    -- Toggle Mở rương & Nhặt đồ
    Tabs.ImpelDown:AddToggle("ImpelChestLoot", {
        Title       = "Mở rương & Nhặt đồ rơi (Chest ESP & Loot)",
        Description = "Tắt để dùng trang bị hiện tại, không mở thêm rương",
        Default     = true
    })

    -- Toggle Tự động nâng stats
    Tabs.ImpelDown:AddToggle("ImpelAutoStats", {
        Title       = "Tự động nâng Stats (Defense 775 -> Kiếm)",
        Description = "Nâng Defense lên 775, còn lại dồn hết vào SwordMastery",
        Default     = true
    })

    -- Slider Tốc độ bay
    Tabs.ImpelDown:AddSlider("ImpelSpeed", {
        Title       = "Tốc độ bay (Fly Speed)",
        Description = "Studs/giây (mặc định 75)",
        Default     = 75,
        Min         = 30,
        Max         = 250,
        Rounding    = 1,
        Callback    = function(value) end
    })

    -- Slider Bán kính quét quái
    Tabs.ImpelDown:AddSlider("ImpelScanRadius", {
        Title       = "Bán kính quét quái (Scan Radius)",
        Description = "Bán kính tìm quái quanh waypoint (studs)",
        Default     = 80,
        Min         = 30,
        Max         = 200,
        Rounding    = 1,
        Callback    = function(value) end
    })

    -- Action Buttons
    Tabs.ImpelDown:AddButton({
        Title       = "Nâng ngay Stats (Defense 775 -> Kiếm)",
        Description = "Nâng toàn bộ SkillPoints hiện có ngay lập tức",
        Callback    = function()
            autoAllocateStats(775)
            notify("Đã nâng stats thành công!", 3)
        end
    })

    Tabs.ImpelDown:AddButton({
        Title       = "Kích hoạt Haki (Cầm Spirit Essence)",
        Description = "Mở Haki bằng Spirit Essence trên tay",
        Callback    = function()
            local char = LocalPlayer.Character
            local holding = false
            if char then
                for _, t in ipairs(char:GetChildren()) do
                    if t:IsA("Tool") and string.find(string.lower(t.Name), "spirit essence") then
                        holding = true break
                    end
                end
            end
            if not holding then
                notify("Phải CẦM Spirit Essence trên tay trước!", 4)
                return
            end
            local ok = false
            if getnilinstances then
                for _, v in next, getnilinstances() do
                    if v.ClassName == "RemoteEvent" and v.Name == "RemoteEvent" then
                        pcall(function() v:FireServer(true) ok = true end)
                    end
                end
            end
            if ok then
                notify("Đã kích hoạt Haki thành công!", 4)
            else
                notify("Không tìm thấy RemoteEvent ẩn!", 4)
            end
        end
    })

    Tabs.ImpelDown:AddButton({
        Title       = "Reset Stats (Cầm SP Reset Essence)",
        Description = "Reset lại điểm stats (cần cầm SP Reset Essence)",
        Callback    = function()
            local ok = false
            if getnilinstances then
                for _, v in next, getnilinstances() do
                    if v.ClassName == "RemoteEvent" and v.Name == "RemoteEvent" then
                        pcall(function() v:FireServer(true) ok = true end)
                    end
                end
            end
            if ok then
                notify("Đã gửi lệnh Reset Stats!", 4)
            else
                notify("Không tìm thấy RemoteEvent ẩn! Đảm bảo đang cầm SP Reset Essence.", 4)
            end
        end
    })

    Tabs.ImpelDown:AddButton({
        Title       = "Reset Spawn về w-3",
        Description = "Xóa checkpoint, lần sau bắt đầu lại từ đầu (setup w-3)",
        Callback    = function()
            setCurrentWaypointByKey("w-3")
            saveImpelSpawn("w-3")
            if Options.ImpelSpawnWP then
                pcall(function() Options.ImpelSpawnWP:SetValue("w-3") end)
            end
            notify("Đã reset spawn về w-3!", 3)
            impelSetStatus("Idle", "Spawn checkpoint: [w-3]")
        end
    })
end

-- ================== QUICK FLY DESTINATIONS ==================
-- Function riêng để không vượt 200 local registers trên executor
local function initQuickFlyModule()

local QUICK_FLY_DESTINATIONS = {
 {
  name = "Impel Down",
  pos  = Vector3.new(5917.4560546875, 182.04696655273438, -9692.3798828125),
  desc = "Cua vao nha tu Impel Down",
 },
 {
  name = "Turtleback Cave",
  pos  = Vector3.new(1981.0869140625, 333.0157775878906, -10841.2158203125),
  desc = "Hang rua",
 },
 {
  name = "Thriller Black",
  pos  = Vector3.new(10156.6767578125, 300.2189025878906, -7000.83935546875),
  desc = "Dao Thriller Bark",
 },
 {
  name = "Umi",
  pos  = Vector3.new(12652.505859375, 141.21099853515625, 2608.876220703125),
  desc = "Vung bien Umi",
 },
 {
  name = "Big Mom Island",
  pos  = Vector3.new(-7601.67, 559.63, 10075.46),
  desc = "Dao Big Mom",
 },
}

-- State cho Navigation
local NavFly = {
 active      = false,
 destName    = nil,
}

local COLLISION_REROUTE_TIMEOUT = 1.5  -- giay bi tac -> kich hoat pathfinding
local COLLISION_RAY_DIST        = 6    -- studs: khoang raycast kiem tra phia truoc

--- Kiem tra va cham phia truoc theo huong di chuyen
--- Tra ve hit result hoac nil
local function checkCollisionAhead(hrp, direction)
 if direction.Magnitude < 0.01 then return nil end
 local params = RaycastParams.new()
 params.FilterType                 = Enum.RaycastFilterType.Exclude
 params.FilterDescendantsInstances = { Character }
 local hit = workspace:Raycast(hrp.Position, direction.Unit * COLLISION_RAY_DIST, params)
 return filterPassThroughHit(hit)
end

--- Bay toi 1 diem den co ten, dung autofly + collision detection
local function flyToDestination(dest)
 if FlyPathfinder and FlyPathfinder.isNavigating then
  pcall(function() FlyPathfinder.Stop() end)
 end
 if NavFly.active then
  -- Neu dang bay den noi khac, dung truoc
  stopFly()
  NavFly.active   = false
  NavFly.destName = nil
 end

 NavFly.active   = true
 NavFly.destName = dest.name
 Fly.collisionTimer = 0
 Fly.isRerouting    = false

 notify("Bay toi: " .. dest.name, 3)

 local targetPos = dest.pos

 -- Ham getter tra ve vi tri dich (co the dieu chinh Y de bay tren cao hon)
 local function getter()
  if not NavFly.active then return nil end
  return targetPos
 end

 local function onArrive()
  NavFly.active   = false
  NavFly.destName = nil
  Fly.collisionTimer = 0
  Fly.isRerouting    = false
  setSharedStatus("NavFly", "Idle", "Da den: " .. dest.name)
  notify("Da den: " .. dest.name .. "!", 5)
  -- Tu dong tat toggle neu co
  pcall(function()
   if Options.NavFlyToggle then
    Options.NavFlyToggle:SetValue(false)
   end
  end)
 end

 -- Goi startAutoFly voi collision detection boi qua wrapper
 startAutoFly(getter, onArrive, 8)
end

-- ================== COLLISION DETECTION HOOK (patch vao autofly loop) ==================
--[[
 Do startAutoFly da duoc dinh nghia o tren, ta dung 1 Heartbeat rieng
 de kiem tra va cham trong khi dang NavFly.active.
 Neu phat hien bi ket boi vat can > COLLISION_REROUTE_TIMEOUT giay:
   1. Dung autofly hien tai
   2. Tinh duong vong qua PathfindingService den 1 waypoint trung gian
   3. Sau khi qua waypoint trung gian, bat lai autofly den dich goc
]]

-- ================== REAL-TIME STEERING AVOIDANCE ==================

-- Cac huong ne vat can theo thu tu uu tien { deltaY, goc xoay (do), nhan }
local AVOIDANCE_DIRS = {
 { dy = 18, angle =   0, label = "len thang"    },
 { dy = 15, angle =  45, label = "len-trai"     },
 { dy = 15, angle = -45, label = "len-phai"     },
 { dy =  0, angle =  90, label = "trai"         },
 { dy =  0, angle = -90, label = "phai"         },
 { dy = 25, angle = 135, label = "len-trai-lon" },
 { dy = 25, angle =-135, label = "len-phai-lon" },
}
local AVOIDANCE_RAY_DIST    = 10
local AVOIDANCE_CLEAR_SECS  = 0.3  -- giay huong goc thong lien tuc thi thoat avoidance

local function rotateY(v, angleDeg)
 local rad = math.rad(angleDeg)
 local c, s = math.cos(rad), math.sin(rad)
 return Vector3.new(v.X*c - v.Z*s, 0, v.X*s + v.Z*c)
end

local function findFreeDir(hrp, destDir, rayParams)
 for _, opt in ipairs(AVOIDANCE_DIRS) do
  local rotated = rotateY(destDir, opt.angle)
  local steer   = (rotated + Vector3.new(0, opt.dy, 0)).Unit
  local hit = workspace:Raycast(hrp.Position, steer * AVOIDANCE_RAY_DIST, rayParams)
  if not filterPassThroughHit(hit) then
   return steer, opt.label
  end
 end
 return nil
end

local Avoidance = { active = false, steerDir = nil, steerLabel = nil, clearTimer = 0 }

local avoidParams = RaycastParams.new()
avoidParams.FilterType = Enum.RaycastFilterType.Exclude

RunService.Heartbeat:Connect(function(dt)
 if (FlyPathfinder and FlyPathfinder.isNavigating) then
  return -- Pathfinder đang chiếm quyền: không override velocity
 end
 if not NavFly.active or not Status.Fly then
  Fly.collisionTimer   = 0
  Avoidance.active     = false
  Avoidance.clearTimer = 0
  return
 end

 local hrp = Character and Character:FindFirstChild("HumanoidRootPart")
 if not hrp or not hrp.Parent then return end

 local bv = Fly.flyBV
 if not bv or not bv.Parent then return end

 local spd = Options.NavSpeed and Options.NavSpeed.Value or 60

 -- Tinh huong thang den dich
 local destPos
 for _, d in ipairs(QUICK_FLY_DESTINATIONS) do
  if d.name == NavFly.destName then destPos = d.pos break end
 end
 if not destPos then return end

 local toDestFlat = Vector3.new(destPos.X - hrp.Position.X, 0, destPos.Z - hrp.Position.Z)
 if toDestFlat.Magnitude < 1 then return end
 local destDir = toDestFlat.Unit

 -- Cap nhat filter cho raycast
 avoidParams.FilterDescendantsInstances = { Character }

 -- Raycast kiem tra huong goc den dich
 local fwdHit = filterPassThroughHit(workspace:Raycast(hrp.Position, destDir * COLLISION_RAY_DIST, avoidParams))
 debugRecordRay(hrp.Position, hrp.Position + destDir * COLLISION_RAY_DIST, fwdHit and DEBUG_RAY_COLORS.blocked or DEBUG_RAY_COLORS.clear)

 if not Avoidance.active then
  -- === BINH THUONG: chi can detect va cham ===
  if fwdHit then
   Fly.collisionTimer = Fly.collisionTimer + dt
if Fly.collisionTimer >= COLLISION_REROUTE_TIMEOUT then
    Fly.collisionTimer = 0
    local freeDir, label = findFreeDir(hrp, destDir, avoidParams)
    if freeDir then
     Avoidance.active     = true
     Avoidance.steerDir   = freeDir
     Avoidance.steerLabel = label
     Avoidance.clearTimer = 0
     notify("Ne vat can: " .. label, 2)
     print("[Avoidance] Bat dau: " .. label)
    else
     -- Tat ca huong deu bi chan -> bay thang len cao
     bv.Velocity = Vector3.new(0, spd, 0)
     print("[Avoidance] Bi ket hoan toan, bay len cao!")
    end
   end
  else
   Fly.collisionTimer = 0
  end
 else
  -- === AVOIDANCE MODE ===
  if not fwdHit then
   -- Huong goc da thong, dem thoi gian xac nhan
   Avoidance.clearTimer = Avoidance.clearTimer + dt
   if Avoidance.clearTimer >= AVOIDANCE_CLEAR_SECS then
    -- Thoat avoidance, autofly loop se tu dieu chinh velocity ve dich
    Avoidance.active     = false
    Avoidance.steerDir   = nil
    Avoidance.clearTimer = 0
    Fly.collisionTimer   = 0
    print("[Avoidance] Duong thong, quay lai bay ve dich.")
    return
   end
  else
   -- Van bi chan, cap nhat huong ne neu can
   Avoidance.clearTimer = 0
   local newDir, newLabel = findFreeDir(hrp, destDir, avoidParams)
   if newDir then
    if newLabel ~= Avoidance.steerLabel then
     print("[Avoidance] Doi huong: " .. tostring(newLabel))
     Avoidance.steerLabel = newLabel
    end
    Avoidance.steerDir = newDir
   else
    -- Toan bo bi chan, bay len
    Avoidance.steerDir = Vector3.new(0, 1, 0)
   end
  end

  -- Ap dung velocity ne (override autofly hien tai)
  if Avoidance.steerDir and bv.Parent then
   bv.Velocity = Avoidance.steerDir * spd
   debugRecordRay(hrp.Position, hrp.Position + Avoidance.steerDir * 12, DEBUG_RAY_COLORS.steer)
  end
 end
end)

-- ================== UI: NAVIGATION TAB ==================

do
 Tabs.Navigation:AddParagraph({
  Title   = "Quick Fly",
  Content = "Bay nhanh den cac diem den. Co phat hien va cham va tu dong tim duong vong."
 })

 -- Slider toc do Navigation
 Tabs.Navigation:AddSlider("NavSpeed", {
  Title       = "Toc do bay",
  Description = "Studs/giay (mac dinh 60)",
  Default     = 60,
  Min         = 20,
  Max         = 200,
  Rounding    = 1,
  Callback    = function(value)
   Fly.flySpeed = value
  end
 })

  -- Nut bay den tung diem
  for _, dest in ipairs(QUICK_FLY_DESTINATIONS) do
   local d = dest  -- capture cho closure
   Tabs.Navigation:AddButton({
    Title       = "Bay toi: " .. d.name,
    Description = d.desc .. string.format(" (%.0f, %.0f, %.0f)", d.pos.X, d.pos.Y, d.pos.Z),
    Callback    = function()
     if not isPlayerAlive() then
      notify("Nhan vat chua san sang!", 3)
      return
     end
     Fly.flySpeed = Options.NavSpeed and Options.NavSpeed.Value or 60
     setSharedStatus("NavFly", "Bay", "Bay toi: " .. d.name)
     flyToDestination(d)
    end
   })
  end

  -- Nut dung bay
  Tabs.Navigation:AddButton({
   Title       = "Dung bay",
   Description = "Dung navigation hien tai",
   Callback    = function()
    NavFly.active      = false
    NavFly.destName    = nil
    Fly.isRerouting    = false
    Fly.collisionTimer = 0
    stopFly()
    setSharedStatus("NavFly", "Idle", "Navigation da dung")
    notify("Da dung bay.", 2)
   end
  })
 end

end -- end initQuickFlyModule
initQuickFlyModule()

-- ================== UI: TOOLS TAB ==================

do
 -- === BOSS TIMER DISPLAY ===
 Tabs.Tools:AddParagraph({
  Title   = "⏰ Boss Spawn Timer",
  Content = "Thoi gian countdown den lan spawn tiep theo cua cac boss."
 })

 local bossTimerLabels = {}
 for _, boss in ipairs(BOSS_LIST) do
  local label = Tabs.Tools:AddParagraph({
   Title   = boss.name .. " (" .. boss.intervalMinutes .. " phut/lan)",
   Content = "Dang tinh..."
  })
  bossTimerLabels[boss.name] = label
 end

 -- Cap nhat boss timer moi giay
 local lastTimerUIUpdate = 0
 RunService.Heartbeat:Connect(function()
  local now = os.time()
  if now - lastTimerUIUpdate < 1 then return end
  lastTimerUIUpdate = now

  for _, boss in ipairs(BOSS_LIST) do
   local _, secondsLeft = readNextBossSpawnTime(boss.intervalMinutes)
   local label = bossTimerLabels[boss.name]
   if label then
    local timeStr = formatSecondsToHMS(secondsLeft)
    local msg
    if secondsLeft <= 5 then
     msg = "⚔️ BOSS DA SPAWN!"
    else
     msg = "⏰ Con lai: " .. timeStr
    end
    pcall(function()
     label:SetTitle(boss.name .. " - " .. msg)
    end)
   end
  end
 end)

 -- === COORDINATE GETTER ===
 Tabs.Tools:AddParagraph({
  Title   = "📍 Lay Toa Do",
  Content = "Nhan nut de lay toa do hien tai. Toa do se hien thi trong o ben duoi de ban co the sao chep."
 })

 -- === VISUAL DEBUG ===
 local VisualDebugToggle = Tabs.Tools:AddToggle("VisualDebug", {
  Title   = "Visual Debug (Drawing 2D)",
  Default = false
 })
 VisualDebugToggle:OnChanged(function()
  local on = Options.VisualDebug.Value
  local ok = debugSetEnabled(on)
  if ok then
   notify(on and "Visual Debug: ON" or "Visual Debug: OFF", 2)
  end
 end)

 local CoordInput = Tabs.Tools:AddInput("CoordDisplay", {
  Title       = "Toa do hien tai",
  Default     = "",
  Placeholder = "Nhan nut 'Lay toa do'...",
  Numeric     = false,
 })

 Tabs.Tools:AddButton({
  Title       = "Lay toa do",
  Description = "Lay toa do X, Y, Z hien tai cua nhan vat",
  Callback    = function()
   local pos = getPlayerPosition()
   if pos then
    local coordStr = string.format("%.2f, %.2f, %.2f", pos.X, pos.Y, pos.Z)
    Options.CoordDisplay:SetValue(coordStr)
    notify("Toa do: " .. coordStr, 3)
   else
    notify("Khong the lay toa do! Nhan vat chua san sang.", 3)
   end
  end
 })

 Tabs.Tools:AddButton({
  Title       = "Lay toa do (Vector3)",
  Description = "Dinh dang Vector3.new(X, Y, Z) de dan vao code",
  Callback    = function()
   local pos = getPlayerPosition()
   if pos then
    local coordStr = string.format("Vector3.new(%.4f, %.4f, %.4f)", pos.X, pos.Y, pos.Z)
    Options.CoordDisplay:SetValue(coordStr)
    notify("Toa do Vector3 da sao chep!", 3)
   else
    notify("Khong the lay toa do! Nhan vat chua san sang.", 3)
   end
  end
 })

 -- === SafeMove: hàm thông dụng (không CFrame teleport) ===
 Tabs.Tools:AddParagraph({
  Title   = "SafeMove (anti-cheat)",
  Content = "Bay BodyVelocity — _G.safeFlyTo(pos, speed) | safeFlyNear | safeFace | safeClearMovers | safeStopMove"
 })

 -- Export / ghi đè _G helpers dùng FlyPathfinder khi có
 local function exportSafeMoveGlobals()
  local function flyToPos(pos, speed, opts)
   if typeof(pos) ~= "Vector3" then
    warn("[SafeMove] pos phải là Vector3")
    return false
   end
   speed = tonumber(speed) or 70
   opts = opts or {}
   if FlyPathfinder and FlyPathfinder.FlyTo then
    local mode = (opts.mode) or "DirectLow"
    local taskName = opts.task or "farm"
    local ok = FlyPathfinder.FlyTo(pos, speed, mode, taskName)
    if not ok and mode == "DirectLow" then
     ok = FlyPathfinder.FlyTo(pos, speed, "Smart3D", taskName)
    end
    return ok and true or false
   end
   if _G.SafeMove and _G.SafeMove.flyTo then
    return _G.SafeMove.flyTo(pos, speed, opts)
   end
   warn("[SafeMove] Chưa có FlyPathfinder / SafeMove.lua")
   return false
  end

  _G.safeFlyTo = flyToPos
  _G.safeFlyNear = function(pos, offset, speed)
   offset = offset or Vector3.new(0, 3, 4)
   return flyToPos(pos + offset, speed)
  end
  _G.safeFace = function(hrp, targetPos, gyro)
   hrp = hrp or getHumanoidRootPart()
   gyro = gyro or (FlyPathfinder and FlyPathfinder.currentGyro) or (Fly and Fly.flyGyro)
   return faceTowardPosition(hrp, targetPos, gyro)
  end
  _G.safeClearMovers = function(hrp)
   hrp = hrp or getHumanoidRootPart()
   if not hrp then return end
   if FlyPathfinder and FlyPathfinder.CleanupPhysics then
    pcall(FlyPathfinder.CleanupPhysics)
   end
   for _, n in ipairs({ "SafeMove_BV", "SafeMove_Gyro", "FlyPathfinder_BV", "FlyPathfinder_Gyro" }) do
    local c = hrp:FindFirstChild(n)
    if c then pcall(function() c:Destroy() end) end
   end
  end
  _G.safeStopMove = function()
   if FlyPathfinder and FlyPathfinder.Stop then pcall(FlyPathfinder.Stop) end
   if stopFly then pcall(stopFly) end
   _G.safeClearMovers()
  end

  -- Gói bảng nếu chưa có SafeMove.lua
  if not _G.SafeMove then
   _G.SafeMove = {
    flyTo = flyToPos,
    flyNear = _G.safeFlyNear,
    face = _G.safeFace,
    clearMovers = _G.safeClearMovers,
    stop = _G.safeStopMove,
    teleportTo = function(pos, offset)
     warn("[SafeMove] teleportTo → flyNear (không CFrame)")
     return _G.safeFlyNear(pos, offset)
    end,
   }
  end
 end
 exportSafeMoveGlobals()

 Tabs.Tools:AddButton({
  Title       = "Dừng mọi di chuyển (SafeMove)",
  Description = "Stop fly / pathfinder + xóa BodyVelocity SafeMove",
  Callback    = function()
   if _G.safeStopMove then _G.safeStopMove() end
   notify("Đã dừng SafeMove / Fly", 2)
  end
 })
end
