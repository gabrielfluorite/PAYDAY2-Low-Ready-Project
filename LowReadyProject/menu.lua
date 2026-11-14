-- Native MenuHelper items; key capture is scoped exclusively to our two items.
local M = {}
local id="low_ready_project_options_v1"
local fields={"walk_speed","sprint_speed","crouch_speed","sprinting_head_bob","enable_lean","lean_left_key","lean_right_key","lean_mode"}
local titles={"WALK SPEED","SPRINT SPEED","CROUCH SPEED","SPRINTING HEAD BOB","ENABLE LEAN","LEAN LEFT KEY","LEAN RIGHT KEY","LEAN MODE"}
local descriptions={
 "Adjust walking speed. Changes may require restarting the mission to take effect. Default value: 60%.",
 "Adjust sprint speed. Changes may require restarting the mission to take effect. Default value: 60%.",
 "Adjust crouching speed. Changes may require restarting the mission to take effect. Default value: 60%.",
 "Adjust camera bobbing while sprinting. Changes may require restarting the mission to take effect. Default value: 50%.",
 "Enable or disable leaning left and right.",
 "Choose the key for leaning left. Check for conflicts with your game controls. Default key: Q.",
 "Choose the key for leaning right. Check for conflicts with your game controls. Default key: E.",
 "Toggle: press to lean, press again to return. Hold: lean while pressed."
}
function M.install(root,env)
 if root.menu_installed then return end
 root.menu_installed=true
 local helper,hooks,callbacks=env.MenuHelper,env.Hooks,env.MenuCallbackHandler
 local function strings(loc)
  loc:add_localized_strings({lrp_title="LOW READY PROJECT",lrp_description="Movement and camera lean preferences"})
 end
 hooks:Add("LocalizationManagerPostInit","LowReadyProject_Localization",strings)
 if env.managers and env.managers.localization then strings(env.managers.localization) end
 local function refresh(node)
  if not node or type(node.items)~="function" then return end
  local values=root.settings.snapshot()
  for _,item in ipairs(node:items()) do
   local p=item:parameters(); local key=p.name and p.name:match("^lrp_(.+)$")
   if key and values[key]~=nil then
    if key=="lean_left_key" or key=="lean_right_key" then p.binding=values[key]
    elseif key=="enable_lean" then item:set_value(values[key] and "on" or "off")
    elseif key=="lean_mode" then item:set_value(values[key]=="toggle" and 1 or 2)
    else item:set_value(values[key]) end
   end
  end
 end
 callbacks.LowReadyProject_Focus=function(node)
  root.cancel_input()
  -- File hooks may replace _key_press after an earlier bootstrap saw the
  -- class. Check the effective dispatch again before exposing key capture.
  local ok,ready=pcall(M.install_capture,root,env)
  if not ok then root.report("KEY_CAPTURE_UNAVAILABLE",ready) end
  if node and type(node.items)=="function" then
   for _,item in ipairs(node:items()) do
    local p=item:parameters()
    if p.name=="lrp_lean_left_key" or p.name=="lrp_lean_right_key" then
     if type(item.set_enabled)=="function" then item:set_enabled(ok and ready==true) end
    end
   end
  end
  refresh(node)
  if root.show_save_warning then root.show_save_warning() end
 end
 callbacks.LowReadyProject_Back=function() root.cancel_input() end
 callbacks.LowReadyProject_Change=function(_,item)
  local key=item:parameters().name:match("^lrp_(.+)$")
  local v=item:value()
  if key=="enable_lean" then v=v=="on"
  elseif key=="lean_mode" then v=tonumber(v)==1 and "toggle" or tonumber(v)==2 and "hold" or nil
  else
   v=tonumber(v)
   -- Native slider step documents arrow-key increments, not mouse-drag
   -- quantization. Quantize only this UI input; saved values stay strict.
   if v and v>=10 and v<=100 then v=math.floor(v+0.5);item:set_value(v) end
  end
  local ok=root.change(key,v)
  if not ok then
   local value=root.settings.snapshot()[key]
   item:set_value(key=="enable_lean" and (value and "on" or "off") or key=="lean_mode" and (value=="toggle" and 1 or 2) or value)
  end
 end
 hooks:Add("MenuManagerSetupCustomMenus","LowReadyProject_Setup",function() helper:NewMenu(id) end)
 hooks:Add("MenuManagerPopulateCustomMenus","LowReadyProject_Populate",function()
  local values=root.settings.snapshot()
  for i,key in ipairs(fields) do
   local data={menu_id=id,id="lrp_"..key,title=titles[i],desc=descriptions[i],localized=false,
    priority=9-i,callback="LowReadyProject_Change",value=values[key]}
   if i<=4 then
    data.min,data.max,data.step,data.show_value,data.display_precision,data.is_percentage=10,100,1,true,0,true
    helper:AddSlider(data)
   elseif i==5 then helper:AddToggle(data)
   elseif i<=7 then
    data.connection_name="lrp_"..key; data.binding=values[key]; data.callback=nil
    local item=helper:AddKeybinding(data)
    item:parameters().low_ready_project_key=key
   else data.items={"Toggle","Hold"};data.localized_items=false;data.value=values[key]=="toggle" and 1 or 2
    helper:AddMultipleChoice(data)
   end
  end
 end)
 hooks:Add("MenuManagerBuildCustomMenus","LowReadyProject_Build",function(_,nodes)
  nodes[id]=helper:BuildMenu(id,{focus_changed_callback="LowReadyProject_Focus",back_callback="LowReadyProject_Back"})
  helper:AddMenuItem(nodes.blt_options,id,"lrp_title","lrp_description")
 end)
