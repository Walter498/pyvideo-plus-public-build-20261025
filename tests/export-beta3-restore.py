from pathlib import Path
import subprocess
root=Path(__file__).resolve().parents[1]
p=root/'src/TaskSupport.m'
old=subprocess.check_output(['git','show','HEAD:src/TaskSupport.m'],cwd=root,text=True)
thumb=old[old.index('@interface PVXThumbnail'):].replace('PVXLocalFile(task)','PVXTaskLocalPath(task)')
with p.open('a') as f:f.write(thumb+'\n#endif\n')
