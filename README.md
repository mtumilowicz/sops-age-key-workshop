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
  * supports structured YAML, JSON, ENV, and INI files
    * YAML and JSON represent nested data
    * ENV files contain `KEY=value` entries
    * INI files contain `key=value` entries, optionally grouped into sections
  * determines the input format from the file extension
    * `--input-type` can set the format explicitly
  * treats structured files as trees
    * keeps keys readable
    * encrypts leaf values by default
    * selection rules such as `encrypted_regex` can restrict which values are
      encrypted
    * example:

      ```yaml
      encrypted_regex: '^(data|stringData)$'
      ```

      * encrypts leaf values below keys named `data` or `stringData`
    * stores the following items in the source document
      * ciphertext
        * protects each selected value
      * wrapped data keys
        * let an authorized identity decrypt the data key
      * encrypted MAC
        * protects the complete document
        * detects added, removed, or changed values
      * metadata
        * records the SOPS version, modification time, and value-selection
          settings
        * abbreviated example:

          ```yaml
          sops:
            encrypted_regex: ^(data|stringData)$
            lastmodified: "2026-07-30T18:26:29Z"
            version: 3.13.3
          ```

        * the complete `sops` section also contains the wrapped data keys and
          encrypted MAC
  * also supports binary files
    * treats the complete file as one value
    * encrypts the whole file
    * stores the encrypted value as base64 inside a JSON document
    * does not preserve an editable structure or useful value-level Git diffs
  * generates one random 256-bit symmetric data key for the document
    * 256 bits means the data key is 32 bytes
    * symmetric means the same data key encrypts and decrypts values
    * symmetric encryption efficiently processes values of arbitrary length
  * encrypts each selected leaf value with the data key using AES-256-GCM
    * AES-256 is the symmetric encryption algorithm
    * GCM produces an authentication tag for each encrypted value
        * tag detects modification of that value or its authenticated context
            * in particular: no separate HMAC is required for each value
    * SOPS also uses an encrypted document MAC to protect the complete document
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
* encryption
  * when SOPS encrypts a new document, it generates one random symmetric data key
    * symmetric means the same key encrypts and decrypts data
  * SOPS uses the data key to encrypt the selected YAML values
    * SOPS reads `encrypted_regex` from the matching rule in `.sops.yaml`
        * example: `^(data|stringData)`
            * => SOPS encrypts values below keys beginning with `data` or `stringData`
            * in particular: values below `metadata` are not selected
  * age encrypts the data key with each recipient's public key (`age1...`)
  * output file contains
    * encrypted YAML values in their original fields
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
        mac: ENC[AES256_GCM,data:W6JZXuZzS1vrtqBA,...]
      ```
    * `sops.age[].enc`
      * each `enc` block is one encrypted copy of the same data key
      * each copy is encrypted with the public key in its `recipient`
      * can be decrypted only with the matching private identity
      * does not contain secret values such as `username` or `password`
      * age uses fresh random material for each encryption
      * if the same recipient appears twice, the two `enc` blocks should still
        differ
      * multiple `enc` blocks have OR semantics
      * any matching private identity can decrypt the data key
    * `sops.mac`
      * is an integrity check calculated from the document values
      * is encrypted with the data key
      * is recalculated during decryption and compared with the stored value
      * reports a MAC mismatch when a value was changed, added, or removed
        without valid re-encryption
      * can be replaced with a valid new MAC by anyone who has a matching
        private identity
* decryption
  * age needs a matching private identity (`AGE-SECRET-KEY-...`)
  * age uses the private identity to decrypt the data key
  * SOPS uses the decrypted data key to decrypt the YAML values

* example 
    * before encryption

      ```yaml
      metadata:
        name: example-application # not selected
      stringData:                 # matches encrypted_regex
        username: demo-user       # selected
        password: demo-value      # selected
      ```

    * after encryption (partial snippet)

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

* multiple recipients
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
      
        * SOPS splits the data key into three shares in the same SOPS document
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
* discovery
  * the working directory is the directory where the `sops` command starts
  * SOPS starts searching for `.sops.yaml` in the working directory
  * it continues through each parent directory
  * it uses the first `.sops.yaml` found
  * it does not start the search from the encrypted file's directory
  * `--config PATH` selects a configuration file explicitly
* creation rules
  * SOPS evaluates rules from top to bottom
  * `path_regex` selects files
    * SOPS compares each `path_regex` with the target file path
    * SOPS uses the first rule whose `path_regex` matches
    * `^` requires the match to start at the beginning
    * `$` requires the match to end at the end
    * example: `^k8s-secret\.enc\.yaml$` matches only
      `k8s-secret.enc.yaml`
  * `encrypted_regex` selects fields
    * example: `^(data|stringData)$` matches only `data` and `stringData`
    * SOPS encrypts values below those keys
    * SOPS leaves `apiVersion`, `kind`, `metadata`, and `type` readable
  * `age` lists public recipients that can decrypt the file
  * is read when SOPS creates a new encrypted file
* example
  * `.sops.yaml`

    ```yaml
    creation_rules:
      - path_regex: '^k8s-secret\.enc\.yaml$'
        encrypted_regex: '^(data|stringData)$'
        age:
          - age1-flux...
          - age1-developer...
    ```

  * YAML anchors can make long recipient strings reusable:

    ```yaml
    keys:
      flux_age_key: &flux_age_key age1-flux...

    creation_rules:
      - path_regex: '^k8s-secret\.enc\.yaml$'
        age:
          - *flux_age_key
    ```

  * anchors are only YAML syntax
  * anchors do not create SOPS access rules by themselves
* embedded `sops` section
  * an encrypted file contains a `sops:` section
  * that section stores the settings that SOPS used for that file
  * example:

    ```yaml
    sops:
      age:
        - recipient: age1-flux...
          enc: <encrypted data-key copy>
        - recipient: age1-developer...
          enc: <encrypted data-key copy>
      encrypted_regex: ^(data|stringData)$
      lastmodified: "2026-07-30T18:26:29Z"
      mac: ENC[AES256_GCM,data:W6JZXuZzS1vrtqBA,...]
      version: 3.13.3
    ```

  * `sops decrypt` and `sops edit` read this section from the encrypted file
  * `.sops.yaml` changes affect the next encryption command
  * an existing encrypted file changes only when a SOPS command rewrites that
    encrypted file
* commands
  * `sops updatekeys FILE`
    * updates the recipients stored in an existing encrypted file
    * reads the current recipients from the first matching `.sops.yaml` rule
    * rewrites `sops.age` in `FILE`
    * requires an authorized private identity to decrypt the data key first
    * keeps the same data key
    * keeps the same encrypted values
    * does not change the field-selection setting
  * `sops rotate FILE`
    * creates a new symmetric data key
    * re-encrypts the selected values with the new data key
    * rewrites encrypted data-key copies in `sops.age`
    * keeps the same field-selection setting
  * changing `encrypted_regex` in `.sops.yaml`
    * affects new encryption operations
    * does not change existing encrypted files
    * requires decrypting and encrypting the file again if an existing file must
      use the new field selection

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
          enc: <data key encrypted for the invoicing Flux age recipient>
        - recipient: age1-prod-invoicing-recovery...
          enc: <same data key encrypted for recovery>
    ```

