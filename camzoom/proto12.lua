-- ========================================================
-- @File    : CamZoomMod.lua (v20)
-- @Brief   : 第三人称滚轮缩放镜头（GTA 风格）
--            核心思路：不赌某个固定 API，而是进战斗后自动校准
--            —— 遍历候选参数，用「相机距离 / FOV 是否真的改变」做客观判据，
--            选出真正生效的那一个，再绑定滚轮驱动。
-- @Note    : 全部 API 调用都走 pcall，任何失败都不会影响游戏本体。
-- ========================================================

CamZoomMod = CamZoomMod or {}
-- 注意：本文件会被注入到 umg_main.lua 的 `return tbClass` 之前，
-- 因此绝不能使用 return（会让 umg_main 提前返回，主界面失效）。用块包裹做幂等。
-- 幂等标记用 _ready：只有「定时器排上了 或 至少注册上一个事件」才锁定，
-- 否则允许另一处注入（ResourceAmend / umg_main）在更晚、环境更完整的时机重试。
if not CamZoomMod._ready then

local LOG = '[CamZoom] '
local function lp(...)
  print(LOG, ...)
end

local function fmt(v, nd)
  if v == nil then return 'nil' end
  if type(v) ~= 'number' then return tostring(v) end
  return string.format('%.' .. (nd or 1) .. 'f', v)
end

-- ---------------- 配置 ----------------
local CFG = {
  zMin = 0.45,
  zMax = 2.60,
  notchStep = 0.09,
  smooth = 9.0,
  pollInterval = 0.02,
  calDwell = 0.42,
  invertWheel = false,
  ipcPath = 'D:\\test\\cbjq-re\\runtime\\wheel.txt',
  hudDuration = 2.5,
}

-- ---------------- 状态 ----------------
local Z = {
  z = 1.0,
  zTarget = 1.0,
  mech = nil,
  calibrated = false,
  calibrating = false,
  candidates = {},
  calIdx = 0,
  errCount = 0,
  wheelSrc = 'none',
  hasDirection = false,
  wheelAxis = nil,
  candidateAxes = {},
  sniffUntil = 0,
  notch = 0,
  notchTotal = 0,
  frame = 0,
  dead = false,
  ioChecked = false,
  hasIO = false,
  ipcSeq = -1,
}

-- ============================================================
-- 取对象
-- ============================================================
local function getIns()
  local fn = GetGameIns
  if type(fn) ~= 'function' then return nil end
  local ok, ins = pcall(fn)
  if ok then return ins end
  return nil
end

local function getPC()
  local ins = getIns()
  if not ins then return nil end
  local ok, pc = pcall(UE4.UGameplayStatics.GetPlayerController, ins, 0)
  if ok then return pc end
  return nil
end

local function getPawn()
  local ins = getIns()
  if not ins then return nil end
  local ok, p = pcall(UE4.UGameplayStatics.GetPlayerPawn, ins, 0)
  if ok then return p end
  return nil
end

local function getPCM()
  local ins = getIns()
  if not ins then return nil end
  local ok, pcm = pcall(UE4.UGameplayStatics.GetPlayerCameraManager, ins, 0)
  if ok then return pcm end
  return nil
end

local function pathOf(obj)
  if obj == nil then return 'nil' end
  local ok, p = pcall(UE4.UKismetSystemLibrary.GetPathName, obj)
  if ok and p then return tostring(p) end
  return ''
end

local function isGameplay(pc)
  local s = pathOf(pc)
  return (s:find('GameController', 1, true) ~= nil)
    or (s:find('FightController', 1, true) ~= nil)
end

local function getCam(pawn)
  local ok, c = pcall(function() return pawn.Camera end)
  if ok and c then return c end
  return nil
end

-- ============================================================
-- 测量
-- ============================================================
local function distToPawn(pawn, loc)
  if not loc then return nil end
  local okP, pl = pcall(function() return pawn:K2_GetActorLocation() end)
  if not okP or not pl then return nil end
  local dx, dy, dz = loc.X - pl.X, loc.Y - pl.Y, loc.Z - pl.Z
  return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function camDist(pawn, cam)
  local ok1, cl = pcall(function() return cam:K2_GetComponentLocation() end)
  if not ok1 or not cl then return nil end
  return distToPawn(pawn, cl)
end

-- 从相机管理器要一份相机变换（若可用）
local function pcmDist(pawn, pcm)
  if not pcm then return nil end
  local ok, t = pcall(function() return pcm:GetPlayerCameraComponentTrans() end)
  if not ok or t == nil then return nil end
  local loc = nil
  local ok1, v = pcall(function() return t.Translation end)
  if ok1 and v then loc = v end
  if loc == nil then
    local ok2, v2 = pcall(function() return t.Location end)
    if ok2 and v2 then loc = v2 end
  end
  if loc == nil then
    local ok3, tb = pcall(function() return t:ToTable() end)
    if ok3 and type(tb) == 'table' and tb[1] and tb[1].Translation then loc = tb[1].Translation end
  end
  if loc == nil then return nil end
  return distToPawn(pawn, loc)
end

