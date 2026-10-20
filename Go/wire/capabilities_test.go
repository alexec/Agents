package wire

import (
	"reflect"
	"testing"
)

func TestServed(t *testing.T) {
	table := map[string]string{"a/one": "a/1", "a/two": "a/1", "b/one": "b/1", "c/heard": "c/1", "d/one": "d/1"}
	notes := map[string]bool{"c/heard": true}
	serves := func(m string) bool { return m != "a/two" }
	got := Served(table, notes, serves, "x.wire/1", "b/1")
	// a/1 is half served, so out; c/1 only names a notification, so in.
	if want := []string{"b/1", "c/1", "d/1", "x.wire/1"}; !reflect.DeepEqual(got, want) {
		t.Errorf("Served = %v, want %v", got, want)
	}
}

func TestMissing(t *testing.T) {
	if got := Missing([]string{"a/1", "b/2"}, []string{"b/2", "b/1", "c/1"}); !reflect.DeepEqual(got, []string{"b/1", "c/1"}) {
		t.Errorf("Missing = %v", got)
	}
	if got := Missing([]string{"a/1"}, []string{"a/1"}); got != nil {
		t.Errorf("Missing = %v, want nil", got)
	}
}
