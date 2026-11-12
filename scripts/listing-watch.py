#!/usr/bin/env python3
"""Finds used M1 Mac mini listings under Alex's budget on eBay (#4500, #4499).

Run by the Used Mac mini watch workflow (.agents/workflows/mac-mini-watch.md), with the
listing-watch skill. It only reads. It buys nothing, bids on nothing and contacts no
seller. The agent that runs it notifies Alex about each listing it prints.

  EBAY_CLIENT_ID=… EBAY_CLIENT_SECRET=… scripts/listing-watch.py [--issue 4499]
      [--budget 300] [--auction-hours 12] [--state FILE] [--dry-run] [--json]
  scripts/listing-watch.py --fixture search.json --budget 300 [--now 2026-11-12T20:00:00Z]
  scripts/listing-watch.py --selftest

Source: eBay's official Browse API (item_summary/search), with an application token from
the keys of a free eBay developer account. eBay's robots.txt disallows its search pages,
so the watch never reads them. The other sites in #4500 have no permitted automatic
reader: the terms of Craigslist and Facebook Marketplace forbid robots, and Swappa answers
a script with a bot challenge. So they are not read.

Budget: the first "budget … $N" in the body of --issue (default #4499), so Alex changes it
in the issue, not here. --budget overrides it. When the issue is closed, the watch has
nothing to do: it prints "stopped: #N is closed" and reads nothing.

A listing is reported once, when it first qualifies:
  - the title names a Mac mini and an M1, and no fault (parts, broken, locked …);
  - price plus the cheapest shipping is at or under the budget, in USD, in the US;
  - an auction (its price is the current bid) qualifies only when it ends within
    --auction-hours, because an early bid says little about the final price.

State: --state (default ~/.agents/listing-watch/mac-mini-m1.json) keeps each listing seen
in the last 30 days and whether it was reported. --dry-run reads it and does not write it.
"""

import argparse
import base64
import datetime as dt
import json
import os
import re
import subprocess
import sys
import tempfile
import urllib.parse
import urllib.request

TOKEN_URL = "https://api.ebay.com/identity/v1/oauth2/token"  # noqa: S105 (a URL, not a password)
SEARCH_URL = "https://api.ebay.com/buy/browse/v1/item_summary/search"
SCOPE = "https://api.ebay.com/oauth/api_scope"
CATEGORY = "111418"  # Apple Desktops & All-In-Ones
# Used, seller refurbished and the certified refurbished grades; never "for parts" (7000).
CONDITIONS = "1500|2000|2010|2020|2030|2500|3000"
QUERY = "mac mini m1"
DEFAULT_STATE = os.path.expanduser("~/.agents/listing-watch/mac-mini-m1.json")
KEEP_DAYS = 30
FAULTS = re.compile(
    r"\b(parts|repair|broken|faulty|locked|icloud|mdm|as[- ]is|read|box only|empty box|"
    r"logic ?board|motherboard|no power|damaged|cracked)\b",
    re.I,
)
BUDGET = re.compile(r"budget\D{0,30}\$\s?(\d[\d,]*)", re.I)


def parse_time(s):
    return dt.datetime.fromisoformat(s.replace("Z", "+00:00"))


def money(m):
    """The value of a Browse API amount in USD, or None for another currency."""
    if not m or m.get("currency", "USD") != "USD":
        return None
    return float(m["value"])


def is_m1_mac_mini(title):
    t = title.lower()
    return "mac mini" in t.replace("-", " ") and re.search(r"\bm1\b", t) and not FAULTS.search(title)


def candidate(item, budget, now, auction_hours):
    """The listing as a dict, when it qualifies now; else None."""
    if not is_m1_mac_mini(item.get("title", "")):
        return None
    options = item.get("buyingOptions", [])
    auction = "AUCTION" in options and "FIXED_PRICE" not in options
    price = money(item.get("currentBidPrice") if auction else item.get("price"))
    if price is None:
        price = money(item.get("price"))
    if price is None:
        return None
    shipping = [money(o.get("shippingCost")) for o in item.get("shippingOptions", [])]
    shipping = [s for s in shipping if s is not None]
    # No shipping cost given: local pickup or calculated. Count it as nothing and say so.
    ship = min(shipping) if shipping else 0.0
    total = price + ship
    if total > budget:
        return None
    ends = item.get("itemEndDate")
    if auction:
        if not ends or parse_time(ends) - now > dt.timedelta(hours=auction_hours):
            return None
    seller = item.get("seller", {})
    return {
        "id": item["itemId"],
        "title": item["title"],
        "url": item.get("itemWebUrl", ""),
        "kind": "auction" if auction else "fixed price",
        "price": price,
        "shipping": ship if shipping else None,
        "total": total,
        "ends": ends,
        "seller": seller.get("username", ""),
        "feedback_percent": seller.get("feedbackPercentage"),
        "feedback_score": seller.get("feedbackScore"),
    }


