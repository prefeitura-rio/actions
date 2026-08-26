package main

import "testing"

func TestFail(t *testing.T) {
	got := 1
	want := 2
	if got != want {
		t.Errorf("got %d, want %d", got, want)
	}
}
