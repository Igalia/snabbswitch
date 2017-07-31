-- Use of this source code is governed by the Apache 2.0 license; see COPYING.

-- ARP address resolution (RFC 826)

-- Given a remote IPv4 address, try to find out its MAC address.
-- If resolution succeeds:
-- All packets coming through the 'south' interface (ie, via the network card)
-- are silently forwarded (unless dropped by the network card).
-- All packets coming through the 'north' interface (the lwaftr) will have
-- their Ethernet headers rewritten.

module(..., package.seeall)

local bit      = require("bit")
local ffi      = require("ffi")
local packet   = require("core.packet")
local link     = require("core.link")
local lib      = require("core.lib")
local datagram = require("lib.protocol.datagram")
local ethernet = require("lib.protocol.ethernet")
local ipv4     = require("lib.protocol.ipv4")

local C = ffi.C
local receive, transmit = link.receive, link.transmit
local htons, ntohs = lib.htons, lib.ntohs

event = {
   arp_resolving = 'arp-resolving',
   arp_resolved = 'arp-resolved',
}

local ether_header_t = ffi.typeof [[
/* All values in network byte order.  */
struct {
   uint8_t  dhost[6];
   uint8_t  shost[6];
   uint16_t type;
} __attribute__((packed))
]]
local arp_header_t = ffi.typeof [[
/* All values in network byte order.  */
struct {
   uint16_t htype;      /* Hardware type */
   uint16_t ptype;      /* Protocol type */
   uint8_t  hlen;       /* Hardware address length */
   uint8_t  plen;       /* Protocol address length */
   uint16_t oper;       /* Operation */
   uint8_t  sha[6];     /* Sender hardware address */
   uint8_t  spa[4];     /* Sender protocol address */
   uint8_t  tha[6];     /* Target hardware address */
   uint8_t  tpa[4];     /* Target protocol address */
} __attribute__((packed))
]]
local ether_arp_header_t = ffi.typeof(
   'struct { $ ether; $ arp; } __attribute__((packed))',
   ether_header_t, arp_header_t)
local ether_header_ptr_t = ffi.typeof('$*', ether_header_t)
local ether_header_len = ffi.sizeof(ether_header_t)
local ether_arp_header_ptr_t = ffi.typeof('$*', ether_arp_header_t)
local ether_arp_header_len = ffi.sizeof(ether_arp_header_t)
local ether_type_arp = 0x0806
local ether_type_ipv4 = 0x0800
local arp_oper_request = 1
local arp_oper_reply = 2
local arp_htype_ethernet = 1
local arp_ptype_ipv4 = 0x0800
local arp_hlen_ethernet = 6
local arp_plen_ipv4 = 4

local mac_unknown = ethernet:pton("00:00:00:00:00:00")
local mac_broadcast = ethernet:pton("ff:ff:ff:ff:ff:ff")

local function make_arp_packet(src_mac, dst_mac, arp_oper,
                               arp_src_mac, arp_src_ipv4,
                               arp_dst_mac, arp_dst_ipv4)
   local pkt = packet.allocate()
   pkt.length = ether_arp_header_len

   local h = ffi.cast(ether_arp_header_ptr_t, pkt.data)
   h.ether.dhost = dst_mac
   h.ether.shost = src_mac
   h.ether.type = htons(ether_type_arp)
   h.arp.htype, h.arp.ptype = htons(arp_htype_ethernet), htons(arp_ptype_ipv4)
   h.arp.hlen, h.arp.plen = arp_hlen_ethernet, arp_plen_ipv4
   h.arp.oper = htons(arp_oper)
   h.arp.sha = arp_src_mac
   h.arp.spa = arp_src_ipv4
   h.arp.tha = arp_dst_mac
   h.arp.tpa = arp_dst_ipv4

   return pkt
end

