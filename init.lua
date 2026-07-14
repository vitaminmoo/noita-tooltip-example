-- noita-tooltip-example — override Noita's item/spell hover cards from Lua.
--
-- WHAT IT DOES
--   SPARK BOLT gets its normal card plus an extra description line (with a word
--   in red) and a custom "Graham x2" stat row.
--   DAMAGE PLUS gets a byte-for-byte reproduction of its native card and nothing
--   else — it's the fidelity test: toggle the mod and you should see NO change.
--   Everything else in the game keeps its untouched native tooltip.
--
-- WHY IT TAKES A HOOK
--   Item/spell cards are drawn entirely in C++ (UI_RenderItemTooltipPanel @
--   0x00b65fb0 — the single function behind the inventory grid, the wand
--   quickbar, the wand-swap menu and world items). No Lua API reaches inside it,
--   and it draws exactly one, never-wrapped description line. So you cannot *add*
--   to the card. The only lever is: suppress it and draw your own in its place.
--
-- THE MODEL (this is the whole mod, in four lines)
--   1. The hook (files/cardhook.lua) intercepts every card the game wants to
--      draw and records WHERE it goes (screen anchor) + WHAT it's for (item entity).
--   2. Each frame we look at that capture and decide: is this a card we own?
--   3. If not -> unblank, and the native card draws exactly as it always did.
--   4. If so  -> blank the native draw, and render our replica (files/card.lua)
--      at the captured anchor, with whatever content we like.
--
-- ADDING A CARD = ADDING AN ENTRY TO `CARDS` BELOW. Each entry is a function
-- returning (meta, rows) — plain data. Everything else in this file is fixed glue.
-- See README.md for the recipe that turns any spell's game data into these rows.

local BASE = "mods/noita-tooltip-example/files/" -- folder name is baked into these paths
local cardhook = dofile_once(BASE .. "cardhook.lua")
local card = dofile_once(BASE .. "card.lua")
local gui = dofile_once(BASE .. "gui.lua")

-- ---- helpers -----------------------------------------------------------------

-- "$key" -> the player's language, like the game does. Plain strings pass through.
local function loc(s)
	if type(s) ~= "string" or s:sub(1, 1) ~= "$" then return tostring(s) end
	local ok, t = pcall(GameTextGetTranslatedOrNot, s)
	if ok and t and t ~= "" then return t end
	return s
end
-- Unit strings are templates: $inventory_seconds is "$0 s", $inventory_degrees "$0 DEG".
local function unit(key, value) return (loc(key):gsub("%$0", value)) end

local IC = "data/ui_gfx/inventory/"       -- vanilla row icons (7x7)
local MINE = BASE                         -- our own art lives beside our code
local PITCH, GAP = 8, 16                  -- row advance: next line / next line + a blank

-- The two header rows every spell card starts with.
local function type_row(type_key) -- e.g. "projectile", "modifier"
	return { icon = IC .. "icon_action_type.png", label = loc("$inventory_actiontype"),
		value = loc("$inventory_actiontype_" .. type_key), adv = PITCH }
end
local function mana_row(mana, adv)
	return { icon = IC .. "icon_mana_drain.png", label = loc("$inventory_manadrain"),
		value = tostring(mana), adv = adv or GAP } -- GAP: the native blank line after the header
end

-- ---- THE CARDS ---------------------------------------------------------------
-- Keyed by ItemActionComponent.action_id (the `id` field in gun_actions.lua).
-- Each builder returns meta + rows; see files/card.lua for both shapes.

local CARDS = {}

