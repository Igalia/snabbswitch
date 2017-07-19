-- Use of this source code is governed by the Apache 2.0 license; see COPYING.

module(...,package.seeall)

local S = require("syscall")
local lib = require("core.lib")
local ffi = require("ffi")
local yang = require("lib.yang.yang")
local binary = require("lib.yang.binary")
local shm = require("core.shm")

local public_names = {}
local function find_public_name(obj)
   if public_names[obj] then return unpack(public_names[obj]) end
   for modname, mod in pairs(package.loaded) do
      if type(mod) == 'table' then
         for name, val in pairs(mod) do
            if val == obj then
               if type(val) == 'table' and type(val.new) == 'function' then
                  public_names[obj] = { modname, name }
                  return modname, name
               end
            end
         end
      end
   end
   error('could not determine public name for object: '..tostring(obj))
end

local lower_case = "abcdefghijklmnopqrstuvwxyz"
local upper_case = lower_case:upper()
local extra = "0123456789_-"
local alphabet = table.concat({lower_case, upper_case, extra})
assert(#alphabet == 64)
local function random_file_name()
   -- 22 bytes, but we only use 2^6=64 bits from each byte, so total of
   -- 132 bits of entropy.
   local bytes = lib.random_data(22)
   local out = {}
   for i=1,#bytes do
      table.insert(out, alphabet:byte(bytes:byte(i) % 64 + 1))
   end
   local basename = string.char(unpack(out))
   return shm.root..'/'..tostring(S.getpid())..'/app-conf-'..basename
end

function encoder()
   local encoder = { out = {} }
   function encoder:uint32(len)
      table.insert(self.out, ffi.new('uint32_t[1]', len))
   end
   function encoder:string(str)
      self:uint32(#str)
      local buf = ffi.new('uint8_t[?]', #str)
      ffi.copy(buf, str, #str)
      table.insert(self.out, buf)
   end
   function encoder:blob(blob)
      self:uint32(ffi.sizeof(blob))
      table.insert(self.out, blob)
   end
   function encoder:class(class)
      local require_path, name = find_public_name(class)
      self:string(require_path)
      self:string(name)
   end
   function encoder:config(class, arg)
      local file_name = random_file_name()
      if class.yang_schema then
         yang.compile_data_for_schema_by_name(class.yang_schema, arg,
                                              file_name)
      else
         if arg == nil then arg = {} end
         binary.compile_ad_hoc_lua_data_to_file(file_name, arg)
      end
      self:string(file_name)
   end
   function encoder:finish()
      local size = 0
      for _,src in ipairs(self.out) do size = size + ffi.sizeof(src) end
      local dst = ffi.new('uint8_t[?]', size)
      local pos = 0
      for _,src in ipairs(self.out) do
         ffi.copy(dst + pos, src, ffi.sizeof(src))
         pos = pos + ffi.sizeof(src)
      end
      return dst, size
   end
   return encoder
end

local uint32_ptr_t = ffi.typeof('uint32_t*')
function decoder(buf, len)
   local decoder = { buf=buf, len=len, pos=0 }
   function decoder:read(count)
      local ret = self.buf + self.pos
      self.pos = self.pos + count
      assert(self.pos <= self.len)
      return ret
   end
   function decoder:uint32()
      return ffi.cast(uint32_ptr_t, self:read(4))[0]
   end
   function decoder:string()
      local len = self:uint32()
      return ffi.string(self:read(len), len)
   end
   function decoder:blob()
      local len = self:uint32()
      local blob = ffi.new('uint8_t[?]', len)
      ffi.copy(blob, self:read(len), len)
      return blob
   end
   function decoder:class()
      local require_path, name = self:string(), self:string()
      return assert(require(require_path)[name])
   end
   function decoder:config()
      return binary.load_compiled_data_file(self:string()).data
   end
   function decoder:finish(...)
      return { ... }
   end
   return decoder
end

function selftest ()
   print('selftest: apps.config.codec')
   local function serialize(data)
      local tmp = random_file_name()
      print('serializing to:', tmp)
      binary.compile_ad_hoc_lua_data_to_file(tmp, data)
      local loaded = binary.load_compiled_data_file(tmp)
      assert(loaded.schema_name == '')
      assert(lib.equal(data, loaded.data))
      os.remove(tmp)
   end
   serialize('foo')
   serialize({foo='bar'})
   serialize({foo={qux='baz'}})
   serialize(1)
   serialize(1LL)
   print('selftest: ok')
end
