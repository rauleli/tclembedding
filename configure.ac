dnl configure.ac for tclembedding extension
dnl This file is processed by autoconf to produce the configure script
dnl Follows Tcl Extension Architecture (TEA) standards

AC_INIT([tclembedding], [1.0.0])

# TEA 3.13 macros are supplied explicitly when generating configure.
m4_include([tcl.m4])
AC_CONFIG_SRCDIR([generic/tclembedding.c])
AC_CONFIG_AUX_DIR([$ac_pwd/tea-aux])

# Standard C compiler checks
AC_PROG_CC
AC_PROG_MAKE_SET

# TEA configuration (Tcl Extension Architecture)
TEA_INIT([3.13])
AS_IF([test "x$TEA_VERSION" != x3.13], [AC_MSG_ERROR([TEA 3.13 macros are required])])

# TEA's installer must use the genuine auxiliary file in the build directory.
AS_IF([test ! -r "$ac_pwd/tea-aux/install-sh"],
      [AC_MSG_ERROR([run autogen.sh in this build directory to prepare TEA auxiliary files])])
INSTALL='$(SHELL) ../tea-aux/install-sh -c'
AC_SUBST([INSTALL])

# Find Tcl configuration
TEA_PATH_TCLCONFIG
TEA_LOAD_TCLCONFIG
AS_IF([test "x$TEA_PLATFORM" != xunix],
      [AC_MSG_ERROR([this build supports Unix; check the compiler recorded in tclConfig.sh])])
AC_SUBST([TCL_INCLUDE_SPEC])
TEA_PROG_TCLSH

# Set up compiler
TEA_SETUP_COMPILER

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
