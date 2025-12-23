dnl configure.ac for tclembedding extension
dnl This file is processed by autoconf to produce the configure script
dnl Follows Tcl Extension Architecture (TEA) standards

AC_INIT([tclembedding], [1.0.0])

# Autoconf setup
AC_CONFIG_AUX_DIR([.])

# Standard C compiler checks
AC_PROG_CC
AC_PROG_MAKE_SET
AC_PROG_INSTALL

# TEA configuration (Tcl Extension Architecture)
TEA_INIT([3.13])

# Find Tcl configuration
TEA_PATH_TCLCONFIG
TEA_LOAD_TCLCONFIG

# Set up compiler
TEA_SETUP_COMPILER_CC
TEA_SETUP_COMPILER_CFLAGS

# Check for required headers
AC_CHECK_HEADERS([onnxruntime_c_api.h], [], [
  AC_MSG_ERROR([onnxruntime_c_api.h not found. Install ONNX Runtime development package:
    Ubuntu/Debian: sudo apt-get install libonnxruntime-dev
    Fedora/RHEL:   sudo dnf install onnxruntime-devel
    macOS:         brew install onnx-runtime])
])

# Check for ONNX Runtime library
AC_CHECK_LIB([onnxruntime], [OrtGetApiBase], [], [
  AC_MSG_ERROR([libonnxruntime not found. Install ONNX Runtime library])
])

# Check for math library
AC_CHECK_LIB([m], [sqrt], [LIBS="-lm $LIBS"])

# Substitute version in pkgIndex.tcl
AC_SUBST(VERSION, [1.0.0])

# Create Makefiles from templates
AC_CONFIG_FILES([
  Makefile
  unix/Makefile
])

AC_OUTPUT

echo ""
echo "Configuration complete!"
echo ""
echo "Next steps:"
echo "  1. make"
echo "  2. make install"
echo ""
