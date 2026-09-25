#!/usr/bin/env python3
"""A small shop's till, for the colour samples (041)."""

from __future__ import annotations

import dataclasses
from decimal import Decimal
from typing import Iterable

FLOAT = Decimal("150.00")
MASK = 0xFF


@dataclasses.dataclass(frozen=True)
class Receipt:
    item: str
    total: Decimal
    count: int = 1


class Till:
    """Takes money and remembers it."""

    def __init__(self, float_: Decimal = FLOAT) -> None:
        self.float = float_
        self.receipts: list[Receipt] = []

    def sell(self, item: str, price: Decimal, count: int = 1) -> Receipt:
        # Nothing sold for nothing.
        if count <= 0:
            raise ValueError(f"cannot sell {count} of {item!r}")
        receipt = Receipt(item, price * count, count)
        self.float += receipt.total
        self.receipts.append(receipt)
        return receipt

    @property
    def takings(self) -> Decimal:
        return sum((r.total for r in self.receipts), Decimal(0))

    def __repr__(self) -> str:
        return f"Till(float={self.float}, receipts={len(self.receipts)})"


def busiest(receipts: Iterable[Receipt]) -> str | None:
    counts: dict[str, int] = {}
    for r in receipts:
        counts[r.item] = counts.get(r.item, 0) + r.count
    return max(counts, key=counts.get, default=None)


if __name__ == "__main__":
    till = Till()
    till.sell("coffee", Decimal("3.20"), count=2)
    print(till, busiest(till.receipts), 1.5e3, True, None)
