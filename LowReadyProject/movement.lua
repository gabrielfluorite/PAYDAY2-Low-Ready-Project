-- Adapted only at the settings boundary from the synchronized functional module.
local M = {}
function M.install(settings_provider)
local diagnostic_seen = {}

local function diagnostic_once(event, ...)
    local args = { ... }

    pcall(function()
        if type(BLT) ~= "table" or type(BLT.Log) ~= "function"
            or type(LogLevel) ~= "table"
            or type(LogLevel.INFO) ~= "number" then
            return
        end

        if diagnostic_seen[event] then
            return
        end

        diagnostic_seen[event] = true
        BLT:Log(LogLevel.INFO, "[LowReady:E1]", event, unpack(args))
    end)
end

diagnostic_once("script_enter")

if _G.IS_VR or type(ModPath) ~= "string"
    or type(Hooks) ~= "table" or type(Hooks.PostHook) ~= "function"
    or type(PlayerStandard) ~= "table"
    or type(PlayerStandard.init) ~= "function"
    or type(PlayerStandard.tweak_data_clbk_reload) ~= "function" then
    diagnostic_once("script_context_rejected")
    return
end

-- Preferences are snapshotted once per native state instance. Existing scaled
-- tweaks are never rescaled when a menu changes. New missions construct states.
local function is_positive_finite(value)
    return type(value) == "number" and value > 0 and value < math.huge
end
local function instance_settings(state)
    if not state._low_ready_project_preferences then
        local supplied = settings_provider()
        local snapshot = {}
        for _, key in ipairs({"walk_speed_multiplier", "run_speed_multiplier",
            "crouch_speed_multiplier", "casing_speed_multiplier", "run_headbob_multiplier"}) do
            local value = supplied[key]
            snapshot[key] = type(value) == "number" and value >= 0.10 and value <= 1 and value or 1
        end
        snapshot.casing_speed_multiplier = snapshot.walk_speed_multiplier
        state._low_ready_project_preferences = snapshot
    end
    return state._low_ready_project_preferences
end
local function shallow_copy(source)
    local result = {}

    for key, value in pairs(source) do
        result[key] = value
    end

    return result
end

-- Only the two explicitly supported movement-state classes receive Low Ready.
-- CoreClass instantiates PlayerCarry with PlayerCarry (not PlayerStandard) as
-- its instance metatable, although it inherits PlayerStandard's methods.
-- Do not extend to arbitrary subclasses (mask_off, incapacitated, etc.).
local function supported_movement_state(state)
    if type(state) ~= "table" then
        return false
    end

    local class = getmetatable(state)
    return class == PlayerStandard
        or (type(PlayerCarry) == "table" and class == PlayerCarry)
end

-- Casing is a distinct PlayerStandard subclass. It inherits the standard
-- speed calculation but must receive only its own walk multiplier. This
-- intentionally does NOT authorize Casing for the running headbob hook.
local function apply_casing_speed_settings(state)
    local casing_multiplier = instance_settings(state).walk_speed_multiplier
    if casing_multiplier == 1 or _G.IS_VR
        or type(Global) ~= "table" or type(Global.game_settings) ~= "table"
        or Global.game_settings.single_player ~= true then
        return
    end

    local source = state._tweak_data

    if type(source) ~= "table" or source == state._low_ready_speed_tweak then
        return
    end

    local movement = source.movement
    if type(movement) ~= "table" or type(movement.multiplier) ~= "table" then
        diagnostic_once("casing_invalid_movement_data")
        return
    end

    local original_walk = movement.multiplier.walk
    if original_walk == nil then
        original_walk = 1
    end

    local adjusted_walk = original_walk * casing_multiplier
    if not is_positive_finite(original_walk)
        or not is_positive_finite(adjusted_walk) then
        diagnostic_once("casing_invalid_walk_factor")
        return
    end

    -- Per-instance copy: global tweaks, run/crouch, jump, camera and
    -- other subclasses remain untouched; no stacked application.
    local custom = shallow_copy(source)
    custom.movement = shallow_copy(movement)
    custom.movement.multiplier = shallow_copy(movement.multiplier)
    custom.movement.multiplier.walk = adjusted_walk
    state._low_ready_speed_tweak = custom
    state._tweak_data = custom

    diagnostic_once("casing_speed_applied",
        "walk_original", original_walk,
        "casing_configured", casing_multiplier,
        "walk_result", adjusted_walk)
end

