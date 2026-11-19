-- ShamanKit settings: the Cures page (Esc > Options > AddOns > ShamanKit > Cures).
-- Built by Options.lua's ns.buildOptions(), which hands over its helpers; kept in its own file because the Cures module is
-- its own piece of the addon.

local ADDON, ns = ...

function ns.buildCuresPage(ui)
	local newPage, checkbox, slider, header, note, enable = ui.newPage, ui.checkbox, ui.slider, ui.header, ui.note, ui.enable
	local LEFT, RIGHT, COLW = ui.LEFT, ui.RIGHT, ui.COLW

	local page = newPage("Cures", "Cures",
		"Your cure spells light up, in the colour of what is on you, while a debuff they can remove is on you. Works in a fight too.",
		{ "cureOn", "cureBars", "cureRow", "cureAlways", "cureSize", "cureSpacing", "cureWash", "cureWashAlpha", "curePulse", "cureCount", "cureClick" })
	local p = page.panel

	-- ---- left column: what and where
	header(p, "Cure spells", LEFT, -88, COLW)
	local on = page.add(checkbox(p, "Light up my cure spells", "cureOn", LEFT, -114))
	local blurb = note(p, "Cure Disease (tan), Cure Poison (green) and, for an Orc, Shatter Curse (purple).", LEFT + 28, -142)

	header(p, "Where", LEFT, -196, COLW)
	local bars = page.add(checkbox(p, "On my action bar buttons", "cureBars", LEFT, -222))
	local row = page.add(checkbox(p, "In a small icon row", "cureRow", LEFT, -248))
	local always = page.add(checkbox(p, "Keep the row on screen when nothing is on me", "cureAlways", LEFT, -274))
	local click = page.add(checkbox(p, "Click a lit icon to cure myself", "cureClick", LEFT, -300))
	local clickNote = note(p, "Casts that cure on you, in a fight too.", LEFT + 28, -328)

	header(p, "Position of the row", LEFT, -372, COLW)
	local unlock = page.add(checkbox(p, "Unlock the frames (the row shows here so you can drag it)", "locked", LEFT, -398,
		function() return ns.get().locked == false end,
		function(v) ns.get().locked = not v end))
	note(p, "The same lock as the totem bar's.", LEFT + 28, -426)
	local reset = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
	reset:SetSize(150, 24)
	reset:SetPoint("TOPLEFT", LEFT, -452)
	reset:SetText("Reset position")
	reset:SetScript("OnClick", function() ns.cureResetPosition() end)

	header(p, "What it found", LEFT, -494, COLW)
	local found = note(p, "", LEFT, -520)
	found:SetWidth(COLW)

	-- ---- right column: the look, and a test
	header(p, "Look", RIGHT, -88, COLW)
	local size = page.add(slider(p, "Row icon size", "cureSize", 24, 80, RIGHT, -114))
	local spacing = page.add(slider(p, "Row spacing", "cureSpacing", 0, 24, RIGHT, -169))
	local wash = page.add(checkbox(p, "Wash the icon in the colour", "cureWash", RIGHT, -224))
	local washAlpha = page.add(slider(p, "Wash strength", "cureWashAlpha", 5, 80, RIGHT + 24, -252,
		function(v) return v .. "%" end, 5))
	local pulse = page.add(checkbox(p, "Pulse the border", "curePulse", RIGHT, -307))
	local count = page.add(checkbox(p, "Show a number when there are several", "cureCount", RIGHT, -333))

	header(p, "Test", RIGHT, -380, COLW)
	local function testButton(label, key, x, y)
		local b = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
		b:SetSize(86, 24)
		b:SetPoint("TOPLEFT", x, y)
		b:SetText(label)
		b:SetScript("OnClick", function() ns.cureTest(key) end)
		b.testKey = key
		return b
	end
	testButton("Poison", "poison", RIGHT, -406)
	testButton("Disease", "disease", RIGHT + 92, -406)
	testButton("Curse", "curse", RIGHT + 184, -406)
	testButton("All", "all", RIGHT, -438)
	testButton("Clear", "clear", RIGHT + 92, -438)
	note(p, "Lights them for a few seconds (out of combat), so you can see where and how.\nWhile this page is open they show anyway when nothing is on you.", RIGHT, -470)

	-- what depends on what
	local function dependents()
		local d = ns.get()
		local rowOn = d.cureRow and true or false
		enable(always, rowOn); enable(size, rowOn); enable(spacing, rowOn); enable(count, rowOn)
		enable(unlock, rowOn)
		enable(click, rowOn and d.locked ~= false)  -- (while this window is up, unlocked means moving)
		clickNote:SetText(d.locked == false and "The frames are unlocked, so clicking is off while this window is open."
			or "Casts that cure on you, in a fight too.")
		enable(washAlpha, d.cureWash and true or false)
		local state = ns.cureState
		if state and state.conflict then
			blurb:SetText("|cffff8080The separate CureWatch addon is still installed, so this stays off. Remove CureWatch and /reload.|r")
		else
			blurb:SetText("Cure Disease (tan), Cure Poison (green) and, for an Orc, Shatter Curse (purple).")
		end
		found:SetText(table.concat(ns.cureInfo and ns.cureInfo() or {}, "\n"))
	end
	for _, c in ipairs({ row, wash, on, bars, unlock }) do c:HookScript("OnClick", dependents) end
	page.after[#page.after + 1] = dependents

	-- the preview is only while THIS page is open
	p:HookScript("OnShow", function() ns.curesPageOpen = true; if ns.cureApply then ns.cureApply() end; dependents() end)
	p:HookScript("OnHide", function() ns.curesPageOpen = false; if ns.cureApply then ns.cureApply() end end)

	page.onDefault = function() if ns.cureApply then ns.cureApply() end end
	return page
end
