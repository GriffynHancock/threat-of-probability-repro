// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @title TieredReserveSupply
/// @notice Share-price vault. Operator-supplied yield raises the share price; a reserve
///         factor diverts a fixed fraction of each yield step into protocol reserves.
contract TieredReserveSupply {
    uint256 private constant SCALE = 1e18;
    uint256 private constant RESERVE_FACTOR_BPS = 1000; // 10%
    uint256 private constant BPS = 10000;

    IERC20 public immutable asset;
    address public immutable governor;

    uint256 public totalShares;
    uint256 public totalAssets;
    uint256 public reserves;
    uint256 public pendingYield;
    uint256 public lastStep;

    mapping(address => uint256) public shareOf;
    mapping(address => uint256) public costBasis;

    event Deposited(address indexed who, uint256 amount, uint256 shares);
    event Withdrawn(address indexed who, uint256 shares, uint256 amount);
    event YieldStepped(uint256 gross, uint256 toReserves);
    event YieldQueued(uint256 amount);

    constructor(IERC20 _asset) {
        asset = _asset;
        governor = msg.sender;
        lastStep = block.timestamp;
    }

    function queueYield(uint256 amount) external {
        require(msg.sender == governor, "governor");
        pendingYield += amount;
        require(asset.transferFrom(msg.sender, address(this), amount), "transferFrom");
        emit YieldQueued(amount);
    }

    function sharePrice() public view returns (uint256) {
        if (totalShares == 0) return SCALE;
        return (totalAssets * SCALE) / totalShares;
    }

    /// @dev Moves queued yield into assets once per block-time step, skimming reserves.
    function _stepIndex() internal {
        if (block.timestamp == lastStep) return;
        lastStep = block.timestamp;
        uint256 gross = pendingYield;
        if (gross == 0) return;
        pendingYield = 0;
        uint256 cut = (gross * RESERVE_FACTOR_BPS) / BPS;
        reserves += cut;
        totalAssets += gross - cut;
        emit YieldStepped(gross, cut);
    }

    function deposit(uint256 amount) external {
        require(amount > 0, "zero");
        _stepIndex();
        uint256 shares = totalShares == 0 ? amount : (amount * totalShares) / totalAssets;
        require(shares > 0, "dust");
        shareOf[msg.sender] += shares;
        costBasis[msg.sender] += amount;
        totalShares += shares;
        totalAssets += amount;
        require(asset.transferFrom(msg.sender, address(this), amount), "transferFrom");
        emit Deposited(msg.sender, amount, shares);
    }

    function withdraw(uint256 shares) external {
        _stepIndex();
        require(shares > 0 && shares <= shareOf[msg.sender], "shares");
        uint256 amount = (shares * totalAssets) / totalShares;
        shareOf[msg.sender] -= shares;
        totalShares -= shares;
        totalAssets -= amount;
        uint256 basisOut = (costBasis[msg.sender] * shares) / (shares + shareOf[msg.sender]);
        costBasis[msg.sender] -= basisOut;
        require(asset.transfer(msg.sender, amount), "transfer");
        emit Withdrawn(msg.sender, shares, amount);
    }
}
