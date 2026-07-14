-- noita-tooltip-example — pixel replica of the game's item/spell hover card.
--
-- The native card is drawn entirely in C++ (UI_RenderItemTooltipPanel @
-- 0x00b65fb0). You cannot add a line to it. What you CAN do is stop it from
-- drawing (files/cardhook.lua) and draw your own card in the same place — which
-- means rebuilding its geometry exactly, or the swap is visible.
--
-- The numbers below are reverse-engineered from that function and checked
-- against screenshots of the real cards:
--
--   +-------------------------------------------+
--   | (5,5)   TITLE (uppercase, " (N)" if uses) |   background: 9piece0_gray,
--   |                                           |   full card, drawn BEHIND
--   | (5,21)  description line 1                |   the content (bigger z)
--   | (5,29)  description line 2  <- our extra  |
--   |                                    [item] |   sprite hugs the right edge,
--   | (5,37+) [ico] label      value            |   5px inset, v-centered, x2
--   |         ...  8px pitch (16 = blank line)  |
--   +-------------------------------------------+
--
-- Vanilla only ever draws ONE description line (it never wraps), so line 2 is
-- pure gravy — the row block and the card height just shift down by DESC_LINE.
--
-- Data shapes (all strings PRE-localized — this file does no $key lookup):
--   meta = { name, description, sprite, max_uses }
--     description : string, or a LIST of lines, or nil. A line is either a plain
--                   string, or a list of SPANS to colour words individually:
--                     { "plain ", { t = "red bit", r = 1, g = 0.3, b = 0.3 }, "!" }
--                   (Noita draws one GuiText in one colour, so a multi-colour line
--                   is several GuiTexts laid end to end — we measure each span and
--                   advance x by its width. Vanilla never does this; nothing stops us.)
--     max_uses    : >= 0 appends " (N)" to the title, like limited-use spells
--   rows = { { icon, label, value, adv, r, g, b }, ... }
--     adv     : y advance after the row; default PITCH (8). Use PITCH*2 (16) for
--               the blank divider line the native card puts between stat groups.
--     r, g, b : optional 0..1 colour for the row's label AND value. Omit for the
--               native grey. (The native card paints every row the same colour;
--               a row that stands out is one more thing it cannot do.)

local M = {}

-- ---- layout (all tweakable; these are the native values) --------------------
M.NAME_Y, M.SUB_Y, M.ROW0_Y, M.PITCH = 5, 21, 37, 8
M.ICON_X, M.LABEL_X, M.VALUE_X = 5, 17, 75
M.ICON_DY, M.TEXT_DY = -1, -3
M.DESC_LINE = 8                       -- height of one description line
M.SPRITE_SCALE, M.MIN_W = 2, 96       -- text column is at least MIN_W wide
M.SIDE_PAD, M.ICON_COL_W = 10, 4
M.ROW_BLOCK_PAD, M.BOTTOM_PAD = 2, 10
-- Card position relative to the anchor the hook captured (the hovered slot's
-- top-left): centered horizontally, dropped CARD_VOFF below it.
M.CARD_HOFF, M.CARD_VOFF = 11, 33
-- The native card's text is not white: it's ~0.82 grey (measured 209,208,208).
M.TEXT_R, M.TEXT_G, M.TEXT_B = 209 / 255, 208 / 255, 208 / 255
M.BG = "data/ui_gfx/decorations/9piece0_gray.png"
M.FONT = "data/fonts/font_pixel_noshadow.xml"
M.PANEL_ID = 81000                    -- base widget id (see gui.lua on ids)
M.ANIM_FADE_SPEED = 0.07              -- the native card's own fade-in rate

-- The native card flips ABOVE the anchor when it would reach past half the
-- window height. That threshold is in PHYSICAL pixels, and GuiGetScreenDimensions
-- returns GUI units (physical / gui scale), so the two only agree at scale 1.
-- Reading the engine's own windowHeightF gives an exact match on every setup.
-- (Jan-2025 noita.exe, ASLR off. A wrong read just falls back to the GUI size.)
M.WINDOW_HF_ADDR = 0x01221bd0
local read_f32
do
	local ok, ffi = pcall(require, "ffi")
	-- Only ever poke a hardcoded address inside noita.exe itself. A bad read is a
	-- segfault, which pcall does NOT catch — so the guard has to be up front, not
	-- around the read. (Under Proton/Wine the game is still the Windows binary.)
	local in_game = ok and ffi.os == "Windows" and ffi.abi("32bit")
	read_f32 = function(addr)
		if not in_game then return nil end
		local ok2, v = pcall(function() return ffi.cast("float*", addr)[0] end)
		if ok2 and v == v then return v end -- v == v rejects NaN
		return nil
	end
end

-- ---- internals --------------------------------------------------------------

local function title_of(meta)
	local title = string.upper(tostring(meta.name or "")) -- native card: all caps
	if meta.max_uses and meta.max_uses >= 0 then title = title .. " (" .. meta.max_uses .. ")" end
	return title
end

-- description -> list of lines ({} when there is none).
local function desc_lines(meta)
	local d = meta.description
	if d == nil or d == "" then return {} end
	if type(d) == "string" then return { d } end
	return d
end

-- A line -> its list of spans. A plain string is a single, default-coloured span.
local function spans_of(line)
	if type(line) == "string" then return { { t = line } } end
	local out = {}
	for i, s in ipairs(line) do
		out[i] = (type(s) == "string") and { t = s } or s
	end
	return out
end

-- Width of a line in GUI units: the spans laid end to end.
local function line_width(gui, line)
	local w = 0
	for _, s in ipairs(spans_of(line)) do w = w + select(1, gui.text_dims(s.t or "")) end
	return w
end

