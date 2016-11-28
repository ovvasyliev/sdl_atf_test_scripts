---------------------------------------------------------------------------------------------
-- Requirements summary:
-- [PolicyTableUpdate] "timeout" countdown start
--
-- Description:
-- SDL must forward OnSystemRequest(request_type=PROPRIETARY, url, appID) with encrypted PTS
-- snapshot as a hybrid data to mobile application with <appID> value. "fileType" must be
-- assigned as "JSON" in mobile app notification.
-- 1. Used preconditions
-- SDL is built with "-DEXTENDED_POLICY: EXTERNAL_PROPRIETARY" flag
-- Application is registered.
-- PTU is requested.
-- SDL->HMI: SDL.OnStatusUpdate(UPDATE_NEEDED)
-- SDL->HMI:SDL.PolicyUpdate(file, timeout, retry[])
-- HMI -> SDL: SDL.GetURLs (<service>)
-- HMI->SDL: BasicCommunication.OnSystemRequest ('url', requestType:PROPRIETARY, appID="default")
-- SDL->app: OnSystemRequest ('url', requestType:PROPRIETARY, fileType="JSON", appID)
-- 2. Performed steps
-- Do not send SystemRequest from <app_ID>
--
-- Expected result:
-- SDL waits for SystemRequest response from <app ID> within 'timeout' value, if no obtained,
-- it starts retry sequence
---------------------------------------------------------------------------------------------

--[[ General configuration parameters ]]
config.deviceMAC = "12ca17b49af2289436f303e0166030a21e525d266e209267433801a8fd4071a0"

--[[ Required Shared libraries ]]
local commonSteps = require('user_modules/shared_testcases/commonSteps')
local commonFunctions = require('user_modules/shared_testcases/commonFunctions')
local commonTestCases = require('user_modules/shared_testcases/commonTestCases')
local testCasesForPolicyTable = require('user_modules/shared_testcases/testCasesForPolicyTable')
local testCasesForPolicyTableSnapshot = require('user_modules/shared_testcases/testCasesForPolicyTableSnapshot')

--[[ General Precondition before ATF start ]]
commonSteps:DeleteLogsFileAndPolicyTable()

--ToDo: shall be removed when issue: "ATF does not stop HB timers by closing session and connection" is fixed
config.defaultProtocolVersion = 2

--[[ General Settings for configuration ]]
Test = require('connecttest')
require('cardinalities')
require('user_modules/AppTypes')

--[[ Preconditions ]]
commonFunctions:newTestCasesGroup("Preconditions")
function Test:Precondition_trigger_getting_device_consent()
  testCasesForPolicyTable:trigger_getting_device_consent(self, config.application1.registerAppInterfaceParams.appName, config.deviceMAC)
end

--[[ Test ]]
commonFunctions:newTestCasesGroup("Test")
function Test:TestStep_Sending_PTS_to_mobile_application()
  local time_update_needed = {}
  local time_system_request = {}
  local endpoints = {}
  local is_test_fail = false
  local SystemFilesPath = commonFunctions:read_parameter_from_smart_device_link_ini("SystemFilesPath")
  local PathToSnapshot = commonFunctions:read_parameter_from_smart_device_link_ini("PathToSnapshot")
  local file_pts = SystemFilesPath.."/"..PathToSnapshot
  local expect_PTU_status_update = 0
  local expect_PTU_policy_update = 0

  for i = 1, #testCasesForPolicyTableSnapshot.pts_endpoints do
    if (testCasesForPolicyTableSnapshot.pts_endpoints[i].service == "0x07") then
      endpoints[#endpoints + 1] = { url = testCasesForPolicyTableSnapshot.pts_endpoints[i].value, appID = nil}
    end

    if (testCasesForPolicyTableSnapshot.pts_endpoints[i].service == "app1") then
      endpoints[#endpoints + 1] = { url = testCasesForPolicyTableSnapshot.pts_endpoints[i].value, appID = testCasesForPolicyTableSnapshot.pts_endpoints[i].appID}
    end
  end

  local RequestId_GetUrls = self.hmiConnection:SendRequest("SDL.GetURLS", { service = 7 })

  EXPECT_HMIRESPONSE(RequestId_GetUrls,{result = {code = 0, method = "SDL.GetURLS", urls = endpoints} } )
  :Do(function(_,_)
      self.hmiConnection:SendNotification("BasicCommunication.OnSystemRequest",{ requestType = "PROPRIETARY", fileName = "PolicyTableUpdate" })
      --first retry sequence
      local seconds_between_retries = {}
      local timeout_pts = testCasesForPolicyTableSnapshot:get_data_from_PTS("module_config.timeout_after_x_seconds")
      for i = 1, #testCasesForPolicyTableSnapshot.pts_seconds_between_retries do
        seconds_between_retries[i] = testCasesForPolicyTableSnapshot.pts_seconds_between_retries[i].value
      end
      local time_wait = (timeout_pts*seconds_between_retries[1]*1000 + 10000)
      commonTestCases:DelayedExp(time_wait) -- tolerance 10 sec

      local function verify_retry_sequence()
        --time_update_needed[#time_update_needed + 1] = testCasesForPolicyTable.time_trigger
        time_update_needed[#time_update_needed + 1] = timestamp()
        local time_1 = time_update_needed[#time_update_needed]
        local time_2 = time_system_request[#time_system_request]
        local timeout = (time_1 - time_2)
        if( ( timeout > (timeout_pts*1000 + 2000) ) or ( timeout < (timeout_pts*1000 - 2000) )) then
          is_test_fail = true
          commonFunctions:printError("ERROR: timeout for first retry sequence is not as expected: "..timeout_pts.."msec(5sec tolerance). real: "..timeout.."ms")
        else
          print("timeout is as expected: "..timeout_pts.."ms. real: "..timeout)
        end
      end

      EXPECT_NOTIFICATION("OnSystemRequest", { requestType = "PROPRIETARY", fileType = "JSON"})
      :Do(function(_,_) time_system_request[#time_system_request + 1] = timestamp() end)

      EXPECT_HMINOTIFICATION("SDL.OnStatusUpdate", {status = "UPDATE_NEEDED"})

      EXPECT_HMICALL("BasicCommunication.PolicyUpdate", { file = file_pts, timeout = timeout_pts, retry = seconds_between_retries})
      :Do(function(exp_pu,data)
          --expect_PTU_policy_update = 1 print("expect_PTU_policy_update = "..expect_PTU_policy_update)
          if(exp_pu.occurences > 1) then
            is_test_fail = true
            commonFunctions:printError("ERROR: PTU sequence is restarted again!")
          end
          verify_retry_sequence()
          self.hmiConnection:SendResponse(data.id, data.method, "SUCCESS", {})
        end)
    end)

  if(is_test_fail == true) then
    self:FailTestCase("Test is FAILED. See prints.")
  end
end

--[[ Postconditions ]]
commonFunctions:newTestCasesGroup("Postconditions")
function Test:Postcondition_Force_Stop_SDL()
  commonFunctions:SDLForceStop(self)
end

return Test