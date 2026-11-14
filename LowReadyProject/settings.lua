-- Eight preferences only. I/O is injected so offline tests never touch SavePath.
local M = {}
local defaults = {
 walk_speed=60, sprint_speed=60, crouch_speed=60, sprinting_head_bob=50,
 enable_lean=true, lean_left_key="q", lean_right_key="e", lean_mode="toggle"
}
local percentages = {walk_speed=true,sprint_speed=true,crouch_speed=true,sprinting_head_bob=true}
local function copy(t) local r={}; for k,v in pairs(t) do r[k]=v end; return r end
function M.percent(v)
 return type(v)=="number" and v==v and v>=10 and v<=100 and v%1==0
end
function M.new(env, path)
 local values, corrupt, last_error = copy(defaults), nil, nil
 local api = {}
 function api.key(value)
  if type(value)~="string" or #value==0 or #value>64 or value:find("[%c]") then return nil end
  local ok, name = pcall(function()
   local keyboard=env.Input:keyboard()
   local id=env.Idstring(value:lower())
   if keyboard:has_button(id)~=true then return nil end
   local canonical=keyboard:button_name_str(id)
   if type(canonical)~="string" or canonical=="" then return nil end
   canonical=canonical:lower()
   if canonical=="esc" or canonical:match("^mouse ") then return nil end
   if keyboard:has_button(env.Idstring(canonical))~=true then return nil end
   return canonical
  end)
  return ok and name or nil
 end
 local function valid(key,value)
  if percentages[key] then return M.percent(value) end
  if key=="enable_lean" then return type(value)=="boolean" end
  if key=="lean_mode" then return value=="toggle" or value=="hold" end
  return false
 end
 local function read(name)
  local f,err,code=env.io.open(name,"rb")
  if not f then
   if code==2 or (err and tostring(err):lower():find("no such file",1,true)) then return nil end
   error(err or "settings_read_unavailable")
  end
  local ok,data=pcall(function() return f:read("*all") end)
  local closed=f:close()
  if not ok or type(data)~="string" or closed==nil then error("settings_read_failed") end
  return data
 end
 local function write(name,bytes)
  local f,err=env.io.open(name,"wb"); if not f then error(err or "settings_open_failed") end
  local ok,result=pcall(function() return f:write(bytes) end)
  local closed=f:close()
  if not ok or not result or not closed then error("settings_write_failed") end
  if read(name)~=bytes then error("settings_verification_failed") end
 end
 function api.load()
  values,corrupt,last_error=copy(defaults),nil,nil
  local ok,bytes,read_error=pcall(read,path)
  if not ok then last_error=tostring(bytes); return false,last_error end
  if bytes==nil then
   -- A missing file is normal. An inaccessible file is not overwritten blindly.
   if read_error and not tostring(read_error):lower():find("no such file",1,true) then
    last_error=tostring(read_error)
   end
   return true,last_error
  end
  -- The installed SuperBLT json wrapper discards the parser's end position.
  -- Use its underlying json10 decoder to reject trailing garbage as well.
  if not env.json10 or type(env.json10.decode)~="function" then
   last_error="settings_decoder_unavailable";return false,last_error
  end
  local decoded,data,after=pcall(env.json10.decode,bytes)
  if not bytes:match("^%s*{") or not decoded or type(data)~="table" or getmetatable(data)~=nil
   or type(after)~="number" or not bytes:sub(after):match("^%s*$") then
   corrupt=bytes; last_error="corrupt_settings_preserved"; return false,last_error
  end
  for k in pairs(defaults) do if valid(k,data[k]) then values[k]=data[k] end end
  local left,right=api.key(data.lean_left_key),api.key(data.lean_right_key)
  if left then values.lean_left_key=left end
  if right then values.lean_right_key=right end
  if values.lean_left_key==values.lean_right_key then
   -- Preserve the valid side if only the other field is invalid. Q/E are
   -- distinct fallback keys; choose the one that does not collide.
   if left and not right then values.lean_right_key=left==defaults.lean_right_key and defaults.lean_left_key or defaults.lean_right_key
   elseif right and not left then values.lean_left_key=right==defaults.lean_left_key and defaults.lean_right_key or defaults.lean_left_key
   else values.lean_left_key,values.lean_right_key=defaults.lean_left_key,defaults.lean_right_key end
  end
  return true
 end
 function api.snapshot() return copy(values) end
 function api.set(key,value)
  if key=="lean_left_key" or key=="lean_right_key" then
   value=api.key(value)
   local other=key=="lean_left_key" and "lean_right_key" or "lean_left_key"
   if not value or value==values[other] then return false,"invalid_or_duplicate_key" end
  elseif not valid(key,value) then return false,"invalid_preference" end
  values[key]=value; return true
 end
 function api.save()
  local ok,err=pcall(function()
   -- Only an explicit user edit saves. Preserve corrupt bytes first; never
   -- overwrite a different previous recovery file. No recovery-file retries.
   if corrupt~=nil then
    local recovery=path..".corrupt"
    local existing=read(recovery)
    if existing~=nil and existing~=corrupt then error("corrupt_recovery_already_exists") end
    if existing==nil then write(recovery,corrupt) end
   elseif last_error then error("unverified_settings_file: "..last_error) end
   write(path,env.json.encode(values))
   corrupt,last_error=nil,nil
  end)
  if not ok then return false,tostring(err) end
  return true
 end
 function api.movement()
  return {walk_speed_multiplier=values.walk_speed/100,run_speed_multiplier=values.sprint_speed/100,
   crouch_speed_multiplier=values.crouch_speed/100,casing_speed_multiplier=values.walk_speed/100,
   run_headbob_multiplier=values.sprinting_head_bob/100}
 end
 function api.lean()
  return {enabled=values.enable_lean,left_key=values.lean_left_key,right_key=values.lean_right_key,lean_mode=values.lean_mode}
 end
 return api
end
return M
