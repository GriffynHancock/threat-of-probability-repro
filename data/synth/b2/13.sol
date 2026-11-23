// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @notice Two-token pair farm. Users deposit both sides of a pair; each side
/// has its own emission accumulator weighted by that side's total deposits.
contract TwoSidedPairFarm {
    uint256 private constant P = 1e18;

    struct Stake {
        uint256 amountA;
        uint256 amountB;
        uint256 rptA;
        uint256 rptB;
        uint256 owedA;
        uint256 owedB;
    }

    IERC20 public immutable tokenA;
    IERC20 public immutable tokenB;
    IERC20 public immutable rewardA;
    IERC20 public immutable rewardB;
    address public immutable treasury;

    uint256 public totalA;
    uint256 public totalB;
    uint256 public rptA;
    uint256 public rptB;
    uint256 public rateA;
    uint256 public rateB;
    uint256 public lastAccrue;

    mapping(address => Stake) public stakes;

    event StakedPair(address indexed who, uint256 a, uint256 b);
    event UnstakedPair(address indexed who, uint256 a, uint256 b);
    event PairRewardClaimed(address indexed who, uint256 ra, uint256 rb);

    constructor(IERC20 a, IERC20 b, IERC20 ra, IERC20 rb, uint256 _rateA, uint256 _rateB) {
        tokenA = a;
        tokenB = b;
        rewardA = ra;
        rewardB = rb;
        rateA = _rateA;
        rateB = _rateB;
        treasury = msg.sender;
        lastAccrue = block.timestamp;
    }

    function stakeBoth(uint256 a, uint256 b) external {
        require(a > 0 && b > 0, "both sides required");
        _accruePair(msg.sender);
        Stake storage s = stakes[msg.sender];
        s.amountA += a;
        s.amountB += b;
        totalA += a;
        totalB += b;
        require(tokenA.transferFrom(msg.sender, address(this), a), "transfer A failed");
        require(tokenB.transferFrom(msg.sender, address(this), b), "transfer B failed");
        emit StakedPair(msg.sender, a, b);
    }

    function unstakeBoth(uint256 a, uint256 b) external {
        Stake storage s = stakes[msg.sender];
        require(a <= s.amountA && b <= s.amountB, "too much");
        _accruePair(msg.sender);
        s.amountA -= a;
        s.amountB -= b;
        totalA -= a;
        totalB -= b;
        require(tokenA.transfer(msg.sender, a), "transfer A failed");
        require(tokenB.transfer(msg.sender, b), "transfer B failed");
        emit UnstakedPair(msg.sender, a, b);
    }

    function claimPairRewards() external {
        _accruePair(msg.sender);
        Stake storage s = stakes[msg.sender];
        uint256 ra = s.owedA;
        uint256 rb = s.owedB;
        s.owedA = 0;
        s.owedB = 0;
        if (ra > 0) require(rewardA.transfer(msg.sender, ra), "reward A failed");
        if (rb > 0) require(rewardB.transfer(msg.sender, rb), "reward B failed");
        emit PairRewardClaimed(msg.sender, ra, rb);
    }

    /// @dev Moves both accumulators to now, then books the caller's side-specific
    /// rewards against the amounts held before this call.
    function _accruePair(address who) internal {
        uint256 dt = block.timestamp - lastAccrue;
        if (dt > 0) {
            if (totalA > 0) rptA += dt * rateA * P / totalA;
            if (totalB > 0) rptB += dt * rateB * P / totalB;
            lastAccrue = block.timestamp;
        }
        Stake storage s = stakes[who];
        s.owedA += s.amountA * (rptA - s.rptA) / P;
        s.owedB += s.amountB * (rptB - s.rptB) / P;
        s.rptA = rptA;
        s.rptB = rptB;
    }
}
