HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# On Git Bash/MSYS, the AWS CLI (a native Windows exe) can't resolve MSYS-style
# /c/... paths passed inside fileb:// paramfile URLs; convert to C:/... there.
native_path() { command -v cygpath >/dev/null 2>&1 && cygpath -m "$1" || printf '%s' "$1"; }
STATE_FILE="${HARNESS_DIR}/state/${CLUSTER_NAME}.env"

log()  { printf '\033[1;34m[harness]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[1;31m[harness:error]\033[0m %s\n' "$*" >&2; exit 1; }

load_state() { [ -f "$STATE_FILE" ] && source "$STATE_FILE" || true; }

save_state() {
  # save_state KEY VALUE  -- upserts a key into the per-cluster state file
  local key="$1" value="$2"
  mkdir -p "$(dirname "$STATE_FILE")"
  touch "$STATE_FILE"
  if grep -q "^${key}=" "$STATE_FILE" 2>/dev/null; then
    sed -i.bak "s|^${key}=.*|${key}=${value}|" "$STATE_FILE" && rm -f "${STATE_FILE}.bak"
  else
    echo "${key}=${value}" >> "$STATE_FILE"
  fi
}

require_state() {
  local key="$1"
  local val="${!key:-}"
  [ -n "$val" ] || err "Missing ${key} in state (${STATE_FILE}). Run 'bastion-up' first."
}

aws_tagged_id() {
  # aws_tagged_id <resource-type-flag e.g. Name=resource-type,Values=vpc> <Name tag value> <query>
  local filter="$1" name_value="$2" query="$3"
  aws ec2 describe-"${4}" --filters "Name=tag:Name,Values=${name_value}" "$filter" \
    --query "$query" --output text --region "$AWS_REGION" 2>/dev/null | awk '{print $1}'
}

ssh_bastion() {
  load_state
  require_state PUBLIC_IP
  ssh -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30 -o ServerAliveCountMax=6 \
    -i "$SSH_KEY_PATH" "ec2-user@${PUBLIC_IP}" "$@"
}

scp_to_bastion() {
  load_state
  require_state PUBLIC_IP
  scp -o StrictHostKeyChecking=accept-new -i "$SSH_KEY_PATH" "$1" "ec2-user@${PUBLIC_IP}:$2"
}

wait_for_ssh() {
  load_state
  require_state PUBLIC_IP
  log "Waiting for SSH on ${PUBLIC_IP}..."
  for _ in $(seq 1 30); do
    ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 -i "$SSH_KEY_PATH" \
      "ec2-user@${PUBLIC_IP}" "echo ok" >/dev/null 2>&1 && { log "SSH is up."; return 0; }
    sleep 5
  done
  err "Timed out waiting for SSH on ${PUBLIC_IP}"
}
