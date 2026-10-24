#!/usr/bin/env python3
"""Add AI routes to the existing warehouse JVM, retain all other routes/resources."""
import pathlib,subprocess,json,yaml,datetime,shutil,sys,os,hashlib
ROOT=pathlib.Path('/opt/OmniTradeERP'); SRC=ROOT/'ops/module-repair'; COMPOSE=ROOT/'docker-compose.minimal.yml'
def run(a,**kw):return subprocess.run(a,check=True,universal_newlines=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,**kw).stdout
def digest(p):return hashlib.sha256(p.read_bytes()).hexdigest()
mode=sys.argv[1]
if mode=='prepare':
 stamp=datetime.datetime.now().strftime('%Y%m%d-%H%M%S'); backup=ROOT/'.ops-backups'/('ai-center-'+stamp);backup.mkdir(mode=0o700)
 shutil.copy2(str(COMPOSE),str(backup/COMPOSE.name))
 with (backup/'source-before.tar').open('wb') as out:
  subprocess.run(['tar','-cf','-','-C',str(ROOT),'erp-web/src','erp-warehouse-service/src/main/java'],stdout=out,check=True)
 info=json.loads(run(['docker','inspect','erp-minimal-mysql']))[0];pw=next(v.split('=',1)[1] for v in info['Config']['Env'] if v.startswith('MYSQL_ROOT_PASSWORD='))
 env=os.environ.copy();env['MYSQL_PWD']=pw
 with (backup/'mysql-before.sql').open('w') as out:
  subprocess.run(['docker','exec','-e','MYSQL_PWD','erp-minimal-mysql','mysqldump','-uroot','--single-transaction','--all-databases','--routines','--events','--set-gtid-purged=OFF'],stdout=out,stderr=subprocess.PIPE,env=env,check=True)
 assert (backup/'mysql-before.sql').stat().st_size>1000
 (backup/'mysql-before.sql').chmod(0o600)
 c=yaml.safe_load(COMPOSE.read_text());spec=c['services']['warehouse-service'];spec['image']=(SRC/'image-tag.txt').read_text().strip()
 secrets=ROOT/'.secrets/ai-center.env'
 if secrets.is_file():
  assert (secrets.stat().st_mode & 0o077)==0, 'AI env file must have permission 600'
  files=spec.get('env_file',[]);files=[files] if isinstance(files,str) else files
  if str(secrets) not in files:files.append(str(secrets))
  spec['env_file']=files
 gateway=c['services']['gateway']['environment']; app=json.loads(gateway['SPRING_APPLICATION_JSON']);routes=app['spring']['cloud']['gateway']['routes']
 routes[:]=[r for r in routes if r['id']!='ai-center']
 routes.insert(0,{'id':'ai-center','uri':'http://warehouse-service:8085','predicates':['Path=/api/ai-center/**'],'filters':['StripPrefix=1']})
 gateway['SPRING_APPLICATION_JSON']=json.dumps(app)
 candidate=SRC/'ai-compose.candidate.yml';candidate.write_text(yaml.safe_dump(c,allow_unicode=True))
 run(['docker','compose','-f',str(candidate),'config','--quiet'])
 print(run(['docker','compose','--dry-run','-f',str(candidate),'up','-d','--no-build','warehouse-service','gateway']))
 state={'backup':str(backup),'composeBeforeHash':digest(COMPOSE),'candidateHash':digest(candidate),'image':spec['image']}
 (SRC/'ai-deploy-state.json').write_text(json.dumps(state))
 print('BACKUP_READY',backup);print('CANDIDATE_READY',spec['image'])
elif mode=='activate':
 state=json.loads((SRC/'ai-deploy-state.json').read_text());candidate=SRC/'ai-compose.candidate.yml'
 assert digest(COMPOSE)==state['composeBeforeHash'],'Compose changed since prepare; rerun prepare'
 assert digest(candidate)==state['candidateHash'],'Candidate changed'
 info=json.loads(run(['docker','inspect','erp-minimal-mysql']))[0];pw=next(v.split('=',1)[1] for v in info['Config']['Env'] if v.startswith('MYSQL_ROOT_PASSWORD='))
 env=os.environ.copy();env['MYSQL_PWD']=pw
 for name in ['ai-business-migration.sql','ai-language-migration.sql']:
  sql=(SRC/name).read_text();assert 'DROP ' not in sql.upper() and 'TRUNCATE ' not in sql.upper()
  run(['docker','exec','-i','-e','MYSQL_PWD','erp-minimal-mysql','mysql','--default-character-set=utf8mb4','-uroot'],input=sql,env=env)
  print('MIGRATION_OK',name)
 shutil.copy2(str(candidate),str(COMPOSE))
 try: print(run(['docker','compose','-f',str(COMPOSE),'up','-d','--no-build','--wait','--wait-timeout','180','warehouse-service','gateway']))
 except subprocess.CalledProcessError:
  print('START_FAILED; restore compose backup and restart warehouse-service/gateway. Additive tables retained.');raise
 dest=ROOT/'erp-warehouse-service/src/main/java/com/crossborder/erp/warehouse/repair'
 assert dest.is_dir()
 for name in ['AiBusinessController.java','AiLanguageController.java']:shutil.copy2(str(SRC/name),str(dest/name))
 print('ACTIVATED',state['image']);print('ROLLBACK_COMPOSE',state['backup']+'/docker-compose.minimal.yml')
elif mode=='inspect':
 for name in ['warehouse-service','gateway','frontend']:
  x=json.loads(run(['docker','inspect','erp-minimal-'+name]))[0]
  print('CONTAINER',name,x['Config']['Image'],x['State'].get('Health',{}).get('Status'), 'restarts='+str(x['RestartCount']),'oom='+str(x['State']['OOMKilled']))
 print(run(['docker','stats','--no-stream','--format','{{.Name}} {{.MemUsage}} {{.CPUPerc}}']))
else: raise SystemExit('prepare | activate | inspect')
