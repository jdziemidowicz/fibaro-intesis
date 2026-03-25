-- Thermostat cool should handle actions: setThermostatMode, setCoolingThermostatSetpoint
-- Proeprties that should be updated:
-- * supportedThermostatModes - array of modes supported by the thermostat eg. {"Off", "Cool"}
-- * thermostatMode - current mode of the thermostat
-- * coolingThermostatSetpoint - set point for cooling, supported units: "C" - Celsius, "F" - Fahrenheit

function QuickApp:setThermostatMode(mode)
  if mode == "Off" then
    self:sendCommand("SET,1:ONOFF,OFF")
  else
    self:sendCommand("SET,1:MODE," .. mode:upper())
    self:sendCommand("SET,1:ONOFF,ON")
  end
end

function QuickApp:setCoolingThermostatSetpoint(value, _unit)
  self:sendCommand("SET,1:SETPTEMP," .. math.floor(10 * value))
end

function QuickApp:onChangeVane()
  if self.lastVane == "AUTO" then
    self:sendCommand("SET,1:VANEUD,SWING")
  elseif self.lastVane == "SWING" then
    self:sendCommand("SET,1:VANEUD,AUTO")
  end
end

function QuickApp:onChangeFanSpeed()
  if self.lastFanSpeed == "AUTO" then
    self:sendCommand("SET,1:FANSP,4")
  elseif self.lastFanSpeed == "4" then
    self:sendCommand("SET,1:FANSP,3")
  elseif self.lastFanSpeed == "3" then
    self:sendCommand("SET,1:FANSP,2")
  elseif self.lastFanSpeed == "2" then
    self:sendCommand("SET,1:FANSP,1")
  elseif self.lastFanSpeed == "1" then
    self:sendCommand("SET,1:FANSP,AUTO")
  end
end

function QuickApp:wakeUpDeadDevice()
  self:connect()
end

-- To update controls you can use method self:updateView(<component ID>, <component property>, <desired value>). Eg:
-- self:updateView("slider", "value", "55")
-- self:updateView("button1", "text", "MUTE")
-- self:updateView("label", "text", "TURNED ON")

-- This is QuickApp inital method. It is called right after your QuickApp starts (after each save or on gateway startup).
-- Here you can set some default values, setup http connection or get QuickApp variables.
-- To learn more, please visit:
--    * https://manuals.fibaro.com/home-center-3/
--    * https://manuals.fibaro.com/home-center-3-quick-apps/

local CONNECT_TIMEOUT_SEC  = 30
local PING_EVERY_SEC       = 10
local RECONNECT_SEC        = 30
local WMP_PORT             = 3310

function QuickApp:onInit()
  math.randomseed(os.time())

  self:updateProperty("supportedThermostatModes", {"Cool", "Fan", "Dry", "Heat", "Auto", "Off"})
  self:updateProperty("coolingThermostatSetpointCapabilitiesMin", 18)
  self:updateProperty("coolingThermostatSetpointCapabilitiesMax", 30)
  self:updateProperty("coolingThermostatSetpointStep", {C = 1.0})

  self.ip = self:getVariable("IP")
  self.pin = tonumber(self:getVariable("PIN"))

  self:connect()
end

function QuickApp:connect()
  self:resetState()

  if not self.ip then
    self:error("Set QuickApp variables: IP")
    return
  end

  self:debug(string.format("Connecting to %s:%d...", self.ip, WMP_PORT))
  self.socket = net.TCPSocket({timeout = CONNECT_TIMEOUT_SEC * 1000});

  self.socket:connect(self.ip, WMP_PORT, {
    success = function()
      self:debug("TCP connected")
      self:updateProperty("dead", false)
      self.connected = true

      self:sendCommand("ID")

      self:startReader()
    end,
    error = function(message)
      self:warning("TCP connect failed: " .. message)
      return self:scheduleReconnect()
    end
  })
end

function QuickApp:doLogin()
  if self.pin then
    local mac_int = tonumber(self.mac, 16)
    self.K = derive_key(self.pin, mac_int)

    self.r0 = random_bytes(8)
    local MAGIC_LOGIN = "\xAB\xCD\xEF\x55\xAA\xFE\xDC\xBA"
    self:sendCommand("LOGIN:" .. bytes_to_hex(aes_ecb_encrypt(self.r0 .. MAGIC_LOGIN, self.K)))
  else
    self:fetchState()
  end
end

function QuickApp:fetchState()
  self:sendCommand("CFG:DATETIME," .. os.date("%d/%m/%Y %H:%M:%S"))
  self:sendCommand("GET,1:MODE")
  self:sendCommand("GET,1:SETPTEMP")
  self:sendCommand("GET,1:VANEUD")
  self:sendCommand("GET,1:FANSP")
  self:sendCommand("GET,1:ONOFF")

  self:startPinger()
end

function QuickApp:resetState()
  self:updateProperty("dead", true)

  if self.socket then
    self.socket:close()
  end
  self.socket = nil
  self.connected = false
  self.lastSendTime = 0

  if self.pingTimer then
    hub.clearTimeout(self.pingTimer)
  end
  self.pingTimer = nil
  if self.reconnectTimer then
    hub.clearTimeout(self.reconnectTimer)
  end
  self.reconnectTimer = nil

  self.waitingForResponse = false
  self.queue = {}
  self.lastMode = "Cool"
  self.lastVane = "AUTO"
  self.lastFanSpeed = "AUTO"
  self.mac = nil
end

function QuickApp:scheduleReconnect()
  self:resetState()
  self:warning(string.format("Reconnecting in %ds...", RECONNECT_SEC))

  self.reconnectTimer = hub.setTimeout(RECONNECT_SEC * 1000, function()
    self.reconnectTimer = nil
    self:connect()
  end)
