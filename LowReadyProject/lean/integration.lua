-- Coordinator: one intent, conservative shared gates, no partial activation.
local M = {}
local PREFIX = "[LowReadyLeanV3] "
local function finite(n) return type(n) == "number" and n == n and math.abs(n) < math.huge end
local function call(object, name, ...)
	local fn = object and object[name]
	if type(fn) ~= "function" then error("api_unavailable", 0) end
	return fn(object, ...)
end
local function weak() return setmetatable({}, { __mode = "v" }) end
local function valid_config(c)
	if type(c) ~= "table" or type(c.enabled) ~= "boolean" then return end
	if c.max_angle_degrees ~= 7 or c.time_constant_seconds ~= 0.18 or c.offset_distance ~= 25 then return end
	if c.lean_mode ~= "hold" and c.lean_mode ~= "toggle" then return end
	if c.effects ~= "tilt" and c.effects ~= "lateral" and c.effects ~= "combined" then return end
	if type(c.left_key) ~= "string" or c.left_key == "" or type(c.right_key) ~= "string" or c.right_key == "" then return end
	local left, right = string.lower(c.left_key), string.lower(c.right_key)
	if left == right then return end
	return { enabled = c.enabled, left_key = left, right_key = right, lean_mode = c.lean_mode,
		effects = c.effects, max_angle_degrees = 7, time_constant_seconds = 0.18, offset_distance = 25 }
