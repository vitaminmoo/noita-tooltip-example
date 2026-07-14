-- Headless smoke test: luajit tools/smoke.lua
--
-- Runs the card renderer outside the game with stubbed Gui*/loc APIs, and prints
-- an ASCII rendering of the Spark Bolt card so it can be eyeballed against the
-- real one. Verifies the reproduction (rows + native geometry) and the added line.
--
-- It cannot exercise the hook (that needs Windows + the game's own memory), which
-- is exactly why the hook is isolated in files/cardhook.lua.

package.path = "./?.lua;" .. package.path

-- ---- stub the Noita API -------------------------------------------------------
local loaded = {}
function dofile_once(path)
	local f = path:gsub("^mods/noita%-tooltip%-example/", "") -- mod path -> repo path
	if loaded[f] == nil then loaded[f] = dofile(f) end
	return loaded[f]
end

local T = { -- the strings the game would return for our $keys
	["$action_light_bullet"] = "Spark bolt",
	["$actiondesc_light_bullet"] = "A weak but enchanting sparkling projectile",
	["$inventory_actiontype"] = "Type",
	["$inventory_actiontype_projectile"] = "Projectile",
	["$inventory_manadrain"] = "Mana drain",
	["$inventory_damage"] = "Damage",
	["$inventory_speed"] = "Speed",
	["$inventory_mod_castdelay"] = "Cast delay",
	["$inventory_mod_spread"] = "Spread",
	["$inventory_mod_critchance"] = "Crit. Chance",
	["$inventory_seconds"] = "$0 s",
	["$inventory_degrees"] = "$0 DEG",
}
function GameTextGetTranslatedOrNot(s) return T[s] or s end

local draws = {} -- everything the card renderer emits
function GuiCreate() return {} end
function GuiStartFrame() end
function GuiGetScreenDimensions() return 640, 360 end
function GuiGetTextDimensions(_, s) return #s * 5, 8 end -- ~5px/char in the pixel font
function GuiGetImageDimensions() return 16, 16 end
function GuiIdPush() end
function GuiIdPop() end
function GuiColorSetForNextWidget() end
function GuiZSet() end
function GuiAnimateBegin() end
function GuiAnimateEnd() end
function GuiAnimateAlphaFadeIn() end
function GuiImage(_, _, x, y, sprite) draws[#draws + 1] = { k = "img", x = x, y = y, s = sprite } end
function GuiImageNinePiece(_, _, x, y, w, h) draws[#draws + 1] = { k = "bg", x = x, y = y, w = w, h = h } end
function GuiText(_, x, y, s) draws[#draws + 1] = { k = "txt", x = x, y = y, s = s } end
function EntityGetFirstComponentIncludingDisabled() return 1 end
function ComponentGetValue2() return "LIGHT_BULLET" end
function print_error(s) error(s) end

-- ---- load the mod exactly as Noita would --------------------------------------
dofile("init.lua")
OnWorldInitialized() -- hook install fails off-Windows; must not throw

local gui = dofile_once("mods/noita-tooltip-example/files/gui.lua")
gui.ready = true -- the stub handle is created; pretend we're inside a frame
local card = dofile_once("mods/noita-tooltip-example/files/card.lua")

-- Rebuild the card the way OnWorldPostUpdate does, from a fake capture at (100, 60).
local meta, rows = _G.tooltip_example_card()
local w, h = card.card_size({ gui = gui }, meta, rows)
local x, y = card.place(100, 60, w, h, gui)
card.draw_card({ gui = gui }, { x = x, y = y, w = w, h = h }, meta, rows)

-- ---- render the draw list as ASCII --------------------------------------------
local grid = {}
local function put(cx, cy, s)
	cx, cy = math.floor((cx - x) / 5), math.floor((cy - y) / 8)
	grid[cy] = grid[cy] or {}
	for i = 1, #s do grid[cy][cx + i] = s:sub(i, i) end
end
for _, d in ipairs(draws) do
	if d.k == "txt" then put(d.x, d.y, d.s)
	elseif d.k == "img" then put(d.x, d.y, (d.s:match("icon_[%w_]+") and "*") or "[]") end
end
local maxy = 0
for cy in pairs(grid) do maxy = math.max(maxy, cy) end
print(("card %dx%d at (%d,%d)  rows=%d  desc lines=%d"):format(w, h, x, y, #rows, #meta.description))
print("+" .. string.rep("-", math.floor(w / 5)) .. "+")
for cy = 0, maxy do
	local line = {}
	for cx = 1, math.floor(w / 5) do line[cx] = (grid[cy] and grid[cy][cx]) or " " end
	print("|" .. table.concat(line) .. "|")
end
print("+" .. string.rep("-", math.floor(w / 5)) .. "+")

-- ---- assertions ---------------------------------------------------------------
local function check(cond, msg) if not cond then error("FAIL: " .. msg, 0) end end
local text = {}
for _, d in ipairs(draws) do if d.k == "txt" then text[#text + 1] = d.s end end
local joined = table.concat(text, "\n")

check(joined:find("SPARK BOLT", 1, true), "title is uppercased")
check(not joined:find("SPARK BOLT (", 1, true), "unlimited-use spell gets no (N) suffix")
check(joined:find("A weak but enchanting sparkling projectile", 1, true), "vanilla description line kept")
check(joined:find("Is this what you're after, GrahamBurger?", 1, true), "the added description line is drawn")
for _, v in ipairs({ "Type", "Projectile", "Mana drain", "5", "Damage", "3", "Speed", "800",
	"Cast delay", "+0.05 s", "Spread", "-1 DEG", "Crit. Chance", "+5%" }) do
	check(joined:find(v, 1, true), "native card content present: " .. v)
end

-- Geometry: two description lines push the row block down exactly one line (8px)
-- from the native 37, and the first row sits there.
local first_row_y
for _, d in ipairs(draws) do
	if d.k == "txt" and d.s == "Type" then first_row_y = d.y - y end
end
check(first_row_y == 37 + 8 + card.TEXT_DY, "rows shifted one line for the 2nd desc line, got " .. tostring(first_row_y))

-- The 16px gaps after "Mana drain" and "Speed" (the native blank divider lines).
local ys = {}
for _, d in ipairs(draws) do if d.k == "txt" then ys[d.s] = d.y - y end end
check(ys["Damage"] - ys["Mana drain"] == 16, "blank line after the header block")
check(ys["Cast delay"] - ys["Speed"] == 16, "blank line before the modifier block")
check(ys["Spread"] - ys["Cast delay"] == 8, "8px pitch inside a block")

print("\nOK — card reproduces the native Spark Bolt card, plus one description line.")
