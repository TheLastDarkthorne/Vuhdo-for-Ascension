-- Conquest of Azeroth: roles of the custom classes, read from the client's spec data.
-- A spec marked Tank or Healer keeps that role; a spec marked Support goes to Support
-- before damage. Stock classes and Hero are left to VuhDo's usual role checks.
-- Specs come from the player's own client, from other VuhDo users (addon messages)
-- and from inspecting group members. Everything is skipped on clients without the
-- CoA spec API, such as a stock 3.3.5a client.

local VUHDO_COA_PREFIX = "VD_COA";
local VUHDO_COA_INSPECT_INTERVAL = 2;
local VUHDO_COA_INSPECT_TIMEOUT = 5;
local VUHDO_COA_INSPECT_REFRESH = 300;
local VUHDO_COA_INSPECT_RETRY = 30;
local VUHDO_COA_INSPECT_MAX_RETRY = 600;
local VUHDO_COA_OWN_SPEC_SECS = 5;
local VUHDO_COA_BROADCAST_DELAY = 3;

local VUHDO_COA_REPORTED_SPECS = { }; -- name -> spec ID, sent by that player's VuhDo
local VUHDO_COA_INSPECTED_SPECS = { }; -- name -> spec ID, from an inspect or a passive aura
local VUHDO_COA_INSPECT_TIMES = { }; -- name -> time of the last inspect attempt
local VUHDO_COA_INSPECT_TRIES = { }; -- name -> inspects since the last one that found a spec
local VUHDO_COA_SPECS_BY_CLASS = { };
local VUHDO_COA_LAST_INSPECTS = { }; -- name -> text about the last inspect, for /vd specs
local VUHDO_COA_SPEC_INFOS = { }; -- spec ID -> info, false if unknown. The client's lookup scans every class's specs and builds new tables each call

local sPending = nil; -- { name, guid, unit, time } of our open inspect request
local sBroadcastAt = nil;
local sKnownNames = { };
local sOwnSpecId = nil;
local sOwnSpecTime = nil;

local twipe = table.wipe;
local pcall = pcall;
local type = type;
local pairs = pairs;
local ipairs = ipairs;
local tonumber = tonumber;



--
local function VUHDO_isCoaSpecApi()
	return type(C_ClassInfo) == "table" and type(C_ClassInfo.GetSpecInfoByID) == "function"
		and type(C_ClassInfo.GetAllSpecs) == "function" and type(C_ClassInfo.GetSpecInfo) == "function"
		and type(IsCustomClass) == "function";
end



--
local function VUHDO_isCoaInspectApi()
	return type(C_CharacterAdvancement) == "table"
		and type(C_CharacterAdvancement.InspectUnit) == "function"
		and type(C_CharacterAdvancement.GetInspectInfo) == "function"
		and type(C_CharacterAdvancement.UnitKnownID) == "function";
end



-- Custom CoA class (not stock, not Hero)?
function VUHDO_isCoaCustomClassUnit(aUnit)
	if (not VUHDO_isCoaSpecApi() or aUnit == nil) then
		return false;
	end

	local tIsOk, tIsCustom = pcall(IsCustomClass, aUnit);
	if (not tIsOk or not tIsCustom) then
		return false;
	end

	if (type(IsHeroClass) == "function") then
		local tIsHeroOk, tIsHero = pcall(IsHeroClass, aUnit);
		if (tIsHeroOk and tIsHero) then
			return false;
		end
	end

	return true;
end



--
local function VUHDO_getCoaSpecInfo(aSpecId)
	if (aSpecId == nil or not VUHDO_isCoaSpecApi()) then
		return nil;
	end

	local tCached = VUHDO_COA_SPEC_INFOS[aSpecId];
	if (tCached ~= nil) then
		return tCached or nil;
	end

	local tIsOk, tInfo = pcall(C_ClassInfo.GetSpecInfoByID, aSpecId);
	if (not tIsOk) then
		return nil;
	end

	if (type(tInfo) == "table") then
		VUHDO_COA_SPEC_INFOS[aSpecId] = tInfo;
		return tInfo;
	end

	VUHDO_COA_SPEC_INFOS[aSpecId] = false;
	return nil;