local function make_arp_request(src_mac, src_ipv4, dst_ipv4)
   return make_arp_packet(src_mac, mac_broadcast, arp_oper_request,
                          src_mac, src_ipv4, mac_unknown, dst_ipv4)
end

local function make_arp_reply(src_mac, src_ipv4, dst_mac, dst_ipv4)
   return make_arp_packet(src_mac, dst_mac, arp_oper_reply,
                          src_mac, src_ipv4, dst_mac, dst_ipv4)
end

local function is_arp(p)
   if p.length < ether_arp_header_len then return false end
   local h = ffi.cast(ether_arp_header_ptr_t, p.data)
   return ntohs(h.ether.type) == ether_type_arp
end

local function ipv4_eq(a, b) return C.memcmp(a, b, 4) == 0 end
local function mac_eq(a, b)  return C.memcmp(a, b, 6) == 0 end

local function copy_mac(src)
   local dst = ffi.new('uint8_t[6]')
   ffi.copy(dst, src, 6)
   return dst
end

local function random_locally_administered_unicast_mac_address()
   local mac = lib.random_bytes(6)
   -- Bit 0 is 0, indicating unicast.  Bit 1 is 1, indicating locally
   -- administered.
   mac[0] = bit.lshift(mac[0], 2) + 2
   return mac
end

ARP = {}
local arp_config_params = {
   -- Source MAC address will default to a random address.
   self_mac = { default=false },
   -- Source IP is required though.
   self_ip  = { required=true },
   -- The next-hop MAC address can be statically configured.
   next_mac = { default=false },
   -- But if the next-hop MAC isn't configured, ARP will figure it out.
   next_ip  = { default=false }
}

function ARP:new(conf)
   local o = setmetatable(lib.parse(conf, arp_config_params), {__index=ARP})
   if not o.self_mac then
      o.self_mac = random_locally_administered_unicast_mac_address()
   end
   if not o.next_mac then
      assert(o.next_ip, 'ARP needs next-hop IPv4 address to learn next-hop MAC')
      o.arp_request_pkt = make_arp_request(o.self_mac, o.self_ip, o.next_ip)
      o.arp_request_interval = 3 -- Send a new arp_request every three seconds.
   end
   o.event_listeners = {}
   o:add_event_listener(event.arp_resolved, function (ip, mac)
      print(("ARP: '%s' resolved (%s)"):format(ipv4:ntop(ip),ethernet:ntop(mac)))
   end)
   o:add_event_listener(event.arp_resolving, function (ip)
      print(("ARP: Resolving '%s'"):format(ipv4:ntop(ip)))
   end)
   return o
end

function ARP:maybe_send_arp_request (output)
   if self.next_mac then return end
   self.next_arp_request_time = self.next_arp_request_time or engine.now()
   if self.next_arp_request_time <= engine.now() then
      self:emit_event(event.arp_resolving, self.next_ip)
      self:send_arp_request(output)
      self.next_arp_request_time = engine.now() + self.arp_request_interval
   end
end

function ARP:send_arp_request (output)
   transmit(output, packet.clone(self.arp_request_pkt))
end

function ARP:add_event_listener (name, cb)
   if not self.event_listeners[name] then
      self.event_listeners[name] = {}
   end
   table.insert(self.event_listeners[name], cb)
end

function ARP:emit_event (name, ...)
   local listeners = self.event_listeners[name] or {}
   for _, cb in ipairs(listeners) do
      cb(...)
   end
end

