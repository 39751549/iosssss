#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
读线上 store.json 的关键状态，供回归测试断言用。

为什么不直接调 API：`clear-user` 的 bug 恰恰是「users 删了、accounts 没删」，
而 accounts 残留无法从任何 HTTP 接口观察到（服务端 ensureAccount 是自动注册的，
账号没了也会重新建号，所以「能不能再登录」判断不出区别）。只能读原始文件。

用法：
    python store_probe.py user <userId>       # 该 userId 在 users / accounts 里的存在情况
    python store_probe.py accounts <prefix>   # 列出 accounts 里以 prefix 开头的账号名
    python store_probe.py count               # users / accounts 总数

输出：一行 JSON（便于 node 侧 JSON.parse）
"""
import json
import sys

import paramiko

HOST, USER, PWD = '43.142.76.172', 'root', 'qq789789...'
STORE = '/opt/voice-room/data/store.json'


def fetch():
    cli = paramiko.SSHClient()
    cli.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    cli.connect(HOST, 22, USER, PWD, timeout=25, allow_agent=False, look_for_keys=False)
    try:
        _, out, _ = cli.exec_command('cat ' + STORE, timeout=40)
        return json.loads(out.read().decode('utf-8'))
    finally:
        cli.close()


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    mode = sys.argv[1]
    arg = sys.argv[2] if len(sys.argv) > 2 else ''
    d = fetch()
    users = d.get('users', {}) or {}
    accs = d.get('accounts', {}) or {}

    if mode == 'user':
        print(json.dumps({
            'inUsers': arg in users,
            'inAccounts': any((a or {}).get('userId') == arg for a in accs.values()),
        }, ensure_ascii=False))
    elif mode == 'accounts':
        print(json.dumps(sorted(k for k in accs if k.startswith(arg)), ensure_ascii=False))
    elif mode == 'count':
        print(json.dumps({'users': len(users), 'accounts': len(accs)}, ensure_ascii=False))
    else:
        print(json.dumps({'error': 'unknown mode: ' + mode}))
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