local function apply_speed_settings(state)
    local settings = instance_settings(state)
    local walk_multiplier, run_multiplier, crouch_multiplier = settings.walk_speed_multiplier, settings.run_speed_multiplier, settings.crouch_speed_multiplier
    -- PlayerMaskOff calls the inherited PlayerStandard:init / reload methods.
    -- Handle only this exact subclass before the Standard/Carry allowlist.
    if type(state) == "table" and type(PlayerMaskOff) == "table"
        and getmetatable(state) == PlayerMaskOff then
        return apply_casing_speed_settings(state)
    end

    -- Preserve the original class and offline guards for every state.
    if _G.IS_VR or not supported_movement_state(state)
        or not Global or not Global.game_settings
        or Global.game_settings.single_player ~= true then
        diagnostic_once("callback_ineligible_context_or_class")
        return
    end

    local source = state._tweak_data

    if type(source) ~= "table" or source == state._low_ready_speed_tweak then
        if type(source) ~= "table" then
            diagnostic_once("callback_invalid_tweak_data")
        end
        return
    end

    local movement = source.movement

    if type(movement) ~= "table" or type(movement.multiplier) ~= "table" then
        diagnostic_once("callback_invalid_movement_data")
        return
    end

    local original_walk = movement.multiplier.walk
    local original_run = movement.multiplier.run
    local original_crouch = movement.multiplier.crouch

    if original_walk == nil then
        original_walk = 1
    end

    if original_run == nil then
        original_run = 1
    end

    if original_crouch == nil then
        original_crouch = 1
    end

    if not is_positive_finite(original_walk) or not is_positive_finite(original_run) then
        diagnostic_once("callback_invalid_original_factors")
        return
    end

    local walk = original_walk * walk_multiplier
    local run = original_run * run_multiplier

    local crouch = original_crouch

    if crouch_multiplier ~= 1 then
        if not is_positive_finite(original_crouch) then
            diagnostic_once("callback_invalid_original_factors")
            return
        end

        crouch = original_crouch * crouch_multiplier

        if not is_positive_finite(crouch) then
            diagnostic_once("callback_invalid_result")
            return
        end
    end

    if not is_positive_finite(walk) or not is_positive_finite(run) then
        diagnostic_once("callback_invalid_result")
        return
    end

    -- Copy only the path being edited. Speed limits and jump data stay shared
    -- and unchanged; the original speed calculation still handles modifiers,
    -- its cache and its network notification.
    local custom = shallow_copy(source)
    custom.movement = shallow_copy(movement)
    custom.movement.multiplier = shallow_copy(movement.multiplier)
    custom.movement.multiplier.walk = walk
    custom.movement.multiplier.run = run

    if crouch_multiplier ~= 1 then
        custom.movement.multiplier.crouch = crouch
    end

    state._low_ready_speed_tweak = custom
    state._tweak_data = custom
    diagnostic_once("applied",
        "walk_original", original_walk,
        "walk_configured", walk_multiplier,
        "walk_result", walk,
        "run_original", original_run,
        "run_configured", run_multiplier,
        "run_result", run,
        "crouch_original", original_crouch,
        "crouch_configured", crouch_multiplier,
        "crouch_result", crouch)

    if type(PlayerCarry) == "table" and getmetatable(state) == PlayerCarry then
        diagnostic_once("carry_speed_applied",
            "walk", walk, "run", run, "crouch", crouch)
    end
end

local function scale_run_headbob_return(headbob_multiplier, ...)
    local count = select("#", ...)
    local current = ...

    if count ~= 1 or not (current == 0 or is_positive_finite(current)) then
        if not diagnostic_seen.run_headbob_return_rejected then
            diagnostic_once("run_headbob_return_rejected",
                "count", count, "first_type", type(current))
        end
        return
    end

    local adjusted = current * headbob_multiplier

    if not (adjusted == 0 or is_positive_finite(adjusted)) then
        if not diagnostic_seen.run_headbob_result_rejected then
            diagnostic_once("run_headbob_result_rejected")
        end
        return
    end

    if not diagnostic_seen.run_headbob_applied then
        diagnostic_once("run_headbob_applied",
            "current", current, "multiplier", headbob_multiplier,
            "result", adjusted)
    end

    return adjusted
end

local function apply_run_headbob(state)
    local headbob_multiplier = instance_settings(state).run_headbob_multiplier
    if headbob_multiplier == 1 or _G.IS_VR
        or not supported_movement_state(state)
        or type(Global) ~= "table" or type(Global.game_settings) ~= "table"
        or Global.game_settings.single_player ~= true then
        return
    end

    local state_data = state._state_data

    if type(state_data) ~= "table" then
        if not diagnostic_seen.run_headbob_invalid_state_data then
            diagnostic_once("run_headbob_invalid_state_data")
        end
        return
    end

    if not state._running or state_data.using_bipod
        or state_data.in_steelsight or state_data.in_air or state_data.ducking then
        return
    end

    local result = scale_run_headbob_return(headbob_multiplier, Hooks:GetReturn())

    if result ~= nil and type(PlayerCarry) == "table"
        and getmetatable(state) == PlayerCarry then
        diagnostic_once("carry_run_headbob_applied", "result", result)
    end

    return result
end

do
    Hooks:PostHook(PlayerStandard, "init", "LowReady_InitializeSpeedSettings", apply_speed_settings)
    Hooks:PostHook(PlayerStandard, "tweak_data_clbk_reload", "LowReady_ReloadSpeedSettings", apply_speed_settings)
    diagnostic_once("posthook_calls_completed")
end

do
    if type(Hooks.GetReturn) ~= "function"
        or type(PlayerStandard._get_walk_headbob) ~= "function" then
        diagnostic_once("run_headbob_api_unavailable")
    else
        Hooks:PostHook(PlayerStandard, "_get_walk_headbob",
            "LowReady_AdjustRunHeadbob", apply_run_headbob)
        diagnostic_once("run_headbob_posthook_call_completed")
    end
end

return true
end
return M
