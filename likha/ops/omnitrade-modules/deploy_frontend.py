import pathlib,subprocess,json,yaml,datetime,shutil,sys
ROOT=pathlib.Path('/opt/OmniTradeERP');SRC=ROOT/'ops/module-repair';BUILD=SRC/(sys.argv[1] if len(sys.argv)>1 else 'frontend-release');COMPOSE=ROOT/'docker-compose.minimal.yml'
assert (BUILD/'dist/index.html').is_file(), 'Missing built frontend index.html'
def run(a):return subprocess.run(a,check=True,universal_newlines=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT).stdout
stamp=datetime.datetime.now().strftime('%Y%m%d-%H%M%S');backup=ROOT/'.ops-backups'/('frontend-modules-'+stamp);backup.mkdir(mode=0o700);shutil.copy2(str(COMPOSE),str(backup/COMPOSE.name))
with (backup/'erp-web-src.tar').open('wb') as f:subprocess.run(['tar','-cf','-','-C',str(ROOT/'erp-web'),'src'],stdout=f,check=True)
info=json.loads(run(['docker','inspect','erp-minimal-frontend']))[0];base='omnitrade-local/frontend:repair-base';print(run(['docker','tag',info['Image'],base]))
(BUILD/'Dockerfile').write_text('FROM '+base+'\nCOPY dist/ /usr/share/nginx/html/\n')
tag='omnitrade-local/frontend:modules-'+stamp;print(run(['docker','build','--network=none','--pull=false','-t',tag,str(BUILD)]))
config=yaml.safe_load(COMPOSE.read_text());config['services']['frontend']['image']=tag
candidate=SRC/'frontend-compose.candidate.yml';candidate.write_text(yaml.safe_dump(config,allow_unicode=True));print(run(['docker','compose','-f',str(candidate),'config','--quiet']));shutil.copy2(str(candidate),str(COMPOSE))
print('FRONTEND_BACKUP',backup);print('FRONTEND_IMAGE',tag)
