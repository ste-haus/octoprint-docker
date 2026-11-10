ARG PYTHON_VERSION=3.10
ARG DEBIAN_RELEASE=bullseye
ARG PYTHON_BASE_IMAGE=${PYTHON_VERSION}-slim-${DEBIAN_RELEASE}

# Obico's bundled Janus is 0.11.x and its generated streaming config uses the
# legacy (pre-multistream) syntax, so stay on the 0.x line.
ARG JANUS_VERSION=0.16.3
ARG JANUS_REPO=https://github.com/meetecho/janus-gateway.git
ARG JANUS_PREFIX=/usr
ARG JANUS_DEB=/tmp/janus.deb

# Bullseye is EOL: its security pool has moved to the archive while
# deb.debian.org still advertises it, so fetch everything from the archive.
ARG DEBIAN_ARCHIVE_MIRROR=http://archive.debian.org
ARG APT_SOURCES_FILE=/etc/apt/sources.list

FROM ubuntu AS s6build
ARG S6_RELEASE
ENV S6_VERSION ${S6_RELEASE:-v2.1.0.0}
RUN apt-get update && apt-get install -y curl
RUN echo "$(dpkg --print-architecture)"
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

ARG DEBIAN_RELEASE
ARG DEBIAN_ARCHIVE_MIRROR
ARG APT_SOURCES_FILE
ARG JANUS_VERSION
ARG JANUS_REPO
ARG JANUS_PREFIX
ARG JANUS_DEB

ARG JANUS_SRC_DIR=/tmp/janus-src
ARG JANUS_STAGING_DIR=/tmp/janus-root

RUN printf '%s\n' \
      "deb ${DEBIAN_ARCHIVE_MIRROR}/debian ${DEBIAN_RELEASE} main" \
      "deb ${DEBIAN_ARCHIVE_MIRROR}/debian ${DEBIAN_RELEASE}-updates main" \
      "deb ${DEBIAN_ARCHIVE_MIRROR}/debian-security ${DEBIAN_RELEASE}-security main" \
      > "${APT_SOURCES_FILE}"

RUN apt-get update && apt-get install -y --no-install-recommends \
      autoconf \
      automake \
      ca-certificates \
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

# Depends lists the runtime libraries so apt pulls them into the final image
RUN mkdir -p "${JANUS_STAGING_DIR}/DEBIAN" \
    && printf '%s\n' \
         "Package: janus" \
         "Version: ${JANUS_VERSION}" \
         "Architecture: $(dpkg --print-architecture)" \
         "Maintainer: ste.haus" \
         "Depends: libconfig9, libcurl4, libglib2.0-0, libjansson4, libnice10, libsrtp2-1, libssl1.1, libusrsctp1, libwebsockets16, zlib1g" \
         "Description: Janus WebRTC gateway, local build for the Obico plugin" \
         > "${JANUS_STAGING_DIR}/DEBIAN/control" \
    && dpkg-deb --build "${JANUS_STAGING_DIR}" "${JANUS_DEB}"


FROM python:${PYTHON_BASE_IMAGE} AS build

ARG DEBIAN_RELEASE
ARG DEBIAN_ARCHIVE_MIRROR
ARG APT_SOURCES_FILE
ARG JANUS_DEB

ARG octoprint_ref
ENV octoprint_ref ${octoprint_ref:-master}

RUN printf '%s\n' \
      "deb ${DEBIAN_ARCHIVE_MIRROR}/debian ${DEBIAN_RELEASE} main" \
      "deb ${DEBIAN_ARCHIVE_MIRROR}/debian ${DEBIAN_RELEASE}-updates main" \
      "deb ${DEBIAN_ARCHIVE_MIRROR}/debian-security ${DEBIAN_RELEASE}-security main" \
      > "${APT_SOURCES_FILE}"

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
RUN s6tar=$(find /tmp -name "s6-overlay-*.tar.gz") \
  && tar xzf $s6tar -C / 

# Install octoprint
RUN	curl -fsSLO --compressed --retry 3 --retry-delay 10 \
  https://github.com/OctoPrint/OctoPrint/archive/${octoprint_ref}.tar.gz \
	&& mkdir -p /opt/octoprint \
  && tar xzf ${octoprint_ref}.tar.gz --strip-components 1 -C /opt/octoprint --no-same-owner

WORKDIR /opt/octoprint
RUN pip install .
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
