// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @title CheckpointArrayPower
/// @notice Balances are checkpointed per block so governance can read historical voting power.
///         Yield accrues on a global index and is settled per holder before any balance change.
contract CheckpointArrayPower {
    uint256 private constant PRECISION = 1e18;

    struct Checkpoint {
        uint64 fromBlock;
        uint192 balance;
    }

    IERC20 public immutable token;
    address public immutable treasurer;

    uint256 public totalBalance;
    uint256 public yieldIndex;

    mapping(address => uint256) public balanceOf;
    mapping(address => uint256) public yieldDebt;
    mapping(address => uint256) public yieldOwed;
    mapping(address => Checkpoint[]) private checkpoints;

    event Deposited(address indexed who, uint256 amount);
    event Withdrawn(address indexed who, uint256 amount);
    event YieldAdded(uint256 amount, uint256 newIndex);
    event YieldClaimed(address indexed who, uint256 amount);

    constructor(IERC20 _token) {
        token = _token;
        treasurer = msg.sender;
    }

    function addYield(uint256 amount) external {
        require(msg.sender == treasurer, "not treasurer");
        require(totalBalance > 0, "no balance");
        require(token.transferFrom(msg.sender, address(this), amount), "transfer failed");
        yieldIndex += (amount * PRECISION) / totalBalance;
        emit YieldAdded(amount, yieldIndex);
    }

    function _syncCheckpoints(address who) internal {
        uint256 bal = balanceOf[who];
        if (bal > 0) {
            yieldOwed[who] += (bal * (yieldIndex - yieldDebt[who])) / PRECISION;
        }
        yieldDebt[who] = yieldIndex;
    }

    function _writeCheckpoint(address who, uint256 bal) internal {
        Checkpoint[] storage cps = checkpoints[who];
        uint256 n = cps.length;
        if (n > 0 && cps[n - 1].fromBlock == block.number) {
            cps[n - 1].balance = uint192(bal);
        } else {
            cps.push(Checkpoint(uint64(block.number), uint192(bal)));
        }
    }

    /// @notice Balance of `who` as of `blockNumber`, via binary search over checkpoints.
    function balanceAt(address who, uint256 blockNumber) public view returns (uint256) {
        Checkpoint[] storage cps = checkpoints[who];
        uint256 n = cps.length;
        if (n == 0 || cps[0].fromBlock > blockNumber) return 0;
        uint256 lo = 0;
        uint256 hi = n - 1;
        while (lo < hi) {
            uint256 mid = (lo + hi + 1) / 2;
            if (cps[mid].fromBlock <= blockNumber) {
                lo = mid;
            } else {
                hi = mid - 1;
            }
        }
        return cps[lo].balance;
    }

    /// @notice Deposit into the pool.
    function depositCapital(uint256 amount) external {
        require(amount > 0, "zero amount");
        _syncCheckpoints(msg.sender);
        balanceOf[msg.sender] += amount;
        totalBalance += amount;
        _writeCheckpoint(msg.sender, balanceOf[msg.sender]);
        require(token.transferFrom(msg.sender, address(this), amount), "transfer failed");
        emit Deposited(msg.sender, amount);
    }

    /// @notice Withdraw balance.
    function withdrawCapital(uint256 amount) external {
        _syncCheckpoints(msg.sender);
        require(balanceOf[msg.sender] >= amount, "insufficient balance");
        balanceOf[msg.sender] -= amount;
        totalBalance -= amount;
        _writeCheckpoint(msg.sender, balanceOf[msg.sender]);
        require(token.transfer(msg.sender, amount), "transfer failed");
        emit Withdrawn(msg.sender, amount);
    }

    /// @notice Claim accrued yield.
    function claimYield() external {
        _syncCheckpoints(msg.sender);
        uint256 amount = yieldOwed[msg.sender];
        require(amount > 0, "nothing to claim");
        yieldOwed[msg.sender] = 0;
        require(token.transfer(msg.sender, amount), "transfer failed");
        emit YieldClaimed(msg.sender, amount);
    }
}
