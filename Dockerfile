FROM ubuntu:26.04

ARG DEBIAN_FRONTEND=noninteractive

ENV container=docker \
    TZ=Asia/Shanghai \
    LANG=zh_CN.UTF-8 \
    LANGUAGE=zh_CN:zh \
    LC_ALL=zh_CN.UTF-8

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      systemd systemd-sysv dbus dbus-user-session udev sudo locales tzdata \
      ubuntu-desktop-minimal gdm3 gnome-terminal nautilus \
      gnome-remote-desktop gnome-keyring libpam-gnome-keyring \
      polkitd pkexec openssl \
      mesa-utils mesa-vulkan-drivers libgl1-mesa-dri \
      pipewire pipewire-audio wireplumber alsa-utils pavucontrol \
      bindfs \
      fonts-noto-cjk \
      language-pack-zh-hans language-pack-zh-hans-base \
      language-pack-gnome-zh-hans language-pack-gnome-zh-hans-base \
      ibus ibus-libpinyin \
 && locale-gen zh_CN.UTF-8 \
 && update-locale LANG=zh_CN.UTF-8 LANGUAGE=zh_CN:zh \
 && printf 'user_allow_other\n' >/etc/fuse.conf \
 && ln -snf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime \
 && echo Asia/Shanghai >/etc/timezone \
 && systemctl set-default graphical.target \
 && systemctl enable gdm3 \
 && systemctl mask getty@.service console-getty.service \
      systemd-remount-fs.service systemd-udevd.service systemd-udev-trigger.service \
      systemd-udevd-control.socket systemd-udevd-kernel.socket \
      systemd-udevd-varlink.socket tpm-udev.path tpm-udev.service \
 && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /etc/gdm3 \
 && printf '[daemon]\nWaylandEnable=true\nAutomaticLoginEnable=false\n' \
      >/etc/gdm3/custom.conf

RUN if id remote >/dev/null 2>&1; then userdel -r remote; fi

# A container must never react to the NAS power controls as if it owned the
# physical machine.  This also avoids shutdown/suspend waits in logind.
RUN mkdir -p /etc/systemd/logind.conf.d \
 && printf '%s\n' \
      '[Login]' \
      'HandlePowerKey=ignore' \
      'HandlePowerKeyLongPress=ignore' \
      'HandleRebootKey=ignore' \
      'HandleRebootKeyLongPress=ignore' \
      'HandleSuspendKey=ignore' \
      'HandleHibernateKey=ignore' \
      'HandleLidSwitch=ignore' \
      >/etc/systemd/logind.conf.d/10-container-ignore-power.conf

COPY container-entrypoint.sh /usr/local/sbin/container-entrypoint
COPY enable-desktop-sharing.sh /usr/local/sbin/enable-desktop-sharing
COPY enable-remote-login.sh /usr/local/sbin/enable-remote-login
COPY fnos-desktop-sharing.service /etc/systemd/system/fnos-desktop-sharing.service
COPY fnos-remote-login.service /etc/systemd/system/fnos-remote-login.service
COPY 99-fnos-login-screen.gschema.override /usr/share/glib-2.0/schemas/99-fnos-login-screen.gschema.override
COPY configure-tv-desktop.sh /usr/local/sbin/configure-tv-desktop
COPY waydroid-media-bridge.sh /usr/local/sbin/waydroid-media-bridge
COPY fnos-waydroid-media.service /etc/systemd/system/fnos-waydroid-media.service
COPY appliance/ /usr/local/share/fnos/
RUN chmod 0755 /usr/local/sbin/container-entrypoint \
               /usr/local/sbin/enable-desktop-sharing \
               /usr/local/sbin/enable-remote-login \
               /usr/local/sbin/configure-tv-desktop \
               /usr/local/sbin/waydroid-media-bridge \
 && chmod 0644 /etc/systemd/system/fnos-desktop-sharing.service \
               /etc/systemd/system/fnos-remote-login.service \
               /etc/systemd/system/fnos-waydroid-media.service \
 && /usr/local/sbin/configure-tv-desktop --system \
 && systemctl enable fnos-desktop-sharing.service \
                    fnos-remote-login.service \
                    gnome-remote-desktop.service

STOPSIGNAL SIGRTMIN+3
EXPOSE 3389/tcp 3390/tcp
ENTRYPOINT ["/usr/local/sbin/container-entrypoint"]
CMD ["/sbin/init"]