end
function M.new(engine, ps, fp, pc, configuration, modules)
	local config = valid_config(configuration)
	if not config or type(engine) ~= "table" or type(ps) ~= "table" or type(fp) ~= "table" or type(pc) ~= "table" then
		return nil, "invalid_configuration_or_classes"
	end
	local hooks = engine.Hooks
	if type(hooks) ~= "table" then return nil, "hooks_unavailable" end
	for _, name in ipairs({"GetFunction", "OverrideFunction", "PreHook", "PostHook"}) do
		if type(hooks[name]) ~= "function" then return nil, "hooks_unavailable" end
	end
	local ready, attempted, disabled, registration_busy = false, false, false, false
	local processing, flushing, depth = false, false, 0
	local generation, publication = 0, nil
	local identities, cycle = weak(), weak()
	local events, reported, specifications = {}, {}, {}
	local state_public, state_previous = {}, {}
	local lateral, tilt, controls
	local restore_requested = false
	local returning = false
	local lateral_offset, lateral_returning = 0, false
	local api = {}
	-- Menu preferences do not reinstall hooks or replace the effect machines.
	local runtime_enabled, pending_preferences = config.enabled, nil
	local tilt_enabled, lateral_enabled = config.effects ~= "lateral", config.effects ~= "tilt"
	local function note(event) events[event] = true end
	local function flush()
		if processing or registration_busy or flushing or depth ~= 0 or (lateral and lateral.busy()) then return end
		flushing = true
		local pending = events; events = {}
		for event in pairs(pending) do
			if not reported[event] then
				reported[event] = true
				pcall(function() if type(engine.log) == "function" then engine.log(PREFIX .. event) end end)
			end
		end
		flushing = false
	end
	local function cancel(reason)
		returning = false
		lateral_offset, lateral_returning = 0, false
		generation, publication = generation + 1, nil
		controls.cancel()
		restore_requested = tilt_enabled
		if reason then note("INTENT_CANCELLED category=" .. reason) end
	end
	local function fault(reason, partial)
		local effects = partial or tilt.has_effect()
		cancel(reason)
		note((effects and "FAILED_AFTER_POSSIBLE_EFFECTS" or "FAILED_BEFORE_WRITES") .. " category=" .. reason)
		if effects or reason == "OVERRIDE_OWNERSHIP" or reason == "HOOK_OWNERSHIP" then
			disabled = true; note("ADAPTATION_DISABLED")
		end
	end
	local function fatal(reason)
		fault(reason, true)
	end
	controls = modules.controls.new(engine, config, note)
	tilt = modules.tilt.new(config, note)
	local function conflict()
		for _, key in ipairs({"__LowReadyLeanV2_62D4A17C", "__LowReadyLateralProof_20261026", "__LowReadyLateralArgumentsProof_20261028"}) do
			if rawget(engine, key) ~= nil then return true end
		end
		return false
	end
	local function hook_owned(spec)
		local object = hooks._function_hooks and hooks._function_hooks[ps]
		local data = object and object[spec.method]
		local list = data and data.overrides and data.overrides[spec.kind]
		if type(list) ~= "table" then return false end
		local count = 0
		for _, entry in ipairs(list) do
			if entry.id == spec.id then
				if entry.func ~= spec.fn then return false end
				count = count + 1
			end
		end
		return count == 1
	end
	local function ownership()
		for _, spec in ipairs(specifications) do
			if not hook_owned(spec) or ps[spec.method] ~= state_public[spec.method]
				or hooks:GetFunction(ps, spec.method) ~= state_previous[spec.method] then return false end
		end
		return lateral.owned()
	end
	local function check_ownership()
		local ok, owned = pcall(ownership)
		if not ok or not owned then fatal("HOOK_OWNERSHIP"); return false end
		if conflict() then fatal("CONCURRENT_PROOF"); return false end
		return true
	end
	-- Identity lookup also serves safe target restoration outside the gates.
	local function context(state)
		local player = call(engine.managers.player, "player_unit")
		if not player or rawget(state, "_unit") ~= player then return end
		local camera = call(player, "camera")
		if rawget(state, "_ext_camera") ~= camera then return end
		local unit = call(camera, "camera_unit")
		if not unit or engine.alive(unit) ~= true then return end
		local base = call(unit, "base")
		if not base or rawget(base, "_parent_unit") ~= player or rawget(base, "_unit") ~= unit
			or call(camera, "camera_unit") ~= unit or call(unit, "base") ~= base then return end
		return { player = player, camera = camera, unit = unit, base = base, state = state }
	end
	-- A normal timed interaction uses native camera limits (spin=80, pitch=50).
	-- Permit a voluntary neutral tail under ONLY that exact, active interaction
	-- contract. All other restricted camera modes retain the original fail-closed
	-- policy: no generic bypass of _limits, _block_input or _animate_pitch.
	local function return_camera_safe(base, state)
		if rawget(base, "_animate_pitch") ~= nil then return false end
		local block = rawget(base, "_block_input")
		if block ~= nil and block ~= false then return false end
		local limits = rawget(base, "_limits")
		if limits == nil then return true end
		if type(limits) ~= "table" or getmetatable(limits) ~= nil then return false end
		if next(limits) == nil then return true end
		-- Never authorize foreign/partial/cinematic limits based on their shape
		-- alone. The player must currently own a native timed interaction.
		if type(state) ~= "table" or not finite(rawget(state, "_interact_expire_t"))
			or rawget(state, "_interact_expire_t") <= 0 then return false end
		local params = rawget(state, "_interact_params")
		if type(params) ~= "table" or rawget(params, "object") == nil
			or not finite(rawget(params, "timer")) or rawget(params, "timer") <= 0 then return false end
		local spin, pitch = rawget(limits, "spin"), rawget(limits, "pitch")
		if type(spin) ~= "table" or getmetatable(spin) ~= nil
			or type(pitch) ~= "table" or getmetatable(pitch) ~= nil then return false end
		if rawget(spin, "offset") ~= 80 or rawget(pitch, "offset") ~= 50
			or not finite(rawget(spin, "mid")) or not finite(rawget(pitch, "mid")) then return false end
		for key in pairs(limits) do if key ~= "spin" and key ~= "pitch" then return false end end
		for key in pairs(spin) do if key ~= "mid" and key ~= "offset" then return false end end
		for key in pairs(pitch) do if key ~= "mid" and key ~= "offset" then return false end end
		return true
	end
	local function eligible(c, t, return_only)
		if not runtime_enabled then return false end
		if return_only and (not return_camera_safe(c.base, c.state)
			or (return_only == true and not tilt_enabled)
			or (return_only == "lateral" and not lateral_enabled)) then return false end
		if engine.IS_VR or not engine.Global or not engine.Global.game_settings
			or engine.Global.game_settings.single_player ~= true then return false end
		local managers, state = engine.managers, c.state
		local state_name = call(managers.player, "current_state")
		if (state_name ~= "standard" and state_name ~= "carry") or engine.alive(c.player) ~= true
			or call(call(c.player, "movement"), "current_state") ~= state then return false end
		-- PlayerCarry inherits PlayerStandard's hooked update but owns a native -5 degree
		-- camera tilt. Fail closed if its inheritance or tilt contract differs.
		if state_name == "carry" and (type(engine.PlayerCarry) ~= "table"
			or engine.PlayerCarry.super ~= ps or engine.PlayerCarry.target_tilt ~= -5) then return false end
		c.carry = state_name == "carry"
		if call(state._controller, "enabled") ~= true then return false end
		if call(engine.Application, "paused") ~= false or call(managers.menu, "active_menu")
			or call(managers.hud, "chat_focus") then return false end
		local component = managers.menu_component
		if component and type(component.input_focut_game_chat_gui) == "function"
			and component:input_focut_game_chat_gui() then return false end
		local data = rawget(state, "_state_data")
		if type(data) ~= "table" or data.on_zipline or data.zipline_data or data.on_ladder then return false end
		local air, method_air, ads = data.in_air, call(state, "in_air"), call(state, "in_steelsight")
		if ads ~= rawget(data, "in_steelsight")
			or (ads ~= nil and ads ~= false and ads ~= true) then return false end
		local jump_started = finite(t) and rawget(state, "_jump_t") == t
		local locomotion_blocked = air == true or method_air == true or jump_started
		if return_only then
			if (air ~= nil and type(air) ~= "boolean")
				or (method_air ~= nil and type(method_air) ~= "boolean") then return false end
			if not rawget(state, "_gnd_ray") and not (locomotion_blocked
				or rawget(state, "_is_jumping") == true) then return false end
		elseif (air ~= nil and air ~= false) or (method_air ~= nil and method_air ~= false)
			or not rawget(state, "_gnd_ray") then return false end
		-- A native run-stop animation keeps _running true until its timer ends.
		-- Authorize a NEW lean during that bounded exit, not during active sprint.
		-- Do not modify native running flags/timers or bypass camera safety gates.
		local run_exit_t = rawget(state, "_end_running_expire_t")
		local run_exit = not return_only and rawget(state, "_running") == true
			and (rawget(state, "_running_wanted") == nil or rawget(state, "_running_wanted") == false)
			and finite(t) and finite(run_exit_t) and run_exit_t >= t
			and run_exit_t - t <= 2 and return_camera_safe(c.base, c.state)
		local sprint_blocked = false
		for _, key in ipairs({"_running", "_running_wanted", "_is_jumping"}) do
			local value = rawget(state, key)
			if value ~= nil and value ~= false then
				if (not return_only or value ~= true) and not (key == "_running" and run_exit) then
					if not return_only and (key == "_running" or key == "_running_wanted") and value == true then
						sprint_blocked = true
					else return false end
				end
				locomotion_blocked = true
			end
		end
		if jump_started and not return_only then return false end
		if sprint_blocked then return false, "SPRINT_ACTIVE" end
		if run_exit then note("SPRINT_EXIT_WINDOW_ELIGIBLE") end
		return not return_only or locomotion_blocked
	end
	local function matches(c)
		return identities[1] == c.player and identities[2] == c.camera and identities[3] == c.unit
			and identities[4] == c.base and identities[5] == c.state
	end
	local had_identity = false
	local function remember(c)
		identities[1], identities[2], identities[3], identities[4], identities[5] = c.player, c.camera, c.unit, c.base, c.state
		had_identity = true
	end
	local function cleanup(c)
		if not restore_requested or not tilt_enabled or lateral.busy() or tilt.busy() then return end
		local restore_generation = generation
		local ok, reason, attempted_write = tilt.restore(c, function()
			return generation == restore_generation and depth == 0 and not lateral.busy()
		end)
		if ok then restore_requested = false
		else
			note(reason)
			if attempted_write then fatal(reason) end
		end
	end
	local function return_permitted(c, t, expected_generation, return_only)
		if disabled or generation ~= expected_generation or depth ~= 0 or lateral.busy() or flushing then return false end
		local current = context(c.state)
		if not current or not matches(current) or current.base ~= c.base or current.unit ~= c.unit
			or not eligible(current, t, return_only) or not check_ownership() then return false end
		-- Gates may call reentrant APIs. Confirm identity and target after them.
		current = context(c.state)
		-- This fresh context does not inherit `carry` from the prior validated
		-- context. Revalidate it before asking Tilt to compare native baselines.
		-- No permission is relaxed; a changed game state still fails closed.
		if not current or not matches(current) or current.base ~= c.base or current.unit ~= c.unit
			or not return_camera_safe(current.base, current.state)
			or not eligible(current, t, return_only) then return false end
		local properties = rawget(current.base, "_camera_properties")
		local ok, observed_target = tilt.available(current)
		if not ok then return false end
		-- One bounded revalidation; no target getter is called after it.
		current = context(c.state)
		if not current or not matches(current) or current.base ~= c.base or current.unit ~= c.unit
			or not check_ownership() then return false end
		return tilt.status().owned and not disabled and generation == expected_generation
			and depth == 0 and not lateral.busy() and not flushing
			and type(properties) == "table"
			and rawequal(rawget(c.base, "_camera_properties"), properties)
			and rawget(properties, "target_tilt") == observed_target
			and rawget(c.state, "_unit") == c.player and rawget(c.state, "_ext_camera") == c.camera
			and rawget(c.base, "_parent_unit") == c.player and rawget(c.base, "_unit") == c.unit
			and return_camera_safe(c.base, c.state)
	end
	local function authorize(base)
		if not ready or not config.enabled or disabled or flushing or processing or depth ~= 0
			or not lateral_enabled or not publication then return end
		local published = publication
		if not check_ownership() then return end
		local state = identities[5]
		local c = state and context(state)
		if not c or c.base ~= base or not matches(c) or not eligible(c, published.t, published.return_only)
			or (published.tail and not return_camera_safe(c.base, c.state)) then cancel("INELIGIBLE"); return end
		local properties, observed
		if tilt_enabled then
			properties = rawget(c.base, "_camera_properties")
			local ok, value = tilt.available(c)
			if not ok then
				-- A target read can call foreign Lua. Recheck hook ownership
				-- before classifying a failed read as an ordinary cancellation.
				if not check_ownership() then return end
				cancel(value)
				return
			end
			observed = value
		end
		-- Bounded final revalidation after extensible gates/target reads.
		local current = context(state)
		if not current or not matches(current) or current.base ~= base or not check_ownership() then return end
		if publication ~= published or disabled or generation ~= published.generation or depth ~= 0 or processing or flushing
			or rawget(state, "_unit") ~= current.player or rawget(state, "_ext_camera") ~= current.camera
			or rawget(base, "_parent_unit") ~= current.player or rawget(base, "_unit") ~= current.unit
			or (published.tail and not return_camera_safe(base, state)) then return end
		if tilt_enabled and (type(properties) ~= "table" or not rawequal(rawget(base, "_camera_properties"), properties)
			or rawget(properties, "target_tilt") ~= observed) then return end
		return current, { direction = published.direction, generation = published.generation, offset = published.offset }
	end
	local function next_lateral(prior, direction, dt)
		local desired = direction * config.offset_distance
		local value = prior + (desired - prior) * (1 - math.exp(-dt / config.time_constant_seconds))
		if math.abs(desired - value) <= 0.05 then value = desired end
		return value
	end
	lateral = modules.lateral.new(engine, fp, pc, config.offset_distance, {
		note = note, fault = fault, flush = flush, authorize = authorize,
		enabled = function() return ready and config.enabled and not disabled and not flushing and lateral_enabled end
	})
	local function local_state(state)
		return type(state) == "table" and rawget(state, "_unit") == call(engine.managers.player, "player_unit")
	end
	local function before_update(state)
		if not ready or not config.enabled then return end
		if not local_state(state) then
			if returning and identities[5] == state then cancel("IDENTITY") end
			return
		end
		if flushing then fatal("CONTROL_DURING_LOGGING"); return end
		generation, publication = generation + 1, nil
		if processing or depth ~= 0 or lateral.busy() or tilt.busy() then
			fatal("CONTROL_REENTRY_OR_UNFINISHED")
			lateral.invalidate("CONTROL_INTERLEAVE")
		end
		depth = depth + 1
		if depth == 1 then cycle[1] = state end
	end
	local function control_update(state, t, dt)
		if pending_preferences then
			local next_config = pending_preferences
			pending_preferences = nil
			config.left_key, config.right_key, config.lean_mode = next_config.left_key, next_config.right_key, next_config.lean_mode
			runtime_enabled = next_config.enabled
			controls = modules.controls.new(engine, config, note)
			controls.cancel() -- Require release before a fresh edge, including Hold.
		end
		local c = context(state)
		if not c then cancel("IDENTITY"); cleanup(nil); return end
		if had_identity and not matches(c) then cancel("IDENTITY_CHANGED") end
		remember(c)
		if disabled or not check_ownership() then cleanup(c); return end
		if not runtime_enabled then cleanup(c); return end
		if not finite(dt) or dt <= 0 then cancel("DT_INVALID"); cleanup(c); return end
		local input_allowed, blocked_reason = eligible(c, t)
		if not input_allowed then
			local may_tilt = tilt_enabled and not restore_requested and tilt.status().owned
			local prior = lateral_offset
			local may_lateral = lateral_enabled and prior ~= 0 and not restore_requested
			cancel("INELIGIBLE")
			-- A locomotion-only gate may authorize an already-owned visual return.
			-- Neither effect is allowed to reactivate the cancelled logical intent.
			if (may_tilt or may_lateral) and eligible(c, t, may_tilt and true or "lateral") then
				local captured = generation
				if may_tilt then
					local ok, reason, attempted_write = tilt.step(c, 0, dt, function()
						return return_permitted(c, t, captured, true)
					end)
					if not ok then
						if attempted_write then fatal(reason) else
							cancel(reason)
							-- Reentrant invalidation leaves the target owned but the
							-- current return lease unusable. Mark a pending restoration
							-- without reading the camera or attempting another write.
							if disabled and tilt.status().owned then
								tilt.restore(nil, function() return false end)
							end
						end
						-- Never retry a failed owned tilt write through this return context.
						return
					end
					if disabled or generation ~= captured or depth ~= 0 then return end
					restore_requested = false
					returning = tilt.status().owned
				else
					-- Only the lateral effect is returning; keep the old defensive
					-- policy for any independently pending tilt restoration.
					cleanup(c)
					if disabled or restore_requested then return end
				end
				if may_lateral then
					local current = context(state)
					if not disabled and generation == captured and depth == 0 and current and matches(current)
						and eligible(current, t, "lateral") and check_ownership() then
						local final = context(state)
						if not disabled and generation == captured and depth == 0 and final and matches(final)
							and return_camera_safe(final.base, final.state) then
							lateral_offset = next_lateral(prior, 0, dt)
							lateral_returning = lateral_offset ~= 0
							if lateral_returning then
								publication = { direction = 0, generation = captured, t = t, offset = lateral_offset,
									return_only = "lateral", tail = true }
							end
						end
					end
				end
			else
				cleanup(c)
			end
			-- Observe only if active sprint is the sole gate failure.
			-- Never accept intent or write camera state from this observation.
			if blocked_reason == "SPRINT_ACTIVE" and not disabled and depth == 0
				and not lateral.busy() and not tilt.busy() and return_camera_safe(c.base, c.state) then
				local ok, observed = pcall(controls.observe_sprint)
				if not ok then fatal("SPRINT_KEYBOARD_OBSERVATION")
				elseif observed then note("SPRINT_INPUT_BASELINE_OBSERVED") end
			end
			return
		end
		if (returning or lateral_returning) and not return_camera_safe(c.base, c.state) then
			cancel("RETURN_CAMERA_RESTRICTED"); cleanup(c); return
		end
		cleanup(c)
		if restore_requested or disabled then return end
		local captured_generation = generation
		local continuing_return = returning
		local function permitted()
			if continuing_return then return return_permitted(c, t, captured_generation, false) end
			return not disabled and generation == captured_generation and depth == 0
		end
		if tilt_enabled then
			local ok, reason = tilt.available(c)
			if not ok then cancel(reason); cleanup(c); return end
		end
		note("CONTEXT_ELIGIBLE")
		local direction, reason = controls.sample()
		if direction == nil then note("DEPENDENCY_UNAVAILABLE category=" .. reason); cancel(reason); cleanup(c); return end
		if not permitted() then
			if continuing_return then cancel("TILT_CONTEXT_CHANGED") end
			return
		end
		if tilt_enabled then
			local ok, failure, attempted_write = tilt.step(c, direction, dt, permitted)
			if not ok then
				if attempted_write then fatal(failure) else cancel(failure) end
				if not continuing_return then cleanup(c) end
				return
			end
		end
		-- Native setters can reenter Lua. Never publish a generation invalidated there.
		local current = context(state)
		if disabled or captured_generation ~= generation or depth ~= 0 then return end
		if not current or not matches(current) or not eligible(current, t) or not check_ownership() then
			cancel("PUBLICATION_CHANGED")
			if not continuing_return then cleanup(current) end
			return
		end
		if continuing_return then
			if disabled or captured_generation ~= generation or depth ~= 0 then return end
			if direction == 0 then
				returning = tilt.status().owned
				if lateral_enabled and lateral_offset ~= 0 then
					lateral_offset = next_lateral(lateral_offset, 0, dt)
					lateral_returning = lateral_offset ~= 0
					if lateral_returning then
						publication = { direction = 0, generation = generation, t = t,
							offset = lateral_offset, tail = true }
					end
				end
				return
			end
		end
		returning = false
		if lateral_enabled then lateral_offset = next_lateral(lateral_offset, direction, dt) end
		lateral_returning = lateral_enabled and direction == 0 and lateral_offset ~= 0
		publication = { direction = direction, generation = generation, t = t, offset = lateral_offset, tail = lateral_returning }
		if lateral_enabled and direction ~= 0 and math.abs(lateral_offset) >= config.offset_distance - 0.05 then
			note("LATERAL_TARGET_REACHED")
		end
		note("INTENT_PUBLISHED")
	end
	local function after_update(state, t, dt)
		if not ready or not config.enabled or flushing then return end
		if cycle[1] ~= state then
			if local_state(state) then fatal("CONTROL_UNPAIRED_POST") end
			return
		end
		if depth > 1 then depth = depth - 1; return end
		if depth ~= 1 then fatal("CONTROL_UNPAIRED_POST"); return end
		depth, cycle[1] = 0, nil
		if processing or lateral.busy() or tilt.busy() then fatal("CONTROL_REENTRY"); return end
		processing = true
		local ok = pcall(control_update, state, t, dt)
		if not ok then fault("CONTROL_API", false) end
		processing = false
		flush()
	end
	local function on_exit(state)
		if not ready or not config.enabled or not local_state(state) then return end
		cancel("STATE_EXIT")
		lateral.invalidate("STATE_EXIT")
		if not flushing and not processing and not lateral.busy() and not tilt.busy() then
			processing = true
			local ok, c = pcall(context, state)
			cleanup(ok and c or nil)
			processing = false
		end
	end
	local function guarded(fn)
		return function(...)
			local ok = pcall(fn, ...)
			if not ok then fatal("CONTROL_CALLBACK") end
			flush()
			-- Never replace original returns through a hook return value.
		end
	end
	specifications = {
		{method = "update", kind = "pre", id = "LowReadyLeanV3_Begin", fn = guarded(before_update)},
		{method = "update", kind = "post", id = "LowReadyLeanV3_Publish", fn = guarded(after_update)},
		{method = "exit", kind = "pre", id = "LowReadyLeanV3_Exit", fn = guarded(on_exit)}
	}
	function api.install()
		if ready then return true end
		if attempted or registration_busy or processing or depth ~= 0 or lateral.busy() then return false end
		attempted, registration_busy = true, true
		local ok = pcall(function()
			if conflict() then error("conflicting_proof", 0) end
			for _, method in ipairs({"update", "exit"}) do
				if type(ps[method]) ~= "function" then error("state_method_unavailable", 0) end
				state_previous[method] = hooks:GetFunction(ps, method)
			end
			if type(fp.set_target_tilt) ~= "function" then error("tilt_method_unavailable", 0) end
			-- Capture/register with effects inactive. Validate actual callbacks, not pcall alone.
			if not lateral.install() then error("lateral_installation_failed", 0) end
			for _, spec in ipairs(specifications) do
				local register = spec.kind == "pre" and hooks.PreHook or hooks.PostHook
				register(hooks, ps, spec.method, spec.id, spec.fn)
				if not hook_owned(spec) then error("hook_unconfirmed", 0) end
			end
			state_public.update, state_public.exit = ps.update, ps.exit
			if not ownership() or not lateral.activate() then error("installation_unconfirmed", 0) end
		end)
		registration_busy = false
		ready = ok
		note(ok and "READY" or "REGISTRATION_FAILED")
		flush()
		return ok
	end
	function api.configure(preferences)
		if type(preferences) ~= "table" then return false end
		local candidate = {}
		for key, value in pairs(config) do candidate[key] = value end
		for _, key in ipairs({"enabled", "left_key", "right_key", "lean_mode"}) do candidate[key] = preferences[key] end
		candidate = valid_config(candidate)
		if not candidate then return false end
		pending_preferences = candidate
		cancel("PREFERENCES_CHANGED")
		-- Publication is invalidated immediately; pending state is committed only
		-- at the next safe logical update. Never write through a reentrant setter.
		if not processing and not flushing and depth == 0 and not lateral.busy() and not tilt.busy() then
			local state = identities[5]
			if state then
				processing = true
				local ok, c = pcall(context, state)
				cleanup(ok and c or nil)
				processing = false
			end
		end
		return true
	end
	function api.status()
		return { ready = ready, disabled = disabled, generation = generation,
			returning = returning, lateral_offset = lateral_offset, lateral_returning = lateral_returning,
			published = publication ~= nil, direction = publication and publication.direction or 0,
			control_pending = depth ~= 0, tilt = tilt.status(), effects = config.effects }
	end
	return api
end
return M
