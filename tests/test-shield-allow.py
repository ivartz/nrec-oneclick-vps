#!/usr/bin/env python3
"""Exercise batched allow and CNAME handling with a fake SSH shield."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]


class AllowTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='shield-allow-test-')
        self.root = Path(self.tmp.name)
        for directory in ('shield', 'keys', 'bin'):
            (self.root / directory).mkdir()
        shutil.copy(REPO / 'shield-allow.sh', self.root)
        shutil.copy(REPO / 'shield' / 'validation.sh', self.root / 'shield')
        (self.root / 'shield' / 'connection.sh').write_text('SSH=fake-ssh\nGW=mock\n')
        (self.root / 'keys' / 'vps-test.pem').touch()
        self.profile = self.root / 'shield' / 'profile-ubuntu.txt'
        self.profile.write_text('plain.example\n')
        self.conf = self.root / 'dnsmasq.conf'
        self.conf.write_text('nftset=/plain.example/4#inet#shield#allow4\n')
        self.log = self.root / 'calls.log'
        self.env = {**os.environ, 'PATH': str(self.root / 'bin') + ':' + os.environ['PATH'],
                    'MOCK_CONF': str(self.conf), 'MOCK_LOG': str(self.log), 'SHIELD': 'ubuntu'}
        self.stub('fake-ssh', '''#!/bin/bash
printf 'SSH_BEGIN\\n' >> "$MOCK_LOG"
cmd=${1//\\/etc\\/dnsmasq.conf/$MOCK_CONF}
bash -c "$cmd"
''')
        self.stub('sudo', '#!/bin/bash\nexec "$@"\n')
        self.stub('systemctl', '#!/bin/bash\nprintf "restart\\n" >> "$MOCK_LOG"\n')
        self.stub('nft', '#!/bin/bash\nprintf "nft %s\\n" "$*" >> "$MOCK_LOG"\n')
        self.stub('conntrack', '#!/bin/bash\nprintf "conntrack %s\\n" "$*" >> "$MOCK_LOG"\n')
        self.stub('dig', '''#!/bin/bash
printf 'dig %s\\n' "$*" >> "$MOCK_LOG"
case "$3" in
  alias.example) printf 'canonical.example.\\n192.0.2.10\\n192.0.2.11\\n' ;;
  canonical.example) printf '192.0.2.10\\n192.0.2.11\\n' ;;
  plain.example) printf '192.0.2.20\\n' ;;
  bad.example) printf 'https://bad.example/\\n' ;;
esac
''')

    def tearDown(self):
        self.tmp.cleanup()

    def stub(self, name, text):
        path = self.root / 'bin' / name
        path.write_text(text)
        path.chmod(0o755)

    def run_allow(self, *domains):
        return subprocess.run(['bash', 'shield-allow.sh', 'vps-test', *domains],
                              cwd=self.root, env=self.env, text=True, capture_output=True)

    def test_multiple_domains_and_cname_are_batched(self):
        result = self.run_allow('alias.example', 'plain.example')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('CNAME target detected: canonical.example', result.stdout)
        self.assertIn('alias.example -> 192.0.2.11 in allow4', result.stdout)
        self.assertEqual(set(self.profile.read_text().splitlines()),
                         {'alias.example', 'canonical.example', 'plain.example'})
        self.assertEqual(set(self.conf.read_text().splitlines()), {
            f'nftset=/{domain}/4#inet#shield#allow4'
            for domain in ('alias.example', 'canonical.example', 'plain.example')})
        log = self.log.read_text()
        self.assertEqual(log.count('SSH_BEGIN'), 3)
        self.assertEqual(log.count('restart'), 1)
        self.assertIn('nft add element inet shield allow4 { 192.0.2.11 }', log)

    def test_revoke_cname_removes_both_names_and_clears_flows(self):
        self.profile.write_text('plain.example\nalias.example\ncanonical.example\n')
        self.conf.write_text(''.join(f'nftset=/{d}/4#inet#shield#allow4\n'
                                     for d in ('plain.example', 'alias.example', 'canonical.example')))
        result = subprocess.run(['bash', 'shield-allow.sh', '--revoke', 'vps-test', 'alias.example'],
                                cwd=self.root, env=self.env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.profile.read_text(), 'plain.example\n')
        self.assertEqual(self.conf.read_text(), 'nftset=/plain.example/4#inet#shield#allow4\n')
        log = self.log.read_text()
        self.assertIn('dig +short A alias.example @127.0.0.1', log)
        self.assertIn('dig +short A alias.example\n', log)
        self.assertIn('conntrack -D -r 192.0.2.10', log)
        self.assertEqual(log.count('restart'), 1)

    def test_invalid_cname_aborts_without_modifying_profile_or_rules(self):
        result = self.run_allow('bad.example')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('invalid CNAME target', result.stderr)
        self.assertEqual(self.profile.read_text(), 'plain.example\n')
        self.assertEqual(self.conf.read_text(), 'nftset=/plain.example/4#inet#shield#allow4\n')
        self.assertNotIn('restart', self.log.read_text())


if __name__ == '__main__':
    unittest.main()
