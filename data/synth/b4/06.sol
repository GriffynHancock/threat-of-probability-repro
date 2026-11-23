// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @title ValidatorDelegation
/// @notice Delegators back a validator. Slashing scales principal down via a global index;
///         rewards accrue on a reward index. Unbonding is slash-adjusted and delayed.
contract ValidatorDelegation {
    uint256 private constant PRECISION = 1e18;
    uint256 private constant BPS = 10_000;
    uint256 private constant UNBOND_PERIOD = 14 days;

    IERC20 public immutable stakeToken;
    address public immutable operator;

    uint256 public slashIndex = PRECISION;
    uint256 public rewardIndex;
    uint256 public totalDelegated;

    struct Delegation {
        uint256 principal;
        uint256 slashSnapshot;
        uint256 rewardDebt;
        uint256 rewards;
    }

    struct Unbond {
        uint256 amount;
        uint256 slashSnapshot;
        uint256 availableAt;
    }

    mapping(address => Delegation) public delegations;
    mapping(address => Unbond) public pendingUnbond;

    event Delegated(address indexed who, uint256 amount);
    event UnbondRequested(address indexed who, uint256 amount, uint256 availableAt);
    event Unbonded(address indexed who, uint256 amount);
    event Slashed(uint256 bps, uint256 newIndex);
    event RewardsClaimed(address indexed who, uint256 amount);

    constructor(IERC20 _token) {
        stakeToken = _token;
        operator = msg.sender;
    }

    function slash(uint256 bps) external {
        require(msg.sender == operator, "not operator");
        require(bps < BPS, "bad bps");
        slashIndex = (slashIndex * (BPS - bps)) / BPS;
        emit Slashed(bps, slashIndex);
    }

    function distributeRewards(uint256 amount) external {
        require(totalDelegated > 0, "no delegation");
        require(stakeToken.transferFrom(msg.sender, address(this), amount), "transfer failed");
        rewardIndex += (amount * PRECISION) / totalDelegated;
    }

    function _rebaseDelegator(address who) internal {
        Delegation storage d = delegations[who];
        if (d.principal > 0) {
            d.rewards += (d.principal * (rewardIndex - d.rewardDebt)) / PRECISION;
            if (d.slashSnapshot != 0 && d.slashSnapshot != slashIndex) {
                uint256 newPrincipal = (d.principal * slashIndex) / d.slashSnapshot;
                totalDelegated = totalDelegated - d.principal + newPrincipal;
                d.principal = newPrincipal;
            }
        }
        d.rewardDebt = rewardIndex;
        d.slashSnapshot = slashIndex;
    }

    /// @notice Delegate stake to the validator.
    function delegate(uint256 amount) external {
        require(amount > 0, "zero amount");
        _rebaseDelegator(msg.sender);
        Delegation storage d = delegations[msg.sender];
        d.principal += amount;
        totalDelegated += amount;
        require(stakeToken.transferFrom(msg.sender, address(this), amount), "transfer failed");
        emit Delegated(msg.sender, amount);
    }

    /// @notice Begin unbonding. Amount is frozen against the current slash index.
    function requestUndelegate(uint256 amount) external {
        _rebaseDelegator(msg.sender);
        Delegation storage d = delegations[msg.sender];
        require(d.principal >= amount, "not enough");
        d.principal -= amount;
        totalDelegated -= amount;

        Unbond storage u = pendingUnbond[msg.sender];
        if (u.amount > 0) {
            u.amount = (u.amount * slashIndex) / u.slashSnapshot;
        }
        u.amount += amount;
        u.slashSnapshot = slashIndex;
        u.availableAt = block.timestamp + UNBOND_PERIOD;
        emit UnbondRequested(msg.sender, amount, u.availableAt);
    }

    /// @notice Complete unbonding after the delay; returns slash-adjusted amount.
    function completeUndelegate() external {
        _rebaseDelegator(msg.sender);
        Unbond storage u = pendingUnbond[msg.sender];
        require(u.amount > 0 && block.timestamp >= u.availableAt, "not matured");
        uint256 out = (u.amount * slashIndex) / u.slashSnapshot;
        u.amount = 0;
        require(stakeToken.transfer(msg.sender, out), "transfer failed");
        emit Unbonded(msg.sender, out);
    }

    /// @notice Claim accrued rewards.
    function claimRewards() external {
        _rebaseDelegator(msg.sender);
        Delegation storage d = delegations[msg.sender];
        uint256 amount = d.rewards;
        require(amount > 0, "nothing to claim");
        d.rewards = 0;
        require(stakeToken.transfer(msg.sender, amount), "transfer failed");
        emit RewardsClaimed(msg.sender, amount);
    }
}
