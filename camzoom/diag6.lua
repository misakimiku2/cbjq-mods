
-- ========================================================
-- @File    : CamZoomMod.lua (diagnostics v15)
-- @Brief   : 相机全局函数溯源 + 缩放配置表深扫
-- ========================================================

CamZoomMod = CamZoomMod or {}
local LOG = '[CamZoomMod] '

local function lp(...)
  print(LOG, ...)
end

---1. 相机全局函数溯源
function CamZoomMod.TraceCamGlobals()
  lp('===== TraceCamGlobals =====')
  local targets = { 'SetCameraPosition', 'SetCameraFOV', 'SetCameraLocation', 'SetCameraRotation',
    'SetFixedPerspectiveEffect', 'CreateUniversalCamera', 'SetViewTargetToUniversalCamera',
    'GetUniversalCameraInfo', 'SetUniversalCameraMode', 'UpdateUniversalCamera' }
  for _, name in ipairs(targets) do
    local f = _G[name]
    if f ~= nil then
      local ok, info = pcall(debug.getinfo, f, 'S')
      if ok and info then
        lp('GLOBAL_FN', name, 'source=', tostring(info.short_src), 'what=', tostring(info.what), 'linedefined=', tostring(info.linedefined))
      else
        lp('GLOBAL_FN', name, 'C function (no lua info)')
      end
    end
  end
  -- 列出所有 Set/Get 开头的全局函数名（找漏网的相机函数）
  local setters = {}
  for k, v in pairs(_G) do
    if type(v) == 'function' then
      local kn = tostring(k)
      if kn:sub(1, 3) == 'Set' or kn:sub(1, 3) == 'Get' then
        setters[#setters + 1] = kn
      end
    end
  end
  table.sort(setters)
  lp('SETGET_GLOBALS(' .. #setters .. ')', table.concat(setters, ','))
end

---2. 深扫已加载模块：找包含缩放/臂长字段的配置表
function CamZoomModuleScan()
  lp('===== ModuleZoomScan =====')
  local hitCount = 0
  for mname, mval in pairs(package.loaded) do
    if type(mval) == 'table' and mname ~= '_G' then
      for k, v in pairs(mval) do
        local kn = tostring(k)
        -- 模块直接持有缩放字段
        if kn:lower():find('zoom') or kn:lower():find('armlength') or kn:lower():find('cameraboom') then
          lp('MOD_FIELD', mname .. '.' .. kn, '=', tostring(v))
          hitCount = hitCount + 1
        end
        -- 模块持有的子表里含缩放字段（嵌套一层）
        if type(v) == 'table' and hitCount < 60 then
          for k2, v2 in pairs(v) do
            local k2n = tostring(k2)
            if type(v2) == 'table' and (k2n:lower():find('zoom') or k2n:lower():find('armlength') or k2n:lower():find('cameraboom') or k2n:lower():find('cameraconfig')) then
              local fields = {}
              for k3, v3 in pairs(v2) do
                fields[#fields + 1] = tostring(k3) .. '=' .. type(v3)
              end
              table.sort(fields)
              lp('NESTED', mname .. '.' .. kn .. '.' .. k2n, '(' .. #fields .. ')', table.concat(fields, ',', 1, math.min(12, #fields)))
              hitCount = hitCount + 1
            end
          end
        end
      end
    end
  end
  lp('===== ModuleZoomScan end, hits=', hitCount)
end

---3. GM 执行器探测
function CamZoomMod.ProbeGMExec()
  lp('===== ProbeGMExec =====')
  lp('GM.DoScript type=', type(GM and GM.DoScript))
  lp('GM.FightDoString type=', type(GM and GM.FightDoString))
  lp('GM.IsOpen=', type(GM and GM.IsOpen))
  if GM and GM.IsOpen then
    local ok, r = pcall(GM.IsOpen)
    lp('GM.IsOpen()=', tostring(r))
  end
end

EventSystem.On(Event.Logined, function()
  UE4.Timer.Add(10, function()
    lp('diagnostics v15 online')
    CamZoomMod.TraceCamGlobals()
    CamZoomModuleScan()
    CamZoomMod.ProbeGMExec()
  end)
end)

lp('v15 injected, waiting Logined')
