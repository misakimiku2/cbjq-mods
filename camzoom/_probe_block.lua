-- ============================================================
-- v24：安全模式
--   v22 的 6 次 AddCameraDataOffset 把相机推出了地图（用户实测），
--   说明这个偏移会持续生效、ClearCameraDataOffset 并不能真正复位。
--   所以这一版：
--     · 启动/进战斗时完全不碰相机
--     · 只在用户第一次滚轮时做一次「80cm 小位移 + 2 秒连续采样」的探测，
--       目的是搞清楚它是「设一次就停」还是「每帧累加」
--     · 平时不缩放，等探测结论出来再实现
-- ============================================================
local probe = { started = false, done = false }

local function camTransStr(pcm, pawn)
  local ok, t = pcall(function() return pcm:GetPlayerCameraComponentTrans() end)
  if not ok or t == nil then return 'nil' end
  local loc = nil
  local ok1, v = pcall(function() return t.Translation end)
  if ok1 and v then loc = v end
  if loc == nil then
    local ok2, v2 = pcall(function() return t.Location end)
    if ok2 and v2 then loc = v2 end
  end
  if loc == nil then return 'no-loc' end
  local d = -1
  local okP, pl = pcall(function() return pawn:K2_GetActorLocation() end)
  if okP and pl then
    local dx, dy, dz = loc.X - pl.X, loc.Y - pl.Y, loc.Z - pl.Z
    d = math.sqrt(dx * dx + dy * dy + dz * dz)
  end
  return string.format('(%.0f,%.0f,%.0f) d=%.0f', loc.X, loc.Y, loc.Z, d)
end

local verifyMechanism   -- 保留符号，主循环里可能引用

local function probeSample(pcm, pawn, tag)
  lp('PROBE2', tag, camTransStr(pcm, pawn))
end

local function startProbe(pawn, cam, pcm)
  if probe.started or probe.done then return end
  probe.started = true

  local ax = axisBack(pawn, cam)
  if not ax then
    lp('PROBE2 no axis')
    probe.done = true
    return
  end

  local mag = 80.0   -- 只推 80cm，尽量不破坏视野
  local vec = { X = ax.X * mag, Y = ax.Y * mag, Z = ax.Z * mag }

  lp('PROBE2 begin, push 80cm along pawn->cam axis', locStr(vec))
  probeSample(pcm, pawn, 't0-before')

  local ok = pcall(function()
    pcm:AddCameraDataOffset(UE4.FVector(vec.X, vec.Y, vec.Z))
  end)
  lp('PROBE2 addOffset ok=', tostring(ok))

  local steps = { 0.25, 0.5, 0.75, 1.0, 1.5, 2.0 }
  for i = 1, #steps do
    local delay = steps[i] - (steps[i - 1] or 0)
    schedule(function()
      probeSample(pcm, pawn, 't+' .. steps[i] .. 's')
      if i == #steps then
        tryClearOffset(pcm)
        lp('PROBE2 cleared')
        schedule(function()
          probeSample(pcm, pawn, 'after-clear')
          probe.done = true
          lp('PROBE2 done')
        end, 0.3)
      end
    end, delay)
  end
end

-- 开关：探测完成前不缩放
local function canZoom()
  return probe.done
end
