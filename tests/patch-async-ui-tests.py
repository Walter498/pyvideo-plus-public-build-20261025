from pathlib import Path
p=Path(__file__).resolve().parent/'webkit-beta3-ui.m';s=p.read_text()
a=s.index('        m.mediaTabs.selectedSegmentIndex=2;');b=s.index('        Check(self.remoteThumbValid',a)
s=s[:a]+'''        m.mediaTabs.selectedSegmentIndex=2; [m.mediaTabs sendActionsForControlEvents:UIControlEventValueChanged];
        Wait(100,^BOOL{return m.rows.count==1&&[m.rows[0][@"kind"] isEqual:@"image"];},^{
            Check(YES,@"collect image filter asynchronously resolves one image");
            m.mediaTabs.selectedSegmentIndex=1;[m.mediaTabs sendActionsForControlEvents:UIControlEventValueChanged];
            Wait(100,^BOOL{return m.rows.count==1&&[m.rows[0][@"kind"] isEqual:@"video"];},^{
                Check(YES,@"collect video filter asynchronously resolves one video");
                m.mediaTabs.selectedSegmentIndex=0;[m.mediaTabs sendActionsForControlEvents:UIControlEventValueChanged];
                Wait(100,^BOOL{return m.rows.count==2;},^{[self testSelectionAfterFilters];},@"all media filter restored");
            },@"video filter snapshot");
        },@"image filter snapshot");
    },@"collect all actual rows");
}
- (void)testSelectionAfterFilters {
        PVXManager *m=self.manager;
''' +s[b:]
a='        Capture(@"collection",^{ [self showDownloadMenu]; });\n    },@"collect all actual rows");\n}'
b='        Capture(@"collection",^{ [self showDownloadMenu]; });\n}'
assert a in s;s=s.replace(a,b,1)
p.write_text(s)