-- SPARK BOLT — the native card, plus our two additions.
--   gun_actions.lua (LIGHT_BULLET): mana 5, type projectile, action() does
--     fire_rate_wait +3 frames, spread_degrees -1, damage_critical_chance +5
--   light_bullet.xml: damage 0.12, speed 750..850
--   -> the card prints damage x25 (0.12 -> 3), speed as the min/max average
--      (750..850 -> 800), frames/60 as seconds (3 -> +0.05 s). (README has the
--      full conversion table.)
CARDS.LIGHT_BULLET = function()
	local meta = {
		name = loc("$action_light_bullet"),          -- card.lua uppercases it
		sprite = "data/ui_gfx/gun_actions/light_bullet.png",
		max_uses = -1,                               -- unlimited -> no " (N)" title suffix
		-- ADDITION 1: a LIST of lines instead of one string. Vanilla draws exactly one
		-- description line, never wraps it, and paints it one colour — so a second
		-- line, with ONE WORD IN RED, is three things it cannot do at once.
		-- A line can be spans: plain strings, or { t = text, r, g, b } (0..1 colour).
		description = {
			loc("$actiondesc_light_bullet"),
			{
				"Is this what you're after, ",
				{ t = "GrahamBurger", r = 0.90, g = 0.20, b = 0.20 }, -- Noita's UI red
				"?",
			},
		},
	}
	local rows = {
		type_row("projectile"),
		mana_row(5),
		-- the projectile's own stats
		{ icon = IC .. "icon_damage_projectile.png", label = loc("$inventory_damage"),
			value = "3", adv = PITCH },

		-- ADDITION 2: a second damage type. The native card prints exactly one damage
		-- number (damage.projectile) — a projectile can carry any of the engine's
		-- damage types, and mods can invent their own, but none of them are shown.
		-- Here's what one looks like when it is.
		-- The label follows the game's own wording for damage-type rows: the vanilla
		-- keys $inventory_mod_damage_slice / _explosion / _ice read "Dmg. Slice",
		-- "Dmg. Expl", "Dmg. Ice" — so a `cute` damage type is "Dmg. Cute". Match the
		-- convention and a made-up stat reads as if it had always been there.
		-- r/g/b colours the label AND value; omit them for the native grey.
		-- (Labels live at x=17, values at a FIXED x=75 — keep labels short enough to
		-- clear it; the value column does not move to make room.)
		{ icon = MINE .. "icon_cute.png", label = "Dmg. Cute", value = "7", adv = PITCH,
			r = 0.96, g = 0.44, b = 0.66 }, -- pink

		{ icon = IC .. "icon_speed_multiplier.png", label = loc("$inventory_speed"),
			value = "800", adv = GAP },
		-- what casting it does to the wand
		{ icon = IC .. "icon_fire_rate_wait.png", label = loc("$inventory_mod_castdelay"),
			value = unit("$inventory_seconds", "+0.05"), adv = PITCH },
		{ icon = IC .. "icon_spread_degrees.png", label = loc("$inventory_mod_spread"),
			value = unit("$inventory_degrees", "-1"), adv = PITCH },
		{ icon = IC .. "icon_damage_critical_chance.png", label = loc("$inventory_mod_critchance"),
			value = "+5%", adv = GAP },

		-- ADDITION 3: a stat the game has no concept of. A row is just data —
		-- icon, label, value, advance — so a made-up one costs exactly what a real
		-- one costs. The icon ships with the mod (7x7, the size vanilla's are); a
		-- vanilla 'data/...' path works just as well.
		{ icon = MINE .. "icon_graham.png", label = "Graham", value = "x2", adv = PITCH },
	}
	return meta, rows
end

-- DAMAGE PLUS — a pure reproduction: no additions, nothing custom. It's here as
-- the FIDELITY TEST (disable the mod, hover it, compare) and to show a card with
-- a different shape: a modifier has no projectile of its own, so no Damage/Speed
-- block — just the header and the deltas it applies to the wand.
--   gun_actions.lua (DAMAGE): mana 5, type modifier, action() does
--     damage_projectile_add +0.4 (-> +10), fire_rate_wait +5 (-> +0.08 s)
--   ...it also sets gore_particles and recoil, which the native card does NOT
--   print. The game shows only a fixed set of stats; the rest are invisible.
--   (Surfacing those hidden ones is exactly what a mod like this is good for.)
CARDS.DAMAGE = function()
	local meta = {
		name = loc("$action_damage"),
		description = loc("$actiondesc_damage"), -- a plain string = one line, like vanilla
		sprite = "data/ui_gfx/gun_actions/damage.png",
		max_uses = -1,
	}
	local rows = {
		type_row("modifier"),
		mana_row(5),
		{ icon = IC .. "icon_fire_rate_wait.png", label = loc("$inventory_mod_castdelay"),
			value = unit("$inventory_seconds", "+0.08"), adv = PITCH },
		{ icon = IC .. "icon_damage_projectile.png", label = loc("$inventory_mod_damage"),
			value = "+10", adv = PITCH },
	}
	return meta, rows
end

-- ---- glue (you should not need to touch anything below) -----------------------

-- The hovered item is an entity; a spell carries its id in ItemActionComponent.
-- (Any other item — wand, potion, gold — is an entity too, so you classify those
-- by whatever component identifies them instead.)
local function action_id_of(entity_id)
	if not entity_id then return nil end
	local ok, aid = pcall(function()
		local comp = EntityGetFirstComponentIncludingDisabled(entity_id, "ItemActionComponent")
		return comp and ComponentGetValue2(comp, "action_id") or nil
	end)
	if not ok or not aid or aid == "" then return nil end
	return aid
end

local ctx = { gui = gui }

function OnWorldInitialized()
	gui.ensure()
	-- Fail-safe by design: on another game build the prologue check fails, install()
	-- returns false, NOTHING is patched, and vanilla tooltips carry on working.
	if not cardhook.install() then
		print("[tooltip-example] hook not installed (" .. tostring(cardhook.last_error) ..
			") — native tooltips are untouched")
	end
end

function OnWorldPostUpdate()
	if not cardhook.installed then return end
	gui.begin_frame()

	-- What card did the game last want to draw, and for what item?
	local cap = cardhook.consume() -- { x, y, id } or nil
	local build = cap and CARDS[action_id_of(cap.id) or ""]
	if not build then
		cardhook.set_blank(false) -- not ours (or nothing hovered): native card renders
		return
	end

	cardhook.set_blank(true) -- ours: the native draw becomes a no-op...
	local meta, rows = build()
	local w, h = card.card_size(ctx, meta, rows)
	local x, y = card.place(cap.x, cap.y, w, h, gui) -- ...and we draw in its place
	card.draw_card(ctx, { x = x, y = y, w = w, h = h }, meta, rows)
end

function OnPausedChanged(_is_paused, _is_inventory_pause)
	-- The pump only runs while the world updates, so never leave the native card
	-- blanked when we stop pumping (pause / menus) — that would hide real tooltips.
	cardhook.set_blank(false)
end

-- Exposed so tools/smoke.lua can build the cards outside the game. Harmless in-game.
_G.tooltip_example_cards = CARDS
