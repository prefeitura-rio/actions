package main

import (
	"context"
	"fmt"
	"log"
	"net/http"
	"time"
)

const timeoutSeconds = 10

func NewHTTPClient(timeout time.Duration) *http.Client {
	return &http.Client{
		Timeout:       timeout,
		Transport:     nil,
		CheckRedirect: nil,
		Jar:           nil,
	}
}

func FetchStatus(ctx context.Context, client *http.Client, url string) (int, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, http.NoBody)
	if err != nil {
		return 0, fmt.Errorf("failed to create request: %w", err)
	}

	resp, err := client.Do(req)
	if err != nil {
		return 0, fmt.Errorf("request failed: %w", err)
	}
	defer resp.Body.Close()

	return resp.StatusCode, nil
}

func main() {
	client := NewHTTPClient(timeoutSeconds * time.Second)
	ctx := context.Background()

	statusCode, err := FetchStatus(ctx, client, "https://example.com")
	if err != nil {
		log.Println("error:", err)

		return
	}

	log.Println("status:", statusCode)
}
