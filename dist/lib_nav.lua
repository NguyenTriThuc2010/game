-- [Module: lib_nav.lua - Navigation & Flight Engine]
local Players = game:GetService("Players")
local Player = Players.LocalPlayer
_G.__SYS = _G.__SYS or {}
local SYS = _G.__SYS

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
-- tiltMode đã bỏ ("dive" = lật người nằm ngang bị XÓA theo yêu cầu) — luôn giữ người đứng
local function faceTowardPosition(hrp, targetPos, gyro, tiltMode)
    if not (hrp and targetPos) then return hrp and hrp.CFrame or CFrame.new() end

    -- FaceLook override: hướng mặt thẳng vào target (nghiêng lên/xuống theo 3D)
    if FaceLook.active and FaceLook.targetGetter then
        local t = FaceLook.targetGetter()
        if t then
            local lookCF = CFrame.lookAt(hrp.Position, t)
            local setCF = lookCF
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
    local setCF = lookCF
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

--- Có cách tiêu hao stamina khi bay cao không (BlackLeg → Sky Walk / Rokushiki → Geppo)?
--- Cache 2s — hasBlackLeg() đọc inventory JSON đắt
local hasStaminaDrainAbility = function()
 if hasBlackLeg() then return true end
 local ok, style = pcall(function() return getFightingStyle() end)
 if ok and type(style) == "string" then
  local s = string.lower(style)
  return s:find("rokushiki", 1, true) ~= nil or s:find("geppo", 1, true) ~= nil
 end
 return false
end
_G.hasStaminaDrainAbility = hasStaminaDrainAbility

local canDrainStamina = function()
 local nowT = os.clock()
 if drainOkCache.value == nil or nowT - drainOkCache.at > DRAIN_CACHE_SECONDS then
  drainOkCache.value = hasStaminaDrainAbility()
  drainOkCache.at = nowT
 end
 return drainOkCache.value == true
end

-- ================== FLIGHT MODE: SAFE / RISK ==================
-- SAFE : không Geppo + không BlackLeg → KHÔNG tiêu hao được stamina → luật game
--        chỉ cho bay cao ≤ 15 studs. Bám địa hình, vượt vật cản xong phải HẠ NGAY
--        về độ cao an toàn (không lơ lửng trên cao — tốn thời gian + dễ bị watchdog).
-- RISK : có Geppo / BlackLeg → drain được stamina → được bay cao (SkyCruise 60+,
--        A* 3D tầng 8/20/45, vượt tường bằng cầu trời) nhưng phải tick drain đều.
local FlyMode = { state = "SAFE", changedAt = 0 }
_G.FlyMode = FlyMode
local function evaluateFlyMode()
 return canDrainStamina() and "RISK" or "SAFE"
end
local function refreshFlyMode()
 local newMode = evaluateFlyMode()
 if newMode ~= FlyMode.state then
  local old = FlyMode.state
  FlyMode.state = newMode
  FlyMode.changedAt = os.clock()
  print(string.format("[FlyMode] %s → %s (%s)", old, newMode,
   newMode == "RISK" and "có Geppo/BlackLeg → bay cao" or "không drain → bám thấp"))
 end
 return FlyMode.state
end

--- Giới hạn tốc độ hệ thống theo FlyMode:
--- SAFE (không Geppo/BlackLeg) → tối đa 70 studs/s (KHÔNG vượt — watchdog chụp tốc độ cao)
--- RISK (có Geppo/BlackLeg)     → tối đa 300 studs/s
local function maxFlightSpeed()
 return FlyMode.state == "SAFE" and 70 or 300
end
_G.maxFlightSpeed = maxFlightSpeed

