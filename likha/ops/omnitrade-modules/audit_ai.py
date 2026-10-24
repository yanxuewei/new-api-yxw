#!/usr/bin/env python3
"""Read-only AI readiness audit; never emit credentials or customer records."""
import pathlib, subprocess, json, yaml, re
ROOT=pathlib.Path('/opt/OmniTradeERP')
def run(a,**kw): return subprocess.run(a,check=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,universal_newlines=True,**kw).stdout
info=json.loads(run(['docker','inspect','erp-minimal-mysql']))[0]
pw=next(v.split('=',1)[1] for v in info['Config']['Env'] if v.startswith('MYSQL_ROOT_PASSWORD='))
def sql(q): return run(['docker','exec','-i','-e','MYSQL_PWD='+pw,'erp-minimal-mysql','mysql','--default-character-set=utf8mb4','-uroot','-N'],input=q)
config=yaml.safe_load((ROOT/'docker-compose.minimal.yml').read_text())
print('SERVICES',','.join(config['services']))
gateway=config['services']['gateway']['environment']; j=json.loads(gateway.get('SPRING_APPLICATION_JSON','{}'))
print('ROUTES',json.dumps(j.get('spring',{}).get('cloud',{}).get('gateway',{}).get('routes',[])))
for name,s in config['services'].items():
 env=s.get('environment',{}); env=env if isinstance(env,dict) else dict(x.split('=',1) for x in env if '=' in x)
 for k,v in env.items():
  if re.search(r'LLM|OPENAI|DEEPSEEK|ANTHROPIC|AI_API',k,re.I): print('MODEL_ENV',name,k,'configured' if v and not str(v).startswith('${') else 'empty_or_reference')
for d in ['erp-ai-assistant-service','erp-product-description-service']:
 for f in (ROOT/d/'src/main/resources').glob('*.y*ml'):
  obj=yaml.safe_load(f.read_text()) or {}
  def walk(x,path=''):
   if isinstance(x,dict):
    for k,v in x.items(): walk(v,path+'.'+str(k))
   elif re.search(r'llm|openai|deepseek',path,re.I):
    text=str(x); print('MODEL_FILE',str(f.relative_to(ROOT)),path,'placeholder' if '${' in text else 'empty' if not x else 'literal_present', 'false' if x is False else '')
  walk(obj)
print('DATABASES\n'+sql('SHOW DATABASES;'))
print('TABLES\n'+sql("SELECT table_schema,table_name,table_rows FROM information_schema.tables WHERE table_schema LIKE 'erp%' ORDER BY table_schema,table_name;"))
print('BUSINESS_COLUMNS\n'+sql("SELECT table_schema,table_name,column_name,column_type FROM information_schema.columns WHERE table_schema IN ('erp_product','erp_order','erp_warehouse','erp_inventory') ORDER BY table_schema,table_name,ordinal_position;"))
for db,table in [('erp_product','t_product'),('erp_order','t_order'),('erp_order','t_order_item'),('erp_inventory','t_inventory'),('erp_product','t_product_sku')]:
 try: print('EXACT_COUNT',db,table,sql('SELECT COUNT(*) FROM `'+db+'`.`'+table+'`;').strip())
 except subprocess.CalledProcessError: print('EXACT_COUNT_QUERY_FAILED',db,table)
for f in [ROOT/'.env',ROOT/'.env.minimal',ROOT/'.secrets/ai-center.env']:
 if not f.is_file(): print('ENV_FILE',str(f.relative_to(ROOT)),'absent');continue
 found=0
 for line in f.read_text().splitlines():
  if '=' not in line or line.lstrip().startswith('#'):continue
  k,v=line.split('=',1)
  if re.search(r'LLM|OPENAI|DEEPSEEK|OMNITRADE_AI',k,re.I):found+=1;print('ENV_FILE_KEY',str(f.relative_to(ROOT)),k.strip(),'set' if v.strip().strip(chr(34)).strip(chr(39)) else 'empty')
 print('ENV_FILE_MODEL_KEYS',str(f.relative_to(ROOT)),found)
for container in ['erp-minimal-warehouse-service','erp-minimal-gateway']:
 ci=json.loads(run(['docker','inspect',container]))[0]
 for value in ci['Config']['Env']:
  k,v=value.split('=',1)
  if re.search(r'LLM|OPENAI|DEEPSEEK|OMNITRADE_AI',k,re.I):print('RUNTIME_MODEL_KEY',container,k,'set' if v else 'empty')
print('AUDIT_DONE')