local function measure(pawn, cam, pcm)
  local m = { fov = nil, dist = nil, pdist = nil }
  if cam then
    local okF, f = pcall(function() return cam.FieldOfView end)
    if okF and type(f) == 'number' then m.fov = f end
    m.dist = camDist(pawn, cam)
  end
  m.pdist = pcmDist(pawn, pcm)
  return m
end

-- ============================================================
-- 属性读写
-- ============================================================
local function readProp(obj, name)
  local ok, v = pcall(function() return obj[name] end)
  if ok and type(v) == 'number' then return v end
  return nil
end

local function writeProp(obj, name, v)
  local ok = pcall(function() obj[name] = v end)
  if not ok then return false, nil end
  local back = readProp(obj, name)
  if back == nil then return false, nil end
  local tol = 0.02 * math.max(1.0, math.abs(v))
  return (math.abs(back - v) <= tol), back
end

local function callMethod(obj, name, v)
  if obj == nil then return false end
  local ok = pcall(function()
    local f = obj[name]
    if f == nil then error('no method') end
    f(obj, v)
  end)
  return ok
end

-- ============================================================
-- 候选参数
-- ============================================================
-- kind: len 臂长(越小越近) / fov FOV(越小越近) / lenoff 臂长偏移 / fovoff FOV偏移
local PROP_CANDIDATES = {
  { owner = 'pcm', name = 'CameraArmLength',     kind = 'len' },
  { owner = 'cam', name = 'CameraArmLength',     kind = 'len' },
  { owner = 'pcm', name = 'ArmLength',           kind = 'len' },
  { owner = 'cam', name = 'ArmLength',           kind = 'len' },
  { owner = 'pcm', name = 'CameraFOV',           kind = 'fov' },
  { owner = 'cam', name = 'CameraFOV',           kind = 'fov' },
  { owner = 'pcm', name = 'TargetFOV',           kind = 'fov' },
  { owner = 'cam', name = 'TargetFOV',           kind = 'fov' },
  { owner = 'pcm', name = 'TempArmLengthOffset', kind = 'lenoff' },
  { owner = 'pcm', name = 'TempCameraFOVOffset', kind = 'fovoff' },
  { owner = 'cam', name = 'CameraZoomFactor',    kind = 'len' },
  { owner = 'pcm', name = 'CameraZoomFactor',    kind = 'len' },
}

local METHOD_CANDIDATES = {
  { owner = 'cam', name = 'SetCameraArmLength', kind = 'len' },
  { owner = 'cam', name = 'SetCameraFOV',       kind = 'fov' },
  { owner = 'cam', name = 'SetCameraFov',       kind = 'fov' },
  -- 注意：刻意不放 AddZoomFactor —— 它是累加语义，若生效会无界累积且无法还原
  { owner = 'cam', name = 'SetFOVOverride',     kind = 'fov' },
  { owner = 'pcm', name = 'SetFOVOverride',     kind = 'fov' },
}

-- 相机状态结构体内部字段（曲线驱动管线的真实输入，读到值才有意义）
local STRUCT_CANDIDATES = {
  { owner = 'pcm', structName = 'CurrentCameraInfo', name = 'CameraArmLength', kind = 'len' },
  { owner = 'pcm', structName = 'CurrentCameraInfo', name = 'CameraFOV',       kind = 'fov' },
  { owner = 'pcm', structName = 'CurrentCameraInfo', name = 'TargetFOV',       kind = 'fov' },
  { owner = 'pcm', structName = 'PlayerCameraInfo',  name = 'CameraArmLength', kind = 'len' },
  { owner = 'pcm', structName = 'PlayerCameraInfo',  name = 'CameraFOV',       kind = 'fov' },
  { owner = 'cam', structName = 'CameraData',        name = 'CameraArmLength', kind = 'len' },
  { owner = 'cam', structName = 'CameraData',        name = 'CameraFOV',       kind = 'fov' },
  -- 只测不用：SetTempCameraInfo 通道（游戏技能镜头用的就是它）。
  -- 这轮先验证它通不通，通了下轮再实现可持续驱动（每帧调可能触发重复混合）。
  { owner = 'pcm', structName = 'TempNormalCameraInfo', name = 'TempArmLengthOffset', kind = 'lenoff',
    alsoCall = 'SetTempCameraInfo', testOnly = true },
  { owner = 'pcm', structName = 'TempNormalCameraInfo', name = 'TempCameraFOVOffset', kind = 'fovoff',
    alsoCall = 'SetTempCameraInfo', testOnly = true },
  { owner = 'pcm', structName = 'PlayerCameraInfo', name = 'CameraArmLength', kind = 'len',
    alsoCall = 'SetTempCameraInfo', testOnly = true },
  { owner = 'pcm', structName = 'PlayerCameraInfo', name = 'CameraFOV', kind = 'fov',
    alsoCall = 'SetTempCameraInfo', testOnly = true },
}

local function ownerObj(key, cam, pcm)
  if key == 'pcm' then return pcm end
  if key == 'cam' then return cam end
  return nil
end

local function testValue(kind, base)
  if kind == 'len' then
    if base and base > 30 then return base * 0.55 end
    return 120.0
  elseif kind == 'fov' then
    if base and base > 5 then return math.max(25.0, base * 0.62) end
    return 45.0
  elseif kind == 'lenoff' then
    return -170.0
  elseif kind == 'fovoff' then
    return -16.0
  end
  return nil
