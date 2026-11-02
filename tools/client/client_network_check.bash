#!/bin/bash
#
# Copyright (c) Microsoft Corporation. All rights reserved.
#
# client_network_check.bash
# -----------------
# Customer-side network triage for an Azure Managed Lustre File
# System (AMLFS) deployment.
#
# Run this script from a Linux VM that lives in the SAME subnet
# as your AMLFS cluster. This is strongly preferred — it is the
# only way to exercise the exact NSG / UDR / private-endpoint /
# DNS configuration that the AMLFS VMs see. If running in the
# same subnet is not possible, run it from a peered subnet whose
# routing and NSGs are intended to be identical, and treat the
# result as indicative rather than authoritative.
#
# This script checks the endpoints AMLFS uses for Azure Resource
# Manager, Azure Monitor diagnostic log/metric ingestion (sampled
# via well-known stamps), login.microsoftonline.com, crash-report
# upload, and the HSM storage account. It does NOT cover every
# Azure dependency exercised by AMLFS. So:
#   - If a check FAILS, fix the corresponding NSG / UDR / DNS /
#     private-endpoint configuration before opening an Azure
#     support ticket.
#   - If all checks PASS, network policy is unlikely to be the
#     cause but is not fully ruled out (some telemetry and
#     diagnostic paths are not exercised here).
#
# Dependencies: only `curl` and `az` (Azure CLI). `getent` and
# `timeout` are part of standard glibc/coreutils on every Linux
# distro that AMLFS supports.
#
# Prerequisites (for the Azure CLI checks in section 7):
#   The script must run in an authenticated Azure CLI context.
#   Establish one BEFORE running this script:
#     - On a VM with a Managed Identity assigned:
#           az login --identity
#     - As an interactive user:
#           az login
#   The signed-in identity (the VM's Managed Identity, or the
#   user) must have at least the 'Reader' role on the resource
#   group that contains the VM's NIC / virtual network. Without
#   it, the effective NSG / UDR checks will be skipped.
#   If you do not have (or do not want to set up) such an auth
#   context, run with --skip-az to bypass section 7 entirely;
#   the network reachability checks (sections 1-6) do not need
#   Azure CLI auth.
#
# Usage:
#   ./client_network_check.bash \
#       [--storage-url <https://account.blob.core.windows.net/...>] \
#       [--cloud public|AzureUSGovernment] \
#       [--skip-az] \
#       [--verbose]
#
# The --storage-url argument is the FULL URL of the HSM storage
# account endpoint used by AMLFS for HSM data movement (import,
# export, or both) — for example
#   https://myacct.blob.core.windows.net
# It must be supplied verbatim from the customer's HSM
# configuration; this script does NOT construct the hostname
# from an account name. If you omit --storage-url,
# the storage probes are skipped.
#
# Exit code: 0 if all checks pass; non-zero count of failures.

set -u
set -o pipefail

# ---------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------
STORAGE_URL=""
CLOUD=""
SKIP_AZ=0
VERBOSE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --storage-url)     STORAGE_URL="$2";     shift 2 ;;
        --cloud)           CLOUD="$2";           shift 2 ;;
        --skip-az)         SKIP_AZ=1;            shift   ;;
        --verbose|-v)      VERBOSE=1;            shift   ;;
        -h|--help)
            sed -n '2,66p' "$0"; exit 0 ;;
        *)
            echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done

# ---------------------------------------------------------------
# Validate --storage-url (if provided) and derive the hostname.
# We require a real URL so we never construct hostnames ourselves
# (DNS-partition / 5ksa accounts cannot be derived from an
# account name alone).
# ---------------------------------------------------------------
SA_HOST=""
if [[ -n "$STORAGE_URL" ]]; then
    # Accept https://host[:port][/path...]; reject anything else.
    if [[ ! "$STORAGE_URL" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?(/.*)?$ ]]; then
        echo "ERROR: --storage-url must be a full https:// URL" >&2
        echo "       got: ${STORAGE_URL}" >&2
        echo "       example: https://myacct.blob.core.windows.net" >&2
        exit 2
    fi
    SA_HOST="${STORAGE_URL#https://}"
    SA_HOST="${SA_HOST%%/*}"
    SA_HOST="${SA_HOST%%:*}"
    if [[ -z "$SA_HOST" || "$SA_HOST" != *.* ]]; then
        echo "ERROR: --storage-url has no valid hostname: ${STORAGE_URL}" >&2
        exit 2
    fi
