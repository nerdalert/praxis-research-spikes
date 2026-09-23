package main

import (
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strings"
	"time"
)

type chatRequest struct {
	Model string `json:"model"`
	Stream bool `json:"stream"`
}

func getenv(name, fallback string) string {
	if value := os.Getenv(name); value != "" {
		return value
	}
	return fallback
}

func main() {
	providerID := getenv("PROVIDER_ID", "provider-a")
	expectedKey := getenv("EXPECTED_API_KEY", "fixture-key")
	certFile := getenv("TLS_CERT_FILE", "/tls/tls.crt")
	keyFile := getenv("TLS_KEY_FILE", "/tls/tls.key")
	listenAddr := getenv("LISTEN_ADDR", ":8443")

	handler := http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		body, err := io.ReadAll(request.Body)
		if err != nil {
			http.Error(writer, "read failed", http.StatusBadRequest)
			return
		}
		var input chatRequest
		_ = json.Unmarshal(body, &input)
		gotKey := strings.TrimSpace(strings.TrimPrefix(request.Header.Get("Authorization"), "Bearer "))
		valid := gotKey != "" && gotKey == expectedKey
		log.Printf("provider_contact provider=%s path=%s model=%s credential_present=%t credential_valid=%t caller_api_key_present=%t", providerID, request.URL.Path, input.Model, gotKey != "", valid, request.Header.Get("X-Api-Key") != "")
		if !valid {
			http.Error(writer, `{"error":"provider credential rejected"}`, http.StatusUnauthorized)
			return
		}
		writer.Header().Set("X-Provider-Id", providerID)
		writer.Header().Set("X-Envoy-Hop", "absent")
		if input.Stream {
			writer.Header().Set("Content-Type", "text/event-stream")
			writer.Header().Set("Cache-Control", "no-cache")
			writer.WriteHeader(http.StatusOK)
			flusher, _ := writer.(http.Flusher)
			for index, text := range []string{"hello", " from ", providerID} {
				chunk := fmt.Sprintf("data: {\"id\":\"%s-%d\",\"object\":\"chat.completion.chunk\",\"choices\":[{\"delta\":{\"content\":%q}}]}\n\n", providerID, index, text)
				if _, err := io.WriteString(writer, chunk); err != nil {
					return
				}
				flusher.Flush()
				time.Sleep(40 * time.Millisecond)
			}
			_, _ = io.WriteString(writer, "data: [DONE]\n\n")
			flusher.Flush()
			return
		}
		writer.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(writer).Encode(map[string]any{
			"id": "fixture-" + providerID,
			"object": "chat.completion",
			"model": input.Model,
			"provider": providerID,
			"choices": []any{map[string]any{"index": 0, "message": map[string]string{"role": "assistant", "content": "hello from " + providerID}, "finish_reason": "stop"}},
		})
	})

	cert, err := tls.LoadX509KeyPair(certFile, keyFile)
	if err != nil {
		log.Fatal(err)
	}
	pool := x509.NewCertPool()
	_ = pool
	server := &http.Server{Addr: listenAddr, Handler: handler, TLSConfig: &tls.Config{MinVersion: tls.VersionTLS12, Certificates: []tls.Certificate{cert}}}
	log.Printf("provider_fixture provider=%s listen=%s", providerID, listenAddr)
	log.Fatal(server.ListenAndServeTLS("", ""))
}
