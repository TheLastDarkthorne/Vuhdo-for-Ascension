-- Custom buffs the player adds under Options > Buffs > Custom.
-- They are stored per character in VUHDO_BUFF_SETTINGS["CUSTOM_BUFFS"] and merged into
-- VUHDO_CLASS_BUFFS[<player class>] as one category each, so the buff watch panel, the
-- missing buff colors and the Config sub tab treat them like the built-in class buffs.
-- This also gives classes VuhDo has no buff list for (the Conquest of Azeroth classes)
-- a working buff tab.

local pairs = pairs;
local ipairs = ipairs;
local tinsert = tinsert;
local tremove = tremove;
local twipe = table.wipe;
local tsort = table.sort;
local strsub = strsub;
local format = format;
local tonumber = tonumber;

local next = next;

-- Category specs this file has put into VUHDO_CLASS_BUFFS, so they can be taken out again
local VUHDO_INJECTED_SPECS = { };
-- Whether VUHDO_CLASS_BUFFS had no table for the player's class until a custom buff was added
local VUHDO_IS_CLASS_TABLE_CREATED = false;

-- Target types a custom buff can use, in the order the options list them. With a single
-- spell per buff, "raid" and "own group" would only repeat "single": all of them check the
-- group, and the Config filter already narrows "single" down to the own group, tanks etc.
VUHDO_CUSTOM_BUFF_TARGETS = {
	VUHDO_BUFF_TARGET_SELF,
	VUHDO_BUFF_TARGET_SINGLE,
	VUHDO_BUFF_TARGET_UNIQUE,
};

local VUHDO_IS_CUSTOM_BUFF_TARGET = { };
for _, tTarget in ipairs(VUHDO_CUSTOM_BUFF_TARGETS) do
	VUHDO_IS_CUSTOM_BUFF_TARGET[tTarget] = true;
end



--
function VUHDO_getCustomBuffs()
	if (VUHDO_BUFF_SETTINGS["CUSTOM_BUFFS"] == nil) then
		VUHDO_BUFF_SETTINGS["CUSTOM_BUFFS"] = { };
	end

	return VUHDO_BUFF_SETTINGS["CUSTOM_BUFFS"];
end



-- Turns user input into a spell name: a spell ID ("48066"), a spell link or a name.
-- Returns the name (nil for an unknown ID) and the ID when one was given.
function VUHDO_resolveCustomBuffSpell(aText)
	local tText = strtrim(aText or "");
	if (tText == "") then
		return nil, nil;
	end

	local tId = tonumber(tText) or tonumber(strmatch(tText, "|Hspell:(%d+)") or "");
	if (tId ~= nil) then
		return GetSpellInfo(tId), tId;
	end

	-- GetSpellInfo(name) only answers for spells the player knows, but keep the
	-- typed name either way: the spell may be learned later
	return GetSpellInfo(tText) or tText, nil;
end



--
local function VUHDO_getCustomBuffIndex(aSpellName)
	for tIndex, tCustomBuff in ipairs(VUHDO_getCustomBuffs()) do
		if (tCustomBuff["name"] == aSpellName) then
			return tIndex;
		end
	end

	return nil;
end



-- True if a built-in category of the player's class already tracks this spell
local function VUHDO_isBuiltInClassBuff(aSpellName)
	local tClassBuffs = VUHDO_CLASS_BUFFS[VUHDO_PLAYER_CLASS];
	if (tClassBuffs == nil) then
		return false;
	end

	for tCategSpec, tCategBuffs in pairs(tClassBuffs) do
		if (not VUHDO_INJECTED_SPECS[tCategSpec]) then
			if (strsub(tCategSpec, 3) == aSpellName) then
				return true;
			end

			for _, tBuffVariants in pairs(tCategBuffs) do
				for _, tVariant in pairs(tBuffVariants) do
					if (tVariant[1] == aSpellName) then
						return true;
					end
				end
			end
		end
	end

	return false;
end



