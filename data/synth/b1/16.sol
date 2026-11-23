// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @title SecondRateStaking
/// @notice Stakers earn a linear per-second rate on their staked amount. Each stake keeps
///         its own accrual clock, advanced by a storage-pointer helper before mutation.
contract SecondRateStaking {
    uint256 private constant SCALE = 1e18;
    uint256 private constant RATE_PER_SECOND = 3e9;

    struct Stake {
        uint256 amount;
        uint256 accrued;
        uint256 lastTs;
    }

    IERC20 public immutable token;
    address public immutable curator;
    uint256 public totalStaked;
    uint256 public payoutReserve;

    mapping(address => Stake) public stakes;

    event Staked(address indexed who, uint256 amount);
    event Unstaked(address indexed who, uint256 amount);
    event Claimed(address indexed who, uint256 amount);

    constructor(IERC20 _token) {
        token = _token;
        curator = msg.sender;
    }

    function fundPayouts(uint256 amount) external {
        require(msg.sender == curator, "curator");
        payoutReserve += amount;
        require(token.transferFrom(msg.sender, address(this), amount), "transferFrom");
    }

    function _accrueSecondRate(Stake storage s) internal {
        if (s.amount > 0) {
            s.accrued += (s.amount * RATE_PER_SECOND * (block.timestamp - s.lastTs)) / SCALE;
        }
        s.lastTs = block.timestamp;
    }

    function stake(uint256 amount) external {
        require(amount > 0, "zero");
        Stake storage s = stakes[msg.sender];
        _accrueSecondRate(s);
        s.amount += amount;
        totalStaked += amount;
        require(token.transferFrom(msg.sender, address(this), amount), "transferFrom");
        emit Staked(msg.sender, amount);
    }

    function unstake(uint256 amount) external {
        Stake storage s = stakes[msg.sender];
        _accrueSecondRate(s);
        require(amount <= s.amount, "amount");
        s.amount -= amount;
        totalStaked -= amount;
        require(token.transfer(msg.sender, amount), "transfer");
        emit Unstaked(msg.sender, amount);
    }

    function claim() external returns (uint256 owed) {
        Stake storage s = stakes[msg.sender];
        _accrueSecondRate(s);
        owed = s.accrued;
        require(owed <= payoutReserve, "reserve");
        s.accrued = 0;
        payoutReserve -= owed;
        require(token.transfer(msg.sender, owed), "transfer");
        emit Claimed(msg.sender, owed);
    }
}
