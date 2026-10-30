-- ========================================================
-- @File    : ShopProbe.lua (v1)
-- @Brief   : 运行时转储商店相关 Lua 模块
--
-- 为什么走运行时：pak 里的 .lua 是密文，已知 key 解不开
-- （证据见 work/HANDOFF-pak-key.md 第五节）。运行时拿到的是游戏已经
-- 解密并加载好的对象，绕开文件层。
--
-- 手法：
--   1) package.loaded 全量枚举，按 shop/mall/store/purchase/goods 过滤
--   2) debug.getinfo(fn, 'S') 拿 chunk 源路径 + 行号
--   3) string.dump(fn) 拿字节码 —— 优先 io 直接落盘，否则 hex 打日志
--
-- ⚠ 商店模块可能**懒加载**（打开商店界面才 require），所以本探针每 5s
--   扫一轮，只转储"上一轮没见过"的模块，最多 40 轮（约 3 分钟）。
--   测法：进游戏 → 打开商店界面（各页签点一遍）→ 等 20s → 退出。
--
-- 判读（Game.log 里 [ShopProbe] 开头的行）：
--   CAP ...            能力探测（string.dump / debug / io 有没有被裁）
--   MODS n / MOD ...   命中模块名
--   KEYS ...           模块键（fn/table/string 类型）
--   FN ...             函数：源路径 + 起始行
--   BCBEGIN/BC ...     字节码 hex（io 不可用时才有）
--   FILE ...           io 可用时落盘的文件路径
-- ========================================================
if not (ShopProbe and ShopProbe._ready) then

ShopProbe = ShopProbe or {}
local P = ShopProbe
local LOG = '[ShopProbe]'
local function lp(...) print(LOG, ...) end

P.cfg = {
  pattern = { 'shop', 'mall', 'store', 'purchase', 'goods', 'commodity', 'trade' },
  intervalMs = 5000,
  maxTicks = 40,
  maxDumpBytes = 200000,   -- 单函数字节码上限，超了就只记长度
  maxFnPerModule = 60,     -- 单模块最多转储多少个函数（防日志爆炸）
  maxFnPerGlobal = 200,    -- 全局表（ShopLogic）预算更大
  globalPattern = { 'logic', 'net', 'dispatch', 'protocol' },
  keyPerModule = 48,
  hexPerLine = 400,        -- 每行 hex 字符数（日志单行别太长）
  outDir = 'D:/test/cbjq-re/work/_dump',  -- io 可用时的落盘目录（需预先存在）
}

P.seen = {}
P.tickCount = 0
P.dumpCount = 0

local function hex(s)
  return (s:gsub('.', function(c) return string.format('%02X', string.byte(c)) end))
end

local function safeStr(v, maxLen)
  local ok, s = pcall(tostring, v)
  if not ok then return '<?>' end
  if maxLen and #s > maxLen then return s:sub(1, maxLen) .. '...' end
  return s
end

-- ---------- 能力探测 ----------
local function caps()
  lp('CAP lua=', safeStr(_VERSION),
     'string.dump=', type(string.dump),
     'debug=', type(debug),
     'io=', type(io),
     'load=', type(load),
     'loadstring=', type(loadstring),
     'require=', type(require))
  if type(debug) == 'table' then
    lp('CAP debug.getinfo=', type(debug.getinfo),
       'getupvalue=', type(debug.getupvalue),
       'getlocal=', type(debug.getlocal),
       'sethook=', type(debug.sethook))
  end
  if type(io) == 'table' then
    lp('CAP io.open=', type(io.open), 'io.write=', type(io.write))
  end
end

-- ---------- 落盘 ----------
local function openOut(fname)
  if type(io) ~= 'table' or type(io.open) ~= 'function' then return nil end
  local ok, f = pcall(io.open, P.cfg.outDir .. '/' .. fname, 'wb')
  if ok and f then return f end
  return nil
end

