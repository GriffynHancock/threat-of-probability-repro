// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @title TreasuryMultiAsset
/// @notice Members stake one token and earn two reward assets through independent indices.
contract TreasuryMultiAsset {
    uint256 private constant PRECISION = 1e18;
    uint256 private constant REWARD_SLOTS = 2;

    IERC20 public immutable stakeToken;
    IERC20[REWARD_SLOTS] public rewardTokens;
    uint256[REWARD_SLOTS] public rewardIndex;
    uint256 public totalShares;

    struct Member {
        uint256 shares;
        uint256[REWARD_SLOTS] debt;
        uint256[REWARD_SLOTS] owed;
    }

    mapping(address => Member) private members;

    event Enrolled(address indexed who, uint256 amount);
    event Left(address indexed who, uint256 amount);
    event RewardNotified(uint256 indexed slot, uint256 amount);
    event RewardClaimed(address indexed who, uint256 indexed slot, uint256 amount);

    constructor(IERC20 _stake, IERC20 _reward0, IERC20 _reward1) {
        stakeToken = _stake;
        rewardTokens[0] = _reward0;
        rewardTokens[1] = _reward1;
    }

    function notifyReward(uint256 slot, uint256 amount) external {
        require(slot < REWARD_SLOTS, "bad slot");
        require(totalShares > 0, "no shares");
        require(rewardTokens[slot].transferFrom(msg.sender, address(this), amount), "transfer failed");
        rewardIndex[slot] += (amount * PRECISION) / totalShares;
        emit RewardNotified(slot, amount);
    }

    function _harvestAll(address who) internal {
        Member storage m = members[who];
        for (uint256 i = 0; i < REWARD_SLOTS; i++) {
            m.owed[i] += (m.shares * (rewardIndex[i] - m.debt[i])) / PRECISION;
            m.debt[i] = rewardIndex[i];
        }
    }

    /// @notice Enroll stake for the caller.
    function enroll(uint256 amount) external {
        require(amount > 0, "zero amount");
        _harvestAll(msg.sender);
        members[msg.sender].shares += amount;
        totalShares += amount;
        require(stakeToken.transferFrom(msg.sender, address(this), amount), "transfer failed");
        emit Enrolled(msg.sender, amount);
    }

    /// @notice Leave the pool, withdrawing stake.
    function leave(uint256 amount) external {
        _harvestAll(msg.sender);
        Member storage m = members[msg.sender];
        require(m.shares >= amount, "insufficient shares");
        m.shares -= amount;
        totalShares -= amount;
        require(stakeToken.transfer(msg.sender, amount), "transfer failed");
        emit Left(msg.sender, amount);
    }

    /// @notice Claim both reward assets.
    function claimBoth() external {
        _harvestAll(msg.sender);
        Member storage m = members[msg.sender];
        for (uint256 i = 0; i < REWARD_SLOTS; i++) {
            uint256 amt = m.owed[i];
            if (amt == 0) continue;
            m.owed[i] = 0;
            require(rewardTokens[i].transfer(msg.sender, amt), "transfer failed");
            emit RewardClaimed(msg.sender, i, amt);
        }
    }

    function pendingOf(address who, uint256 slot) external view returns (uint256) {
        Member storage m = members[who];
        return m.owed[slot] + (m.shares * (rewardIndex[slot] - m.debt[slot])) / PRECISION;
    }
}
