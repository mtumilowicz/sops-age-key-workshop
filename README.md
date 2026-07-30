# SOPS + age key workshop

Technical workshop for protecting Kubernetes Secrets with
[SOPS](https://getsops.io/) and [age](https://age-encryption.org/).

> **LAB ONLY:** `k8s-secret.yaml` and both private identities are committed
> fixtures. This repository provides no confidentiality. Production Git must
> contain neither plaintext nor private identities.

## References

* [SOPS documentation](https://getsops.io/docs/)
* [SOPS configuration and encryption protocol](https://getsops.io/docs/reference/)
* [SOPS key management](https://getsops.io/docs/usage/key-management/)
* [age CLI documentation](https://github.com/FiloSottile/age)
* [Flux SOPS guide](https://fluxcd.io/flux/guides/mozilla-sops/)
* [Kubernetes Secrets](https://kubernetes.io/docs/concepts/configuration/secret/)

## Model

SOPS performs envelope encryption:

```text
random 256-bit data key
  -> AES-256-GCM encrypts each selected leaf
     - unique IV per leaf
     - key path used as authenticated additional data
  -> age encrypts the data key once per public recipient
  -> encrypted MAC authenticates all parsed data values by default
  -> ciphertext, wrapped data keys, MAC, and metadata are stored together
```

Core properties:

* SOPS keeps keys and unselected values readable; file names, YAML structure,
  public recipients, and Kubernetes metadata remain visible.
* A public X25519 recipient starts `age1...`; commit and distribute it.
* Its private identity starts `AGE-SECRET-KEY-...`; possession grants
  decryption and it must remain outside Git.
* Recipients in one `age:` list use OR semantics. Any matching identity
  unwraps the data key and decrypts the complete file.
* `key_groups` with `shamir_threshold` is the separate N-of-M mechanism.
* The encrypted MAC includes cleartext data values by default. Directly
  changing `metadata.name` therefore causes `MAC mismatch`.
* The MAC proves integrity, not authorship. An authorized identity can create a
  valid modified file; Git signatures and review provide attribution.
* SOPS protects data at rest in Git. Plaintext still exists in the editor,
  process memory, pipes, deployment API, and destination system.
* Kubernetes does not decrypt SOPS. Base64 in a Kubernetes Secret is encoding,
  not encryption.

SOPS loads age identities from `SOPS_AGE_KEY_FILE`, `SOPS_AGE_KEY`,
`SOPS_AGE_KEY_CMD`, or its platform-specific `keys.txt`. This workshop sets
`SOPS_AGE_KEY_FILE` explicitly.

## Policy

[`.sops.yaml`](./.sops.yaml) currently means:

* `path_regex: secret\.enc\.yaml`
  * matches any relative path containing `secret.enc.yaml`
  * matches `k8s-secret.enc.yaml`
* `encrypted_regex: ^(data|stringData)`
  * encrypts descendants of keys beginning with `data` or `stringData`
  * leaves `apiVersion`, `kind`, `metadata`, and `type` readable
* `age`
  * wraps one data key for the Flux and developer recipients
* top-level `keys`
  * is an undocumented YAML-anchor holder ignored by the SOPS config model
  * creates no threshold or AND semantics

Use anchored rules in production:

```yaml
creation_rules:
  - path_regex: '^k8s-secret\.enc\.yaml$'
    encrypted_regex: '^(data|stringData)$'
    age:
      - age1...
      - age1...
```

Creation rules are ordered; the first match wins. SOPS searches for
`.sops.yaml` from the current working directory upward, not from the target
file. Use `--config PATH` when necessary. YAML anchors may be used in the
config, but not inside a SOPS-encrypted YAML data document.

Existing files carry their recipients and encryption settings in `sops:`
metadata:

* `updatekeys` synchronizes recipient wrappers after policy membership changes;
  it retains the current data key.
* `rotate` creates a new data key and re-encrypts protected values.
* changing `encrypted_regex` requires re-encryption; `updatekeys` is
  insufficient.

## Files and requirements

| Path | Purpose |
| --- | --- |
| `.sops.yaml` | Public-recipient creation policy |
| `k8s-secret.yaml` | Tracked dummy plaintext; lab only |
| `k8s-secret.enc.yaml` | Encrypted fixture |
| `age-private-key/*.agekey` | Committed disposable identities; lab only |
| `scripts/generate-age-key.sh` | Generate an identity on stdout |
| `scripts/encrypt.sh` | Encrypt the dummy manifest |
| `scripts/decrypt.sh` | Decrypt the fixture to stdout |

Local requirements: Bash, `sops`, `age-keygen`, and an editor for `sops edit`.
Deployment scenarios additionally require `kubectl`; Flux requires installed
controllers and the Flux CLI.

```bash
# macOS installation and verification.
brew install sops age
sops --version
age-keygen --version
```

Verified with SOPS `3.13.3` and age `1.3.1`.

## Commands

| Command | Effect |
| --- | --- |
| `age-keygen -o PATH` | Create a mode-`0600` identity file; refuse overwrite; print its recipient to stderr |
| `age-keygen -y PATH` | Derive the public recipient from an identity |
| `./scripts/generate-age-key.sh` | Print a new identity to stdout and recipient to stderr |
| `./scripts/encrypt.sh` | Read lab plaintext and overwrite `k8s-secret.enc.yaml` |
| `./scripts/decrypt.sh [IDENTITY]` | Verify and print plaintext; default to the Flux fixture identity |
| `sops edit FILE` | Decrypt into an editor; re-encrypt and recalculate the MAC on save |
| `sops set --value-stdin FILE PATH` | Replace one value in place without placing it in SOPS arguments |
| `sops decrypt --extract PATH FILE` | Print one decrypted branch or value |
| `sops exec-file FILE 'COMMAND {}'` | Give one child process a decrypted FIFO or temporary file |
| `sops updatekeys --yes FILE` | Synchronize recipient wrappers without rotating the data key |
| `sops rotate --in-place FILE` | Generate a new data key and re-encrypt protected values |

`encrypt.sh` uses non-atomic shell redirection: failure can leave its output
empty. Always run `sops filestatus`, decrypt, and inspect `git diff`. Avoid
`sops decrypt --in-place`; it leaves plaintext on disk.

## Scenarios

### 1. Local secret lifecycle

Real use: author, verify, edit, and deploy an encrypted manifest.

```bash
export SOPS_AGE_KEY_FILE="$PWD/age-private-key/flux.agekey"

# Lab only: create ciphertext from the tracked dummy plaintext.
./scripts/encrypt.sh
sops filestatus k8s-secret.enc.yaml
./scripts/decrypt.sh

# Update one encrypted leaf. The literal is a dummy value.
printf '%s' '"rotated-demo-value"' |
  sops set --value-stdin k8s-secret.enc.yaml '["stringData"]["password"]'
sops decrypt --extract '["stringData"]["password"]' k8s-secret.enc.yaml
git diff -- k8s-secret.enc.yaml

# Optional: deploy through a pipe, without a persistent plaintext file.
sops decrypt k8s-secret.enc.yaml | kubectl apply -f -
kubectl -n default get secret example-application
```

Pipe real values from a secure source, not shell history. The deployment pipe
reduces disk exposure; it does not remove plaintext from memory or Kubernetes.

Tamper check:

```bash
cp k8s-secret.enc.yaml /tmp/tampered-secret.enc.yaml
sed -i.bak \
  's/name: example-application/name: tampered-application/' \
  /tmp/tampered-secret.enc.yaml
sops decrypt /tmp/tampered-secret.enc.yaml
# Expected: MAC mismatch. Discard the copy; never use --ignore-mac as repair.
```

### 2. Multiple recipients and revocation

Real use: a human and automation decrypt independently; offboarding removes
one principal. Run the revocation steps on a disposable branch.

```bash
# Equal hashes prove OR access to equal plaintext.
./scripts/decrypt.sh | shasum -a 256
./scripts/decrypt.sh age-private-key/mtumilowicz.agekey | shasum -a 256

# Remove "- *mtumilowicz_age_key" from creation_rules[0].age, then:
SOPS_AGE_KEY_FILE=age-private-key/flux.agekey \
  sops updatekeys --yes k8s-secret.enc.yaml

# Removed identity fails; remaining identity succeeds.
./scripts/decrypt.sh age-private-key/mtumilowicz.agekey
./scripts/decrypt.sh age-private-key/flux.agekey

# Replace the data key after access removal.
SOPS_AGE_KEY_FILE=age-private-key/flux.agekey \
  sops rotate --in-place k8s-secret.enc.yaml
```

Onboarding is the inverse: generate an identity outside Git, add only its
`age1...` recipient to the policy, then run `updatekeys` with an existing
identity. After compromise, also rotate the actual password, token, or
certificate. Old Git revisions and previously copied plaintext remain exposed.

### 3. Flux GitOps decryption

Lab simulation: production Git omits this repository's plaintext and identity
fixtures. Prerequisites:

* an authenticated, pushable remote
* an existing Flux `GitRepository` named by `$FLUX_SOURCE` in
  `$FLUX_NAMESPACE`
* that source tracks the pushed branch of this repository

Add a root `kustomization.yaml` that selects only ciphertext:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - k8s-secret.enc.yaml
```

Commit and push `.sops.yaml`, `k8s-secret.enc.yaml`, and
`kustomization.yaml`. Then create the decryption dependency and Flux
`Kustomization` in one namespace:

```bash
git add .sops.yaml k8s-secret.enc.yaml kustomization.yaml
git commit -m "add SOPS-encrypted application secret"
git push

export FLUX_NAMESPACE=flux-system
export FLUX_SOURCE=sops-age-workshop
export FLUX_KUSTOMIZATION=sops-age-workshop

# Idempotently inject the age identity. The source file is lab-only.
kubectl -n "$FLUX_NAMESPACE" create secret generic sops-age \
  --from-file=identity.agekey=age-private-key/flux.agekey \
  --dry-run=client -o yaml |
  kubectl apply -f -

# Idempotently create/update the Flux Kustomization with SOPS decryption.
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
  --namespace="$FLUX_NAMESPACE" --with-source
kubectl -n default get secret example-application
```

Flux fetches ciphertext, decrypts source manifests before the Kustomize build,
then validates and applies them. The bootstrap identity cannot depend on itself
for decryption; inject it out of band from an operator or secret manager.

## Production rules

* Commit encrypted files, public recipients, and policy only.
* Separate recipients by environment, cluster, and trust domain.
* Keep private identities in a secret manager or protected local storage.
* Avoid plaintext in arguments, logs, CI artifacts, editor swap, and Git
  history.
* Treat authorized decryption as disclosure; SOPS cannot retract copied data.
* On compromise: remove recipient, `updatekeys`, `rotate`, then rotate the
  underlying credential.
* Use Kubernetes RBAC and encryption at rest; SOPS protects Git, not runtime
  copies.
