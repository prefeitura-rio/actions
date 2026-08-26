package main

import (
	"fmt"
	"os"
)

func main() {
	f, _ := os.Open("file.txt")
	defer f.Close()
	fmt.Println(f.Name())
}
