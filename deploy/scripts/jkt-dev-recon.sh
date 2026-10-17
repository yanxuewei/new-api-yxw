#!/usr/bin/env bash
# jkt-dev-recon.sh —— 雅加达 dev 集群「节点空转 + Pod 上限 15」取证（只读，零凭据落盘）
#
# 背景：控制台显示 4 台 2C8G 节点，物理 CPU<5%、内存<19%，但调度器内存 Request 已 83%，
#       且每台 Allocatable Pod 固定 15。本脚本用 OpenAPI 把四件事一次问清楚：
#         ① Pod 上限 15 是不是机型 ENI 配额算出来的；
#         ② 4 台节点是谁加出来的（弹性伸缩 / 期望节点数 / 人工）；
#         ③ 仓库 JSON、台账、控制台三者是否漂移；
#         ④ 欠费、vSwitch IP 等会让扩容静默失败的前置条件。
#
# 用法：bash deploy/scripts/jkt-dev-recon.sh
#       只调用 Describe*，不产生任何费用，可随时执行。
set -uo pipefail

# aliyun CLI 由 ~/.zshrc 追加 PATH，非交互 shell 不 source ⇒ 显式补一次（同 lib/ack_remote.sh）
[ -d "$HOME/.workbuddy/binaries/aliyun-cli" ] && \
  case ":$PATH:" in *":$HOME/.workbuddy/binaries/aliyun-cli:"*) ;; *) export PATH="$HOME/.workbuddy/binaries/aliyun-cli:$PATH" ;; esac
command -v aliyun >/dev/null 2>&1 || { echo "[!] aliyun CLI 不在 PATH，终止"; exit 1; }

REGION="${REGION:-ap-southeast-5}"
CID="${CID:-cb0abf5bc06034f7bbdb991752f6f3e62}"          # ack-newapi-jkt-dev
POOL="${POOL:-np72446b422a6441c0bc96762a796aed26}"        # np-jkt-dev-x4c（2026-10-17 重建后的现池；旧池 npd3cc9d…6269b5 已 ErrorNodePoolNotFound）
ASG="${ASG:-asg-k1adh3qjtrpnr4gnzfs1}"                     # 现池伸缩组（旧 asg-k1a59qtckc246wh9r3ay 已无伸缩配置）
VPC="${VPC:-vpc-k1ano67avx98nr3n1bg5d}"
REPO_JSON="${REPO_JSON:-deploy/ops/jkt_nodepool_x4c.json}"   # 现池仓库副本（2026-10-17 与 OpenAPI 12/12 一致）；旧池副本 deploy/ack_jkt_dev_nodepool.json 已属死引用
LEDGER="${LEDGER:-deploy/jakarta_dev_ledger.md}"

A() { aliyun --region "$REGION" "$@" 2>&1; }

echo "########## 0. 账户余额（欠费会让扩容静默失败） ##########"
A bssopenapi QueryAccountBalance 2>/dev/null | python3 -c "
import sys,json
try: d=json.load(sys.stdin)['Data']
except Exception: print('  (接口不可用，改在费用中心目视)'); sys.exit()
print('  AvailableAmount = %s %s ｜ QuotaLimit = %s ｜ CreditAmount = %s' % (
    d.get('AvailableAmount'), d.get('Currency'), d.get('QuotaLimit'), d.get('CreditAmount')))
" 2>&1 | head -4
echo "  ↑ 余额为负/接近 0 时 ESS 返回 Account.Arrearage，扩容活动全部 Failed 且 K8s 侧无任何可见性"

echo
echo "########## 1. 节点池实况（伸缩模式的唯一真相） ##########"
A cs DescribeClusterNodePools --ClusterId "$CID" 2>/dev/null | python3 -c "
import sys,json
d=json.load(sys.stdin)
for p in d.get('nodepools',[]):
    info=p.get('nodepool_info',{}); s=p.get('scaling_group',{}); a=p.get('auto_scaling',{}); st=p.get('status',{})
    if '$POOL' not in (info.get('nodepool_id') or '') and info.get('name')!='np-jkt-dev-app': continue
    print('  池名/ID      : %s / %s' % (info.get('name'), info.get('nodepool_id')))
    print('  机型         : %s' % s.get('instance_types'))
    print('  付费/系统盘  : %s / %s %sG' % (s.get('instance_charge_type'), s.get('system_disk_category'), s.get('system_disk_size')))
    print('  auto_scaling : enable=%s min=%s max=%s type=%s' % (
        a.get('enable'), a.get('min_instances'), a.get('max_instances'), a.get('type')))
    print('  desired_size : %s        ← enable=false 时这才是节点数的决定量' % s.get('desired_size'))
    print('  节点数       : total=%s state=%s' % (st.get('total_nodes'), st.get('state')))
    print('  vswitch_ids  : %s' % s.get('vswitch_ids'))
    print('  management   : %s' % json.dumps(p.get('management',{}).get('auto_scaling') or {}, ensure_ascii=False))
