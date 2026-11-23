// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IERC20Like {
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    function transfer(address to, uint256 value) external returns (bool);
}

// Time-weighted lock. Every state-changing entry point runs the `settles`
// modifier, so the global accumulator and the caller's ledger are brought
// current before the function body touches any balance.
contract TimedLockFarm {
    struct Ledger {
        uint256 principal;
        uint256 debt;
        uint256 unclaimed;
    }

    uint256 private constant SCALE = 1e18;

    IERC20Like public immutable principalToken;
    IERC20Like public immutable payoutToken;
    address public immutable deployer;

    uint256 public payoutPerSecond;
    uint256 public stampedAt;
    uint256 public cumulativePerUnit;
    uint256 public principalTotal;

    mapping(address => Ledger) public ledgers;

    event Locked(address indexed who, uint256 amount);
    event Unlocked(address indexed who, uint256 amount);
    event Collected(address indexed who, uint256 amount);
    event PayoutRateChanged(uint256 oldRate, uint256 newRate);

    constructor(IERC20Like principal_, IERC20Like payout_, uint256 rate_) {
        principalToken = principal_;
        payoutToken = payout_;
        deployer = msg.sender;
        payoutPerSecond = rate_;
        stampedAt = block.timestamp;
    }

    modifier settles() {
        _poke();
        _;
    }

    modifier onlyDeployer() {
        require(msg.sender == deployer, "deployer only");
        _;
    }

    function _poke() internal {
        uint256 nowTs = block.timestamp;
        if (nowTs > stampedAt && principalTotal != 0) {
            cumulativePerUnit += ((nowTs - stampedAt) * payoutPerSecond * SCALE) / principalTotal;
        }
        stampedAt = nowTs;
    }

    function _settleUser(address who) internal {
        Ledger storage l = ledgers[who];
        uint256 entitled = (l.principal * cumulativePerUnit) / SCALE;
        l.unclaimed += entitled - l.debt;
        l.debt = entitled;
    }

    function lock(uint256 amount) external settles {
        require(amount > 0, "empty");
        _settleUser(msg.sender);

        Ledger storage l = ledgers[msg.sender];
        l.principal += amount;
        principalTotal += amount;
        l.debt = (l.principal * cumulativePerUnit) / SCALE;

        require(principalToken.transferFrom(msg.sender, address(this), amount), "pull failed");
        emit Locked(msg.sender, amount);
    }

    function unlock(uint256 amount) external settles {
        Ledger storage l = ledgers[msg.sender];
        require(amount > 0 && l.principal >= amount, "insufficient principal");
        _settleUser(msg.sender);

        l.principal -= amount;
        principalTotal -= amount;
        l.debt = (l.principal * cumulativePerUnit) / SCALE;

        require(principalToken.transfer(msg.sender, amount), "return failed");
        emit Unlocked(msg.sender, amount);
    }

    function collect() external settles {
        _settleUser(msg.sender);
        Ledger storage l = ledgers[msg.sender];
        uint256 out = l.unclaimed;
        require(out > 0, "nothing to collect");

        l.unclaimed = 0;
        require(payoutToken.transfer(msg.sender, out), "payout failed");
        emit Collected(msg.sender, out);
    }

    function setPayoutRate(uint256 newRate) external onlyDeployer settles {
        emit PayoutRateChanged(payoutPerSecond, newRate);
        payoutPerSecond = newRate;
    }
}
