// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

interface IERC721 {
    function ownerOf(uint256 tokenId) external view returns (address);
    function transferFrom(address from, address to, uint256 tokenId) external;
}

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
}

/// @notice Stake NFTs and earn a reward token per second, split pro rata across stakers.
contract NftYieldVault {
    uint256 private constant PRECISION = 1e18;

    IERC721 public immutable nft;
    IERC20 public immutable rewardToken;
    uint256 public immutable rewardPerSecond;

    uint256 public accRewardPerNft;
    uint256 public lastUpdate;
    uint256 public totalStaked;

    struct Staker {
        uint256 count;
        uint256 snapshot;
        uint256 pending;
    }

    mapping(address => Staker) public stakers;
    mapping(uint256 => address) public tokenOwner;

    event Staked(address indexed user, uint256 tokenId);
    event Unstaked(address indexed user, uint256 tokenId);
    event YieldClaimed(address indexed user, uint256 amount);

    constructor(IERC721 _nft, IERC20 _reward, uint256 _rewardPerSecond) {
        nft = _nft;
        rewardToken = _reward;
        rewardPerSecond = _rewardPerSecond;
        lastUpdate = block.timestamp;
    }

    function _updateGlobal() internal {
        if (totalStaked > 0) {
            uint256 elapsed = block.timestamp - lastUpdate;
            accRewardPerNft += (elapsed * rewardPerSecond * PRECISION) / totalStaked;
        }
        lastUpdate = block.timestamp;
    }

    function _harvestYield(address who) internal {
        _updateGlobal();
        Staker storage s = stakers[who];
        s.pending += (s.count * (accRewardPerNft - s.snapshot)) / PRECISION;
        s.snapshot = accRewardPerNft;
    }

    /// @notice Stake one NFT. Yield is settled before the count changes.
    function stakeNFT(uint256 tokenId) external {
        _harvestYield(msg.sender);
        Staker storage s = stakers[msg.sender];
        s.count += 1;
        totalStaked += 1;
        tokenOwner[tokenId] = msg.sender;
        nft.transferFrom(msg.sender, address(this), tokenId);
        emit Staked(msg.sender, tokenId);
    }

    function unstakeNFT(uint256 tokenId) external {
        require(tokenOwner[tokenId] == msg.sender, "not staker");
        _harvestYield(msg.sender);
        Staker storage s = stakers[msg.sender];
        s.count -= 1;
        totalStaked -= 1;
        delete tokenOwner[tokenId];
        nft.transferFrom(address(this), msg.sender, tokenId);
        emit Unstaked(msg.sender, tokenId);
    }

    function claimYield() external {
        _harvestYield(msg.sender);
        Staker storage s = stakers[msg.sender];
        uint256 amount = s.pending;
        require(amount > 0, "nothing to claim");
        s.pending = 0;
        require(rewardToken.transfer(msg.sender, amount), "transfer failed");
        emit YieldClaimed(msg.sender, amount);
    }
}
