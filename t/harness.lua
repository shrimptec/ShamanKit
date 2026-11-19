-- Loads the addon against a mocked WoW API and walks through placement / range / preview.
-- Run: luajit t/harness.lua   (from the project root)

local SECRET = {}
local function boom() error("attempt to use a secret value") end
for _, k in ipairs({ "__lt", "__le", "__add", "__sub", "__mul", "__div", "__concat", "__unm", "__call", "__len", "__index", "__newindex" }) do SECRET[k] = boom end
SECRET.__tostring = function() return "<secret>" end
local function secret() return setmetatable({}, SECRET) end
issecretvalue = function(v) return type(v) == "table" and getmetatable(v) == SECRET end
local realPrint, printedErrors = print, {}
print = function(...)
	local line = table.concat({ ... }, " ")
	if line:find("hit an error", 1, true) then printedErrors[#printedErrors + 1] = line end
	realPrint(...)
end
local scripts = {}
REGISTERED = {}
CALLS = setmetatable({}, { __index = function() return 0 end })
local function mock(kind)
	local o = { kind = kind, shown = true, scripts = {}, checked = false, value = 0, attrs = {} }
	return setmetatable(o, { __index = function(t, k)
		-- secure (protected) frames refuse these in combat, exactly like the real client: the popup the user saw
		if rawget(t, "protected") and InCombatLockdown() and (k == "SetPoint" or k == "ClearAllPoints" or k == "SetSize"
			or k == "Show" or k == "Hide" or k == "SetShown" or k == "SetAttribute" or k == "EnableMouse" or k == "SetParent" or k == "StartMoving" or k == "StopMovingOrSizing") then
			return function() error("ADDON_ACTION_BLOCKED: " .. k .. " on a protected frame in combat") end
		end
		if k == "SetAttribute" then return function(self, n, v) self.attrs[n] = v end end
		if k == "RegisterEvent" or k == "RegisterUnitEvent" then return function(self, n) REGISTERED[#REGISTERED + 1] = n; self.registered = self.registered or {}; self.registered[n] = true end end
		if k == "UnregisterEvent" then return function(self, n) if self.registered then self.registered[n] = nil end end end
		if k == "Show" then return function(self) self.shown = true end end
		if k == "Hide" then return function(self) self.shown = false end end
		if k == "SetShown" then return function(self, v) self.shown = v and true or false end end
		if k == "IsShown" then return function(self) return self.shown end end
		if k == "SetScript" then return function(self, n, f) self.scripts[n] = f end end
		if k == "HookScript" then return function(self, n, f) local old = self.scripts[n]; self.scripts[n] = function(...) if old then old(...) end f(...) end end end
		if k == "SetEnabled" then return function(self, v) self.enabled = v end end
		if k == "GetChildren" then return function() return end end
		if k == "SetAlpha" then return function(self, a) self.alpha = a end end
		if k == "GetScript" then return function(self, n) return self.scripts[n] end end
		if k == "GetFrameLevel" then return function() return 1 end end
		if k == "GetChecked" then return function(self) return self.checked end end
		if k == "EnableMouse" then return function(self, v) self.mouse = v end end
		if k == "SetChecked" then return function(self, v) self.checked = v end end
		if k == "SetValue" then return function(self, v) CALLS.SetValue = CALLS.SetValue + 1; self.value = v; if self.scripts.OnValueChanged then self.scripts.OnValueChanged(self, v) end end end
		if k == "SetText" then return function(self, v) CALLS.SetText = CALLS.SetText + 1; self.text = v end end
		if k == "SetTextColor" then return function(self, ...) CALLS.SetTextColor = CALLS.SetTextColor + 1; self.color = { ... } end end
		if k == "SetVertexColor" then return function(self, ...) CALLS.SetVertexColor = CALLS.SetVertexColor + 1; self.color = { ... } end end
		if k == "SetTexture" then return function(self, v) CALLS.SetTexture = CALLS.SetTexture + 1; self.tex = v end end
		if k == "GetNormalTexture" or k == "GetHighlightTexture" or k == "GetCheckedTexture" then return function() return mock("region") end end
		if k == "SetOrientation" then return function(self, v) self.orientation = v end end
		if k == "SetStatusBarColor" then return function(self, ...) self.sbcolor = { ... } end end
		if k == "SetPoint" then return function(self, ...) self.anchor = { ... } end end
		if k == "SetSize" then return function(self, w, h) self.w, self.h = w, h end end
		if k == "SetCooldown" then return function(self, s, d) self.cd = { s, d } end end
		if k == "GetPoint" then return function() return "CENTER", nil, "CENTER", 10, 20 end end
		if k == "CreateTexture" or k == "CreateFontString" then return function() return mock("region") end end
		if type(k) == "string" and k:match("^%u") then return function() end end   -- methods are Capitalised; fields are nil, as on real frames
		return nil
	end })
end

local frames = {}
CONTAINER_FAILS = true    -- a client that has no aura container (the older tests exercise the reading by name that is used then)
LOADED_ADDONS = {}
C_AddOns = { IsAddOnLoaded = function(n) return LOADED_ADDONS[n] end, LoadAddOn = function(n) LOADED_ADDONS[n] = true end }
local function auraButton()
	local b = mock("auraButton")
	rawset(b, "SetIcon", function(self, tex) self.iconTex = tex end)
	rawset(b, "SetApplicationCount", function(self, fs, opts)
		if opts and opts.formatter and BAD_FORMATTER then error("bad options") end
		self.countFS, self.countOpts = fs, opts
	end)
	return b
end
function CreateFrame(kind, name, parent, tmpl)
	if kind == "AuraContainer" and CONTAINER_FAILS then error("Unknown frame type: AuraContainer") end
	local f = mock(kind); f.name = name; f.tmpl = tmpl; f.parentFrame = parent
	if kind == "AuraContainer" then
		rawset(f, "SetUnit", function(self, u) self.unit = u end)
		if not NO_SLOTS then   -- an older client has no such method at all
			rawset(f, "AddAuraSlot", function(self, key, filter, opts)
				self.slots = self.slots or {}
				local b = auraButton(); self.slots[key] = { filter = filter, opts = opts, button = b }
				opts.initializeFrame(b)
				b.sizeAtInit = b.w      -- the real game gives these buttons no size of their own
				return b
			end)
		else
			rawset(f, "AddAuraSlot", false)
		end
		rawset(f, "AddAuraGroup", function(self, key, filter, opts)
			self.groups = self.groups or {}
			self.groups[key] = { filter = filter, opts = opts }
		end)
		rawset(f, "Show", function(self) self.shown = true end)
		rawset(f, "Hide", function(self) self.shown = false end)
		rawset(f, "SetEnabled", function(self, v) self.enabled = v end)
	end
	if tmpl and tmpl:find("Secure") then rawset(f, "protected", true) end
	if name then _G[name] = f end
	frames[#frames + 1] = f
	return f
end
UIParent = mock("UIParent")
PlayerFrame = mock("PlayerFrame")
TotemFrame = mock("TotemFrame"); TotemFrame.alpha = 1
local hooks = {}
function hooksecurefunc(obj, name, fn)
	local orig = obj[name]
	rawset(obj, name, function(self, ...) orig(self, ...); fn(self, ...) end)
end
GameTooltip = mock("tt"); GameTooltip_Hide = function() end
SOUNDKIT = {}; PlaySound = function() end
function unpack_(...) return ... end
unpack = unpack or table.unpack
MAX_TOTEMS = 4
-- spells this pretend client "has": the catalogue ids except 2062, 8170, 8166, 6495, 25908 and 1535 (so the picker's
-- filtering is exercised); Forever's own Fire Nova is 408341
KNOWN_SPELLS = { [5730] = "Stoneclaw Totem", [8071] = "Stoneskin Totem", [2484] = "Earthbind Totem", [8075] = "Strength of Earth Totem",
	[8143] = "Tremor Totem", [3599] = "Searing Totem", [408341] = "Fire Nova", [8190] = "Magma Totem", [8227] = "Flametongue Totem",
	[8181] = "Frost Resistance Totem", [5394] = "Healing Stream Totem", [5675] = "Mana Spring Totem", [8184] = "Fire Resistance Totem",
	[16190] = "Mana Tide Totem", [8177] = "Grounding Totem", [10595] = "Nature Resistance Totem", [8512] = "Windfury Totem",
	[15107] = "Windwall Totem", [8835] = "Grace of Air Totem" }
C_Spell = { GetSpellTexture = function(id) return 100000 + (tonumber(id) or 0) end, GetSpellInfo = function(id)
	if KNOWN_SPELLS[id] then return { name = KNOWN_SPELLS[id] } end
	if id == 99 then return { name = "Totemic Projection" } end
	if id == 555 then return { name = "Strength of Earth Totem" } end
	if id == 556 then return { name = "Call of the Elements" } end
end }
local t = 1000
function GetTime() return t end
local inCombat = false
function InCombatLockdown() return inCombat end

-- player position + totems
local pos = { y = 100, x = 100, map = 1 }
local secretMode = false   -- emulates combat: totem readings come back secret
local secretPos = false    -- position/aura readings secret too (the real log shows these stay readable in combat)
function UnitPosition() if secretPos then return secret(), secret(), secret(), secret() end if not pos then return end return pos.y, pos.x, 0, pos.map end
-- second source: map position (normalised 0..1, map is 1000x1000 yd) mirrors the unit position
local mapOn = true
C_Map = {
	GetBestMapForUnit = function() return 42 end,
	GetMapWorldSize = function() return 1000, 1000 end,
	GetPlayerMapPosition = function() if secretPos then return secret() end if not mapOn or not pos then return nil end return { GetXY = function() return pos.x / 1000, pos.y / 1000 end } end,
}
local totems = {}
function GetTotemInfo(slot)
	if secretMode == "all" then return secret(), secret(), secret(), secret(), secret() end
	if secretMode and totems[slot] then return true, secret(), secret(), secret(), secret() end
	local d = totems[slot]
	if not d then return false, "", 0, 0, nil end
	return true, d.name, d.start, d.dur, d.icon
end
local auras = {}
C_StringUtil = { CreateNumericRuleFormatter = function() return { FormatNumber = function(_, n) return tostring(n) end } end }
AURAS_HIDDEN = false   -- a fight: the game hides auras
IDAURAS = {}           -- what a lookup by spell id still answers while they are hidden
C_Secrets = { ShouldAurasBeSecret = function() return AURAS_HIDDEN end }
C_UnitAuras = {
	GetAuraDataBySpellName = function(_, name)
		if secretPos then return secret() end
		if AURAS_HIDDEN then return nil end     -- seen in the real log: "nothing", not a secret, even though the aura is there
		return auras[name]
	end,
	-- in a fight (proved by the real log) the data lookups all answer nothing: by name, by id, by index.
	-- Still answered: the list of buff ids (plain numbers) and the count text (a string the addon can't read).
	GetAuraDataByAuraInstanceID = function(_, id) if AURAS_HIDDEN then return nil end return IDAURAS[id] end,
	GetAuraDataByIndex = function(_, i)
		if AURAS_HIDDEN then return nil end
		local list = {}
		for _, d in pairs(IDAURAS) do list[#list + 1] = d end
		table.sort(list, function(a, b) return a.auraInstanceID < b.auraInstanceID end)
		return list[i]
	end,
	GetUnitAuraInstanceIDs = function()
		if IDLIST_FAILS then error("blocked") end
		local list = {}
		for id in pairs(IDAURAS) do list[#list + 1] = id end
		for _, id in ipairs(EXTRA_IDS or {}) do list[#list + 1] = id end
		table.sort(list)
		return list
	end,
	GetAuraApplicationDisplayCount = function(_, id, minCount, maxCount)
		if COUNT_FAILS then error("blocked") end
		local d = IDAURAS[id]
		if not d then error("invalid aura instance") end
		CALLED_COUNT = { id = id, min = minCount, max = maxCount }
		if COUNT_SECRET then return secret() end
		local n = d.applications or 0
		if n < (minCount or 2) then return "" end
		if n > (maxCount or 99) then return "*" end
		return tostring(n)
	end,
}


local savedCat
local allCats = {}
Settings = {
	RegisterCanvasLayoutCategory = function(p, n)
		local id = 7 + #allCats
		local c = { GetID = function() return id end, panel = p, name = n }
		allCats[#allCats + 1] = c
		if not savedCat then savedCat = c end
		return c
	end,
	RegisterCanvasLayoutSubcategory = function(parent, p, n)
		local id = 7 + #allCats
		local c = { GetID = function() return id end, panel = p, name = n, parent = parent }
		allCats[#allCats + 1] = c
		return c
	end,
	RegisterAddOnCategory = function() end,
	OpenToCategory = function(id) savedCat.opened = id end,
}
SlashCmdList = {}
local timers = {}
C_Timer = { After = function(_, fn) timers[#timers + 1] = fn end }
local function runTimers() local t = timers; timers = {}; for _, fn in ipairs(t) do fn() end end

local ns = {}
local function load(file) local f = assert(loadfile(file)); f("ShamanKit", ns) end
load("ShamanKit/ShamanKit.lua")
load("ShamanKit/Options.lua")

local ev
for _, f in ipairs(frames) do if f.scripts.OnEvent then ev = f end end
local function fire(e, ...) ev.scripts.OnEvent(ev, e, ...) end
local function bar() return _G.ShamanKitBar end
local function btn(i) return _G["ShamanKitButton" .. i] end
local function tick() bar().scripts.OnUpdate(bar(), 0.25) end
local fails = 0
local function check(cond, msg) if not cond then fails = fails + 1; print("FAIL: " .. msg) else print("ok:   " .. msg) end end
local function noErrors(msg)
	local bad
	for _, l in ipairs(ShamanKitDB.log or {}) do if l:find("ERROR") then bad = l end end
	check(bad == nil, msg .. (bad and (" -> " .. bad) or ""))
end

fire("ADDON_LOADED", "ShamanKit")
-- The bar is the anchor of the secure click buttons, so the real client treats it as restricted in combat:
-- insecure code may not show, hide, move or resize it then (this is what the "action blocked" popup is about).
rawset(_G.ShamanKitBar, "protected", true)
check(ShamanKitDB and ShamanKitDB.size == 36, "defaults filled")
check(savedCat ~= nil, "settings category registered")
check(#allCats == 4, "settings: a home page and three sub-pages (" .. #allCats .. " registered)")
-- the older checks talk to "the panel": that is now all three pages at once
do
	local pages = {}
	for _, c in ipairs(allCats) do pages[#pages + 1] = c.panel end
	local all = { scripts = {} }
	all.scripts.OnShow = function() for _, p in ipairs(pages) do p.scripts.OnShow() end end
	all.scripts.OnHide = function() for _, p in ipairs(pages) do p.scripts.OnHide() end end
	all.OnRefresh = function() for _, p in ipairs(pages) do p.OnRefresh() end end
	all.OnDefault = function() for _, p in ipairs(pages) do p.OnDefault() end end
	savedCat.pages, savedCat.panel = pages, all
end
fire("PLAYER_ENTERING_WORLD")
check(not bar().anyShown, "bar hidden with no totems while locked")

-- place Strength of Earth in slot 2 at (100,100)
totems[2] = { name = "Strength of Earth Totem IV", start = t, dur = 300, icon = 99 }
fire("PLAYER_TOTEM_UPDATE", 2)
check(btn(2).shown and not btn(1).shown, "slot 2 button shown, slot 1 not")
check(bar().anyShown, "bar shown")
tick(); check(btn(2).mark.tex:find("Ready") and not btn(2).mark.tex:find("NotReady"), "in range at the totem")
check(btn(2).icon.color[1] == 1, "icon untinted in range")

pos = { y = 100, x = 125, map = 1 }; tick()
check(btn(2).mark.tex:find("Ready") and not btn(2).mark.tex:find("NotReady"), "25 yd away still in range (30 yd)")
pos = { y = 100, x = 140, map = 1 }; tick()
check(btn(2).mark.tex:find("NotReady"), "40 yd away is out of range")
check(btn(2).icon.color[1] == 0.8, "icon tinted red out of range")

-- the check and the cross are separate options (out of range right now)
ShamanKitDB.showOut = false; tick()
check(not btn(2).mark.shown, "cross off: nothing drawn out of range")
check(btn(2).icon.color[1] == 0.8, "cross off: red tint still there")
pos = { y = 100, x = 125, map = 1 }; tick()
check(btn(2).mark.shown and btn(2).mark.tex:find("Ready") and not btn(2).mark.tex:find("NotReady"), "cross off: check still drawn in range")
ShamanKitDB.showRange = false; tick()
check(not btn(2).mark.shown, "check off: nothing drawn in range")
pos = { y = 100, x = 140, map = 1 }; tick()
check(not btn(2).mark.shown, "both off: nothing drawn out of range")
ShamanKitDB.showOut = true; tick()
check(btn(2).mark.shown and btn(2).mark.tex:find("NotReady"), "check off, cross on: cross drawn out of range")
pos = { y = 100, x = 125, map = 1 }; tick()
check(not btn(2).mark.shown, "check off, cross on: nothing drawn in range")
ShamanKitDB.showRange = true; tick()
pos = { y = 100, x = 140, map = 1 }; tick()
check(btn(2).mark.shown and btn(2).mark.tex:find("NotReady"), "both back on: cross drawn again")

-- Earthbind (10 yd) in slot 1 at current spot; two buttons laid out side by side
totems[1] = { name = "Earthbind Totem", start = t, dur = 45, icon = 5 }
fire("PLAYER_TOTEM_UPDATE", 1)
check(btn(1).shown and btn(2).shown, "two totems shown")
pos = { y = 100, x = 155, map = 1 }; tick()
check(btn(1).mark.tex:find("NotReady"), "15 yd from Earthbind (10 yd) is out")
check(btn(2).mark.tex:find("NotReady"), "55 yd from Strength of Earth is out")

-- totem expires
totems[1] = nil; fire("PLAYER_TOTEM_UPDATE", 1)
check(not btn(1).shown, "expired totem hidden")

-- position unavailable (instance) -> buff fallback for a buff totem
pos = nil
auras["Strength of Earth"] = nil; tick()
check(btn(2).mark.tex:find("NotReady"), "no position, no buff -> out of range")
auras["Strength of Earth"] = {}; tick()
check(btn(2).mark.tex:find("Ready") and not btn(2).mark.tex:find("NotReady"), "no position, buff present -> in range")
inCombat = true
local realAura = C_UnitAuras.GetAuraDataBySpellName
C_UnitAuras.GetAuraDataBySpellName = function() error("restricted") end
tick()
check(btn(2).mark.shown and btn(2).mark.tex:find("Waiting"), "no position and no buff reading -> yellow ? (unknown), not blank")
C_UnitAuras.GetAuraDataBySpellName = realAura
C_UnitAuras.GetAuraDataBySpellName = realAura
inCombat = false
-- a fight hides auras: the lookup says "nothing" although the buff is there. That is not "out of range".
auras["Strength of Earth"] = {}; AURAS_HIDDEN = true; inCombat = true; tick()
check(btn(2).mark.shown and btn(2).mark.tex:find("Waiting") and not btn(2).mark.tex:find("NotReady"), "REPORTED CLASS: no position, auras hidden in a fight, buff present: yellow ?, never 'out of range'")
AURAS_HIDDEN = false; inCombat = false; tick()
check(btn(2).mark.tex:find("Ready") and not btn(2).mark.tex:find("NotReady"), "fight over: the buff reading is trusted again")

-- Totemic Call: walk out of range, cast it, totems follow you
totems[2] = { name = "Strength of Earth Totem IV", start = t, dur = 300, icon = 99 }
pos = { y = 100, x = 100, map = 1 }; fire("PLAYER_TOTEM_UPDATE", 2)
pos = { y = 100, x = 160, map = 1 }; tick()
check(btn(2).mark.tex:find("NotReady"), "walked 60 yd away: red")
fire("UNIT_SPELLCAST_SUCCEEDED", "player", "guid", 437009); tick()
check(btn(2).mark.tex:find("Ready") and not btn(2).mark.tex:find("NotReady"), "Totemic Call (id 437009) brings the totems to you: in range")
pos = { y = 100, x = 230, map = 1 }; tick()
check(btn(2).mark.tex:find("NotReady"), "walking away again after the call: red")
fire("UNIT_SPELLCAST_SUCCEEDED", "player", "guid", 99); tick()
check(btn(2).mark.tex:find("Ready") and not btn(2).mark.tex:find("NotReady"), "recognised by name too")
fire("UNIT_SPELLCAST_SUCCEEDED", "player", "guid", 12345); pos = { y = 100, x = 400, map = 1 }; tick()
check(btn(2).mark.tex:find("NotReady"), "other spells don't move the totems")
pos = { y = 100, x = 100, map = 1 }

-- laying the same totems down again somewhere else (no totem event, new start time)
totems[2] = { name = "Strength of Earth Totem IV", start = t, dur = 300, icon = 99 }
pos = { y = 100, x = 100, map = 1 }; fire("PLAYER_TOTEM_UPDATE", 2)
pos = { y = 100, x = 200, map = 1 }; tick()
check(btn(2).mark.tex:find("NotReady"), "100 yd from the totem: red")
t = t + 20
totems[2] = { name = "Strength of Earth Totem IV", start = t, dur = 300, icon = 99 }   -- re-dropped here, no event
tick()
check(btn(2).mark.tex:find("Ready") and not btn(2).mark.tex:find("NotReady"), "re-dropped without an event: in range at the new spot")
pos = { y = 100, x = 100, map = 1 }; tick()
check(btn(2).mark.tex:find("NotReady"), "and the OLD spot is now out of range")

-- right-click dismiss: a secure button per slot with the built-in destroytotem action
local hit2 = _G.ShamanKitHit2
check(hit2 and hit2.tmpl == "SecureActionButtonTemplate", "slot buttons are secure action buttons")
check(hit2.attrs["*type2"] == "destroytotem" and hit2.attrs["totem-slot"] == 2, "right-click is the built-in destroytotem action for that slot")
check(hit2.attrs["type1"] == nil and hit2.attrs["*type1"] == nil, "left-click does nothing")
check(hit2.mouse == true, "a shown totem's button takes clicks")
check(_G.ShamanKitHit1.mouse == false and _G.ShamanKitHit4.mouse == false, "empty slots' buttons don't block the mouse")
check(hit2.scripts.OnClick == nil, "no insecure OnClick (that is what the game blocked)")

-- IN COMBAT (flag hidden, name/start/icon hidden, position readable - as the real log showed)
function GetTotemDuration(slot) if totems[slot] then return {} end return nil end
C_Spell.GetSpellInfo = (function(orig) return function(id)
	if id == 557 then return { name = "Earthbind Totem" } end
	return orig(id)
end end)(C_Spell.GetSpellInfo)
pos = { y = 100, x = 100, map = 1 }; fire("PLAYER_TOTEM_UPDATE", 2)
secretMode = "all"; inCombat = true
pos = { y = 100, x = 200, map = 1 }; tick()
check(btn(2).mark.tex:find("NotReady"), "combat: 100 yd from the totem: red (position is still readable)")
-- re-drop in combat: the totem event arrives with every reading hidden
fire("PLAYER_TOTEM_UPDATE", 2); tick()
check(btn(2).mark.tex:find("Ready") and not btn(2).mark.tex:find("NotReady"), "combat: re-dropped, position recorded straight away (not after the fight)")
-- a totem placed from empty in combat, named by the cast because the name is hidden
totems[3] = { name = "Earthbind Totem", start = t, dur = 45, icon = 5 }
fire("UNIT_SPELLCAST_SUCCEEDED", "player", "g", 557)
fire("PLAYER_TOTEM_UPDATE", 3); runTimers(); tick()
check(btn(3).shown, "combat: totem placed in combat appears")
pos = { y = 100, x = 215, map = 1 }; tick()
check(btn(3).mark.tex:find("NotReady"), "combat: 15 yd from Earthbind is out (10 yd radius known from the cast)")
check(btn(2).mark.tex:find("Ready") and not btn(2).mark.tex:find("NotReady"), "combat: Strength of Earth 15 yd away still in (30 yd)")
-- expires during combat
totems[3] = nil; tick()
check(not btn(3).shown, "combat: expired totem disappears without waiting for the fight to end")
check(hit2.mouse == true, "combat: nothing touched the protected buttons (no ADDON_ACTION_BLOCKED)")
-- a totem placed in combat appears; its button stays unclickable until combat ends
totems[3] = { name = "Searing Totem III", start = t, dur = 60, icon = 7 }
fire("PLAYER_TOTEM_UPDATE", 3)
check(btn(3).shown and _G.ShamanKitHit3.mouse == false, "combat: new totem visible, its button not yet clickable")
noErrors("combat with protected frames locked: no blocked actions in the log")
secretMode = false; inCombat = false
fire("PLAYER_REGEN_ENABLED"); tick()
check(btn(2).shown and btn(3).shown, "combat over: resync keeps the live totems")
check(_G.ShamanKitHit3.mouse == true and _G.ShamanKitHit2.mouse == true and _G.ShamanKitHit4.mouse == false, "combat over: clickable exactly where totems are")
totems[3] = nil; fire("PLAYER_TOTEM_UPDATE", 3)

-- unit position blocked, map position works (e.g. in combat): distance still comes out
totems[3] = { name = "Searing Totem III", start = t, dur = 60, icon = 7 }
pos = { y = 500, x = 500, map = 1 }; fire("PLAYER_TOTEM_UPDATE", 3)
local realUP = UnitPosition
UnitPosition = function() return nil end
pos = { y = 500, x = 505, map = 1 }; tick()
check(btn(3).mark.tex:find("Ready") and not btn(3).mark.tex:find("NotReady"), "map source: 5 yd from Searing is in range")
pos = { y = 500, x = 540, map = 1 }; tick()
check(btn(3).mark.tex:find("NotReady"), "map source: 40 yd from Searing is out")
mapOn = false; tick()
check(btn(3).mark.tex:find("Waiting"), "both sources blocked -> ? not a stale answer")
mapOn = true; UnitPosition = realUP
totems[3] = nil; fire("PLAYER_TOTEM_UPDATE", 3)
pos = nil

-- reload: slot still has a totem but we never saw it placed -> unknown position, aura only
for k in pairs(totems) do if k ~= 2 then totems[k] = nil end end
fire("PLAYER_ENTERING_WORLD")
check(btn(2).shown, "totem present after reload is shown")
pos = { y = 0, x = 0, map = 1 }; auras["Strength of Earth"] = nil; tick()
check(btn(2).mark.tex:find("NotReady"), "after reload falls back to buff (absent -> out)")

-- settings: preview while open, changes apply
local panel = savedCat.panel
-- real totems win over the samples: panel open with a real totem out shows ONLY the real one
panel.scripts.OnShow()
check(btn(2).shown and not btn(1).shown and not btn(4).shown, "panel open + real totem out: real totem only, no sample totems")
panel.scripts.OnHide()
local saved2 = totems[2]; totems[2] = nil; fire("PLAYER_TOTEM_UPDATE", 2)
panel.scripts.OnShow()
check(btn(1).shown and btn(4).shown, "preview shows 4 sample totems with the panel open")
ShamanKitDB.size = 50; panel.OnRefresh(); 
local sl
for _, f in ipairs(frames) do if f.kind == "Slider" and f.scripts.OnValueChanged then sl = f; break end end
sl.scripts.OnValueChanged(sl, 60)
check(ShamanKitDB.size == 60 and btn(1).w == 60, "size slider resizes icons")
check(bar().w == 4 * 60 + 3 * 4, "bar width fits 4 icons + spacing")
ShamanKitDB.vertical = true; ns.updatePreview()
check(bar().h == 4 * 60 + 3 * 4 and bar().w == 60, "vertical layout swaps the axis")
-- a real totem appears while the samples are up: samples go, the real one is tracked from this spot
pos = { y = 10, x = 10, map = 1 }
totems[2] = saved2; fire("PLAYER_TOTEM_UPDATE", 2)
check(btn(2).shown and not btn(1).shown and not btn(4).shown, "totem placed while samples show: samples replaced by the real totem")
pos = { y = 10, x = 70, map = 1 }; tick()
check(btn(2).mark.tex:find("NotReady"), "...and it measures range from where it was placed")
-- it expires with the panel still open: samples return
totems[2] = nil; fire("PLAYER_TOTEM_UPDATE", 2)
check(btn(1).shown and btn(4).shown, "last real totem gone with the panel open: samples return")
panel.scripts.OnHide()
check(not btn(1).shown and not btn(2).shown, "closing panel with no totems: bar empty")
totems[2] = saved2

-- attach to the player frame: replaces Blizzard's timers
local pts = {}
local origSetPoint = bar().SetPoint
bar().SetPoint = function(self, ...) pts[#pts + 1] = { ... } end
local att
for _, f in ipairs(frames) do if f.text == "Replace the default totem timers (stays under the player frame)" then att = f end end
for _, f in ipairs(frames) do if f.kind == "CheckButton" and f.scripts.OnClick then end end
ShamanKitDB.attach = true; ns.updatePreview()
check(TotemFrame.alpha == 0, "Blizzard totem timers made invisible when attached")
local last = pts[#pts]
check(last[1] == "TOPLEFT" and last[2] == PlayerFrame and last[3] == "BOTTOMLEFT" and last[4] == 65, "bar anchored under the player frame")
TotemFrame:SetAlpha(1)
check(TotemFrame.alpha == 0, "Blizzard re-showing its frame is undone")
ShamanKitDB.attach = false; ns.updatePreview()
check(TotemFrame.alpha == 1, "Blizzard timers restored when detached")
check(pts[#pts][2] == UIParent, "bar back on its saved screen position")

-- exact distance under each totem
pos = { y = 100, x = 100, map = 1 }; fire("PLAYER_ENTERING_WORLD"); fire("PLAYER_TOTEM_UPDATE", 2)
pos = { y = 100, x = 112.4, map = 1 }
ShamanKitDB.distanceMode = "off"; tick()
check(not btn(2).dist.shown, "distance hidden when the option is off")
ShamanKitDB.distanceMode = "yards"; tick()
check(btn(2).dist.shown and btn(2).dist.text == "12.4 yd", "shows 12.4 yd: " .. tostring(btn(2).dist.text))
pos = { y = 100, x = 145, map = 1 }; tick()
check(btn(2).dist.text == "45.0 yd" and btn(2).dist.color[1] > 0.9 + 0 - 0.0 , "45 yd, red when out of range")
pos = nil; tick()
check(not btn(2).dist.shown, "no distance shown when only the buff is known")
ShamanKitDB.distanceMode = "off"

SlashCmdList.SHAMANKIT("unlock")
check(ShamanKitDB.locked == false and bar().anyShown, "/totemrange unlock shows the frame")
-- the exact bug from the field: left unlocked, real totems must still be tracked (not replaced by samples)
fire("PLAYER_ENTERING_WORLD"); pos = { y = 5, x = 5, map = 1 }; fire("PLAYER_TOTEM_UPDATE", 2)
pos = { y = 5, x = 80, map = 1 }; ShamanKitDB.distanceMode = "yards"; tick()
check(btn(2).shown and not btn(1).shown and not btn(3).shown, "unlocked with a real totem out: only the real totem shows")
check(btn(2).dist.text == "75.0 yd" and btn(2).mark.tex:find("NotReady"), "unlocked: real distance (75.0 yd) and red, not sample numbers")
ShamanKitDB.distanceMode = "off"
-- Totemic Recall while unlocked: every totem goes, nothing fake appears in its place
local keep = totems
totems = {}
for slot = 1, 4 do fire("PLAYER_TOTEM_UPDATE", slot) end
check(not btn(1).shown and not btn(2).shown and not btn(3).shown and not btn(4).shown, "Totemic Recall (unlocked): no icons at all, no placeholders")
check(not bar().anyShown, "...and nothing else on screen: no drag box, bar hidden")
SlashCmdList.SHAMANKIT("lock")
check(not bar().anyShown, "locked and no totems: nothing on screen")
SlashCmdList.SHAMANKIT("unlock")
totems = keep
pos = { y = 5, x = 5, map = 1 }; fire("PLAYER_TOTEM_UPDATE", 2)
check(btn(2).shown and bar().anyShown, "new totem: the real icon shows")
SlashCmdList.SHAMANKIT("lock")
SlashCmdList.SHAMANKIT("")
check(savedCat.opened == 7, "/totemrange opens the settings")
SlashCmdList.SHAMANKIT("status")

-- ---- a totem that is out but whose event never reached us (the "nothing showed, then it came back" bug)
do
	local function rescan() ev.scripts.OnUpdate(ev, 0.6) end
	totems = {}; secretMode = false; inCombat = false
	for slot = 1, 4 do fire("PLAYER_TOTEM_UPDATE", slot) end
	check(not bar().anyShown, "rescan setup: empty bar is hidden (so its own tick is not running)")
	totems = { [3] = { name = "Windfury Totem", start = t, dur = 300, icon = 8 } }   -- placed, NO event fired
	pos = { y = 0, x = 0, map = 1 }
	rescan()
	check(btn(3).shown and bar().anyShown, "missed event: the rescan shows the totem anyway")
	local logged = false
	for _, line in ipairs(ShamanKitDB.log or {}) do if line:find("RESCAN found slot 3") then logged = true end end
	check(logged, "...and logs that it caught a missed event")
	-- it must not invent a position: with none recorded the mark is the unknown one, never a green "in range"
	check(not btn(3).mark.tex:find("Ready") or btn(3).mark.tex:find("NotReady"), "...with unknown range, not a guessed green tick")
	totems = {}
	for slot = 1, 4 do fire("PLAYER_TOTEM_UPDATE", slot) end
	rescan()
	check(not btn(3).shown and not bar().anyShown, "totem gone: the rescan does not bring it back")
	-- and while the preview is on it leaves the samples alone
	totems = { [1] = { name = "Searing Totem III", start = t, dur = 60, icon = 7 } }
	rescan(); for slot = 1, 4 do fire("PLAYER_TOTEM_UPDATE", slot) end
	totems = {}
end

-- ---- combat: every reading is secret. Nothing may raise, the log must hold no ERROR, marks must say "?"
noErrors("no errors logged during the whole normal run")

for _, mode in ipairs({ true, "all" }) do
	local label = mode == "all" and "everything secret (incl. 'have')" or "have visible, name/start/icon/position secret"
	totems = { [1] = { name = "Searing Totem III", start = t, dur = 60, icon = 7 }, [2] = { name = "Windfury Totem", start = t, dur = 300, icon = 8 } }
	secretMode = false; pos = { y = 0, x = 0, map = 1 }
	fire("PLAYER_ENTERING_WORLD"); fire("PLAYER_TOTEM_UPDATE", 1); fire("PLAYER_TOTEM_UPDATE", 2)
	secretMode = mode; secretPos = true; inCombat = true
	local ok, err = pcall(function()
		fire("PLAYER_TOTEM_UPDATE", 1)
		fire("PLAYER_TOTEM_UPDATE", secret())
		fire("UNIT_SPELLCAST_SUCCEEDED", "player", "g", secret()); runTimers()
		fire("UNIT_SPELLCAST_SUCCEEDED", "player", "g", 555); runTimers()
		fire("PLAYER_REGEN_DISABLED"); fire("PLAYER_REGEN_ENABLED")
		fire("PLAYER_ENTERING_WORLD")
		for _ = 1, 3 do tick() end
		ShamanKitDB.distanceMode = "yards"; tick(); ShamanKitDB.distanceMode = "off"
		SlashCmdList.SHAMANKIT("status")
		if btn(1).scripts.OnEnter then btn(1).scripts.OnEnter(btn(1)) end
	end)
	check(ok, label .. ": nothing raises" .. (ok and "" or (" -> " .. tostring(err))))
	noErrors(label .. ": nothing in the error log")
	secretMode = false; secretPos = false; inCombat = false
end


-- ---- the range bar (default): how much room is left inside the totem's radius
do
	local function g(slot) return btn(slot).gauge end
	local function near(a, b) return math.abs(a - b) < 0.03 end
	totems = { [2] = { name = "Strength of Earth Totem II", start = t, dur = 300, icon = 8 } }   -- radius 30
	secretMode = false; secretPos = false; inCombat = false
	ShamanKitDB.distanceMode = nil; ShamanKitDB.vertical = false
	pos = { y = 0, x = 0, map = 1 }
	fire("PLAYER_ENTERING_WORLD"); fire("PLAYER_TOTEM_UPDATE", 2); tick()
	check(ns.distMode() == "bar", "the bar is the default (and what an unset value means)")
	check(g(2).shown and near(g(2).value, 1) and g(2).sbcolor[2] > 0.7 and g(2).sbcolor[1] < 0.3, "standing on the totem: full green bar")
	check(not btn(2).dist.shown, "bar mode: no yards text")
	pos = { y = 0, x = 20, map = 1 }; tick()
	check(near(g(2).value, 1 / 3) and g(2).sbcolor[1] > 0.9 and g(2).sbcolor[2] > 0.7, "20 of 30 yd: a third left, yellow")
	pos = { y = 0, x = 25, map = 1 }; tick()
	check(near(g(2).value, 1 / 6) and g(2).sbcolor[1] > 0.9 and g(2).sbcolor[2] < 0.5, "25 of 30 yd: nearly out, orange")
	check(g(2).edge.color[1] < 0.3, "...frame still dark while in range")
	pos = { y = 0, x = 31, map = 1 }; tick()
	check(g(2).value == 0 and g(2).edge.color[1] > 0.7 and g(2).edge.color[2] < 0.3, "31 yd: empty bar with a red frame")
	pos = { y = 0, x = 200, map = 1 }; tick()
	check(g(2).value == 0 and g(2).shown, "far away: still just empty (never negative, never beyond)")
	pos = { y = 0, x = 0, map = 1 }; tick()
	check(near(g(2).value, 1) and g(2).edge.color[1] < 0.3, "back on it: full again, frame dark again")
	pos = nil; tick()
	check(not g(2).shown, "position unknown (only the buff to go on): no bar at all, the mark says it")
	pos = { y = 0, x = 0, map = 1 }; tick()
	check(g(2).shown, "...and it returns when the position does")
	-- modes
	ShamanKitDB.distanceMode = "yards"; ns.updatePreview(); pos = { y = 0, x = 12.4, map = 1 }; tick()
	check(not g(2).shown and btn(2).dist.shown and btn(2).dist.text == "12.4 yd", "yards mode: the number, no bar")
	ShamanKitDB.distanceMode = "off"; ns.updatePreview(); tick()
	check(not g(2).shown and not btn(2).dist.shown, "off: neither")
	ShamanKitDB.distanceMode = "bar"; ns.updatePreview(); tick()
	check(g(2).shown and not btn(2).dist.shown, "back to the bar: bar only")
	ShamanKitDB.distanceMode = "garbage"
	check(ns.distMode() == "bar", "a damaged setting means the bar")
	ShamanKitDB.distanceMode = "bar"
	-- layout direction and size
	check(g(2).orientation == "HORIZONTAL", "horizontal bar: the range bar runs left to right under the icon")
	ShamanKitDB.vertical = true; ns.apply(); tick()
	check(g(2).orientation == "VERTICAL", "vertical bar: the range bar stands on the icon's right side")
	ShamanKitDB.vertical = false; ns.apply()
	-- the settings radio buttons
	local radios = {}
	for _, f in ipairs(frames) do if (f.value == "bar" or f.value == "yards" or f.value == "off") and f.scripts.OnClick and f.parentFrame == savedCat.pages[2] then radios[f.value] = f end end
	check(radios.bar and radios.yards and radios.off, "settings: three choices (range bar, exact yards, nothing)")
	radios.yards.scripts.OnClick(radios.yards)
	check(ShamanKitDB.distanceMode == "yards" and radios.yards.checked and not radios.bar.checked, "clicking 'Exact yards' selects it and unticks the others")
	radios.off.scripts.OnClick(radios.off); radios.bar.scripts.OnClick(radios.bar)
	check(ShamanKitDB.distanceMode == "bar" and radios.bar.checked and not radios.off.checked, "clicking 'Range bar' selects it")
	-- the preview while the settings are open and nothing is out: four different fills so the look can be judged
	totems = {}; fire("PLAYER_TOTEM_UPDATE", 2); ns.optionsOpen = true; ns.updatePreview()
	check(near(g(1).value, 0.69) and near(g(2).value, 0.51) and g(3).value == 0 and near(g(4).value, 0.25),
		("preview: Searing 0.69, Strength 0.51, one empty, one nearly out (%.2f %.2f %.2f %.2f)"):format(g(1).value, g(2).value, g(3).value, g(4).value))
	check(g(3).edge.color[1] > 0.7, "preview: the out-of-range sample has the red frame")
	ns.optionsOpen = false; ns.updatePreview()
	check(not g(1).shown and not g(2).shown and not g(3).shown and not g(4).shown, "settings closed, no totems: no bars left behind")
	ShamanKitDB.distanceMode = "off"
end

-- ---- keeping a place open for an element: the gap (a dim placeholder) shows which totem is missing
do
	local holders = {}
	for _, f in ipairs(frames) do if f.kind == "Frame" and f.icon and f.border and not f.name then holders[#holders + 1] = f end end
	check(#holders == 4, "one placeholder per element")
	local function X(f) return f.anchor and f.anchor[4] end
	local function Y(f) return f.anchor and f.anchor[5] end
	local function hit(slot) return _G["ShamanKitHit" .. slot] end
	local gap = ShamanKitDB.size + ShamanKitDB.spacing
	local function out() totems = {}; for slot = 1, 4 do fire("PLAYER_TOTEM_UPDATE", slot) end end
	local function put(slot, name) totems[slot] = { name = name, start = t, dur = 300, icon = 8 }; fire("PLAYER_TOTEM_UPDATE", slot) end
	ShamanKitDB.order = { 2, 1, 3, 4 }; ShamanKitDB.vertical = false; ShamanKitDB.distanceMode = "off"
	secretMode = false; secretPos = false; inCombat = false; pos = { y = 0, x = 0, map = 1 }
	fire("PLAYER_ENTERING_WORLD"); out()

	-- off by default: nothing changes
	ShamanKitDB.reserve = nil; ns.fixReserve()
	put(1, "Searing Totem III")
	check(not holders[1].shown and not holders[2].shown and not holders[3].shown and not holders[4].shown, "default: no placeholders")
	check(X(btn(1)) == 0 and bar().w == ShamanKitDB.size, "default: a lone totem sits first, the bar is one icon wide")

	-- reserve earth and air, fire is out
	ShamanKitDB.reserve = { [2] = true, [4] = true }; ns.apply()
	check(holders[2].shown and holders[4].shown and not holders[1].shown and not holders[3].shown, "earth and air reserved: their placeholders show, fire and water's do not")
	check(X(holders[2]) == 0 and X(btn(1)) == gap and X(holders[4]) == 2 * gap, "...earth first, fire in its place, air third (water takes no space)")
	check(bar().w == 3 * ShamanKitDB.size + 2 * ShamanKitDB.spacing, "...the bar is three icons wide")
	check(hit(1).mouse == true and hit(2).mouse == false and hit(4).mouse == false, "only the real totem is clickable, placeholders never block the mouse")

	-- an earth totem comes down: it fills its place, the placeholder goes
	pos = { y = 0, x = 0, map = 1 }; put(2, "Strength of Earth Totem II")
	check(not holders[2].shown and btn(2).shown and X(btn(2)) == 0, "earth totem placed: it fills the first place, its placeholder is gone")
	check(holders[4].shown and X(holders[4]) == 2 * gap, "...air still marked as missing")
	-- it expires: the place stays
	totems[2] = nil; fire("PLAYER_TOTEM_UPDATE", 2)
	check(holders[2].shown and X(holders[2]) == 0 and X(btn(1)) == gap, "earth expires: the place stays open and fire does not slide over")

	-- nothing out at all: nothing drawn
	out()
	check(not bar().anyShown and not holders[2].shown and not holders[4].shown, "no totems out at all: no placeholders either")

	-- a reserved totem that appears mid-fight lands exactly in its place (and nothing protected is touched)
	put(1, "Searing Totem III")
	inCombat = true; put(4, "Windfury Totem")
	check(btn(4).shown and X(btn(4)) == 2 * gap and not holders[4].shown, "mid-fight: the air totem appears in air's own place")
	inCombat = false; fire("PLAYER_REGEN_ENABLED")
	check(hit(4).mouse == true and X(hit(4)) == 2 * gap, "after the fight it is clickable there")

	-- all four reserved
	out(); put(3, "Mana Spring Totem")
	ShamanKitDB.reserve = { [1] = true, [2] = true, [3] = true, [4] = true }; ns.apply()
	check(holders[2].shown and holders[1].shown and holders[4].shown and not holders[3].shown and X(btn(3)) == 2 * gap, "all four reserved: water out, the other three marked, nothing moves")

	-- vertical keeps the same order down the bar
	ShamanKitDB.vertical = true; ns.apply()
	check(Y(holders[2]) == 0 and Y(holders[1]) == -gap and Y(btn(3)) == -2 * gap and Y(holders[4]) == -3 * gap, "vertical: the same places, top to bottom")
	ShamanKitDB.vertical = false; ns.apply()

	-- the settings preview: a reserved element shows its placeholder instead of a sample
	out(); ShamanKitDB.reserve = { [3] = true }; ns.optionsOpen = true; ns.updatePreview()
	check(holders[3].shown and not btn(3).shown and btn(1).shown and btn(2).shown and btn(4).shown, "settings preview: water reserved shows as an empty place, the others as samples")
	ShamanKitDB.reserve = {}; ns.apply()
	check(not holders[3].shown and btn(3).shown, "...and unticking it brings the sample back")
	ShamanKitDB.reserve = { [1] = true, [2] = true, [3] = true, [4] = true }; ns.apply()
	check(holders[1].shown and holders[2].shown and holders[3].shown and holders[4].shown, "preview with everything reserved: four empty places")
	ns.optionsOpen = false; ns.updatePreview()
	check(not holders[1].shown and not holders[2].shown and not bar().anyShown, "settings closed, nothing out: no placeholders")

	-- the four boxes in the settings
	local boxes = {}
	for _, f in ipairs(frames) do if f.rowIndex and f.kind == "CheckButton" and f.scripts.OnClick then boxes[ns.fixOrder()[f.rowIndex]] = f end end
	check(boxes[1] and boxes[2] and boxes[3] and boxes[4], "settings: a box for each element")
	ShamanKitDB.reserve = {}
	boxes[3].checked = true; boxes[3].scripts.OnClick(boxes[3])
	check(ShamanKitDB.reserve[3] == true and not ShamanKitDB.reserve[2], "ticking Water reserves water only")
	boxes[3].checked = false; boxes[3].scripts.OnClick(boxes[3])
	check(ShamanKitDB.reserve[3] == nil, "unticking it clears it")
	ShamanKitDB.reserve = { [2] = true }; savedCat.panel.OnRefresh()
	check(boxes[2].checked == true and not boxes[1].checked, "the boxes show the saved state when the panel opens")
	savedCat.panel.OnDefault()
	check(next(ShamanKitDB.reserve) == nil, "Defaults clears them")

	-- damaged saved data
	for label, bad in pairs({ ["a string"] = "x", ["yes/no text"] = { [2] = "yes", [3] = 0 }, ["a number"] = 7 }) do
		ShamanKitDB.reserve = bad
		fire("PLAYER_ENTERING_WORLD"); ns.fixReserve()
		local r = ShamanKitDB.reserve
		check(type(r) == "table" and r[2] == nil and r[3] == nil, "damaged reserve (" .. label .. ") is cleaned")
	end
	ShamanKitDB.reserve = {}; ShamanKitDB.distanceMode = "off"; ns.apply(); out()
end

-- ---- removing totems one by one (right-click), the last one included, in and out of a fight
do
	local function out() totems = {}; for slot = 1, 4 do fire("PLAYER_TOTEM_UPDATE", slot) end end
	secretMode = false; secretPos = false; pos = { y = 0, x = 0, map = 1 }
	for _, fight in ipairs({ false, true }) do
		inCombat = false; out()
		for slot = 1, 4 do totems[slot] = { name = "Windfury Totem", start = t, dur = 300, icon = 8 }; fire("PLAYER_TOTEM_UPDATE", slot) end
		inCombat = fight
		local before = #printedErrors
		for _, slot in ipairs({ 2, 1, 3, 4 }) do
			totems[slot] = nil; fire("PLAYER_TOTEM_UPDATE", slot); tick()
		end
		runTimers()
		check(not btn(1).shown and not btn(2).shown and not btn(3).shown and not btn(4).shown,
			(fight and "in a fight: " or "out of a fight: ") .. "every totem removed one by one, all icons gone")
		check(#printedErrors == before, (fight and "in a fight: " or "out of a fight: ") .. "removing the last one raises nothing / touches nothing restricted")
		inCombat = false; fire("PLAYER_REGEN_ENABLED")
	end
	out()
end

-- ---- if the game ever does block something, it is written to the log with where it came from
do
	local function lastLog() local l = ShamanKitDB.log; return l[#l] end
	fire("ADDON_ACTION_BLOCKED", "SomeOtherAddon", "Frame:Hide()")
	check(not (lastLog() or ""):find("ACTION_BLOCKED"), "a block caused by another addon is not logged as ours")
	local before = #printedErrors
	fire("ADDON_ACTION_BLOCKED", "ShamanKit", "ShamanKitBar:Hide()")
	check((lastLog() or ""):find("ADDON_ACTION_BLOCKED: ShamanKitBar:Hide()", 1, true), "our blocked action is logged with the function name")
	check(#printedErrors == before, "...and logging it raises nothing")
end

-- ---- what the dim placeholder shows: a locked totem, else the last totem that was out there, else a generic one
do
	local holders = {}
	for _, f in ipairs(frames) do if f.kind == "Frame" and f.icon and f.border and not f.name then holders[#holders + 1] = f end end
	local TEX = function(id) return 100000 + id end
	local function out() totems = {}; for slot = 1, 4 do fire("PLAYER_TOTEM_UPDATE", slot) end end
	local function put(slot, name, icon) totems[slot] = { name = name, start = t, dur = 300, icon = icon }; fire("PLAYER_TOTEM_UPDATE", slot) end
	ShamanKitDB.order = { 2, 1, 3, 4 }; ShamanKitDB.vertical = false; ShamanKitDB.distanceMode = "off"
	ShamanKitDB.hold = nil; ShamanKitDB.rememberLast = true; ShamanKitDB.reserve = { [2] = true, [3] = true }
	secretMode = false; secretPos = false; inCombat = false; pos = { y = 0, x = 0, map = 1 }
	fire("PLAYER_ENTERING_WORLD"); out(); ns.fixHold()
	put(1, "Searing Totem III", 777)   -- keeps the bar up while the others come and go
	check(holders[2].tex == TEX(8071) and holders[3].tex == TEX(5394), "nothing remembered yet: the generic totem of the element (Stoneskin for earth, Healing Stream for water)")

	-- remembers the last totem seen in that place
	put(2, "Strength of Earth Totem II", 888); totems[2] = nil; fire("PLAYER_TOTEM_UPDATE", 2)
	check(ShamanKitDB.hold.last[2] == 888 and holders[2].shown and holders[2].tex == 888, "an earth totem came and went: the placeholder is its icon")
	put(2, "Stoneskin Totem", 999); totems[2] = nil; fire("PLAYER_TOTEM_UPDATE", 2)
	check(holders[2].tex == 999, "a different earth totem next time: the placeholder follows the newest one")
	check(holders[3].tex == TEX(5394), "...water, never seen, stays generic")

	-- remembering switched off
	ShamanKitDB.rememberLast = false; ns.updatePreview()
	check(holders[2].tex == TEX(8071), "remembering off: back to the generic icon")
	check(ShamanKitDB.hold.last[2] == 999, "...but it kept remembering underneath")
	ShamanKitDB.rememberLast = true; ns.updatePreview()
	check(holders[2].tex == 999, "remembering on again: straight back to what it knew")

	-- a locked choice beats the memory and survives new totems
	ShamanKitDB.hold.choice[2] = 8075; ns.updatePreview()
	check(holders[2].tex == TEX(8075), "locked to Strength of Earth: that icon, not the remembered one")
	put(2, "Stoneskin Totem", 555); totems[2] = nil; fire("PLAYER_TOTEM_UPDATE", 2)
	check(holders[2].tex == TEX(8075) and ShamanKitDB.hold.last[2] == 555, "...it stays locked while new totems are still remembered underneath")
	ShamanKitDB.rememberLast = false; ns.updatePreview()
	check(holders[2].tex == TEX(8075), "...and locking works with remembering off")
	ShamanKitDB.hold.choice[2] = nil; ShamanKitDB.rememberLast = true; ns.updatePreview()
	check(holders[2].tex == 555, "unlocked: the memory shows again")
	ShamanKitDB.hold.choice[2] = 123456789   -- a totem this client does not know: texture lookup still answers in the mock, so use a real miss
	local realTex = C_Spell.GetSpellTexture
	C_Spell.GetSpellTexture = function(id) if id == 123456789 then return nil end return realTex(id) end
	ns.updatePreview()
	check(holders[2].tex == 555, "a locked totem with no icon in this client falls back to the memory instead of showing nothing")
	C_Spell.GetSpellTexture = realTex; ShamanKitDB.hold.choice[2] = nil

	-- in a fight the game hides the icon: the name taken from the cast stands in
	out(); put(1, "Searing Totem III", 777)
	secretMode = true; inCombat = true
	fire("UNIT_SPELLCAST_SUCCEEDED", "player", "g", 5675)   -- Mana Spring Totem cast
	totems[3] = { name = "Mana Spring Totem", start = t, dur = 300, icon = 4242 }
	fire("PLAYER_TOTEM_UPDATE", 3); runTimers()
	secretMode = false; inCombat = false
	check(ShamanKitDB.hold.last[3] == TEX(5675), "icon hidden in combat: remembered by the name of the totem that was cast")
	totems[3] = nil; fire("PLAYER_TOTEM_UPDATE", 3)
	check(holders[3].tex == TEX(5675), "...and the placeholder shows it")

	-- damaged saved data
	for label, bad in pairs({ ["a string"] = "x", ["junk inside"] = { last = { [2] = {} , [3] = true }, choice = { [1] = "a", [2] = {} } }, ["a number"] = 5 }) do
		ShamanKitDB.hold = bad
		local h = ns.fixHold()
		check(type(h.last) == "table" and type(h.choice) == "table" and h.last[2] == nil and h.last[3] == nil and h.choice[1] == nil and h.choice[2] == nil,
			"damaged icon memory (" .. label .. ") is cleaned")
	end

	-- the catalogue only lists totems this client has
	local ids = {}
	for _, c in ipairs(ns.totemChoices(2)) do ids[#ids + 1] = c.id end
	check(table.concat(ids, ",") == "5730,8071,2484,8075,8143", "earth choices: only the totems the game has (Earth Elemental, 2062, is missing in this pretend client)")
	ids = {}
	for _, c in ipairs(ns.totemChoices(1)) do ids[#ids + 1] = c.id end
	check(ids[2] == 408341, "Forever's own Fire Nova (408341) is picked when vanilla's (1535) is absent")
	ids = {}
	for _, c in ipairs(ns.totemChoices(4)) do ids[#ids + 1] = c.id end
	check(table.concat(ids, ",") == "8177,10595,8512,15107,8835", "air choices: filtered the same way")

	-- the picker buttons in the settings
	ShamanKitDB.hold = nil; ns.fixHold(); ShamanKitDB.reserve = {}; ShamanKitDB.order = { 2, 1, 3, 4 }; savedCat.panel.OnRefresh()
	local pick, keep = {}, {}
	for _, f in ipairs(frames) do
		if f.rowIndex and f.kind == "Button" and f.scripts.OnClick then pick[f.rowIndex] = f end
		if f.rowIndex and f.kind == "CheckButton" then keep[f.rowIndex] = f end
	end
	check(pick[1] and pick[4] and pick[1].text == "Auto", "settings: a picker per row, starting on Auto")
	pick[1].scripts.OnClick(pick[1], "LeftButton")
	check(ShamanKitDB.hold.choice[2] == 5730 and pick[1].text == "Stoneclaw", "left-click: the first earth totem, shown without the word Totem")
	pick[1].scripts.OnClick(pick[1], "LeftButton"); pick[1].scripts.OnClick(pick[1], "LeftButton")
	check(ShamanKitDB.hold.choice[2] == 2484, "left-click again twice: third earth totem")
	pick[1].scripts.OnClick(pick[1], "RightButton")
	check(ShamanKitDB.hold.choice[2] == 8071, "right-click goes back one")
	for _ = 1, 4 do pick[1].scripts.OnClick(pick[1], "LeftButton") end
	check(ShamanKitDB.hold.choice[2] == nil and pick[1].text == "Auto", "past the last totem it wraps round to Auto")
	pick[1].scripts.OnClick(pick[1], "RightButton")
	check(ShamanKitDB.hold.choice[2] == 8143, "right-click from Auto goes to the last totem")
	-- a row follows the element it shows, so reordering moves the pickers with it
	ShamanKitDB.hold.choice = {}; ns.moveSlot(1, 1); savedCat.panel.OnRefresh()
	pick[1].scripts.OnClick(pick[1], "LeftButton")
	check(ShamanKitDB.hold.choice[1] == 3599 and not ShamanKitDB.hold.choice[2], "after moving fire to the top, the first row picks fire totems")
	ns.resetOrder()
	-- the keep-a-space box on a row, and the remember box
	savedCat.panel.OnRefresh()
	keep[2].checked = true; keep[2].scripts.OnClick(keep[2])
	check(ShamanKitDB.reserve[1] == true and not ShamanKitDB.reserve[2], "the Keep box on the second row (fire) reserves fire")
	local remBox
	for _, f in ipairs(frames) do if f.settingKey == "rememberLast" then remBox = f end end
	remBox.checked = false; remBox.scripts.OnClick(remBox)
	check(ShamanKitDB.rememberLast == false, "the 'last totem used' box switches remembering off")
	remBox.checked = true; remBox.scripts.OnClick(remBox)
	check(ShamanKitDB.rememberLast == true, "...and on")
	ShamanKitDB.hold.choice[2] = 5730; savedCat.panel.OnDefault()
	check(next(ShamanKitDB.hold.choice) == nil and next(ShamanKitDB.reserve) == nil and ShamanKitDB.rememberLast == true, "Defaults clears locked totems and reserved spaces, remembering back on")
	ShamanKitDB.reserve = {}; ShamanKitDB.hold = nil; ns.fixHold(); out()
end

-- ---- a failure in the bookkeeping (memory of icons, placeholders) must never stop a totem from showing, least of all mid-fight
do
	local function out() totems = {}; for slot = 1, 4 do fire("PLAYER_TOTEM_UPDATE", slot) end end
	local function errorsInLog(what)
		local n = 0
		for _, l in ipairs(ShamanKitDB.log or {}) do if l:find("ERROR in " .. what, 1, true) then n = n + 1 end end
		return n
	end
	ShamanKitDB.hold = nil; ShamanKitDB.reserve = { [1] = true, [4] = true }; ShamanKitDB.distanceMode = "bar"
	secretPos = false; pos = { y = 0, x = 0, map = 1 }; inCombat = false; secretMode = false
	fire("PLAYER_ENTERING_WORLD"); out(); ns.fixHold()
	local realPrinted = #printedErrors

	-- in a fight, the icon hidden: the totem still shows, with the right picture from its name
	secretMode = true; inCombat = true
	fire("UNIT_SPELLCAST_SUCCEEDED", "player", "g", 5675)
	totems[3] = { name = "Mana Spring Totem", start = t, dur = 300, icon = 4242 }
	fire("PLAYER_TOTEM_UPDATE", 3); runTimers()
	check(btn(3).shown, "mid-fight, readings hidden: the totem shows")
	check(btn(3).icon.tex == 100000 + 5675, "...with its own picture (worked out from the totem's name), not a blank")

	-- the memory code breaking must not matter
	out(); secretMode = false; inCombat = false
	ShamanKitDB.hold = setmetatable({}, { __index = function() error("boom (test)") end })
	secretMode = true; inCombat = true
	fire("UNIT_SPELLCAST_SUCCEEDED", "player", "g", 5675)
	totems[3] = { name = "Mana Spring Totem", start = t, dur = 300, icon = 4242 }
	fire("PLAYER_TOTEM_UPDATE", 3); runTimers(); tick()
	check(btn(3).shown, "memory code failing mid-fight: the totem still shows")
	check(errorsInLog("remember") + errorsInLog("placeholders") >= 1, "...and the failure is written to the log")
	pos = { y = 0, x = 5, map = 1 }; tick()
	check(btn(3).shown and btn(3).gauge.shown, "...and the range bar keeps working")
	-- a second totem after the failure still shows: nothing was left half-done
	totems[2] = { name = "Strength of Earth Totem", start = t, dur = 300, icon = 4243 }
	fire("PLAYER_TOTEM_UPDATE", 2)
	check(btn(2).shown and btn(3).shown, "...and so does the next totem")
	secretMode = false; inCombat = false
	ShamanKitDB.hold = nil; ns.fixHold(); ShamanKitDB.reserve = {}; out()
	while #printedErrors > realPrinted do table.remove(printedErrors) end   -- these errors were on purpose
end

-- ---- order: earth, fire, water, air like the default totem bar; reorderable; damaged data falls back
do
	local function xOf(slot) return btn(slot).anchor and btn(slot).anchor[4] end
	local function placeAll()
		totems = {
			[1] = { name = "Searing Totem III", start = t, dur = 60, icon = 7 }, [2] = { name = "Strength of Earth Totem II", start = t, dur = 300, icon = 8 },
			[3] = { name = "Mana Spring Totem", start = t, dur = 300, icon = 9 }, [4] = { name = "Windfury Totem", start = t, dur = 300, icon = 10 } }
		secretMode = false; secretPos = false; inCombat = false
		pos = { y = 0, x = 0, map = 1 }
		fire("PLAYER_ENTERING_WORLD"); for slot = 1, 4 do fire("PLAYER_TOTEM_UPDATE", slot) end
	end
	local function sequence()   -- slots left to right
		local list = {}
		for slot = 1, 4 do if btn(slot).shown then list[#list + 1] = { slot, xOf(slot) } end end
		table.sort(list, function(a, b) return a[2] < b[2] end)
		local out = {}
		for _, e in ipairs(list) do out[#out + 1] = e[1] end
		return table.concat(out, ",")
	end
	local gap = ShamanKitDB.size + ShamanKitDB.spacing
	ShamanKitDB.order = nil; ns.fixOrder()
	check(table.concat(ShamanKitDB.order, ",") == "2,1,3,4", "default order is earth, fire, water, air (slots 2,1,3,4)")
	ShamanKitDB.vertical = false
	placeAll()
	check(sequence() == "2,1,3,4" and xOf(2) == 0 and xOf(1) == gap and xOf(3) == 2 * gap and xOf(4) == 3 * gap,
		"all four out: earth, fire, water, air, left to right with the right spacing")
	totems[3] = nil; fire("PLAYER_TOTEM_UPDATE", 3)
	check(sequence() == "2,1,4" and xOf(4) == 2 * gap, "no water totem: the others close the gap but keep their order")
	local n = 0
	local before = table.concat(ShamanKitDB.order, ",")
	check(ns.moveSlot(1, -1) == false and ns.moveSlot(4, 1) == false and table.concat(ShamanKitDB.order, ",") == before,
		"moving the first one up / the last one down does nothing")
	check(ns.moveSlot(1, 1) == true and table.concat(ShamanKitDB.order, ",") == "1,2,3,4", "move earth down one: fire, earth, water, air")
	check(sequence() == "1,2,4", "...and the bar follows at once")
	check(ns.moveSlot(4, -1) == true and table.concat(ShamanKitDB.order, ",") == "1,2,4,3" and sequence() == "1,2,4", "move air up: fire, earth, air, water")
	-- the real Up / Down buttons in the settings panel
	local down
	for _, f in ipairs(frames) do if f.orderRow == 1 and f.orderDelta == 1 and f.scripts.OnClick then down = f break end end
	check(down ~= nil, "settings panel has Up / Down buttons")
	ShamanKitDB.order = { 2, 1, 3, 4 }
	down.scripts.OnClick(down)    -- the first Down button: earth <-> fire
	check(table.concat(ShamanKitDB.order, ",") == "1,2,3,4", "the first Down button swaps the first two")
	local reset
	for _, f in ipairs(frames) do if f.text == "Reset order" and f.scripts.OnClick then reset = f break end end
	reset.scripts.OnClick(reset)
	check(table.concat(ShamanKitDB.order, ",") == "2,1,3,4" and sequence() == "2,1,4", "Reset order restores earth, fire, water, air")
	-- damaged saved data
	for label, bad in pairs({ ["duplicate"] = { 1, 1, 2, 3 }, ["too short"] = { 1, 2, 3 }, ["not a table"] = "x",
		["out of range"] = { 1, 2, 3, 9 }, ["fraction"] = { 1, 2, 3, 3.5 }, ["empty"] = {} }) do
		ShamanKitDB.order = bad
		fire("PLAYER_ENTERING_WORLD"); ns.fixOrder()
		check(table.concat(ShamanKitDB.order, ",") == "2,1,3,4", "damaged order (" .. label .. ") falls back to the default")
	end
	ShamanKitDB.order = { 2, 1, 3, 4 }
	-- vertical keeps the same order
	ShamanKitDB.vertical = true; ns.apply(); placeAll()
	local list = {}
	for slot = 1, 4 do list[#list + 1] = { slot, btn(slot).anchor[5] } end
	table.sort(list, function(a, b) return a[2] > b[2] end)
	check(list[1][1] == 2 and list[2][1] == 1 and list[3][1] == 3 and list[4][1] == 4, "vertical bar: earth on top, then fire, water, air")
	ShamanKitDB.vertical = false; ns.apply()
	totems = {}; for slot = 1, 4 do fire("PLAYER_TOTEM_UPDATE", slot) end
end

-- ---- cost: what one tick (0.25 s) costs while four totems are out and the distance text is on (the worst case)
do
	totems = {
		[1] = { name = "Searing Totem III", start = t, dur = 60, icon = 7 }, [2] = { name = "Strength of Earth Totem II", start = t, dur = 300, icon = 8 },
		[3] = { name = "Mana Spring Totem", start = t, dur = 300, icon = 9 }, [4] = { name = "Windfury Totem", start = t, dur = 300, icon = 10 } }
	secretMode = false; secretPos = false; inCombat = false; mapOn = true
	pos = { y = 0, x = 0, map = 1 }
	ShamanKitDB.distanceMode = "bar"; ShamanKitDB.showRange = true; ShamanKitDB.showOut = true
	fire("PLAYER_ENTERING_WORLD"); for slot = 1, 4 do fire("PLAYER_TOTEM_UPDATE", slot) end
	for _ = 1, 20 do tick() end
	local counts = { UnitPosition = 0, GetTotemInfo = 0, GetPlayerMapPosition = 0 }
	local wrap = function(tbl, key, label)
		local orig = tbl[key]
		tbl[key] = function(...) counts[label] = counts[label] + 1; return orig(...) end
	end
	wrap(_G, "UnitPosition", "UnitPosition"); wrap(_G, "GetTotemInfo", "GetTotemInfo"); wrap(C_Map, "GetPlayerMapPosition", "GetPlayerMapPosition")
	for k in pairs(CALLS) do CALLS[k] = 0 end
	local N = 400
	local moving = 0
	collectgarbage(); collectgarbage("stop")
	local before = collectgarbage("count")
	for i = 1, N do
		moving = moving + 0.05                      -- slowly walking, so distances really change
		pos = { y = 0, x = moving, map = 1 }
		tick()
	end
	local kb = (collectgarbage("count") - before) / N
	collectgarbage("restart")
	local per = function(n) return n / N end
	print(("COST per tick: %.2f KB garbage | UnitPosition %.1f  C_Map position %.1f  GetTotemInfo %.1f | SetTexture %.1f  SetVertexColor %.1f  SetText %.1f  SetTextColor %.1f"):format(
		kb, per(counts.UnitPosition), per(counts.GetPlayerMapPosition), per(counts.GetTotemInfo), per(CALLS.SetTexture), per(CALLS.SetVertexColor), per(CALLS.SetText), per(CALLS.SetTextColor)))
	COST = { kb = kb, up = per(counts.UnitPosition), map = per(counts.GetPlayerMapPosition), info = per(counts.GetTotemInfo),
		tex = per(CALLS.SetTexture), col = per(CALLS.SetVertexColor), txt = per(CALLS.SetText) }
	ShamanKitDB.distanceMode = "off"
	check(COST.kb < 2, ("cost: under 2 KB of garbage per tick (was 4.2): %.2f"):format(COST.kb))
	check(COST.up <= 1.01 and COST.map < 0.1, ("cost: one position read per tick, map only when a range edge is crossed (%.3f)"):format(COST.map))
	check(COST.info <= 4.01, "cost: one GetTotemInfo per totem per tick (was two)")
	check(COST.tex < 0.1 and COST.col < 0.1, ("cost: texture/colour writes only when a range edge is crossed (tex %.3f, colour %.3f)"):format(COST.tex, COST.col))
	-- standing still with the distance text on: not even the text is rewritten
	pos = { y = 0, x = moving, map = 1 }
	for k in pairs(CALLS) do CALLS[k] = 0 end
	for _ = 1, 50 do tick() end
	check(CALLS.SetText == 0 and CALLS.SetTexture == 0 and CALLS.SetVertexColor == 0 and CALLS.SetTextColor == 0,
		"cost: standing still, a tick writes nothing to the screen")
	-- the last totem expiring stops the work: the bar hides (its tick only runs while it is shown)
	totems = {}
	tick()
	check(not bar().anyShown, "cost: when the last totem expires the bar is empty")
	local reads = 0
	local origUP = UnitPosition
	UnitPosition = function(...) reads = reads + 1; return origUP(...) end
	for _ = 1, 20 do tick() end
	UnitPosition = origUP
	check(reads == 0, "cost: with no totem out a tick reads nothing at all")
end

-- ---- weapon enchant + Lightning Shield icons
do
	local db = ShamanKitDB
	local function W() return _G.ShamanKitWeapon end
	local function S() return _G.ShamanKitShield end
	local aux = _G.ShamanKitIndicators
	local function second() ev.scripts.OnUpdate(ev, 1.0) end      -- the once-a-second look
	ShamanKitDB.log = {}                                         -- earlier sections log deliberate errors; start clean

	totems = {}; inCombat = false; secretMode = false; secretPos = false; mapOn = true
	auras = {}
	local held, itemClass, itemSub, dead = 555, 2, 8, false
	local enchants, enchantSecret, enchantCalls = {}, false, 0
	GetInventoryItemID = function(_, slot) if slot == 16 then return held end end
	UnitIsDeadOrGhost = function() return dead end
	C_Item = {
		GetItemInfoInstant = function(id) return id, "Weapon", "Two-Handed Maces", "INVTYPE_2HWEAPON", 1, itemClass, itemSub end,
		GetWeaponEnchantInfo = function() enchantCalls = enchantCalls + 1; if enchantSecret then return secret() end return enchants end,
	}
	db.weaponOn, db.shieldOn, db.auxAnchor, db.vertical, db.lastImbue = true, true, "bar", false, nil
	db.size, db.spacing = 36, 4
	ns.optionsOpen = false
	fire("PLAYER_ENTERING_WORLD")
	second()

	-- the events are real names this client knows (they were taken from the installed addons)
	local want = { UNIT_AURA = true, UNIT_INVENTORY_CHANGED = true, PLAYER_EQUIPMENT_CHANGED = true }
	local known = { ADDON_LOADED = true, PLAYER_ENTERING_WORLD = true, PLAYER_TOTEM_UPDATE = true, UNIT_SPELLCAST_SUCCEEDED = true,
		PLAYER_REGEN_DISABLED = true, PLAYER_REGEN_ENABLED = true, ADDON_ACTION_BLOCKED = true, ADDON_ACTION_FORBIDDEN = true,
		UNIT_AURA = true, UNIT_INVENTORY_CHANGED = true, PLAYER_EQUIPMENT_CHANGED = true }
	local seen, unknown = {}, nil
	for _, n in ipairs(REGISTERED) do seen[n] = true; if not known[n] then unknown = n end end
	check(seen.UNIT_AURA and seen.UNIT_INVENTORY_CHANGED and seen.PLAYER_EQUIPMENT_CHANGED, "icons: the three events are registered")
	check(unknown == nil, "icons: every registered event is one this client has" .. (unknown and (" (" .. unknown .. ")") or ""))

	-- weapon: nothing on it -> the icon pops up
	enchants = {}
	second()
	check(W().shown and W().glow.shown, "weapon: no enchant -> icon shown with the ring")
	check(W().time.text == "", "weapon: no countdown while it is simply missing")
	-- an enchant with plenty of time -> hidden, and its picture is remembered
	enchants = { { hasEnchant = true, timeLeft = 1800000, enchantType = 3, enchantID = 5, enchantIconID = 135 } }
	second()
	check(not W().shown, "weapon: enchant with 30 min left -> icon hidden")
	check(db.lastImbue == 135, "weapon: the picture of the enchant on the weapon is remembered")
	-- running out
	enchants[1].timeLeft = 90000; second()
	check(W().shown and W().time.text == "2m", "weapon: 90 s left -> icon with 2m (" .. tostring(W().time.text) .. ")")
	enchants[1].timeLeft = 45000; second()
	check(W().shown and W().time.text == "45s", "weapon: 45 s left -> 45s")
	enchants[1].timeLeft = 119000; second()
	check(W().shown, "weapon: just under 2 minutes counts as running out")
	enchants[1].timeLeft = 121000; second()
	check(not W().shown, "weapon: just over 2 minutes is fine")
	-- gone: shows the picture of what was on it
	enchants = {}; second()
	check(W().shown and W().icon.tex == 135, "weapon: after it ran out the icon shows the enchant you used (135)")
	-- an enchant with no time (permanent) is not a reminder
	enchants = { { hasEnchant = true, enchantType = 1 } }; second()
	check(not W().shown, "weapon: an enchant without a timer counts as enchanted")
	-- one enchant ended, another remains: the longer one counts
	enchants = { { hasEnchant = true, timeLeft = 30000 }, { hasEnchant = true, timeLeft = 900000 } }; second()
	check(not W().shown, "weapon: two enchants, the longer one has plenty left")
	enchants = {}

	-- things that must not nag
	itemSub = 20; second()
	check(not W().shown, "weapon: a fishing pole in hand -> no reminder")
	itemSub = 8; itemClass = 4; second()
	check(not W().shown, "weapon: not a weapon (armour class) -> no reminder")
	itemClass = 2; held = nil; second()
	check(not W().shown, "weapon: nothing in the main hand -> no reminder")
	held = 555; dead = true; second()
	check(not W().shown, "weapon: dead -> no reminder")
	dead = false; second()
	check(W().shown, "weapon: alive again with no enchant -> back")

	-- readings the game will not give: the icon stays as it was, no claim either way
	enchantSecret = true; second()
	check(W().shown, "weapon: a hidden reading keeps the icon where it was (missing)")
	enchants = { { hasEnchant = true, timeLeft = 1800000 } }; enchantSecret = false; second()
	check(not W().shown, "weapon: enchanted again")
	enchantSecret = true; second()
	check(not W().shown, "weapon: a hidden reading does not suddenly claim 'missing'")
	enchantSecret = false
	enchants = { { hasEnchant = secret(), timeLeft = 5000 } }; second()
	check(not W().shown, "weapon: a hidden 'has enchant' flag changes nothing")
	local savedInfo = C_Item.GetWeaponEnchantInfo
	C_Item.GetWeaponEnchantInfo = nil; second()
	check(not W().shown, "weapon: an API this client lacks changes nothing")
	C_Item.GetWeaponEnchantInfo = savedInfo
	enchants = {}

	-- the weapon icon needs no totem and no bar frame work: nothing of the bar is touched
	check(not bar().anyShown, "icons: they work with no totem out")

	-- Lightning Shield
	check(not S().shown, "shield: not up -> no icon")
	auras["Lightning Shield"] = { applications = 3, icon = 1 }
	fire("UNIT_AURA", "player")
	check(S().shown and S().count.text == "3", "shield: up with 3 charges -> icon, number 3")
	auras["Lightning Shield"].applications = 2; fire("UNIT_AURA", "player")
	check(S().count.text == "2", "shield: charge used -> 2")
	auras["Lightning Shield"] = { applications = 0, charges = 1 }; fire("UNIT_AURA", "player")
	check(S().shown and S().count.text == "1", "shield: falls back to 'charges' when 'applications' is empty")
	auras["Lightning Shield"] = { applications = nil }; fire("UNIT_AURA", "player")
	check(S().shown and S().count.text == "", "shield: up with no number -> icon, no number")
	auras["Lightning Shield"] = { applications = secret() }; fire("UNIT_AURA", "player")
	check(S().shown, "shield: a hidden charge number still shows the icon")
	auras["Lightning Shield"] = { applications = 3 }; fire("UNIT_AURA", "player")
	secretPos = true; fire("UNIT_AURA", "player")
	check(S().shown and S().count.text == "3", "shield: an unreadable aura list keeps the icon and the last number")
	secretPos = false
	auras["Lightning Shield"] = nil; fire("UNIT_AURA", "player")
	check(not S().shown, "shield: gone -> icon hidden")
	secretPos = true; fire("UNIT_AURA", "player")
	check(not S().shown, "shield: an unreadable aura list does not invent a shield")
	secretPos = false

	-- ---- weapon icon mode: "missing" (the default) or "active" (the enchant that is on, like the shield icon)
	do
		secretPos = false; AURAS_HIDDEN = false; inCombat = false
		db.weaponOn = true; db.auxWarnMin = 2; db.lastImbue = nil; held = 555; itemClass, itemSub = 2, 8; dead = false; enchantSecret = false
		enchants = {}; db.weaponMode = nil; second()
		check(ns.weaponMode() == "missing" and W().shown, "weapon mode: nothing saved means 'missing' (the icon pops up when there is no enchant)")
		db.weaponMode = "garbage"
		check(ns.weaponMode() == "missing", "weapon mode: a damaged value means 'missing'")
		check(ns.defaults.weaponMode == "missing", "weapon mode: the default is 'missing'")
		db.weaponMode = "missing"
		enchants = { { hasEnchant = true, timeLeft = 1800000, enchantIconID = 777 } }; second()
		check(not W().shown, "missing mode: an enchant that is on shows nothing")

		db.weaponMode = "active"; ns.updatePreview()
		check(W().shown and W().icon.tex == 777 and W().time.text == "30m" and not W().glow.shown,
			("active mode: the enchant that is on - its picture, its time, no ring (%s %s %s)"):format(tostring(W().icon.tex), tostring(W().time.text), tostring(W().glow.shown)))
		enchants[1].timeLeft = 3600000; second(); check(W().time.text == "60m", "active mode: 60m")
		enchants[1].timeLeft = 119000; second()
		check(W().shown and W().time.text == "2m" and W().glow.shown and W().glow.color[1] == 1 and W().glow.color[2] == 0.82, "active mode: under the warning time -> the yellow ring appears")
		enchants[1].timeLeft = 45000; second(); check(W().time.text == "45s", "active mode: 45s")
		db.auxWarnMin = 0; second()
		check(W().shown and not W().glow.shown and W().time.text == "45s", "active mode, warning off: still shown, no ring")
		db.auxWarnMin = 2
		enchants = { { hasEnchant = true, enchantType = 1, enchantIconID = 888 } }; second()
		check(W().shown and W().icon.tex == 888 and W().time.text == "" and not W().glow.shown, "active mode: an enchant with no timer shows its picture, no time, no ring")
		enchants = { { hasEnchant = true, timeLeft = 300000, enchantIconID = 111 }, { hasEnchant = true, timeLeft = 2700000, enchantIconID = 222 } }; second()
		check(W().icon.tex == 222 and W().time.text == "45m", "two enchants: the longest-lasting one gives the picture and the time")
		enchants = { { hasEnchant = false, enchantIconID = 0 }, { hasEnchant = true, timeLeft = 1800000, enchantIconID = 333 } }; second()
		check(W().icon.tex == 333, "an empty entry beside the real one (what the game really sends) is ignored")
		enchants = {}; second()
		check(not W().shown, "active mode: no enchant -> nothing to show (here the icon is not an alert)")

		-- the same safety rules as the other mode
		enchants = { { hasEnchant = true, timeLeft = 1800000, enchantIconID = 777 } }; second()
		check(W().shown, "active mode: enchant back -> icon back")
		itemSub = 20; second(); check(not W().shown, "active mode: a fishing pole -> nothing"); itemSub = 8
		dead = true; second(); check(not W().shown, "active mode: dead -> nothing"); dead = false
		held = nil; second(); check(not W().shown, "active mode: nothing in the main hand -> nothing"); held = 555
		second(); check(W().shown, "active mode: back")
		enchantSecret = true; second(); check(W().shown and W().time.text == "30m", "active mode: a hidden reading keeps the icon as it was"); enchantSecret = false

		-- off: not even read
		db.weaponOn = false; ns.updatePreview(); check(not W().shown, "weapon icon off: nothing in active mode either")
		enchantCalls = 0; for _ = 1, 3 do second() end
		check(enchantCalls == 0, "weapon icon off: the enchant is not read in active mode")
		db.weaponOn = true; ns.updatePreview()
		check(W().shown, "weapon icon on again: active mode shows at once")
		-- switching the mode repaints at once
		db.weaponMode = "missing"; ns.updatePreview(); check(not W().shown, "switching to 'missing': the icon is gone at once (the enchant is on)")
		db.weaponMode = "active"; ns.updatePreview(); check(W().shown, "switching to 'active': the icon is back at once")

		-- samples: only with a settings page open, and they look like the mode they preview
		enchants = {}; second(); ns.optionsOpen = true; ns.updatePreview()
		check(W().shown and W().time.text == "30m" and not W().glow.shown, "settings open, active mode: the sample looks like an active enchant (30m, no ring)")
		db.weaponMode = "missing"; ns.updatePreview()
		check(W().shown and W().glow.shown and W().time.text == "", "settings open, missing mode: the sample is the red alert")
		ns.optionsOpen = false; ns.updatePreview()
		check(W().shown, "settings closed, missing mode, no enchant: the real alert")
		db.weaponMode = "active"; ns.updatePreview()
		check(not W().shown, "settings closed, active mode, no enchant: nothing (no sample left behind)")

		-- cost: nothing drawn while nothing changes
		enchants = { { hasEnchant = true, timeLeft = 1800000, enchantIconID = 777 } }; second(); second()
		for k in pairs(CALLS) do CALLS[k] = 0 end
		for _ = 1, 30 do second() end
		check(CALLS.SetText == 0 and CALLS.SetTexture == 0 and CALLS.SetVertexColor == 0, "cost: active mode, nothing new -> nothing written")

		-- the picture of the enchant that was on is what the alert shows afterwards
		db.weaponMode = "missing"; enchants = {}; second()
		check(W().shown and W().icon.tex == 777, "missing mode afterwards: the alert shows the enchant you had (777)")

		-- the settings page
		local pageB = savedCat.pages[4]
		local function radioIn(value)
			for _, f in ipairs(frames) do if f.value == value and f.parentFrame == pageB and f.scripts.OnClick then return f end end
		end
		local rA, rM = radioIn("active"), radioIn("missing")
		check(rA ~= nil and rM ~= nil, "settings: two choices for the weapon icon")
		pageB.OnRefresh()
		check(rM.checked and not rA.checked, "settings: the saved choice is shown (missing)")
		rA.scripts.OnClick(rA)
		check(db.weaponMode == "active" and rA.checked and not rM.checked, "settings: clicking 'Which enchant is on' selects it")
		second(); check(not W().shown, "settings: and it applies at once (no enchant -> nothing)")
		rM.scripts.OnClick(rM)
		check(db.weaponMode == "missing" and rM.checked and not rA.checked and W().shown, "settings: clicking 'Only when missing' selects it, the alert shows")
		db.weaponOn = false; pageB.OnRefresh()
		check(rA.enabled == false and rM.enabled == false, "settings: the two choices are greyed out while the icon is off")
		db.weaponOn = true; pageB.OnRefresh()
		check(rA.enabled == true and rM.enabled == true, "settings: and usable again with the icon on")
		db.weaponMode = "active"; pageB.OnDefault()
		check(db.weaponMode == "missing", "Defaults on the buffs page: back to 'missing'")
		db.weaponMode = "missing"; enchants = {}; db.lastImbue = nil; second()
		noErrors("weapon mode: no error in the log")
	end

	-- THE REPORTED BUGS: the icon vanished at every fight start; then "can't be read"; then stuck on 3 until the fight ended.
	-- What the real log proved: in a fight the name, id and scan lookups all answer nothing. Still answered: the list of
	-- buff ids, and the count text (a string the addon can't read).
	do
		secretPos = false; AURAS_HIDDEN = false; IDAURAS = {}; EXTRA_IDS = {}; COUNT_SECRET = false; IDLIST_FAILS = false
		db.shieldOn = true; inCombat = false; ShamanKitDB.log = {}
		local live = { applications = 3, auraInstanceID = 353, spellId = 945 }
		auras["Lightning Shield"] = live; IDAURAS[353] = live; fire("UNIT_AURA", "player")
		check(S().shown and S().count.text == "3", "fight test: shield up out of combat, 3 charges")
		AURAS_HIDDEN = true; inCombat = true; auras["Lightning Shield"] = nil   -- from here every data lookup says nothing
		fire("PLAYER_REGEN_DISABLED")
		check(S().shown and S().count.text == "3" and S().count.color[1] == 1, "the fight starts: the icon STAYS, 3, white (read live, not remembered)")
		check(CALLED_COUNT and CALLED_COUNT.id == 353 and CALLED_COUNT.min == 1 and CALLED_COUNT.max == 99, "the game's count text is asked for with a minimum of 1, so '1' shows")
		live.applications = 2; fire("UNIT_AURA", "player")
		check(S().shown and S().count.text == "2", "REPORTED BUG: a charge is used in the fight: 2, live (it was stuck on 3)")
		live.applications = 1; second()
		check(S().count.text == "1", "...1, live (polls follow it too)")
		check(S().count.color[1] == 1, "...white, no warning colour")
		check(not tostring(S().tipLine):find("can't be read"), "no 'can't be read' text anywhere")
		local seen
		for _, l in ipairs(ShamanKitDB.log) do if l:find("SHIELD in a fight") then seen = l end end
		check(seen ~= nil and seen:find("id=353") and seen:find("up") and seen:find("found") and seen:find("count"), "the log says what each call answered")
		local function lines() local n = 0; for _, l in ipairs(ShamanKitDB.log) do if l:find("SHIELD in a fight") then n = n + 1 end end return n end
		local before = lines(); for _ = 1, 6 do second(); fire("UNIT_AURA", "player") end
		check(lines() == before, "...a line only when the answer changes, not once per message")
		IDAURAS[353] = nil
		fire("UNIT_AURA", "player")
		check(not S().shown, "REPORTED BUG: the shield ends in the fight: the icon is gone at once, not at the end of the fight")
		second(); check(not S().shown, "...and stays gone")
		-- the count text is a hidden string: it is passed straight to the number, never read
		AURAS_HIDDEN = false; inCombat = false; fire("PLAYER_REGEN_ENABLED")
		local live2 = { applications = 3, auraInstanceID = 360, spellId = 945 }
		auras["Lightning Shield"] = live2; IDAURAS[360] = live2; fire("UNIT_AURA", "player")
		AURAS_HIDDEN = true; inCombat = true; auras["Lightning Shield"] = nil; fire("PLAYER_REGEN_DISABLED")
		COUNT_SECRET = true; second()
		check(S().shown and S().count.text ~= "?" and S().count.color[1] == 1, "hidden count text: shown as is (no ?, white)")
		COUNT_SECRET = false
		-- a one-charge shield shows 1, an empty text shows nothing
		live2.applications = 1; second(); check(S().count.text == "1", "1 charge left: shows 1")
		live2.applications = 0; second(); check(S().shown and S().count.text == "", "the game says no count: the number is empty, the icon stays while the aura is on")
		live2.applications = 2; second()
		-- the buff list can't be read: the icon stays, the last number, a little grey
		-- the real log: the id list is blocked. The count text alone must still carry the icon
		IDLIST_FAILS = true; live2.applications = 2; second()
		check(S().shown and S().count.text == "2" and S().count.color[1] == 1, "id list blocked: the count text alone still shows the live number (2), white")
		live2.applications = 1; second(); check(S().count.text == "1", "...and follows it (1)")
		local sawErr; for _, l in ipairs(ShamanKitDB.log) do if l:find("ids: error") then sawErr = true end end
		check(sawErr, "the log says why the list failed")
		-- both blocked: icon and last number stay, a little grey (nothing else can be read)
		COUNT_FAILS = true; second()
		check(S().shown and S().count.text == "1" and S().count.color[1] < 0.9, "both calls blocked: icon and last number stay, a little grey")
		COUNT_FAILS = false; IDLIST_FAILS = false; second()
		check(S().shown and S().count.text == "1" and S().count.color[1] == 1, "...and white again as soon as they answer")
		live2.applications = 2; second()
		-- a shield cast in the fight has an id nobody knows: nothing invented, the old one stays gone
		-- fight over: the real reading again, new id remembered
		AURAS_HIDDEN = false; inCombat = false
		auras["Lightning Shield"] = { applications = 1, auraInstanceID = 361, spellId = 945 }; IDAURAS = { [361] = auras["Lightning Shield"] }
		fire("PLAYER_REGEN_ENABLED")
		check(S().shown and S().count.text == "1", "fight over: the real number (1) at once")
		-- no shield before a fight: a fight does not invent one
		auras["Lightning Shield"] = nil; IDAURAS = {}; fire("UNIT_AURA", "player")
		check(not S().shown, "out of combat the shield is gone: icon hidden")
		EXTRA_IDS = { 500, 501 }   -- other buffs
		AURAS_HIDDEN = true; inCombat = true; fire("PLAYER_REGEN_DISABLED"); second(); fire("UNIT_AURA", "player")
		check(not S().shown, "no shield before the fight: still none during it, whatever other buffs there are")
		EXTRA_IDS = {}
		AURAS_HIDDEN = false; inCombat = false; fire("PLAYER_REGEN_ENABLED")
		-- another buff with another id does not keep the icon up
		local live3 = { applications = 3, auraInstanceID = 400, spellId = 945 }
		auras["Lightning Shield"] = live3; IDAURAS[400] = live3; fire("UNIT_AURA", "player")
		AURAS_HIDDEN = true; inCombat = true; auras["Lightning Shield"] = nil; fire("PLAYER_REGEN_DISABLED")
		IDAURAS[400] = nil; EXTRA_IDS = { 401 }; second()
		check(not S().shown, "the shield's id is gone while another buff came: the icon is gone")
		EXTRA_IDS = {}
		-- no ShouldAurasBeSecret on this client: a fight is assumed to hide the auras
		AURAS_HIDDEN = false; inCombat = false; fire("PLAYER_REGEN_ENABLED")
		local sec = C_Secrets; C_Secrets = nil
		local live4 = { applications = 3, auraInstanceID = 410, spellId = 945 }
		auras["Lightning Shield"] = live4; IDAURAS[410] = live4; fire("UNIT_AURA", "player")
		inCombat = true; AURAS_HIDDEN = true; auras["Lightning Shield"] = nil; fire("PLAYER_REGEN_DISABLED"); live4.applications = 2; second()
		check(S().shown and S().count.text == "2", "no ShouldAurasBeSecret on this client: a fight is still assumed to hide auras")
		inCombat = false; AURAS_HIDDEN = false; fire("PLAYER_REGEN_ENABLED"); C_Secrets = sec
		auras["Lightning Shield"] = nil; IDAURAS = {}; fire("UNIT_AURA", "player")
		-- this client lacks the calls: the icon stays, grey
		local g1, g2 = C_UnitAuras.GetUnitAuraInstanceIDs, C_UnitAuras.GetAuraApplicationDisplayCount
		local live5 = { applications = 3, auraInstanceID = 420, spellId = 945 }
		auras["Lightning Shield"] = live5; IDAURAS[420] = live5; fire("UNIT_AURA", "player")
		C_UnitAuras.GetUnitAuraInstanceIDs, C_UnitAuras.GetAuraApplicationDisplayCount = nil, nil
		AURAS_HIDDEN = true; inCombat = true; auras["Lightning Shield"] = nil; fire("PLAYER_REGEN_DISABLED"); second()
		check(S().shown and S().count.text == "3" and S().count.color[1] < 0.9, "calls missing on this client: icon and last number stay, grey")
		C_UnitAuras.GetUnitAuraInstanceIDs, C_UnitAuras.GetAuraApplicationDisplayCount = g1, g2
		AURAS_HIDDEN = false; inCombat = false; fire("PLAYER_REGEN_ENABLED")
		auras["Lightning Shield"] = nil; IDAURAS = {}; fire("UNIT_AURA", "player")
		noErrors("fight test: no error in the log")
	end

	-- ---- the shield icon drawn by the GAME (aura container): the only thing that works in a fight
	do
		CONTAINER_FAILS = false; NO_SLOTS = false; BAD_FORMATTER = false; AURAS_HIDDEN = false; inCombat = false
		secretPos = false; IDAURAS = {}; EXTRA_IDS = {}; auras["Lightning Shield"] = nil
		db.shieldOn = true; db.weaponOn = false; ns.optionsOpen = false; ShamanKitDB.log = {}
		ns._resetBox(); ns.updatePreview(); second()
		local c
		for _, f in ipairs(frames) do if f.kind == "AuraContainer" and f.slots and f.slots.ShamanKitShield then c = f end end
		check(c ~= nil, "container: an aura container is made for the shield (out of combat)")
		local slot = c and c.slots.ShamanKitShield
		check(c.unit == "player", "container: it watches the player")
		check(slot.filter == "HELPFUL", "container: buffs only")
		local ids = slot.opts.candidateFilters.includeSpellIDs
		check(ids[324] and ids[945] and ids[10432] and not ids[1126], "container: limited to Lightning Shield by spell id (every rank), nothing else")
		check(LOADED_ADDONS.Blizzard_AuraContainer, "container: the game's aura container addon is loaded first")
		local b = slot.button
		check(b.iconTex ~= nil, "container: the game is told where to put the aura's picture")
		check(b.countFS ~= nil and b.countFS.kind == "region", "container: the game is told where to write the stack count")
		check(b.countOpts and b.countOpts.formatter ~= nil, "container: a number formatter is given, so 1 charge shows '1'")
		check(b.sizeAtInit and b.sizeAtInit > 0, "container: the button is given a size when it is made (without one it is invisible)")
		local f = S()
		check(b.anchor and b.anchor[1] == "TOPLEFT" and b.anchor[2] == f, "container: the icon sits exactly where the sample icon sits")
		check(c.shown == true and c.enabled == true, "container: shown and enabled when the shield icon is on")
		check(not S().shown, "container: our own frame is not drawn (no second icon on top of the game's)")
		auras["Lightning Shield"] = { applications = 3, auraInstanceID = 31, spellId = 945 }; fire("UNIT_AURA", "player"); second()
		check(not S().shown, "container: the shield is really up and readable, still only the game's icon (no double)")
		auras["Lightning Shield"] = nil; fire("UNIT_AURA", "player"); second()
		local made; for _, l in ipairs(ShamanKitDB.log) do if l:find("SHIELD container made") then made = l end end
		check(made and made:find("slot") and made:find("CreateNumericRuleFormatter"), "container: the log says what was made")
		check(ns.boxInfo():find("game%-drawn"), "container: status says so")

		-- a fight: nothing of ours may be touched, and nothing is read
		local nCont = 0; for _, fr in ipairs(frames) do if fr.kind == "AuraContainer" then nCont = nCont + 1 end end
		AURAS_HIDDEN = true; inCombat = true; fire("PLAYER_REGEN_DISABLED")
		for _ = 1, 4 do second(); fire("UNIT_AURA", "player") end
		local nCont2 = 0; for _, fr in ipairs(frames) do if fr.kind == "AuraContainer" then nCont2 = nCont2 + 1 end end
		check(nCont2 == nCont, "fight: no new container is made in combat")
		check(c.shown == true and not S().shown, "fight: the game's icon stays up, ours stays hidden")
		local wBefore = b.w
		db.size = 80; ns.updatePreview(); second()
		check(b.w == wBefore, "fight: the icon is not resized in combat")
		AURAS_HIDDEN = false; inCombat = false; fire("PLAYER_REGEN_ENABLED"); second()
		check(b.w ~= wBefore, "fight over: the size change is applied")
		db.size = 36; ns.updatePreview()

		-- settings open: a sample shows, the game's icon steps aside
		ns.optionsOpen = true; ns.updatePreview()
		check(S().shown and S().count.text == "3" and c.shown == false, "settings open: the sample shows (3) and the game's icon is hidden, so there is no double icon")
		ns.optionsOpen = false; ns.updatePreview()
		check(not S().shown and c.shown == true, "settings closed: the sample is gone, the game's icon is back")
		-- switched off
		db.shieldOn = false; ns.updatePreview(); second()
		check(c.shown == false and c.enabled == false and not S().shown, "shield icon off: nothing shows")
		db.shieldOn = true; ns.updatePreview(); second()
		check(c.shown == true, "shield icon on again: shows")
		noErrors("container: no error in the log")

		-- the client has no AuraSlot: a group of one
		NO_SLOTS = true; ns._resetBox(); ns.updatePreview(); second()
		local g; for _, fr in ipairs(frames) do if fr.groups and fr.groups.ShamanKitShield then g = fr end end
		check(g ~= nil and g.groups.ShamanKitShield.opts.maxFrameCount == 1, "no slots on this client: a group that holds one aura")
		check(g.groups.ShamanKitShield.opts.candidateFilters.includeSpellIDs[945], "...limited to the shield the same way")
		NO_SLOTS = false

		-- a formatter the game rejects: the plain count is used
		BAD_FORMATTER = true; ns._resetBox(); ns.updatePreview(); second()
		local c2; for _, fr in ipairs(frames) do if fr.slots and fr.slots.ShamanKitShield then c2 = fr end end
		check(c2.slots.ShamanKitShield.button.countFS ~= nil, "a formatter the game rejects: the stack count still gets registered without it")
		BAD_FORMATTER = false

		-- no formatter object on this client: still works, and the log says 1 charge shows blank
		local su = C_StringUtil; C_StringUtil = nil; ShamanKitDB.log = {}; ns._resetBox(); ns.updatePreview(); second()
		local noFmt; for _, l in ipairs(ShamanKitDB.log) do if l:find("none %(1 charge shows blank%)") then noFmt = true end end
		check(noFmt, "no number formatter on this client: still made, and the log says 1 charge shows blank")
		C_StringUtil = su

		-- the client can't make one: the older reading is used, nothing breaks
		CONTAINER_FAILS = true; ShamanKitDB.log = {}; ns._resetBox(); ns.updatePreview(); second()
		check(ns.boxInfo():find("not available"), "container refused: status says it reads by name instead")
		auras["Lightning Shield"] = { applications = 2, auraInstanceID = 9, spellId = 945 }; fire("UNIT_AURA", "player")
		check(S().shown and S().count.text == "2", "container refused: the shield icon still works the old way out of combat")
		auras["Lightning Shield"] = nil; fire("UNIT_AURA", "player")
		local refused; for _, l in ipairs(ShamanKitDB.log) do if l:find("container could not be made") then refused = true end end
		check(refused, "container refused: the log says why")
		-- it is not retried every second
		local before = #ShamanKitDB.log; for _ = 1, 5 do second() end
		check(#ShamanKitDB.log == before, "container refused: not retried over and over")
		-- started in a fight: wait for the fight to end, then make it
		CONTAINER_FAILS = false; ns._resetBox(); inCombat = true; AURAS_HIDDEN = true; ns.updateAux(); second()
		check(ns.boxInfo():find("not made yet"), "the game started in a fight: no container is made in combat")
		inCombat = false; AURAS_HIDDEN = false; second()
		check(ns.boxInfo():find("game%-drawn"), "made after the fight when the game started in one")
		CONTAINER_FAILS = true; ns._resetBox()
		db.weaponOn = true
	end

	-- the switches
	db.weaponOn = false; ns.updatePreview()
	check(not W().shown, "weapon icon off in the settings -> hidden even though the enchant is missing")
	enchantCalls = 0; for _ = 1, 5 do second() end
	check(enchantCalls == 0, "weapon icon off -> the enchant is never even read")
	db.weaponOn = true; ns.updatePreview()
	check(W().shown, "weapon icon switched on -> shows at once")
	db.shieldOn = false; auras["Lightning Shield"] = { applications = 3 }; fire("UNIT_AURA", "player"); ns.updatePreview()
	check(not S().shown, "shield icon off in the settings -> hidden while the shield is up")
	db.shieldOn = true; ns.updatePreview()
	check(S().shown and S().count.text == "3", "shield icon switched on -> shows at once")
	auras["Lightning Shield"] = nil; fire("UNIT_AURA", "player")

	-- samples only while the settings are open and only where the real thing is not showing
	enchants = { { hasEnchant = true, timeLeft = 1800000 } }; second()
	ns.optionsOpen = true; ns.updatePreview()
	check(W().shown and S().shown and S().count.text == "3", "settings open: samples of both icons")
	ns.optionsOpen = false; ns.updatePreview()
	check(not W().shown and not S().shown, "settings closed: samples gone")
	enchants = {}; auras["Lightning Shield"] = { applications = 2 }; fire("UNIT_AURA", "player"); second()
	ns.optionsOpen = true; ns.updatePreview()
	check(S().count.text == "2", "settings open: the real charges win over the sample")
	ns.optionsOpen = false; ns.updatePreview()

	-- cost: nothing drawn while nothing changes
	for k in pairs(CALLS) do CALLS[k] = 0 end
	for _ = 1, 50 do second() end
	for _ = 1, 50 do fire("UNIT_AURA", "player") end
	check(CALLS.SetText == 0 and CALLS.SetTexture == 0 and CALLS.SetVertexColor == 0, "cost: a second with nothing new writes nothing to the screen")
	local before = collectgarbage("count"); collectgarbage("stop")
	local b0 = collectgarbage("count")
	for _ = 1, 100 do second() end
	local kb = (collectgarbage("count") - b0) / 100
	collectgarbage("restart")
	check(kb < 3, ("cost: under 3 KB of garbage per second for both icons (%.2f)"):format(kb))

	-- where they sit
	enchants = {}; second()
	db.shieldOn, db.weaponOn = true, true; ns.updatePreview()
	check(S().anchor[4] == 0 and W().anchor[4] == (db.size * 0.75 + 0.5 - (db.size * 0.75 + 0.5) % 1) + db.spacing,
		"place: shield first, weapon next to it (" .. tostring(S().anchor[4]) .. ", " .. tostring(W().anchor[4]) .. ")")
	db.shieldOn = false; ns.updatePreview()
	check(W().anchor[4] == 0, "place: with the shield icon off the weapon icon takes the first place")
	db.shieldOn = true; ns.updatePreview()
	check(aux.anchor[1] == "TOPLEFT" and aux.anchor[2] == bar() and aux.anchor[3] == "BOTTOMLEFT", "place: attached -> under the totem bar")
	db.vertical = true; ns.apply()
	check(aux.anchor[1] == "TOPRIGHT" and aux.anchor[2] == bar() and aux.anchor[3] == "TOPLEFT", "place: vertical bar -> to the left of it")
	check(W().anchor[5] ~= 0 or S().anchor[5] ~= 0, "place: vertical bar -> the two icons stack")
	db.vertical = false; ns.apply()
	db.auxAnchor = "free"; ns.updatePreview()
	check(aux.anchor[2] == UIParent, "place: not attached -> its own place on the screen")
	local moved = false
	rawset(aux, "StartMoving", function() moved = true end)
	db.locked = true; W().scripts.OnDragStart(W())
	check(not moved, "drag: locked -> no moving")
	db.locked = false; W().scripts.OnDragStart(W())
	check(moved, "drag: unlocked and not attached -> moves")
	W().scripts.OnDragStop(W())
	check(db.auxX == 10 and db.auxY == 20 and db.auxPoint == "CENTER", "drag: the new place is saved")
	moved = false; db.auxAnchor = "bar"; ns.updatePreview(); W().scripts.OnDragStart(W())
	check(not moved, "drag: attached -> the icons never move on their own")
	db.locked = true
	db.auxAnchor = "free"; ns.resetPosition()
	check(db.auxX == 0 and db.auxY == -260, "reset position also puts the icons back")
	db.auxAnchor = "bar"; ns.updatePreview()

	-- combat: only shown / hidden; placement and size wait for the fight to end
	enchants = { { hasEnchant = true, timeLeft = 1800000 } }; auras["Lightning Shield"] = nil
	second(); fire("UNIT_AURA", "player")
	inCombat = true; fire("PLAYER_REGEN_DISABLED")
	local sizeBefore = S().w
	enchants = {}; second()
	check(W().shown, "combat: the enchant ran out in a fight -> the icon appears")
	auras["Lightning Shield"] = { applications = 3 }; fire("UNIT_AURA", "player")
	check(S().shown and S().count.text == "3", "combat: shield cast in a fight -> the icon appears")
	auras["Lightning Shield"].applications = 1; fire("UNIT_AURA", "player")
	check(S().count.text == "1", "combat: the charge count follows")
	db.size = 50; db.vertical = true; ns.apply(); ns.updatePreview()
	check(S().w == sizeBefore and aux.anchor[1] == "TOPLEFT", "combat: a size / layout change waits (no resize, no re-anchor)")
	db.locked = false; db.auxAnchor = "free"; ns.updatePreview()
	check(aux.anchor[2] == bar(), "combat: un-attaching waits too")
	db.locked = true
	inCombat = false; fire("PLAYER_REGEN_ENABLED")
	check(S().w == 38 and aux.anchor[1] == "CENTER" and aux.anchor[2] == UIParent, ("combat over: the waiting changes are applied (size 38, own place) w=%s a1=%s"):format(tostring(S().w), tostring(aux.anchor[1])))
	db.size = 36; db.vertical = false; db.auxAnchor = "bar"; ns.updatePreview()
	-- the whole fight touched no protected frame
	local blocked
	for _, l in ipairs(ShamanKitDB.log or {}) do if l:find("ACTION_BLOCKED") or l:find("ERROR") then blocked = l end end
	check(blocked == nil, "icons: no error and no blocked action in the log" .. (blocked and (" -> " .. blocked) or ""))
	enchants = { { hasEnchant = true, timeLeft = 1800000 } }; auras["Lightning Shield"] = nil
	second(); fire("UNIT_AURA", "player")
	check(not W().shown and not S().shown, "icons: back to nothing when both are fine")

	-- ---- placement: side of the bar, alignment, nudges, size, warning time
	do
		db.distanceMode = "off"; db.auxAnchor = "bar"; db.vertical = false; db.size, db.spacing = 36, 4
		db.auxSide, db.auxAlign, db.auxOffX, db.auxOffY, db.auxScale = "auto", "start", 0, 0, 75
		local function at(point, rel, relPoint, x, y, msg)
			ns.updatePreview()
			local a = aux.anchor
			check(a[1] == point and a[2] == rel and a[3] == relPoint and a[4] == x and a[5] == y,
				("%s (%s %s %s %s %s)"):format(msg, tostring(a[1]), a[2] == bar() and "bar" or "?", tostring(a[3]), tostring(a[4]), tostring(a[5])))
		end
		at("TOPLEFT", bar(), "BOTTOMLEFT", 0, -6, "side auto, horizontal bar: below, at its start")
		db.auxSide = "top";    at("BOTTOMLEFT", bar(), "TOPLEFT", 0, 6, "side above")
		db.auxSide = "left";   at("TOPRIGHT", bar(), "TOPLEFT", -6, 0, "side left")
		db.auxSide = "right";  at("TOPLEFT", bar(), "TOPLEFT", 6 + 4 * 36 + 3 * 4, 0, "side right of a horizontal bar: after all four places (a new totem lands in the next one)")
		db.auxSide = "bottom"; db.auxAlign = "center"; at("TOP", bar(), "BOTTOM", 0, -6, "below, middle")
		db.auxAlign = "end";   at("TOPRIGHT", bar(), "BOTTOMRIGHT", 0, -6, "below, end")
		db.auxSide = "right";  db.auxAlign = "end"; at("BOTTOMLEFT", bar(), "BOTTOMLEFT", 6 + 156, 0, "right, end: bottom edge, after all four places")
		db.auxSide, db.auxAlign = "left", "center"; at("RIGHT", bar(), "LEFT", -6, 0, "left, middle")
		db.auxSide, db.auxAlign = "bottom", "start"
		db.auxOffX, db.auxOffY = 10, -3; at("TOPLEFT", bar(), "BOTTOMLEFT", 10, -9, "nudge left/right and up/down is added")
		db.auxOffX, db.auxOffY = 0, 0
		db.distanceMode = "bar"; at("TOPLEFT", bar(), "BOTTOMLEFT", 0, -(3 + 6 + 6), "below a bar with range bars: clear of them")
		db.distanceMode = "yards"; at("TOPLEFT", bar(), "BOTTOMLEFT", 0, -18, "below a bar with yards text: clear of it")
		db.distanceMode = "off"
		-- vertical bar
		db.vertical = true; db.auxSide = "auto"
		at("TOPRIGHT", bar(), "TOPLEFT", -6, 0, "side auto, vertical bar: to its left")
		db.auxSide = "right"; db.distanceMode = "bar"; at("TOPLEFT", bar(), "TOPRIGHT", 3 + 6 + 6, 0, "right of a vertical bar: clear of its range bars")
		db.distanceMode = "off"
		db.auxSide = "bottom"; at("TOPLEFT", bar(), "TOPLEFT", 0, -(6 + 156), "below a vertical bar: after all four places")
		db.auxSide = "left"; ns.updatePreview()
		check(W().anchor[4] == 0 and W().anchor[5] < 0 and S().anchor[5] == 0, "beside the bar the two icons stack (shield on top)")
		db.auxSide = "bottom"; db.vertical = false; ns.updatePreview()
		check(W().anchor[5] == 0 and W().anchor[4] > 0 and S().anchor[4] == 0, "under the bar the two icons sit side by side (shield first)")
		-- a damaged value means the usual spot
		db.auxSide, db.auxAlign, db.auxOffX = "sideways", 7, "x"
		at("TOPLEFT", bar(), "BOTTOMLEFT", 0, -6, "damaged side / align / nudge fall back to the usual spot")
		db.auxSide, db.auxAlign, db.auxOffX = "auto", "start", 0

		-- size
		db.auxScale = 100; ns.updatePreview(); check(S().w == 36, "size 100%: as big as a totem icon")
		db.auxScale = 50; ns.updatePreview(); check(S().w == 18, "size 50%: half")
		db.size = 24; ns.updatePreview(); check(S().w == 16, "size: never smaller than 16")
		db.size = 36; db.auxScale = 75; ns.updatePreview(); check(S().w == 27, "size 75% of 36 = 27")

		-- warning time
		enchants = { { hasEnchant = true, timeLeft = 45000 } }
		db.auxWarnMin = 0; second(); check(not W().shown, "warn 0: only when it is gone (45 s left is quiet)")
		db.auxWarnMin = 5; enchants[1].timeLeft = 240000; second()
		check(W().shown and W().time.text == "4m", "warn 5 min: 4 minutes left shows 4m (" .. tostring(W().time.text) .. ")")
		enchants[1].timeLeft = 310000; second(); check(not W().shown, "warn 5 min: 5 min 10 s left is quiet")
		db.auxWarnMin = 2; enchants = {}; second()
		check(W().shown and W().time.text == "", "warn 2 min (the default): gone still shows")
		db.auxWarnMin = nil; enchants = { { hasEnchant = true, timeLeft = 100000 } }; second()
		check(W().shown, "a missing warn setting means 2 minutes")
		db.auxWarnMin = 2; enchants = {}; second()

		-- A SAMPLE LOOKS EXACTLY LIKE THE REAL ICON, so it must never stay on screen: with the frames unlocked and the
		-- icons in a place of their own (the reported case) a fine enchant and no shield must show NOTHING.
		enchants = { { hasEnchant = true, timeLeft = 1800000 } }; auras["Lightning Shield"] = nil; fire("UNIT_AURA", "player"); second()
		db.locked = true; db.auxAnchor = "free"; ns.optionsOpen = false; ns.updatePreview()
		check(not W().shown and not S().shown, "locked and detached: nothing to see when all is well")
		db.locked = false; ns.updatePreview(); second(); fire("UNIT_AURA", "player")
		check(not W().shown, "REPORTED BUG: unlocked + own place + enchant present: the weapon icon must NOT show")
		check(not S().shown, "REPORTED BUG: unlocked + own place + no Lightning Shield: the shield icon must NOT show")
		for _ = 1, 3 do second() end
		check(not W().shown and not S().shown, "...and it stays that way")
		-- the real things still show, unlocked or not
		enchants = {}; second()
		check(W().shown and W().glow.shown, "unlocked, own place: a really missing enchant shows")
		enchants = { { hasEnchant = true, timeLeft = 1800000 } }; second()
		check(not W().shown, "unlocked, own place: enchant back -> gone")
		auras["Lightning Shield"] = { applications = 2 }; fire("UNIT_AURA", "player")
		check(S().shown and S().count.text == "2", "unlocked, own place: a real shield shows with its charges")
		auras["Lightning Shield"] = nil; fire("UNIT_AURA", "player")
		check(not S().shown, "unlocked, own place: shield gone -> gone")
		-- samples belong to an open settings page only
		ns.optionsOpen = true; ns.updatePreview()
		check(W().shown and S().shown, "settings page open: samples of both")
		ns.optionsOpen = false; ns.updatePreview()
		check(not W().shown and not S().shown, "settings page closed: samples gone, whatever the lock or place")
		db.auxAnchor = "bar"; ns.updatePreview()
		check(not W().shown and not S().shown, "unlocked but attached: nothing either")
		db.locked = true; ns.updatePreview()
		db.auxAnchor = "bar"
	end

	-- ---- attached to the player frame
	do
		local function at(point, rel, relPoint, x, y, msg)
			ns.updatePreview()
			local a = aux.anchor
			check(a[1] == point and a[2] == rel and a[3] == relPoint and a[4] == x and a[5] == y,
				("%s (%s %s %s %s %s)"):format(msg, tostring(a[1]), a[2] == PlayerFrame and "player" or (a[2] == bar() and "bar" or "?"), tostring(a[3]), tostring(a[4]), tostring(a[5])))
		end
		db.distanceMode = "bar"; db.vertical = false; db.attach = false; db.locked = true
		db.auxSide, db.auxAlign, db.auxOffX, db.auxOffY = "auto", "start", 0, 0
		db.auxAnchor = "player"
		at("TOPLEFT", PlayerFrame, "BOTTOMLEFT", 0, -6, "player frame, side auto: below it (the totem bar's range bars are not in the way here)")
		db.auxSide = "top";    at("BOTTOMLEFT", PlayerFrame, "TOPLEFT", 0, 6, "player frame, above")
		db.auxSide = "left";   at("TOPRIGHT", PlayerFrame, "TOPLEFT", -6, 0, "player frame, left")
		db.auxSide = "right";  at("TOPLEFT", PlayerFrame, "TOPRIGHT", 6, 0, "player frame, right: next to it, no 'after all four places' (there are no totems there)")
		db.auxSide, db.auxAlign = "bottom", "end"; at("TOPRIGHT", PlayerFrame, "BOTTOMRIGHT", 0, -6, "player frame, below, end")
		db.auxAlign = "center"; at("TOP", PlayerFrame, "BOTTOM", 0, -6, "player frame, below, middle")
		db.auxAlign, db.auxOffX, db.auxOffY = "start", 4, 5; at("TOPLEFT", PlayerFrame, "BOTTOMLEFT", 4, -1, "player frame: the nudge is added")
		db.auxOffX, db.auxOffY = 0, 0
		db.vertical = true; db.auxSide = "auto"
		at("TOPLEFT", PlayerFrame, "BOTTOMLEFT", 0, -6, "player frame: a vertical totem bar changes nothing")
		db.vertical = false
		-- when the totem bar sits under the player frame, auto keeps clear of it
		db.attach = true; ns.updatePreview()
		at("BOTTOMLEFT", PlayerFrame, "TOPLEFT", 0, 6, "player frame + the bar attached to it: auto goes above")
		db.auxSide = "bottom"; at("TOPLEFT", PlayerFrame, "BOTTOMLEFT", 0, -6, "player frame + bar attached: an explicit 'Below' is still obeyed")
		db.attach = false; db.auxSide = "auto"; ns.updatePreview()
		-- the icons' own order and direction work here too
		db.auxSide = "left"; ns.updatePreview()
		check(W().anchor[5] < 0 and S().anchor[5] == 0, "player frame, left: the two icons stack")
		db.auxSide = "auto"; ns.updatePreview()
		-- no player frame (another UI replaced it): fall back to the totem bar, never an error
		local saved = PlayerFrame
		PlayerFrame = nil; ns.updatePreview()
		check(ns.auxMode() == "bar" and aux.anchor[2] == bar(), "no player frame: the icons use the totem bar")
		PlayerFrame = saved; ns.updatePreview()
		check(ns.auxMode() == "player" and aux.anchor[2] == PlayerFrame, "player frame back: the icons go back to it")
		-- dragging and samples belong to 'own place' only
		local moved = false
		rawset(aux, "StartMoving", function() moved = true end)
		db.locked = false; ns.updatePreview(); W().scripts.OnDragStart(W())
		check(not moved, "player frame: the icons are not draggable")
		enchants = { { hasEnchant = true, timeLeft = 1800000 } }; auras["Lightning Shield"] = nil; second()
		check(not W().shown and not S().shown, "player frame, unlocked: no sample icons")
		db.locked = true
		-- in a fight the move waits
		db.auxAnchor = "bar"; ns.updatePreview()
		inCombat = true; fire("PLAYER_REGEN_DISABLED")
		db.auxAnchor = "player"; ns.updatePreview()
		check(aux.anchor[2] == bar(), "player frame chosen in a fight: it waits")
		inCombat = false; fire("PLAYER_REGEN_ENABLED")
		check(aux.anchor[2] == PlayerFrame, "player frame: applied when the fight ends")
		db.auxAnchor = "bar"; db.distanceMode = "off"; ns.updatePreview()
	end

	-- ---- settings from older versions
	do
		local function mig(t) ns.migrate(t); return t end
		local t = mig({ auxAttached = false }); check(t.auxAnchor == "free" and t.auxAttached == nil, "migrate: 'not attached' (0.8) -> own place")
		t = mig({ auxAttached = true }); check(t.auxAnchor == "bar" and t.auxAttached == nil, "migrate: 'attached' (0.8) -> the totem bar")
		t = mig({}); check(t.auxAnchor == "bar", "migrate: nothing saved -> the totem bar")
		t = mig({ auxAnchor = "player", auxAttached = false }); check(t.auxAnchor == "player" and t.auxAttached == nil, "migrate: a choice already made is kept")
		t = mig({ showRange = false }); check(t.showOut == false, "migrate: the old single range switch hid both marks")
		t = mig({ showRange = false, showOut = true }); check(t.showOut == true, "migrate: an explicit cross setting is kept")
		check(ns.defaults.auxAttached == nil and ns.defaults.auxAnchor == "bar", "defaults: auxAnchor replaces auxAttached")
	end

	-- ---- dragging: only out of combat, only what really started, nothing saved otherwise
	do
		db.locked = false; db.attach = false; db.auxAnchor = "bar"; db.x, db.y, db.point = 5, 6, "TOP"; db.auxX, db.auxY, db.auxPoint = 7, 8, "LEFT"
		inCombat = false; fire("PLAYER_REGEN_ENABLED")
		local B = bar()
		local H = _G.ShamanKitHit2
		-- in combat the (protected) bar and its click buttons are never asked to move: the mock raises
		-- ADDON_ACTION_BLOCKED for StartMoving / StopMovingOrSizing on them, as the real game did in the log
		inCombat = true; fire("PLAYER_REGEN_DISABLED")
		local ok1, e1 = pcall(B.scripts.OnDragStart, B)
		local ok2, e2 = pcall(H.scripts.OnDragStart, H)
		local ok3, e3 = pcall(B.scripts.OnDragStop, B)
		local ok4, e4 = pcall(H.scripts.OnDragStop, H)
		check(ok1 and ok2 and ok3 and ok4, "drag in combat: the bar is not touched (no blocked action)" .. ((not (ok1 and ok2 and ok3 and ok4)) and (" -> " .. tostring(e1 or e2 or e3 or e4)) or ""))
		check(db.x == 5 and db.y == 6 and db.point == "TOP", "drag in combat: nothing was saved")
		inCombat = false; fire("PLAYER_REGEN_ENABLED")
		-- out of combat a drag moves and saves
		local started, stopped = 0, 0
		rawset(B, "StartMoving", function() started = started + 1 end)
		rawset(B, "StopMovingOrSizing", function() stopped = stopped + 1 end)
		H.scripts.OnDragStart(H)
		check(started == 1, "drag out of combat, started on a totem icon: the bar moves")
		H.scripts.OnDragStop(H)
		check(stopped == 1 and db.x == 10 and db.y == 20 and db.point == "CENTER", "drag out of combat: finished and the place saved")
		-- a drag that never started saves nothing
		db.x, db.y, db.point = 5, 6, "TOP"; stopped = 0
		B.scripts.OnDragStop(B)
		check(stopped == 0 and db.x == 5 and db.point == "TOP", "a drag that never started: not finished, nothing saved")
		db.locked = true; B.scripts.OnDragStart(B); started = 0; B.scripts.OnDragStart(B)
		check(started == 0, "locked: the bar does not move")
		db.locked = false; db.attach = true; B.scripts.OnDragStart(B)
		check(started == 0, "bar under the player frame: it does not move")
		db.attach = false
		-- a fight that starts in the middle of a drag: finished (and saved) when it ends, not during
		B.scripts.OnDragStart(B)
		check(started == 1, "mid-drag: started")
		inCombat = true; fire("PLAYER_REGEN_DISABLED")
		local okm = pcall(B.scripts.OnDragStop, B)
		check(okm and stopped == 0, "mid-drag fight: no call into the restricted bar during the fight")
		inCombat = false; db.x = 5; fire("PLAYER_REGEN_ENABLED")
		check(stopped == 1 and db.x == 10, "mid-drag fight: finished when it ends and the place saved")
		rawset(B, "StartMoving", nil); rawset(B, "StopMovingOrSizing", nil)
		-- the buff icons: only a drag that started saves a place; attached icons never overwrite it
		db.auxAnchor = "bar"; db.locked = false
		W().scripts.OnDragStop(W())
		check(db.auxX == 7 and db.auxY == 8 and db.auxPoint == "LEFT", "icons attached: a stray drag-stop does not overwrite the own place with a bar-relative spot")
		db.auxAnchor = "free"; ns.updatePreview()
		rawset(aux, "StartMoving", function() end)
		W().scripts.OnDragStop(W())
		check(db.auxX == 7 and db.auxPoint == "LEFT", "icons: a drag that never started saves nothing")
		inCombat = true; fire("PLAYER_REGEN_DISABLED"); W().scripts.OnDragStart(W()); W().scripts.OnDragStop(W())
		check(db.auxX == 7, "icons: no drag in combat")
		inCombat = false; fire("PLAYER_REGEN_ENABLED")
		rawset(aux, "StartMoving", nil)
		db.locked = true; db.auxAnchor = "bar"; ns.updatePreview()
	end

	-- ---- the settings pages
	do
		local pages = savedCat.pages
		local function frameWith(pred) for _, f in ipairs(frames) do if pred(f) and (f.parentFrame == nil or f.kind ~= "CheckButton" or f.parentFrame == pages[4]) then return f end end end
		check(pages[1].name == "ShamanKit" and pages[2].name == "Totem bar" and pages[3].name == "Totems" and pages[4].name == "Buffs",
			"pages: ShamanKit (home), Totem bar, Totems, Buffs")
		check(allCats[2].parent == allCats[1] and allCats[3].parent == allCats[1] and allCats[4].parent == allCats[1], "pages: the three others are sub-pages of the home page")
		check(allCats[1].name == "ShamanKit", "pages: the category is called ShamanKit")
		-- the home page has a button to each page
		local function homeButton(label)
			return frameWith(function(f) return f.kind == "Button" and f.text == label and f.scripts.OnClick end)
		end
		for i, label in ipairs({ "Totem bar", "Totems", "Buffs" }) do
			local btn = homeButton(label)
			check(btn ~= nil, "home: a button for " .. label)
			if btn then btn.scripts.OnClick(btn); check(savedCat.opened == allCats[i + 1].GetID(), "home: the " .. label .. " button opens that page") end
		end
		-- the preview follows the pages: two pages swapped in one go keep it on
		pages[2].scripts.OnShow(); check(ns.optionsOpen, "pages: opening one turns the samples on")
		pages[4].scripts.OnShow(); pages[2].scripts.OnHide()
		check(ns.optionsOpen, "pages: one page hiding while another shows keeps the samples on")
		pages[4].scripts.OnHide(); check(not ns.optionsOpen, "pages: the last one closing turns them off")
		-- choosing a side in the page
		local top = frameWith(function(f) return f.value == "top" and f.scripts.OnClick end)
		check(top ~= nil, "pages: the buffs page has an 'Above' choice")
		top.scripts.OnClick(top)
		check(db.auxSide == "top" and top.checked, "pages: clicking 'Above' selects it")
		check(aux.anchor[1] == "BOTTOMLEFT" and aux.anchor[3] == "TOPLEFT", "pages: and the icons move above the bar")
		local mid = frameWith(function(f) return f.value == "center" and f.scripts.OnClick end)
		mid.scripts.OnClick(mid); check(db.auxAlign == "center", "pages: clicking 'Middle' lines them up in the middle")
		-- attach to: the three choices
		local toPlayer = frameWith(function(f) return f.value == "player" and f.scripts.OnClick end)
		local toFree = frameWith(function(f) return f.value == "free" and f.scripts.OnClick end)
		local toBar = frameWith(function(f) return f.value == "bar" and f.scripts.OnClick end)
		check(toPlayer and toFree and toBar, "pages: attach to the totem bar, the player frame or an own place")
		toPlayer.scripts.OnClick(toPlayer)
		check(db.auxAnchor == "player" and toPlayer.checked and not toBar.checked and aux.anchor[2] == PlayerFrame, "pages: 'Player frame' moves the icons onto the player frame")
		toFree.scripts.OnClick(toFree)
		check(db.auxAnchor == "free" and aux.anchor[2] == UIParent, "pages: 'Own place' frees them")
		toBar.scripts.OnClick(toBar)
		check(db.auxAnchor == "bar" and aux.anchor[2] == bar(), "pages: 'Totem bar' puts them back")
		-- each page resets only its own settings
		db.auxScale, db.auxWarnMin, db.weaponOn, db.size, db.rememberLast = 100, 5, false, 60, false
		pages[4].OnDefault()
		check(db.auxScale == 75 and db.auxWarnMin == 2 and db.weaponOn == true and db.auxSide == "auto" and db.auxAlign == "start" and db.auxAnchor == "bar",
			"defaults on the buffs page: its settings, and the side / alignment, go back")
		check(db.size == 60 and db.rememberLast == false, "defaults on the buffs page: nothing on the other pages changed")
		pages[3].OnDefault(); check(db.rememberLast == true and db.size == 60, "defaults on the totems page: only its own")
		pages[2].OnDefault(); check(db.size == 36, "defaults on the totem bar page: its own")
		db.locked = true
		-- /shamankit <page>
		SlashCmdList.SHAMANKIT("buffs"); check(savedCat.opened == allCats[4].GetID(), "/shamankit buffs opens the buffs page")
		SlashCmdList.SHAMANKIT("icons"); check(savedCat.opened == allCats[4].GetID(), "/shamankit icons (the old name) still opens the buffs page")
		SlashCmdList.SHAMANKIT("totems"); check(savedCat.opened == allCats[3].GetID(), "/shamankit totems opens the totems page")
		SlashCmdList.SHAMANKIT("bar"); check(savedCat.opened == allCats[2].GetID(), "/shamankit bar opens the totem bar page")
		SlashCmdList.SHAMANKIT(""); check(savedCat.opened == 7, "/shamankit opens the home page")
		-- the old command names are still there
		check(SLASH_SHAMANKIT1 == "/shamankit" and SLASH_SHAMANKIT2 == "/totemrange" and SLASH_SHAMANKIT3 == "/trange", "slash: /shamankit, and /totemrange and /trange as before")
		-- a client without sub-pages gets four categories side by side
		local before = #allCats
		local sub = Settings.RegisterCanvasLayoutSubcategory
		Settings.RegisterCanvasLayoutSubcategory = nil
		ns.buildOptions()
		Settings.RegisterCanvasLayoutSubcategory = sub
		check(#allCats == before + 4, "no sub-page support: the pages become categories of their own")
	end

	-- /shamankit status prints both readings
	local lines = {}
	local oldPrint = print
	print = function(...) lines[#lines + 1] = table.concat({ ... }, " ") end
	SlashCmdList.SHAMANKIT("status")
	print = oldPrint
	local sawW, sawS
	for _, l in ipairs(lines) do if l:find("weapon: ok") then sawW = true end if l:find("Lightning Shield: false") then sawS = true end end
	check(sawW and sawS, "status: lists the weapon and the shield readings")
	noErrors("icons: no error line in the log after all of that")
end

check(#printedErrors == 0, "the addon never printed an error line during the whole run" .. (printedErrors[1] and (": " .. printedErrors[1]) or ""))
print(fails == 0 and "ALL PASSED" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
