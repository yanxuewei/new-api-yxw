import verify_inventory as v
import json
rule_id=None
try:
 info=json.loads(v.run(['docker','inspect',v.CONTAINER]))[0];v.MYSQL_PASSWORD=next(x.split('=',1)[1] for x in info['Config']['Env'] if x.startswith('MYSQL_ROOT_PASSWORD='))
 login=v.request('/auth/login','POST',json.loads((v.SRC/'erpadmin.credentials').read_text()),auth=False);v.TOKEN=login['data']['token']
 v.sql("INSERT INTO erp_product.t_product(id,internal_sku,product_name,status) VALUES ({},{},{},1); INSERT INTO erp_product.t_product_sku(id,product_id,sku_code,sku_name,status) VALUES ({},{},{},{},1);".format(v.PRODUCT_ID,v.quoted(v.PREFIX),v.quoted(v.PREFIX),v.SKU_ID,v.PRODUCT_ID,v.quoted(v.SKU),v.quoted(v.SKU)))
 w=v.request('/warehouse','POST',{'warehouseCode':v.CODES[0],'warehouseName':v.CODES[0],'warehouseType':'main','status':1});wid=w['id']
 r=v.request('/inventory/alert/rule','POST',{'productId':v.PRODUCT_ID,'sku':v.SKU,'warehouseId':wid,'safeStock':20,'alertStock':10,'minStock':2,'alertType':'LOW','advanceDays':3,'notifyType':'SYSTEM','enabled':True,'remark':v.PREFIX});rule_id=r if isinstance(r,int) else r['id']
 v.request('/inventory/import','POST',[{'skuCode':v.SKU,'warehouseId':wid,'availableQty':5,'safetyStock':10}])
 records=v.request('/inventory/alert/records?warehouseId='+str(wid))['records'];v.require(len(records)>0,'库存写入未联动预警');record=records[0]
 v.request('/inventory/alert/check?warehouseId='+str(wid)+'&sku='+v.SKU,'POST',{})
 records2=v.request('/inventory/alert/records?warehouseId='+str(wid))['records'];v.require(len(records2)==len(records),'重复预警未去重')
 rep=v.request('/inventory/alert/record/'+str(record['id'])+'/replenishment','POST',{'suggestedQuantity':15});rid=rep if isinstance(rep,int) else rep['id']
 v.request('/inventory/alert/replenishment/'+str(rid)+'/confirm','POST',{'remark':'VERIFY'})
 v.request('/inventory/alert/record/'+str(record['id'])+'/handle','POST',{'remark':'VERIFY'})
 for path in ['/inventory/alert/statistics/realtime','/inventory/alert/statistics/trend?days=7','/inventory/alert/statistics/distribution','/inventory/alert/settings','/inventory/alert/rules','/inventory/alert/replenishments']:
  v.request(path)
 settings=v.request('/inventory/alert/settings');v.request('/inventory/alert/settings','PUT',settings)
 print('ALERT_ACCEPTANCE_OK')
finally:
 if rule_id is not None:
  v.sql('DELETE FROM erp_inventory.t_repair_alert_replenishment WHERE rule_id={}; DELETE FROM erp_inventory.t_repair_alert_record WHERE rule_id={}; DELETE FROM erp_inventory.t_repair_alert_rule WHERE id={} AND sku={};'.format(rule_id,rule_id,rule_id,v.quoted(v.SKU)))
 if v.MYSQL_PASSWORD:v.cleanup()
