# Installation Instructions for tclembedding

This document provides detailed instructions for building and installing the tclembedding Tcl extension.

## Quick Start

For the impatient:

```bash
./configure
make
make install
```

Then use in Tcl:
```tcl
package require tclembedding
```

## Prerequisites

### Required Dependencies

1. **Tcl/Tk 8.6 or later**
   - Include development files (headers)
   - Usually in `tcl-dev` or `tcl-devel` package

2. **ONNX Runtime 1.12 or later**
   - C library and headers
   - Available from [onnxruntime.ai](https://onnxruntime.ai/)

3. **Standard Build Tools**
   - C compiler (GCC, Clang, etc.)
   - GNU make
   - autoconf (for generating configure script)

### Platform-Specific Installation

#### Ubuntu/Debian

```bash
# Install Tcl development files
sudo apt-get install tcl-dev tcl8.6-dev

# Install ONNX Runtime
sudo apt-get install libonnxruntime libonnxruntime-dev

# Install build tools
sudo apt-get install build-essential autoconf
```

#### Fedora/RHEL

```bash
# Install Tcl development files
sudo dnf install tcl-devel

# Install ONNX Runtime
sudo dnf install onnxruntime onnxruntime-devel

# Install build tools
sudo dnf install gcc autoconf make
```

#### macOS (Homebrew)

```bash
# Install Tcl
brew install tcl-tk

# Install ONNX Runtime
brew install onnx-runtime

# Install autoconf (if not present)
brew install autoconf
```

#### Windows (MSYS2/MinGW)

```bash
pacman -S mingw-w64-x86_64-tcl
pacman -S mingw-w64-x86_64-onnxruntime
pacman -S autoconf
```

## Building from Source

### Step 1: Generate Configure Script (if needed)

If `configure` is not present:

```bash
autoconf
```

Or use the provided script:

```bash
./autogen.sh
```

This generates the `configure` script from `configure.ac`.

### Step 2: Configure the Build

```bash
./configure [OPTIONS]
```

**Common Options:**

- `--prefix=/usr/local` - Installation prefix (default: `/usr/local`)
- `--with-tcl=/path/to/tcl/config` - Tcl configuration directory
- `--enable-shared` - Build shared library (default)
- `--with-onnxruntime-prefix=/path` - ONNX Runtime installation directory

**Example with custom prefix:**

```bash
./configure --prefix=$HOME/tcl-embedding
```

**Example specifying Tcl location:**

```bash
./configure --with-tcl=/usr/lib/tcl8.6
```

### Step 3: Build the Extension

```bash
make
```

This compiles the C extension and produces `unix/tclembedding.so`.

### Step 4: Install

```bash
make install
```

By default, installs to:
```
$prefix/lib/tclembedding1.0/
```

For custom destination (staging):

```bash
make install DESTDIR=/tmp/staging
```

## Verification

### Check Installation

```bash
# List installed files
ls -la $(tclsh -c 'puts [lindex $::auto_path 0]')/tclembedding1.0/
```

### Test Loading

```tcl
#!/usr/bin/env tclsh
package require tclembedding
puts "✓ tclembedding successfully loaded!"
puts "Version: [package version tclembedding]"
```

Run tests:

```bash
make test
```

Or manually:

```bash
tclsh tests/quick_test.tcl
```

## Configuration Details

### Environment Variables

- `TCL_LIBRARY` - Path to Tcl libraries (if non-standard)
- `LD_LIBRARY_PATH` - Library search path (for libonnxruntime)
- `CFLAGS` - Compiler flags
- `LDFLAGS` - Linker flags

Example with custom library paths:

```bash
export LD_LIBRARY_PATH=/usr/local/lib:$LD_LIBRARY_PATH
./configure --prefix=/usr/local
make
make install
```

### Finding Tcl Configuration

The configure script searches for Tcl in standard locations. If it fails:

1. Find your Tcl installation:
   ```bash
   tclsh -c 'puts $::tcl_library'
   ```

2. Locate tclConfig.sh:
   ```bash
   find / -name "tclConfig.sh" 2>/dev/null
   ```

3. Configure with explicit path:
   ```bash
   ./configure --with-tcl=/path/to/tcl/config/dir
   ```

## Troubleshooting

### "configure: error: onnxruntime_c_api.h not found"

**Solution:** Install ONNX Runtime development package:

```bash
# Ubuntu/Debian
sudo apt-get install libonnxruntime-dev

# Fedora
sudo dnf install onnxruntime-devel

# macOS
brew install onnx-runtime
```

Or specify the location:

```bash
CPPFLAGS=-I/path/to/onnxruntime/include ./configure
```

### "ld: cannot find -lonnxruntime"

**Solution:** ONNX Runtime library not found in linker path:

```bash
# Find libonnxruntime.so
find /usr -name "libonnxruntime.so*" 2>/dev/null

# Add to linker path
LDFLAGS=-L/path/to/onnxruntime/lib ./configure
export LD_LIBRARY_PATH=/path/to/onnxruntime/lib:$LD_LIBRARY_PATH
```

### "cannot find -ltcl8.6"

**Solution:** Tcl libraries not found:

```bash
# Install Tcl development package
sudo apt-get install tcl-dev tcl8.6-dev

# Or specify location
./configure --with-tcl=/path/to/tcl/config/dir
```

### Extension doesn't load: "undefined symbol"

**Causes:**
1. Library path issues
2. Incompatible ONNX Runtime version
3. Missing dependent libraries

**Solutions:**

```bash
# Check library dependencies
ldd unix/tclembedding.so

# Set library path
export LD_LIBRARY_PATH=/usr/local/lib:$LD_LIBRARY_PATH

# Try with rpath (if configure supports it)
./configure --with-rpath
```

### "command not found: ./configure"

**Solution:** Generate configure script:

```bash
autoconf
./configure
```

## Uninstallation

Remove the installed extension:

```bash
rm -rf $(tclsh -c 'puts [lindex $::auto_path 0]')/tclembedding1.0/
```

Or, if installed with a specific prefix:

```bash
rm -rf /usr/local/lib/tclembedding1.0/
```

## Development Installation

For development work, build in-place:

```bash
./configure
make
# Test without installing
tclsh -c "lappend auto_path [file normalize unix]; package require tclembedding"
```

Or create a symlink to the build directory in Tcl's package path.

## Cross-Compilation

For cross-compilation, set compiler variables:

```bash
./configure \
  --host=arm-linux-gnueabihf \
  CC=arm-linux-gnueabihf-gcc \
  --with-tcl=/path/to/arm/tcl/config
make
```

## Building a Distribution

Create a source tarball:

```bash
git archive --format=tar.gz --prefix=tclembedding-1.0.0/ \
  -o tclembedding-1.0.0.tar.gz HEAD
```

Users can then:

```bash
tar xzf tclembedding-1.0.0.tar.gz
cd tclembedding-1.0.0
./configure
make
make install
```

## See Also

- [Tcl Extension Architecture (TEA)](https://www.tcl.tk/doc/tea/tea.html)
- [ONNX Runtime Installation](https://onnxruntime.ai/docs/build/)
- [Tcl Package Guide](https://www.tcl.tk/man/tcl8.6/TclCmd/package.htm)
