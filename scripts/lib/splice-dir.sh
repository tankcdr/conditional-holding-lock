# Resolve the Splice checkout. Not a git submodule of this repo.
# Default: ./splice (gitignored). Override with SPLICE_DIR.
SPLICE_DIR="${SPLICE_DIR:-$ROOT/splice}"
SPLICE_FORK="${SPLICE_FORK:-https://github.com/tankcdr/splice.git}"
SPLICE_BRANCH="${SPLICE_BRANCH:-cip-conditional-holding-lock}"

require_splice() {
  if [ ! -f "$SPLICE_DIR/token-standard/splice-api-token-conditional-lock-v1/daml.yaml" ]; then
    echo "error: no Splice CIP checkout at $SPLICE_DIR" >&2
    echo "clone it (gitignored here) with:" >&2
    echo "  ./scripts/clone-splice.sh" >&2
    echo "or set SPLICE_DIR to an existing canton-network/splice fork on $SPLICE_BRANCH" >&2
    return 1
  fi
}
