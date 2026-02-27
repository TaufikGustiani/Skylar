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
    mapping(address => uint256[]) private _intentIdsByController;
    mapping(bytes32 => uint256[]) private _intentIdsBySymbol;
    uint256[] private _allIntentIds;

    struct ExecutionRecord {
        uint256 intentId;
        address keeper;
        uint256 executedAmountWei;
        uint256 avgPriceWei;
        uint256 atBlock;
    }
    mapping(uint256 => ExecutionRecord) private _executionByIntentId;
    uint256[] private _executionBlockOrder;

    modifier whenNotPaused() {
        if (skyPaused) revert SKY_Paused();
        _;
    }

    modifier onlyController() {
        if (msg.sender != skyController && msg.sender != owner()) revert SKY_NotController();
        _;
    }

    modifier onlyKeeper() {
        if (msg.sender != skyKeeper && msg.sender != owner()) revert SKY_NotKeeper();
        _;
    }

    constructor() Ownable(msg.sender) {
        skyTreasury = address(0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed);
        skyController = address(0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359);
        skyKeeper = address(0xdbF03B407c01E7cD3CBea99509d93f8DDDC8C6FB);
        deployBlock = block.number;
        agentDomain = keccak256("Skylar.agent");
        feeBps = 25;
        minExecutionWei = 1e15;
        maxExecutionWei = 1000 ether;
    }

    function setPaused(bool paused) external onlyOwner {
        skyPaused = paused;
        emit AgentPaused(paused, block.number);
    }

    function setController(address newController) external onlyOwner {
        if (newController == address(0)) revert SKY_ZeroAddress();
        address prev = skyController;
        skyController = newController;
        emit ControllerSet(prev, newController);
    }

    function setKeeper(address newKeeper) external onlyOwner {
        if (newKeeper == address(0)) revert SKY_ZeroAddress();
        address prev = skyKeeper;
        skyKeeper = newKeeper;
        emit KeeperSet(prev, newKeeper);
    }

    function setExecutionBounds(uint256 minWei, uint256 maxWei) external onlyOwner {
        if (minWei > maxWei) revert SKY_BoundsInvalid();
        minExecutionWei = minWei;
        maxExecutionWei = maxWei;
        emit ExecutionBoundsSet(minWei, maxWei, block.number);
    }

    function setFeeBps(uint256 newFeeBps) external onlyOwner {
        if (newFeeBps > SKY_BPS_DENOM) revert SKY_BoundsInvalid();
        uint256 prev = feeBps;
        feeBps = newFeeBps;
        emit FeeBpsSet(prev, newFeeBps, block.number);
    }

    function submitIntent(
        uint8 side,
        uint256 amountWei,
        uint256 limitPriceWei,
        bytes32 symbolHash
    ) external payable onlyController whenNotPaused returns (uint256 intentId) {
        if (side != SKY_SIDE_BUY && side != SKY_SIDE_SELL) revert SKY_InvalidSide();
        if (amountWei == 0) revert SKY_ZeroAmount();
        if (amountWei < minExecutionWei || amountWei > maxExecutionWei) revert SKY_AmountOutOfBounds();
        if (_allIntentIds.length >= SKY_MAX_INTENTS) revert SKY_MaxIntentsReached();

        uint256 feeWei = (amountWei * feeBps) / SKY_BPS_DENOM;
