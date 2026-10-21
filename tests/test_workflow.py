"""Portable configuration, input isolation, and development-signing boundaries."""
import datetime
import importlib.util
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
from odyssey import make_profile, parse_args
from odyssey_assets import outside_repo, verify_extraction
from sign_install import MEMORY, CLOUD_ENV, CLOUD_IDS, check_ipa, validate_profile
from audit_repo import inspect_entry, TOOL_PREFIX


class WorkflowTests(unittest.TestCase):
    def profile(self):
        return {'TeamIdentifier': ['EXAMPLE123'], 'ExpirationDate': datetime.datetime.now() + datetime.timedelta(days=1),
                'ProvisionedDevices': ['sample-device'], 'Entitlements': {
                    'application-identifier': 'EXAMPLE123.com.example.odyssey', 'get-task-allow': True, MEMORY: True}}

    def test_presets_and_cloud_are_explicit_and_shader_metadata_unchanged(self):
        spec = importlib.util.spec_from_file_location('game', ROOT / 'dm/games/game.py')
        game = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(game)
        for preset, aspect in [('ipad', '4:3'), ('iphone', '239:110')]:
            with tempfile.TemporaryDirectory() as temp:
                path = make_profile(Path(temp), preset, '', True) / '0100000000010000'
                profile = game.Game(path)
                self.assertEqual(profile.get('display_aspect'), aspect)
                self.assertEqual(profile.get('cloud_container', ''), '')
                self.assertIn('#define DM_GAME_FRAME_GENERATION 1', game.header(profile))
                self.assertEqual((path / 'dmsh_chain.h').read_bytes(), (ROOT / 'dm/games/0100000000010000/dmsh_chain.h').read_bytes())
                make_profile(Path(temp), preset, 'iCloud.com.example.odyssey', False)
                header = game.header(game.Game(path))
                self.assertIn('#define DM_GAME_CLOUD_CONTAINER "iCloud.com.example.odyssey"', header)
                self.assertIn('#define DM_GAME_FRAME_GENERATION 0', header)

    def test_repository_and_symlinked_inputs_rejected(self):
        with self.assertRaises(ValueError):
            outside_repo(ROOT / 'ignored-game-folder', ROOT)
        with tempfile.TemporaryDirectory() as temp:
            link = Path(temp) / 'source-link'
            link.symlink_to(ROOT)
            with self.assertRaises(ValueError):
                outside_repo(link / 'game', ROOT)

    def test_wrong_modules_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp)
            (path / 'ExeFS').mkdir()
            (path / 'ExeFS/main').write_bytes(b'synthetic wrong module')
            with self.assertRaisesRegex(ValueError, '1.4.1'):
                verify_extraction(path)

    def test_development_profile_requires_exact_app_memory_and_device(self):
        valid = self.profile()
        self.assertTrue(validate_profile(valid, 'com.example.odyssey', 'sample-device', '')[MEMORY])
        for bundle, device in [('com.other.odyssey', 'sample-device'), ('com.example.odyssey', 'unregistered')]:
            with self.assertRaises(ValueError):
                validate_profile(valid, bundle, device, '')
        valid['Entitlements'][MEMORY] = False
        with self.assertRaises(ValueError):
            validate_profile(valid, 'com.example.odyssey', None, '')

    def test_expiry_distribution_and_cloud_environment_rejected(self):
        profile = self.profile()
        profile['ExpirationDate'] = datetime.datetime.now() - datetime.timedelta(days=1)
        with self.assertRaises(ValueError):
            validate_profile(profile, 'com.example.odyssey', None, '')
        profile = self.profile()
        profile['Entitlements']['get-task-allow'] = False
        with self.assertRaises(ValueError):
            validate_profile(profile, 'com.example.odyssey', None, '')
        profile = self.profile()
        with self.assertRaises(ValueError):
            validate_profile(profile, 'com.example.odyssey', None, 'iCloud.com.example.odyssey')
        profile['Entitlements'].update({CLOUD_IDS: ['iCloud.com.example.odyssey'], CLOUD_ENV: ['Development'],
                                        'com.apple.developer.icloud-services': ['CloudKit']})
        self.assertEqual(validate_profile(profile, 'com.example.odyssey', None, 'iCloud.com.example.odyssey')[CLOUD_ENV], 'Development')

    def test_unsafe_or_multi_app_ipas_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            archive = Path(temp) / 'test.ipa'
            for bad in ['../escape', 'Payload/Other.app/Info.plist']:
                with zipfile.ZipFile(archive, 'w') as z:
                    z.writestr(bad, b'fixture')
                with self.assertRaises(ValueError):
                    check_ipa(archive)
            with zipfile.ZipFile(archive, 'w') as z:
                z.writestr('Payload/DmIOS.app/Info.plist', plistlib.dumps({'CFBundleIdentifier': 'com.example.odyssey'}))
            check_ipa(archive)

    def test_command_requires_input_and_presets_are_validated(self):
        options = parse_args(['--nsp-dir', '/private/game', '--keys', '/private/keys', '--preset', 'iphone'])
        self.assertEqual(options.preset, 'iphone')
        self.assertEqual(options.cloud_container, '')

    def test_publication_rejects_assets_even_when_they_are_plain_text(self):
        self.assertTrue(inspect_entry('shader.metal', b'// private generated shader', {}))
        self.assertTrue(inspect_entry('main', b'NSO0 synthetic fixture', {}))
        self.assertTrue(inspect_entry('archive.zip', b'synthetic', {}))
        self.assertEqual(inspect_entry('host.c', b'// original source\n', {}), [])

    def test_publication_rejects_unknown_binary_and_private_credentials(self):
        self.assertTrue(inspect_entry('unexpected.dat', bytes([255, 254, 253]), {}))
        self.assertTrue(inspect_entry('accident.txt', b'-----BEGIN ' + b'PRIVATE KEY-----', {}))

    def test_only_exact_pinned_tool_bytes_are_exempted_from_text_rule(self):
        import hashlib
        name, payload = TOOL_PREFIX + 'fixture.dll', bytes([255, 254, 253])
        manifest = {name: hashlib.sha256(payload).hexdigest()}
        self.assertEqual(inspect_entry(name, payload, manifest), [])
        self.assertTrue(inspect_entry(name, payload + b'changed', manifest))
        self.assertTrue(inspect_entry(TOOL_PREFIX + 'unlisted.dll', payload, manifest))


if __name__ == '__main__':
    unittest.main()
