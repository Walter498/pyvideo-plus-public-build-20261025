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


def recover(state, credentials=True, original=True):
    if state == 'saving':
        return 'uncertain'
    if state == 'ready':
        return 'ready' if original else 'failed'
    if state in ('queued', 'downloading'):
        return 'queued' if credentials else 'failed'
    return state


def auto_photos(preferences):
    return False


def eligible(state, automatic, manual=False):
    return False


def consume_manual(state, valid_original=True):
    return state, False


class DeleteModel:
    def __init__(self, state):
        self.state, self.active = state, state == 'downloading'
        self.inbox, self.media, self.tombstone = True, True, False

    def delete(self, cleanup=True):
        self.state, self.tombstone = 'deleting', True
        self.active = False
        if cleanup:
            self.inbox = self.media = False
            self.state = 'deleted'

    def callback(self):
        if self.active:
            self.state = 'failed'

    def import_again(self):
        return not self.tombstone


class WorkerContract(unittest.TestCase):
    def test_01_sdk16_and_26_arc_compile(self):
        for sdk in ('/root/theos/sdks/iPhoneOS16.5.sdk', SDK):
            with self.subTest(sdk=sdk):
                self.assertTrue(pathlib.Path(sdk).is_dir(), sdk)
                # Emit a real arm64e object as well as checking ARC diagnostics;
                # no iOS binary is linked, launched or installed.
                p = subprocess.run(['clang', '-target', 'arm64e-apple-ios15.0',
                    '-isysroot', sdk, '-F' + sdk + '/System/Library/SubFrameworks',
                    '-fobjc-arc', '-fblocks', '-Wall', '-Wextra', '-Werror',
                    '-Wno-unused-parameter', '-c', str(SOURCE), '-o', '/dev/null'],
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
        self.assertEqual(recover('ready', credentials=False), 'ready')
        self.assertEqual(recover('ready', original=False), 'failed')
        self.assertIn('@"任务记录损坏，请手动核对相册"', TEXT)
        self.assertNotIn('UIImage', TEXT)
        self.assertNotIn('UIImageJPEGRepresentation', TEXT)

    def test_05_no_photos_transaction_entrypoint(self):
        self.assertNotIn('performChanges:', TEXT)
        self.assertNotIn('authorizationStatusForAccessLevel:', TEXT)
        self.assertNotIn('requestAuthorization', TEXT)
        self.assertNotIn('PHPhotoLibrary', TEXT)
        save = TEXT.split('- (void)save:', 1)[1].split('- (void)shutdown', 1)[0]
        self.assertIn('(void)j;', save)
        self.assertIn('self.active.count >= 2', TEXT)

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

    def test_07_all_old_preferences_are_ignored(self):
        for value in (None, False, True, 0, 1, 'NO', 'YES', [], {}):
            prefs = {} if value is None else {'autoSavePhotos': value}
            roundtrip = plistlib.loads(plistlib.dumps(prefs, fmt=plistlib.FMT_BINARY))
            self.assertFalse(auto_photos(roundtrip))
        pref = TEXT.split('- (BOOL)autoSavePhotos {', 1)[1].split('- (BOOL)restoreOriginal:', 1)[0]
        self.assertIn('return NO;', pref)
        self.assertNotIn('plus-preferences.plist', TEXT)

    def test_08_legacy_manual_commands_are_dropped(self):
        for state in ('queued', 'downloading', 'ready', 'saved', 'saving', 'failed', 'uncertain', 'deleted'):
            self.assertEqual(consume_manual(state), (state, False))
            for automatic in (False, True):
                self.assertFalse(eligible(state, automatic, True))
        scan = TEXT.split('- (void)scanManualPhotos {', 1)[1].split('- (void)finishDeletion:', 1)[0]
        self.assertIn('PVXRemove(self.photosFD,name)', scan)
        self.assertIn('[j.state removeObjectForKey:@"manualPhotos"]', scan)
        self.assertNotIn('@YES', scan)

    def test_09_ready_queue_does_not_starve_downloads(self):
        # Records can accumulate on disk without tying downloaded bytes to RAM
        # or using the ready backlog as a limit on network scheduling.
        ready_count, active, queued = 10000, 0, 13
        while queued:
            started = min(2 - active, queued)
            self.assertGreater(started, 0)
            active += started
            self.assertLessEqual(active, 2)
            queued -= started
            ready_count += active
            active = 0
        self.assertEqual(ready_count, 10013)
        self.assertFalse(any(eligible('ready', False) for _ in range(ready_count)))
        self.assertFalse(eligible('ready', True))
        pump = TEXT.split('- (void)pump {', 1)[1].split('- (void)URLSession:', 1)[0]
        self.assertNotIn('buffered', pump)
        self.assertIn('self.active.count >= 2', pump)
        self.assertNotIn('[self save:', pump)
        self.assertNotIn('manualPhotos', pump)
        downloaded = TEXT.split('didFinishDownloadingToURL:', 1)[1].split('didCompleteWithError:', 1)[0]
        self.assertLess(downloaded.index('fsync(self.mediaFD)'), downloaded.index('j.state[@"state"] = @"ready"'))
        self.assertIn('j.state[@"url"] = @""; j.state[@"page"] = @""', downloaded)
        self.assertIn('retainOriginal:YES', downloaded)

    def test_10_export_metadata_survives_plist_roundtrip(self):
        for uti, extension in [('public.jpeg', 'jpg'), ('com.compuserve.gif', 'gif'),
                               ('public.heic', 'heic'), ('public.png', 'png')]:
            record = dict(state='ready', uti=uti, extension=extension, received=1234)
            saved = plistlib.loads(plistlib.dumps(record, fmt=plistlib.FMT_BINARY))
            self.assertEqual(saved, record)
        verify = TEXT.split('- (BOOL)verify:', 1)[1].split('didFinishDownloadingToURL:', 1)[0]
        self.assertIn('j.state[@"uti"] = j.uti', verify)
        self.assertIn('uti.preferredFilenameExtension', verify)

    def test_11_delete_active_pending_ready_and_late_callbacks(self):
        for state in ('queued', 'downloading', 'ready', 'failed', 'saved', 'uncertain'):
            m = DeleteModel(state)
            m.delete()
            m.callback()
            self.assertEqual(m.state, 'deleted')
            self.assertFalse(m.media or m.inbox or m.import_again())
        delete = TEXT.split('- (void)finishDeletion:', 1)[1].split('- (void)scanControls', 1)[0]
        self.assertLess(delete.index('removeObjectForKey:@(task.taskIdentifier)'), delete.index('[task cancel]'))
        self.assertIn('PVXRemove(self.inboxFD,PVXFile(uuid))', delete)
        self.assertIn('stringByAppendingString:@".original"', delete)
        for method in ('didFinishDownloadingToURL:', 'didCompleteWithError:'):
            body = TEXT.split(method, 1)[1].split('- (void)', 1)[0]
            self.assertIn('self.active[@(task.taskIdentifier)]', body)
            self.assertIn('if (!j', body)

    def test_12_delete_recovery_and_failed_cleanup_retry(self):
        m = DeleteModel('downloading')
        m.delete(cleanup=False)
        m.callback()
        self.assertEqual(m.state, 'deleting')
        m.delete()
        self.assertEqual(m.state, 'deleted')
        self.assertFalse(m.import_again())
        self.assertIn('[state isEqual:@"deleting"] || [state isEqual:@"deleted"]', TEXT)
        controls = TEXT.split('- (void)scanControls {', 1)[1].split('- (NSMutableURLRequest *)requestFor:', 1)[0]
        self.assertLess(controls.index('if (![self persist:j]) return'), controls.index('[self finishDeletion:j]'))
        self.assertIn('@"deleting",@"deleted"] containsObject:', TEXT)

    def test_13_control_binary_plist_contract(self):
        import uuid
        request_id, target = str(uuid.uuid4()), str(uuid.uuid4())
        c = dict(id=request_id, target=target, action='delete', created=100.0)
        blob = plistlib.dumps(c, fmt=plistlib.FMT_BINARY)
        self.assertEqual(plistlib.loads(blob), c)
        self.assertLess(len(blob), 2 * 1024 * 1024)
        controls = TEXT.split('- (void)scanControls {', 1)[1].split('- (NSMutableURLRequest *)requestFor:', 1)[0]
        for guard in ('PVXRead(self.controlFD,name)', 'PVXID(c[@"target"])',
                      'PVXNumber(c[@"created"])', '[c[@"id"] isEqual:requestID]',
                      'PVXKeys(c,@[@"id",@"target",@"action",@"created"])'):
            self.assertIn(guard, controls)
        self.assertIn('plus-image-control', TEXT)


if __name__ == '__main__':
    unittest.main(verbosity=2)
