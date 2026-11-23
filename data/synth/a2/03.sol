// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IToken {
    function balanceOf(address owner) external view returns (uint256);
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
}

contract EpochLedger {
    uint256 private constant ACC_UNIT = 1e27;

    IToken public immutable principal;
    IToken public immutable bonus;
    address public immutable curator;

    // Reward schedule: one epoch at a time, linear over its length.
    uint64 public epochStart;
    uint64 public epochEnd;
    uint256 public epochRatePerSecond;

    uint256 public accPerShare;
    uint64 public accUpdatedAt;

    uint256 public staked;
    mapping(address => uint256) public stakeOf;
    mapping(address => uint256) public accSeen;
    mapping(address => uint256) public bonusOwed;

    event Provide(address indexed account, uint256 amount);
    event Recall(address indexed account, uint256 amount);
    event Collect(address indexed account, uint256 amount);
    event EpochOpened(uint64 start, uint64 end, uint256 total);

    constructor(IToken principal_, IToken bonus_) {
        principal = principal_;
        bonus = bonus_;
        curator = msg.sender;
        accUpdatedAt = uint64(block.timestamp);
    }

    function accruedUntil() public view returns (uint64) {
        return block.timestamp < epochEnd ? uint64(block.timestamp) : epochEnd;
    }

    function previewAccPerShare() public view returns (uint256) {
        if (staked == 0 || accUpdatedAt >= accruedUntil()) {
            return accPerShare;
        }
        uint256 span = accruedUntil() - accUpdatedAt;
        return accPerShare + (span * epochRatePerSecond * ACC_UNIT) / staked;
    }

    function earnedBy(address account) public view returns (uint256) {
        return bonusOwed[account] + (stakeOf[account] * (previewAccPerShare() - accSeen[account])) / ACC_UNIT;
    }

    function openEpoch(uint256 total, uint64 length) external {
        require(msg.sender == curator, "EpochLedger: not curator");
        require(length > 0 && total > 0, "EpochLedger: empty epoch");
        require(block.timestamp >= epochEnd, "EpochLedger: epoch running");

        _settle(address(0));

        epochStart = uint64(block.timestamp);
        epochEnd = uint64(block.timestamp) + length;
        epochRatePerSecond = total / length;
        require(epochRatePerSecond > 0, "EpochLedger: rate zero");
        accUpdatedAt = uint64(block.timestamp);

        require(bonus.transferFrom(msg.sender, address(this), total), "EpochLedger: fund");
        emit EpochOpened(epochStart, epochEnd, total);
    }

    function provide(uint256 amount) external {
        require(amount > 0, "EpochLedger: zero");
        _settle(msg.sender);

        stakeOf[msg.sender] += amount;
        staked += amount;

        require(principal.transferFrom(msg.sender, address(this), amount), "EpochLedger: pull");
        emit Provide(msg.sender, amount);
    }

    function recall(uint256 amount) external {
        require(amount > 0 && amount <= stakeOf[msg.sender], "EpochLedger: bad amount");
        _settle(msg.sender);

        stakeOf[msg.sender] -= amount;
        staked -= amount;

        require(principal.transfer(msg.sender, amount), "EpochLedger: push");
        emit Recall(msg.sender, amount);
    }

    function collect() external {
        _settle(msg.sender);

        uint256 amount = bonusOwed[msg.sender];
        require(amount > 0, "EpochLedger: nothing");
        bonusOwed[msg.sender] = 0;

        require(bonus.transfer(msg.sender, amount), "EpochLedger: bonus");
        emit Collect(msg.sender, amount);
    }

    function _settle(address account) internal {
        accPerShare = previewAccPerShare();
        accUpdatedAt = accruedUntil();

        if (account != address(0)) {
            bonusOwed[account] = earnedBy(account);
            accSeen[account] = accPerShare;
        }
    }
}
