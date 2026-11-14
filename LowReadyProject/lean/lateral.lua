-- Paired-argument adapter derived from the frozen Lateral Arguments Proof.
-- bridge owns controls, gates and joint failure policy. No keyboard reads here.
local M = {}
local function pack(...) return { n = select("#", ...), ... } end
local function sample(v)
	local x, y, z = v.x, v.y, v.z
	for _, n in ipairs({x, y, z}) do
		if type(n) ~= "number" or n ~= n or math.abs(n) == math.huge then error("invalid_vector", 0) end
	end
	if x == nil or y == nil or z == nil then error("invalid_vector", 0) end
	return { x = x, y = y, z = z }
end
local function same(v, s) return v.x == s.x and v.y == s.y and v.z == s.z end
function M.new(engine, fp, pc, distance, bridge)
	local hooks, entries, stack = engine.Hooks, {}, {}
	local active, attempted, installed, registration_busy = false, false, false, false
	local calls, adapter_depth = 0, 0
	-- Diagnostic counters are local and bounded; never alter camera geometry.
	local delivered_pairs = 0
	local api = {}
	local function note(event) bridge.note(event) end
	local function reject(reason)
		local partial = false
		for _, frame in ipairs(stack) do
			frame.bad = true
			if frame.effects or (frame.pair and frame.pair.started) then partial = true end
		end
		note("PAIR_REFUSED category=" .. reason)
		bridge.fault(reason, partial)
		return partial
	end
	local function owned()
		for _, entry in ipairs(entries) do
			if hooks:GetFunction(entry.class, entry.name) ~= entry.wrapper
				or entry.class[entry.name] ~= entry.public then return false end
		end
		return installed
	end
	function api.owned()
		local ok, result = pcall(owned)
		return ok and result == true
	end
	function api.busy() return calls ~= 0 or registration_busy end
	function api.invalidate(reason) if calls ~= 0 then reject(reason) end end
	local function usable()
		if not active or not bridge.enabled() then return false end
		if not api.owned() then bridge.fault("OVERRIDE_OWNERSHIP", true); return false end
		return true
	end
	local function begin(frame)
		local parent = stack[#stack]
		frame.parent, frame.phase = parent, "OPEN"
		if parent then
			local movement = frame.kind == "movement" and parent.kind == "update"
				and parent.base == frame.base and not parent.movement_seen and parent.phase == "OPEN"
			local rotation = frame.kind == "rotation" and parent.kind == "update"
				and parent.base == frame.base and (parent.phase == "OPEN" or parent.phase == "DONE")
			if adapter_depth > 0 or parent.bad or not (movement or rotation) then
				reject("REENTRY_OR_INTERLEAVE"); frame.bad = true
			end
			if movement then parent.movement_seen = true; parent.phase = "MOVEMENT" end
		elseif frame.kind == "movement" then frame.bad = true end
		stack[#stack + 1] = frame
	end
	local function finish(frame, success)
		if not success then reject("ORIGINAL_EXCEPTION") end
		local pair = frame.pair
		if frame.kind == "movement" and not frame.bad and success and frame.parent then
			frame.parent.pair, frame.parent.phase = pair, "WAIT_HEAD"
		elseif pair and pair.started and pair.stage ~= "CONSUMED" then reject("INCOMPLETE_PAIR") end
		assert(stack[#stack] == frame, "scope_order")
		stack[#stack] = nil
	end
	local function flush() bridge.flush() end
	local function scope(entry, kind, base, ...)
		calls = calls + 1
		local frame = { kind = kind, base = base }
		local ok = pcall(begin, frame)
		if not ok then reject("CONTEXT_SETUP"); frame.bad = true end
		local result = pack(pcall(entry.previous, base, ...))
		local closed = pcall(finish, frame, result[1])
		if not closed then reject("CONTEXT_CLEANUP"); stack = {}; bridge.fault("CONTEXT_CLEANUP", true) end
		calls = calls - 1
		flush()
		if not result[1] then error(result[2], 0) end
		return unpack(result, 2, result.n)
	end
	local function prepare_rig(base, position)
		local frame = stack[#stack]
		if not frame then return end
		if adapter_depth > 1 then reject("REENTRANT_SETTER"); return end
		if frame.bad or not usable() then return end
		if frame.base ~= base or (frame.kind ~= "movement" and frame.kind ~= "rotation") then
			reject("RIG_CONTEXT"); return
		end
		if frame.rig_seen then reject("DUPLICATE_RIG"); return end
		frame.rig_seen = true
		local owners, intent = bridge.authorize(base)
		if not owners then frame.bad = true; note("PAIR_REFUSED category=INELIGIBLE"); return end
		local sign = intent.direction
		local offset = intent.offset
		if type(offset) ~= "number" or offset ~= offset or math.abs(offset) > distance then error("invalid_offset", 0) end
		if offset == 0 then return end
		local output = rawget(base, "_output_data")
		local head = output.position
		local h, s = sample(head), sample(position)
		local right = sample(output.rotation:x())
		local length = math.sqrt(right.x * right.x + right.y * right.y)
		if length ~= length or length <= 0 or length == math.huge then error("invalid_axis", 0) end
		local dx, dy = right.x / length * offset, right.y / length * offset
		local shifted_head = engine.Vector3(h.x + dx, h.y + dy, h.z)
		local shifted_rig = engine.Vector3(s.x + dx, s.y + dy, s.z)
		sample(shifted_head); sample(shifted_rig)
		if rawequal(shifted_head, head) or rawequal(shifted_head, position)
			or rawequal(shifted_rig, head) or rawequal(shifted_rig, position)
			or rawequal(shifted_head, shifted_rig) then error("vector_alias", 0) end
		local current, current_intent = bridge.authorize(base)
		if not current or current.player ~= owners.player or current.unit ~= owners.unit
			or current.camera ~= owners.camera or current_intent.generation ~= intent.generation
			or current_intent.direction ~= sign or current_intent.offset ~= offset or frame.bad or not bridge.enabled()
			or rawget(base, "_output_data") ~= output or not rawequal(output.position, head)
			or not same(head, h) or not same(position, s) then reject("PREPARATION_CHANGED"); return end
		local pair = { owners = owners, output = output, head = head, h = h,
			generation = intent.generation, direction = sign, offset = offset,
			shifted_head = shifted_head, shifted_rig = shifted_rig, stage = "PREPARED" }
		frame.pair = pair
		note("PAIR_PREPARED")
		return shifted_rig, pair, frame
	end
	local function prepare_head(camera, position)
		local frame = stack[#stack]
		if not frame then return end
		if adapter_depth > 1 then reject("REENTRANT_SETTER"); return end
		if frame.bad or not usable() then return end
		local pair = frame.pair
		if not pair then return end
		if (frame.kind ~= "rotation" and not (frame.kind == "update" and frame.phase == "WAIT_HEAD"))
			or pair.stage ~= "RIG_RETURNED" then reject("HEAD_ORDER"); return end
		local owners, intent = bridge.authorize(frame.base)
		if not owners or intent.generation ~= pair.generation or intent.direction ~= pair.direction or intent.offset ~= pair.offset
			or owners.player ~= pair.owners.player or owners.unit ~= pair.owners.unit
			or owners.camera ~= pair.owners.camera or camera ~= owners.camera
			or rawget(frame.base, "_output_data") ~= pair.output
			or not rawequal(pair.output.position, pair.head) or not rawequal(position, pair.head)
			or not same(position, pair.h) then reject("HEAD_IDENTITY_OR_ARGUMENT"); return end
		if frame.bad or not bridge.enabled() then return end
		return pair.shifted_head, pair, frame
	end
	local function setter(entry, kind, object, position, ...)
		calls, adapter_depth = calls + 1, adapter_depth + 1
		local prepare = kind == "rig" and prepare_rig or prepare_head
		local ok, adapted, pair, frame = pcall(prepare, object, position)
		if not ok then reject("PREPARATION_FAILED"); adapted, pair, frame = nil, nil, nil end
		if adapted then
			for _, context in ipairs(stack) do context.effects = true end
			pair.started = true
			pair.stage = kind == "rig" and "RIG_ENTERED" or "HEAD_ENTERED"
		end
		local result = pack(pcall(entry.previous, object, adapted or position, ...))
		if not result[1] then reject("ORIGINAL_EXCEPTION")
		elseif adapted and not frame.bad and bridge.enabled() then
			pair.stage = kind == "rig" and "RIG_RETURNED" or "CONSUMED"
			if kind == "head" then
				frame.phase = "DONE"; note("PAIR_CONSUMED")
				delivered_pairs = delivered_pairs + 1
				-- Report achieved nonzero offset magnitudes only once per bin/side.
				-- The engine logger already deduplicates exact event strings.
				local level = math.floor(math.abs(pair.offset) + 0.5)
				local side = pair.offset < 0 and "LEFT" or "RIGHT"
				if level >= 1 then note("LATERAL_DELIVERED side=" .. side .. " magnitude_bin=" .. level) end
				if pair.direction == 0 then note("LATERAL_RETURN_DELIVERED") end
				if delivered_pairs == 60 or delivered_pairs == 240 then
					note("LATERAL_DELIVERED_COUNT=" .. delivered_pairs)
				end
			end
		end
		adapter_depth, calls = adapter_depth - 1, calls - 1
		flush()
		if not result[1] then error(result[2], 0) end
		return unpack(result, 2, result.n)
	end
	local function add(class, name, kind, is_setter)
		local entry = { class = class, name = name }
		entry.wrapper = function(...)
			if not active then
				calls = calls + 1
				local result = pack(pcall(entry.previous, ...))
				calls = calls - 1; flush()
				if not result[1] then error(result[2], 0) end
				return unpack(result, 2, result.n)
			end
			if is_setter then return setter(entry, kind, ...) end
			return scope(entry, kind, ...)
		end
		entries[#entries + 1] = entry
	end
	add(fp, "update", "update")
	add(fp, "_update_movement", "movement")
	add(fp, "_update_rot", "rotation")
	add(fp, "set_position", "rig", true)
	add(pc, "set_position", "head", true)
	function api.install()
		if attempted or api.busy() then return false end
		attempted, registration_busy = true, true
		local ok = pcall(function()
			for _, entry in ipairs(entries) do
				entry.previous = hooks:GetFunction(entry.class, entry.name)
				if type(entry.previous) ~= "function" or type(entry.class[entry.name]) ~= "function" then
					error("method_unavailable", 0)
				end
			end
			for _, entry in ipairs(entries) do
				hooks:OverrideFunction(entry.class, entry.name, entry.wrapper)
				entry.public = entry.class[entry.name]
				if hooks:GetFunction(entry.class, entry.name) ~= entry.wrapper then error("override_unconfirmed", 0) end
			end
		end)
		registration_busy, installed = false, ok
		return ok and api.owned()
	end
	function api.activate()
		if api.busy() or not api.owned() then return false end
		active = true
		return true
	end
	return api
end
return M
