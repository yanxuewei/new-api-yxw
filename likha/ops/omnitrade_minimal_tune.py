#!/usr/bin/env python3
"""Inspect and tune the existing OmniTradeERP minimal stack without deleting data."""
import datetime
import io
import json
import pathlib
import re
import shutil
import subprocess
import sys
import tarfile
import urllib.request
import zipfile
import yaml

ROOT = pathlib.Path('/opt/OmniTradeERP')
COMPOSE = ROOT / 'docker-compose.minimal.yml'
SERVICES = ['mysql', 'redis', 'nacos', 'user-service', 'product-service', 'order-service', 'gateway']

def run(args, **kwargs):
    return subprocess.run(args, check=True, universal_newlines=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, **kwargs).stdout

def inspect(service):
    return json.loads(run(['docker', 'inspect', 'erp-minimal-' + service]))[0]

def audit():
    for service in SERVICES:
        info = inspect(service)
        print(service, json.dumps({'restarts': info['RestartCount'], 'oom': info['State']['OOMKilled'], 'limits': info['HostConfig']['Memory'], 'image': info['Config']['Image'], 'mounts': [(x['Type'], x.get('Name'), x['Destination']) for x in info['Mounts']], 'health': info['State'].get('Health', {}).get('Status')}, ensure_ascii=False))
        if service in ['gateway', 'user-service', 'product-service', 'order-service']:
            stream = subprocess.check_output(['docker', 'cp', 'erp-minimal-' + service + ':/app/' + service + '.jar', '-'])
            with tarfile.open(fileobj=io.BytesIO(stream)) as archive:
                jar = archive.extractfile(archive.getmembers()[0]).read()
            with zipfile.ZipFile(io.BytesIO(jar)) as archive:
                print('JAR', service, [x for x in archive.namelist() if any(t in x for t in ['mysql-connector', 'actuator', 'amqp', 'rabbit'])])
                print('APPLICATION', archive.read('BOOT-INF/classes/application.yml').decode())
    print('NACOS_NAMESPACES', urllib.request.urlopen('http://127.0.0.1:8848/nacos/v1/console/namespaces', timeout=10).read().decode())
    info = inspect('mysql')
    password = next(x.split('=', 1)[1] for x in info['Config']['Env'] if x.startswith('MYSQL_ROOT_PASSWORD='))
    print('DATABASES', run(['docker', 'exec', '-e', 'MYSQL_PWD=' + password, 'erp-minimal-mysql', 'mysql', '-uroot', '-N', '-e', 'SELECT TABLE_SCHEMA,COUNT(*) FROM information_schema.tables GROUP BY TABLE_SCHEMA;']))
    print('NACOS_COMMAND', run(['docker', 'exec', 'erp-minimal-nacos', 'ps', '-eo', 'args']))

