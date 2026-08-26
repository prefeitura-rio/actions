package main

import "fmt"

func main() {
	err := fmt.Errorf("root cause")
	_ = fmt.Errorf("operation failed: %v", err)
}
