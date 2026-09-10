package tests

import "testing"

func TestOrdinaryProjectTestsAreNotAstGrepTests(t *testing.T) {
	t.Parallel()
	const expected = "go-integration-test"
	if actual := "go-integration-test"; actual != expected {
		t.Fatalf("expected %q, got %q", expected, actual)
	}
}
