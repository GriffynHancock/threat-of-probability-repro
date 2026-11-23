// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @notice Weekly-epoch staking. Rewards accrue in whole epochs, settled before any stake change.
contract EpochStakeReward {
    error ZeroAmount();
    error InsufficientStake(uint256 have, uint256 want);
    error NothingToClaim();

    uint256 private constant PRECISION = 1e18;
    uint256 public constant EPOCH = 7 days;

    IERC20 public immutable token;
    uint256 public immutable rewardPerTokenEpoch;

    struct Account {
        uint256 staked;
        uint256 reward;
        uint256 lastEpoch;
    }
    mapping(address => Account) public accounts;
    uint256 public totalStaked;

    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount);
    event Claimed(address indexed user, uint256 amount);

    constructor(IERC20 _token, uint256 _rewardPerTokenEpoch) {
        token = _token;
        rewardPerTokenEpoch = _rewardPerTokenEpoch;
    }

    /// @dev Credits whole elapsed epochs at the current stake.
    function _syncStake(address who) internal {
        Account storage a = accounts[who];
        uint256 nowEpoch = block.timestamp / EPOCH;
        if (a.lastEpoch == 0) {
            a.lastEpoch = nowEpoch;
            return;
        }
        if (nowEpoch > a.lastEpoch) {
            uint256 elapsed = nowEpoch - a.lastEpoch;
            a.reward += (a.staked * rewardPerTokenEpoch * elapsed) / PRECISION;
            a.lastEpoch = nowEpoch;
        }
    }

    function stake(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        _syncStake(msg.sender);
        Account storage a = accounts[msg.sender];
        a.staked += amount;
        totalStaked += amount;
        require(token.transferFrom(msg.sender, address(this), amount), "pull failed");
        emit Staked(msg.sender, amount);
    }

    function unstake(uint256 amount) external {
        _syncStake(msg.sender);
        Account storage a = accounts[msg.sender];
        if (a.staked < amount) revert InsufficientStake(a.staked, amount);
        a.staked -= amount;
        totalStaked -= amount;
        require(token.transfer(msg.sender, amount), "push failed");
        emit Unstaked(msg.sender, amount);
    }

    function claim() external {
        _syncStake(msg.sender);
        Account storage a = accounts[msg.sender];
        uint256 amount = a.reward;
        if (amount == 0) revert NothingToClaim();
        a.reward = 0;
        require(token.transfer(msg.sender, amount), "push failed");
        emit Claimed(msg.sender, amount);
    }
}
