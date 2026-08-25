#!/bin/bash
#
# Loads the two Apple credentials into GitHub Actions secrets.
#
# Both files have to be created by hand first — Apple gives no non-interactive
# way to mint either one:
#
#   1. A Developer ID Application certificate.
#      Xcode → Settings → Accounts → Manage Certificates → + → Developer ID
#      Application. Then Keychain Access → My Certificates → right-click the
#      *identity* (the row with a disclosure triangle showing a private key, not
#      the bare certificate) → Export → .p12, and set a password.
#      Exporting the identity is what includes the private key and the
#      "Developer ID Certification Authority" intermediate; exporting the
#      certificate alone produces a p12 that fails on the runner.
#
#   2. An App Store Connect API key, for notarization.
#      App Store Connect → Users and Access → Integrations → App Store Connect
#      API → Team Keys → +, role Developer (Admin is not needed). The .p8 is
#      downloadable exactly once. The Key ID is in that table; the Issuer ID is
#      the UUID at the top of the page.
#
# Usage:
#   packaging/set-release-secrets.sh <cert.p12> <AuthKey_XXXXXXXXXX.p8> <issuer-uuid>
#
set -euo pipefail

REPO="${REPO:-calebheinzman/freewhisper}"

if [ $# -ne 3 ]; then
    sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
fi

P12="$1"
P8="$2"
ISSUER="$3"

[ -f "$P12" ] || { echo "no such file: $P12"; exit 1; }
[ -f "$P8" ]  || { echo "no such file: $P8"; exit 1; }

# AuthKey_XXXXXXXXXX.p8 -> XXXXXXXXXX
KEY_ID="$(basename "$P8" .p8)"
KEY_ID="${KEY_ID#AuthKey_}"
if ! [[ "$KEY_ID" =~ ^[A-Z0-9]{10}$ ]]; then
    echo "expected the key file to be named AuthKey_<10-char-key-id>.p8, got: $(basename "$P8")"
    exit 1
fi

if ! [[ "$ISSUER" =~ ^[0-9a-fA-F-]{36}$ ]]; then
    echo "the issuer id should be a uuid, got: $ISSUER"
    exit 1
fi

read -rsp "password for $(basename "$P12"): " P12_PASSWORD
echo

# Everything below feeds credentials in on stdin. The obvious spellings —
# `openssl -passin pass:...` and `gh secret set --body "$(base64 ...)"` — put the
# p12 password and the whole base64 private key into the process argument vector,
# where any process running as you can read them out of `ps` for as long as the
# upload takes.
read_p12() {
    # `-legacy` for RC2-encrypted p12s, which is what Keychain Access still
    # writes; the retry covers OpenSSL builds where the flag does not exist. A
    # pipe is consumed once, so the password is re-fed for the second attempt.
    printf '%s' "$P12_PASSWORD" | openssl pkcs12 -in "$P12" -passin stdin -nokeys -legacy >/dev/null 2>&1 ||
    printf '%s' "$P12_PASSWORD" | openssl pkcs12 -in "$P12" -passin stdin -nokeys >/dev/null 2>&1
}

# Fail here rather than on the runner, where the error is a keychain import
# failure fifteen minutes into a release.
if ! read_p12; then
    echo "could not read $P12 with that password"
    exit 1
fi

base64 -i "$P12" | gh secret set MACOS_CERTIFICATE_P12_BASE64 -R "$REPO" --body-file -
printf '%s' "$P12_PASSWORD" | gh secret set MACOS_CERTIFICATE_PASSWORD -R "$REPO" --body-file -
base64 -i "$P8"  | gh secret set AC_API_KEY_P8_BASE64 -R "$REPO" --body-file -

# Variables, not secrets. Both are public identifiers — Apple puts the key id in
# the filename it gives you — and registering them as secrets only makes Actions
# mask them to *** in notarytool's output, which is the one place you need to
# read them when a submission is rejected.
gh variable set AC_API_KEY_ID    -R "$REPO" --body "$KEY_ID"
gh variable set AC_API_ISSUER_ID -R "$REPO" --body "$ISSUER"

echo
echo "set. current secrets:"
gh secret list -R "$REPO"
echo
echo "current variables:"
gh variable list -R "$REPO"

cat <<EOF

Also store the notarization credentials locally, so 'make dist' works on this
Mac without the workflow:

    xcrun notarytool store-credentials freewhisper \\
      --key "$P8" --key-id "$KEY_ID" --issuer "$ISSUER"

Then run one release end to end before trusting CI:

    make dist
EOF
