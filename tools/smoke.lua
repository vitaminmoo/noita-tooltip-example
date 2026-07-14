-- Headless smoke test: luajit tools/smoke.lua
--
-- Builds every card in init.lua's CARDS table with stubbed Gui*/localization APIs,
-- prints an ASCII rendering of each so you can eyeball it against the real card,
-- and asserts the content + the native geometry rules.
--
-- Use it while authoring a new card: add your entry to CARDS, run this, and compare
-- the ASCII to a screenshot of the native card before you ever launch the game.
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
	["$action_damage"] = "Damage plus",
	["$actiondesc_damage"] = "Increases the damage done by a projectile",
	["$inventory_actiontype"] = "Type",
	["$inventory_actiontype_projectile"] = "Projectile",
	["$inventory_actiontype_modifier"] = "Proj. modifier",
	["$inventory_manadrain"] = "Mana drain",
	["$inventory_damage"] = "Damage",
	["$inventory_speed"] = "Speed",
	["$inventory_mod_castdelay"] = "Cast delay",
	["$inventory_mod_damage"] = "Damage",
	["$inventory_mod_spread"] = "Spread",
	["$inventory_mod_critchance"] = "Crit. Chance",
	["$inventory_seconds"] = "$0 s",
	["$inventory_degrees"] = "$0 DEG",
}
function GameTextGetTranslatedOrNot(s) return T[s] or s end

