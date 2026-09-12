"""Verify fresh installer monitoring credentials reach Compose without disclosure."""
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).parent
PLATFORM_INSTALLERS = ('install.sh', 'index.html', 'package-install.sh', 'package-install-online.sh')


class CustomerManagementConfigTests(unittest.TestCase):
    def generate(self, filename, overrides):
        source = (ROOT / filename).read_text()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            env = {
                'PATH': os.environ['PATH'], 'HOME': os.environ['HOME'],
                'ONYXIO_INSTALL_DIR': directory, 'ONYXIO_DEPLOYMENT': 'cloud',
                'PUBLIC_SERVER_URL': 'https://cloud.example.test',
                **overrides,
            }
            if filename.startswith('package-'):
                functions = '\n'.join(re.search(
                    rf'^{name}\(\) \{{\n.*?^\}}', source, re.M | re.S
                ).group() for name in ('quote_compose_env_value', 'is_cloud_install'))
                start = source.index('  cat > .env <<EOF')
                end = source.index('\nelse\n  echo "Onyxio is already installed', start)
                script = 'set -eu\n' + functions + '\n' + source[start:end]
                env.update(POSTGRES_IMAGE='postgres:15', PACKAGE_POSTGRES_IMAGE='postgres:15', VERSION='test', SERVER_IP='192.0.2.1', SERVER_IMAGE='example:test',
                           PUBLIC_URL='https://cloud.example.test', NETWORK_APPLY_MODE='disabled',
                           CASTING_HOST_TOKEN='test', POSTGRES_PASSWORD='test', JWT_SECRET='test')
            else:
                script = source.rsplit('\nmain "$@"', 1)[0]
                script += '\nwrite_env_file ' + ('https://ops.example.test' if filename == 'ops-install.sh' else '192.0.2.1') + '\n'
            result = subprocess.run(['/bin/bash', '-c', script], cwd=root, env=env,
                                    text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            for name, value in overrides.items():
                if 'API_KEY' in name and value:
                    self.assertNotIn(value, result.stdout + result.stderr)
            self.assertEqual((root / '.env').stat().st_mode & 0o777, 0o600)
            (root / 'compose.yml').write_text('services:\n  app:\n    image: example:test\n    env_file: .env\n')
            config = subprocess.run(['docker', 'compose', '-f', str(root / 'compose.yml'),
                                     'config', '--format', 'json'], cwd=root,
                                    env={'PATH': os.environ['PATH'], 'HOME': os.environ['HOME']},
                                    text=True, capture_output=True)
            self.assertEqual(config.returncode, 0, config.stderr)
            service_env = json.loads(config.stdout)['services']['app']['environment']
            # Compose's rendered model re-escapes literal dollars for reuse as YAML/JSON.
            # Check the resolved dotenv environment separately to verify exact key bytes.
            resolved = subprocess.run(['docker', 'compose', '-f', str(root / 'compose.yml'),
                                       'config', '--environment'], cwd=root,
                                      env={'PATH': os.environ['PATH'], 'HOME': os.environ['HOME']},
                                      text=True, capture_output=True)
            self.assertEqual(resolved.returncode, 0, resolved.stderr)
            values = dict(line.split('=', 1) for line in resolved.stdout.splitlines() if '=' in line)
            for name, value in overrides.items():
                if 'API_KEY' in name:
                    self.assertEqual(values[name], value)
                    self.assertEqual(service_env[name], value.replace('$', '$$'))
            return {name: value.replace('$$', '$') if isinstance(value, str) else value
                    for name, value in service_env.items()}

    def test_all_platform_entrypoints_disable_monitoring_by_default(self):
        for filename in PLATFORM_INSTALLERS:
            with self.subTest(filename=filename):
                self.assertEqual(self.generate(filename, {})['ONYXIO_CUSTOMER_MANAGEMENT_API_KEY'], '')

    def test_monitoring_keys_survive_compose_interpolation(self):
        key = 'example-monitoring-key-0123456789-$VALUE-${OTHER}-"quote"-\\slash'
        for filename in PLATFORM_INSTALLERS:
            with self.subTest(filename=filename):
                self.assertEqual(self.generate(filename, {'ONYXIO_CUSTOMER_MANAGEMENT_API_KEY': key})['ONYXIO_CUSTOMER_MANAGEMENT_API_KEY'], key)
        ops = self.generate('ops-install.sh', {
            'ONYXIO_CLOUD_PLATFORM_API_KEY': key,
            'ONYXIO_CLOUD_PLATFORM_URL': 'https://cloud.example.test',
        })
        self.assertEqual(ops['ONYXIO_CLOUD_PLATFORM_API_KEY'], key)
        self.assertEqual(ops['ONYXIO_CLOUD_PLATFORM_URL'], 'https://cloud.example.test')
        self.assertEqual(ops['PUBLIC_URL'], 'https://ops.example.test')

    def test_ops_connection_is_unconfigured_by_default(self):
        ops = self.generate('ops-install.sh', {})
        self.assertEqual(ops['ONYXIO_CLOUD_PLATFORM_API_KEY'], '')
        self.assertEqual(ops['ONYXIO_CLOUD_PLATFORM_URL'], '')

    def test_public_installer_matches_script(self):
        self.assertEqual((ROOT / 'install.sh').read_bytes(), (ROOT / 'index.html').read_bytes())


if __name__ == '__main__':
    unittest.main()
