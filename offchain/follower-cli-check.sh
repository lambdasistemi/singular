#!/usr/bin/env bash
# The published follow command and a writer's --rebuild, on one private node.
set -euo pipefail
cd "$(dirname "$0")"
work=$(mktemp -d /tmp/s107-cli.XXXXXX)
mirror_entries() {
    S107_MIRROR_FILE="$1" nix eval --impure --raw --expr '
      let mirror = builtins.fromJSON (builtins.readFile (builtins.getEnv "S107_MIRROR_FILE"));
          tries = mirror.mirrorTries;
      in assert builtins.any (trie: builtins.length trie.mtKv > 0) tries;
         builtins.toJSON (map (trie: { inherit (trie) mtToken mtKv; }) tries)
    '
}
cleanup() {
    if [[ -n "${devnet_pid:-}" ]]; then
        kill -TERM -- "-$devnet_pid" 2>/dev/null || true
        wait "$devnet_pid" 2>/dev/null || true
    fi
    echo "follower-cli evidence: $work"
}
trap cleanup EXIT
export REGISTRY_BLUEPRINT NAMING_BLUEPRINT
REGISTRY_BLUEPRINT=$(nix build --quiet --no-link --print-out-paths ../onchain#plutus-blueprint)
NAMING_BLUEPRINT=$(nix build --quiet --no-link --print-out-paths ../naming-onchain#plutus-blueprint)
nix build --quiet --no-link .#devnet .#deployment .#register-rows
export TMPDIR="$work"
# Only this newly created process group is stopped by the trap.
setsid nix run --quiet .#devnet > "$work/devnet.out" 2> "$work/devnet.err" &
devnet_pid=$!
for _ in $(seq 1 120); do
    socket=$(head -n1 "$work/devnet.out")
    [[ -n "$socket" && -S "$socket" ]] && break
    kill -0 "$devnet_pid" 2>/dev/null || break
    sleep 1
done
[[ -n "${socket:-}" && -S "$socket" ]] || { tail -40 "$work/devnet.err"; exit 1; }
export SINGULAR_NODE_SOCKET="$socket"
nix run --quiet .#deployment -- genesis-skey --out "$work/private-devnet.skey"
external=(--node-socket "$socket" --network-magic 42 --wallet-skey "$work/private-devnet.skey")
manifest="$work/preprod.json" # documentation placeholder; private magic42 only
mirror="$work/preprod.mirror.json"
nix run --quiet .#deployment -- deploy "${external[@]}" --out "$manifest" --release follower-cli-devnet | tee "$work/deploy.log"
S3_EVIDENCE="$work/first-register" nix run --quiet .#register-rows -- "${external[@]}" --deployment "$manifest" --spelling follower-first | tee "$work/first-register.log"
[[ -s "$mirror" ]]
cp "$mirror" "$work/before-follow.json"
mirror_entries "$mirror" > "$work/expected-entries.json"
rm "$mirror"
# Same published command and flags; only the private manifest path differs.
nix run .#deployment -- follow --deployment "$manifest" --node-socket "$SINGULAR_NODE_SOCKET" | tee "$work/follow.log"
[[ -s "$mirror" ]]
grep -Fq 'deployment follow:' "$work/follow.log"
cp "$mirror" "$work/followed.json"
mirror_entries "$mirror" > "$work/followed-entries.json"
cmp "$work/expected-entries.json" "$work/followed-entries.json"
[[ $(stat -c %a "$mirror") == 600 ]]
rm "$mirror"
S3_EVIDENCE="$work/rebuild-register" nix run --quiet .#register-rows -- "${external[@]}" --deployment "$manifest" --rebuild --spelling follower-first | tee "$work/rebuild-register.log"
[[ -s "$mirror" ]]
# The existing-name path submits and observes its duplicate refusal after
# attachment. This avoids replaying the journey's fixed bob/carol fixture
# against itself; the follower E2E separately proves a new successful fold.
grep -Fq 'spelling "follower-first" is already held: duplicate insert refused' "$work/rebuild-register.log"
mirror_entries "$mirror" > "$work/rebuilt-entries.json"
cmp "$work/expected-entries.json" "$work/rebuilt-entries.json"
nix run .#deployment -- follow --deployment "$manifest" --node-socket "$SINGULAR_NODE_SOCKET" | tee "$work/after-rebuild.log"
mirror_entries "$mirror" > "$work/final-entries.json"
cmp "$work/expected-entries.json" "$work/final-entries.json"
echo 'follower-cli: PASS follow and journey --rebuild executed against the same nonempty registry'
