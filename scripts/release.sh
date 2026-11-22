#!/usr/bin/env bash
# Remora release pipeline. Subcommands: build notarize staple appcast selftest.
# build signs, verifies, and makes the DMG. notarize uploads to Apple. appcast signs
# the update with the Sparkle key from the login Keychain or a runner-supplied file.
set -euo pipefail

TEAM_ID="CRL579ZN46"
NOTARY_PROFILE="remora-notary"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPARKLE_BIN_REL="SourcePackages/artifacts/sparkle/Sparkle/bin"

die() { echo "error: $*" >&2; exit 1; }
note() { echo "==> $*"; }

# ---------------------------------------------------------------- cleanup trap and watchdog

TMP_PATHS=()      # temp dirs/files removed on exit
MOUNTS=()         # mount points this script attached
PARTIAL_DMG=""    # DMG being written; removed unless finished
WD_PIDS=()        # pids of a watched command and its watchdog, killed on exit

track_tmp() { TMP_PATHS+=("$1"); }
track_mount() { MOUNTS+=("$1"); }
untrack_mount() {
  local m keep=()
  for m in ${MOUNTS[@]+"${MOUNTS[@]}"}; do [ "$m" = "$1" ] || keep+=("$m"); done
  MOUNTS=(${keep[@]+"${keep[@]}"})
}

cleanup() {
  local rc=$? m p
  trap - EXIT INT TERM
  for m in ${MOUNTS[@]+"${MOUNTS[@]}"}; do
    hdiutil detach -force "$m" >/dev/null 2>&1 || { sleep 1; hdiutil detach -force "$m" >/dev/null 2>&1; } || true
  done
  MOUNTS=()
  for p in ${WD_PIDS[@]+"${WD_PIDS[@]}"}; do kill "$p" 2>/dev/null || true; done
  if [ "${#WD_PIDS[@]}" -gt 0 ]; then
    sleep 1 || true
    for p in "${WD_PIDS[@]}"; do kill -0 "$p" 2>/dev/null && { kill -9 "$p" 2>/dev/null || true; }; done
  fi
  WD_PIDS=()
  if [ -n "$PARTIAL_DMG" ]; then rm -f "$PARTIAL_DMG" || true; fi
  for p in ${TMP_PATHS[@]+"${TMP_PATHS[@]}"}; do rm -rf "$p" || true; done
  exit "$rc"
}

install_trap() {
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
}

KEYCHAIN_HELP='approve the macOS Keychain prompt for codesign with "Always Allow", or run this yourself (it asks for your login password; never give it to a script or to Claude):
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k <login password> ~/Library/Keychains/login.keychain-db'

# run_watched <seconds> <cmd...>: run cmd; kill it after <seconds> and return 124 with the Keychain instruction.
run_watched() {
  local secs="$1" pid wd flag rc=0 i; shift
  flag="$(mktemp -t remora-wd)"; rm -f "$flag"
  "$@" & pid=$!
  (
    for ((i=0; i<secs; i++)); do kill -0 "$pid" 2>/dev/null || exit 0; sleep 1; done
    kill -0 "$pid" 2>/dev/null || exit 0
    kill -0 "$pid" 2>/dev/null || exit 0
    : > "$flag"; kill "$pid" 2>/dev/null; sleep 1; kill -9 "$pid" 2>/dev/null
  ) >/dev/null 2>&1 &
  wd=$!
  WD_PIDS=("$pid" "$wd")
  wait "$pid" 2>/dev/null || rc=$?
  kill "$wd" 2>/dev/null || true
  wait "$wd" 2>/dev/null || true
  WD_PIDS=()
  if [ -e "$flag" ]; then
    rm -f "$flag"
    echo "error: '$1' did not finish within ${secs}s (probably waiting on a Keychain prompt). To fix: $KEYCHAIN_HELP" >&2
    return 124
  fi
  return "$rc"
}

# is_dry: true when DRY_RUN is 1/true/yes; false for 0 or empty; anything else dies.
is_dry() {
  case "$(printf '%s' "${DRY_RUN:-}" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes) return 0 ;;
    0|"") return 1 ;;
    *) die "DRY_RUN must be 0 or 1 (got '${DRY_RUN}')" ;;
  esac
}

# keychain_info_locked <show-keychain-info-output>
keychain_info_locked() { printf '%s\n' "$1" | grep -qiE 'locked|interaction is not allowed'; }

