# Security policy

## Reporting a vulnerability

Email **hola@frostyirie.cr** with the subject `SECURITY`, or use GitHub's private vulnerability reporting on this repository. Please don't open a public issue. You will get an answer within 5 business days.

## Handling customer data

- Personal data (name, phone, address or beach spot) lives only in the `contacts` stores and is deleted after 30 days.
- Never paste real customer data into issues, pull requests, tests or logs. Use the fictitious values from `tests/`.
- Cloud access is keyless (OIDC and managed identities). If you ever find a cloud key or secret in this repository, treat it as compromised: revoke it first, then report it.
