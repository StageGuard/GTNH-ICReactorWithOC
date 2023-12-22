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

--- 装好的冷却单元的箱子
local chestCooler = helper.proxyTransposer(config.components.chest_cooler)
--- 装坏的冷却单元的箱子
local chestDamagedCooler = helper.proxyTransposer(config.components.chest_damaged_cooler)
--- 装燃料棒的箱子
local chestFuel = helper.proxyTransposer(config.components.chest_fuel)
--- 蜂鸣报警器
local buzzer = helper.proxyRedstoneController(config.components.buzzer)

local function buzz()
    if not buzzer:isEnabled() then buzzer:enable() end
end

local reactors = (function ()
    local obj = {}
    for _, item in pairs(config.reactors) do table.insert(obj, {
        name = item.name,

        fuelName = item.fuel_name,
        coolerName = item.cooler_name,
        coolerDurabilityThreshold = item.cooler_durability_threshold,
        reservedAvailableCoolerThreshold = item.reserved_available_cooler_threshold,

        design = ReactorDesign:fromTemplate(item.design),

        --- 核反应仓
        bin = helper.proxyTransposer(config.components[item.component_refs.bin]),
        --- 控制开关
        switch = helper.proxyRedstoneController(config.components[item.component_refs.switch]),

        --- 检测温反应堆温度
        --- 用 Nuclear Control 2 的温度控制器，然后再贴上红石 I/O 端口
        --- 温度阈值参考工业信息屏显示的温度和反应堆的堆温百分比
        isHighTemperature = function ()
            local tmComponent = config.components[item.component_refs.temperature_monitor]
            local tmIOPort = helper.getComponent(tmComponent)
            return tmIOPort.getInput(helper.DIRECTION[tmComponent.direction]) ~= 0
        end,
    }) end
    return obj
end)()

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

--- 把反应堆耐久低的冷却单元都替换成箱子里的好的单元
--- 返回 true 表示已全部将冷却单元替换完成，反应堆中的冷却单元耐久均在阈值之上
--- 返回 false 表示未能全部替换
--- @return boolean
local function swapCooler(reactor)
    local coolersInChest = chestCooler.getAllItems()
    local reactorItems = reactor.bin.getAllItems()

    local availableCoolers = {}
    -- 获取所有箱子里的可用的冷却单元格子索引
    for idx, item in pairs(coolersInChest) do
        if item.name == nil then goto continue end

        if item.name == reactor.coolerName and item.damage / item.maxDamage < 1 - reactor.coolerDurabilityThreshold then
            table.insert(availableCoolers, idx)
        end

        :: continue ::
    end

    -- 备用数量小于阈值直接返回 -1
    if #availableCoolers + 1 < reactor.reservedAvailableCoolerThreshold then
        io.write("ERROR[" .. reactor.name .. "]: The number of reserved available coolers (" .. reactor.coolerName)
        io.write(") in cooler chest is less than threshold " .. reactor.reservedAvailableCoolerThreshold .. ".\n")

        return false
    end

    for i = 0, 53 do
        local item = reactorItems[i]
        local slotType = reactor.design:slotType(i)

        -- 只检测冷却单元格子
        if slotType ~= 'C' then goto continue end
        -- 这个格子有冷却单元并且单元耐久没到阈值
        if item.name == reactor.coolerName and item.damage / item.maxDamage < 1 - reactor.coolerDurabilityThreshold then 
            goto continue
        end

        -- 检测箱子里还有没有好冷却单元可以用
        local popCooler = table.remove(availableCoolers, 1)
        if popCooler == nil then
            print("ERROR[" .. reactor.name .. "]: No available coolers in chest to swap with reactor slot " .. helper.renderReactorSlot(item.name, i) .. ".")
            return false
        end

        -- 交换冷却单元
        if item.name ~= nil then
            local transportCount = reactor.bin.moveItem(i + 1, chestDamagedCooler, 1)
            if transportCount == 0 then
                print("ERROR[" .. reactor.name .. "]: No available slot in chest to swap with reactor slot " .. helper.renderReactorSlot(item.name, i) .. ".")
                return false
            end
        end

        chestCooler.moveItem(popCooler + 1, reactor.bin, 1, i + 1)
        print(" INFO[" .. reactor.name .. "]: Swapped damaged cooler in reactor " .. helper.renderReactorSlot(item.name, i) .. " with the chest slot " .. tostring(popCooler))

        :: continue ::
    end

    return true