end



--
local function VUHDO_getCoaClassSpecs(aClass)
	if (aClass == nil) then
		return { };
	end

	if (VUHDO_COA_SPECS_BY_CLASS[aClass] == nil) then
		local tSpecs = { };
		local tIsOk, tTokens = pcall(C_ClassInfo.GetAllSpecs, aClass);
		if (tIsOk and type(tTokens) == "table") then
			for _, tToken in ipairs(tTokens) do
				local tIsInfoOk, tInfo = pcall(C_ClassInfo.GetSpecInfo, aClass, tToken);
				if (tIsInfoOk and type(tInfo) == "table" and tInfo["ID"] ~= nil) then
					tInfo["vuhdoToken"] = strupper(tostring(tToken));
					tinsert(tSpecs, tInfo);
				end
			end
		end
		VUHDO_COA_SPECS_BY_CLASS[aClass] = tSpecs;
	end

	return VUHDO_COA_SPECS_BY_CLASS[aClass];
end



-- Tank and Healer keep their role, Support comes before damage
function VUHDO_getCoaRoleForSpec(aSpecId)
	local tInfo = VUHDO_getCoaSpecInfo(aSpecId);
	if (tInfo == nil) then
		return nil;
	elseif (tInfo["Tank"]) then
		return VUHDO_ID_MELEE_TANK;
	elseif (tInfo["Healer"]) then
		return VUHDO_ID_RANGED_HEAL;
	elseif (tInfo["Support"]) then
		return VUHDO_ID_SUPPORT;
	elseif (tInfo["MeleeDPS"]) then
		return VUHDO_ID_MELEE_DAMAGE;
	elseif (tInfo["RangedDPS"] or tInfo["CasterDPS"]) then
		return VUHDO_ID_RANGED_DAMAGE;
	end

	return nil;
end



--
local function VUHDO_readOwnCoaSpecId()
	if (type(C_CharacterAdvancement) == "table" and type(C_CharacterAdvancement.GetActiveChrSpec) == "function") then
		local tIsOk, tSpecId = pcall(C_CharacterAdvancement.GetActiveChrSpec);
		if (tIsOk and VUHDO_getCoaSpecInfo(tSpecId) ~= nil) then
			return tSpecId;
		end
	end

	if (type(GetSpecialization) == "function") then
		local tIsOk, tSpecId = pcall(GetSpecialization);
		if (tIsOk and tSpecId ~= 0 and VUHDO_getCoaSpecInfo(tSpecId) ~= nil) then
			return tSpecId;
		end
	end

	return nil;
end



-- GetSpecialization builds spec tables too, so read at most every few seconds
local function VUHDO_getOwnCoaSpecId()
	local tNow = GetTime();
	if (sOwnSpecTime == nil or tNow - sOwnSpecTime >= VUHDO_COA_OWN_SPEC_SECS) then
		sOwnSpecId = VUHDO_readOwnCoaSpecId();
		sOwnSpecTime = tNow;
	end

	return sOwnSpecId;
end



-- The level 10 passive of each spec, as a buff name, if it shows as an aura
local function VUHDO_getCoaSpecFromAuras(aUnit, aClass)
	local tFound = nil;
	for _, tInfo in ipairs(VUHDO_getCoaClassSpecs(aClass)) do
		local tPassive = tInfo["PassiveID"];
		local tName = tPassive ~= nil and GetSpellInfo(tPassive) or nil;
		if (tName ~= nil and UnitBuff(aUnit, tName) ~= nil) then
			if (tFound ~= nil) then
				return nil; -- ambiguous
			end
			tFound = tInfo["ID"];
		end
	end

	return tFound;
end