# ---------------------------------------------------------------- pure functions (selftest)

# resolve_identity <find-identity-output>: print the single distinct SHA-1 of a valid Developer ID Application identity.
resolve_identity() {
  local out="$1" hashes count
  hashes="$(printf '%s\n' "$out" \
    | grep -F 'Developer ID Application:' | grep -F "($TEAM_ID)\"" | grep -v 'CSSMERR_' \
    | sed -nE 's/^[[:space:]]*[0-9]+\)[[:space:]]+([0-9A-Fa-f]{40})[[:space:]].*/\1/p' | sort -u || true)"
  count="$(printf '%s' "$hashes" | grep -c . || true)"
  if [ "$count" -eq 0 ]; then
    echo "no valid 'Developer ID Application: ... ($TEAM_ID)' identity found" >&2
    return 1
  fi
  if [ "$count" -gt 1 ]; then
    if [ -n "${REMORA_SIGN_IDENTITY:-}" ] && printf '%s\n' "$hashes" | grep -qix "$REMORA_SIGN_IDENTITY"; then
      printf '%s\n' "$REMORA_SIGN_IDENTITY" | tr 'a-f' 'A-F'
      return 0
    fi
    echo "multiple Developer ID identities; set REMORA_SIGN_IDENTITY to one SHA-1" >&2
    return 1
  fi
  printf '%s\n' "$hashes"
}

valid_repo() { [[ "$1" =~ ^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$ ]]; }

# base64 that decodes to exactly 32 bytes (an Ed25519 public key).
valid_public_key() {
  local s="$1" n
  [[ "$s" =~ ^[A-Za-z0-9+/]+=*$ ]] || return 1
  n="$(printf '%s' "$s" | base64 -D 2>/dev/null | wc -c | tr -d ' ')" || return 1
  [ "$n" -eq 32 ]
}

# build_is_newer <new> <appcast-file-or-empty>
build_is_newer() {
  local new="$1" file="${2:-}" v
  [[ "$new" =~ ^[0-9]+$ ]] || return 1
  { [ -z "$file" ] || [ ! -f "$file" ]; } && return 0
  while IFS= read -r v; do
    [ "$new" -gt "$v" ] || return 1
  done < <(grep -oE '<sparkle:version>[0-9]+</sparkle:version>' "$file" | sed -E 's/<[^>]*>//g')
  return 0
}

spctl_verdict() {
  local out="$1" origin="origin=Developer ID Application: .*\\($TEAM_ID\\)"
  if printf '%s\n' "$out" | grep -qF 'accepted' \
     && printf '%s\n' "$out" | grep -qF 'source=Notarized Developer ID' \
     && printf '%s\n' "$out" | grep -qE "$origin"; then
    echo notarized-ok
  elif printf '%s\n' "$out" | grep -qF 'source=Unnotarized Developer ID' \
     && printf '%s\n' "$out" | grep -qE "$origin"; then
    echo unnotarized-ok
  else
    echo bad
  fi
}

# ---------------------------------------------------------------- selftest

