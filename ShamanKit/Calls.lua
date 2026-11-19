-- ShamanKit Calls: the totem spells that belong with the bar, as buttons next to it.
--
--   [Call of the ...]  one button for Call of the Elements / Ancestors / Spirits, with a small arrow that opens a pick
--                      list of the others (the way the default totem bar does it)
--   [Totemic Call]     brings your totems to you
--   [Totemic Recall]   takes them back for mana
--
-- Each button is optional (settings page "Call spells") and only shows when you know the spell. They sit on a side of
-- the totem bar (or in a place of their own, draggable), as big as you like, and show all the time or only while a
-- totem is out.
--
-- Rules this file keeps (the bar next to it is restricted in combat, and so are these buttons):
--   * the buttons are the game's own secure spell buttons: a click is one cast, decided by you;
--   * they are made, placed, shown, hidden and given their spell OUT of combat only; in a fight nothing of that is
--     touched, so choosing another Call spell waits until the fight is over;
--   * what does run in a fight is only the cooldown sweep (a child Cooldown frame, values passed straight through
--     because the game may hand them over as secret numbers, never compared).

local ADDON, ns = ...
local dbg, guard, isSecret = ns.dbg, ns.guard, ns.isSecret
local db

local QUESTION = "Interface\\Icons\\INV_Misc_QuestionMark"
local BEVEL = "Interface\\Buttons\\UI-Quickslot2"
local WHITE = "Interface\\Buttons\\WHITE8x8"
local ARROW = "Interface\\Buttons\\Arrow-Up-Up"
local MAX_SLOTS = 4               -- places on the bar

-- ---------------------------------------------------------------- settings

local D = ns.defaults
D.callOn = false              -- the Call of the ... button
D.callTotemic = false         -- the Totemic Call button
D.callRecall = false          -- the Totemic Recall button
D.callChoice = 0              -- which Call spell the button casts: a spell id, 0 = the first one you know
D.callShow = "always"         -- "always", or "bar": only while the totem bar is up (a totem is out)
D.callScale = 100             -- button size, % of the totem icons
D.callAnchor = "bar"          -- "bar": beside the totem bar, "free": a place of their own on the screen
D.callSide = "start"          -- of the bar: "start" (before the totems: left / above), "end" (after them), or left / right / top / bottom
D.callAlign = "start"         -- along that side: start / center / end
D.callOffX, D.callOffY = 0, 0 -- a nudge from there
D.callPoint, D.callRelPoint, D.callX, D.callY = "CENTER", "CENTER", 0, -200   -- the place of their own

