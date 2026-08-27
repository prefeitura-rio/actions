package main

import (
	"context"
	"log"
	"net/http"
	"time"
)

const timeoutSeconds = 10

func main() {
	client := &http.Client{
		Timeout:       timeoutSeconds * time.Second,
		Transport:     nil,
		CheckRedirect: nil,
		Jar:           nil,
	}

	ctx := context.Background()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, "https://example.com", http.NoBody)

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
