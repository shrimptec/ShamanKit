-- TotemRange settings: Esc > Options > AddOns > TotemRange, or /totemrange
-- Built from plain Blizzard textures (slider bar/thumb, check box) so it looks like the stock panels.

local ADDON, ns = ...

-- get/set are optional: a plain setting is read and written as ns.get()[key]
local function checkbox(parent, label, key, x, y, get, set)
	local cb = CreateFrame("CheckButton", nil, parent)
	cb:SetSize(26, 26)
	cb:SetPoint("TOPLEFT", x, y)
	cb:SetNormalTexture("Interface\\Buttons\\UI-CheckBox-Up")
	cb:SetPushedTexture("Interface\\Buttons\\UI-CheckBox-Down")
	cb:SetHighlightTexture("Interface\\Buttons\\UI-CheckBox-Highlight", "ADD")
	cb:SetCheckedTexture("Interface\\Buttons\\UI-CheckBox-Check")
	cb:SetDisabledCheckedTexture("Interface\\Buttons\\UI-CheckBox-Check-Disabled")
	local text = cb:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	text:SetPoint("LEFT", cb, "RIGHT", 2, 1)
	text:SetText(label)
	cb:SetScript("OnClick", function(self)
		local on = self:GetChecked() and true or false
		if set then set(on) else ns.get()[key] = on end
		PlaySound(on and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_OFF)
		ns.updatePreview()
	end)
	cb.refresh = function() cb:SetChecked(get and get() or (not get and ns.get()[key])) end
	return cb
end

-- A round radio button in the stock look (the same art as the game's own option panels).
local function radio(parent, label, x, y, onClick)
	local rb = CreateFrame("CheckButton", nil, parent)
	rb:SetSize(20, 20)
	rb:SetPoint("TOPLEFT", x, y)
	rb:SetNormalTexture("Interface\\Buttons\\UI-RadioButton")
	rb:GetNormalTexture():SetTexCoord(0, 0.25, 0, 1)
	rb:SetHighlightTexture("Interface\\Buttons\\UI-RadioButton", "ADD")
	rb:GetHighlightTexture():SetTexCoord(0.5, 0.75, 0, 1)
	rb:SetCheckedTexture("Interface\\Buttons\\UI-RadioButton")
	rb:GetCheckedTexture():SetTexCoord(0.25, 0.5, 0, 1)
	local text = rb:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	text:SetPoint("LEFT", rb, "RIGHT", 4, 1)
	text:SetText(label)
	rb:SetScript("OnClick", function() PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON); onClick() end)
	return rb
end

local function slider(parent, label, key, lo, hi, x, y)
	local title = parent:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	title:SetPoint("TOPLEFT", x, y)
	title:SetText(label)

	local s = CreateFrame("Slider", nil, parent, "BackdropTemplate")
	s:SetOrientation("HORIZONTAL")
	s:SetSize(200, 16)
	s:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
	s:SetBackdrop({
		bgFile = "Interface\\Buttons\\UI-SliderBar-Background",
		edgeFile = "Interface\\Buttons\\UI-SliderBar-Border",
		tile = true, tileSize = 8, edgeSize = 8,
		insets = { left = 3, right = 3, top = 6, bottom = 6 },
	})
	s:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
	s:SetMinMaxValues(lo, hi)
	s:SetValueStep(1)
	s:SetObeyStepOnDrag(true)

	local value = parent:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	value:SetPoint("LEFT", s, "RIGHT", 10, 0)

	s:SetScript("OnValueChanged", function(self, v)
		v = math.floor(v + 0.5)
		value:SetText(v)
		if ns.get()[key] ~= v then
			ns.get()[key] = v
			ns.updatePreview()
		end
	end)
	s.refresh = function() s:SetValue(ns.get()[key]); value:SetText(ns.get()[key]) end
	return s
end

