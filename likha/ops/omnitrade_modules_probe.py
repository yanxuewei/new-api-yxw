import subprocess,json,io,tarfile,zipfile,pathlib

def run(a): return subprocess.check_output(a,universal_newlines=True)
info=json.loads(run(['docker','inspect','erp-minimal-mysql']))[0]
pw=next(v.split('=',1)[1] for v in info['Config']['Env'] if v.startswith('MYSQL_ROOT_PASSWORD='))
sql="SELECT TABLE_SCHEMA,TABLE_NAME FROM information_schema.tables WHERE TABLE_SCHEMA LIKE 'erp%'; SELECT COUNT(*) AS users FROM erp_user.t_user; SELECT role_code,COUNT(*) FROM erp_user.t_role GROUP BY role_code; SELECT COUNT(*) FROM erp_user.t_user_role;"
print(run(['docker','exec','-e','MYSQL_PWD='+pw,'erp-minimal-mysql','mysql','-uroot','-N','-e',sql]))
raw=subprocess.check_output(['docker','cp','erp-minimal-warehouse-service:/app/warehouse-service.jar','-'])
with tarfile.open(fileobj=io.BytesIO(raw)) as t: data=t.extractfile(t.getmembers()[0]).read()
with zipfile.ZipFile(io.BytesIO(data)) as z:
 print('LIBS',[n for n in z.namelist() if n.startswith('BOOT-INF/lib/') and any(s in n for s in ['jdbc','redis','jackson','security','jwt','mysql'])])
 print('ENTRY',z.read('META-INF/MANIFEST.MF').decode())
 print('CONFIG',z.read('BOOT-INF/classes/application.yml').decode())
