local component = require("component")

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

local function isNullOrEmpty(table)
    if table == nil then
        return true;
    end
    for i, v in pairs(table) do
        return false;
    end
    return true;
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
            if targetSlot == nil then
                return t.transferItem(side, target.side, count, sourceSlot)
            else
                return t.transferItem(side, target.side, count, sourceSlot, targetSlot)
            end
        end,
        findFirstStackableSlot = function(item)
            local slots = t.getAllStacks(side).getAll()
            local isItemInvalid = isNullOrEmpty(item)
            local firstEmpty, found = nil, nil

            for sk, sv in pairs(slots) do
                if isItemInvalid then
                    if isNullOrEmpty(sv) then return sk end
                    goto continue
                end

                if isNullOrEmpty(sv) then
                    if firstEmpty == nil then firstEmpty = sk end
                    goto continue
                end

                if tostring(sv.name) ~= tostring(item.name) then goto continue end
                if sv.damage ~= item.damage then goto continue end
                if sv.label ~= item.label then goto continue end
                if sv.tag ~= item.tag then goto continue end

                if sv.maxSize - sv.size < item.size then goto continue end
                
                found = sk
                break
                :: continue ::
            end

            if found ~= nil then
                return found
            else
                return firstEmpty
            end
        end,
        name = name,
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



local function renderReactorSlot(name, index)
    return tostring(name) .. "(" .. tostring((index // 9) + 1) .. ", " .. tostring(index % 9) .. ")"
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
    renderReactorSlot = renderReactorSlot,
}