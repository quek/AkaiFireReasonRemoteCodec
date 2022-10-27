function remote_init()
    local items={
        {name="Keyboard", input="keyboard"},
	    {name="Pitch Bend", input="value", min=0, max=16383},
        {name="Knob 1", input="value", output="value", min=0, max=127},
        {name="Knob 2", input="value", output="value", min=0, max=127},
        {name="Knob 3", input="value", output="value", min=0, max=127},
        {name="Knob 4", input="value", output="value", min=0, max=127},
        {name="Select", input="delta"},
        {name="Mode", input="button"},
        {name="MuteSolo1", input="button"},
        {name="MuteSolo2", input="button"},
        {name="MuteSolo3", input="button"},
        {name="MuteSolo4", input="button"},
        {name="PatternUp", input="button"}, -- 0x1f
        {name="PatternDown", input="button"}, -- 0x20
        {name="Browser", input="button"}, -- 0x21
        {name="SelectPush", input="button"}, -- 0x19
        {name="GridLeft", input="button"}, -- 0x22
        {name="GridRight", input="button"}, -- 0x23
    }
    remote.define_items(items)

  local inputs={
    {pattern="e? xx yy", name="Pitch Bend", value="y*128 + x"},
    {pattern="9? xx 00", name="Keyboard", value="0", note="x", velocity="64"},
    {pattern="<100x>? yy zz", name="Keyboard"},
    { pattern = "b? 10 xx", name = "Knob 1" },
    { pattern = "b? 11 xx", name = "Knob 2" },
    { pattern = "b? 12 xx", name = "Knob 3" },
    { pattern = "b? 13 xx", name = "Knob 4" },
    { pattern = "b? 76 xx", name = "Select" },
  }
  remote.define_auto_inputs(inputs)
end

-- this is the array index in 'items' for the first pad button. The array is 1-based.
g_first_padbutton_index = 11

-- this is the number of pad buttons - 2 banks x 8 buttons
g_num_padbuttons = 16

--position of first analog control in the items table
gFirstAnalogIndex = 3
--"Analogs" indicates non-encoder analog controls and refers to both knobs and sliders
-- gNumberOfAnalogs = 5
gNumberOfAnalogs = 5

--converts CC numbers to slider/knob numbers in format: [CC]=Knob
gAnalogCCLookup = {
    -- [0x10]=1,[0x11]=2,[0x12]=3,[0x13]=4,[0x76]=5 --Knobs 1-5
    [0x10]=1,[0x11]=2,[0x12]=3,[0x13]=4 --Knobs 1-4
}

gPadCCLookup = {
    [20]=1,[21]=2,[22]=3,[23]=4,[24]=5,[25]=6,[26]=7,[27]=8, --Pads 1-16
    [28]=9,[29]=10,[30]=11,[31]=12,[35]=13,[36]=14,[37]=15,[38]=16
}

gAnalogPhysicalState, gAnalogMachineState, gAnalogMismatch, gLastAnalogMoveTime, gSentValueSettleTime = {}, {}, {}, {}, {}

for i = 1, gNumberOfAnalogs do --set up slider/knob tracking arrays
    gAnalogPhysicalState[i] = 0 --stores current position/value of control on hardware
    gAnalogMachineState[i] = 0 --stores value of connected software item
    gAnalogMismatch[i] = nil --difference between physical state of control and software value (positive numbers indicate physical value is greater, nil indicates mismatch assumption due to unknown physical state at startup)
    gLastAnalogMoveTime[i] = 0 --stores timestamp of last time knob/slider was moved on hardware
    gSentValueSettleTime[i] = 250 --number of milliseconds to wait for a sent slider or knob value to be echoed back before reevaluating synchronization
end

--acceptable difference between the first reported value from a control and the machine state for the 2 to be considered synchronized
gStartupLiveband = 3


