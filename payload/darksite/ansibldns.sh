#!/usr/bin/env bash
set -euo pipefail

INVENTORY="${1:-inventory/hosts.ini}"

RESOLVER1="10.100.10.2"
RESOLVER2="10.100.10.3"

CHECK_AAAA="${CHECK_AAAA:-0}"
CHECK_PTR="${CHECK_PTR:-0}"
TIMEOUT="${TIMEOUT:-2}"

banner() {
  echo "============================================================"
  echo "DNS VERIFY"
  echo "Inventory : ${INVENTORY}"
  echo "Resolvers : ${RESOLVER1} , ${RESOLVER2}"
  echo "Check AAAA: ${CHECK_AAAA}"
  echo "Check PTR : ${CHECK_PTR}"
  echo "Timeout  : ${TIMEOUT}s"
  echo "============================================================"
  echo
}

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: required command '$1' not found"
    exit 1
  }
}

extract_hosts() {
  awk '
    BEGIN { in_vars=0 }
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    /^\[.*\]$/ {
      if ($0 ~ /:vars\]$/) in_vars=1
      else in_vars=0
      next
    }
    in_vars==1 { next }
    $1 ~ /^[a-zA-Z0-9.-]+$/ { print $1 }
  ' "$INVENTORY" | sort -u
}

resolve_record() {
  local host="$1"
  local type="$2"
  local res="$3"

  dig +time="${TIMEOUT}" +tries=1 @"${res}" "${host}" "${type}" +short 2>/dev/null | head -n1 || true
}

main() {
  need dig
  need awk
  need sort
  need head

  banner

  mapfile -t HOSTS < <(extract_hosts)

  echo "Testing ${#HOSTS[@]} hosts..."
  echo

  OK=0
  FAIL=0
  FAIL_LIST=()

  for h in "${HOSTS[@]}"; do
    [[ "$h" == *"="* ]] && continue
    [[ "$h" == */* ]] && continue

    A1="$(resolve_record "$h" A "$RESOLVER1")"
    A2="$(resolve_record "$h" A "$RESOLVER2")"

    if [[ -n "$A1" || -n "$A2" ]]; then
      IP="${A1:-$A2}"
      printf "OK     %-26s A=%s\n" "$h" "$IP"
      ((OK++))
    else
      printf "FAIL   %-26s NO A record from either resolver\n" "$h"
      FAIL_LIST+=("$h")
      ((FAIL++))
      continue
    fi

    if [[ "$CHECK_AAAA" == "1" ]]; then
      AAAA1="$(resolve_record "$h" AAAA "$RESOLVER1")"
      AAAA2="$(resolve_record "$h" AAAA "$RESOLVER2")"
      [[ -n "$AAAA1" || -n "$AAAA2" ]] && printf "       %-26s AAAA=%s\n" "$h" "${AAAA1:-$AAAA2}"
    fi

    if [[ "$CHECK_PTR" == "1" ]]; then
      PTR1="$(dig +time="${TIMEOUT}" +tries=1 @"${RESOLVER1}" -x "$IP" +short 2>/dev/null | head -n1 || true)"
      PTR2="$(dig +time="${TIMEOUT}" +tries=1 @"${RESOLVER2}" -x "$IP" +short 2>/dev/null | head -n1 || true)"
      [[ -n "$PTR1" || -n "$PTR2" ]] && printf "       %-26s PTR=%s\n" "$h" "${PTR1:-$PTR2}"
    fi
  done

  echo
  echo "============================================================"
  echo "RESULT"
  printf "OK   : %d\n" "$OK"
  printf "FAIL : %d\n" "$FAIL"
  echo "============================================================"

  if [[ "$FAIL" -gt 0 ]]; then
    echo
    echo "Failed hosts:"
    for x in "${FAIL_LIST[@]}"; do
      echo "  - $x"
    done
    exit 2
  fi
}

main "$@"