def prepare():
    original = COMPOSE.read_text()
    config = yaml.safe_load(original)
    stamp = datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
    backup = ROOT / '.ops-backups' / ('minimal-' + stamp)
    backup.mkdir(parents=True, mode=0o700)
    shutil.copy2(str(COMPOSE), str(backup / COMPOSE.name))
    for service in SERVICES:
        info = inspect(service)
        (backup / (service + '-inspect.json')).write_text(json.dumps(info, indent=2))
    mysql_info = inspect('mysql')
    password = next(x.split('=', 1)[1] for x in mysql_info['Config']['Env'] if x.startswith('MYSQL_ROOT_PASSWORD='))
    with (backup / 'mysql-all.sql').open('w') as out:
        subprocess.run(['docker', 'exec', '-e', 'MYSQL_PWD=' + password, 'erp-minimal-mysql', 'mysqldump', '-uroot', '--single-transaction', '--routines', '--events', '--all-databases', '--set-gtid-purged=OFF'], stdout=out, check=True)
    if (backup / 'mysql-all.sql').stat().st_size < 1000:
        raise RuntimeError('Database backup is unexpectedly small')
    with (backup / 'nacos-data.tar').open('wb') as out:
        subprocess.run(['docker', 'cp', 'erp-minimal-nacos:/home/nacos/data', '-'], stdout=out, check=True)
    config.pop('version', None)
    limits = {'mysql':448, 'redis':128, 'nacos':512, 'gateway':320, 'user-service':384, 'product-service':384, 'order-service':384}
    for service, spec in config['services'].items():
        spec['mem_limit'] = str(limits[service]) + 'm'
        spec['memswap_limit'] = str(limits[service] + 64) + 'm'
        spec['cpus'] = 1.0 if service != 'redis' else 0.25
        spec['pids_limit'] = 256
        spec['restart'] = 'unless-stopped'
        spec['stop_grace_period'] = '45s'
        spec['logging'] = {'driver': 'json-file', 'options': {'max-size':'10m', 'max-file':'3'}}
        spec['healthcheck'].update({'interval':'30s', 'timeout':'5s', 'start_period':'90s', 'retries':5})
    config['services']['mysql']['command'] = ['--innodb-buffer-pool-size=128M', '--performance-schema=OFF', '--max-connections=60', '--table-open-cache=256', '--table-definition-cache=256', '--thread-cache-size=8', '--tmp-table-size=16M', '--max-heap-table-size=16M', '--temptable-max-ram=32M']
    config['services']['redis']['command'] = ['redis-server', '--maxmemory', '64mb', '--maxmemory-policy', 'noeviction']
    config['services']['nacos']['environment'].update({'JVM_XMS':'128m', 'JVM_XMX':'256m', 'JVM_XMN':'64m', 'JAVA_OPT':'-XX:ActiveProcessorCount=1 -XX:MaxMetaspaceSize=128m -XX:ReservedCodeCacheSize=48m -XX:MaxDirectMemorySize=32m -Xss512k'})
    ports = {'gateway':8080, 'user-service':8081, 'product-service':8082, 'order-service':8083}
    for service, port in ports.items():
        spec = config['services'][service]
        info = inspect(service)
        tag = 'omnitrade-local/' + service + ':minimal-' + stamp
        run(['docker', 'tag', info['Image'], tag])
        spec.pop('build', None)
        spec['image'] = tag
        spec['pull_policy'] = 'never'
        spec['init'] = True
        env = spec['environment']
        heap = 160 if service == 'gateway' else 192
        env.update({'JAVA_OPTS':'-Xms64m -Xmx%dm -XX:MaxMetaspaceSize=128m -XX:ReservedCodeCacheSize=48m -XX:MaxDirectMemorySize=32m -Xss512k -XX:+UseSerialGC -XX:ActiveProcessorCount=1 -XX:+ExitOnOutOfMemoryError' % heap,
                    'SERVER_PORT':str(port), 'NACOS_HOST':'nacos', 'NACOS_PORT':'8848',
                    'SPRING_CLOUD_NACOS_DISCOVERY_SERVER_ADDR':'nacos:8848', 'SPRING_CLOUD_NACOS_CONFIG_SERVER_ADDR':'nacos:8848',
                    'SPRING_CLOUD_NACOS_DISCOVERY_NAMESPACE':'erp-dev', 'SPRING_CLOUD_NACOS_CONFIG_NAMESPACE':'erp-dev',
                    'SPRING_DATA_REDIS_HOST':'redis', 'SPRING_DATA_REDIS_PORT':'6379',
                    'SPRING_DATASOURCE_HIKARI_MINIMUM_IDLE':'1', 'SPRING_DATASOURCE_HIKARI_MAXIMUM_POOL_SIZE':'5',
                    'SERVER_TOMCAT_THREADS_MAX':'20', 'SERVER_TOMCAT_THREADS_MIN_SPARE':'2',
                    'MANAGEMENT_ENDPOINTS_WEB_EXPOSURE_INCLUDE':'health,info', 'MANAGEMENT_ENDPOINT_HEALTH_SHOW_DETAILS':'never',
                    'LOGGING_LEVEL_COM_CROSSBORDER_ERP':'INFO', 'LOGGING_LEVEL_ORG_SPRINGFRAMEWORK_CLOUD_LOADBALANCER':'INFO'})
        if service != 'gateway':
            database = 'erp_' + service.split('-')[0]
            env.update({'SPRING_DATASOURCE_URL':'jdbc:mysql://mysql:3306/' + database + '?useUnicode=true&characterEncoding=utf8&serverTimezone=Asia/Shanghai&useSSL=false&allowPublicKeyRetrieval=true', 'SPRING_DATASOURCE_USERNAME':'root', 'SPRING_DATASOURCE_PASSWORD':password})
        if service == 'user-service':
            spec['healthcheck']['test'] = ['CMD-SHELL', 'nc -z -w 3 127.0.0.1 8081']
        else:
            spec['healthcheck']['test'] = ['CMD', 'wget', '-q', '-T', '4', '-O', '/dev/null', 'http://127.0.0.1:%d/actuator/health' % port]
    candidate = ROOT / 'docker-compose.minimal.candidate.yml'
    candidate.write_text(yaml.safe_dump(config, default_flow_style=False, allow_unicode=True))
    run(['docker', 'compose', '-f', str(candidate), 'config', '--quiet'])
    candidate.replace(COMPOSE)
    rollback = '#!/bin/sh\nset -eu\ncd /opt/OmniTradeERP\ncp ' + str(backup / COMPOSE.name) + ' docker-compose.minimal.yml\ndocker compose -f docker-compose.minimal.yml up -d --no-build\n'
    (backup / 'rollback.sh').write_text(rollback)
    (backup / 'rollback.sh').chmod(0o700)
    print('BACKUP=' + str(backup))
    print('MYSQL_BACKUP_BYTES=' + str((backup / 'mysql-all.sql').stat().st_size))
    print('MEMORY_LIMIT_TOTAL_MIB=' + str(sum(limits.values())))
    print('COMPOSE_VALIDATED=true')

