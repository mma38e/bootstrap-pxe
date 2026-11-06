#!/bin/bash
# configure-nssdb.sh — Add a CA bundle to one NSS database.
#
# Usage: configure-nssdb.sh <nssdb-dir> <owner> <ca-bundle.pem>
#
# Safe to re-run: prints "changed" only when it modified the database.
set -euo pipefail

DB_DIR="$1"
OWNER="$2"
BUNDLE="$3"

DB="sql:${DB_DIR}"
CHANGED=false

cn_of() {  # <subject|issuer> <cert file>
    openssl x509 -in "$2" -noout "-$1" -nameopt multiline \
        | sed -n 's/^ *commonName *= *//p'
}

# Check first: creating the path for a missing user would leave a root-owned
# home directory that useradd will not fix later.
if ! id "${OWNER}" &>/dev/null; then
    echo "User does not exist: ${OWNER}" >&2
    exit 1
fi

if [[ ! -f "${DB_DIR}/cert9.db" ]]; then
    mkdir -p "${DB_DIR}"
    certutil -N --empty-password -d "${DB}"
    CHANGED=true
fi

SPLIT_DIR="$(mktemp -d)"
trap 'rm -rf "${SPLIT_DIR}"' EXIT
awk -v dir="${SPLIT_DIR}" \
    '/BEGIN CERT/ { n++ } /BEGIN CERT/,/END CERT/ { print > (dir "/" n ".pem") }' \
    "${BUNDLE}"

for CERT in "${SPLIT_DIR}"/*.pem; do
    NAME="$(cn_of subject "${CERT}")"
    certutil -L -d "${DB}" -n "${NAME}" &>/dev/null && continue

    # Only the self-signed roots are trust anchors. Intermediates are imported
    # untrusted: they exist so chains can be built to a smart card certificate.
    TRUST=",,"
    [[ "${NAME}" == "$(cn_of issuer "${CERT}")" ]] && TRUST="CT,C,C"
    certutil -A -d "${DB}" -n "${NAME}" -t "${TRUST}" -i "${CERT}"
    CHANGED=true
done

# Always applied, so a run that stopped part way gets repaired by the next one.
PKI_DIR="$(dirname "${DB_DIR}")"
chown -R "${OWNER}:" "${PKI_DIR}"
chmod 700 "${PKI_DIR}"
if command -v restorecon &>/dev/null; then
    restorecon -R "${PKI_DIR}"
fi

if [[ "${CHANGED}" == true ]]; then
    echo "changed"
fi
