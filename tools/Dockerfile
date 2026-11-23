# Only the transaction/identity adapter is built locally. Node and ICM services
# use public images; this patch never changes their consensus binaries.
FROM golang@sha256:69a7b9788769bec032d238959b61854e9ae87f57be9029ec04e9885fabf99195 AS build
WORKDIR /build
RUN git init upstream && \
    git -C upstream remote add origin https://github.com/ava-labs/avalanchego.git && \
    git -C upstream fetch --depth 1 origin 70bd6d063b7343fd2cd8217200aaf77b57f19f68 && \
    git -C upstream checkout --detach FETCH_HEAD
COPY go.mod ids.patch ./
RUN git -C upstream apply /build/ids.patch && \
    go work init . ./upstream ./upstream/graft/coreth ./upstream/graft/evm ./upstream/graft/subnet-evm && \
    go work edit -replace=google.golang.org/genproto=google.golang.org/genproto@v0.0.0-20230526161137-0005af68ea54
COPY *.go ./
RUN go test ./... && go build -trimpath -o /out/lab .

FROM debian@sha256:734a72b3d6142a71993b4bc580ca01d8ca687f77a2c422d96a961d3376b179bc
# curl and jq for the shell scripts in static_files/scripts, and for a user who
# calls a node from this container. They come from the Debian snapshot that the
# base image names in its sources, so a rebuild installs the same versions.
RUN sed -i -E '/^# http:\/\/snapshot\.debian\.org/{s/^# /URIs: /;n;d}' /etc/apt/sources.list.d/debian.sources && \
    apt-get -o Acquire::Check-Valid-Until=false update && \
    apt-get install -y --no-install-recommends curl jq && \
    rm -rf /var/lib/apt/lists/*
COPY --from=build /out/lab /usr/local/bin/lab
COPY --from=build /build/upstream/LICENSE /usr/share/licenses/avalanche-tools/LICENSE
ENTRYPOINT ["/usr/local/bin/lab"]
