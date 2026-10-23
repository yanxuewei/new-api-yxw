# bodies/install_script.sh —— 把 k6 脚本装成按内容寻址的 ConfigMap
# 依赖 header 注入：K6JS_GZ / K6JS_CM
# 单独下发的原因：压测命令体里再带脚本会超过云助手命令大小上限。
NS=new-api-perf
CM="${K6JS_CM:?缺少 K6JS_CM}"
TMP="/tmp/perf_k6script.$$.js"

[ -n "${K6JS_GZ:-}" ] || { echo "  [XX] 缺少 K6JS_GZ"; exit 2; }
printf '%s' "$K6JS_GZ" | base64 -d | gzip -d > "$TMP" || { rm -f "$TMP"; echo "  [XX] 脚本解码失败"; exit 2; }
[ -s "$TMP" ] || { rm -f "$TMP"; echo "  [XX] 脚本为空"; exit 2; }
kubectl -n $NS create configmap "$CM" --from-file=sse.js="$TMP" --dry-run=client -o yaml \
  | kubectl apply -f - >/dev/null
RC=$?
rm -f "$TMP"
[ "$RC" -eq 0 ] || { echo "  [XX] ConfigMap $CM 写入失败"; exit 2; }
echo "  configmap/$CM 就绪"
