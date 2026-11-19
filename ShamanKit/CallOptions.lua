-- ShamanKit settings: the Call spells page (Esc > Options > AddOns > ShamanKit > Call spells).
-- Built by Options.lua's ns.buildOptions(), which hands over its helpers; its own file because the Calls module is
-- its own piece of the addon (Calls.lua). Laid out like the Buffs page: what shows on the left, where it sits on the right.

local ADDON, ns = ...

function ns.buildCallsPage(ui)
	local newPage, checkbox, slider, header, note, enable, radioGroup = ui.newPage, ui.checkbox, ui.slider, ui.header, ui.note, ui.enable, ui.radioGroup
	local LEFT, RIGHT, COLW = ui.LEFT, ui.RIGHT, ui.COLW

	local page = newPage("Call spells", "Call spells",
		"Buttons for your Call spells, Totemic Call and Totemic Recall, at the totem bar or in a place of their own.",
		{ "callOn", "callTotemic", "callRecall", "callShow", "callScale", "callAnchor", "callSide", "callAlign", "callOffX", "callOffY",
			"callPoint", "callRelPoint", "callX", "callY", "callChoice" })
	local p = page.panel
	page.onDefault = function() if ns.callApply then ns.callApply() end end

	-- ---- left column: what, when, how big
	header(p, "Buttons", LEFT, -78, COLW)
	local call = page.add(checkbox(p, "Call of the ... (Elements, Ancestors, Spirits)", "callOn", LEFT, -102))
	note(p, "Click its small arrow to pick another Call spell.", LEFT + 28, -128)
	local totemic = page.add(checkbox(p, "Totemic Call (brings your totems to you)", "callTotemic", LEFT, -152))
	local recall = page.add(checkbox(p, "Totemic Recall (takes them back)", "callRecall", LEFT, -178))

	header(p, "Show", LEFT, -224, COLW)
	local show = radioGroup(p, {
		{ "always", "All the time" },
		{ "bar", "Only while a totem is out" },
	}, LEFT, -248, 1, 0, 24,
		function() return ns.get().callShow == "bar" and "bar" or "always" end,
		function(v) ns.get().callShow = v end)
	page.add(show)

	header(p, "Size", LEFT, -306, COLW)
	page.add(slider(p, "Button size (% of the totem icons)", "callScale", 50, 150, LEFT, -330, function(v) return v .. "%" end, 5))

	header(p, "Moving", LEFT, -398, COLW)
	local unlock = page.add(checkbox(p, "Unlock to drag the buttons", "locked", LEFT, -422,
		function() return ns.get().locked == false end,
		function(on) ns.get().locked = not on end))
	note(p, "Only for \"Own place\"; it unlocks the totem bar too.\nDrag while this page is open, or use the sliders.\nWhile unlocked, a click on them does not cast.", LEFT + 28, -450)
	local reset = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
	reset:SetSize(170, 24)
	reset:SetPoint("TOPLEFT", LEFT, -510)
	reset:SetText("Reset button position")
	reset:SetScript("OnClick", function() ns.callResetPlace(); page.refresh() end)

	-- ---- right column: where they sit
	header(p, "Position", RIGHT, -78, COLW)
	local anchorLabel = p:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	anchorLabel:SetPoint("TOPLEFT", RIGHT, -102)
	anchorLabel:SetText("Attach to:")
	local anchor = radioGroup(p, {
		{ "bar", "Totem bar" }, { "free", "Own place" },
	}, RIGHT, -120, 2, 130, 24,
		function() return ns.callMode() end,
		function(v) ns.get().callAnchor = v end)
	page.add(anchor)
	local sideLabel = p:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	sideLabel:SetPoint("TOPLEFT", RIGHT, -150)
	sideLabel:SetText("Side of it:")
	local side = radioGroup(p, {
		{ "start", "Auto" }, { "bottom", "Below" }, { "top", "Above" }, { "left", "Left" }, { "right", "Right" },
	}, RIGHT, -168, 3, 76, 24,
		function()
			local sd = ns.get().callSide
			if sd == "bottom" or sd == "top" or sd == "left" or sd == "right" then return sd end
			if sd == "end" then return ns.get().vertical and "bottom" or "right" end
			return "start"
		end,
		function(v) ns.get().callSide = v end)
	page.add(side)
	local alignLabel = p:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	alignLabel:SetPoint("TOPLEFT", RIGHT, -220)
	alignLabel:SetText("Along that side:")
	local align = radioGroup(p, {
		{ "start", "Start" }, { "center", "Middle" }, { "end", "End" },
	}, RIGHT, -238, 3, 76, 24,
		function() local a = ns.get().callAlign; return (a == "center" or a == "end") and a or "start" end,
		function(v) ns.get().callAlign = v end)
	page.add(align)
	local nudgeX = page.add(slider(p, "Nudge left / right", "callOffX", -100, 100, RIGHT, -270))
	local nudgeY = page.add(slider(p, "Nudge up / down", "callOffY", -100, 100, RIGHT, -323))

	header(p, "Own place", RIGHT, -374, COLW)
	local ownX = page.add(slider(p, "Screen position left / right", "callX", -1000, 1000, RIGHT, -400, nil, 5))
	local ownY = page.add(slider(p, "Screen position up / down", "callY", -600, 600, RIGHT, -453, nil, 5))
	local sideNote = note(p, "", RIGHT, -506)

	local function dependents()
		local d = ns.get()
		local attached = ns.callMode() == "bar"
		for _, g in ipairs({ side, align }) do for _, rb in ipairs(g.rbs) do enable(rb, attached) end end
		enable(nudgeX, attached); enable(nudgeY, attached)
		enable(ownX, not attached); enable(ownY, not attached)
		enable(unlock, not attached)
		local st = ns.callState
		if attached and st and st.sideMoved then
			sideNote:SetText("The buff icons are on that side, so the buttons\nsit on the opposite one.")
		else
			sideNote:SetText("")
		end
	end
	for _, c in ipairs({ call, totemic, recall }) do c:HookScript("OnClick", dependents) end
	for _, g in ipairs({ anchor, side, align, show }) do for _, rb in ipairs(g.rbs) do rb:HookScript("OnClick", dependents) end end
	page.after[#page.after + 1] = function() show.refresh(); anchor.refresh(); side.refresh(); align.refresh(); dependents() end

	return page
end
