#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
回归验证：管理后台「删除用户」必须连账号记录一起清掉。

原 bug
------
`case 'clear-user'` 只做了 `delete store.users[uid]`，`store.accounts` 里的
`{ pass, userId }` 记录留在原地。而服务端 `ensureAccount()` 的语义是
「账号不存在就自动注册」，于是被删掉的用户用原账号+原密码还能重新登录，
账号直接「复活」—— 后台的「删除」形同虚设。

为什么必须读原始 store.json
---------------------------
accounts 残留**无法从任何 HTTP 接口观察到**：账号没了会自动重建，
所以「还能不能登录」根本判断不出区别（永远能登录）。只能读文件。

为什么用 Python 而不是 Node 调度
--------------------------------
这个环境里 node 无法 spawn 子进程（execFileSync 直接 EBUSY），
所以由本脚本用 subprocess 调 devtest/ws_make_user.js 完成 WS 操作，
store.json 的读取用 paramiko，HTTP 用 urllib。

用法：
    python verify_clear_user.py
"""
import json
import os
import subprocess
import sys
import time
import urllib.request

import paramiko

HOST, USER, PWD = '43.142.76.172', 'root', 'qq789789...'
HTTP_BASE = 'http://43.142.76.172:8125'
ADMIN_PWD = os.environ.get('ADMIN_PWD', 'admin888')
STORE = '/opt/voice-room/data/store.json'

HERE = os.path.dirname(os.path.abspath(__file__))
NODE = 'C:/Users/a/.workbuddy/binaries/node/versions/22.22.2-3/node.exe'
NODE_PATH = 'C:/Users/a/.workbuddy/binaries/node/workspace/node_modules'

_pass = 0
_fail = 0


def check(name, ok, detail=''):
    global _pass, _fail
    if ok:
        _pass += 1
        print('  ✅ %s%s' % (name, ('  → ' + str(detail)) if detail else ''))
    else:
        _fail += 1
        print('  ❌ %s%s' % (name, ('  → ' + str(detail)) if detail else ''))


def read_store():
    cli = paramiko.SSHClient()
    cli.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    cli.connect(HOST, 22, USER, PWD, timeout=25, allow_agent=False, look_for_keys=False)
    try:
        _, out, _ = cli.exec_command('cat ' + STORE, timeout=40)
        return json.loads(out.read().decode('utf-8'))
    finally:
        cli.close()


def snapshot(user_id, prefix='avtest'):
    """
    读 store.json 看状态。

    ⚠️ 必须先等一下：服务端 saveStore() 是 400ms 防抖（`if (saveTimer) return;`），
    操作返回成功 ≠ 已经落盘。不等的话会读到上一版快照，
    表现为「刚建的账号在 users 里查不到」这种假失败。
    """
    time.sleep(1.2)
    d = read_store()
    users = d.get('users', {}) or {}
    accs = d.get('accounts', {}) or {}
    return {
        'inUsers': user_id in users,
        'inAccounts': any((a or {}).get('userId') == user_id for a in accs.values()),
        'leftovers': sorted(k for k in accs if k.startswith(prefix)),
        'userCount': len(users),
        'accountCount': len(accs),
    }


def admin_api(action, body):
    req = urllib.request.Request(
        HTTP_BASE + '/api/admin/' + action,
        data=json.dumps(dict(body, password=ADMIN_PWD)).encode('utf-8'),
        headers={'Content-Type': 'application/json'})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read().decode('utf-8'))


def make_user(username):
    """调 node 辅助脚本走 WS 登录/注册，返回 {ok, userId, error}。"""
    env = dict(os.environ, NODE_PATH=NODE_PATH)
    p = subprocess.run([NODE, 'ws_make_user.js', username, 'pw123456'],
                       cwd=HERE, env=env, capture_output=True, text=True, timeout=60)
    line = (p.stdout or '').strip().splitlines()
    if not line:
        return {'ok': False, 'error': 'node 无输出: ' + (p.stderr or '')[:120]}
    try:
        return json.loads(line[-1])
    except Exception:
        return {'ok': False, 'error': '无法解析 node 输出: ' + line[-1][:120]}


def main():
    print('--- 0. 清理上一轮测试残留的账号 ---')
    st = snapshot('__none__')
    print('  残留: %s' % json.dumps(st['leftovers']))
    if st['leftovers']:
        for n in st['leftovers']:
            admin_api('clear-user', {'userId': 'u_' + n})
        st = snapshot('__none__')
        check('残留已清空', st['leftovers'] == [], json.dumps(st['leftovers']))
    else:
        check('无需清理', True)

    print('\n--- 1. 建一个临时账号 ---')
    name = 'avtest' + format(int(time.time() * 1000) % 10 ** 9, 'x')
    res = make_user(name)
    check('临时账号已登录', res.get('ok') is True, res.get('error') or (name + ' / ' + str(res.get('userId'))))
    if not res.get('ok'):
        print('\n结果：%d 通过 / %d 失败' % (_pass, _fail))
        return 1
    uid = res['userId']

    s1 = snapshot(uid)
    check('users 里有它', s1['inUsers'] is True)
    check('accounts 里有它', s1['inAccounts'] is True)

    print('\n--- 2. 后台删除该用户 ---')
    try:
        deleted = admin_api('clear-user', {'userId': uid})
        check('删除接口返回 ok', deleted.get('ok') is True)
    except Exception as e:
        check('删除接口返回 ok', False, str(e))

    s2 = snapshot(uid)
    check('users 里已消失', s2['inUsers'] is False)
    check('accounts 里也已消失（原 bug 正是此处残留）', s2['inAccounts'] is False,
          '⚠️ 账号仍可被「复活」' if s2['inAccounts'] else '干净')

    print('\n--- 3. 确认没有遗留 ---')
    check('无 avtest 开头的残留账号', s2['leftovers'] == [], json.dumps(s2['leftovers']))
    print('  store 现状: users=%d, accounts=%d' % (s2['userCount'], s2['accountCount']))

    print('\n结果：%d 通过 / %d 失败' % (_pass, _fail))
    return 1 if _fail else 0


if __name__ == '__main__':
    sys.exit(main())
