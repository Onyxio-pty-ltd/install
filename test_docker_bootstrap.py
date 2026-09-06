"""Exercise installer prerequisite handling without touching host packages or Docker."""
import os
from pathlib import Path
import re
import subprocess
import unittest

ROOT = Path(__file__).parent
INSTALLERS = ('install.sh', 'index.html', 'ops-install.sh')
MOCKS = r'''
engine=${TEST_ENGINE:-false}
plugin=${TEST_PLUGIN:-false}
running=${TEST_RUNNING:-false}
command() {
  if [ "${1:-}" = '-v' ]; then
    case "$2" in
      docker) [ "$engine" = true ]; return ;;
      docker-compose) [ "${TEST_LEGACY:-false}" = true ]; return ;;
      apt-get|apt-cache|add-apt-repository) return 0 ;;
      systemctl) [ "${TEST_SYSTEMD:-true}" = true ]; return ;;
    esac
  fi
  builtin command "$@"
}
docker_host_os() { echo "${TEST_OS:-ubuntu}"; }
docker() {
  case "$1" in
    compose) [ "$engine" = true ] && [ "$plugin" = true ] ;;
    info) [ "$engine" = true ] && [ "$running" = true ] ;;
    *) return 1 ;;
  esac
}
docker-compose() { [ "${TEST_LEGACY:-false}" = true ]; }
apt-cache() {
  if [ "$2" = docker-compose-plugin ]; then [ "${TEST_OFFICIAL:-false}" = true ]; return; fi
  [ "${TEST_UNIVERSE:-true}" = true ]
}
apt-get() {
  echo "apt-get $*"
  [ "${TEST_APT_FAIL:-false}" != true ] || return 42
  case " $* " in *' install '*)
    case " $* " in *' docker.io '*) engine=true ;; esac
    case " $* " in *' docker-compose-v2 '*|*' docker-compose-plugin '*) plugin=true ;; esac
  esac
}
add-apt-repository() { echo "add-apt-repository $*"; TEST_UNIVERSE=true; }
systemctl() { echo "systemctl $*"; [ "${TEST_DAEMON_FAIL:-false}" != true ] || return 43; running=true; }
'''


class DockerBootstrapTests(unittest.TestCase):
    def run_bootstrap(self, filename, **variables):
        source = (ROOT / filename).read_text()
        functions = '\n'.join(re.findall(r'^(?:docker_host_os|require_docker)\(\) \{\n.*?^\}', source, re.M | re.S))
        self.assertIn('require_docker()', functions)
        script = 'set -euo pipefail\n' + functions + '\n' + MOCKS + '\nrequire_docker\necho READY\n'
        env = {**os.environ, **{'TEST_' + key.upper(): value for key, value in variables.items()}}
        return subprocess.run(['/bin/bash', '-c', script], env=env, capture_output=True, text=True)

    def test_fresh_ubuntu_installs_engine_and_compose_and_starts_docker(self):
        for name in INSTALLERS:
            with self.subTest(name=name):
                result = self.run_bootstrap(name)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn('docker.io', result.stdout)
                self.assertIn('docker-compose-v2', result.stdout)
                self.assertIn('--no-remove', result.stdout)
                self.assertIn('systemctl enable --now docker', result.stdout)
                self.assertIn('READY', result.stdout)

    def test_ready_hosts_do_not_install_or_restart_anything(self):
        for name in INSTALLERS:
            with self.subTest(name=name):
                result = self.run_bootstrap(name, engine='true', plugin='true', running='true', os='other')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertNotIn('apt-get', result.stdout)
                self.assertNotIn('systemctl', result.stdout)

    def test_missing_compose_does_not_replace_existing_engine(self):
        for official, package in [('false', 'docker-compose-v2'), ('true', 'docker-compose-plugin')]:
            result = self.run_bootstrap('ops-install.sh', engine='true', running='true', official=official)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(package, result.stdout)
            self.assertNotIn('docker.io', result.stdout)
            self.assertNotIn('systemctl', result.stdout)

    def test_legacy_compose_is_preserved(self):
        result = self.run_bootstrap('install.sh', engine='true', legacy='true', running='true')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('apt-get', result.stdout)

    def test_missing_universe_is_enabled(self):
        result = self.run_bootstrap('install.sh', universe='false')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('add-apt-repository -y universe', result.stdout)

    def test_stopped_daemon_is_started_without_reinstalling(self):
        result = self.run_bootstrap('install.sh', engine='true', plugin='true')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('apt-get', result.stdout)
        self.assertIn('systemctl enable --now docker', result.stdout)

    def test_unsupported_os_fails_before_package_installation(self):
        result = self.run_bootstrap('install.sh', os='other')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('apt-get', result.stdout)
        self.assertIn('Ubuntu', result.stderr)

    def test_package_failure_stops_installation(self):
        result = self.run_bootstrap('install.sh', apt_fail='true')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('READY', result.stdout)
        self.assertNotIn('systemctl', result.stdout)

    def test_daemon_failure_stops_installation(self):
        result = self.run_bootstrap('install.sh', engine='true', plugin='true', daemon_fail='true')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('READY', result.stdout)

    def test_missing_service_manager_reports_unreachable_daemon(self):
        result = self.run_bootstrap('install.sh', engine='true', plugin='true', systemd='false')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('daemon', result.stderr)

    def test_online_endpoints_stay_in_sync(self):
        self.assertEqual((ROOT / 'install.sh').read_bytes(), (ROOT / 'index.html').read_bytes())
        functions = [re.search(r'^require_docker\(\) \{\n.*?^\}', (ROOT / name).read_text(), re.M | re.S).group() for name in INSTALLERS]
        self.assertEqual(functions[0], functions[2])


if __name__ == '__main__':
    unittest.main()
