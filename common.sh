#!/bin/bash
# Source this file after fetching from the lab-setup repo — do not execute directly.
# Set the ERR trap immediately after sourcing:
#   trap 'echo "FATAL: setup failed at line ${LINENO}" >> /tmp/progress.log; exit 1' ERR
# Commands expected to fail use || true to opt out.

RH_REGISTRY_AUTHFILE=/tmp/lab-auth/auth.json



# --- system ---

register_system() {
  dnf -y remove katello-ca-consumer-* 2>/dev/null || true
  subscription-manager clean
  subscription-manager register --activationkey="${ACTIVATION_KEY}" --org="${ORG_ID}" --force
}

setup_libvirt() {
  dnf install -y virt-install libvirt qemu-kvm libvirt-nss
  systemctl enable --now libvirtd
  sed -i 's/hosts:\s\+ files/& libvirt libvirt_guest/' /etc/nsswitch.conf
}

setup_cockpit() {
  dnf install -y cockpit cockpit-machines cockpit-podman cockpit-storaged cockpit-networkmanager cockpit-files
  echo "[WebService]" > /etc/cockpit/cockpit.conf
  echo "Origins = https://cockpit-${GUID}.${DOMAIN}" >> /etc/cockpit/cockpit.conf
  echo "AllowUnencrypted = true" >> /etc/cockpit/cockpit.conf
  systemctl enable --now cockpit.socket
}

# --- registry ---

# Reads REGISTRY_PULL_TOKEN from the environment. set +x keeps the token out of logs.
setup_redhat_registry_auth() {
  mkdir -p "$(dirname ${RH_REGISTRY_AUTHFILE})"
  set +x
  cat > "${RH_REGISTRY_AUTHFILE}" <<EOF
{
  "auths": {
    "registry.redhat.io": {
      "auth": "${REGISTRY_PULL_TOKEN}"
    }
  }
}
EOF
  set -x
  chmod 644 "${RH_REGISTRY_AUTHFILE}"
}

# Usage: pull_images root <image> [image...]
#        pull_images <user> <image> [image...]
pull_images() {
  local USER="$1"
  shift
  if [ "${USER}" = "root" ]; then
    podman pull --authfile "${RH_REGISTRY_AUTHFILE}" "$@"
  else
    runuser -l "${USER}" -c "podman pull --authfile ${RH_REGISTRY_AUTHFILE} $*"
  fi
}

