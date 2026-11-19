-- ShamanKit Cures: your cure spells light up, in the colour of the affliction, while something they can remove is on you.
--
--   Cure Disease -> tan     Cure Poison -> green     Shatter Curse (the Orc racial) -> purple (a "Bane" counts as a curse)
--
-- Where it lights: the action bar buttons that hold the spell, and (optionally) a small icon row of its own.
--
-- HOW IT KNOWS (the part that matters): in a fight the game refuses every aura read from addon code, so a debuff can't be
-- looked up then. What the game does offer is its AuraContainer widget: you give it a "slot" for one kind of aura and the
-- GAME shows that slot's frame while a matching aura is on the unit, in combat too, without the addon ever reading it.
-- Each lit overlay here is such a slot, limited by dispel type (candidateFilters.includeDispelTypes), so "a poison is on you"
-- is decided by the game. The addon does everything else out of combat (which cures you know, which buttons hold them,
-- where things sit, how they look) because the game won't let it touch those frames in a fight, and it never does.
--
-- Out of combat a second, plain reading of your debuffs runs as well: it writes the dispel types the game reports into the
-- log (so a wrong type name is visible), feeds the settings preview, and lights plain frames if the client can't make a
-- container at all. In a fight that reading is not used.

local ADDON, ns = ...
local dbg, guard, isSecret = ns.dbg, ns.guard, ns.isSecret
local db

local MAXB = 8                                    -- action bar overlays per cure
local WHITE = "Interface\\Buttons\\WHITE8x8"
local GLOW = "Interface\\Buttons\\UI-ActionButton-Border"
local BEVEL = "Interface\\Buttons\\UI-Quickslot2"
local QUESTION = "Interface\\Icons\\INV_Misc_QuestionMark"
local TEST_SECONDS = 10

-- ---------------------------------------------------------------- settings

local D = ns.defaults
D.cureOn = true             -- the whole Cures module
D.cureBars = true           -- light the action bar buttons that hold a cure
D.cureRow = true            -- the small icon row
D.cureAlways = false        -- keep the row on screen, dim, while nothing is on you
D.cureSize = 29
D.cureSpacing = 4
D.cureWash = true           -- a wash of the affliction's colour over the icon
D.cureWashAlpha = 65        -- percent
D.curePulse = true
D.cureCount = true          -- a number on the row icon when the debuff has several stacks
D.cureClick = true          -- click a lit row icon to cast that cure on yourself
D.curePoint, D.cureRelPoint, D.cureX, D.cureY = "BOTTOM", "BOTTOM", -482, 337

local function clamp(v, lo, hi, def)
	if type(v) ~= "number" or v ~= v then return def end
	if v < lo then return lo elseif v > hi then return hi end
	return v
end

-- ---------------------------------------------------------------- the cures

-- types = the names the game puts in a debuff's dispelName (Forever calls some curses "Bane", so both count).
local CURES = {
	{ key = "disease", label = "Disease", spell = 2870,    types = { "Disease" },        name = "Cure Disease",  fallback = { 0.80, 0.60, 0.30 } },
	{ key = "poison",  label = "Poison",  spell = 526,     types = { "Poison" },         name = "Cure Poison",   fallback = { 0.20, 0.80, 0.20 } },
	{ key = "curse",   label = "Curse",   spell = 1299026, types = { "Curse", "Bane" },  name = "Shatter Curse", fallback = { 0.62, 0.32, 0.92 }, race = "Orc" },
}
local BYKEY = {}
for i, c in ipairs(CURES) do c.index = i; BYKEY[c.key] = c end
ns.CURES = CURES

local S = {
	known = {},             -- key -> true / false (nil = not worked out yet)
	mapped = {},            -- action button -> cure key
	mappedSig = "",
	assigned = {},          -- action button -> overlay slot record
	pools = {},             -- key -> { slot records }
	rowSlots = {},          -- key -> slot record for the row
	cells = {},             -- key -> the row's plain cell
	plainRow = {},          -- key -> plain lit frame over a cell
	plainBar = {},          -- action button -> plain lit frame
	reader = { types = nil, lit = {}, count = {} },
	failed = false,
	pending = false,
	scheduled = false,
}
ns.cureState = S                                   -- (read by the tests)

local function short(m) m = tostring(m):gsub("%s+", " "); return m:sub(1, 80) end

-- Moving the row: the frames are unlocked AND a ShamanKit settings page is open. An unlocked bar alone does not put the row
-- on screen (it would sit there all the time), and while it is being moved nothing is clickable.
local function movingRow()
	return (db.locked == false or ns.moveMode == true) and ns.optionsOpen == true
end

-- the frames and the container may only be touched out of combat, and never while the game hides auras
local function canTouch()
	return not InCombatLockdown() and not (ns.aurasHidden and ns.aurasHidden())
end

-- ---------------------------------------------------------------- spells

local function spellInfo(id)
	if not (C_Spell and C_Spell.GetSpellInfo) then return nil end
	local ok, info = pcall(C_Spell.GetSpellInfo, id)
	if ok and type(info) == "table" and not isSecret(info) then return info end
end

local function spellName(id)
	local info = spellInfo(id)
	local n = info and info.name
	if type(n) == "string" and n ~= "" and not isSecret(n) then return n end
