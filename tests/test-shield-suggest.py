#!/usr/bin/env python3
"""Offline regression tests for shield-suggest; no network or VM changes."""
import contextlib
import importlib.util
import io
from pathlib import Path
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('shield_suggest', Path(__file__).resolve().parents[1] / 'shield' / 'suggest.py')
assert spec is not None and spec.loader is not None
suggest = importlib.util.module_from_spec(spec)
spec.loader.exec_module(suggest)


class SuggestTests(unittest.TestCase):
    def test_no_blocks_skips_dns_logs_and_resolution(self):
        out = io.StringIO()
        with patch.object(suggest, 'journal', return_value='') as journal, \
             patch.object(suggest, 'resolve') as resolve, contextlib.redirect_stdout(out):
            suggest.main('vps-test', '20 s ago')
        self.assertIn('nothing blocked', out.getvalue())
        journal.assert_called_once_with('-k', '--since', '20 s ago')
        resolve.assert_not_called()

    def test_correlates_window_boot_subdomains_allowed_and_ptr(self):
        logs = {
            ('-k', '--since', '20 s ago'): '[shield-drop] DST=192.0.2.1\n[shield-drop] DST=192.0.2.2\n',
            ('-u', 'dnsmasq', '--since', '20 s ago'): 'query[A] news.example from 10.99.0.10\n',
            ('-u', 'dnsmasq', '-b'): '\n'.join([
                'query[A] example.com from 10.99.0.10',
                'query[A] www.example.com from 10.99.0.10',
                'query[A] allowed.example from 10.99.0.10',
                'query[A] bad;touch.example from 10.99.0.10',
                'query[A] news.example from 10.99.0.10',
            ]),
        }
        def resolve(name, reverse=False):
            if reverse:
                return name, ['owner.example.'], False
            if name in ('example.com', 'www.example.com'):
                return name, ['192.0.2.1'], False
            return name, [], False
        out = io.StringIO()
        with patch.object(suggest, 'journal', side_effect=lambda *args: logs[args]), \
             patch.object(suggest, 'resolve', side_effect=resolve) as lookup, \
             patch.object(suggest.Path, 'read_text', return_value='nftset=/allowed.example/4#inet#shield#allow4\n'), \
             contextlib.redirect_stdout(out):
            suggest.main('vps-test', '20 s ago')
        text = out.getvalue()
        self.assertIn('example.com', text)
        self.assertIn('1 queries before window', text)
        self.assertIn('192.0.2.2', text)
        self.assertIn('owner.example.', text)
        self.assertIn('./shield-allow.sh vps-test example.com', text)
        self.assertNotIn('www.example.com', text)
        queried = {args.args[0] for args in lookup.call_args_list}
        self.assertNotIn('allowed.example', queried)
        self.assertNotIn('bad;touch.example', queried)

    def test_failed_resolutions_are_reported(self):
        out, err = io.StringIO(), io.StringIO()
        logs = ['[shield-drop] DST=192.0.2.1', 'query[A] failed.example']
        def resolve(name, reverse=False):
            return name, [], not reverse
        with patch.object(suggest, 'journal', side_effect=logs), \
             patch.object(suggest, 'resolve', side_effect=resolve), \
             patch.object(suggest.Path, 'read_text', return_value=''), \
             contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            suggest.main('vps-test', '')
        self.assertIn('1 DNS lookups failed', err.getvalue())
        self.assertIn('192.0.2.1', out.getvalue())
        self.assertIn('no PTR', out.getvalue())


if __name__ == '__main__':
    unittest.main()
