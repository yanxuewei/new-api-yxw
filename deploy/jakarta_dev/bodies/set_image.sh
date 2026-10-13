#!/bin/bash
# bodies/set_image.sh —— 把 TARGET 负载的镜像从 newapi-prod/* 换到 newapi-dev/*（免密已按 §13.8 验证可用）
# 闸门设计成"白名单"而不是"黑名单"：只接受 dev 命名空间 + 公网入口域名 + dev EE 里真实存在过的 tag 形状。
#   理由：这次改的动机就是"dev 不该引用生产命名空间"，用黑名单（挡 prod）会漏掉 test/pre 与 -vpc 两类误配。
NS=newapi-dev
T="${TARGET:-}"
IMG="${NEWIMG:-}"
ALLOW_HOST=acr-newapi-mnl-registry.ap-southeast-6.cr.aliyuncs.com
echo "=== G0 目标与镜像闸门（任一不过 ⇒ 一个字都不写）"
[ -n "$T" ] || { echo "  [XX] 未传 TARGET"; exit 2; }
[ -n "$IMG" ] || { echo "  [XX] 未传 NEWIMG"; exit 2; }
if [ "$T" = "new-api-dev" ]; then echo "  [XX] TARGET 不能是 new-api-dev（本卡产物，镜像由清单管）"; exit 2; fi
case "$IMG" in
  "$ALLOW_HOST"/newapi-dev/newapi-master:[0-9]*-[0-9a-f]*) : ;;
  *) echo "  [XX] NEWIMG 不在白名单：要求 $ALLOW_HOST/newapi-dev/newapi-master:<yyyymmdd>-<sha>";
     echo "       明确拒绝三类：① newapi-prod/*（本次要消除的口径）② 带 -vpc 的域名（跨区不可路由，§13.4 坑 15）③ test/pre 命名空间"; exit 2 ;;
esac
[ "$IMG" = "${IMG#*vpc}" ] || { echo "  [XX] 域名含 vpc ⇒ 拒绝"; exit 2; }
kubectl -n $NS get deploy "$T" -o jsonpath='  before: sa={.spec.template.spec.serviceAccountName}{"\n"}' 2>&1 \
  || { echo "  [XX] 取不到 deploy/$T"; exit 2; }
echo "  --- 当前各容器镜像"
kubectl -n $NS get deploy "$T" -o jsonpath='{range .spec.template.spec.containers[*]}    {.name}{"  "}{.image}{"\n"}{end}' 2>&1

echo "=== G1 换镜像（只对域名命中的容器下 set image，其余容器一律不碰）"
RC=0
kubectl -n $NS get deploy "$T" -o jsonpath='{range .spec.template.spec.containers[*]}{.name}{"|"}{.image}{"\n"}{end}' 2>/dev/null \
  | while IFS='|' read -r cn ci; do
      [ -n "$cn" ] || continue
      case "$ci" in
        "$ALLOW_HOST"/*)
          OUT=$(kubectl -n $NS set image deploy/"$T" "$cn=$IMG" 2>&1)
          printf '  [%s] %s\n' "$cn" "$OUT" ;;
        *) printf '  [%s] 域名不匹配（%s）⇒ 跳过不碰\n' "$cn" "$ci" ;;
      esac
    done

echo "=== G2 回读 spec（生效判据只认这里）"
kubectl -n $NS get deploy "$T" -o jsonpath='  after: image={.spec.template.spec.containers[0].image}{"\n"}' 2>&1
kubectl -n $NS get deploy "$T" -o jsonpath='  after: sa={.spec.template.spec.serviceAccountName}  （§13.8 的免密改动不应被本次影响）{"\n"}' 2>&1

echo "=== G3 等新 Pod 起来（180s < 云助手 900s）"
kubectl -n $NS rollout status deploy/"$T" --timeout=180s 2>&1 | sed 's/^/    /'
RC=$?
printf '  rollout_rc=%s\n' "$RC"

echo "=== G4 实测结论：跑起来的到底是哪个 digest（与 §13.1 的 829a4277… 对得上才算等价替换）"
kubectl -n $NS get deploy "$T" -o jsonpath='  ready={.status.readyReplicas}/{.status.replicas}  updated={.status.updatedReplicas}{"\n"}' 2>&1
kubectl -n $NS get pod -o jsonpath='{range .items[*]}{.metadata.name}{"  sa="}{.spec.serviceAccountName}{"  img="}{range .status.containerStatuses[*]}ready={.ready} restarts={.restartCount} imageID={.imageID}{"\n"}{end}{end}' 2>&1 \
  | grep -F -- "$T" | sed 's/^/    /'
echo "  --- 新 Pod 容器起始/拉取事件（有 crash 会在这里露出来）"
kubectl -n $NS get events --sort-by=.lastTimestamp 2>&1 | grep -Ei 'pulled|created|started|backoff|crash' \
  | grep -F "$T" | tail -6 | sed 's/^/    /'
echo "--- G0–G4 结束（写入面只有 deploy/$T 的容器镜像）"
exit $RC
