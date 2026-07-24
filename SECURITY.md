# Security policy

## Supported installation

The supported installation is the Nix flake package. It applies the reviewed hardening patch during the build and keeps runtime dependencies supplied by Nixpkgs.

Running the unpatched upstream `lobster.sh` file directly is not considered a supported secure installation.

## Trust model

Lobster-ng scrapes third-party websites and sends embed URLs to third-party extraction services. Those services and all returned stream, subtitle, and thumbnail URLs must be treated as untrusted.

The hardening patch currently:

- removes shell `eval` from MPV launch handling;
- requires HTTPS for embed, video, and subtitle URLs;
- removes the unauthenticated self-updater;
- uses a private per-process temporary directory and socket;
- runs ShellCheck and Nix package checks in CI.

These changes reduce risk but cannot make third-party streaming providers trustworthy. Never run Lobster-ng as root or with `sudo`.

## Reporting a vulnerability

Please report vulnerabilities privately through GitHub Security Advisories for this repository. Include the affected code path, an example payload when safe to share, and the expected impact.
