#!/usr/bin/env python3
"""任务 11/23 成本复核：DescribePrice 实测节点池三机型的包月/包年/按量单价。

为什么需要它：指南成本表按 `ecs.g9i.2xlarge` 报价，而节点池 np-mnl-app 实际开出的是
`ecs.g9ae.2xlarge`（DescribeInstances 取证）⇒ 两者单价不同，月费必须重算。
只读 API，不创建资源。

用法：python3 deploy/task23_price_matrix.py [zone_id]
"""
import json
import subprocess
import sys

REGION = "ap-southeast-6"
ZONE = sys.argv[1] if len(sys.argv) > 1 else "ap-southeast-6a"

DISKS = {
    "SystemDisk.Category": "cloud_essd",
    "SystemDisk.Size": "100",
    "DataDisk.1.Category": "cloud_essd",
    "DataDisk.1.Size": "300",
    "DataDisk.1.PerformanceLevel": "PL1",
}

# (机型, 计价单位, 周期, 是否含盘, 备注)
CASES = [
    ("ecs.g9ae.2xlarge", "Month", 1, True, "实况机型（节点池实际开出）"),
    ("ecs.g9ae.2xlarge", "Year", 1, True, "实况机型"),
    ("ecs.g9ae.2xlarge", "Hour", 1, True, "实况机型"),
    ("ecs.g9ae.2xlarge", "Month", 1, False, "实况机型 · 仅实例（拆分磁盘价）"),
    ("ecs.g9i.2xlarge", "Month", 1, True, "指南原报价机型"),
    ("ecs.g9i.2xlarge", "Hour", 1, True, "指南原报价机型"),
    ("ecs.g8ine.2xlarge", "Month", 1, True, "节点池三机型之一"),
]


def describe_price(instance_type, unit, period, with_disk, note):
    params = {
        "RegionId": REGION,
        "ZoneId": ZONE,
        "IoOptimized": "optimized",
        "ResourceType": "instance",
        "InstanceType": instance_type,
        "PriceUnit": unit,
        "Period": str(period),
        "Amount": "1",
    }
    if with_disk:
        params.update(DISKS)
    args = ["aliyun", "ecs", "DescribePrice", "--region", REGION]
    for key, value in params.items():
        args += ["--" + key, str(value)]
    r = subprocess.run(args, capture_output=True, text=True)
    try:
        body = json.loads(r.stdout)
    except Exception:
        return {"error": (r.stdout or r.stderr or "").strip()[:220], "note": note}
    price = (body.get("PriceInfo") or {}).get("Price") or {}
    return {
        "trade": price.get("TradePrice"),
        "original": price.get("OriginalPrice"),
        "discount": price.get("DiscountPrice"),
        "currency": price.get("Currency"),
        "with_disk": with_disk,
        "note": note,
    }


def main():
    print("# region=%s zone=%s amount=1  含盘口径=sys100G(PL1)+data300G(PL1)" % (REGION, ZONE))
    for instance_type, unit, period, with_disk, note in CASES:
        row = describe_price(instance_type, unit, period, with_disk, note)
        print("%-20s %-6s %s" % (instance_type, unit, json.dumps(row, ensure_ascii=False)))


if __name__ == "__main__":
    main()
