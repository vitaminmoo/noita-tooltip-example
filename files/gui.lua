-- noita-tooltip-example — the few Gui* calls the card renderer needs.
--
-- Noita's GUI is immediate-mode: create ONE handle (GuiCreate) and keep it for
-- the whole session, call GuiStartFrame once per frame, then issue widget calls.
-- Every widget needs an id that is unique AND stable frame-to-frame — two
-- widgets sharing an id "fight" and flicker, and a *changing* id restarts the
-- widget's animation every frame. card.lua derives all its ids from one base.

local M = { handle = nil, ready = false }

-- Create the handle. Safe once the world exists (call from OnWorldInitialized).
function M.ensure()
	if not M.handle then M.handle = GuiCreate() end
	return M.handle
end

-- Once per frame, before any draw.
function M.begin_frame()
	if M.handle then
		GuiStartFrame(M.handle)
		M.ready = true
	end
end

-- Viewport size in GUI coordinates (NOT pixels — the GUI is scaled).
function M.screen_dims()
	if not M.ready then return nil end
	return GuiGetScreenDimensions(M.handle)
end

function M.text_dims(s, scale)
	if not M.ready then return 0, 0 end
	return GuiGetTextDimensions(M.handle, s, scale or 1)
end

function M.image_dims(sprite, scale)
	if not M.ready then return nil end
	local ok, w, h = pcall(GuiGetImageDimensions, M.handle, sprite, scale or 1)
	if ok then return w, h end
	return nil
end

function M.image(id, x, y, sprite, alpha, scale)
	if not M.ready then return end
	GuiImage(M.handle, id, x, y, sprite, alpha or 1, scale or 1, 0)
end

function M.nine_piece(id, x, y, w, h, alpha, sprite)
	if not M.ready then return end
	GuiImageNinePiece(M.handle, id, x, y, w, h, alpha or 1, sprite)
end

-- Text with an explicit font + scale, so we can match the native card's font.
function M.text_ex(id, x, y, s, r, g, b, a, scale, font)
	if not M.ready then return end
	GuiIdPush(M.handle, id)
	if r then GuiColorSetForNextWidget(M.handle, r, g, b, a or 1) end
	GuiText(M.handle, x, y, s, scale or 1, font, true)
	GuiIdPop(M.handle)
end

-- Render depth for subsequent widgets (smaller = nearer the camera).
function M.z(z) if M.ready then GuiZSet(M.handle, z) end end

-- Appearance tweens. Widgets drawn between begin/end animate, keyed by widget
-- id — reuse the SAME id across frames or the tween restarts every frame.
function M.animate_begin() if M.ready then GuiAnimateBegin(M.handle) end end
function M.animate_end() if M.ready then GuiAnimateEnd(M.handle) end end
function M.animate_alpha_fade_in(id, speed, step, jump)
	if M.ready then GuiAnimateAlphaFadeIn(M.handle, id, speed or 0, step or 0, jump and true or false) end
end

return M
