#!/bin/bash
# Offline regression checks: never contacts or changes a running shield.
set -euo pipefail
cd "$(dirname "$0")/.."
source shield/validation.sh
fail() { echo "FAIL: $*" >&2; exit 1; }
for d in ubuntu.com archive.ubuntu.com A-b.example xn--bcher-kva.example; do
    valid_domain "$d" || fail "valid hostname rejected: $d"
done
for d in 'https://www.ous-research.no/' 1.2.3.4 a..com -a.example a-.example \
         example.com. '*.example.com' 'a.com;echo injected' $'a.com\nevil.com' \
         '' localhost "$(printf 'a%.0s' {1..64}).example"; do
    if valid_domain "$d"; then fail "invalid hostname accepted: $d"; fi
done
for f in shield/profile-*.txt; do profile_domains "$f" >/dev/null || fail "$f"; done
work=$(mktemp -d "${TMPDIR:-.}/shield-validation.XXXXXX")
trap 'rm -rf "$work"' EXIT
printf ' # comment\n  archive.ubuntu.com  # inline comment\n\n' > "$work/profile"
[ "$(profile_domains "$work/profile")" = archive.ubuntu.com ] || fail 'profile trimming'
printf 'ok.example\nhttps://www.ous-research.no/\n' > "$work/profile"
if profile_domains "$work/profile" > /dev/null 2>&1; then fail 'URL in profile accepted'; fi
mock_ssh() { printf '%s\n' "$MOCK_LIVE"; }
SSH=mock_ssh
MOCK_LIVE='nftset=/archive.ubuntu.com/4#inet#shield#allow4'
[ "$(live_domains)" = archive.ubuntu.com ] || fail 'valid live rule'
for MOCK_LIVE in 'nftset=/https://www.ous-research.no//4#inet#shield#allow4' \
                 'nftset=/foo.example/bar.example/4#inet#shield#allow4' \
                 'nftset=/foo.example/6#inet#shield#allow6' \
                 'nftset=//4#inet#shield#allow4'; do
    if live_domains >/dev/null 2>&1; then fail "malformed rule accepted: $MOCK_LIVE"; fi
done
if ./shield-allow.sh vps-test 'https://www.ous-research.no/' > "$work/output" 2>&1; then
    fail 'shield-allow accepted URL'
fi
grep -q 'invalid domain' "$work/output" || fail 'URL not rejected before connection'
python3 - "$work" <<'PY'
import base64, importlib.util, json, pathlib, sys
spec = importlib.util.spec_from_file_location('shield_setup', 'shield/setup-openstack.py')
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
p = pathlib.Path(sys.argv[1]); k = base64.b64encode(bytes(32)).decode()
config = p/'config.json'; config.write_text(json.dumps({'shield_private_key':k,'agent_public_key':k,'agent_ipv4':'192.0.2.1','operator_ipv4':'192.0.2.2'}))
profile = p/'python-profile'
for d in ('example.com', 'foo-bar.example'):
    profile.write_text(d+'\n')
    assert mod.load_inputs(config, profile)[1] == [d]
for d in ('https://www.ous-research.no/', '1.2.3.4', 'a..com', 'localhost', '*.example.com'):
    profile.write_text(d+'\n')
    try: mod.load_inputs(config, profile)
    except ValueError: continue
    raise AssertionError(f'Python setup accepted {d!r}')
print('Python validation passed')
PY
printf 'Shield validation tests passed\n'
