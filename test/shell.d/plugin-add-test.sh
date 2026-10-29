#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

write_plugin() {
  local dir="$1"
  local id="$2"
  local name="$3"

  mkdir -p "$dir"
  cat >"$dir/manifest.json" <<JSON
{
  "schemaVersion": 1,
  "id": "$id",
  "name": "$name",
  "version": "1.0.0",
  "kinds": ["bar-widget"],
  "entryPoints": { "barWidget": "Widget.qml" },
  "barWidget": {
    "displayName": "$name",
    "category": "Test",
    "allowMultiple": false
  }
}
JSON
  printf 'import QtQuick\nItem {}\n' >"$dir/Widget.qml"
}

stub_dir="$TMPDIR/stubs"
mkdir -p "$stub_dir"
cat >"$stub_dir/omarchy-shell" <<'STUB'
#!/bin/bash
exit 0
STUB
chmod +x "$stub_dir/omarchy-shell"

test_home="$TMPDIR/home"
write_plugin "$test_home/.config/omarchy/plugins/different-folder" "acme.same" "Installed"

incoming="$TMPDIR/incoming"
write_plugin "$incoming" "acme.same" "Incoming"
git -C "$incoming" init -q
git -C "$incoming" add .
git -C "$incoming" -c user.name=Test -c user.email=test@example.com commit -qm "Initial"

output=$(HOME="$test_home" OMARCHY_PATH="$ROOT" PATH="$stub_dir:$ROOT/bin:$PATH" \
  omarchy-plugin-add "$incoming" --yes 2>&1) &&
  fail "plugin add accepts an id already installed under another directory" "$output"
grep -qF "plugin id 'acme.same' is already used by" <<<"$output" ||
  fail "plugin add explains the installed id collision" "$output"
[[ ! -e $test_home/.config/omarchy/plugins/acme.same ]] ||
  fail "plugin add leaves a target behind after refusing a duplicate id"
pass "plugin add refuses an installed manifest id regardless of directory name"

# --- URL transport-helper guard -------------------------------------------
#
# The guard refuses git transport helpers (`<name>::…`) and option-shaped URLs
# before `git clone` runs, matching omarchy-theme-install. A git stub records
# whether clone was reached, so the guard is exercised with no network: reaching
# the stub proves a URL passed the guard; not reaching it proves the guard
# rejected the URL first.

guard_stubs="$TMPDIR/guard-stubs"
mkdir -p "$guard_stubs"
cat >"$guard_stubs/omarchy-shell" <<'STUB'
#!/bin/bash
exit 0
STUB
chmod +x "$guard_stubs/omarchy-shell"

clone_marker="$TMPDIR/git-clone-reached"
cat >"$guard_stubs/git" <<STUB
#!/bin/bash
if [[ \$1 == "clone" ]]; then
  touch "$clone_marker"
  exit 1
fi
exit 0
STUB
chmod +x "$guard_stubs/git"

# A gum stub that answers `gum input` with a caller-chosen value, so a test can
# drive any URL through the interactive prompt path.
cat >"$guard_stubs/gum" <<'STUB'
#!/bin/bash
if [[ $1 == "input" ]]; then
  printf '%s\n' "$GUM_INPUT_VALUE"
fi
STUB
chmod +x "$guard_stubs/gum"

add_url() {
  HOME="$test_home" OMARCHY_PATH="$ROOT" PATH="$guard_stubs:$ROOT/bin:$PATH" \
    omarchy-plugin-add "$1" --yes 2>&1
}

# Transport helpers reach the guard, are named as such, and never reach clone.
for bad in "ext::sh -c touch /tmp/omarchy-guard-test" "fd::17"; do
  rm -f "$clone_marker"
  output=$(add_url "$bad") &&
    fail "plugin add rejects a transport-helper URL: $bad" "$output"
  grep -qF "names a git option or transport helper" <<<"$output" ||
    fail "plugin add names the transport-helper rejection: $bad" "$output"
  [[ ! -e $clone_marker ]] ||
    fail "plugin add reached git clone for a transport-helper URL: $bad"
done
pass "plugin add rejects transport-helper URLs before cloning"

# The `://` spelling of the same thing: git resolves git-remote-<scheme> for any
# scheme it does not implement itself, so `ext::` and `ext://` reach the same
# helper and both have to be refused.
for bad in "ext://sh -c id" "gcrypt://example.com/x"; do
  rm -f "$clone_marker"
  output=$(add_url "$bad") &&
    fail "plugin add rejects a transport-scheme URL: $bad" "$output"
  grep -qF "which Omarchy does not clone from" <<<"$output" ||
    fail "plugin add names the transport-scheme rejection: $bad" "$output"
  [[ ! -e $clone_marker ]] ||
    fail "plugin add reached git clone for a transport-scheme URL: $bad"
done
pass "plugin add rejects transport-scheme URLs before cloning"

# Option-shaped URLs on argv are refused before clone — by the option parser
# (`-*` falls to "unknown add option"), not the guard. The guard's own
# leading-dash arm is only reachable through the interactive gum prompt and is
# exercised separately below.
for bad in "-oProxyCommand=x" "--upload-pack=x"; do
  rm -f "$clone_marker"
  output=$(add_url "$bad") &&
    fail "plugin add rejects an option-shaped URL: $bad" "$output"
  [[ ! -e $clone_marker ]] ||
    fail "plugin add reached git clone for an option-shaped URL: $bad"
done
pass "plugin add rejects option-shaped URLs before cloning"

