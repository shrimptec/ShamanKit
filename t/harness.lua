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
		if k == "GetAttribute" then return function(self, n) return self.attrs[n] end end
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
		if k == "CreateAnimationGroup" then
			return function()
				local g = mock("anim")
				rawset(g, "Play", function(s) s.playing = true end)
				rawset(g, "Stop", function(s) s.playing = false end)
				rawset(g, "CreateAnimation", function() return mock("animation") end)
				return g
			end
		end
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
	rawset(b, "ClearAllPoints", function(self) self.anchor = nil end)
	rawset(b, "ClearApplicationCount", function(self) self.countFS, self.countOpts = nil, nil; self.cleared = (self.cleared or 0) + 1 end)
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
		rawset(f, "SetAuraSlotCandidateFilters", function(self, key, filters)
			self.filters = self.filters or {}
			self.filters[key] = filters
			self.filterWrites = (self.filterWrites or 0) + 1
		end)
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
function PlaceAction() end
function PickupAction() end
function hooksecurefunc(obj, name, fn)
	if type(obj) == "string" then fn, name, obj = name, obj, _G end   -- hooksecurefunc("Name", fn)
	local orig = obj[name]
	rawset(obj, name, function(...) if orig then orig(...) end; fn(...) end)
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
BUFF_READS = false     -- the totem BUFFS can be read (out of a fight). Off by default: the older range tests are about the position alone
TOTEM_BUFF = { ["Strength of Earth"] = true, ["Stoneskin"] = true, ["Healing Stream"] = true, ["Mana Spring"] = true, ["Frost Resistance"] = true,
	["Fire Resistance"] = true, ["Nature Resistance"] = true, ["Grace of Air"] = true, ["Windwall"] = true, ["Windfury Totem"] = true, ["Flametongue Totem"] = true }
