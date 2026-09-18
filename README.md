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
  * also supports binary files
    * treats the complete file as one value
    * encrypts the whole file
    * stores the encrypted value as base64 inside a JSON document
    * does not preserve an editable structure or useful value-level Git diffs
* age
  * controls access to the SOPS data key
  * recipient
    * public key beginning with `age1...`
    * encrypts the SOPS data key
    * may be committed and distributed
  * identity
    * private key beginning with `AGE-SECRET-KEY-...`
    * matches one recipient
    * decrypts the SOPS data key
    * must normally remain outside Git

## Encryption model

* data key
  * SOPS generates one random data key when it encrypts a new document
  * the data key is a 256-bit, or 32-byte, symmetric key
  * the same symmetric key encrypts and decrypts values
  * symmetric encryption efficiently processes values of arbitrary length
* value encryption
  * SOPS encrypts each selected leaf value with the data key using AES-256-GCM
  * AES-256 is the symmetric encryption algorithm
  * GCM produces an authentication tag for each encrypted value
    * the tag detects modification of the value or its authenticated context
    * no separate HMAC is required for each value
* data-key access
  * age encrypts one copy of the data key with each public recipient
  * SOPS stores each encrypted copy in a separate `sops.age[].enc` block
  * each block can be decrypted only with the matching private identity
  * an `enc` block does not contain values such as `username` or `password`
  * age uses fresh random material for each encryption
    * two entries for the same recipient should still differ
  * multiple `enc` blocks have OR semantics
    * any matching private identity can decrypt the data key
* decryption
  * age uses a matching private identity to decrypt one copy of the data key
  * SOPS uses the decrypted data key to decrypt the selected values
* encrypted document
  * keeps encrypted values in their original fields
  * stores the following items in the `sops` section
    * encrypted copies of the data key
      * give matching identities access to the data key
    * encrypted MAC
      * detects added, removed, or changed document values
    * metadata
      * records the SOPS version, modification time, and value-selection settings
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
      encrypted_regex: ^(data|stringData)$
      lastmodified: "2026-07-30T18:26:29Z"
      mac: ENC[AES256_GCM,data:W6JZXuZzS1vrtqBA,...]
      version: 3.13.3
    ```

* multiple recipients
  * N-of-M access requires `key_groups` and `shamir_threshold`, for example:

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

## Integrity and limits

* `sops.mac`
  * is an integrity check calculated from the document values
  * is encrypted with the data key
  * covers encrypted and plaintext data values by default
  * is recalculated during decryption and compared with the stored value
  * reports a MAC mismatch when a value was changed, added, or removed without
    valid re-encryption
  * can be replaced with a valid new MAC by anyone who has a matching private
    identity
* authorship
  * the MAC proves integrity, not authorship
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
* normal workflow
  * production repositories normally store the encrypted file as the source of
    truth
  * the encrypted file is often named `*.enc.yaml`
  * users run `sops edit FILE` and `sops decrypt FILE` on that encrypted file
  * `sops edit FILE` decrypts the file for the editor and re-encrypts it on save
  * `sops decrypt FILE` writes plaintext to stdout
  * for a new file, the final encrypted path selects the creation rule
  * for an existing file, SOPS reads the embedded `sops` section
  * production repositories do not normally keep a plaintext copy beside the
    encrypted file
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

## workshop plan

### Local secret lifecycle

* requirements
  * Bash
  * `sops`
  * an editor for `sops edit`

1. install the tools

   ```bash
   brew install sops age
   sops --version
   age-keygen --version
   ```

2. inspect the existing encrypted manifest
   * the workshop starts with `k8s-secret.enc.yaml`
   * `k8s-secret.yaml` is only a dummy plaintext comparison file
   * `sops filestatus` reads the embedded `sops` section to detect whether the
     file is encrypted

   ```bash
   sops filestatus k8s-secret.enc.yaml
   ```

3. decrypt with the Flux fixture identity
   * decryption prints plaintext to stdout
   * do not use `sops decrypt --in-place`; it writes plaintext to disk

   ```bash
   SOPS_AGE_KEY_FILE=age-private-key/flux.agekey \
     sops decrypt k8s-secret.enc.yaml
   ```

4. decrypt with the developer fixture identity

   ```bash
   SOPS_AGE_KEY_FILE=age-private-key/mtumilowicz.agekey \
     sops decrypt k8s-secret.enc.yaml
   ```

5. edit through SOPS editor
   * SOPS decrypts the document for the editor
   * saving re-encrypts protected values and recalculates the MAC

   ```bash
   SOPS_AGE_KEY_FILE=age-private-key/flux.agekey \
     sops edit k8s-secret.enc.yaml
   ```

6. detect tampering
   * the commands modify a disposable copy, not the repository file

   ```bash
   cp k8s-secret.enc.yaml /tmp/tampered-secret.enc.yaml
   sed -i.bak \
     's/name: example-application/name: tampered-application/' \
     /tmp/tampered-secret.enc.yaml
   SOPS_AGE_KEY_FILE=age-private-key/flux.agekey \
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

### Recipient lifecycle

1. generate an identity
   * requires `age-keygen`
   * redirect stdout to protected storage because it contains the private
     identity
   * the public recipient is printed to stderr

   ```bash
   age-keygen > /protected/path/developer.agekey
   ```

   * add only the resulting `age1...` recipient to `.sops.yaml`
   * run `updatekeys` with an existing identity

2. remove an identity
   * perform these commands only on a disposable branch
   * remove `*mtumilowicz_age_key` from `creation_rules[0].age`
   * synchronize the recipient wrappers

   ```bash
   SOPS_AGE_KEY_FILE=age-private-key/flux.agekey \
     sops updatekeys --yes k8s-secret.enc.yaml
   ```

   * verify access

   ```bash
   SOPS_AGE_KEY_FILE=age-private-key/mtumilowicz.agekey \
     sops decrypt k8s-secret.enc.yaml
   SOPS_AGE_KEY_FILE=age-private-key/flux.agekey \
     sops decrypt k8s-secret.enc.yaml
   ```

   * the removed identity must fail
   * the remaining identity must succeed

3. rotate the data key
   * `sops rotate --in-place` generates a new random symmetric data key
   * SOPS re-encrypts the selected values with the new data key

   ```bash
   SOPS_AGE_KEY_FILE=age-private-key/flux.agekey \
     sops rotate --in-place k8s-secret.enc.yaml
   ```
