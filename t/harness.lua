-- Loads the addon against a mocked WoW API and walks through placement / range / preview.
-- Run: luajit t/harness.lua   (from the project root)

local SECRET = {}
local function boom() error("attempt to use a secret value") end
for _, k in ipairs({ "__lt", "__le", "__add", "__sub", "__mul", "__div", "__concat", "__unm", "__call", "__len", "__index", "__newindex" }) do SECRET[k] = boom end
SECRET.__tostring = function() return "<secret>" end
local function secret() return setmetatable({}, SECRET) end
issecretvalue = function(v) return type(v) == "table" and getmetatable(v) == SECRET end
local scripts = {}
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
		if k == "SetValue" then return function(self, v) self.value = v; if self.scripts.OnValueChanged then self.scripts.OnValueChanged(self, v) end end end
		if k == "SetText" then return function(self, v) self.text = v end end
		if k == "SetTextColor" then return function(self, ...) self.color = { ... } end end
		if k == "SetVertexColor" then return function(self, ...) self.color = { ... } end end
		if k == "SetTexture" then return function(self, v) self.tex = v end end
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
C_Spell = { GetSpellTexture = function() return 1234 end, GetSpellInfo = function(id)
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
check(TotemRangeDB and TotemRangeDB.size == 36, "defaults filled")
check(savedCat ~= nil, "settings category registered")
fire("PLAYER_ENTERING_WORLD")
check(not bar().shown, "bar hidden with no totems while locked")

-- place Strength of Earth in slot 2 at (100,100)
totems[2] = { name = "Strength of Earth Totem IV", start = t, dur = 300, icon = 99 }
fire("PLAYER_TOTEM_UPDATE", 2)
check(btn(2).shown and not btn(1).shown, "slot 2 button shown, slot 1 not")
check(bar().shown, "bar shown")
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
TotemRangeDB.showDistance = false; tick()
check(not btn(2).dist.shown, "distance hidden when the option is off")
TotemRangeDB.showDistance = true; tick()
check(btn(2).dist.shown and btn(2).dist.text == "12.4 yd", "shows 12.4 yd: " .. tostring(btn(2).dist.text))
pos = { y = 100, x = 145, map = 1 }; tick()
check(btn(2).dist.text == "45.0 yd" and btn(2).dist.color[1] > 0.9 + 0 - 0.0 , "45 yd, red when out of range")
pos = nil; tick()
check(not btn(2).dist.shown, "no distance shown when only the buff is known")
TotemRangeDB.showDistance = false

SlashCmdList.TOTEMRANGE("unlock")
check(TotemRangeDB.locked == false and bar().shown, "/totemrange unlock shows the frame")
-- the exact bug from the field: left unlocked, real totems must still be tracked (not replaced by samples)
fire("PLAYER_ENTERING_WORLD"); pos = { y = 5, x = 5, map = 1 }; fire("PLAYER_TOTEM_UPDATE", 2)
pos = { y = 5, x = 80, map = 1 }; TotemRangeDB.showDistance = true; tick()
check(btn(2).shown and not btn(1).shown and not btn(3).shown, "unlocked with a real totem out: only the real totem shows")
check(btn(2).dist.text == "75.0 yd" and btn(2).mark.tex:find("NotReady"), "unlocked: real distance (75.0 yd) and red, not sample numbers")
TotemRangeDB.showDistance = false
-- Totemic Recall while unlocked: every totem goes, nothing fake appears in its place
local keep = totems
totems = {}
for slot = 1, 4 do fire("PLAYER_TOTEM_UPDATE", slot) end
check(not btn(1).shown and not btn(2).shown and not btn(3).shown and not btn(4).shown, "Totemic Recall (unlocked): no icons at all, no placeholders")
check(not bar().shown, "...and nothing else on screen: no drag box, bar hidden")
SlashCmdList.TOTEMRANGE("lock")
check(not bar().shown, "locked and no totems: nothing on screen")
SlashCmdList.TOTEMRANGE("unlock")
totems = keep
pos = { y = 5, x = 5, map = 1 }; fire("PLAYER_TOTEM_UPDATE", 2)
check(btn(2).shown and bar().shown, "new totem: the real icon shows")
SlashCmdList.TOTEMRANGE("lock")
SlashCmdList.TOTEMRANGE("")
check(savedCat.opened == 7, "/totemrange opens the settings")
SlashCmdList.TOTEMRANGE("status")

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
		TotemRangeDB.showDistance = true; tick(); TotemRangeDB.showDistance = false
		SlashCmdList.TOTEMRANGE("status")
		if btn(1).scripts.OnEnter then btn(1).scripts.OnEnter(btn(1)) end
	end)
	check(ok, label .. ": nothing raises" .. (ok and "" or (" -> " .. tostring(err))))
	noErrors(label .. ": nothing in the error log")
	secretMode = false; secretPos = false; inCombat = false
end

print(fails == 0 and "ALL PASSED" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
