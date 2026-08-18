-- [Module: lib_dat.lua - Data Registry & Quest API]
local Players = game:GetService("Players")
local Player = Players.LocalPlayer
_G.__SYS = _G.__SYS or {}
local SYS = _G.__SYS

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
 ["Robert"] = { island = "Shell's Town", minLevel = 20, targets = "Corrupt Marines",  count = 8, action = "kill", position = Vector3.new(-1442.0906, 9.8750, -5098.7837) },
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
