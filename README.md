# SOPS age key workshop

A focused workshop for encrypting Kubernetes Secrets with
[SOPS](https://github.com/getsops/sops) and
[age](https://age-encryption.org/). It demonstrates multiple recipients, local
encryption and decryption, and the way Flux obtains an age private identity.

> **Workshop only:** The AGE private identities under `keys/` are intentionally
> committed so every participant can decrypt the example. Never commit private
> identities used to protect real secrets.

## Requirements

* `age-keygen`
* `sops`

## Core idea

SOPS encrypts secret values before a Kubernetes manifest enters Git while
leaving structural fields such as `apiVersion`, `kind`, and `metadata`
readable. In this example, `.sops.yaml` selects only `data` and `stringData`:

```yaml
encrypted_regex: ^(data|stringData)
```

Kubernetes does not understand or decrypt SOPS files. Without Flux, a person or
script must decrypt before applying:

```text
encrypted Git file
  -> sops decrypt
  -> plaintext Kubernetes Secret
  -> kubectl apply
```

With Flux, the cluster reconciles the encrypted Git state:

```text
encrypted Git file
  -> Flux source-controller fetches Git
  -> Flux kustomize-controller decrypts with SOPS
  -> Flux applies the plaintext Secret
  -> kubelet mounts the Secret into the pod
  -> the application reads the mounted configuration
```

## Project layout

```text
.sops.yaml                    SOPS creation rule and AGE recipients
k8s-secret.yaml               plaintext workshop Secret, ignored by Git
k8s-secret.enc.yaml           encrypted Secret committed to Git
keys/                         committed workshop-only AGE private identities
scripts/generate-age-key.sh   print a new AGE key pair
scripts/encrypt.sh            encrypt the example Secret
scripts/decrypt.sh            print the decrypted Secret
```

## Generate AGE keys

Generate and save two identities:

```bash
mkdir -p keys
chmod 700 keys
(umask 077; ./scripts/generate-age-key.sh > keys/flux.agekey)
(umask 077; ./scripts/generate-age-key.sh > keys/mtumilowicz.agekey)
```

Print their public recipients:

```bash
age-keygen -y keys/flux.agekey
age-keygen -y keys/mtumilowicz.agekey
```

An `age1...` value is a public recipient and belongs in `.sops.yaml`. An
`AGE-SECRET-KEY-...` value is a private identity used for decryption.

## Multiple recipients

`.sops.yaml` names both public recipients with YAML anchors:

```yaml
keys:
  flux_age_key: &flux_age_key age1...
  mtumilowicz_age_key: &mtumilowicz_age_key age1...

creation_rules:
  - path_regex: secret\.enc\.yaml
    encrypted_regex: ^(data|stringData)
    age:
      - *flux_age_key
      - *mtumilowicz_age_key
```

SOPS generates one random data key for the document and wraps that data key for
each recipient. Either matching private identity can therefore decrypt the
same file; both identities are not required at the same time.

To add a developer, add only their public recipient to the appropriate policy
and re-encrypt the file so SOPS creates a recipient block for that key:

```bash
sops decrypt --in-place k8s-secret.enc.yaml
sops encrypt --in-place k8s-secret.enc.yaml
```

Do not add a developer key to a production policy unless that developer should
also be able to decrypt production secrets.

## Encrypt and decrypt

Replace the public recipients in `.sops.yaml`, then encrypt:

```bash
./scripts/encrypt.sh
```

The script reads `k8s-secret.yaml` and writes `k8s-secret.enc.yaml`.
`--filename-override` makes SOPS evaluate the creation rule against the
encrypted filename:

```bash
sops encrypt --filename-override k8s-secret.enc.yaml \
  k8s-secret.yaml > k8s-secret.enc.yaml
```

Decrypt with the default Flux identity:

```bash
./scripts/decrypt.sh
```

Prove that the second identity can decrypt the same file:

```bash
./scripts/decrypt.sh keys/mtumilowicz.agekey
```

Decryption prints YAML to standard output. Redirect it only when a plaintext
file is needed:

```bash
./scripts/decrypt.sh > k8s-secret.decrypted.yaml
```

## Editing encrypted files

SOPS encrypts only fields selected by `encrypted_regex`, but its MAC
authenticates the whole YAML document by default. Directly changing a readable
field such as `metadata.name` invalidates the MAC and causes:

```text
MAC mismatch. File has ..., computed ...
```

The companion Spring Boot workshop hit this case when `metadata.name` was
changed directly in encrypted manifests. The ciphertext remained decryptable
with the correct identity, but SOPS rejected the authenticated document.

Open a SOPS file through SOPS when editing:

```bash
sops k8s-secret.enc.yaml
```

SOPS opens decrypted content in an editor and writes it back encrypted.

`--in-place` replaces the file on disk:

```bash
sops decrypt --in-place k8s-secret.enc.yaml
sops encrypt --in-place k8s-secret.enc.yaml
```

Without `--in-place`, decrypted content is printed without modifying the file:

```bash
sops decrypt k8s-secret.enc.yaml
```

## Flux decryption

Flux does not read an AGE key file directly during reconciliation. A Flux
`Kustomization` references a Kubernetes Secret in the `flux-system` namespace:

```yaml
spec:
  decryption:
    provider: sops
    secretRef:
      name: k8s-plain-secrets-dev
```

The referenced Secret contains the private identity:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: k8s-plain-secrets-dev
  namespace: flux-system
stringData:
  identity.agekey: |
    AGE-SECRET-KEY-...
```

When Kubernetes accepts `stringData`, it converts it to base64-encoded `data`.
Base64 is encoding, not encryption.

The bootstrap Secret cannot require the same SOPS identity to decrypt itself.
For this workshop it is committed as plaintext bootstrap YAML:

```text
kubectl applies the plaintext bootstrap Secret
  -> Kubernetes stores flux-system/k8s-plain-secrets-dev
  -> Flux reads identity.agekey
  -> Flux decrypts the SOPS-encrypted application Secret
```

That is deliberately insecure but avoids a bootstrap cycle. In a real system,
commit only public recipients and encrypted application secrets. Common
private-identity delivery options are:

* create the Flux AGE Secret during cluster bootstrap from an operator machine
* inject it from AWS Secrets Manager, Azure Key Vault, Google Secret Manager,
  or HashiCorp Vault
* let a platform bootstrap process create it before Flux reconciliation starts
* use separate identities per environment or cluster

Use separate AGE identities for different environments or clusters:

```text
dev public key  -> dev .sops.yaml
prod public key -> prod .sops.yaml
```

This prevents a dev identity from decrypting production secrets.

## Companion Spring Boot workshop

The `spring-boot-k8s-gitops-flux-sops-workshop` repository uses separate dev
and prod policies:

```text
gitops/overlays/dev/.sops.yaml
gitops/overlays/prod/.sops.yaml
```

Its encrypted application Secret has this shape:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: spring-boot-k8s-gitops-flux-sops-workshop-config
type: Opaque
stringData:
  application.yml: ENC[...]
sops:
  ...
```

After Flux decrypts and applies it, Kubernetes mounts `application.yml` at
`/config/application.yml`, where Spring Boot reads `demo.token1` and
`demo.token2`.

Its Flux bootstrap Secrets are:

```text
gitops/clusters/dev/flux-sops-age-key-bootstrap.yaml
gitops/clusters/prod/flux-sops-age-key-bootstrap.yaml
```

They create these identities for Flux:

```text
namespace: flux-system
name: k8s-plain-secrets-dev
key: identity.agekey

namespace: flux-system
name: k8s-plain-secrets-prod
key: identity.agekey
```

The complete workshop bootstrap flow is:

```text
dev AGE private identity
  -> gitops/clusters/dev/flux-sops-age-key-bootstrap.yaml
prod AGE private identity
  -> gitops/clusters/prod/flux-sops-age-key-bootstrap.yaml
  -> kubectl apply -k gitops/clusters/dev
  -> kubectl apply -k gitops/clusters/prod
  -> Kubernetes stores both flux-system key Secrets
  -> Flux decrypts gitops/overlays/dev/secret.enc.yaml
  -> Flux decrypts gitops/overlays/prod/secret.enc.yaml
```

The companion commands are:

```bash
# Print separate dev and prod key pairs.
scripts/generate-workshop-age-keys.sh

# Encrypt both overlay Secrets in place.
scripts/encrypt-workshop-secrets.sh

# Print both decrypted overlay Secrets.
scripts/decrypt-workshop-secrets.sh
```

The encrypted files are:

```text
gitops/overlays/dev/secret.enc.yaml
gitops/overlays/prod/secret.enc.yaml
```

Commit and push the public-key policies, Flux bootstrap material used by this
workshop, and encrypted files before running its integration test.

## References

* [SOPS project](https://github.com/getsops/sops)
* [age project](https://age-encryption.org/)
* [Flux SOPS guide](https://fluxcd.io/flux/guides/mozilla-sops/)
* [Flux Kustomization decryption](https://fluxcd.io/flux/components/kustomize/kustomizations/#decryption)
* [Kubernetes Secrets](https://kubernetes.io/docs/concepts/configuration/secret/)
