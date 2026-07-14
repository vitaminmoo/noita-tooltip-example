# noita-tooltip-example

**Replace Noita's item/spell hover cards with your own, from Lua.**

A minimal, self-contained, working example — and a guide to doing it for whatever
card you like. Two cards are overridden:

- **Spark Bolt** — its native card, plus three things vanilla physically cannot
  do: a **second description line**, a **word in red**, and a **custom stat row**
  with a mod-shipped icon.
- **Damage Plus** — its native card **reproduced exactly**, nothing added. That's
  the fidelity test: toggle the mod, hover it, and you should see no difference.

Everything else in the game keeps its untouched native tooltip.

```
SPARK BOLT                                     DAMAGE PLUS
A weak but enchanting sparkling projectile     Increases the damage done by a projectile
Is this what you're after, GrahamBurger?
                            ^^^^^^^^^^^^ red   [] Type          Proj. modifier
[] Type          Projectile                    [] Mana drain    5
[] Mana drain    5
                                               [] Cast delay    +0.08 s
[] Damage        3                             [] Damage        +10
[] Speed         800
                                               (byte-for-byte the native card)
[] Cast delay    +0.05 s
[] Spread        -1 DEG
[] Crit. Chance  +5%

() Graham        x2    <- a stat the game has no concept of
```

---

## Why this needs a hook

Every item/spell card — inventory grid, active-wand quickbar, wand-swap menu,
world items — is drawn by **one C++ function**: `UI_RenderItemTooltipPanel @
0x00b65fb0`. No Lua API reaches inside it. It draws exactly **one** description
line, never wraps it, paints it one colour, and prints a **fixed set** of stats.

So you cannot *add* to that card. There is exactly one lever:

> **stop it from drawing, and draw your own in its place.**

That's the whole technique. Everything else is detail.

## The model

```
        the game wants to draw a card
                     |
          [ files/cardhook.lua ]   <- detour on the native renderer
          records: anchor x/y + the hovered item entity,
          and (on request) turns the native draw into a no-op
                     |
     your OnWorldPostUpdate, once per frame:

        cap  = cardhook.consume()             -- what card, for which item?
        mine = CARDS[action_id_of(cap.id)]

        if not mine then
            cardhook.set_blank(false)         -- native card renders. done.
        else
            cardhook.set_blank(true)          -- native draw suppressed...
            card.draw_card(...)               -- ...we render a replica instead
        end
```

**Adding a card = adding an entry to the `CARDS` table in `init.lua`.** An entry
is a function returning `meta, rows` — plain data. Nothing else changes.

**Frame timing**, worth internalising: `consume()` reports what the game drew
*last* render; `set_blank()` applies to the *next* one. A hovered card persists
over many frames, so the swap is invisible — but your decision is always one
render behind the cursor.

## Files

| file | what it is | do you touch it? |
|---|---|---|
| `init.lua` | **Your code.** The `CARDS` table + ~30 lines of fixed glue. | yes — this is where you work |
| `files/cardhook.lua` | The hook: detour, capture, blank. The only code that touches memory. | no — copy as-is |
| `files/card.lua` | Pixel replica of the native card — geometry, font, tint, fade-in, auto-size, placement, bottom-of-screen flip. Adds multi-line descriptions and coloured spans. Every layout constant is a tweakable field. | rarely |
| `files/gui.lua` | The handful of `Gui*` calls the replica needs. | no |
| `files/icon_graham.png` | 7×7 icon for the custom row — the size vanilla's row icons are. | swap in your own art |
| `tools/smoke.lua` | Renders every card in `CARDS` as ASCII, headless, and asserts the layout. Dev-only; the game never loads it. | use it |

## Install / run

1. Copy the folder into `Noita/mods/`. It **must** keep the name
   `noita-tooltip-example` — the `dofile` paths contain it.
