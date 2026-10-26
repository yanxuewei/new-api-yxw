import json,urllib.request,urllib.error,pathlib,sys,datetime,subprocess
SRC=pathlib.Path('/opt/OmniTradeERP/ops/module-repair');BASE='http://127.0.0.1:8080/api';token=None

def request(path,method='GET',body=None,expected=200,auth=True):
 headers={'Content-Type':'application/json'}
 if token and auth:headers['Authorization']='Bearer '+token
 req=urllib.request.Request(BASE+path,data=None if body is None else json.dumps(body).encode(),headers=headers,method=method)
 try:
  with urllib.request.urlopen(req,timeout=20) as r:status=r.status;raw=r.read()
 except urllib.error.HTTPError as e:status=e.code;raw=e.read()
 try:data=json.loads(raw)
 except Exception:data={'raw_bytes':len(raw)}
 if status!=expected:raise RuntimeError('%s %s status=%s expected=%s response=%s'%(method,path,status,expected,str(data)[:500]))
 print('PASS',method,path,status)
 return data
credentials=json.loads((SRC/'erpadmin.credentials').read_text());login=request('/auth/login','POST',credentials,auth=False)
if login.get('code')!=200:raise RuntimeError('LOGIN_BUSINESS_FAILURE '+str(login)[:400])
token=login['data']['token']
if sys.argv[1]=='read':
 for path in ['/inventory/stats','/inventory/list','/warehouse/list','/logistics/channels','/logistics/rates','/finance/account/list','/finance/category/list','/finance/flow/list','/finance/flow/statistics?currency=CNY','/finance/flow/trend?days=7&currency=CNY','/finance/flow/category?currency=CNY','/platform/config/list','/user/list','/role/list','/department/tree','/permission/tree']:
  request(path)
 request('/user/list',expected=401,auth=False)
 request('/platform/sync/orders','POST',{'platform':'shopee','shopId':'none'},501)
 print('READ_ACCEPTANCE_OK')
elif sys.argv[1]=='write':
 stamp=datetime.datetime.now().strftime('%H%M%S');prefix='VERIFY-'+stamp
 # Deliberate, labelled acceptance records are removed/reversed using public APIs.
 u=request('/user','POST',{'username':prefix,'password':'OnlyTest-'+stamp+'-Random9!','realName':'验收测试'});uid=u['id'];request('/user','PUT',{'id':uid,'realName':'验收更新'});request('/user/'+str(uid))
 request('/user/'+str(uid)+'/reset-password','POST',{'newPassword':'UpdatedTest-'+stamp+'-Safe9!'});request('/user/'+str(uid),'DELETE')
 request('/user/1','DELETE',expected=400)
 p=request('/platform/config','POST',{'platform':'shopee','shopId':prefix,'shopName':'验收测试','apiSecret':'TEST-SECRET-NOT-REAL'});pid=p['data']['id'];assert p['data']['apiSecret']=='********';request('/platform/config','POST',{'id':pid,'platform':'shopee','shopId':prefix,'shopName':'验收更新','apiSecret':'********'});request('/platform/config/'+str(pid),'DELETE')
 w=request('/warehouse','POST',{'warehouseCode':prefix,'warehouseName':'验收测试','warehouseType':'main','status':1});wid=w['id'];request('/warehouse','PUT',{'id':wid,'warehouseCode':prefix,'warehouseName':'验收更新','warehouseType':'main','status':1});request('/warehouse/'+str(wid),'DELETE')
 a=request('/finance/account','POST',{'accountNo':prefix,'accountName':'验收测试','accountType':'bank','currency':'CNY','balance':0});aid=a['id'];f=request('/finance/flow','POST',{'type':'income','amount':100,'accountId':aid,'remark':prefix});fid=f['id']
 accounts=request('/finance/account/list');assert next(x for x in accounts if x['id']==aid)['balance']==100
 request('/finance/account/'+str(aid),'DELETE',expected=400)
 request('/finance/flow','PUT',{'id':fid,'type':'income','amount':80,'accountId':aid,'remark':prefix});accounts=request('/finance/account/list');assert next(x for x in accounts if x['id']==aid)['balance']==80
 request('/finance/flow/'+str(fid),'DELETE');accounts=request('/finance/account/list');assert next(x for x in accounts if x['id']==aid)['balance']==0
 request('/finance/account/'+str(aid),'DELETE')
 channel={'code':prefix,'name':'验收渠道','carrier':'TEST','type':'EXPRESS','coverage':['US'],'features':[],'avgDeliveryDays':7,'trackingSupport':True};request('/logistics/channel','POST',channel)
 rate=request('/logistics/rate','POST',{'channelCode':prefix,'fromCountry':'CN','toCountry':'US','weightRangeMin':0,'weightRangeMax':10,'basePrice':10,'pricePerKg':5,'estimatedDays':7,'currency':'USD'});rid=rate if isinstance(rate,int) else rate['id']
 result=request('/logistics/calculate','POST',{'fromCountry':'CN','toCountry':'US','weight':2,'length':0,'width':0,'height':0});assert any(x['channelCode']==prefix and x['totalPrice']==20 for x in result)
 request('/logistics/rate/'+str(rid),'DELETE');request('/logistics/channel/'+prefix,'DELETE')
 print('WRITE_ACCEPTANCE_OK')
else:raise SystemExit('unknown mode')