end

local texCache = {}
local function spellTexture(id)
	local t = texCache[id]
	if t then return t end
	if C_Spell and C_Spell.GetSpellTexture then
		local ok, v = pcall(C_Spell.GetSpellTexture, id)
		if ok and v ~= nil and not isSecret(v) and (type(v) == "number" or type(v) == "string") then t = v end
	end
	if not t then
		local info = spellInfo(id)
		local i = info and info.iconID
		if i ~= nil and not isSecret(i) and (type(i) == "number" or type(i) == "string") then t = i end
	end
	if t then texCache[id] = t end
	return t
end

-- true / false, or nil when this client can't say. Every check must agree before "false" (a client that answers
-- false for a spell it does show would hide the cure for no reason).
local function knows(id)
	local known
	local function ask(fn)
		local ok, v = pcall(fn)
		if not ok or isSecret(v) then return end
		if v == true then known = true
		elseif v == false and known == nil then known = false end
	end
	if C_SpellBook and C_SpellBook.IsSpellKnown then ask(function() return C_SpellBook.IsSpellKnown(id) end) end
	if known ~= true and C_SpellBook and C_SpellBook.IsSpellInSpellBook then
		local bank = Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player
		ask(function()
			if bank then return C_SpellBook.IsSpellInSpellBook(id, bank, false) end
			return C_SpellBook.IsSpellInSpellBook(id)
		end)
	end
	if known ~= true and IsPlayerSpell then ask(function() return IsPlayerSpell(id) end) end
	return known
end

local function raceFile()
	if not UnitRace then return nil end
	local ok, _, file = pcall(UnitRace, "player")
	if ok and type(file) == "string" and not isSecret(file) then return file end
end

-- which cures this character has, with the localised name and the picture of each
local function resolveKnown()
	for _, c in ipairs(CURES) do
		local known = knows(c.spell)
		if known == nil and c.race then
			local race = raceFile()
			if race then known = (race == c.race) end            -- a racial belongs to its race
		end
		if known == nil then known = spellInfo(c.spell) ~= nil end   -- can't tell: show it if the game has it
		c.localName = spellName(c.spell) or c.name
		c.texture = spellTexture(c.spell) or QUESTION
		S.known[c.key] = known and true or false
	end
end

-- the game's own colour for that affliction (the one every unit frame uses), else ours
local function colorOf(c)
	local t = type(DebuffTypeColor) == "table" and DebuffTypeColor[c.types[1]] or nil
	if type(t) == "table" then
		local r, g, b = t.r or t[1], t.g or t[2], t.b or t[3]
		if type(r) == "number" and type(g) == "number" and type(b) == "number" and not isSecret(r) then return r, g, b end
	end
	return c.fallback[1], c.fallback[2], c.fallback[3]
end

-- ---------------------------------------------------------------- how a lit cure looks

-- Everything a lit overlay is made of. Made once per frame (the game restricts a slot's frame when auras are hidden, so
-- this runs before that, out of combat) and re-styled later, out of combat only. kind: "row" (the icon, a bevel, the stack
-- count and the cooldown sweep as well) or "bar" (only the wash and the glow, over a real action button).
local function buildParts(f, kind, cure)
	local p = { kind = kind, cure = cure }
	if kind == "row" then
		p.icon = f:CreateTexture(nil, "BACKGROUND")
		p.icon:SetAllPoints()
		p.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
	end
	p.wash = f:CreateTexture(nil, "ARTWORK")
	p.wash:SetAllPoints()
	p.wash:SetTexture(WHITE)
	if kind == "row" then
		p.cd = CreateFrame("Cooldown", nil, f, "CooldownFrameTemplate")
		p.cd:SetAllPoints()
		p.cd:SetDrawEdge(false)
	end
	local over = CreateFrame("Frame", nil, f)
	over:SetAllPoints()
	over:SetFrameLevel((f:GetFrameLevel() or 1) + 3)
	p.over = over
	if kind == "row" then
		p.bevel = over:CreateTexture(nil, "OVERLAY")
		p.bevel:SetTexture(BEVEL)
		p.bevel:SetPoint("CENTER", 0, -1)
		p.count = over:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
		p.count:SetPoint("BOTTOMRIGHT", -1, 2)
	end
	p.glow = over:CreateTexture(nil, "OVERLAY", nil, 2)
	p.glow:SetTexture(GLOW)
	p.glow:SetBlendMode("ADD")
	p.glow:SetPoint("CENTER")
	local ok, ag = pcall(function()
		local g = p.glow:CreateAnimationGroup()
		g:SetLooping("BOUNCE")
		local a = g:CreateAnimation("Alpha")
		a:SetFromAlpha(1); a:SetToAlpha(0.35); a:SetDuration(0.7)
		return g
	end)
	if ok and ag then p.pulse = ag end
	return p
end

