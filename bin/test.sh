#! /usr/bin/env bash

set -e
# workaround for same solidity compiler version
# change compiler solidity version from 0.5.12 to 0.5.15
egrep -lRZ '0.5.12' . | xargs -0 -l sed -i -e 's/0.5.12/0.5.15/g'

dapp --use solc:0.5.15 test

