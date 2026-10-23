#!/bin/bash
# Exercise every function in common.sh.
# Run as root (sudo bash test-common-functions.sh).
#
# Credential-dependent functions are skipped when the required env vars are absent.
# Set them in /tmp/test-common.env to include those paths:
#
#   REGISTRY_PULL_TOKEN   - for setup_redhat_registry_auth + pull_private_images
#   ACTIVATION_KEY, ORG_ID - for register_system_cdn
#   GIT_REPO [GIT_BRANCH] - for fetch_setup_files
#
#   LAB_USER (default: rhel) - non-root user tested in pull_*_images calls
#
# Note: setup_ssl_registry requires live DNS + ACME — not testable here.

set -euo pipefail
set -x
trap 'echo "FATAL: test failed at line ${LINENO}" >> /tmp/progress.log; exit 1' ERR

# Source credential env vars from a file to avoid passing secrets on the CLI.
# Create /tmp/test-common.env with lines like:
#   REGISTRY_PULL_TOKEN=...
#   ACTIVATION_KEY=...
#   ORG_ID=...
#   GIT_REPO=...
#   ZEROSSL_EAB_KEY_ID=...
#   ZEROSSL_HMAC_KEY=...
#   SSL_REG_HOST=...
ENV_FILE="${LAB_TEST_ENV:-/tmp/test-common.env}"
if [[ -f "${ENV_FILE}" ]]; then
  set +x
  # shellcheck source=/dev/null
  . "${ENV_FILE}"
  set -x
fi

PROGRESS=/tmp/progress.log
echo "common.sh function test started at $(date)" > "${PROGRESS}"
chmod 666 "${PROGRESS}"

LAB_USER="${LAB_USER:-rhel}"
SKIPPED=()

# --- source common.sh ---
LIBDIR=/tmp/lab-lib-$$
git clone --depth=1 https://github.com/rhel-labs/lab-setup "${LIBDIR}"
. "${LIBDIR}/common.sh"
echo "common.sh sourced from ${LIBDIR}" >> "${PROGRESS}"

# =========================================================
# system
# =========================================================

echo "Testing dnf_install..." >> "${PROGRESS}"
dnf_install curl git
echo "PASS: dnf_install" >> "${PROGRESS}"

echo "Testing setup_epel..." >> "${PROGRESS}"
setup_epel
echo "PASS: setup_epel" >> "${PROGRESS}"

echo "Testing setup_libvirt..." >> "${PROGRESS}"
setup_libvirt
echo "PASS: setup_libvirt" >> "${PROGRESS}"

echo "Testing setup_cockpit..." >> "${PROGRESS}"
GUID="${GUID:-test-guid}"
DOMAIN="${DOMAIN:-example.com}"
setup_cockpit
echo "PASS: setup_cockpit" >> "${PROGRESS}"

# =========================================================
# utility
# =========================================================

echo "Testing add_local_host..." >> "${PROGRESS}"
grep -q 'test-lab-host.example.com' /etc/hosts \
  || add_local_host test-lab-host.example.com
echo "PASS: add_local_host" >> "${PROGRESS}"

echo "Testing persist_env_var..." >> "${PROGRESS}"
persist_env_var LAB_TEST_VAR "test_value_$$"
grep -q 'LAB_TEST_VAR' /etc/profile.d/lab.sh
echo "PASS: persist_env_var" >> "${PROGRESS}"

# =========================================================
# registry — public pulls (no credentials needed)
# =========================================================

echo "Testing pull_public_images as ${LAB_USER}..." >> "${PROGRESS}"
pull_public_images "${LAB_USER}" \
  registry.access.redhat.com/ubi9/ubi-minimal:latest
echo "PASS: pull_public_images (${LAB_USER})" >> "${PROGRESS}"

echo "Testing pull_public_images as root..." >> "${PROGRESS}"
pull_public_images root \
  registry.access.redhat.com/ubi9/ubi-minimal:latest
echo "PASS: pull_public_images (root)" >> "${PROGRESS}"

# =========================================================
# registry — private (credential-gated)
# =========================================================