C_Secrets = { ShouldAurasBeSecret = function() return AURAS_HIDDEN end }
C_UnitAuras = {
	GetAuraDataBySpellName = function(_, name)
		if TOTEM_BUFF[name] and not BUFF_READS then error("not readable in this test") end
		if secretPos then return secret() end
		if AURAS_HIDDEN then return nil end     -- seen in the real log: "nothing", not a secret, even though the aura is there
		return auras[name]
	end,
	-- in a fight (proved by the real log) the data lookups all answer nothing: by name, by id, by index.
	-- Still answered: the list of buff ids (plain numbers) and the count text (a string the addon can't read).
	GetAuraDataByAuraInstanceID = function(_, id) if AURAS_HIDDEN then return nil end return IDAURAS[id] end,
	GetAuraDataByIndex = function(_, i, filter)
		if filter == "HARMFUL" then
			DEBUFF_READS = (DEBUFF_READS or 0) + 1
			if AURAS_HIDDEN then error("Auras cannot be accessed when secret while tainted by 'ShamanKit'") end
			return DEBUFFS and DEBUFFS[i]
		end
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
C_Timer = { After = function(_, fn) timers[#timers + 1] = fn end, NewTicker = function(_, fn) TICKERS = TICKERS or {}; TICKERS[#TICKERS + 1] = fn; return {} end }
local function runTimers() local t = timers; timers = {}; for _, fn in ipairs(t) do fn() end end

local ns = {}
local function load(file) local f = assert(loadfile(file)); f("ShamanKit", ns) end
load("ShamanKit/ShamanKit.lua")
load("ShamanKit/Cures.lua")
load("ShamanKit/Calls.lua")
load("ShamanKit/Options.lua")
load("ShamanKit/CureOptions.lua")
load("ShamanKit/CallOptions.lua")

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
check(#allCats == 6, "settings: a home page and five sub-pages (" .. #allCats .. " registered)")
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
BUFF_READS = true
pos = nil
auras["Strength of Earth"] = nil; t = t + 5; tick()
check(btn(2).mark.tex:find("NotReady"), "no position, no buff -> out of range")
auras["Strength of Earth"] = {}; t = t + 1; tick()
check(btn(2).mark.tex:find("Ready") and not btn(2).mark.tex:find("NotReady"), "no position, buff present -> in range")
inCombat = true
local realAura = C_UnitAuras.GetAuraDataBySpellName
C_UnitAuras.GetAuraDataBySpellName = function() error("restricted") end
t = t + 1; tick()
check(btn(2).mark.shown and btn(2).mark.tex:find("Waiting"), "no position and no buff reading -> yellow ? (unknown), not blank")
C_UnitAuras.GetAuraDataBySpellName = realAura
C_UnitAuras.GetAuraDataBySpellName = realAura
inCombat = false
-- a fight hides auras: the lookup says "nothing" although the buff is there. That is not "out of range".
auras["Strength of Earth"] = {}; AURAS_HIDDEN = true; inCombat = true; tick()
check(btn(2).mark.shown and btn(2).mark.tex:find("Waiting") and not btn(2).mark.tex:find("NotReady"), "REPORTED CLASS: no position, auras hidden in a fight, buff present: yellow ?, never 'out of range'")
AURAS_HIDDEN = false; inCombat = false; t = t + 1; tick()
check(btn(2).mark.tex:find("Ready") and not btn(2).mark.tex:find("NotReady"), "fight over: the buff reading is trusted again")
BUFF_READS = false

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
BUFF_READS = true
pos = { y = 0, x = 0, map = 1 }; auras["Strength of Earth"] = nil; t = t + 1; tick()
check(btn(2).mark.tex:find("NotReady"), "after reload falls back to buff (absent -> out)")
BUFF_READS = false

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
	check(not btn(3).mark.tex:find("ReadyCheck%-Ready"), "...with unknown range, not a guessed green tick")
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
	pos = { y = 0, x = 35, map = 1 }; tick()
	check(g(2).value == 0 and g(2).edge.color[1] > 0.7 and g(2).edge.color[2] < 0.3, "35 yd: empty bar with a red frame")
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
-- ---- left-click a place to cast the totem it shows (secure attributes: set out of combat only)
do
	local holders = {}
	for _, f in ipairs(frames) do if f.kind == "Frame" and f.icon and f.border and not f.name then holders[#holders + 1] = f end end
	local TEX = function(id) return 100000 + id end
	local function hit(slot) return _G["ShamanKitHit" .. slot] end
	local function out() totems = {}; for slot = 1, 4 do fire("PLAYER_TOTEM_UPDATE", slot) end end
	local function put(slot, name, icon) totems[slot] = { name = name, start = t, dur = 300, icon = icon }; fire("PLAYER_TOTEM_UPDATE", slot) end
	local function gone(slot) totems[slot] = nil; fire("PLAYER_TOTEM_UPDATE", slot) end
	local db = ShamanKitDB
	db.order = { 2, 1, 3, 4 }; db.vertical = false; db.distanceMode = "off"; db.locked = true; db.attach = false
	db.hold = nil; ns.fixHold(); db.rememberLast = true; db.leftCast = true; db.reserve = { [2] = true, [3] = true }
	secretMode = false; secretPos = false; inCombat = false; ns.optionsOpen = false; pos = { y = 0, x = 0, map = 1 }
	fire("PLAYER_ENTERING_WORLD"); out()
	check(ns.defaults.leftCast == true, "left-click: on by default")

	put(1, "Searing Totem III", TEX(3599))      -- keeps the bar up
	put(2, "Strength of Earth Totem II", TEX(8075)); gone(2)
	check(db.hold.lastSpell[2] == 8075, "left-click: the spell of the last totem in the place is remembered (Strength of Earth)")
	check(hit(2).attrs["*type1"] == "spell" and hit(2).attrs["*spell1"] == "Strength of Earth Totem", "left-click: the empty place casts it by name")
	check(holders[2].shown and hit(2).mouse == true, "left-click: and its place is clickable while the bar is up")
	check(hit(3).attrs["*type1"] == nil and hit(3).attrs["*spell1"] == nil and hit(3).mouse == false, "left-click: a kept place that has never held a totem casts nothing and takes no clicks")
	check(hit(4).attrs["*type1"] == nil and hit(4).mouse == false, "left-click: a place that is not kept takes no clicks")
	check(hit(2).attrs["*type2"] == "destroytotem", "left-click: right-click still dismisses a totem")
	check(hit(1).attrs["*spell1"] == "Searing Totem", "left-click: a place with a totem out is armed too (so it also works in a fight, when the game won't let this change)")

	-- the choice and the memory
	db.hold.choice[2] = 8143; ns.updatePreview()
	check(hit(2).attrs["*spell1"] == "Tremor Totem", "left-click: a totem picked for the place wins over the remembered one")
	db.rememberLast = false; ns.updatePreview()
	check(hit(2).attrs["*spell1"] == "Tremor Totem", "left-click: ...also with remembering off")
	db.hold.choice[2] = nil; ns.updatePreview()
	check(hit(2).attrs["*type1"] == nil and hit(2).mouse == false, "left-click: no pick and remembering off: the place shows a generic totem and casts nothing")
	db.rememberLast = true; ns.updatePreview()
	check(hit(2).attrs["*spell1"] == "Strength of Earth Totem", "left-click: remembering on again: back to the last totem")

	-- a totem the catalogue does not know must not leave an older one to be cast
	put(2, "Mystery Totem", 777); gone(2)
	check(db.hold.lastSpell[2] == nil and hit(2).attrs["*type1"] == nil, "left-click: an unknown totem clears the remembered spell (never casts the wrong, older totem)")
	put(2, "Stoneskin Totem", TEX(8071)); gone(2)
	check(hit(2).attrs["*spell1"] == "Stoneskin Totem", "left-click: the newest totem in the place is the one cast")

	-- the lock, the switch, the settings
	db.locked = false; ns.updatePreview()
	check(hit(2).attrs["*type1"] == nil and hit(2).mouse == false and hit(1).attrs["*type1"] == nil, "left-click: unlocked bar: nothing casts (a left press moves it)")
	db.locked = true; ns.updatePreview()
	check(hit(2).attrs["*spell1"] == "Stoneskin Totem" and hit(2).mouse == true, "left-click: locked again: back")
	db.leftCast = false; ns.updatePreview()
	check(hit(2).attrs["*type1"] == nil and hit(1).attrs["*type1"] == nil and hit(2).mouse == false, "left-click: switched off: nothing casts and the empty place takes no clicks")
	check(hit(1).mouse == true, "left-click: switched off: a real totem is still clickable (right-click)")
	db.leftCast = true; ns.updatePreview()
	check(hit(2).attrs["*type1"] == "spell", "left-click: switched on again")
	out(); ns.optionsOpen = true; ns.updatePreview()
	check(hit(1).attrs["*type1"] == nil and hit(2).attrs["*type1"] == nil, "left-click: settings preview: samples cast nothing")
	ns.optionsOpen = false; ns.updatePreview()

	-- no totem out at all: nothing to click
	out()
	check(hit(2).mouse == false and hit(3).mouse == false, "left-click: no totem out, the bar is gone: no invisible square takes clicks")
	put(1, "Searing Totem III", TEX(3599))
	check(hit(2).mouse == true, "left-click: a totem comes out: the kept empty place is clickable")

	-- the tooltip of an empty place
	local lines = {}
	rawset(GameTooltip, "AddLine", function(_, text) lines[#lines + 1] = text end)
	hit(2).scripts.OnEnter(hit(2))
	check(GameTooltip.text == "Stoneskin Totem" and lines[1] == "Left-click to cast it", "left-click: the tooltip of the empty place names the totem and says what a click does")
	lines = {}; hit(1).scripts.OnEnter(hit(1))
	check(lines[1] == nil or not tostring(lines[1]):find("Left%-click to cast"), "left-click: the tooltip of a real totem is the usual one")
	rawset(GameTooltip, "AddLine", nil)

	-- a fight: nothing protected is touched; what changed waits until it is over
	local before = hit(2).attrs["*spell1"]
	inCombat = true; secretMode = true
	fire("UNIT_SPELLCAST_SUCCEEDED", "player", "g", 5675)
	totems[3] = { name = "Mana Spring Totem", start = t, dur = 300, icon = 4242 }; fire("PLAYER_TOTEM_UPDATE", 3); runTimers()
	secretMode = false
	check(db.hold.lastSpell[3] == 5675, "left-click: icon hidden in a fight: the spell is learnt from the cast")
	check(hit(3).attrs["*spell1"] == nil and hit(2).attrs["*spell1"] == before, "left-click: in a fight no attribute is changed")
	totems[3] = nil; fire("PLAYER_TOTEM_UPDATE", 3)
	check(holders[3].shown and hit(2).mouse == true, "left-click: a totem expiring in a fight: the empty place shows and the old click still works")
	inCombat = false; fire("PLAYER_REGEN_ENABLED")
	check(hit(3).attrs["*spell1"] == "Mana Spring Totem" and hit(3).mouse == true, "left-click: the fight is over: the new totem is armed")
	noErrors("left-click: nothing raised, nothing blocked")

	-- no needless writes
	local writes = 0
	for slot = 1, 4 do
		local f = hit(slot); local orig = f.SetAttribute
		rawset(f, "SetAttribute", function(self, k, v) writes = writes + 1; return orig(self, k, v) end)
	end
	for _ = 1, 6 do ns.updatePreview() end
	for slot = 1, 4 do rawset(hit(slot), "SetAttribute", nil) end
	check(writes == 0, "left-click: nothing changed: no attribute is written again (" .. writes .. ")")

	-- the settings box, and damaged saved data
	local box
	for _, f in ipairs(frames) do if f.settingKey == "leftCast" then box = f end end
	check(box ~= nil, "settings: a box for it on the totems page")
	box:SetChecked(false); box.scripts.OnClick(box)
	check(db.leftCast == false and hit(2).attrs["*type1"] == nil, "settings: unticking it switches it off at once")
	box:SetChecked(true); box.scripts.OnClick(box)
	check(db.leftCast == true and hit(2).attrs["*type1"] == "spell", "settings: ticking it switches it on at once")
	db.leftCast = false; savedCat.pages[3].OnDefault()
	check(db.leftCast == true, "settings: Defaults on the totems page switches it back on")
	for label, bad in pairs({ ["a string"] = "x", ["junk"] = { [2] = "a", [3] = {}, [1] = 8075 } }) do
		db.hold.lastSpell = bad
		local hh = ns.fixHold()
		check(type(hh.lastSpell) == "table" and hh.lastSpell[2] == nil and hh.lastSpell[3] == nil, "damaged spell memory (" .. label .. ") is cleaned")
	end
	db.hold = nil; ns.fixHold(); db.reserve = {}; out(); ns.updatePreview()
end


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
-- ---- Range: the buff is the truth when it can be read, and the position only answers clearly (a totem lands to your side)
do
	local function mark(slot)
		local tx = btn(slot).mark.tex or ""
		if tx:find("NotReady") then return "out" elseif tx:find("Waiting") then return "?" elseif tx:find("Ready") then return "in" end
		return "none"
	end
	local function place(slot, name, at)
		totems[slot] = { name = name, start = t, dur = 300, icon = 99 }
		pos = at or { y = 0, x = 0, map = 1 }
		fire("PLAYER_TOTEM_UPDATE", slot)
	end
	local function at(x) pos = { y = 0, x = x, map = 1 }; t = t + 1; tick() end
	local function clear() for k in pairs(totems) do totems[k] = nil end; fire("PLAYER_ENTERING_WORLD"); auras["Strength of Earth"] = nil; BUFF_READS = false; AURAS_HIDDEN = false; inCombat = false; pos = { y = 0, x = 0, map = 1 } end
	clear(); ShamanKitDB.distanceMode = "yards"; ShamanKitDB.log = {}
	local calls = 0
	local real = C_UnitAuras.GetAuraDataBySpellName
	C_UnitAuras.GetAuraDataBySpellName = function(...) calls = calls + 1; return real(...) end

	-- just dropped: the buff is not on yet, and that must not read as "out of range"
	BUFF_READS = true
	place(2, "Strength of Earth Totem IV")
	t = t + 1; tick()
	check(mark(2) == "in", "range: just dropped, no buff yet: the position decides (in), not a red cross")
	pos = { y = 0, x = 40, map = 1 }; t = t + 1; tick()
	check(mark(2) == "out", "range: ...but if the position says clearly out it is out")
	pos = { y = 0, x = 5, map = 1 }; t = t + 4; tick()
	check(mark(2) == "out", "range: after a few seconds with no buff, no buff means out")
	-- the buff can be read: it decides, whatever the position says
	place(2, "Strength of Earth Totem IV")
	auras["Strength of Earth"] = {}
	at(10)
	check(mark(2) == "in", "range: buff present, 10 yd: in")
	at(40)
	check(mark(2) == "in", "range: the buff is there at 40 yd by my position: in (the totem is not where I stood)")
	check(btn(2).dist.text == "29.1 yd", "range: ...and the number agrees with the answer, not 40 (" .. tostring(btn(2).dist.text) .. ")")
	auras["Strength of Earth"] = nil
	t = t + 5
	at(5)
	check(mark(2) == "out", "range: no buff, 5 yd: out (a totem a few yards off does not read as 'in' by position)")
	check(btn(2).dist.text == "30.9 yd", "range: ...and the number does not say 5 (" .. tostring(btn(2).dist.text) .. ")")
	local n = 0
	for _, l in ipairs(ShamanKitDB.log) do
		if (l:find("%-> true via buff") and l:find("positionSays=false")) or (l:find("%-> false via buff") and l:find("positionSays=true")) then n = n + 1 end
	end
	check(n == 3, "range: the log notes each time the buff and the position disagree, once (" .. n .. ")")
	local before = #ShamanKitDB.log
	for _ = 1, 12 do t = t + 0.3; tick() end
	check(#ShamanKitDB.log == before, "range: the same answer again and again adds nothing to the log")
	check(ShamanKitDB.log[#ShamanKitDB.log]:find("placed u=") ~= nil, "range: ...with both positions, so the real offset can be worked out")

	-- it is only read every half second per totem
	auras["Strength of Earth"] = {}
	t = t + 1; tick()
	calls = 0
	for _ = 1, 40 do tick() end
	check(calls == 0, "range: ten ticks inside half a second read nothing again (" .. calls .. ")")
	t = t + 0.6; tick(); tick()
	check(calls == 1, "range: after half a second, one read (" .. calls .. ")")
	-- a new totem in the place: the last reading belonged to the old one
	auras["Strength of Earth"] = nil
	place(2, "Strength of Earth Totem IV")
	t = t + 4; tick()
	check(mark(2) == "out", "range: a new totem in the place reads fresh, not the old totem's buff")

	-- a fight: auras are hidden, nothing is read, the position answers only when it is clear
	auras["Strength of Earth"] = {}
	AURAS_HIDDEN = true; inCombat = true
	place(2, "Strength of Earth Totem IV")
	calls = 0
	at(10); check(mark(2) == "in", "range fight: 10 yd of 30: in")
	at(22); check(mark(2) == "in", "range fight: 22 yd of 30 (a band of 4): still in")
	at(27); check(mark(2) == "?", "range fight: 27 yd: close to the edge, so 'can't tell' (yellow ?), not a guess")
	at(30); check(mark(2) == "?", "range fight: right at the edge: ?")
	at(33); check(mark(2) == "?", "range fight: 33 yd: ?")
	at(35); check(mark(2) == "out", "range fight: 35 yd: out")
	check(calls == 0, "range fight: no aura read while the game hides them (" .. calls .. ")")
	check(btn(2).dist.shown, "range fight: the distance still shows at the edge")
	AURAS_HIDDEN = false; inCombat = false

	-- totems without a buff only have the position: the same band, narrower for a small totem
	place(1, "Searing Totem")                              -- 20 yd, band 4
	at(15); check(mark(1) == "in", "range: Searing, 15 of 20: in")
	at(18); check(mark(1) == "?", "range: Searing, 18 of 20: ?")
	at(25); check(mark(1) == "out", "range: Searing, 25 of 20: out")
	place(1, "Earthbind Totem")                            -- 10 yd, band 3 (a third of it at most)
	at(6); check(mark(1) == "in", "range: Earthbind, 6 of 10: in")
	at(8); check(mark(1) == "?", "range: Earthbind, 8 of 10: ?")
	at(14); check(mark(1) == "out", "range: Earthbind, 14 of 10: out")
	place(1, "Stoneclaw Totem")                            -- 8 yd, band 2.4
	at(5); check(mark(1) == "in", "range: Stoneclaw, 5 of 8: in")
	at(9); check(mark(1) == "?", "range: Stoneclaw, 9 of 8: ?")
	at(11); check(mark(1) == "out", "range: Stoneclaw, 11 of 8: out")

	-- the buff totem with the buff readable but no position at all: the buff alone, as before
	place(2, "Strength of Earth Totem IV"); BUFF_READS = true
	auras["Strength of Earth"] = {}; pos = nil; t = t + 1; tick()
	check(mark(2) == "in" and not btn(2).dist.shown, "range: no position, buff present: in, no number")
	-- the buff cannot be read (an error) and there is no position: unknown, never out
	BUFF_READS = false; t = t + 1; tick()
	check(mark(2) == "?", "range: neither buff nor position: ?")
	-- the tooltip says how it was decided
	pos = { y = 0, x = 27, map = 1 }; AURAS_HIDDEN = true; inCombat = true; place(2, "Strength of Earth Totem IV"); at(27)
	local tips = {}
	rawset(GameTooltip, "AddLine", function(_, text) tips[#tips + 1] = text end)
	_G.ShamanKitHit2.scripts.OnEnter(_G.ShamanKitHit2)
	rawset(GameTooltip, "AddLine", nil)
	check(tips[#tips] and tostring(tips[#tips]):find("near the edge") and tostring(tips[#tips]):find("Range unknown") == nil, "range: the tooltip says 'near the edge' (" .. tostring(tips[#tips]) .. ")")
	AURAS_HIDDEN = false; inCombat = false

	-- the setting: on by default, and off is exactly the old way (your drop spot alone, a hard cutoff)
	check(ns.defaults.rangeByBuff == true, "range setting: on by default")
	ShamanKitDB.rangeByBuff = false
	BUFF_READS = true; AURAS_HIDDEN = false; inCombat = false
	auras["Strength of Earth"] = {}
	place(2, "Strength of Earth Totem IV")
	calls = 0
	at(40)
	check(mark(2) == "out", "range setting off: 40 yd by position is out, whatever the buff says")
	at(27)
	check(mark(2) == "in", "range setting off: 27 yd is in (no uncertain band)")
	at(31)
	check(mark(2) == "out", "range setting off: 31 yd is out (a hard cutoff at 30, no ?)")
	check(calls == 0, "range setting off: the buff is not read while there is a position (" .. calls .. ")")
	check(btn(2).dist.text == "31.0 yd", "range setting off: the real number, not adjusted (" .. tostring(btn(2).dist.text) .. ")")
	auras["Strength of Earth"] = nil
	at(5)
	check(mark(2) == "in", "range setting off: no buff, 5 yd: in (the position decides)")
	-- no position at all: the buff is the stand-in, as it always was (and no waiting for the buff to arrive)
	auras["Strength of Earth"] = nil
	place(2, "Strength of Earth Totem IV")
	pos = nil; t = t + 0.1; tick()
	check(mark(2) == "out", "range setting off: no position, no buff, just dropped: out (the old way does not wait for the buff)")
	auras["Strength of Earth"] = {}; t = t + 1; tick()
	check(mark(2) == "in", "range setting off: no position, buff there: in")
	-- a damaged saved value counts as on
	ShamanKitDB.rangeByBuff = "maybe"
	place(2, "Strength of Earth Totem IV")
	auras["Strength of Earth"] = {}
	calls = 0
	at(31)
	check(mark(2) == "in" and calls > 0, "range setting damaged: treated as on (the buff is read and decides)")
	ShamanKitDB.rangeByBuff = true
	-- the settings page
	local page = savedCat.pages[2]
	local box
	for _, f in ipairs(frames) do if f.settingKey == "rangeByBuff" and f.parentFrame == page then box = f end end
	check(box ~= nil, "range setting: a box on the Totem bar page")
	page.OnRefresh()
	check(box.checked == true, "range setting: it shows on")
	box:SetChecked(false); box.scripts.OnClick(box)
	check(ShamanKitDB.rangeByBuff == false, "range setting: unticking switches it off")
	page.OnDefault()
	check(ShamanKitDB.rangeByBuff == true, "range setting: Defaults on this page turns it back on")

	C_UnitAuras.GetAuraDataBySpellName = real
	clear(); ShamanKitDB.distanceMode = "bar"; ShamanKitDB.log = {}
end

-- ---- Calls: buttons for Call of the ..., Totemic Call and Totemic Recall beside the bar (Calls.lua)
do
	local db = ShamanKitDB
	local S = ns.callState
	local CE, CA, CS, TC, TR = 66842, 66843, 66844, 437009, 36936
	KNOWN_SPELLS[CE] = "Call of the Elements"; KNOWN_SPELLS[CA] = "Call of the Ancestors"; KNOWN_SPELLS[CS] = "Call of the Spirits"
	KNOWN_SPELLS[TC] = "Totemic Call"; KNOWN_SPELLS[TR] = "Totemic Recall"
	CALL_KNOWN = { [CE] = true, [CA] = true, [TC] = true, [TR] = true }
	function IsPlayerSpell(id) return CALL_KNOWN[id] == true end
	MOUSE_OVER = false
	function MouseIsOver() return MOUSE_OVER end
	UISpecialFrames = {}
	local cf
	for _, f in ipairs(frames) do if f.registered and f.registered.SPELLS_CHANGED and f.registered.SPELL_UPDATE_COOLDOWN and not f.registered.ACTIONBAR_SLOT_CHANGED then cf = f end end
	assert(cf, "the Calls frame registered its events")
	local function cfire(e, ...) cf.scripts.OnEvent(cf, e, ...) end
	local function bt(i) return _G["ShamanKitCall" .. i] end
	local function lines2(pat) local n = 0; for _, l in ipairs(db.log or {}) do if l:find(pat) then n = n + 1 end end return n end
	local function reset()
		inCombat = false; AURAS_HIDDEN = false
		db.callOn, db.callTotemic, db.callRecall, db.callSide, db.callChoice = false, false, false, "start", 0
		db.vertical, db.size, db.spacing = false, 36, 4
		db.shieldOn, db.weaponOn, db.auxAnchor, db.auxSide = true, true, "bar", "auto"
		CALL_KNOWN = { [CE] = true, [CA] = true, [TC] = true, [TR] = true }
		MOUSE_OVER = false
		ns.callCloseFlyout()
		ns.callApply()
	end

	-- defaults: nothing on, nothing in the way
	check(ns.defaults.callOn == false and ns.defaults.callTotemic == false and ns.defaults.callRecall == false, "calls: every button is off until you switch it on")
	check(ns.defaults.callSide == "start" and ns.defaults.callChoice == 0, "calls: before the totems, the first Call you know")
	reset()
	check(S.group ~= nil and S.group.name == "ShamanKitCalls", "calls: the group frame exists")
	rawset(S.group, "protected", true)                       -- it holds secure buttons: the game restricts it in a fight
	check(not bt(1).shown and not bt(2).shown and not bt(3).shown and bt(1).mouse == false and S.group.shown == false, "calls: all off: nothing on screen, nothing takes a click")
	check(bt(1).tmpl == "SecureActionButtonTemplate" and bt(1).parentFrame == S.group, "calls: the buttons are the game's secure buttons, in the group")

	-- the Call button
	db.callOn = true; ns.callApply()
	local b1 = bt(1)
	check(b1.shown and b1.mouse == true and S.group.shown == true, "calls: Call of the ... on: the button shows and takes the mouse")
	check(b1.attrs.type1 == "spell" and b1.attrs.spell1 == "Call of the Elements", "calls: a click casts Call of the Elements (the first you know)")
	check(b1.icon.tex == 100000 + CE, "calls: its picture is the spell's")
	check(b1.w == 36 and b1.h == 36, "calls: sized like the totem icons")
	check(S.group.anchor[1] == "TOPRIGHT" and S.group.anchor[2] == _G.ShamanKitBar and S.group.anchor[3] == "TOPLEFT" and S.group.anchor[4] == -6 and S.group.anchor[5] == 0, "calls: before the totems: the group's right edge sits 6 px left of the bar")
	check(S.arrow.shown, "calls: two Call spells known: the arrow is there")
	check(not bt(2).shown and not bt(3).shown, "calls: the others stay off")

	-- choosing another one from the arrow's list
	S.arrow.scripts.OnClick(S.arrow)
	local fly = S.flyout
	check(fly and fly.shown and fly.items[1].shown and fly.items[1].callId == CA and not (fly.items[2] and fly.items[2].shown), "calls: the arrow opens a list of the OTHER Call spells (Ancestors)")
	check(fly.items[1].icon.tex == 100000 + CA, "calls: with their pictures")
	check(fly.name == "ShamanKitCallFlyout" and UISpecialFrames[1] == "ShamanKitCallFlyout", "calls: Esc closes the list")
	fly.items[1].scripts.OnClick(fly.items[1])
	check(db.callChoice == CA and b1.attrs.spell1 == "Call of the Ancestors" and b1.icon.tex == 100000 + CA, "calls: picking Ancestors makes the button cast it")
	check(not fly.shown, "calls: ...and the list closes")
	ns.callApply()
	check(b1.attrs.spell1 == "Call of the Ancestors", "calls: the choice stays")
	S.arrow.scripts.OnClick(S.arrow)
	check(fly.items[1].callId == CE, "calls: now the list offers Elements")
	ns.callCloseFlyout()
	-- a choice you can't use any more: back to the first you know
	db.callChoice = CS; ns.callApply()
	check(b1.attrs.spell1 == "Call of the Elements", "calls: a Call spell you don't know is never cast: the first you know")
	-- one known: no arrow, no list
	CALL_KNOWN[CA] = nil; ns.callApply()
	check(not S.arrow.shown, "calls: one Call spell known: no arrow")
	S.arrow.scripts.OnClick(S.arrow)
	check(not fly.shown, "calls: ...and the list does not open")
	-- learning another (level up) while playing
	CALL_KNOWN[CA] = true; CALL_KNOWN[CS] = true
	cfire("SPELLS_CHANGED"); runTimers()
	check(S.arrow.shown and #S.choices == 3, "calls: learning a Call spell updates the button (3 known)")
	S.arrow.scripts.OnClick(S.arrow)
	check(fly.items[1].shown and fly.items[2].shown and fly.items[1].callId ~= fly.items[2].callId, "calls: the list then has the other two")
	ns.callCloseFlyout()
	CALL_KNOWN[CS] = nil; db.callChoice = 0; cfire("SPELLS_CHANGED"); runTimers()

	-- which way the list opens: away from the nearer screen edge
	local function openWith(cx, cy)
		rawset(b1, "GetCenter", function() return cx, cy end)
		rawset(UIParent, "GetCenter", function() return 960, 540 end)
		ns.callCloseFlyout(); S.arrow.scripts.OnClick(S.arrow)
		local a = fly.anchor
		local ar = S.arrow.anchor
		ns.callCloseFlyout()
		return a, ar
	end
	local a, ar = openWith(500, 100)
	check(a[1] == "BOTTOMLEFT" and a[3] == "TOPLEFT" and ar[1] == "BOTTOM" and ar[3] == "TOP", "calls: a bar low on the screen: the list opens upward, the arrow is on top")
	a, ar = openWith(500, 900)
	check(a[1] == "TOPLEFT" and a[3] == "BOTTOMLEFT" and ar[1] == "TOP" and ar[3] == "BOTTOM", "calls: a bar high up: it opens downward, the arrow below")
	db.vertical = true; ns.callApply()
	a, ar = openWith(300, 500)
	check(a[1] == "TOPLEFT" and a[3] == "TOPRIGHT" and ar[1] == "LEFT" and ar[3] == "RIGHT", "calls: a vertical bar on the left: it opens to the right, the arrow on that side")
	a, ar = openWith(1600, 500)
	check(a[1] == "TOPRIGHT" and a[3] == "TOPLEFT" and ar[1] == "RIGHT" and ar[3] == "LEFT", "calls: ...on the right: to the left")
	rawset(b1, "GetCenter", nil); rawset(UIParent, "GetCenter", nil)
	db.vertical = false; ns.callApply()
	-- the list goes away by itself when the mouse is not near it
	S.arrow.scripts.OnClick(S.arrow)
	MOUSE_OVER = true
	for _ = 1, 20 do fly.scripts.OnUpdate(fly, 0.2) end
	check(fly.shown, "calls: the list stays while the mouse is on it")
	MOUSE_OVER = false
	for _ = 1, 6 do fly.scripts.OnUpdate(fly, 0.2) end
	check(not fly.shown, "calls: ...and closes when the mouse has been away a moment")

	-- the other two buttons, in order
	db.callTotemic = true; db.callRecall = true; ns.callApply()
	local b2, b3 = bt(2), bt(3)
	check(b1.shown and b2.shown and b3.shown, "calls: all three on screen")
	check(b1.anchor[4] == 0 and b2.anchor[4] == 40 and b3.anchor[4] == 80, "calls: Call, Totemic Call, Totemic Recall, spaced by size + gap")
	check(b2.attrs.spell1 == "Totemic Call" and b3.attrs.spell1 == "Totemic Recall" and b2.attrs.type1 == "spell", "calls: each casts its own spell")
	check(b2.icon.tex == 100000 + TC and b3.icon.tex == 100000 + TR, "calls: with their pictures")
	check(S.group.w == 3 * 36 + 2 * 4 and S.group.h == 36, "calls: the group is as long as the buttons")
	db.callOn = false; ns.callApply()
	check(not b1.shown and b1.attrs.type1 == nil and b1.attrs.spell1 == nil and b1.mouse == false and not S.arrow.shown, "calls: Call off: its button, click and arrow are gone")
	check(b2.anchor[4] == 0 and b3.anchor[4] == 40 and S.group.w == 2 * 36 + 4, "calls: the rest close up")
	db.callOn = true
	CALL_KNOWN[TR] = nil; ns.callApply()
	check(not b3.shown and b3.attrs.spell1 == nil and b3.mouse == false, "calls: a spell you don't know has no button, even switched on")
	CALL_KNOWN[TR] = true; ns.callApply()
	check(b3.shown and b3.attrs.spell1 == "Totemic Recall", "calls: and does when you learn it")
	CALL_KNOWN[TC] = nil; ns.callApply()
	check(not b2.shown and b2.attrs.spell1 == nil and b2.mouse == false and b3.anchor[4] == 40, "calls: Totemic Call not known: no button, Recall moves up")
	CALL_KNOWN[TC] = true; ns.callApply()
	check(b2.shown and b2.attrs.spell1 == "Totemic Call", "calls: and it comes back when you learn it")
	db.callTotemic = false; ns.callApply()
	check(not b2.shown and b3.anchor[4] == 40, "calls: Totemic Call off: Recall moves up")
	db.callTotemic = true; ns.callApply()

	-- where the group sits
	local full = 4 * 36 + 3 * 4
	db.callSide = "end"; ns.callApply()
	check(S.group.anchor[1] == "TOPLEFT" and S.group.anchor[3] == "TOPLEFT" and S.group.anchor[4] == full + 6, "calls: after the totems: past all four places (" .. tostring(S.group.anchor[4]) .. ")")
	db.vertical = true; db.callSide = "start"; ns.callApply()
	check(S.group.anchor[1] == "BOTTOMLEFT" and S.group.anchor[3] == "TOPLEFT" and S.group.anchor[5] == 6, "calls: vertical bar, before: above it")
	check(b2.anchor[5] == -40 and b2.anchor[4] == 0 and S.group.h == 3 * 36 + 2 * 4 and S.group.w == 36, "calls: the buttons stack down")
	db.callSide = "end"; ns.callApply()
	check(S.group.anchor[1] == "TOPLEFT" and S.group.anchor[5] == -(full + 6), "calls: vertical bar, after: below the places")
	db.vertical = false; db.callSide = "start"; ns.callApply()
	-- the buff icons on the same side: the buttons take the opposite one
	db.shieldOn = true; db.auxAnchor = "bar"; db.auxSide = "left"
	ns.callApply()
	check(S.side == "right" and S.sideMoved == true and S.group.anchor[1] == "TOPLEFT", "calls: buff icons on the left: the buttons go to the right")
	db.callSide = "end"; db.auxSide = "right"; ns.callApply()
	check(S.side == "left" and S.sideMoved == true, "calls: buff icons on the right: the buttons go to the left")
	db.shieldOn = false; db.weaponOn = false; ns.callApply()
	check(S.side == "right" and not S.sideMoved, "calls: both buff icons off: nothing in the way")
	db.shieldOn = true; db.auxAnchor = "player"; ns.callApply()
	check(S.side == "right" and not S.sideMoved, "calls: buff icons on the player frame: nothing in the way")
	db.auxAnchor = "bar"; db.auxSide = "bottom"; ns.callApply()
	check(S.side == "right" and not S.sideMoved, "calls: buff icons under the bar, buttons on the right: nothing in the way")
	db.callSide = "bottom"; ns.callApply()
	check(S.side == "top" and S.sideMoved, "calls: buff icons under the bar, buttons asked for below: they go above")
	db.callSide = "start"; db.auxSide = "auto"; ns.callApply()

	-- size: a share of the totem icons, never under 16 px
	db.shieldOn = false; db.weaponOn = false; db.callSide = "start"; db.callAlign = "start"
	db.callOn = true; db.callTotemic = true; db.callRecall = true
	db.callScale = 150; ns.callApply()
	check(b1.w == 54 and b3.w == 54 and S.group.w == 3 * 54 + 2 * 4, "calls size: 150% of 36 is 54 px, the group follows")
	check(b2.anchor[4] == 58, "calls size: and the buttons are spaced by the new size")
	db.callScale = 50; ns.callApply()
	check(b1.w == 18, "calls size: 50% is 18 px")
	db.size = 24; ns.callApply()
	check(b1.w == 16, "calls size: never under 16 px")
	db.size = 36; db.callScale = "big"; ns.callApply()
	check(b1.w == 36, "calls size: a damaged value counts as 100%")
	db.callScale = 150; ns.callApply()
	S.arrow.scripts.OnClick(S.arrow)
	check(fly.items[1].w == 54, "calls size: the pick list's buttons follow too")
	ns.callCloseFlyout()
	db.callScale = 100; ns.callApply()

	-- the side and the place along it (a horizontal bar; the 'bottom' room is the range bar's)
	local bar2 = _G.ShamanKitBar
	local function anchorIs(pt, rel, relPt, x, y, why)
		local a = S.group.anchor
		check(a[1] == pt and a[2] == rel and a[3] == relPt and a[4] == x and a[5] == y,
			("calls place: %s (got %s %s %s %s)"):format(why, tostring(a[1]), tostring(a[3]), tostring(a[4]), tostring(a[5])))
	end
	local function at(side, align) db.callSide, db.callAlign = side, align; ns.callApply() end
	at("left", "start");   anchorIs("TOPRIGHT", bar2, "TOPLEFT", -6, 0, "left, start")
	at("left", "center");  anchorIs("RIGHT", bar2, "LEFT", -6, 0, "left, middle")
	at("left", "end");     anchorIs("BOTTOMRIGHT", bar2, "BOTTOMLEFT", -6, 0, "left, end")
	at("top", "start");    anchorIs("BOTTOMLEFT", bar2, "TOPLEFT", 0, 6, "above, start")
	at("top", "center");   anchorIs("BOTTOM", bar2, "TOP", 0, 6, "above, middle")
	at("top", "end");      anchorIs("BOTTOMRIGHT", bar2, "TOPRIGHT", 0, 6, "above, end")
	at("bottom", "start"); anchorIs("TOPLEFT", bar2, "BOTTOMLEFT", 0, -15, "below, start (room for the range bar)")
	at("bottom", "end");   anchorIs("TOPRIGHT", bar2, "BOTTOMRIGHT", 0, -15, "below, end")
	at("right", "start");  anchorIs("TOPLEFT", bar2, "TOPLEFT", full + 6, 0, "right, start: past all four places")
	at("right", "center"); anchorIs("LEFT", bar2, "LEFT", full + 6, 0, "right, middle")
	at("right", "end");    anchorIs("BOTTOMLEFT", bar2, "BOTTOMLEFT", full + 6, 0, "right, end")
	db.callOffX, db.callOffY = 10, -4
	at("left", "start");   anchorIs("TOPRIGHT", bar2, "TOPLEFT", 4, -4, "a nudge moves it from there")
	db.callOffX, db.callOffY = "x", 0/0; ns.callApply()
	anchorIs("TOPRIGHT", bar2, "TOPLEFT", -6, 0, "damaged nudges count as none")
	db.callOffX, db.callOffY = 0, 0
	at("sideways", "diagonal"); anchorIs("TOPRIGHT", bar2, "TOPLEFT", -6, 0, "a damaged side is 'before the totems', a damaged align is the start")
	at("end", "start");    anchorIs("TOPLEFT", bar2, "TOPLEFT", full + 6, 0, "the old 'end' is past the last place")
	db.vertical = true
	at("start", "start");  anchorIs("BOTTOMLEFT", bar2, "TOPLEFT", 0, 6, "vertical bar, before the totems: above")
	at("end", "start");    anchorIs("TOPLEFT", bar2, "TOPLEFT", 0, -(full + 6), "vertical bar, after: below the places")
	at("left", "start");   anchorIs("TOPRIGHT", bar2, "TOPLEFT", -6, 0, "vertical bar, left")
	at("right", "start");  anchorIs("TOPLEFT", bar2, "TOPRIGHT", 15, 0, "vertical bar, right (room for the range bar)")
	check(b2.anchor[5] == -40 and b2.anchor[4] == 0, "calls place: a vertical bar stacks the buttons")
	db.vertical = false
	at("start", "start")

	-- showing: all the time, or only while a totem is out
	local function pair() return S.group.shown, b1.mouse end
	db.callShow = "always"; ns.callApply()
	local sh, mo = pair()
	check(sh == true and mo == true, "calls show: 'all the time': on screen with no totem out")
	db.callShow = "bar"; ns.callApply()
	sh, mo = pair()
	check(sh == false and mo == false, "calls show: 'only while a totem is out', none out: hidden and nothing takes a click")
	totems[2] = { name = "Strength of Earth Totem IV", start = t, dur = 300, icon = 99 }
	fire("PLAYER_TOTEM_UPDATE", 2)
	sh, mo = pair()
	check(sh == true and mo == true, "calls show: a totem comes out: the buttons appear")
	totems[2] = nil
	fire("PLAYER_TOTEM_UPDATE", 2)
	sh, mo = pair()
	check(sh == false and mo == false, "calls show: it is gone: the buttons go too")
	ns.optionsOpen = true; ns.updatePreview()
	check(S.group.shown == true, "calls show: a settings page open shows them (so you can set them up)")
	ns.optionsOpen = false; ns.updatePreview()
	check(S.group.shown == false, "calls show: ...and closing it hides them again")
	-- a totem comes out in a fight: nothing is touched until it is over
	local gw = 0
	for _, f in ipairs({ S.group }) do local o = f.SetShown; rawset(f, "SetShown", function(self, v) gw = gw + 1; return o(self, v) end) end
	inCombat = true
	totems[2] = { name = "Strength of Earth Totem IV", start = t, dur = 300, icon = 99 }
	local okf = pcall(fire, "PLAYER_TOTEM_UPDATE", 2)
	check(okf and gw == 0 and S.group.shown == false, "calls show fight: a totem out in a fight: no error, the group is not touched")
	inCombat = false
	cfire("PLAYER_REGEN_ENABLED"); fire("PLAYER_REGEN_ENABLED"); runTimers()
	check(S.group.shown == true, "calls show fight: after it the buttons appear")
	inCombat = true
	totems[2] = nil
	pcall(fire, "PLAYER_TOTEM_UPDATE", 2)
	check(S.group.shown == true and gw == 1, "calls show fight: the totem expiring in a fight: the buttons stay until it is over")
	inCombat = false
	cfire("PLAYER_REGEN_ENABLED"); fire("PLAYER_REGEN_ENABLED"); runTimers()
	check(S.group.shown == false, "calls show fight: ...then they go")
	rawset(S.group, "SetShown", nil)
	db.callShow = "always"; ns.callApply()
	check(S.group.shown == true, "calls show: back to all the time")
	db.callShow = "whenever"; ns.callApply()
	check(S.group.shown == true, "calls show: a damaged value counts as all the time")
	db.callShow = "always"

	-- a pass with nothing changed writes nothing
	ns.callApply()
	local clears = 0
	local oc = S.group.ClearAllPoints
	rawset(S.group, "ClearAllPoints", function(self) clears = clears + 1; return oc(self) end)
	local attrWrites = 0
	for _, b in ipairs({ b1, b2, b3 }) do local o = b.SetAttribute; rawset(b, "SetAttribute", function(self, k, v) attrWrites = attrWrites + 1; return o(self, k, v) end) end
	for _ = 1, 20 do ns.callApply() end
	check(clears == 0 and attrWrites == 0, "calls: a pass with nothing changed moves and arms nothing (" .. clears .. ", " .. attrWrites .. ")")
	db.callOffX = 3; ns.callApply()
	check(clears == 1, "calls: ...and one setting changed does it once")
	db.callOffX = 0; ns.callApply()
	rawset(S.group, "ClearAllPoints", nil)
	for _, b in ipairs({ b1, b2, b3 }) do rawset(b, "SetAttribute", nil) end

	-- a place of their own
	db.callAnchor = "free"; ns.callApply()
	anchorIs("CENTER", UIParent, "CENTER", 0, -200, "own place: the usual spot to begin with")
	db.callPoint, db.callRelPoint, db.callX, db.callY = "TOP", "TOP", 120, -80; ns.callApply()
	anchorIs("TOP", UIParent, "TOP", 120, -80, "own place: where you put it")
	db.callX, db.callY = "far", 0/0; ns.callApply()
	anchorIs("TOP", UIParent, "TOP", 0, -200, "own place: damaged numbers fall back")
	db.callX, db.callY = 120, -80
	db.callSide = "right"; db.shieldOn = true; db.auxAnchor = "bar"; db.auxSide = "right"; ns.callApply()
	check(S.group.anchor[2] == UIParent and not S.sideMoved, "calls: own place ignores the side and the buff icons")
	db.shieldOn = false; db.auxSide = "auto"; db.callSide = "start"
	-- dragging it: unlocked, in its own place, out of a fight
	ns.callApply()
	local started, stopped = 0, 0
	local oSM, oSS = S.group.StartMoving, S.group.StopMovingOrSizing
	rawset(S.group, "StartMoving", function() started = started + 1 end)
	rawset(S.group, "StopMovingOrSizing", function() stopped = stopped + 1 end)
	b1.scripts.OnDragStart(b1)
	check(started == 0, "calls drag: locked: no drag")
	db.locked = false; ns.callApply()
	check(b1.attrs.spell1 == nil and b1.attrs.type1 == nil and b1.mouse == true, "calls drag: unlocked in its own place: a press does not cast, the buttons can be grabbed")
	b1.scripts.OnDragStart(b1); b1.scripts.OnDragStop(b1)
	check(started == 1 and stopped == 1 and db.callPoint == "CENTER" and db.callX == 10 and db.callY == 20, "calls drag: moved and saved where it was dropped")
	b1.scripts.OnDragStop(b1)
	check(stopped == 1, "calls drag: a stop with no start saves nothing")
	inCombat = true
	b1.scripts.OnDragStart(b1)
	check(started == 1, "calls drag: not in a fight")
	inCombat = false
	-- a fight starting mid-drag: finished when it is over
	b1.scripts.OnDragStart(b1)
	inCombat = true
	b1.scripts.OnDragStop(b1)
	check(started == 2 and stopped == 1, "calls drag: a drag cut off by a fight is not finished in it")
	inCombat = false; db.callX = 0
	cfire("PLAYER_REGEN_ENABLED")
	check(stopped == 2 and db.callX == 10, "calls drag: ...it is finished and saved when the fight ends")
	db.callAnchor = "weird"; ns.callApply()
	check(S.group.anchor[2] == bar2 and b1.attrs.spell1 == "Call of the Elements", "calls drag: a damaged 'attach to' counts as the bar: armed again (still unlocked)")
	db.callAnchor = "bar"; ns.callApply()
	b1.scripts.OnDragStart(b1)
	check(started == 2, "calls drag: attached: the buttons do not drag (the bar does)")
	rawset(S.group, "StartMoving", oSM); rawset(S.group, "StopMovingOrSizing", oSS)
	db.locked = true; ns.callApply()
	-- back to the usual spot
	db.callAnchor = "free"; db.callPoint, db.callX, db.callY, db.callSide, db.callOffX = "TOP", 99, 98, "right", 5; ns.callApply()
	ns.callResetPlace()
	check(db.callPoint == "CENTER" and db.callX == 0 and db.callY == -200 and db.callSide == "start" and db.callOffX == 0 and db.callAnchor == "free", "calls: reset puts the place, the side and the nudge back (not the choice of own place)")
	db.callAnchor = "bar"; ns.callApply()

	-- each button on its own: the same settings again, one set per button
	do
		local function reset2()
			db.callSide, db.callAlign, db.callAnchor, db.callOffX, db.callOffY = "start", "start", "bar", 0, 0
			for _, k in ipairs({ "posCall", "posTotemic", "posRecall" }) do
				for _, f in ipairs({ "Own", "Anchor", "Side", "Align", "OffX", "OffY", "Point", "RelPoint", "X", "Y" }) do db[k .. f] = ns.defaults[k .. f] end
			end
			db.shieldOn = false; db.weaponOn = false; db.callOn = true; db.callTotemic = true; db.callRecall = true
			ns.callApply()
		end
		reset2()
		check(ns.defaults.posTotemicOwn == false and ns.defaults.posCallY == -200 and ns.defaults.posTotemicY == -250 and ns.defaults.posRecallY == -300, "calls own: nobody is on their own until you say so, and own places differ so they don't pile up")
		check(S.group.w == 3 * 36 + 2 * 4, "calls own: all together to begin with")
		-- Totemic Call on its own: the group closes up around the other two
		db.posTotemicOwn = true; ns.callApply()
		check(S.group.w == 2 * 36 + 4 and b1.anchor[4] == 0 and b3.anchor[4] == 40 and b3.anchor[2] == S.group, "calls own: the one placed on its own leaves the group, the others close up")
		check(b2.anchor[1] == "TOPRIGHT" and b2.anchor[2] == bar2 and b2.anchor[3] == "TOPLEFT" and b2.anchor[4] == -6, "calls own: it sits at the bar by its own settings (left, start)")
		db.posTotemicSide = "right"; db.posTotemicAlign = "end"; ns.callApply()
		check(b2.anchor[1] == "BOTTOMLEFT" and b2.anchor[3] == "BOTTOMLEFT" and b2.anchor[4] == full + 6, "calls own: its side and alignment are its own")
		check(S.group.anchor[1] == "TOPRIGHT" and S.group.anchor[3] == "TOPLEFT", "calls own: and the group's are not touched")
		db.posTotemicOffX, db.posTotemicOffY = 7, -3; ns.callApply()
		check(b2.anchor[4] == full + 13 and b2.anchor[5] == -3, "calls own: its own nudge")
		db.posTotemicAnchor = "free"; db.posTotemicPoint, db.posTotemicRelPoint, db.posTotemicX, db.posTotemicY = "TOP", "TOP", 50, -60; ns.callApply()
		check(b2.anchor[1] == "TOP" and b2.anchor[2] == UIParent and b2.anchor[4] == 50 and b2.anchor[5] == -60, "calls own: or a place of its own on the screen")
		db.posTotemicX = "far"; ns.callApply()
		check(b2.anchor[4] == 0, "calls own: a damaged number falls back")
		db.posTotemicX = 50
		-- the buff icons on its side: it takes the opposite one, and says so
		db.posTotemicAnchor = "bar"; db.posTotemicSide = "left"; db.shieldOn = true; db.auxAnchor = "bar"; db.auxSide = "left"; ns.callApply()
		check(S.ownSide.totemic == "right" and S.ownMoved.totemic == true and b2.anchor[3] == "BOTTOMLEFT", "calls own: the buff icons on its side: it takes the opposite one")
		db.posTotemicAnchor = "free"; ns.callApply()
		check(S.ownMoved.totemic == false, "calls own: in its own place nothing is in the way")
		db.shieldOn = false; db.auxSide = "auto"
		-- showing follows the same rule as the others
		db.callShow = "bar"; ns.callApply()
		check(S.group.shown == false and b2.mouse == false, "calls own: 'only while a totem is out': the one on its own goes too")
		db.callShow = "always"; ns.callApply()
		check(b2.shown == true and b2.mouse == true and S.group.shown == true, "calls own: ...and comes back")
		-- when only buttons on their own are on, the group still shows them
		db.callOn = false; db.callRecall = false; ns.callApply()
		check(b2.shown and S.group.shown, "calls own: only buttons on their own: they still show")
		db.callOn = true; db.callRecall = true; ns.callApply()
		-- dragging a button on its own
		local st, sp = 0, 0
		local oS, oP = b2.StartMoving, b2.StopMovingOrSizing
		rawset(b2, "StartMoving", function() st = st + 1 end)
		rawset(b2, "StopMovingOrSizing", function() sp = sp + 1 end)
		rawset(b2, "GetCenter", function() return 1000, 300 end)
		rawset(UIParent, "GetCenter", function() return 960, 540 end)
		b2.scripts.OnDragStart(b2)
		check(st == 0, "calls own drag: locked: no drag")
		db.locked = false; ns.callApply()
		check(b2.attrs.spell1 == nil and b1.attrs.spell1 == "Call of the Elements" and b3.attrs.spell1 == "Totemic Recall", "calls own drag: unlocked: only the one in its own place is disarmed")
		b1.scripts.OnDragStart(b1)
		check(st == 0 and (not S.group.moved), "calls own drag: a grouped button does not drag (the group is attached)")
		b2.scripts.OnDragStart(b2); b2.scripts.OnDragStop(b2)
		check(st == 1 and sp == 1 and db.posTotemicPoint == "CENTER" and db.posTotemicRelPoint == "CENTER" and db.posTotemicX == 40 and db.posTotemicY == -240, "calls own drag: saved as its distance from the screen's middle")
		check(db.callX == 0 and db.callPoint == "CENTER", "calls own drag: the group's place is left alone")
		inCombat = true
		b2.scripts.OnDragStart(b2)
		check(st == 1, "calls own drag: not in a fight")
		inCombat = false
		rawset(b2, "StartMoving", oS); rawset(b2, "StopMovingOrSizing", oP); rawset(b2, "GetCenter", nil); rawset(UIParent, "GetCenter", nil)
		db.locked = true; ns.callApply()
		-- the reset button of one button only
		db.posTotemicSide = "right"; db.callSide = "right"
		ns.callResetPlace("totemic")
		check(db.posTotemicSide == "start" and db.posTotemicY == -250 and db.posTotemicOwn == true and db.callSide == "right", "calls own: reset puts that button's place back and nothing else")
		db.callSide = "start"
		-- fight: its place and its box are held like the rest
		local w2 = 0
		for _, b in ipairs({ b1, b2, b3 }) do local o = b.SetPoint; rawset(b, "SetPoint", function(...) w2 = w2 + 1; return o(...) end) end
		inCombat = true; AURAS_HIDDEN = true; cfire("PLAYER_REGEN_DISABLED")
		db.posTotemicOwn = false; db.posRecallOwn = true; db.posTotemicSide = "top"
		local okp = pcall(function() ns.updatePreview(); ns.callApply() end)
		check(okp and w2 == 0 and b2.anchor[2] == UIParent, "calls own fight: moving buttons between places waits for the fight to end")
		inCombat = false; AURAS_HIDDEN = false; cfire("PLAYER_REGEN_ENABLED"); runTimers()
		check(w2 > 0 and S.group.w == 2 * 36 + 4 and b3.anchor[2] ~= S.group, "calls own fight: ...and is done after it")
		for _, b in ipairs({ b1, b2, b3 }) do rawset(b, "SetPoint", nil) end
		reset2()
	end

	-- a fight: none of the secure buttons or their group is touched (the game would refuse and show a popup)
	local writes = 0
	for _, b in ipairs({ b1, b2, b3 }) do
		local orig = b.SetAttribute
		rawset(b, "SetAttribute", function(self, k, v) writes = writes + 1; return orig(self, k, v) end)
	end
	local sizeBefore, anchorBefore, spellBefore = S.group.w, S.group.anchor, b1.attrs.spell1
	inCombat = true; AURAS_HIDDEN = true; cfire("PLAYER_REGEN_DISABLED")
	db.callOn = false; db.callTotemic = false; db.callSide = "end"; db.size = 50; db.callChoice = CA
	local okc, errc = pcall(function() ns.updatePreview(); cfire("SPELLS_CHANGED"); runTimers(); ns.callApply() end)
	check(okc, "calls fight: settings changed in a fight raise no error (" .. tostring(errc) .. ")")
	check(writes == 0 and S.group.w == sizeBefore and S.group.anchor == anchorBefore and b1.attrs.spell1 == spellBefore and b1.shown, "calls fight: buttons, spell, size and place are left exactly as they were")
	check(S.pending == true, "calls fight: the change is waiting")
	-- the pick list: nothing can change in a fight
	S.arrow.scripts.OnClick(S.arrow)
	check(not fly.shown, "calls fight: the list does not open")
	fly.items[1].callId = CS
	fly.items[1].scripts.OnClick(fly.items[1])
	check(db.callChoice == CA, "calls fight: ...a pick is not acted on")
	inCombat = false; AURAS_HIDDEN = false; cfire("PLAYER_REGEN_ENABLED"); runTimers()
	check(writes > 0, "calls fight: after it the waiting changes are made")
	check(not b1.shown and not b2.shown and b3.shown and b3.w == 50, "calls fight: ... buttons off, the size 50")
	check(S.pending == false, "calls fight: nothing left waiting")
	for _, b in ipairs({ b1, b2, b3 }) do rawset(b, "SetAttribute", nil) end
	reset()
	rawset(S.group, "protected", true)

	-- a pick list that is open when a fight starts closes
	db.callOn = true; ns.callApply()
	S.arrow.scripts.OnClick(S.arrow)
	check(fly.shown, "calls: list open")
	inCombat = true; cfire("PLAYER_REGEN_DISABLED")
	check(not fly.shown, "calls fight: a fight starting closes the list")
	inCombat = false; cfire("PLAYER_REGEN_ENABLED"); runTimers()

	-- cooldowns: in a fight too, passed straight through
	COOLDOWNS = {}
	C_Spell.GetSpellCooldown = function(id) return COOLDOWNS[id] end
	COOLDOWNS[CE] = { startTime = t - 5, duration = 30 }
	cfire("SPELL_UPDATE_COOLDOWN"); runTimers()
	check(b1.cd.cd and b1.cd.cd[1] == t - 5 and b1.cd.cd[2] == 30, "calls: the cooldown sweeps on the button")
	inCombat = true
	COOLDOWNS[CE] = { startTime = secret(), duration = secret() }
	local okcd, ecd = pcall(function() cfire("SPELL_UPDATE_COOLDOWN"); runTimers() end)
	check(okcd, "calls fight: secret cooldown numbers go straight through without an error (" .. tostring(ecd) .. ")")
	COOLDOWNS[CE] = { startTime = t - 1, duration = 20 }
	cfire("SPELL_UPDATE_COOLDOWN"); runTimers()
	check(b1.cd.cd[2] == 20, "calls fight: the sweep follows in a fight")
	inCombat = false
	local timersBefore = #timers
	for _ = 1, 40 do cfire("SPELL_UPDATE_COOLDOWN") end
	check(#timers - timersBefore == 1, "calls: a burst of cooldown events is one pass")
	runTimers()
	COOLDOWNS[CE] = nil

	-- the settings page
	local page = savedCat.pages[6]
	check(page ~= nil and ns.categories and ns.categories.calls ~= nil, "calls settings: a Call spells page is registered (the sixth)")
	local function boxFor(key) for _, f in ipairs(frames) do if f.settingKey == key and f.parentFrame == page then return f end end end
	for _, key in ipairs({ "callOn", "callTotemic", "callRecall" }) do check(boxFor(key) ~= nil, "calls settings: a box for " .. key) end
	reset(); page.OnRefresh()
	local onBox = boxFor("callOn")
	check(onBox.checked == false, "calls settings: shows off")
	onBox:SetChecked(true); onBox.scripts.OnClick(onBox)
	check(db.callOn == true and b1.shown, "calls settings: ticking it puts the button on screen at once")
	-- the radio groups, in the order the page makes them: show (2), attach (2), side (5), align (3)
	local rb = {}
	for _, f in ipairs(frames) do if type(f.value) == "string" and f.parentFrame == page and f.scripts.OnClick then rb[#rb + 1] = f end end
	check(#rb == 16, "calls settings: sixteen radio choices (" .. #rb .. ")")
	local function pick(i) rb[i].scripts.OnClick(rb[i]) end
	pick(2)
	check(db.callShow == "bar", "calls settings: 'only while a totem is out'")
	pick(1)
	check(db.callShow == "always", "calls settings: 'all the time'")
	pick(4)
	check(db.callAnchor == "free", "calls settings: 'own place'")
	pick(3)
	check(db.callAnchor == "bar", "calls settings: 'totem bar'")
	pick(6); check(db.callSide == "bottom", "calls settings: below")
	pick(7); check(db.callSide == "top", "calls settings: above")
	pick(8); check(db.callSide == "left", "calls settings: left")
	pick(9); check(db.callSide == "right" and S.group.anchor[4] == full + 6, "calls settings: right moves the buttons past the places")
	pick(5); check(db.callSide == "start", "calls settings: auto")
	pick(11); check(db.callAlign == "center", "calls settings: middle")
	pick(12); check(db.callAlign == "end", "calls settings: end")
	pick(10); check(db.callAlign == "start", "calls settings: start")
	-- the radios show what is saved (the old values too)
	db.callSide = "end"; db.vertical = false; page.OnRefresh()
	check(rb[9].checked == true and rb[5].checked == false, "calls settings: the old 'end' shows as Right")
	db.vertical = true; page.OnRefresh()
	check(rb[6].checked == true, "calls settings: ...and as Below on a vertical bar")
	db.vertical = false; db.callSide = "start"; db.callShow = "bar"; db.callAnchor = "free"; page.OnRefresh()
	check(rb[5].checked == true and rb[2].checked == true and rb[4].checked == true, "calls settings: they show what is saved")
	-- own place: the side and the nudge are greyed, the screen position is not
	check(rb[6].enabled == false and rb[10].enabled == false, "calls settings: own place: side and along-side choices are greyed out")
	local sl = {}
	for _, f in ipairs(frames) do if f.kind == "Slider" and f.parentFrame == page then sl[#sl + 1] = f end end
	check(#sl == 5, "calls settings: five sliders: size, two nudges, two screen positions (" .. #sl .. ")")
	check(sl[2].shown == false and sl[3].shown == false and sl[4].shown ~= false and sl[5].shown ~= false, "calls settings: own place: the nudges give way to the screen position")
	local unlockBox = boxFor("locked")
	check(unlockBox and unlockBox.enabled ~= false, "calls settings: own place: the unlock box is on")
	db.callAnchor = "bar"; rb[3].scripts.OnClick(rb[3])
	check(rb[6].enabled == true and sl[2].shown ~= false and sl[4].shown == false and unlockBox.enabled == false, "calls settings: attached: the reverse")
	sl[1]:SetValue(70)
	check(db.callScale == 70 and b1.w == 25, "calls settings: the size slider resizes the buttons (" .. tostring(b1.w) .. ")")
	sl[2]:SetValue(12); sl[3]:SetValue(-8)
	check(db.callOffX == 12 and db.callOffY == -8, "calls settings: the nudge sliders")
	sl[4]:SetValue(300); sl[5]:SetValue(-100)
	check(db.callX == 300 and db.callY == -100, "calls settings: the own-place sliders")
	unlockBox:SetChecked(true)
	rb[4].scripts.OnClick(rb[4]); unlockBox.scripts.OnClick(unlockBox)
	check(db.locked == false, "calls settings: the unlock box unlocks")
	unlockBox:SetChecked(false); unlockBox.scripts.OnClick(unlockBox)
	check(db.locked == true, "calls settings: and locks")
	local resetBtn
	for _, f in ipairs(frames) do if f.kind == "Button" and f.text == "Reset button position" and f.parentFrame == page then resetBtn = f end end
	check(resetBtn ~= nil, "calls settings: a reset button")
	db.callX = 777; resetBtn.scripts.OnClick(resetBtn)
	check(db.callX == 0 and db.callY == -200, "calls settings: reset puts the place back")
	-- the picker on the page: which button the position controls are for
	do
		local function isOn(i) return rb[i].checked end
		db.callAnchor = "bar"; db.callSide = "start"; ns.callTarget = "all"; page.OnRefresh()
		check(isOn(13) and not isOn(14), "calls settings: the picker starts on 'All together'")
		local ownBox2 = boxFor("posCallOwn")
		check(ownBox2 ~= nil and ownBox2.shown == false, "calls settings: all together: no 'on its own' box")
		pick(15)
		check(ns.callTarget == "totemic" and isOn(15) and not isOn(13), "calls settings: picking a button")
		check(ownBox2.shown ~= false and ownBox2.checked == false and rb[6].enabled == false and rb[9].enabled == false and sl[2].enabled == false, "calls settings: a button with the others: its box is off and its place controls are greyed")
		db.posTotemicOwn = false
		ownBox2:SetChecked(true); ownBox2.scripts.OnClick(ownBox2)
		check(db.posTotemicOwn == true and rb[6].enabled == true and rb[9].enabled == true, "calls settings: ticking it gives the button a place of its own")
		pick(9)
		check(db.posTotemicSide == "right" and db.callSide ~= "right", "calls settings: the side controls write that button's settings, not the group's")
		check(rb[9].checked == true, "calls settings: and show them")
		sl[2]:SetValue(15)
		check(db.posTotemicOffX == 15 and db.callOffX ~= 15, "calls settings: the nudge slider too")
		pick(4)
		check(db.posTotemicAnchor == "free" and db.callAnchor == "bar", "calls settings: and 'own place'")
		sl[4]:SetValue(100); sl[5]:SetValue(-50)
		check(db.posTotemicX == 100 and db.posTotemicY == -50 and db.callX ~= 100, "calls settings: and the screen position")
		check(sl[4].shown ~= false and sl[2].shown == false, "calls settings: own place: the screen sliders show")
		pick(14)
		check(ns.callTarget == "call" and ownBox2.checked == false and sl[4].shown == false, "calls settings: another button: its own settings are shown (attached, nothing on its own)")
		pick(16); pick(13)
		check(ns.callTarget == "all" and rb[3].checked == true, "calls settings: back to all together: the group's settings")
		-- reset on the page for one button
		pick(15)
		resetBtn.scripts.OnClick(resetBtn)
		check(db.posTotemicX == 0 and db.posTotemicY == -250 and db.posTotemicOwn == true, "calls settings: 'reset' with a button picked resets that button")
		pick(13)
		-- Defaults restores the per-button settings too
		db.posRecallOwn = true; db.posRecallSide = "top"; db.posTotemicOwn = true
		page.OnDefault()
		check(db.posRecallOwn == false and db.posRecallSide == "start" and db.posTotemicOwn == false and db.posTotemicAnchor == "bar", "calls settings: Defaults restores every button's own settings")
		ns.callTarget = "all"
	end
	db.callTotemic = true; db.callRecall = true; db.callChoice = CA; db.callSide = "end"; db.callShow = "bar"; db.callScale = 120
	db.callAnchor = "free"; db.callAlign = "end"; db.callOffX = 9
	page.OnDefault()
	check(db.callOn == false and db.callTotemic == false and db.callRecall == false and db.callSide == "start" and db.callChoice == 0
		and db.callShow == "always" and db.callScale == 100 and db.callAnchor == "bar" and db.callAlign == "start" and db.callOffX == 0,
		"calls settings: Defaults restores this page's settings")
	check(not b1.shown and not b2.shown, "calls settings: ...and the buttons go away")
	-- status
	local info = ns.callInfo()
	local blob = table.concat(info, "\n")
	check(blob:find("Call of the Elements: you have it") and blob:find("Call of the Spirits: you don't have it") and blob:find("Call button casts: Call of the Elements"), "calls status: what you have and what the button casts")
	check(blob:find("placed: beside the totem bar %(left%), shown all the time, 100%% size"), "calls status: where they are, when they show, how big (" .. blob:match("placed:[^\n]*") .. ")")
	local out = {}
	local pr = print; print = function(...) out[#out + 1] = table.concat({ ... }, " ") end
	SlashCmdList.SHAMANKIT("status")
	print = pr
	local joined = table.concat(out, "\n")
	check(joined:find("calls: Call of the Elements: you have it"), "calls status: /shamankit status lists them")
	-- the events are real names on this client
	local want = { PLAYER_ENTERING_WORLD = true, SPELLS_CHANGED = true, PLAYER_LEVEL_UP = true, SPELL_UPDATE_COOLDOWN = true, PLAYER_REGEN_ENABLED = true, PLAYER_REGEN_DISABLED = true }
	local okEv = true
	for _, e in ipairs(ns.CALL_EVENTS) do if not want[e] then okEv = false end end
	check(okEv and #ns.CALL_EVENTS == 6, "calls: only events this client has")
	noErrors("calls: nothing raised an error in the log")
	reset()
	IsPlayerSpell = nil                                       -- the cures tests are about a client that does not say
end

-- ---- Cures: the cure spells light up while something they can remove is on you (Cures.lua)
do
	local db = ShamanKitDB
	local S = ns.cureState
	local P = "ShamanKitCure_"
	-- this pretend client
	KNOWN_SPELLS[526] = "Cure Poison"; KNOWN_SPELLS[2870] = "Cure Disease"; KNOWN_SPELLS[1299026] = "Shatter Curse"
	CURE_KNOWN = { [526] = true, [2870] = true, [1299026] = true }
	C_SpellBook = { IsSpellKnown = function(id) return CURE_KNOWN[id] == true end }
	local raceFile = "Orc"
	function UnitRace() return raceFile, raceFile, 2 end
	DebuffTypeColor = { Poison = { r = 0, g = 0.6, b = 0 }, Disease = { r = 0.6, g = 0.4, b = 0 }, Curse = { r = 0.6, g = 0, b = 1 } }
	ACTIONS, MACROS, COOLDOWNS = {}, {}, {}
	function GetActionInfo(slot) local a = ACTIONS[slot]; if a then return a[1], a[2] end end
	function GetMacroSpell(i) return MACROS[i] end
	C_Spell.GetSpellCooldown = function(id) return COOLDOWNS[id] end
	local buttons = {}
	for _, prefix in ipairs({ "ActionButton", "MultiBarBottomLeftButton" }) do
		for i = 1, 12 do
			local b = CreateFrame("CheckButton", prefix .. i)
			b.action = #buttons + 1
			rawset(b, "GetWidth", function() return 40 end)
			buttons[#buttons + 1] = b
		end
	end
	local function btn(n) return buttons[n] end
	local function cont() return S.container end   -- the module's current container (an older one may be left in `frames`)
	local function slotBtn(name) local c = cont(); return c and c.slots[name] and c.slots[name].button end
	local function types(name) local c = cont(); local f = (c.filters and c.filters[name]) or c.slots[name].opts.candidateFilters; return f.includeDispelTypes end
	local function empty(tb) return next(tb) == nil end
	local function parked(b) return b.anchor ~= nil and b.anchor[2] == UIParent and b.anchor[4] == -9000 end
	local function lines(pat) local n = 0; for _, l in ipairs(db.log or {}) do if l:find(pat) then n = n + 1 end end return n end
	local function settle() runTimers() end
	-- the Cures module listens on a frame of its own: find it by the events it registered
	local cf
	for _, f in ipairs(frames) do if f.registered and f.registered.ACTIONBAR_SLOT_CHANGED and f.registered.UNIT_AURA then cf = f end end
	assert(cf, "the Cures frame registered its events")
	local function cfire(e, ...) cf.scripts.OnEvent(cf, e, ...) end
	local function both(e, ...) fire(e, ...); cfire(e, ...) end
	local function reset()
		inCombat = false; AURAS_HIDDEN = false; secretPos = false; S.scheduled = false
		CONTAINER_FAILS = false; NO_SLOTS = false; DEBUFFS = {}; ns.curesPageOpen = false
		S.testKey = nil
		db.cureOn, db.cureBars, db.cureRow, db.cureAlways, db.locked = true, true, true, false, true
		db.cureSize, db.cureSpacing, db.cureWash, db.cureWashAlpha, db.curePulse, db.cureCount = 36, 4, true, 30, true, true
	end

	reset(); db.log = {}
	for i = 1, #buttons do ACTIONS[i] = { "spell", 8075 } end            -- every button holds some other spell
	check(db.cureOn == true and db.cureBars == true and db.cureRow == true and db.cureAlways == false and db.cureSize == 36, "cures: defaults are on, row hidden until something is on you")
	check(ns.defaults.cureCount == true and ns.defaults.curePulse == true and ns.defaults.cureWash == true, "cures: the look defaults")
	-- the module started at load with a client that refused the container: start over with one that has it
	S.container, S.failed, S.knownDirty = nil, false, true
	ns.cureApply()
	local c = cont()
	check(c ~= nil, "cures: an aura container is made (out of combat)")
	check(c.unit == "player" and c.enabled == true and c.shown == true, "cures: it watches the player and is on")
	check(LOADED_ADDONS.Blizzard_AuraContainer, "cures: the game's aura container addon is loaded first")
	check(S.known.poison and S.known.disease and S.known.curse, "cures: the three cures are known")

	-- the row: one slot per cure, limited to its dispel type by NAME, over its cell
	local poi, dis, cur = slotBtn(P .. "poison_row1"), slotBtn(P .. "disease_row1"), slotBtn(P .. "curse_row1")
	check(poi and dis and cur, "cures: a game-drawn slot in the row for each cure you have")
	check(c.slots[P .. "poison_row1"].filter == "HARMFUL", "cures: debuffs only")
	local tp, td, tc = types(P .. "poison_row1"), types(P .. "disease_row1"), types(P .. "curse_row1")
	check(tp.Poison and not tp.Disease and not tp.Curse and td.Disease and not td.Poison, "cures: the poison slot takes poison only, the disease slot disease only")
	check(tc.Curse and tc.Bane and not tc.Poison, "cures: the curse slot takes a Curse and a Bane")
	check(poi.anchor and poi.anchor[1] == "CENTER" and poi.anchor[2] == S.cells.poison, "cures: the slot sits over its cell")
	check(poi.sizeAtInit and poi.sizeAtInit > 0, "cures: the button is given a size when it is made (without one it is invisible)")
	check(poi.w == 36 and poi.h == 36, "cures: and sized to the row icon")
	check(poi.countFS ~= nil and poi.iconTex == nil, "cures: the game writes the stack count; the picture is the cure's own, not the debuff's")
	local parts = S.rowSlots.poison.parts
	check(parts.glow.color[1] == 0 and parts.glow.color[2] == 0.6 and parts.glow.color[3] == 0, "cures: the glow is the game's poison green")
	check(parts.icon.tex == 100000 + 526, "cures: the row icon is the cure spell's picture")
	check(parts.pulse and parts.pulse.playing == true, "cures: the border pulses")
	check(parts.wash.shown and parts.wash.alpha == 0.3, "cures: a 30% wash in the colour")
	check(S.cells.poison.shown == false and S.cells.poison.mouse == false, "cures: the plain cells stay hidden (nothing is on you): only the game's slot can show")
	check(not (S.plainRow.poison and S.plainRow.poison.shown), "cures: no plain stand-in frame is lit with the container working")
	check(DEBUFF_READS == nil or DEBUFF_READS >= 0, "cures: (the backup reading may run out of combat)")

	-- keep the row on screen
	db.cureAlways = true; ns.cureApply()
	check(S.cells.poison.shown and S.cells.disease.shown and S.cells.curse.shown, "cures: always show: the three dim cells are there")
	check(S.cells.disease.anchor[4] == 0 and S.cells.poison.anchor[4] == 40 and S.cells.curse.anchor[4] == 80, "cures: laid out disease, poison, curse, spaced by size + gap")
	db.cureAlways = false; ns.cureApply()
	check(not S.cells.poison.shown, "cures: always show off: hidden again")
	db.cureRow = false; ns.cureApply()
	check(parked(poi) and empty(types(P .. "poison_row1")), "cures: row off: its slots are emptied and parked off screen")
	db.cureRow = true; ns.cureApply()
	check(poi.anchor[2] == S.cells.poison and types(P .. "poison_row1").Poison, "cures: row on again: back in place, filtered again")

	-- a cure you do not have
	CURE_KNOWN[1299026] = nil; S.knownDirty = true; ns.cureApply()
	check(S.known.curse == false and parked(cur) and empty(types(P .. "curse_row1")), "cures: no Shatter Curse: no curse slot lights")
	-- a client that cannot say: a racial belongs to its race
	C_SpellBook.IsSpellKnown = function() return nil end
	S.knownDirty = true; ns.cureApply()
	check(S.known.curse == true, "cures: the client can't say, and an Orc has the racial")
	raceFile = "Human"; S.knownDirty = true; ns.cureApply()
	check(S.known.curse == false, "cures: ...a Human does not")
	raceFile = "Orc"
	C_SpellBook.IsSpellKnown = function(id) return CURE_KNOWN[id] == true end
	CURE_KNOWN[1299026] = true; S.knownDirty = true; ns.cureApply()
	check(S.known.curse == true and types(P .. "curse_row1").Curse, "cures: back")

	-- the action bars
	ACTIONS[3] = { "spell", 526 }                  -- Cure Poison on button 3
	ACTIONS[5] = { "macro", 7 }; MACROS[7] = "Cure Disease"   -- a macro that casts Cure Disease on button 5
	cfire("ACTIONBAR_SLOT_CHANGED", 3); settle()
	local o1, o2 = slotBtn(P .. "poison_bar1"), slotBtn(P .. "disease_bar1")
	check(o1 and o1.anchor[2] == btn(3) and types(P .. "poison_bar1").Poison, "cures: the button holding Cure Poison gets a poison overlay")
	check(o2 and o2.anchor[2] == btn(5) and types(P .. "disease_bar1").Disease, "cures: a macro that casts Cure Disease gets a disease overlay")
	check(o1.w == 40 and o1.h == 40, "cures: sized to the button")
	check(S.rowSlots.poison.parts ~= S.assigned[btn(3)].parts and S.assigned[btn(3)].parts.icon == nil, "cures: an overlay has no picture of its own, only the wash and glow")
	check(slotBtn(P .. "poison_bar2") == nil and slotBtn(P .. "disease_bar2") == nil, "cures: no more overlays than there are buttons")
	local n = 0; for _ in pairs(S.assigned) do n = n + 1 end
	check(n == 2, "cures: other spells light nothing")
	check(lines("CURES action bars: ActionButton3>poison,ActionButton5>disease") == 1, "cures: the log names the buttons it matched")

	-- the same cure on two buttons
	ACTIONS[9] = { "spell", 526 }; cfire("ACTIONBAR_SLOT_CHANGED", 9); settle()
	local o3 = slotBtn(P .. "poison_bar2")
	check(o3 and o3.anchor[2] == btn(9) and types(P .. "poison_bar2").Poison and o1.anchor[2] == btn(3), "cures: a second button with the same cure gets its own overlay, the first stays")
	-- the spell is dragged away: its overlay is released, the other stays
	ACTIONS[3] = { "spell", 8075 }; cfire("ACTIONBAR_SLOT_CHANGED", 3); settle()
	check(parked(o1) and empty(types(P .. "poison_bar1")), "cures: the spell moved off the button: its overlay is emptied and parked")
	check(o3.anchor[2] == btn(9) and types(P .. "poison_bar2").Poison, "cures: the other button is still lit")
	-- dragged to a new button without any event: the drag hook and the slow check catch it
	ACTIONS[3] = { "spell", 526 }; PlaceAction(3); settle()
	check(o1.anchor[2] == btn(3) and types(P .. "poison_bar1").Poison, "cures: a drag (PlaceAction) re-reads the bars")
	ACTIONS[3] = { "spell", 8075 }
	check(TICKERS and #TICKERS >= 1, "cures: a slow backstop ticker is running")
	for _, tick in ipairs(TICKERS) do tick() end; settle()
	check(parked(o1), "cures: the backstop finds a change that sent no event")
	for _ = 1, 3 do for _, tick in ipairs(TICKERS) do tick() end end
	check(#timers == 0, "cures: ...and does nothing when nothing changed")
	ACTIONS[3] = { "spell", 526 }; cfire("ACTIONBAR_SLOT_CHANGED", 3); settle()

	-- more buttons than overlays per cure: capped, said in the log
	for i = 13, 24 do ACTIONS[i] = { "spell", 526 } end
	ns.cureApply()
	local pool = 0; for k in pairs(c.slots) do if k:find(P .. "poison_bar") then pool = pool + 1 end end
	check(pool == 8 and lines("no free overlay for poison") >= 1, "cures: at most 8 overlays per cure, the rest said in the log")
	for i = 13, 24 do ACTIONS[i] = { "spell", 8075 } end
	ACTIONS[9] = { "spell", 8075 }
	ns.cureApply()
	local on = 0; for _, rec in pairs(S.assigned) do on = on + 1 end
	check(on == 2, "cures: back to two lit buttons (button 3 poison, button 5 disease)")

	-- bars off
	db.cureBars = false; ns.cureApply()
	check(parked(o1) and parked(o2) and next(S.assigned) == nil, "cures: bars off: no overlay is left lit")
	db.cureBars = true; ns.cureApply()
	check(o1.anchor[2] == btn(3), "cures: bars on again")

	-- ------------------------------------------------ a fight: nothing the game restricts is touched
	local framesBefore, writes, reads = #frames, c.filterWrites, DEBUFF_READS or 0
	local anchorBefore = o1.anchor
	inCombat = true; AURAS_HIDDEN = true; both("PLAYER_REGEN_DISABLED")
	ACTIONS[3] = { "spell", 8075 }
	for _, e in ipairs({ "UNIT_AURA", "ACTIONBAR_SLOT_CHANGED", "SPELL_UPDATE_COOLDOWN", "ACTIONBAR_PAGE_CHANGED", "SPELLS_CHANGED" }) do cfire(e, "player") end
	PlaceAction(3)
	settle()
	for _, tick in ipairs(TICKERS) do tick() end; settle()
	check(#frames == framesBefore, "cures fight: no frame is made")
	check(c.filterWrites == writes and o1.anchor == anchorBefore and o1.anchor[2] == btn(3), "cures fight: no slot is re-filtered, moved or released")
	check((DEBUFF_READS or 0) == reads, "cures fight: the debuffs are not read (the game would refuse)")
	check(c.enabled == true and c.shown == true and types(P .. "poison_bar1").Poison, "cures fight: the game-drawn overlays stay armed: the game lights them when a poison lands")
	db.cureSize = 50; ns.updatePreview(); settle()
	check(S.rowSlots.poison.w == 36 and poi.w == 36, "cures fight: a size change waits")
	ns.cureTest("all")
	check(S.testKey == nil, "cures fight: a test is refused")
	inCombat = false; AURAS_HIDDEN = false; both("PLAYER_REGEN_ENABLED"); settle()
	check(S.rowSlots.poison.w == 50 and parked(o1) , "cures fight: afterwards the size change and the moved spell are applied")
	db.cureSize = 36; ACTIONS[3] = { "spell", 526 }; ns.cureApply()

	-- the game hides auras though no fight is on (an encounter): wait, then do it
	AURAS_HIDDEN = true; db.cureSpacing = 10; ns.cureApply()
	check(S.pending == true, "cures: auras hidden out of combat: the change waits")
	AURAS_HIDDEN = false; settle(); ns.cureApply()
	check(S.pending == false and S.cells.poison.anchor ~= nil, "cures: ...and is done once they are readable")
	db.cureSpacing = 4; ns.cureApply()

	-- ------------------------------------------------ the backup reading (out of combat only)
	db.log = {}
	DEBUFFS = { { dispelName = "Poison" }, { dispelName = "Magic" }, { dispelName = "Poison" } }
	cfire("UNIT_AURA", "player"); settle()
	check(S.reader.lit.poison == true and S.reader.count.poison == 2 and S.reader.lit.disease == false, "cures: reading: two poisons, no disease")
	check(lines("CURES debuff types on you: Magic=1 Poison=2") == 1, "cures: the log names the dispel types the game reported")
	cfire("UNIT_AURA", "player"); settle()
	check(lines("CURES debuff types on you") == 1, "cures: ...only when they change")
	DEBUFFS = { { dispelName = "Bane" } }; cfire("UNIT_AURA", "player"); settle()
	check(S.reader.lit.curse == true and S.reader.lit.poison == false, "cures: a Bane counts as a curse")
	DEBUFFS = { { dispelName = secret() } }; local litBefore = S.reader.lit.curse
	cfire("UNIT_AURA", "player"); settle()
	check(S.reader.lit.curse == litBefore, "cures: a hidden type is never read as 'nothing': the last reading stays")
	DEBUFFS = { secret() }; S.reader.lit.curse = true
	cfire("UNIT_AURA", "player"); settle()
	check(S.reader.lit.curse == true, "cures: a hidden aura entry is never read as 'nothing' either")
	DEBUFFS = {}; cfire("UNIT_AURA", "player"); settle()
	check(S.reader.lit.curse == false and lines("debuff types on you: none") == 1, "cures: nothing on you: nothing lit")
	local burst = DEBUFF_READS
	for _ = 1, 50 do cfire("UNIT_AURA", "player") end
	check(#timers == 1, "cures: a burst of aura events becomes one pass")
	settle()
	check(DEBUFF_READS - burst <= 2, "cures: ...and one reading (" .. (DEBUFF_READS - burst) .. " calls)")

	-- ------------------------------------------------ the settings preview and the test (plain frames)
	check(S.plainRow.poison == nil or not S.plainRow.poison.shown, "cures: nothing plain is lit at rest")
	ns.curesPageOpen = true; ns.cureApply()
	check(S.plainRow.poison.shown and S.plainRow.disease.shown and S.plainRow.curse.shown, "cures: settings page open and nothing on you: the row shows all three lit")
	check(S.plainBar[btn(3)].shown and S.plainBar[btn(5)].shown, "cures: ...and the buttons that hold a cure")
	check(S.plainBar[btn(3)].parts.glow.color[2] == 0.6, "cures: lit in the affliction's colour")
	DEBUFFS = { { dispelName = "Poison" } }; cfire("UNIT_AURA", "player"); settle()
	check(not S.plainRow.poison.shown and not S.plainBar[btn(3)].shown, "cures: a real poison arrives: the preview steps aside (the game's own overlay shows)")
	DEBUFFS = {}; cfire("UNIT_AURA", "player"); settle()
	check(S.plainRow.poison.shown, "cures: ...and is back when it goes")
	ns.curesPageOpen = false; ns.cureApply()
	check(not S.plainRow.poison.shown and not S.plainBar[btn(3)].shown, "cures: page closed: gone")
	ns.cureTest("poison")
	check(S.plainRow.poison.shown and not S.plainRow.disease.shown and S.plainBar[btn(3)].shown and not S.plainBar[btn(5)].shown, "cures: test poison: only poison is lit, on the row and on its button")
	ns.cureTest("all")
	check(S.plainRow.disease.shown and S.plainRow.curse.shown and S.plainBar[btn(5)].shown, "cures: test all")
	ns.cureTest("clear")
	check(S.testKey == nil and not S.plainRow.poison.shown and not S.plainRow.disease.shown and not S.plainBar[btn(3)].shown, "cures: test clear")
	ns.cureTest("curse")
	settle()
	check(S.testKey == nil and not S.plainRow.curse.shown, "cures: a test ends by itself after a few seconds")
	ns.cureTest("all"); inCombat = true; both("PLAYER_REGEN_DISABLED")
	check(S.testKey == nil and not S.plainRow.poison.shown and not S.plainBar[btn(3)].shown, "cures: a fight starting ends a test and puts its frames away")
	inCombat = false; both("PLAYER_REGEN_ENABLED"); settle()

	-- ------------------------------------------------ unlocked: drag the row
	db.locked = false; ns.optionsOpen = false; ns.cureApply()
	check(not S.cells.poison.shown and not S.cells.disease.shown and not S.cells.curse.shown and S.cells.poison.mouse == false, "cures: unlocked, settings closed: the row is NOT on screen")
	ns.optionsOpen = true; ns.cureApply()
	check(S.cells.poison.shown and S.cells.disease.shown and S.cells.curse.shown and S.cells.poison.mouse == true, "cures: unlocked, a ShamanKit settings page open: the cells are there to grab")
	ns.optionsOpen = false; ns.cureApply()
	check(not S.cells.poison.shown, "cures: settings closed again: the row goes away")
	db.locked = true; ns.optionsOpen = true; ns.cureApply()
	check(not S.cells.poison.shown and not S.cells.disease.shown, "cures: locked with a settings page open: the row is not on screen either (only moving it shows it)")
	db.locked = false
	ns.optionsOpen = true; ns.cureApply()
	local moved = 0
	local row = S.row
	rawset(row, "StartMoving", function() moved = moved + 1 end)
	S.cells.poison.scripts.OnDragStart(S.cells.poison)
	S.cells.poison.scripts.OnDragStop(S.cells.poison)
	check(moved == 1 and db.curePoint == "CENTER" and db.cureX == 10 and db.cureY == 20, "cures: dragging the row saves where it was dropped")
	db.locked = true; ns.optionsOpen = false; ns.cureApply(); moved = 0
	S.cells.poison.scripts.OnDragStart(S.cells.poison)
	check(moved == 0, "cures: locked: a drag moves nothing")
	inCombat = true; db.locked = false
	S.cells.poison.scripts.OnDragStart(S.cells.poison)
	check(moved == 0, "cures: not in a fight either")
	inCombat = false; db.locked = true
	ns.cureResetPosition()
	check(db.curePoint == "CENTER" and db.cureX == 0 and db.cureY == -160, "cures: reset puts the row back")

	-- ------------------------------------------------ the look follows the settings (out of combat)
	db.cureWashAlpha = 60; ns.cureApply()
	check(S.rowSlots.poison.parts.wash.alpha == 0.6 and S.assigned[btn(3)].parts.wash.alpha == 0.6, "cures: wash strength changes the row and the overlays")
	db.cureWash = false; ns.cureApply()
	check(S.rowSlots.poison.parts.wash.shown == false, "cures: wash off")
	db.curePulse = false; ns.cureApply()
	check(S.rowSlots.poison.parts.pulse.playing == false and S.assigned[btn(3)].parts.pulse.playing == false, "cures: pulse off")
	db.curePulse = true; db.cureWash = true; db.cureWashAlpha = 30; ns.cureApply()
	check(S.rowSlots.poison.parts.pulse.playing == true and S.rowSlots.poison.parts.wash.shown, "cures: pulse and wash back")
	db.cureCount = false; ns.cureApply()
	check(poi.cleared == 1 and S.rowSlots.poison.parts.count.text == "", "cures: count off: the game stops writing the number")
	db.cureCount = true; ns.cureApply()
	check(poi.countFS ~= nil, "cures: count on: the game writes it again")
	db.cureSize = 60; ns.cureApply()
	check(poi.w == 60 and S.cells.poison.w == 60 and S.assigned[btn(3)].w == 40, "cures: the row size changes, the overlays keep the button's size")
	db.cureSize = 36; ns.cureApply()

	-- ------------------------------------------------ the cooldown (out of combat)
	local now = GetTime()
	COOLDOWNS[526] = { startTime = now - 5, duration = 8 }; cfire("SPELL_UPDATE_COOLDOWN"); settle()
	check(S.rowSlots.poison.parts.icon.alpha == 0.55 and S.rowSlots.poison.parts.cd.cd[2] == 8, "cures: on cooldown: the row icon is dimmed and sweeps")
	COOLDOWNS[526] = { startTime = now, duration = 1.5, isOnGCD = true }; cfire("SPELL_UPDATE_COOLDOWN"); settle()
	check(S.rowSlots.poison.parts.icon.alpha == 1, "cures: the global cooldown does not count")
	COOLDOWNS[526] = { startTime = now, duration = 8 }; cfire("SPELL_UPDATE_COOLDOWN"); settle()
	local sw = #frames
	for _ = 1, 40 do cfire("SPELL_UPDATE_COOLDOWN") end
	check(#timers == 1, "cures: a burst of cooldown events is one pass")
	local pointsBefore = CALLS.SetTexture
	settle()
	check(CALLS.SetTexture == pointsBefore and #frames == sw, "cures: a cooldown event lays nothing out again (no texture or frame written)")
	inCombat = true; COOLDOWNS[526] = nil; cfire("SPELL_UPDATE_COOLDOWN"); settle()
	check(S.rowSlots.poison.parts.icon.alpha == 0.55, "cures fight: the row icon is not touched in a fight")
	inCombat = false; both("PLAYER_REGEN_ENABLED"); settle()
	check(S.rowSlots.poison.parts.icon.alpha == 1, "cures: after the fight it is right again")

	-- ------------------------------------------------ click a lit row icon to cure yourself
	do
		db.cureClick = true; db.locked = true; db.cureOn = true; db.cureRow = true; db.cureBars = true
		S.knownDirty = true; ns.cureApply()
		local function clickOf(key) return S.rowSlots[key] and S.rowSlots[key].click end
		local cp, cd, cc = clickOf("poison"), clickOf("disease"), clickOf("curse")
		check(cp and cd and cc, "cures click: every row icon has a secure button")
		check(cp.tmpl == "SecureActionButtonTemplate" and cp.parentFrame == S.rowSlots.poison.button, "cures click: it is a secure button, a child of the game's icon (so it is only there while the icon is)")
		check(cp.attrs.type1 == "spell" and cp.attrs.spell1 == "Cure Poison" and cp.attrs.unit1 == "player", "cures click: left-click casts Cure Poison on you")
		check(cd.attrs.spell1 == "Cure Disease" and cc.attrs.spell1 == "Shatter Curse", "cures click: each icon casts its own cure")
		check(cp.mouse == true and cp.shown == true, "cures click: the button takes the mouse, and the addon never hides it (the game's icon does)")
		check(S.assigned[btn(3)].click == nil, "cures click: the overlays on your action buttons stay plain (the real button there already casts)")
		db.log = {}; db.cureClick = false; ns.cureApply(); db.cureClick = true; ns.cureApply()
		check(lines("CURES click: poison cast Cure Poison on you") == 1, "cures click: the log says what each icon casts")
		-- the tooltip
		cp.scripts.OnEnter(cp)
		check(GameTooltip.text == "Cure Poison", "cures click: the tooltip names the cure")

		-- off
		db.cureClick = false; ns.cureApply()
		check(cp.attrs.type1 == nil and cp.attrs.spell1 == nil and cp.mouse == false, "cures click: switched off: nothing is cast and the mouse passes through")
		db.cureClick = true; ns.cureApply()
		check(cp.attrs.spell1 == "Cure Poison" and cp.mouse == true, "cures click: switched on again")
		-- unlocked: the row is for dragging
		db.locked = false; ns.optionsOpen = false; ns.cureApply()
		check(cp.attrs.spell1 == "Cure Poison" and cp.mouse == true, "cures click: unlocked with settings closed: the row is not being moved, so clicking works")
		ns.optionsOpen = true; ns.cureApply()
		check(cp.attrs.type1 == nil and cp.mouse == false, "cures click: unlocked with settings open: the row is being moved, clicking is off")
		ns.optionsOpen = false; db.locked = true; ns.cureApply()
		check(cp.attrs.spell1 == "Cure Poison", "cures click: locked again")
		-- a cure you do not have
		CURE_KNOWN[526] = nil; S.knownDirty = true; ns.cureApply()
		check(cp.attrs.type1 == nil and cp.mouse == false, "cures click: a cure you don't have casts nothing")
		CURE_KNOWN[526] = true; S.knownDirty = true; ns.cureApply()
		check(cp.attrs.spell1 == "Cure Poison", "cures click: and is back when you learn it")
		-- the row off, the module off
		db.cureRow = false; ns.cureApply()
		check(cp.attrs.type1 == nil and cp.mouse == false, "cures click: row off: no click")
		db.cureRow = true; ns.cureApply()
		check(cp.attrs.spell1 == "Cure Poison", "cures click: row on")
		db.cureOn = false; ns.cureApply()
		check(cp.attrs.type1 == nil and cp.mouse == false, "cures click: module off: no click")
		db.cureOn = true; ns.cureApply()
		-- a rename (the spell's name in another language, or after an update)
		C_Spell.GetSpellInfo = (function(orig) return function(id) local i = orig(id); if id == 526 and RENAMED then i = { name = RENAMED, iconID = i and i.iconID } end return i end end)(C_Spell.GetSpellInfo)
		RENAMED = "Gift Heilen"; S.knownDirty = true; ns.cureApply()
		check(cp.attrs.spell1 == "Gift Heilen", "cures click: the spell is cast by the name this client uses")
		RENAMED = nil; S.knownDirty = true; ns.cureApply()

		-- a fight: nothing on the secure button is touched (the game would refuse and show a popup)
		local setWrites = 0
		for _, c in ipairs({ cp, cd, cc }) do
			local orig = c.SetAttribute
			rawset(c, "SetAttribute", function(self, k, v) setWrites = setWrites + 1; return orig(self, k, v) end)
		end
		inCombat = true; AURAS_HIDDEN = true; both("PLAYER_REGEN_DISABLED")
		db.cureClick = false; db.locked = false; db.cureOn = false
		local okf, errf = pcall(function() ns.updatePreview(); both("SPELLS_CHANGED"); cfire("ACTIONBAR_SLOT_CHANGED", 3); cfire("UNIT_AURA", "player"); settle() end)
		check(okf, "cures click fight: settings changed in a fight raise no error (" .. tostring(errf) .. ")")
		check(setWrites == 0 and cp.attrs.spell1 == "Cure Poison" and cp.mouse == true, "cures click fight: the secure buttons are left exactly as they were")
		inCombat = false; AURAS_HIDDEN = false; both("PLAYER_REGEN_ENABLED"); settle()
		check(cp.attrs.type1 == nil and cp.mouse == false and setWrites > 0, "cures click fight: and the changes are made once it is over")
		for _, c in ipairs({ cp, cd, cc }) do rawset(c, "SetAttribute", nil) end
		db.cureClick = true; db.locked = true; db.cureOn = true; ns.cureApply()
		check(cp.attrs.spell1 == "Cure Poison", "cures click: back to normal")

		-- CureWatch still installed: the module is off, so is the click
		local realLoaded2 = C_AddOns.IsAddOnLoaded
		C_AddOns.IsAddOnLoaded = function(n) if n == "CureWatch" then return true end return realLoaded2(n) end
		local realPrint2 = print; print = function() end
		ns.cureInit(); print = realPrint2
		ns.cureApply()
		check(cp.attrs.type1 == nil and cp.mouse == false, "cures click: CureWatch installed: no click")
		C_AddOns.IsAddOnLoaded = realLoaded2
		ns.cureInit(); ns.cureApply()
		check(cp.attrs.spell1 == "Cure Poison", "cures click: CureWatch gone: back")

		-- the game refuses to make a secure child: the icon still works, the log says why, nothing raises
		local realCF = CreateFrame
		db.log = {}
		S.container, S.failed, S.rowSlots, S.pools, S.assigned = nil, false, {}, {}, {}
		function CreateFrame(kind, name, parent, tmpl)
			if tmpl == "SecureActionButtonTemplate" then error("secure frames can't be made here") end
			return realCF(kind, name, parent, tmpl)
		end
		local okc, errc = pcall(ns.cureApply)
		CreateFrame = realCF
		check(okc, "cures click: no secure child allowed: no error (" .. tostring(errc) .. ")")
		check(S.rowSlots.poison and S.rowSlots.poison.click == nil and S.rowSlots.poison.button ~= nil, "cures click: the lit icon itself is still made")
		check(lines("CURES click: no secure button for poison") == 1, "cures click: the log says it could not be made")
		S.container, S.rowSlots, S.pools, S.assigned = nil, {}, {}, {}
		S.knownDirty = true; ns.cureApply()
		check(S.rowSlots.poison.click ~= nil and S.rowSlots.poison.click.attrs.spell1 == "Cure Poison", "cures click: next time it is made fine")
		db.log = {}
	end

	-- ------------------------------------------------ no container on this client: plain frames lit by the reading
	for _, rec in pairs(S.rowSlots) do rec.on = false end
	S.container, S.failed, S.rowSlots, S.pools, S.assigned = nil, false, {}, {}, {}
	CONTAINER_FAILS = true; db.log = {}
	DEBUFFS = { { dispelName = "Disease" } }
	ns.cureApply(); cfire("UNIT_AURA", "player"); settle()
	check(S.failed == true and lines("CURES container could not be made") == 1, "cures fallback: the log says the container could not be made")
	check(S.plainRow.disease and S.plainRow.disease.shown and not (S.plainRow.poison and S.plainRow.poison.shown), "cures fallback: the disease is lit on the row by a plain frame")
	check(S.cells.disease.shown, "cures fallback: its cell is shown even with 'always show' off")
	check(S.plainBar[btn(5)] and S.plainBar[btn(5)].shown and not (S.plainBar[btn(3)] and S.plainBar[btn(3)].shown), "cures fallback: and on the button that holds Cure Disease")
	DEBUFFS = {}; cfire("UNIT_AURA", "player"); settle()
	check(not S.plainRow.disease.shown and not S.plainBar[btn(5)].shown, "cures fallback: gone when the debuff is")
	inCombat = true; AURAS_HIDDEN = true; DEBUFFS = { { dispelName = "Poison" } }; cfire("UNIT_AURA", "player"); settle()
	check(not (S.plainRow.poison and S.plainRow.poison.shown), "cures fallback: in a fight nothing is guessed (the reading is not used)")
	inCombat = false; AURAS_HIDDEN = false; DEBUFFS = {}
	CONTAINER_FAILS = false; S.failed = false; both("PLAYER_REGEN_ENABLED"); settle(); ns.cureApply()
	check(cont() ~= nil and S.container ~= nil and not S.failed, "cures: with a container available again it is used")

	-- ------------------------------------------------ the old addon still installed
	local realLoaded = C_AddOns.IsAddOnLoaded
	C_AddOns.IsAddOnLoaded = function(n) if n == "CureWatch" then return true end return realLoaded(n) end
	local printed = {}
	local realPrint = print; print = function(...) printed[#printed + 1] = table.concat({ ... }, " ") end
	ns.cureInit()
	print = realPrint
	check(S.conflict == true and #printed == 1 and printed[1]:find("CureWatch"), "cures: CureWatch still installed: one clear message")
	ns.cureApply()
	check(parked(S.rowSlots.poison.button or poi) or empty(types(P .. "poison_row1")), "cures: ...and nothing lights while it is (both would light every button)")
	check(cont().enabled == false and cont().shown == false, "cures: ...the container is switched off")
	check(ns.cureInfo()[1] ~= nil, "cures: status still answers")
	C_AddOns.IsAddOnLoaded = realLoaded
	ns.cureInit(); ns.cureApply()
	check(S.conflict == false and cont().enabled == true and types(P .. "poison_row1").Poison, "cures: CureWatch gone: lights again")

	-- ------------------------------------------------ the master switch
	db.cureOn = false; ns.cureApply()
	check(cont().enabled == false and parked(slotBtn(P .. "poison_row1")) and next(S.assigned) == nil, "cures: off: the container is off and nothing is lit")
	check(S.cells.poison.shown == false and not (S.plainRow.poison and S.plainRow.poison.shown), "cures: off: nothing plain either")
	ns.curesPageOpen = true; ns.cureApply()
	check(not (S.plainRow.poison and S.plainRow.poison.shown), "cures: off: not even the preview")
	ns.curesPageOpen = false
	db.cureOn = true; ns.cureApply()
	check(cont().enabled == true and types(P .. "poison_row1").Poison, "cures: on again")

	-- ------------------------------------------------ the settings page and the commands
	check(ns.categories and ns.categories.cures ~= nil, "cures settings: a Cures page is registered")
	local page = savedCat.pages[5]                   -- a page is its panel
	check(page ~= nil, "cures settings: it is the fifth page (home, totem bar, totems, buffs, cures)")
	local function boxFor(key) for _, f in ipairs(frames) do if f.settingKey == key and f.parentFrame == page then return f end end end
	for _, key in ipairs({ "cureOn", "cureBars", "cureRow", "cureAlways", "cureWash", "curePulse", "cureCount", "cureClick" }) do
		check(boxFor(key) ~= nil, "cures settings: a box for " .. key)
	end
	page.OnRefresh()
	local rowBox, alwaysBox = boxFor("cureRow"), boxFor("cureAlways")
	poi = slotBtn(P .. "poison_row1")
	check(rowBox.checked == true and alwaysBox.checked == false, "cures settings: the boxes show what is saved")
	rowBox:SetChecked(false); rowBox.scripts.OnClick(rowBox)
	check(db.cureRow == false and parked(poi), "cures settings: unticking the row switches it off at once")
	check(alwaysBox.enabled == false, "cures settings: ...and greys out what only matters for the row")
	check(boxFor("cureClick").enabled == false, "cures settings: ...including the click box")
	rowBox:SetChecked(true); rowBox.scripts.OnClick(rowBox)
	check(db.cureRow == true and alwaysBox.enabled == true and poi.anchor[2] == S.cells.poison, "cures settings: ticking it brings it back")
	db.cureWashAlpha = 77; db.cureSize = 70; db.cureOn = false; db.cureClick = false
	page.OnDefault()
	check(db.cureOn == true and db.cureWashAlpha == 30 and db.cureSize == 36 and db.cureClick == true, "cures settings: Defaults restores this page's settings (the click too)")
	page.scripts.OnShow()
	check(ns.curesPageOpen == true, "cures settings: opening the page turns the preview on")
	page.scripts.OnHide()
	check(ns.curesPageOpen == false, "cures settings: closing it turns it off")
	local unlockBox = boxFor("locked")
	unlockBox:SetChecked(true); unlockBox.scripts.OnClick(unlockBox)
	check(db.locked == false, "cures settings: the unlock box unlocks the frames")
	unlockBox:SetChecked(false); unlockBox.scripts.OnClick(unlockBox)
	check(db.locked == true, "cures settings: and locks them")
	local testBtns = {}
	for _, f in ipairs(frames) do if f.testKey and f.parentFrame == page then testBtns[f.testKey] = f end end
	check(testBtns.poison and testBtns.disease and testBtns.curse and testBtns.all and testBtns.clear, "cures settings: five test buttons")
	testBtns.poison.scripts.OnClick(testBtns.poison)
	check(S.testKey == "poison" and S.plainRow.poison.shown, "cures settings: a test button lights it")
	testBtns.clear.scripts.OnClick(testBtns.clear)
	check(S.testKey == nil, "cures settings: clear ends it")

	local function say(fn)                         -- what a command prints (print is only swapped while it runs)
		local out, pr = {}, print
		print = function(...) out[#out + 1] = table.concat({ ... }, " ") end
		local ok, err = pcall(fn)
		print = pr
		if not ok then error(err, 0) end
		return out
	end
	say(function() SlashCmdList.SHAMANKIT("cures test disease") end)
	check(S.testKey == "disease" and S.plainRow.disease.shown, "cures slash: /shamankit cures test disease")
	say(function() SlashCmdList.SHAMANKIT("cures test clear") end)
	check(S.testKey == nil, "cures slash: ... clear")
	local out = say(function() SlashCmdList.SHAMANKIT("cures status") end)
	check(#out >= 6 and out[1]:find("cures: on") and out[2]:find("lit by the game"), "cures slash: status prints the state and where it is lit from")
	local blob = table.concat(out, "\n")
	check(blob:find("Cure Poison: you have it, 1 action bar button\n") and blob:find("Cure Disease: you have it, 1 action bar button\n") and blob:find("Shatter Curse: you have it, 0 action bar buttons"), "cures slash: status names each cure and its buttons")
	check(blob:find("debuff types on you"), "cures slash: ...and the debuff types the game reported")
	say(function() SlashCmdList.SHAMANKITCURE("test all") end)
	check(S.testKey == "all", "cures slash: /cw still works as an alias")
	say(function() SlashCmdList.SHAMANKITCURE("clear") end); ns.cureTest("clear")
	say(function() SlashCmdList.SHAMANKIT("cures off") end)
	check(db.cureOn == false, "cures slash: /shamankit cures off")
	say(function() SlashCmdList.SHAMANKIT("cures on") end)
	check(db.cureOn == true, "cures slash: ... on")
	out = say(function() SlashCmdList.SHAMANKIT("cures nonsense") end)
	check(out[#out] and out[#out]:find("/shamankit cures"), "cures slash: help for something it doesn't know")
	check(SLASH_SHAMANKITCURE1 == "/curewatch" and SLASH_SHAMANKITCURE2 == "/cw", "cures: the old addon's commands answer")

	-- the home page
	local homeBtn
	for _, f in ipairs(frames) do if f.kind == "Button" and f.text == "Cures" and f.parentFrame == savedCat.pages[1] then homeBtn = f end end
	check(homeBtn ~= nil, "cures settings: a button for it on the home page")

	-- damaged saved numbers never break the layout
	db.cureSize, db.cureSpacing, db.cureWashAlpha, db.cureX = "big", {}, 0/0, "x"
	ns.cureApply()
	check(S.rowSlots.poison.w == 36, "cures: damaged saved numbers fall back to sensible ones")
	db.cureSize, db.cureSpacing, db.cureWashAlpha, db.cureX = 36, 4, 30, 0
	ns.cureApply()
	noErrors("cures: nothing raised an error in the log")
	reset(); CONTAINER_FAILS = true
end


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
		UNIT_AURA = true, UNIT_INVENTORY_CHANGED = true, PLAYER_EQUIPMENT_CHANGED = true,
		-- the cures: all of these appear in addons installed for this client (RareScanner, CampingKit, ForeverFishing, WhatsTraining)
		SPELLS_CHANGED = true, PLAYER_LEVEL_UP = true, ACTIONBAR_SLOT_CHANGED = true, ACTIONBAR_PAGE_CHANGED = true, SPELL_UPDATE_COOLDOWN = true }
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
		check(#allCats == before + 6, "no sub-page support: the pages become categories of their own")
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
