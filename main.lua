local floor, ceil, min, max = math.floor, math.ceil, math.min, math.max
local sin, cos, sqrt, abs, pi = math.sin, math.cos, math.sqrt, math.abs, math.pi
local atan2 = math.atan2 or math.atan
local sort = table.sort

local VW, VH = 320, 240
local ROAD = { left = 88, right = 232, bottom = 188 }
local BOX = { x = 20, y = 190, w = 216, h = 50 }
local SLOT_SIZE = 26
local START_MONEY = 50
local MAX_LIFE = 10
local ROLL_TIME = 0.9
local FLASH_TIME = 0.09
local MAX_PARTICLES = 320
local MAX_FLOATERS = 32
local POOL_LIMIT = 256
local BOUNTY = 5
local TURN_SPEED = 12

local COLOR = {
  white = { 255, 255, 255 },
  black = { 0, 0, 0 },
  gold = { 255, 208, 64 },
  red = { 228, 64, 56 },
  green = { 108, 208, 92 },
  gray = { 176, 176, 186 },
  dim = { 112, 112, 124 },
  slot = { 200, 172, 114 },
  slotHover = { 216, 188, 128 },
  slotEdge = { 150, 120, 76 },
  hilite = { 255, 240, 150 },
  panel = { 20, 22, 26 },
  panelEdge = { 44, 28, 16 },
  plate = { 72, 46, 24 },
  plateLight = { 150, 102, 56 },
  burn = { 78, 46, 22 },
  hpGood = { 96, 200, 80 },
  hpBad = { 200, 48, 48 },
}

local BLOOD = { { 170, 24, 24 }, { 210, 40, 36 }, { 120, 16, 18 } }
local BRASS = { 236, 190, 70 }

local THEME = {
  green = { face = { 88, 170, 72 }, hover = { 116, 204, 92 }, light = { 170, 236, 140 }, dark = { 44, 98, 40 }, text = { 16, 40, 12 } },
  gold = { face = { 226, 178, 44 }, hover = { 252, 206, 72 }, light = { 255, 240, 150 }, dark = { 140, 100, 20 }, text = { 52, 32, 4 } },
  red = { face = { 196, 60, 50 }, hover = { 228, 86, 70 }, light = { 255, 150, 130 }, dark = { 110, 28, 24 }, text = { 255, 240, 230 } },
}
local DISABLED = { face = { 96, 92, 88 }, light = { 128, 124, 120 }, dark = { 60, 58, 56 }, text = { 150, 146, 140 } }

local WAVE = {
  count = function(n) return 5 + (n - 1) * 4 end,
  interval = function(n) return max(0.28, 1.5 - 0.1 * n) end,
  health = function(n) return 3 + floor((n - 1) / 3) end,
  speed = function(n) return min(34, 14 + n * 1.2) end,
  bonus = function(n) return 10 + n * 5 end,
}

local WEAPONS = {
  glock = {
    id = "glock",
    name = "GLOCK",
    sprite = "glock",
    cost = 25,
    weight = 1,
    damage = 1,
    cooldown = 0.38,
    range = 180,
    bulletSpeed = 340,
    muzzle = 9,
    recoil = 3,
    kick = 0.35,
    spread = 0.04,
  },
}
local WEAPON_LIST = { WEAPONS.glock }

local Assets = { sprites = {}, glyphs = {}, flashes = {}, owned = {} }
local view = { x = 0, y = 0, scale = 3 }
local canvas, ui, game
local fatalError
local windowFocused = true

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

local function snap(v)
  return floor(v + 0.5)
end

local function angleDiff(from, to)
  return (to - from + pi) % (2 * pi) - pi
end

local function rnd()
  return love.math.random()
end

local function rndInt(a, b)
  return love.math.random(a, b)
end

local function rndRange(a, b)
  return a + (b - a) * love.math.random()
end

local function removeAt(list, i)
  local n = #list
  list[i] = list[n]
  list[n] = nil
end

local function removeValue(list, value)
  for i = 1, #list do
    if list[i] == value then
      removeAt(list, i)
      return true
    end
  end
  return false
end

local function setColor(c, a)
  love.graphics.setColor(c[1] / 255, c[2] / 255, c[3] / 255, a or 1)
end

local function newPool(factory)
  local free = {}
  return {
    acquire = function()
      local n = #free
      if n > 0 then
        local item = free[n]
        free[n] = nil
        return item
      end
      return factory()
    end,
    release = function(item)
      if #free < POOL_LIMIT then free[#free + 1] = item end
    end,
  }
end

local function releaseAll(list, pool)
  for i = #list, 1, -1 do
    pool.release(list[i])
    list[i] = nil
  end
end

local function labelMaker(prefix, suffix)
  local memo, count = {}, 0
  return function(value)
    local text = memo[value]
    if not text then
      if count >= 512 then
        memo, count = {}, 0
      end
      text = prefix .. value .. (suffix or "")
      memo[value] = text
      count = count + 1
    end
    return text
  end
end

local moneyLabel = labelMaker("$")
local waveLabel = labelMaker("WAVE ")
local lifeLabel = labelMaker("HP ", "/" .. MAX_LIFE)
local zombieLabel = labelMaker("ZOMBIES ")
local clearedLabel = labelMaker("WAVES CLEARED ")
local bannerLabel = labelMaker("WAVE ")
local bonusLabel = labelMaker("+$")

local bulletPool = newPool(function() return {} end)
local particlePool = newPool(function() return {} end)