fi

# ---------------------------------------------------------------
# Pretty output
# ---------------------------------------------------------------
if [[ -t 1 ]]; then
    C_R=$'\e[31m'; C_G=$'\e[32m'; C_Y=$'\e[33m'
    C_B=$'\e[34m'; C_0=$'\e[0m'
else
    C_R=""; C_G=""; C_Y=""; C_B=""; C_0=""
fi

PASS=0
FAIL=0
SKIP=0

ok()    { printf "  %sPASS%s  %s\n" "$C_G" "$C_0" "$*";  PASS=$((PASS+1)); }
bad()   { printf "  %sFAIL%s  %s\n" "$C_R" "$C_0" "$*";  FAIL=$((FAIL+1)); }
skip()  { printf "  %sSKIP%s  %s\n" "$C_Y" "$C_0" "$*";  SKIP=$((SKIP+1)); }
note()  { printf "  %sinfo%s  %s\n" "$C_B" "$C_0" "$*";                  }
section() { printf "\n%s== %s ==%s\n" "$C_B" "$*" "$C_0"; }
verb()  { if [[ $VERBOSE -eq 1 ]]; then printf "        %s\n" "$*"; fi; }

# ---------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------
need_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "missing required command: $1" >&2; exit 2; }
}
need_cmd curl
need_cmd getent
need_cmd timeout
if [[ $SKIP_AZ -eq 0 ]]; then
    command -v az >/dev/null 2>&1 || {
        echo "az CLI not found; re-run with --skip-az to bypass" >&2
        exit 2;
    }
fi

# Resolve a hostname via NSS (the same path the AMLFS agents
# use through Python's socket.gethostbyname). Print the first
# A record on success. On failure, if `nslookup` is available,
# fall back to it to distinguish:
#   - NSS misconfig / wrong DNS in /etc/resolv.conf
#     (NSS fails, direct DNS succeeds)
#   - Real DNS unreachability (both fail)
# A failure that nslookup recovers is reported on stderr so the
# caller can render an "info" tiebreaker line, and we still
# return non-zero — the AMLFS agent would see the failure too.
dns_resolve() {
    local host="$1"
    local ip
    ip=$(getent ahostsv4 "$host" 2>/dev/null | awk 'NR==1 {print $1}')
    if [[ -n "$ip" ]]; then
        echo "$ip"
        return 0
    fi
    if command -v nslookup >/dev/null 2>&1; then
        local nsl_ip
        nsl_ip=$(timeout 5 nslookup -type=A "$host" 2>/dev/null | \
                 awk '/^Address: / && $2 !~ /#/ {print $2; exit}')
        if [[ -n "$nsl_ip" ]]; then
            printf 'NSS-MISCONFIG %s\n' "$nsl_ip" >&2
        fi
    fi
    return 1
}

# HTTPS GET with a hard timeout. Returns the HTTP status code
# (or "000" on connect/TLS failure). We do not care about the
# response body — this is a connectivity-only probe.
https_probe() {
    local url="$1" code
    code=$(timeout 30 curl --silent --show-error \
                           --connect-timeout 10 --max-time 25 \
                           --output /dev/null \
                           --write-out '%{http_code}' \
                           "$url" 2>/dev/null) || code="000"
    echo "$code"
}

# Plain TCP probe via /dev/tcp (bash builtin) — used when
# we cannot make an HTTP request (e.g. AMQP 5671 for Service
# Bus relay, or to confirm 443 reachability without TLS noise).
tcp_probe() {
    local host="$1" port="$2"
    timeout 10 bash -c "exec 3<>/dev/tcp/${host}/${port}" \
        2>/dev/null && { exec 3<&-; exec 3>&-; return 0; }
    return 1
}

