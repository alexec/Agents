// Package safe keeps one panic from taking the host down (#1125, the morning walk's crash).
// Every goroutine, timer and handler the host starts goes through Go, Func or Handler: a panic
// there is logged with its stack and counted, and the host goes on.
package safe

import (
	"fmt"
	"log"
	"net/http"
	"runtime/debug"
	"sync/atomic"
)

// Panics counts the panics recovered since the host started.
var Panics atomic.Int64

// Recover logs a panic in what, with its stack. Call it deferred: `defer safe.Recover("what")`.
// A caller that must clean up after a panic uses Catch.
func Recover(what string) {
	if v := recover(); v != nil {
		note(what, v)
	}
}

// Catch runs fn and returns the panic value it raised, if any, already logged.
func Catch(what string, fn func()) (panicked any) {
	defer func() {
		if v := recover(); v != nil {
			note(what, v)
			panicked = v
		}
	}()
	fn()
	return nil
}

// Go starts fn on a goroutine of its own, with a recover.
func Go(what string, fn func()) {
	go func() {
		defer Recover(what)
		fn()
	}()
}

// Func wraps fn (a timer or cron callback) with a recover.
func Func(what string, fn func()) func() {
	return func() {
		defer Recover(what)
		fn()
	}
}

// Handler answers 500 for a request whose handler panicked, rather than leaving it to net/http
// (which recovers too, but logs to stderr without the request path).
func Handler(what string, h http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer func() {
			if v := recover(); v != nil {
				if v == http.ErrAbortHandler {
					panic(v)
				}
				note(what+" "+r.URL.Path, v)
				http.Error(w, "internal error", http.StatusInternalServerError)
			}
		}()
		h.ServeHTTP(w, r)
	})
}

func note(what string, v any) {
	n := Panics.Add(1)
	log.Printf("panic #%d in %s: %v (the host goes on)\n%s", n, what, v, debug.Stack())
}

// Err recovers a panic into *err, for a callback a library calls (ACP's client side), so that the
// runtime gets an error reply and the host goes on. Call it deferred, with a named error result.
func Err(what string, err *error) {
	if v := recover(); v != nil {
		note(what, v)
		*err = fmt.Errorf("the host hit a bug in %s: %v", what, v)
	}
}
