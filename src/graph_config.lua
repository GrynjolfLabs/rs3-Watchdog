-- The loaded graph keeps data-in pin values and drops every other control key
-- (LibNodeGraph Graph:AddNode / SetControl). Player Input's checks have to survive
-- a save without becoming pins, so a wire cannot target them and a Preset cannot
-- mark them. This installs that slot on the graph the client actually loaded.
-- Types with no config are unchanged.

---@class LibNodeGraph.ConfigDef
---@field name string
---@field dataType string|nil
---@field default any
---@field label string|nil

---@class LibNodeGraph.NodeTypeDef
---@field config LibNodeGraph.ConfigDef[]|nil
---@field configByName table<string, LibNodeGraph.ConfigDef>|nil

local GraphConfig = {}

local installed = false

---@param value any
---@return any
local function copyDefault(value)
    if type(value) ~= "table" then
        return value
    end
    local copy = {}
    for k, v in pairs(value) do
        copy[k] = v
    end
    return copy
end

---@param registry LibNodeGraph.Registry
local function rememberConfig(registry)
    local Registry = getmetatable(registry)
    local register = Registry.RegisterNodeType
    function Registry:RegisterNodeType(key, definition)
        local nodeType = register(self, key, definition)
        local declared = definition and definition.config
        if type(declared) ~= "table" then
            return nodeType
        end
        local list, byName = {}, {}
        for _, def in ipairs(declared) do
            assert(type(def.name) == "string" and def.name ~= "",
                "config entry missing name on node type '" .. key .. "'")
            assert(byName[def.name] == nil,
                "duplicate config name '" .. def.name .. "' on node type '" .. key .. "'")
            assert(nodeType.pins[def.name] == nil,
                "config '" .. def.name .. "' on '" .. key .. "' collides with a pin")
            if nodeType.modes ~= nil then
                for _, modeDef in pairs(nodeType.modes) do
                    assert(modeDef.pins[def.name] == nil,
                        "config '" .. def.name .. "' on '" .. key .. "' collides with a pin")
                end
            end
            local stored = {
                name = def.name,
                dataType = def.dataType,
                default = def.default,
                label = def.label,
            }
            byName[def.name] = stored
            list[#list + 1] = stored
        end
        nodeType.config = list
        nodeType.configByName = byName
        return nodeType
    end
end

---@param registry LibNodeGraph.Registry
local function keepConfigOnNodes(registry)
    local probe = LibNodeGraph.NewGraph(registry)
    local Graph = getmetatable(probe)
    local addNode = Graph.AddNode
    function Graph:AddNode(typeKey, controls, options)
        local id = addNode(self, typeKey, controls, options)
        local nodeType = self.registry:GetNodeType(typeKey)
        local config = nodeType and nodeType.config
        if config == nil then
            return id
        end
        local node = self.nodes[id]
        for _, cfg in ipairs(config) do
            -- false is a stored off-check. Only a missing key takes the default.
            if controls ~= nil and controls[cfg.name] ~= nil then
                node.controls[cfg.name] = controls[cfg.name]
            else
                node.controls[cfg.name] = copyDefault(cfg.default)
            end
        end
        return id
    end

    local setControl = Graph.SetControl
    function Graph:SetControl(nodeId, name, value)
        local node = self.nodes[nodeId]
        if node ~= nil then
            local nodeType = self.registry:GetNodeType(node.typeKey)
            local byName = nodeType and nodeType.configByName
            if byName ~= nil and byName[name] ~= nil then
                node.controls[name] = value
                return
            end
        end
        return setControl(self, nodeId, name, value)
    end

    local setMode = Graph.SetMode
    function Graph:SetMode(id, mode)
        local node = self.nodes[id]
        local kept = nil
        local configByName = nil
        if node ~= nil then
            local nodeType = self.registry:GetNodeType(node.typeKey)
            local byName = nodeType and nodeType.configByName
            if byName ~= nil then
                configByName = byName
                kept = {}
                for name in pairs(byName) do
                    kept[name] = node.controls[name]
                end
            end
        end
        local ok = setMode(self, id, mode)
        if kept == nil or configByName == nil or not ok then
            return ok
        end
        node = self.nodes[id]
        -- false is a real off-check. Only a missing value takes the default.
        for name, value in pairs(kept) do
            if value ~= nil then
                node.controls[name] = value
            end
        end
        for name, cfg in pairs(configByName) do
            if node.controls[name] == nil then
                node.controls[name] = copyDefault(cfg.default)
            end
        end
        return ok
    end
end

---@param registry LibNodeGraph.Registry
function GraphConfig.Install(registry)
    if installed then
        return
    end
    assert(LibNodeGraph ~= nil and LibNodeGraph.NewGraph ~= nil,
        "Player Input config needs the loaded LibNodeGraph")
    rememberConfig(registry)
    keepConfigOnNodes(registry)
    installed = true
end

return GraphConfig
