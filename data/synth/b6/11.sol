// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @notice Epoch-batched unstaking. Requests join the open epoch and are priced when the epoch closes.
contract EpochUnstakeBatch {
    uint256 private constant PRECISION = 1e18;

    IERC20 public immutable asset;
    address public immutable owner;
    uint256 public immutable epochLength;
    uint256 public epochStart;
    uint256 public currentEpoch;

    uint256 public totalAssets;
    uint256 public totalShares;

    mapping(address => uint256) public sharesOf;
    mapping(uint256 => uint256) public epochShares;
    mapping(uint256 => uint256) public epochPrice;
    mapping(uint256 => uint256) public epochAssets;
    mapping(uint256 => mapping(address => uint256)) public queued;

    event Staked(address indexed user, uint256 assets, uint256 shares);
    event EpochClosed(uint256 indexed epoch, uint256 price, uint256 assets);
    event UnstakeQueued(address indexed user, uint256 indexed epoch, uint256 shares);
    event EpochClaimed(address indexed user, uint256 indexed epoch, uint256 assets);

    constructor(IERC20 _asset, uint256 _epochLength) {
        asset = _asset;
        owner = msg.sender;
        epochLength = _epochLength;
        epochStart = block.timestamp;
    }

    function _advanceEpoch() internal {
        while (block.timestamp >= epochStart + epochLength) {
            uint256 c = currentEpoch;
            uint256 supply = totalShares + epochShares[c];
            uint256 price = supply == 0 ? PRECISION : (totalAssets * PRECISION) / supply;
            uint256 out = (epochShares[c] * price) / PRECISION;
            epochPrice[c] = price;
            epochAssets[c] = out;
            totalAssets -= out;
            currentEpoch = c + 1;
            epochStart += epochLength;
            emit EpochClosed(c, price, out);
        }
    }

    function stakeAssets(uint256 assets) external returns (uint256 minted) {
        require(assets > 0, "zero");
        _advanceEpoch();
        uint256 supply = totalShares + epochShares[currentEpoch];
        minted = totalAssets == 0 ? assets : (assets * supply) / totalAssets;
        require(minted > 0, "dust");
        sharesOf[msg.sender] += minted;
        totalShares += minted;
        totalAssets += assets;
        emit Staked(msg.sender, assets, minted);
        require(asset.transferFrom(msg.sender, address(this), assets), "pull");
    }

    function queueUnstake(uint256 shares) external returns (uint256 epoch) {
        require(shares > 0, "zero");
        _advanceEpoch();
        require(sharesOf[msg.sender] >= shares, "insufficient");
        sharesOf[msg.sender] -= shares;
        totalShares -= shares;
        epoch = currentEpoch;
        epochShares[epoch] += shares;
        queued[epoch][msg.sender] += shares;
        emit UnstakeQueued(msg.sender, epoch, shares);
    }

    function claimEpoch(uint256 epoch) external returns (uint256 out) {
        _advanceEpoch();
        require(epoch < currentEpoch, "epoch open");
        uint256 s = queued[epoch][msg.sender];
        require(s > 0, "nothing");
        queued[epoch][msg.sender] = 0;
        out = (s * epochPrice[epoch]) / PRECISION;
        emit EpochClaimed(msg.sender, epoch, out);
        require(asset.transfer(msg.sender, out), "xfer");
    }
}