2. Enable it, and **allow unsafe mods** (see Caveats).
3. Start a run, open the inventory, hover Spark Bolt.

Author cards without launching the game:

```
luajit tools/smoke.lua      # ASCII render of every card in CARDS + layout assertions
```

---

## Recipe: reproducing any spell's native card

To override a card convincingly you must first *reproduce* it. Every number the
native card prints comes from two files, through a handful of conversions.

**1. `data/scripts/gun/gun_actions.lua`** — the entry whose `id` is your
`action_id`. It gives you the header and the deltas:

| field | becomes |
|---|---|
| `id` | your key in `CARDS` |
| `name`, `description` | title (drawn uppercased) and the description line |
| `sprite` | the image at the card's right edge |
| `type` | the `Type` row (`ACTION_TYPE_PROJECTILE` → `$inventory_actiontype_projectile`, `..._MODIFIER` → `...modifier`, …) |
| `mana` | the `Mana drain` row |
| `max_uses` | if ≥ 0: `" (N)"` on the title **and** a `Uses remaining` row |
| `action()` | every `c.<field> = c.<field> + N` is a potential delta row |

**2. The projectile XML** (`related_projectiles`, e.g.
`data/entities/projectiles/deck/light_bullet.xml`) — only for spells that fire
something. `ProjectileComponent` gives `Damage` and `Speed`.

**3. The conversions** — this is what trips people up:

| stat | source | conversion | example |
|---|---|---|---|
| Damage | `ProjectileComponent.damage` | **× 25**, rounded | `0.12` → `3` |
| Speed | `speed_min`, `speed_max` | **average** | `750..850` → `800` |
| Cast delay / Recharge | `c.fire_rate_wait`, `c.reload_time` | **frames ÷ 60**, 2 decimals, signed | `+3` → `+0.05 s` |
| Damage deltas | `c.damage_*_add` | **× 25**, signed | `+0.4` → `+10` |
| Spread | `c.spread_degrees` | signed int + ` DEG` | `-1.0` → `-1 DEG` |
| Crit chance | `c.damage_critical_chance` | signed int + `%` | `+5` → `+5%` |
| Speed multiplier | `c.speed_multiplier` | `x N.NN` | `2` → `x 2.00` |
| Bounces / knockback / expl. radius | `c.bounces`, … | signed int | `+2` |

**4. What the native card does NOT print.** The game prints only a fixed set of
stats. `c.gore_particles`, `c.recoil`, `c.screenshake`, `c.lifetime_add`,
`c.material`, `c.extra_entities` … are invisible, even though they're right there
in `action()`. Damage Plus changes gore and recoil and its card never says so.
**Surfacing the hidden ones is one of the best reasons to write a mod like this.**

Check your reproduction with `tools/smoke.lua` against a screenshot of the real
card *before* you ever launch the game.

## Adding a card

```lua
CARDS.SPITTER = function()          -- key = action_id, straight from gun_actions.lua
    local meta = {
        name        = loc("$action_spitter"),
        description = loc("$actiondesc_spitter"),  -- or a list of lines
        sprite      = "data/ui_gfx/gun_actions/spitter.png",
        max_uses    = -1,                          -- >= 0 also adds " (N)" to the title
    }
    local rows = {
        type_row("projectile"),                    -- helpers live at the top of init.lua
        mana_row(10),
        { icon = IC .. "icon_damage_projectile.png", label = loc("$inventory_damage"),
          value = "5", adv = PITCH },
        -- ...
    }
    return meta, rows
end
```

`adv` is the y-advance after a row: `PITCH` (8) = next line; `GAP` (16) = next
line **plus a blank one** — the divider the native card puts between stat groups.
Get these wrong and the card reads as subtly "off" even when every value is right.

## What you can do that vanilla can't

- **More than one description line** — pass a list. The row block and the card
  height shift down automatically, following the native size formula.
