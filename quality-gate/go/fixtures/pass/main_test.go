package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestNewHTTPClient(t *testing.T) {
	t.Parallel()

	timeout := 5 * time.Second
	client := NewHTTPClient(timeout)

	if client.Timeout != timeout {
		t.Fatalf("expected timeout %v, got %v", timeout, client.Timeout)
	}
}

func TestFetchStatus(t *testing.T) {
	t.Parallel()

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))
	defer server.Close()

	client := server.Client()
	client.Timeout = 5 * time.Second

	statusCode, err := FetchStatus(context.Background(), client, server.URL)
	if err != nil {
		t.Fatalf("expected no error, got %v", err)
	}

	if statusCode != http.StatusOK {
		t.Fatalf("expected status %d, got %d", http.StatusOK, statusCode)
	}
}
