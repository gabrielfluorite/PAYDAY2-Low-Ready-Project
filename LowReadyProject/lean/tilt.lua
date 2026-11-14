-- Target ownership and exponential calibration from Lean V2. No rig getter.
local M = {}
local function finite(v) return type(v) == "number" and v == v and math.abs(v) < math.huge end
local function read(base)
	local value = base._camera_properties.target_tilt
	if not finite(value) then error("tilt_unavailable", 0) end
	return value
end
function M.new(config, note)
	local maximum, tau = config.max_angle_degrees, config.time_constant_seconds
	local owner = setmetatable({}, { __mode = "v" })
	local last, smooth, origin, pending, blocked = nil, nil, nil, false, false
	local busy = false
	local api = {}
	-- Diagnostic-only lease provenance. No target writes or ownership transfers.
	local function clear(reason, observed)
		if last ~= nil then
			local function number(v)
				return finite(v) and string.format("%.3f", v) or "unavailable"
			end
			note("TILT_LEASE_RELEASE category=" .. (reason or "UNSPECIFIED")
				.. " last=" .. number(last) .. " observed=" .. number(observed)
				.. " origin=" .. number(origin))
		end
		last, smooth, origin, pending, owner[1] = nil, nil, nil, false, nil
	end
	function api.busy() return busy end
	function api.has_effect() return last ~= nil and last ~= origin end
	function api.status()
		return { owned = last ~= nil, restore_pending = pending, write_blocked = blocked }
	end
	-- No mutation of the target. A stale owner is never transferred to a new rig.
	local function base_target(context)
		return context.carry and -5 or 0
	end
	function api.available(context)
		if blocked then return false, "TILT_WRITE_BLOCKED" end
		if last ~= nil and owner[1] ~= context.unit then clear("CAMERA_CHANGED"); return false, "TILT_CAMERA_CHANGED" end
		if last ~= nil and origin ~= base_target(context) then clear("NATIVE_MODE_CHANGED"); return false, "TILT_NATIVE_MODE_CHANGED" end
		local ok, current = pcall(read, context.base)
		if not ok then pending = last ~= nil; return false, "TILT_READ_UNAVAILABLE" end
		if last ~= nil and current ~= last then clear("TARGET_CHANGED", current); return false, "TILT_NATIVE_TARGET" end
		if last == nil and current ~= base_target(context) then return false, "TILT_NATIVE_TARGET" end
		return true, current
	end
	local function write(context, value, baseline)
		if blocked or busy then return false, "TILT_WRITE_BLOCKED", false end
		busy = true
		local call_ok = pcall(function() context.base:set_target_tilt(value) end)
		local read_ok, current = pcall(read, context.base)
		busy = false
		-- Readback may establish ownership, but cannot turn an exception into success.
		if read_ok and current == value then
			last, smooth, origin, owner[1] = value, value - baseline, baseline, context.unit
		elseif not read_ok and call_ok then
			last, smooth, origin, owner[1] = value, value - baseline, baseline, context.unit
		elseif read_ok and current ~= last then
			clear("DELIVERY_MISMATCH", current)
		end
		if not call_ok or not read_ok or current ~= value then
			blocked, pending = true, last ~= nil
			return false, not call_ok and "TILT_SET_EXCEPTION" or "TILT_DELIVERY_UNCONFIRMED", true
		end
		pending = false
		return true, nil, true
	end
	function api.step(context, direction, dt, permitted)
		local allowed, current = api.available(context)
		if not allowed then return false, current, false end
		-- A property read can reenter Lua. Revalidate the private control lease
		-- after that read and before touching a target or advancing its curve.
		if not permitted() then return false, "TILT_CONTEXT_CHANGED", false end
		local baseline = base_target(context)
		local desired = direction * maximum
		local prior = smooth or 0
		local next_offset = prior + (desired - prior) * (1 - math.exp(-dt / tau))
		if math.abs(desired - next_offset) <= 0.05 then next_offset = desired end
		smooth = next_offset
		local next_target = baseline + next_offset
		if next_target == last or (last == nil and next_offset == 0 and current == baseline) then return true end
		local ok, reason, attempted = write(context, next_target, baseline)
		if ok then
			note("TILT_TARGET_CONFIRMED")
			if next_offset == 0 then clear("NEUTRAL_CONFIRMED", next_target) end
		end
		return ok, reason, attempted
	end
	function api.restore(context, permitted)
		if last == nil then pending = false; return true end
		if blocked then pending = true; return false, "TILT_RESTORE_SUSPENDED", false end
		if not owner[1] then clear("OWNER_REFERENCE_MISSING"); return true end
		if not context then pending = true; return false, "TILT_RESTORE_PENDING", false end
		if owner[1] ~= context.unit then clear("RESTORE_CAMERA_CHANGED"); return true end
		local ok, current = pcall(read, context.base)
		if not ok then pending = true; return false, "TILT_RESTORE_PENDING", false end
		if not permitted() then pending = true; return false, "TILT_RESTORE_PENDING", false end
		if current ~= last or current == origin then clear(current == origin and "BASELINE_ALREADY_PRESENT" or "RESTORE_TARGET_CHANGED", current); return true end
		pending = true
		local success, reason, attempted = write(context, origin, origin)
		if success then clear("RESTORE_CONFIRMED", origin); note("TILT_OWNED_TARGET_RESTORED") end
		return success, reason, attempted
	end
	return api
end
return M
