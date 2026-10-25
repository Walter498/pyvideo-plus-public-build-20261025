from pathlib import Path
import subprocess
p=Path('/var/minis/workspace/pyvideo-plus/storage/Storage.m');current=p.read_text();old=subprocess.check_output(['git','show','5c69ef8:storage/Storage.m'],cwd=p.parent.parent,text=True);start=old.index('static void PVXFinishRecovery');second=old.index('static void PVXFinishRecovery',start+10);block=old[start:second]
needle='static void PVXPersistRecoveryResult'
assert needle in current and 'static BOOL PVXLoadFFmpegKit' not in current
p.write_text(current.replace(needle,block+'\n'+needle,1))
