#!/bin/sh
# Build a source archive from an explicitly selected committed tree.
set -eu
if [ "$#" -ne 2 ]; then
    echo "usage: make-source.sh COMMIT EXISTING-OUTPUT-DIRECTORY" >&2
    exit 2
fi
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
repo=$(git -C "$script_dir" rev-parse --show-toplevel)
revision=$(git -C "$repo" rev-parse --verify "$1^{commit}")
out=$(CDPATH= cd -- "$2" && pwd -P)
case "$out/" in
    "$repo/"*) echo "output directory must be outside the repository" >&2; exit 1 ;;
esac
if ! git show "$revision:configure.ac" | grep -q '^AC_INIT(\[tclembedding\], \[1\.0\.0\])$'; then
    echo "archive version does not match configure.ac" >&2
    exit 1
fi
short=$(printf '%s' "$revision" | cut -c1-12)
name="tclembedding-1.0.0-g${short}-src"
archive="$out/$name.tar.gz"
if [ -e "$archive" ] || [ -e "$archive.sha256" ]; then
    echo "output already exists" >&2
    exit 1
fi
scratch=$(mktemp -d "${TMPDIR:-/tmp}/tclembedding-source.XXXXXXXX")
trap 'rm -rf -- "$scratch"' EXIT HUP INT TERM
cd "$repo"
git show "$revision:dist/source-files.txt" > "$scratch/inventory"
set --
while IFS= read -r item || [ -n "$item" ]; do
    case "$item" in
        ''|'#'*) continue ;;
        /*|../*|*/../*|*/..|*[!a-zA-Z0-9_./-]*) echo "invalid inventory entry" >&2; exit 1 ;;
    esac
    git cat-file -e "$revision:$item"
    set -- "$@" "$item"
done < "$scratch/inventory"
[ "$#" -gt 0 ] || { echo "empty inventory" >&2; exit 1; }
mkdir "$scratch/$name"
git archive -o "$scratch/source.tar" "$revision" -- "$@"
tar -xf "$scratch/source.tar" -C "$scratch/$name"
git show "$revision:dist/SOURCE_README.md" > "$scratch/$name/README.md"
git show "$revision:dist/SOURCE_INSTALL.md" > "$scratch/$name/INSTALL.md"
git show "$revision:dist/API.md" > "$scratch/$name/API.md"
git show "$revision:dist/EXAMPLE_README.md" > "$scratch/$name/examples/01-in-memory-rag/README.md"
printf '%s\n' "$revision" > "$scratch/$name/SOURCE_REVISION"
(
    cd "$scratch/$name"
    find . -type f ! -name MANIFEST.sha256 -print0 | LC_ALL=C sort -z | xargs -0 sha256sum > MANIFEST.sha256
)
tar --sort=name --mtime='@0' --owner=0 --group=0 --numeric-owner -C "$scratch" -cf "$scratch/archive.tar" "$name"
gzip -n -c "$scratch/archive.tar" > "$scratch/archive.tar.gz"
# Do not overwrite output files, including under concurrent invocations.
( set -C; cat "$scratch/archive.tar.gz" > "$archive" )
(cd "$out" && set -C && sha256sum "$(basename "$archive")" > "$(basename "$archive").sha256")
printf '%s\n' "$archive"
