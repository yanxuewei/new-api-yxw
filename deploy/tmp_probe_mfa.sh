#!/bin/bash
for u in xiangdong dev-xiangdong yxw; do
  echo "== $u MFA:"
  aliyun ram GetUserMFAInfo --UserName "$u" 2>&1 | tr -d '\r' | head -c 200
  echo
done
