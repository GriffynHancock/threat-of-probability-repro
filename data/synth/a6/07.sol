// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

interface IRewardAsset {
    function transfer(address to, uint256 wad) external returns (bool);
}

interface IGaugeLedger {
    function balanceIn(uint256 gaugeId, address account) external view returns (uint256);
    function supplyIn(uint256 gaugeId) external view returns (uint256);
}

/// Gauge-weighted emissions. The controller splits a global emission stream across gauges by
/// admin-set weights, then each gauge pays its holders pro rata. Holder balances live in IGaugeLedger.
contract GaugeEmissionController {
    uint256 private constant ACC_UNIT = 1e18;

    error Forbidden();
    error UnknownGauge(uint256 gaugeId);
    error WeightSumZero();
    error NoRewards();
    error PayFailed();

    event EmissionRate(uint256 perSecond);
    event GaugeWeightSet(uint256 indexed gaugeId, uint256 weight, uint256 totalWeight);
    event GaugeCheckpointed(uint256 indexed gaugeId, uint256 indexAcc);
    event GaugeHarvest(uint256 indexed gaugeId, address indexed account, uint256 amount);

    IRewardAsset public immutable reward;
    IGaugeLedger public immutable ledger;
    address public immutable admin;

    uint256 public emissionPerSecond;
    uint256 public totalWeight;
    uint256 public gaugeCount;

    mapping(uint256 => uint256) public gaugeWeight;
    mapping(uint256 => uint256) public gaugeIndex;
    mapping(uint256 => uint256) public gaugeTs;
    mapping(uint256 => mapping(address => uint256)) public holderIndex;
    mapping(uint256 => mapping(address => uint256)) public holderAccrued;

    constructor(IRewardAsset reward_, IGaugeLedger ledger_, uint256 emissionPerSecond_, uint256 gauges) {
        reward = reward_;
        ledger = ledger_;
        admin = msg.sender;
        emissionPerSecond = emissionPerSecond_;
        gaugeCount = gauges;
        for (uint256 g = 0; g < gauges; g++) {
            gaugeTs[g] = block.timestamp;
        }
        emit EmissionRate(emissionPerSecond_);
    }

    modifier onlyAdmin() {
        if (msg.sender != admin) revert Forbidden();
        _;
    }

    function setEmissionRate(uint256 perSecond) external onlyAdmin {
        for (uint256 g = 0; g < gaugeCount; g++) {
            _checkpointGauge(g);
        }
        emissionPerSecond = perSecond;
        emit EmissionRate(perSecond);
    }

    /// Changes a gauge's weight. Its pending emissions are fixed at the old weight first.
    function setGaugeWeight(uint256 gaugeId, uint256 weight) external onlyAdmin {
        if (gaugeId >= gaugeCount) revert UnknownGauge(gaugeId);
        _checkpointGauge(gaugeId);
        totalWeight = totalWeight - gaugeWeight[gaugeId] + weight;
        if (totalWeight == 0) revert WeightSumZero();
        gaugeWeight[gaugeId] = weight;
        emit GaugeWeightSet(gaugeId, weight, totalWeight);
    }

    /// Hook the gauge ledger calls before it changes a holder's balance in a gauge.
    function onGaugeBalanceChange(uint256 gaugeId, address account) external {
        if (msg.sender != address(ledger)) revert Forbidden();
        _settleHolder(gaugeId, account);
    }

    function harvestGauges(uint256[] calldata gaugeIds) external returns (uint256 total) {
        for (uint256 i = 0; i < gaugeIds.length; i++) {
            uint256 gid = gaugeIds[i];
            if (gid >= gaugeCount) revert UnknownGauge(gid);
            _settleHolder(gid, msg.sender);
            uint256 amt = holderAccrued[gid][msg.sender];
            if (amt == 0) continue;
            holderAccrued[gid][msg.sender] = 0;
            total = total + amt;
            emit GaugeHarvest(gid, msg.sender, amt);
        }
        if (total == 0) revert NoRewards();
        if (!reward.transfer(msg.sender, total)) revert PayFailed();
    }

    function projectedIndex(uint256 gaugeId) public view returns (uint256) {
        uint256 supply = ledger.supplyIn(gaugeId);
        uint256 elapsed = block.timestamp - gaugeTs[gaugeId];
        if (supply == 0 || elapsed == 0 || totalWeight == 0) return gaugeIndex[gaugeId];
        uint256 gaugeRate = (emissionPerSecond * gaugeWeight[gaugeId]) / totalWeight;
        return gaugeIndex[gaugeId] + (elapsed * gaugeRate * ACC_UNIT) / supply;
    }

    function holderPending(uint256 gaugeId, address account) external view returns (uint256) {
        uint256 bal = ledger.balanceIn(gaugeId, account);
        uint256 fresh = (bal * (projectedIndex(gaugeId) - holderIndex[gaugeId][account])) / ACC_UNIT;
        return holderAccrued[gaugeId][account] + fresh;
    }

    function _checkpointGauge(uint256 gaugeId) internal {
        uint256 next = projectedIndex(gaugeId);
        if (next != gaugeIndex[gaugeId]) {
            gaugeIndex[gaugeId] = next;
            emit GaugeCheckpointed(gaugeId, next);
        }
        gaugeTs[gaugeId] = block.timestamp;
    }

    function _settleHolder(uint256 gaugeId, address account) internal {
        _checkpointGauge(gaugeId);
        uint256 bal = ledger.balanceIn(gaugeId, account);
        uint256 idx = gaugeIndex[gaugeId];
        uint256 prev = holderIndex[gaugeId][account];
        holderIndex[gaugeId][account] = idx;
        if (bal == 0 || idx == prev) return;
        holderAccrued[gaugeId][account] = holderAccrued[gaugeId][account] + (bal * (idx - prev)) / ACC_UNIT;
    }
}