-- ---------- 单个函数的转储 ----------
local function dumpFn(modName, label, fn)
  local src, line = '?', -1
  if type(debug) == 'table' and debug.getinfo then
    local ok, info = pcall(debug.getinfo, fn, 'S')
    if ok and info then
      src = safeStr(info.source, 160)
      line = info.linedefined or -1
    end
  end
  if type(string.dump) ~= 'function' then
    lp('FN', modName, label, 'src=', src, 'line=', line, 'dump=n/a')
    return
  end

  local ok, bc = pcall(string.dump, fn)
  if not ok or type(bc) ~= 'string' then
    lp('FN', modName, label, 'src=', src, 'line=', line, 'dump=ERR', safeStr(bc, 60))
    return
  end
  lp('FN', modName, label, 'src=', src, 'line=', line, 'bytes=', #bc)

  if #bc > P.cfg.maxDumpBytes then
    lp('BCSKIP', modName, label, 'too big', #bc)
    return
  end

  local fname = string.gsub(modName .. '__' .. label, '[^%w_%-]', '_') .. '.luac'
  local f = openOut(fname)
  if f then
    pcall(function() f:write(bc); f:close() end)
    lp('FILE', fname, #bc)
  else
    local h = hex(bc)
    local n = 0
    for i = 1, #h, P.cfg.hexPerLine do
      n = n + 1
      lp('BC', modName, label, n, h:sub(i, i + P.cfg.hexPerLine - 1))
    end
    lp('BCBEGIN', modName, label, #bc, 'lines=', n)
  end

  -- 自检：字节码能不能被 load 回来
  if type(load) == 'function' then
    local ok2 = pcall(load, bc)
    lp('BCLOAD', modName, label, ok2 and 'ok' or 'fail')
  end
end

-- ---------- 转储一个模块 ----------
local function dumpModule(name, m)
  P.dumpCount = P.dumpCount + 1
  -- 有些表是 C++ 代理（UnLua），pairs 可能什么都拿不到，先记一下元表形态
  do
    local mt = nil
    if type(getmetatable) == 'function' then
      local ok, v = pcall(getmetatable, m)
      if ok then mt = v end
    end
    local mtType = type(mt)
    local idx = 'n/a'
    if mtType == 'table' then
      local ok, v = pcall(function() return mt.__index end)
      if ok then idx = type(v) end
    end
    local c = 0
    for _ in pairs(m) do c = c + 1 end
    lp('MDHEAD', name, 'keys=', c, 'mt=', mtType, '__index=', idx)
  end
  local keys = {}
  local n = 0
  for k, v in pairs(m) do
    n = n + 1
    if #keys < P.cfg.keyPerModule and type(k) == 'string' then
      local t = type(v)
      local s = t
      if t == 'function' then
        s = 'fn'
        if type(debug) == 'table' and debug.getinfo then
          local ok, info = pcall(debug.getinfo, v, 'S')
          if ok and info then s = 'fn@' .. tostring(info.linedefined) end
        end
      elseif t == 'table' then
        local c = 0
        for _ in pairs(v) do c = c + 1; if c > 999 then break end end
        s = 'tbl#' .. c
      elseif t == 'string' then
        s = 'str:' .. safeStr(v, 40)
      end
      keys[#keys + 1] = k .. '=' .. s
    end
  end
  lp('KEYS', name, 'n=', n, table.concat(keys, ' '))

  -- 顶层函数
  local dumped = 0
  for k, v in pairs(m) do
    if dumped >= P.cfg.maxFnPerModule then lp('FNCAP', name, 'reached', dumped); break end
    if type(k) == 'string' and type(v) == 'function' then
      dumped = dumped + 1
      dumpFn(name, k, v)
    end
  end
  -- 一层嵌套表里的函数（商店常见 Shop.xxx 结构）
  for k, v in pairs(m) do
    if type(k) == 'string' and type(v) == 'table' then
      local c = 0
      for k2, v2 in pairs(v) do
        if type(k2) == 'string' and type(v2) == 'function' then
          c = c + 1
          if c <= 40 and dumped < P.cfg.maxFnPerModule then
            dumped = dumped + 1
            dumpFn(name, k .. '.' .. k2, v2)
          end
        end
      end
    end
  end
end

-- ---------- 每轮扫描 ----------
local function matches(name)
  local l = string.lower(name)
  for _, pat in ipairs(P.cfg.pattern) do
    if string.find(l, pat, 1, true) then return true end
  end
  return false
end

local function tick()
  P.tickCount = P.tickCount + 1
  local loaded = package and package.loaded or {}
  local total, hit, fresh = 0, 0, 0
  local names = {}
  for name in pairs(loaded) do
    if type(name) == 'string' then
      total = total + 1
      if matches(name) then
        hit = hit + 1
        names[#names + 1] = name
      end
    end
  end
  table.sort(names)

  -- 本轮新出现的模块名统一打一行，方便看懒加载时机
  local freshNames = {}
  for _, name in ipairs(names) do
    if not P.seen[name] then
      P.seen[name] = true
      fresh = fresh + 1
      freshNames[#freshNames + 1] = name
    end
  end

  lp('TICK', P.tickCount, 'loaded=', total, 'hit=', hit, 'fresh=', fresh)
  if fresh > 0 then
    local buf = ''
    for _, n in ipairs(freshNames) do
      buf = buf .. ' ' .. n
      if #buf > 180 then lp('MOD', buf); buf = '' end
    end
    if #buf > 0 then lp('MOD', buf) end
  end

  -- 全局表：ShopLogic 不在 package.loaded，必须单独抽
  do
    local budget = P.cfg.maxFnPerGlobal
    for k, v in pairs(_G or {}) do
      if type(k) == 'string' and type(v) == 'table' then
        local lk = string.lower(k)
        local want = false
        for _, pat in ipairs(P.cfg.globalPattern) do
          if string.find(lk, pat, 1, true) then want = true break end
        end
        if want then
          local c = 0
          for _ in pairs(v) do c = c + 1; if c > 5000 then break end end
          P.seen['_G.' .. k] = P.seen['_G.' .. k] or 0
          if P.seen['_G.' .. k] ~= c then
            P.seen['_G.' .. k] = c
            lp('GTABLE', '_G.' .. k, 'keys=', c)
            local saved = P.cfg.maxFnPerModule
            P.cfg.maxFnPerModule = budget
            local ok, err = pcall(dumpModule, '_G.' .. k, v)
            P.cfg.maxFnPerModule = saved
            if not ok then lp('ERR', '_G.' .. k, safeStr(err, 120)) end
          end
        end
      end
    end
  end

  for _, name in ipairs(freshNames) do
    local m = loaded[name]
    if type(m) == 'table' then
      local ok, err = pcall(dumpModule, name, m)
      if not ok then lp('ERR', name, safeStr(err, 120)) end
    else
      lp('MODTYPE', name, type(m))
    end
  end

  if P.tickCount == 6 or P.tickCount == 12 then
    if P.dumpCount == 0 then
      lp('HINT 还没见到商店模块 —— 请在游戏里打开一次商店界面（各页签点一遍），再等 10s')
    end
  end

  if P.tickCount >= P.cfg.maxTicks then
    local seenCount = 0
    for _ in pairs(P.seen) do seenCount = seenCount + 1 end
    lp('DONE ticks=', P.tickCount, 'modules=', P.dumpCount, 'seen=', seenCount)
    P.stopped = true
  end
end

local function loop()
  if P.stopped then return end
  local ok, err = pcall(tick)
  if not ok then lp('LOOPERR', safeStr(err, 120)) end
  pcall(function() UE4.Timer.Add(P.cfg.intervalMs / 1000, loop) end)
end

-- ============================================================
-- 全量协议扫描（PROTO SWEEP）
--   枚举 package.loaded + 所有全局表（深度 3），对每个函数 string.dump，
--   只把**字节码里含 "CallGS"** 的函数落盘 —— 比全量 dump 小一个量级。
--   分批跑（每 0.3s 一批），避免一次性卡住主线程。
-- ============================================================
local PS = { queue = {}, idx = 1, perTick = 15, scanned = 0, dumped = 0,
             seen = {}, done = false, visited = {} }

local function collectFns(name, tbl, depth, out)
  if depth > 3 or PS.visited[tbl] then return end
  PS.visited[tbl] = true
  local ok = pcall(function()
    for k, v in pairs(tbl) do
      if type(k) == 'string' then
        if type(v) == 'function' then
          out[#out + 1] = { name = name .. '.' .. k, fn = v }
        elseif type(v) == 'table' and depth < 3 then
          collectFns(name .. '.' .. k, v, depth + 1, out)
        end
      end
    end
  end)
end

local function buildQueue()
  if #PS.queue > 0 then return end
  local ok = pcall(function()
    for name, m in pairs(package and package.loaded or {}) do
      if type(name) == 'string' and type(m) == 'table' then
        PS.queue[#PS.queue + 1] = { name = 'L:' .. name, tbl = m }
      end
    end
    for k, v in pairs(_G or {}) do
      if type(k) == 'string' and type(v) == 'table' then
        PS.queue[#PS.queue + 1] = { name = 'G:' .. k, tbl = v }
      end
    end
  end)
  lp('PROTO queued', #PS.queue, 'roots=', tostring(ok))
end

local function protoTick()
  if PS.done then return end
  buildQueue()
  local stopAt = math.min(PS.idx + PS.perTick - 1, #PS.queue)
  for i = PS.idx, stopAt do
    local item = PS.queue[i]
    local fns = {}
    collectFns(item.name, item.tbl, 1, fns)
    for _, f in ipairs(fns) do
      if not PS.seen[f.fn] then
        PS.seen[f.fn] = true
        PS.scanned = PS.scanned + 1
        local ok, bc = pcall(string.dump, f.fn)
        if ok and type(bc) == 'string' and #bc <= P.cfg.maxDumpBytes then
          local hit = string.find(bc, 'CallGS', 1, true) or string.find(bc, 'NtfScript', 1, true)
          if hit then
            local fname = 'PROTO_' .. string.gsub(f.name, '[^%w_%-]', '_') .. '.luac'
            local fh = openOut(fname)
            if fh then
              pcall(function() fh:write(bc); fh:close() end)
              PS.dumped = PS.dumped + 1
            else
              lp('PROTO noio', fname)
            end
          end
        end
      end
    end
  end
  PS.idx = stopAt + 1
  if PS.idx > #PS.queue then
    PS.done = true
    lp('PROTODONE roots=', #PS.queue, 'scanned=', PS.scanned, 'dumped=', PS.dumped)
    return
  end
  if PS.idx % 90 < PS.perTick then
    lp('PROTO progress', PS.idx, '/', #PS.queue, 'dumped=', PS.dumped)
  end
  pcall(function() UE4.Timer.Add(0.3, protoTick) end)
end

-- ---------- 启动 ----------
-- 与 CamZoomMod 同款时序：立即试一次，不成则挂 Event.Logined 兜底。
-- ⚠ 不能无条件把 _ready 置 true —— umg_main 加载时 UE4.Timer 可能还没就绪，
--   那样 pcall 静默失败后永远没有第二次机会。
local function start()
  if P.started then return end
  local ok = pcall(function() UE4.Timer.Add(3.0, loop) end)
  if ok then
    P.started = true
    lp('START interval=', P.cfg.intervalMs, 'maxTicks=', P.cfg.maxTicks,
       'outDir=', P.cfg.outDir)
    -- 全量协议扫描：延后 6s 起跑，和主扫描错开
    pcall(function() UE4.Timer.Add(6.0, protoTick) end)
  end
end
P.Start = start

caps()

-- _G 里也扫一遍（有些游戏把入口挂在全局）
do
  local g = {}
  for k, v in pairs(_G or {}) do
    if type(k) == 'string' and matches(k) then
      g[#g + 1] = k .. '=' .. type(v)
    end
  end
  lp('GLOBAL n=', #g, table.concat(g, ' '))
end

local subs = 0
if pcall(function() start() end) then end
if not P.started then
  if pcall(function()
        EventSystem.On(Event.Logined, function()
          pcall(function() UE4.Timer.Add(2.0, start) end)
        end)
      end) then subs = subs + 1 end
end

if P.started or subs > 0 then
  P._ready = true
  lp('injected started=', tostring(P.started), 'subs=', subs)
else
  lp('injected but NOT ready, allow retry')
end

end -- _ready