-- (re)apply the look. The cooldown dimming is separate (it follows the spell), see paintCooldown.
local function styleParts(p, w)
	local c = p.cure
	local r, g, b = colorOf(c)
	w = clamp(w, 12, 200, 36)
	p.glow:SetSize(w * 62 / 36, w * 62 / 36)
	p.glow:SetVertexColor(r, g, b)
	if db.cureWash then
		p.wash:SetVertexColor(r, g, b)
		p.wash:SetAlpha(clamp(db.cureWashAlpha, 0, 100, 30) / 100)
		p.wash:Show()
	else
		p.wash:Hide()
	end
	if p.bevel then p.bevel:SetSize(w * 66 / 36, w * 66 / 36) end
	if p.icon then p.icon:SetTexture(c.texture or QUESTION) end
	if p.pulse then
		if db.curePulse then p.pulse:Play() else p.pulse:Stop(); p.glow:SetAlpha(1) end
	end
	p.w = w
end

-- the row icon is dimmed, and sweeps, while the cure is on cooldown (the global cooldown does not count)
local function cooldownOf(id)
	if not (C_Spell and C_Spell.GetSpellCooldown) then return nil end
	local ok, info = pcall(C_Spell.GetSpellCooldown, id)
	if not ok or type(info) ~= "table" or isSecret(info) then return nil end
	local start, dur = info.startTime, info.duration
	if isSecret(start) or isSecret(dur) or type(start) ~= "number" or type(dur) ~= "number" then return nil end
	if dur <= 1.5 or info.isOnGCD == true then return nil end
	return start, dur
end

local function paintCooldown(p)
	if not (p and p.cd) then return end
	local start, dur = cooldownOf(p.cure.spell)
	local sig = start and (start .. "|" .. dur) or "-"
	if p.cdSig == sig then return end
	p.cdSig = sig
	if start then p.cd:SetCooldown(start, dur) else p.cd:SetCooldown(0, 0) end
	if p.icon then p.icon:SetAlpha(start and 0.55 or 1) end
end

-- ---------------------------------------------------------------- the game-drawn slots

local NOTHING = {}                                  -- a dispel type list with nothing in it: the slot shows nothing

local function typeSet(c)
	local t = {}
	for _, n in ipairs(c.types) do t[n] = true end
	return t
end

local function makeContainer()
	if S.container or S.failed then return S.container end
	local ok, err = pcall(function()
		if C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.LoadAddOn and not C_AddOns.IsAddOnLoaded("Blizzard_AuraContainer") then
			C_AddOns.LoadAddOn("Blizzard_AuraContainer")
		end
		local c = CreateFrame("AuraContainer", nil, UIParent, "CustomAuraContainerTemplate")
		if not c.AddAuraSlot then error("this client has no aura slots") end
		c:SetUnit("player")
		c:SetSize(1, 1)
		c:SetPoint("CENTER", UIParent, "CENTER", 0, 0)   -- one point: a container holding only slots is zero-sized
		S.container = c
	end)
	if not ok then
		S.failed, S.container = true, nil
		dbg("CURES container could not be made: %s (plain frames, lit from the out-of-combat reading, are used instead)", short(err))
		return nil
	end
	dbg("CURES container made")
	return S.container
end

-- ---------------------------------------------------------------- click to cure

-- A secure button as a CHILD of the game's slot frame. The game shows and hides that frame when a matching debuff comes
-- and goes, in a fight too, and a child is only on screen (and only takes the mouse) while its parent is: so the button
-- is there to click exactly when the icon is, with nothing for the addon to show or hide in combat. It is made here, when
-- the slot is made (out of combat), and its spell is set out of combat only (armClick). The game does the casting.
local function tipOf(self)
	local name = self.spellName
	if not name then return end
	GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
	GameTooltip:SetText(name)
	GameTooltip:AddLine("Click to cast it on yourself.", 1, 1, 1)
	GameTooltip:Show()
end

local function makeClick(button, cure)
	local ok, b = pcall(CreateFrame, "Button", nil, button, "SecureActionButtonTemplate")
	if not ok or not b then
		dbg("CURES click: no secure button for %s (%s)", cure.key, short(b))
		return nil
	end
	local okAll, err = pcall(function()
		b:SetAllPoints(button)
		b:SetFrameLevel((button:GetFrameLevel() or 1) + 12)
		b:RegisterForClicks("LeftButtonUp")
		b:EnableMouse(false)                           -- off until armed
		b:SetScript("OnEnter", guard("cure click tooltip", tipOf))
		b:SetScript("OnLeave", GameTooltip_Hide)
		local hl = b:CreateTexture(nil, "HIGHLIGHT")
		hl:SetAllPoints()
		hl:SetTexture(WHITE)
		hl:SetVertexColor(1, 1, 1, 0.18)
	end)
	if not okAll then dbg("CURES click: the button for %s could not be set up (%s)", cure.key, short(err)) end
	return b
end

-- out of combat only: the spell (cast on you), and the mouse
local function armClick(rec)
	local b = rec.click
	if not b then return end
	local want = db.cureClick and not movingRow() and db.cureOn and not S.conflict and S.known[rec.cure.key] == true
	local name = want and (rec.cure.localName or rec.cure.name) or false
	if rec.armed == name then return end
	rec.armed = name
	pcall(function()
		if name then
			b:SetAttribute("type1", "spell")
			b:SetAttribute("spell1", name)
			b:SetAttribute("unit1", "player")
		else
			b:SetAttribute("type1", nil)
			b:SetAttribute("spell1", nil)
			b:SetAttribute("unit1", nil)
		end
		b.spellName = name or nil
		b:EnableMouse(name and true or false)
	end)
	dbg("CURES click: %s %s", rec.cure.key, name and ("cast " .. name .. " on you") or "off")
