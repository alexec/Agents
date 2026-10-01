#!/bin/zsh
# The local demo's certificate (058, T093): self-signed for DEMO_ADDRESS, in deploy/demo/secrets,
# with its pin, which compose.local.yaml gives the copy for its codes. The container has no
# openssl to make one itself.
#
#   deploy/demo/local-cert.sh 192.168.0.152
set -euo pipefail
address=${1:?usage: local-cert.sh <address the machine and its containers reach>}
dir=${0:A:h}/secrets
mkdir -p $dir && chmod 700 $dir
openssl ecparam -name prime256v1 -genkey -noout -out $dir/key.pem
openssl req -new -x509 -key $dir/key.pem -out $dir/cert.pem -days 365 -subj /CN=agents-demo \
    -addext "subjectAltName=IP:$address,IP:127.0.0.1,DNS:localhost" 2>/dev/null
chmod 644 $dir/key.pem $dir/cert.pem
pin=$(openssl x509 -in $dir/cert.pem -pubkey -noout | openssl pkey -pubin -outform der | openssl dgst -sha256 -binary \
    | base64 | tr '+/' '-_' | tr -d '=')
print "DEMO_ADDRESS=$address\nDEMO_PIN=$pin\nDEMO_DOMAIN=unused" > ${0:A:h}/.env
print "certificate for $address in $dir; pin $pin (written to deploy/demo/.env)"
