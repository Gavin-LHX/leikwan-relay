import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import uuid

SPEC = importlib.util.spec_from_file_location('manager', Path(__file__).resolve().parents[1] / 'src/manager.py')
m = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(m)

class ManagerTests(unittest.TestCase):
    def setUp(self):
        self.profile = {'protocol': 'reality', 'host': '192.0.2.10', 'port': 443,
            'sni': 'www.cloudflare.com', 'uuid': str(uuid.uuid4()), 'public_key': 'A' * 43,
            'short_id': '0123456789abcdef', 'flow': 'xtls-rprx-vision'}
        self.node = {'name': 'demo', 'role': 'relay', 'protocol': 'ss2022', 'host': '2001:db8::10',
            'port': 21001, 'bridge_port': 31001, 'listen': '::', 'upstream': self.profile,
            'egress': 'cn2', 'method': '2022-blake3-aes-128-gcm', 'password': 'AAECAwQFBgcICQoLDA0ODw=='}
        self.route = {'interface': 'eth1', 'source': '10.8.0.10', 'gateway': '10.8.0.1', 'prefixlen': 23, 'table': 24002}

    def test_reality_uri_preserves_authentication(self):
        n = dict(self.profile, name='exit', role='exit')
        uri = m.share(n).splitlines()[0]
        parsed = m.parse_upstream(uri)
        for key in self.profile:
            self.assertEqual(parsed[key], self.profile[key])

    def test_anytls_pairing_preserves_certificate_and_password(self):
        p = {'protocol': 'anytls', 'host': '2001:db8::1', 'port': 8443, 'sni': 'test.example',
             'password': 'a:b/?&%+=', 'certificate': '-----BEGIN CERTIFICATE-----\nTEST\n-----END CERTIFICATE-----\n'}
        bundle = 'lkr://' + m.b64(json.dumps(p))
        self.assertEqual(m.parse_upstream(bundle), p)

    def test_rejects_insecure_or_unsupported_upstream(self):
        for uri in ('anytls://password@test.example?insecure=1', 'anytls://p@test.example?allowInsecure=true',
                    'vless://test@test.example?security=tls', 'vless://test@test.example?security=reality&type=ws'):
            with self.subTest(uri=uri), self.assertRaises(ValueError):
                m.parse_upstream(uri)

    def test_ipv6_sharing_uses_brackets(self):
        self.assertIn('@[2001:db8::10]:21001', m.share(self.node))

    def test_ss_uot_export_is_explicit_and_keeps_standard_uri(self):
        n = dict(self.node, ss_uot=True)
        _, cfg = m.client(n)
        self.assertEqual(cfg['outbounds'][0]['udp_over_tcp'], {'enabled': True, 'version': 2})
        self.assertTrue(m.share(n).startswith('ss://'))
        self.assertIn('UoT', m.share(n).splitlines()[1])
        _, native = m.client(self.node)
        self.assertNotIn('udp_over_tcp', native['outbounds'][0])

    def test_invalid_names_cannot_escape_state_directory(self):
        for name in ('../other', 'demo/other', 'x\nExecStart=/bin/sh', '-a', 'a' * 33):
            with self.subTest(name=name), self.assertRaises(ValueError):
                m.node_path(name)

    def test_family_mismatch_fails_before_deployment(self):
        p = dict(self.profile, host='2001:db8::1')
        with self.assertRaises(ValueError):
            m.upstream_outbound(p, self.route)

    def test_each_entry_uses_selected_upstream_without_direct_fallback(self):
        for protocol in ('ss2022', 'snell5', 'vlessenc'):
            n = dict(self.node, protocol=protocol, uuid=str(uuid.uuid4()), decryption='test', encryption='test')
            sb, xr = m.render(n, route_map={'cn2': self.route})
            self.assertEqual(sb['route']['final'], 'upstream')
            self.assertEqual([o['type'] for o in sb['outbounds']], ['vless'])
            self.assertEqual(sb['outbounds'][0]['inet4_bind_address'], '10.8.0.10')
            if protocol == 'vlessenc':
                self.assertEqual(xr['outbounds'][0]['settings']['servers'][0]['port'], n['bridge_port'])
                self.assertEqual(xr['inbounds'][0]['settings']['decryption'], 'test')

    def test_routes_never_change_main_default(self):
        commands = m.route_commands(self.route)
        self.assertTrue(all('table' in c for c in commands))
        self.assertNotIn('main', repr(commands))
        self.assertIn('10.8.0.10/32', commands[-1])

    def test_route_priority_conflict_fails_without_writing(self):
        rules = [{'priority': 24002, 'src': '10.99.0.1', 'table': '24002'}]
        with patch.object(m, 'validate_route', return_value=4), patch.object(m, 'run', return_value=json.dumps(rules)) as run:
            with self.assertRaises(ValueError):
                m.route_apply_one(self.route)
            self.assertEqual(run.call_count, 1)

    def test_route_apply_is_idempotent(self):
        rules = [{'priority': 24002, 'src': '10.8.0.10', 'table': '24002'}]
        with patch.object(m, 'validate_route', return_value=4), patch.object(m, 'run', side_effect=[json.dumps(rules), '', '']) as run:
            m.route_apply_one(self.route)
            self.assertFalse(any('add' in c.args[0] for c in run.call_args_list))

    def test_route_service_has_independent_lock_and_dependency(self):
        self.assertIn('Requires=lkr-routes.service', m.service_text(self.node, 'sing-box'))
        self.assertIn('Requires=lkr-demo-sing-box.service', m.service_text(self.node, 'xray'))

    def test_keypair_accepts_current_and_legacy_cli_labels(self):
        for label in ('Password (PublicKey)', 'Password', 'PublicKey'):
            with patch.object(m, 'run', return_value='PrivateKey: private\n' + label + ': public\nHash32: hash'):
                self.assertEqual(m.keypair(), ('private', 'public'))

