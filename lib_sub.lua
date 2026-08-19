-- [Module: lib_sub.lua - Route & Dungeon Navigation]
local Players = game:GetService("Players")
local Player = Players.LocalPlayer
_G.__SYS = _G.__SYS or {}
local SYS = _G.__SYS

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