# Installs certbot, requests a ZeroSSL cert, starts a TLS registry, and validates it responds.
# Requires ZEROSSL_EAB_KEY_ID and ZEROSSL_HMAC_KEY environment variables.
# Usage: setup_ssl_registry <hostname> [htpasswd_file]
setup_ssl_registry() {
  local HOST="$1"
  local HTPASSWD="$2"
  local CERT_DIR="/etc/letsencrypt/live/${HOST}"
  local MAX_CERT_RETRIES=3
  local RETRY=0

  dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-10.noarch.rpm
  dnf install -y certbot

  while [ $RETRY -lt $MAX_CERT_RETRIES ]; do
    set +x
    certbot certonly \
      --eab-kid "${ZEROSSL_EAB_KEY_ID}" \
      --eab-hmac-key "${ZEROSSL_HMAC_KEY}" \
      --server "https://acme.zerossl.com/v2/DV90" \
      --standalone --preferred-challenges http \
      -d "${HOST}" \
      --non-interactive --agree-tos -m trackbot@instruqt.com || true
    set -x

    if [ -f "${CERT_DIR}/fullchain.pem" ] && [ -f "${CERT_DIR}/privkey.pem" ]; then
      echo "SSL certificate obtained for ${HOST}" >> /tmp/progress.log
      break
    fi

    RETRY=$((RETRY + 1))
    echo "Certificate attempt ${RETRY} of ${MAX_CERT_RETRIES} failed, retrying in 15 seconds..." >> /tmp/progress.log
    sleep 15
  done

  if [ ! -f "${CERT_DIR}/fullchain.pem" ] || [ ! -f "${CERT_DIR}/privkey.pem" ]; then
    echo "FATAL: Failed to obtain SSL certificate for ${HOST} after ${MAX_CERT_RETRIES} attempts" >> /tmp/progress.log
    exit 1
  fi

  [ -f /var/log/letsencrypt/letsencrypt.log ] && rm /var/log/letsencrypt/letsencrypt.log || true

  if [ -n "${HTPASSWD}" ]; then
    podman run -d \
      --name registry \
      -p 443:5000 \
      -v "${HTPASSWD}":/auth/htpasswd:ro \
      -e REGISTRY_AUTH=htpasswd \
      -e "REGISTRY_AUTH_HTPASSWD_REALM=Registry Realm" \
      -e REGISTRY_AUTH_HTPASSWD_PATH=/auth/htpasswd \
      -v "${CERT_DIR}/fullchain.pem":/certs/fullchain.pem:ro \
      -v "${CERT_DIR}/privkey.pem":/certs/privkey.pem:ro \
      -e REGISTRY_HTTP_TLS_CERTIFICATE=/certs/fullchain.pem \
      -e REGISTRY_HTTP_TLS_KEY=/certs/privkey.pem \
      quay.io/mmicene/registry:2
  else
    podman run -d \
      --name registry \
      -p 443:5000 \
      -v "${CERT_DIR}/fullchain.pem":/certs/fullchain.pem:ro \
      -v "${CERT_DIR}/privkey.pem":/certs/privkey.pem:ro \
      -e REGISTRY_HTTP_TLS_CERTIFICATE=/certs/fullchain.pem \
      -e REGISTRY_HTTP_TLS_KEY=/certs/privkey.pem \
      quay.io/mmicene/registry:2
  fi

  local MAX_REG_RETRIES=5
  local HTTP_CODE
  RETRY=0
  while [ $RETRY -lt $MAX_REG_RETRIES ]; do
    HTTP_CODE=$(curl -sk -o /dev/null -w '%{http_code}' "https://${HOST}/v2/" 2>/dev/null) || true
    if [ "${HTTP_CODE}" = "401" ] || [ "${HTTP_CODE}" = "200" ]; then
      echo "Registry responding at ${HOST} (HTTP ${HTTP_CODE})" >> /tmp/progress.log
      return 0
    fi
    RETRY=$((RETRY + 1))
    echo "Registry not responding yet (HTTP ${HTTP_CODE}), retry ${RETRY} of ${MAX_REG_RETRIES}..." >> /tmp/progress.log
    sleep 5
  done

  echo "FATAL: Registry not responding after ${MAX_REG_RETRIES} attempts" >> /tmp/progress.log
  podman logs registry >> /tmp/progress.log 2>&1
  exit 1
}

# --- utility ---

add_local_host() {
  echo "10.0.2.2 $1" >> /etc/hosts
}

persist_env_var() {
  local NAME="$1"
  local VALUE="$2"
  echo "export ${NAME}=${VALUE}" >> /etc/profile.d/lab.sh
}

# Sets SETUP_FILES to the checked-out path. Call directly, not via $() — ERR trap must cover failures.
# Requires GIT_REPO and GIT_BRANCH environment variables (injected by the platform).
fetch_setup_files() {
  local REPO_PATH="$1"
  local TMPDIR="/tmp/lab-files-$$"
  git clone --single-branch --branch "${GIT_BRANCH:-main}" --no-checkout \
    --depth=1 --filter=tree:0 "${GIT_REPO}" "${TMPDIR}"
  git -C "${TMPDIR}" sparse-checkout set --no-cone "/${REPO_PATH}"
  git -C "${TMPDIR}" checkout
  SETUP_FILES="${TMPDIR}/${REPO_PATH}"
}

# --- cleanup ---

cleanup_registry_auth() {
  [ -f "${RH_REGISTRY_AUTHFILE}" ] && rm "${RH_REGISTRY_AUTHFILE}" || true
  podman logout --all 2>/dev/null || true
}

cleanup_subscription() {
  subscription-manager unregister 2>/dev/null || true
  subscription-manager clean
}

cleanup_certbot() {
  [ -f /var/log/letsencrypt/letsencrypt.log ] && rm /var/log/letsencrypt/letsencrypt.log || true
}

# Removes /tmp/lab-* directories. Leaves /tmp/progress.log and /tmp/setup-scripts/ intact.
cleanup_tmpfiles() {
  rm -rf /tmp/lab-*
}
