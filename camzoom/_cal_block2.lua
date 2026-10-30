-- ============================================================
-- v23：改用游戏自己的「设置相机世界变换」接口
--   pcm:ChangeCurrentViewTargetTransformWithBlend(
--         startLoc, startRot, targetLoc, targetRot, blendTime, blendFunc)
--   签名来自游戏自带 Script/Misc/UE4.lua 的 SetCameraPosition()，可信。
--   判据：相机组件世界坐标是否按预期移动（角色->相机 轴）。
-- ============================================================
local calIdx = 0
local calResults = {}
local verifyMechanism
local lastOffset = { X = 0, Y = 0, Z = 0 }

local function locStr(l)
  if not l then return 'nil' end
  return string.format('(%.0f,%.0f,%.0f)', l.X, l.Y, l.Z)
end

-- 角色 -> 相机 的单位向量：这才是"拉远/拉近"的物理轴
local function axisBack(pawn, cam)
  local l = camLoc(cam)
  if not l then return nil end
  local okP, pl = pcall(function() return pawn:K2_GetActorLocation() end)
  if not okP or not pl then return nil end
  local dx, dy, dz = l.X - pl.X, l.Y - pl.Y, l.Z - pl.Z
  local len = math.sqrt(dx * dx + dy * dy + dz * dz)
  if len < 1 then return nil end
  return { X = dx / len, Y = dy / len, Z = dz / len, len = len }
end

local function setCamTransform(pcm, cam, offset)
  local loc = camLoc(cam)
  local okR, rot = pcall(function() return cam:K2_GetComponentRotation() end)
  if not loc or not okR or not rot then return false end
  local tx, ty, tz = loc.X + (offset and offset.X or 0),
                     loc.Y + (offset and offset.Y or 0),
                     loc.Z + (offset and offset.Z or 0)
  return pcall(function()
    pcm:ChangeCurrentViewTargetTransformWithBlend(
      UE4.FVector(0, 0, 0), UE4.FRotator(0, 0, 0),
      UE4.FVector(tx, ty, tz), rot, 0, 0)
  end)
end

local function finishCalibration()
  Z.calibrating = false

  local best, bestMoved = nil, 0
  for i = 1, #calResults do
    local r = calResults[i]
    if (r.moved or 0) > bestMoved then best, bestMoved = r, r.moved end
  end

  if best and bestMoved >= 80 then
    Z.mech = { name = best.test.name, kind = best.test.kind, dirBack = (best.dirBack ~= false) }
    if best.dist and best.dist > 80 then CFG.baseDist = best.dist end
    lp('CAL WINNER', Z.mech.name, 'moved=', fmt(bestMoved, 0), 'baseDist=', fmt(CFG.baseDist, 0))
    hud('CamZoom 校准完成 -> ' .. Z.mech.name, 4.0)
    schedule(function() verifyMechanism() end, 0.3)
  else
    Z.mech = nil
    lp('CAL no working camera-set interface, bestMoved=', fmt(bestMoved, 0))
    hud('CamZoom: 仍未找到可用接口 (见日志)', 6.0)
  end
end

verifyMechanism = function()
  if not Z.mech then return end
  local pawn = getPawn()
  local cam = pawn and getCam(pawn)
  local pcm = getPCM()
  if not pawn or not cam or not pcm then return end

  local before = camLoc(cam)
  Z.z = 1.6
  Z.zTarget = 1.6
  local ok = applyZoom(pawn, cam, pcm)
  schedule(function()
    local after = camLoc(cam)
    local moved = 0
    if before and after then moved = vecLen(vecSub(after, before)) or 0 end
    lp('VERIFY 1.6x moved=', fmt(moved, 0), 'ok=', tostring(ok))
    if moved > 60 then
      hud(string.format('CamZoom 可用 (%.0fcm)', moved), 4.0)
    else
      hud('CamZoom: 位移没生效', 5.0)
    end
    Z.z = 1.0
    Z.zTarget = 1.0
    applyZoom(pawn, cam, pcm)
  end, 0.5)
end

local function calStep()
  if Z.dead or not Z.calibrating then return end
  calIdx = calIdx + 1
  local t = TESTS[calIdx]
  if not t then
    schedule(finishCalibration, 0.2)
    return
  end

  local pawn = getPawn()
  local cam = pawn and getCam(pawn)
  local pcm = getPCM()
  if not pawn or not cam or not pcm then
    Z.calibrating = false
    lp('CAL aborted: objects missing')
    return
  end

  local ax = axisBack(pawn, cam)
  if not ax then
    schedule(calStep, 0.05)
    return
  end
  local sign = (t.dir == 'back') and 1 or -1
  local mag = CFG.calMag * sign
  local vec = { X = ax.X * mag, Y = ax.Y * mag, Z = ax.Z * mag }

  local before = camLoc(cam)
  local beforeDist = ax.len

  local ok
  if t.kind == 'change' then
    ok = setCamTransform(pcm, cam, vec)
  else
    ok = pcall(function()
      pcm:AddCameraDataOffsetWithRotate(UE4.FVector(vec.X, vec.Y, vec.Z), UE4.FRotator(0, 0, 0))
    end)
  end
  if not ok then
    lp('CAL skip', t.name, '[call failed]')
    schedule(calStep, 0.05)
    return
  end

  schedule(function()
    local after = camLoc(cam)
    local moved = 0
    if before and after then moved = vecLen(vecSub(after, before)) or 0 end
    lp('CAL test', t.name, 'vec=' .. locStr(vec),
      'locBefore=' .. locStr(before), 'locAfter=' .. locStr(after),
      'moved=' .. fmt(moved, 0) .. 'cm')

    -- 还原
    if t.kind == 'change' then
      pcall(function()
        local l, r = before, nil
        local okR, rr = pcall(function() return cam:K2_GetComponentRotation() end)
        if okR then r = rr end
        if l and r then
          pcm:ChangeCurrentViewTargetTransformWithBlend(
            UE4.FVector(0, 0, 0), UE4.FRotator(0, 0, 0),
            UE4.FVector(l.X, l.Y, l.Z), r, 0, 0)
        end
      end)
    else
      tryClearOffset(pcm)
    end

    calResults[#calResults + 1] = {
      test = t, moved = moved, dirBack = (sign > 0), dist = beforeDist,
    }
    schedule(calStep, 0.25)
  end, CFG.calDwell)
end
