#!/bin/zsh
# The secrets deploy/compose.yaml mounts (058, T068), made once into deploy/secrets/:
# - control-key: the control plane's private key, shared by every copy, never in the store;
# - cert.pem and key.pem: the load balancer's certificate, self-signed;
# - pin: that certificate's pin, which every code carries (compose reads it as AGENTS_CONTROL_PIN).
set -euo pipefail
dir=${0:A:h}/secrets
mkdir -p $dir && chmod 700 $dir
[[ -f $dir/control-key ]] || { head -c 32 /dev/urandom > $dir/control-key && chmod 644 $dir/control-key }
if [[ ! -f $dir/cert.pem ]]; then
    openssl ecparam -name prime256v1 -genkey -noout -out $dir/key.pem
    openssl req -new -x509 -key $dir/key.pem -out $dir/cert.pem -days 3650 -subj /CN=agents-control \
        -addext "subjectAltName=IP:127.0.0.1,DNS:localhost"
    chmod 644 $dir/key.pem
fi
openssl x509 -in $dir/cert.pem -pubkey -noout | openssl pkey -pubin -outform der | openssl dgst -sha256 -binary \
    | base64 | tr '+/' '-_' | tr -d '=' > $dir/pin
print "AGENTS_CONTROL_PIN=$(cat $dir/pin)" > ${0:A:h}/.env
print "secrets in $dir; pin $(cat $dir/pin)"
