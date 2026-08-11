# SOPS and age key workshop

Technical workshop for encrypting Kubernetes Secrets in Git with
[SOPS](https://getsops.io/) and [age](https://age-encryption.org/).

> **Lab only:** this repository intentionally contains a plaintext Secret and
> two private age identities. They protect no real data. Never commit plaintext
> secrets or production private identities.

## References

* [SOPS documentation](https://getsops.io/docs/)
* [SOPS configuration and encryption protocol](https://getsops.io/docs/reference/)
* [SOPS key management](https://getsops.io/docs/usage/key-management/)
* [age CLI documentation](https://github.com/FiloSottile/age)
* [Flux SOPS guide](https://fluxcd.io/flux/guides/mozilla-sops/)
* [Kubernetes Secrets](https://kubernetes.io/docs/concepts/configuration/secret/)

## Purpose

The exercises demonstrate how to:

* encrypt selected values while keeping a Kubernetes manifest readable
* decrypt and edit a SOPS file with an age identity
* grant and revoke access through multiple recipients
* rotate the SOPS data key after access changes
* let Flux decrypt manifests before applying them to Kubernetes

## Core concepts

### SOPS encryption

SOPS generates a random data key and uses it to encrypt selected values with
AES-256-GCM. It then encrypts that data key for every configured age recipient.
The encrypted values, wrapped data keys, integrity MAC, and encryption metadata
are stored together in the YAML document.

This keeps the document structure readable. In this workshop, fields such as
`apiVersion`, `kind`, `metadata`, and `type` remain plaintext while values below
`data` and `stringData` are encrypted.

The encrypted MAC detects changes to the parsed document, including plaintext
values. For example, manually changing `metadata.name` causes decryption to fail
with a MAC mismatch.

### age identities and recipients

An age key pair has two parts:

* a public recipient beginning with `age1`; it may be committed and shared
* a private identity beginning with `AGE-SECRET-KEY-`; it grants decryption
  access and must normally remain outside Git

When a file has several recipients, each matching identity can decrypt the
complete file. This is OR access, not an N-of-M threshold.

### Protection boundary

SOPS protects secrets stored in Git. Plaintext still exists when it is
decrypted in an editor, process, pipe, Kubernetes API, or target cluster.

Kubernetes Secret values are base64 encoded, not encrypted. SOPS encryption and
Kubernetes runtime protections solve different problems.

## Configuration

[`.sops.yaml`](./.sops.yaml) defines the creation policy:

```yaml
keys:
  flux_age_key: &flux_age_key age1...
  developer_age_key: &developer_age_key age1...

creation_rules:
  - path_regex: secret\.enc\.yaml
    encrypted_regex: ^(data|stringData)
    age:
      - *flux_age_key
      - *developer_age_key
```

The rule:

* matches `k8s-secret.enc.yaml`
* encrypts descendants of keys beginning with `data` or `stringData`
* wraps one data key for both age recipients

The top-level `keys` mapping only holds YAML anchors. It does not create access
rules. SOPS uses the first matching creation rule.

Creation rules apply when a file is encrypted. Existing encrypted files retain
their recipients and settings in their `sops` metadata:

* `sops updatekeys` synchronizes recipients with `.sops.yaml`
* `sops rotate` creates a new data key and re-encrypts protected values

For production, anchor regular expressions to the intended complete path and
field names.

## Exercise 1: Encrypt and decrypt a Secret

Requirements: Bash, `sops`, and `age-keygen`.

On macOS:

```bash
brew install sops age
sops --version
age-keygen --version
```

The input is [`k8s-secret.yaml`](./k8s-secret.yaml). It contains dummy plaintext
for the workshop. The encryption script writes
[`k8s-secret.enc.yaml`](./k8s-secret.enc.yaml):

```bash
./scripts/encrypt.sh
sops filestatus k8s-secret.enc.yaml
```

Inspect the encrypted file. Its Kubernetes structure and public recipients are
visible, but values below `stringData` are encrypted.

Decrypt it with the default Flux fixture identity:

```bash
./scripts/decrypt.sh
```

Decrypt it with the developer fixture identity:

```bash
./scripts/decrypt.sh age-private-key/mtumilowicz.agekey
```

Both commands produce the same plaintext because either recipient can unwrap
the data key.

SOPS also reads age identities from `SOPS_AGE_KEY_FILE`. Set it explicitly when
using SOPS commands directly:

```bash
export SOPS_AGE_KEY_FILE="$PWD/age-private-key/flux.agekey"
sops decrypt k8s-secret.enc.yaml
```

## Exercise 2: Edit encrypted values

Use an editor through SOPS:

```bash
sops edit k8s-secret.enc.yaml
```

SOPS decrypts the document for the editor. On save, it encrypts protected
values again and recalculates the MAC.

To update one value without opening an editor:

```bash
printf '%s' '"rotated-demo-value"' |
  sops set --value-stdin k8s-secret.enc.yaml \
  '["stringData"]["password"]'
```

Verify the result without writing a plaintext file:

```bash
sops decrypt --extract \
  '["stringData"]["password"]' \
  k8s-secret.enc.yaml

git diff -- k8s-secret.enc.yaml
```

Pass real values through a secure input source. Do not place them in command
arguments or shell history.

## Exercise 3: Detect tampering

Create a disposable copy and change a plaintext field without using SOPS:

```bash
cp k8s-secret.enc.yaml /tmp/tampered-secret.enc.yaml
sed -i.bak \
  's/name: example-application/name: tampered-application/' \
  /tmp/tampered-secret.enc.yaml
sops decrypt /tmp/tampered-secret.enc.yaml
```

Expected result: decryption fails with a MAC mismatch. Do not use
`--ignore-mac` as a repair mechanism.

The MAC proves document integrity. It does not prove who changed the document.
Use Git review and signing when authorship matters.

## Exercise 4: Revoke a recipient

Perform this exercise only on a disposable branch.

First, remove `*mtumilowicz_age_key` from `creation_rules[0].age` in
`.sops.yaml`. Then synchronize the encrypted file with the remaining recipient:

```bash
SOPS_AGE_KEY_FILE=age-private-key/flux.agekey \
  sops updatekeys --yes k8s-secret.enc.yaml
```

Confirm that the removed identity fails and the remaining identity succeeds:

```bash
./scripts/decrypt.sh age-private-key/mtumilowicz.agekey
./scripts/decrypt.sh age-private-key/flux.agekey
```

Replace the data key after removing access:

```bash
SOPS_AGE_KEY_FILE=age-private-key/flux.agekey \
  sops rotate --in-place k8s-secret.enc.yaml
```

`updatekeys` changes the wrapped recipient copies of the existing data key.
`rotate` replaces that data key. Neither operation revokes plaintext or keys
already copied from Git history.

To grant access, generate an identity outside Git, add only its `age1...`
recipient to `.sops.yaml`, and run `updatekeys` with an existing identity:

```bash
./scripts/generate-age-key.sh
```

The script prints the private identity to stdout and its public recipient to
stderr. Redirect the identity only to protected storage.

## Exercise 5: Deploy with Flux

Requirements:

* Flux controllers and CLI
* an authenticated Git remote
* an existing Flux `GitRepository` source for this repository

Production Git must contain only the encrypted manifest, public recipients, and
SOPS policy. It must not contain this workshop's plaintext manifest or private
identities.

Create a root `kustomization.yaml` that selects only the encrypted manifest:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - k8s-secret.enc.yaml
```

Inject the Flux age identity into the cluster. The source file below is a
committed fixture and is suitable only for this lab:

```bash
export FLUX_NAMESPACE=flux-system
export FLUX_SOURCE=sops-age-workshop
export FLUX_KUSTOMIZATION=sops-age-workshop

kubectl -n "$FLUX_NAMESPACE" create secret generic sops-age \
  --from-file=identity.agekey=age-private-key/flux.agekey \
  --dry-run=client -o yaml |
  kubectl apply -f -
```

Create or update the Flux `Kustomization`:

```bash
flux create kustomization "$FLUX_KUSTOMIZATION" \
  --namespace="$FLUX_NAMESPACE" \
  --source="GitRepository/$FLUX_SOURCE" \
  --path="./" \
  --prune=true \
  --interval=1m \
  --decryption-provider=sops \
  --decryption-secret=sops-age \
  --export |
  kubectl apply -f -

flux reconcile kustomization "$FLUX_KUSTOMIZATION" \
  --namespace="$FLUX_NAMESPACE" \
  --with-source
```

Flux decrypts source manifests before the Kustomize build and applies the
result. The decryption identity must be injected independently; it cannot be
bootstrapped from a manifest encrypted with itself.

## Production guidance

* Commit encrypted files, public recipients, and SOPS policy only.
* Keep private identities in a secret manager or protected local storage.
* Separate recipients by environment, cluster, and trust boundary.
* Prevent plaintext from entering logs, CI artifacts, editor swap, and Git
  history.
* After compromise, remove the recipient, run `updatekeys`, rotate the SOPS
  data key, and rotate the underlying credential.
* Use Kubernetes RBAC and encryption at rest. SOPS does not protect runtime
  copies.
