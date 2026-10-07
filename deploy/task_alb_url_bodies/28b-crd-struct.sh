kubectl get crd albconfigs.alibabacloud.com -o json 2>/dev/null | python3 -c "
import sys, json
d = json.load(sys.stdin)
v = d['spec']['versions'][0]
print('=== version ===', v['name'])
sch = v['schema']['openAPIV3Schema']
print('=== top schema keys ===', list(sch.keys()))
print('=== schema dump (first 1200) ===')
print(json.dumps(sch, ensure_ascii=False)[:1200])
print()
print('=== additionalPrinterColumns ===')
print(json.dumps(d['spec']['versions'][0].get('additionalPrinterColumns'), ensure_ascii=False)[:600])
"
echo
echo "=== CRD annotations (版本) ==="
kubectl get crd albconfigs.alibabacloud.com -o jsonpath='{.metadata.annotations}{"\n"}' 2>/dev/null | head -c 400
echo
echo "=== CRD labels ==="
kubectl get crd albconfigs.alibabacloud.com -o jsonpath='{.metadata.labels}{"\n"}' 2>/dev/null | head -c 400