end

local function computeValue(kind, base, z)
  if kind == 'len' or kind == 'fov' then
    return base / z
  elseif kind == 'fovoff' then
    return base - (z - 1.0) * 16.0
  elseif kind == 'lenoff' then
    return base - (z - 1.0) * 260.0
  end
  return base
end

-- ============================================================
-- HUD
-- ============================================================
local function hud(text, dur)
  pcall(function()
    UE4.UKismetSystemLibrary.PrintString(getIns() or nil, text, true, false,
      UE4.FLinearColor(0.35, 0.95, 1.0, 1.0), dur or CFG.hudDuration)
  end)
end

local function hudState()
  if Z.dead then
    hud('CamZoom: 已停用', 3.0)
    return
  end
  if not Z.mech then
    hud('CamZoom v20 | 未找到可用镜头参数 | 见 Game.log', 4.5)
    return
  end
  hud(string.format('CamZoom  x%.2f   %s   滚轮:%s', Z.z, Z.mech.name, Z.wheelSrc), 2.2)
end

-- ============================================================
-- 应用缩放
-- ============================================================
local function applyZoom(pawn, cam, pcm)
  local m = Z.mech
  if not m then return end

  if (m.kind == 'fov' or m.kind == 'fovoff') and cam then
    local live = readProp(cam, 'FieldOfView')
    if live and live < 60.0 then return end
  end

  local z = Z.z

  -- 回到 1.0x：把控制权彻底交还游戏（只还原一次），避免长期覆盖原版镜头行为
  if math.abs(z - 1.0) < 0.004 then
    if Z.applied ~= nil then
      if m.special == 'addoffset' then
        pcall(function() pcm:ClearCameraDataOffset() end)
      elseif m.structName then
        pcall(function()
          local st = m.obj[m.structName]
          if st then
            st[m.name] = m.base
            m.obj[m.structName] = st
          end
        end)
      elseif m.method then
        if m.base and m.base > 0 then callMethod(m.obj, m.name, m.base) end
      else
        writeProp(m.obj, m.name, m.base)
      end
      Z.applied = nil
      lp('APPLY released to game')
    end
    return
  end

  Z.applied = z

  if m.structName then
    pcall(function()
      local st = m.obj[m.structName]
      if st == nil then return end
      st[m.name] = computeValue(m.kind, m.base, z)
      m.obj[m.structName] = st
    end)
    return
  end

  if m.special == 'addoffset' then
    pcall(function()
      local rot = cam:K2_GetComponentRotation()
      local f = UE4.UKismetMathLibrary.GetForwardVector(rot)
      local d = (z - 1.0) * 300.0
      pcm:ClearCameraDataOffset()
      pcm:AddCameraDataOffset(UE4.FVector(-f.X * d, -f.Y * d, -f.Z * d))
    end)
    return
  end

  local v = computeValue(m.kind, m.base, Z.z)
  if v == nil then return end

  local ok
  if m.method then
    ok = callMethod(m.obj, m.name, v)
  else
    ok = writeProp(m.obj, m.name, v)
  end
  if not ok then
    Z.errCount = Z.errCount + 1
    if Z.errCount >= 8 then
      lp('APPLY failed, disable mech', m.name)
      Z.mech = nil
    end
  end
end

-- ============================================================
-- 滚轮：轴探测
-- ============================================================
local AXIS_NAMES = nil