end

local PARK = -9000
-- one slot = one frame the game shows while a matching debuff is on you. Unassigned: empty type list + parked off screen.
local function newSlot(cure, kind, index)
	local c = S.container
	local rec = { cure = cure, kind = kind, name = ("ShamanKitCure_%s_%s%d"):format(cure.key, kind, index) }
	local ok, frame = pcall(c.AddAuraSlot, c, rec.name, "HARMFUL", {
		candidateFilters = { includeDispelTypes = NOTHING },
		initializeFrame = function(button)               -- runs now, before the game restricts the button
			rec.button = button
			button:SetSize(clamp(db.cureSize, 16, 80, 36), clamp(db.cureSize, 16, 80, 36))   -- pooled buttons have no size of their own
			pcall(button.EnableMouse, button, false)
			rec.parts = buildParts(button, kind, cure)
			styleParts(rec.parts, clamp(db.cureSize, 16, 80, 36))
			if kind == "row" then rec.click = makeClick(button, cure) end
			if kind == "row" and db.cureCount then
				rec.countOn = pcall(button.SetApplicationCount, button, rec.parts.count, {})   -- the game writes the stack count
			end
		end,
	})
	if not ok then
		dbg("CURES slot %s could not be made: %s", rec.name, short(frame))
		return nil
	end
	rec.frame = frame or rec.button
	if not rec.frame then return nil end
	rec.on = false
	return rec
end

local function parkSlot(rec)
	if not rec then return end
	pcall(S.container.SetAuraSlotCandidateFilters, S.container, rec.name, { includeDispelTypes = NOTHING })
	pcall(function()
		rec.frame:ClearAllPoints()
		rec.frame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", PARK, -PARK)
	end)
	rec.on, rec.anchor = false, nil
	rec.armed = nil
	if rec.click then pcall(function() rec.click:SetAttribute("type1", nil); rec.click:SetAttribute("spell1", nil); rec.click:EnableMouse(false) end); rec.armed = false end
end

local function assignSlot(rec, anchor, w)
	pcall(function()
		rec.frame:ClearAllPoints()
		rec.frame:SetPoint("CENTER", anchor, "CENTER", 0, 0)
		rec.frame:SetSize(w, w)
		if anchor.GetFrameStrata then rec.frame:SetFrameStrata(anchor:GetFrameStrata()) end
		if anchor.GetFrameLevel then rec.frame:SetFrameLevel((anchor:GetFrameLevel() or 1) + 8) end
	end)
	if rec.parts then styleParts(rec.parts, w) end
	pcall(S.container.SetAuraSlotCandidateFilters, S.container, rec.name, { includeDispelTypes = typeSet(rec.cure) })
	rec.on, rec.anchor, rec.w = true, anchor, w
end

-- ---------------------------------------------------------------- the icon row

local function savePosition()
	local row = S.row
	local p, _, rp, x, y = row:GetPoint()
	db.curePoint, db.cureRelPoint, db.cureX, db.cureY = p, rp, x, y
end

local function cellTooltip(self)
	local c = self.cure
	GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
	GameTooltip:SetText(c.localName or c.name)
	GameTooltip:AddLine(("Lights up while a %s is on you."):format(c.label:lower()), 1, 1, 1)
	if S.known[c.key] == false then GameTooltip:AddLine("You don't have this spell.", 0.8, 0.5, 0.5) end
	GameTooltip:Show()
end

local function ensureRow()
	if S.row or not canTouch() then return S.row end
	local row = CreateFrame("Frame", "ShamanKitCureRow", UIParent)
	row:SetSize(1, 1)
	row:SetMovable(true)
	row:SetClampedToScreen(true)
	row:SetPoint(db.curePoint or "CENTER", UIParent, db.cureRelPoint or "CENTER", db.cureX or 0, db.cureY or -160)
	S.row = row
	local moving = false
	for _, c in ipairs(CURES) do
		local cell = CreateFrame("Frame", nil, row)
		cell.cure = c
		cell.icon = cell:CreateTexture(nil, "BACKGROUND")
		cell.icon:SetAllPoints()
		cell.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
		cell.icon:SetDesaturated(true)
		cell.icon:SetAlpha(0.5)
		cell.bevel = cell:CreateTexture(nil, "OVERLAY")
		cell.bevel:SetTexture(BEVEL)
		cell.bevel:SetPoint("CENTER", 0, -1)
		cell.bevel:SetAlpha(0.7)
		cell:SetScript("OnEnter", guard("cure tooltip", cellTooltip))
		cell:SetScript("OnLeave", GameTooltip_Hide)
		cell:RegisterForDrag("LeftButton")
		cell:SetScript("OnDragStart", function()
			if db.locked == false and canTouch() then row:StartMoving(); moving = true end
		end)
		cell:SetScript("OnDragStop", function()
			if not moving then return end
			moving = false
			row:StopMovingOrSizing()
			savePosition()
		end)
		cell:EnableMouse(false)
		cell:Hide()
		S.cells[c.key] = cell
	end
	return row
