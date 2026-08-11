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
        ```yaml
        age:
          - age1-alice
          - age1-flux
        ```
        * Alice can decrypt without Flux
        * Flux can decrypt without Alice
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

* definition
  * `.sops.yaml` is the repository's SOPS configuration file
  * it defines rules for creating and updating SOPS-encrypted files
  * it contains public recipients and selection rules
  * it must not contain private identities or plaintext secrets
* location
  * this repository stores the file at `./.sops.yaml`
* discovery
  * SOPS starts searching in the current working directory
  * it continues through each parent directory
  * it uses the first `.sops.yaml` found
  * it does not start the search from the encrypted file's directory
  * `--config PATH` selects a configuration file explicitly
  * the workshop scripts that run SOPS change to the repository root first
* purpose
  * `path_regex` selects files
  * `encrypted_regex` selects YAML fields
  * `age` defines which recipients may decrypt
  * SOPS uses the first matching `creation_rule`

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
    * here, “wraps” means
      * SOPS generates one data key for `k8s-secret.enc.yaml`
      * age encrypts one copy of that data key with the Flux public recipient
      * age encrypts another copy of the same data key with the developer public
        recipient
      * SOPS stores both encrypted copies in `k8s-secret.enc.yaml`:
    
        ```yaml
        sops:
          age:
            - recipient: age1-flux
              enc: <data key encrypted for Flux>
            - recipient: age1-developer
              enc: <same data key encrypted for the developer>
        ```
* top-level `keys`
  * holds YAML anchors
  * creates no access or threshold semantics
* creation rules
  * are evaluated in order; the first match wins
    * example: `k8s-secret.enc.yaml` matches both rules below, but SOPS uses only
      the first rule

      ```yaml
      creation_rules:
        - path_regex: '^k8s-'
          age:
            - age1-first
        - path_regex: 'secret'
          age:
            - age1-second
      ```

  * apply when `sops encrypt` creates a new encrypted file
  * the selected rule's recipients and field-selection setting are recorded in
    the new file's `sops` metadata; `path_regex` is not recorded
  * changing `.sops.yaml` later does not rewrite that existing file
    * `updatekeys` explicitly applies recipient changes
    * decrypting and creating the encrypted file again explicitly applies a new
      field-selection setting

Use complete matches in production:

```yaml
creation_rules:
  - path_regex: '^k8s-secret\.enc\.yaml$'
    encrypted_regex: '^(data|stringData)$'
    age:
      - age1...
      - age1...
```

* complete match
  * `^` requires the match to start at the beginning
  * `$` requires the match to end at the end
* path example
  * `secret\.enc\.yaml` matches both `k8s-secret.enc.yaml` and
    `backup-k8s-secret.enc.yaml.tmp`
  * `^k8s-secret\.enc\.yaml$` matches only `k8s-secret.enc.yaml`
* YAML-key example
  * `^(data|stringData)` matches `data`, `database`, `stringData`, and
    `stringDatabase`
  * `^(data|stringData)$` matches only `data` and `stringData`

Existing files retain their recipients and encryption settings in `sops`
metadata:

```yaml
# Stored inside k8s-secret.enc.yaml
sops:
  age:
    - recipient: age1-flux
      enc: <encrypted data-key copy>
    - recipient: age1-developer
      enc: <encrypted data-key copy>
  encrypted_regex: ^(data|stringData)
```

* this embedded metadata records the recipients and field-selection setting
  actually used for `k8s-secret.enc.yaml`
* `sops decrypt` and `sops edit` read this metadata from the encrypted file
* editing `.sops.yaml` alone does not change this embedded metadata
* `sops updatekeys`
  * reads the recipients from the first matching rule in `.sops.yaml`
  * makes the `sops.age` recipient entries in the encrypted file equal to that
    list
  * example: after removing the developer from `.sops.yaml`

    ```yaml
    # Before updatekeys: stored in k8s-secret.enc.yaml
    sops:
      age:
        - recipient: age1-flux
          enc: <encrypted data-key copy>
        - recipient: age1-developer
          enc: <encrypted data-key copy>

    # After updatekeys: stored in k8s-secret.enc.yaml
    sops:
      age:
        - recipient: age1-flux
          enc: <encrypted data-key copy>
    ```

  * requires an existing authorized private identity to recover the data key
  * retains the current data key
  * does not change which YAML fields are encrypted
* `sops rotate`
  * creates a new data key
  * re-encrypts protected values
* changing `encrypted_regex`
  * changing it in `.sops.yaml` affects new encryption operations
  * example:

    ```yaml
    # Changed policy in .sops.yaml
    encrypted_regex: '^stringData$'

    # Existing k8s-secret.enc.yaml remains unchanged
    sops:
      encrypted_regex: ^(data|stringData)
    ```

  * `updatekeys` changes recipients, not field selection
  * `rotate` replaces the data key but keeps the file's field selection
  * applying the new regex requires decrypting and creating the encrypted file
    again

### Recipient-change security

* adding an attacker's public recipient to `.sops.yaml` does not grant access to
  an existing encrypted file
  * the file retains its original recipients in `sops.age`
  * `.sops.yaml` does not contain the file's data key
* granting the new recipient access requires `sops updatekeys`
  * SOPS must first use an authorized private identity to recover the existing
    data key
  * SOPS then encrypts a new copy of that data key for the new recipient
  * without an authorized identity, an attacker cannot create a valid encrypted
    copy of the existing data key
* replacing the complete encrypted file does not reveal its original plaintext
  * it can still replace deployed content if the malicious change is accepted
* an attacker succeeds by compromising
  * an authorized private identity
  * CI that holds an identity and processes untrusted recipient changes
  * the repository review or approval process
* controls
  * require review for `.sops.yaml` and encrypted files
  * do not expose private identities to untrusted CI jobs
  * do not run `updatekeys` for untrusted changes
  * validate recipients against an allowlist
  * protect deployment branches and pipelines

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
