#!/bin/bash
# The observability walk (#3417): a scratch control plane against real tools, each in a
# local container, with no outside account. It sends the audit to Graylog by syslog over
# TLS and by HTTPS (its Raw HTTP input, a bearer token), the report figures by OTLP to an
# OpenTelemetry Collector that Prometheus scrapes, and lets Grafana's Infinity source read
# GET /v1/read/reports as a BI tool does; then it revokes the token and checks Grafana is
# refused. It says what each tool got, and stops and removes every container it started.
#
#   Go/internal/controlplane/walk/observability/walk.sh        # lease "build" first
#
# It needs Docker (Colima on a Mac) with about 3 GB of memory and 4 GB of disk free.
# KEEP=1 leaves the tools up after the walk: Graylog on http://127.0.0.1:19000 and Grafana
# on http://127.0.0.1:13000 (admin / walk-3417-admin), Prometheus on :19090.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
mod=$(cd "$here/../../../.." && pwd)
repo=$(dirname "$mod")
run="$here/run"
project=walk3417
password=walk-3417-admin
token=walk-3417-token
fails=0

say() { printf '%s\n' "$*"; }
pass() { say "PASS  $*"; }
fail() { say "FAIL  $*"; fails=$((fails + 1)); }
gl() { curl -sf -u "admin:$password" -H 'X-Requested-By: walk' -H 'Content-Type: application/json' "$@"; }
gf() { curl -sf -u "admin:$password" -H 'Content-Type: application/json' "$@"; }
compose() { docker compose -p "$project" -f "$here/compose.yaml" "$@"; }

cleanup() {
	touch "$run/done" 2>/dev/null || true
	docker rm -f "$project-walk" >/dev/null 2>&1 || true
	if [ "${KEEP:-}" != 1 ]; then
		compose down -v --remove-orphans >/dev/null 2>&1 || true
		rm -rf "$run"
	fi
}
trap cleanup EXIT

# A CA of the walk's own, and Graylog's certificate from it, for a new set of tools.
compose down -v --remove-orphans >/dev/null 2>&1 || true
docker rm -f "$project-walk" >/dev/null 2>&1 || true
rm -rf "$run" && mkdir -p "$run/certs"
(
	cd "$run/certs"
	openssl req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.pem -days 1 -subj "/CN=walk-3417 CA" 2>/dev/null
	openssl req -newkey rsa:2048 -nodes -keyout server.rsa -out server.csr -subj "/CN=graylog" 2>/dev/null
	printf 'subjectAltName=DNS:graylog\nextendedKeyUsage=serverAuth\n' >ext
	openssl x509 -req -in server.csr -CA ca.pem -CAkey ca.key -CAcreateserial -out server.pem -days 1 -extfile ext 2>/dev/null
	openssl pkcs8 -topk8 -nocrypt -in server.rsa -out server.key
	chmod 644 ./*
)

say "Starting Graylog, the Collector, Prometheus and Grafana…"
compose up -d --quiet-pull >/dev/null 2>&1
for _ in $(seq 1 60); do
	gl http://127.0.0.1:19000/api/system/lbstatus >/dev/null 2>&1 && break
	sleep 5
done
gl http://127.0.0.1:19000/api/system/lbstatus >/dev/null || { fail "Graylog did not start"; exit 1; }

# Graylog's two inputs: syslog over TLS, and Raw HTTP over TLS with a bearer token and
# newline-delimited batches.
input() {
	gl -X POST http://127.0.0.1:19000/api/system/inputs -d "$1" >/dev/null || fail "Graylog input: $1"
}
input '{"title":"Agents syslog TLS","type":"org.graylog2.inputs.syslog.tcp.SyslogTCPInput","global":true,
	"configuration":{"bind_address":"0.0.0.0","port":6514,"tls_enable":true,"tls_cert_file":"/certs/server.pem",
	"tls_key_file":"/certs/server.key","use_null_delimiter":false,"store_full_message":true,"recv_buffer_size":1048576}}'
input '{"title":"Agents HTTP","type":"org.graylog2.inputs.raw.http.RawHttpInput","global":true,
	"configuration":{"bind_address":"0.0.0.0","port":8090,"tls_enable":true,"tls_cert_file":"/certs/server.pem",
	"tls_key_file":"/certs/server.key","enable_bulk_receiving":true,"authorization_header_name":"Authorization",
	"authorization_header_value":"Bearer '"$token"'","recv_buffer_size":1048576}}'
sleep 5

say "Running the scratch control plane…"
# The plane runs on the tools' network as "walk", in the Go image go.sh uses; it trusts
# the walk's CA by SSL_CERT_FILE, as a Linux control plane does.
cache="${AGENTS_BUILD_CACHE:-$HOME/Library/Caches/Agents-build}/go"
mkdir -p "$cache/gopath" "$cache/gocache"
image=$(sed -n 's/^.*GO_IMAGE:-\([^}]*\)}.*$/\1/p' "$mod/scripts/go.sh" | head -1)
docker run -d --name "$project-walk" --network "${project}_default" --network-alias walk \
	-v "$repo":/repo -v "$cache/gopath":/go -v "$cache/gocache":/root/.cache/go-build -w /repo/Go \
	-e CGO_ENABLED=0 -e AGENTS_WALK_OBSERVABILITY=/repo/Go/internal/controlplane/walk/observability/run \
	-e SSL_CERT_FILE=/repo/Go/internal/controlplane/walk/observability/run/certs/ca.pem \
	-e WALK_HTTP_TOKEN="$token" "${image:-golang:1.26}" \
	go test -count=1 -run '^TestWalkObservability$' -v -timeout 20m ./internal/controlplane/ >/dev/null
for _ in $(seq 1 120); do
	[ -s "$run/plane.json" ] && break
	if [ "$(docker inspect -f '{{.State.Running}}' "$project-walk")" != true ]; then
		docker logs "$project-walk" 2>&1 | tail -30
		fail "the scratch control plane stopped"
		exit 1
	fi
	sleep 2
done
[ -s "$run/plane.json" ] || { docker logs "$project-walk" 2>&1 | tail -30; fail "the plane did not start"; exit 1; }
docker logs "$project-walk" 2>&1 | grep -E 'sinks:|read API:' | sed 's/^ */      /'
plane_url=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["url"])' "$run/plane.json")
read_token=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["token"])' "$run/plane.json")

