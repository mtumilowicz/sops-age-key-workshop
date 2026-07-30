#!/usr/bin/env bash

cd "$(dirname "$0")/.."

sops encrypt --filename-override k8s-secret.enc.yaml \
  k8s-secret.yaml > k8s-secret.enc.yaml
