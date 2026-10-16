#!/bin/sh
# A MinIO of the spike's own, for the bucket tests (stage 1): container cpgo-minio on the
# docker network cpgo, and on 127.0.0.1:9100 for a control plane run on this Mac.
#   ./minio.sh up | down | env      env prints what ./go.sh test needs
set -e
case "${1:-up}" in
up)
  docker network inspect cpgo >/dev/null 2>&1 || docker network create cpgo >/dev/null
  docker inspect cpgo-minio >/dev/null 2>&1 || docker run -d --name cpgo-minio --network cpgo -p 127.0.0.1:9100:9000 \
    -e MINIO_ROOT_USER=spike -e MINIO_ROOT_PASSWORD=spike-secret-key cgr.dev/chainguard/minio:latest server /data >/dev/null
  for _ in $(seq 1 50); do curl -sf http://127.0.0.1:9100/minio/health/live >/dev/null && break; sleep 0.2; done
  echo "minio up at http://127.0.0.1:9100 (in docker: http://cpgo-minio:9000)" ;;
down) docker rm -f cpgo-minio >/dev/null 2>&1 || true; docker network rm cpgo >/dev/null 2>&1 || true ;;
env)
  echo "export GO_NETWORK=cpgo AGENTS_TEST_S3=s3://cpgo/test AGENTS_STORE_ENDPOINT=http://cpgo-minio:9000 AGENTS_STORE_PATH_STYLE=1 AWS_ACCESS_KEY_ID=spike AWS_SECRET_ACCESS_KEY=spike-secret-key AWS_REGION=us-east-1" ;;
esac
