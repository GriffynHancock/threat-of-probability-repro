// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @title CheckpointDeposits
/// @notice Deposits earn a reward on the time-integral of balance. Each user keeps an
///         append-only checkpoint history of that integral.
contract CheckpointDeposits {
    uint256 private constant SCALE = 1e18;
    uint256 private constant REWARD_PER_SEC = 2e9;

    struct Checkpoint {
        uint64 at;
        uint192 integral;
    }

    IERC20 public immutable token;
    address public immutable admin;

    mapping(address => uint256) public balances;
    mapping(address => Checkpoint[]) public history;
    mapping(address => uint256) public claimedIntegral;
    uint256 public totalDeposits;
    uint256 public rewardsPaid;

    event Deposited(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardClaimed(address indexed user, uint256 amount);

    constructor(IERC20 _token) {
        token = _token;
        admin = msg.sender;
    }

    /// @dev Appends a checkpoint carrying the integral up to now, using the balance
    ///      in force since the previous checkpoint.
    function _checkpoint(address user) internal {
        Checkpoint[] storage h = history[user];
        if (h.length == 0) {
            h.push(Checkpoint(uint64(block.timestamp), 0));
            return;
        }
        Checkpoint storage last = h[h.length - 1];
        uint256 dt = block.timestamp - last.at;
        if (dt == 0) return;
        uint256 next = uint256(last.integral) + (balances[user] * dt);
        h.push(Checkpoint(uint64(block.timestamp), uint192(next)));
    }

    function _latestIntegral(address user) internal view returns (uint256) {
        Checkpoint[] storage h = history[user];
        if (h.length == 0) return 0;
        return h[h.length - 1].integral;
    }

    function deposit(uint256 amount) external {
        require(amount > 0, "zero");
        _checkpoint(msg.sender);
        balances[msg.sender] += amount;
        totalDeposits += amount;
        require(token.transferFrom(msg.sender, address(this), amount), "transferFrom");
        emit Deposited(msg.sender, amount);
    }

    function withdraw(uint256 amount) external {
        _checkpoint(msg.sender);
        require(balances[msg.sender] >= amount, "balance");
        balances[msg.sender] -= amount;
        totalDeposits -= amount;
        require(token.transfer(msg.sender, amount), "transfer");
        emit Withdrawn(msg.sender, amount);
    }

    function claimRewards() external returns (uint256 owed) {
        _checkpoint(msg.sender);
        uint256 integral = _latestIntegral(msg.sender);
        owed = ((integral - claimedIntegral[msg.sender]) * REWARD_PER_SEC) / SCALE;
        claimedIntegral[msg.sender] = integral;
        rewardsPaid += owed;
        emit RewardClaimed(msg.sender, owed);
    }
}
