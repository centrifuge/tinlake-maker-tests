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
contract TinlakeMakerBasicTest is MKRBasicSystemTest, MKRLenderSystemTest {
    // Decimals & precision
    uint256 constant MILLION  = 10 ** 6;
    uint256 constant RAY      = 10 ** 27;
    uint256 constant RAD      = 10 ** 45;

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
        uint mat =  110 * RAY / 100;
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
        vat.fold(ilk, address(vow), int(newRateIndex-prevRateIndex));
    }

    function setStabilityFee(uint fee) public {
        stabilityFee = fee;
    }

    function makerEvent(bytes32 name, bool) public {
        if(name == "live") {
            // Global settlement not triggered
            mgr.cage();
        } else if(name == "glad") {
            // Write-off not triggered
            mgr.tell();
            mgr.sink();
        } else if(name  == "safe") {
            // Soft liquidation not triggered
            mgr.tell();
        }
    }

    function warp(uint plusTime) public {
        if (warpCalled == false)  {
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
        seniorMemberlist.updateMember(address(mgr), uint(-1));
    }
}