cmd_selftest() {
  local pass=0 fail=0
  t() { # t <name> <expected-rc> <cmd...>
    local name="$1" want="$2" rc=0; shift 2
    "$@" >/dev/null 2>&1 || rc=$?
    if [ "$rc" -eq "$want" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $name (rc=$rc, want $want)"; fi
  }
  eq() { # eq <name> <want> <got>
    if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 (got '$3', want '$2')"; fi
  }
  local H1=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA H2=BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB
  local same two none
  same="  1) $H1 \"Developer ID Application: Jane Doe ($TEAM_ID)\"
  2) $H1 \"Developer ID Application: Jane Doe ($TEAM_ID)\"
  3) CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC \"Apple Development: Jane Doe (ABCDE12345)\"
     3 valid identities found"
  two="  1) $H1 \"Developer ID Application: Jane Doe ($TEAM_ID)\"
  2) $H2 \"Developer ID Application: Jane Doe ($TEAM_ID)\"
     2 valid identities found"
  none="  1) CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC \"Apple Development: Jane Doe (ABCDE12345)\"
     1 valid identities found"
  eq "identity same hash twice" "$H1" "$(resolve_identity "$same" 2>/dev/null || echo FAILED)"
  eq "identity two hashes" "FAILED" "$(env -u REMORA_SIGN_IDENTITY bash -c "$(declare -f resolve_identity); TEAM_ID=$TEAM_ID; resolve_identity \"\$1\"" _ "$two" 2>/dev/null || echo FAILED)"
  eq "identity two hashes with override" "$H2" "$(REMORA_SIGN_IDENTITY=$H2 resolve_identity "$two" 2>/dev/null || echo FAILED)"
  eq "identity none" "FAILED" "$(resolve_identity "$none" 2>/dev/null || echo FAILED)"

  t "repo ok" 0 valid_repo "owner/remora"
  t "repo ok dots" 0 valid_repo "my-org/re.mo_ra"
  t "repo empty" 1 valid_repo ""
  t "repo no slash" 1 valid_repo "owner"
  t "repo extra slash" 1 valid_repo "a/b/c"
  t "repo space" 1 valid_repo "a/b c"
  t "repo underscore owner" 1 valid_repo "a_b/c"

  local key32 key31
  key32="$(head -c 32 /dev/zero | base64)"
  key31="$(head -c 31 /dev/zero | base64)"
  t "key 32 bytes" 0 valid_public_key "$key32"
  t "key 31 bytes" 1 valid_public_key "$key31"
  t "key empty" 1 valid_public_key ""
  t "key not base64" 1 valid_public_key "not base64!"

  local tmp; tmp="$(mktemp -d)"; track_tmp "$tmp"
  printf '<rss><item><sparkle:version>1</sparkle:version></item></rss>\n' > "$tmp/a.xml"
  t "newer 2 vs 1" 0 build_is_newer 2 "$tmp/a.xml"
  t "newer 1 vs 1" 1 build_is_newer 1 "$tmp/a.xml"
  t "newer no file" 0 build_is_newer 1 ""
  t "newer missing file" 0 build_is_newer 1 "$tmp/none.xml"
  t "newer non-integer" 1 build_is_newer 1.5 ""

  local un no ad
  un="Remora.app: rejected
source=Unnotarized Developer ID
origin=Developer ID Application: Jane Doe ($TEAM_ID)"
  no="Remora.app: accepted
source=Notarized Developer ID
origin=Developer ID Application: Jane Doe ($TEAM_ID)"
  ad="Remora.app: rejected
