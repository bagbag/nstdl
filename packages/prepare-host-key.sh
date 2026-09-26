if [[ $# -ne 1 ]]; then
  echo "usage: prepare-host-key HOST" >&2
  exit 2
fi

host=$1
if [[ ! $host =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
  echo "HOST must be a path-safe name" >&2
  exit 2
fi
root=$(git rev-parse --show-toplevel 2>/dev/null) || {
  echo "run from the Git consumer flake root" >&2
  exit 2
}
if [[ ! -f flake.nix || $root != "$(pwd -P)" ]]; then
  echo "run from the Git consumer flake root" >&2
  exit 2
fi

directory=".installer-host-keys/$host"
key="$directory/ssh_host_ed25519_key"
if [[ -e $directory || -L $directory ]]; then
  echo "host key directory already exists: $directory" >&2
  exit 1
fi
umask 077
mkdir -p -- .installer-host-keys
if ! git check-ignore -q -- "$key" || ! git check-ignore -q -- "$key.pub"; then
  if [[ -e .installer-host-keys/.gitignore ]]; then
    echo ".installer-host-keys/.gitignore must ignore host key directories" >&2
    exit 1
  fi
  printf '*/\n' > .installer-host-keys/.gitignore
  echo "Created .installer-host-keys/.gitignore; include it in the consumer Git source" >&2
fi
mkdir -m 700 -- "$directory"
ssh-keygen -q -t ed25519 -N '' -C '' -f "$key" </dev/null
read -r algorithm material _ < "$key.pub"
public="$algorithm $material"

printf 'Private key: %s\nPublic key: %s\nFingerprint: %s\n' \
  "$key" "$public" "$(ssh-keygen -lf "$key.pub")"
printf 'Paste into hosts/%s/default.nix:\n  secrets.hostPubkey = "%s";\n' "$host" "$public"