# ---------------------------------------------------------------
# 1. IMDS (Instance Metadata Service)
#    Geneva agent / wireserver depend on this; a failure here
#    indicates a hypervisor / vNIC stack problem, not subnet
#    network policy (169.254.169.254 traffic is intercepted by
#    the host's vNIC stack and never reaches the subnet).
# ---------------------------------------------------------------
section "IMDS (169.254.169.254)"
IMDS_URL="http://169.254.169.254/metadata/instance?api-version=2021-02-01"
IMDS_JSON=$(timeout 10 curl --silent --max-time 8 \
                            -H 'Metadata: true' "$IMDS_URL" 2>/dev/null) \
    || IMDS_JSON=""
if [[ -n "$IMDS_JSON" && "$IMDS_JSON" == *'"compute"'* ]]; then
    ok "IMDS reachable and returned instance metadata"
    # Extract a few useful fields (no jq dependency)
    VM_LOC=$(echo "$IMDS_JSON" | tr ',' '\n' | \
        grep -o '"location":"[^"]*"' | head -1 | cut -d'"' -f4)
    VM_VNET_SUB=$(echo "$IMDS_JSON" | tr ',' '\n' | \
        grep -o '"subscriptionId":"[^"]*"' | head -1 | cut -d'"' -f4)
    AZ_ENV=$(echo "$IMDS_JSON" | tr ',' '\n' | \
        grep -o '"azEnvironment":"[^"]*"' | head -1 | cut -d'"' -f4)
    note "location=${VM_LOC:-?}, azEnvironment=${AZ_ENV:-?}"
    note "subscription=${VM_VNET_SUB:-?}"
    if [[ -z "$CLOUD" && -n "$AZ_ENV" ]]; then
        CLOUD="$AZ_ENV"
    fi
else
    bad "IMDS unreachable — likely a hypervisor / vNIC stack issue"
    note "(traffic to 169.254.169.254 is host-local and cannot be"
    note " blocked by NSG / UDR / subnet routing)"
    note "raw response: ${IMDS_JSON:0:200}"
fi

# ---------------------------------------------------------------
# 2. Cloud-specific endpoint table
# ---------------------------------------------------------------
case "${CLOUD:-public}" in
    public|AzureCloud|AzurePublicCloud|"")
        ARM_HOST=management.azure.com
        MGMT_HOST=management.core.windows.net
        GENEVA_LOG_HOST=gcs.prod.monitoring.core.windows.net
        WATSON_HOST=azurewatsonanalysis-prod.core.windows.net
        LOGIN_HOST=login.microsoftonline.com
        ;;
    fairfax|AzureUSGovernment)
        ARM_HOST=management.usgovcloudapi.net
        MGMT_HOST=management.core.usgovcloudapi.net
        GENEVA_LOG_HOST=gcs.monitoring.core.usgovcloudapi.net
        WATSON_HOST=analysisservice.watson.azure.us
        LOGIN_HOST=login.microsoftonline.us
        ;;
    AzureChinaCloud|AzureGermanCloud)
        echo "--cloud value not supported: $CLOUD" >&2; exit 2 ;;
    *)
        echo "Unknown --cloud value: $CLOUD" >&2; exit 2 ;;
esac

# ---------------------------------------------------------------
# 3. DNS resolution
# ---------------------------------------------------------------
section "DNS resolution"
DNS_NAMES=(
    "$ARM_HOST"
    "$MGMT_HOST"
    "$GENEVA_LOG_HOST"
    "$WATSON_HOST"
    "$LOGIN_HOST"
)

# Storage account hostname (the single host parsed from the
# --storage-url the customer supplied). We do NOT construct it
# from <account>.<service>.<suffix> because that breaks for
# DNS-partitioned ("5ksa") accounts.
SA_HOSTS=()
if [[ -n "$SA_HOST" ]]; then
    SA_HOSTS+=("$SA_HOST")
fi

