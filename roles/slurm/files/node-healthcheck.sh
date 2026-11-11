#!/bin/bash
# Slurm HealthCheckProgram (see slurm.conf). slurmd runs it as root every HealthCheckInterval.
#
# A failed check drains the node with a "healthcheck:" reason, so running jobs finish but no
# new job lands on it. When every check passes again the node is resumed, but only if this
# script drained it: a node an administrator drained by hand is never touched.
set -uo pipefail

NODE="$(hostname -s)"
TAG="healthcheck:"
# XID errors that point at the GPU or its driver rather than at a user's code:
# 48 double-bit ECC, 63/64 row remapping, 74 NVLink, 79 GPU fell off the bus,
# 92 high single-bit ECC rate, 94/95 contained/uncontained ECC, 119/120 GSP firmware.
CRITICAL_XIDS=" 48 63 64 74 79 92 94 95 119 120 "

# Shared file systems that must be mounted and answering. Override per site in
# /etc/sysconfig/node-healthcheck, for example HEALTHCHECK_MOUNTS="/shared/home /shared/apps".
HEALTHCHECK_MOUNTS="/shared"
if [ -r /etc/sysconfig/node-healthcheck ]; then
  # shellcheck source=/dev/null
  . /etc/sysconfig/node-healthcheck
fi

drain() {
  local reason="$TAG $*"
  logger -t node-healthcheck "$reason"
  scontrol update nodename="$NODE" state=drain reason="$reason"
  exit 1
}

is_true() {
  case "${1,,}" in
    1 | yes | true) return 0 ;;
    *) return 1 ;;
  esac
}

node_info="$(scontrol show node "$NODE" 2>/dev/null || true)"

# Shared file systems: home directories, job binaries and results live there.
for mount in $HEALTHCHECK_MOUNTS; do
  mountpoint -q "$mount" || drain "$mount is not mounted"
  timeout 10 stat -t "$mount" >/dev/null 2>&1 || drain "$mount does not respond"
done

# MUNGE: without it slurmd cannot authenticate to the controller.
munge -n 2>/dev/null | unmunge >/dev/null 2>&1 || drain "munge credential round trip failed"

# GPUs, only on nodes that advertise them to Slurm (Gres=gpu:N).
expected="$(grep -oP '\bGres=gpu:\K[0-9]+' <<<"$node_info" || true)"
if [ "${expected:-0}" -gt 0 ]; then
  command -v nvidia-smi >/dev/null 2>&1 || drain "nvidia-smi not found"

  found="$(timeout 60 nvidia-smi --query-gpu=index --format=csv,noheader 2>/dev/null | wc -l)"
  [ "$found" -eq "$expected" ] || drain "$found of $expected GPUs visible"

  while IFS=', ' read -r index ecc; do
    if [[ "$ecc" =~ ^[0-9]+$ ]] && [ "$ecc" -gt 0 ]; then
      drain "GPU $index has $ecc uncorrectable ECC errors"
    fi
  done < <(timeout 60 nvidia-smi --query-gpu=index,ecc.errors.uncorrected.volatile.total \
    --format=csv,noheader,nounits 2>/dev/null)

  # Row remapping (Ampere and newer): a pending remap needs a GPU reset, a failed one an RMA.
  while IFS=', ' read -r uuid pending failure; do
    is_true "$pending" && drain "GPU $uuid has a row remapping pending, reset it"
    is_true "$failure" && drain "GPU $uuid row remapping failed"
  done < <(timeout 60 nvidia-smi --query-remapped-rows=gpu_uuid,remapped_rows.pending,remapped_rows.failure \
    --format=csv,noheader 2>/dev/null)

  # Critical XIDs since boot keep the node drained until it is rebooted.
  while read -r xid; do
    [[ "$CRITICAL_XIDS" == *" $xid "* ]] && drain "critical GPU XID $xid in the kernel log since boot"
  done < <(journalctl -k -b --no-pager 2>/dev/null | grep -oP 'NVRM: Xid \([^)]*\): \K[0-9]+' | sort -un)
fi

# Every check passed: undo a drain this script made earlier.
state="$(grep -oP '\bState=\K\S+' <<<"$node_info" || true)"
reason="$(grep -oP '\bReason=\K.*' <<<"$node_info" || true)"
if [[ "$state" == *DRAIN* && "$reason" == "$TAG"* ]]; then
  logger -t node-healthcheck "all checks pass again, resuming $NODE"
  scontrol update nodename="$NODE" state=resume
fi
exit 0
