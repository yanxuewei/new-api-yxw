#!/usr/bin/env bash
# task17 卡片验收项只读核查（不改任何资源）
NS=new-api
echo "### Q1 namespace label pod-identity"
kubectl get ns $NS -o jsonpath='{.metadata.labels}{"\n"}'

echo "### Q2 ResourceQuota (hard)"
kubectl -n $NS get resourcequota -o json 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
if not d['items']: print('  (无 ResourceQuota)'); raise SystemExit
for it in d['items']:
    print('  name=',it['metadata']['name'])
    print('  hard=',json.dumps(it['status'].get('hard',{}),sort_keys=True))
    print('  used=',json.dumps(it['status'].get('used',{}),sort_keys=True))
"

echo "### Q3 ConfigMap new-api-config full data"
kubectl -n $NS get cm new-api-config -o json 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
for k,v in sorted(d.get('data',{}).items()):
    print('  %-32s= %s' % (k,v))
" || echo "  (缺 ConfigMap)"

echo "### Q4 SA new-api-app annotations + imagePullSecrets"
kubectl -n $NS get sa new-api-app -o json 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
print('  annotations=',json.dumps(d['metadata'].get('annotations',{}),sort_keys=True))
print('  imagePullSecrets=',[s.get('name') for s in d.get('imagePullSecrets',[])])
" || echo "  (缺 SA)"

echo "### Q5 ExternalSecret CRD 是否存在"
kubectl get crd 2>/dev/null | grep -Ei 'externalsecret|secretproviderclass' || echo "  (无 ExternalSecret/SecretProviderClass CRD)"
kubectl api-resources 2>/dev/null | grep -Ei 'alibabacloud.com' | head -5

echo "### Q6 Secret 键名清单（不打印值）"
for s in $(kubectl -n $NS get secret -o name 2>/dev/null | sed 's|secret/||'); do
  echo "  secret $s:"
  kubectl -n $NS get secret "$s" -o jsonpath='{.data}' 2>/dev/null | python3 -c "
import json,sys
raw=sys.stdin.read().strip()
if not raw: print('    (no data)'); raise SystemExit
print('   ', ','.join(sorted(json.loads(raw).keys())))
"
done

echo "### Q7 Pod identity webhook / secret-manager 组件 Pod"
kubectl get pods -A 2>/dev/null | grep -Ei 'pod-identity|secret-manager|ack-secret|webhook' | head -10 || echo "  (无匹配)"

echo "### Q8 运行中 Pod 的 ALIBABA_CLOUD_* env（RRSA 注入证据）"
kubectl -n $NS get pods -o name 2>/dev/null | sed 's|pod/||' | head -5
for p in $(kubectl -n $NS get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | head -5); do
  echo "--- pod $p"
  kubectl -n $NS exec "$p" -- sh -c 'env | grep -i ALIBABA_CLOUD | sed "s/=.*TOKEN.*/=<redacted>/" ; ls -l \$ALIBABA_CLOUD_OIDC_TOKEN_FILE 2>/dev/null' 2>&1 | head -8
done

echo "### Q9 Pod spec 的 serviceAccountName / env 来源（键名级别）"
kubectl -n $NS get pods -o json 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
for it in d['items']:
    m=it['metadata']['name']; sp=it['spec']
    print('  pod',m,'sa=',sp.get('serviceAccountName'))
    for c in sp['containers']:
        ek=[e.get('name') for e in (c.get('env') or [])]
        ef=[ (g.get('configMapRef') or {}).get('name') or (g.get('secretRef') or {}).get('name') for g in (c.get('envFrom') or [])]
        print('     container',c['name'],'env=',','.join(ek),'envFrom=',','.join([x for x in ef if x]))
        for e in (c.get('env') or []):
            vf=e.get('valueFrom') or {}
            if vf: print('        secretKeyRef:', (vf.get('secretKeyRef') or {}).get('name'), '->', (vf.get('secretKeyRef') or {}).get('key'))
"
echo "DONE-T17-CHECK"
