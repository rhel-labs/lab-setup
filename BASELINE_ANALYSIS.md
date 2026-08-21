# Lab Setup Library - Design Sample Baseline

**Analysis Date:** 2026-08-21  
**Sample:** 14 local labs used during library design  
**Purpose:** Document patterns and migration requirements observed in design sample

---

## Executive Summary

This document reviews the lab setup library design work by examining the 14 ZT lab repositories that were available locally during development. These labs informed the library function set. The analysis identifies pattern types, migration requirements, and implementation challenges.

**Sample characteristics:**
- 14 labs from `/home/mmicene/Projects/repos/zt-labs/`
- 16 setup scripts across those labs
- 1 lab (zt-image-mode-day2) already uses the library as proof-of-concept
- Mix of simple (1-line scripts) to complex (219-line scripts with multiple setup tasks)

**Key observations:**
- Common patterns exist: subscription registration, container image pulls, SSL registry setup, file staging
- Migration requires multiple change types: scripts, main.yml environment variables, secrets.yaml, repository structure
- Significant challenges: environment variable gaps, platform dependency verification, bootstrap ordering constraints
- Pattern incompatibilities exist: buildah workflows, minimal scripts, lab-specific operations

This is the design sample, not independent validation. Full catalog analysis will show whether patterns generalize.

---

## 1. Migration Requirements

### Change Types

**Script modifications:**
All migrations require script changes:
- Add library bootstrap block (clone library repo, source common.sh)
- Set ERR trap as documented in library
- Replace inline pattern implementations with library function calls

Example (zt-image-mode-day2):
```bash
# Bootstrap block
LIBDIR=/tmp/lab-lib-$$
git clone --depth=1 https://github.com/rhel-labs/lab-setup "${LIBDIR}"
. "${LIBDIR}/common.sh"

trap 'echo "FATAL: setup failed at line ${LINENO}" >> /tmp/progress.log; exit 1' ERR

# Replace inline registration with library call
register_system  # Replaces 3-4 lines of dnf + subscription-manager
```

**Environment variable additions:**
Library functions require specific variables passed through main.yml:

- **GUID, DOMAIN** — Required by: setup_ssl_registry, setup_cockpit, add_local_host
  - Example gap: zt-podman-basics, zt-buildah, zt-podman-pods (among others) don't pass these
  
- **ACTIVATION_KEY, ORG_ID** — Required by: register_system
  - Example gap: zt-container-management, zt-hardened-images use registration but don't pass vars
  - Anti-pattern: zt-podman-pods uses hardcoded credentials (12-5-22-instruqt / 12451665)
  
- **REGISTRY_PULL_TOKEN** — Required by: setup_redhat_registry_auth
  - Example: zt-image-mode-basics, zt-image-mode-day2 pass this; most others don't
  
- **GIT_REPO, GIT_BRANCH** — Required by: fetch_setup_files
  - Example: zt-hardened-images, zt-scan-sign pass these (platform-injected via GIT_REPO_URL/GIT_REPO_REF)
  - Example gap: zt-image-mode-basics uses heredocs instead (would need these vars if migrating)
  
- **ZEROSSL_EAB_KEY_ID, ZEROSSL_HMAC_KEY** — Required by: setup_ssl_registry
  - Example: zt-image-mode-basics, zt-scan-sign have these in secrets.yaml
  - Example gap: Most labs don't have ZeroSSL credentials

**Secrets management:**
Some variables come from secrets.yaml:
- Subscription credentials (rhelbu_activation_key, rhelbu_org_id)
- Registry tokens (may need registry_pull_token added)
- SSL credentials (zerossl_eab_key_id, zerossl_hmac_key)

Example: zt-podman-pods would need secrets.yaml created with subscription credentials.

**Repository structure changes:**
`fetch_setup_files` pattern requires files committed to repository:

