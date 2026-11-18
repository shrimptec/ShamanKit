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
	cb.settingKey = key
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
		checkbox(panel, "Green check when in range", "showRange", 16, -240),
		checkbox(panel, "Red cross when out of range", "showOut", 16, -270),
		checkbox(panel, "Tint the icon red when out of range", "tint", 16, -300),
		checkbox(panel, "Replace the default totem timers", "attach", 16, -330),
		slider(panel, "Position left / right", "attachX", -200, 300, 40, -365),
		slider(panel, "Position up / down", "attachY", -100, 100, 40, -420),
		checkbox(panel, "Unlock frame (drag it to move)", "locked", 16, -475),
	}
	-- "locked" is stored the other way round to how the box reads
	local unlock = controls[#controls]
	unlock.refresh = function() unlock:SetChecked(ns.get().locked == false) end
	unlock:SetScript("OnClick", function(self)
		ns.get().locked = not self:GetChecked()
		ns.updatePreview()
	end)

	-- One table for the bar: a row per place (first to last) with that element's icon, Up / Down arrows, whether to
	-- keep its space open when the totem is down, and which totem its dim placeholder shows.
	local COL = { icon = 310, label = 344, up = 404, down = 426, keep = 458, pick = 492 }
	local tableTitle = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	tableTitle:SetPoint("TOPLEFT", COL.icon, -70)
	tableTitle:SetText("Totems, first to last in the bar")
	local keepHead = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	keepHead:SetPoint("TOPLEFT", COL.keep - 2, -96)
	keepHead:SetText("Keep")
	local pickHead = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	pickHead:SetPoint("TOPLEFT", COL.pick, -96)
	pickHead:SetText("Placeholder icon")

	local rows = {}
	local function rowSlot(i) return ns.fixOrder()[i] end
	local function choiceIndex(list, id)
		for k, c in ipairs(list) do if c.id == id then return k end end
		return 0   -- 0 = Auto
	end
	local function cycle(slot, dir)
		local list, choice = ns.totemChoices(slot), ns.fixHold().choice
		local k = choiceIndex(list, choice[slot]) + dir
		if k > #list then k = 0 elseif k < 0 then k = #list end
		choice[slot] = k > 0 and list[k].id or nil
	end
	local function refreshRows()
		for i, row in ipairs(rows) do
			local slot = rowSlot(i)
			row.icon:SetTexture(ns.holderTexture(slot))
			row.label:SetText(i .. ".  " .. (ns.SLOT_NAMES[slot] or ("Slot " .. slot)))
			row.up:SetEnabled(i > 1)
			row.down:SetEnabled(i < #rows)
			row.keep.refresh()
			local list = ns.totemChoices(slot)
			local k = choiceIndex(list, ns.fixHold().choice[slot])
			row.pick:SetText(k > 0 and (list[k].name:gsub(" Totem$", "")) or "Auto")
		end
	end
	local function arrow(parent, x, y, dir)
		local b = CreateFrame("Button", nil, parent)
		b:SetSize(20, 20)
		b:SetPoint("TOPLEFT", x, y)
		local name = dir < 0 and "ScrollUpButton" or "ScrollDownButton"
		b:SetNormalTexture("Interface\\Buttons\\UI-ScrollBar-" .. name .. "-Up")
		b:SetPushedTexture("Interface\\Buttons\\UI-ScrollBar-" .. name .. "-Down")
		b:SetDisabledTexture("Interface\\Buttons\\UI-ScrollBar-" .. name .. "-Disabled")
		b:SetHighlightTexture("Interface\\Buttons\\UI-ScrollBar-" .. name .. "-Highlight", "ADD")
		return b
	end
	for i = 1, #ns.fixOrder() do
		local row = {}
		local y = -116 - (i - 1) * 34
		row.icon = panel:CreateTexture(nil, "ARTWORK")
		row.icon:SetSize(26, 26)
		row.icon:SetPoint("TOPLEFT", COL.icon, y)
		row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
		row.label = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
		row.label:SetPoint("TOPLEFT", COL.label, y - 6)
		row.label:SetWidth(58)
		row.label:SetJustifyH("LEFT")
		row.up = arrow(panel, COL.up, y - 3, -1)
		row.up.orderRow, row.up.orderDelta = i, -1
		row.up:SetScript("OnClick", function() ns.moveSlot(i, -1); refreshRows() end)
		row.down = arrow(panel, COL.down, y - 3, 1)
		row.down.orderRow, row.down.orderDelta = i, 1
		row.down:SetScript("OnClick", function() ns.moveSlot(i, 1); refreshRows() end)
		row.keep = checkbox(panel, "", nil, COL.keep, y,
			function() return ns.fixReserve()[rowSlot(i)] == true end,
			function(on) ns.fixReserve()[rowSlot(i)] = on or nil end)
		row.keep.rowIndex = i
		row.pick = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
		row.pick:SetSize(112, 22)
		row.pick:SetPoint("TOPLEFT", COL.pick, y - 2)
		row.pick:RegisterForClicks("LeftButtonUp", "RightButtonUp")
		row.pick.rowIndex = i
		row.pick:SetScript("OnClick", function(_, button)
			cycle(rowSlot(i), button == "RightButton" and -1 or 1)
			ns.updatePreview()
			refreshRows()
		end)
		row.pick:SetScript("OnEnter", function(self)
			local slot = rowSlot(i)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetText("Placeholder icon: " .. (ns.SLOT_NAMES[slot] or "?"))
			GameTooltip:AddLine("Auto: " .. (ns.get().rememberLast ~= false and "the last totem you had out here" or "a generic totem of this element"), 1, 1, 1)
			GameTooltip:AddLine("Pick a totem to lock the icon to it.", 1, 1, 1)
			GameTooltip:AddLine("Click: next    Right-click: previous", 0.7, 0.7, 0.7)
			GameTooltip:Show()
		end)
		row.pick:SetScript("OnLeave", GameTooltip_Hide)
		rows[i] = row
	end
	local resetOrder = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	resetOrder:SetSize(120, 22)
	resetOrder:SetPoint("TOPLEFT", COL.icon, -256)
	resetOrder:SetText("Reset order")
	resetOrder:SetScript("OnClick", function() ns.resetOrder(); refreshRows() end)

	-- Remembering: the placeholder shows the last totem that was out in that place (a picked totem always wins).
	local remember = checkbox(panel, "Placeholder shows the last totem used", "rememberLast", COL.icon, -290)
	controls[#controls + 1] = remember
	local rememberHint = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	rememberHint:SetPoint("TOPLEFT", COL.icon + 28, -318)
	rememberHint:SetText("A totem picked in the list above always wins.")

	-- How the distance to each totem is shown under it.
	local distTitle = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	distTitle:SetPoint("TOPLEFT", COL.icon, -350)
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
		local rb = radio(panel, m[2], COL.icon, -374 - (i - 1) * 24, function()
			ns.get().distanceMode = m[1]
			refreshDistance()
			ns.updatePreview()
		end)
		rb.mode = m[1]
		radios[i] = { rb = rb, mode = m[1] }
	end

	-- The two small icons: weapon enchant missing / running out, and Lightning Shield charges.
	local auxTitle = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	auxTitle:SetPoint("TOPLEFT", COL.icon, -452)
	auxTitle:SetText("Small icons next to the bar")
	controls[#controls + 1] = checkbox(panel, "Weapon enchant missing / running out", "weaponOn", COL.icon, -474)
	controls[#controls + 1] = checkbox(panel, "Lightning Shield charges", "shieldOn", COL.icon, -500)
	local auxAttach = checkbox(panel, "Keep them with the totem bar", "auxAttached", COL.icon, -526)
	controls[#controls + 1] = auxAttach

	local reset = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	reset:SetSize(140, 24)
	reset:SetPoint("TOPLEFT", 16, -520)
	reset:SetText("Reset position")
	reset:SetScript("OnClick", ns.resetPosition)

	-- offsets only matter while attached; dragging only while detached
	local attach, offX, offY = controls[7], controls[8], controls[9]
	local function enable(c, on)
		c:SetEnabled(on)
		c:SetAlpha(on and 1 or 0.5)
	end
	local function dependents()
		local d = ns.get()
		local on = d.attach and true or false
		enable(offX, on); enable(offY, on)
		enable(unlock, not on or d.auxAttached == false)   -- the two small icons can be dragged on their own even while the bar is attached
	end
	attach:HookScript("OnClick", dependents)
	auxAttach:HookScript("OnClick", dependents)
	local function refresh()
		for _, c in ipairs(controls) do c.refresh() end
		dependents()
		refreshRows()
		refreshDistance()
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
			if k ~= "point" and k ~= "relPoint" and k ~= "x" and k ~= "y" and k ~= "auxPoint" and k ~= "auxRelPoint" and k ~= "auxX" and k ~= "auxY" then db[k] = v end
		end
		db.order = ns.defaultOrder()
		db.reserve = {}
		ns.fixHold(); db.hold.choice = {}
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
