// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import '../src/Institutional.sol';
import '../src/CrossChainSettlement.sol';
interface VM { function prank(address) external; function warp(uint256) external; function expectRevert() external; function mockCall(address,bytes calldata,bytes calldata) external; }
contract InstitutionalTest {
    VM constant vm = VM(address(uint160(uint256(keccak256('hevm cheat code')))));
    Ledger cash; Ledger security; DeliveryVersusPayment dvp;
    address constant BUYER = address(1); address constant SELLER = address(2);
    function setUp() public {
        cash = new Ledger(); security = new Ledger(); dvp = new DeliveryVersusPayment(cash,security);
        cash.setParticipant(BUYER,true); cash.setParticipant(SELLER,true); cash.setParticipant(address(dvp),true);
        security.setParticipant(BUYER,true); security.setParticipant(SELLER,true); security.setParticipant(address(dvp),true);
        cash.mint('cash',BUYER,100); security.mint('security',SELLER,10);
        vm.prank(BUYER); cash.approve(address(dvp),100);
        vm.prank(SELLER); security.approve(address(dvp),10);
    }
    function approveTrade() internal {
        bytes32 id = dvp.tradeID('trade',BUYER,SELLER,20,2);
        vm.prank(BUYER); dvp.authorize(id,true); vm.prank(SELLER); dvp.authorize(id,true);
    }
    function testDvPConservesBothAssets() public {
        approveTrade(); dvp.settle('trade',BUYER,SELLER,20,2);
        require(cash.balanceOf(BUYER)==80 && cash.balanceOf(SELLER)==20);
        require(security.balanceOf(BUYER)==2 && security.balanceOf(SELLER)==8);
        require(cash.totalSupply()==100 && security.totalSupply()==10);
        vm.expectRevert(); dvp.settle('trade',BUYER,SELLER,20,2);
    }
    function testUnauthorizedTradeFails() public {vm.expectRevert(); dvp.settle('trade',BUYER,SELLER,20,2);}
    function testSecondLegFailureRollsBackFirstLeg() public {
        approveTrade(); security.setParticipant(SELLER,false);
        vm.expectRevert(); dvp.settle('trade',BUYER,SELLER,20,2);
        require(cash.balanceOf(BUYER)==100 && cash.balanceOf(SELLER)==0 && !dvp.settled('trade'));
    }
    function testIssuanceAuthorizationAndDuplicate() public {
        vm.prank(BUYER); vm.expectRevert(); cash.mint('bad',BUYER,100);
        vm.expectRevert(); cash.mint('cash',BUYER,100);
    }
    function testRevokeParticipant() public {cash.setParticipant(BUYER,false);vm.prank(BUYER);vm.expectRevert();cash.transfer(SELLER,1);}
    function testOracleFreshnessAndPublisherRotation() public {
        PriceFeed feed = new PriceFeed(address(this)); feed.publish(1,100);
        require(feed.valid(60,99,101)); vm.warp(block.timestamp+61);require(!feed.valid(60,99,101));
        feed.setPublisher(SELLER);vm.expectRevert();feed.publish(2,100);
        vm.prank(SELLER);feed.publish(2,100);require(feed.valid(60,99,101));
    }
    function testRedemptionIDsCannotBeSquattedByAnotherActor() public {
        vm.prank(BUYER);cash.transfer(SELLER,2);
        vm.prank(SELLER);cash.redeem('redemption',1);
        vm.prank(BUYER);cash.redeem('redemption',1);
        require(cash.totalSupply()==98);
        vm.prank(SELLER);vm.expectRevert();cash.redeem('zero',0);
    }
    function testOracleSettlementIDsArePayerScoped() public {
        PriceFeed feed=new PriceFeed(address(this));feed.publish(1,100);
        OracleSettlement settlement=new OracleSettlement(cash,feed,60,99,101);
        cash.setParticipant(address(settlement),true);cash.mint('seller-funding',SELLER,2);
        vm.prank(SELLER);cash.approve(address(settlement),2);
        vm.prank(BUYER);cash.approve(address(settlement),2);
        vm.prank(SELLER);settlement.settle('business',address(this),1);
        vm.prank(BUYER);settlement.settle('business',address(this),1);
        require(cash.balanceOf(address(this))==2);
    }
    function testFuzzTransferConservation(uint64 amount) public {
        uint256 n=uint256(amount)%101;vm.prank(BUYER);cash.transfer(SELLER,n);
        require(cash.balanceOf(BUYER)+cash.balanceOf(SELLER)==cash.totalSupply());
    }
}
contract CrossChainTest {
    VM constant vm = VM(address(uint160(uint256(keccak256('hevm cheat code')))));
    address constant WARP = 0x0200000000000000000000000000000000000005;
    address constant REMOTE = address(123);
    bytes32 constant CHAIN = bytes32(uint256(9));
    Ledger cash; CrossChainSettlement source;
    function setUp() public {
        cash=new Ledger();source=new CrossChainSettlement(cash,CHAIN,REMOTE);
        cash.setParticipant(address(source),true);cash.mint('mint',address(this),100);cash.approve(address(source),100);
        vm.mockCall(WARP,abi.encodeWithSelector(IWarp.sendWarpMessage.selector),abi.encode(bytes32(uint256(1))));
    }
    function message(uint8 kind,bytes32 id,uint256 deadline,address origin) internal {
        IWarp.WarpMessage memory m=IWarp.WarpMessage(CHAIN,origin,abi.encode(kind,source.operationID(address(this),id),address(456),uint256(10),deadline));
        vm.mockCall(WARP,abi.encodeWithSelector(IWarp.getVerifiedWarpMessage.selector,uint32(0)),abi.encode(m,true));
    }
    function testTimeoutCannotRefundWithoutDecision() public {
        uint256 deadline=block.timestamp+60;source.open('p',address(456),10,deadline);vm.warp(deadline+1);source.requestAbort(source.operationID(address(this),'p'));
        require(cash.balanceOf(address(source))==10 && cash.balanceOf(address(this))==90);
        message(2,'p',deadline,REMOTE);source.receiveMessage(0);
        message(3,'p',deadline,REMOTE);vm.expectRevert();source.receiveMessage(0);
        require(cash.balanceOf(address(source))==10);
    }
    function testAuthenticatedAbortRefundsExactlyOnce() public {
        uint256 deadline=block.timestamp+60;source.open('p',address(456),10,deadline);
        message(3,'p',deadline,address(999));vm.expectRevert();source.receiveMessage(0);
        message(3,'p',deadline,REMOTE);source.receiveMessage(0);source.receiveMessage(0);
        source.claimRefund(source.operationID(address(this),'p'));
        require(cash.balanceOf(address(this))==100 && cash.balanceOf(address(source))==0);
    }
    function testLateOpenCannotOverrideAbort() public {
        uint256 deadline=block.timestamp+60;message(1,'p',deadline,REMOTE);source.receiveMessage(0);
        message(0,'p',deadline,REMOTE);source.receiveMessage(0);
        require(source.received(address(456))==0);
    }
    function testRevokedRefundRemainsClaimableAfterReinstatement() public {
        uint256 deadline=block.timestamp+60;source.open('p',address(456),10,deadline);
        cash.setParticipant(address(this),false);message(3,'p',deadline,REMOTE);source.receiveMessage(0);
        bytes32 id=source.operationID(address(this),'p');require(source.refundPending(id));
        vm.expectRevert();source.claimRefund(id);require(source.refundPending(id));
        cash.setParticipant(address(this),true);source.claimRefund(id);require(cash.balanceOf(address(this))==100);
    }
    function testInvalidWarpProofRejected() public {
        IWarp.WarpMessage memory m=IWarp.WarpMessage(CHAIN,REMOTE,bytes(''));
        vm.mockCall(WARP,abi.encodeWithSelector(IWarp.getVerifiedWarpMessage.selector,uint32(0)),abi.encode(m,false));
        vm.expectRevert();source.receiveMessage(0);
    }
    function testChangedPayloadForDecidedIDRejected() public {
        uint256 deadline=block.timestamp+60;message(0,'p',deadline,REMOTE);source.receiveMessage(0);
        message(0,'p',deadline+1,REMOTE);vm.expectRevert();source.receiveMessage(0);
        require(source.received(address(456))==10);
    }
    function testDuplicateCommitCannotDoubleCredit() public {
        message(0,'p',block.timestamp+60,REMOTE);source.receiveMessage(0);source.receiveMessage(0);
        require(source.received(address(456))==10);
    }
}