end

-- ---------------------------------------------------------------- reading the debuffs (out of combat only)

-- { [dispel type name] = how many }, or nil when it can't be read (a fight, a hidden value): never "nothing"
local function readTypes()
	if not canTouch() then return nil end
	local A = C_UnitAuras
	if not (A and A.GetAuraDataByIndex) then return nil end
	local seen = {}
	for i = 1, 60 do
		local ok, a = pcall(A.GetAuraDataByIndex, "player", i, "HARMFUL")
		if not ok or isSecret(a) then return nil end
		if a == nil then break end
		if type(a) == "table" then
			local d = a.dispelName
			if isSecret(d) then return nil end
			if type(d) == "string" and d ~= "" then seen[d] = (seen[d] or 0) + 1 end
		end
	end
	return seen
end

local function typesLine(seen)
	local names = {}
	for k, n in pairs(seen) do names[#names + 1] = k .. "=" .. n end
	table.sort(names)
	return #names > 0 and table.concat(names, " ") or "none"
end

-- true when the reading changed what is lit
local function updateReader()
	local seen = readTypes()
	if not seen then return false end
	local line = typesLine(seen)
	if line ~= S.reader.line then
		S.reader.line = line
		dbg("CURES debuff types on you: %s", line)   -- the names the game really uses: a wrong type name in CURES shows here
	end
	local changed = false
	for _, c in ipairs(CURES) do
		local n = 0
		for _, t in ipairs(c.types) do n = n + (seen[t] or 0) end
		local lit = n > 0
		if S.reader.lit[c.key] ~= lit or S.reader.count[c.key] ~= n then changed = true end
		S.reader.lit[c.key], S.reader.count[c.key] = lit, n
	end
	S.reader.types = seen
	return changed
end

local function anyRealLit()
	for _, c in ipairs(CURES) do if S.reader.lit[c.key] then return true end end
	return false
end

-- ---------------------------------------------------------------- the action bars

local PREFIXES = { "ActionButton", "MultiBarBottomLeftButton", "MultiBarBottomRightButton", "MultiBarLeftButton",
	"MultiBarRightButton", "MultiBar5Button", "MultiBar6Button", "MultiBar7Button" }
local PER_BAR = 12

local function cureOfId(id)
	if type(id) == "number" then
		for _, c in ipairs(CURES) do if c.spell == id then return c.key end end
		local n = spellName(id)
		if n then for _, c in ipairs(CURES) do if (c.localName or c.name) == n then return c.key end end end
	elseif type(id) == "string" then
		for _, c in ipairs(CURES) do if (c.localName or c.name) == id then return c.key end end
	end
end

-- which cure that button casts (a macro counts when the spell it casts is one), or nil
local function cureOfButton(b)
	local a = b.action
	if type(a) ~= "number" and b.GetAttribute then
		local ok, v = pcall(b.GetAttribute, b, "action")
		if ok then a = v end
	end
	if type(a) ~= "number" or isSecret(a) then return nil end
	local ok, kind, id = pcall(GetActionInfo, a)
	if not ok or isSecret(kind) or isSecret(id) then return nil end
	if kind == "spell" then return cureOfId(id) end
	if kind == "macro" and id ~= nil and GetMacroSpell then
		local mok, spell = pcall(GetMacroSpell, id)
		if mok and not isSecret(spell) then return cureOfId(spell) end
	end
end

-- the map button -> cure, and a signature that changes when it does
local function scanBars()
	local map, sig = {}, {}
	for _, prefix in ipairs(PREFIXES) do
		for i = 1, PER_BAR do
			local name = prefix .. i
			local b = _G[name]
			if b then
				local key = cureOfButton(b)
				if key then map[b] = key; sig[#sig + 1] = name .. ">" .. key end
			end
		end
	end
	return map, table.concat(sig, ",")
end

-- ---------------------------------------------------------------- putting it all in place (out of combat)

local function forcedKey(key)
	return S.testKey == "all" or S.testKey == key
end

local function sampling()
	return ns.curesPageOpen == true and not anyRealLit()
end

-- is this cure drawn lit by a PLAIN frame (a test, the settings preview, or the fallback reading)?
local function litPlain(key)
	if forcedKey(key) or sampling() then return true end
	return S.failed and S.reader.lit[key] == true
end

local function newPlainLit(parent, kind, cure)
	local f = CreateFrame("Frame", nil, parent)
	f.parts = buildParts(f, kind, cure)
	f:Hide()
	return f
end

local function styleSig()
	return table.concat({ tostring(db.cureWash), clamp(db.cureWashAlpha, 0, 100, 30), tostring(db.curePulse),
		tostring(db.cureCount), clamp(db.cureSize, 16, 80, 36) }, "|")
end

local function layoutRow(keys, shown)
	local row = S.row
	local size = clamp(db.cureSize, 16, 80, 36)
	local gap = clamp(db.cureSpacing, 0, 24, 4)
	row:ClearAllPoints()
	row:SetPoint(db.curePoint or "CENTER", UIParent, db.cureRelPoint or "CENTER", clamp(db.cureX, -3000, 3000, 0), clamp(db.cureY, -3000, 3000, -160))
	for i, key in ipairs(keys) do
		local cell = S.cells[key]
		cell:ClearAllPoints()
		cell:SetSize(size, size)
		cell:SetPoint("TOPLEFT", row, "TOPLEFT", (i - 1) * (size + gap), 0)
		cell.bevel:SetSize(size * 66 / 36, size * 66 / 36)
		cell.icon:SetTexture(BYKEY[key].texture or QUESTION)
		local vis = shown[key] == true
		cell:SetShown(vis)
		cell:EnableMouse(vis)
	end
	for _, c in ipairs(CURES) do
		local inRow = false
		for _, k in ipairs(keys) do if k == c.key then inRow = true end end
		if not inRow then S.cells[c.key]:Hide(); S.cells[c.key]:EnableMouse(false) end
	end
	local n = math.max(#keys, 1)
	row:SetSize(n * size + (n - 1) * gap, size)
end

local function apply()
	if not db then return end
	if not canTouch() then S.pending = true return end
	S.pending = false
	local on = db.cureOn and not S.conflict
	if not on and not S.container and not S.row then return end       -- never started, nothing to undo
	if S.knownDirty ~= false then resolveKnown(); S.knownDirty = false end
	local row = on and ensureRow() or S.row
	if on then makeContainer() end
	local c = S.container
	if c then
		pcall(c.SetEnabled, c, on)
		if on then c:Show() else c:Hide() end
	end

	local samp = on and sampling()
	local testing = on and S.testKey ~= nil
	local wholeRow = on and db.cureRow

	-- which cures sit in the row: the ones you have; every one while a test or the settings preview is showing
	local keys, shown = {}, {}
	if wholeRow then
		for _, cure in ipairs(CURES) do
			local have = S.known[cure.key] == true
			if have or samp or testing then
				keys[#keys + 1] = cure.key
				shown[cure.key] = (have and (db.cureAlways or movingRow())) or litPlain(cure.key)
			end
		end
	end
	if row then layoutRow(keys, shown) end

	-- the style: only rewritten when something that changes it did
	local sig = styleSig()
	local restyle = S.styleSig ~= sig
	S.styleSig = sig

	-- row slots: the game shows these (a real debuff), over the cells
	for _, cure in ipairs(CURES) do
		local key = cure.key
		local rec = S.rowSlots[key]
		local inRow = false
		for _, k in ipairs(keys) do if k == key then inRow = true end end
		local want = c and wholeRow and inRow and S.known[key] == true
		if want then
			if not rec then rec = newSlot(cure, "row", 1); S.rowSlots[key] = rec end
			if rec then
				if not rec.on or rec.anchor ~= S.cells[key] or rec.w ~= clamp(db.cureSize, 16, 80, 36) then
					assignSlot(rec, S.cells[key], clamp(db.cureSize, 16, 80, 36))
				elseif restyle and rec.parts then
					styleParts(rec.parts, rec.w)
				end
				if rec.button and rec.parts then
					if db.cureCount and not rec.countOn then rec.countOn = pcall(rec.button.SetApplicationCount, rec.button, rec.parts.count, {})
					elseif not db.cureCount and rec.countOn then pcall(rec.button.ClearApplicationCount, rec.button); rec.parts.count:SetText(""); rec.countOn = false end
				end
				paintCooldown(rec.parts)
				armClick(rec)
			end
		elseif rec and rec.on then
			parkSlot(rec)
		end
	end

	-- action bar overlays: which buttons hold a cure (read with or without a container: plain frames need it too)
	if on and db.cureBars then
		local map, msig = scanBars()
		if msig ~= S.mappedSig then
			S.mappedSig = msig
			dbg("CURES action bars: %s", msig ~= "" and msig or "none of the cures")
		end
		S.mapped = map
	else
		S.mapped, S.mappedSig = {}, ""
	end
	for b, rec in pairs(S.assigned) do                              -- release what is no longer mapped
		if S.mapped[b] ~= rec.cure.key then parkSlot(rec); S.assigned[b] = nil end
	end
	for b, key in pairs(c and S.mapped or {}) do
		local rec = S.assigned[b]
		local w = clamp(b.GetWidth and b:GetWidth(), 12, 200, 36)
		if not rec then
			local pool = S.pools[key]
			if not pool then pool = {}; S.pools[key] = pool end
			for _, r in ipairs(pool) do if not r.on then rec = r break end end
			if not rec and #pool < MAXB then
				rec = newSlot(BYKEY[key], "bar", #pool + 1)
				if rec then pool[#pool + 1] = rec end
			end
			if rec then S.assigned[b] = rec; assignSlot(rec, b, w)
			else dbg("CURES: no free overlay for %s (%d is the most per cure)", key, MAXB) end
		elseif rec.w ~= w or rec.anchor ~= b then
			assignSlot(rec, b, w)
		elseif restyle and rec.parts then
			styleParts(rec.parts, rec.w)
		end
	end

	-- plain lit frames: a test, the settings preview, or (no container) the out-of-combat reading
	for _, cure in ipairs(CURES) do
		local key = cure.key
		local lit = on and litPlain(key)
		local pf = S.plainRow[key]
		local cell = S.cells[key]
		local showRow = lit and wholeRow and cell and cell:IsShown() and (S.known[key] == true or samp or testing)
		if showRow then
			if not pf then pf = newPlainLit(row, "row", cure); S.plainRow[key] = pf end
			local sz = clamp(db.cureSize, 16, 80, 36)
			pf:ClearAllPoints(); pf:SetPoint("CENTER", cell, "CENTER", 0, 0); pf:SetSize(sz, sz)
			if restyle or not pf.styled then styleParts(pf.parts, sz); pf.styled = true end
			pf.parts.count:SetText((S.reader.count[key] or 0) > 1 and db.cureCount and tostring(S.reader.count[key]) or "")
			paintCooldown(pf.parts)
			pf:Show()
		elseif pf then
			pf:Hide()
		end
	end
	for b, pf in pairs(S.plainBar) do
		local key = pf.cure.key
		if not (on and db.cureBars and S.mapped[b] == key and litPlain(key)) then pf:Hide() end
	end
	if on and db.cureBars then
		for b, key in pairs(S.mapped) do
			if litPlain(key) then
				local pf = S.plainBar[b]
				if not pf then pf = newPlainLit(UIParent, "bar", BYKEY[key]); pf.cure = BYKEY[key]; S.plainBar[b] = pf end
				local w = clamp(b.GetWidth and b:GetWidth(), 12, 200, 36)
				pf:ClearAllPoints(); pf:SetPoint("CENTER", b, "CENTER", 0, 0); pf:SetSize(w, w)
				pf:SetFrameLevel((b:GetFrameLevel() or 1) + 8)
				if restyle or not pf.styled then styleParts(pf.parts, w); pf.styled = true end
				pf:Show()
			end
		end
	end
end
ns.cureApply = guard("cures", apply)   -- settings changed, a test, the preview: one full pass

-- the cooldown dimming / sweep alone (a spell cast fires this often: nothing is laid out again)
local function paintCooldowns()
	for _, rec in pairs(S.rowSlots) do if rec.on then paintCooldown(rec.parts) end end
	for _, pf in pairs(S.plainRow) do if pf:IsShown() then paintCooldown(pf.parts) end end
end

-- ---------------------------------------------------------------- events: nothing polls

local function work()
	if InCombatLockdown() then S.pending = true return end
	local full = S.full or S.pending
	S.full = false
	if S.auraDirty then
		S.auraDirty = false
		-- a debuff only changes what is drawn here when plain frames show it (no container, a test, the preview)
		if updateReader() and (S.failed or ns.curesPageOpen or S.testKey) then full = true end
	end
	if full then
		apply()
	elseif S.cdDirty then
		paintCooldowns()
	end
	S.cdDirty = false
	if S.pending then   -- the game was hiding auras though no fight was on: look again soon
		if C_Timer and C_Timer.After then C_Timer.After(1, function() if S.pending then ns.cureSchedule(true) end end) end
	end
end
local guardedWork = guard("cures", work)

function ns.cureSchedule(full)
	if full then S.full = true end
	if S.scheduled then return end
	S.scheduled = true
	local function go() S.scheduled = false; guardedWork() end
	if C_Timer and C_Timer.After then C_Timer.After(0.05, go) else go() end
end

local EVENTS = { "PLAYER_ENTERING_WORLD", "SPELLS_CHANGED", "PLAYER_LEVEL_UP", "ACTIONBAR_SLOT_CHANGED",
	"ACTIONBAR_PAGE_CHANGED", "SPELL_UPDATE_COOLDOWN", "PLAYER_REGEN_ENABLED", "PLAYER_REGEN_DISABLED" }
ns.CURE_EVENTS = EVENTS

local cf
local function onEvent(_, event, unit)
	if event == "UNIT_AURA" then
		S.auraDirty = true                                  -- a burst becomes one reading, and none at all in a fight
		if not InCombatLockdown() then ns.cureSchedule() end
	elseif event == "SPELL_UPDATE_COOLDOWN" then
		if not InCombatLockdown() and db and db.cureOn then S.cdDirty = true; ns.cureSchedule() end
	elseif event == "PLAYER_REGEN_DISABLED" then
		-- a test or the preview is only for out of combat: put its plain frames away (hiding our own frames is fine)
		if S.testKey then S.testKey = nil end
		for _, pf in pairs(S.plainRow) do pf:Hide() end
		for _, pf in pairs(S.plainBar) do pf:Hide() end
	elseif event == "PLAYER_REGEN_ENABLED" then
		S.auraDirty = true
		ns.cureSchedule(true)
	else
		if event == "SPELLS_CHANGED" or event == "PLAYER_LEVEL_UP" or event == "PLAYER_ENTERING_WORLD" then S.knownDirty = true end
		if event == "PLAYER_ENTERING_WORLD" then S.auraDirty = true end
		ns.cureSchedule(true)
	end
end

-- CureWatch (the separate addon this replaces) still installed: two sets of highlights on every button. Stay off then.
local function conflict()
	return (C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded("CureWatch")) and true or false
end

function ns.cureInit()
	db = ns.get()
	S.conflict = conflict()
	if S.conflict then
		print("|cff33ff99ShamanKit|r: the separate CureWatch addon is still installed, so ShamanKit's Cures stay off (both would light every button). Remove CureWatch (wowupd remove CureWatch, or its folder) and /reload.")
		dbg("CURES: CureWatch is loaded, so the Cures module stays off")
	end
	if cf then return end
	cf = CreateFrame("Frame")
	cf:SetScript("OnEvent", guard("cures event", onEvent))
	for _, e in ipairs(EVENTS) do
		local ok, err = pcall(cf.RegisterEvent, cf, e)           -- one at a time: a name this client doesn't know throws
		if not ok then dbg("CURES: event %s is not known here (%s)", e, short(err)) end
	end
	pcall(cf.RegisterUnitEvent, cf, "UNIT_AURA", "player")
	-- a drag from one slot to another does not always announce itself: look at the bars again after one
	if hooksecurefunc then
		for _, fn in ipairs({ "PlaceAction", "PickupAction" }) do
			if _G[fn] then pcall(hooksecurefunc, fn, function() if not InCombatLockdown() then ns.cureSchedule(true) end end) end
		end
	end
	-- and a slow backstop, out of combat: only reads the buttons, only acts when the answer changed
	if C_Timer and C_Timer.NewTicker then
		C_Timer.NewTicker(2, function()
			if InCombatLockdown() or not (db and db.cureOn and db.cureBars) or S.conflict then return end
			local _, sig = scanBars()
			if sig ~= S.mappedSig then ns.cureSchedule(true) end
		end)
	end
	S.knownDirty = true
	ns.cureSchedule(true)
end

-- ---------------------------------------------------------------- tests, the row's place, status, slash

function ns.cureTest(key)
	if InCombatLockdown() then print("|cff33ff99ShamanKit|r: the test is for out of combat.") return end
	if key == "clear" or key == "off" or key == nil or key == "" then
		S.testKey = nil
	elseif key == "all" or BYKEY[key] then
		S.testKey = key
		local token = {}
		S.testToken = token
		if C_Timer and C_Timer.After then
			C_Timer.After(TEST_SECONDS, function() if S.testToken == token and S.testKey then S.testKey = nil; ns.cureApply() end end)
		end
	else
		print("|cff33ff99ShamanKit|r: cures test all | poison | disease | curse | clear")
		return
	end
	ns.cureApply()
end

function ns.cureResetPosition()
	if not db then return end
	local d = ns.defaults
	db.curePoint, db.cureRelPoint, db.cureX, db.cureY = d.curePoint, d.cureRelPoint, d.cureX, d.cureY
	ns.cureApply()
end

-- a few lines for the settings page and /shamankit cures status
function ns.cureInfo()
	local out = {}
	for _, c in ipairs(CURES) do
		local n = 0
		for _, k in pairs(S.mapped) do if k == c.key then n = n + 1 end end
		out[#out + 1] = ("%s: %s, %d action bar button%s"):format(c.localName or c.name,
			S.known[c.key] == true and "you have it" or (S.known[c.key] == false and "you don't have it" or "not looked at yet"), n, n == 1 and "" or "s")
	end
	return out
end

local function status()
	local P = "|cff33ff99ShamanKit|r cures: "
	if not db then print(P .. "not started") return end
	print(P .. (S.conflict and "OFF: CureWatch is still installed" or (db.cureOn and "on" or "off")))
	print(P .. (S.container and "lit by the game (aura container)" or (S.failed and "no container on this client: lit from the out-of-combat reading" or "container not made yet")))
	for _, line in ipairs(ns.cureInfo()) do print(P .. line) end
	print(P .. "debuff types on you (out of combat reading): " .. (S.reader.line or "not read yet"))
end

function ns.cureSlash(rest)
	rest = (rest or ""):lower()
	local a, b = rest:match("^(%S*)%s*(%S*)")
	if a == "" then
		if ns.openOptions then ns.openOptions("cures") end
	elseif a == "test" then
		ns.cureTest(b ~= "" and b or "all")
	elseif a == "status" then
		status()
	elseif a == "on" or a == "off" then
		db.cureOn = (a == "on")
		ns.updatePreview()
		print("|cff33ff99ShamanKit|r: cures " .. a)
	else
		print("|cff33ff99ShamanKit|r: /shamankit cures [test all|poison|disease|curse|clear] [status] [on|off]")
	end
end

-- the old addon's commands, when it is not around to answer them
if not conflict() then
	SLASH_SHAMANKITCURE1 = "/curewatch"
	SLASH_SHAMANKITCURE2 = "/cw"
	SlashCmdList.SHAMANKITCURE = function(msg) ns.cureSlash(msg) end
end

-- Move mode (Move.lua): the icon row; moving it saves the middle of the row
ns.moveProviders[#ns.moveProviders + 1] = function()
	if not (db and S.row) then return {} end
	return { { id = "cures", label = "Cure row", frame = S.row, on = function() return db.cureOn and db.cureRow and true or false end,
		drop = function(cx, cy)
			db.curePoint, db.cureRelPoint, db.cureX, db.cureY = "CENTER", "CENTER", cx, cy
			ns.cureApply()
		end } }
end
