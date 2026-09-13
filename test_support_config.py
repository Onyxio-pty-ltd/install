"""Check support validation and upgrade preservation without touching a host stack."""
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).parent
PLATFORM_INSTALLERS = ('install.sh', 'index.html', 'package-install.sh', 'package-install-online.sh')
TOKEN = 'test-support-token-with-at-least-32-characters'


class SupportConfigTests(unittest.TestCase):
    def validate(self, filename, url, token):
        source = (ROOT / filename).read_text()
        function = re.search(r'^validate_support_config\(\) \{\n.*?^\}', source, re.M | re.S).group()
        result = subprocess.run(
            ['/bin/bash', '-c', 'set -eu\n' + function + '\nvalidate_support_config'],
            env={'PATH': os.environ['PATH'], 'ONYXIO_SUPPORT_URL': url, 'ONYXIO_SUPPORT_TOKEN': token},
            text=True, capture_output=True,
        )
        if token:
            self.assertNotIn(token, result.stdout + result.stderr)
        return result

    def test_valid_origins_and_disabled_configuration(self):
        for filename in PLATFORM_INSTALLERS:
            for url in ('https://ops.example.test', 'https://ops.example.test:8443/',
                        'http://localhost:8081', 'http://127.0.0.1:8081/',
                        'https://[2001:db8::1]:8443'):
                with self.subTest(filename=filename, url=url):
                    result = self.validate(filename, url, TOKEN)
                    self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(self.validate(filename, '', '').returncode, 0)

    def test_invalid_or_partial_configuration_is_rejected(self):
        cases = [('', TOKEN), ('https://ops.example.test', ''),
                 ('https://ops.example.test', 'short'),
                 ('http://ops.example.test', TOKEN),
                 ('ftp://ops.example.test', TOKEN),
                 ('https://ops.example.test/support/new', TOKEN),
                 ('https://ops.example.test?query', TOKEN),
                 ('https://ops.example.test#fragment', TOKEN),
                 ('https://user:password@ops.example.test', TOKEN),
                 ('https://', TOKEN), ('https://ops.example.test\nOTHER=value', TOKEN),
                 ('https://ops.example.test:65536', TOKEN),
                 ('https://ops.example.test:0', TOKEN),
                 ('https://ops.example.test:999999999999999999', TOKEN)]
        for filename in PLATFORM_INSTALLERS:
            for url, token in cases:
                with self.subTest(filename=filename, url=url):
                    result = self.validate(filename, url, token)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn('ONYXIO_SUPPORT_', result.stderr)

    def test_validation_runs_before_installation_work(self):
        for filename in PLATFORM_INSTALLERS:
            source = (ROOT / filename).read_text()
            with tempfile.TemporaryDirectory() as directory:
                if filename.startswith('package-'):
                    function = re.search(r'^validate_support_config\(\) \{\n.*?^\}', source, re.M | re.S).group()
                    start = source.index('ENV_CREATED=false\n')
                    end = source.index('  ENV_CREATED=true', start)
                    script = function + '\n' + source[start:end] + '\nfi\n'
                else:
                    script = source.rsplit('\nmain "$@"', 1)[0]
                    script += '\nrequire_root() { echo INSTALLATION_STARTED; exit 99; }\nmain\n'
                result = subprocess.run(
                    ['/bin/bash', '-c', 'set -eu\n' + script], cwd=directory,
                    env={'PATH': os.environ['PATH'], 'ONYXIO_SUPPORT_TOKEN': TOKEN},
                    text=True, capture_output=True,
                )
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertNotIn('INSTALLATION_STARTED', result.stdout)
                self.assertFalse((Path(directory) / '.env').exists())

    def test_upgrade_preserves_support_settings_and_does_not_enable_old_installs(self):
        source = (ROOT / 'upgrade.sh').read_text().rsplit('\nmain "$@"', 1)[0]
        support = ('ONYXIO_SUPPORT_URL="https://ops.example.test:8443"\n'
                   'ONYXIO_SUPPORT_TOKEN="existing-$$TOKEN-with-32-characters"\n')
        for deployment in ('cloud', 'on-prem'):
            for settings in ('', support):
                with self.subTest(deployment=deployment, configured=bool(settings)), tempfile.TemporaryDirectory() as directory:
                    path = Path(directory) / '.env'
                    path.write_text('ONYXIO_VERSION=old\n' + settings)
                    path.chmod(0o600)
                    result = subprocess.run(
                        ['/bin/bash', '-c', source + '''
ensure_env_defaults
set_env_value "$INSTALL_DIR/.env" ONYXIO_VERSION new
set_env_value "$INSTALL_DIR/.env" ONYXIO_SERVER_IMAGE example:new
'''],
                        env={'PATH': os.environ['PATH'], 'ONYXIO_INSTALL_DIR': directory,
                             'ONYXIO_DEPLOYMENT': deployment,
                             'ONYXIO_SUPPORT_URL': 'https://unrelated.example.test',
                             'ONYXIO_SUPPORT_TOKEN': 'do-not-overwrite-with-this-shell-token'},
                        text=True, capture_output=True,
                    )
                    self.assertEqual(result.returncode, 0, result.stderr)
                    actual = ''.join(line for line in path.read_text().splitlines(keepends=True)
                                     if line.startswith('ONYXIO_SUPPORT_'))
                    self.assertEqual(actual, settings)
                    self.assertEqual(path.stat().st_mode & 0o777, 0o600)
                    self.assertNotIn('existing-', result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
