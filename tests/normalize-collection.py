from pathlib import Path
p=Path('/var/minis/workspace/pyvideo-plus/src/Collection.m')
s=p.read_text()
for a,b in {'圖片':'图片','網頁':'网页','媒體':'媒体','來源':'来源','請':'请','掃描':'扫描','驗證':'验证','讀取':'读取','逾時':'超时','任務':'任务','導覽':'导航','改變':'改变','標籤頁':'标签页','關閉':'关闭','切換':'切换','無法':'无法','寫入':'写入','下載':'下载','檢查':'检查','儲存':'存储','權限':'权限','與':'与'}.items():s=s.replace(a,b)
p.write_text(s)
