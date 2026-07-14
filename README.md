# noita-tooltip-example

A minimal, self-contained example of **overriding Noita's item/spell hover
card**: hover Spark Bolt and you get its normal card with **one extra
description line**. Every other item and spell keeps its untouched native
tooltip.

Four files, ~400 lines, most of it comments. Read `init.lua` first — it's the
only file you'd rewrite for your own mod.

```
SPARK BOLT
A weak but enchanting sparkling projectile
Cheap, fast, and always there.          <- added by this mod
 [] Type          Projectile
 [] Mana drain    5

 [] Damage        3
 [] Speed         800

 [] Cast delay    +0.05 s
 [] Spread        -1 DEG
 [] Crit. Chance  +5%
```

## Why a hook is needed at all

Every item/spell card — inventory grid, active-wand quickbar, wand-swap menu,
world items — is drawn by **one C++ function**,
`UI_RenderItemTooltipPanel @ 0x00b65fb0`. No Lua API reaches inside it, and it
draws exactly **one**, never-wrapped description line. There is no way to *add*
to that card.

So the only lever is: **stop it from drawing, and draw your own in its place.**

## How it works

| file | role |
|---|---|
| `files/cardhook.lua` | The hook. Detours the native renderer: records **where** each card goes (screen anchor) and **what** it's for (item entity), and can turn the native draw into a no-op. Copy it as-is. |
| `files/card.lua` | A pixel replica of the native card (geometry, font, grey tint, fade-in, auto-size, placement, bottom-of-screen flip) — so your card is indistinguishable from the game's, except for what you changed. Also allows a **multi-line description**, which vanilla can't do. |
| `files/gui.lua` | The handful of `Gui*` calls the replica needs. |
| `init.lua` | **Your code.** Per frame: is the hovered item Spark Bolt? If not, unblank and let the native card render. If so, blank it and draw ours. |

The card content in `init.lua` is written out by hand. That's the point of a
minimal example: it claims **one** spell, so it reproduces **one** card, and you
can see every value. Each number is the one the native card computes — with the
game data it comes from noted in a comment (`gun_actions.lua` for mana/type/cast
delay/spread/crit, the projectile XML for damage/speed).

## Install / run

1. Copy this folder into `Noita/mods/` — the folder **must** be named
   `noita-tooltip-example` (the `dofile` paths in `init.lua` contain it).
2. Enable it, and **allow unsafe mods** (`request_no_api_restrictions="1"` —
   the hook is a raw in-process code patch via LuaJIT FFI).
3. Start a run, open the inventory, hover Spark Bolt.

Headless check of the card (no game needed):

```
luajit tools/smoke.lua     # prints an ASCII render + asserts the layout
```

## Adapting it

- **Different spell:** change `TARGET_ACTION` (the `action_id` — e.g.
  `SPITTER`, `BOMB`, `LIGHT_BULLET_TRIGGER`) and rewrite the rows in
  `spark_bolt_card()` to match that spell's card.
- **Extra rows instead of a line:** append to `rows` — `{ icon, label, value,
  adv }`. `adv` is the y-advance after the row: `8` = next line, `16` = leave a
  blank divider line (what the native card does between stat groups).
- **Many spells:** you have to *derive* each card's rows rather than write them
  out — bake `gun_actions.lua` the way the game does and read the projectile XML.
  That's a big chunk of code; [`noita-spell-tooltips`](../noita-spell-tooltips)
  does it, on top of [`noita-tooltips-lib`](../noita-tooltips-lib) (the same hook
  + renderer as here, generalized into a registry so several mods can share one
  hook). Start there if you want more than a couple of cards.

## Caveats

- **Unsafe mods required.** The hook writes a `jmp` over the renderer's prologue.
- **Build-specific addresses.** `0x00b65fb0` (renderer) and `0x01221bd0`
  (window height, for the flip-above-anchor rule) are for the **Jan 2025** build
  of `noita.exe`, ASLR off. On any other build the prologue check fails,
  `install()` returns `false`, **nothing is patched**, and vanilla tooltips keep
  working. Fail-safe is the design, not a bonus.
- **One hooker at a time.** Whoever patches that function first wins; a second
  mod's `install()` fails the prologue check (safely). Don't run this alongside
  `noita-qol`'s tooltip override or `noita-spell-tooltips`.
- **One capture per frame.** The hook keeps only the latest card the game asked
  for — which is all the UI ever produces (one hovered item).
- Card width follows the native formula: the longest title/description line sets
  it. A long added line makes the card wider than vanilla's.