# The guard's leading-dash arm is only reachable through `gum input`: argv
# dashes die in the option parser first. interactive() requires a TTY on stdin
# and stdout, so run this one case on a pty via util-linux `script -qec` (the
# suite's existing pty idiom); gum itself is stubbed, so no rendering happens.
# Probe script's util-linux syntax first and skip cleanly where it is missing.
if script -qec true /dev/null >/dev/null 2>&1; then
  rm -f "$clone_marker"
  status=0
  raw=$(GUM_INPUT_VALUE="-oProxyCommand=x" HOME="$test_home" OMARCHY_PATH="$ROOT" \
    PATH="$guard_stubs:$ROOT/bin:$PATH" \
    script -qec "omarchy-plugin-add --yes" /dev/null) || status=$?
  output=$(tr -d '\r' <<<"$raw")
  (( status != 0 )) ||
    fail "plugin add rejects an option-shaped URL from the gum prompt" "$output"
  grep -qF "names a git option or transport helper" <<<"$output" ||
    fail "plugin add names the guard rejection for the gum-prompt URL" "$output"
  [[ ! -e $clone_marker ]] ||
    fail "plugin add reached git clone for an option-shaped gum-prompt URL"
  pass "plugin add guard rejects an option-shaped URL from the interactive prompt"
else
  skip "script -qec unavailable; skipping the interactive gum-prompt guard case"
fi

# Legitimate URL forms pass the guard and reach git clone (stubbed, no network).
for good in \
  "https://github.com/acme/omarchy-weather.git" \
  "git@github.com:acme/repo.git" \
  "ssh://git@github.com/acme/repo.git" \
  "git@[2001:db8::1]:org/repo.git"; do
  rm -f "$clone_marker"
  output=$(add_url "$good") || true
  ! grep -qF "names a git option or transport helper" <<<"$output" ||
    fail "plugin add wrongly rejected a legitimate URL: $good" "$output"
  [[ -e $clone_marker ]] ||
    fail "plugin add did not reach git clone for a legitimate URL: $good" "$output"
done
pass "plugin add lets legitimate git URLs reach git clone"

# --- plugin-pre-install / plugin-pre-update gates ---------------------------
#
# A gate hook that exits non-zero refuses the install or update; one that
# exits 0 lets it through. The hook is a real file in the hooks directory and
# the add and update run end to end on local repositories.

gate_home="$TMPDIR/gate-home"
mkdir -p "$gate_home/.config/omarchy/plugins"
gated="$TMPDIR/gated"
write_plugin "$gated" "acme.gated" "Gated"
git -C "$gated" init -q
git -C "$gated" add .
git -C "$gated" -c user.name=Test -c user.email=test@example.com commit -qm "Initial"

gate_run() {
  HOME="$gate_home" OMARCHY_PATH="$ROOT" PATH="$stub_dir:$ROOT/bin:$PATH" "$@" 2>&1
}

write_gate() {
  local event="$1"
  local status="$2"
  mkdir -p "$gate_home/.config/omarchy/hooks/$event.d"
  printf '#!/bin/bash\nprintf "%%s\\n" "$@" >"%s"\nexit %s\n' "$TMPDIR/$event.args" "$status" \
    >"$gate_home/.config/omarchy/hooks/$event.d/scanner"
}

write_gate plugin-pre-install 1
output=$(gate_run omarchy-plugin-add "$gated" --yes) &&
  fail "plugin add installs a plugin its pre-install hook refused" "$output"
[[ ! -e $gate_home/.config/omarchy/plugins/acme.gated ]] ||
  fail "plugin add leaves the refused plugin installed"
[[ -z $(find "$gate_home/.config/omarchy/plugins" -maxdepth 1 -name '.add.tmp.*') ]] ||
  fail "plugin add leaves the refused checkout staged"
[[ $(sed -n 3p "$TMPDIR/plugin-pre-install.args") == "acme.gated" ]] ||
  fail "plugin-pre-install hook gets the plugin id" "$(cat "$TMPDIR/plugin-pre-install.args")"
pass "plugin add honors a refusing plugin-pre-install hook"

# A hook that rewrites the staged checkout and then allows it must not get its
# version installed in place of the one that was cloned.
printf '#!/bin/bash\necho "// injected" >>"$1/Widget.qml"\nexit 0\n' \
  >"$gate_home/.config/omarchy/hooks/plugin-pre-install.d/scanner"
output=$(gate_run omarchy-plugin-add "$gated" --yes) &&
  fail "plugin add installs a checkout its pre-install hook changed" "$output"
[[ ! -e $gate_home/.config/omarchy/plugins/acme.gated ]] ||
  fail "plugin add leaves a hook-changed plugin installed"
pass "plugin add refuses a checkout its plugin-pre-install hook changed"

write_gate plugin-pre-install 0
gate_run omarchy-plugin-add "$gated" --yes >/dev/null ||
  fail "plugin add refuses a plugin its pre-install hook allowed"
pass "plugin add installs what a plugin-pre-install hook allows"

installed="$gate_home/.config/omarchy/plugins/acme.gated"
before=$(git -C "$installed" rev-parse HEAD)
printf 'import QtQuick\nItem { visible: false }\n' >"$gated/Widget.qml"
git -C "$gated" -c user.name=Test -c user.email=test@example.com commit -qam "Update"
write_gate plugin-pre-update 1
output=$(gate_run omarchy-plugin-update acme.gated --yes) &&
  fail "plugin update applies an update its pre-update hook refused" "$output"
[[ $(git -C "$installed" rev-parse HEAD) == "$before" ]] ||
  fail "plugin update moves the plugin past a refused update"
[[ $(sed -n 4p "$TMPDIR/plugin-pre-update.args") == $(git -C "$gated" rev-parse HEAD) ]] ||
  fail "plugin-pre-update hook gets the incoming commit" "$(cat "$TMPDIR/plugin-pre-update.args")"
pass "plugin update honors a refusing plugin-pre-update hook"
