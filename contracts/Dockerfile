# Developer-only compiler image. Foundry v1.8.3, pinned by digest.
FROM ghcr.io/foundry-rs/foundry:v1.8.3@sha256:2e4287278639262de76db72477301d5d3212fa1b1cce710d7d148750a46ce9e7
USER root
RUN apt-get update && apt-get install -y --no-install-recommends python3 \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /build
# Fetch exactly the recorded upstream revision and its recorded submodules.
RUN git init .build/icm \
    && git -C .build/icm remote add origin https://github.com/ava-labs/icm-services.git \
    && git -C .build/icm fetch --depth 1 origin 10923ff3dfa0f1bc3df3704aac8789bed1198b2a \
    && git -C .build/icm checkout --detach FETCH_HEAD \
    && git -C .build/icm submodule update --init --recursive --depth 1
# Preserve the original build's OpenZeppelin aliases. All other settings come
# from the pinned upstream foundry.toml (solc 0.8.30, Shanghai, optimizer 200,
# bytecode_hash=none); local contracts use the checked-in configuration below.
RUN printf '\n%s\n%s\n' \
    '@openzeppelin/contracts/=lib/openzeppelin-contracts-upgradeable/lib/openzeppelin-contracts/contracts/' \
    '@openzeppelin/contracts-upgradeable/=lib/openzeppelin-contracts-upgradeable/contracts/' \
    >> .build/icm/remappings.txt \
    && forge build --root .build/icm --skip test --skip script
COPY contracts/foundry.toml contracts/foundry.toml
COPY contracts/src/ contracts/src/
# The committed local artifacts were compiled separately (each source has ID 0).
# Keep that compilation unit boundary: exported bytecode includes source maps.
RUN cd contracts && for source in src/*.sol; do forge build "$source" || exit 1; done
COPY scripts/export-contracts.py scripts/export-contracts.py
RUN python3 scripts/export-contracts.py
ENTRYPOINT ["tar", "-C", "/build/static_files/contracts", "-cf", "-", "."]