source=no usable signature"
  eq "spctl unnotarized" unnotarized-ok "$(spctl_verdict "$un")"
  eq "spctl notarized" notarized-ok "$(spctl_verdict "$no")"
  eq "spctl ad-hoc" bad "$(spctl_verdict "$ad")"
  eq "spctl wrong team" bad "$(spctl_verdict "${no//$TEAM_ID/ZZZZZZZZZZ}")"

  # watchdog: a hung fake command is killed and the instruction printed
  local wout wrc=0
  wout="$(run_watched 2 sleep 30 2>&1)" || wrc=$?
  eq "watchdog rc" 124 "$wrc"
  case "$wout" in *"Always Allow"*"set-key-partition-list"*) pass=$((pass+1));; *) fail=$((fail+1)); echo "FAIL: watchdog instruction";; esac
  wrc=0; run_watched 5 true >/dev/null 2>&1 || wrc=$?
  eq "watchdog passes success" 0 "$wrc"
  wrc=0; run_watched 5 false >/dev/null 2>&1 || wrc=$?
  eq "watchdog passes failure rc" 1 "$wrc"
  t "locked keychain detected" 0 keychain_info_locked "Keychain \"x\" is locked"
  t "unlocked keychain ok" 1 keychain_info_locked 'Keychain "x" lock-on-sleep timeout=300s'

  # DRY_RUN notarize/staple/appcast: no external calls (stubs log any call)
  local stubs="$tmp/stubs" c
  mkdir -p "$stubs"
  for c in xcrun hdiutil spctl xcodebuild xcodegen codesign security; do
    printf '#!/bin/sh\necho "%s $*" >> "%s/calls.log"\nexit 1\n' "$c" "$tmp" > "$stubs/$c"
    chmod +x "$stubs/$c"
  done
  local sub
  for sub in notarize staple appcast; do
    wrc=0; DRY_RUN=1 PATH="$stubs:$PATH" "$ROOT/scripts/release.sh" "$sub" >/dev/null 2>&1 || wrc=$?
    eq "DRY_RUN $sub rc" 0 "$wrc"
  done
  eq "DRY_RUN made no calls" "none" "$([ -s "$tmp/calls.log" ] && cat "$tmp/calls.log" || echo none)"

  # trap: temp dirs removed, mounts detached, partial DMG removed, exit code kept
  local td="$tmp/trapdir" pd="$tmp/partial.dmg"
  mkdir -p "$td"; : > "$pd"
  wrc=0
  PATH="$stubs:$PATH" bash -c 'source "$1"; install_trap; track_tmp "$2"; PARTIAL_DMG="$3"; track_mount /nonexistent/mnt; exit 3' _ "$ROOT/scripts/release.sh" "$td" "$pd" >/dev/null 2>&1 || wrc=$?
  eq "trap keeps exit code" 3 "$wrc"
  t "trap removed temp dir" 1 test -e "$td"
  t "trap removed partial dmg" 1 test -e "$pd"
  case "$(cat "$tmp/calls.log" 2>/dev/null)" in *"hdiutil detach -force /nonexistent/mnt"*) pass=$((pass+1));; *) fail=$((fail+1)); echo "FAIL: trap did not detach";; esac
  td="$tmp/trapdir2"; mkdir -p "$td"
  bash -c 'source "$1"; install_trap; track_tmp "$2"; kill -TERM $$; sleep 5' _ "$ROOT/scripts/release.sh" "$td" >/dev/null 2>&1 || true
  t "trap on TERM removed temp dir" 1 test -e "$td"

  # TERM during run_watched leaves no orphan
  bash -c 'source "$1"; install_trap; run_watched 60 sleep 37' _ "$ROOT/scripts/release.sh" >/dev/null 2>&1 &
  local bgp=$!
  sleep 2; kill -TERM "$bgp" 2>/dev/null || true; wait "$bgp" 2>/dev/null || true; sleep 1
  t "no orphan sleep after TERM" 1 pgrep -f 'sleep 37'

  # staple failure is fatal
  local sst="$tmp/stubs2"; mkdir -p "$sst" "$tmp/fake/dist"
  printf '#!/bin/sh\nexit 1\n' > "$sst/xcrun"; chmod +x "$sst/xcrun"
  wrc=0; PATH="$sst:$PATH" bash -c 'source "$1"; ROOT="$2"; version_or_die(){ V=9.9.9; }; cd "$2"; : > dist/Remora-9.9.9.dmg; install_trap; cmd_staple' _ "$ROOT/scripts/release.sh" "$tmp/fake" >/dev/null 2>&1 || wrc=$?
  t "staple failure exits non-zero" 0 test "$wrc" -ne 0

  # The hosted runner stores the notary profile in a temporary keychain.
  local ci_dir="$tmp/ci"; mkdir -p "$ci_dir/dist"
  : > "$ci_dir/dist/Remora-9.9.9.dmg"
  cat > "$sst/xcrun" <<'SH'
#!/bin/bash
if [[ "$*" != *"--keychain $EXPECTED_KEYCHAIN"* ]]; then exit 1; fi
case "$2" in
  submit) echo '{"id":"example-id","status":"Invalid"}' ;;
  log) echo '{}' > "${!#}" ;;
esac
SH
  REMORA_NOTARY_KEYCHAIN="$ci_dir/temp keychain" EXPECTED_KEYCHAIN="$ci_dir/temp keychain" PATH="$sst:$PATH" \
    bash -c 'source "$1"; version_or_die(){ V=9.9.9; }; cd "$2"; cmd_notarize' _ "$ROOT/scripts/release.sh" "$ci_dir" >/dev/null 2>&1 || true
  t "notary diagnostic uses the same keychain as submit" 0 test -s "$ci_dir/dist/notary-9.9.9-log.json"

  # Sparkle must receive the exported key file on a runner with no login key.
  cat > "$sst/generate_appcast" <<'SH'
#!/bin/bash
case "$1" in
  --ed-key-file) [[ "$2" = "$EXPECTED_KEY_FILE" ]] || exit 1 ;;
  --account) [[ "$2" = remora ]] || exit 1 ;;
  *) exit 1 ;;