Example (zt-image-mode-day2 migration from zt-image-mode-basics):
- Before: 119 lines of heredocs creating config.json, Containerfile, Containerfile.index
- After: Files committed to setup-files/ directory, fetched with `fetch_setup_files setup-files`
- Repository change required before migration can happen

---

## 2. Migration Challenges

### Environment Variable Gaps

**Pattern:** Many labs don't pass variables the library needs.

Examples:
- zt-buildah: Passes no environment variables at all
- zt-podman-basics through zt-rootless-podman-service: No GUID/DOMAIN/credentials passed
- zt-container-management: Has GUID/DOMAIN but no subscription credentials

**Impact:** Would require main.yml updates before library adoption possible.

### Platform Dependency Verification

**Git availability at provision time:**
Current blocker documented in REQUIREMENTS.md — git not in EUS base image (`rhel-10-2-eus-*`), requires inline subscription registration before library fetch.

Workaround in use (zt-image-mode-day2):
```bash
# Register and install git before library fetch
dnf -y remove katello-ca-consumer-* 2>/dev/null || true
subscription-manager clean
subscription-manager register --activationkey="${ACTIVATION_KEY}" --org="${ORG_ID}" --force
dnf install -y git
```

**Platform variable availability:**
- GIT_REPO_URL, GIT_REPO_REF: Verified available in zt-hardened-images, zt-scan-sign
- ZEROSSL credentials: Not universally available; lab-specific

### Hardcoded Credentials

**Pattern:** Some labs use hardcoded activation keys/org IDs instead of variables.

Example (zt-podman-pods):
```bash
subscription-manager register --activationkey=12-5-22-instruqt --org=12451665 --force
```

**Impact:** Must refactor to use environment variables before library migration. Not a library limitation, but a prerequisite.

### Pattern Incompatibilities

**Buildah workflows:**
Example: zt-podman-deploy uses `buildah` commands to build containers from scratch. Different pattern from podman pull.

**Empty/minimal scripts:**
Example: zt-rootless-podman-service (1 line), zt-quadlet-pods-sysroles (2 and 3 lines per script). No patterns to abstract.

**Lab-specific operations:**
Examples:
- GCP agent removal (zt-image-mode-day2): Platform-specific cleanup
- Bootc conversion (zt-image-mode-day2): Image-mode specific operation
- SELinux booleans (zt-buildah, zt-selinux-containers): Lab-specific configuration

These patterns are intentionally not in the library.

### Bootstrap Ordering Constraint

Git required to fetch library. Git install requires subscription. Creates forced ordering in every setup script.

Current solution: Inline registration + git install before library bootstrap (see REQUIREMENTS.md).

Long-term fix: Add git to EUS base image.

---

## 3. Patterns Not Covered

The following patterns were observed but are intentionally not abstracted:

**Buildah workflows** — Container builds from scratch rather than image pulls  
Example: zt-podman-deploy

**Systemd service management** — Stop/disable specific services  
Example: zt-container-management (httpd stop/disable)

**User management** — usermod, group additions  
Examples: zt-hardened-images (usermod -aG wheel), zt-selinux-containers

**SELinux configuration** — setsebool commands  
Examples: zt-buildah, zt-selinux-containers (container_manage_cgroup boolean)

**Platform-specific cleanup** — Environment-specific operations  
Example: zt-image-mode-day2 (GCP guest agent removal)

**Image-mode operations** — Bootc conversion and stateroot manipulation  
Example: zt-image-mode-day2/setup-imrhel.sh (bootc install to-existing-root)

**Lab-specific content** — Custom HTML, configurations, application code  
These remain in individual labs or are staged via fetch_setup_files.

**Note:** File staging via heredocs IS covered — `fetch_setup_files` replaces heredoc content by fetching committed files from the repository.

---

## 4. Code Reduction Observed

### zt-image-mode-day2 Before and After Library Migration

