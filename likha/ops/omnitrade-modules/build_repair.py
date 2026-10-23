#!/usr/bin/env python3
"""Build a versioned derived image from the pinned existing warehouse image, no network build."""
import pathlib,subprocess,json,io,tarfile,zipfile,datetime,shutil,sys
ROOT=pathlib.Path('/opt/OmniTradeERP'); SRC=ROOT/'ops/module-repair'; BUILD=SRC/'build';BUILD.mkdir(exist_ok=True)
def run(args,**kw): return subprocess.run(args,check=True,universal_newlines=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,**kw).stdout
info=json.loads(run(['docker','inspect','erp-minimal-warehouse-service']))[0]
raw=subprocess.check_output(['docker','cp','erp-minimal-warehouse-service:/app/warehouse-service.jar','-'])
with tarfile.open(fileobj=io.BytesIO(raw)) as tar: jar=tar.extractfile(tar.getmembers()[0]).read()
lib=BUILD/'lib';lib.mkdir(exist_ok=True);classes=BUILD/'classes';classes.mkdir(exist_ok=True)
with zipfile.ZipFile(io.BytesIO(jar)) as z:
 for n in z.namelist():
  if n.startswith('BOOT-INF/lib/') and n.endswith('.jar'): (lib/pathlib.Path(n).name).write_bytes(z.read(n))
java='/usr/lib/jvm/java-21-alibaba-dragonwell-21.0.11.0.11.10-1.1.al8.x86_64/bin/java'
cmd=[java,'-Xmx192m','-jar',str(BUILD/'ecj-3.37.0.jar'),'-21','-proc:none','-parameters','-encoding','UTF-8','-classpath',':'.join(str(p) for p in lib.glob('*.jar')),'-d',str(classes)]+[str(x) for x in SRC.glob('*.java')]
try: print(run(cmd))
except subprocess.CalledProcessError as e: print(e.stdout);raise
with zipfile.ZipFile(io.BytesIO(jar)) as source,zipfile.ZipFile(str(BUILD/'warehouse-service.jar'),'w',compression=zipfile.ZIP_STORED) as out:
 for item in source.infolist():
  if not item.filename.startswith('BOOT-INF/classes/com/crossborder/erp/warehouse/repair/'):out.writestr(item,source.read(item.filename))
 for path in classes.rglob('*.class'):out.write(str(path),'BOOT-INF/classes/'+str(path.relative_to(classes)))
base='omnitrade-local/warehouse-service:repair-base';print(run(['docker','tag',info['Image'],base]));stamp=datetime.datetime.now().strftime('%Y%m%d-%H%M%S');tag='omnitrade-local/warehouse-service:modules-'+stamp
(BUILD/'Dockerfile').write_text('FROM '+base+'\nCOPY warehouse-service.jar /app/warehouse-service.jar\n')
try: print(run(['docker','build','--network=none','--pull=false','-t',tag,str(BUILD)]))
except subprocess.CalledProcessError as e: print(e.stdout);raise
(SRC/'image-tag.txt').write_text(tag+'\n');print('BUILT',tag)
