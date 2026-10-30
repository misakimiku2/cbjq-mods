local calIdx = 0
local calResults = {}
local verifyMechanism

-- 位移方向判据：投影到「角色 -> 相机」这条轴上。
-- 这条轴就是"拉远/拉近"的物理轴；相机前向是看向场景的，不能用来判断。
local function projAgainstPawn(pawn, before, after)
  if not before.loc or not after.loc then return 0, 0 end
  local d = vecSub(after.loc, before.loc)
  local moved = vecLen(d) or 0
  if moved < 0.5 then return moved, 0 end
  local okP, pl = pcall(function() return pawn:K2_GetActorLocation() end)
  if not okP or not pl then return moved, 0 end
  local ax, ay, az = before.loc.X - pl.X, before.loc.Y - pl.Y, before.loc.Z - pl.Z
  local al = math.sqrt(ax * ax + ay * ay + az * az)
  if al < 1 then return moved, 0 end
  local proj = (d.X * (ax / al) + d.Y * (ay / al) + d.Z * (az / al)) / moved
  return moved, proj
end

local function locStr(l)
  if not l then return 'nil' end
  return string.format('(%.0f,%.0f,%.0f)', l.X, l.Y, l.Z)
end

local function finishCalibration()
  Z.calibrating = false

  -- 选出"沿拉远轴位移最多"的变体
  local best, bestScore = nil, 0
  for i = 1, #calResults do
    local r = calResults[i]
    local score = (r.moved or 0) * (r.proj or 0)
    if score > bestScore then best, bestScore = r, score end
  end

  if best and bestScore >= 60 then
    Z.mech = {
      name = best.variant.name,
      space = best.variant.space,
      axis = best.variant.axis,
      sign = ((best.proj or 0) > 0) and best.variant.sign or (-best.variant.sign),
    }
    if best.distAfter and best.distAfter > 80 then CFG.baseDist = best.distAfter end
    lp('CAL WINNER', Z.mech.name, 'sign=', Z.mech.sign,
      'moved=', fmt(best.moved, 0), 'proj=', fmt(best.proj, 2),
      'score=', fmt(bestScore, 0), 'baseDist=', fmt(CFG.baseDist, 0))
    hud('CamZoom 校准完成 -> ' .. Z.mech.name, 4.0)
    schedule(function() verifyMechanism() end, 0.3)
  else
    Z.mech = nil
    lp('CAL no working offset variant, bestScore=', fmt(bestScore, 0))
    hud('CamZoom: 位移偏移没通过判据 (见日志)', 6.0)
  end
end

verifyMechanism = function()
  if not Z.mech then return end
  local pawn = getPawn()
  local cam = pawn and getCam(pawn)
  local pcm = getPCM()
  if not pawn or not cam or not pcm then return end

  local before = measure(pawn, cam)
  Z.z = 1.6
  Z.zTarget = 1.6
  applyZoom(pawn, cam, pcm)
  schedule(function()
    local after = measure(pawn, cam)
    local moved, proj = projAgainstPawn(pawn, before, after)
    lp('VERIFY 1.6x moved=', fmt(moved, 0), 'proj=', fmt(proj, 2),
      'distBefore=', fmt(before.dist, 0), 'distAfter=', fmt(after.dist, 0))
    if moved and moved > 60 and (proj or 0) > 0.5 then
      hud(string.format('CamZoom 可用: %s (%.0fcm)', Z.mech.name, moved), 4.0)
    else
      hud('CamZoom: 位移效果异常', 5.0)
    end
    Z.z = 1.0
    Z.zTarget = 1.0
    applyZoom(pawn, cam, pcm)
  end, 0.5)
end

-- 每个变体：清 -> 加 -> 下一帧读 -> 0.5s 后再读 -> 清 -> 再读
-- 用绝对坐标变化判断"是否真的沿拉远轴移动"
local function calStep()
  if Z.dead or not Z.calibrating then return end
  calIdx = calIdx + 1
  local v = VARIANTS[calIdx]
  if not v then
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

  tryClearOffset(pcm)
  local before = measure(pawn, cam)
  local vec = variantVector(v, cam, CFG.calMag)
  if not vec then
    schedule(calStep, 0.05)
    return
  end

  local ok = tryAddOffset(pcm, vec)
  if not ok then
    lp('CAL skip', v.name, '[add offset failed]')
    schedule(calStep, 0.05)
    return
  end

  schedule(function()
    local after = measure(pawn, cam)
    local moved, proj = projAgainstPawn(pawn, before, after)
    local score = (moved or 0) * (proj or 0)
    tryClearOffset(pcm)

    lp('CAL move', v.name,
      'vec=' .. locStr({ X = vec.X, Y = vec.Y, Z = vec.Z }),
      'locBefore=' .. locStr(before.loc), 'locAfter=' .. locStr(after.loc),
      'moved=' .. fmt(moved, 0) .. 'cm', 'proj=' .. fmt(proj, 2),
      'score=' .. fmt(score, 0),
      'dist=' .. fmt(before.dist, 0) .. '->' .. fmt(after.dist, 0))

    calResults[#calResults + 1] = {
      variant = v, proj = proj, moved = moved, distBefore = before.dist, distAfter = after.dist,
    }
    schedule(calStep, 0.15)
  end, CFG.calDwell)
end
