local KEY="__LowReadyProject_Unified_20261104"
local root=rawget(_G,KEY)
if not root then
 root={path=ModPath};rawset(_G,KEY,root)
 function root.report(code,detail)
  if type(log)=="function" then log("[LowReadyProject] "..code.." "..tostring(detail or "")) end
 end
 function root.load(name)
  local f=assert(io.open(root.path..name..".lua","rb"))
  local source=f:read("*all");f:close()
  local chunk=assert(loadstring(source,"=LowReadyProject/"..name));setfenv(chunk,_G)
  return chunk()
 end
 root.settings=root.load("settings").new(_G,SavePath.."lowreadyproject.json")
 local ok,reason=root.settings.load();if not ok or reason then root.report("SETTINGS_LOAD",reason) end
 function root.cancel_input()
  if root.lean then return root.lean.configure(root.settings.lean()) end
  return true
 end
 function root.show_save_warning()
  if not root.save_warning or root.capturing then return end
  if managers and managers.system_menu and type(managers.system_menu.show)=="function" then
   local ok=pcall(function()
    managers.system_menu:show({title="LOW READY PROJECT",text="Preferences are active for this session but could not be saved. "..root.save_warning,button_list={{text="OK",cancel_button=true}}})
   end)
   if ok then root.save_warning=nil end
  end
 end
 function root.change(key,value)
  local ok,reason=root.settings.set(key,value)
  if not ok then return false,reason end
  if key=="enable_lean" or key=="lean_mode" or key=="lean_left_key" or key=="lean_right_key" then root.cancel_input() end
  local saved,err=root.settings.save()
  if not saved then
   root.report("SETTINGS_SAVE_FAILED",err)
   root.save_warning=tostring(err)
   root.show_save_warning()
  end
  return true, saved and "saved" or "session_only"
 end
end
if root.busy or root.failed then return end
root.busy=true
local ok,err=pcall(function()
 -- Migration must remove both original manifests from loading before activation.
 if rawget(_G,"__LowReadyLeanV3_Combined_20261028") then error("old_lean_loaded") end
 if not root.movement_installed and type(PlayerStandard)=="table" then
  local hooks=Hooks._function_hooks and Hooks._function_hooks[PlayerStandard]
  local init=hooks and hooks.init
  for _,v in ipairs(init and init.overrides and init.overrides.post or {}) do
   if v.id=="LowReady_InitializeSpeedSettings" then error("old_movement_loaded") end
  end
  root.movement_installed=assert(root.load("movement").install(root.settings.movement))
 end
 if not root.lean and type(PlayerStandard)=="table" and type(FPCameraPlayerBase)=="table" and type(PlayerCamera)=="table" then
  local modules={controls=root.load("lean/controls"),tilt=root.load("lean/tilt"),lateral=root.load("lean/lateral")}
  root.lean=assert(root.load("lean/integration").new(_G,PlayerStandard,FPCameraPlayerBase,PlayerCamera,root.load("lean/config"),modules))
  assert(root.lean.install(),"lean_registration_failed")
  assert(root.cancel_input(),"lean_preferences_failed")
 end
 if type(MenuHelper)=="table" and type(MenuCallbackHandler)=="table" then root.load("menu").install(root,_G) end
 if type(MenuNodeGui)=="table" then root.load("menu").install_capture(root,_G) end
end)
root.busy=false
if not ok then root.failed=true;root.report("INITIALIZATION_FAILED",err);if root.lean then root.lean.configure({enabled=false,left_key="q",right_key="e",lean_mode="toggle"}) end end
