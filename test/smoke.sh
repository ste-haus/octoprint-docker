#!/usr/bin/env bash
#
# Boot an image under s6 and check it against the versions the repo declares.
#
#   test/smoke.sh <image>
#
# Expected versions come from .env (OCTOPRINT_VERSION) and the Dockerfile's
# ARG defaults (PYTHON_VERSION, JANUS_VERSION), so the checks track the repo.

set -euo pipefail

IMAGE="${1:?usage: $0 <image>}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${REPO_ROOT}/.env"
DOCKERFILE="${REPO_ROOT}/Dockerfile"

CONTAINER="octoprint-smoke-$$"
STARTUP_TIMEOUT_SECONDS=180
POLL_INTERVAL_SECONDS=2

OCTOPRINT_URL="http://localhost:5000/"
HAPROXY_URL="http://localhost:80/"
OCTOPRINT_LOG="/octoprint/octoprint/logs/octoprint.log"
LOG_ERROR_PATTERN=" - ERROR - "

# The two paths the Obico plugin requires from `dpkg -L janus`
JANUS_PACKAGE="janus"
JANUS_REQUIRED_PATHS=("bin/janus" "janus/plugins/libjanus_streaming.so")


failures=0

pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; failures=$((failures + 1)); }

dockerfile_arg() {
  sed -n "s/^ARG $1=//p" "${DOCKERFILE}" | head -n 1
}

in_container() {
  docker exec "${CONTAINER}" "$@"
}

cleanup() {
  if [ "${failures}" -gt 0 ]; then
    echo "--- container log"
    docker logs "${CONTAINER}" 2>&1 | tail -n 50 || true
    echo "--- ${OCTOPRINT_LOG}"
    in_container tail -n 50 "${OCTOPRINT_LOG}" 2>/dev/null || true
  fi
  docker rm -f "${CONTAINER}" >/dev/null 2>&1 || true
}
trap cleanup EXIT


# Expected versions
expected_octoprint="$(sed -n 's/^OCTOPRINT_VERSION=//p' "${ENV_FILE}")"
expected_python="$(dockerfile_arg PYTHON_VERSION)"
expected_janus="$(dockerfile_arg JANUS_VERSION)"

for name in expected_octoprint expected_python expected_janus; do
  if [ -z "${!name}" ]; then
    echo "Could not determine ${name} from the repo" >&2
    exit 1
  fi
done

echo "Expecting OctoPrint ${expected_octoprint}, Python ${expected_python}, Janus ${expected_janus}"


# Boot under s6 and wait for OctoPrint and the internal haproxy
docker run -d --name "${CONTAINER}" -e ENABLE_MJPG_STREAMER=false "${IMAGE}" >/dev/null

deadline=$((SECONDS + STARTUP_TIMEOUT_SECONDS))
until in_container curl -fsS -o /dev/null "${OCTOPRINT_URL}" 2>/dev/null; do
  if [ "${SECONDS}" -ge "${deadline}" ]; then
    fail "OctoPrint did not answer on ${OCTOPRINT_URL} within ${STARTUP_TIMEOUT_SECONDS}s"
    exit 1
  fi
  if [ "$(docker inspect -f '{{.State.Running}}' "${CONTAINER}")" != "true" ]; then
    fail "container exited during startup"
    exit 1
  fi
  sleep "${POLL_INTERVAL_SECONDS}"
done
pass "OctoPrint answers on ${OCTOPRINT_URL}"

if in_container curl -fsS -o /dev/null "${HAPROXY_URL}"; then
  pass "haproxy answers on ${HAPROXY_URL}"
else
  fail "haproxy did not answer on ${HAPROXY_URL}"
fi


# Versions match what the repo declares
actual_octoprint="$(in_container octoprint --version | awk '{print $NF}')"
if [ "${actual_octoprint}" = "${expected_octoprint}" ]; then
  pass "OctoPrint ${actual_octoprint}"
else
  fail "OctoPrint is ${actual_octoprint}, expected ${expected_octoprint}"
fi

actual_python="$(in_container python --version | awk '{print $2}')"
case "${actual_python}" in
  "${expected_python}" | "${expected_python}".*) pass "Python ${actual_python}" ;;
  *) fail "Python is ${actual_python}, expected ${expected_python}.x" ;;
esac

actual_janus="$(in_container janus --version 2>/dev/null | awk 'NR == 1 {print $NF}')"
if [ "${actual_janus}" = "${expected_janus}" ]; then
  pass "Janus ${actual_janus}"
else
  fail "Janus is ${actual_janus:-missing}, expected ${expected_janus}"
fi


# Janus is discoverable the way the Obico plugin looks for it
janus_files="$(in_container dpkg -L "${JANUS_PACKAGE}" 2>/dev/null || true)"
for path in "${JANUS_REQUIRED_PATHS[@]}"; do
  if grep -q "/${path}$" <<<"${janus_files}"; then
    pass "dpkg -L ${JANUS_PACKAGE} lists ${path}"
  else
    fail "dpkg -L ${JANUS_PACKAGE} does not list ${path}"
  fi
done


# Startup logged no errors
log_errors="$(in_container grep -F -- "${LOG_ERROR_PATTERN}" "${OCTOPRINT_LOG}" || true)"
if [ -z "${log_errors}" ]; then
  pass "no errors in ${OCTOPRINT_LOG}"
else
  fail "errors in ${OCTOPRINT_LOG}:"
  echo "${log_errors}"
fi


if [ "${failures}" -gt 0 ]; then
  echo "${failures} check(s) failed"
  exit 1
fi
echo "All checks passed"
