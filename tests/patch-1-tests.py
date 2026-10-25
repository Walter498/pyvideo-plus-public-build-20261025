from pathlib import Path
p=Path(__file__).resolve().parent/'webkit-beta3-ui.m';s=p.read_text()
a='Check(receipt!=nil&&!error,@"production frame revalidation and submit succeeded");'
assert a in s;s=s.replace(a,a+'PVXRememberSource(images[0],receipt);',1)
a='Check(self.remoteThumbValid,@"remote collected image URL generated actual thumbnail with origin cookies");'
assert a in s;s=s.replace(a,a+'Check(PVXLinkedTask(PVXCollectedMedia(@"image")[0],PVXReadVideoTasks())!=nil,@"collection progress persists source-to-task UUID association");',1)
a='Record(@"webkit-beta3-result.txt",[@"PASS real WKWebView/native collector, production binary inbox/TaskRead, actual manager filters/checks/menu timer, UIKit activity and real staged PNG; REAL production worker downloaded localhost fixture\\n" stringByAppendingString:[Checks componentsJoinedByString:@"\\n"]]);'
b='''[self.manager dismissViewControllerAnimated:NO completion:^{
            PVXPreviewMedia(self.ready);
            Wait(100,^BOOL{return [NSStringFromClass(self.manager.presentedViewController.class) isEqual:@"PVXPreviewController"];},^{
                UIViewController *viewer=self.manager.presentedViewController;
                Wait(150,^BOOL{return [(UIImageView*)PVXGet(viewer,@"imageView") image]!=nil;},^{
                    Check([(UIScrollView*)PVXGet(viewer,@"scroll") maximumZoomScale]>1,@"actual local image viewer supports zoom");
                    PVXFetchMediaQuality(self.ready,^(NSString *quality){Check([quality isEqual:@"96×96"],@"actual ImageIO image resolution read");Record(@"webkit-beta3-result.txt",[@"PASS real collection, actual download, thumbnails, dates, range selection, live linked progress, real image viewer/zoom, image dimensions, stable menu and system share\\n" stringByAppendingString:[Checks componentsJoinedByString:@"\\n"]]);});
                },@"local image viewer decodes actual downloaded file");
            },@"actual image preview controller presentation");
        }];'''
assert a in s;s=s.replace(a,b,1)
p.write_text(s)
