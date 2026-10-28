#!/bin/bash
# autogen.sh - Generate configure script from configure.ac
# This script creates the configure script using autoconf

set -e

echo "Generating configure script from configure.ac..."

# Check if autoconf is available
if ! command -v autoconf &> /dev/null; then
    echo "Error: autoconf is not installed."
    echo "Install it with:"
    echo "  Ubuntu/Debian: sudo apt-get install autoconf"
    echo "  Fedora/RHEL:   sudo dnf install autoconf"
    echo "  macOS:         brew install autoconf"
    exit 1
fi

# Check if Tcl is installed (required for TEA)
if ! pkg-config --exists tcl; then
    echo "Warning: Tcl development files not found."
    echo "Install with:"
    echo "  Ubuntu/Debian: sudo apt-get install tcl-dev"
    echo "  Fedora/RHEL:   sudo dnf install tcl-devel"
    echo "  macOS:         brew install tcl-tk"
fi

# Generate the configure script
autoconf

echo ""
echo "✓ Configure script generated successfully!"
echo ""
echo "Next steps:"
echo "  1. ./configure"
echo "  2. make"
echo "  3. make install"
echo ""
