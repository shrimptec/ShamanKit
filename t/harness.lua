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
CALLS = setmetatable({}, { __index = function() return 0 end })
local function mock(kind)
	local o = { kind = kind, shown = true, scripts = {}, checked = false, value = 0, attrs = {} }
	return setmetatable(o, { __index = function(t, k)
		-- secure (protected) frames refuse these in combat, exactly like the real client: the popup the user saw
		if rawget(t, "protected") and InCombatLockdown() and (k == "SetPoint" or k == "ClearAllPoints" or k == "SetSize"
			or k == "Show" or k == "Hide" or k == "SetShown" or k == "SetAttribute" or k == "EnableMouse" or k == "SetParent") then
			return function() error("ADDON_ACTION_BLOCKED: " .. k .. " on a protected frame in combat") end
		end
		if k == "SetAttribute" then return function(self, n, v) self.attrs[n] = v end end
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
function CreateFrame(kind, name, parent, tmpl)
	local f = mock(kind); f.name = name; f.tmpl = tmpl
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
C_UnitAuras = { GetAuraDataBySpellName = function(_, name) if secretPos then return secret() end return auras[name] end }

local savedCat
Settings = {
	RegisterCanvasLayoutCategory = function(p, n) savedCat = { GetID = function() return 7 end, panel = p }; return savedCat end,
	RegisterAddOnCategory = function() end,
	OpenToCategory = function(id) savedCat.opened = id end,
}
SlashCmdList = {}
local timers = {}
C_Timer = { After = function(_, fn) timers[#timers + 1] = fn end }
local function runTimers() local t = timers; timers = {}; for _, fn in ipairs(t) do fn() end end

local ns = {}
local function load(file) local f = assert(loadfile(file)); f("TotemRange", ns) end
load("TotemRange/TotemRange.lua")
load("TotemRange/Options.lua")

local ev
for _, f in ipairs(frames) do if f.scripts.OnEvent then ev = f end end
local function fire(e, ...) ev.scripts.OnEvent(ev, e, ...) end
local function bar() return _G.TotemRangeBar end
local function btn(i) return _G["TotemRangeButton" .. i] end
local function tick() bar().scripts.OnUpdate(bar(), 0.25) end
local fails = 0
local function check(cond, msg) if not cond then fails = fails + 1; print("FAIL: " .. msg) else print("ok:   " .. msg) end end
local function noErrors(msg)
	local bad
	for _, l in ipairs(TotemRangeDB.log or {}) do if l:find("ERROR") then bad = l end end
	check(bad == nil, msg .. (bad and (" -> " .. bad) or ""))
end

fire("ADDON_LOADED", "TotemRange")
-- The bar is the anchor of the secure click buttons, so the real client treats it as restricted in combat:
-- insecure code may not show, hide, move or resize it then (this is what the "action blocked" popup is about).
rawset(_G.TotemRangeBar, "protected", true)
check(TotemRangeDB and TotemRangeDB.size == 36, "defaults filled")
check(savedCat ~= nil, "settings category registered")
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
local hit2 = _G.TotemRangeHit2
check(hit2 and hit2.tmpl == "SecureActionButtonTemplate", "slot buttons are secure action buttons")
check(hit2.attrs["*type2"] == "destroytotem" and hit2.attrs["totem-slot"] == 2, "right-click is the built-in destroytotem action for that slot")
check(hit2.attrs["type1"] == nil and hit2.attrs["*type1"] == nil, "left-click does nothing")
check(hit2.mouse == true, "a shown totem's button takes clicks")
check(_G.TotemRangeHit1.mouse == false and _G.TotemRangeHit4.mouse == false, "empty slots' buttons don't block the mouse")
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
check(btn(3).shown and _G.TotemRangeHit3.mouse == false, "combat: new totem visible, its button not yet clickable")
noErrors("combat with protected frames locked: no blocked actions in the log")
secretMode = false; inCombat = false
fire("PLAYER_REGEN_ENABLED"); tick()
check(btn(2).shown and btn(3).shown, "combat over: resync keeps the live totems")
check(_G.TotemRangeHit3.mouse == true and _G.TotemRangeHit2.mouse == true and _G.TotemRangeHit4.mouse == false, "combat over: clickable exactly where totems are")
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
TotemRangeDB.size = 50; panel.OnRefresh(); 
local sl
for _, f in ipairs(frames) do if f.kind == "Slider" and f.scripts.OnValueChanged then sl = f; break end end
sl.scripts.OnValueChanged(sl, 60)
check(TotemRangeDB.size == 60 and btn(1).w == 60, "size slider resizes icons")
check(bar().w == 4 * 60 + 3 * 4, "bar width fits 4 icons + spacing")
TotemRangeDB.vertical = true; ns.updatePreview()
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
TotemRangeDB.attach = true; ns.updatePreview()
check(TotemFrame.alpha == 0, "Blizzard totem timers made invisible when attached")
local last = pts[#pts]
check(last[1] == "TOPLEFT" and last[2] == PlayerFrame and last[3] == "BOTTOMLEFT" and last[4] == 65, "bar anchored under the player frame")
TotemFrame:SetAlpha(1)
check(TotemFrame.alpha == 0, "Blizzard re-showing its frame is undone")
TotemRangeDB.attach = false; ns.updatePreview()
check(TotemFrame.alpha == 1, "Blizzard timers restored when detached")
check(pts[#pts][2] == UIParent, "bar back on its saved screen position")

-- exact distance under each totem
pos = { y = 100, x = 100, map = 1 }; fire("PLAYER_ENTERING_WORLD"); fire("PLAYER_TOTEM_UPDATE", 2)
pos = { y = 100, x = 112.4, map = 1 }
TotemRangeDB.distanceMode = "off"; tick()
check(not btn(2).dist.shown, "distance hidden when the option is off")
TotemRangeDB.distanceMode = "yards"; tick()
check(btn(2).dist.shown and btn(2).dist.text == "12.4 yd", "shows 12.4 yd: " .. tostring(btn(2).dist.text))
pos = { y = 100, x = 145, map = 1 }; tick()
check(btn(2).dist.text == "45.0 yd" and btn(2).dist.color[1] > 0.9 + 0 - 0.0 , "45 yd, red when out of range")
pos = nil; tick()
check(not btn(2).dist.shown, "no distance shown when only the buff is known")
TotemRangeDB.distanceMode = "off"

SlashCmdList.TOTEMRANGE("unlock")
check(TotemRangeDB.locked == false and bar().anyShown, "/totemrange unlock shows the frame")
-- the exact bug from the field: left unlocked, real totems must still be tracked (not replaced by samples)
fire("PLAYER_ENTERING_WORLD"); pos = { y = 5, x = 5, map = 1 }; fire("PLAYER_TOTEM_UPDATE", 2)
pos = { y = 5, x = 80, map = 1 }; TotemRangeDB.distanceMode = "yards"; tick()
check(btn(2).shown and not btn(1).shown and not btn(3).shown, "unlocked with a real totem out: only the real totem shows")
check(btn(2).dist.text == "75.0 yd" and btn(2).mark.tex:find("NotReady"), "unlocked: real distance (75.0 yd) and red, not sample numbers")
TotemRangeDB.distanceMode = "off"
-- Totemic Recall while unlocked: every totem goes, nothing fake appears in its place
local keep = totems
totems = {}
for slot = 1, 4 do fire("PLAYER_TOTEM_UPDATE", slot) end
check(not btn(1).shown and not btn(2).shown and not btn(3).shown and not btn(4).shown, "Totemic Recall (unlocked): no icons at all, no placeholders")
check(not bar().anyShown, "...and nothing else on screen: no drag box, bar hidden")
SlashCmdList.TOTEMRANGE("lock")
check(not bar().anyShown, "locked and no totems: nothing on screen")
SlashCmdList.TOTEMRANGE("unlock")
totems = keep
pos = { y = 5, x = 5, map = 1 }; fire("PLAYER_TOTEM_UPDATE", 2)
check(btn(2).shown and bar().anyShown, "new totem: the real icon shows")
SlashCmdList.TOTEMRANGE("lock")
SlashCmdList.TOTEMRANGE("")
check(savedCat.opened == 7, "/totemrange opens the settings")
SlashCmdList.TOTEMRANGE("status")

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
	for _, line in ipairs(TotemRangeDB.log or {}) do if line:find("RESCAN found slot 3") then logged = true end end
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
		TotemRangeDB.distanceMode = "yards"; tick(); TotemRangeDB.distanceMode = "off"
		SlashCmdList.TOTEMRANGE("status")
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
	TotemRangeDB.distanceMode = nil; TotemRangeDB.vertical = false
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
	TotemRangeDB.distanceMode = "yards"; ns.updatePreview(); pos = { y = 0, x = 12.4, map = 1 }; tick()
	check(not g(2).shown and btn(2).dist.shown and btn(2).dist.text == "12.4 yd", "yards mode: the number, no bar")
	TotemRangeDB.distanceMode = "off"; ns.updatePreview(); tick()
	check(not g(2).shown and not btn(2).dist.shown, "off: neither")
	TotemRangeDB.distanceMode = "bar"; ns.updatePreview(); tick()
	check(g(2).shown and not btn(2).dist.shown, "back to the bar: bar only")
	TotemRangeDB.distanceMode = "garbage"
	check(ns.distMode() == "bar", "a damaged setting means the bar")
	TotemRangeDB.distanceMode = "bar"
	-- layout direction and size
	check(g(2).orientation == "HORIZONTAL", "horizontal bar: the range bar runs left to right under the icon")
	TotemRangeDB.vertical = true; ns.apply(); tick()
	check(g(2).orientation == "VERTICAL", "vertical bar: the range bar stands on the icon's right side")
	TotemRangeDB.vertical = false; ns.apply()
	-- the settings radio buttons
	local radios = {}
	for _, f in ipairs(frames) do if f.mode and f.scripts.OnClick then radios[f.mode] = f end end
	check(radios.bar and radios.yards and radios.off, "settings: three choices (range bar, exact yards, nothing)")
	radios.yards.scripts.OnClick(radios.yards)
	check(TotemRangeDB.distanceMode == "yards" and radios.yards.checked and not radios.bar.checked, "clicking 'Exact yards' selects it and unticks the others")
	radios.off.scripts.OnClick(radios.off); radios.bar.scripts.OnClick(radios.bar)
	check(TotemRangeDB.distanceMode == "bar" and radios.bar.checked and not radios.off.checked, "clicking 'Range bar' selects it")
	-- the preview while the settings are open and nothing is out: four different fills so the look can be judged
	totems = {}; fire("PLAYER_TOTEM_UPDATE", 2); ns.optionsOpen = true; ns.updatePreview()
	check(near(g(1).value, 0.69) and near(g(2).value, 0.51) and g(3).value == 0 and near(g(4).value, 0.25),
		("preview: Searing 0.69, Strength 0.51, one empty, one nearly out (%.2f %.2f %.2f %.2f)"):format(g(1).value, g(2).value, g(3).value, g(4).value))
	check(g(3).edge.color[1] > 0.7, "preview: the out-of-range sample has the red frame")
	ns.optionsOpen = false; ns.updatePreview()
	check(not g(1).shown and not g(2).shown and not g(3).shown and not g(4).shown, "settings closed, no totems: no bars left behind")
	TotemRangeDB.distanceMode = "off"
end

-- ---- keeping a place open for an element: the gap (a dim placeholder) shows which totem is missing
do
	local holders = {}
	for _, f in ipairs(frames) do if f.kind == "Frame" and f.icon and f.border and not f.name then holders[#holders + 1] = f end end
	check(#holders == 4, "one placeholder per element")
	local function X(f) return f.anchor and f.anchor[4] end
	local function Y(f) return f.anchor and f.anchor[5] end
	local function hit(slot) return _G["TotemRangeHit" .. slot] end
	local gap = TotemRangeDB.size + TotemRangeDB.spacing
	local function out() totems = {}; for slot = 1, 4 do fire("PLAYER_TOTEM_UPDATE", slot) end end
	local function put(slot, name) totems[slot] = { name = name, start = t, dur = 300, icon = 8 }; fire("PLAYER_TOTEM_UPDATE", slot) end
	TotemRangeDB.order = { 2, 1, 3, 4 }; TotemRangeDB.vertical = false; TotemRangeDB.distanceMode = "off"
	secretMode = false; secretPos = false; inCombat = false; pos = { y = 0, x = 0, map = 1 }
	fire("PLAYER_ENTERING_WORLD"); out()

	-- off by default: nothing changes
	TotemRangeDB.reserve = nil; ns.fixReserve()
	put(1, "Searing Totem III")
	check(not holders[1].shown and not holders[2].shown and not holders[3].shown and not holders[4].shown, "default: no placeholders")
	check(X(btn(1)) == 0 and bar().w == TotemRangeDB.size, "default: a lone totem sits first, the bar is one icon wide")

	-- reserve earth and air, fire is out
	TotemRangeDB.reserve = { [2] = true, [4] = true }; ns.apply()
	check(holders[2].shown and holders[4].shown and not holders[1].shown and not holders[3].shown, "earth and air reserved: their placeholders show, fire and water's do not")
	check(X(holders[2]) == 0 and X(btn(1)) == gap and X(holders[4]) == 2 * gap, "...earth first, fire in its place, air third (water takes no space)")
	check(bar().w == 3 * TotemRangeDB.size + 2 * TotemRangeDB.spacing, "...the bar is three icons wide")
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
	TotemRangeDB.reserve = { [1] = true, [2] = true, [3] = true, [4] = true }; ns.apply()
	check(holders[2].shown and holders[1].shown and holders[4].shown and not holders[3].shown and X(btn(3)) == 2 * gap, "all four reserved: water out, the other three marked, nothing moves")

	-- vertical keeps the same order down the bar
	TotemRangeDB.vertical = true; ns.apply()
	check(Y(holders[2]) == 0 and Y(holders[1]) == -gap and Y(btn(3)) == -2 * gap and Y(holders[4]) == -3 * gap, "vertical: the same places, top to bottom")
	TotemRangeDB.vertical = false; ns.apply()

	-- the settings preview: a reserved element shows its placeholder instead of a sample
	out(); TotemRangeDB.reserve = { [3] = true }; ns.optionsOpen = true; ns.updatePreview()
	check(holders[3].shown and not btn(3).shown and btn(1).shown and btn(2).shown and btn(4).shown, "settings preview: water reserved shows as an empty place, the others as samples")
	TotemRangeDB.reserve = {}; ns.apply()
	check(not holders[3].shown and btn(3).shown, "...and unticking it brings the sample back")
	TotemRangeDB.reserve = { [1] = true, [2] = true, [3] = true, [4] = true }; ns.apply()
	check(holders[1].shown and holders[2].shown and holders[3].shown and holders[4].shown, "preview with everything reserved: four empty places")
	ns.optionsOpen = false; ns.updatePreview()
	check(not holders[1].shown and not holders[2].shown and not bar().anyShown, "settings closed, nothing out: no placeholders")

	-- the four boxes in the settings
	local boxes = {}
	for _, f in ipairs(frames) do if f.rowIndex and f.kind == "CheckButton" and f.scripts.OnClick then boxes[ns.fixOrder()[f.rowIndex]] = f end end
	check(boxes[1] and boxes[2] and boxes[3] and boxes[4], "settings: a box for each element")
	TotemRangeDB.reserve = {}
	boxes[3].checked = true; boxes[3].scripts.OnClick(boxes[3])
	check(TotemRangeDB.reserve[3] == true and not TotemRangeDB.reserve[2], "ticking Water reserves water only")
	boxes[3].checked = false; boxes[3].scripts.OnClick(boxes[3])
	check(TotemRangeDB.reserve[3] == nil, "unticking it clears it")
	TotemRangeDB.reserve = { [2] = true }; savedCat.panel.OnRefresh()
	check(boxes[2].checked == true and not boxes[1].checked, "the boxes show the saved state when the panel opens")
	savedCat.panel.OnDefault()
	check(next(TotemRangeDB.reserve) == nil, "Defaults clears them")

	-- damaged saved data
	for label, bad in pairs({ ["a string"] = "x", ["yes/no text"] = { [2] = "yes", [3] = 0 }, ["a number"] = 7 }) do
		TotemRangeDB.reserve = bad
		fire("PLAYER_ENTERING_WORLD"); ns.fixReserve()
		local r = TotemRangeDB.reserve
		check(type(r) == "table" and r[2] == nil and r[3] == nil, "damaged reserve (" .. label .. ") is cleaned")
	end
	TotemRangeDB.reserve = {}; TotemRangeDB.distanceMode = "off"; ns.apply(); out()
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
	local function lastLog() local l = TotemRangeDB.log; return l[#l] end
	fire("ADDON_ACTION_BLOCKED", "SomeOtherAddon", "Frame:Hide()")
	check(not (lastLog() or ""):find("ACTION_BLOCKED"), "a block caused by another addon is not logged as ours")
	local before = #printedErrors
	fire("ADDON_ACTION_BLOCKED", "TotemRange", "TotemRangeBar:Hide()")
	check((lastLog() or ""):find("ADDON_ACTION_BLOCKED: TotemRangeBar:Hide()", 1, true), "our blocked action is logged with the function name")
	check(#printedErrors == before, "...and logging it raises nothing")
end

-- ---- what the dim placeholder shows: a locked totem, else the last totem that was out there, else a generic one
do
	local holders = {}
	for _, f in ipairs(frames) do if f.kind == "Frame" and f.icon and f.border and not f.name then holders[#holders + 1] = f end end
	local TEX = function(id) return 100000 + id end
	local function out() totems = {}; for slot = 1, 4 do fire("PLAYER_TOTEM_UPDATE", slot) end end
	local function put(slot, name, icon) totems[slot] = { name = name, start = t, dur = 300, icon = icon }; fire("PLAYER_TOTEM_UPDATE", slot) end
	TotemRangeDB.order = { 2, 1, 3, 4 }; TotemRangeDB.vertical = false; TotemRangeDB.distanceMode = "off"
	TotemRangeDB.hold = nil; TotemRangeDB.rememberLast = true; TotemRangeDB.reserve = { [2] = true, [3] = true }
	secretMode = false; secretPos = false; inCombat = false; pos = { y = 0, x = 0, map = 1 }
	fire("PLAYER_ENTERING_WORLD"); out(); ns.fixHold()
	put(1, "Searing Totem III", 777)   -- keeps the bar up while the others come and go
	check(holders[2].tex == TEX(8071) and holders[3].tex == TEX(5394), "nothing remembered yet: the generic totem of the element (Stoneskin for earth, Healing Stream for water)")

	-- remembers the last totem seen in that place
	put(2, "Strength of Earth Totem II", 888); totems[2] = nil; fire("PLAYER_TOTEM_UPDATE", 2)
	check(TotemRangeDB.hold.last[2] == 888 and holders[2].shown and holders[2].tex == 888, "an earth totem came and went: the placeholder is its icon")
	put(2, "Stoneskin Totem", 999); totems[2] = nil; fire("PLAYER_TOTEM_UPDATE", 2)
	check(holders[2].tex == 999, "a different earth totem next time: the placeholder follows the newest one")
	check(holders[3].tex == TEX(5394), "...water, never seen, stays generic")

	-- remembering switched off
	TotemRangeDB.rememberLast = false; ns.updatePreview()
	check(holders[2].tex == TEX(8071), "remembering off: back to the generic icon")
	check(TotemRangeDB.hold.last[2] == 999, "...but it kept remembering underneath")
	TotemRangeDB.rememberLast = true; ns.updatePreview()
	check(holders[2].tex == 999, "remembering on again: straight back to what it knew")

	-- a locked choice beats the memory and survives new totems
	TotemRangeDB.hold.choice[2] = 8075; ns.updatePreview()
	check(holders[2].tex == TEX(8075), "locked to Strength of Earth: that icon, not the remembered one")
	put(2, "Stoneskin Totem", 555); totems[2] = nil; fire("PLAYER_TOTEM_UPDATE", 2)
	check(holders[2].tex == TEX(8075) and TotemRangeDB.hold.last[2] == 555, "...it stays locked while new totems are still remembered underneath")
	TotemRangeDB.rememberLast = false; ns.updatePreview()
	check(holders[2].tex == TEX(8075), "...and locking works with remembering off")
	TotemRangeDB.hold.choice[2] = nil; TotemRangeDB.rememberLast = true; ns.updatePreview()
	check(holders[2].tex == 555, "unlocked: the memory shows again")
	TotemRangeDB.hold.choice[2] = 123456789   -- a totem this client does not know: texture lookup still answers in the mock, so use a real miss
	local realTex = C_Spell.GetSpellTexture
	C_Spell.GetSpellTexture = function(id) if id == 123456789 then return nil end return realTex(id) end
	ns.updatePreview()
	check(holders[2].tex == 555, "a locked totem with no icon in this client falls back to the memory instead of showing nothing")
	C_Spell.GetSpellTexture = realTex; TotemRangeDB.hold.choice[2] = nil

	-- in a fight the game hides the icon: the name taken from the cast stands in
	out(); put(1, "Searing Totem III", 777)
	secretMode = true; inCombat = true
	fire("UNIT_SPELLCAST_SUCCEEDED", "player", "g", 5675)   -- Mana Spring Totem cast
	totems[3] = { name = "Mana Spring Totem", start = t, dur = 300, icon = 4242 }
	fire("PLAYER_TOTEM_UPDATE", 3); runTimers()
	secretMode = false; inCombat = false
	check(TotemRangeDB.hold.last[3] == TEX(5675), "icon hidden in combat: remembered by the name of the totem that was cast")
	totems[3] = nil; fire("PLAYER_TOTEM_UPDATE", 3)
	check(holders[3].tex == TEX(5675), "...and the placeholder shows it")

	-- damaged saved data
	for label, bad in pairs({ ["a string"] = "x", ["junk inside"] = { last = { [2] = {} , [3] = true }, choice = { [1] = "a", [2] = {} } }, ["a number"] = 5 }) do
		TotemRangeDB.hold = bad
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
	TotemRangeDB.hold = nil; ns.fixHold(); TotemRangeDB.reserve = {}; TotemRangeDB.order = { 2, 1, 3, 4 }; savedCat.panel.OnRefresh()
	local pick, keep = {}, {}
	for _, f in ipairs(frames) do
		if f.rowIndex and f.kind == "Button" and f.scripts.OnClick then pick[f.rowIndex] = f end
		if f.rowIndex and f.kind == "CheckButton" then keep[f.rowIndex] = f end
	end
	check(pick[1] and pick[4] and pick[1].text == "Auto", "settings: a picker per row, starting on Auto")
	pick[1].scripts.OnClick(pick[1], "LeftButton")
	check(TotemRangeDB.hold.choice[2] == 5730 and pick[1].text == "Stoneclaw", "left-click: the first earth totem, shown without the word Totem")
	pick[1].scripts.OnClick(pick[1], "LeftButton"); pick[1].scripts.OnClick(pick[1], "LeftButton")
	check(TotemRangeDB.hold.choice[2] == 2484, "left-click again twice: third earth totem")
	pick[1].scripts.OnClick(pick[1], "RightButton")
	check(TotemRangeDB.hold.choice[2] == 8071, "right-click goes back one")
	for _ = 1, 4 do pick[1].scripts.OnClick(pick[1], "LeftButton") end
	check(TotemRangeDB.hold.choice[2] == nil and pick[1].text == "Auto", "past the last totem it wraps round to Auto")
	pick[1].scripts.OnClick(pick[1], "RightButton")
	check(TotemRangeDB.hold.choice[2] == 8143, "right-click from Auto goes to the last totem")
	-- a row follows the element it shows, so reordering moves the pickers with it
	TotemRangeDB.hold.choice = {}; ns.moveSlot(1, 1); savedCat.panel.OnRefresh()
	pick[1].scripts.OnClick(pick[1], "LeftButton")
	check(TotemRangeDB.hold.choice[1] == 3599 and not TotemRangeDB.hold.choice[2], "after moving fire to the top, the first row picks fire totems")
	ns.resetOrder()
	-- the keep-a-space box on a row, and the remember box
	savedCat.panel.OnRefresh()
	keep[2].checked = true; keep[2].scripts.OnClick(keep[2])
	check(TotemRangeDB.reserve[1] == true and not TotemRangeDB.reserve[2], "the Keep box on the second row (fire) reserves fire")
	local remBox
	for _, f in ipairs(frames) do if f.settingKey == "rememberLast" then remBox = f end end
	remBox.checked = false; remBox.scripts.OnClick(remBox)
	check(TotemRangeDB.rememberLast == false, "the 'last totem used' box switches remembering off")
	remBox.checked = true; remBox.scripts.OnClick(remBox)
	check(TotemRangeDB.rememberLast == true, "...and on")
	TotemRangeDB.hold.choice[2] = 5730; savedCat.panel.OnDefault()
	check(next(TotemRangeDB.hold.choice) == nil and next(TotemRangeDB.reserve) == nil and TotemRangeDB.rememberLast == true, "Defaults clears locked totems and reserved spaces, remembering back on")
	TotemRangeDB.reserve = {}; TotemRangeDB.hold = nil; ns.fixHold(); out()
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
	local gap = TotemRangeDB.size + TotemRangeDB.spacing
	TotemRangeDB.order = nil; ns.fixOrder()
	check(table.concat(TotemRangeDB.order, ",") == "2,1,3,4", "default order is earth, fire, water, air (slots 2,1,3,4)")
	TotemRangeDB.vertical = false
	placeAll()
	check(sequence() == "2,1,3,4" and xOf(2) == 0 and xOf(1) == gap and xOf(3) == 2 * gap and xOf(4) == 3 * gap,
		"all four out: earth, fire, water, air, left to right with the right spacing")
	totems[3] = nil; fire("PLAYER_TOTEM_UPDATE", 3)
	check(sequence() == "2,1,4" and xOf(4) == 2 * gap, "no water totem: the others close the gap but keep their order")
	local n = 0
	local before = table.concat(TotemRangeDB.order, ",")
	check(ns.moveSlot(1, -1) == false and ns.moveSlot(4, 1) == false and table.concat(TotemRangeDB.order, ",") == before,
		"moving the first one up / the last one down does nothing")
	check(ns.moveSlot(1, 1) == true and table.concat(TotemRangeDB.order, ",") == "1,2,3,4", "move earth down one: fire, earth, water, air")
	check(sequence() == "1,2,4", "...and the bar follows at once")
	check(ns.moveSlot(4, -1) == true and table.concat(TotemRangeDB.order, ",") == "1,2,4,3" and sequence() == "1,2,4", "move air up: fire, earth, air, water")
	-- the real Up / Down buttons in the settings panel
	local down
	for _, f in ipairs(frames) do if f.orderRow == 1 and f.orderDelta == 1 and f.scripts.OnClick then down = f break end end
	check(down ~= nil, "settings panel has Up / Down buttons")
	TotemRangeDB.order = { 2, 1, 3, 4 }
	down.scripts.OnClick(down)    -- the first Down button: earth <-> fire
	check(table.concat(TotemRangeDB.order, ",") == "1,2,3,4", "the first Down button swaps the first two")
	local reset
	for _, f in ipairs(frames) do if f.text == "Reset order" and f.scripts.OnClick then reset = f break end end
	reset.scripts.OnClick(reset)
	check(table.concat(TotemRangeDB.order, ",") == "2,1,3,4" and sequence() == "2,1,4", "Reset order restores earth, fire, water, air")
	-- damaged saved data
	for label, bad in pairs({ ["duplicate"] = { 1, 1, 2, 3 }, ["too short"] = { 1, 2, 3 }, ["not a table"] = "x",
		["out of range"] = { 1, 2, 3, 9 }, ["fraction"] = { 1, 2, 3, 3.5 }, ["empty"] = {} }) do
		TotemRangeDB.order = bad
		fire("PLAYER_ENTERING_WORLD"); ns.fixOrder()
		check(table.concat(TotemRangeDB.order, ",") == "2,1,3,4", "damaged order (" .. label .. ") falls back to the default")
	end
	TotemRangeDB.order = { 2, 1, 3, 4 }
	-- vertical keeps the same order
	TotemRangeDB.vertical = true; ns.apply(); placeAll()
	local list = {}
	for slot = 1, 4 do list[#list + 1] = { slot, btn(slot).anchor[5] } end
	table.sort(list, function(a, b) return a[2] > b[2] end)
	check(list[1][1] == 2 and list[2][1] == 1 and list[3][1] == 3 and list[4][1] == 4, "vertical bar: earth on top, then fire, water, air")
	TotemRangeDB.vertical = false; ns.apply()
	totems = {}; for slot = 1, 4 do fire("PLAYER_TOTEM_UPDATE", slot) end
end

-- ---- cost: what one tick (0.25 s) costs while four totems are out and the distance text is on (the worst case)
do
	totems = {
		[1] = { name = "Searing Totem III", start = t, dur = 60, icon = 7 }, [2] = { name = "Strength of Earth Totem II", start = t, dur = 300, icon = 8 },
		[3] = { name = "Mana Spring Totem", start = t, dur = 300, icon = 9 }, [4] = { name = "Windfury Totem", start = t, dur = 300, icon = 10 } }
	secretMode = false; secretPos = false; inCombat = false; mapOn = true
	pos = { y = 0, x = 0, map = 1 }
	TotemRangeDB.distanceMode = "bar"; TotemRangeDB.showRange = true
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
	TotemRangeDB.distanceMode = "off"
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

check(#printedErrors == 0, "the addon never printed an error line during the whole run" .. (printedErrors[1] and (": " .. printedErrors[1]) or ""))
print(fails == 0 and "ALL PASSED" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
