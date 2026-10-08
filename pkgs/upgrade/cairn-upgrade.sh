# Rolls a cairn cluster one machine at a time: `clan machines update` per
# machine, gated on etcd, apiserver and node health before and after. It
# deploys nothing itself. See docs/UPGRADES.md for the design and the manual
# runbook this automates.

usage() {
  cat <<'EOF'
Usage: cairn-upgrade [options]

Updates a cairn cluster's machines one at a time, in the order the flake's
`cairn-upgrade-plan.<cluster>` output gives: control plane first, then workers.

Options:
  --flake REF          Flake declaring the cluster (default: .)
  --cluster NAME       Cluster to upgrade; required when the flake has several
  --plan FILE          Read the plan JSON from FILE instead of evaluating it
  --only MACHINE       Update only MACHINE (repeatable)
  --from MACHINE       Resume the rollout at MACHINE, skipping those before it
  --skip-drain         Do not cordon and drain schedulable machines
  --no-snapshot        Do not take an etcd snapshot before the first update
  --snapshot-dir DIR   Where the etcd snapshot is written (default: .)
  --timeout SECONDS    How long each post-update gate waits (default: 600)
  --dry-run            Print the plan and every step without acting
  --rollback MACHINE   Switch MACHINE back to its previous generation and exit
  -h, --help           Show this help

etcd is reached with the client certificate from the current kubeconfig
context, which cairn signs with the same CA etcd trusts. Set ETCDCTL_CACERT,
ETCDCTL_CERT and ETCDCTL_KEY to use other credentials.
EOF
}

die() {
  echo "cairn-upgrade: $*" >&2
  exit 1
}

log() {
  echo "==> $*" >&2
}

flake="."
cluster=""
plan_file=""
only=()
from=""
skip_drain=0
snapshot=1
snapshot_dir="."
timeout=600
dry_run=0
rollback=""

while [ $# -gt 0 ]; do
  case "$1" in
    --flake) flake="${2:?--flake needs a value}"; shift 2 ;;
    --cluster) cluster="${2:?--cluster needs a value}"; shift 2 ;;
    --plan) plan_file="${2:?--plan needs a value}"; shift 2 ;;
    --only) only+=("${2:?--only needs a value}"); shift 2 ;;
    --from) from="${2:?--from needs a value}"; shift 2 ;;
    --skip-drain) skip_drain=1; shift ;;
    --no-snapshot) snapshot=0; shift ;;
    --snapshot-dir) snapshot_dir="${2:?--snapshot-dir needs a value}"; shift 2 ;;
    --timeout) timeout="${2:?--timeout needs a value}"; shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    --rollback) rollback="${2:?--rollback needs a value}"; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
done

# ─── Plan ──────────────────────────────────────────────────────────────────

if [ -n "$plan_file" ]; then
  plans=$(cat "$plan_file")
else
  plans=$(nix eval --json "$flake#cairn-upgrade-plan") ||
    die "could not evaluate $flake#cairn-upgrade-plan; does the flake import cairn's flake module and declare a cluster under cairn.clusters?"
fi

if [ -z "$cluster" ]; then
  mapfile -t names < <(jq -r 'keys[]' <<<"$plans")
  case "${#names[@]}" in
    0) die "the flake declares no cairn.clusters" ;;
    1) cluster="${names[0]}" ;;
    *) die "the flake declares several clusters (${names[*]}); pick one with --cluster" ;;
  esac
fi

plan=$(jq -e --arg c "$cluster" '.[$c]' <<<"$plans") || die "no cluster named $cluster in the plan"
apiserver_port=$(jq -r '.apiserverPort' <<<"$plan")
mapfile -t machines < <(jq -r '.machines[].machine' <<<"$plan")

# One field of one machine's plan entry.
field() {
  jq -r --arg m "$1" --arg k "$2" '.machines[] | select(.machine == $m) | .[$k]' <<<"$plan"
}

in_plan() {
  local m
  for m in "${machines[@]}"; do
    [ "$m" = "$1" ] && return 0
  done
  return 1
}

for m in "${only[@]}" ${from:+"$from"} ${rollback:+"$rollback"}; do
  in_plan "$m" || die "$m is not a machine in cluster $cluster (machines: ${machines[*]})"
done

# ─── Rollback ──────────────────────────────────────────────────────────────

