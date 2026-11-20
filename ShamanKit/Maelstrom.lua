-- ShamanKit Maelstrom: a 5-square Maelstrom Weapon stack bar for Enhancement shamans, with a glow on the Lightning Bolt
-- button at 5 stacks.
--
-- This module is the MaelstromBar addon (https://github.com/Drbmk/MaelstromBar) folded into ShamanKit, ported from
-- its source with the author's permission in the form of its MIT licence:
--
--   MIT License. Copyright (c) 2026 Petitcorps (drbmk)
--   Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated
--   documentation files (the "Software"), to deal in the Software without restriction, including without limitation
--   the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
--   permit persons to whom the Software is furnished to do so, subject to the following conditions: The above
--   copyright notice and this permission notice shall be included in all copies or substantial portions of the
--   Software. THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT
--   LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT
--   SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
--   OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
--   DEALINGS IN THE SOFTWARE.
--
-- How it works (the same as the standalone addon):
--   * Out of combat the stacks are read from the player's buff (spell id 408505, with a name fallback) about 20 times a
--     second and drawn on our own five squares.
--   * In a fight the game hides auras from addons, so the squares, the stack count and the glow are drawn by the game
--     itself: an AuraContainer whose slots fill status bars when the buff is on the player (the same route as the
--     Lightning Shield icon). It is built out of combat; changes made in a fight are applied when it ends.
--   * The glow is a set of plain frames over every action button that holds Lightning Bolt (spells, macros, castsequences,
--     other bar addons), driven by the same stack value, plus an engine-driven copy for the fight.
--
-- What was left out of the port: the French translation, the "ladder" diagnostic of the native layer. The global Lua
-- error recorder is kept but is an option that starts off (it lives in the per-character log file).

local ADDON, ns = ...
local dbg, guard, isSecret = ns.dbg, ns.guard, ns.isSecret
local db

local MAX = 5
local PREFIX = "|cff33ff99ShamanKit|r Maelstrom: "

-- ---------------------------------------------------------------- settings

local D = ns.defaults
D.mwOn = false                           -- the whole module (bar and glow) starts off, like every new feature
D.mwAlways = false                       -- show the bar all the time (off: with stacks, or in a fight)
D.mwOnlyStacks = false                   -- show it ONLY while you have stacks, also in a fight (off: it is up in every fight)
D.mwCount = false                        -- the stack count as a number by the bar
D.mwCountPos = "top"                     -- "top" (above), "center", "bottom" (below)
D.mwCountX, D.mwCountY = 0, 0            -- fine offset of the count, pixels
D.mwW, D.mwH, D.mwGap = 28, 22, 3        -- square width, height, spacing
D.mwScale = 100                          -- percent
D.mwColor = { 0, 0.55, 1 }               -- stacks 1 to 4
D.mwColorFull = { 0.55, 0.95, 1 }        -- 5 stacks
D.mwColorBg = { 0.08, 0.1, 0.15 }        -- behind the squares
D.mwColorGlow = { 1, 0.85, 0.2 }         -- the glow on the action button
D.mwGlow = true                          -- glow at 5 stacks
-- D.mwGlowSpell: nil = Lightning Bolt, else a spell name or id          (no default: nil)
-- D.mwAura: nil = the buff is found by id, else a buff name to look for (no default: nil)
-- db.mwFrames: names of frames to glow as well (a list; nil = none)     (no default: a shared table would be edited in place)
D.mwErrorLog = false                     -- record Lua errors of the whole client (/shamankit mw log)
D.mwPoint, D.mwRelPoint, D.mwX, D.mwY = "CENTER", "CENTER", 0, -150

-- values in the saved file can be damaged: always go through these
local function num(v, lo, hi, def)
	if type(v) ~= "number" or v ~= v then return def end
	if v < lo then return lo elseif v > hi then return hi end
	return v
end
local function rgb(c, def)
	if type(c) == "table" and type(c[1]) == "number" and type(c[2]) == "number" and type(c[3]) == "number" then return c end
	return def
end
local function size() return math.floor(num(db.mwW, 10, 80, 28)), math.floor(num(db.mwH, 6, 60, 22)), math.floor(num(db.mwGap, 0, 30, 3)) end
local function scale() return num(db.mwScale, 50, 300, 100) / 100 end
local function colour(key) return rgb(db[key], D[key]) end
local function countPos() local p = db.mwCountPos; return (p == "center" or p == "bottom") and p or "top" end

local S = {
	active = false,       -- a shaman, and the standalone MaelstromBar is not loaded
	built = false,
	off = true,
	squares = {},
	test = nil,           -- stacks being faked (the settings page and /shamankit mw test)
	glowActive = {}, glowFrames = {}, glowNatives = {},
	glowDirty = true,
}
ns.mwState = S                                      -- (read by the tests)

local function short(m) m = tostring(m):gsub("%s+", " "); return m:sub(1, 120) end
local function fight() return (UnitAffectingCombat and UnitAffectingCombat("player")) or InCombatLockdown() end

local function setColor(tex, r, g, b, a)
	if tex.SetColorTexture then tex:SetColorTexture(r, g, b, a or 1) else tex:SetTexture(r, g, b, a or 1) end
end

-- ---------------------------------------------------------------- reading the stacks

local IDS = { 408505, 53817, 344179 }             -- the Maelstrom Weapon buff (the first is Forever's)
local ID_SET = { [408505] = true, [53817] = true, [344179] = true }
local NATIVE_IDS = { [408505] = true, [408498] = true, [53817] = true, [344179] = true }
local NAMES = { ["maelstrom weapon"] = true, ["arme du maelstrom"] = true, ["arme du maelström"] = true }
local SCAN_EVERY = 0.5                            -- the by-name scan only runs this often

local function isMaelstrom(name, spellId)
	if type(spellId) == "number" and ID_SET[spellId] then return true end
	if type(name) == "string" then
		local lower = name:lower()
		if NAMES[lower] then return true end
		if type(db.mwAura) == "string" and db.mwAura ~= "" and lower == db.mwAura:lower() then return true end
	end
	return false
end

-- one pass over the player's buffs (own function so a tick makes no closure)
local function scanBuffs()
	for i = 1, 40 do
		local a = C_UnitAuras.GetAuraDataByIndex("player", i, "HELPFUL")
		if not a then break end
		if isMaelstrom(a.name, a.spellId) then return a.applications or 1 end
	end
	return 0
end

-- The stack count, a number, or a secret value (a StatusBar takes one without anyone comparing it). A read the game
-- refuses (a fight) answers 0: the squares are then the game's own copy anyway.
local function readStacks()
	local cu = C_UnitAuras
	if not cu then return 0 end
	if cu.GetPlayerAuraBySpellID then
		for i = 1, #IDS do
			local ok, a = pcall(cu.GetPlayerAuraBySpellID, IDS[i])
			if not ok then break end
			if a then
				local c = a.applications
				if isSecret(c) then return c end
				if not (type(c) == "number" and c > 0) then c = 1 end
				return c
			end
		end
	end
	-- by name (another client language, or a changed id), not every tick: it reads every buff
	local now = GetTime()
	if cu.GetAuraDataByIndex and (not S.scanAt or now - S.scanAt >= SCAN_EVERY or now < S.scanAt) then
		S.scanAt = now
		local ok, res = pcall(scanBuffs)
		S.scanned = ok and res or 0
	end
	return S.scanned or 0
end

local function getStacks()
	if S.test then return S.test end
	local ok, res = pcall(readStacks)
	if ok then return res or 0 end
	if res ~= S.lastErr then S.lastErr = res; dbg("MAELSTROM read error: %s", short(res)) end
	return 0
end

-- ---------------------------------------------------------------- the bar

local bar, count, countDragRect
local function buildBar()
	if bar then return end
	bar = CreateFrame("Frame", "ShamanKitMaelstrom", UIParent)
	bar:SetFrameStrata("MEDIUM")
	bar:SetClampedToScreen(true)
	bar:Hide()
	for i = 1, MAX do
		local sq = CreateFrame("Frame", nil, bar)
		sq.border = sq:CreateTexture(nil, "BACKGROUND")
		sq.border:SetAllPoints()
		setColor(sq.border, 0, 0, 0, 0.9)
		sq.bg = sq:CreateTexture(nil, "BORDER")
		sq.bg:SetPoint("TOPLEFT", 1, -1)
		sq.bg:SetPoint("BOTTOMRIGHT", -1, 1)
		-- StatusBars take a secret value without the addon comparing it: `fill` fills when stacks >= i, `fullFill`
		-- (4..5) only at 5 stacks, over it, in the other colour
		local function make(lo, hi, level)
			local s = CreateFrame("StatusBar", nil, sq)
			s:SetPoint("TOPLEFT", 2, -2)
			s:SetPoint("BOTTOMRIGHT", -2, 2)
			s:SetFrameLevel(sq:GetFrameLevel() + level)
			s:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
			s:SetMinMaxValues(lo, hi)
			s:SetValue(lo)
			return s
		end
		sq.fill = make(i - 1, i, 1)
		sq.fullFill = make(MAX - 1, MAX, 2)
		S.squares[i] = sq
	end
	count = bar:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	count:SetTextColor(1, 1, 1)
	count:Hide()
	S.bar, S.count = bar, count
end

-- where the count sits: above (default), in the middle, or below the bar, plus the fine offset
local function countAnchor()
	local pos = countPos()
	local x, y = num(db.mwCountX, -200, 200, 0), num(db.mwCountY, -100, 100, 0)
	if pos == "center" then return "CENTER", "CENTER", x, y end
	if pos == "bottom" then return "TOP", "BOTTOM", x, y - 4 end
	return "BOTTOM", "TOP", x, y + 4
end

local function applyCountPos()
	local p, rp, x, y = countAnchor()
	count:ClearAllPoints()
	count:SetPoint(p, bar, rp, x, y)
end

local function applyPlace()
	bar:ClearAllPoints()
	bar:SetPoint(type(db.mwPoint) == "string" and db.mwPoint or "CENTER", UIParent, type(db.mwRelPoint) == "string" and db.mwRelPoint or "CENTER",
		num(db.mwX, -4000, 4000, 0), num(db.mwY, -4000, 4000, -150))
	bar:SetScale(scale())
end

local function applySize()
	local w, h, gap = size()
	bar:SetSize(MAX * w + (MAX - 1) * gap, h)
	for i = 1, MAX do
		local sq = S.squares[i]
		sq:SetSize(w, h)
		sq:ClearAllPoints()
		sq:SetPoint("LEFT", bar, "LEFT", (i - 1) * (w + gap), 0)
	end
end

local function applyBg()
	local c = colour("mwColorBg")
	for i = 1, MAX do setColor(S.squares[i].bg, c[1], c[2], c[3], 0.8) end
end

-- ---------------------------------------------------------------- the game-drawn copy for a fight

local function countFormatter()
	if not (C_StringUtil and C_StringUtil.CreateNumericRuleFormatter and Enum and Enum.NumericRuleFormatRounding) then return nil end
	local ok, formatter = pcall(C_StringUtil.CreateNumericRuleFormatter)
	if not ok or not formatter then return nil end
	local down = Enum.NumericRuleFormatRounding.Down
	pcall(formatter.SetBreakpoints, formatter, {
		{ threshold = 0, min = 0, step = 1, rounding = down, format = "%d", components = { { div = 1, step = 1, rounding = down } } },
	})
	return formatter
end

local function loadContainerAddon()
	if C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.LoadAddOn and not C_AddOns.IsAddOnLoaded("Blizzard_AuraContainer") then
		C_AddOns.LoadAddOn("Blizzard_AuraContainer")
	end
end

-- Built OUT of combat only. Two slots per square: min..max = i-1..i (full from i stacks) and the "full" bar 4..5 over
-- it. Widgets the game drives must be made inside initializeFrame, so geometry and colours are fixed here and a change
-- means a rebuild (S.nativeChanged, debounced, never in a fight).
local function buildNative()
	if S.layer or S.nativeFailed or not db or not S.built or InCombatLockdown() then return end
	local ok, err = pcall(function()
		loadContainerAddon()
		local host = CreateFrame("Frame", nil, bar)
		host:SetAllPoints(bar)
		host:SetFrameLevel(bar:GetFrameLevel() + 5)
		host:SetAlpha(0)                               -- only visible in a fight (update decides)
		local container = CreateFrame("AuraContainer", nil, host, "CustomAuraContainerTemplate")
		container:SetUnit("player")
		local fills, nativeCount = {}, nil
		local w, h, gap = size()
		local showCount = db.mwCount and true or false
		local function slot(key, lo, hi, c, x1, y1, x2, y2, withCount, level)
			local s = container:AddAuraSlot(key, "HELPFUL", {
				candidateFilters = { includeSpellIDs = NATIVE_IDS },
				initializeFrame = function(frame)
					frame:ClearAllPoints()
					frame:SetPoint("TOPLEFT", host, "TOPLEFT", x1, y1)
					frame:SetPoint("BOTTOMRIGHT", host, "TOPLEFT", x2, y2)
					frame:SetFrameLevel(host:GetFrameLevel() + (level or 1))
					pcall(frame.SetMouseClickEnabled, frame, false)
					pcall(frame.EnableMouseMotion, frame, false)
					local sb = CreateFrame("StatusBar", nil, frame)
					sb:SetAllPoints(frame)
					sb:SetFrameLevel(frame:GetFrameLevel() + 1)
					sb:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
					sb:SetStatusBarColor(c[1], c[2], c[3], 1)
					frame:SetApplicationBar(sb, { minApplications = lo, maxApplications = hi })
					fills[#fills + 1] = { bar = sb, label = key .. " (min=" .. lo .. ", max=" .. hi .. ")" }
					if withCount and showCount then
						-- the game writes the number itself, at the place our own count has
						nativeCount = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
						local p, rp, cx, cy = countAnchor()
						nativeCount:SetPoint(p, host, rp, cx, cy)
						nativeCount:SetTextColor(1, 1, 1)
						frame:SetApplicationCount(nativeCount, { formatter = countFormatter() })
					end
				end,
			})
			if not s then error("slot " .. key .. " unavailable") end
			return s
		end
		local cn, cf = colour("mwColor"), colour("mwColorFull")
		for i = 1, MAX do
			local x = (i - 1) * (w + gap)
			-- inset 2 px like our own fills, so the border and background of the square stay visible
			slot("mwsq" .. i, i - 1, i, cn, x + 2, -2, x + w - 2, -(h - 2), i == 1, 1)
			slot("mwfull" .. i, MAX - 1, MAX, cf, x + 2, -2, x + w - 2, -(h - 2), false, 3)
		end
		S.nativeHost, S.layer = host, { host = host, fills = fills, count = nativeCount }
	end)
	if not ok then
		if S.nativeHost then S.nativeHost:Hide() end
		S.nativeHost, S.layer = nil, nil
		S.nativeFailed = true
		dbg("MAELSTROM native layer unavailable: %s", short(err))
		print(PREFIX .. "the game-drawn display for fights could not be made: " .. short(err))
	else
		dbg("MAELSTROM native layer built (%d bars)", #S.layer.fills)
	end
end

local clearGlowNatives

local function rebuildNative()
	if S.nativeFailed then return end
	if InCombatLockdown() then S.nativeDirty = true return end
	S.nativeDirty = false
	if S.nativeHost then S.nativeHost:Hide() end         -- the old layer is abandoned (the game offers no way to delete one)
	S.nativeHost, S.layer = nil, nil
	buildNative()
	clearGlowNatives()
	S.glowDirty = true
end

-- Sliders and the colour picker change values many times a second: rebuild once, after they settle
local function scheduleNative()
	if InCombatLockdown() then S.nativeDirty = true return end
	if not (C_Timer and C_Timer.After) then rebuildNative() return end
	local token = {}
	S.nativeToken = token
	C_Timer.After(0.6, function()
		if S.nativeToken ~= token then return end
		S.nativeToken = nil
		guard("maelstrom rebuild", rebuildNative)()
	end)
end
ns.mwRebuild = rebuildNative

-- ---------------------------------------------------------------- the glow on the action buttons

local glowTargets = {}

local function spellNameOf(id)
	if C_Spell and C_Spell.GetSpellName then
		local ok, n = pcall(C_Spell.GetSpellName, id)
		if ok and type(n) == "string" and not isSecret(n) then return n end
		return nil
	end
	if GetSpellInfo then return (GetSpellInfo(id)) end
end

local function buildGlowTargets()
	glowTargets = {}
	local custom = db.mwGlowSpell
	if custom ~= nil and custom ~= "" then
		local id = tonumber(custom)
		if id then
			glowTargets[id] = true
			local n = spellNameOf(id)
			if n then glowTargets[n:lower()] = true end
		else
			glowTargets[tostring(custom):lower()] = true
		end
	else
		for _, id in ipairs({ 403, 188196 }) do        -- Lightning Bolt
			glowTargets[id] = true
			local n = spellNameOf(id)
			if n then glowTargets[n:lower()] = true end
		end
		glowTargets["lightning bolt"] = true
		glowTargets["eclair"] = true
		glowTargets[("Éclair"):lower()] = true
	end
end

local function spellMatches(spellId)
	if not spellId then return false end
	if glowTargets[spellId] then return true end
	local n = spellNameOf(spellId)
	return n and glowTargets[n:lower()] or false
end

local function macroBody(macroId)
	if GetMacroBody then
		local ok, body = pcall(GetMacroBody, macroId)
		if ok and type(body) == "string" then return body end
	end
	if GetMacroInfo then
		local ok, _, _, body = pcall(GetMacroInfo, macroId)
		if ok and type(body) == "string" then return body end
	end
	return nil
end

local MACRO_CAST = { cast = true, use = true, spell = true, lancer = true, utiliser = true }

local function clauseMatches(clause)
	clause = clause:gsub("^%s+", ""):gsub("%s+$", "")
	if clause == "" then return false end
	local id = tonumber(clause)
	if id and glowTargets[id] then return true end
	return glowTargets[clause] == true
end

-- #showtooltip, [conditions], /cast A; B and /castsequence reset=5 A, B are all understood
local function macroMatches(macroId)
	local body = macroBody(macroId)
	if not body then return false end
	for raw in body:gmatch("[^\r\n]+") do
		local line = raw:lower():gsub("^%s+", "")
		local cmd, rest = line:match("^/(%a+)%s*(.*)$")
		if cmd and rest ~= "" then
			rest = rest:gsub("%b[]%s*", "")
			if MACRO_CAST[cmd] then
				for clause in rest:gmatch("([^;]+)") do if clauseMatches(clause) then return true end end
			elseif cmd == "castsequence" then
				rest = rest:gsub("reset=%s*[%w%/]+%s*", "")
				for clause in rest:gmatch("([^,]+)") do if clauseMatches(clause) then return true end end
			end
		end
	end
	return false
end

local function slotMatches(slot)
	if not slot then return false end
	local t, id = GetActionInfo(slot)
	if t == "spell" then return spellMatches(id) end
	if t == "macro" then return macroMatches(id) end
	return false
end

local BAR_PREFIXES = {
	{ "ActionButton", 12 }, { "MultiBarBottomLeftButton", 12 }, { "MultiBarBottomRightButton", 12 }, { "MultiBarRightButton", 12 },
	{ "MultiBarLeftButton", 12 }, { "MultiBar5Button", 12 }, { "MultiBar6Button", 12 }, { "MultiBar7Button", 12 },
	{ "BT4Button", 180 }, { "DominosActionButton", 180 },
}

local function buttonAction(btn)
	local a = btn._state_action or btn.action
	if type(a) ~= "number" and btn.GetAttribute then a = btn:GetAttribute("action") end
	return tonumber(a)
end

-- buttons of other UIs (controller UI...) are found by looking at every global button; cached for 5 s
local globalButtons, globalButtonsTime = nil, 0

local function frameMatches(f)
	local ok, a = pcall(buttonAction, f)
	local slot = ok and tonumber(a) or nil
	if slot and slotMatches(slot) then return true end
	if f.GetAttribute then
		local okS, sp = pcall(f.GetAttribute, f, "spell")
		if okS and type(sp) == "number" then return spellMatches(sp) end
		if okS and type(sp) == "string" then return glowTargets[sp:lower()] == true or glowTargets[tonumber(sp)] == true end
	end
	return false
end

local function allButtons()
	if globalButtons and (time() - globalButtonsTime) < 5 then return globalButtons end
	local found = {}
	for _, f in pairs(_G) do
		local ok, isBtn = pcall(function() return type(f) == "table" and f.GetAttribute and f.IsShown and f:IsObjectType("Button") end)
		if ok and isBtn then found[#found + 1] = f end
	end
	globalButtons, globalButtonsTime = found, time() or 0
	return found
end

local function collectGlowButtons()
	local list, seen = {}, {}
	local function try(btn)
		if btn and btn.IsShown and not seen[btn] and slotMatches(buttonAction(btn)) then seen[btn] = true; list[#list + 1] = btn end
	end
	for _, p in ipairs(BAR_PREFIXES) do for i = 1, p[2] do try(_G[p[1] .. i]) end end
	for barIndex = 1, 10 do for i = 1, 12 do try(_G["ElvUI_Bar" .. barIndex .. "Button" .. i]) end end
	if type(db.mwFrames) == "table" then
		for _, name in ipairs(db.mwFrames) do
			local f = _G[name]
			if f and f.IsShown and not seen[f] then seen[f] = true; list[#list + 1] = f end
		end
	end
	for _, f in ipairs(allButtons()) do
		if not seen[f] and frameMatches(f) then
			local ok, shown = pcall(f.IsShown, f)
			if ok and shown then seen[f] = true; list[#list + 1] = f end
		end
	end
	return list
end
ns.mwGlowButtons = collectGlowButtons

local function glowFrameFor(btn)
	local g = S.glowFrames[btn]
	if not g then
		g = CreateFrame("Frame", nil, btn)
		g:SetFrameLevel((btn:GetFrameLevel() or 1) + 8)
		local w = btn:GetWidth(); if not w or w < 10 then w = 36 end
		local h = btn:GetHeight(); if not h or h < 10 then h = 36 end
		g:SetSize(w * 2.1, h * 2.1)
		g:SetPoint("CENTER", btn, "CENTER", 0, 0)
		-- StatusBars (4..5): full at 5 stacks, empty otherwise, even with a secret value in a fight
		local function layer(texture, sw, sh, alpha)
			local s = CreateFrame("StatusBar", nil, g)
			s:SetSize(sw, sh)
			s:SetPoint("CENTER", g, "CENTER", 0, 0)
			s:SetStatusBarTexture(texture)
			local t = s:GetStatusBarTexture()
			if t and t.SetBlendMode then t:SetBlendMode("ADD") end
			s:SetAlpha(alpha)
			s:SetMinMaxValues(MAX - 1, MAX)
			s:SetValue(MAX - 1)
			return s
		end
		g.border = layer("Interface\\Buttons\\UI-ActionButton-Border", w * 2.1, h * 2.1, 1)
		g.border2 = layer("Interface\\Buttons\\UI-ActionButton-Border", w * 1.8, h * 1.8, 1)
		g.fill = layer("Interface\\Buttons\\WHITE8X8", w, h, 0.4)
		g.ag = g:CreateAnimationGroup()
		g.ag:SetLooping("BOUNCE")
		local a = g.ag:CreateAnimation("Alpha")
		if a.SetFromAlpha then a:SetFromAlpha(1); a:SetToAlpha(0.45) end
		a:SetDuration(0.4)
		S.glowFrames[btn] = g
	end
	return g
end

local function hideGlows()
	for btn in pairs(S.glowActive) do
		local g = S.glowFrames[btn]
		if g then g.ag:Stop(); g:Hide() end
		S.glowActive[btn] = nil
	end
end

clearGlowNatives = function()
	for btn, host in pairs(S.glowNatives) do
		if host then host:Hide() end
		S.glowNatives[btn] = nil
	end
end

-- the game's own copy of the glow for a fight: one slot per layer, visible at 5 stacks (min = max). Made out of combat;
-- a glow that appears in a fight gets its copy when the fight is over (S.glowNativePending)
local function attachGlowNative(btn, g)
	if S.glowNatives[btn] ~= nil then return end
	if S.nativeFailed then S.glowNatives[btn] = false return end
	if InCombatLockdown() then S.glowNativePending = true return end
	local ok = pcall(function()
		loadContainerAddon()
		local w = btn:GetWidth(); if not w or w < 10 then w = 36 end
		local h = btn:GetHeight(); if not h or h < 10 then h = 36 end
		local host = CreateFrame("Frame", nil, g)
		host:SetAllPoints(g)
		host:SetFrameLevel(g:GetFrameLevel() + 1)
		host:SetAlpha(0)
		local container = CreateFrame("AuraContainer", nil, host, "CustomAuraContainerTemplate")
		container:SetUnit("player")
		local c = colour("mwColorGlow")
		local layers = {
			{ "Interface\\Buttons\\UI-ActionButton-Border", w * 2.1, h * 2.1, 1 },
			{ "Interface\\Buttons\\UI-ActionButton-Border", w * 1.8, h * 1.8, 1 },
			{ "Interface\\Buttons\\WHITE8X8", w, h, 0.4 },
		}
		for li, L in ipairs(layers) do
			local slot = container:AddAuraSlot("mwglow" .. li, "HELPFUL", {
				candidateFilters = { includeSpellIDs = NATIVE_IDS },
				initializeFrame = function(frame)
					frame:ClearAllPoints()
					frame:SetSize(L[2], L[3])
					frame:SetPoint("CENTER", g, "CENTER", 0, 0)
					frame:SetFrameLevel(host:GetFrameLevel() + 1)
					pcall(frame.SetMouseClickEnabled, frame, false)
					pcall(frame.EnableMouseMotion, frame, false)
					local sb = CreateFrame("StatusBar", nil, frame)
					sb:SetAllPoints(frame)
					sb:SetStatusBarTexture(L[1])
					local t = sb:GetStatusBarTexture()
					if t and t.SetBlendMode then t:SetBlendMode("ADD") end
					sb:SetAlpha(L[4])
					sb:SetStatusBarColor(c[1], c[2], c[3], 1)
					frame:SetApplicationBar(sb, { minApplications = MAX, maxApplications = MAX })
				end,
			})
			if not slot then error("glow slot unavailable") end
		end
		S.glowNatives[btn] = host
	end)
	if not ok then S.glowNatives[btn] = false end
end

local function recolorGlows()
	local c = colour("mwColorGlow")
	for btn in pairs(S.glowActive) do
		local g = S.glowFrames[btn]
		g.border:SetStatusBarColor(c[1], c[2], c[3])
		g.border2:SetStatusBarColor(c[1], c[2], c[3])
		g.fill:SetStatusBarColor(c[1], c[2], c[3])
	end
end

local function refreshGlow(stacks)
	-- the glows stay on the buttons while the option is on; the StatusBar value (4..5) is what shows them at 5 stacks.
	-- In a fight the game's own copy shows, ours stay empty
	local want = db.mwOn and db.mwGlow and true or false
	if want ~= S.lastWant or S.glowDirty then
		S.lastWant, S.glowDirty = want, false
		S.glowPaintedV = nil
		hideGlows()
		clearGlowNatives()
		if want then
			local c = colour("mwColorGlow")
			for _, btn in ipairs(collectGlowButtons()) do
				local g = glowFrameFor(btn)
				g.border:SetStatusBarColor(c[1], c[2], c[3])
				g.border2:SetStatusBarColor(c[1], c[2], c[3])
				g.fill:SetStatusBarColor(c[1], c[2], c[3])
				g:Show()
				g.ag:Play()
				S.glowActive[btn] = true
				attachGlowNative(btn, g)
			end
		end
	end
	-- only write when something is different: a secret value is always written (it can't be compared)
	local combat = fight() and true or false
	local plain = not isSecret(stacks)
	if plain and S.glowPaintedV == stacks and S.glowPaintedFight == combat then return end
	S.glowPaintedV, S.glowPaintedFight = plain and stacks or nil, combat
	for btn in pairs(S.glowActive) do
		local g = S.glowFrames[btn]
		local host = S.glowNatives[btn]
		if host then host:SetAlpha(combat and 1 or 0) end
		g.border:SetValue(stacks)
		g.border2:SetValue(stacks)
		g.fill:SetValue(stacks)
	end
end

-- ---------------------------------------------------------------- update

local function sampleOn() return ns.optionsOpen == true and not InCombatLockdown() end

-- the squares' border and background (ours): hidden in a fight in "only with stacks" mode, so an empty bar is invisible
local function setChrome(on)
	if S.chrome == on then return end
	S.chrome = on
	for i = 1, MAX do
		S.squares[i].border:SetAlpha(on and 1 or 0)
		S.squares[i].bg:SetAlpha(on and 1 or 0)
	end
end

-- one pass: read, show or hide the bar, paint it. Runs ~20 times a second while the module is on.
local function update()
	local stacks = getStacks()
	local inFight = fight()
	local secret = isSecret(stacks)

	refreshGlow(stacks)

	-- a settings page or Move mode is open: show the bar even when empty, with 3 sample stacks (a real reading wins)
	local sample = false
	if sampleOn() and not secret and stacks == 0 then sample = true end
	local only = db.mwOnlyStacks and not db.mwAlways
	local native = S.layer and inFight and not S.test and not ns.moveMode
	-- "only with stacks": in a fight nothing can be read, but the game's own bars are empty without the buff, so the
	-- bar stays up with its frames and background hidden (setChrome) and only the game's filled squares show
	local shown = sample or db.mwAlways or (inFight and not only) or secret or stacks > 0 or (only and native and true) or false
	if not shown then
		if bar:IsShown() then bar:Hide() end
		setChrome(true)
		return
	end
	if not bar:IsShown() then bar:Show() end
	local v = sample and 3 or stacks
	setChrome(not (only and native))

	-- the count: a secret value can't become text; in a fight the game writes its own
	if db.mwCount then
		if native then
			count:Hide()
		elseif not secret and type(v) == "number" and v > 0 then
			local t = tostring(v)
			if S.countText ~= t then S.countText = t; count:SetText(t) end
			count:Show()
		else
			count:Hide()
		end
	else
		count:Hide()
	end

	if native then
		S.nativeHost:SetAlpha(1)
		if S.ownShown ~= false then
			for i = 1, MAX do S.squares[i].fill:Hide(); S.squares[i].fullFill:Hide() end
			S.ownShown = false
		end
	else
		if S.nativeHost then S.nativeHost:SetAlpha(0) end
		if not secret and S.ownShown == true and S.paintedV == v and not S.dirtyPaint then return end
		local n, f = colour("mwColor"), colour("mwColorFull")
		for i = 1, MAX do
			local sq = S.squares[i]
			if S.ownShown ~= true then sq.fill:Show(); sq.fullFill:Show() end
			if S.dirtyPaint or S.ownShown ~= true then
				sq.fill:SetStatusBarColor(n[1], n[2], n[3], 1)
				sq.fullFill:SetStatusBarColor(f[1], f[2], f[3], 1)
			end
			sq.fill:SetValue(v)
			sq.fullFill:SetValue(v)
		end
		S.ownShown, S.dirtyPaint = true, false
		S.paintedV = (not secret) and v or nil
	end
end
local guardedUpdate = guard("maelstrom", update)

local function shutdown()
	S.off = true
	if bar then bar:Hide() end
	if S.nativeHost then S.nativeHost:SetAlpha(0) end
	hideGlows()
	clearGlowNatives()
	S.lastWant = false
	S.glowDirty = true
	S.ownShown, S.paintedV = nil, nil
	setChrome(true)
end

-- the settings that decide the look, as one string: nothing is written while it has not changed
local function placeSig()
	local w, h, gap = size()
	return table.concat({ tostring(db.mwPoint), tostring(db.mwRelPoint), tostring(db.mwX), tostring(db.mwY), scale(), w, h, gap,
		countPos(), tostring(db.mwCountX), tostring(db.mwCountY) }, "|")
end
local function colourSig(...)
	local out = {}
	for _, key in ipairs({ ... }) do local c = colour(key); out[#out + 1] = c[1] .. "," .. c[2] .. "," .. c[3] end
	return table.concat(out, "|")
end

-- called from ns.updatePreview() (after every settings change) and on the module's own events
function ns.mwApply()
	if not (db and S.built and S.active) then return end
	if not db.mwOn then
		if not S.off then shutdown() end
		return
	end
	S.off = false
	local ps = placeSig()
	if ps ~= S.placeSig then
		S.placeSig = ps
		applyPlace(); applySize(); applyCountPos()
	end
	local bs = colourSig("mwColorBg")
	if bs ~= S.bgSig then S.bgSig = bs; applyBg() end
	local cs = colourSig("mwColor", "mwColorFull")
	if cs ~= S.colourSig then S.colourSig = cs; S.dirtyPaint = true end
	-- what the game-drawn copy was built from: a change means a rebuild, once the changes stop
	local w, h, gap = size()
	local ns_ = table.concat({ w, h, gap, cs, tostring(db.mwCount and true or false), countAnchor() }, "|")
	if ns_ ~= S.nativeSig then
		local first = S.nativeSig == nil
		S.nativeSig = ns_
		if not first then scheduleNative() end
	end
	local gs = colourSig("mwColorGlow")
	if gs ~= S.glowSig then
		local first = S.glowSig == nil
		S.glowSig = gs
		if not first then recolorGlows(); scheduleNative() end
	end
	local spellSig = tostring(db.mwGlowSpell) .. "|" .. tostring(db.mwFrames and #db.mwFrames)
	if spellSig ~= S.spellSig then S.spellSig = spellSig; buildGlowTargets(); S.glowDirty = true end
	if not S.layer and not S.nativeFailed and not InCombatLockdown() then buildNative() end
	update()
end
local guardedApply = guard("maelstrom apply", ns.mwApply)
ns.mwApply = guardedApply

-- ---------------------------------------------------------------- error log (option)

local MAX_ERRORS = 50
local function installErrorLog()
	if S.errHooked or not (seterrorhandler and geterrorhandler) then return end
	S.errHooked = true
	local prev = geterrorhandler()
	seterrorhandler(function(msg)
		if db and db.mwErrorLog then
			pcall(function()
				local m = tostring(msg)
				local list = ShamanKitLogDB and ShamanKitLogDB.errors
				if type(ShamanKitLogDB) ~= "table" then return end
				if type(list) ~= "table" then list = {}; ShamanKitLogDB.errors = list end
				local last = list[#list]
				if last and last.msg == m then
					last.count = (last.count or 1) + 1
					last.t = time()
				else
					list[#list + 1] = { t = time(), msg = m, stack = debugstack and debugstack(2) or "", count = 1 }
					if #list > MAX_ERRORS then table.remove(list, 1) end
				end
			end)
		end
		if type(prev) == "function" then return prev(msg) end
	end)
end

-- ---------------------------------------------------------------- test stacks

function ns.mwTest(n)
	n = tonumber(n)
	if n and n >= 1 and n <= MAX then
		S.test = math.floor(n)
		-- fake stacks look like real ones: they end by themselves
		local token = {}
		S.testToken = token
		if C_Timer and C_Timer.After then
			C_Timer.After(20, function() if S.testToken == token and S.test then S.test = nil; S.testToken = nil; guardedUpdate() end end)
		end
	else
		S.test, S.testToken = nil, nil
	end
	if db and S.built and db.mwOn then guardedUpdate() end
	return S.test
end

-- ---------------------------------------------------------------- positions

function ns.mwResetPosition()
	if not db then return end
	db.mwPoint, db.mwRelPoint, db.mwX, db.mwY = D.mwPoint, D.mwRelPoint, D.mwX, D.mwY
	ns.mwApply()
end

function ns.mwResetSize()
	if not db then return end
	db.mwW, db.mwH, db.mwGap, db.mwScale = D.mwW, D.mwH, D.mwGap, D.mwScale
	ns.mwApply()
end

-- Move mode (Move.lua): the bar, and the count (its distance from the bar is what is saved)
ns.moveProviders[#ns.moveProviders + 1] = function()
	if not (db and S.built) then return {} end
	local list = {
		{ id = "maelstrom", label = "Maelstrom bar", frame = bar, on = function() return db.mwOn and bar:IsShown() end,
			drop = function(cx, cy)
				db.mwPoint, db.mwRelPoint, db.mwX, db.mwY = "CENTER", "CENTER", cx, cy
				ns.mwApply()
			end },
		{ id = "maelstrom_count", label = "Maelstrom count", on = function() return db.mwOn and db.mwCount and count:IsShown() end,
			rect = function()
				local ok, l, b, w, h = pcall(count.GetRect, count)
				if not (ok and type(l) == "number") then return nil end
				local k = (count.GetEffectiveScale and count:GetEffectiveScale() or 1) / (UIParent:GetEffectiveScale() or 1)
				return l * k, b * k, w * k, h * k
			end,
			drop = function(cx, cy, w, h)
				-- the piece's middle (from the screen middle) back to an offset from where the count is anchored
				local ux, uy = UIParent:GetCenter()
				local bl, bb = bar:GetLeft(), bar:GetBottom()
				local bw, bh = bar:GetSize()
				local k = (bar.GetEffectiveScale and bar:GetEffectiveScale() or 1) / (UIParent:GetEffectiveScale() or 1)
				if not (ux and bl and bb and bw and bh) then return end
				bl, bb, bw, bh = bl * k, bb * k, bw * k, bh * k
				local s = scale()
				local mx, my = cx + ux, cy + uy                    -- the count's middle in UIParent units
				local pos = countPos()
				local x, y = (mx - (bl + bw / 2)) / s, 0
				if pos == "center" then y = (my - (bb + bh / 2)) / s
				elseif pos == "bottom" then y = (my + (h or 0) / 2 - bb) / s + 4
				else y = (my - (h or 0) / 2 - (bb + bh)) / s - 4 end
				db.mwCountX = math.floor(num(x, -200, 200, 0) + 0.5)
				db.mwCountY = math.floor(num(y, -100, 100, 0) + 0.5)
				ns.mwApply()
			end },
	}
	return list
end

-- ---------------------------------------------------------------- status

-- "ready" (the game draws the stacks in a fight), "pending" (built when out of combat), "unavailable"
function ns.mwCombatState()
	if S.layer then return "ready" end
	if S.nativeFailed then return "unavailable" end
	return "pending"
end

function ns.mwInfo()
	local out = {}
	if not db then return out end
	if S.conflict then out[#out + 1] = "OFF: the separate MaelstromBar addon is still installed" return out end
	if not S.active then out[#out + 1] = "off (not a shaman)" return out end
	out[#out + 1] = db.mwOn and "on" or "off"
	local st = ns.mwCombatState()
	out[#out + 1] = st == "ready" and "in a fight the game draws the stacks (built)"
		or st == "unavailable" and "this client does not let the addon draw the stacks in a fight"
		or "the fight display is built out of combat; it will be ready for the next fight"
	local n = 0
	for _ in pairs(S.glowActive) do n = n + 1 end
	out[#out + 1] = ("glow: %s, %d button%s"):format(db.mwGlow and "on" or "off", n, n == 1 and "" or "s")
	return out
end

-- ---------------------------------------------------------------- start

local EVENTS = { "PLAYER_ENTERING_WORLD", "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED", "ACTIONBAR_SLOT_CHANGED",
	"ACTIONBAR_PAGE_CHANGED", "UPDATE_BONUS_ACTIONBAR" }
ns.MW_EVENTS = EVENTS

local ef, ticker
local function onEvent(_, event)
	if not (db and db.mwOn and S.active) then return end
	if event == "PLAYER_REGEN_ENABLED" then
		if S.nativeDirty then rebuildNative() end
		if S.glowNativePending then S.glowNativePending = false; S.glowDirty = true end
	end
	S.glowDirty = true                      -- the action bars may have changed: look at the buttons again
	update()
end

local function localName()
	local n
	if C_Spell and C_Spell.GetSpellName then
		local ok, v = pcall(C_Spell.GetSpellName, 408505)
		if ok and type(v) == "string" and not isSecret(v) then n = v end
	elseif GetSpellInfo then
		n = GetSpellInfo(408505)
	end
	if n then NAMES[n:lower()] = true end
end

function ns.mwInit()
	db = ns.get()
	local class
	if UnitClass then class = select(2, UnitClass("player")) end
	S.conflict = (C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded("MaelstromBar")) and true or false
	S.active = (class == nil or class == "SHAMAN") and not S.conflict
	if S.conflict then
		print("|cff33ff99ShamanKit|r: the separate MaelstromBar addon is still installed, so ShamanKit's Maelstrom bar stays off (two bars would show). Remove MaelstromBar (its folder, or wowupd remove) and /reload.")
		dbg("MAELSTROM: MaelstromBar is loaded, so the Maelstrom module stays off")
	end
	if not S.active then
		if S.built then shutdown() end
		return
	end
	if db.mwErrorLog then installErrorLog() end
	if not S.built then
		localName()
		buildBar()
		S.built = true
		buildGlowTargets()
		ef = CreateFrame("Frame")
		ef:SetScript("OnEvent", guard("maelstrom event", onEvent))
		for _, e in ipairs(EVENTS) do
			local ok, err = pcall(ef.RegisterEvent, ef, e)          -- one at a time: a name this client doesn't know throws
			if not ok then dbg("MAELSTROM: event %s is not known here (%s)", e, short(err)) end
		end
		pcall(ef.RegisterUnitEvent, ef, "UNIT_AURA", "player")
		if C_Timer and C_Timer.NewTicker then ticker = C_Timer.NewTicker(0.05, function() if db and db.mwOn and S.active then guardedUpdate() end end) end
		-- the interface's Edit Mode (clients that have one) shows the same drag frames as Move mode
		if EditModeManagerFrame and EditModeManagerFrame.HookScript then
			pcall(EditModeManagerFrame.HookScript, EditModeManagerFrame, "OnShow", function()
				if db and db.mwOn and ns.moveStart and not ns.moveMode then S.editMove = true; guard("edit mode", ns.moveStart)() end
			end)
			pcall(EditModeManagerFrame.HookScript, EditModeManagerFrame, "OnHide", function()
				if S.editMove and ns.moveStop then S.editMove = false; guard("edit mode", ns.moveStop)() end
			end)
		end
	end
	S.placeSig, S.bgSig, S.colourSig, S.nativeSig, S.glowSig, S.spellSig = nil, nil, nil, nil, nil, nil
	S.dirtyPaint = true
	guardedApply()
end

-- ---------------------------------------------------------------- slash

local function say(m) print(PREFIX .. m) end

local function toggle(key, what)
	db[key] = not db[key]
	ns.updatePreview()
	say(what .. " " .. (db[key] and "on" or "off"))
end

local function setRGB(key, rest, usage)
	local r, g, b = rest:match("([%d%.]+)%s+([%d%.]+)%s+([%d%.]+)")
	r, g, b = tonumber(r), tonumber(g), tonumber(b)
	if r and g and b and r <= 1 and g <= 1 and b <= 1 then
		db[key] = { r, g, b }
		ns.updatePreview()
	else
		say(usage)
	end
end

local HELP = "/shamankit mw  options | move | lock | always | only | color | count | size | scale | glow | glowspell | glowframe | glowscan | test <0-5> | aura <name> | reset | setup | native retry | log | testerror | debug"

-- arg: what follows "/shamankit mw" (or "/mw"), case kept (frame names are case-sensitive)
function ns.mwSlash(arg)
	if not db then return end
	if S.conflict then say("off: the separate MaelstromBar addon is still installed.") return end
	if not S.active then say("only for shamans.") return end
	local cmd, rest = (arg or ""):match("^(%S*)%s*(.-)%s*$")
	cmd = cmd:lower()
	if cmd == "options" or cmd == "config" then
		if ns.openOptions then ns.openOptions("mw") end
	elseif cmd == "on" or cmd == "off" then
		db.mwOn = cmd == "on"
		ns.updatePreview()
		say(db.mwOn and "on" or "off")
	elseif cmd == "move" or cmd == "unlock" then
		if ns.moveMode then ns.moveStop() else ns.moveStart() end
	elseif cmd == "lock" then
		if ns.moveStop then ns.moveStop() end
		say("locked")
	elseif cmd == "always" then
		toggle("mwAlways", "always show")
	elseif cmd == "only" then
		toggle("mwOnlyStacks", "only with stacks")
	elseif cmd == "color" or cmd == "couleur" then
		local first = rest:match("^(%a+)")
		local usage = "/shamankit mw color [full|bg|glow] <r> <g> <b>  (values from 0 to 1)"
		if first == "full" then setRGB("mwColorFull", rest:gsub("^full%s*", ""), usage)
		elseif first == "bg" or first == "fond" then setRGB("mwColorBg", rest:gsub("^%a+%s*", ""), usage)
		elseif first == "glow" or first == "halo" then setRGB("mwColorGlow", rest:gsub("^%a+%s*", ""), usage)
		else setRGB("mwColor", rest, usage) end
	elseif cmd == "count" or cmd == "compteur" then
		local what, more = rest:match("^(%S*)%s*(.-)$")
		what = what:lower()
		if what == "pos" or what == "position" then
			local p = more:match("^(%S+)")
			p = p and p:lower()
			local pos
			if p == "center" or p == "centre" then pos = "center"
			elseif p == "below" or p == "dessous" or p == "bottom" then pos = "bottom"
			elseif p == "above" or p == "dessus" or p == "au-dessus" or p == "top" then pos = "top" end
			if pos then db.mwCountPos = pos; ns.updatePreview(); say("count position: " .. pos)
			else say("count position: above, center or below (/shamankit mw count pos ...)") end
		elseif what == "offset" or what == "decalage" then
			local x, y = more:match("^([-%d]+)%s+([-%d]+)")
			x, y = tonumber(x), tonumber(y)
			if x and y and math.abs(x) <= 200 and math.abs(y) <= 100 then
				db.mwCountX, db.mwCountY = x, y
				ns.updatePreview()
				say("count offset: " .. x .. ", " .. y)
			else
				say("count offset: /shamankit mw count offset x y (pixels)")
			end
		else
			toggle("mwCount", "count")
		end
	elseif cmd == "size" or cmd == "taille" then
		local w, h, g = rest:match("(%d+)%s+(%d+)%s*(%d*)")
		w, h, g = tonumber(w), tonumber(h), tonumber(g)
		if w and h and w >= 10 and w <= 80 and h >= 6 and h <= 60 then
			db.mwW, db.mwH = w, h
			if g and g >= 0 and g <= 30 then db.mwGap = g end
			ns.updatePreview()
			local cw, ch, cg = size()
			say(("size: %d x %d, spacing %d"):format(cw, ch, cg))
		else
			say("/shamankit mw size <width> <height> [spacing]  (10-80, 6-60, 0-30)")
		end
	elseif cmd == "scale" then
		local s = tonumber(rest)
		if s and s >= 0.5 and s <= 3 then
			db.mwScale = math.floor(s * 100 + 0.5)
			ns.updatePreview()
		else
			say("/shamankit mw scale <0.5-3>")
		end
	elseif cmd == "glow" then
		toggle("mwGlow", "glow")
	elseif cmd == "glowspell" then
		db.mwGlowSpell = (rest ~= "") and rest or nil
		ns.updatePreview()
		say("glow on " .. (db.mwGlowSpell or "Lightning Bolt (default)"))
	elseif cmd == "glowframe" then
		local list = {}
		for _, n in ipairs(type(db.mwFrames) == "table" and db.mwFrames or {}) do list[#list + 1] = n end
		if rest == "" then
			say("highlighted frames: " .. (#list > 0 and table.concat(list, ", ") or "none"))
		elseif rest:lower() == "clear" then
			db.mwFrames = nil
			S.glowDirty = true
			ns.updatePreview()
			say("frames cleared")
		else
			local found
			for i, n in ipairs(list) do if n == rest then table.remove(list, i); found = true; break end end
			if not found then
				list[#list + 1] = rest
				if not _G[rest] then say(("warning: frame '%s' does not exist (yet)"):format(rest)) end
			end
			db.mwFrames = #list > 0 and list or nil     -- a new table each time: a shared one would be edited in place
			S.glowDirty = true
			ns.updatePreview()
			say((found and "frame %s removed" or "frame %s added"):format(rest))
		end
	elseif cmd == "glowscan" then
		local list = collectGlowButtons()
		if #list == 0 then
			say("no button found for the glow; hover the button and use /fstack, then /shamankit mw glowframe <FrameName>")
		else
			say(("%d button(s) found for the glow:"):format(#list))
			for _, btn in ipairs(list) do
				local ok, name = pcall(btn.GetName, btn)
				print("  " .. ((ok and name) or tostring(btn)))
			end
		end
	elseif cmd == "test" then
		local n = ns.mwTest(rest)
		say("test " .. (n or "off"))
	elseif cmd == "aura" and rest ~= "" then
		db.mwAura = rest
		say("aura name = " .. rest)
		ns.updatePreview()
	elseif cmd == "reset" then
		ns.mwResetPosition(); ns.mwResetSize()
		say("position and size reset")
	elseif cmd == "setup" or cmd == "status" then
		for _, line in ipairs(ns.mwInfo()) do say(line) end
	elseif cmd == "native" then
		if rest:lower() == "retry" or rest:lower() == "reessayer" then
			S.nativeFailed = nil
			if InCombatLockdown() then S.nativeDirty = true; say("will be rebuilt when the fight is over") else rebuildNative() end
		end
		if S.layer then
			say(("game-drawn display: built (%d bars)"):format(#S.layer.fills))
			for _, f in ipairs(S.layer.fills) do
				local s = f.bar
				local okS, sh = pcall(s.IsShown, s)
				local okV, v = pcall(s.GetValue, s)
				if okV and isSecret(v) then v = "<secret>" end
				local okM, mn, mx = pcall(s.GetMinMaxValues, s)
				print("  " .. f.label .. " : visible=" .. ((okS and tostring(sh)) or "error") .. " | value=" .. ((okV and tostring(v)) or "error")
					.. " | minmax=" .. ((okM and (tostring(mn) .. ".." .. tostring(mx))) or "error"))
			end
		elseif S.nativeFailed then say("game-drawn display: unavailable on this client, /shamankit mw native retry to try again")
		elseif InCombatLockdown() then say("game-drawn display: not built, in a fight (it is built out of combat)")
		else say("game-drawn display: not built") end
	elseif cmd == "log" then
		local logdb = type(ShamanKitLogDB) == "table" and ShamanKitLogDB or {}
		local list = logdb.errors
		if rest:lower() == "clear" then
			logdb.errors = {}
			say("log cleared")
		elseif type(list) ~= "table" or #list == 0 then
			say("no Lua errors recorded" .. (db.mwErrorLog and "" or " (the recorder is off: tick \"Record Lua errors\" on the Maelstrom page)"))
		else
			say(("%d Lua error(s) recorded, most recent first (/shamankit mw log clear to wipe)"):format(#list))
			for i = #list, 1, -1 do
				local e = list[i]
				print(("#%d x%d  %s  %s"):format(i, e.count or 1, date and date("%Y-%m-%d %H:%M:%S", e.t or 0) or tostring(e.t), tostring(e.msg or "?")))
				if type(e.stack) == "string" and e.stack ~= "" then for line in e.stack:gmatch("[^\n]+") do print("  " .. line) end end
			end
		end
	elseif cmd == "testerror" then
		error("ShamanKit Maelstrom: test error, it should show up in /shamankit mw log")
	elseif cmd == "debug" then
		say("active buffs (index, name, stacks, id)")
		local n = 0
		if InCombatLockdown() or ns.aurasHidden() then
			say("the game hides buffs in a fight; try again out of combat")
		elseif C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
			for i = 1, 40 do
				local ok, a = pcall(C_UnitAuras.GetAuraDataByIndex, "player", i, "HELPFUL")
				if not (ok and a) then break end
				n = n + 1
				print(i, tostring(a.name), tostring(a.applications), tostring(a.spellId))
			end
			say("buffs: " .. n)
		end
	else
		say(HELP)
	end
end

-- the standalone addon's commands, when it is not around to answer them
if not (C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded("MaelstromBar")) then
	SLASH_SHAMANKITMW1 = "/mw"
	SLASH_SHAMANKITMW2 = "/maelstrombar"
	SlashCmdList.SHAMANKITMW = function(msg) ns.mwSlash(msg) end
end

-- the recorder is switched on from the settings page too
function ns.mwErrorLogChanged()
	if db and db.mwErrorLog and S.active then installErrorLog() end
end