--- [FlyMode] Giới hạn độ cao SAFE: tối đa 15 studs trên mặt đất/nước (càng thấp càng an toàn),
--- thấp nhất -1 stud (không cắm đầu xuống đất). RISK: không giới hạn độ cao.
--- Trả về velocity đã clamp Y theo trần/sàn hợp lệ.
--- [Lagfix] Cache groundOrSeaBelow theo ô lưới 20 studs (mặt đất ít đổi khi di chuyển)
--- → không raycast mỗi frame (hàm này gọi mỗi frame trong mọi loop bay).
local _altCache = { key = nil, gy = nil }
local function clampSafeAltitude(hrp, vel)
 if FlyMode.state ~= "SAFE" then return vel end
 local px, pz = hrp.Position.X, hrp.Position.Z
 local key = string.format("%.0f|%.0f", math.floor(px / 20), math.floor(pz / 20))
 local gy = _altCache.gy
 if _altCache.key ~= key then
  gy = groundOrSeaBelow(hrp.Position)
  _altCache.key = key
  _altCache.gy = gy
 end
 if not gy then return vel end
 local height = hrp.Position.Y - gy
 if height > 15 then
  local dy = (gy + 15 - hrp.Position.Y) * 3
  return Vector3.new(vel.X, math.max(dy, vel.Y), vel.Z)
 elseif height < -1 then
  local dy = (gy - 1 - hrp.Position.Y) * 3
  return Vector3.new(vel.X, math.min(dy, vel.Y), vel.Z)
 end
 return vel
end
_G.clampSafeAltitude = clampSafeAltitude

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
 gyro.MaxTorque = Vector3.new(0, 1, 1) * math.huge -- [FlyMode] khóa xoay trục X (pitch): không cho lật người
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
 refreshFlyMode()
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
gyro.MaxTorque = Vector3.new(0,1,1) * math.huge -- [FlyMode] khóa xoay trục X (pitch)
   gyro.P         = 3000
   gyro.D         = 100
   gyro.CFrame    = hrp.CFrame
   gyro.Parent    = hrp
   Fly.flyGyro    = gyro
  end

  local camCFrame = workspace.CurrentCamera.CFrame
  -- [FlyMode] Giới hạn tốc độ hệ thống: SAFE ≤ 70, RISK ≤ 300
  local effFlySpeed = math.min(Fly.flySpeed, maxFlightSpeed())
  local velocity, moveDir = calculateManualHorizontalVelocity(camCFrame, effFlySpeed)

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
   -- [FlyMode] Giới hạn độ cao SAFE: trần 15 studs trên đất/nước, sàn -1
   bv.Velocity = clampSafeAltitude(hrp, velocity + Vector3.new(0, yVelocity, 0))
   -- Xoay nhan vat theo huong di chuyen ngang (bo qua Y de khong nghieng)
   local flatDir = Vector3.new(moveDir.X, 0, moveDir.Z)
   if flatDir.Magnitude > 0.01 then
    gyro.CFrame = CFrame.new(hrp.Position, hrp.Position + flatDir)
   end
  else
   bv.Velocity = clampSafeAltitude(hrp, Vector3.new(0, yVelocity, 0))
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
 refreshFlyMode()
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
   gyro.MaxTorque = Vector3.new(0,1,1) * math.huge -- [FlyMode] khóa xoay trục X (pitch)
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
  local effFlySpeed = math.min(Fly.flySpeed, maxFlightSpeed())
  local horizVelocity, horizontalDir, flatDistance =
   calculateAutoHorizontalVelocity(hrp.Position, targetPos, arriveDistance, effFlySpeed)

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
      -- [FlyMode] SAFE (không Geppo/BlackLeg): cấm vọt cao bất hợp pháp →
      -- không phóng 500 studs, giữ sát mặt đất (≤ ngưỡng watchdog 15)
      if FlyMode.state == "SAFE" then
       desiredY = terrainFloor
      else
       desiredY = BASE_Y + BOOST_HEIGHT
      end
      Fly.bridgeActive = false
     end
    end
   else
    -- [FlyMode] SAFE: không vọt cao bất hợp pháp → giữ sát mặt đất
    if FlyMode.state == "SAFE" then
     desiredY = terrainFloor
    else
     desiredY = BASE_Y + BOOST_HEIGHT
    end
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
  bv.Velocity = clampSafeAltitude(hrp, horizVelocity + Vector3.new(0, vertVelocity, 0))

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
-- Khi đang bay (FlyPathfinder) cao > 15 studs so với mặt đất mà stamina
-- không đổi trong 0.15s → Sky Walk bị server từ chối (bay bất hợp pháp)
-- → hủy bay ngay + chặn cất cánh lại vài giây.
local FLIGHT_HEIGHT_MIN          = 15
local STAMINA_FREEZE_LIMIT       = 3

