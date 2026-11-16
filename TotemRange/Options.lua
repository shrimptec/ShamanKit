-- TotemRange settings: Esc > Options > AddOns > TotemRange, or /totemrange
-- Built from plain Blizzard textures (slider bar/thumb, check box) so it looks like the stock panels.

local ADDON, ns = ...

local function checkbox(parent, label, key, x, y)
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
		ns.get()[key] = on
		PlaySound(on and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_OFF)
		ns.updatePreview()
	end)
	cb.refresh = function() cb:SetChecked(ns.get()[key]) end
	return cb
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
		checkbox(panel, "Show exact distance under each totem", "showDistance", 16, -300),
		checkbox(panel, "Replace the default totem timers (stays under the player frame)", "attach", 16, -330),
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

	local reset = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	reset:SetSize(140, 24)
	reset:SetPoint("TOPLEFT", 16, -520)
	reset:SetText("Reset position")
	reset:SetScript("OnClick", ns.resetPosition)

	-- offsets only matter while attached; dragging only while detached
	local attach, offX, offY = controls[8], controls[9], controls[10]
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
