"""Verify generated Ops configuration can coexist with platform defaults."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).parent


class OpsPortTests(unittest.TestCase):
    def generate(self, directory, **overrides):
        source = (ROOT / 'ops-install.sh').read_text().rsplit('\nmain "$@"', 1)[0]
        env = {
            'PATH': os.environ['PATH'],
            'HOME': os.environ['HOME'],
            'ONYXIO_INSTALL_DIR': str(directory),
            'ONYXIO_ENABLE_HTTPS': 'true',
            'HTTPS_HOST': 'support.example.com',
            **overrides,
        }
        result = subprocess.run(
            ['/bin/bash', '-c', source + '''
write_compose_file
write_https_files
write_env_file https://support.example.com
configure_https_env
'''], env=env, text=True, capture_output=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        config = subprocess.run(
            ['docker', 'compose', '--project-directory', str(directory),
             '-f', str(directory / 'docker-compose.yml'),
             '-f', str(directory / 'docker-compose.https.yml'),
             'config', '--format', 'json'],
            env={'PATH': os.environ['PATH'], 'HOME': os.environ['HOME']},
            text=True, capture_output=True,
        )
        self.assertEqual(config.returncode, 0, config.stderr)
        return json.loads(config.stdout)['services']

    def test_defaults_do_not_claim_platform_ports(self):
        with tempfile.TemporaryDirectory() as directory:
            services = self.generate(Path(directory))
            postgres = services['postgres']['ports'][0]
            app = services['onyxio']['environment']
            proxy = services['https-proxy']['environment']
            self.assertEqual(postgres['host_ip'], '127.0.0.1')
            self.assertEqual(postgres['target'], 5432)
            ports = {int(postgres['published']), int(app['PORT']), int(proxy['HTTPS_PORT'])}
            self.assertTrue(ports.isdisjoint({5432, 80, 443}), ports)
            self.assertEqual(ports, {5433, 8081, 8443})
            self.assertIn('@127.0.0.1:5433/', app['DATABASE_URL'])
            self.assertEqual(proxy['PORT'], app['PORT'])

    def test_custom_ports_reach_database_app_and_proxy(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            services = self.generate(root, POSTGRES_PORT='15433', PORT='18081', HTTPS_PORT='18443')
            self.assertEqual(services['postgres']['ports'][0]['published'], '15433')
            app = services['onyxio']['environment']
            self.assertEqual(app['PORT'], '18081')
            self.assertIn('@127.0.0.1:15433/', app['DATABASE_URL'])
            self.assertIn('@127.0.0.1:15433/', (root / '.env').read_text())
            self.assertEqual(services['https-proxy']['environment']['PORT'], '18081')
            self.assertEqual(services['https-proxy']['environment']['HTTPS_PORT'], '18443')


if __name__ == '__main__':
    unittest.main()
