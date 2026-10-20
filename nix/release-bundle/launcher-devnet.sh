# shellcheck shell=sh
# The development node's part of its launcher, inserted before the program
# starts: it names itself for --version and --help (any other argument would
# start a node), reads the genesis files the bundle carries and finds the
# bundled cardano-node by name, the way it does from a Nix shell.
# shellcheck disable=SC2154
# (here is set by the launcher this text is inserted into)
case ${1-} in
  --version)
    printf '%s\n' 'devnet @VERSION@ (commit @COMMIT@)'
    exit 0
    ;;
  --help | -h)
    printf '%s\n' 'devnet @VERSION@ (commit @COMMIT@)' \
      'Starts a private Cardano development node and prints its settings as one JSON line.' \
      'Funding: --fund-address ADDRESS:N:LOVELACE (see the Demo 1 development node page).'
    exit 0
    ;;
esac
E2E_GENESIS_DIR=$here/share/devnet/genesis
export E2E_GENESIS_DIR
PATH=$here/bin${PATH:+:$PATH}
export PATH
