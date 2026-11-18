-- ShamanKit: small helpers for shamans.
--   Totem bar: your active totems, their timers, and whether you are in range of each.
--   Buffs: two small icons, one for a missing / running-out weapon enchant and one for Lightning Shield charges.
--
-- Totem range: a totem is dropped at your feet, so your position when it appears IS the totem's position.
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
	showRange = true,       -- green check when in range
	showOut = true,         -- red cross when out of range
	rememberLast = true,    -- a placeholder shows the last totem that was out in that place (a chosen totem always wins)
	distanceMode = "bar",   -- how far you are from each totem: "bar" (room left in its radius), "yards" (exact number) or "off"
	tint = true,
	locked = true,
	attach = false,        -- replace the default totem timers and sit under the player frame
	attachX = 65, attachY = 8,
	point = "CENTER", relPoint = "CENTER", x = 0, y = -200,
	weaponOn = true,        -- buff icon: the weapon has no enchant (or one about to run out)
	shieldOn = true,        -- buff icon: the Lightning Shield charges while it is up
	auxAnchor = "bar",      -- what the two buff icons hang on: "bar" (the totem bar), "player" (the player frame) or "free" (a place of their own, drag it when unlocked)
	auxSide = "auto",       -- which side of it: "auto" (below the bar, beside a vertical bar; below the player frame, above it if the bar is there), "bottom", "top", "left", "right"
	auxAlign = "start",     -- along that side: "start", "center" or "end"
	auxOffX = 0, auxOffY = 0,   -- nudge from that spot
	auxScale = 75,          -- icon size as a percent of the totem icon size
	auxWarnMin = 2,         -- the weapon icon also shows when its enchant has less than this many minutes left (0 = only when gone)
	auxPoint = "CENTER", auxRelPoint = "CENTER", auxX = 0, auxY = -260,   -- own place when not attached
}

-- Settings saved by older versions, brought up to date before the defaults are filled in.
function ns.migrate(d)
	if d.showRange == false and d.showOut == nil then d.showOut = false end   -- the old single switch hid both marks
	if d.auxAnchor == nil then d.auxAnchor = (d.auxAttached == false) and "free" or "bar" end   -- "attached or not" became bar / player frame / own place
	d.auxAttached = nil
end

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

-- db.reserve[slot] = true keeps that element's place open in the bar even when no totem of it is out (a dim
-- placeholder fills it), so the gap itself shows what is missing. Always a table of booleans.
local function fixReserve()
	local r = db.reserve
	if type(r) ~= "table" then r = {}; db.reserve = r end
	for slot = 1, MAX_SLOTS do if r[slot] ~= true and r[slot] ~= nil then r[slot] = nil end end
	return r
end
ns.fixReserve = fixReserve

-- The totems of each element (slot), for the placeholder-icon picker, and for working out which totem an
-- icon belongs to when the game hides it in combat. Entry: display name, then spell ids to try (the first one
-- this client knows is used; Forever has its own Fire Nova, for one).
local CATALOGUE = {
	[2] = { { "Stoneclaw Totem", 5730 }, { "Stoneskin Totem", 8071 }, { "Earthbind Totem", 2484 },
		{ "Strength of Earth Totem", 8075 }, { "Tremor Totem", 8143 }, { "Earth Elemental Totem", 2062 } },
	[1] = { { "Searing Totem", 3599 }, { "Fire Nova", 408341, 1535 }, { "Magma Totem", 8190 },
		{ "Flametongue Totem", 8227 }, { "Frost Resistance Totem", 8181 }, { "Fire Elemental Totem", 2894 } },
	[3] = { { "Healing Stream Totem", 5394 }, { "Mana Spring Totem", 5675 }, { "Fire Resistance Totem", 8184 },
		{ "Disease Cleansing Totem", 8170 }, { "Poison Cleansing Totem", 8166 }, { "Mana Tide Totem", 16190 } },
	[4] = { { "Grounding Totem", 8177 }, { "Nature Resistance Totem", 10595 }, { "Windfury Totem", 8512 },
		{ "Sentry Totem", 6495 }, { "Windwall Totem", 15107 }, { "Grace of Air Totem", 8835 }, { "Tranquil Air Totem", 25908 } },
}
local GENERIC_ICON_SPELL = { [1] = 3599, [2] = 8071, [3] = 5394, [4] = 8835 }   -- one totem per element, when nothing is known
local QUESTION = "Interface\\Icons\\INV_Misc_QuestionMark"

local texCache = {}
local function spellTexture(id)
	local t = texCache[id]
	if not t then
		t = C_Spell and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(id)
		if t then texCache[id] = t end   -- only successes are kept: a miss is retried
	end
	return t
end

local function spellInfo(id)
	if not (C_Spell and C_Spell.GetSpellInfo) then return nil end
	local ok, info = pcall(C_Spell.GetSpellInfo, id)
	return ok and info or nil
end

-- the id of a catalogue entry this client has, or nil
local function entryId(entry)
	for i = 2, #entry do if spellInfo(entry[i]) then return entry[i] end end
	if not (C_Spell and C_Spell.GetSpellInfo) then return entry[2] end   -- can't ask: trust the list
end

