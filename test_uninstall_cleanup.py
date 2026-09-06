"""Check container cleanup isolation using a fake Docker CLI."""
import os
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).parent


class UninstallCleanupTests(unittest.TestCase):
    def test_platform_cleanup_does_not_remove_management_containers(self):
        source = (ROOT / 'uninstall.sh').read_text().rsplit('\nmain "$@"', 1)[0]
        script = source + '''
docker_available() { return 0; }
docker() {
  case "$*" in
    'ps -a --filter label=com.docker.compose.project=onyxio --format {{.ID}}')
      echo platform-container ;;
    'ps -a --format {{.ID}} {{.Names}}')
      echo 'platform-container onyxio-onyxio-1'
      echo 'management-container onyxio-management-onyxio-1' ;;
    'rm -f '*) echo "$*" >&2 ;;
    *) echo "Unexpected Docker command: $*" >&2; return 1 ;;
  esac
}
remove_leftover_containers
'''
        result = subprocess.run(
            ['/bin/bash', '-c', script],
            env={**os.environ, 'ONYXIO_INSTALL_DIR': '/opt/onyxio'},
            text=True, capture_output=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('rm -f platform-container', result.stderr)
        self.assertNotIn('rm -f management-container', result.stderr)


if __name__ == '__main__':
    unittest.main()