* production recipient design
  * Flux age decryption identity
    * is a normal age private identity beginning with `AGE-SECRET-KEY-...`
    * matches the public recipient `age1-prod-invoicing-flux...`
    * is not a Flux user, Kubernetes ServiceAccount, or Git identity
    * allows Flux to decrypt SOPS files during reconciliation
  * recovery identity
    * private identity is stored offline or in a separate secret manager
    * is not stored in Git or in the same production cluster
    * recovers secrets if the Flux age decryption identity is lost
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
    * Kubernetes Secret example

      ```yaml
      apiVersion: v1
      kind: Secret
      metadata:
        name: sops-age
        namespace: invoicing
      stringData:
        identity.agekey: AGE-SECRET-KEY-...
      ```

    * Flux `Kustomization` reference

      ```yaml
      metadata:
        name: invoicing
        namespace: invoicing
      spec:
        decryption:
          provider: sops
          secretRef:
            name: sops-age
      ```

    * physical storage and use
      * the Kubernetes API server persists the Secret in the cluster's etcd
        database
      * Secret values are base64 encoded and are unencrypted in etcd by default
      * production clusters should enable encryption at rest
      * RBAC should restrict access to the `sops-age` Secret
      * kustomize-controller reads the identity into process memory during
        reconciliation
* deployment flow
  * Flux fetches the private Git repository using `git-auth`
  * age uses the Flux age decryption identity in `sops-age` to recover the SOPS
    data key
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
