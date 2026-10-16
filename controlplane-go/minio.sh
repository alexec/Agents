#!/bin/sh
# A MinIO of the spike's own, for the bucket tests (stage 1) and run.sh --s3: container
# cpgo-minio, on the docker network cpgo for ./go.sh test, and on 127.0.0.1:19100 for a
# control plane run on this Mac.
#
# Colima did not forward a new container's port to this Mac on 2026-10-16 (the devbox's
# older one still worked), so the Mac reaches MinIO through an ssh tunnel over the
# agents-devbox container's sshd (test-servers), its pid kept beside the build caches.
#   ./minio.sh up | down | env      env prints what ./go.sh test needs
set -e
pidfile="$HOME/Library/Caches/Agents-build/cpgo-minio-tunnel.pid"
case "${1:-up}" in
up)
  docker network inspect cpgo >/dev/null 2>&1 || docker network create cpgo >/dev/null
  if ! docker inspect cpgo-minio >/dev/null 2>&1; then
    docker run -d --name cpgo-minio -e MINIO_ROOT_USER=spike -e MINIO_ROOT_PASSWORD=spike-secret-key \
      cgr.dev/chainguard/minio:latest server /data >/dev/null
    docker network connect cpgo cpgo-minio
  fi
  if ! { [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile")" 2>/dev/null; }; then
    ip=$(docker inspect cpgo-minio --format '{{.NetworkSettings.Networks.bridge.IPAddress}}')
    ssh -f -N -o ExitOnForwardFailure=yes -o UserKnownHostsFile="$HOME/.cache/agents-devbox/known_hosts" \
      -i "$HOME/.ssh/id_ed25519" -p 2222 -L "127.0.0.1:19100:$ip:9000" agents@127.0.0.1
    pgrep -f "127.0.0.1:19100:$ip:9000" | head -1 >"$pidfile"
  fi
  for _ in $(seq 1 50); do curl -sf http://127.0.0.1:19100/minio/health/live >/dev/null && break; sleep 0.2; done
  curl -sf http://127.0.0.1:19100/minio/health/live >/dev/null && echo "minio up at http://127.0.0.1:19100 (in docker: http://cpgo-minio:9000)" ;;
down)
  [ -f "$pidfile" ] && kill "$(cat "$pidfile")" 2>/dev/null; rm -f "$pidfile"
  docker rm -f cpgo-minio >/dev/null 2>&1 || true; docker network rm cpgo >/dev/null 2>&1 || true ;;
env)
  echo "export GO_NETWORK=cpgo AGENTS_TEST_S3=s3://cpgo/test AGENTS_STORE_ENDPOINT=http://cpgo-minio:9000 AGENTS_STORE_PATH_STYLE=1 AWS_ACCESS_KEY_ID=spike AWS_SECRET_ACCESS_KEY=spike-secret-key AWS_REGION=us-east-1" ;;
esac
