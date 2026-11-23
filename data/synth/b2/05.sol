// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @notice Time-bucketed gauge: deposits are keyed by epoch and each epoch's
/// emission is shared pro-rata among that epoch's depositors.
contract EpochGaugeWeights {
    uint256 public constant EPOCH_LENGTH = 7 days;
    uint256 private constant PRECISION = 1e18;

    IERC20 public immutable stake;
    IERC20 public immutable emissionToken;
    address public immutable admin;

    uint256 public activeEpoch;
    uint256 public epochStart;

    mapping(uint256 => uint256) public epochEmission;
    mapping(uint256 => uint256) public epochTotal;
    mapping(uint256 => mapping(address => uint256)) public depositsAt;
    mapping(uint256 => mapping(address => bool)) public epochClaimed;

    event EpochRolled(uint256 indexed epoch, uint256 start);
    event GaugeDeposit(address indexed user, uint256 indexed epoch, uint256 amount);
    event GaugeWithdraw(address indexed user, uint256 indexed epoch, uint256 amount);
    event EpochClaimed(address indexed user, uint256 indexed epoch, uint256 amount);

    constructor(IERC20 _stake, IERC20 _emission) {
        stake = _stake;
        emissionToken = _emission;
        admin = msg.sender;
        activeEpoch = 0;
        epochStart = block.timestamp;
    }

    function fundEpoch(uint256 epoch, uint256 amount) external {
        require(msg.sender == admin, "not admin");
        require(epoch >= activeEpoch, "epoch in past");
        require(emissionToken.transferFrom(msg.sender, address(this), amount), "transfer failed");
        epochEmission[epoch] += amount;
    }

    function depositGauge(uint256 amount) external {
        require(amount > 0, "zero amount");
        _checkpointEpoch();
        uint256 e = activeEpoch;
        depositsAt[e][msg.sender] += amount;
        epochTotal[e] += amount;
        require(stake.transferFrom(msg.sender, address(this), amount), "transfer failed");
        emit GaugeDeposit(msg.sender, e, amount);
    }

    function withdrawGauge(uint256 amount) external {
        _checkpointEpoch();
        uint256 e = activeEpoch;
        require(depositsAt[e][msg.sender] >= amount, "insufficient deposit");
        depositsAt[e][msg.sender] -= amount;
        epochTotal[e] -= amount;
        require(stake.transfer(msg.sender, amount), "transfer failed");
        emit GaugeWithdraw(msg.sender, e, amount);
    }

    /// @notice Claim a share of a finished epoch's emission.
    function claimEpoch(uint256 epoch) external {
        require(epoch < activeEpoch, "epoch not finished");
        require(!epochClaimed[epoch][msg.sender], "already claimed");
        uint256 total = epochTotal[epoch];
        uint256 mine = depositsAt[epoch][msg.sender];
        epochClaimed[epoch][msg.sender] = true;
        if (total == 0 || mine == 0) return;
        uint256 share = epochEmission[epoch] * mine / total;
        require(emissionToken.transfer(msg.sender, share), "transfer failed");
        emit EpochClaimed(msg.sender, epoch, share);
    }

    /// @dev Rolls the active epoch forward while the wall clock has passed the
    /// epoch boundary. Emits once per roll.
    function _checkpointEpoch() internal {
        while (block.timestamp >= epochStart + EPOCH_LENGTH) {
            epochStart += EPOCH_LENGTH;
            activeEpoch += 1;
            emit EpochRolled(activeEpoch, epochStart);
        }
    }
}
