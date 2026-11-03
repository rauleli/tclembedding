#!/bin/sh
# Generate configure in an isolated build directory using supplied TEA files.
set -eu

source_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
build_dir=$(pwd -P)
case "$build_dir/" in
    "$source_dir/"*) echo "Run autogen.sh from a build directory outside the source tree." >&2; exit 1 ;;
esac
if ! command -v autoconf >/dev/null 2>&1; then
    echo "Autoconf is required." >&2
    exit 1
fi
if [ -z "${TEA_CONFIG_DIR:-}" ] || [ ! -r "$TEA_CONFIG_DIR/tcl.m4" ] || [ ! -r "$TEA_CONFIG_DIR/install-sh" ]; then
    echo "Set TEA_CONFIG_DIR to a TEA 3.13 directory containing tcl.m4 and install-sh." >&2
    exit 1
fi
tea_dir=$(CDPATH= cd -- "$TEA_CONFIG_DIR" && pwd -P)
mkdir -p "$build_dir/tea-aux"
if [ -e "$build_dir/tea-aux/install-sh" ]; then
    if ! cmp -s "$tea_dir/install-sh" "$build_dir/tea-aux/install-sh"; then
        echo "The build directory already contains a different tea-aux/install-sh." >&2
        exit 1
    fi
else
    cp "$tea_dir/install-sh" "$build_dir/tea-aux/install-sh"
    chmod u+x "$build_dir/tea-aux/install-sh"
fi
autoconf -I "$tea_dir" -o "$build_dir/configure" "$source_dir/configure.ac"
printf '%s\n' 'Configure generated in the build directory.'
printf '%s\n' "Run ./configure --srcdir=\"$source_dir\" --prefix=... --with-tcl=..."
