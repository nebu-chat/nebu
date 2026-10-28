#!/bin/sh
# Creates a local CA and a server certificate for nebu.localtest.me / localhost in dev/tls/certs
# (git-ignored). Idempotent: an existing CA is reused, the leaf certificate is renewed.
set -eu
cd "$(dirname "$0")"
mkdir -p certs
cd certs

if [ ! -f ca.pem ] || [ ! -f ca.key ]; then
  openssl genrsa -out ca.key 4096 2>/dev/null
  openssl req -x509 -new -nodes -key ca.key -sha256 -days 825 \
    -subj "/O=Nebu local dev/CN=Nebu local dev CA" -out ca.pem
  echo "Created local CA: $(pwd)/ca.pem"
fi

cat > ext.cnf <<EXT
basicConstraints=CA:FALSE
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:nebu.localtest.me,DNS:localhost,IP:127.0.0.1,IP:::1
EXT
openssl genrsa -out localhost.key 2048 2>/dev/null
openssl req -new -key localhost.key -subj "/O=Nebu local dev/CN=nebu.localtest.me" -out localhost.csr
openssl x509 -req -in localhost.csr -CA ca.pem -CAkey ca.key -CAcreateserial \
  -out localhost.crt -days 397 -sha256 -extfile ext.cnf 2>/dev/null
rm -f localhost.csr ext.cnf
chmod 644 localhost.key   # read by the nginx container

echo "Created server certificate: $(pwd)/localhost.crt (valid 397 days)"
echo
echo "Make the browser trust it (macOS, login keychain; Firefox: import ca.pem under Settings > Certificates):"
echo "  security add-trusted-cert -r trustRoot -k ~/Library/Keychains/login.keychain-db $(pwd)/ca.pem"
