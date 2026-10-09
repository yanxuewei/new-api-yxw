# 上游出口 EIP 台账（任务 6 / 任务 12 合并）

> 生成时间：20260928-181113 · 账号 `5108890064395960` · 来源：`deploy/tasks/task6/nat_eip.sh` + `deploy/tasks/task12/nat_eip_sg.sh`
> 坑 1：任一 EIP 新增/替换未同步供应商 → 偶发 403，失败率 ≈ 1/N。**上线前 8 个 EIP 必须全部取得供应商书面生效确认**。

| # | EIP 名称 | AllocationId | 公网 IP | Region | 绑定对象 | 状态 | 已进 RDS 白名单? | 已交供应商? | 生效确认时间 |
|---|---|---|---|---|---|---|---|---|---|
| 1 | eip-mnl-upstream-01 | eip-5tspbliwqwen4ksnh5c7c | 8.212.146.47 | ap-southeast-6 | nat-mnl-prod | InUse | ☐ | ☐ | — |
| 2 | eip-mnl-upstream-02 | eip-5ts7rdy2t4x6gxalrenz8 | 8.220.142.77 | ap-southeast-6 | nat-mnl-prod | InUse | ☐ | ☐ | — |
| 3 | eip-mnl-upstream-03 | eip-5tskfhgsdeck3a39j58lk | 8.220.184.250 | ap-southeast-6 | nat-mnl-prod | InUse | ☐ | ☐ | — |
| 4 | eip-mnl-upstream-04 | eip-5tsqau76kvzh9ur3npukp | 8.212.176.29 | ap-southeast-6 | nat-mnl-prod | InUse | ☐ | ☐ | — |
| 5 | eip-sg-upstream-01 | eip-t4nq406qw5les34b4oiwy | 47.84.184.246 | ap-southeast-1 | nat-sg-prod | InUse | ☐ | ☐ | — |
| 6 | eip-sg-upstream-02 | eip-t4nedki24li77cqqgrn43 | 47.84.29.162 | ap-southeast-1 | nat-sg-prod | InUse | ☐ | ☐ | — |
| 7 | eip-sg-upstream-03 | eip-t4nd71cckqg230xxk37vx | 47.84.83.76 | ap-southeast-1 | nat-sg-prod | InUse | ☐ | ☐ | — |
| 8 | eip-sg-upstream-04 | eip-t4nio4q6t42qw1vp1vdry | 47.84.126.214 | ap-southeast-1 | nat-sg-prod | InUse | ☐ | ☐ | — |

## 待办

- [ ] 8 个 EIP 提交给各上游供应商，取得书面生效确认（任务 56 的外部等待项）
- [ ] 马尼拉 4 EIP 加入马尼拉 RDS 公网白名单（§6.1；否则新加坡备站连不上主库 → M4 挂）
- [ ] 配置余额/到期双告警（坑 2：欠费导致 EIP 被回收后重新分配他人 → 白名单失效）