if [ -n "$rollback" ]; then
  target=$(field "$rollback" targetHost)
  cmd='nix-env --profile /nix/var/nix/profiles/system --rollback && /nix/var/nix/profiles/system/bin/switch-to-configuration switch'
  if [ "$dry_run" = 1 ]; then
    echo "would run on $target: $cmd"
    exit 0
  fi
  log "rolling $rollback ($target) back to its previous generation"
  # shellcheck disable=SC2029 # expanded locally on purpose
  ssh "$target" "$cmd"
  exit 0
fi

# ─── Selection ─────────────────────────────────────────────────────────────

selected=()
started=$([ -z "$from" ] && echo 1 || echo 0)
for m in "${machines[@]}"; do
  if [ "$m" = "$from" ]; then started=1; fi
  [ "$started" = 1 ] || continue
  if [ "${#only[@]}" -gt 0 ]; then
    keep=0
    for o in "${only[@]}"; do
      if [ "$o" = "$m" ]; then keep=1; fi
    done
    [ "$keep" = 1 ] || continue
  fi
  selected+=("$m")
done

[ "${#selected[@]}" -gt 0 ] || die "nothing to update"

mapfile -t etcd_machines < <(jq -r '.machines[] | select(.etcd) | .machine' <<<"$plan")
mapfile -t apiserver_machines < <(jq -r '.machines[] | select(.apiserver) | .machine' <<<"$plan")

# ─── Dry run ───────────────────────────────────────────────────────────────

if [ "$dry_run" = 1 ]; then
  echo "cluster $cluster: ${#selected[@]} machine(s), in order"
  if [ "$snapshot" = 1 ] && [ "${#etcd_machines[@]}" -gt 0 ]; then
    echo "snapshot etcd into $snapshot_dir"
  fi
  for m in "${selected[@]}"; do
    roles=$(jq -r --arg m "$m" '.machines[] | select(.machine == $m) | [(if .etcd then "etcd" else empty end), (if .apiserver then "apiserver" else empty end), (if .kubelet then "kubelet" else empty end)] | join(",")' <<<"$plan")
    echo "$m ($(field "$m" role); $roles)"
    echo "  pre-gate: every other etcd member healthy, every other apiserver /readyz"
    if [ "$skip_drain" = 0 ] && [ "$(field "$m" drain)" = true ]; then
      echo "  cordon and drain $m"
    fi
    echo "  clan machines update --flake $flake $m"
    post=()
    if [ "$(field "$m" etcd)" = true ]; then post+=("etcd member healthy"); fi
    if [ "$(field "$m" apiserver)" = true ]; then post+=("/readyz on :$apiserver_port"); fi
    if [ "$(field "$m" kubelet)" = true ]; then
      v=$(field "$m" kubernetesVersion)
      if [ "$v" = null ]; then
        post+=("node Ready")
      else
        post+=("node Ready at v$v")
      fi
    fi
    if [ "${#post[@]}" -gt 0 ]; then
      echo "  post-gate: $(jq -rn '$ARGS.positional | join(", ")' --args "${post[@]}")"
    fi
    if [ "$skip_drain" = 0 ] && [ "$(field "$m" drain)" = true ]; then
      echo "  uncordon $m"
    fi
  done
  exit 0
fi

# ─── Credentials ───────────────────────────────────────────────────────────

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

# Writes one credential from the current kubeconfig context, which carries
# either inline base64 data or a file path.
kubeconfig_credential() {
  local data_path=$1 file_path=$2 out=$3 data file
  data=$(kubectl config view --raw --minify -o "jsonpath={$data_path}")
  if [ -n "$data" ]; then
    base64 -d <<<"$data" >"$out"
  else
    file=$(kubectl config view --raw --minify -o "jsonpath={$file_path}")
    [ -n "$file" ] || die "the current kubeconfig context has no ${data_path##*.}; set ETCDCTL_CACERT, ETCDCTL_CERT and ETCDCTL_KEY"
    cp "$file" "$out"
  fi
  chmod 600 "$out"
}

# Each credential not supplied comes from the kubeconfig on its own, so
# overriding one keeps the others. The CA also verifies the apiservers.
export ETCDCTL_API=3
if [ -z "${ETCDCTL_CACERT:-}" ]; then
  kubeconfig_credential .clusters[0].cluster.certificate-authority-data .clusters[0].cluster.certificate-authority "$workdir/ca.crt"
  export ETCDCTL_CACERT="$workdir/ca.crt"
