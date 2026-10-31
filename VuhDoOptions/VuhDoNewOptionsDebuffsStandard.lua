
VUHDO_DEBUFF_IGNORE_COMBO_MODEL = { };
VUHDO_SELECTED_DEBUFF_IGNORE = "";



--
function VUHDO_initDebuffIgnoreComboModel()
	local tName;
	table.wipe(VUHDO_DEBUFF_IGNORE_COMBO_MODEL);
	for tName, _ in pairs(VUHDO_DEBUFF_BLACKLIST) do
		tinsert(VUHDO_DEBUFF_IGNORE_COMBO_MODEL, { tName, tName });
	end
end



--
local tText;
function VUHDO_saveDebuffIgnoreClicked(aButton)
	local tText = VUHDO_GLOBAL[aButton:GetParent():GetName() .. "IgnoreComboBoxEditBox"]:GetText();
	if (tText ~= nil) then
		tText = strtrim(tText);
		if (tonumber(tText) ~= nil) then
			local tSpellName = GetSpellInfo(tonumber(tText));
			if (tSpellName ~= nil) then
				tText = tSpellName;
			end
		end
		VUHDO_DEBUFF_BLACKLIST[tText] = true;
		VUHDO_initDebuffIgnoreComboModel();
		VUHDO_GLOBAL[aButton:GetParent():GetName() .. "IgnoreComboBox"]:Hide();
		VUHDO_GLOBAL[aButton:GetParent():GetName() .. "IgnoreComboBox"]:Show();
	end
end



--
function VUHDO_deleteDebuffIgnoreClicked(aButton)
	local tText = VUHDO_GLOBAL[aButton:GetParent():GetName() .. "IgnoreComboBoxEditBox"]:GetText();
	if (tText ~= nil) then
		tText = strtrim(tText);
		if (tonumber(tText) ~= nil) then
			local tSpellName = GetSpellInfo(tonumber(tText));
			if (tSpellName ~= nil) then
				tText = tSpellName;
			end
		end
		VUHDO_DEBUFF_BLACKLIST[tText] = nil;
		VUHDO_initDebuffIgnoreComboModel();
		VUHDO_GLOBAL[aButton:GetParent():GetName() .. "IgnoreComboBox"]:Hide();
		VUHDO_GLOBAL[aButton:GetParent():GetName() .. "IgnoreComboBox"]:Show();
	end
end