import pathlib,subprocess,json,yaml,datetime,shutil,sys
ROOT=pathlib.Path('/opt/OmniTradeERP');SRC=ROOT/'ops/module-repair';COMPOSE=ROOT/'docker-compose.minimal.yml'
def run(a,**kw):return subprocess.run(a,check=True,universal_newlines=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,**kw).stdout
def mysql(sql):return run(['docker','exec','-i','-e','MYSQL_PWD='+pw,'erp-minimal-mysql','mysql','-uroot','-N'],input=sql)
info=json.loads(run(['docker','inspect','erp-minimal-mysql']))[0];pw=next(v.split('=',1)[1] for v in info['Config']['Env'] if v.startswith('MYSQL_ROOT_PASSWORD='))
mode=sys.argv[1]
if mode=='prepare':
 stamp=datetime.datetime.now().strftime('%Y%m%d-%H%M%S');backup=ROOT/'.ops-backups'/('modules-'+stamp);backup.mkdir(mode=0o700)
 shutil.copy2(str(COMPOSE),str(backup/COMPOSE.name))
 with (backup/'mysql-all.sql').open('w') as out:subprocess.run(['docker','exec','-e','MYSQL_PWD='+pw,'erp-minimal-mysql','mysqldump','-uroot','--single-transaction','--all-databases','--routines','--events','--set-gtid-purged=OFF'],stdout=out,check=True)
 if (backup/'mysql-all.sql').stat().st_size<1000:raise RuntimeError('Backup too small')
 config=yaml.safe_load(COMPOSE.read_text());spec=config['services']['warehouse-service'];spec['image']=(SRC/'image-tag.txt').read_text().strip();spec['environment']['SPRING_DATA_REDIS_DATABASE']='0';spec['environment']['MANAGEMENT_ENDPOINTS_WEB_EXPOSURE_INCLUDE']='health';spec['environment']['SERVER_ERROR_INCLUDE_MESSAGE']='always';spec['mem_limit']='384m';spec['memswap_limit']='448m'
 env=spec['environment'];env['SPRING_DATASOURCE_HIKARI_MAXIMUM_POOL_SIZE']='3'
 gateway=config['services']['gateway']['environment']
 # Full route list replacement avoids accidental index overlap with earlier environment overrides.
 current=json.loads(gateway.get('SPRING_APPLICATION_JSON','{}'));routes=[
  {'id':'auth','uri':'http://user-service:8081','predicates':['Path=/api/auth/**'],'filters':['StripPrefix=1']},
  {'id':'order','uri':'http://order-service:8083','predicates':['Path=/api/order/**'],'filters':['StripPrefix=1']},
  {'id':'product','uri':'http://product-service:8082','predicates':['Path=/api/product/**'],'filters':['StripPrefix=1']},
  {'id':'customer','uri':'http://customer-service:8087','predicates':['Path=/api/customer/**'],'filters':['StripPrefix=1']},
  {'id':'supplier','uri':'http://supplier-service:8088','predicates':['Path=/api/supplier/**'],'filters':['StripPrefix=1']},
  {'id':'repair','uri':'http://warehouse-service:8085','predicates':['Path=/api/inventory/**,/api/warehouse/**,/api/logistics/**,/api/finance/**,/api/platform/**,/api/user/**,/api/role/**,/api/department/**,/api/permission/**'],'filters':['StripPrefix=1']}
 ]
 for key in list(gateway):
  if key.startswith('SPRING_CLOUD_GATEWAY_ROUTES_'):del gateway[key]
 current['spring.cloud.gateway.routes']=routes;gateway['SPRING_APPLICATION_JSON']=json.dumps(current)
 gateway['MANAGEMENT_ENDPOINTS_WEB_EXPOSURE_INCLUDE']='health'
 candidate=SRC/'docker-compose.candidate.yml';candidate.write_text(yaml.safe_dump(config,sort_keys=False,allow_unicode=True));run(['docker','compose','-f',str(candidate),'config','--quiet'])
 (SRC/'last-backup.txt').write_text(str(backup)+'\n');print('BACKUP',backup);print('CANDIDATE',candidate)
elif mode=='migrate':
 for name in ['inventory-migration.sql','finance-logistics-migration.sql','user-migration.sql']:
  sql=(SRC/name).read_text();assert 'DROP ' not in sql.upper();print(name,mysql(sql))
 if mysql("SELECT COUNT(*) FROM information_schema.columns WHERE TABLE_SCHEMA='erp_user' AND TABLE_NAME='t_role' AND COLUMN_NAME='sort';").strip()=='0':print(mysql('ALTER TABLE erp_user.t_role ADD COLUMN sort INT NOT NULL DEFAULT 0;'))
 print('MIGRATIONS_OK')
elif mode=='activate':
 backup=pathlib.Path((SRC/'last-backup.txt').read_text().strip())
 run(['docker','compose','--dry-run','-f',str(SRC/'docker-compose.candidate.yml'),'up','-d','--no-build','warehouse-service','gateway'])
 shutil.copy2(str(SRC/'docker-compose.candidate.yml'),str(COMPOSE))
 print('CONFIG_ACTIVATED',backup)
else:raise SystemExit('Unknown mode')
