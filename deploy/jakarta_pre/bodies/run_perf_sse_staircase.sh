#!/bin/bash
# bodies/run_perf_sse_staircase.sh —— 任务 33 S2 的**降档**压测（裁定 2026-10-19：1500 ⇒ 按实际资源降到 800）
# 先决条件已实测闭合：mock SSE 契约（P1–P4）；网关→渠道→mock HTTP 200/ttfb 345ms/data=52/logs 落库（F3/F4）。
# 本版修掉驱动自己的致命 bug（自曝）：非阻塞 socket 刚 connect_ex 完就 sendall 会抛 BlockingIOError，
#   而上一版用 `while len(conns) < CONC: open_conn()` 补连接 ⇒ 异常路径不登记连接、len(conns) 永远不满，
#   死循环空转（实测 100 并发就挂住，本地 `| tail` 还把输出全缓冲住，看起来像"压测卡死"）。
#   ⇒ 正确做法：connect 后先注册 **EVENT_WRITE**，可写事件里再 sendall；补齐循环改成"每 tick 定量、绝不 while 自旋"。
# 凭据：token key 从 Secret 现取到进程环境，命令体与输出都不含值。
set -uo pipefail
NS=new-api-perf
SEC=perf-load-test-credentials
GWC=$(kubectl -n $NS get svc new-api-perf -o jsonpath='{.spec.clusterIP}' 2>/dev/null | tr -d ' \r')
GWP=$(kubectl -n $NS get svc new-api-perf -o jsonpath='{.spec.ports[0].port}' 2>/dev/null | tr -dc '0-9')
TKKEY=$(kubectl -n $NS get secret $SEC -o jsonpath='{.data.token_key}' | base64 -d)
MOCKC=$(kubectl -n $NS get svc mock-upstream -o jsonpath='{.spec.clusterIP}' 2>/dev/null | tr -d ' \r')
[ -n "$TKKEY" ] && [ "${#TKKEY}" -ge 20 ] || { echo "    [XX] 取不到 token key ⇒ 先跑 wire/fix"; exit 0; }
POD=$(kubectl -n $NS get pod -l track=perf -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
printf '=== G0 网关=%s:%s  Pod=%s  档位=先 30/100 校验，再 300/500/800\n' "$GWC" "${GWP:-80}" "$POD"
ulimit -n 65535 2>/dev/null || true
printf '    fd 上限=%s\n' "$(ulimit -n)"

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
        sel.register(s,selectors.EVENT_WRITE)   # 非阻塞 connect 未完成就 sendall 会抛 BlockingIOError ⇒ 等可写
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
    st.setdefault('off',0); st['off']=st.get('off',0)+n
    if st['off']>=len(REQ):
        st['sent']=True; sel.modify(s,selectors.EVENT_READ)
while time.time()<end:
    need=CONC-len(conns)
    for _ in range(0 if need<0 else need): connect()   # 每 tick 定量补齐，绝不 while 自旋
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
        top=sorted(errs.items(), key=lambda x:-x[1])[:5]
        print('  错误分布：' + '  '.join('%s=%d'%(k,v) for k,v in top))
else:
    print('  并发=%d 时长=%.0fs 成功流=0 错误=%d 分布=%s ⇒ 该档全失败，先看错误分布再判容量' % (CONC,DUR,nerr,errs))
PY

export PF_HOST="$GWC" PF_PORT="${GWP:-80}" PF_KEY="$TKKEY"
TIMEFORMAT='      驱动自身 real=%R user=%U sys=%S（user≈real ⇒ 驱动单核到顶，这档数不能当网关容量）'
for C in 30 100 300 500 800; do
  printf '\n=== G1 档位 %s 并发（60s 稳态）\n' "$C"
  RB=$(kubectl -n $NS get pod "$POD" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null)
  { time python3 "$PYD" "$C" 60 ; } 2>&1 | sed 's/^/    /'
  RA=$(kubectl -n $NS get pod "$POD" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null)
  printf '    网关 restarts=%s→%s phase=%s mock计数=%s\n' "$RB" "$RA" \
    "$(kubectl -n $NS get pod "$POD" -o jsonpath='{.status.phase}' 2>/dev/null)" \
    "$(curl -sS -m 6 "http://${MOCKC}:80/metrics" 2>/dev/null | grep -E '^mock_' | head -3 | tr '\n' ' ' | cut -c1-110)"
  [ "$RB" != "$RA" ] && echo "    [!] 网关在档间重启 ⇒ 容量/健壮性发现，后续判读标红"
  sleep 5
done

echo "=== G2 收尾只读回读"
kubectl -n $NS get pod -o custom-columns=N:.metadata.name,R:.status.containerStatuses[0].restartCount,P:.status.phase --no-headers 2>&1 | sed 's/^/      perf /'
kubectl -n newapi-dev get deploy -o custom-columns=N:.metadata.name,R:.status.readyReplicas --no-headers 2>&1 | sed 's/^/      dev邻居 /'
echo "      （dev 邻居全 Ready ⇒ 共池没被压测打挂；有非 Ready 就是隔离缺口的新证据）"
rm -f "$PYD"
echo "--- G0–G2 结束"
exit 0
