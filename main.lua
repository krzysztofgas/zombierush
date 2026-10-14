local lg, lm, lf, lw = love.graphics, love.math, love.filesystem, love.window
local floor, ceil, min, max, abs, sqrt = math.floor, math.ceil, math.min, math.max, math.abs, math.sqrt
local sin, cos, pi, huge = math.sin, math.cos, math.pi, math.huge
local atan2 = math.atan2 or math.atan
local concat, format = table.concat, string.format
local TAU = pi * 2

local VW, MIN_VH, PANEL_H, TOP_H = 384, 256, 60, 14
local WORLD_W, WORLD_H = 384, 470
local ROAD_L, ROAD_R = 120, 264
local ROAD_C = (ROAD_L + ROAD_R) / 2
local BANK = 22
local BARRICADE_Y = 436
local SLOT_ROWS, SLOT_TOP, SLOT_GAP, SLOT_R = 10, 34, 40, 13
local SLOT_X = { 66, 318 }
local MAX_VH = WORLD_H + PANEL_H
local START_MONEY, KILL_REWARD, MAX_LIFE, MAX_LEVEL, SELL_RATE = 50, 1, 20, 3, 0.5
local ROLL_TIME, FLASH_TIME, DECAL_LIFE = 1.1, 0.08, 45
local FIXED_DT, MAX_STEPS = 1 / 60, 8
local MAX_ZOMBIES, MAX_BULLETS, MAX_PARTICLES, MAX_DECALS, MAX_FLOATERS = 400, 600, 700, 220, 48
local POOL_LIMIT, BUCKET = 512, 32
local SAVE_RUN, SAVE_META, SAVE_VERSION, MAX_SAVE_BYTES = "run.dat", "meta.dat", 2, 65536
local SCROLL_SPEED = 260

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

local function snap(v)
  return floor(v + 0.5)
end

local function angleDiff(a, b)
  return (b - a + pi) % TAU - pi
end

local function rnd(a, b)
  return a + (b - a) * lm.random()
end

local function rndInt(a, b)
  return lm.random(a, b)
end

local function rgb(r, g, b)
  return { r / 255, g / 255, b / 255 }
end

local function setColor(c, a)
  lg.setColor(c[1], c[2], c[3], a or 1)
end

local function swapRemove(list, i)
  local n = #list
  list[i] = list[n]
  list[n] = nil
end

local function removeValue(list, value)
  for i = #list, 1, -1 do
    if list[i] == value then
      swapRemove(list, i)
      return true
    end
  end
  return false
end

local function int(n)
  return format("%.0f", n)
end

local function num(v, lo, hi, default)
  local n = tonumber(v)
  if not n or n ~= n or n == huge or n == -huge then return default end
  return clamp(floor(n), lo, hi)
end

local function checksum(s)
  local h = 5381
  for i = 1, #s do
    h = (h * 33 + s:byte(i)) % 2147483647
  end
  return h
end

local function newPool(limit)
  local free, count = {}, 0
  local pool = {}
  function pool.get()
    if count > 0 then
      local item = free[count]
      free[count] = nil
      count = count - 1
      return item
    end
    return {}
  end
  function pool.put(item)
    if count < limit then
      count = count + 1
      free[count] = item
    end
  end
  function pool.clear()
    for i = count, 1, -1 do free[i] = nil end
    count = 0
  end
  return pool
end

local function labeler(prefix, suffix)
  local memo, n = {}, 0
  suffix = suffix or ""
  return function(v)
    local s = memo[v]
    if not s then
      if n >= 256 then
        memo, n = {}, 0
      end
      s = prefix .. tostring(v) .. suffix
      memo[v] = s
      n = n + 1
    end
    return s
  end
end

local L = {
  money = labeler("$"),
  plus = labeler("+$"),
  wave = labeler("WAVE "),
  num = labeler(""),
  left = labeler("", " LEFT"),
  upgrade = labeler("UPGRADE $"),
  sell = labeler("SELL +$"),
  reached = labeler("REACHED WAVE "),
  best = labeler("BEST WAVE "),
  kills = labeler("KILLS "),
  total = labeler("TOTAL KILLS "),
  cleared = labeler("WAVE ", " CLEARED"),
  level = labeler("LV"),
  levelUp = labeler("LEVEL ", "!"),
  hurt = labeler("-", " HP"),
}

local zombiePool, bulletPool = newPool(POOL_LIMIT), newPool(POOL_LIMIT)
local particlePool, floaterPool = newPool(POOL_LIMIT), newPool(64)

local C = {
  white = rgb(255, 255, 255), black = rgb(0, 0, 0), cream = rgb(246, 232, 196),
  gold = rgb(255, 208, 64), red = rgb(236, 72, 60), green = rgb(118, 220, 100),
  gray = rgb(180, 180, 190), dim = rgb(112, 112, 124),
  panel = rgb(14, 16, 20), panelEdge = rgb(36, 24, 14),
  ground = rgb(46, 34, 24), groundHi = rgb(98, 72, 46), groundLo = rgb(24, 16, 10),
  plate = rgb(62, 40, 22), plateHi = rgb(140, 96, 52), plateLo = rgb(30, 18, 10),
  burn = rgb(66, 38, 16), hudBg = rgb(16, 14, 18), hudEdge = rgb(70, 52, 34),
  hp = rgb(220, 56, 46), hpHi = rgb(255, 128, 104), hpBack = rgb(54, 18, 20),
  prog = rgb(170, 44, 38), progBack = rgb(38, 18, 18),
  ring = rgb(255, 238, 150), letterbox = rgb(10, 9, 12),
  mapSand = rgb(176, 146, 98), mapRoad = rgb(70, 70, 78), barHp = rgb(96, 204, 80), barBack = rgb(120, 30, 30),
}
local BLOOD = { rgb(178, 24, 26), rgb(214, 42, 36), rgb(120, 14, 18) }
local DUST = { rgb(214, 186, 130), rgb(190, 160, 108), rgb(234, 212, 162) }
local WOOD = { rgb(178, 122, 68), rgb(124, 82, 44), rgb(220, 170, 108) }
local SPARK = { rgb(255, 236, 140), rgb(255, 200, 70), rgb(255, 255, 220) }
local BRASS = rgb(236, 190, 70)
local GLOW = rgb(255, 170, 60)

local THEME = {
  green = { face = rgb(84, 168, 70), hover = rgb(112, 200, 90), light = rgb(170, 236, 140), dark = rgb(40, 92, 36), text = rgb(14, 38, 10) },
  gold = { face = rgb(224, 176, 42), hover = rgb(250, 204, 70), light = rgb(255, 240, 150), dark = rgb(136, 96, 18), text = rgb(50, 30, 4) },
  red = { face = rgb(194, 58, 48), hover = rgb(226, 84, 68), light = rgb(255, 150, 128), dark = rgb(104, 26, 22), text = rgb(255, 242, 232) },
  steel = { face = rgb(92, 98, 112), hover = rgb(118, 126, 142), light = rgb(170, 178, 194), dark = rgb(46, 50, 60), text = rgb(236, 240, 248) },
}
local DISABLED = { face = rgb(80, 76, 72), light = rgb(112, 108, 102), dark = rgb(50, 48, 46), text = rgb(140, 136, 128) }
DISABLED.hover = DISABLED.face

local RARITY = {
  { name = "COMMON", color = rgb(196, 196, 206) },
  { name = "UNCOMMON", color = rgb(118, 220, 100) },
  { name = "RARE", color = rgb(96, 166, 255) },
  { name = "EPIC", color = rgb(224, 116, 255) },
}

local WEAPONS = {
  { id = "glock", name = "GLOCK", sprite = "glock", cost = 25, weight = 55, rarity = 1, damage = 1, cooldown = 0.42, range = 150, speed = 340, pellets = 1, spread = 0.04, pierce = 1, recoil = 2, kick = 0.3, muzzle = 8, pivotX = 4, pivotY = 3 },
  { id = "uzi", name = "UZI", sprite = "uzi", cost = 60, weight = 27, rarity = 2, damage = 0.7, cooldown = 0.11, range = 130, speed = 360, pellets = 1, spread = 0.13, pierce = 1, recoil = 1, kick = 0.1, muzzle = 8, pivotX = 5, pivotY = 3 },
  { id = "shotgun", name = "SHOTGUN", sprite = "shotgun", cost = 90, weight = 13, rarity = 3, damage = 1, cooldown = 0.95, range = 105, speed = 320, pellets = 6, spread = 0.3, pierce = 1, recoil = 4, kick = 0.45, muzzle = 12, pivotX = 6, pivotY = 2 },
  { id = "rifle", name = "RIFLE", sprite = "rifle", cost = 150, weight = 5, rarity = 4, damage = 7, cooldown = 1.35, range = 270, speed = 560, pellets = 1, spread = 0.004, pierce = 3, recoil = 4, kick = 0.22, muzzle = 14, pivotX = 8, pivotY = 3 },
}
local WEAPON_BY_ID = {}
for i = 1, #WEAPONS do
  WEAPONS[i].index = i
  WEAPON_BY_ID[WEAPONS[i].id] = WEAPONS[i]
end

local ZTYPES = {
  walker = { a = "walkerA", b = "walkerB", shadow = "shadowS", hp = 1, speed = 1, damage = 1, sway = 1, w = 12, h = 16, hitW = 5, hitH = 7 },
  runner = { a = "runnerA", b = "runnerB", shadow = "shadowS", hp = 0.6, speed = 1.75, damage = 1, sway = 0.5, w = 12, h = 16, hitW = 5, hitH = 7 },
  brute = { a = "bruteA", b = "bruteB", shadow = "shadowL", hp = 3.5, speed = 0.6, damage = 3, sway = 0.4, w = 16, h = 18, hitW = 7, hitH = 8 },
}

local function waveCount(n) return 6 + (n - 1) * 3 end
local function waveInterval(n) return max(0.25, 1.5 - n * 0.07) end
local function waveHp(n) return 2 + n * 0.6 end
local function waveSpeed(n) return min(42, 15 + n * 1.1) end
local function waveBonus(n) return 15 + n * 5 end

local function pickZombieType(n)
  local r = lm.random()
  local brute = 0
  if n >= 5 then brute = min(0.22, 0.03 * (n - 4)) * ((n % 5 == 0) and 2 or 1) end
  local runner = n >= 3 and min(0.35, 0.05 * (n - 2)) or 0
  if r < brute then return ZTYPES.brute end
  if r < brute + runner then return ZTYPES.runner end
  return ZTYPES.walker
end

