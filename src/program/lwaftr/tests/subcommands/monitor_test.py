"""
Test the "snabb lwaftr monitor" subcommand. Needs a NIC name and a TAP interface.

1. Execute "snabb lwaftr run" in on-a-stick mode and with the mirror option set.
2. Run "snabb lwaftr monitor" to set the counter and check its output.
"""

import unittest

from lib import sh
from lib.test_env import DATA_DIR, SNABB_CMD, nic_names, tap_name


SNABB_PCI0 = nic_names()[0]
TAP_IFACE, tap_err_msg = tap_name()


@unittest.skipUnless(SNABB_PCI0, 'NIC not configured')
@unittest.skipUnless(TAP_IFACE, tap_err_msg)
class TestMonitor(unittest.TestCase):

    run_cmd_args = (
        SNABB_CMD, 'lwaftr', 'run',
        '--name', 'monitor_test',
        '--bench-file', '/dev/null',
        '--conf', DATA_DIR / 'icmp_on_fail.conf',
        '--on-a-stick', SNABB_PCI0,
        '--mirror', TAP_IFACE,
    )

    monitor_cmd_args = (
        SNABB_CMD, 'lwaftr', 'monitor',
        '--name', 'monitor_test',
        'all',
    )

    # Use setUpClass to only setup the "run" daemon once for all tests.
    @classmethod
    def setUpClass(cls):
        cls.run_cmd = sh.sudo(*cls.run_cmd_args,
            _bg=True, _err_to_out=True, _out=cls.run_cmd_out, _tty_out=False)

    @classmethod
    def run_cmd_out(cls, line):
        """
        Needed to see the daemon's stdout and stderr if it fails.
        The _done attribute is not working well.
        """
        print('Run command:', line)

    def test_monitor(self):
        output = sh.sudo(*self.monitor_cmd_args)
        self.assertIn('Mirror address set', output)
        self.assertIn('255.255.255.255', output)

    @classmethod
    def tearDownClass(cls):
        try:
            cls.run_cmd.terminate()
        except ProcessLookupError:
            # It was already gone.
            pass


if __name__ == '__main__':
    unittest.main()
