// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

interface IERC20 {
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
}

contract BlockStakePool {
    struct Staker {
        uint256 amount;
        uint256 rewardDebt;
    }

    uint256 private constant ACC_PRECISION = 1e12;

    IERC20 public immutable stakeToken;
    IERC20 public immutable rewardToken;
    address public owner;

    uint256 public rewardPerBlock;
    uint256 public lastRewardBlock;
    uint256 public accRewardPerShare;
    uint256 public totalStaked;

    mapping(address => Staker) public stakers;

    event Deposit(address indexed user, uint256 amount);
    event Withdraw(address indexed user, uint256 amount);
    event Harvest(address indexed user, uint256 reward);
    event RewardPerBlockSet(uint256 rewardPerBlock);

    constructor(IERC20 _stakeToken, IERC20 _rewardToken, uint256 _rewardPerBlock) {
        require(address(_stakeToken) != address(0) && address(_rewardToken) != address(0), "zero token");
        stakeToken = _stakeToken;
        rewardToken = _rewardToken;
        owner = msg.sender;
        rewardPerBlock = _rewardPerBlock;
        lastRewardBlock = block.number;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    // Settlement: bring the pool-level accumulator up to the current block.
    function _updatePool() internal {
        if (block.number <= lastRewardBlock) {
            return;
        }
        if (totalStaked == 0) {
            lastRewardBlock = block.number;
            return;
        }
        uint256 elapsed = block.number - lastRewardBlock;
        accRewardPerShare += (elapsed * rewardPerBlock * ACC_PRECISION) / totalStaked;
        lastRewardBlock = block.number;
    }

    function _pendingOf(Staker storage s) internal view returns (uint256) {
        return (s.amount * accRewardPerShare) / ACC_PRECISION - s.rewardDebt;
    }

    function _payReward(address to, uint256 amount) internal {
        require(rewardToken.transfer(to, amount), "reward transfer failed");
    }

    function pendingReward(address user) external view returns (uint256) {
        Staker storage s = stakers[user];
        uint256 acc = accRewardPerShare;
        if (block.number > lastRewardBlock && totalStaked != 0) {
            uint256 elapsed = block.number - lastRewardBlock;
            acc += (elapsed * rewardPerBlock * ACC_PRECISION) / totalStaked;
        }
        return (s.amount * acc) / ACC_PRECISION - s.rewardDebt;
    }

    function deposit(uint256 amount) external {
        require(amount > 0, "amount is zero");
        _updatePool();
        Staker storage s = stakers[msg.sender];
        uint256 pending = _pendingOf(s);

        s.amount += amount;
        totalStaked += amount;
        s.rewardDebt = (s.amount * accRewardPerShare) / ACC_PRECISION;

        require(stakeToken.transferFrom(msg.sender, address(this), amount), "stake transfer failed");
        if (pending > 0) {
            _payReward(msg.sender, pending);
        }
        emit Deposit(msg.sender, amount);
    }

    function withdraw(uint256 amount) external {
        Staker storage s = stakers[msg.sender];
        require(amount > 0 && s.amount >= amount, "bad amount");
        _updatePool();
        uint256 pending = _pendingOf(s);

        s.amount -= amount;
        totalStaked -= amount;
        s.rewardDebt = (s.amount * accRewardPerShare) / ACC_PRECISION;

        require(stakeToken.transfer(msg.sender, amount), "stake return failed");
        if (pending > 0) {
            _payReward(msg.sender, pending);
        }
        emit Withdraw(msg.sender, amount);
    }

    function harvest() external {
        _updatePool();
        Staker storage s = stakers[msg.sender];
        uint256 pending = _pendingOf(s);
        require(pending > 0, "nothing to harvest");

        s.rewardDebt = (s.amount * accRewardPerShare) / ACC_PRECISION;
        _payReward(msg.sender, pending);
        emit Harvest(msg.sender, pending);
    }

    function setRewardPerBlock(uint256 newRate) external onlyOwner {
        _updatePool();
        rewardPerBlock = newRate;
        emit RewardPerBlockSet(newRate);
    }
}
