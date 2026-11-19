-- ShamanKit Badges: a small picture of the totem's BUFF on the totem's icon, drawn by the GAME while that buff is on you.
--
-- Why: in a dungeon no position can be read at all, and in a fight the game hides your buffs from addons, so the range
-- marks can't know whether you are in a totem's range. The game itself can still show a buff in a fight (the same route
-- as the Lightning Shield icon, and the one other addons on this client use for player buffs): an aura container with
-- one slot limited to the buff's spell id, anchored on the totem's icon. A badge on the icon means the buff is on you;
-- no badge means it is not. The addon never reads the aura in a fight.
--
-- The spell ids of a totem's buff are learned from the real thing: whenever the buff can be read (out of a fight) its
-- spell id is remembered under the buff's name (db.buffIds), so every rank works and the next fight already has it.
-- One container per spell id, made on demand out of combat and then only shown, hidden and anchored out of combat
-- (exactly what the shield icon does).
--
-- A buff from someone else's identical totem shows the same badge: it says "you have that buff", not whose it is.

local ADDON, ns = ...
local dbg, guard, isSecret = ns.dbg, ns.guard, ns.isSecret
local db

local D = ns.defaults
D.buffBadge = true             -- show the totem's buff on its icon while it is on you (works in a fight and in dungeons)
-- (db.buffIds is not a default: it is learned, one set of spell ids per buff name)

local SLOTS = 4
local MAX_IDS = 16                                  -- per buff name: ranks and look-alikes, never an endless list
local MAX_BOXES = 24                                -- containers in all (there is no way to remove one)

local S = { boxes = {}, nboxes = 0, scheduled = false, pending = false }
ns.badgeState = S

local function short(m) m = tostring(m):gsub("%s+", " "); return m:sub(1, 80) end

-- ---------------------------------------------------------------- learning the ids

function ns.learnBuff(name, id)
	if not db or type(name) ~= "string" or name == "" then return end
	if type(id) ~= "number" or isSecret(id) or id ~= id or id <= 1 then return end
	local all = db.buffIds
	if type(all) ~= "table" then all = {}; db.buffIds = all end
	local set = all[name]
	if type(set) ~= "table" then set = {}; all[name] = set end
	if set[id] then return end
	local n = 0
	for _ in pairs(set) do n = n + 1 end
	if n >= MAX_IDS then return end
	set[id] = true
	dbg("BADGE learned %s = spell %d", name, id)
	ns.badgeSchedule()
end

local function idsFor(name)
	local all = db and db.buffIds
	local set = type(all) == "table" and all[name]
	if type(set) ~= "table" or next(set) == nil then return nil end
	return set
end