end
function M.install_capture(root,env)
 local gui=env.MenuNodeGui
 assert(type(gui)=="table","native_capture_unavailable")
 assert(type(gui._key_press)=="function" and type(gui._end_customize_controller)=="function","native_capture_unavailable")
 local record=env.Hooks._function_hooks[gui] and env.Hooks._function_hooks[gui]._key_press
 if root.capture_gui==gui and gui._key_press==root.capture_dispatch
  and env.Hooks:GetFunction(gui,"_key_press")==root.capture_handler then return true end
 local previous=env.Hooks:GetFunction(gui,"_key_press")
 if root.capture_gui==gui and previous==root.capture_handler then
  if record~=root.capture_record then
   -- A new hook registry plus a changed public method is ambiguous: do not
   -- wrap a potentially dynamic Hooks dispatcher and create recursion.
   root.report("KEY_CAPTURE_UNAVAILABLE","hook_dispatch_changed")
   return false
  end
  -- A direct method assignment bypassed Hooks, leaving its old record behind.
  -- Preserve that actual replacement for unrelated items, not our stale self.
  previous=gui._key_press
 end
 assert(type(previous)=="function","native_keypress_unavailable")
 local function capture(self,o,key,input_id,item,no_add,...)
  local p=item and item:parameters()
  local field=p and ((p.name=="lrp_lean_left_key" and p.connection_name==p.name and "lean_left_key")
   or (p.name=="lrp_lean_right_key" and p.connection_name==p.name and "lean_right_key"))
  if not field then
   return previous(self,o,key,input_id,item,no_add,...)
  end
  if env.managers.system_menu:is_active() then return end
  if self._skip_first_activate_key then
   self._skip_first_activate_key=false
   if (input_id=="mouse" and key==env.Idstring("0")) or (input_id=="keyboard" and key==env.Idstring("enter")) then return end
  end
  root.capturing=true
  local handled,reason=pcall(function()
   root.cancel_input()
   if input_id=="keyboard" and key~=env.Idstring("esc") then
    local name=env.Input:keyboard():button_name_str(key)
    local accepted=root.change(field,name)
    if not accepted then root.report("KEY_REJECTED",tostring(name)) end
   end
  end)
  -- Esc, mouse and invalid keys preserve the old preference. This branch never
  -- calls set_user_mod, rebind_connections, or the game's binding collision code.
  p.binding=root.settings.snapshot()[field]
  local ended,err=pcall(self._end_customize_controller,self,o,item)
  root.capturing=false
  if not handled then root.report("KEY_CAPTURE_FAILED",reason) end
  if not ended then
   -- Do not retry a native method after possible effects or enter the binding
   -- path as fallback. Native capture release cannot be guaranteed on failure.
   root.report("KEY_CAPTURE_END_FAILED",err)
   return
  end
  if root.show_save_warning then root.show_save_warning() end
 end
 env.Hooks:OverrideFunction(gui,"_key_press",capture)
 assert(env.Hooks:GetFunction(gui,"_key_press")==capture,"capture_registration_failed")
 root.capture_gui,root.capture_handler,root.capture_dispatch=gui,capture,gui._key_press
 root.capture_record=env.Hooks._function_hooks[gui] and env.Hooks._function_hooks[gui]._key_press
 root.report(root.capture_installed and "KEY_CAPTURE_REINSTALLED" or "KEY_CAPTURE_INSTALLED")
 root.capture_installed=true
 return true
end
return M
