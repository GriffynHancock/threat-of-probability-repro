// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @notice Liquidity vault whose share price rises on a fixed per-second rate
/// (a yield index). Deposits mint shares at the current index; the index is
/// advanced lazily at the start of every state-changing call. The index is
/// accounting only: the underlying must be pre-funded by the steward for
/// withdrawals to succeed.
contract IndexedLiquidityVault {
    uint256 private constant RAY = 1e27;

    IERC20 public immutable underlying;
    address public immutable steward;
    uint256 public immutable ratePerSecondRay;

    uint256 public liquidityIndex = RAY;
    uint256 public lastIndexTime;
    uint256 public totalShares;

    mapping(address => uint256) public shareBalance;

    event IndexAdvanced(uint256 newIndex, uint256 timestamp);
    event Deposited(address indexed account, uint256 assets, uint256 shares);
    event Withdrawn(address indexed account, uint256 assets, uint256 shares);

    constructor(IERC20 _underlying, uint256 _ratePerSecondRay) {
        underlying = _underlying;
        steward = msg.sender;
        ratePerSecondRay = _ratePerSecondRay;
        lastIndexTime = block.timestamp;
    }

    function deposit(uint256 assets) external {
        require(assets > 0, "zero assets");
        _advanceIndex();
        uint256 minted = assets * RAY / liquidityIndex;
        shareBalance[msg.sender] += minted;
        totalShares += minted;
        require(underlying.transferFrom(msg.sender, address(this), assets), "transfer failed");
        emit Deposited(msg.sender, assets, minted);
    }

    function withdraw(uint256 shares) external {
        require(shares <= shareBalance[msg.sender], "insufficient shares");
        _advanceIndex();
        uint256 assets = shares * liquidityIndex / RAY;
        shareBalance[msg.sender] -= shares;
        totalShares -= shares;
        require(underlying.transfer(msg.sender, assets), "transfer failed");
        emit Withdrawn(msg.sender, assets, shares);
    }

    function assetsOf(address account) external view returns (uint256) {
        uint256 idx = _projectedIndex();
        return shareBalance[account] * idx / RAY;
    }

    /// @dev Compounds the index linearly from the last update to now.
    function _advanceIndex() internal {
        if (block.timestamp == lastIndexTime) return;
        liquidityIndex = _projectedIndex();
        lastIndexTime = block.timestamp;
        emit IndexAdvanced(liquidityIndex, block.timestamp);
    }

    function _projectedIndex() internal view returns (uint256) {
        uint256 dt = block.timestamp - lastIndexTime;
        return liquidityIndex + liquidityIndex * ratePerSecondRay * dt / RAY;
    }
}