-- Draw one line at (x, y), span by span, each in its own colour. `id` is the base
-- widget id for the line; spans take id, id+1, ... (ids must stay stable per frame).
local function draw_line(gui, id, x, y, line)
	for i, s in ipairs(spans_of(line)) do
		gui.text_ex(id + i - 1, x, y, s.t or "",
			s.r or M.TEXT_R, s.g or M.TEXT_G, s.b or M.TEXT_B, 1, 1, M.FONT)
		x = x + select(1, gui.text_dims(s.t or ""))
	end
end

local function sprite_size(gui, meta)
	local w, h = 16, 16
	if meta.sprite then
		local a, b = gui.image_dims(meta.sprite)
		if a and a > 0 then w, h = a, b end
	end
	return w * M.SPRITE_SCALE, h * M.SPRITE_SCALE
end

-- Y of the first stat row. One description line = the native 37; each extra line
-- pushes the rows down; no description pulls them up (also native).
local function row0_y(meta)
	local n = #desc_lines(meta)
	if n == 0 then return M.ROW0_Y - M.DESC_LINE end
	return M.ROW0_Y + (n - 1) * M.DESC_LINE
end

-- ---- public API -------------------------------------------------------------

-- The native auto-size formula. Width is driven by the TITLE and DESCRIPTION
-- only — never by the rows (the value column is at a fixed x). Returns w, h.
function M.card_size(ctx, meta, rows)
	local gui = ctx.gui
	rows = rows or {}
	local text_w = select(1, gui.text_dims(title_of(meta)))
	for _, line in ipairs(desc_lines(meta)) do
		text_w = math.max(text_w, line_width(gui, line))
	end
	local col_w = math.max(M.MIN_W, text_w)
	local sw, sh = sprite_size(gui, meta)
	local card_w = col_w + M.SIDE_PAD + sw + M.SIDE_PAD + M.ICON_COL_W

	local rows_h = row0_y(meta) + M.ROW_BLOCK_PAD
	for _, r in ipairs(rows) do rows_h = rows_h + (r.adv or M.PITCH) end
	local card_h = math.max(sh, rows_h) + M.BOTTOM_PAD
	return card_w, card_h
end

-- Native placement: centered on the anchor, CARD_VOFF below it, flipped above
-- near the screen bottom, clamped on-screen. Returns the card's top-left x, y.
function M.place(anchor_x, anchor_y, w, h, gui)
	local x = (anchor_x or 0) + M.CARD_HOFF - w * 0.5
	local y = (anchor_y or 0) + M.CARD_VOFF

	local thr = read_f32(M.WINDOW_HF_ADDR)
	if not (thr and thr > 100 and thr < 20000) then
		thr = gui and select(2, gui.screen_dims()) or nil
	else
		thr = thr * 0.5
	end
	if thr and (y + h + 5 > thr) then y = (anchor_y or 0) - h - 5 end

	if x < 5 then x = 5 end
	local screen_w = gui and gui.screen_dims() or nil
	if screen_w and (x + w + 5 > screen_w) then x = screen_w - w - 5 end
	return math.floor(x), math.floor(y)
end

-- Draw one card at rect = { x, y, w, h }. Returns the drawn w, h.
function M.draw_card(ctx, rect, meta, rows)
	local gui = ctx.gui
	rows = rows or {}
	local x, y = math.floor(rect.x or 0), math.floor(rect.y or 0)
	local card_w, card_h = rect.w, rect.h
	if not (card_w and card_h) then card_w, card_h = M.card_size(ctx, meta, rows) end
	local sw, sh = sprite_size(gui, meta)
	local base = M.PANEL_ID

	-- Fade the card in at the native rate. The tween is keyed by widget id, so
	-- it plays once when the card appears and holds while it's up.
	gui.animate_begin()
	gui.animate_alpha_fade_in(base, M.ANIM_FADE_SPEED, 0, false)

	-- Background BEHIND the content: larger z = deeper. Same z would fight.
	gui.z(-1099)
	gui.nine_piece(base, x, y, card_w, card_h, 1.0, M.BG)
	gui.z(-1100)

	gui.text_ex(base + 1, x + M.NAME_Y, y + M.NAME_Y, title_of(meta),
		M.TEXT_R, M.TEXT_G, M.TEXT_B, 1, 1, M.FONT)
	-- Description lines. Each line gets an id block of 10 (base+10, base+20, ...) so
	-- its spans have room for stable, non-colliding ids.
	for i, line in ipairs(desc_lines(meta)) do
		draw_line(gui, base + 10 * i, x + M.NAME_Y, y + M.SUB_Y + (i - 1) * M.DESC_LINE, line)
	end
	if meta.sprite then
		gui.image(base + 3, x + card_w - sw - 5, math.floor(y + (card_h - sh) * 0.5),
			meta.sprite, 1, M.SPRITE_SCALE)
	end

	local row_y = row0_y(meta)
	for j, r in ipairs(rows) do
		local ry = y + row_y
		local rr, rg, rb = r.r or M.TEXT_R, r.g or M.TEXT_G, r.b or M.TEXT_B
		if r.icon then gui.image(base + 100 + j, x + M.ICON_X, ry + M.ICON_DY, r.icon, 1, 1) end
		if r.label and r.label ~= "" then
			gui.text_ex(base + 200 + j, x + M.LABEL_X, ry + M.TEXT_DY, r.label,
				rr, rg, rb, 1, 1, M.FONT)
		end
		gui.text_ex(base + 300 + j, x + M.VALUE_X, ry + M.TEXT_DY, r.value or "",
			rr, rg, rb, 1, 1, M.FONT)
		row_y = row_y + (r.adv or M.PITCH)
	end

	gui.animate_end()
	gui.z(0)
	return card_w, card_h
end

return M
