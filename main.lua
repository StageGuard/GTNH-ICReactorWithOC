local event = require "event"
local JSON = (loadfile "lib/JSON.lua")()
local inspect = (loadfile "lib/inspect.lua")()
local helper = (loadfile "lib/helper.lua")()
local ReactorDesign = (loadfile "lib/ReactorDesign.lua")()


local config = (function (name)
    local cfgFile = io.open(name, "r")
    if cfgFile == nil then
        return nil
    end
    local parsed = JSON:decode(cfgFile:read("*a"))
    cfgFile:close()
    return parsed
end)("config.json")
if config == nil then
    print("config.json is not found, script will exit.")
    goto stop
end

--- 反应堆设计
local design = ReactorDesign:fromTemplate(config.design)
--- 装好的冷却单元的箱子
local chestCooler = helper.proxyTransposer(config.components.chest_cooler)
--- 装坏的冷却单元的箱子
local chestDamagedCooler = helper.proxyTransposer(config.components.chest_damaged_cooler)
--- 装燃料棒的箱子
local chestFuel = helper.proxyTransposer(config.components.chest_fuel)
--- 反应堆方块
local reactorBin = helper.proxyTransposer(config.components.reactor_bin)
--- 反应堆控制器
local reactor = helper.proxyRedstoneController(config.components.reactor_switch)
--- 蜂鸣报警器
local buzzer = helper.proxyRedstoneController(config.components.buzzer)

local function buzz()
    if not buzzer:isEnabled() then buzzer:enable() end
end

--- 检测能量储备是否已满
--- 给 GT 机器贴上能量探测覆盖板，然后再贴上红石 I/O 端口
--- 红石模式为常规模式
--- 能量阈值为：最大 EU 容量 - 核电每 tick 发电量 * 20
--- 20 为 tps
--- 不使用最大 EU 容量作为阈值是因为要给 oc 一定的时间来关闭核电
local isEnergyFull = function ()
    local esComponent = config.components.energy_station
    local esIOPort = helper.getComponent(esComponent)
    return esIOPort.getInput(helper.DIRECTION[esComponent.direction]) ~= 0
end

--- 检测温反应堆温度
--- 用 Nuclear Control 2 的温度控制器，然后再贴上红石 I/O 端口
--- 温度阈值参考工业信息屏显示的温度和反应堆的堆温百分比
local isHighTemperature = function ()
    local tmComponent = config.components.temperature_monitor
    local tmIOPort = helper.getComponent(tmComponent)
    return tmIOPort.getInput(helper.DIRECTION[tmComponent.direction]) ~= 0
end

--- 把反应堆耐久低的冷却单元都替换成箱子里的好的单元
--- 返回 true 表示已全部将冷却单元替换完成，反应堆中的冷却单元耐久均在阈值之上
--- 返回 false 表示未能全部替换
--- @return boolean
local function swapCooler()
    local coolersInChest = chestCooler.getAllItems()
    local reactorItems = reactorBin.getAllItems()

    local availableCoolers = {}
    -- 获取所有箱子里的可用的冷却单元格子索引
    for idx, item in pairs(coolersInChest) do
        if item.name == nil then goto continue end
        
        if item.name == config.cooler_name and item.damage / item.maxDamage < 1 - config.cooler_durability_threshold then
            table.insert(availableCoolers, idx)
        end

        :: continue ::
    end

    -- 备用数量小于阈值直接返回 -1
    if #availableCoolers + 1 < config.reserved_available_cooler_threshold then
        io.write("ERROR: The number of reserved available coolers (" .. config.cooler_name)
        io.write(") in cooler chest is less than threshold " .. config.reserved_available_cooler_threshold .. ".\n")

        return false
    end

    for i = 0, 53 do
        local item = reactorItems[i]
        local slotType = design:slotType(i)
        
        -- 只检测冷却单元格子
        if slotType ~= 'C' then goto continue end
        -- 这个格子有冷却单元并且单元耐久没到阈值
        if item.name == config.cooler_name and item.damage / item.maxDamage < 1 - config.cooler_durability_threshold then 
            goto continue
        end
        
        -- 检测箱子里还有没有好冷却单元可以用
        local popCooler = table.remove(availableCoolers, 1)
        if popCooler == nil then
            print("ERROR: No available coolers in chest to swap with reactor slot " .. helper.renderReactorSlot(item.name, i) .. ".")
            return false
        end

        -- 交换冷却单元
        if item.name ~= nil then
            local transportCount = reactorBin.moveItem(i + 1, chestDamagedCooler, 1)
            if transportCount == 0 then
                print("ERROR: No available slot in chest to swap with reactor slot " .. helper.renderReactorSlot(item.name, i) .. ".")
                return false
            end
        end

        chestCooler.moveItem(popCooler + 1, reactorBin, 1, i + 1)
        print(" INFO: Swapped damaged cooler in reactor " .. helper.renderReactorSlot(item.name, i) .. " with the chest slot " .. tostring(popCooler))

        :: continue ::
    end

    return true
