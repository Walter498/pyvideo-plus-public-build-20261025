from pathlib import Path
p=Path('/var/minis/workspace/pyvideo-plus/src/MediaQuality.m');s=p.read_text()
old='static NSString *PVXQualityText(BOOL image,CGFloat width,CGFloat height){'
new='''static NSString *PVXCodecName(AVAssetTrack *track){if(!track)return @"编码未知";NSArray *formats=track.formatDescriptions;if(!formats.count)return @"编码未知";CMFormatDescriptionRef d=(__bridge CMFormatDescriptionRef)formats.firstObject;FourCharCode c=CMFormatDescriptionGetMediaSubType(d);switch(c){case kCMVideoCodecType_H264:return @"H.264";case kCMVideoCodecType_HEVC:return @"HEVC";case kCMVideoCodecType_VP9:return @"VP9";case kCMVideoCodecType_AV1:return @"AV1";default:return [NSString stringWithFormat:@"编码 %c%c%c%c",(int)((c>>24)&255),(int)((c>>16)&255),(int)((c>>8)&255),(int)(c&255)];}}
static NSString *PVXQualityText(BOOL image,CGFloat width,CGFloat height,NSString *codec){'''
assert old in s;s=s.replace(old,new,1)
s=s.replace('return [NSString stringWithFormat:@"%@ · %ld×%ld",name,(long)w,(long)h];}', 'return [NSString stringWithFormat:@"%@ · %ld×%ld%@",name,(long)w,(long)h,codec.length?[NSString stringWithFormat:@" · %@",codec]:@""];}',1)
s=s.replace('PVXQualityText(image,w,h):', 'PVXQualityText(image,w,h,nil):',1)
s=s.replace('CGFloat w=0,h=0;if(image){', 'CGFloat w=0,h=0;NSString *codec=nil;if(image){',1)
s=s.replace('if(track){CGSize size=CGSizeApplyAffineTransform(track.naturalSize,track.preferredTransform);w=fabs(size.width);h=fabs(size.height);}', 'if(track){CGSize size=CGSizeApplyAffineTransform(track.naturalSize,track.preferredTransform);w=fabs(size.width);h=fabs(size.height);codec=PVXCodecName(track);}',1)
s=s.replace('NSString *quality=PVXQualityText(image,w,h);', 'NSString *quality=PVXQualityText(image,w,h,codec);',1)
p.write_text(s)