-- each button can also be placed on its own, apart from the others: the same settings again, one set per button
-- (posCallOwn, posCallAnchor, posCallSide ... posTotemicOwn ... posRecallY)
local POS = { call = "posCall", totemic = "posTotemic", recall = "posRecall" }
local OWN_Y = { call = -200, totemic = -250, recall = -300 }   -- apart in their own places, so they don't pile up
ns.CALL_POS_KEYS = {}
for _, kind in ipairs({ "call", "totemic", "recall" }) do
	local k = POS[kind]
	D[k .. "Own"] = false          -- true: this button is placed by the settings below, not with the others
	D[k .. "Anchor"], D[k .. "Side"], D[k .. "Align"] = "bar", "start", "start"
	D[k .. "OffX"], D[k .. "OffY"] = 0, 0
	D[k .. "Point"], D[k .. "RelPoint"], D[k .. "X"], D[k .. "Y"] = "CENTER", "CENTER", 0, OWN_Y[kind]
	for _, f in ipairs({ "Own", "Anchor", "Side", "Align", "OffX", "OffY", "Point", "RelPoint", "X", "Y" }) do
		ns.CALL_POS_KEYS[#ns.CALL_POS_KEYS + 1] = k .. f
	end
end

-- the three Call spells (client ids; levels 20 / 30 / 40) and the two single ones
local CALLS = {
	{ id = 66842, key = "elements",  label = "Call of the Elements" },
	{ id = 66843, key = "ancestors", label = "Call of the Ancestors" },
	{ id = 66844, key = "spirits",   label = "Call of the Spirits" },
}
local TOTEMIC = { id = 437009, key = "totemic", label = "Totemic Call" }
local RECALL = { id = 36936, key = "recall", label = "Totemic Recall" }
ns.CALL_SPELLS = { CALLS = CALLS, TOTEMIC = TOTEMIC, RECALL = RECALL }

local S = {
	buttons = {},             -- kind ("call" / "totemic" / "recall") -> button
	shown = {},               -- the kinds on screen, in order
	pending = false,
	scheduled = false,
	cdDirty = false,
}
ns.callState = S                                   -- (read by the tests)

local function short(m) m = tostring(m):gsub("%s+", " "); return m:sub(1, 80) end

-- ---------------------------------------------------------------- spells

local function spellInfo(id)
	if not (C_Spell and C_Spell.GetSpellInfo) then return nil end
	local ok, info = pcall(C_Spell.GetSpellInfo, id)
	if ok and type(info) == "table" and not isSecret(info) then return info end
end

local function spellName(id, fallback)
	local info = spellInfo(id)
	local n = info and info.name
	if type(n) == "string" and n ~= "" and not isSecret(n) then return n end
	return fallback
end

local function spellTexture(id)
	if C_Spell and C_Spell.GetSpellTexture then
		local ok, v = pcall(C_Spell.GetSpellTexture, id)
		if ok and v ~= nil and not isSecret(v) and (type(v) == "number" or type(v) == "string") then return v end
	end
	local info = spellInfo(id)
	local i = info and info.iconID
	if i ~= nil and not isSecret(i) and (type(i) == "number" or type(i) == "string") then return i end
	return QUESTION
end

local function known(id) return ns.knownSpell and ns.knownSpell(id) or false end

-- the Call spells you know, in the order of their levels
local function knownCalls()
	local list = {}
	for _, c in ipairs(CALLS) do if known(c.id) then list[#list + 1] = c end end
	return list
end

-- the one the Call button casts: your choice while you know it, else the first one you know
local function chosenCall(list)
	list = list or knownCalls()
	local want = db and db.callChoice
	if type(want) == "number" then
		for _, c in ipairs(list) do if c.id == want then return c end end
	end
	return list[1]
end

-- ---------------------------------------------------------------- where it sits

local function clamp(v, lo, hi, def)
	if type(v) ~= "number" or v ~= v then return def end
	if v < lo then return lo elseif v > hi then return hi end
	return v
end

local function buttonSize() return math.max(16, math.floor(db.size * clamp(db.callScale, 50, 150, 100) / 100 + 0.5)) end

-- Where something sits is read from a set of settings named by a prefix: "call" is the group of buttons, "posCall" /
-- "posTotemic" / "posRecall" a button placed on its own.
local function ownOf(kind) return POS[kind] ~= nil and db[POS[kind] .. "Own"] == true end
local function pfxOf(kind) return ownOf(kind) and POS[kind] or "call" end

-- "bar" or "free" (a damaged value counts as the bar)
local function modeOf(pfx) return db[pfx .. "Anchor"] == "free" and "free" or "bar" end
local function mode() return modeOf("call") end
ns.callMode = mode

local OPPOSITE = { left = "right", right = "left", top = "bottom", bottom = "top" }

-- the side you asked for, as left / right / top / bottom ("start" and "end" are before / after the totems)
local function sideWanted(sd)
	if sd == "left" or sd == "right" or sd == "top" or sd == "bottom" then return sd end
	if sd == "end" then return db.vertical and "bottom" or "right" end
	return db.vertical and "top" or "left"
end

-- the buff icons are on that side of the bar: the buttons would sit on them
local function auxThere(side)
	if not (db.shieldOn or db.weaponOn) then return false end
	if ns.auxMode and ns.auxMode() ~= "bar" then return false end
	return ns.auxSide and ns.auxSide() == side
end

-- the side that is used: the one you asked for, unless the buff icons are there (then the opposite one), and whether it moved
local function sideFor(pfx)
	local want = sideWanted(db[pfx .. "Side"])
	if auxThere(want) then return OPPOSITE[want], true end
	return want, false
end
local function sideNow() return sideFor("call") end
ns.callSideNow = sideNow
function ns.callSideOf(kind) return sideFor(pfxOf(kind)) end

-- is the totem bar up (a totem out, or the settings open to look at it)?
local function barUp() return (ns.barUp and ns.barUp()) or ns.optionsOpen == true end

-- are the buttons on screen? all the time, or only while the bar is up (a settings page being open always shows them)
local function visibleNow()
	if db.callShow == "bar" then return barUp() end
	return true
end

-- drag a button (or the group) around: only in its own place, with the frames unlocked (a press must not cast then)
local function dragging(pfx) return modeOf(pfx or "call") == "free" and db.locked == false end

-- anchor a frame (the group, or a button on its own) the way the settings named by the prefix say; the frame already has its size
local function place(f, pfx, side)
	f:ClearAllPoints()
	if modeOf(pfx) == "free" then
		f:SetPoint(db[pfx .. "Point"] or "CENTER", UIParent, db[pfx .. "RelPoint"] or "CENTER",
			clamp(db[pfx .. "X"], -3000, 3000, 0), clamp(db[pfx .. "Y"], -3000, 3000, -200))
		return
	end
	local vertical = db.vertical and true or false
	local align = db[pfx .. "Align"]
	if align ~= "center" and align ~= "end" then align = "start" end
	local pair = ns.sidePoints[side][align]
	local edge = ns.edgeGap(side, "bar")
	local x = side == "left" and -edge or (side == "right" and edge or 0)
	local y = side == "top" and edge or (side == "bottom" and -edge or 0)
	local rel = pair[2]
	-- past the end of the bar, where a new totem lands: after all the places, not after the ones showing
	local far = (not vertical and side == "right" and "right") or (vertical and side == "bottom" and "bottom")
	if far then
		rel = ns.farRel[far][align]
		local full = MAX_SLOTS * db.size + (MAX_SLOTS - 1) * db.spacing
		if far == "right" then x = x + full else y = y - full end
	end
	f:SetPoint(pair[1], ns.bar, rel, x + clamp(db[pfx .. "OffX"], -300, 300, 0), y + clamp(db[pfx .. "OffY"], -300, 300, 0))
end

-- ---------------------------------------------------------------- the buttons

local function tooltipOf(self)
	GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
	local done = false
	if self.spellId and GameTooltip.SetSpellByID then done = pcall(GameTooltip.SetSpellByID, GameTooltip, self.spellId) end
	if not done then GameTooltip:SetText(self.spellName or self.label or "") end
	if self.kind == "call" and S.choices and #S.choices > 1 then
		GameTooltip:AddLine("Click the arrow to choose another Call spell.", 0.8, 0.8, 0.8)
	end
	GameTooltip:Show()
end

local function newButton(kind, index)
	local b = CreateFrame("Button", "ShamanKitCall" .. index, S.group, "SecureActionButtonTemplate")
	b.kind = kind
	b:RegisterForClicks("AnyUp", "AnyDown")
	b:SetFrameLevel((S.group:GetFrameLevel() or 1) + 2)
	b.icon = b:CreateTexture(nil, "BACKGROUND")
	b.icon:SetAllPoints()
	b.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
	b.cd = CreateFrame("Cooldown", nil, b, "CooldownFrameTemplate")
	b.cd:SetAllPoints()
	b.cd:SetDrawEdge(false)
	local over = CreateFrame("Frame", nil, b)
	over:SetAllPoints()
	over:SetFrameLevel(b.cd:GetFrameLevel() + 2)
	b.border = over:CreateTexture(nil, "OVERLAY")
	b.border:SetTexture(BEVEL)
	b.border:SetPoint("CENTER", 0, -1)
	local hl = b:CreateTexture(nil, "HIGHLIGHT")
	hl:SetAllPoints()
	hl:SetTexture(WHITE)
	hl:SetVertexColor(1, 1, 1, 0.18)
	b:SetScript("OnEnter", guard("call tooltip", tooltipOf))
	b:SetScript("OnLeave", GameTooltip_Hide)
	b:RegisterForDrag("LeftButton")
	b:SetMovable(true)
	b:SetClampedToScreen(true)
	b:SetScript("OnDragStart", function() ns.callStartMove(kind) end)
	b:SetScript("OnDragStop", function() ns.callStopMove() end)
	b:EnableMouse(false)
	b:Hide()
	return b
end

-- the small arrow on the Call button, and the list it opens
local function closeFlyout()
	if S.flyout and S.flyout:IsShown() then S.flyout:Hide() end
end
ns.callCloseFlyout = closeFlyout

local function chooseCall(id)
	if InCombatLockdown() then return end              -- the button's spell can't change in a fight
	db.callChoice = id
	closeFlyout()
	ns.callApply()
end

local function newFlyout()
	local f = CreateFrame("Frame", "ShamanKitCallFlyout", UIParent)
	f:SetFrameStrata("DIALOG")
	f:SetClampedToScreen(true)
	f.items = {}
	f:Hide()
	if UISpecialFrames then table.insert(UISpecialFrames, "ShamanKitCallFlyout") end   -- Esc closes it
	local idle = 0
	f:SetScript("OnUpdate", function(self, elapsed)
		idle = idle + elapsed
		if idle < 0.15 then return end
		idle = 0
		local over = (MouseIsOver and (MouseIsOver(self) or (S.arrow and MouseIsOver(S.arrow)) or (S.buttons.call and MouseIsOver(S.buttons.call)))) or false
		if over then self.away = 0 else
			self.away = (self.away or 0) + 0.15
			if self.away >= 0.6 then self:Hide() end
		end
	end)
	f:SetScript("OnShow", function(self) self.away = 0 end)
	return f
end

local function flyoutItem(f, i)
	local it = f.items[i]
	if it then return it end
	it = CreateFrame("Button", nil, f)
	it.icon = it:CreateTexture(nil, "BACKGROUND")
	it.icon:SetAllPoints()
	it.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
	it.border = it:CreateTexture(nil, "OVERLAY")
	it.border:SetTexture(BEVEL)
	it.border:SetPoint("CENTER", 0, -1)
	local hl = it:CreateTexture(nil, "HIGHLIGHT")
	hl:SetAllPoints()
	hl:SetTexture(WHITE)
	hl:SetVertexColor(1, 1, 1, 0.18)
	it:SetScript("OnClick", function(self) if self.callId then chooseCall(self.callId) end end)
	it:SetScript("OnEnter", guard("call flyout tooltip", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		local done = false
		if GameTooltip.SetSpellByID then done = pcall(GameTooltip.SetSpellByID, GameTooltip, self.callId) end
		if not done then GameTooltip:SetText(self.callLabel or "") end
		GameTooltip:Show()
	end))
	it:SetScript("OnLeave", GameTooltip_Hide)
	f.items[i] = it
	return it
end

-- which way the pick list opens: away from the nearer screen edge (up from a bar low on the screen, down from one high
-- up; a vertical bar: sideways). The arrow sits on that side of the button and points that way.
local function flyDir()
	local call = S.buttons.call
	local ok, cx, cy = pcall(call.GetCenter, call)
	local ok2, ux, uy = pcall(UIParent.GetCenter, UIParent)
	if not ok then cx, cy = nil, nil end
	if not ok2 then ux, uy = nil, nil end
	if db.vertical then return (cx and ux and cx < ux) and "RIGHT" or "LEFT" end
	return (cy and uy and cy < uy) and "UP" or "DOWN"
end

local ARROW_AT = {   -- the arrow's own point, the button's point, and how far to turn the picture (it points up)
	UP = { "BOTTOM", "TOP", 0 }, DOWN = { "TOP", "BOTTOM", math.pi },
	RIGHT = { "LEFT", "RIGHT", -math.pi / 2 }, LEFT = { "RIGHT", "LEFT", math.pi / 2 },
}

local function placeArrow()
	local arrow, cb = S.arrow, S.buttons.call
	local dir = flyDir()
	S.arrowDir = dir
	local at = ARROW_AT[dir]
	arrow:ClearAllPoints()
	arrow:SetPoint(at[1], cb, at[2], 0, 0)
	pcall(arrow.tex.SetRotation, arrow.tex, at[3])
end

ns.callPlaceArrow = placeArrow

local function openFlyout()
	if InCombatLockdown() or not S.choices then return end
	local current = chosenCall(S.choices)
	local others = {}
	for _, c in ipairs(S.choices) do if not current or c.id ~= current.id then others[#others + 1] = c end end
	if #others == 0 then return end
	if not S.flyout then S.flyout = newFlyout() end
	local f, call = S.flyout, S.buttons.call
	local s, gap = buttonSize(), db.spacing
	local vertical = db.vertical and true or false
	local dir = flyDir()
	placeArrow()                                     -- the bar may have been dragged to the other half of the screen
	for i = 1, #f.items do f.items[i]:Hide() end
	for i, c in ipairs(others) do
		local it = flyoutItem(f, i)
		it.callId, it.callLabel = c.id, c.label
		it:SetSize(s, s)
		it.border:SetSize(s * 66 / 36, s * 66 / 36)
		it.icon:SetTexture(spellTexture(c.id))
		it:ClearAllPoints()
		local off = (i - 1) * (s + gap)
		if dir == "UP" then it:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 0, off)
		elseif dir == "DOWN" then it:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -off)
		elseif dir == "RIGHT" then it:SetPoint("TOPLEFT", f, "TOPLEFT", off, 0)
		else it:SetPoint("TOPRIGHT", f, "TOPRIGHT", -off, 0) end
		it:Show()
	end
	local long = #others * s + (#others - 1) * gap
	if vertical then f:SetSize(long, s) else f:SetSize(s, long) end
	f:ClearAllPoints()
	if dir == "UP" then f:SetPoint("BOTTOMLEFT", call, "TOPLEFT", 0, 4)
	elseif dir == "DOWN" then f:SetPoint("TOPLEFT", call, "BOTTOMLEFT", 0, -4)
	elseif dir == "RIGHT" then f:SetPoint("TOPLEFT", call, "TOPRIGHT", 4, 0)
	else f:SetPoint("TOPRIGHT", call, "TOPLEFT", -4, 0) end
	f:Show()
end

local function toggleFlyout()
	if S.flyout and S.flyout:IsShown() then closeFlyout() else openFlyout() end
end

local function newArrow()
	local a = CreateFrame("Button", nil, S.group)
	a:SetFrameLevel((S.group:GetFrameLevel() or 1) + 6)
	a.tex = a:CreateTexture(nil, "ARTWORK")
	a.tex:SetAllPoints()
	a.tex:SetTexture(ARROW)
	local hl = a:CreateTexture(nil, "HIGHLIGHT")
	hl:SetAllPoints()
	hl:SetTexture(ARROW)
	hl:SetBlendMode("ADD")
	a:SetScript("OnClick", guard("call arrow", toggleFlyout))
	a:SetScript("OnEnter", guard("call arrow tip", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText("Choose the Call spell")
		if InCombatLockdown() then GameTooltip:AddLine("Not in a fight.", 1, 0.5, 0.5) end
		GameTooltip:Show()
	end))
	a:SetScript("OnLeave", GameTooltip_Hide)
	a:Hide()
	return a
end

-- ---------------------------------------------------------------- putting it in place (out of combat)

local function ensure()
	if S.group then return true end
	if InCombatLockdown() or not ns.bar then return false end
	local g = CreateFrame("Frame", "ShamanKitCalls", UIParent)
	g:SetSize(1, 1)
	g:SetMovable(true)
	g:SetClampedToScreen(true)
	S.group = g
	S.buttons.call = newButton("call", 1)
	S.buttons.totemic = newButton("totemic", 2)
	S.buttons.recall = newButton("recall", 3)
	S.arrow = newArrow()
	return true
end

local function arm(b, name)
	-- the spell by name (the highest rank), set only when it changed
	local want = name or false
	if b.armed == want then return end
	b.armed = want
	b:SetAttribute("type1", name and "spell" or nil)
	b:SetAttribute("spell1", name)
end

-- moving by hand (its own place, frames unlocked): the group, or a button placed on its own. Out of combat only, like the
-- bar; a drag that really started is finished and saved, one that never did saves nothing, and a fight that begins
-- mid-drag finishes it when it ends
local moving
function ns.callStartMove(kind)
	if InCombatLockdown() or not S.group then return end
	local pfx = pfxOf(kind)
	if not dragging(pfx) then return end
	local f = pfx == "call" and S.group or S.buttons[kind]
	if not f then return end
	f:StartMoving()
	moving = { f = f, pfx = pfx }
end
local function finishMove()
	local m = moving
	moving = nil
	m.f:StopMovingOrSizing()
	local p, rel, rp, x, y = m.f:GetPoint()
	if m.pfx ~= "call" and rel ~= UIParent then
		-- a button is a child of the group: take where it ended up on the screen instead
		local ok, cx, cy = pcall(m.f.GetCenter, m.f)
		local ok2, ux, uy = pcall(UIParent.GetCenter, UIParent)
		if ok and ok2 and cx and ux then p, rp, x, y = "CENTER", "CENTER", cx - ux, cy - uy end
	end
	db[m.pfx .. "Point"], db[m.pfx .. "RelPoint"], db[m.pfx .. "X"], db[m.pfx .. "Y"] = p, rp, x, y
end
function ns.callStopMove()
	if not moving or InCombatLockdown() then return end   -- finished by PLAYER_REGEN_ENABLED
	finishMove()
end

-- back to the usual spot (the group's, or one button's)
function ns.callResetPlace(kind)
	local d, k = ns.defaults, kind and POS[kind] or "call"
	for _, f in ipairs({ "Side", "Align", "OffX", "OffY", "Point", "RelPoint", "X", "Y" }) do db[k .. f] = d[k .. f] end
	ns.callApply()
end

-- everything that decides what is drawn: when none of it changed, a pass has nothing to do
local SIG_FIELDS = { "Anchor", "Side", "Align", "OffX", "OffY", "Point", "RelPoint", "X", "Y" }
local function signature(kinds, side)
	local parts = { tostring(db.callShow), tostring(db.callScale),
		tostring(db.size), tostring(db.spacing), tostring(db.vertical), tostring(db.locked), tostring(side), tostring(visibleNow()) }
	for _, pfx in ipairs({ "call", "posCall", "posTotemic", "posRecall" }) do
		for _, f in ipairs(SIG_FIELDS) do parts[#parts + 1] = tostring(db[pfx .. f]) end
	end
	for _, kind in ipairs({ "call", "totemic", "recall" }) do
		parts[#parts + 1] = kind .. tostring(db[POS[kind] .. "Own"]) .. tostring((sideFor(POS[kind])))
	end
	for _, k in ipairs(kinds) do parts[#parts + 1] = k[1] .. ":" .. k[2].id .. ":" .. tostring(spellName(k[2].id, k[2].label)) end
	return table.concat(parts, "|")
end

-- the whole pass: which buttons, what they cast, how big, where they sit, whether they are on screen
local function apply()
	if not db then return end
	if InCombatLockdown() then S.pending = true return end
	S.pending = false
	if not ensure() then return end
	S.choices = knownCalls()
	local call = chosenCall(S.choices)

	local kinds = {}
	if db.callOn and call then kinds[#kinds + 1] = { "call", call } end
	if db.callTotemic and known(TOTEMIC.id) then kinds[#kinds + 1] = { "totemic", TOTEMIC } end
	if db.callRecall and known(RECALL.id) then kinds[#kinds + 1] = { "recall", RECALL } end

	local side, moved = sideNow()
	if mode() == "free" then moved = false end         -- no bar to sit beside: nothing to get out of the way of
	S.side, S.sideMoved = side, moved
	local sig = signature(kinds, side) .. "|" .. #S.choices
	if sig == S.sig then ns.callPaintCooldowns() return end
	S.sig = sig

	local s, gap = buttonSize(), clamp(db.spacing, 0, 24, 4)
	local vertical = db.vertical and true or false
	local show = visibleNow()
	local on, grouped = {}, 0
	S.ownSide, S.ownMoved = {}, {}
	for i, k in ipairs(kinds) do
		local kind, sp = k[1], k[2]
		on[kind] = true
		local b = S.buttons[kind]
		local name = spellName(sp.id, sp.label)
		b.spellId, b.spellName, b.label = sp.id, name, sp.label
		b:SetSize(s, s)
		b.border:SetSize(s * 66 / 36, s * 66 / 36)
		b.icon:SetTexture(spellTexture(sp.id))
		local pfx = pfxOf(kind)
		if pfx == "call" then
			grouped = grouped + 1
			local off = (grouped - 1) * (s + gap)
			b:ClearAllPoints()
			if vertical then b:SetPoint("TOPLEFT", S.group, "TOPLEFT", 0, -off) else b:SetPoint("TOPLEFT", S.group, "TOPLEFT", off, 0) end
		else
			local bside, bmoved = sideFor(pfx)
			if modeOf(pfx) == "free" then bmoved = false end
			S.ownSide[kind], S.ownMoved[kind] = bside, bmoved
			place(b, pfx, bside)
		end
		arm(b, (not dragging(pfx)) and name or nil)       -- a press that starts a drag must not cast
		b:EnableMouse(show)
		b:Show()
	end
	for kind, b in pairs(S.buttons) do
		if not on[kind] then
			arm(b, nil)
			b:EnableMouse(false)
			b:Hide()
			b.spellId = nil
		end
	end
	S.shown = {}
	for _, k in ipairs(kinds) do S.shown[#S.shown + 1] = k[1] end

	-- the group: as long as the buttons that are in it
	local n = #kinds
	local g = S.group
	local long = math.max(grouped, 1) * s + math.max(grouped - 1, 0) * gap
	if vertical then g:SetSize(s, long) else g:SetSize(long, s) end
	place(g, "call", side)
	g:SetShown(n > 0 and show)

	-- the arrow: only on the Call button, and only when there is something to choose
	local arrow, cb = S.arrow, S.buttons.call
	if on.call and #S.choices > 1 then
		local aw = math.max(12, math.floor(s * 0.4))
		arrow:SetSize(aw, aw)
		S.arrowDir = nil
		ns.callPlaceArrow()
		arrow:Show()
	else
		arrow:Hide()
		closeFlyout()
	end
	if S.flyout and S.flyout:IsShown() then closeFlyout() end   -- anything changed: the list would be stale

	ns.callPaintCooldowns()
end
ns.callApply = guard("calls", apply)

-- ---------------------------------------------------------------- cooldowns (also in a fight)

-- the sweep and nothing else: the start and the duration go straight into the Cooldown frame, never compared (in a fight
-- the game may hand over secret numbers)
local function paintCooldown(b)
	if not (b and b:IsShown() and b.spellId and b.cd) then return end
	if not (C_Spell and C_Spell.GetSpellCooldown) then return end
	local ok, info = pcall(C_Spell.GetSpellCooldown, b.spellId)
	if not ok or type(info) ~= "table" then return end
	pcall(b.cd.SetCooldown, b.cd, info.startTime, info.duration)
end

function ns.callPaintCooldowns()
	for _, b in pairs(S.buttons) do paintCooldown(b) end
end

-- ---------------------------------------------------------------- events

local function work()
	S.scheduled = false
	if S.full or S.pending then
		S.full = false
		if InCombatLockdown() then S.pending = true else apply() end
	end
	if S.cdDirty then
		S.cdDirty = false
		ns.callPaintCooldowns()
	end
end
local guardedWork = guard("calls", work)

local function schedule(full, cd)
	if full then S.full = true end
	if cd then S.cdDirty = true end
	if S.scheduled then return end
	S.scheduled = true
	if C_Timer and C_Timer.After then C_Timer.After(0.05, guardedWork) else guardedWork() end
end

local EVENTS = { "PLAYER_ENTERING_WORLD", "SPELLS_CHANGED", "PLAYER_LEVEL_UP", "SPELL_UPDATE_COOLDOWN",
	"PLAYER_REGEN_ENABLED", "PLAYER_REGEN_DISABLED" }
ns.CALL_EVENTS = EVENTS

local cf
local function onEvent(_, event)
	if event == "SPELL_UPDATE_COOLDOWN" then
		schedule(false, true)                          -- fine in a fight: only the sweep
	elseif event == "PLAYER_REGEN_DISABLED" then
		closeFlyout()                                  -- hiding our own plain frame is fine
	elseif event == "PLAYER_REGEN_ENABLED" then
		if moving then finishMove() end
		schedule(true, true)
	else
		schedule(true, true)
	end
end

function ns.callInit()
	db = ns.get()
	if cf then return end
	cf = CreateFrame("Frame")
	cf:SetScript("OnEvent", guard("calls event", onEvent))
	for _, e in ipairs(EVENTS) do
		local ok, err = pcall(cf.RegisterEvent, cf, e)    -- one at a time: a name this client doesn't know throws
		if not ok then dbg("CALLS: event %s is not known here (%s)", e, short(err)) end
	end
	ns.callApply()
end

-- ---------------------------------------------------------------- status

function ns.callInfo()
	local out = {}
	if not db then return out end
	for _, c in ipairs(CALLS) do
		out[#out + 1] = ("%s: %s"):format(c.label, known(c.id) and "you have it" or "you don't have it")
	end
	out[#out + 1] = ("%s: %s"):format(TOTEMIC.label, known(TOTEMIC.id) and "you have it" or "you don't have it")
	out[#out + 1] = ("%s: %s"):format(RECALL.label, known(RECALL.id) and "you have it" or "you don't have it")
	local call = chosenCall()
	out[#out + 1] = ("Call button casts: %s"):format(call and call.label or "nothing yet")
	local shown = S.shown and #S.shown > 0 and table.concat(S.shown, ", ") or "none"
	out[#out + 1] = ("buttons on screen: %s%s"):format(shown, S.sideMoved and " (on the opposite side: the buff icons are on yours)" or "")
	out[#out + 1] = ("placed: %s, shown %s, %d%% size"):format(mode() == "free" and "in their own place" or ("beside the totem bar (" .. tostring(S.side) .. ")"),
		db.callShow == "bar" and "only while a totem is out" or "all the time", clamp(db.callScale, 50, 150, 100))
	return out
end
