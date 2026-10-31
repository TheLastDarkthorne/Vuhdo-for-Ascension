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
local VUHDO_COA_BROADCAST_DELAY = 3;

local VUHDO_COA_REPORTED_SPECS = { }; -- name -> spec ID, sent by that player's VuhDo
local VUHDO_COA_INSPECTED_SPECS = { }; -- name -> spec ID, from an inspect or a passive aura
local VUHDO_COA_INSPECT_TIMES = { }; -- name -> time of the last inspect attempt
local VUHDO_COA_SPECS_BY_CLASS = { };

local sPending = nil; -- { name, guid, unit, time } of our open inspect request
local sBroadcastAt = nil;
local sKnownNames = { };

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

	local tIsOk, tInfo = pcall(C_ClassInfo.GetSpecInfoByID, aSpecId);
	if (tIsOk and type(tInfo) == "table") then
		return tInfo;
	end

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
local function VUHDO_getOwnCoaSpecId()
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



-- After a successful inspect: which spec's passive does the unit know?
local function VUHDO_readInspectedCoaSpec(aUnit, aClass)
	local tIsOk, tActive, tUnlocked = pcall(C_CharacterAdvancement.GetInspectInfo, aUnit);
	if (not tIsOk) then
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



--
function VUHDO_coaResetSpecs()
	twipe(VUHDO_COA_INSPECTED_SPECS);
	twipe(VUHDO_COA_INSPECT_TIMES);
	sPending = nil;
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
		local tWait = VUHDO_COA_INSPECTED_SPECS[tName] ~= nil and VUHDO_COA_INSPECT_REFRESH or VUHDO_COA_INSPECT_RETRY;
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
		return;
	end

	local _, tClass = UnitClass(tUnit);
	local tSpecId = VUHDO_readInspectedCoaSpec(tUnit, tClass);
	if (tSpecId ~= nil) then
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

	if (not VUHDO_VARIABLES_LOADED) then
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
		if (VUHDO_VARIABLES_LOADED) then
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
