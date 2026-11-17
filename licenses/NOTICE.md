# Dependency notices

The generated validator-manager and messaging artifacts in `fixtures/contracts` derive from Ava Labs ICM Services revision `10923ff3dfa0f1bc3df3704aac8789bed1198b2a`. Their Ecosystem License is reproduced in `ICM-Ecosystem.txt`. Use is restricted by that license; this package exercises non-production local research and testing.

AvalancheGo and its EVM plugin are built from revision `70bd6d063b7343fd2cd8217200aaf77b57f19f68`, with the explicit ID-decoder patch in `scripts/patch-avalanche.py`. Its license is reproduced in `AvalancheGo.txt`. The build retains upstream source and dependency license files in the private build directory.

The authored institutional Solidity fixtures declare MIT licensing. Their asset accounting is synthetic. The cross-chain fixture demonstrates authenticated escrow decisions and destination accounting credits, not a redeemable bridge or cross-chain DvP product.