declare -A RESOLVED
for h in "${DNS_NAMES[@]}"; do
    tb=$(mktemp)
    if ip=$(dns_resolve "$h" 2>"$tb"); then
        ok  "$h -> $ip"
        RESOLVED["$h"]="$ip"
    else
        bad "cannot resolve $h"
        if grep -q '^NSS-MISCONFIG ' "$tb"; then
            tb_ip=$(awk '/^NSS-MISCONFIG / {print $2; exit}' "$tb")
            note "  nslookup tiebreaker: DNS server returned $tb_ip"
            note "  → NSS / /etc/nsswitch.conf / systemd-resolved"
            note "    is misconfigured; AMLFS agents will see this"
            note "    as a DNS failure even though the upstream"
            note "    resolver works"
        fi
    fi
    rm -f "$tb"
done

# DNS for the storage account host.
if [[ ${#SA_HOSTS[@]} -gt 0 ]]; then
    for h in "${SA_HOSTS[@]}"; do
        tb=$(mktemp)
        if ip=$(dns_resolve "$h" 2>"$tb"); then
            ok "$h -> $ip"
            RESOLVED["$h"]="$ip"
        else
            bad "cannot resolve $h (from --storage-url)"
            if grep -q '^NSS-MISCONFIG ' "$tb"; then
                tb_ip=$(awk '/^NSS-MISCONFIG / {print $2; exit}' "$tb")
                note "  (nslookup got $tb_ip — NSS misconfig)"
            fi
        fi
        rm -f "$tb"
    done
fi

# ---------------------------------------------------------------
# 4. TCP/443 reachability
# ---------------------------------------------------------------
section "TCP 443 reachability"
for h in "${DNS_NAMES[@]}"; do
    if [[ -z "${RESOLVED[$h]:-}" ]]; then
        skip "$h:443 (skipped — DNS failed)"
        continue
    fi
    if tcp_probe "$h" 443; then
        ok "$h:443 connect succeeded"
    else
        bad "$h:443 unreachable (NSG / UDR / private-endpoint?)"
    fi
done

# ---------------------------------------------------------------
# 5. Geneva logging endpoint (https GET)
#    The Geneva *log* upload path only. The Geneva *metrics*
#    (MDM) ingest endpoint is a separate hostname family and is
#    probed in section 5b below.
# ---------------------------------------------------------------
section "Geneva logging endpoint (GCS log upload path)"
GENEVA_URL="https://${GENEVA_LOG_HOST}/healthcheck"
code=$(https_probe "$GENEVA_URL")
case "$code" in
    2??|3??|4??)
        # Per Geneva team: status code is irrelevant; this is a
        # connectivity probe only. Anything that returns an HTTP
        # response means the TLS handshake completed and traffic
        # is flowing.
        ok "$GENEVA_URL responded HTTP $code (connectivity OK)"
        ;;
    000)
        bad "$GENEVA_URL connection failed (no HTTP response)"
        ;;
    5??)
        ok "$GENEVA_URL responded HTTP $code (server reachable)"
        ;;
    *)
        bad "$GENEVA_URL unexpected response: $code"
        ;;
esac

# ---------------------------------------------------------------
# 5b. Geneva metrics (MDM) ingest endpoint
# ---------------------------------------------------------------
case "$CLOUD" in
    public|AzureCloud|AzurePublicCloud|usgovcloud|AzureUSGovernment|"")
        MDM_STAMPS=(
            "azglobal-black.prod.microsoftmetrics.com"
            "azglobal-red.prod.microsoftmetrics.com"
        )
        ;;
    *)
        MDM_STAMPS=()
        ;;
esac

