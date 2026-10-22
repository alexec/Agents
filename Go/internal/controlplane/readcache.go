package controlplane

import (
	"context"
	"strings"
	"sync"

	"github.com/alexec/agents/Go/internal/controlplane/store"
)

// What the store held at a key, by its entity tag (#2054, #2056). Reports and the Console
// list a prefix, then read the keys they need: a key whose tag has not moved since this
// copy last read it is not read again, and the rest are read storeReadsAtOnce at a time.
// It holds only keys the last listing of their prefix had, and at most mostCachedReads.

const (
	storeReadsAtOnce = 16
	// mostCachedReads bounds the keys held: 100 machines' 90 days and 20,000 claims.
	mostCachedReads = 40000
)

type readCache struct {
	mu   sync.Mutex
	held map[string]cachedRead
}

type cachedRead struct {
	etag string
	data []byte
}

// read is the data at each of keys, in their order, nil for a key gone since it was listed.
// listed is the whole listing of prefix: a key it no longer has is let go.
func (c *readCache) read(ctx context.Context, st store.Store, prefix string, listed, keys []store.Key) ([][]byte, error) {
	out := make([][]byte, len(keys))
	var missing []int
	c.mu.Lock()
	if c.held == nil {
		c.held = map[string]cachedRead{}
	}
	there := make(map[string]bool, len(listed))
	for _, k := range listed {
		there[k.Key] = true
	}
	for key := range c.held {
		if strings.HasPrefix(key, prefix) && !there[key] {
			delete(c.held, key)
		}
	}
	for i, k := range keys {
		if held, ok := c.held[k.Key]; ok && k.ETag != "" && held.etag == k.ETag {
			out[i] = held.data
		} else {
			missing = append(missing, i)
		}
	}
	c.mu.Unlock()
	if len(missing) == 0 {
		return out, nil
	}

	next := make(chan int)
	errs := make(chan error, 1)
	var wg sync.WaitGroup
	for range min(storeReadsAtOnce, len(missing)) {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := range next {
				k := keys[i]
				object, err := st.Get(ctx, k.Key)
				if err != nil {
					select {
					case errs <- err:
					default:
					}
					continue
				}
				if object == nil {
					continue
				}
				out[i] = object.Data
				// Kept only when what was read is what was listed.
				if k.ETag != "" && object.ETag == k.ETag {
					c.mu.Lock()
					if len(c.held) >= mostCachedReads {
						clear(c.held)
					}
					c.held[k.Key] = cachedRead{etag: k.ETag, data: object.Data}
					c.mu.Unlock()
				}
			}
		}()
	}
	for _, i := range missing {
		if len(errs) > 0 || ctx.Err() != nil {
			break
		}
		next <- i
	}
	close(next)
	wg.Wait()
	select {
	case err := <-errs:
		return nil, err
	default:
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	return out, nil
}