local draws = {} -- everything the card renderer emits, for the card under test
function GuiCreate() return {} end
function GuiStartFrame() end
function GuiGetScreenDimensions() return 640, 360 end
function GuiGetTextDimensions(_, s) return #s * 5, 8 end -- ~5px/char (the real font is variable-width)
function GuiGetImageDimensions() return 16, 16 end
function GuiIdPush() end
function GuiIdPop() end
local next_color = nil
function GuiColorSetForNextWidget(_, r, g, b) next_color = { r, g, b } end
function GuiZSet() end
function GuiAnimateBegin() end
function GuiAnimateEnd() end
function GuiAnimateAlphaFadeIn() end
function GuiImage(_, _, x, y, sprite) draws[#draws + 1] = { k = "img", x = x, y = y, s = sprite } end
function GuiImageNinePiece(_, _, x, y, w, h) draws[#draws + 1] = { k = "bg", x = x, y = y, w = w, h = h } end
function GuiText(_, x, y, s)
	draws[#draws + 1] = { k = "txt", x = x, y = y, s = s, c = next_color }
	next_color = nil
end
function EntityGetFirstComponentIncludingDisabled() return 1 end
function ComponentGetValue2() return "LIGHT_BULLET" end

-- ---- load the mod exactly as Noita would --------------------------------------
dofile("init.lua")
OnWorldInitialized() -- the hook can't install off-Windows; this must not throw

local gui = dofile_once("mods/noita-tooltip-example/files/gui.lua")
gui.ready = true -- the stub handle exists; pretend we're inside a frame
local card = dofile_once("mods/noita-tooltip-example/files/card.lua")

-- Render one CARDS entry the way OnWorldPostUpdate does, from a capture at (100,60).
-- Prints it as ASCII and returns: draw list, joined text, { text -> y within card }.
local function render(action_id)
	draws = {}
	local meta, rows = _G.tooltip_example_cards[action_id]()
	local w, h = card.card_size({ gui = gui }, meta, rows)
	local x, y = card.place(100, 60, w, h, gui)
	card.draw_card({ gui = gui }, { x = x, y = y, w = w, h = h }, meta, rows)

	local grid, text, ys = {}, {}, {}
	local function put(cx, cy, s)
		cx, cy = math.floor((cx - x) / 5), math.floor((cy - y) / 8)
		grid[cy] = grid[cy] or {}
		for i = 1, #s do grid[cy][cx + i] = s:sub(i, i) end
	end
	for _, d in ipairs(draws) do
		if d.k == "txt" then
			put(d.x, d.y, d.s); text[#text + 1] = d.s; ys[d.s] = d.y - y
		elseif d.k == "img" then
			put(d.x, d.y, (d.s:match("icon_[%w_]+") and "*") or "[]")
		end
	end

	local maxy, cols = 0, math.floor(w / 5)
	for cy in pairs(grid) do maxy = math.max(maxy, cy) end
	print(("\n%s — card %dx%d, %d rows, %d description line(s)"):format(
		action_id, w, h, #rows, type(meta.description) == "table" and #meta.description or 1))
	print("+" .. string.rep("-", cols) .. "+")
	for cy = 0, maxy do
		local line = {}
		for cx = 1, cols do line[cx] = (grid[cy] and grid[cy][cx]) or " " end
		print("|" .. table.concat(line) .. "|")
	end
	print("+" .. string.rep("-", cols) .. "+")
	return draws, table.concat(text, "\n"), ys
end

local function check(cond, msg) if not cond then error("FAIL: " .. msg, 0) end end

-- ---- SPARK BOLT: the native card + our two additions ---------------------------
local d, txt, ys = render("LIGHT_BULLET")

check(txt:find("SPARK BOLT", 1, true), "title is uppercased")
check(not txt:find("SPARK BOLT (", 1, true), "an unlimited-use spell gets no (N) suffix")
check(txt:find("A weak but enchanting sparkling projectile", 1, true), "vanilla description line kept")
check(txt:find("Is this what you're after, ", 1, true), "the added description line is drawn")

-- The coloured span: "GrahamBurger" is its own GuiText, in red, laid out directly
-- after the preceding span (that's how one line gets two colours).
local red, lead
for _, dr in ipairs(d) do
	if dr.k == "txt" and dr.s == "GrahamBurger" then red = dr end
	if dr.k == "txt" and dr.s == "Is this what you're after, " then lead = dr end
end
check(red, "GrahamBurger is drawn as its own span")
check(red.c and red.c[1] > 0.8 and red.c[2] < 0.4 and red.c[3] < 0.4, "the GrahamBurger span is red")
check(lead and red.x == lead.x + #lead.s * 5 and red.y == lead.y, "spans are laid end to end on one line")
for _, v in ipairs({ "Type", "Projectile", "Mana drain", "5", "Damage", "3", "Speed", "800",
	"Cast delay", "+0.05 s", "Spread", "-1 DEG", "Crit. Chance", "+5%" }) do
	check(txt:find(v, 1, true), "native card content present: " .. v)
end
check(txt:find("Graham", 1, true) and txt:find("x2", 1, true), "the custom stat row is drawn")
check(txt:find("Dmg. Cute", 1, true), "the extra damage-type row is drawn")

local icons = {}
for _, dr in ipairs(d) do
	if dr.k == "img" then icons[#icons + 1] = dr.s end
end
check(table.concat(icons, " "):find("icon_graham.png", 1, true), "the custom row's mod-shipped icon is drawn")
check(table.concat(icons, " "):find("icon_cute.png", 1, true), "the pink row's mod-shipped icon is drawn")

-- A coloured row tints BOTH its label and its value, and only that row: every other
-- row stays the native grey.
local function drawn(s)
	for _, dr in ipairs(d) do if dr.k == "txt" and dr.s == s then return dr end end
end
local function is_pink(dr) return dr.c and dr.c[1] > 0.9 and dr.c[2] < 0.6 and dr.c[3] > 0.5 and dr.c[3] < 0.8 end
check(is_pink(drawn("Dmg. Cute")), "the Dmg. Cute label is pink")
check(is_pink(drawn("7")), "the Dmg. Cute value is pink")
check(not is_pink(drawn("Graham")), "an uncoloured row keeps the native grey")

-- Geometry: a 2nd description line pushes the row block down exactly one line (8px)
-- from the native first-row y of 37.
check(ys["Type"] == 37 + 8 + card.TEXT_DY, "rows shift one line for the 2nd desc line, got " .. tostring(ys["Type"]))
check(ys["Damage"] - ys["Mana drain"] == 16, "blank line after the header block")
check(ys["Dmg. Cute"] - ys["Damage"] == 8, "the pink row sits in the projectile-stats block, 8px pitch")
check(ys["Speed"] - ys["Dmg. Cute"] == 8, "...and pushes Speed down one line, not out of the block")
check(ys["Cast delay"] - ys["Speed"] == 16, "blank line before the modifier block")
check(ys["Spread"] - ys["Cast delay"] == 8, "8px pitch inside a block")
check(ys["Graham"] - ys["Crit. Chance"] == 16, "blank line before the custom row")

-- ---- DAMAGE PLUS: a pure reproduction (must look exactly like native) ----------
local _, txt2, ys2 = render("DAMAGE")

check(txt2:find("DAMAGE PLUS", 1, true), "title")
check(txt2:find("Increases the damage done by a projectile", 1, true), "description")
for _, v in ipairs({ "Type", "Proj. modifier", "Mana drain", "5", "Cast delay", "+0.08 s", "+10" }) do
	check(txt2:find(v, 1, true), "native card content present: " .. v)
end
check(not txt2:find("Speed", 1, true), "a modifier has no projectile-stats block")
-- One description line = native geometry, unshifted: first row at y 37.
check(ys2["Type"] == 37 + card.TEXT_DY, "a single-description card keeps the native first-row y")
check(ys2["Cast delay"] - ys2["Mana drain"] == 16, "blank line after the header block")

print("\nOK — Spark Bolt: native card + 1 description line + 2 custom rows (one pink).")
print("     Damage Plus: native card reproduced exactly.")
