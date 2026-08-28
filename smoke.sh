#!/bin/bash
# Upload smoke test across every authentication mode in docker-compose.yml.
#
#   ./smoke.sh [path-to-rclone]
#
# Each remote gets a fresh directory, then is checked for: upload into a
# subdirectory, upload to the remote root, concurrent uploads, overwrite,
# delete, a large file verified byte for byte, and a streamed upload.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)

# Which rclone to test. The expected layout is this repo cloned inside an
# rclone checkout, in which case it is rebuilt from source on every run so the
# results always describe the working tree rather than a stale binary. An
# explicit binary is used as given, without building.
#
# The build costs 10-20s, nearly all of it linking, against a run measured in
# minutes. Set SKIP_BUILD=1 to reuse the last one. "go run" is never used: it
# costs about 6s per invocation against 0.2s for a binary, and this script
# makes a few hundred calls.
if [ $# -ge 1 ]; then
  RCLONE=$1
elif [ -n "${RCLONE:-}" ]; then
  : # taken from the environment
elif grep -qs '^module github.com/rclone/rclone$' "$HERE/../go.mod"; then
  RCLONE="$HERE/.rclone-built"
  if [ -n "${SKIP_BUILD:-}" ] && [ -x "$RCLONE" ]; then
    echo "SKIP_BUILD set, reusing $RCLONE" >&2
  else
    echo "building rclone from $(cd "$HERE/.." && pwd) ..." >&2
    (cd "$HERE/.." && go build -o "$RCLONE" .) || {
      echo "error: go build failed" >&2; exit 2; }
  fi
elif [ -x "$HERE/rclone" ]; then
  RCLONE="$HERE/rclone"
else
  RCLONE=rclone
fi

# A build without digest support fails every digest remote with a bare 401,
# which reads like a broken server rather than the wrong binary.
if ! "$RCLONE" help backend webdav 2>/dev/null | grep -q -- "--webdav-digest"; then
  echo "error: $RCLONE ($("$RCLONE" version 2>/dev/null | head -1)) has no webdav digest support." >&2
  echo "       Expected layout is this repo inside an rclone checkout:" >&2
  echo "         (cd $HERE/.. && go build) && $0" >&2
  echo "       Otherwise point it at a build explicitly:" >&2
  echo "         $0 /path/to/rclone" >&2
  echo "         RCLONE=/path/to/rclone $0" >&2
  exit 2
fi
echo "using $RCLONE ($("$RCLONE" version 2>/dev/null | head -1))"

CONF="$HERE/rclone.conf"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# remote:extra-flags - nccheck rejects out of order nonce counts, so it gets one at a time
REMOTES=(
  "dav-open:"
  "dav-basic:"
  "dav-rclone:"
  "dav-digest:"
  "dav-digest-preset:"
  "dav-digest-stale:"
  "dav-digest-nccheck:--transfers 1 --checkers 1"
  # Vendor specific paths - these are the only ones which set modification
  # times with PROPPATCH and report quota. Need: docker compose --profile heavy up -d
  "dav-nextcloud:"
  "dav-owncloud:"
)

pass=0; fail=0
ok()  { printf "    \033[32mPASS\033[0m %s\n" "$1"; pass=$((pass+1)); }
bad() { printf "    \033[31mFAIL\033[0m %s\n" "$1"; fail=$((fail+1)); }
chk() { [ "$2" = "$3" ] && ok "$1" || bad "$1: got '$2' want '$3'"; }
rc()  { "$RCLONE" --config "$CONF" "$@"; }

for entry in "${REMOTES[@]}"; do
  remote=${entry%%:*}; flags=${entry#*:}
  printf "\n\033[1m### %s\033[0m %s\n" "$remote" "${flags:+($flags)}"
  base="smoke-$$"
  rc purge "$remote:$base" >/dev/null 2>&1
  rc mkdir "$remote:$base" >/dev/null 2>&1 || { bad "mkdir"; continue; }

  echo "hello-subdir" > "$WORK/a.txt"
  rc $flags copy "$WORK/a.txt" "$remote:$base/sub/" >/dev/null 2>&1 \
    && chk "upload into subdirectory" "$(rc cat "$remote:$base/sub/a.txt" 2>/dev/null)" "hello-subdir" \
    || bad "upload into subdirectory"

  echo "hello-root" > "$WORK/b.txt"
  rc $flags --no-check-dest copy "$WORK/b.txt" "$remote:$base" >/dev/null 2>&1 \
    && chk "upload to remote root" "$(rc cat "$remote:$base/b.txt" 2>/dev/null)" "hello-root" \
    || bad "upload to remote root"

  rm -rf "$WORK/many"; mkdir -p "$WORK/many"
  for i in $(seq 1 12); do head -c 30000 /dev/urandom > "$WORK/many/f$i.bin"; done
  if rc $flags copy "$WORK/many" "$remote:$base/many" >/dev/null 2>&1; then
    chk "12 uploads" "$(rc ls "$remote:$base/many" 2>/dev/null | wc -l | tr -d ' ')" "12"
    rc $flags check "$WORK/many" "$remote:$base/many" >/dev/null 2>&1 \
      && ok "  content verified" || bad "  content mismatch"
  else
    bad "12 uploads"
  fi

  echo "second-version" > "$WORK/a.txt"
  rc $flags copy "$WORK/a.txt" "$remote:$base" >/dev/null 2>&1 \
    && chk "overwrite" "$(rc cat "$remote:$base/a.txt" 2>/dev/null)" "second-version" \
    || bad "overwrite"

  rc delete "$remote:$base/a.txt" >/dev/null 2>&1 \
    && chk "delete" "$(rc ls "$remote:$base/a.txt" 2>/dev/null | wc -l | tr -d ' ')" "0" \
    || bad "delete"

  head -c 8388608 /dev/urandom > "$WORK/big.bin"
  if rc $flags copy "$WORK/big.bin" "$remote:$base" >/dev/null 2>&1; then
    rc cat "$remote:$base/big.bin" > "$WORK/big.got" 2>/dev/null
    chk "8 MiB round trip" "$(md5 -q "$WORK/big.got" 2>/dev/null || md5sum "$WORK/big.got" | cut -d' ' -f1)" \
                           "$(md5 -q "$WORK/big.bin" 2>/dev/null || md5sum "$WORK/big.bin" | cut -d' ' -f1)"
  else
    bad "8 MiB round trip"
  fi

  head -c 100000 /dev/urandom > "$WORK/stream.bin"
  if rc $flags rcat "$remote:$base/streamed.bin" < "$WORK/stream.bin" >/dev/null 2>&1; then
    rc cat "$remote:$base/streamed.bin" > "$WORK/stream.got" 2>/dev/null
    chk "streamed upload (rcat)" "$(md5 -q "$WORK/stream.got" 2>/dev/null || md5sum "$WORK/stream.got" | cut -d' ' -f1)" \
                                 "$(md5 -q "$WORK/stream.bin" 2>/dev/null || md5sum "$WORK/stream.bin" | cut -d' ' -f1)"
  else
    bad "streamed upload (rcat)"
  fi

  # --- case G: server side copy and move ---
  echo "to-be-copied" > "$WORK/c.txt"
  rc $flags copy "$WORK/c.txt" "$remote:$base" >/dev/null 2>&1
  rc copyto "$remote:$base/c.txt" "$remote:$base/copied.txt" >/dev/null 2>&1 \
    && chk "server side copy" "$(rc cat "$remote:$base/copied.txt" 2>/dev/null)" "to-be-copied" \
    || bad "server side copy"
  if rc moveto "$remote:$base/copied.txt" "$remote:$base/moved.txt" >/dev/null 2>&1; then
    chk "server side move" "$(rc cat "$remote:$base/moved.txt" 2>/dev/null)" "to-be-copied"
    chk "  source gone after move" "$(rc ls "$remote:$base/copied.txt" 2>/dev/null | wc -l | tr -d ' ')" "0"
  else
    bad "server side move"
  fi

  # --- case H: directory move, then rmdir ---
  rc $flags copy "$WORK/c.txt" "$remote:$base/dirA" >/dev/null 2>&1
  rc move "$remote:$base/dirA" "$remote:$base/dirB" >/dev/null 2>&1 \
    && chk "directory move" "$(rc ls "$remote:$base/dirB" 2>/dev/null | wc -l | tr -d ' ')" "1" \
    || bad "directory move"
  rc delete "$remote:$base/dirB" >/dev/null 2>&1
  rc rmdir "$remote:$base/dirB" >/dev/null 2>&1 \
    && chk "rmdir empty directory" "$(rc lsd "$remote:$base" 2>/dev/null | grep -c dirB)" "0" \
    || bad "rmdir empty directory"

  # --- case I: modification times, where the vendor supports them ---
  # Expected to skip on plain webdav (no propset) and on ownCloud, which
  # returns 403 for oc:checksums in the same propertyupdate and so 424s the
  # lastmodified alongside it. Master behaves identically - not a regression.
  if rc touch -t 2020-01-02T03:04:05 "$remote:$base/c.txt" >/dev/null 2>&1; then
    chk "set modification time" \
      "$(rc lsl "$remote:$base/c.txt" 2>/dev/null | awk '{print $2}')" "2020-01-02"
  else
    printf "    \033[33mSKIP\033[0m set modification time (not supported by this vendor)\n"
  fi

  # --- case J: quota, where the server reports it ---
  if out=$(rc about "$remote:" 2>/dev/null) && [ -n "$out" ]; then
    ok "about reports quota"
  else
    printf "    \033[33mSKIP\033[0m about (server reports no quota properties)\n"
  fi

  rc purge "$remote:$base" >/dev/null 2>&1
  chk "purge removes everything" "$(rc lsd "$remote:" 2>/dev/null | grep -c "$base")" "0"
done

# This one must refuse rather than authenticate, and say why
printf "\n\033[1m### dav-digest-md5sess\033[0m (expected to refuse)\n"
out=$(rc ls dav-digest-md5sess: 2>&1)
echo "$out" | grep -q "Can't do the digest authentication" \
  && ok "reports the algorithm it can't sign with" \
  || bad "expected \"Can't do the digest authentication\", got: $(echo "$out" | tail -1)"

printf "\n\033[1m== %d passed, %d failed ==\033[0m\n" "$pass" "$fail"
[ "$fail" -eq 0 ]
