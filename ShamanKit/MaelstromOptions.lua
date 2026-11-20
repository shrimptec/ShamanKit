-- ShamanKit settings: the Maelstrom page (Esc > Options > AddOns > ShamanKit > Maelstrom).
-- Built by Options.lua's ns.buildOptions(), which hands over its helpers; its own file because the Maelstrom module is
-- its own piece of the addon (Maelstrom.lua). Left: what shows, colours, the glow. Right: the fight display, size, test.

local ADDON, ns = ...

function ns.buildMaelstromPage(ui)
	local newPage, checkbox, slider, header, note, enable, radioGroup = ui.newPage, ui.checkbox, ui.slider, ui.header, ui.note, ui.enable, ui.radioGroup
	local LEFT, RIGHT, COLW = ui.LEFT, ui.RIGHT, ui.COLW

	local page = newPage("Maelstrom", "Maelstrom Weapon",
		"A bar of five squares for your Maelstrom Weapon stacks, and a glow on Lightning Bolt at five.",
		{ "mwOn", "mwAlways", "mwCount", "mwCountPos", "mwCountX", "mwCountY", "mwW", "mwH", "mwGap", "mwScale", "mwColor", "mwColorFull",
			"mwColorBg", "mwColorGlow", "mwGlow", "mwGlowSpell", "mwAura", "mwFrames", "mwErrorLog", "mwPoint", "mwRelPoint", "mwX", "mwY" })
	local p = page.panel
	page.onDefault = function() if ns.mwApply then ns.mwApply() end end

	-- ---- left column: what shows
	header(p, "Bar", LEFT, -78, COLW)
	local on = page.add(checkbox(p, "Show the Maelstrom Weapon bar", "mwOn", LEFT, -102))
	page.add(checkbox(p, "Always show it (not only with stacks)", "mwAlways", LEFT, -128))
	local count = page.add(checkbox(p, "Show the stack count as a number", "mwCount", LEFT, -154))
	local countPos = radioGroup(p, {
		{ "top", "Above" }, { "center", "Middle" }, { "bottom", "Below" },
	}, LEFT + 28, -180, 3, 76, 24,
		function() local v = ns.get().mwCountPos; return (v == "center" or v == "bottom") and v or "top" end,
		function(v) ns.get().mwCountPos = v end)
	page.add(countPos)

	-- ---- colours: a swatch opens the game's colour picker
	header(p, "Colors", LEFT, -222, COLW)
	local function swatchRow(label, key, y)
		local btn = CreateFrame("Button", nil, p)
		btn:SetSize(24, 24)
		btn:SetPoint("TOPLEFT", LEFT + 4, y)
		local border = btn:CreateTexture(nil, "BACKGROUND")
		border:SetAllPoints()
		border:SetColorTexture(1, 1, 1, 1)
		local sw = btn:CreateTexture(nil, "ARTWORK")
		sw:SetPoint("TOPLEFT", 2, -2)
		sw:SetPoint("BOTTOMRIGHT", -2, 2)
		local fs = p:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
		fs:SetPoint("LEFT", btn, "RIGHT", 8, 0)
		fs:SetText(label)
		local function current()
			local c = ns.get()[key]
			if type(c) == "table" and type(c[1]) == "number" and type(c[2]) == "number" and type(c[3]) == "number" then return c end
			return ns.defaults[key]
		end
		btn.refresh = function() local c = current(); sw:SetColorTexture(c[1], c[2], c[3], 1) end
		-- a new table every time: the default colours are shared and must never be edited in place
		local function put(r, g, b) ns.get()[key] = { r, g, b }; btn.refresh(); ns.updatePreview() end
		btn:SetScript("OnClick", function()
			local c = current()
			local old = { c[1], c[2], c[3] }
			local function apply() local r, g, b = ColorPickerFrame:GetColorRGB(); put(r, g, b) end
			local function cancel() put(old[1], old[2], old[3]) end
			if ColorPickerFrame.SetupColorPickerAndShow then
				ColorPickerFrame:SetupColorPickerAndShow({ r = c[1], g = c[2], b = c[3], hasOpacity = false, swatchFunc = apply, cancelFunc = cancel })
			else
				ColorPickerFrame.hasOpacity = false
				ColorPickerFrame.func, ColorPickerFrame.swatchFunc, ColorPickerFrame.cancelFunc = apply, apply, cancel
				ColorPickerFrame:SetColorRGB(c[1], c[2], c[3])
				ColorPickerFrame:Hide()
				ColorPickerFrame:Show()
			end
		end)
		page.add(btn)
		return btn
	end
	swatchRow("Stacks 1 to 4", "mwColor", -246)
	swatchRow("5 stacks (maximum)", "mwColorFull", -274)
	swatchRow("Bar background", "mwColorBg", -302)
	swatchRow("Glow on the spell", "mwColorGlow", -330)

	-- ---- the glow
	header(p, "Action-bar glow", LEFT, -378, COLW)
	page.add(checkbox(p, "Glow on the spell at 5 stacks", "mwGlow", LEFT, -402))
	note(p, "Spell to highlight (name or ID); empty = Lightning Bolt", LEFT + 4, -432)
	local function editBox(x, y, key, apply)
		local eb = CreateFrame("EditBox", nil, p, "InputBoxTemplate")
		eb:SetSize(220, 22)
		eb:SetPoint("TOPLEFT", x, y)
		eb:SetAutoFocus(false)
		eb:SetScript("OnEnterPressed", function(self)
			local t = self:GetText()
			ns.get()[key] = (t and t ~= "") and t or nil
			self:ClearFocus()
			if apply then apply() end
			ns.updatePreview()
		end)
		eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
		eb.refresh = function() local v = ns.get()[key]; eb:SetText(v ~= nil and tostring(v) or "") end
		page.add(eb)
		return eb
	end
	editBox(LEFT + 8, -450, "mwGlowSpell")

	-- ---- right column: the fight display, size, test
	header(p, "In a fight", RIGHT, -78, COLW)
	local status = p:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	status:SetPoint("TOPLEFT", RIGHT, -102)
	status:SetWidth(COLW)
	status:SetJustifyH("LEFT")
	local function paintStatus()
		local st = ns.mwCombatState and ns.mwCombatState() or "pending"
		if st == "ready" then
			status:SetText("The game itself draws the stacks, the count and the glow, so nothing needs setting up.")
			status:SetTextColor(0.35, 1, 0.35)
		elseif st == "unavailable" then
			status:SetText("This client does not let the addon draw the stacks in a fight.")
			status:SetTextColor(1, 0.55, 0.2)
		else
			status:SetText("The fight display is built out of combat; it will be ready for the next fight.")
			status:SetTextColor(1, 0.8, 0.2)
		end
	end
	page.after[#page.after + 1] = paintStatus

	header(p, "Size", RIGHT, -160, COLW)
	page.add(slider(p, "Square width", "mwW", 10, 80, RIGHT, -184))
	page.add(slider(p, "Square height", "mwH", 6, 60, RIGHT, -228))
	page.add(slider(p, "Spacing between squares", "mwGap", 0, 30, RIGHT, -272))
	page.add(slider(p, "Scale", "mwScale", 50, 300, RIGHT, -316, function(v) return v .. "%" end, 5))

	header(p, "Test", RIGHT, -366, COLW)
	local function testButton(label, x, n)
		local b = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
		b:SetSize(76, 22)
		b:SetPoint("TOPLEFT", x, -390)
		b:SetText(label)
		b:SetScript("OnClick", function() ns.mwTest(n) end)
		return b
	end
	testButton("3 stacks", RIGHT, 3)
	testButton("5 stacks", RIGHT + 82, 5)
	testButton("Stop", RIGHT + 164, 0)
	note(p, "Fake stacks, for 20 seconds. Press Move on screen\n(top right) to drag the bar and the count.", RIGHT, -418)

	-- ---- advanced
	local ox = page.adv(page.add(slider(p, "Count left / right", "mwCountX", -200, 200, RIGHT, -470)))
	local oy = page.adv(page.add(slider(p, "Count up / down", "mwCountY", -100, 100, RIGHT, -514)))
	page.adv(header(p, "Stack count position", RIGHT, -446, COLW))
	page.adv(header(p, "Buff to track", LEFT, -486, COLW))
	local aura = editBox(LEFT + 8, -508, "mwAura")
	page.adv(aura)
	local errlog = page.add(checkbox(p, "Record Lua errors (/shamankit mw log)", "mwErrorLog", LEFT, -534,
		nil, function(v) ns.get().mwErrorLog = v; if ns.mwErrorLogChanged then ns.mwErrorLogChanged() end end))
	page.adv(errlog)

	local function dependents()
		enable(ox, ns.get().mwCount and true or false)
		enable(oy, ns.get().mwCount and true or false)
		for _, rb in ipairs(countPos.rbs) do enable(rb, ns.get().mwCount and true or false) end
		paintStatus()
		page.applyAdvanced()
	end
	count:HookScript("OnClick", dependents)
	on:HookScript("OnClick", paintStatus)
	page.after[#page.after + 1] = dependents

	return page
end
