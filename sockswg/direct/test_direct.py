#!/usr/bin/env python3
"""Rootless regression tests; Python 3.11+, no network or service mutations."""
import importlib.machinery
import importlib.util
import pathlib
import subprocess
import tempfile
import time
import tomllib
import unittest
from unittest.mock import patch

HERE = pathlib.Path(__file__).resolve().parent
loader = importlib.machinery.SourceFileLoader('direct', str(HERE / 'soga-warp-direct'))
spec = importlib.util.spec_from_loader(loader.name, loader)
direct = importlib.util.module_from_spec(spec)
loader.exec_module(direct)

ROUTES = '''enable=true
[[routes]]
rules=["geosite:google"]
[[routes.Outs]]
type="socks"
server="127.0.0.1"
port=40000
[[routes]]
rules=["domain:example.com"]
[[routes.Outs]]
type="socks"
server="192.0.2.1"
port=1080
[[routes]]
rules=["*"]
[[routes.Outs]]
type="direct"
'''

class RoutingTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = pathlib.Path(self.tmp.name)
        self.routes = self.base / 'routes.toml'
        self.routes.write_text(ROUTES)
        for target, value in [('BASE', self.base), ('ROUTES', self.routes)]:
            p = patch.object(direct, target, value)
            p.start(); self.addCleanup(p.stop)
        p = patch.object(direct, 'ensure')
        p.start(); self.addCleanup(p.stop)

    def test_a_b_switch_preserves_inode_and_unrelated_routes(self):
        inode = self.routes.stat().st_ino
        other = tomllib.loads(ROUTES)['routes'][1:]
        for slot, source in [('a', '172.16.0.2'), ('b', '10.203.2.1'), ('a', '172.16.0.2')]:
            direct.select(slot)
            result = tomllib.loads(self.routes.read_text())
            self.assertEqual(result['routes'][1:], other)
            self.assertEqual(result['routes'][0]['Outs'][0]['listen_ipv4'], source)
            self.assertEqual(result['routes'][0]['Outs'][0]['type'], 'direct')
            self.assertEqual(self.routes.stat().st_ino, inode)

    def test_unchanged_selection_does_not_extend_drain_hold(self):
        direct.select('a')
        before = (self.base / 'selected_at').read_text()
        direct.select('a')
        self.assertEqual((self.base / 'selected_at').read_text(), before)

    def test_missing_managed_route_fails_without_edit(self):
        self.routes.write_text('enable=true\n')
        with self.assertRaises(RuntimeError):
            direct.select('a')
        self.assertEqual(self.routes.read_text(), 'enable=true\n')

    def test_invalid_toml_does_not_replace_existing_file(self):
        broken = ROUTES + '\nbroken=[\n'
        self.routes.write_text(broken)
        with self.assertRaises(tomllib.TOMLDecodeError):
            direct.select('a')
        self.assertEqual(self.routes.read_text(), broken)

    def test_tcp_and_udp_flows_block_repair_but_listener_does_not(self):
        (self.base / 'selected_at').write_text(str(time.time() - 1000))
        def result(text):
            return subprocess.CompletedProcess([], 0, text, '')
        listener = 'LISTEN 0 4096 10.203.2.1:10001 0.0.0.0:* users:(("soga",pid=1,fd=3))'
        ingress = 'UNCONN 0 0 10.203.2.1:10001 0.0.0.0:* users:(("soga",pid=1,fd=4))'
        outgoing = 'UNCONN 0 0 10.203.2.1:40123 0.0.0.0:* users:(("soga",pid=1,fd=5))'
        with patch.object(direct, 'run', side_effect=[result(''), result(listener), result(ingress)]):
            self.assertTrue(direct.drained('b'))
        with patch.object(direct, 'run', side_effect=[result(''), result(listener), result(outgoing)]):
            self.assertFalse(direct.drained('b'))
        with patch.object(direct, 'run', return_value=result('0 0 10.203.2.1:1234 1.1.1.1:443 users:(("soga",pid=1,fd=2))')):
            self.assertFalse(direct.drained('b'))

class ProbeTests(unittest.TestCase):
    def shell(self, body):
        library = (HERE / 'sockswg-bluegreen').read_text().split('case "${1:-}" in')[0]
        with tempfile.TemporaryDirectory() as directory:
            prefix = f"BASE_DIR='{directory}'\nSTATE_DIR='{directory}'\nSETTINGS_FILE='{directory}/absent'\n"
            return subprocess.check_output(['bash'], input=prefix + library + '\n' + body, text=True)

    def test_probe_paths_bind_sources_without_socks(self):
        output = self.shell('''curl() { printf '%s\\n' "$@"; }
trace_via 172.16.0.2
trace_via 10.203.2.1
''')
        self.assertNotIn('--socks', output)
        self.assertIn('--interface\n172.16.0.2', output)
        self.assertIn('--interface\n10.203.2.1', output)
        self.assertEqual(output.count('--noproxy\n*'), 2)

    def test_gemini_error_is_still_rejected(self):
        output = self.shell('''printf '%s' 'BardErrorInfo,[1060]' > "$BASE_DIR/response"
if classify_gemini_response "$BASE_DIR/response" 200; then exit 77; fi
''')
        self.assertIn('bard-error-1060', output)

    def test_lifecycle_cannot_start_socks(self):
        for filename in ['sockswg-bluegreen', 'sockswg-watchdog']:
            script = (HERE / filename).read_text()
            self.assertNotIn('--socks5', script)
            self.assertNotIn('systemctl restart sockswg.service', script)
            self.assertNotIn('systemctl start sockswg.service', script)
        unit = (HERE / 'sockswg-bluegreen-b.service').read_text()
        self.assertNotIn('danted', unit)
        self.assertNotIn('cleanup-b', unit)
        self.assertIn('Type=oneshot', unit)

    def test_two_failures_switch_only_to_a_healthy_peer(self):
        output = self.shell('''require_root() { :; }
flock() { :; }
log() { printf '%s\\n' "$*"; }
health_a() { return 1; }
health_b() { return "$B_FAIL"; }
public_ip_b() { printf '192.0.2.1'; }
rotation_due() { return 1; }
switch_b() { printf 'b\\n' > "$ACTIVE_FILE"; }
printf 'a\\n' > "$ACTIVE_FILE"
B_FAIL=1
check
check
[ "$(cat "$ACTIVE_FILE")" = a ]
counter_set a_fail 0
B_FAIL=0
check
[ "$(cat "$ACTIVE_FILE")" = a ]
check
[ "$(cat "$ACTIVE_FILE")" = b ]
printf 'state-machine-ok\\n'
''')
        self.assertIn('state-machine-ok', output)

if __name__ == '__main__':
    unittest.main()
