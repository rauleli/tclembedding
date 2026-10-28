# Project Structure

This document describes the directory and file organization of the tclembedding project following the Tcl Extension Architecture (TEA) standard.

## Directory Layout

```
tclembedding/
├── configure                 # Generated autoconf script
├── configure.ac             # Autoconf configuration source
├── autogen.sh               # Script to generate configure from configure.ac
├── Makefile.in              # Top-level Makefile template
├── Makefile.dev             # Development convenience makefile
│
├── generic/                 # Platform-independent source code
│   ├── tclembedding.c       # Main extension C code
│   └── tokenizer.tcl        # Tcl tokenizer module
│
├── unix/                    # Unix/Linux-specific build rules
│   └── Makefile.in          # Unix build configuration template
│
├── lib/                     # Tcl library modules
│   └── tokenizer.tcl        # Tokenizer Tcl implementation
│
├── tests/                   # Test suite
│   ├── quick_test.tcl       # Basic functionality tests
│   └── VERSION              # Version file (1.0.0)
│
├── models/                  # ONNX models (not distributed)
│   ├── paraphrase-multilingual-MiniLM-L12-v2/
│   │   ├── model.onnx
│   │   └── tokenizer.json
│   └── multilingual-e5-large/
│       ├── model.onnx
│       └── tokenizer.json
│
├── src/                     # Original source directory
│   ├── tclembedding.c       # (backup of generic version)
│   └── rag_optimizations.c  # MySQL UDF utilities (optional)
│
├── tools/                   # Development tools
│
├── Documentation Files:
├── README.md                # Overview and quick start
├── INSTALL.md               # Detailed installation instructions
├── CHANGELOG.md             # Version history and changes
├── STRUCTURE.md             # This file
├── LICENSE                  # MIT License
├── .gitignore              # Git ignore rules
│
└── Configuration Files:
    ├── pkgIndex.tcl.in      # Package registration template
    └── examples.tcl         # Usage examples
```

## TEA Standard Compliance

The project follows the Tcl Extension Architecture (TEA) standard for cross-platform compatibility:

### Core TEA Components

1. **configure.ac** - Autoconf configuration script
   - Detects Tcl installation
   - Checks for dependencies (ONNX Runtime)
   - Generates Makefiles

2. **unix/Makefile.in** - Build rules for Unix/Linux
   - Compilation flags
   - Library linking
   - Installation targets

