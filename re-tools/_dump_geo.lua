-- 一次性控件树转储（带位置）：用于定位「任务星星」「技能状态栏」
local function dumpTreeGeo()
  if Z.dumpGeoDone then return end
  local pc = getPC()
  if not pc then return end
  local cls
  pcall(function() cls = UE4.UUserWidget end)
  local arr
  if not pcall(function() arr = UE4.UWidgetBlueprintLibrary.GetAllWidgetsOfClass(pc, nil, cls) end) then return end
  if arr == nil then return end
  local n = arrCount(arr)
  if not n or n <= 0 then return end
  Z.dumpGeoDone = true

  local target
  for i = 1, math.min(n, 12) do
    local w = arrAt(arr, i)
    local c = uobjClass(w)
    if c ~= nil and string.find(c, 'fight_pc') then target = w end
  end
  if target == nil then return end
  local tree, root
  pcall(function() tree = target.WidgetTree end)
  if tree ~= nil then pcall(function() root = tree.RootWidget end) end
  if root == nil then lp('GEO no root'); return end

  local list = {}
  local budget = { n = 0 }
  local function walk(w, depth)
    if w == nil or depth > 7 or budget.n >= 200 then return end
    budget.n = budget.n + 1
    local nm, c, vis, op
    pcall(function() nm = w:GetName() end)
    pcall(function() c = w:GetClass():GetName() end)
    pcall(function() vis = tostring(w.Visibility) end)
    pcall(function() op = w:GetRenderOpacity() end)
    -- 槽位坐标（CanvasPanelSlot 有 GetPosition/GetSize）
    local px, py, sx, sy
    local slot
    pcall(function() slot = w.Slot end)
    if slot ~= nil then
      pcall(function()
        local p = slot:GetPosition()
        if p ~= nil then px = p.X; py = p.Y end
      end)
      pcall(function()
        local s = slot:GetSize()
        if s ~= nil then sx = s.X; sy = s.Y end
      end)
    end
    list[#list + 1] = string.format('%s%s[%s] v=%s o=%.2f p=(%.0f,%.0f) s=(%.0f,%.0f)',
      string.rep('..', depth), tostring(nm), tostring(c), tostring(vis),
      tonumber(op) or -1, tonumber(px) or -9999, tonumber(py) or -9999,
      tonumber(sx) or -1, tonumber(sy) or -1)
    local cnt
    pcall(function() cnt = w:GetChildrenCount() end)
    if type(cnt) == 'number' and cnt > 0 then
      for i = 0, math.min(cnt - 1, 30) do
        local ch
        pcall(function() ch = w:GetChildAt(i) end)
        if ch ~= nil then walk(ch, depth + 1) end
      end
    end
  end
  pcall(function() walk(root, 0) end)
  lp('GEO nodes=', #list)
  local buf = ''
  for i = 1, #list do
    buf = buf .. ' | ' .. list[i]
    if #buf > 170 or i == #list then lp('GEOT', buf); buf = '' end
  end
end
