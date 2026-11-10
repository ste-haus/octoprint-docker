ARG PYTHON_VERSION=3.13
ARG DEBIAN_RELEASE=trixie
ARG PYTHON_BASE_IMAGE=${PYTHON_VERSION}-slim-${DEBIAN_RELEASE}

# Obico's bundled Janus is 0.11.x and its generated streaming config uses the
# legacy (pre-multistream) syntax, so stay on the 0.x line.
ARG JANUS_VERSION=0.16.3
ARG JANUS_REPO=https://github.com/meetecho/janus-gateway.git
ARG JANUS_PREFIX=/usr
ARG JANUS_DEB=/tmp/janus.deb

ARG S6_DOWNLOAD_UBUNTU_RELEASE=24.04

FROM ubuntu:${S6_DOWNLOAD_UBUNTU_RELEASE} AS s6build
ARG S6_RELEASE
ENV S6_VERSION ${S6_RELEASE:-v2.1.0.0}
RUN apt-get update && apt-get install -y curl
RUN dpkg --print-architecture
WORKDIR /tmp
RUN ARCH= && dpkgArch="$(dpkg --print-architecture)" \
  && case "${dpkgArch##*-}" in \
  amd64) ARCH='amd64';; \
  arm64) ARCH='aarch64';; \
  armhf) ARCH='armhf';; \
  *) echo "unsupported architecture: $(dpkg --print-architecture)"; exit 1 ;; \
  esac \
  && set -ex \
  && echo $S6_VERSION \
  && curl -fsSLO "https://github.com/just-containers/s6-overlay/releases/download/$S6_VERSION/s6-overlay-$ARCH.tar.gz"



# Build Janus and wrap it in a .deb named "janus". The Obico plugin only
# accepts a system Janus it can locate with `dpkg -L janus`.
FROM debian:${DEBIAN_RELEASE}-slim AS janus-builder

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ARG JANUS_VERSION
ARG JANUS_REPO
ARG JANUS_PREFIX
ARG JANUS_DEB

ARG JANUS_SRC_DIR=/tmp/janus-src
ARG JANUS_STAGING_DIR=/tmp/janus-root
ARG JANUS_SHLIBDEPS_DIR=/tmp/janus-shlibdeps

RUN apt-get update && apt-get install -y --no-install-recommends \
      autoconf \
      automake \
      ca-certificates \
      dpkg-dev \
      gcc \
      gengetopt \
      git \
      libconfig-dev \
      libcurl4-openssl-dev \
      libglib2.0-dev \
      libjansson-dev \
      libnice-dev \
      libsrtp2-dev \
      libssl-dev \
      libtool \
      libusrsctp-dev \
      libwebsockets-dev \
      make \
      pkg-config \
      zlib1g-dev \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

RUN git clone --depth 1 --branch "v${JANUS_VERSION}" "${JANUS_REPO}" "${JANUS_SRC_DIR}"

# Only the streaming plugin and websockets transport are used by Obico
WORKDIR ${JANUS_SRC_DIR}
RUN sh autogen.sh \
    && ./configure \
         --prefix="${JANUS_PREFIX}" \
         --disable-docs \
         --disable-all-plugins \
         --disable-all-transports \
         --disable-all-handlers \
         --disable-all-loggers \
         --enable-plugin-streaming \
         --enable-websockets \
         --enable-data-channels \
    && make -j"$(nproc)" \
    && make DESTDIR="${JANUS_STAGING_DIR}" install-strip

# Depends lists the runtime libraries so apt pulls them into the final image.
# dpkg-shlibdeps derives them from the built binaries, so the names track the
# Debian release, and it needs a stub debian/control to run outside a source tree.
WORKDIR ${JANUS_SHLIBDEPS_DIR}
RUN mkdir -p debian "${JANUS_STAGING_DIR}/DEBIAN" \
    && printf '%s\n' "Source: janus" "" "Package: janus" "Architecture: any" \
         > debian/control \
    && janus_depends="$(find "${JANUS_STAGING_DIR}${JANUS_PREFIX}/bin" "${JANUS_STAGING_DIR}${JANUS_PREFIX}/lib/janus" \
         -type f \( -name janus -o -name '*.so*' \) -print0 \
         | xargs -0 dpkg-shlibdeps -O 2>/dev/null \
         | sed -n 's/^shlibs:Depends=//p')" \
    && test -n "${janus_depends}" \
    && printf '%s\n' \
         "Package: janus" \
         "Version: ${JANUS_VERSION}" \
         "Architecture: $(dpkg --print-architecture)" \
         "Maintainer: ste.haus" \
         "Depends: ${janus_depends}" \
         "Description: Janus WebRTC gateway, local build for the Obico plugin" \
         > "${JANUS_STAGING_DIR}/DEBIAN/control" \
    && cat "${JANUS_STAGING_DIR}/DEBIAN/control" \
    && dpkg-deb --build "${JANUS_STAGING_DIR}" "${JANUS_DEB}"


