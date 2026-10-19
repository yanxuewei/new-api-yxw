#!/bin/bash
# bodies/run_perf_sse_800_confirm.sh —— 800 档**重测**（上轮 800 档被额度打断，不能当容量数）
# 上轮：30/100/300/500 无 403，只有 800 档 http_403=10976；diag H1/H2 实测 quota=-826490、
#   单发也 403 insufficient_user_quota ⇒ 夹具额度上限，非容量。topup 已改 quota=1.5e9（≈61.9 万条）。
# 口径：800×60s（与上轮同参可比）+ 前后哨兵各一条；任何 http_403 ⇒ 本轮作废。
# 驱动＝与上版同一个 selectors 非阻塞 SSE 驱动（BlockingIOError 自旋 bug 已修）。
set -uo pipefail
NS=new-api-perf
SEC=perf-load-test-credentials
GWC=$(kubectl -n $NS get svc new-api-perf -o jsonpath='{.spec.clusterIP}' 2>/dev/null | tr -d ' \r')
GWP=$(kubectl -n $NS get svc new-api-perf -o jsonpath='{.spec.ports[0].port}' 2>/dev/null | tr -dc '0-9')
TKKEY=$(kubectl -n $NS get secret $SEC -o jsonpath='{.data.token_key}' | base64 -d)
MOCKC=$(kubectl -n $NS get svc mock-upstream -o jsonpath='{.spec.clusterIP}' 2>/dev/null | tr -d ' \r')
[ -n "$TKKEY" ] && [ "${#TKKEY}" -ge 20 ] || { echo "    [XX] 取不到 token key"; exit 0; }
POD=$(kubectl -n $NS get pod -l track=perf -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
GW="http://${GWC}:${GWP:-80}"
printf '=== K0 网关=%s:%s Pod=%s 档位=800×60s（重测）\n' "$GWC" "${GWP:-80}" "$POD"
ulimit -n 65535 2>/dev/null || true
one() {
  local M O=/tmp/k_$$.b
  M=$(curl -sS -m 25 -N -o "$O" -w 'http=%{http_code} ttfb=%{time_starttransfer}' \
    -H 'Content-Type: application/json' -H "Authorization: Bearer $TKKEY" \
    --data '{"model":"mock-gpt","messages":[{"role":"user","content":"hi"}],"stream":true}' "$GW/v1/chat/completions" 2>&1)
  printf '      %s | %s\n' "$(printf '%s' "$M" | tr -d '\r')" "$(head -c 90 "$O" | tr -d '\n\r')"
  rm -f "$O"
}
echo "=== K0a 跑前哨兵（必须 200；403 就是额度又空了）"; one

PYD=/tmp/perf_driver.$$.py
cat > "$PYD" <<'PY'
import os, socket, selectors, time, sys
HOST=os.environ['PF_HOST']; PORT=int(os.environ['PF_PORT']); KEY=os.environ['PF_KEY']
CONC=int(sys.argv[1]); DUR=float(sys.argv[2])
BODY=b'{"model":"mock-gpt","messages":[{"role":"user","content":"hi"}],"stream":true}'
HDR=('POST /v1/chat/completions HTTP/1.1\r\nHost: %s\r\nAuthorization: Bearer %s\r\n'
     'Content-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n') % (HOST, KEY, len(BODY))
REQ=HDR.encode()+BODY
ADDR=(HOST, PORT)
sel=selectors.DefaultSelector(); end=time.time()+DUR
conns={}; done=[]; errs={}
def bump(k): errs[k]=errs.get(k,0)+1
def drop(s):
    try: sel.unregister(s)
    except Exception: pass
    conns.pop(s,None)
    try: s.close()
    except Exception: pass
def connect():
    try:
        s=socket.socket(); s.setblocking(False)
        e=s.connect_ex(ADDR)
        if e not in (0,115):
            bump('connect_%d'%e); s.close(); return
    except Exception as ex:
        bump('open_'+type(ex).__name__); return
    st={'t0':time.time(),'tf':None,'status':None,'nd':0,'sent':False}
    conns[s]=st
    if e==0:
        try:
            s.sendall(REQ); st['sent']=True; sel.register(s,selectors.EVENT_READ)
        except BlockingIOError:
            sel.register(s,selectors.EVENT_WRITE)
        except Exception as ex:
            bump('send_'+type(ex).__name__); drop(s)
    else:
        sel.register(s,selectors.EVENT_WRITE)
def writable(s,st):
    so=s.getsockopt(socket.SOL_SOCKET, socket.SO_ERROR)
    if so!=0:
        bump('connfail_%d'%so); drop(s); return
    try:
        n=s.send(REQ)
    except BlockingIOError:
        return
    except Exception as ex:
        bump('send_'+type(ex).__name__); drop(s); return
    st['off']=st.get('off',0)+n
    if st['off']>=len(REQ):
        st['sent']=True; sel.modify(s,selectors.EVENT_READ)
while time.time()<end:
    need=CONC-len(conns)
    for _ in range(0 if need<0 else need): connect()
    try:
        events=sel.select(timeout=0.05)
    except Exception as ex:
        bump('select_'+type(ex).__name__); events=[]
    for key,ev in events:
        s=key.fileobj; st=conns.get(s)
        if st is None: continue
        if (ev & selectors.EVENT_WRITE) and not st['sent']:
            writable(s,st); continue
        if not (ev & selectors.EVENT_READ): continue
        try:
            chunk=s.recv(65536)
        except BlockingIOError:
            continue
        except Exception as ex:
            bump('recv_'+type(ex).__name__); drop(s); continue
        now=time.time()
        if not chunk:
            if st['nd']>=3 and st['status']==200:
                done.append((st['tf'] if st['tf'] is not None else now-st['t0'], now-st['t0']))
            else:
                bump('eof_status=%s_nd=%s'%(st['status'],st['nd']))
            drop(s); continue
        if st['status'] is None and chunk[:5]==b'HTTP/':
            try: st['status']=int(chunk.split(b' ',2)[1])
            except Exception: st['status']=0
            if st['status']!=200:
                bump('http_%d'%st['status']); drop(s); continue
        if b'data:' in chunk and st['tf'] is None: st['tf']=now-st['t0']
        st['nd']+=chunk.count(b'data:')
        if b'[DONE]' in chunk:
            done.append((st['tf'] if st['tf'] is not None else now-st['t0'], now-st['t0'])); drop(s)
timedout=len(conns)
for s in list(conns): drop(s)
sel.close()
n=len(done); nerr=sum(errs.values())+timedout; tot=n+nerr
def pct(a,q): return a[min(len(a)-1,int(len(a)*q))]
if done:
    tf=sorted(x[0] for x in done); tt=sorted(x[1] for x in done)
    print('  并发=%d 时长=%.0fs 成功流=%d 错误=%d(超时中留=%d) 错误率=%.2f%% 吞吐=%.1f rps '
          '首字P50=%.0fms P95=%.0fms P99=%.0fms 端到端P50=%.2fs P95=%.2fs' % (
      CONC, DUR, n, nerr, timedout, (100.0*nerr/tot) if tot else 0.0, n/DUR,
      pct(tf,.5)*1000, pct(tf,.95)*1000, pct(tf,.99)*1000, pct(tt,.5), pct(tt,.95)))
    if errs:
        print('  错误分布：' + '  '.join('%s=%d'%(k,v) for k,v in sorted(errs.items(), key=lambda x:-x[1])[:5]))
else:
    print('  并发=%d 成功流=0 错误=%d 分布=%s ⇒ 全失败，先判原因再谈容量' % (CONC,nerr,errs))
if errs.get('http_403',0)>0:
    print('  [X] 本轮出现 http_403=%d ⇒ 额度/鉴权又被吃掉，**本轮数字作废**，不要读成容量' % errs['http_403'])
PY
export PF_HOST="$GWC" PF_PORT="${GWP:-80}" PF_KEY="$TKKEY"
RB=$(kubectl -n $NS get pod "$POD" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null)
TIMEFORMAT='      驱动自身 real=%R user=%U sys=%S（user<real ⇒ 驱动未到单核上限）'
echo "=== K1 档位 800 并发（60s 稳态）"
{ time python3 "$PYD" 800 60 ; } 2>&1 | sed 's/^/    /'
RA=$(kubectl -n $NS get pod "$POD" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null)
printf '    网关 restarts=%s→%s phase=%s 资源=%s\n' "$RB" "$RA" \
  "$(kubectl -n $NS get pod "$POD" -o jsonpath='{.status.phase}' 2>/dev/null)" \
  "$(kubectl -n $NS top pod "$POD" --no-headers 2>/dev/null | tr -s ' ' | cut -d' ' -f2-3)"
printf '    mock计数(单 Pod 采样，非集群合计)=%s\n' "$(curl -sS -m 6 "http://${MOCKC}:80/metrics" 2>/dev/null | grep -E '^mock_' | head -3 | tr '\n' ' ' | cut -c1-110)"
[ "$RB" != "$RA" ] && echo "    [!] 网关在档位内重启 ⇒ 可靠性发现，标红"
echo "=== K2 跑后哨兵 + 收尾"
one
kubectl -n $NS get pod -o custom-columns=N:.metadata.name,R:.status.containerStatuses[0].restartCount,P:.status.phase --no-headers 2>&1 | sed 's/^/      perf /'
kubectl -n newapi-dev get deploy -o custom-columns=N:.metadata.name,R:.status.readyReplicas --no-headers 2>&1 | sed 's/^/      dev邻居 /'
rm -f "$PYD"
echo "--- K0–K2 结束"
exit 0