function ns.buildOptions()
	if not (Settings and Settings.RegisterCanvasLayoutCategory) then return end

	local panel = CreateFrame("Frame")
	panel.name = "TotemRange"

	local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", 16, -16)
	title:SetText("TotemRange")

	local sub = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
	sub:SetText("Your active totems, how long they have left, and whether you are in range of each.")

	local controls = {
		slider(panel, "Icon size", "size", 24, 80, 16, -70),
		slider(panel, "Spacing", "spacing", 0, 24, 16, -125),
		checkbox(panel, "Vertical layout", "vertical", 16, -180),
		checkbox(panel, "Show time left", "showTimer", 16, -210),
		checkbox(panel, "Show range mark (check / cross)", "showRange", 16, -240),
		checkbox(panel, "Tint the icon red when out of range", "tint", 16, -270),
		checkbox(panel, "Replace the default totem timers (stays under the player frame)", "attach", 16, -300),
		slider(panel, "Position left / right", "attachX", -200, 300, 40, -335),
		slider(panel, "Position up / down", "attachY", -100, 100, 40, -390),
		checkbox(panel, "Unlock frame (drag it to move)", "locked", 16, -445),
	}
	-- "locked" is stored the other way round to how the box reads
	local unlock = controls[#controls]
	unlock.refresh = function() unlock:SetChecked(ns.get().locked == false) end
	unlock:SetScript("OnClick", function(self)
		ns.get().locked = not self:GetChecked()
		ns.updatePreview()
	end)

	-- Order of the totems in the bar: one row per place, with the element, an icon and Up / Down buttons.
	local orderTitle = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	orderTitle:SetPoint("TOPLEFT", 330, -70)
	orderTitle:SetText("Totem order")
	local orderHint = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	orderHint:SetPoint("TOPLEFT", orderTitle, "BOTTOMLEFT", 0, -4)
	orderHint:SetText("First to last in the bar. Default: earth, fire, water, air.")
	local SAMPLE_SPELL = { [1] = 3599, [2] = 8071, [3] = 5394, [4] = 8835 }   -- one totem of each element, for the icon
	local rows = {}
	local function refreshOrder()
		local order = ns.fixOrder()
		for i, row in ipairs(rows) do
			local slot = order[i]
			local tex = C_Spell and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(SAMPLE_SPELL[slot])
			row.icon:SetTexture(tex or "Interface\\Icons\\INV_Misc_QuestionMark")
			row.label:SetText(i .. ".  " .. (ns.SLOT_NAMES[slot] or ("Slot " .. slot)))
			row.up:SetEnabled(i > 1)
			row.down:SetEnabled(i < #rows)
		end
	end
	for i = 1, #ns.fixOrder() do
		local row = {}
		local y = -112 - (i - 1) * 32
		row.icon = panel:CreateTexture(nil, "ARTWORK")
		row.icon:SetSize(26, 26)
		row.icon:SetPoint("TOPLEFT", 330, y)
		row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
		row.label = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
		row.label:SetPoint("LEFT", row.icon, "RIGHT", 8, 0)
		row.label:SetWidth(70)
		row.label:SetJustifyH("LEFT")
		row.up = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
		row.up:SetSize(52, 22)
		row.up:SetPoint("LEFT", row.label, "RIGHT", 6, 0)
		row.up:SetText("Up")
		row.up:SetScript("OnClick", function() ns.moveSlot(i, -1); refreshOrder() end)
		row.down = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
		row.down:SetSize(52, 22)
		row.down:SetPoint("LEFT", row.up, "RIGHT", 4, 0)
		row.down:SetText("Down")
		row.down:SetScript("OnClick", function() ns.moveSlot(i, 1); refreshOrder() end)
		rows[i] = row
	end
	local resetOrder = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	resetOrder:SetSize(140, 24)
	resetOrder:SetPoint("TOPLEFT", 330, -112 - #rows * 32 - 6)
	resetOrder:SetText("Reset order")
	resetOrder:SetScript("OnClick", function() ns.resetOrder(); refreshOrder() end)

	-- How the distance to each totem is shown under it.
	local distTitle = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	distTitle:SetPoint("TOPLEFT", 330, -112 - #rows * 32 - 50)
	distTitle:SetText("Distance under each totem")
	local MODES = {
		{ "bar", "Range bar  (room left in its range)" },
		{ "yards", "Exact yards" },
		{ "off", "Nothing" },
	}
	local radios = {}
	local function refreshDistance()
		local now = ns.distMode()
		for _, r in ipairs(radios) do r.rb:SetChecked(r.mode == now) end
	end
	for i, m in ipairs(MODES) do
		local rb = radio(panel, m[2], 330, -112 - #rows * 32 - 74 - (i - 1) * 24, function()
			ns.get().distanceMode = m[1]
			refreshDistance()
			ns.updatePreview()
		end)
		rb.mode = m[1]
		radios[i] = { rb = rb, mode = m[1] }
	end

	-- Keep a place open for an element even when its totem is down: the dim placeholder makes the missing one obvious.
	local holdTitle = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	holdTitle:SetPoint("TOPLEFT", 330, -402)
	holdTitle:SetText("Keep a space open for")
	local holdHint = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	holdHint:SetPoint("TOPLEFT", holdTitle, "BOTTOMLEFT", 0, -4)
	holdHint:SetText("A dim icon marks the missing totem.")
	local holdBoxes = {}
	local HOLD_AT = { { 2, 330, -440 }, { 1, 440, -440 }, { 3, 330, -468 }, { 4, 440, -468 } }   -- earth, fire / water, air
	for _, e in ipairs(HOLD_AT) do
		local slot = e[1]
		local cb = checkbox(panel, ns.SLOT_NAMES[slot], nil, e[2], e[3],
			function() return ns.fixReserve()[slot] == true end,
			function(on) ns.fixReserve()[slot] = on or nil end)
		cb.slotKey = slot
		holdBoxes[#holdBoxes + 1] = cb
	end

	local reset = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	reset:SetSize(140, 24)
	reset:SetPoint("TOPLEFT", 16, -490)
	reset:SetText("Reset position")
	reset:SetScript("OnClick", ns.resetPosition)

	-- offsets only matter while attached; dragging only while detached
	local attach, offX, offY = controls[7], controls[8], controls[9]
	local function enable(c, on)
		c:SetEnabled(on)
		c:SetAlpha(on and 1 or 0.5)
	end
	local function dependents()
		local on = ns.get().attach and true or false
		enable(offX, on); enable(offY, on); enable(unlock, not on)
	end
	attach:HookScript("OnClick", dependents)
	local function refresh()
		for _, c in ipairs(controls) do c.refresh() end
		dependents()
		refreshOrder()
		refreshDistance()
		for _, cb in ipairs(holdBoxes) do cb.refresh() end
	end
	panel:SetScript("OnShow", function()
		refresh()
		ns.optionsOpen = true
		ns.updatePreview()   -- sample totems appear while this page is open
	end)
	panel:SetScript("OnHide", function()
		ns.optionsOpen = false
		ns.updatePreview()
	end)
	panel.OnCommit = function() end
	panel.OnRefresh = refresh
	panel.OnDefault = function()
		local db = ns.get()
		for k, v in pairs(ns.defaults) do
			if k ~= "point" and k ~= "relPoint" and k ~= "x" and k ~= "y" then db[k] = v end
		end
		db.order = ns.defaultOrder()
		db.reserve = {}
		refresh()
		ns.updatePreview()
	end

	local category = Settings.RegisterCanvasLayoutCategory(panel, "TotemRange")
	Settings.RegisterAddOnCategory(category)
	ns.category = category
end

function ns.openOptions()
	if not ns.category then print("TotemRange: settings panel unavailable on this client.") return end
	local ok = pcall(Settings.OpenToCategory, ns.category:GetID())
	if not ok then pcall(Settings.OpenToCategory, ns.category) end
end