-- Lưu tham số FlyTo cuối cùng để auto-resume sau khi chạm đất
local lastFlyToParams            = nil
local watchdogCancelledTask      = nil
local waitingForGroundTouch      = false

-- Kiểm tra nhân vật đã chạm đất / mặt sàn / mặt biển chưa
local function isCharacterOnGround()
    local char = Character or Player.Character
    if not char then return false end
    local hum = char:FindFirstChildOfClass("Humanoid")
    if hum then
        local mat = hum.FloorMaterial
        if mat and mat ~= Enum.Material.Air then
            return true
        end
        local state = hum:GetState()
        if state == Enum.HumanoidStateType.Landed or state == Enum.HumanoidStateType.Running then
            return true
        end
    end
    local hrp = char:FindFirstChild("HumanoidRootPart")
    if hrp then
        local gy, isSea = groundOrSeaBelow(hrp.Position)
        if gy and (hrp.Position.Y - gy) <= 4.0 then
            return true
        end
    end
    return false
end

local function cancelFlightByWatchdog(reason)
    -- Lưu chuyến bay bị hủy, đánh dấu BẮT BUỘC CHỜ CHẠM ĐẤT
    if FlyPathfinder.currentTask and lastFlyToParams then
        watchdogCancelledTask = {
            taskName     = FlyPathfinder.currentTask,
            destination  = lastFlyToParams.destination,
            speed        = lastFlyToParams.speed,
            mode         = lastFlyToParams.mode,
            waitingForGround = true,
            resumeAfter  = nil
        }
    end
    waitingForGroundTouch = true
    if FlyPathfinder.isNavigating then
        FlyPathfinder.Stop()
    end
    -- Nhả PlatformStand để nhân vật rơi xuống đất tự nhiên
    local hum = Character and Character:FindFirstChildOfClass("Humanoid")
    if hum then
        hum.PlatformStand = false
    end
    pcall(notify, "[Watchdog] " .. reason .. " — Rơi xuống chạm đất để hồi bay!", 3)
    print(string.format("[Watchdog] %s -> Dang cho cham dat de hoi stamina...", reason))
end

FlyPathfinder.isFlightBlocked = function()
    if waitingForGroundTouch then
        if not isCharacterOnGround() then
            return true
        end
    end
    return false
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