if [[ -n "${REGISTRY_PULL_TOKEN:-}" ]]; then
  echo "Testing setup_redhat_registry_auth..." >> "${PROGRESS}"
  setup_redhat_registry_auth
  echo "PASS: setup_redhat_registry_auth" >> "${PROGRESS}"

  echo "Testing pull_private_images as root..." >> "${PROGRESS}"
  pull_private_images "${RH_REGISTRY_AUTHFILE}" root \
    registry.redhat.io/ubi9/ubi-minimal:latest
  echo "PASS: pull_private_images (root)" >> "${PROGRESS}"

  echo "Testing pull_private_images as ${LAB_USER}..." >> "${PROGRESS}"
  pull_private_images "${RH_REGISTRY_AUTHFILE}" "${LAB_USER}" \
    registry.redhat.io/ubi9/ubi-minimal:latest
  echo "PASS: pull_private_images (${LAB_USER})" >> "${PROGRESS}"
else
  SKIPPED+=("setup_redhat_registry_auth" "pull_private_images")
  echo "SKIP: setup_redhat_registry_auth, pull_private_images (REGISTRY_PULL_TOKEN not set)" >> "${PROGRESS}"
fi

# =========================================================
# subscription (credential-gated)
# =========================================================

if [[ -n "${ACTIVATION_KEY:-}" && -n "${ORG_ID:-}" ]]; then
  echo "Testing register_system_cdn..." >> "${PROGRESS}"
  register_system_cdn
  echo "PASS: register_system_cdn" >> "${PROGRESS}"

  if [[ -n "${RHEL_RELEASE:-}" ]]; then
    echo "Testing pin_rhel_release ${RHEL_RELEASE}..." >> "${PROGRESS}"
    pin_rhel_release "${RHEL_RELEASE}"
    echo "PASS: pin_rhel_release" >> "${PROGRESS}"
  else
    SKIPPED+=("pin_rhel_release")
    echo "SKIP: pin_rhel_release (RHEL_RELEASE not set)" >> "${PROGRESS}"
  fi
else
  SKIPPED+=("register_system_cdn" "pin_rhel_release")
  echo "SKIP: register_system_cdn, pin_rhel_release (ACTIVATION_KEY and/or ORG_ID not set)" >> "${PROGRESS}"
fi

# =========================================================
# fetch_setup_files (credential-gated: needs GIT_REPO)
# =========================================================

if [[ -n "${GIT_REPO:-}" ]]; then
  echo "Testing fetch_setup_files..." >> "${PROGRESS}"
  GIT_BRANCH="${GIT_BRANCH:-main}"
  fetch_setup_files "setup"
  echo "PASS: fetch_setup_files (SETUP_FILES=${SETUP_FILES})" >> "${PROGRESS}"
else
  SKIPPED+=("fetch_setup_files")
  echo "SKIP: fetch_setup_files (GIT_REPO not set)" >> "${PROGRESS}"
fi

# setup_ssl_registry is not tested here — it requires a live public DNS name,
# port 80 open for ACME challenge, and ZeroSSL API access. Test only in full
# production provisioning.

# =========================================================
# cleanup (all unconditional — safe even if prior steps skipped)
# =========================================================

echo "Testing cleanup_registry_auth..." >> "${PROGRESS}"
cleanup_registry_auth
echo "PASS: cleanup_registry_auth" >> "${PROGRESS}"

echo "Testing cleanup_subscription..." >> "${PROGRESS}"
cleanup_subscription
echo "PASS: cleanup_subscription" >> "${PROGRESS}"

echo "Testing cleanup_certbot..." >> "${PROGRESS}"
cleanup_certbot
echo "PASS: cleanup_certbot" >> "${PROGRESS}"

echo "Testing cleanup_tmpfiles..." >> "${PROGRESS}"
cleanup_tmpfiles  # removes /tmp/lab-lib-$$ among other /tmp/lab-* dirs
echo "PASS: cleanup_tmpfiles" >> "${PROGRESS}"

# =========================================================
# summary
# =========================================================

{
  echo ""
  echo "=== Test Summary ==="
  echo "Completed at $(date)"
  if [[ ${#SKIPPED[@]} -gt 0 ]]; then
    echo "Skipped (missing credentials/env vars):"
    printf '  - %s\n' "${SKIPPED[@]}"
  else
    echo "All functions exercised."
  fi
} >> "${PROGRESS}"

echo "Done. Results in /tmp/progress.log"
cat /tmp/progress.log