-- The totems of one element that exist in this game, in a fixed order: { { id =, name =, tex = }, ... }
function ns.totemChoices(slot)
	local out = {}
	for _, entry in ipairs(CATALOGUE[slot] or {}) do
		local id = entryId(entry)
		local tex = id and spellTexture(id)
		if id and tex then
			local info = spellInfo(id)
			out[#out + 1] = { id = id, name = (info and type(info.name) == "string" and info.name ~= "") and info.name or entry[1], tex = tex }
		end
	end
	return out
end

-- icon of the totem called `name` (any rank), or nil
local function iconForName(name)
	if type(name) ~= "string" or isSecret(name) then return nil end
	local lower = name:lower()
	for _, list in pairs(CATALOGUE) do
		for _, entry in ipairs(list) do
			local key = entry[1]:lower():gsub(" totem$", "")
			if lower:find(key, 1, true) then
				local id = entryId(entry)
				return id and spellTexture(id) or nil
			end
		end
	end
end

-- db.hold.last[slot] = icon of the last totem seen in that place; db.hold.choice[slot] = spell id of the totem the
-- player locked that place's placeholder to. Always plain tables with plain values.
local function fixHold()
	local h = db.hold
	if type(h) ~= "table" then h = {}; db.hold = h end
	if type(h.last) ~= "table" then h.last = {} end
	if type(h.choice) ~= "table" then h.choice = {} end
	for slot = 1, MAX_SLOTS do
		local l, c = h.last[slot], h.choice[slot]
		if l ~= nil and not ((type(l) == "number" or type(l) == "string") and not isSecret(l)) then h.last[slot] = nil end
		if c ~= nil and type(c) ~= "number" then h.choice[slot] = nil end
	end
	return h
end
ns.fixHold = fixHold

-- What the dim placeholder shows: the locked totem, else (if remembering is on) the last totem that was out in
-- that place, else a generic totem of the element.
local function holderTexture(slot, h)
	h = h or fixHold()
	local id = h.choice[slot]
	local tex = id and spellTexture(id)
	if tex then return tex end
	if db.rememberLast ~= false and h.last[slot] then return h.last[slot] end
	return spellTexture(GENERIC_ICON_SPELL[slot]) or QUESTION
end
ns.holderTexture = holderTexture

-- Remember what a place last held. Done for every totem, even with remembering off, so turning it on later
-- already knows. The icon is used when readable; in combat it may be hidden, and the name stands in.
local function remember(slot, icon, name)
	local tex
	if icon ~= nil and not isSecret(icon) and (type(icon) == "number" or type(icon) == "string") then tex = icon
	else tex = iconForName(name) end
	if tex ~= nil and not isSecret(tex) and (type(tex) == "number" or type(tex) == "string") then
		local last = fixHold().last
		if last[slot] ~= tex then last[slot] = tex end
	end
end


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
local applyAux               -- the weapon / shield icons (defined further down); layout() asks it to re-place them
local auxMode                -- what those icons hang on: "bar", "player" or "free"

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
				print("|cff33ff99ShamanKit|r hit an error (" .. where .. "): " .. tostring(err) .. "  (also logged)")
			end
		end
	end
end

-- Bookkeeping must never stop a totem from being shown: it runs after the icon is up, and a failure is only logged.
local rememberSafe = guard("remember", remember)

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

-- True while the game hides aura details (in combat). Then a lookup does NOT say "you don't have it": it answers
-- "nothing" for auras that are there (seen in the log: the Lightning Shield read as gone half a second after every
-- fight started, and back half a second after it ended). So while this is true, "nothing" means "can't tell".
local function aurasHidden()
	if C_Secrets and C_Secrets.ShouldAurasBeSecret then
		local ok, r = pcall(C_Secrets.ShouldAurasBeSecret)
		if ok then return (isSecret(r) or r) and true or false end
	end
	return InCombatLockdown() and true or false   -- no such call here: assume a fight hides them
end

-- true / false, or nil when it can't be read
local function hasAura(name)
	if aurasHidden() then return nil end
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
	local b = CreateFrame("Button", "ShamanKitButton" .. slot, bar)
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

-- The placeholder for a reserved place with no totem in it: the element's totem icon, dimmed and grey, in the
-- same frame the action buttons use. A plain frame of its own (a button's children hide with the button).
local holds = {}
local function newHolder(slot)
	local h = CreateFrame("Frame", nil, bar)
	h.icon = h:CreateTexture(nil, "BACKGROUND")
	h.icon:SetAllPoints()
	h.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
	h.icon:SetTexture(QUESTION)   -- the real picture is set when it is shown (refreshHolders)
	h.icon:SetDesaturated(true)
	h.icon:SetAlpha(0.35)
	h.border = h:CreateTexture(nil, "OVERLAY")
	h.border:SetTexture("Interface\\Buttons\\UI-Quickslot2")
	h.border:SetPoint("CENTER", 0, -1)
	h.border:SetAlpha(0.6)
	h:Hide()
	return h
end

-- The clickable layer. Right-click dismisses the totem: the game only lets its own secure code do that,
-- so each slot gets a secure button with the built-in "destroytotem" action (what the default totem bar
-- uses). Secure buttons can't be created, moved, resized or have their attributes changed in combat,
-- so they are made once out of combat and only repositioned out of combat. The visible icon sits at the
-- same spot (it is a plain frame, so it can be shown/hidden in combat); a totem that appears mid-fight
-- shows where its button was parked and becomes clickable when the fight ends.
-- Moving the bar by hand (unlocked). The bar anchors the secure click buttons, so the game refuses to move it in
-- combat (ADDON_ACTION_BLOCKED on StartMoving, seen in the log): a drag is only started out of combat, and only a drag
-- that really started is finished and saved. A fight that begins mid-drag finishes it when the fight ends.
local barMoving = false
local function startBarMove()
	if db.locked == false and not db.attach and not InCombatLockdown() then
		bar:StartMoving()
		barMoving = true
	end
end
local function stopBarMove()
	if not barMoving then return end
	if InCombatLockdown() then return end   -- finished by PLAYER_REGEN_ENABLED
	barMoving = false
	bar:StopMovingOrSizing()
	local p, _, rp, x, y = bar:GetPoint()
	db.point, db.relPoint, db.x, db.y = p, rp, x, y
end

local function newHit(slot, b)
	local h = CreateFrame("Button", "ShamanKitHit" .. slot, bar, "SecureActionButtonTemplate")
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
	h:SetScript("OnDragStart", startBarMove)
	h:SetScript("OnDragStop", stopBarMove)
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
	local want, reserve, order = fixOrder(), fixReserve(), {}
	-- a place is taken by a totem that is out or by a reserved element (so a reserved totem that appears
	-- mid-fight lands exactly where its placeholder was)
	for _, slot in ipairs(want) do if buttons[slot]:IsShown() or reserve[slot] then order[#order + 1] = slot end end
	local n = #order
	-- the rest are parked after those: a totem that appears mid-fight lands on its own spot
	for _, slot in ipairs(want) do if not (buttons[slot]:IsShown() or reserve[slot]) then order[#order + 1] = slot end end
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
		h:EnableMouse(b:IsShown())   -- no invisible click-blocking squares where there is no totem
		local ph = holds[slot]
		ph:ClearAllPoints()
		ph:SetSize(s, s)
		ph.border:SetSize(s * 66 / 36, s * 66 / 36)
		ph:SetPoint("TOPLEFT", bar, "TOPLEFT", x, y)
	end
	local long = math.max(n, 1) * s + math.max(n - 1, 0) * gap
	if db.vertical then bar:SetSize(s, long) else bar:SetSize(long, s) end
	ns.refreshHolders()
	if applyAux then applyAux() end
end

local function setMark(b, r)
	-- check (in range) and cross (out of range) are separate options; "?" shows if either is on
	local want = r == nil and (db.showRange or db.showOut) or (r and db.showRange) or (r == false and db.showOut)
	if not want then b.mark:Hide() return end
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
	local showRange = (db.showRange and 1 or 0) + (db.showOut and 2 or 0)
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
	if isSecret(icon) then   -- the game hides the icon in a fight: the name of the totem tells which picture it is
		local ok, known = pcall(iconForName, s.name)
		if ok and known and not isSecret(known) then pcall(b.icon.SetTexture, b.icon, known) end
	end
	refreshTimer(b, slot, start, duration)
	sizeButton(b)
	invalidate(b)
	b:Show()
	rememberSafe(slot, icon, s.name)
end

-- Placeholders: only for reserved places that are empty, and only while the bar is up (a totem is out, or the
-- settings are open): with nothing out at all there is nothing to compare against, so nothing is drawn.
local function doRefreshHolders()
	local reserve, hold = fixReserve(), fixHold()
	local up = bar and (bar.anyShown or previewing)
	for slot = 1, MAX_SLOTS do
		local ph = holds[slot]
		if ph then
			local show = up and reserve[slot] and not buttons[slot]:IsShown() and true or false
			ph:SetShown(show)
			if show then
				local tex = holderTexture(slot, hold)
				if ph.tex ~= tex then ph.tex = tex; ph.icon:SetTexture(tex) end
			end
		end
	end
end
ns.refreshHolders = guard("placeholders", doRefreshHolders)

local function updateShown()
	local any = false
	for slot = 1, MAX_SLOTS do if buttons[slot]:IsShown() then any = true end end
	bar.anyShown = any
	-- The bar frame itself is never shown or hidden: the secure click buttons are anchored to it, which makes it
	-- restricted in combat (touching it then is what raises the game's "action blocked" popup). When no totem is
	-- out, everything on it is hidden, so an empty bar is simply invisible.
	ns.refreshHolders()
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
	if previewing or not bar.anyShown then return end   -- nothing out: nothing to read (the rescan notices a new totem)
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
		if fixReserve()[slot] then
			b:Hide()   -- the preview of a missing totem: its placeholder shows instead of a sample
		else
			b:Show()
			paintRange(b, slot ~= 3, SAMPLE_DIST[slot], SAMPLE_RANGE[slot])   -- one shown out of range so the look can be judged
		end
	end
	layout()
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

local mousePending = false
local function applyBarMouse()
	if InCombatLockdown() then mousePending = true return end
	mousePending = false
	bar:EnableMouse(db.locked == false and not db.attach)
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

-- ---------------------------------------------------------------- weapon enchant + Lightning Shield icons

-- Two small icons next to the totem bar. Like the totem icons they are plain frames (children of the bar, which
-- is restricted in combat), so in combat they are only ever shown or hidden: where they sit and how big they are
-- changes out of combat only (applyAux defers). A reading the game hides (secret) or can't give leaves the icon
-- as it was; a missing enchant is only claimed when the game plainly said "none".
local aux, ind = nil, {}
local auxPending = false
local auxMoving = false
local WARN_DEFAULT_MIN = 2                    -- minutes
local WEAPON_MAIN = (Enum and Enum.WeaponSlot and Enum.WeaponSlot.MainHand) or 0
local WEAPON_CLASS = (Enum and Enum.ItemClass and Enum.ItemClass.Weapon) or 2
local FISHING_POLE = 20                        -- weapon subclass: nobody wants an imbue reminder while fishing
local IMBUE_SPELLS = { 8232, 8024, 8033, 8017 }  -- Windfury, Flametongue, Frostbrand, Rockbiter Weapon (rank 1): the first you know gives the icon
local SHIELD_ID = 324                          -- Lightning Shield, rank 1 (the aura is looked up by name, so any rank)
local SHIELD_FALLBACK_ICON = "Interface\\Icons\\Spell_Nature_LightningShield"

local function knownSpell(id)
	if IsPlayerSpell then
		local ok, r = pcall(IsPlayerSpell, id)
		if ok and not isSecret(r) and r then return true end
	end
	if C_SpellBook and C_SpellBook.IsSpellKnown then
		local ok, r = pcall(C_SpellBook.IsSpellKnown, id)
		if ok and not isSecret(r) and r then return true end
	end
	return false
end

-- the picture on the weapon icon: the last enchant seen on the weapon (what you actually use), else the best
-- imbue you know, else Rockbiter
local function weaponIcon()
	local last = db.lastImbue
	if last ~= nil and (type(last) == "number" or type(last) == "string") and not isSecret(last) then return last end
	for _, id in ipairs(IMBUE_SPELLS) do
		if knownSpell(id) then
			local tex = spellTexture(id)
			if tex then return tex end
		end
	end
	return spellTexture(8017) or QUESTION
end

local shieldName
local function shieldAuraName()
	if shieldName then return shieldName end
	local info = spellInfo(SHIELD_ID)
	local n = info and info.name
	if type(n) == "string" and not isSecret(n) and n ~= "" then shieldName = n; return n end
	return "Lightning Shield"
end

-- "keep" (can't tell right now), "none" (nothing to remind about), "missing", "ok" or "expiring";
-- then the seconds left (nil = no time known), the picture of the enchant on the weapon, and the raw list.
local function readWeapon()
	local okd, dead = pcall(UnitIsDeadOrGhost, "player")
	if okd then
		if isSecret(dead) then return "keep" end
		if dead then return "none" end
	end
	local id = GetInventoryItemID and GetInventoryItemID("player", 16)
	if isSecret(id) then return "keep" end
	if not id then return "none" end                           -- nothing in the main hand
	if not (C_Item and C_Item.GetItemInfoInstant and C_Item.GetWeaponEnchantInfo) then return "keep" end
	local iok, _, _, _, _, _, class, sub = pcall(C_Item.GetItemInfoInstant, id)
	if not iok or class == nil or isSecret(class) or isSecret(sub) then return "keep" end
	if class ~= WEAPON_CLASS or sub == FISHING_POLE then return "none" end
	local ok, list = pcall(C_Item.GetWeaponEnchantInfo, WEAPON_MAIN)
	if not ok or isSecret(list) then return "keep" end
	if list ~= nil and type(list) ~= "table" then return "keep" end
	local active, left, icon, untimed = false, nil, nil, false
	if list then
		for _, e in ipairs(list) do
			if type(e) == "table" and not isSecret(e) then
				local h = e.hasEnchant
				if isSecret(h) then return "keep" end
				if h then
					active = true
					local ms = e.timeLeft
					if readable(ms) and ms > 0 then
						if not left or ms / 1000 > left then left = ms / 1000 end   -- the longest-lasting one is what is still protecting you
					else
						untimed = true
					end
					if readable(e.enchantIconID) then icon = e.enchantIconID end
				end
			end
		end
	end
	if not active then return "missing", nil, nil, list end
	if untimed or not left then return "ok", nil, icon, list end
	local warn = (readable(db.auxWarnMin) and db.auxWarnMin or WARN_DEFAULT_MIN) * 60   -- 0 = only when it is gone
	if warn > 0 and left <= warn then return "expiring", left, icon, list end
	return "ok", left, icon, list
end

-- Lightning Shield: false (not up), true + charges (the number may be hidden), or "keep" (can't tell right now).
-- A "not up" is only believed while auras are readable. While the game hides them, the one other lookup that may still
-- answer (by spell id) is tried; if that says nothing too, the answer is "keep".
local S = { up = false }        -- the last reading of the shield
local SHIELD_RANKS = { 324, 325, 905, 945, 8134, 10431, 10432 }
local function shieldCharges(data)
	local n = data.applications
	if not isSecret(n) and not (type(n) == "number" and n > 0) then
		local c = data.charges
		if isSecret(c) or (type(c) == "number" and c > 0) then n = c else n = nil end
	end
	return n
end

local function readShield()
	if not (C_UnitAuras and C_UnitAuras.GetAuraDataBySpellName) then return "keep" end
	local hidden = aurasHidden()
	local ok, data = pcall(C_UnitAuras.GetAuraDataBySpellName, "player", shieldAuraName(), "HELPFUL")
	if not ok or isSecret(data) then return "keep" end
	if data == nil and hidden then
		local viaId
		if C_UnitAuras.GetPlayerAuraBySpellID then
			for _, id in ipairs(SHIELD_RANKS) do
				local ok2, d = pcall(C_UnitAuras.GetPlayerAuraBySpellID, id)
				if ok2 and type(d) == "table" and not isSecret(d) then data = d; viaId = id break end
			end
		end
		if not S.loggedHidden then   -- once per fight: what the game let us read (so the next report has the facts)
			S.loggedHidden = true
			dbg("SHIELD auras hidden (combat=%s): by name = nothing, by spell id = %s", tostring(InCombatLockdown()), viaId and ("found " .. viaId) or "nothing")
		end
		if data == nil then return "keep" end
	end
	if data == nil then return false end
	if type(data) ~= "table" then return "keep" end
	return true, shieldCharges(data)
end

local function timeText(secs)
	if not secs then return "" end
	if secs >= 60 then return ("%dm"):format(math.ceil(secs / 60)) end
	return ("%ds"):format(math.max(0, math.floor(secs)))
end

local function num(v, default) if readable(v) then return v end return default end
local function auxSize() return math.max(16, math.floor(db.size * num(db.auxScale, 75) / 100 + 0.5)) end

local function indTooltip(self)
	GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
	if self.kind == "shield" then
		GameTooltip:SetText(shieldAuraName())
		if self.tipLine then GameTooltip:AddLine(self.tipLine, 1, 1, 1) end
	else
		GameTooltip:SetText("Weapon enchant")
		if self.tipLine then GameTooltip:AddLine(self.tipLine, 1, 1, 1) end
	end
	GameTooltip:Show()
end

local function newIndicator(kind)
	local f = CreateFrame("Frame", "ShamanKit" .. (kind == "shield" and "Shield" or "Weapon"), aux)
	f.kind = kind
	f.icon = f:CreateTexture(nil, "BACKGROUND")
	f.icon:SetAllPoints()
	f.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

	f.over = CreateFrame("Frame", nil, f)
	f.over:SetAllPoints()
	f.over:SetFrameLevel(f:GetFrameLevel() + 2)
	f.border = f.over:CreateTexture(nil, "OVERLAY")                 -- the action-button bevel, like the totem icons
	f.border:SetTexture("Interface\\Buttons\\UI-Quickslot2")
	f.border:SetPoint("CENTER", 0, -1)

	-- the action bar's own highlight ring: pulses red when the enchant is gone, steady yellow when it is running out
	f.glow = f.over:CreateTexture(nil, "OVERLAY", nil, 2)
	f.glow:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
	f.glow:SetBlendMode("ADD")
	f.glow:SetPoint("CENTER")
	f.glow:Hide()
	local ok, ag = pcall(function()
		local g = f.glow:CreateAnimationGroup()
		g:SetLooping("BOUNCE")
		local a = g:CreateAnimation("Alpha")
		a:SetFromAlpha(1); a:SetToAlpha(0.3); a:SetDuration(0.7)
		return g
	end)
	if ok and ag then f.pulse = ag end

	f.count = f.over:CreateFontString(nil, "OVERLAY", "NumberFontNormal")     -- charges, like a buff's stack count
	f.count:SetPoint("BOTTOMRIGHT", -1, 2)
	f.time = f.over:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall") -- time left, like a cooldown number
	f.time:SetPoint("BOTTOM", 0, 2)

	f:EnableMouse(true)
	f:SetScript("OnEnter", guard("tooltip", indTooltip))
	f:SetScript("OnLeave", GameTooltip_Hide)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", function()
		if db.locked == false and auxMode() == "free" and not InCombatLockdown() then aux:StartMoving(); auxMoving = true end
	end)
	f:SetScript("OnDragStop", function()
		if not auxMoving then return end   -- nothing was started (locked, or attached): nothing to save
		auxMoving = false
		aux:StopMovingOrSizing()
		local p, _, rp, x, y = aux:GetPoint()
		db.auxPoint, db.auxRelPoint, db.auxX, db.auxY = p, rp, x, y
	end)
	f:Hide()
	return f
end

-- Where the icons sit (db.auxAnchor). On the totem bar or the player frame: on a side of it (db.auxSide), lined up along
-- that side (db.auxAlign) and nudged by db.auxOffX / auxOffY. Otherwise a place of their own.
-- The shield takes the first place so the usual picture (shield up, enchant fine) has no gap. Out of combat only.
-- "bar", "player" or "free"; anything else (a damaged value, or no player frame) means the bar
auxMode = function()
	local a = db.auxAnchor
	if a == "free" then return "free" end
	if a == "player" and PlayerFrame then return "player" end
	return "bar"
end
ns.auxMode = auxMode

local function auxSide()
	local sd = db.auxSide
	if sd == "bottom" or sd == "top" or sd == "left" or sd == "right" then return sd end
	if auxMode() == "player" then return db.attach and "top" or "bottom" end   -- the totem bar hangs under the player frame when it replaces the default timers
	return db.vertical and "left" or "bottom"
end
ns.auxSide = auxSide

-- { the icons' own point, the bar's point } for each side and alignment
local SIDE_POINTS = {
	bottom = { start = { "TOPLEFT", "BOTTOMLEFT" }, center = { "TOP", "BOTTOM" }, ["end"] = { "TOPRIGHT", "BOTTOMRIGHT" } },
	top = { start = { "BOTTOMLEFT", "TOPLEFT" }, center = { "BOTTOM", "TOP" }, ["end"] = { "BOTTOMRIGHT", "TOPRIGHT" } },
	left = { start = { "TOPRIGHT", "TOPLEFT" }, center = { "RIGHT", "LEFT" }, ["end"] = { "BOTTOMRIGHT", "BOTTOMLEFT" } },
	right = { start = { "TOPLEFT", "TOPRIGHT" }, center = { "LEFT", "RIGHT" }, ["end"] = { "BOTTOMLEFT", "BOTTOMRIGHT" } },
}
-- the end of the bar where new totems appear (right of a horizontal bar, bottom of a vertical one): the bar is only as
-- long as the totems showing, but a totem that appears mid-fight lands in the next place, so icons put there start
-- after all the places instead
local FAR_REL = {
	right = { start = "TOPLEFT", center = "LEFT", ["end"] = "BOTTOMLEFT" },
	bottom = { start = "TOPLEFT", center = "TOP", ["end"] = "TOPRIGHT" },
}

-- room next to the bar taken by the range bars / the yards text, so the icons don't sit on them
local function edgeGap(side, mode)
	local barOrText = mode == "bar" and ((not db.vertical and side == "bottom") or (db.vertical and side == "right"))
	if not barOrText then return 6 end
	local mode = distMode()
	if mode == "bar" then return GAUGE_GAP + math.max(5, math.floor(db.size * 0.16 + 0.5)) + 6 end
	if mode == "yards" then return db.vertical and 52 or 18 end
	return 6
end

applyAux = function()
	if not aux then return end
	if InCombatLockdown() then auxPending = true return end
	auxPending = false
	local s, gap = auxSize(), db.spacing
	local mode = auxMode()
	local side = auxSide()
	local row = side == "bottom" or side == "top"       -- side by side along a top / bottom edge, stacked beside it
	local place = 0
	for _, kind in ipairs({ "shield", "weapon" }) do
		local f = ind[kind]
		local on = (kind == "shield" and db.shieldOn) or (kind == "weapon" and db.weaponOn)
		f:SetSize(s, s)
		f.border:SetSize(s * 66 / 36, s * 66 / 36)
		f.glow:SetSize(s * 62 / 36, s * 62 / 36)
		f:ClearAllPoints()
		if on then
			local off = place * (s + gap)
			if row then f:SetPoint("TOPLEFT", aux, "TOPLEFT", off, 0) else f:SetPoint("TOPLEFT", aux, "TOPLEFT", 0, -off) end
			place = place + 1
		else
			f:SetPoint("TOPLEFT", aux, "TOPLEFT", 0, 0)
		end
	end
	local long = math.max(place, 1) * s + math.max(place - 1, 0) * gap
	if row then aux:SetSize(long, s) else aux:SetSize(s, long) end
	aux:ClearAllPoints()
	if mode ~= "free" then
		local target = mode == "player" and PlayerFrame or bar
		local align = db.auxAlign
		if align ~= "center" and align ~= "end" then align = "start" end
		local pair = SIDE_POINTS[side][align]
		local g = edgeGap(side, mode)
		local x = side == "left" and -g or (side == "right" and g or 0)
		local y = side == "top" and g or (side == "bottom" and -g or 0)
		local rel = pair[2]
		local far = mode == "bar" and ((not db.vertical and side == "right" and "right") or (db.vertical and side == "bottom" and "bottom"))
		if far then
			rel = FAR_REL[far][align]
			local full = MAX_SLOTS * db.size + (MAX_SLOTS - 1) * db.spacing
			if far == "right" then x = x + full else y = y - full end
		end
		aux:SetPoint(pair[1], target, rel, x + num(db.auxOffX, 0), y + num(db.auxOffY, 0))
	else
		aux:SetPoint(db.auxPoint or "CENTER", UIParent, db.auxRelPoint or "CENTER", num(db.auxX, 0), num(db.auxY, -260))
	end
end

-- Samples of the two icons (so there is something to look at and to grab): ONLY while a settings page is open, and
-- only where the real thing is not showing. Never otherwise: a sample looks exactly like the real icon, so one that
-- stayed on screen read as "my enchant is missing" / "I have the shield" when neither was true.
local function showSamples()
	return ns.optionsOpen
end

local W = { st = "none" }       -- the last reading of the weapon

local function rawList(list)
	if type(list) ~= "table" then return tostring(list) end
	local out = {}
	for i, e in ipairs(list) do
		if type(e) == "table" and not isSecret(e) then
			local function v(x) return (isSecret(x) and "?") or tostring(x) end
			out[#out + 1] = ("{type=%s id=%s icon=%s ms=%s}"):format(v(e.enchantType), v(e.enchantID), v(e.enchantIconID), v(e.timeLeft))
		end
	end
	return #out > 0 and table.concat(out, " ") or "(empty)"
end

local function paintWeapon()
	local f = ind.weapon
	if not f then return end
	if db.weaponOn then
		local st, left, icon, list = readWeapon()
		if st ~= "keep" then
			if st ~= W.st then dbg("WEAPON %s left=%s combat=%s entries=%s", st, left and ("%.0f"):format(left) or "-", tostring(InCombatLockdown()), rawList(list)) end
			W.st, W.left = st, left
			if icon and icon ~= db.lastImbue then db.lastImbue = icon end
		end
	end
	local real = db.weaponOn and (W.st == "missing" or W.st == "expiring")
	local view = real and W.st or ((db.weaponOn and showSamples()) and "sample" or "off")
	local text = view == "expiring" and timeText(W.left) or ""
	local key = view .. "|" .. text .. "|" .. tostring(db.lastImbue)
	if f.vkey == key then return end
	f.vkey = key
	if view == "off" then
		if f.pulse then f.pulse:Stop() end
		f.glow:Hide()
		f:Hide()
		return
	end
	f.icon:SetTexture(weaponIcon())
	f.count:SetText("")
	f.time:SetText(text)
	local missing = view ~= "expiring"          -- missing (or the sample): grey picture + red pulse
	f.icon:SetDesaturated(missing)
	if missing then f.glow:SetVertexColor(1, 0.2, 0.1) else f.glow:SetVertexColor(1, 0.82, 0) end
	f.glow:Show()
	if f.pulse then if missing then f.pulse:Play() else f.pulse:Stop(); f.glow:SetAlpha(1) end end
	f.tipLine = missing and "Your weapon has no enchant." or ("Your weapon enchant ends in " .. text .. ".")
	f:Show()
end

local function paintShield()
	local f = ind.shield
	if not f then return end
	if db.shieldOn then
		local r, n = readShield()
		if r ~= "keep" then
			if (r and true or false) ~= S.up then dbg("SHIELD %s charges=%s combat=%s", r and "up" or "down", isSecret(n) and "?" or tostring(n), tostring(InCombatLockdown())) end
			S.up, S.n, S.stale = r and true or false, n, false
		else
			S.stale = S.up and true or false   -- can't tell right now: the icon stays, but its number is no longer known
		end
	end
	local real = db.shieldOn and S.up
	local view = real and "up" or ((db.shieldOn and showSamples()) and "sample" or "off")
	local stale = view == "up" and S.stale
	local n = view == "sample" and 3 or S.n
	if stale then n = "?" end                   -- an unknown number is shown as a yellow ?, never as the last (now wrong) one
	local hidden = isSecret(n)                  -- a hidden number can't be compared, so it is passed straight on and never cached
	local key = view .. "|" .. (hidden and "?" or tostring(n))
	if not hidden and f.vkey == key then return end
	f.vkey = (not hidden) and key or nil
	if view == "off" then f:Hide() return end
	f.icon:SetTexture(spellTexture(SHIELD_ID) or SHIELD_FALLBACK_ICON)
	f.icon:SetDesaturated(false)
	f.glow:Hide()
	f.time:SetText("")
	if stale then f.count:SetTextColor(1, 0.82, 0) else f.count:SetTextColor(1, 1, 1) end
	if stale then f.count:SetText("?")
	elseif hidden then pcall(f.count.SetText, f.count, n)
	elseif type(n) == "number" and n > 0 then f.count:SetText(tostring(n))
	else f.count:SetText("") end
	f.tipLine = stale and "Charges can't be read during a fight."
		or ((not hidden and type(n) == "number" and n > 0) and (n == 1 and "1 charge left" or (n .. " charges left")) or nil)
	f:Show()
end

ns.updateAux = guard("indicators", function() paintWeapon(); paintShield() end)

local function buildAux()
	aux = CreateFrame("Frame", "ShamanKitIndicators", bar)
	aux:SetSize(1, 1)
	aux:SetClampedToScreen(true)
	aux:SetMovable(true)
	ind.shield = newIndicator("shield")
	ind.weapon = newIndicator("weapon")
end

-- ---------------------------------------------------------------- public API for the options panel

function ns.apply()
	if not bar then return end
	if previewing then showPreview() else refreshAll() end
	applyBarMouse()
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
	applyBarMouse()
	applyAux()
	ns.updateAux()
	local want = ns.optionsOpen and not anyRealTotem()   -- samples: only a live preview while the panel is open
	if want and not previewing then showPreview()
	elseif not want and previewing then endPreview()
	else ns.apply() end
	updateShown()
end

-- where the two small icons sit: back to the usual spot (under the bar, or the middle-low screen place)
function ns.resetAuxPlace()
	local d = ns.defaults
	db.auxSide, db.auxAlign, db.auxOffX, db.auxOffY = d.auxSide, d.auxAlign, d.auxOffX, d.auxOffY
	db.auxPoint, db.auxRelPoint, db.auxX, db.auxY = d.auxPoint, d.auxRelPoint, d.auxX, d.auxY
	if applyAux then applyAux() end
end

function ns.resetPosition()
	local d = ns.defaults
	db.point, db.relPoint, db.x, db.y = d.point, d.relPoint, d.x, d.y
	db.attachX, db.attachY = d.attachX, d.attachY
	applyAttach()
	ns.resetAuxPlace()
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
	bar = CreateFrame("Frame", "ShamanKitBar", UIParent)
	bar:SetClampedToScreen(true)
	bar:SetMovable(true)
	bar:RegisterForDrag("LeftButton")
	bar:SetScript("OnDragStart", startBarMove)
	bar:SetScript("OnDragStop", function(self)
		stopBarMove()
	end)
	bar:SetPoint(db.point, UIParent, db.relPoint, db.x, db.y)
	for slot = 1, MAX_SLOTS do
		buttons[slot] = newButton(slot)
		hits[slot] = newHit(slot, buttons[slot])
		holds[slot] = newHolder(slot)
	end
	applyAttach()
	buildAux()
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
				rememberSafe(slot, nil, cast)
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

-- the icons that watch the weapon and the shield also listen for the game's own signals; every name is
-- registered on its own inside pcall, because one name this client doesn't know would otherwise throw
local function registerAuxEvents(self)
	pcall(self.RegisterUnitEvent, self, "UNIT_AURA", "player")
	pcall(self.RegisterUnitEvent, self, "UNIT_INVENTORY_CHANGED", "player")
	pcall(self.RegisterEvent, self, "PLAYER_EQUIPMENT_CHANGED")
end

local reportedUnlocked, reportedBlocked = false, false
local ev = CreateFrame("Frame")
do
	local acc, acc2 = 0, 0
	ev:SetScript("OnUpdate", function(_, elapsed)
		acc = acc + elapsed
		if acc >= 0.5 then acc = 0; guardedRescan() end
		-- the weapon has no signal for "the enchant ran out", so it is looked at once a second (shield: only a safety net)
		acc2 = acc2 + elapsed
		if acc2 >= 1 then acc2 = 0; ns.updateAux() end
	end)
end
ev:RegisterEvent("ADDON_LOADED")
ev:SetScript("OnEvent", guard("event", function(self, event, arg1, ...)
	if event == "ADDON_LOADED" and arg1 == ADDON then
		ShamanKitDB = ShamanKitDB or {}
		db = ShamanKitDB
		ns.migrate(db)
		for k, v in pairs(ns.defaults) do if db[k] == nil then db[k] = v end end
		fixOrder()
		fixReserve()
		fixHold()
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
		self:RegisterEvent("ADDON_ACTION_BLOCKED")
		self:RegisterEvent("ADDON_ACTION_FORBIDDEN")
		registerAuxEvents(self)
		if ns.buildOptions then ns.buildOptions() end
	elseif event == "PLAYER_ENTERING_WORLD" then
		for slot in pairs(state) do state[slot] = nil end   -- loading screen: positions mean nothing now
		ns.updatePreview()
		refreshAll()
		if db.locked == false and not reportedUnlocked then
			reportedUnlocked = true
			print("|cff33ff99ShamanKit|r: the frame is unlocked (drag the box to move it). /shamankit lock to lock it.")
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
	elseif event == "ADDON_ACTION_BLOCKED" or event == "ADDON_ACTION_FORBIDDEN" then
		if arg1 == ADDON then
			local what = ...
			dbg("%s: %s | combat=%s | %s", event, tostring(what), tostring(InCombatLockdown()),
				(debugstack and tostring(debugstack(2, 6, 0)) or "-"):gsub("\n", " < "))
			if not reportedBlocked then
				reportedBlocked = true
				print("|cff33ff99ShamanKit|r: the game blocked an action (" .. tostring(what) .. "); details are in the addon's log.")
			end
		end
	elseif event == "PLAYER_REGEN_ENABLED" and self.deferredBuild then
		self.deferredBuild = nil
		build()
		self:RegisterEvent("PLAYER_ENTERING_WORLD")
		self:RegisterEvent("PLAYER_TOTEM_UPDATE")
		self:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
		self:RegisterEvent("PLAYER_REGEN_DISABLED")
		self:RegisterEvent("ADDON_ACTION_BLOCKED")
		self:RegisterEvent("ADDON_ACTION_FORBIDDEN")
		registerAuxEvents(self)
		if ns.buildOptions then ns.buildOptions() end
		refreshAll()
		ns.updateAux()
	elseif event == "UNIT_AURA" then
		if db.shieldOn then paintShield() end        -- (its own cache: nothing is drawn unless the picture changes)
	elseif event == "UNIT_INVENTORY_CHANGED" or event == "PLAYER_EQUIPMENT_CHANGED" then
		if db.weaponOn then paintWeapon() end
	elseif event == "PLAYER_REGEN_DISABLED" or event == "PLAYER_REGEN_ENABLED" then
		-- what can still be read across the combat boundary (for the log)
		local aura = hasAura("Strength of Earth")
		dbg("%s: %s | aura readable=%s", event == "PLAYER_REGEN_DISABLED" and "COMBAT START" or "COMBAT END",
			describe(playerPos()), tostring(aura ~= nil))
		for slot in pairs(state) do state[slot].last = nil end
		S.loggedHidden = false
		ns.updateAux()                          -- the buff icons notice the fight edge at once (a fight hides auras, the end shows them again)
		if event == "PLAYER_REGEN_ENABLED" then
			if attachPending then applyAttach() end
			if mousePending then applyBarMouse() end
			if auxPending then applyAux() end
			if barMoving then stopBarMove() end
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

SLASH_SHAMANKIT1 = "/shamankit"
SLASH_SHAMANKIT2 = "/totemrange"   -- the name this addon had before ShamanKit
SLASH_SHAMANKIT3 = "/trange"
SlashCmdList.SHAMANKIT = function(msg)
	msg = (msg or ""):lower():match("^%s*(%S*)")
	if msg == "unlock" or msg == "lock" then
		db.locked = msg == "lock"
		ns.updatePreview()
		print("|cff33ff99ShamanKit|r: frame " .. (db.locked and "locked" or "unlocked - open /shamankit to see and drag it"))
	elseif msg == "reset" then
		ns.resetPosition()
	elseif msg == "status" then
		local any = false
		for slot = 1, MAX_SLOTS do
			local s = state[slot]
			if s then
				any = true
				local r, how = rangeOf(slot)
				print(("|cff33ff99ShamanKit|r slot %d: %s, radius %d, %s via %s"):format(slot, s.name or "?", s.range,
					r == true and "in range" or r == false and "OUT of range" or "unknown", how))
			end
		end
		if not any then print("|cff33ff99ShamanKit|r: no active totems") end
		local st, left, _, list = readWeapon()
		print(("|cff33ff99ShamanKit|r weapon: %s%s (%s)  enchants: %s"):format(st, left and (", %ds left"):format(math.floor(left)) or "", db.weaponOn and "icon on" or "icon off", rawList(list)))
		local up, n = readShield()
		print(("|cff33ff99ShamanKit|r %s: %s%s (%s)"):format(shieldAuraName(), tostring(up),
			(up == true and not isSecret(n)) and (", charges " .. tostring(n)) or "", db.shieldOn and "icon on" or "icon off"))
	elseif ns.openOptions then
		ns.openOptions(msg)   -- "bar", "totems" or "buffs" open that page
	end
end
