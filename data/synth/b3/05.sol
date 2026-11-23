// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @notice Guild treasury. Members deposit guild shares and receive pro rata fee income.
contract GuildTreasury {
    uint256 private constant ACC = 1e27;

    IERC20 public immutable stakeToken;
    IERC20 public immutable feeToken;
    address public immutable guildMaster;

    uint256 public accFeePerShare;
    uint256 public totalShares;

    struct Member {
        uint256 shares;
        uint256 feeDebt;
        uint256 owed;
    }
    mapping(address => Member) public members;

    event FeesDeposited(uint256 amount, uint256 accFeePerShare);
    event SharesDeposited(address indexed user, uint256 amount);
    event SharesWithdrawn(address indexed user, uint256 amount);
    event FeesClaimed(address indexed user, uint256 amount);

    constructor(IERC20 _stake, IERC20 _fee, address _master) {
        stakeToken = _stake;
        feeToken = _fee;
        guildMaster = _master;
    }

    function depositFees(uint256 amount) external {
        require(msg.sender == guildMaster, "not master");
        require(totalShares > 0, "no shares");
        require(feeToken.transferFrom(msg.sender, address(this), amount), "fee pull");
        accFeePerShare += (amount * ACC) / totalShares;
        emit FeesDeposited(amount, accFeePerShare);
    }

    function _harvestFor(address who) internal {
        Member storage m = members[who];
        uint256 accrued = (m.shares * accFeePerShare) / ACC;
        m.owed += accrued - m.feeDebt;
        m.feeDebt = accrued;
    }

    function deposit(uint256 amount) external {
        _harvestFor(msg.sender);
        Member storage m = members[msg.sender];
        m.shares += amount;
        m.feeDebt = (m.shares * accFeePerShare) / ACC;
        totalShares += amount;
        require(stakeToken.transferFrom(msg.sender, address(this), amount), "stake pull");
        emit SharesDeposited(msg.sender, amount);
    }

    function withdrawShares(uint256 amount) external {
        _harvestFor(msg.sender);
        Member storage m = members[msg.sender];
        require(m.shares >= amount, "insufficient shares");
        m.shares -= amount;
        m.feeDebt = (m.shares * accFeePerShare) / ACC;
        totalShares -= amount;
        require(stakeToken.transfer(msg.sender, amount), "stake push");
        emit SharesWithdrawn(msg.sender, amount);
    }

    function claimFees() external {
        _harvestFor(msg.sender);
        Member storage m = members[msg.sender];
        uint256 amount = m.owed;
        m.owed = 0;
        require(feeToken.transfer(msg.sender, amount), "fee push");
        emit FeesClaimed(msg.sender, amount);
    }
}