3. **generic/** - Platform-independent C source
   - `tclembedding.c` - Main extension code
   - `tokenizer.tcl` - Optional Tcl modules

4. **pkgIndex.tcl.in** - Package registration
   - Enables automatic package loading
   - Specifies version information

## File Purposes

### Build Configuration

| File | Purpose |
|------|---------|
| `configure.ac` | Autoconf template (generates configure) |
| `configure` | Generated shell script for system setup |
| `Makefile.in` | Template for top-level Makefile |
| `unix/Makefile.in` | Template for Unix-specific build rules |
| `autogen.sh` | Script to generate configure from configure.ac |
| `Makefile.dev` | Convenience makefile for development |

### Source Code

| Directory | Purpose |
|-----------|---------|
| `generic/` | Platform-independent C source code |
| `unix/` | Unix/Linux specific build configuration |
| `lib/` | Tcl library code and modules |
| `src/` | Original source (retained for reference) |

### Documentation

| File | Purpose |
|------|---------|
| `README.md` | Project overview and basic usage |
| `INSTALL.md` | Detailed installation instructions |
| `CHANGELOG.md` | Version history and release notes |
| `STRUCTURE.md` | This file - project organization |
| `LICENSE` | MIT License text |

### Package Integration

| File | Purpose |
|------|---------|
| `pkgIndex.tcl.in` | Tcl package index template |
| `examples.tcl` | Usage examples and demonstrations |
| `tests/quick_test.tcl` | Test suite |

## Installation Directory Structure

After `make install`, the extension is installed to:

```
$prefix/lib/tclembedding1.0/
├── tclembedding.so         # Compiled shared library
├── pkgIndex.tcl            # Package registration
├── tokenizer.tcl           # (if present)
└── [other Tcl modules]
```

Where `$prefix` is specified during configure (default: `/usr/local`).

## Build Process

### 1. Generate Configure Script
```bash
autoconf              # Uses configure.ac
```

### 2. Configure for Your System
```bash
./configure          # Creates Makefile from Makefile.in
```

### 3. Build
```bash
make                 # Compiles using unix/Makefile
```

### 4. Install
```bash
make install         # Installs to $prefix/lib/tclembedding1.0/
```

## Tcl Integration

### Package Loading

Once installed, users can load the extension:

```tcl
package require tclembedding
```

The `pkgIndex.tcl` file in the installation directory enables automatic discovery:
- Loads `tclembedding.so` (compiled C extension)
- Optionally loads `tokenizer.tcl` (Tcl modules)

### Module Organization

```tcl
# Main C extension
embedding::init
embedding::encode
embedding::info
embedding::free

# Optional Tcl modules
tokenizer::load_vocab
tokenizer::encode
```

## Development Workflow

### Quick Development Setup

```bash
# 1. Generate configure
make -f Makefile.dev configure

# 2. Configure with local prefix
./configure --prefix=$HOME/tcl-embedding

# 3. Build
make

# 4. Install locally
make install

# 5. Test
tclsh -c "lappend auto_path $HOME/tcl-embedding/lib; package require tclembedding"
```

### Testing

```bash
# After building
make test

# Or manually
tclsh tests/quick_test.tcl
```

## Configuration Variables

The configure script recognizes these variables:

### Build Configuration
- `CC` - C compiler (default: detected)
- `CFLAGS` - Compiler flags
- `LDFLAGS` - Linker flags
- `CPPFLAGS` - Preprocessor flags

### Installation
- `--prefix` - Installation root (default: `/usr/local`)
- `--exec-prefix` - Executable installation root

### Tcl Detection
- `--with-tcl` - Path to tcl/config directory

### Dependencies
- `CPPFLAGS` - Include path for ONNX Runtime headers
- `LDFLAGS` - Library path for libonnxruntime

### Example Custom Configuration

```bash
./configure \
  --prefix=$HOME/tcl-embedding \
  --with-tcl=/usr/lib/tcl8.6 \
  CPPFLAGS=-I/opt/onnxruntime/include \
  LDFLAGS=-L/opt/onnxruntime/lib
```

## Platform Considerations

### Linux
- Fully supported and tested
- Standard Unix build process
- Install development packages: `tcl-dev`, `libonnxruntime-dev`

### macOS
- Supported via Unix build rules
- May require specification of Tcl location
- Homebrew packages available

### Windows
- Requires MSYS2/MinGW environment
- Additional configuration may be needed
- Full Windows support planned for future versions

## Design Decisions

### Why TEA?
- **Cross-platform compatibility** - Works on Unix, Linux, macOS
- **Standard integration** - Follows Tcl community conventions
- **Automated dependencies** - autoconf handles system detection
- **User familiarity** - Follows expected `./configure && make && make install`

### Why Separate generic/ and unix/?
- **Portability** - Easier to add platform-specific code later
- **Standards compliance** - TEA best practices
- **Maintainability** - Clear separation of concerns

### Why pkgIndex.tcl.in?
- **Automatic discovery** - Tcl automatically finds and loads the extension
- **Version management** - Makes version specified in one place
- **Flexibility** - Can reference multiple modules

## References

- [Tcl Extension Architecture (TEA)](https://www.tcl.tk/doc/tea/tea.html)
- [Autoconf Manual](https://www.gnu.org/software/autoconf/)
- [GNU Make Manual](https://www.gnu.org/software/make/)
- [Tcl Package Management](https://www.tcl.tk/man/tcl/TclCmd/package.htm)
