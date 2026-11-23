// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @title TimeDecayedVotePower
/// @notice Votes decay linearly over DECAY_WINDOW since the last refresh; principal earns rewards.
contract TimeDecayedVotePower {
    uint256 private constant PRECISION = 1e18;
    uint256 public constant DECAY_WINDOW = 90 days;

    struct Ballot {
        uint128 principal;
        uint128 weight;
        uint64 stamp;
        uint256 rewardDebt;
        uint256 rewards;
    }

    IERC20 public immutable token;
    address public immutable admin;
    uint256 public totalPrincipal;
    uint256 public rewardIndex;

    mapping(address => Ballot) public ballots;

    event Pledged(address indexed who, uint256 amount);
    event Retracted(address indexed who, uint256 amount);
    event RewardsDistributed(uint256 amount);
    event RewardsClaimed(address indexed who, uint256 amount);

    constructor(IERC20 _token) {
        token = _token;
        admin = msg.sender;
    }

    function distribute(uint256 amount) external {
        require(msg.sender == admin, "not admin");
        require(totalPrincipal > 0, "no principal");
        require(token.transferFrom(msg.sender, address(this), amount), "transfer failed");
        rewardIndex += (amount * PRECISION) / totalPrincipal;
        emit RewardsDistributed(amount);
    }

    /// @dev Decays weight to now and settles rewards on principal.
    function _refreshWeight(address who) internal {
        Ballot storage b = ballots[who];
        if (b.principal > 0) {
            b.rewards += (uint256(b.principal) * (rewardIndex - b.rewardDebt)) / PRECISION;
        }
        b.rewardDebt = rewardIndex;
        uint256 elapsed = block.timestamp - b.stamp;
        if (b.stamp != 0 && b.weight > 0) {
            if (elapsed >= DECAY_WINDOW) {
                b.weight = 0;
            } else {
                b.weight = uint128((uint256(b.weight) * (DECAY_WINDOW - elapsed)) / DECAY_WINDOW);
            }
        }
        b.stamp = uint64(block.timestamp);
    }

    /// @notice Current voting weight, computed without writing state.
    function currentWeight(address who) public view returns (uint256) {
        Ballot storage b = ballots[who];
        if (b.stamp == 0 || b.weight == 0) return 0;
        uint256 elapsed = block.timestamp - b.stamp;
        if (elapsed >= DECAY_WINDOW) return 0;
        return (uint256(b.weight) * (DECAY_WINDOW - elapsed)) / DECAY_WINDOW;
    }

    /// @notice Pledge tokens; they count toward voting weight at full value, decaying over time.
    function pledge(uint256 amount) external {
        require(amount > 0, "zero amount");
        _refreshWeight(msg.sender);
        Ballot storage b = ballots[msg.sender];
        b.principal += uint128(amount);
        b.weight += uint128(amount);
        totalPrincipal += amount;
        require(token.transferFrom(msg.sender, address(this), amount), "transfer failed");
        emit Pledged(msg.sender, amount);
    }

    /// @notice Retract principal and its weight.
    function retract(uint256 amount) external {
        _refreshWeight(msg.sender);
        Ballot storage b = ballots[msg.sender];
        require(b.principal >= amount, "insufficient principal");
        b.principal -= uint128(amount);
        b.weight = amount >= b.weight ? 0 : uint128(uint256(b.weight) - amount);
        totalPrincipal -= amount;
        require(token.transfer(msg.sender, amount), "transfer failed");
        emit Retracted(msg.sender, amount);
    }

    /// @notice Claim rewards earned on principal.
    function claimShare() external {
        _refreshWeight(msg.sender);
        Ballot storage b = ballots[msg.sender];
        uint256 amount = b.rewards;
        require(amount > 0, "nothing to claim");
        b.rewards = 0;
        require(token.transfer(msg.sender, amount), "transfer failed");
        emit RewardsClaimed(msg.sender, amount);
    }
}