def describe(c):
    ship = f" + ${c['shipping']:.2f} shipping" if c["shipping"] else (
        " (shipping not given)" if c["shipping"] is None else " (free shipping)")
    ends = f", ends {c['ends']}" if c["ends"] else ""
    rating = ""
    if c["seller"]:
        rating = f", seller {c['seller']} ({c['feedback_percent'] or '?'}%, {c['feedback_score'] or '?'} ratings)"
    return f"${c['price']:.2f}{ship} = ${c['total']:.2f}, {c['kind']}{ends}{rating}: {c['title']} {c['url']}"


def load_state(file):
    try:
        with open(file) as f:
            return json.load(f)
    except FileNotFoundError:
        return {"seen": {}}


def save_state(file, state):
    os.makedirs(os.path.dirname(file), exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(file), prefix=".listing-watch.")
    with os.fdopen(fd, "w") as f:
        json.dump(state, f, indent=1, sort_keys=True)
    os.replace(tmp, file)


def update(state, items, budget, now, auction_hours):
    """Records every item seen and returns the ones to report now, once each."""
    seen = state.setdefault("seen", {})
    stamp = now.strftime("%Y-%m-%dT%H:%M:%SZ")
    report = []
    for item in items:
        c = candidate(item, budget, now, auction_hours)
        entry = seen.setdefault(item["itemId"], {"first_seen": stamp, "reported": False})
        entry["last_seen"] = stamp
        if c and not entry["reported"]:
            entry["reported"] = True
            entry["reported_at"] = stamp
            entry["total"] = c["total"]
            report.append(c)
    cutoff = now - dt.timedelta(days=KEEP_DAYS)
    for k in [k for k, v in seen.items() if parse_time(v["last_seen"]) < cutoff]:
        del seen[k]
    return report


def issue_budget(issue):
    """(budget, open) from the issue's body, read with gh."""
    out = subprocess.run(
        ["gh", "issue", "view", str(issue), "--json", "body,state"],
        check=True, capture_output=True, text=True,
    ).stdout
    data = json.loads(out)
    m = BUDGET.search(data["body"])
    budget = float(m.group(1).replace(",", "")) if m else None
    return budget, data["state"] == "OPEN"


def token(client_id, secret):
    basic = base64.b64encode(f"{client_id}:{secret}".encode()).decode()
    req = urllib.request.Request(  # noqa: S310 (fixed https URL)
        TOKEN_URL,
        data=urllib.parse.urlencode({"grant_type": "client_credentials", "scope": SCOPE}).encode(),
        headers={"Authorization": f"Basic {basic}", "Content-Type": "application/x-www-form-urlencoded"},
    )
    with urllib.request.urlopen(req, timeout=30) as r:  # noqa: S310 (fixed https URLs)
        return json.load(r)["access_token"]


def search(access, budget):
    """Every listing in one call: at most 200, the most a page holds, which is plenty here."""
    flt = ",".join([
        f"price:[..{int(budget)}]",
        "priceCurrency:USD",
        f"conditionIds:{{{CONDITIONS}}}",
        "itemLocationCountry:US",
        "buyingOptions:{FIXED_PRICE|AUCTION|BEST_OFFER}",
    ])
    q = urllib.parse.urlencode({
        "q": QUERY, "category_ids": CATEGORY, "filter": flt, "limit": "200", "sort": "price",
    })
    req = urllib.request.Request(  # noqa: S310 (fixed https URL)
        f"{SEARCH_URL}?{q}",
        headers={"Authorization": f"Bearer {access}", "X-EBAY-C-MARKETPLACE-ID": "EBAY_US"},
    )
    with urllib.request.urlopen(req, timeout=30) as r:  # noqa: S310 (fixed https URLs)
        return json.load(r).get("itemSummaries", [])