section "Geneva metrics (MDM) ingest endpoint (*.prod.microsoftmetrics.com)"
if [[ ${#MDM_STAMPS[@]} -eq 0 ]]; then
    skip "no known MDM stamps for cloud=$CLOUD; metrics check skipped"
else
    mdm_any_ok=0
    mdm_first_ok=""
    for h in "${MDM_STAMPS[@]}"; do
        url="https://${h}/"
        code=$(https_probe "$url")
        case "$code" in
            000)
                note "$h unreachable (no HTTP response)"
                ;;
            *)
                note "$h responded HTTP $code"
                mdm_any_ok=1
                [[ -z "$mdm_first_ok" ]] && mdm_first_ok="$h"
                ;;
        esac
    done
    if [[ $mdm_any_ok -eq 1 ]]; then
        ok "Geneva metrics path reachable (e.g. $mdm_first_ok)"
        note "wildcard *.prod.microsoftmetrics.com appears to be allowed;"
        note "the per-VM stamp assigned to AMLFS should also be reachable"
    else
        bad "no probed Geneva metrics stamp responded"
        note "if your firewall does not allow *.prod.microsoftmetrics.com,"
        note "AMLFS metrics upload will fail; ask your network admin to"
        note "permit that wildcard on TCP/443 outbound"
    fi
fi

# ---------------------------------------------------------------
# 6. HSM Storage account (queue + blob)
# ---------------------------------------------------------------
if [[ -n "$STORAGE_URL" ]]; then
    section "HSM Storage account ($SA_HOST)"
    # Anonymous GET against a private storage account returns
    # AuthenticationFailed (401/403) when the network path is
    # OK; it returns 000 on TCP/TLS failure. We map the former
    # to "reachable" and the latter to "unreachable".
    if [[ -z "${RESOLVED[$SA_HOST]:-}" ]]; then
        bad "$STORAGE_URL skipped — DNS for $SA_HOST failed"
    else
        code=$(https_probe "$STORAGE_URL")
        case "$code" in
            200|400|401|403|404)
                ok "$STORAGE_URL responded HTTP $code (network path OK)"
                ;;
            000)
                bad "$STORAGE_URL unreachable (no HTTP response)"
                bad "  (likely NSG, private-endpoint, or firewall block"
                bad "   between this VM and $SA_HOST)"
                ;;
            *)
                ok "$STORAGE_URL responded HTTP $code (server reachable)"
                ;;
        esac
    fi
else
    section "HSM Storage account"
    skip "no --storage-url provided; storage probes skipped"
    note "provide the full HSM storage URL used by AMLFS for HSM"
    note "data movement (import, export, or both), e.g."
    note "  --storage-url https://myacct.blob.core.windows.net"
fi

# ---------------------------------------------------------------
# 7. Effective NSG/route view from Azure (optional, needs az)
# ---------------------------------------------------------------
section "Effective NSG / UDR (this VM, via Azure CLI)"
if [[ $SKIP_AZ -eq 1 ]]; then
    skip "--skip-az specified"
elif ! az account show >/dev/null 2>&1; then
    skip "az CLI not signed in — run 'az login --identity' (VM MI) or"
    note "'az login' (user). The identity must have 'Reader' on the RG"
    note "containing the VM's NIC / VNet."
