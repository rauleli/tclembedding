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

AC_ARG_WITH([simd], [AS_HELP_STRING([--with-simd=auto|scalar],
    [select CPU-specific similarity objects or the conservative scalar build])],
    [simd_mode=$withval], [simd_mode=auto])
AS_CASE([$simd_mode], [auto|scalar], [], [AC_MSG_ERROR([invalid --with-simd value])])
AC_MSG_CHECKING([target architecture])
AC_COMPILE_IFELSE([AC_LANG_PROGRAM([], [[
#if !defined(__x86_64__) && !defined(_M_X64)
#error not x86_64
#endif
]])], [simd_arch=x86_64], [
  AC_COMPILE_IFELSE([AC_LANG_PROGRAM([], [[
#if !defined(__aarch64__)
#error not aarch64
#endif
]])], [simd_arch=aarch64], [
  AC_COMPILE_IFELSE([AC_LANG_PROGRAM([], [[
#if !defined(__i386__)
#error not i386
#endif
]])], [simd_arch=i386], [simd_arch=other])])])
AC_MSG_RESULT([$simd_arch])

dnl Check the actual compiler macros before running any CPU capability probe.
dnl An explicit -m option can remain enabled after a later -march=x86-64.
AS_IF([test "$simd_arch" = x86_64], [
  AS_CASE([" $CFLAGS $CPPFLAGS "], [*"-march=native"*],
    [AC_MSG_ERROR([-march=native is not permitted for the similarity build])])
  simd_save_CPPFLAGS=$CPPFLAGS
  CPPFLAGS="$CPPFLAGS -I$srcdir/src"
  AC_COMPILE_IFELSE([AC_LANG_SOURCE([[
#include "similarity_baseline.h"
int main(void) { return 0; }
  ]])], [], [AC_MSG_ERROR([compiler flags exceed the x86-64 similarity baseline])])
  CPPFLAGS=$simd_save_CPPFLAGS
])

dnl GCC and Clang report AVX only when the OS enables the required state.
dnl Never execute a target test when Autoconf detects a cross build.
AC_COMPILE_IFELSE([AC_LANG_PROGRAM([], [[
#if !defined(__x86_64__) && !defined(__i386__)
#error x86 detector unavailable
#endif
__builtin_cpu_init(); return __builtin_cpu_supports("sse2") ? 0 : 1;
]])], [simd_detector=yes], [simd_detector=no])
m4_foreach_w([feature], [sse2 avx avx2 avx512f], [
  AC_MSG_CHECKING([whether target CPU and OS can use ]feature)
  AS_IF([test "$simd_detector" = yes], [
  AC_RUN_IFELSE([AC_LANG_SOURCE([[
int main(void) {
#if (defined(__x86_64__) || defined(__i386__)) && (defined(__GNUC__) || defined(__clang__))
  __builtin_cpu_init();
  return __builtin_cpu_supports("]]feature[[") ? 0 : 1;
#else
  return 1;
#endif
}
  ]])], [cpu_[]feature=yes], [cpu_[]feature=no], [cpu_[]feature=unknown-cross])
  ], [cpu_[]feature=unknown-detector])
  AC_MSG_RESULT([$cpu_[]feature])
])
save_CFLAGS=$CFLAGS
for flag in sse2 avx avx2 avx512f; do
  CFLAGS="$save_CFLAGS -m$flag -Werror"
  AC_MSG_CHECKING([whether the compiler accepts -m$flag])
  AC_COMPILE_IFELSE([AC_LANG_PROGRAM([], [[return 0;]])],
    [eval "compiler_$flag=yes"; AC_MSG_RESULT([yes])],
    [eval "compiler_$flag=no"; AC_MSG_RESULT([no])])
done
CFLAGS=$save_CFLAGS
SIMD_BASE_CFLAGS=
AS_IF([test "$simd_arch" = x86_64], [
  CFLAGS="$save_CFLAGS -march=x86-64 -Werror"
  AC_COMPILE_IFELSE([AC_LANG_PROGRAM([], [[return 0;]])],
    [SIMD_BASE_CFLAGS=-march=x86-64],
    [AC_MSG_ERROR([compiler cannot establish the x86-64 baseline])])
  CFLAGS=$save_CFLAGS
])
SIMD_OBJECTS=
SIMD_CPPFLAGS=
SIMD_SSE2_CFLAGS=
AS_IF([test "$simd_mode" = auto && test "$simd_arch" = x86_64 &&
       test "$compiler_sse2" = yes && test "$cross_compiling" != yes &&
       test "$cpu_sse2" = yes], [
  SIMD_OBJECTS=similarity_sse2.o
  SIMD_CPPFLAGS=-DTCLEMBEDDING_HAVE_SSE2
  SIMD_SSE2_CFLAGS=-msse2
])
AC_SUBST([SIMD_OBJECTS])
AC_SUBST([SIMD_CPPFLAGS])
AC_SUBST([SIMD_SSE2_CFLAGS])
AC_SUBST([SIMD_BASE_CFLAGS])
AC_MSG_NOTICE([SIMD mode=$simd_mode target=$simd_arch cross=$cross_compiling])
AC_MSG_NOTICE([CPU/OS: SSE2=$cpu_sse2 AVX=$cpu_avx AVX2=$cpu_avx2 AVX512F=$cpu_avx512f])
AC_MSG_NOTICE([compiler flags: SSE2=$compiler_sse2 AVX=$compiler_avx AVX2=$compiler_avx2 AVX512F=$compiler_avx512f])
AC_MSG_NOTICE([configured similarity objects: scalar $SIMD_OBJECTS; AVX/AVX2/AVX512 not implemented])

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
