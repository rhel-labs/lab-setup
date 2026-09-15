# Lab Setup Library — Image Requirements

## Assumed present in base image

These must be available before the bootstrap block runs. If any are missing,
the bootstrap will fail before it can install anything.

| Package | Used for |
|---------|----------|
| `bash` | Script interpreter |
| `dnf` | Package installation |
| `subscription-manager` | System registration |
| `systemctl` | Service management |
| `curl` | Registry health check in `setup_ssl_registry` |
| `sed` | NSS config in `setup_libvirt` |

## Installed by library functions

These are installed on demand by specific functions and do not need to be
present in the base image or the bootstrap block.

| Package | Installed by |
|---------|--------------|
| `epel-release` | `setup_ssl_registry` |
| `certbot` | `setup_ssl_registry` |

## Installed by bootstrap block

`git` is not in the EUS image (`rhel-10-2-eus-*`) but is present in the older
base (`rhel-10-0-*`). Because the library fetch requires git, and installing
git requires an active subscription, every setup script targeting the EUS image
must register and install git before sourcing the library:

```bash
dnf -y remove katello-ca-consumer-* 2>/dev/null || true
subscription-manager clean
subscription-manager register --activationkey="${ACTIVATION_KEY}" --org="${ORG_ID}" --force
dnf install -y git
```

As labs migrate to the EUS image this block is required in every setup script.
Request `git` be added to the EUS image build to eliminate it.

## Idempotency

All library functions must be safe to run multiple times against the same host. The Ansible job that invokes setup scripts is retried on failure, so any function that executed before the failure point will run again on the next attempt.

**Inherently idempotent — no special handling needed:**
- `dnf install -y` — skips packages already installed
- `systemctl enable --now` — no-op if already enabled/running
- `mkdir -p` — no-op if directory exists
- `podman pull` — skips layers already present

**Patterns required for non-idempotent operations:**

| Pattern | Use when |
|---------|----------|
| `grep -qF "..." file \|\| echo "..." >> file` | Appending a line to a file (hosts, profile.d) |
| `[ ! -f ... ] \|\|` guard before expensive external calls | Certbot, certificate requests, anything with rate limits |
| `cmd 2>/dev/null \|\| true` | Cleanup/removal steps that are no-ops when nothing exists |

## Internal retry policy

The setup script runs as an init container inside the zerotouch pod. If it exits non-zero, the kubelet restarts the container with exponential backoff (10s → 300s max). Each restart replays the full setup script from the top against a VM with partial state. The cost of a kubelet restart cycle is high — several minutes of replay before reaching the failure point again.

**Retry internally** when the failure is transient (resolves in seconds), and the retry is cheaper than a full kubelet restart cycle plus setup replay. Use a bounded retry loop with short sleep between attempts. Exit non-zero once retries are exhausted.

**Exit immediately** when the failure is not recoverable without external action — bad credentials, hard configuration errors, persistent service unavailability. Spinning internally wastes the provisioning time budget.

| Function | Retry | Rationale |
|----------|-------|-----------|
| `pull_private_images()` | 3 × 30s | Network interruptions during large pulls are common and transient; replay cost is high |
| `pull_public_images()` | 3 × 30s | Same rationale; no auth required — works for quay.io, ghcr.io with PAT, registry.access.redhat.com, etc. |
| `setup_ssl_registry()` certbot | 3 × 15s | ACME challenges can fail transiently; rate limits make re-requesting from scratch expensive |
| `setup_ssl_registry()` health check | 5 × 5s | Registry container startup is fast but not instant |
| `dnf_install()` | none | `dnf` retries internally (mirrors, metadata); the `rpm -q` guard handles replay |
| `register_system_cdn()` | none | `--force` handles re-registration; failures are configuration errors |

**Quality issues (function works on retry but should be improved):**
- `setup_ssl_registry()`: certbot runs unconditionally on retry even when cert files already exist. `|| true` covers its non-zero exit, existing certs are used, and execution continues correctly — but certbot binds port 80 briefly and consumes a ZeroSSL rate-limited call unnecessarily. A `[ ! -f "${CERT_DIR}/fullchain.pem" ]` guard before the loop would skip it cleanly.
- `add_local_host()`: appends without guard — creates duplicate `/etc/hosts` entries on retry. Harmless for name resolution (first match wins) but untidy.
- `persist_env_var()`: appends without guard — creates duplicate export lines on retry. Harmless; same assignment runs twice with same result.

## Platform notes

**Google guest agent shutdown** — GCP base images include Google guest agents
(`google-guest-agent`, `google-osconfig-agent`, etc.) that can take up to 10
minutes to fully stop. Labs that remove these agents (e.g. image mode conversion
hosts) should account for this in provisioning timeout budgets.
