-- ShamanKit settings: the Call spells page (Esc > Options > AddOns > ShamanKit > Call spells).
-- Built by Options.lua's ns.buildOptions(), which hands over its helpers; its own file because the Calls module is
-- its own piece of the addon (Calls.lua).

local ADDON, ns = ...

function ns.buildCallsPage(ui)
	local newPage, checkbox, header, note, enable, radioGroup = ui.newPage, ui.checkbox, ui.header, ui.note, ui.enable, ui.radioGroup
	local LEFT, RIGHT, COLW = ui.LEFT, ui.RIGHT, ui.COLW

	local page = newPage("Call spells", "Call spells",
		"Buttons next to the totem bar for your Call spells, Totemic Call and Totemic Recall.",
		{ "callOn", "callTotemic", "callRecall", "callSide", "callChoice" })
	local p = page.panel

	-- ---- left column: which buttons, and where
	header(p, "Buttons", LEFT, -88, COLW)
	local call = page.add(checkbox(p, "Call of the ... (Elements, Ancestors, Spirits)", "callOn", LEFT, -114))
	note(p, "One button with a small arrow: click the arrow to\npick another Call spell, like the default totem bar.", LEFT + 28, -142)
	local totemic = page.add(checkbox(p, "Totemic Call", "callTotemic", LEFT, -190))
	note(p, "Brings your totems to you.", LEFT + 28, -218)
	local recall = page.add(checkbox(p, "Totemic Recall", "callRecall", LEFT, -244))
	note(p, "Takes your totems back and gives mana back.", LEFT + 28, -272)

	header(p, "Where", LEFT, -318, COLW)
	local side = radioGroup(p, {
		{ "start", "Before the totems" },
		{ "end", "After the totems" },
	}, LEFT, -344, 1, 0, 24,
		function() return ns.get().callSide == "end" and "end" or "start" end,
		function(v) ns.get().callSide = v end)
	page.add(side)
	local sideNote = note(p, "", LEFT, -396)

	-- ---- right column: what you have
	header(p, "Your spells", RIGHT, -88, COLW)
	local have = note(p, "", RIGHT, -114)
	have:SetWidth(COLW)

	local function dependents()
		local lines = ns.callInfo and ns.callInfo() or {}
		have:SetText(table.concat(lines, "\n"))
		local st = ns.callState
		if st and st.sideMoved then
			sideNote:SetText("The buff icons are on that end, so the buttons\nsit on the other one.")
		else
			sideNote:SetText("Always at the totem bar, even with no totem out.")
		end
	end
	for _, c in ipairs({ call, totemic, recall }) do c:HookScript("OnClick", dependents) end
	for _, rb in ipairs(side.rbs) do rb:HookScript("OnClick", dependents) end
	page.after[#page.after + 1] = function() side.refresh(); dependents() end

	page.onDefault = function() if ns.callApply then ns.callApply() end end
	return page
end