"
echo
echo "  ▶ 判读：enable=false + desired_size=N ⇒ 固定 N 台常驻，min/max 完全不生效。"
echo "    若 desired_size > max_instances，配置本身自相矛盾（只有固定数量模式允许）。"

echo
echo "########## 2. 集群节点清单：机型 / AZ / 创建时间 / 谁加的 ##########"
IDS=$(A cs DescribeClusterNodes --ClusterId "$CID" --pageSize 100 2>/dev/null | python3 -c "
import sys,json
d=json.load(sys.stdin)
print(' '.join(n['instance_id'] for n in d.get('nodes',[])))
")
echo "  instance_ids: $IDS"
[ -z "$IDS" ] && { echo "[!] 拿不到节点，终止后续"; exit 1; }
IDJSON=$(printf '%s\n' $IDS | python3 -c "import sys,json; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))")
A ecs DescribeInstances --InstanceIds "$IDJSON" --PageSize 100 2>/dev/null | python3 -c "
import sys,json
d=json.load(sys.stdin)
rows=sorted(d['Instances']['Instance'], key=lambda x: x['CreationTime'])
print('  %-24s %-16s %-16s %-18s %-9s %s' % ('INSTANCE','TYPE','AZ','CREATED(UTC)','AS-标签','ENI/IP 占用'))
for i in rows:
    tags={t['TagKey'] for t in i['Tags']['Tag']}
    enis=i['NetworkInterfaces']['NetworkInterface']
    sec=sum(1 for n in enis if n['Type']=='Secondary'); trunk=sum(1 for n in enis if n['Type']=='Trunk')
    aux=sum(len(n['PrivateIpSets']['PrivateIpSet'])-1 for n in enis)
    print('  %-24s %-16s %-16s %-18s %-9s ENI=%d(sec%d/trunk%d) 辅助IP=%d' % (
        i['InstanceId'], i['InstanceType'], i['ZoneId'], i['CreationTime'],
        'Y' if 'k8s.io/cluster-autoscaler' in tags else 'N', len(enis), sec, trunk, aux))
print('  合计 =', d.get('TotalCount'), '台')
"
echo
echo "  ▶ 判读：无 k8s.io/cluster-autoscaler 标签 = 不是 K8s 自动伸缩加的，是期望节点数补的。"
echo "    辅助IP=0 且辅助网卡少 ⇒ Pod 数远低于机型上限，15 这个天花板根本没被触及。"

echo
echo "########## 3. Pod 上限核算：15 是怎么来的 ##########"
TYPES=$(A cs DescribeClusterNodePools --ClusterId "$CID" 2>/dev/null | python3 -c "
import sys,json
d=json.load(sys.stdin)
for p in d.get('nodepools',[]):
    if (p.get('nodepool_info') or {}).get('nodepool_id')=='$POOL':
        print(' '.join((p.get('scaling_group') or {}).get('instance_types') or []))
")
ARGS=""; i=1
for t in $TYPES; do ARGS="$ARGS --InstanceTypes.$i $t"; i=$((i+1)); done
echo "  机型候选: $TYPES"
A ecs DescribeInstanceTypes $ARGS 2>/dev/null | python3 -c "
import sys,json
d=json.load(sys.stdin)
print('  %-18s %-5s %-7s %-6s %-9s %-9s %s' % ('TYPE','vCPU','Mem','ENI','IP/ENI','EniTotal','(ENI-1)*IP+3'))
for t in sorted(d['InstanceTypes']['InstanceType'], key=lambda x:(x['CpuCoreCount'],x['InstanceTypeId'])):
    q=t['EniQuantity']; p=t['EniPrivateIpAddressQuantity']
    print('  %-18s %-5s %-7s %-6s %-9s %-9s %d' % (
        t['InstanceTypeId'], t['CpuCoreCount'], '%sGi'%t['MemorySize'], q, p,
        t.get('EniTotalQuantity','-'), (q-1)*p+3))
"
cat <<'EOF'
  公式（Terway 共享 ENI 模式，官方）：
      单节点最大 Pod 数 = (EniQuantity - 1) × EniPrivateIpAddressQuantity + hostNetwork Pod 数
    ecs.g9i.large / g9ae.large：(3-1)×6 + 3 = 15  ← 与控制台 Allocatable Pod=15 一致
    修改 kubelet maxPods 无效：该值只影响 hostNetwork Pod，ENI 部分由机型锁死。
    Terway 要求单节点 Pod 限额 >11 才能入集群，15 已贴近下限。
EOF

echo
echo "########## 3.1 提高 Pod 上限的候选机型：三区库存实测 ##########"
for t in ecs.g8ine.large ecs.g9i.xlarge ecs.g9ae.xlarge; do
  for az in "$REGION"a "$REGION"b "$REGION"c; do
    s=$(A ecs DescribeAvailableResource --DestinationResource InstanceType \
          --InstanceChargeType PostPaid --IoOptimized optimized --NetworkCategory vpc \
          --ZoneId "$az" --InstanceType "$t" 2>/dev/null | python3 -c "
import sys,json
try: d=json.load(sys.stdin)
except Exception: print('ERR'); sys.exit()
zs=d.get('AvailableZones',{}).get('AvailableZone',[])
vals=[s0.get('Status') for z in zs for r in z.get('AvailableResources',{}).get('AvailableResource',[])
      for s0 in r.get('SupportedResources',{}).get('SupportedResource',[]) if s0.get('Value')=='$t']
print(vals[0] if vals else 'NO_DATA')
")
    printf '  %-18s %-18s %s\n' "$t" "$az" "$s"
  done
done
cat <<'EOF'
  ▶ 判读：无货(NO_DATA)的机型不能进 BALANCE 多可用区机型列表，否则 5a/5c 会像
    本次欠费一样反复静默扩容失败。选机型必须先跑这一步。
EOF

echo
echo "########## 4. 伸缩组与伸缩活动（扩容为什么发生/为什么失败） ##########"
A ess DescribeScalingActivities --ScalingGroupId "$ASG" 2>/dev/null | python3 -c "
import sys,json,collections
d=json.load(sys.stdin)
a=d.get('ScalingActivities',{}).get('ScalingActivity',[])
c=collections.Counter(x.get('StatusCode') for x in a)
print('  活动统计:', dict(c), '（仅返回最近一页）')
for x in a[:12]:
    em=x.get('ErrorMessages') or {}
    msgs=[m.get('Code') for m in (em.get('ErrorMessages') or [])]
    print('  %s %-11s %-14s %s' % (x.get('StartTime'), x.get('StatusCode'),
          ','.join(msgs) or '-', (x.get('Cause') or '')[:70]))
"
cat <<'EOF'
  ▶ 判读：Cause 含 "Total Capacity is lesser than the Desired Capacity" = 期望节点数在补货，
    不是业务负载触发。Account.Arrearage = 账户欠费，会连续失败直到充值，且无 K8s 侧可见性。
EOF

echo
echo "########## 5. vSwitch 剩余 IP（Terway 下 Pod IP 的隐性天花板） ##########"
A vpc DescribeVSwitches --VpcId "$VPC" --PageSize 50 2>/dev/null | python3 -c "
import sys,json
d=json.load(sys.stdin)
for v in sorted(d['VSwitches']['VSwitch'], key=lambda x: x['CidrBlock']):
    n=v['VSwitchName']
    if 'app' not in n: continue
    print('  %-26s %-18s %-15s %-22s 可用IP=%s' % (v['VSwitchId'], v['ZoneId'], v['CidrBlock'], n, v['AvailableIpAddressCount']))
"
echo "  ▶ 判读：app 三段是 /20，余量数千 ⇒ 本集群 Pod 上限来自机型 ENI 配额，不是子网 IP 枯竭。"

echo
echo "########## 6. 三源漂移对比（OpenAPI vs 仓库 JSON vs 台账） ##########"
python3 -c "
import json,re,sys,subprocess
want={'auto_enable':None,'min':None,'max':None,'desired':None,'types':None}
try:
    out=subprocess.check_output(['aliyun','--region','$REGION','cs','DescribeClusterNodePools','--ClusterId','$CID'],text=True)
    for p in json.loads(out).get('nodepools',[]):
        if (p.get('nodepool_info') or {}).get('nodepool_id')=='$POOL':
            a=p.get('auto_scaling') or {}; s=p.get('scaling_group') or {}
            want['auto_enable']=a.get('enable'); want['min']=a.get('min_instances')
            want['max']=a.get('max_instances'); want['desired']=s.get('desired_size')
            want['types']=s.get('instance_types')
except Exception as e:
    print('  OpenAPI 读取失败:',e)
repo={}
try:
    r=json.load(open('$REPO_JSON')); repo=r
except Exception as e:
    print('  仓库 JSON 读取失败:',e)
def dig(o,keys,path=''):
    res={}
    if isinstance(o,dict):
        for k,v in o.items():
            if k in keys: res[k]=v
            else: res.update(dig(v,keys,path+'/'+k))
    elif isinstance(o,list):
        for v in o: res.update(dig(v,keys))
    return res
rf=dig(repo,{'min_instances','max_instances','instance_types','desired_size','enable'})
txt=''
try: txt=open('$LEDGER',encoding='utf-8').read()
except Exception: pass
led=[]
def led_note(kw):
    return '已标注 ' + kw if kw in txt else '未标注 ✗'
tot=None
try:
    o2=subprocess.check_output(['aliyun','--region','$REGION','cs','DescribeClusterNodes',
                                '--ClusterId','$CID','--pageSize','100'],text=True)
    tot=len(json.loads(o2).get('nodes',[]))
except Exception: pass
print('  %-14s %-26s %-22s %s' % ('','OpenAPI(现值)','仓库 JSON','台账'))
print('  %-14s %-26s %-22s %s' % ('auto_scaling', want['auto_enable'], rf.get('enable'), led_note('auto_scaling.enable=true')))
print('  %-14s %-26s %-22s %s' % ('min/max', '%s/%s'%(want['min'],want['max']), '%s/%s'%(rf.get('min_instances'),rf.get('max_instances')), led_note('min=max=2')))
print('  %-14s %-26s %-22s %s' % ('desired_size', want['desired'], rf.get('desired_size','(无该字段)'), led_note('desired_size=null')))
print('  %-14s %-26s %-22s %s' % ('节点数', tot, '(仓库 JSON 不表达)', led_note('min=max=2') if tot else '-'))
print('  %-14s %-26s %-22s %s' % ('instance_types', want['types'], rf.get('instance_types'), led_note('ecs.g9i.xlarge')))
print()
print('  ▶ 台账列出现「未标注 ✗」即为漂移未回填。以 OpenAPI 为准，回填仓库 JSON 与台账。')
if tot is not None and want.get('desired') is not None:
    d0=int(want['desired']); t0=int(tot)
    if d0==t0:
        print('  ▶ 一致性：期望 %d == 实际 %d ⇒ 节点数处于稳态。' % (d0,t0))
    else:
        print('  ⚠ 一致性：期望 %d ≠ 实际 %d ⇒ 伸缩组仍在朝期望值补货/回收。' % (d0,t0))
        print('     若实际 < 期望：余额或库存不足时这批复货会**静默失败**（见 §2.4 的 9 次 Account.Arrearage），')
        print('     而**一旦恢复就会自动弹回期望台数并开始计费**——集群侧没有任何告警。')
        print('     若实际 > 期望：ESS 正在移除节点，需确认移除的是哪台、是否 drain。')
        print('     ⇒ 跑第 4 节看最近伸缩活动的 StatusCode/StatusMessage 才能定性；期望值本身需回填为本人拍定的意图值。')
"

echo
echo "########## 7. kubectl 侧补充取证（需集群凭据，本脚本不代跑） ##########"
cat <<'EOF'
  dev 集群 endpoint_public_access=false，本机无法直连。二选一：
    A) 控制台 Cloud Shell 或跳板机，执行 deploy/pub_bodies/04-node-profile.sh、09-maxpods-recon.sh
    B) 复用 deploy/lib/ack_remote.sh（当前只有 mnl|sg 两个站点，需先加 jkt 分支，见文档 §4.3）
  必看的四项：
    kubectl describe node <n> | sed -n '/Allocated resources/,/^Events/p'   # requests vs limit vs 实际
    kubectl top nodes                                                        # 物理用量
    kubectl top pods -A --sort-by=memory                                     # 谁把内存 request 抬到 83%
    kubectl get pods -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,\
      NODE:.spec.nodeName,RQ_MEM:.spec.containers[*].resources.requests.memory
EOF

echo
echo "[i] 取证结束。本脚本全程只调用 Describe*，未做任何写操作。"
