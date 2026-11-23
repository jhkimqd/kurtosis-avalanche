# The tools service: existing command-line tools, no code of this package.
#
#   avalanchego    generates node identities (static_files/scripts/network.sh)
#   platform-cli   signs and sends P-Chain transactions
#   cast           signs and sends EVM transactions, ABI encoding
#   curl, jq       JSON-RPC calls and JSON files
#
# The setup scripts that call them live in static_files/scripts and are
# mounted at run time, so a change to a script needs no rebuild.
#
# Debian 13: the platform-cli release needs glibc 2.38 or later.
FROM debian@sha256:a72b4433de1cf7d6bae0c4cee74d0547f58601a643b3375f070c51600d63b6b2

# The AvalancheGo binary of the node image, at the same digest as
# IMAGES["avalanchego"] in src/config/constants.star (a test compares them).
COPY --from=avaplatform/avalanchego@sha256:5181093d02d2a201e890f714f8b9ebb9677de9fd6155e9c391214f3918b41710 \
    /avalanchego/build/avalanchego /avalanchego/build/avalanchego

# curl and jq come from the Debian snapshot that the base image names in its
# sources, so a rebuild installs the same versions.
RUN sed -i -E '/^# http:\/\/snapshot\.debian\.org/{s/^# /URIs: /;n;d}' /etc/apt/sources.list.d/debian.sources && \
    apt-get -o Acquire::Check-Valid-Until=false update && \
    apt-get install -y --no-install-recommends ca-certificates curl jq && \
    rm -rf /var/lib/apt/lists/*

# Release archives, pinned by version and SHA-256 for each architecture.
ARG PLATFORM_CLI_VERSION=2.4.0
ARG PLATFORM_CLI_SHA256_AMD64=c6fe20838ab553f87a42a307d5174ca5e74dbe9a6ff81dca9ea2a34c4ad20cb6
ARG PLATFORM_CLI_SHA256_ARM64=ac7ad46f383662786338eaf786386b056ed5cd4f854438bc13b3a482562abbd4
ARG FOUNDRY_VERSION=v1.8.3
ARG FOUNDRY_SHA256_AMD64=7ca48e6ca3cac1bce1403ca67e5bc1dc3bc1fd818199c9957c7165079c228568
ARG FOUNDRY_SHA256_ARM64=93fc23be26c8a902ca58fe54aa6ca28c880b58af95d052674933161df7928e6d
RUN set -eu; \
    arch=$(dpkg --print-architecture); \
    case "$arch" in \
      amd64) platform_sum=$PLATFORM_CLI_SHA256_AMD64; foundry_sum=$FOUNDRY_SHA256_AMD64 ;; \
      arm64) platform_sum=$PLATFORM_CLI_SHA256_ARM64; foundry_sum=$FOUNDRY_SHA256_ARM64 ;; \
      *) echo "unsupported architecture $arch" >&2; exit 1 ;; \
    esac; \
    cd /tmp; \
    curl -fsSLo platform-cli.tar.gz "https://github.com/ava-labs/platform-cli/releases/download/v${PLATFORM_CLI_VERSION}/platform-cli_${PLATFORM_CLI_VERSION}_linux_${arch}.tar.gz"; \
    echo "$platform_sum  platform-cli.tar.gz" | sha256sum -c -; \
    tar -xzf platform-cli.tar.gz platform; \
    install -m 0755 platform /usr/local/bin/platform-cli; \
    curl -fsSLo foundry.tar.gz "https://github.com/foundry-rs/foundry/releases/download/${FOUNDRY_VERSION}/foundry_${FOUNDRY_VERSION}_linux_${arch}.tar.gz"; \
    echo "$foundry_sum  foundry.tar.gz" | sha256sum -c -; \
    tar -xzf foundry.tar.gz cast; \
    install -m 0755 cast /usr/local/bin/cast; \
    rm -f platform-cli.tar.gz platform foundry.tar.gz cast; \
    platform-cli version; cast --version

ENTRYPOINT []
CMD ["sleep", "infinity"]