# 1. The audit in Graylog, from each input. A phrase, or Graylog matches its words apart.
search() {
	gl -G http://127.0.0.1:19000/api/search/universal/relative --data-urlencode "query=$1" \
		--data-urlencode range=3600 --data-urlencode limit=50 -H 'Accept: application/json'
}
for _ in $(seq 1 30); do
	n=$(search '"control/setAuditDays"' | python3 -c 'import json,sys; print(json.load(sys.stdin)["total_results"])' || echo 0)
	[ "$n" -ge 6 ] && break
	sleep 2
done
search '"control/setAuditDays"' >"$run/graylog.json" || true
python3 - "$run/graylog.json" <<'EOF' && pass "Graylog has the audit entries from syslog (TLS) and from HTTP" || fail "Graylog has not the audit entries"
import json, sys
found = json.load(open(sys.argv[1]))["messages"]
by = {}
for m in found:
    m = m["message"]
    by.setdefault(m.get("gl2_source_input"), []).append(m)
print("      %d messages in %d inputs" % (len(found), len(by)))
for msgs in by.values():
    m = msgs[0]
    line = m.get("full_message") or m.get("message")
    print("      source=%s facility=%s application=%s: %s" % (m.get("source"), m.get("facility"), m.get("application_name"), line[:150]))
assert len(by) == 2 and all(len(v) >= 3 for v in by.values()), by.keys()
assert all('"hash":"' in (m.get("full_message") or m.get("message")) for v in by.values() for m in v)
EOF

# The burst: three full batches, every line at both inputs.
count() {
	gl -G http://127.0.0.1:19000/api/search/universal/relative --data-urlencode "query=$1" \
		--data-urlencode range=3600 --data-urlencode limit=1 --data-urlencode "filter=streams:000000000000000000000001" \
		-H 'Accept: application/json' | python3 -c 'import json,sys; print(json.load(sys.stdin)["total_results"])'
}
for _ in $(seq 1 30); do
	n=$(count '"walk/burst"' || echo 0)
	[ "$n" -ge 3000 ] && break
	sleep 2
