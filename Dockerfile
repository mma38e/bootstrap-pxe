FROM rockylinux:9

RUN dnf install -y --setopt=install_weak_deps=False --nodocs \
        epel-release \
        dnf-plugins-core \
 && dnf config-manager --add-repo \
        https://download.docker.com/linux/centos/docker-ce.repo \
 && dnf install -y --setopt=install_weak_deps=False --nodocs \
        xorriso \
        isomd5sum \
        createrepo_c \
        rsync \
        iptables-nft \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-compose-plugin \
        docker-buildx-plugin \
 && dnf clean all \
 && rm -rf /var/cache/dnf

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

VOLUME ["/var/lib/docker"]
WORKDIR /work

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["/work/build-iso.sh"]
