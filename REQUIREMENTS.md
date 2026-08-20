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

## Platform notes

**Google guest agent shutdown** — GCP base images include Google guest agents
(`google-guest-agent`, `google-osconfig-agent`, etc.) that can take up to 10
minutes to fully stop. Labs that remove these agents (e.g. image mode conversion
hosts) should account for this in provisioning timeout budgets.
