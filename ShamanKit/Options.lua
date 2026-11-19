-- ShamanKit settings: Esc > Options > AddOns > ShamanKit (a home page and four pages), or /shamankit
-- Built from plain Blizzard textures (slider bar/thumb, check box, radio button) so it looks like the stock panels.
--   ShamanKit   home page: what is here, and buttons to the pages
--   Totem bar   the icons, the range display and where the bar sits
--   Totems      order of the totems, keeping a place open, the placeholder icon
--   Buffs       the weapon-enchant and Lightning Shield icons
--   Cures       your cure spells lighting up (CureOptions.lua)
--   Call spells buttons for Call of the ..., Totemic Call and Totemic Recall next to the bar (CallOptions.lua)

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

-- A group of radio buttons laid out in a grid (cols per row); items = { { value, label }, ... }.
-- Choosing one writes get/set, redraws the group and the preview.
local function radioGroup(parent, items, x, y, cols, dx, dy, get, set)
	local group = { rbs = {} }
	function group.refresh()
		local now = get()
		for _, rb in ipairs(group.rbs) do rb:SetChecked(rb.value == now) end
	end
	for i, item in ipairs(items) do
		local col, row = (i - 1) % cols, math.floor((i - 1) / cols)
		local rb = radio(parent, item[2], x + col * dx, y - row * dy, function()
			set(item[1])
			group.refresh()
			ns.updatePreview()
		end)
		rb.value = item[1]
		group.rbs[i] = rb
	end
	return group
end

-- fmt (optional) turns the number into the text beside the slider; step defaults to 1
local function slider(parent, label, key, lo, hi, x, y, fmt, step)
	local title = parent:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
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
	step = step or 1
	s:SetValueStep(step)
	s:SetObeyStepOnDrag(true)

	local value = parent:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	value:SetPoint("LEFT", s, "RIGHT", 10, 0)

	local function show(v) value:SetText(fmt and fmt(v) or v) end
	s:SetScript("OnValueChanged", function(self, v)
		v = math.floor(v / step + 0.5) * step
		show(v)
		if ns.get()[key] ~= v then
			ns.get()[key] = v
			ns.updatePreview()
		end
	end)
	s.refresh = function() s:SetValue(ns.get()[key]); show(ns.get()[key]) end
	s.title = title
	return s
end

-- a gold heading with a thin grey line under it
local function header(parent, text, x, y, width)
	local fs = parent:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	fs:SetPoint("TOPLEFT", x, y)
	fs:SetText(text)
	local line = parent:CreateTexture(nil, "ARTWORK")
	line:SetColorTexture(0.5, 0.5, 0.5, 0.45)
	line:SetPoint("TOPLEFT", x, y - 17)
	line:SetSize(width, 1)
	return fs
end

local function note(parent, text, x, y)
	local fs = parent:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	fs:SetPoint("TOPLEFT", x, y)
	fs:SetJustifyH("LEFT")
	fs:SetText(text)
	return fs
end

local function enable(c, on)
	c:SetEnabled(on)
	c:SetAlpha(on and 1 or 0.5)
end

local function enableGroup(group, on)
	for _, rb in ipairs(group.rbs) do enable(rb, on) end
end

local LEFT, RIGHT, COLW = 16, 320, 280

