# Security Policy

## Supported Versions

OptimCE does not publish tagged releases yet. Security fixes are applied to the
`main` branch of each repository.

## Reporting a Vulnerability

**Please do not report security vulnerabilities through public GitHub issues,
discussions, or pull requests.**

Instead, use one of these channels:

1. **GitHub private vulnerability reporting** (preferred): go to the
   **Security** tab of the affected repository and click
   **"Report a vulnerability"**.
2. **Email**: [contact@optimce.be](mailto:contact@optimce.be).

Please include as much of the following as you can:

- The type of issue (e.g. exposed credentials or default secrets, gateway or
  reverse-proxy routing that bypasses authentication, container privilege or
  network isolation problems, insecure TLS configuration)
- The affected file(s) or service(s) in the deployment
- Step-by-step instructions to reproduce the issue, or a proof of concept
- The impact you believe the issue has, and how an attacker might exploit it

## What to Expect

OptimCE is maintained by a small team. We aim to acknowledge your report within
a few business days, keep you informed while we investigate, and credit you in
the fix (unless you prefer to remain anonymous). Please give us a reasonable
amount of time to address the issue before any public disclosure.

## Scope

This repository holds the deployment configuration — Docker Compose stack, API
gateway, reverse proxy, Keycloak realm template, and database bootstrap — for a
production OptimCE installation. Vulnerabilities in the application code itself
belong in the corresponding service repository under the
[OptimCE organization](https://github.com/OptimCE). If you are not sure where an
issue belongs, report it here (or by email) and we will route it to the right
place.