-- The spec whose tree holds most of the known talents, or whose passive is known
local function VUHDO_getCoaSpecFromBuild(aUnit, aClass, aBuild)
	local tGetBuild = C_CharacterAdvancement.GetInspectedBuild;
	local tGetEntry = C_CharacterAdvancement.GetEntryByInternalID;
	if (type(tGetBuild) ~= "function" or type(tGetEntry) ~= "function") then
		return nil, 0;
	end

	local tIsOk, tEntries = pcall(tGetBuild, aUnit, aBuild);
	if (not tIsOk or type(tEntries) ~= "table") then
		return nil, 0;
	end

	local tSpecs = VUHDO_getCoaClassSpecs(aClass);
	local tCounts = { };
	for _, tKnown in ipairs(tEntries) do
		local tEntryId = tKnown["EntryId"];
		for _, tInfo in ipairs(tSpecs) do
			if (tEntryId ~= nil and tInfo["PassiveID"] == tEntryId) then
				return tInfo["ID"], #tEntries;
			end
		end

		local tIsEntryOk, tEntry = pcall(tGetEntry, tEntryId);
		if (tIsEntryOk and type(tEntry) == "table" and tEntry["Tab"] ~= nil) then
			local tTab = strupper(tostring(tEntry["Tab"]));
			tCounts[tTab] = (tCounts[tTab] or 0) + 1;
		end
	end

	local tBest, tBestCount, tIsTie = nil, 0, false;
	for _, tInfo in ipairs(tSpecs) do
		local tCount = tCounts[tInfo["vuhdoToken"]] or 0;
		if (tCount > tBestCount) then
			tBest, tBestCount, tIsTie = tInfo["ID"], tCount, false;
		elseif (tCount > 0 and tCount == tBestCount) then
			tIsTie = true;
		end
	end

	return (not tIsTie) and tBest or nil, #tEntries;
end



-- After a successful inspect: which spec does the unit play?
local function VUHDO_readInspectedCoaSpec(aUnit, aClass, aName)
	local tIsOk, tActive, tUnlocked = pcall(C_CharacterAdvancement.GetInspectInfo, aUnit);
	if (not tIsOk) then
		VUHDO_COA_LAST_INSPECTS[aName] = "GetInspectInfo failed";
		return nil;
	end

	-- The client's own code passes either the build index or its unlocked spec ID
	local tBuilds = { };
	if (tActive ~= nil) then
		tinsert(tBuilds, tActive);
		if (type(tUnlocked) == "table" and tUnlocked[tActive] ~= nil and tUnlocked[tActive] ~= tActive) then
			tinsert(tBuilds, tUnlocked[tActive]);
		end
	end
	if (tActive == nil or tActive == 0) then
		tinsert(tBuilds, 1); -- the client's window falls back to the first build
	end

	local tNumEntries = 0;
	for _, tBuild in ipairs(tBuilds) do
		local tSpecId, tCount = VUHDO_getCoaSpecFromBuild(aUnit, aClass, tBuild);
		tNumEntries = tNumEntries + tCount;
		if (tSpecId ~= nil) then
			VUHDO_COA_LAST_INSPECTS[aName] = "found from build " .. tBuild;
			return tSpecId;
		end
	end
	VUHDO_COA_LAST_INSPECTS[aName] = "no spec in " .. tNumEntries .. " entries, active build " .. tostring(tActive);

	local tGetEntry = C_CharacterAdvancement.GetEntryBySpellID;
	for _, tBuild in ipairs(tBuilds) do
		local tFound = nil;
		for _, tInfo in ipairs(VUHDO_getCoaClassSpecs(aClass)) do
			local tIds = { tInfo["PassiveID"] };
			if (type(tGetEntry) == "function" and tInfo["PassiveID"] ~= nil) then
				local tIsEntryOk, tEntry = pcall(tGetEntry, tInfo["PassiveID"]);
				if (tIsEntryOk and type(tEntry) == "table" and tEntry["ID"] ~= nil) then
					tinsert(tIds, tEntry["ID"]);
				end
			end

			for _, tId in ipairs(tIds) do
				local tIsKnownOk, tIsKnown = pcall(C_CharacterAdvancement.UnitKnownID, aUnit, tId, tBuild);
				if (tIsKnownOk and tIsKnown) then
					if (tFound ~= nil and tFound ~= tInfo["ID"]) then
						tFound = false; -- more than one spec matched, this reading can't be trusted
					elseif (tFound == nil) then
						tFound = tInfo["ID"];
					end
					break;
				end
			end
		end

		if (tFound) then
			VUHDO_COA_LAST_INSPECTS[aName] = "found from passive, build " .. tBuild;
			return tFound;
		end
	end

	return nil;
