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

interface DROPMemberList {
    function updateMember(address, uint) external;
}

contract TinlakeMkrTest is LenderSystemTest {
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
        spotter.file(ilk, "mat", 110 * RAY / 100);

        // Update DROP spot value in Vat
        //spotter.poke(ilk);
        // price with safety margin
        uint spot =  110 * RAY / 100;
        vat.file(ilk, "spot", spot);
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

        // accept mgr with Tinlake in MKR
        spellTinlake();

        // depend mgr in Tinlake clerk
        clerk.depend("mgr", address(mgr));
        // depend mgr in Tinlake clerk
        clerk.depend("spotter", address(spotter));
        clerk.depend("vat", address(vat));

        // give testcase the right to modify drop token holders
        root.relyContract(address(seniorMemberlist), address(this));
        // add mgr as drop token holder
        seniorMemberlist.updateMember(address(mgr), uint(-1));
    }

}
