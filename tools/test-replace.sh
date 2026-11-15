#!/bin/sh
# Hana world mac launcher: self-update replace test (11-15). macOS only, no account, no network.
# Usage: sh test-replace.sh "<path to Hana world.app>" [<path to a newer Hana_world_Mac zip>]
#  - takes replace.sh out of the app itself (HANA_SELFCHECK=1 ... --print-replace-script), so it tests the shipped script
#  - case 1: normal replace after the old launcher pid exits -> new app in place, old app in backup, `open` called on the new app
#  - case 2: new app missing -> old app restored and opened, exit 1
#  - case 3 (zip given): ditto unpack like the launcher, Info.plist version and Contents/MacOS/HanaWorld present
# `open` is replaced by a stub on PATH so nothing is launched. Prints PASS/FAIL per case; exit 0 = all pass.
set -u
APP="$1"
ZIP="${2:-}"
WORK="$(mktemp -d /tmp/hana-replace-test.XXXXXX)"
FAIL=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; FAIL=1; }

HANA_SELFCHECK=1 "$APP/Contents/MacOS/HanaWorld" --print-replace-script > "$WORK/replace.sh" 2>/dev/null
if ! head -1 "$WORK/replace.sh" | grep -q '^#!/bin/sh'; then echo "FAIL could not read replace script from app"; exit 1; fi
pass "replace script read from app ($(wc -l < "$WORK/replace.sh" | tr -d ' ') lines)"

mkdir -p "$WORK/bin"
cat > "$WORK/bin/open" <<'EOF'
#!/bin/sh
echo "$@" >> "$OPEN_LOG"
EOF
chmod +x "$WORK/bin/open"
export OPEN_LOG="$WORK/open.log"

make_app() { # dir version
  mkdir -p "$1/Contents/MacOS"
  printf '<plist><string>%s</string></plist>\n' "$2" > "$1/Contents/Info.plist"
  printf '#!/bin/sh\n' > "$1/Contents/MacOS/HanaWorld"
}

# case 1: normal
C1="$WORK/c1"; mkdir -p "$C1/Applications" "$C1/update/unpack"
make_app "$C1/Applications/Hana world.app" 1.0.0
make_app "$C1/update/unpack/Hana world.app" 2.0.0
SLEEPER=$(sh -c 'sleep 3 >/dev/null 2>&1 & echo $!')   # not our child: no zombie keeping kill -0 true
: > "$OPEN_LOG"
START=$(date +%s)
PATH="$WORK/bin:$PATH" /bin/sh "$WORK/replace.sh" "$SLEEPER" "$C1/Applications/Hana world.app" "$C1/update/unpack/Hana world.app" "$C1/update/old-app"
CODE=$?
WAITED=$(( $(date +%s) - START ))
if [ $CODE -eq 0 ] && grep -q 2.0.0 "$C1/Applications/Hana world.app/Contents/Info.plist" \
   && grep -q 1.0.0 "$C1/update/old-app/Contents/Info.plist" && grep -q "Applications/Hana world.app" "$OPEN_LOG" && [ $WAITED -ge 2 ]; then
  pass "case 1 replace (waited ${WAITED}s for old pid)"
else
  fail "case 1 replace (exit $CODE, waited ${WAITED}s)"
fi

# case 2: new app missing -> roll back
C2="$WORK/c2"; mkdir -p "$C2/Applications" "$C2/update"
make_app "$C2/Applications/Hana world.app" 1.0.0
make_app "$C2/update/old-app" 0.9.0
: > "$OPEN_LOG"
PATH="$WORK/bin:$PATH" /bin/sh "$WORK/replace.sh" 999999 "$C2/Applications/Hana world.app" "$C2/update/missing.app" "$C2/update/old-app" 2>/dev/null
CODE=$?
if [ $CODE -ne 0 ] && grep -q 1.0.0 "$C2/Applications/Hana world.app/Contents/Info.plist" && grep -q "Applications/Hana world.app" "$OPEN_LOG"; then
  pass "case 2 roll back when new app is missing"
else
  fail "case 2 roll back (exit $CODE)"
fi

# case 3: real zip unpack like the launcher (ditto -x -k)
if [ -n "$ZIP" ]; then
  C3="$WORK/c3"; mkdir -p "$C3"
  if /usr/bin/ditto -x -k "$ZIP" "$C3" && NEW="$(find "$C3" -maxdepth 2 -name '*.app' -type d | head -1)" && [ -n "$NEW" ] \
     && [ -x "$NEW/Contents/MacOS/HanaWorld" ] && [ -x "$NEW/Contents/MacOS/HanaWorldLauncher-arm64" ] && [ -x "$NEW/Contents/MacOS/HanaWorldLauncher-x64" ]; then
    pass "case 3 ditto unpack · version $(/usr/bin/plutil -extract CFBundleShortVersionString raw "$NEW/Contents/Info.plist" 2>/dev/null) · exec bits ok"
  else
    fail "case 3 ditto unpack"
  fi
fi

rm -rf "$WORK"
[ $FAIL -eq 0 ] && echo "REPLACE TEST PASS" || echo "REPLACE TEST FAIL"
exit $FAIL
