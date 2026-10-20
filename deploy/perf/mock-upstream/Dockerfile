# mock-upstream 镜像（任务 33 压测用）
# 二进制在本机交叉编译（CGO_ENABLED=0 GOOS=linux GOARCH=amd64），镜像只做搬运：
#   CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags="-s -w" -o mock-upstream .
#   docker build -t acr-newapi-mnl-registry.ap-southeast-6.cr.aliyuncs.com/newapi-dev/mock-upstream:<tag> .
FROM alpine:3.20
RUN adduser -D -u 10001 mock
COPY mock-upstream /usr/local/bin/mock-upstream
USER 10001
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/mock-upstream"]
