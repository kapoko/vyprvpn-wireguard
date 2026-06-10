FROM alpine:3.20

ARG TARGETARCH
ARG VYPR_ARTICLE_URL="https://support.vyprvpn.com/hc/en-us/articles/43750934530317-VyprVPN-WireGuard-Go-Client-Setup"

# Current VyprVPN support article values as of 2026-06-10:
# x86_64 v0.2.2 SHA256: B882EAF0A5C8042E962DC8CBD4C0F35AE03500D329B4B10EEF13C340DF8951CA
# arm64  v0.2.2 SHA256: 2B861806A5FF8EAB370951A2EB134E702F89BB5B04386F686344319718E8C706
ARG VYPR_X86_64_URL="https://support.vyprvpn.com/hc/article_attachments/44520639682445"
ARG VYPR_ARM64_URL="https://support.vyprvpn.com/hc/article_attachments/44514697251213"
ARG VYPR_X86_64_SHA256="b882eaf0a5c8042e962dc8cbd4c0f35ae03500d329b4b10eef13c340df8951ca"
ARG VYPR_ARM64_SHA256="2b861806a5ff8eab370951a2eb134e702f89bb5b04386f686344319718e8c706"

RUN apk add --no-cache \
    bash \
    ca-certificates \
    curl \
    iproute2 \
    iptables \
    wireguard-tools \
    openresolv \
    bind-tools \
    tini

RUN set -eux; \
    case "${TARGETARCH:-amd64}" in \
      amd64) url="$VYPR_X86_64_URL"; sha="$VYPR_X86_64_SHA256" ;; \
      arm64) url="$VYPR_ARM64_URL"; sha="$VYPR_ARM64_SHA256" ;; \
      *) echo "Unsupported architecture: ${TARGETARCH:-unknown}" >&2; exit 1 ;; \
    esac; \
    curl -fL "$url" -o /tmp/vypr-download; \
    echo "${sha}  /tmp/vypr-download" | sha256sum -c -; \
    mv /tmp/vypr-download /usr/local/bin/vyprvpn-wireguard-go; \
    chmod 755 /usr/local/bin/vyprvpn-wireguard-go

COPY entrypoint.sh /entrypoint.sh
COPY healthcheck.sh /healthcheck.sh
RUN chmod +x /entrypoint.sh /healthcheck.sh

HEALTHCHECK --interval=30s --timeout=15s --start-period=60s --retries=3 CMD /healthcheck.sh

ENTRYPOINT ["/sbin/tini", "--", "/entrypoint.sh"]