-- Rebuilds the custom categories inside VUHDO_CLASS_BUFFS[VUHDO_PLAYER_CLASS]
function VUHDO_initCustomBuffs()
	if (VUHDO_PLAYER_CLASS == nil or VUHDO_BUFF_SETTINGS == nil) then
		return;
	end

	local tClassBuffs = VUHDO_CLASS_BUFFS[VUHDO_PLAYER_CLASS];

	for tCategSpec, _ in pairs(VUHDO_INJECTED_SPECS) do
		if (tClassBuffs ~= nil) then
			tClassBuffs[tCategSpec] = nil;
		end
	end
	twipe(VUHDO_INJECTED_SPECS);

	-- A class without built-in buffs goes back to having no buff list at all
	if (VUHDO_IS_CLASS_TABLE_CREATED and tClassBuffs ~= nil and next(tClassBuffs) == nil) then
		VUHDO_CLASS_BUFFS[VUHDO_PLAYER_CLASS] = nil;
		tClassBuffs = nil;
		VUHDO_IS_CLASS_TABLE_CREATED = false;
	end

	local tCustomBuffs = VUHDO_getCustomBuffs();
	if (#tCustomBuffs == 0) then
		return;
	end

	if (tClassBuffs == nil) then
		tClassBuffs = { };
		VUHDO_CLASS_BUFFS[VUHDO_PLAYER_CLASS] = tClassBuffs;
		VUHDO_IS_CLASS_TABLE_CREATED = true;
	end

	-- Numbers in use by built-in categories; custom ones keep the slot they got when added
	local tUsedSlots = { };
	for tCategSpec, _ in pairs(tClassBuffs) do
		tUsedSlots[tonumber(strsub(tCategSpec, 1, 2)) or 0] = true;
	end

	for _, tCustomBuff in ipairs(tCustomBuffs) do
		local tName = tCustomBuff["name"];

		if (tName ~= nil and tName ~= "" and not VUHDO_isBuiltInClassBuff(tName)) then
			if (not VUHDO_IS_CUSTOM_BUFF_TARGET[tCustomBuff["target"]]) then
				-- Buffs saved with the former "your party" choice keep watching only the own group
				if (VUHDO_BUFF_TARGET_OWN_GROUP == tCustomBuff["target"] and VUHDO_BUFF_SETTINGS[tName] ~= nil) then
					VUHDO_BUFF_SETTINGS[tName]["filter"] = { [VUHDO_ID_GROUP_OWN] = true };
				end
				tCustomBuff["target"] = VUHDO_BUFF_TARGET_SINGLE;
			end

			local tSlot = tCustomBuff["slot"];
			if (tSlot == nil or tUsedSlots[tSlot]) then
				tSlot = nil;
				for tCnt = 1, 99 do
					if (not tUsedSlots[tCnt]) then
						tSlot = tCnt;
						break;
					end
				end
				tCustomBuff["slot"] = tSlot;
			end

			if (tSlot ~= nil) then
				tUsedSlots[tSlot] = true;
				local tCategSpec = format("%02d%s", tSlot, tName);
				tClassBuffs[tCategSpec] = { { { tName, tCustomBuff["target"] } } };
				VUHDO_INJECTED_SPECS[tCategSpec] = true;
			end
		end
	end

	-- A buff added just now goes after everything already listed, whatever its slot number
	if (VUHDO_BUFF_ORDER ~= nil) then
		local tMaxOrder = 0;
		for tCategSpec, _ in pairs(tClassBuffs) do
			local tOrder = VUHDO_BUFF_ORDER[tCategSpec];
			if (tOrder == nil and not VUHDO_INJECTED_SPECS[tCategSpec]) then
				tOrder = tonumber(strsub(tCategSpec, 1, 2));
			end
			if ((tOrder or 0) > tMaxOrder) then
				tMaxOrder = tOrder;
			end
		end

		for _, tCustomBuff in ipairs(tCustomBuffs) do
			if (tCustomBuff["slot"] ~= nil) then
				local tCategSpec = format("%02d%s", tCustomBuff["slot"], tCustomBuff["name"]);
				if (VUHDO_INJECTED_SPECS[tCategSpec] and VUHDO_BUFF_ORDER[tCategSpec] == nil) then
					tMaxOrder = tMaxOrder + 1;
					VUHDO_BUFF_ORDER[tCategSpec] = tMaxOrder;
				end
			end
		end
	end
end



-- The buff panel and the Config tab only draw categories numbered 1, 2, 3...
-- without gaps, so renumber after categories were added or removed.
function VUHDO_normalizeBuffOrder()
	local tAllBuffs = VUHDO_CLASS_BUFFS[VUHDO_PLAYER_CLASS];
	if (tAllBuffs == nil or VUHDO_BUFF_ORDER == nil) then
		return;
	end

	local tSpecs = { };
	for tCategSpec, _ in pairs(tAllBuffs) do
		tinsert(tSpecs, tCategSpec);
	end

	local tOrderOf = { };
	for _, tCategSpec in ipairs(tSpecs) do
		tOrderOf[tCategSpec] = VUHDO_BUFF_ORDER[tCategSpec] or tonumber(strsub(tCategSpec, 1, 2)) or 99;
	end

	tsort(tSpecs,
		function(aSpec, anotherSpec)
			if (tOrderOf[aSpec] ~= tOrderOf[anotherSpec]) then
				return tOrderOf[aSpec] < tOrderOf[anotherSpec];
			end
			return aSpec < anotherSpec;
		end
	);

	for tCategSpec, _ in pairs(VUHDO_BUFF_ORDER) do
		if (tAllBuffs[tCategSpec] == nil) then
			VUHDO_BUFF_ORDER[tCategSpec] = nil;
		end
	end

	for tIndex, tCategSpec in ipairs(tSpecs) do
		VUHDO_BUFF_ORDER[tCategSpec] = tIndex;
	end
end



-- Rescans the spellbook and redraws the buff panel
local function VUHDO_reloadCustomBuffs()
	if (VUHDO_isVariablesLoaded()) then
		VUHDO_initBuffs();
		VUHDO_updateBuffFilters();
	end
end



-- Returns success and a message for the chat frame
function VUHDO_addCustomBuff(aText, aTarget)
	local tName, tId = VUHDO_resolveCustomBuffSpell(aText);

	if (tName == nil) then
		if (tId ~= nil) then
			return false, format(VUHDO_I18N_CUSTOM_BUFF_NO_SPELL_ID, tId);
		end
		return false, VUHDO_I18N_CUSTOM_BUFF_EMPTY;
	end

	if (VUHDO_isBuiltInClassBuff(tName)) then
		return false, format(VUHDO_I18N_CUSTOM_BUFF_BUILT_IN, tName);
	end

	if (not VUHDO_IS_CUSTOM_BUFF_TARGET[aTarget]) then
		aTarget = VUHDO_BUFF_TARGET_SINGLE;
	end

	local tIndex = VUHDO_getCustomBuffIndex(tName);
	local tMessage;
	if (tIndex ~= nil) then
		VUHDO_getCustomBuffs()[tIndex]["target"] = aTarget;
		tMessage = format(VUHDO_I18N_CUSTOM_BUFF_UPDATED, tName);
	else
		tinsert(VUHDO_getCustomBuffs(), { ["name"] = tName, ["id"] = tId, ["target"] = aTarget });
		tMessage = format(VUHDO_I18N_CUSTOM_BUFF_ADDED, tName);
	end

	-- Start from fresh settings so a changed target type gets matching defaults
	VUHDO_BUFF_SETTINGS[tName] = nil;
	VUHDO_initBuffSettings();

	if (VUHDO_BUFF_SETTINGS[tName] ~= nil) then
		VUHDO_BUFF_SETTINGS[tName]["enabled"] = true;
		if (VUHDO_BUFF_TARGET_UNIQUE == aTarget) then
			VUHDO_BUFF_SETTINGS[tName]["name"] = VUHDO_PLAYER_NAME;
		end
	end

	VUHDO_reloadCustomBuffs();

	if (VUHDO_BUFFS[tName] == nil or not VUHDO_BUFFS[tName]["present"]) then
		tMessage = tMessage .. " " .. format(VUHDO_I18N_CUSTOM_BUFF_NOT_KNOWN, tName);
	end

	return true, tMessage;
end



--
function VUHDO_removeCustomBuff(aSpellName)
	local tIndex = VUHDO_getCustomBuffIndex(aSpellName);
	if (tIndex == nil) then
		return false;
	end

	tremove(VUHDO_getCustomBuffs(), tIndex);
	VUHDO_BUFF_SETTINGS[aSpellName] = nil;
	VUHDO_initBuffSettings();
	VUHDO_reloadCustomBuffs();
	return true;
end
