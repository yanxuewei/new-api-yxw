#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
aliyun_rpc.py — 通用阿里云 RPC 风格 OpenAPI 调用器（SigV1 / HMAC-SHA1）

为什么需要它：aliyun CLI 3.5.1 对「object 类型参数」（如 ALB 的 HealthCheckConfig）
既不接受 JSON 串（服务端回 `Flat format is required`），也不接受点号子参数
（CLI 本地回 `not a valid parameter or flag`）⇒ 嵌套对象参数无法通过 CLI 传递。
本工具直接按 RPC 规范签名，参数以**扁平明文**提交，任何嵌套结构都能表达。

用法：
  aliyun_rpc.py <product> <Action> [--region ap-southeast-6] [--endpoint host]
                [--version 2020-06-16] [--method POST] [--dry] k=v k=v ...

示例：
  aliyun_rpc.py alb ListServerGroups --region ap-southeast-6 --version 2020-06-16
  aliyun_rpc.py alb CreateServerGroup --region ap-southeast-6 \
      ServerGroupName=demo ServerGroupType=Ip Protocol=HTTP VpcId=vpc-xxx \
      HealthCheckConfig.HealthCheckEnabled=true \
      HealthCheckConfig.HealthCheckPath=/api/status \
      DefaultActions.1.Type=ForwardGroup                     # 数组/嵌套一律用点号

凭证：读 ~/.aliyun/config.json（current profile，AK 模式）；
     可用 ALIBABA_CLOUD_ACCESS_KEY_ID/SECRET 环境变量覆盖。

⚠ 密钥只从本地配置读取，不落日志、不进 ps（参数经 stdin/argv 明文，注意 shell history）。
"""
import base64
import hashlib
import hmac
import json
import os
import sys
import time
import urllib.parse
import urllib.request
import uuid

DEFAULT_VERSION = {
    "alb": "2020-06-16",
    "ecs": "2014-05-26",
    "rds": "2014-05-26",
    "vpc": "2016-04-28",
    "cs": "2015-12-15",
    "sls": "2020-09-30",
}


def _creds():
    ak = os.environ.get("ALIBABA_CLOUD_ACCESS_KEY_ID") or os.environ.get("ALICLOUD_ACCESS_KEY_ID")
    sk = os.environ.get("ALIBABA_CLOUD_ACCESS_KEY_SECRET") or os.environ.get("ALICLOUD_ACCESS_KEY_SECRET")
    if ak and sk:
        return ak, sk
    cfg_path = os.path.expanduser("~/.aliyun/config.json")
    with open(cfg_path, encoding="utf-8") as f:
        cfg = json.load(f)
    cur = cfg.get("current") or "default"
    for p in cfg.get("profiles", []):
        if p.get("name") == cur:
            return p["access_key_id"], p["access_key_secret"]
    raise SystemExit("no profile found in ~/.aliyun/config.json")


def _enc(s):
    return urllib.parse.quote(str(s), safe="~")


def _sign(params, secret):
    canon = "&".join("%s=%s" % (_enc(k), _enc(params[k])) for k in sorted(params))
    sts = "POST&%2F&" + _enc(canon)
    return base64.b64encode(
        hmac.new((secret + "&").encode("utf-8"), sts.encode("utf-8"), hashlib.sha1).digest()
    ).decode()


def call(product, action, params, region="ap-southeast-6", endpoint=None,
         version=None, print_request=False, timestamp=None):
    ak, sk = _creds()
    version = version or DEFAULT_VERSION.get(product)
    if not version:
        raise SystemExit("need --version for product %s" % product)
    # 国际站域名：*.aliyuncs.com 全球同名（endpoint 可显式覆盖）
    host = endpoint or "%s.%s.aliyuncs.com" % (product, region)
    ts = timestamp or time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    p = dict(params)
    p.update({
        "Action": action,
        "Version": version,
        "Format": "JSON",
        "AccessKeyId": ak,
        "SignatureMethod": "HMAC-SHA1",
        "SignatureVersion": "1.0",
        "SignatureNonce": str(uuid.uuid4()),
        "Timestamp": ts,
        "RegionId": p.get("RegionId", region),
    })
    p["Signature"] = _sign(p, sk)
    if print_request:
        safe = {k: v for k, v in p.items() if k not in ("Signature", "AccessKeyId")}
        print("[req] POST https://%s/  params=%s" % (host, json.dumps(safe, ensure_ascii=False, sort_keys=True)))
    body = urllib.parse.urlencode(p, quote_via=urllib.parse.quote).encode()
    req = urllib.request.Request("https://%s/" % host, data=body, method="POST")
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))  # 绕开沙箱代理，直连
    try:
        with opener.open(req, timeout=30) as r:
            return json.loads(r.read().decode("utf-8", "replace"))
    except urllib.error.HTTPError as e:
        raw = e.read().decode("utf-8", "replace")
        try:
            return json.loads(raw)
        except Exception:
            return {"_http_status": e.code, "_raw": raw}


def main(argv):
    if len(argv) < 3:
        raise SystemExit(__doc__)
    product, action = argv[1], argv[2]
    region = "ap-southeast-6"
    endpoint = None
    version = None
    dry = False
    kv = []
    i = 3
    while i < len(argv):
        a = argv[i]
        if a == "--region":
            region = argv[i + 1]; i += 2
        elif a == "--endpoint":
            endpoint = argv[i + 1]; i += 2
        elif a == "--version":
            version = argv[i + 1]; i += 2
        elif a == "--dry":
            dry = True; i += 1
        elif a in ("--method", "--profile"):
            i += 2
        elif "=" in a:
            k, v = a.split("=", 1); kv.append((k, v)); i += 1
        else:
            i += 1
    res = call(product, action, dict(kv), region=region, endpoint=endpoint,
               version=version, print_request=dry)
    if dry and res is None:
        return 0
    print(json.dumps(res, ensure_ascii=False, indent=2))
    return 0 if not (isinstance(res, dict) and (res.get("Code") or res.get("error_code"))) else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
