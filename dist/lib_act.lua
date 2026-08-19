-- [Module: lib_act.lua - Action & Combat Engine]
local Players = game:GetService("Players")
local Player = Players.LocalPlayer
_G.__SYS = _G.__SYS or {}
local SYS = _G.__SYS


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
  -- [FlyMode] Giới hạn độ cao SAFE: trần 15 studs trên đất/nước, sàn -1
  bv.Velocity = (_G.clampSafeAltitude or clampSafeAltitude)(hrp, horizVelocity + Vector3.new(0, vertVelocity, 0))

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

-- NPC quest khả dụng: có position + minLevel <= cấp + có targets (bỏ Zen/Noah/Zhen chưa có thông tin)
-- CHỌN QUEST PHÙ HỢP CẤP: ưu tiên minLevel CAO NHẤT <= cấp hiện tại (quest đúng tầm, rewards tốt);
-- cùng minLevel thì chọn cái GẦN NHẤT. Bỏ qua NPC trong cooldown + pauseUntil.
QuestAPI.skipUntil = {}
QuestAPI.pauseUntil = 0
QuestAPI.findAvailable = function()
 if os.clock() < QuestAPI.pauseUntil then return nil end
 local lvl = QuestAPI.getPlayerLevel()
 local myPos = getPlayerPosition()
 local nowT = os.clock()
 -- Lay danh sach quest da hoan thanh de loc bo (dung QuestName hoac db.quest lam key)
 local completed = getCompletedQuests()
 local bestName, bestDb, bestMin, bestDist = nil, nil, -1, math.huge
 for npcName, db in pairs(QuestDB) do
  -- Kiem tra quest nay da hoan thanh chua (khop voi db.quest hoac npcName)
  local questKey = db.quest or ("Help " .. npcName)
  local alreadyDone = completed[questKey] or completed[npcName]
  if db.position and db.minLevel and db.targets and db.minLevel <= lvl
   and not alreadyDone
   and not (QuestAPI.skipUntil[npcName] and QuestAPI.skipUntil[npcName] > nowT) then
   local d = myPos and (db.position - myPos).Magnitude or 0
   if db.minLevel > bestMin or (db.minLevel == bestMin and d < bestDist) then
    bestName, bestDb, bestMin, bestDist = npcName, db, db.minLevel, d
   end
  end
 end
 return bestName, bestDb
end

-- Bán kính "đứng gần NPC quest" để kích hoạt quest đó (đứng cạnh + bật farm → nhận ngay, không bay xa)
local QUEST_NEAR_RADIUS = 3

--- NPC quest GẦN NHẤT (minLevel <= cấp): dùng khi ĐỨNG GẦN NPC muốn farm (anyDistance=false → trong
--- bán kính QUEST_NEAR_RADIUS) hoặc FALLBACK khi không thể bay tới quest hợp lý (anyDistance=true).
--- excludeName: loại NPC vừa thất bại. Trả (name, db) hoặc (nil, nil)
QuestAPI.findNearest = function(excludeName, anyDistance)
 if os.clock() < QuestAPI.pauseUntil then return nil end
 local lvl = QuestAPI.getPlayerLevel()
 local myPos = getPlayerPosition()
 local nowT = os.clock()
 -- Lay danh sach quest da hoan thanh de loc bo
 local completed = getCompletedQuests()
 local bestName, bestDb, bestDist = nil, nil, math.huge
 for npcName, db in pairs(QuestDB) do
  local questKey = db.quest or ("Help " .. npcName)
  local alreadyDone = completed[questKey] or completed[npcName]
  if npcName ~= excludeName and db.position and db.minLevel and db.targets and db.minLevel <= lvl
   and not alreadyDone
   and not (QuestAPI.skipUntil[npcName] and QuestAPI.skipUntil[npcName] > nowT) then
   local d = myPos and (db.position - myPos).Magnitude or 0
   if d <= QUEST_NEAR_RADIUS or anyDistance then
    if d < bestDist then bestName, bestDb, bestDist = npcName, db, d end
   end
  end
 end
 return bestName, bestDb
end

-- Bay tới NPC + nhận quest (tối đa 2 lần, MỖI lần đều phải cách NPC <= 5 studs theo serverPos)
QuestAPI.goTake = function(npcName, db, speed)
 local fp = _G.FlyPathfinder
 if not (npcName and db) then return false end
 local npcPos = db.position or getNPCPosition(npcName)
 if not npcPos then
  QuestAPI.skipUntil[npcName] = os.clock() + 30
  return false
 end
 if not db.position then db.position = npcPos end

 -- Cổng CẤP (bước đầu tiên): kiểm tra cấp TRƯỚC khi bay/nhận
 local lvlGate = QuestAPI.getPlayerLevel()
 if db.minLevel and lvlGate and lvlGate < db.minLevel then
  QuestAPI.skipUntil[npcName] = os.clock() + 30
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
    -- → buộc phải đứng GẦN NPC quest đó (≤ QUEST_NEAR_RADIUS = 3 studs) mới được farm tiếp.
    -- Nếu xa → hủy quest cũ để nhận quest cấp cao hơn.
    if Options.AutoQuest.Value and db and db.minLevel then
     local lvl = QuestAPI.getPlayerLevel()
     local nowT = os.clock()
     local maxMin = db.minLevel
     for npcName2, db2 in pairs(QuestDB) do
      if db2.position and db2.minLevel and db2.targets and db2.minLevel <= lvl
       and not (QuestAPI.skipUntil[npcName2] and QuestAPI.skipUntil[npcName2] > nowT) then
       if db2.minLevel > maxMin then maxMin = db2.minLevel end
      end
     end
     if maxMin > db.minLevel then
      local myPos = getPlayerPosition()
      if not myPos or (myPos - db.position).Magnitude > QUEST_NEAR_RADIUS then
       setAutoFarmStatus("WaitingQuest", string.format(
        "Quest '%s' (minLevel %d) thấp hơn max %d — xa NPC > %d studs → hủy để lấy quest cao hơn",
        npcName, db.minLevel, maxMin, QUEST_NEAR_RADIUS))
       QuestAPI.cancelQuest()
       QuestAPI.pauseUntil = 0 -- nhận quest mới ngay
       task.wait(0.5)
       continue
      end
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
