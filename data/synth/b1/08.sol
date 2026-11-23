// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @title MasterYieldLender
/// @notice Accumulator-per-share lending pool. A global reward-per-share value grows at a
///         fixed emission rate; each lender keeps a reward-debt watermark.
contract MasterYieldLender {
    uint256 private constant ACC_SCALE = 1e12;

    struct Lender {
        uint128 principal;
        uint128 rewardDebt;
    }

    IERC20 public immutable asset;
    address public immutable deployer;
    uint256 public rewardPerSecond;
    uint256 public accRewardPerShare;
    uint256 public lastRollTime;
    uint256 public totalPrincipal;
    uint256 public rewardReserve;

    mapping(address => Lender) public lenders;
    mapping(address => uint256) public pendingRewards;

    event Lent(address indexed who, uint256 amount);
    event Recalled(address indexed who, uint256 amount);
    event Harvested(address indexed who, uint256 amount);

    constructor(IERC20 _asset, uint256 _rewardPerSecond) {
        asset = _asset;
        deployer = msg.sender;
        rewardPerSecond = _rewardPerSecond;
        lastRollTime = block.timestamp;
    }

    function topUpReserve(uint256 amount) external {
        require(msg.sender == deployer, "forbidden");
        rewardReserve += amount;
        require(asset.transferFrom(msg.sender, address(this), amount), "transferFrom");
    }

    /// @dev Rolls the global accumulator forward to the current block time.
    function _rollRate() internal {
        uint256 dt = block.timestamp - lastRollTime;
        lastRollTime = block.timestamp;
        if (dt == 0 || totalPrincipal == 0) return;
        accRewardPerShare += (rewardPerSecond * dt * ACC_SCALE) / totalPrincipal;
    }

    function lend(uint256 amount) external {
        require(amount > 0, "zero");
        _rollRate();
        Lender storage l = lenders[msg.sender];
        uint256 accrued = (uint256(l.principal) * accRewardPerShare) / ACC_SCALE;
        pendingRewards[msg.sender] += accrued - l.rewardDebt;
        l.principal += uint128(amount);
        totalPrincipal += amount;
        l.rewardDebt = uint128((uint256(l.principal) * accRewardPerShare) / ACC_SCALE);
        require(asset.transferFrom(msg.sender, address(this), amount), "transferFrom");
        emit Lent(msg.sender, amount);
    }

    function recall(uint256 amount) external {
        _rollRate();
        Lender storage l = lenders[msg.sender];
        require(amount <= l.principal, "principal");
        uint256 accrued = (uint256(l.principal) * accRewardPerShare) / ACC_SCALE;
        pendingRewards[msg.sender] += accrued - l.rewardDebt;
        l.principal -= uint128(amount);
        totalPrincipal -= amount;
        l.rewardDebt = uint128((uint256(l.principal) * accRewardPerShare) / ACC_SCALE);
        require(asset.transfer(msg.sender, amount), "transfer");
        emit Recalled(msg.sender, amount);
    }

    function harvest() external returns (uint256 owed) {
        _rollRate();
        Lender storage l = lenders[msg.sender];
        uint256 accrued = (uint256(l.principal) * accRewardPerShare) / ACC_SCALE;
        pendingRewards[msg.sender] += accrued - l.rewardDebt;
        l.rewardDebt = uint128(accrued);
        owed = pendingRewards[msg.sender];
        require(owed <= rewardReserve, "reserve");
        pendingRewards[msg.sender] = 0;
        rewardReserve -= owed;
        require(asset.transfer(msg.sender, owed), "transfer");
        emit Harvested(msg.sender, owed);
    }
}
