#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Web 端 API 一致性检查：确保 index.html / room.html / admin.html 里调用的
VR.xxx 都存在于 public/js/common.js 的导出清单里。

为什么需要这个脚本
------------------
common.js 是个 IIFE，导出靠末尾手写的 `return { ... }` 维护。
删掉或改名一个函数时，其它页面里残留的调用**没有任何工具会报错** ——
而它们通常位于 load() 的渲染链里，一个 undefined 一抛错，
就会把后面所有区块的渲染一起带走。

真实事故：把内置背景从 CSS 主题换成 5 张图时，common.js 里的
bgIcon() / bgClass() 被换成了 bgStyle() / resolveBg()，但
admin.html 的 renderRooms() 还在调 VR.bgIcon() →
后台「全部用户」整块空白、找不到「设置头像」入口，
而「房间管理」看着又正常，非常难排查。

用法
----
    python check_vr_api.py            # 在 voice-room/ 目录下运行
退出码 0 = 全部一致；1 = 有残留调用。
"""
import io
import os
import re
import sys

BASE = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'public')
COMMON = os.path.join(BASE, 'js', 'common.js')
TARGETS = ['index.html', 'room.html', 'admin.html']
for _f in sorted(os.listdir(os.path.join(BASE, 'js'))):
    if _f.endswith('.js') and _f != 'common.js':
        TARGETS.append(os.path.join('js', _f))


def strip_comments(s):
    """去掉块注释与整行注释 —— 否则注释里提到的 VR.xxx 会造成误报。"""
    s = re.sub(r'/\*.*?\*/', '', s, flags=re.S)
    s = re.sub(r'<!--.*?-->', '', s, flags=re.S)
    s = re.sub(r'^[ \t]*//.*$', '', s, flags=re.M)
    return s


def main():
    src = io.open(COMMON, encoding='utf-8').read()
    m = re.search(r'return \{([^}]*)\};', src)
    if not m:
        print('!! 在 common.js 里找不到导出清单（return { ... };）')
        return 1
    exports = set(x.strip() for x in re.sub(r'\s+', ' ', m.group(1)).split(','))
    exports.discard('')
    print('common.js 导出 %d 个成员\n' % len(exports))

    bad = 0
    for rel in TARGETS:
        path = os.path.join(BASE, rel.replace('/', os.sep))
        if not os.path.exists(path):
            print('SKIP %-16s (文件不存在)' % rel)
            continue
        body = strip_comments(io.open(path, encoding='utf-8').read())
        used = set(re.findall(r'\bVR\.([A-Za-z_][A-Za-z0-9_]*)', body))
        miss = sorted(used - exports)
        if miss:
            print('FAIL %-16s 调用了不存在的成员: %s' % (rel, ', '.join(miss)))
            bad += 1
        else:
            print('OK   %-16s (%d 个成员调用)' % (rel, len(used)))

    print()
    if bad:
        print('结论：%d 个文件有残留调用，会导致该页面渲染中断 ❌' % bad)
        return 1
    print('结论：全部一致 ✅')
    return 0


if __name__ == '__main__':
    sys.exit(main())
