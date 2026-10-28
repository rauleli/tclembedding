# Getting Started with tclembedding TEA Distribution

Welcome! You now have a complete, professional Tcl Extension Architecture (TEA) setup for the tclembedding project.

## What You Have

A production-ready Tcl extension with:
- ✓ Automatic cross-platform build configuration (autoconf)
- ✓ Standard Unix build system (Makefiles)
- ✓ Tcl package integration
- ✓ Comprehensive documentation
- ✓ Usage examples and tests

## Next Steps

### 1. First Time Setup

If this is a fresh checkout, generate the configure script:

```bash
cd /path/to/tclembedding
make -f Makefile.dev configure
```

This creates the `configure` script from `configure.ac`.

### 2. Configure for Your System

```bash
./configure
```

By default, this configures for `/usr/local` installation. Options:

```bash
# Custom prefix
./configure --prefix=$HOME/.local

# Specify Tcl location
./configure --with-tcl=/usr/lib/tcl8.6

# Debug build
./configure --enable-debug
```

### 3. Build

```bash
make
```

This compiles the C extension and produces `unix/tclembedding.so`.

### 4. Install

```bash
make install
```

For a custom location:

```bash
make install DESTDIR=/tmp/staging
```

### 5. Verify Installation

```tcl
#!/usr/bin/env tclsh
package require tclembedding
puts "Extension loaded: [package provide tclembedding]"
```

Or run tests:

```bash
make test
```

## Choosing Installation Locations

### System-Wide (Requires sudo)

```bash
./configure --prefix=/usr/local
make
sudo make install

# Extension goes to: /usr/local/lib/tclembedding1.0/
```

### User Home Directory

```bash
./configure --prefix=$HOME/.local
make
make install

# Extension goes to: ~/.local/lib/tclembedding1.0/
# Add to .bashrc: export PATH=$HOME/.local/bin:$PATH
```

### Development (In-place)

```bash
./configure --prefix=$(pwd)/install
make
make install

# Extension goes to: ./install/lib/tclembedding1.0/
# Test with: tclsh -c "lappend auto_path $(pwd)/install/lib; package require tclembedding"
```

## Common Tasks

### Check Installation

```bash
# Find installation directory
tclsh -c 'puts [lindex $::auto_path 0]'

# List installed files
ls -la "$(tclsh -c 'puts [lindex $::auto_path 0]')"/tclembedding1.0/
```

### Clean and Rebuild

```bash
# Remove build artifacts but keep configure
make clean

# Rebuild
make
make install
```

### Full Clean (includes configure)

```bash
make distclean
```

### Use Installed Extension

```tcl
package require tclembedding
package require tokenizer

# Load tokenizer vocabulary
tokenizer::load_vocab "path/to/tokenizer.json"

# Initialize ONNX model
set handle [embedding::init_raw "path/to/model.onnx"]

# Tokenize and compute embedding
set tokens [tokenizer::tokenize "your text here"]
set embedding [embedding::compute $handle $tokens]

# Cleanup
embedding::free $handle
```

## Understanding the Structure

```
tclembedding/
├── configure              ← Run this to configure your build
├── Makefile               ← Generated, do not edit
├── generic/               ← Source code (C)
├── unix/Makefile          ← Generated Unix build rules
├── lib/                   ← Tcl library code
├── tests/                 ← Test suite
└── [documentation]        ← README, INSTALL, etc.
```

**Key:** After running `./configure`, don't edit the generated `Makefile` or `unix/Makefile` files - they are recreated if configure is rerun.

## Troubleshooting

### "command not found: configure"

You need to generate it first:

```bash
make -f Makefile.dev configure
```

### "cannot find -lonnxruntime"

Install ONNX Runtime:

- **Ubuntu/Debian:** `sudo apt-get install libonnxruntime-dev`
- **Fedora:** `sudo dnf install onnxruntime-devel`
- **macOS:** `brew install onnx-runtime`

Or specify the location:

