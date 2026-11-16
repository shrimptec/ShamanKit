-- TotemRange: your active totems, their timers, and whether you are in range of each.
--
-- Range: a totem is dropped at your feet, so your position when it appears IS the totem's position.
-- Each tick the distance from there to you is compared to the totem's radius. If positions are
-- unavailable (instances, combat) a buff totem falls back to "do I have its buff", and if that is
-- unreadable too, nothing is marked (we never claim out of range unless we are sure).

local ADDON, ns = ...
ns.name = ADDON

local MAX_SLOTS = MAX_TOTEMS or 4
local TICK = 0.2
local OUT_COLOR = { 0.8, 0.1, 0.1 }   -- the default action-button "out of range" red

ns.defaults = {
	size = 36,
	spacing = 4,
	vertical = false,
	showTimer = true,
	showRange = true,
	distanceMode = "bar",   -- how far you are from each totem: "bar" (room left in its radius), "yards" (exact number) or "off"
	tint = true,
	locked = true,
	attach = false,        -- replace the default totem timers and sit under the player frame
	attachX = 65, attachY = 8,
	point = "CENTER", relPoint = "CENTER", x = 0, y = -200,
}

local isSecret = issecretvalue or function() return false end
local db

-- Game slots: 1 fire, 2 earth, 3 water, 4 air. The default totem bar shows them earth, fire, water, air, so
-- that is the default here too; the settings let the player reorder them (db.order = list of slots).
ns.SLOT_NAMES = { [1] = "Fire", [2] = "Earth", [3] = "Water", [4] = "Air" }
local function defaultOrder()
	local o, seen = {}, {}
	for _, slot in ipairs({ 2, 1, 3, 4 }) do
		if slot <= MAX_SLOTS then o[#o + 1] = slot; seen[slot] = true end
	end
	for slot = 1, MAX_SLOTS do if not seen[slot] then o[#o + 1] = slot end end
	return o
end
ns.defaultOrder = defaultOrder

-- db.order must be every slot exactly once; anything else (a hand-edited or damaged file) falls back to the default.
local function fixOrder()
	local o, seen, ok = db.order, {}, true
	if type(o) ~= "table" or #o ~= MAX_SLOTS then ok = false
	else
		for _, slot in ipairs(o) do
			if type(slot) ~= "number" or slot < 1 or slot > MAX_SLOTS or slot % 1 ~= 0 or seen[slot] then ok = false break end
			seen[slot] = true
		end
	end
	if not ok then db.order = defaultOrder() end
	return db.order
end
ns.fixOrder = fixOrder

-- Radius in yards, matched on the English totem name (others fall back to 30, the Forever buff radius).
-- aura = the buff name to look for when positions are unavailable.
local DEFAULT_RANGE = 30
local TOTEMS = {
	{ "stoneclaw", 8 }, { "earthbind", 10 }, { "magma", 8 }, { "searing", 20 }, { "fire nova", 10 },
	{ "tremor", 30 }, { "grounding", 30 }, { "sentry", 30 },
	{ "strength of earth", 30, "Strength of Earth" }, { "stoneskin", 30, "Stoneskin" },
	{ "healing stream", 30, "Healing Stream" }, { "mana spring", 30, "Mana Spring" },
	{ "frost resistance", 30, "Frost Resistance" }, { "fire resistance", 30, "Fire Resistance" },
	{ "nature resistance", 30, "Nature Resistance" }, { "grace of air", 30, "Grace of Air" },
	{ "windwall", 30, "Windwall" }, { "windfury", 30, "Windfury Totem" },
	{ "flametongue", 30, "Flametongue Totem" },
}

local function classify(name)
	if type(name) ~= "string" then return DEFAULT_RANGE end
	local lower = name:lower()
	for _, t in ipairs(TOTEMS) do
		if lower:find(t[1], 1, true) then return t[2], t[3] end
	end
	return DEFAULT_RANGE
end
ns.classify = classify

local bar, buttons, hits = nil, {}, {}
local state = {}          -- slot -> { at = placement position, range, aura, name }
local previewing = false

-- ---------------------------------------------------------------- positions & auras

-- A short log kept in the saved variables (written on /reload or logout) so range problems can be read back
local function dbg(fmt, ...)
	if not db then return end
	local log = db.log
	if not log then log = {}; db.log = log end
	log[#log + 1] = ("%.1f "):format(GetTime()) .. fmt:format(...)
	if #log > 80 then table.remove(log, 1) end
end

-- Anything running on a timer or event goes through this: a bug is written to the log (and mentioned once in
-- chat) instead of throwing a Lua error popup every 0.2 s.
local reported = false
local function guard(where, fn)
	return function(...)
		local ok, err = pcall(fn, ...)
		if not ok then
			dbg("ERROR in %s: %s", where, tostring(err))
			if not reported then
				reported = true
				print("|cff33ff99TotemRange|r hit an error (" .. where .. "): " .. tostring(err) .. "  (also logged)")
			end
		end
	end
end

-- Where the player is, from every source that is readable right now. Two independent sources so that
-- a restriction on one (combat, instances) still leaves the other:
--   u = UnitPosition (yards)   m = world map position scaled by the map's size in yards
local function readable(v) return v ~= nil and not isSecret(v) and type(v) == "number" end

local function readUnitPos(p)
	if UnitPosition then
		local ok, y, x, _, map = pcall(UnitPosition, "player")
		if ok and readable(y) and readable(x) then p.uy, p.ux, p.umap = y, x, map end
	end
end

local function readMapPos(p)
	p.mapRead = true
	if C_Map and C_Map.GetBestMapForUnit and C_Map.GetPlayerMapPosition and C_Map.GetMapWorldSize then
		local ok, mapID = pcall(C_Map.GetBestMapForUnit, "player")
		if ok and readable(mapID) then
			local ok2, v = pcall(C_Map.GetPlayerMapPosition, mapID, "player")
			local ok3, w, h = pcall(C_Map.GetMapWorldSize, mapID)
			if ok2 and ok3 and not isSecret(v) and v and readable(w) and readable(h) and w > 0 and h > 0 then
				local ok4, mx, my = pcall(v.GetXY, v)
				if ok4 and readable(mx) and readable(my) then p.mx, p.my, p.mw, p.mh, p.mapID = mx, my, w, h, mapID end
			end
		end
	end
end

-- A fresh, complete reading: kept as a totem's placement, so it must not be reused or changed afterwards.
local function playerPos()
	local p = {}
	readUnitPos(p)
	readMapPos(p)
	return p
end

-- The per-tick reading: ONE table reused every tick (no garbage), and the map source is only read when
-- the yard position can't answer. Not to be stored.
local scratch = {}
local function tickPos()
	scratch.uy, scratch.ux, scratch.umap = nil, nil, nil
	scratch.mx, scratch.my, scratch.mw, scratch.mh, scratch.mapID, scratch.mapRead = nil, nil, nil, nil, nil, false
	readUnitPos(scratch)
	return scratch
end

-- true / false, or nil when it can't be read
local function hasAura(name)
	if C_UnitAuras and C_UnitAuras.GetAuraDataBySpellName then
		local ok, data = pcall(C_UnitAuras.GetAuraDataBySpellName, "player", name, "HELPFUL")
		if ok and not isSecret(data) then return data ~= nil end
	end
	return nil
end

local function describe(p)
	if not p then return "-" end
	return ("u=%s,%s@%s m=%s,%s@%s"):format(tostring(p.uy), tostring(p.ux), tostring(p.umap),
		tostring(p.mx and ("%.5f"):format(p.mx)), tostring(p.my and ("%.5f"):format(p.my)), tostring(p.mapID))
end

-- true = in range, false = out, nil = unknown; second value says how it was decided
local function rangeOf(slot, now)
	local s = state[slot]
	if not s then return nil end
	now = now or playerPos()
	local was = s.at
	local r, how, dist
	if was and was.ux and now.ux and now.umap == was.umap then
		local dx, dy = now.ux - was.ux, now.uy - was.uy
		dist = math.sqrt(dx * dx + dy * dy)
		r, how = dist <= s.range, "position"
	else
		if not now.mapRead then readMapPos(now) end   -- the yard position could not answer: ask the map
	end
	if how then
		-- decided above
	elseif was and was.mx and now.mx and now.mapID == was.mapID then
		local dx, dy = (now.mx - was.mx) * now.mw, (now.my - was.my) * now.mh
		dist = math.sqrt(dx * dx + dy * dy)
		r, how = dist <= s.range, "map position"
	elseif s.aura then
		local a = hasAura(s.aura)
		if a ~= nil then r, how = a, "buff" end
	end
	how = how or "unknown"
	local key = tostring(r) .. how
	if s.last ~= key then
		s.last = key
		if not now.mapRead then readMapPos(now) end   -- the log line wants both sources
		dbg("slot %d %s -> %s via %s dist=%s range=%s | now %s | placed %s | combat=%s",
			slot, tostring(s.name), tostring(r), how, dist and ("%.1f"):format(dist) or "-", tostring(s.range),
			describe(now), describe(was), tostring(InCombatLockdown()))
	end
	return r, how, dist
end

-- ---------------------------------------------------------------- buttons

local function tooltip(self)
	GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
	local shown = false
	if not previewing and GameTooltip.SetTotem then shown = pcall(GameTooltip.SetTotem, GameTooltip, self.slot) end
	if not shown then GameTooltip:SetText(buttons[self.slot].sampleName or "Totem") end
	local s = state[self.slot]
	if s and not previewing then
		local r, how = rangeOf(self.slot)
		local text = r == true and "In range" or r == false and "Out of range" or "Range unknown"
		GameTooltip:AddLine(("%s (%d yd, by %s)"):format(text, s.range, how), 1, 1, 1)
	end
	GameTooltip:Show()
end

local function newButton(slot)
	local b = CreateFrame("Button", "TotemRangeButton" .. slot, bar)
	b.slot = slot

	b.icon = b:CreateTexture(nil, "BACKGROUND")
	b.icon:SetAllPoints()
	b.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

	b.cooldown = CreateFrame("Cooldown", nil, b, "CooldownFrameTemplate")
	b.cooldown:SetAllPoints()
	b.cooldown:SetDrawEdge(false)

	-- the same bevelled frame the action buttons use
	b.over = CreateFrame("Frame", nil, b)
	b.over:SetAllPoints()
	b.over:SetFrameLevel(b.cooldown:GetFrameLevel() + 2)
	b.border = b.over:CreateTexture(nil, "OVERLAY")
	b.border:SetTexture("Interface\\Buttons\\UI-Quickslot2")
	b.border:SetPoint("CENTER", 0, -1)

	b.mark = b.over:CreateTexture(nil, "OVERLAY", nil, 2)
	b.mark:SetPoint("BOTTOMRIGHT", 4, -4)
	b.mark:Hide()

	-- exact distance to the totem: under the icon (to the right when the bar is vertical)
	b.dist = b.over:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	b.dist:SetShadowOffset(1, -1)
	b.dist:Hide()

	-- Range bar: a thin status bar in the style of the default unit-frame bars, showing how much room is left
	-- inside the totem's radius (full = standing on it, empty = at the edge or beyond). Under the icon, or along
	-- its right side in a vertical bar.
	local g = CreateFrame("StatusBar", nil, b.over)
	g:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
	g:SetMinMaxValues(0, 1)
	g:SetValue(0)
	g.edge = g:CreateTexture(nil, "BACKGROUND", nil, -2)       -- 1 px frame, darkened (red when out of range)
	g.edge:SetTexture("Interface\\Tooltips\\UI-Tooltip-Background")
	g.edge:SetPoint("TOPLEFT", -1, 1)
	g.edge:SetPoint("BOTTOMRIGHT", 1, -1)
	g.back = g:CreateTexture(nil, "BACKGROUND", nil, -1)       -- empty part of the bar
	g.back:SetTexture("Interface\\Tooltips\\UI-Tooltip-Background")
	g.back:SetAllPoints()
	g.back:SetVertexColor(0.1, 0.1, 0.1, 0.9)
	g:Hide()
	b.gauge = g

	b:EnableMouse(false)
	b:Hide()
	return b
end

-- The clickable layer. Right-click dismisses the totem: the game only lets its own secure code do that,
-- so each slot gets a secure button with the built-in "destroytotem" action (what the default totem bar
-- uses). Secure buttons can't be created, moved, resized or have their attributes changed in combat,
-- so they are made once out of combat and only repositioned out of combat. The visible icon sits at the
-- same spot (it is a plain frame, so it can be shown/hidden in combat); a totem that appears mid-fight
-- shows where its button was parked and becomes clickable when the fight ends.
local function newHit(slot, b)
	local h = CreateFrame("Button", "TotemRangeHit" .. slot, bar, "SecureActionButtonTemplate")
	h.slot = slot
	h:RegisterForClicks("AnyUp", "AnyDown")
	h:SetAttribute("pressAndHoldAction", true)
	h:SetAttribute("*type2", "destroytotem")   -- "*": right-click with any modifier held
	h:SetAttribute("totem-slot", slot)
	h:SetSize(db.size, db.size)
	h:SetPoint("TOPLEFT", bar, "TOPLEFT", 0, 0)
	h:SetFrameLevel(b.over:GetFrameLevel() + 5)
	h:EnableMouse(false)
	h:SetScript("OnEnter", tooltip)
	h:SetScript("OnLeave", GameTooltip_Hide)
	h:RegisterForDrag("LeftButton")
	h:SetScript("OnDragStart", function() if db.locked == false and not db.attach then bar:StartMoving() end end)
	h:SetScript("OnDragStop", function() bar:GetScript("OnDragStop")(bar) end)
	return h
end

local GAUGE_GAP = 3
local function sizeGauge(b)
	local g, s = b.gauge, db.size
	local thick = math.max(5, math.floor(s * 0.16 + 0.5))
	g:ClearAllPoints()
	if db.vertical then
		g:SetOrientation("VERTICAL")
		g:SetPoint("TOPLEFT", b, "TOPRIGHT", GAUGE_GAP, 0)
		g:SetPoint("BOTTOMLEFT", b, "BOTTOMRIGHT", GAUGE_GAP, 0)
		g:SetWidth(thick)
	else
		g:SetOrientation("HORIZONTAL")
		g:SetPoint("TOPLEFT", b, "BOTTOMLEFT", 0, -GAUGE_GAP)
		g:SetPoint("TOPRIGHT", b, "BOTTOMRIGHT", 0, -GAUGE_GAP)
		g:SetHeight(thick)
	end
end

local function sizeButton(b)
	local s = db.size
	b:SetSize(s, s)
	b.border:SetSize(s * 66 / 36, s * 66 / 36)
	b.mark:SetSize(s * 0.5, s * 0.5)
	sizeGauge(b)
end

local layoutPending = false
local function layout()
	if InCombatLockdown() then layoutPending = true return end   -- the hit buttons can't move in combat
	layoutPending = false
	local want, order = fixOrder(), {}
	for _, slot in ipairs(want) do if buttons[slot]:IsShown() then order[#order + 1] = slot end end
	local n = #order
	-- slots without a totem are parked after the shown ones: a totem that appears mid-fight lands on its own spot
	for _, slot in ipairs(want) do if not buttons[slot]:IsShown() then order[#order + 1] = slot end end
	local s, gap = db.size, db.spacing
	for i, slot in ipairs(order) do
		local h = hits[slot]
		sizeButton(buttons[slot])
		local b = buttons[slot]
		h:ClearAllPoints()
		h:SetSize(s, s)
		b:ClearAllPoints()
		local off = (i - 1) * (s + gap)
		local x, y = 0, 0
		if db.vertical then y = -off else x = off end
		h:SetPoint("TOPLEFT", bar, "TOPLEFT", x, y)
		b:SetPoint("TOPLEFT", bar, "TOPLEFT", x, y)   -- same spot; not anchored to the protected button, so it stays freely showable
		h:EnableMouse(i <= n)   -- no invisible click-blocking squares where there is no totem
	end
	local long = math.max(n, 1) * s + math.max(n - 1, 0) * gap
	if db.vertical then bar:SetSize(s, long) else bar:SetSize(long, s) end
end

local function setMark(b, r)
	if not db.showRange then b.mark:Hide() return end
	-- unknown gets its own yellow "?" so a blank is never mistaken for "in range"
	b.mark:SetTexture(r == nil and "Interface\\RaidFrame\\ReadyCheck-Waiting"
		or r and "Interface\\RaidFrame\\ReadyCheck-Ready" or "Interface\\RaidFrame\\ReadyCheck-NotReady")
	b.mark:Show()
end

local function distMode()
	local m = db.distanceMode
	if m == "yards" or m == "off" then return m end
	return "bar"   -- the default; also what a damaged value means
end
ns.distMode = distMode

local function setDistance(b, dist, r)
	if not dist then b.dist:Hide() return end
	b.dist:ClearAllPoints()
	if db.vertical then b.dist:SetPoint("LEFT", b, "RIGHT", 4, 0)
	else b.dist:SetPoint("TOP", b, "BOTTOM", 0, -2) end
	b.dist:SetText(("%.1f yd"):format(dist))
	if r == false then b.dist:SetTextColor(OUT_COLOR[1] + 0.2, 0.3, 0.3) else b.dist:SetTextColor(1, 1, 1) end
	b.dist:Show()
end

-- The bar's colours: plenty of room left / getting close to the edge / nearly out. Out of range is an empty bar
-- with a red frame.
local GREEN, YELLOW, ORANGE = { 0.1, 0.8, 0.15 }, { 1, 0.82, 0 }, { 0.95, 0.4, 0.05 }
local EDGE_OK, EDGE_OUT = { 0, 0, 0, 0.9 }, { 0.85, 0.1, 0.1, 1 }

local function paintGauge(b, r, dist, range)
	local g = b.gauge
	if not (dist and range and range > 0) then
		if b.pg ~= -1 then b.pg = -1; g:Hide() end
		return
	end
	local len = db.size
	local frac = 1 - dist / range
	if frac < 0 then frac = 0 end
	local step = math.floor(frac * len + 0.5)          -- one step per pixel of bar: nothing to redraw between
	local out = r == false
	local bucket = out and 3 or (frac >= 0.5 and 0 or (frac >= 0.25 and 1 or 2))
	if b.pg == -1 or b.pg == nil then g:Show() end
	if b.pg ~= step then
		b.pg = step
		g:SetValue(step / len)
	end
	if b.pgb ~= bucket then
		b.pgb = bucket
		local c = bucket == 0 and GREEN or (bucket == 1 and YELLOW or ORANGE)
		g:SetStatusBarColor(c[1], c[2], c[3])
		local e = out and EDGE_OUT or EDGE_OK
		g.edge:SetVertexColor(e[1], e[2], e[3], e[4])
	end
end

-- Called every tick for every shown totem, so it only touches the screen when what is drawn would change:
-- the mark, the tint, the bar (one step per pixel) and the distance text (a tenth of a yard) are each remembered.
local function invalidate(b)
	b.pc, b.psr, b.pt, b.pd, b.pdc, b.pdv, b.pg, b.pgb, b.pm = nil, nil, nil, nil, nil, nil, nil, nil, nil
end

local function paintRange(b, r, dist, range)
	local c = r == nil and 0 or (r and 1 or 2)
	local showRange = db.showRange and true or false
	if b.pc ~= c or b.psr ~= showRange then
		b.pc, b.psr = c, showRange
		setMark(b, r)
	end
	local tint = (r == false and db.tint) and true or false
	if b.pt ~= tint then
		b.pt = tint
		if tint then b.icon:SetVertexColor(unpack(OUT_COLOR)) else b.icon:SetVertexColor(1, 1, 1) end
	end
	local mode = distMode()
	if b.pm ~= mode then          -- the setting changed: clear whichever display is not wanted
		b.pm = mode
		b.pd, b.pdc, b.pdv, b.pg, b.pgb = nil, nil, nil, nil, nil
		if mode ~= "bar" then b.gauge:Hide() end
		if mode ~= "yards" then b.dist:Hide() end
	end
	if mode == "bar" then
		paintGauge(b, r, dist, range)
	elseif mode == "yards" then
		local tenth = dist and math.floor(dist * 10 + 0.5) or -1
		local vertical = db.vertical and true or false
		if b.pd ~= tenth or b.pdc ~= c or b.pdv ~= vertical then
			b.pd, b.pdc, b.pdv = tenth, c, vertical
			setDistance(b, dist, r)
		end
	end
end

-- ---------------------------------------------------------------- real totems

local function refreshTimer(b, slot, start, duration)
	b.cooldown:SetHideCountdownNumbers(not db.showTimer)
	if GetTotemDuration then
		local ok, d = pcall(GetTotemDuration, slot)
		if ok and d and b.cooldown.SetCooldownFromDurationObject then
			b.cooldown:SetCooldownFromDurationObject(d, true)
			return
		end
	end
	-- start/duration may be secret in combat: pass them straight through, never test them
	pcall(b.cooldown.SetCooldown, b.cooldown, start, duration)
end

-- Is there a totem in the slot? In combat GetTotemInfo's flag is a hidden (secret) value, but
-- GetTotemDuration still returns an object exactly while a totem exists, so ask that instead.
-- Returns "keep" (can't tell), false (empty), or true plus the raw readings (any of which may be secret).
local function readSlot(slot)
	local ok, have, name, start, duration, icon = pcall(GetTotemInfo, slot)
	if not ok then return "keep" end
	local exists
	if isSecret(have) then
		if not GetTotemDuration then return "keep" end
		local dok, d = pcall(GetTotemDuration, slot)
		if not dok then return "keep" end
		exists = d ~= nil
	else
		exists = have and (isSecret(name) or (type(name) == "string" and name ~= ""))
	end
	if not exists then return false end
	return true, name, start, duration, icon, not isSecret(have)
end

-- The totem spell just cast, for naming a totem whose name the game hides in combat
local lastCast = { name = nil, t = 0 }
local function recentCastName()
	if lastCast.name and GetTime() - lastCast.t < 3 then return lastCast.name end
end

-- placed: the totem just appeared (or was moved to us), so we are standing on it
local function refreshSlot(slot, placed)
	local b = buttons[slot]
	local have, name, start, duration, icon = readSlot(slot)
	if have == "keep" then return end
	if not have then
		state[slot] = nil
		invalidate(b)
		b.gauge:Hide()
		b:Hide()
		return
	end
	local s = state[slot]
	if not s then
		s = {}
		state[slot] = s
	end
	if placed then
		s.at = playerPos()
		s.t = GetTime()
		s.last = nil
		local known = (not isSecret(name) and type(name) == "string" and name ~= "") and name or recentCastName()
		if known then s.name = known end
		s.range, s.aura = classify(s.name)
		dbg("PLACED slot %d %s at %s%s", slot, tostring(s.name), describe(s.at), (isSecret(have) or isSecret(name)) and " (hidden readings)" or "")
	elseif not s.name and not isSecret(name) and type(name) == "string" then
		s.name = name
		s.range, s.aura = classify(name)
	end
	s.range = s.range or DEFAULT_RANGE
	s.start = readable(start) and start or nil   -- a new start time means the totem was dropped again
	b.sampleName = s.name
	pcall(b.icon.SetTexture, b.icon, icon)
	refreshTimer(b, slot, start, duration)
	sizeButton(b)
	invalidate(b)
	b:Show()
end

local function updateShown()
	local any = false
	for slot = 1, MAX_SLOTS do if buttons[slot]:IsShown() then any = true end end
	bar.anyShown = any
	bar:SetShown(any or (ns.optionsOpen and true or false))
end

local function refreshAll()
	if previewing then return end
	for slot = 1, MAX_SLOTS do refreshSlot(slot) end
	layout()
	updateShown()
end

-- Dropping a totem again while one is already in that slot sends no event we can rely on, so notice it
-- by the start time changing and re-record where we are standing.
local function noticeReplaced(slot, visible, start)
	local s = state[slot]
	if not s or not s.start then return end
	-- in combat these can be secret values, which can't even be compared: leave those to the cast backup
	if visible and readable(start) and start > 0 and math.abs(start - s.start) > 0.05 then
		dbg("REPLACED slot %d %s (start %.2f -> %.2f)", slot, tostring(s.name), s.start, start)
		refreshSlot(slot, true)
	end
end

local function tick()
	if previewing then return end
	local any, cleared = false, false
	local now = tickPos()
	for slot = 1, MAX_SLOTS do
		local b = buttons[slot]
		if b:IsShown() then
			local have, _, start, _, _, visible = readSlot(slot)
			if have == false then
				refreshSlot(slot)   -- expired or destroyed: clears the button
				cleared = true
			else
				any = true
				if have then noticeReplaced(slot, visible, start) end
				local r, _, d = rangeOf(slot, now)
				paintRange(b, r, d, state[slot] and state[slot].range)
			end
		end
	end
	bar.anyShown = any
	if cleared then layout() updateShown() end   -- the last one gone: hide the bar, which also stops this tick
end

-- ---------------------------------------------------------------- preview (unlocked / settings open)

local SAMPLE = {
	{ "Searing Totem", 3599 }, { "Stoneskin Totem", 8071 },
	{ "Healing Stream Totem", 5394 }, { "Grace of Air Totem", 8835 },
}

local SAMPLE_DIST = { 6.2, 14.8, 41.3, 22.5 }
local SAMPLE_RANGE = { 20, 30, 30, 30 }   -- Searing 20 yd, the buff totems 30: shows full, half, empty and nearly-out

local function showPreview()
	previewing = true
	for slot = 1, MAX_SLOTS do
		local b, sample = buttons[slot], SAMPLE[slot]
		local tex = C_Spell and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(sample[2])
		b.icon:SetTexture(tex or "Interface\\Icons\\INV_Misc_QuestionMark")
		b.sampleName = sample[1]
		b.cooldown:SetHideCountdownNumbers(not db.showTimer)
		b.cooldown:SetCooldown(GetTime() - 30 * slot, 300)
		sizeButton(b)
		invalidate(b)
		b:Show()
		paintRange(b, slot ~= 3, SAMPLE_DIST[slot], SAMPLE_RANGE[slot])   -- one shown out of range so the look can be judged
	end
	layout()
	bar:Show()
end

local function endPreview()
	previewing = false
	for slot = 1, MAX_SLOTS do
		buttons[slot]:Hide()
		invalidate(buttons[slot])
		buttons[slot].cooldown:Clear()
		buttons[slot].icon:SetVertexColor(1, 1, 1)
	end
	refreshAll()
end

-- ---------------------------------------------------------------- attach to the player frame

-- Blizzard's own totem timers (TotemFrame, a child of the player frame) are made invisible and
-- click-through rather than hidden: hiding it would re-lay out the player frame from addon code.
local blizzHidden, settingAlpha = false, false
local function setBlizzardHidden(hide)
	if not TotemFrame or blizzHidden == hide then return end
	blizzHidden = hide
	settingAlpha = true
	TotemFrame:SetAlpha(hide and 0 or 1)
	settingAlpha = false
	for _, child in ipairs({ TotemFrame:GetChildren() }) do
		if child.EnableMouse and not (child.IsProtected and child:IsProtected()) then child:EnableMouse(not hide) end
	end
end

local attachPending = false
local function applyAttach()
	if InCombatLockdown() then attachPending = true return end   -- the bar holds protected buttons: no re-anchoring in combat
	attachPending = false
	local attached = db.attach and PlayerFrame ~= nil
	setBlizzardHidden(attached and true or false)
	bar:ClearAllPoints()
	if attached then
		bar:SetPoint("TOPLEFT", PlayerFrame, "BOTTOMLEFT", db.attachX, db.attachY)
	else
		bar:SetPoint(db.point, UIParent, db.relPoint, db.x, db.y)
	end
end

if TotemFrame then
	-- Blizzard re-shows it whenever totems change; keep it invisible while we replace it
	hooksecurefunc(TotemFrame, "SetAlpha", function(self, a)
		if blizzHidden and not settingAlpha and (isSecret(a) or a ~= 0) then
			settingAlpha = true
			self:SetAlpha(0)
			settingAlpha = false
		end
	end)
	if TotemFrame.Update then hooksecurefunc(TotemFrame, "Update", function()
		if blizzHidden then
			settingAlpha = true
			TotemFrame:SetAlpha(0)
			settingAlpha = false
		end
	end) end
end

-- ---------------------------------------------------------------- public API for the options panel

function ns.apply()
	if not bar then return end
	if previewing then showPreview() else refreshAll() end
	bar:EnableMouse(db.locked == false)
end

-- Sample totems are only for an empty bar: real totems always win, so being unlocked or having the
-- settings open can never hide what is really out.
local function anyRealTotem()
	for slot = 1, MAX_SLOTS do
		if readSlot(slot) == true then return true end
	end
	return false
end

function ns.updatePreview()
	applyAttach()
	bar:EnableMouse(db.locked == false and not db.attach)
	local want = ns.optionsOpen and not anyRealTotem()   -- samples: only a live preview while the panel is open
	if want and not previewing then showPreview()
	elseif not want and previewing then endPreview()
	else ns.apply() end
	updateShown()
end

function ns.resetPosition()
	local d = ns.defaults
	db.point, db.relPoint, db.x, db.y = d.point, d.relPoint, d.x, d.y
	db.attachX, db.attachY = d.attachX, d.attachY
	applyAttach()
end

function ns.get() return db end

-- Reordering (settings panel). `pos` is the place in the bar (1 = first), `delta` -1 = earlier, +1 = later.
function ns.moveSlot(pos, delta)
	local o = fixOrder()
	local to = pos + delta
	if not o[pos] or not o[to] then return false end
	o[pos], o[to] = o[to], o[pos]
	if bar then ns.apply() end
	return true
end

function ns.resetOrder()
	db.order = defaultOrder()
	if bar then ns.apply() end
end

-- ---------------------------------------------------------------- setup

local guardedTick = guard("update", tick)

local function build()
	bar = CreateFrame("Frame", "TotemRangeBar", UIParent)
	bar:SetClampedToScreen(true)
	bar:SetMovable(true)
	bar:RegisterForDrag("LeftButton")
	bar:SetScript("OnDragStart", function(self) if db.locked == false and not db.attach then self:StartMoving() end end)
	bar:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		local p, _, rp, x, y = self:GetPoint()
		db.point, db.relPoint, db.x, db.y = p, rp, x, y
	end)
	bar:SetPoint(db.point, UIParent, db.relPoint, db.x, db.y)
	for slot = 1, MAX_SLOTS do
		buttons[slot] = newButton(slot)
		hits[slot] = newHit(slot, buttons[slot])
	end
	applyAttach()
	layout()

	local acc = 0
	bar:SetScript("OnUpdate", function(_, elapsed)
		acc = acc + elapsed
		if acc >= TICK then acc = 0; guardedTick() end
	end)
end

-- Totemic Call (Totemic Projection in the client's data): teleports your totems to you
local MOVE_SPELL_ID = 437009
local function isMoveSpell(id)
	if id == MOVE_SPELL_ID then return true end
	local info = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(id)
	local name = info and info.name
	return type(name) == "string" and not isSecret(name) and (name == "Totemic Call" or name == "Totemic Projection")
end

-- A totem spell just succeeded. The totem event (which fires in combat too) records the position; this
-- only supplies the name when the game hides it, so the right radius (Earthbind 10 yd, ...) is used.
local MULTI = { ["Call of the Elements"] = true, ["Call of the Ancestors"] = true, ["Call of the Spirits"] = true }
local function onTotemCast(id)
	local info = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(id)
	local cast = info and info.name
	if type(cast) ~= "string" or isSecret(cast) then return end
	if MULTI[cast] or not cast:find("Totem", 1, true) then return end
	lastCast.name, lastCast.t = cast, GetTime()
	C_Timer.After(0.3, function()
		for slot, st in pairs(state) do
			if not st.name and GetTime() - (st.t or 0) < 2 then
				st.name = cast
				st.range, st.aura = classify(cast)
				st.last = nil
				dbg("named slot %d from cast: %s", slot, cast)
			end
		end
	end)
end

-- Safety net. The bar only learns about a totem from PLAYER_TOTEM_UPDATE, and its own tick stops while the
-- bar is hidden (which is exactly when it is empty). If an event is ever missed, a totem that is out would
-- stay invisible until combat ends or a loading screen. So a frame that is never hidden looks for totems
-- the bar does not show. Position unknown => the "?" mark, never a guessed in/out of range.
local function rescan()
	if previewing or not bar then return end
	local found = false
	for slot = 1, MAX_SLOTS do
		if not buttons[slot]:IsShown() and readSlot(slot) == true then
			dbg("RESCAN found slot %d showing nothing (missed event); showing it with unknown range", slot)
			refreshSlot(slot)
			found = true
		end
	end
	if found then layout() updateShown() tick() end
end
local guardedRescan = guard("rescan", rescan)

local reportedUnlocked = false
local ev = CreateFrame("Frame")
do
	local acc = 0
	ev:SetScript("OnUpdate", function(_, elapsed)
		acc = acc + elapsed
		if acc >= 0.5 then acc = 0; guardedRescan() end
	end)
end
ev:RegisterEvent("ADDON_LOADED")
ev:SetScript("OnEvent", guard("event", function(self, event, arg1, ...)
	if event == "ADDON_LOADED" and arg1 == ADDON then
		TotemRangeDB = TotemRangeDB or {}
		db = TotemRangeDB
		for k, v in pairs(ns.defaults) do if db[k] == nil then db[k] = v end end
		fixOrder()
		self:UnregisterEvent("ADDON_LOADED")
		if InCombatLockdown() then
			-- secure buttons can't be made in combat: build when it ends
			self:RegisterEvent("PLAYER_REGEN_ENABLED")
			self.deferredBuild = true
			return
		end
		build()
		self:RegisterEvent("PLAYER_ENTERING_WORLD")
		self:RegisterEvent("PLAYER_TOTEM_UPDATE")
		self:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
		self:RegisterEvent("PLAYER_REGEN_DISABLED")
		self:RegisterEvent("PLAYER_REGEN_ENABLED")
		if ns.buildOptions then ns.buildOptions() end
	elseif event == "PLAYER_ENTERING_WORLD" then
		for slot in pairs(state) do state[slot] = nil end   -- loading screen: positions mean nothing now
		ns.updatePreview()
		refreshAll()
		if db.locked == false and not reportedUnlocked then
			reportedUnlocked = true
			print("|cff33ff99TotemRange|r: the frame is unlocked (drag the box to move it). /totemrange lock to lock it.")
		end
	elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
		-- Totemic Call / Projection moves every totem to you without a totem event, so re-record
		-- where they are: right here
		local id = select(2, ...)
		if readable(id) and not previewing then
			onTotemCast(id)
		end
		if readable(id) and isMoveSpell(id) and not previewing then
			local at = playerPos()
			for slot, st in pairs(state) do
				st.at, st.last = at, nil
				dbg("MOVED slot %d %s by spell %d to %s", slot, tostring(st.name), id, describe(at))
			end
		end
	elseif event == "PLAYER_REGEN_ENABLED" and self.deferredBuild then
		self.deferredBuild = nil
		build()
		self:RegisterEvent("PLAYER_ENTERING_WORLD")
		self:RegisterEvent("PLAYER_TOTEM_UPDATE")
		self:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
		self:RegisterEvent("PLAYER_REGEN_DISABLED")
		if ns.buildOptions then ns.buildOptions() end
		refreshAll()
	elseif event == "PLAYER_REGEN_DISABLED" or event == "PLAYER_REGEN_ENABLED" then
		-- what can still be read across the combat boundary (for the log)
		local aura = hasAura("Strength of Earth")
		dbg("%s: %s | aura readable=%s", event == "PLAYER_REGEN_DISABLED" and "COMBAT START" or "COMBAT END",
			describe(playerPos()), tostring(aura ~= nil))
		for slot in pairs(state) do state[slot].last = nil end
		if event == "PLAYER_REGEN_ENABLED" then
			if attachPending then applyAttach() end
			if previewing then layout() else refreshAll() end   -- catch what changed during the fight; make new totems clickable
		end
	elseif event == "PLAYER_TOTEM_UPDATE" then
		if not readable(arg1) then
			dbg("PLAYER_TOTEM_UPDATE with an unreadable slot: the rescan will pick it up")
			return
		end
		if previewing then
			if not anyRealTotem() then return end
			endPreview()   -- a real totem is out: drop the samples first
		end
		refreshSlot(arg1, true)
		layout()
		updateShown()
		tick()
		-- the last real totem went away while unlocked / settings open: back to the samples
		if ns.optionsOpen then ns.updatePreview() end
	end
end))

-- ---------------------------------------------------------------- slash

SLASH_TOTEMRANGE1 = "/totemrange"
SLASH_TOTEMRANGE2 = "/trange"
SlashCmdList.TOTEMRANGE = function(msg)
	msg = (msg or ""):lower():match("^%s*(%S*)")
	if msg == "unlock" or msg == "lock" then
		db.locked = msg == "lock"
		ns.updatePreview()
		print("|cff33ff99TotemRange|r: frame " .. (db.locked and "locked" or "unlocked - open /totemrange to see and drag it"))
	elseif msg == "reset" then
		ns.resetPosition()
	elseif msg == "status" then
		local any = false
		for slot = 1, MAX_SLOTS do
			local s = state[slot]
			if s then
				any = true
				local r, how = rangeOf(slot)
				print(("|cff33ff99TotemRange|r slot %d: %s, radius %d, %s via %s"):format(slot, s.name or "?", s.range,
					r == true and "in range" or r == false and "OUT of range" or "unknown", how))
			end
		end
		if not any then print("|cff33ff99TotemRange|r: no active totems") end
	elseif ns.openOptions then
		ns.openOptions()
	end
end