local staminaWatch = { lastValue = nil, lastChange = 0, lastGroundCheck = 0, lastGroundY = nil }
RunService.Heartbeat:Connect(function()
    -- AUTO-RESUME KHI CHẠM ĐẤT:
    if watchdogCancelledTask then
        if watchdogCancelledTask.waitingForGround then
            if isCharacterOnGround() then
                -- Đã chạm đất! Chờ 0.5s để hồi phục stamina rồi mới bay tiếp
                watchdogCancelledTask.waitingForGround = false
                watchdogCancelledTask.resumeAfter = os.clock() + 0.5
                waitingForGroundTouch = false
                print("[Watchdog] Da cham dat thanh cong! Chuan bi cat canh tiep...")
            end
        elseif watchdogCancelledTask.resumeAfter and os.clock() >= watchdogCancelledTask.resumeAfter then
            local t = watchdogCancelledTask
            watchdogCancelledTask = nil
            if not FlyPathfinder.isNavigating and isPlayerAlive() then
                print(string.format("[Watchdog] Da cham dat xong — Tiep tuc bay task=%s", t.taskName))
                FlyPathfinder.FlyTo(t.destination, t.speed, t.mode, t.taskName)
            end
        end
    end

    if not FlyPathfinder.isNavigating then
        staminaWatch.lastValue = nil
        return
    end
    local hrp = getHumanoidRootPart()
    if not (hrp and isPlayerAlive()) then return end

    -- [Lagfix] Throttle groundOrSeaBelow 0.2s/lần (mặt đất dưới chân ít đổi khi bay)
    -- → watchdog không raycast mỗi frame
    local nowG = os.clock()
    if nowG - staminaWatch.lastGroundCheck >= 0.2 then
        staminaWatch.lastGroundCheck = nowG
        staminaWatch.lastGroundY = groundOrSeaBelow(hrp.Position)
    end
    local groundY = staminaWatch.lastGroundY
    local height = groundY and (hrp.Position.Y - groundY) or 300
    if height <= FLIGHT_HEIGHT_MIN then
        staminaWatch.lastValue = nil
        return
    end

    -- [FlyMode] SAFE: không có cách tiêu hao → bay cao > 15 là BẤT HỢP PHÁP NGAY
    -- (không chờ stamina-freeze 3s) — "không delay khi check trạng thái bay quá độ cao ở SAFE".
    if FlyMode.state == "SAFE" then
        staminaWatch.lastValue = nil
        cancelFlightByWatchdog(string.format(
            "SAFE bay cao %.0f studs (>%d) — HỦY NGAY (không drain được stamina)",
            height, FLIGHT_HEIGHT_MIN
        ))
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
-- bằng BodyGyro (không ghi hrp.CFrame — anti-cheat). Chạy độc lập với combat loop.
-- Tư thế nằm ngang (dive) đã XÓA theo yêu cầu — luôn đứng thẳng.
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
--  OBSTACLE-CROSSED DESCENT — phát hiện "đã vượt xong vật cản → hạ về độ cao an toàn"
--  FlyPathfinder (Smart3D/SkyCruise) CHƯA có state này như legacy Fly (bridgeActive):
--  sau khi leo tường/cây, nó cứ bay lơ lửng trên cao (tốn stamina + watchdog dễ nghi).
--  Giải pháp: theo dõi wasBlocked → clear. Khi tia tới target từng bị chặn rồi
--  THÔNG TRỞ LẠI = đã qua vật cản → bật phase DESCEND tới độ cao an toàn
--  (SAFE: terrainFloor + margin; RISK: giữ nguyên nếu vẫn cần cao cho chặng tới).
local ObDescent = {
    wasBlocked  = false,  -- tia tới target đang bị chặn bởi tường (đang vượt)
    descending  = false,  -- đang trong phase hạ xuống độ cao an toàn
    safeY       = nil,    -- độ cao an toàn cần hạ tới
    descendUntil= 0,      -- thời điểm kết thúc hạ (có thể duy trì vài giây)
    lastCheck   = 0,      -- throttle raycast check (tốn)
}

local OBSTACLE_DESCEND_CHECK_INTERVAL = 0.25
local OBSTACLE_DESCEND_HOLD_SECONDS    = 3

--- Kiểm tra mỗi frame: đã vượt xong vật cản chưa → trả về desiredY an toàn (hoặc nil)
--- Chỉ chạy raycast 4 lần/giây (interval), giữa các lần dùng cache → không lag
local function getObstacleDescendY(hrpPos, targetPos, targetModel)
    if not (hrpPos and targetPos) then return nil end
    local now = os.clock()

    -- Đang trong phase hạ (hold) → giữ nguyên safeY tới hết hold
    if ObDescent.descending then
        if now < ObDescent.descendUntil then
            return ObDescent.safeY
        end
        ObDescent.descending = false
        ObDescent.safeY = nil
        return nil
    end

    -- Throttle raycast: không check mỗi frame
    if now - ObDescent.lastCheck < OBSTACLE_DESCEND_CHECK_INTERVAL then
        return nil
    end
    ObDescent.lastCheck = now

    local blocked = isSeparatedByThickWall(hrpPos, targetPos, targetModel, true)
    if blocked then
        -- Vẫn bị chắn: nhớ đang vượt
        ObDescent.wasBlocked = true
        return nil
    end

    -- Tia THÔNG trở lại sau khi từng bị chắn → ĐÃ VƯỢT XONG vật cản
    if ObDescent.wasBlocked then
        ObDescent.wasBlocked = false
        ObDescent.descending = true
        ObDescent.descendUntil = now + OBSTACLE_DESCEND_HOLD_SECONDS

        -- Độ cao an toàn: mặt đất/nước dưới chân + margin (SAFE)
        local gy, isSea = groundOrSeaBelow(hrpPos)
        local safeY
        if isSea then
            safeY = gy + SEA_LOW_FLY_MARGIN
        else
            safeY = gy + TERRAIN_FOLLOW_MARGIN
        end
        ObDescent.safeY = safeY

        -- RISK: nếu target còn XA (cần giữ cao cho chặng sau) thì không ép hạ sát đất,
        -- chỉ hạ về mức tối thiểu hợp pháp khi ở mode SAFE
        local mode = (canDrainStamina() and "RISK") or "SAFE"
        if mode == "RISK" and ObDescent.safeY then
            local distToTarget = (hrpPos - targetPos).Magnitude
            if distToTarget > 150 then
                -- Còn xa: hạ về độ cao bay cao bình thường (không sát đất)
                ObDescent.safeY = math.max(ObDescent.safeY, hrpPos.Y - 30)
            end
        end
        print(string.format("[Fly] Đã vượt vật cản → hạ về y=%.1f (%s)", ObDescent.safeY, mode))
        return ObDescent.safeY
    end
    return nil
end

local function resetObstacleDescent()
    ObDescent.wasBlocked = false
    ObDescent.descending = false
    ObDescent.safeY = nil
    ObDescent.descendUntil = 0
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
 -- [FlyMode] LOS thẳng thông → không cần PFS/A* (PFS ComputeAsync là server-blocking gây lag
 -- trên mode SAFE). Chỉ tính đường chi tiết khi có vật cản chặn thật sự.
 if has3DLineOfSight(currentPos, subGoal, ignoreList) then return { currentPos, subGoal } end
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
        gyro.MaxTorque = Vector3.new(0, 1, 1) * math.huge -- [FlyMode] khóa xoay trục X (pitch)
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

    -- [FlyMode] Cập nhật trạng thái SAFE/RISK cho chuyến bay này
    refreshFlyMode()
    resetObstacleDescent()

    FlyPathfinder.isNavigating = true
    FlyPathfinder.SetupPhysics()

    local speed = math.min(tonumber(customSpeed) or (Options and Options.ImpelSpeed and tonumber(Options.ImpelSpeed.Value)) or FlyPathfinder.Config.FlySpeed, maxFlightSpeed())
    local startPos = hrp.Position
    local totalDist = (targetPos - startPos).Magnitude

    FlyPathfinder.currentTask = taskName
    print(string.format("[Fly] TASK=%s mode=%s | FlyMode=%s → (%.1f, %.1f, %.1f) | dist=%.0f studs",
        taskName, customMode or "auto", FlyMode.state, targetPos.X, targetPos.Y, targetPos.Z, totalDist))
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
        -- [FlyMode] Giới hạn độ cao SAFE: trần 15 studs trên đất/nước, sàn -1
        vel = clampSafeAltitude(hrp, vel)
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
    -- [FlyMode] noDrain = không Geppo + không BlackLeg → luật game chỉ cho bay cao ≤ 15 studs
    local noDrain = FlyMode.state == "SAFE"
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
        -- [FlyMode] LOOKAHEAD: tính TRƯỚC chunk kế ngay khi sắp hết chunk hiện tại →
        -- không dừng/khựng giữa các chunk (bay liền mạch, không chờ A* chạy xong).
        local nextChunkWps, nextChunkLast, nextChunkIdx = nil, false, 0

        local function computeChunk(idx)
         local hrpN = getHumanoidRootPart()
         if not hrpN then return nil, false end
         local dx = targetPos.X - startPos.X
         local dz = targetPos.Z - startPos.Z
         local hDist = math.max(1, math.sqrt(dx * dx + dz * dz))
         local frac = math.min(1, (idx * FLY3D_CHUNK_DIST) / hDist)
         local sg = Vector3.new(startPos.X + dx * frac, hrpN.Position.Y, startPos.Z + dz * frac)
         local last = frac >= 1
         if last then sg = targetPos end
         local wps = computeFly3DChunk(hrpN.Position, sg, ignoreList, noDrain)
         if #wps == 0 then wps = { sg } end
         return wps, last
        end

        local function applyChunk(wps, last, idx)
         waypoints = wps
         totalWps = #waypoints
         isLastChunk = last
         subGoalIdx = idx
         wpIndex = 1
        end

        local function replanChunk()
         subGoalIdx = subGoalIdx + 1
         local wps, last = computeChunk(subGoalIdx)
         applyChunk(wps, last, subGoalIdx)
         nextChunkWps = nil
        end

        -- Precompute chunk kế TRƯỚC khi hết chunk hiện tại (chạy 1 lần/chunk)
        local function ensureNextChunk()
         if isLastChunk or nextChunkWps then return end
         local wps, last = computeChunk(subGoalIdx + 1)
         nextChunkWps, nextChunkLast, nextChunkIdx = wps, last, subGoalIdx + 1
        end

        -- Chuyển sang chunk kế: dùng bản đã tính sẵn (không block), fallback tính mới
        local function advanceChunk()
         if nextChunkWps then
          applyChunk(nextChunkWps, nextChunkLast, nextChunkIdx)
          nextChunkWps = nil
         else
          replanChunk()
         end
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
                -- Hết chunk → chuyển sang chunk kế ĐÃ tính sẵn (không block, không khựng)
                advanceChunk()
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

            -- [FlyMode] Sắp hết chunk hiện tại → tính sẵn chunk kế (bay liền mạch)
            if not isLastChunk and wpIndex >= totalWps - 1 then
                ensureNextChunk()
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
                    advanceChunk()
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

            -- [FlyMode] Đã vượt xong vật cản → hạ về độ cao an toàn (không lơ lửng trên cao)
            -- SAFE: hạ NGAY về terrainFloor + margin; RISK: hạ từ từ (không vọt)
            if not inEscape then
                local odY = getObstacleDescendY(hrp.Position, targetPos, nil)
                if odY and hrp.Position.Y > odY + 2 then
                    local flatDir = Vector3.new(moveDir.X, 0, moveDir.Z)
                    if flatDir.Magnitude < 0.05 then
                        flatDir = Vector3.new((targetPos - hrp.Position).X, 0, (targetPos - hrp.Position).Z)
                    end
                    local yDiff = hrp.Position.Y - odY
                    local yBias
                    if FlyMode.state == "SAFE" then
                        yBias = -math.min(0.9, yDiff / 60)     -- hạ nhanh, hợp pháp (≤15 studs)
                    else
                        yBias = -math.min(0.5, yDiff / 90)     -- RISK: hạ từ từ, không vọt
                    end
                    moveDir = (flatDir.Unit * 0.6 + Vector3.new(0, yBias, 0)).Unit
                end
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
            -- [FlyMode] Giới hạn độ cao SAFE: trần 15 studs trên đất/nước, sàn -1
            vel = clampSafeAltitude(hrp, vel)
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
            -- [FlyMode] Giới hạn độ cao SAFE: trần 15 studs trên đất/nước, sàn -1
            vel = clampSafeAltitude(hrp, vel)
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
            -- [FlyMode] Giới hạn độ cao SAFE: trần 15 studs trên đất/nước, sàn -1
            vel = clampSafeAltitude(hrp, vel)
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
            -- Tư thế: đánh trong tầm vẫn ĐỨNG THẲNG (dive đã xóa — không lật nằm ngang)
            canSwing = serverDist <= ATTACK_RANGE_SOFT and visualDist <= ATTACK_RANGE_SOFT
            AAB_hoverDive = nil
            -- POSE PIN: giữ tư thế đứng (không ghim nằm ngang)
            PosePin.dive = false
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
