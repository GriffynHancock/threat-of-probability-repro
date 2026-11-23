// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

error ZeroAmount();
error InsufficientStake(uint256 staked, uint256 requested);
error NothingToClaim();
error NotGovernor();
error TransferFailed();

contract BlockCumulativeVault {
    uint256 internal constant SCALE = 1e18;

    IERC20 public immutable asset;
    IERC20 public immutable rewardAsset;
    address public immutable governor;
    uint256 public immutable genesisBlock;
    uint256 public immutable blocksPerEpoch;
    uint256 public immutable emissionPerEpoch;

    // cumulative[i] = reward per staked unit accrued across the first i closed epochs.
    // cumulative.length - 1 is the number of closed epochs.
    uint256[] public cumulative;

    uint256 public totalStaked;
    mapping(address => uint256) public stakedOf;
    mapping(address => uint256) public entryOf;
    mapping(address => uint256) public owed;

    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount);
    event Harvested(address indexed user, uint256 amount);
    event EpochClosed(uint256 indexed epoch, uint256 rewardPerUnit);

    modifier onlyGovernor() {
        if (msg.sender != governor) revert NotGovernor();
        _;
    }

    constructor(IERC20 _asset, IERC20 _reward, uint256 _blocksPerEpoch, uint256 _emission) {
        if (_blocksPerEpoch == 0) revert ZeroAmount();
        asset = _asset;
        rewardAsset = _reward;
        governor = msg.sender;
        genesisBlock = block.number;
        blocksPerEpoch = _blocksPerEpoch;
        emissionPerEpoch = _emission;
        cumulative.push(0);
    }

    function stake(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        _advanceTo();
        _checkpoint(msg.sender);
        _pull(asset, msg.sender, amount);
        stakedOf[msg.sender] += amount;
        totalStaked += amount;
        emit Staked(msg.sender, amount);
    }

    function unstake(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        _advanceTo();
        _checkpoint(msg.sender);
        uint256 have = stakedOf[msg.sender];
        if (have < amount) revert InsufficientStake(have, amount);
        stakedOf[msg.sender] = have - amount;
        totalStaked -= amount;
        _push(asset, msg.sender, amount);
        emit Unstaked(msg.sender, amount);
    }

    function harvest() external {
        _advanceTo();
        _checkpoint(msg.sender);
        uint256 amount = owed[msg.sender];
        if (amount == 0) revert NothingToClaim();
        owed[msg.sender] = 0;
        _push(rewardAsset, msg.sender, amount);
        emit Harvested(msg.sender, amount);
    }

    function fund(uint256 amount) external onlyGovernor {
        _pull(rewardAsset, msg.sender, amount);
    }

    /// @notice Reward accrued up to the most recent closed epoch boundary.
    function earnedSoFar(address user) external view returns (uint256) {
        uint256 boundary = cumulative.length - 1;
        return owed[user] + stakedOf[user] * (cumulative[boundary] - cumulative[entryOf[user]]) / SCALE;
    }

    /// @dev Closes every whole epoch elapsed since the last boundary. Empty epochs add nothing.
    function _advanceTo() internal {
        uint256 target = (block.number - genesisBlock) / blocksPerEpoch;
        while (cumulative.length - 1 < target) {
            uint256 closing = cumulative.length - 1;
            uint256 prev = cumulative[closing];
            uint256 next = prev;
            if (totalStaked > 0) {
                next = prev + emissionPerEpoch * SCALE / totalStaked;
            }
            cumulative.push(next);
            emit EpochClosed(closing, next - prev);
        }
    }

    /// @dev Moves the user's entitlement from their entry boundary to the current boundary.
    function _checkpoint(address user) internal {
        uint256 boundary = cumulative.length - 1;
        owed[user] += stakedOf[user] * (cumulative[boundary] - cumulative[entryOf[user]]) / SCALE;
        entryOf[user] = boundary;
    }

    function _pull(IERC20 token, address from, uint256 amount) internal {
        if (!token.transferFrom(from, address(this), amount)) revert TransferFailed();
    }

    function _push(IERC20 token, address to, uint256 amount) internal {
        if (!token.transfer(to, amount)) revert TransferFailed();
    }
}
