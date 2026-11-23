// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// ----------------------------------------------------------------------------
// Inline SafeMath (2020 DeFi house copy)
// ----------------------------------------------------------------------------
library SafeMath {
    function add(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 c = a + b;
        require(c >= a, "SafeMath: addition overflow");
        return c;
    }
    function sub(uint256 a, uint256 b) internal pure returns (uint256) {
        require(b <= a, "SafeMath: subtraction overflow");
        return a - b;
    }
    function mul(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a == 0) return 0;
        uint256 c = a * b;
        require(c / a == b, "SafeMath: multiplication overflow");
        return c;
    }
    function div(uint256 a, uint256 b) internal pure returns (uint256) {
        require(b > 0, "SafeMath: division by zero");
        return a / b;
    }
}

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

// ============================================================================
// BondingEmission - bond tokens; the emission rate halves every epoch.
// ============================================================================
contract BondingEmission {
    using SafeMath for uint256;

    struct Bond {
        uint256 principal;
        uint256 rewardDebt;
        uint256 pending;
    }

    uint256 private constant PRECISION = 1e12;
    uint256 public constant EPOCH_LENGTH = 30 days;

    IERC20 public bondToken;
    IERC20 public payoutToken;
    address public issuer;

    uint256 public emissionRate;
    uint256 public epochStart;
    uint256 public epochIndex;
    uint256 public lastEmission;
    uint256 public accPayoutPerBond;
    uint256 public bondedTotal;

    mapping(address => Bond) public bonds;

    event Bonded(address indexed holder, uint256 amount);
    event Unbonded(address indexed holder, uint256 amount);
    event PayoutClaimed(address indexed holder, uint256 amount);
    event EpochAdvanced(uint256 epoch, uint256 newRate);

    constructor(IERC20 _bond, IERC20 _payout, uint256 _initialRate) {
        bondToken = _bond;
        payoutToken = _payout;
        emissionRate = _initialRate;
        epochStart = block.timestamp;
        lastEmission = block.timestamp;
        issuer = msg.sender;
    }

    // Settlement helper: rolls the emission schedule and the payout index.
    function _advanceEmission() internal {
        while (block.timestamp >= epochStart.add(EPOCH_LENGTH)) {
            accrueToEpochBoundary();
            epochIndex = epochIndex.add(1);
            emissionRate = emissionRate.div(2);
            epochStart = epochStart.add(EPOCH_LENGTH);
            emit EpochAdvanced(epochIndex, emissionRate);
        }
        if (bondedTotal == 0 || block.timestamp <= lastEmission) {
            lastEmission = block.timestamp;
            return;
        }
        uint256 minted = block.timestamp.sub(lastEmission).mul(emissionRate);
        accPayoutPerBond = accPayoutPerBond.add(minted.mul(PRECISION).div(bondedTotal));
        lastEmission = block.timestamp;
    }

    function accrueToEpochBoundary() internal {
        uint256 boundary = epochStart.add(EPOCH_LENGTH);
        if (bondedTotal > 0 && lastEmission < boundary) {
            uint256 minted = boundary.sub(lastEmission).mul(emissionRate);
            accPayoutPerBond = accPayoutPerBond.add(minted.mul(PRECISION).div(bondedTotal));
        }
        lastEmission = boundary;
    }

    function _settleBond(address _holder) internal {
        Bond storage b = bonds[_holder];
        b.pending = b.pending.add(b.principal.mul(accPayoutPerBond).div(PRECISION).sub(b.rewardDebt));
        b.rewardDebt = b.principal.mul(accPayoutPerBond).div(PRECISION);
    }

    function bond(uint256 _amount) external {
        require(_amount > 0, "BondingEmission: zero bond");
        _advanceEmission();
        _settleBond(msg.sender);
        Bond storage b = bonds[msg.sender];
        b.principal = b.principal.add(_amount);
        bondedTotal = bondedTotal.add(_amount);
        b.rewardDebt = b.principal.mul(accPayoutPerBond).div(PRECISION);
        require(bondToken.transferFrom(msg.sender, address(this), _amount), "BondingEmission: bond in");
        emit Bonded(msg.sender, _amount);
    }

    function unbond(uint256 _amount) external {
        Bond storage b = bonds[msg.sender];
        require(b.principal >= _amount, "BondingEmission: short");
        _advanceEmission();
        _settleBond(msg.sender);
        b.principal = b.principal.sub(_amount);
        bondedTotal = bondedTotal.sub(_amount);
        b.rewardDebt = b.principal.mul(accPayoutPerBond).div(PRECISION);
        require(bondToken.transfer(msg.sender, _amount), "BondingEmission: bond out");
        emit Unbonded(msg.sender, _amount);
    }

    function claimPayout() external {
        _advanceEmission();
        _settleBond(msg.sender);
        Bond storage b = bonds[msg.sender];
        uint256 owed = b.pending;
        b.pending = 0;
        if (owed > 0) {
            require(payoutToken.transfer(msg.sender, owed), "BondingEmission: payout");
            emit PayoutClaimed(msg.sender, owed);
        }
    }
}
