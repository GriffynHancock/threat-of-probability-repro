// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @title InsuranceCoverPool
/// @notice Capital providers underwrite cover and earn their pro-rata share of buffered premiums.
contract InsuranceCoverPool {
    uint256 private constant PRECISION = 1e18;

    IERC20 public immutable asset;

    uint256 public totalCapital;
    uint256 public premiumIndex;
    uint256 public premiumsBuffered;

    mapping(address => uint256) public capitalOf;
    mapping(address => uint256) public premiumDebt;
    mapping(address => uint256) public premiumOwed;

    event PremiumsBuffered(uint256 amount);
    event CapitalDeposited(address indexed provider, uint256 amount);
    event CapitalRedeemed(address indexed provider, uint256 amount);
    event PremiumClaimed(address indexed provider, uint256 amount);

    constructor(IERC20 _asset) {
        asset = _asset;
    }

    /// @notice Premium payers add to the buffer; it is realised into the index on the next sync.
    function bufferPremiums(uint256 amount) external {
        require(asset.transferFrom(msg.sender, address(this), amount), "transfer failed");
        premiumsBuffered += amount;
        emit PremiumsBuffered(amount);
    }

    function _syncPremiums(address who) internal {
        if (totalCapital > 0 && premiumsBuffered > 0) {
            premiumIndex += (premiumsBuffered * PRECISION) / totalCapital;
            premiumsBuffered = 0;
        }
        premiumOwed[who] += (capitalOf[who] * (premiumIndex - premiumDebt[who])) / PRECISION;
        premiumDebt[who] = premiumIndex;
    }

    function depositCapital(uint256 amount) external {
        require(amount > 0, "zero amount");
        _syncPremiums(msg.sender);
        capitalOf[msg.sender] += amount;
        totalCapital += amount;
        require(asset.transferFrom(msg.sender, address(this), amount), "transfer failed");
        emit CapitalDeposited(msg.sender, amount);
    }

    function redeemCapital(uint256 amount) external {
        _syncPremiums(msg.sender);
        require(capitalOf[msg.sender] >= amount, "insufficient capital");
        capitalOf[msg.sender] -= amount;
        totalCapital -= amount;
        require(asset.transfer(msg.sender, amount), "transfer failed");
        emit CapitalRedeemed(msg.sender, amount);
    }

    function claimPremium() external {
        _syncPremiums(msg.sender);
        uint256 amount = premiumOwed[msg.sender];
        require(amount > 0, "nothing owed");
        premiumOwed[msg.sender] = 0;
        require(asset.transfer(msg.sender, amount), "transfer failed");
        emit PremiumClaimed(msg.sender, amount);
    }
}