**Before (commit fd84cff, before library refactor): 114 lines**
- Inline subscription registration: 3 lines
- Manual auth.json creation: 10 lines  
- Podman pulls: 1 line
- SSL registry setup: ~24 lines (certbot + podman run)
- Heredoc file creation: ~50 lines (config.json, Containerfile, Containerfile.index)
- Hosts file entries: 2 lines
- Manual cleanup: 1 line (auth.json)
- Lab-specific operations: ~23 lines (sudoers, etc structure, final host entries)

**After (current, using library): 57 lines**
- Bootstrap block: 4 lines (inline registration + git install + library fetch)
- ERR trap setup: 1 line
- Lab configuration variables: 4 lines
- Library function calls: 8 lines (setup_libvirt, setup_redhat_registry_auth, pull_images, setup_ssl_registry, fetch_setup_files, add_local_host×2, persist_env_var)
- Setup file copies: 3 lines
- Cleanup calls: 4 lines (cleanup_registry_auth, cleanup_certbot, cleanup_tmpfiles)
- Lab-specific operations: ~10 lines (sudoers, etc/hosts copies)
- Progress logging: ~10 lines

**Reduction:** 114 lines → 57 lines (50% reduction)

Most reduction from:
- SSL registry: ~24 lines → 1 function call
- Heredocs: ~50 lines → 1 fetch call + 3 cp commands  
- Auth.json creation: 10 lines → 1 function call
- Cleanup: scattered → 3 function calls

---

## 5. Pattern Examples

### Subscription Registration

**Pattern:** `register_system`

Removes katello artifacts, cleans subscription-manager, registers with activation key.

**Example implementation (zt-selinux-containers):**
```bash
dnf -y remove katello-ca-consumer-*
subscription-manager clean
subscription-manager register --activationkey=$ACTIVATION_KEY --org=$ORG_ID --force
```

**Library equivalent:**
```bash
register_system
# Uses ACTIVATION_KEY and ORG_ID from environment
```

**Variants observed:**
- With katello cleanup (zt-selinux-containers, zt-image-mode-basics)
- Simple clean + register (zt-podman-pods)
- Hardcoded credentials (zt-podman-pods — anti-pattern)

---

### Container Image Pulls

**Pattern:** `pull_images`

Pre-stage container images into root or user storage.

**Example implementations:**

zt-hardened-images (user storage with runuser):
```bash
runuser -l rhel -c "podman pull registry.access.redhat.com/ubi9/python-39"
runuser -l rhel -c "podman pull docker.io/library/nginx"
# ...8 total images
```

zt-podman-basics (user storage with sudo):
```bash
sudo -u rhel podman pull docker.io/httpd
sudo -u rhel podman pull registry.access.redhat.com/ubi9/ubi
```

zt-image-mode-basics (root storage):
```bash
podman pull registry.redhat.io/rhel10/rhel-bootc:$BOOTC_RHEL_VER
```

**Library equivalent:**
```bash
pull_images rhel registry.access.redhat.com/ubi9/python-39
pull_images rhel docker.io/library/nginx
pull_images root registry.redhat.io/rhel10/rhel-bootc:${BOOTC_RHEL_VER}
```

**Requires:** RH_REGISTRY_AUTHFILE set by setup_redhat_registry_auth for authenticated registries

---

### SSL Registry Setup

**Pattern:** `setup_ssl_registry`

Install certbot, request ZeroSSL certificate, start TLS registry, validate it responds.

**Example implementation (zt-image-mode-basics, 24 lines):**
```bash
dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-10.noarch.rpm
dnf install -y certbot

set +x
certbot certonly --eab-kid "${ZEROSSL_EAB_KEY_ID}" \
  --eab-hmac-key "${ZEROSSL_HMAC_KEY}" \
  --server "https://acme.zerossl.com/v2/DV90" \
  --standalone --preferred-challenges http \
  -d builder-"${GUID}"."${DOMAIN}" \
  --non-interactive --agree-tos -m trackbot@instruqt.com -v
rm /var/log/letsencrypt/letsencrypt.log
set -x

podman run -d \
  --name registry \
  -p 443:5000 \
  -v /etc/letsencrypt/live/builder-${GUID}.${DOMAIN}/fullchain.pem:/certs/fullchain.pem:ro \
  -v /etc/letsencrypt/live/builder-${GUID}.${DOMAIN}/privkey.pem:/certs/privkey.pem:ro \
  -e REGISTRY_HTTP_TLS_CERTIFICATE=/certs/fullchain.pem \
  -e REGISTRY_HTTP_TLS_KEY=/certs/privkey.pem \
  quay.io/mmicene/registry:2
```