local function sorted(set) local l = {}; for k, v in pairs(set) do if type(k) == "number" and v == true then l[#l + 1] = k end end table.sort(l); return l end

-- ---------------------------------------------------------------- one game-drawn container per spell id

local function size() return math.max(14, math.floor((db.size or 36) * 0.45 + 0.5)) end

-- runs once per button, BEFORE the game restricts it: everything the badge is made of goes in here
local function styleButton(button)
	local s = size()
	pcall(button.SetSize, button, s, s)
	pcall(function()
		local bar = ns.bar
		if bar then
			button:SetFrameStrata(bar:GetFrameStrata())
			button:SetFrameLevel((bar:GetFrameLevel() or 1) + 30)
		end
	end)
	pcall(button.EnableMouse, button, false)
	local icon = button:CreateTexture(nil, "BACKGROUND")
	icon:SetAllPoints()
	icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
	pcall(button.SetIcon, button, icon)                         -- the game puts the buff's own picture here
	local over = CreateFrame("Frame", nil, button)
	over:SetAllPoints()
	over:SetFrameLevel((button:GetFrameLevel() or 1) + 2)
	local border = over:CreateTexture(nil, "OVERLAY")
	border:SetTexture("Interface\\Buttons\\UI-Quickslot2")
	border:SetPoint("CENTER", 0, -1)
	border:SetSize(s * 66 / 36, s * 66 / 36)
	S.lastButton, S.lastBorder = button, border
end

local function makeBox(id)
	if S.failed or S.boxes[id] then return S.boxes[id] end
	if S.nboxes >= MAX_BOXES then return nil end
	local box
	local ok, err = pcall(function()
		if C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.LoadAddOn and not C_AddOns.IsAddOnLoaded("Blizzard_AuraContainer") then
			C_AddOns.LoadAddOn("Blizzard_AuraContainer")
		end
		local c = CreateFrame("AuraContainer", nil, UIParent, "CustomAuraContainerTemplate")
		c:SetUnit("player")
		c:SetSize(1, 1)
		S.lastButton, S.lastBorder = nil, nil
		local opts = { candidateFilters = { includeSpellIDs = { [id] = true } }, initializeFrame = styleButton }
		local how
		local key = "ShamanKitTotemBuff" .. id
		local button
		if c.AddAuraSlot then
			button = c:AddAuraSlot(key, "HELPFUL", opts) or S.lastButton
			how = "slot"
		else
			opts.maxFrameCount = 1
			c:AddAuraGroup(key, "HELPFUL", opts)
			pcall(c.SetAuraGroupMaxFrameCount, c, key, 1)
			pcall(c.SetFlowLayoutAnchorPoint, c, "TOPLEFT")
			how = "group"
		end
		box = { id = id, c = c, button = button, border = S.lastBorder, how = how }
		c:SetEnabled(false)
		c:Hide()
	end)
	if not ok then
		S.failed = true
		dbg("BADGE container could not be made for spell %d: %s (no buff badges; the range marks work as before)", id, short(err))
		return nil
	end
	S.boxes[id] = box
	S.nboxes = S.nboxes + 1
	dbg("BADGE container made for spell %d (%s)", id, box.how)
	return box
end

-- out of combat only: put the box on the totem's icon and show it, or hide it
local function place(box, b, s)
	local key = b and (tostring(b) .. "|" .. s) or "off"
	if box.key == key then return end
	box.key = key
	pcall(function()
		if b then
			box.c:ClearAllPoints()
			box.c:SetPoint("TOPLEFT", b, "TOPLEFT", -3, 3)
			if box.button then
				box.button:SetSize(s, s)
				if box.how == "slot" then box.button:ClearAllPoints(); box.button:SetPoint("TOPLEFT", b, "TOPLEFT", -3, 3) end
			end
			if box.border then box.border:SetSize(s * 66 / 36, s * 66 / 36) end
			box.c:SetEnabled(true)
			box.c:Show()
		else
			box.c:SetEnabled(false)
			box.c:Hide()
		end
	end)
end

-- the whole pass (out of combat, auras not hidden): which totems get a badge, which spell ids, how big
local function apply()
	if not db then return end
	if InCombatLockdown() or (ns.aurasHidden and ns.aurasHidden()) then S.pending = true return end
	S.pending = false
	local wanted = db.buffBadge ~= false
	local s = size()
	local want = {}                                                    -- spell id -> the totem's icon it sits on
	if wanted and not S.failed then
		for slot = 1, SLOTS do
			local b = ns.barButton and ns.barButton(slot)
			local st = ns.barState and ns.barState(slot)
			local set = (b and b:IsShown() and st and st.aura) and idsFor(st.aura) or nil
			if set then for _, id in ipairs(sorted(set)) do if not want[id] then want[id] = b end end end
		end
		for id in pairs(want) do makeBox(id) end
	end
	for id, box in pairs(S.boxes) do place(box, want[id], s) end
end
ns.badgeApply = guard("badges", apply)

-- many things ask for a pass at once (every totem event): one pass a moment later
local run = guard("badges", function()
	S.scheduled = false
	apply()
end)
function ns.badgeSchedule()
	if S.scheduled then return end
	S.scheduled = true
	if C_Timer and C_Timer.After then C_Timer.After(0.05, run) else run() end
end

-- ---------------------------------------------------------------- events

local EVENTS = { "PLAYER_ENTERING_WORLD", "PLAYER_REGEN_ENABLED" }
ns.BADGE_EVENTS = EVENTS
local cf
function ns.badgeInit()
	db = ns.get()
	if cf then return end
	cf = CreateFrame("Frame")
	cf:SetScript("OnEvent", guard("badges event", function() ns.badgeSchedule() end))
	for _, e in ipairs(EVENTS) do
		local ok, err = pcall(cf.RegisterEvent, cf, e)
		if not ok then dbg("BADGE: event %s is not known here (%s)", e, short(err)) end
	end
	ns.badgeSchedule()
end

-- ---------------------------------------------------------------- status

function ns.badgeInfo()
	local out = {}
	if not db then return out end
	local names = {}
	for name, set in pairs(type(db.buffIds) == "table" and db.buffIds or {}) do
		if type(set) == "table" then names[#names + 1] = name .. " (" .. table.concat(sorted(set), ",") .. ")" end
	end
	table.sort(names)
	out[#out + 1] = ("buff badges: %s, %s"):format(db.buffBadge ~= false and "on" or "off",
		S.failed and "the game would not make the container" or (S.nboxes > 0 and ("%d drawn by the game"):format(S.nboxes) or "none made yet"))
	out[#out + 1] = "buff spell ids learned: " .. (#names > 0 and table.concat(names, ", ") or "none yet (learned the first time a totem's buff can be read)")
	return out
end
