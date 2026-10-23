import pathlib,subprocess,json,datetime,sys,urllib.request,hashlib,re
ROOT=pathlib.Path('/opt/OmniTradeERP')
def run(args,**kw):
    return subprocess.run(args,check=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,universal_newlines=True,**kw).stdout
info=json.loads(run(['docker','inspect','erp-minimal-mysql']))[0]
pw=next(v.split('=',1)[1] for v in info['Config']['Env'] if v.startswith('MYSQL_ROOT_PASSWORD='))
def sql(query):
    return run(['docker','exec','-i','-e','MYSQL_PWD='+pw,'erp-minimal-mysql','mysql','--default-character-set=utf8mb4','-uroot','-N','-B'],input=query)
print('CHARSETS',sql('SELECT @@character_set_server,@@character_set_client,@@character_set_connection,@@character_set_results;').strip())
print('ROLE_ROWS',sql('SELECT id,role_code,role_name,HEX(role_name) FROM erp_user.t_role;'))
print('ADMIN_NAMES',sql("SELECT id,username,real_name,HEX(real_name) FROM erp_user.t_user WHERE username='erpadmin';"))
print('ROLE_COLUMN',sql("SELECT COLUMN_NAME,CHARACTER_SET_NAME,COLLATION_NAME FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='erp_user' AND TABLE_NAME='t_role' AND COLUMN_NAME='role_name';"))
if '--verify-assets' in sys.argv:
    dist=ROOT/'ops/module-repair/frontend-display-20261023/dist'
    assert sql("SELECT HEX(role_name) FROM erp_user.t_role WHERE id=1 AND role_code='admin';").strip()=='系统管理员'.encode('utf-8').hex().upper()
    source=(ROOT/'erp-web/src/views/Dashboard.vue').read_text()
    assert '< <el-col' not in source
    assets=list((dist/'assets').glob('Dashboard-*.js'))
    assert len(assets)==1
    for path in [dist/'index.html']+assets:
        relative=str(path.relative_to(dist))
        with urllib.request.urlopen('https://workflow-erp.likha.hk/'+relative,timeout=20) as response:
            assert response.status==200
            assert hashlib.sha256(response.read()).digest()==hashlib.sha256(path.read_bytes()).digest()
        print('PASS_ASSET_SHA256',relative)
    container=json.loads(run(['docker','inspect','erp-minimal-frontend']))[0]
    assert container['State']['Health']['Status']=='healthy'
    assert container['RestartCount']==0 and not container['State']['OOMKilled']
    print('PASS_FRONTEND',container['Config']['Image'],'healthy restart=0 oom=false')
    print('DISPLAY_FIX_VERIFIED (database and published assets; not browser click test)')
if '--apply' not in sys.argv:
    sys.exit(0)
expected=sys.argv[sys.argv.index('--apply')+1]
assert expected and all(c in '0123456789ABCDEF' for c in expected)
correct='系统管理员'.encode('utf-8').hex().upper()
role=sql("SELECT HEX(role_name) FROM erp_user.t_role WHERE id=1 AND role_code='admin';").strip()
assert role==expected, 'Role changed; refusing to overwrite'
backup=ROOT/'.ops-backups'/('display-fix-'+datetime.datetime.now().strftime('%Y%m%d-%H%M%S'))
backup.mkdir(mode=0o700)
(backup/'role-before.tsv').write_text(sql("SELECT id,role_code,role_name,HEX(role_name) FROM erp_user.t_role WHERE id=1;"),encoding='utf-8')
(backup/'rollback.sql').write_text("SET NAMES utf8mb4; UPDATE erp_user.t_role SET role_name=CONVERT(UNHEX('"+expected+"') USING utf8mb4) WHERE id=1 AND role_code='admin' AND HEX(role_name)='"+correct+"';\n",encoding='utf-8')
print('UPDATED_ROWS',sql("START TRANSACTION; UPDATE erp_user.t_role SET role_name=CONVERT(UNHEX('"+correct+"') USING utf8mb4) WHERE id=1 AND role_code='admin' AND HEX(role_name)='"+expected+"'; SELECT ROW_COUNT(); COMMIT;").strip())
assert sql("SELECT HEX(role_name) FROM erp_user.t_role WHERE id=1 AND role_code='admin';").strip()==correct
print('ROLE_FIXED',sql("SELECT id,role_code,role_name,HEX(role_name) FROM erp_user.t_role WHERE id=1;").strip())
print('BACKUP',str(backup))
