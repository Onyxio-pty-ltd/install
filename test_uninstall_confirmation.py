"""Exercise the real confirmation prompt in a PTY without running any cleanup."""
import errno
import os
from pathlib import Path
import pty
import select
import signal
import tempfile
import time
import unittest

ROOT = Path(__file__).parent


class UninstallConfirmationTests(unittest.TestCase):
    def confirm(self, name, answer, metadata=''):
        source = (ROOT / 'uninstall.sh').read_text().rsplit('\nmain "$@"', 1)[0]
        with tempfile.TemporaryDirectory() as directory:
            install_dir = Path(directory) / name
            install_dir.mkdir()
            (install_dir / '.env').write_text(metadata)
            env = {**os.environ, 'ONYXIO_INSTALL_DIR': str(install_dir), 'ONYXIO_UNINSTALL_CONFIRM': 'false'}
            pid, fd = pty.fork()
            if pid == 0:
                os.execve('/bin/bash', ['bash', '-c', source + '\nconfirm\necho CONFIRMED\n'], env)
            output = b''
            sent = False
            finished = False
            deadline = time.monotonic() + 5
            try:
                while time.monotonic() < deadline:
                    if not select.select([fd], [], [], 0.1)[0]:
                        continue
                    try:
                        chunk = os.read(fd, 4096)
                    except OSError as error:
                        if error.errno != errno.EIO:
                            raise
                        chunk = b''
                    if not chunk:
                        finished = True
                        break
                    output += chunk
                    if not sent and b'to continue:' in output:
                        os.write(fd, (answer + '\n').encode())
                        sent = True
                self.assertTrue(finished, output.decode())
            finally:
                if not finished:
                    os.kill(pid, signal.SIGKILL)
                _, status = os.waitpid(pid, 0)
                os.close(fd)
            return os.waitstatus_to_exitcode(status), output.decode()

    def test_management_accepts_its_own_phrase(self):
        code, output = self.confirm('onyxio-management', 'uninstall onyxio-management')
        self.assertEqual(code, 0, output)
        self.assertIn("Type 'uninstall onyxio-management'", output)
        self.assertIn('CONFIRMED', output)

    def test_management_rejects_platform_phrase(self):
        code, output = self.confirm('onyxio-management', 'uninstall onyxio')
        self.assertNotEqual(code, 0, output)
        self.assertNotIn('CONFIRMED', output)

    def test_custom_management_directory_uses_metadata(self):
        for metadata in ['ONYXIO_MANAGEMENT_IMAGE=custom.example/ops:release\n',
                         'ONYXIO_MANAGEMENT_VERSION=latest\n']:
            with self.subTest(metadata=metadata):
                code, output = self.confirm('support', 'uninstall onyxio-management', metadata)
                self.assertEqual(code, 0, output)
                self.assertIn("Type 'uninstall onyxio-management'", output)

    def test_platform_keeps_its_phrase(self):
        code, output = self.confirm('onyxio', 'uninstall onyxio', 'ONYXIO_VERSION=latest\n')
        self.assertEqual(code, 0, output)
        self.assertIn("Type 'uninstall onyxio'", output)

    def test_platform_rejects_management_phrase(self):
        code, output = self.confirm('onyxio', 'uninstall onyxio-management')
        self.assertNotEqual(code, 0, output)
        self.assertNotIn('CONFIRMED', output)


if __name__ == '__main__':
    unittest.main()