end



--
local function VUHDO_setCoaSpec(aTable, aName, aSpecId)
	if (aName == nil or aTable[aName] == aSpecId) then
		return;
	end

	aTable[aName] = aSpecId;
	VUHDO_normalRaidReload();
end



-- Role of a custom class unit, nil if unknown or not a CoA custom class
function CoA_Determine_Role(anInfo)
	local tUnit = anInfo["unit"];
	if (not VUHDO_isCoaCustomClassUnit(tUnit)) then
		return nil;
	end

	local tName = anInfo["name"];
	local tSpecId;
	if (UnitIsUnit(tUnit, "player")) then
		tSpecId = VUHDO_getOwnCoaSpecId();
	else
		tSpecId = VUHDO_COA_REPORTED_SPECS[tName] or VUHDO_COA_INSPECTED_SPECS[tName];
		if (tSpecId == nil) then
			local _, tClass = UnitClass(tUnit);
			tSpecId = VUHDO_getCoaSpecFromAuras(tUnit, tClass);
			VUHDO_COA_INSPECTED_SPECS[tName] = tSpecId;
		end
	end

	return VUHDO_getCoaRoleForSpec(tSpecId);
end



-- Does this client have the CoA classes?
function VUHDO_isCoaClient()
	return VUHDO_isCoaSpecApi();
end



-- /vd specs: what role detection knows about each group member
function VUHDO_coaPrintSpecs()
	if (not VUHDO_isCoaSpecApi()) then
		VUHDO_Msg("This client has no Conquest of Azeroth spec data.");
		return;
	end

	for tUnit, tInfo in pairs(VUHDO_RAID) do
		if (not tInfo["isPet"] and tUnit ~= "target" and tUnit ~= "focus") then
			local tName = tInfo["name"];
			local tSpecId, tSource;
			if (UnitIsUnit(tUnit, "player")) then
				tSpecId, tSource = VUHDO_getOwnCoaSpecId(), "own client";
			elseif (VUHDO_COA_REPORTED_SPECS[tName] ~= nil) then
				tSpecId, tSource = VUHDO_COA_REPORTED_SPECS[tName], "their VuhDo";
			elseif (VUHDO_COA_INSPECTED_SPECS[tName] ~= nil) then
				tSpecId, tSource = VUHDO_COA_INSPECTED_SPECS[tName], "inspect";
			else
				tSource = "unknown";
			end

			local tSpecInfo = VUHDO_getCoaSpecInfo(tSpecId);
			local _, tClass = UnitClass(tUnit);
			VUHDO_Msg(tostring(tName) .. " (" .. tostring(tClass) .. "): role " .. tostring(tInfo["role"])
				.. ", spec " .. tostring(tSpecInfo and tSpecInfo["Name"]) .. " from " .. tSource
				.. ", inspects " .. tostring(VUHDO_COA_INSPECT_TRIES[tName] or 0)
				.. ", last: " .. tostring(VUHDO_COA_LAST_INSPECTS[tName] or "none"));
		end
	end

	if (not VUHDO_isCoaInspectApi()) then
		VUHDO_Msg("This client has no inspect functions.");
	elseif (not VUHDO_CONFIG["IS_SCAN_TALENTS"]) then
		VUHDO_Msg("Inspecting is off: the talent Scan option under General > Scan.");
	end
end



