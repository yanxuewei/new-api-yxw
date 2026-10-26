import pathlib,subprocess,json,datetime,sys
ROOT=pathlib.Path('/opt/OmniTradeERP');SRC=ROOT/'ops/module-repair';NAME='erp-legacy-user-audit'
def run(a,**kw):return subprocess.run(a,check=True,universal_newlines=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,**kw).stdout
mode=sys.argv[1]
if mode=='clone':
 running=run(['docker','ps','--filter','volume=omnitradeerp_mysql-data','--format','{{.ID}}']).strip()
 if running:raise RuntimeError('Legacy volume is mounted by a running container; stop audit')
 volume=json.loads(run(['docker','volume','inspect','omnitradeerp_mysql-data']))[0]['Mountpoint'];clone=ROOT/'.ops-backups'/('legacy-user-clone-'+datetime.datetime.now().strftime('%Y%m%d-%H%M%S'));clone.mkdir(mode=0o700)
 print(run(['cp','-a',volume+'/.',str(clone)]));(SRC/'legacy-clone.txt').write_text(str(clone))
 print(run(['docker','run','-d','--name',NAME,'--network','none','--memory','320m','--memory-swap','384m','--cpus','0.5','-v',str(clone)+':/var/lib/mysql','mysql:8.0','--skip-grant-tables','--skip-networking','--innodb-buffer-pool-size=64M','--performance-schema=OFF','--max-connections=10']))
 print('CLONE',clone)
elif mode=='inspect':
 print(run(['docker','exec',NAME,'mysql','-uroot','-N','-e',"SELECT TABLE_SCHEMA,TABLE_NAME FROM information_schema.tables WHERE TABLE_NAME IN ('t_user','t_role','t_user_role'); SELECT id,username,status,deleted,LENGTH(password) AS hash_length FROM erp_user.t_user; SELECT id,role_code,status FROM erp_user.t_role; SELECT user_id,role_id FROM erp_user.t_user_role;"]))
elif mode=='export':
 backup=pathlib.Path((SRC/'legacy-clone.txt').read_text()).parent;dest=backup/'legacy-admin-users.sql'
 with dest.open('w') as out:subprocess.run(['docker','exec',NAME,'mysqldump','-uroot','--no-create-info','--skip-add-locks','--skip-disable-keys','--skip-triggers','--set-gtid-purged=OFF','--where','deleted=0','erp_user','t_user'],stdout=out,check=True)
 dest.chmod(0o600);print('EXPORT',dest)
else:raise SystemExit('Unknown mode')