if __name__ == '__main__':
    if sys.argv[1] == 'audit':
        audit()
    elif sys.argv[1] == 'prepare':
        prepare()
    elif sys.argv[1] == 'dependencies':
        for directory in ['erp-order-service', 'erp-user-service', 'erp-product-service']:
            for path in (ROOT / directory / 'src').rglob('*.java'):
                lines = path.read_text().splitlines()
                for n, line in enumerate(lines, 1):
                    if re.search(r'Rabbit|Elasticsearch|ElasticSearch|@.*Mapping|FeignClient', line):
                        print(str(path.relative_to(ROOT)) + ':' + str(n) + ':' + line.strip())
    elif sys.argv[1] == 'add-extra':
        import copy
        config = yaml.safe_load(COMPOSE.read_text())
        stamp = datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
        backup = ROOT/'.ops-backups'/('extra-'+stamp)
        backup.mkdir(mode=0o700)
        shutil.copy2(str(COMPOSE),str(backup/COMPOSE.name))
        password = config['services']['mysql']['environment']['MYSQL_ROOT_PASSWORD']
        with (backup/'mysql-all.sql').open('w') as out:
            subprocess.run(['docker','exec','-e','MYSQL_PWD='+password,'erp-minimal-mysql','mysqldump','-uroot','--single-transaction','--routines','--events','--all-databases','--set-gtid-purged=OFF'],stdout=out,check=True)
        assert (backup/'mysql-all.sql').stat().st_size > 1000
        for service,port,limit,heap in [('customer-service',8087,256,112),('supplier-service',8088,256,112),('warehouse-service',8085,320,144)]:
            assert service not in config['services'], 'Already configured: '+service
            spec = copy.deepcopy(config['services']['product-service'])
            tag = 'omnitrade-local/'+service+':minimal-'+stamp
            run(['docker','tag','omnitradeerp-'+service,tag])
            spec.update({'image':tag,'container_name':'erp-minimal-'+service,'ports':['127.0.0.1:%d:%d'%(port,port)],'mem_limit':str(limit)+'m','memswap_limit':str(limit+64)+'m','cpus':0.75,'pids_limit':160})
            env = spec['environment']
            env.update({'SERVER_PORT':str(port),'JAVA_OPTS':'-Xms32m -Xmx%dm -XX:MaxMetaspaceSize=96m -XX:ReservedCodeCacheSize=32m -XX:MaxDirectMemorySize=16m -Xss512k -XX:+UseSerialGC -XX:ActiveProcessorCount=1 -XX:+ExitOnOutOfMemoryError'%heap,'SPRING_DATASOURCE_URL':'jdbc:mysql://mysql:3306/erp_'+service.split('-')[0]+'?useUnicode=true&characterEncoding=utf8&serverTimezone=Asia/Shanghai&useSSL=false&allowPublicKeyRetrieval=true','SPRING_DATASOURCE_HIKARI_MINIMUM_IDLE':'0','SPRING_DATASOURCE_HIKARI_MAXIMUM_POOL_SIZE':'3','SERVER_TOMCAT_THREADS_MAX':'10','SERVER_TOMCAT_THREADS_MIN_SPARE':'1'})
            spec['healthcheck']['test']=['CMD','wget','-q','-T','4','-O','/dev/null','http://127.0.0.1:%d/actuator/health'%port]
            config['services'][service]=spec
        stream=subprocess.check_output(['docker','cp','erp-minimal-gateway:/app/gateway.jar','-'])
        with tarfile.open(fileobj=io.BytesIO(stream)) as archive:
            jar=archive.extractfile(archive.getmembers()[0]).read()
        with zipfile.ZipFile(io.BytesIO(jar)) as archive:
            app=yaml.safe_load(archive.read('BOOT-INF/classes/application.yml').decode())
        routes=app['spring']['cloud']['gateway']['routes']
        for route in routes:
            if route['id'] in ['customer-service','supplier-service']:
                port=8087 if route['id']=='customer-service' else 8088
                route['uri']='http://%s:%d'%(route['id'],port)
        config['services']['gateway']['environment']['SPRING_APPLICATION_JSON']=json.dumps({'spring':{'cloud':{'gateway':{'routes':routes}}}})
        sql='CREATE DATABASE IF NOT EXISTS erp_customer CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci; CREATE DATABASE IF NOT EXISTS erp_supplier CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;'
        run(['docker','exec','-e','MYSQL_PWD='+password,'erp-minimal-mysql','mysql','-uroot','-e',sql])
        candidate=ROOT/'docker-compose.minimal.candidate.yml'
        candidate.write_text(yaml.safe_dump(config,default_flow_style=False))
        run(['docker','compose','-f',str(candidate),'config','--quiet'])
        candidate.replace(COMPOSE)
        (backup/'rollback.sh').write_text('#!/bin/sh\nset -eu\ncd /opt/OmniTradeERP\ndocker compose -f docker-compose.minimal.yml stop customer-service supplier-service warehouse-service\ncp '+str(backup/COMPOSE.name)+' docker-compose.minimal.yml\ndocker compose -f docker-compose.minimal.yml up -d --no-build --wait gateway\n')
        (backup/'rollback.sh').chmod(0o700)
        print('BACKUP='+str(backup))
        print('Added three services; total container limits 3424 MiB, not a guaranteed simultaneous peak capacity.')
    elif sys.argv[1] == 'smoke-extra':
        import concurrent.futures
        import time
        paths=['/api/customer/list','/api/customer/stats','/api/customer/tag/list','/api/customer/group/list','/api/customer/follow/list','/api/supplier/list','/api/supplier/stats','/api/supplier/evaluation/list','/api/supplier/purchase/list','/api/supplier/purchase/stats','/api/product/list','/api/order/list']
        def request(path):
            start=time.monotonic()
            try:
                with urllib.request.urlopen('http://127.0.0.1:8080'+path,timeout=15) as response:
                    json.loads(response.read())
                    return path,response.status,round((time.monotonic()-start)*1000,2)
            except urllib.error.HTTPError as exc:
                return path,exc.code,exc.read().decode()[:100]
        for path in paths:
            print('ENDPOINT',request(path))
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            results=list(pool.map(request,[paths[i%len(paths)] for i in range(60)]))
        good=[x for x in results if x[1]==200]
        print('SMOKE',json.dumps({'requests':len(results),'concurrency':2,'passed':len(good),'p95_ms':sorted(x[2] for x in good)[int(len(good)*.95)-1] if good else None}))
        print('WAREHOUSE_REGISTRY',urllib.request.urlopen('http://127.0.0.1:8848/nacos/v1/ns/instance/list?namespaceId=erp-dev&serviceName=erp-warehouse-service',timeout=10).read().decode())
    elif sys.argv[1] == 'schema-extra':
        statements=['-- Additive bootstrap derived from the deployed customer/supplier entity fields. No DROP/ALTER/data inserts.']
        for service in ['customer','supplier']:
            statements.append('USE `erp_'+service+'`;')
            for path in sorted((ROOT/('erp-'+service+'-service')/'src').rglob('entity/*.java')):
                text=path.read_text()
                table=re.search(r'@TableName\("([a-z_]+)"\)',text).group(1)
                fields=[]
                for field_type,name in re.findall(r'private\s+(Long|String|Integer|BigDecimal|LocalDateTime)\s+(\w+)\s*;',text):
                    column=re.sub(r'(?<!^)(?=[A-Z])','_',name).lower()
                    sql_type={'Long':'BIGINT','String':'VARCHAR(500)','Integer':'INT','BigDecimal':'DECIMAL(20,4)','LocalDateTime':'DATETIME'}[field_type]
                    if name in ['content','remark','description','advantages','improvements']:
                        sql_type='TEXT'
                    if name=='id':
                        suffix=' NOT NULL PRIMARY KEY'
                    elif name=='createTime':
                        suffix=' DEFAULT CURRENT_TIMESTAMP'
                    elif name=='updateTime':
                        suffix=' DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP'
                    else:
                        suffix=' NULL'
                    fields.append('  `'+column+'` '+sql_type+suffix)
                assert fields
                statements.append('CREATE TABLE IF NOT EXISTS `'+table+'` (\n'+',\n'.join(fields)+'\n) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;')
        sql='\n\n'.join(statements)+'\n'
        path=ROOT/'.ops-backups'/'extra-20261023-165012'/'customer-supplier-bootstrap.sql'
        path.write_text(sql)
        print(sql)
        config=yaml.safe_load(COMPOSE.read_text())
        password=config['services']['mysql']['environment']['MYSQL_ROOT_PASSWORD']
        run(['docker','exec','-i','-e','MYSQL_PWD='+password,'erp-minimal-mysql','mysql','-uroot'],input=sql)
        print('Applied additive bootstrap; existing tables/data untouched. String/decimal widths are deployment defaults, not an upstream migration.')
    elif sys.argv[1] == 'extra-errors':
        for service in ['customer-service','supplier-service','warehouse-service']:
            proc=subprocess.run(['docker','logs','--tail','250','erp-minimal-'+service],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,universal_newlines=True)
            print('LOG',service)
            for line in proc.stdout.splitlines():
                if re.search(r'ERROR|Caused by|doesn.t exist|SQL:|Started |OutOfMemory',line):
                    print(line[:1200])
        for directory in ['erp-customer-service','erp-supplier-service']:
            for path in (ROOT/directory/'src').rglob('*.java'):
                if 'controller' in str(path):
                    print('CONTROLLER',str(path.relative_to(ROOT)))
                    lines=path.read_text().splitlines()
                    for n,line in enumerate(lines):
                        if '@GetMapping' in line:
                            print('\n'.join(lines[n:n+10]))
    elif sys.argv[1] == 'verify-extra':
        for service in ['customer-service','supplier-service','warehouse-service']:
            info=inspect(service)
            print('STATE',service,info['State']['Status'],info['State'].get('Health',{}).get('Status'),'restarts',info['RestartCount'],'oom',info['State']['OOMKilled'])
        for path in ['/api/customer/list','/api/supplier/list','/api/warehouse/list','/api/product/list','/api/order/list']:
            try:
                response=urllib.request.urlopen('http://127.0.0.1:8080'+path,timeout=15)
                print('HTTP',path,response.status,response.read().decode()[:500])
            except urllib.error.HTTPError as exc:
                print('HTTP',path,exc.code,exc.read().decode()[:500])
        print(run(['docker','stats','--no-stream','--format','json']))
        print(run(['free','-m']))
        password=yaml.safe_load(COMPOSE.read_text())['services']['mysql']['environment']['MYSQL_ROOT_PASSWORD']
        print(run(['docker','exec','-e','MYSQL_PWD='+password,'erp-minimal-mysql','mysql','-uroot','-N','-e','SELECT TABLE_SCHEMA,TABLE_NAME FROM information_schema.tables WHERE TABLE_SCHEMA IN (\"erp_customer\",\"erp_supplier\",\"erp_warehouse\");']))
    elif sys.argv[1] == 'extra-source':
        for service in ['customer','supplier','warehouse']:
            root = ROOT/('erp-'+service+'-service')
            print('POM',service,(root/'pom.xml').read_text())
            for path in (root/'src').rglob('*.java'):
                if 'controller' in str(path) or 'Application' in path.name:
                    print('SOURCE',str(path.relative_to(ROOT)),path.read_text())
        for path in ROOT.glob('*.py'):
            text = path.read_text(errors='replace')
            if 'CREATE TABLE' in text or 'wms_warehouse' in text:
                print('SCHEMA_SCRIPT',path.name,text[:12000])
    elif sys.argv[1] == 'audit-extra':
        for service in ['customer-service','supplier-service','warehouse-service']:
            name = 'erp-audit-' + service
            run(['docker','create','--name',name,'omnitradeerp-'+service])
            try:
                stream = subprocess.check_output(['docker','cp',name+':/app/'+service+'.jar','-'])
                with tarfile.open(fileobj=io.BytesIO(stream)) as archive:
                    jar = archive.extractfile(archive.getmembers()[0]).read()
                with zipfile.ZipFile(io.BytesIO(jar)) as archive:
                    print('IMAGE',service)
                    print('LIBS',[x for x in archive.namelist() if any(t in x for t in ['mysql-connector','actuator','spring-boot-','nacos','mybatis'])])
                    print('MANIFEST',archive.read('META-INF/MANIFEST.MF').decode())
                    print('CONTROLLERS',[x for x in archive.namelist() if x.startswith('BOOT-INF/classes/') and ('Controller' in x or x.endswith('.sql'))])
                    print('APP',archive.read('BOOT-INF/classes/application.yml').decode())
            finally:
                run(['docker','rm',name])
            for path in (ROOT/('erp-'+service)/'src').rglob('*.java'):
                if path.parent.name == 'controller':
                    print('SOURCE',str(path.relative_to(ROOT)), '\n'.join(line.strip() for line in path.read_text().splitlines() if re.search(r'@.*Mapping|@Table|private |public .*class',line)))
        print('SQL_FILES',[str(x.relative_to(ROOT)) for x in ROOT.rglob('*.sql') if '.ops-backups' not in str(x) and '.git' not in str(x)])
    elif sys.argv[1] == 'smoke':
        import concurrent.futures
        import time
        def request(index):
            path = ['/api/product/list','/api/order/list'][index % 2]
            start = time.monotonic()
            with urllib.request.urlopen('http://127.0.0.1:8080' + path,timeout=15) as response:
                body = json.loads(response.read())
                return response.status == 200 and body.get('code') == 200, (time.monotonic()-start)*1000
        start = time.monotonic()
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            results = list(pool.map(request,range(100)))
        times = sorted(x[1] for x in results)
        print(json.dumps({'requests':100,'concurrency':4,'passed':sum(x[0] for x in results),'elapsed_seconds':round(time.monotonic()-start,2),'p50_ms':round(times[49],2),'p95_ms':round(times[94],2),'max_ms':round(times[-1],2)}))
    elif sys.argv[1] == 'frontend-network':
        config = yaml.safe_load(COMPOSE.read_text())
        config['services']['gateway']['networks'] = {'erp-minimal-network':{'aliases':['erp-gateway']}}
        config['services']['frontend']['depends_on'] = {'gateway':{'condition':'service_healthy'}}
        candidate = ROOT / 'docker-compose.minimal.candidate.yml'
        candidate.write_text(yaml.safe_dump(config, default_flow_style=False))
        run(['docker','compose','-f',str(candidate),'config','--quiet'])
        candidate.replace(COMPOSE)
        print('Added legacy frontend upstream alias erp-gateway and startup dependency')
    elif sys.argv[1] == 'verify':
        for service in SERVICES + ['frontend']:
            info = inspect(service)
            print('STATE', service, json.dumps({'status':info['State']['Status'], 'health':info['State'].get('Health',{}).get('Status'), 'restarts':info['RestartCount'], 'oom':info['State']['OOMKilled'], 'memory_mib':info['HostConfig']['Memory']//1048576, 'cpus':info['HostConfig']['NanoCpus']/1e9}))
        print(run(['docker','stats','--no-stream','--format','json']))
        print(run(['free','-m']))
        print(run(['uptime']))
        for port, path in [(8080,'/actuator/health'),(8082,'/actuator/health'),(8083,'/actuator/health'),(8082,'/product/list'),(8083,'/order/list'),(8080,'/api/product/list'),(8080,'/api/order/list'),(3000,'/')]:
            try:
                response = urllib.request.urlopen('http://127.0.0.1:%d%s' % (port,path),timeout=15)
                body = response.read().decode()
                print('HTTP',port,path,response.status,body[:300])
            except urllib.error.HTTPError as exc:
                print('HTTP',port,path,exc.code,exc.read().decode()[:300])
        url = 'http://127.0.0.1:8848/nacos/v1/ns/instance/list?namespaceId=erp-dev&serviceName='
        for name in ['erp-gateway','erp-user-service','erp-product-service','erp-order-service']:
            print('REGISTRY',name,urllib.request.urlopen(url+name,timeout=10).read().decode())
        info = inspect('mysql')
        password = next(x.split('=',1)[1] for x in info['Config']['Env'] if x.startswith('MYSQL_ROOT_PASSWORD='))
        query = 'SELECT COUNT(*) AS users FROM erp_user.t_user; SELECT COUNT(*) AS orders FROM erp_order.t_order; SELECT COUNT(*) AS products FROM erp_product.t_product; SHOW VARIABLES WHERE Variable_name IN (\"innodb_buffer_pool_size\",\"max_connections\",\"performance_schema\");'
        print('MYSQL',run(['docker','exec','-e','MYSQL_PWD='+password,'erp-minimal-mysql','mysql','-uroot','-e',query]))
    elif sys.argv[1] == 'minimal-dependencies':
        config = yaml.safe_load(COMPOSE.read_text())
        backup = ROOT / '.ops-backups' / 'minimal-20261023-162832'
        shutil.copy2(str(COMPOSE), str(backup / 'before-optional-dependencies.yml'))
        env = config['services']['order-service']['environment']
        env.update({'MANAGEMENT_HEALTH_RABBIT_ENABLED':'false', 'MANAGEMENT_HEALTH_ELASTICSEARCH_ENABLED':'false', 'SPRING_RABBITMQ_LISTENER_SIMPLE_AUTO_STARTUP':'false', 'SPRING_RABBITMQ_LISTENER_DIRECT_AUTO_STARTUP':'false'})
        candidate = ROOT / 'docker-compose.minimal.candidate.yml'
        candidate.write_text(yaml.safe_dump(config, default_flow_style=False))
        run(['docker','compose','-f',str(candidate),'config','--quiet'])
        candidate.replace(COMPOSE)
        print('Minimal mode: RabbitMQ/Elasticsearch not deployed or used by current order source; only their probes/listeners disabled, DB/Redis health retained.')
    elif sys.argv[1] == 'frontend':
        config = yaml.safe_load(COMPOSE.read_text())
        backup = ROOT / '.ops-backups' / 'minimal-20261023-162832'
        shutil.copy2(str(COMPOSE), str(backup / 'before-frontend.yml'))
        config['services']['frontend'] = {
            'image':'omnitradeerp-frontend:latest', 'pull_policy':'never',
            'container_name':'erp-minimal-frontend', 'restart':'unless-stopped',
            'ports':['127.0.0.1:3000:80'], 'networks':['erp-minimal-network'],
            'mem_limit':'32m', 'memswap_limit':'32m', 'cpus':0.25, 'pids_limit':32,
            'environment':{'NGINX_WORKER_PROCESSES':'1'},
            'logging':{'driver':'json-file','options':{'max-size':'10m','max-file':'3'}},
            'healthcheck':{'test':['CMD','wget','-q','-O','/dev/null','http://127.0.0.1/'], 'interval':'30s','timeout':'5s','retries':3}}
        candidate = ROOT / 'docker-compose.minimal.candidate.yml'
        candidate.write_text(yaml.safe_dump(config, default_flow_style=False))
        run(['docker','compose','-f',str(candidate),'config','--quiet'])
        candidate.replace(COMPOSE)
        print('Frontend added; total memory budget 2592 MiB')
    elif sys.argv[1] == 'namespace':
        url = 'http://127.0.0.1:8848/nacos/v1/console/namespaces'
        result = json.loads(urllib.request.urlopen(url, timeout=10).read())
        if result['code'] != 200:
            raise RuntimeError(str(result))
        if not any(x['namespace'] == 'erp-dev' for x in result['data']):
            request = urllib.request.Request(url, data=b'customNamespaceId=erp-dev&namespaceName=erp-dev&namespaceDesc=minimal')
            print('CREATE_NAMESPACE', urllib.request.urlopen(request, timeout=10).read().decode())
        print(urllib.request.urlopen(url, timeout=10).read().decode())
