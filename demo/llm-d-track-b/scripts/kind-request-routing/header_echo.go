// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Praxis Contributors

package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"log"
	"net/http"
)

type response struct {
	BodySHA256 string      `json:"body_sha256"`
	Headers    http.Header `json:"headers"`
	Method     string      `json:"method"`
	Path       string      `json:"path"`
}

func echo(w http.ResponseWriter, r *http.Request) {
	body, err := io.ReadAll(r.Body)
	if err != nil {
		http.Error(w, "read request body", http.StatusInternalServerError)
		return
	}

	digest := sha256.Sum256(body)
	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(response{
		BodySHA256: hex.EncodeToString(digest[:]),
		Headers:    r.Header,
		Method:     r.Method,
		Path:       r.URL.Path,
	}); err != nil {
		log.Printf("write response: %v", err)
	}
}

func main() {
	http.HandleFunc("/", echo)
	log.Fatal(http.ListenAndServe(":8080", nil))
}
