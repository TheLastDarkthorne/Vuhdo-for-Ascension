VUHDO_PANEL_MODELS = {};
VUHDO_PANEL_DYN_MODELS = {};

local tinsert = tinsert;
local tremove = tremove;
local twipe = table.wipe;
local ceil = ceil;
local pairs = pairs;



--
local tModelArray;
local tKeyArray;
local tCnt;
local tModelId;
function VUHDO_clearUndefinedModelEntries()
	for tKeyArray, tModelArray in pairs(VUHDO_PANEL_MODELS) do
		for tCnt = 15, 1, -1 do -- VUHDO_MAX_GROUPS_PER_PANEL
			tModelId = tModelArray[tCnt];

			if (tModelId == 0) then -- VUHDO_ID_UNDEFINED
				tremove(tModelArray, tCnt);
			end
		end
	end

	for tKeyArray, tModelArray in pairs(VUHDO_PANEL_MODELS) do
		if (tModelArray == nil or #tModelArray == 0) then
			VUHDO_PANEL_MODELS[tKeyArray] = nil;
		end
	end

end



-- Supports used to count as damage: a panel listing damage roles gets the Support group
-- once, so these players keep a bar. Removing the group afterwards in the options sticks.
function VUHDO_addSupportToModel(aModel)
	if (aModel["isSupportChecked"] or not VUHDO_isCoaClient()) then
		return;
	end
	aModel["isSupportChecked"] = true;

	local tGroups = aModel["groups"];
	if (tGroups == nil) then
		return;
	end

	local tLastRole = nil;
	for tIndex, tId in ipairs(tGroups) do
		if (tId == VUHDO_ID_SUPPORT) then
			return;
		elseif (tId == VUHDO_ID_MELEE_TANK or tId == VUHDO_ID_MELEE_DAMAGE
			or tId == VUHDO_ID_RANGED_DAMAGE or tId == VUHDO_ID_RANGED_HEAL) then
			if (tId == VUHDO_ID_MELEE_DAMAGE or tId == VUHDO_ID_RANGED_DAMAGE or tLastRole ~= nil) then
				tLastRole = tIndex;
			end
		end
	end

	if (tLastRole ~= nil) then
		tinsert(tGroups, tLastRole + 1, VUHDO_ID_SUPPORT);
	end
end



--
local tCnt;
function VUHDO_initPanelModels()
	twipe(VUHDO_PANEL_MODELS);

	for tCnt = 1, 10 do -- VUHDO_MAX_PANELS
		VUHDO_addSupportToModel(VUHDO_PANEL_SETUP[tCnt]["MODEL"]);
		VUHDO_PANEL_MODELS[tCnt] = VUHDO_PANEL_SETUP[tCnt]["MODEL"]["groups"];
	end
end



--
local tIsShowModel;
local tIsOmitEmpty;
local tPanelNum, tModelArray;
local tModelIdx, tModelId;
local tMaxRows, tNumModels, tRepeatModels;
local tCnt;
function VUHDO_initDynamicPanelModels()

	if (VUHDO_isConfigPanelShowing()) then
		VUHDO_PANEL_DYN_MODELS = VUHDO_deepCopyTable(VUHDO_PANEL_MODELS);
		return;
	end

	twipe(VUHDO_PANEL_DYN_MODELS);

	for tPanelNum, tModelArray in pairs(VUHDO_PANEL_MODELS) do
		tIsOmitEmpty = VUHDO_PANEL_SETUP[tPanelNum]["SCALING"]["ommitEmptyWhenStructured"];
		VUHDO_PANEL_DYN_MODELS[tPanelNum] = { };
		tMaxRows = VUHDO_PANEL_SETUP[tPanelNum]["SCALING"]["maxRowsWhenLoose"];

		for tModelIdx, tModelId in pairs(tModelArray) do
			tNumModels = #VUHDO_getGroupMembers(tModelId);
			if ((not tIsOmitEmpty)
				or tNumModels > 0) then

				tRepeatModels = ceil(tNumModels / tMaxRows);
				if (tRepeatModels == 0) then
					tRepeatModels = 1;
				end

				for tCnt = 1, tRepeatModels do
					tinsert(VUHDO_PANEL_DYN_MODELS[tPanelNum], tModelId);
				end
			end
		end
		
	end
end