function ns.buildOptions()
	if not (Settings and Settings.RegisterCanvasLayoutCategory) then return end

	-- Every page tells the bar to show its samples while it is on screen; two pages can be swapped in one go
	-- (one hides as the other shows), so count the pages that are up instead of keeping one flag.
	local up = {}
	local function newPage(name, title, subtitle, keys)
		local panel = CreateFrame("Frame")
		panel.name = name
		local page = { panel = panel, controls = {}, after = {}, keys = keys }
		function page.add(c) page.controls[#page.controls + 1] = c; return c end
		function page.refresh()
			for _, c in ipairs(page.controls) do c.refresh() end
			for _, f in ipairs(page.after) do f() end
		end
		local t = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
		t:SetPoint("TOPLEFT", 16, -16)
		t:SetText(title)
		note(panel, subtitle, 16, -42)
		panel:SetScript("OnShow", function()
			up[panel] = true
			page.refresh()
			ns.optionsOpen = true
			ns.updatePreview()   -- sample totems / icons appear while a page is open
		end)
		panel:SetScript("OnHide", function()
			up[panel] = nil
			ns.optionsOpen = next(up) ~= nil
			ns.updatePreview()
		end)
		panel.OnCommit = function() end
		panel.OnRefresh = page.refresh
		panel.OnDefault = function()
			local db = ns.get()
			for _, k in ipairs(page.keys) do db[k] = ns.defaults[k] end
			if page.onDefault then page.onDefault() end
			page.refresh()
			ns.updatePreview()
		end
		return page
	end

	-- ------------------------------------------------------------ home page
	local home = newPage("ShamanKit", "ShamanKit",
		"Small helpers for shamans: your totems, reminders for your weapon enchant and Lightning Shield, your cure spells, and buttons for your Call spells.", {})
	local p0 = home.panel
	local getMeta = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
	local okv, version = pcall(function() return getMeta and getMeta(ADDON, "Version") end)
	if okv and type(version) == "string" and version ~= "" then note(p0, "Version " .. version, 16, -62) end
	header(p0, "Pages", LEFT, -88, 580)
	local function pageButton(label, which, y, text)
		local b = CreateFrame("Button", nil, p0, "UIPanelButtonTemplate")
		b:SetSize(140, 24)
		b:SetPoint("TOPLEFT", LEFT, y)
		b:SetText(label)
		b:SetScript("OnClick", function() ns.openOptions(which) end)
		note(p0, text, LEFT + 156, y - 6)
	end
	pageButton("Totem bar", "bar", -116, "Your active totems, their time left, range, and where the bar sits.")
	pageButton("Totems", "totems", -150, "The order of the totems, and a place kept open for each.")
	pageButton("Buffs", "buffs", -184, "Icons for a missing weapon enchant and your Lightning Shield charges.")
	pageButton("Cures", "cures", -218, "Your cure spells light up while a poison, disease or curse is on you.")
	pageButton("Call spells", "calls", -252, "Buttons for Call of the ..., Totemic Call and Totemic Recall at the bar.")
	header(p0, "Commands", LEFT, -304, 580)
	note(p0, "/shamankit - open this window\n/shamankit bar, totems, buffs, cures or calls - open that page\n/shamankit cures test - light the cures for a few seconds (also /cw)\n/shamankit lock or unlock - lock the frames, or make them draggable\n/shamankit reset - put the bar, the buff icons and the cure row back in the usual place\n/shamankit status - print what the addon reads (for bug reports)", LEFT, -330)

	-- ------------------------------------------------------------ page 1: the totem bar
	local main = newPage("Totem bar", "Totem bar",
		"Your active totems, how long they have left, and whether you are in range of each.",
		{ "size", "spacing", "vertical", "showTimer", "showRange", "showOut", "tint", "distanceMode", "rangeByBuff", "attach", "attachX", "attachY", "locked" })
	local p1 = main.panel

	header(p1, "Totem icons", LEFT, -88, COLW)
	main.add(slider(p1, "Icon size", "size", 24, 80, LEFT, -114))
	main.add(slider(p1, "Spacing", "spacing", 0, 24, LEFT, -169))
	main.add(checkbox(p1, "Vertical layout", "vertical", LEFT, -222))
	main.add(checkbox(p1, "Show time left", "showTimer", LEFT, -250))

	header(p1, "Range", LEFT, -292, COLW)
	main.add(checkbox(p1, "Green check when in range", "showRange", LEFT, -318))
	main.add(checkbox(p1, "Red cross when out of range", "showOut", LEFT, -344))
	main.add(checkbox(p1, "Tint the icon red when out of range", "tint", LEFT, -370))
	local distTitle = p1:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	distTitle:SetPoint("TOPLEFT", LEFT, -406)
	distTitle:SetText("Distance under each totem:")
	local distance = radioGroup(p1, {
		{ "bar", "Range bar  (room left in its range)" },
		{ "yards", "Exact yards" },
		{ "off", "Nothing" },
	}, LEFT, -428, 1, 0, 24,
		function() return ns.distMode() end,
		function(v) ns.get().distanceMode = v end)
	main.add(distance)

	header(p1, "Position", RIGHT, -88, COLW)
	local attach = main.add(checkbox(p1, "Replace the default totem timers", "attach", RIGHT, -114))
	note(p1, "(sits under the player frame while this is ticked)", RIGHT + 28, -140)
	local offX = main.add(slider(p1, "Position left / right", "attachX", -200, 300, RIGHT + 24, -162))
	local offY = main.add(slider(p1, "Position up / down", "attachY", -100, 100, RIGHT + 24, -217))
	-- "locked" is stored the other way round to how the box reads
	local unlock = main.add(checkbox(p1, "Unlock frame (drag it to move)", "locked", RIGHT, -274,
		function() return ns.get().locked == false end,
		function(on) ns.get().locked = not on end))
	local reset = CreateFrame("Button", nil, p1, "UIPanelButtonTemplate")
	reset:SetSize(140, 24)
	reset:SetPoint("TOPLEFT", RIGHT, -312)
	reset:SetText("Reset position")
	reset:SetScript("OnClick", function() ns.resetPosition(); main.refresh() end)

	header(p1, "Range accuracy", RIGHT, -354, COLW)
	main.add(checkbox(p1, "Watch the totem's buff", "rangeByBuff", RIGHT, -380))
	note(p1, "A totem lands a little to one side of you, so your\nposition is only a guess. On: a buff totem is judged by\nits buff when the game lets addons see it, and close to\nthe edge the mark is a yellow ? instead of a guess.", RIGHT + 28, -408)

	-- offsets only matter while attached; dragging only while detached (the small icons can be dragged on their own)
	local function mainDependents()
		local d = ns.get()
		local on = d.attach and true or false
		enable(offX, on); enable(offY, on)
		enable(unlock, not on or ns.auxMode() == "free")
	end
	attach:HookScript("OnClick", mainDependents)
	main.after[#main.after + 1] = function() distance.refresh(); mainDependents() end

	-- ------------------------------------------------------------ page 2: the totems
	local totems = newPage("Totems", "Totems",
		"The order of the totems, keeping a place open while one is down, and what its dim placeholder shows.",
		{ "rememberLast", "leftCast" })
	local p2 = totems.panel
	header(p2, "Totems, first to last in the bar", LEFT, -78, 580)
	local COL = { icon = 16, label = 50, up = 116, down = 138, keep = 184, pick = 232 }
	local keepHead = p2:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	keepHead:SetPoint("TOPLEFT", COL.keep - 2, -104)
	keepHead:SetText("Keep")
	local pickHead = p2:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	pickHead:SetPoint("TOPLEFT", COL.pick, -104)
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
		local y = -124 - (i - 1) * 34
		row.icon = p2:CreateTexture(nil, "ARTWORK")
		row.icon:SetSize(26, 26)
		row.icon:SetPoint("TOPLEFT", COL.icon, y)
		row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
		row.label = p2:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
		row.label:SetPoint("TOPLEFT", COL.label, y - 6)
		row.label:SetWidth(62)
		row.label:SetJustifyH("LEFT")
		row.up = arrow(p2, COL.up, y - 3, -1)
		row.up.orderRow, row.up.orderDelta = i, -1
		row.up:SetScript("OnClick", function() ns.moveSlot(i, -1); refreshRows() end)
		row.down = arrow(p2, COL.down, y - 3, 1)
		row.down.orderRow, row.down.orderDelta = i, 1
		row.down:SetScript("OnClick", function() ns.moveSlot(i, 1); refreshRows() end)
		row.keep = checkbox(p2, "", nil, COL.keep, y,
			function() return ns.fixReserve()[rowSlot(i)] == true end,
			function(on) ns.fixReserve()[rowSlot(i)] = on or nil end)
		row.keep.rowIndex = i
		row.pick = CreateFrame("Button", nil, p2, "UIPanelButtonTemplate")
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
	local resetOrder = CreateFrame("Button", nil, p2, "UIPanelButtonTemplate")
	resetOrder:SetSize(120, 22)
	resetOrder:SetPoint("TOPLEFT", COL.icon, -270)
	resetOrder:SetText("Reset order")
	resetOrder:SetScript("OnClick", function() ns.resetOrder(); refreshRows() end)

	header(p2, "Placeholders", LEFT, -314, 580)
	totems.add(checkbox(p2, "Placeholder shows the last totem used", "rememberLast", LEFT, -340))
	note(p2, "A totem picked in the list above always wins.", LEFT + 28, -368)
	totems.add(checkbox(p2, "Left-click a place to cast its totem", "leftCast", LEFT, -396))
	note(p2, "Casts the totem the place shows (the dim one, or the one that is out), also in a fight.\nLocked bar only: when it is unlocked, dragging moves it instead.", LEFT + 28, -424)
	totems.after[#totems.after + 1] = refreshRows
	totems.onDefault = function()
		local db = ns.get()
		db.order = ns.defaultOrder()
		db.reserve = {}
		ns.fixHold(); db.hold.choice = {}
	end

	-- ------------------------------------------------------------ page 3: the small icons
	local icons = newPage("Buffs", "Buffs",
		"A small icon when your weapon has no enchant, and one with your Lightning Shield charges.",
		{ "weaponOn", "weaponMode", "shieldOn", "auxAnchor", "auxSide", "auxAlign", "auxOffX", "auxOffY", "auxScale", "auxWarnMin" })
	local p3 = icons.panel
	icons.onDefault = function() ns.resetAuxPlace() end

	header(p3, "Show", LEFT, -78, COLW)
	local weaponBox = icons.add(checkbox(p3, "Weapon enchant icon", "weaponOn", LEFT, -102))
	local modeLabel = p3:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	modeLabel:SetPoint("TOPLEFT", LEFT + 28, -130)
	modeLabel:SetText("It shows:")
	local weaponMode = radioGroup(p3, {
		{ "missing", "Only when missing or running out" },
		{ "active", "Which enchant is on (like the shield)" },
	}, LEFT + 28, -148, 1, 0, 22,
		function() return ns.weaponMode() end,
		function(v) ns.get().weaponMode = v end)
	icons.add(weaponMode)
	icons.add(checkbox(p3, "Lightning Shield charges", "shieldOn", LEFT, -198))
	local warnSlider = icons.add(slider(p3, "Warn when the weapon enchant has under", "auxWarnMin", 0, 10, LEFT, -234,
		function(v) return v == 0 and "only when gone" or (v .. (v == 1 and " minute" or " minutes")) end))

	header(p3, "Size", LEFT, -296, COLW)
	icons.add(slider(p3, "Icon size (% of the totem icons)", "auxScale", 50, 120, LEFT, -320, function(v) return v .. "%" end, 5))

	header(p3, "Moving", LEFT, -384, COLW)
	local unlockIcons = icons.add(checkbox(p3, "Unlock to drag the icons", "locked", LEFT, -408,
		function() return ns.get().locked == false end,
		function(on) ns.get().locked = not on end))
	note(p3, "Only for \"Own place\"; it unlocks the totem bar too.\nDrag while this page is open, or use the sliders.", LEFT + 28, -436)
	local resetIcons = CreateFrame("Button", nil, p3, "UIPanelButtonTemplate")
	resetIcons:SetSize(160, 24)
	resetIcons:SetPoint("TOPLEFT", LEFT, -472)
	resetIcons:SetText("Reset icon position")
	resetIcons:SetScript("OnClick", function() ns.resetAuxPlace(); icons.refresh() end)

	header(p3, "Position", RIGHT, -78, COLW)
	local anchorLabel = p3:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	anchorLabel:SetPoint("TOPLEFT", RIGHT, -102)
	anchorLabel:SetText("Attach to:")
	local anchor = radioGroup(p3, {
		{ "bar", "Totem bar" }, { "player", "Player frame" }, { "free", "Own place" },
	}, RIGHT, -120, 3, 96, 24,
		function() return ns.auxMode() end,
		function(v) ns.get().auxAnchor = v end)
	icons.add(anchor)
	local sideLabel = p3:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	sideLabel:SetPoint("TOPLEFT", RIGHT, -150)
	sideLabel:SetText("Side of it:")
	local side = radioGroup(p3, {
		{ "auto", "Auto" }, { "bottom", "Below" }, { "top", "Above" }, { "left", "Left" }, { "right", "Right" },
	}, RIGHT, -168, 3, 76, 24,
		function() local sd = ns.get().auxSide; return (sd == "bottom" or sd == "top" or sd == "left" or sd == "right") and sd or "auto" end,
		function(v) ns.get().auxSide = v end)
	icons.add(side)
	local alignLabel = p3:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	alignLabel:SetPoint("TOPLEFT", RIGHT, -220)
	alignLabel:SetText("Along that side:")
	local align = radioGroup(p3, {
		{ "start", "Start" }, { "center", "Middle" }, { "end", "End" },
	}, RIGHT, -238, 3, 76, 24,
		function() local a = ns.get().auxAlign; return (a == "center" or a == "end") and a or "start" end,
		function(v) ns.get().auxAlign = v end)
	icons.add(align)
	local nudgeX = icons.add(slider(p3, "Nudge left / right", "auxOffX", -100, 100, RIGHT, -270))
	local nudgeY = icons.add(slider(p3, "Nudge up / down", "auxOffY", -100, 100, RIGHT, -323))

	header(p3, "Own place", RIGHT, -374, COLW)
	local ownX = icons.add(slider(p3, "Screen position left / right", "auxX", -1000, 1000, RIGHT, -400, nil, 5))
	local ownY = icons.add(slider(p3, "Screen position up / down", "auxY", -600, 600, RIGHT, -453, nil, 5))

	local function iconDependents()
		local on = ns.auxMode() ~= "free"
		enableGroup(side, on); enableGroup(align, on)
		enable(nudgeX, on); enable(nudgeY, on)
		enable(ownX, not on); enable(ownY, not on)
		enable(unlockIcons, not on)
		enableGroup(weaponMode, ns.get().weaponOn and true or false)   -- the choice only matters while the icon is on
	end
	for _, rb in ipairs(anchor.rbs) do rb:HookScript("OnClick", iconDependents) end
	weaponBox:HookScript("OnClick", iconDependents)
	icons.after[#icons.after + 1] = function() anchor.refresh(); side.refresh(); align.refresh(); weaponMode.refresh(); iconDependents() end

	-- ------------------------------------------------------------ page 4: the cures (built in CureOptions.lua)
	-- its own pcall: a fault in that page must never take the others down
	local okc, curesPage = pcall(function()
		return ns.buildCuresPage and ns.buildCuresPage({ newPage = newPage, checkbox = checkbox, slider = slider, header = header,
			note = note, enable = enable, LEFT = LEFT, RIGHT = RIGHT, COLW = COLW })
	end)
	if not okc then print("ShamanKit: the Cures page could not be built: " .. tostring(curesPage)); curesPage = nil end

	-- ------------------------------------------------------------ page 5: the Call spell buttons (built in CallOptions.lua)
	local okk, callsPage = pcall(function()
		return ns.buildCallsPage and ns.buildCallsPage({ newPage = newPage, checkbox = checkbox, header = header, note = note,
			enable = enable, radioGroup = radioGroup, LEFT = LEFT, RIGHT = RIGHT, COLW = COLW })
	end)
	if not okk then print("ShamanKit: the Call spells page could not be built: " .. tostring(callsPage)); callsPage = nil end

	-- ------------------------------------------------------------ register: one category, five sub-pages
	local category = Settings.RegisterCanvasLayoutCategory(p0, "ShamanKit")
	Settings.RegisterAddOnCategory(category)
	ns.category = category
	local function register(page, name)
		page.panel.parent = "ShamanKit"
		if Settings.RegisterCanvasLayoutSubcategory then
			local ok, sub = pcall(Settings.RegisterCanvasLayoutSubcategory, category, page.panel, name)
			if ok and sub then return sub end
		end
		-- no sub-pages on this client: a category of its own beside the main one
		local c = Settings.RegisterCanvasLayoutCategory(page.panel, "ShamanKit - " .. name)
		Settings.RegisterAddOnCategory(c)
		return c
	end
	ns.categories = {
		bar = register(main, "Totem bar"),
		totems = register(totems, "Totems"),
		buffs = register(icons, "Buffs"),
		cures = curesPage and register(curesPage, "Cures") or nil,
		calls = callsPage and register(callsPage, "Call spells") or nil,
	}
end

-- which: nil = the home page, or "bar", "totems", "buffs", "cures", "calls" (also "icons", the old name of the buffs page)
function ns.openOptions(which)
	if not ns.category then print("ShamanKit: settings panel unavailable on this client.") return end
	local c = (ns.categories and (ns.categories[which] or (which == "icons" and ns.categories.buffs))) or ns.category
	local ok = pcall(Settings.OpenToCategory, c:GetID())
	if not ok then pcall(Settings.OpenToCategory, c) end
end
