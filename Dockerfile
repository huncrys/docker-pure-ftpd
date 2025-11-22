# syntax=docker/dockerfile:1

FROM --platform=${BUILDPLATFORM} tonistiigi/xx:1.8.0@sha256:add602d55daca18914838a78221f6bbe4284114b452c86a48f96d59aeb00f5c6 AS xx
FROM --platform=${BUILDPLATFORM} lsiobase/alpine:3.22@sha256:0c6f0f369af665f8f01c22150000c8f15b26772954fc4abeda461171298205b1 AS base
FROM base AS src
COPY --from=xx / /
RUN apk --update --no-cache add patch
WORKDIR /src/pure-ftpd

# renovate: datasource=github-releases depName=jedisct1/pure-ftpd
ARG PUREFTPD_VERSION=1.0.52
ADD https://github.com/jedisct1/pure-ftpd.git#${PUREFTPD_VERSION} .

COPY patchs /src
RUN patch -p1 < ../minimal.patch

FROM base AS builder
COPY --from=xx / /
RUN apk --update --no-cache add autoconf automake binutils clang file make pkgconf tar xz
ENV XX_CC_PREFER_LINKER=ld
ARG TARGETPLATFORM
RUN xx-apk --no-cache --update add \
    gcc \
    linux-headers \
    musl-dev \
    libsodium-dev \
    mariadb-connector-c-dev \
    openldap-dev \
    postgresql-dev \
    openssl-dev
WORKDIR /src
COPY --from=src /src/pure-ftpd /src
RUN <<EOT
  echo "**** compile pure-ftpd ****"
  set -ex
  ./autogen.sh
  CC=xx-clang ./configure \
    --sysconfdir=/config/pure-ftpd \
    --host=$(xx-clang --print-target-triple) \
    --prefix=/out \
    --without-ascii \
    --without-humor \
    --without-inetd \
    --without-pam \
    --with-altlog \
    --with-cookie \
    --with-ftpwho \
    --with-ldap \
    --with-mysql \
    --with-pgsql \
    --with-puredb \
    --with-quotas \
    --with-ratios \
    --with-throttling \
    --with-tls \
    --with-uploadscript \
    --with-brokenrealpath \
    --with-certfile=/config/keys/pure-ftpd.pem
  make install-strip
EOT

RUN \
  echo "**** verify binaries ****" && \
  ls -lR /out && \
  xx-verify \
    /out/bin/* \
    /out/sbin/*

RUN \
  echo "**** create files ****" && \
  mkdir -p /rootfs && \
  mv /out /rootfs/usr && \
  mkdir -p /rootfs/etc/ssl/private && \
  ln -sf "/config/pure-ftpd/dhparams.pem" "/rootfs/etc/ssl/private/pure-ftpd-dhparams.pem"

RUN \
  echo "**** determine runtime packages ****" && \
  scanelf --needed --nobanner /rootfs/usr/bin/pure-* /rootfs/usr/sbin/pure-* \
    | awk '{ gsub(/,/, "\nso:", $2); print "so:" $2 }' \
    | sort -u \
    | xargs -r apk info --installed \
    | sort -u \
    >> /rootfs/packages

FROM base

COPY --from=builder /rootfs/ /

RUN \
  echo "**** install runtime packages ****" && \
  RUNTIME_PACKAGES=$(echo $(cat /packages)) && \
  apk -U --update --no-cache add \
    ${RUNTIME_PACKAGES} \
    logrotate \
    openssl && \
  echo "**** fix logrotate ****" && \
  sed -i "s#/var/log/messages {}.*# #g" \
    /etc/logrotate.conf && \
  sed -i 's#/usr/sbin/logrotate /etc/logrotate.conf#/usr/sbin/logrotate /etc/logrotate.conf -s /config/log/logrotate.status#g' \
    /etc/periodic/daily/logrotate && \
  echo "**** cleanup ****" && \
  rm -rf \
    /etc/s6-overlay/s6-rc.d/init-adduser \
    /etc/s6-overlay/s6-rc.d/init-device-perms/dependencies.d/init-adduser \
    /etc/s6-overlay/s6-rc.d/init-os-end/dependencies.d/init-adduser \
    /etc/s6-overlay/s6-rc.d/user/contents.d/init-adduser

# copy local files
COPY root/ /

EXPOSE 2100 30000-30009
VOLUME /config
