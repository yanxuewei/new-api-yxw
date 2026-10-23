import pathlib,subprocess,json,secrets,os
SRC=pathlib.Path('/opt/OmniTradeERP/ops/module-repair');java='/usr/lib/jvm/java-21-alibaba-dragonwell-21.0.11.0.11.10-1.1.al8.x86_64/bin/java'
def run(a,**kw):return subprocess.run(a,check=True,universal_newlines=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,**kw).stdout
info=json.loads(run(['docker','inspect','erp-minimal-mysql']))[0];pw=next(v.split('=',1)[1] for v in info['Config']['Env'] if v.startswith('MYSQL_ROOT_PASSWORD='))
def sql(q):return run(['docker','exec','-i','-e','MYSQL_PWD='+pw,'erp-minimal-mysql','mysql','--default-character-set=utf8mb4','-uroot','-N'],input=q)
if sql('SELECT COUNT(*) FROM erp_user.t_user;').strip()!='0':raise RuntimeError('User table not empty; refusing bootstrap')
password=secrets.token_urlsafe(24);classes=SRC/'build/classes';cp=str(classes)+':'+str(SRC/'build/lib/*')
hash=run([java,'-Xmx64m','-cp',cp,'PasswordHash'],input=password)
assert hash.startswith('$2') and len(hash)==60
credential=SRC/'erpadmin.credentials';fd=os.open(str(credential),os.O_CREAT|os.O_EXCL|os.O_WRONLY,0o600)
with os.fdopen(fd,'w') as f:json.dump({'username':'erpadmin','password':password},f)
sql("START TRANSACTION; INSERT INTO erp_user.t_user(id,username,password,real_name,status) VALUES(1,'erpadmin','"+hash+"','系统管理员',1); INSERT INTO erp_user.t_role(id,role_code,role_name,status,sort) VALUES(1,'admin','系统管理员',1,0); INSERT INTO erp_user.t_user_role(id,user_id,role_id) VALUES(1,1,1); COMMIT;")
print('ADMIN_CREATED username=erpadmin credential_file='+str(credential)+' mode=600')
