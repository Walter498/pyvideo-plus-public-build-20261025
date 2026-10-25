from pathlib import Path
p=Path('/var/minis/workspace/pyvideo-plus/src/Collection.m');s=p.read_text()
old='for(NSString *k in @[@"key",@"documentID",@"width",@"height"]){id v=row[k];if([v isKindOfClass:NSString.class]||[v isKindOfClass:NSNumber.class])c[k]=v;}'
new='for(NSString *k in @[@"key",@"documentID",@"width",@"height",@"protocol",@"mime",@"headers",@"sourceKind"]){id v=row[k];if([v isKindOfClass:NSString.class]||[v isKindOfClass:NSNumber.class]||[v isKindOfClass:NSDictionary.class])c[k]=v;}'
assert old in s;s=s.replace(old,new,1);p.write_text(s)
# Make public task rows retain safe diagnostics rather than deleting the only useful error.
p=Path('/var/minis/workspace/pyvideo-plus/src/TaskSupport.m');s=p.read_text()
old='[row removeObjectForKey:@"error"];\n    if ([raw[@"state"] isEqual:@"failed"]) row[@"error"] = @"下载失败，请重试或检查服务";'
new='NSString *diagnostic=PVXSafeText(raw[@"error"],320);[row removeObjectForKey:@"error"];\n    if(diagnostic.length&&[diagnostic rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location==NSNotFound)row[@"error"]=diagnostic;\n    else if ([raw[@"state"] isEqual:@"failed"]) row[@"error"] = @"下载失败，请重试或检查服务";'
assert old in s;s=s.replace(old,new,1)
# Show diagnostics directly in the status text, but keep the compact status when none exists.
old='NSString *status = complete && !local ? @"本地原文件缺失 · 需重新下载" : names[state] ?: @"等待处理";'
new='NSString *status = complete && !local ? @"本地原文件缺失 · 需重新下载" : names[state] ?: @"等待处理";if([state isEqual:@"failed"]&&PVXSafeText(task[@"error"],240).length)status=[NSString stringWithFormat:@"下载失败：%@",PVXSafeText(task[@"error"],240)];'
assert old in s;s=s.replace(old,new,1);p.write_text(s)