def selftest():
    now = parse_time("2026-11-12T20:00:00Z")

    def item(i, title, price, *, auction=False, ends=None, ship="0.00", bid=None, cur="USD"):
        d = {
            "itemId": f"v1|{i}|0", "title": title, "itemWebUrl": f"https://www.ebay.com/itm/{i}",
            "price": {"value": price, "currency": cur},
            "buyingOptions": ["AUCTION"] if auction else ["FIXED_PRICE"],
            "shippingOptions": [{"shippingCost": {"value": ship, "currency": "USD"}}],
            "seller": {"username": "s", "feedbackPercentage": "99.5", "feedbackScore": 120},
        }
        if ends:
            d["itemEndDate"] = ends
        if bid:
            d["currentBidPrice"] = {"value": bid, "currency": "USD"}
        return d

    items = [
        item(1, "Apple Mac mini M1 2020 8GB 256GB", "280.00", ship="15.00"),        # 295: yes
        item(2, "Apple Mac Mini M1 8GB 256GB", "290.00", ship="20.00"),             # 310: no
        item(3, "Mac mini M1 for parts, no power", "120.00"),                       # fault: no
        item(4, "Mac mini M2 2023 8GB", "250.00"),                                  # not M1
        item(5, "Mac-mini M1 16GB 512GB", "50.00", auction=True,
             ends="2026-11-13T02:00:00Z", bid="210.00"),                            # 6 h: yes
        item(6, "Mac mini M1 8GB", "50.00", auction=True,
             ends="2026-11-15T20:00:00Z", bid="60.00"),                             # 3 days: not yet
        item(7, "Mac mini M1 8GB", "200.00", cur="GBP"),                            # not USD
    ]
    state = {"seen": {"v1|9|0": {"first_seen": "2026-09-01T00:00:00Z",
                                 "last_seen": "2026-09-01T00:00:00Z", "reported": True}}}
    got = update(state, items, 300, now, 12)
    assert [c["id"] for c in got] == ["v1|1|0", "v1|5|0"], got
    assert got[0]["total"] == 295.0 and got[1]["price"] == 210.0, got
    assert "v1|9|0" not in state["seen"], "old entries are pruned"
    assert len(state["seen"]) == len(items)
    assert update(state, items, 300, now, 12) == [], "a listing is reported once"
    later = parse_time("2026-11-15T10:00:00Z")
    assert [c["id"] for c in update(state, items, 300, later, 12)] == ["v1|6|0"], "auction near its end"
    assert BUDGET.search("1. Set the budget: $300 for a Mac").group(1) == "300"
    assert BUDGET.search("Budget $1,200").group(1) == "1,200"
    assert describe(got[0]).startswith("$280.00 + $15.00 shipping = $295.00, fixed price")
    print("listing-watch selftest: ok")


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--issue", type=int, default=4499)
    p.add_argument("--budget", type=float)
    p.add_argument("--auction-hours", type=float, default=12)
    p.add_argument("--state", default=DEFAULT_STATE)
    p.add_argument("--fixture", help="a saved search response to read instead of eBay")
    p.add_argument("--now", help="the time to judge by (tests)")
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("--json", action="store_true")
    p.add_argument("--selftest", action="store_true")
    a = p.parse_args()
    if a.selftest:
        selftest()
        return 0
    now = parse_time(a.now) if a.now else dt.datetime.now(dt.timezone.utc)
    budget = a.budget
    if budget is None:
        budget, is_open = issue_budget(a.issue)
        if not is_open:
            print(f"stopped: #{a.issue} is closed")
            return 0
        if budget is None:
            print(f"error: #{a.issue} has no budget line (\"budget … $N\")", file=sys.stderr)
            return 2
    if a.fixture:
        with open(a.fixture) as f:
            items = json.load(f).get("itemSummaries", [])
    else:
        cid, secret = os.environ.get("EBAY_CLIENT_ID"), os.environ.get("EBAY_CLIENT_SECRET")
        if not cid or not secret:
            print("error: EBAY_CLIENT_ID and EBAY_CLIENT_SECRET are not set", file=sys.stderr)
            return 2
        items = search(token(cid, secret), budget)
    state = load_state(a.state)
    report = update(state, items, budget, now, a.auction_hours)
    if not a.dry_run and not a.fixture:
        save_state(a.state, state)
    if a.json:
        print(json.dumps({"budget": budget, "checked": len(items), "new": report}, indent=1))
    else:
        print(f"budget ${budget:.0f}; {len(items)} eBay listings checked; {len(report)} new under budget")
        for c in report:
            print(describe(c))
    return 0


if __name__ == "__main__":
    sys.exit(main())
