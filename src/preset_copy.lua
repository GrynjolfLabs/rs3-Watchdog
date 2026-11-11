-- Copies a Preset into an enabled Alert in a caller-supplied Bucket.
-- Does not save that Bucket and does not write the Preset library.

local Store = require("src/store")
local Presets = require("src/presets")
local DropDismissOn = require("src/drop_dismiss_on")
local ControlKinds = require("src/ui/control_kinds")
local Text = require("src/text")
local NumberField = require("src/ui/widgets/number_field")
local SoundEffectValue = require("src/sound_effect_value")

local PresetCopy = {}

---@param message string
local function report(message)
    if type(log) == "function" then
        log("Watchdog: " .. message)
    end
end

---@param arr Watchdog.LayoutArray|nil
---@return Watchdog.Layout
local function layoutFromArray(arr)
    local layout = {}
    for _, entry in ipairs(arr or {}) do
        if entry.id ~= nil then
            layout[entry.id] = { x = entry.x or 0, y = entry.y or 0 }
        end
    end
    return layout
end

---@param node table|nil
---@return boolean
local function isPlaceholder(node)
    if node == nil then return false end
    if node.unknown ~= nil then return true end
    local unknown = (LibNodeGraph ~= nil) and LibNodeGraph.UNKNOWN_TYPE or nil
    if unknown ~= nil and node.typeKey == unknown then return true end
    return node.typeKey == "__unknown__"
end

---@param graph LibNodeGraph.Graph
---@param nodeId integer
---@param pinName string
---@return table|nil
local function dataInPin(graph, nodeId, pinName)
    for _, pin in ipairs(graph:GetPins(nodeId) or {}) do
        if pin.name == pinName and pin.kind == "data" and pin.direction == "in" then
            return pin
        end
    end
    return nil
end

-- Answers follow stored Variable order. A blank number is not stored as 0.
-- A Sound Effect answer is already a number or a pack sound effect. A plain
-- number answer is still parsed from raw or quantity. Bake writes that value.
-- It does not branch on node type. A Matcher answer is the needle. The mode
-- already on that Control is kept.
---@param graph LibNodeGraph.Graph
---@param variables Watchdog.PresetVariable[]
---@param answers any[]
---@return string|nil err
local function bake(graph, variables, answers)
    if type(answers) ~= "table" or #answers ~= #variables then
        return "A marked control is missing."
    end
    for i, mark in ipairs(variables) do
        local node = graph.nodes[mark.nodeId]
        if node == nil or isPlaceholder(node) then
            return "A marked control is missing."
        end
        local pin = dataInPin(graph, mark.nodeId, mark.pinName)
        if pin == nil then
            return "A marked control is missing."
        end
        local widget = ControlKinds.Widget(pin.dataType)
        local answer = answers[i]
        if widget == "number" then
            if type(answer) == "number" or SoundEffectValue.isPackSoundEffect(answer) then
                graph:SetControl(mark.nodeId, mark.pinName, answer)
            else
                local raw, quantity = answer, nil
                if type(answer) == "table" then
                    raw = answer.raw
                    quantity = answer.quantity
                end
                local parsed = NumberField.Parse(raw, quantity)
                if parsed == nil then
                    return "Enter a number."
                end
                graph:SetControl(mark.nodeId, mark.pinName, parsed)
            end
        elseif widget == "text" then
            if type(answer) ~= "string" then
                return "A marked control is missing."
            end
            graph:SetControl(mark.nodeId, mark.pinName, Text.StripTags(answer))
        elseif ControlKinds.IsChoiceWidget(widget) then
            graph:SetControl(mark.nodeId, mark.pinName, answer)
        elseif widget == "matcher" then
            if type(answer) ~= "string" then
                return "A marked control is missing."
            end
            local existing = graph:GetControl(mark.nodeId, mark.pinName)
            local mode = "substring"
            if type(existing) == "table" and (existing.mode == "pattern" or existing.mode == "substring") then
                mode = existing.mode
            end
            graph:SetControl(mark.nodeId, mark.pinName, { needle = Text.StripTags(answer), mode = mode })
        else
            return "A marked control is missing."
        end
    end
    return nil
end

