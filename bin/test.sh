#! /usr/bin/env bash

set -e
# workaround for same solidity compiler version
# upgrade solidity 0.5.12 files to 0.5.15
find . -type f -name "*.sol" -print0 | xargs -0 sed -i '' -e 's/0.5.12/0.5.15/g'

dapp --use solc:0.5.15 test

