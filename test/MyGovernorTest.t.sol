// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {Test, console} from "../lib/forge-std/src/Test.sol";

import {MyGovernor} from "../src/MyGovernor.sol";
import {Box} from "../src/Box.sol";
import {TimeLock} from "../src/TimeLock.sol";
import {GovToken} from "../src/GovToken.sol";

contract MyGovernorTest is Test {
    MyGovernor governor;
    Box box;
    TimeLock timeLock;
    GovToken govToken;
    address public USER = makeAddr("user");
    uint256 public constant INITIAL_SUPPLY = 100 ether;
    uint256 public constant MIN_DELAY = 3600;
    uint256 public constant VOTING_DELAY = 1; // how many blocks till a vote is active
    uint256 constant VOTING_PERIOD = 50400; // 1 week

    //  Leaving the `proposers` and `executors` arrays empty is how you tell the timelock that anyone can fill these roles.
    address[] proposers;
    address[] executors;
    uint256[] values;
    bytes[] calldatas;
    address[] targets;

    function setUp() public {
        govToken = new GovToken();
        govToken.mint(USER, INITIAL_SUPPLY);

        vm.startPrank(USER);
        //Something commonly overlooked when writing tests this way is that, just because our user has minted tokens, doesn't mean they have voting power. It's necessary to call the delegate function to assign this weight to the user who minted.
        govToken.delegate(USER); // for voting power
        timeLock = new TimeLock(MIN_DELAY, proposers, executors);
        governor = new MyGovernor(govToken, timeLock);

        // The Timelock contract we're using contains a number of roles which we can set on deployment.
        // For example, we only want our governor to be able to submit proposals to the timelock, so this is something we want want to configure explicitly after deployment.
        // Similarly the `admin` role is defaulted to the address which deployed our timelock, we absolutely want this to be our governor to avoid centralization.
        bytes32 proposerRole = timeLock.PROPOSER_ROLE(); // only the governor can propose stuff to the timeLock
        bytes32 executorRole = timeLock.EXECUTOR_ROLE(); // give this to anybody
        bytes32 adminRole = timeLock.DEFAULT_ADMIN_ROLE();

        timeLock.grantRole(proposerRole, address(governor));
        timeLock.grantRole(executorRole, address(0));
        timeLock.revokeRole(adminRole, USER);

        box = new Box();
        // we need to assure that the `timelock` is set as the owner of this protocol.
        // the store function of our Box contract is access controlled. This is meant to be called by only our DAO. But, because our DAO (the governor contract) must always check with the timelock before executing anything, the timelock is what must be set as the address able to call functions on our protocol.
        box.transferOwnership(address(timeLock));
        vm.stopPrank();
    }

    function testCantUpdateBoxWithoutGovernance() public {
        vm.expectRevert();
        box.store(1);
    }

    function testGovernanceUpdatesBox() public {
        uint256 valueToStore = 888;

        //first thing we need to kickoff anything is to propose
        string memory description = "Store 888 in Box";
        bytes memory encodedFunctionCall = abi.encodeWithSignature("store(uint256)", valueToStore);

        values.push(0);
        calldatas.push(encodedFunctionCall);
        targets.push(address(box));

        // 1.Propose to the DAO
        uint256 proposalId = governor.propose(targets, values, calldatas, description);

        // view the state of the proposal
        console.log("Proposal State:", uint256(governor.state(proposalId))); //should be pending(0)

        vm.warp(block.timestamp + VOTING_DELAY + 1);
        vm.roll(block.number + VOTING_DELAY + 1);

        console.log("Proposal State:", uint256(governor.state(proposalId))); // hsould be active(1)

        // 2. Vote
        string memory reason = "I want to store 888 in the Box";
        uint8 voteWay = 1; // voting yes/isFor, also called support
        vm.prank(USER);
        governor.castVoteWithReason(proposalId, voteWay, reason);

        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        vm.roll(block.number + VOTING_PERIOD + 1);

        // 3.Queue the txn
        bytes32 decriptionHash = keccak256(abi.encodePacked(description));
        governor.queue(targets, values, calldatas, decriptionHash);

        vm.warp(block.timestamp + MIN_DELAY + 1);
        vm.roll(block.number + MIN_DELAY + 1);

        // 4.Execute
        governor.execute(targets, values, calldatas, decriptionHash);

        assert(box.getNumber() == valueToStore);
        console.log("Box number:", box.getNumber());
    }
}
