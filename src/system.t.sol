// Copyright (C) 2021 Centrifuge

// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

pragma solidity >=0.5.15 <0.6.0;
pragma experimental ABIEncoderV2;

import "ds-test/test.sol";
import "tinlake/test/system/lender/mkr/mkr_basic.t.sol";
import "tinlake/test/system/lender/mkr/mkr_scenarios.t.sol";
import "tinlake/test/mock/mock.sol";
import "tinlake-maker-lib/mgr.sol";
import "dss/vat.sol";
import {DaiJoin} from "dss/join.sol";
import {Spotter} from "dss/spot.sol";

import "../lib/tinlake-maker-lib/src/mgr.sol";

contract VowMock is Mock {
    function fess(uint256 tab) public {
        values_uint["fess_tab"] = tab;
    }
}

// executes all mkr tests from the Tinlake repo with the mgr and Maker contracts
contract TinlakeMakerTests is MKRBasicSystemTest, MKRLenderSystemTest {
    // Decimals & precision
    uint256 constant MILLION = 10 ** 6;
    uint256 constant RAY = 10 ** 27;
    uint256 constant RAD = 10 ** 45;

    TinlakeManager public mgr;
    Vat public vat;
    Spotter public spotter;
    DaiJoin public daiJoin;
    VowMock vow;
    bytes32 ilk;

    uint lastRateUpdate;
    uint stabilityFee;

    bool warpCalled = false;

    function setUp() public {
        // setup Tinlake contracts with mocked maker adapter
        super.setUp();
        // replace mocked maker adapter with maker and adapter
        setUpMgrAndMaker();
    }

    function spellTinlake() public {
        vat.init(ilk);

        vat.rely(address(mgr));
        daiJoin.rely(address(mgr));

        // Set the global debt ceiling
        vat.file("Line", 1_468_750_000 * RAD);
        // Set the NS2DRP-A debt ceiling
        vat.file(ilk, "line", 5 * MILLION * RAD);
        // Set the NS2DRP-A dust
        vat.file(ilk, "dust", 0);

        //tinlake system tests work with 110%
        uint mat = 110 * RAY / 100;
        spotter.file(ilk, "mat", mat);

        // Update DROP spot value in Vat
        //spotter.poke(ilk);
        // assume a constant price with safety margin
        uint spot = mat;
        vat.file(ilk, "spot", spot);
        lastRateUpdate = now;
    }

    // updates the interest rate in maker contracts
    function dripMakerDebt() public {
        (,uint prevRateIndex,,,) = vat.ilks(ilk);
        uint newRateIndex = rmul(rpow(stabilityFee, now - lastRateUpdate, ONE), prevRateIndex);
        lastRateUpdate = now;
        (uint ink, uint art) = vat.urns(ilk, address(mgr));
        vat.fold(ilk, address(daiJoin), int(newRateIndex - prevRateIndex));
    }

    function setStabilityFee(uint fee) public {
        stabilityFee = fee;
    }

    function makerEvent(bytes32 name, bool) public {
        if (name == "live") {
            // Global settlement not triggered
            mgr.cage();
        } else if (name == "glad") {
            // Write-off not triggered
            mgr.tell();
            mgr.sink();
        } else if (name == "safe") {
            // Soft liquidation not triggered
            mgr.tell();
        }
    }

    function warp(uint plusTime) public {
        if (warpCalled == false) {
            warpCalled = true;
            // init maker rate update mock
            lastRateUpdate = now;
        }
        hevm.warp(now + plusTime);
        // maker debt should be always up to date
        dripMakerDebt();
    }

    // creates all relevant mkr contracts to test the mgr
    function mkrDeploy() public {
        vat = new Vat();
        daiJoin = new DaiJoin(address(vat), currency_);
        vow = new VowMock();
        ilk = "DROP";
        vat.rely(address(daiJoin));
        spotter = new Spotter(address(vat));
        vat.rely(address(spotter));
    }

    function setUpMgrAndMaker() public {
        mkrDeploy();

        // create mgr contract
        mgr = new TinlakeManager(address(vat), currency_, address(daiJoin), address(vow), address(seniorToken),
            address(seniorOperator), address(clerk), address(seniorTranche), ilk);

        // accept Tinlake MGR in Maker
        spellTinlake();

        // depend mgr in Tinlake clerk
        clerk.depend("mgr", address(mgr));

        // depend Maker contracts in clerk
        clerk.depend("spotter", address(spotter));
        clerk.depend("vat", address(vat));

        // give testcase the right to modify drop token holders
        root.relyContract(address(seniorMemberlist), address(this));
        // add mgr as drop token holder
        seniorMemberlist.updateMember(address(mgr), uint(- 1));
    }

    function _setupUnderwaterTinlake() public {
        uint fee = 1000000564701133626865910626;
        // 5% per day
        setStabilityFee(fee);
        uint juniorAmount = 200 ether;
        uint mkrAmount = 300 ether;
        uint borrowAmount = 250 ether;
        uint firstLoan = 1;
        _setUpDraw(mkrAmount, juniorAmount, borrowAmount);
        // second loan same ammount
        uint secondLoan = setupOngoingDefaultLoan(borrowAmount);
        warp(1 days);
        // repay small amount of loan debt
        uint repayAmount = 5 ether;
        repayDefaultLoan(repayAmount);

        // nav will be zero because loan is overdue
        warp(5 days);
        // write 40% of debt off / second loan 100% loss
        root.relyContract(address(pile), address(this));
        pile.changeRate(firstLoan, nftFeed.WRITE_OFF_PHASE_A());

        assertTrue(mkrAssessor.calcSeniorTokenPrice() > 0);

        // junior lost everything
        assertEq(mkrAssessor.calcJuniorTokenPrice(), 0);
    }

    function _executeEpoch(uint dropRedeem) public {
        warp(1 days);

        // close epoch
        coordinator.closeEpoch();
        coordinator.submitSolution(dropRedeem, 0, 0, 0);

        warp(1 hours);
        coordinator.executeEpoch();
    }

    function testSoftLiquidation() public {
        uint fee = 1000000564701133626865910626;
        // 5% per day
        setStabilityFee(fee);
        uint juniorAmount = 200 ether;
        uint mkrAmount = 300 ether;
        uint borrowAmount = 250 ether;
        uint firstLoan = 1;
        _setUpDraw(mkrAmount, juniorAmount, borrowAmount);
        // second loan same ammount
        uint secondLoan = setupOngoingDefaultLoan(borrowAmount);
        warp(1 days);
        // repay small amount of loan debt
        uint repayAmount = 5 ether;
        repayDefaultLoan(repayAmount);

        warp(1 days);

        // system is in a healthy state
        assertTrue(mkrAssessor.calcSeniorTokenPrice() > ONE);

        // trigger soft liquidation
        mgr.tell();

        warp(1 days);

        // bring some currency into the reserve
        repayAmount = 10 ether;
        repayDefaultLoan(repayAmount);

        _executeEpoch(repayAmount);

        assertEqTol(currency.balanceOf(address(seniorTranche)), repayAmount, "testSoftLiquidation#1");

        uint debt = clerk.debt();

        mgr.unwind(coordinator.lastEpochExecuted());
        // no currency in the reserve
        assertEq(reserve.totalBalance(), 0);
        assertEqTol(clerk.debt(), debt-repayAmount, "testSoftLiquidation#2");
    }

    function testSoftLiquidationUnderwater() public {
        _setupUnderwaterTinlake();

        // vault under water
        assertTrue(clerk.debt() > clerk.cdpink());

        // trigger soft liquidation
        mgr.tell();

        // bring some currency into the reserve
        uint repayAmount = 10 ether;
        repayDefaultLoan(repayAmount);

        _executeEpoch(repayAmount);

        uint debt = clerk.debt();

        assertEqTol(currency.balanceOf(address(seniorTranche)), repayAmount, "unwind#1");
        assertTrue(coordinator.submissionPeriod() == false);

        mgr.unwind(coordinator.lastEpochExecuted());

        assertEqTol(reserve.totalBalance(), 0, "unwind#2");
        assertEqTol(clerk.debt(), debt-repayAmount, "unwind#3");
    }

    function testWriteOff() public {
        testSoftLiquidationUnderwater();
        uint preDebt = clerk.debt();

        assertTrue(preDebt > 0);

        // write off
        mgr.sink();
        uint tab = mgr.tab();
        assertEq(preDebt, tab/ONE);

        uint debt = clerk.debt();
        assertEq(debt, 0);

        // bring some currency into the reserve
        uint repayAmount = 13 ether;
        repayDefaultLoan(repayAmount);

        _executeEpoch(repayAmount);

        mgr.recover(coordinator.lastEpochExecuted());
        assertEq(reserve.totalBalance(), 0);
        assertEq(mgr.tab(), tab-repayAmount);
    }

    function testGlobalSettlement() public {
        // 5% per day
        uint fee = 1000000564701133626865910626;
        setStabilityFee(fee);
        uint juniorAmount = 200 ether;
        uint mkrAmount = 300 ether;
        uint borrowAmount = 250 ether;
        _setUpDraw(mkrAmount, juniorAmount, borrowAmount);

        assertEq(clerk.debt(), borrowAmount-juniorAmount);

        // trigger global settlement
        mgr.cage();

        mgr.tell();

        warp(1 days);

        // bring some currency into the reserve
        uint repayAmount = 10 ether;
        repayDefaultLoan(repayAmount);

        _executeEpoch(repayAmount);

        clerk.changeOwnerMgr(address(this));

        //tab = dai written off
        uint tab = mgr.tab();
        mgr.recover(coordinator.lastEpochExecuted());

        assertEq(reserve.totalBalance(), 0);
        assertEqTol(tab/ONE-repayAmount, mgr.tab()/ONE, "testGlobalSettlement#1");
    }
}