**Library equivalent:**
```bash
setup_ssl_registry "builder-${GUID}.${DOMAIN}"
```

**Requires:** ZEROSSL_EAB_KEY_ID, ZEROSSL_HMAC_KEY, GUID, DOMAIN

**Code reduction:** 24 lines → 1 line

---

### File Staging

**Pattern:** `fetch_setup_files`

Fetch setup files from lab repository. Replaces two manual approaches: git sparse-checkout and heredoc content.

**Example A: Git sparse-checkout (zt-hardened-images):**
```bash
TMPDIR=/tmp/lab-setup-$$
git clone --single-branch --branch ${GIT_BRANCH:-main} --no-checkout \
  --depth=1 --filter=tree:0 ${GIT_REPO} $TMPDIR
git -C $TMPDIR sparse-checkout set --no-cone /content/modules/ROOT/examples/flask
git -C $TMPDIR checkout
SETUP_FILES=$TMPDIR/content/modules/ROOT/examples/flask
```

**Example B: Heredoc content (zt-image-mode-basics, 119 lines):**
```bash
cat <<EOF> ~/config.json
{
  "blueprint": {
    "customizations": {
      "user": [...]
    }
  }
}
EOF

cat <<EOM> ~/Containerfile
FROM registry.redhat.io/rhel9/rhel-bootc:9.8
ADD etc /etc
RUN dnf install -y httpd vim
...
EOM
```

**Library equivalent (both patterns):**
```bash
# Pattern A: Direct replacement
fetch_setup_files content/modules/ROOT/examples/flask

# Pattern B: After committing heredoc content to repo setup-files/
fetch_setup_files setup-files
cp "${SETUP_FILES}/config.json" /root/config.json
cp "${SETUP_FILES}/Containerfile" /root/Containerfile
cp "${SETUP_FILES}/Containerfile.index" /root/Containerfile.index
```

**Requires:** GIT_REPO, GIT_BRANCH  
**Repository change for Pattern B:** Commit files to repo before migration

**Code reduction:**
- Pattern A: 6 lines → 1 line
- Pattern B: 119 lines → 4 lines + files in repo

---

### Registry Authentication

**Pattern:** `setup_redhat_registry_auth`

Create auth.json for registry.redhat.io with bearer token.

**Example implementation (zt-image-mode-basics):**
```bash
mkdir -p ~/.config/containers
cat<<EOF> ~/.config/containers/auth.json
{
    "auths": {
      "registry.redhat.io": {
        "auth": "${REGISTRY_PULL_TOKEN}"
      }
    }
  }
EOF
```

**Library equivalent:**
```bash
setup_redhat_registry_auth
```

**Requires:** REGISTRY_PULL_TOKEN

**Note:** Most labs pull from registry.access.redhat.com (public) and don't need auth. Auth only needed for registry.redhat.io (terms-based).

---

### Libvirt Setup

**Pattern:** `setup_libvirt`

Install packages, enable libvirtd, configure NSS for guest name resolution.

**Example implementation (zt-image-mode-basics):**
```bash
dnf install -y virt-install libvirt qemu-kvm libvirt-nss
systemctl enable --now libvirtd
sed -i 's/hosts:\s\+ files/& libvirt libvirt_guest/' /etc/nsswitch.conf
```

**Library equivalent:**
```bash
setup_libvirt
```

**Used in:** VM-based labs (zt-image-mode-basics, zt-image-mode-day2)

