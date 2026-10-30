#!/bin/zsh
# The secrets deploy/compose.yaml mounts (058, T068), made once into deploy/secrets/:
# - control-key: the control plane's private key, shared by every copy, never in the store;
# - secrets-key: the key that seals people's and providers' secrets, shared by every copy, so a
#   secret one copy sealed opens at the others (#2163);
# - cert.pem and key.pem: the load balancer's certificate, self-signed;
# - pin: that certificate's pin, which every code carries (compose reads it as AGENTS_CONTROL_PIN).
#
# With --public (#61, compose.public.yaml), no key file and no certificate: Caddy's comes from
# Let's Encrypt, is publicly trusted, and codes carry no pin. The control key is sealed in the
# store by Google Cloud KMS (#1458), so it is never on the machine's disk in clear:
#
#   deploy/make-secrets.sh --public --kms projects/P/locations/L/keyRings/R/cryptoKeys/K \
#       [--service-account sa.json]
#
# - AGENTS_CONTROL_KMS in deploy/.env: gcpkms:// and the key's name;
# - gcp-service-account: a copy of the service account file that may use the key, or an empty
#   file without --service-account, for a machine whose own service account may use it.
#
# Pushes without a Mac (#1460): the APNs key from the Apple developer account, scoped to the
# Remote's app id. Give it once, with --kms or after it:
#
#   deploy/make-secrets.sh --public --apns AuthKey_KEYID.p8 [--apns-key-id KEYID] [--team-id TEAM]
#
# - apns-key: a copy of the .p8 file, in the 0700 secrets folder, mounted as a compose secret;
#   an empty file without --apns, and then the control plane sends no pushes and says so;
# - AGENTS_APNS_KEY_ID and AGENTS_APNS_TEAM_ID in deploy/.env. The Key ID is read from the
#   file's name (AuthKey_KEYID.p8) when not given; the Team ID is the app's, 6T4RVD5724.
#
# Web Push to a browser (#1486): vapid-key, a P-256 key made here the first time and kept, since
# a new one ends every browser's subscription.
set -euo pipefail
dir=${0:A:h}/secrets
env_file=${0:A:h}/.env
mkdir -p $dir && chmod 700 $dir

# set_env NAME VALUE: NAME's line in deploy/.env, leaving any others there as they are.
set_env() {
    { [[ -f $env_file ]] && { grep -v "^$1=" $env_file || true }; print "$1=$2" } > $env_file.new
    mv $env_file.new $env_file
}

if [[ ${1:-} == --public ]]; then
    shift
    kms='' account='' apns='' apns_key_id='' team_id=6T4RVD5724
    while (( $# )); do
        case $1 in
            --kms) kms=${2:?--kms needs the key name}; shift 2 ;;
            --service-account) account=${2:?--service-account needs a file}; shift 2 ;;
            --apns) apns=${2:?--apns needs the .p8 file}; shift 2 ;;
            --apns-key-id) apns_key_id=${2:?--apns-key-id needs the Key ID}; shift 2 ;;
            --team-id) team_id=${2:?--team-id needs the Team ID}; shift 2 ;;
            *) print -u2 "make-secrets.sh: $1 is not an option"; exit 2 ;;
        esac
    done
    if [[ -n $apns ]]; then
        if [[ ! -s $apns ]] || ! grep -q -- '-----BEGIN PRIVATE KEY-----' $apns; then
            print -u2 "make-secrets.sh: $apns is not an APNs key (.p8)"
            exit 2
        fi
        if [[ -z $apns_key_id && ${apns:t} =~ '^AuthKey_([A-Z0-9]{10})\.p8$' ]]; then
            apns_key_id=${match[1]}
        fi
        if [[ ! $apns_key_id =~ '^[A-Z0-9]{10}$' ]]; then
            print -u2 "make-secrets.sh: say the key's 10-character Key ID: --apns-key-id KEYID"
            exit 2
        fi
        if [[ ! $team_id =~ '^[A-Z0-9]{10}$' ]]; then
            print -u2 "make-secrets.sh: $team_id is not a Team ID"
            exit 2
        fi
        cp $apns $dir/apns-key
        chmod 644 $dir/apns-key
        set_env AGENTS_APNS_KEY_ID $apns_key_id
        set_env AGENTS_APNS_TEAM_ID $team_id
        print "the APNs key $apns_key_id (team $team_id) is in $dir/apns-key"
    elif [[ ! -f $dir/apns-key ]]; then
        : > $dir/apns-key
        chmod 644 $dir/apns-key
        print "no APNs key: the control plane sends no pushes until you give one with --apns"
    fi
    if [[ ! -s $dir/vapid-key ]]; then
        openssl ecparam -name prime256v1 -genkey -noout | openssl pkcs8 -topk8 -nocrypt -out $dir/vapid-key
        chmod 644 $dir/vapid-key
        print "a VAPID key for Web Push is in $dir/vapid-key"
    fi
    if [[ -z $kms ]]; then
        # Only the APNs key, given after the rest.
        if [[ -n $apns ]] && [[ -f $env_file ]] && grep -q '^AGENTS_CONTROL_KMS=' $env_file; then
            exit 0
        fi
        print -u2 "make-secrets.sh: say which Cloud KMS key seals the control key:"
        print -u2 "    --kms projects/P/locations/L/keyRings/R/cryptoKeys/K [--service-account sa.json]"
        exit 2
    fi
    [[ $kms == gcpkms://* ]] || kms=gcpkms://$kms
    if [[ ! $kms =~ '^gcpkms://projects/[^/]+/locations/[^/]+/keyRings/[^/]+/cryptoKeys/[^/]+$' ]]; then
        print -u2 "make-secrets.sh: $kms is not a key name: projects/P/locations/L/keyRings/R/cryptoKeys/K"
        exit 2
    fi
    if [[ -n $account ]]; then
        [[ -s $account ]] || { print -u2 "make-secrets.sh: $account is not a service account file"; exit 2 }
        cp $account $dir/gcp-service-account
    else
        : > $dir/gcp-service-account
    fi
    chmod 644 $dir/gcp-service-account
    set_env AGENTS_CONTROL_KMS $kms
    print "the control key is sealed by $kms (AGENTS_CONTROL_KMS in $env_file)"
    if [[ -n $account ]]; then
        print "the right to use it is in $dir/gcp-service-account"
    else
        print "no service account file: the machine's own service account must be able to use the key"
    fi
    exit 0
fi
[[ -f $dir/control-key ]] || { head -c 32 /dev/urandom > $dir/control-key && chmod 644 $dir/control-key }
[[ -f $dir/secrets-key ]] || { head -c 32 /dev/urandom > $dir/secrets-key && chmod 644 $dir/secrets-key }
if [[ ! -f $dir/cert.pem ]]; then
    openssl ecparam -name prime256v1 -genkey -noout -out $dir/key.pem
    openssl req -new -x509 -key $dir/key.pem -out $dir/cert.pem -days 3650 -subj /CN=agents-control \
        -addext "subjectAltName=IP:127.0.0.1,DNS:localhost"
    chmod 644 $dir/key.pem
fi
openssl x509 -in $dir/cert.pem -pubkey -noout | openssl pkey -pubin -outform der | openssl dgst -sha256 -binary \
    | base64 | tr '+/' '-_' | tr -d '=' > $dir/pin
set_env AGENTS_CONTROL_PIN $(cat $dir/pin)
print "secrets in $dir; pin $(cat $dir/pin)"
