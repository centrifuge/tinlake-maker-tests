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
import {Dai} from "dss/dai.sol";
import {Vat} from "dss/vat.sol";
import {Jug} from 'dss/jug.sol';
import {Spotter} from "dss/spot.sol";

import {RwaToken} from "rwa-example/RwaToken.sol";
import {RwaUrn} from "rwa-example/RwaUrn.sol";
import {RwaLiquidationOracle} from "rwa-example/RwaLiquidationOracle.sol";
import {DaiJoin} from 'dss/join.sol';
import {AuthGemJoin} from "dss-gem-joins/join-auth.sol";
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
    mapping(bytes32 => int) public values_int;

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

interface SeniorTrancheLike {
    function epochs(uint epochID) external returns(uint, uint, uint);
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

    uint liqTime = 1 hours;

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
            doc, uint48(liqTime));
        vat.rely(address(oracle));
        (,address pip,,) = oracle.ilks(ilk);

        spotter.file(ilk, "mat", RAY);
        spotter.file(ilk, "pip", pip);
        spotter.poke(ilk);

        gemJoin = new AuthGemJoin(address(vat), ilk, address(rwa));
        gemJoin_ = address(gemJoin);
        vat.rely(gemJoin_);


        mgr = new TinlakeManager(address(currency),
            daiJoin_,
            address(seniorToken), // DROP token
            address(seniorOperator), // senior operator
            address(seniorTranche), // senior tranche
            end_,
            address(vat), address(vow));

        mgr_ = address(mgr);
        mgr.file("owner", address(clerk));

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
        uint drawDAIAmount = 600 ether;
        uint wethAmount = 10 ether;
        createDAIWithWETH(drawDAIAmount, wethAmount);

    }

    function deployWETHCollateral() public {
        bytes32 wethIlk = "ETH";
        weth = new SimpleToken("WETH", "WETH");

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
        weth.approve(address(ethJoin), uint(- 1));
        weth.mint(address(this), 10 ether);

        ethJoin.join(address(this), 10 ether);
        vat.frob("ETH", address(this), address(this), address(this), int(wethAmount / 2), int(drawDAIAmount));
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

    // triggers a soft liquidation
    function tell() public {
        mip21Tell();
        mgr.tell();
    }

    function cull() public {
        mip21Cull();
        mgr.cull();
    }

    function isMKRStateHealthy() public returns(bool) {
        nftFeed.calcUpdateNAV();
        uint lockedCollateralDAI = rmul(clerk.cdpink(), mkrAssessor.calcSeniorTokenPrice());
        uint requiredLocked = clerk.calcOvercollAmount(clerk.cdptab());
        return lockedCollateralDAI >= requiredLocked;
    }

    // returns the amount of debt in MKR after write-off
    function currTab() public returns(uint) {
        return mgr.tab()/ONE;
    }

    function makerEvent(bytes32 name, bool) public {
        if(!(name == "safe" || name == "glad"|| name == "live")) return;
        tell();
        if (name == "safe") return;
        cull();
        if (name == "glad") return;
        mgr.cage();
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

    function executeEpoch(uint dropRedeem) public {
        warp(1 days);

        // close epoch
        coordinator.closeEpoch();

        // submitting a solution is required
        if(coordinator.submissionPeriod() == true) {
            coordinator.submitSolution(dropRedeem, 0, 0, 0);
            warp(1 hours);
            coordinator.executeEpoch();
        }
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
        warp(liqTime);
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
        tell();

        warp(1 days);

        // bring some currency into the reserve
        repayAmount = 10 ether;
        repayDefaultLoan(repayAmount);

        executeEpoch(repayAmount);

        assertEqTol(currency.balanceOf(address(seniorTranche)), repayAmount, "testSoftLiquidation#1");

        uint debt = clerk.debt();

        mgr.unwind(coordinator.lastEpochExecuted());
        // no currency in the reserve
        assertEq(reserve.totalBalance(), 0);
        assertEqTol(clerk.debt(), debt - repayAmount, "testSoftLiquidation#2");
    }

    function testSoftLiquidationUnderwater() public {
        _setupUnderwaterTinlake();

        // vault under water
        assertTrue(clerk.debt() > clerk.cdpink());

        // trigger soft liquidation
        tell();

        // bring some currency into the reserve
        uint repayAmount = 10 ether;
        repayDefaultLoan(repayAmount);

        executeEpoch(repayAmount);

        uint debt = clerk.debt();

        assertEqTol(currency.balanceOf(address(seniorTranche)), repayAmount, "unwind#1");
        assertTrue(coordinator.submissionPeriod() == false);
        // trigger soft liquidation
        mgr.unwind(coordinator.lastEpochExecuted());
        assertEqTol(reserve.totalBalance(), 0, "unwind#2");
        assertEqTol(clerk.debt(), debt - repayAmount, "unwind#3");
    }

    function testWriteOff() public {
        // previous test case triggers soft liquidation
        testSoftLiquidationUnderwater();
        uint preDebt = clerk.debt();

        assertTrue(preDebt > 0);

        // write off
        cull();

        uint debt = clerk.debt();
        assertEq(debt, 0);

        // bring some currency into the reserve
        uint repayAmount = 13 ether;
        repayDefaultLoan(repayAmount);

        executeEpoch(repayAmount);

        uint preTotalDai = vat.dai(daiJoin_);
        mgr.recover(coordinator.lastEpochExecuted());
        uint totalDai = vat.dai(daiJoin_);
        assertEqTol((totalDai / ONE), (preTotalDai / ONE) - repayAmount, "testWriteOff#1");
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

        // mkr is healthy
        assertTrue(isMKRStateHealthy() == true);

        tell();

        cull();

        // trigger global settlement
        mgr.cage();

        warp(1 days);

        // bring some currency into the reserve
        uint repayAmount = 10 ether;
        repayDefaultLoan(repayAmount);

        executeEpoch(repayAmount);

        clerk.changeOwnerMgr(address(this));

        //tab = dai written off
        uint tab = mgr.tab();
        mgr.recover(coordinator.lastEpochExecuted());

        assertEqTol(reserve.totalBalance(), 0, "testGlobalSettlement#1");
        assertEqTol(tab/ONE-repayAmount, mgr.tab()/ONE, "testGlobalSettlement#2");
    }

    function testMultipleUnwind() public {
        uint loan = 1;
        testSoftLiquidationUnderwater();
        assertTrue(isMKRStateHealthy() == false);

        uint preDebt = clerk.debt();

        // mkr debt is still existing
        assertTrue(preDebt > 0);

        uint max = 10;
        uint minRepayAmount = 10 ether;
        uint loanDebt = pile.debt(loan);
        for (uint i = 0; i < max; i++) {
            uint loanDebt = pile.debt(loan);
            if (loanDebt == 0) {
                break;
            }

            // different loan repayment amounts
            uint repayAmount = ((i+1) * minRepayAmount);
            repayDefaultLoan(repayAmount);
            executeEpoch(repayAmount);

            uint preDebt = clerk.debt();
            mgr.unwind(coordinator.lastEpochExecuted());

            (uint redeemFulfillment,,) = SeniorTrancheLike(address(seniorTranche)).epochs(coordinator.lastEpochExecuted());
            (uint seniorRedeemOrder,,,) = coordinator.order();
            uint amountForMKR = rmul(seniorRedeemOrder, redeemFulfillment);

            //total loan repayment amount is used for redeemOrder from mgr
            assertEqTol(preDebt-amountForMKR, clerk.debt(), "testMultipleUnwind#1");
        }

    }

    function testMultipleUnwindRepayAllMKRDebt() public {
        // no stability fee
        uint fee = ONE;
        setStabilityFee(fee);
        uint juniorAmount = 200 ether;
        uint mkrAmount = 300 ether;
        uint borrowAmount = 250 ether;
        uint firstLoan = 1;

        // default loan has 5% interest per day
        _setUpDraw(mkrAmount, juniorAmount, borrowAmount);

        mgr.tell();

        uint repayAmount = borrowAmount;
        repayDefaultLoan(repayAmount);
        executeEpoch(repayAmount);

        uint preDebt = clerk.debt();


        uint preOperatorBalance = currency.balanceOf(address(clerk));

        (uint redeemFulfillment,,) = SeniorTrancheLike(address(seniorTranche)).epochs(coordinator.lastEpochExecuted());
        (uint seniorRedeemOrder,,,) = coordinator.order();
        uint amountForMKR = rmul(seniorRedeemOrder, redeemFulfillment);

        mgr.unwind(coordinator.lastEpochExecuted());
        assertEqTol(clerk.debt(), 0, "testMultipleUnwindMRKDebt#1");
        // difference between collateralValue and debt should receive the clerk
        assertEqTol(preOperatorBalance+amountForMKR-preDebt, currency.balanceOf(address(clerk)), "testMultipleUnwindMRKDebt#2");
    }

    function testMultipleRecover() public {
        // 5% per day
        uint fee = 1000000564701133626865910626;
        setStabilityFee(fee);
        uint juniorAmount = 200 ether;
        uint mkrAmount = 300 ether;
        uint borrowAmount = 500 ether;
        _setUpDraw(mkrAmount, juniorAmount, borrowAmount);

        assertEq(clerk.debt(), borrowAmount-juniorAmount);

        // mkr is healthy
        assertTrue(isMKRStateHealthy() == true);

        // trigger soft liquidation with healthy pool
        tell();

        cull();

        uint max = 5;
        uint minRepayAmount = 50 ether;
        uint loan = 1;
        uint loanDebt = pile.debt(loan);
        for (uint i = 0; i < max; i++) {
            uint preTab = currTab();

            uint loanDebt = pile.debt(loan);
            if (loanDebt == 0) {
                break;
            }

            // different loan repayment amounts
            uint repayAmount =  minRepayAmount + (i * 10 ether);
            repayDefaultLoan(repayAmount);
            executeEpoch(repayAmount);

            (uint redeemFulfillment,,) = SeniorTrancheLike(address(seniorTranche)).epochs(coordinator.lastEpochExecuted());
            (uint seniorRedeemOrder,,,) = coordinator.order();
            uint amountForMKR = rmul(seniorRedeemOrder, redeemFulfillment);

            mgr.recover(coordinator.lastEpochExecuted());

            if (currTab() > 0) {
                // total repay amount is used tab reduction
                assertEqTol(preTab-amountForMKR, currTab(), "testMultipleRecover#2");
            } else {
                assertEqTol(currency.balanceOf(address(clerk)), amountForMKR-preTab, "testMultipleRecover#3");
                break;
            }

        }
        assertEq(currTab(), 0);
    }

    function testRecoverAfterTabZero() public {
        uint fee = ONE;
        setStabilityFee(fee);
        uint juniorAmount = 200 ether;
        uint mkrAmount = 300 ether;
        uint borrowAmount = 500 ether;
        _setUpDraw(mkrAmount, juniorAmount, borrowAmount);

        assertEq(clerk.debt(), borrowAmount-juniorAmount);

        // mkr is healthy
        assertTrue(isMKRStateHealthy() == true);

        tell();

        cull();

        // repay 100% of tab
        uint repayAmount = currTab();
        repayDefaultLoan(repayAmount);
        executeEpoch(repayAmount);

        mgr.recover(coordinator.lastEpochExecuted());
        assertEqTol(currTab(), 0, "testRecoverAfterTabZero#1");

        (,,uint tokenLeft) = seniorTranche.users(address(mgr));
        assertTrue(tokenLeft > 0);

        repayAmount = 10 ether;
        repayDefaultLoan(repayAmount);
        executeEpoch(repayAmount);

        // all currency should go to clerk
        mgr.recover(coordinator.lastEpochExecuted());
        assertEqTol(currency.balanceOf(address(clerk)), repayAmount, "testRecoverAfterTabZero#2");
    }
}