@unittest.skipUnless(os.environ.get('LKR_CORE_DIR'), 'set LKR_CORE_DIR for real core schema checks')
class CoreSchemaTests(unittest.TestCase):
    def setUp(self):
        ManagerTests.setUp(self)
    def test_generated_configs_are_accepted_by_pinned_cores(self):
        old = m.BIN
        m.BIN = Path(os.environ['LKR_CORE_DIR'])
        try:
            private, public = m.keypair()
            self.profile['public_key'] = public
            for protocol in ('ss2022', 'ss2022-uot', 'snell5', 'vlessenc'):
                n = dict(self.node, protocol=protocol, uuid=str(uuid.uuid4()),
                    decryption='mlkem768x25519plus.native.600s.' + private,
                    encryption='mlkem768x25519plus.native.1rtt.' + public)
                if protocol == 'ss2022-uot':
                    n.update(protocol='ss2022', ss_uot=True)
                with tempfile.TemporaryDirectory() as tmp:
                    sb, xr = m.render(n, tmp, {'cn2': self.route})
                    # A CI runner does not have our synthetic eth1.
                    sb['outbounds'][0].pop('bind_interface')
                    sb['outbounds'][0].pop('inet4_bind_address')
                    m.save(Path(tmp) / 'sb.json', sb)
                    m.run([m.BIN / 'sing-box', 'check', '-c', Path(tmp) / 'sb.json'])
                    if xr:
                        m.save(Path(tmp) / 'xr.json', xr)
                        m.run([m.BIN / 'xray', 'run', '-test', '-config', Path(tmp) / 'xr.json'])
                    core, cfg = m.client(n)
                    m.save(Path(tmp) / 'client.json', cfg)
                    args = ['check', '-c'] if core == 'sing-box' else ['run', '-test', '-config']
                    m.run([m.BIN / core, *args, Path(tmp) / 'client.json'])
        finally:
            m.BIN = old

if __name__ == '__main__':
    unittest.main()
