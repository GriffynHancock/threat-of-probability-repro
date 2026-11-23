// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @title StakeForFees
/// @notice Stakers receive a pro-rata share of protocol fee revenue. Anyone may stake on behalf of a beneficiary.
contract StakeForFees {
    error ZeroAmount();
    error InsufficientStake(uint256 have, uint256 want);
    error TransferFailed();

    uint256 private constant ACC = 1e18;

    IERC20 public immutable stakeToken;
    IERC20 public immutable feeToken;

    uint256 public totalStaked;
    uint256 public feeAccPerShare;

    mapping(address => uint256) public stakedOf;
    mapping(address => uint256) public rewardDebtOf;
    mapping(address => uint256) public pendingFees;

    event FeesReceived(uint256 amount);
    event StakedFor(address indexed payer, address indexed beneficiary, uint256 amount);
    event Unstaked(address indexed user, uint256 amount);
    event FeesHarvested(address indexed user, uint256 amount);

    constructor(IERC20 _stake, IERC20 _fee) {
        stakeToken = _stake;
        feeToken = _fee;
    }

    function notifyFees(uint256 amount) external {
        if (totalStaked == 0) revert ZeroAmount();
        if (!feeToken.transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
        feeAccPerShare += (amount * ACC) / totalStaked;
        emit FeesReceived(amount);
    }

    function _settleStaker(address who) internal {
        uint256 shares = stakedOf[who];
        if (shares > 0) {
            pendingFees[who] += (shares * (feeAccPerShare - rewardDebtOf[who])) / ACC;
        }
        rewardDebtOf[who] = feeAccPerShare;
    }

    /// @notice Stake tokens into `beneficiary`'s position.
    function stakeFor(address beneficiary, uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        _settleStaker(beneficiary);
        stakedOf[beneficiary] += amount;
        totalStaked += amount;
        if (!stakeToken.transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
        emit StakedFor(msg.sender, beneficiary, amount);
    }

    /// @notice Unstake up to the caller's balance.
    function unstake(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        _settleStaker(msg.sender);
        uint256 have = stakedOf[msg.sender];
        if (have < amount) revert InsufficientStake(have, amount);
        stakedOf[msg.sender] -= amount;
        totalStaked -= amount;
        if (!stakeToken.transfer(msg.sender, amount)) revert TransferFailed();
        emit Unstaked(msg.sender, amount);
    }

    /// @notice Harvest accrued fee share.
    function harvest() external {
        _settleStaker(msg.sender);
        uint256 amount = pendingFees[msg.sender];
        if (amount == 0) revert ZeroAmount();
        pendingFees[msg.sender] = 0;
        if (!feeToken.transfer(msg.sender, amount)) revert TransferFailed();
        emit FeesHarvested(msg.sender, amount);
    }
}
