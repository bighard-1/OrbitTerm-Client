#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 || "$1" != /* || "$2" != /* ]]; then
  echo "Usage: run_isolated_qa.sh /absolute/OrbitTerm-QA-NAME /absolute/orbitterm-linux [args...]" >&2
  exit 2
fi

qa_root="$1"
binary="$2"
shift 2

# A QA profile must never silently reuse the installed app's state/cursor or
# Secret Service store. Require a dedicated, explicit root before creating it.
if [[ "$(basename -- "$qa_root")" != OrbitTerm-QA-* || -L "$qa_root" || ! -x "$binary" ]]; then
  echo "Refusing non-QA root, symlinked root, or non-executable binary." >&2
  exit 2
fi

umask 077
mkdir -p -- "$qa_root"
qa_root="$(cd -- "$qa_root" && pwd -P)"
if [[ "$qa_root" == / || "$qa_root" == "$HOME" ||
      "$(basename -- "$qa_root")" != OrbitTerm-QA-* ]]; then
  echo "Refusing broad QA root." >&2
  exit 2
fi
if [[ "$(stat -c %u -- "$qa_root")" != "$(id -u)" ||
      "$(stat -c %a -- "$qa_root")" != 700 ]]; then
    echo "QA root must be owned by the current user and mode 0700." >&2
    exit 2
fi

for part in data config state cache runtime; do
  directory="$qa_root/$part"
  if [[ -L "$directory" ]]; then
    echo "Refusing symlinked QA directory: $part" >&2
    exit 2
  fi
  mkdir -p -- "$directory"
  if [[ "$(stat -c %u -- "$directory")" != "$(id -u)" ||
        "$(stat -c %a -- "$directory")" != 700 ]]; then
    echo "QA directory must be owned by the current user and mode 0700: $part" >&2
    exit 2
  fi
done

export XDG_DATA_HOME="$qa_root/data"
export XDG_CONFIG_HOME="$qa_root/config"
export XDG_STATE_HOME="$qa_root/state"
export XDG_CACHE_HOME="$qa_root/cache"
export XDG_RUNTIME_DIR="$qa_root/runtime"

exec dbus-run-session -- "$binary" "$@"
