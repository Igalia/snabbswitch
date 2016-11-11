module(...,package.seeall)

-- Ingress packet drop monitor timer.

local ffi = require("ffi")

-- Every 100 milliseconds.
local interval = 1e8

local with_restart = core.app.with_restart
local now = core.app.now

ingress_drop_monitor = {
   threshold = 100000,
   wait = 20,
   last_flush = 0,
   last_value = ffi.new('uint64_t[1]'),
   current_value = ffi.new('uint64_t[1]'),
}

function new(args)
   local ret = {
      threshold = args.threshold or 100000,
      wait = args.wait or 20,
      action = args.action or 'flush',
      tips_url = args.tips_url or default_tips_url,
      last_flush = 0,
      last_value = ffi.new('uint64_t[1]'),
      current_value = ffi.new('uint64_t[1]')
   }
   if args.counter then
      if not args.counter:match(".counter$") then
         args.counter = args.counter..".counter"
      end
      if not shm.exists(args.counter) then
         ret.counter = counter.create(args.counter, 0)
      else
         ret.counter = counter.open(args.counter)
      end
   end
   return setmetatable(ret, {__index=IngressDropMonitor})
end

function IngressDropMonitor:sample ()
   local app_array = engine.breathe_push_order
   local sum = self.current_value
   sum[0] = 0
   for i = 1, #app_array do
      local app = app_array[i]
      if app.ingress_packet_drops and not app.dead then
         local status, value = with_restart(app, app.ingress_packet_drops)
         if status then sum[0] = sum[0] + value end
      end
   end
end

function ingress_drop_monitor:jit_flush_if_needed ()
   if self.current_value[0] - self.last_value[0] < self.threshold then return end
   if now() - self.last_flush < self.wait then return end
   self.last_flush = now()
   self.last_value[0] = self.current_value[0]
   jit.flush()
   print("jit.flush")
   --- TODO: Change last_flush, last_value and current_value fields to be counters.
end

local function fn ()
   ingress_drop_monitor:sample()
   ingress_drop_monitor:jit_flush_if_needed()
end

return timer.new("ingress drop monitor", fn, interval, "repeating")