end

function QuickApp:startReader()
  self:readSomething(function (data)
    self:handleIncoming(data)
    self:startReader()
  end)
end

function QuickApp:readSomething(callback)
  self.socket:readUntil("\r\n", {
    success = function(data)
      if self.SK then
        data = unescape(data)
        data = aes_cbc_decrypt(data, self.SK, self.iv_rx)
        local num2 = tonumber(data:sub(1, 4))
        data = data:sub(6, 5 + num2 - 2)
      end

      self:debug("<-- " .. data)

      self.waitingForResponse = false
      local payload = table.remove(self.queue, 1)
      if payload then
        self:sendCommand(payload)
      end

      callback(data)
    end,
    error = function(message)
      self:warning("Socket read error: " .. message)
      self:scheduleReconnect()
    end
  })
end

function QuickApp:startPinger()
  if self.pingTimer then
    hub.clearTimeout(self.pingTimer)
  end

  self:pingLoop()
end

function QuickApp:pingLoop()
  self.pingTimer = hub.setTimeout(PING_EVERY_SEC * 1000, function()
    if os.time() - self.lastSendTime >= PING_EVERY_SEC then
      self:sendCommand("PING")
    end
    self:pingLoop()
  end)
end

local function firstToUpper(str)
  return str:sub(1, 1):upper() .. str:sub(2):lower()
end

function QuickApp:handleIncoming(data)
  if data == "CHN,1:MODE,COOL" then
    self.lastMode = "Cool"
    self:updateProperty("thermostatMode", "Cool")
  elseif data == "CHN,1:MODE,FAN" then
    self.lastMode = "Fan"
    self:updateProperty("thermostatMode", "Fan")
  elseif data == "CHN,1:MODE,DRY" then
    self.lastMode = "Dry"
    self:updateProperty("thermostatMode", "Dry")
  elseif data == "CHN,1:MODE,HEAT" then
    self.lastMode = "Heat"
    self:updateProperty("thermostatMode", "Heat")
  elseif data == "CHN,1:MODE,AUTO" then
    self.lastMode = "Auto"
    self:updateProperty("thermostatMode", "Auto")
  elseif data == "CHN,1:ONOFF,OFF" then
    self:updateProperty("thermostatMode", "Off")
  elseif data == "CHN,1:ONOFF,ON" then
    self:updateProperty("thermostatMode", self.lastMode)
  elseif data == "OK" then
    self.SK = self.r1 .. self.r2
    self.iv_rx = { md5(self.r0) }

    local r0_inc = {}
    for i = 1, 8 do r0_inc[i] = (self.r0:byte(i) + 1) & 0xFF end
    self.iv_tx = { md5(string.char(table.unpack(r0_inc))) }
    self:fetchState()
  elseif data:starts("CHN,1:VANEUD,") then
    local _, e = data:find("CHN,1:VANEUD,", 1, true)
    local mode = data:sub(e+1)
    self.lastVane = mode
    self:updateView("buttonVane", "text", "Vane: " .. firstToUpper(mode))
  elseif data:starts("CHN,1:FANSP,") then
    local _, e = data:find("CHN,1:FANSP,", 1, true)
    local speed = data:sub(e+1)
    self.lastFanSpeed = speed
    self:updateView("buttonFanSp", "text", "Fan: " .. firstToUpper(speed))
  elseif data:starts("CHN,1:SETPTEMP,") then
    local _, e = data:find("CHN,1:SETPTEMP,", 1, true)
    local temp = tonumber(data:sub(e+1))
    if temp ~= 32768 then
      self:updateProperty("coolingThermostatSetpoint", {value = temp // 10, unit = "C"})
    end
  elseif data:starts("ID:") then
    local comma = data:find(",")
    self.mac = data:sub(comma + 1, comma + 12)
    self:doLogin()
  elseif data:starts("M0:") then
    local m0_plain = aes_ecb_decrypt(hex_to_bytes(data:sub(4)), self.K)
    local MAGIC_M0 = "\xFE\xA5\x1B\x1E\x01\x23\x45\x67"
    assert(m0_plain:sub(9, 16) == MAGIC_M0, "M0 magic mismatch: " .. bytes_to_hex(m0_plain:sub(9, 16)))
    self.r1 = m0_plain:sub(1, 8)

    self.r2 = random_bytes(8)
    local MAGIC_M1 = "\x5A\xFE\xB0\xA7\xBE\xA1\xAF\xEA"
    self:sendCommand("M1:" .. bytes_to_hex(aes_ecb_encrypt(self.r2 .. MAGIC_M1, self.K)))
  end
end

function QuickApp:sendRaw(payload)
  if self.SK then
    local buf = payload .. "\n"
    local inner = escape(buf, #buf - 1)
    local array2 = ("%04d~"):format(#inner) .. inner
    local cipher_out = aes_cbc_encrypt(array2, self.SK, self.iv_tx)
    local outer = escape(cipher_out, #cipher_out)
    data = outer .. "\n"
  else
    data = payload .. "\r\n"
  end

  self.socket:write(data, {
    success = function()
      self:debug("--> " .. payload)
      self.lastSendTime = os.time()
    end,
    error = function(message)
      self:warning("Socket write error: " .. message)
      self:scheduleReconnect()
    end
  })
end

function QuickApp:sendCommand(payload)
  if not self.connected then
    self:warning("Not connected, cannot send")
    return
  end

  if not self.waitingForResponse then
    self:sendRaw(payload)
    self.waitingForResponse = true
  else
    table.insert(self.queue, payload)
  end
end
