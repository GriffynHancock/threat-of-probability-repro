// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.24;

interface IERC20Like {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// Stakes are held as numbered positions (like NFTs without the token standard).
/// Each position is owned by one holder. A per-holder aggregate is kept so that
/// rewards are computed without iterating positions.
contract PositionStakingBook {
    uint256 internal constant ACC = 1e12;

    struct Position {
        address holder;
        uint128 amount;
        uint64 openedAt;
    }

    IERC20Like public immutable stakeToken;
    IERC20Like public immutable rewardToken;
    address public operator;
    uint256 public emissionPerSecond;
    uint256 public lastStamp;
    uint256 public stakedTotal;
    uint256 public perShareAcc;

    uint256 public nextPositionId = 1;
    mapping(uint256 => Position) public positionOf;
    mapping(address => uint256) public stakedByHolder;
    mapping(address => uint256) public settledAcc;
    mapping(address => uint256) public rewardCredit;

    event PositionOpened(uint256 indexed id, address indexed holder, uint256 amount);
    event PositionClosed(uint256 indexed id, address indexed holder, uint256 amount);
    event Harvested(address indexed holder, uint256 amount);
    event EmissionSet(uint256 perSecond);

    constructor(IERC20Like _stake, IERC20Like _reward, uint256 _emission) {
        stakeToken = _stake;
        rewardToken = _reward;
        operator = msg.sender;
        emissionPerSecond = _emission;
        lastStamp = block.timestamp;
    }

    function open(uint256 amount) external returns (uint256 id) {
        _checkpoint(msg.sender);
        require(amount > 0, "amount=0");
        require(amount <= type(uint128).max, "amount too large");
        require(stakeToken.transferFrom(msg.sender, address(this), amount), "pull failed");

        id = nextPositionId++;
        positionOf[id] = Position({
            holder: msg.sender,
            amount: uint128(amount),
            openedAt: uint64(block.timestamp)
        });
        stakedByHolder[msg.sender] += amount;
        stakedTotal += amount;
        emit PositionOpened(id, msg.sender, amount);
    }

    function close(uint256 id) external {
        Position memory p = positionOf[id];
        require(p.holder == msg.sender, "not holder");

        _checkpoint(msg.sender);
        delete positionOf[id];
        stakedByHolder[msg.sender] -= p.amount;
        stakedTotal -= p.amount;

        require(stakeToken.transfer(msg.sender, p.amount), "return failed");
        emit PositionClosed(id, msg.sender, p.amount);
    }

    function harvest() external {
        _checkpoint(msg.sender);
        uint256 amt = rewardCredit[msg.sender];
        require(amt > 0, "nothing to harvest");
        rewardCredit[msg.sender] = 0;
        require(rewardToken.transfer(msg.sender, amt), "reward failed");
        emit Harvested(msg.sender, amt);
    }

    function setEmission(uint256 perSecond) external {
        require(msg.sender == operator, "not operator");
        _advance();
        emissionPerSecond = perSecond;
        emit EmissionSet(perSecond);
    }

    /// @dev Settlement for a holder's aggregate. Runs before any change to
    ///      stakedByHolder, so the accrual is priced at the balance held
    ///      up to this moment.
    function _checkpoint(address holder) internal {
        _advance();
        uint256 held = stakedByHolder[holder];
        rewardCredit[holder] += held * (perShareAcc - settledAcc[holder]) / ACC;
        settledAcc[holder] = perShareAcc;
    }

    function _advance() internal {
        uint256 elapsed = block.timestamp - lastStamp;
        lastStamp = block.timestamp;
        if (elapsed == 0 || stakedTotal == 0) return;
        perShareAcc += emissionPerSecond * elapsed * ACC / stakedTotal;
    }
}
