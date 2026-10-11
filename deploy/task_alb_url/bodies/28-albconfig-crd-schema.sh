kubectl get crd albconfigs.alibabacloud.com -o json 2>/dev/null | python3 -c "
import sys, json
d = json.load(sys.stdin)
try:
    prop = d['spec']['versions'][0]['schema']['openAPIV3Schema']['properties']['spec']['properties']['listeners']
except Exception as e:
    print('路径解析失败:', e)
    v = d['spec']['versions'][0]
    print('version keys:', list(v.keys()))
    print('spec props:', list(d['spec']['versions'][0]['schema']['openAPIV3Schema']['properties']['spec']['properties'].keys()))
    raise SystemExit
print(json.dumps(prop, ensure_ascii=False, indent=1)[:4000])
"