esac
cat > "${!#}/appcast.xml" <<'XML'
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>
<sparkle:version>42</sparkle:version>
<sparkle:shortVersionString>9.9.9</sparkle:shortVersionString>
<sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
<enclosure sparkle:edSignature="fake" url="https://github.com/example/remora/releases/download/v9.9.9/Remora-9.9.9.dmg"/>
</item></channel></rss>
XML
SH
  chmod +x "$sst/generate_appcast"
  : > "$ci_dir/sparkle key"
  REMORA_SPARKLE_KEY_FILE="$ci_dir/sparkle key" EXPECTED_KEY_FILE="$ci_dir/sparkle key" STUB_SPARKLE="$sst/generate_appcast" \
    t "appcast can sign with an exported key file" 0 bash -c 'source "$1"; install_trap; version_or_die(){ V=9.9.9; BUILD=42; REPO=example/remora; }; sparkle_bin(){ echo "$STUB_SPARKLE"; }; cd "$2"; cmd_appcast' _ "$ROOT/scripts/release.sh" "$ci_dir"
  REMORA_SPARKLE_KEY_FILE= REMORA_SPARKLE_ACCOUNT=remora STUB_SPARKLE="$sst/generate_appcast" \
    t "local appcast can use the Remora key account" 0 bash -c 'source "$1"; install_trap; version_or_die(){ V=9.9.9; BUILD=42; REPO=example/remora; }; sparkle_bin(){ echo "$STUB_SPARKLE"; }; cd "$2"; cmd_appcast' _ "$ROOT/scripts/release.sh" "$ci_dir"

  mkdir -p "$ci_dir/Remora.xcodeproj"
  printf '#!/bin/bash\n[[ " $* " = *" -destination generic/platform=macOS "* ]] && echo "[]"\n' > "$sst/xcodebuild"
  chmod +x "$sst/xcodebuild"
  PATH="$sst:$PATH" t "release uses a destination that allows both architectures" 0 bash -c 'source "$1"; ROOT="$2"; load_settings' _ "$ROOT/scripts/release.sh" "$ci_dir"

  # DRY_RUN normalisation
  wrc=0; DRY_RUN=bogus "$ROOT/scripts/release.sh" notarize >/dev/null 2>&1 || wrc=$?
  t "DRY_RUN bogus dies" 0 test "$wrc" -ne 0
  wrc=0; DRY_RUN=yes "$ROOT/scripts/release.sh" notarize >/dev/null 2>&1 || wrc=$?
  eq "DRY_RUN yes is on" 0 "$wrc"

  if [ "$fail" -ne 0 ]; then echo "selftest: $fail failed, $pass passed" >&2; exit 1; fi
  echo "selftest: $pass passed"
}

# ---------------------------------------------------------------- settings

SETTINGS_JSON=""
release_xcodebuild() {
  # A concrete host destination limits Xcode to the host architecture even with ONLY_ACTIVE_ARCH=NO.
  xcodebuild -project Remora.xcodeproj -scheme Remora -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath build/release "$@"
}

load_settings() {
  [ -d "$ROOT/Remora.xcodeproj" ] || (cd "$ROOT" && xcodegen generate >/dev/null)
  SETTINGS_JSON="$(cd "$ROOT" && release_xcodebuild -showBuildSettings -json 2>/dev/null)"
  [ -n "$SETTINGS_JSON" ] || die "xcodebuild -showBuildSettings produced nothing"
}
setting() { printf '%s' "$SETTINGS_JSON" | plutil -extract "0.buildSettings.$1" raw - 2>/dev/null || true; }

sparkle_pin() { sed -nE '/^[[:space:]]*Sparkle:/,/^[^ ]/{s/^[[:space:]]*exactVersion:[[:space:]]*"?([0-9.]+)"?.*/\1/p;}' "$ROOT/project.yml" | head -1; }

sparkle_bin() {
  local d
  for d in "$ROOT/build/release/$SPARKLE_BIN_REL" "$ROOT/build/$SPARKLE_BIN_REL"; do
    [ -x "$d/$1" ] && { echo "$d/$1"; return 0; }
  done
  return 1
}

# ---------------------------------------------------------------- build

PLIST_BUDDY=/usr/libexec/PlistBuddy

verify_signed_bundle() { # <path> : strict verify plus hardened runtime and team id
  local p="$1" info
  codesign --verify --strict --verbose=2 "$p" 2>&1 || die "codesign --verify failed: $p"
  info="$(codesign -dvv "$p" 2>&1)"
  printf '%s\n' "$info" | grep -q "TeamIdentifier=$TEAM_ID" || die "$p: TeamIdentifier is not $TEAM_ID"
  printf '%s\n' "$info" | grep -E '^CodeDirectory' | grep -q 'runtime' || die "$p: hardened runtime flag missing"
}

