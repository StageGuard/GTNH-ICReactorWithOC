local component = require("component")
local JSON = (loadfile "lib/JSON.lua")()

local sides = {
    BOTTOM = 0,
    TOP = 1,
    NORTH = 2,
    SOUTH = 3,
    WEST = 4,
    EAST = 5
}

local function startsWith(text, prefix)
    return text:find(prefix, 1, true) == 1
end

local function printTable(table)
    if table == nil then
        print("nil table")
        return
    end
    if isNullOrEmpty(table) then
        print("empty table")
        return
    end
    for k, v in pairs(table) do
        print(k, v)
    end
end

function isNullOrEmpty(table)
    if table == nil then
        return true;
    end
    for i, v in pairs(table) do
        return false;
    end
    return true;
end

---
-- Returns the component only if the type and name prefixes match only one in the network
---

local componentCacheStorage = {}

local function getComponent(componentTable)
    local concated = componentTable.type .. ":" .. componentTable.address_prefix
    if componentCacheStorage[concated] ~= nil then
        return componentCacheStorage[concated]
    end

    -- Get component
    local matched = 0
    local matchedK = nil
    local matchedV = nil
    for k, v in pairs(component.list(componentTable.type)) do
        if startsWith(k, componentTable.address_prefix) then
            matchedK = k
            matchedV = v
            matched = matched + 1
        end
    end
    if matched == 1 then
        local proxied = component.proxy(matchedK, matchedV)
        componentCacheStorage[concated] = proxied
        return proxied
    end
    if matched > 1 then
        error("duplicate match for " .. componentTable.type .. " with prefix " .. componentTable.address_prefix)
    else
        error("no match for " .. componentTable.type .. " with prefix " .. componentTable.address_prefix)
    end
end

local function findNonEmptyIndex(item_in_box)

    local boxLocation = 0

    for idx = 0, #item_in_box, 1 do
        if ((not isNullOrEmpty(item_in_box[idx])) and item_in_box[idx].size > 0) then
            boxLocation = idx + 1
            break
        end
    end
    if boxLocation == 0 then
        return nil
    end
    return boxLocation
end

local function getTransposerSide(t, side, name)
    return {
        getAllItems = function()
            return t.getAllStacks(side).getAll()
        end,
        transposer = t,
        side = side,
        moveItem = function(sourceSlot, target, count, targetSlot)
            if count == nil then
                count = 1
            end
            --if targetSlot == nil then
            --    targetSlot = findEmptySlot(t.getAllStacks(targetSide).getAll())
            --end
            -- sourceSide, sinkSide, count, sourceSlot, sinkSlot
            if targetSlot == nil then
                t.transferItem(side, target.side, count, sourceSlot)
            else
                t.transferItem(side, target.side, count, sourceSlot, targetSlot)
            end
        end,
        name = name,
        findFirstEmptySlot = function ()
            local allItems = t.getAllStacks(side).getAll()
            for index, item in ipairs(allItems) do
                if item.name == nil then return index end
            end
            return nil
        end,
    }
end

local function proxyTransposer(componentTable)
    if componentTable.type ~= "transposer" then return nil end
    local transposer = getComponent(componentTable)
    return getTransposerSide(transposer, sides[componentTable.direction])
end

local function proxyRedstoneController(componentTable)
    if isNullOrEmpty(componentTable) then return nil end
    if componentTable.type ~= "redstone" then return nil end

    local CONTROLLER = {
        component = componentTable,
        port = getComponent(componentTable),
        running = false,
    }

    function CONTROLLER:enable()
        self.port.setOutput(sides[self.component.direction], 15)
        self.running = true
    end

    function CONTROLLER:disable()
        self.port.setOutput(sides[self.component.direction], 0)
        self.running = false
    end

    function CONTROLLER:isEnabled()
        return self.running
    end

    CONTROLLER.__index = CONTROLLER

    return CONTROLLER
end

local function loadConfig(name)
    local cfgFile = io.open(name, "r")
    if cfgFile == nil then
        return nil
    end
    local parsed = JSON:decode(cfgFile:read("*a"))
    cfgFile:close()
    return parsed
end

local function renderReactorSlot(index)
    return "(" .. tostring((index // 9) + 1) .. ", " .. tostring(index % 9) .. ")"
end

return {
    startsWith = startsWith,
    printTable = printTable,
    getComponent = getComponent,
    findNonEmptyIndex = findNonEmptyIndex,
    getTransposerSide = getTransposerSide,
    DIRECTION = sides,
    proxyTransposer = proxyTransposer,
    proxyRedstoneController = proxyRedstoneController,
    loadConfig = loadConfig,
    renderReactorSlot = renderReactorSlot,
}