local function track(resource)
  Assets.owned[#Assets.owned + 1] = resource
  return resource
end

local function buildSprite(rows, palette)
  local h = #rows
  if h == 0 then return nil, "empty sprite" end
  local w = #rows[1]
  local data = love.image.newImageData(w, h)
  for y = 1, h do
    local row = rows[y]
    if #row ~= w then
      data:release()
      return nil, "sprite row " .. y .. " has width " .. #row .. ", expected " .. w
    end
    for x = 1, w do
      local ch = row:sub(x, x)
      local c = palette[ch]
      if c then
        data:setPixel(x - 1, y - 1, c[1] / 255, c[2] / 255, c[3] / 255, (c[4] or 255) / 255)
      elseif ch ~= "." then
        data:release()
        return nil, "unknown palette key '" .. ch .. "'"
      end
    end
  end
  local image = love.graphics.newImage(data)
  image:setFilter("nearest", "nearest")
  data:release()
  track(image)
  return { image = image, w = w, h = h }
end

local function g(...)
  return table.concat({ ... })
end

local GLYPHS = {
  [" "] = g("000", "000", "000", "000", "000"),
  A = g("010", "101", "111", "101", "101"),
  B = g("110", "101", "110", "101", "110"),
  C = g("011", "100", "100", "100", "011"),
  D = g("110", "101", "101", "101", "110"),
  E = g("111", "100", "110", "100", "111"),
  F = g("111", "100", "110", "100", "100"),
  G = g("011", "100", "101", "101", "011"),
  H = g("101", "101", "111", "101", "101"),
  I = g("111", "010", "010", "010", "111"),
  J = g("001", "001", "001", "101", "010"),
  K = g("101", "101", "110", "101", "101"),
  L = g("100", "100", "100", "100", "111"),
  M = g("101", "111", "111", "101", "101"),
  N = g("110", "101", "101", "101", "101"),
  O = g("010", "101", "101", "101", "010"),
  P = g("110", "101", "110", "100", "100"),
  Q = g("010", "101", "101", "111", "011"),
  R = g("110", "101", "110", "101", "101"),
  S = g("011", "100", "010", "001", "110"),
  T = g("111", "010", "010", "010", "010"),
  U = g("101", "101", "101", "101", "111"),
  V = g("101", "101", "101", "101", "010"),
  W = g("101", "101", "111", "111", "101"),
  X = g("101", "101", "010", "101", "101"),
  Y = g("101", "101", "010", "010", "010"),
  Z = g("111", "001", "010", "100", "111"),
  ["0"] = g("111", "101", "101", "101", "111"),
  ["1"] = g("010", "110", "010", "010", "111"),
  ["2"] = g("110", "001", "010", "100", "111"),
  ["3"] = g("110", "001", "010", "001", "110"),
  ["4"] = g("101", "101", "111", "001", "001"),
  ["5"] = g("111", "100", "110", "001", "110"),
  ["6"] = g("011", "100", "111", "101", "111"),
  ["7"] = g("111", "001", "010", "010", "010"),
  ["8"] = g("111", "101", "111", "101", "111"),
  ["9"] = g("111", "101", "111", "001", "110"),
  ["$"] = g("011", "110", "010", "011", "110"),
  ["+"] = g("000", "010", "111", "010", "000"),
  ["-"] = g("000", "000", "111", "000", "000"),
  ["/"] = g("001", "001", "010", "100", "100"),
  ["."] = g("000", "000", "000", "000", "010"),
  ["!"] = g("010", "010", "010", "000", "010"),
  ["?"] = g("110", "001", "010", "000", "010"),
  [":"] = g("000", "010", "000", "010", "000"),
}

local PALETTE = {
  k = { 22, 22, 26 },
  d = { 56, 58, 66 },
  e = { 120, 124, 136 },
  y = { 255, 226, 80 },
  o = { 255, 148, 40 },
  w = { 255, 255, 230 },
  t = { 196, 164, 104 },
  T = { 150, 120, 72 },
  G = { 58, 104, 56 },
  g = { 112, 168, 88 },
  r = { 216, 48, 48 },
  m = { 70, 24, 24 },
  b = { 84, 104, 150 },
  x = { 150, 36, 36 },
  p = { 58, 54, 84 },
}

local function concatRows(a, b)
  local out = {}
  for i = 1, #a do out[#out + 1] = a[i] end
  for i = 1, #b do out[#out + 1] = b[i] end
  return out
end

local ZOMBIE_TOP = {
  "...GGGG...",
  "..GggggG..",
  "..GrggrG..",
  "..GggggG..",
  "..GmmmmG..",
  "...GggG...",
  ".bbbbbbbb.",
  "gbbxbbbbbg",
  "g.bbbbbb.g",
  "..bbxbbb..",
  "..bbbbbb..",
}
local ZOMBIE_LEGS_A = { "..pp..pp..", "..pp..pp..", "..kk..kk.." }
local ZOMBIE_LEGS_B = { "..pp..pp..", ".pp....pp.", ".kk....kk." }

local GLOCK_ROWS = {
  ".kkkkkkkkkk.",
  ".keeeeeeekk.",
  ".kddddddddk.",
  ".kkkkkkkkkk.",
  ".kddk.......",
  ".kddk.......",
  ".kkkk.......",
}

local SANDBAG_ROWS = {
  "....tttttttttt....",
  "..tttTtttttTtttt..",
  ".ttttTttttttTtttt.",
  ".TTTTTTTTTTTTTTTT.",
}

local FLASH_ROWS = {
  { "..y..", ".yoy.", "yowoy", ".yoy.", "..y.." },
  { ".y.", "yoy", ".y." },
  { "y.y", ".w.", "y.y" },
}

local FLARE_ROWS = { "..yyy.", "oyyyww", "..yyy." }

local function buildBackground()
  local rng = love.math.newRandomGenerator(20260)
  local function rr() return rng:random() end
  local data = love.image.newImageData(VW, VH)

  local function put(x, y, r, gg, b)
    if x >= 0 and x < VW and y >= 0 and y < VH then
      data:setPixel(x, y, clamp(r, 0, 255) / 255, clamp(gg, 0, 255) / 255, clamp(b, 0, 255) / 255, 1)
    end
  end

  local edgeL, edgeR = {}, {}
  local oL, oR = 0, 0
  for y = 0, VH - 1 do
    oL = clamp(oL + (rr() - 0.5) * 1.6, -4, 4)
    oR = clamp(oR + (rr() - 0.5) * 1.6, -4, 4)
    edgeL[y] = floor(ROAD.left + oL)
    edgeR[y] = floor(ROAD.right + oR)
  end

  local function sandColor(d, x, y)
    local n = rng:random(-6, 6)
    if d <= 4 then return 148 + n, 120 + n, 76 + n end
    if d <= 8 then return 178 + n, 148 + n, 96 + n end
    if d <= 12 then return 204 + n, 176 + n, 116 + n end
    if d <= 15 then return 228 + n, 204 + n, 148 + n end
    if d <= 16 then return 244 + n, 226 + n, 176 + n end
    local r, gg, b = 224 + n, 198 + n, 138 + n
    if (y + floor(x * 0.3)) % 14 == 0 then r, gg, b = r - 14, gg - 14, b - 12 end
    if rr() < 0.012 then r, gg, b = 172, 142, 98 end
    return r, gg, b
  end

  for y = 0, VH - 1 do
    local eL, eR = edgeL[y], edgeR[y]
    for x = 0, VW - 1 do
      if x >= eL and x < eR then
        local n = rng:random(-7, 7)
        local r, gg, b = 72 + n, 72 + n, 78 + n
        local d = min(x - eL, eR - 1 - x)
        if d < 2 then
          r, gg, b = 44 + n, 44 + n, 48 + n
        elseif d < 9 and rr() < (9 - d) * 0.035 then
          r, gg, b = 190 + n, 164 + n, 108 + n
        end
        if rr() < 0.012 then r, gg, b = 118, 118, 124 end
        put(x, y, r, gg, b)
      else
        local d = x < eL and (eL - x) or (x - eR + 1)
        local r, gg, b = sandColor(d, x, y)
        put(x, y, r, gg, b)
      end
    end
  end

  for y = 0, VH - 1 do
    if y % 26 < 15 then
      for x = 159, 160 do
        if rr() > 0.4 then
          local n = rng:random(-10, 10)
          put(x, y, 184 + n, 164 + n, 66)
        end
      end
    end
  end

  for _ = 1, 6 do
    local pw, ph = rng:random(14, 30), rng:random(9, 20)
    local px, py = rng:random(100, 212 - pw), rng:random(8, 160)
    for y = py, py + ph - 1 do
      for x = px, px + pw - 1 do
        local n = rng:random(-5, 5)
        if x == px or x == px + pw - 1 or y == py or y == py + ph - 1 then
          put(x, y, 40 + n, 40 + n, 44 + n)
        else
          put(x, y, 58 + n, 58 + n, 63 + n)
        end
      end
    end
  end

  for _ = 1, 9 do
    local cx, cy = rng:random(104, 216), rng:random(10, 176)
    local rx, ry = rng:random(4, 10), rng:random(3, 6)
    for y = cy - ry - 1, cy + ry + 1 do
      for x = cx - rx - 1, cx + rx + 1 do
        local dx, dy = (x - cx) / rx, (y - cy) / ry
        local dist = dx * dx + dy * dy + (rr() - 0.5) * 0.35
        if dist <= 1 then
          local n = rng:random(-4, 4)
          if dist > 0.65 then
            put(x, y, 24 + n, 24 + n, 28 + n)
          elseif rr() < 0.22 then
            put(x, y, 92 + n, 76 + n, 52 + n)
          else
            put(x, y, 36 + n, 36 + n, 40 + n)
          end
        elseif dist <= 1.35 and dy < 0 then
          put(x, y, 104, 104, 110)
        end
      end
    end
    for _ = 1, 8 do
      put(cx + rng:random(-rx - 3, rx + 3), cy + rng:random(-ry - 3, ry + 3), 124, 124, 130)
    end
  end

  local function crack(x, y, angle, len, depth)
    for _ = 1, len do
      angle = angle + (rr() - 0.5) * 0.9
      x = x + cos(angle)
      y = y + sin(angle)
      local ix, iy = floor(x), floor(y)
      if iy >= 0 and iy < VH and ix > edgeL[iy] + 2 and ix < edgeR[iy] - 3 then
        put(ix + 1, iy, 100, 100, 106)
        put(ix, iy, 26, 26, 30)
        if depth == 0 and rr() < 0.3 then put(ix, iy + 1, 26, 26, 30) end
      end
      if depth < 2 and rr() < 0.05 then
        local side = rr() < 0.5 and -1 or 1
        crack(x, y, angle + side * (0.5 + rr() * 0.7), floor(len * 0.5), depth + 1)
      end
    end
  end

  for _ = 1, 16 do
    crack(rng:random(96, 224), rng:random(0, 170), pi / 2 + (rr() - 0.5) * 1.6, rng:random(24, 70), 0)
  end
  for _ = 1, 3 do
    crack(rng:random(96, 150), rng:random(20, 170), (rr() - 0.5) * 0.6, rng:random(30, 60), 0)
  end

  local image = love.graphics.newImage(data)
  image:setFilter("nearest", "nearest")
  data:release()
  return track(image)
end

local function buildBox()
  local w, h = BOX.w, BOX.h
  local rng = love.math.newRandomGenerator(77)
  local data = love.image.newImageData(w, h)
  local planks = { { 152, 100, 54 }, { 140, 90, 48 }, { 162, 108, 60 }, { 146, 94, 50 } }
  local frame = 4

  local function put(x, y, r, gg, b)
    data:setPixel(x, y, clamp(r, 0, 255) / 255, clamp(gg, 0, 255) / 255, clamp(b, 0, 255) / 255, 1)
  end

  for y = 0, h - 1 do
    for x = 0, w - 1 do
      local n = rng:random(-6, 6)
      local r, gg, b
      if x < frame or x >= w - frame or y < frame or y >= h - frame then
        r, gg, b = 104 + n, 66 + n, 34 + n
        if y == 0 or x == 0 then
          r, gg, b = 188, 138, 84
        elseif y == h - 1 or x == w - 1 then
          r, gg, b = 56, 34, 18
        end
      else
        local py = y - frame
        local c = planks[floor(py / 11) % #planks + 1]
        r, gg, b = c[1] + n, c[2] + n, c[3] + n
        if py % 11 == 10 then
          r, gg, b = 84, 52, 26
        elseif py % 11 == 0 then
          r, gg, b = r + 14, gg + 10, b + 6
        end
        if y == frame or x == frame then r, gg, b = 64, 40, 20 end
      end
      put(x, y, r, gg, b)
    end
  end

  for _ = 1, 46 do
    local sx, sy = rng:random(frame + 1, w - frame - 20), rng:random(frame + 1, h - frame - 2)
    for i = 0, rng:random(6, 18) do
      local x = sx + i
      if x < w - frame then
        local pr, pg, pb = data:getPixel(x, sy)
        data:setPixel(x, sy, pr * 0.88, pg * 0.88, pb * 0.88, 1)
      end
    end
  end

  for _ = 1, 3 do
    local kx, ky = rng:random(frame + 6, w - frame - 6), rng:random(frame + 5, h - frame - 5)
    for dy = -2, 2 do
      for dx = -2, 2 do
        local d = dx * dx + dy * dy
        if d <= 5 then
          if d >= 3 then put(kx + dx, ky + dy, 70, 42, 20) else put(kx + dx, ky + dy, 108, 68, 34) end
        end
      end
    end
  end

  local nails = { { 2, 2 }, { w - 3, 2 }, { 2, h - 3 }, { w - 3, h - 3 } }
  for i = 1, #nails do
    local nx, ny = nails[i][1], nails[i][2]
    put(nx, ny, 64, 64, 70)
    put(nx + 1, ny, 48, 48, 54)
    put(nx, ny + 1, 48, 48, 54)
    put(nx - 1, ny - 1, 150, 150, 160)
  end

  local image = love.graphics.newImage(data)
  image:setFilter("nearest", "nearest")
  data:release()
  return track(image)
end

local function loadAssets()
  for ch, bits in pairs(GLYPHS) do
    assert(#bits == 15, "malformed glyph '" .. ch .. "'")
    local data = love.image.newImageData(3, 5)
    for i = 0, 14 do
      if bits:sub(i + 1, i + 1) == "1" then data:setPixel(i % 3, floor(i / 3), 1, 1, 1, 1) end
    end
    local image = love.graphics.newImage(data)
    image:setFilter("nearest", "nearest")
    data:release()
    track(image)
    Assets.glyphs[ch:byte()] = image
    local lower = ch:lower()
    if lower ~= ch then Assets.glyphs[lower:byte()] = image end
  end

  Assets.sprites.zombieA = assert(buildSprite(concatRows(ZOMBIE_TOP, ZOMBIE_LEGS_A), PALETTE))
  Assets.sprites.zombieB = assert(buildSprite(concatRows(ZOMBIE_TOP, ZOMBIE_LEGS_B), PALETTE))
  Assets.sprites.glock = assert(buildSprite(GLOCK_ROWS, PALETTE))
  Assets.sprites.sandbag = assert(buildSprite(SANDBAG_ROWS, PALETTE))
  Assets.sprites.flare = assert(buildSprite(FLARE_ROWS, PALETTE))
  for i = 1, #FLASH_ROWS do
    Assets.flashes[i] = assert(buildSprite(FLASH_ROWS[i], PALETTE))
  end
  Assets.background = buildBackground()
  Assets.box = buildBox()
end

local function textWidth(str, scale)
  local n = #str
  if n == 0 then return 0 end
  return (n * 4 - 1) * scale
end

local function drawRun(str, x, y, scale)
  local glyphs = Assets.glyphs
  for i = 1, #str do
    local image = glyphs[str:byte(i)]
    if image then love.graphics.draw(image, x, y, 0, scale, scale) end
    x = x + 4 * scale
  end
end

local function drawText(str, x, y, scale, color, alpha, shadow)
  local a = alpha or 1
  if shadow then
    love.graphics.setColor(0, 0, 0, 0.55 * a)
    drawRun(str, x + scale, y + scale, scale)
  end
  setColor(color or COLOR.white, a)
  drawRun(str, x, y, scale)
end

local function drawTextCentered(str, cx, y, scale, color, alpha, shadow)
  drawText(str, floor(cx - textWidth(str, scale) / 2), y, scale, color, alpha, shadow)
end

local function drawTextRight(str, rx, y, scale, color, alpha, shadow)
  drawText(str, rx - textWidth(str, scale), y, scale, color, alpha, shadow)
end

local function drawSprite(sprite, x, y, rot, sx, sy, ox, oy)
  love.graphics.draw(sprite.image, snap(x), snap(y), rot or 0, sx or 1, sy or 1, ox or 0, oy or 0)
end

local function drawWeapon(def, x, y, angle, kick, alpha)
  local dirx = cos(angle)
  local flip = dirx >= 0 and 1 or -1
  local rot = angle + (dirx >= 0 and -kick or kick)
  love.graphics.setColor(1, 1, 1, alpha or 1)
  drawSprite(Assets.sprites[def.sprite], x, y, rot, 1, flip, 3, 2)
end

local function frameRect(x, y, w, h, color, alpha)
  setColor(color, alpha)
  love.graphics.rectangle("fill", x, y, w, 1)
  love.graphics.rectangle("fill", x, y + h - 1, w, 1)
  love.graphics.rectangle("fill", x, y, 1, h)
  love.graphics.rectangle("fill", x + w - 1, y, 1, h)
end

local function pickWeapon()
  local total = 0
  for i = 1, #WEAPON_LIST do total = total + WEAPON_LIST[i].weight end
  local roll = rnd() * total
  for i = 1, #WEAPON_LIST do
    roll = roll - WEAPON_LIST[i].weight
    if roll <= 0 then return WEAPON_LIST[i] end
  end
  return WEAPON_LIST[#WEAPON_LIST]
end

local Button = {}
Button.__index = Button

function Button.new(x, y, w, h, label, theme, scale)
  return setmetatable({ x = x, y = y, w = w, h = h, label = label, theme = theme, scale = scale or 1, enabled = true }, Button)
end

function Button:contains(px, py)
  return px >= self.x and px < self.x + self.w and py >= self.y and py < self.y + self.h
end

function Button:draw(mx, my, down)
  local enabled = self.enabled
  local hover = enabled and self:contains(mx, my)
  local pressed = hover and down
  local t = enabled and self.theme or DISABLED
  local face = (hover and t.hover) or t.face
  local x, y, w, h = self.x, self.y, self.w, self.h
  if pressed then y = y + 1 end
  setColor(COLOR.black, 0.9)
  love.graphics.rectangle("fill", x - 1, y - 1, w + 2, h + 2)
  setColor(face)
  love.graphics.rectangle("fill", x, y, w, h)
  setColor(pressed and t.dark or t.light)
  love.graphics.rectangle("fill", x, y, w, 1)
  love.graphics.rectangle("fill", x, y, 1, h)
  setColor(pressed and t.light or t.dark)
  love.graphics.rectangle("fill", x, y + h - 2, w, 2)
  love.graphics.rectangle("fill", x + w - 1, y, 1, h)
  local tw = textWidth(self.label, self.scale)
  local th = 5 * self.scale
  drawText(self.label, x + floor((w - tw) / 2), y + floor((h - th) / 2), self.scale, t.text)
end

local Turret = {}
Turret.__index = Turret

function Turret.new(def, slot)
  local rest = slot.side == "left" and 0 or pi
  return setmetatable({
    def = def,
    slot = slot,
    x = slot.cx,
    y = slot.cy - 2,
    angle = rest,
    rest = rest,
    cooldown = 0.25,
    recoil = 0,
    kick = 0,
    flash = 0,
  }, Turret)
end

function Turret:findTarget(zombies)
  local range2 = self.def.range * self.def.range
  local best
  local bestY = -math.huge
  for i = 1, #zombies do
    local z = zombies[i]
    if z.y > 2 then
      local dx, dy = z.x - self.x, z.y - self.y
      if dx * dx + dy * dy <= range2 and z.y > bestY then
        best, bestY = z, z.y
      end
    end
  end
  return best
end

function Turret:update(dt, world)
  local def = self.def
  self.cooldown = max(0, self.cooldown - dt)
  self.flash = max(0, self.flash - dt)
  self.recoil = max(0, self.recoil - 24 * dt)
  self.kick = max(0, self.kick - 2.4 * dt)
  local target
  if world.state == "wave" then target = self:findTarget(world.zombies) end
  if target then
    local dx, dy = target.x - self.x, target.y - self.y
    local dist = sqrt(dx * dx + dy * dy)
    local t = dist / def.bulletSpeed
    local desired = atan2(target.y + target.vy * t - self.y, target.x + target.vx * t - self.x)
    local diff = angleDiff(self.angle, desired)
    self.angle = self.angle + clamp(diff, -TURN_SPEED * dt, TURN_SPEED * dt)
    if self.cooldown <= 0 and abs(angleDiff(self.angle, desired)) < 0.1 then
      self.cooldown = def.cooldown * rndRange(0.9, 1.1)
      world:fire(self)
    end
  else
    local diff = angleDiff(self.angle, self.rest)
    self.angle = self.angle + clamp(diff, -3 * dt, 3 * dt)
  end
end

function Turret:draw()
  local def = self.def
  local dirx, diry = cos(self.angle), sin(self.angle)
  local px = self.x - dirx * self.recoil
  local py = self.y - diry * self.recoil
  drawWeapon(def, px, py, self.angle, self.kick, 1)
  if self.flash > 0 then
    local idx = clamp(floor((FLASH_TIME - self.flash) / (FLASH_TIME / 3)) + 1, 1, 3)
    local sprite = Assets.flashes[idx]
    love.graphics.setColor(1, 1, 1, 1)
    drawSprite(sprite, px + dirx * (def.muzzle + 2), py + diry * (def.muzzle + 2), self.angle, 1, 1, sprite.w / 2, sprite.h / 2)
  end
end

local function createSlots()
  local slots = {}
  local rows = { 44, 92, 140 }
  for i = 1, #rows do
    slots[#slots + 1] = { cx = 36, cy = rows[i], side = "left", turret = nil }
    slots[#slots + 1] = { cx = 284, cy = rows[i], side = "right", turret = nil }
  end
  return slots
end

local function slotContains(slot, x, y)
  local half = SLOT_SIZE / 2
  return x >= slot.cx - half and x < slot.cx + half and y >= slot.cy - half and y < slot.cy + half
end

local function byDepth(a, b)
  return a.y < b.y
end

local Game = {}
Game.__index = Game

function Game.new(interface)
  local self = setmetatable({}, Game)
  self.ui = interface
  self.slots = createSlots()
  self:reset()
  return self
end

function Game:reset()
  self.bullets = self.bullets or {}
  self.particles = self.particles or {}
  releaseAll(self.bullets, bulletPool)
  releaseAll(self.particles, particlePool)
  self.zombies, self.turrets, self.floaters = {}, {}, {}
  for i = 1, #self.slots do self.slots[i].turret = nil end
  self.state = "build"
  self.money = START_MONEY
  self.wave = 1
  self.life = MAX_LIFE
  self.hand = nil
  self.offer = nil
  self.rollResult = nil
  self.rolling = 0
  self.spawnQueue = 0
  self.spawnTimer = 0
  self.clock = 0
  self.overClock = 0
  self.shake = 0
  self.toast = nil
  self.banner = nil
  self.moneyFlash = 0
  self.moneyFlashColor = COLOR.white
  self.paused = false
end

function Game:notify(text)
  self.toast = { text = text, life = 1.8 }
end

function Game:addMoney(delta)
  self.money = self.money + delta
  self.moneyFlash = 0.4
  self.moneyFlashColor = delta >= 0 and COLOR.green or COLOR.red
end

function Game:addFloater(text, x, y, color)
  if #self.floaters >= MAX_FLOATERS then removeAt(self.floaters, 1) end
  self.floaters[#self.floaters + 1] = { text = text, x = x, y = y, life = 0.9, color = color }
end

function Game:emit(x, y, vx, vy, life, size, color, gravity, floorY)
  if #self.particles >= MAX_PARTICLES then return end
  local p = particlePool.acquire()
  p.x, p.y, p.vx, p.vy = x, y, vx, vy
  p.life, p.max, p.size = life, life, size
  p.color, p.grav, p.floorY = color, gravity, floorY
  self.particles[#self.particles + 1] = p
end

function Game:burst(x, y, count, speed, floorY)
  for _ = 1, count do
    local a = rndRange(0, 2 * pi)
    local s = rndRange(0.3, 1) * speed
    self:emit(x, y, cos(a) * s, sin(a) * s - 20, rndRange(0.35, 0.8), rndInt(1, 2), BLOOD[rndInt(1, #BLOOD)], 180, floorY)
  end
end

function Game:hint()
  if self.state ~= "build" then return nil end
  if self.hand then return "CLICK A SAND SLOT TO PLACE" end
  if self.rolling > 0 then return "ROLLING..." end
  if self.offer then
    if self.money >= self.offer.cost then return "BUY IT OR ROLL AGAIN" end
    return "TOO EXPENSIVE - ROLL AGAIN"
  end
  if #self.turrets == 0 then return "ROLL THE LUCKY BOX" end
  return "READY? START THE WAVE"
end

function Game:syncUi()
  local interface = self.ui
  local build = self.state == "build"
  interface.start.enabled = build and #self.turrets > 0 and self.hand == nil
  interface.roll.enabled = build and self.rolling <= 0 and self.hand == nil
  interface.buy.enabled = build and self.offer ~= nil and self.hand == nil and self.money >= self.offer.cost
end

function Game:roll()
  if self.state ~= "build" or self.rolling > 0 then return end
  if self.hand then
    self:notify("PLACE YOUR WEAPON FIRST")
    return
  end
  self.offer = nil
  self.rollResult = pickWeapon()
  self.rolling = ROLL_TIME
end

function Game:buy()
  local offer = self.offer
  if self.state ~= "build" or not offer or self.hand then return end
  if self.money < offer.cost then
    self:notify("NOT ENOUGH MONEY")
    return
  end
  self:addMoney(-offer.cost)
  self.hand = offer
  self.offer = nil
  self:notify("CLICK A SAND SLOT")
end

function Game:cancelHand()
  if self.state ~= "build" or not self.hand then return false end
  self:addMoney(self.hand.cost)
  self.hand = nil
  self:notify("REFUNDED")
  return true
end

function Game:useSlot(slot)
  if self.hand then
    if slot.turret then
      self:notify("SLOT TAKEN")
      return
    end
    local turret = Turret.new(self.hand, slot)
    slot.turret = turret
    self.turrets[#self.turrets + 1] = turret
    self.hand = nil
  elseif slot.turret then
    self.hand = slot.turret.def
    removeValue(self.turrets, slot.turret)
    slot.turret = nil
  end
end

function Game:startWave()
  if self.state ~= "build" then return end
  if self.hand then
    self:notify("PLACE YOUR WEAPON FIRST")
    return
  end
  if #self.turrets == 0 then
    self:notify("PLACE A WEAPON FIRST")
    return
  end
  self.state = "wave"
  self.spawnQueue = WAVE.count(self.wave)
  self.spawnTimer = 1.2
  self.banner = { text = bannerLabel(self.wave), life = 1.6, max = 1.6, scale = 4, color = COLOR.white }
end

function Game:finishWave()
  local bonus = WAVE.bonus(self.wave)
  self:addMoney(bonus)
  self:addFloater(bonusLabel(bonus), 160, 110, COLOR.gold)
  self.banner = { text = "WAVE CLEARED", life = 2, max = 2, scale = 3, color = COLOR.green }
  self.wave = self.wave + 1
  self.state = "build"
end

function Game:click(x, y, button)
  if self.state == "over" then
    if self.overClock > 0.7 then self:reset() end
    return
  end
  if button == 2 then
    self:cancelHand()
    return
  end
  if button ~= 1 or self.state ~= "build" then return end
  local interface = self.ui
  if interface.start:contains(x, y) then
    self:startWave()
    return
  end
  if interface.roll:contains(x, y) then
    self:roll()
    return
  end
  if interface.buy:contains(x, y) then
    self:buy()
    return
  end
  for i = 1, #self.slots do
    if slotContains(self.slots[i], x, y) then
      self:useSlot(self.slots[i])
      return
    end
  end
end

function Game:spawnZombie()
  local w = self.wave
  local hp = WAVE.health(w)
  self.zombies[#self.zombies + 1] = {
    x = rndRange(ROAD.left + 14, ROAD.right - 14),
    y = -10,
    vx = 0,
    vy = 0,
    hp = hp,
    maxHp = hp,
    speed = WAVE.speed(w) * rndRange(0.8, 1.25),
    t = rndRange(0, 6),
    phase = rndRange(0, 6.28),
    freq = rndRange(0.8, 2),
    amp = rndRange(3, 10),
    flash = 0,
    frame = 1,
  }
end

function Game:updateSpawning(dt)
  if self.spawnQueue <= 0 then return end
  self.spawnTimer = self.spawnTimer - dt
  if self.spawnTimer <= 0 then
    self:spawnZombie()
    self.spawnQueue = self.spawnQueue - 1
    self.spawnTimer = WAVE.interval(self.wave) * rndRange(0.6, 1.4)
  end
end

function Game:damageBox()
  self.life = self.life - 1
  self.shake = 0.3
  self:addFloater("-1 HP", rndRange(110, 210), ROAD.bottom - 6, COLOR.red)
  for _ = 1, 6 do
    self:emit(rndRange(110, 210), BOX.y, rndRange(-30, 30), rndRange(-60, -20), rndRange(0.3, 0.6), 2, { 150, 100, 54 }, 200, BOX.y + 4)
  end
  if self.life <= 0 then
    self.life = 0
    self.state = "over"
    self.overClock = 0
    self.banner = nil
    self.toast = nil
  end
end

function Game:updateZombies(dt)
  local zs = self.zombies
  for i = #zs, 1, -1 do
    local z = zs[i]
    z.t = z.t + dt
    z.vx = cos(z.t * z.freq + z.phase) * z.amp
    z.vy = z.speed
    z.x = clamp(z.x + z.vx * dt, ROAD.left + 10, ROAD.right - 10)
    z.y = z.y + z.vy * dt
    z.flash = max(0, z.flash - dt)
    z.frame = floor(z.t * 3.2) % 2 + 1
    if z.y >= ROAD.bottom - 4 then
      removeAt(zs, i)
      self:damageBox()
    end
  end
end

function Game:hitZombie(z, damage, x, y)
  z.hp = z.hp - damage
  z.flash = 0.08
  self:burst(x, y, 4, 60, z.y + 7)
  if z.hp <= 0 then
    removeValue(self.zombies, z)
    self:burst(z.x, z.y, 12, 90, z.y + 7)
    self:addMoney(BOUNTY)
    self:addFloater(bonusLabel(BOUNTY), z.x, z.y - 8, COLOR.gold)
  end
end

function Game:fire(turret)
  local def = turret.def
  local a = turret.angle + rndRange(-def.spread, def.spread)
  local dx, dy = cos(a), sin(a)
  local b = bulletPool.acquire()
  b.x = turret.x + dx * (def.muzzle + 2)
  b.y = turret.y + dy * (def.muzzle + 2)
  b.dx, b.dy, b.angle = dx, dy, a
  b.speed = def.bulletSpeed
  b.damage = def.damage
  b.dist = 0
  b.maxDist = def.range * 1.6
  self.bullets[#self.bullets + 1] = b
  turret.recoil = def.recoil
  turret.kick = def.kick
  turret.flash = FLASH_TIME
  local side = dx >= 0 and -1 or 1
  self:emit(turret.x, turret.y, side * rndRange(10, 40), rndRange(-80, -50), 0.7, 1, BRASS, 260, turret.y + 10)
end

function Game:stepBullet(b, dt)
  local step = b.speed * dt
  local n = max(1, ceil(step / 3))
  local sub = step / n
  local zs = self.zombies
  for _ = 1, n do
    b.x = b.x + b.dx * sub
    b.y = b.y + b.dy * sub
    b.dist = b.dist + sub
    for j = 1, #zs do
      local z = zs[j]
      if abs(b.x - z.x) <= 5 and abs(b.y - z.y) <= 7 then
        self:hitZombie(z, b.damage, b.x, b.y)
        return true
      end
    end
  end
  return b.dist > b.maxDist or b.x < -8 or b.x > VW + 8 or b.y < -16 or b.y > VH + 8
end

function Game:updateBullets(dt)
  local list = self.bullets
  for i = #list, 1, -1 do
    local b = list[i]
    if self:stepBullet(b, dt) then
      removeAt(list, i)
      bulletPool.release(b)
    end
  end
end

function Game:updateParticles(dt)
  local list = self.particles
  for i = #list, 1, -1 do
    local p = list[i]
    p.life = p.life - dt
    if p.life <= 0 then
      removeAt(list, i)
      particlePool.release(p)
    else
      p.vy = p.vy + p.grav * dt
      p.x = p.x + p.vx * dt
      p.y = p.y + p.vy * dt
      if p.floorY and p.y > p.floorY then
        p.y = p.floorY
        p.vy = -p.vy * 0.3
        p.vx = p.vx * 0.5
      end
    end
  end
end

function Game:updateFloaters(dt)
  local list = self.floaters
  for i = #list, 1, -1 do
    local f = list[i]
    f.life = f.life - dt
    f.y = f.y - 14 * dt
    if f.life <= 0 then removeAt(list, i) end
  end
end

function Game:update(dt)
  self.clock = self.clock + dt
  self.shake = max(0, self.shake - dt)
  self.moneyFlash = max(0, self.moneyFlash - dt)
  if self.toast then
    self.toast.life = self.toast.life - dt
    if self.toast.life <= 0 then self.toast = nil end
  end
  if self.banner then
    self.banner.life = self.banner.life - dt
    if self.banner.life <= 0 then self.banner = nil end
  end

  if self.state == "over" then
    self.overClock = self.overClock + dt
    self:updateParticles(dt)
    self:updateFloaters(dt)
    return
  end

  if self.rolling > 0 then
    self.rolling = self.rolling - dt
    if self.rolling <= 0 then
      self.rolling = 0
      self.offer = self.rollResult
      self.rollResult = nil
    end
  end

  if self.state == "wave" then
    self:updateSpawning(dt)
    self:updateZombies(dt)
  end
  for i = 1, #self.turrets do self.turrets[i]:update(dt, self) end
  self:updateBullets(dt)
  self:updateParticles(dt)
  self:updateFloaters(dt)

  if self.state == "wave" and self.spawnQueue == 0 and #self.zombies == 0 then
    self:finishWave()
  end
  self:syncUi()
end

function Game:drawSlots(mx, my)
  local build = self.state == "build"
  local holding = build and self.hand ~= nil
  local half = SLOT_SIZE / 2
  for i = 1, #self.slots do
    local s = self.slots[i]
    local x, y = s.cx - half, s.cy - half
    local hover = build and slotContains(s, mx, my)
    setColor(hover and COLOR.slotHover or COLOR.slot)
    love.graphics.rectangle("fill", x, y, SLOT_SIZE, SLOT_SIZE)
    frameRect(x, y, SLOT_SIZE, SLOT_SIZE, COLOR.slotEdge)
    if holding and not s.turret then
      local pulse = 0.5 + 0.5 * sin(self.clock * 6)
      frameRect(x - 1, y - 1, SLOT_SIZE + 2, SLOT_SIZE + 2, COLOR.hilite, 0.4 + 0.5 * pulse)
      if hover then
        local angle = s.side == "left" and 0 or pi
        drawWeapon(self.hand, s.cx, s.cy - 2, angle, 0, 0.55)
      end
    end
    if s.turret then
      love.graphics.setColor(1, 1, 1, 1)
      drawSprite(Assets.sprites.sandbag, s.cx - 9, s.cy + 4)
    end
  end
  love.graphics.setColor(1, 1, 1, 1)
end

function Game:drawZombies()
  local zs = self.zombies
  sort(zs, byDepth)
  for i = 1, #zs do
    local z = zs[i]
    setColor(COLOR.black, 0.25)
    love.graphics.rectangle("fill", snap(z.x) - 4, snap(z.y) + 6, 8, 2)
    if z.flash > 0 then
      love.graphics.setColor(1, 0.55, 0.55, 1)
    else
      love.graphics.setColor(1, 1, 1, 1)
    end
    local sprite = z.frame == 1 and Assets.sprites.zombieA or Assets.sprites.zombieB
    drawSprite(sprite, z.x, z.y, 0, 1, 1, 5, 7)
    if z.hp < z.maxHp then
      local bx, by = snap(z.x) - 5, snap(z.y) - 10
      setColor(COLOR.black, 0.8)
      love.graphics.rectangle("fill", bx - 1, by - 1, 12, 3)
      setColor(COLOR.hpBad)
      love.graphics.rectangle("fill", bx, by, 10, 1)
      setColor(COLOR.hpGood)
      love.graphics.rectangle("fill", bx, by, max(1, floor(10 * z.hp / z.maxHp)), 1)
    end
  end
  love.graphics.setColor(1, 1, 1, 1)
end

function Game:drawBullets()
  local flare = Assets.sprites.flare
  for i = 1, #self.bullets do
    local b = self.bullets[i]
    love.graphics.setColor(1, 0.8, 0.3, 0.4)
    love.graphics.draw(flare.image, snap(b.x - b.dx * 4), snap(b.y - b.dy * 4), b.angle, 1, 1, 3, 1.5)
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.draw(flare.image, snap(b.x), snap(b.y), b.angle, 1, 1, 3, 1.5)
  end
end

function Game:drawParticles()
  for i = 1, #self.particles do
    local p = self.particles[i]
    setColor(p.color, clamp(p.life / p.max * 1.6, 0, 1))
    love.graphics.rectangle("fill", snap(p.x), snap(p.y), p.size, p.size)
  end
  love.graphics.setColor(1, 1, 1, 1)
end

function Game:drawFloaters()
  for i = 1, #self.floaters do
    local f = self.floaters[i]
    drawTextCentered(f.text, f.x, snap(f.y), 1, f.color, min(1, f.life * 2.5), true)
  end
  love.graphics.setColor(1, 1, 1, 1)
end

function Game:drawBox(mx, my, down)
  setColor(COLOR.black, 0.25)
  love.graphics.rectangle("fill", BOX.x + 1, BOX.y - 3, BOX.w, 3)
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.draw(Assets.box, BOX.x, BOX.y)
  drawTextCentered("LUCKY BOX", 64, 196, 1, COLOR.burn)

  self.ui.roll:draw(mx, my, down)
  self.ui.buy:draw(mx, my, down)

  local px, py, pw, ph = 106, 201, 76, 32
  local cx = px + pw / 2
  setColor(COLOR.panelEdge)
  love.graphics.rectangle("fill", px - 1, py - 1, pw + 2, ph + 2)
  setColor(COLOR.panel)
  love.graphics.rectangle("fill", px, py, pw, ph)

  if self.state == "wave" then
    drawTextCentered("DEFEND", cx, py + 8, 1, COLOR.red)
    drawTextCentered("THE BOX!", cx, py + 17, 1, COLOR.gray)
  elseif self.rolling > 0 then
    local weapon = WEAPON_LIST[floor(self.clock * 10) % #WEAPON_LIST + 1]
    if floor(self.clock * 12) % 2 == 0 then
      love.graphics.setColor(1, 1, 1, 1)
      drawSprite(Assets.sprites[weapon.sprite], cx - 12, py + 6, 0, 2, 2)
    else
      drawTextCentered("?", cx, py + 6, 3, COLOR.gold)
    end
    drawTextCentered("ROLLING", cx, py + ph - 8, 1, COLOR.gray)
  elseif self.offer then
    love.graphics.setColor(1, 1, 1, 1)
    drawSprite(Assets.sprites[self.offer.sprite], px + 6, py + 9, 0, 2, 2)
    drawText(self.offer.name, px + 36, py + 9, 1, COLOR.white)
    drawText(moneyLabel(self.offer.cost), px + 36, py + 18, 1, self.money >= self.offer.cost and COLOR.gold or COLOR.red)
  elseif self.hand then
    drawTextCentered("PLACE IT", cx, py + 8, 1, COLOR.gold)
    drawTextCentered("ON SAND", cx, py + 17, 1, COLOR.gold)
  else
    drawTextCentered("ROLL IS", cx, py + 8, 1, COLOR.gray)
    drawTextCentered("FREE!", cx, py + 17, 1, COLOR.green)
  end
end

function Game:drawMoney()
  local x, y, w, h = 244, 205, 72, 30
  setColor(COLOR.black, 0.9)
  love.graphics.rectangle("fill", x - 1, y - 1, w + 2, h + 2)
  setColor(COLOR.plate)
  love.graphics.rectangle("fill", x, y, w, h)
  setColor(COLOR.plateLight)
  love.graphics.rectangle("fill", x, y, w, 1)
  love.graphics.rectangle("fill", x, y, 1, h)
  drawText("CASH", x + 5, y + 4, 1, COLOR.gray)
  local text = moneyLabel(self.money)
  local scale = textWidth(text, 3) <= w - 10 and 3 or 2
  local color = self.moneyFlash > 0 and self.moneyFlashColor or COLOR.gold
  drawText(text, x + 5, y + 12 + (3 - scale) * 2, scale, color, 1, true)
end

function Game:drawHud()
  drawText(waveLabel(self.wave), 6, 6, 2, COLOR.white, 1, true)
  local hpColor = self.life <= 3 and COLOR.red or COLOR.white
  drawTextRight(lifeLabel(self.life), VW - 6, 6, 2, hpColor, 1, true)
  if self.state == "wave" then
    drawTextCentered(zombieLabel(self.spawnQueue + #self.zombies), 160, 8, 1, COLOR.white, 1, true)
  else
    local hint = self:hint()
    if hint then drawTextCentered(hint, 160, 8, 1, COLOR.white, 1, true) end
  end
end

function Game:drawOverlays(mx, my)
  if self.banner then
    local b = self.banner
    drawTextCentered(b.text, 160, 66, b.scale, b.color, clamp(b.life / 0.5, 0, 1), true)
  end
  if self.toast then
    local t = self.toast
    local tw = textWidth(t.text, 1)
    local a = clamp(t.life / 0.4, 0, 1)
    setColor(COLOR.black, 0.65 * a)
    love.graphics.rectangle("fill", floor(160 - tw / 2) - 4, 22, tw + 8, 11)
    drawTextCentered(t.text, 160, 25, 1, COLOR.white, a)
  end
  if self.hand and self.state == "build" then
    love.graphics.setColor(1, 1, 1, 0.9)
    drawSprite(Assets.sprites[self.hand.sprite], mx, my, 0, 2, 2, 6, 3)
  end
  if self.state == "over" then
    setColor(COLOR.black, 0.6)
    love.graphics.rectangle("fill", 0, 0, VW, VH)
    drawTextCentered("GAME OVER", 160, 78, 5, COLOR.red, 1, true)
    drawTextCentered(clearedLabel(self.wave - 1), 160, 124, 2, COLOR.white, 1, true)
    if self.overClock > 0.7 and floor(self.clock * 2) % 2 == 0 then
      drawTextCentered("CLICK TO RESTART", 160, 150, 2, COLOR.gold, 1, true)
    end
  end
  if self.paused then
    setColor(COLOR.black, 0.55)
    love.graphics.rectangle("fill", 0, 0, VW, VH)
    drawTextCentered("PAUSED", 160, 108, 4, COLOR.white, 1, true)
  end
  love.graphics.setColor(1, 1, 1, 1)
end

function Game:draw(mx, my, down)
  local sx, sy = 0, 0
  if self.shake > 0 then sx, sy = rndInt(-1, 1), rndInt(-1, 1) end
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.push()
  love.graphics.translate(sx, sy)
  love.graphics.draw(Assets.background, 0, 0)
  self:drawSlots(mx, my)
  for i = 1, #self.turrets do self.turrets[i]:draw() end
  self:drawZombies()
  self:drawBullets()
  self:drawParticles()
  self:drawFloaters()
  love.graphics.pop()

  self:drawBox(mx, my, down)
  self:drawMoney()
  self:drawHud()
  if self.state == "build" then self.ui.start:draw(mx, my, down) end
  self:drawOverlays(mx, my)
end

local function computeViewport()
  local w, h = love.graphics.getDimensions()
  local s = min(w / VW, h / VH)
  if s >= 1 then s = floor(s) end
  view.scale = s
  view.x = floor((w - VW * s) / 2)
  view.y = floor((h - VH * s) / 2)
end

local function toVirtual(x, y)
  return (x - view.x) / view.scale, (y - view.y) / view.scale
end

local function initialise()
  local ok = love.window.setMode(960, 720, { resizable = true, minwidth = VW, minheight = VH, vsync = 1 })
  if not ok then error("could not create the game window") end
  love.window.setTitle("Zombie Rush")
  love.graphics.setDefaultFilter("nearest", "nearest", 1)
  love.graphics.setLineStyle("rough")
  love.graphics.setLineWidth(1)
  loadAssets()
  canvas = track(love.graphics.newCanvas(VW, VH))
  canvas:setFilter("nearest", "nearest")
  ui = {
    start = Button.new(110, 96, 100, 22, "START WAVE", THEME.red, 2),
    roll = Button.new(32, 204, 64, 26, "ROLL", THEME.green, 2),
    buy = Button.new(186, 204, 40, 26, "BUY", THEME.gold, 2),
  }
  game = Game.new(ui)
  computeViewport()
end

local function drawFatal()
  love.graphics.setCanvas()
  love.graphics.clear(0.1, 0.02, 0.02, 1)
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.printf("An error occurred:\n\n" .. tostring(fatalError) .. "\n\nPress ESC to quit.", 20, 20, love.graphics.getWidth() - 40)
end

function love.load()
  local ok, err = pcall(initialise)
  if not ok then fatalError = tostring(err) end
end

function love.resize()
  if not fatalError then computeViewport() end
end

function love.focus(focused)
  windowFocused = focused
end

function love.update(dt)
  if fatalError or not game then return end
  dt = min(dt, 1 / 30)
  game.paused = not windowFocused
  if game.paused then return end
  local ok, err = pcall(game.update, game, dt)
  if not ok then fatalError = tostring(err) end
end

function love.draw()
  if fatalError or not game then
    if fatalError then drawFatal() end
    return
  end
  local mx, my = toVirtual(love.mouse.getPosition())
  love.graphics.setCanvas(canvas)
  love.graphics.clear(0, 0, 0, 1)
  local ok, err = pcall(game.draw, game, mx, my, love.mouse.isDown(1))
  love.graphics.setCanvas()
  if not ok then
    fatalError = tostring(err)
    drawFatal()
    return
  end
  love.graphics.clear(0.05, 0.05, 0.06, 1)
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.setBlendMode("alpha", "premultiplied")
  love.graphics.draw(canvas, view.x, view.y, 0, view.scale, view.scale)
  love.graphics.setBlendMode("alpha", "alphamultiply")
end

function love.mousepressed(x, y, button)
  if fatalError or not game then return end
  local vx, vy = toVirtual(x, y)
  local ok, err = pcall(game.click, game, vx, vy, button)
  if not ok then fatalError = tostring(err) end
end

function love.keypressed(key)
  if key == "f11" then
    love.window.setFullscreen(not love.window.getFullscreen())
    return
  end
  if fatalError or not game then
    if key == "escape" then love.event.quit() end
    return
  end
  if key == "escape" then
    if not game:cancelHand() then love.event.quit() end
  elseif key == "space" or key == "return" then
    game:startWave()
  elseif key == "r" and game.state == "over" and game.overClock > 0.7 then
    game:reset()
  end
end

function love.quit()
  for i = #Assets.owned, 1, -1 do
    local resource = Assets.owned[i]
    if resource and resource.release then pcall(resource.release, resource) end
    Assets.owned[i] = nil
  end
  if canvas then
    pcall(canvas.release, canvas)
    canvas = nil
  end
  return false
end