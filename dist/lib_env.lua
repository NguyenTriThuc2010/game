-- [Module: lib_env.lua - Environment & Core Utilities]
local Players = game:GetService("Players")
local Player = Players.LocalPlayer
local LocalPlayer = Player
_G.__SYS = _G.__SYS or {}
local SYS = _G.__SYS

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
