from pathlib import Path
import json,shutil
p=Path(__file__).resolve().parents[1]/'depiction';p.mkdir(exist_ok=True)
names=['photo_0DAFEDC3.jpeg','photo_8DCB1BB7.png','photo_FE599E0D.png','photo_09F99D46.png','photo_994F0566.png']
files=[]
for i,name in enumerate(names,1):
 dest=p/f'screenshot-{i}{Path(name).suffix}';shutil.copyfile('/var/minis/attachments/uploads/'+name,dest);files.append(dest.name)
text='让Safari获得某些类似亚瑟浏览器的功能，能够在画中画中直接下载影片，或者在网站中采集图片及影片以下载，长按搜索栏或点击画中画中的菜单开始使用'
html='''<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Safari亚瑟下载 1.0</title><style>:root{color-scheme:dark}*{box-sizing:border-box}body{margin:0;background:#111;color:#eee;font:16px -apple-system,BlinkMacSystemFont,sans-serif}main{max-width:760px;margin:auto;padding:28px 20px}h1{font-size:28px;margin-bottom:8px}.meta{color:#aaa;font-size:14px}p{line-height:1.8}.screens{display:flex;overflow-x:auto;gap:14px;padding:10px 0 24px}.screens img{height:520px;width:auto;border-radius:12px;border:1px solid #333}h2{font-size:20px}footer{font-size:13px;color:#999;line-height:1.7}</style><main><h1>Safari亚瑟下载</h1><div class="meta">版本 1.0 · 作者：水甲嫩鸡</div><h2>介绍</h2><p>'''+text+'</p><h2>功能截图</h2><div class="screens">'+''.join(f'<a href="{f}"><img loading="lazy" src="{f}" alt="Safari亚瑟下载截图 {i}"></a>' for i,f in enumerate(files,1))+'''</div><h2>开始使用</h2><p>在 Safari 长按搜索栏，或打开播放器菜单，选择下载入口。采集页支持视频、图片分别查看，下载完成后通过系统分享菜单导出。</p><footer>保留原包标识 com.crctdd.pyvideo 以兼容升级。此为插件内置离线详情页，未自动发布到外部软件源。</footer></main></html>'''
(p/'index.html').write_text(html)
(p/'info.json').write_text(json.dumps({'name':'Safari亚瑟下载','version':'1.0','author':'水甲嫩鸡','description':text,'screenshots':files},ensure_ascii=False,indent=2))
