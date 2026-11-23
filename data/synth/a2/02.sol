// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

interface IERC20Minimal {
    function balanceOf(address who) external view returns (uint256);
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
}

error ReservoirNotOperator(address caller);
error ReservoirZeroAmount();
error ReservoirInsufficientStake(uint256 requested, uint256 staked);
error ReservoirTransferFailed();

/// Reservoir: a stake pool that emits a constant rate per second.
/// Each depositor owns a Position record; global accumulator is
/// rewardPerTokenStored, and every Position remembers the accumulator
/// value it was last synchronised against.
contract ReservoirPool {
    struct Position {
        uint256 staked;
        uint256 rewardPerTokenPaid;
        uint256 pending;
    }

    uint256 internal constant SCALE = 1e18;

    IERC20Minimal public immutable depositAsset;
    IERC20Minimal public immutable emissionAsset;
    address public operator;

    uint256 public emissionPerSecond;
    uint256 public lastSyncedAt;
    uint256 public rewardPerTokenStored;
    uint256 public totalStaked;

    mapping(address => Position) public positions;

    event Deposited(address indexed who, uint256 amount);
    event Redeemed(address indexed who, uint256 amount);
    event Harvested(address indexed who, uint256 amount);
    event EmissionChanged(uint256 previousRate, uint256 newRate);

    modifier onlyOperator() {
        if (msg.sender != operator) revert ReservoirNotOperator(msg.sender);
        _;
    }

    constructor(IERC20Minimal _deposit, IERC20Minimal _emission, uint256 _emissionPerSecond) {
        depositAsset = _deposit;
        emissionAsset = _emission;
        operator = msg.sender;
        emissionPerSecond = _emissionPerSecond;
        lastSyncedAt = block.timestamp;
    }

    /// Accumulator as of now, without writing state.
    function currentRewardPerToken() public view returns (uint256) {
        if (totalStaked == 0) {
            return rewardPerTokenStored;
        }
        uint256 dt = block.timestamp - lastSyncedAt;
        return rewardPerTokenStored + (dt * emissionPerSecond * SCALE) / totalStaked;
    }

    function pendingOf(address who) public view returns (uint256) {
        Position storage p = positions[who];
        return p.pending + (p.staked * (currentRewardPerToken() - p.rewardPerTokenPaid)) / SCALE;
    }

    function deposit(uint256 amount) external {
        _sync(msg.sender);
        if (amount == 0) revert ReservoirZeroAmount();

        Position storage p = positions[msg.sender];
        p.staked += amount;
        totalStaked += amount;

        _moveIn(depositAsset, msg.sender, amount);
        emit Deposited(msg.sender, amount);
    }

    function redeem(uint256 amount) external {
        _sync(msg.sender);
        if (amount == 0) revert ReservoirZeroAmount();

        Position storage p = positions[msg.sender];
        if (amount > p.staked) revert ReservoirInsufficientStake(amount, p.staked);
        p.staked -= amount;
        totalStaked -= amount;

        _moveOut(depositAsset, msg.sender, amount);
        emit Redeemed(msg.sender, amount);
    }

    function harvest() external {
        _sync(msg.sender);

        Position storage p = positions[msg.sender];
        uint256 owed = p.pending;
        if (owed == 0) return;
        p.pending = 0;

        _moveOut(emissionAsset, msg.sender, owed);
        emit Harvested(msg.sender, owed);
    }

    /// Operator changes the emission rate. Accrual at the old rate is
    /// settled first so the change applies only going forward.
    function setEmissionPerSecond(uint256 rate) external onlyOperator {
        _sync(address(0));
        emit EmissionChanged(emissionPerSecond, rate);
        emissionPerSecond = rate;
    }

    /// Settlement step. Advances the global accumulator to now and, when
    /// an account is supplied, credits its accrued share before its
    /// stake is changed.
    function _sync(address who) internal {
        rewardPerTokenStored = currentRewardPerToken();
        lastSyncedAt = block.timestamp;

        if (who != address(0)) {
            Position storage p = positions[who];
            p.pending = pendingOf(who);
            p.rewardPerTokenPaid = rewardPerTokenStored;
        }
    }

    function _moveIn(IERC20Minimal token, address from, uint256 amount) private {
        if (!token.transferFrom(from, address(this), amount)) revert ReservoirTransferFailed();
    }

    function _moveOut(IERC20Minimal token, address to, uint256 amount) private {
        if (!token.transfer(to, amount)) revert ReservoirTransferFailed();
    }
}
