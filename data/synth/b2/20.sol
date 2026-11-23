// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @notice Gauge registry. Each registered gauge keeps its own total stake and
/// a per-gauge emission rate; a holder's stake is tracked per (gauge, holder)
/// and rewards are settled per gauge before that holder's stake changes.
contract GaugeRegistryDirector {
    uint256 private constant ACC = 1e18;

    struct GaugeInfo {
        IERC20 lp;
        uint256 emissionPerSecond;
        uint256 totalStake;
        uint256 accPerStake;
        uint256 lastTouch;
        bool active;
    }

    struct HolderInfo {
        uint256 stake;
        uint256 accPaid;
        uint256 earned;
    }

    IERC20 public immutable emissionToken;
    address public immutable director;
    uint256 public gaugeCount;

    mapping(uint256 => GaugeInfo) public gauges;
    mapping(uint256 => mapping(address => HolderInfo)) public holders;

    event GaugeRegistered(uint256 indexed gaugeId, address lp, uint256 emissionPerSecond);
    event GaugeStaked(uint256 indexed gaugeId, address indexed who, uint256 amount);
    event GaugeUnstaked(uint256 indexed gaugeId, address indexed who, uint256 amount);
    event GaugeClaimed(uint256 indexed gaugeId, address indexed who, uint256 amount);

    constructor(IERC20 _emission) {
        emissionToken = _emission;
        director = msg.sender;
    }

    function registerGauge(IERC20 lp, uint256 emissionPerSecond) external returns (uint256 gaugeId) {
        require(msg.sender == director, "not director");
        gaugeId = gaugeCount;
        gauges[gaugeId] = GaugeInfo({
            lp: lp,
            emissionPerSecond: emissionPerSecond,
            totalStake: 0,
            accPerStake: 0,
            lastTouch: block.timestamp,
            active: true
        });
        gaugeCount += 1;
        emit GaugeRegistered(gaugeId, address(lp), emissionPerSecond);
    }

    function supplyToGauge(uint256 gaugeId, uint256 amount) external {
        GaugeInfo storage g = gauges[gaugeId];
        require(g.active, "inactive gauge");
        require(amount > 0, "zero amount");
        _syncRegistry(gaugeId, msg.sender);
        HolderInfo storage h = holders[gaugeId][msg.sender];
        h.stake += amount;
        g.totalStake += amount;
        require(g.lp.transferFrom(msg.sender, address(this), amount), "transfer failed");
        emit GaugeStaked(gaugeId, msg.sender, amount);
    }

    function withdrawFromGauge(uint256 gaugeId, uint256 amount) external {
        GaugeInfo storage g = gauges[gaugeId];
        HolderInfo storage h = holders[gaugeId][msg.sender];
        require(amount <= h.stake, "insufficient stake");
        _syncRegistry(gaugeId, msg.sender);
        h.stake -= amount;
        g.totalStake -= amount;
        require(g.lp.transfer(msg.sender, amount), "transfer failed");
        emit GaugeUnstaked(gaugeId, msg.sender, amount);
    }

    function claimGauge(uint256 gaugeId) external {
        _syncRegistry(gaugeId, msg.sender);
        HolderInfo storage h = holders[gaugeId][msg.sender];
        uint256 amount = h.earned;
        if (amount == 0) return;
        h.earned = 0;
        require(emissionToken.transfer(msg.sender, amount), "transfer failed");
        emit GaugeClaimed(gaugeId, msg.sender, amount);
    }

    /// @dev Moves the gauge's accumulator to the present, then books the holder's
    /// emissions for the stake it held before the caller's change.
    function _syncRegistry(uint256 gaugeId, address who) internal {
        GaugeInfo storage g = gauges[gaugeId];
        uint256 dt = block.timestamp - g.lastTouch;
        if (dt > 0 && g.totalStake > 0) {
            g.accPerStake += dt * g.emissionPerSecond * ACC / g.totalStake;
        }
        g.lastTouch = block.timestamp;

        HolderInfo storage h = holders[gaugeId][who];
        h.earned += h.stake * (g.accPerStake - h.accPaid) / ACC;
        h.accPaid = g.accPerStake;
    }
}
