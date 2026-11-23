// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @title SlashingInsuranceLedger
/// @notice Share-based insurance vault. Incidents reduce totalAssets, so price-per-share falls.
///         Premiums accrue on a per-share index.
contract SlashingInsuranceLedger {
    error ZeroAmount();
    error VaultImpaired();
    error NotEnoughShares();
    error TransferFailed();

    uint256 private constant PRECISION = 1e18;

    IERC20 public immutable asset;
    address public immutable underwriter;

    uint256 public totalShares;
    uint256 public totalAssets;
    uint256 public premiumIndex;

    mapping(address => uint256) public sharesOf;
    mapping(address => uint256) public premiumDebt;
    mapping(address => uint256) public premiumOwed;

    event Insured(address indexed who, uint256 assets, uint256 shares);
    event Exited(address indexed who, uint256 shares, uint256 assets);
    event IncidentReported(uint256 loss, uint256 newTotalAssets);
    event PremiumPaid(uint256 amount);
    event PremiumHarvested(address indexed who, uint256 amount);

    constructor(IERC20 _asset) {
        asset = _asset;
        underwriter = msg.sender;
    }

    /// @notice Underwriter records a loss; all shares are diluted pro rata.
    function reportIncident(uint256 loss) external {
        require(msg.sender == underwriter, "not underwriter");
        if (loss > totalAssets) loss = totalAssets;
        totalAssets -= loss;
        emit IncidentReported(loss, totalAssets);
    }

    function payPremium(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        if (totalShares == 0) revert ZeroAmount();
        if (!asset.transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
        totalAssets += amount;
        premiumIndex += (amount * PRECISION) / totalShares;
        emit PremiumPaid(amount);
    }

    function _applySlashIndex(address who) internal {
        uint256 s = sharesOf[who];
        if (s > 0) {
            premiumOwed[who] += (s * (premiumIndex - premiumDebt[who])) / PRECISION;
        }
        premiumDebt[who] = premiumIndex;
    }

    /// @notice Deposit assets and receive shares at the current price.
    function insure(uint256 assets) external {
        if (assets == 0) revert ZeroAmount();
        if (totalAssets == 0 && totalShares > 0) revert VaultImpaired();
        _applySlashIndex(msg.sender);
        uint256 minted = totalShares == 0 ? assets : (assets * totalShares) / totalAssets;
        sharesOf[msg.sender] += minted;
        totalShares += minted;
        totalAssets += assets;
        if (!asset.transferFrom(msg.sender, address(this), assets)) revert TransferFailed();
        emit Insured(msg.sender, assets, minted);
    }

    /// @notice Burn shares for assets at the current (possibly impaired) price.
    function exitPool(uint256 shares) external {
        _applySlashIndex(msg.sender);
        if (sharesOf[msg.sender] < shares) revert NotEnoughShares();
        uint256 assets = (shares * totalAssets) / totalShares;
        sharesOf[msg.sender] -= shares;
        totalShares -= shares;
        totalAssets -= assets;
        if (!asset.transfer(msg.sender, assets)) revert TransferFailed();
        emit Exited(msg.sender, shares, assets);
    }

    /// @notice Harvest premiums owed on current shares.
    function harvestPremium() external {
        _applySlashIndex(msg.sender);
        uint256 amount = premiumOwed[msg.sender];
        if (amount == 0) revert ZeroAmount();
        premiumOwed[msg.sender] = 0;
        totalAssets -= amount;
        if (!asset.transfer(msg.sender, amount)) revert TransferFailed();
        emit PremiumHarvested(msg.sender, amount);
    }
}
