import pathlib,json,urllib.request,urllib.error,secrets
SRC=pathlib.Path('/opt/OmniTradeERP/ops/module-repair');BASE='https://workflow-erp.likha.hk/api';token=None

def req(path,method='GET',body=None,expected=200,auth=True):
 headers={'Content-Type':'application/json'}
 if auth and token:headers['Authorization']='Bearer '+token
 r=urllib.request.Request(BASE+path,headers=headers,method=method,data=None if body is None else json.dumps(body).encode())
 try:
  with urllib.request.urlopen(r,timeout=20) as res:code=res.status;raw=res.read()
 except urllib.error.HTTPError as e:code=e.code;raw=e.read()
 if code!=expected:raise RuntimeError('%s %s got %s wanted %s'%(method,path,code,expected))
 print('PASS_HTTPS',method,path,code)
 return json.loads(raw) if raw else None
creds=json.loads((SRC/'erpadmin.credentials').read_text());token=req('/auth/login','POST',creds,auth=False)['data']['token'];admin=token
for p in ['/inventory/list','/inventory/alert/settings','/logistics/rates','/finance/account/list','/platform/config/list','/user/list']:req(p)
req('/user/list',expected=401,auth=False);req('/auth/refresh','POST',{},401)
password=secrets.token_urlsafe(18);username='VERIFY-SEC-'+secrets.token_hex(5);u=req('/user','POST',{'username':username,'password':password});uid=u['id']
try:
 token=req('/auth/login','POST',{'username':username,'password':password},auth=False)['data']['token'];normal=token
 req('/user/list',expected=403)
 token=admin;req('/user/'+str(uid)+'/reset-password','POST',{'newPassword':secrets.token_urlsafe(18)})
 token=normal;req('/user/list',expected=401)
 token=admin;roles=req('/role/list');assert roles
 req('/erp-user-service/auth/refresh','POST',{},404)
 print('SECURITY_ACCEPTANCE_OK')
finally:
 token=admin;req('/user/'+str(uid),'DELETE')