--
function VUHDO_coaResetSpecs()
	twipe(VUHDO_COA_INSPECTED_SPECS);
	twipe(VUHDO_COA_INSPECT_TIMES);
	twipe(VUHDO_COA_INSPECT_TRIES);
	sPending = nil;
	sOwnSpecTime = nil;
end



--
local function VUHDO_broadcastCoaSpec()
	if (not VUHDO_isCoaCustomClassUnit("player")) then
		return;
	end

	if (GetNumRaidMembers() == 0 and GetNumPartyMembers() == 0) then
		return;
	end

	local tSpecId = VUHDO_getOwnCoaSpecId();
	if (tSpecId ~= nil) then
		SendAddonMessage(VUHDO_COA_PREFIX, "SPEC " .. tSpecId, VUHDO_getAddOnDistribution());
	end
end



--
local function VUHDO_scheduleCoaBroadcast()
	sBroadcastAt = GetTime() + VUHDO_COA_BROADCAST_DELAY;
end



-- Rebroadcast when somebody new joins, so they learn our spec
local function VUHDO_coaRosterChanged()
	local tIsNew = false;
	local tNames = { };
	for tName, _ in pairs(VUHDO_RAID_NAMES or { }) do
		tNames[tName] = true;
		if (not sKnownNames[tName]) then
			tIsNew = true;
		end
	end
	sKnownNames = tNames;

	if (tIsNew) then
		VUHDO_scheduleCoaBroadcast();
	end
end



--
local function VUHDO_parseCoaMessage(aMessage, aSender)
	if (aSender == nil or aSender == UnitName("player")) then
		return;
	end

	local tSpecId = tonumber(strmatch(aMessage or "", "^SPEC (%d+)$"));
	if (tSpecId ~= nil and VUHDO_getCoaSpecInfo(tSpecId) ~= nil) then
		VUHDO_setCoaSpec(VUHDO_COA_REPORTED_SPECS, aSender, tSpecId);
	end
end



--
local function VUHDO_shouldCoaInspect(aUnit, anInfo, aNow)
	if (anInfo == nil or anInfo["isPet"] or not anInfo["connected"]) then
		return false;
	end

	local tName = anInfo["name"];
	if (UnitIsUnit(aUnit, "player") or VUHDO_COA_REPORTED_SPECS[tName] ~= nil
		or VUHDO_MANUAL_ROLES[tName] ~= nil) then
		return false;
	end

	local tLast = VUHDO_COA_INSPECT_TIMES[tName];
	if (tLast ~= nil) then
		local tWait = VUHDO_COA_INSPECT_REFRESH;
		if (VUHDO_COA_INSPECTED_SPECS[tName] == nil) then
			-- Doubles with every inspect that doesn't find a spec
			tWait = VUHDO_COA_INSPECT_RETRY * 2 ^ ((VUHDO_COA_INSPECT_TRIES[tName] or 1) - 1);
			if (tWait > VUHDO_COA_INSPECT_MAX_RETRY) then
				tWait = VUHDO_COA_INSPECT_MAX_RETRY;
			end
		end

		if (aNow - tLast < tWait) then
			return false;
		end
	end

	return UnitIsVisible(aUnit) and UnitIsPlayer(aUnit) and VUHDO_isCoaCustomClassUnit(aUnit);
end



--
local function VUHDO_tryCoaInspect()
	local tNow = GetTime();
	if (sPending ~= nil) then
		if (tNow - sPending["time"] < VUHDO_COA_INSPECT_TIMEOUT) then
			return;
		end
		sPending = nil;
	end

	if (not VUHDO_CONFIG or not VUHDO_CONFIG["IS_SCAN_TALENTS"] or InCombatLockdown()
		or (AscensionInspectFrame ~= nil and AscensionInspectFrame:IsShown())
		or (InspectFrame ~= nil and InspectFrame:IsShown())) then
		return;
	end

	for tUnit, tInfo in pairs(VUHDO_RAID or { }) do
		if (tUnit ~= "target" and tUnit ~= "focus" and VUHDO_shouldCoaInspect(tUnit, tInfo, tNow)) then
			VUHDO_COA_INSPECT_TIMES[tInfo["name"]] = tNow;
			VUHDO_COA_INSPECT_TRIES[tInfo["name"]] = (VUHDO_COA_INSPECT_TRIES[tInfo["name"]] or 0) + 1;
			sPending = { ["name"] = tInfo["name"], ["guid"] = UnitGUID(tUnit), ["unit"] = tUnit, ["time"] = tNow };
			if (not pcall(C_CharacterAdvancement.InspectUnit, tUnit)) then
				sPending = nil;
			end
			return;
		end
	end
