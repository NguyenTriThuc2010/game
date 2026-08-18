-- [Module: lib_gui.lua - User Interface & Control Bindings]
local Players = game:GetService("Players")
local Player = Players.LocalPlayer
_G.__SYS = _G.__SYS or {}
local SYS = _G.__SYS

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
