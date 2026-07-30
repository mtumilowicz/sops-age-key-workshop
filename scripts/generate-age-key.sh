#!/usr/bin/env bash

set -euo pipefail

echo "Copy the age1... public key to the matching placeholder in .sops.yaml" >&2
echo "WORKSHOP ONLY: save and commit AGE-SECRET-KEY-... in keys/<name>.agekey" >&2
echo "Never commit an AGE private key used for real secrets." >&2
echo >&2

age-keygen
