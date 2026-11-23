// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.19 <0.9.0;

/// Minimal ERC-20 surface used by the vault.
interface IERC20Like {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @title FarmVault
/// @notice Stake-to-earn vault whose emission rate decays by a fixed factor each time the
///         operator calls `stepDown()`. All accrual is settled through the `accrue` modifier.
contract FarmVault {
    struct Position {
        uint256 shares;
        uint256 rewardSnapshot;
        uint256 accumulated;
    }

    uint256 public constant ONE = 1e18;
    uint256 public constant DECAY_NUM = 9;
    uint256 public constant DECAY_DEN = 10;

    IERC20Like public immutable lpToken;
    IERC20Like public immutable farmToken;
    address public governor;

    uint256 public emissionRate;
    uint256 public rewardIndex;
    uint256 public lastIndexUpdate;
    uint256 public totalShares;

    mapping(address => Position) private _positions;

    event Staked(address indexed account, uint256 amount);
    event Unstaked(address indexed account, uint256 amount);
    event Claimed(address indexed account, uint256 amount);
    event Stepped(uint256 newRate);

    modifier onlyGovernor() {
        require(msg.sender == governor, "FarmVault: unauthorised");
        _;
    }

    /// @dev Advances the global index to the current block, then (if an account is given)
    ///      credits that account's accrual. Runs before the function body.
    modifier accrue(address account) {
        rewardIndex = _indexNow();
        lastIndexUpdate = block.timestamp;
        if (account != address(0)) {
            Position storage p = _positions[account];
            p.accumulated = _owedTo(p);
            p.rewardSnapshot = rewardIndex;
        }
        _;
    }

    constructor(IERC20Like _lp, IERC20Like _farm, uint256 _initialRate) {
        lpToken = _lp;
        farmToken = _farm;
        governor = msg.sender;
        emissionRate = _initialRate;
        lastIndexUpdate = block.timestamp;
    }

    function positionOf(address account)
        external
        view
        returns (uint256 shares, uint256 claimable)
    {
        Position storage p = _positions[account];
        return (p.shares, _owedTo(p));
    }

    function stake(uint256 amount) external accrue(msg.sender) {
        require(amount > 0, "FarmVault: zero");
        Position storage p = _positions[msg.sender];
        p.shares += amount;
        totalShares += amount;
        require(lpToken.transferFrom(msg.sender, address(this), amount), "FarmVault: lp in");
        emit Staked(msg.sender, amount);
    }

    function unstake(uint256 amount) external accrue(msg.sender) {
        Position storage p = _positions[msg.sender];
        require(amount > 0 && amount <= p.shares, "FarmVault: shares");
        p.shares -= amount;
        totalShares -= amount;
        require(lpToken.transfer(msg.sender, amount), "FarmVault: lp out");
        emit Unstaked(msg.sender, amount);
    }

    function claimReward() external accrue(msg.sender) {
        Position storage p = _positions[msg.sender];
        uint256 amount = p.accumulated;
        require(amount > 0, "FarmVault: nothing");
        p.accumulated = 0;
        require(farmToken.transfer(msg.sender, amount), "FarmVault: farm out");
        emit Claimed(msg.sender, amount);
    }

    /// @notice Reduces the emission rate by the decay factor. Accrual at the old rate is
    ///         booked by the `accrue` modifier before the rate changes.
    function stepDown() external onlyGovernor accrue(address(0)) {
        emissionRate = (emissionRate * DECAY_NUM) / DECAY_DEN;
        emit Stepped(emissionRate);
    }

    function _indexNow() private view returns (uint256) {
        if (totalShares == 0) {
            return rewardIndex;
        }
        uint256 elapsed = block.timestamp - lastIndexUpdate;
        return rewardIndex + (elapsed * emissionRate * ONE) / totalShares;
    }

    function _owedTo(Position storage p) private view returns (uint256) {
        uint256 delta = _indexNow() - p.rewardSnapshot;
        return p.accumulated + (p.shares * delta) / ONE;
    }
}
