// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @title VestingPremiumSplitter
/// @notice Premiums are split across capital providers by share. Each new underwrite resets a lockup
///         clock for that provider; capital cannot be withdrawn until the clock expires.
contract VestingPremiumSplitter {
    uint256 private constant PRECISION = 1e18;
    uint256 public constant LOCKUP = 30 days;

    struct Provider {
        uint256 capital;
        uint256 premiumDebt;
        uint256 premiumOwed;
        uint256 unlockAt;
    }

    IERC20 public immutable asset;
    uint256 public totalCapital;
    uint256 public premiumPerCapital;

    mapping(address => Provider) public providers;

    event Underwritten(address indexed provider, uint256 amount, uint256 unlockAt);
    event PremiumReceived(uint256 amount);
    event Withdrawn(address indexed provider, uint256 amount);
    event PremiumPaid(address indexed provider, uint256 amount);

    constructor(IERC20 _asset) {
        asset = _asset;
    }

    function receivePremium(uint256 amount) external {
        require(totalCapital > 0, "no capital");
        require(asset.transferFrom(msg.sender, address(this), amount), "transfer failed");
        premiumPerCapital += (amount * PRECISION) / totalCapital;
        emit PremiumReceived(amount);
    }

    function _settleProvider(address who) internal {
        Provider storage p = providers[who];
        p.premiumOwed += (p.capital * (premiumPerCapital - p.premiumDebt)) / PRECISION;
        p.premiumDebt = premiumPerCapital;
    }

    /// @notice Underwrite capital; the lockup restarts on each deposit.
    function underwrite(uint256 amount) external {
        require(amount > 0, "zero amount");
        _settleProvider(msg.sender);
        Provider storage p = providers[msg.sender];
        p.capital += amount;
        p.unlockAt = block.timestamp + LOCKUP;
        totalCapital += amount;
        require(asset.transferFrom(msg.sender, address(this), amount), "transfer failed");
        emit Underwritten(msg.sender, amount, p.unlockAt);
    }

    /// @notice Withdraw capital after the lockup has expired.
    function withdrawCapital(uint256 amount) external {
        _settleProvider(msg.sender);
        Provider storage p = providers[msg.sender];
        require(block.timestamp >= p.unlockAt, "locked");
        require(p.capital >= amount, "insufficient capital");
        p.capital -= amount;
        totalCapital -= amount;
        require(asset.transfer(msg.sender, amount), "transfer failed");
        emit Withdrawn(msg.sender, amount);
    }

    /// @notice Collect premiums.
    function collectPremium() external {
        _settleProvider(msg.sender);
        Provider storage p = providers[msg.sender];
        uint256 amount = p.premiumOwed;
        require(amount > 0, "nothing owed");
        p.premiumOwed = 0;
        require(asset.transfer(msg.sender, amount), "transfer failed");
        emit PremiumPaid(msg.sender, amount);
    }
}
