package main

import "testing"

func TestRequesterLabelIsPresent(t *testing.T) {
	label := requesterLabel()
	if label == "" {
		t.Fatal("empty requester label")
	}
	t.Logf("requester claim: %s", label)
}
