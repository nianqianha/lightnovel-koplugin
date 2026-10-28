#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""在电脑上远程触发 Kindle 截图，取回 PNG。

依赖：设备端已安装 screenshottool.koplugin（KOReader 菜单 Tools → 截图工具），
且 FileBrowser+ 正在运行。截图桥协议见 screenshottool.koplugin/SPEC-截图工具.md：
往 /mnt/us/koreader/screenbridge/{requests,results} 投递 <id>.request / <id>.ready，
轮询 results/<id>.result，按其中给出的 PNG 路径下载。

用法：
    python kindle_screenshot.py --ip 192.168.43.195            # 设备在局域网
    python kindle_screenshot.py --ip 127.0.0.1 --port 18080    # 走 SSH 隧道
    python kindle_screenshot.py --ip 127.0.0.1 --port 18080 --out shot.png
"""
import argparse
import random
import re
import string
import sys
import time
import urllib.error
import urllib.request


def http(base, path, method="GET", token=None, body=None, timeout=60):
    req = urllib.request.Request(base + path, data=body, method=method)
    if token:
        req.add_header("X-Auth", token)
    if body is not None:
        req.add_header("Content-Type", "application/octet-stream")
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.status, resp.read()


def login(base):
    status, body = http(base + "/api/login", timeout=15)
    text = body.decode("utf-8", "replace").strip()
    if status != 200 or not text:
        raise SystemExit("登录失败：HTTP %s" % status)
    return text.strip('"')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ip", required=True)
    ap.add_argument("--port", type=int, default=80)
    ap.add_argument("--out", default="kindle_screenshot.png")
    ap.add_argument("--wait", type=int, default=30,
                    help="等待设备截图完成的秒数（默认 30）")
    args = ap.parse_args()

    base = "http://%s:%d" % (args.ip, args.port)
    token = login(base)
    print("connected %s" % base)

    rid = "".join(random.choice(string.ascii_letters + string.digits + "_-")
                  for _ in range(24))
    bridge = "/mnt/us/koreader/screenbridge"

    # request 与 ready 的内容格式是硬校验：首行必须等于 id / "ready"
    for name, payload in ((rid + ".request", (rid + "\n").encode()),
                          (rid + ".ready", b"ready\n")):
        status, _ = http("/api/resources" + bridge + "/requests/" + name
                         + "?override=true", method="POST", token=token,
                         body=payload, timeout=60)
        if status != 200:
            raise SystemExit("上传 %s 失败：HTTP %s" % (name, status))

    result_path = bridge + "/results/" + rid + ".result"
    deadline = time.time() + max(5, args.wait)
    result_text = ""
    while time.time() < deadline:
        time.sleep(1)
        try:
            status, body = http("/api/raw" + result_path, token=token,
                                timeout=20)
        except urllib.error.HTTPError:
            continue
        if status == 200:
            result_text = body.decode("utf-8", "replace")
            if "OK" in result_text[:20]:
                break

    match = re.search(r"/mnt/us/\S+\.png", result_text)
    if not match:
        raise SystemExit("设备未返回截图（等待 %ds）。result=%r"
                         % (args.wait, result_text[:120]))

    _, png = http("/api/raw" + match.group(0), token=token, timeout=120)
    if not png.startswith(b"\x89PNG"):
        raise SystemExit("下载的内容不是 PNG（%d 字节）" % len(png))
    with open(args.out, "wb") as f:
        f.write(png)
    print("saved %s (%d bytes) from %s" % (args.out, len(png),
                                           match.group(0)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
