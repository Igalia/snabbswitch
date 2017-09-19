module(..., package.seeall)

function run (args)
   local opts = { command='get-alarms-state', with_path=true, is_config=false }
   args = common.parse_command_line(args, opts)
   local response = common.call_leader(
      args.instance_id, 'get-alarms-state',
      { schema = args.schema_name, revision = args.revision_date,
        path = args.path, print_default = args.print_default,
        format = args.format })
   common.print_and_exit(response, "state")
end