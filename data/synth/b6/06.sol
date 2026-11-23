// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @notice Points programme layered on deposits. Points accrue per token-second and convert to rewards.
contract PointsOnDepositLedger {
    uint256 private constant PRECISION = 1e18;
    uint256 public constant POINTS_RATE = 1e12;
    uint256 public constant POINTS_PER_REWARD = 1000;

    struct Account {
        uint256 deposited;
        uint256 points;
        uint256 lastCheckpoint;
        uint256 rewardsOwed;
    }

    IERC20 public immutable token;
    address public immutable steward;
    uint256 public totalDeposited;
    uint256 public rewardReserve;

    mapping(address => Account) public accounts;

    event DepositedForPoints(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event PointsConverted(address indexed user, uint256 points, uint256 rewards);
    event RewardsClaimed(address indexed user, uint256 amount);
    event RewardsFunded(uint256 amount);

    constructor(IERC20 _token) {
        token = _token;
        steward = msg.sender;
    }

    function fundRewards(uint256 amount) external {
        require(msg.sender == steward, "not steward");
        rewardReserve += amount;
        require(token.transferFrom(msg.sender, address(this), amount), "pull");
        emit RewardsFunded(amount);
    }

    function pointsOf(address user) public view returns (uint256) {
        Account storage a = accounts[user];
        uint256 dt = block.timestamp - a.lastCheckpoint;
        return a.points + (a.deposited * dt * POINTS_RATE) / PRECISION;
    }

    function _checkpointPoints(address who) internal {
        Account storage a = accounts[who];
        uint256 dt = block.timestamp - a.lastCheckpoint;
        if (dt > 0 && a.deposited > 0) {
            a.points += (a.deposited * dt * POINTS_RATE) / PRECISION;
        }
        a.lastCheckpoint = block.timestamp;
    }

    function stakeForPoints(uint256 amount) external {
        require(amount > 0, "zero");
        _checkpointPoints(msg.sender);
        Account storage a = accounts[msg.sender];
        a.deposited += amount;
        totalDeposited += amount;
        emit DepositedForPoints(msg.sender, amount);
        require(token.transferFrom(msg.sender, address(this), amount), "pull");
    }

    function withdrawDeposit(uint256 amount) external {
        _checkpointPoints(msg.sender);
        Account storage a = accounts[msg.sender];
        require(a.deposited >= amount, "insufficient");
        a.deposited -= amount;
        totalDeposited -= amount;
        emit Withdrawn(msg.sender, amount);
        require(token.transfer(msg.sender, amount), "xfer");
    }

    function convertPoints(uint256 pts) external returns (uint256 rewards) {
        _checkpointPoints(msg.sender);
        Account storage a = accounts[msg.sender];
        rewards = pts / POINTS_PER_REWARD;
        require(rewards > 0, "too few points");
        uint256 burned = rewards * POINTS_PER_REWARD;
        require(a.points >= burned, "points");
        a.points -= burned;
        a.rewardsOwed += rewards;
        emit PointsConverted(msg.sender, burned, rewards);
    }

    function claimRewards() external returns (uint256 amount) {
        Account storage a = accounts[msg.sender];
        amount = a.rewardsOwed;
        require(amount > 0, "none");
        require(amount <= rewardReserve, "reserve");
        a.rewardsOwed = 0;
        rewardReserve -= amount;
        emit RewardsClaimed(msg.sender, amount);
        require(token.transfer(msg.sender, amount), "xfer");
    }
}
