import pathlib,subprocess,yaml,datetime,shutil,json
ROOT=pathlib.Path('/opt/OmniTradeERP');SRC=ROOT/'ops/module-repair';COMPOSE=ROOT/'docker-compose.minimal.yml'
backup=ROOT/'.ops-backups'/('final-modules-'+datetime.datetime.now().strftime('%Y%m%d-%H%M%S'));backup.mkdir(mode=0o700);shutil.copy2(str(COMPOSE),str(backup/COMPOSE.name))
c=yaml.safe_load(COMPOSE.read_text());c['services']['gateway']['environment']['SPRING_CLOUD_GATEWAY_DISCOVERY_LOCATOR_ENABLED']='false';c['services']['user-service']['ports']=['127.0.0.1:8081:8081'];c['services']['user-service']['environment']['MANAGEMENT_ENDPOINTS_WEB_EXPOSURE_INCLUDE']='health'
COMPOSE.write_text(yaml.safe_dump(c,allow_unicode=True));subprocess.run(['docker','compose','-f',str(COMPOSE),'config','--quiet'],check=True)
# Retain source changes beside production project so the repair is not image-only.
dest=ROOT/'erp-warehouse-service/src/main/java/com/crossborder/erp/warehouse/repair';dest.mkdir(parents=True,exist_ok=True)
for p in SRC.glob('*.java'):
 if p.name!='PasswordHash.java':shutil.copy2(str(p),str(dest/p.name))
rollback=SRC/'rollback-modules.sh';rollback.write_text('#!/usr/bin/env bash\nset -euo pipefail\ncd /opt/OmniTradeERP\ncp .ops-backups/modules-20261023-174435/docker-compose.minimal.yml docker-compose.minimal.yml\ndocker compose -f docker-compose.minimal.yml config --quiet\ndocker compose -f docker-compose.minimal.yml up -d --no-build --wait --wait-timeout 180 user-service warehouse-service gateway frontend\n# Additive database tables and administrator are retained. No data is deleted.\n');rollback.chmod(0o700)
print('FINAL_CONFIG_BACKUP',backup)
