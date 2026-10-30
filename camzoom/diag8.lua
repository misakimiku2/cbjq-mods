
-- ========================================================
-- @File    : CamZoomMod.lua (diagnostics v18)
-- @Brief   : 战斗中配置表深扫 + 开镜 FOV 监控
-- ========================================================

CamZoomMod = CamZoomMod or {}
local LOG = '[CamZoomMod] '

local function lp(...)
  print(LOG, ...)
end

---战斗中深度扫描 package.loaded（3 层），找相机缩放配置
function CamZoomMod.CombatConfigScan()
  lp('===== CombatConfigScan begin =====')
  local hits = 0
  local seen = {}
  local function walk(tbl, path, depth)
    if depth > 3 or hits > 50 or seen[tbl] then return end
    seen[tbl] = true
    for k, v in pairs(tbl) do
      local kn = tostring(k)
      local klow = kn:lower()
      if klow:find('zoom') or klow:find('armlength') or klow:find('cameraboom') or klow:find('cameraoffset') or (klow:find('fov') and klow:find('min') == nil) then
        lp('HIT', path .. '.' .. kn, '=', tostring(v))
        hits = hits + 1
      end
      if type(v) == 'table' and not seen[v] then
        walk(v, path .. '.' .. kn, depth + 1)
      end
    end
  end
  for mname, mval in pairs(package.loaded) do
    if type(mval) == 'table' and mname ~= '_G' then
      walk(mval, tostring(mname), 1)
    end
  end
  -- 全局表也扫一层
  for gname, gval in pairs(_G) do
    if type(gval) == 'table' and gname ~= '_G' and gname ~= 'package' then
      walk(gval, 'G.' .. tostring(gname), 1)
    end
  end
  lp('===== CombatConfigScan end, hits=', hits)
end

---FOV 监控：每 0.8 秒读 pawn.Camera.FieldOfView，捕捉开镜变化
local fovLogCount = 0
local lastFov = nil
local function monitorFOV()
  local okP, pawn = pcall(UE4.UGameplayStatics.GetPlayerPawn, GetGameIns(), 0)
  if not okP or not pawn then return end
  local okC, cam = pcall(function() return pawn.Camera end)
  if not okC or not cam then return end
  local okR, fov = pcall(function() return cam.FieldOfView end)
  if okR and fov then
    if lastFov == nil or math.abs(fov - lastFov) > 0.5 then
      fovLogCount = fovLogCount + 1
      if fovLogCount <= 20 then
        lp('FOV_CHANGE', string.format('%.1f', lastFov or -1), '->', string.format('%.1f', fov))
      end
      lastFov = fov
    end
  end
end

function Z_Poll() end

function Z_Start()
  UE4.Timer.Add(0.8, function()
    monitorFOV()
    Z_Start()
  end)
end

EventSystem.On(Event.Logined, function()
  UE4.Timer.Add(10, function()
    lp('diagnostics v18 online')
    CamZoomMod.CombatConfigScan()
    Z_Start()
    lp('FOV monitor running - 请在战斗中开镜（按住右键）几次')
  end)
end)

lp('v18 injected, waiting Logined')
