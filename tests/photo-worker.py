#!/usr/bin/env python3
"""Offline contract/model tests; does not execute Foundation or Photos."""
import datetime
import pathlib
import plistlib
import re
import subprocess
import unittest
from urllib.parse import urlsplit

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'worker/main.m'
TEXT = SOURCE.read_text()
SDK = '/root/.ios-sdk/iPhoneOS26.5.sdk'


def match(cookie, target, now=100):
    u = urlsplit(target)
    domain = cookie['Domain'].lower()
    sub = domain.startswith('.')
    domain = domain.lstrip('.')
    path = cookie['Path']
    target_path = u.path or '/'
    return ((u.hostname == domain or (sub and u.hostname.endswith('.' + domain)))
            and (not cookie.get('Secure') or u.scheme == 'https')
            and cookie.get('Expires', now + 1) > now
            and target_path.startswith(path)
            and (len(target_path) == len(path) or path.endswith('/')
                 or target_path[len(path):len(path)+1] == '/'))


def recover(state, credentials=True):
    if state == 'saving':
        return 'uncertain'
    if state in ('queued', 'downloading'):
        return 'queued' if credentials else 'failed'
    return state


class WorkerContract(unittest.TestCase):
    def test_01_sdk26_syntax(self):
        p = subprocess.run(['clang', '-target', 'arm64e-apple-ios15.0',
            '-isysroot', SDK, '-F' + SDK + '/System/Library/SubFrameworks',
            '-fobjc-arc', '-fblocks', '-Wall', '-Wextra', '-Werror',
            '-Wno-unused-parameter', '-fsyntax-only', str(SOURCE)],
            text=True, capture_output=True)
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)

    def test_02_real_binary_plist_fixtures(self):
        r = dict(id='12345678-1234-1234-1234-123456789ABC', kind='image',
                 url='https://example.test/a.gif', title='Animated',
                 page='https://example.test/', created=100.0,
                 headers={'Referer': 'https://example.test/'},
                 cookies=[dict(Name='sid', Value='secret', Domain='.example.test',
                               Path='/', Expires=datetime.datetime(2030, 1, 1))])
        b = plistlib.dumps(r, fmt=plistlib.FMT_BINARY)
        self.assertEqual(b[:8], b'bplist00')
        self.assertEqual(plistlib.loads(b), r)
        self.assertFalse(plistlib.dumps(r).startswith(b'bplist00'))
        self.assertLess(len(b), 2 * 1024 * 1024)
        self.assertGreater(len(plistlib.dumps({'title': 'x'*(2*1024*1024)}, fmt=plistlib.FMT_BINARY)), 2*1024*1024)
        self.assertIn('memcmp(b.bytes, "bplist00", 8)', TEXT)

    def test_03_cookie_domain_path_secure_expiry_model(self):
        c = dict(Domain='.example.test', Path='/a', Secure=True)
        for url, expected in [
            ('https://example.test/a', True),
            ('https://cdn.example.test/a/x', True),
            ('https://badexample.test/a', False),
            ('https://example.test/ab', False),
            ('http://example.test/a', False),
            ('https://elsewhere.test/a', False)]:
            self.assertEqual(match(c, url), expected, url)
        self.assertFalse(match(dict(c, Expires=99), 'https://example.test/a'))
        self.assertFalse(match(dict(c, Domain='example.test'), 'https://cdn.example.test/a'))
        redirect = TEXT.split('willPerformHTTPRedirection:', 1)[1].split('- (void)URLSession:', 1)[0]
        self.assertIn('requestFor:j target:target', redirect)
        self.assertIn('completionHandler(fresh)', redirect)
        self.assertIn('++j.redirects > 10', redirect)
        self.assertIn('source.scheme.lowercaseString isEqual:@"https"', redirect)

    def test_04_crash_recovery_model(self):
        for old, new in [('queued','queued'),('downloading','queued'),
                         ('saving','uncertain'),('saved','saved'),
                         ('failed','failed'),('uncertain','uncertain')]:
            self.assertEqual(recover(old), new)
        self.assertEqual(recover('downloading', False), 'failed')
        self.assertIn('@"Corrupt persisted state; manual reconciliation required"', TEXT)
        self.assertNotIn('UIImage', TEXT)
        self.assertNotIn('UIImageJPEGRepresentation', TEXT)

    def test_05_transaction_order_and_original_bytes(self):
        save = TEXT.split('- (void)save:', 1)[1].split('- (void)shutdown', 1)[0]
        self.assertLess(save.index('j.state[@"state"] = @"saving"'), save.index('performChanges:'))
        self.assertLess(save.index('if (![self persist:j])'), save.index('performChanges:'))
        self.assertIn('PHAssetResourceTypePhoto fileURL:file', save)
        self.assertIn('options.shouldMoveFile = NO', save)
        self.assertIn('if ([self persist:j]) [self cleanup:j]', save)
        self.assertIn('PHAccessLevelAddOnly', save)
        self.assertIn('self.active.count >= 2', TEXT)
        self.assertIn('j.ready && !j.task', TEXT)
        self.assertIn('self.saving = YES', save)

    def test_06_persistence_and_privacy_guards(self):
        for token in ['O_NOFOLLOW','O_EXCL','st.st_nlink != 1',
                      'fsync(fd)','fsync(dir)','renameat(', '0700','0600',
                      'flock(self.lockFD,LOCK_EX|LOCK_NB)',
                      'ephemeralSessionConfiguration', 'c.HTTPCookieStorage = nil',
                      'CGImageSourceGetCount', 'CGImageSourceGetStatus',
                      'PVXMaxBytes = 100ULL * 1024 * 1024',
                      'typedef NSString *(*PVXRootMapper)(NSString *)',
                      'dlsym(RTLD_DEFAULT,"_Z6jbrootP8NSString")']:
            self.assertIn(token, TEXT)
        persist = TEXT.split('- (BOOL)persist:', 1)[1].split('- (void)fail:', 1)[0]
        self.assertNotIn('request', persist)
        self.assertNotIn('cookies', persist)
        self.assertNotRegex(TEXT, r'NSLog\(|fprintf\([^;]*(?:absoluteString|cookie)')
        self.assertIn('PVXWrite(self.inboxFD,name,r)', TEXT)
        self.assertIn('PVXRemove(self.inboxFD,PVXFile(uuid))', TEXT)
        self.assertNotIn('"_jbroot"', TEXT)
        self.assertIn('if (!map) return nil', TEXT)


if __name__ == '__main__':
    unittest.main(verbosity=2)
