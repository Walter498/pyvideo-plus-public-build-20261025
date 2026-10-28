#!/usr/bin/env python3
"""Source wiring contracts, not UIKit/AVFoundation runtime tests.
Run: python3 tests/ui-list-regression.py
"""
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
u = (ROOT / 'src/DownloadsUI.m').read_text()
m = (ROOT / 'src/MediaMetadata.m').read_text()
c = (ROOT / 'src/Collection.m').read_text()
p = (ROOT / 'src/SystemVideoPreview.inc').read_text()

def check(name, condition):
    assert condition, name
    print('PASS source contract:', name)

check('list only, no grid class/delegates/layout/menu/setter',
      not re.search(r'UICollectionView|PVXGridCell|self\.grid|setGridMode|@"图标"|@"显示模式"', u))
check('legacy grid preference removed, table visible',
      'removeObjectForKey:@"com.crctdd.pyvideo.plus.gridMode"' in u and 'self.table.hidden=NO;' in u)
for capability in ['rangeSelect:', 'selectAll', 'sortMenu', 'filterChanged',
                   'searchBar', 'batchTransfer:', 'toggleTransfer:', 'rowMenu:',
                   'exportSelected', 'deleteSelected', 'PVXPreviewMedia']:
    check('preserved list capability ' + capability, capability in u)
check('HLS not returned before asset fallback', 'if(manifest)return' not in m and
      'else loadAsset();' in m and 'PVXMetadataTakeDelivery(&state,timeout)' in m)
check('poster is explicit association, not page scraping',
      'row[@"poster"]' in m and not re.search(r'querySelector|og:image|twitter:image', m))
check('poster failure falls back to AVAsset', 'else loadAsset();' in m)
check('collector canonicalization keeps exact page/frame/poster',
      'c[@"poster"]=PVXCollectionHTTP(row[@"poster"])' in c and
      'c[@"frame"]=frame.absoluteString' in c)
check('frame referer, per-target request cookie filtering, asset live cookie jar',
      'r[@"frame"]?:r[@"page"]' in m and
      'PVXMediaCookiesForURL(cookies,url)' in m and
      'opts[AVURLAssetHTTPCookiesKey]=cookies' in m and
      '[headers removeObjectForKey:@"Cookie"]' in m)
check('bounded poster/manifest/range and async frames; no whole-video download API',
      'posterRequest,4*1024*1024,0' in m and
      'manifest?2*1024*1024:128*1024,0' in m and
      'bytes=0-0' in m and 'generateCGImagesAsynchronouslyForTimes' in m and
      not re.search(r'downloadTask|dataWithContentsOfURL|copyCGImageAtTime', m))
check('worker decode, hard deadline, cancellation, bounded asset concurrency',
      'dispatch_get_global_queue(QOS_CLASS_UTILITY,0)' in m and
      '25*NSEC_PER_SEC' in m and 'cancelAllCGImageGeneration' in m and
      'cancelLoading' in m and 'PVXMetadataActive<PVXMetadataConcurrencyLimit' in m)
check('metadata context includes poster and document; partial values not cached',
      'PVXText(row[@"poster"],16384),PVXText(row[@"documentID"],512)' in m and
      'if([value[@"thumbnail"] isKindOfClass:UIImage.class]' in m)
check('cell rejects stale context, retries failure, preserves URL after async fill',
      '![weakMetadata.metadataIdentity isEqual:metadataIdentity]' in u and
      'metadataRetryAfter=NSDate.date.timeIntervalSince1970+15' in u and
      '[NSString stringWithFormat:@"%@\\n%@",size,PVXText(r[@"url"])]' in u and
      'if(collect&&!self.metadataRequested' in u)
check('preview reuses exact ready asset without claiming thumbnail success',
      'AVPlayerItemStatusReadyToPlay&&!self.metadataNotified&&self.sourceRow' in p and
      'postNotificationName:@"PVXPreviewAssetReady" object:asset' in p and
      '[PVXMetadataKey(source) isEqual:key]' in m and
      'asset=ready?:[AVURLAsset URLAssetWithURL:u options:opts]' in m and
      'if(!borrowedAsset)[asset cancelLoading]' in m and
      'attempt!=assetAttempt' in m)
with tempfile.TemporaryDirectory(prefix='pvx-ui-list-') as tmp:
    binary = str(Path(tmp) / 'state')
    subprocess.run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror',
                    str(ROOT / 'tests/ui-list-state.c'), '-o', binary], check=True)
    subprocess.run([binary], check=True)
print('PASS ui-list regression (source contracts + executed production C gate only; no device/decode claims)')
