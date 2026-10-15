#!/usr/bin/env bash
# 轮询 rm-5ts0ez22t67il9oz3 直至 Running（最多 30 次 x 30s）
case ":${PATH}:" in
  *":/usr/local/bin:"*) ;;
  *) PATH="${PATH}:/usr/local/bin" ;;
esac
ID="rm-5ts0ez22t67il9oz3"
for i in $(seq 1 30); do
  ST=$(aliyun rds DescribeDBInstanceAttribute --region ap-southeast-6 --DBInstanceId ${ID} \
      --cli-query 'Items.DBInstanceAttribute[0].DBInstanceStatus' 2>/dev/null | tr -d '"\r')
  echo "poll ${i}: ${ST}"
  if [ "${ST}" = "Running" ]; then
    echo RUNNING_OK
    exit 0
  fi
  sleep 30
done
echo TIMEOUT_NOT_RUNNING
exit 1