---

### Cockpit Configuration

**Pattern:** `setup_cockpit`

Configure Cockpit for Showroom environment access.

**Example implementation (zt-container-management):**
```bash
echo "[WebService]" > /etc/cockpit/cockpit.conf
echo "Origins = https://cockpit-${GUID}.${DOMAIN}" >> /etc/cockpit/cockpit.conf
echo "AllowUnencrypted = true" >> /etc/cockpit/cockpit.conf
systemctl enable --now cockpit.socket
```

**Library equivalent:**
```bash
setup_cockpit
```

**Requires:** GUID, DOMAIN

---

### Hosts File Management

**Pattern:** `add_local_host`

Add hostname entries to /etc/hosts for internal routing.

**Example implementation (zt-image-mode-basics):**
```bash
echo "10.0.2.2 builder.${GUID}.${DOMAIN}" >> /etc/hosts
echo "10.0.2.2 builder-${GUID}.${DOMAIN}" >> /etc/hosts
echo "10.0.2.2 registry-${GUID}.${DOMAIN}" >> /etc/hosts
```

**Library equivalent:**
```bash
add_local_host "builder.${GUID}.${DOMAIN}"
add_local_host "builder-${GUID}.${DOMAIN}"
add_local_host "registry-${GUID}.${DOMAIN}"
```

---

### Cleanup Patterns

**Temp file cleanup:**
Example (zt-hardened-images):
```bash
rm -rf $TMPDIR
```

Library: `cleanup_tmpfiles` (removes /tmp/lab-* directories)

**Registry auth cleanup:**
Example (zt-image-mode-basics):
```bash
rm ~/.config/containers/auth.json
```

Library: `cleanup_registry_auth` (removes auth file + podman logout --all)

**Subscription cleanup:**
Example (zt-image-mode-day2/setup-imrhel.sh):
```bash
subscription-manager unregister
```

Library: `cleanup_subscription`

---


## 6. Environment Variables

### Variables Required by Library Functions

| Variable | Required By |
|----------|-------------|
| GUID, DOMAIN | setup_ssl_registry, setup_cockpit, add_local_host |
| ACTIVATION_KEY, ORG_ID | register_system |
| REGISTRY_PULL_TOKEN | setup_redhat_registry_auth |
| GIT_REPO, GIT_BRANCH | fetch_setup_files |
| ZEROSSL_EAB_KEY_ID, ZEROSSL_HMAC_KEY | setup_ssl_registry |

### Sample Labs by Environment Variable Presence

**All required vars present:**
- zt-image-mode-day2 (reference implementation)

**Subscription credentials only:**
- zt-containerize-app (GUID, DOMAIN, ACTIVATION_KEY, ORG_ID via secrets)
- zt-selinux-containers (ACTIVATION_KEY, ORG_ID via secrets)
- zt-image-mode-basics (all vars including ZEROSSL)

**Partial coverage:**
- zt-container-management (GUID, DOMAIN only)
- zt-hardened-images (GUID, DOMAIN, GIT_REPO, GIT_BRANCH)
- zt-scan-sign (GUID, DOMAIN, GIT_REPO, GIT_BRANCH, ZEROSSL)

**No environment variables:**
- zt-buildah
- zt-podman-basics through zt-rootless-podman-service (6 labs)

---

## 7. Sample Inventory

