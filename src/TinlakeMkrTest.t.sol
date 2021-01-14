pragma solidity ^0.5.15;

import "ds-test/test.sol";

import "./TinlakeMkrTest.sol";

contract TinlakeMkrTestTest is DSTest {
    TinlakeMkrTest test;

    function setUp() public {
        test = new TinlakeMkrTest();
    }

    function testFail_basic_sanity() public {
        assertTrue(false);
    }

    function test_basic_sanity() public {
        assertTrue(true);
    }
}
