// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @title MultiRewardStakingPool
/// @notice Stakes a single token and streams a list of reward tokens pro rata.
/// @dev Each reward token has its own cumulative per-token accumulator. Users
///      carry a per-reward "paid" checkpoint and an "owed" balance.
contract MultiRewardStakingPool {
    uint256 public constant PRECISION = 1e18;

    IERC20 public immutable stakingToken;
    address public owner;
    uint256 public lastUpdate;
    uint256 public totalStaked;

    IERC20[] public rewardTokens;
    uint256[] public rewardRates; // reward units per second, whole pool
    uint256[] public rewardPerTokenStored; // scaled by PRECISION

    mapping(address => uint256) public stakedBalance;
    mapping(address => mapping(uint256 => uint256)) public rewardPaid;
    mapping(address => mapping(uint256 => uint256)) public rewardOwed;

    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardClaimed(address indexed user, uint256 indexed rewardIndex, uint256 amount);
    event RateUpdated(uint256 indexed rewardIndex, uint256 newRate);

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    constructor(IERC20 _stakingToken, IERC20[] memory _tokens, uint256[] memory _rates) {
        require(_tokens.length == _rates.length, "length mismatch");
        stakingToken = _stakingToken;
        owner = msg.sender;
        lastUpdate = block.timestamp;
        for (uint256 i = 0; i < _tokens.length; i++) {
            rewardTokens.push(_tokens[i]);
            rewardRates.push(_rates[i]);
            rewardPerTokenStored.push(0);
        }
    }

    function deposit(uint256 amount) external {
        _settleUser(msg.sender);
        require(amount > 0, "zero amount");
        require(stakingToken.transferFrom(msg.sender, address(this), amount), "transfer failed");
        stakedBalance[msg.sender] += amount;
        totalStaked += amount;
        emit Staked(msg.sender, amount);
    }

    function withdraw(uint256 amount) external {
        _settleUser(msg.sender);
        require(amount > 0 && amount <= stakedBalance[msg.sender], "bad amount");
        stakedBalance[msg.sender] -= amount;
        totalStaked -= amount;
        require(stakingToken.transfer(msg.sender, amount), "transfer failed");
        emit Withdrawn(msg.sender, amount);
    }

    function claimAll() external {
        _settleUser(msg.sender);
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            uint256 owed = rewardOwed[msg.sender][i];
            if (owed == 0) continue;
            rewardOwed[msg.sender][i] = 0;
            require(rewardTokens[i].transfer(msg.sender, owed), "reward transfer failed");
            emit RewardClaimed(msg.sender, i, owed);
        }
    }

    function setRate(uint256 index, uint256 newRate) external onlyOwner {
        _updateGlobal();
        rewardRates[index] = newRate;
        emit RateUpdated(index, newRate);
    }

    /// @notice View of what a user would hold for one reward index right now.
    function pending(address who, uint256 i) external view returns (uint256) {
        uint256 stored = rewardPerTokenStored[i];
        if (block.timestamp > lastUpdate && totalStaked > 0) {
            stored += rewardRates[i] * (block.timestamp - lastUpdate) * PRECISION / totalStaked;
        }
        return rewardOwed[who][i] + stakedBalance[who] * (stored - rewardPaid[who][i]) / PRECISION;
    }

    /// @dev Settlement: advance every accumulator, then credit the user's
    ///      accrual at their CURRENT balance. Must run before any balance change.
    function _settleUser(address who) internal {
        _updateGlobal();
        uint256 bal = stakedBalance[who];
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            uint256 accrued = bal * (rewardPerTokenStored[i] - rewardPaid[who][i]) / PRECISION;
            rewardOwed[who][i] += accrued;
            rewardPaid[who][i] = rewardPerTokenStored[i];
        }
    }

    function _updateGlobal() internal {
        uint256 elapsed = block.timestamp - lastUpdate;
        lastUpdate = block.timestamp;
        if (elapsed == 0 || totalStaked == 0) return;
        for (uint256 i = 0; i < rewardRates.length; i++) {
            rewardPerTokenStored[i] += rewardRates[i] * elapsed * PRECISION / totalStaked;
        }
    }
}
