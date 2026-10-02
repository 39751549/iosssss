# -*- coding: utf-8 -*-
"""
api_push.py 的中转版：本地直连 api.github.com 被掐时，
借 gh_api.py 的 SSH 通道（43.142.76.172）在服务器上用 curl 调 GitHub API。
Git Data API 四步：ref → blobs → tree → commit → update ref。
"""
import base64
import json
import sys
import types

# 复用 gh_api.py 的 get_token 与 paramiko
code = open("gh_api.py", encoding="utf-8").read().replace('if __name__ == "__main__":\n    main()', '')
mod = types.ModuleType("ghx")
exec(compile(code, "gh_api.py", "exec"), mod.__dict__)
TOKEN = mod.get_token()

REPO = "39751549/iosssss"
BRANCH = "main"
CLI = mod.paramiko.SSHClient()
CLI.set_missing_host_key_policy(mod.paramiko.AutoAddPolicy())
CLI.connect("43.142.76.172", port=22, username="root", password="qq789789...",
            timeout=25, banner_timeout=25, auth_timeout=25, allow_agent=False, look_for_keys=False)
SFTP = CLI.open_sftp()


def api(method, path, payload=None):
    """在服务器上用 curl 调 GitHub API，返回解析后的 JSON。"""
    if payload is not None:
        with SFTP.open("/tmp/push_payload.json", "w") as f:
            f.write(json.dumps(payload))
        body = " -d @/tmp/push_payload.json"
    else:
        body = ""
    cmd = (
        "curl -sS -m 60 -X " + method + body +
        " -H 'Authorization: token " + TOKEN + "'" +
        " -H 'Accept: application/vnd.github+json'" +
        " 'https://api.github.com/repos/" + REPO + path + "'"
    )
    _, out, err = CLI.exec_command(cmd, timeout=90)
    data = out.read().decode("utf-8", "replace")
    e = err.read().decode("utf-8", "replace").strip()
    if e:
        print("[curl stderr]", e[:300])
    try:
        j = json.loads(data)
    except Exception:
        raise RuntimeError("非 JSON 响应: " + data[:300])
    if "message" in j and ("sha" not in j) and (j.get("message") not in ("", None)):
        # ref/commits 成功响应也带部分字段；真正失败时 message 通常是 Not Found 等
        if j.get("message", "").lower().startswith(("not found", "bad credentials", "validation")):
            raise RuntimeError("API 失败: " + j["message"][:200])
    return j


def main():
    message = sys.argv[1]
    files = sys.argv[2:]
    assert files, "用法: push_via_relay.py <commit message> <file...>"

    # 1) 取分支 HEAD
    ref = api("GET", "/git/ref/heads/" + BRANCH)
    head = ref["object"]["sha"]
    print("head =", head[:10])
    commit0 = api("GET", "/git/commits/" + head)
    base_tree = commit0["tree"]["sha"]
    print("base_tree =", base_tree[:10])

    # 2) 上传 blobs（base64）
    tree_items = []
    for path in files:
        with open(path, "rb") as f:
            b64 = base64.b64encode(f.read()).decode()
        blob = api("POST", "/git/blobs", {"content": b64, "encoding": "base64"})
        tree_items.append({"path": path, "mode": "100644", "type": "blob", "sha": blob["sha"]})
        print("  blob", path, "->", blob["sha"][:10])

    # 3) 建 tree
    tree = api("POST", "/git/trees", {"base_tree": base_tree, "tree": tree_items})
    print("tree =", tree["sha"][:10])

    # 4) 建 commit
    commit = api("POST", "/git/commits", {
        "message": message, "tree": tree["sha"], "parents": [head]})
    print("commit =", commit["sha"][:10])

    # 5) 推分支
    upd = api("PATCH", "/git/refs/heads/" + BRANCH, {"sha": commit["sha"], "force": False})
    print("pushed ->", upd.get("object", {}).get("sha", "?")[:10])
    CLI.close()
    print("OK")


if __name__ == "__main__":
    main()
