FROM golang@sha256:69a7b9788769bec032d238959b61854e9ae87f57be9029ec04e9885fabf99195
COPY .build/bin/lab /usr/local/bin/lab
COPY .build/bin/avalanchego /usr/local/bin/avalanchego
COPY .build/bin/subnet-evm /opt/avalanche/plugins/srEXiWaHuhNyGwPUi444Tu47ZEDwxTWrbQiuD7FmgSAQ6X7Dy
COPY .build/bin/signature-aggregator /usr/local/bin/signature-aggregator
COPY .build/bin/icm-relayer /usr/local/bin/icm-relayer
COPY licenses /usr/share/licenses/avalanche-lab
ENTRYPOINT ["/usr/local/bin/lab"]