cmd_build() {
  local dry=0 suffix="" tool
  if is_dry; then dry=1; fi
  [ "$dry" = 1 ] && suffix="-dryrun"
  cd "$ROOT"

  note "Preflight"
  for tool in xcodegen xcodebuild codesign hdiutil lipo plutil ditto spctl shasum security; do
    command -v "$tool" >/dev/null || die "missing tool: $tool"
  done
  xcodegen generate >/dev/null
  load_settings
  local V BUILD REPO KEY FEED
  V="$(setting MARKETING_VERSION)"; BUILD="$(setting CURRENT_PROJECT_VERSION)"
  REPO="$(setting REMORA_GITHUB_REPO)"; KEY="$(setting REMORA_SPARKLE_PUBLIC_KEY)"; FEED="$(setting REMORA_FEED_URL)"
  [[ "$V" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "MARKETING_VERSION '$V' is not x.y.z"
  if [ "$dry" != 1 ]; then
    valid_repo "$REPO" || die "REMORA_GITHUB_REPO '$REPO' is not owner/name (Config/Updates.xcconfig)"
    valid_public_key "$KEY" || die "REMORA_SPARKLE_PUBLIC_KEY is not a 32-byte base64 key (Config/Updates.xcconfig)"
    build_is_newer "$BUILD" dist/appcast/appcast.xml || die "CURRENT_PROJECT_VERSION $BUILD is not newer than dist/appcast/appcast.xml"
  fi
  local ID
  ID="$(resolve_identity "$(security find-identity -v -p codesigning)")" || die "no signing identity"
  local kinfo
  kinfo="$(security show-keychain-info 2>&1 || true)"
  if keychain_info_locked "$kinfo"; then die "the login keychain is locked; unlock it (Keychain Access or 'security unlock-keychain') and retry"; fi
  note "Keychain preflight: signing a throwaway copy of /usr/bin/true (30s watchdog)"
  local pre; pre="$(mktemp -d -t remora-preflight)"; track_tmp "$pre"
  cp /usr/bin/true "$pre/true"
  run_watched 30 codesign --force --sign "$ID" "$pre/true" \
    || die "codesign preflight failed or timed out; see above. To fix: $KEYCHAIN_HELP"
  rm -rf "$pre"
  note "Version $V (build $BUILD), identity ...${ID: -6}${suffix:+, DRY RUN}"

  note "Build (universal Release)"
  release_xcodebuild CODE_SIGNING_ALLOWED=NO clean build

  note "Stage"
  rm -rf dist/stage && mkdir -p dist/stage
  ditto build/release/Build/Products/Release/Remora.app dist/stage/Remora.app
  local APP="$ROOT/dist/stage/Remora.app" FW SP
  FW="$APP/Contents/Frameworks"; SP="$FW/Sparkle.framework"
  [ -d "$SP" ] || die "Sparkle.framework not embedded"
  local pin got
  pin="$(sparkle_pin)"; got="$("$PLIST_BUDDY" -c 'Print :CFBundleShortVersionString' "$SP/Versions/B/Resources/Info.plist")"
  [ -n "$pin" ] && [ "$pin" = "$got" ] || die "embedded Sparkle $got does not match project.yml pin '$pin'"
  rm -rf "$SP/Versions/B/XPCServices" "$SP/XPCServices"   # D2: the app is not sandboxed, so Sparkle's XPC services are unused

  note "Sign inside-out (no --deep)"
  sign() { run_watched "${CODESIGN_TIMEOUT:-120}" codesign --force --sign "$ID" --options runtime --timestamp "$@"; }
  sign "$SP/Versions/B/Autoupdate"
  sign "$SP/Versions/B/Updater.app"
  sign "$SP"
  local b
  while IFS= read -r b; do
    sign "$b"
  done < <(find "$FW" -mindepth 1 -maxdepth 1 \( -name '*.framework' -o -name '*.app' -o -name '*.xpc' -o -name '*.dylib' \) ! -name 'Sparkle.framework' | sort)
  sign --identifier dev.remora.remora-mcp "$APP/Contents/MacOS/remora-mcp"
  sign --entitlements "$ROOT/App/Remora/Remora.entitlements" "$APP"

  note "Verify"
  codesign --verify --deep --strict --verbose=2 "$APP" || die "codesign --verify --deep --strict failed"
  # Nested code (Sparkle's Autoupdate, Updater.app, any XPC service still present) individually, hardened runtime included.
  local nested n=0
  while IFS= read -r nested; do
    verify_signed_bundle "$nested"; n=$((n+1))
  done < <({ echo "$SP"; echo "$SP/Versions/B/Autoupdate"; echo "$SP/Versions/B/Updater.app"; \
             find "$SP" -name '*.xpc' -type d 2>/dev/null; echo "$APP/Contents/MacOS/remora-mcp"; echo "$APP"; } | sort -u)
  echo "verified $n signed bundles (team $TEAM_ID, hardened runtime)"
  local ents
  ents="$(codesign -d --entitlements - --xml "$APP" 2>/dev/null | strings || true)"
  printf '%s' "$ents" | grep -q 'com.apple.security.device.audio-input' || die "audio-input entitlement missing"
  if printf '%s' "$ents" | grep -q 'get-task-allow'; then die "get-task-allow present in a release build"; fi
  local f archs
  for f in "$APP/Contents/MacOS/Remora" "$APP/Contents/MacOS/remora-mcp" "$SP/Versions/B/Sparkle"; do
    archs="$(lipo -archs "$f")"
    case " $archs " in *" arm64 "*) ;; *) die "$f lacks arm64 ($archs)";; esac
    case " $archs " in *" x86_64 "*) ;; *) die "$f lacks x86_64 ($archs)";; esac
  done
  local plist="$APP/Contents/Info.plist"
  if [ "$dry" != 1 ]; then
    [ "$("$PLIST_BUDDY" -c 'Print :SUFeedURL' "$plist")" = "$FEED" ] || die "SUFeedURL differs from configured feed"
    [ "$("$PLIST_BUDDY" -c 'Print :SUPublicEDKey' "$plist")" = "$KEY" ] || die "SUPublicEDKey differs from configured key"
  fi
  local verdict
  verdict="$(spctl_verdict "$(spctl -a -t exec -vv "$APP" 2>&1 || true)")"
  [ "$verdict" = unnotarized-ok ] || die "spctl verdict '$verdict', expected unnotarized-ok"
  echo "spctl: $verdict"
  "$PLIST_BUDDY" -c 'Print :CFBundleIconName' "$plist" >/dev/null 2>&1 || echo "warning: No app icon yet"

  note "DMG"
  rm -rf dist/dmg-root && mkdir dist/dmg-root
  track_tmp "$ROOT/dist/dmg-root"
  ditto "$APP" dist/dmg-root/Remora.app
  ln -s /Applications dist/dmg-root/Applications
  local DMG="dist/Remora-$V$suffix.dmg"
  PARTIAL_DMG="$DMG"
  hdiutil create -volname Remora -srcfolder dist/dmg-root -fs APFS -format ULFO -ov "$DMG"
  run_watched "${CODESIGN_TIMEOUT:-120}" codesign --sign "$ID" --timestamp "$DMG"
  codesign --verify --strict "$DMG"
  PARTIAL_DMG=""
  shasum -a 256 "$DMG"
  echo "Next: make notarize (uploads to Apple, USER)"
}

