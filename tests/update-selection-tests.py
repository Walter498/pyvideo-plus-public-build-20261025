from pathlib import Path
p=Path('/var/minis/workspace/pyvideo-plus/tests/webkit-beta3-ui.m');s=p.read_text();s=s.replace('m.selectionButton.frame','m.moreButton.frame').replace('[m.selectionButton sendActionsForControlEvents:UIControlEventTouchUpInside];','m.selecting=YES;m.batchBar.hidden=NO;')
s=s.replace('Check(m.selecting&&!m.batchBar.hidden&&!m.allButton.hidden,', 'Check(m.selecting&&!m.batchBar.hidden,')
s=s.replace('anchor:m.selectionButton','anchor:m.moreButton')
p.write_text(s)