```bash
LDFLAGS=-L/path/to/onnxruntime/lib ./configure
export LD_LIBRARY_PATH=/path/to/onnxruntime/lib:$LD_LIBRARY_PATH
```

### "Tcl not found"

Find your Tcl:

```bash
tclsh -c 'puts [file dirname [info library]]'
```

Then tell configure:

```bash
./configure --with-tcl=/usr/lib/tcl8.6
```

### Installation fails with permission denied

Use a location you own, or use sudo:

```bash
# Option 1: Install to home directory
./configure --prefix=$HOME/.local
make
make install

# Option 2: Use sudo for system installation
./configure
make
sudo make install
```

### Package not found after installation

Ensure installation directory is in Tcl path:

```tcl
# Check where Tcl looks for packages
puts $::auto_path

# Manually load if needed
set dir /path/to/tclembedding1.0
lappend auto_path $dir
package require tclembedding
```

## Advanced Usage

### Build with Custom Compiler

```bash
./configure CC=gcc-11 CXX=g++-11
make
```

### Build with Optimization

```bash
./configure CFLAGS="-O3 -march=native"
make
```

### Build with Debugging

```bash
./configure --enable-debug CFLAGS="-g -O0"
make
```

### Out-of-Source Build

```bash
mkdir build
cd build
../configure
make
make install
```

### Build and Test Multiple Times

```bash
./configure
make clean
make
make test

# Make changes...

make clean
make
make test
```

## Creating Distributions

To create a tarball for distribution:

```bash
# Using git
git archive --format=tar.gz --prefix=tclembedding-1.0.0/ \
  -o tclembedding-1.0.0.tar.gz HEAD

# Manual
tar czf tclembedding-1.0.0.tar.gz \
  --exclude=.git --exclude=build --exclude=models \
  --exclude=.vscode --exclude=.DS_Store \
  tclembedding/
```

Users can then:

```bash
tar xzf tclembedding-1.0.0.tar.gz
cd tclembedding-1.0.0
./configure
make
sudo make install
```

## Documentation

- **README.md** - Overview and quick reference
- **INSTALL.md** - Detailed installation instructions
- **STRUCTURE.md** - Project architecture
- **CHANGELOG.md** - Version history
- **examples.tcl** - Usage examples

## Getting Help

1. **Check documentation**
   ```bash
   less README.md
   less INSTALL.md
   ```

2. **Review examples**
   ```bash
   cat examples.tcl
   ```

3. **Check configure help**
   ```bash
   ./configure --help
   ```

4. **Examine test results**
   ```bash
   make test
   ```

## Summary

The installation process is straightforward:

```bash
make -f Makefile.dev configure    # Generate configure (first time)
./configure                        # Configure build
make                               # Build
make install                       # Install
tclsh -c "package require tclembedding; puts OK"  # Verify
```

That's it! You're ready to use tclembedding in your Tcl scripts.

## Next: Using the Extension

Once installed, use in your Tcl code:

```tcl
#!/usr/bin/env tclsh

package require tclembedding
package require tokenizer

# Load model
set model_path "models/e5-small/model.onnx"
set tokenizer_path "models/e5-small/tokenizer.json"

tokenizer::load_vocab $tokenizer_path
set handle [embedding::init_raw $model_path]

# Generate embeddings (e5-small uses "query:" prefix)
set text1 "query: Hello, world!"
set text2 "query: Hi there!"

set tokens1 [tokenizer::tokenize $text1]
set tokens2 [tokenizer::tokenize $text2]

set embedding1 [embedding::compute $handle $tokens1]
set embedding2 [embedding::compute $handle $tokens2]

# Calculate similarity (dot product for normalized vectors)
set similarity [dot_product $embedding1 $embedding2]
puts "Similarity: [format %.4f $similarity]"

# Cleanup
embedding::free $handle

proc dot_product {vec1 vec2} {
    set dot 0.0
    foreach v1 $vec1 v2 $vec2 {
        set dot [expr {$dot + $v1 * $v2}]
    }
    return $dot
}
```

See `examples.tcl` for more detailed examples.

---

Happy building! 🚀
