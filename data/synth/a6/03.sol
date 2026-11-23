// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

interface IERC20Min {
    function transfer(address to, uint256 value) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
}

interface IPositionBook {
    function positionOf(address who) external view returns (uint256);
    function totalPositions() external view returns (uint256);
}

/// Per-block accrual vault. Rewards are computed from block numbers, not timestamps.
/// Each account keeps a Cursor that records the global index and the amount already owed.
contract BlockRewardVault {
    uint256 internal constant ONE = 1e27;

    struct Cursor {
        uint256 index;
        uint256 owed;
    }

    error Unauthorised(address caller);
    error VaultPaused();
    error ZeroRewardToken();
    error NoAccrual();
    error PayoutFailed(address to, uint256 value);

    event BlockRewardSet(uint128 previous, uint128 current, uint64 atBlock);
    event GlobalIndexMoved(uint256 index, uint64 atBlock);
    event CursorSettled(address indexed who, uint256 owed);
    event Harvested(address indexed who, uint256 value);
    event Paused(bool isPaused);

    IERC20Min public immutable token;
    IPositionBook public immutable book;
    address public immutable governor;

    uint128 public rewardPerBlock;
    uint64 public lastBlock;
    bool public paused;

    uint256 public globalIndex;
    mapping(address => Cursor) public cursors;

    constructor(IERC20Min token_, IPositionBook book_, uint128 rewardPerBlock_) {
        if (address(token_) == address(0)) revert ZeroRewardToken();
        token = token_;
        book = book_;
        governor = msg.sender;
        rewardPerBlock = rewardPerBlock_;
        lastBlock = uint64(block.number);
        emit BlockRewardSet(0, rewardPerBlock_, uint64(block.number));
    }

    modifier onlyGovernor() {
        if (msg.sender != governor) revert Unauthorised(msg.sender);
        _;
    }

    function setRewardPerBlock(uint128 next) external onlyGovernor {
        _moveGlobal();
        emit BlockRewardSet(rewardPerBlock, next, uint64(block.number));
        rewardPerBlock = next;
    }

    function setPaused(bool isPaused) external onlyGovernor {
        _moveGlobal();
        paused = isPaused;
        emit Paused(isPaused);
    }

    /// Called by the position book before it writes a new position for `who`.
    function notifyPositionChange(address who) external {
        if (msg.sender != address(book)) revert Unauthorised(msg.sender);
        _settleCursor(who);
    }

    function harvest() external returns (uint256 value) {
        if (paused) revert VaultPaused();
        _settleCursor(msg.sender);
        Cursor storage c = cursors[msg.sender];
        value = c.owed;
        if (value == 0) revert NoAccrual();
        c.owed = 0;
        if (!token.transfer(msg.sender, value)) revert PayoutFailed(msg.sender, value);
        emit Harvested(msg.sender, value);
    }

    function pendingOf(address who) public view returns (uint256) {
        Cursor memory c = cursors[who];
        uint256 projected = _projectIndex();
        uint256 position = book.positionOf(who);
        return c.owed + (position * (projected - c.index)) / ONE;
    }

    function _projectIndex() internal view returns (uint256) {
        uint256 blocks = block.number - lastBlock;
        uint256 total = book.totalPositions();
        if (blocks == 0 || total == 0) return globalIndex;
        return globalIndex + (blocks * rewardPerBlock * ONE) / total;
    }

    function _moveGlobal() internal {
        uint256 next = _projectIndex();
        if (next != globalIndex) {
            globalIndex = next;
            emit GlobalIndexMoved(next, uint64(block.number));
        }
        lastBlock = uint64(block.number);
    }

    function _settleCursor(address who) internal {
        _moveGlobal();
        Cursor storage c = cursors[who];
        uint256 position = book.positionOf(who);
        uint256 delta = globalIndex - c.index;
        if (position != 0 && delta != 0) {
            c.owed = c.owed + (position * delta) / ONE;
        }
        c.index = globalIndex;
        emit CursorSettled(who, c.owed);
    }
}
