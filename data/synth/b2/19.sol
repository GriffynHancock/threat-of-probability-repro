// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @notice Tiered pot distribution. Each depositor's weight is its stake times a
/// tier multiplier chosen by lock length. Pot rewards per block are split by
/// weight; each account's weight contribution is re-based on every change.
contract TieredWeightPot {
    uint256 private constant Q = 1e12;
    uint256 private constant MULT_SHORT = 100;
    uint256 private constant MULT_MID = 150;
    uint256 private constant MULT_LONG = 200;

    IERC20 public immutable stakeToken;
    IERC20 public immutable potToken;
    address public immutable owner;

    uint256 public perWeightStored;
    uint256 public lastBlock;
    uint256 public rewardPerBlock;
    uint256 public totalWeight;

    mapping(address => uint256) public stakeOf;
    mapping(address => uint256) public weightOf;
    mapping(address => uint256) public perWeightPaid;
    mapping(address => uint256) public potOwed;

    event Entered(address indexed user, uint256 amount, uint256 tier);
    event Exited(address indexed user, uint256 amount);
    event PotPaid(address indexed user, uint256 amount);

    constructor(IERC20 _stake, IERC20 _pot, uint256 _rewardPerBlock) {
        stakeToken = _stake;
        potToken = _pot;
        owner = msg.sender;
        rewardPerBlock = _rewardPerBlock;
        lastBlock = block.number;
    }

    function enterPool(uint256 amount, uint256 tier) external {
        require(amount > 0, "zero amount");
        require(tier <= 2, "bad tier");
        _checkpointPot(msg.sender);
        uint256 mult = tier == 0 ? MULT_SHORT : tier == 1 ? MULT_MID : MULT_LONG;
        uint256 addedWeight = amount * mult / 100;
        stakeOf[msg.sender] += amount;
        weightOf[msg.sender] += addedWeight;
        totalWeight += addedWeight;
        require(stakeToken.transferFrom(msg.sender, address(this), amount), "transfer failed");
        emit Entered(msg.sender, amount, tier);
    }

    function exitPool(uint256 amount) external {
        require(amount <= stakeOf[msg.sender], "insufficient stake");
        _checkpointPot(msg.sender);
        uint256 w = weightOf[msg.sender];
        uint256 removed = stakeOf[msg.sender] == 0 ? 0 : w * amount / stakeOf[msg.sender];
        stakeOf[msg.sender] -= amount;
        weightOf[msg.sender] -= removed;
        totalWeight -= removed;
        require(stakeToken.transfer(msg.sender, amount), "transfer failed");
        emit Exited(msg.sender, amount);
    }

    function claimPot() external {
        _checkpointPot(msg.sender);
        uint256 amount = potOwed[msg.sender];
        if (amount == 0) return;
        potOwed[msg.sender] = 0;
        require(potToken.transfer(msg.sender, amount), "transfer failed");
        emit PotPaid(msg.sender, amount);
    }

    /// @dev Adds pot emitted since the last block to the per-weight index, then
    /// credits `who` for its weight at the index it last saw.
    function _checkpointPot(address who) internal {
        if (block.number > lastBlock && totalWeight > 0) {
            perWeightStored += (block.number - lastBlock) * rewardPerBlock * Q / totalWeight;
        }
        lastBlock = block.number;
        uint256 delta = perWeightStored - perWeightPaid[who];
        potOwed[who] += weightOf[who] * delta / Q;
        perWeightPaid[who] = perWeightStored;
    }
}
