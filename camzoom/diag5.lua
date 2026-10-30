
-- ========================================================
-- @File    : CamZoomMod.lua (diagnostics v14)
-- @Brief   : 全局表方法普查 —— 找相机/FOV/缩放的可调用入口
-- ========================================================

CamZoomMod = CamZoomMod or {}
local LOG = '[CamZoomMod] '

local function lp(...)
  print(LOG, ...)
end

---扫描所有全局表：收集成员名匹配相机相关的函数
function CamZoomMod.ScanGlobals()
  lp('===== ScanGlobals begin =====')
  local found = 0
  for gname, gval in pairs(_G) do
    if type(gval) == 'table' and gname ~= '_G' and gname ~= 'CamZoomMod' then
      for k, v in pairs(gval) do
        local kn = tostring(k)
        if type(v) == 'function' and (kn:lower():find('camera') or kn:lower():find('fov') or kn:lower():find('zoom')) then
          lp('FN', gname .. '.' .. kn)
          found = found + 1
        end
      end
    elseif type(gval) == 'function' then
      local gn = tostring(gname)
      if gn:lower():find('camera') or gn:lower():find('fov') or gn:lower():find('zoom') then
        lp('GFN', gn)
        found = found + 1
      end
    end
  end
  lp('===== ScanGlobals end, found=', found)
end

---完整导出 GM 表（游戏调试工具箱）
function CamZoomMod.DumpGM()
  if type(GM) ~= 'table' then
    lp('GM not a table:', type(GM))
    return
  end
  local names = {}
  for k, v in pairs(GM) do
    names[#names + 1] = tostring(k) .. ':' .. type(v)
  end
  table.sort(names)
  lp('GM_TABLE(' .. #names .. ')')
  for _, s in ipairs(names) do
    lp('  GM.' .. s)
  end
end

function Z_PollStub() end

EventSystem.On(Event.Logined, function()
  UE4.Timer.Add(10, function()
    lp('diagnostics v14 online')
    CamZoomMod.ScanGlobals()
    CamZoomMod.DumpGM()
  end)
end)

lp('v14 injected, waiting Logined')