function remote_process_midi(event) --manual handling of incoming values sent by controller
    -- remote.trace("remote_process_midi is called!")
    --Analog Messages
    ret=remote.match_midi("B9 yy xx", event) --check for messages in channel 10
    if ret~=nil then
        -- Catch pad events
        local padNum = gPadCCLookup[ret.y]
        if padNum == nil then
            return false
        else
            local val = (ret.x ~= 0) and 1 or 0
            -- Make a remote message. item is the index in the control surface item list. 0-1, release-press.
            local msg = {
                time_stamp = event.time_stamp,
                item = g_first_padbutton_index + padNum - 1,
                value = val
            }
            remote.handle_input(msg)
            return true
        end
    end

    -- Select
    ret=remote.match_midi("B0 76 xx", event)
    if ret~=nil then
        local value = 1
        if ret.x > 0x40 then
            value = -1
        end
        remote.handle_input({ time_stamp=event.time_stamp, item=7, value=value })
        return true
    end

    ret=remote.match_midi("B0 yy xx", event) --check for messages in channel 1
    if ret~=nil then
        -- Catch knob events
        local AnalogNum = gAnalogCCLookup[ret.y] --try to get the analog number that corresponds to the received Continuous Controller message
        if AnalogNum == nil then --if message isn't from an analog
            return false --pass it on to auto input handling
        else
            -- gAnalogPhysicalState[AnalogNum] = ret.x --update the stored physical state to the incoming value
            local AllowChange = true --we'll send the incoming value to the host unless we find a reason not to

            if gAnalogMismatch[AnalogNum] ~= 0 then --assess conditions if controller and software values are mismatched
                if gAnalogMismatch[AnalogNum] == nil then --startup condition: analog hasn't reported in yet
                    gAnalogMismatch[AnalogNum] = gAnalogPhysicalState[AnalogNum] - gAnalogMachineState[AnalogNum] --calculate and store how physical and machine states relate to each other
                    if math.abs(gAnalogMismatch[AnalogNum]) > gStartupLiveband then --if the physical value is too far from the machine value
                        AllowChange = false --don't send it to Reason
                    end
                elseif gAnalogMismatch[AnalogNum] > 0 and gAnalogPhysicalState[AnalogNum] - gAnalogMachineState[AnalogNum] > 0 then --if physical state of analog was and still is above virtual value
                    AllowChange = false --don't send the new value to Reason because it's out of sync
                elseif gAnalogMismatch[AnalogNum] < 0 and gAnalogPhysicalState[AnalogNum] - gAnalogMachineState[AnalogNum] < 0 then --if physical state of analog was and still is below virtual value
                    AllowChange = false --don't send the updated value
                end
            end

            if ret.x > 0x40 then
                if gAnalogPhysicalState[AnalogNum] > 0 then
                    gAnalogPhysicalState[AnalogNum] = gAnalogPhysicalState[AnalogNum] - 1
                end
            else
                if gAnalogPhysicalState[AnalogNum] < 127 then
                    gAnalogPhysicalState[AnalogNum] = gAnalogPhysicalState[AnalogNum] + 1
                end
            end

            if AllowChange then --if the incoming change should be sent to Reason
                remote.handle_input({ time_stamp=event.time_stamp, item=gFirstAnalogIndex + AnalogNum - 1, value=gAnalogPhysicalState[AnalogNum]  }) --send the new analog value to Reason
                gLastAnalogMoveTime[AnalogNum] = remote.get_time_ms() --store the time this change was sent
                gAnalogMismatch[AnalogNum] = 0 --and set the flag to show the controller and Reason are in sync
            end
            return true --input has been handled
        end
    end

    -- ret=remote.match_midi("90 1a 7f", event)
    -- if ret~=nil then
    --     remote.handle_input({ time_stamp=event.time_stamp, item=8, value=1 })
    --     return true
    -- end
    -- ret=remote.match_midi("80 1a 00", event)
    -- if ret~=nil then
    --     return true
    -- end

    ret=remote.match_midi("90 xx yy", event)
    if ret~=nil then
        if ret.x == 0x1a then
            remote.handle_input({ time_stamp=event.time_stamp, item=8, value=1 })
            return true
        elseif ret.x == 0x24 then
            remote.handle_input({ time_stamp=event.time_stamp, item=9, value=1 })
            return true
        elseif ret.x == 0x25 then
            remote.handle_input({ time_stamp=event.time_stamp, item=10, value=1 })
            return true
        elseif ret.x == 0x26 then
            remote.handle_input({ time_stamp=event.time_stamp, item=11, value=1 })
            return true
        elseif ret.x == 0x27 then
            remote.handle_input({ time_stamp=event.time_stamp, item=12, value=1 })
            return true
        elseif ret.x == 0x1f then -- PatternUp
            remote.handle_input({ time_stamp=event.time_stamp, item=13, value=1 })
            return true
        elseif ret.x == 0x20 then -- PatternDown
            remote.handle_input({ time_stamp=event.time_stamp, item=14, value=1 })
            return true
        elseif ret.x == 0x21 then -- Browser
            remote.handle_input({ time_stamp=event.time_stamp, item=15, value=1 })
            return true
        elseif ret.x == 0x19 then -- SelectPush
            remote.handle_input({ time_stamp=event.time_stamp, item=16, value=1 })
            return true
        elseif ret.x == 0x22 then -- GridLeft
            remote.handle_input({ time_stamp=event.time_stamp, item=17, value=1 })
            return true
        elseif ret.x == 0x23 then -- GridRight
            remote.handle_input({ time_stamp=event.time_stamp, item=18, value=1 })
            return true
        end
    end
    ret=remote.match_midi("80 xx yy", event)
    if ret~=nil then
        if ret.x == 0x1a then
            return true
        elseif ret.x == 0x24 then
            return true
        elseif ret.x == 0x25 then
            return true
        elseif ret.x == 0x26 then
            return true
        elseif ret.x == 0x27 then
            return true
        elseif ret.x == 0x1f then -- PatternUp
            return true
        elseif ret.x == 0x20 then -- PatternDown
            return true
        elseif ret.x == 0x21 then -- Browser
            return true
        elseif ret.x == 0x19 then -- SelectPush
            return true
        elseif ret.x == 0x22 then -- GridLeft
            return true
        elseif ret.x == 0x23 then -- GridRight
            return true
        end
    end
   return false
end

function remote_set_state(changed_items) --handle incoming changes sent by Reason
    -- remote.trace("remote_set_state is called!")
    for i,item_index in ipairs(changed_items) do
        local AnalogNum = item_index - gFirstAnalogIndex + 1 --calculate which analog (if any) the index of the changed item indicates
        if AnalogNum >= 1 and AnalogNum <= gNumberOfAnalogs then --if change belongs to an analog control
            gAnalogMachineState[AnalogNum] = remote.get_item_value(item_index) --update the machine state for the analog
            -- if gAnalogMismatch[AnalogNum] ~= nil then --if we know the analog's physical state
            --     if (remote.get_time_ms() - gLastAnalogMoveTime[AnalogNum]) > gSentValueSettleTime[AnalogNum] then --and the last value it sent to Reason happened outside the settle time
            --         gAnalogMismatch[AnalogNum] = gAnalogPhysicalState[AnalogNum] - gAnalogMachineState[AnalogNum] --recalculate and store how physical and machine states relate to each other
            --     end
            -- end
            gAnalogMismatch[AnalogNum] = 0
            gAnalogPhysicalState[AnalogNum] = gAnalogMachineState[AnalogNum]
        end
    end
end