FROM python:${PYTHON_BASE_IMAGE} AS build

ARG JANUS_DEB

# OctoPrint's version comes from OCTOPRINT_VERSION in .env; octoprint_ref
# overrides it for one-off builds of another tag or branch
ARG octoprint_ref
ARG BUILD_ENV_FILE=/tmp/build.env
ARG OCTOPRINT_SRC_DIR=/opt/octoprint

RUN apt-get update && apt-get install -y \
  avrdude \
  build-essential \
  cmake \
  curl \
  imagemagick \
  ffmpeg \
  fontconfig \
  g++ \
  git \
  haproxy \
  libffi-dev \
  libjpeg-dev \
  libjpeg62-turbo \
  libprotobuf-dev \
  libudev-dev \
  libusb-1.0-0-dev \
  libv4l-dev \
  openssh-client \
  v4l-utils \
  xz-utils \
  zlib1g-dev \
  x265

# Janus as a dpkg-registered system package, so Obico can stream live video
COPY --from=janus-builder ${JANUS_DEB} ${JANUS_DEB}
RUN apt-get install -y --no-install-recommends "${JANUS_DEB}" \
  && rm -f "${JANUS_DEB}"

# unpack s6
COPY --from=s6build /tmp /tmp
# /bin is a symlink to /usr/bin on merged-/usr releases, and extracting the
# tarball's ./bin over it replaces the symlink, so unpack ./bin into /usr
RUN s6tar=$(find /tmp -name "s6-overlay-*.tar.gz") \
  && tar xzf "$s6tar" -C / --exclude="./bin" \
  && tar xzf "$s6tar" -C /usr ./bin

# Install octoprint
RUN --mount=type=bind,source=.env,target=${BUILD_ENV_FILE} \
  . "${BUILD_ENV_FILE}" \
  && octoprint_ref="${octoprint_ref:-${OCTOPRINT_VERSION}}" \
  && test -n "${octoprint_ref}" \
  && echo "Installing OctoPrint ${octoprint_ref}" \
  && curl -fsSLO --compressed --retry 3 --retry-delay 10 \
       "https://github.com/OctoPrint/OctoPrint/archive/${octoprint_ref}.tar.gz" \
  && mkdir -p "${OCTOPRINT_SRC_DIR}" \
  && tar xzf "${octoprint_ref}.tar.gz" --strip-components 1 -C "${OCTOPRINT_SRC_DIR}" --no-same-owner

WORKDIR ${OCTOPRINT_SRC_DIR}
RUN pip install --no-cache-dir .
RUN mkdir -p /octoprint/octoprint /octoprint/plugins

# Install mjpg-streamer
RUN curl -fsSLO --compressed --retry 3 --retry-delay 10 \
  https://github.com/jacksonliam/mjpg-streamer/archive/master.tar.gz \
  && mkdir /mjpg \
  && tar xzf master.tar.gz -C /mjpg


WORKDIR /mjpg/mjpg-streamer-master/mjpg-streamer-experimental
RUN make
RUN make install

# Copy services into s6 servicedir and set default ENV vars
COPY root /
ENV CAMERA_DEV /dev/video0
ENV MJPG_STREAMER_INPUT -n -r 640x480
ENV PIP_USER true
ENV PYTHONUSERBASE /octoprint/plugins
ENV PATH "${PYTHONUSERBASE}/bin:${PATH}"
# set WORKDIR 
WORKDIR /octoprint

# port to access haproxy frontend
EXPOSE 80

VOLUME /octoprint

ENTRYPOINT ["/init"]
