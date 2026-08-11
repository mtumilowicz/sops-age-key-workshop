# SOPS and age key workshop

## References

* [SOPS documentation](https://getsops.io/docs/)
* [SOPS configuration and encryption protocol](https://getsops.io/docs/reference/)
* [SOPS key management](https://getsops.io/docs/usage/key-management/)
* [age CLI documentation](https://github.com/FiloSottile/age)
* [Flux SOPS guide](https://fluxcd.io/flux/guides/mozilla-sops/)
* [Kubernetes Secrets](https://kubernetes.io/docs/concepts/configuration/secret/)

## Workshop warning

* this repository intentionally commits
  * dummy plaintext in `k8s-secret.yaml`
  * disposable private identities in `age-private-key/`
* the committed identities provide no confidentiality
* production Git must contain neither plaintext secrets nor private identities

## SOPS and age

* SOPS
  * encrypts selected values while preserving the document structure
  * generates a random 256-bit data key
  * encrypts selected leaves with AES-256-GCM
  * stores ciphertext, wrapped data keys, an encrypted MAC, and metadata in the
    source document
* age
  * encrypts the SOPS data key for each configured recipient
  * public recipient
    * starts with `age1`
    * may be committed and distributed
  * private identity
    * starts with `AGE-SECRET-KEY-`
    * grants decryption access
    * must normally remain outside Git
* how SOPS and age work together
  * SOPS generates one random symmetric data key
    * symmetric means the same key encrypts and decrypts data
  * SOPS uses the data key to encrypt the selected YAML values
    * SOPS reads `encrypted_regex` from the matching rule in `.sops.yaml`
    * this workshop uses `^(data|stringData)`
    * SOPS therefore encrypts values below keys beginning with `data` or
      `stringData`
    * values below `metadata` are not selected
  * age encrypts the data key with each recipient's public key (`age1...`)
  * the file stores
    * encrypted YAML values in their original fields, such as
      `stringData.password`
    * one encrypted copy of the data key for each recipient in a separate
      `sops.age[].enc` block, for example:

      ```yaml
      sops:
        age:
          - recipient: age1deeq9...
            enc: |
              -----BEGIN AGE ENCRYPTED FILE-----
              YWdlLWVuY3J5cHRpb24ub3JnL3Yx...
              -----END AGE ENCRYPTED FILE-----
      ```
* decryption
  * age needs a matching private identity (`AGE-SECRET-KEY-...`)
  * age uses the private identity to decrypt the data key
  * SOPS uses the recovered data key to decrypt the YAML values

Example before encryption:

```yaml
metadata:
  name: example-application # not selected
stringData:                 # matches encrypted_regex
  username: demo-user       # selected
  password: demo-value      # selected
```

Abbreviated result from `k8s-secret.enc.yaml`:

```yaml
metadata:
  name: example-application
stringData:
  password: ENC[AES256_GCM,data:XtOo6CeeOqr1gw==,...]
sops:
  age:
    - recipient: age1deeq9...
      enc: |
        -----BEGIN AGE ENCRYPTED FILE-----
        YWdlLWVuY3J5cHRpb24ub3JnL3Yx...
        -----END AGE ENCRYPTED FILE-----
    - recipient: age1an9w...
      enc: |
        -----BEGIN AGE ENCRYPTED FILE-----
        YWdlLWVuY3J5cHRpb24ub3JnL3Yx...
        -----END AGE ENCRYPTED FILE-----
  encrypted_regex: ^(data|stringData)
  mac: ENC[AES256_GCM,data:W6JZXuZzS1vrtqBA,...]
```

* `sops.age[].enc`
  * each `enc` block is one encrypted copy of the same data key
  * each copy is encrypted with the public key in its `recipient`
  * can be decrypted only with the matching private identity
  * does not contain the YAML values
  * the copies differ because they use different recipients and encryption
    randomness
* `sops.mac`
  * is an integrity check calculated from the document values
  * is encrypted with the data key
  * is recalculated during decryption and compared with the stored value
  * reports a MAC mismatch when a value was changed, added, or removed without
    valid re-encryption
  * can be replaced with a valid new MAC by anyone who has a matching private
    identity
* multiple recipients
  * recipients in one `age` list have OR semantics
    * example: two-recipient list is therefore 1-of-2 access
        ```
        ```
  * any matching identity can decrypt the complete document
  * N-of-M access requires `key_groups` and `shamir_threshold`, for example:
    * example
        ```yaml
        key_groups:
          - age:
              - age1-alice
          - age:
              - age1-flux
          - age:
              - age1-recovery
        shamir_threshold: 2
        ```
      
        * SOPS splits the data key into three shares
        * shares from any two groups are required
        * valid combinations are Alice and Flux, Alice and Recovery, or Flux and
          Recovery
        * the threshold counts groups, not individual identities
        * when one group contains several identities, any one of them can recover
          that group's share
* integrity
  * the encrypted MAC covers encrypted and plaintext data values by default
  * changing plaintext such as `metadata.name` causes a MAC mismatch
  * the MAC proves integrity, not authorship
    * anyone with a matching age identity can change the file and create a new
      valid MAC
  * signed commits or tags provide cryptographic attribution
    * verify that the Git object was signed by the holder of a trusted signing
      key
    * detect changes made to that object after signing
    * do not prove that the signed change is correct or safe
* protection boundary
  * SOPS protects data stored in Git
  * plaintext still exists in editors, process memory, pipes, deployment APIs,
    and target systems
  * Kubernetes Secret values use base64 encoding, not encryption

## SOPS policy

Current [`.sops.yaml`](./.sops.yaml):

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

* `path_regex: secret\.enc\.yaml`
  * matches relative paths containing `secret.enc.yaml`
  * therefore matches `k8s-secret.enc.yaml`
* `encrypted_regex: ^(data|stringData)`
  * encrypts descendants of keys beginning with `data` or `stringData`
  * leaves `apiVersion`, `kind`, `metadata`, and `type` readable
* `age`
  * wraps one data key for the Flux and developer recipients
* top-level `keys`
  * holds YAML anchors
  * creates no access or threshold semantics
* creation rules
  * are evaluated in order; the first match wins
  * apply when a file is created
  * do not automatically update existing encrypted files

Use complete matches in production:

```yaml
creation_rules:
  - path_regex: '^k8s-secret\.enc\.yaml$'
    encrypted_regex: '^(data|stringData)$'
    age:
      - age1...
      - age1...
```

Existing files retain their recipients and encryption settings in `sops`
metadata:

* `sops updatekeys`
  * synchronizes recipient wrappers with `.sops.yaml`
  * retains the current data key
* `sops rotate`
  * creates a new data key
  * re-encrypts protected values
* changing `encrypted_regex`
  * requires re-encryption
  * is not handled by `updatekeys`

## Local operations

Requirements: Bash, `sops`, and an editor for `sops edit`.

```bash
brew install sops age
sops --version
age-keygen --version
```

* encrypt the dummy manifest
  * `scripts/encrypt.sh` reads `k8s-secret.yaml`
  * it overwrites `k8s-secret.enc.yaml`
  * its shell redirection is not atomic; an encryption failure can leave the
    output empty
  * always verify the result

    ```bash
    ./scripts/encrypt.sh
    sops filestatus k8s-secret.enc.yaml
    ./scripts/decrypt.sh
    git diff -- k8s-secret.enc.yaml
    ```

* decrypt with the default Flux fixture identity

    ```bash
    ./scripts/decrypt.sh
    ```

* decrypt with the developer fixture identity

    ```bash
    ./scripts/decrypt.sh age-private-key/mtumilowicz.agekey
    ```

* use SOPS directly
  * the workshop sets `SOPS_AGE_KEY_FILE` explicitly

    ```bash
    export SOPS_AGE_KEY_FILE="$PWD/age-private-key/flux.agekey"
    sops decrypt k8s-secret.enc.yaml
    ```

* edit through SOPS
  * SOPS decrypts the document for the editor
  * saving re-encrypts protected values and recalculates the MAC

    ```bash
    sops edit k8s-secret.enc.yaml
    ```

* update one encrypted value
  * pipe real values from a secure source
  * do not place them in arguments or shell history

    ```bash
    printf '%s' '"rotated-demo-value"' |
      sops set --value-stdin k8s-secret.enc.yaml \
      '["stringData"]["password"]'

    sops decrypt --extract \
      '["stringData"]["password"]' \
      k8s-secret.enc.yaml
    ```

* detect tampering

    ```bash
    cp k8s-secret.enc.yaml /tmp/tampered-secret.enc.yaml
    sed -i.bak \
      's/name: example-application/name: tampered-application/' \
      /tmp/tampered-secret.enc.yaml
    sops decrypt /tmp/tampered-secret.enc.yaml
    ```

  * expected result: `MAC mismatch`
  * discard the copy
  * never use `--ignore-mac` as a repair mechanism

Avoid `sops decrypt --in-place`; it writes plaintext to disk.

## Recipient lifecycle

* generate an identity
  * requires `age-keygen`
  * redirect stdout to protected storage because it contains the private
    identity
  * the public recipient is printed to stderr

    ```bash
    ./scripts/generate-age-key.sh > /protected/path/developer.agekey
    ```

  * add only the resulting `age1...` recipient to `.sops.yaml`
  * run `updatekeys` with an existing identity
* remove an identity
  * perform these commands only on a disposable branch
  * remove `*mtumilowicz_age_key` from `creation_rules[0].age`
  * synchronize the recipient wrappers

    ```bash
    SOPS_AGE_KEY_FILE=age-private-key/flux.agekey \
      sops updatekeys --yes k8s-secret.enc.yaml
    ```

  * verify access

    ```bash
    ./scripts/decrypt.sh age-private-key/mtumilowicz.agekey
    ./scripts/decrypt.sh age-private-key/flux.agekey
    ```

  * the removed identity must fail
  * the remaining identity must succeed
  * replace the data key after access removal

    ```bash
    SOPS_AGE_KEY_FILE=age-private-key/flux.agekey \
      sops rotate --in-place k8s-secret.enc.yaml
    ```

* revocation limits
  * recipient removal does not erase old Git revisions
  * rotation does not retract copied plaintext
  * after compromise, also rotate the underlying password, token, or
    certificate

## Flux decryption

Requirements:

* `kubectl`
* Flux controllers and CLI
* an authenticated, pushable Git remote
* an existing Flux `GitRepository` source for this repository

Production Git contains the SOPS policy, public recipients, and encrypted
manifest. It omits the workshop plaintext and private identity fixtures.

* select only the encrypted manifest in a root `kustomization.yaml`

    ```yaml
    apiVersion: kustomize.config.k8s.io/v1beta1
    kind: Kustomization
    resources:
      - k8s-secret.enc.yaml
    ```

* commit and push the source files

    ```bash
    git add .sops.yaml k8s-secret.enc.yaml kustomization.yaml
    git commit -m "add SOPS-encrypted application secret"
    git push
    ```

* inject the age identity independently
  * the committed source below is suitable only for this lab
  * production identities come from an operator or secret manager

    ```bash
    export FLUX_NAMESPACE=flux-system
    export FLUX_SOURCE=sops-age-workshop
    export FLUX_KUSTOMIZATION=sops-age-workshop

    kubectl -n "$FLUX_NAMESPACE" create secret generic sops-age \
      --from-file=identity.agekey=age-private-key/flux.agekey \
      --dry-run=client -o yaml |
      kubectl apply -f -
    ```

* create or update the Flux `Kustomization`

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

    kubectl -n default get secret example-application
    ```

Flux decrypts source manifests before the Kustomize build. The bootstrap
identity cannot depend on a manifest encrypted with itself.

## Production rules

* commit encrypted files, public recipients, and policy only
* separate recipients by environment, cluster, and trust boundary
* keep private identities in a secret manager or protected local storage
* prevent plaintext from entering arguments, logs, CI artifacts, editor swap,
  and Git history
* use Kubernetes RBAC and encryption at rest; SOPS does not protect runtime
  copies
