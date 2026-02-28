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
        if (msg.value < feeWei) revert SKY_InsufficientFee();
        if (msg.value > 0) {
            treasuryBalance += msg.value;
            emit TreasuryTopped(msg.value, msg.sender, block.number);
        }

        intentCounter++;
        intentId = intentCounter;
        intents[intentId] = AgentIntent({
            controller: msg.sender,
            side: side,
            amountWei: amountWei,
            limitPriceWei: limitPriceWei,
            executedAmountWei: 0,
            symbolHash: symbolHash,
            atBlock: block.number,
            executed: false,
            cancelled: false
        });
        _intentIdsByController[msg.sender].push(intentId);
        _intentIdsBySymbol[symbolHash].push(intentId);
        _allIntentIds.push(intentId);
        emit AgentIntentSubmitted(intentId, msg.sender, side, amountWei, limitPriceWei, symbolHash, block.number);
        return intentId;
    }

    function executeIntent(uint256 intentId, uint256 executedAmountWei, uint256 avgPriceWei) external onlyKeeper whenNotPaused nonReentrant {
        AgentIntent storage intent = intents[intentId];
        if (intent.atBlock == 0) revert SKY_IntentNotFound();
        if (intent.executed) revert SKY_IntentAlreadyExecuted();
        if (intent.cancelled) revert SKY_IntentCancelled();
        if (executedAmountWei == 0 || executedAmountWei > intent.amountWei) revert SKY_AmountOutOfBounds();

        intent.executedAmountWei = executedAmountWei;
        intent.executed = true;
        _executionByIntentId[intentId] = ExecutionRecord({
            intentId: intentId,
            keeper: msg.sender,
            executedAmountWei: executedAmountWei,
            avgPriceWei: avgPriceWei,
            atBlock: block.number
        });
        _executionBlockOrder.push(intentId);
        emit IntentExecuted(intentId, msg.sender, executedAmountWei, avgPriceWei, block.number);
    }

    function cancelIntent(uint256 intentId) external {
        AgentIntent storage intent = intents[intentId];
        if (intent.atBlock == 0) revert SKY_IntentNotFound();
        if (intent.executed) revert SKY_IntentAlreadyExecuted();
        if (intent.cancelled) revert SKY_IntentCancelled();
        if (msg.sender != intent.controller && msg.sender != owner()) revert SKY_NotController();
        intent.cancelled = true;
        emit IntentCancelled(intentId, msg.sender, block.number);
    }

    function getIntent(uint256 intentId) external view returns (
        address controller,
        uint8 side,
        uint256 amountWei,
        uint256 limitPriceWei,
        uint256 executedAmountWei,
        bytes32 symbolHash,
        uint256 atBlock,
        bool executed,
        bool cancelled
    ) {
        AgentIntent storage i = intents[intentId];
        if (i.atBlock == 0) revert SKY_IntentNotFound();
        return (i.controller, i.side, i.amountWei, i.limitPriceWei, i.executedAmountWei, i.symbolHash, i.atBlock, i.executed, i.cancelled);
    }

    function intentCount() external view returns (uint256) {
        return _allIntentIds.length;
    }

    function getIntentIdAt(uint256 index) external view returns (uint256) {
        if (index >= _allIntentIds.length) revert SKY_IntentNotFound();
        return _allIntentIds[index];
    }

    function getIntentIdsByController(address controller) external view returns (uint256[] memory) {
        return _intentIdsByController[controller];
    }

    function withdrawTreasury(address to, uint256 amountWei) external onlyOwner nonReentrant {
        if (to == address(0)) revert SKY_ZeroAddress();
        if (amountWei == 0) revert SKY_ZeroAmount();
        if (amountWei > treasuryBalance) revert SKY_TransferFailed();
        treasuryBalance -= amountWei;
        (bool ok,) = payable(to).call{value: amountWei}("");
        if (!ok) revert SKY_TransferFailed();
        emit TreasuryWithdrawn(to, amountWei);
    }

    receive() external payable {
        if (msg.value > 0) {
            treasuryBalance += msg.value;
            emit TreasuryTopped(msg.value, msg.sender, block.number);
        }
    }

    function submitIntentBatch(
        uint8[] calldata sides,
        uint256[] calldata amountsWei,
        uint256[] calldata limitPricesWei,
        bytes32[] calldata symbolHashes
    ) external payable onlyController whenNotPaused returns (uint256[] memory intentIds) {
        uint256 n = sides.length;
        if (n == 0 || amountsWei.length != n || limitPricesWei.length != n || symbolHashes.length != n) revert SKY_BoundsInvalid();
        if (_allIntentIds.length + n > SKY_MAX_INTENTS) revert SKY_MaxIntentsReached();

        uint256 totalFee = 0;
        for (uint256 i = 0; i < n; i++) {
            if (amountsWei[i] < minExecutionWei || amountsWei[i] > maxExecutionWei) revert SKY_AmountOutOfBounds();
            totalFee += (amountsWei[i] * feeBps) / SKY_BPS_DENOM;
        }
        if (msg.value < totalFee) revert SKY_InsufficientFee();
        if (msg.value > 0) {
            treasuryBalance += msg.value;
            emit TreasuryTopped(msg.value, msg.sender, block.number);
        }

        intentIds = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            if (sides[i] != SKY_SIDE_BUY && sides[i] != SKY_SIDE_SELL) revert SKY_InvalidSide();
            intentCounter++;
            uint256 intentId = intentCounter;
            intents[intentId] = AgentIntent({
                controller: msg.sender,
                side: sides[i],
                amountWei: amountsWei[i],
                limitPriceWei: limitPricesWei[i],
                executedAmountWei: 0,
                symbolHash: symbolHashes[i],
                atBlock: block.number,
                executed: false,
                cancelled: false
            });
            _intentIdsByController[msg.sender].push(intentId);
            _intentIdsBySymbol[symbolHashes[i]].push(intentId);
            _allIntentIds.push(intentId);
            intentIds[i] = intentId;
            emit AgentIntentSubmitted(intentId, msg.sender, sides[i], amountsWei[i], limitPricesWei[i], symbolHashes[i], block.number);
        }
        return intentIds;
    }

    function getConfig() external view returns (
        address controller,
        address keeper,
        address treasury,
        uint256 feeBpsVal,
        uint256 minWei,
        uint256 maxWei,
        bool paused,
        uint256 deployBlockNum
    ) {
        return (skyController, skyKeeper, skyTreasury, feeBps, minExecutionWei, maxExecutionWei, skyPaused, deployBlock);
    }

    function getRecentIntentIds(uint256 limit) external view returns (uint256[] memory ids) {
        uint256 total = _allIntentIds.length;
        if (limit > total) limit = total;
        if (limit == 0) return new uint256[](0);
        ids = new uint256[](limit);
        for (uint256 i = 0; i < limit; i++) {
            ids[i] = _allIntentIds[total - 1 - i];
        }
        return ids;
    }

    function getIntentRange(uint256 fromIndex, uint256 toIndex) external view returns (
        uint256[] memory ids,
        address[] memory controllers,
        uint8[] memory sides,
        uint256[] memory amountsWei,
        uint256[] memory atBlocks
    ) {
        uint256 n = _allIntentIds.length;
        if (fromIndex >= n) return (new uint256[](0), new address[](0), new uint8[](0), new uint256[](0), new uint256[](0));
        if (toIndex >= n) toIndex = n - 1;
        if (fromIndex > toIndex) return (new uint256[](0), new address[](0), new uint8[](0), new uint256[](0), new uint256[](0));
        uint256 len = toIndex - fromIndex + 1;
        ids = new uint256[](len);
        controllers = new address[](len);
        sides = new uint8[](len);
        amountsWei = new uint256[](len);
        atBlocks = new uint256[](len);
        for (uint256 i = 0; i < len; i++) {
            uint256 id = _allIntentIds[fromIndex + i];
            ids[i] = id;
            controllers[i] = intents[id].controller;
            sides[i] = intents[id].side;
            amountsWei[i] = intents[id].amountWei;
            atBlocks[i] = intents[id].atBlock;
        }
        return (ids, controllers, sides, amountsWei, atBlocks);
    }

    function countExecuted() external view returns (uint256 count) {
        for (uint256 i = 0; i < _allIntentIds.length; i++) {
            if (intents[_allIntentIds[i]].executed) count++;
        }
        return count;
    }

    function countCancelled() external view returns (uint256 count) {
        for (uint256 i = 0; i < _allIntentIds.length; i++) {
            if (intents[_allIntentIds[i]].cancelled) count++;
        }
        return count;
    }

    function countPending() external view returns (uint256 count) {
        for (uint256 i = 0; i < _allIntentIds.length; i++) {
            AgentIntent storage i0 = intents[_allIntentIds[i]];
            if (!i0.executed && !i0.cancelled) count++;
        }
        return count;
    }

    function totalVolumeWei() external view returns (uint256 total) {
        for (uint256 i = 0; i < _allIntentIds.length; i++) {
            total += intents[_allIntentIds[i]].executedAmountWei;
        }
        return total;
    }

    function isIntentExecutable(uint256 intentId) external view returns (bool) {
        AgentIntent storage i0 = intents[intentId];
        if (i0.atBlock == 0 || i0.executed || i0.cancelled) return false;
        return true;
    }

    function domainSalt() external view returns (bytes32) {
        return agentDomain;
    }

    function version() external pure returns (string memory) {
        return "Skylar.1.0.0";
    }

    function getIntentsBulk(uint256[] calldata intentIds) external view returns (
        address[] memory controllers,
        uint8[] memory sides,
        uint256[] memory amountsWei,
        uint256[] memory limitPricesWei,
        uint256[] memory executedAmountsWei,
        uint256[] memory atBlocks,
        bool[] memory executedFlags,
        bool[] memory cancelledFlags
    ) {
        uint256 n = intentIds.length;
        if (n > 200) revert SKY_BoundsInvalid();
        controllers = new address[](n);
        sides = new uint8[](n);
        amountsWei = new uint256[](n);
        limitPricesWei = new uint256[](n);
        executedAmountsWei = new uint256[](n);
        atBlocks = new uint256[](n);
        executedFlags = new bool[](n);
        cancelledFlags = new bool[](n);
        for (uint256 i = 0; i < n; i++) {
            AgentIntent storage i0 = intents[intentIds[i]];
            if (i0.atBlock == 0) revert SKY_IntentNotFound();
            controllers[i] = i0.controller;
            sides[i] = i0.side;
            amountsWei[i] = i0.amountWei;
            limitPricesWei[i] = i0.limitPriceWei;
            executedAmountsWei[i] = i0.executedAmountWei;
            atBlocks[i] = i0.atBlock;
            executedFlags[i] = i0.executed;
            cancelledFlags[i] = i0.cancelled;
        }
        return (controllers, sides, amountsWei, limitPricesWei, executedAmountsWei, atBlocks, executedFlags, cancelledFlags);
    }

    function volumeBySide() external view returns (uint256 buyVolumeWei, uint256 sellVolumeWei) {
        for (uint256 i = 0; i < _allIntentIds.length; i++) {
            AgentIntent storage i0 = intents[_allIntentIds[i]];
            if (i0.side == SKY_SIDE_BUY) buyVolumeWei += i0.executedAmountWei;
            else if (i0.side == SKY_SIDE_SELL) sellVolumeWei += i0.executedAmountWei;
        }
        return (buyVolumeWei, sellVolumeWei);
    }

    function intentIdsPaginated(uint256 offset, uint256 limit) external view returns (uint256[] memory ids) {
        uint256 total = _allIntentIds.length;
        if (offset >= total) return new uint256[](0);
        if (limit > total - offset) limit = total - offset;
        ids = new uint256[](limit);
        for (uint256 i = 0; i < limit; i++) {
            ids[i] = _allIntentIds[offset + i];
        }
        return ids;
    }

    function treasuryInfo() external view returns (uint256 balance, address recipient) {
        return (treasuryBalance, skyTreasury);
    }

    function constantsForFrontend() external pure returns (
        uint256 bpsDenom,
        uint256 sideBuy,
        uint256 sideSell,
        uint256 maxIntents
    ) {
        return (SKY_BPS_DENOM, SKY_SIDE_BUY, SKY_SIDE_SELL, SKY_MAX_INTENTS);
    }

    function dashboardSummary() external view returns (
        uint256 totalIntents,
        uint256 executedCount,
        uint256 cancelledCount,
        uint256 pendingCount,
        uint256 totalVolumeExecutedWei,
        uint256 treasuryBal,
        bool paused
    ) {
        totalIntents = _allIntentIds.length;
        for (uint256 i = 0; i < totalIntents; i++) {
            AgentIntent storage i0 = intents[_allIntentIds[i]];
            if (i0.executed) {
                executedCount++;
                totalVolumeExecutedWei += i0.executedAmountWei;
            }
            else if (i0.cancelled) cancelledCount++;
            else pendingCount++;
        }
        treasuryBal = treasuryBalance;
        paused = skyPaused;
        return (totalIntents, executedCount, cancelledCount, pendingCount, totalVolumeExecutedWei, treasuryBal, paused);
    }

    function getIntentDetails(uint256 intentId) external view returns (
        address controller,
        uint8 side,
        uint256 amountWei,
        uint256 limitPriceWei,
        uint256 executedAmountWei,
        bytes32 symbolHash,
        uint256 atBlock,
        bool executed,
        bool cancelled,
        bool executable
    ) {
        AgentIntent storage i0 = intents[intentId];
        if (i0.atBlock == 0) revert SKY_IntentNotFound();
        executable = !i0.executed && !i0.cancelled;
        return (
            i0.controller,
            i0.side,
            i0.amountWei,
            i0.limitPriceWei,
            i0.executedAmountWei,
            i0.symbolHash,
            i0.atBlock,
            i0.executed,
            i0.cancelled,
            executable
        );
    }

    function countByController(address controller) external view returns (uint256) {
        return _intentIdsByController[controller].length;
    }

    function countExecutedByController(address controller) external view returns (uint256 count) {
        uint256[] storage ids = _intentIdsByController[controller];
        for (uint256 i = 0; i < ids.length; i++) {
            if (intents[ids[i]].executed) count++;
        }
        return count;
    }

    function totalFeeCollected() external view returns (uint256) {
        return treasuryBalance;
    }

    function deployInfo() external view returns (uint256 blockNum, bytes32 domain) {
        return (deployBlock, agentDomain);
    }

    function getExecution(uint256 intentId) external view returns (address keeper, uint256 executedAmountWei, uint256 avgPriceWei, uint256 atBlock) {
        ExecutionRecord storage r = _executionByIntentId[intentId];
        if (r.atBlock == 0) revert SKY_IntentNotFound();
        return (r.keeper, r.executedAmountWei, r.avgPriceWei, r.atBlock);
    }

    function getIntentIdsBySymbol(bytes32 symbolHash) external view returns (uint256[] memory) {
        return _intentIdsBySymbol[symbolHash];
    }

    function volumeBySymbol(bytes32 symbolHash) external view returns (uint256 volumeWei) {
        uint256[] storage ids = _intentIdsBySymbol[symbolHash];
        for (uint256 i = 0; i < ids.length; i++) {
            volumeWei += intents[ids[i]].executedAmountWei;
        }
        return volumeWei;
    }

    function countBySymbol(bytes32 symbolHash) external view returns (uint256) {
        return _intentIdsBySymbol[symbolHash].length;
    }

    function getRecentExecutions(uint256 limit) external view returns (
        uint256[] memory intentIds,
        address[] memory keepers,
        uint256[] memory amountsWei,
        uint256[] memory pricesWei,
        uint256[] memory atBlocks
    ) {
        uint256 n = _executionBlockOrder.length;
        if (limit > n) limit = n;
        if (limit == 0) return (new uint256[](0), new address[](0), new uint256[](0), new uint256[](0), new uint256[](0));
        intentIds = new uint256[](limit);
        keepers = new address[](limit);
        amountsWei = new uint256[](limit);
        pricesWei = new uint256[](limit);
        atBlocks = new uint256[](limit);
        for (uint256 i = 0; i < limit; i++) {
            uint256 id = _executionBlockOrder[n - 1 - i];
            intentIds[i] = id;
            ExecutionRecord storage r = _executionByIntentId[id];
            keepers[i] = r.keeper;
            amountsWei[i] = r.executedAmountWei;
            pricesWei[i] = r.avgPriceWei;
            atBlocks[i] = r.atBlock;
        }
        return (intentIds, keepers, amountsWei, pricesWei, atBlocks);
    }

    function executionCount() external view returns (uint256) {
        return _executionBlockOrder.length;
    }

    function getController() external view returns (address) {
        return skyController;
    }

    function getKeeper() external view returns (address) {
        return skyKeeper;
    }

    function getTreasury() external view returns (address) {
        return skyTreasury;
    }

    function getMinExecutionWei() external view returns (uint256) {
        return minExecutionWei;
    }

    function getMaxExecutionWei() external view returns (uint256) {
        return maxExecutionWei;
    }

    function getFeeBps() external view returns (uint256) {
        return feeBps;
    }

    function isPaused() external view returns (bool) {
        return skyPaused;
    }

    function hasIntent(uint256 intentId) external view returns (bool) {
        return intents[intentId].atBlock != 0;
    }

    function getPendingIntentIds() external view returns (uint256[] memory ids) {
        uint256 n = _allIntentIds.length;
        uint256 pendingCount = 0;
        for (uint256 i = 0; i < n; i++) {
            if (!intents[_allIntentIds[i]].executed && !intents[_allIntentIds[i]].cancelled) pendingCount++;
        }
        ids = new uint256[](pendingCount);
        uint256 j = 0;
        for (uint256 i = 0; i < n; i++) {
            uint256 id = _allIntentIds[i];
            if (!intents[id].executed && !intents[id].cancelled) {
                ids[j] = id;
                j++;
            }
        }
        return ids;
    }

    function getIntentIdsInBlockRange(uint256 fromBlock, uint256 toBlock) external view returns (uint256[] memory ids) {
        uint256 n = _allIntentIds.length;
        uint256 count = 0;
        for (uint256 i = 0; i < n; i++) {
            uint256 b = intents[_allIntentIds[i]].atBlock;
            if (b >= fromBlock && b <= toBlock) count++;
        }
        ids = new uint256[](count);
        count = 0;
        for (uint256 i = 0; i < n; i++) {
            uint256 id = _allIntentIds[i];
            uint256 b = intents[id].atBlock;
            if (b >= fromBlock && b <= toBlock) {
                ids[count] = id;
                count++;
            }
        }
        return ids;
    }

    function averageExecutionPrice(uint256 intentId) external view returns (uint256) {
        ExecutionRecord storage r = _executionByIntentId[intentId];
        if (r.atBlock == 0) return 0;