fi
if [ "${#etcd_machines[@]}" -gt 0 ]; then
  if [ -z "${ETCDCTL_CERT:-}" ]; then
    kubeconfig_credential .users[0].user.client-certificate-data .users[0].user.client-certificate "$workdir/client.crt"
    export ETCDCTL_CERT="$workdir/client.crt"
  fi
  if [ -z "${ETCDCTL_KEY:-}" ]; then
    kubeconfig_credential .users[0].user.client-key-data .users[0].user.client-key "$workdir/client.key"
    export ETCDCTL_KEY="$workdir/client.key"
  fi
fi

# ─── Gates ─────────────────────────────────────────────────────────────────

etcd_healthy() {
  etcdctl --endpoints="https://$(field "$1" ip):2379" --command-timeout=5s endpoint health >/dev/null 2>&1
}

# /readyz on the apiserver's own port rather than the VIP, so a ready backend
# is never masked by another one answering for it. The apiserver certificate
# lists every control-plane IP, so the cluster CA verifies it there.
apiserver_ready() {
  curl -sf --cacert "$ETCDCTL_CACERT" -o /dev/null --max-time 5 "https://$(field "$1" ip):$apiserver_port/readyz"
}

node_ready() {
  local m=$1 want status version
  want=$(field "$m" kubernetesVersion)
  read -r status version < <(kubectl get node "$m" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status} {.status.nodeInfo.kubeletVersion}{"\n"}' 2>/dev/null) || return 1
  [ "$status" = True ] || return 1
  if [ "$want" != null ]; then
    case "$version" in
      "v$want".*) ;;
      *) return 1 ;;
    esac
  fi
}

wait_for() {
  local what=$1 deadline=$((SECONDS + timeout))
  shift
  until "$@"; do
    [ "$SECONDS" -lt "$deadline" ] || die "gave up after ${timeout}s waiting for $what; the rollout stopped here"
    sleep 5
  done
  log "$what"
}

# The quorum-loss guard: refuse to take a machine down while any other member
# is already unhealthy. The machine about to update is only reported, since
# updating it may be the fix.
pre_gate() {
  local target=$1 m failed=()
  for m in "${etcd_machines[@]}"; do
    etcd_healthy "$m" && continue
    if [ "$m" = "$target" ]; then
      log "warning: $m's own etcd member is unhealthy"
    else
      failed+=("etcd on $m")
    fi
  done
  for m in "${apiserver_machines[@]}"; do
    apiserver_ready "$m" && continue
    if [ "$m" = "$target" ]; then
      log "warning: $m's own apiserver is not ready"
    else
      failed+=("apiserver on $m")
    fi
  done
  [ "${#failed[@]}" -eq 0 ] || die "not updating $target: unhealthy: ${failed[*]}"
}

post_gate() {
  local m=$1
  if [ "$(field "$m" etcd)" = true ]; then
    wait_for "$m: etcd member healthy" etcd_healthy "$m"
  fi
  if [ "$(field "$m" apiserver)" = true ]; then
    wait_for "$m: apiserver ready" apiserver_ready "$m"
  fi
  if [ "$(field "$m" kubelet)" = true ]; then
    wait_for "$m: node Ready" node_ready "$m"
  fi
}

# ─── Rollout ───────────────────────────────────────────────────────────────

if [ "$snapshot" = 1 ] && [ "${#etcd_machines[@]}" -gt 0 ]; then
  mkdir -p "$snapshot_dir"
  out="$snapshot_dir/etcd-$cluster-$(date -u +%Y%m%dT%H%M%SZ).db"
  taken=0
  for m in "${etcd_machines[@]}"; do
    if etcd_healthy "$m" && etcdctl --endpoints="https://$(field "$m" ip):2379" snapshot save "$out" >/dev/null; then
      taken=1
      break
    fi
  done
  [ "$taken" = 1 ] || die "could not take an etcd snapshot from any member"
  log "etcd snapshot saved to $out"
fi

for m in "${selected[@]}"; do
  log "$m: checking cluster health"
  pre_gate "$m"

  drain=0
  if [ "$skip_drain" = 0 ] && [ "$(field "$m" drain)" = true ]; then
    drain=1
    kubectl cordon "$m"
    if ! kubectl drain "$m" --ignore-daemonsets --delete-emptydir-data --timeout="${timeout}s"; then
      kubectl uncordon "$m"
      die "could not drain $m; uncordoned it and stopped before updating"
    fi
  fi

  log "$m: updating"
  clan machines update --flake "$flake" "$m"

  post_gate "$m"
  if [ "$drain" = 1 ]; then
    kubectl uncordon "$m"
  fi
  log "$m: done"
done

log "cluster $cluster: updated ${selected[*]}"
