package main

import (
	"context"
	"log"
	"net/http"
	"time"
)

func main() {
	client := &http.Client{
		Timeout:       10 * time.Second,
		Transport:     nil,
		CheckRedirect: nil,
		Jar:           nil,
	}

	ctx := context.Background()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, "https://example.com", nil)
	if err != nil {
		log.Println("error:", err)

		return
	}

	resp, err := client.Do(req)
	if err != nil {
		log.Println("error:", err)

		return
	}

	defer resp.Body.Close()
	log.Println("status:", resp.StatusCode)
}
