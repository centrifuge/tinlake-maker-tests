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
import { Dai } from "dss/dai.sol";
import { Vat } from "dss/vat.sol";
import { Jug } from 'dss/jug.sol';
import { Spotter } from "dss/spot.sol";

import { RwaToken } from "rwa-example/RwaToken.sol";
import { RwaUrn } from "rwa-example/RwaUrn.sol";
import { RwaLiquidationOracle } from "rwa-example/RwaLiquidationOracle.sol";
import { DaiJoin } from 'dss/join.sol';
import { AuthGemJoin } from "dss-gem-joins/join-auth.sol";
import "dss/vat.sol";
import {DaiJoin, GemJoin} from "dss/join.sol";
import {Spotter} from "dss/spot.sol";

import "../lib/tinlake-maker-lib/src/mgr.sol";
import "ds-token/token.sol";

contract VowMock is Mock {
    function fess(uint256 tab) public {
        values_uint["fess_tab"] = tab;
    }
}

contract EndMock is Mock, Auth {
    mapping (bytes32 => int) public values_int;

    constructor() public {
        wards[msg.sender] = 1;
    }

    function debt() external returns (uint) {
        return values_uint["debt"];
    }

    // unit test helpers
    function setDebt(uint debt) external {
        values_uint["debt"] = debt;
    }

}

