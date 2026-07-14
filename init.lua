-- noita-tooltip-example — minimal "add a line to a spell's tooltip" mod.
--
-- WHAT IT DOES
--   Hovering Spark Bolt shows its normal card with ONE extra description line.
--   Every other item and spell keeps its untouched native tooltip.
--
-- WHY IT TAKES A HOOK
--   Item/spell cards are drawn entirely in C++ (UI_RenderItemTooltipPanel @
--   0x00b65fb0 — the single function behind the inventory grid, the wand
--   quickbar, the wand-swap menu and world items). No Lua API reaches inside
--   it, and it draws exactly one, never-wrapped description line. So there is
--   no way to *add* to the card. The only lever is: suppress it and draw your
--   own in the same spot.
--
-- HOW (three moving parts)
--   1. files/cardhook.lua  detours the native renderer. For every card the game
--      wants to draw it records WHERE (screen anchor) and FOR WHAT (the item
--      entity), and can be told to make the native draw a no-op.
--   2. Each frame we consume that capture and ask: is this Spark Bolt?
--      No  -> unblank, the native card draws, we do nothing.
--      Yes -> blank it, and draw our own card at the captured anchor.
--   3. files/card.lua  is a pixel replica of the native card, so the swapped
--      card looks identical — except for whatever we changed.
--
-- The card CONTENT below is spelled out by hand: this mod claims exactly one
-- spell, so it reproduces exactly one card. Deriving every spell's rows
-- automatically (baking gun_actions.lua + reading projectile XML) is a much
-- bigger job — see noita-spell-tooltips if you want that.

local BASE = "mods/noita-tooltip-example/files/" -- folder name is baked into these paths
local cardhook = dofile_once(BASE .. "cardhook.lua")
local card = dofile_once(BASE .. "card.lua")
local gui = dofile_once(BASE .. "gui.lua")

-- ---- what we override --------------------------------------------------------

local TARGET_ACTION = "LIGHT_BULLET" -- Spark Bolt (ItemActionComponent.action_id)

-- The whole point of the mod: a second description line the native card cannot draw.
-- (Keep it no wider than the vanilla line or the card grows — width is set by the
-- longest title/description line, exactly as the native size formula does it.)
local EXTRA_DESC_LINE = "Cheap, fast, and always there."

-- ---- localization ------------------------------------------------------------
-- "$key" -> the player's language, like the game does. Plain strings pass through.
local function loc(s)
	if type(s) ~= "string" or s:sub(1, 1) ~= "$" then return tostring(s) end
	local ok, t = pcall(GameTextGetTranslatedOrNot, s)
	if ok and t and t ~= "" then return t end
	return s
end
-- Unit strings are templates: $inventory_seconds is "$0 s", $inventory_degrees "$0 DEG".
local function unit(key, value) return (loc(key):gsub("%$0", value)) end

-- ---- Spark Bolt's card, exactly as the game draws it --------------------------
-- Every value here is what the native card computes, sourced from game data:
--   data/scripts/gun/gun_actions.lua (LIGHT_BULLET):  mana = 5, type = projectile,
--     action(): fire_rate_wait +3 frames, spread_degrees -1, damage_critical_chance +5
--   data/entities/projectiles/deck/light_bullet.xml:  damage 0.12, speed 750..850
--   ...and the card prints damage x25 (0.12 -> 3), speed as the min/max average
--   (750..850 -> 800), and frames/60 as seconds (3 -> +0.05 s).
local IC = "data/ui_gfx/inventory/"
local PITCH, GAP = 8, 16 -- row pitch; GAP = one blank line (the native group divider)

local function spark_bolt_card()
	local meta = {
		name = loc("$action_light_bullet"),          -- card.lua uppercases it
		sprite = "data/ui_gfx/gun_actions/light_bullet.png",
		max_uses = -1,                               -- unlimited -> no " (N)" suffix
		-- A LIST of lines instead of a single string: line 1 is vanilla's, line 2 is ours.
		description = {
			loc("$actiondesc_light_bullet"),
			EXTRA_DESC_LINE,
		},
	}
	local rows = {
		-- header: type + mana (the blank line after mana is the native GAP)
		{ icon = IC .. "icon_action_type.png", label = loc("$inventory_actiontype"),
			value = loc("$inventory_actiontype_projectile"), adv = PITCH },
		{ icon = IC .. "icon_mana_drain.png", label = loc("$inventory_manadrain"),
			value = "5", adv = GAP },
		-- the projectile's absolute stats
		{ icon = IC .. "icon_damage_projectile.png", label = loc("$inventory_damage"),
			value = "3", adv = PITCH },
		{ icon = IC .. "icon_speed_multiplier.png", label = loc("$inventory_speed"),
			value = "800", adv = GAP },
		-- what casting it does to the wand
		{ icon = IC .. "icon_fire_rate_wait.png", label = loc("$inventory_mod_castdelay"),
			value = unit("$inventory_seconds", "+0.05"), adv = PITCH },
		{ icon = IC .. "icon_spread_degrees.png", label = loc("$inventory_mod_spread"),
			value = unit("$inventory_degrees", "-1"), adv = PITCH },
		{ icon = IC .. "icon_damage_critical_chance.png", label = loc("$inventory_mod_critchance"),
			value = "+5%", adv = PITCH },
	}
	return meta, rows
end

-- ---- glue --------------------------------------------------------------------

-- The hovered item is an entity; a spell carries its id in ItemActionComponent.
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

	-- Did the game just try to draw a card, and for what?
	local cap = cardhook.consume() -- { x, y, id } or nil
	if not cap or action_id_of(cap.id) ~= TARGET_ACTION then
		cardhook.set_blank(false) -- not ours: let the native card render
		return
	end

	cardhook.set_blank(true) -- ours: the native draw becomes a no-op...
	local meta, rows = spark_bolt_card()
	local w, h = card.card_size(ctx, meta, rows)
	local x, y = card.place(cap.x, cap.y, w, h, gui) -- ...and we draw in its place
	card.draw_card(ctx, { x = x, y = y, w = w, h = h }, meta, rows)
end

function OnPausedChanged(_is_paused, _is_inventory_pause)
	-- The pump only runs while the world updates, so never leave the native card
	-- blanked when we stop pumping (pause / menus) — that would hide real tooltips.
	cardhook.set_blank(false)
end

-- Exposed so tools/smoke.lua can build the card outside the game. Harmless in-game.
_G.tooltip_example_card = spark_bolt_card
