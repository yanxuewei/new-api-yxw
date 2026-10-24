#!/usr/bin/env python3
import pathlib,hashlib,urllib.request,json,subprocess,sys
SRC=pathlib.Path('/opt/OmniTradeERP/ops/module-repair');DIST=SRC/sys.argv[1]/'dist';BASE='https://workflow-erp.likha.hk'
paths=[DIST/'index.html']
for name in ['Assistant','Pricing','Recommend','Anomaly','Description','InventoryPredict','ai']:
 found=list((DIST/'assets').glob(name+'-*.js'));assert len(found)==1,(name,len(found));paths+=found
for p in paths:
 rel=str(p.relative_to(DIST));req=urllib.request.Request(BASE+'/'+rel,headers={'Cache-Control':'no-cache'})
 with urllib.request.urlopen(req,timeout=30) as response: content=response.read();assert response.status==200
 assert hashlib.sha256(content).digest()==hashlib.sha256(p.read_bytes()).digest(),rel
 print('PASS_ASSET_SHA256',rel)
for name in ['warehouse-service','gateway','frontend']:
 item=json.loads(subprocess.check_output(['docker','inspect','erp-minimal-'+name]).decode())[0]
 assert item['State']['Health']['Status']=='healthy',name
 assert item['RestartCount']==0 and not item['State']['OOMKilled'],name
 print('PASS_HEALTH',name,item['Config']['Image'],'healthy restart=0 oom=false')
print('AI_PUBLISHED_ASSET_ACCEPTANCE_OK (not browser click test)')
