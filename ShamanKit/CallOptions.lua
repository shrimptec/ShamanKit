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
			"callPoint", "callRelPoint", "callX", "callY", "callChoice", unpack(ns.CALL_POS_KEYS) })
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

	-- advanced, left: dragging by hand
	page.adv(header(p, "Moving", LEFT, -398, COLW))
	local unlock = page.adv(page.add(checkbox(p, "Unlock to drag the buttons", "locked", LEFT, -422,
		function() return ns.get().locked == false end,
		function(on) ns.get().locked = not on end)))
	page.adv(note(p, "Only for \"Own place\"; it unlocks the totem bar too.\nDrag while this page is open, or use the sliders.\nWhile unlocked, a click on them does not cast.", LEFT + 28, -450))
	local reset = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
	reset:SetSize(170, 24)
	reset:SetPoint("TOPLEFT", LEFT, -510)
	reset:SetText("Reset button position")
	reset:SetScript("OnClick", function() ns.callResetPlace(ns.callTarget ~= "all" and ns.callTarget or nil); page.refresh() end)
	page.adv(reset)

	-- ---- right column: where they sit. One set of controls, for whichever you pick: all the buttons together, or one
	-- button placed on its own (ns.callTarget is only what this page is showing, it is not saved)
	local KIND = { all = "call", call = "posCall", totemic = "posTotemic", recall = "posRecall" }
	ns.callTarget = ns.callTarget or "all"
	local function pfx() return KIND[ns.callTarget] or "call" end
	local function kindOf() return ns.callTarget ~= "all" and ns.callTarget or nil end
	local function get(f) return ns.get()[pfx() .. f] end
	local function set(f, v) ns.get()[pfx() .. f] = v end

	header(p, "Position", RIGHT, -78, COLW)
	note(p, "Press Move on screen (top right) to drag the buttons\nwhere you want them. For exact choices, per button,\nuse Show advanced.", RIGHT, -102)

	-- advanced: pick a button (or all together), then its side, place along it and nudge, or its own spot on the screen
	local targetLabel = p:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	targetLabel:SetPoint("TOPLEFT", RIGHT, -152)
	targetLabel:SetText("Set the position of:")
	page.adv(targetLabel)
	local ownBox = checkbox(p, "Place this button on its own", "posCallOwn", RIGHT, -222,
		function() local k = kindOf(); return k ~= nil and ns.get()[KIND[k] .. "Own"] == true end,
		function(on) local k = kindOf(); if k then ns.get()[KIND[k] .. "Own"] = on end end)
	page.add(ownBox)
	page.adv(ownBox, function() return ns.callTarget ~= "all" end)

	local anchorLabel = p:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	anchorLabel:SetPoint("TOPLEFT", RIGHT, -254)
	anchorLabel:SetText("Attach to:")
	page.adv(anchorLabel)
	local anchor = radioGroup(p, {
		{ "bar", "Totem bar" }, { "free", "Own place" },
	}, RIGHT, -272, 2, 130, 24,
		function() return get("Anchor") == "free" and "free" or "bar" end,
		function(v) set("Anchor", v) end)
	page.add(anchor)
	page.adv(anchor)
	local sideLabel = p:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	sideLabel:SetPoint("TOPLEFT", RIGHT, -302)
	sideLabel:SetText("Side of it:")
	page.adv(sideLabel)
	local side = radioGroup(p, {
		{ "start", "Auto" }, { "bottom", "Below" }, { "top", "Above" }, { "left", "Left" }, { "right", "Right" },
	}, RIGHT, -320, 3, 76, 24,
		function()
			local sd = get("Side")
			if sd == "bottom" or sd == "top" or sd == "left" or sd == "right" then return sd end
			if sd == "end" then return ns.get().vertical and "bottom" or "right" end
			return "start"
		end,
		function(v) set("Side", v) end)
	page.add(side)
	page.adv(side)
	local alignLabel = p:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	alignLabel:SetPoint("TOPLEFT", RIGHT, -378)
	alignLabel:SetText("Along that side:")
	page.adv(alignLabel)
	local align = radioGroup(p, {
		{ "start", "Start" }, { "center", "Middle" }, { "end", "End" },
	}, RIGHT, -396, 3, 76, 24,
		function() local a = get("Align"); return (a == "center" or a == "end") and a or "start" end,
		function(v) set("Align", v) end)
	page.add(align)
	page.adv(align)
	-- the nudges (attached) and the screen position (own place) share the same spot: only the one that applies shows
	local nudgeX = page.add(slider(p, "Nudge left / right", function() return pfx() .. "OffX" end, -100, 100, RIGHT, -428))
	local nudgeY = page.add(slider(p, "Nudge up / down", function() return pfx() .. "OffY" end, -100, 100, RIGHT, -481))
	local ownX = page.add(slider(p, "Screen position left / right", function() return pfx() .. "X" end, -1000, 1000, RIGHT, -428, nil, 5))
	local ownY = page.add(slider(p, "Screen position up / down", function() return pfx() .. "Y" end, -600, 600, RIGHT, -481, nil, 5))
	local attachedNow = function() return get("Anchor") ~= "free" end
	local freeNow = function() return get("Anchor") == "free" end
	page.adv(nudgeX, attachedNow); page.adv(nudgeY, attachedNow)
	page.adv(ownX, freeNow); page.adv(ownY, freeNow)
	local sideNote = note(p, "", RIGHT, -538)
	page.adv(sideNote)

	-- the picker comes last so the controls above keep their order
	local target = radioGroup(p, {
		{ "all", "All together" }, { "call", "Call of the ..." }, { "totemic", "Totemic Call" }, { "recall", "Totemic Recall" },
	}, RIGHT, -170, 2, 130, 24,
		function() return ns.callTarget end,
		function(v) ns.callTarget = v end)
	page.add(target)
	page.adv(target)

	local function dependents()
		local d = ns.get()
		local own = ns.callTarget == "all" or ownBox:GetChecked()
		local attached = get("Anchor") ~= "free"
		enable(ownBox, ns.callTarget ~= "all")
		for _, g in ipairs({ anchor, side, align }) do for _, rb in ipairs(g.rbs) do enable(rb, own) end end
		for _, g in ipairs({ side, align }) do for _, rb in ipairs(g.rbs) do enable(rb, own and attached) end end
		for _, sl in ipairs({ nudgeX, nudgeY, ownX, ownY }) do enable(sl, own) end
		enable(unlock, own and not attached)
		local st = ns.callState
		local moved = st and (ns.callTarget == "all" and st.sideMoved or (st.ownMoved and st.ownMoved[ns.callTarget]))
		if own and attached and moved then
			sideNote:SetText("The buff icons are on that side, so the button(s)\nsit on the opposite one.")
		elseif not own then
			sideNote:SetText("This button sits with the others. Tick the box\nabove to give it a position of its own.")
		else
			sideNote:SetText("")
		end
		page.applyAdvanced()
	end
	local function everything() page.refresh() end
	for _, c in ipairs({ call, totemic, recall, ownBox }) do c:HookScript("OnClick", dependents) end
	for _, g in ipairs({ anchor, side, align, show }) do for _, rb in ipairs(g.rbs) do rb:HookScript("OnClick", dependents) end end
	for _, rb in ipairs(target.rbs) do rb:HookScript("OnClick", everything) end
	page.after[#page.after + 1] = function() dependents() end

	return page
end
