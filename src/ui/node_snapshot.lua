-- A plain-table copy of some or all of a graph: nodes (type, controls, name, mode), the
-- wires between them, and their layout points. The clipboard holds one; each undo step is one.

local Util = require("src/util")

local NodeSnapshot = {}

local function deepCopy(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, x in pairs(v) do out[k] = deepCopy(x) end
    return out
end

local function serialize(graph)
    if LibNodeGraph ~= nil and LibNodeGraph.Serialize ~= nil then return LibNodeGraph.Serialize(graph) end
    return require("serialize").Serialize(graph)
end

local function isPlaceholder(graph, id)
    local node = graph.nodes[id]
    return node ~= nil and (node.unknown ~= nil
        or (LibNodeGraph ~= nil and node.typeKey == LibNodeGraph.UNKNOWN_TYPE))
end

--- Copies the nodes in `only` (all when nil) and the wires between them.
---@return table snapshot, integer skipped
function NodeSnapshot.Capture(graph, layout, only, skipPlaceholders)
    local snap, kept, skipped = { nodes = {}, connections = {}, layout = {} }, {}, 0
    local data = serialize(graph)
    for _, n in ipairs(data.nodes or {}) do
        if only == nil or only[n.id] then
            if skipPlaceholders and isPlaceholder(graph, n.id) then
                skipped = skipped + 1
            else
                local ok, mode = pcall(graph.GetMode, graph, n.id)
                if not ok or mode == nil then mode = n.mode end
                snap.nodes[#snap.nodes + 1] = {
                    id = n.id, type = n.type, controls = deepCopy(n.controls or {}), name = n.name, mode = mode,
                }
                kept[n.id] = true
                local p = layout and layout[n.id]
                if p ~= nil then snap.layout[n.id] = { x = p.x, y = p.y } end
            end
        end
    end
    for _, c in ipairs(data.connections or {}) do
        if kept[c.fromNode] and kept[c.toNode] then
            snap.connections[#snap.connections + 1] =
                { fromNode = c.fromNode, fromPin = c.fromPin, toNode = c.toNode, toPin = c.toPin }
        end
    end
    table.sort(snap.nodes, function(a, b) return a.id < b.id end)
    table.sort(snap.connections, function(a, b)
        return NodeSnapshot.Encode(a) < NodeSnapshot.Encode(b)
    end)
    return snap, skipped
end

--- A string that is equal for equal tables, whatever their key order.
function NodeSnapshot.Encode(v)
    if type(v) == "string" then return string.format("%q", v) end
    if type(v) ~= "table" then return tostring(v) end
    local parts = {}
    for k, x in pairs(v) do parts[#parts + 1] = NodeSnapshot.Encode(k) .. "=" .. NodeSnapshot.Encode(x) end
    table.sort(parts)
    return "{" .. table.concat(parts, ";") .. "}"
end

local function addNode(graph, n)
    local ok, id = pcall(graph.AddNode, graph, n.type, deepCopy(n.controls), { name = n.name, mode = n.mode })
    if ok then return id end
    return nil
end

local function connect(graph, a, ap, b, bp)
    pcall(graph.Connect, graph, a, ap, b, bp)
end

--- Adds a copy with new ids, its top-left at gx, gy. Types the registry lacks, or that
--- `canPlace` refuses, are left out with their wires.
---@return integer[] newIds
function NodeSnapshot.Paste(graph, registry, layout, snap, gx, gy, canPlace)
    local minX, minY = math.huge, math.huge
    for _, p in pairs(snap.layout) do
        minX, minY = math.min(minX, p.x), math.min(minY, p.y)
    end
    if minX == math.huge then minX, minY = 0, 0 end
    local map, newIds = {}, {}
    for _, n in ipairs(snap.nodes) do
        local id = registry:GetNodeType(n.type) ~= nil and (canPlace == nil or canPlace(n.type))
            and addNode(graph, n) or nil
        if id ~= nil then
            map[n.id] = id
            newIds[#newIds + 1] = id
            local p = snap.layout[n.id] or { x = minX, y = minY }
            layout[id] = { x = Util.RoundHalfAway(gx + p.x - minX), y = Util.RoundHalfAway(gy + p.y - minY) }
        end
    end
    for _, c in ipairs(snap.connections) do
        if map[c.fromNode] and map[c.toNode] then
            connect(graph, map[c.fromNode], c.fromPin, map[c.toNode], c.toPin)
        end
    end
    return newIds
end

local function resolve(alias, id)
    for _ = 1, 1000 do
        if alias[id] == nil then return id end
        id = alias[id]
    end
    return id
end

--- Makes the live graph match `snap` in place (the runtime runs this graph object). Nodes of
--- the same type keep their id and runtime state; missing ones are re-added and `alias`
--- maps the snapshot id to the new id, so older snapshots find them too.
function NodeSnapshot.Restore(graph, registry, layout, snap, alias, removeNode)
    local liveType = {}
    for _, n in ipairs(NodeSnapshot.Capture(graph).nodes) do liveType[n.id] = n.type end

    local resolved, claimed, missing = {}, {}, {}
    for _, n in ipairs(snap.nodes) do
        local id = resolve(alias, n.id)
        if liveType[id] == n.type and not claimed[id] then
            claimed[id], resolved[n.id] = true, id
        else
            missing[#missing + 1] = n
        end
    end
    for id in pairs(liveType) do
        if not claimed[id] then removeNode(id) end
    end

    for _, n in ipairs(snap.nodes) do
        local id = resolved[n.id]
        if id ~= nil and not isPlaceholder(graph, id) then
            if n.mode ~= nil and graph:GetMode(id) ~= n.mode then graph:SetMode(id, n.mode) end
            local live = NodeSnapshot.Capture(graph, nil, { [id] = true }).nodes[1].controls
            for k in pairs(live) do
                if n.controls[k] == nil then graph:SetControl(id, k, nil) end
            end
            for k, v in pairs(n.controls) do graph:SetControl(id, k, deepCopy(v)) end
            graph.nodes[id].name = n.name
        end
    end
    for _, n in ipairs(missing) do
        local id = registry:GetNodeType(n.type) ~= nil and addNode(graph, n) or nil
        if id ~= nil then
            local tail = resolve(alias, n.id)
            if tail ~= id then alias[tail] = id end
            alias[id] = nil
            resolved[n.id] = id
        end
    end

    local wanted = {}
    for _, c in ipairs(snap.connections) do
        local a, b = resolved[c.fromNode], resolved[c.toNode]
        if a and b then wanted[a .. "\0" .. c.fromPin .. "\0" .. b .. "\0" .. c.toPin] = { a, c.fromPin, b, c.toPin } end
    end
    for _, c in ipairs(graph:GetConnections()) do
        local key = c.fromNode .. "\0" .. c.fromPin .. "\0" .. c.toNode .. "\0" .. c.toPin
        if wanted[key] then wanted[key] = nil else graph:Disconnect(c.id) end
    end
    for _, w in pairs(wanted) do connect(graph, w[1], w[2], w[3], w[4]) end

    for id in pairs(layout) do
        if graph.nodes[id] == nil then layout[id] = nil end
    end
    for snapId, id in pairs(resolved) do
        local p = snap.layout[snapId]
        if p ~= nil then layout[id] = { x = p.x, y = p.y } end
    end
end

return NodeSnapshot
