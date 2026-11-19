-- ShamanKit Move mode: one button (settings pages, or /shamankit move) puts every piece of the addon on screen at once as a
-- labelled frame you drag where you want it: the totem bar, the buff icons, the cure row, the Call buttons. Pieces that sat
-- on the bar or the player frame become their own place when you move them. Pieces that overlap turn red and are named.
--
-- The frames are plain ones laid over the real pieces; a drag only changes settings and then asks the module to place
-- itself (out of combat, like everything else). The real, secure buttons are never touched, and a fight ends the mode.
-- Each module offers its pieces through ns.moveProviders: a function returning a list of
--   { id, label, frame | rect = function() -> left, bottom, width, height, on = function() -> bool,
--     drop = function(cx, cy, w, h) }   (cx, cy: the piece's middle, measured from the middle of the screen)

local ADDON, ns = ...
local dbg, guard = ns.dbg, ns.guard

local M = { on = false, overlays = {}, dragging = nil }
ns.moveState = M

local GOLD, RED = { 1, 0.82, 0 }, { 1, 0.25, 0.25 }

local function scaleOf(f)
	local ok, s = pcall(f.GetEffectiveScale, f)
	return (ok and type(s) == "number" and s > 0) and s or 1
end

-- where a piece is, in screen units of UIParent: left, bottom, width, height (nil when it has no place to show)
local function rectOf(piece)
	local l, b, w, h
	if piece.rect then
		l, b, w, h = piece.rect()
	elseif piece.frame then
		local f = piece.frame
		local ok
		ok, l, b, w, h = pcall(f.GetRect, f)
		if not ok then l = nil end
		if l and w and h then
			local k = scaleOf(f) / scaleOf(UIParent)
			l, b, w, h = l * k, b * k, w * k, h * k
		end
	end
	if type(l) ~= "number" or type(b) ~= "number" or type(w) ~= "number" or type(h) ~= "number" then return nil end
	if w < 4 or h < 4 then return nil end
	return l, b, w, h
end

local function collect()
	local list = {}
	for _, fn in ipairs(ns.moveProviders or {}) do
		local ok, pieces = pcall(fn)
		if ok and type(pieces) == "table" then
			for _, p in ipairs(pieces) do
				local good, on = pcall(function() return p.on == nil or p.on() end)
				if good and on then list[#list + 1] = p end
			end
		elseif not ok then
			dbg("MOVE: a provider failed: %s", tostring(pieces):sub(1, 80))
		end
	end
	return list
end

local function round(v) return math.floor(v + 0.5) end

-- ---------------------------------------------------------------- the frames you drag

local function colour(o, c)
	o.fill:SetColorTexture(c[1], c[2], c[3], 0.22)
	for _, ln in ipairs(o.lines) do ln:SetColorTexture(c[1], c[2], c[3], 0.95) end
	o.label:SetTextColor(c[1], c[2], c[3])
	o.colour = c
end

local function onDragStop(o)
	if M.dragging ~= o then return end            -- a drag that never started saves nothing
	M.dragging = nil
	o:StopMovingOrSizing()
	local piece = o.piece
	if piece and not InCombatLockdown() then
		local l, b = o:GetLeft(), o:GetBottom()
		local w, h = o:GetSize()
		local ux, uy = UIParent:GetCenter()
		if type(l) == "number" and type(b) == "number" and type(ux) == "number" then
			local cx, cy = round(l + w / 2 - ux), round(b + h / 2 - uy)
			local ok, err = pcall(piece.drop, cx, cy, w, h)
			dbg("MOVE %s to %d,%d%s", piece.id, cx, cy, ok and "" or (" FAILED: " .. tostring(err):sub(1, 80)))
		end
	end
	if C_Timer and C_Timer.After then C_Timer.After(0.1, function() if M.on then M.sync() end end) elseif M.on then M.sync() end
end

local function newOverlay()
	local o = CreateFrame("Frame", nil, UIParent)
	o:SetFrameStrata("FULLSCREEN_DIALOG")
	o:SetClampedToScreen(true)
	o:SetMovable(true)
	o:EnableMouse(true)
	o:RegisterForDrag("LeftButton")
	o.fill = o:CreateTexture(nil, "BACKGROUND")
	o.fill:SetAllPoints()
	o.lines = {}
	for i = 1, 4 do
		local ln = o:CreateTexture(nil, "BORDER")
		if i == 1 then ln:SetPoint("TOPLEFT"); ln:SetPoint("TOPRIGHT"); ln:SetHeight(2)
		elseif i == 2 then ln:SetPoint("BOTTOMLEFT"); ln:SetPoint("BOTTOMRIGHT"); ln:SetHeight(2)
		elseif i == 3 then ln:SetPoint("TOPLEFT"); ln:SetPoint("BOTTOMLEFT"); ln:SetWidth(2)
		else ln:SetPoint("TOPRIGHT"); ln:SetPoint("BOTTOMRIGHT"); ln:SetWidth(2) end
		o.lines[i] = ln
	end
	o.label = o:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	o.label:SetPoint("BOTTOM", o, "TOP", 0, 3)
	o:SetScript("OnDragStart", function(self)
		if InCombatLockdown() then return end
		M.dragging = self
		self:StartMoving()
	end)
	o:SetScript("OnDragStop", onDragStop)
	o:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText(self.piece and self.piece.label or "")
		GameTooltip:AddLine("Drag to move it.", 0.8, 0.8, 0.8)
		if self.piece and self.piece.hint then GameTooltip:AddLine(self.piece.hint, 1, 1, 1, true) end
		GameTooltip:Show()
	end)
	o:SetScript("OnLeave", GameTooltip_Hide)
	colour(o, GOLD)
	o:Hide()
	return o
end

-- ---------------------------------------------------------------- the small panel

local function overlap(a, b)
	return a.l < b.l + b.w - 1 and b.l < a.l + a.w - 1 and a.b < b.b + b.h - 1 and b.b < a.b + a.h - 1
end

local function buildPanel()
	local p = CreateFrame("Frame", "ShamanKitMovePanel", UIParent, "BackdropTemplate")
	p:SetSize(380, 124)
	p:SetPoint("TOP", UIParent, "TOP", 0, -110)
	p:SetFrameStrata("FULLSCREEN_DIALOG")
	p:SetFrameLevel(50)
	p:SetClampedToScreen(true)
	p:EnableMouse(true)
	p:SetBackdrop({ bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background", edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
		tile = true, tileSize = 32, edgeSize = 32, insets = { left = 8, right = 8, top = 8, bottom = 8 } })
	local title = p:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
	title:SetPoint("TOP", 0, -16)
	title:SetText("ShamanKit: move things")
	p.info = p:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	p.info:SetPoint("TOP", 0, -42)
	p.info:SetWidth(340)
	p.info:SetText("Drag a frame where you want it. Moving something that sat on the bar or the player frame gives it a place of its own.")
	p.warn = p:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	p.warn:SetPoint("TOP", p.info, "BOTTOM", 0, -6)
	p.warn:SetWidth(340)
	local done = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
	done:SetSize(120, 24)
	done:SetPoint("BOTTOMRIGHT", -20, 16)
	done:SetText("Done")
	done:SetScript("OnClick", function() ns.moveStop() end)
	local reset = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
	reset:SetSize(150, 24)
	reset:SetPoint("BOTTOMLEFT", 20, 16)
	reset:SetText("Reset all positions")
	reset:SetScript("OnClick", function() ns.moveResetAll() end)
	p.done, p.reset = done, reset
	if UISpecialFrames then table.insert(UISpecialFrames, "ShamanKitMovePanel") end        -- Esc is Done
	p:SetScript("OnHide", function() if M.on then ns.moveStop() end end)
	local acc = 0
	p:SetScript("OnUpdate", function(_, elapsed)
		acc = acc + elapsed
		if acc < 0.5 then return end
		acc = 0
		if not M.on or M.dragging then return end
		if InCombatLockdown() then ns.moveStop() return end
		M.sync()
	end)
	p:Hide()
	return p
end

-- ---------------------------------------------------------------- showing and checking the pieces

function M.sync()
	if not M.on then return end
	local pieces = collect()
	local seen, rects = {}, {}
	for _, piece in ipairs(pieces) do
		local l, b, w, h = rectOf(piece)
		if l then
			local o = M.overlays[piece.id]
			if not o then o = newOverlay(); M.overlays[piece.id] = o end
			o.piece = piece
			seen[piece.id] = true
			if M.dragging ~= o then
				o:ClearAllPoints()
				o:SetSize(w, h)
				o:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", l, b)
			end
			o.label:SetText(piece.label)
			o:Show()
			rects[#rects + 1] = { id = piece.id, label = piece.label, l = l, b = b, w = w, h = h }
		end
	end
	for id, o in pairs(M.overlays) do
		if not seen[id] then o:Hide(); o.piece = nil end
	end
	-- pieces on top of each other turn red
	local hit, names = {}, {}
	for i = 1, #rects do
		for j = i + 1, #rects do
			if overlap(rects[i], rects[j]) then
				hit[rects[i].id], hit[rects[j].id] = true, true
				names[#names + 1] = rects[i].label .. " and " .. rects[j].label
			end
		end
	end
	for id, o in pairs(M.overlays) do
		local want = hit[id] and RED or GOLD
		if o.colour ~= want then colour(o, want) end
	end
	M.overlapping = names
	M.shown = #rects
	if M.panel then
		if #names > 0 then M.panel.warn:SetText("|cffff4040These sit on top of each other: " .. table.concat(names, "; ") .. ".|r")
		elseif #rects == 0 then M.panel.warn:SetText("Nothing is on screen to move yet. Switch a piece on in its settings page.")
		else M.panel.warn:SetText("Nothing overlaps.") end
	end
end

-- ---------------------------------------------------------------- start and stop

function ns.moveStart()
	if M.on then return end
	if InCombatLockdown() then print("|cff33ff99ShamanKit|r: things can't be moved in a fight.") return end
	M.on = true
	ns.moveMode = true                           -- keeps the sample totems and icons up, like an open settings page
	ns.optionsOpen = true
	M.reopen = SettingsPanel and SettingsPanel.IsShown and SettingsPanel:IsShown() or false
	if M.reopen then pcall(HideUIPanel, SettingsPanel) end
	if not M.panel then M.panel = buildPanel() end
	M.panel:Show()
	ns.updatePreview()
	M.sync()
	if C_Timer and C_Timer.After then C_Timer.After(0.15, function() if M.on then M.sync() end end) end   -- once the pieces have settled
end

function ns.moveStop()
	if not M.on then return end
	M.on = false
	M.dragging = nil
	ns.moveMode = false
	for _, o in pairs(M.overlays) do o:StopMovingOrSizing(); o:Hide() end
	if M.panel then M.panel:Hide() end
	ns.optionsOpen = ns.pagesUp and ns.pagesUp() or false
	ns.updatePreview()
	if M.reopen and ns.openOptions and not InCombatLockdown() then ns.openOptions() end
	M.reopen = false
end

-- every position back to the usual place (the bar, the buff icons, the cure row and the Call buttons)
function ns.moveResetAll()
	if InCombatLockdown() then return end
	if ns.resetPosition then ns.resetPosition() end
	if ns.callResetPlace then
		ns.callResetPlace()
		for _, kind in ipairs({ "call", "totemic", "recall" }) do ns.callResetPlace(kind) end
	end
	ns.updatePreview()
	if M.on then M.sync() end
end

local ev = CreateFrame("Frame")
ev:SetScript("OnEvent", guard("move event", function() if M.on then ns.moveStop() end end))
pcall(ev.RegisterEvent, ev, "PLAYER_REGEN_DISABLED")       -- a fight ends the mode: nothing may be moved in it
