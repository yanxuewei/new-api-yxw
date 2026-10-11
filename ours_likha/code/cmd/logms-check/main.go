// 毫秒定制本地自检：直接调用被改动的三条日志路径，断言输出带 .mmm
// 临时文件（不入库）：go run ./deploy/logs/msprobe
package main

import (
	"bytes"
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"regexp"

	"github.com/QuantumNous/new-api/common"
	"github.com/QuantumNous/new-api/logger"
	"github.com/QuantumNous/new-api/middleware"

	"github.com/gin-gonic/gin"
)

func main() {
	gin.SetMode(gin.ReleaseMode)

	// 把所有日志重定向到内存 buffer，便于机械断言
	var buf bytes.Buffer
	gin.DefaultWriter = &buf
	gin.DefaultErrorWriter = &buf

	// --- 1. common.SysLog / SysError / FatalLog（不触发 FatalLog，会 os.Exit） ---
	common.SysLog("ms-probe: sys log line")
	common.SysError("ms-probe: sys error line")

	// --- 2. logger.LogInfo / LogWarn / LogError ---
	logger.LogInfo(context.Background(), "ms-probe: info line")
	logger.LogWarn(context.Background(), "ms-probe: warn line")
	logger.LogError(context.Background(), "ms-probe: err line")

	// --- 3. GIN 访问日志（middleware.SetUpLogger 真实 formatter 路径） ---
	r := gin.New()
	middleware.SetUpLogger(r)
	r.GET("/probe", func(c *gin.Context) { c.String(http.StatusOK, "ok") })
	srv := httptest.NewServer(r)
	resp, err := http.Get(srv.URL + "/probe")
	if err != nil {
		fmt.Println("http err:", err)
	} else {
		_ = resp.Body.Close()
	}
	srv.Close()

	out := buf.String()

	msRe := regexp.MustCompile(`\d{2}:\d{2}:\d{2}\.\d{3}`)
	secRe := regexp.MustCompile(`\d{2}:\d{2}:\d{2}(?:\s|\|)`)
	msHits := msRe.FindAllString(out, -1)
	secHits := secRe.FindAllString(out, -1)

	fmt.Println("========= 捕获到的日志 =========")
	fmt.Print(out)
	fmt.Println("================================")
	fmt.Printf("ms 命中 (含 .mmm) = %d\n", len(msHits))
	fmt.Printf("秒级行 (无 .mmm)  = %d\n", len(secHits))
	fmt.Println("样例 ms:", msHits)

	if len(msHits) >= 5 && len(secHits) == 0 {
		fmt.Println("RESULT=MS_CONFIRMED")
	} else {
		fmt.Println("RESULT=FAIL")
	}
}
