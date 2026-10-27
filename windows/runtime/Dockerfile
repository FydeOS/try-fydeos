# Cross toolchain for the Windows runtime, after QEMU's
# tests/docker/dockerfiles/fedora-win64-cross.docker (lcitool, fedora-43,
# mingw64). Kept: the build tools and the mingw64 libraries the runtime links;
# dropped: test, docs, Rust, GTK/VNC/TLS/curl/image libraries and NSIS, which
# this runtime disables. Fedora 43 ships only sdl2-compat (on SDL3) as
# mingw64-SDL2, and its libepoxy lacks the fix that keeps it from calling into
# a missing libEGL.dll, so SDL2 and libepoxy are built from source like
# libslirp and virglrenderer; angleproject only supplies the EGL headers. Updates are needed (the release's glib 2.86.0 cannot read
# files on msvcrt); lock.json lists the Fedora packages whose DLLs ship and
# the build stops when one has moved. Docs are installed because a few
# packages keep their license text there.
ARG BASE
FROM ${BASE}

RUN dnf --quiet --setopt=install_weak_deps=False --setopt=tsflags= install -y \
        bash bison bzip2 cmake diffutils findutils flex gcc git glib2-devel \
        jq make ninja-build patch python3 python3-PyYAML python3-pip python3-setuptools python3-wheel sed tar which xz zstd \
        mingw-w64-tools \
        mingw64-gcc \
        mingw64-gcc-c++ \
        mingw64-glib2 \
        mingw64-angleproject \
        mingw64-libfdt \
        mingw64-pixman \
        mingw64-pkg-config \
        mingw64-zstd && \
    dnf --quiet clean all && \
    rm -f /usr/lib*/python3*/EXTERNALLY-MANAGED

RUN pip3 install --no-cache-dir meson==1.8.1

ENV LANG=C.UTF-8 \
    ABI=x86_64-w64-mingw32 \
    MESON_CROSS=/usr/share/mingw/toolchain-mingw64.meson \
    CMAKE_TOOLCHAIN=/usr/share/mingw/toolchain-mingw64.cmake \
    SYSROOT=/usr/x86_64-w64-mingw32/sys-root/mingw