else
    # Find the NIC backing this VM via IMDS, then ask ARM for
    # the *effective* security rules and route table — this is
    # the source of truth, regardless of NSG/UDR layering.
    VM_RID=$(echo "$IMDS_JSON" | tr ',' '\n' | \
        grep -o '"resourceId":"[^"]*"' | head -1 | cut -d'"' -f4)
    if [[ -z "$VM_RID" ]]; then
        skip "could not extract VM resourceId from IMDS"
    else
        note "VM resourceId: $VM_RID"
        NIC_ID=$(az vm show --ids "$VM_RID" \
            --query 'networkProfile.networkInterfaces[0].id' \
            -o tsv 2>/dev/null) || NIC_ID=""
        if [[ -z "$NIC_ID" ]]; then
            skip "could not read NIC id (need 'Reader' on the VM)"
        else
            note "NIC: $NIC_ID"
            # Trigger NIC effective rule evaluation. Capture the
            # output rather than letting `az -o table` interleave
            # its multi-line table into our PASS/FAIL stream.
            #
            # Note: this surfaces effective Deny rules. Absence of
            # a Deny does NOT guarantee an Allow exists for the
            # destinations AMLFS needs — for that, rely on the
            # TCP/443 reachability checks above.
            # shellcheck disable=SC2016  # JMESPath literal, not shell expansion
            DENY_RULES=$(az network nic list-effective-nsg \
                  --ids "$NIC_ID" --query \
                  'value[].effectiveSecurityRules[?access==`Deny`].[name,destinationAddressPrefix,destinationPortRange,protocol,direction]' \
                  -o tsv 2>/dev/null) || DENY_RULES=""
            if [[ -z "$DENY_RULES" ]]; then
                ok "no effective Deny rules on this NIC"
            else
                # Filter to rules that could plausibly affect AMLFS
                # egress to public Azure IPs on TCP/443.
                AMLFS_DENIES=$(printf '%s\n' "$DENY_RULES" | awk -F '\t' \
                    '$5 == "Outbound" && ($4 == "Tcp" || $4 == "*") &&
                     ($3 == "*" || $3 ~ /(^|,| )443( |,|$)/ ||
                      $3 ~ /^[0-9]+-[0-9]+$/)')
                if [[ -z "$AMLFS_DENIES" ]]; then
                    ok "no Deny rules on TCP/443 outbound"
                    note "(other Deny rules exist but do not affect 443 outbound)"
                else
                    bad "Deny rules affecting outbound TCP/443:"
                    printf '%s\n' "$AMLFS_DENIES" | \
                        awk -F '\t' '{printf "        %s  -> %s:%s/%s (%s)\n",
                                      $1,$2,$3,$4,$5}'
                fi
            fi

            # Effective route table: only flag routes that force
            # AMLFS traffic through a Virtual Appliance / firewall
            # (these can silently drop egress to Storage/Geneva).
            # `nextHopType: None` on RFC1918 / Microsoft corp
            # ranges is Azure default plumbing and is benign.
            # shellcheck disable=SC2016  # JMESPath literal, not shell expansion
            ROUTES=$(az network nic show-effective-route-table \
                  --ids "$NIC_ID" --query \
                  'value[?nextHopType==`VirtualAppliance`].[addressPrefix,nextHopIpAddress,source]' \
                  -o tsv 2>/dev/null) || ROUTES=""
            if [[ -z "$ROUTES" ]]; then
                ok "no UDRs forcing traffic through a Virtual Appliance"
            else
                # 0.0.0.0/0 → NVA means all egress is funneled
                # through a customer firewall — that firewall
                # must allow every endpoint probed above.
                if printf '%s\n' "$ROUTES" | grep -q '^\["0\.0\.0\.0/0"\]'; then
                    bad "default route (0.0.0.0/0) sends all egress to NVA:"
                    printf '%s\n' "$ROUTES" | grep '^\["0\.0\.0\.0/0"\]' | \
                        awk -F '\t' '{printf "        next-hop %s (source %s)\n",$2,$3}'
                    bad "  verify the NVA permits 443 to every host probed above"
                else
                    ok "UDRs to Virtual Appliance exist but not for default route"
                    printf '%s\n' "$ROUTES" | \
                        awk -F '\t' '{printf "        %s -> NVA %s (%s)\n",$1,$2,$3}'
                fi
            fi
        fi
    fi
fi

# ---------------------------------------------------------------
# Summary
# ---------------------------------------------------------------
section "Summary"
printf "  PASS=%d  FAIL=%d  SKIP=%d\n" "$PASS" "$FAIL" "$SKIP"
echo
if [[ $FAIL -eq 0 ]]; then
    echo "${C_G}All required network paths are open from this VM.${C_0}"
    echo "If your AMLFS cluster is still unavailable, please open"
    echo "an Azure support ticket and attach this output."
    exit 0
else
    echo "${C_R}One or more checks failed.${C_0}"
    echo "These are the same dependencies AMLFS MDS/MGS and OSS"
    echo "VMs use. Fix the failing path (NSG outbound rule, UDR"
    echo "next hop, private DNS zone, or private-endpoint) on the"
    echo "AMLFS cluster's subnet, then re-run this script. AMLFS"
    echo "subnet documentation:"
    echo "  https://learn.microsoft.com/azure/azure-managed-lustre/amlfs-prerequisites"
    exit "$FAIL"
fi
