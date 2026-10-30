-- 一次性深度转储：遇到 UserWidget 就进它自己的 WidgetTree 继续走
local function deepDump()
  if Z.deepDone then return end
  local pc = getPC()
  if not pc then return end
  local cls
  pcall(function() cls = UE4.UUserWidget end)
  local arr
  if not pcall(function() arr = UE4.UWidgetBlueprintLibrary.GetAllWidgetsOfClass(pc, nil, cls) end) then return end
  if arr == nil then return end
  local n = arrCount(arr)
  if not n or n <= 0 then return end
  Z.deepDone = true

  local target
  for i = 1, math.min(n, 12) do
    local w = arrAt(arr, i)
    local c = uobjClass(w)
    if c ~= nil and string.find(c, 'fight_pc') then target = w end
  end
  if target == nil then return end

  local out = {}
  local budget = { n = 0 }
  local function sub(uw)
    local t, r
    pcall(function() t = uw.WidgetTree end)
    if t ~= nil then pcall(function() r = t.RootWidget end) end
    return r
  end
  local function walk(w, depth)
    if w == nil or depth > 10 or budget.n >= 320 then return end
    budget.n = budget.n + 1
    local nm, c, vis, op
    pcall(function() nm = w:GetName() end)
    pcall(function() c = w:GetClass():GetName() end)
    pcall(function() vis = tostring(w.Visibility) end)
    pcall(function() op = w:GetRenderOpacity() end)
    out[#out + 1] = string.format('%s%s[%s] v=%s o=%.2f',
      string.rep('..', depth), tostring(nm), tostring(c), tostring(vis), tonumber(op) or -1)
    -- 是 UserWidget 就先钻进它自己的树
    if c ~= nil and string.find(c, '_C') then
      local r = sub(w)
      if r ~= nil and r ~= w then walk(r, depth + 1) end
    end
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
  pcall(function() walk(target, 0) end)
  lp('DEEP nodes=', #out)
  local buf = ''
  for i = 1, #out do
    buf = buf .. ' | ' .. out[i]
    if #buf > 170 or i == #out then lp('DEEPT', buf); buf = '' end
  end
end
