// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @title TrancheSupply
/// @notice Two supply tranches (senior and junior) with different fixed rates. Each tranche
///         has its own index; a user's yield is realised across both tranches on touch.
contract TrancheSupply {
    uint256 private constant SCALE = 1e18;

    enum Tranche { Senior, Junior }

    IERC20 public immutable token;
    address public immutable sponsor;

    uint256[2] public trancheIndex = [SCALE, SCALE];
    uint256[2] public trancheTotal;
    uint256[2] public trancheRate = [uint256(2e9), uint256(6e9)];
    uint256 public lastTrancheTs;
    uint256 public yieldReserve;

    mapping(address => mapping(Tranche => uint256)) public principal;
    mapping(address => mapping(Tranche => uint256)) public userIndex;
    mapping(address => uint256) public accruedYield;

    event TrancheDeposit(address indexed who, Tranche tranche, uint256 amount);
    event TrancheWithdraw(address indexed who, Tranche tranche, uint256 amount);
    event YieldClaimed(address indexed who, uint256 amount);

    constructor(IERC20 _token) {
        token = _token;
        sponsor = msg.sender;
        lastTrancheTs = block.timestamp;
    }

    function fundYield(uint256 amount) external {
        require(msg.sender == sponsor, "sponsor");
        yieldReserve += amount;
        require(token.transferFrom(msg.sender, address(this), amount), "transferFrom");
    }

    /// @dev Advances both tranche indices, then realises the user's yield in each tranche.
    function _materialize(address who) internal {
        uint256 dt = block.timestamp - lastTrancheTs;
        lastTrancheTs = block.timestamp;
        for (uint256 i = 0; i < 2; i++) {
            if (dt > 0 && trancheTotal[i] > 0) {
                trancheIndex[i] += (trancheIndex[i] * trancheRate[i] * dt) / SCALE;
            }
        }
        for (uint256 i = 0; i < 2; i++) {
            Tranche t = Tranche(i);
            uint256 snap = userIndex[who][t];
            if (snap != 0) {
                accruedYield[who] += (principal[who][t] * (trancheIndex[i] - snap)) / snap;
            }
            userIndex[who][t] = trancheIndex[i];
        }
    }

    function depositTranche(Tranche t, uint256 amount) external {
        require(amount > 0, "zero");
        _materialize(msg.sender);
        principal[msg.sender][t] += amount;
        trancheTotal[uint256(t)] += amount;
        require(token.transferFrom(msg.sender, address(this), amount), "transferFrom");
        emit TrancheDeposit(msg.sender, t, amount);
    }

    function withdrawTranche(Tranche t, uint256 amount) external {
        _materialize(msg.sender);
        require(amount <= principal[msg.sender][t], "principal");
        principal[msg.sender][t] -= amount;
        trancheTotal[uint256(t)] -= amount;
        require(token.transfer(msg.sender, amount), "transfer");
        emit TrancheWithdraw(msg.sender, t, amount);
    }

    function claimYield() external returns (uint256 owed) {
        _materialize(msg.sender);
        owed = accruedYield[msg.sender];
        require(owed <= yieldReserve, "reserve");
        accruedYield[msg.sender] = 0;
        yieldReserve -= owed;
        require(token.transfer(msg.sender, owed), "transfer");
        emit YieldClaimed(msg.sender, owed);
    }
}
