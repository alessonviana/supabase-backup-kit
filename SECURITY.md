# Security model

This repository is **public** and contains **only logic** — no credentials, keys,
project references or backups. Everything sensitive lives in the settings of the
private repository that consumes this kit.

## Design guarantees

- **Asymmetric encryption.** Backups are encrypted with an [age](https://github.com/FiloSottile/age)
  **public** key. The backup job never has the private key, so a compromised
  backup runner cannot decrypt existing backups. The private key is only supplied
  to the restore/verify jobs (as a secret) and should also be kept offline.
- **Least privilege.** Consumer workflows should grant `permissions: contents: read`
  (plus `actions: read` only where an artifact from another run is downloaded).
- **Secret masking.** Connection strings and their passwords are masked in logs
  (`::add-mask::`). Never `echo` a secret.
- **No secrets in this repo.** Enforced by `.gitignore` (blocks `*.age`, `*.key`,
  `*.sql`, `.env`, ...). Do not add real connection strings to examples.

## Reporting a vulnerability

Open a private security advisory on this repository, or contact the maintainer
directly. Please do not open a public issue for security problems.

## Hardening notes

- Pin this kit from consumers by tag (`@v1`) or, for maximum supply-chain safety,
  by commit SHA.
- Third-party actions used here are watched by Dependabot (`.github/dependabot.yml`).
- Rotate the age key pair periodically; keep old private keys until the last
  backup encrypted to them has expired.
