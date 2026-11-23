// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.19;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
}

/// @title DaoContributionRewards
/// @notice Governor-granted attestations let contributors convert work into points; points earn an epoch reward.
contract DaoContributionRewards {
    error NotGovernor();
    error NoPoints();
    error NothingOwed();
    error NotAttested(uint256 have, uint256 want);
    error TransferFailed();

    uint256 private constant PRECISION = 1e18;

    struct Contributor {
        uint128 points;
        uint128 epochSeen;
        uint256 rewardOwed;
    }

    IERC20 public immutable rewardToken;
    address public immutable governor;
    uint256 public rewardPerEpoch;
    uint256 public currentEpoch;
    uint256 public pointsThisEpoch;

    mapping(address => Contributor) private contributors;
    mapping(address => uint256) public attestation;
    mapping(uint256 => uint256) public epochRatePerPoint;

    event Attested(address indexed who, uint256 units);
    event Contributed(address indexed who, uint256 points, uint256 epoch);
    event EpochClosed(uint256 indexed epoch, uint256 ratePerPoint);
    event RewardsClaimed(address indexed who, uint256 amount);

    modifier onlyGovernor() {
        if (msg.sender != governor) revert NotGovernor();
        _;
    }

    constructor(IERC20 _token, uint256 _rewardPerEpoch) {
        rewardToken = _token;
        governor = msg.sender;
        rewardPerEpoch = _rewardPerEpoch;
    }

    function grantAttestation(address who, uint256 units) external onlyGovernor {
        attestation[who] += units;
        emit Attested(who, units);
    }

    function closeEpoch() external onlyGovernor {
        uint256 rate = pointsThisEpoch == 0 ? 0 : (rewardPerEpoch * PRECISION) / pointsThisEpoch;
        epochRatePerPoint[currentEpoch] = rate;
        emit EpochClosed(currentEpoch, rate);
        currentEpoch += 1;
        pointsThisEpoch = 0;
    }

    function _finalizeEpochFor(address who) internal {
        Contributor storage c = contributors[who];
        if (c.epochSeen < currentEpoch && c.points > 0) {
            c.rewardOwed += (uint256(c.points) * epochRatePerPoint[c.epochSeen]) / PRECISION;
        }
        c.points = 0;
        c.epochSeen = uint128(currentEpoch);
    }

    /// @notice Convert attested units into points for the current epoch.
    function contribute(uint256 points) external {
        if (points == 0) revert NoPoints();
        uint256 have = attestation[msg.sender];
        if (have < points) revert NotAttested(have, points);
        _finalizeEpochFor(msg.sender);
        Contributor storage c = contributors[msg.sender];
        c.points += uint128(points);
        attestation[msg.sender] -= points;
        pointsThisEpoch += points;
        emit Contributed(msg.sender, points, currentEpoch);
    }

    /// @notice Pay out owed rewards and revoke any unused attestation.
    function exit() external {
        _finalizeEpochFor(msg.sender);
        uint256 unused = attestation[msg.sender];
        attestation[msg.sender] -= unused;
        Contributor storage c = contributors[msg.sender];
        uint256 amount = c.rewardOwed;
        c.rewardOwed -= amount;
        if (amount > 0 && !rewardToken.transfer(msg.sender, amount)) revert TransferFailed();
        emit RewardsClaimed(msg.sender, amount);
    }

    /// @notice Claim rewards for finished epochs.
    function claimRewards() external {
        _finalizeEpochFor(msg.sender);
        Contributor storage c = contributors[msg.sender];
        uint256 amount = c.rewardOwed;
        if (amount == 0) revert NothingOwed();
        c.rewardOwed = 0;
        if (!rewardToken.transfer(msg.sender, amount)) revert TransferFailed();
        emit RewardsClaimed(msg.sender, amount);
    }
}