- **Colour individual words** — a line can be a list of spans:
  `{ "plain ", { t = "red", r = 0.9, g = 0.2, b = 0.2 }, " plain" }`. Noita draws
  one `GuiText` in one colour, so `card.lua` lays the spans end to end, measuring
  each one. Works on any line.
- **Rows the game has no concept of** — a row is just `{ icon, label, value, adv }`.
  `Graham x2` costs exactly what a real stat costs. The icon is any path: your own
  art (7×7 matches vanilla) or a stock one like
  `data/ui_gfx/inventory/icon_speed_multiplier.png`.
- **Anything else in `card.lua`** — every layout constant is a field you can
  reassign (`card.CARD_VOFF = 40`, `card.TEXT_R = 1`, …).

## Gotchas that will bite you

1. **Always unblank when you don't claim a card.** If you `set_blank(true)` and
   then fail to draw — or stop pumping — the player gets *no* tooltip at all. Note
   `OnPausedChanged` in `init.lua`: the pump doesn't run while paused, so the flag
   is cleared there.
2. **Widget ids must be unique and frame-stable.** Two widgets sharing an id
   flicker; an id that changes every frame restarts the fade animation every
   frame. `card.lua` derives all its ids from one base — keep that discipline.
3. **The background must be *deeper* than the content** (`GuiZSet`; larger =
   deeper), or they fight and your text disappears.
4. **One capture per frame.** The hook keeps only the latest card the game asked
   for — which is all the UI ever produces (one hovered item).
5. **Your builder runs every frame the card is up.** Keep it cheap, or cache it by
   `action_id`.
6. **Card width comes from the title and description only** — never from rows (the
   value column sits at a fixed x). A very long row value can run under the sprite.
7. **Only one mod can own the hook.** First to patch wins; a second `install()`
   fails the prologue check — safely, doing nothing.

## Beyond spells

The capture hands you an **entity id**. A spell is just an entity with an
`ItemActionComponent` — wands, potions and gold are entities too. Classify them by
whatever component identifies them (`AbilityComponent`,
`MaterialInventoryComponent`, …) and the same capture → blank → draw loop applies.
`card.lua` neither knows nor cares that it's drawing a spell.

## Doing this for *every* spell

This example writes its card content **by hand**, because it claims two cards. To
claim all ~400 you'd stop writing rows and start *deriving* them: bake
`gun_actions.lua` the way the game does (run each `action()` against a stub `c`
table to collect its deltas) and parse the projectile XML chain, `<Base>`
inheritance included — then feed the result through the conversion table above.
It's a meaningful chunk of code, but nothing here changes: same hook, same
capture, same replica renderer, same `(meta, rows)` shape. Only the *source* of
the rows changes, from hand-written to computed.

(There are private mods of ours that already do this — a generalised hook library
plus a consumer that derives every spell's stats, including the hidden ones. They
aren't published, so treat them as an existence proof rather than a dependency:
this repo stands alone.)

## Caveats

- **Unsafe mods required** (`request_no_api_restrictions="1"`). The hook writes a
  `jmp` over the renderer's prologue via LuaJIT FFI +
  `VirtualAlloc`/`VirtualProtect`. No native code *ships* with the mod — it
  assembles the ~40 bytes it needs at runtime.
- **Build-locked addresses.** `0x00b65fb0` (the renderer) and `0x01221bd0` (window
  height, for the flip-above-anchor rule) are for the **Jan 2025** build of
  `noita.exe`, ASLR off. On any other build the prologue check fails, `install()`
  returns `false`, **nothing is patched**, and vanilla tooltips keep working.
  Fail-safe is the design, not a bonus.
- **One hooker per process.** Don't run this alongside any other mod that
  overrides tooltips — they'd hook the same function, and only the first one to
  patch it wins (the loser fails safely and does nothing).

## License

MIT — do whatever you like with it. Copy the hook, the renderer, or the whole
thing into your own mod; no attribution required (though it's always welcome).
