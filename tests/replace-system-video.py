from pathlib import Path
p=Path(__file__).resolve().parents[1]/'src/MediaPreview.m'
s=p.read_text()
s=s.replace('@interface PVXPreviewController : UIViewController <AVPlayerViewControllerDelegate, AVPictureInPictureControllerDelegate, UIScrollViewDelegate>','@interface PVXPreviewController : UIViewController <UIScrollViewDelegate>')
for prop in ['@property(nonatomic,strong) AVPlayerViewController *videoController;','@property(nonatomic,strong) AVPlayer *player;','@property(nonatomic,strong) AVPictureInPictureController *pip;','@property(nonatomic) BOOL audioActive;','@property(nonatomic,strong) AVPlayerLayer *playerLayer;','@property(nonatomic,strong) UIButton *playButton;','@property(nonatomic,strong) PVXPreviewController *pipKeeper;','@property(nonatomic,copy) NSString *previousCategory;','@property(nonatomic,copy) NSString *previousMode;','@property(nonatomic) AVAudioSessionCategoryOptions previousOptions;','@property(nonatomic) BOOL observingItem;','@property(nonatomic) BOOL observingPiP;','@property(nonatomic) BOOL autoPiPRequested;']:
 assert prop in s,prop
 s=s.replace(prop+'\n','',1)
s=s.replace('if ([self.row[@"kind"] isEqual:@"image"]) [self showImage]; else [self showVideo];','[self showImage];')
a=s.index('- (void)showVideo {');b=s.index('@end\n\nvoid PVXPreviewMedia',a)
s=s[:a]+'''- (void)closePreview { [self.imageTask cancel];[self.previewSession invalidateAndCancel];[self dismissViewControllerAnimated:YES completion:nil]; }
- (void)viewDidDisappear:(BOOL)animated { [super viewDidDisappear:animated];[self.imageTask cancel];[self.previewSession invalidateAndCancel]; }
- (void)dealloc { [_imageTask cancel];[_previewSession invalidateAndCancel]; }
'''+s[b:]
s=s.replace('@end\n\nvoid PVXPreviewMedia','@end\n\n#import "SystemVideoPreview.inc"\n\nvoid PVXPreviewMedia',1)
a='    UIViewController *presenter=PVXPresenter();if(!presenter)'
assert a in s
s=s.replace(a,'    if([row[@"kind"] isEqual:@"video"]){PVXOpenSystemVideo([row copy]);return;}\n'+a,1)
p.write_text(s)
print('Replaced custom layer/PiP/buttons with directly presented AVPlayerViewController')
