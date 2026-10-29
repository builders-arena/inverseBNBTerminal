// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Errors} from "../libraries/Errors.sol";
import {Governed} from "../libraries/Governed.sol";

/// @title  KeeperFunder
/// @notice Holds treasury BNB and tops up registered keeper hot wallets on demand, with a per-keeper
///         daily cap. A drained keeper key therefore costs at most the daily cap, not the treasury.
/// @dev    Holds only treasury funds (never user funds), so the Guardian may recover the balance.
contract KeeperFunder is Governed, ReentrancyGuard {
    uint256 public constant TOP_UP = 0.2 ether;
    uint256 public constant THRESHOLD = 0.1 ether; // only refill below this balance
    uint256 public constant DAILY_CAP = 1 ether; // per keeper per rolling 24h window

    mapping(address => bool) public isKeeper;
    mapping(address => uint256) public windowStart;
    mapping(address => uint256) public sentInWindow;

    event KeeperSet(address indexed keeper, bool allowed);
    event Refilled(address indexed keeper, uint256 amount);
    event Funded(address indexed from, uint256 amount);
    event Recovered(address indexed to, uint256 amount);

    constructor(address guardian_) Governed(guardian_) {}

    /// @notice Registered keeper pulls a top-up when its balance is below THRESHOLD.
    function refill() external nonReentrant {
        if (!isKeeper[msg.sender]) revert Errors.NotGuardian(msg.sender);
        if (msg.sender.balance >= THRESHOLD) revert Errors.OutOfBounds(msg.sender.balance, 0, THRESHOLD);

        if (block.timestamp >= windowStart[msg.sender] + 1 days) {
            windowStart[msg.sender] = block.timestamp;
            sentInWindow[msg.sender] = 0;
        }

        uint256 amount = TOP_UP;
        uint256 remaining = DAILY_CAP - sentInWindow[msg.sender];
        if (amount > remaining) amount = remaining;
        if (amount == 0) revert Errors.OutOfBounds(0, 1, DAILY_CAP);
        if (address(this).balance < amount) amount = address(this).balance;
        if (amount == 0) revert Errors.InsufficientNav(TOP_UP, 0);

        sentInWindow[msg.sender] += amount;
        emit Refilled(msg.sender, amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert Errors.EthTransferFailed();
    }

    function setKeeper(address keeper, bool allowed) external onlyGuardian {
        isKeeper[keeper] = allowed;
        emit KeeperSet(keeper, allowed);
    }

    /// @notice Guardian recovers unused treasury funds (this contract holds no user money).
    function recover(address to, uint256 amount) external onlyGuardian nonReentrant {
        if (to == address(0)) revert Errors.ZeroAddress();
        emit Recovered(to, amount);
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert Errors.EthTransferFailed();
    }

    receive() external payable {
        emit Funded(msg.sender, msg.value);
    }
}
