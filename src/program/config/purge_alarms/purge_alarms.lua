-- Use of this source code is governed by the Apache 2.0 license; see COPYING.
module(..., package.seeall)

local common = require("program.config.common")

function run(args)
   args = common.parse_command_line(args, { command='get' })
   local path = '/softwire-config/alarms/alarm-list'
   local response = common.call_leader(
      args.instance_id, 'purge-alarms',
      { schema = args.schema_name, revision = args.revision_date,
        path = args.path, print_default = args.print_default })
   common.print_and_exit(response, 'purged_alarms')
end