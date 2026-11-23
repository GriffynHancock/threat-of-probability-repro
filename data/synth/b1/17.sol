// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @title CheckpointDebtLedger
/// @notice Each borrower keeps an append-only list of debt checkpoints. Debt compounds
///         linearly between checkpoints; pledges and draws edit the latest checkpoint.
contract CheckpointDebtLedger {
    uint256 private constant SCALE = 1e18;
    uint256 private constant RATE_PER_SECOND = 2e9;
    uint256 private constant LTV = 70e16;

    struct Checkpoint {
        uint128 debt;
        uint128 collateral;
        uint64 at;
    }

    IERC20 public immutable token;
    address public immutable operator;
    uint256 public totalDebt;
    uint256 public totalCollateral;
    uint256 public liquidity;

    mapping(address => Checkpoint[]) internal ledger;

    event Pledged(address indexed who, uint256 amount);
    event Drawn(address indexed who, uint256 amount);
    event Repaid(address indexed who, uint256 amount);
    event Released(address indexed who, uint256 amount);

    constructor(IERC20 _token) {
        token = _token;
        operator = msg.sender;
    }

    function provideLiquidity(uint256 amount) external {
        require(msg.sender == operator, "operator");
        liquidity += amount;
        require(token.transferFrom(msg.sender, address(this), amount), "transferFrom");
    }

    /// @dev Appends a checkpoint whose debt is the last one compounded to now.
    function _snapshotDebt(address who) internal {
        Checkpoint[] storage cps = ledger[who];
        Checkpoint memory last = Checkpoint(0, 0, uint64(block.timestamp));
        if (cps.length > 0) {
            last = cps[cps.length - 1];
        }
        uint256 dt = block.timestamp - last.at;
        uint256 compounded = uint256(last.debt) + (uint256(last.debt) * RATE_PER_SECOND * dt) / SCALE;
        cps.push(Checkpoint(uint128(compounded), last.collateral, uint64(block.timestamp)));
    }

    function _top(address who) internal view returns (Checkpoint storage) {
        Checkpoint[] storage cps = ledger[who];
        return cps[cps.length - 1];
    }

    function pledge(uint256 amount) external {
        require(amount > 0, "zero");
        _snapshotDebt(msg.sender);
        Checkpoint storage top = _top(msg.sender);
        top.collateral += uint128(amount);
        totalCollateral += amount;
        require(token.transferFrom(msg.sender, address(this), amount), "transferFrom");
        emit Pledged(msg.sender, amount);
    }

    function draw(uint256 amount) external {
        require(amount > 0 && amount <= liquidity, "liquidity");
        _snapshotDebt(msg.sender);
        Checkpoint storage top = _top(msg.sender);
        require(uint256(top.debt) + amount <= (uint256(top.collateral) * LTV) / SCALE, "ltv");
        top.debt += uint128(amount);
        totalDebt += amount;
        liquidity -= amount;
        require(token.transfer(msg.sender, amount), "transfer");
        emit Drawn(msg.sender, amount);
    }

    function repay(uint256 amount) external {
        _snapshotDebt(msg.sender);
        Checkpoint storage top = _top(msg.sender);
        uint256 pay = amount > top.debt ? top.debt : amount;
        top.debt -= uint128(pay);
        totalDebt -= pay;
        liquidity += pay;
        require(token.transferFrom(msg.sender, address(this), pay), "transferFrom");
        emit Repaid(msg.sender, pay);
    }

    function release(uint256 amount) external {
        _snapshotDebt(msg.sender);
        Checkpoint storage top = _top(msg.sender);
        require(amount <= top.collateral, "collateral");
        require(uint256(top.debt) <= ((uint256(top.collateral) - amount) * LTV) / SCALE, "ltv");
        top.collateral -= uint128(amount);
        totalCollateral -= amount;
        require(token.transfer(msg.sender, amount), "transfer");
        emit Released(msg.sender, amount);
    }
}