end

--- 把坏的燃料替换成好的燃料
--- @return boolean
local function swapFuel(reactor)
    local fuelInChest = chestFuel.getAllItems()
    local reactorItems = reactor.bin.getAllItems()

    local availableFuel = {}
    -- 获取所有箱子里的可用的燃料棒格子索引
    for idx, item in pairs(fuelInChest) do
        if item.name == nil then goto continue end

        -- 只要是还有耐久的燃料棒就都可以用
        if item.name == reactor.fuelName and item.damage ~= item.maxDamage then
            for _ = 1, item.size, 1 do table.insert(availableFuel, idx) end
        end

        :: continue ::
    end

    for i = 0, 53 do
        local item = reactorItems[i]
        local slotType = reactor.design:slotType(i)

        -- 只检测燃料棒格子
        if slotType ~= 'F' then goto continue end
        -- 这个格子的冷却单元还有耐久
        if item.name == reactor.fuelName and item.damage ~= item.maxDamage then goto continue end

        -- 检测箱子里还有没有燃料棒可以用
        local popFuel = table.remove(availableFuel, 1)
        if popFuel == nil then
            print(" WARN[" .. reactor.name .. "]: No available fuel in chest to swap with reactor slot " .. helper.renderReactorSlot(item.name, i) .. ".")
            return false
        end

        -- 交换燃料棒
        if item.name ~= nil then
            local stackableSlot = chestFuel.findFirstStackableSlot(reactorItems[i])
            if stackableSlot == nil then
                print(" WARN[" .. reactor.name .. "]: No available slot in chest to swap with reactor slot " .. helper.renderReactorSlot(item.name, i) .. ".")
                return false
            end
            local transportCount = reactor.bin.moveItem(i + 1, chestFuel, 1, stackableSlot + 1)
            if transportCount == 0 then
                print(" WARN[" .. reactor.name .. "]: Failed to swap depleted fuel in reactor slot " .. helper.renderReactorSlot(item.name, i) .. ".")
                return false
            end
        end

        chestFuel.moveItem(popFuel + 1, reactor.bin, 1, i + 1)
        print(" INFO[" .. reactor.name .. "]: Swapped depleted fuel in reactor " .. helper.renderReactorSlot(item.name, i) .. " with the chest slot " .. tostring(popFuel))

        :: continue ::
    end

    return true
end

local function safeStop()
    print("Goodbye!")
    for _, reactor in pairs(reactors) do
        reactor.switch:disable()
    end
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
        while true do
            :: inner_loop_start ::

            local workingReactors = #reactors
            for _, reactor in pairs(reactors) do
                if isEnergyFull() then
                    print(" WARN: Energy station is full, reactor will stop working.")
                    reactor.switch:disable()
                    workingReactors = workingReactors - 1
                    goto reactor_check_continue
                end

                if reactor.isHighTemperature() then
                    print("ERROR[" .. reactor.name .. "]: Reactor temperature is higher than threshold, reactor will stop working.")
                    reactor.switch:disable()
                    buzz()
                    workingReactors = workingReactors - 1
                    goto reactor_check_continue
                end

                if not swapCooler(reactor) then
                    print("ERROR[" .. reactor.name .. "]: Swap cooler failed, reactor will stop working.")
                    reactor.switch:disable()
                    buzz()
                    workingReactors = workingReactors - 1
                    goto reactor_check_continue
                end

                if not swapFuel(reactor) then
                    print(" WARN[" .. reactor.name .. "]: Swap fuel failed. Reactor will keep working, but may not produce energy with maxmium efficiency.")
                    buzz()
                end

                if not reactor.switch:isEnabled() then
                    reactor.switch:enable()
                end

                :: reactor_check_continue ::
                if event.pull(0.01) == "interrupted" then
                    goto mainloop_end
                end
            end

            if workingReactors == #reactors then
                buzzer:disable()
            elseif workingReactors == 0 then
                goto inner_loop_end
            end

            if event.pull(0.03) == "interrupted" then
                goto mainloop_end
            end
            goto inner_loop_start

            :: inner_loop_end ::
            if #reactors >= 2 then
                print(" INFO: All reactors stopped working.")
            end
            break
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