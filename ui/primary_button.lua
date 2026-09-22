-- Fit PrettyUI's gold button to its content instead of its wide default endcaps.
local PrimaryButton = {}

function PrimaryButton.fit(button, text, spriteID)
    local textWidth = math.ceil(config.Font.CINZEL_13PT_BOLD:GetStringWidth(text, false))
    local iconSpace = spriteID and 24 or 0 -- 18px icon + 6px gap
    local width = textWidth + iconSpace + 24 -- 12px padding on each side
    button.root:SetSize(width, 28)
    button.left:SetSize(25, 28)
    button.middle.isTiling = false
    button.middle:SetSize(-50, 28, 1.0)
    button.right:SetSize(25, 28)
    button.label:SetPos(12 + iconSpace, 0)
    button.label:SetSize(textWidth, 28)
    if spriteID then
        local icon = ui.Sprite.new(button.root)
        icon.spriteID = spriteID
        icon:SetSize(18, 18)
        icon:SetPos(12, 5)
        icon.clickthrough = true
    end
    return width
end

return PrimaryButton
