
-- ========================================================
-- @File    : CamZoomMod.lua (diagnostics v16)
-- @Brief   : UE4.lua 函数枚举 + 源文件导出
-- ========================================================

CamZoomMod = CamZoomMod or {}
local LOG = '[CamZoomMod] '

local function lp(...)
  print(LOG, ...)
end

---1. 枚举所有在 UE4.lua 中定义的函数
function CamZoomMod.EnumUE4LuaFunctions()
  lp('===== UE4.lua functions =====')
  local names = {}
  for k, v in pairs(_G) do
    if type(v) == 'function' then
      local ok, info = pcall(debug.getinfo, v, 'S')
      if ok and info and info.source and tostring(info.source):find('UE4%.lua', 1, false) then
        names[#names + 1] = tostring(k) .. '@' .. tostring(info.linedefined)
      end
    end
  end
  table.sort(names)
  lp('UE4LUA_FNS(' .. #names .. ')')
  for _, s in ipairs(names) do
    lp('  ' .. s)
  end
end

---2. 用游戏文件 API 导出 UE4.lua 原始字节（base64 分块打印，离线解密）
function CamZoomMod.DumpUE4LuaFile()
  lp('===== DumpUE4LuaFile =====')
  local paths = {
    '../../../Game/Content/Script/Misc/UE4.lua',
    'Script/Misc/UE4.lua',
    '../../../Game/Content/Script/Misc/UE4.lua',
  }
  local b64chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
  local function tobase64(data)
    local out = {}
    for i = 1, #data, 3 do
      local a, b, c = data:byte(i, i + 3)
      local n = a * 65536 + (b or 0) * 256 + (c or 0)
      out[#out + 1] = b64chars:sub(math.floor(n / 262144) % 64 + 1, math.floor(n / 262144) % 64 + 1)
        .. b64chars:sub(math.floor(n / 4096) % 64 + 1, math.floor(n / 4096) % 64 + 1)
        .. b64chars:sub(math.floor(n / 64) % 64 + 1, math.floor(n / 64) % 64 + 1)
        .. b64chars:sub(n % 64 + 1, n % 64 + 1)
    end
    local pad = (3 - #data % 3) % 3
    if pad > 0 then
      local s = out[#out]
      out[#out] = s:sub(1, #s - pad) .. string.rep('=', pad)
    end
    return table.concat(out)
  end

  for _, p in ipairs(paths) do
    local ok, err = pcall(function()
      local f = UE4.File()
      local exists = UE4.UBlueprintPathsLibrary.FileExists(p)
      lp('TRY', p, 'exists=', tostring(exists))
      if not exists then return end
      local okOpen = f:Open(p, 'r')
      if not okOpen then
        lp('  open fail')
        return
      end
      local content = UE4.File.Read(f, 'a')
      f:Close()
      if not content or #content == 0 then
        lp('  empty content')
        return
      end
      lp('FILE READ OK len=', #content, 'head=', string.byte(content, 1, 4) and (string.byte(content, 1) .. ',' .. string.byte(content, 2) .. ',' .. string.byte(content, 3) .. ',' .. string.byte(content, 4)) or '?')
      -- base64 分块输出
      local b64 = tobase64(content)
      lp('B64TOTAL', #b64)
      local chunk = 3000
      for i = 1, #b64, chunk do
        lp('B64|' .. b64:sub(i, i + chunk - 1))
      end
      return true
    end)
    if ok then return end
    if err then lp('DUMP ERR', tostring(err)) end
  end
end

EventSystem.On(Event.Logined, function()
  UE4.Timer.Add(10, function()
    lp('diagnostics v16 online')
    CamZoomMod.EnumUE4LuaFunctions()
    CamZoomMod.DumpUE4LuaFile()
  end)
end)

lp('v16 injected, waiting Logined')
