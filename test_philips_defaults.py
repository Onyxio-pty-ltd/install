"""Exercise generated Philips settings without installing or restarting services."""
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).parent


class PhilipsDefaultsTests(unittest.TestCase):
    def generate(self, filename, cloud, setting=None, upgrade=False):
        source = (ROOT / filename).read_text()
        with tempfile.TemporaryDirectory() as directory:
            env = {
                'PATH': os.environ['PATH'],
                'HOME': os.environ['HOME'],
                'ONYXIO_INSTALL_DIR': directory,
                'PUBLIC_SERVER_URL': 'http://example.test',
            }
            if cloud:
                env['ONYXIO_DEPLOYMENT'] = 'cloud'
            env_file = Path(directory) / '.env'
            if upgrade:
                env_file.write_text('' if setting is None else
                                    f'PHILIPS_WEBSERVICES_ENABLED={setting}\n')
                script = source.rsplit('\nmain "$@"', 1)[0]
                script += '\nensure_env_defaults\n'
            else:
                if setting is not None:
                    env['PHILIPS_WEBSERVICES_ENABLED'] = setting
                if filename.startswith('package-'):
                    cloud_function = re.search(
                        r'^is_cloud_install\(\) \{\n.*?^\}', source, re.M | re.S
                    ).group()
                    start = source.index('  cat > .env <<EOF')
                    end = source.index('\nelse\n  echo "Onyxio is already installed', start)
                    script = cloud_function + '\n' + source[start:end]
                    env.update(VERSION='test', SERVER_IP='192.0.2.1',
                               PUBLIC_URL='http://example.test', NETWORK_APPLY_MODE='agent',
                               CASTING_HOST_TOKEN='test', POSTGRES_PASSWORD='test',
                               JWT_SECRET='test')
                else:
                    script = source.rsplit('\nmain "$@"', 1)[0]
                    script += '\nwrite_env_file 192.0.2.1\n'
            result = subprocess.run(
                ['/bin/bash', '-c', script], cwd=directory, env=env,
                text=True, capture_output=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            values = [line.split('=', 1)[1] for line in env_file.read_text().splitlines()
                      if line.startswith('PHILIPS_WEBSERVICES_ENABLED=')]
            self.assertEqual(len(values), 1, values)
            return values[0]

    def test_fresh_installs_default_to_enabled_and_allow_explicit_disable(self):
        for filename in ('install.sh', 'index.html', 'package-install.sh',
                         'package-install-online.sh'):
            for cloud in (False, True):
                for setting in (None, 'true', 'false'):
                    with self.subTest(filename=filename, cloud=cloud, setting=setting):
                        self.assertEqual(self.generate(filename, cloud, setting),
                                         setting or 'true')

    def test_upgrade_defaults_to_enabled_and_preserves_existing_choice(self):
        for cloud in (False, True):
            for setting in (None, 'true', 'false'):
                with self.subTest(cloud=cloud, setting=setting):
                    self.assertEqual(self.generate('upgrade.sh', cloud, setting, upgrade=True),
                                     setting or 'true')


if __name__ == '__main__':
    unittest.main()
