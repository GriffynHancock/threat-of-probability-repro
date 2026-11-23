// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @notice Bribes paid to voters per unit of vote weight, tracked with a
/// per-gauge bribe index. Each voter keeps a per-gauge checkpoint.
contract BribeIndexMarket {
    uint256 private constant SCALE = 1e27;

    IERC20 public immutable bribeToken;

    /// @dev gaugeId => total vote weight currently on the gauge
    mapping(uint256 => uint256) public totalWeight;
    /// @dev gaugeId => cumulative bribe per unit of weight, scaled by SCALE
    mapping(uint256 => uint256) public bribeIndex;
    /// @dev voter => gaugeId => vote weight
    mapping(address => mapping(uint256 => uint256)) public weightOf;
    /// @dev voter => gaugeId => bribeIndex at last checkpoint
    mapping(address => mapping(uint256 => uint256)) public indexPaid;
    /// @dev voter => amount of bribe token ready to claim
    mapping(address => uint256) public claimable;

    event Voted(address indexed voter, uint256 indexed gaugeId, uint256 weight);
    event Unvoted(address indexed voter, uint256 indexed gaugeId, uint256 weight);
    event Bribed(address indexed briber, uint256 indexed gaugeId, uint256 amount);
    event Claimed(address indexed voter, uint256 amount);

    constructor(IERC20 _bribeToken) {
        bribeToken = _bribeToken;
    }

    /// @notice Deposit a bribe for a gauge. The index moves by amount per unit of
    /// the weight currently voting on that gauge.
    function bribe(uint256 gaugeId, uint256 amount) external {
        require(amount > 0, "zero bribe");
        require(totalWeight[gaugeId] > 0, "no votes on gauge");
        bribeIndex[gaugeId] += amount * SCALE / totalWeight[gaugeId];
        require(bribeToken.transferFrom(msg.sender, address(this), amount), "transfer failed");
        emit Bribed(msg.sender, gaugeId, amount);
    }

    /// @notice Add vote weight to a gauge.
    /// @param gaugeId The gauge receiving the weight.
    /// @param weight Amount of weight to add.
    function vote(uint256 gaugeId, uint256 weight) external {
        require(weight > 0, "zero weight");
        _collectFor(msg.sender, gaugeId);
        weightOf[msg.sender][gaugeId] += weight;
        totalWeight[gaugeId] += weight;
        emit Voted(msg.sender, gaugeId, weight);
    }

    /// @notice Remove vote weight from a gauge.
    function unvote(uint256 gaugeId, uint256 weight) external {
        require(weight <= weightOf[msg.sender][gaugeId], "too much weight");
        _collectFor(msg.sender, gaugeId);
        weightOf[msg.sender][gaugeId] -= weight;
        totalWeight[gaugeId] -= weight;
        emit Unvoted(msg.sender, gaugeId, weight);
    }

    function claimBribes() external {
        uint256 amount = claimable[msg.sender];
        if (amount == 0) return;
        claimable[msg.sender] = 0;
        require(bribeToken.transfer(msg.sender, amount), "transfer failed");
        emit Claimed(msg.sender, amount);
    }

    /// @dev Credits the voter with bribe accrued on this gauge since their last
    /// checkpoint, then advances the checkpoint to the current index.
    function _collectFor(address voter, uint256 gaugeId) internal {
        uint256 idx = bribeIndex[gaugeId];
        uint256 delta = idx - indexPaid[voter][gaugeId];
        if (delta == 0) {
            return;
        }
        claimable[voter] += weightOf[voter][gaugeId] * delta / SCALE;
        indexPaid[voter][gaugeId] = idx;
    }
}
