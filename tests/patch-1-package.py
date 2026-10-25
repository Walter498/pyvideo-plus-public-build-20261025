from pathlib import Path
p=Path(__file__).resolve().parents[1]/'package.py';s=p.read_text()
s=s.replace('Name: PyVideo Plus\\n','Name: Safari亚瑟下载\\n').replace('Version: 0.0.3+pvx.3~beta3\\n','Version: 1.0\\n').replace('PyVideo-0.0.3-pvx3-beta3-iphoneos-arm64e.deb','Safari-Arthur-Downloads-1.0-iphoneos-arm64e.deb')
a='Description: PyVideo 增强测试版：搜索栏长按入口、播放器当前视频下载、网页图片多选原格式下载。保留原视频插件引擎；iOS 15-17 arm64e/roothide，新增菜单需真机验证。'
b='Description: 让Safari获得某些类似亚瑟浏览器的功能，能够在画中画中直接下载影片，或者在网站中采集图片及影片以下载，长按搜索栏或点击画中画中的菜单开始使用'
assert a in s;s=s.replace(a,b)
a="control.write_text(raw)"
assert a in s;s=s.replace(a,"raw=re.sub(r'^Author: .*$', 'Author: 水甲嫩鸡', raw, flags=re.M);raw=re.sub(r'^Maintainer: .*$', 'Maintainer: 水甲嫩鸡', raw, flags=re.M);raw+='Depiction: file:///Library/Application%20Support/PyVideo/depiction/index.html\\n';control.write_text(raw)",1)
a="place(P/'resources/MediaCollector.js','Library/Application Support/PyVideo/MediaCollector.js')"
assert a in s;s=s.replace(a,a+"\nfor depiction in (P/'depiction').rglob('*'):\n if depiction.is_file():place(depiction,Path('Library/Application Support/PyVideo/depiction')/depiction.relative_to(P/'depiction'))\n",1)
p.write_text(s)
