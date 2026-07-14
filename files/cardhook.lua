-- noita-tooltip-example — native tooltip-card CAPTURE HOOK.
--
-- This file is the whole trick, and it's the only code here that touches raw
-- memory. Copy it into your own mod unchanged; everything else is plain Lua.
--
-- The native tooltip renderer UI_RenderItemTooltipPanel@0x00b65fb0 is the SINGLE
-- function that draws EVERY item/spell card — inventory spell grid, active-wand
-- quickbar, wand-swap menu, world items (RE'd callers). To override our replica card
-- for spells EVERYWHERE (not just the active wand row) we need, for each call, the
-- card's screen position and which item it's for. There is NO global holding either
-- (RE-confirmed): position is a call-local Vec2* (in EDX) and the item is a stack
-- arg (an Entity*). So we install a small inline detour that CAPTURES those into a
-- buffer and can CONDITIONALLY early-return (blank) the native card — the blank is
-- toggled from Lua per-frame, so non-spell items (potions/gold/wands) keep their
-- native tooltips while spells get ours.
--
-- ABI (RE'd from both HUD call sites; the fn is caller-cleaned / bare ret is safe):
--   ECX = renderer ctx (unused here)
--   EDX = Vec2* {float x, float y} — the card TOP-LEFT origin
--   [esp+4] at entry = the item Entity* (Entity.id is at +0x00; ItemActionComponent
--                      -> action_id identifies a spell)
--
-- The detour overwrites the first 5 prologue bytes (55 8B EC 6A FF = push ebp; mov
-- ebp,esp; push -1) with `jmp cave`. The cave: captures x/y/item, sets a pending
-- flag, and if the Lua-controlled blank flag is set returns 0 (card suppressed);
-- otherwise it executes the displaced 5 bytes and jmps back to 0x00b65fb5 so the
-- native card renders normally.
--
-- Everything is pcall-guarded and gated: if ffi/VirtualProtect are unavailable, the
-- prologue isn't the expected bytes, or no in-range cave can be allocated, install()
-- returns false and callers fall back to the per-slot suppression path. EXPERIMENTAL:
-- this is a raw machine-code patch — off by default.

local M = { installed = false, available = false, last_error = nil }

local CARD_FN = 0x00b65fb0
local RESUME = 0x00b65fb5 -- CARD_FN + 5 (instruction boundary after the displaced bytes)
local EXPECTED_PROLOGUE = { 0x55, 0x8b, 0xec, 0x6a, 0xff } -- push ebp; mov ebp,esp; push -1

-- buffer field offsets
local OFF_X, OFF_Y, OFF_ITEM, OFF_PEND, OFF_BLANK = 0, 4, 8, 12, 13

local ffi
do
	local ok, m = pcall(require, "ffi")
	if ok and m then ffi = m; M.available = true end
end

local kernel32
if M.available then
	pcall(function()
		ffi.cdef [[
			void*    __stdcall VirtualAlloc(void* addr, uint32_t size, uint32_t allocType, uint32_t protect);
			int      __stdcall VirtualFree(void* addr, uint32_t size, uint32_t freeType);
			int      __stdcall VirtualProtect(void* addr, uint32_t size, uint32_t newProt, uint32_t* oldProt);
		]]
		kernel32 = ffi.load("kernel32")
	end)
end
if not kernel32 then M.available = false end

M.can_hook = function() return M.available end

-- ---- little-endian byte helpers -------------------------------------------
local function u32le(v)
	v = v % 0x100000000
	return { v % 256, math.floor(v / 256) % 256, math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256 }
end
local function s32le(v) if v < 0 then v = v + 0x100000000 end return u32le(v) end
local function fits_i32(v) return v >= -0x80000000 and v <= 0x7fffffff end

-- ---- raw memory access (RWX cave: direct; .text: via VirtualProtect) --------
local function poke(addr, bytes)
	return pcall(function()
		local p = ffi.cast("uint8_t*", addr)
		for i, b in ipairs(bytes) do p[i - 1] = b end
	end)
end
local function peek(addr, n)
	local ok, t = pcall(function()
		local p = ffi.cast("uint8_t*", addr)
		local out = {}
		for i = 0, n - 1 do out[i + 1] = p[i] end
		return out
	end)
	return ok and t or nil
end
local function write_text(addr, bytes)
	return pcall(function()
		local p = ffi.cast("uint8_t*", addr)
		local old = ffi.new("uint32_t[1]")
		kernel32.VirtualProtect(p, #bytes, 0x40, old) -- PAGE_EXECUTE_READWRITE
		for i, b in ipairs(bytes) do p[i - 1] = b end
		kernel32.VirtualProtect(p, #bytes, old[0], old)
	end)
end
local function u32_at(addr)
	local ok, v = pcall(function() return tonumber(ffi.cast("uint32_t*", addr)[0]) end)
	return ok and v or nil
end
local function f32_at(addr)
	local ok, v = pcall(function() return ffi.cast("float*", addr)[0] end)
	if ok and v == v then return v end
	return nil
end
local function u8_at(addr)
	local ok, v = pcall(function() return tonumber(ffi.cast("uint8_t*", addr)[0]) end)
	return ok and v or nil
end
local function set_u8(addr, v) pcall(function() ffi.cast("uint8_t*", addr)[0] = v end) end

-- ---- cave allocation (must be within rel32 range of CARD_FN) ----------------
-- noita.exe is LARGE_ADDRESS_AWARE, so VirtualAlloc(NULL) can land >2GB away and
-- break the rel32 detour. Try hints near the module first (all < 2GB from CARD_FN),
-- then a NULL alloc as a range-checked fallback.
local ALLOC = 0x3000    -- MEM_COMMIT|MEM_RESERVE
local RWX = 0x40        -- PAGE_EXECUTE_READWRITE
local RELEASE = 0x8000  -- MEM_RELEASE
-- Sweep the low 2GB (all < rel32 range of CARD_FN) in 0x08000000 steps, plus a few
-- extra spots, so an occupied hint just moves on to the next candidate. VirtualAlloc
-- with a hint fails (NULL) if that exact region is taken, so we try many.
local HINTS = {
	0x10000000, 0x20000000, 0x30000000, 0x18000000, 0x28000000, 0x38000000,
	0x08000000, 0x40000000, 0x48000000, 0x50000000, 0x58000000, 0x60000000,
	0x68000000, 0x70000000, 0x78000000, 0x04000000, 0x0c000000, 0x14000000,
}

local function in_range(cave)
	-- detour jmp (CARD_FN -> cave) and the cave's return jmp (-> RESUME) must both fit.
	return fits_i32(cave - (CARD_FN + 5)) and fits_i32(RESUME - (cave + 512))
end
local function valloc(hint)
	local ok, p = pcall(function()
		return tonumber(ffi.cast("uintptr_t", kernel32.VirtualAlloc(ffi.cast("void*", hint), 4096, ALLOC, RWX)))
	end)
	return (ok and p ~= 0) and p or nil
end
local function vfree(addr)
	pcall(function() kernel32.VirtualFree(ffi.cast("void*", addr), 0, RELEASE) end)
end
local function alloc_cave()
	for _, h in ipairs(HINTS) do
		local p = valloc(h)
		if p then
			if in_range(p) then return p end
			vfree(p)
		end
	end
	local p = valloc(0)
	if p and in_range(p) then return p end
	if p then vfree(p) end
	return nil
end

-- ---- cave code builder -----------------------------------------------------
-- BUF and CODE both live in the allocated page: BUF at page+0 (16B), CODE at page+64.
local function build_cave(code_addr, buf, prologue)
	local X, Y, ITEM, PEND, BLANK = buf + OFF_X, buf + OFF_Y, buf + OFF_ITEM, buf + OFF_PEND, buf + OFF_BLANK
	local c = {}
	local function e(...) for _, b in ipairs({ ... }) do c[#c + 1] = b end end
	local function eb(t) for _, b in ipairs(t) do c[#c + 1] = b end end
	-- if (edx) { X = edx->x; Y = edx->y }   (guard against a non-pointer EDX)
	e(0x85, 0xD2)                       -- test edx, edx
	e(0x74, 0x0F)                       -- jz +15 -> skip_pos
	e(0x8B, 0x02); e(0xA3); eb(u32le(X))       -- mov eax,[edx]   ; mov [X],eax
	e(0x8B, 0x42, 0x04); e(0xA3); eb(u32le(Y)) -- mov eax,[edx+4] ; mov [Y],eax
	-- skip_pos: ITEM = [esp+4]  (item Entity*, first stack arg at entry)
	e(0x8B, 0x44, 0x24, 0x04); e(0xA3); eb(u32le(ITEM))
	-- PEND = 1
	e(0xC6, 0x05); eb(u32le(PEND)); e(0x01)
	-- if (BLANK) return 0
	e(0x80, 0x3D); eb(u32le(BLANK)); e(0x00) -- cmp byte [BLANK], 0
	e(0x74, 0x03)                            -- jz +3 -> cont
	e(0x33, 0xC0)                            -- xor eax,eax
	e(0xC3)                                  -- ret
	-- cont: run the CAPTURED displaced prologue (exactly the bytes we overwrote — not
	-- a hardcoded guess, so a slightly different build still executes correctly), then
	-- jmp back to RESUME.
	eb(prologue)
	local jmp_at = code_addr + #c
	e(0xE9); eb(s32le(RESUME - (jmp_at + 5))) -- jmp RESUME
	return c
end

-- ---- lifecycle -------------------------------------------------------------
local page, buf_addr, orig_prologue = nil, nil, nil

-- Format a byte array as a hex string for diagnostics ("55 8b ec 6a ff").
local function hexbytes(t)
	if not t then return "nil" end
	local parts = {}
	for i, b in ipairs(t) do parts[i] = string.format("%02x", b) end
	return table.concat(parts, " ")
end

function M.install()
	if M.installed then return true end
	if not M.can_hook() then M.last_error = "ffi/kernel32 unavailable"; return false end
	-- verify the prologue is exactly what we expect (guards against a different build).
	-- On mismatch we record the ACTUAL bytes so the log tells us the real prologue
	-- (rather than failing blind) — the cave re-executes whatever we overwrote.
	local cur = peek(CARD_FN, #EXPECTED_PROLOGUE)
	if not cur then M.last_error = "could not read prologue at CARD_FN"; return false end
	for i, b in ipairs(EXPECTED_PROLOGUE) do
		if cur[i] ~= b then
			M.last_error = ("prologue mismatch: got [%s] want [%s]"):format(hexbytes(cur), hexbytes(EXPECTED_PROLOGUE))
			return false
		end
	end

	local p = alloc_cave()
	if not p then M.last_error = "no in-range cave (VirtualAlloc)"; return false end
	local code_addr = p + 64
	local buf = p
	local code = build_cave(code_addr, buf, cur)
	if #code > 512 - 64 then vfree(p); M.last_error = "cave code too large"; return false end -- sanity vs in_range's 512 budget

	-- zero the buffer, write the cave, then the detour (last, so nothing runs a half-cave)
	poke(buf, { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 })
	if not poke(code_addr, code) then vfree(p); M.last_error = "cave write failed"; return false end
	orig_prologue = cur
	local rel = code_addr - (CARD_FN + 5)
	local detour = { 0xE9 }
	for _, b in ipairs(s32le(rel)) do detour[#detour + 1] = b end
	if not write_text(CARD_FN, detour) then vfree(p); orig_prologue = nil; M.last_error = "detour write failed (VirtualProtect)"; return false end

	page, buf_addr = p, buf
	M.installed = true
	M.last_error = nil
	return true
end

function M.uninstall()
	if not M.installed then return end
	if orig_prologue then write_text(CARD_FN, orig_prologue) end
	if page then vfree(page) end
	page, buf_addr, orig_prologue = nil, nil, nil
	M.installed = false
end

-- Tell the stub whether to blank the native card on its NEXT call(s).
function M.set_blank(on)
	if M.installed and buf_addr then set_u8(buf_addr + OFF_BLANK, on and 1 or 0) end
end

-- Read + clear the latest capture. Returns { x, y, id } for the hovered item, or nil
-- if no card was requested since the last consume. `id` is the Lua entity id (read
-- from Entity.id @+0x00 of the captured Entity*); nil if the pointer looked invalid.
function M.consume()
	if not (M.installed and buf_addr) then return nil end
	local pend = u8_at(buf_addr + OFF_PEND)
	if not pend or pend == 0 then return nil end
	set_u8(buf_addr + OFF_PEND, 0)
	local x = f32_at(buf_addr + OFF_X)
	local y = f32_at(buf_addr + OFF_Y)
	local ent = u32_at(buf_addr + OFF_ITEM)
	local id
	-- Only dereference a plausibly-valid pointer (the game just used it, so it's live;
	-- reject obvious garbage to avoid a hard fault ffi can't catch).
	if ent and ent > 0x10000 and ent < 0xffff0000 then
		id = u32_at(ent) -- Entity.id @ +0x00
	end
	return { x = x, y = y, id = id }
end

return M
