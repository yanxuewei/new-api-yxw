import pathlib,json,urllib.request,urllib.error,sys,hashlib,subprocess,re
SRC=pathlib.Path('/opt/OmniTradeERP/ops/module-repair')
BASE='https://workflow-erp.likha.hk'
def request(path,method='GET',body=None,token=None,expected=200):
    headers={'Content-Type':'application/json'}
    if token: headers['Authorization']='Bearer '+token
    req=urllib.request.Request(BASE+path,headers=headers,method=method,data=None if body is None else json.dumps(body).encode())
    try:
        with urllib.request.urlopen(req,timeout=20) as res: code=res.status; raw=res.read()
    except urllib.error.HTTPError as error: code=error.code; raw=error.read()
    assert code==expected, '%s %s HTTP %s expected %s'%(method,path,code,expected)
    print('PASS',method,path,code)
    return json.loads(raw) if raw else None
if '--assets' in sys.argv:
    dist=SRC/'frontend-logout-20261023/dist'
    for relative in ['index.html']+[str(p.relative_to(dist)) for p in (dist/'assets').glob('*.js') if '/api/auth/logout' in p.read_text()]:
        with urllib.request.urlopen(BASE+'/'+relative,timeout=20) as response:
            raw=response.read(); assert response.status==200
        assert hashlib.sha256(raw).digest()==hashlib.sha256((dist/relative).read_bytes()).digest(), relative+' content mismatch'
        print('PASS_PUBLISHED_ASSET',relative)
    assert any('/api/auth/logout' in p.read_text() for p in (dist/'assets').glob('*.js'))
    info=json.loads(subprocess.check_output(['docker','inspect','erp-minimal-frontend']).decode())[0]
    assert info['State']['Health']['Status']=='healthy'
    assert info['RestartCount']==0 and not info['State']['OOMKilled']
    print('PASS_CONTAINER',info['Config']['Image'],'healthy restart=0 oom=false')
    print('ASSET_ACCEPTANCE_OK; authenticated logout test remains separate')
    sys.exit(0)
creds=json.loads((SRC/'erpadmin.credentials').read_text())
login=request('/api/auth/login','POST',creds)
assert login['code']==200
access=login['data']['token']
try:
    request('/api/user/list',token=access)
    result=request('/api/auth/logout','POST',token=access)
    assert result['code']==200, 'Logout business status is not success'
    request('/api/user/list',token=access,expected=401)
    request('/api/inventory/list',token=access,expected=401)
    request('/api/auth/refresh','POST',{},token=access,expected=401)
    request('/api/user/list',expected=401)
    print('LOGOUT_HTTPS_ACCEPTANCE_OK')
finally:
    # Do not leave the verification login active even if a test fails.
    request('/api/auth/logout','POST',token=access)
