#!/bin/sh
# Creates only a Boomer-specific development identity; no system trust changes.
set -eu
umask 077
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
signing="$root/.local-signing"
keychain="$signing/boomer.keychain-db"
add_to_search_list() {
    # codesign's --keychain limits certificate lookup, but its private-key
    # lookup also needs the keychain in the user's search list.
    /usr/bin/security list-keychains -d user > "$signing/search-list.before"
    set --
    found=no
    while IFS= read -r line; do
        entry=$(printf '%s\n' "$line" | sed 's/^[[:space:]]*"//; s/"[[:space:]]*$//')
        [ "$entry" != "$keychain" ] || found=yes
        [ -z "$entry" ] || set -- "$@" "$entry"
    done < "$signing/search-list.before"
    if [ "$found" = no ]; then
        /usr/bin/security list-keychains -d user -s "$@" "$keychain"
    fi
}
if [ -f "$signing/identity" ]; then
    add_to_search_list
    echo 'Boomer local signing identity already exists.'
    exit 0
fi
if [ -e "$keychain" ]; then
    echo "Incomplete signing setup at $signing; refusing to replace existing keys." >&2
    exit 1
fi
mkdir -p "$signing"
chmod 700 "$signing"
tmp=$(mktemp -d "$signing/setup.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
/usr/bin/openssl rand -base64 32 > "$signing/password"
password=$(cat "$signing/password")
cat > "$tmp/certificate.cnf" <<'EOF'
[req]
prompt = no
distinguished_name = subject
x509_extensions = extensions
[subject]
CN = Boomer Local Development
[extensions]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
EOF
/usr/bin/openssl req -new -newkey rsa:2048 -x509 -sha256 -days 3650 -nodes \
    -config "$tmp/certificate.cnf" -keyout "$tmp/key.pem" -out "$tmp/certificate.pem" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/certificate.pem" \
    -name 'Boomer Local Development' -out "$tmp/identity.p12" -passout "file:$signing/password"
/usr/bin/security create-keychain -p "$password" "$keychain"
/usr/bin/security unlock-keychain -p "$password" "$keychain"
/usr/bin/security import "$tmp/identity.p12" -k "$keychain" -P "$password" -T /usr/bin/codesign >/dev/null
/usr/bin/security set-key-partition-list -S apple-tool:,apple: -s -k "$password" "$keychain" >/dev/null
add_to_search_list
/usr/bin/openssl x509 -in "$tmp/certificate.pem" -outform DER -out "$signing/certificate.cer"
/usr/bin/openssl x509 -in "$tmp/certificate.pem" -noout -fingerprint -sha1 |
    sed 's/.*=//; s/://g' > "$signing/identity"
echo 'Created a persistent local signing identity for Boomer.'
echo 'No certificate was added to system trust. Keep .local-signing private and do not delete it between builds.'