done
n=$(count '"walk/burst"' || echo 0)
if [ "$n" = 3000 ]; then pass "Graylog has all 1500 lines of the burst from each input"; else fail "Graylog has $n of the burst's 3000 lines"; fi

# 2. The report figures in Prometheus, by runtime.
prom() { curl -sf -G http://127.0.0.1:19090/api/v1/query --data-urlencode "query=$1"; }
for _ in $(seq 1 30); do
	prom '{__name__=~"agents_cost.*"}' | grep -q '"runtime"' && break
	sleep 2
done
prom '{__name__=~"agents_.*"}' >"$run/prometheus.json" || true
python3 - "$run/prometheus.json" <<'EOF' && pass "Prometheus has the report figures by runtime" || fail "Prometheus has not the report figures"
import json, sys
got = json.load(open(sys.argv[1]))["data"]["result"]
names = sorted({r["metric"]["__name__"] for r in got})
print("      " + ", ".join(names))
for r in got:
    m = r["metric"]
    if m["__name__"].startswith("agents_cost"):
        print("      %s runtime=%s currency=%s = %s" % (m["__name__"], m.get("runtime"), m.get("currency"), r["value"][1]))
cost = {r["metric"].get("runtime"): float(r["value"][1]) for r in got if r["metric"]["__name__"].startswith("agents_cost")}
assert cost == {"claude": 2.5, "codex": 0.75}, cost
assert any(n.startswith("agents_tokens") for n in names) and any(n.startswith("agents_time") for n in names)
EOF

# 3. The read API from Grafana's Infinity source, as a BI tool reads it.
gf -X POST http://127.0.0.1:13000/api/datasources -d '{"name":"Agents read API","type":"yesoreyeram-infinity-datasource",
	"access":"proxy","jsonData":{"auth_method":"bearerToken","allowedHosts":["'"$plane_url"'"]},
	"secureJsonData":{"bearerToken":"'"$read_token"'"}}' >"$run/datasource.json" || fail "Grafana took no data source"
uid=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["datasource"]["uid"])' "$run/datasource.json" 2>/dev/null || true)
# Not -f: a refused read is an answer with an error in it.
query() {
	curl -s -u "admin:$password" -H 'Content-Type: application/json' -X POST http://127.0.0.1:13000/api/ds/query -d '{"queries":[{"refId":"A","datasource":{"uid":"'"$uid"'"},
		"type":"csv","source":"url","format":"table","parser":"backend",
		"url":"'"$plane_url"'/v1/read/reports?range=day&format=csv","url_options":{"method":"GET"}}],
		"from":"now-1h","to":"now"}'
}
query >"$run/grafana.json" || true
python3 - "$run/grafana.json" <<'EOF' && pass "Grafana reads the reports with the token" || fail "Grafana could not read the reports"
import json, sys
frame = json.load(open(sys.argv[1]))["results"]["A"]["frames"][0]
names = [f["name"] for f in frame["schema"]["fields"]]
values = frame["data"]["values"]
rows = list(zip(*values))
print("      columns: " + ", ".join(names))
for r in rows:
    print("      " + ", ".join(str(v) for v in r))
assert len(rows) == 2, rows
EOF

touch "$run/revoke"
for _ in $(seq 1 20); do [ -e "$run/revoked" ] && break; sleep 1; done
sleep 11 # a copy keeps what it read of a token for 10 s
query >"$run/grafana-revoked.json" 2>/dev/null || true
python3 - "$run/grafana-revoked.json" <<'EOF' && pass "Grafana is refused once the token is revoked" || fail "Grafana still reads with a revoked token"
import json, sys
r = json.load(open(sys.argv[1]))["results"]["A"]
print("      status=%s: %s" % (r.get("status"), (r.get("error") or "no error")[:150]))
rows = [v for f in r.get("frames", []) for v in f["data"]["values"][:1]]
assert r.get("error") and "401" in r["error"] and not any(rows), r
EOF

if [ "$fails" = 0 ]; then say "The walk passed."; else say "The walk failed $fails check(s)."; fi
exit "$fails"
