#!/bin/bash
# Common setup functions for ZT lab provisioning scripts.
# Source this file after fetching from the lab-setup repo — do not execute directly.
#
# Calling scripts should set the ERR trap immediately after sourcing:
#   trap 'echo "FATAL: setup failed at line ${LINENO}" >> /tmp/progress.log; exit 1' ERR
# Commands expected to fail should use || true to opt out of that behavior.

LAB_AUTHFILE=/tmp/lab-auth/auth.json

# Removes katello CA, cleans subscription-manager, and registers using
# ACTIVATION_KEY and ORG_ID environment variables.
register_system() {
  dnf -y remove katello-ca-consumer-* 2>/dev/null || true
  subscription-manager clean
  subscription-manager register --activationkey="${ACTIVATION_KEY}" --org="${ORG_ID}" --force
}

# Writes registry pull credentials to the shared auth file.
# Reads REGISTRY_PULL_TOKEN from the environment — do not pass the token as an argument.
# set +x suppresses tracing to keep the token out of logs.
# Usage: setup_pull_auth <registry>
setup_pull_auth() {
  local REGISTRY="$1"
  mkdir -p "$(dirname ${LAB_AUTHFILE})"
  set +x
  cat > "${LAB_AUTHFILE}" <<EOF
{
  "auths": {
    "${REGISTRY}": {
      "auth": "${REGISTRY_PULL_TOKEN}"
    }
  }
}
EOF
  set -x
  chmod 644 "${LAB_AUTHFILE}"
}

# Removes the lab auth file and logs out of any podman-managed registries.
cleanup_registry_auth() {
  [ -f "${LAB_AUTHFILE}" ] && rm "${LAB_AUTHFILE}"
  podman logout --all 2>/dev/null || true
}

# Unregisters and cleans subscription-manager state.
cleanup_subscription() {
  subscription-manager unregister 2>/dev/null || true
  subscription-manager clean
}

# Removes the letsencrypt log which may contain credential traces.
cleanup_certbot() {
  [ -f /var/log/letsencrypt/letsencrypt.log ] && rm /var/log/letsencrypt/letsencrypt.log
}

# Removes temporary directories created by this library (/tmp/lab-*).
# Leaves setup logs (/tmp/progress.log, /tmp/setup-scripts/) intact for review.
cleanup_tmpfiles() {
  rm -rf /tmp/lab-*
}

# Requests a ZeroSSL certificate and starts a TLS registry in one operation.
# Installs certbot, retries the ACME challenge up to 3 times, then starts the
# registry and validates it responds before returning.
# Optional second argument is a path to an htpasswd file to enable authentication.
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

  [ -f /var/log/letsencrypt/letsencrypt.log ] && rm /var/log/letsencrypt/letsencrypt.log

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

# Pulls one or more container images, optionally as a non-root user.
# Root pulls go directly to system storage; user pulls use runuser to
# land images in that user's storage.
# Usage: pull_images root <image> [image...]
#        pull_images rhel <image> [image...]
pull_images() {
  local USER="$1"
  shift
  if [ "${USER}" = "root" ]; then
    podman pull --authfile "${LAB_AUTHFILE}" "$@"
  else
    runuser -l "${USER}" -c "podman pull --authfile ${LAB_AUTHFILE} $*"
  fi
}

# Adds a local IP entry to /etc/hosts for internal cluster routing.
# Usage: add_local_host <hostname>
add_local_host() {
  echo "10.0.2.2 $1" >> /etc/hosts
}

# Enables libvirtd and configures NSS for container name resolution.
setup_libvirt() {
  systemctl enable --now libvirtd
  sed -i 's/hosts:\s\+ files/& libvirt libvirt_guest/' /etc/nsswitch.conf
}

# Sparse-checks out a path from the lab's own git repo.
# Requires GIT_REPO and GIT_BRANCH environment variables (injected by the platform).
# Prints the path to the checked-out files for use by the caller.
# Usage: SETUP_FILES=$(fetch_setup_files setup-files)
fetch_setup_files() {
  local REPO_PATH="$1"
  local TMPDIR="/tmp/lab-files-$$"
  git clone --single-branch --branch "${GIT_BRANCH:-main}" --no-checkout \
    --depth=1 --filter=tree:0 "${GIT_REPO}" "${TMPDIR}"
  git -C "${TMPDIR}" sparse-checkout set --no-cone "/${REPO_PATH}"
  git -C "${TMPDIR}" checkout
  echo "${TMPDIR}/${REPO_PATH}"
}

# Appends an export to /etc/profile.d/lab.sh so the value persists across terminal sessions.
# Usage: persist_env_var NAME value
persist_env_var() {
  local NAME="$1"
  local VALUE="$2"
  echo "export ${NAME}=${VALUE}" >> /etc/profile.d/lab.sh
}

# Configures Cockpit for showroom access and enables the socket.
# Requires GUID and DOMAIN environment variables.
setup_cockpit() {
  echo "[WebService]" > /etc/cockpit/cockpit.conf
  echo "Origins = https://cockpit-${GUID}.${DOMAIN}" >> /etc/cockpit/cockpit.conf
  echo "AllowUnencrypted = true" >> /etc/cockpit/cockpit.conf
  systemctl enable --now cockpit.socket
}
