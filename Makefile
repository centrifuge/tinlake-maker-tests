all    :; dapp build
clean  :; dapp clean
update:
	dapp update
test: update
	./bin/test.sh
deploy :; dapp create TinlakeMakerTests

export DAPP_TEST_TIMESTAMP=1234567
export DAPP_SOLC_VERSION=0.5.15