function ARP:push()
   local isouth, osouth = self.input.south, self.output.south
   local inorth, onorth = self.input.north, self.output.north

   self:maybe_send_arp_request(osouth)

   for _ = 1, link.nreadable(isouth) do
      local p = receive(isouth)
      if p.length < ether_header_len then
         -- Packet too short.
         packet.free(p)
      elseif is_arp(p) then
         local h = ffi.cast(ether_arp_header_ptr_t, p.data)
         if (ntohs(h.arp.htype) ~= arp_htype_ethernet or
             ntohs(h.arp.ptype) ~= arp_ptype_ipv4 or
             h.arp.hlen ~= 6 or h.arp.plen ~= 4) then
            -- Ignore invalid packet.
         elseif ntohs(h.arp.oper) == arp_oper_request then
            if self.self_ip and ipv4_eq(h.arp.tpa, self.self_ip, 4) then
               transmit(osouth, make_arp_reply(self.self_mac, self.self_ip,
                                               h.arp.sha, h.arp.spa))
            end
         elseif ntohs(h.arp.oper) == arp_oper_reply then
            if ipv4_eq(h.arp.spa, self.next_ip, 4) then
               local next_mac = copy_mac(h.arp.sha)
               self:emit_event(event.arp_resolved, self.next_ip, next_mac)
               self.next_mac = next_mac
            end
         else
            -- Incoming ARP that isn't handled; drop it silently.
         end
         packet.free(p)
      else
         transmit(onorth, p)
      end
   end

   for _ = 1, link.nreadable(inorth) do
      local p = receive(inorth)
      if not self.next_mac then
         -- drop all southbound packets until the next hop's ethernet address is known
         packet.free(p)
      else
         local e = ffi.cast(ether_header_ptr_t, p.data)
         e.dhost = self.next_mac
         e.shost = self.self_mac
         transmit(osouth, p)
      end
   end
end

function selftest()
   print('selftest: arp')

   local arp = ARP:new({ self_ip = ipv4:pton('1.2.3.4'),
                         next_ip = ipv4:pton('5.6.7.8') })
   arp.input  = { south=link.new('south in'),  north=link.new('north in') }
   arp.output = { south=link.new('south out'), north=link.new('north out') }

   -- After first push, ARP should have sent out request.
   arp:push()
   assert(link.nreadable(arp.output.south) == 1)
   assert(link.nreadable(arp.output.north) == 0)
   local req = link.receive(arp.output.south)
   assert(is_arp(req))
   -- Send a response.
   local rep = make_arp_reply(ethernet:pton('11:22:33:44:55:66'),
                              ipv4:pton('5.6.7.8'),
                              ethernet:pton('22:22:22:22:22:22'),
                              ipv4:pton('2.2.2.2'))
   packet.free(req)
   assert(is_arp(rep))
   link.transmit(arp.input.south, rep)
   -- Process response.
   arp:push()
   assert(link.nreadable(arp.output.south) == 0)
   assert(link.nreadable(arp.output.north) == 0)

   -- Now push some payload.
   local payload = datagram:new()
   local udp = require("lib.protocol.udp")
   local IP_PROTO_UDP  = 17
   local udp_h = udp:new({ src_port = 1234,
                           dst_port = 5678 })
   local ipv4_h = ipv4:new({ src = ipv4:pton('1.1.1.1'),
                             dst = ipv4:pton('2.2.2.2'),
                             protocol = IP_PROTO_UDP,
                             ttl = 64 })
   payload:push(udp_h)
   payload:push(ipv4_h)
   payload:push(ethernet:new({ src = ethernet:pton("00:00:00:00:00:00"),
                               dst = ethernet:pton("00:00:00:00:00:00"),
                               type = ether_type_ipv4 }))
   link.transmit(arp.input.north, payload:packet())
   arp:push()
   assert(link.nreadable(arp.output.south) == 1)
   assert(link.nreadable(arp.output.north) == 0)

   -- The packet should have the destination ethernet address set.
   local routed = link.receive(arp.output.south)
   local payload = datagram:new(routed, ethernet)
   local eth_h = payload:parse()
   assert(eth_h:src_eq(arp.self_mac))
   assert(eth_h:dst_eq(ethernet:pton('11:22:33:44:55:66')))
   assert(ipv4_h:eq(payload:parse()))
   assert(udp_h:eq(payload:parse()))
   packet.free(payload:packet())
   print('selftest ok')
end
