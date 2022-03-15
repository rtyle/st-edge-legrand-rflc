local cosock    = require "cosock"
local log       = require "log"

local xml       = require "xml"

local classify  = require "classify"
local UPnP      = require "upnp"

-- at the time of this writing, the latest Denon AVR-X4100W firmware,
-- UPnP service eventing are all worthless for our purposes
-- except RenderingControl, which will sendEvents only on its LastChange state variable.
-- this may have Mute and/or Volume state but only for the Master channel.
-- we are kept in sync with the device's Mute state.
-- we are not kept in sync with the device's Volume state and its value may be wrong.
local RENDERING_CONTROL
    = table.concat({UPnP.USN.UPNP_ORG, UPnP.USN.SERVICE_ID, "RenderingControl"}, ":")
local MEDIA_RENDERER
    = table.concat({UPnP.USN.SCHEMAS_UPNP_ORG, UPnP.USN.DEVICE, "MediaRenderer", 1}, ":")

local LOG = "AVR"
local denon
denon = {
    ST = UPnP.USN{[UPnP.USN.URN] = MEDIA_RENDERER},

    AVR = classify.single({
        _init = function(_, self, uuid, upnp)
            self.upnp = upnp
            self.uuid = uuid
            log.debug(LOG, self.uuid)

            -- self.eventing capture is garbage collected with self
            self.eventing = function(_, encoded)
                pcall(function()
                    local event = xml.decode(encoded).root.Event.InstanceID
                    for _, name in ipairs{"Mute", "Volume"} do
                        local value = event[name]
                        if value then
                            self["eventing_" .. name:lower()](self, value._attr.channel, value._attr.val)
                        end
                    end
                end)
            end

            -- search until we find location and device for uuid
            local find_receiver
            self.find_sender, find_receiver = cosock.channel.new()
            local st = UPnP.USN{[UPnP.USN.UUID] = uuid}
            cosock.spawn(function()
                local function find(address, port, header, device)
                    local find_uuid = header.usn.uuid
                    if find_uuid ~= self.uuid then
                        log.error(LOG, self.uuid, "find", "not", find_uuid)
                        return
                    end
                    self.find_sender:send(1)
                    log.debug(LOG, self.uuid, "find", address, port, header.location, device.friendlyName)
                    self.location = header.location
                    self.device = device
                    for _, service in ipairs(device.serviceList.service) do
                        local urn = UPnP.USN(service.serviceId).urn
                        if urn == RENDERING_CONTROL then
                            self.subscription = upnp:eventing_subscribe(
                                header.location, service.eventSubURL, header.usn.uuid, urn, nil, self.eventing)
                            -- unsubscribe is implicit on garbage collection of self
                            break
                        end
                    end
                end

                local discover = denon.Discover(upnp, find, st)
                while true do
                    pcall(discover.search, discover)
                    local ready, select_error = cosock.socket.select({find_receiver}, {}, 60)
                    if select_error then
                        -- stop on unexpected error
                        log.error(LOG, self.uuid, "find", select_error)
                        break
                    end
                    if ready then
                        find_receiver:receive()
                        break
                    end
                end
                log.debug(LOG, self.uuid, "find", "exiting")
            end, table.concat({LOG, self.uuid, "find"}, "\t"))
        end,

        stop = function(self)
            self.find_sender:send(0)
            if self.subscription then
                self.subscription:unsubscribe()
                self.subscription = nil
            end
        end,

        eventing_mute = function(self, channel, value)
            log.warn(LOG, self.uuid, "event", "drop", "mute", channel, value)
        end,

        eventing_volume = function(self, channel, value)
            log.warn(LOG, self.uuid, "event", "drop", "volume", channel, value)
        end,
    }),

    Discover = classify.single({
        _init = function(_, self, upnp, find, st)
            st = st or denon.ST
            self.upnp = upnp
            self.find = find
            self.st = st

            -- self.discovery capture is garbage collected with self
            self.discovery = function(address, port, header, description)
                local device = description.root.device
                if "Denon" == device.manufacturer then
                    self.find(address, port, header, device)
                end
            end

            upnp:discovery_notify(st, self.discovery)
            -- undo is implicit on garbage collection of self
        end,

        search = function(self)
            self.upnp:discovery_search_multicast(self.st)
        end,
    }),
}

return denon
