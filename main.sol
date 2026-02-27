// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title Skylar
/// @notice On-chain registry for AI trading agent signals and execution intents. Controllers post buy/sell intents; keeper executes within bounds; treasury receives fees.
/// @dev Agent seed: 0xa7c3e9f1b5d2e4a6c8d0e2f4a6b8c0d2e4f6a8b0c2d4e6f8a0b2c4d6e8f0a2b4

import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.6/contracts/security/ReentrancyGuard.sol";
import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.6/contracts/access/Ownable.sol";

contract Skylar is ReentrancyGuard, Ownable {

    event AgentIntentSubmitted(
        uint256 indexed intentId,
        address indexed controller,
        uint8 side,
        uint256 amountWei,
        uint256 limitPriceWei,
        bytes32 symbolHash,
        uint256 atBlock
    );
    event IntentExecuted(
        uint256 indexed intentId,
        address indexed keeper,
        uint256 executedAmountWei,
        uint256 avgPriceWei,
        uint256 atBlock
    );
    event IntentCancelled(uint256 indexed intentId, address indexed by, uint256 atBlock);
    event ControllerSet(address indexed previous, address indexed current);
    event KeeperSet(address indexed previous, address indexed current);
    event TreasuryTopped(uint256 amountWei, address indexed from, uint256 atBlock);
    event TreasuryWithdrawn(address indexed to, uint256 amountWei, uint256 atBlock);
    event AgentPaused(bool paused, uint256 atBlock);
    event ExecutionBoundsSet(uint256 minWei, uint256 maxWei, uint256 atBlock);
    event FeeBpsSet(uint256 previousBps, uint256 newBps, uint256 atBlock);

    error SKY_ZeroAddress();
    error SKY_ZeroAmount();
    error SKY_Paused();
    error SKY_NotController();
    error SKY_NotKeeper();
    error SKY_IntentNotFound();
    error SKY_IntentAlreadyExecuted();
    error SKY_IntentCancelled();
    error SKY_TransferFailed();
    error SKY_AmountOutOfBounds();
    error SKY_InvalidSide();
    error SKY_InvalidPrice();
    error SKY_BoundsInvalid();
    error SKY_InsufficientFee();
    error SKY_MaxIntentsReached();

    uint256 public constant SKY_BPS_DENOM = 10000;
    uint256 public constant SKY_SIDE_BUY = 1;
    uint256 public constant SKY_SIDE_SELL = 2;
    uint256 public constant SKY_MAX_INTENTS = 10000;
    uint256 public constant SKY_AGENT_SEED = 0xa7c3e9f1b5d2e4a6c8d0e2f4a6b8c0d2e4f6a8b0c2d4e6f8a0b2c4d6e8f0a2b4;

    address public immutable skyTreasury;
    uint256 public immutable deployBlock;
    bytes32 public immutable agentDomain;

    address public skyController;
    address public skyKeeper;
    bool public skyPaused;
    uint256 public feeBps;
    uint256 public minExecutionWei;
    uint256 public maxExecutionWei;
    uint256 public intentCounter;
    uint256 public treasuryBalance;

    struct AgentIntent {
        address controller;
        uint8 side;
        uint256 amountWei;
        uint256 limitPriceWei;
        uint256 executedAmountWei;
        bytes32 symbolHash;
        uint256 atBlock;
        bool executed;
        bool cancelled;
    }

    mapping(uint256 => AgentIntent) public intents;
