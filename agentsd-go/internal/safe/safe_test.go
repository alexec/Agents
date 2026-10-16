package safe

import (
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestGoRecovers(t *testing.T) {
	before := Panics.Load()
	done := make(chan struct{})
	Go("test", func() { defer close(done); panic("boom") })
	<-done
	for i := 0; i < 100 && Panics.Load() == before; i++ {
		time.Sleep(time.Millisecond)
	}
	if Panics.Load() != before+1 {
		t.Fatalf("panics %d, want %d", Panics.Load(), before+1)
	}
}

func TestFuncAndCatch(t *testing.T) {
	Func("timer", func() { var m map[string]int; m["x"] = 1 })()
	if v := Catch("catch", func() { panic(42) }); v != 42 {
		t.Fatalf("Catch gave %v", v)
	}
	if v := Catch("catch", func() {}); v != nil {
		t.Fatalf("Catch gave %v with no panic", v)
	}
}

func TestHandler(t *testing.T) {
	h := Handler("http", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { panic("bad request") }))
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest("GET", "/mcp/agents", nil))
	if rec.Code != 500 {
		t.Fatalf("code %d", rec.Code)
	}
}