local function pickWeapon()
  local total = 0
  for i = 1, #WEAPONS do total = total + WEAPONS[i].weight end
  local roll = lm.random() * total
  for i = 1, #WEAPONS do
    roll = roll - WEAPONS[i].weight
    if roll <= 0 then return WEAPONS[i] end
  end
  return WEAPONS[#WEAPONS]
end

local function g(...)
  return concat({ ... })
end

local GLYPHS = {
  [" "] = g("000", "000", "000", "000", "000"),
  A = g("010", "101", "111", "101", "101"), B = g("110", "101", "110", "101", "110"),
  C = g("011", "100", "100", "100", "011"), D = g("110", "101", "101", "101", "110"),
  E = g("111", "100", "110", "100", "111"), F = g("111", "100", "110", "100", "100"),
  G = g("011", "100", "101", "101", "011"), H = g("101", "101", "111", "101", "101"),
  I = g("111", "010", "010", "010", "111"), J = g("001", "001", "001", "101", "010"),
  K = g("101", "101", "110", "101", "101"), L = g("100", "100", "100", "100", "111"),
  M = g("101", "111", "111", "101", "101"), N = g("110", "101", "101", "101", "101"),
  O = g("010", "101", "101", "101", "010"), P = g("110", "101", "110", "100", "100"),
  Q = g("010", "101", "101", "111", "011"), R = g("110", "101", "110", "101", "101"),
  S = g("011", "100", "010", "001", "110"), T = g("111", "010", "010", "010", "010"),
  U = g("101", "101", "101", "101", "111"), V = g("101", "101", "101", "101", "010"),
  W = g("101", "101", "111", "111", "101"), X = g("101", "101", "010", "101", "101"),
  Y = g("101", "101", "010", "010", "010"), Z = g("111", "001", "010", "100", "111"),
  ["0"] = g("111", "101", "101", "101", "111"), ["1"] = g("010", "110", "010", "010", "111"),
  ["2"] = g("110", "001", "010", "100", "111"), ["3"] = g("110", "001", "010", "001", "110"),
  ["4"] = g("101", "101", "111", "001", "001"), ["5"] = g("111", "100", "110", "001", "110"),
  ["6"] = g("011", "100", "111", "101", "111"), ["7"] = g("111", "001", "010", "010", "010"),
  ["8"] = g("111", "101", "111", "101", "111"), ["9"] = g("111", "101", "111", "001", "110"),
  ["$"] = g("011", "110", "010", "011", "110"), ["+"] = g("000", "010", "111", "010", "000"),
  ["-"] = g("000", "000", "111", "000", "000"), ["/"] = g("001", "001", "010", "100", "100"),
  ["."] = g("000", "000", "000", "000", "010"), ["!"] = g("010", "010", "010", "000", "010"),
  ["?"] = g("110", "001", "010", "000", "010"), [":"] = g("000", "010", "000", "010", "000"),
  ["%"] = g("101", "001", "010", "100", "101"), ["("] = g("010", "100", "100", "100", "010"),
  [")"] = g("010", "001", "001", "001", "010"), ["'"] = g("010", "010", "000", "000", "000"),
  [","] = g("000", "000", "000", "010", "100"), ["<"] = g("001", "010", "100", "010", "001"),
  [">"] = g("100", "010", "001", "010", "100"), ["#"] = g("101", "111", "101", "111", "101"),
  ["="] = g("000", "111", "000", "111", "000"),
}
local GLYPH_ORDER = " ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789$+-/.!?:%()',<>#="
local NARROW = { ["."] = true, [":"] = true, ["!"] = true, ["'"] = true, [","] = true, ["("] = true, [")"] = true }

local PAL = {
  ["1"] = { 255, 255, 255 },
  k = { 24, 20, 26 }, K = { 46, 44, 52 }, d = { 64, 66, 76 }, e = { 108, 112, 126 }, E = { 160, 166, 180 }, W = { 214, 220, 228 },
  y = { 255, 222, 74 }, Y = { 255, 246, 176 }, o = { 255, 146, 38 }, O = { 206, 84, 22 }, w = { 255, 255, 236 },
  G = { 40, 82, 44 }, g = { 88, 146, 70 }, h = { 150, 196, 106 },
  r = { 255, 64, 44 }, R = { 104, 18, 22 }, m = { 172, 28, 30 },
  b = { 68, 92, 140 }, B = { 42, 56, 94 }, p = { 84, 70, 56 }, P = { 54, 44, 36 },
  s = { 158, 168, 150 }, S = { 108, 118, 104 }, n = { 204, 112, 40 }, N = { 140, 68, 24 },
  v = { 124, 134, 88 }, V = { 82, 92, 58 },
  t = { 178, 122, 68 }, T = { 118, 78, 42 }, l = { 220, 170, 108 },
  a = { 0, 0, 0, 70 }, q = { 255, 214, 90, 80 }, Q = { 255, 236, 150, 170 },
}

local ZOMBIE_BODY = {
  "....kkkk....",
  "...kggggk...",
  "..kghgggGk..",
  "..kgrggrGk..",
  "..kggRRgGk..",
  "...kgggGk...",
  "..kkbbbbkk..",
  ".kgbbbbbBgk.",
  ".kgbbmbbBgk.",
  "kgkbbbbbBkgk",
  "kGkbbbbbBkGk",
  "..kppppPPk..",
  "..kppkkPPk..",
}
local ZOMBIE_LEGS_A = { "..kpk..kPk..", "..kkk..kPk..", ".......kkk.." }
local ZOMBIE_LEGS_B = { "..kpk..kPk..", "..kpk..kkk..", "..kkk......." }
local RUNNER_REMAP = { g = "s", G = "S", h = "W", b = "n", B = "N", r = "y" }

local BRUTE_BODY = {
  ".....kkkkkk.....",
  "....kvvvvvvk....",
  "...kvvvvvvvVk...",
  "...kvrvvvvrVk...",
  "...kvvRRRRvVk...",
  "....kvvvvvVk....",
  "..kkkNNNNNNkkk..",
  ".kvvknnnnnNkvvk.",
  "kvvvknnmnnNkvvvk",
  "kvvvknnnnnNkvvvk",
  "kVVvknnnnnNkvVVk",
  ".kkkknnnnnNkkkk.",
  "...kppppppPPk...",
  "...kpppkkpPPk...",
}
local BRUTE_LEGS_A = { "...kppk..kPPk...", "...kkkk..kPPk...", ".........kkkk...", "................" }
local BRUTE_LEGS_B = { "...kppk..kPPk...", "...kppk..kkkk...", "...kkkk.........", "................" }

local SPRITE_ROWS = {
  glock = {
    ".kkkkkkkkkkk",
    ".kEWWWWWWWEk",
    ".kddddddddek",
    ".kkKKkkkkkk.",
    "..kKKk.k....",
    "..kKKkk.....",
    "..kkkk......",
  },
  uzi = {
    "kkkkkkkkkkkk.",
    "kEWWWWWWWWEkk",
    "kdddddddddddk",
    "kkkkKKkkkkkk.",
    "...kKKk.kek..",
    "...kKKk.kek..",
    "...kkkk.kkk..",
  },
  shotgun = {
    "..kkkkkkkkkkkkkkkk",
    "kktltkkEWWWWWWWWWk",
    "kttttTkdddddddddkk",
    "kTTTk.kkkkkkkkkk..",
    ".kkk..............",
  },
  rifle = {
    ".........kkkk.........",
    "........kEWWEk........",
    "kkkkkkkkkkkkkkkkkkkkkk",
    "kTttltkddddddddddddddk",
    "kTTTTkkk.kk...........",
    "kkkk..................",
  },
  flash1 = { "...y...", "..yoy..", ".yoYoy.", "yoYwYoy", ".yoYoy.", "..yoy..", "...y..." },
  flash2 = { "..y..", ".yoy.", "yoway", ".yoy.", "..y.." },
  flash3 = { "o.o", ".y.", "o.o" },
  flare = { "..oyy..", "OoyYwwy", "..oyy.." },
  glow = { ".qqq.", "qQQQq", "qQwQq", "qQQQq", ".qqq." },
  heart = { ".kk.kk.", "kwrkrrk", "krrrrrk", ".krrrk.", "..krk..", "...k..." },
  coin = { ".kkkk.", "kyYYyk", "kYyyOk", "kyyyOk", "kyOOOk", ".kkkk." },
  skull = { ".kkkkk.", "kWWWWWk", "kWkWkWk", "kWWWWWk", ".kWkWk.", "..kkk.." },
  arrow = { "..r..", ".rrr.", "rrrrr" },
  shadowS = { ".aaaaaaaa.", "aaaaaaaaaa", ".aaaaaaaa." },
  shadowL = { ".aaaaaaaaaaaa.", "aaaaaaaaaaaaaa", ".aaaaaaaaaaaa." },
  splat1 = { "..m...", ".mRmm.", "mRRRm.", ".mRm.m", "..m..." },
  splat2 = { "m...m.", ".mmR..", "..RRm.", ".mRm..", "m....m" },
  splat3 = { ".mm..m.", "mRRm...", ".mRRmm.", "..m..m." },
  pixel = { "1" },
}

local CACTUS = { "...gh...", "...gh..h", "g..gh..h", "g..gh..G", "gG.gh.gG", ".GGghGG.", "...gh...", "...gh...", "...gG...", "..aaaa.." }
local ROCK = { "..EEe...", ".EEeed..", "Eeeeddd.", ".aaaaaa." }
local BUSH = { "T...T..T.", ".T.T.TT..", "..TtT.T.T", ".T.TtT.T.", "...tTt...", "..aaaaa.." }
local SKULL_DECOR = { ".www.", "wkwkw", "wwwww", ".w.w." }
local BONES = { "w.....w", ".wwwww.", "w.....w" }
local TIRE = { ".kkkkk.", "kKkkkKk", "kk...kk", "kKkkkKk", ".kkkkk." }

local SAND_PAL = { { 96, 72, 48 }, { 128, 100, 64 }, { 160, 128, 84 }, { 190, 156, 104 }, { 214, 182, 126 }, { 232, 206, 150 }, { 246, 228, 182 } }
local ASPH_PAL = { { 28, 28, 34 }, { 40, 40, 46 }, { 52, 52, 58 }, { 64, 64, 70 }, { 78, 78, 84 }, { 94, 94, 100 } }
local BAYER = { 0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5 }

local Assets = { owned = {} }
local SP = {}
local FLASH, SPLATS, BARRICADE = {}, {}, {}
local atlas

local function own(resource)
  Assets.owned[#Assets.owned + 1] = resource
  return resource
end

local function concatRows(a, b)
  local out = {}
  for i = 1, #a do out[#out + 1] = a[i] end
  for i = 1, #b do out[#out + 1] = b[i] end
  return out
end

local function quant(pal, v, x, y)
  local n = #pal
  local f = clamp(v, 0, 1) * (n - 1)
  local i = floor(f)
  if f - i > (BAYER[(y % 4) * 4 + (x % 4) + 1] + 0.5) / 16 then i = i + 1 end
  if i > n - 1 then i = n - 1 end
  return pal[i + 1]
end

local function slotCenters()
  local list = {}
  for row = 1, SLOT_ROWS do
    for side = 1, 2 do
      list[#list + 1] = { x = SLOT_X[side], y = SLOT_TOP + (row - 1) * SLOT_GAP, side = side }
    end
  end
  return list
end

local function buildFont()
  local spans, total = {}, 1
  for i = 1, #GLYPH_ORDER do
    local ch = GLYPH_ORDER:sub(i, i)
    local bits = GLYPHS[ch]
    if not bits or #bits ~= 15 then error("malformed glyph '" .. ch .. "'") end
    local x0, x1 = 0, 2
    if ch == " " then
      x1 = 1
    elseif NARROW[ch] then
      x0, x1 = 3, -1
      for c = 0, 2 do
        for r = 0, 4 do
          if bits:sub(r * 3 + c + 1, r * 3 + c + 1) == "1" then
            x0, x1 = min(x0, c), max(x1, c)
          end
        end
      end
    end
    spans[i] = { x0, x1 }
    total = total + (x1 - x0 + 1) + 1
  end
  local data = love.image.newImageData(total, 5)
  local function separator(col)
    for r = 0, 4 do data:setPixel(col, r, 1, 0, 1, 1) end
  end
  separator(0)
  local x = 1
  for i = 1, #GLYPH_ORDER do
    local bits = GLYPHS[GLYPH_ORDER:sub(i, i)]
    local x0, x1 = spans[i][1], spans[i][2]
    for c = x0, x1 do
      for r = 0, 4 do
        if bits:sub(r * 3 + c + 1, r * 3 + c + 1) == "1" then
          data:setPixel(x + c - x0, r, 1, 1, 1, 1)
        end
      end
    end
    x = x + (x1 - x0 + 1)
    separator(x)
    x = x + 1
  end
  local font = lg.newImageFont(data, GLYPH_ORDER, 1)
  font:setFilter("nearest", "nearest")
  data:release()
  return own(font)
end

local function paintRows(data, s)
  local rows, remap = s.rows, s.remap
  for y = 1, s.h do
    local row = rows[y]
    for x = 1, s.w do
      local ch = row:sub(x, x)
      if remap and remap[ch] then ch = remap[ch] end
      if ch ~= "." then
        local c = PAL[ch]
        if not c then error("unknown palette key '" .. ch .. "' in sprite " .. s.name) end
        data:setPixel(s.x + x - 1, s.y + y - 1, c[1] / 255, c[2] / 255, c[3] / 255, (c[4] or 255) / 255)
      end
    end
  end
end

local function makeSetter(data, s)
  local ox, oy, w, h = s.x, s.y, s.w, s.h
  return function(x, y, r, gg, b, a)
    if x >= 0 and y >= 0 and x < w and y < h then
      data:setPixel(ox + x, oy + y, clamp(r, 0, 255) / 255, clamp(gg, 0, 255) / 255, clamp(b, 0, 255) / 255, (a or 255) / 255)
    end
  end
end

local function padPainter(full)
  return function(set, w, h)
    local cx, cy = (w - 1) / 2, (h - 1) / 2
    for y = 0, h - 1 do
      for x = 0, w - 1 do
        local dx, dy = x - cx, y - cy
        local r = sqrt(dx * dx + dy * dy)
        local hash = ((x * 7 + y * 13 + x * y * 3) % 11) / 11
        if full then
          if r <= 12.6 then
            if r >= 8.2 then
              local seg = (atan2(dy, dx) + pi) / TAU * 9
              local f = seg - floor(seg)
              local light = -(dx + dy) * 0.7071 / max(r, 0.001)
              local bulge = (1 - abs(f - 0.5) * 2) * (1 - abs((r - 8.2) / 4.4 - 0.5) * 2)
              local v = 0.45 + light * 0.3 + bulge * 0.35 + (hash - 0.5) * 0.08
              if r > 11.9 then
                set(x, y, 70, 52, 32)
              elseif f < 0.07 or f > 0.93 then
                set(x, y, 116, 94, 58)
              elseif v > 0.78 then
                set(x, y, 240, 222, 172)
              elseif v > 0.52 then
                set(x, y, 214, 190, 136)
              elseif v > 0.3 then
                set(x, y, 176, 150, 100)
              else
                set(x, y, 136, 112, 72)
              end
            elseif r >= 7.2 then
              set(x, y, 96, 76, 48)
            elseif hash > 0.8 then
              set(x, y, 128, 104, 68)
            else
              set(x, y, 146, 120, 80)
            end
          end
        else
          if r <= 11.6 and r >= 10.4 then
            if floor((atan2(dy, dx) + pi) / TAU * 18) % 2 == 0 then set(x, y, 150, 122, 80, 220) end
          elseif r < 10.4 then
            set(x, y, 120, 96, 60, 60)
          end
          if (abs(dx) < 0.6 and abs(dy) < 3.5) or (abs(dy) < 0.6 and abs(dx) < 3.5) then
            set(x, y, 120, 96, 60, 200)
          end
        end
      end
    end
  end
end

local function barricadePainter(dmg)
  return function(set, w, h)
    local rng = lm.newRandomGenerator(900 + dmg)
    local top, bottom = {}, {}
    if dmg >= 1 then
      top[#top + 1] = { 24, 40 }
      bottom[#bottom + 1] = { 118, 128 }
    end
    if dmg >= 2 then
      top[#top + 1] = { 96, 120 }
      bottom[#bottom + 1] = { 52, 78 }
    end
    local function holed(list, x, y)
      for i = 1, #list do
        if x >= list[i][1] + (y % 2) and x <= list[i][2] - ((y + 1) % 2) then return true end
      end
      return false
    end
    local function plank(y0, holes)
      for x = 0, w - 1 do
        for y = 0, 4 do
          if not holed(holes, x, y) then
            local grain = lm.noise(x * 0.15, (y0 + y) * 0.9 + y0)
            if y == 0 then
              set(x, y0 + y, 222, 172, 110)
            elseif y == 4 then
              set(x, y0 + y, 110, 72, 38)
            elseif grain > 0.72 then
              set(x, y0 + y, 146, 98, 54)
            else
              set(x, y0 + y, 178, 122, 68)
            end
          end
        end
      end
    end
    plank(4, top)
    plank(11, bottom)
    if dmg >= 1 then
      for _ = 1, 4 + dmg * 4 do
        local cx, cy = rng:random(4, w - 5), rng:random(0, 1) == 0 and 6 or 13
        for i = 0, rng:random(3, 8) do set(cx + i, cy + (i % 3 == 0 and 1 or 0), 70, 44, 22) end
      end
    end
    local posts = { 0, 48, 100, 148 }
    for i = 1, #posts do
      local px = posts[i]
      for y = 2, h - 1 do
        for x = 0, 3 do
          if x == 0 then
            set(px + x, y, 150, 104, 60)
          elseif x == 3 or y == h - 1 then
            set(px + x, y, 70, 46, 24)
          else
            set(px + x, y, 104, 68, 36)
          end
        end
      end
      set(px + 1, 2, 60, 40, 20)
      set(px + 2, 2, 60, 40, 20)
      set(px + 1, 6, 40, 40, 46)
      set(px + 2, 13, 40, 40, 46)
    end
    for x = 0, w - 1 do
      if not (dmg >= 2 and x > 60 and x < 110) then
        set(x, 1 + floor((x % 6) / 3), 150, 156, 170)
        if x % 8 == 0 then
          set(x, 0, 90, 94, 104)
          set(x, 3, 90, 94, 104)
        end
      end
    end
  end
end

local function boxPainter(set, w, h)
  local frame = 5
  for y = 0, h - 1 do
    for x = 0, w - 1 do
      local n = ((x * 31 + y * 17) % 7) - 3
      if x == 0 or y == 0 or x == w - 1 or y == h - 1 then
        set(x, y, 40, 24, 12)
      elseif x < frame or y < frame or x >= w - frame or y >= h - frame then
        if x == 1 or y == 1 then
          set(x, y, 176, 126, 74)
        elseif x == frame - 1 and y >= frame - 1 and y < h - frame + 1 or y == frame - 1 and x >= frame - 1 and x < w - frame + 1 then
          set(x, y, 58, 36, 18)
        else
          set(x, y, 100 + n, 62 + n, 32 + n)
        end
      else
        local py = y - frame
        local plank = floor(py / 9)
        local row = py % 9
        local base = (plank % 2 == 0) and 150 or 140
        local grain = lm.noise(x * 0.06, y * 0.7 + plank * 7)
        if row == 8 then
          set(x, y, 78, 48, 24)
        elseif row == 0 then
          set(x, y, base + 26, floor(base * 0.68) + 20, floor(base * 0.36) + 14)
        elseif grain > 0.7 then
          set(x, y, base - 22 + n, floor(base * 0.66) - 16 + n, floor(base * 0.34) - 8 + n)
        else
          set(x, y, base + n, floor(base * 0.66) + n, floor(base * 0.34) + n)
        end
      end
    end
  end
  for x = frame, w - frame - 1 do
    set(x, 16, 50, 30, 14)
    set(x, 17, 190, 140, 86)
  end
  local corners = { { 0, 0, 1, 1 }, { w - 1, 0, -1, 1 }, { 0, h - 1, 1, -1 }, { w - 1, h - 1, -1, -1 } }
  for i = 1, #corners do
    local cx, cy, sx, sy = corners[i][1], corners[i][2], corners[i][3], corners[i][4]
    for a = 0, 10 do
      for b = 0, 2 do
        local c1 = (b == 0) and 180 or 124
        set(cx + sx * a, cy + sy * b, c1, c1 + 6, c1 + 18)
        set(cx + sx * b, cy + sy * a, c1, c1 + 6, c1 + 18)
      end
    end
    set(cx + sx * 7, cy + sy * 1, 50, 52, 60)
    set(cx + sx * 1, cy + sy * 7, 50, 52, 60)
  end
  local lx = floor(w / 2) - 5
  for y = 11, 22 do
    for x = lx, lx + 10 do
      local edge = x == lx or x == lx + 10 or y == 11 or y == 22
      if edge then set(x, y, 60, 62, 72) else set(x, y, 140, 146, 160) end
    end
  end
  for y = 14, 18 do set(lx + 5, y, 30, 30, 36) end
  set(lx + 4, 15, 30, 30, 36)
  set(lx + 6, 15, 30, 30, 36)
end

local function buildAtlas()
  local sources = {}
  local function rows(name, r, remap)
    sources[#sources + 1] = { name = name, rows = r, remap = remap, w = #r[1], h = #r }
  end
  local function paint(name, w, h, fn)
    sources[#sources + 1] = { name = name, w = w, h = h, paint = fn }
  end
  rows("walkerA", concatRows(ZOMBIE_BODY, ZOMBIE_LEGS_A))
  rows("walkerB", concatRows(ZOMBIE_BODY, ZOMBIE_LEGS_B))
  rows("runnerA", concatRows(ZOMBIE_BODY, ZOMBIE_LEGS_A), RUNNER_REMAP)
  rows("runnerB", concatRows(ZOMBIE_BODY, ZOMBIE_LEGS_B), RUNNER_REMAP)
  rows("bruteA", concatRows(BRUTE_BODY, BRUTE_LEGS_A))
  rows("bruteB", concatRows(BRUTE_BODY, BRUTE_LEGS_B))
  for name, r in pairs(SPRITE_ROWS) do rows(name, r) end
  paint("padFull", 26, 26, padPainter(true))
  paint("padEmpty", 26, 26, padPainter(false))
  for i = 1, 3 do paint("barricade" .. i, 152, 18, barricadePainter(i - 1)) end
  paint("box", 236, 52, boxPainter)

  for i = 1, #sources do
    local s = sources[i]
    if s.rows then
      for r = 1, #s.rows do
        if #s.rows[r] ~= s.w then
          error("sprite '" .. s.name .. "' row " .. r .. " has width " .. #s.rows[r] .. ", expected " .. s.w)
        end
      end
    end
  end
  table.sort(sources, function(a, b)
    if a.h ~= b.h then return a.h > b.h end
    return a.name < b.name
  end)
  local width = 256
  local x, y, shelf = 1, 1, 0
  for i = 1, #sources do
    local s = sources[i]
    if s.w + 2 > width then error("sprite '" .. s.name .. "' is too wide for the atlas") end
    if x + s.w + 1 > width then
      x, y, shelf = 1, y + shelf + 1, 0
    end
    s.x, s.y = x, y
    x = x + s.w + 1
    if s.h > shelf then shelf = s.h end
  end
  local height = y + shelf + 1
  local data = love.image.newImageData(width, height)
  for i = 1, #sources do
    local s = sources[i]
    if s.rows then paintRows(data, s) else s.paint(makeSetter(data, s), s.w, s.h) end
  end
  local image = lg.newImage(data)
  image:setFilter("nearest", "nearest")
  data:release()
  for i = 1, #sources do
    local s = sources[i]
    SP[s.name] = { quad = own(lg.newQuad(s.x, s.y, s.w, s.h, width, height)), w = s.w, h = s.h }
  end
  return own(image)
end

local function buildBackground()
  local W, H = WORLD_W, WORLD_H
  local rng = lm.newRandomGenerator(424242)
  local function rr() return rng:random() end
  local function ri(a, b) return rng:random(a, b) end
  local data = love.image.newImageData(W, H)
  local function put(x, y, c, a)
    if x < 0 or y < 0 or x >= W or y >= H then return end
    if a and a < 1 then
      local r0, g0, b0 = data:getPixel(x, y)
      data:setPixel(x, y, r0 + (c[1] / 255 - r0) * a, g0 + (c[2] / 255 - g0) * a, b0 + (c[3] / 255 - b0) * a, 1)
    else
      data:setPixel(x, y, c[1] / 255, c[2] / 255, c[3] / 255, 1)
    end
  end
  local function stamp(rows, x0, y0, flip)
    for r = 1, #rows do
      local row = rows[r]
      local w = #row
      for c = 1, w do
        local ch = row:sub(c, c)
        local col = PAL[ch]
        if col then
          put(flip and (x0 + w - c) or (x0 + c - 1), y0 + r - 1, col, col[4] and col[4] / 255 or nil)
        end
      end
    end
  end

  local eL, eR = {}, {}
  local oL, oR = 0, 0
  for y = 0, H - 1 do
    oL = clamp(oL + (rr() - 0.5) * 1.2, -3, 3)
    oR = clamp(oR + (rr() - 0.5) * 1.2, -3, 3)
    eL[y] = floor(ROAD_L + oL + sin(y * 0.031) * 2)
    eR[y] = floor(ROAD_R + oR + sin(y * 0.027 + 1.7) * 2)
  end

  for y = 0, H - 1 do
    local l, r = eL[y], eR[y]
    for x = 0, W - 1 do
      if x >= l and x < r then
        local v = 0.5 + (rr() - 0.5) * 0.2 + (lm.noise(x * 0.045, y * 0.045) - 0.5) * 0.3
        local dl = x - l
        if dl < 8 then v = v - 0.34 * (1 - dl / 8) end
        if r - 1 - x < 2 then v = v - 0.18 end
        put(x, y, quant(ASPH_PAL, v, x, y))
      else
        local left = x < l
        local d = left and (l - x) or (x - r + 1)
        local v
        if d <= BANK then
          local t = d / BANK
          if left then v = 0.14 + 0.3 * t else v = 0.6 + 0.18 * t end
          if d >= BANK - 1 then v = left and 0.7 or 0.92 end
        else
          local rip = sin(y * 0.42 + sin(x * 0.06 + y * 0.015) * 3.2 + x * 0.05)
          v = 0.55 + rip * 0.07 + (lm.noise(x * 0.02 + 40, y * 0.02) - 0.5) * 0.16
          if rip > 0.9 then
            v = v + 0.12
          elseif rip < -0.92 then
            v = v - 0.1
          end
        end
        put(x, y, quant(SAND_PAL, v + (rr() - 0.5) * 0.08, x, y))
      end
    end
  end

  local paintY, paintW = { 206, 178, 74 }, { 196, 196, 188 }
  local cx = floor(ROAD_C) - 1
  for y = 0, H - 1 do
    if y % 30 < 16 then
      for x = cx, cx + 1 do
        if lm.noise(x * 0.7, y * 0.23) > 0.3 then put(x, y, paintY, 0.85) end
      end
    end
    if lm.noise(3.3, y * 0.07) > 0.3 then
      if rr() > 0.2 then put(eL[y] + 9, y, paintW, 0.55) end
      if rr() > 0.2 then put(eR[y] - 6, y, paintW, 0.65) end
    end
  end

  for _ = 1, 7 do
    local pw, ph = ri(14, 34), ri(10, 26)
    local px, py = ri(ROAD_L + 10, ROAD_R - 10 - pw), ri(4, BARRICADE_Y - 30)
    for y = py, py + ph - 1 do
      for x = px, px + pw - 1 do
        local edge = x == px or y == py or x == px + pw - 1 or y == py + ph - 1
        put(x, y, quant(ASPH_PAL, edge and 0.12 or (0.32 + (rr() - 0.5) * 0.12), x, y))
      end
    end
  end

  for y = 0, H - 1 do
    local l, r = eL[y], eR[y]
    for x = l, l + 14 do
      local d = x - l
      if lm.noise(x * 0.09, y * 0.06 + 11) > 0.55 + d * 0.035 then
        put(x, y, quant(SAND_PAL, 0.36 + (rr() - 0.5) * 0.15, x, y))
      end
    end
    for x = r - 15, r - 1 do
      local d = r - 1 - x
      if lm.noise(x * 0.09 + 77, y * 0.06) > 0.55 + d * 0.035 then
        put(x, y, quant(SAND_PAL, 0.6 + (rr() - 0.5) * 0.15, x, y))
      end
    end
  end

  local crackDark, crackLight = ASPH_PAL[1], ASPH_PAL[6]
  local function crack(x, y, ang, len, depth)
    for _ = 1, len do
      ang = ang + (rr() - 0.5) * 0.8
      x, y = x + cos(ang), y + sin(ang)
      local ix, iy = floor(x), floor(y)
      if iy >= 0 and iy < H and ix > eL[iy] + 2 and ix < eR[iy] - 3 then
        put(ix + 1, iy + 1, crackLight, 0.6)
        put(ix, iy, crackDark)
        if depth == 0 and rr() < 0.25 then put(ix + 1, iy, crackDark) end
      end
      if depth < 2 and rr() < 0.05 then
        crack(x, y, ang + (rr() < 0.5 and -1 or 1) * (0.5 + rr() * 0.7), floor(len * 0.5), depth + 1)
      end
    end
  end
  for _ = 1, 26 do crack(ri(ROAD_L + 6, ROAD_R - 6), ri(0, H - 20), pi / 2 + (rr() - 0.5) * 1.6, ri(24, 80), 0) end
  for _ = 1, 6 do crack(ri(ROAD_L + 6, floor(ROAD_C)), ri(10, H - 30), (rr() - 0.5) * 0.6, ri(30, 70), 0) end

  for _ = 1, 14 do
    local px, py = ri(ROAD_L + 18, ROAD_R - 18), ri(8, BARRICADE_Y - 16)
    local rx, ry = ri(4, 11), ri(3, 7)
    for y = py - ry - 2, py + ry + 2 do
      for x = px - rx - 2, px + rx + 2 do
        local dx, dy = (x - px) / rx, (y - py) / ry
        local dist = dx * dx + dy * dy + (lm.noise(x * 0.4, y * 0.4) - 0.5) * 0.5
        if dist <= 1 then
          if dist > 0.6 and dy < 0 then
            put(x, y, ASPH_PAL[1])
          elseif dist > 0.7 and dy > 0 then
            put(x, y, ASPH_PAL[4])
          elseif rr() < 0.18 then
            put(x, y, SAND_PAL[2])
          else
            put(x, y, ASPH_PAL[2])
          end
        elseif dist <= 1.45 and rr() < 0.55 then
          put(x, y, dy < 0 and ASPH_PAL[5] or ASPH_PAL[3])
        end
      end
    end
    for _ = 1, 10 do put(px + ri(-rx - 4, rx + 4), py + ri(-ry - 4, ry + 4), ASPH_PAL[5]) end
  end

  for _ = 1, 3 do
    local x0, y0, len = ri(ROAD_L + 20, ROAD_R - 40), ri(20, H - 120), ri(50, 110)
    local k = (rr() - 0.5) * 0.004
    for t = 0, len do
      local x = floor(x0 + k * t * t * 0.5)
      if rr() > 0.15 then
        put(x, y0 + t, ASPH_PAL[1], 0.45)
        put(x + 10, y0 + t, ASPH_PAL[1], 0.45)
      end
    end
  end

  local oil, stain = { 20, 20, 26 }, { 92, 30, 28 }
  for _ = 1, 6 do
    local px, py, rad = ri(ROAD_L + 14, ROAD_R - 14), ri(10, H - 30), ri(3, 7)
    local c = rr() < 0.4 and stain or oil
    for y = py - rad, py + rad do
      for x = px - rad * 2, px + rad * 2 do
        local dx, dy = (x - px) / (rad * 1.6), (y - py) / rad
        if dx * dx + dy * dy + (lm.noise(x * 0.3, y * 0.3) - 0.5) * 0.8 < 1 then put(x, y, c, 0.55) end
      end
    end
  end

  local slots = slotCenters()
  local function free(x, y, w, h)
    for i = 1, #slots do
      local dx, dy = (x + w / 2) - slots[i].x, (y + h / 2) - slots[i].y
      if dx * dx + dy * dy < 22 * 22 then return false end
    end
    return true
  end
  local decor = { CACTUS, ROCK, ROCK, BUSH, BUSH, SKULL_DECOR, BONES, TIRE, ROCK }
  local placed = 0
  for _ = 1, 400 do
    if placed >= 46 then break end
    local rows = decor[ri(1, #decor)]
    local w, h = #rows[1], #rows
    local x
    if rr() < 0.5 then x = ri(2, ROAD_L - BANK - w - 6) else x = ri(ROAD_R + BANK + 4, W - w - 2) end
    local y = ri(2, H - h - 2)
    if free(x, y, w, h) then
      stamp(rows, x, y, rr() < 0.5)
      placed = placed + 1
    end
  end
  for _ = 1, 600 do
    local x, y = ri(0, W - 1), ri(0, H - 1)
    if x < eL[y] - BANK or x > eR[y] + BANK then put(x, y, SAND_PAL[ri(2, 3)]) end
  end

  local image = lg.newImage(data)
  image:setFilter("nearest", "nearest")
  data:release()
  return own(image)
end

local function buildAssets()
  Assets.font = buildFont()
  atlas = buildAtlas()
  Assets.background = buildBackground()
  FLASH[1], FLASH[2], FLASH[3] = SP.flash1, SP.flash2, SP.flash3
  SPLATS[1], SPLATS[2], SPLATS[3] = SP.splat1, SP.splat2, SP.splat3
  BARRICADE[1], BARRICADE[2], BARRICADE[3] = SP.barricade1, SP.barricade2, SP.barricade3
  for _, zt in pairs(ZTYPES) do
    zt.sprA, zt.sprB, zt.shadowSpr = SP[zt.a], SP[zt.b], SP[zt.shadow]
    if not (zt.sprA and zt.sprB and zt.shadowSpr) then error("missing zombie sprite") end
  end
  for i = 1, #WEAPONS do
    if not SP[WEAPONS[i].sprite] then error("missing weapon sprite " .. WEAPONS[i].sprite) end
  end
end

local function spr(s, x, y, r, sx, sy, ox, oy)
  lg.draw(atlas, s.quad, x, y, r or 0, sx or 1, sy or 1, ox or 0, oy or 0)
end

local function text(str, x, y, s, color, alpha, shadow)
  s = s or 1
  x, y = floor(x), floor(y)
  local a = alpha or 1
  if shadow then
    lg.setColor(0, 0, 0, 0.6 * a)
    lg.print(str, x + s, y + s, 0, s, s)
  end
  setColor(color or C.white, a)
  lg.print(str, x, y, 0, s, s)
end

local function textWidth(str, s)
  return Assets.font:getWidth(str) * (s or 1)
end

local function textCenter(str, cx, y, s, color, alpha, shadow)
  text(str, cx - textWidth(str, s) / 2, y, s, color, alpha, shadow)
end

local function textRight(str, rx, y, s, color, alpha, shadow)
  text(str, rx - textWidth(str, s), y, s, color, alpha, shadow)
end

local function frameRect(x, y, w, h)
  lg.rectangle("fill", x, y, w, 1)
  lg.rectangle("fill", x, y + h - 1, w, 1)
  lg.rectangle("fill", x, y, 1, h)
  lg.rectangle("fill", x + w - 1, y, 1, h)
end

local function dottedRing(x, y, r, phase, color, alpha)
  local n = max(12, floor(r * TAU / 5))
  local q = SP.pixel.quad
  setColor(color, alpha)
  for i = 0, n - 1 do
    local a = phase + i / n * TAU
    lg.draw(atlas, q, floor(x + cos(a) * r + 0.5), floor(y + sin(a) * r + 0.5))
  end
end

local function sortByY(list)
  for i = 2, #list do
    local v = list[i]
    local y = v.y
    local j = i - 1
    while j >= 1 and list[j].y > y do
      list[j + 1] = list[j]
      j = j - 1
    end
    list[j + 1] = v
  end
end

local function parseSave(content)
  if type(content) ~= "string" or #content == 0 or #content > MAX_SAVE_BYTES then return nil end
  local body, sum = content:match("^(.-)\nsum=(%d+)\n?$")
  if not body or tonumber(sum) ~= checksum(body) then return nil end
  local fields, list = {}, {}
  for line in body:gmatch("[^\n]+") do
    local k, v = line:match("^(%a+)=([%w%.%-,]+)$")
    if not k then return nil end
    if k == "t" then
      if #list < 64 then list[#list + 1] = v end
    else
      fields[k] = v
    end
  end
  if tonumber(fields.v) ~= SAVE_VERSION then return nil end
  return fields, list
end

local function readSave(name)
  local candidates = { name, name .. ".bak" }
  for i = 1, #candidates do
    local file = candidates[i]
    local ok, info = pcall(lf.getInfo, file)
    if ok and info and info.type == "file" and (info.size or 0) <= MAX_SAVE_BYTES then
      local okRead, content = pcall(lf.read, file)
      if okRead and content then
        local fields, list = parseSave(content)
        if fields then return fields, list end
      end
    end
  end
  return nil
end

local function writeSave(name, content)
  local ok, res = pcall(lf.write, name, content)
  if not ok or not res then return false end
  pcall(lf.write, name .. ".bak", content)
  return true
end

local function removeSave(name)
  pcall(lf.remove, name)
  pcall(lf.remove, name .. ".bak")
end

local function sealed(lines)
  local body = concat(lines, "\n")
  return body .. "\nsum=" .. checksum(body) .. "\n"
end

local function serializeMeta(m)
  return sealed({
    "v=" .. SAVE_VERSION,
    "best=" .. int(m.best),
    "total=" .. int(m.total),
    "zoom=" .. int(m.zoom),
    "full=" .. (m.full and 1 or 0),
    "speed=" .. int(m.speed),
  })
end

local function loadMeta()
  local m = { best = 0, total = 0, zoom = 0, full = false, speed = 1 }
  local fields = readSave(SAVE_META)
  if fields then
    m.best = num(fields.best, 0, 1e7, 0)
    m.total = num(fields.total, 0, 1e12, 0)
    m.zoom = num(fields.zoom, -4, 0, 0)
    m.full = fields.full == "1"
    m.speed = fields.speed == "2" and 2 or 1
  end
  return m
end

local view = { scale = 1, x = 0, y = 0, vh = MIN_VH }
local canvas, ui, game, meta
local fatalError, defaultFont
local computeViewport, changeZoom

local Button = {}
Button.__index = Button

function Button.new(label, theme, scale)
  return setmetatable({ x = 0, y = 0, w = 10, h = 10, label = label, theme = theme, scale = scale or 1, enabled = true, visible = true }, Button)
end

function Button:place(x, y, w, h)
  self.x, self.y, self.w, self.h = x, y, w, h
end

function Button:contains(px, py)
  return self.visible and px >= self.x and px < self.x + self.w and py >= self.y and py < self.y + self.h
end

function Button:hit(px, py)
  return self.enabled and self:contains(px, py)
end

function Button:draw(mx, my, down)
  if not self.visible then return end
  local on = self.enabled
  local hover = on and self:contains(mx, my)
  local pressed = hover and down
  local t = on and self.theme or DISABLED
  local x, y, w, h = self.x, self.y + (pressed and 1 or 0), self.w, self.h
  setColor(C.black, 0.85)
  lg.rectangle("fill", x - 1, y - 1, w + 2, h + (pressed and 2 or 3))
  setColor(hover and t.hover or t.face)
  lg.rectangle("fill", x, y, w, h)
  setColor(pressed and t.dark or t.light)
  lg.rectangle("fill", x, y, w, 1)
  lg.rectangle("fill", x, y, 1, h)
  setColor(pressed and t.light or t.dark)
  lg.rectangle("fill", x, y + h - 1, w, 1)
  lg.rectangle("fill", x + w - 1, y, 1, h)
  local s = self.scale
  local tx = x + floor((w - textWidth(self.label, s)) / 2) + floor(s / 2)
  local ty = y + floor((h - 5 * s) / 2)
  text(self.label, tx, ty, s, t.text)
end

local function createUi()
  return {
    roll = Button.new("ROLL", THEME.green, 2),
    buy = Button.new("BUY", THEME.gold, 2),
    start = Button.new("START WAVE", THEME.red, 2),
    speed = Button.new("1X", THEME.steel, 1),
    pause = Button.new("II", THEME.steel, 1),
    upgrade = Button.new("UPGRADE", THEME.green, 1),
    sell = Button.new("SELL", THEME.gold, 1),
    move = Button.new("MOVE", THEME.steel, 1),
    resume = Button.new("RESUME", THEME.green, 2),
    newRun = Button.new("NEW RUN", THEME.red, 2),
    quit = Button.new("QUIT", THEME.steel, 2),
  }
end

local function layoutUi(u, vh)
  local py = vh - PANEL_H
  u.roll:place(12, py + 22, 56, 26)
  u.buy:place(176, py + 22, 56, 26)
  u.start:place(248, py + 30, 88, 24)
  u.speed:place(340, py + 30, 19, 24)
  u.pause:place(362, py + 30, 18, 24)
  local cx, cy = floor(VW / 2), floor(vh / 2)
  u.resume:place(cx - 55, cy - 24, 110, 20)
  u.newRun:place(cx - 55, cy, 110, 20)
  u.quit:place(cx - 55, cy + 24, 110, 20)
end

local Turret = {}
Turret.__index = Turret

function Turret.new(def, slot, level, spent, kills)
  local rest = slot.side == 1 and 0 or pi
  local t = setmetatable({
    def = def, slot = slot, x = slot.cx, y = slot.cy - 1, angle = rest, rest = rest,
    level = 1, spent = spent or def.cost, kills = kills or 0,
    cooldown = 0.3, recoil = 0, kick = 0, flash = 0, retarget = 0, target = nil, targetId = 0,
    damage = 0, fireDelay = 1, range = 0, range2 = 0,
  }, Turret)
  t:setLevel(level or 1)
  return t
end

function Turret:setLevel(level)
  self.level = clamp(floor(level), 1, MAX_LEVEL)
  local d, k = self.def, self.level - 1
  self.damage = d.damage * (1 + 0.5 * k)
  self.fireDelay = d.cooldown * (1 - 0.12 * k)
  self.range = d.range * (1 + 0.1 * k)
  self.range2 = self.range * self.range
end

function Turret:upgradeCost()
  if self.level >= MAX_LEVEL then return nil end
  return floor(self.def.cost * (0.6 + 0.4 * (self.level - 1)) + 0.5)
end

function Turret:sellValue()
  return floor(self.spent * SELL_RATE)
end

function Turret:update(dt, game)
  self.cooldown = max(0, self.cooldown - dt)
  self.flash = max(0, self.flash - dt)
  self.recoil = max(0, self.recoil - 30 * dt)
  self.kick = max(0, self.kick - 3 * dt)
  local target = self.target
  if target and (not target.alive or target.id ~= self.targetId) then target = nil end
  self.retarget = self.retarget - dt
  if game.state == "wave" and (target == nil or self.retarget <= 0) then
    self.retarget = 0.12
    target = game:findTarget(self.x, self.y, self.range2)
  end
  if target then
    local dx, dy = target.x - self.x, target.y - self.y
    local d2 = dx * dx + dy * dy
    if d2 > self.range2 then
      target = nil
    else
      local lead = sqrt(d2) / self.def.speed
      local desired = atan2(dy + target.vy * lead, dx + target.vx * lead)
      local diff = angleDiff(self.angle, desired)
      local turn = 10 * dt
      self.angle = self.angle + clamp(diff, -turn, turn)
      if self.cooldown <= 0 and abs(diff) < 0.12 then
        self.cooldown = self.fireDelay * rnd(0.92, 1.08)
        game:fire(self)
      end
    end
  end
  if not target then
    local diff = angleDiff(self.angle, self.rest)
    self.angle = self.angle + clamp(diff, -2.5 * dt, 2.5 * dt)
  end
  self.angle = (self.angle + pi) % TAU - pi
  self.target = target
  self.targetId = target and target.id or 0
end

function Turret:draw()
  local def = self.def
  local ca, sa = cos(self.angle), sin(self.angle)
  local px, py = self.x - ca * self.recoil, self.y - sa * self.recoil
  local right = ca >= 0
  lg.setColor(1, 1, 1, 1)
  spr(SP[def.sprite], snap(px), snap(py), self.angle + (right and -self.kick or self.kick), 1, right and 1 or -1, def.pivotX, def.pivotY)
  if self.flash > 0 then
    local f = FLASH[clamp(floor((FLASH_TIME - self.flash) / FLASH_TIME * 3) + 1, 1, 3)]
    spr(f, snap(px + ca * (def.muzzle + 2)), snap(py + sa * (def.muzzle + 2)), self.angle, 1, 1, f.w / 2, f.h / 2)
  end
end

local function createSlots()
  local slots = {}
  local centers = slotCenters()
  for i = 1, #centers do
    slots[i] = { index = i, cx = centers[i].x, cy = centers[i].y, side = centers[i].side, turret = nil }
  end
  return slots
end

local Game = {}
Game.__index = Game

function Game.new(interface, viewport, metaData)
  local self = setmetatable({}, Game)
  self.ui, self.view, self.meta = interface, viewport, metaData
  self.slots = createSlots()
  self.zombies, self.bullets, self.particles, self.floaters, self.turrets = {}, {}, {}, {}, {}
  self.decals, self.decalHead = {}, 0
  for i = 1, MAX_DECALS do self.decals[i] = { life = 0, x = 0, y = 0, sprite = nil, flip = 1 } end
  self.bucketCount = ceil((WORLD_H + 64) / BUCKET) + 1
  self.buckets = {}
  for i = 1, self.bucketCount do self.buckets[i] = { n = 0, old = 0 } end
  self.nextId = 0
  self.clock, self.realClock, self.acc = 0, 0, 0
  self.speed = metaData.speed == 2 and 2 or 1
  self.paused = false
  self.saveTimer, self.savedFlash, self.runDirty, self.metaDirty = 0, 0, false, false
  self.confirmNew = 0
  self.camY, self.camTarget = 0, 0
  self.panelVisible, self.panelX, self.panelY, self.panelW, self.panelH = false, 0, 0, 0, 0
  self:reset()
  return self
end

function Game:clearEntities()
  for i = #self.zombies, 1, -1 do
    local z = self.zombies[i]
    z.alive = false
    zombiePool.put(z)
    self.zombies[i] = nil
  end
  for i = #self.bullets, 1, -1 do
    self.bullets[i].owner = nil
    bulletPool.put(self.bullets[i])
    self.bullets[i] = nil
  end
  for i = #self.particles, 1, -1 do
    particlePool.put(self.particles[i])
    self.particles[i] = nil
  end
  for i = #self.floaters, 1, -1 do
    floaterPool.put(self.floaters[i])
    self.floaters[i] = nil
  end
  for i = 1, MAX_DECALS do
    self.decals[i].life = 0
    self.decals[i].sprite = nil
  end
  for i = 1, self.bucketCount do
    local b = self.buckets[i]
    for j = max(b.n, b.old), 1, -1 do b[j] = nil end
    b.n, b.old = 0, 0
  end
end

function Game:reset()
  self:clearEntities()
  for i = 1, #self.slots do self.slots[i].turret = nil end
  for i = #self.turrets, 1, -1 do
    self.turrets[i].target = nil
    self.turrets[i] = nil
  end
  self.state = "build"
  self.money, self.wave, self.life, self.kills = START_MONEY, 1, MAX_LIFE, 0
  self.hand, self.selected, self.offer = nil, nil, nil
  self.rolling, self.rollResult, self.rollShow, self.rollTick, self.reveal = 0, nil, 1, 0, 0
  self.spawnQueue, self.spawnTimer, self.waveTotal, self.waveSnapshot = 0, 0, 0, nil
  self.overClock, self.shake, self.hurtFlash, self.barricadeHit = 0, 0, 0, 0
  self.moneyFlash, self.moneyFlashColor = 0, C.white
  self.toastText, self.toastLife = nil, 0
  self.bannerText, self.bannerSub, self.bannerLife, self.bannerMax, self.bannerColor = nil, nil, 0, 1, C.white
end

function Game:newRun()
  self:reset()
  removeSave(SAVE_RUN)
  self.paused = false
  self.confirmNew = 0
  self:setCamera(self:maxCam(), true)
  self:notify("NEW RUN - GOOD LUCK!")
end

function Game:viewH()
  return self.view.vh - PANEL_H
end

function Game:maxCam()
  return max(0, WORLD_H - self:viewH())
end

function Game:setCamera(v, instant)
  self.camTarget = clamp(v, 0, self:maxCam())
  if instant then self.camY = self.camTarget end
end

function Game:onResize()
  layoutUi(self.ui, self.view.vh)
  self.camTarget = clamp(self.camTarget, 0, self:maxCam())
  self.camY = clamp(self.camY, 0, self:maxCam())
end

function Game:serializeRun()
  local hand = self.hand
  local money = self.money
  if hand and not hand.origin then money = money + hand.spent end
  local lines = { "v=" .. SAVE_VERSION, "money=" .. int(money), "wave=" .. int(self.wave), "life=" .. int(self.life), "kills=" .. int(self.kills) }
  for i = 1, #self.slots do
    local t = self.slots[i].turret
    if t then
      lines[#lines + 1] = "t=" .. i .. "," .. t.def.id .. "," .. t.level .. "," .. int(t.spent) .. "," .. int(t.kills)
    elseif hand and hand.origin == self.slots[i] then
      lines[#lines + 1] = "t=" .. i .. "," .. hand.def.id .. "," .. hand.level .. "," .. int(hand.spent) .. "," .. int(hand.kills or 0)
    end
  end
  return sealed(lines)
end

function Game:applyRun(fields, list)
  local money = num(fields.money, 0, 1e9, nil)
  local wave = num(fields.wave, 1, 100000, nil)
  local life = num(fields.life, 1, MAX_LIFE, nil)
  if not (money and wave and life) then return false end
  self:reset()
  self.money, self.wave, self.life = money, wave, life
  self.kills = num(fields.kills, 0, 1e12, 0)
  for i = 1, #list do
    local s, id, lv, sp, kl = list[i]:match("^(%d+),(%a+),(%d+),(%d+),(%d+)$")
    local slot = s and self.slots[tonumber(s)]
    local def = id and WEAPON_BY_ID[id]
    if slot and def and not slot.turret then
      local t = Turret.new(def, slot, num(lv, 1, MAX_LEVEL, 1), num(sp, 0, 1e9, def.cost), num(kl, 0, 1e12, 0))
      slot.turret = t
      self.turrets[#self.turrets + 1] = t
    end
  end
  return true
end

function Game:saveRun()
  self.runDirty = false
  self.saveTimer = 0.6
  if self.state == "over" then return true end
  local content = (self.state == "wave" and self.waveSnapshot) or self:serializeRun()
  if writeSave(SAVE_RUN, content) then
    self.savedFlash = 1.2
    return true
  end
  self:notify("SAVE FAILED")
  return false
end

function Game:saveMetaNow()
  self.metaDirty = false
  if not writeSave(SAVE_META, serializeMeta(self.meta)) then self:notify("SAVE FAILED") end
end

function Game:markDirty()
  if self.state == "build" then self.runDirty = true end
end

function Game:autosave(dt)
  self.saveTimer = self.saveTimer - dt
  if self.saveTimer > 0 then return end
  if self.runDirty then self:saveRun() end
  if self.metaDirty then self:saveMetaNow() end
end

function Game:notify(msg)
  self.toastText, self.toastLife = msg, 1.8
end

function Game:banner(msg, sub, color, duration)
  self.bannerText, self.bannerSub, self.bannerColor = msg, sub, color or C.white
  self.bannerLife, self.bannerMax = duration or 1.8, duration or 1.8
end

function Game:addMoney(delta)
  self.money = self.money + delta
  self.moneyFlash = 0.35
  self.moneyFlashColor = delta >= 0 and C.green or C.red
end

function Game:addFloater(msg, x, y, color)
  local list = self.floaters
  if #list >= MAX_FLOATERS then
    local old = list[1]
    swapRemove(list, 1)
    floaterPool.put(old)
  end
  local f = floaterPool.get()
  f.text, f.x, f.y, f.life, f.color = msg, x, y, 0.9, color
  list[#list + 1] = f
end

function Game:emit(x, y, vx, vy, life, size, color, grav, floorY)
  local list = self.particles
  if #list >= MAX_PARTICLES then return end
  local p = particlePool.get()
  p.x, p.y, p.vx, p.vy, p.life, p.max = x, y, vx, vy, life, life
  p.size, p.color, p.grav, p.floorY = size, color, grav, floorY
  list[#list + 1] = p
end

function Game:blood(x, y, count, speed, floorY)
  for _ = 1, count do
    local a, s = rnd(0, TAU), rnd(0.3, 1) * speed
    self:emit(x, y, cos(a) * s, sin(a) * s - 25, rnd(0.3, 0.8), rndInt(1, 2), BLOOD[rndInt(1, #BLOOD)], 200, floorY)
  end
end

function Game:puff(x, y, count, colors, speed)
  for _ = 1, count do
    local a, s = rnd(0, TAU), rnd(0.2, 1) * speed
    self:emit(x, y, cos(a) * s, sin(a) * s * 0.6 - 10, rnd(0.3, 0.7), 1, colors[rndInt(1, #colors)], 40, nil)
  end
end

function Game:addDecal(x, y)
  self.decalHead = self.decalHead % MAX_DECALS + 1
  local d = self.decals[self.decalHead]
  d.x, d.y, d.life = snap(x), snap(y), DECAL_LIFE
  d.sprite = SPLATS[rndInt(1, #SPLATS)]
  d.flip = lm.random() < 0.5 and -1 or 1
end

function Game:hint()
  if self.hand then return "CLICK A SAND SLOT TO PLACE IT" end
  if self.rolling > 0 then return "ROLLING..." end
  if self.offer then
    if self.money >= self.offer.cost then return "BUY IT OR ROLL AGAIN" end
    return "TOO PRICEY - ROLL AGAIN"
  end
  if #self.turrets == 0 then return "ROLL THE LUCKY BOX" end
  return "READY? START THE WAVE"
end

function Game:slotAt(wx, wy)
  for i = 1, #self.slots do
    local s = self.slots[i]
    local dx, dy = wx - s.cx, wy - s.cy
    if dx * dx + dy * dy <= SLOT_R * SLOT_R then return s end
  end
  return nil
end

function Game:minimapRect()
  return VW - 20, TOP_H + 4, 16, self:viewH() - TOP_H - 8
end

function Game:onMinimap(x, y)
  local mx, my, mw, mh = self:minimapRect()
  return mh >= 24 and x >= mx - 2 and x < mx + mw + 2 and y >= my and y < my + mh
end

function Game:minimapJump(y)
  local _, my, _, mh = self:minimapRect()
  if mh < 24 then return end
  self:setCamera((y - my) / mh * WORLD_H - self:viewH() / 2, true)
end

function Game:overPanel(x, y)
  return self.panelVisible and x >= self.panelX and x < self.panelX + self.panelW and y >= self.panelY and y < self.panelY + self.panelH
end

function Game:isWorldPoint(x, y)
  return y > TOP_H and y < self:viewH() and not self:onMinimap(x, y) and not self:overPanel(x, y)
end

function Game:setPaused(v)
  if self.state == "over" then v = false end
  self.paused = v
  self.confirmNew = 0
end

function Game:toggleSpeed()
  if self.state == "over" then return end
  self.speed = self.speed == 2 and 1 or 2
  self.meta.speed = self.speed
  self.metaDirty = true
  self:notify(self.speed == 2 and "FAST FORWARD" or "NORMAL SPEED")
end

function Game:roll()
  if self.state == "over" or self.rolling > 0 then return end
  if self.hand then
    self:notify("PLACE YOUR WEAPON FIRST")
    return
  end
  self.offer = nil
  self.rollResult = pickWeapon()
  self.rolling = ROLL_TIME
  self.rollTick = 0
end

function Game:buy()
  local offer = self.offer
  if self.state == "over" or self.hand then return end
  if not offer then
    self:notify(self.rolling > 0 and "WAIT FOR THE ROLL" or "ROLL FIRST")
    return
  end
  if self.money < offer.cost then
    self:notify("NOT ENOUGH CASH")
    return
  end
  self:addMoney(-offer.cost)
  self.hand = { def = offer, level = 1, spent = offer.cost, origin = nil, kills = 0 }
  self.offer = nil
  self.selected = nil
  self:notify("PICK A SAND SLOT")
end

function Game:cancelHand()
  local hand = self.hand
  if not hand then return false end
  self.hand = nil
  if hand.origin and not hand.origin.turret then
    self:placeTurret(hand.origin, hand)
  else
    self:addMoney(hand.spent)
    self:notify("REFUNDED")
    self:markDirty()
  end
  return true
end

function Game:placeTurret(slot, hand)
  local t = Turret.new(hand.def, slot, hand.level, hand.spent, hand.kills)
  slot.turret = t
  self.turrets[#self.turrets + 1] = t
  self:puff(slot.cx, slot.cy + 4, 10, DUST, 40)
  self:markDirty()
  return t
end

function Game:removeTurret(t)
  removeValue(self.turrets, t)
  if t.slot.turret == t then t.slot.turret = nil end
  t.target = nil
  if self.selected == t then self.selected = nil end
end

function Game:clickSlot(slot)
  if self.hand then
    if slot.turret then
      self:notify("SLOT TAKEN")
      return
    end
    local hand = self.hand
    self.hand = nil
    self:placeTurret(slot, hand)
    return
  end
  if slot.turret then
    self.selected = (self.selected == slot.turret) and nil or slot.turret
  else
    self.selected = nil
  end
end

function Game:upgradeSelected()
  local t = self.selected
  if not t or self.state == "over" then return end
  local cost = t:upgradeCost()
  if not cost then
    self:notify("MAX LEVEL")
    return
  end
  if self.money < cost then
    self:notify("NOT ENOUGH CASH")
    return
  end
  self:addMoney(-cost)
  t.spent = t.spent + cost
  t:setLevel(t.level + 1)
  self:puff(t.x, t.y, 14, SPARK, 50)
  self:addFloater(L.levelUp(t.level), t.x, t.y - 14, C.green)
  self:markDirty()
end

function Game:sellSelected()
  local t = self.selected
  if not t or self.state == "over" then return end
  local value = t:sellValue()
  self:removeTurret(t)
  self:addMoney(value)
  self:addFloater(L.plus(value), t.x, t.y - 12, C.gold)
  self:puff(t.x, t.y, 10, DUST, 40)
  self:markDirty()
end

function Game:moveSelected()
  local t = self.selected
  if not t or self.hand or self.state == "over" then return end
  self:removeTurret(t)
  self.hand = { def = t.def, level = t.level, spent = t.spent, origin = t.slot, kills = t.kills }
  self:notify("PICK A NEW SLOT")
end

function Game:startWave()
  if self.state ~= "build" or self.paused then return end
  if self.hand then
    self:notify("PLACE YOUR WEAPON FIRST")
    return
  end
  if #self.turrets == 0 then
    self:notify("PLACE A WEAPON FIRST")
    return
  end
  self.waveSnapshot = self:serializeRun()
  self.state = "wave"
  self.waveTotal = waveCount(self.wave)
  self.spawnQueue = self.waveTotal
  self.spawnTimer = 1
  self:banner(L.wave(self.wave), nil, C.cream, 1.6)
  self:saveRun()
end

function Game:finishWave()
  local bonus = waveBonus(self.wave)
  self:addMoney(bonus)
  self:banner(L.cleared(self.wave), L.plus(bonus), C.green, 2.2)
  if self.wave > self.meta.best then self.meta.best = self.wave end
  self.wave = self.wave + 1
  self.state = "build"
  self.waveSnapshot = nil
  self.metaDirty = true
  self:saveRun()
  self:saveMetaNow()
end

function Game:gameOver()
  if self.state == "over" then return end
  self.state = "over"
  self.overClock = 0
  self.hand, self.selected, self.offer = nil, nil, nil
  self.rolling, self.rollResult = 0, nil
  self.waveSnapshot = nil
  self.bannerText = nil
  self.paused = false
  removeSave(SAVE_RUN)
  self.metaDirty = true
  self:saveMetaNow()
end

function Game:spawnZombie()
  if #self.zombies >= MAX_ZOMBIES then return false end
  local zt = pickZombieType(self.wave)
  local z = zombiePool.get()
  self.nextId = self.nextId + 1
  local hp = max(1, floor(waveHp(self.wave) * zt.hp + 0.5))
  z.id, z.alive, z.type = self.nextId, true, zt
  z.x, z.y, z.vx, z.vy = rnd(ROAD_L + 16, ROAD_R - 16), -14, 0, 0
  z.hp, z.maxHp = hp, hp
  z.speed = waveSpeed(self.wave) * zt.speed * rnd(0.85, 1.15)
  z.t, z.phase, z.freq, z.amp = rnd(0, 6), rnd(0, TAU), rnd(0.7, 1.8), rnd(3, 9) * zt.sway
  z.flash, z.step = 0, rnd(0, 10)
  self.zombies[#self.zombies + 1] = z
  return true
end

function Game:updateSpawning(dt)
  if self.spawnQueue <= 0 then return end
  self.spawnTimer = self.spawnTimer - dt
  if self.spawnTimer <= 0 then
    if self:spawnZombie() then
      self.spawnQueue = self.spawnQueue - 1
      self.spawnTimer = waveInterval(self.wave) * rnd(0.6, 1.4)
    else
      self.spawnTimer = 0.25
    end
  end
end

function Game:damageBarricade(z)
  local dmg = z.type.damage
  self.life = max(0, self.life - dmg)
  self.shake, self.hurtFlash, self.barricadeHit = 0.25, 0.35, 0.2
  self:addFloater(L.hurt(dmg), z.x, BARRICADE_Y - 8, C.red)
  self:puff(z.x, BARRICADE_Y + 6, 8, WOOD, 60)
  self:blood(z.x, z.y, 6, 60, BARRICADE_Y)
  if self.life <= 0 then self:gameOver() end
end

function Game:updateZombies(dt)
  local zs = self.zombies
  local limit = BARRICADE_Y - 2
  for i = 1, #zs do
    local z = zs[i]
    if z.alive then
      z.t = z.t + dt
      z.vx = cos(z.t * z.freq + z.phase) * z.amp
      z.vy = z.speed
      z.x = clamp(z.x + z.vx * dt, ROAD_L + 10, ROAD_R - 10)
      z.y = z.y + z.vy * dt
      z.step = z.step + z.vy * dt
      if z.flash > 0 then z.flash = z.flash - dt end
      if z.y + z.type.hitH >= limit then
        z.alive = false
        self:damageBarricade(z)
      end
    end
  end
end

function Game:sweepZombies()
  local zs = self.zombies
  local n, j = #zs, 0
  for i = 1, n do
    local z = zs[i]
    if z.alive then
      j = j + 1
      zs[j] = z
    else
      zombiePool.put(z)
    end
  end
  for i = j + 1, n do zs[i] = nil end
end

function Game:bucketIndex(y)
  return clamp(floor((y + 32) / BUCKET) + 1, 1, self.bucketCount)
end

function Game:rebuildBuckets()
  local buckets = self.buckets
  for i = 1, self.bucketCount do
    local b = buckets[i]
    b.old, b.n = b.n, 0
  end
  local zs = self.zombies
  for i = 1, #zs do
    local z = zs[i]
    if z.alive then
      local b = buckets[self:bucketIndex(z.y)]
      b.n = b.n + 1
      b[b.n] = z
    end
  end
  for i = 1, self.bucketCount do
    local b = buckets[i]
    for j = b.n + 1, b.old do b[j] = nil end
  end
end

function Game:findTarget(x, y, range2)
  local best, bestY = nil, -huge
  local zs = self.zombies
  for i = 1, #zs do
    local z = zs[i]
    if z.alive and z.y > -4 and z.y > bestY then
      local dx, dy = z.x - x, z.y - y
      if dx * dx + dy * dy <= range2 then best, bestY = z, z.y end
    end
  end
  return best
end

function Game:fire(turret)
  local def = turret.def
  local bullets = self.bullets
  for p = 1, def.pellets do
    if #bullets >= MAX_BULLETS then break end
    local a
    if def.pellets > 1 then
      a = turret.angle + def.spread * ((p - 1) / (def.pellets - 1) * 2 - 1) + rnd(-0.04, 0.04)
    else
      a = turret.angle + rnd(-def.spread, def.spread)
    end
    local dx, dy = cos(a), sin(a)
    local b = bulletPool.get()
    b.x, b.y = turret.x + dx * def.muzzle, turret.y + dy * def.muzzle
    b.dx, b.dy, b.angle = dx, dy, a
    b.speed = def.speed * (def.pellets > 1 and rnd(0.85, 1.1) or 1)
    b.damage, b.pierce, b.lastHit = turret.damage, def.pierce, 0
    b.dist, b.maxDist = 0, turret.range * 1.25
    b.small, b.owner = def.pellets > 1, turret
    bullets[#bullets + 1] = b
  end
  turret.recoil, turret.kick, turret.flash = def.recoil, def.kick, FLASH_TIME
  local side = cos(turret.angle) >= 0 and -1 or 1
  self:emit(turret.x, turret.y, side * rnd(15, 40), rnd(-70, -40), 0.9, 1, BRASS, 240, turret.y + 8)
end

function Game:killZombie(z, owner)
  z.alive = false
  self.kills = self.kills + 1
  self.meta.total = self.meta.total + 1
  self:addMoney(KILL_REWARD)
  self:addFloater(L.plus(KILL_REWARD), z.x, z.y - 10, C.gold)
  self:blood(z.x, z.y, 14, 90, z.y + 6)
  self:addDecal(z.x, z.y + 3)
  if owner then owner.kills = owner.kills + 1 end
end

function Game:hitZombie(z, b)
  z.hp = z.hp - b.damage
  z.flash = 0.08
  self:blood(b.x, b.y, 3, 50, z.y + z.type.h * 0.5)
  if z.hp <= 0 then self:killZombie(z, b.owner) end
end

function Game:stepBullet(b, dt)
  local travel = b.speed * dt
  local n = max(1, ceil(travel / 4))
  local sub = travel / n
  local buckets = self.buckets
  for _ = 1, n do
    b.x, b.y = b.x + b.dx * sub, b.y + b.dy * sub
    b.dist = b.dist + sub
    local bi = self:bucketIndex(b.y)
    for k = max(1, bi - 1), min(self.bucketCount, bi + 1) do
      local bucket = buckets[k]
      for j = 1, bucket.n do
        local z = bucket[j]
        if z.alive and z.id ~= b.lastHit and abs(b.x - z.x) <= z.type.hitW and abs(b.y - z.y) <= z.type.hitH then
          self:hitZombie(z, b)
          b.pierce = b.pierce - 1
          b.lastHit = z.id
          if b.pierce <= 0 then return true end
        end
      end
    end
  end
  return b.dist >= b.maxDist or b.x < -10 or b.x > WORLD_W + 10 or b.y < -40 or b.y > WORLD_H + 10
end

function Game:updateBullets(dt)
  local list = self.bullets
  for i = #list, 1, -1 do
    local b = list[i]
    if self:stepBullet(b, dt) then
      swapRemove(list, i)
      b.owner = nil
      bulletPool.put(b)
    end
  end
end

function Game:updateParticles(dt)
  local list = self.particles
  for i = #list, 1, -1 do
    local p = list[i]
    p.life = p.life - dt
    if p.life <= 0 then
      swapRemove(list, i)
      p.color = nil
      particlePool.put(p)
    else
      p.vy = p.vy + p.grav * dt
      p.x, p.y = p.x + p.vx * dt, p.y + p.vy * dt
      if p.floorY and p.y > p.floorY then
        p.y = p.floorY
        p.vy = -p.vy * 0.25
        p.vx = p.vx * 0.6
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
    if f.life <= 0 then
      swapRemove(list, i)
      f.text, f.color = nil, nil
      floaterPool.put(f)
    end
  end
end

function Game:updateDecals(dt)
  local decals = self.decals
  for i = 1, MAX_DECALS do
    local d = decals[i]
    if d.life > 0 then
      d.life = d.life - dt
      if d.life <= 0 then d.sprite = nil end
    end
  end
end

function Game:updateRoll(dt)
  self.reveal = max(0, self.reveal - dt)
  if self.rolling <= 0 then return end
  self.rolling = self.rolling - dt
  self.rollTick = self.rollTick - dt
  if self.rollTick <= 0 then
    self.rollShow = self.rollShow % #WEAPONS + 1
    self.rollTick = 0.05 + (1 - max(0, self.rolling) / ROLL_TIME) * 0.16
  end
  if self.rolling <= 0 then
    self.rolling = 0
    self.offer, self.rollResult = self.rollResult, nil
    if self.offer then self.rollShow = self.offer.index end
    self.reveal = 0.6
  end
end

function Game:step(dt)
  self.clock = self.clock + dt
  self.shake = max(0, self.shake - dt)
  self.moneyFlash = max(0, self.moneyFlash - dt)
  self.hurtFlash = max(0, self.hurtFlash - dt)
  self.barricadeHit = max(0, self.barricadeHit - dt)
  self:updateRoll(dt)
  if self.state == "over" then
    self.overClock = self.overClock + dt
  elseif self.state == "wave" then
    self:updateSpawning(dt)
    self:updateZombies(dt)
  end
  self:rebuildBuckets()
  if self.state ~= "over" then
    for i = 1, #self.turrets do self.turrets[i]:update(dt, self) end
  end
  self:updateBullets(dt)
  self:sweepZombies()
  self:updateParticles(dt)
  self:updateFloaters(dt)
  self:updateDecals(dt)
  if self.state == "wave" and self.spawnQueue <= 0 and #self.zombies == 0 then self:finishWave() end
end

function Game:layoutTurretPanel()
  local u = self.ui
  local t = self.selected
  local show = t ~= nil and self.state ~= "over" and not self.paused
  u.upgrade.visible, u.sell.visible, u.move.visible = show, show, show
  self.panelVisible = show
  if not show then return end
  local pw, ph = 76, 52
  local sx = t.slot.side == 1 and (t.slot.cx + 17) or (t.slot.cx - 17 - pw)
  local sy = floor(t.slot.cy - self.camY - ph / 2)
  sy = max(TOP_H + 3, min(sy, self:viewH() - ph - 3))
  self.panelX, self.panelY, self.panelW, self.panelH = sx, sy, pw, ph
  u.upgrade:place(sx + 5, sy + 14, pw - 10, 11)
  u.sell:place(sx + 5, sy + 27, pw - 10, 11)
  u.move:place(sx + 5, sy + 40, pw - 10, 9)
  local cost = t:upgradeCost()
  if cost then
    u.upgrade.label = L.upgrade(cost)
    u.upgrade.enabled = self.money >= cost
  else
    u.upgrade.label = "MAX LEVEL"
    u.upgrade.enabled = false
  end
  u.sell.label = L.sell(t:sellValue())
  u.move.enabled = self.hand == nil
end

function Game:syncUi()
  local u = self.ui
  local active = self.state ~= "over" and not self.paused
  u.roll.enabled = active and self.rolling <= 0 and self.hand == nil
  u.buy.enabled = active and self.offer ~= nil and self.hand == nil and self.money >= self.offer.cost
  u.start.visible = self.state == "build"
  u.start.enabled = active and #self.turrets > 0 and self.hand == nil
  u.speed.label = self.speed == 2 and "2X" or "1X"
  u.speed.enabled = self.state ~= "over"
  u.pause.enabled = active
  u.resume.visible, u.newRun.visible, u.quit.visible = self.paused, self.paused, self.paused
  u.newRun.label = self.confirmNew > 0 and "SURE?" or "NEW RUN"
  self:layoutTurretPanel()
end

function Game:frame(dt)
  self.realClock = self.realClock + dt
  if self.toastText then
    self.toastLife = self.toastLife - dt
    if self.toastLife <= 0 then self.toastText = nil end
  end
  if self.bannerText then
    self.bannerLife = self.bannerLife - dt
    if self.bannerLife <= 0 then self.bannerText = nil end
  end
  self.savedFlash = max(0, self.savedFlash - dt)
  self.confirmNew = max(0, self.confirmNew - dt)
  if not self.paused then
    local dir = 0
    if love.keyboard.isDown("w", "up") then dir = dir - 1 end
    if love.keyboard.isDown("s", "down") then dir = dir + 1 end
    if dir ~= 0 then self:setCamera(self.camTarget + dir * SCROLL_SPEED * dt) end
    self.acc = self.acc + dt * self.speed
    local steps, cap = 0, MAX_STEPS * self.speed
    while self.acc >= FIXED_DT and steps < cap do
      self:step(FIXED_DT)
      self.acc = self.acc - FIXED_DT
      steps = steps + 1
    end
    if steps >= cap then self.acc = 0 end
  end
  self.camY = self.camY + (self.camTarget - self.camY) * min(1, dt * 14)
  if abs(self.camTarget - self.camY) < 0.1 then self.camY = self.camTarget end
  self:syncUi()
  self:autosave(dt)
end

function Game:click(x, y)
  local u = self.ui
  if self.paused then
    if u.resume:contains(x, y) then
      self:setPaused(false)
    elseif u.newRun:contains(x, y) then
      if self.confirmNew > 0 then self:newRun() else self.confirmNew = 2.5 end
    elseif u.quit:contains(x, y) then
      love.event.quit()
    end
    return
  end
  if self.state == "over" then
    if self.overClock > 0.8 then self:newRun() end
    return
  end
  if self:overPanel(x, y) then
    if u.upgrade:contains(x, y) then
      self:upgradeSelected()
    elseif u.sell:contains(x, y) then
      self:sellSelected()
    elseif u.move:hit(x, y) then
      self:moveSelected()
    end
    return
  end
  if y >= self:viewH() then
    if u.roll:contains(x, y) then
      self:roll()
    elseif u.buy:contains(x, y) then
      self:buy()
    elseif u.start:contains(x, y) then
      self:startWave()
    elseif u.speed:contains(x, y) then
      self:toggleSpeed()
    elseif u.pause:contains(x, y) then
      self:setPaused(true)
    end
    return
  end
  if y < TOP_H or self:onMinimap(x, y) then return end
  local slot = self:slotAt(x, y + self.camY)
  if slot then
    self:clickSlot(slot)
    return
  end
  self.selected = nil
end

function Game:cancelAction()
  if self.paused or self.state == "over" then return end
  if not self:cancelHand() then self.selected = nil end
end

function Game:key(k)
  if k == "escape" then
    if self.paused then
      self:setPaused(false)
    elseif self.hand then
      self:cancelHand()
    elseif self.selected then
      self.selected = nil
    elseif self.state ~= "over" then
      self:setPaused(true)
    end
    return
  end
  if k == "p" then
    self:setPaused(not self.paused)
    return
  end
  if k == "-" or k == "kp-" then
    changeZoom(-1)
    return
  end
  if k == "=" or k == "+" or k == "kp+" then
    changeZoom(1)
    return
  end
  if self.paused then
    if k == "n" then
      if self.confirmNew > 0 then self:newRun() else self.confirmNew = 2.5 end
    elseif k == "q" then
      love.event.quit()
    end
    return
  end
  if self.state == "over" then
    if (k == "return" or k == "space" or k == "r") and self.overClock > 0.8 then self:newRun() end
    return
  end
  if k == "space" or k == "return" then
    self:startWave()
  elseif k == "r" then
    self:roll()
  elseif k == "b" then
    self:buy()
  elseif k == "f" or k == "tab" then
    self:toggleSpeed()
  elseif k == "u" then
    self:upgradeSelected()
  elseif k == "x" or k == "delete" then
    self:sellSelected()
  elseif k == "m" then
    self:moveSelected()
  elseif k == "home" then
    self:setCamera(0)
  elseif k == "end" then
    self:setCamera(self:maxCam())
  elseif k == "pageup" then
    self:setCamera(self.camTarget - self:viewH() * 0.8)
  elseif k == "pagedown" then
    self:setCamera(self.camTarget + self:viewH() * 0.8)
  end
end

function Game:drawDecals(top, bottom)
  local decals = self.decals
  for i = 1, MAX_DECALS do
    local d = decals[i]
    if d.life > 0 and d.sprite and d.y > top and d.y < bottom then
      lg.setColor(1, 1, 1, min(1, d.life / 8) * 0.85)
      spr(d.sprite, d.x, d.y, 0, d.flip, 1, floor(d.sprite.w / 2), floor(d.sprite.h / 2))
    end
  end
end

function Game:drawSlots(top, bottom, hover)
  local pulse = 0.55 + 0.45 * sin(self.realClock * 6)
  for i = 1, #self.slots do
    local s = self.slots[i]
    if s.cy > top and s.cy < bottom then
      if s.turret then
        lg.setColor(1, 1, 1, 1)
        spr(SP.padFull, s.cx - 13, s.cy - 13)
      else
        if self.hand then
          lg.setColor(1, 0.92, 0.55, 0.6 + 0.4 * pulse)
        elseif hover == s then
          lg.setColor(1, 1, 1, 1)
        else
          lg.setColor(1, 1, 1, 0.75)
        end
        spr(SP.padEmpty, s.cx - 13, s.cy - 13)
      end
    end
  end
end

function Game:drawBarricade()
  local idx = 3
  if self.life > MAX_LIFE * 0.66 then
    idx = 1
  elseif self.life > MAX_LIFE * 0.33 then
    idx = 2
  end
  local ox = self.barricadeHit > 0 and rndInt(-1, 1) or 0
  lg.setColor(1, 1, 1, 1)
  spr(BARRICADE[idx], floor(ROAD_C - 76) + ox, BARRICADE_Y)
end

function Game:drawZombies(top, bottom)
  local zs = self.zombies
  sortByY(zs)
  for i = 1, #zs do
    local z = zs[i]
    if z.alive and z.y > top and z.y < bottom then
      local zt = z.type
      local x, y = snap(z.x), snap(z.y)
      local sh = zt.shadowSpr
      lg.setColor(1, 1, 1, 1)
      spr(sh, x - floor(sh.w / 2), y + floor(zt.h / 2) - 2)
      if z.flash > 0 then lg.setColor(1, 0.4, 0.4, 1) end
      spr((floor(z.step / 7) % 2 == 0) and zt.sprA or zt.sprB, x, y, 0, 1, 1, zt.w / 2, zt.h / 2)
      if z.hp < z.maxHp then
        local bw = zt.w - 2
        local bx, by = x - floor(bw / 2), y - floor(zt.h / 2) - 4
        setColor(C.black, 0.8)
        lg.rectangle("fill", bx - 1, by - 1, bw + 2, 3)
        setColor(C.barBack)
        lg.rectangle("fill", bx, by, bw, 1)
        setColor(C.barHp)
        lg.rectangle("fill", bx, by, max(1, floor(bw * z.hp / z.maxHp + 0.5)), 1)
      end
    end
  end
end

function Game:drawBullets(top, bottom)
  local bs = self.bullets
  if #bs == 0 then return end
  local px, glow, flare = SP.pixel, SP.glow, SP.flare
  lg.setBlendMode("add")
  for i = 1, #bs do
    local b = bs[i]
    if b.y > top and b.y < bottom then
      setColor(GLOW, 0.45)
      lg.draw(atlas, px.quad, b.x, b.y, b.angle, -min(b.dist, b.small and 4 or 9), 1, 0, 0.5)
      lg.setColor(1, 1, 1, 0.7)
      spr(glow, snap(b.x), snap(b.y), 0, 1, 1, 2, 2)
    end
  end
  lg.setBlendMode("alpha")
  lg.setColor(1, 1, 1, 1)
  for i = 1, #bs do
    local b = bs[i]
    if b.y > top and b.y < bottom then spr(flare, snap(b.x), snap(b.y), b.angle, 1, 1, 5, 1) end
  end
end

function Game:drawParticles(top, bottom)
  local list = self.particles
  local q = SP.pixel.quad
  for i = 1, #list do
    local p = list[i]
    if p.y > top and p.y < bottom then
      setColor(p.color, min(1, p.life / p.max * 1.5))
      lg.draw(atlas, q, snap(p.x), snap(p.y), 0, p.size, p.size)
    end
  end
end

function Game:drawFloaters(top, bottom)
  local list = self.floaters
  for i = 1, #list do
    local f = list[i]
    if f.y > top and f.y < bottom then
      textCenter(f.text, f.x, f.y, 1, f.color, min(1, f.life * 2.5), true)
    end
  end
end

function Game:drawPreview(hover)
  local hand = self.hand
  if not (hand and hover and not hover.turret) then return end
  local def = hand.def
  lg.setColor(1, 1, 1, 0.6)
  local right = hover.side == 1
  spr(SP[def.sprite], hover.cx, hover.cy - 1, right and 0 or pi, 1, right and 1 or -1, def.pivotX, def.pivotY)
end

function Game:drawRings(hover)
  local phase = self.realClock * 0.4
  local t = self.selected
  if t then
    dottedRing(t.x, t.y, t.range, phase, C.ring, 0.75)
    dottedRing(t.slot.cx, t.slot.cy, 14, -phase * 3, C.gold, 1)
  elseif hover and hover.turret and not self.hand then
    dottedRing(hover.turret.x, hover.turret.y, hover.turret.range, phase, C.ring, 0.35)
  end
  if self.hand and hover and not hover.turret then
    dottedRing(hover.cx, hover.cy, self.hand.def.range * (1 + 0.1 * (self.hand.level - 1)), phase, C.ring, 0.6)
  end
end

function Game:drawWorld(mx, my)
  local viewH = self:viewH()
  local camY = floor(self.camY + 0.5)
  local ox, oy = 0, 0
  if self.shake > 0 then ox, oy = rndInt(-1, 1), rndInt(-1, 1) end
  local hover = nil
  if not self.paused and self.state ~= "over" and self:isWorldPoint(mx, my) then
    hover = self:slotAt(mx, my + camY)
  end
  lg.push()
  lg.translate(ox, oy - camY)
  lg.setColor(1, 1, 1, 1)
  lg.draw(Assets.background, 0, 0)
  local top, bottom = camY - 30, camY + viewH + 30
  self:drawDecals(top, bottom)
  self:drawSlots(top, bottom, hover)
  self:drawBarricade()
  self:drawZombies(top, bottom)
  for i = 1, #self.turrets do
    local t = self.turrets[i]
    if t.y > top and t.y < bottom then t:draw() end
  end
  self:drawPreview(hover)
  self:drawBullets(top, bottom)
  self:drawParticles(top, bottom)
  self:drawFloaters(top, bottom)
  self:drawRings(hover)
  lg.pop()
end

function Game:drawTopBar()
  setColor(C.hudBg, 0.86)
  lg.rectangle("fill", 0, 0, VW, TOP_H)
  setColor(C.hudEdge)
  lg.rectangle("fill", 0, TOP_H, VW, 1)
  text(L.wave(self.wave), 5, 5, 1, C.cream, 1, true)
  local hx = 46
  lg.setColor(1, 1, 1, 1)
  spr(SP.heart, hx, 4)
  local bx = hx + 10
  local bw = MAX_LIFE * 3
  setColor(C.black, 0.8)
  lg.rectangle("fill", bx - 1, 4, bw + 1, 7)
  local filled = self.life * 3
  setColor(C.hpBack)
  lg.rectangle("fill", bx, 5, bw - 1, 5)
  if filled > 0 then
    setColor(self.hurtFlash > 0 and C.white or C.hp)
    lg.rectangle("fill", bx, 5, filled - 1, 5)
    setColor(C.hpHi)
    lg.rectangle("fill", bx, 5, filled - 1, 1)
  end
  setColor(C.black, 0.8)
  for i = 1, MAX_LIFE - 1 do lg.rectangle("fill", bx + i * 3 - 1, 5, 1, 5) end
  text(L.num(self.life), bx + bw + 4, 5, 1, self.life <= 5 and C.red or C.cream, 1, true)
  local cx = 198
  if self.state == "wave" then
    local total = max(1, self.waveTotal)
    local remaining = self.spawnQueue + #self.zombies
    local ratio = clamp(1 - remaining / total, 0, 1)
    local pw = 90
    local px = floor(cx - pw / 2)
    setColor(C.black, 0.8)
    lg.rectangle("fill", px - 1, 3, pw + 2, 9)
    setColor(C.progBack)
    lg.rectangle("fill", px, 4, pw, 7)
    setColor(C.prog)
    lg.rectangle("fill", px, 4, floor(pw * ratio), 7)
    textCenter(L.left(remaining), cx, 5, 1, C.cream, 1, true)
  elseif self.state == "build" then
    textCenter(self:hint(), cx, 5, 1, C.cream, 0.75 + 0.25 * sin(self.realClock * 3), true)
  end
  if self.speed == 2 then text(">>", VW - 84, 5, 1, C.gold, 1, true) end
  lg.setColor(1, 1, 1, 1)
  spr(SP.skull, VW - 62, 4)
  text(L.num(self.kills), VW - 52, 5, 1, C.cream, 1, true)
end

function Game:drawMinimap()
  local x, y, w, h = self:minimapRect()
  if h < 24 then return end
  local s = h / WORLD_H
  setColor(C.black, 0.85)
  lg.rectangle("fill", x - 1, y - 1, w + 2, h + 2)
  setColor(C.mapSand)
  lg.rectangle("fill", x, y, w, h)
  local rl = x + floor(ROAD_L / WORLD_W * w + 0.5)
  local rr = x + floor(ROAD_R / WORLD_W * w + 0.5)
  setColor(C.mapRoad)
  lg.rectangle("fill", rl, y, rr - rl, h)
  setColor(WOOD[1])
  lg.rectangle("fill", rl, y + floor(BARRICADE_Y * s), rr - rl, 1)
  local q = SP.pixel.quad
  setColor(C.gold)
  for i = 1, #self.turrets do
    local t = self.turrets[i]
    lg.draw(atlas, q, x + floor(t.x / WORLD_W * w), y + floor(t.y * s))
  end
  setColor(C.red)
  for i = 1, #self.zombies do
    local z = self.zombies[i]
    if z.y >= 0 then lg.draw(atlas, q, x + floor(z.x / WORLD_W * w), y + floor(z.y * s)) end
  end
  setColor(C.white, 0.85)
  frameRect(x - 1, y + floor(self.camY * s), w + 2, max(3, floor(self:viewH() * s)))
end

function Game:drawIndicators()
  if self.state ~= "wave" then return end
  local above = 0
  local limit = self.camY - 4
  local zs = self.zombies
  for i = 1, #zs do
    if zs[i].y < limit and zs[i].y > -10 then above = above + 1 end
  end
  if above > 0 then
    local x = floor(ROAD_C)
    local blink = floor(self.realClock * 4) % 2 == 0
    lg.setColor(1, 1, 1, blink and 1 or 0.55)
    spr(SP.arrow, x - 9, TOP_H + 4)
    text(L.num(above), x - 2, TOP_H + 3, 1, C.red, 1, true)
  end
end

function Game:drawTurretPanel(mx, my, down)
  if not self.panelVisible then return end
  local t = self.selected
  local x, y, w, h = self.panelX, self.panelY, self.panelW, self.panelH
  setColor(C.black, 0.9)
  lg.rectangle("fill", x - 1, y - 1, w + 2, h + 2)
  setColor(C.panel, 0.95)
  lg.rectangle("fill", x, y, w, h)
  setColor(RARITY[t.def.rarity].color)
  lg.rectangle("fill", x, y, w, 1)
  text(t.def.name, x + 5, y + 4, 1, C.white)
  textRight(L.level(t.level), x + w - 4, y + 4, 1, C.gold)
  local u = self.ui
  u.upgrade:draw(mx, my, down)
  u.sell:draw(mx, my, down)
  u.move:draw(mx, my, down)
end

function Game:drawDisplay(x, y, w, h)
  local cx = x + w / 2
  setColor(C.black)
  lg.rectangle("fill", x - 1, y - 1, w + 2, h + 2)
  setColor(C.panel)
  lg.rectangle("fill", x, y, w, h)
  setColor(C.white, 0.03)
  for ry = y + 1, y + h - 1, 2 do lg.rectangle("fill", x, ry, w, 1) end
  if self.rolling > 0 then
    local def = WEAPONS[self.rollShow] or WEAPONS[1]
    local s = SP[def.sprite]
    lg.setColor(1, 1, 1, 0.85)
    spr(s, floor(cx - s.w), y + 4, 0, 2, 2)
    textCenter(def.name, cx, y + 22, 1, C.dim)
    if floor(self.realClock * 6) % 2 == 0 then textCenter("? ? ?", cx, y + 30, 1, C.gold) end
  elseif self.offer then
    local def = self.offer
    local rar = RARITY[def.rarity]
    setColor(rar.color, 0.55 + 0.45 * sin(self.realClock * 5) + self.reveal)
    frameRect(x, y, w, h)
    if self.reveal > 0 then
      setColor(rar.color, self.reveal * 0.5)
      lg.rectangle("fill", x + 1, y + 1, w - 2, h - 2)
    end
    local s = SP[def.sprite]
    lg.setColor(1, 1, 1, 1)
    spr(s, floor(cx - s.w), y + 4, 0, 2, 2)
    textCenter(def.name, cx, y + 22, 1, C.white)
    text(L.money(def.cost), x + 5, y + 30, 1, self.money >= def.cost and C.gold or C.red)
    textRight(rar.name, x + w - 4, y + 30, 1, rar.color)
  elseif self.hand then
    textCenter("PLACE IT", cx, y + 12, 1, C.gold)
    textCenter("ON THE SAND", cx, y + 21, 1, C.gold)
  else
    textCenter("ROLL IS", cx, y + 12, 1, C.gray)
    textCenter("FREE!", cx, y + 21, 1, C.green)
  end
end

function Game:drawPanel(mx, my, down)
  local u = self.ui
  local py = self.view.vh - PANEL_H
  setColor(C.ground)
  lg.rectangle("fill", 0, py, VW, PANEL_H)
  setColor(C.groundHi)
  lg.rectangle("fill", 0, py, VW, 1)
  setColor(C.groundLo)
  lg.rectangle("fill", 0, py + 1, VW, 1)
  local bx = 4
  if self.rolling > 0 then bx = bx + ((floor(self.realClock * 30) % 2 == 0) and 1 or -1) end
  lg.setColor(1, 1, 1, 1)
  spr(SP.box, bx, py + 4)
  text("LUCKY BOX", bx + 10, py + 8, 1, C.burn)
  u.roll:draw(mx, my, down)
  u.buy:draw(mx, my, down)
  self:drawDisplay(74, py + 12, 96, 38)

  local rx, ry, rw, rh = 248, py + 4, 132, 22
  setColor(C.black, 0.9)
  lg.rectangle("fill", rx - 1, ry - 1, rw + 2, rh + 2)
  setColor(C.plate)
  lg.rectangle("fill", rx, ry, rw, rh)
  setColor(C.plateHi)
  lg.rectangle("fill", rx, ry, rw, 1)
  lg.rectangle("fill", rx, ry, 1, rh)
  setColor(C.plateLo)
  lg.rectangle("fill", rx, ry + rh - 1, rw, 1)
  lg.setColor(1, 1, 1, 1)
  spr(SP.coin, rx + 6, ry + 8)
  text(L.money(floor(self.money)), rx + 17, ry + 6, 2, self.moneyFlash > 0 and self.moneyFlashColor or C.gold, 1, true)
  textRight("CASH", rx + rw - 5, ry + 4, 1, C.gray)

  if self.state == "build" then
    u.start:draw(mx, my, down)
  else
    local px, ppy, pw, ph = 248, py + 30, 88, 24
    setColor(C.black, 0.9)
    lg.rectangle("fill", px - 1, ppy - 1, pw + 2, ph + 2)
    setColor(C.progBack)
    lg.rectangle("fill", px, ppy, pw, ph)
    if self.state == "wave" then
      local total = max(1, self.waveTotal)
      local remaining = self.spawnQueue + #self.zombies
      setColor(C.prog)
      lg.rectangle("fill", px, ppy, floor(pw * clamp(1 - remaining / total, 0, 1)), ph)
      textCenter(L.wave(self.wave), px + pw / 2, ppy + 5, 1, C.cream, 1, true)
      textCenter(L.left(remaining), px + pw / 2, ppy + 14, 1, C.cream, 1, true)
    else
      textCenter("GAME OVER", px + pw / 2, ppy + 9, 1, C.red, 1, true)
    end
  end
  u.speed:draw(mx, my, down)
  u.pause:draw(mx, my, down)
end

function Game:drawOverlays(mx, my, down)
  local viewH = self:viewH()
  local vh = self.view.vh
  local cx = VW / 2
  if self.hurtFlash > 0 then
    lg.setColor(0.85, 0.1, 0.08, min(0.8, self.hurtFlash * 1.5))
    lg.rectangle("fill", 0, TOP_H + 1, VW, 2)
    lg.rectangle("fill", 0, viewH - 2, VW, 2)
    lg.rectangle("fill", 0, TOP_H + 1, 2, viewH - TOP_H - 1)
    lg.rectangle("fill", VW - 2, TOP_H + 1, 2, viewH - TOP_H - 1)
  end
  if self.bannerText then
    local a = clamp(self.bannerLife / 0.5, 0, 1) * clamp((self.bannerMax - self.bannerLife) / 0.15, 0, 1)
    local y = floor(viewH * 0.32)
    textCenter(self.bannerText, cx, y, 3, self.bannerColor, a, true)
    if self.bannerSub then textCenter(self.bannerSub, cx, y + 20, 2, C.gold, a, true) end
  end
  if self.toastText then
    local a = clamp(self.toastLife / 0.4, 0, 1)
    local tw = textWidth(self.toastText, 1)
    setColor(C.black, 0.7 * a)
    lg.rectangle("fill", floor(cx - tw / 2) - 5, TOP_H + 6, tw + 10, 11)
    textCenter(self.toastText, cx, TOP_H + 9, 1, C.white, a)
  end
  if self.savedFlash > 0 then
    textRight("SAVED", VW - 26, TOP_H + 5, 1, C.green, min(1, self.savedFlash), true)
  end
  if self.hand and not self.paused then
    lg.setColor(1, 1, 1, 0.9)
    spr(SP[self.hand.def.sprite], floor(mx) + 5, floor(my) + 5)
  end
  if self.state == "over" then
    setColor(C.black, 0.65)
    lg.rectangle("fill", 0, 0, VW, vh)
    local y = floor(vh * 0.26)
    textCenter("GAME OVER", cx, y, 5, C.red, 1, true)
    textCenter(L.reached(self.wave), cx, y + 36, 2, C.cream, 1, true)
    textCenter(L.kills(self.kills), cx, y + 54, 1, C.gray, 1, true)
    textCenter(L.best(self.meta.best), cx, y + 64, 1, C.gold, 1, true)
    if self.overClock > 0.8 and floor(self.realClock * 2) % 2 == 0 then
      textCenter("CLICK TO START A NEW RUN", cx, y + 84, 1, C.white, 1, true)
    end
  end
  if self.paused then
    setColor(C.black, 0.65)
    lg.rectangle("fill", 0, 0, VW, vh)
    local cy = floor(vh / 2)
    textCenter("PAUSED", cx, cy - 64, 3, C.white, 1, true)
    textCenter(L.best(self.meta.best), cx, cy - 42, 1, C.gold, 1, true)
    textCenter(L.total(self.meta.total), cx, cy - 34, 1, C.gray, 1, true)
    local u = self.ui
    u.resume:draw(mx, my, down)
    u.newRun:draw(mx, my, down)
    u.quit:draw(mx, my, down)
    textCenter("SCROLL: WHEEL, DRAG, W/S, MINIMAP", cx, cy + 54, 1, C.gray)
    textCenter("R ROLL  B BUY  SPACE START  F SPEED  P PAUSE", cx, cy + 64, 1, C.gray)
    textCenter("U UPGRADE  X SELL  M MOVE  -/= ZOOM  F11 FULLSCREEN", cx, cy + 74, 1, C.gray)
  end
end

function Game:draw(mx, my, down)
  lg.setFont(Assets.font)
  lg.setColor(1, 1, 1, 1)
  self:drawWorld(mx, my)
  self:drawTopBar()
  self:drawMinimap()
  self:drawIndicators()
  self:drawTurretPanel(mx, my, down)
  self:drawPanel(mx, my, down)
  self:drawOverlays(mx, my, down)
end

computeViewport = function()
  local w, h = lg.getDimensions()
  if w <= 0 or h <= 0 then return end
  local fit = min(w / VW, h / MIN_VH)
  local s
  if fit < 1 then
    s = fit
  else
    local maxS = floor(fit)
    local minS = min(maxS, max(1, ceil(h / MAX_VH)))
    s = clamp(maxS + (meta and meta.zoom or 0), minS, maxS)
  end
  local vh = clamp(floor(h / s), 1, MAX_VH)
  view.scale, view.vh = s, vh
  view.x = floor((w - VW * s) / 2)
  view.y = floor((h - vh * s) / 2)
  if not canvas or canvas:getHeight() ~= vh then
    local old = canvas
    canvas = lg.newCanvas(VW, vh)
    canvas:setFilter("nearest", "nearest")
    if old then old:release() end
  end
  if game then game:onResize() end
end

changeZoom = function(delta)
  if not meta then return end
  local w, h = lg.getDimensions()
  local maxS = max(1, floor(min(w / VW, h / MIN_VH)))
  local minS = min(maxS, max(1, ceil(h / MAX_VH)))
  meta.zoom = clamp(meta.zoom + delta, minS - maxS, 0)
  computeViewport()
  if game then
    game.metaDirty = true
    game:notify(meta.zoom == 0 and "ZOOM: LARGEST" or "ZOOM CHANGED")
  end
end

local function toggleFullscreen()
  local full = not lw.getFullscreen()
  local ok = pcall(lw.setFullscreen, full, "desktop")
  if ok and meta then
    meta.full = full
    if game then game.metaDirty = true end
  end
  computeViewport()
end

local function toVirtual(x, y)
  return (x - view.x) / view.scale, (y - view.y) / view.scale
end

local function protect(fn, ...)
  local ok, err = pcall(fn, ...)
  if not ok then fatalError = tostring(err) end
  return ok
end

local function initialise()
  defaultFont = lg.getFont()
  lf.setIdentity("zombierush")
  meta = loadMeta()
  local dw, dh = lw.getDesktopDimensions()
  dw, dh = dw or 1280, dh or 800
  local w = clamp(floor(dw * 0.8), VW * 2, max(VW * 2, dw))
  local h = clamp(floor(dh * 0.8), MIN_VH * 2, max(MIN_VH * 2, dh))
  local ok = lw.setMode(w, h, { resizable = true, minwidth = VW, minheight = MIN_VH, vsync = 1, fullscreen = meta.full, fullscreentype = "desktop" })
  if not ok then error("could not create the game window") end
  lw.setTitle("Zombie Rush Defense")
  lg.setDefaultFilter("nearest", "nearest", 1)
  lg.setLineStyle("rough")
  buildAssets()
  ui = createUi()
  computeViewport()
  game = Game.new(ui, view, meta)
  game:onResize()
  local fields, list = readSave(SAVE_RUN)
  if fields and game:applyRun(fields, list) then
    game:notify("RUN RESTORED - WAVE " .. game.wave)
  end
  game:setCamera(game:maxCam(), true)
  game:syncUi()
end

local function drawFatal()
  lg.setCanvas()
  lg.origin()
  lg.setBlendMode("alpha")
  lg.clear(0.1, 0.02, 0.02, 1)
  if defaultFont then lg.setFont(defaultFont) end
  lg.setColor(1, 1, 1, 1)
  lg.printf("Something went wrong:\n\n" .. tostring(fatalError) .. "\n\nProgress up to the last autosave is kept.\nPress ESC to quit.", 20, 20, max(100, lg.getWidth() - 40))
end

local function releaseResources()
  if canvas then
    pcall(canvas.release, canvas)
    canvas = nil
  end
  for i = #Assets.owned, 1, -1 do
    local r = Assets.owned[i]
    if r and r.release then pcall(r.release, r) end
    Assets.owned[i] = nil
  end
  zombiePool.clear()
  bulletPool.clear()
  particlePool.clear()
  floaterPool.clear()
end

function love.load()
  local ok, err = pcall(initialise)
  if not ok then fatalError = tostring(err) end
end

function love.resize()
  if not fatalError then protect(computeViewport) end
end

function love.focus(focused)
  if not focused and game and not fatalError and game.state ~= "over" then game:setPaused(true) end
end

function love.update(dt)
  if fatalError or not game then return end
  protect(game.frame, game, min(dt, 0.25))
end

function love.draw()
  if fatalError then
    drawFatal()
    return
  end
  if not game or not canvas then return end
  local mx, my = toVirtual(love.mouse.getPosition())
  lg.setCanvas(canvas)
  lg.clear(0, 0, 0, 1)
  local ok, err = pcall(game.draw, game, mx, my, love.mouse.isDown(1))
  lg.setCanvas()
  lg.setBlendMode("alpha")
  if not ok then
    fatalError = tostring(err)
    drawFatal()
    return
  end
  lg.origin()
  lg.clear(C.letterbox[1], C.letterbox[2], C.letterbox[3], 1)
  lg.setColor(1, 1, 1, 1)
  lg.setBlendMode("alpha", "premultiplied")
  lg.draw(canvas, view.x, view.y, 0, view.scale, view.scale)
  lg.setBlendMode("alpha", "alphamultiply")
end

local pointer = { down = false, button = 0, sx = 0, sy = 0, cam = 0, drag = false, mode = nil }

function love.mousepressed(x, y, button)
  if fatalError or not game then return end
  local vx, vy = toVirtual(x, y)
  if button == 2 then
    protect(game.cancelAction, game)
    return
  end
  if button ~= 1 and button ~= 3 then return end
  pointer.down, pointer.button, pointer.sx, pointer.sy = true, button, vx, vy
  pointer.cam, pointer.drag = game.camTarget, false
  if game.paused or game.state == "over" then
    pointer.mode = "ui"
  elseif game:onMinimap(vx, vy) then
    pointer.mode = "minimap"
    protect(game.minimapJump, game, vy)
  elseif button == 3 or game:isWorldPoint(vx, vy) then
    pointer.mode = "world"
  else
    pointer.mode = "ui"
  end
end

function love.mousemoved(x, y)
  if fatalError or not game or not pointer.down then return end
  local vx, vy = toVirtual(x, y)
  if pointer.mode == "minimap" then
    protect(game.minimapJump, game, vy)
  elseif pointer.mode == "world" then
    if not pointer.drag and (abs(vy - pointer.sy) > 3 or abs(vx - pointer.sx) > 3) then pointer.drag = true end
    if pointer.drag then game:setCamera(pointer.cam - (vy - pointer.sy), true) end
  end
end

function love.mousereleased(x, y, button)
  if not pointer.down or button ~= pointer.button then return end
  local wasDrag, mode = pointer.drag, pointer.mode
  pointer.down, pointer.drag, pointer.mode = false, false, nil
  if fatalError or not game then return end
  if button == 1 and not wasDrag and mode ~= "minimap" then
    local vx, vy = toVirtual(x, y)
    protect(game.click, game, vx, vy)
  end
end

function love.wheelmoved(_, y)
  if fatalError or not game or game.paused then return end
  game:setCamera(game.camTarget - y * 30)
end

function love.keypressed(key)
  if key == "f11" then
    protect(toggleFullscreen)
    return
  end
  if fatalError then
    if key == "escape" then love.event.quit() end
    return
  end
  if game then protect(game.key, game, key) end
end

function love.quit()
  if game and not fatalError then
    pcall(game.saveRun, game)
    pcall(game.saveMetaNow, game)
  elseif meta then
    pcall(writeSave, SAVE_META, serializeMeta(meta))
  end
  releaseResources()
  return false
end