local function collectAxisNames()
  if AXIS_NAMES then return AXIS_NAMES end
  AXIS_NAMES = {}
  local okS, st = pcall(function() return UE4.UInputSettings.GetInputSettings() end)
  if not okS or not st then
    lp('AXES InputSettings unavailable')
    return AXIS_NAMES
  end
  local okA, arr = pcall(function() return st.AxisMappings end)
  if not okA or not arr then
    lp('AXES AxisMappings unavailable')
    return AXIS_NAMES
  end
  local n = 0
  pcall(function() n = arr:Length() end)
  local seen = {}
  for i = 1, math.min(n, 200) do
    local okm, m = pcall(function() return arr:Get(i) end)
    if okm and m then
      local okn, nm = pcall(function() return m.AxisName end)
      if okn and nm then
        local oks, s = pcall(function() return UE4.UKismetStringLibrary.Conv_NameToString(nm) end)
        if oks and s then
          s = tostring(s)
          if s ~= '' and not seen[s] then
            seen[s] = true
            AXIS_NAMES[#AXIS_NAMES + 1] = s
          end
        end
      end
    end
  end
  lp('AXES mapped count=', #AXIS_NAMES, table.concat(AXIS_NAMES, ','))
  return AXIS_NAMES
end

local function pollWheelAxis(pc)
  if Z.wheelAxis then
    local ok, v = pcall(function() return pc:GetInputAxisValue(Z.wheelAxis) end)
    if ok and type(v) == 'number' and math.abs(v) > 0.005 then return v end
    return 0
  end

  -- 名字里带 wheel/zoom/scroll 的轴：每帧都查（数量很少，开销可忽略）
  if #Z.candidateAxes > 0 then
    local best, bv = nil, 0
    for i = 1, #Z.candidateAxes do
      local ok, v = pcall(function() return pc:GetInputAxisValue(Z.candidateAxes[i]) end)
      if ok and type(v) == 'number' and math.abs(v) > 0.3 and math.abs(v) > math.abs(bv) then
        best, bv = Z.candidateAxes[i], v
      end
    end
    if best then
      Z.wheelAxis = best
      Z.hasDirection = true
      Z.wheelSrc = 'axis'
      lp('WHEEL axis identified(cand):', best, fmt(bv, 3))
      hud('CamZoom: 滚轮轴 = ' .. best, 3.0)
      return bv
    end
    return 0
  end

  if (Z.sniffUntil or 0) < Z.frame then return 0 end

  local names = collectAxisNames()
  local best, bv = nil, 0
  for i = 1, #names do
    local ok, v = pcall(function() return pc:GetInputAxisValue(names[i]) end)
    if ok and type(v) == 'number' and math.abs(v) > 0.3 and math.abs(v) > math.abs(bv) then
      best, bv = names[i], v
    end
  end
  if best then
    Z.wheelAxis = best
    Z.hasDirection = true
    Z.wheelSrc = 'axis'
    lp('WHEEL axis identified:', best, fmt(bv, 3))
    hud('CamZoom: 滚轮轴 = ' .. best, 3.0)
    return bv
  end
  return 0
end

-- ============================================================
-- 滚轮：文件 IPC（外部嗅探器，兜底）
-- ============================================================
local function pollIPC()
  if not Z.ioChecked then
    Z.ioChecked = true
    Z.hasIO = (type(io) == 'table' and type(io.open) == 'function')
    lp('IPC io available=', tostring(Z.hasIO))
    if not Z.hasIO then return 0 end
  end
  if not Z.hasIO then return 0 end

  local ok, f = pcall(io.open, CFG.ipcPath, 'r')
  if not ok or not f then return 0 end
  local content = nil
  pcall(function() content = f:read('a') end)
  pcall(function() f:close() end)
  if not content or content == '' then return 0 end

  local seqs, dirs = content:match('(%d+)%s+(-?%d+)')
  if not seqs then return 0 end
  local seq, dir = tonumber(seqs), tonumber(dirs)
  if not seq or not dir then return 0 end
  if Z.ipcSeq < 0 then
    Z.ipcSeq = seq
    return 0
  end
  if seq == Z.ipcSeq then return 0 end
  local steps = seq - Z.ipcSeq
  Z.ipcSeq = seq
  if steps < 1 or steps > 20 then steps = 1 end
  if dir == 0 then return 0 end
  Z.hasDirection = true
  if Z.wheelSrc ~= 'axis' then Z.wheelSrc = 'ipc' end
  return dir * steps
end

-- ============================================================
-- 滚轮：按键名反查（FKey -> 显示名）
-- ============================================================
local IN = {
  inited = false,
  wheelKeys = {},   -- {key=FKey, dir=+1/-1, name=str}
  wheelByEvent = 0, -- 由 OnKeyboardKeyPressed 推断出的方向
}

local function fkeyName(k)
  if k == nil then return nil end
  local ok, t = pcall(function() return UE4.UKismetInputLibrary.Key_GetDisplayName(k) end)
  if ok and t ~= nil then
    local ok2, s = pcall(function() return UE4.UKismetTextLibrary.Conv_TextToString(t) end)
    if ok2 and type(s) == 'string' and #s > 0 then return s end
    local s2 = tostring(t)
    if type(s2) == 'string' and #s2 > 0 and #s2 < 64 and not s2:find('FText', 1, true) then
      return s2
    end
  end
  return nil
end

local function classifyWheelName(name)
  local n = string.lower(tostring(name))
  local isWheel = n:find('wheel', 1, true) or n:find('scroll', 1, true) or n:find('滚轮', 1, true)
  if not isWheel then return 0 end
  if n:find('up', 1, true) or n:find('上', 1, true) then return 1 end
  if n:find('down', 1, true) or n:find('下', 1, true) then return -1 end
  return 0
end

local function initInput()
  if IN.inited then return end
  IN.inited = true

  local okS, st = pcall(function() return UE4.UInputSettings.GetInputSettings() end)
  if not okS or not st then
    lp('INPUT UInputSettings unavailable')
    return
  end

  local function scan(arr, isAxis)
    if not arr then return end
    local n = 0
    pcall(function() n = arr:Length() end)
    for i = 1, math.min(n, 300) do
      local okm, m = pcall(function() return arr:Get(i) end)
      if okm and m then
        -- 分别取名字：对 struct 访问不存在的字段在 UnLua 里可能直接报错
        local nm = nil
        local ok1, v1 = pcall(function() return m.AxisName end)
        if ok1 then nm = v1 end
        if nm == nil then
          local ok2, v2 = pcall(function() return m.ActionName end)
          if ok2 then nm = v2 end
        end
        local nameStr = '?'
        if nm ~= nil then
          local oks, s = pcall(function() return UE4.UKismetStringLibrary.Conv_NameToString(nm) end)
          if oks and s then nameStr = tostring(s) end
        end
        local okK, k = pcall(function() return m.Key end)
        local keyStr = nil
        if okK and k then keyStr = fkeyName(k) end
        local okSc, sc = pcall(function() return m.Scale end)
        -- 动作映射有上百条，全量打印没意义（已从 Input.ini 拿到）；只记轴和滚轮相关
        local keyLower = keyStr and string.lower(keyStr) or ''
        local interesting = isAxis or keyLower:find('wheel', 1, true) or keyLower:find('scroll', 1, true)
        if interesting then
          lp('MAP', isAxis and 'axis' or 'action', nameStr, 'key=' .. tostring(keyStr),
            'scale=' .. tostring(okSc and sc or ''))
        end

        if okK and k and keyStr then
          local d = classifyWheelName(keyStr)
          if d ~= 0 or string.lower(keyStr):find('wheel', 1, true) then
            IN.wheelKeys[#IN.wheelKeys + 1] = { key = k, dir = d, name = keyStr, axis = nameStr }
            lp('MAP wheel key found:', keyStr, 'dir=', d)
          end
        end
        if isAxis and nameStr ~= '?' then
          local ln = string.lower(nameStr)
          if ln:find('wheel', 1, true) or ln:find('zoom', 1, true) or ln:find('scroll', 1, true) then
            Z.candidateAxes[#Z.candidateAxes + 1] = nameStr
          end
        end
      end
    end
  end

  local okA, axes = pcall(function() return st.AxisMappings end)
  if okA then scan(axes, true) end
  local okB, acts = pcall(function() return st.ActionMappings end)
  if okB then scan(acts, false) end

  lp('INPUT wheelKeys=', #IN.wheelKeys)
end

local function pollWheelKeys(pc)
  if #IN.wheelKeys == 0 then return 0 end
  local sum = 0
  for i = 1, #IN.wheelKeys do
    local w = IN.wheelKeys[i]
    if w.dir ~= 0 then
      local ok, pressed = pcall(function() return pc:WasInputKeyJustPressed(w.key) end)
      if ok and pressed then sum = sum + w.dir end
    end
  end
  return sum
end

-- ============================================================
-- 滚轮：无方向事件
-- ============================================================
local function onKeyboardLikeEvent(...)
  local num = tonumber(select(1, ...))
  if num == nil then return end
  Z.notchTotal = Z.notchTotal + 1
  if Z.notchTotal <= 8 then
    lp('KEYEVT', tostring(select(1, ...)), tostring(select(2, ...)), 'argc=', select('#', ...))
  end
  if num == 13 then
    Z.notch = (Z.notch or 0) + 1
    Z.sniffUntil = Z.frame + 8
  end
end

-- ============================================================
-- 校准
-- ============================================================
local function schedule(fn, sec)
  pcall(function() UE4.Timer.Add(sec or 0.01, fn) end)
end

local function finishCalibration()
  Z.calibrating = false

  local best = nil
  local hits = Z.hits or {}
  for i = 1, #hits do
    local h = hits[i]
    if best == nil or h.prio < best.prio
      or (h.prio == best.prio and math.abs(h.ddist or 0) > math.abs(best.ddist or 0)) then
      best = h
    end
  end

  if best then
    -- 方法型候选没有「基准值」可读，用当前实测值兜底，避免算出 0 臂长这种退化值
    if best.base == nil or best.base <= 0 then
      local pawn = getPawn()
      local cam = pawn and getCam(pawn)
      if best.kind == 'len' or best.kind == 'lenoff' then
        best.base = (pawn and cam and camDist(pawn, cam)) or 300.0
      else
        best.base = (cam and readProp(cam, 'FieldOfView')) or 75.0
      end
    end
    Z.mech = best
    lp('CAL WINNER', best.name, best.kind, 'prio=', best.prio,
      'base=', fmt(best.base), 'method=', tostring(best.method), 'special=', tostring(best.special),
      'hits=', #hits)
    hud('CamZoom 校准完成 -> ' .. best.name, 4.0)
  else
    Z.mech = nil
    lp('CAL no working knob found, hits=0')
    hud('CamZoom: 未找到可用镜头参数 (见 Game.log)', 6.0)
  end
end

local calStep

local function relDelta(a, b)
  if not a or not b then return nil end
  return (b - a) / math.max(1.0, a)
end

-- 优先级：臂长类 > 臂长偏移 > FOV > FOV 偏移（推拉镜头比变 FOV 更接近 GTA 手感）
local function priorityOf(kind)
  if kind == 'len' then return 1 end
  if kind == 'lenoff' then return 2 end
  if kind == 'fov' then return 3 end
  if kind == 'fovoff' then return 4 end
  return 9
end

local function evalCandidate(c, obj, before, testApplied)
  local pawn = getPawn()
  local cam = pawn and getCam(pawn)
  local pcm = getPCM()
  if not pawn or not cam then
    Z.calibrating = false
    return
  end
  local after = measure(pawn, cam, pcm)
  local dfov = nil
  if before.fov and after.fov then dfov = after.fov - before.fov end
  local ddist = relDelta(before.dist, after.dist)
  local dpdist = relDelta(before.pdist, after.pdist)

  local still = nil
  if c.structName then
    pcall(function()
      local st = obj[c.structName]
      if st then still = st[c.name] end
    end)
  elseif not c.isMethod then
    still = readProp(obj, c.name)
  end

  lp('CAL result', c.owner .. ':' .. c.name, 'kind=' .. tostring(c.kind),
    'base=' .. fmt(c.base), 'test=' .. fmt(testApplied),
    'kept=' .. tostring(still and testApplied and (math.abs(still - testApplied) < 0.5)),
    'dFOV=' .. fmt(dfov, 2),
    'dDist=' .. fmt(ddist and (ddist * 100) or nil, 1) .. '%',
    'dPDist=' .. fmt(dpdist and (dpdist * 100) or nil, 1) .. '%')

  -- 还原
  if c.special == 'addoffset' then
    pcall(function() pcm:ClearCameraDataOffset() end)
  elseif c.alsoCall then
    pcall(function() pcm:StopTempCameraInfo() end)
    if c.structName and c.base then
      pcall(function()
        local st = obj[c.structName]
        if st then
          st[c.name] = c.base
          obj[c.structName] = st
        end
      end)
    end
  elseif c.structName and c.base then
    pcall(function()
      local st = obj[c.structName]
      if st then
        st[c.name] = c.base
        obj[c.structName] = st
      end
    end)
  elseif not c.isMethod and c.base then
    writeProp(obj, c.name, c.base)
  end

  -- 距离类变化可信度高（角色静止时相机距离本来不会乱变）；
  -- FOV 类变化可能只是玩家刚好开镜/收镜，所以必须「我们的值没被游戏改回去」才算数。
  local distEffect = (ddist and math.abs(ddist) > 0.12)
    or (dpdist and math.abs(dpdist) > 0.12)
  local fovEffect = (dfov ~= nil) and (math.abs(dfov) > 2.0)
  local kept = (still ~= nil) and (testApplied ~= nil)
    and (math.abs(still - testApplied) < 0.5)

  local hit
  if c.isMethod or c.special then
    hit = distEffect or (fovEffect and math.abs(dfov) > 8.0)
  else
    hit = distEffect or (fovEffect and kept)
  end

  if hit then
    if c.testOnly then
      lp('CAL HIT(testOnly, 不参与选择)', c.structName .. '.' .. c.name)
      schedule(calStep, 0.06)
      return
    end
    Z.hits = Z.hits or {}
    Z.hits[#Z.hits + 1] = {
      obj = obj, name = c.name, kind = c.kind,
      base = c.base or 0, method = c.isMethod or false,
      special = c.special, structName = c.structName,
      prio = priorityOf(c.kind),
      dfov = dfov, ddist = ddist or dpdist,
    }
    lp('CAL HIT', c.owner .. ':' .. c.name, 'prio=', priorityOf(c.kind))
  end
  schedule(calStep, 0.06)
end

calStep = function()
  if Z.dead or not Z.calibrating then return end
  Z.calIdx = Z.calIdx + 1
  local c = Z.candidates[Z.calIdx]
  if not c then
    schedule(finishCalibration, 0.1)
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

  local obj = ownerObj(c.owner, cam, pcm)
  if obj == nil then
    schedule(calStep, 0.02)
    return
  end

  local before = measure(pawn, cam, pcm)

  -- 结构体内字段
  if c.structName then
    local st = nil
    local okS = pcall(function() st = obj[c.structName] end)
    if not okS or st == nil then
      schedule(calStep, 0.02)
      return
    end
    local base = nil
    pcall(function() base = st[c.name] end)
    if type(base) ~= 'number' then
      schedule(calStep, 0.02)
      return
    end
    c.base = base
    local tv = testValue(c.kind, base)
    if tv == nil or math.abs(tv - base) < 0.5 then tv = base * 0.6 end
    local okW = pcall(function()
      st[c.name] = tv
      obj[c.structName] = st
    end)
    if not okW then
      lp('CAL skip', c.structName .. '.' .. c.name, '[struct write failed] base=', fmt(base))
      schedule(calStep, 0.02)
      return
    end
    lp('CAL test', c.structName .. '.' .. c.name, 'base=', fmt(base), 'v=', fmt(tv))
    if c.alsoCall then
      local okCall = callMethod(obj, c.alsoCall, st)
      lp('CAL test', c.alsoCall, 'callable=', tostring(okCall))
      if not okCall then
        pcall(function()
          st[c.name] = base
          obj[c.structName] = st
        end)
        schedule(calStep, 0.02)
        return
      end
    end
    schedule(function() evalCandidate(c, obj, before, tv) end, CFG.calDwell)
    return
  end

  -- 特殊候选：AddCameraDataOffset（偏移位移）
  if c.special == 'addoffset' then
    local ok = pcall(function() pcm:AddCameraDataOffset(UE4.FVector(0, 0, -220)) end)
    if not ok then
      lp('CAL skip addoffset [call failed]')
      schedule(calStep, 0.02)
      return
    end
    lp('CAL test pcm:AddCameraDataOffset v= -220Z')
    schedule(function() evalCandidate(c, pcm, before, -220) end, CFG.calDwell)
    return
  end

  if c.isMethod then
    local tv = testValue(c.kind, nil)
    if not callMethod(obj, c.name, tv) then
      lp('CAL skip', c.owner .. ':' .. c.name, '[method not callable]')
      schedule(calStep, 0.02)
      return
    end
    lp('CAL test', c.owner .. ':' .. c.name, 'method v=', fmt(tv))
    schedule(function() evalCandidate(c, obj, before, tv) end, CFG.calDwell)
    return
  end

  c.base = readProp(obj, c.name)
  if c.base == nil then
    schedule(calStep, 0.02)
    return
  end

  local tv = testValue(c.kind, c.base)
  if tv == nil then
    schedule(calStep, 0.02)
    return
  end
  if math.abs(tv - c.base) < 0.5 then tv = c.base * 0.6 end

  local writable = writeProp(obj, c.name, tv)
  if not writable then
    lp('CAL skip', c.owner .. ':' .. c.name, '[not writable] base=', fmt(c.base))
    schedule(calStep, 0.02)
    return
  end

  lp('CAL test', c.owner .. ':' .. c.name, 'prop base=', fmt(c.base), 'v=', fmt(tv))
  schedule(function() evalCandidate(c, obj, before, tv) end, CFG.calDwell)
end

local function startCalibration(pawn, cam, pcm)
  if Z.calibrated or Z.calibrating then return end
  Z.calibrated = true
  Z.calibrating = true

  local cands = {}
  for i = 1, #PROP_CANDIDATES do cands[#cands + 1] = PROP_CANDIDATES[i] end
  for i = 1, #METHOD_CANDIDATES do
    local m = METHOD_CANDIDATES[i]
    cands[#cands + 1] = { owner = m.owner, name = m.name, kind = m.kind, isMethod = true }
  end
  cands[#cands + 1] = { owner = 'pcm', name = 'AddCameraDataOffset', kind = 'lenoff', special = 'addoffset' }
  for i = 1, #STRUCT_CANDIDATES do
    local s = STRUCT_CANDIDATES[i]
    cands[#cands + 1] = { owner = s.owner, name = s.name, kind = s.kind, structName = s.structName }
  end
  Z.candidates = cands
  Z.calIdx = 0
  Z.hits = {}

  -- 诊断：pawn 上有哪些相机相关对象，pcm 的状态结构体里有什么字段
  pcall(function()
    local PROBE = { 'Camera', 'CameraComponent', 'CameraBlueprint', 'CameraComp', 'CameraBoom', 'SpringArm', 'CameraManager', 'CameraData' }
    local found = {}
    for i = 1, #PROBE do
      local ok, v = pcall(function() return pawn[PROBE[i]] end)
      if ok and v then found[#found + 1] = PROBE[i] .. '=' .. pathOf(v) end
    end
    lp('PROBE pawn cam objs:', table.concat(found, ' |'))

    local okCI, ci = pcall(function() return pcm.CurrentCameraInfo end)
    lp('PROBE pcm.CurrentCameraInfo ok=', tostring(okCI), 'nil=', tostring(ci == nil))
    if okCI and ci then
      local fields = { 'CameraArmLength', 'CameraFOV', 'TargetFOV', 'TempArmLengthOffset', 'CameraSocketOffset' }
      local parts = {}
      for i = 1, #fields do
        local ok2, v = pcall(function() return ci[fields[i]] end)
        parts[#parts + 1] = fields[i] .. '=' .. tostring(ok2 and v or 'ERR')
      end
      lp('PROBE CurrentCameraInfo fields:', table.concat(parts, ' '))
    end
  end)

  lp('CAL begin candidates=', #cands,
    'pawn=', pathOf(pawn), 'cam=', pathOf(cam), 'pcm=', pathOf(pcm),
    'pcmCast=', tostring((function()
      local ok, r = pcall(function() return pcm:Cast(UE4.AThirdPersonPlayerCameraManager) end)
      return ok and r ~= nil
    end)()))

  local b = measure(pawn, cam, pcm)
  lp('CAL baseline fov=', fmt(b.fov), 'dist=', fmt(b.dist))
  hud('CamZoom 校准中…(相机会短暂抖动)', 4.0)
  schedule(calStep, 0.5)
end

-- ============================================================
-- 主循环
-- ============================================================
local function onWheel(steps, allowWrap)
  if steps == 0 then return end
  if CFG.invertWheel then steps = -steps end

  Z.zTarget = Z.zTarget + steps * CFG.notchStep
  if Z.zTarget > CFG.zMax then
    if allowWrap then Z.zTarget = CFG.zMin else Z.zTarget = CFG.zMax end
  elseif Z.zTarget < CFG.zMin then
    if allowWrap then Z.zTarget = CFG.zMax else Z.zTarget = CFG.zMin end
  end
  hudState()
end

local function step()
  if Z.dead then return end

  local okAll, err = pcall(function()
    Z.frame = Z.frame + 1

    local pc = getPC()
    if not pc then return end
    local pawn = getPawn()
    if not pawn then return end
    local cam = getCam(pawn)
    if not cam then return end
    if not isGameplay(pc) then return end

    local pcm = getPCM()
    if not Z.calibrated and pcm then
      -- 进入战斗后先等 2.5s，避开进场镜头混合，保证基线稳定
      if Z.firstCombatFrame == nil then Z.firstCombatFrame = Z.frame end
      if Z.frame - Z.firstCombatFrame > 125 then
        startCalibration(pawn, cam, pcm)
      end
    end

    -- 滚轮输入
    local delta = 0
    local allowWrap = false
    initInput()
    local ipc = pollIPC()
    if ipc ~= 0 then
      delta = ipc
    end

    if delta == 0 then
      local av = pollWheelAxis(pc)
      if av ~= 0 then
        -- 轴值可能连续多帧非零：用 armed 机制保证「一格只走一步」
        if math.abs(av) > 0.3 and Z.axisArmed ~= false then
          Z.axisArmed = false
          delta = (av > 0) and 1 or -1
        end
      else
        Z.axisArmed = true
      end
    end

    if delta == 0 then
      local kv = pollWheelKeys(pc)
      if kv ~= 0 then
        Z.hasDirection = true
        if Z.wheelSrc ~= 'ipc' then Z.wheelSrc = 'fkey' end
        delta = kv
      end
    end

    if delta == 0 then
      local ev = IN.wheelByEvent
      if ev ~= 0 then
        IN.wheelByEvent = 0
        Z.hasDirection = true
        if Z.wheelSrc ~= 'ipc' then Z.wheelSrc = 'keyevt' end
        delta = ev
      end
    end

    if delta == 0 and (Z.notch or 0) > 0 and not Z.hasDirection then
      delta = Z.notch
      Z.notch = 0
      Z.wheelSrc = 'notch'
      allowWrap = true
    end
    if (Z.notch or 0) > 0 and Z.hasDirection then Z.notch = 0 end
    if delta ~= 0 then onWheel(delta, allowWrap) end

    -- 平滑 + 应用
    if Z.mech then
      local dz = Z.zTarget - Z.z
      local stepv = CFG.smooth * CFG.pollInterval
      if math.abs(dz) <= stepv then
        Z.z = Z.zTarget
      else
        Z.z = Z.z + (dz > 0 and stepv or -stepv)
      end
      applyZoom(pawn, cam, pcm)
    end
  end)

  if not okAll then
    Z.errCount = Z.errCount + 1
    if Z.errCount <= 10 then lp('STEP ERR', tostring(err)) end
    if Z.errCount > 80 then
      Z.dead = true
      lp('too many errors, disabled')
    end
  end
end

local _loopStarted = false
local _subCount = 0

local function loop()
  step()
  pcall(function() UE4.Timer.Add(CFG.pollInterval, loop) end)
end

function CamZoomMod.Start()
  if _loopStarted then return end
  -- 只有真正排上定时器才算启动成功；否则保留重试机会（注入时机可能早于 UE4 环境就绪）
  local ok = pcall(function() UE4.Timer.Add(0.5, loop) end)
  if ok then
    _loopStarted = true
    lp('v20 online (self-calibrating)')
  end
end

if pcall(function() CamZoomMod.Start() end) then _subCount = _subCount + 1 end

if pcall(function()
  EventSystem.On(Event.Logined, function()
    schedule(CamZoomMod.Start, 2.0)
  end)
end) then _subCount = _subCount + 1 end

if pcall(function()
  EventSystem.On(Event.PCKeyboardEvent, function(...)
    if not _loopStarted then pcall(function() CamZoomMod.Start() end) end
    pcall(onKeyboardLikeEvent, ...)
  end)
end) then _subCount = _subCount + 1 end

-- 疑似「带方向的滚轮」事件（宿舍/照相馆镜头用它缩放）：若在战斗中也会广播，直接可用
local okHouse, subHouse = pcall(function()
  if Event.OnHousePlayerScrollWheel == nil then return false end
  EventSystem.On(Event.OnHousePlayerScrollWheel, function(...)
    local a = select(1, ...)
    local v = tonumber(a)
    if (Z.houseLog or 0) < 6 then
      Z.houseLog = (Z.houseLog or 0) + 1
      lp('HOUSEWHEEL', tostring(a), 'type=', type(a), 'argc=', select('#', ...))
    end
    if v and v ~= 0 then
      IN.wheelByEvent = (v > 0) and 1 or -1
      if Z.wheelSrc == 'none' or Z.wheelSrc == 'notch' then Z.wheelSrc = 'houseevt' end
    end
  end)
  return true
end)
if okHouse and subHouse then _subCount = _subCount + 1 end

-- 按键名反查：若滚轮会走键盘事件通道，这里能直接拿到方向
if pcall(function()
  EventSystem.On(Event.OnKeyboardKeyPressed, function(...)
    local k = select(1, ...)
    pcall(function()
      local nm = fkeyName(k)
      if not nm then return end
      local d = classifyWheelName(nm)
      if d ~= 0 then
        IN.wheelByEvent = d
        if Z.wheelSrc == 'none' or Z.wheelSrc == 'notch' then Z.wheelSrc = 'keyevt' end
        if (Z.keyevtLog or 0) < 8 then
          Z.keyevtLog = (Z.keyevtLog or 0) + 1
          lp('KEYNAME', nm, 'dir=', d)
        end
      elseif (Z.keyUnknownLog or 0) < 24 then
        Z.keyUnknownLog = (Z.keyUnknownLog or 0) + 1
        lp('KEYNAME(unknown)', tostring(nm))
      end
    end)
  end)
end) then _subCount = _subCount + 1 end

if _loopStarted or _subCount > 0 then
  CamZoomMod._ready = true
  lp('v20 injected (loop=' .. tostring(_loopStarted) .. ', subs=' .. tostring(_subCount) .. ')')
else
  lp('v20 injected but NOT ready, allow retry')
end

end -- CamZoomMod guard
