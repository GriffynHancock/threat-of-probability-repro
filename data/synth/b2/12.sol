// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @notice Time-weighted fee sharing. Each unit of liquidity accumulates
/// "seconds per liquidity" while staked; fees are split by each user's share
/// of that accumulator over the window they were in the pool.
contract TimeWeightedFeeShare {
    uint256 private constant SCALE = 1e18;

    IERC20 public immutable liquidityToken;
    IERC20 public immutable feeToken;

    uint256 public totalLiquidity;
    uint256 public lastTick;
    uint256 public secondsPerLiquidity;
    uint256 public feeReservoir;

    mapping(address => uint256) public liquidity;
    mapping(address => uint256) public secondsPerLiquidityPaid;
    mapping(address => uint256) public feeClaimable;

    event Tick(uint256 timestamp, uint256 totalLiquidity);
    event Supplied(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event FeesClaimed(address indexed user, uint256 amount);
    event FeesDeposited(uint256 amount, uint256 reservoir);

    constructor(IERC20 _liquidity, IERC20 _fee) {
        liquidityToken = _liquidity;
        feeToken = _fee;
        lastTick = block.timestamp;
    }

    function depositFees(uint256 amount) external {
        require(feeToken.transferFrom(msg.sender, address(this), amount), "transfer failed");
        feeReservoir += amount;
        emit FeesDeposited(amount, feeReservoir);
    }

    function supply(uint256 amount) external {
        require(amount > 0, "zero amount");
        _tickTo(msg.sender);
        liquidity[msg.sender] += amount;
        totalLiquidity += amount;
        require(liquidityToken.transferFrom(msg.sender, address(this), amount), "transfer failed");
        emit Supplied(msg.sender, amount);
    }

    function withdraw(uint256 amount) external {
        require(amount <= liquidity[msg.sender], "insufficient liquidity");
        _tickTo(msg.sender);
        liquidity[msg.sender] -= amount;
        totalLiquidity -= amount;
        require(liquidityToken.transfer(msg.sender, amount), "transfer failed");
        emit Withdrawn(msg.sender, amount);
    }

    /// @notice Converts the user's time-weighted share of the reservoir into a claim.
    function claimFees() external {
        _tickTo(msg.sender);
        uint256 amount = feeClaimable[msg.sender];
        if (amount == 0) return;
        feeClaimable[msg.sender] = 0;
        require(feeToken.transfer(msg.sender, amount), "transfer failed");
        emit FeesClaimed(msg.sender, amount);
    }

    /// @dev Advances the global seconds-per-liquidity accumulator and then
    /// settles `who` for the window in which it held its current balance.
    function _tickTo(address who) internal {
        uint256 elapsed = block.timestamp - lastTick;
        if (elapsed > 0 && totalLiquidity > 0) {
            secondsPerLiquidity += elapsed * SCALE / totalLiquidity;
            emit Tick(block.timestamp, totalLiquidity);
        }
        lastTick = block.timestamp;

        uint256 held = liquidity[who];
        uint256 window = secondsPerLiquidity - secondsPerLiquidityPaid[who];
        if (held > 0 && window > 0) {
            uint256 share = held * window / SCALE;
            uint256 pot = feeReservoir;
            uint256 payout = share > pot ? pot : share;
            feeReservoir = pot - payout;
            feeClaimable[who] += payout;
        }
        secondsPerLiquidityPaid[who] = secondsPerLiquidity;
    }
}
