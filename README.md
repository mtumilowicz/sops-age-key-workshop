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
  * terminology
    * recipient
      * public key beginning with `age1...`
      * used to encrypt the SOPS data key
      * may be committed and distributed
    * identity
      * private key beginning with `AGE-SECRET-KEY-...`
      * matches one recipient
      * used to decrypt the SOPS data key
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
    * each rule defines both which file paths it matches and which public
      recipients receive encrypted copies of the file's data key
    * example: a specific production rule followed by a general fallback rule

      ```yaml
      creation_rules:
        # Specific production rule.
        - path_regex: '^production/'
          age:
            - *flux_age_key

        # General fallback rule.
        - path_regex: '.*'
          age:
            - *mtumilowicz_age_key
      ```

      * `production/k8s-secret.enc.yaml` matches both rules
      * SOPS stops at the first rule and uses only `*flux_age_key`
      * Flux can decrypt the production file
      * the developer fallback recipient cannot decrypt it

  * apply when `sops encrypt` creates a new encrypted file
  * the selected rule's recipients and field-selection setting are recorded in
    the new file's `sops` metadata, for example:

    ```yaml
    # Stored inside k8s-secret.enc.yaml
    sops:
      age:
        - recipient: age1deeq9...
          enc: <data key encrypted for this recipient>
        - recipient: age1an9w...
          enc: <same data key encrypted for this recipient>
      encrypted_regex: ^(data|stringData)
      lastmodified: "2026-07-30T18:26:29Z"
      mac: ENC[AES256_GCM,data:W6JZXuZzS1vrtqBA,...]
      version: 3.13.3
    ```

    * `age` records the actual recipients and an encrypted data-key copy for
      each recipient
    * `encrypted_regex` records the field-selection setting actually used
    * `lastmodified` records when SOPS last encrypted the file
    * `mac` stores the encrypted integrity check
    * `version` records the SOPS version that wrote the file
    * `path_regex` is absent because it only selected the creation rule
  * changing `.sops.yaml` later does not rewrite that existing file
    * `.sops.yaml` and `k8s-secret.enc.yaml` are separate files
    * saving `.sops.yaml` runs no SOPS command
    * the ciphertext and `sops` metadata in `k8s-secret.enc.yaml` remain
      unchanged

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
* `.sops.yaml` and the embedded metadata have different purposes
  * `.sops.yaml` supplies the intended policy for new encryption operations
  * embedded metadata describes how this existing encrypted file was created
  * editing `.sops.yaml` changes only the intended policy
  * the existing file changes only when a SOPS command rewrites it
* `sops updatekeys FILE`
  * purpose: apply recipient additions or removals from `.sops.yaml` to an
    existing encrypted file
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
  * retains the encrypted YAML values
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
  * to apply the new field selection to an existing file
    * decrypt `k8s-secret.enc.yaml` to plaintext with an authorized identity
    * encrypt that plaintext again using the target filename
    * SOPS reads the changed `.sops.yaml` rule during this new encryption
    * the new encrypted file records the new setting:

      ```yaml
      sops:
        encrypted_regex: '^stringData$'
      ```

    * protect and discard any temporary plaintext

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

## Flux with SOPS and age

* use case
  * an invoicing backend calls the Stripe API
  * the application requires a server-side Stripe API key
* plaintext Kubernetes Secret
  * the application reads the Stripe key from a Secret in its namespace
  * example

    ```yaml
    apiVersion: v1
    kind: Secret
    metadata:
      name: invoicing-stripe
      namespace: invoicing
    stringData:
      STRIPE_API_KEY: rk_live_example
    ```

* encrypted Git state
  * the Stripe key must not be committed as plaintext
  * SOPS encrypts the value before the file enters Git
  * the file includes production Flux and recovery public age recipients
  * example

    ```yaml
    apiVersion: v1
    kind: Secret
    metadata:
      name: invoicing-stripe
      namespace: invoicing
    stringData:
      STRIPE_API_KEY: ENC[AES256_GCM,...]
    sops:
      age:
        - recipient: age1-prod-invoicing-flux...
          enc: <data key encrypted for production Flux>
        - recipient: age1-prod-invoicing-recovery...
          enc: <same data key encrypted for recovery>
    ```

* production recipient design
  * production Flux identity
    * private identity is stored in the production cluster
    * provides automatic decryption during reconciliation
    * is scoped to the production invoicing workload or tenant
  * recovery identity
    * private identity is stored offline or in a separate secret manager
    * is not stored in Git or in the same production cluster
    * recovers secrets if the Flux identity is lost
  * recipients use OR semantics
    * either private identity can decrypt the complete file
    * additional recipients improve recoverability but increase exposure
  * do not add routine developer identities unless developers require plaintext
    access
* Flux credentials
  * `git-auth`
    * authenticates Flux to the private Git repository
    * is referenced by the Flux `GitRepository`
  * `sops-age`
    * contains the private age identity matching
      `age1-prod-invoicing-flux...`
    * is referenced by the Flux `Kustomization`
    * allows age to recover the SOPS data key
* deployment flow
  * Flux fetches the private Git repository using `git-auth`
  * age uses the production Flux identity in `sops-age` to recover the SOPS data
    key
  * SOPS uses the data key to verify the MAC and decrypt `STRIPE_API_KEY`
  * Flux creates the `invoicing-stripe` Kubernetes Secret in the `invoicing`
    namespace
  * the invoicing application reads the Stripe key from the Kubernetes Secret
  * the application uses the key when calling Stripe
* `HelmRelease` responsibility
  * deploys the invoicing application
  * does not contain the Stripe key
  * does not decrypt SOPS
  * the Kubernetes Secret is created before the application uses it

## workshop plan

### Local secret lifecycle

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
  * the commands modify a disposable copy, not the repository file

    ```bash
    cp k8s-secret.enc.yaml /tmp/tampered-secret.enc.yaml
    sed -i.bak \
      's/name: example-application/name: tampered-application/' \
      /tmp/tampered-secret.enc.yaml
    sops decrypt /tmp/tampered-secret.enc.yaml
    ```

  * `cp` creates `/tmp/tampered-secret.enc.yaml`; the original encrypted file
    remains unchanged
  * `sed -i.bak` modifies that copy without using SOPS
    * replaces `metadata.name: example-application` with
      `metadata.name: tampered-application`
    * creates the backup `/tmp/tampered-secret.enc.yaml.bak`
  * `sops decrypt` recalculates the MAC from the modified document values
  * the changed plaintext `metadata.name` does not match the stored MAC
  * expected result: `MAC mismatch`
  * discard the copy and its `.bak` backup
  * never use `--ignore-mac` as a repair mechanism

Avoid `sops decrypt --in-place`; it writes plaintext to disk.

### Recipient lifecycle

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
