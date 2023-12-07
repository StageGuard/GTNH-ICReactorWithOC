local ReactorDesign = {
    fuel_slots = {},
    cool_slots = {},
    mapping = {},
}

function ReactorDesign:fromTemplate(src)
    local obj = {}
    setmetatable(obj, self)
    self.__index = self
    local row = 0
    local counter = 0
    for s in src:gmatch("[^\r\n]+") do
        s = s:gsub("^%s*(.-)%s*$", "%1")
        if s == "" then
            goto continue
        end
        row = row + 1
        if string.len(s) ~= 9 then
            error("Each row has 9 slots")
        end
        for i = 1, #s do
            local type = string.sub(s, i, i)
            if type == "F" then
                table.insert(self.fuel_slots, counter)
            elseif type == "C" then
                table.insert(self.cool_slots, counter)
            else
                error("Unknown type " .. type)
            end
            self.mapping[counter] = type
            counter = counter + 1
        end
        :: continue ::
    end
    if row ~= 6 then
        error("Should have 6 rows")
    end
    return obj
end
function ReactorDesign:fuelSlots()
    return self.fuel_slots
end
function ReactorDesign:coolSlots()
    return self.cool_slots
end
function ReactorDesign:numOfFuel()
    return #self.fuel_slots
end
function ReactorDesign:numOfCool()
    return #self.cool_slots
end
function ReactorDesign:slotType(slotNum)
    return self.mapping[slotNum]
end

-- meta

function ReactorDesign.__tostring()
    return "Reactor Design"
end

ReactorDesign.__index = ReactorDesign

function ReactorDesign:new()
    local obj = {}
    return setmetatable(obj, ReactorDesign)
end

return ReactorDesign:new()