import os
import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import pathlib
import stat
import subprocess
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).with_name('install-casting-host.sh')
CODE = 'oce_01234567-0123-4567-8901-012345678901.' + 'b' * 43
TOKEN = 'ocm_01234567-0123-4567-8901-012345678901.' + 'a' * 43

class CastingCredentials(unittest.TestCase):
    def install(self, folder, credential, use_prompt=False, enrollment_url=None):
        source = SCRIPT.read_text().rsplit('\nmain "$@"', 1)[0]
        secret = pathlib.Path(folder) / 'input-credential'
        secret.write_text(credential)
        env = dict(os.environ, ONYXIO_INSTALL_DIR=str(pathlib.Path(folder) / 'installed'),
                   CASTING_MODULE_CREDENTIAL_FILE=str(secret), CASTING_HOST_ID='host-1',
                   CASTING_HOST_SITE_ID='site-1', CASTING_HOST_NAME='Module',
                   CASTING_CONTROL_PLANE_WS_URL='wss://example.test')
        if use_prompt:
            env.pop('CASTING_MODULE_CREDENTIAL_FILE')
            env['TEST_CREDENTIAL_PROMPT'] = credential
        if enrollment_url:
            env.pop('CASTING_MODULE_CREDENTIAL_FILE')
            env['CASTING_CONTROL_PLANE_WS_URL'] = enrollment_url
        harness = source + '''
require_root() { :; }
require_safe_install_dir() { :; }
require_docker() { :; }
require_network_agent_dependencies() { :; }
require_package_platform() { :; }
resolve_server_image() { SERVER_IMAGE=example.test/server:test; }
install_network_agent() { :; }
install_self_if_possible() { :; }
load_local_images_if_available() { :; }
pull_image_if_needed() { :; }
check_control_plane_reachability() { :; }
wait_for_casting_host() { :; }
prompt_secret() { printf '%s' "$TEST_CREDENTIAL_PROMPT"; }
prompt() { printf '%s' "$2"; }
compose() { printf '%s\\n' "$*" > "$INSTALL_DIR/compose-args"; }
main
'''
        harness_file = pathlib.Path(folder) / 'harness.sh'
        harness_file.write_text(harness)
        return subprocess.run(['bash', str(harness_file)] + (['--enrollment-stdin'] if enrollment_url else []),
                              input=credential + '\n' if enrollment_url else None, env=env, text=True, capture_output=True)

    def test_private_credential_file_and_forced_restart(self):
        with tempfile.TemporaryDirectory() as folder:
            installed = pathlib.Path(folder) / 'installed'
            installed.mkdir()
            (installed / '.env').write_text('CASTING_HOST_TOKEN=obsolete-global\nCASTING_MODULE_CREDENTIAL=obsolete-inline\n')
            result = self.install(folder, TOKEN)
            self.assertEqual(result.returncode, 0, result.stderr)
            installed = pathlib.Path(folder) / 'installed'
            secret = installed / 'module-credential'
            self.assertEqual(secret.read_text().strip(), TOKEN)
            self.assertEqual(stat.S_IMODE(secret.stat().st_mode), 0o600)
            for output in [result.stdout, result.stderr, (installed / '.env').read_text(),
                           (installed / 'docker-compose.casting-host.yml').read_text()]:
                self.assertNotIn(TOKEN, output)
                self.assertNotIn('CASTING_HOST_TOKEN', output)
            self.assertIn('--force-recreate', (installed / 'compose-args').read_text())

    def test_rotation_requires_new_command_instead_of_reusing_revoked_file(self):
        with tempfile.TemporaryDirectory() as folder:
            installed = pathlib.Path(folder) / 'installed'
            installed.mkdir()
            (installed / 'module-credential').write_text('ocm_01234567-0123-4567-8901-012345678901.' + 'b' * 43)
            result = self.install(folder, TOKEN, use_prompt=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotEqual((installed / 'module-credential').read_text().strip(), TOKEN)
            self.assertNotIn(TOKEN, result.stdout + result.stderr)

    def test_enrollment_exchange_keeps_permanent_credential_out_of_output(self):
        requests = []
        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass
            def do_POST(self):
                requests.append((self.path, json.loads(self.rfile.read(int(self.headers['Content-Length'])))))
                self.send_response(200 if len(requests) == 1 else 401)
                self.end_headers()
                self.wfile.write(json.dumps({'credential': TOKEN} if len(requests) == 1 else {'error': 'already used'}).encode())
        server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        try:
            with tempfile.TemporaryDirectory() as folder:
                url = 'http://127.0.0.1:' + str(server.server_port)
                result = self.install(folder, CODE, enrollment_url=url)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(requests[0], ('/casting/enroll', {'enrollmentCode': CODE, 'hostId': 'host-1', 'siteId': 'site-1'}))
                installed = pathlib.Path(folder) / 'installed'
                self.assertEqual((installed / 'module-credential').read_text().strip(), TOKEN)
                for secret in [CODE, TOKEN]:
                    self.assertNotIn(secret, result.stdout + result.stderr + (installed / '.env').read_text())
                replay = self.install(folder, CODE, enrollment_url=url)
                self.assertNotEqual(replay.returncode, 0)
                self.assertNotIn(CODE, replay.stderr)
                self.assertEqual((installed / 'module-credential').read_text().strip(), TOKEN, 'Failed redemption must preserve the installed credential')
        finally:
            server.shutdown()
            server.server_close()
            worker.join()

    def test_global_token_is_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            result = self.install(folder, 'old-global-token')
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse((pathlib.Path(folder) / 'installed/module-credential').exists())
            self.assertNotIn('old-global-token', result.stdout + result.stderr)

if __name__ == '__main__':
    unittest.main()
