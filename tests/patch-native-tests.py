from pathlib import Path
p=Path(__file__).resolve().parent/'webkit-beta3-ui.m';s=p.read_text()
s=s.replace('#define PVX_TEST 1','#define PVX_TEST 1\n#import <AVKit/AVKit.h>\n#import <CoreVideo/CoreVideo.h>',1)
a='Record(@"webkit-beta3-result.txt",[@"PASS real collection, actual download, thumbnails, dates, range selection, live linked progress, real image viewer/zoom, image dimensions, stable menu and system share\\n" stringByAppendingString:[Checks componentsJoinedByString:@"\\n"]]);'
assert a in s;s=s.replace(a,'[self verifySystemPlayerAfterImage];',1)
a='}\n@end\nint main(int argc,char **argv)'
assert a in s;s=s.replace(a,'}\n#import "system-player-test.inc"\n@end\nint main(int argc,char **argv)',1)
p.write_text(s)
p=Path(__file__).resolve().parent/'webkit-beta3-simulator.py';s=p.read_text()
s=s.replace("for name in ('collection', 'menu', 'activity'):","for name in ('collection', 'menu', 'activity', 'native-player'):",1)
s=s.replace("captured != {'collection', 'menu', 'activity'}","captured != {'collection', 'menu', 'activity', 'native-player'}",1)
s=s.replace("'-framework', 'QuartzCore'])","'-framework', 'QuartzCore', '-framework', 'CoreVideo'])",1)
p.write_text(s)
