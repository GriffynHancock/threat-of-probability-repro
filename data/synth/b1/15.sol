// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @title ReceiptAccumulator
/// @notice Receipt-style accumulator. A global reward-per-receipt grows at a fixed rate
///         while receipts exist; holders settle against their paid-per-receipt watermark.
contract ReceiptAccumulator {
    uint256 private constant SCALE = 1e18;

    IERC20 public immutable token;
    address public immutable steward;

    uint256 public rewardRate;
    uint256 public rewardPerReceipt;
    uint256 public lastUpdate;
    uint256 public totalReceipts;
    uint256 public rewardPaid;

    mapping(address => uint256) public receipts;
    mapping(address => uint256) public paidPerReceipt;
    mapping(address => uint256) public earned;

    event Enrolled(address indexed holder, uint256 amount);
    event Released(address indexed holder, uint256 amount);
    event RewardPaid(address indexed holder, uint256 amount);

    constructor(IERC20 _token, uint256 _rewardRate) {
        token = _token;
        steward = msg.sender;
        rewardRate = _rewardRate;
        lastUpdate = block.timestamp;
    }

    function _pokeEarnings() internal {
        uint256 dt = block.timestamp - lastUpdate;
        lastUpdate = block.timestamp;
        if (dt == 0 || totalReceipts == 0) return;
        rewardPerReceipt += (rewardRate * dt * SCALE) / totalReceipts;
    }

    function enroll(uint256 amount) external {
        require(amount > 0, "zero");
        _pokeEarnings();
        earned[msg.sender] += (receipts[msg.sender] * (rewardPerReceipt - paidPerReceipt[msg.sender])) / SCALE;
        paidPerReceipt[msg.sender] = rewardPerReceipt;
        receipts[msg.sender] += amount;
        totalReceipts += amount;
        require(token.transferFrom(msg.sender, address(this), amount), "transferFrom");
        emit Enrolled(msg.sender, amount);
    }

    function release(uint256 amount) external {
        _pokeEarnings();
        earned[msg.sender] += (receipts[msg.sender] * (rewardPerReceipt - paidPerReceipt[msg.sender])) / SCALE;
        paidPerReceipt[msg.sender] = rewardPerReceipt;
        require(amount <= receipts[msg.sender], "receipts");
        receipts[msg.sender] -= amount;
        totalReceipts -= amount;
        require(token.transfer(msg.sender, amount), "transfer");
        emit Released(msg.sender, amount);
    }

    function getReward() external returns (uint256 owed) {
        _pokeEarnings();
        earned[msg.sender] += (receipts[msg.sender] * (rewardPerReceipt - paidPerReceipt[msg.sender])) / SCALE;
        paidPerReceipt[msg.sender] = rewardPerReceipt;
        owed = earned[msg.sender];
        earned[msg.sender] = 0;
        rewardPaid += owed;
        emit RewardPaid(msg.sender, owed);
    }
}
