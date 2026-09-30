#!/bin/zsh
set -euo pipefail

cd "${0:A:h:h}"
mkdir -p build
node --test Tests/*.test.js
clang -fobjc-arc -mmacosx-version-min=14.0 -Wall -framework Foundation \
    Tests/AccountTests.m Sources/Account.m Sources/SubscriptionParser.m -o build/account-tests
build/account-tests