end

--- 把坏的燃料替换成好的燃料
--- @return boolean
local function swapFuel()
    local fuelInChest = chestFuel.getAllItems()
    local reactorItems = reactorBin.getAllItems()
    
    local availableFuel = {}
    -- 获取所有箱子里的可用的冷却单元格子索引
    for idx, item in pairs(fuelInChest) do
        if item.name == nil then goto continue end
        
        -- 只要是还有耐久的燃料棒就都可以用
        if item.name == config.fuel_name and item.damage ~= item.maxDamage then
            for _ = 1, item.size, 1 do table.insert(availableFuel, idx) end
        end

        :: continue ::
    end

    for i = 0, 53 do
        local item = reactorItems[i]
        local slotType = design:slotType(i)
     
        -- 只检测燃料棒格子
        if slotType ~= 'F' then goto continue end
        -- 这个格子的冷却单元还有耐久
        if item.name == config.fuel_name and item.damage ~= item.maxDamage then goto continue end
     
        -- 检测箱子里还有没有好冷却单元可以用
        local popFuel = table.remove(availableFuel, 1)
        if popFuel == nil then
            print(" WARN: No available fuel in chest to swap with reactor slot " .. helper.renderReactorSlot(item.name, i) .. ".")
            return false
        end

        -- 交换冷却单元
        if item.name ~= nil then
            local stackableSlot = chestFuel.findFirstStackableSlot(reactorItems[i])
            if stackableSlot == nil then
                print(" WARN: No available slot in chest to swap with reactor slot " .. helper.renderReactorSlot(item.name, i) .. ".")
                return false
            end
            local transportCount = reactorBin.moveItem(i + 1, chestFuel, 1, stackableSlot + 1)
            if transportCount == 0 then
                print(" WARN: Failed to swap depleted fuel in reactor slot " .. helper.renderReactorSlot(item.name, i) .. ".")
                return false
            end
        end

        chestFuel.moveItem(popFuel + 1, reactorBin, 1, i + 1)
        print(" INFO: Swapped depleted fuel in reactor " .. helper.renderReactorSlot(item.name, i) .. " with the chest slot " .. tostring(popFuel))

        :: continue ::
    end

    return true
end

local function safeStop()
    print("Goodbye!")
    reactor:disable()
    buzzer:disable()
end

--- 主循环，每次循环都会：
--- 1. 检测能量储备是否已满
--- 2. 检测反应堆堆温是否超过阈值
--- 3. 更换坏的冷却单元
--- 4. 更换坏的燃料棒
--- 除了第四步，其他三步若无法完成则反应堆会停机
local mainloop = coroutine.create(function ()
    while true do
        print(" INFO: mainloop is running, press Ctrl+C to stop script.")
        buzzer:disable()
        while true do
            if isEnergyFull() then
                print(" WARN: Energy station is full, reactor will stop working.")
                reactor:disable()
                break
            end

            if isHighTemperature() then
                print("ERROR: Reactor temperature is higher than threshold, reactor will stop working.")
                reactor:disable()
                buzz()
                break
            end

            if not swapCooler() then
                print("ERROR: Swap cooler failed, reactor will stop working.")
                reactor:disable()
                buzz()
                break
            end

            if not swapFuel() then
                print(" WARN: Swap fuel failed. Reactor will keep working, but may not produce energy with maxmium efficiency.")
                buzz()
            end

            -- 冷却单元和燃料棒都检查完毕，若反应堆未启动则可以启动
            if not reactor:isEnabled() then
                reactor:enable()
            end
    
            if event.pull(0.05) == "interrupted" then
                goto mainloop_end
            end
        end
        coroutine.yield(-1)
    end
    :: mainloop_end ::
    coroutine.yield(0)
end);

while true do
    local _, await = coroutine.resume(mainloop)

    if await == 0 or await == "interrupted" then
        coroutine.resume(mainloop)
        safeStop()
        break
    end

    print(" INFO: mainloop is suspended, resuming in 10 seconds, press Ctrl+C to stop script.")

    local id, _ = event.pull(10, "interrupted")
    if id == "interrupted" then
        safeStop()
        break
    end
end

:: stop ::