# ---------------------------------------------------------------- USER-REQUIRED steps

version_or_die() {
  cd "$ROOT"; load_settings
  V="$(setting MARKETING_VERSION)"; BUILD="$(setting CURRENT_PROJECT_VERSION)"; REPO="$(setting REMORA_GITHUB_REPO)"
  [[ "$V" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "MARKETING_VERSION '$V' is not x.y.z"
}

cmd_notarize() {
  if is_dry; then echo "DRY_RUN: would notarize dist/Remora-<version>.dmg with notarytool profile $NOTARY_PROFILE (no Apple calls made)"; return 0; fi
  local V BUILD REPO; version_or_die
  local dmg="dist/Remora-$V.dmg"
  [ -f "$dmg" ] || die "$dmg not found; run make release first"
  local profile_args=(--keychain-profile "$NOTARY_PROFILE")
  if [ -n "${REMORA_NOTARY_KEYCHAIN:-}" ]; then profile_args+=(--keychain "$REMORA_NOTARY_KEYCHAIN"); fi
  xcrun notarytool submit "$dmg" "${profile_args[@]}" --wait --output-format json > "dist/notary-$V.json" || true
  local status id
  [ -s "dist/notary-$V.json" ] || die "notarytool submit produced no JSON output (it failed before returning a result; check the profile '$NOTARY_PROFILE' and network)"
  status="$(plutil -extract status raw "dist/notary-$V.json" 2>/dev/null || echo unknown)"
  if [ "$status" != Accepted ]; then
    id="$(plutil -extract id raw "dist/notary-$V.json" 2>/dev/null || true)"
    [ -n "$id" ] && xcrun notarytool log "$id" "${profile_args[@]}" "dist/notary-$V-log.json" || true
    die "notarization status '$status'; see dist/notary-$V-log.json"
  fi
  echo "Notarized. Next: make staple"
}

cmd_staple() {
  if is_dry; then echo "DRY_RUN: would staple and Gatekeeper-check dist/Remora-<version>.dmg (no mounts, no calls made)"; return 0; fi
  local V BUILD REPO; version_or_die
  local dmg="dist/Remora-$V.dmg" out
  [ -f "$dmg" ] || die "$dmg not found; run make release and make notarize first"
  xcrun stapler staple "$dmg" || die "stapler staple failed"
  xcrun stapler validate "$dmg" || die "stapler validate failed"
  out="$(spctl -a -t open --context context:primary-signature -vv "$dmg" 2>&1 || true)"
  printf '%s\n' "$out" | grep -qF accepted || die "dmg not accepted by Gatekeeper: $out"
  printf '%s\n' "$out" | grep -qF 'source=Notarized Developer ID' || die "dmg not notarized: $out"
  rm -rf dist/mnt && mkdir -p dist/mnt
  track_tmp "$ROOT/dist/mnt"
  track_mount "$ROOT/dist/mnt"
  hdiutil attach -nobrowse -readonly -mountpoint dist/mnt "$dmg" >/dev/null || die "hdiutil attach failed"
  local verdict
  verdict="$(spctl_verdict "$(spctl -a -t exec -vv dist/mnt/Remora.app 2>&1 || true)")"
  hdiutil detach dist/mnt >/dev/null
  untrack_mount "$ROOT/dist/mnt"
  [ "$verdict" = notarized-ok ] || die "app inside dmg verdict '$verdict', expected notarized-ok"
  echo "Stapled and verified. Next: make appcast"
}

cmd_appcast() {
  if is_dry; then echo "DRY_RUN: would run generate_appcast over dist/Remora-<version>.dmg (no Keychain access, nothing written)"; return 0; fi
  local V BUILD REPO; version_or_die
  local dmg="dist/Remora-$V.dmg" tool
  [ -f "$dmg" ] || die "$dmg not found"
  valid_repo "$REPO" || die "REMORA_GITHUB_REPO '$REPO' is not owner/name"
  tool="$(sparkle_bin generate_appcast)" || die "generate_appcast not found; run make release first"
  rm -rf dist/appcast-work && mkdir -p dist/appcast-work dist/appcast
  track_tmp "$ROOT/dist/appcast-work"
  cp "$dmg" dist/appcast-work/
  set -- --download-url-prefix "https://github.com/$REPO/releases/download/v$V/" --maximum-deltas 0 dist/appcast-work
  if [ -n "${REMORA_SPARKLE_KEY_FILE:-}" ]; then
    set -- --ed-key-file "$REMORA_SPARKLE_KEY_FILE" "$@"
  elif [ -n "${REMORA_SPARKLE_ACCOUNT:-}" ]; then
    set -- --account "$REMORA_SPARKLE_ACCOUNT" "$@"
  fi
  "$tool" "$@"
  local x=dist/appcast-work/appcast.xml
  [ -f "$x" ] || die "generate_appcast wrote no appcast.xml"
  grep -qF "<sparkle:version>$BUILD</sparkle:version>" "$x" || die "appcast lacks build $BUILD"
  grep -qF "<sparkle:shortVersionString>$V</sparkle:shortVersionString>" "$x" || die "appcast lacks version $V"
  grep -qF 'sparkle:edSignature=' "$x" || die "appcast lacks an edSignature"
  grep -qF "https://github.com/$REPO/releases/download/v$V/Remora-$V.dmg" "$x" || die "appcast lacks the download URL"
  grep -qF '<sparkle:minimumSystemVersion>26.0' "$x" || die "appcast lacks minimumSystemVersion 26.0"
  cp "$x" dist/appcast/appcast.xml
  echo "dist/appcast/appcast.xml ready. Publish per docs/releasing.md (USER)."
}

main() {
  install_trap
  case "${1:-}" in
    build) cmd_build ;;
    notarize) cmd_notarize ;;
    staple) cmd_staple ;;
    appcast) cmd_appcast ;;
    selftest) cmd_selftest ;;
    *) echo "usage: $0 {build|notarize|staple|appcast|selftest}" >&2; exit 2 ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
