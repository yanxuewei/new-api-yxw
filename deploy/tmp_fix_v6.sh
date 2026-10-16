#!/bin/bash
# v6：ops-operator & newapi-dev-program 追加授权检查页所需的只读（角色/组/域）
set -euo pipefail

add_stmt() {
  local PN="$1" DOC=/tmp/policy_v6.json
  aliyun ram GetPolicy --PolicyName "$PN" --PolicyType Custom 2>&1 | tr -d '\r' \
  | python3 -c "
import json,sys
d=json.load(sys.stdin)
doc=d['DefaultPolicyVersion']['PolicyDocument']
if isinstance(doc,str): doc=json.loads(doc)
st=doc['Statement']
st=st if isinstance(st,list) else [st]
acts=['ram:GetRole','ram:ListRoles','ram:ListGroupsForUser','ram:GetDefaultDomain','ram:ListPoliciesForGroup','ram:ListEntitiesForPolicy','resourcemanager:GetRole','resourcemanager:ListRoles']
flat=[]
for s in st:
    a=s.get('Action',[])
    flat += a if isinstance(a,list) else [a]
if 'ram:GetRole' not in flat:
    st.append({'Effect':'Allow','Action':acts,'Resource':['*']})
    print('appended', file=sys.stderr)
else:
    print('already', file=sys.stderr)
open('/tmp/policy_v6.json','w').write(json.dumps({'Version':'1','Statement':st}, ensure_ascii=False))
"
  aliyun ram CreatePolicyVersion --PolicyName "$PN" \
    --PolicyDocument "$(cat $DOC)" --SetAsDefault true 2>&1 | tr -d '\r' | grep -E 'VersionId|IsDefaultVersion' | head -2
}

echo "== newapi-ops-operator"
add_stmt newapi-ops-operator
echo "== newapi-dev-program"
add_stmt newapi-dev-program

echo
echo "== 回读核验（应含 ram:GetRole + resourcemanager:GetRole）"
for PN in newapi-ops-operator newapi-dev-program; do
  echo "-- $PN"
  aliyun ram GetPolicy --PolicyName "$PN" --PolicyType Custom 2>&1 | tr -d '\r' \
  | python3 -c "
import json,sys
d=json.load(sys.stdin)
pv=d['DefaultPolicyVersion']; doc=pv['PolicyDocument']
if isinstance(doc,str): doc=json.loads(doc)
print('  default:', pv.get('VersionId'))
for s in doc['Statement']:
    a=s.get('Action',[])
    a=a if isinstance(a,list) else [a]
    if 'ram:GetRole' in a or 'resourcemanager:GetRole' in a:
        print('  allow:', [x for x in a if 'Role' in x or 'Groups' in x or 'Domain' in x])
"
done
