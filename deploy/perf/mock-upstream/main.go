// mock-upstream
//
// 目的：给 new-api 提供**可控**的 OpenAI 兼容上游，用于 S1–S10 压测：
//   - 可控首字延迟（FIRST_TOKEN_DELAY_MS）、token 间隔（TOKEN_INTERVAL_MS）、
//     单响应 token 数（TOKENS_PER_RESPONSE）与每 token 文本体积（TOKEN_TEXT_BYTES，决定真实响应体大小）
//   - 可注入 429/5xx（error_rate + error_status），可加额外延迟（extra_latency_ms）⇒ S5 上游劣化
//   - SSE 与 JSON 两种响应（stream 字段）
//   - 运行时控制：POST /__ctrl 改参数（无需重启）；GET /__state 回读
//   - 观测：GET /metrics（Prometheus 文本）
//
// 为什么不用真实上游：真实 API Key 压测会触发厂商风控/产生费用
// 6 副本 × 250 长连接（1500 并发 SSE）由 Go 原生的 goroutine 模型承担，无导出器依赖。
package main

import (
	"encoding/json"
	"fmt"
	"io"
	"log"
	"math/rand"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

type config struct {
	FirstTokenDelayMS int     `json:"first_token_delay_ms"`
	TokenIntervalMS   int     `json:"token_interval_ms"`
	TokensPerResponse int     `json:"tokens_per_response"`
	TokenTextBytes    int     `json:"token_text_bytes"`
	ErrorRate         float64 `json:"error_rate"`
	ErrorStatus       int     `json:"error_status"`
	ExtraLatencyMS    int     `json:"extra_latency_ms"`
}

var (
	mu  sync.RWMutex
	cfg = config{}

	reqTotal    atomic.Int64
	errTotal    atomic.Int64
	streamTotal atomic.Int64
	tokenTotal  atomic.Int64
	activeConns atomic.Int64
)

func envInt(k string, def int) int {
	if v := os.Getenv(k); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
	}
	return def
}

func envFloat(k string, def float64) float64 {
	if v := os.Getenv(k); v != "" {
		if f, err := strconv.ParseFloat(v, 64); err == nil {
			return f
		}
	}
	return def
}

func loadConfig() {
	cfg = config{
		FirstTokenDelayMS: envInt("FIRST_TOKEN_DELAY_MS", 300),
		TokenIntervalMS:   envInt("TOKEN_INTERVAL_MS", 30),
		TokensPerResponse: envInt("TOKENS_PER_RESPONSE", 50),
		TokenTextBytes:    envInt("TOKEN_TEXT_BYTES", 12),
		ErrorRate:         envFloat("ERROR_RATE", 0.0),
		ErrorStatus:       envInt("ERROR_STATUS", 500),
		ExtraLatencyMS:    envInt("EXTRA_LATENCY_MS", 0),
	}
}

func (c config) clone() config {
	mu.RLock()
	defer mu.RUnlock()
	return c
}

func tokenText(n int) string {
	if n <= 0 {
		return ""
	}
	// 一段可复用的 ASCII 填充（保证按字节计长，便于估算真实响应体大小）
	const filler = "abcdefghijklmnopqrstuvwxyz0123456789"
	var b strings.Builder
	for b.Len() < n {
		b.WriteString(filler)
	}
	return b.String()[:n]
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

func openAIError(w http.ResponseWriter, code int, typ, msg string) {
	writeJSON(w, code, map[string]any{
		"error": map[string]any{"message": msg, "type": typ, "code": code},
	})
}

func main() {
	port := envInt("PORT", 8080)
	loadConfig()

	mux := http.NewServeMux()

	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = io.WriteString(w, "ok")
	})

	mux.HandleFunc("/metrics", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain; version=0.0.4")
		fmt.Fprintf(w, "# HELP mock_requests_total Total requests received\n")
		fmt.Fprintf(w, "# TYPE mock_requests_total counter\nmock_requests_total %d\n", reqTotal.Load())
		fmt.Fprintf(w, "# HELP mock_errors_total Injected/computed errors\n# TYPE mock_errors_total counter\nmock_errors_total %d\n", errTotal.Load())
		fmt.Fprintf(w, "# HELP mock_streams_total Streaming responses completed\n# TYPE mock_streams_total counter\nmock_streams_total %d\n", streamTotal.Load())
		fmt.Fprintf(w, "# HELP mock_tokens_total Tokens emitted\n# TYPE mock_tokens_total counter\nmock_tokens_total %d\n", tokenTotal.Load())
		fmt.Fprintf(w, "# HELP mock_active_conns In-flight requests\n# TYPE mock_active_conns gauge\nmock_active_conns %d\n", activeConns.Load())
	})

	mux.HandleFunc("/__state", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, cfg.clone())
	})

	// 运行时控制：只 patch 传进来的字段（零值字段会被覆盖——刻意要求显式传全量用于关键项，
	// 结构体零值语义在压测脚本里可控；S5 切回 normal 用 {"error_rate":0,"extra_latency_ms":0}）
	mux.HandleFunc("/__ctrl", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "POST only", http.StatusMethodNotAllowed)
			return
		}
		var patch config
		if err := json.NewDecoder(r.Body).Decode(&patch); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		mu.Lock()
		cfg = patch
		mu.Unlock()
		log.Printf("[ctrl] patched: %+v", patch)
		writeJSON(w, http.StatusOK, cfg.clone())
	})

	mux.HandleFunc("/v1/models", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, map[string]any{
			"object": "list",
			"data": []map[string]any{
				{"id": "mock-gpt", "object": "model", "owned_by": "mock", "created": time.Now().Unix()},
			},
		})
	})

	mux.HandleFunc("/v1/chat/completions", handleChat)
	mux.HandleFunc("/v1/completions", handleChat) // 兼容 completions 路径，响应形状与 chat 近似（只用于 SSE 打流）

	log.Printf("mock-upstream listening :%d  cfg=%+v", port, cfg.clone())
	srv := &http.Server{
		Addr:              fmt.Sprintf(":%d", port),
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
		IdleTimeout:       300 * time.Second,
	}
	if err := srv.ListenAndServe(); err != nil {
		log.Fatal(err)
	}
}

