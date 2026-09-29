#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""任务 11 二次回写：把「配置 17/17 = 完成」的口径改为「配置 17/17 + 功能 8/8」，
并补入控制面安全组缺失的血案警示。
幂等：以 deploy/d2/nodes-zones.txt 作为标记。用法：--check | --apply"""
import datetime
import shutil
import sys
from pathlib import Path

HERE = Path(__file__).parent
MARK = "deploy/d2/nodes-zones.txt"

R_SPEC_OLD = "| 实例规格 | `ecs.g9i.2xlarge` ×2 + `ecs.g9ae.2xlarge` ×2（均 **8C32G**） |"
R_SPEC_NEW = "| 实例规格 | **`ecs.g9ae.2xlarge` ×4**（均 **8C32G**；ESS 自主挑选，**不严格按 `instance_types` 顺序**） |"

R_DONE_OLD = """终验 **17/17 PASS，0 FAIL**；完整字段、ESS 删池坑、CLI 速查 → **`deploy/nodepool_ledger.md`**。
**仍未完成**：`kubectl get nodes -l site=ph-mnl`、`ulimit -n`=200000 落地核查、`/var/log/newapi-node-init.log` 复核需 **VPC 内**执行 → 等任务 46（堡垒机）。"""

R_DONE_NEW = """终验 **配置 17/17 + 功能 8/8 PASS**（功能层 2026-09-29 15:20 补齐闭合）；完整字段、ESS 删池坑、CLI 速查 → **`deploy/nodepool_ledger.md`**。
**功能层证据**：`deploy/d2/nodes-zones.txt`（4×`Ready`，6a:2 / 6b:2）· `deploy/d2/node-fd-limit.txt`（`ulimit -n` 软/硬限 262144）。

> ### ⚠️ 血案警示（2026-09-29，本卡真实经历，必读）
>
> 本卡曾报告「17/17 PASS」并判定完成，但**集群当时实际是 0 个 Worker** —— **配置项全绿 ≠ 功能可用**。
>
> **根因**：ACK 创建集群时**没有在「控制面 ENI 的安全组」放行 TCP 6443**。该安全组 `sg-5tsaatp5w68vyqszezja`
> （名 `alicloud-cs-auto-created-security-group-<集群ID>`）创建后入方向**只有一条 ICMP 规则**。
> 于是节点与 Pod 都无法直连 apiserver ENI（`10.0.22.183` / `10.0.43.190`）：
> - 4/4 节点 `attach_node.sh` 的 `ensure_kube_version` 失败（`FailGetKubeVersion`，cloud-init 卡满 606s 放弃）→ 节点从未注册；
> - 即便节点 join，Terway 走 ClusterIP（`172.21.0.1:443`）也连不上 API Server → 永远 `NotReady`。
> - **DNS 记录与 `kubernetes` EndpointSlice 从头到尾都是对的**，问题纯在网络层放行。
>
> **修复**：补一条 `TCP 6443 ← 10.0.0.0/16` 入方向规则 + 重跑 bootstrap → **4/4 `Ready`**，集群恢复可调度。
>
> **必须记住的三条**：
> 1. **任务 24（新加坡）建完集群第一件事 = 核对控制面安全组有没有 6443**，否则原样复现；
> 2. 节点可用性**必须用 `kubectl get nodes` 验证**（私网端点用云助手直连，不必等堡垒机），不能只看节点池配置项；
> 3. 排查口径：**`ping` 通 ≠ 端口通**（ICMP 恰在白名单里）；**`curl (7) timed out` ≠ DNS 问题**（`(6)` 才是解析失败）。
>
> 完整证据与 11 个坑（I–S）→ `deploy/nodepool_ledger.md` §7；工单文本 → `deploy/工单_ACK马尼拉控制面安全组缺失.md`。"""

R_LB_OLD = '"labels":[{"key":"track","value":"stable"}],'
R_LB_NEW = '"labels":[{"key":"site","value":"ph-mnl"},{"key":"track","value":"stable"}],'

R_T10_OLD = "**仍未完成**：`kubectl get ns` / Terway CRD 校验 / kubeconfig 拉取需 **VPC 内**执行 → 等任务 46（堡垒机）；8 EIP 出口复验与 Tair 连通性需节点池 → 等任务 11。"
R_T10_NEW = ("**已解除**：`kubectl get ns`（实测 6 个 namespace）、Terway CRD（`network.alibabacloud.com` 已注册）、kubeconfig 拉取"
             "均已可执行 —— **云助手可直连私网节点，不必等任务 46（堡垒机）**；集群 admin kubeconfig 取得方式见 "
             "`deploy/nodepool_ledger.md` §8.2。8 EIP 出口复验 / Tair 连通性待验证（节点池已就绪，任务 11 已闭合）。")

GUIDES = [
    HERE / "阿里云国际站菲律宾部署_详细操作指南-v2.0.md",
    HERE / "阿里云国际站菲律宾部署_详细操作指南.md",
    HERE / "阿里云国际站菲律宾部署_详细操作指南-ch.md",
]
PART = HERE / "wf2" / "part2a.md"


def patch(path, pairs, apply):
    if not path.exists():
        return "[跳过] 不存在 %s" % path.name
    raw = path.open(encoding="utf-8", newline="").read()
    nl = "\r\n" if "\r\n" in raw else "\n"
    new = raw
    changed, missed = [], []
    for old, rep, tag in pairs:
        o, r = old.replace("\n", nl), rep.replace("\n", nl)
        if o in new and r not in new:
            new = new.replace(o, r, 1)
            changed.append(tag)
        elif o not in new:
            missed.append(tag)
    if not changed:
        return "[已是最新/未匹配] %s：%s" % (path.name, "；".join(missed) or "无")
    if apply:
        ts = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
        shutil.copy2(path, path.with_suffix(path.suffix + ".bak-np11v2-" + ts))
        path.write_text(new, encoding="utf-8", newline="")
    return "[%s] %s：%s%s" % ("已写入" if apply else "待改", path.name, "；".join(changed),
                             ("  ⚠️未匹配：" + "；".join(missed)) if missed else "")


def main():
    apply = "--apply" in sys.argv
    guide_pairs = [
        (R_SPEC_OLD, R_SPEC_NEW, "实例规格行 -> g9ae×4"),
        (R_DONE_OLD, R_DONE_NEW, "验收口径 -> 配置17/17+功能8/8 并加血案警示"),
        (R_LB_OLD, R_LB_NEW, "建池 body labels 补 site"),
        (R_T10_OLD, R_T10_NEW, "任务10 尾部「等堡垒机」-> 已解除"),
    ]
    part_pairs = [(R_LB_OLD, R_LB_NEW, "part2a 建池 body labels 补 site")]

    for p in GUIDES:
        print(patch(p, guide_pairs, apply))
    print(patch(PART, part_pairs, apply))
    return 0


if __name__ == "__main__":
    sys.exit(main())