---@param bucket Watchdog.Bucket
---@param name string|nil
---@param graphData table|nil
---@param layoutData Watchdog.LayoutArray|nil
---@param variables Watchdog.PresetVariable[]|nil
---@param registry LibNodeGraph.Registry
---@param answers any[]|nil
---@param reportLabel any
---@return Watchdog.Entry|nil entry
---@return LibNodeGraph.Graph|nil graph
---@return Watchdog.Layout|nil layout
---@return string|nil err
local function copyGraph(bucket, name, graphData, layoutData, variables, registry, answers, reportLabel)
    local hasVariables = type(variables) == "table" and #variables > 0
    if hasVariables and answers == nil then
        return nil, nil, nil, "variables"
    end
    if LibNodeGraph == nil or LibNodeGraph.Deserialize == nil then
        return nil, nil, nil, "Could not copy the preset graph."
    end
    local ok, graph = pcall(function()
        return LibNodeGraph.Deserialize(graphData, registry, { onUnknown = "placeholder" })
    end)
    if not ok or graph == nil then
        report("could not instantiate preset " .. tostring(reportLabel) .. " - " .. tostring(graph))
        return nil, nil, nil, "Could not copy the preset graph."
    end
    if hasVariables then
        local bakeErr = bake(graph, variables, answers)
        if bakeErr ~= nil then
            return nil, nil, nil, bakeErr
        end
    end
    local layout = layoutFromArray(layoutData)
    local entry = Store.NewAlertEntry(Store.MintId(bucket), Presets.trim(name), graph, layout, true)
    if not Store.InsertEntry(bucket, entry) then
        return nil, nil, nil, "Could not create the alert."
    end
    return entry, graph, layout, nil
end

-- Empty variables keep the previous result: an enabled Alert, a new Entry id,
-- the Preset name, and the snapshot's node ids. The snapshot has no enabled flag.
---@param bucket Watchdog.Bucket
---@param presetId integer
---@param registry LibNodeGraph.Registry
---@param answers any[]|nil
---@return Watchdog.Entry|nil entry
---@return LibNodeGraph.Graph|nil graph
---@return Watchdog.Layout|nil layout
---@return string|nil err
function PresetCopy.Instantiate(bucket, presetId, registry, answers)
    if type(bucket) ~= "table" or registry == nil then
        return nil, nil, nil, "No scope to create the alert in."
    end
    local doc, err = Presets.Load()
    if doc == nil then
        return nil, nil, nil, err
    end
    local preset
    for _, candidate in ipairs(doc.presets) do
        if candidate.id == presetId then
            preset = candidate
            break
        end
    end
    if preset == nil then
        return nil, nil, nil, "Preset not found."
    end
    return copyGraph(bucket, preset.name, preset.graph, preset.layout, preset.variables, registry, answers, presetId)
end

--- Copies a captured Alert Preset into an enabled Alert in the caller's Bucket.
--- Unknown node types become placeholders. Nil answers on a snapshot that has
--- Variables writes nothing. Does not save the Bucket, mint a Preset id, or
--- keep the author id or Pack name.
---@param bucket Watchdog.Bucket
---@param snapshot Watchdog.PackAlertPreset
---@param registry LibNodeGraph.Registry
---@param answers any[]|nil
---@return Watchdog.Entry|nil entry
---@return LibNodeGraph.Graph|nil graph
---@return Watchdog.Layout|nil layout
---@return string|nil err
function PresetCopy.InstantiateSnapshot(bucket, snapshot, registry, answers)
    if type(bucket) ~= "table" or registry == nil then
        return nil, nil, nil, "No scope to create the alert in."
    end
    if type(snapshot) ~= "table" then
        return nil, nil, nil, "Could not copy the preset graph."
    end
    -- Pack snapshots are not read by Presets.Load. Rewrite the saved graph
    -- before Deserialize fills Sticky false and drops a removed Dismiss On.
    if type(snapshot.graph) == "table" then
        snapshot.layout = DropDismissOn.Apply(snapshot.graph, snapshot.layout)
    end
    return copyGraph(
        bucket, snapshot.name, snapshot.graph, snapshot.layout, snapshot.variables,
        registry, answers, snapshot.name)
end

return PresetCopy
