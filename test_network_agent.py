import importlib.util
import json
from pathlib import Path
import unittest
from unittest import mock


def load_network_agent():
    module_path = Path(__file__).with_name("network-agent.py")
    spec = importlib.util.spec_from_file_location("network_agent", module_path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


class NetworkAgentTests(unittest.TestCase):
    def test_reconcile_static_addresses_removes_stale_ipv4_address(self):
        network_agent = load_network_agent()
        commands = []

        def fake_run(command, timeout=60):
            commands.append(command)
            if command == ["ip", "-j", "-4", "addr", "show", "dev", "enp0s31f6.1000"]:
                return json.dumps(
                    [
                        {
                            "addr_info": [
                                {"family": "inet", "local": "172.20.0.5", "prefixlen": 24},
                                {"family": "inet", "local": "172.20.0.4", "prefixlen": 24},
                            ]
                        }
                    ]
                )
            return ""

        with mock.patch.object(network_agent, "run", side_effect=fake_run):
            network_agent.reconcile_static_addresses(
                [
                    {
                        "mode": "static",
                        "interfaceName": "enp0s31f6.1000",
                        "address": "172.20.0.4/24",
                    }
                ]
            )

        self.assertIn(
            ["ip", "addr", "del", "172.20.0.5/24", "dev", "enp0s31f6.1000"], commands
        )
        self.assertNotIn(
            ["ip", "addr", "del", "172.20.0.4/24", "dev", "enp0s31f6.1000"], commands
        )


if __name__ == "__main__":
    unittest.main()
