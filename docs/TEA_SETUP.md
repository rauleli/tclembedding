# TEA build setup

The supported, tested configuration and installation procedure is documented in [INSTALL.md](../INSTALL.md). The current Unix build requires externally supplied TEA 3.13 `tcl.m4` and `install-sh`, Tcl development files, ONNX Runtime, Rust and the locked Cargo dependencies. TEA files are not bundled or downloaded by this project.

Run `autogen.sh` from an isolated build directory with `TEA_CONFIG_DIR` pointing to those TEA files, then configure with an explicit source directory and prefix. Inspect `print-install-dir` and `make -n install` before installing. The configured path and `DESTDIR` procedure were checked on the Linux environment identified in [CHARACTERIZATION.md](../CHARACTERIZATION.md); this is not a cross-platform distribution claim.

The configured root makefile provides the full `make test` suite and explicit subset targets; their fixture requirements are described in [INSTALL.md](../INSTALL.md). Dependency packaging and other platforms remain open work.
