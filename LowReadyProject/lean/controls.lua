-- One keyboard sample per control update. Derived from the approved Lean V2.
local M = {}
function M.new(engine, config, note)
	local mode, left_key, right_key = config.lean_mode, config.left_key, config.right_key
	local left_id, right_id, wait = nil, nil, 0
	local direction, previous_left, previous_right = 0, false, false
	local synced, release_left, release_right = true, false, false
	local api = {}
	function api.cancel()
		direction, synced = 0, false
		release_left, release_right = true, true
	end
	local function read_buttons()
		if not left_id then
			if wait > 0 then wait = wait - 1; return nil, nil, "IDSTRING" end
			local ok, l, r = pcall(function()
				return engine.Idstring(left_key), engine.Idstring(right_key)
			end)
			if not ok or l == nil or r == nil then
				wait = 30
				return nil, nil, "IDSTRING"
			end
			left_id, right_id = l, r
		end
		local keyboard = engine.Input:keyboard()
		if keyboard:has_button(left_id) ~= true or keyboard:has_button(right_id) ~= true then
			error("keyboard_key_unavailable", 0)
		end
		local left, right = keyboard:down(left_id), keyboard:down(right_id)
		if type(left) ~= "boolean" or type(right) ~= "boolean" then error("keyboard_unavailable", 0) end
		return left, right
	end
	-- During an otherwise safe ACTIVE sprint, observe held keys without
	-- generating intent. This arms the next real rising edge immediately
	-- after sprint exit; keys held throughout sprint cannot auto-trigger.
	function api.observe_sprint()
		local left, right = read_buttons()
		if left == nil then return false end
		direction, previous_left, previous_right = 0, left, right
		release_left, release_right, synced = left, right, true
		return true
	end
	function api.sample()
		local left, right, reason = read_buttons()
		if left == nil then return nil, reason end
		if release_left and not left then release_left = false end
		if release_right and not right then release_right = false end
		if mode == "toggle" then
			if not synced then
				synced = true -- Establish a baseline, never synthesize a new press.
			elseif left and not previous_left and right and not previous_right then
				direction = 0
			elseif left and not previous_left and not release_left then
				direction = direction == -1 and 0 or -1
			elseif right and not previous_right and not release_right then
				direction = direction == 1 and 0 or 1
			end
		else
			synced = true
			direction = left and not right and not release_left and -1
				or right and not left and not release_right and 1 or 0
		end
		previous_left, previous_right = left, right
		if left ~= right then note(left and "INPUT_LEFT" or "INPUT_RIGHT") end
		return direction
	end
	return api
end
return M
