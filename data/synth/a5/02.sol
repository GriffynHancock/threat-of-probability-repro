// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC20Min {
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
}

error ZeroAmount();
error Insufficient(uint256 have, uint256 want);
error FeeTooHigh(uint256 bps);
error NotGovernor();
error TransferFailed();

contract FeeSkimVault {
    uint256 private constant BPS = 10_000;
    uint256 private constant MAX_FEE_BPS = 500;
    uint256 private constant SCALE = 1e18;

    IERC20Min public immutable asset;
    IERC20Min public immutable rewardToken;
    address public governor;
    address public treasury;
    uint256 public depositFeeBps;
    uint256 public withdrawFeeBps;
    uint256 public rewardPerSecond;
    uint256 public lastAccrual;
    uint256 public rewardPerShare;
    uint256 public totalPrincipal;

    mapping(address => uint256) public principalOf;
    mapping(address => uint256) public userIndex;
    mapping(address => uint256) public claimableOf;

    event Staked(address indexed who, uint256 gross, uint256 credited, uint256 fee);
    event Unstaked(address indexed who, uint256 amount, uint256 fee);
    event Harvested(address indexed who, uint256 amount);
    event FeesSet(uint256 depositBps, uint256 withdrawBps);

    modifier onlyGovernor() {
        if (msg.sender != governor) revert NotGovernor();
        _;
    }

    constructor(
        IERC20Min _asset,
        IERC20Min _reward,
        address _treasury,
        uint256 _rewardPerSecond,
        uint256 _depositBps,
        uint256 _withdrawBps
    ) {
        if (_depositBps > MAX_FEE_BPS) revert FeeTooHigh(_depositBps);
        if (_withdrawBps > MAX_FEE_BPS) revert FeeTooHigh(_withdrawBps);
        asset = _asset;
        rewardToken = _reward;
        governor = msg.sender;
        treasury = _treasury;
        rewardPerSecond = _rewardPerSecond;
        depositFeeBps = _depositBps;
        withdrawFeeBps = _withdrawBps;
        lastAccrual = block.timestamp;
    }

    /// @notice Deposit `amount`; the fee is taken from the gross amount and only
    ///         the remainder is credited to the caller's principal.
    function stake(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        _bringCurrent(msg.sender);
        _pullFrom(asset, msg.sender, amount);

        uint256 fee = amount * depositFeeBps / BPS;
        uint256 credited = amount - fee;
        principalOf[msg.sender] += credited;
        totalPrincipal += credited;

        if (fee != 0) _push(asset, treasury, fee);
        emit Staked(msg.sender, amount, credited, fee);
    }

    /// @notice Withdraw `amount` of principal; the withdraw fee is deducted from
    ///         what is sent out.
    function unstake(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        _bringCurrent(msg.sender);
        uint256 have = principalOf[msg.sender];
        if (have < amount) revert Insufficient(have, amount);

        principalOf[msg.sender] = have - amount;
        totalPrincipal -= amount;

        uint256 fee = amount * withdrawFeeBps / BPS;
        if (fee != 0) _push(asset, treasury, fee);
        _push(asset, msg.sender, amount - fee);
        emit Unstaked(msg.sender, amount, fee);
    }

    function harvest() external {
        _bringCurrent(msg.sender);
        uint256 owed = claimableOf[msg.sender];
        if (owed == 0) revert ZeroAmount();
        claimableOf[msg.sender] = 0;
        _push(rewardToken, msg.sender, owed);
        emit Harvested(msg.sender, owed);
    }

    function setFees(uint256 depositBps, uint256 withdrawBps) external onlyGovernor {
        if (depositBps > MAX_FEE_BPS) revert FeeTooHigh(depositBps);
        if (withdrawBps > MAX_FEE_BPS) revert FeeTooHigh(withdrawBps);
        _tick();
        depositFeeBps = depositBps;
        withdrawFeeBps = withdrawBps;
        emit FeesSet(depositBps, withdrawBps);
    }

    function setRewardPerSecond(uint256 r) external onlyGovernor {
        _tick();
        rewardPerSecond = r;
    }

    /// @dev Global index advances first; then the caller's pending share is
    ///      frozen at the OLD principal and their index checkpoint moves forward.
    function _bringCurrent(address who) internal {
        _tick();
        uint256 p = principalOf[who];
        if (p != 0) {
            claimableOf[who] += p * (rewardPerShare - userIndex[who]) / SCALE;
        }
        userIndex[who] = rewardPerShare;
    }

    function _tick() internal {
        uint256 dt = block.timestamp - lastAccrual;
        lastAccrual = block.timestamp;
        if (dt == 0 || totalPrincipal == 0) return;
        rewardPerShare += rewardPerSecond * dt * SCALE / totalPrincipal;
    }

    function _pullFrom(IERC20Min t, address from, uint256 v) private {
        if (!t.transferFrom(from, address(this), v)) revert TransferFailed();
    }

    function _push(IERC20Min t, address to, uint256 v) private {
        if (!t.transfer(to, v)) revert TransferFailed();
    }
}