| Lab | Scripts | Lines | Patterns |
|-----|---------|-------|----------|
| zt-buildah | setup-rhel.sh | 31 | SELinux config, no env vars |
| zt-containerize-app | setup-rhel.sh | 19 | Registration (duplicate), git clone |
| zt-container-management | setup-rhel.sh | 7 | Cockpit config |
| zt-hardened-images | setup-rhel.sh | 61 | User pulls (8 images), sparse-checkout |
| zt-image-mode-basics | setup-builder.sh | 219 | Registration, auth, pulls, SSL registry, libvirt, heredocs |
| zt-image-mode-day2 | setup-builder.sh, setup-imrhel.sh | 57, 75 | **Uses library** (reference implementation) |
| zt-podman-basics | setup-rhel.sh | 55 | User pulls with sudo |
| zt-podman-containerfile | setup-rhel.sh | 27 | Root pulls |
| zt-podman-deploy | setup-rhel.sh | 26 | Buildah workflow (incompatible) |
| zt-podman-pods | setup-rhel.sh | 47 | Hardcoded credentials, mixed pulls |
| zt-quadlet-pods-sysroles | 2 scripts | 2, 3 | Minimal (no patterns) |
| zt-rootless-podman-service | setup-rhel.sh | 1 | Empty (no patterns) |
| zt-scan-sign | setup-rhel.sh | 98 | User pulls, SSL registry, sparse-checkout |
| zt-selinux-containers | setup-rhel.sh | 21 | Registration, buildah |

**Total:** 14 labs, 16 scripts, 749 lines of setup code (excluding day2's library-based scripts)

---


## Appendix A: Design Sample Distribution

This appendix documents pattern distribution observed in the 14-lab design sample. These counts serve as a reference point when analyzing the full catalog.

### Pattern Occurrence

| Pattern | Labs in Sample | Labs |
|---------|----------------|------|
| Container image pulls | 8/14 | zt-hardened-images, zt-image-mode-basics, zt-image-mode-day2, zt-podman-basics, zt-podman-containerfile, zt-podman-deploy, zt-podman-pods, zt-scan-sign |
| Subscription registration | 6/14 | zt-containerize-app, zt-image-mode-basics, zt-image-mode-day2 (2 scripts), zt-podman-pods, zt-selinux-containers |
| Temp file cleanup | 4/14 | zt-hardened-images, zt-image-mode-day2 (2 scripts), zt-scan-sign |
| File staging (git sparse-checkout) | 3/14 | zt-hardened-images, zt-image-mode-day2, zt-scan-sign |
| File staging (heredocs) | 2/14 | zt-image-mode-basics, zt-scan-sign |
| SSL registry setup | 3/14 | zt-image-mode-basics, zt-image-mode-day2, zt-scan-sign |
| Hosts file entries | 3/14 | zt-image-mode-basics, zt-image-mode-day2 (2 scripts) |
| Registry auth setup | 2/14 | zt-image-mode-basics, zt-image-mode-day2 |
| Libvirt setup | 2/14 | zt-image-mode-basics, zt-image-mode-day2 |
| Environment persistence | 2/14 | zt-image-mode-day2, zt-scan-sign |
| Registry auth cleanup | 2/14 | zt-image-mode-basics, zt-image-mode-day2 |
| Cockpit setup | 1/14 | zt-container-management |
| Subscription cleanup | 1/14 | zt-image-mode-day2 |

### Environment Variable Coverage

| Variable Set | Labs in Sample |
|--------------|----------------|
| GUID, DOMAIN | 6/14 |
| ACTIVATION_KEY, ORG_ID | 4/14 |
| REGISTRY_PULL_TOKEN | 2/14 |
| GIT_REPO, GIT_BRANCH | 3/14 |
| ZEROSSL_EAB_KEY_ID, ZEROSSL_HMAC_KEY | 3/14 |
| No environment variables | 8/14 |

### Migration Surface

| Category | Labs in Sample |
|----------|----------------|
| Contains library-compatible patterns | 9/14 |
| No patterns or incompatible | 5/14 |

### Implementation Variants Observed

**Subscription registration:**
- With katello cleanup: 4 labs
- Simple clean + register: 2 labs
- Hardcoded credentials: 2 labs

**Container pulls:**
- Root storage: 3 labs
- User storage with runuser: 3 labs
- User storage with sudo: 2 labs
- Mixed: 1 lab

**File staging:**
- Git sparse-checkout: 3 labs
- Heredocs: 2 labs

---

**End of Baseline Analysis**
