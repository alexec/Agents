// Package till is a small shop's till, for the colour samples (041).
package till

import (
	"errors"
	"fmt"
)

const Float = 150.0
const mask = 0xFF

// Receipt is one sale.
type Receipt struct {
	Item  string
	Total float64
	Count int
}

type Till struct {
	float    float64
	receipts []Receipt
}

var ErrNothing = errors.New("cannot sell nothing")

func (t *Till) Sell(item string, price float64, count int) (Receipt, error) {
	if count <= 0 {
		return Receipt{}, fmt.Errorf("sell %q: %w", item, ErrNothing)
	}
	r := Receipt{Item: item, Total: price * float64(count), Count: count}
	t.receipts = append(t.receipts, r)
	t.float += r.Total
	return r, nil
}

func (t *Till) Takings() (sum float64) {
	for _, r := range t.receipts {
		sum += r.Total
	}
	return
}
