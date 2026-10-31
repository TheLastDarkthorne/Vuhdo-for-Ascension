-- Options > Buffs > Custom: add and remove buffs to track by spell name or ID.
-- The list itself is kept by VuhDoCustomBuffs.lua in the core addon.

VUHDO_CUSTOM_BUFF_TARGET = VUHDO_BUFF_TARGET_SINGLE;
VUHDO_CUSTOM_BUFF_SELECTED = nil;

VUHDO_CUSTOM_BUFF_TARGET_COMBO = {
	{ VUHDO_BUFF_TARGET_SELF, VUHDO_I18N_CUSTOM_BUFF_TARGET_SELF },
	{ VUHDO_BUFF_TARGET_SINGLE, VUHDO_I18N_CUSTOM_BUFF_TARGET_SINGLE },
	{ VUHDO_BUFF_TARGET_UNIQUE, VUHDO_I18N_CUSTOM_BUFF_TARGET_UNIQUE },
};

local VUHDO_TARGET_TEXTS = { };
for _, tEntry in ipairs(VUHDO_CUSTOM_BUFF_TARGET_COMBO) do
	VUHDO_TARGET_TEXTS[tEntry[1]] = tEntry[2];
end

local VUHDO_LIST_MODEL = { };



--
local function VUHDO_initCustomBuffListModel()
	table.wipe(VUHDO_LIST_MODEL);

	local tIsSelectedListed = false;
	for _, tCustomBuff in ipairs(VUHDO_getCustomBuffs()) do
		local tText = tCustomBuff["name"];
		if (tCustomBuff["id"] ~= nil) then
			tText = tText .. " (" .. tCustomBuff["id"] .. ")";
		end
		tText = tText .. " - " .. (VUHDO_TARGET_TEXTS[tCustomBuff["target"]] or "");

		tinsert(VUHDO_LIST_MODEL, { tCustomBuff["name"], tText });
		if (tCustomBuff["name"] == VUHDO_CUSTOM_BUFF_SELECTED) then
			tIsSelectedListed = true;
		end
	end

	if (not tIsSelectedListed) then
		VUHDO_CUSTOM_BUFF_SELECTED = nil;
	end
end



--
local function VUHDO_refreshCustomBuffList()
	local tComboBox = VuhDoNewOptionsBuffsCustomListPanelSelectComboBox;
	if (tComboBox ~= nil and tComboBox:IsVisible()) then
		tComboBox:Hide();
		tComboBox:Show();
	end
end



--
function VUHDO_setupCustomBuffsComboModel(aComboBox)
	VUHDO_initCustomBuffListModel();
	VUHDO_setComboModel(aComboBox, "VUHDO_CUSTOM_BUFF_SELECTED", VUHDO_LIST_MODEL);
	VUHDO_lnfComboBoxInitFromModel(aComboBox);
end



-- Picking a listed buff fills the add panel, so its target type can be changed with Add
function VUHDO_customBuffListSelected(aComboBox, aValue)
	for _, tCustomBuff in ipairs(VUHDO_getCustomBuffs()) do
		if (tCustomBuff["name"] == aValue) then
			VuhDoNewOptionsBuffsCustomAddPanelSpellEditBox:SetText(tCustomBuff["name"]);
			VUHDO_CUSTOM_BUFF_TARGET = tCustomBuff["target"];
			VUHDO_lnfComboBoxInitFromModel(VuhDoNewOptionsBuffsCustomAddPanelTargetComboBox);
			return;
		end
	end
end



--
function VUHDO_customBuffAddClicked(aPanel)
	local tEditBox = VUHDO_GLOBAL[aPanel:GetName() .. "SpellEditBox"];
	local tIsAdded, tMessage = VUHDO_addCustomBuff(tEditBox:GetText(), VUHDO_CUSTOM_BUFF_TARGET);

	if (tIsAdded) then
		VUHDO_Msg(tMessage);
		VUHDO_CUSTOM_BUFF_SELECTED = (VUHDO_resolveCustomBuffSpell(tEditBox:GetText()));
		tEditBox:SetText("");
		tEditBox:ClearFocus();
		VUHDO_refreshCustomBuffList();
	else
		VUHDO_Msg(tMessage, 1, 0.4, 0.4);
	end
end



--
function VUHDO_customBuffRemoveClicked()
	if (VUHDO_CUSTOM_BUFF_SELECTED == nil) then
		return;
	end

	if (VUHDO_removeCustomBuff(VUHDO_CUSTOM_BUFF_SELECTED)) then
		VUHDO_Msg(format(VUHDO_I18N_CUSTOM_BUFF_REMOVED, VUHDO_CUSTOM_BUFF_SELECTED));
		VUHDO_CUSTOM_BUFF_SELECTED = nil;
		VUHDO_refreshCustomBuffList();
	end
end