func handleChat(w http.ResponseWriter, r *http.Request) {
	activeConns.Add(1)
	defer activeConns.Add(-1)
	reqTotal.Add(1)

	if r.Method != http.MethodPost {
		openAIError(w, http.StatusMethodNotAllowed, "invalid_request_error", "POST only")
		return
	}
	body, err := io.ReadAll(io.LimitReader(r.Body, 1<<20))
	if err != nil {
		openAIError(w, http.StatusBadRequest, "invalid_request_error", err.Error())
		return
	}
	var in struct {
		Model  string `json:"model"`
		Stream bool   `json:"stream"`
	}
	_ = json.Unmarshal(body, &in)
	model := in.Model
	if model == "" {
		model = "mock-gpt"
	}

	c := cfg.clone()

	// 失败注入：S5（上游劣化）用 error_rate + error_status；额外延迟用来模拟慢上游
	if c.ExtraLatencyMS > 0 {
		time.Sleep(time.Duration(c.ExtraLatencyMS) * time.Millisecond)
	}
	if c.ErrorRate > 0 && rand.Float64() < c.ErrorRate {
		errTotal.Add(1)
		code := c.ErrorStatus
		if code == 0 {
			code = 500
		}
		if code == http.StatusTooManyRequests {
			w.Header().Set("Retry-After", "1")
			openAIError(w, code, "rate_limit_error", "mock injected 429")
			return
		}
		openAIError(w, code, "server_error", "mock injected upstream failure")
		return
	}

	if c.FirstTokenDelayMS > 0 {
		time.Sleep(time.Duration(c.FirstTokenDelayMS) * time.Millisecond)
	}

	id := fmt.Sprintf("chatcmpl-mock-%d", time.Now().UnixNano())
	created := time.Now().Unix()
	text := tokenText(c.TokenTextBytes)

	if !in.Stream {
		// 非流式：一次性返回完整文本 + usage（估算：1 token ≈ len(text) 字节）
		content := strings.Repeat(text, max(1, c.TokensPerResponse))
		completionTokens := c.TokensPerResponse
		tokenTotal.Add(int64(completionTokens))
		writeJSON(w, http.StatusOK, map[string]any{
			"id": id, "object": "chat.completion", "created": created, "model": model,
			"choices": []map[string]any{{
				"index":         0,
				"message":       map[string]any{"role": "assistant", "content": content},
				"finish_reason": "stop",
			}},
			"usage": map[string]any{
				"prompt_tokens":     16,
				"completion_tokens": completionTokens,
				"total_tokens":      16 + completionTokens,
			},
		})
		return
	}

	flusher, ok := w.(http.Flusher)
	if !ok {
		openAIError(w, http.StatusInternalServerError, "server_error", "streaming unsupported")
		return
	}
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.Header().Set("X-Accel-Buffering", "no")
	w.WriteHeader(http.StatusOK)

	emit := func(v any) error {
		b, err := json.Marshal(v)
		if err != nil {
			return err
		}
		if _, err := fmt.Fprintf(w, "data: %s\n\n", b); err != nil {
			return err
		}
		flusher.Flush()
		return nil
	}

	interval := time.Duration(c.TokenIntervalMS) * time.Millisecond
	for i := 0; i < max(1, c.TokensPerResponse); i++ {
		delta := map[string]any{"content": text}
		if i == 0 {
			delta["role"] = "assistant"
		}
		if err := emit(map[string]any{
			"id": id, "object": "chat.completion.chunk", "created": created, "model": model,
			"choices": []map[string]any{{"index": 0, "delta": delta, "finish_reason": nil}},
		}); err != nil {
			errTotal.Add(1) // 客户端提前断开（压测里属正常）
			return
		}
		tokenTotal.Add(1)
		if interval > 0 {
			time.Sleep(interval)
		}
	}
	_ = emit(map[string]any{
		"id": id, "object": "chat.completion.chunk", "created": created, "model": model,
		"choices": []map[string]any{{"index": 0, "delta": map[string]any{}, "finish_reason": "stop"}},
		"usage":   map[string]any{"prompt_tokens": 16, "completion_tokens": c.TokensPerResponse, "total_tokens": 16 + c.TokensPerResponse},
	})
	_, _ = io.WriteString(w, "data: [DONE]\n\n")
	flusher.Flush()
	streamTotal.Add(1)
}