end



--
local function VUHDO_coaInspectResult(aResult)
	if (sPending == nil) then
		return;
	end

	local tPending = sPending;
	sPending = nil;
	local tUnit = tPending["unit"];
	if (aResult ~= "CA_INSPECT_OK" or UnitGUID(tUnit) ~= tPending["guid"]) then
		VUHDO_COA_LAST_INSPECTS[tPending["name"]] = tostring(aResult);
		return;
	end

	local _, tClass = UnitClass(tUnit);
	local tSpecId = VUHDO_readInspectedCoaSpec(tUnit, tClass, tPending["name"]);
	if (tSpecId ~= nil) then
		VUHDO_COA_INSPECT_TRIES[tPending["name"]] = nil;
		VUHDO_setCoaSpec(VUHDO_COA_INSPECTED_SPECS, tPending["name"], tSpecId);
	end
end



--
local sElapsed = 0;
local function VUHDO_coaOnUpdate(aFrame, anElapsed)
	sElapsed = sElapsed + anElapsed;
	if (sElapsed < VUHDO_COA_INSPECT_INTERVAL) then
		return;
	end
	sElapsed = 0;

	if (not VUHDO_isVariablesLoaded()) then
		return;
	end

	if (sBroadcastAt ~= nil and GetTime() >= sBroadcastAt) then
		sBroadcastAt = nil;
		VUHDO_broadcastCoaSpec();
	end

	if (VUHDO_isCoaInspectApi()) then
		VUHDO_tryCoaInspect();
	end
end



--
local function VUHDO_coaOnEvent(aFrame, anEvent, anArg1, anArg2, anArg3, anArg4)
	if ("CHAT_MSG_ADDON" == anEvent) then
		if (anArg1 == VUHDO_COA_PREFIX) then
			VUHDO_parseCoaMessage(anArg2, anArg4);
		end
	elseif ("INSPECT_CHARACTER_ADVANCEMENT_RESULT" == anEvent) then
		VUHDO_coaInspectResult(anArg1);
	elseif ("ASCENSION_CA_SPECIALIZATION_ACTIVE_ID_CHANGED" == anEvent) then
		sOwnSpecTime = nil;
		if (VUHDO_isVariablesLoaded()) then
			VUHDO_resetTalentScan("player");
			VUHDO_normalRaidReload();
		end
		VUHDO_scheduleCoaBroadcast();
	elseif ("PLAYER_ENTERING_WORLD" == anEvent) then
		VUHDO_scheduleCoaBroadcast();
	else -- PARTY_MEMBERS_CHANGED, RAID_ROSTER_UPDATE
		VUHDO_coaRosterChanged();
	end
end



-- Nothing is registered unless the client has the CoA spec API
if (VUHDO_isCoaSpecApi()) then
	local tFrame = CreateFrame("Frame");
	tFrame:SetScript("OnEvent", VUHDO_coaOnEvent);
	tFrame:SetScript("OnUpdate", VUHDO_coaOnUpdate);
	for _, tEvent in ipairs({ "CHAT_MSG_ADDON", "PLAYER_ENTERING_WORLD", "PARTY_MEMBERS_CHANGED", "RAID_ROSTER_UPDATE",
		"INSPECT_CHARACTER_ADVANCEMENT_RESULT", "ASCENSION_CA_SPECIALIZATION_ACTIVE_ID_CHANGED" }) do
		pcall(tFrame.RegisterEvent, tFrame, tEvent);
	end
end
