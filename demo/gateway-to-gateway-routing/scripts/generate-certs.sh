#!/usr/bin/env bash
set -euo pipefail

# Generate a local PKI for the three-gateway G2G E2E demo.
#
# Creates:
#   certs/grid-ca.pem         — grid CA certificate
#   certs/grid-ca-key.pem     — grid CA private key
#   certs/site-{a,b,c}.pem    — per-site server certificates (SAN: DNS:site-X, IP:127.0.0.1)
#   certs/site-{a,b,c}-key.pem
#   certs/site-a-client.pem   — site-a client cert for upstream mTLS
#   certs/site-a-client-key.pem
#   certs/untrusted-client.pem — grid-CA-valid client cert with untrusted org
#   certs/unknown-ca-client.pem — client cert signed by a different CA

DEMO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CERT_DIR="$DEMO_DIR/certs"

required_certs=(
    grid-ca.pem
    grid-ca-key.pem
    site-a.pem
    site-a-key.pem
    site-a-client.pem
    site-a-client-key.pem
    site-b.pem
    site-b-key.pem
    site-c.pem
    site-c-key.pem
    untrusted-client.pem
    untrusted-client-key.pem
    unknown-ca.pem
    unknown-ca-key.pem
    unknown-ca-client.pem
    unknown-ca-client-key.pem
)

if [ -d "$CERT_DIR" ]; then
    missing=false
    for cert in "${required_certs[@]}"; do
        if [ ! -f "$CERT_DIR/$cert" ]; then
            missing=true
        fi
    done

    if [ "$missing" = false ]; then
        echo "Certs already exist in $CERT_DIR — reusing."
        echo "Delete $CERT_DIR to regenerate."
        exit 0
    fi

    echo "Cert directory is missing expected files — regenerating."
    rm -rf "$CERT_DIR"
fi

mkdir -p "$CERT_DIR"
cd "$CERT_DIR"

DAYS=30

echo "Generating grid CA..."
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout grid-ca-key.pem -out grid-ca.pem \
    -days "$DAYS" -nodes -subj "/O=praxis-grid-e2e/CN=grid-ca" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null

generate_site_cert() {
    local site="$1"
    echo "Generating $site server cert..."

    openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout "${site}-key.pem" -out "${site}.csr" \
        -nodes -subj "/O=praxis-grid-e2e/CN=${site}" 2>/dev/null

    openssl x509 -req -in "${site}.csr" \
        -CA grid-ca.pem -CAkey grid-ca-key.pem -CAcreateserial \
        -out "${site}.pem" -days "$DAYS" \
        -extfile <(printf "basicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nsubjectAltName=DNS:%s,IP:127.0.0.1" "$site") 2>/dev/null

    rm -f "${site}.csr"
}

generate_site_cert site-a
generate_site_cert site-b
generate_site_cert site-c

echo "Generating site-a client cert..."
openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout site-a-client-key.pem -out site-a-client.csr \
    -nodes -subj "/O=praxis-grid-e2e/CN=site-a-client" 2>/dev/null

openssl x509 -req -in site-a-client.csr \
    -CA grid-ca.pem -CAkey grid-ca-key.pem -CAcreateserial \
    -out site-a-client.pem -days "$DAYS" \
    -extfile <(printf "basicConstraints=CA:FALSE\nkeyUsage=digitalSignature") 2>/dev/null

rm -f site-a-client.csr

echo "Generating untrusted client cert (different org, same CA)..."
openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout untrusted-client-key.pem -out untrusted-client.csr \
    -nodes -subj "/O=wrong-org/CN=untrusted-client" 2>/dev/null

openssl x509 -req -in untrusted-client.csr \
    -CA grid-ca.pem -CAkey grid-ca-key.pem -CAcreateserial \
    -out untrusted-client.pem -days "$DAYS" \
    -extfile <(printf "basicConstraints=CA:FALSE\nkeyUsage=digitalSignature") 2>/dev/null

rm -f untrusted-client.csr

echo "Generating unknown CA..."
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout unknown-ca-key.pem -out unknown-ca.pem \
    -days "$DAYS" -nodes -subj "/O=praxis-grid-e2e/CN=unknown-ca" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null

echo "Generating unknown-CA client cert..."
openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout unknown-ca-client-key.pem -out unknown-ca-client.csr \
    -nodes -subj "/O=praxis-grid-e2e/CN=unknown-ca-client" 2>/dev/null

openssl x509 -req -in unknown-ca-client.csr \
    -CA unknown-ca.pem -CAkey unknown-ca-key.pem -CAcreateserial \
    -out unknown-ca-client.pem -days "$DAYS" \
    -extfile <(printf "basicConstraints=CA:FALSE\nkeyUsage=digitalSignature") 2>/dev/null

rm -f unknown-ca-client.csr grid-ca.srl unknown-ca.srl

chmod 600 *-key.pem

echo ""
echo "Certificates generated in $CERT_DIR:"
ls -la "$CERT_DIR"