// executes all mkr tests from the Tinlake repo with the mgr and Maker contracts
contract TinlakeMakerTests is MKRBasicSystemTest, MKRLenderSystemTest {
    // Decimals & precision
    uint256 constant MILLION = 10 ** 6;
    uint256 constant WAD = 10 ** 18;
    uint256 constant RAY = 10 ** 27;
    uint256 constant RAD = 10 ** 45;

    function rad(uint wad) internal pure returns (uint) {
        return wad * 10 ** 27;
    }

    //rounds to zero if x*y < WAD / 2
    function wmul(uint x, uint y) internal pure returns (uint z) {
        z = safeAdd(safeMul(x, y), WAD / 2) / WAD;
    }

    TinlakeManager public mgr;
    address public mgr_;

    address public self;

    // Maker
    DaiJoin daiJoin;
    EndMock end;
    DSToken dai;
    Vat vat;
    DSToken gov;
    RwaToken rwa;
    AuthGemJoin gemJoin;
    RwaUrn urn;
    RwaLiquidationOracle oracle;
    Jug jug;
    Spotter spotter;

    uint lastRateUpdate;
    uint stabilityFee;

    bool warpCalled = false;

    address daiJoin_;
    address gemJoin_;
    address dai_;
    address vow = address(123);
    address end_;
    address urn_;
    bytes32 public constant ilk = "DROP";

    // -- testing --
    uint256 rate;
    uint256 ceiling = 400 ether;
    string doc = "Please sign on the dotted line.";

    // dummy weth collateral
    GemJoin ethJoin;
    SimpleToken weth;

function setUp() public {
        // setup Tinlake contracts with mocked maker adapter
        super.setUp();
        // replace mocked maker adapter with maker and adapter
        setUpMgrAndMakerMIP21();
    }

    function setUpMgrAndMakerMIP21() public {
        self = address(this);

        end = new EndMock();
        end_ = address(end);

        // deploy governance token
        gov = new DSToken('GOV');
        gov.mint(100 ether);

        // deploy rwa token
        rwa = new RwaToken();

        // standard Vat setup
        vat = new Vat();

        jug = new Jug(address(vat));
        jug.file("vow", address(vow));
        vat.rely(address(jug));

        spotter = new Spotter(address(vat));
        vat.rely(address(spotter));

        daiJoin = new DaiJoin(address(vat), address(currency));
        daiJoin_ = address(daiJoin);
        vat.rely(address(daiJoin));
        currency.rely(address(daiJoin));

        vat.init(ilk);
        vat.file("Line", 100 * rad(ceiling));
        vat.file(ilk, "line", rad(ceiling));

        jug.init(ilk);
        // $ bc -l <<< 'scale=27; e( l(1.08)/(60 * 60 * 24 * 365) )'
        uint256 EIGHT_PCT = 1000000002440418608258400030;
        jug.file(ilk, "duty", EIGHT_PCT);

        oracle = new RwaLiquidationOracle(address(vat), vow);
        oracle.init(
            ilk,
            wmul(ceiling, 1.1 ether),
            doc,
            2 weeks);
        vat.rely(address(oracle));
        (,address pip,,) = oracle.ilks(ilk);

        spotter.file(ilk, "mat", RAY);
        spotter.file(ilk, "pip", pip);
        spotter.poke(ilk);

        gemJoin = new AuthGemJoin(address(vat), ilk, address(rwa));
        gemJoin_ = address(gemJoin);
        vat.rely(gemJoin_);


        mgr = new TinlakeManager(address(currency)  ,
            daiJoin_,
            address(seniorToken), // DROP token
            address(seniorOperator), // senior operator
            address(seniorTranche), // senior tranche
            end_,
            address(vat), address(vow));

        mgr_ = address(mgr);
        mgr.file("owner",   address(seniorTranche));

        urn = new RwaUrn(address(vat), address(jug), address(gemJoin), address(daiJoin), mgr_);
        urn_ = address(urn);
        gemJoin.rely(address(urn));

        // fund mgr with rwa
        rwa.transfer(mgr_, 1 ether);
        assertEq(rwa.balanceOf(mgr_), 1 ether);

        // auth user to operate
        urn.hope(mgr_);
        mgr.file("urn", address(urn));
        mgr.file("liq", address(oracle));

        // depend mgr in Tinlake clerk
        clerk.depend("mgr", address(mgr));

        // depend Maker contracts in clerk
        clerk.depend("spotter", address(spotter));
        clerk.depend("vat", address(vat));

        // give testcase the right to modify drop token holders
        root.relyContract(address(seniorMemberlist), address(this));
        // add mgr as drop token holder
        seniorMemberlist.updateMember(address(mgr), uint(- 1));

        mgr.rely(address(clerk));

        // lock RWA token
        mgr.lock(1 ether);

        jug.drip(ilk);

        deployWETHCollateral();

        // create circulating DAI supply
        uint drawDAIAmount  = 600 ether;
        uint wethAmount = 10 ether;
        createDAIWithWETH(drawDAIAmount, wethAmount);

    }

    function deployWETHCollateral() public {
        bytes32 wethIlk = "ETH";
        weth  = new SimpleToken("WETH", "WETH");

        ethJoin = new GemJoin(address(vat), wethIlk, address(weth));
        jug.init(wethIlk);
        vat.init(wethIlk);

        // Internal auth
        vat.rely(address(ethJoin));

        // Set a debt  ceiling
        vat.file(wethIlk, "line", 5 * MILLION * RAD);
        // Set the NS2DRP-A dust
        vat.file(wethIlk, "dust", 0);

        //tinlake system tests work with 110%
        uint mat = 110 * RAY / 100;
        spotter.file(wethIlk, "mat", mat);

        //spotter.poke(ilk);
        // assume a constant price with safety margin
        // add some price
        uint spot = mat;
        // set some price
        vat.file(wethIlk, "spot", 1000 * RAY);
    }

    function createDAIWithWETH(uint drawDAIAmount, uint wethAmount) public {
        weth.approve(address(ethJoin), uint(-1));
        weth.mint(address(this), 10 ether);

        ethJoin.join(address(this), 10 ether);
        vat.frob("ETH", address(this), address(this), address(this), int(wethAmount/2), int(drawDAIAmount));
        vat.hope(address(daiJoin));
        daiJoin.exit(address(this), drawDAIAmount);
    }

    // updates the interest rate in maker contracts
    function dripMakerDebt() public {
        jug.drip(ilk);
    }

    function setStabilityFee(uint fee) public {
        stabilityFee = fee;
        jug.file(ilk, "duty", fee);
    }

    function makerEvent(bytes32 name, bool) public {
        if (name == "live") {
            // Global settlement not triggered
            mgr.cage();
        } else if (name == "glad") {
            // Write-off not triggered
            mip21Tell();
            mgr.tell();
            mip21Cull();
            mgr.cull();
        } else if (name == "safe") {
            // Soft liquidation not triggered
            mip21Tell();
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

    function mip21Tell() public {
        // trigger a soft liquidation in the mip21 oracle
        oracle.bump(ilk, 500 ether);
        // reduce the debt ceiling to zero
        vat.file(ilk, "line", 0);
        // trigger soft liquidation
        oracle.tell(ilk);
    }

    function mip21Cull() public {
        warp(2 weeks);
        oracle.cull(ilk, address(urn));
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
        mip21Tell();
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
        mip21Tell();
        mgr.tell();

        // bring some currency into the reserve
        uint repayAmount = 10 ether;
        repayDefaultLoan(repayAmount);

        _executeEpoch(repayAmount);

        uint debt = clerk.debt();

        assertEqTol(currency.balanceOf(address(seniorTranche)), repayAmount, "unwind#1");
        assertTrue(coordinator.submissionPeriod() == false);
        // trigger soft liquidation
        mgr.unwind(coordinator.lastEpochExecuted());
        assertEqTol(reserve.totalBalance(), 0, "unwind#2");
        assertEqTol(clerk.debt(), debt-repayAmount, "unwind#3");
    }

    function testWriteOff() public {
        // previous test case triggers soft liquidation
        testSoftLiquidationUnderwater();
        uint preDebt = clerk.debt();

        assertTrue(preDebt > 0);

        // write off
        mip21Cull();
        mgr.cull();

        uint debt = clerk.debt();
        assertEq(debt, 0);

        // bring some currency into the reserve
        uint repayAmount = 13 ether;
        repayDefaultLoan(repayAmount);

        _executeEpoch(repayAmount);

        uint preTotalDai = vat.dai(daiJoin_);
        mgr.recover(coordinator.lastEpochExecuted());
        uint totalDai = vat.dai(daiJoin_);
        assertEqTol((totalDai/ONE), (preTotalDai/ONE) -repayAmount, "testWriteOff#1");
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

        mip21Tell();
        mgr.tell();

        warp(1 days);

        // bring some currency into the reserve
        uint repayAmount = 10 ether;
        repayDefaultLoan(repayAmount);

        _executeEpoch(repayAmount);

        clerk.changeOwnerMgr(address(this));
//        mgr.take(coordinator.lastEpochExecuted());
//
//        assertEqTol(currency.balanceOf(address(this)), repayAmount, "globalSettlement#1");
    }
}
