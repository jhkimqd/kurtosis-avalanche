#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
root=$(pwd)
[[ "$(go version)" == *"go1.27.1 "* ]] || { echo 'Go 1.27.1 is required' >&2; exit 1; }
[[ "$(forge --version | head -1)" == *"1.8.3"* ]] || { echo 'Foundry 1.8.3 is required' >&2; exit 1; }
mkdir -p .build/bin artifacts
exec 9>.build/build.lock
flock -n 9 || { echo "Another build is active" >&2; exit 1; }
avago=${AVALANCHEGO_SOURCE:-$HOME/avax/takehome/avalanchego}
icm=${ICM_SOURCE:-$HOME/avax/takehome/icm-services}
if ! test -d "$avago/.git"; then
 avago="$root/.build/upstream-avalanchego"
 if ! test -d "$avago/.git"; then git clone https://github.com/ava-labs/avalanchego.git "$avago"; fi
fi
if ! test -e "$icm/.git"; then
 icm="$root/.build/upstream-icm"
 if ! test -d "$icm/.git"; then git clone https://github.com/ava-labs/icm-services.git "$icm"; fi
 git -C "$icm" checkout --detach 10923ff3dfa0f1bc3df3704aac8789bed1198b2a
 git -C "$icm" submodule update --init --recursive
fi
python3 scripts/export-pinned.py "$avago" 70bd6d063b7343fd2cd8217200aaf77b57f19f68 .build/avalanchego
python3 scripts/export-pinned.py "$icm" 10923ff3dfa0f1bc3df3704aac8789bed1198b2a .build/icm
python3 scripts/patch-avalanche.py .build/avalanchego
cat > .build/go.work <<WORK
go 1.27.1
use (
 $root
 $root/.build/avalanchego
 $root/.build/avalanchego/graft/coreth
 $root/.build/avalanchego/graft/evm
 $root/.build/avalanchego/graft/subnet-evm
 $root/.build/icm
)
replace google.golang.org/genproto => google.golang.org/genproto v0.0.0-20230526161137-0005af68ea54
WORK
export GOWORK="$root/.build/go.work"
go mod edit -modfile=.build/icm/go.mod -dropreplace=github.com/ava-labs/avalanchego -dropreplace=github.com/ava-labs/avalanchego/graft/coreth -dropreplace=github.com/ava-labs/avalanchego/graft/evm -dropreplace=github.com/ava-labs/avalanchego/graft/subnet-evm
go build -trimpath -o .build/bin/lab ./cmd/lab
go build -trimpath -o .build/bin/avalanchego ./.build/avalanchego/main
go build -trimpath -o .build/bin/subnet-evm ./.build/avalanchego/graft/subnet-evm/plugin
go build -trimpath -o .build/bin/signature-aggregator ./.build/icm/signature-aggregator/main
go build -trimpath -o .build/bin/icm-relayer ./.build/icm/relayer
cat >> .build/icm/remappings.txt <<'MAP'
@openzeppelin/contracts/=lib/openzeppelin-contracts-upgradeable/lib/openzeppelin-contracts/contracts/
@openzeppelin/contracts-upgradeable/=lib/openzeppelin-contracts-upgradeable/contracts/
MAP
forge build --root .build/icm --skip test --skip script > artifacts/contract-build.log 2>&1
forge build --root contracts > artifacts/fixture-build.log 2>&1
python3 scripts/export-contracts.py
docker build -f docker/Dockerfile -t avalanche-lab:local .
sha256sum .build/bin/* > artifacts/binaries.sha256
docker image inspect avalanche-lab:local --format '{{.Id}}' > artifacts/image-id.txt
