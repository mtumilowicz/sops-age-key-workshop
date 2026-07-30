#!/usr/bin/env bash

cd "$(dirname "$0")/.."

SOPS_AGE_KEY_FILE="${1:-keys/flux.agekey}" sops decrypt k8s-secret.enc.yaml
